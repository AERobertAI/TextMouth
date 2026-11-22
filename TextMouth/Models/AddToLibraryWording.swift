import Foundation

/// Every word of the Add to Library button and sheet (FR20): the button's
/// title, label, and hint, the sheet's heading, and each choice's one-line
/// summary. The wording is pinned by tests, and the choices' titles come from
/// their shortcut actions (`AddToLibraryChoice.title`), not from here.
enum AddToLibraryWording {
    /// The sheet's heading (with the header trait) and its navigation title.
    static var sheetTitle: String {
        // Translators: Heading and navigation title of the sheet that lists the ways to add to the library. Title case.
        InterfaceText.line("common.addToLibrary", "Add to Library")
    }

    /// The toolbar button's title.
    static var buttonTitle: String {
        // Translators: Title of the Library toolbar button that opens the sheet of ways to add to the library. Title case.
        InterfaceText.line("common.addToLibrary", "Add to Library")
    }

    /// The toolbar button's accessibility label.
    static var buttonLabel: String {
        // Translators: VoiceOver label of the Library toolbar button that opens the sheet of ways to add to the library. Title case.
        InterfaceText.line("common.addToLibrary", "Add to Library")
    }

    /// The toolbar button's accessibility hint: what its sheet offers.
    static var buttonHint: String {
        // Translators: VoiceOver hint of the Add to Library toolbar button. Names the five choices the sheet offers, in the order the sheet lists them.
        InterfaceText.line("addToLibrary.buttonHint", "Opens a sheet to open a book, import a folder, make a book from text, record audio, or add a feed")
    }

    /// The sheet's Cancel button.
    static var cancel: String {
        // Translators: Title of the Cancel button of the Add to Library sheet, which closes it.
        InterfaceText.line("common.cancel", "Cancel")
    }

    /// What `choice` does, in one line: shown under its button and given as
    /// the button's hint. Open Book and Add Feed reuse the constants their
    /// old toolbar buttons used, so those words have one home.
    static func summary(_ choice: AddToLibraryChoice) -> String {
        switch choice {
        case .openBook: return LibraryView.importBookHint
        // Translators: One-line summary and VoiceOver hint of the Import Folder choice of the Add to Library sheet.
        case .importFolder: return InterfaceText.line("addToLibrary.summary.importFolder", "Imports a folder holding a DAISY book or audio tracks as one book.")
        // Translators: One-line summary and VoiceOver hint of the New from Text choice of the Add to Library sheet.
        case .newFromText: return InterfaceText.line("addToLibrary.summary.newFromText", "Makes a book from text you paste or type.")
        // Translators: One-line summary and VoiceOver hint of the Record choice of the Add to Library sheet.
        case .newRecording: return InterfaceText.line("addToLibrary.summary.newRecording", "Records from a microphone into a new audiobook.")
        case .addFeed: return FeedWording.addFeedButtonHint
        }
    }

    /// The hint of a dimmed choice, one whose menu command does not work in
    /// the window the sheet is in: its summary, then why it does nothing.
    static func unavailableHint(_ choice: AddToLibraryChoice) -> String {
        // Translators: Second sentence of the hint of a dimmed choice of the Add to Library sheet: its menu command does not work in the window the sheet is in. The choice's own summary comes first.
        let reason = InterfaceText.line("addToLibrary.unavailableHint", "Not available in this window.")
        return SentenceWording.joined([summary(choice), reason])
    }

    /// The button's spoken label: the choice's title, then, when a key is in
    /// force for it, a comma and the key in words, as in "Open Book…, Command
    /// + O". `key` is nil for a choice with no key.
    static func label(_ choice: AddToLibraryChoice, key: String?) -> String {
        guard let key else { return choice.title }
        return SentenceWording.commaJoined([choice.title, key])
    }
}
