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

    /// Why an edit was not taken, as VoiceOver hears it once a check found
    /// it, then where the edited text was kept (`kept(_:)`), as in "Text not
    /// updated: the edited text of Harbour Pilots isn't UTF-8 text. Save it
    /// as UTF-8 in your editor; until then, the book keeps the text it had.
    /// Your edited text was also kept as content.md.edited-20261004T123012Z,
    /// in the book's package."
    static func notTaken(_ refusal: BookTextEditRefusal, bookTitle: String, keptCopy: URL?) -> String {
        "\(refused(refusal, bookTitle: bookTitle)) \(kept(keptCopy))"
    }

    /// Why an edit was not taken: the book keeps the text it had, unless its
    /// own file changed too, which its text is read from again.
    static func refused(_ refusal: BookTextEditRefusal, bookTitle: String) -> String {
        switch refusal {
        case .notText:
            return "Text not updated: the edited text of \(bookTitle) isn't UTF-8 text. "
                + "Save it as UTF-8 in your editor; until then, the book keeps the text it had."
        case .noChapters:
            return "Text not updated: the edited text of \(bookTitle) has no chapter left with anything in it. "
                + "Undo the change in your editor and save again; until then, the book keeps the text it had."
        case .sourceChanged:
            return "Text not updated: the original file of \(bookTitle) changed too, "
                + "so TextMouth reads the book's text from that file again the next time the book opens."
        case .failed(let reason):
            return "Text not updated: \(reason)"
        }
    }

    /// Where the edited text was kept, beside content.md: "Your edited text
    /// was also kept as content.md.edited-20261004T123012Z, in the book's
    /// package." Without a copy, nothing replaces content.md, which holds
    /// the edit, and that is said instead.
    static func kept(_ copy: URL?) -> String {
        guard let copy else {
            return "No copy of your edited text could be kept, so TextMouth leaves content.md as it is."
        }
        return "Your edited text was also kept as \(copy.lastPathComponent), in the book's package."
    }

    /// What a reader shows in place of a book it does not open while the
    /// book's edited text cannot be taken (`BookTextEditPending`), as in
    /// "Harbour Pilots can't open while its edited text can't be used: it
    /// isn't UTF-8 text. Save it as UTF-8 in your editor, and the book
    /// opens. Your edited text was also kept as content.md.edited-…, in the
    /// book's package." The reader opens the book once an edit is taken.
    static func held(_ refusal: BookTextEditRefusal, bookTitle: String, keptCopy: URL?) -> String {
        let why: String
        switch refusal {
        case .notText:
            why = "it isn't UTF-8 text. Save it as UTF-8 in your editor, and the book opens."
        case .noChapters:
            why = "it has no chapter left with anything in it. Undo the change in your editor and save again, "
                + "and the book opens."
        case .sourceChanged:
            why = "the book's own file changed too. Open the book again to read its text from that file."
        case .failed(let reason):
            why = reason
        }
        return "\(bookTitle) can't open while its edited text can't be used: \(why) \(kept(keptCopy))"
    }

    /// A rebuild read the book's text from its own file again, over other
    /// text in content.md, which was kept first: "The text of Harbour Pilots
    /// was read again from its own file. The text content.md held before was
    /// kept as content.md.edited-20261004T123012Z, in the book's package."
    /// That text is most often what the user saved, but may be an earlier
    /// reading of the file, so it is not called theirs.
    static func replaced(bookTitle: String, keptCopy: URL) -> String {
        "The text of \(bookTitle) was read again from its own file. "
            + "The text content.md held before was kept as \(keptCopy.lastPathComponent), in the book's package."
    }

    /// Why an edit could not be committed while the book's record could
    /// not take it.
    static let recordUnavailable = "the book's record can't be changed now. "
        + "TextMouth tries again the next time you save or come back to TextMouth."

    /// Why a rebuild left a content.md that is only in the cloud alone.
    static let onlyInCloud = "content.md is only in the cloud, so TextMouth leaves it as it is."

    /// Why a rebuild left content.md alone when no copy of the text it would
    /// replace could be kept.
    static let noCopyKept = "no copy of the edited text could be kept, so TextMouth leaves content.md as it is."

    /// Why a rebuild left alone a save no check had read yet; the check that
    /// reads it follows.
    static let notReadYet = "TextMouth hasn't read the latest save yet."

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
