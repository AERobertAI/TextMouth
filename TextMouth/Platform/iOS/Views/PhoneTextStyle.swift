import SwiftUI

/// The colors of the phone's words, in one place.
///
/// The iPhone interface spec (`IOS-INTERFACE-SPEC-2026-11-07.md`) has no
/// section on contrast. Its words on text sizes are "The layout" of the
/// reader ("At large text sizes, the grid becomes one column and the screen
/// scrolls") and "A book's row" ("What's visible"). Full contrast is a
/// decision outside the spec: question 2 of section 6 in
/// `humanQuestions/2026-11-08.md`, which the user has not answered.
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

    /// Words that do nothing now (a dimmed button or row). iOS dims them, and
    /// a color named outright would hide that, so they keep the system's
    /// gray, which Apple's contrast check does not hold a disabled control to.
    /// **Unverified:** that the audit lets a disabled control's text pass.
    static let disabled = Color.secondary
}

/// Draws its words in `color` while the control is enabled, and in
/// `PhoneTextColor.disabled` while it is not, so that a color named outright
/// never hides that a row or button is dimmed.
private struct PhoneTextColored: ViewModifier {
    /// The color while enabled.
    let color: Color
    /// Whether the control the words are in is enabled.
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.foregroundStyle(isEnabled ? color : PhoneTextColor.disabled)
    }
}

extension View {
    /// Draws secondary words (a caption, a detail, a value, a section
    /// heading) in `PhoneTextColor.secondary`. Named as a color, not as a
    /// hierarchical style: inside a button the hierarchical styles take the
    /// button's tint.
    func phoneSecondaryText() -> some View {
        modifier(PhoneTextColored(color: PhoneTextColor.secondary))
    }

    /// Draws the words of a button in `PhoneTextColor.primary`.
    func phonePrimaryText() -> some View {
        modifier(PhoneTextColored(color: PhoneTextColor.primary))
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
/// and the value `PhoneTextColor.secondary`. At the accessibility text sizes
/// the value goes under the name.
struct PhoneValueRow: View {
    /// The row's name.
    let name: String
    /// The row's value.
    let value: String

    /// Whether the text size is one of the accessibility sizes.
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if typeSize.isAccessibilitySize {
            // Side by side, the name was broken in the middle of a word
            // ("dura-tion") beside its value at the largest size (the
            // simulator's screenshot): one above the other, each takes the
            // whole width.
            VStack(alignment: .leading, spacing: 4) {
                Text(name).phonePrimaryText()
                Text(value).phoneSecondaryText()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LabeledContent {
                Text(value).phoneSecondaryText()
            } label: {
                Text(name).phonePrimaryText()
            }
        }
    }
}

/// TEMPORARY (an audit experiment, removed before it is finished): names, in
/// the debug launch variable TEXTMOUTH_EXPERIMENT (comma separated), the
/// candidate causes of an audit finding that a view leaves out for one run.
enum PhoneExperiment {
    /// Whether `name` is switched on. Always false in a release build.
    static func has(_ name: String) -> Bool {
        #if DEBUG
        let list = ProcessInfo.processInfo.environment["TEXTMOUTH_EXPERIMENT"] ?? ""
        return list.split(separator: ",").contains { $0 == name }
        #else
        return false
        #endif
    }
}
