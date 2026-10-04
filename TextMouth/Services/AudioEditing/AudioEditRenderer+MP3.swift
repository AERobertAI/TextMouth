import AVFoundation

// MARK: - Which Encoder Writes MP3

/// Which encoder writes an MP3 (FR04): the LAME built into TextMouth
/// (`MP3Encoder`), or, should it somehow be unavailable, the LAME of an
/// installed ffmpeg TextMouth may use (`FFmpeg.encodeMP3`). The user's answer
/// of October 4: MP3 is wanted, whatever the encoder adds to the app.
enum MP3Route: Equatable, Sendable {
    /// TextMouth's own LAME.
    case builtIn
    /// An installed ffmpeg's LAME.
    case ffmpeg(FFmpeg)

    /// The encoder an MP3 is written with: TextMouth's own while
    /// `builtInIsAvailable`, otherwise `ffmpeg` when there is one; nil, when
    /// there is neither, as MP3 can't be written.
    static func preferred(ffmpeg: FFmpeg?, builtInIsAvailable: Bool = MP3Encoder.isAvailable) -> MP3Route? {
        if builtInIsAvailable {
            return .builtIn
        }
        return ffmpeg.map { .ffmpeg($0) }
    }
}

// MARK: - Rendering MP3

extension AudioEditRenderer {
    /// Renders `timeline`, whose stretches come from `sources`, as MP3 at
    /// `destination` along `route`, tagged with `metadata` and the timeline's
    /// chapter markers, telling `progress` how far it is.
    /// - Throws: `AudioEditError.mp3NeedsFFmpeg` when `route` is nil, there
    ///   being no encoder; the render's errors; or `CancellationError`.
    ///   Nothing is left at `destination` after a failure.
    static func renderMP3(
        _ timeline: AudioEditTimeline,
        sources: AudioEditComposition.Sources,
        to destination: URL,
        metadata: AudioRenderMetadata,
        route: MP3Route?,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Outcome {
        switch route {
        case .builtIn:
            return try await encodeMP3(timeline, sources: sources, to: destination, metadata: metadata, progress: progress)
        case .ffmpeg(let ffmpeg):
            return try await renderMP3ThroughFFmpeg(
                timeline,
                sources: sources,
                to: destination,
                metadata: metadata,
                ffmpeg: ffmpeg,
                progress: progress
            )
        case nil:
            throw AudioEditError.mp3NeedsFFmpeg
        }
    }

    /// The settings LAME encodes `base`'s edits with: the rate, channels, and
    /// bit rate the renderer chooses for MP3 (`AudioRenderSettings.make`):
    /// an MP3's own bit rate, or 64 kbit/s a channel for speech.
    static func mp3EncoderSettings(for base: AudioEditBase) -> MP3EncoderSettings {
        let settings = AudioRenderSettings.make(.mp3, for: base)
        let bitRate = settings.bitRate ?? AudioRenderSettings.bitRatePerChannel * settings.channels
        return MP3EncoderSettings(
            sampleRate: Int(settings.sampleRate.rounded()),
            channels: settings.channels,
            kilobitsPerSecond: Int((Double(bitRate) / 1_000).rounded())
        )
    }

    /// Encodes `timeline` as MP3 at `destination` with TextMouth's own LAME:
    /// the composition is decoded to 32-bit floats at the MP3's rate and
    /// channels, cut at the end of the edits as every render is, and handed
    /// to the encoder buffer by buffer, so nothing is written but the MP3
    /// itself, however long it is. The file is tagged with `metadata`'s title
    /// and author, the chapter markers as ID3 chapter frames, and the gapless
    /// numbers (`MP3Tag`).
    private static func encodeMP3(
        _ timeline: AudioEditTimeline,
        sources: AudioEditComposition.Sources,
        to destination: URL,
        metadata: AudioRenderMetadata,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Outcome {
        let made = try await AudioEditComposition.make(timeline, sources: sources)
        let settings = AudioRenderSettings.make(.mp3, for: sources.base)
        let (reader, output, _) = try await makeReader(of: made, settings: settings, copyingSamples: false)
        let tag = MP3Tag(
            title: metadata.title,
            artist: metadata.author,
            chapters: chapterList(of: timeline, leadingTitle: metadata.title)
        )
        try? FileManager.default.removeItem(at: destination)
        let encoder: MP3Encoder
        do {
            encoder = try MP3Encoder(writingTo: destination, settings: mp3EncoderSettings(for: sources.base), tag: tag)
        } catch {
            throw renderFailure(error)
        }
        guard reader.startReading() else { throw failure(reader.error) }
        // The floats of one buffer, reused for the next.
        var samples: [Float] = []
        do {
            try await drain(output, of: reader, made: made, settings: settings, cuttingAtTheEnd: true, progress: progress) {
                try encode($0, channels: settings.channels, with: encoder, through: &samples)
            }
            try encoder.finish()
        } catch {
            reader.cancelReading()
            // The encoder removes the file it could not finish as it goes.
            throw renderFailure(error)
        }
        return Outcome(frames: made.frames, copiedSamples: false)
    }

    /// Copies the decoded, interleaved floats of `sample`, of `channels`
    /// channels, into `samples`, grown as needed, and hands them to
    /// `encoder`.
    /// - Throws: `AudioEditError.renderFailed` when the floats can't be
    ///   copied, or the encoder's errors.
    private static func encode(
        _ sample: CMSampleBuffer,
        channels: Int,
        with encoder: MP3Encoder,
        through samples: inout [Float]
    ) throws {
        let frames = CMSampleBufferGetNumSamples(sample)
        let count = frames * channels
        guard count > 0 else { return }
        if samples.count < count {
            samples = [Float](repeating: 0, count: count)
        }
        let status = samples.withUnsafeMutableBufferPointer { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kCMSampleBufferError_RequiredParameterMissing }
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(channels),
                    mDataByteSize: UInt32(count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(base)
                )
            )
            return CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: &list)
        }
        guard status == noErr else { throw AudioEditError.renderFailed("\(NSOSStatusErrorDomain) \(status)") }
        try samples.withUnsafeBufferPointer {
            try encoder.encode(interleaved: UnsafeBufferPointer(rebasing: $0[0..<count]))
        }
    }

    /// `error` as a render's error: LAME's, as a render failure naming what
    /// LAME said, for the debug log; any other as it is.
    private static func renderFailure(_ error: Error) -> Error {
        guard let lame = error as? MP3EncoderError else { return error }
        return AudioEditError.renderFailed(lame.description)
    }
}
