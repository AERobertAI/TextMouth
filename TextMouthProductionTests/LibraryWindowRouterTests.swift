import AppKit
import XCTest
@testable import TextMouth

@MainActor
final class LibraryWindowRouterTests: XCTestCase {
    /// Creates a lightweight titled window without displaying it.
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

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

    func testRouterAllowsOnlyOneRegisteredLibraryToHandleAction() {
        let router = LibraryWindowRouter()
        let firstLibrary = makeWindow()
        let secondLibrary = makeWindow()
        router.register(firstLibrary)
        router.register(secondLibrary)

        XCTAssertTrue(router.shouldHandleGlobalAction(in: firstLibrary))
        XCTAssertFalse(router.shouldHandleGlobalAction(in: secondLibrary))
    }

    func testRouterFallsBackToUnregisteredSceneOnlyWhenRegistryIsEmpty() {
        let router = LibraryWindowRouter()
        let existingLibrary = makeWindow()

        XCTAssertTrue(router.shouldHandleGlobalAction(in: nil))
        router.register(existingLibrary)
        XCTAssertFalse(router.shouldHandleGlobalAction(in: nil))
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

    // MARK: - Continue to Next Book

    /// Who opens the next book's reader in each window arrangement: the key
    /// Library window; otherwise the first Library window, even while a
    /// reader is key; and only with no Library window at all, the app
    /// delegate's fallback.
    func testContinueToNextBookOpenerInEachWindowArrangement() {
        let firstLibrary = makeWindow()
        let secondLibrary = makeWindow()
        let reader = makeWindow()
        let libraries = [firstLibrary, secondLibrary]

        // A Library window is key.
        XCTAssertTrue(
            LibraryWindowRouter.continueToNextBookOpener(libraryWindows: libraries, keyWindow: secondLibrary)
                .isLibraryWindow(secondLibrary)
        )
        // Library windows are open, but none is key.
        XCTAssertTrue(
            LibraryWindowRouter.continueToNextBookOpener(libraryWindows: libraries, keyWindow: nil)
                .isLibraryWindow(firstLibrary)
        )
        // A reader window is key.
        XCTAssertTrue(
            LibraryWindowRouter.continueToNextBookOpener(libraryWindows: libraries, keyWindow: reader)
                .isLibraryWindow(firstLibrary)
        )
        // No Library window is open, whatever is key.
        for keyWindow in [reader, nil] {
            let opener = LibraryWindowRouter.continueToNextBookOpener(libraryWindows: [], keyWindow: keyWindow)
            guard case .appFallback = opener else {
                return XCTFail("No Library window is open, yet one was chosen")
            }
        }
    }

    /// Exactly one registered Library window opens the next book's reader,
    /// whichever window is key, and the app delegate's fallback never does
    /// while one is registered.
    func testExactlyOneRegisteredLibraryOpensTheContinuedBook() {
        let router = LibraryWindowRouter()
        let firstLibrary = makeWindow()
        let secondLibrary = makeWindow()
        let reader = makeWindow()
        router.register(firstLibrary)
        router.register(secondLibrary)
        let libraries: [NSWindow] = [firstLibrary, secondLibrary]
        let arrangements: [(name: String, keyWindow: NSWindow?, opener: NSWindow)] = [
            ("Library key", secondLibrary, secondLibrary),
            ("nothing key", nil, firstLibrary),
            ("reader key", reader, firstLibrary),
        ]

        for arrangement in arrangements {
            let openers = libraries.filter {
                router.shouldOpenContinuedBook(in: $0, keyWindow: arrangement.keyWindow)
            }
            XCTAssertEqual(openers.count, 1, arrangement.name)
            XCTAssertTrue(openers.first === arrangement.opener, arrangement.name)
            if case .appFallback = router.continueToNextBookOpener(keyWindow: arrangement.keyWindow) {
                XCTFail("The fallback was chosen as well: \(arrangement.name)")
            }
        }
    }

    /// A Library scene that has not supplied its window never opens the
    /// next book's reader, whether or not another Library is registered;
    /// with none registered, the app delegate's fallback opens it instead.
    func testUnregisteredLibrarySceneNeverOpensTheContinuedBook() {
        let router = LibraryWindowRouter()

        XCTAssertFalse(router.shouldOpenContinuedBook(in: nil, keyWindow: nil))
        guard case .appFallback = router.continueToNextBookOpener(keyWindow: nil) else {
            return XCTFail("No Library is registered, yet the fallback was not chosen")
        }

        let library = makeWindow()
        router.register(library)
        XCTAssertFalse(router.shouldOpenContinuedBook(in: nil, keyWindow: nil))
        XCTAssertTrue(router.shouldOpenContinuedBook(in: library, keyWindow: nil))
    }

    /// Once its only Library window closes, the next book's reader is left
    /// to the app delegate's fallback.
    func testClosingTheLastLibraryLeavesTheContinuedBookToTheFallback() {
        let router = LibraryWindowRouter()
        let library = makeWindow()
        router.register(library)

        router.unregister(library)

        XCTAssertFalse(router.shouldOpenContinuedBook(in: library, keyWindow: library))
        guard case .appFallback = router.continueToNextBookOpener(keyWindow: library) else {
            return XCTFail("A closed Library window was still chosen")
        }
    }

    /// In every window arrangement exactly one receiver opens the next
    /// book's reader: one Library window or, when no Library window is
    /// open, the app delegate's fallback, through a reader window.
    func testExactlyOneReceiverOpensTheContinuedBookInEveryArrangement() {
        let firstLibrary = makeWindow()
        let secondLibrary = makeWindow()
        let reader = makeWindow()
        let book = UUID()
        let arrangements: [(name: String, libraries: [NSWindow], keyWindow: NSWindow?)] = [
            ("Library window key", [firstLibrary, secondLibrary], secondLibrary),
            ("Library windows open, none key", [firstLibrary, secondLibrary], nil),
            ("reader window key", [firstLibrary, secondLibrary], reader),
            ("no Library window, reader key", [], reader),
            ("no Library window, none key", [], nil),
        ]

        for arrangement in arrangements {
            let router = LibraryWindowRouter()
            for library in arrangement.libraries {
                router.register(library)
            }
            var openedThroughReader: [UUID] = []
            router.registerReaderWindow(reader) { openedThroughReader.append($0) }

            let libraryOpeners = arrangement.libraries.filter {
                router.shouldOpenContinuedBook(in: $0, keyWindow: arrangement.keyWindow)
            }
            let fallbackOpened = AppDelegate.openContinuedBookIfNoLibraryWindow(
                book,
                router: router,
                keyWindow: arrangement.keyWindow
            )

            XCTAssertEqual(libraryOpeners.count + (fallbackOpened ? 1 : 0), 1, arrangement.name)
            XCTAssertEqual(fallbackOpened, arrangement.libraries.isEmpty, arrangement.name)
            XCTAssertEqual(openedThroughReader, fallbackOpened ? [book] : [], arrangement.name)
        }
    }

    /// With no window open at all, the fallback has nothing to open the
    /// next book's reader through.
    func testFallbackOpensNothingWithoutAnyWindow() {
        XCTAssertFalse(
            AppDelegate.openContinuedBookIfNoLibraryWindow(
                UUID(),
                router: LibraryWindowRouter(),
                keyWindow: nil
            )
        )
    }

    // MARK: - Reader windows

    /// A reader opens through the key window when it is a reader window,
    /// and otherwise through the reader window registered most recently.
    func testReaderOpensThroughTheKeyReaderWindowFirst() {
        let router = LibraryWindowRouter()
        let olderReader = makeWindow()
        let newerReader = makeWindow()
        var opened: [(through: String, bookID: UUID)] = []
        router.registerReaderWindow(olderReader) { opened.append(("older", $0)) }
        router.registerReaderWindow(newerReader) { opened.append(("newer", $0)) }
        let book = UUID()

        XCTAssertTrue(router.openReaderWindow(for: book, keyWindow: olderReader))
        XCTAssertTrue(router.openReaderWindow(for: book, keyWindow: nil))
        XCTAssertTrue(router.openReaderWindow(for: book, keyWindow: makeWindow()))

        XCTAssertEqual(opened.map(\.through), ["older", "newer", "newer"])
        XCTAssertEqual(opened.map(\.bookID), [book, book, book])
    }

    /// Registering a reader window again replaces its action instead of
    /// adding a second one.
    func testRegisteringAReaderWindowAgainReplacesItsAction() {
        let router = LibraryWindowRouter()
        let reader = makeWindow()
        var calls: [String] = []
        router.registerReaderWindow(reader) { _ in calls.append("first") }
        router.registerReaderWindow(reader) { _ in calls.append("second") }

        router.openReaderWindow(for: UUID(), keyWindow: reader)
        router.openReaderWindow(for: UUID(), keyWindow: nil)

        XCTAssertEqual(calls, ["second", "second"])
    }

    /// With no reader window open, or only one that has since closed,
    /// nothing can open a reader.
    func testNoOpenReaderWindowLeavesNothingToOpenThrough() {
        let router = LibraryWindowRouter()
        XCTAssertFalse(router.openReaderWindow(for: UUID(), keyWindow: nil))

        let reader = makeWindow()
        var calls = 0
        router.registerReaderWindow(reader) { _ in calls += 1 }
        router.unregisterReaderWindow(reader)

        XCTAssertFalse(router.openReaderWindow(for: UUID(), keyWindow: reader))
        XCTAssertEqual(calls, 0)
    }

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

    // MARK: - Who takes an app-wide action (TODO A05)

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
}
