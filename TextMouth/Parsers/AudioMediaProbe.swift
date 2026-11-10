import AVFoundation
import Foundation

// MARK: - Problems

/// Why an audio file cannot be played. Each problem completes the sentence
/// `PackageDamage` speaks for a damaged file: "The file “03.mp3” in this
/// audiobook is damaged or incomplete: …".
enum AudioMediaProblem: Error, Equatable, Sendable {
    /// AVFoundation cannot open the file as media at all: it is not audio
    /// (a text file named "03.mp3"), or its header is damaged or describes
    /// audio in a form the Mac cannot decode.
    case cannotOpen
    /// The file opens, but holds no audio that can be played: AVFoundation
    /// says it cannot be played, it has no audio track the Mac can decode,
    /// or it has no samples at all, as a WAVE file cut off right after its
    /// header has none.
    case noAudio
    /// The opening of the file's audio cannot be decoded.
    case cannotDecode
    /// The file's audio breaks off before the length its header declares,
    /// as a copy or download that stopped partway leaves an MPEG-4 file:
    /// its index still lists every sample, but the last ones are missing.
    case endsEarly

    /// What is wrong, as the end of the sentence "The file … is damaged or
    /// incomplete: …".
    var reason: String {
        switch self {
        case .cannotOpen: return "it cannot be opened as audio"
        case .noAudio: return "it holds no audio that can be played"
        case .cannotDecode: return "its audio cannot be decoded"
        case .endsEarly: return "its audio breaks off before the length the file declares"
        }
    }
}

// MARK: - Probing One File

/// Checks that an audio file can be played and measures how long it plays,
/// before an audiobook's sections are built on it (TODO I04).
///
/// A file passes only when every one of these holds. The properties are
/// AVFoundation's own answers to "can this be played?", as its headers
/// define them:
///
/// 1. `AVURLAsset` loads `duration`, `isPlayable`, and `isReadable` without
///    an error. A file AVFoundation cannot open as media (text named
///    ".mp3", a damaged WAVE header, a codec description it cannot decode)
///    fails to load.
/// 2. `isPlayable`: "whether an AVPlayer can play the contents of the
///    asset". The reader plays every file through `AVPlayer`.
/// 3. At least one audio track is `isDecodable`: the track "can be decoded"
///    in this environment, so the Mac has a decoder for its format.
/// 4. `duration` is a finite number of seconds above zero and at most a
///    year (`isPlayableLength(_:)`). A WAVE file cut off after its header
///    opens, plays, and decodes, with no samples; an MPEG-4 file's movie
///    header (`mvhd`) can claim 1e18 seconds over an audio track of two.
/// 5. When `isReadable` ("whether an AVAssetReader can be used" to extract
///    its samples), the first half second and the final second of that
///    track decode, measured over the track's own time range, so another
///    track that runs longer (an audiobook's cover art or chapter titles)
///    cannot leave the final second without audio. A truncated MPEG-4
///    file (.m4a, .m4b) still opens with its full duration, playable and
///    decodable, because its index comes first and still lists every
///    sample; only decoding its end fails. An asset that cannot be read
///    this way, as with some protected content that `AVPlayer` may still
///    play, skips this check rather than being refused.
///
/// The asset asks for precise timing
/// (`AVURLAssetPreferPreciseDurationAndTimingKey`). Without it, an MP3's
/// duration is estimated from its size and its first frames' bit rate:
/// measured on two 600-second VBR files without a Xing header, the
/// estimates were 578.6 and 829.4 seconds, which would refuse a valid book
/// or accept sections that run past the audio. Precise timing makes
/// AVFoundation examine the MP3's frames first (about 25 ms per megabyte,
/// measured); MPEG-4 files already state their exact timing, as the key's
/// documentation notes, and WAVE files their exact length.
///
/// Garbage samples under a well-formed header (PCM or ADPCM noise) decode
/// as noise, which no check can tell from a recording, so they pass.
enum AudioMediaProbe {
    /// Seconds decoded at the start of the file to confirm its audio
    /// decodes at all: enough for several frames of any codec.
    static let openingCheckDuration: TimeInterval = 0.5

    /// Seconds decoded at the end of the file to confirm the audio its
    /// header promises is all there: several frames of any codec, so a
    /// file cut short anywhere fails, as its last frames are always lost.
    static let endingCheckDuration: TimeInterval = 1

