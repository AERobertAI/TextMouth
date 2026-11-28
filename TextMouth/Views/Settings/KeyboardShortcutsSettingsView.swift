import SwiftUI

/// The Shortcuts settings tab: the double-press time, then every action's
/// shortcuts, by group, each changeable; the audio editor's actions are a
/// group of their own, matched only in its windows (`ShortcutScope`), so
/// their keys may be the reader's, and an action that may work in more than
/// one kind of window says where it does, which the user may change (FR12's
/// branch E). An action the user edited says so, and can be given back to
/// its defaults, and where it works by default, on its own (FR12).
struct KeyboardShortcutsSettingsView: View {
    @EnvironmentObject var shortcutManager: KeyboardShortcutManager
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            // One double-press time for every shortcut, at the top (FR12),
            // and a way to try it by ear.
            Section {
                DoublePressTimeStepper()
                Button(ShortcutsSettingsWording.tryDoublePressTitle, action: tryDoublePress)
                    .accessibilityHint(ShortcutsSettingsWording.tryDoublePressHint)
                // What a trial waits for, or what the last one found, as
                // text to read again: VoiceOver says each once (review item
                // C), and a braille display keeps this.
                if let status = ShortcutsSettingsWording.trialStatus(
                    isTrying: shortcutManager.isTryingDoublePress,
                    lastOutcome: shortcutManager.lastDoublePressTrialOutcome
                ) {
                    Text(status)
                }
                // Why a letter shortcut does nothing in a Library window,
                // as text, so VoiceOver and a braille display have it.
                Text(ShortcutsSettingsWording.letterNavigationNote)
            }

            ForEach(categories, id: \.self) { category in
                Section {
                    ForEach(actionsInCategory(category)) { action in
                        ShortcutBindingRow(action: action)
                    }
                } header: {
                    Text(ShortcutAction.title(ofCategory: category))
                }
            }

            Section {
                Button(ShortcutsSettingsWording.resetAllTitle) {
                    showResetConfirmation = true
                }
                .accessibilityLabel(ShortcutsSettingsWording.resetAllLabel)
            }
        }
        .padding()
        .alert(ShortcutsSettingsWording.resetAllAlertTitle, isPresented: $showResetConfirmation) {
            Button(ShortcutsSettingsWording.resetAllConfirm, role: .destructive) {
                Self.resetEveryShortcut(shortcutManager)
            }
            Button(ShortcutsSettingsWording.resetAllCancel, role: .cancel) {}
        } message: {
            Text(ShortcutsSettingsWording.resetAllAlertMessage)
        }
    }

    /// Gives every action its default keys again, then says so: the alert's
    /// Reset ends in silence otherwise, and a VoiceOver user could not tell
    /// the reset had worked. VoiceOver hears `ShortcutsSettingsWording.resetDone`
    /// once the alert has closed (REV11 F6), since hearing the alert close
    /// would cut the words off. `announce` lets a test capture the words
    /// without waiting out the delay.
    static func resetEveryShortcut(
        _ manager: KeyboardShortcutManager,
        announce: (String) -> Void = { VoiceOverAnnouncer.announceAfterSheetCloses($0, from: nil) }
    ) {
        manager.resetToDefaults()
        announce(ShortcutsSettingsWording.resetDone)
    }

    private var categories: [String] {
        var seen: [String] = []
        for action in ShortcutAction.allCases {
            if !seen.contains(action.category) {
                seen.append(action.category)
            }
        }
        return seen
    }

    private func actionsInCategory(_ category: String) -> [ShortcutAction] {
        ShortcutAction.allCases.filter { $0.category == category }
    }

    /// Try a Double Press: asks for a key pressed twice, then says what the
    /// two presses made, measured against the double-press time in force.
    private func tryDoublePress() {
        VoiceOverAnnouncer.announce(ShortcutsSettingsWording.tryDoublePressPrompt)
        shortcutManager.tryDoublePress { outcome in
            VoiceOverAnnouncer.announce(ShortcutsSettingsWording.trialResult(outcome))
        }
    }
}

/// The double-press time's stepper (FR12, section 6.2 of the design): how
/// soon a second press must follow the first to make a double press, from
/// 0.2 to 2 seconds in tenths. VoiceOver speaks its value as "0.5 seconds",
/// "1 second", or "2 seconds", and its hint says what the time costs.
struct DoublePressTimeStepper: View {
    @EnvironmentObject var shortcutManager: KeyboardShortcutManager

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // The label and the time for the eye; VoiceOver hears both
                // from the stepper itself, so they are not read twice.
                Text(ShortcutsSettingsWording.labeled(ShortcutsSettingsWording.doublePressTimeLabel, spokenTime))
                    .accessibilityHidden(true)
                Stepper(
                    value: Binding(
                        get: { shortcutManager.doublePressTime },
                        set: { shortcutManager.setDoublePressTime($0) }
                    ),
                    in: SettingsPolicy.shortcutDoublePressSeconds.range,
                    step: 1 / SettingsPolicy.shortcutDoublePressTenthsPerSecond
                ) {
                    EmptyView()
                }
                .accessibilityLabel(ShortcutsSettingsWording.doublePressTimeLabel)
                .accessibilityValue(spokenTime)
                .accessibilityHint(ShortcutsSettingsWording.doublePressTimeHint)
            }

            // The hint for the eye; VoiceOver hears it as the stepper's hint.
            Text(ShortcutsSettingsWording.doublePressTimeHint)
                .font(.caption)
                .foregroundColor(.secondary)
                .accessibilityHidden(true)
        }
    }

    /// The double-press time in force, as it is spoken and shown, to the
    /// tenth of a second (`CountWording.secondsToTheTenth`).
    private var spokenTime: String {
        CountWording.secondsToTheTenth(shortcutManager.doublePressTime)
    }
}

