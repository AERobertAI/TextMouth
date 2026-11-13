#if os(macOS)
import AppKit
#else
import UIKit
#endif
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
/// says which action, if any, the press triggers; the manager posts it. A key
/// equivalent's key, a menu command's or one of the Record window's buttons'
/// (FR12's branch D), is never taken: its menu item or button shows the key
/// in force (`keyEquivalent(for:)`) and acts on it, as menus always have.
@MainActor
final class KeyboardShortcutManager: ObservableObject {
    /// The record of the shortcuts the user edited, as the store holds it.
    private(set) var edits: ShortcutEdits
    /// Every action's keys in force: the record's, with this build's
    /// defaults (`ShortcutEdits.effectiveBindings(defaults:)`), so no key
    /// belongs to two actions in one kind of window. Key presses match these
    /// where each action's scope reaches (`scope(of:)`). A change of the
    /// record and these is published once (`take(_:)`).
    private(set) var bindings: [ShortcutAction: [KeyBinding]]
    /// How soon a second press must follow the first to make a double press,
    /// in seconds (FR12), as the store holds it: one time for every
    /// shortcut. A change made anywhere, in the Shortcuts tab or in
    /// config.json, is published, and the next key press goes by it.
    private(set) var doublePressTime: TimeInterval

#if os(macOS)
    private var eventMonitor: Any?
#endif
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
        scopes: edits.scopesInForce,
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
#if os(macOS)
        if installsEventMonitor {
            startMonitoring()
        }
#endif
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
        dispatcher.rebuild(from: bindings, scopes: newEdits.scopesInForce)
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
    /// every other action whose scope overlaps its own (`ShortcutEdits.setKeys(_:for:)`,
    /// the one rule a key's owner follows). Replacing a key in Settings comes
    /// through here, so it can no longer leave one key on two actions.
    /// Returns why nothing changed when `action` cannot take one of the keys
    /// (`ShortcutAction.refusal(ofKeys:holding:)`), or nil.
    @discardableResult
    func updateBindings(for action: ShortcutAction, to newBindings: [KeyBinding]) -> ShortcutRefusal? {
        change(action, to: newBindings)
    }

    /// Adds `binding` to `action`'s keys, which makes them the user's, and
    /// takes it from any other action whose scope overlaps its own; an
    /// action working elsewhere keeps it, as the editor's Space and the
    /// reader's do.
    /// Returns why nothing changed when `action` cannot take it, or nil.
    @discardableResult
    func addBinding(_ binding: KeyBinding, to action: ShortcutAction) -> ShortcutRefusal? {
        let keys = bindingsFor(action)
        return change(action, to: keys.contains(binding) ? keys : keys + [binding])
    }

    /// Removes `binding` from `action`'s keys, which makes them the user's.
    func removeBinding(_ binding: KeyBinding, from action: ShortcutAction) {
        // A removal adds no key, so nothing refuses it.
        _ = change(action, to: bindingsFor(action).filter { $0 != binding })
    }

    /// Gives `action` back to this build's defaults (Reset to Default),
    /// less any key an edited action whose scope overlaps its own holds;
    /// every key it held goes back to the unedited action whose default it
    /// is.
    func resetToDefault(_ action: ShortcutAction) {
        var changed = edits
        changed.reset(action)
        save(changed)
    }

    /// Gives every action back to this build's defaults (Reset to Defaults).
    func resetToDefaults() {
        save(ShortcutEdits())
    }

    /// Makes `action` work in `scope`, as the user's (FR12's branch E): it
    /// keeps its keys in force, each taken from every other action whose
    /// scope now overlaps its own, as recording a key takes it. A scope the
    /// action may not be given (`ShortcutAction.availableScopes`), or the
    /// one it works in already, changes nothing. Reset to Default gives back
    /// its default scope.
    func setScope(_ scope: ShortcutScope, for action: ShortcutAction) {
        guard action.availableScopes.contains(scope), scope != self.scope(of: action) else { return }
        var changed = edits
        changed.setScope(scope, for: action, keys: bindingsFor(action))
        save(changed)
    }

