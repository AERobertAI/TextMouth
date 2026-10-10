import AppKit
import XCTest
@testable import TextMouth

/// Shortcuts that work in a kind of window the user chooses (FR12's branch
/// E): which scopes each action may be given, the record keeping a chosen
/// scope beside the action's keys, a change of scope taking keys only where
/// scopes then overlap, and Reset to Default giving the default scope back.
/// Every store is the test's own.
@MainActor
final class WindowScopeShortcutTests: XCTestCase {

    // MARK: - Keys Used Below

    private let shiftCommandT = KeyBinding(key: "t", command: true, shift: true)
    private let shiftR = KeyBinding(key: "r", shift: true)

    // MARK: - The Scopes an Action May Be Given

    /// The app's actions and the File menu's commands may work in every
    /// window, in Library windows, or in reader windows; the audio editor's,
    /// the Record window's buttons, and the Library and Playback menus'
    /// commands work only where they do by nature.
    func testEachActionMayBeGivenTheScopesItCanWorkIn() {
        let choosable: [ShortcutScope] = [.app, .library, .reader]
        for action in [ShortcutAction.togglePlayback, .showSleepTimer, .speakInfo, .openBook, .newFromText, .newRecording] {
            XCTAssertEqual(action.availableScopes, choosable, action.rawValue)
        }
        XCTAssertEqual(ShortcutAction.importDAISYFolder.availableScopes, [.library])
        XCTAssertEqual(ShortcutAction.addFeed.availableScopes, [.library])
        XCTAssertEqual(ShortcutAction.copyReadingPosition.availableScopes, [.reader])
        XCTAssertEqual(ShortcutAction.searchInBook.availableScopes, [.reader])
        XCTAssertEqual(ShortcutAction.recordingStop.availableScopes, [.recording])
        XCTAssertEqual(ShortcutAction.editorPlayPause.availableScopes, [.audioEditor])
        for action in ShortcutAction.allCases {
            XCTAssertTrue(action.availableScopes.contains(action.defaultScope), action.rawValue)
        }
    }

    // MARK: - The Record

    /// The record keeps a scope only for an action it holds, only one the
    /// action may be given, and only when it is not the action's default; an
    /// action it leaves out works where its default scope reaches.
    func testTheRecordKeepsAChosenScopeOnlyWhereItCounts() {
        let edits = ShortcutEdits(
            [.newFromText: [shiftCommandT], .showSleepTimer: [shiftCommandT], .addFeed: []],
            scopes: [.newFromText: .app, .showSleepTimer: .reader, .addFeed: .reader, .whereAmI: .library]
        )

        XCTAssertEqual(edits.scopesByEditedAction, [.newFromText: .app], "a default, an unavailable, and an unedited action's scope are dropped")
        XCTAssertEqual(edits.scope(of: .newFromText), .app)
        XCTAssertEqual(edits.scope(of: .showSleepTimer), .reader)
        XCTAssertEqual(edits.scope(of: .addFeed), .library)
        XCTAssertEqual(edits.scope(of: .whereAmI), .app)
    }

    /// Giving New from Text every window takes Shift-Command-T from Show
    /// Sleep Timer, whose reader windows that scope now overlaps: from the
    /// keys in force of an unedited one, and from an edited one's keys,
    /// which stay without it; back in Library windows, an unedited Show
    /// Sleep Timer has its key again.
    func testAChangeOfScopeTakesKeysWhereScopesNowOverlap() {
        var edits = ShortcutEdits()
        edits.setScope(.app, for: .newFromText, keys: [shiftCommandT])

        var inForce = edits.effectiveBindings(defaults: ShortcutAction.defaultBindings)
        XCTAssertEqual(inForce[.newFromText], [shiftCommandT])
        XCTAssertEqual(inForce[.showSleepTimer], [], "the unedited Show Sleep Timer goes without it")
        XCTAssertTrue(edits.isEdited(.newFromText))

        edits.setScope(.library, for: .newFromText, keys: [shiftCommandT])
        inForce = edits.effectiveBindings(defaults: ShortcutAction.defaultBindings)
        XCTAssertEqual(inForce[.showSleepTimer], [shiftCommandT], "apart again, each has it")
        XCTAssertEqual(edits.scopesByEditedAction, [:], "Library windows is New from Text's default")
        XCTAssertTrue(edits.isEdited(.newFromText), "a scope set back to its default stays the user's")

        var bothEdited = ShortcutEdits([.showSleepTimer: [shiftCommandT], .newFromText: [shiftCommandT]])
        bothEdited.setScope(.app, for: .newFromText, keys: [shiftCommandT])
        XCTAssertEqual(bothEdited.keys(of: .showSleepTimer), [], "the edited Show Sleep Timer lost it, and stays edited")
        XCTAssertEqual(bothEdited.keys(of: .newFromText), [shiftCommandT])

        var unavailable = ShortcutEdits()
        unavailable.setScope(.reader, for: .addFeed, keys: [KeyBinding(key: "f", command: true, shift: true)])
        XCTAssertEqual(unavailable, ShortcutEdits(), "Add Feed works only in Library windows")
    }

