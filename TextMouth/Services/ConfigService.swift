import Foundation
import Combine

/// Mirrors the app's settings in config.json, in the data directory, where
/// they can be read and edited by hand.
///
/// The preferences store is the source of truth while TextMouth runs, and
/// config.json follows it: each settings change saves the file. At launch
/// the file's values are applied first, because the file is where settings
/// can change while TextMouth is closed. While TextMouth runs, a watcher
/// notices edits saved from outside, tells them from TextMouth's own saves
/// by their bytes rather than by timing, and publishes each once through
/// `externalEdits`. Everything here runs on the main actor, which owns all
/// of the watcher's state.
@MainActor
final class ConfigService: ObservableObject {
    /// The service for the data directory's config.json.
    static let shared = ConfigService()

    /// The settings as config.json holds them. Screens that manage a field of
    /// their own change it here and call `saveToDisk()`; the settings model
    /// keeps the fields it mirrors in step with the preferences.
    @Published var config: AppConfig = AppConfig()

    /// Publishes each edit of config.json made outside TextMouth, once, after
    /// `config` holds it. Delivery is synchronous on the main actor, so a
    /// subscriber applies edits in order and never receives TextMouth's own
    /// saves. The settings model applies these to the preferences.
    let externalEdits = PassthroughSubject<AppConfig, Never>()

    // MARK: - The File

    /// What config.json held when this service was created.
    enum LoadedFile: Equatable {
        /// There was no file: the first launch, or the file was deleted.
        case missing
        /// The file decoded, and `config` holds its values.
        case decoded
        /// The file exists but could not be read or decoded. It stays as it
        /// is, so whoever edited it can correct it.
        case unreadable
    }

    /// What config.json held when this service was created.
    private(set) var loadedFile: LoadedFile = .missing

    /// Whether config.json held a decodable file when this service was
    /// created; `config` then holds that file's values, which launch applies
    /// to the preferences. A file that leaves speed unset still counts, since
    /// it can hold every other setting.
    var hasExistingConfig: Bool { loadedFile == .decoded }

    /// The file to mirror in place of the data directory's, for tests.
    private let customFileURL: URL?

    /// config.json: the file this service was created for, or else the one
    /// in the data directory in use, which moves when the library does.
    var fileURL: URL { customFileURL ?? TextMouthPaths.configFile }

    /// The file-system calls this service makes, replaceable so tests can
    /// count them.
    struct FileOperations {
        /// Replaces the file at a URL with new contents in one atomic step.
        var write: @MainActor (_ data: Data, _ url: URL) throws -> Void
        /// Opens a path for event notification only, returning a descriptor,
        /// or -1 when it cannot be opened.
        var openForEvents: @MainActor (_ path: String) -> Int32
        /// Closes a descriptor that `openForEvents` returned.
        var close: @MainActor (_ descriptor: Int32) -> Void

        /// The calls the app makes.
        static var system: FileOperations {
            FileOperations(
                write: { data, url in try data.write(to: url, options: .atomic) },
                openForEvents: { path in Darwin.open(path, O_EVTONLY) },
                close: { descriptor in _ = Darwin.close(descriptor) }
            )
        }
    }

    /// The file-system calls in use.
    private let fileOperations: FileOperations

    // MARK: - Agreement With the File

    /// config.json's bytes as this process last wrote, loaded, or examined
    /// them. A file event that finds these bytes brings nothing new: it is
    /// TextMouth's own save, or an edit already applied or rejected. This
    /// replaces a half-second window after each save during which every
    /// event, an editor's included, used to be ignored.
    private var lastHandledContents: Data?

    /// The settings this process and config.json last agreed on: the ones it
    /// last loaded, wrote, or applied. Saving merges an edit it finds on disk
    /// against this, to tell the fields TextMouth changed since from the
    /// fields the edit changed. Nil until a file was decoded or written.
    private var lastSyncedConfig: AppConfig?

    // MARK: - Watcher State

    /// Whether the watcher is on: from `startWatching()` until `shutdown()`.
    private var isWatching = false
    /// How long a burst of file events must stay quiet before the file is
    /// read.
    private let coalescingDelay: Duration
    /// The events received since the file was last checked, combined.
    private var pendingEvents: DispatchSource.FileSystemEvent = []
    /// The check that runs once the current burst of events settles.
    private var pendingCheck: Task<Void, Never>?

