import Foundation

/// The tags of a file one of TextMouth's own audio readers reads: what its
/// APEv2 tag says (the tag True Audio, WavPack, and Monkey's Audio share),
/// then what an ID3v2 tag at its start or an ID3v1 tag at its end adds.
/// The converted .m4a carries them (`OwnAudioConverter`).
struct OwnAudioTags: Equatable, Sendable {
    var title = ""
    var artist = ""
    var album = ""
    var genre = ""
    /// The year or date, as the tag writes it.
    var date = ""
    /// A cue sheet kept inside the APEv2 tag (its `Cuesheet` item), the
    /// usual home of a whole-CD rip's track list; empty when there is none.
    var cueSheet = ""

    /// Whether no tag gave anything.
    var isEmpty: Bool { self == OwnAudioTags() }

    /// The tags with every field still empty filled from `other`.
    func filling(from other: OwnAudioTags) -> OwnAudioTags {
        var merged = self
        if merged.title.isEmpty { merged.title = other.title }
        if merged.artist.isEmpty { merged.artist = other.artist }
        if merged.album.isEmpty { merged.album = other.album }
        if merged.genre.isEmpty { merged.genre = other.genre }
        if merged.date.isEmpty { merged.date = other.date }
        if merged.cueSheet.isEmpty { merged.cueSheet = other.cueSheet }
        return merged
    }
}

/// Reads the tags of a file by hand, from its first and last bytes, with
/// every bound checked: an APEv2 tag at the end, an ID3v2 tag at the start,
/// and an ID3v1 tag at the end. A tag that is damaged, or larger than
/// `maximumTagBytes`, reads as no tag.
enum OwnAudioTagReader {
    /// The most bytes of one tag that are read. Text items come to a few
    /// kilobytes; a tag past this holds pictures, which TextMouth does not
    /// carry over, and is passed by.
    static let maximumTagBytes = 4 * 1_048_576
    /// The longest value kept of one text field, in bytes; a cue sheet may
    /// run to `maximumCueSheetBytes`.
    static let maximumFieldBytes = 4_096
    static let maximumCueSheetBytes = 1_048_576
    /// The length of an ID3v1 tag, and of an APEv2 tag's footer or header.
    static let id3v1Length = 128
    static let apeFooterLength = 32

    /// The tags of `bytes`: the APEv2 tag's, then the ID3v2 tag's, then
    /// the ID3v1 tag's, each filling only what the ones before left empty.
    static func read(_ bytes: OwnAudioBytes) -> OwnAudioTags {
        apeTags(of: bytes).filling(from: id3v2Tags(of: bytes)).filling(from: id3v1Tags(of: bytes))
    }

    // MARK: - APEv2

    /// The APEv2 tag at the end of `bytes`, before an ID3v1 tag when there
    /// is one. Its footer names the tag's size and item count; each item is
    /// its value's length, its flags, its key (ASCII, ended by a zero byte),
    /// and its value. Only UTF-8 text items are kept.
    static func apeTags(of bytes: OwnAudioBytes) -> OwnAudioTags {
        var tags = OwnAudioTags()
        var end = bytes.count
        if OwnAudioLittleEndian.holds(bytes.readUpTo(at: end - id3v1Length, count: 3), "TAG", at: 0) {
            end -= id3v1Length
        }
        let footer = bytes.readUpTo(at: end - apeFooterLength, count: apeFooterLength)
        guard footer.count == apeFooterLength, OwnAudioLittleEndian.holds(footer, "APETAGEX", at: 0),
              let size = OwnAudioLittleEndian.uint32(footer, 12),
              let itemCount = OwnAudioLittleEndian.uint32(footer, 16) else { return tags }
        // The size counts the items and the footer, not the header.
        let length = Int(size)
        guard length >= apeFooterLength, length <= maximumTagBytes, length <= end else { return tags }
        let items = bytes.readUpTo(at: end - length, count: length - apeFooterLength)
        guard items.count == length - apeFooterLength else { return tags }

        var position = 0
        var seen = 0
        // Every item takes at least nine bytes, so the bytes bound the loop.
        while seen < itemCount, let valueLength = OwnAudioLittleEndian.uint32(items, position),
              let flags = OwnAudioLittleEndian.uint32(items, position + 4) {
            seen += 1
            let keyStart = position + 8
            guard let keyEnd = items[keyStart...].firstIndex(of: 0) else { break }
            let valueStart = keyEnd + 1
            guard Int(valueLength) <= items.count - valueStart else { break }
            let valueEnd = valueStart + Int(valueLength)
            // Bits 1 and 2 of the flags give the value's kind: 0 is UTF-8 text.
            if (flags >> 1) & 3 == 0 {
                let key = String(decoding: items[keyStart..<keyEnd], as: UTF8.self).lowercased()
                store(text(items[valueStart..<valueEnd], limit: limit(forKey: key)), forKey: key, in: &tags)
            }
            position = valueEnd
        }
        return tags
    }

