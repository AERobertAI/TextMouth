import Darwin
import Foundation

/// What an audio file holds, told from its first bytes alone (review item 3
/// of the audiofmt team): the content decides whether the import converts a
/// file, not its extension, because Core Audio reads the content. An Ogg file
/// named .m4a opens as Ogg all the same, and a feed episode's extension comes
/// from the server's MIME type, so an MP2 file arrives as audio/mpeg named
/// .mp3 and an AIFC file as audio/x-aiff named .aiff.
///
/// Nothing here uses an Apple audio API (the October 14 rule: no source file
/// of a format the import converts is opened by Apple's audio frameworks in
/// the app's process). The file is opened with `open(2)`, read at most
/// `windowLength` bytes, and closed; the bytes are judged by hand.
enum AudioContentSniffer {
    /// What a file holds.
    enum Kind: Equatable, Sendable {
        /// Ogg ("OggS"): Vorbis, Opus, or FLAC in Ogg.
        case ogg
        /// AC-3 or Enhanced AC-3 (the sync word 0x0B77 begins both).
        case ac3
        /// Core Audio Format ("caff").
        case caf
        /// AIFF-C ("FORM", then "AIFC"), whose codec may be coded.
        case aifc
        /// AIFF ("FORM", then "AIFF"): linear PCM.
        case aiff
        /// Sun/NeXT AU (".snd").
        case au
        /// Sony Wave64 ("riff" and its GUID).
        case wave64
        /// AMR ("#!AMR").
        case amr
        /// 3GPP or 3GPP2 audio (an `ftyp` box of a `3gp` or `3g2` brand).
        case threeGPP
        /// Any other MPEG-4 or QuickTime file: an `ftyp` box of another
        /// brand, or a file that starts with a `moov`, `mdat`, `wide`,
        /// `free`, or `skip` box. What it holds depends on its tracks.
        case mpeg4
        /// WAVE ("RIFF", "RF64", or "BW64", then "WAVE"), whatever its codec.
        case wave
        /// FLAC ("fLaC").
        case flac
        /// MPEG audio, layer I.
        case mpegLayerI
        /// MPEG audio, layer II (MP2).
        case mpegLayerII
        /// MPEG audio, layer III (MP3).
        case mpegLayerIII
        /// ADTS AAC: MPEG audio framing with layer bits 00.
        case adts
        /// Nothing above: unreadable, empty, too short, or not recognized.
        case unknown
    }

    /// What the import does about a kind, from the bytes alone.
    enum Verdict: Equatable, Sendable {
        /// The import converts it, whatever the file's extension.
        case convert
        /// TextMouth plays it as it is.
        case leave
        /// The bytes do not settle it: `afinfo` must name what the file's
        /// first audio track holds (`AudioFileInfo`).
        case askAfinfo
    }

    /// How many bytes of a file are read: enough for a large ID3v2 tag's
    /// start and several frames, and no more.
    static let windowLength = 64 * 1024

    /// How far past the audio's start a frame pair is looked for: a little
    /// padding or junk after a tag is allowed, a long run of other data is not
    /// (a Matroska file with MP3 frames deep inside is not an MP3 file).
    static let frameSearchLength = 8 * 1024

    /// The bytes read to tell Ogg alone ("OggS").
    static let oggSignatureLength = 4

    // MARK: - The Kind

    /// What the file at `url` holds: `.unknown` when it cannot be read as a
    /// regular file, is only in the cloud, or is not recognized.
    ///
    /// An ID3v2 tag with cover art can run past the first window (audiobooks
    /// carry them often): the audio is then looked for in a second window,
    /// read at the tag's end, so such an MP3 is told from its frames and
    /// needs no `afinfo`.
    static func kind(of url: URL) -> Kind {
        guard let head = firstBytes(of: url, upTo: windowLength) else { return .unknown }
        let found = kind(of: head)
        let start = audioStart(in: head)
        guard found == .unknown, start >= head.count, text(in: head, at: 0, is: "ID3"),
              let next = firstBytes(of: url, upTo: windowLength, from: start) else { return found }
        return mpegAudioKind(in: next) ?? .unknown
    }

