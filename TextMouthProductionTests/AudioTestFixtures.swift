import AVFoundation
import XCTest

/// Real audio files, and files that only look like audio, for hosted tests.
/// Every test that needs an audio file writes it here, so each kind of
/// fixture has exactly one writer.
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

    // MARK: Valid Audio

    /// Write `duration` seconds of silence to `url` as 16-bit mono linear
    /// PCM, creating missing folders on the way. The file type follows the
    /// extension (".wav" writes a WAVE file), as `AVAudioFile` infers it.
    static func writeSilence(to url: URL, duration: TimeInterval = 1) throws {
        try writeSilence(to: url, duration: duration, encoding: nil)
    }

    /// Write `duration` seconds of silence to `url` as AAC audio in an
    /// MPEG-4 file (name it ".m4a"), the encoding most audiobooks use,
    /// creating missing folders on the way. `AVAudioFile` writes the file's
    /// index (its "moov" atom) ahead of the audio data (its "mdat" atom).
    static func writeAACSilence(to url: URL, duration: TimeInterval = 1) throws {
        try writeSilence(to: url, duration: duration, encoding: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1
        ])
    }

    /// Write a QuickTime movie holding two tracks of silent 16-bit PCM
    /// audio, the first lasting `first` seconds and the second `second`
    /// seconds, so the file lasts as long as its longer track. An
    /// audiobook whose cover art or chapter titles outlast its audio has
    /// this shape when `first` is the shorter: its first audio track ends
    /// before the file does.
    static func writeTwoAudioTracks(to url: URL, first: TimeInterval, second: TimeInterval) async throws {
        let sources = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: sources) }

        // Each track is copied whole from a WAVE file of its own length.
        // The composition only refers to those files' assets, so they are
        // kept until the export has read them.
        let composition = AVMutableComposition()
        var sourceAssets: [AVURLAsset] = []
        for (number, seconds) in [first, second].enumerated() {
            let source = sources.appendingPathComponent("track \(number).wav")
            try writeSilence(to: source, duration: seconds)
            let sourceAsset = AVURLAsset(url: source)
            sourceAssets.append(sourceAsset)
            let sourceTracks = try await sourceAsset.loadTracks(withMediaType: .audio)
            let sourceTrack = try XCTUnwrap(sourceTracks.first)
            let track = try XCTUnwrap(composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ))
            try track.insertTimeRange(try await sourceTrack.load(.timeRange), of: sourceTrack, at: .zero)
        }

        // Passthrough keeps the samples as they are.
        try createFolder(for: url)
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        if #available(macOS 15, *) {
            try await export.export(to: url, as: .mov)
        } else {
            export.outputURL = url
            export.outputFileType = .mov
            await export.export()
            if let error = export.error {
                throw error
            }
        }
        withExtendedLifetime(sourceAssets) {}
    }

    /// Write `duration` seconds of 16-bit mono silence to `url`, stored as
    /// `encoding` describes (`AVAudioFile` settings), or as the samples are
    /// (linear PCM) when it is nil.
    private static func writeSilence(to url: URL, duration: TimeInterval, encoding: [String: Any]?) throws {
        try createFolder(for: url)
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
            settings: encoding ?? format.settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        try file.write(from: buffer)
        // The file is finished and closed when `file` is released on return.
    }

    // MARK: Damaged Audio

    /// Write `duration` seconds of AAC silence to `url`, then cut the file
    /// off `fraction` of the way through its audio data, as a download or
    /// copy that stopped partway leaves it: 0 keeps none of the audio, 0.5
    /// half of it. The index ahead of the data still lists every sample, so
    /// AVFoundation opens the file with its full duration and calls it
    /// playable; only decoding the missing samples fails.
    static func writeTruncatedAAC(
        to url: URL,
        duration: TimeInterval = 3,
        keepingAudioFraction fraction: Double
    ) throws {
        try writeAACSilence(to: url, duration: duration)
        let file = try Data(contentsOf: url)
        // The audio data atom begins with its size and its type, "mdat";
        // its samples follow the type.
        let audioType = try XCTUnwrap(file.range(of: Data("mdat".utf8)), "The AAC file holds no audio data atom")
        let keptBytes = audioType.upperBound + Int(Double(file.count - audioType.upperBound) * fraction)
        try file.prefix(keptBytes).write(to: url)
    }

    /// Write a WAVE file whose header promises one second of 16-bit samples
    /// and which ends right after that header, as a copy cut off before its
    /// samples leaves it. AVFoundation opens it and calls it playable, but
    /// finds nothing to play.
    static func writeWAVHeaderWithoutSamples(to url: URL) throws {
        try createFolder(for: url)
        let oneSecondOfSamples = Int(sampleRate) * 2
        try waveFile(format: pcmFormatChunk, declaredSampleBytes: oneSecondOfSamples, samples: Data())
            .write(to: url)
    }

    /// Write a WAVE file with a valid RIFF header whose format chunk
    /// declares Microsoft ADPCM audio but leaves out the coefficient table
    /// that format requires, followed by scrambled bytes where the
    /// compressed samples belong. AVFoundation cannot decode it, so it
    /// cannot open it. (Scrambled bytes under a complete PCM or ADPCM
    /// header would decode as noise, which no check can tell from sound.)
    static func writeWAVWithUndecodableSamples(to url: URL) throws {
        try createFolder(for: url)
        let samples = scrambledBytes(count: 4_096)
        try waveFile(format: adpcmFormatChunkWithoutCoefficients, declaredSampleBytes: samples.count, samples: samples)
            .write(to: url)
    }

    /// Write a short plain-text note to `url`: a file named like audio,
    /// such as "02.mp3", that is plainly text, as a mislabeled download is.
    /// Text never holds the 0xFF byte that starts an MPEG audio frame.
    static func writePlainText(to url: URL) throws {
        try createFolder(for: url)
        try Data("This note was saved under the name of a recording; it holds no sound.\n".utf8).write(to: url)
    }

    /// Write `byteCount` scrambled bytes to `url`: a file with an audio name,
    /// such as "05.mp3", whose contents are not audio at all.
    static func writeNonAudioBytes(to url: URL, byteCount: Int = 4_096) throws {
        try scrambledBytes(count: byteCount).write(to: url)
    }

    // MARK: Building Files

    /// `count` scrambled bytes. They come from a fixed-seed generator, so
    /// every run writes the same file, and each byte is below 0x80. Truly
    /// random bytes would now and then contain 0xFF, the first byte of
    /// every MPEG audio frame, and a lenient decoder could find "frames" in
    /// them and play noise instead of failing.
    private static func scrambledBytes(count: Int) -> Data {
        // A 32-bit linear congruential generator (Numerical Recipes
        // constants); its high bits are well mixed, and seven of them make
        // each byte.
        var state: UInt32 = 0x5EED_1234
        return Data((0..<count).map { _ -> UInt8 in
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(state >> 25)
        })
    }

    /// The bytes of a WAVE file: a RIFF header, a "fmt " chunk holding
    /// `format`, and a "data" chunk whose header declares
    /// `declaredSampleBytes` bytes of samples and which holds `samples`
    /// (fewer than declared, for a file that was cut off).
    private static func waveFile(format: Data, declaredSampleBytes: Int, samples: Data) -> Data {
        var file = Data("RIFF".utf8)
        // The RIFF size counts every byte after it that the header declares:
        // "WAVE", both chunk headers, and both chunks' declared contents.
        appendLittleEndian(UInt32(4 + 8 + format.count + 8 + declaredSampleBytes), to: &file)
        file.append(Data("WAVE".utf8))
        file.append(Data("fmt ".utf8))
        appendLittleEndian(UInt32(format.count), to: &file)
        file.append(format)
        file.append(Data("data".utf8))
        appendLittleEndian(UInt32(declaredSampleBytes), to: &file)
        file.append(samples)
        return file
    }

    /// A "fmt " chunk describing 16-bit mono linear PCM at `sampleRate`.
    private static var pcmFormatChunk: Data {
        var chunk = Data()
        appendLittleEndian(UInt16(1), to: &chunk)                  // format: linear PCM
        appendLittleEndian(UInt16(1), to: &chunk)                  // one channel
        appendLittleEndian(UInt32(sampleRate), to: &chunk)         // samples per second
        appendLittleEndian(UInt32(sampleRate) * 2, to: &chunk)     // bytes per second
        appendLittleEndian(UInt16(2), to: &chunk)                  // bytes per sample
        appendLittleEndian(UInt16(16), to: &chunk)                 // bits per sample
        return chunk
    }

    /// A "fmt " chunk declaring mono Microsoft ADPCM in 256-byte blocks
    /// that ends where the format's samples-per-block count and coefficient
    /// table belong: it declares no extra bytes at all.
    private static var adpcmFormatChunkWithoutCoefficients: Data {
        var chunk = Data()
        appendLittleEndian(UInt16(2), to: &chunk)                  // format: Microsoft ADPCM
        appendLittleEndian(UInt16(1), to: &chunk)                  // one channel
        appendLittleEndian(UInt32(sampleRate), to: &chunk)         // samples per second
        appendLittleEndian(UInt32(4_096), to: &chunk)              // bytes per second
        appendLittleEndian(UInt16(256), to: &chunk)                // bytes per block
        appendLittleEndian(UInt16(4), to: &chunk)                  // bits per sample
        appendLittleEndian(UInt16(0), to: &chunk)                  // extra bytes: none
        return chunk
    }

    /// Append `value` to `data` in little-endian byte order, as WAVE headers
    /// store integers on every host.
    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// Create the folder `url` goes in, and any missing folders above it.
    private static func createFolder(for url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }
}

// MARK: - Waiting for Playback

/// Waiting on the main run loop, where AVFoundation's observations and the
/// audio service's callbacks arrive.
extension XCTestCase {
    /// Let queued main-queue work, such as AVFoundation observations, run
    /// for `interval` seconds.
    @MainActor
    func spinMainRunLoop(for interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    /// Run the main run loop until `condition` holds or `timeout` passes.
    ///
    /// - Returns: Whether `condition` came to hold.
    @MainActor
    func eventually(within timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            spinMainRunLoop(for: 0.01)
        }
        return condition()
    }

    /// Wait until `item` is ready to play, and a little longer, so that the
    /// audio service has handled the status change: its observation reaches
    /// the main queue just after the status itself changes.
    @MainActor
    func waitUntilReady(_ item: AVPlayerItem, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            eventually { item.status == .readyToPlay },
            "Item never became ready",
            file: file,
            line: line
        )
        spinMainRunLoop(for: 0.1)
    }
}
