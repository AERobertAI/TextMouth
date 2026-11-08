import SwiftUI

/// The colors of the phone's words, in one place (the iPhone interface spec,
/// "Dynamic Type and contrast").
///
/// Apple's accessibility audit finds iOS's secondary gray only "nearly"
/// enough contrast, and the tint a button draws its words in no better, so
/// the phone draws every word in the primary label color and tells the kinds
/// apart by font, weight, and position instead. The Library first did so for
/// its rows (`PhoneRowLines`). Every secondary word on the phone takes its
/// color from `secondary` here, so that if the user chooses the system's
/// gray after all, one line gives it back.
enum PhoneTextColor {
    /// Captions, details, values, and section headings: the words a design
    /// would draw in gray. To undo full contrast, make this `Color.secondary`.
    static let secondary = Color.primary

    /// The words of a button or of a row that is one, which iOS would draw in
    /// the tint. Kept apart from `secondary` because a tint fails the audit
    /// on its own account, whatever is decided about gray.
    static let primary = Color.primary
}

extension View {
    /// Draws secondary words (a caption, a detail, a value, a section
    /// heading) in `PhoneTextColor.secondary`. Named as a color, not as a
    /// hierarchical style: inside a button the hierarchical styles take the
    /// button's tint.
    func phoneSecondaryText() -> some View {
        foregroundStyle(PhoneTextColor.secondary)
    }

    /// Draws the words of a button in `PhoneTextColor.primary`.
    func phonePrimaryText() -> some View {
        foregroundStyle(PhoneTextColor.primary)
    }
}

/// A button whose plain words are drawn in `PhoneTextColor.primary`, in place
/// of `Button(title, action:)`, which draws them in the tint. VoiceOver reads
/// the same label.
struct PhoneActionButton: View {
    /// The button's words.
    let title: String
    /// The button's role, if it has one.
    var role: ButtonRole?
    /// What pressing it does.
    let action: @MainActor () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Text(title).phonePrimaryText()
        }
    }
}

/// A row of a list or form that shows a name and its value, in place of
/// `LabeledContent(name, value:)`, whose value iOS draws in gray: the name
/// takes `PhoneTextColor.primary` (it is a button's label in a choice row),
/// and the value `PhoneTextColor.secondary`.
struct PhoneValueRow: View {
    /// The row's name.
    let name: String
    /// The row's value.
    let value: String

    var body: some View {
        LabeledContent {
            Text(value).phoneSecondaryText()
        } label: {
            Text(name).phonePrimaryText()
        }
    }
}
