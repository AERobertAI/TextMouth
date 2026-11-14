import Foundation

/// Reads a Nero chapter list (the `chpl` atom) from an MPEG-4 file's own
/// bytes. AVFoundation reads a QuickTime chapter track but not a `chpl` atom
/// on its own, and some audiobook tools write only that atom, so such a book
/// would show no headings. The atom lives at `moov` > `udta` > `chpl`.
///
/// This reader opens no Apple audio API: it seeks through box headers on a
/// `FileHandle` (never reading the media data) and reads the one small atom.
/// Whatever the bytes are, nothing here may trap or loop without a bound:
/// every size is checked against what remains of the box that holds it, the
/// boxes looked at on each level are capped, and a malformed file simply has
/// no chapters.
enum NeroChapterReader {
    /// One chapter of a Nero list.
    struct Chapter: Equatable, Sendable {
        /// The chapter's title; empty when the file gave none.
        let title: String
        /// Where the chapter starts, in seconds from the file's start.
        let start: TimeInterval
    }

    // MARK: - Limits

    /// The most boxes looked at on each level of the walk.
    static let maxBoxesPerLevel = 10_000
    /// The largest `chpl` payload read; a larger atom is refused.
    static let maxPayloadLength: UInt64 = 1_048_576
    /// One `chpl` start tick is 100 nanoseconds: ten million to the second.
    private static let ticksPerSecond = 10_000_000.0
    /// The size of a plain box header: a 32-bit size and a four-byte type.
    private static let plainHeaderLength: UInt64 = 8
    /// The size of a box header with a 64-bit size after the type.
    private static let largeHeaderLength: UInt64 = 16

    // MARK: - Reading a file

    /// The extensions (lower case) of the MPEG-4 files that may hold a `chpl` atom.
    private static let mpeg4Extensions: Set<String> = ["m4a", "m4b", "mp4", "m4v", "mov"]

    /// Whether `url`'s extension (in any case) names an MPEG-4 file.
    static func mayHoldChapterList(_ url: URL) -> Bool {
        mpeg4Extensions.contains(url.pathExtension.lowercased())
    }

    /// The Nero chapters of the MPEG-4 file at `url`, in the atom's order;
    /// empty when the file has no `chpl` atom, cannot be read, or is malformed.
    static func read(at url: URL) -> [Chapter] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let fileEnd = try? handle.seekToEnd() else { return [] }

