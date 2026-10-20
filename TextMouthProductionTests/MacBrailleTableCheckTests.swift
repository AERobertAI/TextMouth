import XCTest
@testable import TextMouth

/// The check one of this Mac's braille tables passes before TextMouth uses it
/// (October 20, 2026, decision 5): six-dot cells with liblouis's escape
/// backslash aside, the refusals stand-in helpers give, the verdicts a
/// session keeps, the translator refusing by name, and this Mac's real
/// French, German, Spanish, and Greek tables.
///
/// Every test binds verdicts of its own, so no stand-in's failure is kept
/// for a real table. The tests that need this Mac's folder skip, saying
/// why, on a Mac that has none. Nothing here touches the real preferences
/// store or plays sound.
final class MacBrailleTableCheckTests: XCTestCase {
    /// The folder the helper's hidden files are made in; every call must
    /// leave it empty.
    private var work = URL(fileURLWithPath: "/var/empty", isDirectory: true)  // replaced in setUp

    override func setUpWithError() throws {
        work = try makeSandboxDirectory("MacBrailleCheck")
    }

    // MARK: - Helpers

    /// Runs `body` with verdicts of its own and, when given, `tool` standing
    /// in for the helper.
    private func isolated<T>(tool: BrailleTranslator.Tool? = nil, _ body: () throws -> T) throws -> T {
        try MacBrailleTableCheck.$verdicts.withValue(MacBrailleTableCheck.Verdicts()) {
            guard let tool else { return try body() }
            return try BrailleTranslator.$tool.withValue(tool, operation: body)
        }
    }

    /// A stand-in helper that runs `/bin/sh -c script sh MODE OUTPUT`, with
    /// limits that keep a test short: `seconds` for each run.
    private func shell(_ script: String, seconds: TimeInterval = 5) -> BrailleTranslator.Tool {
        let limits = WatchedProcess.Limits(
            maximumSeconds: seconds, maximumResidentBytes: 1 << 30, maximumStalledSeconds: seconds, pollInterval: 0.1
        )
        return BrailleTranslator.Tool(
            command: { mode, _, _, output in
                (URL(fileURLWithPath: "/bin/sh"), ["-c", script, "sh", mode, output?.path ?? ""])
            },
            limits: { _, _ in limits },
            residentMemory: { _ in nil },
            tablesFolder: nil
        )
    }

    /// Asserts that the working folder holds nothing, hidden files included.
    private func assertWorkFolderEmpty(file: StaticString = #filePath, line: UInt = #line) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? ["<unreadable>"]
        XCTAssertEqual(names, [], file: file, line: line)
    }

    /// A table this Mac offers, for the stand-in tests, which need one the
    /// catalog accepts but never run it: one whose metadata says six dots
    /// when `declaringSixDots` is true, one with no dots line when it is
    /// false, and any when it is nil. Skips on a Mac with none.
    private func anyOfferedMacTable(declaringSixDots: Bool? = false) throws -> String {
        let table = BrailleTableCatalog.offeredTables.first { table in
            table.source == .mac && declaringSixDots.map { table.declaresSixDots == $0 } ?? true
        }
        guard let table else {
            throw XCTSkip("This Mac offers no such VoiceOver braille table (\(BrailleTableCatalog.macTablesFolder.path))")
        }
        return table.id
    }

    /// The Mac table `id`, when this Mac offers it; skips, saying why, when not.
    private func requireOffered(_ id: String) throws -> String {
        guard BrailleTableCatalog.table(withID: id) != nil else {
            throw XCTSkip("This Mac does not offer \(id) (\(BrailleTableCatalog.macTablesFolder.path))")
        }
        return id
    }

    // MARK: - Six Dots

