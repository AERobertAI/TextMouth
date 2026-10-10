import XCTest
@testable import TextMouth

/// Continue to Next Book leaves a request for the next book's reader. A
/// request starts only the book it names, is claimed at most once, and is
/// thrown away once it is too old to use, so it can never start a book
/// long after the finished one asked for it.
@MainActor
final class ReaderAutoplayRequestsTests: XCTestCase {
    /// The finished book in every test.
    private let finishedBook = UUID()
    /// The book it continues to.
    private let nextBook = UUID()
    /// A book unrelated to both.
    private let otherBook = UUID()

    // MARK: - Claiming

    /// A request is claimed once, and records both books and its time.
    func testRequestIsClaimedExactlyOnce() throws {
        let (store, clock) = makeStore()

        store.request(for: nextBook, from: finishedBook)
        let claimed = try XCTUnwrap(store.consume(for: nextBook))

        XCTAssertEqual(claimed.bookID, nextBook)
        XCTAssertEqual(claimed.previousBookID, finishedBook)
        XCTAssertEqual(claimed.createdAt, clock.now)
        XCTAssertNil(store.consume(for: nextBook))
        XCTAssertFalse(store.hasRequest(for: nextBook))
    }

    /// Asking whether a request is waiting leaves it waiting.
    func testCheckingForARequestDoesNotClaimIt() {
        let (store, _) = makeStore()
        store.request(for: nextBook, from: finishedBook)

        XCTAssertTrue(store.hasRequest(for: nextBook))
        XCTAssertTrue(store.hasRequest(for: nextBook))
        XCTAssertNotNil(store.consume(for: nextBook))
    }

    /// Another book's reader finds nothing, and the request stays waiting
    /// for the book it names.
    func testRequestIsNeverClaimedForAnotherBook() {
        let (store, _) = makeStore()
        store.request(for: nextBook, from: finishedBook)

        XCTAssertNil(store.consume(for: otherBook))
        XCTAssertFalse(store.hasRequest(for: otherBook))
        XCTAssertTrue(store.hasRequest(for: nextBook))
    }

    /// Claiming one book's request leaves another book's untouched.
    func testClaimingOneRequestLeavesAnotherBooksWaiting() {
        let (store, _) = makeStore()
        store.request(for: nextBook, from: finishedBook)
        store.request(for: otherBook, from: finishedBook)

        XCTAssertEqual(store.consume(for: nextBook)?.bookID, nextBook)

        XCTAssertTrue(store.hasRequest(for: otherBook))
        XCTAssertEqual(store.consume(for: otherBook)?.bookID, otherBook)
    }

    /// A newer request for the same book replaces the older one, so the
    /// book still starts only once.
    func testNewerRequestForTheSameBookReplacesTheOlder() throws {
        let (store, clock) = makeStore()
        store.request(for: nextBook, from: finishedBook)
        clock.advance(by: 5)

        store.request(for: nextBook, from: otherBook)
        let claimed = try XCTUnwrap(store.consume(for: nextBook))

        XCTAssertEqual(claimed.previousBookID, otherBook)
        XCTAssertEqual(claimed.createdAt, clock.now)
        XCTAssertNil(store.consume(for: nextBook))
    }

    // MARK: - Age

    /// The window a request stays usable for is thirty seconds.
    func testRequestsStayUsableForThirtySeconds() {
        XCTAssertEqual(ReaderAutoplayRequests.lifetime, 30)
    }

    /// A request is still usable at the very end of its lifetime.
    func testRequestIsUsableUntilItsLifetimeEnds() {
        let (store, clock) = makeStore()
        store.request(for: nextBook, from: finishedBook)

        clock.advance(by: ReaderAutoplayRequests.lifetime)

        XCTAssertTrue(store.hasRequest(for: nextBook))
        XCTAssertNotNil(store.consume(for: nextBook))
    }

    /// A request older than its lifetime is thrown away when a reader
    /// tries to claim it: it is gone even if the clock is set back.
    func testStaleRequestIsDiscardedWhenClaimed() {
        let (store, clock) = makeStore()
        store.request(for: nextBook, from: finishedBook)

        clock.advance(by: ReaderAutoplayRequests.lifetime + 1)
        XCTAssertFalse(store.hasRequest(for: nextBook))
        XCTAssertNil(store.consume(for: nextBook))

        clock.advance(by: -(ReaderAutoplayRequests.lifetime + 1))
        XCTAssertNil(store.consume(for: nextBook))
    }

