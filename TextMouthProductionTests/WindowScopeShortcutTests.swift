import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Shortcuts that work in a kind of window the user chooses (FR12's branch
/// E): which scopes each action may be given, the record keeping a chosen
/// scope beside the action's keys, a change of scope taking keys only where
/// scopes then overlap, Reset to Default giving the default scope back, and
/// the Shortcuts tab's Works in pop-up and what it says. Every store is the
/// test's own, and every announcement is recorded rather than spoken.
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
        XCTAssertEqual(ShortcutAction.searchLibrary.availableScopes, [.app], "Edit's command works in every window")
        XCTAssertEqual(ShortcutAction.recordingStop.availableScopes, [.recording])
        XCTAssertEqual(ShortcutAction.editorPlayPause.availableScopes, [.audioEditor])
        for action in ShortcutAction.allCases {
            XCTAssertTrue(action.availableScopes.contains(action.defaultScope), action.rawValue)
        }
    }

    // MARK: - Naming a Scope

    /// config.json may name a scope by the Works in pop-up's words or by its
    /// short name, in any letter case, with or without spaces, "the", and
    /// "window" or "windows"; each scope's own names name it alone, and a
    /// name naming none is nil. Library and reader windows are said even as
    /// an action's default.
    func testAScopeIsNamedByItsWordsOrItsShortName() {
        let named: [String: ShortcutScope] = [
            "Every window": .app, "every window": .app, "EVERY": .app, "app": .app,
            "Library windows": .library, "library": .library, "LIBRARY WINDOW": .library, "the library": .library,
            "Reader windows": .reader, "reader": .reader, " reader  windows ": .reader,
            "The audio editor": .audioEditor, "audio editor": .audioEditor, "audioEditor": .audioEditor,
            "The recording window": .recording, "recording": .recording, "Recording Window": .recording,
        ]
        for (name, scope) in named {
            XCTAssertEqual(ShortcutScope.named(name), scope, name)
        }
        for scope in ShortcutScope.allCases {
            XCTAssertEqual(ShortcutScope.named(scope.title), scope, scope.title)
            XCTAssertEqual(ShortcutScope.named(scope.rawValue), scope, scope.rawValue)
        }
        for nothing in ["", "the", "windows", "kitchen", "everywhere", "libraries", "editor window"] {
            XCTAssertNil(ShortcutScope.named(nothing), nothing)
        }
        XCTAssertEqual(ShortcutScope.allCases.filter(\.isSaidAsADefault), [.library, .reader])
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

    /// Recording a key takes it only from the actions whose scopes overlap
    /// the recording action's, and the tab names those: Shift-Command-T
    /// recorded for Where Am I?, given reader windows, is taken from Show
    /// Sleep Timer alone, New from Text keeping it in Library windows;
    /// recorded for Play / Pause, which works in every window, it is taken
    /// from both actions that had it then.
    func testRecordingAKeyTakesItOnlyWhereScopesOverlap() {
        let manager = KeyboardShortcutManager(userDefaults: makeSandboxedPreferences("window-scope-recording"), installsEventMonitor: false)
        manager.setScope(.reader, for: .whereAmI)

        var before = manager.bindings
        manager.addBinding(shiftCommandT, to: .whereAmI)

        XCTAssertEqual(manager.actions(thatLostKeysSince: before, besides: .whereAmI), [.showSleepTimer])
        XCTAssertEqual(manager.bindingsFor(.newFromText), [shiftCommandT])
        XCTAssertEqual(
            ShortcutsSettingsWording.recorded(shiftCommandT, for: .whereAmI, takenFrom: [.showSleepTimer]),
            "Shift + Command + T, recorded for Where Am I? Taken from Show Sleep Timer."
        )

        before = manager.bindings
        manager.addBinding(shiftCommandT, to: .togglePlayback)

        XCTAssertEqual(manager.actions(thatLostKeysSince: before, besides: .togglePlayback), [.whereAmI, .newFromText])
        XCTAssertEqual(
            ShortcutsSettingsWording.recorded(shiftCommandT, for: .togglePlayback, takenFrom: [.whereAmI, .newFromText]),
            "Shift + Command + T, recorded for Play / Pause. Taken from Where Am I? and New from Text…"
        )
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

    // MARK: - The Shortcuts Tab

    /// The Works in pop-up names each scope as the user reads it; a row's
    /// label says where its action works when that is one kind of window or
    /// a scope the user chose, and a change of scope, and Reset to Default,
    /// say where it works now, in words that fit a sentence.
    func testTheTabSaysWhereAnActionWorks() {
        XCTAssertEqual(
            ShortcutScope.allCases.map(\.title),
            ["Every window", "Library windows", "Reader windows", "The audio editor", "The recording window"]
        )
        XCTAssertEqual(
            ShortcutScope.allCases.map(\.inSentence),
            ["every window", "Library windows", "reader windows", "the audio editor", "the recording window"]
        )
        XCTAssertEqual(ShortcutsSettingsWording.worksInLabel, "Works in")
        XCTAssertFalse(ShortcutsSettingsWording.worksInHint.isEmpty)

        let commandS = KeyBinding(key: "s", command: true)
        let said: [(label: String, words: String)] = [
            (ShortcutsSettingsWording.rowLabel(for: .showSleepTimer, keys: [shiftCommandT], isEdited: false, worksIn: .reader),
             "Show Sleep Timer: Shift + Command + T. Works in reader windows."),
            (ShortcutsSettingsWording.rowLabel(for: .newFromText, keys: [shiftCommandT], isEdited: true, worksIn: .app),
             "New from Text…: Shift + Command + T. Works in every window. Edited."),
            (ShortcutsSettingsWording.rowLabel(
                for: .showSleepTimer,
                keys: [],
                isEdited: false,
                defaultsHeldElsewhere: [DefaultKeyHeldElsewhere(key: shiftCommandT, holder: .newFromText)],
                worksIn: .reader
            ), "Show Sleep Timer: No shortcut. Works in reader windows. New from Text… has its default, Shift + Command + T."),
            (ShortcutsSettingsWording.rowLabel(for: .whereAmI, keys: [KeyBinding(key: "w")], isEdited: true, worksIn: .library),
             "Where Am I?: W. Works in Library windows. Edited."),
            // Every window, the audio editor, and the Record window go
            // unsaid where they are the action's default.
            (ShortcutsSettingsWording.rowLabel(for: .whereAmI, keys: [KeyBinding(key: "w")], isEdited: false, worksIn: .app),
             "Where Am I?: W"),
            (ShortcutsSettingsWording.rowLabel(for: .editorPlayPause, keys: [KeyBinding(key: "k")], isEdited: false, worksIn: .audioEditor),
             "Audio Editor: Play / Pause: K"),
            (ShortcutsSettingsWording.rowLabel(for: .recordingStop, keys: [commandS], isEdited: true, worksIn: .recording),
             "New Recording: Stop: Command + S. Edited."),
            (ShortcutsSettingsWording.scopeChanged(.newFromText, to: .app, takenFrom: [.showSleepTimer]),
             "New from Text… works in every window. Taken from Show Sleep Timer."),
            (ShortcutsSettingsWording.scopeChanged(.whereAmI, to: .reader, takenFrom: []),
             "Where Am I? works in reader windows."),
            (ShortcutsSettingsWording.resetAnnouncement(for: .newFromText, keys: [shiftCommandT], worksIn: .library),
             "New from Text… reset to default: Shift + Command + T. Works in Library windows."),
        ]
        for (label, words) in said {
            XCTAssertEqual(label, words)
        }
    }

    /// The row of an action that may work in more than one kind of window
    /// shows the Works in pop-up of its choices, the scope in force chosen;
    /// choosing another makes the action the user's at once, taking its key
    /// from the action whose scope it now overlaps, and says so. A row whose
    /// action works only where it does by nature shows none.
    func testTheWorksInPopUpChangesWhereAnActionWorks() throws {
        let manager = KeyboardShortcutManager(userDefaults: makeSandboxedPreferences("window-scope-pop-up"), installsEventMonitor: false)
        let view = VStack {
            ShortcutBindingRow(action: .addFeed)
            ShortcutBindingRow(action: .newFromText)
            ShortcutBindingRow(action: .recordingStop)
        }
        .environmentObject(manager)

        let heard = try recordingAnnouncements {
            try withHostedView(view, size: NSSize(width: 600, height: 300), until: { !self.worksInPopUps(in: $0).isEmpty }) { hosting in
                let popUps = worksInPopUps(in: hosting)
                XCTAssertEqual(popUps.count, 1, "only New from Text's row has a choice")
                let popUp = try XCTUnwrap(popUps.first)
                XCTAssertEqual(popUp.itemTitles, ["Every window", "Library windows", "Reader windows"])
                XCTAssertEqual(popUp.titleOfSelectedItem, "Library windows")

                popUp.menu?.performActionForItem(at: 0)

                XCTAssertTrue(waitUntil { manager.scope(of: .newFromText) == .app }, "choosing Every window changed nothing")
                XCTAssertTrue(manager.isEdited(.newFromText))
                XCTAssertEqual(manager.bindingsFor(.showSleepTimer), [], "Show Sleep Timer lost Shift-Command-T in reader windows")
                XCTAssertTrue(waitUntil {
                    hosting.layoutSubtreeIfNeeded()
                    return self.worksInPopUps(in: hosting).first?.titleOfSelectedItem == "Every window"
                }, "the pop-up shows \(self.worksInPopUps(in: hosting).first?.titleOfSelectedItem ?? "nothing")")
            }
        }
        XCTAssertEqual(heard.announcements.map(\.message), ["New from Text… works in every window. Taken from Show Sleep Timer."])
    }

    /// VoiceOver reads the pop-up as "Works in", with the scope in force as
    /// its value and its hint: "Works in, Library windows, pop-up button".
    /// The pop-up AppKit drew carries the label always; the element
    /// VoiceOver lands on lives in the row's accessibility container, which
    /// SwiftUI builds only for a connected assistive app, so without one the
    /// rest is skipped, and the words above hold either way.
    func testVoiceOverReadsTheWorksInPopUp() throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        let manager = KeyboardShortcutManager(userDefaults: makeSandboxedPreferences("window-scope-pop-up-voiceover"), installsEventMonitor: false)
        let view = ShortcutBindingRow(action: .newFromText).environmentObject(manager)

        try withHostedView(view, size: NSSize(width: 600, height: 200), until: { !self.worksInPopUps(in: $0).isEmpty }) { hosting in
            // SwiftUI labels the pop-up it drew as it builds the window's
            // accessibility elements, which asking for them makes it do.
            XCTAssertTrue(waitUntil {
                hosting.layoutSubtreeIfNeeded()
                return !self.worksInControls(in: hosting).isEmpty
                    || self.worksInPopUps(in: hosting).first?.accessibilityLabel() == ShortcutsSettingsWording.worksInLabel
            }, "the pop-up is labelled \(worksInPopUps(in: hosting).first?.accessibilityLabel() ?? "nothing")")
            // The pop-up AppKit drew is checked above; what follows needs the
            // element SwiftUI builds around it, which an in-process read never
            // finds where SwiftUI exposes nothing of its own.
            try skipUnlessSwiftUIExposesItsOwnElements()
            _ = waitUntil { !self.worksInControls(in: hosting).isEmpty }
            guard let popUp = worksInControls(in: hosting).first else {
                throw XCTSkip("SwiftUI exposed no accessibility elements without an assistive app")
            }
            XCTAssertEqual(popUp.element.accessibilityValue() as? String, "Library windows")
            XCTAssertEqual(popUp.hint, ShortcutsSettingsWording.worksInHint)
        }
    }

    /// The pop-up buttons AppKit drew in `view`, which in a row are the
    /// Works in pop-up's.
    private func worksInPopUps(in view: NSView) -> [NSPopUpButton] {
        descendants(of: view, as: NSPopUpButton.self)
    }

    /// The pop-up buttons VoiceOver finds in `view` labelled "Works in".
    private func worksInControls(in view: NSView) -> [AccessibleControl] {
        accessibleControls(in: view).filter { $0.role == .popUpButton && $0.label == ShortcutsSettingsWording.worksInLabel }
    }
}
