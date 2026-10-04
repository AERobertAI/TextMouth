import AppKit
import Combine

/// Manages customizable keyboard shortcuts using NSEvent monitoring.
/// Posts notifications when shortcuts are triggered, so the rest of the app
/// can respond via the same NotificationCenter pattern already in use.
///
/// The bindings live in the preferences store. The manager saves each change
/// made through it there, and takes up every change made there by anyone
/// else, such as the settings model applying an edit of config.json, which
/// mirrors the shortcuts; key presses match the new bindings at once.
@MainActor
final class KeyboardShortcutManager: ObservableObject {
    @Published var bindings: [ShortcutAction: [KeyBinding]] = [:]

    private var eventMonitor: Any?
    /// The store holding the custom bindings.
    private let userDefaults: UserDefaults
    /// Reports changes to the bindings in the store.
    private var storeObserver: PreferenceObserver?

    /// Loads the bindings, follows their changes in the store from then on,
    /// and, unless told not to, starts watching key presses.
    /// - Parameters:
    ///   - userDefaults: The store holding the custom bindings: this
    ///     process's preferences unless a test passes its own.
    ///   - installsEventMonitor: False leaves key presses alone, for tests.
    init(userDefaults: UserDefaults = TextMouthRuntime.current.preferences, installsEventMonitor: Bool = true) {
        self.userDefaults = userDefaults
        bindings = Self.bindingsPreference.read(from: userDefaults)
        storeObserver = PreferenceObserver(keys: [Self.bindingsPreference.key], in: userDefaults) { [weak self] _ in
            self?.takeBindingsFromStore()
        }
        if installsEventMonitor {
            startMonitoring()
        }
    }

    // MARK: - Persistence

    /// The bindings of every action in the preferences store, saved as JSON
    /// keyed by the actions' names under the key every release has used, so
    /// saved shortcuts keep loading. An action the saved bindings leave out,
    /// such as one added since they were saved, gets its defaults. The
    /// settings model mirrors the bindings in config.json through this same
    /// definition.
    nonisolated static let bindingsPreference = StoredPreference<[ShortcutAction: [KeyBinding]]>(
        key: "customKeyboardBindings",
        read: { store, key in
            guard let data = store.data(forKey: key),
                  let saved = try? JSONDecoder().decode([String: [KeyBinding]].self, from: data) else {
                return ShortcutAction.defaultBindings
            }
            return KeyboardShortcutManager.bindings(
                addingDefaultsTo: [ShortcutAction: [KeyBinding]](keyedByRawValue: saved)
            )
        },
        write: { bindings, store, key in
            guard let data = try? JSONEncoder().encode(bindings.keyedByRawValue) else { return }
            store.set(data, forKey: key)
        }
    )

    /// `saved` with each action it leaves out given its default bindings,
    /// except any binding another action of its scope already uses.
    nonisolated static func bindings(
        addingDefaultsTo saved: [ShortcutAction: [KeyBinding]]
    ) -> [ShortcutAction: [KeyBinding]] {
        var loaded = saved
        let defaults = ShortcutAction.defaultBindings
        // The bindings each scope's actions use: a key may mean one thing in
        // a reader and another in the audio editor, never two in one place.
        var claimedBindings: [ShortcutScope: Set<KeyBinding>] = [:]
        for (action, bindings) in loaded {
            claimedBindings[action.scope, default: []].formUnion(bindings)
        }
        for action in ShortcutAction.allCases where loaded[action] == nil {
            // Preserve existing custom ownership during upgrades. A newly
            // introduced default must not duplicate an older user-assigned
            // binding because dictionary iteration would otherwise make the
            // action that fires nondeterministic.
            let availableDefaults = (defaults[action] ?? []).filter {
                !claimedBindings[action.scope, default: []].contains($0)
            }
            loaded[action] = availableDefaults
            claimedBindings[action.scope, default: []].formUnion(availableDefaults)
        }
        return loaded
    }

    /// The bindings once `requested`, from config.json, are in place: each
    /// action it names takes exactly the bindings it lists, and every other
    /// action keeps its own, except any binding the file gives a named
    /// action of its scope, which moves there as a shortcut recorded in
    /// Settings moves from the action that had it. A file that changes a
    /// few shortcuts thus never leaves one key on two actions of one scope,
    /// which would make the action it triggers a matter of chance.
    nonisolated static func bindings(
        _ current: [ShortcutAction: [KeyBinding]],
        adopting requested: [ShortcutAction: [KeyBinding]]
    ) -> [ShortcutAction: [KeyBinding]] {
        var claimed: [ShortcutScope: Set<KeyBinding>] = [:]
        for (action, bindings) in requested {
            claimed[action.scope, default: []].formUnion(bindings)
        }
        var adopted: [ShortcutAction: [KeyBinding]] = [:]
        for (action, bindings) in current {
            adopted[action] = bindings.filter { !claimed[action.scope, default: []].contains($0) }
        }
        for (action, bindings) in requested {
            adopted[action] = bindings
        }
        return adopted
    }

