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
        XCTAssertNil(GlobalAction.newFromText.bookToOpen)
        XCTAssertNil(GlobalAction.importDAISYFolder.bookToOpen)
        XCTAssertNil(GlobalAction.goToLibrary.bookToOpen)
        XCTAssertNil(GlobalAction.openFiles([URL(fileURLWithPath: "/Books/Volume.epub")]).bookToOpen)
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
        let finderItems = [URL(fileURLWithPath: "/Books/Volume.epub")]
        let actionsNeedingALibrary: [GlobalAction] = [
            .openBookFile, .newFromText, .importDAISYFolder, .goToLibrary, .openFiles(finderItems),
        ]
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
            (Notification(name: .newFromText), .newFromText),
            (Notification(name: .importDAISYFolder), .importDAISYFolder),
            (Notification(name: .goToLibrary), .goToLibrary),
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
        // The keyboard shortcut's notification names its source window, and
        // asks for the same action as the menu command's.
        let shortcutSource = makeWindow()
        XCTAssertEqual(
            GlobalAction(notification: Notification(
                name: .goToLibrary,
                object: nil,
                userInfo: ["sourceWindow": shortcutSource]
            )),
            .goToLibrary
        )
        XCTAssertNil(GlobalAction(notification: Notification(name: .openBookWindow)))
        XCTAssertNil(GlobalAction(notification: Notification(name: .openBookWindow, object: "not a book")))
        XCTAssertNil(GlobalAction(notification: Notification(name: .continueToNextBook)))
        XCTAssertNil(GlobalAction(notification: Notification(name: .goBack)))
    }

    /// Every app-wide action is taken exactly once, in every window
    /// arrangement TODO A05 names, however many Library windows are open:
    /// by the one Library window the decision names, by a reader window, or,
    /// when no open window can take it, by the one Library window opened for
    /// it once that window registers. Each action arrives as it does in the
    /// app: posted on the router's center, or, for items opened from Finder,
    /// handed over by the app delegate.
    func testEveryActionIsTakenExactlyOnceInEveryArrangement() {
        let book = UUID()
        let finderItems = [URL(fileURLWithPath: "/Books/Volume.epub")]
        let deliveries: [(action: GlobalAction, deliver: (RouterHarness) -> Void)] = [
            (.openBookFile, { $0.post(.openBookFile) }),
            (.newFromText, { $0.post(.newFromText) }),
            (.importDAISYFolder, { $0.post(.importDAISYFolder) }),
            (.goToLibrary, { $0.post(.goToLibrary) }),
            (.openBookWindow(book), { $0.post(.openBookWindow, object: book) }),
            (
                .continueToNextBook(book),
                { $0.post(.continueToNextBook, userInfo: [Notification.ContinueToNextBookKey.bookID: book]) }
            ),
            (.openFiles(finderItems), { $0.router.route(.openFiles(finderItems)) }),
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
            for delivery in deliveries {
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

                delivery.deliver(harness)
                // Items from Finder wait a little longer for a window.
                harness.advance(by: LibraryWindowRouter.finderOpenGracePeriod)
                // When the action waits, the Library window it asked for
                // opens and registers.
                if harness.libraryWindowRequests > 0 {
                    harness.addLibraryWindow(named: "new Library")
                    harness.runDueWork()
                }

                let action = delivery.action
                let taker = action.bookToOpen == nil ? arrangement.libraryActionTaker : arrangement.readerActionTaker
                let context = "\(arrangement.name): \(action)"
                XCTAssertEqual(harness.takings, [RouterHarness.taking(of: action, by: taker)], context)
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

    // MARK: - Items opened from Finder

    /// Items opened from Finder on a cold launch, before any Library window
    /// has registered, wait for the first Library window SwiftUI opens
    /// without asking for another, and are imported once, by that window: a
    /// Library window registering after it imports nothing. They arrive
    /// through the app delegate.
    func testItemsOpenedFromFinderAtLaunchAreImportedOnceByTheFirstLibraryWindow() {
        let harness = RouterHarness()
        let appDelegate = AppDelegate()
        appDelegate.router = harness.router
        let items = [
            URL(fileURLWithPath: "/Books/First Volume.epub"),
            URL(fileURLWithPath: "/Books/Second Volume.txt"),
        ]
        harness.router.expectLibraryWindow()

        appDelegate.application(NSApp, open: items)
        harness.advance(by: LibraryWindowRouter.finderOpenGracePeriod)
        XCTAssertEqual(harness.libraryWindowRequests, 0)
        XCTAssertEqual(harness.router.waitingActions, [.openFiles(items)])

        harness.addLibraryWindow(named: "first Library")
        harness.runDueWork()
        harness.addLibraryWindow(named: "second Library")
        harness.runDueWork()

        XCTAssertEqual(harness.takings, ["first Library: \(GlobalAction.openFiles(items))"])
        XCTAssertEqual(harness.libraryWindowRequests, 0)
    }

    /// Items opened from Finder with no Library window registered wait for
    /// the one SwiftUI shows for them. Only when none has registered by the
    /// end of the grace period does the router ask for one, which then
    /// imports them.
    func testItemsOpenedFromFinderAskForALibraryWindowOnlyAfterTheGracePeriod() {
        let harness = RouterHarness()
        let items = [URL(fileURLWithPath: "/Books/Volume.epub")]

        harness.router.route(.openFiles(items))
        harness.advance(by: LibraryWindowRouter.finderOpenGracePeriod - 0.5)
        XCTAssertEqual(harness.libraryWindowRequests, 0)
        harness.advance(by: 0.5)
        XCTAssertEqual(harness.libraryWindowRequests, 1)

        harness.addLibraryWindow(named: "Library")
        harness.runDueWork()
        XCTAssertEqual(harness.takings, ["Library: \(GlobalAction.openFiles(items))"])
    }

    /// While only readers are open, items opened from Finder go to the
    /// Library window SwiftUI shows for them, and no other is asked for.
    func testItemsOpenedFromFinderGoToTheLibraryWindowSwiftUIShows() {
        let harness = RouterHarness()
        harness.keyWindow = harness.addReaderWindow(named: "reader")
        let items = [URL(fileURLWithPath: "/Books/Volume.epub")]

        harness.router.route(.openFiles(items))
        harness.runDueWork()
        harness.addLibraryWindow(named: "Library SwiftUI shows")
        harness.advance(by: LibraryWindowRouter.finderOpenGracePeriod)

        XCTAssertEqual(harness.takings, ["Library SwiftUI shows: \(GlobalAction.openFiles(items))"])
        XCTAssertEqual(harness.libraryWindowRequests, 0)
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

    // MARK: - Diagnostics

    /// What goes wrong in routing reaches the debug log as an event,
    /// written while tracing is off: a Library window that could not be
    /// opened, and an action dropped after waiting too long. The routine
    /// line of the action starting to wait is trace, so it is not written.
    /// A book is named by the first eight characters of its ID.
    func testRoutingFailuresAreEventsAndTheRoutinePathIsNot() throws {
        try XCTSkipIf(
            DiagnosticLog.TraceSwitch.environmentTurnsTracingOn(ProcessInfo.processInfo.environment),
            "TEXTMOUTH_TRACE_LOG turns tracing on for this whole run"
        )
        try TextMouthPaths.ensureDirectoryStructure()
        setAppTracing(false)
        let harness = RouterHarness()
        harness.router.openLibraryWindow = { false }
        let book = UUID()
        let action = GlobalAction.openBookWindow(book)

        let lines = routingLines(naming: action) {
            harness.router.route(action)
            harness.runDueWork()
            // Past its lifetime the action is dropped when the next action
            // asks for a Library window.
            harness.advance(by: PendingGlobalActions.lifetime + 1)
            harness.router.route(.goToLibrary)
            harness.runDueWork()
        }

        let named = "open book \(book.uuidString.prefix(8))"
        XCTAssertEqual(action.logDescription, named)
        XCTAssertEqual(lines, [
            "app-wide action: could not open a Library window for \(named)",
            "app-wide action: \(named) waited too long for a Library window and was dropped",
        ])
    }

    /// While tracing is on, the routine path is written too, as trace of
    /// the app category: the action starting to wait, and the Library
    /// window opened for it.
    func testRoutinePathIsAppTraceWhileTracing() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        setAppTracing(true)
        let harness = RouterHarness()
        let action = GlobalAction.openBookWindow(UUID())

        let lines = routingLines(naming: action) {
            harness.router.route(action)
            harness.runDueWork()
        }

        XCTAssertEqual(harness.libraryWindowRequests, 1)
        XCTAssertEqual(lines, [
            "TRACE app: app-wide action: no open window can take \(action.logDescription); it waits for a Library window",
            "TRACE app: app-wide action: opened a Library window for \(action.logDescription)",
        ])
    }

    // MARK: - The running app

    /// The app delegate starts the shared router listening to the default
    /// center at launch, where the menus, readers, and imports post their
    /// app-wide actions.
    func testTheAppRoutesActionsPostedOnTheDefaultCenter() {
        XCTAssertTrue(LibraryWindowRouter.shared.listenedCenter === NotificationCenter.default)
    }

    /// The app delegate gives the shared router SwiftUI's way of opening a
    /// Library window, and in the running app it opens exactly one, shown
    /// and registered with the router. The window is closed again before
    /// the test ends.
    func testTheAppOpensExactlyOneRegisteredLibraryWindow() {
        let router = LibraryWindowRouter.shared
        let registeredBefore = router.registeredLibraryWindows
        let shownBefore = Self.shownLibraryWindows()
        /// The Library windows registered since the test began.
        func newlyRegistered() -> [NSWindow] {
            router.registeredLibraryWindows.filter { window in !registeredBefore.contains { $0 === window } }
        }
        defer { closeLibraryWindows(except: shownBefore, registeredBefore: registeredBefore) }

        XCTAssertTrue(router.openLibraryWindow())

        XCTAssertTrue(waitUntil(timeout: 5) { !newlyRegistered().isEmpty }, "No Library window registered")
        let opened = newlyRegistered()
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(Self.shownLibraryWindows().count, shownBefore.count + 1)
        if let window = opened.first {
            XCTAssertTrue(window.isVisible)
            XCTAssertEqual(MenuVisibilityManager.detectWindowType(for: window), .library)
        }
    }

    /// A Library window that closes unregisters, and registers again when
    /// it is shown again, as it is when SwiftUI shows it for a book opened
    /// from Finder. The window is closed again before the test ends.
    func testALibraryWindowShownAgainRegistersAgain() throws {
        let router = LibraryWindowRouter.shared
        let registeredBefore = router.registeredLibraryWindows
        let shownBefore = Self.shownLibraryWindows()
        defer { closeLibraryWindows(except: shownBefore, registeredBefore: registeredBefore) }
        XCTAssertTrue(router.openLibraryWindow())
        XCTAssertTrue(waitUntil(timeout: 5) { router.registeredLibraryWindows.count > registeredBefore.count })
        let window = try XCTUnwrap(router.registeredLibraryWindows.first { candidate in
            !registeredBefore.contains { $0 === candidate }
        })

        window.close()
        XCTAssertTrue(waitUntil(timeout: 5) { !router.registeredLibraryWindows.contains { $0 === window } })
        window.orderFront(nil)

        XCTAssertTrue(
            waitUntil(timeout: 5) { router.registeredLibraryWindows.contains { $0 === window } },
            "The Library window shown again did not register again"
        )
    }

    /// With every Library window closed and the app still running, an
    /// app-wide action opens one Library window through SwiftUI, and that
    /// window takes the action once it has registered: the whole chain in
    /// the running app, through the shared router, the app delegate's way
    /// of opening a window, and the Library window's own action. Go to
    /// Library is the action, since it presents nothing. Before the test
    /// ends, the window it opened is closed and the app's own Library
    /// windows are shown and registered again.
    func testWithEveryLibraryWindowClosedAnActionOpensOneThatTakesIt() throws {
        let router = LibraryWindowRouter.shared
        let shownBefore = Self.shownLibraryWindows()
        let registeredBefore = router.registeredLibraryWindows
        guard !shownBefore.isEmpty, !registeredBefore.isEmpty else {
            throw XCTSkip("This run has no Library window open to close")
        }
        defer {
            for window in Self.shownLibraryWindows() where !shownBefore.contains(where: { $0 === window }) {
                window.close()
            }
            for window in shownBefore {
                window.orderFront(nil)
            }
            XCTAssertTrue(waitUntil(timeout: 5) {
                registeredBefore.allSatisfy { window in router.registeredLibraryWindows.contains { $0 === window } }
                    && router.registeredLibraryWindows.count == registeredBefore.count
            }, "The app's own Library windows did not register again")
        }
        for window in shownBefore {
            window.close()
        }
        XCTAssertTrue(waitUntil(timeout: 5) { !router.hasRegisteredWindow }, "A closed Library window stayed registered")

        router.route(.goToLibrary)

        XCTAssertTrue(
            waitUntil(timeout: 5) { router.hasRegisteredWindow && router.waitingActions.isEmpty },
            "No Library window opened and took the action"
        )
        let opened = router.registeredLibraryWindows
        XCTAssertEqual(opened.count, 1)
        let openedWindow = try XCTUnwrap(opened.first)
        XCTAssertFalse(shownBefore.contains { $0 === openedWindow })
        XCTAssertEqual(Array(router.recordedDecisions.suffix(2)), [
            GlobalActionDecision(action: .goToLibrary, handler: .newLibraryWindow),
            GlobalActionDecision(action: .goToLibrary, handler: .libraryWindow(openedWindow)),
        ])
    }

    /// The running app's File menu offers no way to open a reader without a
    /// book: New Window (Command-N) opens a Library window, and nothing opens
    /// the Book Reader scene. Open Book... and New from Text... stay enabled,
    /// since the router takes them whichever window is key, opening a
    /// Library window when none is open. The items are only read, never
    /// chosen. Skipped when this run's menu bar has no File menu.
    func testFileMenuOffersNoReaderWithoutABook() throws {
        guard let fileMenu = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu else {
            throw XCTSkip("This run's menu bar has no File menu")
        }
        let items = Self.allItems(of: fileMenu)
        let titles = items.map(\.title)

        XCTAssertFalse(titles.contains("New Book Reader Window"), "The File menu holds \(titles)")
        let newWindow = try XCTUnwrap(
            items.first { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == [.command] },
            "The File menu holds \(titles)"
        )
        XCTAssertEqual(newWindow.title, "New Window")
        for title in ["Open Book...", "New from Text..."] {
            let item = try XCTUnwrap(items.first { $0.title == title }, "The File menu holds \(titles)")
            XCTAssertTrue(item.isEnabled, title)
        }
    }

    /// Every item of `menu` and of the menus inside it, each menu brought up
    /// to date first, as it is before it opens.
    private static func allItems(of menu: NSMenu?) -> [NSMenuItem] {
        guard let menu else { return [] }
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu.items.flatMap { [$0] + allItems(of: $0.submenu) }
    }

    /// The app's Library windows on screen or minimized.
    private static func shownLibraryWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            (window.isVisible || window.isMiniaturized)
                && MenuVisibilityManager.detectWindowType(for: window) == .library
        }
    }

    /// Closes every Library window on screen that is not one of `shown`,
    /// and waits until the router has let go of all but `registeredBefore`.
    private func closeLibraryWindows(except shown: [NSWindow], registeredBefore: [NSWindow]) {
        for window in Self.shownLibraryWindows() where !shown.contains(where: { $0 === window }) {
            window.close()
        }
        XCTAssertTrue(waitUntil(timeout: 5) {
            LibraryWindowRouter.shared.registeredLibraryWindows.count == registeredBefore.count
        }, "A Library window the test opened is still registered")
    }

    /// The debug log's lines written while `body` runs that name `action`
    /// by its `logDescription`, each without the timestamp before its
    /// first ": ".
    private func routingLines(naming action: GlobalAction, during body: () -> Void) -> [String] {
        logLines(in: .debug, writtenDuring: body)
            .filter { $0.contains(action.logDescription) }
            .compactMap { line in line.range(of: ": ").map { String(line[$0.upperBound...]) } }
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

    /// Runs every piece of scheduled work that has fallen due, the earliest
    /// due first and work due at the same moment in the order it was
    /// scheduled, as the main queue would, including any it schedules in
    /// turn.
    func runDueWork() {
        while let index = scheduled.indices
            .filter({ scheduled[$0].due <= now })
            .min(by: { scheduled[$0].due < scheduled[$1].due }) {
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
