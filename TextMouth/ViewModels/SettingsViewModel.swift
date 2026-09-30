import SwiftUI
import AVFoundation
import Combine

/// Units for rewind-on-resume
enum RewindUnit: String, CaseIterable, Codable {
    case none = "None"
    case sentence = "Sentence"
    case paragraph = "Paragraph"
    case heading = "Heading"
}

/// What happens when a book ends
enum EndOfBookBehavior: String, CaseIterable, Codable {
    case stop = "Stop"
    case loop = "Loop to Start"
    case continueNext = "Continue to Next Book"

    static func effective(localRawValue: String?, global: Self) -> Self {
        localRawValue.flatMap(Self.init(rawValue:)) ?? global
    }
}

/// Units for skip forward / skip backward
enum SkipUnit: String, CaseIterable, Codable {
    case seconds10 = "10 seconds"
    case seconds15 = "15 seconds"
    case seconds30 = "30 seconds"
    case seconds60 = "60 seconds"
    case sentence = "Sentence"
    case paragraph = "Paragraph"
    case heading = "Heading"
    case subheading = "Subheading"
    case bookmark = "Bookmark"

    /// For time-based units, the number of words to skip at the given WPM rate.
    /// Returns nil for structural units (sentence, paragraph, heading, etc.).
    func wordCount(wpm: Double) -> Int? {
        switch self {
        case .seconds10: return max(1, Int(wpm * 10.0 / 60.0))
        case .seconds15: return max(1, Int(wpm * 15.0 / 60.0))
        case .seconds30: return max(1, Int(wpm * 30.0 / 60.0))
        case .seconds60: return max(1, Int(wpm * 60.0 / 60.0))
        case .sentence, .paragraph, .heading, .subheading, .bookmark: return nil
        }
    }

    var isTimeBased: Bool {
        switch self {
        case .seconds10, .seconds15, .seconds30, .seconds60: return true
        default: return false
        }
    }

    /// Number of seconds for time-based skip units
    var seconds: Int? {
        switch self {
        case .seconds10: return 10
        case .seconds15: return 15
        case .seconds30: return 30
        case .seconds60: return 60
        default: return nil
        }
    }

    /// Complete, non-duplicated label for a playback-bar navigation menu.
    /// The directionless form matches the shared menu; separate menus include
    /// their direction so VoiceOver users can distinguish them immediately.
    func playbackMenuAccessibilityLabel(direction: PlaybackSkipDirection? = nil) -> String {
        switch direction {
        case .forward:
            return "Forward navigation unit: \(rawValue)"
        case .backward:
            return "Backward navigation unit: \(rawValue)"
        case nil:
            return "Navigation unit: \(rawValue)"
        }
    }

    /// Advance through the same stable order shown by every navigation-unit
    /// picker, wrapping from Bookmark back to 10 seconds.
    var nextNavigationUnit: SkipUnit {
        guard let index = Self.allCases.firstIndex(of: self) else {
            return Self.allCases[0]
        }
        let nextIndex = Self.allCases.index(after: index)
        return nextIndex == Self.allCases.endIndex
            ? Self.allCases[0]
            : Self.allCases[nextIndex]
    }

    /// Return the direction-aware SF Symbol for a skip button. Keeping this
    /// mapping on the unit makes icon refresh behavior consistent everywhere.
    func iconName(forward: Bool) -> String {
        switch (self, forward) {
        case (.seconds10, false): return "gobackward.10"
        case (.seconds15, false): return "gobackward.15"
        case (.seconds30, false): return "gobackward.30"
        case (.seconds60, false): return "gobackward.60"
        case (.seconds10, true): return "goforward.10"
        case (.seconds15, true): return "goforward.15"
        case (.seconds30, true): return "goforward.30"
        case (.seconds60, true): return "goforward.60"
        case (.sentence, false): return "text.line.first.and.arrowtriangle.forward"
        case (.sentence, true): return "text.line.last.and.arrowtriangle.forward"
        case (.paragraph, false): return "text.justify.left"
        case (.paragraph, true): return "text.justify.right"
        case (.heading, false), (.subheading, false): return "backward.end.fill"
        case (.heading, true), (.subheading, true): return "forward.end.fill"
        case (.bookmark, _): return "bookmark.fill"
        }
    }
}

