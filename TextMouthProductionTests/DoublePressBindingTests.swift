import AppKit
import XCTest
@testable import TextMouth

/// A binding pressed twice (FR12, `KeyBinding.isDoublePress`): every binding
/// saved before the flag existed reads as a single press, a single press is
/// saved exactly as before, a double press is its stroke pressed twice, and
/// the screen, VoiceOver, braille, and config.json all say "twice". This
/// user's record and config.json, in today's exact forms, read unchanged.
/// Nothing here reads the user's own files or preferences.
@MainActor
final class DoublePressBindingTests: XCTestCase {

    // MARK: - Keys Used Below

    private let shiftR = KeyBinding(key: "r", shift: true)
    private let plainW = KeyBinding(key: "w")
    private let wTwice = KeyBinding(key: "w", isDoublePress: true)
    private let commandITwice = KeyBinding(key: "i", command: true, isDoublePress: true)

    /// The record branch A writes for this user, byte for byte: Release
    /// Media Controls on Shift-R, saved before double presses existed.
    private static let thisUsersRecord =
        #"{"Release Media Controls":[{"command":false,"control":false,"key":"r","option":false,"shift":true}]}"#

    // MARK: - Saved Before the Flag

    /// A binding saved before double presses existed, with no flag, reads
    /// as a single press: one alone, a list in the whole map every release
    /// before the record saved, and this user's record.
    func testABindingSavedBeforeTheFlagReadsAsASinglePress() throws {
        let saved = #"{"command":false,"control":false,"key":"r","option":false,"shift":true}"#
        let binding = try JSONDecoder().decode(KeyBinding.self, from: Data(saved.utf8))
        XCTAssertEqual(binding, shiftR)
        XCTAssertFalse(binding.isDoublePress)

        // The whole map's form, as the October 5 build saved it, keys unsorted.
        let wholeMap = #"""
        {"Where Am I?":[{"key":"w","command":false,"option":false,"shift":false,"control":false}],
         "Release Media Controls":[{"key":"r","command":false,"option":false,"shift":true,"control":false}]}
        """#
        let map = ShortcutEdits.reading(Data(wholeMap.utf8))
        XCTAssertEqual(map.skipped, [])
        XCTAssertEqual(map.edits, ShortcutEdits([.whereAmI: [plainW], .releaseMediaControls: [shiftR]]))

        let record = ShortcutEdits.reading(Data(Self.thisUsersRecord.utf8))
        XCTAssertEqual(record.skipped, [])
        XCTAssertEqual(record.edits, ShortcutEdits([.releaseMediaControls: [shiftR]]))
    }

    /// A single press is written exactly as before, with no flag, so the
    /// same record is the same bytes; a double press is written with its
    /// flag, and both read back.
    func testASinglePressIsWrittenAsBeforeAndADoublePressWithItsFlag() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(
            String(decoding: try encoder.encode(shiftR), as: UTF8.self),
            #"{"command":false,"control":false,"key":"r","option":false,"shift":true}"#
        )
        XCTAssertEqual(
            String(decoding: try encoder.encode(wTwice), as: UTF8.self),
            #"{"command":false,"control":false,"isDoublePress":true,"key":"w","option":false,"shift":false}"#
        )
        for binding in [shiftR, wTwice, commandITwice] {
            XCTAssertEqual(try JSONDecoder().decode(KeyBinding.self, from: encoder.encode(binding)), binding, binding.configText)
        }
        XCTAssertEqual(
            ShortcutEdits([.releaseMediaControls: [shiftR]]).storedData.map { String(decoding: $0, as: UTF8.self) },
            Self.thisUsersRecord
        )
    }

    /// A saved binding still needs its key and its four modifiers, as every
    /// release wrote them: one without them is unreadable, and left out of
    /// a record while the rest loads.
    func testASavedBindingStillNeedsItsKeyAndModifiers() {
        let record = #"{"Where Am I?":[{"key":"w","isDoublePress":true}],"Release Media Controls":[{"command":false,"control":false,"key":"r","option":false,"shift":true}]}"#

        let reading = ShortcutEdits.reading(Data(record.utf8))

        XCTAssertEqual(reading.edits, ShortcutEdits([.releaseMediaControls: [shiftR]]))
        XCTAssertEqual(reading.skipped.map(\.name), ["Where Am I?"])
    }

    // MARK: - This User's Shortcuts

    /// This user's record and config.json, in the exact forms the build
    /// before double presses writes them, read unchanged: Release Media
    /// Controls keeps Shift-R as the user's one edit, every other action
    /// follows its defaults, and both are written back as they were.
    func testThisUsersRecordAndConfigJSONReadAndWriteUnchanged() throws {
        let store = makeSandboxedPreferences("double-press-this-user")
        store.set(Data(Self.thisUsersRecord.utf8), forKey: KeyboardShortcutManager.editsPreference.key)
        let manager = KeyboardShortcutManager(userDefaults: store, installsEventMonitor: false)
        XCTAssertEqual(manager.edits, ShortcutEdits([.releaseMediaControls: [shiftR]]))
        XCTAssertEqual(manager.bindingsFor(.releaseMediaControls), [shiftR])

        // The design's excerpt of this user's config.json (section 5.1),
        // the full summaries' double presses included (FR12's branch C).
        let entries: [String: ShortcutListing] = [
            "Add Bookmark": "default: command+b",
            "Add to Reading List": "default: none",
            "Next Bookmark": "default: option+shift+command+b",
            "Play / Pause": "default: space, k",
            "Release Media Controls": ["shift+r"],
            "Show Bookmarks": "default: shift+command+b",
            "Speak Full Info": "default: i twice",
            "Speak Info": "default: i",
            "Where Am I?": "default: w",
            "Where Am I? Full Summary": "default: w twice",
        ]
        let file = try JSONEncoder().encode(["keyboardShortcuts": entries])
        let config = try ConfigService.decode(file)
        XCTAssertEqual(config.keyboardShortcuts, entries)
        XCTAssertFalse(KeyboardShortcutManager.adopt(
            SettingsPolicy.keyboardShortcuts.requestedValues(fromConfig: config.keyboardShortcuts),
            in: store
        ))

        XCTAssertEqual(manager.edits, ShortcutEdits([.releaseMediaControls: [shiftR]]))
        XCTAssertEqual(store.data(forKey: KeyboardShortcutManager.editsPreference.key), Data(Self.thisUsersRecord.utf8))
        let defaultsInForce = ShortcutEdits().effectiveBindings(defaults: ShortcutAction.defaultBindings)
        for action in ShortcutAction.allCases where action != .releaseMediaControls {
            XCTAssertEqual(manager.bindingsFor(action), defaultsInForce[action], action.rawValue)
        }
        let written = SettingsPolicy.keyboardShortcuts.fileEntries(manager.edits.listings(defaults: ShortcutAction.defaultBindings))
        // The file may name an action by a former name (the excerpt's Add
        // Bookmark, #1937); TextMouth writes it back under its current name.
        for (name, entry) in entries {
            let currentName = ShortcutAction.exactlyNamed(name)?.rawValue ?? name
            XCTAssertEqual(written[currentName], entry, name)
        }
    }

    // MARK: - The Stroke

    /// A double press is its stroke, the single press, pressed twice: the
    /// two are different bindings, and a key press is the stroke of both.
    func testADoublePressIsItsStrokePressedTwice() throws {
        XCTAssertEqual(wTwice.stroke, plainW)
        XCTAssertEqual(plainW.stroke, plainW)
        XCTAssertEqual(commandITwice.stroke, KeyBinding(key: "i", command: true))
        XCTAssertEqual(KeyBinding(key: "W", shift: true).stroke, KeyBinding(key: "w", shift: true), "a stroke's character is in lower case")
        XCTAssertEqual(KeyBinding(key: "rightArrow", command: true).stroke.key, "rightArrow", "a named key keeps its name")
        XCTAssertNotEqual(wTwice, plainW)
        XCTAssertEqual(Set([wTwice, plainW, wTwice]).count, 2)

        let press = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13
        ))
        // The dispatcher looks a press up by its stroke, which W and W
        // twice share.
        let pressed = try XCTUnwrap(KeyBinding.from(event: press))
        XCTAssertEqual(pressed, plainW.stroke)
        XCTAssertEqual(pressed, wTwice.stroke)
        XCTAssertEqual(pressed, plainW, "a key press is recorded as a single press")
    }

    // MARK: - In Words

    /// The screen, VoiceOver, and braille say "twice" after a double press.
    func testADoublePressIsShownAndSaidWithTwice() {
        XCTAssertEqual(wTwice.accessibleDisplayString, "W twice")
        XCTAssertEqual(commandITwice.accessibleDisplayString, "Command + I twice")
        XCTAssertEqual(commandITwice.displayString, "\u{2318}I twice")
        XCTAssertEqual(plainW.accessibleDisplayString, "W")
        XCTAssertEqual(KeyBinding.accessibleDisplayString(for: [plainW, wTwice]), "W or W twice")
    }

    // MARK: - In config.json

    /// config.json writes "twice" after a double press's shortcut, and an
    /// action following its defaults says it too.
    func testConfigJSONWritesTwiceAfterTheShortcut() {
        XCTAssertEqual(wTwice.configText, "w twice")
        XCTAssertEqual(commandITwice.configText, "command+i twice")
        XCTAssertEqual(KeyBinding(key: "+", command: true, isDoublePress: true).configText, "command++ twice")
        XCTAssertEqual(ShortcutListing.edited([plainW, wTwice]), ["w", "w twice"])
        XCTAssertEqual(ShortcutListing.followingDefaults([wTwice]), "default: w twice")
    }

    /// config.json reads a double press generously: "twice" in any letter
    /// case, with or without the space before it, or "double" before the
    /// shortcut; every binding reads back from the text it writes.
    func testConfigJSONReadsADoublePressGenerously() {
        let read: [(text: String, binding: KeyBinding)] = [
            ("w twice", wTwice),
            ("W Twice", wTwice),
            ("w TWICE", wTwice),
            ("wtwice", wTwice),
            ("  w   twice ", wTwice),
            ("double w", wTwice),
            ("Double W", wTwice),
            ("doublew", wTwice),
            ("Command+I twice", commandITwice),
            ("double cmd+i", commandITwice),
            ("command++ twice", KeyBinding(key: "+", command: true, isDoublePress: true)),
            ("shift+r", shiftR),
            ("d", KeyBinding(key: "d")),
            ("t", KeyBinding(key: "t")),
        ]
        for (text, binding) in read {
            XCTAssertEqual(KeyBinding(configText: text), binding, text)
        }
        for text in ["twice", "double", "w twice twice", "double w twice", "command+twice", "double+w", "w double"] {
            XCTAssertNil(KeyBinding(configText: text), text)
        }
        for binding in [wTwice, commandITwice, KeyBinding(key: "space", option: true, isDoublePress: true)] {
            XCTAssertEqual(KeyBinding(configText: binding.configText), binding, binding.configText)
        }
        XCTAssertEqual(ShortcutListing.text("w twice").bindings, [wTwice])
        XCTAssertEqual(ShortcutListing.list(["w", "double w"]).bindings, [plainW, wTwice])
    }

    // MARK: - In the Record

    /// A single and a double press of one key are two keys: two actions,
    /// edited or not, hold them at once, and a record holds both for one
    /// action; each reads back through config.json.
    func testASingleAndADoublePressOfOneKeyAreTwoKeys() throws {
        var edits = ShortcutEdits()
        edits.setKeys([wTwice], for: .goToLibrary)

        let inForce = edits.effectiveBindings(defaults: ShortcutAction.defaultBindings)

        XCTAssertEqual(inForce[.goToLibrary], [wTwice])
        XCTAssertEqual(inForce[.whereAmI], [plainW], "the single W stays Where Am I?'s")
        let roundTrip = ShortcutEdits().adopting(edits.listings(defaults: ShortcutAction.defaultBindings))
        XCTAssertEqual(roundTrip.edits, edits)
        XCTAssertEqual(roundTrip.sharedKeys, [])
        let stored = try XCTUnwrap(edits.storedData)
        XCTAssertEqual(ShortcutEdits.reading(stored).edits, edits)
    }
}
