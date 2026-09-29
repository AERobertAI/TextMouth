import AppKit
import SwiftUI
import Accessibility

/// The accessibility identifier placed on the SwiftUI element that should
/// receive VoiceOver focus. VoiceOverFocus searches the accessibility tree
/// for an element with this identifier.
let voiceOverFocusID = "vo-focus-target"

struct StandardVoiceOverFocus: NSViewRepresentable {
    var delay: TimeInterval = 0.8

    func makeNSView(context: Context) -> StandardVoiceOverFocusTriggerView {
        let view = StandardVoiceOverFocusTriggerView()
        view.focusDelay = delay
        return view
    }

    func updateNSView(_ nsView: StandardVoiceOverFocusTriggerView, context: Context) {}
}

struct VoiceOverFocus: NSViewRepresentable {
    var delay: TimeInterval = 1.2

    func makeNSView(context: Context) -> VoiceOverFocusTriggerView {
        let view = VoiceOverFocusTriggerView()
        view.focusDelay = delay
        return view
    }

    func updateNSView(_ nsView: VoiceOverFocusTriggerView, context: Context) {}
}

/// Prefix that marks VoiceOver focus diagnostics in the shared debug log.
let voiceOverFocusLogPrefix = "[VoiceOverFocus]"

/// Append a timestamped VoiceOver focus message to the debug log file.
///
/// Goes through the shared writer so focus diagnostics share one serial
/// queue with every other log line (two queues appending to the same file
/// could interleave lines), obey the same size cap, and can never crash the
/// app when the disk is full.
func voiceOverFocusLog(_ msg: String) {
    TextMouthPaths.appendLog(to: TextMouthPaths.debugLogFile, message: "\(voiceOverFocusLogPrefix): \(msg)")
}

/// Marks exactly one element as the target for a sheet's one-time VoiceOver
/// focus request. The caller decides whether that target is the first item, a
/// current item, or another contextually useful control.
struct InitialVoiceOverFocusModifier: ViewModifier {
    let isTarget: Bool
    var delay: TimeInterval = 1.2

    func body(content: Content) -> some View {
        if isTarget {
            content
                .accessibilityIdentifier(voiceOverFocusID)
                .background(VoiceOverFocus(delay: delay))
        } else {
            content
        }
    }
}

class StandardVoiceOverFocusTriggerView: NSView {
    var focusDelay: TimeInterval = 0.8
    private var hasFired = false

    /// Cancel-and-replace: when multiple VoiceOverFocus instances exist for the
    /// same window (SwiftUI @ViewBuilder re-evaluation), cancel the previous
    /// pending work and let the latest instance win.
    private static var pendingWork: [ObjectIdentifier: DispatchWorkItem] = [:]

    /// Pure focus-stealing guard used before posting accessibility events.
    static func shouldPostFocus(
        isSheet: Bool,
        targetWindowIsKey: Bool,
        anotherWindowIsKey: Bool
    ) -> Bool {
        isSheet || targetWindowIsKey || !anotherWindowIsKey
    }

    /// Sheets receive extra retries because their accessibility hierarchy is
    /// commonly published later than a standard window's hierarchy.
    static func focusAttemptCount(isSheet: Bool) -> Int {
        isSheet ? 4 : 2
    }

