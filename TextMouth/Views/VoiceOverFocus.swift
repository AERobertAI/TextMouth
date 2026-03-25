import AppKit
import SwiftUI
import Accessibility

/// The accessibility identifier placed on the SwiftUI element that should
/// receive VoiceOver focus. VoiceOverFocus searches the accessibility tree
/// for an element with this identifier.
let voiceOverFocusID = "vo-focus-target"

/// Moves VoiceOver focus to the element tagged with `.accessibilityIdentifier("vo-focus-target")`
/// in the same window. Attach as `.background(VoiceOverFocus())` alongside
/// the identifier on the target element.
///
/// How it works: on appear, walks the window's accessibility tree
/// (accessibilityChildren, recursively) to find the element with the
/// matching identifier, then posts focusedUIElementChanged to move
/// VoiceOver's cursor there.
struct VoiceOverFocus: NSViewRepresentable {
    var delay: TimeInterval = 0.8

    func makeNSView(context: Context) -> VoiceOverFocusTriggerView {
        let view = VoiceOverFocusTriggerView()
        view.focusDelay = delay
        return view
    }

    func updateNSView(_ nsView: VoiceOverFocusTriggerView, context: Context) {}
}

/// Append a timestamped message to the debug log file.
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

/// ViewModifier that adds VoiceOverFocus to only the first item in a list.
/// Use as `.modifier(FirstItemFocusModifier(isFirst: index == 0))`.
struct FirstItemFocusModifier: ViewModifier {
    let isFirst: Bool
    var delay: TimeInterval = 1.2

    func body(content: Content) -> some View {
        if isFirst {
            content
                .accessibilityIdentifier(voiceOverFocusID)
                .background(VoiceOverFocus(delay: delay))
        } else {
            content
        }
    }
}

/// The NSView that searches the accessibility tree and posts the focus notification.
class VoiceOverFocusTriggerView: NSView {
    var focusDelay: TimeInterval = 0.8
    private var hasFired = false

    /// Cancel-and-replace: when multiple VoiceOverFocus instances exist for the
    /// same window (SwiftUI @ViewBuilder re-evaluation), cancel the previous
    /// pending work and let the latest instance win.
    private static var pendingWork: [ObjectIdentifier: DispatchWorkItem] = [:]

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window, !hasFired else { return }
        hasFired = true

        let windowID = ObjectIdentifier(window)

        // Cancel any previous pending focus for this window
        if let existing = Self.pendingWork[windowID] {
            existing.cancel()
            voiceOverFocusLog("cancelled previous pending focus for '\(window.title)'")
        }

        voiceOverFocusLog("scheduled: delay=\(focusDelay)s window='\(window.title)'")

