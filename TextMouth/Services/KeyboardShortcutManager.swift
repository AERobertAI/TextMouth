import AppKit
import Combine

/// Manages customizable keyboard shortcuts using NSEvent monitoring.
/// Posts notifications when shortcuts are triggered, so the rest of the app
/// can respond via the same NotificationCenter pattern already in use.
///
/// The shortcuts live in the preferences store as the record of the ones the
/// user edited (FR12, `ShortcutEdits`); every other action follows this
/// build's defaults. Every change made through the manager goes through the
/// record and is saved there, and the manager takes up every change made
/// there by anyone else, such as the settings model applying an edit of
/// config.json, which mirrors the shortcuts; key presses match the keys in
/// force at once.
///
/// Each key press goes to a `ShortcutPressDispatcher`, which tells single
/// presses from double presses by the double-press time the store holds, and
/// says which action, if any, the press triggers; the manager posts it.
@MainActor
final class KeyboardShortcutManager: ObservableObject {
    /// The record of the shortcuts the user edited, as the store holds it.
    private(set) var edits: ShortcutEdits
    /// Every action's keys in force: the record's, with this build's
    /// defaults (`ShortcutEdits.effectiveBindings(defaults:)`), so no key
    /// belongs to two actions of one scope. Key presses match these. A
    /// change of the record and these is published once (`take(_:)`).
    private(set) var bindings: [ShortcutAction: [KeyBinding]]
    /// How soon a second press must follow the first to make a double press,
    /// in seconds (FR12), as the store holds it: one time for every
    /// shortcut. A change made anywhere, in the Shortcuts tab or in
    /// config.json, is published, and the next key press goes by it.
    private(set) var doublePressTime: TimeInterval

    private var eventMonitor: Any?
    /// The store holding the record.
    private let userDefaults: UserDefaults
    /// Where the actions' notifications are posted: the app's own center,
    /// which every window hears, unless a test passes one of its own.
    private let notificationCenter: NotificationCenter
    /// Reports changes to the record and the double-press time in the store.
    private var storeObserver: PreferenceObserver?
    /// Reads the time on the key presses' time line, for the dispatcher.
    private let clock: ShortcutPressDispatcher.Clock
    /// Starts the timer a waiting single press waits on, for the dispatcher.
    private let startTimer: ShortcutPressDispatcher.StartTimer
    /// Decides what each key press does, from the bindings in force: made
    /// on first use, since its closures reach back to the manager, and
    /// rebuilt whenever the bindings change (`take(_:)`).
    private lazy var dispatcher = ShortcutPressDispatcher(
        bindings: bindings,
        doublePressTime: { [weak self] in
            self?.doublePressTime ?? SettingsPolicy.shortcutDoublePressSeconds.defaultValue
        },
        clock: clock,
        startTimer: startTimer,
        perform: { [weak self] trigger in
            self?.post(trigger)
        }
    )

    /// Loads the record, follows its changes in the store from then on,
    /// and, unless told not to, starts watching key presses.
    /// - Parameters:
    ///   - userDefaults: The store holding the record: this process's
    ///     preferences unless a test passes its own.
    ///   - installsEventMonitor: False leaves key presses alone, for tests.
    ///   - notificationCenter: Where the actions' notifications go: the
    ///     default center unless a test passes its own, so that a key it
    ///     presses through the manager reaches no window of the app.
    ///   - clock: The time on the key presses' time line, the Mac's uptime
    ///     unless a test passes its own.
    ///   - startTimer: Starts the timer a waiting single press waits on, a
    ///     work item on the main queue unless a test passes its own, so
    ///     that no test waits.
    init(
        userDefaults: UserDefaults = TextMouthRuntime.current.preferences,
        installsEventMonitor: Bool = true,
        notificationCenter: NotificationCenter = .default,
        clock: ShortcutPressDispatcher.Clock? = nil,
        startTimer: ShortcutPressDispatcher.StartTimer? = nil
    ) {
        self.userDefaults = userDefaults
        self.notificationCenter = notificationCenter
        self.clock = clock ?? { ProcessInfo.processInfo.systemUptime }
        self.startTimer = startTimer ?? { delay, fire in MainQueuePressTimer(delay: delay, fire: fire) }
        let stored = Self.storedEdits(in: userDefaults)
        edits = stored
        bindings = stored.effectiveBindings(defaults: ShortcutAction.defaultBindings)
        doublePressTime = Self.doublePressTimePreference.read(from: userDefaults)
        let observedKeys = [Self.editsPreference.key, Self.doublePressTimePreference.key]
        storeObserver = PreferenceObserver(keys: observedKeys, in: userDefaults) { [weak self] key in
            if key == Self.doublePressTimePreference.key {
                self?.takeDoublePressTimeFromStore()
            } else {
                self?.takeEditsFromStore()
            }
        }
        if installsEventMonitor {
            startMonitoring()
        }
    }

