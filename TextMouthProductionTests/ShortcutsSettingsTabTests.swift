import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The Shortcuts tab with the record of the user's edits (FR12): every key
/// said in words, never in symbols, which a braille display shows as signs;
/// an edited row says "Edited" and offers Reset to Default, as a button and
/// a VoiceOver action; a recorded key is announced, with the action it was
/// taken from. The wording is pinned without a window, since SwiftUI
/// exposes its buttons and rows only to a connected assistive app.
@MainActor
final class ShortcutsSettingsTabTests: XCTestCase {

    // MARK: - Keys in Words

    /// A shortcut is said in words: its modifiers, then its key, a special
    /// key by its name; the screen keeps its symbols.
    func testEveryKeyIsSaidInWords() {
        let said: [(KeyBinding, String)] = [
            (KeyBinding(key: "rightArrow", command: true), "Command + Right Arrow"),
            (KeyBinding(key: "leftArrow", command: true), "Command + Left Arrow"),
            (KeyBinding(key: "upArrow", command: true, option: true), "Option + Command + Up Arrow"),
            (KeyBinding(key: "downArrow", command: true, shift: true), "Shift + Command + Down Arrow"),
            (KeyBinding(key: "delete", command: true), "Command + Delete"),
            (KeyBinding(key: "escape", shift: true), "Shift + Escape"),
            (KeyBinding(key: "tab", control: true), "Control + Tab"),
            (KeyBinding(key: "return"), "Return"),
            (KeyBinding(key: "space"), "Space"),
            (KeyBinding(key: "b", command: true, option: true, shift: true), "Option + Shift + Command + B"),
            (KeyBinding(key: "[", command: true), "Command + Left Bracket"),
            (KeyBinding(key: "+", command: true), "Command + Plus"),
            (KeyBinding(key: "-", command: true), "Command + Minus"),
            (KeyBinding(key: ",", option: true), "Option + Comma"),
        ]
        for (binding, words) in said {
            XCTAssertEqual(binding.accessibleDisplayString, words)
        }
        XCTAssertEqual(KeyBinding(key: "rightArrow", command: true).displayString, "\u{2318}\u{2192}")
        XCTAssertEqual(KeyBinding(key: "[", command: true).displayString, "\u{2318}[", "the screen keeps a punctuation mark itself")
        XCTAssertEqual(KeyBinding.accessibleDisplayString(for: [KeyBinding(key: "space"), KeyBinding(key: "k")]), "Space or K")
        XCTAssertEqual(KeyBinding.accessibleDisplayString(for: []), "No shortcut")
    }

