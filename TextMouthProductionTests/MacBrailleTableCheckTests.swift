import os
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

    /// A stand-in helper that runs `/bin/sh -c script sh MODE OUTPUT INPUT`,
    /// with limits that keep a test short: `seconds` for each run.
    private func shell(_ script: String, seconds: TimeInterval = 5) -> BrailleTranslator.Tool {
        let limits = WatchedProcess.Limits(
            maximumSeconds: seconds, maximumResidentBytes: 1 << 30, maximumStalledSeconds: seconds, pollInterval: 0.1
        )
        return BrailleTranslator.Tool(
            command: { mode, _, input, output in
                (URL(fileURLWithPath: "/bin/sh"), ["-c", script, "sh", mode, output?.path ?? "", input?.path ?? ""])
            },
            limits: { _, _ in limits },
            residentMemory: { _ in nil },
            tablesFolder: nil
        )
    }

    /// A stand-in helper whose "check" passes and whose translations write
    /// `cells` for each paragraph of their input, both ways, after running
    /// `before` (a shell command, such as a sleep). It writes the helper's
    /// protocol: the input's header line, then for each record the cells
    /// and an empty code line (`TextMouthBrailleProtocol.h`).
    private func echoing(_ cells: String, before: String = ":", seconds: TimeInterval = 5) -> BrailleTranslator.Tool {
        let records = #"NR == 1 { print; next } NR % 2 == 0 { print "\#(cells)"; next } { print "" }"#
        return shell(#"[ "$1" = check ] && exit 0; "# + before + #"; awk '\#(records)' "$3" > "$2""#, seconds: seconds)
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
        XCTAssertEqual(MacBrailleTableCheck.Refusal.needsTooMuchMemory.reason, "it needs more than 64 MB of memory")
        XCTAssertEqual(MacBrailleTableCheck.Refusal.tooSlow.reason, "it translates too slowly, under 50 KB a second")
        XCTAssertTrue(MacBrailleTableCheck.Verdict.usable(.none).lastsTheSession)
        // A table found too slow is measured again at its next use (review F8).
        XCTAssertFalse(MacBrailleTableCheck.Verdict.refused(.tooSlow).lastsTheSession)
        XCTAssertTrue(MacBrailleTableCheck.Verdict.refused(.needsTooMuchMemory).lastsTheSession)
        XCTAssertTrue(MacBrailleTableCheck.Verdict.refused(.doesNotLoad).lastsTheSession)
        XCTAssertFalse(MacBrailleTableCheck.Verdict.refused(.helperFailed).lastsTheSession)
        XCTAssertFalse(MacBrailleTableCheck.Verdict.refused(.noWorkingFolder).lastsTheSession)
    }

    /// The verdicts keep a lasting one, so a second ask checks nothing, and
    /// never keep a check that could not be made.
    func testTheSessionKeepsLastingVerdicts() {
        let verdicts = MacBrailleTableCheck.Verdicts()
        var checks = 0
        let usable = { () -> MacBrailleTableCheck.Verdict in checks += 1; return .usable(.none) }
        XCTAssertNil(verdicts.verdict(for: "mac:a.ctb"))
        XCTAssertEqual(verdicts.verdict(for: "mac:a.ctb", checking: usable), .usable(.none))
        XCTAssertEqual(verdicts.verdict(for: "mac:a.ctb", checking: usable), .usable(.none))
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(verdicts.verdict(for: "mac:a.ctb"), .usable(.none))

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
            XCTAssertEqual(try MacBrailleTableCheck.check("en-ueb-g2.ctb", workingIn: work), .usable(.none))
            XCTAssertEqual(try MacBrailleTableCheck.check("mac:no-such-table.ctb", workingIn: work), .refused(.gone))
            XCTAssertNoThrow(try MacBrailleTableCheck.requireUsable("en-ueb-g2.ctb", workingIn: work))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    /// The helper's answers become verdicts: status 2 is a table that does
    /// not load, eight-dot cells in the sample's translation are refused,
    /// six-dot ones (with the escape backslash) are usable, a run stopped
    /// for its time is too slow (review R1), and any other failure is a
    /// check that could not be made, saying why. Each leaves the working
    /// folder empty.
    func testTheHelpersAnswersBecomeVerdicts() throws {
        let table = try anyOfferedMacTable()
        // Nil stands for a usable table.
        let cases: [(BrailleTranslator.Tool, MacBrailleTableCheck.Refusal?)] = [
            (shell("exit 2"), .doesNotLoad),
            (shell("exit 1"), .helperFailed),
            (shell("sleep 5", seconds: 0.5), .tooSlow),
            (echoing("\u{2843}"), .writesEightDots),  // dots 1, 2, and 7
            (echoing("\u{2801}\u{2873}"), nil),  // ⠁ and the escape backslash
        ]
        for (tool, expected) in cases {
            try isolated(tool: tool) {
                let verdict = try MacBrailleTableCheck.check(table, workingIn: work)
                if let expected {
                    XCTAssertEqual(verdict, .refused(expected))
                } else {
                    XCTAssertTrue(verdict.isUsable, "\(verdict)")
                }
            }
            assertWorkFolderEmpty()
        }
    }

    // MARK: - Needs and Limits (review R1)

    /// A table's measured needs raise the limits of its runs to at least
    /// twice its memory and four times its time, each way, and never lower
    /// a limit; a bundled table's needs change nothing.
    func testTheNeedsRaiseTheLimitsAndNeverLowerThem() {
        let needs = MacBrailleTableCheck.TableNeeds(
            loadSeconds: 0.1, forwardSecondsPerMB: 1.5, backSecondsPerMB: 7.6, peakResidentBytes: 28 * 1_048_576
        )
        let back = BrailleTranslator.limits(for: .brailleToPrint, bytes: 1_000_000)
        let raised = needs.limits(raising: back, direction: .brailleToPrint, bytes: 1_000_000)
        XCTAssertEqual(raised.maximumSeconds, 4 * (0.1 + 7.6), accuracy: 1e-9)
        XCTAssertEqual(raised.maximumStalledSeconds, raised.maximumSeconds)
        XCTAssertEqual(raised.maximumResidentBytes, 56 * 1_048_576)
        XCTAssertEqual(raised.maximumOutputBytes, back.maximumOutputBytes)
        // Forward, today's six seconds a megabyte is more than four times 1.5.
        let forward = BrailleTranslator.limits(for: .printToBraille, bytes: 1_000_000)
        XCTAssertEqual(needs.limits(raising: forward, direction: .printToBraille, bytes: 1_000_000).maximumSeconds, forward.maximumSeconds)
        // A check run needs only the load, far under today's ten seconds.
        let check = BrailleTranslator.limits(for: nil, bytes: 0)
        XCTAssertEqual(needs.limits(raising: check, direction: nil, bytes: 0).maximumSeconds, check.maximumSeconds)
        XCTAssertEqual(MacBrailleTableCheck.TableNeeds.none.limits(raising: back, direction: .brailleToPrint, bytes: 1_000_000), back)
    }

    /// Needs past a ceiling refuse the table: more than 64 MB of memory, or
    /// slower than 20 seconds a megabyte either way.
    func testTheCeilings() {
        XCTAssertEqual(MacBrailleTableCheck.memoryCeilingBytes, 64 * 1_048_576)
        XCTAssertEqual(MacBrailleTableCheck.secondsPerMBCeiling, 20)
        func needs(memory: Int64 = 1_048_576, forward: TimeInterval = 1, back: TimeInterval = 1) -> MacBrailleTableCheck.TableNeeds {
            .init(loadSeconds: 0.1, forwardSecondsPerMB: forward, backSecondsPerMB: back, peakResidentBytes: memory)
        }
        XCTAssertEqual(MacBrailleTableCheck.verdict(for: needs(memory: 65 * 1_048_576), timedSeconds: 1), .refused(.needsTooMuchMemory))
        XCTAssertEqual(MacBrailleTableCheck.verdict(for: needs(forward: 21), timedSeconds: 1), .refused(.tooSlow))
        XCTAssertEqual(MacBrailleTableCheck.verdict(for: needs(back: 21), timedSeconds: 1), .refused(.tooSlow))
        XCTAssertEqual(MacBrailleTableCheck.verdict(for: needs(memory: 28 * 1_048_576, back: 7.6), timedSeconds: 1),
                       .usable(needs(memory: 28 * 1_048_576, back: 7.6)))
        // A rate over a run of a few hundredths of a second is the time of
        // starting a process, and refuses nothing.
        XCTAssertEqual(MacBrailleTableCheck.minimumTimedSeconds, 0.25)
        XCTAssertEqual(MacBrailleTableCheck.verdict(for: needs(back: 60), timedSeconds: 0.03), .usable(needs(back: 60)))
        // A rate is the run's seconds beyond loading for each MB of input.
        XCTAssertEqual(MacBrailleTableCheck.secondsPerMB(0.5, input: [String(repeating: "a", count: 499_999)]), 1, accuracy: 1e-9)
        XCTAssertEqual(MacBrailleTableCheck.secondsPerMB(-0.1, input: ["a"]), 0)
        XCTAssertEqual(MacBrailleTableCheck.secondsPerMB(1, input: []), 0)
    }

    /// A table that holds more memory than the ceiling is stopped in its
    /// check and refused for it: a stand-in that holds 100 MB is stopped
    /// within a moment, its memory read every millisecond.
    func testATableNeedingTooMuchMemoryIsRefused() throws {
        let table = try anyOfferedMacTable()
        let hog = BrailleTranslator.Tool(
            command: { _, _, _, _ in
                (URL(fileURLWithPath: "/usr/bin/perl"), ["-e", "my $held = 'a' x (100 * 1024 * 1024); sleep 3;"])
            },
            limits: { _, _ in WatchedProcess.Limits(maximumSeconds: 5, maximumResidentBytes: 1 << 30, maximumStalledSeconds: 5) },
            residentMemory: { WatchedProcess.residentMemory(of: $0) },
            tablesFolder: nil
        )
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/perl"), "This Mac has no /usr/bin/perl")
        try isolated(tool: hog) {
            XCTAssertEqual(try MacBrailleTableCheck.check(table, workingIn: work), .refused(.needsTooMuchMemory))
        }
        assertWorkFolderEmpty()
    }

    /// A table slower than the ceiling is refused, and not kept for the
    /// session: by a scripted clock (review F8), loading takes a hundredth of
    /// a second and reading half a kilobyte of braille back a whole second,
    /// whatever the Mac's load. The next import checks it again.
    func testATableTooSlowIsRefusedAndMeasuredAgain() throws {
        let table = try anyOfferedMacTable()
        // Each run reads the clock as it starts and as it ends: the load,
        // the print, and the reading back, then the same again.
        let times = OSAllocatedUnfairLock(initialState: [0, 0.01, 1, 1.02, 2, 3, 10, 10.01, 11, 11.02, 12, 13])
        var tool = echoing("\u{2801}")
        tool.uptime = { times.withLock { $0.isEmpty ? 0 : $0.removeFirst() } }
        let verdicts = MacBrailleTableCheck.Verdicts()
        try MacBrailleTableCheck.$verdicts.withValue(verdicts) {
            try BrailleTranslator.$tool.withValue(tool) {
                XCTAssertEqual(try MacBrailleTableCheck.check(table, workingIn: work), .refused(.tooSlow))
                XCTAssertThrowsError(try MacBrailleTableCheck.requireUsable(table, workingIn: work))
            }
        }
        XCTAssertNil(verdicts.verdict(for: table), "a table found too slow was kept for the session")
        assertWorkFolderEmpty()
    }

    /// A run of a table found usable gets the limits its needs call for: a
    /// stand-in taking a second passes under a tool limit of half a second
    /// once the table's load is a second, and is stopped with no needs.
    func testARunGetsTheLimitsItsTablesNeedsCallFor() throws {
        let table = try anyOfferedMacTable()
        let slowStart = echoing("\u{2801}", before: "sleep 1", seconds: 0.5)
        let needs = MacBrailleTableCheck.TableNeeds(loadSeconds: 1, forwardSecondsPerMB: 0, backSecondsPerMB: 0, peakResidentBytes: 0)
        for (kept, passes) in [(needs, true), (.none, false)] {
            let verdicts = MacBrailleTableCheck.Verdicts()
            _ = verdicts.verdict(for: table) { .usable(kept) }
            try MacBrailleTableCheck.$verdicts.withValue(verdicts) {
                let limits = MacBrailleTableCheck.limits(
                    for: table, raising: slowStart.limits(.printToBraille, 2), direction: .printToBraille, bytes: 2
                )
                XCTAssertEqual(limits.maximumSeconds, passes ? 4 : 0.5, accuracy: 1e-9)
                try BrailleTranslator.$tool.withValue(slowStart) {
                    if passes {
                        XCTAssertEqual(try BrailleTranslator.translate(["a"], table: table, direction: .printToBraille, workingIn: work), ["\u{2801}"])
                    } else {
                        XCTAssertThrowsError(try BrailleTranslator.translate(["a"], table: table, direction: .printToBraille, workingIn: work))
                    }
                }
            }
        }
        assertWorkFolderEmpty()
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
                XCTAssertEqual(try BrailleTranslator.translate([] as [String], table: table, direction: .printToBraille, workingIn: work), [])
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
            // Every line this stand-in translates becomes one six-dot cell, ⠁.
            try BrailleTranslator.$tool.withValue(echoing("\u{2801}")) {
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
        try isolated(tool: echoing("\u{2843}")) {
            XCTAssertTrue(try MacBrailleTableCheck.check(declared, workingIn: work).isUsable)
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
                let verdict = try MacBrailleTableCheck.check(id, workingIn: work)
                guard case let .usable(needs) = verdict else { return XCTFail("\(id): \(verdict)") }
                // The check measured the table: its load, and its memory.
                XCTAssertGreaterThan(needs.loadSeconds, 0, id)
                XCTAssertGreaterThan(needs.peakResidentBytes, 0, id)
                XCTAssertLessThan(needs.peakResidentBytes, MacBrailleTableCheck.memoryCeilingBytes, id)
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
        // Nil stands for a usable table.
        for (id, expected) in [("mac:hu.tbl", MacBrailleTableCheck.Refusal?.some(.writesEightDots)),
                               ("mac:hu-hu-g2.ctb", .writesEightDots), ("mac:sv-g1.ctb", nil)]
        where BrailleTableCatalog.table(withID: id) != nil {
            checked += 1
            try isolated {
                let verdict = try MacBrailleTableCheck.check(id, workingIn: work)
                if let expected {
                    XCTAssertEqual(verdict, .refused(expected), id)
                } else {
                    XCTAssertTrue(verdict.isUsable, "\(id): \(verdict)")
                }
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
