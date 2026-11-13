import SwiftUI

/// The options bar at the top of the Reading List (FR09): what a book
/// opened from the reading list does when it ends, whether continuing
/// passes over finished books, whether a finished book leaves the list, and,
/// in a cloud library, whether this Mac keeps the list's books downloaded.
///
/// All are AppKit controls the keyboard and VoiceOver reach as they reach
/// any other, side by side with no group around them, so VoiceOver moves to
/// each directly: a pop-up button, which speaks its label, the option
/// chosen, and its hint, and the checkboxes, each of which speaks its
/// label, whether it is checked, and its hint. Each choice is saved with
/// the list at once, by the closures the window gives.
struct ReadingListOptionsBar: View {
    /// What a book opened from the list does when it ends.
    let continuation: ReadingList.Continuation
    /// Whether continuing passes over finished books.
    let skipsFinished: Bool
    /// Whether a book leaves the list as soon as it is finished.
    let removesFinished: Bool
    /// Whether this Mac keeps the list's books downloaded; this Mac's own
    /// choice, not the list's.
    let keepsBooks: Bool
    /// Whether the library is in a cloud location, which alone shows the
    /// checkbox for keeping the list's books on this Mac.
    let showsKeepChoice: Bool
    /// Saves a new choice of what a book does when it ends.
    let chooseContinuation: (ReadingList.Continuation) -> Void
    /// Saves skipping finished books on or off.
    let chooseSkipsFinished: (Bool) -> Void
    /// Saves removing finished books on or off.
    let chooseRemovesFinished: (Bool) -> Void
    /// Saves keeping the list's books on this Mac on or off, on this Mac.
    let chooseKeepsBooks: (Bool) -> Void

    var body: some View {
        HStack(spacing: 16) {
            // The label is spoken from the control itself, as in Settings:
            // a pop-up button takes no label from the picker's title.
            Picker(ReadingListWording.continuationLabel, selection: Binding(
                get: { continuation },
                set: { chooseContinuation($0) }
            )) {
                ForEach(ReadingList.Continuation.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help(ReadingListWording.continuationHint)
            .accessibilityLabel(ReadingListWording.continuationLabel)
            .accessibilityHint(ReadingListWording.continuationHint)

            Toggle(ReadingListWording.skipFinishedLabel, isOn: Binding(
                get: { skipsFinished },
                set: { chooseSkipsFinished($0) }
            ))
            .checkboxToggleStyle()
            .help(ReadingListWording.skipFinishedHint)
            .accessibilityLabel(ReadingListWording.skipFinishedLabel)
            .accessibilityHint(ReadingListWording.skipFinishedHint)

            Toggle(ReadingListWording.removeFinishedLabel, isOn: Binding(
                get: { removesFinished },
                set: { chooseRemovesFinished($0) }
            ))
            .checkboxToggleStyle()
            .help(ReadingListWording.removeFinishedHint)
            .accessibilityLabel(ReadingListWording.removeFinishedLabel)
            .accessibilityHint(ReadingListWording.removeFinishedHint)

            // Only a cloud library has downloads to keep; elsewhere there is
            // nothing to choose and no control to find.
            if showsKeepChoice {
                Toggle(ReadingListWording.keepBooksLabel, isOn: Binding(
                    get: { keepsBooks },
                    set: { chooseKeepsBooks($0) }
                ))
                .checkboxToggleStyle()
                .help(ReadingListWording.keepBooksHint)
                .accessibilityLabel(ReadingListWording.keepBooksLabel)
                .accessibilityHint(ReadingListWording.keepBooksHint)
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08))
    }
}
