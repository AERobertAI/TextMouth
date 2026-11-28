import Foundation

/// Whether the disks have room for a speech export (FMT43), checked before
/// anything is spoken: the chapters it speaks are kept on this Mac
/// (`SpeechExportStore`) until the exported file is made, so both need room
/// at once, and each disk keeps the room TextMouth always leaves free.
enum SpeechExportSpace {
    /// The bytes a second of spoken audio takes in a kept chapter's file:
    /// 16-bit mono samples at 22,050 Hz, as the system's voices speak, so
    /// 1.6 GB for a 10-hour book (the formats research, 7.5).
    static let speechBytesPerSecond: Int64 = 44_100

    /// The bytes a second takes in the exported file: AAC or MP3 at
    /// 64 kbit/s, the rate of spoken-word audiobooks
    /// (`AudioRenderSettings.bitRatePerChannel`).
    static var fileBytesPerSecond: Int64 {
        Int64(AudioRenderSettings.bitRatePerChannel / 8)
    }

    /// How long `wordCount` words take to speak at `wordsPerMinute`: 0 when
    /// the speed is not above 0, or not a finite number.
    static func seconds(wordCount: Int, wordsPerMinute: Double) -> TimeInterval {
        guard wordsPerMinute.isFinite, wordsPerMinute > 0 else { return 0 }
        return Double(wordCount) / wordsPerMinute * 60
    }

    /// Checks that the disks have room for an export: its speech needs
    /// `speechSeconds`, every second begun counted whole, at
    /// `speechBytesPerSecond` on the volume of `speechFolder`, and its file
    /// `fileSeconds` likewise at `fileBytesPerSecond` on the volume of
    /// `fileFolder`. On one volume the two needs add up. A volume whose free
    /// space less what it needs is below `reserve` has no room; a volume
    /// whose free space is unknown is not checked.
    /// - Parameters:
    ///   - speechSeconds: How long the chapters still to speak take.
    ///   - fileSeconds: How long the exported file plays.
    ///   - speechFolder: Where the spoken chapters are kept.
    ///   - fileFolder: The folder the file is exported to.
    ///   - freeSpace: The free bytes on the volume holding a location, or
    ///     nil when they can't be told; tests pass their own.
    ///   - sameVolume: Whether two locations are on one volume; tests pass
    ///     their own.
    ///   - reserve: The bytes left free on every volume.
    /// - Throws: `SpeechExportError.notEnoughSpace(needed:)` with the bytes
    ///   the first volume without room needs (both needs, on one volume).
    static func check(
        speechSeconds: TimeInterval,
        fileSeconds: TimeInterval,
        speechFolder: URL,
        fileFolder: URL,
        freeSpace: (URL) -> Int64? = ArchiveLimits.volumeFreeSpace(at:),
        sameVolume: (URL, URL) -> Bool = ImportScratchSpace.areOnSameVolume,
        reserve: Int64 = ArchiveLimits.standard.freeSpaceReserve
    ) throws {
        let speechNeed = bytes(forSeconds: speechSeconds, at: speechBytesPerSecond)
        let fileNeed = bytes(forSeconds: fileSeconds, at: fileBytesPerSecond)
        if sameVolume(speechFolder, fileFolder) {
            try requireRoom(for: saturatingSum(speechNeed, fileNeed), on: speechFolder, freeSpace: freeSpace, reserve: reserve)
        } else {
            try requireRoom(for: speechNeed, on: speechFolder, freeSpace: freeSpace, reserve: reserve)
            try requireRoom(for: fileNeed, on: fileFolder, freeSpace: freeSpace, reserve: reserve)
        }
    }

    /// The bytes `seconds` of audio take at `bytesPerSecond`, every second
    /// begun counted whole: none for a time not above 0, or not a number,
    /// and at most `Int64.max`, which an endless time needs.
    static func bytes(forSeconds seconds: TimeInterval, at bytesPerSecond: Int64) -> Int64 {
        // NaN is not above 0, so it needs nothing too.
        guard seconds > 0 else { return 0 }
        // Infinity, and any time past Int64's whole seconds, has no exact
        // count of seconds: it needs more than any disk holds.
        guard let wholeSeconds = Int64(exactly: seconds.rounded(.up)) else { return .max }
        let (product, overflow) = wholeSeconds.multipliedReportingOverflow(by: bytesPerSecond)
        return overflow ? .max : product
    }

    /// `first` and `second` added, or `Int64.max` when the sum is beyond it.
    private static func saturatingSum(_ first: Int64, _ second: Int64) -> Int64 {
        let (sum, overflow) = first.addingReportingOverflow(second)
        return overflow ? .max : sum
    }

    /// Throws `SpeechExportError.notEnoughSpace(needed: need)` unless the
    /// volume of `folder` keeps at least `reserve` bytes free after `need`
    /// more are written to it, or its free space is unknown.
    private static func requireRoom(
        for need: Int64,
        on folder: URL,
        freeSpace: (URL) -> Int64?,
        reserve: Int64
    ) throws {
        guard let free = freeSpace(folder) else { return }
        // A free space so far below the need that the difference is beyond
        // Int64's range is short of room too.
        let (left, overflow) = free.subtractingReportingOverflow(need)
        if overflow || left < reserve {
            throw SpeechExportError.notEnoughSpace(needed: need)
        }
    }
}
