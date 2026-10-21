import os
import XCTest
@testable import TextMouth

/// The braille helper's line protocol, version 2 (October 21, 2026): each
/// paragraph travels with the emphasis of each of its characters, defined
/// once in `TextMouthBraille/include/TextMouthBrailleProtocol.h` for both the
/// helper and the app. The input the app writes, the outputs it accepts and
/// refuses, the real helper's refusals of input of another form, and
/// emphasis through the real helper both ways in the four bundled tables.
/// Every call must leave its working folder empty.
final class BrailleHelperProtocolTests: XCTestCase {
    /// The folder the helper's hidden files are made in.
    private var work = URL(fileURLWithPath: "/var/empty", isDirectory: true)  // replaced in setUp

    /// The four bundled tables: UEB and EBAE, each uncontracted and contracted.
    private let ueb = ["en-ueb-g1.ctb", "en-ueb-g2.ctb"]
    private let ebae = ["en-us-g1.ctb", "en_US.tbl"]

    override func setUpWithError() throws {
        work = try makeSandboxDirectory("BrailleProtocol")
    }

    // MARK: - Helpers

    /// Asserts that the working folder holds nothing, hidden files included.
    private func assertWorkFolderEmpty(file: StaticString = #filePath, line: UInt = #line) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? ["<unreadable>"]
        XCTAssertEqual(names, [], file: file, line: line)
    }

    /// `text` with `flags` on the scalars of each range in `ranges`, given
    /// as offsets in scalars; an offset past the text is left out, so a
    /// mistaken range fails its test rather than trapping.
    private func emphasized(_ text: String, _ ranges: [(Range<Int>, BrailleEmphasis)]) -> EmphasizedText {
        var flags = [BrailleEmphasis](repeating: [], count: text.unicodeScalars.count)
        for (range, emphasis) in ranges {
            for index in range where flags.indices.contains(index) { flags[index].formUnion(emphasis) }
        }
        return EmphasizedText(text, emphasis: flags) ?? EmphasizedText(text)
    }

    /// Each word of `text` (split at spaces), in order, with the emphasis of
    /// its first scalar, what a word's letters say of it: "cat/1" for an
    /// italic "cat".
    private func wordEmphasis(_ text: EmphasizedText) -> [String] {
        var result: [String] = []
        var word = ""
        var flags: BrailleEmphasis?
        let emphasis = text.hasEmphasis ? text.emphasis : Array(repeating: [], count: text.text.unicodeScalars.count)
        for (scalar, scalarFlags) in Array(zip(text.text.unicodeScalars, emphasis)) + [(" ", [])] {
            if scalar == " " {
                if !word.isEmpty { result.append("\(word)/\((flags ?? []).rawValue)") }
                word = ""
                flags = nil
            } else {
                word.unicodeScalars.append(scalar)
                flags = flags ?? scalarFlags
            }
        }
        return result
    }

    /// Limits that keep a test short.
    private func limits(seconds: TimeInterval = 5) -> WatchedProcess.Limits {
        WatchedProcess.Limits(
            maximumSeconds: seconds, maximumResidentBytes: 1 << 30, maximumStalledSeconds: seconds, pollInterval: 0.1
        )
    }

    /// A stand-in helper that runs `/bin/sh -c script sh MODE OUTPUT INPUT`.
    private func shell(_ script: String) -> BrailleTranslator.Tool {
        let limits = limits()
        return BrailleTranslator.Tool(
            command: { mode, _, input, output in
                (URL(fileURLWithPath: "/bin/sh"), ["-c", script, "sh", mode, output?.path ?? "", input?.path ?? ""])
            },
            limits: { _, _ in limits },
            residentMemory: { _ in nil },
            tablesFolder: nil
        )
    }

