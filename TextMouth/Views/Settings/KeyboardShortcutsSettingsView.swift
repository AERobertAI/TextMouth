import SwiftUI

/// The Shortcuts settings tab: every action's shortcuts, by group, each
/// changeable; the audio editor's actions are a group of their own, matched
/// only in its windows (`ShortcutScope`), so their keys may be the reader's.
/// An action the user edited says so, and can be given back to its defaults
/// on its own (FR12).
struct KeyboardShortcutsSettingsView: View {
    @EnvironmentObject var shortcutManager: KeyboardShortcutManager
    @State private var showResetConfirmation = false

    var body: some View {
        Form {
            ForEach(categories, id: \.self) { category in
                Section {
                    ForEach(actionsInCategory(category)) { action in
                        ShortcutBindingRow(action: action)
                    }
                } header: {
                    Text(category)
                }
            }

            Section {
                Button("Reset to Defaults") {
                    showResetConfirmation = true
                }
                .accessibilityLabel("Reset all keyboard shortcuts to defaults")
            }
        }
        .padding()
        .alert("Reset Keyboard Shortcuts?", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                shortcutManager.resetToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will reset all keyboard shortcuts to their default values. Any custom bindings will be lost.")
        }
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
}

/// One action's row: its name; a button for each of its keys, which records
/// a key in that one's place, and one removing it; a button adding a key;
/// and, for an action the user edited, "Edited" and Reset to Default.
/// VoiceOver reads the row as one label in words
/// (`ShortcutsSettingsWording.rowLabel`) and offers Reset to Default as an
/// action of the row as well, and every key recorded is announced.
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
                        ShortcutRecorderButton(
                            binding: binding,
                            isRecording: isRecording && recordingSlot == index,
                            onStartRecording: {
                                isRecording = true
                                recordingSlot = index
                            },
                            onKeyRecorded: { newBinding in
                                replaceBinding(at: index, with: newBinding)
                                isRecording = false
                                recordingSlot = nil
                            },
                            onCancel: {
                                isRecording = false
                                recordingSlot = nil
                            }
                        )

                        Button {
                            removeBinding(at: index)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove shortcut \(binding.accessibleDisplayString) from \(action.rawValue)")
                        .accessibilityHint("Deletes this keyboard shortcut binding")
                    }
                }

                if currentBindings.count < 3 {
                    ShortcutRecorderButton(
                        binding: nil,
                        isRecording: isRecording && recordingSlot == currentBindings.count,
                        onStartRecording: {
                            isRecording = true
                            recordingSlot = currentBindings.count
                        },
                        onKeyRecorded: { newBinding in
                            addBinding(newBinding)
                            isRecording = false
                            recordingSlot = nil
                        },
                        onCancel: {
                            isRecording = false
                            recordingSlot = nil
                        }
                    )
                }
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
        .accessibilityLabel(ShortcutsSettingsWording.rowLabel(for: action, keys: currentBindings, isEdited: isEdited))
        .accessibilityActions {
            if isEdited {
                Button(ShortcutsSettingsWording.resetToDefaultTitle, action: resetToDefault)
            }
        }
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

    /// Puts `newBinding` in place of the key at `index`, as the user's,
    /// taking it from any other action of the scope that had it, and
    /// announces it.
    private func replaceBinding(at index: Int, with newBinding: KeyBinding) {
        var bindings = currentBindings
        guard bindings.indices.contains(index) else { return }
        let previousOwner = shortcutManager.action(holding: newBinding, in: action.scope)
        bindings[index] = newBinding
        shortcutManager.updateBindings(for: action, to: bindings)
        announceRecorded(newBinding, takenFrom: previousOwner)
    }

    /// Removes the key at `index`, which makes the keys left the user's.
    private func removeBinding(at index: Int) {
        var bindings = currentBindings
        guard bindings.indices.contains(index) else { return }
        bindings.remove(at: index)
        shortcutManager.updateBindings(for: action, to: bindings)
    }

    /// Adds `binding` to the action's keys, as the user's, taking it from
    /// any other action of the scope that had it, and announces it.
    private func addBinding(_ binding: KeyBinding) {
        let previousOwner = shortcutManager.action(holding: binding, in: action.scope)
        shortcutManager.addBinding(binding, to: action)
        announceRecorded(binding, takenFrom: previousOwner)
    }

    /// Tells VoiceOver, wherever its cursor is, the key recorded for the
    /// action and, when another action had it, which one it was taken from:
    /// a key once moved silently.
    private func announceRecorded(_ binding: KeyBinding, takenFrom previousOwner: ShortcutAction?) {
        let other = previousOwner == action ? nil : previousOwner
        VoiceOverAnnouncer.announce(ShortcutsSettingsWording.recorded(binding, for: action, takenFrom: other))
    }

    /// Gives the action back to its defaults and says what they are, since
    /// the button that did it goes away with the row's edit.
    private func resetToDefault() {
        shortcutManager.resetToDefault(action)
        VoiceOverAnnouncer.announce(ShortcutsSettingsWording.resetAnnouncement(for: action, keys: currentBindings))
    }
}

