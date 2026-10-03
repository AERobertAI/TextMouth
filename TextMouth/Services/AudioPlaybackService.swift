@preconcurrency import AVFoundation
import Combine

/// Latest-wins gate for asynchronous AVPlayer seeks. AVPlayer may complete
/// overlapping seeks out of order; a plain Boolean lets an older completion
/// re-enable position observers while a newer seek is still pending.
final class AudioSeekGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var pendingGeneration: Int?

    @discardableResult
    func begin() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        pendingGeneration = generation
        return generation
    }

    func complete(_ token: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard pendingGeneration == token else { return }
        pendingGeneration = nil
    }

    func cancelAll() {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        pendingGeneration = nil
    }

    var isSeeking: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingGeneration != nil
    }
}

enum AudioPositionObserverPolicy {
    enum Action: Equatable {
        case ignore
        case finishClip
        case publish(TimeInterval)
    }

    static func action(
        seconds: TimeInterval,
        isSeeking: Bool,
        clipEndTime: TimeInterval?
    ) -> Action {
        guard seconds.isFinite, !isSeeking else { return .ignore }
        if let clipEndTime, seconds >= clipEndTime {
            return .finishClip
        }
        return .publish(seconds)
    }
}

/// Decides whether audio that should be playing has stalled.
enum AudioStallPolicy {
    /// Whether playback the service believes is running has stalled: the
    /// player is not advancing, and it has not simply reached the end of its
    /// file, whose completion is on its way. Paused or stopped playback
    /// never counts as stalled.
    static func isStalled(
        isPlaying: Bool,
        isPaused: Bool,
        playerIsAdvancing: Bool,
        reachedEndOfFile: Bool
    ) -> Bool {
        isPlaying && !isPaused && !playerIsAdvancing && !reachedEndOfFile
    }
}

// MARK: - Clip Chains

/// The clips one chapter of a segmented audiobook plays, one after another,
/// as a single stretch of the chapter's time. The chapter's time is 0 where
/// its first clip starts and runs on through each clip in turn, whatever
/// file holds it. `AudioPlaybackService.playClips(_:fromChapterTime:)` plays
/// a chain; this type converts between a time in the chapter and a clip
/// with a time in that clip's file.
struct AudioClipChain: Equatable, Sendable {
    /// One stretch of one audio file.
    struct Clip: Equatable, Sendable {
        /// The file the clip plays from.
        let url: URL
        /// Where the clip starts in its file, in seconds.
        let start: TimeInterval
        /// Where the clip ends in its file, in seconds, or nil when it plays
        /// to the end of the file.
        let end: TimeInterval?

        /// How long the clip plays, in seconds. A clip that plays to the end
        /// of its file counts as lasting no time, since only its file knows
        /// how long that is; in a chain of several clips every clip but
        /// perhaps the last has an end (see `AudioBookParser`).
        var duration: TimeInterval {
            guard let end else { return 0 }
            return max(0, end - start)
        }
    }

    /// The clips, in the order they play. Never empty.
    let clips: [Clip]
    /// Where each clip starts in the chapter, in seconds: the lengths of
    /// the clips before it, together.
    let startTimes: [TimeInterval]

    /// A chain of `clips`, or nil when there are none.
    init?(clips: [Clip]) {
        guard !clips.isEmpty else { return nil }
        self.init(nonEmpty: clips)
    }

    /// The chain `segment` plays, each clip's file found in `folder`, the
    /// book's audio folder. A clip whose end is not after its start (an end
    /// of 0 means just this) plays to the end of its file, as a segment's
    /// clip always has.
    init(segment: AudioSegment, folder: URL) {
        self.init(nonEmpty: segment.clips.map { clip in
            Clip(
                url: folder.appendingPathComponent(clip.file),
                start: clip.startTime,
                end: clip.endTime > clip.startTime ? clip.endTime : nil
            )
        })
    }

    /// The chain of `clips`, which holds at least one.
    private init(nonEmpty clips: [Clip]) {
        self.clips = clips
        var starts: [TimeInterval] = []
        var elapsed: TimeInterval = 0
        for clip in clips {
            starts.append(elapsed)
            elapsed += clip.duration
        }
        startTimes = starts
    }

    /// The clip playing `chapterTime` seconds into the chapter, and the time
    /// in its file to play from. A time before the chapter is its start; a
    /// time past the last clip's end lies past that end, in the last clip,
    /// where playback finishes at once, as past a lone clip's end. Where
    /// one clip ends and the next starts, the next is chosen, so a clip
    /// that lasts no time is passed over.
    func location(atChapterTime chapterTime: TimeInterval) -> (clipIndex: Int, fileTime: TimeInterval) {
        let time = chapterTime.isFinite ? max(0, chapterTime) : 0
        let index = startTimes.lastIndex { $0 <= time } ?? 0
        return (index, clips[index].start + (time - startTimes[index]))
    }

    /// How far into the chapter `fileTime`, a time in the file of clip
    /// `clipIndex`, lies. A time before the clip's start counts as its
    /// start, and one past its end as its end: the player runs a moment
    /// past a clip's end before playback moves on, and the next clip begins
    /// the chapter's time exactly there, so the chapter's time never runs
    /// ahead and then back.
    func chapterTime(clipIndex: Int, fileTime: TimeInterval) -> TimeInterval {
        let clip = clips[clipIndex]
        var elapsed = max(0, fileTime - clip.start)
        if clip.end != nil {
            elapsed = min(elapsed, clip.duration)
        }
        return startTimes[clipIndex] + elapsed
    }
}