    // MARK: - Persistence

    /// The record of the shortcuts the user edited (FR12) in the
    /// preferences store, under a key of its own, as
    /// `ShortcutEdits.storedData` writes it: an empty record while the store
    /// holds none. The settings model mirrors it in config.json through this
    /// same definition.
    nonisolated static let editsPreference = StoredPreference<ShortcutEdits>(
        key: "keyboardShortcutEdits",
        read: { store, key in
            store.data(forKey: key).map { ShortcutEdits.reading($0).edits } ?? ShortcutEdits()
        },
        write: { edits, store, key in
            guard let data = edits.storedData else { return }
            store.set(data, forKey: key)
        }
    )

    /// How soon a second press must follow the first to make a double press
    /// (FR12), in seconds, in the preferences store: one time for every
    /// shortcut, set in the Shortcuts tab and in config.json. It is read and
    /// written through `SettingsPolicy.validatedDoublePressSeconds(_:)`, so
    /// it is always 0.2 to 2 seconds in tenths, and half a second while the
    /// store holds none. The settings model mirrors it in config.json
    /// through this same definition.
    nonisolated static let doublePressTimePreference = StoredPreference<Double>(
        key: SettingsPolicy.shortcutDoublePressSeconds.key,
        read: { store, _ in
            SettingsPolicy.validatedDoublePressSeconds(SettingsPolicy.shortcutDoublePressSeconds.storedValue(in: store))
        },
        write: { seconds, store, key in
            store.set(SettingsPolicy.validatedDoublePressSeconds(seconds), forKey: key)
        }
    )

    /// The key under which every release before the record saved the whole
    /// map of every action's keys. The move to the record reads it once, at
    /// the first launch that finds no record (`moveSavedShortcutsIfNeeded`),
    /// and nothing writes it again, so it stays as a copy to go back to.
    nonisolated static let savedMapKey = "customKeyboardBindings"

    /// The keys in force as a store's record gives them, read only, for
    /// whoever follows the shortcuts without a manager of its own: an audio
    /// editor window says its buttons' keys in their hints. Its key is the
    /// record's, so a change of the record is a change of these.
    nonisolated static let bindingsPreference = StoredShortcutBindings(key: editsPreference.key)

    /// Names the preferences store in the repair lines of the debug log.
    nonisolated static let storeLogSource = "preferences"

    /// The record `store` holds, each entry left out of it logged as a
    /// repair; an empty record while there is none.
    private static func storedEdits(in store: UserDefaults) -> ShortcutEdits {
        guard let data = store.data(forKey: editsPreference.key) else { return ShortcutEdits() }
        let reading = ShortcutEdits.reading(data)
        ShortcutEdits.log(reading.skipped, source: storeLogSource, field: editsPreference.key)
        return reading.edits
    }

    /// Takes the record from the store when someone else changed it there.
    /// Nothing is written back: the record is saved only by the methods
    /// that change it.
    private func takeEditsFromStore() {
        take(Self.storedEdits(in: userDefaults))
    }

    /// Takes the double-press time from the store whenever it changes
    /// there, by `setDoublePressTime(_:)` or by anyone else, publishing it
    /// when it differs from the one in force.
    private func takeDoublePressTimeFromStore() {
        let stored = Self.doublePressTimePreference.read(from: userDefaults)
        guard stored != doublePressTime else { return }
        objectWillChange.send()
        doublePressTime = stored
    }

    /// Saves `seconds` as the double-press time, as the Shortcuts tab's
    /// stepper sets it: validated and in tenths of a second. The store
    /// reports the change at once, and the time in force follows.
    func setDoublePressTime(_ seconds: TimeInterval) {
        Self.doublePressTimePreference.write(seconds, to: userDefaults)
    }

