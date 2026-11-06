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

    /// Paste from Clipboard changes nothing, and so says so, when the
    /// clipboard holds no text (nil) or an empty string.
    func testPasteFromAnEmptyClipboardIsRefusedWithAWordToSay() {
        XCTAssertNil(TextImportPolicy.pastedText(fromClipboard: nil))
        XCTAssertNil(TextImportPolicy.pastedText(fromClipboard: ""))
        XCTAssertEqual(TextImportPolicy.pastedText(fromClipboard: " \n"), " \n", "blanks are text, and paste as they are")
        XCTAssertEqual(TextImportPolicy.pastedText(fromClipboard: "A page."), "A page.")
        XCTAssertTrue(TextImportPolicy.noClipboardTextAnnouncement.contains("no text"))
    }

    /// Reload from Editor reads what an editor saved in the encoding the
    /// editor chose, not only UTF-8, and gives nil, so the view says so,
    /// when the file cannot be read.
    func testReloadFromEditorReadsTheEncodingTheEditorSavedIn() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReloadFromEditor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        func saved(_ name: String, _ bytes: Data) throws -> URL {
            let url = folder.appendingPathComponent(name)
            try bytes.write(to: url)
            return url
        }

        let utf8 = try saved("utf8.txt", Data("Caf\u{E9} au lait\n".utf8))
        XCTAssertEqual(TextImportPolicy.reloadedText(from: utf8), "Caf\u{E9} au lait\n")

        // An editor that saves UTF-16 with a byte-order mark.
        let utf16 = try saved("utf16.txt", Data([0xFF, 0xFE]) + (try XCTUnwrap("Caf\u{E9}\n".data(using: .utf16LittleEndian))))
        XCTAssertEqual(TextImportPolicy.reloadedText(from: utf16), "Caf\u{E9}\n")

        // An editor that saves Windows-1252: a lone E9 byte is not valid UTF-8.
        let windows = try saved("windows.txt", Data([0x43, 0x61, 0x66, 0xE9, 0x0A]))
        XCTAssertEqual(TextImportPolicy.reloadedText(from: windows), "Caf\u{E9}\n")

        XCTAssertNil(TextImportPolicy.reloadedText(from: folder.appendingPathComponent("missing.txt")))
        XCTAssertTrue(TextImportPolicy.reloadFailedAnnouncement.contains("unchanged"))
        XCTAssertTrue(TextImportPolicy.editorOpenFailedAnnouncement.hasSuffix("try again."))
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
    /// user already assigned to an older action: the record of the user's
    /// edits (FR12) keeps F on Where Am I?, and a whole map saved before the
    /// cycling actions existed moves to such a record.
    func testNewShortcutDefaultsDoNotDuplicateLegacyCustomBindings() throws {
        let defaults = makeSandboxedPreferences("shortcuts")
        let existingForwardBinding = KeyBinding(key: "f")
        let moved = ShortcutEdits.migrating(savedMap: [.whereAmI: [existingForwardBinding]], fileLists: nil)
        XCTAssertEqual(moved.edits, ShortcutEdits([.whereAmI: [existingForwardBinding]]))
        KeyboardShortcutManager.editsPreference.write(moved.edits, to: defaults)

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

    // MARK: - Shortcuts as config.json writes them

    /// config.json writes a shortcut's modifiers in the order Settings shows
    /// them, then its key, joined by "+".
    func testConfigTextNamesModifiersInSettingsOrderThenTheKey() {
        XCTAssertEqual(KeyBinding(key: "space").configText, "space")
        XCTAssertEqual(KeyBinding(key: "rightArrow", command: true).configText, "command+rightArrow")
        XCTAssertEqual(
            KeyBinding(key: "b", command: true, option: true, shift: true).configText,
            "option+shift+command+b"
        )
        XCTAssertEqual(
            KeyBinding(key: "a", command: true, option: true, shift: true, control: true).configText,
            "control+option+shift+command+a"
        )
        XCTAssertEqual(KeyBinding(key: "+", command: true).configText, "command++")
    }

    /// Every default shortcut, and every key with every combination of
    /// modifiers, reads back from its config.json text unchanged.
    func testEveryShortcutReadsBackFromItsConfigText() {
        var bindings = ShortcutAction.defaultBindings.values.flatMap { $0 }
        for key in KeyBinding.namedKeys + ["k", "+", "-", "[", "é"] {
            for modifiers in 0..<16 {
                bindings.append(KeyBinding(
                    key: key,
                    command: modifiers & 1 != 0,
                    option: modifiers & 2 != 0,
                    shift: modifiers & 4 != 0,
                    control: modifiers & 8 != 0
                ))
            }
        }
        for binding in bindings {
            XCTAssertEqual(KeyBinding(configText: binding.configText), binding, binding.configText)
        }
    }

    /// Shortcuts typed by hand are read generously: any letter case, spaces,
    /// the usual abbreviations, a capital letter key, and a modifier named
    /// twice all read as the binding they mean.
    func testHandTypedShortcutsAreReadGenerously() {
        let cases: [(text: String, binding: KeyBinding)] = [
            ("Command+K", KeyBinding(key: "k", command: true)),
            ("cmd + shift + K", KeyBinding(key: "k", command: true, shift: true)),
            ("Ctrl+Opt+Space", KeyBinding(key: "space", option: true, control: true)),
            ("alt+LEFTARROW", KeyBinding(key: "leftArrow", option: true)),
            ("command++", KeyBinding(key: "+", command: true)),
            ("+", KeyBinding(key: "+")),
            ("shift+shift+b", KeyBinding(key: "b", shift: true)),
        ]
        for (text, binding) in cases {
            XCTAssertEqual(KeyBinding(configText: text), binding, text)
        }
    }

    /// Text that names no key, or a key that is neither a named key (F1 to
    /// F35 among them, so "command+f13" is F13's) nor one character, is not
    /// a shortcut; nor is a private-use character no name says.
    func testUnreadableShortcutTextIsNotAShortcut() {
        for text in ["", "   ", "command+", "comand+k", "command+kk", "hyper+k", "++", "command+f36", "command+f0", "\u{F8FF}"] {
            XCTAssertNil(KeyBinding(configText: text), text)
        }
        XCTAssertEqual(KeyBinding(configText: "command+f13")?.accessibleDisplayString, "Command + F13")
    }

    /// An action's list of shortcuts is read whole, without repeats, or not
    /// at all: one mistyped shortcut leaves the action's bindings alone.
    func testShortcutListsAreReadWholeOrNotAtAll() {
        XCTAssertEqual(
            KeyBinding.bindings(fromConfigTexts: ["space", "K", "k"]),
            [KeyBinding(key: "space"), KeyBinding(key: "k")]
        )
        XCTAssertEqual(KeyBinding.bindings(fromConfigTexts: []), [])
        XCTAssertNil(KeyBinding.bindings(fromConfigTexts: ["space", "comand+k"]))
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
