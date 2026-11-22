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
        // Never decode a format the import converts (B09, FMT09): Apple's
        // Vorbis decoder once spun forever. Such audio is converted in a
        // child process first.
        guard !ImportAudioConverter.isNeverDecodedInApp(url) else { throw AudioEditError.unreadableAudio }
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
/// a preview, and a render copies samples stored as they are through it; a
/// render that decodes reads the stretches one by one instead
/// (`AudioEditRenderer.readStretches`), since AVFoundation decodes an MP3
/// wrongly through a composition.
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
        let pieces = try await AudioEditStretchSound.pieces(of: timeline, sources: sources)
        return try make(pieces, sampleRate: timeline.sampleRate)
    }

    /// The composition of `pieces`, every stretch of a timeline at
    /// `sampleRate` in order, their files already opened
    /// (`AudioEditStretchSound.pieces(of:sources:)`).
    /// - Throws: `AudioEditError.renderFailed` when AVFoundation refuses a
    ///   stretch.
    static func make(_ pieces: [AudioEditStretchSound.Piece], sampleRate: Double) throws -> AudioEditComposition {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw AudioEditError.renderFailed("the composition took no audio track") // l10n: no (a technical reason for the debug log (AudioEditError.renderFailed); the listener hears its fixed sentence)
        }
        var position: Int64 = 0
        for piece in pieces {
            try insert(piece.range, of: piece.track, at: AudioEditStretchSound.time(position, at: sampleRate), into: track)
            position += piece.length
        }
        // Each file once, kept alive with the composition.
        var seen: Set<ObjectIdentifier> = []
        let assets = pieces.map(\.asset).filter { seen.insert(ObjectIdentifier($0)).inserted }
        return AudioEditComposition(composition: composition, sources: assets, frames: position, sampleRate: sampleRate)
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
}

// MARK: - The Stretches' Sound

/// Where the stretches of a timeline find their sound (FR04): each file
/// opened once, with its first audio track, and each stretch as the pieces
/// of those files it plays, in order (`pieces(of:sources:)`). A composition
/// is made of them (`AudioEditComposition.make`), and a render that decodes
/// reads them one by one (`AudioEditRenderer.readStretches`). Each piece
/// keeps its file's asset, so it lives as long as the piece is used.
struct AudioEditStretchSound {
    /// One piece of a stretch: `range` of `track`, the first audio track of
    /// the file `asset` opened, in that file's own time, lasting `length`
    /// frames at the timeline's rate; `sourceEnd` is where that track's
    /// sound ends, as far as a read of the piece may run past it.
    struct Piece {
        let asset: AVURLAsset
        let track: AVAssetTrack
        let range: CMTimeRange
        let length: Int64
        let sourceEnd: CMTime
    }

    /// The timeline's rate, the timescale of every time given here.
    let sampleRate: Double
    /// Where the stretches come from.
    let sources: AudioEditComposition.Sources
    /// The files opened so far, by their URL, with where each one's sound
    /// ends.
    private var opened: [URL: (asset: AVURLAsset, track: AVAssetTrack, end: CMTime)] = [:]

    /// Every piece of the stretches of `timeline`, whose stretches come from
    /// `sources`, in order: each file opened once, and each stretch checked
    /// against it, before any sound is read.
    /// - Throws: `AudioEditError.missingAudio`, `.audioInCloud`, or
    ///   `.unreadableAudio` for a source that can't be read; `.invalidEdit`
    ///   for a stretch reaching past the end of its source;
    ///   `.fileOutsidePackage` for a source named outside the book.
    static func pieces(of timeline: AudioEditTimeline, sources: AudioEditComposition.Sources) async throws -> [Piece] {
        var sound = AudioEditStretchSound(sampleRate: timeline.sampleRate, sources: sources)
        var pieces: [Piece] = []
        for segment in timeline.segments {
            pieces += try await sound.pieces(of: segment)
        }
        return pieces
    }

    /// `frames` frames as a time at `sampleRate`.
    static func time(_ frames: Int64, at sampleRate: Double) -> CMTime {
        CMTime(value: frames, timescale: CMTimeScale(sampleRate.rounded()))
    }

    /// The sound of the stretches of a timeline at `sampleRate` whose
    /// stretches come from `sources`, no file opened yet.
    private init(sampleRate: Double, sources: AudioEditComposition.Sources) {
        self.sampleRate = sampleRate
        self.sources = sources
    }

    /// `frames` frames as a time at the timeline's rate.
    private func time(_ frames: Int64) -> CMTime {
        Self.time(frames, at: sampleRate)
    }

