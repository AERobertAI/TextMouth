import SwiftUI

struct SubstitutionsSettingsView: View {
    @ObservedObject var service = TextSubstitutionService.shared
    @State private var editingRule: SubstitutionRule?
    @State private var showAddRule = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Enable text substitutions", isOn: $service.isEnabled)
                    .accessibilityLabel("Enable text substitutions")
                    .accessibilityHint("When enabled, text is processed through substitution rules before being spoken")

                Spacer()

                Button("Add Rule") { showAddRule = true }
                    .accessibilityLabel("Add a new substitution rule")

                Button("Reset to Defaults") { service.resetToDefaults() }
                    .accessibilityLabel("Reset all rules to factory defaults")
            }
            .padding()

            Divider()

            if service.rules.isEmpty {
                VStack(spacing: 8) {
                    Text("No substitution rules.")
                        .foregroundColor(.secondary)
                    Text("Add rules to change how text is spoken. Rules are applied in order from top to bottom.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(service.rules) { rule in
                        SubstitutionRuleRow(rule: rule, onToggle: {
                            service.toggleRule(id: rule.id)
                        })
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editingRule = rule
                        }
                        .contextMenu {
                            Button("Edit") { editingRule = rule }
                            Button(rule.isEnabled ? "Disable" : "Enable") {
                                service.toggleRule(id: rule.id)
                            }
                            Divider()
                            Button("Delete", role: .destructive) {
                                service.removeRule(id: rule.id)
                            }
                        }
                    }
                    .onMove { source, destination in
                        service.moveRule(from: source, to: destination)
                    }
                }
            }

            HStack {
                Text("\(service.rules.count) rules (\(service.rules.filter { $0.isEnabled }.count) enabled)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("Drag to reorder. Rules apply top to bottom.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
        .sheet(isPresented: $showAddRule) {
            SubstitutionRuleEditorView(
                rule: SubstitutionRule(pattern: ""),
                isNew: true,
                onSave: { rule in
                    service.addRule(rule)
                    showAddRule = false
                },
                onCancel: { showAddRule = false }
            )
        }
        .sheet(item: $editingRule) { rule in
            SubstitutionRuleEditorView(
                rule: rule,
                isNew: false,
                onSave: { updated in
                    service.updateRule(updated)
                    editingRule = nil
                },
                onCancel: { editingRule = nil }
            )
        }
    }
}

struct SubstitutionRuleRow: View {
    let rule: SubstitutionRule
    let onToggle: () -> Void

