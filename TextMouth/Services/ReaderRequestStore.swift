import Combine
import Foundation

// MARK: - A Request a Reader Claims

/// A request that waits for a book's reader to claim it: a finished book's
/// request that the next book start playing (`ReaderAutoplayRequest`), or a
/// request that a book be read from the reading list
/// (`ReadingListOpenRequest`, FR09).
///
/// A reader window is identified by its book's ID alone, so neither wish can
/// ride on the window's value; each waits in a store of its kind
/// (`ReaderRequestStore`), under the book's ID, for that book's reader.
protocol ReaderRequest: Equatable, Sendable {
    /// The book whose reader claims the request.
    var bookID: UUID { get }
    /// When the request was made.
    var createdAt: Date { get }
}

extension ReaderRequest {
    /// Whether the request may still be claimed at `date`: no further than
    /// `ReaderRequestStore.lifetime` from when it was made. The limit holds
    /// in both directions, so a clock set back after the request cannot
    /// keep it usable any longer either.
    func isUsable(at date: Date) -> Bool {
        abs(date.timeIntervalSince(createdAt)) <= ReaderRequestStore<Self>.lifetime
    }
}

// MARK: - The Store

/// The requests of one kind that wait for their books' readers: the
/// autoplay requests (`ReaderAutoplayRequests`) or the reading list's
/// (`ReadingListOpenRequests`), each kind in a store of its own, which this
/// one shape serves.
///
/// A book has at most one waiting request; a newer request replaces it.
/// Claiming a request removes it, so each is used at most once, however many
/// readers and notifications look for it. A request that has outlived
/// `lifetime` is thrown away rather than claimed, so a book whose window
/// failed to open does not act on it when someone opens the book much
/// later; but while a book's reader downloads the book from the cloud to
/// open it, which can take longer, the reader holds its requests
/// (`hold(for:)`), and they wait for as long as that takes (FR02). Each
/// request is told as it is made (`requestsMade`), so that a reader already
/// open for its book can claim it there and then.
@MainActor
final class ReaderRequestStore<Request: ReaderRequest> {
    /// How long a request stays usable, in seconds. Opening a book's window
    /// and loading the book normally takes well under a second; the margin
    /// covers a large book whose text must be extracted again. The window
    /// router keeps an open waiting for a Library window as long
    /// (`PendingGlobalActions.lifetime`), so a waiting open still finds its
    /// requests when its reader opens.
    nonisolated static var lifetime: TimeInterval { 30 }

    /// The waiting requests, keyed by the book each one is for.
    private var waiting: [UUID: Request] = [:]

    /// The books whose readers hold their requests while the books download
    /// to open (`hold(for:)`): their requests never grow too old to use.
    private var held: Set<UUID> = []

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

    /// The current time by the store's clock, which dates the requests made
    /// for it.
    var currentDate: Date {
        now()
    }

    /// The book of each request as it is made, on the main actor, after the
    /// request waits: a reader already open for that book, whose window the
    /// open is bringing forward, can claim it there and then.
    var requestsMade: AnyPublisher<UUID, Never> {
        made.eraseToAnyPublisher()
    }

    /// Makes `request` wait for its book's reader, replacing any request
    /// already waiting for that book, and tells `requestsMade`.
    ///
    /// - Returns: The request made. A reader already open for the book may
    ///   have claimed it by the time this returns.
    @discardableResult
    func add(_ request: Request) -> Request {
        discardUnusableRequests()
        waiting[request.bookID] = request
        // Told last, once the request waits, so a reader told of it finds it
        // to claim.
        made.send(request.bookID)
        return request
    }

    /// Claim the request waiting for `bookID`, removing it so that nothing
    /// can claim it again.
    ///
    /// - Returns: The request, or nil when none is waiting for this book or
    ///   the one waiting is too old, in which case it is thrown away.
    func consume(for bookID: UUID) -> Request? {
        discardUnusableRequests()
        return waiting.removeValue(forKey: bookID)
    }

    /// The usable request waiting for `bookID`, read without claiming it:
    /// unlike `consume(for:)`, this leaves it waiting.
    func waitingRequest(for bookID: UUID) -> Request? {
        waiting[bookID].flatMap { isUsable($0, at: now()) ? $0 : nil }
    }

