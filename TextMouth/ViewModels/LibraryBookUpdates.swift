import Combine
import Foundation

/// What the library tells the readers that have one book open (TODO P10).
enum LibraryBookEvent {
    /// The book's package is about to move on disk. Its readers stop
    /// reading the book's files until `packageMoveEnded` arrives.
    case packageWillMove(bookID: UUID)
    /// The library changed something its readers show or use of the book.
    case updated(LibraryBookUpdate)
    /// The move announced by `packageWillMove` is over, whether the package
    /// moved or was put back. Any update the move made arrived before this.
    case packageMoveEnded(bookID: UUID)
    /// The book's text was replaced by an edit the user made in their own
    /// editor (FR05): readers show `content`, the edited text, parsed and
    /// indexed, near where they were reading. The row's new analysis
    /// arrived before this, as an update. `movedPlaces` holds the moves of
    /// the book's saved places that the edit took (T06): the readers' own
    /// copies of those places follow, where each still holds the place as it
    /// was; nil when the edit moved none.
    case textReplaced(bookID: UUID, content: DocumentContent, movedPlaces: MovedPlaces?)
    /// An audiobook's transcript text changed (FR05): it was transcribed,
    /// transcribed again, or its transcript deleted, which leaves `text`
    /// nil. Readers show the text as the book plays on, its audio and
    /// position untouched.
    case transcriptReplaced(bookID: UUID, text: TranscriptText?)
    /// An audiobook of tracks was rearranged by an edit of its manifest the
    /// user made in their own editor (FR17), already committed to its
    /// record: readers show the new headings, with their cursors on the
    /// same tracks at the same times, and a playing reader plays on. The
    /// row's new analysis and the moves of its places arrived before this,
    /// as an update.
    case tracksRearranged(bookID: UUID, edit: BookManifestEdit)

    /// The book the event is about.
    var bookID: UUID {
        switch self {
        case .packageWillMove(let bookID), .packageMoveEnded(let bookID), .textReplaced(let bookID, _, _),
             .transcriptReplaced(let bookID, _), .tracksRearranged(let bookID, _):
            return bookID
        case .updated(let update):
            return update.book.id
        }
    }
}

/// One change the library made to a book, as the book's readers receive it.
struct LibraryBookUpdate {
    /// The book as the library holds it after the change. Readers take its
    /// library fields (`Book.LibraryFields`) and keep their own state.
    let book: Book
    /// The book's update revision: one more than its previous update's, so a
    /// reader can tell an update it has not applied yet from one it has.
    /// Revisions start at 1 and rise for as long as the app runs.
    let revision: Int
}

/// Publishes the library's changes to the books open in readers (TODO P10).
///
/// A reader takes its own copy of its book when it opens, and the library
/// changes its rows in place: a metadata edit, a move to another folder, a
/// rename or move of a folder above the book, a data directory move, and
/// the repairs Storage settings run. So a reader watches its book here
/// while it is open, and the library offers every change of its library
/// (`libraryDidChange(_:)`). Whenever a watched book's library fields
/// (`Book.LibraryFields`) differ from those its readers were last given,
/// they receive the book's row with the next revision. Nothing else about a
/// row (a reading position, a bookmark, a setting the reader itself wrote)
/// is published, so the reader's own changes never come back to it.
///
/// Changes that move a book's package on disk are bracketed as well
/// (`packagesWillMove(_:)` and `packagesDidMove(_:)`), so a reader playing
/// the book's audio can stop reading its files before they move and play on
/// from the same place once they have.
///
/// Every event is delivered synchronously on the main actor, while the
/// change that caused it is being made.
@MainActor
final class LibraryBookUpdates {

    /// One book open in readers.
    private struct Watch {
        /// How many readers have the book open.
        var readerCount: Int
        /// The book's library fields as its readers were last given them,
        /// or as the first of them opened it.
        var published: Book.LibraryFields
    }

    /// Where every event is sent; each reader hears only its own book's.
    private let events = PassthroughSubject<LibraryBookEvent, Never>()
    /// The books open in readers, by ID.
    private var watches: [UUID: Watch] = [:]
    /// The latest update revision of every book ever updated, by ID. Kept
    /// after a book's readers close, so its revisions keep rising.
    private var revisions: [UUID: Int] = [:]
    /// How many package-move brackets are open for each book. Brackets
    /// nest: a book hears `packageWillMove` when its first one opens and
    /// `packageMoveEnded` when its last one closes.
    private var openMoveBrackets: [UUID: Int] = [:]
    /// True while updates are being sent. A reader applying one can change
    /// the library again (by saving its position, say); that change is
    /// published after the updates under way, never in the middle of them.
    private var isPublishing = false
    /// The newest library offered while updates were being sent.
    private var libraryOfferedWhilePublishing: Library?

    // MARK: - Readers

    /// The events for the book `bookID`, as the readers that have it open
    /// subscribe to them. Delivery is synchronous on the main actor.
    func events(for bookID: UUID) -> AnyPublisher<LibraryBookEvent, Never> {
        events.filter { $0.bookID == bookID }.eraseToAnyPublisher()
    }

