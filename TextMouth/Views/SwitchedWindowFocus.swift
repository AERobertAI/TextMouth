import Accessibility
import AppKit

/// Seeing to VoiceOver's and the keyboard's focus in a reader window that was
/// switched to another book (0.2.5).
///
/// A new reader window gets its first focus from the views it makes: the play
/// button (`StandardVoiceOverFocus`) and the loading and error states
/// (`InitialVoiceOverFocusModifier`) mark one element with
/// `voiceOverFocusID`, and a trigger view puts focus on it when its view
/// reaches the window. A switched window makes the same views, so the same
/// trigger runs; this is the guarantee behind it.
///
/// It starts once the book has loaded, when the play button's own trigger is
/// due (0.8 seconds after its view appears, then two attempts 0.3 seconds
/// apart), and looks `checkDelay` later, when that trigger has run. Before
/// each attempt it asks whether the window is still the key window, so focus
/// is never taken from the listener who went elsewhere, and whether VoiceOver
/// is on the element already, so the element is never announced twice. It
/// finds no element while the window still shows "Loading book...", which
/// has none, and then does nothing.
@MainActor
enum SwitchedWindowFocus {
    /// How long to wait after the book has loaded before looking: the trigger
    /// view's own delay and its attempts have run by then.
    static let checkDelay: TimeInterval = 1.6

    /// How long after an attempt the next one is made.
    static let attemptSpacing: TimeInterval = 0.5

    /// How many attempts are made.
    static let attempts = 2

    /// Sees to the focus of `window`, which now shows a book that has loaded,
    /// from `checkDelay` on. Nothing is done when the window is no longer key
    /// (focus is not taken from another window), when it has closed, or when
    /// VoiceOver is on the marked element already.
    static func place(in window: NSWindow) {
        for attempt in 0..<attempts {
            let delay = checkDelay + Double(attempt) * attemptSpacing
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak window] in
                guard let window else { return }
                attemptToPlaceFocus(in: window)
            }
        }
    }

    /// One attempt: only in the key window, and only when VoiceOver is not on
    /// the marked element, the focus is placed there as the element's own
    /// trigger places it (`StandardVoiceOverFocusTriggerView`).
    private static func attemptToPlaceFocus(in window: NSWindow) {
        guard window.isKeyWindow, window.hasContentForVoiceOverFocus,
              let contentView = window.contentView else { return }
        let finder = StandardVoiceOverFocusTriggerView()
        guard let target = finder.findElementByIdentifier(voiceOverFocusID, root: contentView, depth: 0) else {
            voiceOverFocusLog("switched window: no focus target found")
            return
        }
        guard !finder.isVoiceOverOnTarget(target, window: window) else { return }
        voiceOverFocusLog("switched window: placing focus")
        if let view = target as? NSView {
            window.makeFirstResponder(view)
        }
        AccessibilityNotification.ScreenChanged(target).post()
    }
}
