import XCTest
@testable import TextMouth

/// Keyboard reachability, checked by machine (the acceptance matrix's
/// "Keyboard only" row): the user works by keyboard alone, so a command with
/// no key and no menu item is a command he cannot reach. A person still tries
/// each by hand; these tests check the part a machine can: which actions have
/// a way in, that no two default keys collide where both act, that every menu
/// item is an action or is accounted for, that every default key can be
/// spoken, and that no default key is one the shortcut rules refuse.
///
/// What the older shortcut tests already pin is not repeated here:
/// `ShortcutListingTests` (every action is listed in config.json's two forms),
/// `MenuKeyShortcutTests` (what can be a key equivalent, what a menu command
/// refuses, how the menus show the keys in force), `ShortcutManagerTests` and
/// `ShortcutEditsTests` (changes, resets, and settling a key two edited
/// actions hold), `ShortcutsSettingsTabTests` (the tab's rows, a table of
/// key names spoken), `WindowScopeShortcutTests` (scopes), `DoublePressBindingTests`,
/// `TextFieldEditingKeysTests` (a field being edited takes its keys, no
/// shortcut fires from one), `AudioEditorShortcutTests`, and
/// `RecordingWindowTests`.
final class KeyboardReachabilityTests: XCTestCase {

    // MARK: - The Lists a Person Maintains

    /// The actions with no default key and no menu item, each with the reason
    /// it is reached some other way, a full sentence, such as "Reached from
    /// the library toolbar's Folder or Feed Settings button; a key would
    /// shadow Edit > Select All."
    ///
    /// To extend it: a new action must either get a default key in
    /// `ShortcutAction.defaultBindings`, or a menu item in MenuCommands.swift,
    /// or be added here with its reason. (Team feedopts adds one such action,
    /// "Folder or Feed Settings", which has neither.) The list must not rot:
    /// an action listed here that has since got a key or a menu item fails
    /// `testEveryActionHasAWayIn` until it is taken off the list.
    static let unboundActions: [ShortcutAction: String] = [:]

    /// The menu's `Button(` arguments that are no shortcut action's title,
    /// each with the reason, a full sentence. The key is the argument exactly
    /// as MenuCommands.swift writes it. A menu button not on this list and not
    /// an action's fails `testEveryMenuCommandIsAnActionOrListed`; an entry
    /// the menu no longer has fails it too.
    static let standaloneMenuCommands: [String: String] = [
        "FeedWording.refreshAllCommand": "A Library menu command that refreshes every feed; it has no shortcut action and is reached from the menu bar.",
        "FeedWording.importCommand": "A Library menu command that imports a list of feeds; it has no shortcut action and is reached from the menu bar.",
        "FeedWording.exportCommand": "A Library menu command that exports the feeds as a list; it has no shortcut action and is reached from the menu bar.",
        "LibraryCloudWording.keepName": "A Library menu command that keeps the selected books on this Mac; it has no shortcut action and is reached from the menu bar.",
        "LibraryCloudWording.stopKeepingName": "A Library menu command that stops keeping the selected books on this Mac; it has no shortcut action and is reached from the menu bar.",
        "LibraryRemoveCommandWording.menuBarTitle(preferences: removal.preferences, selection: removalSelection)":
            "A Library menu command whose title follows the selection and the removal preferences; its shortcut is Remove from Library's, which acts on the same selection.",
        "BookExportWording.commandTitle": "A File menu command that exports a book; it has no shortcut action and is reached from the menu bar.",
        "BookTextEditWording.editTitle": "A Book menu command that edits the book's text; it has no shortcut action and is reached from the menu bar.",
        "BookTextEditWording.editWithTitle": "A Book menu command that edits the book's text with another app; it has no shortcut action and is reached from the menu bar.",
        "BookManifestEditWording.editTitle": "A Book menu command that edits the book's manifest; it has no shortcut action and is reached from the menu bar.",
        "BookManifestEditWording.editWithTitle": "A Book menu command that edits the book's manifest with another app; it has no shortcut action and is reached from the menu bar.",
        "TranscriptionWording.transcribeCommandTitle(hasTranscript: canDeleteBookTranscript == true)":
            "A Book menu command that transcribes a book's audio, or retranscribes it once it has a transcript; it has no shortcut action and is reached from the menu bar.",
        "TranscriptionWording.attachCommandTitle": "A Book menu command that attaches a transcript file to an audiobook; it has no shortcut action and is reached from the menu bar.",
        "TranscriptCleanupWording.commandTitle": "A Book menu command that cleans up a transcript; it has no shortcut action and is reached from the menu bar.",
        "TranscriptionWording.deleteCommandTitle": "A Book menu command that deletes a book's transcript; it has no shortcut action and is reached from the menu bar.",
        "AudioEditorWording.editAudioCommand": "A Book menu command that opens the audio editor; it has no shortcut action and is reached from the menu bar.",
    ]

