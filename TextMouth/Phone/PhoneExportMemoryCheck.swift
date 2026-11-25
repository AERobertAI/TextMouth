import Foundation

/// The check the iPhone's export makes before it converts a book's text: that
/// the memory left to the app holds the conversion and still leaves the app
/// its floor (FR31, the design's "Risks: memory"). A plain type, so the Mac's
/// test host tests every case; the figure it reads on the iPhone is
/// `os_proc_available_memory()` (`PhoneExportMemoryCheck.live`).
///
/// Every text conversion walks the whole of content.md into an
/// `ExportDocument`, and HTML, RTF, and EPUB build their file in memory, so a
/// book of tens of megabytes of text could ask for a gigabyte. iOS ends an app
/// past a limit it does not publish, which a person would meet as a crash
/// partway through an export, so a book that would leave the app too little is
/// refused instead, before its walk: its file fails with a sentence saying why
/// (`PhoneExportWording.tooLittleMemory`) and the other books still export.
struct PhoneExportMemoryCheck: Sendable {
    /// The memory the check leaves the app after a conversion: 512 MB, the
    /// in-app FFmpeg converter's floor (`SessionMemoryFloor`), room for the
    /// rest of TextMouth to say what happened.
    static let floorBytes: UInt64 = 512 << 20

    /// How many bytes of memory a conversion by a writer of text holds at its
    /// peak for each byte of the book's text (content.md): Markdown, HTML, RTF,
    /// and EPUB, which held 5.4 to 10.6 in four runs on GitHub's simulator.
    /// `PhoneExportPeakMemoryTests` measures each writer there and fails if
    /// any holds more than its figure for the largest fixture, so a figure
    /// can only be raised by its evidence, never left behind by a writer that
    /// grew.
    static let peakBytesPerTextByte: UInt64 = 16

    /// The same for the braille writers, BRF and PEF, which translate the text and
    /// keep its print blocks and its cells beside it: 19.0 to 22.6 for a text of
    /// 3 MB warm, and up to 28.8 for one of 1 MB, where the engine's tables are
    /// most of the peak. 32 leaves a margin over the most measured.
    static let braillePeakBytesPerTextByte: UInt64 = 32

    /// The ids of the writers whose figure is the braille one.
    private static let brailleWriterIDs: Set<String> = [BRFExportWriter().id, PEFExportWriter().id]

    /// How many bytes for each byte of text the writer whose `id` is `writerID` is estimated to hold.
    static func peakBytesPerTextByte(forWriter writerID: String) -> UInt64 {
        brailleWriterIDs.contains(writerID) ? braillePeakBytesPerTextByte : peakBytesPerTextByte
    }

    /// The most memory converting `textBytes` bytes of text by the writer `writerID` is
    /// estimated to hold at once.
    static func estimatedPeak(textBytes: Int64, writerID: String) -> UInt64 {
        UInt64(max(0, textBytes)).multipliedReportingOverflow(by: peakBytesPerTextByte(forWriter: writerID)).partialValue
    }

    /// Whether a conversion of `textBytes` bytes of text by `writerID` may begin with
    /// `availableBytes` of memory left to the app: when its estimated peak
    /// leaves the floor. Nil `availableBytes` is a system that sets the app
    /// no limit (the simulator), which allows every conversion.
    static func allows(writerID: String, textBytes: Int64, availableBytes: UInt64?) -> Bool {
        guard let availableBytes else { return true }
        let needed = estimatedPeak(textBytes: textBytes, writerID: writerID).addingReportingOverflow(floorBytes)
        return !needed.overflow && availableBytes >= needed.partialValue
    }

    /// Refuses a conversion of `textBytes` bytes of text that `allows` does
    /// not.
    /// - Throws: a `TextExportError` saying so
    ///   (`PhoneExportWording.tooLittleMemory`), which the export names with
    ///   the file as a failure.
    static func check(writerID: String, textBytes: Int64, availableBytes: UInt64?) throws {
        guard allows(writerID: writerID, textBytes: textBytes, availableBytes: availableBytes) else {
            throw TextExportError(PhoneExportWording.tooLittleMemory)
        }
    }
}
