import AppKit
import XCTest
@testable import TextMouth

/// Routing app-wide actions to windows (TODO A05): who takes each action in
/// every window arrangement, taking it exactly once through the router, and
/// actions waiting for a Library window.
///
/// Every router a test routes through listens on a private notification
/// center and asks for Library windows only by counting them, so the running
/// app's own windows never see these actions and nothing opens on screen.
@MainActor
final class LibraryWindowRouterTests: XCTestCase {
    /// Creates a lightweight titled window without displaying it.
    private func makeWindow() -> NSWindow {
        RouterHarness.makeWindow()
    }

    // MARK: - Choosing a Library window

    func testSelectionReturnsNilWhenNoLibraryWindowExists() {
        XCTAssertNil(
            LibraryWindowRouter.selectedWindow(from: [], keyWindow: nil)
        )
    }

    func testSelectionPrefersKeyLibraryWindow() {
        let firstLibrary = makeWindow()
        let keyLibrary = makeWindow()

        let selected = LibraryWindowRouter.selectedWindow(
            from: [firstLibrary, keyLibrary],
            keyWindow: keyLibrary
        )

        XCTAssertTrue(selected === keyLibrary)
    }

    func testSelectionUsesExistingLibraryWhenReaderIsKey() {
        let existingLibrary = makeWindow()
        let otherLibrary = makeWindow()
        let keyReader = makeWindow()

        let selected = LibraryWindowRouter.selectedWindow(
            from: [existingLibrary, otherLibrary],
            keyWindow: keyReader
        )

        XCTAssertTrue(selected === existingLibrary)
    }

    func testAppDelegateAllowsInitialUntitledLibrary() {
        XCTAssertTrue(
            AppDelegate.shouldOpenUntitledLibrary(hasOpenLibraryWindow: false)
        )
    }

    func testAppDelegateSuppressesUntitledLibraryWhenOneExists() {
        XCTAssertFalse(
            AppDelegate.shouldOpenUntitledLibrary(hasOpenLibraryWindow: true)
        )
    }

    /// Registering a Library window again, as SwiftUI showing it again
    /// does, replaces its way of taking actions and keeps its place among
    /// the Library windows.
    func testRegisteringALibraryWindowAgainReplacesItsActionAndKeepsItsPlace() {
        let harness = RouterHarness()
        let first = makeWindow()
        let second = makeWindow()
        var calls: [String] = []
        harness.router.register(first) { calls.append("first, before: \($0)") }
        harness.router.register(second) { calls.append("second: \($0)") }
        harness.router.register(first) { calls.append("first, after: \($0)") }

        harness.router.route(.openBookFile)

        XCTAssertEqual(calls, ["first, after: openBookFile"])
        XCTAssertEqual(harness.router.registeredLibraryWindows, [first, second])
    }

    /// A Library window that closed and is shown again registers again, as
    /// SwiftUI showing it for a book opened from Finder makes it do: it
    /// takes the action waiting since it closed, and the actions after.
    func testALibraryWindowShownAgainTakesActionsAgain() {
        let harness = RouterHarness()
        let library = harness.addLibraryWindow(named: "Library")
        harness.router.unregister(library)
        harness.post(.openBookFile)
        harness.runDueWork()

        harness.router.register(library) { [unowned harness] action in
            harness.note("Library shown again: \(action)")
        }
        harness.runDueWork()
        harness.post(.importDAISYFolder)

        XCTAssertEqual(harness.takings, [
            "Library shown again: openBookFile",
            "Library shown again: importDAISYFolder",
        ])
        XCTAssertEqual(harness.router.registeredLibraryWindows, [library])
    }

    // MARK: - Reader windows

    /// The reader window another reader opens through: the key window when
    /// it is a reader, otherwise the newest reader, and none when no reader
    /// is open.
    func testReaderSelectionPrefersTheKeyReaderThenTheNewest() {
        let olderReader = makeWindow()
        let newerReader = makeWindow()
        let otherWindow = makeWindow()
        let readers = [olderReader, newerReader]

        XCTAssertTrue(LibraryWindowRouter.selectedReaderWindow(from: readers, keyWindow: olderReader) === olderReader)
        XCTAssertTrue(LibraryWindowRouter.selectedReaderWindow(from: readers, keyWindow: nil) === newerReader)
        XCTAssertTrue(LibraryWindowRouter.selectedReaderWindow(from: readers, keyWindow: otherWindow) === newerReader)
        XCTAssertNil(LibraryWindowRouter.selectedReaderWindow(from: [], keyWindow: otherWindow))
    }

