import SwiftUI

struct KeyboardShortcutsSettingsView: View {
    @EnvironmentObject var shortcutManager: KeyboardShortcutManager

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
                    shortcutManager.resetToDefaults()
                }
                .accessibilityLabel("Reset all keyboard shortcuts to defaults")
            }
        }
        .padding()
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

struct ShortcutBindingRow: View {
    let action: ShortcutAction
    @EnvironmentObject var shortcutManager: KeyboardShortcutManager
    @State private var isRecording = false
    @State private var recordingSlot: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(action.rawValue)
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
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(action.rawValue): \(shortcutManager.allDisplayStrings(for: action))")
    }

    private var currentBindings: [KeyBinding] {
        shortcutManager.bindingsFor(action)
    }

    private func replaceBinding(at index: Int, with newBinding: KeyBinding) {
        var bindings = currentBindings
        if index < bindings.count {
            bindings[index] = newBinding
        }
        shortcutManager.updateBindings(for: action, to: bindings)
    }

    private func removeBinding(at index: Int) {
        var bindings = currentBindings
        if index < bindings.count {
            bindings.remove(at: index)
        }
        shortcutManager.updateBindings(for: action, to: bindings)
    }

    private func addBinding(_ binding: KeyBinding) {
        shortcutManager.addBinding(binding, to: action)
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

    class Coordinator {
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
                        DispatchQueue.main.async { self.onCancel() }
                        self.removeMonitor()
                        return nil
                    }
                    if let binding = KeyBinding.from(event: event) {
                        DispatchQueue.main.async { self.onKeyRecorded(binding) }
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

        deinit {
            removeMonitor()
        }
    }
}
