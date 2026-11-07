import SwiftUI
import UIKit

/// The iPhone app's one scene: it makes the window, and takes the system's
/// calls for files from other apps and for going to the background. These are
/// UIKit's documented calls, which is why SwiftUI's `scenePhase` and
/// `onOpenURL` are not used.
final class TextMouthSceneDelegate: UIResponder, UIWindowSceneDelegate {
    /// The scene's window. UIKit's protocol asks the delegate to hold it.
    var window: UIWindow?

    /// The background task that covers saving as the app leaves the screen;
    /// `.invalid` when none is under way.
    private var backgroundSaveTask = UIBackgroundTaskIdentifier.invalid

    /// Makes the window over the app's one model, shows it, and opens any file
    /// the scene was made for: at a cold launch a file arrives here, and
    /// `scene(_:openURLContexts:)` does not hear of it.
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // Reading the model the first time loads the library, on this thread,
        // before the first frame (see the report on Slice 1).
        let model = TextMouthAppDelegate.model
        let window = MagicTapWindow(windowScene: windowScene)
        window.session = model.session
        window.rootViewController = UIHostingController(rootView: PhoneRootView(model: model))
        self.window = window
        window.makeKeyAndVisible()
        openFiles(in: connectionOptions.urlContexts)
    }

    /// Opens files another app sends while the scene is connected.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        openFiles(in: URLContexts)
    }

    /// Hands files from another app to the library, the one path both calls
    /// above take.
    ///
    /// The seam for Slice 3, which puts `PhoneImportHolding` and the copy here.
    /// What this lacks until then: a file opened in place (Info.plist's
    /// `LSSupportsOpeningDocumentsInPlace`) is security-scoped, and needs its
    /// scope started and a coordinated copy before the import can read it; and
    /// files arriving while the library is unavailable are dropped here, when
    /// they should be held until the library has started.
    private func openFiles(in contexts: Set<UIOpenURLContext>) {
        let urls = contexts.map(\.url)
        let library = TextMouthAppDelegate.model.library
        guard !urls.isEmpty, library.hasStartedLibrary else { return }
        library.importAndOpenFiles(urls: urls, from: nil)
    }

    /// Saves what waits to be saved, since iOS gives a suspended app no last
    /// call: every open reader's place, the library, the statistics, and the
    /// settings. It does not close the reader or end the listening session: a
    /// book playing with the screen locked is still being listened to. Slice 6
    /// builds the rest of the life cycle here.
    ///
    /// The flush runs on this thread before this returns, and a scene has
    /// seconds for this call. The task covers it if that runs out: Apple's
    /// documentation says to begin one "as early as possible", not at the end
    /// of this method, and that each must be ended, or the system kills the app.
    func sceneDidEnterBackground(_ scene: UIScene) {
        backgroundSaveTask = UIApplication.shared.beginBackgroundTask(withName: "Saving the book's place") { [weak self] in
            self?.endBackgroundSaveTask()
        }
        UnsavedChangesTerminationGuard.flushPendingWrites()
        endBackgroundSaveTask()
    }

    /// Ends the background task, once, whichever comes first: the flush's end,
    /// or the system's call that its time is nearly up.
    private func endBackgroundSaveTask() {
        guard backgroundSaveTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundSaveTask)
        backgroundSaveTask = .invalid
    }
}
