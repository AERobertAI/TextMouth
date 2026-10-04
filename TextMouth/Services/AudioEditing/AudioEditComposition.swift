import AVFoundation

// MARK: - The Audio the Edits Start From

/// The audio an edit list is applied to (FR04): the original, or, without
/// one, the book's file as last rendered. Read once, off the main thread,
/// with everything a timeline, a preview, and a render need to know of it.
struct AudioEditBase: Sendable {
    /// The file.
    let url: URL
    /// Its sample rate: the rate of every timeline made from it.
    let sampleRate: Double
    /// Its channels.
    let channelCount: Int
    /// How many frames it lasts, at its own rate.
    let frames: Int64
    /// How its samples are stored: the format of its first audio track.
    let format: AudioStreamBasicDescription
    /// Its bit rate in bits a second, as its track estimates it; nil when
    /// the track gives none.
    let bitRate: Double?
    /// Its chapter markers, as AVFoundation reads them: an m4b's chapters,
    /// or the markers an earlier render wrote.
    let chapters: [AudioEditTimeline.Chapter]

    /// The audio unedited, as the start of a timeline.
    var timeline: AudioEditTimeline {
        AudioEditTimeline(sampleRate: sampleRate, baseFrames: frames, chapters: chapters)
    }

    /// Whether its samples are stored as linear PCM.
    var isLinearPCM: Bool {
        format.mFormatID == kAudioFormatLinearPCM
    }

    /// Reads the audio at `url`. Never downloads it: a file only in the
    /// cloud is refused.
    /// - Throws: `AudioEditError.missingAudio` (naming `name`, the file's path
    ///   inside its package), `.audioInCloud`, or `.unreadableAudio`.
    static func load(_ url: URL, name: String) async throws -> AudioEditBase {
        guard FileManager.default.fileExists(atPath: url.path) else { throw AudioEditError.missingAudio(name) }
        guard !DatalessFiles.isDataless(url) else { throw AudioEditError.audioInCloud }
        // Precise timing measures a VBR MP3 by decoding its frames rather than
        // estimating from its first ones, so its length is its real length.
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let loaded = try? await track.load(.timeRange, .formatDescriptions, .estimatedDataRate) else {
            throw AudioEditError.unreadableAudio
        }
        let (timeRange, descriptions, dataRate) = loaded
        guard let format = descriptions.first?.audioStreamBasicDescription,
              format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
            throw AudioEditError.unreadableAudio
        }
        let rate = format.mSampleRate
        // An asset of indefinite length, or one longer than any count of
        // frames, is no audio to edit.
        guard let frames = Int64(exactly: (timeRange.duration.seconds * rate).rounded()), frames > 0 else {
            throw AudioEditError.unreadableAudio
        }
        let chapters = await AudioPlaybackService.extractChapters(from: url).map {
            AudioEditTimeline.Chapter(frame: Int64(($0.startTime * rate).rounded()), title: $0.title)
        }
        return AudioEditBase(
            url: url,
            sampleRate: rate,
            channelCount: Int(format.mChannelsPerFrame),
            frames: frames,
            format: format,
            bitRate: dataRate > 0 ? Double(dataRate) : nil,
            chapters: chapters
        )
    }
}

// MARK: - The Composition

/// A composition of an edit timeline: one audio track that plays every
/// stretch of the timeline from its source, in order, referring to the
/// source files without copying them (FR04). It plays in an `AVPlayer` for
/// a preview, sample-exact, and is what a render reads.
///
/// Silence is inserted as sound, from a silent file in the scratch folder,
/// never as an empty range: a composition with an empty range cannot be
/// exported as it is stored (the research prototype, AVFoundation error
/// -11838). The assets the composition reads from are kept with it, so they
/// live as long as it is used.
struct AudioEditComposition {
    /// The composition.
    let composition: AVMutableComposition
    /// The assets its stretches come from, kept alive with it.
    let sources: [AVURLAsset]
    /// How many frames it lasts, at the timeline's rate.
    let frames: Int64
    /// The timeline's rate.
    let sampleRate: Double

    /// Where a timeline's stretches come from.
    struct Sources: Sendable {
        /// The audio the edits start from.
        let base: AudioEditBase
        /// The book's package, holding the takes of punch-ins.
        let package: URL
        /// This Mac's scratch folder for the edit: the processed stretches,
        /// and the silent file (`AudioEditScratch`).
        let scratch: URL
    }

    /// How long the silent file lasts, in seconds: longer silences repeat
    /// it.
    static let silenceSeconds = 10.0

    /// The composition of `timeline`, whose stretches come from `sources`:
    /// a new one, which the caller owns and may hand to any actor.
    /// - Throws: `AudioEditError.missingAudio`, `.audioInCloud`, or
    ///   `.unreadableAudio` for a source that can't be read;
    ///   `.invalidEdit` for a stretch reaching past the end of its source;
    ///   `.renderFailed` when AVFoundation refuses a stretch.
    static func make(_ timeline: AudioEditTimeline, sources: Sources) async throws -> sending AudioEditComposition {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AudioEditError.renderFailed("the composition took no audio track")
        }
        let scale = CMTimeScale(timeline.sampleRate.rounded())
        func time(_ frames: Int64) -> CMTime { CMTime(value: frames, timescale: scale) }