/// Identifies which navigation direction a separate playback-bar menu edits.
enum PlaybackSkipDirection: Equatable {
    case forward
    case backward
}

/// Controls whether per-book skip-unit menus appear in the playback bar.
/// The global forward/backward choices remain the fallback in every mode.
enum PlaybackNavigationUnitControlMode: String, CaseIterable, Codable {
    case none = "None (Use Global)"
    case shared = "One Shared Menu"
    case separate = "Menu for Each Button"

    /// Current user-facing wording. Raw values remain unchanged so existing
    /// AppStorage selections continue to decode after the control redesign.
    var displayName: String {
        switch self {
        case .none: return "None (Use Global)"
        case .shared: return "One Unit for Both Directions"
        case .separate: return "Separate Forward and Backward Units"
        }
    }
}

/// Pure policy for resolving global and per-book units under each playback-bar
/// presentation mode. Keeping this out of SwiftUI makes fallback behavior easy
/// to verify, including malformed values from manually edited book state.
enum PlaybackSkipUnitPolicy {
    static func resolve(
        mode: PlaybackNavigationUnitControlMode,
        localForwardRawValue: String?,
        localBackwardRawValue: String?,
        globalForward: SkipUnit,
        globalBackward: SkipUnit
    ) -> (forward: SkipUnit, backward: SkipUnit) {
        let localForward = localForwardRawValue.flatMap(SkipUnit.init(rawValue:))
        let localBackward = localBackwardRawValue.flatMap(SkipUnit.init(rawValue:))

        switch mode {
        case .none:
            return (globalForward, globalBackward)
        case .shared:
            let shared = localForward ?? localBackward ?? globalForward
            return (shared, shared)
        case .separate:
            return (localForward ?? globalForward, localBackward ?? globalBackward)
        }
    }
}

@MainActor
final class SettingsViewModel: ObservableObject {
    // MARK: - Stored preferences
    //
    // Every preference lives in one preferences store: the standard defaults
    // in the app, an isolated suite in tests. `init` binds each property to
    // that store under its key and default; validated preferences take both
    // from `SettingsPolicy`. `defaults write` can put any value under these
    // keys, so numeric preferences are stored privately and reach the rest of
    // the app only through the validating accessors further down.

    @AppStorage var selectedVoiceID: String {
        didSet { broadcastChanges(); syncToConfig() }
    }
    /// Stored speed; use `wordsPerMinute`.
    @AppStorage private var storedWordsPerMinute: Double {
        didSet { broadcastChanges(); syncToConfig() }
    }
    /// Stored pitch; use `pitchMultiplier`.
    @AppStorage private var storedPitchMultiplier: Double {
        didSet { broadcastChanges(); syncToConfig() }
    }
    @AppStorage var selectedLanguage: String {
        didSet { syncToConfig() }
    }
    @AppStorage var skipForwardUnitRaw: String {
        didSet { publishPlaybackControlsChange(); syncToConfig() }
    }
    @AppStorage var skipBackwardUnitRaw: String {
        didSet { publishPlaybackControlsChange(); syncToConfig() }
    }

    @AppStorage var shiftSkipForwardUnitRaw: String {
        didSet { syncToConfig() }
    }
    @AppStorage var shiftSkipBackwardUnitRaw: String {
        didSet { syncToConfig() }
    }