    /// The actions whose default key is the key of one of macOS's own
    /// commands (`KeyBinding.systemCommands`), each with that command: the
    /// action stands for it, as Select All's Command-A and the audio editor's
    /// Undo, Redo, Cut, Copy, Paste, and Select All do. Any other action's
    /// default may not be such a key.
    static let systemCommandOwners: [ShortcutAction: String] = [
        .selectAll: "Select All",
        .editorSelectAll: "Select All",
        .editorUndo: "Undo",
        .editorRedo: "Redo",
        .editorCut: "Cut",
        .editorCopy: "Copy",
        .editorPaste: "Paste",
    ]

    // MARK: - Reading the Menu

    /// One `Button(` of MenuCommands.swift.
    struct MenuButton {
        /// What stands between `Button(` and `) {`, exactly as written.
        let argument: String
        /// Its line in the file, from 1.
        let line: Int
    }

    /// What a menu button's argument is.
    enum MenuButtonSource: Equatable {
        /// A shortcut action's title or raw value.
        case action(ShortcutAction)
        /// Anything else, whose argument is the key to look up in
        /// `standaloneMenuCommands`.
        case other
    }

    /// The `Button(` lines of `text`, and the lines of any it cannot read.
    ///
    /// The extraction rules, which a reformatted file must keep: a menu
    /// command is a line that, trimmed, begins `Button(` and ends `) {`, the
    /// argument being what stands between. A comment line (`//`) is skipped.
    /// A line that merely contains `Button(` anywhere else, or a button whose
    /// argument runs onto a second line, is reported as unreadable, so a
    /// change of style never lets a command go unchecked.
    static func menuButtons(in text: String) -> (buttons: [MenuButton], unreadable: [Int]) {
        var buttons: [MenuButton] = []
        var unreadable: [Int] = []
        for (index, untrimmed) in text.components(separatedBy: "\n").enumerated() where untrimmed.contains("Button(") {
            let line = untrimmed.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("//") {
                continue
            }
            guard line.hasPrefix("Button("), line.hasSuffix(") {") else {
                unreadable.append(index + 1)
                continue
            }
            let argument = String(line.dropFirst("Button(".count).dropLast(") {".count))
            buttons.append(MenuButton(argument: argument, line: index + 1))
        }
        return (buttons, unreadable)
    }

    /// `name` without an ellipsis at its end, written as one character or as
    /// three periods, in the same letter case: the menu writes "Move to
    /// Folder..." where the action is named "Move to Folder".
    static func withoutEllipsis(_ name: String) -> String {
        for ellipsis in ["\u{2026}", "..."] where name.hasSuffix(ellipsis) {
            return String(name.dropLast(ellipsis.count))
        }
        return name
    }

    /// What `argument` is: `ShortcutAction.<case>.title` or `.rawValue`, or a
    /// string literal equal to some action's raw value or title (an ellipsis at the
    /// end counting for nothing, as `withoutEllipsis(_:)` says), or
    /// else `.other`.
    static func source(ofMenuButton argument: String) -> MenuButtonSource {
        // ShortcutAction.<case>.title and ShortcutAction.<case>.rawValue.
        for ending in [".title", ".rawValue"] where argument.hasPrefix("ShortcutAction.") && argument.hasSuffix(ending) {
            let caseName = String(argument.dropFirst("ShortcutAction.".count).dropLast(ending.count))
            if let action = ShortcutAction.allCases.first(where: { String(describing: $0) == caseName }) {
                return .action(action)
            }
        }
        // A string literal.
        if argument.count >= 2, argument.hasPrefix("\""), argument.hasSuffix("\"") {
            let literal = withoutEllipsis(String(argument.dropFirst().dropLast()))
            if let action = ShortcutAction.allCases.first(where: { withoutEllipsis($0.rawValue) == literal || withoutEllipsis($0.title) == literal }) {
                return .action(action)
            }
        }
        return .other
    }

    /// Everything MenuCommands.swift's buttons tell, read from the source.
    struct MenuScan {
        /// Every readable `Button(` in the file.
        let buttons: [MenuButton]
        /// The lines of buttons it could not read.
        let unreadable: [Int]
        /// The actions whose title or raw value some button carries: those
        /// with a menu item.
        let actionsWithAMenuItem: Set<ShortcutAction>
    }

