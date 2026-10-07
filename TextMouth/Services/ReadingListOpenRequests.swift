import Combine
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
/// and the open brings it forward.
struct ReadingListOpenRequest: Equatable {
    /// The book to read from the reading list.
    let bookID: UUID
    /// When the request was made.
    let createdAt: Date

    /// Whether the request may still be claimed at `date`: no further than
    /// `ReadingListOpenRequests.lifetime` from when it was made. The limit
    /// holds in both directions, so a clock set back after the request
    /// cannot keep it usable any longer either.
    func isUsable(at date: Date) -> Bool {
        abs(date.timeIntervalSince(createdAt)) <= ReadingListOpenRequests.lifetime
    }
}

// MARK: - Request Store

/// The requests to read a book from the reading list that wait for the
/// books' readers (FR09), shaped like `ReaderAutoplayRequests`.
///
/// A book has at most one waiting request; a newer request replaces it.
/// Claiming a request removes it, so each marks one reader at most, however
/// many readers look for it. A request that has outlived `lifetime` is
/// thrown away rather than claimed, so a book whose window failed to open
/// is not read from the list when someone opens it much later from a
/// folder. Each request is told as it is made (`requestsMade`), so that a
/// reader already open for its book claims it at once.
@MainActor
final class ReadingListOpenRequests {
    /// The store readers and Library windows use unless a test gives a
    /// reader its own.
    static let shared = ReadingListOpenRequests()

    /// How long a request stays usable, in seconds: as long as an autoplay
    /// request, since a book continuing through the list leaves the next
    /// book both, and the window router keeps an open waiting as long.
    nonisolated static let lifetime: TimeInterval = ReaderAutoplayRequests.lifetime

    /// The waiting requests, keyed by the book each one is for.
    private var waiting: [UUID: ReadingListOpenRequest] = [:]

    /// The clock that dates and ages requests.
    private let now: () -> Date

    /// Tells, with the book's ID, of each request as it is made.
    private let made = PassthroughSubject<UUID, Never>()

    /// Create an empty store.
    ///
    /// - Parameter now: The current time: the system clock, unless a test
    ///   needs to control how old requests are.
    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    /// The book of each request as it is made, on the main actor, after the
    /// request waits: a reader already open for that book, whose window the
    /// open is bringing forward, claims it there and then.
    var requestsMade: AnyPublisher<UUID, Never> {
        made.eraseToAnyPublisher()
    }

    /// Ask that `bookID` be read from the reading list, replacing any
    /// request already waiting for that book, and tell `requestsMade`.
    ///
    /// - Returns: The request made. A reader already open for the book may
    ///   have claimed it by the time this returns.
    @discardableResult
    func request(for bookID: UUID) -> ReadingListOpenRequest {
        discardUnusableRequests()
        let request = ReadingListOpenRequest(bookID: bookID, createdAt: now())
        waiting[bookID] = request
        // Told last, once the request waits, so a reader told of it finds
        // it to claim.
        made.send(bookID)
        return request
    }

    /// Claim the request waiting for `bookID`, removing it so that nothing
    /// can claim it again.
    ///
    /// - Returns: The request, or nil when none is waiting for this book or
    ///   the one waiting is too old, in which case it is thrown away.
    func consume(for bookID: UUID) -> ReadingListOpenRequest? {
        discardUnusableRequests()
        return waiting.removeValue(forKey: bookID)
    }

    /// Whether a usable request is waiting for `bookID`. Unlike
    /// `consume(for:)`, this leaves the request waiting.
    func hasRequest(for bookID: UUID) -> Bool {
        waiting[bookID]?.isUsable(at: now()) ?? false
    }

    /// Throw away every request too old to use, so none can be claimed
    /// later and the store never holds more than the fresh ones.
    private func discardUnusableRequests() {
        let date = now()
        waiting = waiting.filter { $0.value.isUsable(at: date) }
    }
}

// MARK: - Opening a Book from a Library Window

extension ReadingListOpenRequests {
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
