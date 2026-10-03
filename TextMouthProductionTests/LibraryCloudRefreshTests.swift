import AppKit
import XCTest
@testable import TextMouth

/// How the library list keeps its books' cloud states current (FR02): when
/// a Library window appears, when the app becomes active, after every change
/// to where the library's books are, every minute while a Library window is
/// visible, and every 2 seconds while a book downloads. Each refresh reads
/// through the storage once, and refreshes never overlap.
@MainActor
final class LibraryCloudRefreshTests: XCTestCase {
    /// A download partway done.
    private let partway = BookDownloadProgress(completedFiles: 1, totalFiles: 4, completedBytes: 0, totalBytes: 0)

    // MARK: - Cadence

    /// While a Library window is visible and nothing downloads, the list
    /// refreshes every minute.
    func testCadenceWaitsAMinuteWhileAWindowIsVisible() {
        XCTAssertEqual(
            LibraryCloudRefreshCadence.interval(libraryWindowIsVisible: true, states: [.downloaded, .inCloud]),
            .seconds(60)
        )
        XCTAssertEqual(
            LibraryCloudRefreshCadence.interval(libraryWindowIsVisible: true, states: [BookCloudState]()),
            .seconds(60)
        )
    }

    /// While any book downloads, the list refreshes every 2 seconds.
    func testCadenceWaitsTwoSecondsWhileAnyBookDownloads() {
        XCTAssertEqual(
            LibraryCloudRefreshCadence.interval(
                libraryWindowIsVisible: true,
                states: [.downloaded, .downloading(partway), .inCloud]
            ),
            .seconds(2)
        )
    }

    /// With no Library window visible there is nothing to show, so no timed
    /// refresh happens, downloads or not.
    func testCadenceStopsWithoutAVisibleWindow() {
        XCTAssertNil(LibraryCloudRefreshCadence.interval(libraryWindowIsVisible: false, states: [BookCloudState.inCloud]))
        XCTAssertNil(
            LibraryCloudRefreshCadence.interval(libraryWindowIsVisible: false, states: [BookCloudState.downloading(partway)])
        )
    }

    // MARK: - Events

    /// A Library window appearing refreshes the location and every book.
    func testWindowAppearingRefreshesEveryBook() async {
        let books = [cloudTestBook("Moby-Dick"), cloudTestBook("Middlemarch", author: "George Eliot")]
        let fixture = RefreshFixture(books: books)
        defer { fixture.closeWindows() }
        fixture.storage.fake.setState(.inCloud, of: books[0].id)

        fixture.openWindow()
        await fixture.refresher.waitForRefreshes()

        XCTAssertEqual(fixture.states.libraryLocation, .cloud(.iCloudDrive))
        XCTAssertEqual(fixture.states.state(of: books[0].id), .inCloud)
        XCTAssertEqual(fixture.states.state(of: books[1].id), .downloaded)
        XCTAssertEqual(fixture.storage.refreshCount, 1)
        XCTAssertEqual(fixture.storage.mainThreadCalls, 0, "a refresh reads off the main thread")
    }

    /// Adding, moving, and removing a book each refresh once more, and the
    /// added book's state is recorded.
    func testEveryChangeToWhereBooksAreRefreshes() async {
        let book = cloudTestBook()
        let fixture = RefreshFixture(books: [book])
        defer { fixture.closeWindows() }
        fixture.openWindow()
        await fixture.refresher.waitForRefreshes()

        let added = cloudTestBook("Bleak House", author: "Charles Dickens")
        fixture.storage.fake.setState(.inCloud, of: added.id)
        fixture.model.library.books.append(added)
        await fixture.refresher.waitForRefreshes()
        XCTAssertEqual(fixture.storage.refreshCount, 2, "adding a book refreshes")
        XCTAssertEqual(fixture.states.state(of: added.id), .inCloud)

        fixture.model.library.books[0].folderPath = "Whaling"
        await fixture.refresher.waitForRefreshes()
        XCTAssertEqual(fixture.storage.refreshCount, 3, "moving a book refreshes")

        fixture.model.library.books.removeLast()
        await fixture.refresher.waitForRefreshes()
        XCTAssertEqual(fixture.storage.refreshCount, 4, "removing a book refreshes")
    }

