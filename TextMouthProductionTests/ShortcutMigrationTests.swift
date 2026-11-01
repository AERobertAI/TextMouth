import XCTest
@testable import TextMouth

/// The move from the whole saved map of every action's keys to the record
/// of the user's edits (FR12, `ShortcutEdits.migrating`), on maps shaped
/// like this user's: 72 actions, saved by the October 5 build, two of them
/// unlike today's defaults. Nothing here reads the user's own files or
/// preferences: every map is built below.
@MainActor
final class ShortcutMigrationTests: XCTestCase {

    // MARK: - Keys Used Below

    private let shiftR = KeyBinding(key: "r", shift: true)
    private let shiftCommandB = KeyBinding(key: "b", command: true, shift: true)
    private let optionShiftCommandB = KeyBinding(key: "b", command: true, option: true, shift: true)
    private let space = KeyBinding(key: "space")
    private let plainK = KeyBinding(key: "k")
    private let plainW = KeyBinding(key: "w")

    // MARK: - This User's Shortcuts

    /// The thirty-three actions added after the October 5 build that wrote
    /// this user's shortcuts: Speak Info, Speak Import Progress, Speak
    /// Download Progress (FR10's feed half), the reading list's four
    /// commands, the two full summaries (FR12), Move to Library… (FR11's
    /// branch D), and the menu commands and Record window buttons whose keys
    /// were fixed before (FR12's branch D), Folder or Feed Settings (FR19),
    /// Next Page, Previous Page, and Go to Page… (PG02, PG03), and Go to View
    /// 1 to Go to View 9 (the Library views of October 30, 2026).
    static let actionsAddedSinceOctober5: Set<ShortcutAction> = ShortcutAction.keyEquivalentActions.union([
        .speakInfo, .speakImportProgress, .speakDownloadProgress, .addToReadingList, .removeFromReadingList,
        .nextInReadingList, .previousInReadingList, .whereAmIFull, .speakFullInfo, .moveToLibrary,
        .folderOrFeedSettings, .nextPage, .previousPage, .goToPage, .nextInFolder, .previousInFolder,
    ]).union(ShortcutAction.goToViewActions)

    /// Every action the October 5 build had, in the order Settings lists
    /// them.
    static var actionsOfTheOctober5Build: [ShortcutAction] {
        ShortcutAction.allCases.filter { !actionsAddedSinceOctober5.contains($0) }
    }

    /// A whole map shaped like this user's: every action of the October 5
    /// build at today's default, but Release Media Controls on Shift-R, the
    /// user's own choice (the action has no default), and Next Bookmark on
    /// Shift-Command-B, its default until March 24, which Show Bookmarks has
    /// had since.
    private func mapShapedLikeThisUsers(including actions: [ShortcutAction] = actionsOfTheOctober5Build) -> [ShortcutAction: [KeyBinding]] {
        var map: [ShortcutAction: [KeyBinding]] = [:]
        for action in actions {
            map[action] = ShortcutAction.defaultBindings[action] ?? []
        }
        map[.releaseMediaControls] = [shiftR]
        map[.nextBookmark] = [shiftCommandB]
        return map
    }

    /// The fixture has this user's shape: 72 actions, two of them unlike
    /// today's defaults, one key on two actions.
    func testTheFixtureIsShapedLikeThisUsersShortcuts() {
        let map = mapShapedLikeThisUsers()
        XCTAssertEqual(map.count, 72)
        let unlikeToday = ShortcutAction.allCases.filter { action in
            map[action].map { $0 != ShortcutAction.defaultBindings[action] } ?? false
        }
        XCTAssertEqual(unlikeToday, [.releaseMediaControls, .nextBookmark])
        XCTAssertEqual(map[.showBookmarkList], [shiftCommandB])
    }

    /// This user's shortcuts, with the saved map and config.json written
    /// together by the October 5 build: Release Media Controls is the only
    /// edit, with Shift-R; Next Bookmark takes today's
    /// Option-Shift-Command-B, so Shift-Command-B is Show Bookmarks' alone;
    /// Speak Info gets I and the reading list's commands no key; every other
    /// action follows today's defaults.
    func testThisUsersShortcutsKeepShiftRAndEndTheShiftCommandBClash() {
        let map = mapShapedLikeThisUsers()

        let migrated = ShortcutEdits.migrating(savedMap: map, fileLists: map)

        assertThisUsersRecord(migrated)
    }

    /// The same when the saved map was written before the audio editor
    /// existed, without its 41 actions, while config.json lists all 72.
    func testThisUsersShortcutsSavedBeforeTheAudioEditorMoveTheSame() {
        let fileLists = mapShapedLikeThisUsers()
        let savedMap = mapShapedLikeThisUsers(including: Self.actionsOfTheOctober5Build.filter { $0.defaultScope != .audioEditor })
        XCTAssertEqual(savedMap.count, 31)

        let migrated = ShortcutEdits.migrating(savedMap: savedMap, fileLists: fileLists)

        assertThisUsersRecord(migrated)
    }

