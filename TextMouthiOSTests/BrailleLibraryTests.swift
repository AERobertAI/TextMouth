import os
import TextMouthBrailleLibrary
import XCTest
@testable import TextMouth

/// The iPhone's braille translation in its own process (DR34), which only the
/// iPhone links: the bundled tables, the batches, the limits of each call and
/// of a whole translation, Cancel, an engine that refuses after a call was
/// abandoned, and damaged input to the library itself.
///
/// The shared braille tests (BrailleTranslatorTests, BrailleImportTests, and
/// the rest) show that the iPhone reads as the Mac reads; these test what is
/// the iPhone's own. Every call of the library goes through an engine, one
/// call at a time, as the app's do; a test that hangs or wedges an engine uses
/// one of its own (its hung work waits on `makeGate()`, opened when the test
/// ends), so the app's `BrailleTranslator.libraryEngine` is never
/// refused for the tests after it. They run on GitHub's simulator only, as
/// every iPhone test does, so damaged input never reaches liblouis on the
/// development Mac.
final class BrailleLibraryTests: XCTestCase {
    /// The table most tests translate with: Unified English Braille, uncontracted.
    private let grade1 = "en-ueb-g1.ctb"

    /// The four tables TextMouth offers, the bundled ones.
    private let offered = ["en-ueb-g1.ctb", "en-ueb-g2.ctb", "en-us-g1.ctb", "en_US.tbl"]

    /// The engine the direct calls of the library go through.
    private let engine = InProcessEngine(name: "test-liblouis", work: "the braille translation")

    /// A working folder for the calls that take one; the iPhone writes nothing in it.
    private var work = URL(fileURLWithPath: "/var/empty", isDirectory: true)  // replaced in setUp

    override func setUpWithError() throws {
        work = try makeSandboxDirectory("BrailleLibrary")
    }

    // MARK: - Helpers

    /// The protocol's header line.
    private var header: String { BrailleEmphasis.protocolHeader + "\n" }

    /// One record of the protocol: `text`, then its codes (empty for none).
    private func record(_ text: String, _ codes: String = "") -> String {
        text + "\n" + codes + "\n"
    }

    /// What one direct call of the library gave.
    private struct Outcome: Sendable {
        let status: Int32
        let output: Data
    }

    /// `tmb_translate` called once on `engine`, as the app calls it: `input`
    /// in `mode` with `table` from the bundle's tables folder, or from
    /// `folder` when one is given, with at most `maxRecord` characters a
    /// record and `maxOutput` bytes of output (0 for no cap), told to stop at
    /// once when `stops`.
    private func call(
        _ input: Data,
        mode: tmb_mode,
        table: String = "en-ueb-g1.ctb",
        folder tables: String? = nil,
        maxRecord: Int = BrailleTranslator.maximumPieceScalars,
        maxOutput: Int = 0,
        stops: Bool = false
    ) throws -> Outcome {
        // The folder given, else a new one the test makes with the table in it (any name that is no offered table gets the default's).
        let folder = try tables ?? unpackedAppTables(for: BrailleTableCatalog.bundled.contains(where: { $0.id == table }) ? table : grade1).path
        let rawMode = mode.rawValue
        return try engine.run(limit: 60) { _ in
            folder.withCString { folder in
                table.withCString { table in
                    input.withUnsafeBytes { bytes in
                        var request = tmb_request()
                        request.mode = tmb_mode(rawValue: rawMode)
                        request.tables_folder = folder
                        request.table = table
                        request.input = bytes.baseAddress
                        request.input_length = bytes.count
                        request.limits.max_record_chars = maxRecord
                        request.limits.max_output_bytes = maxOutput
                        if stops { request.limits.should_stop = { _ in 1 } }
                        var response = tmb_response()
                        tmb_translate(&request, &response)
                        let output = response.output.map {
                            Data(bytesNoCopy: $0, count: response.output_length, deallocator: .free)
                        } ?? Data()
                        return Outcome(status: response.status, output: output)
                    }
                }
            }
        }
    }

    /// The status `call` gave, for a table of expected statuses.
    private func status(_ input: String, _ mode: tmb_mode, table: String = "en-ueb-g1.ctb", maxRecord: Int = 4_000) throws -> Int {
        Int(try call(Data(input.utf8), mode: mode, table: table, maxRecord: maxRecord).status)
    }