    /// A shortcut on Forward Delete, Home, End, Page Up, Page Down, Help,
    /// Clear, an F key, or the keypad's Enter is held as the character
    /// AppKit gives the key, as the Shortcuts tab records it, but shown,
    /// spoken, and written in config.json in words, never as that
    /// character (#1452), and read back from either.
    func testKeysWithoutNamesOfTheirOwnAreSaidAndWrittenInWords() throws {
        let keys: [(appKit: Int, keyCode: UInt16, words: String, configName: String)] = [
            (NSDeleteFunctionKey, 117, "Forward Delete", "forwardDelete"),
            (NSHomeFunctionKey, 115, "Home", "home"),
            (NSEndFunctionKey, 119, "End", "end"),
            (NSPageUpFunctionKey, 116, "Page Up", "pageUp"),
            (NSPageDownFunctionKey, 121, "Page Down", "pageDown"),
            (NSHelpFunctionKey, 114, "Help", "help"),
            (NSClearLineFunctionKey, 71, "Clear", "clear"),
            (NSF1FunctionKey, 122, "F1", "f1"),
            (NSF5FunctionKey, 96, "F5", "f5"),
            (NSF13FunctionKey, 105, "F13", "f13"),
            (NSF19FunctionKey, 80, "F19", "f19"),
            (NSF35FunctionKey, 0, "F35", "f35"),
            (0x03, 76, "Enter", "enter"),
        ]
        for key in keys {
            let scalar = try XCTUnwrap(UnicodeScalar(UInt32(key.appKit)), key.words)
            let character = String(Character(scalar))
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .function], timestamp: 10, windowNumber: 0,
                context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: key.keyCode
            ))
            let recorded = try XCTUnwrap(KeyBinding.from(event: event), key.words)

            XCTAssertEqual(recorded.key, character, "\(key.words) is held as AppKit's character")
            XCTAssertEqual(recorded.stroke, recorded, "a press of the key is looked up as the binding recorded")
            XCTAssertEqual(recorded.accessibleDisplayString, "Command + \(key.words)")
            XCTAssertEqual(recorded.displayString, "\u{2318}\(key.words)")
            XCTAssertEqual(recorded.configText, "command+\(key.configName)")
            XCTAssertEqual(recorded.asDoublePress(true).configText, "command+\(key.configName) twice")
            XCTAssertEqual(KeyBinding(configText: "command+\(key.configName)"), recorded)
            XCTAssertEqual(KeyBinding(configText: "Command+\(key.configName.uppercased())"), recorded)
            XCTAssertEqual(KeyBinding(configText: "command+\(character)"), recorded, "\(key.words)'s character reads back too")
            XCTAssertEqual(KeyBinding(configText: "double command+\(key.configName)"), recorded.asDoublePress(true))
        }
    }

    /// Every name in the one table of key names says its key in words with
    /// no character a screen or a braille display cannot show; no two names
    /// share a key, a key code, or config.json's name; and every named key,
    /// with every set of modifiers, reads back from the text config.json
    /// writes for it.
    func testTheTableOfKeyNamesIsWholeAndReadsBack() {
        let names = KeyBinding.keyNames
        func isShowable(_ text: String) -> Bool {
            !text.isEmpty && text.unicodeScalars.allSatisfy { !(0xE000...0xF8FF).contains($0.value) && $0.value >= 0x20 }
        }
        for name in names {
            XCTAssertTrue(isShowable(name.words), name.configName)
            XCTAssertTrue(isShowable(name.shown), name.configName)
            XCTAssertTrue(isShowable(name.configName), name.words)
            for modifiers in 0..<16 {
                let binding = KeyBinding(
                    key: name.key,
                    command: modifiers & 1 != 0,
                    option: modifiers & 2 != 0,
                    shift: modifiers & 4 != 0,
                    control: modifiers & 8 != 0
                )
                XCTAssertEqual(KeyBinding(configText: binding.configText), binding, binding.configText)
                XCTAssertTrue(isShowable(binding.accessibleDisplayString), binding.configText)
            }
        }
        XCTAssertEqual(Set(names.map(\.key)).count, names.count, "a key named twice")
        XCTAssertEqual(Set(names.map { $0.configName.lowercased() }).count, names.count, "a name config.json reads twice")
        let keyCodes = names.compactMap(\.keyCode)
        XCTAssertEqual(Set(keyCodes).count, keyCodes.count, "a key code named twice")
        XCTAssertEqual(KeyBinding.namedKeys, ["space", "tab", "return", "delete", "escape", "leftArrow", "rightArrow", "upArrow", "downArrow"])
    }

    /// A key of the private-use area that no name says is no shortcut: the
    /// Shortcuts tab cannot record it, and config.json cannot name it, so
    /// nothing ever shows or speaks it as a character.
    func testAPrivateUseKeyNoNameSaysIsNoShortcut() throws {
        let character = "\u{F8FF}"
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 10, windowNumber: 0,
            context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0
        ))

        XCTAssertNil(KeyBinding.from(event: event))
        XCTAssertNil(KeyBinding(configText: character))
        XCTAssertNil(KeyBinding(configText: "command+\(character)"))
        XCTAssertTrue(KeyBinding.isUnnamedPrivateUseCharacter(character))
        XCTAssertFalse(KeyBinding.isUnnamedPrivateUseCharacter("\u{F72D}"), "Page Down has a name")
        XCTAssertFalse(KeyBinding.isUnnamedPrivateUseCharacter("k"))
    }

    /// The manager says an action's keys in force in words.
    func testTheManagerSaysAnActionsKeysInWords() {
        let manager = KeyboardShortcutManager(userDefaults: makeSandboxedPreferences("shortcut-tab-words"), installsEventMonitor: false)

        XCTAssertEqual(manager.allDisplayStrings(for: .skipForward), "Command + Right Arrow or L")
        XCTAssertEqual(manager.allDisplayStrings(for: .releaseMediaControls), "No shortcut")
    }

    // MARK: - The Order of the Actions

    /// `ShortcutAction.allCases`, the order the record of edits, the press
    /// index, and the settling of a key two edited actions share all call
    /// Settings order, is the order the Shortcuts tab lists the actions in:
    /// each group whole, the groups as the tab heads them (#1528: Up One
    /// Level came after the Information group, and Show Bookmarks among the
    /// Panels).
    func testEveryActionIsListedWithItsGroup() {
        var groups: [String] = []
        for action in ShortcutAction.allCases where groups.last != action.category {
            XCTAssertFalse(groups.contains(action.category), "\(action.rawValue) is listed apart from \(action.category)")
            groups.append(action.category)
        }

        XCTAssertEqual(
            groups,
            ["Playback", "Navigation", "Bookmarks", "Panels", "Information", "Library", "File", "New Recording", "Audio Editor"]
        )
        let navigation = ShortcutAction.allCases.filter { $0.category == "Navigation" }
        XCTAssertEqual(navigation.last, .navigateUpLevel, "the tab lists Up One Level last of its group, as before")
    }

    // MARK: - A Row

    /// A row's VoiceOver label names the action, its keys in words, and,
    /// for an edited action, "Edited."; an audio editor action keeps its
    /// group's name.
    func testARowSaysItsKeysInWordsAndWhetherItIsEdited() {
        let shiftR = KeyBinding(key: "r", shift: true)

        XCTAssertEqual(
            ShortcutsSettingsWording.rowLabel(for: .releaseMediaControls, keys: [shiftR], isEdited: true),
            "Release Media Controls: Shift + R. Edited."
        )
        XCTAssertEqual(ShortcutsSettingsWording.rowLabel(for: .whereAmI, keys: [KeyBinding(key: "w")], isEdited: false), "Where Am I?: W")
        XCTAssertEqual(ShortcutsSettingsWording.rowLabel(for: .goToLibrary, keys: [], isEdited: true), "Go to Library: No shortcut. Edited.")
        XCTAssertEqual(
            ShortcutsSettingsWording.rowLabel(for: .editorPlayPause, keys: [KeyBinding(key: "space"), KeyBinding(key: "k")], isEdited: false),
            "Audio Editor: Play / Pause: Space or K"
        )
        XCTAssertEqual(ShortcutsSettingsWording.edited, "Edited")
    }

    /// Reset to Default names its action to VoiceOver, and once done says
    /// the keys the action has again.
    func testResetToDefaultNamesItsActionAndSaysTheKeys() {
        XCTAssertEqual(ShortcutsSettingsWording.resetToDefaultTitle, "Reset to Default")
        XCTAssertEqual(ShortcutsSettingsWording.resetToDefaultLabel(for: .releaseMediaControls), "Reset Release Media Controls to Default")
        XCTAssertEqual(
            ShortcutsSettingsWording.resetAnnouncement(for: .nextBookmark, keys: [KeyBinding(key: "b", command: true, option: true, shift: true)]),
            "Next Bookmark reset to default: Option + Shift + Command + B."
        )
        XCTAssertEqual(
            ShortcutsSettingsWording.resetAnnouncement(for: .releaseMediaControls, keys: []),
            "Release Media Controls reset to default: No shortcut."
        )
        XCTAssertFalse(ShortcutsSettingsWording.resetToDefaultHint.isEmpty)
    }

    // MARK: - Recording a Key

    /// A recorded key is announced with the action it was recorded for and,
    /// when another action had it, the one it was taken from; a name ending
    /// in a question mark ends the sentence itself.
    func testARecordedKeyIsAnnouncedWithTheActionItWasTakenFrom() {
        XCTAssertEqual(
            ShortcutsSettingsWording.recorded(KeyBinding(key: "r", shift: true), for: .releaseMediaControls, takenFrom: nil),
            "Shift + R, recorded for Release Media Controls."
        )
        XCTAssertEqual(
            ShortcutsSettingsWording.recorded(KeyBinding(key: "k"), for: .whereAmI, takenFrom: .togglePlayback),
            "K, recorded for Where Am I? Taken from Play / Pause."
        )
        XCTAssertEqual(
            ShortcutsSettingsWording.recorded(KeyBinding(key: "w"), for: .goToLibrary, takenFrom: .whereAmI),
            "W, recorded for Go to Library. Taken from Where Am I?"
        )
    }

    /// The action a recorded key is taken from is the one of the same scope
    /// whose keys in force held it, never one of another scope, as the tab
    /// finds it once the key is recorded (`actions(thatLostKeysSince:besides:)`):
    /// K recorded for Where Am I? is taken from Play / Pause, while the
    /// audio editor's Play/Pause keeps it in its own windows, and Shift-R,
    /// which no action holds where Release Media Controls acts, is taken
    /// from none.
    func testTheActionAKeyIsTakenFromIsTheOneHoldingItInTheScope() {
        let manager = KeyboardShortcutManager(userDefaults: makeSandboxedPreferences("shortcut-tab-owner"), installsEventMonitor: false)
        let k = KeyBinding(key: "k")
        let shiftR = KeyBinding(key: "r", shift: true)
        // Who answers `key` where `action` acts, with the keys in force now.
        let holders = { (key: KeyBinding, action: ShortcutAction) in
            ShortcutKeyOwners.actions(holding: key, in: manager.bindings, sharingAWindowWith: action, scopes: manager.scope(of:))
        }
        XCTAssertEqual(holders(k, .whereAmI), [.togglePlayback])
        XCTAssertEqual(holders(k, .editorPlayPause), [.editorPlayPause])
        XCTAssertEqual(holders(shiftR, .releaseMediaControls), [])

        let keysBeforeK = manager.bindings
        manager.addBinding(k, to: .whereAmI)

        XCTAssertEqual(manager.actions(thatLostKeysSince: keysBeforeK, besides: .whereAmI), [.togglePlayback])
        XCTAssertEqual(holders(k, .whereAmI), [.whereAmI])
        XCTAssertEqual(holders(k, .editorPlayPause), [.editorPlayPause])

        let keysBeforeShiftR = manager.bindings
        manager.addBinding(shiftR, to: .releaseMediaControls)

        XCTAssertEqual(manager.actions(thatLostKeysSince: keysBeforeShiftR, besides: .releaseMediaControls), [])
    }

    // MARK: - Double Presses (FR12, Section 6 of the Design)

    /// The recorder, the actions that change a key's presses, and the
    /// double-press time's stepper say what the design words.
    func testTheDoublePressWordingIsPinned() {
        XCTAssertEqual(ShortcutsSettingsWording.recordingLabel, "Recording shortcut. Press a key, or press it twice for a double press.")
        // Results and keys, never a click (TODO A10).
        XCTAssertEqual(ShortcutsSettingsWording.recordingHint, "Press the new key, or Escape to cancel.")
        XCTAssertEqual(ShortcutsSettingsWording.recordHint, "Records a new shortcut.")
        XCTAssertEqual(ShortcutsSettingsWording.addShortcutLabel, "Add shortcut")
        XCTAssertEqual(ShortcutsSettingsWording.makeDoublePress, "Make Double Press")
        XCTAssertEqual(ShortcutsSettingsWording.makeSinglePress, "Make Single Press")
        XCTAssertEqual(ShortcutsSettingsWording.pressChange(for: KeyBinding(key: "w")), "Make Double Press")
        XCTAssertEqual(ShortcutsSettingsWording.pressChange(for: KeyBinding(key: "w", isDoublePress: true)), "Make Single Press")
        XCTAssertEqual(ShortcutsSettingsWording.doublePressTimeLabel, "Double press time")
        XCTAssertEqual(
            ShortcutsSettingsWording.doublePressTimeHint,
            "How soon a second press must follow the first to make a double press. "
                + "A key with a different action for each waits this long before its single press acts."
        )
    }

    /// The double-press time is said in seconds: tenths as a decimal, and
    /// whole seconds counted as the Miscellaneous tab counts its seconds.
    func testTheDoublePressTimeIsSaidInSeconds() {
        let said: [(Double, String)] = [
            (0.5, "0.5 seconds"), (0.2, "0.2 seconds"), (1, "1 second"), (2, "2 seconds"), (1.5, "1.5 seconds"),
            (0.30000000000000004, "0.3 seconds"), (0.7999999999999999, "0.8 seconds"),
        ]
        for (seconds, words) in said {
            XCTAssertEqual(ShortcutsSettingsWording.seconds(seconds), words, "\(seconds)")
        }
    }

    /// A double press recorded is announced with "twice"; a key whose single
    /// press now waits is announced with its cost, after the action it was
    /// taken from.
    func testADoublePressAndAKeyThatNowWaitsAreAnnounced() {
        let jTwice = KeyBinding(key: "j", isDoublePress: true)
        XCTAssertEqual(
            ShortcutsSettingsWording.recorded(KeyBinding(key: "w", isDoublePress: true), for: .goToLibrary, takenFrom: nil),
            "W twice, recorded for Go to Library."
        )
        XCTAssertEqual(
            ShortcutsSettingsWording.recorded(jTwice, for: .goToLibrary, takenFrom: .whereAmI, nowWaitsBefore: .skipBackward),
            "J twice, recorded for Go to Library. Taken from Where Am I? J now waits before Skip Backward, in case it is pressed twice."
        )
        XCTAssertEqual(
            ShortcutsSettingsWording.nowWaits(KeyBinding(key: "j", command: true), before: .showBookInfo),
            "Command + J now waits before Book Info, in case it is pressed twice."
        )
    }

    /// The manager says which action a key's single press now waits before:
    /// the key's single action, once the key's double press has an
    /// unrelated action, and none for a key whose presses act at once or
    /// whose double press is its single action's own.
    func testTheManagerSaysWhichActionAKeyWaitsBefore() {
        let manager = KeyboardShortcutManager(userDefaults: makeSandboxedPreferences("shortcut-tab-waits"), installsEventMonitor: false)
        let plainJ = KeyBinding(key: "j")
        let jTwice = plainJ.asDoublePress(true)
        XCTAssertNil(manager.waitingAction(for: plainJ, in: .app))

        manager.addBinding(jTwice, to: .goToLibrary)

        XCTAssertEqual(manager.waitingAction(for: plainJ, in: .app), .skipBackward)
        XCTAssertEqual(manager.waitingAction(for: jTwice, in: .app), .skipBackward)
        XCTAssertNil(manager.waitingAction(for: plainJ, in: .audioEditor), "the editor's J has no double press")
        manager.addBinding(KeyBinding(key: "w", isDoublePress: true), to: .whereAmI)
        XCTAssertNil(manager.waitingAction(for: KeyBinding(key: "w"), in: .app), "an action on both presses is its own escalation")
    }

    /// Make Double Press and Make Single Press change a key's presses and
    /// nothing else; the change makes the action the user's, and the single
    /// press it leaves goes back to no action.
    func testMakeDoublePressChangesOnlyTheKeysPresses() {
        let manager = KeyboardShortcutManager(userDefaults: makeSandboxedPreferences("shortcut-tab-make-double"), installsEventMonitor: false)
        let commandI = KeyBinding(key: "i", command: true)
        XCTAssertEqual(commandI.asDoublePress(true), KeyBinding(key: "i", command: true, isDoublePress: true))
        XCTAssertEqual(commandI.asDoublePress(true).asDoublePress(false), commandI)

        manager.updateBindings(for: .showBookInfo, to: [commandI.asDoublePress(true)])

        XCTAssertTrue(manager.isEdited(.showBookInfo))
        XCTAssertEqual(manager.bindingsFor(.showBookInfo), [KeyBinding(key: "i", command: true, isDoublePress: true)])
        XCTAssertEqual(
            ShortcutKeyOwners.actions(holding: commandI, in: manager.bindings, sharingAWindowWith: .showBookInfo, scopes: manager.scope(of:)),
            [],
            "an action holds the single press where Show Book Info acts"
        )
        XCTAssertEqual(manager.allDisplayStrings(for: .showBookInfo), "Command + I twice")
    }

    /// While a recorder records, the shortcut manager leaves every key press
    /// to it and posts nothing, whichever key monitor AppKit asks first;
    /// once it stops, or goes away without saying so, shortcuts act again.
    func testShortcutsWaitWhileARecorderRecords() throws {
        let center = NotificationCenter()
        let manager = KeyboardShortcutManager(
            userDefaults: makeSandboxedPreferences("shortcut-tab-recording"),
            installsEventMonitor: false,
            notificationCenter: center
        )
        var posted = 0
        let subscription = center.publisher(for: ShortcutAction.whereAmI.notificationName).sink { _ in posted += 1 }
        defer { subscription.cancel() }
        let pressW = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 10, windowNumber: 0, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13
        ))
        let recorder = NSObject()

        manager.recordingStarted(by: recorder)
        XCTAssertTrue(manager.isRecordingShortcut)
        XCTAssertFalse(manager.handleKeyEvent(pressW, keyWindow: nil, firstResponder: nil))
        XCTAssertEqual(posted, 0)

        manager.recordingStopped(by: recorder)
        XCTAssertFalse(manager.isRecordingShortcut)
        XCTAssertTrue(manager.handleKeyEvent(pressW, keyWindow: nil, firstResponder: nil))
        XCTAssertEqual(posted, 1)

        autoreleasepool {
            manager.recordingStarted(by: NSObject())
        }
        XCTAssertFalse(manager.isRecordingShortcut, "a recorder that went away records nothing")
    }

    // MARK: - The Recorder (FR12, Section 6.1 of the Design)

    /// One press of a key, and none after it within the time, records a
    /// single press once the time is up, counted from the press.
    func testOnePressRecordsASinglePressWhenTheTimeIsUp() throws {
        let recorder = RecorderHarness(clock: 10.1)

        XCTAssertTrue(recorder.take(KeyBinding(key: "w"), at: 10))
        XCTAssertEqual(recorder.outcomes, [])
        XCTAssertEqual(try XCTUnwrap(recorder.timers.last).delay, 0.4, accuracy: 1e-9)
        recorder.fireTimers()

        XCTAssertEqual(recorder.outcomes, [.recorded(KeyBinding(key: "w"))])
    }

    /// The same key pressed again within the time records a double press,
    /// its modifiers kept; at exactly the time, the first is a single press
    /// and the second goes no further.
    func testTheSameKeyAgainWithinTheTimeRecordsADoublePress() {
        let commandI = KeyBinding(key: "i", command: true)
        let twice = RecorderHarness()
        twice.take(commandI, at: 10)
        XCTAssertTrue(twice.take(commandI, at: 10.3))
        twice.fireTimers()
        XCTAssertEqual(twice.outcomes, [.recorded(commandI.asDoublePress(true))])

        let tooLate = RecorderHarness()
        tooLate.take(commandI, at: 10)
        XCTAssertTrue(tooLate.take(commandI, at: 10.5))
        XCTAssertEqual(tooLate.outcomes, [.recorded(commandI)])
    }

    /// Another key pressed while the first waits records the first as a
    /// single press, and is not recorded itself; a key no binding names
    /// does the same but goes on, as such a key always has.
    func testAnotherKeyRecordsTheFirstAsASinglePress() {
        let recorder = RecorderHarness()
        recorder.take(KeyBinding(key: "w"), at: 10)
        XCTAssertTrue(recorder.take(KeyBinding(key: "k"), at: 10.1))
        XCTAssertFalse(recorder.take(KeyBinding(key: "w"), at: 10.2), "an ended recording takes nothing")
        XCTAssertEqual(recorder.outcomes, [.recorded(KeyBinding(key: "w"))])

        let nameless = RecorderHarness()
        XCTAssertFalse(nameless.take(nil, at: 10), "a key no binding names goes on and starts nothing")
        nameless.take(KeyBinding(key: "w"), at: 10.1)
        XCTAssertFalse(nameless.take(nil, at: 10.2))
        XCTAssertEqual(nameless.outcomes, [.recorded(KeyBinding(key: "w"))])
    }

    /// Escape cancels, before a first press or after one, so it is never
    /// recorded; a held key's repeats are ignored, so holding a key never
    /// records a double press.
    func testEscapeCancelsAndRepeatsAreIgnored() {
        let before = RecorderHarness()
        XCTAssertTrue(before.take(KeyBinding(key: "escape"), at: 10, isEscape: true))
        XCTAssertEqual(before.outcomes, [.cancelled])

        let after = RecorderHarness()
        after.take(KeyBinding(key: "w"), at: 10)
        after.take(KeyBinding(key: "escape"), at: 10.2, isEscape: true)
        after.fireTimers()
        XCTAssertEqual(after.outcomes, [.cancelled])

        let held = RecorderHarness()
        held.take(KeyBinding(key: "w"), at: 10)
        XCTAssertTrue(held.take(KeyBinding(key: "w"), at: 10.3, isRepeat: true))
        XCTAssertTrue(held.take(KeyBinding(key: "w"), at: 10.4, isRepeat: true))
        held.fireTimers()
        XCTAssertEqual(held.outcomes, [.recorded(KeyBinding(key: "w"))])
    }

    /// Cancelled from outside, as the recorder going away does, a recording
    /// ends without an outcome, and its timer does nothing.
    func testARecordingCancelledFromOutsideEndsWithoutAKey() {
        let recorder = RecorderHarness()
        recorder.take(KeyBinding(key: "w"), at: 10)

        recorder.recording.cancel()
        recorder.fireTimers()

        XCTAssertTrue(recorder.recording.hasEnded)
        XCTAssertEqual(recorder.outcomes, [])
    }

    // MARK: - Try a Double Press (FR12, Section 6.2 of the Design)

    /// Try a Double Press says what the design words: "Double press.", or
    /// how far apart two presses came and the time that would count them as
    /// one, or that no time can when they came more than two seconds apart.
    func testTryADoublePressSaysWhatThePressesMade() {
        XCTAssertEqual(ShortcutsSettingsWording.tryDoublePressTitle, "Try a Double Press")
        XCTAssertEqual(
            ShortcutsSettingsWording.tryDoublePressHint,
            "For five seconds, the next two presses of any key are no shortcuts, and TextMouth says whether they make a double press."
        )
        XCTAssertEqual(ShortcutsSettingsWording.tryDoublePressPrompt, "Press a key twice.")
        let said: [(DoublePressTrial.Outcome, String)] = [
            (.doublePress, "Double press."),
            (.tooFarApart(0.7), "Two presses, 0.7 seconds apart. Set the time above 0.7 seconds to count them as one."),
            (.tooFarApart(0.66), "Two presses, 0.7 seconds apart. Set the time above 0.7 seconds to count them as one."),
            (.tooFarApart(1), "Two presses, 1 second apart. Set the time above 1 second to count them as one."),
            (.tooFarApart(1.94), "Two presses, 1.9 seconds apart. Set the time above 1.9 seconds to count them as one."),
            (.tooFarApart(1.96), "Two presses, 2 seconds apart. The double press time goes up to 2 seconds."),
            (.tooFarApart(3.42), "Two presses, 3.4 seconds apart. The double press time goes up to 2 seconds."),
            (.differentKeys, "Two different keys. A double press is one key pressed twice."),
            (.noSecondPress, "No key was pressed twice."),
        ]
        for (outcome, words) in said {
            XCTAssertEqual(ShortcutsSettingsWording.trialResult(outcome), words)
        }
    }

    // MARK: - The Double-Press Time's Stepper

    /// The stepper says its label, the time in seconds, and its hint, as
    /// VoiceOver reads them; stepping it up saves a tenth of a second more,
    /// said at once. Without an assistive app's view of hosted windows the
    /// test is skipped, and the wording above holds either way.
    func testTheDoublePressStepperSaysTheTime() throws {
        let manager = KeyboardShortcutManager(userDefaults: makeSandboxedPreferences("shortcut-tab-stepper"), installsEventMonitor: false)

        try withHostedControls(DoublePressTimeStepper().environmentObject(manager)) { controls in
            let stepper = try XCTUnwrap(controls.first { $0.role == .incrementor }, "\(controls.map(\.label))")
            XCTAssertEqual(stepper.label, ShortcutsSettingsWording.doublePressTimeLabel)
            XCTAssertEqual(stepper.valueDescription, "0.5 seconds")
            XCTAssertEqual(stepper.hint, ShortcutsSettingsWording.doublePressTimeHint)

            _ = stepper.element.accessibilityPerformIncrement()

            XCTAssertEqual(manager.doublePressTime, 0.6)
            XCTAssertTrue(waitUntil { stepper.element.accessibilityValueDescription() == "0.6 seconds" })
        }
    }

    // MARK: - The Row on Screen

    /// An edited row is one element whose label ends "Edited." and whose
    /// VoiceOver action is Reset to Default; an unedited row offers none.
    /// SwiftUI builds these elements only for an assistive app, so without
    /// one the test is skipped; the wording above holds either way.
    func testAnEditedRowOffersResetToDefaultToVoiceOver() throws {
        let manager = KeyboardShortcutManager(userDefaults: makeSandboxedPreferences("shortcut-tab-row"), installsEventMonitor: false)
        manager.updateBindings(for: .releaseMediaControls, to: [KeyBinding(key: "r", shift: true)])
        let editedLabel = "Release Media Controls: Shift + R. Edited."
        let view = VStack {
            ShortcutBindingRow(action: .releaseMediaControls)
            ShortcutBindingRow(action: .whereAmI)
        }
        .environmentObject(manager)

        try withHostedView(view, until: { !self.accessibilityElements(labelled: editedLabel, in: $0).isEmpty }) { hosting in
            guard let edited = accessibilityElements(labelled: editedLabel, in: hosting).first else {
                throw XCTSkip("SwiftUI exposed no accessibility elements without an assistive app")
            }
            XCTAssertEqual((edited.accessibilityCustomActions() ?? []).map(\.name), [ShortcutsSettingsWording.resetToDefaultTitle])
            let unedited = accessibilityElements(labelled: "Where Am I?: W", in: hosting).first
            XCTAssertEqual((unedited?.accessibilityCustomActions() ?? []).map(\.name), [])
        }
    }
}

