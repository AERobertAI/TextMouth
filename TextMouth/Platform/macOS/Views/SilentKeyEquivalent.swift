import AppKit
import SwiftUI

/// A key that does what a button's key equivalent does, with no second
/// button (FR03): `key`, pressed with no modifier anywhere in the window,
/// runs `action`. A SwiftUI button carries one shortcut, so the Close of
/// Show Description…, of the feed item's Book Info sheet, and of the
/// speech refusal report, whose shortcut is Return, answers Escape
/// through this. The view takes no space, draws nothing, and is no
/// element to VoiceOver.
struct SilentKeyEquivalent: NSViewRepresentable {
    /// The key.
    let key: KeyEquivalent
    /// What pressing it does.
    let action: () -> Void

    /// Builds the view that takes the key.
    func makeNSView(context: Context) -> SilentKeyEquivalentView {
        let view = SilentKeyEquivalentView(frame: .zero)
        view.key = key
        view.action = action
        view.setAccessibilityElement(false)
        return view
    }

    /// Keeps the view's key and action current.
    func updateNSView(_ view: SilentKeyEquivalentView, context: Context) {
        view.key = key
        view.action = action
    }

    /// No space at all, wherever the view is placed.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SilentKeyEquivalentView, context: Context) -> CGSize? {
        .zero
    }
}

/// The view that takes the key. AppKit offers every key pressed in a window
/// to each of the window's views as a key equivalent before the focused
/// view sees it, so the key works wherever focus is, as a button's shortcut
/// does, and before a focused text view can take it.
final class SilentKeyEquivalentView: NSView {
    /// The key, Escape until set.
    var key: KeyEquivalent = .escape
    /// What pressing it does; nothing until set.
    var action: () -> Void = {}

    /// Runs the action, and takes the key, when it is pressed with no modifier.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers.isEmpty, event.charactersIgnoringModifiers == String(key.character) else {
            return super.performKeyEquivalent(with: event)
        }
        action()
        return true
    }
}
