import Foundation

/// What VoiceOver's escape gesture (the two-finger scrub) does on a Library
/// screen (the spec, "How a person moves around" and "Searching").
///
/// The system already does the rest: it pops a pushed screen (the reader, a
/// folder) through the navigation stack's Back, and it closes a sheet unless
/// that sheet disabled its interactive dismissal, as the import question
/// does, so that only an answer settles it. A search is the one place the
/// system doesn't know what "back" means, so this type says.
enum PhoneEscapePolicy {
    /// What a scrub on a Library screen does.
    enum LibraryOutcome: Equatable, Sendable {
        /// Empty the search field and put focus on it ("A scrub clears the
        /// search, and the list comes back with focus on the field").
        case clearSearch
        /// Go back one screen, from a folder to its parent.
        case goBack
        /// Nothing: the top of the Library has nowhere to go back to.
        case nothing
    }

    /// The outcome of a scrub on a Library screen. A search in progress is
    /// cleared first, wherever the screen is; only then does a folder go back.
    ///
    /// - Parameters:
    ///   - isSearching: Whether the search field holds text.
    ///   - isFolderScreen: Whether this screen is a folder's, not the top.
    static func libraryOutcome(isSearching: Bool, isFolderScreen: Bool) -> LibraryOutcome {
        if isSearching { return .clearSearch }
        return isFolderScreen ? .goBack : .nothing
    }
}
