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
/// one of its own, so the app's `BrailleTranslator.libraryEngine` is never
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

    /// Gates that hung work waits on, opened when the test ends.
    private var gates: [DispatchSemaphore] = []

    /// A working folder for the calls that take one; the iPhone writes nothing in it.
    private var work = URL(fileURLWithPath: "/var/empty", isDirectory: true)  // replaced in setUp

    override func setUpWithError() throws {
        work = try makeSandboxDirectory("BrailleLibrary")
    }

    override func tearDown() {
        for gate in gates { gate.signal() }
        gates = []
        super.tearDown()
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
    /// in `mode` with `table` from the bundle's tables folder, with at most
    /// `maxRecord` characters a record and `maxOutput` bytes of output (0 for
    /// no cap), told to stop at once when `stops`.
    private func call(
        _ input: Data,
        mode: tmb_mode,
        table: String = "en-ueb-g1.ctb",
        maxRecord: Int = BrailleTranslator.maximumPieceScalars,
        maxOutput: Int = 0,
        stops: Bool = false
    ) throws -> Outcome {
        let folder = try XCTUnwrap(BrailleTranslator.Tool.helper.tablesFolder?.path, "the app has no tables folder")
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

    /// A gate for hung work, opened when the test ends; work that waits on it
    /// gives up after 30 seconds whatever happens.
    private func makeGate() -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        gates.append(gate)
        return gate
    }

    /// A random number generator with a seed, so a failure can be run again
    /// exactly (SplitMix64).
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - The Bundled Tables

    /// The iPhone app holds liblouis's 20 table files in its liblouis/tables
    /// folder, as the Mac app does, and each of the four tables it offers
    /// loads in the app's own process.
    func testTheBundledTablesAreInTheAppAndEachOfferedOneLoads() throws {
        let folder = try XCTUnwrap(BrailleTranslator.Tool.helper.tablesFolder)
        XCTAssertTrue(folder.path.hasSuffix("/liblouis/tables"), folder.path)
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.count, 20, files.sorted().joined(separator: ", "))
        XCTAssertEqual(Set(BrailleTableCatalog.bundled.map(\.id)), Set(offered))
        for table in offered {
            XCTAssertEqual(try status("", TMB_MODE_CHECK, table: table), Int(TMB_EXIT_DONE), table)
            XCTAssertNoThrow(try BrailleTranslator.check(table: table, workingIn: work), table)
        }
    }

    /// Only a bundled table is compiled on the iPhone: one of a Mac's own
    /// tables, an include file, and a name that is no bare file name are each
    /// refused by name, before the library loads anything.
    func testOnlyBundledTablesAreCompiled() throws {
        for table in ["mac:fr-bfu-g2.ctb", "spaces.uti", "../en-ueb-g1.ctb", "en-ueb-g1.ctb,en-ueb-g2.ctb", ""] {
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
    /// each reads it first.
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

    // MARK: - Refused Until TextMouth Is Opened Again

    /// Once a braille engine has abandoned a call, every braille translation
    /// and check is refused at once, in the engine's own sentence, and an
    /// import of a braille book fails with it after the import's words.
    func testAfterAnAbandonedCallBrailleIsRefusedUntilTheAppIsOpenedAgain() throws {
        let wedged = InProcessEngine(name: "test-liblouis-wedged", work: "the braille translation", grace: 0.1)
        let gate = makeGate()
        XCTAssertThrowsError(try wedged.run(limit: 0.1) { _ in _ = gate.wait(timeout: .now() + 30) })
        XCTAssertTrue(wedged.hasAbandonedACall)

        let refusal = "TextMouth stopped the braille translation earlier because it took too long, "
            + "and won't try again until TextMouth is opened again."
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
        var random = SeededGenerator(state: 20_261_116)
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
