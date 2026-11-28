import Foundation
private import TextMouthFFmpegProtocol

/// Reads the stream TextMouth's FFmpeg session writes (FMT50), whose one
/// definition is TextMouthFFmpeg/include/TextMouthFFmpegProtocol.h: HEAD,
/// INFO, the file's and the stream's tags (TAG, STAG), the chapters (CHAP),
/// then, in a decode, the samples (PCM), and END.
///
/// The bytes come in pieces of any size from `nextPiece`: on the Mac, what
/// the bundled helper wrote to its pipe (`WatchedProcess.PipeReader`); for a
/// stream already in memory, all of it at once (`init(data:)`). The iPhone,
/// which runs the session in its own process, can hand over each record as
/// the session gives it. Everything is checked against the protocol's
/// limits, so a helper that writes nonsense costs a failed import, never the
/// app's memory: a record longer than its kind allows, of an unknown kind, or
/// out of its order; more tags or chapters than the protocol writes; samples
/// that are not whole frames, or no samples at all (the session never writes
/// an empty PCM record); and an END that counts other frames than came.
struct FFmpegHelperStream {
    /// Why the stream could not be read.
    enum StreamError: Error, Equatable, Sendable {
        /// The first record is not HEAD of this protocol's version: the
        /// helper and the app were built from different sources.
        case otherProtocol
        /// A record breaks the protocol (see the type's comment).
        case damaged
        /// The stream ended before its END record.
        case endedEarly
    }

    /// One record: its kind (four ASCII letters as a little-endian number)
    /// and its payload.
    struct Record {
        let kind: UInt32
        let payload: [UInt8]
    }

    /// The bytes of each piece asked of a pipe: 256 KB, about a PCM record
    /// as the session writes them. A longer record is gathered from several
    /// pieces, and a pipe gives less at a time anyway.
    static let pieceBytes = 256 * 1_024

    /// Gives the next bytes of the stream, empty at its end.
    private let nextPiece: () async throws -> [UInt8]
    /// Bytes read and not yet framed, from `position` on.
    private var buffered: [UInt8] = []
    private var position = 0
    /// Whether `nextPiece` has said the stream is over.
    private var atEnd = false
    /// A record read past the report (the first PCM, or END), kept for
    /// `nextBlock()`.
    private var pending: Record?
    /// The report, once `readReport()` has read it.
    private(set) var report: FFmpegReport?
    /// The frames handed over so far, which END must count.
    private(set) var framesRead: UInt64 = 0
    /// Whether END has been read.
    private(set) var isFinished = false
    /// How many packets and frames the decoder refused, as END says: more
    /// than none in a damaged file, whose sound is converted all the same.
    private(set) var refusedPackets: UInt32 = 0
    private(set) var refusedFrames: UInt32 = 0

    /// A stream whose bytes `nextPiece` gives, empty at the end.
    init(reading nextPiece: @escaping () async throws -> [UInt8]) {
        self.nextPiece = nextPiece
    }

    /// A stream whose bytes are all in `data`.
    init(data: Data) {
        let bytes = [UInt8](data)
        var given = false
        self.init(reading: {
            defer { given = true }
            return given ? [] : bytes
        })
    }

    // MARK: - Records

    /// Reads until `count` bytes are buffered past `position`; false when the
    /// stream ends first.
    private mutating func fill(_ count: Int) async throws -> Bool {
        while buffered.count - position < count {
            if atEnd { return false }
            let piece = try await nextPiece()
            if piece.isEmpty {
                atEnd = true
                return false
            }
            // Bytes already framed go before the buffer grows past a few megabytes.
            if position > 0, position >= buffered.count / 2 {
                buffered.removeFirst(position)
                position = 0
            }
            buffered.append(contentsOf: piece)
        }
        return true
    }

