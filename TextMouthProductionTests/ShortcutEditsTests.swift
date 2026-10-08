import XCTest
@testable import TextMouth

/// The record of the keyboard shortcuts the user edited (FR12,
/// `ShortcutEdits`): how the store's form is read and written, the keys in
/// force it gives with a build's defaults, how a change takes a key from
/// the action that had it, and how a key two edited actions hold is left to
/// one of them.
@MainActor
final class ShortcutEditsTests: XCTestCase {

    // MARK: - Keys Used Below

    private let plainW = KeyBinding(key: "w")
    private let shiftR = KeyBinding(key: "r", shift: true)
    private let space = KeyBinding(key: "space")
    private let plainK = KeyBinding(key: "k")
    private let shiftCommandB = KeyBinding(key: "b", command: true, shift: true)
    private let optionShiftCommandB = KeyBinding(key: "b", command: true, option: true, shift: true)

    // MARK: - Reading the Store's Form

    /// The whole map every release before the record saved, every action
    /// with its keys keyed by its name, reads in full: the record's stored
    /// form is the same, holding only the edited actions.
    func testTheOldWholeMapFormReadsEveryActionWithItsKeys() throws {
        var map = ShortcutAction.defaultBindings
        map[.releaseMediaControls] = [shiftR]
        map[.nextBookmark] = [shiftCommandB]
        let data = try JSONEncoder().encode(map.keyedByRawValue)

        let reading = ShortcutEdits.reading(data)

        XCTAssertEqual(reading.skipped, [])
        XCTAssertEqual(reading.edits.keysByEditedAction, map)
        XCTAssertEqual(reading.edits.editedActions, ShortcutAction.allCases)
        XCTAssertEqual(reading.edits.keys(of: .releaseMediaControls), [shiftR])
    }

    /// An entry naming no action this build knows, as a later release may
    /// write, and an entry whose keys cannot be read are left out and
    /// reported; every other entry still loads.
    func testUnknownAndUnreadableEntriesAreLeftOutAndTheRestLoads() {
        let json = """
        {
          "Release Media Controls": [{"key": "r", "command": false, "option": false, "shift": true, "control": false}],
          "Speak Full Info": [{"key": "i", "command": false, "option": false, "shift": false, "control": false}],
          "Where Am I?": "w",
          "Go Back": [{"key": 7}],
          "Go to Library": []
        }
        """

        let reading = ShortcutEdits.reading(Data(json.utf8))

        XCTAssertEqual(reading.edits, ShortcutEdits([.releaseMediaControls: [shiftR], .goToLibrary: []]))
        XCTAssertEqual(reading.skipped.map(\.name), ["Go Back", "Speak Full Info", "Where Am I?"])
        XCTAssertEqual(reading.skipped.first?.reason, "could not be read as a list of shortcuts; leaving it out")
        XCTAssertEqual(reading.skipped.dropFirst().first?.reason, "names nothing TextMouth knows; leaving it out")
    }

    /// Data that is not an object of shortcuts at all reads as an empty
    /// record, reported once without a name.
    func testDataThatIsNoObjectReadsAsAnEmptyRecord() {
        for data in [Data("not json".utf8), Data("[1, 2]".utf8), Data("\"w\"".utf8), Data()] {
            let reading = ShortcutEdits.reading(data)
            XCTAssertEqual(reading.edits, ShortcutEdits())
            XCTAssertEqual(reading.skipped, [ShortcutEdits.SkippedEntry(name: nil, reason: "could not be read as keyboard shortcuts; using none")])
        }
    }

    /// Each repair is one debug-log line naming the field and the entry,
    /// in the form every stored-value repair takes.
    func testEachEntryLeftOutIsLoggedOnce() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let source = "shortcut-edits-test-\(UUID().uuidString)"
        let skipped = [
            ShortcutEdits.SkippedEntry(name: "Teleport", reason: "names nothing TextMouth knows; leaving it out"),
            ShortcutEdits.SkippedEntry(name: nil, reason: "could not be read as keyboard shortcuts; using none"),
        ]

        ShortcutEdits.log(skipped, source: source, field: "keyboardShortcutEdits")

