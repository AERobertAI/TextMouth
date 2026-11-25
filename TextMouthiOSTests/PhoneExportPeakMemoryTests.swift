import Darwin
import os
import XCTest
@testable import TextMouth

/// How much memory each text writer holds at its peak, for each byte of the
/// book's text (FR31): the evidence the iPhone's memory check stands on
/// (`PhoneExportMemoryCheck.peakBytesPerTextByte` and the braille writers' own).
///
/// An export of a large book on the iPhone could ask for a gigabyte, and iOS
/// ends an app past a limit it does not publish, so a book that would leave the
/// app too little is refused before its walk. The check's factor must be
/// measured, not guessed, and the design says to measure it where this is safe:
/// on GitHub's simulator, never on the development Mac. Each writer exports
/// through the real service (`BookExportService.export`) a book of the largest
/// fixture the writer is given, while a thread samples the process's physical
/// footprint, and the peak above where it began is written to the test's log,
/// one line a writer, as
/// `PHONE_EXPORT_PEAK writer=html text=16777216 peak=… factor=…`.
///
/// The test fails when any writer's peak is above what the check estimates for
/// that text, so the factor can be raised only by its evidence, and no writer
/// can grow past it unseen. The braille writers are given a text of three
/// megabytes: their translation has a limit of time for the whole call, and
/// one that ran over it would be abandoned, which refuses braille to every test
/// after it until the app is closed.
///
/// The braille engine also holds a cost that no text size changes: its tables,
/// compiled when it first translates (train 1125-0501 measured 28.78 bytes for
/// each byte of a 1 MB text, most of it that cost). So one tiny braille export
/// comes first, to warm the engine: its peak is the engine's fixed cost, which
/// is logged (`writer=engine`) and held under 64 MB, inside the 512 MB floor
/// the check always leaves the app (`PhoneExportMemoryCheck.floorBytes`). The
/// writers are then measured warm, braille too, and held to the estimate with
/// no allowance, so a braille writer that costs more for each byte than the
/// check says fails here, and the check, not this test, is what is raised.
///
/// Nothing here plays, types, or speaks; the files go to a sandbox folder.
final class PhoneExportPeakMemoryTests: XCTestCase {
    /// A writer measured: its name for the log, its conversion, and the bytes
    /// of text it is given.
    private struct Measured {
        let name: String
        let conversion: BookExportConversion
        let textBytes: Int
        /// The writer's `id`, which the check's estimate is made by.
        let writerID: String
    }

    /// The most the braille engine may hold for its tables, once, besides the text: well inside the
    /// 512 MB floor the memory check leaves the app.
    private let engineCostLimit: UInt64 = 64 << 20

    /// The text of the largest fixture the text writers are given: 16 MB,
    /// half of the 32 MB book the braille review's measurements met.
    private let largestText = 16 << 20
    /// The text the braille writers are given: 3 MB.
    private let brailleText = 3 << 20
    /// The text of the warm-up export: a few hundred bytes.
    private let warmUpText = 300

    /// Every writer the iPhone offers, and Markdown's, which an export makes
    /// when no other is chosen.
    private var cases: [Measured] {
        [
            Measured(name: "markdown", conversion: .markdown, textBytes: largestText, writerID: TextExportWriters.markdownID),
            Measured(name: "html", conversion: Self.text(HTMLExportWriter()), textBytes: largestText, writerID: HTMLExportWriter().id),
            Measured(name: "rtf", conversion: Self.text(RTFExportWriter()), textBytes: largestText, writerID: RTFExportWriter().id),
            Measured(name: "epub", conversion: Self.text(EPUBExportWriter()), textBytes: largestText, writerID: EPUBExportWriter().id),
            Measured(name: "brf", conversion: .text(TextExportConversion(BRFExportWriter(), options: BrailleExportOptions())), textBytes: brailleText, writerID: BRFExportWriter().id),
            Measured(name: "pef", conversion: .text(TextExportConversion(PEFExportWriter(), options: BrailleExportOptions())), textBytes: brailleText, writerID: PEFExportWriter().id),
        ]
    }