        // Schedule new work — capture window strongly since we need it after delay
        let work = DispatchWorkItem { [weak self] in
            // Remove from pending map
            Self.pendingWork.removeValue(forKey: windowID)

            // Use the window directly from the closure, not from self.window,
            // because self's view might have been removed from the window by
            // SwiftUI but the window itself is still valid
            guard !window.contentView!.subviews.isEmpty else {
                voiceOverFocusLog("ABORTED: window content gone")
                return
            }
            self?.findAndFocus(in: window)
            // If self was deallocated, search directly
            if self == nil {
                VoiceOverFocusTriggerView.staticFindAndFocus(in: window)
            }
        }
        Self.pendingWork[windowID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + focusDelay, execute: work)
    }

    /// Static version for when the trigger view has been deallocated by SwiftUI
    /// but the window is still valid (common with @ViewBuilder re-evaluation).
    static func staticFindAndFocus(in window: NSWindow) {
        guard let contentView = window.contentView else {
            voiceOverFocusLog("ERROR: window has no contentView")
            return
        }

        voiceOverFocusLog("searching (static) for identifier '\(voiceOverFocusID)' in '\(window.title)'...")

        // Create a temporary instance just to use the search methods
        let helper = VoiceOverFocusTriggerView()
        if let target = helper.findElementByIdentifier(voiceOverFocusID, root: contentView, depth: 0) {
            let desc = helper.describeElement(target)
            voiceOverFocusLog("FOUND target: \(desc)")
            helper.postFocusNotifications(target: target, window: window)
        } else {
            voiceOverFocusLog("NOT FOUND in static search")
        }
    }

    /// Search the window's accessibility tree for the element with identifier
    /// "vo-focus-target" and post a focus notification on it.
    private func findAndFocus(in window: NSWindow) {
        guard let contentView = window.contentView else {
            voiceOverFocusLog("ERROR: window has no contentView")
            return
        }

        voiceOverFocusLog("searching for identifier '\(voiceOverFocusID)' in '\(window.title)'...")

        if let target = findElementByIdentifier(voiceOverFocusID, root: contentView, depth: 0) {
            let desc = describeElement(target)
            voiceOverFocusLog("FOUND target: \(desc)")
            postFocusNotifications(target: target, window: window)
        } else {
            // Fallback: find the first interactive element that isn't a radio button
            // (the category picker). Look for the first list row or button.
            voiceOverFocusLog("identifier not found, trying fallback...")
            if let fallback = findFirstInteractiveElement(root: contentView, depth: 0) {
                let desc = describeElement(fallback)
                voiceOverFocusLog("FALLBACK target: \(desc)")
                postFocusNotifications(target: fallback, window: window)
            } else {
                voiceOverFocusLog("NO FALLBACK found either")
            }
        }
    }

    /// Post focus notifications to move VoiceOver's cursor to the target element.
    func postFocusNotifications(target: Any, window: NSWindow) {
        let isSheet = window.title.isEmpty

        // For non-sheet windows, only act if already key (don't steal from other windows).
        // For sheets, always act — sheets need activation to work with VoiceOver.
        if !isSheet && !window.isKeyWindow {
            voiceOverFocusLog("SKIPPED: window '\(window.title)' is not key, won't steal focus")
            return
        }

        // Activate window and notify VoiceOver — required for sheets
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
            voiceOverFocusLog("activated sheet window")
        }
        NSAccessibility.post(element: window, notification: .focusedWindowChanged)

        // Repeat ScreenChanged to catch VoiceOver when it's ready
        for attempt in 0..<4 {
            let delay = Double(attempt) * 0.3
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                if let targetView = target as? NSView {
                    window.makeFirstResponder(targetView)
                }
                AccessibilityNotification.ScreenChanged(target).post()
                if attempt == 0 {
                    voiceOverFocusLog("posting focus attempts (4x at 300ms intervals)")
                }
            }
        }
    }

    /// Fallback: find the first interactive element that isn't a radio button/group
    /// (to avoid landing on the category picker). Prefers list rows and buttons.
    func findFirstInteractiveElement(root: Any, depth: Int) -> Any? {
        guard depth < 15 else { return nil }

        if let obj = root as? NSObject {
            let role: String? = {
                if let view = obj as? NSView { return view.accessibilityRole()?.rawValue }
                guard obj.responds(to: Selector(("accessibilityRole"))) else { return nil }
                return obj.perform(Selector(("accessibilityRole")))?.takeUnretainedValue() as? String
            }()
            // Accept list rows, buttons (not radio buttons), text fields
            if let role = role {
                if role == "AXRow" || role == "AXCell" { return root }
                if role == "AXButton" { return root }
                if role == "AXTextField" { return root }
            }
        }

        // Search children
        let children: [Any]
        if let view = root as? NSView {
            children = view.accessibilityChildren() ?? []
        } else if let obj = root as? NSObject, obj.responds(to: Selector(("accessibilityChildren"))) {
            children = (obj.perform(Selector(("accessibilityChildren")))?.takeUnretainedValue() as? [Any]) ?? []
        } else {
            children = []
        }

        for child in children {
            if let found = findFirstInteractiveElement(root: child, depth: depth + 1) {
                return found
            }
        }
        return nil
    }

    /// Recursively search the accessibility tree for an element with the given identifier.
    /// Searches accessibilityChildren (what VoiceOver sees), not NSView subviews.
    func findElementByIdentifier(_ identifier: String, root: Any, depth: Int) -> Any? {
        // Don't go too deep
        guard depth < 15 else { return nil }

        // Check if this element has the identifier — works for both NSView
        // and non-NSView accessibility elements (SwiftUI's internal AccessibilityNode, etc.)
        if let obj = root as? NSObject {
            // Try the NSAccessibility method (works on NSView)
            if obj.responds(to: #selector(NSView.accessibilityIdentifier)) {
                if let view = obj as? NSView {
                    let axID = view.accessibilityIdentifier()
                    if !axID.isEmpty && axID == identifier {
                        return view
                    }
                }
            }
            // Try reading the identifier via KVC (works on SwiftUI AccessibilityNode).
            // Wrapped in @try-equivalent since some elements throw for undefined keys.
            if obj.responds(to: Selector(("accessibilityIdentifier"))) {
                if let axID = obj.perform(Selector(("accessibilityIdentifier")))?.takeUnretainedValue() as? String,
                   axID == identifier {
                    return root
                }
            }
        }

        // Search children
        let children: [Any]
        if let view = root as? NSView {
            children = view.accessibilityChildren() ?? []
        } else if let obj = root as? NSObject,
                  obj.responds(to: Selector(("accessibilityChildren"))) {
            children = (obj.value(forKey: "accessibilityChildren") as? [Any]) ?? []
        } else {
            children = []
        }

        for child in children {
            if let found = findElementByIdentifier(identifier, root: child, depth: depth + 1) {
                return found
            }
        }

        return nil
    }

    /// Log the first few levels of the accessibility tree for debugging.
    func logAccessibilityTree(root: Any, maxDepth: Int) {
        voiceOverFocusLog("--- Accessibility tree (first \(maxDepth) levels) ---")
        logTreeNode(root, depth: 0, maxDepth: maxDepth)
    }

    private func logTreeNode(_ node: Any, depth: Int, maxDepth: Int) {
        guard depth < maxDepth else { return }
        let indent = String(repeating: "  ", count: depth)
        let desc = describeElement(node)
        voiceOverFocusLog("\(indent)\(desc)")

        let children: [Any]
        if let view = node as? NSView {
            children = view.accessibilityChildren() ?? []
        } else if let obj = node as? NSObject,
                  obj.responds(to: Selector(("accessibilityChildren"))) {
            children = (obj.value(forKey: "accessibilityChildren") as? [Any]) ?? []
        } else {
            children = []
        }

        for child in children {
            logTreeNode(child, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    /// Human-readable description of an accessibility element.
    func describeElement(_ element: Any) -> String {
        if let view = element as? NSView {
            let cls = NSStringFromClass(type(of: view)).components(separatedBy: ".").last ?? "?"
            let role = view.accessibilityRole()?.rawValue ?? "nil"
            let label = view.accessibilityLabel() ?? "nil"
            let id = view.accessibilityIdentifier()
            return "\(cls) role=\(role) label='\(label)' id='\(id.isEmpty ? "nil" : id)'"
        }
        // For non-NSView accessibility elements, try to read properties safely
        if let obj = element as? NSObject {
            let cls = NSStringFromClass(type(of: obj)).components(separatedBy: ".").last ?? "?"
            let role: String = {
                guard obj.responds(to: Selector(("accessibilityRole"))) else { return "nil" }
                return obj.perform(Selector(("accessibilityRole")))?.takeUnretainedValue() as? String ?? "nil"
            }()
            let label: String = {
                guard obj.responds(to: Selector(("accessibilityLabel"))) else { return "nil" }
                return obj.perform(Selector(("accessibilityLabel")))?.takeUnretainedValue() as? String ?? "nil"
            }()
            let id: String = {
                guard obj.responds(to: Selector(("accessibilityIdentifier"))) else { return "nil" }
                return obj.perform(Selector(("accessibilityIdentifier")))?.takeUnretainedValue() as? String ?? "nil"
            }()
            return "\(cls) role=\(role) label='\(label)' id='\(id)'"
        }
        return String(describing: type(of: element))
    }
}