    /// How long the audio file at `url` plays, in seconds, or why it cannot
    /// be played. See the type's documentation for each check.
    static func duration(of url: URL) async -> Result<TimeInterval, AudioMediaProblem> {
        // Never decode a format the import converts (B09, FMT09): Apple's
        // Vorbis decoder once spun forever. Such audio is converted in a
        // child process first.
        guard !ImportAudioConverter.isNeverDecodedInApp(url) else { return .failure(.cannotOpen) }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])

        // Opening: any load error means AVFoundation cannot read the file
        // as media. Its own words ("Operation Stopped") help no listener,
        // so the problem is reported in the terms above.
        let duration: CMTime
        let isPlayable: Bool
        let isReadable: Bool
        do {
            (duration, isPlayable, isReadable) = try await asset.load(.duration, .isPlayable, .isReadable)
        } catch {
            return .failure(.cannotOpen)
        }

        guard isPlayable, let audio = await firstDecodableAudioTrack(of: asset) else {
            return .failure(.noAudio)
        }
        let seconds = CMTimeGetSeconds(duration)
        guard isPlayableLength(seconds) else { return .failure(.noAudio) }

        if isReadable {
            // The span the track's samples cover, by its index; the whole
            // asset when the track reports no usable span.
            let start = CMTimeGetSeconds(audio.timeRange.start)
            let end = CMTimeGetSeconds(audio.timeRange.end)
            let span = start.isFinite && end.isFinite && end > start ? start...end : 0...seconds
            if let problem = await decodingProblemOffThePool(of: audio.track, in: asset, over: span) {
                return .failure(problem)
            }
        }
        return .success(seconds)
    }

    /// Whether `seconds`, the length a file's header states, is one audio
    /// can play for: a finite number above zero and at most
    /// `OggHeaderReader.maximumDuration` (a year), the longest length any
    /// of TextMouth's readers believes. A header can state anything; a
    /// longer length is a damaged header, not audio, and believed it would
    /// become the length of a book's section.
    static func isPlayableLength(_ seconds: TimeInterval) -> Bool {
        seconds.isFinite && seconds > 0 && seconds <= OggHeaderReader.maximumDuration
    }

    /// The first audio track of `asset` that the Mac can decode, with the
    /// time range its index says its samples cover, or nil when it has none.
    private static func firstDecodableAudioTrack(
        of asset: AVURLAsset
    ) async -> (track: AVAssetTrack, timeRange: CMTimeRange)? {
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else { return nil }
        for track in tracks {
            guard let (isDecodable, timeRange) = try? await track.load(.isDecodable, .timeRange) else { continue }
            if isDecodable {
                return (track, timeRange)
            }
        }
        return nil
    }

    /// The queue the decoding checks run on, many at once (the prober runs up to four probes).
    private static let decodeQueue = DispatchQueue(label: "com.textmouth.AudioMediaProbe.decode", qos: .utility,
                                                   attributes: .concurrent)

    /// `decodingProblem(of:in:over:)`, run on `decodeQueue` and not in a task of Swift's concurrency pool. The
    /// check blocks its thread in `AVAssetReaderOutput.copyNextSampleBuffer()`, a few milliseconds on a Mac with
    /// working audio. On a GitHub runner it sometimes never returned (the spindump of a hung test, run 42856695469,
    /// shows three probes in it), and a task of the pool that blocks takes one of its few threads for good: the
    /// threads of the process were all held, and the tests after the hung one failed with it. A thread of a
    /// dispatch queue held for ever costs nothing else.
    private static func decodingProblemOffThePool(
        of track: AVAssetTrack,
        in asset: AVAsset,
        over span: ClosedRange<TimeInterval>
    ) async -> AudioMediaProblem? {
        await withCheckedContinuation { continuation in
            decodeQueue.async { continuation.resume(returning: decodingProblem(of: track, in: asset, over: span)) }
        }
    }

    /// Why `track` fails to decode, checked at the opening of `span` (the
    /// seconds its samples cover) and over its final second, or nil when
    /// both decode.
    ///
    /// Decoding blocks the calling thread for a few milliseconds (a second
    /// and a half of audio, decoded far faster than real time).
    private static func decodingProblem(
        of track: AVAssetTrack,
        in asset: AVAsset,
        over span: ClosedRange<TimeInterval>
    ) -> AudioMediaProblem? {
        let length = span.upperBound - span.lowerBound
        let opening = CMTimeRange(
            start: CMTime(seconds: span.lowerBound, preferredTimescale: 600),
            duration: CMTime(seconds: min(openingCheckDuration, length), preferredTimescale: 600)
        )
        guard decodesSamples(of: track, in: asset, within: opening) else { return .cannotDecode }

        // From one second before the declared end to whatever end the
        // file really has.
        let ending = CMTimeRange(
            start: CMTime(seconds: max(span.lowerBound, span.upperBound - endingCheckDuration), preferredTimescale: 600),
            duration: .positiveInfinity
        )
        guard decodesSamples(of: track, in: asset, within: ending) else { return .endsEarly }
        return nil
    }

    /// Whether `track` decodes to at least one sample within `range`, read
    /// to the range's end through `AVAssetReader` as linear PCM, without
    /// the reader failing on the way.
    private static func decodesSamples(of track: AVAssetTrack, in asset: AVAsset, within range: CMTimeRange) -> Bool {
        guard let reader = try? AVAssetReader(asset: asset) else { return false }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
        // The samples are only counted, never kept, so no copy is needed.
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return false }
        reader.add(output)
        reader.timeRange = range
        guard reader.startReading() else { return false }

        var decodedSamples = 0
        while let buffer = output.copyNextSampleBuffer() {
            decodedSamples += CMSampleBufferGetNumSamples(buffer)
        }
        return reader.status == .completed && decodedSamples > 0
    }
}

