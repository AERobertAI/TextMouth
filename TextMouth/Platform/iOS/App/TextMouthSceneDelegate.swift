import SwiftUI
import UIKit

/// The iPhone app's one scene: it makes the window, and passes the system's
/// calls on to the model's life cycle (`PhoneLifeCycle`), which every slice
/// joins, so that no slice edits this file. These are UIKit's documented calls,
/// which is why SwiftUI's `scenePhase` and `onOpenURL` are not used.
final class TextMouthSceneDelegate: UIResponder, UIWindowSceneDelegate {
    /// The scene's window. UIKit's protocol asks the delegate to hold it.
    var window: UIWindow?

    /// Makes the window over the app's one model, shows it, and opens any file
    /// the scene was made for: at a cold launch a file arrives in the connection
    /// options, which the header calls the contexts "to handle on connection".
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        // The model was made as launching finished, its library's index read
        // on the main thread: about 134 milliseconds for 643 books on the
        // development Mac. Nothing it does needs the scene or the window.
        let model = TextMouthAppDelegate.model
        let window = MagicTapWindow(windowScene: windowScene)
        window.session = model.session
        window.rootViewController = UIHostingController(rootView: PhoneRootView(model: model))
        self.window = window
        window.makeKeyAndVisible()
        var opened = connectionOptions.urlContexts.map(\.url)
        #if DEBUG
        // A UI test, or a run in the simulator, sends a book by its path, as
        // another app would at a cold launch (PhoneLaunchRequest).
        opened += PhoneLaunchRequest.filesToOpen(ProcessInfo.processInfo.environment)
        #endif
        model.lifeCycle.sceneOpened(opened)
    }

    /// Opens files another app sends while the scene is connected.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        TextMouthAppDelegate.model.lifeCycle.sceneOpened(URLContexts.map(\.url))
    }

    /// The scene went to the background: what is registered runs inside a
    /// background task, begun at once, since Apple's documentation says to
    /// begin one "as early as possible", not at the end of this method.
    func sceneDidEnterBackground(_ scene: UIScene) {
        let endTask = TextMouthAppDelegate.beginBackgroundTask(named: "Saving the book's place")
        TextMouthAppDelegate.model.lifeCycle.sceneDidEnterBackground()
        endTask()
    }

    /// The scene is coming back toward the foreground.
    func sceneWillEnterForeground(_ scene: UIScene) {
        TextMouthAppDelegate.model.lifeCycle.sceneWillEnterForeground()
    }

    /// The scene became active.
    func sceneDidBecomeActive(_ scene: UIScene) {
        TextMouthAppDelegate.model.lifeCycle.sceneDidBecomeActive()
    }
}
