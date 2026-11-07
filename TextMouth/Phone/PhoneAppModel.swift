import Foundation

/// Everything the iPhone app holds for as long as it runs: the library, the
/// settings, the sounds, and the session that owns the open book's reader.
///
/// It is made once for the process, never once per scene: the system may
/// disconnect a scene to reclaim memory, while a book plays on with the screen
/// locked, and a second model would be a second library over the same files.
///
/// It compiles on the Mac too, where only the tests reach it. The Mac's own app
/// never makes one, so nothing here happens on the Mac.
@MainActor
final class PhoneAppModel {
    /// The preference that says the phone's fixed settings were applied.
    nonisolated static let phoneSettingsAppliedKey = "phoneAppModel.phoneSettingsApplied"

    /// The library, loaded as this model is made.
    let library: LibraryViewModel
    /// The settings, read from config.json as this model is made.
    let settings: SettingsViewModel
    /// Plays the sounds of every reader.
    let soundEffects: SoundEffectService
    /// The owner of the open book's reader.
    let session: PhoneSession

    /// Whether `startAfterFirstWindow()` has run: a scene that reconnects shows
    /// a first window of its own, in the same process.
    private var hasStartedAfterFirstWindow = false

    /// The app's own model, its parts made in the order the Mac's `TextMouthApp`
    /// holds them: the library, the settings, then the sounds. The Mac's cloud
    /// services, keyboard shortcuts, and window router have no part on a phone.
    convenience init() {
        let library = LibraryViewModel()
        let settings = SettingsViewModel()
        let soundEffects = SoundEffectService()
        self.init(
            library: library,
            settings: settings,
            soundEffects: soundEffects,
            session: PhoneSession(library: library, settings: settings, soundEffects: soundEffects),
            preferences: TextMouthRuntime.current.preferences,
            removalPreferences: .shared
        )
    }

    /// A model of the parts given, which applies the phone's fixed settings
    /// the first time a model is made over `preferences`.
    init(
        library: LibraryViewModel,
        settings: SettingsViewModel,
        soundEffects: SoundEffectService,
        session: PhoneSession,
        preferences: UserDefaults,
        removalPreferences: RemovalPreferencesModel
    ) {
        self.library = library
        self.settings = settings
        self.soundEffects = soundEffects
        self.session = session
        Self.applyPhoneSettingsOnce(to: settings, removal: removalPreferences, in: preferences)
    }

    /// Sets what the phone fixes and never shows, once, at the first launch, so
    /// it never overrides a value an edit or a later version changes:
    /// - one navigation unit for both directions, since the reader's screen has
    ///   one Navigation Unit control;
    /// - deleting a book's files, not moving them to the Trash, since a phone
    ///   has no Trash a person can open.
    private static func applyPhoneSettingsOnce(
        to settings: SettingsViewModel,
        removal: RemovalPreferencesModel,
        in preferences: UserDefaults
    ) {
        guard !preferences.bool(forKey: phoneSettingsAppliedKey) else { return }
        preferences.set(true, forKey: phoneSettingsAppliedKey)
        settings.playbackNavigationUnitControlMode = .shared
        removal.setMovesToTrash(false)
    }

    /// What the app starts once the first window shows, rather than before it,
    /// once for the process: listing the voices, off the main thread, as the
    /// Mac's first window does, and the log's line naming this build, as the
    /// Mac's app delegate writes it.
    func startAfterFirstWindow() {
        guard !hasStartedAfterFirstWindow else { return }
        hasStartedAfterFirstWindow = true
        VoiceCatalog.shared.loadIfNeeded()
        DiagnosticLog.event(.app, BuildIdentity.current.diagnosticLine)
    }
}