    /// Reads MenuCommands.swift from the app's sources. Fails the test, not
    /// traps, when the file is missing.
    func scanMenu() throws -> MenuScan {
        let sources = try AppSourceFile.all()
        let file = try XCTUnwrap(sources.first { $0.path == "App/MenuCommands.swift" }, "App/MenuCommands.swift is not among the app's sources")
        let (buttons, unreadable) = Self.menuButtons(in: file.text)
        var actions: Set<ShortcutAction> = []
        for button in buttons {
            if case .action(let action) = Self.source(ofMenuButton: button.argument) {
                actions.insert(action)
            }
        }
        return MenuScan(buttons: buttons, unreadable: unreadable, actionsWithAMenuItem: actions)
    }

    // MARK: - Every Action Has a Way In

    /// Every action has a default key, or a menu item, or is on
    /// `unboundActions` with its reason; and an action on the list that has
    /// since got a key or a menu item must come off it.
    func testEveryActionHasAWayIn() throws {
        let menuActions = try scanMenu().actionsWithAMenuItem
        for action in ShortcutAction.allCases {
            let hasAKey = !(ShortcutAction.defaultBindings[action] ?? []).isEmpty
            let hasAMenuItem = menuActions.contains(action)
            let reason = Self.unboundActions[action]
            if reason != nil, hasAKey {
                XCTFail("\(action.rawValue) is listed as unbound but now has a binding; remove it from the list.")
            } else if reason != nil, hasAMenuItem {
                XCTFail("\(action.rawValue) is listed as unbound but now has a menu item; remove it from the list.")
            } else if reason == nil, !hasAKey, !hasAMenuItem {
                XCTFail(
                    "\(action.rawValue) has no default key and no menu item, so the keyboard cannot reach it. "
                        + "Give it a default key in ShortcutAction.defaultBindings, or a menu item in MenuCommands.swift, "
                        + "or add it to unboundActions in KeyboardReachabilityTests with the reason it is reached some other way."
                )
            }
        }
    }

    /// Each reason on `unboundActions` is a sentence, so a reader of the list
    /// learns why a command has no key.
    func testEveryUnboundActionSaysWhy() {
        for (action, reason) in Self.unboundActions {
            XCTAssertTrue(reason.count > 20 && reason.hasSuffix("."), "\(action.rawValue)'s reason is not a full sentence: \(reason)")
        }
    }

    // MARK: - No Two Defaults Collide

    /// Each default key that clashes with another action's where both can act
    /// in one window, described once, in the order Settings lists the
    /// actions. The rule is the app's own (`KeyClaims`, which settles every
    /// key in force): an action's scope, the kinds of window its keys act in
    /// (a menu command's wherever its menu item acts), and, for a menu
    /// command, its key and the same key pressed twice.
    static func defaultCollisions(in bindings: [ShortcutAction: [KeyBinding]]) -> [String] {
        var claims = KeyClaims()
        var found: [String] = []
        for action in ShortcutAction.allCases {
            for binding in bindings[action] ?? [] {
                // Nil means claimed without a clash; a clash with the
                // action's own other key is no collision.
                guard let holder = claims.claim(binding, for: action, in: action.defaultScope), holder.action != action else { continue }
                found.append(
                    "\(action.rawValue) (\(action.defaultScope.title)) has \(binding.accessibleDisplayString), which clashes with "
                        + "\(holder.key.accessibleDisplayString) of \(holder.action.rawValue) (\(holder.action.defaultScope.title)); "
                        + "both can act in one window."
                )
            }
        }
        return found
    }

    /// No two actions share a default key where both can act in one window;
    /// Shift-Command-T, New from Text's in Library windows and Show Sleep
    /// Timer's in readers, is the one key two actions share, in kinds of
    /// window that never meet.
    func testNoTwoDefaultsCollideWhereBothApply() {
        let collisions = Self.defaultCollisions(in: ShortcutAction.defaultBindings)
        XCTAssertEqual(collisions, [], collisions.joined(separator: "\n"))
        // The one shared key is there, so the check is not looking at nothing.
        XCTAssertEqual(ShortcutAction.defaultBindings[.newFromText], ShortcutAction.defaultBindings[.showSleepTimer])
        XCTAssertNotEqual(ShortcutAction.newFromText.defaultScope, ShortcutAction.showSleepTimer.defaultScope)
    }