    @AppStorage var rewindOnResumeUnitRaw: String {
        didSet { syncToConfig() }
    }
    @AppStorage var rewindSmartMode: Bool {
        didSet { syncToConfig() }
    }
    /// Stored smart-rewind threshold; use `rewindSmartThreshold`.
    @AppStorage private var storedRewindSmartThreshold: Double {
        didSet { syncToConfig() }
    }
    /// Stored fade-out duration; use `sleepFadeOutDuration`.
    @AppStorage private var storedSleepFadeOutDuration: Double {
        didSet { syncToConfig() }
    }
    @AppStorage var sleepTimerAutoClose: Bool {
        didSet { syncToConfig() }
    }
    @AppStorage var endOfBookBehaviorRaw: String {
        didSet { syncToConfig() }
    }
    /// Stored punctuation pause level; use `punctuationPauseLevel`.
    @AppStorage private var storedPunctuationPauseLevel: Double {
        didSet { syncToConfig() }
    }
    @AppStorage var autoPlayOnNavigate: Bool {
        didSet { syncToConfig() }
    }
    @AppStorage var showBookmarkInPlaybackControls: Bool {
        didSet { publishPlaybackControlsChange() }
    }
    @AppStorage var showSpeedInPlaybackControls: Bool {
        didSet { publishPlaybackControlsChange() }
    }
    @AppStorage var playbackNavigationUnitControlModeRaw: String {
        didSet { publishPlaybackControlsChange() }
    }

    /// Whether to monitor Bluetooth device disconnections and suppress
    /// spurious media commands from macOS's rcd daemon.
    @AppStorage var bluetoothMonitoringEnabled: Bool {
        didSet { broadcastBluetoothChanges(); syncToConfig() }
    }
    /// Stored Bluetooth delay; use `bluetoothDisconnectDelay`.
    @AppStorage private var storedBluetoothDisconnectDelay: Double {
        didSet { broadcastBluetoothChanges(); syncToConfig() }
    }

    // MARK: - Restart Sleep Timer Gesture (Experimental)

    /// Whether the experimental media-gesture detector for restarting
    /// the sleep timer is active. Off by default — the feature is
    /// opt-in because it monitors every media-key press and could
    /// surprise users who just want their headphone buttons to do
    /// what they normally do.
    @AppStorage var restartTimerGestureEnabled: Bool {
        didSet { broadcastGestureChanges(); syncToConfig() }
    }
    /// Comma-separated event-type sequence (see `MediaGestureDetector.EventType`).
    /// Default "previousTrack,previousTrack,previousTrack" — three
    /// previous-track presses in a row, picked because it's
    /// vanishingly unlikely to occur accidentally during normal use.
    @AppStorage var restartTimerGesturePattern: String {
        didSet { broadcastGestureChanges(); syncToConfig() }
    }
    /// Stored gesture window; use `restartTimerGestureWindow`.
    @AppStorage private var storedRestartTimerGestureWindow: Double {
        didSet { broadcastGestureChanges(); syncToConfig() }
    }

    @Published var availableVoices: [AVSpeechSynthesisVoice] = []
    @Published var availableLanguages: [String] = []
    /// Changes whenever an option affecting the open playback bar changes.
    /// `PlaybackControlsView` observes this model directly, so incrementing the
    /// revision invalidates existing book windows without reopening them.
    @Published private(set) var playbackControlsSettingsRevision = 0

    private let configService: ConfigService
    private let notificationCenter: NotificationCenter
    private var configCancellable: AnyCancellable?
    /// True while config.json's values are applied, and while launch
    /// reconciles the preferences with the file: preference changes made
    /// then are not saved back to the file one at a time.
    private var isSyncingFromConfig = false

    // MARK: - Validated numeric preferences
    //
    // Consumers read these instead of the stored values. A read validates
    // whatever is stored and a write validates before storing, so every value
    // that leaves this model is one the Settings controls could produce.

    /// Global speech speed in words per minute.
    var wordsPerMinute: Double {
        get { SettingsPolicy.wordsPerMinute.validated(storedWordsPerMinute) }
        set { storedWordsPerMinute = SettingsPolicy.wordsPerMinute.validated(newValue) }
    }

