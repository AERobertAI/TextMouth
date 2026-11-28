import XCTest
@testable import TextMouth

/// Damaged braille on both platforms (DR34): random cells and random print
/// through the translator with each bundled table, and the braille samples
/// damaged every way the import fuzz sweep damages a file, imported; each ends
/// by itself, translated or refused in words, never with a crash or a hang.
///
/// liblouis reads untrusted input. On the Mac it runs in the braille helper,
/// whose crash would put a crash report on the user's screen; on the iPhone it
/// runs in the app itself, where a crash ends the app. So these tests run on
/// GitHub's runners only (`TestMachine.skipUnlessGitHubRunner`; the iPhone's
/// tests run nowhere else). On the iPhone each test uses one braille engine
/// of its own, made in setUp, so a hang refuses no other test's braille, and
/// after one, the engine refuses the test's later calls instead of starting a
/// second thread inside liblouis beside the stuck one. A hang under any of
/// its names (a call abandoned or refused, a run stopped for time) fails the
/// test, never passes as a refusal in words (the review of November 16,
/// finding 3). The input is seeded (`SplitMix64`), so a failure can be run
/// again exactly.
final class BrailleDamagedInputTests: XCTestCase {
    /// The four tables TextMouth bundles and offers.
    private let offered = ["en-ueb-g1.ctb", "en-ueb-g2.ctb", "en-us-g1.ctb", "en_US.tbl"]

    /// A working folder for the Mac's helper's hidden files.
    private var work = URL(fileURLWithPath: "/var/empty", isDirectory: true)  // replaced in setUp

    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox?

    #if os(iOS)
    /// The braille engine of this test, made in setUp: every call of the
    /// test, in every loop, goes through it.
    private var engine: InProcessEngine?
    #endif

    override func setUpWithError() throws {
        try TestMachine.skipUnlessGitHubRunner("This test feeds damaged braille to liblouis")
        work = try makeSandboxDirectory("BrailleDamaged")
        sandbox = try LibraryIndexSandbox.capture()
        #if os(iOS)
        engine = InProcessEngine(name: "test-liblouis-damaged", work: "the braille translation")
        #endif
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up skipped or failed partway.
        sandbox?.restore()
    }

    // MARK: - Helpers

    /// Runs `body` with braille translated by this test's braille engine on
    /// the iPhone, so that a hang wedges only it; the Mac's helper runs apart
    /// from the test host anyway.
    private func withOwnEngine<T>(_ body: () throws -> T) throws -> T {
        #if os(iOS)
        return try BrailleTranslator.$engine.withValue(try XCTUnwrap(engine, "setUp made no engine"), operation: body)
        #else
        return try body()
        #endif
    }

    /// The beginnings of the watchdog's words for a run stopped for time, a
    /// hang by another name: past its time, its output stalled, or past its
    /// processor time (`WatchedProcess.KillReason.words`, up to its number).
    private static let timeStops: [String] = [
        WatchedProcess.KillReason.tookTooLong(seconds: 1), .madeNoProgress(seconds: 1), .usedTooMuchProcessorTime(seconds: 1),
    ].map { String($0.words.prefix { !$0.isNumber }) }

    /// Whether `error`, an import's failure or a translation's own, is a hang
    /// under another name: a call the iPhone's engine abandoned, or refused
    /// after one, or a run of the Mac's helper stopped for time.
    private static func isAHang(_ error: any Error) -> Bool {
        let underlying = (error as? ImportFailure)?.underlying ?? error
        if underlying is InProcessEngine.Failure { return true }
        if case let .stopped(reason: reason)? = underlying as? BrailleTranslator.Failure {
            return timeStops.contains { reason.hasPrefix($0) }
        }
        return false
    }

    /// `count` random scalars from `scalars`, as a string.
    private func randomText(_ count: Int, from scalars: [ClosedRange<UInt32>], using random: inout SplitMix64) -> String {
        String(String.UnicodeScalarView((0..<count).compactMap { _ in
            let range = scalars[Int.random(in: 0..<scalars.count, using: &random)]
            return Unicode.Scalar(UInt32.random(in: range, using: &random))
        }))
    }

    // MARK: - What Counts as a Hang

    /// The damaged-books test fails on a hang under any of its names, and
    /// passes a refusal: an abandoned or refused call of the iPhone's engine
    /// and a run stopped for time are hangs, whether an import's failure
    /// holds them or not; a run stopped for its output, and a reader's
    /// refusal, are not.
    func testAHangUnderAnyNameIsNotARefusal() {
        let work = "the braille translation"
        let hangs: [any Error] = [
            InProcessEngine.Failure.abandoned(work: work, limit: 12),
            InProcessEngine.Failure.refused(work: work),
            BrailleTranslator.Failure.stopped(reason: WatchedProcess.KillReason.tookTooLong(seconds: 12).words),
            BrailleTranslator.Failure.stopped(reason: WatchedProcess.KillReason.madeNoProgress(seconds: 12).words),
            BrailleTranslator.Failure.stopped(reason: WatchedProcess.KillReason.usedTooMuchProcessorTime(seconds: 48).words),
        ]
        let refusals: [any Error] = [
            BrailleTranslator.Failure.stopped(reason: WatchedProcess.KillReason.wroteTooMuch(bytes: 9_437_184).words),
            BrailleTranslator.Failure.stopped(reason: WatchedProcess.KillReason.usedTooMuchMemory(bytes: 16_777_216).words),
            BrailleTranslator.Failure.unknownTable("en-ueb-g1.ctb"),
            BrailleTranslator.Failure.failed,
        ]
        for error in hangs {
            XCTAssertTrue(Self.isAHang(error), "\(error)")
            XCTAssertTrue(Self.isAHang(ImportFailure(fileName: "book.brf", step: .readingText, underlying: error)), "\(error)")
        }
        for error in refusals {
            XCTAssertFalse(Self.isAHang(error), "\(error)")
            XCTAssertFalse(Self.isAHang(ImportFailure(fileName: "book.brf", step: .readingText, underlying: error)), "\(error)")
        }
    }

