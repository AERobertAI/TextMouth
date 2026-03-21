import Foundation
import Combine

/// Manages ~/.TextMouth/config.json, mirroring app settings.
/// AppStorage is the primary source of truth. Config.json mirrors it and
/// allows external editing — external changes are detected and synced back.
class ConfigService: ObservableObject {
    static let shared = ConfigService()

    @Published var config: AppConfig = AppConfig()
    private var fileMonitorSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var isSaving = false

    struct AppConfig: Codable, Equatable {
        var selectedVoiceID: String = ""
        var wordsPerMinute: Double = 0  // 0 means "not yet set by user"
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
        /// End-of-book behavior (stop, loop, continueNext)
        var endOfBookBehavior: String = ""
        /// Punctuation pause level (0 = none, 1 = subtle, 2 = moderate, 3 = heavy)
        var punctuationPauseLevel: Double = 0
        /// UUID of the last book that was opened/played (for quick-resume)
        var lastOpenedBookID: String = ""
        /// Auto-play when navigating to a heading, bookmark, or search result
        var autoPlayOnNavigate: Bool = false
    }

    private init() {
        loadFromDisk()
    }

    deinit {
        stopFileWatcher()
    }

    /// Call after SettingsViewModel has initialized and populated config from AppStorage.
    /// This ensures the file watcher only starts after we have correct values on disk.
    func startWatching() {
        startFileWatcher()
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
        let path = TextMouthPaths.configFile.path
        guard FileManager.default.fileExists(atPath: path) else { return }

        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            guard let self = self, !self.isSaving else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.loadFromDisk()
            }
        }

        source.setCancelHandler { [weak self] in
            if let fd = self?.fileDescriptor, fd >= 0 {
                close(fd)
            }
        }

        source.resume()
        fileMonitorSource = source
    }

    private func stopFileWatcher() {
        fileMonitorSource?.cancel()
        fileMonitorSource = nil
    }
}

/// How to handle original files after import
enum ImportDeleteBehavior: String, Codable, CaseIterable {
    case keepOriginal = "Keep Original"
    case deleteAfterImport = "Delete After Import"
    case askEachTime = "Ask Each Time"

    var description: String { rawValue }
}
