import Foundation

/// What a screen of the iPhone app shows of the open book: `PhoneSession`
/// publishes it, and views read it instead of the reader.
///
/// A reader publishes eight times a second while it plays, as its place moves.
/// A view observing it would be rebuilt each time, which on a phone also
/// disturbs VoiceOver's cursor. So only what these fields hold reaches a view:
/// a new value is published only when one of them changes (`ReaderSnapshot`).
struct PhoneReaderSnapshot: Equatable, Sendable {
    /// The open book.
    let bookID: UUID
    /// The open book's title, which follows a rename.
    let title: String
    /// Whether the book plays, by the Mac's rule for its Play button: the
    /// reader shows Playing and not Paused, which a book waiting for its
    /// chapter's speech or files also does.
    let isPlaying: Bool
    /// Whether the book is still loading.
    let isLoading: Bool

    /// What `reader` shows now.
    @MainActor
    init(of reader: ReaderViewModel) {
        bookID = reader.book.id
        title = reader.book.title
        isPlaying = reader.isPlaybackActivelyAdvancing
        isLoading = reader.isLoading
    }
}
