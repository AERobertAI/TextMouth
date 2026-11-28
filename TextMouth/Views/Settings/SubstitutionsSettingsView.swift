import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// The Text settings tab: the substitution rules that rewrite text before it
/// is spoken, listed in the order they apply, and below them the Repeated
/// Symbols group, which sets how runs of one symbol are spoken.
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
    /// Whether Reset to Defaults is asking before it replaces the rules.
    @State private var showResetConfirmation = false
    /// What the last lexicon import or export says, while its alert is
    /// open (FMT08); nil when no alert is open.
    @State private var lexiconOutcome: LexiconFileOutcome?

    /// - Parameter service: The rules to show and change: the app's shared
    ///   rules, unless a test supplies its own.
    init(service: TextSubstitutionService = .shared) {
        _service = ObservedObject(wrappedValue: service)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle(SubstitutionsWording.enableTitle, isOn: $service.isEnabled)
                    .accessibilityLabel(SubstitutionsWording.enableTitle)
                    .accessibilityHint(SubstitutionsWording.enableHint)

                Spacer()

                Button(SubstitutionsWording.addRuleTitle) { showAddRule = true }
                    .accessibilityLabel(SubstitutionsWording.addRuleLabel)

                #if os(macOS)
                // Pronunciation lexicon files, as buttons beside the other
                // rule commands so the keyboard reaches them in order (FMT08).
                Button(PronunciationLexiconWording.importButton) { chooseLexiconToImport() }
                    .accessibilityLabel(PronunciationLexiconWording.importLabel)
                    .accessibilityHint(PronunciationLexiconWording.importHint)
                Button(PronunciationLexiconWording.exportButton) { chooseLexiconDestination() }
                    .accessibilityLabel(PronunciationLexiconWording.exportLabel)
                    .accessibilityHint(PronunciationLexiconWording.exportHint)
                #endif

                // Asks first, naming what it replaces: it used to replace
                // every rule at once (TODO A10).
                Button(SubstitutionsWording.resetTitle) { showResetConfirmation = true }
                    .accessibilityLabel(SubstitutionsWording.resetLabel)
                    .accessibilityHint(Self.resetHint)
            }
            .padding()

            Divider()

            if service.rules.isEmpty {
                VStack(spacing: 8) {
                    Text(SubstitutionsWording.emptyHeading)
                        .foregroundColor(.secondary)
                    Text(SubstitutionsWording.emptyHint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ruleList
            }

            HStack {
                Text(Self.ruleCountText(rules: service.rules.count, enabled: service.rules.filter { $0.isEnabled }.count))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text(Self.reorderInstructions)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 4)

            Divider()

            RepeatedSymbolsSettingsView(service: service)
                .padding(.horizontal)
                .padding(.vertical, 8)
        }
        .alert(Self.resetConfirmationTitle, isPresented: $showResetConfirmation) {
            Button(SubstitutionsWording.resetButton, role: .destructive) {
                service.resetToDefaults()
            }
            Button(SubstitutionsWording.cancelTitle, role: .cancel) {}
        } message: {
            Text(Self.resetConfirmationMessage(
                ruleCount: service.rules.count,
                defaultCount: TextSubstitutionService.defaultRules.count
            ))
        }
        // The result of a lexicon import or export, which VoiceOver reads
        // as the alert appears.
        .alert(
            lexiconOutcome?.title ?? "",
            isPresented: Binding(get: { lexiconOutcome != nil }, set: { if !$0 { lexiconOutcome = nil } })
        ) {
            Button(SubstitutionsWording.okTitle) { lexiconOutcome = nil }
        } message: {
            Text(lexiconOutcome?.message ?? "")
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

    #if os(macOS)
    /// Import Rules…: asks for a pronunciation lexicon file in an Open
    /// panel, then adds its entries as rules and tells what happened.
    private func chooseLexiconToImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Self.lexiconFileTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = PronunciationLexiconWording.importPanelMessage
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            lexiconOutcome = LexiconFileActions.importLexicon(at: url, into: service)
        }
    }

    /// Export Rules…: asks where to save, then writes the rules as a
    /// pronunciation lexicon and tells what was left out. With no rule that
    /// a lexicon can hold, it says so without asking for a file.
    private func chooseLexiconDestination() {
        guard service.exportedLexicon().written > 0 else {
            lexiconOutcome = LexiconFileOutcome(
                title: PronunciationLexiconWording.exportFailedTitle,
                message: PronunciationLexiconWording.nothingToExport
            )
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = Self.lexiconFileTypes.prefix(1).map { $0 }
        panel.nameFieldStringValue = PronunciationLexiconWording.exportFileName
        panel.message = PronunciationLexiconWording.exportPanelMessage
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            lexiconOutcome = LexiconFileActions.exportLexicon(from: service, to: url)
        }
    }

    /// The file types of a pronunciation lexicon: its own extension first,
    /// then any XML file, as lexicons are often saved as .xml.
    private static var lexiconFileTypes: [UTType] {
        [UTType(filenameExtension: "pls"), .xml].compactMap { $0 }
    }
    #endif

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
        Button(rule.isEnabled ? SubstitutionsWording.disableTitle : SubstitutionsWording.enableRuleTitle) {
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
        SubstitutionsWording.moved(ruleName: ruleName, position: index + 1, count: count)
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
        SubstitutionsWording.deleted(ruleName: ruleName)
    }

    /// Reset to Defaults' hint: what it does, and that it asks first.
    nonisolated static var resetHint: String { SubstitutionsWording.resetHint }
    /// The title of the alert Reset to Defaults asks with.
    nonisolated static var resetConfirmationTitle: String { SubstitutionsWording.resetConfirmationTitle }

    /// What the alert asks about: how many rules the list holds and how
    /// many it will hold, as in "The 15 rules in the list will be replaced
    /// by TextMouth's 16 default rules. Rules you added or changed will be
    /// lost."
    nonisolated static func resetConfirmationMessage(ruleCount: Int, defaultCount: Int) -> String {
        SubstitutionsWording.resetConfirmationMessage(ruleCount: ruleCount, defaultCount: defaultCount)
    }

    /// The footer's count of the rules: "1 rule (1 enabled)", "15 rules (12
    /// enabled)" (TODO A10; it said "1 rules").
    nonisolated static func ruleCountText(rules: Int, enabled: Int) -> String {
        SubstitutionsWording.ruleCount(rules: rules, enabled: enabled)
    }

    /// The footer's help on reordering, naming both ways to do it and the
    /// Move commands exactly as their buttons and VoiceOver actions do.
    nonisolated static var reorderInstructions: String {
        SubstitutionsWording.reorderInstructions(
            moveUp: SubstitutionRuleCommand.moveUp.title,
            moveDown: SubstitutionRuleCommand.moveDown.title
        )
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
        case .edit: return SubstitutionsWording.editTitle
        case .moveUp: return SubstitutionsWording.moveUpTitle
        case .moveDown: return SubstitutionsWording.moveDownTitle
        case .delete: return SubstitutionsWording.deleteTitle
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

                    Text(rule.replacement.isEmpty ? SubstitutionsWording.skipMark : rule.replacement)
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
            if rule.isRegex { optionTag(SubstitutionsWording.regexTag, color: .purple) }
            if rule.caseSensitive { optionTag(SubstitutionsWording.caseTag, color: .blue) }
            // Show "word" only while whole-word matching takes effect: the
            // same predicate as the editor toggle, so the tag matches
            // behaviour.
            if rule.isWholeWordEffective { optionTag(SubstitutionsWording.wordTag, color: .green) }
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
        return trimmedPattern.isEmpty ? SubstitutionsWording.untitledRule : trimmedPattern
    }

    /// The label of the rule's enable checkbox, such as "Enable Mr.".
    var enableLabel: String {
        SubstitutionsWording.enableLabel(displayName)
    }

    /// What VoiceOver reads for the rule itself: its name, pattern,
    /// replacement, and matching options, such as
    /// "Mr., Pattern: \bMr\., Replace with: Mister, Regular expression".
    /// It leaves out whether the rule is enabled; its checkbox says that.
    var accessibilitySummary: String {
        var parts: [String] = []
        if !trimmedName.isEmpty { parts.append(trimmedName) }
        parts.append(SubstitutionsWording.patternPart(pattern))
        parts.append(replacement.isEmpty ? SubstitutionsWording.skipPart : SubstitutionsWording.replacePart(replacement))
        if isRegex { parts.append(SubstitutionsWording.regexPart) }
        if caseSensitive { parts.append(SubstitutionsWording.casePart) }
        if isWholeWordEffective { parts.append(SubstitutionsWording.wholeWordPart) }
        return SentenceWording.commaJoined(parts)
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
            Text(SubstitutionsWording.editorTitle(isNew: isNew))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Form {
                TextField(SubstitutionsWording.namePrompt, text: $rule.name)
                    .accessibilityLabel(SubstitutionsWording.nameLabel)

                TextField(SubstitutionsWording.patternPrompt, text: $rule.pattern)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel(SubstitutionsWording.patternLabel)
                    .onChange(of: rule.pattern) { _, _ in validatePattern() }

                TextField(SubstitutionsWording.replacementPrompt, text: $rule.replacement)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel(SubstitutionsWording.replacementLabel)
                    .accessibilityHint(Self.replacementHint)

                if let error = patternError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .accessibilityLabel(SubstitutionsWording.patternErrorLabel(error))
                }

                Toggle(SubstitutionsWording.regexTitle, isOn: $rule.isRegex)
                    .accessibilityLabel(SubstitutionsWording.regexLabel)
                    .accessibilityHint(SubstitutionsWording.regexHint)
                    .onChange(of: rule.isRegex) { _, _ in validatePattern() }

                Toggle(SubstitutionsWording.caseTitle, isOn: $rule.caseSensitive)
                    .accessibilityLabel(SubstitutionsWording.caseLabel)

                // "Match whole word only" only makes sense for plain
                // (non-regex) patterns that don't already contain
                // whitespace — for regex, the user can place \b directly
                // in the pattern; for multi-word phrases, the notion of
                // a single word boundary doesn't apply. The stored value
                // on the rule is preserved across edits so that toggling
                // regex off (or removing the space) brings it back.
                if !rule.isRegex && !rule.pattern.contains(where: { $0.isWhitespace }) {
                    Toggle(SubstitutionsWording.wholeWordTitle, isOn: $rule.wholeWord)
                        .accessibilityLabel(SubstitutionsWording.wholeWordTitle)
                        .accessibilityHint(SubstitutionsWording.wholeWordHint)
                }

                Section {
                    TextField(SubstitutionsWording.testInputPrompt, text: $testInput)
                        .accessibilityLabel(SubstitutionsWording.testInputLabel)
                    if !testOutput.isEmpty {
                        Text(SubstitutionsWording.resultText(testOutput))
                            .font(.system(.caption, design: .monospaced))
                            .accessibilityLabel(SubstitutionsWording.testResultLabel(testOutput))
                    }
                    Button(SubstitutionsWording.testTitle) { runTest() }
                        .disabled(rule.pattern.isEmpty || testInput.isEmpty)
                        .accessibilityLabel(SubstitutionsWording.testButtonLabel)
                } header: {
                    Text(SubstitutionsWording.testTitle)
                }
            }

            HStack {
                Button(SubstitutionsWording.cancelTitle, action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button(isNew ? SubstitutionsWording.addTitle : SubstitutionsWording.saveTitle) {
                    onSave(rule)
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(rule.pattern.isEmpty || patternError != nil)
            }
        }
        .padding()
        .frame(width: 480, height: 460)
        .navigationTitle(SubstitutionsWording.editorTitle(isNew: isNew))
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
            patternError = SubstitutionsWording.invalidRegex(error.localizedDescription)
        }
    }

    private func runTest() {
        guard !rule.pattern.isEmpty, !testInput.isEmpty else { return }
        testOutput = Self.testResult(of: rule, on: testInput)
    }

    /// The replacement field's hint: how a regular expression's replacement
    /// puts back what a group of its pattern matched. The replacement is an
    /// `NSRegularExpression` template, which reads a dollar sign and a
    /// group's number; a backslash there escapes the next character, so
    /// "\1", which the hint said until TODO A10, gives a plain "1". The
    /// dollar sign is named in words as well, since VoiceOver speaks "$1" as
    /// "one dollar".
    nonisolated static var replacementHint: String { SubstitutionsWording.replacementHint }

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

