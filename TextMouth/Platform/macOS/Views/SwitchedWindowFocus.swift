import AppKit

/// Seeing to VoiceOver's and the keyboard's focus in a reader window that was
/// switched to another book (0.2.5).
///
/// A new reader window gets its first focus from the views it makes: the play
/// button (`StandardVoiceOverFocus`) and the loading and error states
/// (`InitialVoiceOverFocusModifier`) mark one element with
/// `voiceOverFocusID`, and a trigger view puts focus on it when its view
/// reaches the window. A switched window makes the same views, so the same
/// trigger runs; this is the guarantee behind it, and it acts only when the
/// trigger did not place the focus: it found no element, or its window was not
/// key when it ran. VoiceOver is never told twice to read the play button.
///
/// It starts once the book has loaded, when the trigger is due, notes how many
/// times a trigger has posted in the window
/// (`StandardVoiceOverFocusTriggerView.focusPostCount(of:)`), and looks
/// `checkDelay` later, when the trigger has run. If a trigger posted meanwhile
/// it does nothing. Otherwise, only in the key window, it finds the marked
/// element and puts focus there once, as the trigger does; "Loading book..."
/// has no marked element, and then it does nothing. A trigger delayed past the
/// check by main-thread work could still post after it, which only the user's
/// ears can tell.
@MainActor
enum SwitchedWindowFocus {
    /// How long to wait after the book has loaded before looking: the trigger
    /// view's own delay and its attempts have run by then.
    static let checkDelay: TimeInterval = 1.6

    /// Whether the check puts focus in the window: only in the key window, and
    /// only if no trigger posted since the book loaded. The count at the load
    /// need not be zero, since an earlier book's trigger in the same window
    /// has posted before (W8), so the check compares counts and never reads a
    /// count as a yes or a no.
    nonisolated static func shouldPlace(postsAtTheLoad: Int, postsNow: Int, windowIsKey: Bool) -> Bool {
        windowIsKey && postsNow == postsAtTheLoad
    }

    /// Sees to the focus of `window`, which now shows a book that has loaded,
    /// once, `checkDelay` from now.
    static func place(in window: NSWindow) {
        let postsAtTheLoad = StandardVoiceOverFocusTriggerView.focusPostCount(of: window)
        DispatchQueue.main.asyncAfter(deadline: .now() + checkDelay) { [weak window] in
            guard let window, window.hasContentForVoiceOverFocus else { return }
            guard shouldPlace(
                postsAtTheLoad: postsAtTheLoad,
                postsNow: StandardVoiceOverFocusTriggerView.focusPostCount(of: window),
                windowIsKey: window.isKeyWindow
            ) else { return }
            let finder = StandardVoiceOverFocusTriggerView()
            guard let target = finder.findMarkedElement(in: window) else {
                voiceOverFocusLog("switched window: no focus target found")
                return
            }
            voiceOverFocusLog("switched window: the trigger did not place focus; placing it once")
            StandardVoiceOverFocusTriggerView.placeFocus(on: target, in: window)
        }
    }
}
