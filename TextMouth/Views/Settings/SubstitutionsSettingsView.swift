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