// MARK: - The Words

/// The words of the Substitutions settings tab and its rule editor, each
/// defined once for the screen, VoiceOver, a braille display, and the tests
/// (FR34).
enum SubstitutionsWording {
    // MARK: The List

    /// The switch's title and label.
    static var enableTitle: String {
        // Translators: Title and VoiceOver label of the switch in the Substitutions settings that turns text substitution rules on.
        InterfaceText.line("substitutions.enableTitle", "Enable text substitutions")
    }
    /// The switch's hint.
    static var enableHint: String {
        // Translators: VoiceOver hint of the Enable text substitutions switch in the Substitutions settings.
        InterfaceText.line("substitutions.enableHint", "Applies the rules to text before it is spoken")
    }
    /// The button that adds a rule.
    static var addRuleTitle: String {
        // Translators: Title of the button in the Substitutions settings that opens the editor for a new substitution rule.
        InterfaceText.line("substitutions.addRuleTitle", "Add Rule")
    }
    /// The same button's VoiceOver label.
    static var addRuleLabel: String {
        // Translators: VoiceOver label of the Add Rule button in the Substitutions settings.
        InterfaceText.line("substitutions.addRuleLabel", "Add a new substitution rule")
    }
    /// The button that resets the rules.
    static var resetTitle: String {
        // Translators: Title of the button in the Substitutions settings that replaces every rule with TextMouth's default rules, after asking.
        InterfaceText.line("common.resetToDefaults", "Reset to Defaults")
    }
    /// The same button's VoiceOver label.
    static var resetLabel: String {
        // Translators: VoiceOver label of the Reset to Defaults button in the Substitutions settings.
        InterfaceText.line("substitutions.resetLabel", "Reset all rules to factory defaults")
    }
    /// Reset to Defaults' hint: what it does, and that it asks first.
    static var resetHint: String {
        // Translators: VoiceOver hint of the Reset to Defaults button in the Substitutions settings.
        InterfaceText.line("substitutions.resetHint", "Asks first, then replaces every rule with the defaults.")
    }
    /// The title of the alert Reset to Defaults asks with.
    static var resetConfirmationTitle: String {
        // Translators: Title of the question asked before the Substitutions settings replace every rule with the defaults.
        InterfaceText.line("substitutions.resetConfirmationTitle", "Reset Text Rules to Defaults?")
    }
    /// The alert's button that goes ahead.
    static var resetButton: String {
        // Translators: Title of the button that goes ahead in the question asked before the Substitutions settings replace every rule with the defaults.
        InterfaceText.line("common.reset", "Reset")
    }
    /// A button that cancels.
    static var cancelTitle: String {
        // Translators: Title of a button that cancels, in the Substitutions settings' question and rule editor.
        InterfaceText.line("common.cancel", "Cancel")
    }
    /// A button that dismisses an alert.
    static var okTitle: String {
        // Translators: Title of the button that dismisses the alert telling the result of importing or exporting pronunciation rules.
        InterfaceText.line("common.ok", "OK")
    }
    /// What the list says while it holds no rule.
    static var emptyHeading: String {
        // Translators: Shown in the Substitutions settings while the list holds no rule.
        InterfaceText.line("substitutions.emptyHeading", "No substitution rules.")
    }
    /// The line under that.
    static var emptyHint: String {
        // Translators: Shown under "No substitution rules." in the Substitutions settings.
        InterfaceText.line("substitutions.emptyHint", "Add rules to change how text is spoken. They apply top to bottom.")
    }
    /// A rule's context-menu item that turns it off.
    static var disableTitle: String {
        // Translators: Title of the context menu item that turns a substitution rule off.
        InterfaceText.line("substitutions.disableTitle", "Disable")
    }
    /// A rule's context-menu item that turns it on.
    static var enableRuleTitle: String {
        // Translators: Title of the context menu item that turns a substitution rule on.
        InterfaceText.line("substitutions.enableRuleTitle", "Enable")
    }

