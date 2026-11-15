import Foundation

/// The containers only ffmpeg reads (FMT31, FMT32), told from a file's first
/// bytes alone, so the import names ffmpeg's demuxer itself (`-f`) and ffmpeg
/// never guesses a format from bytes it cannot trust; and whether a Windows
/// Media file is copy-protected, which is refused before any program runs.
///
/// Nothing here uses an Apple audio API or decodes a sample: the bytes are
/// read with `AudioContentSniffer.firstBytes(of:upTo:from:)` (one open, a
/// bounded read, and a close, never a download of a file only in the cloud)
/// and judged by hand. The signatures are each format's published magic
/// numbers; the ASF object identifiers are those of Microsoft's ASF
/// specification (revision 01.20.03), as the November 15 research's probe
/// reads them (`research/AUDIO-DECODERS-RESEARCH-2026-11-15.md`).
enum FFmpegContainer: String, CaseIterable, Equatable, Sendable {
    /// Advanced Systems Format: WMA and WMV (its header object's identifier).
    case asf
    /// Matroska or WebM (EBML's magic number, 1A 45 DF A3).
    case matroska
    /// Flash video ("FLV" and version 1).
    case flv
    /// Audio Video Interleave ("RIFF", then "AVI ").
    case avi
    /// RealMedia (".RMF"), or an old RealAudio file (".ra" and 0xFD).
    case realMedia
    /// Musepack, stream version 7 ("MP+" and version 7).
    case musepack7
    /// Musepack, stream version 8 ("MPCK").
    case musepack8
    /// Ogg whose first stream is Speex: an Ogg page whose first packet
    /// begins "Speex   ". Ogg of this kind goes to ffmpeg whatever its name,
    /// since Apple's frameworks have no Speex decoder.
    case oggSpeex
    /// Ogg of any other codec (Vorbis, Opus, FLAC). The import leaves it to
    /// afconvert (`ImportAudioConverter`), as before; ffmpeg reads it only in
    /// a file named for ffmpeg, such as an .spx that holds Vorbis.
    case ogg

    /// The name ffmpeg and ffprobe know this container's demuxer by, given
    /// with `-f` before the input.
    var demuxer: String {
        switch self {
        case .asf: return "asf"
        case .matroska: return "matroska"
        case .flv: return "flv"
        case .avi: return "avi"
        case .realMedia: return "rm"
        case .musepack7: return "mpc"
        case .musepack8: return "mpc8"
        case .oggSpeex, .ogg: return "ogg"
        }
    }

    // MARK: - Telling Them Apart

    /// How many bytes are read to tell the container: enough for an Ogg
    /// page's header with the largest segment table (27 + 255 bytes) and the
    /// eight bytes of a Speex header's start.
    static let windowLength = 512

    /// The container the file at `url` holds, or nil when it is none of
    /// these, cannot be read as a regular file, or is only in the cloud.
    static func of(fileAt url: URL) -> FFmpegContainer? {
        guard let bytes = AudioContentSniffer.firstBytes(of: url, upTo: windowLength) else { return nil }
        return of(bytes)
    }

