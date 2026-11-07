import Combine
import Foundation

/// Everything the iPhone app holds for as long as it runs: the library, the
/// settings, the sounds, the session that owns the open readers, the navigation
/// path, and the life cycle every slice joins.
///
/// It is made once for the process, never once per scene: the system may
/// disconnect a scene to reclaim memory while a book plays on with the screen
/// locked, and a second model would be a second library over the same files.
///
/// It compiles on the Mac too, where only the tests reach it. The Mac's own app
/// never makes one, so nothing here happens on the Mac.
@MainActor
final class PhoneAppModel: ObservableObject {
    /// The library, loaded as this model is made.
    let library: LibraryViewModel
    /// The settings, read from config.json as this model is made.
    let settings: SettingsViewModel
    /// Plays the sounds of every reader.
    let soundEffects: SoundEffectService
    /// The owner of the open readers.
    let session: PhoneSession
    /// The life cycle, which the scene delegate calls and each slice joins.
    let lifeCycle = PhoneLifeCycle()

    /// The screens pushed over the Library, which `NavigationStack(path:)`
    /// binds to. A Back or a scrub off the reader's screen tells the session
    /// (`PhoneSession.leaveReader()`), wherever the change came from.
    @Published var path: [PhoneRoute] = [] {
        didSet {
            if PhoneRoute.showsReader(oldValue), !PhoneRoute.showsReader(path) {
                session.leaveReader()
            }
        }
    }

    /// Whether `startAfterFirstWindow()` has run: a scene that reconnects shows
    /// a first window of its own, in the same process.
    private var hasStartedAfterFirstWindow = false
    /// The session's requests to show the reader's screen.
    private var showReaderSubscription: AnyCancellable?

    /// The app's own model, its parts made in the order the Mac's `TextMouthApp`
    /// holds them: the library, the settings, then the sounds. The phone's
    /// settings are applied as the model is made, before any reader can exist.
    /// The Mac's cloud services, keyboard shortcuts, and window router have no
    /// part on a phone.
    convenience init() {
        let library = LibraryViewModel()
        let settings = SettingsViewModel()
        let soundEffects = SoundEffectService()
        self.init(
            library: library,
            settings: settings,
            soundEffects: soundEffects,
            session: PhoneSession(library: library, settings: settings, soundEffects: soundEffects),
            config: .shared
        )
    }

    /// A model of the parts given, which applies the phone's settings
    /// (`PhoneDefaults`) over `config`, and joins the parts together.
    init(
        library: LibraryViewModel,
        settings: SettingsViewModel,
        soundEffects: SoundEffectService,
        session: PhoneSession,
        config: ConfigService
    ) {
        self.library = library
        self.settings = settings
        self.soundEffects = soundEffects
        self.session = session
        PhoneDefaults.apply(to: settings, config: config)

        // A hand-over to the next book is held through the life cycle's hold, a
        // background task on iOS.
        session.beginHold = { [weak lifeCycle] name in
            lifeCycle?.beginHold(name) ?? {}
        }
        // Files from other apps go to the library once it has started. The
        // import slice replaces this with its holding and its copying: a file
        // opened in place is security-scoped, and must be copied in its scope.
        lifeCycle.openedFiles = { [weak library] urls in
            guard let library, library.hasStartedLibrary else { return }
            library.importAndOpenFiles(urls: urls, from: nil)
        }
        // Leaving the screen: what reopens the book is kept, then everything
        // waiting is saved, since iOS gives a suspended app no last call. The
        // reader is not closed, nor its listening session ended: a book playing
        // with the screen locked is still being listened to. The flush is the
        // life cycle's one timed and logged flush, so every flush is measured
        // the same way.
        lifeCycle.onDidEnterBackground { [weak self] in
            guard let self else { return }
            self.session.noteAppLeavingForeground(readerScreenShowing: PhoneRoute.showsReader(self.path))
            PhoneLifeCycle.flushPendingWrites(because: "entered-background")
        }
        showReaderSubscription = session.showReaderRequests.sink { [weak self] _ in
            self?.showReader()
        }
    }

    /// Shows the reader's screen, pushing it unless it is there.
    func showReader() {
        path = PhoneRoute.showingReader(on: path)
    }

    /// What the app starts once the first screen shows, rather than before it,
    /// once for the process: listing the voices, off the main thread, as the
    /// Mac's first window does, without which "No voices are installed" would be
    /// said falsely; and the log's line naming this build, as the Mac's app
    /// delegate writes it.
    func startAfterFirstWindow() {
        guard !hasStartedAfterFirstWindow else { return }
        hasStartedAfterFirstWindow = true
        VoiceCatalog.shared.loadIfNeeded()
        DiagnosticLog.event(.app, BuildIdentity.current.diagnosticLine)
    }
}