    /// Making a request throws away other books' stale requests too, so
    /// none lingers to be claimed later.
    func testMakingARequestDiscardsOtherStaleRequests() {
        let (store, clock) = makeStore()
        store.request(for: otherBook, from: finishedBook)
        clock.advance(by: ReaderAutoplayRequests.lifetime + 1)

        store.request(for: nextBook, from: finishedBook)
        clock.advance(by: -(ReaderAutoplayRequests.lifetime + 1))

        XCTAssertFalse(store.hasRequest(for: otherBook))
        XCTAssertNil(store.consume(for: otherBook))
    }

    /// A clock set back further than a request's lifetime does not keep
    /// the request usable for longer.
    func testClockSetBackBeyondTheLifetimeMakesARequestUnusable() {
        let (store, clock) = makeStore()
        store.request(for: nextBook, from: finishedBook)

        clock.advance(by: -(ReaderAutoplayRequests.lifetime + 1))

        XCTAssertFalse(store.hasRequest(for: nextBook))
        XCTAssertNil(store.consume(for: nextBook))
    }

    // MARK: - Held While a Book Downloads (FR02)

    /// A request whose book's reader holds it, while the book downloads to
    /// open, stays usable however old it grows, and is claimed once.
    func testAHeldRequestWaitsHoweverOldItGrows() throws {
        let (store, clock) = makeStore()
        store.request(for: nextBook, from: finishedBook)
        store.hold(for: nextBook)

        clock.advance(by: ReaderAutoplayRequests.lifetime * 20)

        XCTAssertTrue(store.isHolding(nextBook))
        XCTAssertTrue(store.hasRequest(for: nextBook))
        XCTAssertEqual(try XCTUnwrap(store.consume(for: nextBook)).previousBookID, finishedBook)
        XCTAssertNil(store.consume(for: nextBook))
    }

    /// A request made for a book whose reader already holds its requests,
    /// as when a finished book continues to a book downloading in a window
    /// of its own, is held too.
    func testARequestMadeWhileHeldIsHeldToo() {
        let (store, clock) = makeStore()
        store.hold(for: nextBook)
        clock.advance(by: 5)

        store.request(for: nextBook, from: finishedBook)
        clock.advance(by: ReaderAutoplayRequests.lifetime * 4)

        XCTAssertTrue(store.hasRequest(for: nextBook))
    }

    /// Letting go of a hold makes the request age again from when it was
    /// made: one older than the lifetime lapses.
    func testReleasingLetsAHeldRequestAgeAgain() {
        let (store, clock) = makeStore()
        store.request(for: nextBook, from: finishedBook)
        store.hold(for: nextBook)
        clock.advance(by: ReaderAutoplayRequests.lifetime + 1)

        store.release(for: nextBook)

        XCTAssertFalse(store.isHolding(nextBook))
        XCTAssertFalse(store.hasRequest(for: nextBook))
        XCTAssertNil(store.consume(for: nextBook))
    }

    /// A hold keeps its own book's requests alone: another book's request
    /// ages as before, and is thrown away when the store is next used.
    func testAHoldKeepsOnlyItsOwnBooksRequests() {
        let (store, clock) = makeStore()
        store.request(for: nextBook, from: finishedBook)
        store.request(for: otherBook, from: finishedBook)
        store.hold(for: nextBook)

        clock.advance(by: ReaderAutoplayRequests.lifetime + 1)

        XCTAssertFalse(store.hasRequest(for: otherBook))
        XCTAssertNil(store.consume(for: otherBook))
        XCTAssertNotNil(store.consume(for: nextBook))
    }

    // MARK: - An Open Refused (FR02)

