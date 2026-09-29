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
    @AppStorage("selectedVoiceID") var selectedVoiceID: String = "" {
        didSet { broadcastChanges(); syncToConfig() }
    }
    @AppStorage("wordsPerMinute") var wordsPerMinute: Double = 200 {
        didSet { broadcastChanges(); syncToConfig() }
    }
    @AppStorage("pitchMultiplier") var pitchMultiplier: Double = 1.0 {
        didSet { broadcastChanges(); syncToConfig() }
    }
    @AppStorage("selectedLanguage") var selectedLanguage: String = "en" {
        didSet { syncToConfig() }
    }
    @AppStorage("skipForwardUnit") var skipForwardUnitRaw: String = SkipUnit.seconds15.rawValue {
        didSet { publishPlaybackControlsChange(); syncToConfig() }
    }
    @AppStorage("skipBackwardUnit") var skipBackwardUnitRaw: String = SkipUnit.seconds15.rawValue {
        didSet { publishPlaybackControlsChange(); syncToConfig() }
    }

    @AppStorage("shiftSkipForwardUnit") var shiftSkipForwardUnitRaw: String = SkipUnit.seconds30.rawValue {
        didSet { syncToConfig() }
    }
    @AppStorage("shiftSkipBackwardUnit") var shiftSkipBackwardUnitRaw: String = SkipUnit.seconds30.rawValue {
        didSet { syncToConfig() }
    }

    @AppStorage("rewindOnResumeUnit") var rewindOnResumeUnitRaw: String = RewindUnit.none.rawValue {
        didSet { syncToConfig() }
    }
    @AppStorage("rewindSmartMode") var rewindSmartMode: Bool = false {
        didSet { syncToConfig() }
    }
    @AppStorage("rewindSmartThreshold") var rewindSmartThreshold: Double = 70 {
        didSet { syncToConfig() }
    }
    @AppStorage("sleepFadeOutDuration") var sleepFadeOutDuration: Double = 0 {
        didSet { syncToConfig() }
    }
    @AppStorage("sleepTimerAutoClose") var sleepTimerAutoClose: Bool = true {
        didSet { syncToConfig() }
    }
    @AppStorage("endOfBookBehavior") var endOfBookBehaviorRaw: String = EndOfBookBehavior.stop.rawValue {
        didSet { syncToConfig() }
    }
    @AppStorage("punctuationPauseLevel") var punctuationPauseLevel: Double = 0 {
        didSet { syncToConfig() }
    }
    @AppStorage("autoPlayOnNavigate") var autoPlayOnNavigate: Bool = false {
        didSet { syncToConfig() }
    }
    @AppStorage("showBookmarkInPlaybackControls") var showBookmarkInPlaybackControls: Bool = false {
        didSet { publishPlaybackControlsChange() }
    }
    @AppStorage("showSpeedInPlaybackControls") var showSpeedInPlaybackControls: Bool = true {
        didSet { publishPlaybackControlsChange() }
    }
    @AppStorage("playbackNavigationUnitControlMode")
    var playbackNavigationUnitControlModeRaw: String = PlaybackNavigationUnitControlMode.none.rawValue {
        didSet { publishPlaybackControlsChange() }
    }

    /// Whether to monitor Bluetooth device disconnections and suppress
    /// spurious media commands from macOS's rcd daemon.
    @AppStorage("bluetoothMonitoringEnabled") var bluetoothMonitoringEnabled: Bool = true {
        didSet { broadcastBluetoothChanges(); syncToConfig() }
    }
    /// How long (in seconds) to suppress spurious media commands after
    /// a Bluetooth audio device disconnects. Range: 1–10, default 2.
    @AppStorage("bluetoothDisconnectDelay") var bluetoothDisconnectDelay: Double = 2.0 {
        didSet { broadcastBluetoothChanges(); syncToConfig() }
    }

    // MARK: - Restart Sleep Timer Gesture (Experimental)

    /// Whether the experimental media-gesture detector for restarting
    /// the sleep timer is active. Off by default — the feature is
    /// opt-in because it monitors every media-key press and could
    /// surprise users who just want their headphone buttons to do
    /// what they normally do.
    @AppStorage("restartTimerGestureEnabled") var restartTimerGestureEnabled: Bool = false {
        didSet { broadcastGestureChanges(); syncToConfig() }
    }
    /// Comma-separated event-type sequence (see `MediaGestureDetector.EventType`).
    /// Default "previousTrack,previousTrack,previousTrack" — three
    /// previous-track presses in a row, picked because it's
    /// vanishingly unlikely to occur accidentally during normal use.
    @AppStorage("restartTimerGesturePattern") var restartTimerGesturePattern: String = "previousTrack,previousTrack,previousTrack" {
        didSet { broadcastGestureChanges(); syncToConfig() }
    }
    /// Maximum total elapsed time (seconds) for the gesture to count
    /// as a match. 0.5–10s; 2.0 is the default — long enough for a
    /// deliberate sequence, short enough that real navigation use
    /// won't accidentally trigger.
    @AppStorage("restartTimerGestureWindow") var restartTimerGestureWindow: Double = 2.0 {
        didSet { broadcastGestureChanges(); syncToConfig() }
    }

    @Published var availableVoices: [AVSpeechSynthesisVoice] = []
    @Published var availableLanguages: [String] = []
    /// Changes whenever an option affecting the open playback bar changes.
    /// `PlaybackControlsView` observes this model directly, so incrementing the
    /// revision invalidates existing book windows without reopening them.
    @Published private(set) var playbackControlsSettingsRevision = 0

    private let configService = ConfigService.shared
    private let notificationCenter: NotificationCenter
    private var configCancellable: AnyCancellable?
    private var isSyncingFromConfig = false

    var skipForwardUnit: SkipUnit {
        get { SkipUnit(rawValue: skipForwardUnitRaw) ?? .seconds15 }
        set { skipForwardUnitRaw = newValue.rawValue }
    }

    var skipBackwardUnit: SkipUnit {
        get { SkipUnit(rawValue: skipBackwardUnitRaw) ?? .seconds15 }
        set { skipBackwardUnitRaw = newValue.rawValue }
    }

    var shiftSkipForwardUnit: SkipUnit {
        get { SkipUnit(rawValue: shiftSkipForwardUnitRaw) ?? .seconds30 }
        set { shiftSkipForwardUnitRaw = newValue.rawValue }
    }

    var shiftSkipBackwardUnit: SkipUnit {
        get { SkipUnit(rawValue: shiftSkipBackwardUnitRaw) ?? .seconds30 }
        set { shiftSkipBackwardUnitRaw = newValue.rawValue }
    }

    /// Typed view of the persisted playback-bar navigation control mode.
    var playbackNavigationUnitControlMode: PlaybackNavigationUnitControlMode {
        get {
            PlaybackNavigationUnitControlMode(rawValue: playbackNavigationUnitControlModeRaw)
                ?? .none
        }
        set { playbackNavigationUnitControlModeRaw = newValue.rawValue }
    }

    var endOfBookBehavior: EndOfBookBehavior {
        get { EndOfBookBehavior(rawValue: endOfBookBehaviorRaw) ?? .stop }
        set { endOfBookBehaviorRaw = newValue.rawValue }
    }

    var rewindOnResumeUnit: RewindUnit {
        get { RewindUnit(rawValue: rewindOnResumeUnitRaw) ?? .none }
        set { rewindOnResumeUnitRaw = newValue.rawValue }
    }

    /// Publish one coalescible settings-model change for open playback bars.
    /// The revision also gives tests a deterministic signal independent of
    /// SwiftUI's rendering schedule.
    private func publishPlaybackControlsChange() {
        playbackControlsSettingsRevision &+= 1
    }

    init(
        notificationCenter: NotificationCenter = .default,
        initializeServices: Bool = true
    ) {
        self.notificationCenter = notificationCenter
        guard initializeServices else { return }
        refreshVoices()

        // AppStorage is the source of truth. If an existing config.json has
        // different values (external edit), apply those. Otherwise write
        // current AppStorage values to config.json.
        if configService.hasExistingConfig {
            loadFromConfig()
        }
        // Always write current values to config.json so it's in sync
        syncToConfig()

        // Now start watching for external edits
        configService.startWatching()
        observeConfigChanges()
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
        configService.config.selectedVoiceID = selectedVoiceID
        configService.config.wordsPerMinute = wordsPerMinute
        configService.config.pitchMultiplier = pitchMultiplier
        configService.config.selectedLanguage = selectedLanguage
        configService.config.skipForwardUnit = skipForwardUnitRaw
        configService.config.skipBackwardUnit = skipBackwardUnitRaw
        configService.config.shiftSkipForwardUnit = shiftSkipForwardUnitRaw
        configService.config.shiftSkipBackwardUnit = shiftSkipBackwardUnitRaw
        configService.config.rewindOnResumeUnit = rewindOnResumeUnitRaw
        configService.config.rewindSmartMode = rewindSmartMode
        configService.config.rewindSmartThreshold = rewindSmartThreshold
        configService.config.sleepFadeOutDuration = sleepFadeOutDuration
        configService.config.sleepTimerAutoClose = sleepTimerAutoClose
        configService.config.endOfBookBehavior = endOfBookBehaviorRaw
        configService.config.punctuationPauseLevel = punctuationPauseLevel
        configService.config.autoPlayOnNavigate = autoPlayOnNavigate
        configService.config.bluetoothMonitoringEnabled = bluetoothMonitoringEnabled
        configService.config.bluetoothDisconnectDelay = bluetoothDisconnectDelay
        configService.config.restartTimerGestureEnabled = restartTimerGestureEnabled
        configService.config.restartTimerGesturePattern = restartTimerGesturePattern
        configService.config.restartTimerGestureWindow = restartTimerGestureWindow
        // Preserve dataDirectoryPath — it's managed by the Storage settings tab
        configService.config.dataDirectoryPath = TextMouthPaths.isCustomPath ? TextMouthPaths.rootPath : ""
        configService.saveToDisk()
    }

    /// Pull settings from config.json (only for values that differ, i.e., external edits)
    private func loadFromConfig() {
        applyConfigChanges(configService.config)
    }

    /// Watch for external config.json changes
    private func observeConfigChanges() {
        configCancellable = configService.$config
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newConfig in
                self?.applyConfigChanges(newConfig)
            }
    }

    /// Sync local @AppStorage properties from a config snapshot.
    /// Used both on initial load and when config.json is externally modified.
    func applyConfigChanges(_ config: ConfigService.AppConfig) {
        isSyncingFromConfig = true
        if !config.selectedVoiceID.isEmpty && config.selectedVoiceID != selectedVoiceID {
            selectedVoiceID = config.selectedVoiceID
        }
        if config.wordsPerMinute > 0 && config.wordsPerMinute != wordsPerMinute {
            wordsPerMinute = config.wordsPerMinute
        }
        if config.pitchMultiplier > 0 && config.pitchMultiplier != pitchMultiplier {
            pitchMultiplier = config.pitchMultiplier
        }
        if !config.selectedLanguage.isEmpty && config.selectedLanguage != selectedLanguage {
            selectedLanguage = config.selectedLanguage
        }
        if !config.skipForwardUnit.isEmpty && config.skipForwardUnit != skipForwardUnitRaw {
            skipForwardUnitRaw = config.skipForwardUnit
        }
        if !config.skipBackwardUnit.isEmpty && config.skipBackwardUnit != skipBackwardUnitRaw {
            skipBackwardUnitRaw = config.skipBackwardUnit
        }
        if !config.shiftSkipForwardUnit.isEmpty && config.shiftSkipForwardUnit != shiftSkipForwardUnitRaw {
            shiftSkipForwardUnitRaw = config.shiftSkipForwardUnit
        }
        if !config.shiftSkipBackwardUnit.isEmpty && config.shiftSkipBackwardUnit != shiftSkipBackwardUnitRaw {
            shiftSkipBackwardUnitRaw = config.shiftSkipBackwardUnit
        }
        if !config.rewindOnResumeUnit.isEmpty && config.rewindOnResumeUnit != rewindOnResumeUnitRaw {
            rewindOnResumeUnitRaw = config.rewindOnResumeUnit
        }
        if config.rewindSmartMode != rewindSmartMode {
            rewindSmartMode = config.rewindSmartMode
        }
        if config.rewindSmartThreshold > 0 && config.rewindSmartThreshold != rewindSmartThreshold {
            rewindSmartThreshold = config.rewindSmartThreshold
        }
        if config.sleepFadeOutDuration != sleepFadeOutDuration {
            sleepFadeOutDuration = config.sleepFadeOutDuration
        }
        if config.sleepTimerAutoClose != sleepTimerAutoClose {
            sleepTimerAutoClose = config.sleepTimerAutoClose
        }
        if !config.endOfBookBehavior.isEmpty && config.endOfBookBehavior != endOfBookBehaviorRaw {
            endOfBookBehaviorRaw = config.endOfBookBehavior
        }
        if config.punctuationPauseLevel != punctuationPauseLevel {
            punctuationPauseLevel = config.punctuationPauseLevel
        }
        if config.autoPlayOnNavigate != autoPlayOnNavigate {
            autoPlayOnNavigate = config.autoPlayOnNavigate
        }
        if config.bluetoothMonitoringEnabled != bluetoothMonitoringEnabled {
            bluetoothMonitoringEnabled = config.bluetoothMonitoringEnabled
        }
        if config.bluetoothDisconnectDelay > 0 && config.bluetoothDisconnectDelay != bluetoothDisconnectDelay {
            bluetoothDisconnectDelay = config.bluetoothDisconnectDelay
        }
        if config.restartTimerGestureEnabled != restartTimerGestureEnabled {
            restartTimerGestureEnabled = config.restartTimerGestureEnabled
        }
        if !config.restartTimerGesturePattern.isEmpty &&
           config.restartTimerGesturePattern != restartTimerGesturePattern {
            restartTimerGesturePattern = config.restartTimerGesturePattern
        }
        if config.restartTimerGestureWindow > 0 &&
           config.restartTimerGestureWindow != restartTimerGestureWindow {
            restartTimerGestureWindow = config.restartTimerGestureWindow
        }
        // Handle external change to dataDirectoryPath
        let currentCustom = TextMouthPaths.isCustomPath ? TextMouthPaths.rootPath : ""
        if config.dataDirectoryPath != currentCustom {
            notificationCenter.post(
                name: .dataDirectoryChangeRequested,
                object: nil,
                userInfo: ["path": config.dataDirectoryPath]
            )
        }
        isSyncingFromConfig = false
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

extension Notification.Name {
    static let speechSettingsChanged = Notification.Name("speechSettingsChanged")
    static let bluetoothSettingsChanged = Notification.Name("bluetoothSettingsChanged")
    static let restartTimerGestureSettingsChanged = Notification.Name("restartTimerGestureSettingsChanged")
    static let dataDirectoryChangeRequested = Notification.Name("dataDirectoryChangeRequested")
}
