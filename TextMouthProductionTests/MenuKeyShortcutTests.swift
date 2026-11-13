import AppKit
import Combine
import SwiftUI
import XCTest
@testable import TextMouth

/// The menu commands' and the Record window's keys as shortcut actions of
/// their own (FR12's branch D): Open Book…, New from Text…, New Recording…,
/// Import DAISY Folder…, Add Feed…, Copy Reading Position, Search in Book,
/// Search Library…, and the Record window's Record, Pause or Resume, and Stop. Each key is
/// the key equivalent of its menu item or button, which acts on it; the
/// shortcut manager never takes it, and no other action has it, pressed
/// once or twice. Every store is the test's own.
@MainActor
final class MenuKeyShortcutTests: XCTestCase {

    // MARK: - Keys Used Below

    private let commandO = KeyBinding(key: "o", command: true)
    private let shiftCommandT = KeyBinding(key: "t", command: true, shift: true)
    private let shiftCommandP = KeyBinding(key: "p", command: true, shift: true)
    private let commandP = KeyBinding(key: "p", command: true)
    private let commandJ = KeyBinding(key: "j", command: true)

    // MARK: - The Actions

    /// The ten keys fixed before, and Search Library…'s, are actions of their
    /// own, each in the group named as its menu is, listed where its menu
    /// lists it, with its old key as its default; each title is the menu's or
    /// button's own.
    func testTheFixedKeysAreActionsWithTheirOldKeys() {
        let expected: [(action: ShortcutAction, title: String, group: String, key: KeyBinding)] = [
            (.copyReadingPosition, "Copy Reading Position", "Playback", shiftCommandP),
            (.searchInBook, "Search in Book", "Playback", KeyBinding(key: "f", command: true)),
            (.importDAISYFolder, "Import Folder…", "Library", KeyBinding(key: "o", command: true, shift: true)),
            (.addFeed, "Add Feed…", "Library", KeyBinding(key: "f", command: true, shift: true)),
            (.searchLibrary, "Search Library…", "Library", KeyBinding(key: "f", command: true, option: true)),
            (.openBook, "Open Book…", "File", commandO),
            (.newFromText, "New from Text…", "File", shiftCommandT),
            (.newRecording, "New Recording…", "File", KeyBinding(key: "n", command: true, option: true)),
            (.recordingRecord, "Record", "New Recording", KeyBinding(key: "r", command: true)),
            (.recordingPauseOrResume, "Pause or Resume", "New Recording", commandP),
            (.recordingStop, "Stop", "New Recording", KeyBinding(key: ".", command: true)),
        ]

        XCTAssertEqual(ShortcutAction.allCases.filter(\.isKeyEquivalent), expected.map(\.action), "in Settings order")
        for (action, title, group, key) in expected {
            XCTAssertEqual(action.title, title)
            XCTAssertEqual(action.category, group, title)
            XCTAssertEqual(ShortcutAction.defaultBindings[action], [key], title)
            XCTAssertTrue(key.canBeKeyEquivalent, title)
        }
        XCTAssertEqual(ShortcutAction.recordingStop.rawValue, "New Recording: Stop", "config.json tells it from the editor's Stop")
        XCTAssertEqual(ShortcutAction.recordingWindowCategory, RecordingWording.windowTitle, "the group is named as VoiceOver names the window")
        XCTAssertEqual(ShortcutAction.recordingRecord.title, RecordingWording.recordTitle)
        XCTAssertEqual(ShortcutAction.recordingStop.title, RecordingWording.stopTitle)
        XCTAssertEqual(ShortcutAction.allCases.filter { $0.category == "Playback" }.suffix(2), [.copyReadingPosition, .searchInBook])
        // Search Library… is Edit's, but the Shortcuts tab lists it whole with
        // the Library group, last of it (`testEveryActionIsListedWithItsGroup`).
        XCTAssertEqual(ShortcutAction.allCases.filter { $0.category == "Library" }.suffix(3), [.importDAISYFolder, .addFeed, .searchLibrary])
    }

    /// The manager never posts a key equivalent's action: its notification
    /// is the one choosing its menu item posts, or none of its own for a
    /// command that acts directly.
    func testTheirNotificationsAreTheirMenuItems() {
        let posted: [ShortcutAction: Notification.Name] = [
            .copyReadingPosition: .copyReadingPosition,
            .searchInBook: .searchInBook,
            .searchLibrary: .searchLibrary,
            .importDAISYFolder: .importDAISYFolder,
            .addFeed: .addFeed,
            .openBook: .openBookFile,
            .newFromText: .newFromText,
            .newRecording: .actsWithoutNotification,
            .recordingRecord: .actsWithoutNotification,
            .recordingPauseOrResume: .actsWithoutNotification,
            .recordingStop: .actsWithoutNotification,
        ]
        for (action, name) in posted {
            XCTAssertEqual(action.notificationName, name, action.rawValue)
        }
    }

    /// A key equivalent is one press with Command or Control that a text
    /// field does not edit with: no double press, no plain or Shift key, and
    /// none of a field's arrows, deletes, or Edit menu keys.
    func testWhatCanBeAKeyEquivalent() {
        XCTAssertTrue(commandO.canBeKeyEquivalent)
        XCTAssertTrue(KeyBinding(key: "g", control: true).canBeKeyEquivalent)
        XCTAssertTrue(KeyBinding(key: "o", command: true, control: true).canBeKeyEquivalent)
        XCTAssertTrue(KeyBinding(key: ".", command: true).canBeKeyEquivalent)
        XCTAssertFalse(commandO.asDoublePress(true).canBeKeyEquivalent)
        XCTAssertFalse(KeyBinding(key: "w").canBeKeyEquivalent)
        XCTAssertFalse(KeyBinding(key: "w", option: true, shift: true).canBeKeyEquivalent)
        XCTAssertFalse(KeyBinding(key: "leftArrow", command: true).canBeKeyEquivalent)
        XCTAssertFalse(KeyBinding(key: "delete", command: true).canBeKeyEquivalent)
        XCTAssertFalse(KeyBinding(key: "a", command: true).canBeKeyEquivalent)
        XCTAssertFalse(KeyBinding(key: "a", control: true).canBeKeyEquivalent, "Control-A moves to a line's start in a field")
        XCTAssertFalse(KeyBinding(key: "o", control: true).canBeKeyEquivalent, "Control-O opens a line in a field")
    }

    // MARK: - Search Library… (Edit > Find)

