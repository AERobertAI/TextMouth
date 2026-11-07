import SwiftUI

/// The phone's way to pick from a list of choices: a sheet with one row for
/// each, the current one marked selected, where choosing closes the sheet.
///
/// SwiftUI's `Menu` isn't used for these, since it doesn't return VoiceOver's
/// focus when it closes, and `AccessibilityFocusState` can't bring it back
/// (the spec, under "Choices"; REPORTED by CVS Health's SwiftUI techniques).
/// Focus lands on the current choice, so the next flick reaches its
/// neighbor. The caller returns focus to its own control in the sheet's
/// `onDismiss`.
///
/// Nothing here has run on iOS: the 0.35-second wait before asking for focus
/// is the figure careful apps report, and is on the hand-check list.
struct PhoneChoiceSheet<ID: Hashable>: View {
    /// The sheet's title, read as its heading.
    let title: String
    /// The choices, in the order they're offered.
    let choices: [PhoneChoice<ID>]
    /// The current choice, marked selected. Nil when none is current, as for
    /// a sheet of commands.
    let selected: ID?
    /// Called once with the choice made, as the sheet closes. Cancel doesn't
    /// call it.
    let onChoose: (ID) -> Void

    /// Closes the sheet, whichever way it's left.
    @Environment(\.dismiss) private var dismiss
    /// Which row has VoiceOver's focus: set once, on arrival.
    @AccessibilityFocusState private var focusedChoice: ID?

    var body: some View {
        NavigationStack {
            List(choices) { choice in
                choiceRow(choice)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                // VoiceOver lands somewhere by itself as a sheet appears, so
                // ask a moment later, or the request is lost.
                try? await Task.sleep(for: .milliseconds(350))
                focusedChoice = selected
            }
        }
    }

    /// One choice's row: a button whose checkmark is for sight alone, since
    /// VoiceOver hears the selected trait instead.
    private func choiceRow(_ choice: PhoneChoice<ID>) -> some View {
        Button {
            dismiss()
            onChoose(choice.id)
        } label: {
            HStack {
                Text(choice.label)
                Spacer()
                if choice.id == selected {
                    Image(systemName: "checkmark")
                        .accessibilityHidden(true)
                }
            }
        }
        .disabled(!choice.isEnabled)
        .accessibilityAddTraits(choice.id == selected ? .isSelected : [])
        .accessibilityHint(choice.hint ?? "")
        .accessibilityFocused($focusedChoice, equals: choice.id)
    }
}