    /// Defines which accessibility nodes are safe generic fallback targets.
    static func acceptsFallback(role: String, label: String?, isScrollerPart: Bool) -> Bool {
        if role == "AXRow" || role == "AXCell" || role == "AXTextField" { return true }
        return role == "AXButton" && !isScrollerPart && label?.isEmpty == false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window, !hasFired else { return }
        hasFired = true

        let windowID = ObjectIdentifier(window)

        if let existing = Self.pendingWork[windowID] {
            existing.cancel()
            voiceOverFocusLog("cancelled previous pending focus for '\(window.title)'")
        }

        voiceOverFocusLog("scheduled: delay=\(focusDelay)s window='\(window.title)'")

        let work = DispatchWorkItem { [weak self] in
            Self.pendingWork.removeValue(forKey: windowID)

            guard !window.contentView!.subviews.isEmpty else {
                voiceOverFocusLog("ABORTED: window content gone")
                return
            }
            self?.findAndFocus(in: window)
            if self == nil {
                StandardVoiceOverFocusTriggerView.staticFindAndFocus(in: window)
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

        let helper = StandardVoiceOverFocusTriggerView()
        if let target = helper.findElementByIdentifier(voiceOverFocusID, root: contentView, depth: 0) {
            let desc = helper.describeElement(target)
            voiceOverFocusLog("FOUND target: \(desc)")
            helper.postFocusNotifications(target: target, window: window)
        } else {
            voiceOverFocusLog("NOT FOUND in static search")
        }
    }

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

    func postFocusNotifications(target: Any, window: NSWindow) {
        let isSheet = window.title.isEmpty

        let anotherWindowIsKey = NSApp.keyWindow.map { $0 !== window } ?? false
        guard Self.shouldPostFocus(
            isSheet: isSheet,
            targetWindowIsKey: window.isKeyWindow,
            anotherWindowIsKey: anotherWindowIsKey
        ) else {
            voiceOverFocusLog("SKIPPED: another window is key, won't steal focus")
            return
        }

        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
            voiceOverFocusLog("activated sheet window")
        }
        NSAccessibility.post(element: window, notification: .focusedWindowChanged)

        let attempts = Self.focusAttemptCount(isSheet: isSheet)

        for attempt in 0..<attempts {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt) * 0.3) {
                if let targetView = target as? NSView {
                    window.makeFirstResponder(targetView)
                }
                AccessibilityNotification.ScreenChanged(target).post()
                if attempt == 0 {
                    voiceOverFocusLog("posting focus (\(attempts) attempts)")
                }
            }
        }
    }

    func isVoiceOverOnTarget(_ target: Any, window: NSWindow) -> Bool {
        guard let focused = NSApp.accessibilityFocusedUIElement else { return false }

        if let focusedObj = focused as? NSObject, let targetObj = target as? NSObject,
           focusedObj === targetObj {
            return true
        }

        if let focusedObj = focused as? NSObject,
           focusedObj.responds(to: Selector(("accessibilityIdentifier"))) {
            if let focusedID = focusedObj.perform(Selector(("accessibilityIdentifier")))?.takeUnretainedValue() as? String,
               focusedID == voiceOverFocusID {
                return true
            }
        }

        if let focusedObj = focused as? NSObject, let targetObj = target as? NSObject {
            let focusedLabel: String? = {
                if let v = focusedObj as? NSView { return v.accessibilityLabel() }
                guard focusedObj.responds(to: Selector(("accessibilityLabel"))) else { return nil }
                return focusedObj.perform(Selector(("accessibilityLabel")))?.takeUnretainedValue() as? String
            }()
            let targetLabel: String? = {
                if let v = targetObj as? NSView { return v.accessibilityLabel() }
                guard targetObj.responds(to: Selector(("accessibilityLabel"))) else { return nil }
                return targetObj.perform(Selector(("accessibilityLabel")))?.takeUnretainedValue() as? String
            }()
            if let fl = focusedLabel, let tl = targetLabel, !fl.isEmpty, fl == tl {
                return true
            }
        }

        return false
    }

    func findFirstInteractiveElement(root: Any, depth: Int) -> Any? {
        guard depth < 15 else { return nil }

        if let obj = root as? NSObject {
            let role: String? = {
                if let view = obj as? NSView { return view.accessibilityRole()?.rawValue }
                guard obj.responds(to: Selector(("accessibilityRole"))) else { return nil }
                return obj.perform(Selector(("accessibilityRole")))?.takeUnretainedValue() as? String
            }()
            if let role = role {
                let label = accessibilityLabel(for: root)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let className = NSStringFromClass(type(of: obj))
                let isScrollerPart = className.contains("Scroller")

                if Self.acceptsFallback(role: role, label: label, isScrollerPart: isScrollerPart) {
                    return root
                }
            }
        }

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

    private func accessibilityLabel(for value: Any) -> String? {
        if let view = value as? NSView {
            return view.accessibilityLabel()
        }
        guard let obj = value as? NSObject,
              obj.responds(to: Selector(("accessibilityLabel"))) else {
            return nil
        }
        return obj.perform(Selector(("accessibilityLabel")))?.takeUnretainedValue() as? String
    }

    func findElementByIdentifier(_ identifier: String, root: Any, depth: Int) -> Any? {
        guard depth < 15 else { return nil }

        if let obj = root as? NSObject {
            if obj.responds(to: #selector(NSView.accessibilityIdentifier)) {
                if let view = obj as? NSView {
                    let axID = view.accessibilityIdentifier()
                    if !axID.isEmpty && axID == identifier {
                        return view
                    }
                }
            }
            if obj.responds(to: Selector(("accessibilityIdentifier"))) {
                if let axID = obj.perform(Selector(("accessibilityIdentifier")))?.takeUnretainedValue() as? String,
                   axID == identifier {
                    return root
                }
            }
        }

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

    func describeElement(_ element: Any) -> String {
        if let view = element as? NSView {
            let cls = NSStringFromClass(type(of: view)).components(separatedBy: ".").last ?? "?"
            let role = view.accessibilityRole()?.rawValue ?? "nil"
            let label = view.accessibilityLabel() ?? "nil"
            let id = view.accessibilityIdentifier()
            return "\(cls) role=\(role) label='\(label)' id='\(id.isEmpty ? "nil" : id)'"
        }
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

final class VoiceOverFocusTriggerView: NSView {
    var focusDelay: TimeInterval = 1.2
    private var hasFired = false
    private static let focusCheckDelays: [TimeInterval] = [0.05, 0.15, 0.3, 0.6, 1.0, 1.5]
    private var pendingAttemptWork: [DispatchWorkItem] = []
    private var pendingCheckWork: [DispatchWorkItem] = []
    private var didReachTarget = false

    private static var pendingWork: [ObjectIdentifier: DispatchWorkItem] = [:]

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window, !hasFired else { return }
        hasFired = true

        let windowID = ObjectIdentifier(window)

        if let existing = Self.pendingWork[windowID] {
            existing.cancel()
            voiceOverFocusLog("cancelled previous pending focus for '\(window.title)'")
        }

        voiceOverFocusLog("scheduled: delay=\(focusDelay)s window='\(window.title)'")

        let work = DispatchWorkItem { [weak self] in
            Self.pendingWork.removeValue(forKey: windowID)

            guard !window.contentView!.subviews.isEmpty else {
                voiceOverFocusLog("ABORTED: window content gone")
                return
            }
            self?.findAndFocus(in: window)
            if self == nil {
                VoiceOverFocusTriggerView.staticFindAndFocus(in: window)
            }
        }
        Self.pendingWork[windowID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + focusDelay, execute: work)
    }

    static func staticFindAndFocus(in window: NSWindow) {
        guard let contentView = window.contentView else {
            voiceOverFocusLog("ERROR: window has no contentView")
            return
        }

        voiceOverFocusLog("searching (static) for identifier '\(voiceOverFocusID)' in '\(window.title)'...")

        let helper = VoiceOverFocusTriggerView()
        if let target = helper.findElementByIdentifier(voiceOverFocusID, root: contentView, depth: 0) {
            let desc = helper.describeElement(target)
            voiceOverFocusLog("FOUND target: \(desc)")
            helper.postFocusNotifications(target: target, window: window)
        } else {
            voiceOverFocusLog("NOT FOUND in static search")
        }
    }

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

    func postFocusNotifications(target: Any, window: NSWindow) {
        let isSheet = window.title.isEmpty

        if !isSheet && !window.isKeyWindow {
            voiceOverFocusLog("SKIPPED: window '\(window.title)' is not key, won't steal focus")
            return
        }

        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
            voiceOverFocusLog("activated sheet window")
        }
        NSAccessibility.post(element: window, notification: .focusedWindowChanged)

        cancelPendingFocusWork()
        didReachTarget = false

        for attempt in 0..<4 {
            let delay = Double(attempt) * 0.3
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                guard !self.didReachTarget else {
                    voiceOverFocusLog("attempt \(attempt + 1): skipped because target was already reached")
                    return
                }
                if let targetView = target as? NSView {
                    window.makeFirstResponder(targetView)
                    voiceOverFocusLog("attempt \(attempt + 1): made first responder \(self.describeElement(targetView))")
                }
                AccessibilityNotification.ScreenChanged(target).post()
                if attempt == 0 {
                    voiceOverFocusLog("posting focus attempts (4x at 300ms intervals)")
                }
                voiceOverFocusLog(
                    "attempt \(attempt + 1): posted ScreenChanged to \(self.describeElement(target)); keyWindow=\(window.isKeyWindow); firstResponder=\(self.describeResponder(window.firstResponder))"
                )
                self.scheduleFocusChecks(
                    target: target,
                    window: window,
                    attempt: attempt + 1,
                    baseDelay: delay
                )
            }
            pendingAttemptWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    private func scheduleFocusChecks(target: Any, window: NSWindow, attempt: Int, baseDelay: TimeInterval) {
        for checkDelay in Self.focusCheckDelays {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                let focusedDescription = self.describeFocusedElement()
                let matched = self.focusedElementMatches(target)
                voiceOverFocusLog(
                    "attempt \(attempt) check +\(String(format: "%.2f", checkDelay))s: matchedTarget=\(matched); focused=\(focusedDescription); firstResponder=\(self.describeResponder(window.firstResponder)); keyWindow=\(window.isKeyWindow)"
                )
                if matched && !self.didReachTarget {
                    self.didReachTarget = true
                    self.cancelPendingFocusWork()
                    voiceOverFocusLog("confirmed target reached after attempt \(attempt); cancelled remaining sheet retries")
                }
            }
            pendingCheckWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + baseDelay + checkDelay, execute: work)
        }
    }

    private func cancelPendingFocusWork() {
        pendingAttemptWork.forEach { $0.cancel() }
        pendingCheckWork.forEach { $0.cancel() }
        pendingAttemptWork.removeAll()
        pendingCheckWork.removeAll()
    }

    private func focusedElementMatches(_ target: Any) -> Bool {
        guard let focused = NSApp.accessibilityFocusedUIElement else { return false }

        if let focusedObj = focused as? NSObject, let targetObj = target as? NSObject,
           focusedObj === targetObj {
            return true
        }

        if let focusedDescription = focused as? NSObject,
           let targetDescription = target as? NSObject,
           accessibilityIdentifier(for: focusedDescription) == accessibilityIdentifier(for: targetDescription),
           accessibilityIdentifier(for: focusedDescription) != nil {
            return true
        }

        let focusedLabel = accessibilityLabel(for: focused as Any)
        let targetLabel = accessibilityLabel(for: target)
        return focusedLabel != nil && focusedLabel == targetLabel
    }

    private func describeFocusedElement() -> String {
        guard let focused = NSApp.accessibilityFocusedUIElement else { return "nil" }
        return describeElement(focused)
    }

    private func describeResponder(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        if let view = responder as? NSView {
            return describeElement(view)
        }
        return String(describing: type(of: responder))
    }

    private func accessibilityIdentifier(for value: Any) -> String? {
        if let view = value as? NSView {
            let identifier = view.accessibilityIdentifier()
            return identifier.isEmpty ? nil : identifier
        }
        guard let obj = value as? NSObject,
              obj.responds(to: Selector(("accessibilityIdentifier"))) else {
            return nil
        }
        return obj.perform(Selector(("accessibilityIdentifier")))?.takeUnretainedValue() as? String
    }

    private func accessibilityLabel(for value: Any) -> String? {
        if let view = value as? NSView {
            return view.accessibilityLabel()
        }
        guard let obj = value as? NSObject,
              obj.responds(to: Selector(("accessibilityLabel"))) else {
            return nil
        }
        return obj.perform(Selector(("accessibilityLabel")))?.takeUnretainedValue() as? String
    }

    func findFirstInteractiveElement(root: Any, depth: Int) -> Any? {
        guard depth < 15 else { return nil }

        if let obj = root as? NSObject {
            let role: String? = {
                if let view = obj as? NSView { return view.accessibilityRole()?.rawValue }
                guard obj.responds(to: Selector(("accessibilityRole"))) else { return nil }
                return obj.perform(Selector(("accessibilityRole")))?.takeUnretainedValue() as? String
            }()
            if let role = role {
                if role == "AXRow" || role == "AXCell" { return root }
                if role == "AXButton" { return root }
                if role == "AXTextField" { return root }
            }
        }

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

    func findElementByIdentifier(_ identifier: String, root: Any, depth: Int) -> Any? {
        guard depth < 15 else { return nil }

        if let obj = root as? NSObject {
            if obj.responds(to: #selector(NSView.accessibilityIdentifier)) {
                if let view = obj as? NSView {
                    let axID = view.accessibilityIdentifier()
                    if !axID.isEmpty && axID == identifier {
                        return view
                    }
                }
            }
            if obj.responds(to: Selector(("accessibilityIdentifier"))) {
                if let axID = obj.perform(Selector(("accessibilityIdentifier")))?.takeUnretainedValue() as? String,
                   axID == identifier {
                    return root
                }
            }
        }

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

    func describeElement(_ element: Any) -> String {
        if let view = element as? NSView {
            let cls = NSStringFromClass(type(of: view)).components(separatedBy: ".").last ?? "?"
            let role = view.accessibilityRole()?.rawValue ?? "nil"
            let label = view.accessibilityLabel() ?? "nil"
            let id = view.accessibilityIdentifier()
            return "\(cls) role=\(role) label='\(label)' id='\(id.isEmpty ? "nil" : id)'"
        }
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
