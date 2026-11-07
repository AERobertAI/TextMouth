import Foundation

/// The words of the iPhone app's frame: its first screen, its bare reader, and
/// the app-wide alert. Each is the Mac's word, which sits inside a Mac view, or
/// a word the spec gives. `PhoneAppWordingTests` reads the Mac's sources, so a
/// change on the Mac cannot leave the phone saying something else.
enum PhoneAppWording {
    // MARK: The App-Wide Alert (the Mac's, in ContentView)

    /// The alert's title, when the library names no kind of problem.
    static let errorTitle = "Error"
    /// The button that dismisses the alert.
    static let errorDismiss = "OK"
    /// The alert's message, when the library gives none.
    static let unknownError = "An unknown error occurred."

    // MARK: The First Screen (the spec's)

    /// The navigation title of the Library.
    static let libraryTitle = "Library"
    /// The one row of a library with no books.
    static let emptyLibrary = "Your library is empty. Add to Library adds a book."

    // MARK: The Bare Reader

    /// The Play button's label, by the Mac's words in PlaybackControlsView.
    static func playButton(isPlaying: Bool) -> String {
        isPlaying ? "Pause" : "Play"
    }

    /// The Play button's value while the book loads (the spec's).
    static let loading = "Loading"
}