    /// Global pitch multiplier; 1 is normal.
    var pitchMultiplier: Double {
        get { SettingsPolicy.pitchMultiplier.validated(storedPitchMultiplier) }
        set { storedPitchMultiplier = SettingsPolicy.pitchMultiplier.validated(newValue) }
    }

    /// Seconds a pause must last before smart rewind-on-resume rewinds.
    var rewindSmartThreshold: Double {
        get { SettingsPolicy.rewindSmartThreshold.validated(storedRewindSmartThreshold) }
        set { storedRewindSmartThreshold = SettingsPolicy.rewindSmartThreshold.validated(newValue) }
    }

    /// Seconds the sleep timer fades out before pausing; 0 pauses instantly.
    var sleepFadeOutDuration: Double {
        get { SettingsPolicy.sleepFadeOutDuration.validated(storedSleepFadeOutDuration) }
        set { storedSleepFadeOutDuration = SettingsPolicy.sleepFadeOutDuration.validated(newValue) }
    }

    /// Punctuation pause level: 0 off, 1 subtle, 2 moderate, 3 heavy.
    var punctuationPauseLevel: Double {
        get { SettingsPolicy.punctuationPauseLevel.validated(storedPunctuationPauseLevel) }
        set { storedPunctuationPauseLevel = SettingsPolicy.punctuationPauseLevel.validated(newValue) }
    }

    /// How long (in seconds) to suppress spurious media commands after
    /// a Bluetooth audio device disconnects. Range: 1–10, default 2.
    var bluetoothDisconnectDelay: Double {
        get { SettingsPolicy.bluetoothDisconnectDelay.validated(storedBluetoothDisconnectDelay) }
        set { storedBluetoothDisconnectDelay = SettingsPolicy.bluetoothDisconnectDelay.validated(newValue) }
    }

    /// Maximum total elapsed time (seconds) for the gesture to count
    /// as a match. 0.5–10s; 2.0 is the default — long enough for a
    /// deliberate sequence, short enough that real navigation use
    /// won't accidentally trigger.
    var restartTimerGestureWindow: Double {
        get { SettingsPolicy.restartTimerGestureWindow.validated(storedRestartTimerGestureWindow) }
        set { storedRestartTimerGestureWindow = SettingsPolicy.restartTimerGestureWindow.validated(newValue) }
    }

    // MARK: - Typed enum-backed preferences
    //
    // An unsupported stored raw value reads as the rule's default case.

    var skipForwardUnit: SkipUnit {
        get { SettingsPolicy.skipForwardUnit.value(fromRaw: skipForwardUnitRaw) }
        set { skipForwardUnitRaw = newValue.rawValue }
    }

    var skipBackwardUnit: SkipUnit {
        get { SettingsPolicy.skipBackwardUnit.value(fromRaw: skipBackwardUnitRaw) }
        set { skipBackwardUnitRaw = newValue.rawValue }
    }

    var shiftSkipForwardUnit: SkipUnit {
        get { SettingsPolicy.shiftSkipForwardUnit.value(fromRaw: shiftSkipForwardUnitRaw) }
        set { shiftSkipForwardUnitRaw = newValue.rawValue }
    }

    var shiftSkipBackwardUnit: SkipUnit {
        get { SettingsPolicy.shiftSkipBackwardUnit.value(fromRaw: shiftSkipBackwardUnitRaw) }
        set { shiftSkipBackwardUnitRaw = newValue.rawValue }
    }

    /// Typed view of the persisted playback-bar navigation control mode.
    var playbackNavigationUnitControlMode: PlaybackNavigationUnitControlMode {
        get { SettingsPolicy.playbackNavigationUnitControlMode.value(fromRaw: playbackNavigationUnitControlModeRaw) }
        set { playbackNavigationUnitControlModeRaw = newValue.rawValue }
    }

    var endOfBookBehavior: EndOfBookBehavior {
        get { SettingsPolicy.endOfBookBehavior.value(fromRaw: endOfBookBehaviorRaw) }
        set { endOfBookBehaviorRaw = newValue.rawValue }
    }