    // MARK: Counts and Announcements

    /// The message of the Reset to Defaults question: how many rules the list
    /// holds and how many it will hold: "The 15 rules in the list will be
    /// replaced by TextMouth's 16 default rules. Rules you added or changed
    /// will be lost." Each count is a plural of its own, joined into the
    /// sentence.
    static func resetConfirmationMessage(ruleCount: Int, defaultCount: Int) -> String {
        let rules = rulesCounted(ruleCount)
        let defaults = defaultRulesCounted(defaultCount)
        return SentenceWording.joined([
            // Translators: First sentence of the message of the question asked before the Substitutions settings replace every rule with the defaults. %1$@ is the number of rules in the list with their noun, such as "15 rules", and %2$@ is the number of default rules with their noun, such as "16 default rules".
            InterfaceText.line("substitutions.resetConfirmationMessage.replaced", "The \(rules) in the list will be replaced by TextMouth's \(defaults)."),
            // Translators: Last sentence of the message of the question asked before the Substitutions settings replace every rule with the defaults.
            InterfaceText.line("substitutions.resetConfirmationMessage.changed", "Rules you added or changed will be lost."),
        ])
    }
    /// `count` rules: "1 rule", "15 rules".
    private static func rulesCounted(_ count: Int) -> String {
        // Translators: A count of substitution rules inside a longer sentence. %lld is the number of rules.
        InterfaceText.line("substitutions.rulesCounted", "\(number: count) rules")
    }
    /// `count` default rules: "1 default rule", "16 default rules".
    private static func defaultRulesCounted(_ count: Int) -> String {
        // Translators: A count of TextMouth's default substitution rules inside a longer sentence. %lld is the number of default rules.
        InterfaceText.line("substitutions.defaultRulesCounted", "\(number: count) default rules")
    }
    /// The footer's count of the rules: "1 rule (1 enabled)", "15 rules (12
    /// enabled)".
    static func ruleCount(rules: Int, enabled: Int) -> String {
        // Translators: The footer of the Substitutions settings: how many rules the list holds and how many of them are turned on. %1$lld is the number of rules, which the noun agrees with, and %2$@ is the number enabled.
        InterfaceText.line("substitutions.ruleCount", "\(number: rules) rules (\(enabled.interfaceFormatted()) enabled)")
    }
    /// The footer's help on reordering, naming both ways to do it and the
    /// Move commands exactly as their buttons and VoiceOver actions do.
    static func reorderInstructions(moveUp: String, moveDown: String) -> String {
        // Translators: Help in the footer of the Substitutions settings on reordering rules. %1$@ and %2$@ are the titles of the Move Up and Move Down commands, which stay as those commands show them.
        InterfaceText.line("substitutions.reorderInstructions", "Use \(moveUp) and \(moveDown), or drag, to reorder. Rules apply top to bottom.")
    }
    /// What VoiceOver says after a rule moves, counting positions from one.
    static func moved(ruleName: String, position: Int, count: Int) -> String {
        // Translators: Announcement after a substitution rule moves in the list. %1$@ is the rule's name, %2$@ is its new place counting from one, and %3$@ is how many rules the list holds.
        InterfaceText.line("substitutions.moved", "\(ruleName) moved to position \(position.interfaceFormatted()) of \(count.interfaceFormatted())")
    }
    /// What VoiceOver says after a delete.
    static func deleted(ruleName: String) -> String {
        // Translators: Announcement after a substitution rule is deleted. %@ is the rule's name.
        InterfaceText.line("common.valueDeleted", "\(ruleName) deleted")
    }

