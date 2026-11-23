import SwiftUI

/// The Interface Language group at the top of the Mac's Miscellaneous tab (FR39): a pop-up of System and the 25
/// languages, each by its own name and then by its name in the interface language, and a short line saying that some of
/// macOS's own words change only at the next launch.
///
/// Choosing a language switches the interface at once and announces the new language in its own words
/// (`InterfaceLanguagePicker.apply`). The choice is the system's per-app language, so System Settings shows it too.
struct InterfaceLanguageSettingsSection: View {
    /// The choice the pop-up shows. It starts as what is stored, which includes a choice made in System Settings.
    @State private var choice: InterfaceLanguageChoice

    /// A group showing what is stored now, or `choice`, which tests give.
    init(choice: InterfaceLanguageChoice = InterfaceLanguageStore().choice()) {
        _choice = State(initialValue: choice)
    }

    var body: some View {
        // The choices are read here, in the body, so a switch of language words them again.
        let options = InterfaceLanguagePicker.options()
        Section {
            Picker(InterfaceLanguagePickerWording.title, selection: selection) {
                ForEach(options) { option in
                    Text(option.label).tag(option.choice)
                }
            }
            .accessibilityLabel(InterfaceLanguagePickerWording.title)
            .accessibilityHint(InterfaceLanguagePickerWording.hint)

            // Static text, so VoiceOver and a braille display can read it where it is.
            Text(InterfaceLanguagePickerWording.launchNote)
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text(InterfaceLanguagePickerWording.title)
        }
    }

    /// The pop-up's selection: a change is applied at once, which switches the interface and announces it.
    private var selection: Binding<InterfaceLanguageChoice> {
        Binding(
            get: { choice },
            set: { newChoice in
                guard newChoice != choice else { return }
                choice = newChoice
                InterfaceLanguagePicker.apply(newChoice)
            }
        )
    }
}