// MARK: - Audio Speed Rules

/// The single source of truth for audio book playback speed: the supported
/// range, the step sizes, snapping, and the text shown and spoken for a speed.
///
/// Audio speed is a multiplier of the recording's natural speed (1.0 = as
/// recorded). Every speed that is applied to the player, restored from a
/// saved book, used for a time estimate, saved, displayed, or announced
/// passes through `normalized(_:)`, which clamps it to `range` and snaps it
/// to the `fineStep` grid. Snapping keeps binary floating-point drift such as
/// `1.0 + 0.1 == 1.1000000000000001` out of the player, the UI, and the saved
/// library, and keeps the quarter steps saved by earlier releases
/// (1.25, 1.5, 1.75, 2) exact.
enum AudioSpeed {
    /// Supported multipliers. Unchanged from earlier releases so every saved
    /// per-book speed stays valid. Both bounds lie on the snapping grid.
    static let range: ClosedRange<Double> = 0.25...4.0

    /// The recording's natural speed, and the fallback for unusable values.
    static let normal: Double = 1.0

    /// Step for quick adjustments: the playback bar's speed buttons and the
    /// Increase Speed / Decrease Speed menu items and keyboard shortcuts.
    /// Steps are relative, so a speed of 1.25 moves to 1.35 and back.
    static let coarseStep: Double = 0.1

    /// Step for precise adjustments: the stepper and slider in the per-book
    /// speed sheet. It is also the snapping grid, so every normalized speed
    /// is a whole number of fine steps.
    static let fineStep: Double = 0.05

    /// Grid points per 1x (20 for a 0.05 grid). Snapping multiplies by this
    /// whole number, rounds to an integer, and divides back; dividing two
    /// exact integers yields the Double closest to the intended decimal, so
    /// the result compares equal to a literal such as 1.1.
    private static let gridPointsPerUnit = (1 / fineStep).rounded()

    /// Clamps `speed` to `range` and snaps it to the nearest `fineStep`.
    /// Non-finite input (NaN or infinity from damaged saved data) falls back
    /// to `normal`, because neither range bound is a sensible guess for it.
    static func normalized(_ speed: Double) -> Double {
        guard speed.isFinite else { return normal }
        let clamped = min(max(speed, range.lowerBound), range.upperBound)
        // The bounds are on the grid, so snapping cannot leave the range.
        return (clamped * gridPointsPerUnit).rounded() / gridPointsPerUnit
    }

    // MARK: Labels

    /// A multiplier or step as a plain decimal with one or two fraction
    /// digits: "1.0", "1.3", "1.25", "0.05". It always uses "." (like the
    /// app's other numeric labels) so the visible and spoken forms of a
    /// speed carry exactly the same number.
    static func formattedNumber(_ value: Double) -> String {
        // Two fixed decimals keep every hundredth ("1.25", "1.30"). Dropping
        // one trailing zero then leaves at least one decimal ("1.3", "1.0"),
        // so a two-decimal speed is never shown with one decimal.
        let twoDecimals = String(format: "%.2f", value)
        return twoDecimals.hasSuffix("0") ? String(twoDecimals.dropLast()) : twoDecimals
    }

    /// Visible speed text, e.g. "1.0x", "1.3x", "1.25x". The speed is
    /// normalized first, so the label always names the speed that plays.
    static func visibleLabel(for speed: Double) -> String {
        "\(formattedNumber(normalized(speed)))x"
    }

    /// Spoken equivalent of `visibleLabel(for:)` for VoiceOver and braille,
    /// e.g. "1.25 times speed". A bare "1.25x" is read ambiguously.
    static func spokenLabel(for speed: Double) -> String {
        "\(formattedNumber(normalized(speed))) times speed"
    }

    /// Accessibility label for a button that moves the speed by `step`,
    /// e.g. "Increase audio speed by 0.1 times".
    static func stepButtonLabel(increasing: Bool, by step: Double) -> String {
        "\(increasing ? "Increase" : "Decrease") audio speed by \(formattedNumber(step)) times"
    }

    /// Accessibility hint for an adjustable control that moves in steps of
    /// `step`, e.g. "Changes the speed in steps of 0.05 times".
    static func stepHint(_ step: Double) -> String {
        "Changes the speed in steps of \(formattedNumber(step)) times"
    }
}

// MARK: - Playback Failures

/// Why the audio player could not play a file, or stopped playing it.
///
/// Every failure names its file, so a listener can be told which track to
/// restore, and keeps AVFoundation's own error, when it gave one, for the
/// debug log.
struct AudioPlaybackFailure: Error, Equatable, Sendable {
    /// What went wrong, in the terms a listener is told.
    enum Reason: Equatable, Sendable {
        /// Nothing exists at the file's path.
        case fileMissing
        /// The file cannot be read, or what it holds is not audio that
        /// AVFoundation can play: a damaged track, a folder, or some other
        /// kind of file under an audio name.
        case fileUnreadable
        /// The file started playing and then failed partway through.
        case failedDuringPlayback
        /// Audio stopped arriving, or never started, and playback did not
        /// recover in time.
        case stalled
    }

