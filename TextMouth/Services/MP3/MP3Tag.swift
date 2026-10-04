import Foundation

// MARK: - Gapless Playback

/// The gapless-playback numbers of an MP3 TextMouth encodes (FR04): the
/// samples of silence LAME's encoder puts before the sound, its delay, and
/// after it, the padding of the last frame, and how many samples of sound
/// lie between, a channel's worth.
///
/// They are written as the comment iTunes writes for the same purpose,
/// "iTunSMPB", which AVFoundation honours: an MP3 carrying it measures and
/// plays exactly as long as its sound, from its first sample, where without
/// it AVFoundation can count LAME's delay and padding as part of the audio
/// (`MP3EncoderTests`). LAME's own tag holds the same numbers for other
/// players; AVFoundation reads that one only for some rates and channels.
struct MP3GaplessInfo: Equatable, Sendable {
    /// Samples of the encoder's delay before the sound: LAME's encoder delay,
    /// which AVFoundation's decoder leaves in its output.
    let priming: Int
    /// Samples of padding after the sound, to the end of the last frame.
    let padding: Int
    /// Samples of sound, a channel's worth.
    let sampleCount: Int64

    /// The comment's text as iTunes writes it: twelve hexadecimal fields,
    /// each after a space: zero, the priming, the padding, the sample count
    /// in sixteen digits, then eight more zeros. Every field has a fixed
    /// width, so the text is always 116 characters long, whatever the
    /// numbers: the encoder writes the tag before it knows them and writes it
    /// again, the same size, once it does.
    var commentText: String {
        let fields = [Self.hex(0, digits: 8), Self.hex(Int64(priming), digits: 8), Self.hex(Int64(padding), digits: 8),
                      Self.hex(sampleCount, digits: 16)]
            + Array(repeating: Self.hex(0, digits: 8), count: 8)
        return fields.map { " " + $0 }.joined()
    }

    /// `value` in upper-case hexadecimal, zero-padded to `digits` digits.
    private static func hex(_ value: Int64, digits: Int) -> String {
        let text = String(UInt64(clamping: value), radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }

    /// Nothing yet: what the tag holds until the encoder knows the numbers.
    static let unknown = MP3GaplessInfo(priming: 0, padding: 0, sampleCount: 0)
}

// MARK: - The ID3 Tag

/// The ID3 tag TextMouth writes at the start of every MP3 it encodes (FR04),
/// in ID3 version 2.3, which Apple's players read and nearly every other
/// player does too: the title (TIT2) and author (TPE1), each chapter marker
/// as a chapter frame (CHAP) titled by its own TIT2, listed in order by a
/// table of contents (CTOC), as the ID3v2 Chapter Frame Addendum lays them
/// out, and the gapless numbers as iTunes's comment (COMM "iTunSMPB").
///
/// AVFoundation reads the chapters a top-level table of contents lists, and
/// no others: none without a table, and none of a table listed by another
/// (measured on macOS 26). A table lists at most 255 entries, its count
/// being one byte, so an MP3 holds at most `maximumChapters` chapters that
/// TextMouth and Apple's players can find; past that, the last one lasts to
/// the end of the audio (`writtenChapters`), so every moment stays in one.
///
/// Text is written in UTF-16 with a byte-order mark, so any title survives;
/// the comment, which is all ASCII, in ISO-8859-1, as iTunes writes it.
struct MP3Tag: Equatable, Sendable {
    /// The title, or nil for none.
    var title: String?
    /// The author, or nil for none.
    var artist: String?
    /// The chapter markers, in order: where each starts and how long it
    /// lasts, in seconds, and its title.
    var chapters: [AudioRenderChapter] = []
    /// The gapless numbers, or nil to write none.
    var gapless: MP3GaplessInfo?

    /// The most chapters an MP3 holds: as many as one table of contents can
    /// list.
    static let maximumChapters = 255

    /// The tag's bytes: the ten-byte header, then its frames.
    func encoded() -> Data {
        var frames = Data()
        if let title, !title.isEmpty {
            frames += Self.textFrame("TIT2", title)
        }
        if let artist, !artist.isEmpty {
            frames += Self.textFrame("TPE1", artist)
        }
        frames += chapterFrames()
        if let gapless {
            frames += Self.commentFrame(description: "iTunSMPB", text: gapless.commentText)
        }
        // "ID3", version 2.3.0, no flags, then the size of everything after
        // the header as a synchsafe integer: seven bits in each byte.
        return Data("ID3".utf8) + Data([3, 0, 0]) + Self.synchsafe(frames.count) + frames
    }

    // MARK: Chapters

