import Darwin
import os
import XCTest
@testable import TextMouth

/// How much memory each writer holds at its peak, for each byte of the book's
/// text (FR31): the evidence the iPhone's memory check stands on
/// (`PhoneExportMemoryCheck`'s figure for each writer).
///
/// An export of a large book on the iPhone could ask for a gigabyte, and iOS
/// ends an app past a limit it does not publish, so a book that would leave the
/// app too little is refused before its walk. The check's figures must be
/// measured, not guessed, and the design says to measure them where this is
/// safe: on GitHub's simulator, never on the development Mac. Each writer
/// exports through the real service (`BookExportService.export`) a book of a
/// fixture of its own, while a thread samples the process's physical footprint,
/// and the peak above where it began is written to the test's log, one line a
/// writer, as
/// `PHONE_EXPORT_PEAK writer=html fixture=prose text=… peak=… factor=… figure=…`.
/// The writers are the five text writers and the plain text and the captions,
/// which the check asks about too; the braille writers are given prose and verse
/// (short lines, so more blocks for each byte).
///
/// **The log is what the test is for.** A peak is a measurement, and the same
/// export read 22.61 and then 25.69 bytes for each byte in two runs; so the
/// test fails only past twice the figure the check estimates with, a margin no
/// run-to-run difference reaches, and says so, while every line is in the log
/// for whoever raises a figure. The braille writers are given 1 MB: their
/// translation has a limit of time for the whole call (a 3 MB export used about
/// half of it), and one that ran over it would be abandoned, which refuses
/// braille to every test after it until the app is closed.
///
/// One tiny braille export comes first, to warm the engine, whose tables are
/// compiled when it first translates: its peak is the engine's fixed cost (557,056
/// and 2,965,632 bytes in two runs), logged as `writer=engine` and held under
/// 64 MB, inside the 512 MB floor the check always leaves the app
/// (`PhoneExportMemoryCheck.floorBytes`).
///
/// Nothing here plays, types, or speaks; the files go to a sandbox folder.
final class PhoneExportPeakMemoryTests: XCTestCase {
    /// What the book's text is like, which changes how much memory each byte costs.
    private enum Fixture: String {
        /// Paragraphs of prose with emphasis, lists, quotes, and headings.
        case prose
        /// Short lines, each a paragraph of its own: more blocks for each byte.
        case verse
        /// A transcript.json, which captions are made of.
        case transcript
    }

    /// An export measured: its name for the log, the kind and conversion it
    /// makes, the fixture and size of its text, and the id of the writer
    /// whose figure the check estimates with.
    private struct Measured {
        let name: String
        let kind: BookExportKind
        let conversion: BookExportConversion?
        let fixture: Fixture
        let textBytes: Int
        let writerID: String
    }

    /// The text of the text writers' fixtures: 8 MB, half the 16 MB the first
    /// runs used and a quarter of the 32 MB book the braille review's
    /// measurements met; what each byte costs does not change with the size.
    private let largeText = 8 << 20
    /// The text of the plain text's and the captions' fixtures: 4 MB.
    private let mediumText = 4 << 20
    /// The text the braille writers are given: 1 MB.
    private let brailleText = 1 << 20
    /// The text of the warm-up export: a few hundred bytes.
    private let warmUpText = 300
    /// The most the braille engine may hold for its tables, once, besides the text: well inside the
    /// 512 MB floor the memory check leaves the app.
    private let engineCostLimit: UInt64 = 64 << 20

    /// The BRF writer with its options as a new export starts them.
    private var brf: BookExportConversion {
        .text(TextExportConversion(BRFExportWriter(), options: BrailleExportOptions()))
    }

    /// The PEF writer with its options as a new export starts them.
    private var pef: BookExportConversion {
        .text(TextExportConversion(PEFExportWriter(), options: BrailleExportOptions()))
    }