    /// The container `bytes`, a file's first bytes, begin with; nil for any
    /// other. A pure function of the bytes: none is read past their end.
    static func of(_ bytes: [UInt8]) -> FFmpegContainer? {
        if bytes.starts(with: ASFHeader.headerObjectID) { return .asf }
        if bytes.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return .matroska }
        if bytes.starts(with: Array("FLV".utf8) + [0x01]) { return .flv }
        if bytes.starts(with: Array("RIFF".utf8)), ascii(in: bytes, at: 8, is: "AVI ") { return .avi }
        if bytes.starts(with: Array(".RMF".utf8)) || bytes.starts(with: Array(".ra".utf8) + [0xFD]) { return .realMedia }
        // Stream version 7 keeps its version in the low four bits of the
        // fourth byte (0x07, or 0x17 for version 7.1).
        if bytes.starts(with: Array("MP+".utf8)), bytes.count > 3, bytes[3] & 0x0F == 7 { return .musepack7 }
        if bytes.starts(with: Array("MPCK".utf8)) { return .musepack8 }
        if isOggSpeex(bytes) { return .oggSpeex }
        if bytes.starts(with: Array("OggS".utf8)) { return .ogg }
        return nil
    }

    /// Whether `bytes` begin an Ogg page whose first packet is a Speex
    /// header. An Ogg page is 27 bytes of header ("OggS", the version, the
    /// header type, the granule position, the serial number, the page
    /// number, and the checksum), then its number of segments and a table
    /// of that many lacing values; the first packet's bytes follow the
    /// table. A Speex header packet starts with "Speex" and three spaces.
    static func isOggSpeex(_ bytes: [UInt8]) -> Bool {
        let segmentCountOffset = 26
        guard bytes.starts(with: Array("OggS".utf8)), bytes.count > segmentCountOffset else { return false }
        let segments = Int(bytes[segmentCountOffset])
        guard segments > 0 else { return false }
        return ascii(in: bytes, at: segmentCountOffset + 1 + segments, is: "Speex   ")
    }

    // MARK: - The Formats TextMouth Reads Itself

    /// The signatures of the lossless formats TextMouth reads with readers
    /// of its own (TTA, WavPack, and Monkey's Audio), which go by a file's
    /// content: ffmpeg never takes a file that holds one, whatever its name.
    static let ownReaderSignatures = ["TTA1", "wvpk", "MAC "]

    /// Whether the file at `url` holds TTA, WavPack, or Monkey's Audio: one
    /// of `ownReaderSignatures` at its start, or after the ID3v2 tag it
    /// starts with (a header of ten bytes and a size in four bytes of seven
    /// bits each, and ten bytes more when its flags say it has a footer).
    /// False when it cannot be read. Reads ten bytes, then four.
    static func holdsOwnReaderFormat(fileAt url: URL) -> Bool {
        guard let head = AudioContentSniffer.firstBytes(of: url, upTo: 10) else { return false }
        var offset = 0
        if head.count == 10, ascii(in: head, at: 0, is: "ID3"), head[6..<10].allSatisfy({ $0 & 0x80 == 0 }) {
            let size = head[6..<10].reduce(0) { $0 << 7 | Int($1) }
            offset = 10 + size + (head[5] & 0x10 != 0 ? 10 : 0)
        }
        guard let signature = AudioContentSniffer.firstBytes(of: url, upTo: 4, from: offset) else { return false }
        return ownReaderSignatures.contains { Array($0.utf8) == signature }
    }

    /// Whether `bytes` hold the ASCII `word` at `offset`, all inside them.
    private static func ascii(in bytes: [UInt8], at offset: Int, is word: String) -> Bool {
        let expected = Array(word.utf8)
        guard offset >= 0, offset + expected.count <= bytes.count else { return false }
        return Array(bytes[offset..<(offset + expected.count)]) == expected
    }
}

// MARK: - The ASF Header

/// What TextMouth reads of an ASF file's header (FMT31): only whether it is
/// copy-protected. A protected WMA or WMV file names its protection system
/// in its header, before any packet, in one of three objects:
/// - Content Encryption (Windows Media DRM version 1),
/// - Extended Content Encryption (version 7 and later), or
/// - Advanced Content Encryption (PlayReady), inside the Header Extension
///   object.
///
/// The header is a Header object (its identifier, its size, the number of
/// objects in it, and two reserved bytes: 30 bytes), followed by its
/// objects, each an identifier of 16 bytes and a 64-bit size that counts the
/// object's own 24 bytes; the Header Extension's objects follow 22 bytes of
/// its own fields. Every read is checked against the bytes at hand, every
/// size must cover at least its 24 bytes and end inside its parent, and the
/// walk stops at the first object that breaks either rule: a damaged header
/// is then judged by the objects before it.
enum ASFHeader {
    /// The most of a file's header read: 16 MB. A header holds every object
    /// before the packets, a cover picture included, which is seldom more
    /// than a megabyte. A protection object past this many bytes would go
    /// unseen, and the file on to ffmpeg; no such file is known.
    static let maximumHeaderBytes = 16 * 1_048_576

    /// The most objects walked in one header or extension, so a header of
    /// a million tiny objects costs a bounded walk.
    static let maximumObjects = 10_000

    /// The Header object's identifier, which every ASF file begins with.
    static let headerObjectID = guidBytes("75B22630-668E-11CF-A6D9-00AA0062CE6C")

    /// The Header Extension object's identifier, whose body holds the newer
    /// objects (metadata, PlayReady's encryption).
    static let headerExtensionID = guidBytes("5FBF03B5-A92E-11CF-8EE3-00C00C205365")

