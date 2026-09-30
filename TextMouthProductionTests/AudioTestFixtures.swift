import AVFoundation
import XCTest

/// Real audio files, and files that only look like audio, for hosted tests.
///
/// Each test writes its files into its own folder under the temporary
/// directory and removes the folder when it ends, so no fixture is shared
/// between tests and none touches the user's library.
enum AudioTestFixtures {
    /// Samples per second of every file written here. Low, since the audio
    /// is silence and only needs to be valid.
    private static let sampleRate = 8_000.0

    /// Create a new, empty folder for one test's files.
    static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioFixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Write `duration` seconds of silence to `url` as 16-bit mono linear
    /// PCM, creating missing folders on the way. The file type follows the
    /// extension (".wav" writes a WAVE file), as `AVAudioFile` infers it.
    static func writeSilence(to url: URL, duration: TimeInterval = 1) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ))
        let frameCount = AVAudioFrameCount(duration * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        buffer.frameLength = frameCount
        // Silence is all-zero samples; zero them explicitly rather than rely
        // on how the buffer's memory was allocated.
        let samples = try XCTUnwrap(buffer.int16ChannelData)
        samples[0].update(repeating: 0, count: Int(frameCount))

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        try file.write(from: buffer)
        // The file is finished and closed when `file` is released on return.
    }

    /// Write `byteCount` scrambled bytes to `url`: a file with an audio name,
    /// such as "05.mp3", whose contents are not audio at all.
    ///
    /// The bytes come from a fixed-seed generator, so every run writes the
    /// same file, and each byte is below 0x80. Truly random bytes would now
    /// and then contain 0xFF, the first byte of every MPEG audio frame, and
    /// a lenient decoder could find "frames" in them and play noise instead
    /// of failing.
    static func writeNonAudioBytes(to url: URL, byteCount: Int = 4_096) throws {
        // A 32-bit linear congruential generator (Numerical Recipes
        // constants); its high bits are well mixed, and seven of them make
        // each byte.
        var state: UInt32 = 0x5EED_1234
        let bytes = (0..<byteCount).map { _ -> UInt8 in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(state >> 25)
        }
        try Data(bytes).write(to: url)
    }
}