    /// Every export measured.
    private var cases: [Measured] {
        [
            Measured(name: "markdown", kind: .markdown, conversion: .markdown, fixture: .prose, textBytes: largeText, writerID: TextExportWriters.markdownID),
            Measured(name: "html", kind: .markdown, conversion: Self.text(HTMLExportWriter()), fixture: .prose, textBytes: largeText, writerID: HTMLExportWriter().id),
            Measured(name: "rtf", kind: .markdown, conversion: Self.text(RTFExportWriter()), fixture: .prose, textBytes: largeText, writerID: RTFExportWriter().id),
            Measured(name: "epub", kind: .markdown, conversion: Self.text(EPUBExportWriter()), fixture: .prose, textBytes: largeText, writerID: EPUBExportWriter().id),
            Measured(name: "plain-text", kind: .plainText, conversion: nil, fixture: .prose, textBytes: mediumText, writerID: BookExportService.plainTextGuardID),
            Measured(name: "captions", kind: .transcript, conversion: .timedText(.webVTT), fixture: .transcript, textBytes: mediumText, writerID: BookExportService.captionsGuardID),
            Measured(name: "brf", kind: .markdown, conversion: brf, fixture: .prose, textBytes: brailleText, writerID: BRFExportWriter().id),
            Measured(name: "pef", kind: .markdown, conversion: pef, fixture: .prose, textBytes: brailleText, writerID: PEFExportWriter().id),
            Measured(name: "brf", kind: .markdown, conversion: brf, fixture: .verse, textBytes: brailleText, writerID: BRFExportWriter().id),
            Measured(name: "pef", kind: .markdown, conversion: pef, fixture: .verse, textBytes: brailleText, writerID: PEFExportWriter().id),
        ]
    }

    /// The conversion of a writer that takes no options.
    private static func text<Writer: TextExportWriter>(_ writer: Writer) -> BookExportConversion where Writer.Options == NoTextExportOptions {
        .text(TextExportConversion(writer, options: NoTextExportOptions()))
    }

    // MARK: - The Measurement

    /// Each export's peak, above the memory the process held as it began, is
    /// written to the log; the test fails only past twice what the check
    /// estimates for it.
    func testNoWriterHoldsFarMoreThanTheCheckEstimates() throws {
        try TestMachine.skipUnlessGitHubRunner("it fills hundreds of megabytes of memory")
        var lines: [String] = []
        var over: [String] = []
        // The braille engine first: its peak is its fixed cost, and its tables stay compiled for what follows.
        let warmUp = Measured(name: "engine", kind: .markdown, conversion: brf, fixture: .prose, textBytes: warmUpText, writerID: BRFExportWriter().id)
        let engineCost = try measurePeak(of: warmUp)
        let engineLine = "PHONE_EXPORT_PEAK writer=engine fixed=\(engineCost)"
        lines.append(engineLine)
        NSLog("%@", engineLine)
        XCTAssertLessThan(
            engineCost, engineCostLimit,
            "The braille engine holds \(engineCost) bytes for its tables, past \(engineCostLimit), which the 512 MB floor of the memory check no longer covers"
        )
        for measured in cases {
            let peak = try measurePeak(of: measured)
            let factor = Double(peak) / Double(measured.textBytes)
            let figure = PhoneExportMemoryCheck.peakBytesPerTextByte(forWriter: measured.writerID)
            let line = "PHONE_EXPORT_PEAK writer=\(measured.name) fixture=\(measured.fixture.rawValue) text=\(measured.textBytes) peak=\(peak) "
                + "factor=\(String(format: "%.2f", factor)) figure=\(figure)"
            lines.append(line)
            // Into the test's log, where a train's run keeps it.
            NSLog("%@", line)
            if peak > 2 * PhoneExportMemoryCheck.estimatedPeak(textBytes: Int64(measured.textBytes), writerID: measured.writerID) {
                over.append(line)
            }
        }
        XCTAssertEqual(
            over, [],
            "A writer holds more than twice what the check estimates for it (a figure of 16 bytes for each byte of text, braille's 32): raise its figure in PhoneExportMemoryCheck. All: \(lines.joined(separator: "; "))"
        )
    }

