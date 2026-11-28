import Foundation

/// The words of the iPhone app's frame: its first screen, its bare reader, and
/// the app-wide alert. Each is the Mac's word, which sits inside a Mac view, or
/// a word the spec gives. `PhoneAppWordingTests` reads the Mac's sources, so a
/// change on the Mac cannot leave the phone saying something else.
///
/// Every word is localized here, once, with the same English key the Mac's
/// literal has, so a translation of "Cancel" serves both apps and every phone
/// sheet that shows these (FR34). They are computed, so no language is cached.
enum PhoneAppWording {
    // MARK: The App-Wide Alert (the Mac's, in ContentView)

    /// The alert's title, when the library names no kind of problem.
    static var errorTitle: String {
        // Translators: Title of an alert about a problem, when the problem has no more specific title.
        InterfaceText.line("common.error", "Error")
    }

    /// The button that dismisses the alert.
    static var errorDismiss: String {
        // Translators: Button that dismisses an alert about a problem.
        InterfaceText.line("common.ok", "OK")
    }

    /// The alert's message, when the library gives none.
    static var unknownError: String {
        // Translators: Message of an alert about a problem, when nothing more is known about it.
        InterfaceText.line("common.anUnknownErrorOccurred", "An unknown error occurred.")
    }

    // MARK: Every Sheet and Question

    /// The button that closes a sheet or answers a question with nothing
    /// done or changed: the Mac's "Cancel", said once for every phone view.
    static var cancel: String {
        // Translators: Button that closes a sheet or answers a question without doing or changing anything.
        InterfaceText.line("common.cancel", "Cancel")
    }

    /// The toolbar button that closes a sheet that has nothing to cancel.
    static var close: String {
        // Translators: Button that closes a sheet, such as the sleep timer sheet over a book's reader.
        InterfaceText.line("common.close", "Close")
    }

    /// The button that saves a sheet's edits: the Mac's "Save".
    static var save: String {
        // Translators: Button that saves the changes made in a sheet.
        InterfaceText.line("common.save", "Save")
    }

    // MARK: The First Screen (the spec's)

    /// The navigation title of the Library.
    static var libraryTitle: String {
        // Translators: Title of the first screen, the list of the user's books and folders.
        InterfaceText.line("common.library", "Library")
    }

    /// The one row of a library with no books.
    static var emptyLibrary: String {
        // Translators: The only row of an empty library. "Add to Library" is the name of the button that adds a book, so keep it the same as that button's label.
        InterfaceText.line("phoneApp.emptyLibrary", "Your library is empty. Add to Library adds a book.")
    }

    // MARK: The Bare Reader

    /// The Play button's label, by the Mac's words in PlaybackControlsView.
    static func playButton(isPlaying: Bool) -> String {
        isPlaying
            // Translators: Label of the button that pauses the book while it is playing.
            ? InterfaceText.line("common.pause", "Pause")
            // Translators: Label of the button that starts playing the book.
            : InterfaceText.line("common.play", "Play")
    }

    /// The Play button's value while the book loads (the spec's).
    static var loading: String {
        // Translators: Value of the Play button while the book is loading, spoken by VoiceOver.
        InterfaceText.line("phoneApp.loading", "Loading")
    }

    // MARK: Reopening at Launch

    /// Said with low priority at a launch after the app ended while opening the
    /// book `title`, which is therefore not opened again (the engineering
    /// review's F4, in its words).
    static func closedWhileOpening(_ title: String) -> String {
        // Translators: Announced at launch after the app closed while it was opening a book. %@ is the book's title, which is not opened again.
        InterfaceText.line("phoneApp.closedWhileOpening", "TextMouth closed while opening \(title), so it wasn't reopened.")
    }
}
