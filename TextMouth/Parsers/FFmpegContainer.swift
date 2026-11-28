import Foundation

/// The containers only ffmpeg reads (FMT31, FMT32), told from a file's first
/// bytes alone, so the import names ffmpeg's demuxer itself (`-f`) and ffmpeg
/// never guesses a format from bytes it cannot trust; and whether a Windows
/// Media file, or a Matroska or WebM file, is copy-protected, which is refused
/// before any program runs.
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
        if bytes.starts(with: Array("MP+".utf8)), bytes.count > 3, bytes[3] & 0x0F == 7 { return .musepack7 } // l10n: no (a file-format signature, not interface text)
        if bytes.starts(with: Array("MPCK".utf8)) { return .musepack8 }
        if isOggSpeex(bytes) { return .oggSpeex }
        if bytes.starts(with: Array("OggS".utf8)) { return .ogg }
        return nil
    }

    /// The most beginning-of-stream pages looked through for a Speex header:
    /// an Ogg file's first pages begin its streams, one each, and a Skeleton
    /// track's may come before the sound's.
    static let maximumOpeningPages = 4

    /// Whether `bytes` begin an Ogg file one of whose first pages, those that
    /// begin its streams, holds a Speex header. An Ogg page is 27 bytes of
    /// header ("OggS", the version, the header type, whose bit 0x02 marks the
    /// beginning of a stream, the granule position, the serial number, the
    /// page number, and the checksum), then its number of segments and a
    /// table of that many lacing values, whose sum is the length of the
    /// packets that follow the table. A Speex header packet starts with
    /// "Speex" and three spaces. The walk stops at the first page that
    /// begins no stream, and never reads past `bytes`.
    static func isOggSpeex(_ bytes: [UInt8]) -> Bool {
        var page = 0
        for _ in 0..<maximumOpeningPages {
            let segmentCountOffset = page + 26
            guard ascii(in: bytes, at: page, is: "OggS"), segmentCountOffset < bytes.count,
                  bytes[page + 5] & 0x02 != 0 else { return false }
            let segments = Int(bytes[segmentCountOffset])
            let packets = segmentCountOffset + 1 + segments
            if segments > 0, ascii(in: bytes, at: packets, is: "Speex   ") { return true } // l10n: no (a file-format signature, not interface text)
            guard packets <= bytes.count else { return false }
            page = packets + bytes[(segmentCountOffset + 1)..<packets].reduce(0) { $0 + Int($1) }
        }
        return false
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
/// in its header, before any packet, in one of four objects:
/// - Content Encryption (Windows Media DRM version 1),
/// - Extended Content Encryption (version 7 and later),
/// - Advanced Content Encryption (Windows Media DRM for Network Devices),
///   inside the Header Extension object, or
/// - Protection System Identifier (PlayReady), inside the Header Extension
///   object too.
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
    /// objects (metadata, and the newer protection systems').
    static let headerExtensionID = guidBytes("5FBF03B5-A92E-11CF-8EE3-00C00C205365")

    /// The identifiers of the four objects that say the content is
    /// encrypted: Content Encryption, Extended Content Encryption, Advanced
    /// Content Encryption, and PlayReady's Protection System Identifier
    /// (review9 finding 4: without it a PlayReady file reached ffmpeg, which
    /// decodes the encrypted data as noise of the right length).
    static let protectionObjectIDs: [[UInt8]] = [
        guidBytes("2211B3FB-BD23-11D2-B4B7-00A0C955FC6E"),
        guidBytes("298AE614-2622-4C17-B935-DAE07EE9289C"),
        guidBytes("43058533-6981-49E6-9B74-AD12CB86D58C"),
        guidBytes("9A04F079-9840-4286-AB92-E65BE0885F95"),
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

// MARK: - The Matroska Header

/// What TextMouth reads of a Matroska or WebM file's header (B19): only
/// whether its sound is encrypted. The format is the Matroska specification,
/// RFC 9559 (Matroska Media Container Format, 2024), whose elements are
/// EBML, RFC 8794 (Extensible Binary Meta Language, 2020): the identifiers,
/// variable-size integers, and "unknown size" below are its. It puts an
/// encrypted track's mark in its track entry, before any sound:
/// Segment > Tracks > TrackEntry > ContentEncodings > ContentEncoding >
/// ContentEncryption, which counts only when the ContentEncoding's
/// ContentEncodingType (0x5033, default 0) is 1 (encryption; 0 is
/// compression, and a ContentEncryption beside it MUST be ignored), and
/// whose ContentEncAlgo is 0 for "not encrypted" and 1 to 5 for DES, 3DES,
/// Twofish, Blowfish, and AES. (A ContentCompression, which many good files
/// carry to strip headers, is no mark.)
///
/// The file is a tree of EBML elements: an identifier of 1 to 4 bytes (its
/// first byte's leading zeros give its length, and its marker bit is kept),
/// a size of 1 to 8 bytes (the same, with the marker bit taken off; all
/// ones means "unknown"), then the body. The walk reads each top-level
/// element's header alone and skips its body by its size, so a large file
/// costs a few small reads, and stops at the first Cluster (the sound
/// itself). The specification lets Tracks follow the Clusters when a
/// SeekHead names it, which the walk does not follow: such a file, rare
/// since writers put Tracks first, is not told as protected and goes on to
/// the session as it did before B19. Every read is
/// checked against the bytes at hand, every size must end inside its
/// parent, and the counts and sizes walked are bounded, so a damaged or
/// hostile header costs a bounded walk and is judged by what came before it.
///
/// Only audio tracks (TrackType 2) count, and the file is protected only
/// when it has one and every audio track is encrypted: a good file, whose
/// picture is encrypted and whose sound is not, or which has a plain sound
/// track beside an encrypted one, must never be called protected. A file
/// that names none of this is not protected.
enum MatroskaHeader {
    /// The identifiers (marker bits kept) of the elements the walk names.
    private enum ID {
        static let ebml: UInt32 = 0x1A45_DFA3
        static let segment: UInt32 = 0x1853_8067
        static let cluster: UInt32 = 0x1F43_B675
        static let tracks: UInt32 = 0x1654_AE6B
        static let trackEntry: UInt32 = 0xAE
        static let trackType: UInt32 = 0x83
        static let contentEncodings: UInt32 = 0x6D80
        static let contentEncoding: UInt32 = 0x6240
        static let contentEncodingType: UInt32 = 0x5033
        static let contentEncryption: UInt32 = 0x5035
        static let contentEncAlgo: UInt32 = 0x47E1
    }

    /// TrackType's value for an audio track.
    private static let audioTrackType: UInt64 = 2

    /// The most top-level elements stepped over before Tracks is found.
    static let maximumTopLevelElements = 1_000

    /// The most of a Tracks element read: 4 MB, far more than any file's
    /// track entries hold (a track's codec private data is the large part).
    static let maximumTracksBytes = 4 * 1_048_576

    /// The most elements walked inside one parent, so a body of a million
    /// tiny elements costs a bounded walk.
    static let maximumElements = 10_000

    /// An element's header: its identifier, where its body starts (from the
    /// header's own start), and the body's size (nil when it is "unknown").
    private struct Header {
        var id: UInt32
        var bodyStart: Int
        var size: UInt64?
    }

    /// An element inside bytes at hand: its identifier and its body's range.
    private struct Element {
        var id: UInt32
        var start: Int
        var end: Int
    }

    /// Whether the Matroska or WebM file at `url` is encrypted; false when
    /// it is not such a file or cannot be read. Reads the headers of the
    /// elements before Tracks, and Tracks whole (`maximumTracksBytes`).
    static func isCopyProtected(fileAt url: URL) -> Bool {
        isCopyProtected { offset, count in
            AudioContentSniffer.firstBytes(of: url, upTo: count, from: Int(clamping: offset)) ?? []
        }
    }

    /// Whether `bytes`, a file's bytes, whole or in part, hold an encrypted
    /// sound: the same walk over bytes at hand (the form the tests use).
    static func isCopyProtected(bytes: [UInt8]) -> Bool {
        isCopyProtected { offset, count in
            guard offset < UInt64(bytes.count) else { return [] }
            return Array(bytes[Int(offset)..<min(bytes.count, Int(offset) + count)])
        }
    }

    /// The walk over the file as `read` gives it: the bytes at an offset, up
    /// to a count, fewer (or none) where the file ends.
    private static func isCopyProtected(read: (UInt64, Int) -> [UInt8]) -> Bool {
        /// The header of the element that starts at `offset`, nil when the
        /// bytes there are no element's header.
        func headerAt(_ offset: UInt64) -> Header? {
            Self.header(in: read(offset, 12), at: 0)
        }
        // The EBML header comes first, then the Segment that holds the rest.
        guard let first = headerAt(0), first.id == ID.ebml, let firstSize = first.size,
              firstSize < UInt64(maximumTracksBytes) else { return false }
        var position = UInt64(first.bodyStart) + firstSize
        guard let segment = headerAt(position), segment.id == ID.segment else { return false }
        position += UInt64(segment.bodyStart)
        for _ in 0..<maximumTopLevelElements {
            guard let element = headerAt(position), element.id != ID.cluster, let size = element.size else { return false }
            let bodyAt = position + UInt64(element.bodyStart)
            if element.id == ID.tracks {
                guard size <= UInt64(maximumTracksBytes) else { return false }
                let body = read(bodyAt, Int(size))
                return UInt64(body.count) == size && holdsOnlyEncryptedSound(tracks: body)
            }
            let (next, overflowed) = bodyAt.addingReportingOverflow(size)
            guard !overflowed else { return false }
            position = next
        }
        return false
    }

    /// Whether `tracks`, the body of a Tracks element, holds an audio track
    /// and every one of its audio tracks is encrypted.
    private static func holdsOnlyEncryptedSound(tracks: [UInt8]) -> Bool {
        var audio = 0
        var encrypted = 0
        for entry in elements(in: tracks, from: 0, to: tracks.count) where entry.id == ID.trackEntry {
            let fields = elements(in: tracks, from: entry.start, to: entry.end)
            let type = fields.first { $0.id == ID.trackType }.flatMap { unsigned(tracks, $0) }
            guard type == audioTrackType else { continue }
            audio += 1
            if isEncrypted(trackFields: fields, in: tracks) { encrypted += 1 }
        }
        return audio > 0 && encrypted == audio
    }

    /// The ContentEncodingType's value for encryption (0, its default, is compression).
    private static let encryptionEncodingType: UInt64 = 1

    /// Whether a track entry's `fields` (elements of `bytes`) hold a
    /// ContentEncoding of type 1 (encryption) with a ContentEncryption whose
    /// algorithm is not 0 ("not encrypted"). A ContentEncryption in an
    /// encoding of any other type is ignored, as RFC 9559 says.
    private static func isEncrypted(trackFields fields: [Element], in bytes: [UInt8]) -> Bool {
        for encodings in fields where encodings.id == ID.contentEncodings {
            for encoding in elements(in: bytes, from: encodings.start, to: encodings.end) where encoding.id == ID.contentEncoding {
                let parts = elements(in: bytes, from: encoding.start, to: encoding.end)
                let type = parts.first { $0.id == ID.contentEncodingType }.flatMap { unsigned(bytes, $0) } ?? 0
                guard type == encryptionEncodingType else { continue }
                for part in parts where part.id == ID.contentEncryption {
                    let algorithm = elements(in: bytes, from: part.start, to: part.end)
                        .first { $0.id == ID.contentEncAlgo }.flatMap { unsigned(bytes, $0) }
                    if let algorithm, algorithm != 0 { return true }
                }
            }
        }
        return false
    }

    /// The elements, in order, between `start` and `end` of `bytes`, at most
    /// `maximumElements`. The walk stops at the first element whose header
    /// is broken, whose size is unknown, or whose body runs past `end`.
    private static func elements(in bytes: [UInt8], from start: Int, to end: Int) -> [Element] {
        var found: [Element] = []
        var position = start
        while position < end, found.count < maximumElements {
            let window = Array(bytes[position..<min(end, position + 12)])
            guard let head = header(in: window, at: 0), let size = head.size,
                  size <= UInt64(end - position - head.bodyStart) else { break }
            let bodyStart = position + head.bodyStart
            found.append(Element(id: head.id, start: bodyStart, end: bodyStart + Int(size)))
            position = bodyStart + Int(size)
        }
        return found
    }

    /// The element header at `offset` of `bytes`: an identifier of 1 to 4
    /// bytes, then a size of 1 to 8; nil when either is cut short or its
    /// first byte (0, or too many zeros) gives no such length.
    private static func header(in bytes: [UInt8], at offset: Int) -> Header? {
        guard offset < bytes.count else { return nil }
        let idLength = bytes[offset].leadingZeroBitCount + 1
        guard idLength <= 4, offset + idLength < bytes.count else { return nil }
        let id = bytes[offset..<(offset + idLength)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let sizeAt = offset + idLength
        let sizeLength = bytes[sizeAt].leadingZeroBitCount + 1
        guard sizeLength <= 8, sizeAt + sizeLength <= bytes.count else { return nil }
        // The size's marker bit is taken off; every other bit set is "unknown".
        var size = UInt64(bytes[sizeAt] & (0xFF >> UInt8(sizeLength)))
        for byte in bytes[(sizeAt + 1)..<(sizeAt + sizeLength)] { size = size << 8 | UInt64(byte) }
        let unknown = size == (UInt64(1) << UInt64(7 * sizeLength)) - 1
        return Header(id: id, bodyStart: sizeAt + sizeLength - offset, size: unknown ? nil : size)
    }

    /// The big-endian unsigned number an element's body holds (up to eight
    /// bytes; nil for an empty or longer body).
    private static func unsigned(_ bytes: [UInt8], _ element: Element) -> UInt64? {
        let length = element.end - element.start
        guard length > 0, length <= 8 else { return nil }
        return bytes[element.start..<element.end].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }
}