    /// Six-dot cells pass, and so does liblouis's escape backslash; a cell
    /// with dot 7 or 8, and anything that is not braille, does not.
    func testSixDotCellsOnly() {
        XCTAssertEqual(BrailleCells.escapeBackslash, Unicode.Scalar(0x2873))
        XCTAssertTrue(MacBrailleTableCheck.writesSixDotsOnly(""))
        XCTAssertTrue(MacBrailleTableCheck.writesSixDotsOnly("\u{2801}\u{2803}\u{2800}\u{283F}"))
        XCTAssertTrue(MacBrailleTableCheck.writesSixDotsOnly("\u{2804}\u{2873}\u{282D}\u{2804}"))
        XCTAssertFalse(MacBrailleTableCheck.writesSixDotsOnly("\u{2801}\u{2843}"), "dot 7")
        XCTAssertFalse(MacBrailleTableCheck.writesSixDotsOnly("\u{2881}"), "dot 8")
        XCTAssertFalse(MacBrailleTableCheck.writesSixDotsOnly("\u{2801} "), "a space is no braille cell")
        XCTAssertEqual(
            MacBrailleTableCheck.sample,
            "Braille 2026, ABC abc: it\u{2019}s \u{2018}one\u{2019}, \u{201C}two\u{201D}, \u{201E}three\u{201C} and "
                + "\u{00AB}four\u{00BB} \u{2013} five \u{2014} six\u{2026} \u{2019} \u{2018} \u{201C} \u{201D} \u{201E} "
                + "\u{00AB} \u{00BB} \u{2013} \u{2014} \u{2026} 0123456789."
        )
    }

    /// The escape backslash is what liblouis really writes for a character
    /// a table lacks: the bundled Grade 2 table writes it for a Chinese
    /// character, and the check counts that as six-dot braille.
    func testTheEscapeBackslashIsLiblouisOwn() throws {
        let escape = try XCTUnwrap(try BrailleTranslator.translate(
            ["\u{4E2D}"], table: "en-ueb-g2.ctb", direction: .printToBraille, workingIn: work
        ).first)
        XCTAssertTrue(escape.unicodeScalars.contains(BrailleCells.escapeBackslash), escape)
        XCTAssertTrue(MacBrailleTableCheck.writesSixDotsOnly(escape))
        assertWorkFolderEmpty()
    }

    // MARK: - Verdicts

    /// Each refusal's reason, pinned; only a check that could not be made is
    /// not kept for the session.
    func testTheReasons() {
        XCTAssertEqual(MacBrailleTableCheck.Refusal.gone.reason, "this Mac no longer has it")
        XCTAssertEqual(MacBrailleTableCheck.Refusal.doesNotLoad.reason, "it does not load in TextMouth's liblouis 3.39.0")
        XCTAssertEqual(
            MacBrailleTableCheck.Refusal.writesEightDots.reason,
            "it writes eight-dot braille, and TextMouth uses six-dot braille only"
        )
        XCTAssertEqual(MacBrailleTableCheck.Refusal.helperFailed.reason, "the braille helper failed")
        XCTAssertEqual(MacBrailleTableCheck.Refusal.noWorkingFolder.reason, "TextMouth could not make a folder to check it in")
        XCTAssertEqual(
            MacBrailleTableCheck.Refusal.helperStopped(because: "it ran longer than 1 second").reason,
            "the braille helper was stopped because it ran longer than 1 second"
        )
        XCTAssertTrue(MacBrailleTableCheck.Refusal.helperFailed.isUnchecked)
        XCTAssertFalse(MacBrailleTableCheck.Refusal.doesNotLoad.isUnchecked)
        XCTAssertTrue(MacBrailleTableCheck.Verdict.usable.lastsTheSession)
        XCTAssertTrue(MacBrailleTableCheck.Verdict.refused(.doesNotLoad).lastsTheSession)
        XCTAssertFalse(MacBrailleTableCheck.Verdict.refused(.helperFailed).lastsTheSession)
        XCTAssertFalse(MacBrailleTableCheck.Verdict.refused(.noWorkingFolder).lastsTheSession)
    }