    /// Search Library… is a menu command of Edit > Find on Option-Command-F:
    /// a key equivalent in the Library group, titled as the Search Library
    /// window is, posting the name the window listens for, and working in
    /// every window, which is the one scope it can be given, so its menu item
    /// shows its key whichever kind of window is in front.
    func testSearchLibraryIsAMenuCommandOnOptionCommandFInEveryWindow() {
        let action = ShortcutAction.searchLibrary
        let optionCommandF = KeyBinding(key: "f", command: true, option: true)

        XCTAssertEqual(action.rawValue, "Search Library…")
        XCTAssertEqual(action.title, LibrarySearchWording.windowTitle + "…", "the menu item and the window are named alike")
        XCTAssertEqual(action.category, "Library")
        XCTAssertTrue(action.isKeyEquivalent)
        XCTAssertEqual(action.notificationName, .searchLibrary)
        XCTAssertEqual(Notification.Name.searchLibrary.rawValue, "searchLibrary")
        XCTAssertEqual(ShortcutAction.defaultBindings[action], [optionCommandF])
        XCTAssertTrue(optionCommandF.canBeKeyEquivalent)
        XCTAssertNil(action.refusal(ofKeys: [optionCommandF]))
        XCTAssertEqual(action.defaultScope, .app)
        XCTAssertEqual(action.availableScopes, [.app], "a Library-group menu command's scope is fixed, and this one's is every window")
        for kind in ShortcutWindowKind.allCases {
            XCTAssertTrue(ShortcutScope.app.admitsMenuCommand(in: kind), "\(kind)")
            XCTAssertTrue(ShortcutScope.app.windowKinds(of: action).contains(kind), "its key is claimed in a \(kind) window")
        }
        XCTAssertTrue(ShortcutScope.app.admitsMenuCommand(in: nil))
        XCTAssertEqual(makeManager("search-library-key").keyEquivalent(for: action), optionCommandF)
    }

    /// Option-Command-F is Search Library…'s alone: no other action has it as
    /// a default, once or twice, and none of macOS's own commands does.
    func testNoOtherDefaultAndNoSystemCommandHasOptionCommandF() {
        let optionCommandF = KeyBinding(key: "f", command: true, option: true)

        for (other, keys) in ShortcutAction.defaultBindings where other != .searchLibrary {
            XCTAssertFalse(keys.contains(optionCommandF), "\(other.rawValue) has Option-Command-F too")
            XCTAssertFalse(keys.contains(optionCommandF.asDoublePress(true)), "\(other.rawValue) has Option-Command-F twice")
        }
        XCTAssertNil(KeyBinding.systemCommands[optionCommandF])
        XCTAssertNil(KeyBinding.systemCommands[optionCommandF.asDoublePress(true)])
        XCTAssertEqual(ShortcutAction.defaultBindings.values.flatMap { $0 }.filter { $0 == optionCommandF }.count, 1)
    }

    /// The running app's Edit menu offers Search Library… in a Find submenu
    /// with Option-Command-F. Skipped when this run's menu bar has no Edit
    /// menu.
    func testTheEditMenuOffersSearchLibraryInFind() throws {
        guard let edit = Self.menu(titled: "Edit") else {
            throw XCTSkip("This run's menu bar has no Edit menu")
        }
        let found = try XCTUnwrap(Self.itemsAndParents(of: edit).first { $0.item.title == ShortcutAction.searchLibrary.title })

        XCTAssertEqual(found.parentTitle, "Find")
        XCTAssertEqual(Self.keyEquivalent(of: found.item).key, "f")
        XCTAssertEqual(Self.keyEquivalent(of: found.item).modifiers, [.option, .command])
        XCTAssertTrue(found.item.isEnabled)
    }

    // MARK: - Shift-Command-T in Its Two Kinds of Window (FR12's Branch E)

    /// New from Text works in Library windows and Show Sleep Timer in reader
    /// windows, as the user chose, so both have Shift-Command-T (#1451): in
    /// a reader the manager takes it for Show Sleep Timer; in a Library
    /// window it goes on to New from Text's menu item, which shows it; and in
    /// any other window, Settings's say, it is neither's.
    func testShiftCommandTIsEachsInItsOwnKindOfWindow() throws {
        let center = NotificationCenter()
        let manager = makeManager("shift-command-t", center: center)
        let posted = PostedShortcutActions(on: center)

        XCTAssertEqual(ShortcutAction.newFromText.defaultScope, .library)
        XCTAssertEqual(ShortcutAction.showSleepTimer.defaultScope, .reader)
        XCTAssertEqual(manager.bindingsFor(.showSleepTimer), [shiftCommandT])
        XCTAssertEqual(manager.keyEquivalent(for: .newFromText), shiftCommandT)
        XCTAssertNil(manager.keyEquivalent(for: .showSleepTimer), "the manager matches its own actions' keys")

        let press = try ShortcutKeyPresses.keyPress(of: shiftCommandT)
        XCTAssertTrue(manager.handleKeyEvent(press, keyWindow: makeShortcutWindow(.reader), firstResponder: nil))
        XCTAssertEqual(posted.names, [ShortcutAction.showSleepTimer.rawValue])
        XCTAssertFalse(manager.handleKeyEvent(press, keyWindow: makeShortcutWindow(.library), firstResponder: nil))
        XCTAssertFalse(manager.handleKeyEvent(press, keyWindow: makeShortcutWindow(.other), firstResponder: nil))
        XCTAssertEqual(posted.names, [ShortcutAction.showSleepTimer.rawValue], "nothing else posted")
    }

    /// The Shortcuts tab says, for an action following its defaults, which
    /// action has a default key it goes without: no default does with
    /// nothing edited, now New from Text and Show Sleep Timer each have
    /// Shift-Command-T in its own kind of window; Book Info's row says Where
    /// Am I? has Command-I once given it, as Open Book's names the action
    /// whose double press keeps Command-O from its menu item; an edited
    /// action says nothing of the kind.
    func testTheTabSaysWhoHasADefaultKey() {
        let manager = makeManager("defaults-held")
        let commandI = KeyBinding(key: "i", command: true)
        XCTAssertEqual(ShortcutAction.allCases.flatMap(manager.defaultKeysHeldElsewhere(for:)), [])

        manager.addBinding(commandI, to: .whereAmI)
        manager.updateBindings(for: .goToLibrary, to: [commandO.asDoublePress(true)])

        XCTAssertEqual(
            ShortcutsSettingsWording.rowLabel(
                for: .showBookInfo,
                keys: [],
                isEdited: false,
                defaultsHeldElsewhere: manager.defaultKeysHeldElsewhere(for: .showBookInfo)
            ),
            "Book Info: No shortcut. Where Am I? has its default, Command + I."
        )
        XCTAssertEqual(manager.defaultKeysHeldElsewhere(for: .showBookInfo), [DefaultKeyHeldElsewhere(key: commandI, holder: .whereAmI)])
        XCTAssertEqual(manager.defaultKeysHeldElsewhere(for: .openBook), [DefaultKeyHeldElsewhere(key: commandO, holder: .goToLibrary)])
        XCTAssertEqual(manager.defaultKeysHeldElsewhere(for: .whereAmI), [], "an edited action's keys are the user's")
        XCTAssertEqual(
            ShortcutsSettingsWording.defaultsHeldElsewhere(manager.defaultKeysHeldElsewhere(for: .showBookInfo)),
            "Where Am I? has its default, Command + I."
        )
    }