    /// Whether the user edited `action`'s keys, which then stay theirs until
    /// Reset to Default, even when they are its default keys.
    func isEdited(_ action: ShortcutAction) -> Bool {
        edits.isEdited(action)
    }

    /// Makes `keys` `action`'s, as the user's, unless `action` cannot take
    /// them (FR12's branch D), whose refusal it returns: a key they add to
    /// its keys in force that it cannot take, or a second key for a key
    /// equivalent's action (`ShortcutAction.refusal(ofKeys:holding:)`), a
    /// key it has in force already never being refused, so a store edited
    /// by hand never stops the user changing the action. Keys that leave an
    /// unedited action as it is change nothing: it stays TextMouth's.
    private func change(_ action: ShortcutAction, to keys: [KeyBinding]) -> ShortcutRefusal? {
        if let refusal = action.refusal(ofKeys: keys, holding: bindingsFor(action)) {
            return refusal
        }
        guard edits.isEdited(action) || keys != bindingsFor(action) else { return nil }
        var changed = edits
        changed.setKeys(keys, for: action)
        save(changed)
        return nil
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
    /// config.json is in the new form already (an entry written "default",
    /// or as an object naming where its action works), which is then read
    /// as any edit is: over an empty record, written now, so that the move
    /// never runs again. The whole map (`savedMapKey`) is read and left as
    /// it is; nothing writes it again.
    @discardableResult
    static func moveSavedShortcutsIfNeeded(in store: UserDefaults, fileListings: [ShortcutAction: ShortcutListing]?) -> Bool {
        guard store.data(forKey: editsPreference.key) == nil else { return false }
        if let fileListings, fileListings.values.contains(where: \.isInTheRecordsForm) {
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
    /// a list makes its action the user's, an object makes it the user's
    /// working in the kind of window it names (FR12's branch E), "default"
    /// gives it back, and a key two edited actions then hold where their
    /// scopes overlap is left to one of them and logged, naming the key and
    /// both actions. An entry naming a kind of window its action cannot work
    /// in, or giving it a key it cannot take, such as a menu command's key
    /// without Command or Control (FR12's branch D), is left out and logged,
    /// the action keeping what it has (`ShortcutEdits.entriesLeftOut(of:)`).
    /// No entries change nothing.
    ///
    /// A file in the old form, a list for every action and none of the
    /// record's forms (`ShortcutListing.isInTheRecordsForm`), is read as the
    /// move reads it (`moveSavedShortcutsIfNeeded(in:fileListings:)`): a
    /// list whose keys are a default of its action
    /// (`ShortcutEdits.keysAreADefault`) is left out and edits nothing, so
    /// an action the user edited in the app keeps its edit and an unedited
    /// one keeps following the defaults, and only a list that differs from
    /// every default makes its action the user's. A file in the new form is
    /// read as above, a list equal to its action's default still making the
    /// action the user's: an edited action set back to its default keys
    /// stays the user's.
    ///
    /// - Returns: Whether such a key was settled, an entry left out, or an
    ///   old-form file's list left out as a default, so the settings model
    ///   saves config.json again at once and the file shows the keys in
    ///   force, as it is saved after a repaired value; for an old-form file,
    ///   in the new form, which a second reading changes nothing in.
    @discardableResult
    static func adopt(_ listings: [ShortcutAction: ShortcutListing], in store: UserDefaults) -> Bool {
        guard !listings.isEmpty else { return false }
        let record = editsPreference.read(from: store)
        let leftOut = record.entriesLeftOut(of: listings)
        let (applied, defaultsLeftOut) = listingsLeavingOutDefaults(of: listings, skipping: Set(leftOut.keys))
        let adopted = record.adopting(applied)
        ShortcutEdits.log(leftOut, source: "config.json", field: SettingsPolicy.keyboardShortcuts.key)
        ShortcutEdits.log(adopted.sharedKeys, source: "config.json", field: SettingsPolicy.keyboardShortcuts.key)
        if defaultsLeftOut > 0 {
            // A count only, naming no key.
            DiagnosticLog.trace(
                .storage,
                "config.json is in the old form: \(defaultsLeftOut) of its lists are an action's default and edit nothing"
            )
        }
        editsPreference.write(adopted.edits, to: store)
        return !adopted.sharedKeys.isEmpty || !leftOut.isEmpty || defaultsLeftOut > 0
    }

    /// `listings` less the actions in `skipping` (entries left out for
    /// another reason) and, for a file in the old form, less every list
    /// whose keys are a default of its action by the rule the move uses
    /// (`ShortcutEdits.keysAreADefault`); and how many lists that second
    /// step left out. The form is the whole file's, `skipping` included,
    /// and the keys other actions hold, which the rule reads, are the
    /// file's own lists, as the move reads them. A file with any entry in
    /// the record's form is in the new form, whose lists are all the user's:
    /// none is left out.
    private static func listingsLeavingOutDefaults(
        of listings: [ShortcutAction: ShortcutListing],
        skipping skipped: Set<ShortcutAction>
    ) -> (kept: [ShortcutAction: ShortcutListing], leftOut: Int) {
        let usable = listings.filter { !skipped.contains($0.key) }
        guard !listings.values.contains(where: \.isInTheRecordsForm) else { return (usable, 0) }
        let fileLists = listings.compactMapValues(\.bindings)
        let kept = usable.filter { action, _ in
            guard let keys = fileLists[action] else { return true }
            return !ShortcutEdits.keysAreADefault(of: action, given: keys, among: fileLists)
        }
        return (kept, usable.count - kept.count)
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

    /// Where `action`'s shortcuts work (FR12's branch E).
    func scope(of action: ShortcutAction) -> ShortcutScope {
        edits.scope(of: action)
    }

    /// The actions other than `action` that hold fewer keys in force than
    /// `earlier` gave them, in the order Settings lists them: the ones a
    /// change of `action`'s keys took a key from, whether the very key or one
    /// clashing with it (a key equivalent's key and its double press, FR12's
    /// branch D), as the Shortcuts tab says after recording a key.
    func actions(thatLostKeysSince earlier: [ShortcutAction: [KeyBinding]], besides action: ShortcutAction) -> [ShortcutAction] {
        ShortcutAction.allCases.filter { other in
            other != action && !(earlier[other] ?? []).allSatisfy(bindingsFor(other).contains)
        }
    }

    /// The default keys `action` goes without while it follows its defaults,
    /// each with the action that has it in force (FR12's branch D), in the
    /// order its defaults list them: New from Text's Shift-Command-T, Show
    /// Sleep Timer's too, or a default the user gave another action. Empty
    /// for an action the user edited, whose keys are the user's, and for one
    /// with all its defaults.
    func defaultKeysHeldElsewhere(for action: ShortcutAction) -> [DefaultKeyHeldElsewhere] {
        guard !isEdited(action) else { return [] }
        let inForce = bindingsFor(action)
        return (ShortcutAction.defaultBindings[action] ?? []).filter { !inForce.contains($0) }.compactMap { key in
            let holder = ShortcutAction.allCases.first { other in
                other != action && bindingsFor(other).contains { edits.key(key, of: action, clashesWith: $0, of: other) }
            }
            return holder.map { DefaultKeyHeldElsewhere(key: key, holder: $0) }
        }
    }

    // MARK: - Key Equivalents (FR12's Branch D)

    /// The key `action`'s menu item or button shows and acts on, for an
    /// action whose key is a key equivalent (`ShortcutAction.isKeyEquivalent`):
    /// its first key in force that can be one, or nil for none, as while
    /// another action has its default key. Nil for every other action, whose
    /// keys the manager matches itself.
    func keyEquivalent(for action: ShortcutAction) -> KeyBinding? {
        Self.keyEquivalent(for: action, in: bindings)
    }

    /// `keyEquivalent(for:)` among `bindings`, every action's keys in force,
    /// for whoever reads them from a store without a manager of its own.
    nonisolated static func keyEquivalent(for action: ShortcutAction, in bindings: [ShortcutAction: [KeyBinding]]) -> KeyBinding? {
        guard action.isKeyEquivalent else { return nil }
        return bindings[action]?.first(where: \.canBeKeyEquivalent)
    }

    /// The action whose single press waits on the key `binding` is a press
    /// of, single or double, in `scope` (FR12): the key's single action, when
    /// the key also has a double action that does not escalate it, so each
    /// single press waits out the double-press time before it acts. Nil
    /// when the key's presses act at once.
    func waitingAction(for binding: KeyBinding, in scope: ShortcutScope) -> ShortcutAction? {
        // The first kind of window the scope reaches where the key waits.
        ShortcutWindowKind.allCases.lazy.filter(scope.reaches).compactMap { kind in
            self.dispatcher.index.actions(for: binding, in: kind).flatMap { $0.singleWaits ? $0.single : nil }
        }.first
    }

    // MARK: - Recording a Shortcut

    /// The Shortcuts tab's recorders that are recording, held weakly: while
    /// one records, every key press is left to it and no shortcut acts, so
    /// the key it records never runs the action that has it, whichever key
    /// monitor AppKit asks first. A recorder that goes away without saying
    /// so stops counting.
    private var recorders: [WeakRecorder] = []

    /// Whether a recorder of the Shortcuts tab is recording.
    var isRecordingShortcut: Bool {
        recorders.contains { $0.recorder != nil }
    }

    /// Says that `recorder` is recording: key presses are left to it.
    func recordingStarted(by recorder: AnyObject) {
        recorders.removeAll { $0.recorder == nil || $0.recorder === recorder }
        recorders.append(WeakRecorder(recorder: recorder))
    }

    /// Says that `recorder` has stopped: shortcuts act again once no
    /// recorder records.
    func recordingStopped(by recorder: AnyObject) {
        recorders.removeAll { $0.recorder == nil || $0.recorder === recorder }
    }

    // MARK: - Trying a Double Press

    /// The Try a Double Press trial running, if any: the next key presses
    /// are its, and no shortcut acts on them. A change is published, so the
    /// Shortcuts tab says a trial waits for its presses.
    private var trial: DoublePressTrial? {
        willSet { objectWillChange.send() }
    }

    /// What the last Try a Double Press found, kept so the Shortcuts tab
    /// shows it as text a braille display can read again after VoiceOver has
    /// said it (the review of October 10, item C); nil before any trial
    /// ends. A trial ended without a report keeps the one before.
    private(set) var lastDoublePressTrialOutcome: DoublePressTrial.Outcome? {
        willSet { objectWillChange.send() }
    }

    /// Whether Try a Double Press is waiting for its two presses.
    var isTryingDoublePress: Bool {
        trial != nil
    }

    /// Starts Try a Double Press (FR12, section 6.2 of the design): for five
    /// seconds the next two key presses are no shortcuts, and `report` is
    /// told what they made, measured against the double-press time in
    /// force, which is kept as the last outcome too. A trial already running
    /// ends without a report.
    func tryDoublePress(report: @escaping @MainActor (DoublePressTrial.Outcome) -> Void) {
        trial?.cancel()
        let trial = DoublePressTrial(doublePressTime: doublePressTime, startTimer: startTimer) { [weak self] outcome in
            self?.trial = nil
            self?.lastDoublePressTrialOutcome = outcome
            report(outcome)
        }
        self.trial = trial
        trial.start()
    }

    // MARK: - Event Monitoring

#if os(macOS)
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
        // While the Shortcuts tab records a key, every press is its.
        guard event.type == .keyDown, !isRecordingShortcut else { return false }
        let stroke = KeyBinding.from(event: event)
        // While Try a Double Press runs, the presses it measures are its.
        if let trial {
            return trial.take(stroke, at: event.timestamp, isRepeat: event.isARepeat)
        }
        // A Space while the Library list types a title that goes on with one
        // ("the h", the Leading articles setting), the list still having
        // the keyboard, is the list's, as letters are there; at any other
        // time it is Play or Pause.
        // Judged by the list's own clock, as the list judges it next.
        if stroke == KeyBinding(key: "space"), firstResponder is NSTableView,
           TitleTypingSpaceClaim.shared.takesSpace(in: keyWindow) {
            return false
        }
        return dispatcher.handle(ShortcutPressDispatcher.Press(
            stroke: stroke,
            time: event.timestamp,
            window: keyWindow,
            // Only the shortcuts whose scopes reach the key window's kind
            // match; in a sheet over an audio editor none do, so its own
            // controls take every key.
            kind: Self.windowKind(ofKeyWindow: keyWindow),
            // A field being edited keeps its typing and the keys it edits
            // with (`shouldHandle`).
            textInputIsFocused: Self.isTextInput(firstResponder),
            isRepeat: event.isARepeat,
            // A sheet's or an alert's buttons keep Return and Escape.
            keyWindowIsDialog: Self.isDialog(keyWindow)
        ))
    }

    /// Whether `window` is a dialog whose own buttons answer Return and
    /// Escape (the review of October 10, item B): a sheet, attached to its
    /// window or styled as one (AppKit makes every sheet, an alert's
    /// included, a document-modal window), or the window of a modal session,
    /// such as an alert run on its own. No shortcut takes those keys there
    /// (`KeyBinding.isDialogKey`), so a sheet's default button answers
    /// Return though Open Selected Book has it everywhere else.
    static func isDialog(_ window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window.sheetParent != nil
            || window.styleMask.contains(.docModalWindow)
            || window === NSApp.modalWindow
    }

#endif
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
#if os(macOS)
        if trigger.action == .restartSleepTimer {
            let windowNumber = trigger.window.map { String($0.windowNumber) } ?? "none"
            SleepTimerService.log(
                .event,
                "SHORTCUT_RECEIVED action=restart-sleep-timer binding=\(trigger.binding.displayString) "
                    + "sourceWindow=\(windowNumber)"
            )
        }
#endif
        notificationCenter.post(name: trigger.action.notificationName, object: nil, userInfo: userInfo)
    }

#if os(macOS)
    /// The kind of window a key pressed while `keyWindow` is key is pressed
    /// in, whose scopes' shortcuts match it (FR12's branch E): a sheet's
    /// window's kind (`pressKind(window:sheetParent:)`), and `.other` with no
    /// key window.
    ///
    /// A sheet over a sheet counts as the window under them both, which
    /// commands are routed to too (`WindowCommandRouting.rootWindow(for:)`).
    /// It once counted as a sheet over the sheet beneath it, a titled window,
    /// which counts as a Library window (REV11): a reader's shortcuts did not
    /// work there, the Library's did, and over an audio editor they matched
    /// where none should.
    ///
    /// The Search Library window is neither: no shortcut matches in it, nor
    /// in a sheet over it (nil, as over an audio editor), so its list and
    /// field take every key, Return opening a match and Space and the
    /// letters going to VoiceOver and the list rather than playing a book.
    /// Menu key equivalents still act there, as menus handle them.
    static func windowKind(ofKeyWindow keyWindow: NSWindow?) -> ShortcutWindowKind? {
        guard let keyWindow else { return .other }
        let underneath = WindowCommandRouting.rootWindow(for: keyWindow)
        if isLibrarySearchWindow(underneath) {
            return nil
        }
        return pressKind(
            window: windowKind(of: keyWindow),
            sheetParent: underneath === keyWindow ? nil : windowKind(of: underneath)
        )
    }

    /// Whether `window`, or the window under its sheets, is the Search
    /// Library window, named by its identifier
    /// (`LibrarySearchWindowController.windowIdentifier`) as the Record
    /// window and the audio editors are.
    static func isLibrarySearchWindow(_ window: NSWindow) -> Bool {
        WindowCommandRouting.rootWindow(for: window).identifier?.rawValue == LibrarySearchWindowController.windowIdentifier
    }

    /// The kind of window `window` is, apart from any sheet it is: an audio
    /// editor's or the Record window by their identifiers; a panel of its
    /// own, such as an Open panel or an alert run on its own, or the window
    /// of a modal session, `.other`; a reader or a Library window as the menu
    /// bar tells them apart (`MenuVisibilityManager.detectWindowType`); and
    /// any other, Settings among them, `.other`.
    static func windowKind(of window: NSWindow) -> ShortcutWindowKind {
        switch window.identifier?.rawValue {
        case AudioEditorWindowController.windowIdentifier: return .audioEditor
        case RecordingWindowController.windowIdentifier: return .recording
        default: break
        }
        if window.sheetParent == nil, window is NSPanel || window === NSApp.modalWindow {
            return .other
        }
        switch MenuVisibilityManager.detectWindowType(for: window) {
        case .library: return .library
        case .reader: return .reader
        case nil: return .other
        }
    }

#endif
    /// The kind whose shortcuts a key pressed in a window of `kind` matches,
    /// a sheet over a window of `parentKind` when it is one: a sheet counts
    /// as its window, so a reader's shortcuts work in a sheet over a reader,
    /// as they always have; none match in a sheet over an audio editor,
    /// whose fields and buttons take every key.
    nonisolated static func pressKind(window kind: ShortcutWindowKind, sheetParent parentKind: ShortcutWindowKind?) -> ShortcutWindowKind? {
        guard let parentKind else { return kind }
        return parentKind == .audioEditor ? nil : parentKind
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
    /// to its binding without Shift where none with Shift is its own, for
    /// an action that takes Shift along (finding 4 of FR12's design,
    /// `ShortcutAction.takesShiftAlong`).
    nonisolated static func hasExtraShift(
        eventHasShift: Bool,
        bindingRequiresShift: Bool
    ) -> Bool {
        eventHasShift && !bindingRequiresShift
    }

#if os(macOS)
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
#endif
}

/// A default key an action following its defaults goes without, and the
/// action that has it in force (FR12's branch D), which the Shortcuts tab
/// names on the action's row.
struct DefaultKeyHeldElsewhere: Equatable, Sendable {
    /// The default key.
    let key: KeyBinding
    /// The action holding it, or a key clashing with it.
    let holder: ShortcutAction
}

/// A recorder of the Shortcuts tab, held weakly by the shortcut manager.
private struct WeakRecorder {
    /// The recorder, while it lives.
    weak var recorder: AnyObject?
}

/// The key equivalents in force as a preferences store's record gives them,
/// followed as it changes, for a window with no shortcut manager of its own:
/// the Record window's buttons show and answer their keys in force (FR12's
/// branch D), as the menus show theirs from the app's manager.
@MainActor
final class StoredKeyEquivalents: ObservableObject {
    /// The store holding the record.
    private let store: UserDefaults
    /// Reports a change of the record, which may change a key.
    private var recordObserver: PreferenceObserver?

    /// Follows the record in `store`: the app's preferences unless a test
    /// passes a store of its own.
    init(store: UserDefaults = TextMouthRuntime.current.preferences) {
        self.store = store
        recordObserver = PreferenceObserver(keys: [KeyboardShortcutManager.editsPreference.key], in: store) { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// `action`'s key equivalent in force
    /// (`KeyboardShortcutManager.keyEquivalent(for:in:)`), or nil for none.
    func keyEquivalent(for action: ShortcutAction) -> KeyBinding? {
        KeyboardShortcutManager.keyEquivalent(for: action, in: KeyboardShortcutManager.bindingsPreference.read(from: store))
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