    /// The latest update revision of the book `bookID`: 0 when it has never
    /// been updated. A reader that opens the book applies only later ones.
    func revision(of bookID: UUID) -> Int {
        revisions[bookID] ?? 0
    }

    /// Notes that a reader opened `book`, as the reader holds it. Its first
    /// reader's copy is what later library changes are compared with.
    func watch(_ book: Book) {
        if var watch = watches[book.id] {
            watch.readerCount += 1
            watches[book.id] = watch
        } else {
            watches[book.id] = Watch(readerCount: 1, published: book.libraryFields)
        }
    }

    /// Notes that a reader of the book `bookID` closed. Once its last reader
    /// has closed, the book's changes are no longer published.
    func unwatch(_ bookID: UUID) {
        guard var watch = watches[bookID] else { return }
        watch.readerCount -= 1
        watches[bookID] = watch.readerCount > 0 ? watch : nil
    }

    /// The IDs of the books open in readers.
    var watchedBookIDs: Set<UUID> {
        Set(watches.keys)
    }

    // MARK: - Library Changes

    /// Publishes, with its next revision, the row of every watched book
    /// whose library fields `library` changes. The library model calls this
    /// after every change of its library, with the library as it now is.
    func libraryDidChange(_ library: Library) {
        guard !watches.isEmpty else { return }
        guard !isPublishing else {
            // Published once the updates under way have been sent.
            libraryOfferedWhilePublishing = library
            return
        }
        isPublishing = true
        defer { isPublishing = false }
        var next: Library? = library
        while let current = next {
            libraryOfferedWhilePublishing = nil
            publishChanges(in: current)
            next = libraryOfferedWhilePublishing
        }
    }

    /// Sends an update for each watched book whose row in `library` has
    /// library fields its readers were not given yet. Each book's watch and
    /// revision are settled before its update is sent, so a reader can never
    /// be sent the same change twice.
    private func publishChanges(in library: Library) {
        for bookID in Array(watches.keys) {
            guard let published = watches[bookID]?.published,
                  let row = library.books.first(where: { $0.id == bookID }) else { continue }
            let fields = row.libraryFields
            guard fields != published else { continue }
            watches[bookID]?.published = fields
            let revision = self.revision(of: bookID) + 1
            revisions[bookID] = revision
            events.send(.updated(LibraryBookUpdate(book: row, revision: revision)))
        }
    }

    // MARK: - Edited Text

    /// Tells the readers of the book `bookID`, when it is watched, that its
    /// text is now `content`, an edit the user made in their own editor
    /// (FR05). Call it after the library holds the book's new analysis, so
    /// the readers' copies of the book agree with the text they show.
    /// `movedPlaces` is what the edit moved of the book's saved places (nil
    /// for none), which the readers' own copies take too.
    func textReplaced(bookID: UUID, with content: DocumentContent, movedPlaces: MovedPlaces?) {
        guard watches[bookID] != nil else { return }
        events.send(.textReplaced(bookID: bookID, content: content, movedPlaces: movedPlaces))
    }

    /// Tells the readers of the audiobook `bookID`, when it is watched, that
    /// its transcript text is now `text`, or that it has none (FR05). Call
    /// it once the transcript is saved, or deleted, in the book's package.
    func transcriptReplaced(bookID: UUID, with text: TranscriptText?) {
        guard watches[bookID] != nil else { return }
        events.send(.transcriptReplaced(bookID: bookID, text: text))
    }

    /// Tells the readers of the audiobook `bookID`, when it is watched, that
    /// an edit of its manifest rearranged it (FR17). Call it after the
    /// library holds the book's new analysis.
    func tracksRearranged(bookID: UUID, by edit: BookManifestEdit) {
        guard watches[bookID] != nil else { return }
        events.send(.tracksRearranged(bookID: bookID, edit: edit))
    }

    // MARK: - Package Moves

    /// Tells the readers of each watched book in `bookIDs` that its package
    /// is about to move on disk. Each call is closed by a call of
    /// `packagesDidMove(_:)` with the same books once the move is over,
    /// whether it succeeded or was put back.
    func packagesWillMove(_ bookIDs: some Sequence<UUID>) {
        for bookID in Set(bookIDs) where watches[bookID] != nil {
            let open = openMoveBrackets[bookID] ?? 0
            openMoveBrackets[bookID] = open + 1
            if open == 0 {
                events.send(.packageWillMove(bookID: bookID))
            }
        }
    }

    /// Tells the readers of each book in `bookIDs` that the move announced
    /// by `packagesWillMove(_:)` is over. Call it after the library holds
    /// the books' new rows, so their readers carry on from the new places.
    func packagesDidMove(_ bookIDs: some Sequence<UUID>) {
        for bookID in Set(bookIDs) {
            guard let open = openMoveBrackets[bookID] else { continue }
            if open > 1 {
                openMoveBrackets[bookID] = open - 1
            } else {
                openMoveBrackets[bookID] = nil
                events.send(.packageMoveEnded(bookID: bookID))
            }
        }
    }
}