    /// While no Library window is open, a book's reader opens through the
    /// key window when it is a reader, and otherwise through the reader
    /// window registered most recently.
    func testReaderOpensThroughTheKeyReaderWindowFirst() {
        let harness = RouterHarness()
        let olderReader = harness.addReaderWindow(named: "older reader")
        harness.addReaderWindow(named: "newer reader")
        let otherWindow = makeWindow()
        let book = UUID()

        harness.keyWindow = olderReader
        harness.router.route(.openBookWindow(book))
        harness.keyWindow = nil
        harness.router.route(.openBookWindow(book))
        harness.keyWindow = otherWindow
        harness.router.route(.continueToNextBook(book))

        XCTAssertEqual(harness.takings, [
            "older reader: opened \(book)",
            "newer reader: opened \(book)",
            "newer reader: opened \(book)",
        ])
        XCTAssertEqual(harness.libraryWindowRequests, 0)
    }

    /// Registering a reader window again replaces its action instead of
    /// adding a second one.
    func testRegisteringAReaderWindowAgainReplacesItsAction() {
        let harness = RouterHarness()
        let reader = makeWindow()
        var calls: [String] = []
        harness.router.registerReaderWindow(reader) { _ in calls.append("first") }
        harness.router.registerReaderWindow(reader) { _ in calls.append("second") }

        harness.keyWindow = reader
        harness.router.route(.openBookWindow(UUID()))
        harness.keyWindow = nil
        harness.router.route(.continueToNextBook(UUID()))

        XCTAssertEqual(calls, ["second", "second"])
    }

    /// A reader window that has closed opens nothing. With no other window
    /// open, the book's reader waits for a Library window instead.
    func testAClosedReaderWindowOpensNothing() {
        let harness = RouterHarness()
        let reader = harness.addReaderWindow(named: "reader")
        let book = UUID()
        harness.router.unregisterReaderWindow(reader)

        harness.post(.continueToNextBook, userInfo: [Notification.ContinueToNextBookKey.bookID: book])
        harness.runDueWork()

        XCTAssertEqual(harness.takings, [])
        XCTAssertEqual(harness.router.waitingActions, [.continueToNextBook(book)])
        XCTAssertEqual(harness.libraryWindowRequests, 1)
    }

    /// Once the only Library window closes, the next book's reader opens
    /// through a reader window instead.
    func testClosingTheLastLibraryLeavesTheContinuedBookToAReaderWindow() {
        let harness = RouterHarness()
        let library = harness.addLibraryWindow(named: "Library")
        harness.addReaderWindow(named: "reader")
        let book = UUID()

        harness.router.unregister(library)
        harness.post(.continueToNextBook, userInfo: [Notification.ContinueToNextBookKey.bookID: book])

        XCTAssertEqual(harness.takings, ["reader: opened \(book)"])
        XCTAssertEqual(harness.libraryWindowRequests, 0)
    }

    // MARK: - Who takes an app-wide action

    /// Only the actions that open a book's reader name a book; the rest
    /// need a Library window.
    func testOnlyActionsThatOpenAReaderNameABook() {
        let book = UUID()

        XCTAssertEqual(GlobalAction.openBookWindow(book).bookToOpen, book)
        XCTAssertEqual(GlobalAction.continueToNextBook(book).bookToOpen, book)
        XCTAssertNil(GlobalAction.openBookFile.bookToOpen)
        XCTAssertNil(GlobalAction.importDAISYFolder.bookToOpen)
    }

