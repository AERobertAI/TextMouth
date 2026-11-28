import SwiftUI

/// The pop-up button "Open the next book in" of a feed's Feed Info and of a
/// folder's settings sheet (0.2.5): where the next item opens when listening
/// goes on from one of its items to another. One view for both sheets, so
/// they say and speak the same, built as the sheets build their "When an
/// item ends" pop-up button, so the keyboard and VoiceOver reach it as they
/// reach any other.
///
/// It is dimmed while listening does not go on from the sheet's items, when
/// the choice is not in effect (`NextBookWindowRule.choice`), and its hint
/// then says when it is available. The choice is kept while it is dimmed.
struct NextBookWindowPicker: View {
    /// What the sheet's items are called: episodes, articles, items, books.
    let noun: ListeningOptionsWording.Noun
    /// The choice saved: nil is "Use the global setting".
    @Binding var selection: NextBookWindow?
    /// The global "Open the next book in", which "Use the global setting"
    /// names.
    let global: NextBookWindow
    /// Whether listening goes on from one item to another, so the choice
    /// is in effect.
    let isAvailable: Bool

    /// Every choice, "Use the global setting" (nil) first.
    static let choices: [NextBookWindow?] = [nil] + NextBookWindow.allCases.map { Optional($0) }

    var body: some View {
        // The label is spoken from the control itself: a pop-up button takes
        // no label from the picker's title.
        let label = NextBookWindowWording.label(noun)
        let hint = NextBookWindowWording.hint(noun, enabled: isAvailable)
        Picker(label, selection: $selection) {
            ForEach(Self.choices, id: \.self) { choice in
                Text(NextBookWindowWording.title(choice, global: global)).tag(choice)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(!isAvailable)
        .help(hint)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
    }
}
