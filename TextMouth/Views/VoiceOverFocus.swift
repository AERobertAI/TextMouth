import AppKit
import SwiftUI
import Accessibility
import os.log

private let focusLog = Logger(subsystem: "com.textmouth", category: "VoiceOverFocus")

/// Which strategy to use for moving VoiceOver focus. Set this to test
/// each approach independently. Defaults to `.makeFirstResponder`.
enum VoiceOverFocusStrategy: String {
    /// Move keyboard focus via NSWindow.makeFirstResponder; VoiceOver's
    /// cursor tracking should follow.
    case makeFirstResponder
    /// Post AccessibilityNotification.ScreenChanged (macOS 14+).
    case screenChanged
    /// Call setAccessibilityFocused(true) + post focusedUIElementChanged.
    case legacyPost
    /// Try all three in sequence with delays between them.
    case all
}

/// Moves VoiceOver focus to the element this is attached to when it first appears.
///
/// Usage: attach `.background(VoiceOverFocus())` to the SwiftUI element that
/// should receive initial VoiceOver focus when its containing view appears.
struct VoiceOverFocus: NSViewRepresentable {
    /// Delay before attempting to move focus. Sheets need time to fully present.
    var delay: TimeInterval = 0.6

    /// Which strategy to use. Change this to test individual approaches.
    var strategy: VoiceOverFocusStrategy = .screenChanged

    func makeNSView(context: Context) -> VoiceOverFocusTriggerView {
        let view = VoiceOverFocusTriggerView()
        view.focusDelay = delay
        view.strategy = strategy
        return view
    }

    func updateNSView(_ nsView: VoiceOverFocusTriggerView, context: Context) {}
}

/// The NSView that performs the actual focus move via AppKit APIs.
class VoiceOverFocusTriggerView: NSView {
    var focusDelay: TimeInterval = 0.6
    var strategy: VoiceOverFocusStrategy = .screenChanged
    private var hasFired = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window, !hasFired else { return }
        hasFired = true

        let strat = strategy
        focusLog.info("VoiceOverFocus: scheduled with strategy=\(strat.rawValue) delay=\(self.focusDelay)s window=\(window.title)")

        DispatchQueue.main.asyncAfter(deadline: .now() + focusDelay) { [weak self] in
            guard let self = self, let window = self.window else {
                focusLog.warning("VoiceOverFocus: view or window gone before fire")
                return
            }
            self.moveFocus(in: window, strategy: strat)
        }
    }

    private func moveFocus(in window: NSWindow, strategy: VoiceOverFocusStrategy) {
        // Log the view hierarchy walk
        let target = findAccessibleParent()
        let resolvedTarget = target ?? self

        focusLog.info("""
            VoiceOverFocus: firing strategy=\(strategy.rawValue)
              self=\(String(describing: type(of: self)))
              foundParent=\(target != nil)
              target=\(String(describing: type(of: resolvedTarget)))
              targetClass=\(NSStringFromClass(type(of: resolvedTarget)))
              targetRole=\(resolvedTarget.accessibilityRole()?.rawValue ?? "nil")
              targetLabel=\(resolvedTarget.accessibilityLabel() ?? "nil")
              targetIsElement=\(resolvedTarget.isAccessibilityElement())
              windowTitle=\(window.title)
              currentFirstResponder=\(String(describing: window.firstResponder.map { NSStringFromClass(type(of: $0)) }))
            """)

        switch strategy {
        case .makeFirstResponder:
            let success = window.makeFirstResponder(resolvedTarget)
            focusLog.info("VoiceOverFocus: makeFirstResponder success=\(success)")

        case .screenChanged:
            AccessibilityNotification.ScreenChanged(resolvedTarget).post()
            focusLog.info("VoiceOverFocus: posted ScreenChanged")

        case .legacyPost:
            resolvedTarget.setAccessibilityFocused(true)
            NSAccessibility.post(element: resolvedTarget, notification: .focusedUIElementChanged)
            focusLog.info("VoiceOverFocus: posted setAccessibilityFocused + focusedUIElementChanged")

        case .all:
            // Try all three with small gaps
            let success = window.makeFirstResponder(resolvedTarget)
            focusLog.info("VoiceOverFocus [all]: makeFirstResponder success=\(success)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                AccessibilityNotification.ScreenChanged(resolvedTarget).post()
                focusLog.info("VoiceOverFocus [all]: posted ScreenChanged")
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                resolvedTarget.setAccessibilityFocused(true)
                NSAccessibility.post(element: resolvedTarget, notification: .focusedUIElementChanged)
                focusLog.info("VoiceOverFocus [all]: posted legacy focusedUIElementChanged")
            }
        }
    }

    /// Walk up the view hierarchy to find the nearest view that VoiceOver
    /// considers an accessibility element. Logs each step for debugging.
    private func findAccessibleParent() -> NSView? {
        var current: NSView? = superview
        var steps = 0
        while let view = current, steps < 30 {
            let isElement = view.isAccessibilityElement()
            let role = view.accessibilityRole()?.rawValue ?? "nil"
            let label = view.accessibilityLabel() ?? "nil"
            let cls = NSStringFromClass(type(of: view))

            if steps < 10 || isElement {
                focusLog.debug("  walk[\(steps)]: \(cls) role=\(role) label=\(label) isElement=\(isElement)")
            }

            if isElement {
                focusLog.info("VoiceOverFocus: found accessible parent at step \(steps): \(cls) role=\(role) label=\(label)")
                return view
            }
            current = view.superview
            steps += 1
        }
        focusLog.warning("VoiceOverFocus: no accessible parent found in \(steps) steps")
        return nil
    }
}
