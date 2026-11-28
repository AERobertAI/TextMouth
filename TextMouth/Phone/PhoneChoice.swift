import Foundation

/// One choice in a phone's list of choices, such as a library view, a sort,
/// or a voice (the iPhone interface spec, under "Choices").
///
/// A plain value, so that the code deciding what is offered can be tested on
/// the Mac, which never shows it: `PhoneChoiceSheet`, on iOS, only reads it.
struct PhoneChoice<ID: Hashable>: Identifiable {
    /// What the choice stands for, handed back when it is chosen.
    let id: ID
    /// The words shown and spoken.
    let label: String
    /// What choosing it does, when its label doesn't say. Never names a
    /// gesture.
    var hint: String?
    /// False for a choice that can't be made now, as Sort Descending is in
    /// Manual Order: it stays in the list, dimmed, so nothing moves.
    var isEnabled: Bool

    /// Makes a choice, enabled and with no hint unless it says otherwise.
    init(id: ID, label: String, hint: String? = nil, isEnabled: Bool = true) {
        self.id = id
        self.label = label
        self.hint = hint
        self.isEnabled = isEnabled
    }
}

/// A heading and the choices under it in a phone's list of choices that is grouped, such as the braille tables of one language
/// (FR32). A plain value, like `PhoneChoice`, so the code that makes the groups is tested on the Mac.
struct PhoneChoiceGroup<ID: Hashable>: Identifiable {
    /// What names the group in the list; for a language, its code.
    let id: String
    /// The group's heading, read as a heading; nil for a list that has none.
    let title: String?
    /// The group's choices, in the order they are offered.
    let choices: [PhoneChoice<ID>]
}