/// One action's row: its name; a button for each of its keys, which records
/// a key in that one's place, offers Make Double Press or Make Single Press,
/// and has one removing it beside it; a button adding a key; a Works in
/// pop-up, for an action that may work in more than one kind of window
/// (FR12's branch E); and, for an action the user edited, "Edited" and Reset
/// to Default. VoiceOver reads the row as one label in words
/// (`ShortcutsSettingsWording.rowLabel`) and offers Reset to Default as an
/// action of the row as well, and every key recorded, and every change of
/// where it works, is announced.
struct ShortcutBindingRow: View {
    let action: ShortcutAction
    @EnvironmentObject var shortcutManager: KeyboardShortcutManager
    @State private var isRecording = false
    @State private var recordingSlot: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Under its group's heading, so the audio editor's actions
                // show without the group's name their raw values begin with;
                // VoiceOver's label below keeps it, telling them apart from
                // the reader's of the same name.
                Text(action.title)
                    .frame(width: 160, alignment: .leading)

                Spacer()

                ForEach(Array(currentBindings.enumerated()), id: \.offset) { index, binding in
                    HStack(spacing: 4) {
                        if action.isKeyEquivalent {
                            // A menu command's key: no menu takes a double press.
                            recorderButton(for: binding, at: index)
                        } else {
                            recorderButton(for: binding, at: index)
                                // A double press made or undone without timing
                                // two presses, as a VoiceOver action
                                // (VO-Command-Space) and in the context menu.
                                .accessibilityAction(named: Text(ShortcutsSettingsWording.pressChange(for: binding))) {
                                    togglePresses(at: index)
                                }
                                .contextMenu {
                                    Button(ShortcutsSettingsWording.pressChange(for: binding)) {
                                        togglePresses(at: index)
                                    }
                                }
                        }

                        Button {
                            removeBinding(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(ShortcutsSettingsWording.removeShortcutLabel(binding, from: action))
                    }
                }

                if currentBindings.count < ShortcutsSettingsWording.mostKeys(for: action) {
                    recorderButton(for: nil, at: currentBindings.count)
                }
            }

            // Where the action works, for one that may work in more than
            // one kind of window (FR12's branch E): VoiceOver reads it as
            // "Works in, Library windows, pop-up button".
            if action.availableScopes.count > 1 {
                HStack {
                    Spacer()
                    Picker(ShortcutsSettingsWording.worksInLabel, selection: scopeSelection) {
                        ForEach(action.availableScopes, id: \.self) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.menu)
                    .fixedSize()
                    .accessibilityLabel(ShortcutsSettingsWording.worksInLabel)
                    .accessibilityHint(ShortcutsSettingsWording.worksInHint)
                }
            }

            // An action following its defaults says which of them another
            // action has (FR12's branch D), as New from Text's
            // Shift-Command-T is Show Sleep Timer's.
            if !defaultsHeldElsewhere.isEmpty {
                Text(ShortcutsSettingsWording.defaultsHeldElsewhere(defaultsHeldElsewhere))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // An action the user edited says so, after its keys, and can go
            // back to its defaults on its own.
            if isEdited {
                HStack(spacing: 8) {
                    Spacer()
                    Text(ShortcutsSettingsWording.edited)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button(ShortcutsSettingsWording.resetToDefaultTitle, action: resetToDefault)
                        .accessibilityLabel(ShortcutsSettingsWording.resetToDefaultLabel(for: action))
                        .accessibilityHint(ShortcutsSettingsWording.resetToDefaultHint)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(ShortcutsSettingsWording.rowLabel(
            for: action,
            keys: currentBindings,
            isEdited: isEdited,
            defaultsHeldElsewhere: defaultsHeldElsewhere,
            worksIn: shortcutManager.scope(of: action)
        ))
        .accessibilityActions {
            if isEdited {
                Button(ShortcutsSettingsWording.resetToDefaultTitle, action: resetToDefault)
            }
        }
    }

    /// The button recording a key in slot `index`: the button of `binding`,
    /// recording in its place, or, with nil, the button adding a key.
    private func recorderButton(for binding: KeyBinding?, at index: Int) -> ShortcutRecorderButton {
        ShortcutRecorderButton(
            binding: binding,
            isRecording: isRecording && recordingSlot == index,
            doublePressTime: shortcutManager.doublePressTime,
            // A menu command's key is one press, recorded as it goes down.
            takesDoublePresses: !action.isKeyEquivalent,
            shortcutManager: shortcutManager,
            onStartRecording: {
                isRecording = true
                recordingSlot = index
            },
            onKeyRecorded: { newBinding in
                if binding == nil {
                    addBinding(newBinding)
                } else {
                    replaceBinding(at: index, with: newBinding)
                }
                isRecording = false
                recordingSlot = nil
            },
            onCancel: {
                isRecording = false
                recordingSlot = nil
            }
        )
    }

    /// The action's keys in force.
    private var currentBindings: [KeyBinding] {
        shortcutManager.bindingsFor(action)
    }

    /// Whether the user edited the action's keys, which then stay theirs
    /// until Reset to Default.
    private var isEdited: Bool {
        shortcutManager.isEdited(action)
    }

    /// The default keys the action goes without, each with the action that
    /// has it, while it follows its defaults.
    private var defaultsHeldElsewhere: [DefaultKeyHeldElsewhere] {
        shortcutManager.defaultKeysHeldElsewhere(for: action)
    }

    /// The Works in pop-up's choice: the action's scope in force, changed
    /// through the manager, which makes the action the user's.
    private var scopeSelection: Binding<ShortcutScope> {
        Binding(
            get: { shortcutManager.scope(of: action) },
            set: { changeScope(to: $0) }
        )
    }

    /// Makes the action work in `scope`, as the user's (FR12's branch E),
    /// and tells VoiceOver where it works now and which actions lost a key
    /// to it where their scopes now overlap its own.
    private func changeScope(to scope: ShortcutScope) {
        guard scope != shortcutManager.scope(of: action) else { return }
        let keysBefore = shortcutManager.bindings
        shortcutManager.setScope(scope, for: action)
        VoiceOverAnnouncer.announce(ShortcutsSettingsWording.scopeChanged(
            action,
            to: shortcutManager.scope(of: action),
            takenFrom: shortcutManager.actions(thatLostKeysSince: keysBefore, besides: action)
        ))
    }

    /// Puts `newBinding` in place of the key at `index`, as the user's,
    /// taking it from any other action of the scope that had it, and
    /// announces it, or why the action cannot take it.
    private func replaceBinding(at index: Int, with newBinding: KeyBinding) {
        var bindings = currentBindings
        guard bindings.indices.contains(index) else { return }
        bindings[index] = newBinding
        announcing(newBinding) {
            shortcutManager.updateBindings(for: action, to: bindings)
        }
    }

    /// Makes the key at `index` a double press, or a single press again
    /// (Make Double Press and Make Single Press), and announces it as a key
    /// recorded.
    private func togglePresses(at index: Int) {
        guard currentBindings.indices.contains(index) else { return }
        let binding = currentBindings[index]
        replaceBinding(at: index, with: binding.asDoublePress(!binding.isDoublePress))
    }

    /// Removes the key at `index`, which makes the keys left the user's.
    private func removeBinding(at index: Int) {
        var bindings = currentBindings
        guard bindings.indices.contains(index) else { return }
        bindings.remove(at: index)
        shortcutManager.updateBindings(for: action, to: bindings)
    }

    /// Adds `binding` to the action's keys, as the user's, taking it from
    /// any other action of the scope that had it, and announces it, or why
    /// the action cannot take it.
    private func addBinding(_ binding: KeyBinding) {
        announcing(binding) {
            shortcutManager.addBinding(binding, to: action)
        }
    }

    /// Makes `change`, which gives the action `binding`, then tells
    /// VoiceOver, wherever its cursor is, the key recorded for the action;
    /// when other actions lost a key to it, which ones, since a key once
    /// moved silently; and when its key's single press now waits out the
    /// double-press time, before which action. When the action cannot take
    /// the key, which `change` returns, nothing changes, and VoiceOver hears
    /// why (FR12's branch D).
    private func announcing(_ binding: KeyBinding, _ change: () -> ShortcutRefusal?) {
        let keysBefore = shortcutManager.bindings
        let waitedBefore = shortcutManager.waitingAction(for: binding, in: shortcutManager.scope(of: action))
        if let refusal = change() {
            VoiceOverAnnouncer.announce(ShortcutsSettingsWording.refused(refusal, for: action))
            return
        }
        let waitsNow = shortcutManager.waitingAction(for: binding, in: shortcutManager.scope(of: action))
        VoiceOverAnnouncer.announce(ShortcutsSettingsWording.recorded(
            binding,
            for: action,
            takenFrom: shortcutManager.actions(thatLostKeysSince: keysBefore, besides: action),
            nowWaitsBefore: waitsNow == waitedBefore ? nil : waitsNow
        ))
    }

    /// Gives the action back to its defaults and says what they are, since
    /// the button that did it goes away with the row's edit, with where it
    /// works again when that changed too (FR12's branch E).
    private func resetToDefault() {
        let scopeBefore = shortcutManager.scope(of: action)
        shortcutManager.resetToDefault(action)
        let scopeNow = shortcutManager.scope(of: action)
        VoiceOverAnnouncer.announce(ShortcutsSettingsWording.resetAnnouncement(
            for: action,
            keys: currentBindings,
            worksIn: scopeNow == scopeBefore ? nil : scopeNow
        ))
    }
}

// MARK: - Wording

/// What the Shortcuts tab says (FR12): every key in words, never in symbols,
/// which a braille display shows as signs. Tests pin each wording. Every
/// text is localized (FR34); an action is named by `ShortcutAction.fullTitle`,
/// never by its raw value, which is the stored id.
enum ShortcutsSettingsWording {
    // MARK: The Tab's Own Controls

    /// Said in the tab's first section: in a Library window a letter pressed
    /// alone is the list's letter navigation, never a shortcut (October 17,
    /// `ShortcutWindowKind.navigatesByLetter`).
    static var letterNavigationNote: String {
        // Translators: Note in the Shortcuts tab of Settings. In a Library window, a letter key pressed with no other key jumps to the first book or folder starting with that letter, so a shortcut made of a letter alone, such as W, cannot work in a Library window.
        InterfaceText.line("shortcutsSettings.letterNavigationNote", "In Library windows, a letter alone moves to the first book or folder starting with it, so a shortcut that is a letter alone, such as W, works only in other windows.")
    }

    /// The title of the button that gives every action its defaults again.
    static var resetAllTitle: String {
        // Translators: Button at the end of the Shortcuts tab of Settings that gives every keyboard shortcut its default keys again. It asks to confirm first.
        InterfaceText.line("common.resetToDefaults", "Reset to Defaults")
    }

    /// That button's VoiceOver label.
    static var resetAllLabel: String {
        // Translators: VoiceOver label of the button at the end of the Shortcuts tab of Settings that gives every keyboard shortcut its default keys again.
        InterfaceText.line("shortcutsSettings.resetAllLabel", "Reset all shortcuts to defaults")
    }

    /// The title of the alert that asks to confirm the reset of every shortcut.
    static var resetAllAlertTitle: String {
        // Translators: Title of the alert that asks the listener to confirm resetting every keyboard shortcut to its default.
        InterfaceText.line("shortcutsSettings.resetAllAlertTitle", "Reset Keyboard Shortcuts?")
    }

    /// The alert's button that does the reset.
    static var resetAllConfirm: String {
        // Translators: Button of an alert that confirms resetting every keyboard shortcut to its default.
        InterfaceText.line("common.reset", "Reset")
    }

    /// The alert's button that leaves the shortcuts as they are.
    static var resetAllCancel: String {
        // Translators: Button that closes a sheet or answers a question without doing or changing anything.
        InterfaceText.line("common.cancel", "Cancel")
    }

    /// The alert's message: what is lost.
    static var resetAllAlertMessage: String {
        // Translators: Message of the alert that asks the listener to confirm resetting every keyboard shortcut to its default: the shortcuts they changed are lost.
        InterfaceText.line("shortcutsSettings.resetAllAlertMessage", "Every shortcut and where it works go back to the defaults. Your own keys are lost.")
    }

    /// What an edited row says after its keys, on screen and to VoiceOver.
    static var edited: String {
        // Translators: Said after the keys of a keyboard shortcut action the listener changed in Settings, to tell it from one that follows the defaults.
        InterfaceText.line("shortcutsSettings.edited", "Edited")
    }

    /// The title of the button, and of the row's VoiceOver action, that
    /// gives one action back to its defaults.
    static var resetToDefaultTitle: String {
        // Translators: Button in the row of a keyboard shortcut action the listener changed, and the row's VoiceOver action: gives that one action its default keys again.
        InterfaceText.line("common.resetToDefault", "Reset to Default")
    }

    /// That button's hint.
    static var resetToDefaultHint: String {
        // Translators: VoiceOver hint of the Reset to Default button of one keyboard shortcut action: the action goes back to the default keys, and later versions of TextMouth may change them.
        InterfaceText.line("shortcutsSettings.resetToDefaultHint", "Restores this action's default shortcuts, which follow later releases' changes")
    }

    /// What VoiceOver hears after the Shortcuts tab's Reset to Defaults has
    /// been confirmed. It follows the audio filter presets' reset wording.
    static var resetDone: String {
        // Translators: Announced by VoiceOver after the listener confirmed resetting every keyboard shortcut to its default.
        InterfaceText.line("shortcutsSettings.resetDone", "Shortcuts reset to defaults.")
    }

    // MARK: Shared Pieces

    /// `label`, a colon, and `value`: an action's name and its keys, or a
    /// control's label and its time.
    static func labeled(_ label: String, _ value: String) -> String {
        // Translators: A name, a colon, and its value, such as a keyboard shortcut action's name and its keys, or a control's label and its value. %1$@ is the name and %2$@ is the value.
        InterfaceText.line("common.valueColonValue", "\(label): \(value)")
    }

    /// `text` ended as a sentence: with a full stop, unless it ends in a
    /// question mark, a period, or an ellipsis already, as "Where Am I?"
    /// does.
    static func sentence(_ text: String) -> String {
        guard let last = text.last, !"?.…。？！".contains(last) else { return text } // l10n: no (the marks that end a sentence already)
        // Translators: Ends a sentence with its full stop. %@ is the sentence without it. Chinese and Japanese use their own full stop here.
        return InterfaceText.line("common.valuePeriod", "\(text).")
    }

    // MARK: The Recorder

    /// The label of the button adding a key.
    static var addShortcutLabel: String {
        // Translators: Label of the button, in a keyboard shortcut action's row in Settings, that adds one more key to the action.
        InterfaceText.line("shortcutsSettings.addShortcutLabel", "Add shortcut")
    }

    /// A key's button's hint, and the add button's, while not recording:
    /// what pressing it does, never a click (TODO A10).
    static var recordHint: String {
        // Translators: VoiceOver hint of a keyboard shortcut's key button, and of the add shortcut button, in Settings: the next key pressed becomes the shortcut.
        InterfaceText.line("shortcutsSettings.recordHint", "Records a new shortcut.")
    }

    /// The recorder's label while it records (FR12, section 6.1 of the
    /// design).
    static var recordingLabel: String {
        // Translators: VoiceOver label of a keyboard shortcut's key button while it waits for the new key: pressing a key records it, and pressing the same key twice quickly records a double press.
        InterfaceText.line("shortcutsSettings.recordingLabel", "Recording shortcut. Press a key, or press it twice for a double press.")
    }

    /// The recorder's hint while it records. Every key, VoiceOver's own
    /// included, goes to the recorder then, so Escape, not a click, is how
    /// to stop (TODO A10).
    static var recordingHint: String {
        // Translators: VoiceOver hint of a keyboard shortcut's key button while it waits for the new key: Escape stops recording.
        InterfaceText.line("shortcutsSettings.recordingHint", "Press the new key, or Escape to cancel.")
    }

    /// What the recorder shows while it records.
    static var recordingPrompt: String {
        // Translators: Shown on a keyboard shortcut's key button while it waits for the new key. The three periods say that a key press is awaited.
        InterfaceText.line("shortcutsSettings.recordingPrompt", "Press a key...")
    }

    /// The recorder's label while it records a menu command's key, one press
    /// of a key with Command or Control (FR12's branch D).
    static var recordingKeyEquivalentLabel: String {
        // Translators: VoiceOver label of a menu command's key button while it waits for the new key: the shortcut of a menu command must be a key held with the Command or Control key.
        InterfaceText.line("shortcutsSettings.recordingKeyEquivalentLabel", "Recording shortcut. Press a key with Command or Control.")
    }

    /// The action on a single press's button, and in its context menu, that
    /// makes it a double press.
    static var makeDoublePress: String {
        // Translators: VoiceOver action and context menu item of a keyboard shortcut's key button: changes a single press of the key into the key pressed twice quickly.
        InterfaceText.line("shortcutsSettings.makeDoublePress", "Make Double Press")
    }

    /// The action on a double press's button, and in its context menu, that
    /// makes it a single press again.
    static var makeSinglePress: String {
        // Translators: VoiceOver action and context menu item of a keyboard shortcut's key button: changes a key pressed twice quickly into a single press of the key.
        InterfaceText.line("shortcutsSettings.makeSinglePress", "Make Single Press")
    }

    /// The action `binding`'s button offers: Make Single Press for a double
    /// press, Make Double Press for a single one.
    static func pressChange(for binding: KeyBinding) -> String {
        binding.isDoublePress ? makeSinglePress : makeDoublePress
    }

    /// The label of the small button that removes one key of an action.
    static func removeShortcutLabel(_ binding: KeyBinding, from action: ShortcutAction) -> String {
        // Translators: VoiceOver label of the button that removes one key from a keyboard shortcut action. %1$@ is the key in words, such as "Command + I", and %2$@ is the action's name.
        InterfaceText.line("shortcutsSettings.removeShortcutLabel", "Remove shortcut \(binding.accessibleDisplayString) from \(action.fullTitle)")
    }

    /// The most keys `action`'s row records: one for a menu command's or a
    /// Record window button's, whose item has one key equivalent (FR12's
    /// branch D), and three for any other.
    static func mostKeys(for action: ShortcutAction) -> Int {
        action.isKeyEquivalent ? 1 : 3
    }

    /// What VoiceOver says when the action cannot take a key recorded for
    /// it, which then changes nothing (FR12's branch D): "W not recorded for
    /// Open Book…: a menu command's shortcut is one press of a key with
    /// Command or Control."
    static func refused(_ refusal: ShortcutRefusal, for action: ShortcutAction) -> String {
        // Translators: Announced by VoiceOver when a key cannot become a keyboard shortcut. %1$@ is the key in words, %2$@ is the action's name, and %3$@ is the reason, which starts in lower case.
        sentence(InterfaceText.line("shortcutsSettings.refused", "\(refusal.key.accessibleDisplayString) not recorded for \(action.fullTitle): \(refusal.reason)"))
    }

    // MARK: The Double-Press Time

    /// The double-press time stepper's label.
    static var doublePressTimeLabel: String {
        // Translators: Label of the stepper in Settings that sets how soon a second press of a key must follow the first to count as a double press.
        InterfaceText.line("shortcutsSettings.doublePressTimeLabel", "Double press time")
    }

    /// The double-press time stepper's hint: what the time is, and what it
    /// costs.
    static var doublePressTimeHint: String {
        // Translators: Hint of the double press time stepper in Settings: what the time is, and that a key that has one action for a single press and another for a double press waits for that time before acting on a single press.
        InterfaceText.line("shortcutsSettings.doublePressTimeHint", "How soon a second press must follow the first. A key with different single and double press actions waits this long before its single press acts.")
    }

    // MARK: Trying a Double Press (FR12, Section 6.2 of the Design)

    /// The title of the button that tries a double press.
    static var tryDoublePressTitle: String {
        // Translators: Button in the Shortcuts tab of Settings that lets the listener press a key twice to find out whether the double press time counts the two presses as a double press.
        InterfaceText.line("shortcutsSettings.tryDoublePressTitle", "Try a Double Press")
    }

    /// Its hint.
    static var tryDoublePressHint: String {
        // Translators: VoiceOver hint of the Try a Double Press button: for five seconds key presses are not shortcuts, and TextMouth says whether two presses were a double press.
        InterfaceText.line("shortcutsSettings.tryDoublePressHint", "For five seconds, the next two key presses are not shortcuts; TextMouth says whether they make a double press.")
    }

    /// What VoiceOver says as a trial starts.
    static var tryDoublePressPrompt: String {
        // Translators: Announced by VoiceOver when a trial of the double press time starts: asks the listener to press one key twice.
        InterfaceText.line("shortcutsSettings.tryDoublePressPrompt", "Press a key twice.")
    }

    /// What VoiceOver says once a trial ends: "Double press.", or how far
    /// apart two presses of one key came and what time would count them as
    /// one: "Two presses, 0.7 seconds apart. Set the time above 0.7 seconds
    /// to count them as one."
    static func trialResult(_ outcome: DoublePressTrial.Outcome) -> String {
        switch outcome {
        case .doublePress:
            // Translators: Announced by VoiceOver at the end of a trial of the double press time: the two presses counted as a double press.
            return InterfaceText.line("shortcutsSettings.trialResult.doublePress", "Double press.")
        case .tooFarApart(let apart):
            let gap = CountWording.secondsToTheTenth(apart)
            let longest = SettingsPolicy.shortcutDoublePressSeconds.range.upperBound
            guard (apart * SettingsPolicy.shortcutDoublePressTenthsPerSecond).rounded() < longest * SettingsPolicy.shortcutDoublePressTenthsPerSecond else {
                // Translators: Announced by VoiceOver at the end of a trial of the double press time when the two presses were farther apart than the longest time allowed. %1$@ is the time between the presses, such as "2.5 seconds", and %2$@ is the longest time allowed, such as "2 seconds".
                return InterfaceText.line("shortcutsSettings.trialResult.tooFarApart.double", "Two presses, \(gap) apart. The double press time goes up to \(CountWording.secondsToTheTenth(longest)).")
            }
            // Translators: Announced by VoiceOver at the end of a trial of the double press time when the two presses were too far apart for the time set. Both %1$@ and %2$@ are the time between the presses, such as "0.7 seconds"; the listener should set the double press time above it.
            return InterfaceText.line("shortcutsSettings.trialResult.tooFarApart.above", "Two presses, \(gap) apart. Set the time above \(gap) to count them as one.")
        case .differentKeys:
            // Translators: Announced by VoiceOver at the end of a trial of the double press time when the two presses were of different keys.
            return InterfaceText.line("shortcutsSettings.trialResult.differentKeys", "Two different keys, not a double press.")
        case .noSecondPress:
            // Translators: Announced by VoiceOver at the end of a trial of the double press time when no second press came in time.
            return InterfaceText.line("shortcutsSettings.trialResult.noSecondPress", "No key was pressed twice.")
        }
    }

    /// The text below Try a Double Press, which a braille display can read
    /// again after VoiceOver has said it (review item C): the prompt while a
    /// trial waits for its presses, "Last try: " and what the last one found
    /// once one has ended, as in "Last try: Double press.", and nothing
    /// before any trial.
    static func trialStatus(isTrying: Bool, lastOutcome: DoublePressTrial.Outcome?) -> String? {
        if isTrying {
            return tryDoublePressPrompt
        }
        return lastOutcome.map {
            // Translators: Text below the Try a Double Press button after a trial ended. %@ is what the trial found, a whole sentence such as "Double press.".
            InterfaceText.line("shortcutsSettings.trialStatus", "Last try: \(trialResult($0))")
        }
    }

    // MARK: Rows and Announcements

    /// A row's VoiceOver label: the action's name as config.json names it,
    /// an audio editor action's with its group's, then its keys in words;
    /// where it works, when that is one kind of window or a scope the user
    /// chose (FR12's branch E): "Show Sleep Timer: Shift + Command + T.
    /// Works in reader windows."; and, for an action the user edited,
    /// "Edited.": "Release Media Controls: Shift + R. Edited.", "Where Am
    /// I?: W"; or, for an action following its defaults that goes without
    /// one, which action has it (FR12's branch D), as Show Sleep Timer does
    /// once the user gives New from Text every window: "Show Sleep Timer: No
    /// shortcut. Works in reader windows. New from Text… has its default,
    /// Shift + Command + T."
    static func rowLabel(
        for action: ShortcutAction,
        keys: [KeyBinding],
        isEdited: Bool,
        defaultsHeldElsewhere held: [DefaultKeyHeldElsewhere] = [],
        worksIn scope: ShortcutScope? = nil
    ) -> String {
        let label = labeled(action.fullTitle, KeyBinding.accessibleDisplayString(for: keys))
        var more: [String] = []
        if let scope, saysScope(scope, of: action) {
            more.append(worksInSentence(scope))
        }
        if isEdited {
            more.append(sentence(edited))
        } else if !held.isEmpty {
            more.append(defaultsHeldElsewhere(held))
        }
        return more.isEmpty ? label : SentenceWording.joined([sentence(label)] + more)
    }

    /// Whether a row says where `action` works, in `scope`: when the user
    /// chose it, and otherwise when it is a default said
    /// (`ShortcutScope.isSaidAsADefault`), Library or reader windows.
    private static func saysScope(_ scope: ShortcutScope, of action: ShortcutAction) -> Bool {
        scope != action.defaultScope || scope.isSaidAsADefault
    }

    /// The sentence saying where a shortcut works: "Works in reader windows."
    static func worksInSentence(_ scope: ShortcutScope) -> String {
        // Translators: Says where a keyboard shortcut works, in a row of the Shortcuts tab or an announcement. %@ names the windows, such as "every window", "Library windows", or "the audio editor".
        sentence(InterfaceText.line("shortcutsSettings.worksInSentence", "Works in \(scope.inSentence)"))
    }

    /// The Works in pop-up's label (FR12's branch E).
    static var worksInLabel: String {
        // Translators: Label of the pop-up button in a keyboard shortcut action's row that chooses in which windows the shortcut works, such as every window or Library windows.
        InterfaceText.line("shortcutsSettings.worksInLabel", "Works in")
    }

    /// The Works in pop-up's hint.
    static var worksInHint: String {
        // Translators: VoiceOver hint of the Works in pop-up button of a keyboard shortcut action: choosing a choice makes the action the listener's own, and Reset to Default restores where it works by default.
        InterfaceText.line("shortcutsSettings.worksInHint", "Choosing makes the shortcut yours; Reset to Default restores where it works by default.")
    }

    /// What VoiceOver says once a row's Works in choice is made (FR12's
    /// branch E): "New from Text… works in every window.", followed, when
    /// actions lost a key to it where their scopes now overlap its own, by
    /// "Taken from Show Sleep Timer."
    static func scopeChanged(_ action: ShortcutAction, to scope: ShortcutScope, takenFrom previousOwners: [ShortcutAction]) -> String {
        // Translators: Announced by VoiceOver after the listener chose where a keyboard shortcut works. %1$@ is the action's name and %2$@ names the windows, such as "every window" or "Library windows".
        var sentences = [InterfaceText.line("shortcutsSettings.scopeChanged", "\(action.fullTitle) works in \(scope.inSentence).")]
        if !previousOwners.isEmpty {
            sentences.append(takenFromSentence(previousOwners))
        }
        return SentenceWording.joined(sentences)
    }

    /// "Taken from Play / Pause and Where Am I?": the actions that lost a key
    /// to the one just recorded or moved.
    private static func takenFromSentence(_ previousOwners: [ShortcutAction]) -> String {
        // Translators: Announced by VoiceOver after a key was given to a keyboard shortcut action that another action had. %@ names the action or actions that lost the key, such as "Play / Pause and Where Am I?".
        sentence(InterfaceText.line("shortcutsSettings.takenFromSentence", "Taken from \(CountWording.list(previousOwners.map(\.fullTitle)))"))
    }

    /// What a row says, on screen and to VoiceOver, of the default keys its
    /// action goes without (FR12's branch D): "Show Sleep Timer has its
    /// default, Shift + Command + T.", a sentence for each.
    static func defaultsHeldElsewhere(_ held: [DefaultKeyHeldElsewhere]) -> String {
        SentenceWording.joined(held.map {
            // Translators: Said in the row of a keyboard shortcut action that has lost its default key to another action. %1$@ is the name of the action that now has the key, and %2$@ is the key in words, such as "Shift + Command + T".
            sentence(InterfaceText.line("shortcutsSettings.defaultsHeldElsewhere", "\($0.holder.fullTitle) has its default, \($0.key.accessibleDisplayString)"))
        })
    }

    /// The reset button's VoiceOver label: "Reset Release Media Controls to
    /// Default".
    static func resetToDefaultLabel(for action: ShortcutAction) -> String {
        // Translators: VoiceOver label of the Reset to Default button in the row of a keyboard shortcut action. %@ is the action's name.
        InterfaceText.line("shortcutsSettings.resetToDefaultLabel", "Reset \(action.fullTitle) to Default")
    }

    /// What VoiceOver says once a key is recorded: "Shift + R, recorded for
    /// Release Media Controls.", or "W twice, recorded for …" for a double
    /// press; followed, for a key another action of the scope had, by
    /// "Taken from Play / Pause.", and, when the key's single press now
    /// waits before an action, by what `nowWaits(_:before:)` says.
    static func recorded(
        _ key: KeyBinding,
        for action: ShortcutAction,
        takenFrom previousOwner: ShortcutAction?,
        nowWaitsBefore waitingAction: ShortcutAction? = nil
    ) -> String {
        recorded(key, for: action, takenFrom: previousOwner.map { [$0] } ?? [], nowWaitsBefore: waitingAction)
    }

    /// `recorded(_:for:takenFrom:nowWaitsBefore:)` for a key taken from
    /// any number of actions, every one named: "Command + O twice, recorded
    /// for Book Info. Taken from Open Book…", or "… Taken from Play / Pause
    /// and Where Am I?" when two actions lost a key to it.
    static func recorded(
        _ key: KeyBinding,
        for action: ShortcutAction,
        takenFrom previousOwners: [ShortcutAction],
        nowWaitsBefore waitingAction: ShortcutAction? = nil
    ) -> String {
        // Translators: Announced by VoiceOver after a key became a keyboard shortcut. %1$@ is the key in words, such as "Shift + R" or "W twice", and %2$@ is the action's name.
        var sentences = [sentence(InterfaceText.line("shortcutsSettings.sentences", "\(key.accessibleDisplayString), recorded for \(action.fullTitle)"))]
        if !previousOwners.isEmpty {
            sentences.append(takenFromSentence(previousOwners))
        }
        if let waitingAction {
            sentences.append(nowWaits(key, before: waitingAction))
        }
        return SentenceWording.joined(sentences)
    }

    /// What VoiceOver says of a key whose single press now waits out the
    /// double-press time before its action acts, the cost of giving its
    /// double press an unrelated action: "J now waits before Skip Backward,
    /// in case it is pressed twice."
    static func nowWaits(_ key: KeyBinding, before action: ShortcutAction) -> String {
        // Translators: Announced by VoiceOver after a key's double press was given to an action: the key's single press now waits a moment before it acts, in case a second press follows. %1$@ is the key in words, such as "J", and %2$@ is the name of the action of its single press.
        InterfaceText.line("shortcutsSettings.nowWaits", "\(key.stroke.accessibleDisplayString) now waits before \(action.fullTitle), in case it is pressed twice.")
    }

    /// What VoiceOver says once an action is reset to its default: "Next
    /// Bookmark reset to default: Option + Shift + Command + B.", and, when
    /// the reset gave back where it works too (FR12's branch E), "Works in
    /// Library windows."
    static func resetAnnouncement(for action: ShortcutAction, keys: [KeyBinding], worksIn scope: ShortcutScope? = nil) -> String {
        // Translators: Announced by VoiceOver after a keyboard shortcut action was given its default keys again. %1$@ is the action's name and %2$@ is its keys in words, such as "Option + Shift + Command + B", or "No shortcut".
        let reset = sentence(InterfaceText.line("shortcutsSettings.resetAnnouncement", "\(action.fullTitle) reset to default: \(KeyBinding.accessibleDisplayString(for: keys))"))
        return scope.map { SentenceWording.joined([reset, worksInSentence($0)]) } ?? reset
    }
}

/// A button that, when clicked, starts recording a key press to set as a
/// shortcut: one press, or the same key pressed twice within the
/// double-press time for a double press (`ShortcutRecording`).
struct ShortcutRecorderButton: View {
    let binding: KeyBinding?
    let isRecording: Bool
    /// How long the recorder waits for a second press of the key.
    let doublePressTime: TimeInterval
    /// Whether a key pressed twice records a double press; false for a menu
    /// command's key, recorded as it goes down (FR12's branch D).
    let takesDoublePresses: Bool
    /// The shortcut manager, which leaves every key press to the recorder
    /// while it records.
    let shortcutManager: KeyboardShortcutManager?
    let onStartRecording: () -> Void
    let onKeyRecorded: (KeyBinding) -> Void
    let onCancel: () -> Void

    var body: some View {
        Button {
            if isRecording {
                onCancel()
            } else {
                onStartRecording()
            }
        } label: {
            if isRecording {
                Text(ShortcutsSettingsWording.recordingPrompt)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .frame(minWidth: 80)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.1))
                    .cornerRadius(4)
            } else if let binding = binding {
                Text(binding.displayString)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.primary)
                    .frame(minWidth: 50)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(4)
            } else {
                Image(systemName: "plus.circle")
                    .foregroundColor(.secondary)
                    .font(.body)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(isRecording ? ShortcutsSettingsWording.recordingHint : ShortcutsSettingsWording.recordHint)
        #if os(macOS)
        .background(
            ShortcutRecorderEventHandler(
                isActive: isRecording,
                doublePressTime: doublePressTime,
                takesDoublePresses: takesDoublePresses,
                shortcutManager: shortcutManager,
                onKeyRecorded: onKeyRecorded,
                onCancel: onCancel
            )
        )
        #endif
    }

    private var accessibilityLabel: String {
        if isRecording {
            return takesDoublePresses ? ShortcutsSettingsWording.recordingLabel : ShortcutsSettingsWording.recordingKeyEquivalentLabel
        } else if let binding = binding {
            return binding.accessibleDisplayString
        } else {
            return ShortcutsSettingsWording.addShortcutLabel
        }
    }
}

#if os(macOS)
/// Invisible view that, while active, takes the key presses made in
/// TextMouth with a local event monitor and records the key they press
/// (`ShortcutRecording`); the shortcut manager acts on none of them
/// meanwhile.
struct ShortcutRecorderEventHandler: NSViewRepresentable {
    let isActive: Bool
    /// How long the recorder waits for a second press of the key.
    let doublePressTime: TimeInterval
    /// Whether a key pressed twice records a double press.
    let takesDoublePresses: Bool
    /// The shortcut manager, told when recording starts and stops.
    let shortcutManager: KeyboardShortcutManager?
    let onKeyRecorded: (KeyBinding) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The row hands over new closures and a new time as it is drawn
        // again; the coordinator keeps the latest.
        let coordinator = context.coordinator
        coordinator.onKeyRecorded = onKeyRecorded
        coordinator.onCancel = onCancel
        coordinator.doublePressTime = doublePressTime
        coordinator.takesDoublePresses = takesDoublePresses
        coordinator.shortcutManager = shortcutManager
        coordinator.updateMonitor(isActive: isActive)
    }

    /// Stops recording when the button goes away, so no monitor outlives it
    /// and the shortcuts act again.
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stopRecording()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onKeyRecorded: onKeyRecorded,
            onCancel: onCancel,
            doublePressTime: doublePressTime,
            takesDoublePresses: takesDoublePresses,
            shortcutManager: shortcutManager
        )
    }

    @MainActor
    final class Coordinator {
        var onKeyRecorded: (KeyBinding) -> Void
        var onCancel: () -> Void
        /// How long the recorder waits for a second press of the key.
        var doublePressTime: TimeInterval
        /// Whether a key pressed twice records a double press.
        var takesDoublePresses: Bool
        /// The shortcut manager, which leaves key presses to the recorder
        /// while it records.
        weak var shortcutManager: KeyboardShortcutManager?
        /// The local event monitor taking key presses, while recording.
        private var monitor: Any?
        /// What the presses taken make, while recording.
        private var recording: ShortcutRecording?

        init(
            onKeyRecorded: @escaping (KeyBinding) -> Void,
            onCancel: @escaping () -> Void,
            doublePressTime: TimeInterval,
            takesDoublePresses: Bool,
            shortcutManager: KeyboardShortcutManager?
        ) {
            self.onKeyRecorded = onKeyRecorded
            self.onCancel = onCancel
            self.doublePressTime = doublePressTime
            self.takesDoublePresses = takesDoublePresses
            self.shortcutManager = shortcutManager
        }

        /// Starts recording when the button becomes active, and stops when
        /// it no longer is.
        func updateMonitor(isActive: Bool) {
            if isActive && monitor == nil {
                startRecording()
            } else if !isActive {
                stopRecording()
            }
        }

        /// Takes every key press from now on and hands it to a new
        /// recording, telling the shortcut manager to act on none.
        private func startRecording() {
            let recording = ShortcutRecording(doublePressTime: doublePressTime, takesDoublePresses: takesDoublePresses) { [weak self] outcome in
                self?.finish(outcome)
            }
            self.recording = recording
            shortcutManager?.recordingStarted(by: self)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let recording = self?.recording else { return event }
                let taken = recording.take(
                    KeyBinding.from(event: event),
                    at: event.timestamp,
                    isRepeat: event.isARepeat,
                    isEscape: event.keyCode == 53
                )
                return taken ? nil : event
            }
        }

        /// Ends recording with `outcome`: the key recorded, or cancelled.
        private func finish(_ outcome: ShortcutRecording.Outcome) {
            stopRecording()
            switch outcome {
            case .recorded(let binding):
                onKeyRecorded(binding)
            case .cancelled:
                onCancel()
            }
        }

        /// Stops taking key presses, ends the recording without a key, and
        /// lets the shortcuts act again.
        func stopRecording() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            recording?.cancel()
            recording = nil
            shortcutManager?.recordingStopped(by: self)
        }
    }
}

