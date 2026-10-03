import AVFoundation
import Combine

/// Latest-wins gate for asynchronous AVPlayer seeks. AVPlayer may complete
/// overlapping seeks out of order; a plain Boolean lets an older completion
/// re-enable position observers while a newer seek is still pending.
///
/// `@unchecked Sendable`: its counters are read and changed only under
/// `lock`, since a seek completes on a thread AVFoundation chooses.
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

/// Counts the plays of an audio service's loaded file, so a notice
/// AVFoundation posted during one play is never taken for the end of
/// another. Each load, play from a time, seek, stop, and finish begins a
/// new play.
///
/// AVFoundation may post its notices on any thread, where the count is
/// read as each is posted, so the count is guarded by a lock.
final class AudioPlaybackGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// The generation of the play under way.
    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    /// Begin a new play. Anything posted before now belongs to an earlier
    /// one.
    func advance() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }
}

/// What the audio service made of one notice from AVFoundation that its
/// loaded file played to its end.
enum AudioEndNoticeOutcome: Equatable, Sendable {
    /// The notice ended the play under way: a clip chain moved on to its
    /// next clip, or playback finished.
    case endedPlay
    /// The notice ends the play under way, which was paused when it came.
    /// It is held until playback resumes, which finishes the play, so the
    /// listener's pause is never overridden by moving on.
    case heldUntilResume
    /// The notice was posted during an earlier play, before a load, a play
    /// from a time, a seek, a stop, or a finish began the one under way. It
    /// was ignored.
    case postedDuringEarlierPlay
    /// Nothing was playing when the notice was acted on, as when playback
    /// finished at its clip's end just before the file's own end was
    /// reported. It was ignored.
    case nothingPlaying
    /// The notice was the late end of an earlier playthrough of the same
    /// file, which AVFoundation posted as the play under way began. It was
    /// ignored, and that play was started again on a new player.
    case lateForEarlierPlaythrough
}

/// Decides what AVFoundation's notice that the loaded file played to its
/// end means for the play under way.
///
/// AVFoundation posts the notice a little after the playhead reaches the
/// file's end (about 35 milliseconds, in hosted tests), so the play it ends
/// may have given way to another by the time it is acted on. And when a
/// play that ended at the file's end, at its clip's end, gives way to a new
/// play of the same item, as a loop or a clip earlier in the same file
/// does, AVFoundation still posts the end of that earlier playthrough: just
/// as the new play's seek lands, with the playhead still exactly where
/// that seek put it, leaving the player stopped there.
enum AudioEndNoticePolicy {
    /// How near, in seconds, the playhead must stand to where the play
    /// under way began for a notice to count as the late end of an earlier
    /// playthrough: a seek's landing rounded to its sample, with room to
    /// spare. No play that has really reached the end is so short, unless
    /// it began at the end.
    static let playStartTolerance: TimeInterval = 0.01

    /// What a notice means for the play under way.
    ///
    /// - Parameters:
    ///   - postedGeneration: The play generation when AVFoundation posted
    ///     the notice.
    ///   - currentGeneration: The generation of the play under way.
    ///   - isPlaying: Whether the service is playing, paused or not.
    ///   - isPaused: Whether that playback is paused.
    ///   - playhead: Where the item's playhead stood when the notice was
    ///     posted, in seconds into the file, or nil when it is unknown.
    ///   - playStart: Where the play under way began, in seconds into the
    ///     file.
    ///   - fileDuration: How long the file lasts, in seconds, or nil while
    ///     unknown.
    ///   - restartedFrom: The play start from which the play under way was
    ///     started again on a new player, after an earlier late notice, or
    ///     nil when it was not.
    static func outcome(
        postedGeneration: Int,
        currentGeneration: Int,
        isPlaying: Bool,
        isPaused: Bool,
        playhead: TimeInterval?,
        playStart: TimeInterval,
        fileDuration: TimeInterval?,
        restartedFrom: TimeInterval?
    ) -> AudioEndNoticeOutcome {
        guard postedGeneration == currentGeneration else { return .postedDuringEarlierPlay }
        guard isPlaying else { return .nothingPlaying }
        if isLateForEarlierPlaythrough(
            playhead: playhead,
            playStart: playStart,
            fileDuration: fileDuration,
            restartedFrom: restartedFrom
        ) {
            return .lateForEarlierPlaythrough
        }
        return isPaused ? .heldUntilResume : .endedPlay
    }

