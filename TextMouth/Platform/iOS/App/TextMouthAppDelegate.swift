import UIKit

/// TextMouth's iPhone app begins here, on UIKit's life cycle rather than
/// SwiftUI's `App`: its one window is a subclass, `MagicTapWindow`, which is the
/// reliable home for the magic tap, and placing a window subclass under a
/// SwiftUI `App` takes an empty scene and a delegate that may not be called.
///
/// UIKit's order at launch, from Apple's "About the app launch sequence":
/// `UIApplicationMain` makes `UIApplication` and this delegate; then
/// `application(_:didFinishLaunchingWithOptions:)`, not needed yet; then, "after
/// the app launch completes", the scene's configuration, which names the scene
/// delegate, and that delegate's `scene(_:willConnectTo:options:)`, where `model`
/// is first read. So everything the model makes runs with `UIApplication.shared`
/// in place and a scene connecting. Nothing has run on iOS yet, so this order is
/// the documentation's, not an observation.
@main
final class TextMouthAppDelegate: UIResponder, UIApplicationDelegate {
    /// The app's one model, made at its first use and kept for the process.
    /// It belongs to the process, not to a scene delegate: Apple's documentation
    /// says UIKit "may also disconnect a scene in order to reclaim memory", and
    /// a scene that comes back has a new delegate, while the book may have
    /// played on all that time.
    static let model = PhoneAppModel()

    /// Names `TextMouthSceneDelegate` for every scene, in code: the scene
    /// manifest Xcode generates holds no configurations. With none in the
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
}