        let lines = debugLogLines(containing: source)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.contains {
            $0.contains("STORED_VALUE_REPAIRED \(source) keyboardShortcutEdits.Teleport: names nothing TextMouth knows")
        }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains {
            $0.contains("STORED_VALUE_REPAIRED \(source) keyboardShortcutEdits: could not be read as keyboard shortcuts")
        }, lines.joined(separator: "\n"))
    }

    // MARK: - Writing the Store's Form

    /// The record is written as JSON keyed by the edited actions' names,
    /// with sorted keys, so one record is always the same bytes, and it
    /// reads back as it was; an empty record is an empty object.
    func testTheRecordIsAlwaysTheSameBytesAndReadsBack() throws {
        let edits = ShortcutEdits([.whereAmI: [plainW, plainK], .releaseMediaControls: [shiftR], .goToLibrary: []])
        let data = try XCTUnwrap(edits.storedData)

        for _ in 0..<5 {
            XCTAssertEqual(ShortcutEdits(edits.keysByEditedAction).storedData, data)
        }
        XCTAssertEqual(ShortcutEdits.reading(data), ShortcutEdits.StoredReading(edits: edits, skipped: []))
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let names = ["\"Go to Library\"", "\"Release Media Controls\"", "\"Where Am I?\""]
        let positions = names.compactMap { text.range(of: $0)?.lowerBound }
        XCTAssertEqual(positions.count, names.count, text)
        XCTAssertEqual(positions, positions.sorted(), "entries in sorted order: \(text)")
        let decoded = try JSONDecoder().decode([String: [KeyBinding]].self, from: data)
        XCTAssertEqual(decoded, ["Where Am I?": [plainW, plainK], "Release Media Controls": [shiftR], "Go to Library": []])
        XCTAssertEqual(ShortcutEdits().storedData, Data("{}".utf8))
    }

    // MARK: - The Keys in Force

    /// With nothing edited, every action has exactly its defaults.
    func testAnEmptyRecordGivesEveryActionItsDefaults() {
        XCTAssertEqual(ShortcutEdits().effectiveBindings(defaults: ShortcutAction.defaultBindings), ShortcutAction.defaultBindings)
    }

    /// A default changed by a later release reaches every action the user
    /// never edited, and never one the user did, even one edited back to
    /// the old default keys.
    func testAChangedDefaultReachesAnUneditedActionAndNeverAnEditedOne() {
        let edits = ShortcutEdits([.skipForward: ShortcutAction.defaultBindings[.skipForward] ?? []])
        var laterDefaults = ShortcutAction.defaultBindings
        let commandBracket = KeyBinding(key: "]", command: true, shift: true)
        laterDefaults[.goForward] = [commandBracket]
        laterDefaults[.skipForward] = [KeyBinding(key: "rightArrow", option: true)]

        let inForce = edits.effectiveBindings(defaults: laterDefaults)

        XCTAssertEqual(inForce[.goForward], [commandBracket], "the unedited action follows the new default")
        XCTAssertEqual(inForce[.skipForward], ShortcutAction.defaultBindings[.skipForward], "the edited action keeps its keys")
        XCTAssertTrue(edits.isEdited(.skipForward), "an action edited back to its default keys stays edited")
    }

    /// A new action's default whose key an edited action holds goes
    /// without it: the edited action keeps its key.
    func testANewDefaultNeverTakesAKeyAnEditedActionHolds() {
        let plainI = KeyBinding(key: "i")
        let edits = ShortcutEdits([.whereAmI: [plainW, plainI]])

        let inForce = edits.effectiveBindings(defaults: ShortcutAction.defaultBindings)

        XCTAssertEqual(inForce[.whereAmI], [plainW, plainI])
        XCTAssertEqual(inForce[.speakInfo], [], "Speak Info's I stays with Where Am I?")
        XCTAssertEqual(inForce[.editorMarkIn], [plainI], "the audio editor's I is in a scope of its own")
    }

    /// A key the user gave another action leaves the unedited action
    /// without it, not edited, and it comes back when that action is reset.
    func testAKeyLostToAnotherActionComesBackWhenThatActionIsReset() {
        var edits = ShortcutEdits()
        edits.setKeys([plainW, plainK], for: .whereAmI)

        XCTAssertEqual(edits.effectiveBindings(defaults: ShortcutAction.defaultBindings)[.togglePlayback], [space])
        XCTAssertFalse(edits.isEdited(.togglePlayback), "losing a key never makes an action the user's")

        edits.reset(.whereAmI)

        XCTAssertEqual(edits, ShortcutEdits())
        XCTAssertEqual(edits.effectiveBindings(defaults: ShortcutAction.defaultBindings)[.togglePlayback], [space, plainK])
    }

    /// No key belongs to two actions of one scope in force, even when a
    /// store edited by hand gives one key to two edited actions: the one
    /// Settings lists first keeps it. The two scopes stay apart.
    func testNoKeyIsInForceForTwoActionsOfOneScope() {
        let edits = ShortcutEdits([
            .showBookmarkList: [shiftCommandB],
            .nextBookmark: [shiftCommandB, optionShiftCommandB],
            .editorPlayPause: [plainW],
        ])

        let inForce = edits.effectiveBindings(defaults: ShortcutAction.defaultBindings)

        XCTAssertEqual(inForce[.nextBookmark], [shiftCommandB, optionShiftCommandB], "Next Bookmark is listed first")
        XCTAssertEqual(inForce[.showBookmarkList], [])
        XCTAssertEqual(inForce[.whereAmI], [plainW], "the editor's W leaves the app's alone")
        XCTAssertEqual(inForce[.editorWhereAmI], [], "the editor's own Where Am I? goes without it")
        for scope in [ShortcutScope.app, .audioEditor] {
            let keys = ShortcutAction.allCases.filter { $0.scope == scope }.flatMap { inForce[$0] ?? [] }
            XCTAssertEqual(keys.count, Set(keys).count, "a key in force twice in \(scope)")
        }
    }

    // MARK: - Changing a Record

    /// Setting an action's keys takes each from every other edited action
    /// of its scope, which keeps its other keys and stays edited, even with
    /// no key left; an action of the other scope keeps it.
    func testSettingKeysTakesThemFromOtherEditedActionsOfTheScope() {
        var edits = ShortcutEdits([
            .whereAmI: [plainW, plainK],
            .releaseMediaControls: [shiftR],
            .editorStop: [plainK],
        ])

        edits.setKeys([plainK, shiftR, plainK], for: .goToLibrary)

        XCTAssertEqual(edits.keys(of: .goToLibrary), [plainK, shiftR], "each key once, in the order given")
        XCTAssertEqual(edits.keys(of: .whereAmI), [plainW])
        XCTAssertEqual(edits.keys(of: .releaseMediaControls), [], "an edited action left with no key stays edited")
        XCTAssertEqual(edits.keys(of: .editorStop), [plainK], "the editor's scope is apart")
        XCTAssertEqual(edits.editedActions, [.releaseMediaControls, .goToLibrary, .whereAmI, .editorStop])
    }

    // MARK: - A Key Two Edited Actions Hold

    /// The holder whose entry changed keeps the key; when both changed, or
    /// neither did, the one Settings lists first keeps it. The other goes
    /// without it, keeps its other keys, and stays edited.
    func testASharedKeyGoesToTheChangedHolderElseTheFirstListed() {
        let edits = ShortcutEdits([
            .nextBookmark: [shiftCommandB],
            .showBookmarkList: [shiftCommandB, KeyBinding(key: "l", command: true, shift: true)],
        ])

        let showChanged = edits.resolvingSharedKeys(favoring: [.showBookmarkList])
        XCTAssertEqual(showChanged.edits.keys(of: .showBookmarkList), [shiftCommandB, KeyBinding(key: "l", command: true, shift: true)])
        XCTAssertEqual(showChanged.edits.keys(of: .nextBookmark), [], "the loser stays edited with no key")
        XCTAssertEqual(showChanged.sharedKeys, [ShortcutEdits.SharedKey(key: shiftCommandB, keeper: .showBookmarkList, loser: .nextBookmark)])

        for changed: Set<ShortcutAction> in [[], [.nextBookmark, .showBookmarkList], [.nextBookmark]] {
            let settled = edits.resolvingSharedKeys(favoring: changed)
            XCTAssertEqual(settled.edits.keys(of: .nextBookmark), [shiftCommandB], "\(changed)")
            XCTAssertEqual(settled.edits.keys(of: .showBookmarkList), [KeyBinding(key: "l", command: true, shift: true)], "\(changed)")
            XCTAssertEqual(settled.sharedKeys, [ShortcutEdits.SharedKey(key: shiftCommandB, keeper: .nextBookmark, loser: .showBookmarkList)])
        }
    }

    /// Of three holders, the first changed one Settings lists keeps the
    /// key; a key two scopes hold is no conflict; a record with no shared
    /// key comes back as it was.
    func testThreeHoldersAndTwoScopes() {
        let edits = ShortcutEdits([
            .togglePlayback: [plainK],
            .whereAmI: [plainK],
            .goToLibrary: [plainK],
            .editorPlayPause: [plainK],
        ])

        let settled = edits.resolvingSharedKeys(favoring: [.goToLibrary, .whereAmI])

        XCTAssertEqual(settled.edits.keys(of: .goToLibrary), [plainK])
        XCTAssertEqual(settled.edits.keys(of: .togglePlayback), [])
        XCTAssertEqual(settled.edits.keys(of: .whereAmI), [])
        XCTAssertEqual(settled.edits.keys(of: .editorPlayPause), [plainK])
        XCTAssertEqual(settled.sharedKeys.map(\.loser), [.togglePlayback, .whereAmI])
        XCTAssertEqual(Set(settled.sharedKeys.map(\.keeper)), [.goToLibrary])

        let unshared = ShortcutEdits([.whereAmI: [plainW], .releaseMediaControls: [shiftR]])
        XCTAssertEqual(unshared.resolvingSharedKeys(favoring: []).edits, unshared)
        XCTAssertTrue(unshared.resolvingSharedKeys(favoring: []).sharedKeys.isEmpty)
    }

    /// Each settled key is one debug-log line naming the key and both
    /// actions.
    func testEachSharedKeyIsLoggedWithBothActions() throws {
        try TextMouthPaths.ensureDirectoryStructure()
        let source = "shortcut-edits-test-\(UUID().uuidString)"
        let shared = ShortcutEdits.SharedKey(key: shiftCommandB, keeper: .nextBookmark, loser: .showBookmarkList)

        ShortcutEdits.log([shared], source: source, field: "keyboardShortcuts")

        XCTAssertEqual(debugLogLines(containing: source).map { line in
            line.components(separatedBy: "STORED_VALUE_REPAIRED ").last ?? line
        }, [
            "\(source) keyboardShortcuts.Show Bookmarks: shared \"shift+command+b\" with \"Next Bookmark\", "
                + "which keeps it; \"Show Bookmarks\" goes without it",
        ])
    }
}