    /// The file the watcher listens to.
    private struct WatchedFile {
        /// Which file it is, whatever path later leads to it.
        let identity: FileIdentity
        /// Delivers its events; cancelling it closes its descriptor.
        let source: DispatchSourceFileSystemObject
    }

    /// The file the watcher listens to, if any.
    private var watchedFile: WatchedFile?
    /// The search for a file that went missing, while it goes on.
    private var rearmRetry: Task<Void, Never>?

    /// The events that matter: a write in place, and the rename, deletion,
    /// or revocation (its volume was unmounted) that ends the watched file's
    /// time at the path.
    private static let watchedEvents: DispatchSource.FileSystemEvent = [.write, .rename, .delete, .revoke]

    /// The pauses before each look for a missing file: short at first, for an
    /// editor that puts the new file in place a moment after removing the old
    /// one, and longer at the end, for a slow volume. About 1.5 seconds in all.
    private static let rearmRetryDelays: [Duration] = [50, 100, 200, 400, 800].map { .milliseconds($0) }

    // MARK: - Watcher Decision

    /// What the watcher does about a batch of file events.
    struct WatcherActions: Equatable {
        /// Watch the file now at the path: the watched one was renamed,
        /// deleted, or revoked, as when an atomic save renames a new file
        /// over it.
        let rearm: Bool
        /// Decode the file and apply it: it holds bytes this process has
        /// neither written nor seen.
        let reload: Bool
    }

    /// The watcher's decision for `event`, given config.json's bytes now (nil
    /// when there is no readable file) and the bytes this process last wrote,
    /// loaded, or examined.
    ///
    /// Comparing contents rather than the time since the last save is what
    /// tells TextMouth's own writes from anyone else's: an edit saved moments
    /// after TextMouth saved is still applied, and TextMouth's own save never
    /// is, however late its events arrive. Atomic saves replace the watched
    /// file, TextMouth's included, so the event alone decides whether to
    /// follow the file.
    nonisolated static func watcherActions(
        for event: DispatchSource.FileSystemEvent,
        fileContents: Data?,
        lastHandledContents: Data?
    ) -> WatcherActions {
        WatcherActions(
            rearm: replacesWatchedFile(event),
            reload: fileContents.map { $0 != lastHandledContents } ?? false
        )
    }

    /// Whether `event` means the watched file no longer sits at the path.
    private nonisolated static func replacesWatchedFile(_ event: DispatchSource.FileSystemEvent) -> Bool {
        !event.isDisjoint(with: [.rename, .delete, .revoke])
    }

    // MARK: - Settings

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

        // MARK: Fields added after the file first shipped
        //
        // A file written before one of these existed lacks it. Each reads as
        // nil or empty then, which leaves the preference as it is, so a file
        // from an earlier version never resets a newer preference.

