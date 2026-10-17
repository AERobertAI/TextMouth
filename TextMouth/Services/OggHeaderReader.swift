import Foundation

/// Reads an Ogg Vorbis or Ogg Opus file's stream facts (codec, channels,
/// sample rate, duration) and tags from the file's own bytes, with no Apple
/// audio API: since October 14, 2026 Ogg audio never reaches AVFoundation
/// or AudioToolbox in the app's process, so a hand-written reader is the only
/// way to learn an Ogg file's length and tags at import.
///
/// Everything is pure Swift over two bounded windows of the file (its start
/// and its end). Nothing here may trap or loop without a bound, whatever the
/// bytes are: every length is checked against what remains of the buffer, and
/// a page is accepted only if it lies wholly inside the buffer and its CRC
/// verifies (RFC 3533), so a stray "OggS" in audio data costs nothing.
enum OggHeaderReader {
    /// The codecs this reader recognises.
    enum Codec: Equatable, Sendable { case vorbis, opus }

    /// The tags of the stream's comment packet; a field the file does not
    /// carry is empty.
    struct Tags: Equatable, Sendable {
        var title = "", artist = "", album = "", genre = "", date = ""
    }

    /// What the reader learns of a file.
    struct Header: Equatable, Sendable {
        /// The stream's codec.
        let codec: Codec
        /// The channel count, above 0.
        let channels: Int
        /// The sample rate in hertz; for Opus always 48,000 (the decoder's rate).
        let sampleRate: Double
        /// The stream's length in seconds: above 0 and at most `maximumDuration`.
        let duration: TimeInterval
        /// The tags, empty when the comment packet is missing or too large.
        let tags: Tags
    }

    /// How many bytes are read from the start of a file: its identification
    /// and comment packets.
    static let headLength = 256 * 1024
    /// How many bytes are read from the end of a file: an Ogg page is at
    /// most 65,307 bytes, so this holds at least one whole last page.
    static let tailLength = 70_000

    // MARK: - Limits

    /// The largest comment packet read; a larger one (cover art) gives empty tags.
    private static let maxPacketLength = 256 * 1024
    /// The most comments read from a comment packet.
    private static let maxComments = 1_000
    /// The most candidate pages, found by their "OggS", that may fail their
    /// checks while the tail is searched, which bounds the search's work.
    private static let maxRejectedCandidates = 256
    /// The Opus decoder's sample rate, whatever the file was recorded at.
    private static let opusSampleRate = 48_000.0
    /// The longest stream believed: a year. A granule position that claims more is
    /// corrupt, not audio, and refusing it keeps every later conversion of the
    /// length to whole seconds (`Int(seconds)`) from overflowing and trapping.
    static let maximumDuration: TimeInterval = 365 * 24 * 3_600

    // MARK: - CRC