// MARK: - Wording

/// What the Shortcuts tab says (FR12): every key in words, never in symbols,
/// which a braille display shows as signs. Tests pin each wording.
enum ShortcutsSettingsWording {
    /// What an edited row says after its keys, on screen and to VoiceOver.
    static let edited = "Edited"
    /// The title of the button, and of the row's VoiceOver action, that
    /// gives one action back to its defaults.
    static let resetToDefaultTitle = "Reset to Default"
    /// That button's hint.
    static let resetToDefaultHint =
        "Gives this action TextMouth's default shortcuts again, which follow later releases' changes"

    /// A row's VoiceOver label: the action's name as config.json names it,
    /// an audio editor action's with its group's, then its keys in words,
    /// and, for an action the user edited, "Edited.": "Release Media
    /// Controls: Shift + R. Edited.", "Where Am I?: W".
    static func rowLabel(for action: ShortcutAction, keys: [KeyBinding], isEdited: Bool) -> String {
        let label = "\(action.rawValue): \(KeyBinding.accessibleDisplayString(for: keys))"
        return isEdited ? "\(sentence(label)) \(edited)." : label
    }

    /// The reset button's VoiceOver label: "Reset Release Media Controls to
    /// Default".
    static func resetToDefaultLabel(for action: ShortcutAction) -> String {
        "Reset \(action.rawValue) to Default"
    }

    /// What VoiceOver says once a key is recorded: "Shift + R, recorded for
    /// Release Media Controls.", followed, for a key another action of the
    /// scope had, by "Taken from Play / Pause."
    static func recorded(_ key: KeyBinding, for action: ShortcutAction, takenFrom previousOwner: ShortcutAction?) -> String {
        let recorded = sentence("\(key.accessibleDisplayString), recorded for \(action.rawValue)")
        guard let previousOwner else { return recorded }
        return "\(recorded) \(sentence("Taken from \(previousOwner.rawValue)"))"
    }

    /// What VoiceOver says once an action is reset to its default: "Next
    /// Bookmark reset to default: Option + Shift + Command + B."
    static func resetAnnouncement(for action: ShortcutAction, keys: [KeyBinding]) -> String {
        sentence("\(action.rawValue) reset to default: \(KeyBinding.accessibleDisplayString(for: keys))")
    }

    /// `text` ended as a sentence: with a period, unless it ends in a
    /// question mark, a period, or an ellipsis already, as "Where Am I?"
    /// does.
    static func sentence(_ text: String) -> String {
        guard let last = text.last, !"?.…".contains(last) else { return text }
        return text + "."
    }
}

/// A button that, when clicked, starts recording a key press to set as a shortcut
struct ShortcutRecorderButton: View {
    let binding: KeyBinding?
    let isRecording: Bool
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
                Text("Press a key...")
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
        .accessibilityHint(isRecording ? "Press any key to set, or click to cancel" : "Click to record a new shortcut")
        .background(
            ShortcutRecorderEventHandler(
                isActive: isRecording,
                onKeyRecorded: onKeyRecorded,
                onCancel: onCancel
            )
        )
    }

    private var accessibilityLabel: String {
        if isRecording {
            return "Recording shortcut. Press a key."
        } else if let binding = binding {
            return binding.accessibleDisplayString
        } else {
            return "Add shortcut"
        }
    }
}

/// Invisible view that installs a local event monitor when active to capture the next key press
struct ShortcutRecorderEventHandler: NSViewRepresentable {
    let isActive: Bool
    let onKeyRecorded: (KeyBinding) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.updateMonitor(isActive: isActive)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onKeyRecorded: onKeyRecorded, onCancel: onCancel)
    }

    @MainActor
    final class Coordinator {
        let onKeyRecorded: (KeyBinding) -> Void
        let onCancel: () -> Void
        private var monitor: Any?

        init(onKeyRecorded: @escaping (KeyBinding) -> Void, onCancel: @escaping () -> Void) {
            self.onKeyRecorded = onKeyRecorded
            self.onCancel = onCancel
        }

        func updateMonitor(isActive: Bool) {
            if isActive && monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self = self else { return event }
                    // Escape cancels recording
                    if event.keyCode == 53 {
                        self.onCancel()
                        self.removeMonitor()
                        return nil
                    }
                    if let binding = KeyBinding.from(event: event) {
                        self.onKeyRecorded(binding)
                        self.removeMonitor()
                        return nil
                    }
                    return event
                }
            } else if !isActive {
                removeMonitor()
            }
        }

        private func removeMonitor() {
            if let m = monitor {
                NSEvent.removeMonitor(m)
                monitor = nil
            }
        }

    }
}