    /// Makes `newEdits` the record in force, with its keys, publishing once
    /// when it differs from the one in force; key presses go by the new keys
    /// at once.
    private func take(_ newEdits: ShortcutEdits) {
        guard newEdits != edits else { return }
        objectWillChange.send()
        edits = newEdits
        bindings = newEdits.effectiveBindings(defaults: ShortcutAction.defaultBindings)
        dispatcher.rebuild(from: bindings)
    }

    /// Puts `changed` in force, then saves it. In force first: the store
    /// reports the save at once, within the write, and the record it then
    /// reads is the one already in force, so the change is published once.
    private func save(_ changed: ShortcutEdits) {
        take(changed)
        Self.editsPreference.write(changed, to: userDefaults)
    }

    // MARK: - Changing the Shortcuts

    /// Gives `action` exactly `newBindings`, as the user's, each taken from
    /// every other action of its scope (`ShortcutEdits.setKeys(_:for:)`,
    /// the one rule a key's owner follows). Replacing a key in Settings comes
    /// through here, so it can no longer leave one key on two actions.
    func updateBindings(for action: ShortcutAction, to newBindings: [KeyBinding]) {
        change(action, to: newBindings)
    }

    /// Adds `binding` to `action`'s keys, which makes them the user's, and
    /// takes it from any other action of the same scope; an action of the
    /// other scope keeps it, as the editor's Space and the reader's do.
    func addBinding(_ binding: KeyBinding, to action: ShortcutAction) {
        let keys = bindingsFor(action)
        change(action, to: keys.contains(binding) ? keys : keys + [binding])
    }

    /// Removes `binding` from `action`'s keys, which makes them the user's.
    func removeBinding(_ binding: KeyBinding, from action: ShortcutAction) {
        change(action, to: bindingsFor(action).filter { $0 != binding })
    }

    /// Gives `action` back to this build's defaults (Reset to Default),
    /// less any key an edited action of its scope holds; every key it held
    /// goes back to the unedited action whose default it is.
    func resetToDefault(_ action: ShortcutAction) {
        var changed = edits
        changed.reset(action)
        save(changed)
    }

    /// Gives every action back to this build's defaults (Reset to Defaults).
    func resetToDefaults() {
        save(ShortcutEdits())
    }

    /// Whether the user edited `action`'s keys, which then stay theirs until
    /// Reset to Default, even when they are its default keys.
    func isEdited(_ action: ShortcutAction) -> Bool {
        edits.isEdited(action)
    }

    /// Makes `keys` `action`'s, as the user's. Keys that leave an unedited
    /// action as it is change nothing: it stays TextMouth's.
    private func change(_ action: ShortcutAction, to keys: [KeyBinding]) {
        guard edits.isEdited(action) || keys != bindingsFor(action) else { return }
        var changed = edits
        changed.setKeys(keys, for: action)
        save(changed)
    }

    // MARK: - The Move to the Record (FR12)

    /// Moves the shortcuts saved before the record existed into it, at the
    /// first launch that finds no record in `store` (FR12, section 4.2 of
    /// the design), and returns whether it did.
    ///
    /// The settings model calls this at launch, before it applies
    /// config.json, with the file's entries (`fileListings`, nil when there
    /// was no file it could read), and leaves the file's shortcuts out of
    /// what it applies when this returns true: the move reads them itself,
    /// and applying the old form's lists afterwards would make every action
    /// the user's. That launch's own save then writes config.json in the new
    /// form.
    ///
    /// Nothing is moved when the store holds a record already, nor when
    /// config.json is in the new form already (an entry written "default"),
    /// which is then read as any edit is: over an empty record, written now,
    /// so that the move never runs again. The whole map (`savedMapKey`) is
    /// read and left as it is; nothing writes it again.
    @discardableResult
    static func moveSavedShortcutsIfNeeded(in store: UserDefaults, fileListings: [ShortcutAction: ShortcutListing]?) -> Bool {
        guard store.data(forKey: editsPreference.key) == nil else { return false }
        if let fileListings, fileListings.values.contains(where: \.followsDefaults) {
            DiagnosticLog.event(
                .storage,
                "SHORTCUT_EDITS_MOVED: config.json is in the new form already; reading it over an empty record"
            )
            editsPreference.write(ShortcutEdits(), to: store)
            return false
        }
        let savedMap = store.data(forKey: savedMapKey).map(ShortcutEdits.reading)
        if let savedMap {
            ShortcutEdits.log(savedMap.skipped, source: storeLogSource, field: savedMapKey)
        }
        let fileLists = fileListings?.compactMapValues(\.bindings)
        let moved = ShortcutEdits.migrating(savedMap: savedMap?.edits.keysByEditedAction, fileLists: fileLists)
        ShortcutEdits.log(moved.sharedKeys, source: storeLogSource, field: editsPreference.key)
        let sources = [
            savedMap.map { "\(savedMapKey) (\($0.edits.keysByEditedAction.count) actions)" },
            fileLists.map { "config.json (\($0.count) actions)" },
        ].compactMap { $0 }
        let edited = moved.edits.editedActions.map(\.rawValue)
        DiagnosticLog.event(
            .storage,
            "SHORTCUT_EDITS_MOVED: made the record of edited shortcuts from "
                + (sources.isEmpty ? "nothing saved" : sources.joined(separator: " and "))
                + "; edited: " + (edited.isEmpty ? "none" : edited.joined(separator: ", "))
        )
        editsPreference.write(moved.edits, to: store)
        return true
    }