    private func saveBindings() {
        Self.bindingsPreference.write(bindings, to: userDefaults)
    }

    /// Takes the bindings from the store when someone else changed them
    /// there. Nothing is written back: `bindings` saves only through the
    /// methods that change it.
    private func takeBindingsFromStore() {
        let stored = Self.bindingsPreference.read(from: userDefaults)
        if stored != bindings {
            bindings = stored
        }
    }

    // MARK: - Binding Management

    func updateBindings(for action: ShortcutAction, to newBindings: [KeyBinding]) {
        bindings[action] = newBindings
        saveBindings()
    }

    func addBinding(_ binding: KeyBinding, to action: ShortcutAction) {
        // Remove this binding from any other action of the same scope first
        // (no duplicates where one key press could mean two things); an
        // action of the other scope keeps it, as the editor's Space and the
        // reader's do.
        for otherAction in ShortcutAction.allCases where otherAction != action && otherAction.scope == action.scope {
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
        let textInputIsFocused = isTextInputFocused()
        // Only the shortcuts of the key window's scope match; in a sheet over
        // an audio editor none do, so its own controls take every key.
        guard let scope = Self.scope(ofKeyWindow: NSApp.keyWindow) else { return false }

        // Check each action's bindings
        for (action, actionBindings) in bindings where action.scope == scope {
            for binding in actionBindings {
                if binding.matches(event) {
                    // Plain typing must continue to reach text fields. Command-
                    // and Control-based bindings represent explicit shortcuts,
                    // however, and need to keep working from fields such as the
                    // sleep timer's custom-minutes input so they can close the
                    // panel they opened.
                    guard Self.shouldHandle(
                        binding: binding,
                        whenTextInputIsFocused: textInputIsFocused
                    ) else {
                        continue
                    }

                    // Pass whether Shift was held (for secondary skip amounts)
                    // Only count it as "extra shift" if the binding itself doesn't require Shift
                    let shiftHeld = Self.hasExtraShift(
                        eventHasShift: event.modifierFlags.contains(.shift),
                        bindingRequiresShift: binding.shift
                    )
                    // Include the key window so only the focused book reader responds
                    var userInfo: [String: Any] = ["action": action.rawValue]
                    if shiftHeld { userInfo["shiftHeld"] = true }
                    if let keyWindow = NSApp.keyWindow {
                        userInfo["sourceWindow"] = keyWindow
                    }
                    if action == .restartSleepTimer {
                        let windowNumber = NSApp.keyWindow.map { String($0.windowNumber) } ?? "none"
                        SleepTimerService.log(
                            .event,
                            "SHORTCUT_RECEIVED action=restart-sleep-timer binding=\(binding.displayString) "
                                + "sourceWindow=\(windowNumber)"
                        )
                    }
                    NotificationCenter.default.post(name: action.notificationName, object: nil, userInfo: userInfo)
                    return true
                }
            }
        }
        return false
    }

    /// The scope whose shortcuts a key pressed in `keyWindow` matches: the
    /// audio editor's in an editor window (FR04); none in a sheet over one,
    /// whose fields and buttons take every key; the app's everywhere else,
    /// as before the editor, with no key window included.
    static func scope(ofKeyWindow keyWindow: NSWindow?) -> ShortcutScope? {
        scope(
            windowIdentifier: keyWindow?.identifier?.rawValue,
            sheetParentIdentifier: keyWindow?.sheetParent?.identifier?.rawValue
        )
    }

    /// The scope for a key window identified as `windowIdentifier`, a sheet
    /// over a window identified as `sheetParentIdentifier` when it is one:
    /// `scope(ofKeyWindow:)`'s rule, apart from AppKit.
    nonisolated static func scope(windowIdentifier: String?, sheetParentIdentifier: String?) -> ShortcutScope? {
        let editor = AudioEditorWindowController.windowIdentifier
        if windowIdentifier == editor { return .audioEditor }
        if sheetParentIdentifier == editor { return nil }
        return .app
    }

    /// Preserve normal text entry unless the binding uses a conventional
    /// command modifier that clearly identifies it as an app shortcut.
    nonisolated static func shouldHandle(
        binding: KeyBinding,
        whenTextInputIsFocused: Bool
    ) -> Bool {
        !whenTextInputIsFocused || binding.command || binding.control
    }

    nonisolated static func hasExtraShift(
        eventHasShift: Bool,
        bindingRequiresShift: Bool
    ) -> Bool {
        eventHasShift && !bindingRequiresShift
    }

    private func isTextInputFocused() -> Bool {
        guard let window = NSApp.keyWindow,
              let firstResponder = window.firstResponder else { return false }
        // NSTextView is the field editor for NSTextField, NSSearchField, etc.
        // Also check NSTextInputClient protocol adoption for custom text views.
        return firstResponder is NSTextView || firstResponder is NSTextField
    }
}