    /// Whether a notice posted with the playhead at `playhead` is the late
    /// end of an earlier playthrough: the playhead stands where the play
    /// under way began, short of the file's end, on a player that has not
    /// already been started again for that play.
    ///
    /// A playhead at or past the file's end has played to it, however its
    /// play began. A player started again after a late notice holds a new
    /// item, which has no earlier playthrough to report, so another notice
    /// with the playhead still at the start is a real end there, as at the
    /// true end of a file whose length was overestimated.
    static func isLateForEarlierPlaythrough(
        playhead: TimeInterval?,
        playStart: TimeInterval,
        fileDuration: TimeInterval?,
        restartedFrom: TimeInterval?
    ) -> Bool {
        guard let playhead, playhead.isFinite else { return false }
        if let fileDuration, playhead >= fileDuration { return false }
        if let restartedFrom, abs(restartedFrom - playStart) <= playStartTolerance { return false }
        return abs(playhead - playStart) <= playStartTolerance
    }
}

/// What the audio service does with one tick of its position observer.
enum AudioPositionObserverPolicy {
    enum Action: Equatable, Sendable {
        /// Nothing: the position cannot be trusted, or belongs to no clip.
        case ignore
        /// The clip being played has reached its end.
        case finishClip
        /// Report this position, in seconds into the loaded file.
        case publish(TimeInterval)
    }

    /// The action for a tick that finds the player `seconds` into its file.
    ///
    /// - Parameters:
    ///   - seconds: The player's position as the tick is handled.
    ///   - isSeeking: Whether a seek is still on its way. Until it lands,
    ///     the player may report where it was before.
    ///   - isPlaying: Whether playback is playing and not paused. Only such
    ///     playback finishes its clip. Paused or finished playback at or
    ///     past the clip's end reports nothing, since that time belongs to
    ///     whatever follows the clip; paused playback finishes the clip on
    ///     its first tick once resumed.
    ///   - clipEndTime: Where the clip being played ends, in seconds into
    ///     its file, or nil when it plays to the file's end.
    static func action(
        seconds: TimeInterval,
        isSeeking: Bool,
        isPlaying: Bool,
        clipEndTime: TimeInterval?
    ) -> Action {
        guard seconds.isFinite, !isSeeking else { return .ignore }
        if let clipEndTime, seconds >= clipEndTime {
            return isPlaying ? .finishClip : .ignore
        }
        return .publish(seconds)
    }
}

/// One report from AVFoundation about the audio service's player, as the
/// service dealt with it. Hosted tests receive each one through
/// `AudioPlaybackService._reportHandledForTesting`.
enum AudioPlayerReport: Equatable, Sendable {
    /// A tick of the position observer of the player now loaded, finding
    /// the player `seconds` into its file, and what the service did with it.
    case tick(seconds: TimeInterval, action: AudioPositionObserverPolicy.Action)
    /// A tick of the position observer of a player since released, which
    /// the service turned away.
    case tickFromReleasedPlayer
    /// A notice that the loaded file played to its end, and what the
    /// service made of it.
    case endOfFile(AudioEndNoticeOutcome)
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
///
/// What plays ends once: `onPlaybackFinished` is called once each time
/// playback runs to the end of its file, clip, or chain, however many ways
/// AVFoundation reports that end, and never for a play that a load, a play
/// from a time, a seek, or a stop has since replaced (see
/// `AudioEndNoticePolicy`). An end that comes while playback is paused is
/// held until it resumes.
///
/// Starting any player costs about a quarter of a second of silence before
/// its clock moves, a new one or a stopped one alike. A file named to follow
/// the loaded one (`setFileAfterCurrent(_:)`) is queued behind it, so the
/// player rolls straight on into it with no gap (TODO PERF09).
///
/// `@unchecked Sendable`: everything it holds is read and changed on the
/// main thread. Its owner, the reader, is main-actor isolated, and every
/// AVFoundation callback it installs runs on the main queue or hops there;
/// the two that run where AVFoundation calls them, the end-of-file notice
/// and a seek's completion, touch only the lock-guarded `playGeneration`
/// and `seekGate`.
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

    /// Called on the main queue once each time playback runs to the end of
    /// what it was asked to play, never while it is paused.
    var onPlaybackFinished: (() -> Void)?
    var onPositionUpdate: ((TimeInterval) -> Void)?
    /// Called on the main queue once for each failure, after `failure` is
    /// set and playback has halted. A file that fails never also reports
    /// `onPlaybackFinished`.
    var onPlaybackFailed: ((AudioPlaybackFailure) -> Void)?

