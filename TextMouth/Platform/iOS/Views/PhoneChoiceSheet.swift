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
            ScrollViewReader { proxy in
                List(choices) { choice in
                    choiceRow(choice)
                        .id(choice.id)
                }
                .task {
                    await focusCurrentChoice(scrollingWith: proxy)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                PhoneSheetButton(title: PhoneAppWording.cancel) { dismiss() }
            }
        }
    }

    /// Puts VoiceOver's focus on the current choice, once, on arrival.
    ///
    /// A `List` makes its rows lazily, and a row not yet made has no element:
    /// asking for its focus then does nothing and reports nothing. So the
    /// list first scrolls the row into being, and focus is asked for a moment
    /// later, after VoiceOver has landed somewhere by itself, as it does when
    /// a sheet appears (the engineering review's F12). Setting the state to
    /// nil first makes the request a change even if it held the value before.
    private func focusCurrentChoice(scrollingWith proxy: ScrollViewProxy) async {
        guard let selected, choices.contains(where: { $0.id == selected }) else { return }
        proxy.scrollTo(selected, anchor: .center)
        try? await Task.sleep(for: .milliseconds(350))
        focusedChoice = nil
        focusedChoice = selected
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
                    .phonePrimaryText()
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