    /// The most bytes kept of the value of the APEv2 item `key`.
    private static func limit(forKey key: String) -> Int {
        key == "cuesheet" ? maximumCueSheetBytes : maximumFieldBytes
    }

    /// Puts `value` into the field of `tags` the APEv2 key `key`, in
    /// lowercase, names; other keys are passed by.
    private static func store(_ value: String, forKey key: String, in tags: inout OwnAudioTags) {
        switch key {
        case "title": tags.title = value
        case "artist": tags.artist = value
        case "album": tags.album = value
        case "genre": tags.genre = value
        case "year", "date": tags.date = value
        case "cuesheet": tags.cueSheet = value
        default: break
        }
    }

    /// `bytes` as UTF-8 text, at most `limit` bytes of it: an APEv2 value
    /// of several strings is joined by zero bytes, of which the first
    /// string is kept, trimmed of white space.
    private static func text(_ bytes: ArraySlice<UInt8>, limit: Int) -> String {
        let first = bytes.prefix(limit).prefix { $0 != 0 }
        return String(decoding: first, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - ID3v1

    /// The ID3v1 tag in the last 128 bytes of `bytes`: fixed fields of
    /// Latin-1 text, padded with zero bytes or spaces.
    static func id3v1Tags(of bytes: OwnAudioBytes) -> OwnAudioTags {
        var tags = OwnAudioTags()
        let tag = bytes.readUpTo(at: bytes.count - id3v1Length, count: id3v1Length)
        guard tag.count == id3v1Length, OwnAudioLittleEndian.holds(tag, "TAG", at: 0) else { return tags }
        tags.title = latin1(tag[3..<33])
        tags.artist = latin1(tag[33..<63])
        tags.album = latin1(tag[63..<93])
        tags.date = latin1(tag[93..<97])
        return tags
    }

    /// `bytes` as Latin-1 text up to its first zero byte, trimmed.
    private static func latin1(_ bytes: ArraySlice<UInt8>) -> String {
        String(String.UnicodeScalarView(bytes.prefix { $0 != 0 }.map { Unicode.Scalar($0) }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - ID3v2

    /// The field of the tags that the ID3v2 text frame `identifier` names,
    /// in versions 2.3 and 2.4 (four letters) and 2.2 (three); nil for
    /// every other frame.
    private static func field(forFrame identifier: String) -> WritableKeyPath<OwnAudioTags, String>? {
        switch identifier {
        case "TIT2", "TT2": return \.title
        case "TPE1", "TP1": return \.artist
        case "TALB", "TAL": return \.album
        case "TCON", "TCO": return \.genre
        case "TDRC", "TYER", "TYE": return \.date
        default: return nil
        }
    }

    /// The ID3v2 tag at the start of `bytes` (versions 2.2, 2.3, and 2.4):
    /// the title, artist, album, genre, and year frames. A tag that is
    /// compressed or encrypted as a whole, or written with
    /// unsynchronisation, reads as no tag: its text could not be trusted.
    static func id3v2Tags(of bytes: OwnAudioBytes) -> OwnAudioTags {
        var tags = OwnAudioTags()
        let head = bytes.readUpTo(at: 0, count: 10)
        let total = OwnAudioLeadingTag.id3v2Length(in: head)
        guard total > 10, head[3] >= 2, head[3] <= 4, head[5] & 0xC0 == 0 else { return tags }
        let version = Int(head[3])
        // The footer of a 2.4 tag repeats the header and holds no frames.
        let bodyLength = min(total - 10 - (head[5] & 0x10 != 0 ? 10 : 0), maximumTagBytes)
        let body = bytes.readUpTo(at: 10, count: bodyLength)
        let idLength = version == 2 ? 3 : 4
        let headerLength = version == 2 ? 6 : 10
        var position = 0
        // Every frame takes at least its header, so the bytes bound the loop.
        while position <= body.count - headerLength, body[position] != 0 {
            let identifier = String(decoding: body[position..<position + idLength], as: UTF8.self)
            let sizeBytes = body[(position + idLength)..<(position + idLength + (version == 2 ? 3 : 4))]
            // 2.4 sizes are four 7-bit bytes; 2.2 and 2.3 sizes are plain big-endian numbers.
            let size = sizeBytes.reduce(0) { version == 4 ? ($0 << 7) | Int($1 & 0x7F) : ($0 << 8) | Int($1) }
            let start = position + headerLength
            guard size > 0, size <= body.count - start else { break }
            if let field = field(forFrame: identifier), tags[keyPath: field].isEmpty {
                tags[keyPath: field] = id3v2Text(body[start..<start + size])
            }
            position = start + size
        }
        // A genre written as a number in parentheses names ID3v1's list, which is not kept.
        if tags.genre.hasPrefix("("), let close = tags.genre.firstIndex(of: ")") {
            tags.genre = String(tags.genre[tags.genre.index(after: close)...])
        }
        if !tags.genre.isEmpty, tags.genre.allSatisfy(\.isNumber) { tags.genre = "" }
        return tags
    }

    /// The text of an ID3v2 text frame's `content`: a byte naming the
    /// encoding (0 Latin-1, 1 UTF-16 with a byte order mark, 2 UTF-16
    /// big-endian, 3 UTF-8), then the text, of which at most
    /// `maximumFieldBytes` are read, up to its first zero character.
    private static func id3v2Text(_ content: ArraySlice<UInt8>) -> String {
        guard let encoding = content.first else { return "" }
        let raw = content.dropFirst().prefix(maximumFieldBytes)
        let decoded: String
        switch encoding {
        case 0: decoded = latin1(raw)
        case 1: decoded = String(decoding: utf16Units(raw, bigEndianWithoutMark: false), as: UTF16.self)
        case 2: decoded = String(decoding: utf16Units(raw, bigEndianWithoutMark: true), as: UTF16.self)
        default: decoded = String(decoding: raw, as: UTF8.self)
        }
        let first = decoded.prefix { $0 != "\0" }
        return first.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The UTF-16 code units of `bytes`: in the order its byte order mark
    /// gives (the mark itself dropped), or, without a mark, big-endian when
    /// `bigEndianWithoutMark` and little-endian otherwise.
    private static func utf16Units(_ bytes: ArraySlice<UInt8>, bigEndianWithoutMark: Bool) -> [UInt16] {
        var raw = Array(bytes)
        var bigEndian = bigEndianWithoutMark
        if raw.count >= 2, (raw[0] == 0xFF && raw[1] == 0xFE) || (raw[0] == 0xFE && raw[1] == 0xFF) {
            bigEndian = raw[0] == 0xFE
            raw.removeFirst(2)
        }
        return stride(from: 0, to: raw.count - 1, by: 2).map { index in
            bigEndian ? UInt16(raw[index]) << 8 | UInt16(raw[index + 1]) : UInt16(raw[index + 1]) << 8 | UInt16(raw[index])
        }
    }
}
