import AppKit
import SwiftUI
import Accessibility

/// Moves VoiceOver focus to the element this is attached to when it first appears.
/// Uses multiple strategies since no single macOS API reliably moves VoiceOver:
///
/// 1. Makes the underlying NSView the window's first responder (VoiceOver tracks
///    keyboard focus by default via "cursor tracking")
/// 2. Posts AccessibilityNotification.ScreenChanged to tell VoiceOver to re-evaluate
/// 3. Posts NSAccessibility focusedUIElementChanged as a fallback
///
/// Usage: attach `.background(VoiceOverFocus())` to the SwiftUI element that
/// should receive initial VoiceOver focus when its containing view appears.
struct VoiceOverFocus: NSViewRepresentable {
    /// Delay before attempting to move focus. Sheets need time to fully present.
    var delay: TimeInterval = 0.6

    func makeNSView(context: Context) -> VoiceOverFocusTriggerView {
        let view = VoiceOverFocusTriggerView()
        view.focusDelay = delay
        return view
    }

    func updateNSView(_ nsView: VoiceOverFocusTriggerView, context: Context) {}
}

/// The NSView that performs the actual focus move via AppKit APIs.
/// Accepts first responder so makeFirstResponder can target it, which
/// causes VoiceOver's cursor tracking to follow keyboard focus.
class VoiceOverFocusTriggerView: NSView {
    var focusDelay: TimeInterval = 0.6
    private var hasFired = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window, !hasFired else { return }
        hasFired = true

        DispatchQueue.main.asyncAfter(deadline: .now() + focusDelay) { [weak self] in
            guard let self = self, let window = self.window else { return }
            self.moveFocus(in: window)
        }
    }

    private func moveFocus(in window: NSWindow) {
        // Strategy 1: Make the nearest accessible parent the first responder.
        // VoiceOver's cursor tracking follows keyboard focus by default.
        let target = findAccessibleParent() ?? self
        window.makeFirstResponder(target)

        // Strategy 2: Post the modern ScreenChanged notification (macOS 14+).
        // Tells VoiceOver a major UI change happened and it should move to this element.
        AccessibilityNotification.ScreenChanged(target).post()

        // Strategy 3: Mark the element as accessibility-focused and post the
        // legacy focusedUIElementChanged notification as a belt-and-suspenders fallback.
        target.setAccessibilityFocused(true)
        NSAccessibility.post(element: target, notification: .focusedUIElementChanged)
    }

    /// Walk up the view hierarchy to find the nearest view that VoiceOver
    /// considers an accessibility element.
    private func findAccessibleParent() -> NSView? {
        var current: NSView? = superview
        var steps = 0
        while let view = current, steps < 30 {
            if view.isAccessibilityElement() {
                return view
            }
            current = view.superview
            steps += 1
        }
        return nil
    }
}
