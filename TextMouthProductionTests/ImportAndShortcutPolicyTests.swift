import XCTest
@testable import TextMouth

@MainActor
final class ImportAndShortcutPolicyTests: XCTestCase {
    func testTextImportDefaultTitleUsesExpectedFormat() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(TextImportPolicy.defaultTitle(for: date).hasPrefix("Paste "))
        XCTAssertEqual(TextImportPolicy.defaultTitle(for: date).count, "Paste yyyy-MM-dd HH:mm".count)
    }

    func testTextImportRejectsEmptyText() {
        XCTAssertFalse(TextImportPolicy.canAdd(text: ""))
    }

    func testTextImportRejectsWhitespaceOnlyText() {
        XCTAssertFalse(TextImportPolicy.canAdd(text: " \n\t "))
    }

    func testTextImportAcceptsPlainText() {
        XCTAssertTrue(TextImportPolicy.canAdd(text: "A complete paragraph."))
        XCTAssertEqual(TextImportPolicy.resolvedTitle(""), "Untitled")
    }

    func testTextImportSanitizesFilenameWithoutChangingTitle() {
        let title = "My/Book:Title?"
        XCTAssertEqual(TextImportPolicy.textFilename(for: title), "My-Book-Title.txt")
        XCTAssertEqual(TextImportPolicy.resolvedTitle(title), title)
    }

    func testSecondarySkipDefaultsAreThirtySeconds() {
        XCTAssertEqual(SkipUnit.seconds30.rawValue, "30 seconds")
    }

    func testExtraShiftIsDetectedWhenBindingDoesNotRequireIt() {
        XCTAssertTrue(KeyboardShortcutManager.hasExtraShift(
            eventHasShift: true, bindingRequiresShift: false
        ))
    }

    func testExtraShiftIsNotDetectedWhenBindingAlreadyRequiresIt() {
        XCTAssertFalse(KeyboardShortcutManager.hasExtraShift(
            eventHasShift: true, bindingRequiresShift: true
        ))
    }

    func testExtraShiftIsNotDetectedWhenShiftIsUp() {
        XCTAssertFalse(KeyboardShortcutManager.hasExtraShift(
            eventHasShift: false, bindingRequiresShift: false
        ))
    }

    func testSkipUnitSelectionChoosesPrimaryOrSecondary() {
        XCTAssertEqual(ReaderViewModel.selectedSkipUnit(
            primary: .seconds15, secondary: .heading, useSecondary: false
        ), .seconds15)
        XCTAssertEqual(ReaderViewModel.selectedSkipUnit(
            primary: .seconds15, secondary: .heading, useSecondary: true
        ), .heading)
    }

    func testAddingBindingRemovesItFromPreviousAction() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let manager = KeyboardShortcutManager(
            userDefaults: defaults,
            installsEventMonitor: false
        )
        let binding = KeyBinding(key: "k")
        XCTAssertTrue(manager.bindingsFor(.togglePlayback).contains(binding))

        manager.addBinding(binding, to: .skipForward)

        XCTAssertFalse(manager.bindingsFor(.togglePlayback).contains(binding))
        XCTAssertTrue(manager.bindingsFor(.skipForward).contains(binding))
    }

    func testRemovingAllBindingsLeavesActionUnassigned() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let manager = KeyboardShortcutManager(
            userDefaults: defaults,
            installsEventMonitor: false
        )

        manager.updateBindings(for: .whereAmI, to: [])

        XCTAssertTrue(manager.bindingsFor(.whereAmI).isEmpty)
        XCTAssertEqual(manager.primaryDisplayString(for: .whereAmI), "None")
        XCTAssertEqual(manager.allDisplayStrings(for: .whereAmI), "No shortcut")
    }

    func testModifierDisplayOrderIsControlOptionShiftCommand() {
        let binding = KeyBinding(
            key: "a",
            command: true,
            option: true,
            shift: true,
            control: true
        )

        XCTAssertEqual(binding.displayString, "⌃⌥⇧⌘A")
        XCTAssertEqual(
            binding.accessibleDisplayString,
            "Control + Option + Shift + Command + A"
        )
    }
}
