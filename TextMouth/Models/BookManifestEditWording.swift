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
    static var editTitle: String {
        // Translators: Menu command that opens an audiobook's manifest.json file in the Mac's default app for JSON files.
        InterfaceText.line("bookManifestEdit.editTitle", "Edit Manifest in Default Editor")
    }
    /// The command that opens it in an app the user chooses.
    static var editWithTitle: String {
        // Translators: Menu command that lets the user choose an app to edit an audiobook's manifest.json file with. The ellipsis shows that a chooser follows.
        InterfaceText.line("bookManifestEdit.editWithTitle", "Edit Manifest With…")
    }

    // MARK: The First Time

    /// The title of the explanation given the first time Edit Manifest is used.
    static func explanationTitle(bookTitle: String) -> String {
        // Translators: Title of the alert shown the first time Edit Manifest is used. %@ is the book's title.
        InterfaceText.line("bookManifestEdit.explanationTitle", "Edit the Manifest of \(bookTitle)?")
    }

    /// What the explanation says will happen: five whole sentences, joined
    /// the way the language joins sentences.
    static var explanation: String {
        SentenceWording.joined([
            // Translators: First sentence of the Edit Manifest explanation. manifest.json is a file name and stays as written.
            InterfaceText.line("bookManifestEdit.explanation.editor", "TextMouth opens the book's manifest.json in your text editor."),
            // Translators: Second sentence of the Edit Manifest explanation: what the manifest lists and what the user can change in it.
            InterfaceText.line("bookManifestEdit.explanation.headings", "It lists the book's tracks in play order, each with its heading's title. You can reorder, retitle, and group them under headings of your own, and set the pauses between them."),
            // Translators: Third sentence of the Edit Manifest explanation. TextEdit is the Mac's text editor; Smart Quotes, Edit and Substitutions are its menu names, so use the words macOS shows for them.
            InterfaceText.line("bookManifestEdit.explanation.quotation", "Type straight quotation marks: in TextEdit, turn off Smart Quotes under Edit, Substitutions."),
            // Translators: Fourth sentence of the Edit Manifest explanation: what happens when the user saves the manifest.
            InterfaceText.line("bookManifestEdit.explanation.rearranges", "When you save, TextMouth checks the manifest and rearranges the book, keeping your place in its track."),
            // Translators: Last sentence of the Edit Manifest explanation: it is shown only the first time.
            InterfaceText.line("common.thisExplanationAppearsOnlyOnce", "This explanation appears only once."),
        ])
    }

    // MARK: Choosing the App

    /// The app chooser's title and message.
    static var appPanelTitle: String {
        // Translators: Title of the panel in which the user chooses an app to edit a manifest.json file with.
        InterfaceText.line("bookManifestEdit.appPanelTitle", "Edit Manifest With")
    }
    static func appPanelMessage(bookTitle: String) -> String {
        // Translators: Message of the panel in which the user chooses an app to edit a book's manifest.json with. %@ is the book's title.
        InterfaceText.line("bookManifestEdit.appPanelMessage", "Choose the app to edit the manifest of \(bookTitle) with.")
    }

    // MARK: What VoiceOver Hears

    /// An edit was taken as the book's arrangement.
    static var updated: String {
        // Translators: Announcement after the user saved an edited manifest.json and TextMouth took it as the book's arrangement of tracks.
        InterfaceText.line("bookManifestEdit.updated", "Manifest updated")
    }

    /// Why an edit was not taken: `problem`, a manifest's problem as an
    /// import says it, as in "Manifest not updated: manifest.json is not
    /// valid JSON: … Fix it in your editor and save again; until then,
    /// Harbour Pilots keeps its headings."
    static func notTaken(problem: String, bookTitle: String) -> String {
        // Translators: Announcement after an edited manifest.json was refused. %1$@ is the reason, a whole sentence in English that names what is wrong inside the file and may stay in English; %2$@ is the book's title.
        InterfaceText.line("bookManifestEdit.notTaken", "Manifest not updated: \(problem) Fix it in your editor and save again; until then, \(bookTitle) keeps its headings.")
    }

    /// The book is not an audiobook of tracks, so it has no manifest to edit.
    static func noManifest(bookTitle: String) -> String {
        // Translators: Message when the user asks to edit the manifest of a book that is not an audiobook of tracks. %@ is the book's title.
        InterfaceText.line("bookManifestEdit.noManifest", "\(bookTitle) isn't an audiobook of tracks, so it has no manifest to edit.")
    }

    /// The book's files are only in the cloud (FR02).
    static func inCloud(bookTitle: String) -> String {
        LibraryCloudWording.notDownloaded(titles: [bookTitle])
    }

    /// The manifest could not be written or read, with why.
    static func cannotBegin(bookTitle: String, reason: String) -> String {
        // Translators: Message when a book's manifest could not be readied for editing. %1$@ is the book's title; %2$@ is the reason, a sentence from the system or TextMouth.
        InterfaceText.line("bookManifestEdit.cannotBegin", "The manifest of \(bookTitle) can't be edited: \(reason)")
    }

    /// Why an edited manifest that gives sections was not taken: a
    /// manifest arranges a book's tracks, and only TextMouth writes
    /// sections, for a converted DAISY book.
    static var sectionsGiven: String {
        SentenceWording.joined([
            // Translators: First sentence of a reason an edited manifest.json was refused. manifest.json is a file name and stays as written; DAISY is a book format.
            InterfaceText.line("bookManifestEdit.sectionsGiven.segments", "manifest.json has segments, which TextMouth writes only for a DAISY book it converts."),
            // Translators: Second sentence of the reason an edited manifest.json was refused for having segments: the user should remove the segments.
            InterfaceText.line("bookManifestEdit.sectionsGiven.audiobook", "Remove them: an audiobook of tracks is arranged with tracks."),
        ])
    }

    /// Why a manifest could not be read once it was readied for editing.
    static var unreadable: String {
        // Translators: Reason an edited manifest.json could not be read back. manifest.json is a file name and stays as written.
        InterfaceText.line("bookManifestEdit.unreadable", "manifest.json could not be read.")
    }

    /// The editor could not be opened, with why.
    static func openFailed(bookTitle: String, reason: String) -> String {
        // Translators: Message when the app that edits a manifest.json could not be opened. %1$@ is the book's title; %2$@ is the reason from the system.
        InterfaceText.line("bookManifestEdit.openFailed", "Couldn't open the manifest of \(bookTitle): \(reason)")
    }
}