    /// The same from the saved map alone (config.json missing, unreadable,
    /// or only in the cloud at that launch), and from config.json alone.
    func testThisUsersShortcutsMoveTheSameFromEitherCopyAlone() {
        let map = mapShapedLikeThisUsers()

        assertThisUsersRecord(ShortcutEdits.migrating(savedMap: map, fileLists: nil))
        assertThisUsersRecord(ShortcutEdits.migrating(savedMap: nil, fileLists: map))
    }

    /// What every test of this user's shortcuts expects: the record, its
    /// stored bytes, and every action's keys in force.
    private func assertThisUsersRecord(_ migrated: ShortcutEdits.Settlement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(migrated.edits, ShortcutEdits([.releaseMediaControls: [shiftR]]), file: file, line: line)
        XCTAssertEqual(migrated.sharedKeys, [], file: file, line: line)
        XCTAssertEqual(
            migrated.edits.storedData.flatMap { String(data: $0, encoding: .utf8) },
            #"{"Release Media Controls":[{"command":false,"control":false,"key":"r","option":false,"shift":true}]}"#,
            file: file,
            line: line
        )

        let inForce = migrated.edits.effectiveBindings(defaults: ShortcutAction.defaultBindings)
        XCTAssertEqual(inForce[.releaseMediaControls], [shiftR], file: file, line: line)
        XCTAssertEqual(inForce[.nextBookmark], [optionShiftCommandB], file: file, line: line)
        XCTAssertEqual(inForce[.showBookmarkList], [shiftCommandB], file: file, line: line)
        XCTAssertEqual(inForce[.speakInfo], [KeyBinding(key: "i", command: true, shift: true)], file: file, line: line)
        // The full summaries, newer than the map, get their double presses.
        XCTAssertEqual(inForce[.speakFullInfo], [KeyBinding(key: "i", command: true, shift: true, isDoublePress: true)], file: file, line: line)
        XCTAssertEqual(inForce[.whereAmIFull], [KeyBinding(key: "w", isDoublePress: true)], file: file, line: line)
        // Every other action has its defaults in force, as with nothing edited.
        let defaultsInForce = ShortcutEdits().effectiveBindings(defaults: ShortcutAction.defaultBindings)
        for action in ShortcutAction.allCases where action != .releaseMediaControls {
            XCTAssertEqual(inForce[action], defaultsInForce[action], "\(action.rawValue)", file: file, line: line)
        }
    }

    // MARK: - The Rule

    /// Keys equal to the action's default, today's or a former one, count
    /// as never edited, in any order.
    func testKeysEqualToADefaultTodaysOrAFormerOneAreUnedited() {
        let controlOptionUp = KeyBinding(key: "upArrow", option: true, control: true)
        let controlOptionDown = KeyBinding(key: "downArrow", option: true, control: true)
        let map: [ShortcutAction: [KeyBinding]] = [
            .togglePlayback: [plainK, space],
            .moveBookUp: [controlOptionUp],
            .moveBookDown: [controlOptionDown],
            .nextBookmark: [shiftCommandB],
            .whereAmI: [plainW],
        ]

        let migrated = ShortcutEdits.migrating(savedMap: map, fileLists: map)

        XCTAssertEqual(migrated.edits, ShortcutEdits())
        let inForce = migrated.edits.effectiveBindings(defaults: ShortcutAction.defaultBindings)
        XCTAssertEqual(inForce[.moveBookUp], [KeyBinding(key: "upArrow", command: true, shift: true)])
        XCTAssertEqual(inForce[.moveBookDown], [KeyBinding(key: "downArrow", command: true, shift: true)])
        XCTAssertEqual(inForce[.togglePlayback], [space, plainK])
    }

    /// The former defaults are exactly the three that ever changed.
    func testTheFormerDefaultsAreTheThreeThatEverChanged() {
        XCTAssertEqual(ShortcutAction.formerDefaultBindings, [
            .moveBookUp: [[KeyBinding(key: "upArrow", option: true, control: true)]],
            .moveBookDown: [[KeyBinding(key: "downArrow", option: true, control: true)]],
            .nextBookmark: [[shiftCommandB]],
        ])
        for (action, formers) in ShortcutAction.formerDefaultBindings {
            XCTAssertFalse(formers.contains(ShortcutAction.defaultBindings[action] ?? []), "\(action.rawValue)'s former default is today's")
        }
    }