    // MARK: - Random Cells and Print

    /// 120 paragraphs of random braille cells of all 256 patterns, eight-dot
    /// ones and blanks among them, some longer than one piece, read back with
    /// each table: a print text for each, in order.
    func testRandomCellsReadBackWithEveryTable() throws {
        var random = SplitMix64(seed: 20_261_116)
        let paragraphs = (0..<120).map { index in
            randomText(Int.random(in: 1...(index % 10 == 0 ? 9_000 : 600), using: &random), from: [0x2800...0x28FF], using: &random)
        }
        for table in offered {
            let print = try withOwnEngine {
                try BrailleTranslator.translate(paragraphs, table: table, direction: .brailleToPrint, workingIn: work)
            }
            XCTAssertEqual(print.count, paragraphs.count, table)
        }
    }

    /// 120 paragraphs of random print (controls, Latin and its accents,
    /// combining marks, other scripts, symbols, emoji, and braille cells as
    /// print), with random emphasis, written as braille with each table: one
    /// braille text for each, in order, all of it cells.
    func testRandomPrintIsWrittenWithEveryTable() throws {
        var random = SplitMix64(seed: 20_261_117)
        let ranges: [ClosedRange<UInt32>] = [
            0x01...0x1F, 0x20...0x7E, 0xA0...0x24F, 0x300...0x36F, 0x370...0x52F,
            0x5D0...0x6FF, 0x900...0x97F, 0x2000...0x2BFF, 0x2800...0x28FF, 0x3040...0x30FF, 0x4E00...0x4E80,
            0x1F300...0x1F6FF,
        ]
        let texts = try (0..<120).map { _ in
            let text = randomText(Int.random(in: 1...400, using: &random), from: ranges, using: &random)
            let emphasis = text.unicodeScalars.map { _ in BrailleEmphasis(rawValue: UInt8.random(in: 0...31, using: &random)) }
            // One flag set for each scalar, so the text always takes them.
            return try XCTUnwrap(EmphasizedText(text, emphasis: emphasis), "the emphasis does not fit its text")
        }
        for table in offered {
            let braille = try withOwnEngine {
                try BrailleTranslator.translate(texts, table: table, direction: .printToBraille, workingIn: work)
            }
            XCTAssertEqual(braille.count, texts.count, table)
            let notCells = braille.flatMap { $0.text.unicodeScalars }.filter { !(0x2800...0x28FF).contains($0.value) }
            XCTAssertEqual(notCells.count, 0, "\(table): \(notCells.prefix(5).map { String($0.value, radix: 16) })")
        }
    }

    // MARK: - Damaged Braille Books

    /// Each braille sample damaged in every way the import fuzz sweep damages
    /// a file (`ImportFuzzMutator`) imports as a book or fails with words;
    /// nothing else happens.
    func testDamagedBrailleBooksImportOrFailInWords() throws {
        let samples = ["brf/grade2-short.brf", "brf/pride-and-prejudice-ch1-grade1.brf", "brl/pride-and-prejudice-ch1-grade1.brl",
                       "pef/pride-and-prejudice-ch1-grade1.pef"]
        // The seed of every damage, so a failing case's id runs it again.
        let seed: UInt64 = 20_261_116
        var cases = 0
        for sample in samples {
            let original = try Data(contentsOf: formatSampleURL(sample))
            let name = (sample as NSString).lastPathComponent
            for mutation in ImportFuzzMutator.applicable(to: name) {
                let damaged = ImportFuzzMutator.apply(mutation, to: original, fileName: name, seed: seed)
                let file = try makeSandboxDirectory("BrailleDamagedBook").appendingPathComponent(name)
                try damaged.write(to: file)
                let id = ImportFuzzMutator.caseID(fileName: name, mutation: mutation, seed: seed)
                cases += 1
                do {
                    let book = try withOwnEngine {
                        try BraillePreferences.$tableForImports.withValue("en-ueb-g1.ctb") { try importedForTest(file).book }
                    }
                    XCTAssertEqual(book.format, .braille, id)
                } catch {
                    // A hang fails the test, and ends it: no later book should
                    // wait behind it, nor be refused for it.
                    guard !Self.isAHang(error) else {
                        XCTFail("\(id): a hang, not a refusal: \(error)")
                        return
                    }
                    // A refusal is fine, in words a listener can hear.
                    let words = (error as? LocalizedError)?.errorDescription ?? ""
                    XCTAssertFalse(words.isEmpty, "\(id): \(error)")
                }
            }
        }
        XCTAssertGreaterThan(cases, 40, "too few damaged books were tried")
    }
}