    /// A stand-in helper whose translation writes `output`, whatever its input.
    private func writing(_ output: String) -> BrailleTranslator.Tool {
        let quoted = output.replacingOccurrences(of: "'", with: #"'\''"#)
        return shell("printf '%s' '\(quoted)' > \"$2\"")
    }

    /// The real helper run in `mode` on the bundled `table`, on an input file
    /// holding `input`: its exit status (nil when the watchdog stopped it or
    /// it could not start) and the output it wrote, if any.
    private func runRealHelper(_ mode: String, _ table: String, input: Data) throws -> (status: Int32?, output: String?) {
        let executable = try XCTUnwrap(Bundle.main.url(forAuxiliaryExecutable: "TextMouthBraille"))
        let tables = try XCTUnwrap(BrailleTranslator.Tool.helper.tablesFolder)
        let inputURL = work.appendingPathComponent("input.txt")
        let outputURL = work.appendingPathComponent("output.txt")
        try input.write(to: inputURL)
        defer {
            try? FileManager.default.removeItem(at: inputURL)
            try? FileManager.default.removeItem(at: outputURL)
        }
        let limits = limits(seconds: 20)
        let outcome = try AsyncBridge.waitForResult {
            try await WatchedProcess.run(
                executable, arguments: [mode, tables.path, table, inputURL.path, outputURL.path],
                watching: outputURL, limits: limits
            )
        }
        let output = try? String(contentsOf: outputURL, encoding: .utf8)
        guard case let .exited(status) = outcome else { return (nil, output) }
        return (status, output)
    }

    /// The protocol's header line.
    private var header: String { BrailleEmphasis.protocolHeader + "\n" }

    // MARK: - The Protocol, Defined Once

    /// The app reads the protocol from the helper's own header: version 2's
    /// header line, and a code for each set of flags, "@" plus the flags,
    /// each a printable ASCII character, none a line feed.
    func testTheProtocolComesFromTheHelpersHeader() {
        XCTAssertEqual(BrailleEmphasis.protocolHeader, "TextMouthBraille 2")
        XCTAssertEqual(BrailleEmphasis.italic.rawValue, 1)
        XCTAssertEqual(BrailleEmphasis.bold.rawValue, 2)
        XCTAssertEqual(BrailleEmphasis.underline.rawValue, 4)
        XCTAssertEqual(BrailleEmphasis.script.rawValue, 8)
        XCTAssertEqual(BrailleEmphasis.transcriber.rawValue, 16)

        XCTAssertEqual(BrailleEmphasis().code, UInt8(ascii: "@"))
        XCTAssertEqual(BrailleEmphasis.italic.code, UInt8(ascii: "A"))
        XCTAssertEqual(BrailleEmphasis.bold.code, UInt8(ascii: "B"))
        XCTAssertEqual(BrailleEmphasis([.italic, .bold]).code, UInt8(ascii: "C"))
        XCTAssertEqual(BrailleEmphasis([.italic, .bold, .underline, .script, .transcriber]).code, UInt8(ascii: "_"))

        // Every code stands for its flags, and nothing else is a code.
        for raw in UInt8(0)...31 {
            let flags = BrailleEmphasis(rawValue: raw)
            XCTAssertEqual(BrailleEmphasis(code: flags.code), flags)
            XCTAssertTrue((0x40...0x5F).contains(flags.code))
        }
        for byte in [UInt8(0x0A), 0x20, 0x3F, 0x60, 0x7F, 0xFF] {
            XCTAssertNil(BrailleEmphasis(code: byte), "byte \(byte)")
        }
        // Bits the protocol has not got are dropped.
        XCTAssertEqual(BrailleEmphasis(rawValue: 0xE1), .italic)
    }

    // MARK: - Text With Its Emphasis

    /// An `EmphasizedText` keeps one emphasis for each scalar, or none at
    /// all when every scalar is plain, through every way it is built:
    /// emphasis that does not number the scalars is refused; appending a
    /// scalar, a string, or another text keeps each scalar's emphasis,
    /// starting from an empty text too; and trimming white space trims its
    /// emphasis with it.
    func testEmphasizedTextKeepsEachScalarsEmphasis() throws {
        XCTAssertNil(EmphasizedText("ab", emphasis: [.italic]))
        XCTAssertEqual(EmphasizedText("ab", emphasis: [[], []]), EmphasizedText("ab"))
        XCTAssertFalse(try XCTUnwrap(EmphasizedText("ab", emphasis: [[], []])).hasEmphasis)

        // Appending emphasized text to an empty one keeps the emphasis.
        var built = EmphasizedText()
        built.append(try XCTUnwrap(EmphasizedText("ab", emphasis: [.italic, .italic])))
        XCTAssertEqual(built.emphasis, [.italic, .italic])
        var fromScalar = EmphasizedText()
        fromScalar.append("x", .bold)
        XCTAssertEqual(fromScalar.emphasis, [.bold])
        var fromString = EmphasizedText()
        fromString.append(contentsOf: "xy", .script)
        XCTAssertEqual(fromString.emphasis, [.script, .script])

        // Plain text, then emphasis: the plain scalars get plain entries.
        var mixed = EmphasizedText("a ")
        mixed.append(contentsOf: "cat", .italic)
        mixed.append(" ", [])
        mixed.append(EmphasizedText("sat"))
        XCTAssertEqual(mixed.text, "a cat sat")
        XCTAssertEqual(mixed.emphasis, [[], [], .italic, .italic, .italic, [], [], [], []])
        XCTAssertEqual(mixed.firstEmphasis, [])
        XCTAssertEqual(mixed.lastEmphasis, [])

        // Plain additions to plain text keep no array at all.
        var plain = EmphasizedText("a")
        plain.append(contentsOf: "b", [])
        plain.append("c", [])
        plain.append(EmphasizedText("d"))
        XCTAssertEqual(plain, EmphasizedText("abcd"))

        // Trimming takes the emphasis of what it trims.
        let padded = try XCTUnwrap(EmphasizedText(" \u{A0}cat\n ", emphasis: [.bold, .bold, .italic, .italic, .italic, .bold, .bold]))
        XCTAssertEqual(padded.trimmingWhitespace(), EmphasizedText("cat", emphasis: [.italic, .italic, .italic]))
        let onlyEdgesEmphasized = try XCTUnwrap(EmphasizedText(" cat ", emphasis: [.bold, [], [], [], .bold]))
        XCTAssertEqual(onlyEdgesEmphasized.trimmingWhitespace(), EmphasizedText("cat"))
        XCTAssertEqual(EmphasizedText("  ").trimmingWhitespace(), EmphasizedText())
    }

    // MARK: - What the App Writes and Reads

    /// The input is the header, then a record for each piece: its text and
    /// a code for each of its scalars, or an empty line for a piece with no
    /// emphasis; an empty text sends no record. A stand-in copies the input
    /// to the output and to a file the test reads, and the copy, a
    /// well-formed output, comes back as the texts with their emphasis.
    func testTheInputHoldsEachPiecesRecordAndComesBackWhole() throws {
        let copy = work.appendingPathComponent("copy.txt")
        let texts = [
            emphasized("a cat sat", [(2..<5, .italic)]),
            EmphasizedText("plain words"),
            EmphasizedText(""),
            emphasized("caf\u{E9} \u{1F600}!", [(0..<4, [.italic, .bold]), (5..<6, .underline)]),
        ]
        let result = try BrailleTranslator.$tool.withValue(shell(#"cp "$3" "$2" && cp "$3" "\#(copy.path)""#)) {
            try BrailleTranslator.translate(texts, table: "en-ueb-g1.ctb", direction: .printToBraille, workingIn: work)
        }
        XCTAssertEqual(
            try String(contentsOf: copy, encoding: .utf8),
            header + "a cat sat\n@@AAA@@@@\nplain words\n\ncaf\u{E9} \u{1F600}!\nCCCC@D@\n"
        )
        try FileManager.default.removeItem(at: copy)
        XCTAssertEqual(result, texts)
        assertWorkFolderEmpty()
    }

    /// Outputs the app cannot trust are failures, each logged as one line
    /// that names what was wrong and holds no text: no header, another
    /// protocol's header, too few or too many records, codes that do not
    /// number their text's scalars, and a byte that is no code.
    func testOutputsThatDoNotFitAreFailed() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let cases: [(output: String, logged: String)] = [
            ("abc\n\n", "wrote no protocol header"),
            ("TextMouthBraille 1\nabc\n\n", "wrote no protocol header"),
            (header, "wrote 0 lines for 1 pieces"),
            (header + "abc\n", "wrote 1 lines for 1 pieces"),
            (header + "abc\n\nabc\n\n", "wrote 4 lines for 1 pieces"),
            (header + "abc\n@A\n", "wrote codes that do not fit their text"),
            (header + "abc\n@AAA\n", "wrote codes that do not fit their text"),
            (header + "abc\n@a@\n", "wrote codes that do not fit their text"),
        ]
        for (output, logged) in cases {
            let lines = try logLines(in: .debug) {
                try BrailleTranslator.$tool.withValue(writing(output)) {
                    XCTAssertThrowsError(
                        try BrailleTranslator.translate(
                            [EmphasizedText("\u{2801}")], table: "en-ueb-g1.ctb", direction: .brailleToPrint, workingIn: work
                        ), output
                    ) {
                        XCTAssertEqual($0 as? BrailleTranslator.Failure, .failed, output)
                    }
                }
            }
            let ours = lines.filter { $0.contains("BRAILLE_HELPER_") }
            XCTAssertEqual(ours.count, 1, "\(output): \(ours)")
            XCTAssertTrue(ours.first?.contains("BRAILLE_HELPER_FAILED: back en-ueb-g1.ctb: \(logged)") == true, "\(output): \(ours)")
        }
        assertWorkFolderEmpty()
    }

    /// An output's codes come back as each scalar's flags, and an empty code
    /// line as none.
    func testCodesComeBackAsEachScalarsEmphasis() throws {
        let result = try BrailleTranslator.$tool.withValue(writing(header + "abc\n@AB\nxy\n\n")) {
            try BrailleTranslator.translate(
                [EmphasizedText("\u{2801}"), EmphasizedText("\u{2803}")],
                table: "en-ueb-g1.ctb", direction: .brailleToPrint, workingIn: work
            )
        }
        let abc = try XCTUnwrap(EmphasizedText("abc", emphasis: [[], .italic, .bold]))
        XCTAssertEqual(result, [abc, EmphasizedText("xy")])
        XCTAssertEqual(result.first?.hasEmphasis, true)
        XCTAssertEqual(result.last?.hasEmphasis, false)
        assertWorkFolderEmpty()
    }

    /// A text cut into pieces is joined again with the word break the cut
    /// dropped, which takes the emphasis both its neighbours have: a space
    /// inside an italic passage is italic, and one between an italic word
    /// and a plain one is plain. The stand-in answers each of the 9,000-cell
    /// text's three pieces with a record of its own.
    func testABreakPutBackBetweenPiecesTakesTheEmphasisItsNeighboursShare() throws {
        let long = Array(repeating: String(repeating: "\u{2801}", count: 3_000), count: 3).joined(separator: "\u{2800}")
        XCTAssertEqual(BrailleTranslator.pieces(of: long, direction: .brailleToPrint).count, 3)
        let result = try BrailleTranslator.$tool.withValue(writing(header + "ab\nAA\ncd\nAC\nef\n@@\n")) {
            try BrailleTranslator.translate([EmphasizedText(long)], table: "en-ueb-g1.ctb", direction: .brailleToPrint, workingIn: work)
        }
        let expected = try XCTUnwrap(EmphasizedText("ab cd ef", emphasis: [.italic, .italic, .italic, .italic, [.italic, .bold], [], [], []]))
        XCTAssertEqual(result, [expected])
        assertWorkFolderEmpty()
    }

    // MARK: - The Real Helper's Refusals

    /// The real helper reads only protocol 2. An input with no header, with
    /// protocol 1's form, or empty is refused with status 7; codes that do
    /// not number their text's characters, a byte that is no code, codes
    /// sent with braille, a text with no code line after it, and codes for
    /// an empty text, with status 4. A well-formed input gives the header
    /// and a record for each record.
    func testTheRealHelperRefusesInputOfAnotherForm() throws {
        let a = "\u{2801}"
        let refusals: [(mode: String, input: String, status: Int32)] = [
            ("back", "\(a)\n", 7),
            ("back", "TextMouthBraille 1\n\(a)\n\n", 7),
            ("forward", "", 7),
            ("back", header + "\(a)\n@\n", 4),
            ("forward", header + "abc\n@@\n", 4),
            ("forward", header + "abc\n@@@@\n", 4),
            ("forward", header + "abc\n@`@\n", 4),
            ("forward", header + "abc\n@?@\n", 4),
            ("forward", header + "abc\n", 4),
            ("forward", header + "\n@\n", 4),
        ]
        for (mode, input, status) in refusals {
            let run = try runRealHelper(mode, "en-ueb-g1.ctb", input: Data(input.utf8))
            XCTAssertEqual(run.status, status, "\(mode): \(input.debugDescription)")
        }

        let good = try runRealHelper("forward", "en-ueb-g1.ctb", input: Data((header + "a cat\n@@AAA\n\n\nplain\n\n").utf8))
        XCTAssertEqual(good.status, 0)
        XCTAssertEqual(good.output, header + "\u{2801}\u{2800}\u{2828}\u{2802}\u{2809}\u{2801}\u{281E}\n\n\n\n\u{280F}\u{2807}\u{2801}\u{280A}\u{281D}\n\n")
        assertWorkFolderEmpty()
    }

    // MARK: - Emphasis Through liblouis

    /// UEB, both grades: italic, bold, both, underline, script, and a
    /// transcriber-defined typeface written forward become UEB's indicators
    /// (the italic word indicator ⠨⠂ for one word, the bold passage
    /// indicator ⠘⠶ and terminator ⠘⠄ for three words or more), and read
    /// back as the same emphasis on the same words, word for word.
    func testUEBWritesAndReadsBackEveryCarriedEmphasis() throws {
        let sentence = "one cat sat on the mat in the sun today"
        let marked = emphasized(sentence, [
            (4..<7, .italic),              // cat
            (8..<11, .bold),               // sat
            (12..<14, [.italic, .bold]),   // on
            (19..<22, .underline),         // mat
            (23..<25, .script),            // in
            (26..<29, .transcriber),       // the (the second)
        ])
        let passage = emphasized("plain then three bold words and plain", [(11..<27, .bold)])
        for table in ueb {
            let braille = try BrailleTranslator.translate([marked, passage], table: table, direction: .printToBraille, workingIn: work)
            XCTAssertEqual(braille.count, 2)
            guard braille.count == 2 else { continue }
            // Braille holds its emphasis in its cells, and carries none.
            XCTAssertFalse(braille.contains { $0.hasEmphasis }, table)
            XCTAssertTrue(braille[0].text.contains("\u{2828}\u{2802}"), "the italic word indicator, \(table)")
            XCTAssertTrue(braille[1].text.contains("\u{2818}\u{2836}"), "the bold passage indicator, \(table)")
            XCTAssertTrue(braille[1].text.contains("\u{2818}\u{2804}"), "the bold terminator, \(table)")

            let back = try BrailleTranslator.translate(braille, table: table, direction: .brailleToPrint, workingIn: work)
            XCTAssertEqual(back.map(\.text), [sentence, "plain then three bold words and plain"], table)
            guard back.count == 2 else { continue }
            XCTAssertEqual(wordEmphasis(back[0]), wordEmphasis(marked), table)
            XCTAssertEqual(wordEmphasis(back[1]), wordEmphasis(passage), table)
        }
        assertWorkFolderEmpty()
    }

    /// EBAE writes emphasis its own way: the italic sign (dots 4-6) before
    /// an italic word, the bold sign (dots 4-5-6, 4-6) before a bold one,
    /// and for a passage of four words or more the doubled sign before its
    /// first word and the single one before its last. liblouis 3.39.0
    /// cannot read EBAE's emphasis back (its "before" closing sign shares
    /// the word sign's cells), so the helper reports none: the words come
    /// back with no emphasis. And liblouis's own reading of the italic
    /// sign alone is a period, pinned here by name: "a .cat sat".
    func testEBAEWritesItsOwnSignsAndReadsNoneBack() throws {
        let sentence = emphasized("a cat sat", [(2..<5, .italic)])
        let bold = emphasized("a cat sat", [(2..<5, .bold)])
        let passage = emphasized("one two three four five", [(0..<18, .italic)])
        for table in ebae {
            let braille = try BrailleTranslator.translate([sentence, bold, passage], table: table, direction: .printToBraille, workingIn: work)
            XCTAssertEqual(braille.count, 3)
            guard braille.count == 3 else { continue }
            XCTAssertTrue(BrailleCells.spaced(braille[0].text).contains(" \u{2828}\u{2809}"), "the italic sign, \(table)")
            XCTAssertTrue(BrailleCells.spaced(braille[1].text).contains(" \u{2838}\u{2828}\u{2809}"), "the bold sign, \(table)")
            XCTAssertTrue(braille[2].text.hasPrefix("\u{2828}\u{2828}"), "the doubled italic sign, \(table)")

            let back = try BrailleTranslator.translate(braille, table: table, direction: .brailleToPrint, workingIn: work)
            XCTAssertFalse(back.contains { $0.hasEmphasis }, table)
            XCTAssertEqual(back.first?.text, "a .cat sat", table)
            XCTAssertEqual(back.dropFirst().first?.text, "a cat sat", table)
        }
        assertWorkFolderEmpty()
    }

    /// Text with no emphasis translates exactly as it did in protocol 1: the
    /// helper gives liblouis no typeform array for it, so the Grade 2
    /// sample's lines still give its rows (as `BrailleTranslatorTests`
    /// pins with the words-only form), and the emphasized form agrees.
    func testTextWithNoEmphasisTranslatesAsBefore() throws {
        let lines = ["The quick brown fox jumps over the lazy dog.", "Knowledge and understanding."]
        let words = try BrailleTranslator.translate(lines, table: "en-ueb-g2.ctb", direction: .printToBraille, workingIn: work)
        let emphasized = try BrailleTranslator.translate(
            lines.map { EmphasizedText($0) }, table: "en-ueb-g2.ctb", direction: .printToBraille, workingIn: work
        )
        XCTAssertEqual(emphasized.map(\.text), words)
        XCTAssertFalse(emphasized.contains { $0.hasEmphasis })
        assertWorkFolderEmpty()
    }

    /// An italic passage longer than a piece is cut at a word break and
    /// sent as pieces, each with its own emphasis, so liblouis writes each
    /// piece as a passage of its own, opened by UEB's italic passage
    /// indicator ⠨⠶ and closed by its terminator ⠨⠄.
    func testAnItalicPassageCutIntoPiecesIsWrittenAsOnePassageAPiece() throws {
        let words = Array(repeating: "truth", count: 1_500).joined(separator: " ")
        let count = words.unicodeScalars.count
        let pieces = BrailleTranslator.pieces(of: emphasized(words, [(0..<count, .italic)]), direction: .printToBraille)
        XCTAssertEqual(pieces.count, 3)
        XCTAssertTrue(pieces.allSatisfy { $0.emphasis == Array(repeating: .italic, count: $0.text.unicodeScalars.count) })

        let braille = try BrailleTranslator.translate(
            [emphasized(words, [(0..<count, .italic)])], table: "en-ueb-g1.ctb", direction: .printToBraille, workingIn: work
        )
        let cells = try XCTUnwrap(braille.first?.text)
        XCTAssertEqual(cells.components(separatedBy: "\u{2828}\u{2836}").count - 1, 3, "one passage indicator a piece")
        XCTAssertEqual(cells.components(separatedBy: "\u{2828}\u{2804}").count - 1, 3, "one terminator a piece")
        XCTAssertTrue(cells.hasPrefix("\u{2828}\u{2836}"))
        XCTAssertTrue(cells.hasSuffix("\u{2828}\u{2804}"))
        assertWorkFolderEmpty()
    }

    /// The pieces of an emphasized text keep each scalar's emphasis through
    /// the preparation: a line break becomes a word break with its own
    /// emphasis, a CR LF one break with the CR's, and a NUL goes with its
    /// emphasis; a piece whose scalars have none keeps no array.
    func testPreparationKeepsEachScalarsEmphasisInStep() throws {
        let text = try XCTUnwrap(EmphasizedText("a\r\nb\u{0}c\nd", emphasis: [.italic, .bold, .bold, .italic, .script, .italic, .underline, []]))
        let prepared = BrailleTranslator.prepared(text, direction: .printToBraille)
        XCTAssertEqual(String(String.UnicodeScalarView(prepared.scalars)), "a bc d")
        XCTAssertEqual(prepared.emphasis, [.italic, .bold, .italic, .italic, .underline, []])
        XCTAssertEqual(
            BrailleTranslator.pieces(of: text, direction: .printToBraille),
            [.init(text: "a bc d", emphasis: [.italic, .bold, .italic, .italic, .underline, []], endsAtBreak: false)]
        )
        XCTAssertEqual(
            BrailleTranslator.pieces(of: EmphasizedText("plain"), direction: .printToBraille),
            [.init(text: "plain", endsAtBreak: false)]
        )
    }
}
