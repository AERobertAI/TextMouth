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

    func testCommandPanelShortcutWorksFromTextInput() {
        let binding = KeyBinding(key: "t", command: true, shift: true)

        XCTAssertTrue(KeyboardShortcutManager.shouldHandle(
            binding: binding,
            whenTextInputIsFocused: true
        ))
    }

    func testPlainLetterShortcutDoesNotInterruptTextInput() {
        let binding = KeyBinding(key: "w")

        XCTAssertFalse(KeyboardShortcutManager.shouldHandle(
            binding: binding,
            whenTextInputIsFocused: true
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

    /// F and B provide quick, unmodified cycling while text-field focus policy
    /// still prevents either key from interrupting typing.
    func testNavigationUnitCycleShortcutsDefaultToPlainFAndB() {
        XCTAssertEqual(
            ShortcutAction.defaultBindings[.cycleForwardNavigationUnit],
            [KeyBinding(key: "f")]
        )
        XCTAssertEqual(
            ShortcutAction.defaultBindings[.cycleBackwardNavigationUnit],
            [KeyBinding(key: "b")]
        )
    }

    /// Keyboard cycling follows the picker order and wraps continuously.
    func testNavigationUnitCyclingUsesPickerOrderAndWraps() {
        for (current, next) in zip(SkipUnit.allCases, SkipUnit.allCases.dropFirst()) {
            XCTAssertEqual(current.nextNavigationUnit, next)
        }
        XCTAssertEqual(SkipUnit.bookmark.nextNavigationUnit, .seconds10)
    }

    /// Adding F/B defaults in an upgrade must never steal a binding that the
    /// user already assigned to an older action.
    func testNewShortcutDefaultsDoNotDuplicateLegacyCustomBindings() throws {
        let defaults = makeSandboxedPreferences("shortcuts")
        let existingForwardBinding = KeyBinding(key: "f")
        let saved = [
            ShortcutAction.whereAmI.rawValue: [existingForwardBinding],
        ]
        defaults.set(try JSONEncoder().encode(saved), forKey: "customKeyboardBindings")

        let manager = KeyboardShortcutManager(
            userDefaults: defaults,
            installsEventMonitor: false
        )

        XCTAssertEqual(manager.bindingsFor(.whereAmI), [existingForwardBinding])
        XCTAssertTrue(manager.bindingsFor(.cycleForwardNavigationUnit).isEmpty)
        XCTAssertEqual(
            manager.bindingsFor(.cycleBackwardNavigationUnit),
            [KeyBinding(key: "b")]
        )
    }

    func testAddingBindingRemovesItFromPreviousAction() throws {
        let defaults = makeSandboxedPreferences("shortcuts")
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
        let defaults = makeSandboxedPreferences("shortcuts")
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