    /// The verdicts keep a lasting one, so a second ask checks nothing, and
    /// never keep a check that could not be made.
    func testTheSessionKeepsLastingVerdicts() {
        let verdicts = MacBrailleTableCheck.Verdicts()
        var checks = 0
        let usable = { () -> MacBrailleTableCheck.Verdict in checks += 1; return .usable }
        XCTAssertNil(verdicts.verdict(for: "mac:a.ctb"))
        XCTAssertEqual(verdicts.verdict(for: "mac:a.ctb", checking: usable), .usable)
        XCTAssertEqual(verdicts.verdict(for: "mac:a.ctb", checking: usable), .usable)
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(verdicts.verdict(for: "mac:a.ctb"), .usable)

        checks = 0
        let failing = { () -> MacBrailleTableCheck.Verdict in checks += 1; return .refused(.helperFailed) }
        XCTAssertEqual(verdicts.verdict(for: "mac:b.ctb", checking: failing), .refused(.helperFailed))
        XCTAssertEqual(verdicts.verdict(for: "mac:b.ctb", checking: failing), .refused(.helperFailed))
        XCTAssertEqual(checks, 2)
        XCTAssertNil(verdicts.verdict(for: "mac:b.ctb"))
    }

    // MARK: - The Check With Stand-ins