    /// Who takes each kind of app-wide action in every window arrangement
    /// TODO A05 names: a cold launch with no window yet, every window
    /// closed while the app runs, only readers open, one Library window,
    /// and several Library windows with and without a key one.
    ///
    /// A registered Library window takes everything whenever there is one.
    /// Without one, a reader window opens a book's reader, and everything
    /// else waits for a new Library window.
    func testWhoTakesEachActionInEveryWindowArrangement() {
        let firstLibrary = makeWindow()
        let secondLibrary = makeWindow()
        let olderReader = makeWindow()
        let newerReader = makeWindow()
        // Settings, or any other window that is neither Library nor reader.
        let otherWindow = makeWindow()
        let book = UUID()
        let actionsNeedingALibrary: [GlobalAction] = [.openBookFile, .importDAISYFolder]
        let actionsOpeningAReader: [GlobalAction] = [.openBookWindow(book), .continueToNextBook(book)]

        let arrangements: [(
            name: String,
            libraries: [NSWindow],
            readers: [NSWindow],
            keyWindow: NSWindow?,
            libraryActionHandler: GlobalActionHandler,
            readerActionHandler: GlobalActionHandler
        )] = [
            ("cold launch, no window yet", [], [], nil, .newLibraryWindow, .newLibraryWindow),
            ("every window closed, app running", [], [], nil, .newLibraryWindow, .newLibraryWindow),
            ("every Library and reader closed, Settings key", [], [], otherWindow, .newLibraryWindow, .newLibraryWindow),
            ("only readers, one key", [], [olderReader, newerReader], olderReader, .newLibraryWindow, .readerWindow(olderReader)),
            ("only readers, none key", [], [olderReader, newerReader], nil, .newLibraryWindow, .readerWindow(newerReader)),
            ("only readers, Settings key", [], [olderReader, newerReader], otherWindow, .newLibraryWindow, .readerWindow(newerReader)),
            ("one Library, none key", [firstLibrary], [], nil, .libraryWindow(firstLibrary), .libraryWindow(firstLibrary)),
            ("one Library, it key", [firstLibrary], [olderReader], firstLibrary, .libraryWindow(firstLibrary), .libraryWindow(firstLibrary)),
            ("one Library, reader key", [firstLibrary], [olderReader], olderReader, .libraryWindow(firstLibrary), .libraryWindow(firstLibrary)),
            ("several Libraries, second key", [firstLibrary, secondLibrary], [olderReader], secondLibrary, .libraryWindow(secondLibrary), .libraryWindow(secondLibrary)),
            ("several Libraries, none key", [firstLibrary, secondLibrary], [olderReader], nil, .libraryWindow(firstLibrary), .libraryWindow(firstLibrary)),
            ("several Libraries, reader key", [firstLibrary, secondLibrary], [olderReader], olderReader, .libraryWindow(firstLibrary), .libraryWindow(firstLibrary)),
            ("several Libraries, Settings key", [firstLibrary, secondLibrary], [], otherWindow, .libraryWindow(firstLibrary), .libraryWindow(firstLibrary)),
        ]

        for arrangement in arrangements {
            for (actions, expected) in [
                (actionsNeedingALibrary, arrangement.libraryActionHandler),
                (actionsOpeningAReader, arrangement.readerActionHandler),
            ] {
                for action in actions {
                    let handler = LibraryWindowRouter.handler(
                        for: action,
                        keyWindow: arrangement.keyWindow,
                        registeredLibraryWindows: arrangement.libraries,
                        readerWindows: arrangement.readers
                    )
                    XCTAssertEqual(handler, expected, "\(arrangement.name): \(action)")
                }
            }
        }
    }

    // MARK: - Taking each action exactly once

    /// Each notification the router listens for asks for its action, and
    /// one that names no book, or that the router does not route, asks for
    /// none.
    func testEachRoutedNotificationAsksForItsAction() {
        let book = UUID()
        let samples: [(notification: Notification, action: GlobalAction)] = [
            (Notification(name: .openBookFile), .openBookFile),
            (Notification(name: .importDAISYFolder), .importDAISYFolder),
            (Notification(name: .openBookWindow, object: book), .openBookWindow(book)),
            (
                Notification(
                    name: .continueToNextBook,
                    object: nil,
                    userInfo: [Notification.ContinueToNextBookKey.bookID: book]
                ),
                .continueToNextBook(book)
            ),
        ]

        XCTAssertEqual(samples.map(\.notification.name), GlobalAction.routedNotificationNames)
        for sample in samples {
            XCTAssertEqual(GlobalAction(notification: sample.notification), sample.action)
        }
        XCTAssertNil(GlobalAction(notification: Notification(name: .openBookWindow)))
        XCTAssertNil(GlobalAction(notification: Notification(name: .openBookWindow, object: "not a book")))
        XCTAssertNil(GlobalAction(notification: Notification(name: .continueToNextBook)))
        XCTAssertNil(GlobalAction(notification: Notification(name: .goBack)))
    }

