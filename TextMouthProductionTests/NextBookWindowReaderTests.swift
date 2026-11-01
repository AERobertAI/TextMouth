import Combine
import XCTest
@testable import TextMouth

/// A reader going on to the next book shows it in its own window or opens a
/// new one, as the setting says (0.2.5). The window's switch is injected, so
/// no window opens and nothing plays: the readers are of silent audiobooks,
/// ended by `handleEndOfBook()` or moved by the reading list's commands.
@MainActor
final class NextBookWindowReaderTests: XCTestCase {
    /// Subscriptions a test keeps until it ends.
    private var subscriptions = Set<AnyCancellable>()

    // MARK: - The End of a Book

    /// With This Window, going on to the next book calls the switcher once,
    /// after the request to play it is made, and posts neither the
    /// notification that opens a window nor the one that brings it forward.
    func testTheEndOfABookSwitchesThisWindowAfterTheRequests() throws {
        let folder = try makeFolderWorld("EndSwitch")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let asked = record(.continueToNextBook, in: folder.world)
        let opened = record(.openBookWindow, in: folder.world)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)

        let recorder = recordingAnnouncements {
            reader.handleEndOfBook()
            XCTAssertTrue(switcher.shown.isEmpty, "Switched before the announcement had a moment")
            XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "Never switched")
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: B Volume"])
        XCTAssertEqual(switcher.shown, [folder.second.id])
        XCTAssertEqual(switcher.requestWaitingAtTheSwitch, [true], "The request came after the switch")
        XCTAssertTrue(asked().isEmpty, "Opened a window as well")
        XCTAssertTrue(opened().isEmpty, "Opened a window as well")
        XCTAssertTrue(reader.hasSwitchedWindow)
    }

    /// With A New Window, going on posts as before 0.2.5, and never calls
    /// the switcher.
    func testANewWindowPostsAsBefore() throws {
        let folder = try makeFolderWorld("EndNewWindow")
        folder.world.settings.nextBookWindow = .newWindow
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let asked = record(.continueToNextBook, in: folder.world)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)

        reader.handleEndOfBook()
        XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")

        XCTAssertEqual(asked().map(\.nextBookID), [folder.second.id])
        XCTAssertTrue(switcher.shown.isEmpty)
        XCTAssertFalse(reader.hasSwitchedWindow)
    }

    /// A feed's or folder's own choice wins over the global one, either way,
    /// while its books go on.
    func testTheFoldersOwnChoiceWinsOverTheGlobalSetting() throws {
        for (own, global, switches) in [
            (NextBookWindow.newWindow, NextBookWindow.thisWindow, false),
            (NextBookWindow.thisWindow, NextBookWindow.newWindow, true),
        ] {
            let folder = try makeFolderWorld("EndOwn \(own.rawValue)", options: ListeningOptions(
                continuation: .playBookBelow, nextBookWindow: own
            ))
            folder.world.settings.nextBookWindow = global
            let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
            let asked = record(.continueToNextBook, in: folder.world)
            let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)

            reader.handleEndOfBook()
            XCTAssertTrue(eventually { !asked().isEmpty || !switcher.shown.isEmpty }, "Never went on: \(own)")

            XCTAssertEqual(!switcher.shown.isEmpty, switches, "own \(own.rawValue), global \(global.rawValue)")
            XCTAssertEqual(!asked().isEmpty, !switches, "own \(own.rawValue), global \(global.rawValue)")
        }
    }

    /// A reader that has no window on screen, as one whose window closed,
    /// opens a new window as before, and calls no switcher.
    func testAReaderWithNoWindowOnScreenOpensANewWindow() throws {
        let folder = try makeFolderWorld("EndOffScreen")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let asked = record(.continueToNextBook, in: folder.world)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        reader.hostWindowIsOnScreenOverride = false

        reader.handleEndOfBook()
        XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")

        XCTAssertEqual(asked().map(\.nextBookID), [folder.second.id])
        XCTAssertTrue(switcher.shown.isEmpty)
    }

    /// The listener closes the window in the half second between "Starting"
    /// and the request: the hand-over goes on as announced, in a new window,
    /// and the closed reader calls no switcher.
    func testAHandOverAfterTheReaderClosedPostsAsBefore() throws {
        let folder = try makeFolderWorld("EndClosed")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let asked = record(.continueToNextBook, in: folder.world)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)

        reader.handleEndOfBook()
        reader.close()
        XCTAssertTrue(reader.switchingTheWindowCouldLoseWork)
        XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")

        XCTAssertEqual(asked().map(\.nextBookID), [folder.second.id])
        XCTAssertTrue(switcher.shown.isEmpty, "A closed reader switched a window that is gone")
        XCTAssertFalse(reader.hasSwitchedWindow)
    }

    /// A reader reaching a book already open in another window brings that
    /// window forward, as before, and does not switch this one.
    func testABookAlreadyOpenElsewhereIsBroughtForward() throws {
        let folder = try makeFolderWorld("EndAlreadyOpen")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let asked = record(.continueToNextBook, in: folder.world)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        _ = folder.world.openReader(for: folder.second)
        XCTAssertTrue(folder.world.library.openBookIDs.contains(folder.second.id))

        reader.handleEndOfBook()
        XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")

        XCTAssertEqual(asked().map(\.nextBookID), [folder.second.id])
        XCTAssertTrue(switcher.shown.isEmpty, "Replaced a book that is open in another window")
    }

    /// A reader with no switcher, as in any test of the old behavior, opens
    /// a new window whatever the setting says.
    func testAReaderWithNoSwitcherOpensANewWindow() throws {
        let folder = try makeFolderWorld("EndNoSwitcher")
        let asked = record(.continueToNextBook, in: folder.world)
        let reader = folder.world.openReader(for: folder.first)
        waitForReaderToLoad(reader)

        reader.handleEndOfBook()
        XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")
        XCTAssertEqual(asked().map(\.nextBookID), [folder.second.id])
    }

    // MARK: - The Reading List

    /// Next in Reading List, from a book not playing, follows the global
    /// setting even in a folder with a choice of its own: with This Window it
    /// switches, after the reading-list request, and posts nothing.
    func testNextInReadingListFollowsTheGlobalSetting() throws {
        let folder = try makeFolderWorld("ListSwitch", options: ListeningOptions(
            continuation: .playBookBelow, nextBookWindow: .newWindow
        ))
        let world = folder.world
        world.library.library.readingList = ReadingList(
            bookIDs: [folder.first.id, folder.second.id], continuation: .playBookBelow, skipsFinished: true
        )
        let requests = ReadingListOpenRequests()
        requests.request(for: folder.first.id)
        let switcher = SwitchRecorder(requests: world.autoplayRequests, readingListRequests: requests)
        let opened = record(.openBookWindow, in: world)
        let reader = makeReader(for: folder.first, in: world, switcher: switcher, readingListRequests: requests)
        XCTAssertTrue(reader.isOpenedFromReadingList)

        let recorder = recordingAnnouncements {
            reader.goThroughReadingList(.down)
            XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "Never switched")
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Opening: B Volume"])
        XCTAssertEqual(switcher.shown, [folder.second.id])
        XCTAssertEqual(switcher.readingListRequestWaitingAtTheSwitch, [true], "The request came after the switch")
        XCTAssertTrue(opened().isEmpty)
    }

    /// With A New Window, Next in Reading List posts as before.
    func testNextInReadingListWithANewWindowPostsAsBefore() throws {
        let folder = try makeFolderWorld("ListNewWindow")
        let world = folder.world
        world.settings.nextBookWindow = .newWindow
        world.library.library.readingList = ReadingList(
            bookIDs: [folder.first.id, folder.second.id], continuation: .playBookBelow, skipsFinished: true
        )
        let requests = ReadingListOpenRequests()
        requests.request(for: folder.first.id)
        let switcher = SwitchRecorder(requests: world.autoplayRequests, readingListRequests: requests)
        let opened = record(.openBookWindow, in: world)
        let reader = makeReader(for: folder.first, in: world, switcher: switcher, readingListRequests: requests)

        reader.goThroughReadingList(.down)
        XCTAssertTrue(eventually { !opened().isEmpty }, "Never opened the next book")

        XCTAssertEqual(opened().map { $0.object as? UUID }, [folder.second.id])
        XCTAssertTrue(switcher.shown.isEmpty)
    }

    // MARK: - Teardown Against Start

    /// The reader moved from closes without touching the media session of the
    /// reader that took over: its owner stays the active one.
    func testTheOldReadersCloseLeavesTheNewReadersMediaSessionAlone() throws {
        let folder = try makeFolderWorld("Teardown")
        let coordinator = NowPlayingService(installsSystemIntegrations: false, diagnosticSink: { _ in })
        let old = folder.world.openReader(for: folder.first, nowPlaying: coordinator)
        let new = folder.world.openReader(for: folder.second, nowPlaying: coordinator)
        waitForReaderToLoad(old)
        waitForReaderToLoad(new)
        new.windowBecameKey()
        XCTAssertEqual(coordinator.activeOwnerID, new.readerID)

        old.close()

        XCTAssertEqual(coordinator.activeOwnerID, new.readerID, "The old reader's close took the new reader's session")
        XCTAssertTrue(folder.world.library.openBookIDs.contains(folder.second.id))
        XCTAssertFalse(folder.world.library.openBookIDs.contains(folder.first.id))
    }

    // MARK: - Helpers

    /// A folder of three silent audiobooks, "A Volume", "B Volume", and "C
    /// Volume", in a world whose global "When book ends" is Continue to Next
    /// Book, so each ends into the next; the folder has `options`.
    struct FolderWorld {
        let world: IntegrationWorld
        let first: Book
        let second: Book
        let third: Book
    }

    private func makeFolderWorld(_ label: String, options: ListeningOptions? = nil) throws -> FolderWorld {
        let world = try makeIntegrationWorld(label)
        // Titles order the books in their folder; the folder's own row holds
        // the options, set directly so nothing is saved.
        let titles = ["A Volume", "B Volume", "C Volume"]
        var books: [Book] = []
        for title in titles {
            books.append(try world.makeSilentAudioBook(title: title, trackDurations: [1, 1], endOfBook: .continueNext))
        }
        var row = BookFolder(name: world.folder.path)
        row.listeningOptions = options
        world.library.library.folders = [row]
        world.settings.endOfBookBehavior = .continueNext
        return FolderWorld(world: world, first: books[0], second: books[1], third: books[2])
    }

    /// A reader for `book` in `folder`'s world, loaded, with `switcher` as
    /// its window and its window on screen. It is closed when the test ends.
    private func makeReader(
        for book: Book,
        in world: IntegrationWorld,
        switcher: SwitchRecorder,
        readingListRequests: ReadingListOpenRequests? = nil
    ) -> ReaderViewModel {
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: world.library,
            settingsViewModel: world.settings,
            substitutionService: TextSubstitutionService(rules: []),
            autoplayRequests: world.autoplayRequests,
            readingListRequests: readingListRequests,
            notificationCenter: world.notifications
        )
        reader.nextBookWindowSwitcher = { switcher.show($0) }
        reader.hostWindowIsOnScreenOverride = true
        addTeardownBlock { reader.close() }
        waitForReaderToLoad(reader)
        return reader
    }

    /// Records every notification named `name` posted on `world`'s center,
    /// returning a function that reads them.
    private func record(_ name: Notification.Name, in world: IntegrationWorld) -> () -> [Notification] {
        var posted: [Notification] = []
        world.notifications.publisher(for: name)
            .sink { posted.append($0) }
            .store(in: &subscriptions)
        return { posted }
    }
}

/// A stand-in for the window's switch: records each book shown, and whether
/// the requests for it were waiting at that moment.
@MainActor
private final class SwitchRecorder {
    /// The books shown, in order.
    private(set) var shown: [UUID] = []
    /// For each switch, whether the autoplay request for the book waited.
    private(set) var requestWaitingAtTheSwitch: [Bool] = []
    /// For each switch, whether the reading-list request for the book waited.
    private(set) var readingListRequestWaitingAtTheSwitch: [Bool] = []
    private let requests: ReaderAutoplayRequests
    private let readingListRequests: ReadingListOpenRequests?

    init(requests: ReaderAutoplayRequests, readingListRequests: ReadingListOpenRequests? = nil) {
        self.requests = requests
        self.readingListRequests = readingListRequests
    }

    /// Notes that the window was asked to show `bookID`.
    func show(_ bookID: UUID) {
        shown.append(bookID)
        requestWaitingAtTheSwitch.append(requests.hasRequest(for: bookID))
        readingListRequestWaitingAtTheSwitch.append(readingListRequests?.hasRequest(for: bookID) ?? false)
    }
}