    /// What the file starts with, `bytes` being the first bytes of a file
    /// (at most `windowLength`). A pure function of the bytes; no byte is
    /// ever read past their end.
    static func kind(of bytes: [UInt8]) -> Kind {
        if let container = containerKind(of: bytes) { return container }
        return mpegAudioKind(in: bytes) ?? .unknown
    }

    /// What the import does about `kind`: convert the formats whose decoders
    /// should stay out of the app, leave those TextMouth plays, and ask
    /// `afinfo` about MPEG-4, QuickTime, and the rest. WAVE is left whatever
    /// its codec (a coded WAVE is a question for the user, not decided here).
    static func verdict(for kind: Kind) -> Verdict {
        switch kind {
        case .ogg, .ac3, .caf, .aifc, .au, .wave64, .amr, .threeGPP, .mpegLayerI, .mpegLayerII:
            return .convert
        case .mpegLayerIII, .adts, .wave, .aiff, .flac:
            return .leave
        case .mpeg4, .unknown:
            return .askAfinfo
        }
    }

    /// Whether the file at `url` starts with "OggS": one open and four
    /// bytes, for the guards that ask it on any thread. False for a file
    /// that cannot be read as a regular file or is only in the cloud.
    static func isOgg(at url: URL) -> Bool {
        guard let bytes = firstBytes(of: url, upTo: oggSignatureLength) else { return false }
        return kind(of: bytes) == .ogg
    }

    // MARK: - Reading