    /// What went wrong.
    let reason: Reason
    /// The file that failed, as the player was asked to load it.
    let url: URL
    /// AVFoundation's description of the failure, when it gave one.
    let underlyingError: NSError?

    init(reason: Reason, url: URL, underlyingError: Error? = nil) {
        self.reason = reason
        self.url = url
        self.underlyingError = underlyingError.map { $0 as NSError }
    }

    /// The file's name, such as "03.mp3". A listener knows a track by its
    /// name, never by the package path around it.
    var fileName: String { url.lastPathComponent }

    /// What happened to the file, as a clause that can end a longer
    /// sentence: "the file 03.mp3 is missing".
    var problem: String { "the file \(fileName) \(predicate)" }

    /// The problem as a sentence of its own, to show or speak:
    /// "The file 03.mp3 is missing."
    var message: String { "The file \(fileName) \(predicate)." }

    /// The reason for an error AVFoundation raised while opening or playing
    /// a file.
    ///
    /// What is wrong with the file now comes first, so a track deleted or
    /// made unreadable after it was checked is reported as exactly that.
    /// Otherwise an item that never became ready to play could not be
    /// opened as audio, and one that did failed partway through.
    ///
    /// - Parameters:
    ///   - fileProblem: What `AudioPlaybackService.fileProblem(at:)` finds
    ///     wrong with the file now, or nil when nothing is.
    ///   - itemBecameReady: Whether the item ever reached `.readyToPlay`.
    static func reasonForPlaybackError(
        fileProblem: Reason?,
        itemBecameReady: Bool
    ) -> Reason {
        fileProblem ?? (itemBecameReady ? .failedDuringPlayback : .fileUnreadable)
    }

    /// What happened, following "the file 03.mp3".
    private var predicate: String {
        switch reason {
        case .fileMissing:
            return "is missing"
        case .fileUnreadable:
            return "is damaged, unreadable, or not an audio file"
        case .failedDuringPlayback:
            return "failed partway through"
        case .stalled:
            return "could not be read quickly enough"
        }
    }
}

/// Plays audio files (mp3, m4a, m4b, wav, etc.) with variable speed and seeking.
/// Used for audio book playback as an alternative to the TTS SpeechService.
///
/// A chapter of a segmented audiobook can play several clips, stretches of
/// one or more files: `playClips(_:fromChapterTime:)` plays them one after
/// another as one chapter, timed by the chapter's clock (see
/// `AudioClipChain`).
///
/// A file that cannot be played is reported through one channel: `failure`
/// is set and `onPlaybackFailed` is called. Playback halts, the player is
/// released, and `currentTime` stays where it was, so the same position can
/// be played again once the file is restored.
final class AudioPlaybackService: NSObject, ObservableObject, @unchecked Sendable {
    @Published var isPlaying = false
    @Published var isPaused = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var playbackSpeed: Double = 1.0
    /// Why the file most recently loaded could not be played, or stopped
    /// playing. Nil until a failure, and cleared again when a file loads
    /// successfully.
    @Published private(set) var failure: AudioPlaybackFailure?

    var onPlaybackFinished: (() -> Void)?
    var onPositionUpdate: ((TimeInterval) -> Void)?
    /// Called on the main queue once for each failure, after `failure` is
    /// set and playback has halted. A file that fails never also reports
    /// `onPlaybackFinished`.
    var onPlaybackFailed: ((AudioPlaybackFailure) -> Void)?

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    /// Observes the current item failing to play to its end.
    private var failedToPlayToEndObserver: NSObjectProtocol?
    /// Observes the current item stalling: audio not arriving in time.
    private var stallObserver: NSObjectProtocol?
    /// The pending check that playback is really advancing; see
    /// `scheduleProgressCheck()`.
    private var progressCheck: DispatchWorkItem?
    /// Key-value observations of the current item's and player's status,
    /// either of which can become `.failed`.
    private var itemStatusObservation: NSKeyValueObservation?
    private var playerStatusObservation: NSKeyValueObservation?
    /// Whether the current item has reached `.readyToPlay`. An error before
    /// then means the file could not be opened as audio; one after it means
    /// playback failed partway through.
    private var itemBecameReady = false
    private var durationTask: Task<Void, Never>?
    private(set) var loadedURL: URL?

    /// Optional clip end time for segmented audio (e.g. DAISY).
    /// When set, playback fires onPlaybackFinished when reaching this time
    /// instead of waiting for the actual end of the audio file. While a
    /// clip chain plays, it is the loaded clip's end, and reaching it moves
    /// on to the next clip instead, until the last.
    private var clipEndTime: TimeInterval?

    /// The clip chain being played and which of its clips is loaded, or nil
    /// while the service plays a file on its own (`load(url:)`). While a
    /// chain plays, every time the service takes or reports, from
    /// `play(fromTime:)` and `seek(to:)` to `currentTime` and
    /// `onPositionUpdate`, is the chapter's time (see `AudioClipChain`).
    private var chained: ChainedPlayback?

    /// A clip chain, and the clip of it now loaded.
    private struct ChainedPlayback {
        /// The chapter's clips.
        let chain: AudioClipChain
        /// The place in `chain.clips` of the clip now loaded.
        let clipIndex: Int
    }

