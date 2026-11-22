import Darwin
import Foundation

// The parts TextMouth's own audio readers share: the bytes of a file read
// with every bound checked, the errors a reader ends in, what a reader says
// of a stream, and the reader's own shape.
//
// The readers (True Audio, WavPack, Monkey's Audio) decode formats neither
// macOS nor iOS reads. Each takes bytes it cannot trust inside the app's own
// process, so the rules are the same in all of them: no arithmetic that can
// trap on a file's bytes (wrapping operators, checked conversions), every
// read inside the bytes it was handed, and every loop limited by what the
// file holds. A damaged or crafted file ends in an `OwnAudioError`.

/// Why one of TextMouth's own audio readers gave a file up.
enum OwnAudioError: Error, Equatable, Sendable {
    /// The bytes are not of the format the reader reads.
    case notThisFormat
    /// The file is of the format, in a form the reader refuses; `reason`
    /// finishes the sentence "TextMouth can't read it because …"
    /// (`OwnAudioWording`).
    case unsupported(reason: String)
    /// The file ends before the audio its header promises.
    case truncated
    /// A checksum failed or a field holds a value no encoder writes.
    case damaged
    /// The file beside this one that completes it (a hybrid WavPack file's
    /// correction file) is damaged, cut short, or another recording's.
    case companionDamaged
}

/// The words a listener hears about a file one of the readers refuses. Each
/// reason finishes "… because <reason>."
enum OwnAudioWording {
    /// A True Audio file locked with a password (format 2).
    static let ttaPassword = "it is locked with a password" // l10n: no (a parser's damage reason: finishes "because …", question 3)
    /// A True Audio file of floating-point samples or another unknown form.
    static let ttaForm = "it is a kind of True Audio file TextMouth does not know" // l10n: no (a parser's damage reason: finishes "because …", question 3)
    /// A True Audio file whose channels, bit depth, or sample rate no
    /// encoder writes.
    static let ttaShape = "its channels, bit depth, or sample rate are outside what True Audio allows" // l10n: no (a parser's damage reason: finishes "because …", question 3)

    /// The sentence for a file named `fileName` given up with `error`. The
    /// reason inside "because …" is a parser's English (question 3).
    static func sentence(for error: OwnAudioError, fileName: String) -> String {
        switch error {
        case .notThisFormat:
            // Translators: Why an audio file could not be converted at import: its bytes are not of the format its extension names. %@ is the file's name.
            return InterfaceText.line("ownAudio.sentence.notThisFormat", "The audio file \(fileName) is not the kind of file its name says.")
        case let .unsupported(reason):
            // Translators: Why an audio file could not be converted at import: it is of a format TextMouth reads, in a form it refuses. %1$@ is the file's name and %2$@ the reason, a clause in English that follows "because" and has no full stop.
            return InterfaceText.line("ownAudio.sentence.unsupported", "TextMouth can't read the audio file \(fileName) because \(reason).")
        case .truncated:
            // Translators: Why an audio file could not be converted at import: the file stops before the audio its header promises. %@ is the file's name.
            return InterfaceText.line("ownAudio.sentence.truncated", "The audio file \(fileName) ends before its audio does, so it could not be converted.")
        case .damaged:
            // Translators: Why an audio file could not be converted at import: a checksum failed or a field holds a value no encoder writes. %@ is the file's name.
            return InterfaceText.line("ownAudio.sentence.damaged", "The audio file \(fileName) is damaged, so it could not be converted.")
        case .companionDamaged:
            // Translators: Why a hybrid WavPack file could not be converted at import: the correction file beside it (the same name ending in .wvc) is damaged or belongs to another recording. %1$@ is the correction file's name and %2$@ the WavPack file's name.
            return InterfaceText.line("ownAudio.sentence.companionDamaged", "The correction file \(companionName(of: fileName)) is damaged or belongs to another recording, so \(fileName) could not be converted.")
        }
    }

    /// The name of the correction file of the hybrid WavPack file named
    /// `fileName`: the same name ending in .wvc.
    static func companionName(of fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        guard let ending = OwnAudioFormat.wavPack.companionExtension else { return fileName }
        return (stem as NSString).appendingPathExtension(ending) ?? fileName
    }
}

/// What a reader says of the audio in a file, from its header alone.
struct OwnAudioStream: Equatable, Sendable {
    /// The sample rate in hertz, above 0.
    let sampleRate: Int
    /// The channel count, above 0.
    let channels: Int
    /// The bits in a sample, from 1 to 32.
    let bitsPerSample: Int
    /// Whether a sample is a 32-bit floating-point number, handed over as
    /// its bit pattern.
    var isFloat = false
    /// Whether decoding gives the encoder's input back exactly. False only
    /// for a WavPack hybrid file read without its correction file.
    var isLossless = true
    /// How many frames (one sample of every channel) the file holds.
    let frames: Int
    /// Which loudspeaker each channel is, as the bits of a WAVE channel
    /// mask, or nil when the file does not say.
    var channelMask: UInt32?

    /// How long the stream lasts, in seconds.
    var duration: TimeInterval {
        sampleRate > 0 ? Double(frames) / Double(sampleRate) : 0
    }
}

/// One of TextMouth's own audio readers, opened on a file: it hands the
/// audio over block by block, so memory stays small whatever the length.
protocol OwnAudioDecoder {
    /// What the header says of the audio.
    var stream: OwnAudioStream { get }