    var rewindOnResumeUnit: RewindUnit {
        get { SettingsPolicy.rewindOnResumeUnit.value(fromRaw: rewindOnResumeUnitRaw) }
        set { rewindOnResumeUnitRaw = newValue.rawValue }
    }

    /// Publish one coalescible settings-model change for open playback bars.
    /// The revision also gives tests a deterministic signal independent of
    /// SwiftUI's rendering schedule.
    private func publishPlaybackControlsChange() {
        playbackControlsSettingsRevision &+= 1
    }

    /// - Parameters:
    ///   - notificationCenter: Receives settings-change broadcasts.
    ///   - initializeServices: False skips voice discovery and config.json
    ///     synchronization, for tests.
    ///   - userDefaults: The store holding every preference. Tests pass an
    ///     isolated suite so they never read or change the user's settings.
    ///   - configService: The config.json mirror to keep in step with the
    ///     preferences. Tests pass one bound to a file of their own.
    init(
        notificationCenter: NotificationCenter = .default,
        initializeServices: Bool = true,
        userDefaults: UserDefaults = .standard,
        configService: ConfigService = .shared
    ) {
        self.notificationCenter = notificationCenter
        self.configService = configService
        // Bind every preference to `userDefaults` before anything reads one.
        // The keys are the ones every release has used, so saved preferences
        // keep loading.
        _selectedVoiceID = AppStorage(wrappedValue: "", "selectedVoiceID", store: userDefaults)
        _storedWordsPerMinute = SettingsPolicy.wordsPerMinute.appStorage(in: userDefaults)
        _storedPitchMultiplier = SettingsPolicy.pitchMultiplier.appStorage(in: userDefaults)
        _selectedLanguage = AppStorage(wrappedValue: "en", "selectedLanguage", store: userDefaults)
        _skipForwardUnitRaw = SettingsPolicy.skipForwardUnit.appStorage(in: userDefaults)
        _skipBackwardUnitRaw = SettingsPolicy.skipBackwardUnit.appStorage(in: userDefaults)
        _shiftSkipForwardUnitRaw = SettingsPolicy.shiftSkipForwardUnit.appStorage(in: userDefaults)
        _shiftSkipBackwardUnitRaw = SettingsPolicy.shiftSkipBackwardUnit.appStorage(in: userDefaults)
        _rewindOnResumeUnitRaw = SettingsPolicy.rewindOnResumeUnit.appStorage(in: userDefaults)
        _rewindSmartMode = AppStorage(wrappedValue: false, "rewindSmartMode", store: userDefaults)
        _storedRewindSmartThreshold = SettingsPolicy.rewindSmartThreshold.appStorage(in: userDefaults)
        _storedSleepFadeOutDuration = SettingsPolicy.sleepFadeOutDuration.appStorage(in: userDefaults)
        _sleepTimerAutoClose = AppStorage(wrappedValue: true, "sleepTimerAutoClose", store: userDefaults)
        _endOfBookBehaviorRaw = SettingsPolicy.endOfBookBehavior.appStorage(in: userDefaults)
        _storedPunctuationPauseLevel = SettingsPolicy.punctuationPauseLevel.appStorage(in: userDefaults)
        _autoPlayOnNavigate = AppStorage(wrappedValue: false, "autoPlayOnNavigate", store: userDefaults)
        _showBookmarkInPlaybackControls = AppStorage(
            wrappedValue: false, "showBookmarkInPlaybackControls", store: userDefaults
        )
        _showSpeedInPlaybackControls = AppStorage(
            wrappedValue: true, "showSpeedInPlaybackControls", store: userDefaults
        )
        _playbackNavigationUnitControlModeRaw =
            SettingsPolicy.playbackNavigationUnitControlMode.appStorage(in: userDefaults)
        _bluetoothMonitoringEnabled = AppStorage(
            wrappedValue: true, "bluetoothMonitoringEnabled", store: userDefaults
        )
        _storedBluetoothDisconnectDelay = SettingsPolicy.bluetoothDisconnectDelay.appStorage(in: userDefaults)
        _restartTimerGestureEnabled = AppStorage(
            wrappedValue: false, "restartTimerGestureEnabled", store: userDefaults
        )
        _restartTimerGesturePattern = AppStorage(
            wrappedValue: ConfigService.AppConfig.defaultRestartTimerGesturePattern, "restartTimerGesturePattern",
            store: userDefaults
        )
        _storedRestartTimerGestureWindow = SettingsPolicy.restartTimerGestureWindow.appStorage(in: userDefaults)
        guard initializeServices else { return }
        startConfigSync()
    }