    // MARK: - config.json's Entries (FR12)

    /// Puts config.json's entries in place in `store`'s record (FR12,
    /// sections 5.1 and 5.2 of the design, `ShortcutEdits.adopting(_:)`):
    /// a list makes its action the user's, "default" gives it back, and a key
    /// two edited actions then hold is left to one of them and logged, naming
    /// the key and both actions. No entries change nothing.
    ///
    /// - Returns: Whether such a key was settled, so the settings model
    ///   saves config.json again at once and the file shows the keys in
    ///   force, as it is saved after a repaired value.
    @discardableResult
    static func adopt(_ listings: [ShortcutAction: ShortcutListing], in store: UserDefaults) -> Bool {
        guard !listings.isEmpty else { return false }
        let adopted = editsPreference.read(from: store).adopting(listings)
        ShortcutEdits.log(adopted.sharedKeys, source: "config.json", field: SettingsPolicy.keyboardShortcuts.key)
        editsPreference.write(adopted.edits, to: store)
        return !adopted.sharedKeys.isEmpty
    }

    // MARK: - Reading the Shortcuts

    /// Get all bindings for an action
    func bindingsFor(_ action: ShortcutAction) -> [KeyBinding] {
        bindings[action] ?? []
    }

    /// Display string for the primary binding of an action
    func primaryDisplayString(for action: ShortcutAction) -> String {
        bindings[action]?.first?.displayString ?? "None"
    }

    /// An action's keys in force in words, as VoiceOver and a braille
    /// display take them: "Space or K", or "No shortcut".
    func allDisplayStrings(for action: ShortcutAction) -> String {
        KeyBinding.accessibleDisplayString(for: bindingsFor(action))
    }

    /// The action of `scope` whose keys in force hold `binding`, if any: the
    /// one a key recorded in Settings is taken from.
    func action(holding binding: KeyBinding, in scope: ShortcutScope) -> ShortcutAction? {
        ShortcutAction.allCases.first { $0.scope == scope && bindingsFor($0).contains(binding) }
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

    /// Acts on a key pressed anywhere in TextMouth, as the event monitor
    /// hands it over: in the key window, whose first responder has the
    /// keyboard. Returns whether the press was a shortcut and is consumed.
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        let keyWindow = NSApp.keyWindow
        return handleKeyEvent(event, keyWindow: keyWindow, firstResponder: keyWindow?.firstResponder)
    }

    /// Acts on the key press `event`, made in `keyWindow` while
    /// `firstResponder` has the keyboard: hands it to the dispatcher, which
    /// posts the action it triggers, now or, for a single press waiting to
    /// see whether a second follows, once the double-press time is up.
    /// Returns true when the press was a shortcut's and goes no further, or
    /// false to leave it to the window, its menus, and its first responder.
    ///
    /// The event monitor passes the key window and its first responder.
    /// Tests pass a key press made up for them, no window or one never
    /// shown, and a stand-in for the first responder, such as the field
    /// editor of a text field being edited: no key is really pressed.
    func handleKeyEvent(_ event: NSEvent, keyWindow: NSWindow?, firstResponder: NSResponder?) -> Bool {
        // A key press alone has the characters and the repeat flag read
        // below; AppKit raises an exception for them on any other event.
        guard event.type == .keyDown else { return false }
        return dispatcher.handle(ShortcutPressDispatcher.Press(
            stroke: KeyBinding.from(event: event),
            time: event.timestamp,
            window: keyWindow,
            // Only the shortcuts of the key window's scope match; in a sheet
            // over an audio editor none do, so its own controls take every key.
            scope: Self.scope(ofKeyWindow: keyWindow),
            // A field being edited keeps its typing and the keys it edits
            // with (`shouldHandle`).
            textInputIsFocused: Self.isTextInput(firstResponder),
            isRepeat: event.isARepeat
        ))
    }

