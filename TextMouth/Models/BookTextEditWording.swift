import Foundation

/// The words of Edit Text in Default Editor and Edit Text With… (FR05):
/// the commands, the explanation given the first time, the app chooser,
/// and what VoiceOver hears as an edit is taken or refused, each built
/// once for the screen and VoiceOver alike.
enum BookTextEditWording {
    // MARK: Commands

    /// The command that opens a book's text in the default app for Markdown.
    static let editTitle = "Edit Text in Default Editor"
    /// The command that opens it in an app the user chooses.
    static let editWithTitle = "Edit Text With…"

    // MARK: The First Time

    /// The title of the explanation given the first time Edit Text is used.
    static func explanationTitle(bookTitle: String) -> String {
        "Edit the Text of \(bookTitle)?"
    }

    /// What the explanation says will happen.
    static let explanation = "TextMouth opens the book's text in your text editor, as a Markdown file. "
        + "Each line beginning with <!-- chapter: starts a chapter; keep those lines. "
        + "When you save, TextMouth reads your changes and updates the book, keeping your place as near as it can. "
        + "This explanation appears only once."

    /// The explanation's buttons: going on, which Return presses, and
    /// Cancel, which Escape presses.
    static let continueTitle = "Continue"
    static let cancelTitle = "Cancel"

    // MARK: Choosing the App

    /// The app chooser's title, message, and button.
    static let appPanelTitle = "Edit Text With"
    static func appPanelMessage(bookTitle: String) -> String {
        "Choose the app to edit the text of \(bookTitle) with."
    }
    static let appPanelPrompt = "Edit With"

    // MARK: What VoiceOver Hears

    /// An edit was taken as the book's text.
    static let updated = "Text updated"

    /// Why an edited text was not taken; the book keeps the text it had.
    static func refused(_ refusal: BookTextEditRefusal, bookTitle: String) -> String {
        switch refusal {
        case .notText:
            return "Text not updated: the edited text of \(bookTitle) isn't UTF-8 text. "
                + "Save it as UTF-8 in your editor; until then, the book keeps the text it had."
        case .noChapters:
            return "Text not updated: the edited text of \(bookTitle) has no chapter left with anything in it. "
                + "Undo the change in your editor and save again; until then, the book keeps the text it had."
        }
    }

    /// The book's own file changed while its text was edited, so the edit
    /// was not taken.
    static func sourceChanged(bookTitle: String) -> String {
        "Text not updated: the original file of \(bookTitle) changed too, "
            + "so TextMouth reads the book's text from that file again."
    }

    /// The edit could not be committed to the book's record, with why.
    static func failed(reason: String) -> String {
        "Text not updated: \(reason)"
    }

    /// Why an edit could not be committed while the book's record could
    /// not take it.
    static let recordUnavailable = "the book's record can't be changed now. TextMouth tries again when you next save."

    /// Why Edit Text could not begin for the book `bookTitle`.
    static func cannotBegin(_ failure: BookTextEditStartFailure, bookTitle: String) -> String {
        switch failure {
        case .inCloud:
            return LibraryCloudWording.notDownloaded(titles: [bookTitle])
        case .missing:
            return "The text of \(bookTitle) isn't ready to edit yet. Open the book once, then try again."
        case .unreadable:
            return "The text of \(bookTitle) can't be read, so it can't be edited."
        }
    }

    /// An audiobook has no text to edit, for now.
    static func noText(bookTitle: String) -> String {
        "\(bookTitle) is an audiobook, which has no text to edit."
    }

    /// The editor could not be opened, with why.
    static func openFailed(bookTitle: String, reason: String) -> String {
        "Couldn't open the text of \(bookTitle): \(reason)"
    }
}
