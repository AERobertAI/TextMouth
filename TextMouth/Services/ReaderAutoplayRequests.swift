import Foundation

// MARK: - Autoplay Request

/// A finished book's request that the next book start playing as soon as
/// that book's reader is ready.
///
/// Continue to Next Book makes one when a book ends with another after it
/// in its folder. The next book's reader claims it exactly once: when it
/// finishes loading, or straight away when it was already open and loaded.
struct ReaderAutoplayRequest: Equatable {
    /// The book that should start playing.
    let bookID: UUID
    /// The book that finished and continued to it.
    let previousBookID: UUID
    /// When the request was made.
    let createdAt: Date

    /// Whether the request may still start playback at `date`: no further
    /// than `ReaderAutoplayRequests.lifetime` from when it was made. The
    /// limit holds in both directions, so a clock set back after the
    /// request cannot keep it usable any longer either.
    func isUsable(at date: Date) -> Bool {
        abs(date.timeIntervalSince(createdAt)) <= ReaderAutoplayRequests.lifetime
    }

    /// The `userInfo` of the `.continueToNextBook` notification that tells
    /// the app's windows and readers about this request.
    var notificationUserInfo: [AnyHashable: Any] {
        [
            Notification.ContinueToNextBookKey.bookID: bookID,
            Notification.ContinueToNextBookKey.previousBookID: previousBookID,
        ]
    }
}

// MARK: - Request Store

/// The autoplay requests waiting for their books' readers.
///
/// A book has at most one waiting request; a newer request replaces it.
/// Claiming a request removes it, so each request starts playback at most
/// once, however many readers and notifications look for it. A request that
/// has outlived `lifetime` is thrown away rather than claimed, so a book
/// whose window failed to open cannot start playing when someone opens it
/// much later.
@MainActor
final class ReaderAutoplayRequests {
    /// The store readers use unless they were created with their own.
    static let shared = ReaderAutoplayRequests()

    /// How long a request stays usable, in seconds. Opening the next book's
    /// window and loading the book normally takes well under a second; the
    /// margin covers a large book whose text must be extracted again.
    nonisolated static let lifetime: TimeInterval = 30

    /// The waiting requests, keyed by the book each one is for.
    private var waiting: [UUID: ReaderAutoplayRequest] = [:]

    /// The clock that dates and ages requests.
    private let now: () -> Date

    /// Create an empty store.
    ///
    /// - Parameter now: The current time: the system clock, unless a test
    ///   needs to control how old requests are.
    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    /// Ask that `bookID` start playing once its reader is ready, replacing
    /// any request already waiting for that book.
    ///
    /// - Parameters:
    ///   - bookID: The book to start.
    ///   - previousBookID: The book that finished and continued to it.
    /// - Returns: The request now waiting.
    @discardableResult
    func request(for bookID: UUID, from previousBookID: UUID) -> ReaderAutoplayRequest {
        discardUnusableRequests()
        let request = ReaderAutoplayRequest(
            bookID: bookID,
            previousBookID: previousBookID,
            createdAt: now()
        )
        waiting[bookID] = request
        return request
    }

    /// Claim the request waiting for `bookID`, removing it so that nothing
    /// can claim it again.
    ///
    /// - Returns: The request, or nil when none is waiting for this book or
    ///   the one waiting is too old, in which case it is thrown away.
    func consume(for bookID: UUID) -> ReaderAutoplayRequest? {
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

// MARK: - Continue to Next Book Notification

extension Notification {
    /// The keys of a `.continueToNextBook` notification's `userInfo`.
    enum ContinueToNextBookKey {
        /// The next book, which should open and start playing, as a `UUID`.
        static let bookID = "bookID"
        /// The book that finished, as a `UUID`.
        static let previousBookID = "previousBookID"
    }

    /// The book a `.continueToNextBook` notification asks to open and play,
    /// or nil when it names none.
    var nextBookID: UUID? {
        userInfo?[ContinueToNextBookKey.bookID] as? UUID
    }
}
