import Foundation
private import LAME

// MARK: - Errors

/// Why LAME could not write an MP3. The words are for the debug log and the
/// renderer's failure (`AudioEditError.renderFailed`), which says the rest.
enum MP3EncoderError: Error, Equatable, Sendable, CustomStringConvertible {
    /// LAME could not start: it found no memory for an encoder.
    case unavailable
    /// The settings are none an MP3 can have, or LAME refused them: why.
    case unsupportedSettings(String)
    /// LAME failed while encoding, with the code it returned.
    case encodingFailed(Int32)
    /// The file could not be written: the error's domain and code.
    case writeFailed(String)

    var description: String {
        switch self {
        case .unavailable:
            return "LAME could not start"
        case .unsupportedSettings(let reason):
            return "LAME refused the settings: \(reason)"
        case .encodingFailed(let code):
            return "LAME failed with code \(code)"
        case .writeFailed(let reason):
            return "the MP3 could not be written: \(reason)"
        }
    }

    /// The write failure `error`, by its domain and code only: its
    /// description can name the file by its full path.
    static func writing(_ error: Error) -> MP3EncoderError {
        let failure = error as NSError
        return .writeFailed("\(failure.domain) \(failure.code)")
    }
}

// MARK: - Settings

/// What an MP3 is encoded as (FR04): its sample rate, its channels, and its
/// constant bit rate. A constant rate keeps every seek in a long audiobook
/// exact, where a variable one makes players estimate.
struct MP3EncoderSettings: Equatable, Sendable {
    /// The sample rates an MP3 can have: MPEG-2.5's, MPEG-2's, and MPEG-1's.
    /// The renderer's rates (`RecordingEncoder.outputSampleRate`) are all
    /// among them.
    static let sampleRates = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]

    /// Samples a second, a channel.
    let sampleRate: Int
    /// One channel, or two.
    let channels: Int
    /// The bit rate, in kilobits a second. LAME takes the nearest one an MP3
    /// at `sampleRate` can have (at 8 kHz, at most 64), and the encoder's
    /// own `settings` say which it took.
    let kilobitsPerSecond: Int

    /// The settings for speech at `sampleRate` in `channels` channels: the
    /// rate spoken-word audiobooks use for clear speech, 64 kbit/s a channel
    /// (`RecordingEncoder.speechBitRate`).
    static func speech(sampleRate: Int, channels: Int) -> MP3EncoderSettings {
        MP3EncoderSettings(
            sampleRate: sampleRate,
            channels: channels,
            kilobitsPerSecond: RecordingEncoder.speechBitRate / 1_000 * channels
        )
    }

    /// Why an MP3 can't have these settings, or nil when it can.
    var problem: String? {
        if !Self.sampleRates.contains(sampleRate) { return "an MP3 can't have a sample rate of \(sampleRate) Hz" }
        if !(1...2).contains(channels) { return "an MP3 has one channel or two, not \(channels)" }
        if kilobitsPerSecond <= 0 { return "the bit rate must be above zero" }
        return nil
    }
}

// MARK: - The Encoder

/// Writes one MP3 file with LAME 3.100, which TextMouth builds in
/// (Vendor/lame, the LAME target): linear PCM in, as 32-bit floats from
/// −1 to 1, interleaved when there are two channels, a constant-bit-rate
/// MP3 out (FR04).
///
/// The file starts with TextMouth's ID3 tag (`MP3Tag`): the title, author,
/// and chapters given, and the gapless numbers, which only the end of the
/// encoding knows. The tag is written first with those numbers unknown and
/// written again, the same size, by `finish()`, which also puts LAME's own
/// tag (its Xing "Info" frame, holding the delay and padding too) in the
/// empty frame LAME leaves at the start of the audio for it. LAME leaves
/// none, and writes no tag, when the frame at the bit rate chosen is too
/// small to hold one; the iTunes numbers serve AVFoundation either way.
///
/// One encoder writes one file, from one task at a time. A file it does not
/// finish, as when encoding fails or is cancelled, is removed when the
/// encoder goes, so nothing is left at its URL.
final class MP3Encoder {
    /// LAME's quality setting: 2, "near-best quality, not too slow", what
    /// its documentation recommends; speech encodes about 100 times faster
    /// than real time with it (measured on an Apple silicon Mac).
    static let quality: Int32 = 2

