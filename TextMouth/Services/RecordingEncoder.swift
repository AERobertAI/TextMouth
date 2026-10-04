import AVFoundation

/// Why a take could not be encoded as a book's audio.
enum RecordingEncodingError: LocalizedError, Equatable, Sendable {
    /// The take holds no audio track that can be read.
    case unreadableTake
    /// The encoder refused the settings or the audio; the words are
    /// AVFoundation's error domain and code, for the debug log.
    case encodingFailed(String)

    /// What the Record window says when saving fails here.
    var errorDescription: String? {
        switch self {
        case .unreadableTake:
            return "The recording's audio couldn't be read."
        case .encodingFailed:
            return "The recording couldn't be converted to an audiobook file."
        }
    }
}

/// Encodes a take as a book's audio: AAC in an MPEG-4 audio file (.m4a),
/// one channel, at a bit rate suited to speech, tagged with the book's
/// title, so the library lists it by name and any player shows it.
///
/// The take is read with AVAssetReader and written with AVAssetWriter in one
/// pass, sample buffer by sample buffer, so memory stays small whatever the
/// take's length. All of it runs off the main thread: the caller awaits it.
enum RecordingEncoder {
    /// The bit rate of a book's audio: 64 kbit/s, the rate spoken-word
    /// audiobooks use for clear speech in about 28 MB an hour.
    static let speechBitRate = 64_000

    /// The sample rates the AAC encoder takes, lowest first.
    static let aacSampleRates: [Double] = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000, 44_100, 48_000]

    /// The sample rate a take recorded at `rate` is encoded at: its own when
    /// the AAC encoder takes it, otherwise the highest it takes below it,
    /// and 48 kHz for anything above.
    static func outputSampleRate(for rate: Double) -> Double {
        aacSampleRates.last { $0 <= rate } ?? aacSampleRates[0]
    }

    /// The bit rate for mono AAC at `sampleRate`: the highest the encoder
    /// accepts at that rate up to `speechBitRate`, asked of the encoder
    /// itself, since the rates it accepts depend on the sample rate (at
    /// 8 kHz it refuses 48 kbit/s). Nil when it names none, so the encoder
    /// picks its own.
    static func bitRate(forSampleRate sampleRate: Double) -> Int? {
        let accepted = AudioRenderSettings.acceptedAACBitRates(sampleRate: sampleRate, channels: 1)
        guard !accepted.isEmpty else { return nil }
        return accepted.filter { $0 <= speechBitRate }.max() ?? accepted.min()
    }

    /// Encodes the take at `take` into a new M4A file at `destination`,
    /// tagged with `title`. A file already at `destination` is replaced.
    /// Should the encoder still refuse the bit rate chosen, the take is
    /// encoded once more at the encoder's own.
    /// - Throws: `RecordingEncodingError`; nothing is left at `destination`
    ///   after a failure.
    static func encode(take: URL, to destination: URL, title: String) async throws {
        try? FileManager.default.removeItem(at: destination)
        do {
            do {
                try await write(take: take, to: destination, title: title, choosingBitRate: true)
            } catch RecordingEncodingError.encodingFailed {
                try? FileManager.default.removeItem(at: destination)
                try await write(take: take, to: destination, title: title, choosingBitRate: false)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// The pass itself: reads the take's audio as linear PCM and appends it
    /// to an AAC writer, waiting whenever the writer has enough. With
    /// `choosingBitRate`, at the bit rate `bitRate(forSampleRate:)` chooses;
    /// without, at the encoder's own.
    private static func write(take: URL, to destination: URL, title: String, choosingBitRate: Bool) async throws {
        let asset = AVURLAsset(url: take)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let format = try? await track.load(.formatDescriptions).first,
              let source = format.audioStreamBasicDescription, source.mSampleRate > 0 else {
            throw RecordingEncodingError.unreadableTake
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw RecordingEncodingError.unreadableTake
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        reader.add(output)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        } catch {
            throw RecordingEncodingError.encodingFailed(describe(error))
        }
        let sampleRate = outputSampleRate(for: source.mSampleRate)
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
        ]
        if choosingBitRate, let bitRate = bitRate(forSampleRate: sampleRate) {
            settings[AVEncoderBitRateKey] = bitRate
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else {
            throw RecordingEncodingError.encodingFailed("the writer refused the audio input")
        }
        writer.add(input)
        writer.metadata = [titleItem(title)]

        guard reader.startReading() else {
            throw RecordingEncodingError.unreadableTake
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw RecordingEncodingError.encodingFailed(writer.error.map(describe) ?? "the writer did not start")
        }
        writer.startSession(atSourceTime: .zero)
        while let buffer = output.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }
            guard input.append(buffer) else {
                reader.cancelReading()
                writer.cancelWriting()
                throw RecordingEncodingError.encodingFailed(writer.error.map(describe) ?? "a sample was refused")
            }
        }
        guard reader.status == .completed else {
            writer.cancelWriting()
            throw RecordingEncodingError.unreadableTake
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RecordingEncodingError.encodingFailed(writer.error.map(describe) ?? "the file was not finished")
        }
    }

    /// The metadata item naming the book: the common title, which the
    /// MPEG-4 writer stores as the song name iTunes and Apple Books show.
    private static func titleItem(_ title: String) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = .commonIdentifierTitle
        item.value = title as NSString
        item.extendedLanguageTag = "und"
        return item
    }

    /// An error as the debug log names it: domain and code only.
    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }
}
