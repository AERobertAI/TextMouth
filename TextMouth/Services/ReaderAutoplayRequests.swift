import Foundation

// MARK: - Autoplay Request

/// A finished book's request that the next book start playing as soon as
/// that book's reader is ready.
///
/// Continue to Next Book makes one when a book ends with another after it
/// in its folder, and a book read from the reading list makes one for the
/// book it continues to there (FR09). The next book's reader claims it
/// exactly once: when it finishes loading, or straight away when it was
/// already open and loaded. It waits in `ReaderAutoplayRequests`, a
/// `ReaderRequestStore`.
struct ReaderAutoplayRequest: ReaderRequest {
    /// The book that should start playing.
    let bookID: UUID
    /// The book that finished and continued to it.
    let previousBookID: UUID
    /// When the request was made.
    let createdAt: Date

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

/// The autoplay requests waiting for their books' readers: a store of the
/// one shape every reader request takes (`ReaderRequestStore`).
typealias ReaderAutoplayRequests = ReaderRequestStore<ReaderAutoplayRequest>

/// The store readers use unless they were created with their own, made on
/// the main actor at its first use.
@MainActor private let sharedAutoplayRequests = ReaderAutoplayRequests()

extension ReaderRequestStore where Request == ReaderAutoplayRequest {
    /// The store readers use unless they were created with their own.
    static var shared: ReaderAutoplayRequests {
        sharedAutoplayRequests
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
        add(ReaderAutoplayRequest(bookID: bookID, previousBookID: previousBookID, createdAt: currentDate))
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