    /// Exports a book of `measured.textBytes` bytes of text through the real
    /// service and the iPhone's delivery, and returns the most physical memory
    /// the process held above what it held as it began.
    private func measurePeak(of measured: Measured) throws -> UInt64 {
        let sandbox = try makeSandboxDirectory("PhoneExportPeak-\(measured.name)")
        let offer = try makeOffer(for: measured, in: sandbox)
        let conversions = measured.conversion.map { [measured.kind: $0] } ?? [:]
        // What the fixture and earlier exports left free goes back to the
        // system, so each peak is measured from where this export began.
        malloc_zone_pressure_relief(nil, 0)
        let sampler = FootprintSampler()
        sampler.start()
        let outcome = BookExportService.export(
            [offer],
            kinds: [measured.kind],
            conversions: conversions,
            to: sandbox.appendingPathComponent("Chosen", isDirectory: true),
            delivery: .coordinatedCopy
        )
        let peak = sampler.stop()
        XCTAssertEqual(outcome.failures, [], "\(measured.name) failed")
        XCTAssertEqual(outcome.exported.count, 1, "\(measured.name) wrote nothing")
        return peak
    }

    // MARK: - The Fixtures

    /// An offer, made by hand, of a book's text (its Markdown converted, its
    /// plain text, or its transcript's captions), whose source holds about
    /// `measured.textBytes` bytes of `measured.fixture`, written in `folder`.
    private func makeOffer(for measured: Measured, in folder: URL) throws -> BookExportOffer {
        let source = folder.appendingPathComponent(measured.fixture == .transcript ? "transcript.json" : "content.md")
        let bytes: Data
        switch measured.fixture {
        case .prose: bytes = Data(Self.prose(about: measured.textBytes).utf8)
        case .verse: bytes = Data(Self.verse(about: measured.textBytes).utf8)
        case .transcript: bytes = try Self.transcript(about: measured.textBytes)
        }
        try bytes.write(to: source)
        let book = Book(title: "Harbour Pilots", format: .markdown, filePath: source.path, md5Hash: "")
        let file: BookExportFile
        switch measured.kind {
        case .plainText:
            file = BookExportFile(source: .readingText(fromMarkdown: source), path: "Harbour Pilots - Text.txt", byteCount: Int64(bytes.count))
        case .transcript:
            file = BookExportFile(source: .copy(source), path: "Harbour Pilots - Transcript.json", byteCount: Int64(bytes.count))
        default:
            file = BookExportFile(
                source: .converted(from: source, book: ExportBookDetails(book), by: .markdown),
                path: "Harbour Pilots - Text.md",
                byteCount: Int64(bytes.count)
            )
        }
        let item = BookExportItem(kind: measured.kind, folderName: nil, files: [file], fileInCloud: nil)
        return BookExportOffer(book: book, items: [item], isPackageInCloud: false)
    }

    /// A content.md of about `bytes` bytes: chapters of forty paragraphs, a
    /// heading and a list and a quote in each, with emphasis in the words.
    private static func prose(about bytes: Int) -> String {
        // A few hundred bytes are one heading and one paragraph, not a chapter of forty.
        if bytes < 2_000 {
            return "<!-- chapter: Warm -->\n# Warm\n\nThe pilot boat ties up at the slip.\n"
        }
        var text = ""
        text.reserveCapacity(bytes + 8_192)
        var chapter = 0
        while text.utf8.count < bytes {
            chapter += 1
            text += "<!-- chapter: Chapter \(chapter) -->\n# Chapter \(chapter)\n\n"
            for paragraph in 0..<40 {
                switch paragraph % 10 {
                case 0:
                    text += "## Section \(chapter).\(paragraph / 10 + 1)\n\n"
                case 3:
                    text += "- the pilot boat ties up at the slip\n- berths 4 and 5 stay shut till noon\n- the gulls argue over the net shed\n\n"
                case 6:
                    text += "> The tide came in late that evening, and nobody on the quay said why.\n\n"
                default:
                    text += "The pilot boat ties up at the *slip* while the **harbour master** reads the day's \(paragraph) notices aloud; berths 4 and 5 stay shut till noon, and the gulls argue over the net shed. Nobody at the quay remembers a quieter morning, though the older hands say the tide was late.\n\n"
                }
            }
        }
        return text
    }