    /// The identifiers of the three objects that say the content is
    /// encrypted: Content Encryption, Extended Content Encryption, and
    /// Advanced Content Encryption.
    static let protectionObjectIDs: [[UInt8]] = [
        guidBytes("2211B3FB-BD23-11D2-B4B7-00A0C955FC6E"),
        guidBytes("298AE614-2622-4C17-B935-DAE07EE9289C"),
        guidBytes("43058533-6981-49E6-9B74-AD12CB86D58C"),
    ]

    /// The 16 bytes of the identifier `spelled` as the specification prints
    /// it ("75B22630-668E-11CF-A6D9-00AA0062CE6C"), in the order a file holds
    /// them: the first three groups little-endian, the last two as written.
    /// Every identifier here is a constant spelled correctly, so a malformed
    /// one yields fewer than 16 bytes, which no file's bytes can match.
    static func guidBytes(_ spelled: String) -> [UInt8] {
        let groups = spelled.split(separator: "-").map(String.init)
        guard groups.map(\.count) == [8, 4, 4, 4, 12] else { return [] }
        /// The bytes of a group of hexadecimal digits, two digits a byte.
        func bytes(_ group: String) -> [UInt8] {
            var result: [UInt8] = []
            var digits = Substring(group)
            while digits.count >= 2 {
                guard let byte = UInt8(digits.prefix(2), radix: 16) else { return [] }
                result.append(byte)
                digits = digits.dropFirst(2)
            }
            return result
        }
        var result: [UInt8] = []
        for (position, group) in groups.enumerated() {
            let groupBytes = bytes(group)
            // The first three groups are numbers stored little-endian.
            result += position < 3 ? Array(groupBytes.reversed()) : groupBytes
        }
        return result
    }

    /// Whether the ASF file at `url` is copy-protected; false when it is not
    /// an ASF file or cannot be read. Reads the header's first 30 bytes, then
    /// the header itself, at most `maximumHeaderBytes`.
    static func isCopyProtected(fileAt url: URL) -> Bool {
        guard let start = AudioContentSniffer.firstBytes(of: url, upTo: 30), start.count == 30,
              start.starts(with: headerObjectID) else { return false }
        let claimed = littleEndian(start, at: 16, count: 8) ?? 0
        let length = Int(min(claimed, UInt64(maximumHeaderBytes)))
        guard let header = AudioContentSniffer.firstBytes(of: url, upTo: length) else { return false }
        return isCopyProtected(header: header)
    }

    /// Whether `header`, the first bytes of an ASF file (its Header object,
    /// whole or in part), holds a protection object, at its top level or in
    /// its Header Extension. A pure function of the bytes.
    static func isCopyProtected(header: [UInt8]) -> Bool {
        guard header.count >= 30, header.starts(with: headerObjectID),
              let claimed = littleEndian(header, at: 16, count: 8) else { return false }
        let end = Int(min(claimed, UInt64(header.count)))
        return holdsProtection(header, from: 30, to: end, nested: true)
    }

    /// Whether an object between `start` and `end` of `bytes` is a
    /// protection object; with `nested`, a Header Extension's own objects
    /// are looked through too (one level: no extension nests another).
    private static func holdsProtection(_ bytes: [UInt8], from start: Int, to end: Int, nested: Bool) -> Bool {
        var position = start
        var walked = 0
        while position + 24 <= end, walked < maximumObjects {
            walked += 1
            guard let size = littleEndian(bytes, at: position + 16, count: 8), size >= 24,
                  size <= UInt64(end - position) else { return false }
            let identifier = Array(bytes[position..<(position + 16)])
            if protectionObjectIDs.contains(identifier) { return true }
            let objectEnd = position + Int(size)
            // The extension's objects start after its reserved identifier
            // (16 bytes), reserved number (2), and data size (4).
            if nested, identifier == headerExtensionID, position + 24 + 22 <= objectEnd,
               holdsProtection(bytes, from: position + 24 + 22, to: objectEnd, nested: false) {
                return true
            }
            position = objectEnd
        }
        return false
    }

    /// The little-endian unsigned number of `count` bytes (at most eight) at
    /// `offset` of `bytes`, or nil when they run past the end.
    private static func littleEndian(_ bytes: [UInt8], at offset: Int, count: Int) -> UInt64? {
        guard offset >= 0, count <= 8, offset + count <= bytes.count else { return nil }
        var value: UInt64 = 0
        for index in (0..<count).reversed() {
            value = value << 8 | UInt64(bytes[offset + index])
        }
        return value
    }
}