    /// The next record; nil at a clean end, between two records.
    /// - Throws: `StreamError.endedEarly` for a stream cut inside a record,
    ///   `.damaged` for a length past its kind's limit.
    mutating func nextRecord() async throws -> Record? {
        let header = Int(TMFF_RECORD_HEADER_BYTES)
        guard try await fill(header) else {
            if buffered.count > position { throw StreamError.endedEarly }
            return nil
        }
        let kind = Self.number32(buffered, at: position)
        let length = Int(Self.number32(buffered, at: position + 4))
        let limit = kind == UInt32(TMFF_RECORD_PCM) ? Int(TMFF_MAX_PCM_RECORD_BYTES) : Int(TMFF_MAX_RECORD_BYTES)
        guard length <= limit else { throw StreamError.damaged }
        guard try await fill(header + length) else { throw StreamError.endedEarly }
        let start = position + header
        let payload = Array(buffered[start..<(start + length)])
        position = start + length
        return Record(kind: kind, payload: payload)
    }

    // MARK: - The Report

    /// Reads HEAD, INFO, and the tags and chapters that follow, up to the
    /// first PCM record or END, and returns what they say (also kept as
    /// `report`).
    /// - Throws: `StreamError`: `.otherProtocol` for a stream of another
    ///   version, `.damaged` for a record out of order or past the counts the
    ///   protocol writes, or an INFO that says no sound.
    mutating func readReport() async throws -> FFmpegReport {
        guard let head = try await nextRecord() else { throw StreamError.endedEarly }
        guard head.kind == UInt32(TMFF_RECORD_HEAD), head.payload.count >= 4,
              Self.number32(head.payload, at: 0) == UInt32(TMFF_PROTOCOL_VERSION) else {
            throw StreamError.otherProtocol
        }
        guard let infoRecord = try await nextRecord() else { throw StreamError.endedEarly }
        guard infoRecord.kind == UInt32(TMFF_RECORD_INFO) else { throw StreamError.damaged }
        let info = Self.lines(of: infoRecord.payload)
        var fileTags: [(String, String)] = []
        var streamTags: [(String, String)] = []
        var chapters: [FFmpegReport.Chapter] = []
        while true {
            guard let record = try await nextRecord() else { throw StreamError.endedEarly }
            switch record.kind {
            case UInt32(TMFF_RECORD_TAG):
                guard fileTags.count < Int(TMFF_MAX_TAGS) else { throw StreamError.damaged }
                fileTags.append(try Self.tag(of: record.payload))
            case UInt32(TMFF_RECORD_STAG):
                guard streamTags.count < Int(TMFF_MAX_TAGS) else { throw StreamError.damaged }
                streamTags.append(try Self.tag(of: record.payload))
            case UInt32(TMFF_RECORD_CHAP):
                guard chapters.count < Int(TMFF_MAX_CHAPTERS) else { throw StreamError.damaged }
                chapters.append(try Self.chapter(of: record.payload))
            case UInt32(TMFF_RECORD_PCM), UInt32(TMFF_RECORD_END):
                pending = record
                guard let report = FFmpegReport(info: info, fileTags: fileTags, streamTags: streamTags, chapters: chapters) else {
                    throw StreamError.damaged
                }
                self.report = report
                return report
            default:
                throw StreamError.damaged
            }
        }
    }