    /// A key the user gave another action leaves the action that had it
    /// without it, and that action unedited; the action given the key is
    /// edited, and in force the first goes on without the key.
    func testAKeyLostToAnotherActionLeavesTheLoserUnedited() {
        let map: [ShortcutAction: [KeyBinding]] = [
            .togglePlayback: [space],
            .whereAmI: [plainW, plainK],
        ]

        let migrated = ShortcutEdits.migrating(savedMap: map, fileLists: map)

        XCTAssertEqual(migrated.edits, ShortcutEdits([.whereAmI: [plainW, plainK]]))
        XCTAssertEqual(migrated.edits.effectiveBindings(defaults: ShortcutAction.defaultBindings)[.togglePlayback], [space])
    }

    /// An action whose keys differ from its default, an empty list among
    /// them, is edited with those keys; an action neither copy lists, such
    /// as one added since, is unedited.
    func testOtherKeysAreEditedAndActionsListedNowhereAreNot() {
        let map: [ShortcutAction: [KeyBinding]] = [
            .goToLibrary: [],
            .goBack: [KeyBinding(key: "[", control: true)],
        ]

        let migrated = ShortcutEdits.migrating(savedMap: map, fileLists: nil)

        XCTAssertEqual(migrated.edits, ShortcutEdits(map))
        XCTAssertFalse(migrated.edits.isEdited(.speakInfo))
    }

    /// One key on two edited actions in the saved map goes to the one
    /// Settings lists first; the other keeps its other keys and stays
    /// edited.
    func testOneKeyOnTwoEditedActionsGoesToTheFirstListed() {
        let commandJ = KeyBinding(key: "j", command: true)
        let map: [ShortcutAction: [KeyBinding]] = [
            .goToLibrary: [commandJ],
            .whereAmI: [plainW, commandJ],
        ]

        let migrated = ShortcutEdits.migrating(savedMap: map, fileLists: map)

        XCTAssertEqual(migrated.edits, ShortcutEdits([.goToLibrary: [commandJ], .whereAmI: [plainW]]))
        XCTAssertEqual(migrated.sharedKeys, [ShortcutEdits.SharedKey(key: commandJ, keeper: .goToLibrary, loser: .whereAmI)])
    }

    /// An edit made in config.json while TextMouth was closed (the file's
    /// list unlike the saved map's) wins over the saved map, and its action
    /// keeps a key it shares with another edited action.
    func testAnEditMadeInTheFileWhileClosedWinsAndKeepsItsKey() {
        let commandJ = KeyBinding(key: "j", command: true)
        let savedMap: [ShortcutAction: [KeyBinding]] = [
            .goToLibrary: [commandJ],
            .whereAmI: [plainW],
            .releaseMediaControls: [shiftR],
        ]
        var fileLists = savedMap
        fileLists[.whereAmI] = [plainW, commandJ]
        fileLists[.releaseMediaControls] = [KeyBinding(key: "r", control: true)]

        let migrated = ShortcutEdits.migrating(savedMap: savedMap, fileLists: fileLists)

        XCTAssertEqual(migrated.edits, ShortcutEdits([
            .goToLibrary: [],
            .whereAmI: [plainW, commandJ],
            .releaseMediaControls: [KeyBinding(key: "r", control: true)],
        ]))
        XCTAssertEqual(migrated.sharedKeys, [ShortcutEdits.SharedKey(key: commandJ, keeper: .whereAmI, loser: .goToLibrary)])
    }

    /// A key given in the file while TextMouth was closed to another action
    /// leaves the action that had it unedited, as the same edit made in
    /// Settings would: what other actions hold is read from the file's
    /// lists where they differ from the saved map.
    func testAKeyMovedInTheFileWhileClosedLeavesTheLoserUnedited() {
        let savedMap = ShortcutAction.defaultBindings.filter { $0.key.defaultScope != .audioEditor }
        var fileLists = savedMap
        fileLists[.whereAmI] = [plainW, plainK]
        fileLists[.togglePlayback] = [space]

        let migrated = ShortcutEdits.migrating(savedMap: savedMap, fileLists: fileLists)

        XCTAssertEqual(migrated.edits, ShortcutEdits([.whereAmI: [plainW, plainK]]))
    }

    /// A user who never changed a shortcut has no saved map: config.json,
    /// which the old release wrote from its defaults, is read alone, its
    /// former defaults unedited too. With neither, the record is empty.
    func testWithoutASavedMapTheFileIsReadAloneAndWithNeitherNothingIsEdited() {
        var fileLists = ShortcutAction.defaultBindings.filter { !Self.actionsAddedSinceOctober5.contains($0.key) }
        fileLists[.moveBookUp] = [KeyBinding(key: "upArrow", option: true, control: true)]

        XCTAssertEqual(ShortcutEdits.migrating(savedMap: nil, fileLists: fileLists).edits, ShortcutEdits())
        XCTAssertEqual(ShortcutEdits.migrating(savedMap: nil, fileLists: nil).edits, ShortcutEdits())
        XCTAssertEqual(ShortcutEdits.migrating(savedMap: [:], fileLists: [:]).edits, ShortcutEdits())
    }
}