    /// The most frames handed to LAME at once, which sizes its output
    /// buffer: larger buffers are handed over in parts.
    static let framesPerCall = 8_192

    /// The largest MP3 frame there is, in bytes, which LAME's own tag takes
    /// at most.
    private static let maximumFrameSize = 2_880

    /// Whether LAME can encode here. It is linked into the app, so this is
    /// false only when it cannot even start; the renderer then turns to an
    /// installed ffmpeg (`MP3Route`).
    static let isAvailable: Bool = {
        guard let flags = lame_init() else { return false }
        lame_close(flags)
        return true
    }()

    /// LAME's version, as it names itself: "3.100".
    static var version: String {
        String(cString: get_lame_version())
    }

    /// The settings the file is written with: those asked for, with the bit
    /// rate LAME took.
    let settings: MP3EncoderSettings

    /// LAME's encoder.
    private let flags: OpaquePointer
    /// The file being written.
    private let file: FileHandle
    /// Where the file is, to remove it when it is not finished.
    private let url: URL
    /// The ID3 tag, as written first.
    private let tag: MP3Tag
    /// The tag's size in bytes: where the audio starts.
    private let tagSize: Int
    /// Whether the tag carries the gapless numbers.
    private let writesGaplessInfo: Bool
    /// LAME's output, reused for every call.
    private var output: [UInt8]
    /// Frames of sound handed to LAME so far.
    private(set) var framesEncoded: Int64 = 0
    /// Whether `finish()` completed: the file is whole and LAME is closed.
    private var isFinished = false

    /// An encoder writing a new MP3 file at `url`, replacing any there, with
    /// `settings`, and `tag`'s title, author, and chapters; with the iTunes
    /// gapless numbers unless `writesGaplessInfo` is false, as only a test
    /// asks, to show what they do.
    /// - Throws: `MP3EncoderError.unsupportedSettings` for settings no MP3
    ///   can have, `.unavailable`, or `.writeFailed`; nothing is left at
    ///   `url` then.
    init(writingTo url: URL, settings requested: MP3EncoderSettings, tag: MP3Tag, writesGaplessInfo: Bool = true) throws {
        if let problem = requested.problem {
            throw MP3EncoderError.unsupportedSettings(problem)
        }
        guard let flags = lame_init() else { throw MP3EncoderError.unavailable }
        // LAME is closed unless the encoder comes to own it.
        var owned = false
        defer {
            if !owned { lame_close(flags) }
        }
        lame_set_in_samplerate(flags, Int32(requested.sampleRate))
        lame_set_out_samplerate(flags, Int32(requested.sampleRate))
        lame_set_num_channels(flags, Int32(requested.channels))
        lame_set_mode(flags, requested.channels == 1 ? MONO : JOINT_STEREO)
        lame_set_VBR(flags, vbr_off)
        lame_set_brate(flags, Int32(requested.kilobitsPerSecond))
        lame_set_quality(flags, Self.quality)
        // LAME's own tag goes in the frame it leaves empty; TextMouth writes
        // the ID3 tag itself.
        lame_set_bWriteVbrTag(flags, 1)
        lame_set_write_id3tag_automatic(flags, 0)
        let status = lame_init_params(flags)
        guard status >= 0 else {
            throw MP3EncoderError.unsupportedSettings("lame_init_params returned \(status)")
        }

        var firstTag = tag
        firstTag.gapless = writesGaplessInfo ? .unknown : nil
        let tagBytes = firstTag.encoded()
        guard FileManager.default.createFile(atPath: url.path, contents: tagBytes) else {
            throw MP3EncoderError.writeFailed("the file could not be created")
        }
        let file: FileHandle
        do {
            file = try FileHandle(forWritingTo: url)
            _ = try file.seekToEnd()
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw MP3EncoderError.writing(error)
        }

        owned = true
        self.flags = flags
        self.file = file
        self.url = url
        self.tag = firstTag
        self.tagSize = tagBytes.count
        self.writesGaplessInfo = writesGaplessInfo
        self.output = [UInt8](repeating: 0, count: Self.framesPerCall * 5 / 4 + 7_200)
        self.settings = MP3EncoderSettings(
            sampleRate: Int(lame_get_out_samplerate(flags)),
            channels: requested.channels,
            kilobitsPerSecond: Int(lame_get_brate(flags))
        )
    }