    /// Posts the action `trigger` names, with the window it was pressed in,
    /// so that only that window acts (`WindowCommandRouting`), and whether
    /// Shift was held beyond the binding's own modifiers.
    private func post(_ trigger: ShortcutPressDispatcher.Trigger) {
        var userInfo: [String: Any] = ["action": trigger.action.rawValue]
        if trigger.shiftHeld {
            userInfo["shiftHeld"] = true
        }
        if let window = trigger.window {
            userInfo["sourceWindow"] = window
        }
        if trigger.action == .restartSleepTimer {
            let windowNumber = trigger.window.map { String($0.windowNumber) } ?? "none"
            SleepTimerService.log(
                .event,
                "SHORTCUT_RECEIVED action=restart-sleep-timer binding=\(trigger.binding.displayString) "
                    + "sourceWindow=\(windowNumber)"
            )
        }
        notificationCenter.post(name: trigger.action.notificationName, object: nil, userInfo: userInfo)
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

    /// Whether the manager acts on a key press matching `binding`, given
    /// whether a text field or text view has the keyboard (`isTextInput`).
    ///
    /// Away from text every binding acts. A field being edited keeps what
    /// it types and edits with (B03): a key with neither Command nor
    /// Control types, Shift and Option alone included, and the keys
    /// `TextEditingKeys` lists delete, move, and select in its text,
    /// Command-Delete, Command-A, and the Command arrows among them. Every
    /// other key with Command or Control is an app shortcut and acts from a
    /// field too, as Command-I's Book Info does, and Shift-Command-T, which
    /// closes the sleep timer's panel from its own minutes field.
    nonisolated static func shouldHandle(
        binding: KeyBinding,
        whenTextInputIsFocused: Bool
    ) -> Bool {
        guard whenTextInputIsFocused else { return true }
        return (binding.command || binding.control) && !TextEditingKeys.contains(binding)
    }

    /// Whether Shift was held beyond the modifiers of the binding a press
    /// matched: the press had Shift and the binding has none. The action is
    /// told so (`shiftHeld`), and Skip Forward and Skip Backward then go by
    /// the Playback tab's Shift units; the dispatcher matches such a press
    /// to its binding without Shift where none with Shift is its own
    /// (finding 4 of FR12's design).
    nonisolated static func hasExtraShift(
        eventHasShift: Bool,
        bindingRequiresShift: Bool
    ) -> Bool {
        eventHasShift && !bindingRequiresShift
    }

    /// Whether `responder`, as the key window's first responder, takes
    /// text from the keyboard: a text view, editable or only selectable
    /// (a feed item's description is read and copied from one); the field
    /// editor through which a text field or a search field is edited,
    /// SwiftUI's included, which is itself a text view; or a text field in
    /// the moment before its field editor takes over. The reader draws its
    /// text in a view of its own, which is none of these.
    static func isTextInput(_ responder: NSResponder?) -> Bool {
        responder is NSTextView || responder is NSTextField
    }
}

/// Every action's keys in force as a preferences store's record of the
/// user's edits gives them (`KeyboardShortcutManager.bindingsPreference`),
/// read only: every change goes through the record
/// (`KeyboardShortcutManager.editsPreference`).
struct StoredShortcutBindings: Sendable {
    /// The store key whose changes change the keys in force: the record's.
    let key: String

    /// Every action's keys in force, as `store`'s record gives them with
    /// this build's defaults.
    func read(from store: UserDefaults) -> [ShortcutAction: [KeyBinding]] {
        KeyboardShortcutManager.editsPreference.read(from: store)
            .effectiveBindings(defaults: ShortcutAction.defaultBindings)
    }
}
