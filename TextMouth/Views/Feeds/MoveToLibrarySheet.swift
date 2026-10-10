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

    /// What moving does, under the heading.
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
    /// (`LibraryViewModel.moveToLibraryReturningOutcome(_:toFolder:)`).
    /// - Returns: What happened, for the sheet: after a success, what moving
    ///   did, as its message, which the sheet's owner says once the sheet
    ///   has closed, so the closing never cuts it off (REV11 F6); after a
    ///   failure, the reason, the sheet staying open.
    @MainActor
    func move(toFolder path: String, in library: LibraryViewModel) async -> OperationOutcome {
        let outcome = await library.moveToLibraryReturningOutcome(books, toFolder: path)
        guard outcome.succeeded else { return outcome }
        return .success(FeedWording.movedToLibrary(titles: books.map(\.title), noun: noun, folderPath: path))
    }
}

/// Shows Move to Library…'s sheet (FR11, branch D) while `request` names
/// what moves, over a Library window or a reader, and says what the move
/// did through `say` once the sheet has closed, so the closing never cuts
/// the words off (REV11 F6). A modifier of its own, shared by both owners,
/// so their long chains of modifiers stay within what the type checker
/// takes.
struct MoveToLibrarySheetPresentation: ViewModifier {
    /// What moves while the sheet shows; nil closes it.
    @Binding var request: MoveToLibraryRequest?
    /// The library the books move in.
    let library: LibraryViewModel
    /// Speaks what the move did, from the owner's window.
    let say: @MainActor (String) -> Void
    /// What the move did, kept while the sheet closes.
    @State private var afterMove = AnnouncementAfterSheet()

    func body(content: Content) -> some View {
        content.sheet(item: $request, onDismiss: sayWhatTheMoveDid) { request in
            MoveToLibrarySheet(request: request, library: library, onClose: close)
        }
    }

    /// Closes the sheet, keeping `sentence`, what the move did, nil after
    /// Cancel, to say once the sheet has closed.
    private func close(saying sentence: String?) {
        afterMove.keep(sentence)
        request = nil
    }

    /// Says what the move did, once the sheet has closed.
    private func sayWhatTheMoveDid() {
        afterMove.sheetDidClose(say: say)
    }
}

/// Move to Library…'s sheet (FR11, branch D): the folder picker Move to
/// Folder… uses (`MoveFolderSheet`), with New Folder… below it, headed with
/// what moves, and saying what moving does under its heading, once, its
/// Move button giving no hint that says it again (REV13 feeds 8): "Moves
/// this episode into a folder of your library, where it becomes a book you
/// can edit; it leaves the feed". Move moves the books and closes the
/// sheet, handing its owner what moving did, which the owner says once the
/// sheet has closed (REV11 F6); a failure keeps it open, saying why. A
/// Library window shows it for an item's row or its selection, and a
/// reader for its book.
struct MoveToLibrarySheet: View {
    /// What moves.
    let request: MoveToLibraryRequest
    /// The library the books move in.
    let library: LibraryViewModel
    /// Closes the sheet, with what to say once it has closed: what moving
    /// did after a move, or nil after Cancel.
    let onClose: (String?) -> Void

    var body: some View {
        MoveFolderSheet(
            books: request.books,
            library: library.library,
            lastMovedFolderPath: library.lastMovedFolderPath,
            onMove: { path in
                let outcome = await request.move(toFolder: path, in: library)
                if outcome.succeeded {
                    onClose(outcome.message)
                }
                return outcome
            },
            onCreateFolder: { name, parentPath in
                library.createFolderReturningOutcome(name: name, parentPath: parentPath)
            },
            onCancel: { onClose(nil) },
            heading: request.heading,
            explanation: request.hint
        )
    }
}