    // MARK: - The Manager Never Takes Them

    /// Every key equivalent's key in force goes on to its menu item or
    /// button, pressed in a window where its command works, from a field and
    /// elsewhere, with nothing posted.
    func testTheManagerLeavesEveryKeyEquivalentsKeyToItsItem() throws {
        let center = NotificationCenter()
        let manager = makeManager("leaves-key-equivalents", center: center)
        let posted = PostedShortcutActions(on: center)
        let firstResponders: [NSResponder?] = [nil, NSTextView(), NSTableView()]

        for action in ShortcutAction.keyEquivalentActions {
            let key = try XCTUnwrap(manager.keyEquivalent(for: action), action.rawValue)
            let kind = try XCTUnwrap(ShortcutWindowKind.allCases.first(where: action.defaultScope.reaches))
            let window = makeShortcutWindow(kind)
            for firstResponder in firstResponders {
                XCTAssertFalse(
                    manager.handleKeyEvent(try ShortcutKeyPresses.keyPress(of: key), keyWindow: window, firstResponder: firstResponder),
                    action.rawValue
                )
            }
        }
        XCTAssertEqual(posted.names, [])
    }

    /// Shift never turns a key equivalent's key into another action's: with
    /// Command-P given to Skip Forward, which takes Shift along, Shift-Command-P
    /// stays Copy Reading Position's in a reader, while Command-P skips.
    func testShiftNeverTurnsAKeyEquivalentsKeyIntoAnotherAction() throws {
        let center = NotificationCenter()
        let manager = makeManager("shift-and-key-equivalents", center: center)
        let posted = PostedShortcutActions(on: center)
        let reader = makeShortcutWindow(.reader)

        manager.updateBindings(for: .skipForward, to: [commandP])

        XCTAssertEqual(manager.bindingsFor(.recordingPauseOrResume), [], "the Record window's Pause or Resume lost Command-P")
        XCTAssertFalse(manager.handleKeyEvent(try ShortcutKeyPresses.keyPress(of: shiftCommandP), keyWindow: reader, firstResponder: nil))
        XCTAssertEqual(posted.names, [])
        XCTAssertTrue(manager.handleKeyEvent(try ShortcutKeyPresses.keyPress(of: commandP), keyWindow: reader, firstResponder: nil))
        XCTAssertEqual(posted.names, [ShortcutAction.skipForward.rawValue])
    }

    // MARK: - One Owner for a Key Equivalent's Key

    /// A double press of a key equivalent's key takes the key from it, since
    /// the double press's first press would never reach the menu: Command-O
    /// twice for Book Info leaves Open Book… with no key, still TextMouth's,
    /// says so as the key it lost, and gives it back once Book Info is reset.
    func testADoublePressOfAKeyEquivalentsKeyTakesItFromTheMenu() {
        let manager = makeManager("double-takes-key-equivalent")
        let before = manager.bindings

        manager.updateBindings(for: .showBookInfo, to: [commandO.asDoublePress(true)])

        XCTAssertEqual(manager.bindingsFor(.openBook), [])
        XCTAssertNil(manager.keyEquivalent(for: .openBook))
        XCTAssertFalse(manager.isEdited(.openBook))
        XCTAssertEqual(manager.actions(thatLostKeysSince: before, besides: .showBookInfo), [.openBook])
        XCTAssertEqual(
            ShortcutsSettingsWording.recorded(commandO.asDoublePress(true), for: .showBookInfo, takenFrom: [.openBook]),
            "Command + O twice, recorded for Book Info. Taken from Open Book…"
        )

        manager.resetToDefault(.showBookInfo)

        XCTAssertEqual(manager.keyEquivalent(for: .openBook), commandO)
    }

    /// A key equivalent given a key takes the key's double press from an
    /// edited action, which stays edited, and the key itself from any.
    func testAKeyEquivalentTakesItsKeysDoublePressFromAnotherAction() {
        let manager = makeManager("key-equivalent-takes-double")
        manager.updateBindings(for: .goToLibrary, to: [commandJ.asDoublePress(true)])

        manager.updateBindings(for: .openBook, to: [commandJ])

        XCTAssertEqual(manager.bindingsFor(.goToLibrary), [])
        XCTAssertTrue(manager.isEdited(.goToLibrary))
        XCTAssertEqual(manager.keyEquivalent(for: .openBook), commandJ)
    }

    /// Two actions' single and double presses of one key share it, as
    /// before, unless one of them is a key equivalent's; the audio editor's
    /// keys stay apart from the rest, but for a menu command's, whose menu
    /// item acts in an editor window too (REV11).
    func testOnlyAKeyEquivalentClashesWithItsKeysDoublePress() {
        let edits = ShortcutEdits()
        let plainJ = KeyBinding(key: "j")

        XCTAssertFalse(edits.key(plainJ, of: .skipBackward, clashesWith: plainJ.asDoublePress(true), of: .goToLibrary))
        XCTAssertTrue(edits.key(commandJ, of: .openBook, clashesWith: commandJ.asDoublePress(true), of: .goToLibrary))
        XCTAssertTrue(edits.key(commandJ.asDoublePress(true), of: .goToLibrary, clashesWith: commandJ, of: .openBook))
        XCTAssertTrue(edits.key(commandJ, of: .openBook, clashesWith: commandJ, of: .searchInBook))
        XCTAssertFalse(edits.key(commandJ, of: .openBook, clashesWith: commandO, of: .searchInBook))
        XCTAssertFalse(edits.key(commandJ, of: .goToLibrary, clashesWith: commandJ, of: .editorSave), "the audio editor's keys are apart")
        XCTAssertTrue(edits.key(commandJ, of: .openBook, clashesWith: commandJ, of: .editorSave), "Open Book… acts in an editor window too")
        XCTAssertTrue(edits.key(commandJ, of: .editorSave, clashesWith: commandJ.asDoublePress(true), of: .newRecording))
        XCTAssertFalse(
            edits.key(commandJ, of: .importDAISYFolder, clashesWith: commandJ, of: .editorSave),
            "the Library menu's command acts in Library windows alone"
        )
        XCTAssertFalse(
            edits.key(commandJ, of: .newFromText, clashesWith: commandJ, of: .editorSave),
            "New from Text… acts in Library windows alone by default"
        )
    }

