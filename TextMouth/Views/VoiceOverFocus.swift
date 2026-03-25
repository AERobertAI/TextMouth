import AppKit
import SwiftUI
import Accessibility

/// Moves VoiceOver focus to the element this is attached to when it first appears.
/// Uses an NSViewRepresentable to access AppKit's accessibility APIs directly,
/// since SwiftUI's @AccessibilityFocusState and @FocusState do not reliably
/// move VoiceOver's cursor on macOS.
///
/// Usage: `.background(VoiceOverFocus())` on the target element.
struct VoiceOverFocus: NSViewRepresentable {
    /// Delay before attempting to move focus. Sheets need time to fully present.
    var delay: TimeInterval = 0.8

    func makeNSView(context: Context) -> VoiceOverFocusTriggerView {
        let view = VoiceOverFocusTriggerView()
        view.focusDelay = delay
        return view
    }

    func updateNSView(_ nsView: VoiceOverFocusTriggerView, context: Context) {}
}

/// Append a timestamped message to the debug log file for VoiceOver focus debugging.
func voiceOverFocusLog(_ msg: String) {
    let logPath = TextMouthPaths.debugLogFile.path
    let line = "\(Date()) [VoiceOverFocus]: \(msg)\n"
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logPath),
           let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: logPath))
        }
    }
}

/// The NSView that performs the actual focus move via AppKit APIs.
class VoiceOverFocusTriggerView: NSView {
    var focusDelay: TimeInterval = 0.8
    private var hasFired = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window, !hasFired else { return }
        hasFired = true

        voiceOverFocusLog("scheduled: delay=\(focusDelay)s window='\(window.title)'")

        DispatchQueue.main.asyncAfter(deadline: .now() + focusDelay) { [weak self] in
            guard let self = self, let window = self.window else {
                voiceOverFocusLog("ABORTED: view or window gone before fire")
                return
            }
            self.moveFocus(in: window)
        }
    }

    private func moveFocus(in window: NSWindow) {
        // Walk the view tree looking for potential targets at different levels
        logViewHierarchy()

        // Try to find accessible siblings/children near us in the tree, not just parents.
        // The SwiftUI hosting view places our background view as a sibling of the
        // actual content view — so the target might be a sibling, not a parent.
        let target = findNearestAccessibleElement()

        if let target = target {
            let cls = NSStringFromClass(type(of: target))
            let role = target.accessibilityRole()?.rawValue ?? "nil"
            let label = target.accessibilityLabel() ?? "nil"
            voiceOverFocusLog("FOUND target: class=\(cls) role=\(role) label='\(label)'")

            // Strategy: setAccessibilityFocused + post notification
            // This was one of the three that showed results in earlier testing
            target.setAccessibilityFocused(true)
            NSAccessibility.post(element: target, notification: .focusedUIElementChanged)
            voiceOverFocusLog("POSTED: setAccessibilityFocused(true) + focusedUIElementChanged")
        } else {
            voiceOverFocusLog("NO TARGET FOUND — falling back to self")
            self.setAccessibilityFocused(true)
            NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
        }
    }

    /// Search for the nearest accessible element. Checks:
    /// 1. Siblings of self (other children of our parent)
    /// 2. Parent's accessibility children
    /// 3. Walking up to find an accessible ancestor
    private func findNearestAccessibleElement() -> NSView? {
        // Check siblings first — SwiftUI .background() places us as a sibling
        // of the actual content in the hosting view
        if let parent = superview {
            for sibling in parent.subviews where sibling !== self {
                if sibling.isAccessibilityElement() {
                    voiceOverFocusLog("  found accessible sibling: \(NSStringFromClass(type(of: sibling)))")
                    return sibling
                }
                // Check sibling's children
                for child in sibling.subviews {
                    if child.isAccessibilityElement() {
                        voiceOverFocusLog("  found accessible sibling child: \(NSStringFromClass(type(of: child)))")
                        return child
                    }
                }
            }

            // Check parent's accessibility children (these may differ from subviews)
            if let axChildren = parent.accessibilityChildren() {
                for child in axChildren {
                    if let view = child as? NSView, view !== self, view.isAccessibilityElement() {
                        voiceOverFocusLog("  found via accessibilityChildren: \(NSStringFromClass(type(of: view)))")
                        return view
                    }
                }
            }
        }

        // Walk up looking for an accessible ancestor
        var current: NSView? = superview
        var steps = 0
        while let view = current, steps < 30 {
            if view.isAccessibilityElement() {
                voiceOverFocusLog("  found accessible ancestor at step \(steps): \(NSStringFromClass(type(of: view)))")
                return view
            }
            current = view.superview
            steps += 1
        }

        return nil
    }

    /// Log the first several levels of the view hierarchy for debugging
    private func logViewHierarchy() {
        voiceOverFocusLog("--- View hierarchy from self ---")
        var current: NSView? = self
        var depth = 0
        while let view = current, depth < 12 {
            let cls = NSStringFromClass(type(of: view))
            let isAx = view.isAccessibilityElement()
            let role = view.accessibilityRole()?.rawValue ?? "nil"
            let label = view.accessibilityLabel() ?? "nil"
            let childCount = view.subviews.count
            let axChildCount = view.accessibilityChildren()?.count ?? 0
            voiceOverFocusLog("  [\(depth)] \(cls) isElement=\(isAx) role=\(role) label='\(label)' children=\(childCount) axChildren=\(axChildCount)")
            current = view.superview
            depth += 1
        }
        // Also log siblings
        if let parent = superview {
            voiceOverFocusLog("  siblings of self in parent (\(parent.subviews.count) total):")
            for (i, sibling) in parent.subviews.enumerated() {
                let cls = NSStringFromClass(type(of: sibling))
                let isAx = sibling.isAccessibilityElement()
                let isSelf = sibling === self
                voiceOverFocusLog("    sibling[\(i)] \(cls) isElement=\(isAx)\(isSelf ? " (SELF)" : "")")
            }
        }
    }
}