// MARK: - Probing a Book's Files

/// Probes audio files for a parse: how long each plays, or why it cannot be
/// played. Parsers take one, so tests can count probes or stand in for
/// AVFoundation; the app always uses `avFoundation`.
struct AudioMediaProber: Sendable {
    /// What probing the file at a URL found. Called from several tasks at
    /// once, so it must be safe to call concurrently.
    let probe: @Sendable (URL) async -> Result<TimeInterval, AudioMediaProblem>

    /// The probe the app uses: `AudioMediaProbe.duration(of:)`.
    static let avFoundation = AudioMediaProber { url in
        await AudioMediaProbe.duration(of: url)
    }

    /// How many files are probed at once. Probing is mostly reading the
    /// file (an MP3's frames are scanned end to end), so a few at a time
    /// shorten a book of many files without crowding the disk or memory.
    static let maximumConcurrentProbes = 4

    /// What probing each of `files` found, in the same order. This is the
    /// parse's cache: each distinct file is probed exactly once, however
    /// many times it is listed (as when several sections share one file),
    /// and every listing of it gets that one result. Up to
    /// `maximumConcurrentProbes` probes run at a time.
    func probeEach(_ files: [URL]) async -> [Result<TimeInterval, AudioMediaProblem>] {
        // Map each listing to its file's place among the distinct files.
        var distinctFiles: [URL] = []
        var placeOfFile: [URL: Int] = [:]
        let places = files.map { file -> Int in
            if let place = placeOfFile[file] { return place }
            placeOfFile[file] = distinctFiles.count
            distinctFiles.append(file)
            return distinctFiles.count - 1
        }

        let outcomes = await probeConcurrently(distinctFiles)
        return places.map { outcomes[$0] }
    }

    /// Probe every one of `files`, up to `maximumConcurrentProbes` at a
    /// time, returning the outcomes in the order of `files`.
    private func probeConcurrently(_ files: [URL]) async -> [Result<TimeInterval, AudioMediaProblem>] {
        let probe = self.probe
        return await withTaskGroup(of: (index: Int, outcome: Result<TimeInterval, AudioMediaProblem>).self) { group in
            var nextIndex = 0
            var finished: [(index: Int, outcome: Result<TimeInterval, AudioMediaProblem>)] = []
            while true {
                // Start probes while files remain and fewer than the limit
                // are running (every started probe not yet finished runs).
                while nextIndex < files.count, nextIndex - finished.count < Self.maximumConcurrentProbes {
                    let index = nextIndex
                    group.addTask { (index, await probe(files[index])) }
                    nextIndex += 1
                }
                guard let done = await group.next() else { break }
                finished.append(done)
            }
            // Probes finish in any order; put each outcome back in place.
            return finished.sorted { $0.index < $1.index }.map(\.outcome)
        }
    }
}
