import XCTest
@testable import TextMouth

// MARK: - Streams Written by Hand

/// Streams of TextMouth's FFmpeg session (FMT50) written by hand, for tests
/// of what reads them. The records' letters and the protocol's numbers are
/// spelled out here, from TextMouthFFmpegProtocol.h's comment, rather than
/// taken from the header, so a change to the header that the comment does not
/// follow fails these tests.
enum FFmpegTestStream {
    /// A record of `kind` (four ASCII letters) with `payload`.
    static func record(_ kind: String, _ payload: [UInt8]) -> [UInt8] {
        Array(kind.utf8) + littleEndian(UInt32(payload.count)) + payload
    }

    /// `value` as four little-endian bytes.
    static func littleEndian(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    /// `value` as eight little-endian bytes.
    static func littleEndian(_ value: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) }
    }

    /// HEAD of protocol `version` (1, the one the app reads).
    static func head(version: UInt32 = 1) -> [UInt8] {
        record("HEAD", littleEndian(version) + Array("9.0.2".utf8))
    }

    /// INFO of `pairs`, one "key=value" line each.
    static func info(_ pairs: [(String, String)]) -> [UInt8] {
        record("INFO", Array(pairs.map { "\($0.0)=\($0.1)\n" }.joined().utf8))
    }

    /// A tag of the file (TAG) or, with `stream`, of the chosen stream (STAG).
    static func tag(_ key: String, _ value: String, stream: Bool = false) -> [UInt8] {
        record(stream ? "STAG" : "TAG ", Array(key.utf8) + [0] + Array(value.utf8))
    }

    /// A chapter from `start` to `end` seconds (no end: not a number) titled `title`.
    static func chapter(start: Double, end: Double = .nan, title: String) -> [UInt8] {
        record("CHAP", littleEndian(start.bitPattern) + littleEndian(end.bitPattern) + Array(title.utf8))
    }

    /// A PCM record of 16-bit samples.
    static func pcm16(_ samples: [Int16]) -> [UInt8] {
        record("PCM ", samples.flatMap { sample in
            [UInt8(truncatingIfNeeded: UInt16(bitPattern: sample)), UInt8(truncatingIfNeeded: UInt16(bitPattern: sample) >> 8)]
        })
    }

    /// A PCM record of 32-bit samples (whole numbers, or floats' patterns).
    static func pcm32(_ samples: [UInt32]) -> [UInt8] {
        record("PCM ", samples.flatMap(littleEndian))
    }

    /// END, counting `frames`, and the packets and frames the decoder refused.
    static func end(frames: UInt64, refusedPackets: UInt32 = 0, refusedFrames: UInt32 = 0) -> [UInt8] {
        record("END ", littleEndian(frames) + littleEndian(refusedPackets) + littleEndian(refusedFrames))
    }

    /// The INFO of wma/tones-wma1.wma as the helper writes it in a probe:
    /// one WMA 1 stream of four seconds, mono at 22,050 Hz, 32 kbit/s.
    static let wmaInfo: [(String, String)] = [
        ("format", "asf"), ("codec", "wmav1"), ("stream", "0"), ("streams", "1"), ("audio_streams", "1"),
        ("more_than_sound", "0"), ("default", "0"), ("sample_rate", "22050"), ("channels", "1"), ("channel_mask", "4"),
        ("sample_format", "f32"), ("bits", "32"), ("duration", "3.999000"), ("format_duration", "3.999000"),
        ("bit_rate", "32000"), ("format_bit_rate", "40258"),
    ]

    /// `pairs` with the value of `key` replaced, or, for a nil value, left out.
    static func replacing(_ key: String, with value: String?, in pairs: [(String, String)]) -> [(String, String)] {
        pairs.compactMap { pair in
            guard pair.0 == key else { return pair }
            return value.map { (key, $0) }
        }
    }

    /// A whole probe of a file: HEAD, INFO of `info`, the file's tags, the
    /// stream's tags, the chapters, and END of no frames.
    static func probe(
        info: [(String, String)] = wmaInfo,
        tags: [(String, String)] = [("TITLE", "Three Tones"), ("artist", "TextMouth Test"), ("album", "Harbour Recordings")],
        streamTags: [(String, String)] = [],
        chapters: [(Double, String)] = []
    ) -> [UInt8] {
        var bytes: [UInt8] = head()
        bytes += self.info(info)
        for (key, value) in tags {
            bytes += tag(key, value)
        }
        for (key, value) in streamTags {
            bytes += tag(key, value, stream: true)
        }
        for (start, title) in chapters {
            bytes += chapter(start: start, title: title)
        }
        bytes += end(frames: 0)
        return bytes
    }
}
