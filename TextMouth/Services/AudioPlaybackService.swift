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
    private var durationTask: Task<Void, Never>?
    private(set) var loadedURL: URL?

    /// Optional clip end time for segmented audio (e.g. DAISY).
    /// When set, playback fires onPlaybackFinished when reaching this time
    /// instead of waiting for the actual end of the audio file.
    private var clipEndTime: TimeInterval?

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
    /// - Returns: True when a player holds the file, ready to be asked to
    ///   play it; false when the file failed its check.
    @discardableResult
    func load(url: URL) -> Bool {
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
        // Both checks follow symbolic links; a broken link is missing.
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

    /// Play the loaded file from `fromTime` seconds.
    ///
    /// - Returns: True when playback started; false when there was nothing
    ///   to play, such as after a load that failed. `isPlaying` becomes true
    ///   only when playback starts.
    @discardableResult
    func play(fromTime: TimeInterval = 0) -> Bool {
        guard let player = player else { return false }
        let clampedTime = max(0, duration > 0 ? min(fromTime, duration) : fromTime)
        let cmTime = CMTime(seconds: clampedTime, preferredTimescale: 600)

        // Block clip-end checks until the seek lands, preventing the stale-time
        // race where the time observer sees the old position and re-triggers.
        let seekToken = seekGate.begin()
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.seekGate.complete(seekToken)
        }
        currentTime = clampedTime
        player.rate = Float(playbackSpeed)
        isPlaying = true
        isPaused = false
        return true
    }

    func pause() {
        guard isPlaying, !isPaused else { return }
        player?.pause()
        isPaused = true
    }

    /// Resumes only when a live AVPlayer item still exists. Returning false
    /// lets the reader reload the chapter after route changes or player loss.
    @discardableResult
    func resume() -> Bool {
        guard isPaused, let player, player.currentItem != nil, player.error == nil else {
            return false
        }
        player.rate = Float(playbackSpeed)
        isPaused = false
        isPlaying = true
        return true
    }

    func stop() {
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
        removeObservers()
        player?.pause()
        player = nil
        playerItem = nil
        loadedURL = nil
        clipEndTime = nil
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

    func seek(to time: TimeInterval) {
        guard let player = player else { return }
        let clampedTime = max(0, duration > 0 ? min(time, duration) : time)
        let cmTime = CMTime(seconds: clampedTime, preferredTimescale: 600)
        let seekToken = seekGate.begin()
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.seekGate.complete(seekToken)
        }
        currentTime = clampedTime
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

    // MARK: - Chapter/Marker Extraction

    /// Extract chapter markers from an audio file (M4B, M4A with chapters).
    /// Returns array of (title, startTime, duration).
    static func extractChapters(from url: URL) async -> [(title: String, startTime: TimeInterval, duration: TimeInterval)] {
        let asset = AVURLAsset(url: url)
        do {
            let locales = try await asset.load(.availableChapterLocales)
            let preferredLanguages = locales.isEmpty ? ["en"] : locales.map { $0.identifier }
            let groups = asset.chapterMetadataGroups(bestMatchingPreferredLanguages: preferredLanguages)

            return groups.map { group in
                let titleItems = AVMetadataItem.metadataItems(from: group.items,
                                                              filteredByIdentifier: .commonIdentifierTitle)
                let title = titleItems.first?.stringValue ?? "Chapter"
                let start = CMTimeGetSeconds(group.timeRange.start)
                let dur = CMTimeGetSeconds(group.timeRange.duration)
                return (title: title, startTime: start.isFinite ? start : 0, duration: dur.isFinite ? dur : 0)
            }
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
                self.player?.pause()
                self.isPlaying = false
                self.isPaused = false
                self.clipEndTime = nil
                self.onPlaybackFinished?()
                return
            case .publish(let seconds):
                self.currentTime = seconds
                self.onPositionUpdate?(seconds)
            }
        }
    }

    private func setupEndObserver() {
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            guard let self = self else { return }
            self.isPlaying = false
            self.isPaused = false
            self.onPlaybackFinished?()
        }
    }

    private func removeObservers() {
        if let observer = timeObserver, let player = player {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
    }
}