    /// The conversion of a writer that takes no options.
    private static func text<Writer: TextExportWriter>(_ writer: Writer) -> BookExportConversion where Writer.Options == NoTextExportOptions {
        .text(TextExportConversion(writer, options: NoTextExportOptions()))
    }

    // MARK: - The Measurement

    /// Each writer's peak, above the memory the process held as the export
    /// began, is within what the check estimates for its text; the numbers are
    /// in the log whether or not it is.
    func testNoWriterHoldsMoreThanTheCheckEstimates() throws {
        try TestMachine.skipUnlessGitHubRunner("it fills hundreds of megabytes of memory")
        var lines: [String] = []
        var over: [String] = []
        // The braille engine first, with a text of a few hundred bytes and the table every braille case uses: its peak is
        // the engine's fixed cost, and its tables stay compiled for the measurements below.
        let warmUp = Measured(
            name: "engine",
            conversion: .text(TextExportConversion(BRFExportWriter(), options: BrailleExportOptions())),
            textBytes: warmUpText,
            writerID: BRFExportWriter().id
        )
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
            let line = "PHONE_EXPORT_PEAK writer=\(measured.name) text=\(measured.textBytes) peak=\(peak) factor=\(String(format: "%.2f", factor))"
            lines.append(line)
            // Into the test's log, where a train's run keeps it.
            NSLog("%@", line)
            if peak > PhoneExportMemoryCheck.estimatedPeak(textBytes: Int64(measured.textBytes), writerID: measured.writerID) {
                over.append(line)
            }
        }
        XCTAssertEqual(
            over, [],
            "A writer holds more than the check estimates for it (\(PhoneExportMemoryCheck.peakBytesPerTextByte) bytes for each byte of text, braille's \(PhoneExportMemoryCheck.braillePeakBytesPerTextByte)). All: \(lines.joined(separator: "; "))"
        )
    }

    /// Exports a book of `measured.textBytes` bytes of text with the writer,
    /// through the real service and the iPhone's delivery, and returns the most
    /// physical memory the process held above what it held as it began.
    private func measurePeak(of measured: Measured) throws -> UInt64 {
        let sandbox = try makeSandboxDirectory("PhoneExportPeak-\(measured.name)")
        let offer = try makeOffer(textBytes: measured.textBytes, in: sandbox)
        // What the fixture and earlier writers left free goes back to the
        // system, so each peak is measured from where this export began.
        malloc_zone_pressure_relief(nil, 0)
        let sampler = FootprintSampler()
        sampler.start()
        let outcome = BookExportService.export(
            [offer],
            kinds: [.markdown],
            conversions: [.markdown: measured.conversion],
            to: sandbox.appendingPathComponent("Chosen", isDirectory: true),
            delivery: .coordinatedCopy
        )
        let peak = sampler.stop()
        XCTAssertEqual(outcome.failures, [], "\(measured.name) failed")
        XCTAssertEqual(outcome.exported.count, 1, "\(measured.name) wrote nothing")
        return peak
    }

    // MARK: - The Fixture

    /// An offer, made by hand, of a book's Markdown, whose content.md holds
    /// about `textBytes` bytes of chapters of paragraphs, headings, lists,
    /// quotes, and emphasis, written in `folder`.
    private func makeOffer(textBytes: Int, in folder: URL) throws -> BookExportOffer {
        let cache = folder.appendingPathComponent("content.md")
        try Data(Self.markdown(about: textBytes).utf8).write(to: cache)
        let attributes = try FileManager.default.attributesOfItem(atPath: cache.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let book = Book(title: "Harbour Pilots", format: .markdown, filePath: cache.path, md5Hash: "")
        let file = BookExportFile(
            source: .converted(from: cache, book: ExportBookDetails(book), by: .markdown),
            path: "Harbour Pilots - Text.md",
            byteCount: size
        )
        let item = BookExportItem(kind: .markdown, folderName: nil, files: [file], fileInCloud: nil)
        return BookExportOffer(book: book, items: [item], isPackageInCloud: false)
    }

    /// A content.md of about `bytes` bytes: chapters of forty paragraphs, a
    /// heading and a list and a quote in each, with emphasis in the words.
    private static func markdown(about bytes: Int) -> String {
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
