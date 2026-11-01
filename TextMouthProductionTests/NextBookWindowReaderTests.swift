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
        reader.windowStandingOverride = .noWindow

        reader.handleEndOfBook()
        XCTAssertTrue(eventually { !asked().isEmpty }, "Never asked for the next book")

        XCTAssertEqual(asked().map(\.nextBookID), [folder.second.id])
        XCTAssertTrue(switcher.shown.isEmpty)
    }

    /// Ends the first book of a fresh folder world, whose window stands as
    /// `standing` and which `prepare` has made busy, and says whether the
    /// next book opened in a new window (the notification posted, the
    /// switcher not called) or this window switched.
    ///
    /// - Returns: True when a new window opened, false when this window
    ///   switched.
    private func endOpensANewWindow(
        _ label: String,
        standing: NextBookWindowStanding = .onScreen,
        prepare: (FolderWorld) -> Void = { _ in },
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> Bool {
        let folder = try makeFolderWorld(label)
        prepare(folder)
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let asked = record(.continueToNextBook, in: folder.world)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        reader.windowStandingOverride = standing

        reader.handleEndOfBook()
        XCTAssertTrue(
            eventually { !asked().isEmpty || !switcher.shown.isEmpty },
            "\(label): never went on", file: file, line: line
        )
        // Exactly one of the two happened.
        XCTAssertEqual(asked().isEmpty, !switcher.shown.isEmpty, "\(label)", file: file, line: line)
        return !asked().isEmpty
    }

    /// A sheet or an alert open over the window, or a field being typed in
    /// (Go to Percent, Time, or Page), opens a new window: a switch would
    /// take them away.
    func testASheetOrAFieldBeingEditedOpensANewWindow() throws {
        var sheet = NextBookWindowStanding.onScreen
        sheet.hasSheet = true
        XCTAssertTrue(try endOpensANewWindow("BusySheet", standing: sheet))
        var field = NextBookWindowStanding.onScreen
        field.fieldIsBeingEdited = true
        XCTAssertTrue(try endOpensANewWindow("BusyField", standing: field))
    }

    /// An Edit Text session of the book, the library moving, and the library
    /// being unavailable each open a new window: the app refuses to open a
    /// book while the library moves or is unavailable, which a switch would
    /// go around.
    func testAnEditSessionAMoveOrAnUnavailableLibraryOpensANewWindow() throws {
        XCTAssertTrue(try endOpensANewWindow("BusyEdit") { folder in
            let sessions = BookTextEditSessions()
            let baseline = BookTextBaseline(
                source: nil,
                cache: FileFingerprint(stamp: FileStamp(byteCount: 0, modificationTimeNanoseconds: 0), digest: "")
            )
            sessions.begin(folder.first.id, BookTextEditSessions.Session(baseline: baseline, report: { _, _ in }))
            folder.world.library.textEditSessions = sessions
            self.addTeardownBlock { sessions.end(folder.first.id) }
        })
        XCTAssertTrue(try endOpensANewWindow("BusyMove") { folder in
            folder.world.library.dataDirectoryMove = DataDirectoryMoveProgress(
                destination: URL(fileURLWithPath: "/Volumes/Backup/Library")
            )
        })
        XCTAssertTrue(try endOpensANewWindow("BusyUnavailable") { folder in
            folder.world.library.noteDataDirectoryUnavailable(
                .driveNotConnected(volume: "Spare Disk", folder: "/Volumes/Spare Disk/TextMouth")
            )
        })
    }

    /// A window minimized to the Dock, and a window hidden with the app
    /// (Command-H orders every window out), still switch: a book shown there
    /// is there when the window returns. A window that has closed does not.
    func testAMinimizedWindowAndAHiddenAppStillSwitch() throws {
        var minimized = NextBookWindowStanding.noWindow
        minimized.isMiniaturized = true
        XCTAssertFalse(try endOpensANewWindow("StandingMinimized", standing: minimized))
        var hidden = NextBookWindowStanding.noWindow
        hidden.appIsHidden = true
        XCTAssertFalse(try endOpensANewWindow("StandingHidden", standing: hidden))
        XCTAssertFalse(try endOpensANewWindow("StandingVisible", standing: .onScreen))
        XCTAssertTrue(try endOpensANewWindow("StandingClosed", standing: .noWindow))
    }

    /// A sleep timer this reader set and that runs opens the next book in a
    /// new window, and keeps running: closing the old reader would stop it.
    func testARunningSleepTimerOpensANewWindowAndKeepsRunning() throws {
        preserveSharedSleepTimer()
        let folder = try makeFolderWorld("BusyTimer")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let opened = record(.openBookWindow, in: folder.world)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        SleepTimerService.shared.start(duration: .minutes(30), ownerID: reader.readerID, onExpire: {})
        XCTAssertTrue(SleepTimerService.shared.isActive)

        reader.goThroughFolder(.down)
        XCTAssertTrue(eventually { !opened().isEmpty }, "Never opened the next book")

        XCTAssertEqual(opened().map { $0.object as? UUID }, [folder.second.id])
        XCTAssertTrue(switcher.shown.isEmpty, "Switched a window that holds a running timer")
        XCTAssertTrue(SleepTimerService.shared.isActive, "The timer stopped")
        XCTAssertEqual(SleepTimerService.shared.ownerID, reader.readerID)
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

    // MARK: - Next and Previous in Folder

    /// Next in Folder, from a book not playing, opens the book below it:
    /// "Opening: <title>", then its window alone is asked for, with no
    /// request to play it and none to read it from the reading list.
    func testNextInFolderOpensTheBookBelowWithANewWindow() throws {
        let folder = try makeFolderWorld("FolderNextNew")
        folder.world.settings.nextBookWindow = .newWindow
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let asked = record(.continueToNextBook, in: folder.world)
        let opened = record(.openBookWindow, in: folder.world)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)

        let recorder = recordingAnnouncements {
            reader.goThroughFolder(.down)
            XCTAssertTrue(opened().isEmpty, "Opened before the announcement had a moment")
            XCTAssertTrue(eventually { !opened().isEmpty }, "Never opened the next book")
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Opening: B Volume"])
        XCTAssertEqual(opened().map { $0.object as? UUID }, [folder.second.id])
        XCTAssertTrue(asked().isEmpty, "Asked for the next book to start")
        XCTAssertFalse(folder.world.autoplayRequests.hasRequest(for: folder.second.id))
        XCTAssertTrue(switcher.shown.isEmpty)
    }

    /// With This Window the same command switches the window instead.
    func testNextInFolderSwitchesThisWindow() throws {
        let folder = try makeFolderWorld("FolderNextSwitch")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let opened = record(.openBookWindow, in: folder.world)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)

        reader.goThroughFolder(.down)
        XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "Never switched")

        XCTAssertEqual(switcher.shown, [folder.second.id])
        XCTAssertTrue(opened().isEmpty)
    }

    /// Previous in Folder opens the book above.
    func testPreviousInFolderOpensTheBookAbove() throws {
        let folder = try makeFolderWorld("FolderPrevious")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let reader = makeReader(for: folder.third, in: folder.world, switcher: switcher)

        let recorder = recordingAnnouncements {
            reader.goThroughFolder(.up)
            XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "Never switched")
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Opening: B Volume"])
        XCTAssertEqual(switcher.shown, [folder.second.id])
    }

    /// At either end the command says so, and changes nothing.
    func testTheEndsOfTheFolderSayNoMoreBooks() throws {
        let folder = try makeFolderWorld("FolderEnds")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let opened = record(.openBookWindow, in: folder.world)
        let last = makeReader(for: folder.third, in: folder.world, switcher: switcher)
        let first = makeReader(for: folder.first, in: folder.world, switcher: switcher)

        let down = recordingAnnouncements { last.goThroughFolder(.down) }
        let up = recordingAnnouncements { first.goThroughFolder(.up) }
        spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)

        XCTAssertEqual(down.announcements.map(\.message), ["No more books in folder."])
        XCTAssertEqual(up.announcements.map(\.message), ["No more books in folder."])
        XCTAssertTrue(switcher.shown.isEmpty)
        XCTAssertTrue(opened().isEmpty)
    }

    /// A finished book is passed over while the folder skips finished books,
    /// and visited when it does not; with only finished books beyond, the
    /// command says why.
    func testFinishedBooksArePassedOverAsTheFolderSays() throws {
        let folder = try makeFolderWorld("FolderFinished")
        markFinished(folder.second, in: folder.world)
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)

        reader.goThroughFolder(.down)
        XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "Never switched")
        XCTAssertEqual(switcher.shown, [folder.third.id], "went to the finished book")

        // The folder's own options keep finished books in the way.
        folder.world.library.library.folders[0].listeningOptions = ListeningOptions(skipsFinished: false)
        reader.goThroughFolder(.down)
        XCTAssertTrue(eventually { switcher.shown.count == 2 }, "Never switched the second time")
        XCTAssertEqual(switcher.shown.last, folder.second.id)

        // Only a finished book lies below the second one.
        markFinished(folder.third, in: folder.world)
        folder.world.library.library.folders[0].listeningOptions = nil
        let middle = makeReader(for: folder.second, in: folder.world, switcher: switcher)
        let said = recordingAnnouncements { middle.goThroughFolder(.down) }
        XCTAssertEqual(said.announcements.map(\.message), ["Every book after it in the folder is finished."])
    }

    /// Next in Folder from a book that plays pauses it, says "Starting", and
    /// asks for the book below to play, after the request, in this window.
    func testNextInFolderFromAPlayingBookStartsTheBookBelow() throws {
        let folder = try makeFolderWorld("FolderPlaying")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)
        reader.play()
        XCTAssertTrue(eventually(within: 15) { reader.audioPlaybackService.isPlaying }, "The book did not play")

        let recorder = recordingAnnouncements {
            reader.goThroughFolder(.down)
            XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "Never switched")
        }

        XCTAssertEqual(recorder.announcements.map(\.message), ["Starting: B Volume"])
        XCTAssertTrue(reader.audioPlaybackService.isPaused, "This book was not paused")
        XCTAssertEqual(switcher.shown, [folder.second.id])
        XCTAssertEqual(switcher.requestWaitingAtTheSwitch, [true], "The request to play came after the switch")
    }

    /// The folder's own choice of window decides the command's window, and a
    /// dimmed choice, with items that do not go on, does not.
    func testTheCommandFollowsTheFoldersChoiceWhileItIsInEffect() throws {
        let folder = try makeFolderWorld("FolderChoice", options: ListeningOptions(
            continuation: .playBookBelow, nextBookWindow: .newWindow
        ))
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let opened = record(.openBookWindow, in: folder.world)
        let reader = makeReader(for: folder.first, in: folder.world, switcher: switcher)

        reader.goThroughFolder(.down)
        XCTAssertTrue(eventually { !opened().isEmpty }, "Never opened the next book")
        XCTAssertTrue(switcher.shown.isEmpty, "The folder's choice of a new window was not followed")

        // Stop dims the choice, so the global This Window decides.
        folder.world.library.library.folders[0].listeningOptions = ListeningOptions(
            continuation: .stop, nextBookWindow: .newWindow
        )
        reader.goThroughFolder(.down)
        XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "A dimmed choice was followed")
    }

    // MARK: - The Commands

    /// The two commands are listed under Navigation with no keys until the
    /// user gives them some, in the app's scope, each posting its own
    /// notification.
    func testTheFolderCommandsHaveNoKeysUntilGivenSome() {
        XCTAssertEqual(ShortcutAction.nextInFolder.rawValue, "Next in Folder")
        XCTAssertEqual(ShortcutAction.previousInFolder.rawValue, "Previous in Folder")
        for action in [ShortcutAction.nextInFolder, .previousInFolder] {
            XCTAssertEqual(action.title, action.rawValue)
            XCTAssertEqual(action.category, "Navigation", action.rawValue)
            XCTAssertEqual(action.defaultScope, .app, action.rawValue)
            XCTAssertEqual(ShortcutAction.defaultBindings[action], [], action.rawValue)
        }
        XCTAssertEqual(ShortcutAction.nextInFolder.notificationName, .nextInFolder)
        XCTAssertEqual(ShortcutAction.previousInFolder.notificationName, .previousInFolder)
        XCTAssertEqual(Notification.Name.nextInFolder.rawValue, "nextInFolder")
        XCTAssertEqual(Notification.Name.previousInFolder.rawValue, "previousInFolder")
    }

    /// The Navigate menu has both, offered in a reader window alone. SwiftUI
    /// builds the menu where a test cannot read it, so this reads the menu's
    /// source for the items and for the condition that dims them.
    func testTheNavigateMenuOffersThemInReaderWindowsOnly() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TextMouth/App/MenuCommands.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        for name in ["nextInFolder", "previousInFolder"] {
            XCTAssertTrue(text.contains("Button(ShortcutAction.\(name).title)"), name)
            XCTAssertTrue(text.contains("post(name: .\(name), object: nil)"), name)
        }
        // Gated on a scene value the reader's window publishes, so the items
        // stay offered while VoiceOver reads the text, which holds no
        // keyboard focus; a plain focused value would dim them then.
        XCTAssertTrue(text.contains(".disabled(isReaderWindow != true)"))
        XCTAssertFalse(text.contains("activeWindowType != .reader"))
        let view = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TextMouth/Views/Reader/BookReaderWindowView.swift")
        let viewText = try String(contentsOf: view, encoding: .utf8)
        XCTAssertTrue(viewText.contains(".focusedSceneValue(\\.isReaderWindow, true)"))
    }

    /// The notification reaches the key reader and moves it.
    func testTheNotificationsMoveTheReader() throws {
        let folder = try makeFolderWorld("FolderNotification")
        let switcher = SwitchRecorder(requests: folder.world.autoplayRequests)
        let reader = makeReader(for: folder.second, in: folder.world, switcher: switcher)
        _ = reader

        folder.world.notifications.post(name: .previousInFolder, object: nil)
        XCTAssertTrue(eventually { !switcher.shown.isEmpty }, "Previous in Folder did not reach the reader")
        XCTAssertEqual(switcher.shown, [folder.first.id])
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
            // Longer than any test runs, so no chapter ends by itself.
            books.append(try world.makeSilentAudioBook(title: title, trackDurations: [5, 5], endOfBook: .continueNext))
        }
        var row = BookFolder(name: world.folder.path)
        row.listeningOptions = options
        world.library.library.folders = [row]
        world.settings.endOfBookBehavior = .continueNext
        return FolderWorld(world: world, first: books[0], second: books[1], third: books[2])
    }

    /// Makes `book`'s row in `world`'s library rest at its end, as a book
    /// that played to its end does (`Book.restsAtEnd`): its place at the
    /// last character of a measured total.
    private func markFinished(_ book: Book, in world: IntegrationWorld) {
        guard let index = world.library.library.books.firstIndex(where: { $0.id == book.id }) else {
            return XCTFail("\(book.title) is not in the library")
        }
        world.library.library.books[index].totalCharacterCount = 100
        world.library.library.books[index].readingPosition = ReadingPosition(
            chapterIndex: 0, characterOffset: 100, globalCharacterOffset: 100
        )
        XCTAssertTrue(world.library.library.books[index].restsAtEnd, "\(book.title) does not rest at its end")
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
        reader.windowStandingOverride = .onScreen
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
