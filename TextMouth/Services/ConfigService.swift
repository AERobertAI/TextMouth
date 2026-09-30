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

    /// What config.json held when this service last read it.
    enum LoadedFile: Equatable {
        /// There was no file: the first launch, or the file was deleted.
        case missing
        /// The file decoded, and `config` holds its values.
        case decoded
        /// The file exists but could not be read or decoded. It stays as it
        /// is, so whoever edited it can correct it.
        case unreadable
    }

    /// What config.json held when this service last read it.
    private(set) var loadedFile: LoadedFile = .missing

    /// The file to mirror in place of the data directory's, for tests.
    private let customFileURL: URL?

    /// config.json: the file this service was created for, or else the one
    /// in the data directory in use, which moves when the library does.
    var fileURL: URL { customFileURL ?? TextMouthPaths.configFile }

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

    /// The contents of config.json. Numeric and enum-backed fields follow
    /// `SettingsPolicy`, which supplies their defaults and validates them
    /// when the file is decoded.
    struct AppConfig: Codable, Equatable {
        var selectedVoiceID: String = ""
        /// Words per minute (50–650). 0 means "not yet set by user".
        var wordsPerMinute: Double = SettingsPolicy.wordsPerMinute.configDefault
        /// Pitch multiplier (0.5–2.0, default 1.0). 0 means "not yet set by user"
        var pitchMultiplier: Double = SettingsPolicy.pitchMultiplier.configDefault
        var selectedLanguage: String = ""
        var skipForwardUnit: String = ""
        var skipBackwardUnit: String = ""
        var importDeleteBehavior: ImportDeleteBehavior = SettingsPolicy.importDeleteBehavior.defaultValue
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
        var rewindSmartThreshold: Double = SettingsPolicy.rewindSmartThreshold.configDefault
        /// Sleep timer fade-out duration in seconds (0 = instant pause)
        var sleepFadeOutDuration: Double = SettingsPolicy.sleepFadeOutDuration.configDefault
        /// Whether to automatically close the sleep timer sheet after setting a timer
        var sleepTimerAutoClose: Bool = true
        /// End-of-book behavior (stop, loop, continueNext)
        var endOfBookBehavior: String = ""
        /// Punctuation pause level (0 = none, 1 = subtle, 2 = moderate, 3 = heavy)
        var punctuationPauseLevel: Double = SettingsPolicy.punctuationPauseLevel.configDefault
        /// UUID of the last book that was opened/played (for quick-resume)
        var lastOpenedBookID: String = ""
        /// Auto-play when navigating to a heading, bookmark, or search result
        var autoPlayOnNavigate: Bool = false
        /// Move deleted books to Trash instead of permanently deleting
        var moveToTrashInsteadOfDeleting: Bool = true
        /// Whether Bluetooth disconnect monitoring is enabled
        var bluetoothMonitoringEnabled: Bool = true
        /// Suppress window duration (seconds) after Bluetooth disconnect
        var bluetoothDisconnectDelay: Double = SettingsPolicy.bluetoothDisconnectDelay.configDefault
        /// Whether the experimental "restart sleep timer via media
        /// gesture" detector is enabled. Off by default — see
        /// MediaGestureDetector for rationale.
        var restartTimerGestureEnabled: Bool = false
        /// Comma-separated event-type sequence (see
        /// MediaGestureDetector.EventType) that triggers a sleep timer
        /// restart when matched within the configured time window.
        var restartTimerGesturePattern: String = AppConfig.defaultRestartTimerGesturePattern
        /// Maximum elapsed time in seconds across the gesture's event
        /// sequence. Anything longer breaks the match and starts the
        /// pattern over.
        var restartTimerGestureWindow: Double = SettingsPolicy.restartTimerGestureWindow.configDefault

        /// Decodes config.json one field at a time, because people edit it
        /// by hand. A missing field keeps its default (older files lack newer
        /// fields). A field that is unreadable, out of range, or unsupported
        /// is repaired and logged by `LenientFields` rather than failing the
        /// whole file, so one bad value can never discard the others.
        init(from decoder: Decoder) throws {
            let fields = LenientFields(try decoder.container(keyedBy: CodingKeys.self), source: "config.json")
            // The property defaults above are the only copy of each default.
            let fallback = AppConfig()
            selectedVoiceID = fields.value(.selectedVoiceID, default: fallback.selectedVoiceID)
            wordsPerMinute = fields.number(.wordsPerMinute, rule: SettingsPolicy.wordsPerMinute)
            pitchMultiplier = fields.number(.pitchMultiplier, rule: SettingsPolicy.pitchMultiplier)
            selectedLanguage = fields.value(.selectedLanguage, default: fallback.selectedLanguage)
            skipForwardUnit = fields.rawChoice(.skipForwardUnit, rule: SettingsPolicy.skipForwardUnit)
            skipBackwardUnit = fields.rawChoice(.skipBackwardUnit, rule: SettingsPolicy.skipBackwardUnit)
            importDeleteBehavior = fields.choice(.importDeleteBehavior, rule: SettingsPolicy.importDeleteBehavior)
            // Applying "" moves the library to the default location at once,
            // so an unreadable path keeps the directory already in use.
            dataDirectoryPath = fields.value(
                .dataDirectoryPath,
                default: fallback.dataDirectoryPath,
                ifUnreadable: Self.currentDataDirectoryPath
            )
            confirmBeforeDelete = fields.value(.confirmBeforeDelete, default: fallback.confirmBeforeDelete)
            shiftSkipForwardUnit = fields.rawChoice(.shiftSkipForwardUnit, rule: SettingsPolicy.shiftSkipForwardUnit)
            shiftSkipBackwardUnit = fields.rawChoice(.shiftSkipBackwardUnit, rule: SettingsPolicy.shiftSkipBackwardUnit)
            rewindOnResumeUnit = fields.rawChoice(.rewindOnResumeUnit, rule: SettingsPolicy.rewindOnResumeUnit)
            rewindSmartMode = fields.value(.rewindSmartMode, default: fallback.rewindSmartMode)
            rewindSmartThreshold = fields.number(.rewindSmartThreshold, rule: SettingsPolicy.rewindSmartThreshold)
            sleepFadeOutDuration = fields.number(.sleepFadeOutDuration, rule: SettingsPolicy.sleepFadeOutDuration)
            sleepTimerAutoClose = fields.value(.sleepTimerAutoClose, default: fallback.sleepTimerAutoClose)
            endOfBookBehavior = fields.rawChoice(.endOfBookBehavior, rule: SettingsPolicy.endOfBookBehavior)
            punctuationPauseLevel = fields.number(.punctuationPauseLevel, rule: SettingsPolicy.punctuationPauseLevel)
            lastOpenedBookID = fields.value(.lastOpenedBookID, default: fallback.lastOpenedBookID)
            autoPlayOnNavigate = fields.value(.autoPlayOnNavigate, default: fallback.autoPlayOnNavigate)
            moveToTrashInsteadOfDeleting = fields.value(
                .moveToTrashInsteadOfDeleting,
                default: fallback.moveToTrashInsteadOfDeleting
            )
            bluetoothMonitoringEnabled = fields.value(
                .bluetoothMonitoringEnabled,
                default: fallback.bluetoothMonitoringEnabled
            )
            bluetoothDisconnectDelay = fields.number(
                .bluetoothDisconnectDelay,
                rule: SettingsPolicy.bluetoothDisconnectDelay
            )
            restartTimerGestureEnabled = fields.value(
                .restartTimerGestureEnabled,
                default: fallback.restartTimerGestureEnabled
            )
            restartTimerGesturePattern = fields.value(
                .restartTimerGesturePattern,
                default: fallback.restartTimerGesturePattern
            )
            restartTimerGestureWindow = fields.number(
                .restartTimerGestureWindow,
                rule: SettingsPolicy.restartTimerGestureWindow
            )
        }

        init() {}

        /// The `dataDirectoryPath` describing the data directory in use: empty
        /// for the default location, otherwise its full path.
        static var currentDataDirectoryPath: String {
            TextMouthPaths.isCustomPath ? TextMouthPaths.rootPath : ""
        }

        /// Three previous-track presses in a row: the restart-timer gesture
        /// until the user picks another, shared with the Settings model.
        static let defaultRestartTimerGesturePattern = "previousTrack,previousTrack,previousTrack"
    }

    /// Creates a service and loads its file before returning.
    ///
    /// - Parameter fileURL: The file to mirror. Nil, as `shared` uses,
    ///   follows the data directory in use; tests pass a file of their own.
    init(fileURL: URL? = nil) {
        customFileURL = fileURL
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
            let data = try Self.fileData(for: config)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log("could not save \(fileURL.path): \(error)")
        }
    }

    /// The exact bytes `saveToDisk()` writes for `config`: sorted, indented
    /// JSON that stays readable for people who edit the file by hand.
    nonisolated static func fileData(for config: AppConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(config)
    }

    /// Reads config.json into `config` before returning.
    ///
    /// Consumers created afterwards therefore read the file's values. The
    /// assignment used to wait for the next main-queue turn, so launch found
    /// only defaults, skipped applying the file, and saved the preferences
    /// over it before the file's own values arrived.
    func loadFromDisk() {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            loadedFile = .missing
            return
        }
        do {
            let decoded = try JSONDecoder().decode(AppConfig.self, from: Data(contentsOf: url))
            if decoded != config {
                config = decoded
            }
            loadedFile = .decoded
        } catch {
            loadedFile = .unreadable
            log("could not read \(url.path); keeping the settings in use. \(Self.failureReason(error))")
        }
    }

    /// Whether config.json held a decodable file when this service last read
    /// it; `config` then holds that file's values, which launch applies to
    /// the preferences. A file that leaves speed unset still counts, since
    /// it can hold every other setting.
    var hasExistingConfig: Bool { loadedFile == .decoded }

    // MARK: - File Watching

    private func startFileWatcher() {
        stopFileWatcher()
        let path = fileURL.path
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

    // MARK: - Diagnostics

    /// Records a config.json event in the console and the debug log.
    private func log(_ message: String) {
        let line = "CONFIG_FILE: \(message)"
        print(line)
        TextMouthPaths.appendLog(to: TextMouthPaths.debugLogFile, message: line)
    }

    /// Why decoding failed, in one line: the decoder's summary, then the
    /// parser's account of where the text went wrong when it gives one, such
    /// as "Unexpected character ',' around line 1, column 24."
    private nonisolated static func failureReason(_ error: Error) -> String {
        guard case DecodingError.dataCorrupted(let context) = error else {
            return String(describing: error)
        }
        let detail = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
        return [context.debugDescription, detail].compactMap { $0 }.joined(separator: " ")
    }
}

/// How to handle original files after import
enum ImportDeleteBehavior: String, Codable, CaseIterable {
    case keepOriginal = "Keep Original"
    case deleteAfterImport = "Delete After Import"
    case askEachTime = "Ask Each Time"

    var description: String { rawValue }
}
