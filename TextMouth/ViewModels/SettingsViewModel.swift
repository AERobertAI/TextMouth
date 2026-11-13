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

/// What happens when a book ends, and what Play then does on the finished
/// book (`ReaderViewModel.handleEndOfBook()` and `playFromTheEnd()`, TODO
/// P07). Each raw value is the choice's name in the Playback tab's and a
/// book's own picker, which list every case in this order, and what
/// config.json and the book's record keep.
enum EndOfBookBehavior: String, CaseIterable, Codable {
    /// The book stops at its end, finished; Play then says "Finished:
    /// <title>" and does nothing else.
    case stop = "Stop"
    /// The book stops at its end, finished, as with Stop; Play then starts
    /// it over from its beginning, "Starting again: <title>". The user
    /// asked on October 10, 2026 for this choice beside the others, Play's
    /// starting over "not by default".
    case stopAndPlayStartsOver = "Stop, and Play Starts Over"
    /// The book plays again from its beginning, and is never finished.
    case loop = "Loop to Start"
    /// The next book in the folder plays.
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
    /// A page of the book (PG02), as the book numbers its pages. A book
    /// without pages has none to move by, and the unit cycle passes over it
    /// there (`ReaderViewModel.unit(after:bookHasPages:)`).
    case page = "Page"
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
        case .sentence, .paragraph, .page, .heading, .subheading, .bookmark: return nil
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
        case (.page, _): return "doc.text"
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
    /// Stored choice of where the next book opens; use `nextBookWindow`.
    @AppStorage var nextBookWindowRaw: String {
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
        didSet { publishPlaybackControlsChange(); syncToConfig() }
    }
    @AppStorage var showSpeedInPlaybackControls: Bool {
        didSet { publishPlaybackControlsChange(); syncToConfig() }
    }
    /// Whether the reader names the speed beside time left and total time
    /// (P08), in Playback settings: "3:44:01 left at 2.0x" for an audiobook
    /// not at 1x, "at 500 words a minute" for a text book. Off by default.
    /// Its change is published, so open readers follow it at once.
    @AppStorage var includeSpeedWithTimes: Bool {
        didSet { objectWillChange.send(); syncToConfig() }
    }
    /// Whether the reader screen shows the page being read, such as "Page 12
    /// of 300", beside the percent, for a book with pages (PG03), in
    /// Playback settings. On by default. Its change is published, so open
    /// readers follow it at once.
    @AppStorage var showsPageInReader: Bool {
        didSet { objectWillChange.send(); syncToConfig() }
    }
    /// Whether Where Am I?'s summaries, brief and full, say the page being
    /// read, such as "Page 112 of 300", for a book with pages (PG04), in
    /// Playback settings. On by default.
    @AppStorage var saysPageInWhereAmI: Bool {
        didSet { syncToConfig() }
    }
    @AppStorage var playbackNavigationUnitControlModeRaw: String {
        didSet { publishPlaybackControlsChange(); syncToConfig() }
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

    /// The voices the Voice picker offers: the shared catalog's voices for
    /// the language chosen (TODO PERF07).
    @Published var availableVoices: [AVSpeechSynthesisVoice] = []
    /// The languages the Language picker offers: the shared catalog's.
    @Published var availableLanguages: [String] = []
    /// The installed voices, listed once off the main thread and shared
    /// (TODO PERF07). This model only reads the list; it never lists voices
    /// itself.
    let voiceCatalog: VoiceCatalog
    /// Offers the catalog's list again whenever it lists the voices.
    private var voiceListSubscription: AnyCancellable?
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
    /// The store holding every preference, the ones other services keep
    /// included; the mirror reads and writes theirs there.
    private let preferences: UserDefaults
    /// Saves config.json when a preference another service keeps changes in
    /// the store through that service's own controls.
    private var servicePreferencesObserver: PreferenceObserver?
    /// Whether an import keeps the original of each audio file it converts
    /// (Storage settings). Like `importDeleteBehavior`, config.json is its
    /// only store: read from the configuration, saved there, and announced
    /// on every change, an edit of config.json included.
    var keepsOriginalOfConvertedAudio: Bool {
        get { configService.config.keepsOriginalOfConvertedAudio }
        set {
            guard newValue != configService.config.keepsOriginalOfConvertedAudio else { return }
            configService.config.keepsOriginalOfConvertedAudio = newValue
            configService.saveToDisk()
        }
    }

    /// Announces each change of a choice config.json alone holds.
    private var fileOnlyChoicesCancellable: AnyCancellable?

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

    /// Where the next book opens when listening goes on from one book to
    /// another: this window by default (0.2.5).
    var nextBookWindow: NextBookWindow {
        get { SettingsPolicy.nextBookWindow.value(fromRaw: nextBookWindowRaw) }
        set { nextBookWindowRaw = newValue.rawValue }
    }

    var rewindOnResumeUnit: RewindUnit {
        get { SettingsPolicy.rewindOnResumeUnit.value(fromRaw: rewindOnResumeUnitRaw) }
        set { rewindOnResumeUnitRaw = newValue.rawValue }
    }

    // MARK: - Choices config.json alone holds

    /// What happens to an original file after its book is imported (Storage
    /// settings). config.json is this choice's only store, so it is read
    /// from the configuration and saved there; the model announces every
    /// change to it, an edit of config.json included, so a control bound to
    /// it always shows the choice in force.
    var importDeleteBehavior: ImportDeleteBehavior {
        get { configService.config.importDeleteBehavior }
        set {
            guard newValue != configService.config.importDeleteBehavior else { return }
            configService.config.importDeleteBehavior = newValue
            configService.saveToDisk()
        }
    }

    /// Announces each change of a choice config.json alone holds, wherever
    /// it came from, as this model announces changes to its own preferences.
    private func announceFileOnlyChoiceChanges() {
        fileOnlyChoicesCancellable = configService.$config
            .map { ($0.importDeleteBehavior, $0.keepsOriginalOfConvertedAudio) }
            .removeDuplicates(by: ==)
            .dropFirst()
            .sink { [weak self] _ in self?.objectWillChange.send() }
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
    ///   - userDefaults: The store holding every preference: this process's
    ///     preferences, which are the standard store in the app and the
    ///     sandboxed one under hosted tests. Tests may pass a suite of their
    ///     own to start from known values, and services of their own on it.
    ///   - configService: The config.json mirror to keep in step with the
    ///     preferences. Tests pass one bound to a file of their own.
    ///   - voiceCatalog: Where the voices offered come from: the shared
    ///     catalog, unless a test passes its own.
    init(
        notificationCenter: NotificationCenter = .default,
        initializeServices: Bool = true,
        userDefaults: UserDefaults = TextMouthRuntime.current.preferences,
        configService: ConfigService = .shared,
        voiceCatalog: VoiceCatalog = .shared
    ) {
        self.notificationCenter = notificationCenter
        self.configService = configService
        self.voiceCatalog = voiceCatalog
        preferences = userDefaults
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
        _nextBookWindowRaw = SettingsPolicy.nextBookWindow.appStorage(in: userDefaults)
        _storedPunctuationPauseLevel = SettingsPolicy.punctuationPauseLevel.appStorage(in: userDefaults)
        _autoPlayOnNavigate = AppStorage(wrappedValue: false, "autoPlayOnNavigate", store: userDefaults)
        _showBookmarkInPlaybackControls = AppStorage(
            wrappedValue: false, "showBookmarkInPlaybackControls", store: userDefaults
        )
        _showSpeedInPlaybackControls = AppStorage(
            wrappedValue: true, "showSpeedInPlaybackControls", store: userDefaults
        )
        _includeSpeedWithTimes = AppStorage(wrappedValue: false, "includeSpeedWithTimes", store: userDefaults)
        _showsPageInReader = AppStorage(wrappedValue: true, "showsPageInReader", store: userDefaults)
        _saysPageInWhereAmI = AppStorage(wrappedValue: true, "saysPageInWhereAmI", store: userDefaults)
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
        saveServicePreferenceChanges()
        announceFileOnlyChoiceChanges()
        guard initializeServices else { return }
        startConfigSync()
    }

    /// Reconciles the preferences with config.json at launch, then watches
    /// the file for edits made outside TextMouth.
    ///
    /// `ConfigService` read the file when it was created, so its snapshot is
    /// complete before anything here runs. The file's values are applied
    /// first, as one snapshot, because the file is where settings can be
    /// edited while TextMouth is closed. The voices offered follow, from the
    /// shared catalog (TODO PERF07). A default voice is chosen only when
    /// neither the file nor the preferences name one, which is only on the
    /// first launch: that launch lists the voices at once, to choose it
    /// before anything else runs, as every launch used to. Every other launch
    /// lists none here; the catalog lists them off the main thread once the
    /// first window shows, and they are offered when they arrive. No
    /// preference change in between is saved on its own: the preferences are
    /// saved once at the end, which writes only when the file's bytes change,
    /// so a launch on a consistent file writes nothing.
    private func startConfigSync() {
        // Subscribe first: the save below merges in any edit that reached the
        // file since it was loaded, and publishes it for this model to apply.
        observeExternalEdits()
        withoutSyncingToConfig {
            applyFileAtLaunch()
            if selectedVoiceID.isEmpty {
                voiceCatalog.listNow()
            }
            refreshVoices()
        }
        observeVoiceCatalog()
        writePreferences(into: &configService.config)
        // A file that could not be read is someone's edit in progress. It
        // stays on disk to be corrected; the watcher applies the correction.
        if configService.loadedFile != .unreadable {
            configService.saveToDisk()
        }
        configService.startWatching()
    }

    /// Applies config.json as launch found it, when it could be read. First,
    /// at the first launch that finds no record of the shortcuts the user
    /// edited, the shortcuts saved before the record are moved into it
    /// (FR12): that move reads the file's shortcuts itself, so they are left
    /// out of what is applied then, since the old form's lists would make
    /// every action the user's. The launch's save then writes the new form.
    private func applyFileAtLaunch() {
        var fileConfig = configService.hasExistingConfig ? configService.config : nil
        let fileListings = fileConfig.map {
            SettingsPolicy.keyboardShortcuts.requestedValues(fromConfig: $0.keyboardShortcuts)
        }
        if KeyboardShortcutManager.moveSavedShortcutsIfNeeded(in: preferences, fileListings: fileListings) {
            fileConfig?.keyboardShortcuts = [:]
        }
        if let fileConfig {
            applyConfigChanges(fileConfig)
        }
    }

    /// Offers the catalog's voices for the language chosen (every voice when
    /// none is), with the catalog's languages, and chooses the first voice
    /// offered when no voice is chosen yet. It reads the shared list rather
    /// than listing voices (TODO PERF07), so a change of language costs a
    /// filter, not a listing; before the catalog's first list arrives it
    /// offers nothing.
    func refreshVoices() {
        availableLanguages = voiceCatalog.languages
        availableVoices = voiceCatalog.voices(forLanguage: selectedLanguage)

        if selectedVoiceID.isEmpty, let defaultVoice = availableVoices.first {
            selectedVoiceID = defaultVoice.identifier
        }
    }

    /// Offers the catalog's list each time it lists the voices: when its
    /// first list arrives after launch, and when the installed voices
    /// change.
    func observeVoiceCatalog() {
        voiceListSubscription = voiceCatalog.didList.sink { [weak self] in
            self?.refreshVoices()
        }
    }

    var selectedVoice: AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(identifier: selectedVoiceID)
    }

    func voiceQualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        voice.qualityLabel
    }