    /// Guards against the time observer firing clip-end while a seek is
    /// still in progress. Set true before seek, cleared in the completion
    /// handler. Prevents the stale-time race that causes rapid looping
    /// when consecutive segments share the same audio file.
    private let seekGate = AudioSeekGate()

    /// Tracks the intended output volume independently of the AVPlayer
    /// instance. When load() creates a new AVPlayer for a chapter
    /// transition, the new player defaults to volume 1.0, discarding
    /// any fade-in-progress volume set by the sleep timer. This property
    /// is re-applied after every new player creation so volume remains
    /// consistent across chapters (mirrors the fix in AudioEngineService).
    private var currentVolume: Float = 1.0

    /// Slowest and fastest supported multipliers (see `AudioSpeed.range`).
    let minimumSpeed: Double = AudioSpeed.range.lowerBound
    let maximumSpeed: Double = AudioSpeed.range.upperBound

    /// How long playback may go without advancing, after it was asked to
    /// start, resume, seek, or recover from a stall, before it is reported
    /// as a `.stalled` failure. A local file starts within milliseconds, so
    /// the margin is wide; hosted tests shorten it.
    var stallRecoveryTimeout: TimeInterval = 10

    override init() {
        super.init()
    }

    deinit {
        stop()
    }

    // MARK: - Loading

    /// Load an audio file for playback. Call this before play().
    ///
    /// The file is checked before a player is built. A missing file, or one
    /// that cannot be read, is reported through `failure` and
    /// `onPlaybackFailed` before this returns, and no player is created, so
    /// nothing can claim to play it.
    ///
    /// The file plays on its own, timed by its own clock: a clip chain that
    /// was playing ends here.
    ///
    /// - Returns: True when a player holds the file, ready to be asked to
    ///   play it; false when the file failed its check.
    @discardableResult
    func load(url: URL) -> Bool {
        chained = nil
        let normalizedURL = url.standardizedFileURL
        // A failure releases its player, so a live player for this URL has
        // not failed and can keep playing the file.
        if let loadedURL, loadedURL == normalizedURL, player != nil {
            clipEndTime = nil
            return true
        }

        // A chapter transition replaces the player but is not a user-visible
        // full stop. Preserve an in-progress sleep-timer fade across the
        // teardown; public stop() still resets volume for a future session.
        let volumeBeforeLoad = currentVolume
        stop()
        currentVolume = volumeBeforeLoad
        clipEndTime = nil

        if let reason = Self.fileProblem(at: normalizedURL) {
            reportFailure(AudioPlaybackFailure(reason: reason, url: normalizedURL))
            return false
        }
        failure = nil

        let asset = AVURLAsset(url: normalizedURL)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain // Best for speech

        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.automaticallyWaitsToMinimizeStalling = false
        // Re-apply tracked volume to the new player. AVPlayer defaults
        // to 1.0, which discards any in-progress sleep timer fade.
        avPlayer.volume = currentVolume

        self.playerItem = item
        self.player = avPlayer
        self.loadedURL = normalizedURL

        // Get duration — cancel any previous load to avoid stale overwrites
        durationTask?.cancel()
        let currentItem = item
        durationTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            if let dur = try? await asset.load(.duration) {
                guard !Task.isCancelled, self.playerItem === currentItem else { return }
                let secs = CMTimeGetSeconds(dur)
                if secs.isFinite && secs > 0 {
                    self.duration = secs
                }
            }
        }