    /// A content.md of about `bytes` bytes of verse: each short line a paragraph of its own, in stanzas under
    /// chapters, which makes many more blocks for each byte than prose does.
    private static func verse(about bytes: Int) -> String {
        let lines = [
            "The pilot boat ties up at the slip,",
            "the gulls go quiet on the net shed roof,",
            "and nobody at the quay will say",
            "why the tide came in so late.",
            "Berths four and five stay shut till noon,",
            "the harbour master reads his book,",
            "a bell, a rope, a lantern lit,",
            "and morning takes its time.",
        ]
        var text = ""
        text.reserveCapacity(bytes + 8_192)
        var chapter = 0
        while text.utf8.count < bytes {
            chapter += 1
            text += "<!-- chapter: Canto \(chapter) -->\n# Canto \(chapter)\n\n"
            for stanza in 0..<60 {
                for line in lines.rotated(by: stanza % lines.count) {
                    text += "\(line)\n\n"
                }
            }
        }
        return text
    }

    /// A transcript.json of about `bytes` bytes: one audio file of sentences of eight words each, as the
    /// recognizer writes them, in times that pass the transcript's own validation.
    private static func transcript(about bytes: Int) throws -> Data {
        let sentenceText = "The pilot boat ties up at the slip."
        let wordRanges = [(0, 3), (4, 5), (10, 4), (15, 4), (20, 2), (23, 2), (26, 3), (30, 5)]
        // About 360 bytes of JSON for each sentence.
        let count = max(1, bytes / 360)
        var sentences: [TranscriptSentence] = []
        sentences.reserveCapacity(count)
        for number in 0..<count {
            let start = number * 3_000
            let words = wordRanges.enumerated().map { place, range in
                TranscriptWord(
                    characterOffset: range.0, characterCount: range.1,
                    startMilliseconds: start + place * 300, endMilliseconds: start + place * 300 + 250, confidence: 0.9
                )
            }
            sentences.append(TranscriptSentence(text: sentenceText, startMilliseconds: start, endMilliseconds: start + 2_500, words: words))
        }
        let duration = count * 3_000
        let file = TranscriptFile(
            path: "01.mp3",
            fingerprint: FileFingerprint(stamp: FileStamp(byteCount: 1, modificationTimeNanoseconds: 1), digest: "0"),
            durationMilliseconds: duration,
            sentences: sentences
        )
        let transcript = Transcript(
            version: Transcript.currentVersion,
            locale: "en-US",
            model: TranscriptSpeechModel(engine: "test", assetStatus: "installed", systemVersion: "26"),
            app: TranscriptAppBuild(version: "0", build: "0", commit: "0"),
            createdAt: Date(timeIntervalSince1970: 0),
            files: [file]
        )
        // As transcript.json is written, so that the export reads it as it reads a book's own.
        return try TranscriptStore.encoded(transcript)
    }
}

private extension Array {
    /// The array turned about, so that its element `count` places on comes first.
    func rotated(by count: Int) -> [Element] {
        guard !isEmpty else { return self }
        let split = count % self.count
        return Array(self[split...] + self[..<split])
    }
}

// MARK: - Sampling the Footprint

/// Samples the process's physical memory footprint as fast as a thread can,
/// from `start()` to `stop()`, and keeps the highest, above the first.
///
/// The footprint is the number iOS judges an app's memory by (`phys_footprint`
/// of `task_vm_info`). The thread never sleeps: it yields between samples, so
/// no guessed wait stands between a peak and its sample.
private final class FootprintSampler: Sendable {
    /// What the thread keeps: whether to go on, the first reading, and the highest.
    private struct State {
        var running = true
        var first: UInt64?
        var highest: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Starts sampling on a thread of its own, after a first reading taken here.
    func start() {
        record(Self.footprint())
        Thread.detachNewThread { [self] in
            while state.withLock({ $0.running }) {
                record(Self.footprint())
                sched_yield()
            }
        }
    }

    /// Stops sampling and returns the most the footprint rose above its first
    /// reading, in bytes.
    func stop() -> UInt64 {
        record(Self.footprint())
        return state.withLock { state in
            state.running = false
            return state.highest &- (state.first ?? state.highest)
        }
    }

    /// Notes one reading.
    private func record(_ reading: UInt64) {
        state.withLock { state in
            if state.first == nil { state.first = reading }
            state.highest = max(state.highest, reading)
        }
    }

    /// The process's physical footprint now, in bytes; 0 if the system won't say.
    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
    }
}