    /// Reconciles the preferences with config.json at launch, then watches
    /// the file for edits made outside TextMouth.
    ///
    /// `ConfigService` read the file when it was created, so its snapshot is
    /// complete before anything here runs. The file's values are applied
    /// first, as one snapshot, because the file is where settings can be
    /// edited while TextMouth is closed. Voice discovery follows, so a default
    /// voice is chosen only when neither the file nor the preferences name
    /// one. No preference change in between is saved on its own: the
    /// preferences are saved once at the end, which writes only when the
    /// file's bytes change, so a launch on a consistent file writes nothing.
    private func startConfigSync() {
        withoutSyncingToConfig {
            if configService.hasExistingConfig {
                applyConfigChanges(configService.config)
            }
            refreshVoices()
        }
        writePreferences(into: &configService.config)
        // A file that could not be read is someone's edit in progress. It
        // stays on disk to be corrected; the watcher applies the correction.
        if configService.loadedFile != .unreadable {
            configService.saveToDisk()
        }
        configService.startWatching()
        observeExternalEdits()
    }

    func refreshVoices() {
        let allVoices = SpeechService.availableVoices()
        let languages = Set(allVoices.map { String($0.language.prefix(2)) })
        availableLanguages = languages.sorted()

        if selectedLanguage.isEmpty {
            availableVoices = allVoices
        } else {
            availableVoices = allVoices.filter { $0.language.hasPrefix(selectedLanguage) }
        }

        if selectedVoiceID.isEmpty, let defaultVoice = availableVoices.first {
            selectedVoiceID = defaultVoice.identifier
        }
    }