        setupTimeObserver()
        setupEndObserver()
        setupFailureObservers()
        return true
    }

    /// What keeps the file at `url` from being played, found without
    /// opening it, or nil when it is a regular file that can be read.
    ///
    /// A symbolic link is judged by the item it leads to. A folder, a named
    /// pipe, or any other item that is not a regular file cannot hold a
    /// track, and handing a pipe to AVFoundation could block its loading
    /// forever, so each is reported unreadable at once.
    static func fileProblem(
        at url: URL,
        fileManager: FileManager = .default
    ) -> AudioPlaybackFailure.Reason? {
        // Every check follows symbolic links, so a broken link is missing.
        guard fileManager.fileExists(atPath: url.path) else { return .fileMissing }
        let resourceValues = try? url.resolvingSymlinksInPath()
            .resourceValues(forKeys: [.isRegularFileKey])
        guard resourceValues?.isRegularFile == true,
              fileManager.isReadableFile(atPath: url.path) else {
            return .fileUnreadable
        }
        return nil
    }

    // MARK: - Playback

    /// Play from `fromTime` seconds into the loaded file or, while a clip
    /// chain plays, into the chapter, from whichever clip holds that time.
    ///
    /// - Returns: True when playback started; false when there was nothing
    ///   to play, such as after a load that failed, or when the loaded item
    ///   has already failed, which is reported now. `isPlaying` becomes true
    ///   only when playback starts.
    @discardableResult
    func play(fromTime: TimeInterval = 0) -> Bool {
        if let chained {
            return playClips(chained.chain, fromChapterTime: fromTime)
        }
        return playLoadedFile(from: fromTime)
    }

    /// Play `chain`'s clips one after another as one chapter, from
    /// `chapterTime` seconds into it: the clip holding that time is loaded
    /// and played from the matching time in its file.
    ///
    /// Each clip's end loads the next clip's file, or seeks within the file
    /// when the next clip shares it, and plays on; `onPlaybackFinished` is
    /// called only once the last clip ends. Until `stop()` or `load(url:)`,
    /// every time the service takes or reports is the chapter's time, so it
    /// runs on unbroken across clips. A clip whose file cannot be played is
    /// reported like any file, naming that clip's file, whenever playback
    /// reaches it.
    ///
    /// - Returns: As `play(fromTime:)` returns.
    @discardableResult
    func playClips(_ chain: AudioClipChain, fromChapterTime chapterTime: TimeInterval) -> Bool {
        let location = chain.location(atChapterTime: chapterTime)
        guard loadClip(location.clipIndex, of: chain) else { return false }
        return playLoadedFile(from: location.fileTime)
    }

    /// Play the loaded file from `fileTime` seconds into it.
    ///
    /// - Returns: As `play(fromTime:)` returns.
    @discardableResult
    private func playLoadedFile(from fileTime: TimeInterval) -> Bool {
        guard let player = player, let playerItem else { return false }
        // The item can fail before its status observation reaches the main
        // queue. Report it now rather than claim to play it meanwhile.
        if playerItem.status == .failed {
            reportPlaybackError(playerItem.error)
            return false
        }
        let clampedTime = max(0, duration > 0 ? min(fileTime, duration) : fileTime)
        let cmTime = CMTime(seconds: clampedTime, preferredTimescale: 600)

        // Block clip-end checks until the seek lands, preventing the stale-time
        // race where the time observer sees the old position and re-triggers.
        let seekToken = seekGate.begin()
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.seekGate.complete(seekToken)
        }
        recordPosition(atFileTime: clampedTime)
        player.rate = Float(playbackSpeed)
        isPlaying = true
        isPaused = false
        scheduleProgressCheck()
        return true
    }

    func pause() {
        guard isPlaying, !isPaused else { return }
        player?.pause()
        isPaused = true
        // A paused player is not expected to advance.
        cancelProgressCheck()
    }

    /// Resumes only when a live AVPlayer item still exists and has not
    /// failed. Returning false lets the reader reload the chapter after
    /// route changes, player loss, or a failure still on its way to the
    /// main queue; reloading reports a file that cannot play.
    @discardableResult
    func resume() -> Bool {
        guard isPaused, let player, let item = player.currentItem,
              player.error == nil, item.status != .failed else {
            return false
        }
        player.rate = Float(playbackSpeed)
        isPaused = false
        isPlaying = true
        scheduleProgressCheck()
        return true
    }

    func stop() {
        // A stopped service plays nothing, a chain included.
        chained = nil
        releasePlayer()
        isPlaying = false
        isPaused = false
        currentTime = 0
        duration = 0
        currentVolume = 1.0
    }

    /// Silence and release the player, its item, and everything observing
    /// them. Published playback state is left for the caller to settle.
    private func releasePlayer() {
        durationTask?.cancel()
        durationTask = nil
        cancelProgressCheck()
        removeObservers()
        player?.pause()
        player = nil
        playerItem = nil
        loadedURL = nil
        clipEndTime = nil
        itemBecameReady = false
        seekGate.cancelAll()
    }

    /// Halt playback because of `failure`, then publish it and tell
    /// `onPlaybackFailed`.
    ///
    /// The player is released: AVFoundation never plays a failed item
    /// again, and without a player the next `load(url:)` of the same file
    /// builds a fresh one. `currentTime` and `duration` keep their values,
    /// so playing the file again can start where this attempt stopped.
    private func reportFailure(_ failure: AudioPlaybackFailure) {
        releasePlayer()
        isPlaying = false
        isPaused = false
        self.failure = failure
        onPlaybackFailed?(failure)
    }

    /// Move playback to `time` seconds into the loaded file or, while a clip
    /// chain plays, into the chapter, loading the clip that holds that time
    /// when it is another. Playback stays playing, paused, or stopped, as it
    /// was. With nothing loaded there is nothing to move.
    func seek(to time: TimeInterval) {
        if let chained {
            seek(chained, toChapterTime: time)
            return
        }
        seekLoadedFile(to: time)
    }

    /// Move the loaded file's playback to `fileTime` seconds into it.
    private func seekLoadedFile(to fileTime: TimeInterval) {
        guard let player = player else { return }
        let clampedTime = max(0, duration > 0 ? min(fileTime, duration) : fileTime)
        let cmTime = CMTime(seconds: clampedTime, preferredTimescale: 600)
        let seekToken = seekGate.begin()
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.seekGate.complete(seekToken)
        }
        recordPosition(atFileTime: clampedTime)
        // Playing on from the new position is a fresh start to check.
        if isPlaying && !isPaused {
            scheduleProgressCheck()
        }
    }

    /// Set an optional clip end time for segmented audio playback.
    /// When the current time reaches this value, onPlaybackFinished is fired
    /// instead of continuing to the actual end of the audio file.
    /// Pass nil or 0 to clear the clip boundary.
    func setClipEndTime(_ time: TimeInterval?) {
        clipEndTime = (time ?? 0) > 0 ? time : nil
    }

    /// Set the playback multiplier, live if audio is currently playing.
    /// Reader restoration, time estimates, and the player share
    /// `AudioSpeed.normalized(_:)`, so the player always runs at exactly the
    /// speed the reader shows and saves.
    func setSpeed(_ speed: Double) {
        playbackSpeed = AudioSpeed.normalized(speed)
        if isPlaying && !isPaused {
            player?.rate = Float(playbackSpeed)
        }
    }

    /// Volume control (for sleep timer fade-out).
    /// Tracks the intended volume so it persists across chapter
    /// transitions where a new AVPlayer is created.
    func setVolume(_ volume: Float) {
        currentVolume = max(0.0, min(volume, 1.0))
        player?.volume = currentVolume
    }

    /// Restore volume to full (1.0) after a fade completes.
    func restoreVolume() {
        currentVolume = 1.0
        player?.volume = 1.0
    }

    /// Intended volume and the current player's applied volume. These internal
    /// read-only values let hosted tests verify chapter-load fade persistence.
    var intendedVolume: Float { currentVolume }
    var outputVolume: Float { player?.volume ?? currentVolume }

    /// The item being played, or nil when no player exists. Hosted tests
    /// read its status and post the notifications AVFoundation posts for it.
    var _playerItemForTesting: AVPlayerItem? { playerItem }

    /// Pause the player without the service knowing, exactly as AVFoundation
    /// pauses it when a stall empties its buffer. Hosted tests use it to
    /// stall playback of a local file, which never stalls by itself.
    func _pausePlayerForTesting() {
        player?.pause()
    }

    // MARK: - Clip Chains

    /// Make clip `index` of `chain` the one playing: load its file, keeping
    /// the player when that file is loaded already, and end the clip at its
    /// own end.
    ///
    /// - Returns: False when the clip's file failed its check, which
    ///   `load(url:)` has reported, naming that file, after halting
    ///   playback.
    private func loadClip(_ index: Int, of chain: AudioClipChain) -> Bool {
        let clip = chain.clips[index]
        guard load(url: clip.url) else { return false }
        chained = ChainedPlayback(chain: chain, clipIndex: index)
        clipEndTime = clip.end
        return true
    }

    /// Move a chain's playback to `chapterTime` seconds into the chapter.
    private func seek(_ chained: ChainedPlayback, toChapterTime chapterTime: TimeInterval) {
        let location = chained.chain.location(atChapterTime: chapterTime)
        guard location.clipIndex != chained.clipIndex else {
            seekLoadedFile(to: location.fileTime)
            return
        }
        // After a failure released the player there is nothing to move, as
        // for a file played on its own; playing again starts afresh.
        guard player != nil else { return }
        moveToClip(location.clipIndex, of: chained.chain, atFileTime: location.fileTime)
    }

    /// Load clip `index` of `chain` and put playback at `fileTime` seconds
    /// into its file. Playback that was playing plays on from there; paused
    /// or stopped playback stays paused or stopped.
    private func moveToClip(_ index: Int, of chain: AudioClipChain, atFileTime fileTime: TimeInterval) {
        let wasPlaying = isPlaying
        let wasPaused = isPaused
        // Loading another file resets the playing state; it is put back
        // below. A file that fails its check has been reported already.
        guard loadClip(index, of: chain) else { return }
        if wasPlaying && !wasPaused {
            playLoadedFile(from: fileTime)
        } else {
            seekLoadedFile(to: fileTime)
            isPlaying = wasPlaying
            isPaused = wasPaused
        }
    }

    /// Carry a chain on with the clip after the one that has just played
    /// to its end.
    ///
    /// - Returns: True when a next clip took over, playing or, if its file
    ///   cannot be played, reported as failed; false when nothing chains
    ///   on, because no chain plays or its last clip ended, which ends the
    ///   chapter.
    private func advanceToNextClip() -> Bool {
        guard let chained, chained.clipIndex + 1 < chained.chain.clips.count else { return false }
        let next = chained.clipIndex + 1
        // The chapter's time stands at the next clip's start, however far
        // the player ran past the ended clip's end. Reporting it before the
        // clip loads leaves the listener's place exactly where that clip
        // begins even when its file then fails to load.
        currentTime = chained.chain.startTimes[next]
        onPositionUpdate?(currentTime)
        moveToClip(next, of: chained.chain, atFileTime: chained.chain.clips[next].start)
        return true
    }

    /// Record `fileTime`, a time in the loaded file, as `currentTime`,
    /// measured as the service reports times: within the chapter while a
    /// clip chain plays, within the file otherwise.
    private func recordPosition(atFileTime fileTime: TimeInterval) {
        if let chained {
            currentTime = chained.chain.chapterTime(clipIndex: chained.clipIndex, fileTime: fileTime)
        } else {
            currentTime = fileTime
        }
    }

    // MARK: - Chapter/Marker Extraction

    /// Extract chapter markers from an audio file (M4B, M4A with chapters).
    /// Returns array of (title, startTime, duration), in the file's order.
    /// Everything is read through AVFoundation's asynchronous loading API
    /// (TODO Q06): a marker whose title cannot be read is named "Chapter",
    /// and a file whose markers cannot be loaded has none.
    static func extractChapters(from url: URL) async -> [(title: String, startTime: TimeInterval, duration: TimeInterval)] {
        let asset = AVURLAsset(url: url)
        do {
            let locales = try await asset.load(.availableChapterLocales)
            let preferredLanguages = locales.isEmpty ? ["en"] : locales.map { $0.identifier }
            let groups = try await asset.loadChapterMetadataGroups(bestMatchingPreferredLanguages: preferredLanguages)

            var chapters: [(title: String, startTime: TimeInterval, duration: TimeInterval)] = []
            for group in groups {
                let titleItems = AVMetadataItem.metadataItems(from: group.items,
                                                              filteredByIdentifier: .commonIdentifierTitle)
                // A title that fails to load counts as missing, as the
                // synchronous stringValue this replaces returned nil.
                let title = (try? await titleItems.first?.load(.stringValue)) ?? "Chapter"
                let start = CMTimeGetSeconds(group.timeRange.start)
                let dur = CMTimeGetSeconds(group.timeRange.duration)
                chapters.append((title: title, startTime: start.isFinite ? start : 0, duration: dur.isFinite ? dur : 0))
            }
            return chapters
        } catch {
            return []
        }
    }

    /// Extract basic metadata (title, artist) from an audio file.
    /// Used by AudioBookParser for quick title/artist extraction during import.
    static func extractMetadata(from url: URL) async -> (title: String?, artist: String?) {
        let full = await extractFullMetadata(from: url)
        return (title: full.title.isEmpty ? nil : full.title,
                artist: full.artist.isEmpty ? nil : full.artist)
    }

    /// Extract comprehensive metadata from an audio file including album, genre, year, and duration.
    /// Returns an AudioMetadata struct with all available fields populated.
    static func extractFullMetadata(from url: URL) async -> AudioMetadata {
        let asset = AVURLAsset(url: url)
        var result = AudioMetadata()

        // Set the file format from the extension
        result.fileFormat = url.pathExtension.uppercased()

        do {
            let metadata = try await asset.load(.commonMetadata)

            // Extract each field from common metadata identifiers
            let titleItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle)
            result.title = (try? await titleItems.first?.load(.stringValue)) ?? ""

            let artistItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtist)
            result.artist = (try? await artistItems.first?.load(.stringValue)) ?? ""

            let albumItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierAlbumName)
            result.album = (try? await albumItems.first?.load(.stringValue)) ?? ""

            let creatorItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierCreator)
            // Use creator as artist fallback if artist is empty
            if result.artist.isEmpty {
                result.artist = (try? await creatorItems.first?.load(.stringValue)) ?? ""
            }

            let typeItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierType)
            result.genre = (try? await typeItems.first?.load(.stringValue)) ?? ""

            let dateItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierCreationDate)
            result.year = (try? await dateItems.first?.load(.stringValue)) ?? ""
        } catch {
            // Metadata extraction failed; fields stay empty
        }

        // Extract duration separately (always available even if metadata tags are missing)
        do {
            let dur = try await asset.load(.duration)
            let secs = CMTimeGetSeconds(dur)
            if secs.isFinite && secs > 0 {
                let hours = Int(secs) / 3600
                let minutes = (Int(secs) % 3600) / 60
                let seconds = Int(secs) % 60
                if hours > 0 {
                    result.duration = String(format: "%d:%02d:%02d", hours, minutes, seconds)
                } else {
                    result.duration = String(format: "%d:%02d", minutes, seconds)
                }
            }
        } catch {
            // Duration not available
        }

        return result
    }

    /// Get duration of an audio file without playing it.
    static func getDuration(of url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        do {
            let dur = try await asset.load(.duration)
            let secs = CMTimeGetSeconds(dur)
            return secs.isFinite && secs > 0 ? secs : nil
        } catch {
            return nil
        }
    }

    // MARK: - Observers

    private func setupTimeObserver() {
        guard let player = player else { return }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            let secs = CMTimeGetSeconds(time)

            switch AudioPositionObserverPolicy.action(
                seconds: secs,
                isSeeking: self.seekGate.isSeeking,
                clipEndTime: self.clipEndTime
            ) {
            case .ignore:
                // While a seek is in progress, the player may report stale
                // pre-seek positions. Suppress every observer side effect,
                // including clip completion, until the latest seek lands.
                return
            case .finishClip:
                // A clip chain plays on with its next clip; only the end of
                // its last clip, or of a lone clip, finishes playback.
                if self.advanceToNextClip() { return }
                self.finishPlayback()
                return
            case .publish(let seconds):
                self.recordPosition(atFileTime: seconds)
                self.onPositionUpdate?(self.currentTime)
            }
        }
    }

    private func setupEndObserver() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] notification in
            // Removing the observer stops new deliveries, but one already
            // queued for an item that `load(url:)` has since replaced must
            // not finish the new item and advance past it.
            guard let self, let item = self.playerItem,
                  notification.object as AnyObject? === item else { return }
            if self.chained != nil {
                // Moving on to a clip later in the same file keeps the item
                // and seeks it away from its end, so an end that arrives
                // while that seek is under way is stale. A real end comes
                // only once playback has run on to it.
                guard !self.seekGate.isSeeking else { return }
                // A clip chain plays on with its next clip; only the end of
                // its last clip finishes playback.
                if self.advanceToNextClip() { return }
            }
            self.finishPlayback()
        }
    }

    /// End playback because what it was asked to play has played to its
    /// end: the loaded file, the clip it was to stop at, or a chain's last
    /// clip. A clip that ends where its file does is reported twice, by the
    /// clip-end check and by AVFoundation's end-of-file notice, one after
    /// the other; only the first is acted on, since playback that no longer
    /// plays has nothing left to finish. `onPlaybackFinished` is therefore
    /// called once each time playback is started and runs to its end.
    private func finishPlayback() {
        guard isPlaying else { return }
        player?.pause()
        isPlaying = false
        isPaused = false
        clipEndTime = nil
        onPlaybackFinished?()
    }

    /// Observe each way AVFoundation reports that the current file cannot
    /// be played: the item's status, the player's status, the item failing
    /// to play to its end, and the item stalling.
    ///
    /// Every observation is acted on from the main queue, like the other
    /// observers, and only while its item or player is still the current
    /// one: an observation that arrives after `load(url:)` replaced them is
    /// ignored, as the duration task ignores a replaced item.
    private func setupFailureObservers() {
        guard let player, let item = playerItem else { return }
        // Key-value observation can call back on any thread. `.initial`
        // also delivers a status the item or player already has.
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                self?.itemStatusDidChange(item)
            }
        }
        playerStatusObservation = player.observe(\.status, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async { [weak self] in
                self?.playerStatusDidChange(player)
            }
        }
        failedToPlayToEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self?.itemDidFailToPlayToEnd(notification.object as AnyObject?, error: error)
        }
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] notification in
            self?.playbackDidStall(notification.object as AnyObject?)
        }
    }

    /// Record that the current item became ready, or report that it failed.
    private func itemStatusDidChange(_ item: AVPlayerItem) {
        guard item === playerItem else { return }
        switch item.status {
        case .readyToPlay:
            itemBecameReady = true
        case .failed:
            reportPlaybackError(item.error)
        default:
            break
        }
    }

    /// Report the current player failing. AVFoundation never plays with a
    /// failed player again.
    private func playerStatusDidChange(_ changedPlayer: AVPlayer) {
        guard changedPlayer === player, changedPlayer.status == .failed else { return }
        reportPlaybackError(changedPlayer.error)
    }

    /// Report the current item stopping short of its end because of `error`.
    private func itemDidFailToPlayToEnd(_ object: AnyObject?, error: Error?) {
        guard let item = playerItem, object === item else { return }
        reportPlaybackError(error ?? item.error)
    }

    /// Report an error AVFoundation raised for the loaded file, with the
    /// reason `AudioPlaybackFailure.reasonForPlaybackError` gives it.
    private func reportPlaybackError(_ error: Error?) {
        guard let url = loadedURL else { return }
        let reason = AudioPlaybackFailure.reasonForPlaybackError(
            fileProblem: Self.fileProblem(at: url),
            itemBecameReady: itemBecameReady
        )
        reportFailure(AudioPlaybackFailure(reason: reason, url: url, underlyingError: error))
    }

    // MARK: - Stalls

    /// Try to recover from a stall of the current item: audio that did not
    /// arrive in time to keep playing.
    ///
    /// With automatic waiting off, for immediate starts, a stall leaves the
    /// player paused, and it never restarts by itself. Turning waiting on
    /// and asking for the rate again lets AVFoundation resume as soon as
    /// enough audio has arrived. A stall while paused needs nothing: resume
    /// asks for the rate and checks progress itself.
    private func playbackDidStall(_ object: AnyObject?) {
        guard let player, let item = playerItem, object === item,
              isPlaying, !isPaused else { return }
        player.automaticallyWaitsToMinimizeStalling = true
        player.rate = Float(playbackSpeed)
        scheduleProgressCheck()
    }

    /// Check, `stallRecoveryTimeout` from now, that playback of the current
    /// item is really advancing, replacing any check already pending.
    ///
    /// Asking to start, resume, or seek sets `isPlaying` at once, whether or
    /// not audio ever arrives, and a stall pauses the player without telling
    /// the service. Without this check either would leave the service
    /// claiming to play in silence.
    private func scheduleProgressCheck() {
        cancelProgressCheck()
        guard let item = playerItem else { return }
        let check = DispatchWorkItem { [weak self] in
            self?.checkProgress(of: item)
        }
        progressCheck = check
        DispatchQueue.main.asyncAfter(deadline: .now() + stallRecoveryTimeout, execute: check)
    }

    /// Drop the pending progress check, if any.
    private func cancelProgressCheck() {
        progressCheck?.cancel()
        progressCheck = nil
    }

    /// Report a stall when `item`, still the current item and meant to be
    /// playing, is not advancing.
    private func checkProgress(of item: AVPlayerItem) {
        guard item === playerItem, let player, let url = loadedURL else { return }
        // Only the newest check runs; scheduling another cancelled this one.
        progressCheck = nil
        let reachedEndOfFile = item.duration.isNumeric
            && CMTimeCompare(item.currentTime(), item.duration) >= 0
        guard AudioStallPolicy.isStalled(
            isPlaying: isPlaying,
            isPaused: isPaused,
            playerIsAdvancing: player.timeControlStatus == .playing,
            reachedEndOfFile: reachedEndOfFile
        ) else { return }
        reportFailure(AudioPlaybackFailure(reason: .stalled, url: url))
    }

    private func removeObservers() {
        if let observer = timeObserver, let player = player {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        for observer in [endObserver, failedToPlayToEndObserver, stallObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        endObserver = nil
        failedToPlayToEndObserver = nil
        stallObserver = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        playerStatusObservation?.invalidate()
        playerStatusObservation = nil
    }
}