        /// Which per-book navigation menus the playback bar shows (a
        /// `PlaybackNavigationUnitControlMode` raw value); empty keeps the
        /// current choice.
        var playbackNavigationUnitControlMode: String = ""
        /// Whether the playback bar shows the bookmark button.
        var showBookmarkInPlaybackControls: Bool?
        /// Whether the playback bar shows the speed controls.
        var showSpeedInPlaybackControls: Bool?
        /// Whether sound effects play.
        var soundEffectsEnabled: Bool?
        /// How loud sound effects play, from 0 to 1, written to the
        /// hundredth: the precision Settings shows, as a percentage.
        var soundEffectsVolume: Double?
        /// The sound each playback event plays, keyed by the event's name as
        /// Settings shows it; "None" plays nothing. TextMouth writes every
        /// event; an event the file leaves out keeps its sound.
        var soundEffectAssignments: [String: String] = [:]

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
            playbackNavigationUnitControlMode = fields.rawChoice(
                .playbackNavigationUnitControlMode,
                rule: SettingsPolicy.playbackNavigationUnitControlMode
            )
            showBookmarkInPlaybackControls = fields.optionalFlag(.showBookmarkInPlaybackControls)
            showSpeedInPlaybackControls = fields.optionalFlag(.showSpeedInPlaybackControls)
            soundEffectsEnabled = fields.optionalFlag(.soundEffectsEnabled)
            soundEffectsVolume = fields.optionalNumber(.soundEffectsVolume, rule: SettingsPolicy.soundEffectsVolume)
            soundEffectAssignments = fields.entries(
                .soundEffectAssignments,
                rule: SettingsPolicy.soundEffectAssignments
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

    // MARK: - Lifecycle

    /// Creates a service and loads its file before returning.
    ///
    /// - Parameters:
    ///   - fileURL: The file to mirror. Nil, as `shared` uses, follows the
    ///     data directory in use; tests pass a file of their own.
    ///   - fileOperations: The file-system calls to make; tests count them.
    ///   - coalescingDelay: How long a burst of file events must stay quiet
    ///     before the watcher reads the file.
    init(
        fileURL: URL? = nil,
        fileOperations: FileOperations = .system,
        coalescingDelay: Duration = .milliseconds(200)
    ) {
        customFileURL = fileURL
        self.fileOperations = fileOperations
        self.coalescingDelay = coalescingDelay
        loadFromDisk()
    }

    /// Starts following config.json for edits made outside TextMouth. Launch
    /// calls this once it has reconciled the file with the preferences.
    func startWatching() {
        isWatching = true
        rearmWatcher()
    }

    /// Stops following config.json: pending checks and searches are dropped,
    /// and the watched file's descriptor is closed once its source is
    /// cancelled. Events that arrive later are ignored.
    func shutdown() {
        isWatching = false
        pendingCheck?.cancel()
        pendingCheck = nil
        pendingEvents = []
        rearmRetry?.cancel()
        rearmRetry = nil
        disarm()
    }

    // MARK: - Persistence

    /// Makes config.json hold `config`.
    ///
    /// An edit that reached the file since this process last wrote or read
    /// it, still waiting for the watcher's delay, is merged in first rather
    /// than saved over. Nothing is written when the file already holds
    /// exactly the resulting bytes: writing them again would change only the
    /// modification date and wake the watcher, so a launch on a consistent
    /// file writes nothing. The bytes become `lastHandledContents`, which is
    /// how the watcher recognizes the events of this save as TextMouth's own.
    func saveToDisk() {
        let onDisk = readFileContents()
        if let onDisk, onDisk != lastHandledContents {
            mergeUnhandledEdit(onDisk)
        }
        let data: Data
        do {
            data = try Self.fileData(for: config)
        } catch {
            log("could not encode the settings for \(fileURL.path): \(error)")
            return
        }
        guard data != onDisk else {
            recordAgreement(data)
            return
        }
        do {
            try TextMouthPaths.ensureDirectoryStructure()
            try fileOperations.write(data, fileURL)
        } catch {
            log("could not save \(fileURL.path): \(error)")
            // The settings in use are not on disk: the user is told, not only
            // the log (TODO S09). A retry saves the settings as they are then,
            // the same ones unless a later change has saved them itself.
            PersistenceFailureCenter.shared.recordFailure(
                .configuration,
                path: fileURL.path,
                error: error
            ) { [weak self] _ in
                self?.saveToDisk()
            }
            return
        }
        recordAgreement(data)
        // The atomic write replaced the watched file. Follow the new one now
        // rather than when its event arrives, leaving no moment unwatched.
        rearmWatcher()
    }

    /// Records that config.json holds `data`, the bytes of `config`: the
    /// watcher ignores these bytes, the next merge starts from `config`, and
    /// the settings are saved, which settles any earlier failed save.
    private func recordAgreement(_ data: Data) {
        lastHandledContents = data
        lastSyncedConfig = config
        PersistenceFailureCenter.shared.recordSuccess(.configuration)
    }

    /// config.json's current bytes, or nil when there is no file or it
    /// cannot be read.
    private func readFileContents() -> Data? {
        try? Data(contentsOf: fileURL)
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
    private func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            loadedFile = .missing
            return
        }
        do {
            let contents = try Data(contentsOf: fileURL)
            lastHandledContents = contents
            let decoded = try Self.decode(contents)
            if decoded != config {
                config = decoded
            }
            lastSyncedConfig = decoded
            loadedFile = .decoded
        } catch {
            loadedFile = .unreadable
            logUnreadableFile(error)
        }
    }

