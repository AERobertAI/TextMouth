import os
import XCTest
@testable import TextMouth

/// Tests for `BrailleTranslator` (FMT21): the paragraphs of the format
/// samples translated by the real helper in both directions, and the
/// helper's failures, its stops, and Cancel simulated by stand-in children
/// (`sleep`, `false`) with tight limits. Every call must leave its working
/// folder empty.
final class BrailleTranslatorTests: XCTestCase {
    /// The folder the helper's hidden files are made in; every call must
    /// leave it empty.
    private var work = URL(fileURLWithPath: "/var/empty", isDirectory: true)  // replaced in setUp

    override func setUpWithError() throws {
        work = try makeSandboxDirectory("BrailleWork")
    }

    // MARK: - Helpers

    /// Asserts that the working folder holds nothing, hidden files included.
    private func assertWorkFolderEmpty(file: StaticString = #filePath, line: UInt = #line) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? ["<unreadable>"]
        XCTAssertEqual(names, [], file: file, line: line)
    }

    /// `texts` translated with the real helper, then the working folder
    /// checked for leftovers.
    private func translate(
        _ texts: [String],
        _ table: String,
        _ direction: BrailleTranslator.Direction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String] {
        defer { assertWorkFolderEmpty(file: file, line: line) }
        return try BrailleTranslator.translate(texts, table: table, direction: direction, workingIn: work)
    }

    /// The cells braille ASCII `ascii` stands for (a space is the blank cell).
    private func cells(_ ascii: String) throws -> String {
        var result = String.UnicodeScalarView()
        for byte in ascii.utf8 {
            result.append(try XCTUnwrap(BrailleCells.cell(forASCII: byte), "no cell for byte \(byte)"))
        }
        return String(result)
    }

