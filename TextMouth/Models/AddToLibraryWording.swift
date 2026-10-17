import Foundation

/// Every word of the Add to Library button and sheet (FR20): the button's
/// title, label, and hint, the sheet's heading, and each choice's one-line
/// summary. The wording is pinned by tests, and the choices' titles come from
/// their shortcut actions (`AddToLibraryChoice.title`), not from here.
enum AddToLibraryWording {
    /// The sheet's heading (with the header trait) and its navigation title.
    static let sheetTitle = "Add to Library"

    /// The toolbar button's title.
    static let buttonTitle = "Add to Library"

    /// The toolbar button's accessibility label.
    static let buttonLabel = "Add to Library"

    /// The toolbar button's accessibility hint: what its sheet offers.
    static let buttonHint = "Opens a sheet with the ways to add to the library: open a book, import a folder, make a book from text, record audio, or add a feed"

    /// The sheet's Cancel button.
    static let cancel = "Cancel"

    /// What `choice` does, in one line: shown under its button and given as
    /// the button's hint. Open Book and Add Feed reuse the constants their
    /// old toolbar buttons used, so those words have one home.
    static func summary(_ choice: AddToLibraryChoice) -> String {
        switch choice {
        case .openBook: return LibraryView.importBookHint
        case .importFolder: return "Chooses a folder that holds a DAISY book or audio tracks and imports it as one book."
        case .newFromText: return "Makes a new book from text you paste or type."
        case .newRecording: return "Records from a microphone into a new audiobook."
        case .addFeed: return FeedWording.addFeedButtonHint
        }
    }

    /// The hint of a dimmed choice, one whose menu command does not work in
    /// the window the sheet is in: its summary, then why it does nothing.
    static func unavailableHint(_ choice: AddToLibraryChoice) -> String {
        "\(summary(choice)) Not available in this window."
    }

    /// The button's spoken label: the choice's title, then, when a key is in
    /// force for it, a comma and the key in words, as in "Open Book…, Command
    /// + O". `key` is nil for a choice with no key.
    static func label(_ choice: AddToLibraryChoice, key: String?) -> String {
        guard let key else { return choice.title }
        return "\(choice.title), \(key)"
    }
}