    /// An open a Library window refuses, while the library moves or is
    /// unavailable, drops the requests waiting for its book at once, of
    /// both kinds, however young; another book's requests stay, and an
    /// action that opens no book drops nothing.
    func testARefusedOpenDropsItsBooksRequestsAtOnce() {
        let (autoplay, _) = makeStore()
        let readingList = ReadingListOpenRequests()
        for book in [nextBook, otherBook] {
            autoplay.request(for: book, from: finishedBook)
            readingList.request(for: book)
        }

        ReaderOpenRefusal.dropRequests(for: .continueToNextBook(nextBook), autoplay: autoplay, readingList: readingList)

        XCTAssertFalse(autoplay.hasRequest(for: nextBook))
        XCTAssertFalse(readingList.hasRequest(for: nextBook))
        XCTAssertTrue(autoplay.hasRequest(for: otherBook))
        XCTAssertTrue(readingList.hasRequest(for: otherBook))

        ReaderOpenRefusal.dropRequests(for: .openBookWindow(otherBook), autoplay: autoplay, readingList: readingList)
        XCTAssertFalse(autoplay.hasRequest(for: otherBook))
        XCTAssertFalse(readingList.hasRequest(for: otherBook))

        autoplay.request(for: nextBook, from: finishedBook)
        for action in [GlobalAction.goToLibrary, .openBookFile, .newFromText, .importDAISYFolder, .openFiles([])] {
            ReaderOpenRefusal.dropRequests(for: action, autoplay: autoplay, readingList: readingList)
        }
        XCTAssertTrue(autoplay.hasRequest(for: nextBook), "an action that opens no book dropped a request")
    }

    /// Dropping a request leaves the hold of its book's reader as it was:
    /// the reader lets go of its own hold.
    func testDroppingARequestLeavesItsReadersHold() {
        let (store, _) = makeStore()
        store.request(for: nextBook, from: finishedBook)
        store.hold(for: nextBook)

        store.discard(for: nextBook)

        XCTAssertNil(store.consume(for: nextBook))
        XCTAssertTrue(store.isHolding(nextBook))
    }

    // MARK: - One Store for Both Kinds

    /// The autoplay requests and the reading list's are kept by one store
    /// shape (`ReaderRequestStore`), each kind in a store of its own: a
    /// request of one kind is never found as the other, both last as long,
    /// and each store tells of each request as it is made.
    func testOneStoreShapeServesBothKindsOfRequest() {
        let (autoplay, _) = makeStore()
        let readingList = ReadingListOpenRequests()
        XCTAssertEqual(ReaderAutoplayRequests.lifetime, ReadingListOpenRequests.lifetime)

        var told: [UUID] = []
        let subscription = autoplay.requestsMade.sink { told.append($0) }
        defer { subscription.cancel() }
        autoplay.request(for: nextBook, from: finishedBook)
        readingList.request(for: otherBook)

        XCTAssertEqual(told, [nextBook])
        XCTAssertTrue(autoplay.hasRequest(for: nextBook))
        XCTAssertFalse(readingList.hasRequest(for: nextBook))
        XCTAssertFalse(autoplay.hasRequest(for: otherBook))
        XCTAssertEqual(readingList.consume(for: otherBook)?.bookID, otherBook)
    }

    // MARK: - Notification

    /// The notification announcing a request names the next book where
    /// window receivers and readers read it, and the finished book.
    func testNotificationNamesTheNextAndFinishedBooks() {
        let (store, _) = makeStore()
        let request = store.request(for: nextBook, from: finishedBook)

        let notification = Notification(
            name: .continueToNextBook,
            object: nil,
            userInfo: request.notificationUserInfo
        )

        XCTAssertEqual(notification.nextBookID, nextBook)
        XCTAssertEqual(
            notification.userInfo?[Notification.ContinueToNextBookKey.previousBookID] as? UUID,
            finishedBook
        )
    }

    /// A notification that names no book, or names it with the wrong
    /// type, names no next book.
    func testNotificationWithoutABookNamesNoNextBook() {
        XCTAssertNil(Notification(name: .continueToNextBook).nextBookID)
        let wrongType = Notification(
            name: .continueToNextBook,
            object: nil,
            userInfo: [Notification.ContinueToNextBookKey.bookID: nextBook.uuidString]
        )
        XCTAssertNil(wrongType.nextBookID)
    }

    // MARK: - Fixture

    /// A clock the tests move by hand.
    private final class ManualClock {
        /// The time the clock reads now.
        var now = Date(timeIntervalSinceReferenceDate: 812_000_000)

        /// Move the clock by `seconds`, backwards when negative.
        func advance(by seconds: TimeInterval) {
            now = now.addingTimeInterval(seconds)
        }
    }

    /// An empty store whose requests are dated by a clock the test moves.
    private func makeStore() -> (ReaderAutoplayRequests, ManualClock) {
        let clock = ManualClock()
        return (ReaderAutoplayRequests(now: { clock.now }), clock)
    }
}