    /// Every app-wide action posted is taken exactly once, in every window
    /// arrangement TODO A05 names, however many Library windows are open:
    /// by the one Library window the decision names, by a reader window, or,
    /// when no open window can take it, by the one Library window opened for
    /// it once that window registers.
    func testEveryPostedActionIsTakenExactlyOnceInEveryArrangement() {
        let book = UUID()
        let posts: [(name: Notification.Name, object: Any?, userInfo: [AnyHashable: Any]?, action: GlobalAction)] = [
            (.openBookFile, nil, nil, .openBookFile),
            (.importDAISYFolder, nil, nil, .importDAISYFolder),
            (.openBookWindow, book, nil, .openBookWindow(book)),
            (.continueToNextBook, nil, [Notification.ContinueToNextBookKey.bookID: book], .continueToNextBook(book)),
        ]
        let arrangements: [(
            name: String,
            libraries: Int,
            readers: Int,
            closedLibraries: Int,
            key: KeyWindowChoice,
            libraryActionTaker: String,
            readerActionTaker: String
        )] = [
            ("cold launch, no window yet", 0, 0, 0, .noWindow, "new Library", "new Library"),
            ("every window closed, app running", 0, 0, 2, .noWindow, "new Library", "new Library"),
            ("only readers, the first key", 0, 2, 1, .reader(0), "new Library", "reader 1"),
            ("only readers, none key", 0, 2, 0, .noWindow, "new Library", "reader 2"),
            ("one Library, a reader key", 1, 1, 0, .reader(0), "Library 1", "Library 1"),
            ("several Libraries, the second key", 3, 1, 1, .library(1), "Library 2", "Library 2"),
            ("several Libraries, none key", 3, 1, 0, .noWindow, "Library 1", "Library 1"),
            ("several Libraries, a reader key", 3, 1, 0, .reader(0), "Library 1", "Library 1"),
        ]

        for arrangement in arrangements {
            for post in posts {
                let harness = RouterHarness()
                // Library windows that registered and then closed, as when
                // the app keeps running after its windows close.
                for index in 0..<arrangement.closedLibraries {
                    harness.router.unregister(harness.addLibraryWindow(named: "closed Library \(index + 1)"))
                }
                let libraries = (0..<arrangement.libraries).map { harness.addLibraryWindow(named: "Library \($0 + 1)") }
                let readers = (0..<arrangement.readers).map { harness.addReaderWindow(named: "reader \($0 + 1)") }
                switch arrangement.key {
                case .noWindow: harness.keyWindow = nil
                case .library(let index): harness.keyWindow = libraries[index]
                case .reader(let index): harness.keyWindow = readers[index]
                }

                harness.post(post.name, object: post.object, userInfo: post.userInfo)
                harness.runDueWork()
                // When the action waits, the Library window it asked for
                // opens and registers.
                if harness.libraryWindowRequests > 0 {
                    harness.addLibraryWindow(named: "new Library")
                    harness.runDueWork()
                }

                let taker = post.action.bookToOpen == nil ? arrangement.libraryActionTaker : arrangement.readerActionTaker
                let context = "\(arrangement.name): \(post.action)"
                XCTAssertEqual(harness.takings, [RouterHarness.taking(of: post.action, by: taker)], context)
                XCTAssertEqual(harness.libraryWindowRequests, taker == "new Library" ? 1 : 0, context)
                XCTAssertEqual(harness.router.waitingActions, [], context)
            }
        }
    }

