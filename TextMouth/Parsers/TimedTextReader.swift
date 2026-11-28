import Foundation

// MARK: - Reading a Timed-Text File (FMT23, FMT25)

/// Reads a timed-text file in any format TextMouth reads (`TimedTextFormat`):
/// the one place that picks the reader for a format, and that bounds a file
/// read from disk before any of it is parsed. Attach Transcript…, the
/// import's pairing, and a podcast episode's fetch all read through it.
enum TimedTextReader {
    /// The document `data` holds, read as `format` by that format's reader,
    /// each cue's count bounded by `TimedTextLimits.maximumCues`.
    /// - Throws: `TimedTextError`, as the format's reader throws it.
    static func read(_ data: Data, as format: TimedTextFormat) throws -> TimedTextDocument {
        switch format {
        case .webVTT:
            return try WebVTTReader.read(data)
        case .subRip:
            return try SubRipReader.read(data)
        case .podcastJSON:
            return try PodcastTranscriptReader.read(data)
        }
    }

    /// The document the file at `url` holds, read as `format`. At most
    /// `byteLimit` + 1 bytes are read, so a file larger than `byteLimit`,
    /// or one that grows while it is read, is refused before any of it is
    /// parsed and without being read whole.
    /// - Throws: `TimedTextError.tooLarge` for a file larger than
    ///   `byteLimit`; the error that kept the file from being opened or
    ///   read, in the system's words (a missing file, a folder, no
    ///   permission); and what `read(_:as:)` throws.
    static func read(
        fileAt url: URL,
        as format: TimedTextFormat,
        byteLimit: Int = TimedTextLimits.localFileBytes
    ) throws -> TimedTextDocument {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: byteLimit + 1) ?? Data()
        guard data.count <= byteLimit else { throw TimedTextError.tooLarge(byteLimit: byteLimit) }
        return try read(data, as: format)
    }
}