    /// The little-endian 32-bit number at `offset` of `bytes`.
    private static func number32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { value, index in value | UInt32(bytes[offset + index]) << (8 * index) }
    }

    /// The little-endian 64-bit number at `offset` of `bytes`.
    private static func number64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        UInt64(number32(bytes, at: offset)) | UInt64(number32(bytes, at: offset + 4)) << 32
    }

    /// INFO's "key=value" lines as a dictionary; a line without "=" is left out.
    static func lines(of payload: [UInt8]) -> [String: String] {
        var values: [String: String] = [:]
        for line in String(decoding: payload, as: UTF8.self).split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            values[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return values
    }

    /// The most bytes of a TAG or STAG payload: a key, its zero byte, and a
    /// value, each at the protocol's most. Held to this, the tags and
    /// chapters of a stream take at most about 21 MB, whatever wrote them.
    static let maximumTagRecordBytes = Int(TMFF_MAX_TAG_KEY_BYTES) + 1 + Int(TMFF_MAX_TAG_VALUE_BYTES)

    /// The most bytes of a CHAP payload: its two times and a title at the
    /// protocol's most.
    static let maximumChapterRecordBytes = 16 + Int(TMFF_MAX_TAG_VALUE_BYTES)

    /// A TAG or STAG payload: the key, a zero byte, the value (UTF-8; what
    /// is not becomes U+FFFD, which the report reads as missing).
    /// - Throws: `StreamError.damaged` for a payload past the protocol's
    ///   most, or with no zero byte.
    private static func tag(of payload: [UInt8]) throws -> (String, String) {
        guard payload.count <= maximumTagRecordBytes, let zero = payload.firstIndex(of: 0) else { throw StreamError.damaged }
        let key = String(decoding: payload[..<zero], as: UTF8.self)
        let value = String(decoding: payload[(zero + 1)...], as: UTF8.self)
        return (key, value)
    }

    /// A CHAP payload: its start and end in seconds (64-bit floating point;
    /// an end that is not a number is none), then its title.
    /// - Throws: `StreamError.damaged` for a payload too short for its times
    ///   or past the protocol's most.
    private static func chapter(of payload: [UInt8]) throws -> FFmpegReport.Chapter {
        guard payload.count >= 16, payload.count <= maximumChapterRecordBytes else { throw StreamError.damaged }
        let start = Double(bitPattern: number64(payload, at: 0))
        let end = Double(bitPattern: number64(payload, at: 8))
        let title = String(decoding: payload[16...], as: UTF8.self)
        return FFmpegReport.Chapter(
            start: start, end: end.isFinite ? end : nil,
            title: title.unicodeScalars.contains("\u{FFFD}") ? "" : FFmpegReport.cut(title, toBytes: FFmpegReport.maximumTagBytes)
        )
    }

    // MARK: - The Samples

    /// The next block of samples, interleaved by channel, as TextMouth's own
    /// readers hand theirs over (`OwnAudioDecoder.nextBlock()`): each a signed
    /// number of the report's `bits` bits in an `Int32`, or a 32-bit float's
    /// bit pattern; nil once END has been read and checked. A probe's stream
    /// has none: its first call reads END.
    /// - Throws: `StreamError`: `.endedEarly` when the stream ends before END,
    ///   `.damaged` for samples that are not whole frames, a record out of
    ///   order, or an END that counts other frames than came.
    mutating func nextBlock() async throws -> [Int32]? {
        guard !isFinished else { return nil }
        guard let report, let format = report.sampleFormat, let channels = report.channels else {
            throw StreamError.damaged
        }
        while true {
            let record: Record
            if let waiting = pending {
                record = waiting
                pending = nil
            } else if let read = try await nextRecord() {
                record = read
            } else {
                throw StreamError.endedEarly
            }
            switch record.kind {
            case UInt32(TMFF_RECORD_PCM):
                let block = try Self.samples(of: record.payload, format: format, channels: channels)
                // The session never writes a PCM record with no samples, so
                // an empty one means the stream is not what the session wrote.
                guard !block.isEmpty else { throw StreamError.damaged }
                framesRead += UInt64(block.count / channels)
                return block
            case UInt32(TMFF_RECORD_END):
                guard record.payload.count >= 16, Self.number64(record.payload, at: 0) == framesRead else {
                    throw StreamError.damaged
                }
                refusedPackets = Self.number32(record.payload, at: 8)
                refusedFrames = Self.number32(record.payload, at: 12)
                isFinished = true
                return nil
            default:
                throw StreamError.damaged
            }
        }
    }

    /// A PCM record's samples as `Int32`s: 16-bit numbers widened, 32-bit
    /// numbers and floats' bit patterns as they are.
    /// - Throws: `StreamError.damaged` when the payload is not whole frames.
    ///   An empty payload is whole frames of none, and returns no samples;
    ///   `nextBlock()` refuses it.
    static func samples(of payload: [UInt8], format: FFmpegReport.SampleFormat, channels: Int) throws -> [Int32] {
        let width = format == .s16 ? 2 : 4
        guard channels > 0, payload.count % (width * channels) == 0 else { throw StreamError.damaged }
        let count = payload.count / width
        var samples = [Int32](repeating: 0, count: count)
        samples.withUnsafeMutableBufferPointer { out in
            payload.withUnsafeBytes { raw in
                if width == 2 {
                    for index in 0..<count {
                        out[index] = Int32(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)))
                    }
                } else {
                    for index in 0..<count {
                        out[index] = Int32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: Int32.self))
                    }
                }
            }
        }
        return samples
    }
}
