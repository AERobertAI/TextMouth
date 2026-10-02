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
}
