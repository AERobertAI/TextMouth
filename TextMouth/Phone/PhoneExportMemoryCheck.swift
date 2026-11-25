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

    /// How many bytes of memory a conversion holds at its peak for each byte
    /// of the book's text (content.md), by the writer that holds the most.
    /// `PhoneExportPeakMemoryTests` measures each writer on GitHub and fails
    /// if any holds more than this for the largest fixture, so the figure
    /// can only be raised by its evidence, never left behind by a writer
    /// that grew.
    static let peakBytesPerTextByte: UInt64 = 16

    /// The most memory converting `textBytes` bytes of text is estimated to
    /// hold at once.
    static func estimatedPeak(textBytes: Int64) -> UInt64 {
        UInt64(max(0, textBytes)).multipliedReportingOverflow(by: peakBytesPerTextByte).partialValue
    }

    /// Whether a conversion of `textBytes` bytes of text may begin with
    /// `availableBytes` of memory left to the app: when its estimated peak
    /// leaves the floor. Nil `availableBytes` is a system that sets the app
    /// no limit (the simulator), which allows every conversion.
    static func allows(textBytes: Int64, availableBytes: UInt64?) -> Bool {
        guard let availableBytes else { return true }
        let needed = estimatedPeak(textBytes: textBytes).addingReportingOverflow(floorBytes)
        return !needed.overflow && availableBytes >= needed.partialValue
    }

    /// Refuses a conversion of `textBytes` bytes of text that `allows` does
    /// not.
    /// - Throws: a `TextExportError` saying so
    ///   (`PhoneExportWording.tooLittleMemory`), which the export names with
    ///   the file as a failure.
    static func check(textBytes: Int64, availableBytes: UInt64?) throws {
        guard allows(textBytes: textBytes, availableBytes: availableBytes) else {
            throw TextExportError(PhoneExportWording.tooLittleMemory)
        }
    }
}