    // MARK: - The Manager

    /// Through the manager, a change of scope makes the action the user's,
    /// published once, says which actions it took a key from, and moves the
    /// key at once: Shift-Command-T in a reader then goes on to New from
    /// Text's menu item. Reset to Default gives back its keys and its scope,
    /// and Show Sleep Timer has the key again.
    func testTheManagerChangesAScopeAndResetGivesItBack() throws {
        let center = NotificationCenter()
        let manager = KeyboardShortcutManager(
            userDefaults: makeSandboxedPreferences("window-scope-manager"),
            installsEventMonitor: false,
            notificationCenter: center
        )
        let posted = PostedShortcutActions(on: center)
        var publications = 0
        let subscription = manager.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        let before = manager.bindings

        manager.setScope(.app, for: .newFromText)

        XCTAssertEqual(publications, 1)
        XCTAssertEqual(manager.scope(of: .newFromText), .app)
        XCTAssertTrue(manager.isEdited(.newFromText))
        XCTAssertEqual(manager.actions(thatLostKeysSince: before, besides: .newFromText), [.showSleepTimer])
        let press = try ShortcutKeyPresses.keyPress(of: shiftCommandT)
        XCTAssertFalse(manager.handleKeyEvent(press, keyWindow: makeShortcutWindow(.reader), firstResponder: nil))
        XCTAssertEqual(posted.names, [], "New from Text's menu item has it in a reader now")

        manager.setScope(.recording, for: .newFromText)
        XCTAssertEqual(manager.scope(of: .newFromText), .app, "a scope the action may not be given changes nothing")

        manager.resetToDefault(.newFromText)

        XCTAssertEqual(manager.scope(of: .newFromText), .library)
        XCTAssertFalse(manager.isEdited(.newFromText))
        XCTAssertEqual(manager.bindingsFor(.showSleepTimer), [shiftCommandT])
        XCTAssertTrue(manager.handleKeyEvent(press, keyWindow: makeShortcutWindow(.reader), firstResponder: nil))
        XCTAssertEqual(posted.names, [ShortcutAction.showSleepTimer.rawValue])
    }

    // MARK: - The Store

    /// The store keeps an action working in a scope the user chose as an
    /// object of its keys and the scope, and every other as before, a list;
    /// both read back to the same record, a store from before scopes reads
    /// as it always did, and an entry naming a scope its action cannot have
    /// keeps its keys and is reported.
    func testTheStoreKeepsAChosenScopeBesideItsKeys() throws {
        var edits = ShortcutEdits([.releaseMediaControls: [shiftR]])
        edits.setScope(.app, for: .newFromText, keys: [shiftCommandT])

        let stored = try XCTUnwrap(edits.storedData.flatMap { String(data: $0, encoding: .utf8) })

        XCTAssertEqual(
            stored,
            #"{"New from Text…":{"keys":[{"command":true,"control":false,"key":"t","option":false,"shift":true}],"worksIn":"app"},"#
                + #""Release Media Controls":[{"command":false,"control":false,"key":"r","option":false,"shift":true}]}"#
        )
        XCTAssertEqual(ShortcutEdits.reading(Data(stored.utf8)), ShortcutEdits.StoredReading(edits: edits, skipped: []))

        let beforeScopes = #"{"Release Media Controls":[{"command":false,"control":false,"key":"r","option":false,"shift":true}]}"#
        XCTAssertEqual(ShortcutEdits.reading(Data(beforeScopes.utf8)).edits, ShortcutEdits([.releaseMediaControls: [shiftR]]))

        let unavailable = #"{"Add Feed…":{"keys":[],"worksIn":"reader"},"Show Sleep Timer":{"keys":[],"worksIn":"kitchen"}}"#
        let reading = ShortcutEdits.reading(Data(unavailable.utf8))
        XCTAssertEqual(reading.edits, ShortcutEdits([.addFeed: [], .showSleepTimer: []]))
        XCTAssertEqual(reading.skipped.map(\.name), ["Add Feed…", "Show Sleep Timer"])
        XCTAssertEqual(reading.skipped.first?.reason, #"works in "reader", which it cannot; working where it does by default"#)
    }
}