        // Walk down: the top level to `moov`, `moov` to `udta`, `udta` to `chpl`.
        var range = 0..<fileEnd
        for type in ["moov", "udta", "chpl"] {
            guard let inner = findBox(type, in: range, handle: handle) else { return [] }
            range = inner
        }
        // The payload is bounded before it is read.
        let length = range.upperBound - range.lowerBound
        guard length <= maxPayloadLength,
              let bytes = readBytes(handle: handle, at: range.lowerBound, count: Int(length)) else { return [] }
        return parse(chpl: bytes)
    }

    /// The payload range (after the header) of the first box of `type` found
    /// among the boxes that lie wholly inside `parent`, or nil when there is
    /// none or the walk meets a malformed box.
    private static func findBox(_ type: String, in parent: Range<UInt64>, handle: FileHandle) -> Range<UInt64>? {
        var position = parent.lowerBound
        for _ in 0..<maxBoxesPerLevel {
            // A header must fit in what remains of the parent.
            guard parent.upperBound - position >= plainHeaderLength,
                  let header = readBytes(handle: handle, at: position, count: Int(plainHeaderLength)) else { return nil }
            var size = UInt64(bigEndian32(header, at: 0))
            let boxType = String(decoding: header[4..<8], as: UTF8.self)
            var headerLength = plainHeaderLength

            if size == 1 {
                // A 64-bit size follows the type.
                guard parent.upperBound - position >= largeHeaderLength,
                      let large = readBytes(handle: handle, at: position + plainHeaderLength, count: 8) else { return nil }
                size = bigEndian64(large, at: 0)
                headerLength = largeHeaderLength
            } else if size == 0 {
                // The box runs to the end of its parent.
                size = parent.upperBound - position
            }
            // A size below its own header, or past the parent's end, stops the walk.
            guard size >= headerLength, size <= parent.upperBound - position else { return nil }

            if boxType == type { return (position + headerLength)..<(position + size) }
            position += size
            if position >= parent.upperBound { return nil }
        }
        return nil
    }

    /// Exactly `count` bytes at `offset`, or nil when the file gives fewer.
    private static func readBytes(handle: FileHandle, at offset: UInt64, count: Int) -> [UInt8]? {
        guard count >= 0, (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: count), data.count == count else { return nil }
        return [UInt8](data)
    }

    // MARK: - Reading the payload

    /// The chapters of a `chpl` payload (the bytes after the box header), as
    /// FFmpeg's `mov_read_chpl` reads it: a version byte and three flag bytes,
    /// four more bytes when the version is not 0, a one-byte count, then per
    /// chapter a 64-bit big-endian start in 100-nanosecond units, a one-byte
    /// title length, and the title. A payload that ends partway keeps the
    /// chapters read whole before the break.
    static func parse(chpl payload: [UInt8]) -> [Chapter] {
        guard let version = payload.first else { return [] }
        // The version and flags, then (version 1 and later) four reserved bytes.
        var position = version == 0 ? 4 : 8
        guard position < payload.count else { return [] }
        let count = Int(payload[position])
        position += 1

        var chapters: [Chapter] = []
        for _ in 0..<count {
            // A start and a title length must fit before the title is read.
            guard payload.count - position >= 9 else { break }
            let start = bigEndian64(payload, at: position)
            let titleLength = Int(payload[position + 8])
            position += 9
            guard payload.count - position >= titleLength else { break }
            let title = decodeTitle(payload[position..<(position + titleLength)])
            position += titleLength
            chapters.append(Chapter(title: title, start: Double(start) / ticksPerSecond))
        }
        return chapters
    }

    /// A title cut at its first NUL byte (as FFmpeg reads one: the rest is
    /// padding or garbage), then read as UTF-8, or as Windows-1252 when the
    /// bytes are not valid UTF-8 (the shared rule of `TextFileDecoder`, which
    /// gives the curly quotes a Windows tool writes at 0x93 and 0x94), with
    /// white space trimmed from both ends.
    private static func decodeTitle(_ bytes: ArraySlice<UInt8>) -> String {
        // Stop at the first NUL; a title that starts with one is empty.
        let data = Data(bytes.prefix(while: { $0 != 0 }))
        let text = String(data: data, encoding: .utf8) ?? TextFileDecoder.windows1252Text(data)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - The book's chapters

    /// Makes a book's chapters, in the shape `AudioPlaybackService.extractChapters`
    /// returns, from a Nero list and the file's length:
    /// - none when the length is not known (not a finite number above zero):
    ///   the last chapter's end would be unknown, and a damaged start could
    ///   give a chapter of any length, so the book keeps one chapter, as
    ///   without a list;
    /// - sorted by start, equal starts keeping their file order;
    /// - a chapter at or past the file's end dropped, and so is a repeat of
    ///   a start already taken;
    /// - the first chapter taken to begin at 0, so the chapters cover the file;
    /// - each lasting until the next one's start, the last until the file's end;
    /// - an empty title named "Chapter N", N being the chapter's place from 1.
    static func bookChapters(from chapters: [Chapter], fileDuration: TimeInterval)
        -> [(title: String, startTime: TimeInterval, duration: TimeInterval)] {
        guard fileDuration.isFinite, fileDuration > 0 else { return [] }
        let ordered = chapters.enumerated()
            .sortedStably { $0.element.start != $1.element.start ? $0.element.start < $1.element.start : $0.offset < $1.offset }
            .map(\.element)

        // Drop what lies past the end and repeated starts (the list is sorted).
        var kept: [Chapter] = []
        for chapter in ordered {
            if chapter.start >= fileDuration { continue }
            if let last = kept.last, last.start == chapter.start { continue }
            kept.append(chapter)
        }

        return kept.enumerated().map { index, chapter in
            let start = index == 0 ? 0 : chapter.start
            let next = index + 1 < kept.count ? kept[index + 1].start : fileDuration
            return (title: chapter.title.isEmpty ? "Chapter \(index + 1)" : chapter.title,
                    startTime: start,
                    duration: max(0, next - start))
        }
    }

    // MARK: - Big-endian helpers

    /// The 32-bit big-endian value at `offset`; the caller has checked the bounds.
    private static func bigEndian32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        bytes[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// The 64-bit big-endian value at `offset`; the caller has checked the bounds.
    private static func bigEndian64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        bytes[offset..<(offset + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