    // MARK: The Rule Commands

    /// The Edit command's name.
    static var editTitle: String {
        // Translators: Name of the command that opens a substitution rule's editor: a row button's label and tooltip, a VoiceOver action, and a context menu item.
        InterfaceText.line("common.edit", "Edit")
    }
    /// The Move Up command's name.
    static var moveUpTitle: String {
        // Translators: Name of the command that moves a substitution rule up the list: a row button's label and tooltip, a VoiceOver action, and a context menu item.
        InterfaceText.line("common.moveUp", "Move Up")
    }
    /// The Move Down command's name.
    static var moveDownTitle: String {
        // Translators: Name of the command that moves a substitution rule down the list: a row button's label and tooltip, a VoiceOver action, and a context menu item.
        InterfaceText.line("common.moveDown", "Move Down")
    }
    /// The Delete command's name.
    static var deleteTitle: String {
        // Translators: Name of the command that deletes a substitution rule: a row button's label and tooltip, a VoiceOver action, and a context menu item.
        InterfaceText.line("common.delete", "Delete")
    }

    // MARK: A Rule's Row

    /// What a row shows for a replacement of nothing.
    static var skipMark: String {
        // Translators: Shown in a substitution rule's row where its replacement would be, when the rule skips the matched text.
        InterfaceText.line("substitutions.skipMark", "(skip)")
    }
    /// The small tag of a rule that is a regular expression.
    static var regexTag: String {
        // Translators: A small tag in a substitution rule's row: the rule's pattern is a regular expression. Short for regular expression, in lower case.
        InterfaceText.line("substitutions.regexTag", "regex")
    }
    /// The small tag of a rule that is case sensitive.
    static var caseTag: String {
        // Translators: A small tag in a substitution rule's row: the rule is case sensitive. A capital and a small letter of the language's alphabet.
        InterfaceText.line("substitutions.caseTag", "Aa")
    }
    /// The small tag of a rule that matches whole words only.
    static var wordTag: String {
        // Translators: A small tag in a substitution rule's row: the rule matches whole words only. In lower case.
        InterfaceText.line("substitutions.wordTag", "word")
    }
    /// What a rule is called when it has neither a name nor a pattern.
    static var untitledRule: String {
        // Translators: The name a substitution rule is given in lists and announcements when it has neither a name nor a pattern.
        InterfaceText.line("substitutions.untitledRule", "Untitled rule")
    }
    /// The label of a rule's enable checkbox.
    static func enableLabel(_ name: String) -> String {
        // Translators: VoiceOver label of the checkbox that turns a substitution rule on or off. %@ is the rule's name.
        InterfaceText.line("substitutions.enableLabel", "Enable \(name)")
    }
    /// The pattern, as a row's spoken label says it.
    static func patternPart(_ pattern: String) -> String {
        // Translators: A part of a substitution rule's spoken summary. %@ is the rule's pattern.
        InterfaceText.line("substitutions.patternPart", "Pattern: \(pattern)")
    }
    /// What a rule that skips says.
    static var skipPart: String {
        // Translators: A part of a substitution rule's spoken summary: the rule removes the text it matches.
        InterfaceText.line("substitutions.skipPart", "Action: skip")
    }
    /// What a rule that replaces says.
    static func replacePart(_ replacement: String) -> String {
        // Translators: A part of a substitution rule's spoken summary. %@ is the replacement text.
        InterfaceText.line("substitutions.replacePart", "Replace with: \(replacement)")
    }
    /// A regular expression rule's part of the spoken summary.
    static var regexPart: String {
        // Translators: A part of a substitution rule's spoken summary: the pattern is a regular expression.
        InterfaceText.line("substitutions.regularExpression", "Regular expression")
    }
    /// A case sensitive rule's part of the spoken summary.
    static var casePart: String {
        // Translators: A part of a substitution rule's spoken summary: capital and small letters are told apart.
        InterfaceText.line("substitutions.caseSensitive", "Case sensitive")
    }
    /// A whole word rule's part of the spoken summary.
    static var wholeWordPart: String {
        // Translators: A part of a substitution rule's spoken summary: the rule matches whole words only.
        InterfaceText.line("substitutions.wholeWordPart", "Whole word only")
    }

