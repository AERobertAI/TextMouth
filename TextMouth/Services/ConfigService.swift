import Foundation
import Combine

/// Manages ~/.TextMouth/config.json, mirroring app settings.
/// AppStorage is the primary source of truth. Config.json mirrors it and
/// allows external editing — external changes are detected and synced back.
@MainActor
final class ConfigService: ObservableObject {
    static let shared = ConfigService()

    @Published var config: AppConfig = AppConfig()
    private var fileMonitorSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var isSaving = false

    struct WatcherActions: Equatable {
        let reload: Bool
        let rearm: Bool
    }

    /// Atomic writes replace the watched inode. Rename/delete events therefore
    /// always require a new watcher, including writes initiated by this process.
    static func watcherActions(
        for event: DispatchSource.FileSystemEvent,
        isSaving: Bool
    ) -> WatcherActions {
        let replaced = event.contains(.rename) || event.contains(.delete)
        return WatcherActions(reload: !isSaving, rearm: replaced)
    }

    struct AppConfig: Codable, Equatable {
        var selectedVoiceID: String = ""
        var wordsPerMinute: Double = 0  // 0 means "not yet set by user"
        /// Pitch multiplier (0.5–2.0, default 1.0). 0 means "not yet set by user"
        var pitchMultiplier: Double = 0
        var selectedLanguage: String = ""
        var skipForwardUnit: String = ""
        var skipBackwardUnit: String = ""
        var importDeleteBehavior: ImportDeleteBehavior = .keepOriginal
        /// Path to the .TextMouth data directory. Empty string means default (~/.TextMouth).
        var dataDirectoryPath: String = ""
        /// Whether to show a confirmation dialog before removing a book
        var confirmBeforeDelete: Bool = true
        /// Shift+skip forward unit (secondary skip amount)
        var shiftSkipForwardUnit: String = ""
        /// Shift+skip backward unit (secondary skip amount)
        var shiftSkipBackwardUnit: String = ""
        /// Rewind-on-resume unit (none, sentence, paragraph, heading)
        var rewindOnResumeUnit: String = ""
        /// Whether smart mode is enabled (only rewind after long pauses)
        var rewindSmartMode: Bool = false
        /// Smart mode threshold in seconds (don't rewind if pause shorter than this)
        var rewindSmartThreshold: Double = 70
        /// Sleep timer fade-out duration in seconds (0 = instant pause)
        var sleepFadeOutDuration: Double = 0
        /// Whether to automatically close the sleep timer sheet after setting a timer
        var sleepTimerAutoClose: Bool = true
        /// End-of-book behavior (stop, loop, continueNext)
        var endOfBookBehavior: String = ""
        /// Punctuation pause level (0 = none, 1 = subtle, 2 = moderate, 3 = heavy)
        var punctuationPauseLevel: Double = 0
        /// UUID of the last book that was opened/played (for quick-resume)
        var lastOpenedBookID: String = ""
        /// Auto-play when navigating to a heading, bookmark, or search result
        var autoPlayOnNavigate: Bool = false
        /// Move deleted books to Trash instead of permanently deleting
        var moveToTrashInsteadOfDeleting: Bool = true
        /// Whether Bluetooth disconnect monitoring is enabled
        var bluetoothMonitoringEnabled: Bool = true
        /// Suppress window duration (seconds) after Bluetooth disconnect
        var bluetoothDisconnectDelay: Double = 2.0
        /// Whether the experimental "restart sleep timer via media
        /// gesture" detector is enabled. Off by default — see
        /// MediaGestureDetector for rationale.
        var restartTimerGestureEnabled: Bool = false
        /// Comma-separated event-type sequence (see
        /// MediaGestureDetector.EventType) that triggers a sleep timer
        /// restart when matched within the configured time window.
        var restartTimerGesturePattern: String = "previousTrack,previousTrack,previousTrack"
        /// Maximum elapsed time in seconds across the gesture's event
        /// sequence. Anything longer breaks the match and starts the
        /// pattern over.
        var restartTimerGestureWindow: Double = 2.0

