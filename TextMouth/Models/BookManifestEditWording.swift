import Foundation

/// The words of Edit Manifest in Default Editor and Edit Manifest With…
/// (FR17): the commands, the explanation given the first time, the app
/// chooser, and what VoiceOver hears as an edit is taken or refused, each
/// built once for the screen and VoiceOver alike. The buttons are Edit
/// Text's (`BookTextEditWording`), and a manifest's problems are said in
/// the words an import uses (`AudioManifestProblem`).
enum BookManifestEditWording {
    // MARK: Commands

    /// The command that opens a book's manifest in the default app for JSON.
    static let editTitle = "Edit Manifest in Default Editor"
    /// The command that opens it in an app the user chooses.
    static let editWithTitle = "Edit Manifest With…"

    // MARK: The First Time

    /// The title of the explanation given the first time Edit Manifest is used.
    static func explanationTitle(bookTitle: String) -> String {
        "Edit the Manifest of \(bookTitle)?"
    }

    /// What the explanation says will happen.
    static let explanation = "TextMouth opens the book's manifest.json in your text editor. "
        + "It lists the book's tracks in the order they play, each with the title its heading shows; "
        + "you can reorder and retitle them, group them under headings of your own, and set the pauses between them. "
        + "Type straight quotation marks: in TextEdit, turn off Smart Quotes under Edit, Substitutions. "
        + "When you save, TextMouth checks the manifest and rearranges the book, keeping your place in its track. "
        + "This explanation appears only once."

    // MARK: Choosing the App

    /// The app chooser's title and message.
    static let appPanelTitle = "Edit Manifest With"
    static func appPanelMessage(bookTitle: String) -> String {
        "Choose the app to edit the manifest of \(bookTitle) with."
    }

    // MARK: What VoiceOver Hears

    /// An edit was taken as the book's arrangement.
    static let updated = "Manifest updated"

    /// Why an edit was not taken: `problem`, a manifest's problem as an
    /// import says it, as in "Manifest not updated: manifest.json is not
    /// valid JSON: … Fix it in your editor and save again; until then,
    /// Harbour Pilots keeps its headings."
    static func notTaken(problem: String, bookTitle: String) -> String {
        "Manifest not updated: \(problem) Fix it in your editor and save again; until then, \(bookTitle) keeps its headings."
    }

    /// The book is not an audiobook of tracks, so it has no manifest to edit.
    static func noManifest(bookTitle: String) -> String {
        "\(bookTitle) isn't an audiobook of tracks, so it has no manifest to edit."
    }

    /// The book's files are only in the cloud (FR02).
    static func inCloud(bookTitle: String) -> String {
        LibraryCloudWording.notDownloaded(titles: [bookTitle])
    }

    /// The manifest could not be written or read, with why.
    static func cannotBegin(bookTitle: String, reason: String) -> String {
        "The manifest of \(bookTitle) can't be edited: \(reason)"
    }

    /// Why an edited manifest that gives sections was not taken: a
    /// manifest arranges a book's tracks, and only TextMouth writes
    /// sections, for a converted DAISY book.
    static let sectionsGiven = "manifest.json has segments, which TextMouth writes only for a DAISY book it converts. "
        + "Remove them: an audiobook of tracks is arranged with tracks."

    /// Why a manifest could not be read once it was readied for editing.
    static let unreadable = "manifest.json could not be read."

    /// The editor could not be opened, with why.
    static func openFailed(bookTitle: String, reason: String) -> String {
        "Couldn't open the manifest of \(bookTitle): \(reason)"
    }
}
