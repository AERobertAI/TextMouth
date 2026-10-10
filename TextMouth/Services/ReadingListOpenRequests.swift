import Foundation

// MARK: - Reading List Open Request

/// A request that a book's reader read the book from the reading list
/// (FR09): made just before a Library window opens the book from the
/// Reading List, or by a book read from the list as it continues to the
/// next one there.
///
/// A reader window is identified by its book's ID alone, so the reading
/// list cannot ride on the window's value; the reader claims this request
/// instead, exactly once: as the reader is made, when the open makes a
/// window for the book, or at once, when the book's window is already open
/// and the open brings it forward (`ReaderRequestStore.requestsMade`). It
/// waits in `ReadingListOpenRequests`, a `ReaderRequestStore`.
struct ReadingListOpenRequest: ReaderRequest {
    /// The book to read from the reading list.
    let bookID: UUID
    /// When the request was made.
    let createdAt: Date
}

// MARK: - Request Store

/// The requests to read a book from the reading list that wait for the
/// books' readers (FR09): a store of the one shape every reader request
/// takes (`ReaderRequestStore`), as the autoplay requests' is. The two
/// stay apart, since a reader claims each at its own moment: this one as
/// the reader is made, an autoplay request once the book has loaded.
typealias ReadingListOpenRequests = ReaderRequestStore<ReadingListOpenRequest>

/// The store readers and Library windows use unless a test gives a reader
/// its own, made on the main actor at its first use.
@MainActor private let sharedReadingListOpenRequests = ReadingListOpenRequests()

extension ReaderRequestStore where Request == ReadingListOpenRequest {
    /// The store readers and Library windows use unless a test gives a
    /// reader its own.
    static var shared: ReadingListOpenRequests {
        sharedReadingListOpenRequests
    }

    /// Ask that `bookID` be read from the reading list, replacing any
    /// request already waiting for that book, and tell `requestsMade`.
    ///
    /// - Returns: The request made. A reader already open for the book may
    ///   have claimed it by the time this returns.
    @discardableResult
    func request(for bookID: UUID) -> ReadingListOpenRequest {
        add(ReadingListOpenRequest(bookID: bookID, createdAt: currentDate))
    }
}

// MARK: - Opening a Book from a Library Window

extension ReaderRequestStore where Request == ReadingListOpenRequest {
    /// Whether a Library window showing `category` opens its books to be
    /// read from the reading list: only at the Reading List, and not while
    /// the library moves, when the window refuses every open (FR02), so no
    /// request is left behind for a reader of the book to claim.
    nonisolated static func marksOpens(in category: LibraryCategory, libraryIsMoving: Bool) -> Bool {
        category == .readingList && !libraryIsMoving
    }

    /// Opens `book` with `open`, as a Library window showing `category`
    /// opens a book from its list: by the row's default action, its Open
    /// item, or Return on the selection. At the Reading List a request is
    /// made first, so the book's reader reads it from the list (FR09);
    /// anywhere else a book opens as it always has, even one in the list,
    /// as it does from Continue Listening, which opens the last book read
    /// rather than the list's.
    ///
    /// - Parameters:
    ///   - book: The book to open.
    ///   - category: The category the window shows.
    ///   - libraryIsMoving: Whether the library is moving, when the window
    ///     refuses the open (`marksOpens(in:libraryIsMoving:)`).
    ///   - open: Opens the book's reader window, or brings it forward.
    func open(_ book: Book, shownIn category: LibraryCategory, libraryIsMoving: Bool, with open: (Book) -> Void) {
        if Self.marksOpens(in: category, libraryIsMoving: libraryIsMoving) {
            request(for: book.id)
        }
        open(book)
    }
}