        /// Custom decoder to handle missing keys from older config.json files.
        /// Without this, adding new fields would break loading of existing configs.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            selectedVoiceID = try container.decodeIfPresent(String.self, forKey: .selectedVoiceID) ?? ""
            wordsPerMinute = try container.decodeIfPresent(Double.self, forKey: .wordsPerMinute) ?? 0
            pitchMultiplier = try container.decodeIfPresent(Double.self, forKey: .pitchMultiplier) ?? 0
            selectedLanguage = try container.decodeIfPresent(String.self, forKey: .selectedLanguage) ?? ""
            skipForwardUnit = try container.decodeIfPresent(String.self, forKey: .skipForwardUnit) ?? ""
            skipBackwardUnit = try container.decodeIfPresent(String.self, forKey: .skipBackwardUnit) ?? ""
            importDeleteBehavior = try container.decodeIfPresent(ImportDeleteBehavior.self, forKey: .importDeleteBehavior) ?? .keepOriginal
            dataDirectoryPath = try container.decodeIfPresent(String.self, forKey: .dataDirectoryPath) ?? ""
            confirmBeforeDelete = try container.decodeIfPresent(Bool.self, forKey: .confirmBeforeDelete) ?? true
            shiftSkipForwardUnit = try container.decodeIfPresent(String.self, forKey: .shiftSkipForwardUnit) ?? ""
            shiftSkipBackwardUnit = try container.decodeIfPresent(String.self, forKey: .shiftSkipBackwardUnit) ?? ""
            rewindOnResumeUnit = try container.decodeIfPresent(String.self, forKey: .rewindOnResumeUnit) ?? ""
            rewindSmartMode = try container.decodeIfPresent(Bool.self, forKey: .rewindSmartMode) ?? false
            rewindSmartThreshold = try container.decodeIfPresent(Double.self, forKey: .rewindSmartThreshold) ?? 70
            sleepFadeOutDuration = try container.decodeIfPresent(Double.self, forKey: .sleepFadeOutDuration) ?? 0
            sleepTimerAutoClose = try container.decodeIfPresent(Bool.self, forKey: .sleepTimerAutoClose) ?? true
            endOfBookBehavior = try container.decodeIfPresent(String.self, forKey: .endOfBookBehavior) ?? ""
            punctuationPauseLevel = try container.decodeIfPresent(Double.self, forKey: .punctuationPauseLevel) ?? 0
            lastOpenedBookID = try container.decodeIfPresent(String.self, forKey: .lastOpenedBookID) ?? ""
            autoPlayOnNavigate = try container.decodeIfPresent(Bool.self, forKey: .autoPlayOnNavigate) ?? false
            moveToTrashInsteadOfDeleting = try container.decodeIfPresent(Bool.self, forKey: .moveToTrashInsteadOfDeleting) ?? true
            bluetoothMonitoringEnabled = try container.decodeIfPresent(Bool.self, forKey: .bluetoothMonitoringEnabled) ?? true
            bluetoothDisconnectDelay = try container.decodeIfPresent(Double.self, forKey: .bluetoothDisconnectDelay) ?? 2.0
            restartTimerGestureEnabled = try container.decodeIfPresent(Bool.self, forKey: .restartTimerGestureEnabled) ?? false
            restartTimerGesturePattern = try container.decodeIfPresent(String.self, forKey: .restartTimerGesturePattern) ?? "previousTrack,previousTrack,previousTrack"
            restartTimerGestureWindow = try container.decodeIfPresent(Double.self, forKey: .restartTimerGestureWindow) ?? 2.0
        }

        init() {}
    }

    private init() {
        loadFromDisk()
    }

    /// Call after SettingsViewModel has initialized and populated config from AppStorage.
    /// This ensures the file watcher only starts after we have correct values on disk.
    func startWatching() {
        startFileWatcher()
    }

    func shutdown() {
        stopFileWatcher()
    }

    // MARK: - Persistence

    func saveToDisk() {
        isSaving = true
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.isSaving = false
            }
        }

        do {
            try TextMouthPaths.ensureDirectoryStructure()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: TextMouthPaths.configFile, options: .atomic)
        } catch {
            print("Failed to save config: \(error)")
        }
    }

    func loadFromDisk() {
        let url = TextMouthPaths.configFile
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(AppConfig.self, from: data)
            if decoded != config {
                DispatchQueue.main.async {
                    self.config = decoded
                }
            }
        } catch {
            print("Failed to load config: \(error)")
        }
    }

    /// Whether the config file has meaningful values (vs fresh defaults)
    var hasExistingConfig: Bool {
        FileManager.default.fileExists(atPath: TextMouthPaths.configFile.path) && config.wordsPerMinute > 0
    }

    // MARK: - File Watching

    private func startFileWatcher() {
        stopFileWatcher()
        let path = TextMouthPaths.configFile.path
        guard FileManager.default.fileExists(atPath: path) else { return }

        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let watchedDescriptor = fileDescriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchedDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let actions = Self.watcherActions(for: source.data, isSaving: self.isSaving)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                if actions.reload {
                    self.loadFromDisk()
                }
                if actions.rearm {
                    self.startFileWatcher()
                }
            }
        }

        source.setCancelHandler {
            close(watchedDescriptor)
        }

        source.resume()
        fileMonitorSource = source
    }

    private func stopFileWatcher() {
        fileMonitorSource?.cancel()
        fileMonitorSource = nil
        fileDescriptor = -1
    }
}

/// How to handle original files after import
enum ImportDeleteBehavior: String, Codable, CaseIterable {
    case keepOriginal = "Keep Original"
    case deleteAfterImport = "Delete After Import"
    case askEachTime = "Ask Each Time"

    var description: String { rawValue }
}