    /// The CRC-32 lookup table (polynomial 0x04C11DB7, most significant bit
    /// first), built once.
    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index) << 24
        for _ in 0..<8 {
            value = (value & 0x8000_0000) != 0 ? (value << 1) ^ 0x04C1_1DB7 : value << 1
        }
        return value
    }

    /// The CRC of an Ogg page, as the page header stores it: CRC-32 with
    /// polynomial 0x04C11DB7, initial value 0, no bit reflection and no final
    /// xor, over the whole page with the CRC field (bytes 22 to 25) read as
    /// zero, whatever those bytes hold.
    static func crc<Bytes: Sequence>(of page: Bytes) -> UInt32 where Bytes.Element == UInt8 {
        var value: UInt32 = 0
        for (offset, byte) in page.enumerated() {
            let effective: UInt8 = (22..<26).contains(offset) ? 0 : byte
            value = (value << 8) ^ crcTable[Int((value >> 24) ^ UInt32(effective))]
        }
        return value
    }

    // MARK: - Reading a file

    /// The header of the Ogg Vorbis or Opus file at `url`, read from its
    /// first `headLength` and last `tailLength` bytes only; nil when it is
    /// not a regular, readable Ogg Vorbis or Opus file.
    static func read(at url: URL) -> Header? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let headData = try? handle.read(upToCount: headLength) else { return nil }
        // The tail starts `tailLength` bytes before the end (or at the start
        // of a shorter file, which is then read whole).
        let tailStart = UInt64(max(0, size - tailLength))
        guard (try? handle.seek(toOffset: tailStart)) != nil,
              let tailData = try? handle.read(upToCount: tailLength) else { return nil }
        // Copy into zero-based arrays: a Data slice's indices need not start at 0.
        return parse(head: [UInt8](headData), tail: [UInt8](tailData))
    }

    /// The header of an Ogg file from `head`, its first bytes, and `tail`, its
    /// last bytes (the two may overlap, and for a short file are both the
    /// whole file); nil when they are not a whole Ogg Vorbis or Opus stream's
    /// start and end. Pure: it reads nothing but the two arrays.
    static func parse(head: [UInt8], tail: [UInt8]) -> Header? {
        guard let start = streamStart(in: head),
              let granule = lastGranule(in: tail, serial: start.serial) else { return nil }

        // The stream's length from the last page that ends a packet.
        let seconds: Double
        switch start.codec {
        case .vorbis:
            seconds = Double(granule) / start.sampleRate
        case .opus:
            // The first `preSkip` samples are the decoder's warm-up.
            seconds = Double(max(0, granule - Int64(start.preSkip))) / opusSampleRate
        }
        guard seconds.isFinite, seconds > 0, seconds <= maximumDuration else { return nil }

        return Header(codec: start.codec, channels: start.channels,
                      sampleRate: start.sampleRate, duration: seconds, tags: start.tags)
    }

    // MARK: - Pages

    /// One Ogg page that passed every check.
    private struct Page {
        /// The header-type flags: 0x01 continued packet, 0x02 first page.
        let type: UInt8
        /// The granule position; -1 means no packet ends on the page.
        let granule: Int64
        /// The serial number of the page's logical stream.
        let serial: UInt32
        /// The lacing values, one per segment.
        let lacing: [UInt8]
        /// Where the page's payload starts in the buffer.
        let payloadStart: Int
        /// The index just past the page in the buffer.
        let end: Int
    }

    /// A little-endian unsigned integer of type `T` at `index` in `bytes`;
    /// nil when it does not wholly lie inside the buffer.
    private static func littleEndian<T: FixedWidthInteger & UnsignedInteger>(
        _ bytes: [UInt8], at index: Int, as type: T.Type = T.self
    ) -> T? {
        let size = MemoryLayout<T>.size
        guard index >= 0, index <= bytes.count, bytes.count - index >= size else { return nil }
        var value: T = 0
        // Most significant byte first, so each earlier byte is shifted up.
        for offset in (0..<size).reversed() {
            value = (value << 8) | T(bytes[index + offset])
        }
        return value
    }

    /// Whether "OggS" starts at `index` in `bytes`.
    private static func hasMagic(_ bytes: [UInt8], at index: Int) -> Bool {
        index >= 0 && index <= bytes.count && bytes.count - index >= 4
            && Array(bytes[index..<(index + 4)]) == [0x4F, 0x67, 0x67, 0x53]
    }

    /// The page starting at `index` in `bytes`, or nil when there is no
    /// valid one: no "OggS", a version other than 0, no segments, a header or
    /// payload that runs past the buffer, or a CRC that does not verify.
    private static func page(in bytes: [UInt8], at index: Int) -> Page? {
        guard hasMagic(bytes, at: index), bytes.count - index >= 27,
              bytes[index + 4] == 0,                                // version
              let granuleBits = littleEndian(bytes, at: index + 6, as: UInt64.self),
              let serial = littleEndian(bytes, at: index + 14, as: UInt32.self),
              let storedCRC = littleEndian(bytes, at: index + 22, as: UInt32.self) else { return nil }

        let segmentCount = Int(bytes[index + 26])
        let headerLength = 27 + segmentCount
        guard segmentCount > 0, bytes.count - index >= headerLength else { return nil }
        let lacing = Array(bytes[(index + 27)..<(index + headerLength)])
        // At most 255 segments of at most 255 bytes: no overflow.
        let payloadLength = lacing.reduce(0) { $0 + Int($1) }
        guard bytes.count - index - headerLength >= payloadLength else { return nil }

        let end = index + headerLength + payloadLength
        guard crc(of: bytes[index..<end]) == storedCRC else { return nil }
        return Page(type: bytes[index + 5], granule: Int64(bitPattern: granuleBits), serial: serial,
                    lacing: lacing, payloadStart: index + headerLength, end: end)
    }

    /// The granule position of the last page of stream `serial` in `tail`
    /// that ends a packet (a granule of 0 or more); nil when there is none.
    /// `tail` may begin in the middle of a page, so it is searched for
    /// "OggS" and each candidate is checked, with a bound on the failures.
    private static func lastGranule(in tail: [UInt8], serial: UInt32) -> Int64? {
        var found: Int64?
        var index = 0
        var rejected = 0
        while index < tail.count {
            // The next candidate: a byte that starts "OggS". Bytes that only
            // look like it are passed over without counting as failures.
            guard let candidate = tail[index...].firstIndex(of: 0x4F) else { break }
            guard hasMagic(tail, at: candidate) else {
                index = candidate + 1
                continue
            }
            if let page = page(in: tail, at: candidate) {
                if page.serial == serial, page.granule >= 0 { found = page.granule }
                index = page.end
            } else {
                rejected += 1
                if rejected > maxRejectedCandidates { break }
                index = candidate + 1
            }
        }
        return found
    }

    // MARK: - Packets

    /// Joins the segments of one logical stream's pages into packets. A
    /// packet ends at the first lacing value below 255; 255 continues into
    /// the next segment, and into the next page, whose type then has 0x01.
    private struct PacketAssembler {
        /// The bytes of the packet in progress.
        private var current: [UInt8] = []
        /// Whether a packet is in progress, ended by no lacing value yet.
        private var inProgress = false

        /// Takes `page`, of `bytes`, and returns the packets it completes;
        /// nil when the page contradicts the packets so far (a continuation
        /// of nothing, or a packet left unfinished) or a packet outgrows
        /// `maxPacketLength`.
        mutating func feed(_ page: Page, of bytes: [UInt8]) -> [[UInt8]]? {
            let continues = page.type & 0x01 != 0
            guard continues == inProgress else { return nil }

            var completed: [[UInt8]] = []
            var position = page.payloadStart
            for value in page.lacing {
                let length = Int(value)
                current.append(contentsOf: bytes[position..<(position + length)])
                position += length
                guard current.count <= OggHeaderReader.maxPacketLength else { return nil }
                if value < 255 {
                    completed.append(current)
                    current = []
                    inProgress = false
                } else {
                    inProgress = true
                }
            }
            return completed
        }
    }

    // MARK: - The stream's start

    /// What the first two packets of a stream tell.
    private struct StreamStart {
        let serial: UInt32
        let codec: Codec
        let channels: Int
        let sampleRate: Double
        /// The Opus pre-skip, in 48,000 Hz samples; 0 for Vorbis.
        let preSkip: Int
        let tags: Tags
    }

    /// The first packet that ends on `page`, a first ("start of stream")
    /// page, taken from `bytes`: the payload up to the first lacing value
    /// below 255. Nil when no packet ends on the page (every lacing value is
    /// 255, so the packet runs on) or the page continues an earlier packet.
    private static func firstPacket(on page: Page, of bytes: [UInt8]) -> [UInt8]? {
        guard page.type & 0x01 == 0 else { return nil }
        var length = 0
        for value in page.lacing {
            length += Int(value)
            // The page was checked to hold its whole payload, so this range is inside `bytes`.
            if value < 255 { return Array(bytes[page.payloadStart..<(page.payloadStart + length)]) }
        }
        return nil
    }

    /// The serial of the Vorbis or Opus stream among the leading
    /// start-of-stream pages of `head`, with the format its identification
    /// packet declares. A multiplexed file begins with one such page per
    /// stream (RFC 3533 section 4), and an Ogg Skeleton stream's "fishead"
    /// may come first, so the first page's stream is not necessarily the
    /// audio: the walk goes on while pages have the start flag (a page that
    /// fails its checks ends it, keeping what was found), tries each new
    /// serial's first packet, and takes the first that `identify` accepts.
    /// Nil when the first page lacks the start flag or no leading stream is
    /// Vorbis or Opus (FLAC, Speex, Theora, an unknown codec).
    private static func audioStream(in head: [UInt8])
        -> (serial: UInt32, format: (codec: Codec, channels: Int, sampleRate: Double, preSkip: Int))? {
        var seen = Set<UInt32>()
        var index = 0
        while let current = page(in: head, at: index), current.type & 0x02 != 0 {
            // Two start pages of one serial count once.
            if seen.insert(current.serial).inserted,
               let packet = firstPacket(on: current, of: head),
               let format = identify(packet) {
                return (current.serial, format)
            }
            index = current.end
        }
        return nil
    }

    /// The Vorbis or Opus stream among the leading pages of `head`: its codec
    /// and format from its first packet, and its tags from its second; nil
    /// when no leading stream is Vorbis or Opus (see `audioStream(in:)`). The
    /// tags are empty when the comment packet is missing, spans past `head`,
    /// or is larger than `maxPacketLength`.
    private static func streamStart(in head: [UInt8]) -> StreamStart? {
        guard let (serial, format) = audioStream(in: head) else { return nil }

        // Assemble only that stream's packets from the first page again: the
        // pages of the other streams (Skeleton's, a video's) are passed over.
        var assembler = PacketAssembler()
        var packets: [[UInt8]] = []
        var index = 0
        while let current = page(in: head, at: index) {
            if current.serial == serial {
                guard let completed = assembler.feed(current, of: head) else { break }
                packets += completed
                if packets.count >= 2 { break }
            }
            index = current.end
        }

        let tags = packets.count >= 2 ? parseTags(packets[1], codec: format.codec) : Tags()
        return StreamStart(serial: serial, codec: format.codec, channels: format.channels,
                           sampleRate: format.sampleRate, preSkip: format.preSkip, tags: tags)
    }

    /// The codec, channel count, sample rate and Opus pre-skip an
    /// identification packet declares; nil for any other kind of packet
    /// (FLAC, Speex, Theora, and so on) or a nonsensical value.
    private static func identify(_ packet: [UInt8])
        -> (codec: Codec, channels: Int, sampleRate: Double, preSkip: Int)? {
        if hasPrefix(packet, signature: [0x01] + Array("vorbis".utf8)) {
            // 0x01 "vorbis", version (UInt32, 0), channels (byte), sample rate (UInt32).
            guard littleEndian(packet, at: 7, as: UInt32.self) == 0,
                  packet.count > 11, packet[11] > 0,
                  let rate = littleEndian(packet, at: 12, as: UInt32.self), rate > 0 else { return nil }
            return (.vorbis, Int(packet[11]), Double(rate), 0)
        }
        if hasPrefix(packet, signature: Array("OpusHead".utf8)) {
            // "OpusHead", version (byte, high nibble 0), channels (byte), pre-skip (UInt16).
            guard packet.count > 9, packet[8] & 0xF0 == 0, packet[9] > 0,
                  let preSkip = littleEndian(packet, at: 10, as: UInt16.self) else { return nil }
            return (.opus, Int(packet[9]), opusSampleRate, Int(preSkip))
        }
        return nil
    }

    /// Whether `bytes` begin with `signature`.
    private static func hasPrefix(_ bytes: [UInt8], signature: [UInt8]) -> Bool {
        bytes.count >= signature.count && Array(bytes[0..<signature.count]) == signature
    }

    // MARK: - Tags

    /// The tags in a comment packet: its signature (Vorbis `0x03 "vorbis"`,
    /// Opus `"OpusTags"`), the vendor string, then the comments, each a
    /// length and a UTF-8 `NAME=value`. Names match case-insensitively and the
    /// first of a name wins; at most `maxComments` are read, and reading
    /// stops at the first inconsistent length, keeping what was read.
    private static func parseTags(_ packet: [UInt8], codec: Codec) -> Tags {
        let signature = codec == .vorbis ? [0x03] + Array("vorbis".utf8) : Array("OpusTags".utf8)
        guard hasPrefix(packet, signature: signature) else { return Tags() }

        /// The length-prefixed block at `index` and the index after it.
        func block(at index: Int) -> (bytes: ArraySlice<UInt8>, next: Int)? {
            guard let length = littleEndian(packet, at: index, as: UInt32.self) else { return nil }
            let start = index + 4
            guard Int(length) <= packet.count - start else { return nil }
            return (packet[start..<(start + Int(length))], start + Int(length))
        }

        // The vendor string, then the comment count.
        guard let vendor = block(at: signature.count),
              let count = littleEndian(packet, at: vendor.next, as: UInt32.self) else { return Tags() }
        var index = vendor.next + 4

        var values: [String: String] = [:]
        for _ in 0..<min(Int(count), maxComments) {
            guard let comment = block(at: index) else { break }
            index = comment.next
            // NAME=value: a comment with no "=" is skipped.
            guard let equals = comment.bytes.firstIndex(of: 0x3D) else { continue }
            let name = String(decoding: comment.bytes[comment.bytes.startIndex..<equals], as: UTF8.self)
                .uppercased()
            if values[name] == nil {
                values[name] = String(decoding: comment.bytes[(equals + 1)...], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        // The artist is ARTIST, else PERFORMER.
        let artist = values["ARTIST"].flatMap { $0.isEmpty ? nil : $0 } ?? values["PERFORMER"] ?? ""
        return Tags(title: values["TITLE"] ?? "", artist: artist, album: values["ALBUM"] ?? "",
                    genre: values["GENRE"] ?? "", date: values["DATE"] ?? "")
    }
}