    /// The chapters as the tag writes them: `chapters`, or, when there are
    /// more than `maximumChapters`, the first of them, the last of which runs
    /// on to where the last of all ends, keeping its own title.
    var writtenChapters: [AudioRenderChapter] {
        guard chapters.count > Self.maximumChapters, let end = chapters.last.map({ $0.start + $0.duration }) else {
            return chapters
        }
        var kept = Array(chapters.prefix(Self.maximumChapters))
        if let last = kept.popLast() {
            kept.append(AudioRenderChapter(start: last.start, duration: end - last.start, title: last.title))
        }
        return kept
    }

    /// The table of contents, "toc", listing the chapters in order, then a
    /// frame for each, their element IDs "ch0", "ch1", and so on. Nothing
    /// when there are no chapters.
    private func chapterFrames() -> Data {
        let written = writtenChapters
        guard !written.isEmpty else { return Data() }
        let ids = written.indices.map { "ch\($0)" }
        var frames = Self.tableOfContents("toc", entries: ids)
        for (id, chapter) in zip(ids, written) {
            frames += Self.chapterFrame(id, chapter)
        }
        return frames
    }

    /// The top-level CTOC frame: its element ID, its flags (top-level, its
    /// entries in order), how many entries it lists, at most
    /// `maximumChapters`, and their element IDs.
    private static func tableOfContents(_ id: String, entries: [String]) -> Data {
        let listed = entries.prefix(maximumChapters)
        var content = latin1(id) + Data([0])
        // Bit 1: the top-level table; bit 0: its entries are in order.
        content.append(0x03)
        content.append(UInt8(listed.count))
        for entry in listed {
            content += latin1(entry) + Data([0])
        }
        return frame("CTOC", content)
    }

    /// A CHAP frame: its element ID, its start and end in milliseconds, the
    /// byte offsets left unused (all ones, as the addendum says when times
    /// are given), and its title as a TIT2 frame inside it.
    private static func chapterFrame(_ id: String, _ chapter: AudioRenderChapter) -> Data {
        var content = latin1(id) + Data([0])
        content += bigEndian(milliseconds(chapter.start))
        content += bigEndian(milliseconds(chapter.start + chapter.duration))
        content += bigEndian(UInt32.max) + bigEndian(UInt32.max)
        content += textFrame("TIT2", chapter.title)
        return frame("CHAP", content)
    }

    /// `seconds` in whole milliseconds, within what four bytes hold.
    private static func milliseconds(_ seconds: TimeInterval) -> UInt32 {
        let value = (max(0, seconds) * 1_000).rounded()
        return value >= Double(UInt32.max) ? UInt32.max : UInt32(value)
    }

    // MARK: Frames

    /// A text frame: encoding 1, UTF-16 with a byte-order mark, then the
    /// text, little-endian.
    private static func textFrame(_ id: String, _ text: String) -> Data {
        frame(id, Data([1]) + utf16(text))
    }

    /// A comment frame: encoding 0 (ISO-8859-1), the language "eng", the
    /// description and a zero ending it, then the text.
    private static func commentFrame(description: String, text: String) -> Data {
        frame("COMM", Data([0]) + Data("eng".utf8) + latin1(description) + Data([0]) + latin1(text))
    }

    /// A frame of ID3 version 2.3: its four-letter ID, the size of its
    /// content as a plain big-endian number (2.3 does not make it
    /// synchsafe), two bytes of flags, all clear, then the content.
    private static func frame(_ id: String, _ content: Data) -> Data {
        latin1(id) + bigEndian(UInt32(clamping: content.count)) + Data([0, 0]) + content
    }

    // MARK: Encodings

    /// `text` in UTF-16, little-endian, after its byte-order mark.
    private static func utf16(_ text: String) -> Data {
        var data = Data([0xFF, 0xFE])
        for unit in text.utf16 {
            data.append(UInt8(unit & 0xFF))
            data.append(UInt8(unit >> 8))
        }
        return data
    }

    /// `text` in ISO-8859-1, any character it can't hold as "?". Only
    /// TextMouth's own ASCII identifiers and numbers are written this way.
    private static func latin1(_ text: String) -> Data {
        text.data(using: .isoLatin1, allowLossyConversion: true) ?? Data()
    }

    /// `value` as four bytes, most significant first.
    private static func bigEndian(_ value: UInt32) -> Data {
        Data([UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    /// `size` as the synchsafe integer an ID3 header holds: four bytes of
    /// seven bits each, most significant first, so no byte looks like the
    /// start of an MP3 frame.
    static func synchsafe(_ size: Int) -> Data {
        Data([UInt8((size >> 21) & 0x7F), UInt8((size >> 14) & 0x7F), UInt8((size >> 7) & 0x7F), UInt8(size & 0x7F)])
    }
}