    /// Whether a usable request is waiting for `bookID`: the one meaning of
    /// "the request still waits", which a hand-over and a move asked for both
    /// use to tell that their book has not started. Unlike `consume(for:)`,
    /// this leaves the request waiting.
    ///
    /// - Parameter madeAt: When the request in question was made, when a caller
    ///   means one request and no other for the same book: a request made
    ///   later, by another move, is not it.
    func hasRequest(for bookID: UUID, madeAt: Date? = nil) -> Bool {
        guard let request = waitingRequest(for: bookID) else { return false }
        return madeAt.map { request.createdAt == $0 } ?? true
    }

    /// Throws away the request waiting for `bookID`, if any, whatever its
    /// age, so no reader of the book claims it: the open it was made for was
    /// refused (`ReaderOpenRefusal`, FR02).
    func discard(for bookID: UUID) {
        waiting.removeValue(forKey: bookID)
    }

    // MARK: Holding Requests While a Book Downloads (FR02)

    /// Keeps every request for `bookID`, the one waiting and any made later,
    /// usable however old it grows, until `release(for:)`: the book's reader
    /// is downloading the book from the cloud before it can load it, which
    /// can take longer than `lifetime`, and the request is still wanted. A
    /// finished book's request that the book start playing is so kept, and
    /// claimed once the book has downloaded and loaded.
    func hold(for bookID: UUID) {
        held.insert(bookID)
    }

    /// Ends the hold `hold(for:)` began: the book's requests age again from
    /// when they were made, so one older than `lifetime` lapses. The reader
    /// lets go once its book has loaded, or once its download failed, was
    /// cancelled, or its window closed.
    func release(for bookID: UUID) {
        held.remove(bookID)
    }

    /// Whether the book `bookID`'s requests are held (`hold(for:)`).
    func isHolding(_ bookID: UUID) -> Bool {
        held.contains(bookID)
    }

    // MARK: Ageing

    /// Whether `request` may still be claimed at `date`: while its book's
    /// reader holds it, whatever its age, and otherwise within `lifetime`.
    private func isUsable(_ request: Request, at date: Date) -> Bool {
        held.contains(request.bookID) || request.isUsable(at: date)
    }

    /// Throw away every request too old to use, so none can be claimed
    /// later and the store never holds more than the fresh ones.
    private func discardUnusableRequests() {
        let date = now()
        waiting = waiting.filter { isUsable($0.value, at: date) }
    }
}

// MARK: - An Open Refused (FR02)

/// What becomes of the requests waiting for a book's reader when the open
/// that would make the reader is refused: a Library window refuses every
/// open of a book while the library moves, and while the data directory is
/// unavailable (FR02), saying so. The requests are dropped there and then,
/// rather than waiting out their lifetime for a reader the refused open
/// never makes, ready to start the book or mark it as read from the reading
/// list should it be opened some other way meanwhile.
enum ReaderOpenRefusal {
    /// Drops the autoplay request and the reading list's request waiting
    /// for the book `action` opens (`GlobalAction.bookToOpen`), and releases
    /// a sleep timer held for it (0.2.5), in whichever window it is held: the
    /// book will not open, so the timer would count toward pausing nothing.
    /// Search Library's request to move to a match in the book goes too, so
    /// opening the book some other way within the request's lifetime never
    /// jumps to an old match (the review of Search Library, November 13,
    /// finding 9). An action that opens no book drops nothing.
    ///
    /// - Parameters:
    ///   - action: The app-wide action refused.
    ///   - autoplay: The autoplay requests: the app's, unless a test gives
    ///     its own.
    ///   - readingList: The reading list's requests: the app's, unless a
    ///     test gives its own.
    ///   - sleepTimers: The registry of every window's sleep timer: the
    ///     app's, unless a test gives its own.
    ///   - librarySearch: Search Library's requests to move to a match: the
    ///     app's, unless a test gives its own.
    @MainActor
    static func dropRequests(
        for action: GlobalAction,
        autoplay: ReaderAutoplayRequests = .shared,
        readingList: ReadingListOpenRequests = .shared,
        sleepTimers: SleepTimerRegistry = .shared,
        librarySearch: LibrarySearchJumpRequests = .shared
    ) {
        guard let bookID = action.bookToOpen else { return }
        autoplay.discard(for: bookID)
        readingList.discard(for: bookID)
        librarySearch.discard(for: bookID)
        sleepTimers.releaseHeld(forBook: bookID, reason: "the Library refused the open")
    }
}