    /// The router records each decision it makes, naming the window that
    /// took the action, one decision per action.
    func testEachDecisionIsRecordedWithWhoTookTheAction() {
        let harness = RouterHarness()
        let firstLibrary = harness.addLibraryWindow(named: "Library 1")
        let secondLibrary = harness.addLibraryWindow(named: "Library 2")

        harness.keyWindow = secondLibrary
        harness.post(.openBookFile)
        harness.keyWindow = nil
        harness.post(.importDAISYFolder)
        // A notification naming no book asks for nothing, and is not decided.
        harness.post(.openBookWindow)

        XCTAssertEqual(harness.router.recordedDecisions, [
            GlobalActionDecision(action: .openBookFile, handler: .libraryWindow(secondLibrary)),
            GlobalActionDecision(action: .importDAISYFolder, handler: .libraryWindow(firstLibrary)),
        ])
        XCTAssertEqual(harness.takings, ["Library 2: openBookFile", "Library 1: importDAISYFolder"])
    }

    // MARK: - Waiting for a Library window

    /// With no window open, an action waits while one Library window is
    /// asked for, on the next turn of the main queue. The Library window
    /// that registers takes the action on the turn after, and one that
    /// registers later finds nothing to take.
    func testWaitingActionIsTakenOnceByTheLibraryWindowThatRegisters() {
        let harness = RouterHarness()

        harness.post(.openBookFile)
        XCTAssertEqual(harness.router.waitingActions, [.openBookFile])
        XCTAssertEqual(harness.libraryWindowRequests, 0, "Asked for a window before the notification was delivered")
        harness.runDueWork()
        XCTAssertEqual(harness.libraryWindowRequests, 1)

        harness.addLibraryWindow(named: "Library 1")
        XCTAssertEqual(harness.takings, [], "Taken in the turn the window registered")
        harness.runDueWork()
        XCTAssertEqual(harness.takings, ["Library 1: openBookFile"])
        XCTAssertEqual(harness.router.waitingActions, [])

        harness.addLibraryWindow(named: "Library 2")
        harness.runDueWork()
        XCTAssertEqual(harness.takings, ["Library 1: openBookFile"])
        XCTAssertEqual(harness.libraryWindowRequests, 1)
    }

    /// Several actions waiting at once open one Library window, which takes
    /// them all in the order they arrived.
    func testOneLibraryWindowOpensForSeveralWaitingActions() {
        let harness = RouterHarness()
        let book = UUID()

        harness.post(.openBookFile)
        harness.runDueWork()
        harness.post(.importDAISYFolder)
        harness.post(.continueToNextBook, userInfo: [Notification.ContinueToNextBookKey.bookID: book])
        harness.runDueWork()
        XCTAssertEqual(harness.libraryWindowRequests, 1)

        harness.addLibraryWindow(named: "Library 1")
        harness.runDueWork()

        XCTAssertEqual(harness.takings, [
            "Library 1: openBookFile",
            "Library 1: importDAISYFolder",
            "Library 1: \(GlobalAction.continueToNextBook(book))",
        ])
    }

    /// Once the Library window asked for has come, and closed again, the
    /// next action with no window to take it asks for another.
    func testAnotherLibraryWindowIsAskedForOnceTheFirstHasComeAndGone() {
        let harness = RouterHarness()
        harness.post(.openBookFile)
        harness.runDueWork()
        let first = harness.addLibraryWindow(named: "Library 1")
        harness.runDueWork()

        harness.router.unregister(first)
        harness.post(.importDAISYFolder)
        harness.runDueWork()
        XCTAssertEqual(harness.libraryWindowRequests, 2)
        harness.addLibraryWindow(named: "Library 2")
        harness.runDueWork()

        XCTAssertEqual(harness.takings, ["Library 1: openBookFile", "Library 2: importDAISYFolder"])
    }

    /// While the Library window asked for is on its way, later actions wait
    /// for it. A window that never comes is asked for again only once an
    /// action's lifetime has passed, by which time the oldest action has
    /// been dropped.
    func testALibraryWindowThatNeverComesIsAskedForAgainOnlyAfterTheLifetime() {
        let harness = RouterHarness()
        harness.post(.openBookFile)
        harness.runDueWork()

        harness.advance(by: 10)
        harness.post(.importDAISYFolder)
        harness.runDueWork()
        XCTAssertEqual(harness.libraryWindowRequests, 1)
        XCTAssertEqual(harness.router.waitingActions, [.openBookFile, .importDAISYFolder])

        harness.advance(by: PendingGlobalActions.lifetime - 10 + 1)
        harness.post(.openBookFile)
        harness.runDueWork()
        XCTAssertEqual(harness.libraryWindowRequests, 2)
        XCTAssertEqual(harness.router.waitingActions, [.importDAISYFolder, .openBookFile])
    }