    /// The collision check finds a clash when one is planted, and none where
    /// scopes never meet, so a green run means something.
    func testTheCollisionCheckFindsAPlantedClash() {
        let space = KeyBinding(key: "space")
        let commandO = KeyBinding(key: "o", command: true)
        let plainW = KeyBinding(key: "w")

        // Two actions of one scope.
        XCTAssertEqual(Self.defaultCollisions(in: [.togglePlayback: [space], .increaseSpeed: [space]]).count, 1)
        // The reader's and the audio editor's never meet.
        XCTAssertEqual(Self.defaultCollisions(in: [.togglePlayback: [space], .editorPlayPause: [space]]), [])
        // A key and the same key pressed twice are two keys for a plain action...
        XCTAssertEqual(Self.defaultCollisions(in: [.whereAmI: [plainW], .whereAmIFull: [plainW.asDoublePress(true)]]), [])
        // ...but a menu command's key takes the double press with it.
        XCTAssertEqual(Self.defaultCollisions(in: [.openBook: [commandO], .togglePlayback: [commandO.asDoublePress(true)]]).count, 1)
        // The message names both actions and the key in words.
        let message = Self.defaultCollisions(in: [.togglePlayback: [space], .increaseSpeed: [space]]).first ?? ""
        XCTAssertTrue(message.contains("Play / Pause") && message.contains("Increase Speed") && message.contains("Space"), message)
    }

    // MARK: - Defaults the Shortcut Rules Refuse

    /// No default key is a key of macOS's own commands, except an action
    /// standing for that command (`systemCommandOwners`). The older tests
    /// ask `refusal(of:)` about each default, which never refuses an action's
    /// own default, so this is what checks them.
    func testNoDefaultTakesASystemCommandsKey() {
        for action in ShortcutAction.allCases {
            for binding in ShortcutAction.defaultBindings[action] ?? [] {
                guard let command = binding.systemCommand else { continue }
                XCTAssertEqual(
                    Self.systemCommandOwners[action],
                    command,
                    "\(action.rawValue)'s default, \(binding.accessibleDisplayString), is macOS's \(command) key; "
                        + "give the action another key, or list it in systemCommandOwners if it stands for that command."
                )
            }
        }
        // The list does not rot: each owner still has the key it stands for.
        for (action, command) in Self.systemCommandOwners {
            let keys = ShortcutAction.defaultBindings[action] ?? []
            XCTAssertTrue(keys.contains { $0.systemCommand == command }, "\(action.rawValue) no longer has \(command)'s key; remove it from systemCommandOwners.")
        }
    }

    /// A menu command's or Record window button's default is its only key,
    /// and one its item or button can take: one press with Command or
    /// Control, and not a key a text field edits with.
    func testAKeyEquivalentActionHasOneDefaultItsMenuCanTake() {
        for action in ShortcutAction.keyEquivalentActions.sorted(by: { $0.rawValue < $1.rawValue }) {
            let keys = ShortcutAction.defaultBindings[action] ?? []
            XCTAssertEqual(keys.count, 1, "\(action.rawValue) is a menu command or button; it has one default key")
            XCTAssertNil(action.refusal(ofKeys: keys), "\(action.rawValue)'s default is refused: \(String(describing: action.refusal(ofKeys: keys)?.reason))")
            for key in keys {
                XCTAssertTrue(
                    key.canBeKeyEquivalent,
                    "\(action.rawValue)'s default, \(key.accessibleDisplayString), cannot be a key equivalent: \(String(describing: key.keyEquivalentRefusal?.reason))"
                )
            }
        }
    }

    // MARK: - Every Menu Command Maps to an Action

    /// Every `Button(` in MenuCommands.swift is a shortcut action's title or
    /// raw value, or is on `standaloneMenuCommands`; no standalone entry is
    /// stale or really an action; and the scan finds enough buttons to have
    /// read the file.
    func testEveryMenuCommandIsAnActionOrListed() throws {
        let scan = try scanMenu()

        XCTAssertEqual(scan.unreadable, [], "MenuCommands.swift lines with a Button( this scan cannot read; see menuButtons(in:) for the rules.")
        XCTAssertGreaterThan(scan.buttons.count, 30, "a reformatted MenuCommands.swift would let this pass having checked nothing")
        var seen: Set<String> = []
        for button in scan.buttons {
            switch Self.source(ofMenuButton: button.argument) {
            case .action:
                XCTAssertNil(Self.standaloneMenuCommands[button.argument], "\(button.argument) is an action's; remove it from standaloneMenuCommands.")
            case .other:
                seen.insert(button.argument)
                XCTAssertNotNil(
                    Self.standaloneMenuCommands[button.argument],
                    "MenuCommands.swift line \(button.line): Button(\(button.argument)) is no shortcut action's title; "
                        + "give it an action, or add it to standaloneMenuCommands with the reason it has none."
                )
            }
        }
        for (argument, reason) in Self.standaloneMenuCommands {
            XCTAssertTrue(seen.contains(argument), "standaloneMenuCommands lists \(argument), which MenuCommands.swift no longer has; remove it.")
            XCTAssertTrue(reason.count > 20 && reason.hasSuffix("."), "\(argument)'s reason is not a full sentence: \(reason)")
        }
    }