    // MARK: - Config Sync

    /// Push current AppStorage settings to config.json. The configuration
    /// takes them at once; the file once changes pause for a moment
    /// (`ConfigService.scheduleSave()`, PERF17), so a slider moved through
    /// its steps writes config.json once rather than at every step.
    func syncToConfig() {
        guard !isSyncingFromConfig else { return }
        // One in-place update publishes a single complete snapshot.
        writePreferences(into: &configService.config)
        configService.scheduleSave()
    }

    /// Copies the mirrored preferences into `config`, this model's own and
    /// those other services keep, leaving fields that other screens manage
    /// (import and deletion choices, the last opened book) as they are.
    /// Every value is the validated one consumers see, so a value injected
    /// with `defaults write` is written in its repaired form.
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
        config.nextBookWindow = nextBookWindow.rawValue
        config.punctuationPauseLevel = punctuationPauseLevel
        config.autoPlayOnNavigate = autoPlayOnNavigate
        config.bluetoothMonitoringEnabled = bluetoothMonitoringEnabled
        config.bluetoothDisconnectDelay = bluetoothDisconnectDelay
        config.restartTimerGestureEnabled = restartTimerGestureEnabled
        config.restartTimerGesturePattern = restartTimerGesturePattern
        config.restartTimerGestureWindow = restartTimerGestureWindow
        config.playbackNavigationUnitControlMode = playbackNavigationUnitControlMode.rawValue
        config.showBookmarkInPlaybackControls = showBookmarkInPlaybackControls
        config.showSpeedInPlaybackControls = showSpeedInPlaybackControls
        config.includeSpeedWithTimes = includeSpeedWithTimes
        config.showsPageInReader = showsPageInReader
        config.saysPageInWhereAmI = saysPageInWhereAmI
        writeServicePreferences(into: &config)
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
    /// unset speed or pitch, empty text, or a newer field the file leaves out
    /// (nil) leaves the current preference alone.
    ///
    /// When the snapshot's shortcuts gave one key to two edited actions,
    /// left to one of them now (FR12), config.json is saved again once this
    /// is applied, as after a repaired value, so the file shows the keys in
    /// force; at launch, the launch's own save does it.
    func applyConfigChanges(_ config: ConfigService.AppConfig) {
        var shortcutsWereRepaired = false
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
            adopt(config.nextBookWindow, rule: SettingsPolicy.nextBookWindow, into: \.nextBookWindowRaw)
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
            adopt(
                config.playbackNavigationUnitControlMode,
                rule: SettingsPolicy.playbackNavigationUnitControlMode,
                into: \.playbackNavigationUnitControlModeRaw
            )
            adopt(config.showBookmarkInPlaybackControls, into: \.showBookmarkInPlaybackControls)
            adopt(config.showSpeedInPlaybackControls, into: \.showSpeedInPlaybackControls)
            adopt(config.includeSpeedWithTimes, into: \.includeSpeedWithTimes)
            adopt(config.showsPageInReader, into: \.showsPageInReader)
            adopt(config.saysPageInWhereAmI, into: \.saysPageInWhereAmI)
            shortcutsWereRepaired = adoptServicePreferences(from: config)
            requestDataDirectoryMove(to: config.dataDirectoryPath)
        }
        if shortcutsWereRepaired {
            syncToConfig()
        }
    }

    /// Asks the library to move to the data directory config.json names,
    /// when that differs from the one in use and is a place this Mac can
    /// move it to (FR02). config.json can come from another Mac, through a
    /// library in the cloud, naming that Mac's data directory: a location
    /// missing here, or one that holds a library already, is ignored with
    /// one debug log line (`DataDirectoryRequest`). Storage settings remain
    /// the way to move the library on purpose.
    private func requestDataDirectoryMove(to requestedPath: String) {
        guard requestedPath != ConfigService.AppConfig.currentDataDirectoryPath else { return }
        let target = requestedPath.isEmpty
            ? TextMouthPaths.defaultRoot
            : URL(fileURLWithPath: requestedPath, isDirectory: true)
        if let reason = DataDirectoryRequest.reasonToIgnore(target) {
            DiagnosticLog.event(
                .storage,
                "CONFIG_FILE: ignored the dataDirectoryPath \(DataDirectoryPaths.shortName(of: target)), "
                    + "since \(reason); the data directory stays where it is"
            )
            return
        }
        notificationCenter.post(
            name: .dataDirectoryChangeRequested,
            object: nil,
            userInfo: ["path": requestedPath]
        )
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

    // MARK: - Preferences other services keep
    //
    // The sound effects service, the substitution service, recording (the
    // Record window), audio editing (the original policy), the shortcut manager,
    // the log writer, transcription, and Export keep their preferences in
    // the same store as this model, and follow them there. The mirror reads
    // and writes them there through each service's own definitions: a value
    // applied from config.json reaches its service at once, and a change
    // made through a service's controls is saved to config.json by the
    // observer below.

    /// The store keys of the preferences other services keep.
    static var servicePreferenceKeys: [String] {
        // The list is built in two parts, because the compiler cannot
        // type-check one sum of this many arrays in reasonable time.
        let earlier: [String] = SoundEffectService.preferenceKeys
            + FeedSettings.preferenceKeys
            + TextSubstitutionService.preferenceKeys
            + RecordingPreferences.keys
            + AudioEditingPreferences.keys
            + [KeyboardShortcutManager.editsPreference.key, LogLocation.preference.key]
            + [KeyboardShortcutManager.doublePressTimePreference.key]
            + [TranscriptionLanguage.preference.key, TranscriptionPreferences.offerAfterImport.key]
            // The Library window's views share the Export button's array: one
            // more sum here takes the type checker past its time limit.
            + [BookExportPreferences.showInReaderToolbar.key, LibraryViewDefinitionStore.preference.key]
        // What a title's leading article does in the Library's lists
        // (November 13, 2026), typed apart to keep the sum below quick.
        let library: [String] = [LeadingArticles.preference.key]
        return earlier + [BraillePreferences.table.key]
            + [BraillePreferences.fileCode.key]
            + library
    }

    /// The keys of the preferences other services keep that this model
    /// shows (the log location, the reader toolbar's Export button, the
    /// feed settings, the transcription settings, the braille table, the
    /// braille file characters, and the Library's leading articles), whose
    /// changes it announces wherever they are made, such as in config.json,
    /// so the controls showing them, and the Library windows, follow.
    private static let shownServicePreferenceKeys = Set([
        LogLocation.preference.key,
        BookExportPreferences.showInReaderToolbar.key,
        TranscriptionLanguage.preference.key,
        TranscriptionPreferences.offerAfterImport.key,
        BraillePreferences.table.key,
        BraillePreferences.fileCode.key,
        LeadingArticles.preference.key,
    ] + FeedSettings.preferenceKeys)

    /// The language transcription uses (FR05), in Playback settings'
    /// Transcription group, as a locale identifier. Transcription keeps it
    /// (`TranscriptionLanguage`), and config.json follows it through the
    /// observer below, which also announces a change made anywhere else.
    var transcriptionLanguage: String {
        get { TranscriptionLanguage.preference.read(from: preferences) }
        set {
            guard let chosen = TranscriptionLanguage.validated(newValue), chosen != transcriptionLanguage else { return }
            objectWillChange.send()
            TranscriptionLanguage.preference.write(chosen, to: preferences)
        }
    }

    /// The braille table braille files are read and written with (FMT21),
    /// by its stored value, such as "en-ueb-g2.ctb", or "mac:fr-bfu-g2.ctb"
    /// for one of this Mac's tables. Imports read it (`BraillePreferences`),
    /// and config.json follows it through the observer below, which also
    /// announces a change made anywhere else. A value no offered table has
    /// changes nothing; the Braille tab's pop-ups set a Mac table only once
    /// its check passes (`BrailleTablePickers`).
    var brailleTable: String {
        get { BraillePreferences.table.read(from: preferences) }
        set {
            guard let chosen = BrailleTableCatalog.table(withID: newValue)?.id, chosen != brailleTable else { return }
            objectWillChange.send()
            BraillePreferences.table.write(chosen, to: preferences)
        }
    }

    /// The braille file characters imports read a BRF or BRL file with
    /// (braillecodes), by the code's id, such as "ascii-na" for North
    /// American Braille ASCII or "ascii-eurobraille". Imports read it
    /// (`BraillePreferences.importFileCode()`), and Export's braille options
    /// start from it; config.json follows it through the observer below,
    /// which also announces a change made anywhere else. A value that is not
    /// one of the import's choices (`BrailleFileCode.importChoices`, the
    /// seven-bit codes; Unicode braille patterns are recognized, never
    /// chosen), or the one already chosen, changes nothing.
    var brailleFileCode: String {
        get { BraillePreferences.fileCode.read(from: preferences) }
        set {
            guard let chosen = BrailleFileCode.importChoice(withID: newValue)?.id, chosen != brailleFileCode else { return }
            objectWillChange.send()
            BraillePreferences.fileCode.write(chosen, to: preferences)
        }
    }

    /// Whether TextMouth offers to transcribe each audiobook just imported
    /// (FR05), in Playback settings' Transcription group. Imports read it
    /// (`TranscriptionPreferences.offerAfterImport`), and config.json
    /// follows it through the observer below.
    var offerTranscriptionAfterImport: Bool {
        get { TranscriptionPreferences.offerAfterImport.read(from: preferences) }
        set {
            guard newValue != offerTranscriptionAfterImport else { return }
            objectWillChange.send()
            TranscriptionPreferences.offerAfterImport.write(newValue, to: preferences)
        }
    }

    /// Whether the reader's toolbar shows an Export button (FR05), in
    /// Playback settings. Export keeps it (`BookExportPreferences`), and
    /// config.json follows it through the observer below, which also
    /// announces a change made anywhere else, so open readers show or hide
    /// the button at once.
    var showExportInReaderToolbar: Bool {
        get { BookExportPreferences.showInReaderToolbar.read(from: preferences) }
        set {
            guard newValue != showExportInReaderToolbar else { return }
            objectWillChange.send()
            BookExportPreferences.showInReaderToolbar.write(newValue, to: preferences)
        }
    }

    /// Where the diagnostic logs are written (Storage settings' Logs group).
    /// The log writer reads it from the store for every line
    /// (`LogLocation.preference`), so a change applies to the next line
    /// written; config.json follows it through the observer below, which
    /// also announces a change made anywhere else, such as in config.json,
    /// so the picker always shows the choice in force.
    var logLocation: LogLocation {
        get { LogLocation.preference.read(from: preferences) }
        set {
            guard newValue != logLocation else { return }
            objectWillChange.send()
            LogLocation.preference.write(newValue, to: preferences)
        }
    }

    /// What a title's leading article does in the Library's lists (the
    /// Library tab's Leading articles pop-up, November 13, 2026). The
    /// Library windows read it from the store (`LeadingArticles.preference`)
    /// as they draw; config.json follows it through the observer below,
    /// which also announces a change made anywhere else, such as in
    /// config.json, so the pop-up and every open Library window follow it.
    var leadingArticles: LeadingArticles {
        get { LeadingArticles.preference.read(from: preferences) }
        set {
            guard newValue != leadingArticles else { return }
            objectWillChange.send()
            LeadingArticles.preference.write(newValue, to: preferences)
        }
    }

    /// The feed reader's settings (FR03), which the feed engine reads from
    /// the store (`FeedSettings`), for the Preferences section to show and
    /// change. A change is saved to the store at once, setting by setting,
    /// and config.json follows it through the observer below, which also
    /// announces a change made anywhere else, such as in config.json, so the
    /// section always shows the settings in force.
    var feedSettings: FeedSettings {
        get { FeedSettings.read(from: preferences) }
        set {
            guard newValue != feedSettings else { return }
            objectWillChange.send()
            newValue.write(to: preferences)
        }
    }

    /// Saves config.json whenever a preference another service keeps changes
    /// in the store. A change this model makes while applying config.json
    /// saves nothing, like every other change made then. A change of a
    /// preference this model shows, the log location, the reader toolbar's
    /// Export button, a feed setting, a transcription setting, the braille
    /// table, or the braille file characters, is announced, so Storage
    /// settings, Playback settings, the feed settings, the Braille tab, and
    /// open readers follow it wherever it was made.
    private func saveServicePreferenceChanges() {
        servicePreferencesObserver = PreferenceObserver(keys: Self.servicePreferenceKeys, in: preferences) { [weak self] key in
            if Self.shownServicePreferenceKeys.contains(key) {
                self?.objectWillChange.send()
            }
            self?.syncToConfig()
        }
    }

    /// Copies the preferences other services keep into `config`, in the
    /// readable forms config.json holds them in.
    private func writeServicePreferences(into config: inout ConfigService.AppConfig) {
        config.soundEffectsEnabled = SoundEffectService.enabledPreference.read(from: preferences)
        config.soundEffectsVolume = Self.fileVolume(SoundEffectService.volumePreference.read(from: preferences))
        config.soundEffectAssignments = SettingsPolicy.soundEffectAssignments.fileEntries(
            SoundEffectService.assignmentsNamingEveryEvent(SoundEffectService.assignmentsPreference.read(from: preferences))
        )
        let feeds = FeedSettings.read(from: preferences)
        config.feedRefreshAtLaunch = feeds.refreshAtLaunch
        config.feedRefreshIntervalHours = feeds.refreshIntervalHours
        config.feedItems = feeds.itemPolicy.choice.rawValue
        config.feedNewestCount = feeds.itemPolicy.newestCount
        config.feedDeleteDownloadsDaysAfterPlayed = feeds.deleteDownloadsDaysAfterPlayed
        config.feedRefreshAlert = feeds.refreshAlert
        config.feedNotifications = feeds.notifications
        config.substitutionsEnabled = TextSubstitutionService.enabledPreference.read(from: preferences)
        config.repeatedSymbolStyle = TextSubstitutionService.repeatedSymbolStylePreference.read(from: preferences).rawValue
        config.repeatedSymbolThreshold = TextSubstitutionService.repeatedSymbolThresholdPreference.read(from: preferences)
        config.repeatedSymbolSet = TextSubstitutionService.repeatedSymbolSetPreference.read(from: preferences)
        config.recordingInputDeviceID = RecordingInputChoice.preference.read(from: preferences)
        config.recordingAnnouncesLevel = RecordingLevelAnnouncements.enabled.read(from: preferences)
        config.recordingLevelAnnouncementSeconds = Double(RecordingLevelAnnouncements.interval.read(from: preferences))
        config.recordingOriginalPolicy = AudioOriginalPolicy.choicePreference.read(from: preferences).rawValue
        config.recordingOriginalDays = AudioOriginalPolicy.daysPreference.read(from: preferences)
        config.useInstalledFFmpeg = AudioFilterEngine.usePreference.read(from: preferences)
        config.audioEditorPreviewsFilters = AudioEditorPreferences.previewFiltersFirst.read(from: preferences)
        config.audioEditorPlaysAfterMoves = AudioEditorPreferences.playAfterMoves.read(from: preferences)
        config.showExportInReaderToolbar = BookExportPreferences.showInReaderToolbar.read(from: preferences)
        // Every action: an edited one as the list of its keys, or as an
        // object of its keys and where they work when the user chose that
        // (FR12's branch E), every other as "default: " and its keys in
        // force (FR12).
        config.keyboardShortcuts = SettingsPolicy.keyboardShortcuts.fileEntries(
            KeyboardShortcutManager.editsPreference.read(from: preferences).listings(defaults: ShortcutAction.defaultBindings)
        )
        config.shortcutDoublePressSeconds = KeyboardShortcutManager.doublePressTimePreference.read(from: preferences)
        config.logLocation = LogLocation.preference.read(from: preferences).rawValue
        config.transcriptionLocale = TranscriptionLanguage.preference.read(from: preferences)
        config.offerTranscriptionAfterImport = TranscriptionPreferences.offerAfterImport.read(from: preferences)
        // The Library window's views, every one, as the views store keeps them.
        config.libraryViews = LibraryViewDefinitionStore.preference.read(from: preferences).fileEntries
        // What a title's leading article does in the Library's lists.
        config.leadingArticles = LeadingArticles.preference.read(from: preferences).rawValue
        #if os(iOS)
        // The iPhone bundles no tables, so the Mac's default is not one it
        // accepts: config.json would keep it, and decoding would repair it to
        // empty and log it at every launch. Empty is the file's "keep the
        // current choice".
        config.brailleTable = PhoneDefaults.configBrailleTable(for: BraillePreferences.table.read(from: preferences))
        #else
        config.brailleTable = BraillePreferences.table.read(from: preferences)
        #endif
        config.brailleFileCode = BraillePreferences.fileCode.read(from: preferences)
    }

    /// Writes the values config.json asks for into the store, where their
    /// services take them up, through the same rules the decoder applies.
    /// Returns whether the shortcuts gave one key to two edited actions,
    /// settled now (FR12), so the file is to be saved again.
    private func adoptServicePreferences(from config: ConfigService.AppConfig) -> Bool {
        adopt(config.soundEffectsEnabled, into: SoundEffectService.enabledPreference)
        let volume = config.soundEffectsVolume.flatMap { SettingsPolicy.soundEffectsVolume.requestedValue(fromConfig: $0) }
        adopt(volume.map { Float($0) }, into: SoundEffectService.volumePreference)
        adopt(
            entries: SettingsPolicy.soundEffectAssignments.requestedValues(fromConfig: config.soundEffectAssignments),
            into: SoundEffectService.assignmentsPreference
        )
        adopt(config.feedRefreshAtLaunch, into: FeedSettings.refreshAtLaunchPreference)
        adopt(
            config.feedRefreshIntervalHours.map { SettingsPolicy.feedRefreshIntervalHours.validated($0) },
            into: FeedSettings.refreshIntervalHoursPreference
        )
        adopt(SettingsPolicy.feedItems.requestedValue(fromConfig: config.feedItems), into: FeedSettings.itemsPreference)
        adopt(config.feedNewestCount.map { SettingsPolicy.feedNewestCount.validated($0) }, into: FeedSettings.newestCountPreference)
        adopt(
            config.feedDeleteDownloadsDaysAfterPlayed.map { SettingsPolicy.feedDeleteDownloadsDaysAfterPlayed.validated($0) },
            into: FeedSettings.deleteDownloadsDaysAfterPlayedPreference
        )
        adopt(config.feedRefreshAlert, into: FeedSettings.refreshAlertPreference)
        adopt(config.feedNotifications, into: FeedSettings.notificationsPreference)
        adopt(config.substitutionsEnabled, into: TextSubstitutionService.enabledPreference)
        adopt(
            SettingsPolicy.repeatedSymbolStyle.requestedValue(fromConfig: config.repeatedSymbolStyle),
            into: TextSubstitutionService.repeatedSymbolStylePreference
        )
        adopt(
            config.repeatedSymbolThreshold.map { SettingsPolicy.repeatedSymbolThreshold.validated($0) },
            into: TextSubstitutionService.repeatedSymbolThresholdPreference
        )
        // Empty symbols, like any empty text in the file, leave the current
        // ones alone.
        adopt(
            config.repeatedSymbolSet.map { SettingsPolicy.repeatedSymbolSet.validated($0) }.flatMap(\.nonEmpty),
            into: TextSubstitutionService.repeatedSymbolSetPreference
        )
        // Empty, like any empty text in the file, keeps the microphone chosen.
        adopt(config.recordingInputDeviceID.nonEmpty, into: RecordingInputChoice.preference)
        adopt(config.recordingAnnouncesLevel, into: RecordingLevelAnnouncements.enabled)
        adopt(
            config.recordingLevelAnnouncementSeconds
                .flatMap { SettingsPolicy.recordingLevelAnnouncementSeconds.requestedValue(fromConfig: $0) }
                .map { Int($0.rounded()) },
            into: RecordingLevelAnnouncements.interval
        )
        adopt(
            SettingsPolicy.recordingOriginalPolicy.requestedValue(fromConfig: config.recordingOriginalPolicy),
            into: AudioOriginalPolicy.choicePreference
        )
        adopt(
            config.recordingOriginalDays.flatMap { SettingsPolicy.recordingOriginalDays.requestedValue(fromConfig: $0) },
            into: AudioOriginalPolicy.daysPreference
        )
        adopt(config.useInstalledFFmpeg, into: AudioFilterEngine.usePreference)
        adopt(config.audioEditorPreviewsFilters, into: AudioEditorPreferences.previewFiltersFirst)
        adopt(config.audioEditorPlaysAfterMoves, into: AudioEditorPreferences.playAfterMoves)
        adopt(config.showExportInReaderToolbar, into: BookExportPreferences.showInReaderToolbar)
        // A list or an object makes its action the user's, "default" gives
        // it back, and a key two edited actions then hold goes to one (FR12).
        let shortcutsWereRepaired = KeyboardShortcutManager.adopt(
            SettingsPolicy.keyboardShortcuts.requestedValues(fromConfig: config.keyboardShortcuts),
            in: preferences
        )
        // The double-press time, in range and in tenths, as decoding left it.
        adopt(
            config.shortcutDoublePressSeconds.map(SettingsPolicy.validatedDoublePressSeconds),
            into: KeyboardShortcutManager.doublePressTimePreference
        )
        // An empty or unsupported choice leaves the current one alone.
        adopt(SettingsPolicy.logLocation.requestedValue(fromConfig: config.logLocation), into: LogLocation.preference)
        // So does an empty language, or one that cannot be an identifier.
        adopt(TranscriptionLanguage.validated(config.transcriptionLocale), into: TranscriptionLanguage.preference)
        adopt(config.offerTranscriptionAfterImport, into: TranscriptionPreferences.offerAfterImport)
        // The Library window's views: the list reads each entry on its own,
        // keeps the ones it cannot read as they are, and logs its repairs as
        // config.json's; no key, or an empty list, leaves the views alone.
        adopt(
            config.libraryViews.flatMap { entries in
                entries.isEmpty ? nil : LibraryViewDefinitionList(fileEntries: entries, logRepairsAs: "config.json")
            },
            into: LibraryViewDefinitionStore.preference
        )
        // An empty or unsupported leading-articles choice leaves the
        // current one alone.
        adopt(SettingsPolicy.leadingArticles.requestedValue(fromConfig: config.leadingArticles), into: LeadingArticles.preference)
        // An empty or unknown table name leaves the current table alone; a
        // Mac table's value is taken without reading this Mac's tables
        // (review R3), and refused by name when it is used if the Mac lacks it.
        adopt(BrailleTableCatalog.storableValue(config.brailleTable), into: BraillePreferences.table)
        // An empty id, or one this TextMouth lacks, leaves the current braille
        // file characters alone.
        adopt(BrailleFileCode.importChoice(withID: config.brailleFileCode)?.id, into: BraillePreferences.fileCode)
        return shortcutsWereRepaired
    }

    /// Writes a value config.json asks for into the store when it differs
    /// from the one there; nil leaves the preference alone.
    private func adopt<Value>(_ requested: Value?, into preference: StoredPreference<Value>) {
        guard let requested, preference.read(from: preferences) != requested else { return }
        preference.write(requested, to: preferences)
    }

    /// Writes the entries config.json sets for a preference keyed by enum
    /// cases, each replacing its case's value, so every case they leave out
    /// keeps its value. No entries leave the preference alone.
    private func adopt<Case: Hashable & Sendable, Value: Equatable & Sendable>(
        entries requested: [Case: Value],
        into preference: StoredPreference<[Case: Value]>
    ) {
        guard !requested.isEmpty else { return }
        adopt(preference.read(from: preferences).merging(requested) { _, requested in requested }, into: preference)
    }

    /// The sound effects volume as config.json holds it: to the hundredth,
    /// the precision Settings shows as a percentage, so the file reads 0.65
    /// where the stored Float would print as 0.6499999761581421.
    private static func fileVolume(_ volume: Float) -> Double {
        (Double(volume) * 100).rounded() / 100
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