    var body: some View {
        HStack {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .accessibilityLabel(rule.isEnabled ? "Enabled" : "Disabled")

            VStack(alignment: .leading, spacing: 2) {
                if !rule.name.isEmpty {
                    Text(rule.name)
                        .font(.headline)
                }
                HStack(spacing: 4) {
                    Text(rule.pattern)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Text(rule.replacement.isEmpty ? "(skip)" : rule.replacement)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(rule.replacement.isEmpty ? .orange : .primary)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                if rule.isRegex {
                    Text("regex")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.purple.opacity(0.2))
                        .cornerRadius(3)
                }
                if rule.caseSensitive {
                    Text("Aa")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.2))
                        .cornerRadius(3)
                }
                // Show the "word" badge only when wholeWord is actually
                // taking effect — same predicate as the editor toggle
                // visibility, so the displayed state stays consistent
                // with behaviour.
                if rule.isWholeWordEffective {
                    Text("word")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.green.opacity(0.2))
                        .cornerRadius(3)
                }
            }
        }
        .opacity(rule.isEnabled ? 1.0 : 0.5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ruleAccessibilityLabel)
        .accessibilityHint("Double-tap to edit, use context menu for more options")
    }

    private var ruleAccessibilityLabel: String {
        var parts: [String] = []
        if !rule.name.isEmpty { parts.append(rule.name) }
        parts.append(rule.isEnabled ? "Enabled" : "Disabled")
        parts.append("Pattern: \(rule.pattern)")
        if rule.replacement.isEmpty {
            parts.append("Action: skip")
        } else {
            parts.append("Replace with: \(rule.replacement)")
        }
        if rule.isRegex { parts.append("Regular expression") }
        if rule.caseSensitive { parts.append("Case sensitive") }
        if rule.isWholeWordEffective { parts.append("Whole word only") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Announcements

extension SubstitutionsSettingsView {
    /// What VoiceOver says after a rule moves, counting positions from one:
    /// "Mr. moved to position 3 of 7" for index 2 in a list of 7.
    nonisolated static func movedAnnouncement(ruleName: String, index: Int, count: Int) -> String {
        "\(ruleName) moved to position \(index + 1) of \(count)"
    }
}

// MARK: - Rule commands

/// A command for one substitution rule. Each row shows every command as a
/// button, offers those that can act as VoiceOver actions, and repeats them
/// in its context menu, always under the same name.
enum SubstitutionRuleCommand: CaseIterable {
    case edit
    case moveUp
    case moveDown
    case delete

    /// The command's name: its button's spoken label and tooltip, its
    /// VoiceOver action, and its context menu item.
    var title: String {
        switch self {
        case .edit: return "Edit"
        case .moveUp: return "Move Up"
        case .moveDown: return "Move Down"
        case .delete: return "Delete"
        }
    }

    /// The SF Symbol drawn on the command's row button.
    var systemImage: String {
        switch self {
        case .edit: return "pencil"
        case .moveUp: return "arrow.up"
        case .moveDown: return "arrow.down"
        case .delete: return "trash"
        }
    }

    /// The step this command moves a rule, or nil when it moves nothing.
    var moveDirection: SubstitutionRuleMoveDirection? {
        switch self {
        case .moveUp: return .up
        case .moveDown: return .down
        case .edit, .delete: return nil
        }
    }

    /// Whether the command can act on the rule at `index` in a list of
    /// `count` rules. Only moves depend on position: the first rule cannot
    /// move up and the last cannot move down.
    func isAvailable(at index: Int, of count: Int) -> Bool {
        guard let moveDirection else { return true }
        return moveDirection.destination(from: index, count: count) != nil
    }

    /// The commands that can act on the rule at `index`, in button order.
    /// VoiceOver actions have no dimmed state, so a row offers only these.
    static func available(at index: Int, of count: Int) -> [SubstitutionRuleCommand] {
        allCases.filter { $0.isAvailable(at: index, of: count) }
    }
}

// MARK: - Spoken descriptions

extension SubstitutionRule {
    /// The rule's name without surrounding white space; empty when unnamed.
    fileprivate var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the settings list calls the rule: its name, or else its pattern,
    /// or "Untitled rule" when both are blank.
    var displayName: String {
        if !trimmedName.isEmpty { return trimmedName }
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedPattern.isEmpty ? "Untitled rule" : trimmedPattern
    }

    /// The label of the rule's enable checkbox, such as "Enable Mr.".
    var enableLabel: String {
        "Enable \(displayName)"
    }

    /// What VoiceOver reads for the rule itself: its name, pattern,
    /// replacement, and matching options, such as
    /// "Mr., Pattern: \bMr\., Replace with: Mister, Regular expression".
    /// It leaves out whether the rule is enabled; its checkbox says that.
    var accessibilitySummary: String {
        var parts: [String] = []
        if !trimmedName.isEmpty { parts.append(trimmedName) }
        parts.append("Pattern: \(pattern)")
        parts.append(replacement.isEmpty ? "Action: skip" : "Replace with: \(replacement)")
        if isRegex { parts.append("Regular expression") }
        if caseSensitive { parts.append("Case sensitive") }
        if isWholeWordEffective { parts.append("Whole word only") }
        return parts.joined(separator: ", ")
    }
}

struct SubstitutionRuleEditorView: View {
    @State var rule: SubstitutionRule
    let isNew: Bool
    let onSave: (SubstitutionRule) -> Void
    let onCancel: () -> Void

    @State private var patternError: String?
    @State private var testInput = ""
    @State private var testOutput = ""

    var body: some View {
        VStack(spacing: 16) {
            Text(isNew ? "Add Substitution Rule" : "Edit Substitution Rule")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Form {
                TextField("Name (optional)", text: $rule.name)
                    .accessibilityLabel("Rule name")

                TextField("Pattern", text: $rule.pattern)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Search pattern")
                    .onChange(of: rule.pattern) { _ in validatePattern() }

                TextField("Replacement (empty to skip)", text: $rule.replacement)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Replacement text. Leave empty to skip matched text.")
                    .accessibilityHint("For regex, use backslash 1, backslash 2, etc. for capture groups")

                if let error = patternError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .accessibilityLabel("Pattern error: \(error)")
                }

                Toggle("Regular expression", isOn: $rule.isRegex)
                    .accessibilityLabel("Use regular expression matching")
                    .accessibilityHint("When enabled, use \\b in the pattern for word boundaries")
                    .onChange(of: rule.isRegex) { _ in validatePattern() }

                Toggle("Case sensitive", isOn: $rule.caseSensitive)
                    .accessibilityLabel("Case sensitive matching")

                // "Match whole word only" only makes sense for plain
                // (non-regex) patterns that don't already contain
                // whitespace — for regex, the user can place \b directly
                // in the pattern; for multi-word phrases, the notion of
                // a single word boundary doesn't apply. The stored value
                // on the rule is preserved across edits so that toggling
                // regex off (or removing the space) brings it back.
                if !rule.isRegex && !rule.pattern.contains(where: { $0.isWhitespace }) {
                    Toggle("Match whole word only", isOn: $rule.wholeWord)
                        .accessibilityLabel("Match whole word only")
                        .accessibilityHint("Match only when the pattern is not adjacent to letters, digits, or underscores")
                }

                Section {
                    TextField("Test input", text: $testInput)
                        .accessibilityLabel("Test input text")
                    if !testOutput.isEmpty {
                        Text("Result: \(testOutput)")
                            .font(.system(.caption, design: .monospaced))
                            .accessibilityLabel("Test result: \(testOutput)")
                    }
                    Button("Test") { runTest() }
                        .disabled(rule.pattern.isEmpty || testInput.isEmpty)
                        .accessibilityLabel("Test this rule against the input")
                } header: {
                    Text("Test")
                }
            }

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button(isNew ? "Add" : "Save") {
                    onSave(rule)
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(rule.pattern.isEmpty || patternError != nil)
            }
        }
        .padding()
        .frame(width: 480, height: 460)
        .navigationTitle(isNew ? "Add Substitution Rule" : "Edit Substitution Rule")
        .onAppear { validatePattern() }
    }

    private func validatePattern() {
        patternError = nil
        guard rule.isRegex, !rule.pattern.isEmpty else { return }
        var options: NSRegularExpression.Options = []
        if !rule.caseSensitive { options.insert(.caseInsensitive) }
        do {
            _ = try NSRegularExpression(pattern: rule.pattern, options: options)
        } catch {
            patternError = "Invalid regex: \(error.localizedDescription)"
        }
    }

    private func runTest() {
        guard !rule.pattern.isEmpty, !testInput.isEmpty else { return }
        let service = TextSubstitutionService.shared
        // Temporarily create a service-like transform with just this rule
        let tempRules = service.rules
        let tempEnabled = service.isEnabled
        service.rules = [rule]
        service.isEnabled = true
        let result = service.transform(testInput)
        testOutput = result.modifiedText
        service.rules = tempRules
        service.isEnabled = tempEnabled
    }
}