    /// The pieces `segment` plays, in order: one range of its source, or,
    /// for silence, pieces of the silent file of at most
    /// `AudioEditComposition.silenceSeconds` each, as long as the silence
    /// lasts.
    /// - Throws: as `pieces(of:sources:)` does.
    private mutating func pieces(of segment: AudioEditTimeline.Segment) async throws -> [Piece] {
        guard case .silence = segment.source else {
            let (url, name) = try Self.location(of: segment.source, in: sources)
            let source = try await open(url, name: name)
            let range = CMTimeRange(start: time(segment.sourceStart), duration: time(segment.length))
            // Rounding to frames can reach half a frame past a source's
            // measured end; anything more names sound that isn't there.
            guard CMTimeCompare(range.end, CMTimeAdd(source.end, time(1))) <= 0 else {
                // Translators: Said when an edit names a stretch of a source audio file that lies past the file's end. %@ is the file's name.
                throw AudioEditError.invalidEdit(InterfaceText.line("audioEditStretchSound.pieces", "A stretch of the edits runs past the end of “\(name)”."))
            }
            return [Piece(asset: source.asset, track: source.track, range: range, length: segment.length, sourceEnd: source.end)]
        }
        let silence = try AudioEditScratch.silentFile(sampleRate: sampleRate, channels: sources.base.channelCount, in: sources.scratch)
        let source = try await open(silence, name: silence.lastPathComponent)
        let most = Int64(AudioEditComposition.silenceSeconds * sampleRate)
        var pieces: [Piece] = []
        var remaining = segment.length
        while remaining > 0 {
            let length = min(most, remaining)
            pieces.append(Piece(
                asset: source.asset,
                track: source.track,
                range: CMTimeRange(start: .zero, duration: time(length)),
                length: length,
                sourceEnd: source.end
            ))
            remaining -= length
        }
        return pieces
    }

    /// The file at `url`, named `name` for an error, opened once: its asset,
    /// its first audio track, and where that track ends.
    private mutating func open(_ url: URL, name: String) async throws -> (asset: AVURLAsset, track: AVAssetTrack, end: CMTime) {
        if let known = opened[url] { return known }
        guard FileManager.default.fileExists(atPath: url.path) else { throw AudioEditError.missingAudio(name) }
        guard !DatalessFiles.isDataless(url) else { throw AudioEditError.audioInCloud }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let range = try? await track.load(.timeRange) else {
            throw AudioEditError.unreadableAudio
        }
        opened[url] = (asset, track, range.end)
        return (asset, track, range.end)
    }

    /// The file `source` plays from, and its name for an error: the base
    /// audio, a take inside the package, or a processed stretch in the
    /// scratch folder.
    private static func location(of source: AudioEditTimeline.Source, in sources: AudioEditComposition.Sources) throws -> (URL, String) {
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
            // Silence is taken from the silent file before this is asked.
            throw AudioEditError.renderFailed("silence has no file of its own") // l10n: no (a technical reason for the debug log (AudioEditError.renderFailed); the listener hears its fixed sentence)
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
/// can be made again from the book's package, and an edit session makes a
/// processed stretch again when it is next needed. A book's folder is
/// removed once its edits are rendered into its audio, whenever an edit
/// session closes, and, after a crash, at the next launch
/// (`AudioEditCaches.removeStale`).
enum AudioEditScratch {
    /// The folder of all books' scratch folders.
    static var root: URL {
        MachineLocalPaths.caches.appendingPathComponent("Audio Edits", isDirectory: true)
    }

    /// Serializes making a book's scratch folder for a use of the book with
    /// the launch sweep's choice to remove it (`setAside`), so the sweep never
    /// removes a folder an edit session or a save has begun to use.
    private static let lock = NSLock()

    /// The scratch folder of the book `bookID`, made when missing. Call it
    /// once a use of the book has begun (`AudioEditActivity`).
    static func folder(for bookID: UUID) throws -> URL {
        let folder = root.appendingPathComponent(bookID.uuidString, isDirectory: true)
        lock.lock()
        defer { lock.unlock() }
        try make(folder)
        return folder
    }

    /// Moves `folder`, a book's scratch folder, aside to be removed, beside
    /// itself under a name of `AudioEditCaches.setAsidePrefix`, unless
    /// `isInUse` says its book is in use, both while no scratch folder is
    /// being made for a use: so a use that begins now makes a new folder.
    /// Returns where the folder went, or nil when it stays.
    static func setAside(_ folder: URL, unless isInUse: () -> Bool) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard !isInUse() else { return nil }
        let aside = folder.deletingLastPathComponent()
            .appendingPathComponent(AudioEditCaches.setAsidePrefix + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.moveItem(at: folder, to: aside)
            return aside
        } catch {
            return nil
        }
    }

    /// Makes the scratch folder `folder` when it is missing. Whatever writes
    /// there makes it first: a save removes the folder once it has rendered
    /// the edits, while the editor stays open to edit on, and macOS may
    /// empty the Caches folder at any time.
    static func make(_ folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
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
        try make(folder)
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