    deinit {
        // An encoder that did not finish leaves nothing behind.
        guard !isFinished else { return }
        try? file.close()
        lame_close(flags)
        try? FileManager.default.removeItem(at: url)
    }

    /// Encodes `samples`: a channel's frames, or two channels' interleaved,
    /// left first, each from −1 to 1. Writes what LAME has ready.
    /// - Throws: `MP3EncoderError.unsupportedSettings` for samples that are
    ///   not a whole number of frames, or after `finish()`; `.encodingFailed`
    ///   or `.writeFailed`.
    func encode(interleaved samples: UnsafeBufferPointer<Float>) throws {
        guard !isFinished else { throw MP3EncoderError.unsupportedSettings("the MP3 is already finished") }
        let channels = settings.channels
        guard samples.count % channels == 0 else {
            throw MP3EncoderError.unsupportedSettings("\(samples.count) samples are not a whole number of frames")
        }
        guard let base = samples.baseAddress else { return }
        let frames = samples.count / channels
        var done = 0
        while done < frames {
            let count = min(Self.framesPerCall, frames - done)
            let start = base + done * channels
            let written = output.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let bytes = buffer.baseAddress else { return -1 }
                let capacity = Int32(buffer.count)
                // LAME reads one channel from the first pointer, or, given
                // interleaved floats, both from one.
                return channels == 1
                    ? lame_encode_buffer_ieee_float(flags, start, start, Int32(count), bytes, capacity)
                    : lame_encode_buffer_interleaved_ieee_float(flags, start, Int32(count), bytes, capacity)
            }
            guard written >= 0 else { throw MP3EncoderError.encodingFailed(written) }
            try write(Int(written))
            done += count
            framesEncoded += Int64(count)
        }
    }

    /// Encodes what LAME still holds, puts LAME's own tag in its place, and
    /// writes the ID3 tag again with the gapless numbers, then closes the
    /// file, which is complete. Returns the numbers.
    /// - Throws: `MP3EncoderError.encodingFailed` or `.writeFailed`; the
    ///   file is removed when the encoder goes.
    @discardableResult
    func finish() throws -> MP3GaplessInfo {
        guard !isFinished else { throw MP3EncoderError.unsupportedSettings("the MP3 is already finished") }
        let flushed = output.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let bytes = buffer.baseAddress else { return -1 }
            return lame_encode_flush(flags, bytes, Int32(buffer.count))
        }
        guard flushed >= 0 else { throw MP3EncoderError.encodingFailed(flushed) }
        try write(Int(flushed))

        let gapless = MP3GaplessInfo(
            priming: Int(lame_get_encoder_delay(flags)),
            padding: Int(lame_get_encoder_padding(flags)),
            sampleCount: framesEncoded
        )
        var lameTag = [UInt8](repeating: 0, count: Self.maximumFrameSize)
        let lameTagSize = lameTag.withUnsafeMutableBufferPointer { buffer -> Int in
            guard let bytes = buffer.baseAddress else { return 0 }
            return lame_get_lametag_frame(flags, bytes, buffer.count)
        }
        var finalTag = tag
        finalTag.gapless = writesGaplessInfo ? gapless : nil
        let tagBytes = finalTag.encoded()
        // The numbers are written in fixed widths, so the tag keeps its size
        // and the audio after it stays where it is.
        guard tagBytes.count == tagSize else {
            throw MP3EncoderError.writeFailed("the ID3 tag changed size")
        }
        do {
            if lameTagSize > 0 && lameTagSize <= lameTag.count {
                try file.seek(toOffset: UInt64(tagSize))
                try file.write(contentsOf: lameTag[0..<lameTagSize])
            }
            try file.seek(toOffset: 0)
            try file.write(contentsOf: tagBytes)
            try file.close()
        } catch {
            throw MP3EncoderError.writing(error)
        }
        lame_close(flags)
        isFinished = true
        return gapless
    }

    /// Writes the first `count` bytes of LAME's output to the file.
    private func write(_ count: Int) throws {
        guard count > 0 else { return }
        do {
            try file.write(contentsOf: output[0..<count])
        } catch {
            throw MP3EncoderError.writing(error)
        }
    }
}
