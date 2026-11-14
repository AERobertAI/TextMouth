import Combine
import Foundation

/// Where readers are in their books between checkpoints (TODO PERF11), for
/// the library's rows and summary bar.
///
/// A playing reader reports its cursor about once a second, so the rows can
/// show the time left as it falls. Each report used to set the book's row in
/// the library itself, which copied every row, published the whole library
/// model, and so re-rendered every Library window's list and every reader
/// window's root once a second for as long as anything played. Live
/// positions now live here, by book ID, and only the views that show them
/// observe them: a book's row observes that book's entry (`entry(for:)`),
/// so the other rows never redraw, and the summary bar observes the store.
/// The library itself takes a reader's position only at its checkpoints
/// (every 30 seconds while playing, and at pause, stop, navigation, chapter
/// end, and close), as `LibraryViewModel.persistReadingPosition` writes it.
///
/// A live position is shown in place of the row's own only while it is the
/// newer (`ReadingPosition.lastUpdated`), so a checkpoint, or a position
/// another window saved, takes over at once; and the library model drops a
/// book's live position once no reader has the book open.
///
/// Main-actor isolated, like the views and the library model that use it.
@MainActor
final class LiveReadingPositions: ObservableObject {
    /// The store for views made without a library model, such as previews
    /// and tests: it never holds a position.
    static let inert = LiveReadingPositions()

    /// Each book's entry, by book ID, made when first asked for and kept,
    /// so a row and its book's reports always share one object.
    private var entries: [UUID: LiveReadingPosition] = [:]

    /// The books whose entries hold a live position now, kept beside the
    /// entries, of which there is one for every book a row has asked about
    /// and few hold a position: the summary bar adds up only these anew
    /// each time a reader moves (`TimeRemainingTally`).
    private(set) var liveBookIDs: Set<UUID> = []

    /// The entry of the book `bookID`, which its row observes: made the
    /// first time it is asked for and kept for the session, so asking twice
    /// gives the same object. Asking publishes nothing, so a view may ask
    /// while it draws.
    func entry(for bookID: UUID) -> LiveReadingPosition {
        if let entry = entries[bookID] {
            return entry
        }
        let entry = LiveReadingPosition()
        entries[bookID] = entry
        return entry
    }

    /// `book` with its reader's live position in place of its own while the
    /// live one is newer; otherwise `book` itself.
    func applied(to book: Book) -> Book {
        entries[book.id]?.applied(to: book) ?? book
    }

    /// The time left in `book` at `wpm`, from its reader's live position
    /// while that is newer than the library's: what
    /// `applied(to:).estimatedTimeRemaining(wpm:)` says, without copying the
    /// book for each of the many that have no live position.
    func estimatedTimeRemaining(of book: Book, wpm: Double) -> TimeInterval? {
        guard liveBookIDs.contains(book.id) else { return book.estimatedTimeRemaining(wpm: wpm) }
        return applied(to: book).estimatedTimeRemaining(wpm: wpm)
    }

    /// Records `position` as where a reader of `book` is now, unless the
    /// cursor has not moved from the position `book`'s row shows: then
    /// nothing is published. Otherwise the book's entry publishes, which
    /// redraws its row, and the store publishes, which redraws the summary
    /// bar. The inert store records nothing.
    /// - Parameters:
    ///   - position: Where the reader is now.
    ///   - book: The book as the library holds it.
    func update(_ position: ReadingPosition, of book: Book) {
        guard self !== Self.inert else { return }
        let shown = applied(to: book).readingPosition
        guard !position.hasSameCursor(as: shown) else { return }
        objectWillChange.send()
        entry(for: book.id).position = position
        liveBookIDs.insert(book.id)
    }

    /// Drops the live position of every book not in `bookIDs`, the books
    /// readers have open: a book's last reader saved its position to the
    /// library as it closed, so its row shows the library's position again.
    func keepOnly(_ bookIDs: Set<UUID>) {
        let closed = entries.filter { !bookIDs.contains($0.key) && $0.value.position != nil }
        guard !closed.isEmpty else { return }
        objectWillChange.send()
        for (bookID, entry) in closed {
            entry.position = nil
            liveBookIDs.remove(bookID)
        }
    }
}

/// One book's live position (TODO PERF11), which the book's row observes:
/// it publishes only when that book's reader reports a new cursor.
@MainActor
final class LiveReadingPosition: ObservableObject {
    /// The entry for rows made without a store, such as in previews and
    /// tests: it never holds a position.
    static let inert = LiveReadingPosition()

    /// Where the book's reader is, while a reader reports one; set only by
    /// `LiveReadingPositions`.
    @Published fileprivate(set) var position: ReadingPosition?

    /// `book` with this live position in place of its own while this one
    /// is the newer (`ReadingPosition.lastUpdated`); otherwise `book` itself.
    func applied(to book: Book) -> Book {
        guard let position,
              position.lastUpdated > (book.readingPosition?.lastUpdated ?? .distantPast) else {
            return book
        }
        var shown = book
        shown.readingPosition = position
        return shown
    }
}

private extension ReadingPosition {
    /// Whether `other` puts the cursor at the same place: the same chapter
    /// and offsets, whenever it was recorded.
    func hasSameCursor(as other: ReadingPosition?) -> Bool {
        guard let other else { return false }
        return chapterIndex == other.chapterIndex
            && characterOffset == other.characterOffset
            && globalCharacterOffset == other.globalCharacterOffset
    }
}