    /// Changes that leave every package where it was, such as a reading
    /// position or a new title, start no refresh: they come often and change
    /// no cloud state.
    func testChangesThatMoveNoPackageDoNotRefresh() async {
        let fixture = RefreshFixture(books: [cloudTestBook()])
        defer { fixture.closeWindows() }
        fixture.openWindow()
        await fixture.refresher.waitForRefreshes()

        fixture.model.library.books[0].readingPosition = ReadingPosition(chapterIndex: 3, characterOffset: 12)
        fixture.model.library.books[0].title = "Moby-Dick; or, The Whale"
        await fixture.refresher.waitForRefreshes()

        XCTAssertEqual(fixture.storage.refreshCount, 1)
    }

    /// The app becoming active refreshes while a Library window is visible.
    func testAppBecomingActiveRefreshesWhileAWindowIsVisible() async {
        let fixture = RefreshFixture(books: [cloudTestBook()])
        defer { fixture.closeWindows() }
        fixture.openWindow()
        await fixture.refresher.waitForRefreshes()

        fixture.notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await drainMainQueue()
        await fixture.refresher.waitForRefreshes()

        XCTAssertEqual(fixture.storage.refreshCount, 2)
    }

    /// With every Library window closed, the app becoming active refreshes
    /// nothing: no list would show it.
    func testAppBecomingActiveWithoutAWindowDoesNotRefresh() async {
        let fixture = RefreshFixture(books: [cloudTestBook()])
        fixture.openWindow()
        await fixture.refresher.waitForRefreshes()
        fixture.closeWindows()

        fixture.notifications.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await drainMainQueue()
        await fixture.refresher.waitForRefreshes()

        XCTAssertEqual(fixture.storage.refreshCount, 1)
    }

    /// Requests made while a refresh runs start exactly one more refresh
    /// after it, never one beside it.
    func testRequestsDuringARefreshRunOnceMoreAfterIt() async {
        let fixture = RefreshFixture(books: [cloudTestBook()])
        defer { fixture.closeWindows() }
        let reading = expectation(description: "the first refresh is reading")
        fixture.storage.holdReads()
        fixture.storage.onRead { reading.fulfill() }

        fixture.openWindow()
        await fulfillment(of: [reading], timeout: 5)
        fixture.storage.onRead(nil)
        fixture.refresher.requestRefresh()
        fixture.refresher.requestRefresh()
        XCTAssertEqual(fixture.storage.refreshCount, 1, "nothing reads beside the held refresh")
        fixture.storage.releaseReads()
        await fixture.refresher.waitForRefreshes()

        XCTAssertEqual(fixture.storage.refreshCount, 2)
    }

    // MARK: - Timer

    /// The timer refreshes after each minute, and switches to 2 seconds as
    /// soon as a book is downloading.
    func testTimerRefreshesOnTheCadenceAndFollowsDownloads() async {
        let book = cloudTestBook()
        let fixture = RefreshFixture(books: [book])
        defer { fixture.closeWindows() }
        let sleeps = (1...3).map { expectation(description: "sleep \($0) starts") }
        fixture.sleep.onSleep { count in
            if count <= sleeps.count { sleeps[count - 1].fulfill() }
        }

        fixture.openWindow()
        await fixture.refresher.waitForRefreshes()
        await fulfillment(of: [sleeps[0]], timeout: 5)
        XCTAssertEqual(fixture.refresher.timerInterval, .seconds(60))
        XCTAssertEqual(fixture.storage.refreshCount, 1)

        // A minute passes: the timer refreshes, then waits another minute.
        fixture.sleep.wakeOldest()
        await fulfillment(of: [sleeps[1]], timeout: 5)
        await fixture.refresher.waitForRefreshes()
        XCTAssertEqual(fixture.storage.refreshCount, 2)

        // A download starts: the minute's wait ends, and a 2-second one begins.
        fixture.states.record(.downloading(partway), for: book.id)
        XCTAssertEqual(fixture.refresher.timerInterval, .seconds(2))
        await fulfillment(of: [sleeps[2]], timeout: 5)
        XCTAssertEqual(fixture.sleep.requestedWaits, [.seconds(60), .seconds(60), .seconds(2)])

        // The download ends: back to a minute.
        fixture.states.record(.downloaded, for: book.id)
        XCTAssertEqual(fixture.refresher.timerInterval, .seconds(60))
    }