    /// A bundled table is never checked, and a Mac value this Mac does not
    /// offer is gone; neither starts the helper.
    func testBundledTablesPassAndGoneOnesAreRefusedWithoutAHelper() throws {
        let marker = work.appendingPathComponent("marker")
        let spy = shell("touch '\(marker.path)'")
        try isolated(tool: spy) {
            XCTAssertEqual(try MacBrailleTableCheck.check("en-ueb-g2.ctb", workingIn: work), .usable)
            XCTAssertEqual(try MacBrailleTableCheck.check("mac:no-such-table.ctb", workingIn: work), .refused(.gone))
            XCTAssertNoThrow(try MacBrailleTableCheck.requireUsable("en-ueb-g2.ctb", workingIn: work))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// The helper's answers become verdicts: status 2 is a table that does
    /// not load, eight-dot cells in the sample's translation are refused,
    /// six-dot ones (with the escape backslash) are usable, and any other
    /// failure is a check that could not be made, saying why: the helper
    /// failed, or the watchdog stopped it. Each leaves the working folder
    /// empty.
    func testTheHelpersAnswersBecomeVerdicts() throws {
        let table = try anyOfferedMacTable()
        // "check" passes; "forward" writes one line of `cells` to the output.
        func writing(_ octal: String) -> BrailleTranslator.Tool {
            shell(#"[ "$1" = check ] && exit 0; printf '\#(octal)\n' > "$2""#)
        }
        let cases: [(BrailleTranslator.Tool, MacBrailleTableCheck.Verdict)] = [
            (shell("exit 2"), .refused(.doesNotLoad)),
            (shell("exit 1"), .refused(.helperFailed)),
            (shell("sleep 5", seconds: 0.5), .refused(.helperStopped(because: "it ran longer than 1 second"))),
            (writing(#"\342\241\203"#), .refused(.writesEightDots)),  // U+2843, dots 1, 2, and 7
            (writing(#"\342\240\201\342\241\263"#), .usable),  // ⠁ and the escape backslash
        ]
        for (tool, expected) in cases {
            try isolated(tool: tool) {
                XCTAssertEqual(try MacBrailleTableCheck.check(table, workingIn: work), expected)
            }
            assertWorkFolderEmpty()
        }
    }

    /// The translator refuses a Mac table whose check fails by name, as an
    /// unknown table, and keeps the verdict: the second translation starts
    /// no helper at all. A call with no work checks nothing.
    func testTheTranslatorRefusesAFailingMacTableByName() throws {
        let table = try anyOfferedMacTable()
        let marker = work.appendingPathComponent("marker")
        try MacBrailleTableCheck.$verdicts.withValue(MacBrailleTableCheck.Verdicts()) {
            try BrailleTranslator.$tool.withValue(shell("exit 2")) {
                XCTAssertThrowsError(try BrailleTranslator.translate(["a"], table: table, direction: .printToBraille, workingIn: work)) {
                    XCTAssertEqual($0 as? BrailleTranslator.Failure, .unknownTable(table))
                    XCTAssertEqual(
                        ($0 as? LocalizedError)?.errorDescription,
                        "TextMouth has no braille table named \u{201C}\(table)\u{201D}."
                    )
                }
            }
            try BrailleTranslator.$tool.withValue(shell("touch '\(marker.path)'")) {
                XCTAssertThrowsError(try BrailleTranslator.translate(["a"], table: table, direction: .brailleToPrint, workingIn: work))
                XCTAssertEqual(try BrailleTranslator.translate([], table: table, direction: .printToBraille, workingIn: work), [])
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "a kept refusal ran the helper again")
        assertWorkFolderEmpty()
    }

    /// A check that could not be made refuses the translation saying so,
    /// and why, rather than naming a table TextMouth has not got; it is not
    /// kept, so the next translation checks again, and with a helper that
    /// works it translates (review R7).
    func testACheckThatCouldNotBeMadeSaysWhyAndIsTriedAgain() throws {
        let table = try anyOfferedMacTable()
        try MacBrailleTableCheck.$verdicts.withValue(MacBrailleTableCheck.Verdicts()) {
            try BrailleTranslator.$tool.withValue(shell("exit 1")) {
                XCTAssertThrowsError(try BrailleTranslator.translate(["a"], table: table, direction: .printToBraille, workingIn: work)) {
                    XCTAssertEqual($0 as? BrailleTranslator.Failure, .uncheckedTable(table, why: "the braille helper failed"))
                    XCTAssertEqual(
                        ($0 as? LocalizedError)?.errorDescription,
                        "TextMouth could not check this Mac's braille table \u{201C}\(table)\u{201D}: the braille helper failed. Try again."
                    )
                }
            }
            // Every run of this stand-in writes one six-dot cell, ⠁.
            try BrailleTranslator.$tool.withValue(shell(#"[ "$1" = check ] && exit 0; printf '\342\240\201\n' > "$2""#)) {
                XCTAssertEqual(try BrailleTranslator.translate(["a"], table: table, direction: .printToBraille, workingIn: work), ["\u{2801}"])
            }
        }
        assertWorkFolderEmpty()
    }

    /// A table whose metadata says six dots is offered on its word
    /// (decision 3): eight-dot cells in its sample do not refuse it, as they
    /// refuse a table with no dots line (review R1).
    func testATableDeclaringSixDotsIsNotRefusedForItsSample() throws {
        let declared = try anyOfferedMacTable(declaringSixDots: true)
        let eightDots = shell(#"[ "$1" = check ] && exit 0; printf '\342\241\203\n' > "$2""#)
        try isolated(tool: eightDots) {
            XCTAssertEqual(try MacBrailleTableCheck.check(declared, workingIn: work), .usable)
        }
        assertWorkFolderEmpty()
    }

    /// A refusal that says something of the table writes one event line,
    /// naming the table and the reason.
    func testARefusalIsLogged() throws {
        let table = try anyOfferedMacTable()
        try TextMouthPaths.ensureDirectoryStructure()
        try isolated(tool: shell("exit 2")) {
            _ = try MacBrailleTableCheck.check(table, workingIn: work)
        }
        let lines = debugLogLines(containing: "BRAILLE_MAC_TABLE_REFUSED: \(table): it does not load")
        XCTAssertFalse(lines.isEmpty, "no event line for the refusal")
    }

    /// The pop-ups' check runs off the main thread with the tool and the
    /// verdicts of the caller, and keeps its verdict.
    func testTheCheckOffTheMainThreadKeepsItsVerdict() async throws {
        let table = try anyOfferedMacTable()
        let verdicts = MacBrailleTableCheck.Verdicts()
        let root = try makeSandboxDirectory("MacBrailleCheckRoot")
        let verdict = await MacBrailleTableCheck.$verdicts.withValue(verdicts) {
            await BrailleTranslator.$tool.withValue(shell("exit 2")) {
                await TextutilDocumentReader.$temporaryRoot.withValue(root) {
                    await MacBrailleTableCheck.verdictOffTheMainThread(for: table)
                }
            }
        }
        XCTAssertEqual(verdict, .refused(.doesNotLoad))
        XCTAssertEqual(verdicts.verdict(for: table), .refused(.doesNotLoad))
        // Its working folder is gone again.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    // MARK: - The Real Tool

    /// The real tool runs a Mac table from the Mac's folder by its bare file
    /// name, and a bundled one from the bundle's, as before.
    func testTheRealToolRunsEachTableFromItsOwnFolder() throws {
        let tool = BrailleTranslator.Tool.helper
        let bundled = try XCTUnwrap(tool.tablesFolder)
        XCTAssertEqual(
            try XCTUnwrap(tool.command("check", "mac:fr-bfu-g2.ctb", nil, nil)).arguments,
            ["check", BrailleTableCatalog.macTablesFolder.path, "fr-bfu-g2.ctb"]
        )
        XCTAssertEqual(try XCTUnwrap(tool.command("check", "en-ueb-g2.ctb", nil, nil)).arguments, ["check", bundled.path, "en-ueb-g2.ctb"])
    }

    /// TextMouth's own liblouis version, which the refusal names, is the one
    /// vendored in `Vendor/liblouis/config.h`.
    func testTheBundledLiblouisVersionIsTheVendoredOne() throws {
        let config = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Vendor/liblouis/config.h")
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(
            text.contains("#define PACKAGE_VERSION \"\(BrailleTableCatalog.bundledLiblouisVersion)\""),
            "config.h names another version than \(BrailleTableCatalog.bundledLiblouisVersion)"
        )
    }

    // MARK: - This Mac's Real Tables

    /// This Mac's contracted French, partly contracted German, and
    /// uncontracted Spanish tables pass the check, and a sentence in each
    /// goes to six-dot braille and back unchanged through the translator.
    func testFrenchGermanAndSpanishPassAndRoundTrip() throws {
        let cases = [
            ("mac:fr-bfu-g2.ctb", "Le chat est noir."),
            ("mac:de-g1-detailed.ctb", "Der Hund ist klein."),
            ("mac:es.tbl", "El perro es grande."),
        ]
        var checked = 0
        for (id, sentence) in cases {
            guard BrailleTableCatalog.table(withID: id) != nil else { continue }
            checked += 1
            try isolated {
                XCTAssertEqual(try MacBrailleTableCheck.check(id, workingIn: work), .usable, id)
                let braille = try BrailleTranslator.translate([sentence], table: id, direction: .printToBraille, workingIn: work)
                XCTAssertTrue(braille.allSatisfy(MacBrailleTableCheck.writesSixDotsOnly), "\(id): \(braille)")
                XCTAssertEqual(try BrailleTranslator.translate(braille, table: id, direction: .brailleToPrint, workingIn: work), [sentence], id)
            }
            assertWorkFolderEmpty()
        }
        try XCTSkipIf(checked == 0, "This Mac offers none of its French, German, or Spanish tables")
    }

    /// This Mac's Hungarian tables, which give no dots line, write ’ and ‘
    /// with eight dots, so the typographic sample refuses them (review R1);
    /// its Swedish table says six dots, so it is offered though it writes «
    /// with eight dots, and an export that meets « fails, naming it.
    func testHungarianIsRefusedForEightDotsAndSwedishIsOffered() throws {
        var checked = 0
        for (id, expected) in [("mac:hu.tbl", MacBrailleTableCheck.Verdict.refused(.writesEightDots)),
                               ("mac:hu-hu-g2.ctb", .refused(.writesEightDots)), ("mac:sv-g1.ctb", .usable)]
        where BrailleTableCatalog.table(withID: id) != nil {
            checked += 1
            try isolated {
                XCTAssertEqual(try MacBrailleTableCheck.check(id, workingIn: work), expected, id)
            }
        }
        assertWorkFolderEmpty()
        try XCTSkipIf(checked == 0, "This Mac offers none of its Hungarian or Swedish tables")
    }

    /// This Mac's Greek table does not load in TextMouth's liblouis, so the
    /// check refuses it, and an import or export with it is refused by name.
    func testGreekDoesNotLoadAndIsRefusedByName() throws {
        let greek = try requireOffered("mac:el.ctb")
        try isolated {
            XCTAssertEqual(try MacBrailleTableCheck.check(greek, workingIn: work), .refused(.doesNotLoad))
            XCTAssertThrowsError(try BrailleTranslator.translate(["a"], table: greek, direction: .printToBraille, workingIn: work)) {
                XCTAssertEqual($0 as? BrailleTranslator.Failure, .unknownTable(greek))
            }
        }
        assertWorkFolderEmpty()
    }
}
