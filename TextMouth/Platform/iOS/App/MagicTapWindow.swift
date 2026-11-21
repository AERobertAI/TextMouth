import UIKit

/// The app's one window, and the home of VoiceOver's magic tap, the two-finger
/// double-tap: it plays and pauses the current book from any screen.
///
/// VoiceOver sends the magic tap up the responder chain from the element in
/// focus, and the window is in every chain, sheets included. A delegate behind
/// SwiftUI's adaptor is reported not to hear it, by two shipping audio apps.
/// The spec lists this first among what a person must check on a real iPhone:
/// that it does not take dictation from a text field, or answering a call.
final class MagicTapWindow: UIWindow {
    /// The session that owns the open book's reader. No initializer is declared
    /// here, so the window keeps `UIWindow(windowScene:)`, and the scene
    /// delegate sets this as it makes the window.
    var session: PhoneSession?

    /// Plays or pauses, saying nothing: the book starting or stopping is the
    /// feedback.
    ///
    /// - Returns: Apple's documentation has it mean "the magic tap action
    ///   succeeds"; false when no book has ever been opened, so that the
    ///   system's own fallback runs.
    override func accessibilityPerformMagicTap() -> Bool {
        session?.togglePlayPauseFromAnywhere() ?? false
    }
}
