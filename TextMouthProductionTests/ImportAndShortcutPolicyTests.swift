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
    /// editor chose, not only UTF-8: a byte-order mark, and the legacy
    /// encodings the bytes of a paragraph give away (Cyrillic, Mac Roman,
    /// Shift JIS), each as a whole paragraph, as an import reads them. Text
    /// that is only ASCII or valid UTF-8 is never flagged as misread.
    func testReloadFromEditorReadsTheEncodingTheEditorSavedIn() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReloadFromEditor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        func reloaded(_ name: String, _ bytes: Data) throws -> TextImportPolicy.ReloadedText? {
            let url = folder.appendingPathComponent(name)
            try bytes.write(to: url)
            return TextImportPolicy.reloadedText(from: url)
        }
        func encoded(_ text: String, _ encoding: String.Encoding) throws -> Data {
            try XCTUnwrap(text.data(using: encoding), "the paragraph has a character \(encoding) lacks")
        }

        let utf8 = try reloaded("utf8.txt", Data("Caf\u{E9} au lait\n".utf8))
        XCTAssertEqual(utf8, TextImportPolicy.ReloadedText(text: "Caf\u{E9} au lait\n", mayBeMisread: false))

        // An editor that saves UTF-16 with a byte-order mark.
        let utf16 = try reloaded("utf16.txt", Data([0xFF, 0xFE]) + (try encoded("Caf\u{E9}\n", .utf16LittleEndian)))
        XCTAssertEqual(utf16, TextImportPolicy.ReloadedText(text: "Caf\u{E9}\n", mayBeMisread: false))

        // Plain ASCII in any encoding is the same text, and not in doubt.
        XCTAssertEqual(
            try reloaded("ascii.txt", Data("Plain words.\n".utf8)),
            TextImportPolicy.ReloadedText(text: "Plain words.\n", mayBeMisread: false)
        )

        // Legacy encodings, each a whole paragraph the guess can tell.
        let paragraphs: [(name: String, text: String, encoding: String.Encoding)] = [
            ("cyrillic", "\u{421}\u{435}\u{433}\u{43E}\u{434}\u{43D}\u{44F} \u{443}\u{442}\u{440}\u{43E}\u{43C} \u{43C}\u{44B} "
                + "\u{432}\u{44B}\u{448}\u{43B}\u{438} \u{438}\u{437} \u{434}\u{43E}\u{43C}\u{430} \u{440}\u{430}\u{43D}\u{43E}, "
                + "\u{43F}\u{43E}\u{43A}\u{430} \u{43D}\u{430} \u{443}\u{43B}\u{438}\u{446}\u{435} \u{435}\u{449}\u{435} "
                + "\u{43D}\u{435} \u{431}\u{44B}\u{43B}\u{43E} \u{43B}\u{44E}\u{434}\u{435}\u{439}, \u{438} \u{434}\u{43E}\u{43B}\u{433}\u{43E} "
                + "\u{448}\u{43B}\u{438} \u{43F}\u{43E} \u{431}\u{435}\u{440}\u{435}\u{433}\u{443} \u{440}\u{435}\u{43A}\u{438}.\n",
             .windowsCP1251),
            ("macroman", "Il \u{E9}tait une fois un vieux meunier qui habitait pr\u{E8}s de la rivi\u{E8}re, et chaque matin "
                + "il quittait sa maison avant l\u{2019}aube pour moudre le bl\u{E9} des voisins, "
                + "m\u{EA}me \u{E0} la saison des pluies.\n",
             .macOSRoman),
            ("shiftjis", "\u{4ECA}\u{65E5}\u{306F}\u{671D}\u{65E9}\u{304F}\u{5BB6}\u{3092}\u{51FA}\u{3066}\u{3001}\u{5DDD}\u{6CBF}\u{3044}\u{306E}"
                + "\u{53E4}\u{3044}\u{6A4B}\u{307E}\u{3067}\u{9577}\u{3044}\u{6642}\u{9593}\u{3092}\u{304B}\u{3051}\u{3066}"
                + "\u{6B69}\u{304D}\u{307E}\u{3057}\u{305F}\u{3002}\n",
             .shiftJIS),
        ]
        for paragraph in paragraphs {
            let read = try reloaded("\(paragraph.name).txt", try encoded(paragraph.text, paragraph.encoding))
            XCTAssertEqual(read?.text, paragraph.text, paragraph.name)
            XCTAssertEqual(read?.mayBeMisread, false, paragraph.name)
        }

        // Too few bytes to tell: read as Windows-1252, and flagged, since
        // the listener would not otherwise know the characters may be wrong.
        let short = try reloaded("short.txt", Data([0x43, 0x61, 0x66, 0xE9, 0x0A]))
        XCTAssertEqual(short?.text, "Caf\u{E9}\n")
        XCTAssertEqual(short?.mayBeMisread, true)

        // A file that cannot be read gives nothing, so the view says so.
        XCTAssertNil(TextImportPolicy.reloadedText(from: folder.appendingPathComponent("missing.txt")))
        XCTAssertTrue(TextImportPolicy.reloadFailedAnnouncement.contains("unchanged"))
        XCTAssertTrue(TextImportPolicy.reloadFailedAnnouncement.hasSuffix("choose Open in Editor to start again."))
        XCTAssertTrue(TextImportPolicy.reloadMayBeMisreadAnnouncement.contains("may be wrong"))
    }

    /// Open in Editor's file is written by the policy, which says when it
    /// cannot: a folder that is not there is a real failure, and the text is
    /// untouched either way.
    func testOpenInEditorWritesItsFileOrSaysItCould() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenInEditor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }

        let written = try XCTUnwrap(TextImportPolicy.writeForEditor("Caf\u{E9}\n", inFolder: folder))
        XCTAssertEqual(try String(contentsOf: written, encoding: .utf8), "Caf\u{E9}\n")
        XCTAssertEqual(written.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(written.pathExtension, "txt")

        let missing = folder.appendingPathComponent("not-there", isDirectory: true)
        XCTAssertNil(TextImportPolicy.writeForEditor("text", inFolder: missing))
        XCTAssertTrue(TextImportPolicy.editorOpenFailedAnnouncement.hasSuffix("try again."))
        XCTAssertTrue(TextImportPolicy.editorNotOpenedAnnouncement.hasSuffix("try again."))
    }

    /// A title of only blanks is no title: the book is "Untitled", and its
    /// file is not named for spaces. A title with blanks around it loses them.
    func testATitleOfOnlyBlanksIsUntitled() {
        XCTAssertEqual(TextImportPolicy.resolvedTitle("   "), "Untitled")
        XCTAssertEqual(TextImportPolicy.resolvedTitle(" \n\t"), "Untitled")
        XCTAssertEqual(TextImportPolicy.resolvedTitle(""), "Untitled")
        XCTAssertEqual(TextImportPolicy.resolvedTitle("  Dune "), "Dune")
        XCTAssertEqual(TextImportPolicy.textFilename(for: TextImportPolicy.resolvedTitle("   ")), "Untitled.txt")
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