    /// A key equivalent's key and its double press, held by two edited
    /// actions after an edit of config.json, are settled as one key two
    /// actions hold: the changed one keeps it, else the one Settings lists
    /// first, and the debug log names both keys.
    func testAKeyEquivalentAndItsKeysDoublePressAreSettled() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let edits = ShortcutEdits([.showBookInfo: [commandO.asDoublePress(true)], .openBook: [commandO]])

        let neither = edits.resolvingSharedKeys(favoring: [])
        XCTAssertEqual(neither.edits.keys(of: .showBookInfo), [commandO.asDoublePress(true)], "Book Info is listed first")
        XCTAssertEqual(neither.edits.keys(of: .openBook), [])
        XCTAssertEqual(neither.sharedKeys, [
            ShortcutEdits.SharedKey(key: commandO, keeper: .showBookInfo, loser: .openBook, keepersKey: commandO.asDoublePress(true)),
        ])
        let openBookChanged = edits.resolvingSharedKeys(favoring: [.openBook])
        XCTAssertEqual(openBookChanged.edits.keys(of: .openBook), [commandO])
        XCTAssertEqual(openBookChanged.edits.keys(of: .showBookInfo), [])

        let source = "menu-keys-test-\(UUID().uuidString)"
        ShortcutEdits.log(neither.sharedKeys, source: source, field: "keyboardShortcuts")
        XCTAssertEqual(debugLogLines(containing: source).map { $0.components(separatedBy: "STORED_VALUE_REPAIRED ").last ?? $0 }, [
            "\(source) keyboardShortcuts.Open Book…: \"command+o\" clashed with \"Book Info\"'s \"command+o twice\", "
                + "which keeps it; \"Open Book…\" goes without it",
        ])
    }

    // MARK: - A Menu Command's Key in an Audio Editor's Window (REV11)

    /// A File menu command working in every window acts in an audio
    /// editor's window too, so its key is claimed there: Command-S given to
    /// Open Book… is taken from the editor's Save, the Shortcuts tab says so
    /// ("Taken from Audio Editor: Save"), Save's row names the action that
    /// has its default, and a press of Command-S in an editor window goes on
    /// to Open Book…'s menu item, which shows it. Reset to Default gives Save
    /// its key back. Before, no clash was found: the editor took the key in
    /// its window while the menu showed it, enabled.
    func testAMenuCommandsKeyIsTakenFromTheAudioEditorToo() throws {
        let center = NotificationCenter()
        let manager = makeManager("menu-key-in-editor", center: center)
        let posted = PostedShortcutActions(on: center)
        let commandS = KeyBinding(key: "s", command: true)
        let before = manager.bindings

        XCTAssertNil(manager.updateBindings(for: .openBook, to: [commandS]))

        XCTAssertEqual(manager.keyEquivalent(for: .openBook), commandS)
        XCTAssertEqual(manager.bindingsFor(.editorSave), [], "the editor's Save kept Command-S")
        XCTAssertFalse(manager.isEdited(.editorSave), "losing its key made Save the user's")
        XCTAssertEqual(manager.actions(thatLostKeysSince: before, besides: .openBook), [.editorSave])
        XCTAssertEqual(
            ShortcutsSettingsWording.recorded(commandS, for: .openBook, takenFrom: [.editorSave]),
            "Command + S, recorded for Open Book… Taken from Audio Editor: Save."
        )
        XCTAssertEqual(manager.defaultKeysHeldElsewhere(for: .editorSave), [DefaultKeyHeldElsewhere(key: commandS, holder: .openBook)])
        XCTAssertEqual(
            ShortcutKeyOwners.actions(holding: commandS, in: manager.bindings, sharingAWindowWith: .editorSave, scopes: manager.scope(of:)),
            [.openBook],
            "Command-S is not Open Book…'s alone in the audio editor"
        )
        let editor = makeShortcutWindow(.audioEditor)
        XCTAssertFalse(manager.handleKeyEvent(try ShortcutKeyPresses.keyPress(of: commandS), keyWindow: editor, firstResponder: nil))
        XCTAssertEqual(posted.names, [], "the editor took Open Book…'s key in its window")

        manager.resetToDefault(.openBook)

        XCTAssertEqual(manager.bindingsFor(.editorSave), [commandS])
        XCTAssertEqual(manager.keyEquivalent(for: .openBook), commandO)
        XCTAssertTrue(manager.handleKeyEvent(try ShortcutKeyPresses.keyPress(of: commandS), keyWindow: editor, firstResponder: nil))
        XCTAssertEqual(posted.names, [ShortcutAction.editorSave.rawValue])
    }

    /// An audio editor action given a File menu command's key takes it from
    /// the command, whose menu item would answer it in the editor's window:
    /// Command-O given to the editor's Stop leaves Open Book… with no key,
    /// still TextMouth's, and its row says which action has its default.
    func testAnEditorActionGivenAMenuCommandsKeyTakesIt() {
        let manager = makeManager("editor-takes-menu-key")
        let before = manager.bindings

        XCTAssertNil(manager.updateBindings(for: .editorStop, to: [commandO]))

        XCTAssertNil(manager.keyEquivalent(for: .openBook))
        XCTAssertFalse(manager.isEdited(.openBook))
        XCTAssertEqual(manager.actions(thatLostKeysSince: before, besides: .editorStop), [.openBook])
        XCTAssertEqual(manager.defaultKeysHeldElsewhere(for: .openBook), [DefaultKeyHeldElsewhere(key: commandO, holder: .editorStop)])
        XCTAssertEqual(ShortcutPressDispatcher.Index(manager.bindings).actions(for: commandO, in: .audioEditor)?.single, .editorStop)
    }

    /// Only a menu command whose menu item acts in an editor window claims
    /// its key there: New from Text…, working in Library windows by default,
    /// and the Library menu's Import DAISY Folder… leave an editor action
    /// their keys; New from Text… given every window takes its key from the
    /// editor's Stop, which stays the user's with its other key, as it takes
    /// it from Show Sleep Timer, and VoiceOver names both.
    func testOnlyAMenuCommandActingInAnEditorTakesAnEditorsKey() {
        let manager = makeManager("menu-key-scope-editor")
        let shiftCommandO = KeyBinding(key: "o", command: true, shift: true)

        manager.updateBindings(for: .editorStop, to: [shiftCommandT, shiftCommandO])

        XCTAssertEqual(manager.bindingsFor(.editorStop), [shiftCommandT, shiftCommandO])
        XCTAssertEqual(manager.keyEquivalent(for: .newFromText), shiftCommandT)
        XCTAssertEqual(manager.keyEquivalent(for: .importDAISYFolder), shiftCommandO)

        let before = manager.bindings
        manager.setScope(.app, for: .newFromText)

        XCTAssertEqual(manager.bindingsFor(.editorStop), [shiftCommandO])
        XCTAssertTrue(manager.isEdited(.editorStop))
        XCTAssertEqual(manager.keyEquivalent(for: .newFromText), shiftCommandT)
        XCTAssertEqual(manager.actions(thatLostKeysSince: before, besides: .newFromText), [.showSleepTimer, .editorStop])
        XCTAssertEqual(
            ShortcutsSettingsWording.scopeChanged(.newFromText, to: .app, takenFrom: [.showSleepTimer, .editorStop]),
            "New from Text… works in every window. Taken from Show Sleep Timer and Audio Editor: Stop."
        )
    }

    /// A menu command's key and an audio editor action's, both the user's
    /// after an edit of config.json, are settled as any key two actions hold
    /// where both act: the changed one keeps it, else the one Settings lists
    /// first, Open Book….
    func testAMenuCommandAndAnEditorActionHoldingOneKeyAreSettled() {
        let commandS = KeyBinding(key: "s", command: true)
        let edits = ShortcutEdits([.openBook: [commandS], .editorSave: [commandS]])

        let neither = edits.resolvingSharedKeys(favoring: [])
        XCTAssertEqual(neither.edits.keys(of: .openBook), [commandS])
        XCTAssertEqual(neither.edits.keys(of: .editorSave), [])
        XCTAssertEqual(neither.sharedKeys, [ShortcutEdits.SharedKey(key: commandS, keeper: .openBook, loser: .editorSave)])

        let saveChanged = edits.resolvingSharedKeys(favoring: [.editorSave])
        XCTAssertEqual(saveChanged.edits.keys(of: .editorSave), [commandS])
        XCTAssertEqual(saveChanged.edits.keys(of: .openBook), [])
    }

    // MARK: - The Index

    /// The index notes each key equivalent's key as one, gives it to no
    /// action, and, between a key equivalent and another action holding its
    /// key, once or twice, leaves it to the one Settings lists first.
    func testTheIndexNotesKeyEquivalentsAndTheFirstListedHasAKey() {
        let defaults = ShortcutPressDispatcher.Index(ShortcutAction.defaultBindings)
        // Open Book… works in every window, its menu item in an audio
        // editor's too (REV11).
        for kind in ShortcutWindowKind.allCases {
            XCTAssertTrue(defaults.isKeyEquivalent(commandO, in: kind), "\(kind)")
            XCTAssertNil(defaults.actions(for: commandO, in: kind), "\(kind)")
        }
        // Shift-Command-T is New from Text's key equivalent in a Library
        // window, Show Sleep Timer's in a reader, and neither's elsewhere.
        XCTAssertTrue(defaults.isKeyEquivalent(shiftCommandT, in: .library))
        XCTAssertNil(defaults.actions(for: shiftCommandT, in: .library))
        XCTAssertFalse(defaults.isKeyEquivalent(shiftCommandT, in: .reader))
        XCTAssertEqual(defaults.actions(for: shiftCommandT, in: .reader)?.single, .showSleepTimer)
        XCTAssertFalse(defaults.isKeyEquivalent(shiftCommandT, in: .other))
        XCTAssertNil(defaults.actions(for: shiftCommandT, in: .other))

        let raw = ShortcutPressDispatcher.Index([.showBookInfo: [commandO.asDoublePress(true)], .openBook: [commandO]])
        XCTAssertFalse(raw.isKeyEquivalent(commandO, in: .library))
        XCTAssertEqual(raw.actions(for: commandO, in: .library)?.double, .showBookInfo)
    }

    // MARK: - The Menus and the Record Window Show the Keys in Force

    /// A binding becomes the key equivalent a menu item or a button takes:
    /// its key with its modifiers, a named key by SwiftUI's name, a function
    /// key by its character; a binding that can be no key equivalent becomes
    /// none.
    func testABindingBecomesTheKeyEquivalentAnItemTakes() throws {
        let expected: [(binding: KeyBinding, key: KeyEquivalent, modifiers: EventModifiers)] = [
            (commandO, "o", .command),
            (KeyBinding(key: "n", command: true, option: true), "n", [.command, .option]),
            (shiftCommandT, "t", [.command, .shift]),
            (KeyBinding(key: ".", command: true), ".", .command),
            (KeyBinding(key: "g", control: true), "g", .control),
            (KeyBinding(key: "space", command: true, control: true), .space, [.command, .control]),
            (KeyBinding(key: "return", command: true), .return, .command),
            (KeyBinding(key: "\u{F708}", command: true), KeyEquivalent("\u{F708}"), .command),
        ]
        for (binding, key, modifiers) in expected {
            let shortcut = try XCTUnwrap(binding.keyboardShortcut, binding.configText)
            XCTAssertEqual(shortcut.key, key, binding.configText)
            XCTAssertEqual(shortcut.modifiers, modifiers, binding.configText)
        }
        for binding in [KeyBinding(key: "w"), commandO.asDoublePress(true), KeyBinding(key: "leftArrow", command: true)] {
            XCTAssertNil(binding.keyboardShortcut, binding.configText)
        }
        let manager = makeManager("keyboard-shortcuts")
        XCTAssertEqual(manager.keyboardShortcut(for: .openBook)?.key, "o")
        XCTAssertEqual(manager.keyboardShortcut(for: .newFromText)?.key, "t")
        XCTAssertNil(manager.keyboardShortcut(for: .whereAmI), "no key equivalent's action")
    }

    /// The Record window's buttons read their keys from the record in the
    /// store, and follow a change of it, published once.
    func testTheRecordWindowsKeysFollowTheRecord() {
        let store = makeSandboxedPreferences("menu-keys-record-window")
        let keys = StoredKeyEquivalents(store: store)
        var changes = 0
        let subscription = keys.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }
        XCTAssertEqual(keys.keyEquivalent(for: .recordingRecord), KeyBinding(key: "r", command: true))
        XCTAssertEqual(keys.keyEquivalent(for: .recordingStop), KeyBinding(key: ".", command: true))

        let optionCommandR = KeyBinding(key: "r", command: true, option: true)
        KeyboardShortcutManager.editsPreference.write(ShortcutEdits([.recordingRecord: [optionCommandR]]), to: store)

        XCTAssertEqual(keys.keyEquivalent(for: .recordingRecord), optionCommandR)
        XCTAssertEqual(changes, 1)
        XCTAssertNil(keys.keyEquivalent(for: .togglePlayback), "no key equivalent's action")
    }

    /// The running app's menus show each menu command's key in force:
    /// Command-O for Open Book…, Shift-Command-T for New from Text… (FR12's
    /// branch E), Option-Command-N for New Recording…,
    /// Shift-Command-O and Shift-Command-F in the Library menu, and
    /// Shift-Command-P and Command-F in the Playback menu. Given another key
    /// in the app's own store, a test sandbox's, Open Book… shows it, and
    /// shows Command-O again once the store is as it was. Skipped when this
    /// run's menu bar has no File menu.
    func testTheMenusShowTheKeysInForceAndFollowAChange() throws {
        guard Self.menu(titled: "File") != nil else {
            throw XCTSkip("This run's menu bar has no File menu")
        }
        let shown: [(menu: String, action: ShortcutAction, key: String, modifiers: NSEvent.ModifierFlags)] = [
            ("File", .openBook, "o", .command),
            ("File", .newFromText, "t", [.shift, .command]),
            ("File", .newRecording, "n", [.option, .command]),
            ("Library", .importDAISYFolder, "o", [.shift, .command]),
            ("Library", .addFeed, "f", [.shift, .command]),
            ("Playback", .copyReadingPosition, "p", [.shift, .command]),
            ("Playback", .searchInBook, "f", .command),
        ]
        // Each item acts, with its key, only where its action works, as the
        // window in front of this run tells (FR12's branch E).
        let front = FrontWindowKind.shared.kind
        for (menuTitle, action, key, modifiers) in shown {
            let item = try XCTUnwrap(Self.menu(titled: menuTitle).flatMap { Self.item(action.title, in: $0) }, action.rawValue)
            let acts = action.defaultScope.admitsMenuCommand(in: front)
            XCTAssertEqual(item.isEnabled, acts, "\(action.rawValue) with \(String(describing: front)) in front")
            XCTAssertEqual(Self.keyEquivalent(of: item).key, acts ? key : "", action.rawValue)
            XCTAssertEqual(Self.keyEquivalent(of: item).modifiers, acts ? modifiers : [], action.rawValue)
        }

        let store = TextMouthRuntime.current.preferences
        let recordKey = KeyboardShortcutManager.editsPreference.key
        let before = store.data(forKey: recordKey)
        // Puts the app's store back however the test ends.
        addTeardownBlock { @MainActor in
            if let before {
                store.set(before, forKey: recordKey)
            } else {
                store.removeObject(forKey: recordKey)
            }
        }
        var edits = KeyboardShortcutManager.editsPreference.read(from: store)
        edits.setKeys([KeyBinding(key: "o", command: true, control: true)], for: .openBook)
        KeyboardShortcutManager.editsPreference.write(edits, to: store)

        // Read afresh each time, as SwiftUI may build the menu again.
        func openBookKey() -> (key: String, modifiers: NSEvent.ModifierFlags)? {
            Self.menu(titled: "File").flatMap { Self.item(ShortcutAction.openBook.title, in: $0) }.map(Self.keyEquivalent(of:))
        }
        XCTAssertTrue(
            waitUntil(timeout: 5) { openBookKey()?.key == "o" && openBookKey()?.modifiers == [.control, .command] },
            "Open Book… shows \(String(describing: openBookKey()))"
        )

        if let before {
            store.set(before, forKey: recordKey)
        } else {
            store.removeObject(forKey: recordKey)
        }
        XCTAssertTrue(
            waitUntil(timeout: 5) { openBookKey()?.key == "o" && openBookKey()?.modifiers == .command },
            "Open Book… shows \(String(describing: openBookKey()))"
        )
    }

    // MARK: - A Menu Command Acts Where Its Action Works (FR12's Branch E)

    /// A menu command working in every window acts in any, an audio
    /// editor's included, as menus always have; one working in a kind of
    /// window acts only in that kind; and any acts with no window open.
    func testAMenuCommandActsWhereItsActionWorks() {
        for kind in ShortcutWindowKind.allCases {
            XCTAssertTrue(ShortcutScope.app.admitsMenuCommand(in: kind), "\(kind)")
        }
        XCTAssertTrue(ShortcutScope.library.admitsMenuCommand(in: .library))
        XCTAssertFalse(ShortcutScope.library.admitsMenuCommand(in: .reader))
        XCTAssertFalse(ShortcutScope.library.admitsMenuCommand(in: .other))
        XCTAssertFalse(ShortcutScope.library.admitsMenuCommand(in: .audioEditor))
        XCTAssertTrue(ShortcutScope.reader.admitsMenuCommand(in: .reader))
        XCTAssertFalse(ShortcutScope.reader.admitsMenuCommand(in: .recording))
        for scope in ShortcutScope.allCases {
            XCTAssertTrue(scope.admitsMenuCommand(in: nil), "\(scope) with no window")
        }
    }

    /// The menus take the kind of the window in front as the shortcut
    /// manager tells kinds apart: a reader's, a Library window, an audio
    /// editor's, the Record window, any other window, or none.
    func testTheMenusTellTheWindowInFrontApart() {
        XCTAssertNil(FrontWindowKind.kind(of: nil))
        for kind in ShortcutWindowKind.allCases {
            XCTAssertEqual(FrontWindowKind.kind(of: makeShortcutWindow(kind)), kind, "\(kind)")
        }
    }

    // MARK: - Keys a Menu Command Cannot Take

    /// A menu command's key is one press of a key with Command or Control
    /// that no text field edits with, and the command has one: anything else
    /// is refused, with the reason VoiceOver hears and the log says; any
    /// other action takes any key.
    func testAMenuCommandRefusesWhatCannotBeItsKey() {
        let plainW = KeyBinding(key: "w")
        let commandLeft = KeyBinding(key: "leftArrow", command: true)
        let controlG = KeyBinding(key: "g", control: true)

        XCTAssertEqual(ShortcutAction.openBook.refusal(of: plainW), .notOnePressWithCommandOrControl(plainW))
        XCTAssertEqual(ShortcutAction.openBook.refusal(of: commandO.asDoublePress(true)), .notOnePressWithCommandOrControl(commandO.asDoublePress(true)))
        XCTAssertEqual(ShortcutAction.recordingStop.refusal(of: commandLeft), .editsText(commandLeft))
        XCTAssertNil(ShortcutAction.openBook.refusal(of: controlG))
        XCTAssertNil(ShortcutAction.whereAmI.refusal(of: plainW))
        XCTAssertEqual(ShortcutAction.openBook.refusal(ofKeys: [commandO, controlG]), .secondKeyEquivalent(controlG))
        XCTAssertNil(ShortcutAction.togglePlayback.refusal(ofKeys: [KeyBinding(key: "space"), KeyBinding(key: "k"), plainW]))
        // One rule, holding keys as the Shortcuts tab holds those in force:
        // a key held already is never refused, and the key past the number
        // held is the one named, whichever place it is given in.
        XCTAssertNil(ShortcutAction.openBook.refusal(ofKeys: [plainW], holding: [plainW]))
        XCTAssertEqual(ShortcutAction.openBook.refusal(ofKeys: [plainW, controlG], holding: [plainW]), .secondKeyEquivalent(controlG))
        XCTAssertEqual(ShortcutAction.openBook.refusal(ofKeys: [controlG, commandO], holding: [commandO]), .secondKeyEquivalent(controlG))
        XCTAssertNil(ShortcutAction.openBook.refusal(ofKeys: [commandO, controlG], holding: [commandO, controlG]))
        XCTAssertEqual(
            ShortcutAction.openBook.refusal(ofKeys: [commandO, plainW], holding: [commandO]),
            .notOnePressWithCommandOrControl(plainW),
            "a key it cannot take is named before a second key"
        )

        XCTAssertEqual(
            ShortcutsSettingsWording.refused(.notOnePressWithCommandOrControl(plainW), for: .openBook),
            "W not recorded for Open Book…: a menu command's shortcut is one press of a key with Command or Control."
        )
        XCTAssertEqual(
            ShortcutsSettingsWording.refused(.editsText(commandLeft), for: .recordingStop),
            "Command + Left Arrow not recorded for New Recording: Stop: a text field edits with it, "
                + "and a menu command's shortcut would take it from the field."
        )
        XCTAssertEqual(
            ShortcutsSettingsWording.refused(.secondKeyEquivalent(controlG), for: .openBook),
            "Control + G not recorded for Open Book…: a menu command has one shortcut."
        )
        XCTAssertEqual(ShortcutsSettingsWording.mostKeys(for: .openBook), 1)
        XCTAssertEqual(ShortcutsSettingsWording.mostKeys(for: .whereAmI), 3)
        XCTAssertEqual(ShortcutsSettingsWording.recordingKeyEquivalentLabel, "Recording shortcut. Press a key with Command or Control.")
    }

    /// The manager refuses what an action cannot take, changing nothing and
    /// saying why, but never a key the action has already, so an action a
    /// store edited by hand gave a key it cannot take can still be changed.
    func testTheManagerRefusesAndChangesNothing() {
        let plainW = KeyBinding(key: "w")
        let controlG = KeyBinding(key: "g", control: true)
        let manager = makeManager("refuses")

        XCTAssertEqual(manager.updateBindings(for: .openBook, to: [plainW]), .notOnePressWithCommandOrControl(plainW))
        XCTAssertEqual(manager.addBinding(controlG, to: .openBook), .secondKeyEquivalent(controlG))
        XCTAssertEqual(manager.bindingsFor(.openBook), [commandO])
        XCTAssertFalse(manager.isEdited(.openBook))
        XCTAssertNil(manager.updateBindings(for: .openBook, to: [controlG]))
        XCTAssertEqual(manager.keyEquivalent(for: .openBook), controlG)

        let store = makeSandboxedPreferences("menu-keys-edited-by-hand")
        KeyboardShortcutManager.editsPreference.write(ShortcutEdits([.openBook: [plainW]]), to: store)
        let handEdited = KeyboardShortcutManager(userDefaults: store, installsEventMonitor: false, notificationCenter: NotificationCenter())
        XCTAssertNil(handEdited.keyEquivalent(for: .openBook), "the menu shows no key it cannot take")
        XCTAssertEqual(handEdited.addBinding(controlG, to: .openBook), .secondKeyEquivalent(controlG))
        XCTAssertNil(handEdited.updateBindings(for: .openBook, to: [controlG]))
        XCTAssertEqual(handEdited.keyEquivalent(for: .openBook), controlG)
    }

    /// A recording that takes no double press, a menu command's, records the
    /// first key pressed as it goes down, with no wait and no timer.
    func testARecordingThatTakesNoDoublePressRecordsAtOnce() {
        var outcomes: [ShortcutRecording.Outcome] = []
        var timers = 0
        let recording = ShortcutRecording(
            doublePressTime: 0.5,
            takesDoublePresses: false,
            clock: { 10 },
            startTimer: { delay, fire in
                timers += 1
                return HandFiredTimer(delay: delay, fire: fire)
            },
            finish: { outcomes.append($0) }
        )

        XCTAssertTrue(recording.take(commandO, at: 10, isRepeat: false, isEscape: false))

        XCTAssertEqual(outcomes, [.recorded(commandO)])
        XCTAssertEqual(timers, 0)
        XCTAssertFalse(recording.take(commandO, at: 10.1, isRepeat: false, isEscape: false), "the recording has ended")
    }

    /// config.json's entries giving a menu command keys it cannot take are
    /// left out and logged, each command keeping its key, and the file is to
    /// be saved again to show the keys in force; an entry it can take is
    /// read; an entry the record already holds is never refused again.
    func testConfigJSONLeavesOutKeysAMenuCommandCannotTake() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let store = makeSandboxedPreferences("menu-keys-config")
        let controlG = KeyBinding(key: "g", control: true)

        let repaired = KeyboardShortcutManager.adopt([
            .openBook: ["w"],
            .searchInBook: ["command+f twice"],
            .copyReadingPosition: ["command+leftArrow"],
            .newRecording: ["option+command+n", "control+g"],
            .addFeed: ["control+g"],
        ], in: store)

        XCTAssertTrue(repaired)
        XCTAssertEqual(KeyboardShortcutManager.editsPreference.read(from: store), ShortcutEdits([.addFeed: [controlG]]))
        let logged = [
            #"keyboardShortcuts.Open Book…: "w" cannot be its shortcut: a menu command's shortcut is one press of a key with Command or Control; keeping its shortcuts"#,
            #"keyboardShortcuts.Search in Book: "command+f twice" cannot be its shortcut"#,
            #"keyboardShortcuts.Copy Reading Position: "command+leftArrow" cannot be its shortcut: a text field edits with it"#,
            #"keyboardShortcuts.New Recording…: "control+g" cannot be its shortcut: a menu command has one shortcut"#,
        ]
        for line in logged {
            XCTAssertFalse(debugLogLines(containing: line).isEmpty, line)
        }

        KeyboardShortcutManager.editsPreference.write(ShortcutEdits([.openBook: [KeyBinding(key: "w")]]), to: store)
        XCTAssertFalse(KeyboardShortcutManager.adopt([.openBook: ["w"]], in: store), "the record holds it already")
    }

    // MARK: - Keys macOS's Own Commands Keep (Finding 10)

    /// No action takes a system command's key, pressed once or twice: Quit,
    /// Close, Settings, Hide, Minimize, and the Edit menu's keys stay
    /// macOS's, said with the command's name; but an action's own default,
    /// which stands for that command, as Select All's Command-A and the
    /// audio editor's Undo do, may be given back.
    func testNoActionTakesASystemCommandsKey() {
        let commandQ = KeyBinding(key: "q", command: true)
        let commandA = KeyBinding(key: "a", command: true)
        let commandZ = KeyBinding(key: "z", command: true)

        XCTAssertEqual(ShortcutAction.togglePlayback.refusal(of: commandQ), .systemCommand(commandQ, command: "Quit TextMouth"))
        XCTAssertEqual(
            ShortcutAction.togglePlayback.refusal(of: commandQ.asDoublePress(true)),
            .systemCommand(commandQ.asDoublePress(true), command: "Quit TextMouth")
        )
        XCTAssertEqual(ShortcutAction.openBook.refusal(of: KeyBinding(key: "w", command: true)), .systemCommand(KeyBinding(key: "w", command: true), command: "Close"))
        XCTAssertEqual(ShortcutAction.showBookInfo.refusal(of: commandA), .systemCommand(commandA, command: "Select All"))
        XCTAssertNil(ShortcutAction.selectAll.refusal(of: commandA), "Select All's own default")
        XCTAssertNil(ShortcutAction.editorUndo.refusal(of: commandZ), "the editor's own Undo")
        XCTAssertEqual(ShortcutAction.editorCopy.refusal(of: commandZ), .systemCommand(commandZ, command: "Undo"))
        XCTAssertNil(ShortcutAction.togglePlayback.refusal(of: KeyBinding(key: "q", command: true, shift: true)), "Shift-Command-Q is no command of TextMouth's menus")
        XCTAssertEqual(
            ShortcutsSettingsWording.refused(.systemCommand(commandQ, command: "Quit TextMouth"), for: .togglePlayback),
            "Command + Q not recorded for Play / Pause: Quit TextMouth has it in the menus, and no shortcut may take it."
        )
        // No default key is checked here: refusal(of:) never refuses an
        // action's own default, so KeyboardReachabilityTests checks them
        // without it (testNoDefaultTakesASystemCommandsKey and
        // testAKeyEquivalentActionHasOneDefaultItsMenuCanTake).
        // Through the manager and config.json alike, the key stays macOS's.
        let manager = makeManager("system-commands")
        XCTAssertEqual(manager.addBinding(commandQ, to: .togglePlayback), .systemCommand(commandQ, command: "Quit TextMouth"))
        XCTAssertEqual(manager.bindingsFor(.togglePlayback), [KeyBinding(key: "space"), KeyBinding(key: "k")])
        let store = makeSandboxedPreferences("menu-keys-system-config")
        XCTAssertTrue(KeyboardShortcutManager.adopt([.whereAmI: ["command+h"]], in: store))
        XCTAssertEqual(KeyboardShortcutManager.editsPreference.read(from: store), ShortcutEdits())
    }

    // MARK: - Names in config.json

    /// A name ending in an ellipsis is read with three periods or none in
    /// its place, in any letter case; no two actions' names read alike.
    func testNamesReadWithOrWithoutTheirEllipsis() {
        XCTAssertEqual(ShortcutAction.named("Open Book…"), .openBook)
        XCTAssertEqual(ShortcutAction.named("open book..."), .openBook)
        XCTAssertEqual(ShortcutAction.named("OPEN BOOK"), .openBook)
        XCTAssertEqual(ShortcutAction.named("Import DAISY Folder"), .importDAISYFolder)
        XCTAssertEqual(ShortcutAction.named("new recording: stop"), .recordingStop)
        XCTAssertEqual(ShortcutAction.named("Audio Editor: Go to Time"), .editorGoToTime)
        XCTAssertEqual(ShortcutAction.named("where am i?"), .whereAmI)
        XCTAssertNil(ShortcutAction.named("Stop"), "Stop alone names neither the editor's nor the Record window's")
        XCTAssertNil(ShortcutAction.named("Open Book…?"))
        // The Record window's buttons' former names, under "Recording
        // Window", still name them (REV11), exactly and in any letter case.
        XCTAssertEqual(ShortcutAction.named("Recording Window: Record"), .recordingRecord)
        XCTAssertEqual(ShortcutAction.named("recording window: pause or resume"), .recordingPauseOrResume)
        XCTAssertEqual(ShortcutAction.exactlyNamed("Recording Window: Stop"), .recordingStop)
        XCTAssertNil(ShortcutAction.exactlyNamed("recording window: stop"), "the record names actions letter for letter")
        // The bookmark command's one name is the Bookmarks menu's; its old
        // name, Add Bookmark, is still read (#1937).
        XCTAssertEqual(ShortcutAction.addBookmark.rawValue, "Toggle Bookmark")
        XCTAssertEqual(ShortcutAction.named("Toggle Bookmark"), .addBookmark)
        XCTAssertEqual(ShortcutAction.named("Add Bookmark"), .addBookmark)
        XCTAssertEqual(ShortcutAction.named("add bookmark"), .addBookmark)
        XCTAssertEqual(ShortcutAction.exactlyNamed("Add Bookmark"), .addBookmark)
        let compared = (ShortcutAction.allCases.map(\.rawValue) + ShortcutAction.formerNames.keys).map(ShortcutAction.comparableName)
        XCTAssertEqual(Set(compared).count, compared.count)
    }

    // MARK: - Helpers

    /// The running app's top-level menu titled `title`, brought up to date
    /// as it is before it opens, or nil when the menu bar has none.
    private static func menu(titled title: String) -> NSMenu? {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == title })?.submenu else { return nil }
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu
    }

    /// Every item of `menu` and of its submenus, each with the title of the
    /// item whose submenu holds it (`parentTitle`, `menu`'s own title at the
    /// top), every menu brought up to date first.
    private static func itemsAndParents(of menu: NSMenu, parentTitle: String? = nil) -> [(item: NSMenuItem, parentTitle: String)] {
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu.items.flatMap { item -> [(item: NSMenuItem, parentTitle: String)] in
            [(item, parentTitle ?? menu.title)] + (item.submenu.map { itemsAndParents(of: $0, parentTitle: item.title) } ?? [])
        }
    }

    /// The item titled `title` in `menu`, brought up to date first.
    private static func item(_ title: String, in menu: NSMenu) -> NSMenuItem? {
        menu.delegate?.menuNeedsUpdate?(menu)
        return menu.items.first { $0.title == title }
    }

    /// The key equivalent `item` shows: its key in lower case, and its
    /// modifiers, Shift included when the key is a capital, as AppKit reads
    /// a capital.
    private static func keyEquivalent(of item: NSMenuItem) -> (key: String, modifiers: NSEvent.ModifierFlags) {
        var modifiers = item.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control])
        if item.keyEquivalent != item.keyEquivalent.lowercased() {
            modifiers.insert(.shift)
        }
        return (item.keyEquivalent.lowercased(), item.keyEquivalent.isEmpty ? [] : modifiers)
    }

    /// A shortcut manager with the default keys, from a preferences store
    /// of the test's own, watching no key presses and posting on `center`.
    private func makeManager(_ label: String, center: NotificationCenter = NotificationCenter()) -> KeyboardShortcutManager {
        KeyboardShortcutManager(
            userDefaults: makeSandboxedPreferences("menu-keys-\(label)"),
            installsEventMonitor: false,
            notificationCenter: center
        )
    }
}
