import Foundation

/// The iPhone app's life cycle, as the one place every slice joins it: the
/// scene delegate only calls this, and each slice registers what it does,
/// so no slice edits the delegate.
///
/// Handlers run in the order they were registered. Everything here runs on the
/// main actor, where UIKit calls its scene delegate.
@MainActor
final class PhoneLifeCycle {
    /// The handlers of each moment, in the order they were registered.
    private var didEnterBackgroundHandlers: [@MainActor () -> Void] = []
    private var willEnterForegroundHandlers: [@MainActor () -> Void] = []
    private var didBecomeActiveHandlers: [@MainActor () -> Void] = []

    /// Opens files another app sent: one owner, since a file is opened once.
    /// `PhoneAppModel` sets the first; the import slice replaces it with its
    /// holding and copying.
    var openedFiles: @MainActor ([URL]) -> Void = { _ in }

    /// Begins work the system must let finish should the app leave the screen,
    /// and returns what ends it, which may be called more than once. The app
    /// delegate makes it a background task; with nothing installed, as on the
    /// Mac's test host, it holds nothing.
    var beginHold: @MainActor (_ name: String) -> (@MainActor () -> Void) = { _ in {} }

    /// Whether files arrived before the app first became active: a file opened
    /// at launch wins over opening the last book again.
    private(set) var filesOpenedAtLaunch = false

    /// Whether the app has become active since launch.
    private(set) var hasBecomeActive = false

    // MARK: - Registering

    /// Runs `handler` each time the app goes to the background.
    func onDidEnterBackground(_ handler: @escaping @MainActor () -> Void) {
        didEnterBackgroundHandlers.append(handler)
    }

    /// Runs `handler` each time the app comes back toward the foreground.
    func onWillEnterForeground(_ handler: @escaping @MainActor () -> Void) {
        willEnterForegroundHandlers.append(handler)
    }

    /// Runs `handler` each time the app becomes active.
    func onDidBecomeActive(_ handler: @escaping @MainActor () -> Void) {
        didBecomeActiveHandlers.append(handler)
    }

    // MARK: - What the Scene Delegate Calls

    /// The scene went to the background.
    func sceneDidEnterBackground() {
        for handler in didEnterBackgroundHandlers { handler() }
    }

    /// The scene is coming back toward the foreground.
    func sceneWillEnterForeground() {
        for handler in willEnterForegroundHandlers { handler() }
    }

    /// The scene became active.
    func sceneDidBecomeActive() {
        hasBecomeActive = true
        for handler in didBecomeActiveHandlers { handler() }
    }

    /// Another app sent `urls`: at launch, in the scene's connection options,
    /// or later.
    func sceneOpened(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if !hasBecomeActive {
            filesOpenedAtLaunch = true
        }
        openedFiles(urls)
    }
}