        var assets: [URL: (asset: AVURLAsset, track: AVAssetTrack, end: CMTime)] = [:]
        /// The first audio track of the file at `url`, read once.
        func sourceTrack(_ url: URL, name: String) async throws -> (track: AVAssetTrack, end: CMTime) {
            if let known = assets[url] { return (known.track, known.end) }
            guard FileManager.default.fileExists(atPath: url.path) else { throw AudioEditError.missingAudio(name) }
            guard !DatalessFiles.isDataless(url) else { throw AudioEditError.audioInCloud }
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                  let range = try? await sourceTrack.load(.timeRange) else {
                throw AudioEditError.unreadableAudio
            }
            assets[url] = (asset, sourceTrack, range.end)
            return (sourceTrack, range.end)
        }

        var position: Int64 = 0
        for segment in timeline.segments {
            switch segment.source {
            case .silence:
                let silence = try AudioEditScratch.silentFile(
                    sampleRate: timeline.sampleRate,
                    channels: sources.base.channelCount,
                    in: sources.scratch
                )
                let source = try await sourceTrack(silence, name: silence.lastPathComponent)
                let piece = Int64(silenceSeconds * timeline.sampleRate)
                var remaining = segment.length
                while remaining > 0 {
                    let length = min(piece, remaining)
                    try insert(CMTimeRange(start: .zero, duration: time(length)), of: source.track, at: time(position), into: track)
                    position += length
                    remaining -= length
                }
            default:
                let (url, name) = try location(of: segment.source, in: sources)
                let source = try await sourceTrack(url, name: name)
                let range = CMTimeRange(start: time(segment.sourceStart), duration: time(segment.length))
                // Rounding to frames can reach half a frame past a source's
                // measured end; anything more names sound that isn't there.
                guard CMTimeCompare(range.end, CMTimeAdd(source.end, time(1))) <= 0 else {
                    throw AudioEditError.invalidEdit("A stretch of the edits runs past the end of “\(name)”.")
                }
                try insert(range, of: source.track, at: time(position), into: track)
                position += segment.length
            }
        }
        return AudioEditComposition(
            composition: composition,
            sources: assets.values.map(\.asset),
            frames: position,
            sampleRate: timeline.sampleRate
        )
    }

    /// Inserts `range` of `source` at `at` in `track`, naming AVFoundation's
    /// refusal by its domain and code.
    private static func insert(_ range: CMTimeRange, of source: AVAssetTrack, at: CMTime, into track: AVMutableCompositionTrack) throws {
        do {
            try track.insertTimeRange(range, of: source, at: at)
        } catch {
            let failure = error as NSError
            throw AudioEditError.renderFailed("\(failure.domain) \(failure.code)")
        }
    }

    /// The file `source` plays from, and its name for an error: the base
    /// audio, a take inside the package, or a processed stretch in the
    /// scratch folder.
    private static func location(of source: AudioEditTimeline.Source, in sources: Sources) throws -> (URL, String) {
        switch source {
        case .base:
            return (sources.base.url, sources.base.url.lastPathComponent)
        case .take(let path):
            guard let url = AudioEditPackage.url(of: path, in: sources.package) else { throw AudioEditError.fileOutsidePackage }
            return (url, path)
        case .processed(let name):
            guard BookOrigin.isPlainFileName(name) else { throw AudioEditError.fileOutsidePackage }
            return (sources.scratch.appendingPathComponent(name), name)
        case .silence:
            // Silence is inserted from the silent file before this is asked.
            throw AudioEditError.renderFailed("silence has no file of its own")
        }
    }
}

/// Makes what renders filters and gain changes for edits whose stretches
/// come from the sources given, or nil, which refuses them: a factory, since
/// rendering a stretch needs those sources, and they are known only once
/// the audio the edits start from has been read.
typealias AudioEditProcessorFactory = @Sendable (AudioEditComposition.Sources) -> (any AudioEditProcessing)?

// MARK: - This Mac's Scratch Folder

/// This Mac's scratch folder for audio edits (FR04): the processed stretches
/// a filter or a gain change renders, and the silent file silence is
/// inserted from, one folder for each book in the Caches folder, which never
/// syncs and which macOS may empty when the disk runs low; everything there
/// can be made again from the book's package. A book's folder is removed
/// once its edits are rendered into its audio, and whenever an edit session
/// closes.
enum AudioEditScratch {
    /// The folder of all books' scratch folders.
    static var root: URL {
        MachineLocalPaths.caches.appendingPathComponent("Audio Edits", isDirectory: true)
    }

    /// The scratch folder of the book `bookID`, made when missing.
    static func folder(for bookID: UUID) throws -> URL {
        let folder = root.appendingPathComponent(bookID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Removes the scratch folder of the book `bookID`, when there is one.
    static func remove(for bookID: UUID) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent(bookID.uuidString, isDirectory: true))
    }

    /// A silent file, `AudioEditComposition.silenceSeconds` long, of 32-bit
    /// float samples at `sampleRate` in `channels` channels, in `folder`:
    /// made the first time it is asked for.
    static func silentFile(sampleRate: Double, channels: Int, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("silence-\(Int(sampleRate.rounded()))-\(channels).caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: false
        ) else { throw AudioEditError.unreadableAudio }
        let frames = AVAudioFrameCount(AudioEditComposition.silenceSeconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let samples = buffer.floatChannelData else { throw AudioEditError.unreadableAudio }
        buffer.frameLength = frames
        for channel in 0..<channels {
            samples[channel].update(repeating: 0, count: Int(frames))
        }
        // Written beside its final name and moved there, so a reader never
        // meets a silent file half written.
        let partial = folder.appendingPathComponent(".\(UUID().uuidString).caf")
        do {
            let file = try AVAudioFile(forWriting: partial, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        do {
            try FileManager.default.moveItem(at: partial, to: url)
        } catch where FileManager.default.fileExists(atPath: url.path) {
            // Another edit made the same file meanwhile.
            try? FileManager.default.removeItem(at: partial)
        }
        return url
    }
}
