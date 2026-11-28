import Foundation

/// How tall the reader's Book content stands (FR54): Settings' "Book content
/// height", a small choice of three, Medium the twelve lines round 1 gave it
/// (FR48). Whatever is chosen, Book content never takes more than
/// `PhoneReaderControls.bookContentShareOfScreen` of the screen, so Play
/// always shows below it (`PhoneReaderControls.bookContentHeight`).
enum PhoneBookContentHeight: String, CaseIterable, Hashable, Sendable {
    /// About six lines of body text.
    case short
    /// About twelve lines: the height before the setting, and its default.
    case medium
    /// About eighteen lines.
    case tall

    /// The height until the listener chooses one.
    static let `default` = PhoneBookContentHeight.medium

    /// How many lines of body text Book content holds at this height.
    var lines: Int {
        switch self {
        case .short: return 6
        case .medium: return 12
        case .tall: return 18
        }
    }

    /// The height at this choice for `twelveLines`, the twelve lines' height
    /// at the text size in force, in points.
    func scaled(fromTwelveLines twelveLines: Double) -> Double {
        twelveLines * Double(lines) / 12
    }

    /// What the choice is called, in the Settings row's value and its sheet.
    var title: String {
        switch self {
        case .short:
            // Translators: A choice of the Book content height row in iPhone Settings: the book's text area on the reader is about six lines tall.
            return InterfaceText.line("phoneSettings.bookContentHeight.short", "Short")
        case .medium:
            // Translators: A choice of the Book content height row in iPhone Settings: about twelve lines, the default.
            return InterfaceText.line("phoneSettings.bookContentHeight.medium", "Medium")
        case .tall:
            // Translators: A choice of the Book content height row in iPhone Settings: about eighteen lines.
            return InterfaceText.line("phoneSettings.bookContentHeight.tall", "Tall")
        }
    }
}