    /// The next block of samples, interleaved by channel, each a signed
    /// number of `stream.bitsPerSample` bits held in an `Int32` (or a
    /// float's bit pattern); nil once every frame has been handed over.
    /// A block is never empty.
    /// - Throws: `OwnAudioError`.
    mutating func nextBlock() throws -> [Int32]?
}

/// The bytes of one file, read a piece at a time with every bound checked:
/// a file on disk, read with `pread(2)` and never mapped (a mapped file
/// that shrinks under the reader ends the process), or bytes in memory,
/// which the tests and the fuzzers use.
final class OwnAudioBytes {
    /// The file's descriptor, or -1 for bytes in memory.
    private let descriptor: Int32
    /// The bytes in memory, empty for a file on disk.
    private let memory: [UInt8]
    /// How many bytes there are.
    let count: Int

    /// The bytes of the regular file at `path`; nil when it cannot be
    /// opened or is not a regular file. The file is opened non-blocking and
    /// checked with `fstat`, so a FIFO or a device is never waited on.
    init?(path: String) {
        let opened = open(path, O_RDONLY | O_NONBLOCK)
        guard opened >= 0 else { return nil }
        var status = stat()
        guard fstat(opened, &status) == 0, status.st_mode & S_IFMT == S_IFREG, status.st_size >= 0 else {
            close(opened)
            return nil
        }
        descriptor = opened
        memory = []
        count = Int(clamping: status.st_size)
    }

    /// Bytes already in memory.
    init(_ bytes: [UInt8]) {
        descriptor = -1
        memory = bytes
        count = bytes.count
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    /// Exactly `length` bytes starting at `offset`.
    /// - Throws: `OwnAudioError.truncated` when the file does not hold them
    ///   all, or the read fails.
    func read(at offset: Int, count length: Int) throws -> [UInt8] {
        guard offset >= 0, length >= 0, offset <= count, length <= count - offset else {
            throw OwnAudioError.truncated
        }
        guard length > 0 else { return [] }
        guard descriptor >= 0 else { return Array(memory[offset..<offset + length]) }
        var buffer = [UInt8](repeating: 0, count: length)
        var filled = 0
        // A short read is not the end: read on until the buffer is full.
        while filled < length {
            let got = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return pread(descriptor, base + filled, length - filled, off_t(offset + filled))
            }
            if got < 0, errno == EINTR { continue }
            guard got > 0 else { throw OwnAudioError.truncated }
            filled += got
        }
        return buffer
    }

    /// Up to `length` bytes starting at `offset`: fewer when the file ends
    /// sooner, and none when `offset` is outside it or the read fails.
    func readUpTo(at offset: Int, count length: Int) -> [UInt8] {
        guard offset >= 0, offset < count, length > 0 else { return [] }
        return (try? read(at: offset, count: min(length, count - offset))) ?? []
    }
}

/// Little-endian numbers read from bytes, with the bounds checked: a field
/// that is not wholly inside the bytes reads as nil.
enum OwnAudioLittleEndian {
    /// The unsigned 16-bit number at `offset`.
    static func uint16(_ bytes: [UInt8], _ offset: Int) -> UInt16? {
        guard offset >= 0, bytes.count >= 2, offset <= bytes.count - 2 else { return nil }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    /// The unsigned 32-bit number at `offset`.
    static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32? {
        guard offset >= 0, bytes.count >= 4, offset <= bytes.count - 4 else { return nil }
        return UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
    }

    /// Whether `bytes` holds the ASCII text `text` at `offset`.
    static func holds(_ bytes: [UInt8], _ text: String, at offset: Int) -> Bool {
        let wanted = Array(text.utf8)
        guard offset >= 0, bytes.count >= wanted.count, offset <= bytes.count - wanted.count else { return false }
        return bytes[offset..<offset + wanted.count].elementsEqual(wanted)
    }
}

/// The standard CRC-32 (polynomial 0xEDB88320), which True Audio and
/// Monkey's Audio put after their headers and frames.
enum OwnAudioCRC32 {
    /// The 256 values a byte steps the checksum by.
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1 }
        return value
    }

    /// The checksum of `bytes[range]`; the range must lie inside the bytes.
    static func checksum(_ bytes: [UInt8], in range: Range<Int>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        table.withUnsafeBufferPointer { table in
            bytes.withUnsafeBufferPointer { bytes in
                for index in range { crc = (crc >> 8) ^ table[Int((crc ^ UInt32(bytes[index])) & 0xFF)] }
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

/// The ID3v2 tag some files carry ahead of their audio.
enum OwnAudioLeadingTag {
    /// The length in bytes of an ID3v2 tag that starts `head`, the first
    /// bytes of a file, or 0 when it starts with none: the ten-byte header,
    /// the size its four 7-bit bytes give, and a footer when flagged.
    static func id3v2Length(in head: [UInt8]) -> Int {
        guard head.count >= 10, OwnAudioLittleEndian.holds(head, "ID3", at: 0) else { return 0 }
        var size = 0
        for index in 6..<10 { size = size << 7 | Int(head[index] & 0x7F) }
        return size + 10 + (head[5] & 0x10 != 0 ? 10 : 0)
    }
}