    /// The player, which holds the loaded file's item and, behind it, the
    /// item of any file named to follow.
    private var player: AVQueuePlayer?
    /// The loaded file's item.
    private var playerItem: AVPlayerItem?
    /// The file named to follow the loaded one, with its item, queued behind
    /// the loaded file's item, and the asset that item plays; or nil
    /// (`setFileAfterCurrent(_:)`).
    private var followingFile: (url: URL, item: AVPlayerItem, asset: AVURLAsset)?
    /// Watches the following file's item, which is dropped from the queue
    /// should it fail before playback reaches it.
    private var followingItemStatusObservation: NSKeyValueObservation?
    /// Whether the loaded file began playing by rolling straight on from the
    /// file before it, and has not been moved since: playing it from its
    /// start then plays on rather than setting it back.
    private var rolledOnIntoLoadedFile = false
    /// Watches the player arrive at the loaded file it is rolling on into,
    /// to have it stop at that file's end in turn (`stopAtLoadedFileEnd()`).
    private var arrivalObservation: NSKeyValueObservation?
    private var timeObserver: Any?
    /// Counts the position observers installed, one for each player. Each
    /// observer's ticks carry the count it was installed with, so a tick of
    /// an observer installed for an earlier player can never act on the
    /// current one.
    private var timeObserverGeneration = 0
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

    /// The generation of the play under way. Each end-of-file notice
    /// carries the generation it was posted in, and only a notice posted in
    /// the play under way can end it.
    private let playGeneration = AudioPlaybackGeneration()

    /// Where the play under way began, in seconds into the loaded file: the
    /// time the latest play or seek put the playhead at. The late end of an
    /// earlier playthrough arrives with the playhead still exactly there.
    private var playStartFileTime: TimeInterval = 0

    /// The play start from which the play under way was started again on a
    /// new player, after AVFoundation posted the late end of an earlier
    /// playthrough as it began; nil when it was not.
    private var restartedAfterLateEndFrom: TimeInterval?