    // MARK: - The Bundled Tables

    /// The iPhone app holds every table it ships in its pack, unpacks a table and the files it includes into its Caches
    /// folder, under the liblouis version, at first use, and each of the four English tables loads in the app's own process.
    func testTheBundledTablesAreInThePackAndEachOfferedOneLoads() throws {
        let folder = try XCTUnwrap(try BrailleTranslator.Tool.helper.tablesFolder("en-ueb-g1.ctb"))
        XCTAssertEqual(folder.lastPathComponent, BrailleTableCatalog.bundledLiblouisVersion)
        XCTAssertEqual(folder.deletingLastPathComponent().lastPathComponent, "BrailleTables")
        XCTAssertTrue(Set(offered).isSubset(of: BrailleTableCatalog.bundled.map(\.id)))
        for table in offered {
            XCTAssertEqual(try status("", TMB_MODE_CHECK, table: table), Int(TMB_EXIT_DONE), table)
            XCTAssertNoThrow(try BrailleTranslator.check(table: table, workingIn: work), table)
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(table).path), table)
        }
    }

    /// Every table the iPhone offers, of every language, loads in the app's own process with the files it includes
    /// (FR40), and a table that is not English reads its own letters: the print "\u{E9}t\u{E9} bonjour" is written
    /// otherwise in Spanish and in French braille, and in neither as in English. The cells are what liblouis wrote
    /// for them on the development Mac.
    func testEveryOfferedTableLoadsAndOtherLanguagesTranslateWithTheirOwn() throws {
        XCTAssertGreaterThan(BrailleTableCatalog.bundled.count, 100)
        var failed: [String] = []
        for table in BrailleTableCatalog.bundled.map(\.id) where (try? BrailleTranslator.check(table: table, workingIn: work)) == nil {
            failed.append(table)
        }
        XCTAssertEqual(failed, [], "tables that did not load")
        let print = "\u{E9}t\u{E9} bonjour"
        let spanish = try BrailleTranslator.translate([print], table: "es.tbl", direction: .printToBraille, workingIn: work)
        XCTAssertEqual(spanish, ["\u{282E}\u{281E}\u{282E}\u{2800}\u{2803}\u{2815}\u{281D}\u{281A}\u{2815}\u{2825}\u{2817}"])
        let french = try BrailleTranslator.translate([print], table: "fr-bfu-g2.ctb", direction: .printToBraille, workingIn: work)
        XCTAssertEqual(french, ["\u{2836}\u{2800}\u{2803}\u{281A}"])
        let english = try BrailleTranslator.translate([print], table: "en-ueb-g1.ctb", direction: .printToBraille, workingIn: work)
        XCTAssertNotEqual(english, spanish)
        XCTAssertNotEqual(english, french)
        // And back, with the table's own letters.
        XCTAssertEqual(try BrailleTranslator.translate(spanish, table: "es.tbl", direction: .brailleToPrint, workingIn: work), [print])
    }

    /// A Mac's own table whose file name the iPhone's pack has is read with the pack's table (a library shared with a Mac,
    /// or the import table of a config.json made on one), and gives what the bare name gives; one the pack lacks stays
    /// refused by name.
    func testAMacsTableOfAFileNameThePackHasReadsWithThePacksOwn() throws {
        // The table is the pack's, under the value it was asked for (see testAMacsValueKeepsItsValue...).
        XCTAssertEqual(BrailleTableCatalog.table(withID: "mac:fr-bfu-g2.ctb")?.id, "mac:fr-bfu-g2.ctb")
        XCTAssertNil(BrailleTableCatalog.table(withID: "mac:no-such-table.ctb"))
        let print = "\u{E9}t\u{E9} bonjour"
        let own = try BrailleTranslator.translate([print], table: "fr-bfu-g2.ctb", direction: .printToBraille, workingIn: work)
        let named = try BrailleTranslator.translate([print], table: "mac:fr-bfu-g2.ctb", direction: .printToBraille, workingIn: work)
        XCTAssertEqual(named, own)
        XCTAssertNoThrow(try BrailleTranslator.check(table: "mac:fr-bfu-g2.ctb", workingIn: work))
        XCTAssertThrowsError(
            try BrailleTranslator.translate(["\u{2801}"], table: "mac:no-such-table.ctb", direction: .brailleToPrint, workingIn: work)
        ) {
            XCTAssertEqual($0 as? BrailleTranslator.Failure, .unknownTable("mac:no-such-table.ctb"))
        }
    }

    /// A value moves between devices as it was stored (FR40): asked for a Mac's `mac:<file>`, the catalog answers a table that
    /// keeps that value, so a copy or a re-read stores `mac:<file>` again, and the version recorded is the one this iPhone reads
    /// the table with, TextMouth's own (3.39.0), for a Mac's value and for a bare value of another language, and none for a
    /// table both apps carry.
    func testAMacsValueKeepsItsValueAndRecordsTheVersionTheIPhoneReadsWith() throws {
        let table = try XCTUnwrap(BrailleTableCatalog.table(withID: "mac:fr-bfu-g2.ctb"))
        XCTAssertEqual(table.id, "mac:fr-bfu-g2.ctb", "the value asked for is the value kept")
        XCTAssertEqual(table.displayName, BrailleTableCatalog.table(withID: "fr-bfu-g2.ctb")?.displayName)
        XCTAssertEqual(BrailleTableCatalog.table(withID: "fr-bfu-g2.ctb")?.id, "fr-bfu-g2.ctb")
        XCTAssertEqual(BrailleTableCatalog.versionToRecord(forTable: "mac:fr-bfu-g2.ctb"), BrailleTableCatalog.bundledLiblouisVersion)
        XCTAssertEqual(BrailleTableCatalog.versionToRecord(forTable: "fr-bfu-g2.ctb"), BrailleTableCatalog.bundledLiblouisVersion)
        XCTAssertNil(BrailleTableCatalog.versionToRecord(forTable: "en-ueb-g2.ctb"), "both apps carry it")
        XCTAssertNil(BrailleTableCatalog.table(withID: "mac:no-such-table.ctb"))
    }

    /// A re-read of a book a Mac read with one of its own tables, under liblouis 3.34.0, keeps the book's text on the iPhone,
    /// in the iPhone's words (never "This Mac's braille table"); the iPhone's own version, no version, and a table both apps
    /// carry pass.
    func testAMacsBookReadUnderAnotherLiblouisKeepsItsTextInThePhonesWords() throws {
        XCTAssertThrowsError(try BrailleBookReader.requireUnchangedTable("mac:fr-bfu-g2.ctb", recordedVersion: "3.34.0")) { error in
            let changed = BrailleTranslator.Failure.changedTable("mac:fr-bfu-g2.ctb", then: "3.34.0", now: BrailleTableCatalog.bundledLiblouisVersion)
            XCTAssertEqual(error as? BrailleTranslator.Failure, changed)
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "The braille table \u{201C}mac:fr-bfu-g2.ctb\u{201D} on this iPhone is liblouis \(BrailleTableCatalog.bundledLiblouisVersion), "
                    + "not liblouis 3.34.0 as when the book was read, so TextMouth keeps the book's text as it was."
            )
            XCTAssertFalse((error as? LocalizedError)?.errorDescription?.contains("This Mac") ?? true)
        }
        XCTAssertThrowsError(try BrailleBookReader.requireUnchangedTable("fr-bfu-g2.ctb", recordedVersion: "3.34.0"))
        XCTAssertNoThrow(try BrailleBookReader.requireUnchangedTable("mac:fr-bfu-g2.ctb", recordedVersion: BrailleTableCatalog.bundledLiblouisVersion))
        XCTAssertNoThrow(try BrailleBookReader.requireUnchangedTable("mac:fr-bfu-g2.ctb", recordedVersion: nil))
        XCTAssertNoThrow(try BrailleBookReader.requireUnchangedTable("en-ueb-g2.ctb", recordedVersion: "3.34.0"))
        // A Mac's value for a table both apps carry was read with a Mac's liblouis, so it is held to its version as every
        // other `mac:` value is, and records the iPhone's own.
        XCTAssertThrowsError(try BrailleBookReader.requireUnchangedTable("mac:en-ueb-g2.ctb", recordedVersion: "3.34.0"))
        XCTAssertNoThrow(try BrailleBookReader.requireUnchangedTable("mac:en-ueb-g2.ctb", recordedVersion: BrailleTableCatalog.bundledLiblouisVersion))
        XCTAssertEqual(BrailleTableCatalog.versionToRecord(forTable: "mac:en-ueb-g2.ctb"), BrailleTableCatalog.bundledLiblouisVersion)
        // A whole read of a book recorded under another version stops there, before anything is translated.
        let sample = try copyOfFormatSample("brf/grade2-short.brf")
        XCTAssertThrowsError(try BrailleBookReader.markdown(of: sample, table: "mac:fr-bfu-g2.ctb", recordedVersion: "3.34.0")) {
            XCTAssertEqual($0 as? BrailleTranslator.Failure, .changedTable("mac:fr-bfu-g2.ctb", then: "3.34.0", now: BrailleTableCatalog.bundledLiblouisVersion))
        }
    }

    /// A table whose files vanished between the check and the library's open (iOS may clear Caches whenever it likes) is
    /// unpacked again, once, before it is called unknown: a tool that gives a folder with nothing in it the first time and the
    /// unpacked one after succeeds, and one that always gives the empty folder is told the table is unknown, after one more try.
    func testATableThatVanishedBetweenTheCheckAndTheOpenIsUnpackedAgainOnce() throws {
        let good = try unpackedAppTables(for: grade1)
        let empty = try makeSandboxDirectory("BrailleVanished")
        func tool(calls: OSAllocatedUnfairLock<Int>, emptyFor count: Int) -> BrailleTranslator.Tool {
            BrailleTranslator.Tool(
                command: { _, _, _, _ in nil },
                limits: { BrailleTranslator.limits(for: $0, bytes: $1) },
                residentMemory: { _ in nil },
                tablesFolder: { _ in
                    let call = calls.withLock { total -> Int in total += 1; return total }
                    return call <= count ? empty : good
                }
            )
        }
        let again = OSAllocatedUnfairLock<Int>(initialState: 0)
        try BrailleTranslator.$tool.withValue(tool(calls: again, emptyFor: 1)) {
            try BrailleTranslator.check(table: grade1, workingIn: work)
        }
        XCTAssertGreaterThanOrEqual(again.withLock { $0 }, 2, "the tool was not asked again")

        let never = OSAllocatedUnfairLock<Int>(initialState: 0)
        try BrailleTranslator.$tool.withValue(tool(calls: never, emptyFor: Int.max)) {
            XCTAssertThrowsError(try BrailleTranslator.check(table: grade1, workingIn: work)) {
                XCTAssertEqual($0 as? BrailleTranslator.Failure, .unknownTable(grade1))
            }
        }
        XCTAssertGreaterThanOrEqual(never.withLock { $0 }, 2)
        XCTAssertLessThanOrEqual(never.withLock { $0 }, 4, "it tried more than the once more")
    }

    /// Only a table of the pack is compiled on the iPhone: a Mac's own table the pack lacks, an include file, and a name that
    /// is no bare file name are each refused by name, before the library loads anything.
    func testOnlyBundledTablesAreCompiled() throws {
        for table in ["mac:no-such-table.ctb", "spaces.uti", "../en-ueb-g1.ctb", "en-ueb-g1.ctb,en-ueb-g2.ctb", ""] {
            XCTAssertThrowsError(
                try BrailleTranslator.translate(["⠁"], table: table, direction: .brailleToPrint, workingIn: work), table
            ) {
                XCTAssertEqual($0 as? BrailleTranslator.Failure, .unknownTable(table), table)
            }
        }
        // The library refuses them itself too, whatever its caller let by.
        for table in ["spaces.uti/..", "../en-ueb-g1.ctb", "en-ueb-g1.ctb,en-ueb-g2.ctb", ".hidden.ctb", ""] {
            XCTAssertEqual(try status("", TMB_MODE_CHECK, table: table), Int(TMB_EXIT_TABLE), table)
        }
    }

    // MARK: - Batches

    /// A translation of many batches reads exactly as its texts read one by
    /// one: 600 paragraphs of about 5 KB each go to the library in ten
    /// batches or more, and each comes back whole, in order.
    func testATranslationOfManyBatchesReadsAsItsTextsAlone() throws {
        let word = "\u{281E}\u{2817}\u{2825}\u{281E}\u{2813}"  // "truth"
        let paragraphs = (0..<600).map { index in
            Array(repeating: word, count: 300 + index % 7).joined(separator: "\u{2800}")
        }
        let bytes = paragraphs.reduce(0) { $0 + $1.utf8.count }
        XCTAssertGreaterThan(bytes, 10 * BrailleTranslator.batchBytes, "the texts should fill ten batches")
        let result = try BrailleTranslator.translate(paragraphs, table: grade1, direction: .brailleToPrint, workingIn: work)
        XCTAssertEqual(result.count, paragraphs.count)
        for (index, text) in result.enumerated() where text != Array(repeating: "truth", count: 300 + index % 7).joined(separator: " ") {
            XCTFail("paragraph \(index + 1) reads \(text.prefix(40))…")
            break
        }
        // A sample of them, alone, reads the same.
        for index in [0, 299, 599] {
            XCTAssertEqual(
                try BrailleTranslator.translate([paragraphs[index]], table: grade1, direction: .brailleToPrint, workingIn: work),
                [result[index]], "paragraph \(index + 1)"
            )
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [], "the iPhone wrote a file")
    }

    /// Nothing is kept from one call of the library to the next: the four
    /// tables taken in turn, twice over, read the same braille each time as
    /// each reads it first; and a table file written again between two calls
    /// is compiled again, by its new rules, under the same name. liblouis
    /// keeps a compiled table by its name until it is freed, so a call that
    /// left its tables loaded would have the next read by the old rules
    /// ("a" for dot 1 here, measured on the Mac with the unload taken out;
    /// the review of November 16's nit).
    func testNothingIsKeptFromOneCallToTheNext() throws {
        let braille = ["\u{2828}\u{2801}\u{2803}\u{2809}\u{2800}\u{2819}\u{2811}\u{280B}", "\u{2820}\u{280B}\u{2815}\u{2817}\u{2800}\u{282E}"]
        var first: [String: [String]] = [:]
        for round in 0..<2 {
            for table in offered {
                let read = try BrailleTranslator.translate(braille, table: table, direction: .brailleToPrint, workingIn: work)
                if round == 0 {
                    first[table] = read
                } else {
                    XCTAssertEqual(read, first[table], "\(table) read otherwise after the other tables")
                }
            }
        }

        let folder = try makeSandboxDirectory("BrailleTableWrittenAgain")
        let file = folder.appendingPathComponent("probe.ctb")
        let dotOne = Data((header + record("\u{2801}")).utf8)
        try "letter a 1\n".write(to: file, atomically: true, encoding: .utf8)
        let before = try call(dotOne, mode: TMB_MODE_BACK_LIBLOUIS, table: "probe.ctb", folder: folder.path)
        try "letter b 1\n".write(to: file, atomically: true, encoding: .utf8)
        let after = try call(dotOne, mode: TMB_MODE_BACK_LIBLOUIS, table: "probe.ctb", folder: folder.path)
        XCTAssertEqual(String(decoding: before.output, as: UTF8.self), header + record("a"))
        XCTAssertEqual(String(decoding: after.output, as: UTF8.self), header + record("b"), "the first call's table was kept")
    }

    // MARK: - The Library's Own Limits

    /// The limits the library takes from its caller: a record past its most
    /// characters is invalid input (4), an output past its cap ends the call
    /// (9) with no output, and should_stop asked before a record ends it (8);
    /// within them the call is done (0).
    func testTheLibraryKeepsToEachLimit() throws {
        let cells = String(repeating: "\u{2801}", count: 4_000)
        XCTAssertEqual(try status(header + record(cells), TMB_MODE_BACK), Int(TMB_EXIT_DONE))
        XCTAssertEqual(try status(header + record(cells + "\u{2801}"), TMB_MODE_BACK), Int(TMB_EXIT_INPUT_INVALID))

        let input = Data((header + record(cells) + record(cells)).utf8)
        let capped = try call(input, mode: TMB_MODE_BACK, maxOutput: 100)
        XCTAssertEqual(Int(capped.status), Int(TMB_EXIT_OUTPUT_CAP))
        XCTAssertTrue(capped.output.isEmpty)
        let whole = try call(input, mode: TMB_MODE_BACK)
        XCTAssertEqual(Int(whole.status), Int(TMB_EXIT_DONE))
        let exact = try call(input, mode: TMB_MODE_BACK, maxOutput: whole.output.count)
        XCTAssertEqual(Int(exact.status), Int(TMB_EXIT_DONE), "an output exactly at its cap is done")
        XCTAssertEqual(exact.output, whole.output)

        let stopped = try call(input, mode: TMB_MODE_BACK, stops: true)
        XCTAssertEqual(Int(stopped.status), Int(TMB_EXIT_STOPPED))
        XCTAssertTrue(stopped.output.isEmpty)
    }

    /// An import's Cancel, made before the translation, ends it as a
    /// cancelled import ends, and the app's engine stays usable.
    func testCancelEndsATranslationAsCancelled() throws {
        let cancellation = ImportCancellation()
        cancellation.cancel()
        XCTAssertThrowsError(
            try ImportCancellation.$current.withValue(cancellation) {
                try BrailleTranslator.translate(["\u{2801}"], table: grade1, direction: .brailleToPrint, workingIn: work)
            }
        ) {
            XCTAssertTrue($0 is ImportCancelled, "\($0)")
        }
        XCTAssertFalse(BrailleTranslator.libraryEngine.hasAbandonedACall)
        XCTAssertEqual(try BrailleTranslator.translate(["\u{2801}"], table: grade1, direction: .brailleToPrint, workingIn: work), ["a"])
    }

    // MARK: - A Mac's Own Tables

    /// A braille book that needs one of a Mac's own tables the pack has no table of the same file name for is refused
    /// first, in the phone's words, whether a Mac read it with that table under a recorded liblouis version or not, and so
    /// is an import whose table is one (from a config.json made on a Mac): never in the Mac's sentences about "this Mac's"
    /// table, nor as a table TextMouth lacks.
    func testABookNeedingAMacsTableIsRefusedInThePhonesWords() throws {
        let sample = try copyOfFormatSample("brf/grade2-short.brf")
        for version in ["3.34.0", nil] as [String?] {
            XCTAssertThrowsError(
                try BrailleBookReader.markdown(of: sample, table: "mac:no-such-table.ctb", recordedVersion: version)
            ) {
                XCTAssertEqual($0 as? PhoneImportRefusal, .macBrailleTable("no-such-table.ctb"), version ?? "no version")
            }
        }
        let refusal = PhoneImportWording.macBrailleTableRefusal(
            PhoneImportWording.displayName(ofFileNamed: "grade2-short.brf"), table: "no-such-table.ctb"
        )
        XCTAssertThrowsError(
            try BraillePreferences.$tableForImports.withValue("mac:no-such-table.ctb") { try importedForTest(sample) }
        ) {
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, refusal)
        }
    }

    // MARK: - Refused Until TextMouth Is Closed and Opened Again

    /// Once a braille engine has abandoned a call, every braille translation
    /// and check is refused at once, in the engine's own sentence, and an
    /// import of a braille book fails with it after the import's words.
    func testAfterAnAbandonedCallBrailleIsRefusedUntilTheAppIsClosedAndOpenedAgain() throws {
        let wedged = InProcessEngine(name: "test-liblouis-wedged", work: "the braille translation", grace: 0.1)
        let gate = makeGate()
        XCTAssertThrowsError(try wedged.run(limit: 0.1) { _ in _ = gate.wait(timeout: .now() + 30) })
        XCTAssertTrue(wedged.hasAbandonedACall)

        let refusal = "TextMouth stopped the braille translation earlier because it took too long, "
            + "and won't try again until TextMouth is closed and opened again."
        try BrailleTranslator.$engine.withValue(wedged) {
            XCTAssertThrowsError(
                try BrailleTranslator.translate(["\u{2801}"], table: grade1, direction: .brailleToPrint, workingIn: work)
            ) {
                XCTAssertEqual($0 as? InProcessEngine.Failure, .refused(work: "the braille translation"))
                XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, refusal)
            }
            XCTAssertThrowsError(try BrailleTranslator.check(table: grade1, workingIn: work))

            // An import says it after its own words.
            let sample = try copyOfFormatSample("brf/grade2-short.brf")
            XCTAssertThrowsError(try importedForTest(sample)) {
                let words = ($0 as? LocalizedError)?.errorDescription ?? "\($0)"
                XCTAssertTrue(words.hasSuffix(refusal), words)
                XCTAssertTrue(words.hasPrefix("Could not import “grade2-short.brf”."), words)
            }
        }
        // The app's own engine is untouched.
        XCTAssertFalse(BrailleTranslator.libraryEngine.hasAbandonedACall)
    }

    // MARK: - Damaged Input

    /// Input that is not what the protocol takes gets its status from the
    /// library, never a crash: no header or another protocol's (7), an empty
    /// input (7), and in a record bad UTF-8, a NUL, a character that is no
    /// cell in braille, codes in braille, a missing code line, or codes that
    /// do not fit their text (4).
    func testDamagedInputGetsItsStatus() throws {
        let cases: [(name: String, input: String, mode: tmb_mode, status: Int32)] = [
            ("no header", record("\u{2801}"), TMB_MODE_BACK, Int32(TMB_EXIT_PROTOCOL)),
            ("another protocol", "TextMouthBraille 1\n" + record("\u{2801}"), TMB_MODE_BACK, Int32(TMB_EXIT_PROTOCOL)),
            ("print as braille", header + record("abc"), TMB_MODE_BACK, Int32(TMB_EXIT_INPUT_INVALID)),
            ("a NUL", header + record("a\u{0}b"), TMB_MODE_FORWARD, Int32(TMB_EXIT_INPUT_INVALID)),
            ("codes in braille", header + record("\u{2801}", "A"), TMB_MODE_BACK, Int32(TMB_EXIT_INPUT_INVALID)),
            ("no code line", header + "abc\n", TMB_MODE_FORWARD, Int32(TMB_EXIT_INPUT_INVALID)),
            ("codes that do not fit", header + record("abc", "AA"), TMB_MODE_FORWARD, Int32(TMB_EXIT_INPUT_INVALID)),
            ("a code past the flags", header + record("abc", "A`A"), TMB_MODE_FORWARD, Int32(TMB_EXIT_INPUT_INVALID)),
        ]
        for sample in cases {
            let outcome = try call(Data(sample.input.utf8), mode: sample.mode)
            XCTAssertEqual(outcome.status, sample.status, sample.name)
            XCTAssertTrue(outcome.output.isEmpty, sample.name)
        }
        XCTAssertEqual(Int(try call(Data(), mode: TMB_MODE_BACK).status), Int(TMB_EXIT_PROTOCOL), "an empty input")
        var badUTF8 = Data(header.utf8)
        badUTF8.append(contentsOf: [0xE2, 0xA0, 0x0A, 0x0A])
        XCTAssertEqual(Int(try call(badUTF8, mode: TMB_MODE_BACK).status), Int(TMB_EXIT_INPUT_INVALID), "bad UTF-8")
    }

    /// 300 inputs of random bytes, each after the protocol's header, in every
    /// mode and table, each get a status the library names and no output
    /// unless done; and 200 random paragraphs of braille cells, of every
    /// pattern, read back with each table, each in one record. Seeded, so a
    /// failure can be run again.
    func testRandomDamagedInputNeverEndsTheApp() throws {
        var random = SplitMix64(seed: 20_261_116)
        let modes = [TMB_MODE_FORWARD, TMB_MODE_BACK, TMB_MODE_BACK_LIBLOUIS]
        for round in 0..<300 {
            var input = Data(header.utf8)
            let length = Int.random(in: 0...600, using: &random)
            input.append(contentsOf: (0..<length).map { _ in UInt8.random(in: 0...255, using: &random) })
            let mode = modes[round % modes.count]
            let table = offered[round % offered.count]
            let outcome = try call(input, mode: mode, table: table)
            XCTAssertTrue((0...9).contains(Int(outcome.status)), "round \(round): status \(outcome.status)")
            if Int(outcome.status) != Int(TMB_EXIT_DONE) { XCTAssertTrue(outcome.output.isEmpty, "round \(round)") }
        }
        for round in 0..<200 {
            let count = Int.random(in: 1...BrailleTranslator.maximumPieceScalars, using: &random)
            let cells = String(String.UnicodeScalarView((0..<count).compactMap { _ in
                Unicode.Scalar(0x2800 + UInt32.random(in: 0...255, using: &random))
            }))
            let table = offered[round % offered.count]
            let outcome = try call(Data((header + record(cells)).utf8), mode: TMB_MODE_BACK, table: table)
            XCTAssertEqual(Int(outcome.status), Int(TMB_EXIT_DONE), "round \(round), \(table): \(count) cells")
        }
    }
}
