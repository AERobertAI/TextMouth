import SwiftUI

/// The Text settings tab: the substitution rules that rewrite text before it
/// is spoken, listed in the order they apply.
///
/// Every rule can be enabled, edited, moved, and deleted from the keyboard,
/// with VoiceOver, or from a braille display. Each row has its own enable
/// checkbox and command buttons, the commands are also VoiceOver actions on
/// the row, and the context menu repeats them. Pointer users can still click
/// a rule to edit it and drag rules into a new order.
struct SubstitutionsSettingsView: View {
    /// The rules this tab shows and changes.
    @ObservedObject private var service: TextSubstitutionService
    /// The rule whose editor sheet is open, if any.
    @State private var editingRule: SubstitutionRule?
    /// Whether the sheet for adding a new rule is open.
    @State private var showAddRule = false

    /// - Parameter service: The rules to show and change: the app's shared
    ///   rules, unless a test supplies its own.
    init(service: TextSubstitutionService = .shared) {
        _service = ObservedObject(wrappedValue: service)
    }

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
                ruleList
            }

            HStack {
                Text("\(service.rules.count) rules (\(service.rules.filter { $0.isEnabled }.count) enabled)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(Self.reorderInstructions)
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

    /// The rules in the order they apply. Each row carries its own controls
    /// and context menu, and dragging rows reorders the rules as well.
    private var ruleList: some View {
        List {
            // Enumerated for each rule's position, but identified by the
            // rule's ID, so SwiftUI moves a row along with its rule.
            ForEach(Array(service.rules.enumerated()), id: \.element.id) { index, rule in
                SubstitutionRuleRow(
                    rule: rule,
                    index: index,
                    count: service.rules.count,
                    onToggle: { service.toggleRule(id: rule.id) },
                    onCommand: { perform($0, on: rule) }
                )
                .contextMenu { ruleMenu(for: rule, at: index) }
            }
            .onMove { source, destination in
                Self.moveByDragging(from: source, to: destination, in: service)
            }
        }
    }

    /// The pointer menu for one rule: the row's commands under the same
    /// names, plus Enable or Disable. Moves that cannot happen are dimmed.
    @ViewBuilder
    private func ruleMenu(for rule: SubstitutionRule, at index: Int) -> some View {
        ruleMenuItem(.edit, for: rule, at: index)
        Button(rule.isEnabled ? "Disable" : "Enable") {
            service.toggleRule(id: rule.id)
        }
        Divider()
        ruleMenuItem(.moveUp, for: rule, at: index)
        ruleMenuItem(.moveDown, for: rule, at: index)
        Divider()
        ruleMenuItem(.delete, for: rule, at: index)
    }

    /// The context menu item that runs `command` on `rule`.
    private func ruleMenuItem(
        _ command: SubstitutionRuleCommand,
        for rule: SubstitutionRule,
        at index: Int
    ) -> some View {
        SubstitutionRuleCommandButton(
            command: command,
            isAvailable: command.isAvailable(at: index, of: service.rules.count)
        ) {
            perform(command, on: rule)
        }
    }

    /// Carry out `command` on `rule`, whichever control asked for it: a row
    /// button, a VoiceOver action, or the context menu.
    private func perform(_ command: SubstitutionRuleCommand, on rule: SubstitutionRule) {
        switch command {
        case .edit:
            editingRule = rule
        case .moveUp, .moveDown:
            guard let direction = command.moveDirection else { return }
            Self.move(rule, direction, in: service)
        case .delete:
            Self.delete(rule, from: service)
        }
    }
}

// MARK: - Moving, deleting, and announcing

extension SubstitutionsSettingsView {
    /// Move `rule` one step and tell VoiceOver where it landed. At an end of
    /// the list nothing moves and nothing is announced.
    static func move(
        _ rule: SubstitutionRule,
        _ direction: SubstitutionRuleMoveDirection,
        in service: TextSubstitutionService
    ) {
        guard let index = service.moveRule(id: rule.id, direction: direction) else { return }
        announcePosition(of: rule, at: index, in: service)
    }

    /// Apply a drag from the list. When the drag took a single rule to a new
    /// place, tell VoiceOver where it landed, as the Move commands do.
    static func moveByDragging(
        from source: IndexSet,
        to destination: Int,
        in service: TextSubstitutionService
    ) {
        // Note the dragged rule and where it started before the move
        // renumbers the list.
        let start = source.count == 1 ? source.first : nil
        let dragged = start.flatMap { service.rules.indices.contains($0) ? service.rules[$0] : nil }
        service.moveRule(from: source, to: destination)
        guard let dragged, let start,
              let index = service.rules.firstIndex(where: { $0.id == dragged.id }),
              index != start else { return }
        announcePosition(of: dragged, at: index, in: service)
    }

    /// What VoiceOver says after a rule moves, counting positions from one:
    /// "Mr. moved to position 3 of 7" for index 2 in a list of 7.
    nonisolated static func movedAnnouncement(ruleName: String, index: Int, count: Int) -> String {
        "\(ruleName) moved to position \(index + 1) of \(count)"
    }

    /// Remove `rule` and tell VoiceOver which rule went, since the row that
    /// had focus disappears with it. A rule already gone is left alone.
    static func delete(_ rule: SubstitutionRule, from service: TextSubstitutionService) {
        guard service.rules.contains(where: { $0.id == rule.id }) else { return }
        service.removeRule(id: rule.id)
        VoiceOverAnnouncer.announce(deletedAnnouncement(ruleName: rule.displayName))
    }

    /// What VoiceOver says after a delete, such as "Mr. deleted".
    nonisolated static func deletedAnnouncement(ruleName: String) -> String {
        "\(ruleName) deleted"
    }

    /// The footer's help on reordering, naming both ways to do it and the
    /// Move commands exactly as their buttons and VoiceOver actions do.
    nonisolated static var reorderInstructions: String {
        let moveUp = SubstitutionRuleCommand.moveUp.title
        let moveDown = SubstitutionRuleCommand.moveDown.title
        return "Use \(moveUp) and \(moveDown), or drag, to reorder. Rules apply top to bottom."
    }

    /// Announce that `rule` now sits at `index` in `service`'s list.
    private static func announcePosition(
        of rule: SubstitutionRule,
        at index: Int,
        in service: TextSubstitutionService
    ) {
        VoiceOverAnnouncer.announce(
            movedAnnouncement(ruleName: rule.displayName, index: index, count: service.rules.count)
        )
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

    /// Delete removes the rule for good, so its button and menu item are
    /// marked destructive.
    var role: ButtonRole? {
        self == .delete ? .destructive : nil
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

/// A button that runs one rule command, named and pictured as that command
/// and dimmed when the command cannot act.
struct SubstitutionRuleCommandButton: View {
    /// The command this button runs.
    let command: SubstitutionRuleCommand
    /// Whether the command can act on its rule; the button is dimmed if not.
    let isAvailable: Bool
    /// Runs the command.
    let action: () -> Void

    var body: some View {
        Button(role: command.role, action: action) {
            Label(command.title, systemImage: command.systemImage)
        }
        .disabled(!isAvailable)
    }
}

// MARK: - Rule rows

/// One rule in the list: its enable checkbox, a summary that opens the
/// editor when clicked, and a button for every rule command.
///
/// For VoiceOver the row is a container labelled with the rule's summary.
/// It holds the checkbox ("Enable Mr.") and the four command buttons as
/// separate controls, so the checkbox is never mistaken for the rule, and it
/// offers the commands that can act as VoiceOver actions.
struct SubstitutionRuleRow: View {
    /// The rule this row shows.
    let rule: SubstitutionRule
    /// The rule's zero-based position in the list.
    let index: Int
    /// How many rules the list holds.
    let count: Int
    /// Turns the rule on or off.
    let onToggle: () -> Void
    /// Runs a command on the rule.
    let onCommand: (SubstitutionRuleCommand) -> Void

    var body: some View {
        HStack(spacing: 8) {
            // The hidden title is still the checkbox's accessibility label.
            Toggle(rule.enableLabel, isOn: Binding(
                get: { rule.isEnabled },
                set: { _ in onToggle() }
            ))
            .labelsHidden()

            summary

            ForEach(SubstitutionRuleCommand.allCases, id: \.self) { command in
                SubstitutionRuleCommandButton(
                    command: command,
                    isAvailable: command.isAvailable(at: index, of: count)
                ) {
                    onCommand(command)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(command.title)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(rule.accessibilitySummary)
        .accessibilityActions {
            ForEach(SubstitutionRuleCommand.available(at: index, of: count), id: \.self) { command in
                Button(command.title) { onCommand(command) }
            }
        }
    }

    /// The rule's name, pattern, replacement, and option tags, dimmed while
    /// the rule is disabled. Clicking it opens the editor, as clicking a rule
    /// always has. VoiceOver hears the same facts in the row's label, so the
    /// drawing itself is hidden from it.
    private var summary: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                if !rule.trimmedName.isEmpty {
                    Text(rule.trimmedName)
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

            optionTags
        }
        .opacity(rule.isEnabled ? 1.0 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture { onCommand(.edit) }
        .accessibilityHidden(true)
    }

    /// Tags for the rule's matching options.
    private var optionTags: some View {
        HStack(spacing: 4) {
            if rule.isRegex { optionTag("regex", color: .purple) }
            if rule.caseSensitive { optionTag("Aa", color: .blue) }
            // Show "word" only while whole-word matching takes effect: the
            // same predicate as the editor toggle, so the tag matches
            // behaviour.
            if rule.isWholeWordEffective { optionTag("word", color: .green) }
        }
    }

    /// One small tag naming a matching option.
    private func optionTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.2))
            .cornerRadius(3)
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
        testOutput = Self.testResult(of: rule, on: testInput)
    }

    /// What `rule` alone makes of `text`, as the Test button shows it.
    ///
    /// A service of its own works it out, with only this rule and with
    /// substitutions on, so showing a test never touches the app's rules or
    /// its substitution switch. The switch is mirrored in config.json, so
    /// turning it on and back off to show a test would save the file twice.
    static func testResult(of rule: SubstitutionRule, on text: String) -> String {
        TextSubstitutionService(rules: [rule]).transform(text).modifiedText
    }
}
