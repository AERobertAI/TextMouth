import AVFoundation
import Combine

/// Plays audio files (mp3, m4a, m4b, wav, etc.) with variable speed and seeking.
/// Used for audio book playback as an alternative to the TTS SpeechService.
class AudioPlaybackService: NSObject, ObservableObject {
    @Published var isPlaying = false
    @Published var isPaused = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var playbackSpeed: Double = 1.0

    var onPlaybackFinished: (() -> Void)?
    var onPositionUpdate: ((TimeInterval) -> Void)?

    private var player: AVPlayer?
    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var durationTask: Task<Void, Never>?

    let minimumSpeed: Double = 0.25
    let maximumSpeed: Double = 4.0

    override init() {
        super.init()
    }

    deinit {
        stop()
    }

    // MARK: - Loading

    /// Load an audio file for playback. Call this before play().
    func load(url: URL) {
        stop()

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain // Best for speech

        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.automaticallyWaitsToMinimizeStalling = false

        self.playerItem = item
        self.player = avPlayer

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
    }

    // MARK: - Playback

    func play(fromTime: TimeInterval = 0) {
        guard let player = player else { return }
        if fromTime > 0 {
            let cmTime = CMTime(seconds: fromTime, preferredTimescale: 600)
            player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        player.rate = Float(playbackSpeed)
        isPlaying = true
        isPaused = false
    }

    func pause() {
        guard isPlaying, !isPaused else { return }
        player?.pause()
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        player?.rate = Float(playbackSpeed)
        isPaused = false
    }

    func stop() {
        removeObservers()
        player?.pause()
        player = nil
        playerItem = nil
        isPlaying = false
        isPaused = false
        currentTime = 0
    }

    func seek(to time: TimeInterval) {
        guard let player = player else { return }
        let cmTime = CMTime(seconds: max(0, min(time, duration)), preferredTimescale: 600)
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = time
    }

    func setSpeed(_ speed: Double) {
        playbackSpeed = max(minimumSpeed, min(speed, maximumSpeed))
        if isPlaying && !isPaused {
            player?.rate = Float(playbackSpeed)
        }
    }

    /// Volume control (for sleep timer fade-out)
    func setVolume(_ volume: Float) {
        player?.volume = max(0.0, min(volume, 1.0))
    }

    func restoreVolume() {
        player?.volume = 1.0
    }

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
    static func extractMetadata(from url: URL) async -> (title: String?, artist: String?) {
        let asset = AVURLAsset(url: url)
        do {
            let metadata = try await asset.load(.commonMetadata)
            let titleItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle)
            let artistItems = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtist)
            let title = try? await titleItems.first?.load(.stringValue)
            let artist = try? await artistItems.first?.load(.stringValue)
            return (title: title, artist: artist)
        } catch {
            return (nil, nil)
        }
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
            if secs.isFinite {
                self.currentTime = secs
                self.onPositionUpdate?(secs)
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