    /// The generation of a play whose end AVFoundation reported while it
    /// was paused, or nil. Resuming finishes that play, unless a seek, a
    /// load, or a stop has begun another since.
    private var endHeldUntilResume: Int?

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
        loadFile(url, reusingLivePlayer: true)
    }

    /// Load `url` as `load(url:)` describes. A live player that already
    /// holds the file is kept when `reusingLivePlayer` is true, as for the
    /// next chapter or clip of the same file, and replaced by a new player
    /// otherwise.
    ///
    /// Either way the loaded file begins a new play: nothing AVFoundation
    /// posted before can end what plays next. A file named to follow the one
    /// loaded before is forgotten; it is named again for each play.
    private func loadFile(_ url: URL, reusingLivePlayer: Bool) -> Bool {
        // A player moving on into a named file is leaving the loaded file,
        // so it is never kept to go on playing it.
        let isMovingOn = isMovingOnToFollowingFile
        dropFollowingFile()
        chained = nil
        let normalizedURL = url.standardizedFileURL
        // A failure releases its player, so a live player for this URL has
        // not failed and can keep playing the file.
        if reusingLivePlayer, !isMovingOn, let loadedURL, loadedURL == normalizedURL, player != nil {
            clipEndTime = nil
            playGeneration.advance()
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

        let (item, asset) = Self.makeItem(playing: normalizedURL)
        let avPlayer = AVQueuePlayer(items: [item])
        // Like a plain player, stop at the end of the loaded file, unless a
        // file named to follow it is queued (`setFileAfterCurrent(_:)`).
        avPlayer.actionAtItemEnd = .pause
        avPlayer.automaticallyWaitsToMinimizeStalling = false
        // Re-apply tracked volume to the new player. AVPlayer defaults
        // to 1.0, which discards any in-progress sleep timer fade.
        avPlayer.volume = currentVolume

        self.playerItem = item
        self.player = avPlayer
        self.loadedURL = normalizedURL

        loadDuration(of: item, asset: asset)
        setupTimeObserver()
        setupItemObservers()
        setupPlayerStatusObserver()
        return true
    }

    /// An item playing the file at `url`, stretched in time for speech, and
    /// the asset it plays, kept to learn the file's length from (an item's
    /// own `asset` may be read only on the main actor).
    private static func makeItem(playing url: URL) -> (item: AVPlayerItem, asset: AVURLAsset) {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain // Best for speech
        return (item, asset)
    }

    /// Learn how long `asset`, which the loaded file's `item` plays, lasts,
    /// and publish it as `duration` once known, cancelling any earlier load
    /// so that it cannot overwrite this one.
    private func loadDuration(of item: AVPlayerItem, asset: AVURLAsset) {
        durationTask?.cancel()
        durationTask = Task { @MainActor in
            guard !Task.isCancelled else { return }
            if let dur = try? await asset.load(.duration) {
                guard !Task.isCancelled, self.playerItem === item else { return }
                let secs = CMTimeGetSeconds(dur)
                if secs.isFinite && secs > 0 {
                    self.duration = secs
                }
            }
        }
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
        // A file playback rolled straight on into is already playing from
        // its start, or about to: asked to play from there, it plays on,
        // rather than be set back by a seek. Anything else is a fresh start.
        let playsOn = rolledOnIntoLoadedFile && fileTime <= 0
        rolledOnIntoLoadedFile = false
        if !playsOn {
            restartLoadedFileIfOutOfStep()
        }
        guard let player = player, let playerItem else { return false }
        // The item can fail before its status observation reaches the main
        // queue. Report it now rather than claim to play it meanwhile.
        if playerItem.status == .failed {
            reportPlaybackError(playerItem.error)
            return false
        }
        if !playsOn {
            seekPlayer(toFileTime: fileTime)
        }
        player.rate = Float(playbackSpeed)
        isPlaying = true
        isPaused = false
        scheduleProgressCheck()
        return true
    }

    /// Move the loaded player to `fileTime` seconds into its file, held
    /// within the file once its length is known, as a new play: notices
    /// AVFoundation posted before now belong to an earlier one.
    ///
    /// Clip-end checks wait until the seek lands, so the position observer
    /// never acts on a position from before it.
    private func seekPlayer(toFileTime fileTime: TimeInterval) {
        guard let player else { return }
        let clampedTime = max(0, duration > 0 ? min(fileTime, duration) : fileTime)
        playGeneration.advance()
        playStartFileTime = clampedTime
        restartedAfterLateEndFrom = nil
        endHeldUntilResume = nil
        let seekToken = seekGate.begin()
        player.seek(
            to: CMTime(seconds: clampedTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            self?.seekGate.complete(seekToken)
        }
        recordPosition(atFileTime: clampedTime)
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
    ///
    /// Playback paused at the end of its file finishes instead, once this
    /// call has returned, so the caller sees it resume before it ends: its
    /// end came while it was paused and was held, or it was paused there
    /// first. AVFoundation reports no end again for a player asked to play
    /// on from its end, which then stays where it is.
    @discardableResult
    func resume() -> Bool {
        guard isPaused, let player, let item = player.currentItem,
              player.error == nil, item.status != .failed else {
            return false
        }
        isPaused = false
        isPlaying = true
        let generation = playGeneration.current
        // A seek still on its way decides where playback stands; AVFoundation
        // reports the end itself when it lands there and plays on.
        let pausedAtTheEnd = !seekGate.isSeeking && Self.isAtEndOfFile(item)
        if endHeldUntilResume == generation || pausedAtTheEnd {
            endHeldUntilResume = nil
            DispatchQueue.main.async { [weak self] in
                self?.finishResumedPlayAtItsEnd(generation: generation)
            }
            return true
        }
        player.rate = Float(playbackSpeed)
        scheduleProgressCheck()
        return true
    }

    /// Finish the play of `generation`, resumed at its end, unless that
    /// play has given way to another since: a seek, a load, or a stop began
    /// one. A pause made in the meantime holds the end until the next
    /// resume.
    private func finishResumedPlayAtItsEnd(generation: Int) {
        guard generation == playGeneration.current, isPlaying else {
            DiagnosticLog.trace(.playback, "audio play resumed at its end gave way to another before it finished")
            return
        }
        guard !isPaused else {
            endHeldUntilResume = generation
            return
        }
        reachedEnd()
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
        // The queue goes with the player; only the bookkeeping is left.
        followingItemStatusObservation?.invalidate()
        followingItemStatusObservation = nil
        arrivalObservation?.invalidate()
        arrivalObservation = nil
        followingFile = nil
        rolledOnIntoLoadedFile = false
        player = nil
        playerItem = nil
        loadedURL = nil
        clipEndTime = nil
        itemBecameReady = false
        seekGate.cancelAll()
        // Whatever the released player was playing is over: a notice it
        // posted that is still on its way to the main queue ends nothing.
        playGeneration.advance()
        restartedAfterLateEndFrom = nil
        endHeldUntilResume = nil
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
        rolledOnIntoLoadedFile = false
        restartLoadedFileIfOutOfStep()
        guard let player = player else { return }
        seekPlayer(toFileTime: fileTime)
        if isPlaying && !isPaused {
            // AVFoundation stops a player that reaches the end of its file,
            // and a seek away from the end does not start it again, so
            // playback that should be playing asks for its rate again; the
            // end that stopped it was posted before this seek and ends
            // nothing now. Playing on from the new position is a fresh start
            // to check.
            player.rate = Float(playbackSpeed)
            scheduleProgressCheck()
        }
    }

    /// Set an optional clip end time for segmented audio playback.
    /// When the current time reaches this value, onPlaybackFinished is fired
    /// instead of continuing to the actual end of the audio file.
    /// Pass nil or 0 to clear the clip boundary. A clip end forgets any file
    /// named to follow, since the play no longer ends where the file does.
    func setClipEndTime(_ time: TimeInterval?) {
        clipEndTime = (time ?? 0) > 0 ? time : nil
        if clipEndTime != nil {
            dropFollowingFile()
        }
    }

    // MARK: - The File That Follows

    /// Name the file that plays after the loaded one, from its start, so
    /// that when the loaded file plays to its end the player rolls straight
    /// on into it, sparing the quarter of a second of silence that starting
    /// a player costs (TODO PERF09). Nil names none, and playback stops at
    /// the file's end as it always has.
    ///
    /// When the loaded file ends, `onPlaybackFinished` is called as at any
    /// end, with the named file already the loaded one and playing, or about
    /// to; loading it then and playing it from its start plays on, with no
    /// seek and no new player. A stop, a pause, or another load instead
    /// stops it or replaces it as usual.
    ///
    /// The file is queued only while the loaded file plays on its own to its
    /// own end: not during a clip chain or with a clip end set, which end the
    /// play elsewhere, and not when it cannot be read. Loading any file, a
    /// clip end, a stop, or a failure forgets it. Once the loaded file has
    /// played to its end and the player is moving on into the named file, a
    /// new name changes nothing: the end about to be acted on carries
    /// playback into the file already named.
    ///
    /// Name a file only when it certainly plays next: never when playback
    /// should stop at the loaded file's end, as at a book's last chapter or
    /// with a sleep timer that stops at the end of a chapter, and never a
    /// file that is only in the cloud, which would stall.
    func setFileAfterCurrent(_ url: URL?) {
        guard !isMovingOnToFollowingFile else { return }
        dropFollowingFile()
        guard let url, let player, let playerItem, chained == nil, clipEndTime == nil else { return }
        let normalizedURL = url.standardizedFileURL
        // A file that cannot be played is left for its own load to report.
        guard Self.fileProblem(at: normalizedURL) == nil else {
            DiagnosticLog.trace(.playback, "audio: the file named to follow cannot be read; none is queued")
            return
        }
        let (item, asset) = Self.makeItem(playing: normalizedURL)
        guard player.canInsert(item, after: playerItem) else { return }
        player.insert(item, after: playerItem)
        player.actionAtItemEnd = .advance
        followingFile = (normalizedURL, item, asset)
        // Key-value observation can call back on any thread.
        followingItemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                self?.followingItemStatusDidChange(item)
            }
        }
    }

    /// Drop the following file's item from the queue when it fails before
    /// playback reaches it, so the loaded file stops at its end as though
    /// none were named, and the file's own load reports the failure.
    private func followingItemStatusDidChange(_ item: AVPlayerItem) {
        guard item === followingFile?.item, item.status == .failed, !isMovingOnToFollowingFile else { return }
        DiagnosticLog.trace(.playback, "audio: the file named to follow failed before it was reached; dropped it")
        dropFollowingFile()
    }

    /// Whether the player is moving on into the file named to follow: the
    /// loaded file has played to its end, or the player has already left it
    /// for the named file, and that end has yet to be acted on. The player
    /// moves on, and shows it in `currentItem`, on its own schedule, so until
    /// the end is acted on (`finishPlayback()`) its queue is left alone.
    private var isMovingOnToFollowingFile: Bool {
        guard let following = followingFile, let player, let playerItem else { return false }
        return player.currentItem === following.item || Self.isAtEndOfFile(playerItem)
    }

    /// Whether the player's queue is out of step with the loaded file: it is
    /// moving on into a file named to follow, or it has yet to arrive at the
    /// loaded file, a file it was rolling on into.
    private var isQueueOutOfStep: Bool {
        guard let player, let playerItem else { return false }
        return player.currentItem !== playerItem || isMovingOnToFollowingFile
    }

    /// Forget the file named to follow. Before the loaded file's end, its
    /// item is taken off the queue, and the player again stops at the loaded
    /// file's end. Once the player is moving on into it, the queue is left
    /// alone, and the caller releases the player or starts the loaded file
    /// again on a new one (`restartLoadedFileIfOutOfStep()`).
    private func dropFollowingFile() {
        guard let following = followingFile else { return }
        let isMovingOn = isMovingOnToFollowingFile
        followingItemStatusObservation?.invalidate()
        followingItemStatusObservation = nil
        followingFile = nil
        guard !isMovingOn, let player else { return }
        player.remove(following.item)
        // A player still to arrive at the loaded file it is rolling on into
        // is stopped at that file's end once it gets there, not before, lest
        // it stop at the end of the file it is leaving.
        if player.currentItem === playerItem {
            player.actionAtItemEnd = .pause
        }
    }

    /// Start the loaded file again on a new player when the player's queue
    /// is out of step with it, as a seek or a play in the loaded file must
    /// act on that file, which a queue moving on cannot be trusted to.
    /// Playback keeps its state, playing or paused; the caller then moves it
    /// where it wants. Any file named to follow is forgotten.
    private func restartLoadedFileIfOutOfStep() {
        guard isQueueOutOfStep, let url = loadedURL else { return }
        DiagnosticLog.trace(.playback, "audio: the player was moving between files; starting the loaded file again on a new player")
        let wasPlaying = isPlaying
        let wasPaused = isPaused
        // A file that fails its check now is reported as any load reports it.
        guard loadFile(url, reusingLivePlayer: false) else { return }
        isPlaying = wasPlaying
        isPaused = wasPaused
    }

    /// Make the file named to follow the loaded file, as the loaded file's
    /// play has finished with that file still queued behind it, so the player
    /// is moving on into it or about to: a play of it from its start, which
    /// plays on, observed as any loaded file is.
    ///
    /// - Returns: False when no such file is queued.
    private func adoptFollowingFile() -> Bool {
        guard let player, let following = followingFile,
              player.items().contains(where: { $0 === following.item }) else { return false }
        followingItemStatusObservation?.invalidate()
        followingItemStatusObservation = nil
        followingFile = nil
        removeItemObservers()
        playerItem = following.item
        loadedURL = following.url
        itemBecameReady = following.item.status == .readyToPlay
        clipEndTime = nil
        playStartFileTime = 0
        restartedAfterLateEndFrom = nil
        endHeldUntilResume = nil
        rolledOnIntoLoadedFile = true
        currentTime = 0
        duration = 0
        loadDuration(of: following.item, asset: following.asset)
        setupItemObservers()
        stopAtLoadedFileEnd()
        return true
    }

    /// Have the player stop at the loaded file's end, rather than move on
    /// past it, once it plays that file and nothing is named to follow it: at
    /// once when it already plays it, otherwise as soon as it arrives there.
    /// Changing what the player does at an item's end before it has moved on
    /// could stop it at the end of the file it is leaving.
    private func stopAtLoadedFileEnd() {
        arrivalObservation?.invalidate()
        arrivalObservation = nil
        guard let player else { return }
        guard player.currentItem !== playerItem else {
            if followingFile == nil {
                player.actionAtItemEnd = .pause
            }
            return
        }
        // Key-value observation can call back on any thread. `.initial`
        // also reports an arrival made since the check above.
        arrivalObservation = player.observe(\.currentItem, options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, let player = self.player, player.currentItem === self.playerItem else { return }
                self.stopAtLoadedFileEnd()
            }
        }
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

    /// The player now loaded, or nil. Hosted tests keep a released player
    /// and play it on, to show that nothing it reports reaches its
    /// successor.
    var _playerForTesting: AVPlayer? { player }

    /// Told, on the main queue, of every report from AVFoundation about the
    /// player once the service has dealt with it. Hosted tests wait on these
    /// reports instead of waiting a fixed time.
    var _reportHandledForTesting: ((AudioPlayerReport) -> Void)?

    /// Called on the main queue as an end-of-file notice, already posted,
    /// is about to be acted on. Hosted tests stop, seek, or load here, as a
    /// listener could just after the file's end was reached.
    var _endNoticeArrivedForTesting: (() -> Void)?

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
        continuePlayback(fromFileTime: fileTime, wasPlaying: wasPlaying, wasPaused: wasPaused)
    }

    /// Put the playback of a newly loaded player at `fileTime` seconds into
    /// its file, in the state playback was in before the load: playing on
    /// from there when it was playing, and otherwise paused or stopped
    /// there, as it was.
    private func continuePlayback(fromFileTime fileTime: TimeInterval, wasPlaying: Bool, wasPaused: Bool) {
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

    /// Watch the new player's clock: four times a second while it plays,
    /// and whenever its time jumps or it starts or stops.
    private func setupTimeObserver() {
        guard let player = player else { return }
        timeObserverGeneration += 1
        let observerGeneration = timeObserverGeneration
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            guard let self = self else { return }
            // AVFoundation starts no tick once its observer is removed, and
            // releasing a player removes its observer; a tick of an earlier
            // player's observer is still turned away here, so none can act
            // on the player now loaded.
            guard observerGeneration == self.timeObserverGeneration else {
                DiagnosticLog.trace(.playback, "audio position: ignored a tick from the observer of a released player")
                self._reportHandledForTesting?(.tickFromReleasedPlayer)
                return
            }
            self.playerClockDidTick()
        }
    }

    /// Act on the position of the player now loaded: publish it, or end the
    /// clip that has reached its end.
    ///
    /// The position is read from the player now rather than taken from the
    /// tick, which AVFoundation can measure just before a seek or a new play
    /// moves the player (it has handed over a tick still giving the old
    /// time while a seek to the end landed).
    private func playerClockDidTick() {
        guard let player else { return }
        let seconds = CMTimeGetSeconds(player.currentTime())
        // While the player plays another item than the loaded file's, as it
        // does for a moment when it rolls on from one file into the next,
        // its clock tells nothing of the loaded file's play.
        let action: AudioPositionObserverPolicy.Action = player.currentItem !== playerItem
            ? .ignore
            : AudioPositionObserverPolicy.action(
                seconds: seconds,
                isSeeking: seekGate.isSeeking,
                isPlaying: isPlaying && !isPaused,
                clipEndTime: clipEndTime
            )
        switch action {
        case .ignore:
            // Nothing to act on: a seek still on its way, during which the
            // player may report where it was before; a time that is not a
            // number; paused or finished playback at or past its clip's end;
            // or the clock of the file rolled on into.
            break
        case .finishClip:
            reachedEnd()
        case .publish(let position):
            recordPosition(atFileTime: position)
            onPositionUpdate?(currentTime)
        }
        _reportHandledForTesting?(.tick(seconds: seconds, action: action))
    }

    /// AVFoundation's notice that the loaded file played to its end, as it
    /// stood when the notice was posted.
    private struct EndNotice: Sendable {
        /// The generation of the play under way when the notice was posted.
        let generation: Int
        /// Where the item's playhead stood then, in seconds into the file,
        /// or nil when it could not be read.
        let playhead: TimeInterval?
    }

    /// Observe the loaded file's item: its end (`setupEndObserver()`) and
    /// each way it can fail (`setupItemFailureObservers()`). Releasing the
    /// player, or another file becoming the loaded one, removes these.
    private func setupItemObservers() {
        setupEndObserver()
        setupItemFailureObservers()
    }

    /// Watch for AVFoundation's notice that the new item played to its end.
    ///
    /// The notice is read as it is posted, on whatever thread posts it (the
    /// main thread, for a local file): the generation of the play under way
    /// and the item's playhead go with it to the main queue, where
    /// `handleEndNotice(_:)` acts on it. However late it is acted on, a
    /// notice posted during an earlier play is told apart from the end of
    /// the play under way.
    private func setupEndObserver() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let notice = EndNotice(
                generation: self.playGeneration.current,
                playhead: (notification.object as? AVPlayerItem).map { CMTimeGetSeconds($0.currentTime()) }
            )
            DispatchQueue.main.async { [weak self] in
                self?.handleEndNotice(notice)
            }
        }
    }

    /// Act on AVFoundation's notice that the loaded file played to its end,
    /// as `AudioEndNoticePolicy` decides. A notice that ends nothing is
    /// ignored with one trace line saying why.
    private func handleEndNotice(_ notice: EndNotice) {
        _endNoticeArrivedForTesting?()
        let outcome = AudioEndNoticePolicy.outcome(
            postedGeneration: notice.generation,
            currentGeneration: playGeneration.current,
            isPlaying: isPlaying,
            isPaused: isPaused,
            playhead: notice.playhead,
            playStart: playStartFileTime,
            fileDuration: loadedFileDuration,
            restartedFrom: restartedAfterLateEndFrom
        )
        switch outcome {
        case .endedPlay:
            reachedEnd()
        case .heldUntilResume:
            DiagnosticLog.trace(.playback, "audio end of file held: playback was paused when it came; resuming finishes the play")
            endHeldUntilResume = notice.generation
        case .postedDuringEarlierPlay:
            DiagnosticLog.trace(
                .playback,
                "audio end of file ignored: posted during an earlier play "
                    + "(generation \(notice.generation), now \(playGeneration.current))"
            )
        case .nothingPlaying:
            DiagnosticLog.trace(.playback, "audio end of file ignored: nothing was playing")
        case .lateForEarlierPlaythrough:
            DiagnosticLog.trace(
                .playback,
                "audio end of file ignored: the late end of an earlier playthrough, posted as the play "
                    + "from \(playStartFileTime)s began; starting that play again on a new player"
            )
            restartOnFreshPlayer()
        }
        _reportHandledForTesting?(.endOfFile(outcome))
    }

    /// How long the loaded file lasts, in seconds, as its item reports once
    /// it knows; nil before then or without an item.
    private var loadedFileDuration: TimeInterval? {
        guard let itemDuration = playerItem?.duration, itemDuration.isNumeric else { return nil }
        return CMTimeGetSeconds(itemDuration)
    }

    /// Begin the play under way again, from where it began, on a new player
    /// for the same file.
    ///
    /// AVFoundation leaves a player that posted the late end of an earlier
    /// playthrough stopped where the new play began, and asking it for its
    /// rate again does not start it. A new player holds a new item, which
    /// has no earlier playthrough. Playback keeps its state and its clip: it
    /// plays on when it was playing, and stays paused when it was paused.
    private func restartOnFreshPlayer() {
        guard let url = loadedURL else { return }
        let start = playStartFileTime
        let chain = chained
        let clipEnd = clipEndTime
        let following = followingFile?.url
        let wasPlaying = isPlaying
        let wasPaused = isPaused
        // A file that fails its check now is reported as any load reports it.
        guard loadFile(url, reusingLivePlayer: false) else { return }
        chained = chain
        clipEndTime = clipEnd
        continuePlayback(fromFileTime: start, wasPlaying: wasPlaying, wasPaused: wasPaused)
        restartedAfterLateEndFrom = start
        // The new player follows the file with whatever followed it before.
        setFileAfterCurrent(following)
    }

    /// Carry playback on from the end of the clip or file it has just
    /// played to: a clip chain plays on with its next clip, and only the end
    /// of its last clip, or of a lone clip or file, finishes playback. Both
    /// ways of noticing an end, the position observer reaching a clip's end
    /// and AVFoundation's end-of-file notice, come through here.
    private func reachedEnd() {
        if advanceToNextClip() { return }
        finishPlayback()
    }

    /// End playback because what it was asked to play has played to its
    /// end: the loaded file, the clip it was to stop at, or a chain's last
    /// clip. A clip that ends where its file does is reported twice, by the
    /// clip-end check and by AVFoundation's end-of-file notice, one after
    /// the other; only the first is acted on. Finishing begins a new play
    /// generation, so the second, posted during the play just finished,
    /// ends nothing, and playback that no longer plays has nothing left to
    /// finish anyway. `onPlaybackFinished` is therefore called once each
    /// time playback is started and runs to its end.
    ///
    /// The clip's end is kept, so the player's ticks at or past it once it
    /// has stopped report no time beyond the clip. Loading a file, or a
    /// chain's clip, sets the end afresh.
    ///
    /// Paused playback never finishes here: its end is held until it
    /// resumes, so the listener's pause is never overridden by moving on.
    ///
    /// When a file named to follow is queued behind the one that finished
    /// (`setFileAfterCurrent(_:)`), the player rolls straight on into it:
    /// that file becomes the loaded one and plays on, and the finished play's
    /// end is reported just the same.
    private func finishPlayback() {
        guard isPlaying, !isPaused else { return }
        playGeneration.advance()
        if adoptFollowingFile() {
            DiagnosticLog.trace(
                .playback,
                "audio play finished; playback rolled on into the file named to follow "
                    + "(generation \(playGeneration.current))"
            )
        } else {
            player?.pause()
            isPlaying = false
            isPaused = false
            DiagnosticLog.trace(.playback, "audio play finished (generation \(playGeneration.current))")
        }
        onPlaybackFinished?()
    }

    /// Observe the player's status, which can become `.failed`. Acted on
    /// from the main queue, and only while the player is still the current
    /// one, as `setupItemFailureObservers()` describes.
    private func setupPlayerStatusObserver() {
        guard let player else { return }
        // Key-value observation can call back on any thread. `.initial`
        // also delivers a status the player already has.
        playerStatusObservation = player.observe(\.status, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async { [weak self] in
                self?.playerStatusDidChange(player)
            }
        }
    }

    /// Observe each way AVFoundation reports that the loaded file's item
    /// cannot be played: its status, its failing to play to its end, and its
    /// stalling. The player's own status is observed with the player
    /// (`setupPlayerStatusObserver()`).
    ///
    /// Every observation is acted on from the main queue, like the other
    /// observers, and only while its item or player is still the current
    /// one: an observation that arrives after `load(url:)` replaced them is
    /// ignored, as the duration task ignores a replaced item.
    private func setupItemFailureObservers() {
        guard let item = playerItem else { return }
        // Key-value observation can call back on any thread. `.initial`
        // also delivers a status the item already has.
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async { [weak self] in
                self?.itemStatusDidChange(item)
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
        guard AudioStallPolicy.isStalled(
            isPlaying: isPlaying,
            isPaused: isPaused,
            playerIsAdvancing: player.timeControlStatus == .playing,
            reachedEndOfFile: Self.isAtEndOfFile(item)
        ) else { return }
        reportFailure(AudioPlaybackFailure(reason: .stalled, url: url))
    }

    /// Whether `item`'s playhead stands at or past the end of its file, as
    /// far as its length is known.
    private static func isAtEndOfFile(_ item: AVPlayerItem) -> Bool {
        item.duration.isNumeric && CMTimeCompare(item.currentTime(), item.duration) >= 0
    }

    /// Remove every observer of the player and of the loaded file's item.
    private func removeObservers() {
        if let observer = timeObserver, let player = player {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        playerStatusObservation?.invalidate()
        playerStatusObservation = nil
        removeItemObservers()
    }

    /// Remove the observers of the loaded file's item
    /// (`setupItemObservers()`), as when it gives way to another.
    private func removeItemObservers() {
        for observer in [endObserver, failedToPlayToEndObserver, stallObserver].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        endObserver = nil
        failedToPlayToEndObserver = nil
        stallObserver = nil
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
    }
}