#endif

// MARK: - Recording a Key

/// What the Shortcuts tab's recorder makes of the key presses it takes
/// (FR12, section 6.1 of the design). The first press of a key waits the
/// double-press time: the same key pressed again within it records a double
/// press, and no second press, or another key, records a single press.
/// Escape cancels, so it is never recorded; a held key's repeats are
/// ignored, so holding a key never records it twice; and a key no binding
/// can name goes on, as before. A recording that takes no double press, a
/// menu command's (FR12's branch D), records the first press as it goes
/// down. The clock and the timer are passed in, so tests never wait.
@MainActor
final class ShortcutRecording {
    /// How a recording ends.
    enum Outcome: Equatable {
        /// A key was recorded: a single press or a double press.
        case recorded(KeyBinding)
        /// Escape cancelled it.
        case cancelled
    }

    /// The time on the key presses' time line.
    private let clock: ShortcutPressDispatcher.Clock
    /// Whether a key pressed twice records a double press.
    private let takesDoublePresses: Bool
    /// The two presses the recording measures, and its outcome.
    private let presses: TwoPresses<Outcome>

    /// Whether the recording has ended.
    var hasEnded: Bool {
        presses.hasEnded
    }

    /// A recording waiting `doublePressTime` for a second press, unless it
    /// `takesDoublePresses` not, ending through `finish`.
    init(
        doublePressTime: TimeInterval,
        takesDoublePresses: Bool = true,
        clock: @escaping ShortcutPressDispatcher.Clock = { ProcessInfo.processInfo.systemUptime },
        startTimer: @escaping ShortcutPressDispatcher.StartTimer = { delay, fire in MainQueuePressTimer(delay: delay, fire: fire) },
        finish: @escaping @MainActor (Outcome) -> Void
    ) {
        self.clock = clock
        self.takesDoublePresses = takesDoublePresses
        presses = TwoPresses(doublePressTime: doublePressTime, startTimer: startTimer, finish: finish)
    }

