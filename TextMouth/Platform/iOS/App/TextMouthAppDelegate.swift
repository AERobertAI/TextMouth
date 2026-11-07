import UIKit

/// TextMouth's iPhone app begins here, on UIKit's life cycle rather than
/// SwiftUI's `App`: its one window is a subclass, `MagicTapWindow`, which is the
/// reliable home for the magic tap, and placing a window subclass under a
/// SwiftUI `App` takes an empty scene and a delegate that may not be called.
///
/// UIKit's order at launch, from Apple's "About the app launch sequence":
/// `UIApplicationMain` makes `UIApplication` and this delegate; then
/// `application(_:didFinishLaunchingWithOptions:)`, where the model is made and
/// the audio session installed; then, "after the app launch completes", the
/// scene's configuration, which names the scene delegate, and that delegate's
/// `scene(_:willConnectTo:options:)`. So a launch in the background for a Play
/// from the lock screen, which may connect no scene, still has the model and the
/// media commands' targets. Nothing has run on iOS yet, so this order is the
/// documentation's, not an observation.
@main
final class TextMouthAppDelegate: UIResponder, UIApplicationDelegate {
    /// The app's one model, made at its first use and kept for the process.
    /// It belongs to the process, not to a scene delegate: Apple's documentation
    /// says UIKit "may also disconnect a scene in order to reclaim memory", and
    /// a scene that comes back has a new delegate, while the book may have
    /// played on all that time.
    static let model = PhoneAppModel()

    /// Makes the model, before any scene connects, gives its life cycle a hold
    /// that is a background task, and installs the audio session over its
    /// session: the category, the observers, and the remote commands' targets,
    /// which must be in place for a Play to wake a killed app (the engineer's
    /// review, F9; `PhoneAudioSession.install(session:)`). Not in this
    /// delegate's initializer, which runs inside `UIApplicationMain` before
    /// launching has begun.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let model = Self.model
        model.lifeCycle.beginHold = { name in
            Self.beginBackgroundTask(named: name)
        }
        PhoneAudioSession.install(session: model.session)
        joinTheSlices(on: model)
        return true
    }

    /// Joins the work of the slices that meet only here, once, at launch,
    /// before any scene connects, so that a launch in the background (for a
    /// remote Play, with no scene) has them too:
    /// - the life cycle's background work (Slice 6), with the audio session's
    ///   deactivation (Slice 5) and the memory guard's check on look-ahead
    ///   renders, which the two slices left to be joined where both are seen;
    /// - the import copier (Slice 3), which takes the files other apps hand
    ///   over, so a file sent at a cold launch is copied under its scope
    ///   rather than imported directly;
    /// - the reader's model (Slice 4), so the AirPods' and the lock screen's
    ///   skips take the phone's one move path before the reader's screen has
    ///   ever been shown.
    private func joinTheSlices(on model: PhoneAppModel) {
        PhoneBackgroundWork.deactivateAudioIfIdle = {
            PhoneAudioSession.shared.deactivateIfIdle()
        }
        SpeechRenderCoordinator.shared.mayRenderAhead = {
            PlaybackMemoryGuard.mayRenderAhead()
        }
        PhoneBackgroundWork.install(on: model)
        PhoneImportCopier.shared.install()
        _ = PhoneReaderModel.attached(to: model.session)
    }

    /// Names `TextMouthSceneDelegate` for every scene, in code. iOSApp/Info.plist
    /// declares one scene at a time and no configurations, and with none in the
    /// Info.plist, the header says, the configuration comes back with no scene
    /// class, delegate class, or storyboard. So both classes are set here, the
    /// scene's too, since the documentation does not say what a nil scene class
    /// does, and says "typically, you specify the UIWindowScene class".
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.sceneClass = UIWindowScene.self
        configuration.delegateClass = TextMouthSceneDelegate.self
        return configuration
    }

    /// A second home for the magic tap, after the window: the application's
    /// delegate is the last responder VoiceOver asks.
    override func accessibilityPerformMagicTap() -> Bool {
        Self.model.session.togglePlayPauseFromAnywhere()
    }

    /// Begins a background task named `name`, and returns what ends it, once,
    /// however often it is called. Apple's documentation: each task "must be
    /// ended", or "the system kills the app", and the expiration handler runs
    /// "shortly before the app's remaining background time reaches 0", so it
    /// ends the task too.
    static func beginBackgroundTask(named name: String) -> @MainActor () -> Void {
        let task = BackgroundTask()
        task.identifier = UIApplication.shared.beginBackgroundTask(withName: name) {
            task.end()
        }
        return { task.end() }
    }
}

/// One background task, ended once.
@MainActor
private final class BackgroundTask {
    /// The task, or `.invalid` once ended or never granted.
    var identifier = UIBackgroundTaskIdentifier.invalid

    /// Ends the task, if it is still running.
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