    /// An action that waited longer than its lifetime is dropped, so a
    /// Library window registering much later takes nothing.
    func testAnActionTooOldIsDroppedInsteadOfTaken() {
        let harness = RouterHarness()
        harness.post(.openBookFile)
        harness.runDueWork()

        harness.advance(by: PendingGlobalActions.lifetime + 1)
        harness.addLibraryWindow(named: "Library 1")
        harness.runDueWork()

        XCTAssertEqual(harness.takings, [])
        XCTAssertEqual(harness.router.waitingActions, [])
    }

    /// At launch SwiftUI opens the first Library window itself, so an action
    /// arriving before it registers waits for it without asking for a
    /// second. Once it has come, a later need asks for a window again.
    func testTheFirstLibraryWindowOfALaunchIsNotAskedForTwice() {
        let harness = RouterHarness()
        harness.router.expectLibraryWindow()

        harness.post(.openBookFile)
        harness.runDueWork()
        XCTAssertEqual(harness.libraryWindowRequests, 0)
        let first = harness.addLibraryWindow(named: "Library 1")
        harness.runDueWork()
        XCTAssertEqual(harness.takings, ["Library 1: openBookFile"])

        harness.router.unregister(first)
        harness.post(.importDAISYFolder)
        harness.runDueWork()
        XCTAssertEqual(harness.libraryWindowRequests, 1)
    }

    /// Expecting a Library window changes nothing once one has registered:
    /// after it closes, the next action asks for a window at once.
    func testExpectingALibraryWindowChangesNothingOnceOneIsRegistered() {
        let harness = RouterHarness()
        let library = harness.addLibraryWindow(named: "Library 1")
        harness.router.expectLibraryWindow()

        harness.router.unregister(library)
        harness.post(.openBookFile)
        harness.runDueWork()

        XCTAssertEqual(harness.libraryWindowRequests, 1)
    }

    /// SwiftUI can build a Library window for a book opened from Finder and
    /// discard it within the same turn of the main queue. The waiting
    /// actions go to the window that stays, never to the discarded one.
    func testALibraryWindowDiscardedInTheSameTurnTakesNothing() {
        let harness = RouterHarness()
        harness.post(.openBookFile)
        harness.runDueWork()

        let discarded = harness.addLibraryWindow(named: "discarded Library")
        harness.router.unregister(discarded)
        harness.addLibraryWindow(named: "kept Library")
        harness.runDueWork()

        XCTAssertEqual(harness.takings, ["kept Library: openBookFile"])
    }

    // MARK: - Actions waiting for a Library window

    /// Waiting actions are taken oldest first, and only once: whatever
    /// takes them next finds nothing, as a second Library window
    /// registering after the first must.
    func testWaitingActionsAreTakenOnceOldestFirst() {
        var pending = PendingGlobalActions()
        let start = Date()
        pending.add(.openBookFile, at: start)
        pending.add(.importDAISYFolder, at: start.addingTimeInterval(1))

        XCTAssertEqual(pending.actions, [.openBookFile, .importDAISYFolder])
        XCTAssertEqual(pending.takeAll(), [.openBookFile, .importDAISYFolder])
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(pending.takeAll(), [])
    }

    /// An action waits for its lifetime and no longer: at the limit it is
    /// still waiting, and just past it it is thrown away, while a younger
    /// action keeps waiting.
    func testWaitingActionExpiresAfterItsLifetime() {
        var pending = PendingGlobalActions()
        let start = Date()
        pending.add(.openBookFile, at: start)
        pending.add(.importDAISYFolder, at: start.addingTimeInterval(10))

        XCTAssertEqual(pending.discardExpired(at: start.addingTimeInterval(PendingGlobalActions.lifetime)), [])
        XCTAssertEqual(
            pending.discardExpired(at: start.addingTimeInterval(PendingGlobalActions.lifetime + 1)),
            [.openBookFile]
        )
        XCTAssertEqual(pending.takeAll(), [.importDAISYFolder])
    }