    /// The text of the format sample at `path`, read from a copy of it.
    private func sampleText(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: copyOfFormatSample(path)), as: UTF8.self)
    }

    /// The Grade 1 sample's 14 lines in braille ASCII (title, heading, 12
    /// paragraphs), split at CR LF.
    private func brlLines() throws -> [String] {
        let lines = try sampleText("brl/pride-and-prejudice-ch1-grade1.brl").components(separatedBy: "\r\n")
        return Array(lines.dropLast(lines.last == "" ? 1 : 0))  // the empty string after the last CR LF
    }

    /// The Grade 1 sample's 14 print blocks, split at blank lines.
    private func printBlocks() throws -> [String] {
        try sampleText("brf/pride-and-prejudice-ch1.txt")
            .trimmingCharacters(in: .newlines)
            .components(separatedBy: "\n\n")
    }

    /// The Grade 2 sample's three rows in braille ASCII, the first three
    /// lines of its BRF.
    private func grade2Rows() throws -> [String] {
        let lines = try sampleText("brf/grade2-short.brf").components(separatedBy: "\r\n")
        XCTAssertGreaterThanOrEqual(lines.count, 3)
        return Array(lines.prefix(3))
    }

    /// The Grade 2 sample's three print lines.
    private func grade2Lines() throws -> [String] {
        let lines = try sampleText("brf/grade2-short.txt").components(separatedBy: "\n")
        return Array(lines.dropLast(lines.last == "" ? 1 : 0))  // the empty string after the last LF
    }

    /// Limits that keep a test short: the watchdog looks every 0.1 second.
    private func limits(seconds: TimeInterval = 5) -> WatchedProcess.Limits {
        WatchedProcess.Limits(
            maximumSeconds: seconds, maximumResidentBytes: 1 << 30, maximumStalledSeconds: seconds, pollInterval: 0.1
        )
    }

    /// A stand-in tool whose child is `executable` with `arguments`, or no
    /// child at all (no helper) when `executable` is nil.
    private func standIn(_ executable: String?, _ arguments: [String] = [], seconds: TimeInterval = 5) -> BrailleTranslator.Tool {
        let limits = limits(seconds: seconds)
        return BrailleTranslator.Tool(
            command: { _, _, _, _ in executable.map { (URL(fileURLWithPath: $0), arguments) } },
            limits: { _, _ in limits },
            residentMemory: { _ in nil },
            tablesFolder: nil
        )
    }

    /// Runs `body` with `tool` standing in for the helper.
    private func with<T>(_ tool: BrailleTranslator.Tool, _ body: () throws -> T) throws -> T {
        try BrailleTranslator.$tool.withValue(tool, operation: body)
    }

    // MARK: - Grade 1 and Grade 2 With the Real Helper

    /// Grade 1, braille to print: the 14 BRL lines give the 14 print
    /// blocks, but for two differences that are liblouis's own.
    func testGrade1BrailleToPrint() throws {
        let braille = try brlLines().map(cells)
        let expected = try printBlocks()
        XCTAssertEqual(braille.count, 14)
        XCTAssertEqual(expected.count, 14)
        let result = try translate(braille, "en-ueb-g1.ctb", .brailleToPrint)
        XCTAssertEqual(result.count, 14)
        guard result.count == 14, expected.count == 14 else { return }

        // First difference: UEB writes both curly double quotes with cells
        // that liblouis reads back as the straight quote ", so the print
        // text is compared with its curly quotes made straight.
        // Second: the print's _You_ (Project Gutenberg's mark for italics)
        // comes back as You, since liblouis reads UEB's italic word
        // indicator as emphasis, which this form of `translate` drops (the
        // emphasized form keeps it: `BrailleHelperProtocolTests`): block 10
        // (1-based) is compared with _You_ replaced by You.
        for (index, block) in expected.enumerated() {
            var print = block.replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
            if index == 9 {
                XCTAssertTrue(print.contains("_You_"), "block 10 should hold the italic word")
                print = print.replacingOccurrences(of: "_You_", with: "You")
            }
            XCTAssertEqual(result[index], print, "block \(index + 1)")
        }
        for block in result {
            XCTAssertFalse(block.contains("\u{201C}") || block.contains("\u{201D}"), block)
            // liblouis writes a cell it could not read as a backslash escape.
            XCTAssertFalse(block.contains("\\"), block)
        }
    }

    /// Grade 2, braille to print: the three rows give the three lines exactly.
    func testGrade2BrailleToPrint() throws {
        let rows = try grade2Rows().map(cells)
        XCTAssertEqual(try translate(rows, "en-ueb-g2.ctb", .brailleToPrint), try grade2Lines())
    }

    /// Grade 2, print to braille: the three lines give the three rows exactly.
    func testGrade2PrintToBraille() throws {
        let rows = try grade2Rows().map(cells)
        XCTAssertEqual(try translate(try grade2Lines(), "en-ueb-g2.ctb", .printToBraille), rows)
    }

    /// Grade 1, print to braille: the 14 print blocks give the BRL lines
    /// with exactly two kinds of difference, both from the prototype that
    /// wrote the sample.
    func testGrade1PrintToBraille() throws {
        // First: a question mark at a word's end is the cell for 8 alone in
        // liblouis (its postpunc rule), where the sample has ;8 (three
        // times). Second: the underscores of _You_ are characters to
        // liblouis, each written as the underscore sign (.-), where the
        // sample has the italic word indicator (.1) before the word.
        let expected = try brlLines().map {
            $0.replacingOccurrences(of: ";8", with: "8").replacingOccurrences(of: ".1,YOU", with: ".-,YOU.-")
        }.map(cells)
        let blocks = try printBlocks()
        XCTAssertEqual(blocks.count, 14)
        let result = try translate(blocks, "en-ueb-g1.ctb", .printToBraille)
        XCTAssertEqual(result.count, 14)
        guard result.count == 14, expected.count == 14 else { return }
        for index in 0..<14 {
            XCTAssertEqual(
                BrailleCells.spaced(result[index]), BrailleCells.spaced(expected[index]), "block \(index + 1)"
            )
        }
    }

    // MARK: - Characters a Table Lacks

    /// The cells liblouis writes for the one character `character`, which
    /// the table lacks: its escape notation, forward with Grade 2.
    private func escape(of character: String) throws -> String {
        let escape = try XCTUnwrap(try translate([character], "en-ueb-g2.ctb", .printToBraille).first)
        // An escape is several cells; one cell would mean the table has the character.
        XCTAssertGreaterThan(escape.unicodeScalars.count, 1, character)
        return escape
    }

    /// Forward output is never silently cut (review finding M1). When the
    /// output fills its room on characters the table lacks, liblouis reports
    /// success, says it used all the input, and cuts the output: 100 emoji
    /// at the helper's first room (864 cells) gave 864 of their 900 cells.
    /// The helper now asks for more room until 16 cells are spare, so every
    /// run here gives one escape for each character.
    func testForwardOutputForCharactersATableLacksIsNeverCut() throws {
        let emoji = "\u{1F600}"
        let emojiEscape = try escape(of: emoji)
        let cjkEscape = try escape(of: "\u{4E2D}")
        let party = try XCTUnwrap(try translate(["Party time"], "en-ueb-g2.ctb", .printToBraille).first)

        // 100 emoji; words and then 160 emoji; 20 CJK characters (liblouis
        // reported all 20 used at a room of 64 cells, and cut the output).
        let result = try translate(
            [
                String(repeating: emoji, count: 100),
                "Party time " + String(repeating: emoji, count: 160),
                String(repeating: "\u{4E2D}", count: 20),
            ],
            "en-ueb-g2.ctb", .printToBraille
        )
        XCTAssertEqual(result.count, 3)
        guard result.count == 3 else { return }
        XCTAssertEqual(result[0], String(repeating: emojiEscape, count: 100))
        XCTAssertEqual(result[1], party + "\u{2800}" + String(repeating: emojiEscape, count: 160))
        XCTAssertEqual(result[2], String(repeating: cjkEscape, count: 20))
    }

    /// A paragraph of 4,000 control characters, which liblouis writes as
    /// escapes 24 times as long as the input in bytes, translates: it needs
    /// more room than the helper's first, and is not a failure.
    func testAParagraphOfControlCharactersTranslates() throws {
        let control = "\u{1}"
        let controlEscape = try escape(of: control)
        let result = try translate([String(repeating: control, count: 4_000)], "en-ueb-g2.ctb", .printToBraille)
        XCTAssertEqual(result, [String(repeating: controlEscape, count: 4_000)])
    }

    /// Cyrillic, which no table has, translates forward with Grade 2: each
    /// letter becomes an escape, the output is 11 times the input's bytes,
    /// and that is above the old output cap (10 times plus 1 MiB) once the
    /// input passes half a megabyte (review finding L3). 600 KB of unbroken
    /// letters, cut into 75 pieces, is such an input.
    func testLargeCyrillicTranslatesForward() throws {
        let letter = "\u{436}"
        let letterEscape = try escape(of: letter)
        let letters = 300_000
        let result = try translate([String(repeating: letter, count: letters)], "en-ueb-g2.ctb", .printToBraille)
        XCTAssertEqual(result.count, 1)
        guard result.count == 1 else { return }
        XCTAssertEqual(result[0].unicodeScalars.count, letters * letterEscape.unicodeScalars.count)
    }

    // MARK: - Tables

    /// Every table the app offers loads: the four of the catalog.
    func testEveryTableChecks() throws {
        let offered = ["en-ueb-g1.ctb", "en-ueb-g2.ctb", "en-us-g1.ctb", "en_US.tbl"]
        XCTAssertEqual(Set(BrailleTableCatalog.bundled.map(\.id)), Set(offered))
        for table in offered {
            XCTAssertNoThrow(try BrailleTranslator.check(table: table, workingIn: work), table)
            assertWorkFolderEmpty()
        }
    }

    /// A table the bundle lacks, and a name that is not a bare file name,
    /// throw `unknownTable`, with its sentence, from translate and from check.
    func testUnknownTablesThrow() throws {
        for table in ["en-xx.ctb", "../en-ueb-g1.ctb", "", ".hidden.ctb", "en-ueb-g1.ctb,en-ueb-g2.ctb", "a/b.ctb"] {
            XCTAssertThrowsError(try translate(["⠁"], table, .brailleToPrint), table) {
                XCTAssertEqual($0 as? BrailleTranslator.Failure, .unknownTable(table))
            }
            XCTAssertThrowsError(try BrailleTranslator.check(table: table, workingIn: work), table) {
                XCTAssertEqual($0 as? BrailleTranslator.Failure, .unknownTable(table))
            }
            assertWorkFolderEmpty()
        }
        XCTAssertEqual(
            BrailleTranslator.Failure.unknownTable("en-xx.ctb").errorDescription,
            "TextMouth has no braille table named \u{201C}en-xx.ctb\u{201D}."
        )
    }

    /// A file of the tables folder that the catalog does not offer is
    /// refused by name, from translate and from check (review finding L2):
    /// an edited record naming an include file such as `spaces.uti` would
    /// otherwise load it, and the book would read as liblouis escapes. The
    /// files exist in the bundle, so only the catalog refuses them; the
    /// stand-in that would leave a marker is never started.
    func testFilesOfTheTablesFolderThatTheCatalogLacksAreRefused() throws {
        let tables = try XCTUnwrap(BrailleTranslator.Tool.helper.tablesFolder)
        let marker = work.appendingPathComponent("marker")
        let spy = standIn("/usr/bin/touch", [marker.path])
        try with(spy) {
            for table in ["spaces.uti", "en-ueb-chardefs.uti", "en-us-compbrl.uti"] {
                XCTAssertTrue(FileManager.default.fileExists(atPath: tables.appendingPathComponent(table).path), table)
                XCTAssertNil(BrailleTableCatalog.table(withID: table), table)
                XCTAssertThrowsError(try translate(["⠁"], table, .brailleToPrint), table) {
                    XCTAssertEqual($0 as? BrailleTranslator.Failure, .unknownTable(table))
                }
                XCTAssertThrowsError(try BrailleTranslator.check(table: table, workingIn: work), table) {
                    XCTAssertEqual($0 as? BrailleTranslator.Failure, .unknownTable(table))
                }
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        // With the real tool the answer is the same, and the sentence is the
        // unknown-table one.
        for table in ["spaces.uti", "en-ueb-chardefs.uti"] {
            XCTAssertThrowsError(try translate(["⠁"], table, .brailleToPrint), table) {
                XCTAssertEqual(
                    ($0 as? LocalizedError)?.errorDescription,
                    "TextMouth has no braille table named \u{201C}\(table)\u{201D}."
                )
            }
            XCTAssertThrowsError(try BrailleTranslator.check(table: table, workingIn: work), table) {
                XCTAssertEqual($0 as? BrailleTranslator.Failure, .unknownTable(table))
            }
        }
        assertWorkFolderEmpty()
    }

    /// A malformed table name never starts the helper, even with no work to
    /// check it on: a stand-in that would leave a marker does not run.
    func testAMalformedTableNameStartsNothing() throws {
        let marker = work.appendingPathComponent("marker")
        let spy = standIn("/usr/bin/touch", [marker.path])
        try with(spy) {
            XCTAssertThrowsError(try BrailleTranslator.translate(["a"], table: "../x", direction: .printToBraille, workingIn: work))
            XCTAssertThrowsError(try BrailleTranslator.check(table: "", workingIn: work))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    // MARK: - A Comma in the Bundle's Path

    /// The real helper, on a copy of the bundle's tables folder at
    /// `<sandbox>/Apps, old/tables` (review finding L1). liblouis splits a
    /// table list and LOUIS_TABLEPATH at commas, so a path holding one broke
    /// every table; the helper now loads a table by its bare name from
    /// inside its folder. `check` passes and the Grade 2 sample's rows give
    /// its print, which also shows that translating still works once the
    /// helper has left the folder (liblouis keeps the loaded table by name).
    func testTheHelperWorksFromAFolderWhoseNameHoldsAComma() throws {
        let bundled = try XCTUnwrap(BrailleTranslator.Tool.helper.tablesFolder)
        let parent = try makeSandboxDirectory("BrailleComma").appendingPathComponent("Apps, old", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let tables = parent.appendingPathComponent("tables", isDirectory: true)
        try FileManager.default.copyItem(at: bundled, to: tables)
        XCTAssertTrue(tables.path.contains(","), tables.path)

        // The real executable, pointed at the copy instead of the bundle's folder.
        let executable = try XCTUnwrap(Bundle.main.url(forAuxiliaryExecutable: "TextMouthBraille"))
        let tool = BrailleTranslator.Tool(
            command: { mode, table, input, output in
                (executable, [mode, tables.path, table] + [input, output].compactMap { $0?.path })
            },
            limits: { BrailleTranslator.limits(for: $0, bytes: $1) },
            residentMemory: { WatchedProcess.residentMemory(of: $0) },
            tablesFolder: tables
        )
        try with(tool) {
            XCTAssertNoThrow(try BrailleTranslator.check(table: "en-ueb-g2.ctb", workingIn: work))
            let rows = try grade2Rows().map(cells)
            XCTAssertEqual(try translate(rows, "en-ueb-g2.ctb", .brailleToPrint), try grade2Lines())
        }
        assertWorkFolderEmpty()
    }

    // MARK: - Long Texts and Line Breaks

    /// A long text is cut at its blank cells and put together again: 2,000
    /// words each way, and 9,000 cells with no break, cut mid-word and
    /// joined with nothing.
    func testLongTextsAreCutAndJoined() throws {
        let truthCells = "⠞⠗⠥⠞⠓"
        let braille = Array(repeating: truthCells, count: 2_000).joined(separator: "\u{2800}")
        XCTAssertEqual(braille.unicodeScalars.count, 11_999)
        let back = try translate([braille], "en-ueb-g1.ctb", .brailleToPrint)
        XCTAssertEqual(back, [Array(repeating: "truth", count: 2_000).joined(separator: " ")])

        let print = Array(repeating: "truth", count: 3_000).joined(separator: " ")
        let forward = try translate([print], "en-ueb-g1.ctb", .printToBraille)
        XCTAssertEqual(forward, [Array(repeating: truthCells, count: 3_000).joined(separator: "\u{2800}")])

        let unbroken = String(repeating: "⠁", count: 9_000)
        XCTAssertEqual(try translate([unbroken], "en-ueb-g1.ctb", .brailleToPrint), [String(repeating: "a", count: 9_000)])
    }

    /// Line breaks inside a text are one word break each.
    func testLineBreaksInsideATextAreWordBreaks() throws {
        let spaced = try translate(["one two"], "en-ueb-g1.ctb", .printToBraille)
        XCTAssertEqual(try translate(["one\ntwo"], "en-ueb-g1.ctb", .printToBraille), spaced)
        XCTAssertEqual(try translate(["one\r\ntwo"], "en-ueb-g1.ctb", .printToBraille), spaced)
        let blank = try translate(["⠁\u{2800}⠃"], "en-ueb-g1.ctb", .brailleToPrint)
        XCTAssertEqual(try translate(["⠁\n⠃"], "en-ueb-g1.ctb", .brailleToPrint), blank)
        XCTAssertEqual(blank, ["a b"])
    }

    /// Empty texts among others come back empty and in place, and the
    /// others are still translated.
    func testEmptyTextsAmongOthersKeepTheirPlaces() throws {
        XCTAssertEqual(try translate(["", "⠁", ""], "en-ueb-g1.ctb", .brailleToPrint), ["", "a", ""])
    }

    /// 3,000 texts of every kind, long ones cut at a break, unbroken ones cut
    /// mid-word, short ones, and empty ones, still join exactly as they did
    /// when the input was made whole in memory (E5). The input is some 9 MB,
    /// so the buffer it is written through is flushed several times.
    func testThreeThousandMixedTextsStillJoinExactly() throws {
        let truthCells = "\u{281E}\u{2817}\u{2825}\u{281E}\u{2813}"
        var texts: [String] = []
        var expected: [String] = []
        for index in 0..<3_000 {
            switch index % 10 {
            case 0:
                // 900 words, 5,399 cells: two pieces, cut at a blank cell.
                texts.append(Array(repeating: truthCells, count: 900).joined(separator: "\u{2800}"))
                expected.append(Array(repeating: "truth", count: 900).joined(separator: " "))
            case 5:
                // 4,500 cells with no break: two pieces, cut mid-word.
                texts.append(String(repeating: "\u{2801}", count: 4_500))
                expected.append(String(repeating: "a", count: 4_500))
            case 3:
                texts.append("")
                expected.append("")
            default:
                texts.append("\u{2801}\u{2800}\u{2803}")
                expected.append("a b")
            }
        }
        let result = try translate(texts, "en-ueb-g1.ctb", .brailleToPrint)
        XCTAssertEqual(result.count, expected.count)
        // One assertion for the whole list, so a failure prints no 3,000 lines.
        XCTAssertTrue(result == expected, "the joined translations differ from the expected ones")
    }

    /// The input file holds the protocol's header and then every piece's
    /// record (its text, a line feed, and the empty code line of a piece with
    /// no emphasis), written through a buffer, and the size the watchdog's
    /// limits are drawn from is the file's exact size (E5). A stand-in that
    /// copies its input to its output, which is then a well-formed output,
    /// also shows the pieces come back in order and join to the texts.
    func testTheInputIsWrittenPieceByPieceAndSizedExactly() throws {
        let word = "\u{281E}\u{2817}\u{2825}\u{281E}\u{2813}"
        let long = Array(repeating: word, count: 900).joined(separator: "\u{2800}")
        // 200 long texts of about 16 KB each, with short and empty ones among them.
        let texts = (0..<600).map { $0 % 3 == 0 ? long : ($0 % 3 == 1 ? "\u{2801}\u{2803}" : "") }
        let header = Int64(BrailleEmphasis.protocolHeader.utf8.count) + 1
        let expectedBytes = texts
            .flatMap { BrailleTranslator.pieces(of: $0, direction: .brailleToPrint) }
            .reduce(header) { $0 + Int64($1.text.utf8.count) + 2 }
        XCTAssertGreaterThan(expectedBytes, 2 * Int64(1_048_576), "the input should pass the buffer's size twice")

        // What the stand-in saw of the input file, and what the limits were asked for.
        let fileSize = OSAllocatedUnfairLock<Int64>(initialState: -1)
        let limitBytes = OSAllocatedUnfairLock<Int64>(initialState: -1)
        let allowed = limits(seconds: 20)
        let tool = BrailleTranslator.Tool(
            command: { _, _, input, output in
                guard let input, let output else { return nil }
                let attributes = try? FileManager.default.attributesOfItem(atPath: input.path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? -2
                fileSize.withLock { $0 = size }
                return (URL(fileURLWithPath: "/bin/cp"), [input.path, output.path])
            },
            limits: { _, bytes in
                limitBytes.withLock { $0 = bytes }
                return allowed
            },
            residentMemory: { _ in nil },
            tablesFolder: nil
        )
        let result = try with(tool) {
            try BrailleTranslator.translate(texts, table: "en-ueb-g1.ctb", direction: .brailleToPrint, workingIn: work)
        }
        XCTAssertEqual(fileSize.withLock { $0 }, expectedBytes)
        XCTAssertEqual(limitBytes.withLock { $0 }, expectedBytes)

        // Copied pieces, joined: the only difference from a text is a space
        // where a cut dropped a blank cell, which was put back as a space.
        XCTAssertEqual(result.count, texts.count)
        let rejoined = result.map { $0.replacingOccurrences(of: " ", with: "\u{2800}") }
        XCTAssertTrue(rejoined == texts, "the copied pieces do not join to the texts")
        XCTAssertTrue(result.contains { $0.contains(" ") }, "no long text was cut")
        assertWorkFolderEmpty()
    }

    /// The preparation of a text: every line break one word break, NUL
    /// gone, and in braille an ASCII space the blank cell.
    func testPreparationOfATextForTheHelper() {
        let breaks = "a\r\nb\rc\nd\u{85}e\u{2028}f\u{2029}g\u{0}h"
        XCTAssertEqual(
            String(String.UnicodeScalarView(BrailleTranslator.prepared(breaks, direction: .printToBraille))),
            "a b c d e f gh"
        )
        XCTAssertEqual(
            String(String.UnicodeScalarView(BrailleTranslator.prepared("⠁ ⠃\n⠉\r\n⠙", direction: .brailleToPrint))),
            "⠁\u{2800}⠃\u{2800}⠉\u{2800}⠙"
        )
        // A CR then an LF is one break; two LFs are two.
        XCTAssertEqual(BrailleTranslator.prepared("\r\n\n", direction: .printToBraille).count, 2)
    }

    /// Where a long text is cut: at the last break within 4,000 scalars,
    /// the break dropped; mid-word when there is none.
    func testPiecesAreCutAtTheLastBreakWithinTheLimit() {
        let limit = BrailleTranslator.maximumPieceScalars
        XCTAssertEqual(limit, 4_000)
        XCTAssertEqual(BrailleTranslator.pieces(of: "", direction: .printToBraille), [])

        // A text of exactly the limit is one piece; a break stays inside it.
        let whole = String(repeating: "a", count: limit)
        XCTAssertEqual(BrailleTranslator.pieces(of: whole, direction: .printToBraille), [.init(text: whole, endsAtBreak: false)])

        // A break just past the limit's first 4,000 scalars (index 4,000) is a cut.
        let atLimit = whole + " bb"
        XCTAssertEqual(
            BrailleTranslator.pieces(of: atLimit, direction: .printToBraille),
            [.init(text: whole, endsAtBreak: true), .init(text: "bb", endsAtBreak: false)]
        )

        // The last break within the limit is the cut.
        let early = String(repeating: "a", count: 10) + " " + String(repeating: "b", count: limit)
        XCTAssertEqual(
            BrailleTranslator.pieces(of: early, direction: .printToBraille),
            [.init(text: String(repeating: "a", count: 10), endsAtBreak: true), .init(text: String(repeating: "b", count: limit), endsAtBreak: false)]
        )

        // With no break, the cut is at the limit, mid-word.
        let unbroken = String(repeating: "a", count: limit + 5)
        XCTAssertEqual(
            BrailleTranslator.pieces(of: unbroken, direction: .printToBraille),
            [.init(text: whole, endsAtBreak: false), .init(text: "aaaaa", endsAtBreak: false)]
        )

        // A break only at the very start makes no empty piece.
        let leading = " " + String(repeating: "a", count: limit + 5)
        let pieces = BrailleTranslator.pieces(of: leading, direction: .printToBraille)
        XCTAssertEqual(pieces.map(\.text.unicodeScalars.count), [limit, 6])
        XCTAssertFalse(pieces.contains { $0.text.isEmpty })

        // In braille the break is the blank cell.
        let braille = String(repeating: "⠁", count: limit) + "\u{2800}⠃"
        XCTAssertEqual(
            BrailleTranslator.pieces(of: braille, direction: .brailleToPrint).map(\.endsAtBreak), [true, false]
        )
    }

    // MARK: - No Work, Failures, Stops, and Cancel

    /// An empty list, and a list of empty texts, run no helper: a stand-in
    /// that fails would have thrown.
    func testNoWorkRunsNothing() throws {
        let failing = standIn("/usr/bin/false")
        try with(failing) {
            XCTAssertEqual(
                try BrailleTranslator.translate([] as [String], table: "en-ueb-g1.ctb", direction: .printToBraille, workingIn: work), []
            )
            XCTAssertEqual(
                try BrailleTranslator.translate([] as [EmphasizedText], table: "en-ueb-g1.ctb", direction: .printToBraille, workingIn: work),
                []
            )
            XCTAssertEqual(
                try BrailleTranslator.translate(["", ""], table: "en-ueb-g1.ctb", direction: .brailleToPrint, workingIn: work),
                ["", ""]
            )
            // Texts that hold only NULs are empty too.
            XCTAssertEqual(
                try BrailleTranslator.translate(["\u{0}"], table: "en-ueb-g1.ctb", direction: .printToBraille, workingIn: work),
                [""]
            )
        }
        assertWorkFolderEmpty()
    }

    /// A helper the watchdog stops throws `stopped`, with the reason in words.
    func testAHungHelperIsStopped() throws {
        let hung = standIn("/bin/sleep", ["30"], seconds: 1)
        let childrenBefore = WatchedProcess.runningChildCount
        try with(hung) {
            XCTAssertThrowsError(
                try BrailleTranslator.translate(["a"], table: "en-ueb-g1.ctb", direction: .printToBraille, workingIn: work)
            ) {
                XCTAssertEqual($0 as? BrailleTranslator.Failure, .stopped(reason: "it ran longer than 1 second"))
                XCTAssertEqual(
                    ($0 as? LocalizedError)?.errorDescription,
                    "TextMouth stopped the braille translation because it ran longer than 1 second."
                )
            }
        }
        XCTAssertEqual(WatchedProcess.runningChildCount, childrenBefore)
        assertWorkFolderEmpty()
    }

    /// A helper that fails, a helper that cannot start, and a missing
    /// helper all throw `failed`, in translate and in check.
    func testFailuresAreFailed() throws {
        let tools = [standIn("/usr/bin/false"), standIn("/nonexistent/helper"), standIn(nil)]
        for tool in tools {
            try with(tool) {
                XCTAssertThrowsError(
                    try BrailleTranslator.translate(["a"], table: "en-ueb-g1.ctb", direction: .printToBraille, workingIn: work)
                ) {
                    XCTAssertEqual($0 as? BrailleTranslator.Failure, .failed)
                    XCTAssertEqual(
                        ($0 as? LocalizedError)?.errorDescription, "TextMouth could not translate this braille."
                    )
                }
                XCTAssertThrowsError(try BrailleTranslator.check(table: "en-ueb-g1.ctb", workingIn: work)) {
                    XCTAssertEqual($0 as? BrailleTranslator.Failure, .failed)
                }
            }
            assertWorkFolderEmpty()
        }
    }

    /// A helper that exits 0 without writing the lines it should is a
    /// failure, not a translation.
    func testOutputOfTheWrongLengthIsFailed() throws {
        // `true` exits 0 and writes no output file.
        try with(standIn("/usr/bin/true")) {
            XCTAssertThrowsError(
                try BrailleTranslator.translate(["a"], table: "en-ueb-g1.ctb", direction: .printToBraille, workingIn: work)
            ) {
                XCTAssertEqual($0 as? BrailleTranslator.Failure, .failed)
            }
        }
        assertWorkFolderEmpty()
    }

    /// A failed run writes one line to the debug log, naming the mode and
    /// the table, and never the text.
    func testAFailureLogsOneLineWithoutTheText() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let secret = "Quillwort"
        let lines = try logLines(in: .debug) {
            try with(standIn("/usr/bin/false")) {
                _ = try? BrailleTranslator.translate([secret], table: "en-ueb-g1.ctb", direction: .printToBraille, workingIn: work)
            }
        }
        let ours = lines.filter { $0.contains("BRAILLE_HELPER_") }
        XCTAssertEqual(ours.count, 1, "\(lines)")
        XCTAssertTrue(ours.first?.contains("BRAILLE_HELPER_FAILED: forward en-ueb-g1.ctb: exited with status 1") == true, "\(ours)")
        XCTAssertFalse(lines.contains { $0.contains(secret) })
    }

    /// A stopped run writes one KILLED line with the reason.
    func testAStopLogsOneLine() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let lines = try logLines(in: .debug) {
            try with(standIn("/bin/sleep", ["30"], seconds: 1)) {
                _ = try? BrailleTranslator.translate(["a"], table: "en-ueb-g2.ctb", direction: .brailleToPrint, workingIn: work)
            }
        }
        let ours = lines.filter { $0.contains("BRAILLE_HELPER_") }
        XCTAssertEqual(ours.count, 1, "\(lines)")
        XCTAssertTrue(
            ours.first?.contains("BRAILLE_HELPER_KILLED: back en-ueb-g2.ctb: it ran longer than 1 second") == true, "\(ours)"
        )
    }

    /// Cancelling the import kills the running helper at once and throws
    /// `ImportCancelled`.
    func testCancellingTheImportStopsTheHelper() throws {
        let hung = standIn("/bin/sleep", ["30"], seconds: 30)
        let childrenBefore = WatchedProcess.runningChildCount
        let cancellation = ImportCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { cancellation.cancel() }
        let started = Date()
        try ImportCancellation.$current.withValue(cancellation) {
            try with(hung) {
                XCTAssertThrowsError(
                    try BrailleTranslator.translate(["a"], table: "en-ueb-g1.ctb", direction: .printToBraille, workingIn: work)
                ) {
                    XCTAssertTrue($0 is ImportCancelled, "\($0)")
                }
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(WatchedProcess.runningChildCount, childrenBefore)
        assertWorkFolderEmpty()
    }

    // MARK: - Limits

    /// The limits follow the measurements written beside them.
    func testTheLimitsArePinned() {
        let tenMB: Int64 = 10_000_000
        let back = BrailleTranslator.limits(for: .brailleToPrint, bytes: tenMB)
        XCTAssertEqual(back.maximumSeconds, 12.5, accuracy: 0.0001)
        let forward = BrailleTranslator.limits(for: .printToBraille, bytes: tenMB)
        XCTAssertEqual(forward.maximumSeconds, 70, accuracy: 0.0001)
        let check = BrailleTranslator.limits(for: nil, bytes: 0)
        XCTAssertEqual(check.maximumSeconds, 10, accuracy: 0.0001)
        XCTAssertEqual(BrailleTranslator.limits(for: nil, bytes: 5_000_000).maximumSeconds, 10, accuracy: 0.0001)

        // The output cap: forward may grow 32 times (liblouis writes 11 times
        // the input for Cyrillic and 24 times for control characters), back
        // and check 10 times; each has 1 MiB besides.
        let caps: [(limits: WatchedProcess.Limits, bytes: Int64, growth: Int64)] = [
            (back, tenMB, 10), (forward, tenMB, 32), (check, 0, 10),
        ]
        for (limits, bytes, growth) in caps {
            XCTAssertEqual(limits.maximumStalledSeconds, limits.maximumSeconds)
            XCTAssertEqual(limits.maximumResidentBytes, 16 * 1_048_576)
            XCTAssertEqual(limits.maximumOutputBytes, growth * bytes + 1_048_576)
        }
        XCTAssertEqual(BrailleTranslator.limits(for: .printToBraille, bytes: 1_000).maximumOutputBytes, 32 * 1_000 + 1_048_576)
    }

    /// The real tool names the helper and the tables inside the app bundle.
    func testTheRealToolIsTheBundledHelper() throws {
        let tool = BrailleTranslator.Tool.helper
        let tables = try XCTUnwrap(tool.tablesFolder)
        XCTAssertTrue(tables.path.hasSuffix("Contents/Resources/liblouis/tables"), tables.path)
        let command = try XCTUnwrap(tool.command("check", "en-ueb-g1.ctb", nil, nil))
        XCTAssertEqual(command.executable.lastPathComponent, "TextMouthBraille")
        XCTAssertEqual(command.arguments, ["check", tables.path, "en-ueb-g1.ctb"])
        let input = URL(fileURLWithPath: "/tmp/in"), output = URL(fileURLWithPath: "/tmp/out")
        XCTAssertEqual(
            try XCTUnwrap(tool.command("back", "x.ctb", input, output)).arguments,
            ["back", tables.path, "x.ctb", "/tmp/in", "/tmp/out"]
        )
    }
}