    /// Decodes config.json's bytes. The decoder is lenient: a single bad
    /// value is repaired and logged rather than failing the whole file.
    nonisolated static func decode(_ contents: Data) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: contents)
    }

    // MARK: - External Edits

    /// Applies config.json's `contents` as an edit made outside TextMouth:
    /// `config` takes the whole snapshot, which is then published once. A
    /// file that cannot be decoded changes nothing and stays on disk as it
    /// is, for whoever edited it to correct; the debug log says why, once,
    /// since the same bytes are not examined twice.
    private func applyExternalEdit(_ contents: Data) {
        lastHandledContents = contents
        let edited: AppConfig
        do {
            edited = try Self.decode(contents)
        } catch {
            logUnreadableFile(error)
            return
        }
        lastSyncedConfig = edited
        adopt(edited)
        // A value the file could not hold as written was repaired. Writing
        // the repaired snapshot once makes the file show the value in use;
        // the watcher recognizes that write as TextMouth's own. Otherwise the
        // file stays exactly as its editor saved it.
        if Self.decodingRepairedValues(in: contents, decoded: edited) {
            saveToDisk()
        }
    }

    /// Whether decoding `contents` into `decoded` changed a value the file
    /// states: a number clamped into range, an unsupported choice dropped, or
    /// a value of the wrong type replaced. Layout, missing and null fields,
    /// and keys TextMouth does not use are not repairs, so a hand-edited
    /// file is never rewritten for its form alone.
    nonisolated static func decodingRepairedValues(in contents: Data, decoded: AppConfig) -> Bool {
        // Contents that only the lenient decoder could read, such as a number
        // too large to represent, had something replaced.
        guard let stated = (try? JSONSerialization.jsonObject(with: contents)) as? [String: Any] else {
            return true
        }
        guard let used = try? jsonFields(of: decoded) else {
            return false
        }
        return stated.contains { key, value in
            guard !(value is NSNull), let usedValue = used[key] else {
                return false
            }
            return !sameJSONValue(value, usedValue)
        }
    }

    /// Folds in an edit that reached config.json after this process last
    /// wrote or read it, which the watcher has not handled yet because its
    /// events are still settling. The save about to happen would otherwise
    /// replace it unseen.
    ///
    /// The merged snapshot is published like any external edit, so the
    /// preferences take the edit's values too. Contents that cannot be
    /// decoded are logged; the save then replaces them.
    private func mergeUnhandledEdit(_ contents: Data) {
        lastHandledContents = contents
        let edited: AppConfig
        do {
            edited = try Self.decode(contents)
        } catch {
            log("saving over \(fileURL.path), which could not be read. \(Self.failureReason(error))")
            return
        }
        // Without a known base, the edit on disk is taken whole.
        adopt(Self.merging(ours: config, theirs: edited, base: lastSyncedConfig ?? config))
    }

    /// Makes `snapshot`, which came from the file, the configuration in use,
    /// and publishes it once.
    private func adopt(_ snapshot: AppConfig) {
        config = snapshot
        externalEdits.send(snapshot)
    }

    /// Combines an edit found on disk (`theirs`) with the changes this
    /// process made since it last agreed with the file (`base`): a field this
    /// process changed keeps its value, and every other field takes the
    /// edit's. When both changed a field, this process's value wins, being
    /// the later change: the edit was already on disk when this process saved.
    ///
    /// Fields are compared as config.json holds them, so the merge follows
    /// `AppConfig`'s coding keys and needs no list of fields of its own.
    nonisolated static func merging(ours: AppConfig, theirs: AppConfig, base: AppConfig) -> AppConfig {
        guard let oursFields = try? jsonFields(of: ours),
              let baseFields = try? jsonFields(of: base),
              var mergedFields = try? jsonFields(of: theirs) else {
            return ours
        }
        for (key, value) in oursFields where !sameJSONValue(value, baseFields[key]) {
            mergedFields[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: mergedFields),
              let merged = try? decode(data) else {
            return ours
        }
        return merged
    }

    /// `config` as the JSON object config.json holds, keyed by field name.
    private nonisolated static func jsonFields(of config: AppConfig) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: fileData(for: config))
        guard let fields = object as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return fields
    }

    /// Whether two values that JSONSerialization produced are equal. They are
    /// all NSObjects, which compare by value; two missing values are equal.
    private nonisolated static func sameJSONValue(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs = lhs as? NSObject, let rhs = rhs as? NSObject else {
            return lhs == nil && rhs == nil
        }
        return lhs.isEqual(rhs)
    }

    // MARK: - File Watching

    /// Acts on a settled batch of file events: follows the file when it was
    /// replaced, and applies its contents when they hold an edit this process
    /// has neither written nor seen. The watcher calls this once a burst of
    /// events settles; tests call it directly.
    func handleFileEvent(_ event: DispatchSource.FileSystemEvent) {
        let contents = readFileContents()
        let actions = Self.watcherActions(
            for: event,
            fileContents: contents,
            lastHandledContents: lastHandledContents
        )
        // A file replaced again after the read above is checked once more
        // when the watcher attaches to it, so the order here loses nothing.
        if actions.rearm {
            rearmWatcher()
        }
        if actions.reload, let contents {
            applyExternalEdit(contents)
        }
    }

    /// Collects an event from the watched file's source, on the main actor.
    /// A replacement is followed at once, so no edit to the new file goes
    /// unreported while the burst settles; the batch goes to
    /// `handleFileEvent(_:)` once no further event has arrived for
    /// `coalescingDelay`.
    private func receiveFileEvent(_ event: DispatchSource.FileSystemEvent) {
        guard isWatching else { return }
        if Self.replacesWatchedFile(event) {
            rearmWatcher()
        }
        pendingEvents.formUnion(event)
        scheduleCheck()
    }

    /// Checks the file once `coalescingDelay` passes without a new event,
    /// handling every event collected until then as one batch: an editor's
    /// save arrives as several events, and a file written in place may be
    /// incomplete until they end.
    private func scheduleCheck() {
        pendingCheck?.cancel()
        pendingCheck = Task { [weak self, coalescingDelay] in
            try? await Task.sleep(for: coalescingDelay)
            guard !Task.isCancelled, let self else { return }
            let events = self.pendingEvents
            self.pendingEvents = []
            self.pendingCheck = nil
            self.handleFileEvent(events)
        }
    }

    /// Moves the watcher to the file now at `fileURL`.
    ///
    /// When no file is there, an editor may be partway through a save that
    /// removes or renames the old file before putting the new one in place,
    /// so the watcher looks again a few times before giving up until the
    /// next save.
    private func rearmWatcher() {
        guard isWatching else { return }
        if armWatcher() {
            rearmRetry?.cancel()
            rearmRetry = nil
            return
        }
        // The watched file is gone or renamed away: stop listening to it.
        disarm()
        guard rearmRetry == nil else { return }
        rearmRetry = Task { [weak self] in
            await self?.lookForMissingFile()
        }
    }

    /// Looks for the file after each of `rearmRetryDelays`, watching it as
    /// soon as it is back. Giving up is logged.
    private func lookForMissingFile() async {
        for delay in Self.rearmRetryDelays {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, isWatching else { return }
            if armWatcher() {
                rearmRetry = nil
                return
            }
        }
        rearmRetry = nil
        log("\(fileURL.path) is missing; watching resumes when TextMouth next saves the settings")
    }

    /// Attaches the watcher to the file now at `fileURL`, unless it already
    /// listens to that very file, and returns whether a file is watched.
    ///
    /// A newly attached file is checked once events settle: an edit saved
    /// before the watcher attached reports no event of its own, so the check
    /// is what keeps the moment between two watched files covered.
    @discardableResult
    private func armWatcher() -> Bool {
        // Identify the file before opening it. A replacement in between makes
        // the next rearm see a different file and open it again: one open too
        // many at worst, never an edit missed.
        guard let identity = FileIdentity(of: fileURL) else { return false }
        if watchedFile?.identity == identity { return true }
        let descriptor = fileOperations.openForEvents(fileURL.path)
        guard descriptor >= 0 else { return false }
        disarm()

        // The source delivers on the main queue, where all of the watcher's
        // state lives: the handler only passes the event mask on, so nothing
        // is read from another thread.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: Self.watchedEvents,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.receiveFileEvent(source.data)
            }
        }
        // Dispatch runs this once the source has stopped using the
        // descriptor, the only safe moment to close it.
        let close = fileOperations.close
        source.setCancelHandler {
            MainActor.assumeIsolated {
                close(descriptor)
            }
        }
        source.resume()
        watchedFile = WatchedFile(identity: identity, source: source)
        scheduleCheck()
        return true
    }

    /// Stops listening to the watched file. Cancelling its source closes the
    /// descriptor, and releases the handlers that hold the source.
    private func disarm() {
        watchedFile?.source.cancel()
        watchedFile = nil
    }

    // MARK: - Diagnostics

    /// Records a config.json event in the console and the debug log.
    private func log(_ message: String) {
        let line = "CONFIG_FILE: \(message)"
        print(line)
        TextMouthPaths.appendLog(to: TextMouthPaths.debugLogFile, message: line)
    }

    /// Records that config.json could not be used, and that the settings in
    /// use were kept.
    private func logUnreadableFile(_ error: Error) {
        log("could not read \(fileURL.path); keeping the settings in use. \(Self.failureReason(error))")
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