    /// Takes one key press: the key with its modifiers (`stroke`, nil for a
    /// key no binding can name), when it went down, whether it is a held
    /// key's repeat, and whether it is Escape. Returns whether the press is
    /// the recording's, which goes no further.
    @discardableResult
    func take(_ stroke: KeyBinding?, at time: TimeInterval, isRepeat: Bool, isEscape: Bool) -> Bool {
        guard !presses.hasEnded else { return false }
        if isEscape {
            presses.end(.cancelled)
            return true
        }
        if isRepeat {
            return true
        }
        // The recording keeps a first press only of a key a binding names.
        guard let firstKey = presses.first?.stroke else {
            guard let stroke else { return false }
            guard takesDoublePresses else {
                presses.end(.recorded(stroke))
                return true
            }
            presses.keepFirst(stroke, at: time)
            presses.startTimer(after: max(0, time + presses.doublePressTime - clock())) { [weak self] in
                self?.timeIsUp()
            }
            return true
        }
        if presses.second(stroke, at: time) == .doublePress {
            presses.end(.recorded(firstKey.asDoublePress(true)))
            return true
        }
        // Another key, or the same one too late: the first was pressed once.
        // A key no binding names goes on; any other is the recording's.
        presses.end(.recorded(firstKey))
        return stroke != nil
    }

    /// Ends the recording without a key, as the recorder going away does.
    func cancel() {
        presses.cancel()
    }

    /// Records the first press as a single press once no second press has
    /// come within the time.
    private func timeIsUp() {
        guard let firstKey = presses.first?.stroke else { return }
        presses.end(.recorded(firstKey))
    }
}
