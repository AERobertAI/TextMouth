import AppKit
import Combine

/// Manages customizable keyboard shortcuts using NSEvent monitoring.
/// Posts notifications when shortcuts are triggered, so the rest of the app
/// can respond via the same NotificationCenter pattern already in use.
class KeyboardShortcutManager: ObservableObject {
    @Published var bindings: [ShortcutAction: [KeyBinding]] = [:]

    private var eventMonitor: Any?
    private let storageKey = "customKeyboardBindings"

    init() {
        loadBindings()
        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    // MARK: - Persistence

    private func loadBindings() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode([String: [KeyBinding]].self, from: data) {
            var loaded: [ShortcutAction: [KeyBinding]] = [:]
            for (rawValue, keys) in saved {
                if let action = ShortcutAction(rawValue: rawValue) {
                    loaded[action] = keys
                }
            }
            // Merge with defaults for any new actions not yet saved
            let defaults = ShortcutAction.defaultBindings
            for action in ShortcutAction.allCases {
                if loaded[action] == nil {
                    loaded[action] = defaults[action] ?? []
                }
            }
            bindings = loaded
        } else {
            bindings = ShortcutAction.defaultBindings
        }
    }

    private func saveBindings() {
        var dict: [String: [KeyBinding]] = [:]
        for (action, keys) in bindings {
            dict[action.rawValue] = keys
        }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    // MARK: - Binding Management

    func updateBindings(for action: ShortcutAction, to newBindings: [KeyBinding]) {
        bindings[action] = newBindings
        saveBindings()
    }

    func addBinding(_ binding: KeyBinding, to action: ShortcutAction) {
        // Remove this binding from any other action first (no duplicates)
        for otherAction in ShortcutAction.allCases where otherAction != action {
            bindings[otherAction]?.removeAll { $0 == binding }
        }
        if bindings[action] == nil {
            bindings[action] = []
        }
        if !(bindings[action]?.contains(binding) ?? false) {
            bindings[action]?.append(binding)
        }
        saveBindings()
    }

    func removeBinding(_ binding: KeyBinding, from action: ShortcutAction) {
        bindings[action]?.removeAll { $0 == binding }
        saveBindings()
    }

    func resetToDefaults() {
        bindings = ShortcutAction.defaultBindings
        saveBindings()
    }

    /// Get all bindings for an action
    func bindingsFor(_ action: ShortcutAction) -> [KeyBinding] {
        bindings[action] ?? []
    }

    /// Display string for the primary binding of an action
    func primaryDisplayString(for action: ShortcutAction) -> String {
        bindings[action]?.first?.displayString ?? "None"
    }

    /// All display strings for an action (for accessibility)
    func allDisplayStrings(for action: ShortcutAction) -> String {
        let keys = bindings[action] ?? []
        if keys.isEmpty { return "No shortcut" }
        return keys.map { $0.displayString }.joined(separator: " or ")
    }

    // MARK: - Event Monitoring

    private func startMonitoring() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            return self.handleKeyEvent(event) ? nil : event
        }
    }

    private func stopMonitoring() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        // Don't intercept keys when a text field/editor has focus
        if isTextInputFocused() { return false }

        // Check each action's bindings
        for (action, actionBindings) in bindings {
            for binding in actionBindings {
                if binding.matches(event) {
                    // Pass whether Shift was held (for secondary skip amounts)
                    // Only count it as "extra shift" if the binding itself doesn't require Shift
                    let shiftHeld = event.modifierFlags.contains(.shift) && !binding.shift
                    // Include the key window so only the focused book reader responds
                    var userInfo: [String: Any] = [:]
                    if shiftHeld { userInfo["shiftHeld"] = true }
                    if let keyWindow = NSApp.keyWindow {
                        userInfo["sourceWindow"] = keyWindow
                    }
                    NotificationCenter.default.post(name: action.notificationName, object: nil, userInfo: userInfo)
                    return true
                }
            }
        }
        return false
    }

    private func isTextInputFocused() -> Bool {
        guard let window = NSApp.keyWindow,
              let firstResponder = window.firstResponder else { return false }
        // NSTextView is the field editor for NSTextField, NSSearchField, etc.
        // Also check NSTextInputClient protocol adoption for custom text views.
        return firstResponder is NSTextView || firstResponder is NSTextField
    }
}