    var selectedVoice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(identifier: selectedVoiceID)
    }

    func voiceQualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        voice.qualityLabel
    }

    // MARK: - Config Sync

    /// Push current AppStorage settings to config.json
    func syncToConfig() {
        guard !isSyncingFromConfig else { return }
        // One in-place update publishes a single complete snapshot.
        writePreferences(into: &configService.config)
        configService.saveToDisk()
    }

    /// Copies the mirrored preferences into `config`, leaving fields that
    /// other screens manage (import and deletion choices, the last opened
    /// book) as they are. Every value is the validated one consumers see, so
    /// a value injected with `defaults write` is written in its repaired form.
    func writePreferences(into config: inout ConfigService.AppConfig) {
        config.selectedVoiceID = selectedVoiceID
        config.wordsPerMinute = wordsPerMinute
        config.pitchMultiplier = pitchMultiplier
        config.selectedLanguage = selectedLanguage
        config.skipForwardUnit = skipForwardUnit.rawValue
        config.skipBackwardUnit = skipBackwardUnit.rawValue
        config.shiftSkipForwardUnit = shiftSkipForwardUnit.rawValue
        config.shiftSkipBackwardUnit = shiftSkipBackwardUnit.rawValue
        config.rewindOnResumeUnit = rewindOnResumeUnit.rawValue
        config.rewindSmartMode = rewindSmartMode
        config.rewindSmartThreshold = rewindSmartThreshold
        config.sleepFadeOutDuration = sleepFadeOutDuration
        config.sleepTimerAutoClose = sleepTimerAutoClose
        config.endOfBookBehavior = endOfBookBehavior.rawValue
        config.punctuationPauseLevel = punctuationPauseLevel
        config.autoPlayOnNavigate = autoPlayOnNavigate
        config.bluetoothMonitoringEnabled = bluetoothMonitoringEnabled
        config.bluetoothDisconnectDelay = bluetoothDisconnectDelay
        config.restartTimerGestureEnabled = restartTimerGestureEnabled
        config.restartTimerGesturePattern = restartTimerGesturePattern
        config.restartTimerGestureWindow = restartTimerGestureWindow
        // Preserve dataDirectoryPath — it's managed by the Storage settings tab
        config.dataDirectoryPath = ConfigService.AppConfig.currentDataDirectoryPath
    }

    /// Runs `body` with `syncToConfig()` suspended, then restores the previous
    /// state rather than clearing it, so the scopes nest: the snapshot applied
    /// during launch reconciliation must not end the launch's suspension.
    private func withoutSyncingToConfig(_ body: () -> Void) {
        let wasSyncing = isSyncingFromConfig
        isSyncingFromConfig = true
        defer { isSyncingFromConfig = wasSyncing }
        body()
    }

    /// Applies each edit of config.json made outside TextMouth, once, as
    /// `ConfigService` publishes it. TextMouth's own saves are never sent
    /// back, and delivery is synchronous, so no stale snapshot can arrive
    /// after a newer change and roll a preference back.
    private func observeExternalEdits() {
        configCancellable = configService.externalEdits.sink { [weak self] config in
            self?.applyConfigChanges(config)
        }
    }

    /// Sync local @AppStorage properties from a config snapshot.
    /// Used both on initial load and when config.json is externally modified.
    ///
    /// Snapshots can be built in code as well as decoded, so every value
    /// passes through the same `SettingsPolicy` rules as the decoder: numbers
    /// are clamped before assignment, and an empty or unsupported choice, an
    /// unset speed or pitch, or empty text leaves the current preference alone.
    func applyConfigChanges(_ config: ConfigService.AppConfig) {
        withoutSyncingToConfig {
            adopt(config.selectedVoiceID.nonEmpty, into: \.selectedVoiceID)
            adopt(config.wordsPerMinute, rule: SettingsPolicy.wordsPerMinute, into: \.wordsPerMinute)
            adopt(config.pitchMultiplier, rule: SettingsPolicy.pitchMultiplier, into: \.pitchMultiplier)
            adopt(config.selectedLanguage.nonEmpty, into: \.selectedLanguage)
            adopt(config.skipForwardUnit, rule: SettingsPolicy.skipForwardUnit, into: \.skipForwardUnitRaw)
            adopt(config.skipBackwardUnit, rule: SettingsPolicy.skipBackwardUnit, into: \.skipBackwardUnitRaw)
            adopt(
                config.shiftSkipForwardUnit,
                rule: SettingsPolicy.shiftSkipForwardUnit,
                into: \.shiftSkipForwardUnitRaw
            )
            adopt(
                config.shiftSkipBackwardUnit,
                rule: SettingsPolicy.shiftSkipBackwardUnit,
                into: \.shiftSkipBackwardUnitRaw
            )
            adopt(config.rewindOnResumeUnit, rule: SettingsPolicy.rewindOnResumeUnit, into: \.rewindOnResumeUnitRaw)
            adopt(config.rewindSmartMode, into: \.rewindSmartMode)
            adopt(
                config.rewindSmartThreshold,
                rule: SettingsPolicy.rewindSmartThreshold,
                into: \.rewindSmartThreshold
            )
            adopt(
                config.sleepFadeOutDuration,
                rule: SettingsPolicy.sleepFadeOutDuration,
                into: \.sleepFadeOutDuration
            )
            adopt(config.sleepTimerAutoClose, into: \.sleepTimerAutoClose)
            adopt(config.endOfBookBehavior, rule: SettingsPolicy.endOfBookBehavior, into: \.endOfBookBehaviorRaw)
            adopt(
                config.punctuationPauseLevel,
                rule: SettingsPolicy.punctuationPauseLevel,
                into: \.punctuationPauseLevel
            )
            adopt(config.autoPlayOnNavigate, into: \.autoPlayOnNavigate)
            adopt(config.bluetoothMonitoringEnabled, into: \.bluetoothMonitoringEnabled)
            adopt(
                config.bluetoothDisconnectDelay,
                rule: SettingsPolicy.bluetoothDisconnectDelay,
                into: \.bluetoothDisconnectDelay
            )
            adopt(config.restartTimerGestureEnabled, into: \.restartTimerGestureEnabled)
            adopt(config.restartTimerGesturePattern.nonEmpty, into: \.restartTimerGesturePattern)
            adopt(
                config.restartTimerGestureWindow,
                rule: SettingsPolicy.restartTimerGestureWindow,
                into: \.restartTimerGestureWindow
            )
            // Handle external change to dataDirectoryPath
            if config.dataDirectoryPath != ConfigService.AppConfig.currentDataDirectoryPath {
                notificationCenter.post(
                    name: .dataDirectoryChangeRequested,
                    object: nil,
                    userInfo: ["path": config.dataDirectoryPath]
                )
            }
        }
    }

    /// Assigns a value config.json asks for, when it differs from the current
    /// one, so unchanged fields cause no didSet side effects. A nil request
    /// means the file leaves this preference alone.
    private func adopt<Value: Equatable>(
        _ requested: Value?,
        into keyPath: ReferenceWritableKeyPath<SettingsViewModel, Value>
    ) {
        guard let requested, self[keyPath: keyPath] != requested else { return }
        self[keyPath: keyPath] = requested
    }

    /// Adopts a config.json number validated by `rule`: clamped, or ignored
    /// when it means "not chosen yet".
    private func adopt(
        _ configValue: Double,
        rule: NumericSettingRule,
        into keyPath: ReferenceWritableKeyPath<SettingsViewModel, Double>
    ) {
        adopt(rule.requestedValue(fromConfig: configValue), into: keyPath)
    }

    /// Adopts a config.json raw value for an enum-backed preference, ignoring
    /// an empty or unsupported value.
    private func adopt<Choice>(
        _ configRawValue: String,
        rule: EnumSettingRule<Choice>,
        into keyPath: ReferenceWritableKeyPath<SettingsViewModel, String>
    ) {
        adopt(rule.requestedValue(fromConfig: configRawValue)?.rawValue, into: keyPath)
    }

    private func broadcastChanges() {
        notificationCenter.post(name: .speechSettingsChanged, object: nil)
    }

    private func broadcastBluetoothChanges() {
        notificationCenter.post(name: .bluetoothSettingsChanged, object: nil)
    }

    private func broadcastGestureChanges() {
        notificationCenter.post(name: .restartTimerGestureSettingsChanged, object: nil)
    }
}

// MARK: - Preference storage from the policy table

private extension NumericSettingRule {
    /// `@AppStorage` storage for this preference's key and default in `store`.
    @MainActor
    func appStorage(in store: UserDefaults) -> AppStorage<Double> {
        AppStorage(wrappedValue: defaultValue, key, store: store)
    }
}

private extension EnumSettingRule {
    /// `@AppStorage` storage for this preference's raw value in `store`,
    /// defaulting to the rule's default case.
    @MainActor
    func appStorage(in store: UserDefaults) -> AppStorage<String> {
        AppStorage(wrappedValue: defaultValue.rawValue, key, store: store)
    }
}

private extension String {
    /// nil for the empty string, which config.json uses for "not chosen yet".
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension Notification.Name {
    static let speechSettingsChanged = Notification.Name("speechSettingsChanged")
    static let bluetoothSettingsChanged = Notification.Name("bluetoothSettingsChanged")
    static let restartTimerGestureSettingsChanged = Notification.Name("restartTimerGestureSettingsChanged")
    static let dataDirectoryChangeRequested = Notification.Name("dataDirectoryChangeRequested")
}