    // MARK: The Editor

    /// The editor's heading and navigation title.
    static func editorTitle(isNew: Bool) -> String {
        guard isNew else {
            // Translators: Heading and navigation title of the editor of an existing substitution rule.
            return InterfaceText.line("substitutions.editorTitle.edit", "Edit Substitution Rule")
        }
        // Translators: Heading and navigation title of the editor of a new substitution rule.
        return InterfaceText.line("substitutions.editorTitle.addSubstitution", "Add Substitution Rule")
    }
    /// The name field's placeholder.
    static var namePrompt: String {
        // Translators: Placeholder of the field that names a substitution rule in the rule editor.
        InterfaceText.line("substitutions.namePrompt", "Name (optional)")
    }
    /// The name field's VoiceOver label.
    static var nameLabel: String {
        // Translators: VoiceOver label of the field that names a substitution rule in the rule editor.
        InterfaceText.line("substitutions.nameLabel", "Rule name")
    }
    /// The pattern field's placeholder.
    static var patternPrompt: String {
        // Translators: Placeholder of the field that holds a substitution rule's search pattern in the rule editor.
        InterfaceText.line("substitutions.patternPrompt", "Pattern")
    }
    /// The pattern field's VoiceOver label.
    static var patternLabel: String {
        // Translators: VoiceOver label of the field that holds a substitution rule's search pattern in the rule editor.
        InterfaceText.line("substitutions.patternLabel", "Search pattern")
    }
    /// The replacement field's placeholder.
    static var replacementPrompt: String {
        // Translators: Placeholder of the field that holds a substitution rule's replacement text in the rule editor. Leaving it empty removes the matched text.
        InterfaceText.line("substitutions.replacementPrompt", "Replacement (empty to skip)")
    }
    /// The replacement field's VoiceOver label.
    static var replacementLabel: String {
        // Translators: VoiceOver label of the replacement field in the substitution rule editor.
        InterfaceText.line("substitutions.replacementLabel", "Replacement text. Leave empty to skip matched text.")
    }
    /// The replacement field's hint: how a regular expression's replacement
    /// puts back what a group of its pattern matched. The dollar sign is
    /// named in words as well, since VoiceOver speaks "$1" as "one dollar".
    static var replacementHint: String {
        // Translators: VoiceOver hint of the replacement field in the substitution rule editor. $1 and $2 are written as in regular expressions and stay as written.
        InterfaceText.line("substitutions.replacementHint", "In a regular expression, a dollar sign and a group's number, as in $1 or $2, put back what that group matched.")
    }
    /// The label of the pattern's error.
    static func patternErrorLabel(_ error: String) -> String {
        // Translators: VoiceOver label of the message that says a substitution rule's pattern is not a valid regular expression. %@ is the message.
        InterfaceText.line("substitutions.patternErrorLabel", "Pattern error: \(error)")
    }
    /// The message about a pattern that is not a regular expression.
    static func invalidRegex(_ reason: String) -> String {
        // Translators: Shown in the substitution rule editor when the pattern is not a valid regular expression. %@ is the reason the system gives, which may be in English. Regex is short for regular expression.
        InterfaceText.line("substitutions.invalidRegex", "Invalid regex: \(reason)")
    }
    /// The regular expression switch's title.
    static var regexTitle: String {
        // Translators: Title of the switch in the substitution rule editor that makes the pattern a regular expression.
        InterfaceText.line("substitutions.regularExpression", "Regular expression")
    }
    /// The same switch's VoiceOver label.
    static var regexLabel: String {
        // Translators: VoiceOver label of the Regular expression switch in the substitution rule editor.
        InterfaceText.line("substitutions.regexLabel", "Use regular expression matching")
    }
    /// The same switch's VoiceOver hint.
    static var regexHint: String {
        // Translators: VoiceOver hint of the Regular expression switch in the substitution rule editor. \b is regular expression syntax and stays as written.
        InterfaceText.line("substitutions.regexHint", "When enabled, use \\b in the pattern for word boundaries")
    }
    /// The case sensitive switch's title.
    static var caseTitle: String {
        // Translators: Title of the switch in the substitution rule editor that makes the pattern tell capital and small letters apart.
        InterfaceText.line("substitutions.caseSensitive", "Case sensitive")
    }
    /// The same switch's VoiceOver label.
    static var caseLabel: String {
        // Translators: VoiceOver label of the Case sensitive switch in the substitution rule editor.
        InterfaceText.line("substitutions.caseLabel", "Case sensitive matching")
    }
    /// The whole word switch's title and label.
    static var wholeWordTitle: String {
        // Translators: Title and VoiceOver label of the switch in the substitution rule editor that makes the pattern match whole words only.
        InterfaceText.line("substitutions.wholeWordTitle", "Match whole word only")
    }
    /// The same switch's VoiceOver hint.
    static var wholeWordHint: String {
        // Translators: VoiceOver hint of the Match whole word only switch in the substitution rule editor.
        InterfaceText.line("substitutions.wholeWordHint", "Skips matches next to letters, digits, or underscores")
    }
    /// The test input field's placeholder.
    static var testInputPrompt: String {
        // Translators: Placeholder of the field in the substitution rule editor where text is typed to test the rule on.
        InterfaceText.line("substitutions.testInputPrompt", "Test input")
    }
    /// The test input field's VoiceOver label.
    static var testInputLabel: String {
        // Translators: VoiceOver label of the test input field in the substitution rule editor.
        InterfaceText.line("substitutions.testInputLabel", "Test input text")
    }
    /// The test result as the screen shows it.
    static func resultText(_ result: String) -> String {
        // Translators: The text a substitution rule made of the test input, shown in the rule editor. %@ is the result.
        InterfaceText.line("substitutions.resultText", "Result: \(result)")
    }
    /// The test result as VoiceOver reads it.
    static func testResultLabel(_ result: String) -> String {
        // Translators: VoiceOver label of the text a substitution rule made of the test input. %@ is the result.
        InterfaceText.line("substitutions.testResultLabel", "Test result: \(result)")
    }
    /// The test button's title, and the test group's heading.
    static var testTitle: String {
        // Translators: Title of the button that tests a substitution rule on the input, and the heading of the group that holds it, in the rule editor.
        InterfaceText.line("substitutions.testTitle", "Test")
    }
    /// The test button's VoiceOver label.
    static var testButtonLabel: String {
        // Translators: VoiceOver label of the Test button in the substitution rule editor.
        InterfaceText.line("substitutions.testButtonLabel", "Test this rule against the input")
    }
    /// The button that adds a new rule.
    static var addTitle: String {
        // Translators: Title of the button that adds a new substitution rule, in the rule editor.
        InterfaceText.line("common.add", "Add")
    }
    /// The button that saves an edited rule.
    static var saveTitle: String {
        // Translators: Title of the button that saves an edited substitution rule, in the rule editor.
        InterfaceText.line("common.save", "Save")
    }
}
