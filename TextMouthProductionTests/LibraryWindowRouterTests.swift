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
}
