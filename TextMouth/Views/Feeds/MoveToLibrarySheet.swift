import SwiftUI

// MARK: - Move to Library… (FR11, Branch D)

/// What Move to Library… moves while its sheet shows (FR11, branch D):
/// episodes and articles downloaded in their feeds, from an item's row, a
/// Library window's selection, or a reader's book.
struct MoveToLibraryRequest: Identifiable, Equatable {
    /// Tells two requests apart, so a second one opens its sheet anew.
    let id = UUID()
    /// The feed items' downloads that move, as the library held them.
    let books: [Book]

    /// What the books are called together.
    var noun: FeedWording.ItemNoun {
        FeedWording.noun(of: books)
    }

    /// The sheet's heading: "Move “Ep. 368” to Library".
    var heading: String {
        FeedWording.moveToLibraryHeading(titles: books.map(\.title), noun: noun)
    }

    /// What moving does, under the heading and as the Move button's hint.
    var hint: String {
        FeedWording.moveToLibraryHint(count: books.count, noun: noun)
    }

    /// The request to move those of `books` that Move to Library… can move
    /// in `library` (`LibraryViewModel.booksMovableToLibrary(_:)`): episodes
    /// and articles downloaded in their feeds; nil when none of them is one,
    /// when the caller says why (`FeedWording.nothingToMoveToLibrary`).
    @MainActor
    static func forBooks(_ books: [Book], in library: LibraryViewModel) -> MoveToLibraryRequest? {
        let movable = library.booksMovableToLibrary(books)
        return movable.isEmpty ? nil : MoveToLibraryRequest(books: movable)
    }

    /// Moves the books into the library folder at `path` through `library`
    /// (`LibraryViewModel.moveToLibraryReturningOutcome(_:toFolder:)`), and,
    /// once they have moved, says so through `announce`.
    /// - Returns: What happened, for the sheet: it closes after a success,
    ///   and stays open with the reason after a failure.
    @MainActor
    func move(toFolder path: String, in library: LibraryViewModel, announce: (String) -> Void) async -> OperationOutcome {
        let outcome = await library.moveToLibraryReturningOutcome(books, toFolder: path)
        if outcome.succeeded {
            announce(FeedWording.movedToLibrary(titles: books.map(\.title), noun: noun, folderPath: path))
        }
        return outcome
    }
}

/// Move to Library…'s sheet (FR11, branch D): the folder picker Move to
/// Folder… uses (`MoveFolderSheet`), with New Folder… below it, headed with
/// what moves, and saying what moving does under its heading and as its
/// Move button's hint: "Moves this episode into a folder of your library,
/// where it becomes a book you can edit; it leaves the feed". Move moves the
/// books, says so, and closes the sheet; a failure keeps it open, saying
/// why. A Library window shows it for an item's row or its selection, and a
/// reader for its book.
struct MoveToLibrarySheet: View {
    /// What moves.
    let request: MoveToLibraryRequest
    /// The library the books move in.
    let library: LibraryViewModel
    /// Speaks what moving did, from the window the sheet is over.
    let announce: @MainActor (String) -> Void
    /// Closes the sheet: after a move, or Cancel.
    let onClose: () -> Void

    var body: some View {
        MoveFolderSheet(
            books: request.books,
            library: library.library,
            lastMovedFolderPath: library.lastMovedFolderPath,
            onMove: { path in
                let outcome = await request.move(toFolder: path, in: library, announce: announce)
                if outcome.succeeded {
                    onClose()
                }
                return outcome
            },
            onCreateFolder: { name, parentPath in
                library.createFolderReturningOutcome(name: name, parentPath: parentPath)
            },
            onCancel: onClose,
            heading: request.heading,
            explanation: request.hint
        )
    }
}
