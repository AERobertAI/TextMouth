import AppKit

/// Seeing to VoiceOver's and the keyboard's focus in a reader window that was
/// switched to another book (0.2.5).
///
/// A new reader window gets its first focus from the views it makes: the play
/// button (`StandardVoiceOverFocus`) and the loading and error states
/// (`InitialVoiceOverFocusModifier`) mark one element with
/// `voiceOverFocusID`, and a trigger view puts focus on it when its view
/// reaches the window. A switched window makes the same views, so the same
/// trigger runs; this is the guarantee behind it. A moment after the trigger
/// has run, if VoiceOver is not on that element, the focus is placed there
/// with the same notifications, so a blind listener is never left on nothing
/// in a window that did not announce itself.
@MainActor
enum SwitchedWindowFocus {
    /// How long to wait before looking: the trigger view's own delay and its
    /// attempts (`StandardVoiceOverFocusTriggerView`, 0.8 seconds and two
    /// tries 0.3 seconds apart) have run by then.
    static let checkDelay: TimeInterval = 1.6

    /// Sees to the focus of `window`, which now shows another book, after
    /// `checkDelay`. Nothing is done when VoiceOver is on the element
    /// already, when the window is no longer key (focus is not taken from
    /// another window), or when it has closed.
    static func place(in window: NSWindow) {
        DispatchQueue.main.asyncAfter(deadline: .now() + checkDelay) { [weak window] in
            guard let window, window.isKeyWindow, window.hasContentForVoiceOverFocus,
                  let contentView = window.contentView else { return }
            let finder = StandardVoiceOverFocusTriggerView()
            guard let target = finder.findElementByIdentifier(voiceOverFocusID, root: contentView, depth: 0) else {
                voiceOverFocusLog("switched window: no focus target found")
                return
            }
            guard !finder.isVoiceOverOnTarget(target, window: window) else { return }
            voiceOverFocusLog("switched window: placing focus")
            finder.postFocusNotifications(target: target, window: window)
        }
    }
}
