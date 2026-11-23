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

    /// Makes the window follow the interface language (FR39): now, and after every switch of it.
    ///
    /// The scene delegate calls it as it makes the window. The window's own settings are what UIKit's bars read and what
    /// VoiceOver speaks in; SwiftUI's views follow through the root modifier (`followsInterfaceLanguage`).
    func followInterfaceLanguage() {
        applyInterfaceLanguage()
        // The window lives as long as the app; the observer holds it weakly and is never removed.
        NotificationCenter.default.addObserver(forName: InterfaceLanguage.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyInterfaceLanguage() }
        }
    }

    /// Sets the window's reading direction for UIKit's bars and VoiceOver's language from the person's choice.
    ///
    /// Under System both stay unset, which is how the app behaved before the picker: the system's own language and
    /// direction apply. A chosen language sets both, since the interface is then in it whatever the system speaks: the
    /// views' direction (`semanticContentAttribute`, which UIKit's bars follow) and the language VoiceOver reads in
    /// (`accessibilityLanguage`), so a switch is spoken in the new language's voice.
    func applyInterfaceLanguage() {
        switch InterfaceLanguageStore().choice() {
        case .system:
            semanticContentAttribute = .unspecified
            accessibilityLanguage = nil
        case .language:
            let state = InterfaceLanguage.current
            semanticContentAttribute = state.isRightToLeft ? .forceRightToLeft : .forceLeftToRight
            accessibilityLanguage = state.language
        }
    }

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