    /// A second Library window refreshes when it appears, and the timer
    /// runs until the last visible window closes.
    func testTimerRunsUntilTheLastWindowCloses() async {
        let fixture = RefreshFixture(books: [cloudTestBook()])
        let first = UUID()
        let second = UUID()

        fixture.refresher.libraryWindowAppeared(first, showing: fixture.model)
        await fixture.refresher.waitForRefreshes()
        fixture.refresher.libraryWindowAppeared(second, showing: fixture.model)
        await fixture.refresher.waitForRefreshes()
        XCTAssertEqual(fixture.storage.refreshCount, 2, "each window appearing refreshes")

        fixture.refresher.libraryWindowDisappeared(first)
        XCTAssertEqual(fixture.refresher.timerInterval, .seconds(60), "a window is still visible")
        fixture.refresher.libraryWindowDisappeared(second)
        XCTAssertNil(fixture.refresher.timerInterval)
    }

    // MARK: - Enabling

    /// A refresher made disabled never refreshes and never starts its timer.
    func testDisabledRefresherNeverRefreshes() async {
        let storage = CountingBookCloudStorage(FakeBookCloudStorage(location: .cloud(.dropbox)))
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [cloudTestBook()])
        let refresher = LibraryCloudRefresher(states: BookCloudStates(), storage: { storage }, isEnabled: false)

        refresher.libraryWindowAppeared(UUID(), showing: model)
        refresher.requestRefresh()
        await refresher.waitForRefreshes()

        XCTAssertEqual(storage.refreshCount, 0)
        XCTAssertNil(refresher.timerInterval)
    }

    /// In a process hosting tests, the app's own refresher is disabled, so
    /// the hosted app's Library window never changes the shared store while
    /// a test uses it.
    func testTheAppsRefresherIsDisabledInAProcessHostingTests() {
        XCTAssertFalse(LibraryCloudRefresher.shared.isEnabled)
    }
}

/// A refresher of its own for one test: its own store, counting storage over
/// a cloud library in iCloud Drive, a stepped sleep, its own notification
/// center, and an inert library model holding `books`.
@MainActor
private final class RefreshFixture {
    let states: BookCloudStates
    let storage: CountingBookCloudStorage
    let sleep: SteppedSleep
    let notifications: NotificationCenter
    let model: LibraryViewModel
    let refresher: LibraryCloudRefresher
    /// The token of the one Library window the fixture opens.
    let window = UUID()

    init(books: [Book]) {
        let states = BookCloudStates()
        let storage = CountingBookCloudStorage(FakeBookCloudStorage(location: .cloud(.iCloudDrive)))
        let sleep = SteppedSleep()
        let notifications = NotificationCenter()
        self.states = states
        self.storage = storage
        self.sleep = sleep
        self.notifications = notifications
        model = LibraryViewModel(initializeServices: false)
        refresher = LibraryCloudRefresher(
            states: states,
            storage: { storage },
            sleep: { try await sleep.sleep($0) },
            notificationCenter: notifications
        )
        model.library = Library(books: books)
    }

    /// The fixture's Library window appears.
    func openWindow() {
        refresher.libraryWindowAppeared(window, showing: model)
    }

    /// The fixture's Library window disappears, which stops the timer.
    func closeWindows() {
        refresher.libraryWindowDisappeared(window)
    }
}
