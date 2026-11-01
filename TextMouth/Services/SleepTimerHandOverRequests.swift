import Foundation

// MARK: - A Sleep Timer Moving to the Next Book

/// A request that a book's reader take over the running sleep timer of the
/// reader that listening goes on from (0.2.5): made just before the next
/// book is shown, whether in the window of the reader moved from or in
/// another, by every way listening goes on: the end of a book, and Next and
/// Previous in the reading list and in the folder.
///
/// The timer is one shared service with one owner. The reader the book goes
/// on to claims this request once it has loaded, before anything plays, and
/// adopts the timer (`SleepTimerService.transferOwnership`): its owner and
/// callbacks change, its countdown does not. A reader already open for the
/// book claims it as it is made. The request names the reader the timer
/// moves from, so a reader never adopts a timer another reader has started
/// since.
///
/// A reader window is identified by its book's ID alone, so the wish cannot
/// ride on the window's value; it waits in `SleepTimerHandOverRequests`, a
/// `ReaderRequestStore`, as the autoplay and reading-list requests do.
struct SleepTimerHandOverRequest: ReaderRequest {
    /// The book whose reader claims the request: the one listening goes on to.
    let bookID: UUID
    /// When the request was made.
    let createdAt: Date
    /// The reader that owned the timer when the request was made.
    let previousOwnerID: UUID
}

/// The requests to take over a sleep timer that wait for the books' readers:
/// a store of the one shape every reader request takes (`ReaderRequestStore`).
typealias SleepTimerHandOverRequests = ReaderRequestStore<SleepTimerHandOverRequest>

/// The store readers use unless a test gives a reader its own, made on the
/// main actor at its first use.
@MainActor private let sharedSleepTimerHandOverRequests = SleepTimerHandOverRequests()

extension ReaderRequestStore where Request == SleepTimerHandOverRequest {
    /// The store readers use unless a test gives a reader its own.
    static var shared: SleepTimerHandOverRequests {
        sharedSleepTimerHandOverRequests
    }

    /// Ask that the reader of `bookID` take over the sleep timer that
    /// `previousOwnerID` owns, replacing any request already waiting for that
    /// book, and tell `requestsMade`.
    ///
    /// - Returns: The request made. A reader already open for the book may
    ///   have claimed it by the time this returns.
    @discardableResult
    func request(for bookID: UUID, from previousOwnerID: UUID) -> SleepTimerHandOverRequest {
        add(SleepTimerHandOverRequest(bookID: bookID, createdAt: currentDate, previousOwnerID: previousOwnerID))
    }
}
