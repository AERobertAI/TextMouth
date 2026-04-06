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
    private(set) var loadedURL: URL?

    /// Optional clip end time for segmented audio (e.g. DAISY).
    /// When set, playback fires onPlaybackFinished when reaching this time
    /// instead of waiting for the actual end of the audio file.
    private var clipEndTime: TimeInterval?

    /// Guards against the time observer firing clip-end while a seek is
    /// still in progress. Set true before seek, cleared in the completion
    /// handler. Prevents the stale-time race that causes rapid looping
    /// when consecutive segments share the same audio file.
    private var isSeeking = false

    /// Tracks the intended output volume independently of the AVPlayer
    /// instance. When load() creates a new AVPlayer for a chapter
    /// transition, the new player defaults to volume 1.0, discarding
    /// any fade-in-progress volume set by the sleep timer. This property
    /// is re-applied after every new player creation so volume remains
    /// consistent across chapters (mirrors the fix in AudioEngineService).
    private var currentVolume: Float = 1.0

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
        let normalizedURL = url.standardizedFileURL
        if let loadedURL, loadedURL == normalizedURL, player != nil {
            clipEndTime = nil
            return
        }

        stop()
        clipEndTime = nil

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
    }

    // MARK: - Playback

    func play(fromTime: TimeInterval = 0) {
        guard let player = player else { return }
        let clampedTime = max(0, duration > 0 ? min(fromTime, duration) : fromTime)
        let cmTime = CMTime(seconds: clampedTime, preferredTimescale: 600)

        // Block clip-end checks until the seek lands, preventing the stale-time
        // race where the time observer sees the old position and re-triggers.
        isSeeking = true
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.isSeeking = false
        }
        currentTime = clampedTime
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
        durationTask?.cancel()
        durationTask = nil
        removeObservers()
        player?.pause()
        player = nil
        playerItem = nil
        loadedURL = nil
        clipEndTime = nil
        isSeeking = false
        isPlaying = false
        isPaused = false
        currentTime = 0
        duration = 0
        currentVolume = 1.0
    }

    func seek(to time: TimeInterval) {
        guard let player = player else { return }
        let clampedTime = max(0, duration > 0 ? min(time, duration) : time)
        let cmTime = CMTime(seconds: clampedTime, preferredTimescale: 600)
        isSeeking = true
        player.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            self?.isSeeking = false
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

    func setSpeed(_ speed: Double) {
        playbackSpeed = max(minimumSpeed, min(speed, maximumSpeed))
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
            if secs.isFinite {
                // Skip clip-end check while a seek is in progress — the
                // reported time may be stale (pre-seek) and would falsely
                // trigger onPlaybackFinished for the new segment.
                if !self.isSeeking, let endTime = self.clipEndTime, secs >= endTime {
                    self.player?.pause()
                    self.isPlaying = false
                    self.isPaused = false
                    self.clipEndTime = nil
                    self.onPlaybackFinished?()
                    return
                }
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