    /// A clock set back further than the lifetime throws a waiting action
    /// away too, so it cannot wait indefinitely.
    func testClockSetBackThrowsAWaitingActionAway() {
        var pending = PendingGlobalActions()
        let start = Date()
        pending.add(.openBookFile, at: start)

        XCTAssertEqual(
            pending.discardExpired(at: start.addingTimeInterval(-PendingGlobalActions.lifetime - 1)),
            [.openBookFile]
        )
        XCTAssertTrue(pending.isEmpty)
    }

    // MARK: - The running app

    /// The app delegate starts the shared router listening to the default
    /// center at launch, where the menus, readers, and imports post their
    /// app-wide actions.
    func testTheAppRoutesActionsPostedOnTheDefaultCenter() {
        XCTAssertTrue(LibraryWindowRouter.shared.listenedCenter === NotificationCenter.default)
    }
}

/// Which window a routing test makes key.
private enum KeyWindowChoice {
    /// No window is key.
    case noWindow
    /// The Library window at this index.
    case library(Int)
    /// The reader window at this index.
    case reader(Int)
}

/// A router whose clock, key window, and later work a test controls. It
/// listens on a private notification center, counts the Library windows the
/// router asks for instead of opening any, and records what each window it
/// registers takes.
@MainActor
private final class RouterHarness {
    /// The time the router sees.
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    /// The window the router sees as key.
    var keyWindow: NSWindow?
    /// The center the router takes actions from, private to the test, so
    /// the running app's windows never see them.
    let notifications = NotificationCenter()
    /// How many Library windows the router asked for.
    private(set) var libraryWindowRequests = 0
    /// What the windows took, in order (`taking(of:by:)`).
    private(set) var takings: [String] = []
    /// The router under test.
    private(set) var router: LibraryWindowRouter!
    /// Work the router scheduled and has not run yet, with when it falls due.
    private var scheduled: [(due: Date, work: @MainActor @Sendable () -> Void)] = []
    /// The windows made here, kept alive because the router holds windows
    /// weakly.
    private var windows: [NSWindow] = []

    init() {
        router = LibraryWindowRouter(
            now: { [unowned self] in self.now },
            keyWindow: { [unowned self] in self.keyWindow },
            schedule: { [unowned self] delay, work in
                self.scheduled.append((self.now.addingTimeInterval(delay), work))
            }
        )
        router.openLibraryWindow = { [unowned self] in
            self.libraryWindowRequests += 1
            return true
        }
        router.listen(to: notifications)
    }

    /// Creates a lightweight titled window without displaying it.
    static func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    /// How a taking is recorded: the action a Library window took, or, for
    /// a reader window, the book it opened.
    static func taking(of action: GlobalAction, by taker: String) -> String {
        if taker.hasPrefix("reader"), let bookID = action.bookToOpen {
            return "\(taker): opened \(bookID)"
        }
        return "\(taker): \(action)"
    }

    /// Registers a new Library window named `name`, which records each
    /// action it takes.
    @discardableResult
    func addLibraryWindow(named name: String) -> NSWindow {
        let window = Self.makeWindow()
        windows.append(window)
        router.register(window) { [unowned self] action in
            self.takings.append(Self.taking(of: action, by: name))
        }
        return window
    }

    /// Registers a new reader window named `name`, which records each book
    /// it opens.
    @discardableResult
    func addReaderWindow(named name: String) -> NSWindow {
        let window = Self.makeWindow()
        windows.append(window)
        router.registerReaderWindow(window) { [unowned self] bookID in
            self.takings.append("\(name): opened \(bookID)")
        }
        return window
    }

    /// Records a taking described by the test itself.
    func note(_ taking: String) {
        takings.append(taking)
    }

    /// Posts a notification on the router's center.
    func post(_ name: Notification.Name, object: Any? = nil, userInfo: [AnyHashable: Any]? = nil) {
        notifications.post(name: name, object: object, userInfo: userInfo)
    }

    /// Runs every piece of scheduled work that has fallen due, in the order
    /// it was scheduled, including any it schedules in turn.
    func runDueWork() {
        while let index = scheduled.firstIndex(where: { $0.due <= now }) {
            let item = scheduled.remove(at: index)
            item.work()
        }
    }

    /// Moves the clock on by `seconds`, then runs the work fallen due.
    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
        runDueWork()
    }
}