    /// The `count` bytes (fewer when the file ends sooner) of the file at
    /// `url` that start at `offset`, or nil when the file is only in the cloud (never
    /// downloaded), cannot be opened, or is not a regular file. The file is
    /// opened non-blocking and checked with `fstat` before it is read, so
    /// a FIFO or a device named like an audio file is never waited on.
    static func firstBytes(of url: URL, upTo count: Int, from offset: Int = 0) -> [UInt8]? {
        guard offset >= 0 else { return [] }
        // A file in the cloud only is never downloaded for a look at it.
        guard !DatalessFiles.isDataless(url) else { return nil }
        let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_NONBLOCK)
        }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG else { return nil }
        var buffer = [UInt8](repeating: 0, count: max(count, 0))
        var filled = 0
        // A short read is not the end of the file: read until the buffer is
        // full, the file ends (0), or the read fails.
        while filled < buffer.count {
            let got = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return pread(descriptor, base + filled, raw.count - filled, off_t(offset + filled))
            }
            if got < 0, errno == EINTR { continue }
            if got <= 0 { break }
            filled += got
        }
        return Array(buffer.prefix(filled))
    }

    // MARK: - Containers

    /// The kind of a container that announces itself in its first bytes, or
    /// nil when the bytes begin with none (MPEG audio is looked for next).
    private static func containerKind(of bytes: [UInt8]) -> Kind? {
        if bytes.starts(with: Array("OggS".utf8)) { return .ogg }
        if bytes.starts(with: [0x0B, 0x77]) { return .ac3 }
        if bytes.starts(with: Array("caff".utf8)) { return .caf }
        if bytes.starts(with: Array("FORM".utf8)) {
            if text(in: bytes, at: 8, is: "AIFC") { return .aifc }
            if text(in: bytes, at: 8, is: "AIFF") { return .aiff }
        }
        if bytes.starts(with: Array(".snd".utf8)) { return .au }
        if bytes.starts(with: wave64Signature) { return .wave64 }
        if bytes.starts(with: Array("#!AMR".utf8)) { return .amr }
        if let boxKind = mpeg4Kind(of: bytes) { return boxKind }
        if ["RIFF", "RF64", "BW64"].contains(where: { bytes.starts(with: Array($0.utf8)) }),
           text(in: bytes, at: 8, is: "WAVE") {
            return .wave
        }
        if bytes.starts(with: Array("fLaC".utf8)) { return .flac }
        return nil
    }

    /// Wave64's first 16 bytes: "riff" and the rest of its RIFF GUID
    /// (72696666-912E-11CF-A5D6-28DB04C10000, in file order).
    private static let wave64Signature: [UInt8] = [
        0x72, 0x69, 0x66, 0x66, 0x2E, 0x91, 0xCF, 0x11, 0xA5, 0xD6, 0x28, 0xDB, 0x04, 0xC1, 0x00, 0x00,
    ]

    /// The boxes an MPEG-4 or QuickTime file may begin with, besides `ftyp`.
    private static let openingBoxTypes = ["moov", "mdat", "wide", "free", "skip"]

    /// `.threeGPP` for an `ftyp` box with a `3gp` or `3g2` brand, `.mpeg4`
    /// for an `ftyp` box of any other brand or a file that starts with one
    /// of `openingBoxTypes`, nil otherwise. A box starts with its size (four
    /// bytes) and its type (four more); an `ftyp` box's brand follows.
    private static func mpeg4Kind(of bytes: [UInt8]) -> Kind? {
        if text(in: bytes, at: 4, is: "ftyp") {
            let brand = bytes.count >= 12 ? String(decoding: bytes[8..<12], as: UTF8.self) : ""
            return brand.hasPrefix("3gp") || brand.hasPrefix("3g2") ? .threeGPP : .mpeg4
        }
        if openingBoxTypes.contains(where: { text(in: bytes, at: 4, is: $0) }) { return .mpeg4 }
        return nil
    }

    /// Whether `bytes` holds the ASCII `word` at `offset`, all inside the bytes.
    private static func text(in bytes: [UInt8], at offset: Int, is word: String) -> Bool {
        let expected = Array(word.utf8)
        guard offset >= 0, offset + expected.count <= bytes.count else { return false }
        return Array(bytes[offset..<(offset + expected.count)]) == expected
    }

    // MARK: - MPEG Audio

    /// What an MPEG audio frame header says: enough to find the next frame.
    private struct FrameHeader {
        /// The layer, 1 to 3; 0 for an ADTS frame.
        let layer: Int
        /// The version bits (0 is MPEG 2.5, 2 is MPEG 2, 3 is MPEG 1), kept
        /// to compare one frame with the next.
        let version: Int
        /// The sample rate index, kept to compare one frame with the next.
        let sampleRateIndex: Int
        /// The frame's length in bytes, from this header to the next.
        let length: Int
    }

    /// The sample rates of MPEG 1, 2, and 2.5 by their index.
    private static let mpegSampleRates: [Int: [Int]] = [
        3: [44_100, 48_000, 32_000], 2: [22_050, 24_000, 16_000], 0: [11_025, 12_000, 8_000],
    ]

    /// MPEG 1's bit rates in kilobits a second, by layer (1 to 3) and index
    /// (1 to 14; the index 0 is free format and 15 is invalid).
    private static let mpeg1BitRates: [Int: [Int]] = [
        1: [32, 64, 96, 128, 160, 192, 224, 256, 288, 320, 352, 384, 416, 448],
        2: [32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384],
        3: [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
    ]

    /// MPEG 2's and 2.5's bit rates in kilobits a second: layer I's, and
    /// layers II's and III's, which are alike.
    private static let mpeg2BitRates: [Int: [Int]] = [
        1: [32, 48, 56, 64, 80, 96, 112, 128, 144, 160, 176, 192, 224, 256],
        2: [8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160],
    ]

    /// The frame header at `offset` of `bytes`, whether MPEG audio layer I,
    /// II, or III or ADTS AAC, or nil when the bytes there are no valid
    /// header. A header that gives no frame length (free format) is not valid.
    private static func frameHeader(in bytes: [UInt8], at offset: Int) -> FrameHeader? {
        guard offset >= 0, offset + 4 <= bytes.count, bytes[offset] == 0xFF, bytes[offset + 1] & 0xE0 == 0xE0 else {
            return nil
        }
        // ADTS has a 12-bit sync (0xFFF) and layer bits 00; its frame length
        // is 13 bits in bytes 3 to 5.
        if bytes[offset + 1] & 0xF6 == 0xF0 {
            guard offset + 6 <= bytes.count else { return nil }
            let length = (Int(bytes[offset + 3] & 0x03) << 11) | (Int(bytes[offset + 4]) << 3) | Int(bytes[offset + 5] >> 5)
            guard length >= 7 else { return nil }
            return FrameHeader(layer: 0, version: 0, sampleRateIndex: Int(bytes[offset + 2] >> 2) & 0x0F, length: length)
        }
        let version = Int(bytes[offset + 1] >> 3) & 0x03
        let layer = 4 - (Int(bytes[offset + 1] >> 1) & 0x03)
        let bitRateIndex = Int(bytes[offset + 2] >> 4)
        let sampleRateIndex = Int(bytes[offset + 2] >> 2) & 0x03
        let padding = Int(bytes[offset + 2] >> 1) & 0x01
        guard version != 1, layer <= 3, (1...14).contains(bitRateIndex), sampleRateIndex < 3,
              let sampleRate = mpegSampleRates[version]?[sampleRateIndex] else { return nil }
        let rates = version == 3 ? mpeg1BitRates[layer] : mpeg2BitRates[layer == 1 ? 1 : 2]
        guard let kilobits = rates?[bitRateIndex - 1] else { return nil }
        let bitRate = kilobits * 1_000
        let length: Int
        if layer == 1 {
            length = (12 * bitRate / sampleRate + padding) * 4
        } else if layer == 3, version != 3 {
            length = 72 * bitRate / sampleRate + padding
        } else {
            length = 144 * bitRate / sampleRate + padding
        }
        return FrameHeader(layer: layer, version: version, sampleRateIndex: sampleRateIndex, length: length)
    }

    /// Where the audio starts once the ID3v2 tags at the start of `bytes`
    /// are skipped: each tag is ten bytes of header, a size in four
    /// synchsafe bytes (seven bits each), and a ten-byte footer when its
    /// flags say so. A tag that claims to run past `bytes` ends the search
    /// (the offset is then past the end).
    private static func audioStart(in bytes: [UInt8]) -> Int {
        var offset = 0
        // A few tags in a row are allowed; no more, so no loop is unbounded.
        for _ in 0..<4 {
            guard text(in: bytes, at: offset, is: "ID3"), offset + 10 <= bytes.count else { break }
            let sizeBytes = bytes[(offset + 6)..<(offset + 10)]
            // A size byte with its top bit set is not synchsafe: no tag.
            guard sizeBytes.allSatisfy({ $0 & 0x80 == 0 }) else { break }
            let size = sizeBytes.reduce(0) { ($0 << 7) | Int($1) }
            let footer = bytes[offset + 5] & 0x10 != 0 ? 10 : 0
            offset += 10 + size + footer
        }
        return offset
    }

    /// The kind of the MPEG audio or ADTS AAC that `bytes` holds after any
    /// ID3v2 tag, or nil when none is found. A header counts only when the
    /// next frame's header, where this frame's length points, matches it (the
    /// same version, layer, and sample rate): a stray 0xFFE sync is common
    /// in other data. The search runs along the bytes after the tag, each
    /// candidate costing a constant amount.
    private static func mpegAudioKind(in bytes: [UInt8]) -> Kind? {
        var offset = audioStart(in: bytes)
        let end = min(bytes.count, offset + frameSearchLength)
        while offset + 4 <= end {
            if let header = frameHeader(in: bytes, at: offset),
               let next = frameHeader(in: bytes, at: offset + header.length),
               next.layer == header.layer, next.version == header.version, next.sampleRateIndex == header.sampleRateIndex {
                switch header.layer {
                case 0: return .adts
                case 1: return .mpegLayerI
                case 2: return .mpegLayerII
                default: return .mpegLayerIII
                }
            }
            offset += 1
        }
        return nil
    }
}
