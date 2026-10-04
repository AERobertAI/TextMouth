import SwiftUI

/// One of the editor's commands as a button (FR04): titled as Settings
/// lists the command, with a hint saying what it does and the shortcuts in
/// force, dimmed when it can't act. The same command runs whether it is
/// pressed here, chosen by its shortcut, or chosen from VoiceOver.
struct AudioEditorCommandButton: View {
    /// The command.
    let action: ShortcutAction
    /// What it does and its shortcuts, as its hint and tooltip.
    let hint: String
    /// Whether it can act now.
    let isEnabled: Bool
    /// Runs it.
    let perform: () -> Void

    var body: some View {
        Button(action.title, action: perform)
            .disabled(!isEnabled)
            .accessibilityHint(hint)
            .help(hint)
    }
}

/// The commands of one of the window's groups of buttons, under its
/// heading (FR04).
struct AudioEditorCommandList: Identifiable, Sendable {
    /// The group's heading.
    let heading: String
    /// Its commands, in the order their buttons show.
    let actions: [ShortcutAction]

    /// Groups are told apart by their headings.
    var id: String { heading }
}

/// A group of the editor's command buttons under a heading (FR04), laid out
/// in as many columns as the window's width allows. VoiceOver meets the
/// heading, then the buttons in order, so its heading navigation moves
/// from group to group.
struct AudioEditorCommandGroup: View {
    /// The group's heading.
    let heading: String
    /// The commands, in order.
    let actions: [ShortcutAction]
    /// The window's model.
    let model: AudioEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(actions) { action in
                    AudioEditorCommandButton(
                        action: action,
                        hint: AudioEditorWording.hint(for: action, bindings: model.bindings(for: action)),
                        isEnabled: model.canPerform(action),
                        perform: { model.perform(action) }
                    )
                }
            }
        }
    }
}

/// The sheet of a question the editor asks with one text field (FR04), such
/// as Go to Time's: a heading, the field, where VoiceOver starts, what to
/// type, and the buttons. An answer that won't do keeps the sheet open,
/// with the reason under the field, which VoiceOver hears too, so it can
/// be corrected where it was typed. Return takes the answer; Escape
/// cancels.
struct AudioEditorPromptSheet: View {
    /// The question.
    let prompt: AudioEditorPrompt
    /// Takes an answer; returns what's wrong with it, or nil once taken.
    let submit: (String) -> String?
    /// Closes the sheet with nothing done.
    let cancel: () -> Void

    /// The answer as typed.
    @State private var text: String
    /// What's wrong with the last answer, shown under the field.
    @State private var problem = ""
    /// Puts the keyboard in the field as the sheet opens.
    @FocusState private var fieldFocused: Bool

    /// The sheet for `prompt`, its field starting as `initialText`.
    init(prompt: AudioEditorPrompt, initialText: String, submit: @escaping (String) -> String?, cancel: @escaping () -> Void) {
        self.prompt = prompt
        self.submit = submit
        self.cancel = cancel
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(prompt.title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            // A plain field, which VoiceOver reads as the edit text it is.
            TextField(prompt.fieldLabel, text: $text)
                .focused($fieldFocused)
                .onSubmit(take)
                .accessibilityLabel(prompt.fieldLabel)
                .accessibilityHint(prompt.explanation)
                .modifier(InitialVoiceOverFocusModifier(isTarget: true))
            Text(prompt.explanation)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !problem.isEmpty {
                Text(problem)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(AudioEditorWording.problemLabel(problem))
            }
            HStack {
                Spacer()
                Button(AudioEditorWording.cancelButton, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(prompt.actionTitle, action: take)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 380)
        .onAppear { fieldFocused = true }
    }

    /// Hands the answer on; keeps the sheet open with the reason when it
    /// won't do.
    private func take() {
        problem = submit(text) ?? ""
    }
}
