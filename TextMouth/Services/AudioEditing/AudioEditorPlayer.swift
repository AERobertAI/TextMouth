import AVFoundation

// MARK: - What the Editor Plays Through

/// What the audio editor plays its preview through (FR04): an `AVPlayer`
/// over the edited audio's composition in the app (`AVAudioEditorPlayer`),
/// and a stand-in in tests, which never makes a sound.
///
/// The editor hands the player a new composition after every edit, at the
/// place it was, so what plays is always the audio as edited. Every time is
/// in seconds on the edited audio. Seeks are exact to the sample: an editor
/// that lands near a place is no use for cutting at it.
@MainActor
protocol AudioEditorPlayback: AnyObject {
    /// Plays `preview` from now on, paused at `time`.
    func load(_ preview: AudioEditComposition, at time: TimeInterval)
    /// Where the player is, in seconds.
    var currentTime: TimeInterval { get }
    /// Whether it is playing.
    var isPlaying: Bool { get }
    /// Plays from `time`, stopping by itself at `end` when one is given (a
    /// selection's end, or half a second on for a scrub), or else at the
    /// end of the audio.
    func play(from time: TimeInterval, until end: TimeInterval?)
    /// Pauses where it is.
    func pause()
    /// Moves to `time` without playing.
    func seek(to time: TimeInterval)
    /// Told, on the main actor, when playing stops by itself: at the end
    /// time `play(from:until:)` was given, or at the end of the audio.
    var onStop: (@MainActor () -> Void)? { get set }
    /// Told every tenth of a second or so while playing, with the time.
    var onTime: (@MainActor (TimeInterval) -> Void)? { get set }
    /// Stops and lets go of the preview, as the window closes.
    func close()
}

// MARK: - The App's Player

/// The audio editor's player in the app: an `AVPlayer` over the edited
/// audio's composition, which refers to the book's files without copying
/// them, so it plays the edits sample-exact without rendering anything.
///
/// Every seek has zero tolerance. A play that should stop at a given time
/// sets the item's `forwardPlaybackEndTime`, AVFoundation's own way to stop
/// there, and the clock observer stops it too should the item overrun.
/// Playing never touches the reader's Now Playing information or the media
/// keys, and nothing here mutes or ducks other sound: VoiceOver keeps
/// speaking over it, as over any other sound.
@MainActor
final class AVAudioEditorPlayer: AudioEditorPlayback {
    var onStop: (@MainActor () -> Void)?
    var onTime: (@MainActor (TimeInterval) -> Void)?

    /// The player.
    private let player = AVPlayer()
    /// The composition playing, kept with the assets it reads from.
    private var preview: AudioEditComposition?
    /// The periodic clock observer, removed as the player closes.
    private var clockObserver: Any?
    /// The observer of the item playing to its end.
    private var endObserver: NSObjectProtocol?
    /// Where a play under way stops by itself, if it was given an end.
    private var stopTime: TimeInterval?
    /// Counts plays, seeks, and loads, so a seek that finishes after a
    /// newer one began starts nothing.
    private var generation = 0
    /// Whether a play was asked for and has not stopped: true from the
    /// moment `play` is called, while its seek is still under way.
    private(set) var isPlaying = false

    /// A player with nothing loaded.
    init() {
        // The editor plays files on this Mac: there is nothing to wait for.
        player.automaticallyWaitsToMinimizeStalling = false
        let interval = CMTime(value: 1, timescale: 10)
        clockObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.clockTicked(time.seconds) }
        }
    }

    var currentTime: TimeInterval {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? max(0, seconds) : 0
    }

    func load(_ preview: AudioEditComposition, at time: TimeInterval) {
        generation += 1
        stopPlaying(reportingStop: false)
        // Never decode a format the import converts (B09, FMT09): Apple's
        // Vorbis decoder once spun forever. A preview of such audio holds no
        // item, so it plays nothing; the library converts such a book.
        guard !preview.sources.contains(where: { ImportAudioConverter.isNeverDecodedInApp($0.url) }) else {
            player.replaceCurrentItem(with: nil)
            return
        }
        let item = AVPlayerItem(asset: preview.composition)
        self.preview = preview
        observeEnd(of: item)
        player.replaceCurrentItem(with: item)
        seekPlayer(to: time, then: nil)
    }

    func play(from time: TimeInterval, until end: TimeInterval?) {
        guard let item = player.currentItem else { return }
        generation += 1
        let thisPlay = generation
        stopTime = end
        item.forwardPlaybackEndTime = end.map(Self.cmTime) ?? .invalid
        isPlaying = true
        seekPlayer(to: time) { [weak self] in
            guard let self, self.generation == thisPlay, self.isPlaying else { return }
            self.player.play()
        }
    }

    func pause() {
        generation += 1
        stopPlaying(reportingStop: false)
    }

    func seek(to time: TimeInterval) {
        generation += 1
        stopPlaying(reportingStop: false)
        seekPlayer(to: time, then: nil)
    }

    func close() {
        generation += 1
        stopPlaying(reportingStop: false)
        if let clockObserver {
            player.removeTimeObserver(clockObserver)
            self.clockObserver = nil
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        player.replaceCurrentItem(with: nil)
        preview = nil
        onStop = nil
        onTime = nil
    }

    // MARK: Helpers

    /// `seconds` as a time AVFoundation takes, to the microsecond.
    private static func cmTime(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: 1_000_000)
    }

    /// Seeks with zero tolerance, then runs `then` on the main actor.
    private func seekPlayer(to time: TimeInterval, then: (@MainActor @Sendable () -> Void)?) {
        player.seek(to: Self.cmTime(time), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            guard let then else { return }
            Task { @MainActor in then() }
        }
    }

    /// Stops the player and forgets the play under way; tells `onStop`
    /// when the play ended by itself.
    private func stopPlaying(reportingStop: Bool) {
        player.pause()
        let wasPlaying = isPlaying
        isPlaying = false
        stopTime = nil
        player.currentItem?.forwardPlaybackEndTime = .invalid
        if reportingStop, wasPlaying {
            onStop?()
        }
    }

    /// Reports the clock while playing, and stops a play that reached its
    /// end time without AVFoundation stopping it.
    private func clockTicked(_ seconds: TimeInterval) {
        guard isPlaying, seconds.isFinite else { return }
        onTime?(max(0, seconds))
        if let stopTime, seconds >= stopTime {
            stopPlaying(reportingStop: true)
        }
    }

    /// Follows `item` to its end, or to its forward end time: either stops
    /// the play under way.
    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopPlaying(reportingStop: true) }
        }
    }
}