/// A recording of the Shortcuts tab's recorder with a clock the test sets
/// and timers it fires by hand, keeping every outcome. The recording's
/// closures capture a record of their own rather than the harness.
@MainActor
final class RecorderHarness {
    /// What the recording's closures read and write.
    private final class Record {
        /// The time the clock reads.
        var now: TimeInterval = 0
        /// Every timer started, oldest first.
        var timers: [HandFiredTimer] = []
        /// Every outcome, oldest first.
        var outcomes: [ShortcutRecording.Outcome] = []
    }

    /// The recording under test, with a double-press time of half a second.
    let recording: ShortcutRecording
    /// What its closures read and write.
    private let record: Record

    /// Every timer started, oldest first.
    var timers: [HandFiredTimer] {
        record.timers
    }

    /// Every outcome, oldest first.
    var outcomes: [ShortcutRecording.Outcome] {
        record.outcomes
    }

    /// A recording whose clock reads `clock`, or the time of each press
    /// taken when nil.
    init(clock: TimeInterval? = nil) {
        let record = Record()
        self.record = record
        let fixedClock = clock
        recording = ShortcutRecording(
            doublePressTime: 0.5,
            clock: { fixedClock ?? record.now },
            startTimer: { delay, fire in
                let timer = HandFiredTimer(delay: delay, fire: fire)
                record.timers.append(timer)
                return timer
            },
            finish: { record.outcomes.append($0) }
        )
    }

    /// Hands the recording a press of `stroke` at `time`, and returns
    /// whether it took it.
    @discardableResult
    func take(_ stroke: KeyBinding?, at time: TimeInterval, isRepeat: Bool = false, isEscape: Bool = false) -> Bool {
        record.now = time
        return recording.take(stroke, at: time, isRepeat: isRepeat, isEscape: isEscape)
    }

    /// Fires every timer started and not cancelled.
    func fireTimers() {
        timers.forEach { $0.fire() }
    }
}