    /// The scan reads each way a button names its action, and an ellipsis
    /// written as three periods or one character.
    func testTheMenuScanReadsEachFormOfButton() {
        let text = """
        struct Commands {
            Button(ShortcutAction.openBook.title) {
            Button("Play / Pause") {
                // Button(commentedOut) {
            Button("Move to Folder...") {
            Button(ShortcutAction.addBookmark.rawValue) {
            Button(FeedWording.importCommand) {
            Button(
            SomeButton(x) {
        """
        let (buttons, unreadable) = Self.menuButtons(in: text)

        XCTAssertEqual(buttons.map(\.argument), [
            "ShortcutAction.openBook.title", "\"Play / Pause\"", "\"Move to Folder...\"",
            "ShortcutAction.addBookmark.rawValue", "FeedWording.importCommand",
        ])
        XCTAssertEqual(unreadable, [8, 9], "a button whose argument runs on, and a word ending in Button(")
        XCTAssertEqual(buttons.map { Self.source(ofMenuButton: $0.argument) }, [
            .action(.openBook), .action(.togglePlayback), .action(.moveToFolder), .action(.addBookmark), .other,
        ])
        XCTAssertEqual(Self.source(ofMenuButton: "\"Import Folder...\""), .action(.importDAISYFolder))
        XCTAssertEqual(Self.source(ofMenuButton: "\"play / pause\""), .other, "a literal must match an action's name letter for letter")
    }

    /// A menu command that is a key equivalent has its menu item (the Record
    /// window's buttons are buttons, not menu items), since the key acts
    /// through the item.
    func testEveryKeyEquivalentOutsideTheRecordWindowHasAMenuItem() throws {
        let menuActions = try scanMenu().actionsWithAMenuItem
        for action in ShortcutAction.keyEquivalentActions where action.category != ShortcutAction.recordingWindowCategory {
            XCTAssertTrue(menuActions.contains(action), "\(action.rawValue) has a key equivalent but no menu item in MenuCommands.swift to act on it.")
        }
    }

    // MARK: - Every Default Key Can Be Spoken

    /// Whether `scalar` is one VoiceOver or a braille display cannot say: a
    /// character of the private-use area, or a control character.
    static func isUnspeakable(_ scalar: Unicode.Scalar) -> Bool {
        (0xE000...0xF8FF).contains(scalar.value) || scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    /// Every default key reads as words, not as a raw private-use or control
    /// character, and no two keys of one action read alike. (No older test
    /// goes through every default: `ShortcutsSettingsTabTests` checks a table
    /// of key names and a few keys.)
    func testEveryDefaultKeyIsSpeakable() {
        for action in ShortcutAction.allCases {
            var spoken: [String: KeyBinding] = [:]
            for binding in ShortcutAction.defaultBindings[action] ?? [] {
                let words = binding.accessibleDisplayString
                XCTAssertFalse(words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "\(action.rawValue) has a default key that reads as nothing")
                XCTAssertFalse(KeyBinding.isUnnamedPrivateUseCharacter(binding.key), "\(action.rawValue)'s default key is a character no name says")
                XCTAssertNil(words.unicodeScalars.first(where: Self.isUnspeakable), "\(action.rawValue)'s default reads as \"\(words)\", which holds a raw character")
                if spoken[words] != nil {
                    XCTFail("\(action.rawValue) has two different default keys that both read \"\(words)\".")
                }
                spoken[words] = binding
            }
        }
    }

    /// The speakable check tells a spoken key from a raw character.
    func testTheSpeakableCheckFindsARawCharacter() {
        XCTAssertNil("Command + I".unicodeScalars.first(where: Self.isUnspeakable))
        XCTAssertNotNil("\u{F8FF}".unicodeScalars.first(where: Self.isUnspeakable))
        XCTAssertNotNil("Command + \u{1}".unicodeScalars.first(where: Self.isUnspeakable))
        // A key no name says reads as its raw character, which the check catches.
        XCTAssertNotNil(KeyBinding(key: "\u{F8FF}").accessibleDisplayString.unicodeScalars.first(where: Self.isUnspeakable))
        XCTAssertTrue(KeyBinding.isUnnamedPrivateUseCharacter("\u{F8FF}"))
    }
}
