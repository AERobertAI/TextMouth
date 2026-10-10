import XCTest
@testable import TextMouth

/// The shortcut manager on the record of the user's edits (FR12): which
/// changes make an action the user's, the one rule a key's owner follows
/// whichever way a key is given, Reset to Default and Reset to Defaults, and
/// following the record in its store, the move to it included.
@MainActor
final class ShortcutManagerTests: XCTestCase {

    // MARK: - Keys Used Below

    private let plainW = KeyBinding(key: "w")
    private let plainK = KeyBinding(key: "k")
    private let space = KeyBinding(key: "space")
    private let shiftR = KeyBinding(key: "r", shift: true)
    private let optionW = KeyBinding(key: "w", option: true)

    /// A manager on a store of the test's own, watching no key presses.
    private func makeManager(_ label: String) -> (manager: KeyboardShortcutManager, store: UserDefaults) {
        let store = makeSandboxedPreferences("shortcut-manager-\(label)")
        return (KeyboardShortcutManager(userDefaults: store, installsEventMonitor: false), store)
    }

    // MARK: - What Makes an Action the User's

    /// Recording, replacing, or removing a key makes the action the user's;
    /// losing a key to another action does not, and the action goes without
    /// it while the other holds it.
    func testAChangeMakesAnActionTheUsersAndLosingAKeyDoesNot() {
        let (manager, store) = makeManager("edited")

        manager.addBinding(plainK, to: .whereAmI)

        XCTAssertTrue(manager.isEdited(.whereAmI))
        XCTAssertEqual(manager.bindingsFor(.whereAmI), [plainW, plainK])
        XCTAssertFalse(manager.isEdited(.togglePlayback), "losing K never makes Play / Pause the user's")
        XCTAssertEqual(manager.bindingsFor(.togglePlayback), [space])
        XCTAssertEqual(KeyboardShortcutManager.editsPreference.read(from: store), ShortcutEdits([.whereAmI: [plainW, plainK]]))

        manager.removeBinding(space, from: .togglePlayback)
        XCTAssertTrue(manager.isEdited(.togglePlayback))
        XCTAssertEqual(manager.bindingsFor(.togglePlayback), [], "an action edited to have no key has none")
    }

    /// Keys that leave an unedited action exactly as it is change nothing:
    /// it stays TextMouth's, and nothing is saved.
    func testKeysThatChangeNothingLeaveAnActionUnedited() {
        let (manager, store) = makeManager("unchanged")

        manager.addBinding(space, to: .togglePlayback)
        manager.updateBindings(for: .whereAmI, to: [plainW])
        manager.removeBinding(KeyBinding(key: "q"), from: .goToLibrary)

        XCTAssertEqual(manager.edits, ShortcutEdits())
        XCTAssertNil(store.object(forKey: KeyboardShortcutManager.editsPreference.key))
    }

    /// An edited action set back to its default keys stays the user's, as
    /// the user asked on October 7 (question 5), until Reset to Default.
    func testAnEditedActionSetBackToItsDefaultStaysEdited() {
        let (manager, _) = makeManager("set-back")
        manager.updateBindings(for: .whereAmI, to: [optionW])

        manager.updateBindings(for: .whereAmI, to: [plainW])

        XCTAssertTrue(manager.isEdited(.whereAmI))
        XCTAssertEqual(manager.edits, ShortcutEdits([.whereAmI: [plainW]]))

        manager.resetToDefault(.whereAmI)
        XCTAssertFalse(manager.isEdited(.whereAmI))
        XCTAssertEqual(manager.bindingsFor(.whereAmI), [plainW])
    }

    // MARK: - One Owner for Each Key

    /// Replacing a key with one another action has, as recording on a key's
    /// button does, takes the key from that action: the replace path no
    /// longer leaves one key on two actions, edited or not.
    func testReplacingAKeyTakesItFromTheActionThatHadIt() {
        let (manager, _) = makeManager("replace")
        manager.updateBindings(for: .releaseMediaControls, to: [shiftR])

        manager.updateBindings(for: .whereAmI, to: [plainK])
        manager.updateBindings(for: .goToLibrary, to: [shiftR])

        XCTAssertEqual(manager.bindingsFor(.whereAmI), [plainK])
        XCTAssertEqual(manager.bindingsFor(.togglePlayback), [space], "the unedited action lost K")
        XCTAssertFalse(manager.isEdited(.togglePlayback))
        XCTAssertEqual(manager.bindingsFor(.goToLibrary), [shiftR])
        XCTAssertEqual(manager.bindingsFor(.releaseMediaControls), [], "the edited action lost Shift-R")
        XCTAssertTrue(manager.isEdited(.releaseMediaControls), "and stays edited")
        for scope in [ShortcutScope.app, .audioEditor] {
            let keys = ShortcutAction.allCases.filter { $0.scope == scope }.flatMap(manager.bindingsFor)
            XCTAssertEqual(keys.count, Set(keys).count, "a key on two actions in \(scope)")
        }
    }

    // MARK: - Resetting

    /// Reset to Default gives one action back to its defaults, publishing
    /// once; a key it held goes back to the unedited action whose default it
    /// is, and every other edit stays.
    func testResetToDefaultGivesOneActionBack() {
        let (manager, _) = makeManager("reset-one")
        manager.addBinding(plainK, to: .whereAmI)
        manager.updateBindings(for: .releaseMediaControls, to: [shiftR])
        var publications = 0
        let subscription = manager.objectWillChange.sink { publications += 1 }

        manager.resetToDefault(.whereAmI)

        subscription.cancel()
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(manager.edits, ShortcutEdits([.releaseMediaControls: [shiftR]]))
        XCTAssertEqual(manager.bindingsFor(.whereAmI), [plainW])
        XCTAssertEqual(manager.bindingsFor(.togglePlayback), [space, plainK], "K is Play / Pause's again")
    }

    /// Reset to Defaults gives every action back to its defaults and saves
    /// an empty record, even over a store that held none.
    func testResetToDefaultsGivesEveryActionBack() {
        let (manager, store) = makeManager("reset-all")
        manager.updateBindings(for: .releaseMediaControls, to: [shiftR])
        manager.addBinding(plainK, to: .whereAmI)

        manager.resetToDefaults()

        XCTAssertEqual(manager.edits, ShortcutEdits())
        XCTAssertEqual(manager.bindings, ShortcutAction.defaultBindings)
        XCTAssertEqual(store.data(forKey: KeyboardShortcutManager.editsPreference.key), Data("{}".utf8))
    }

    // MARK: - Following the Store

    /// A manager made before the move to the record ran sees every default,
    /// and follows the record once the move writes it, publishing once: the
    /// app's settings model runs the move at launch.
    func testAManagerFollowsTheMoveToTheRecord() throws {
        let store = makeSandboxedPreferences("shortcut-manager-move")
        var savedMap = ShortcutAction.defaultBindings
        savedMap[.releaseMediaControls] = [shiftR]
        store.set(try JSONEncoder().encode(savedMap.keyedByRawValue), forKey: KeyboardShortcutManager.savedMapKey)
        let manager = KeyboardShortcutManager(userDefaults: store, installsEventMonitor: false)
        XCTAssertEqual(manager.bindings, ShortcutAction.defaultBindings)
        var publications = 0
        let subscription = manager.objectWillChange.sink { publications += 1 }

        XCTAssertTrue(KeyboardShortcutManager.moveSavedShortcutsIfNeeded(in: store, fileListings: nil))

        subscription.cancel()
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(manager.bindingsFor(.releaseMediaControls), [shiftR])
        XCTAssertEqual(manager.edits, ShortcutEdits([.releaseMediaControls: [shiftR]]))
        XCTAssertFalse(KeyboardShortcutManager.moveSavedShortcutsIfNeeded(in: store, fileListings: nil), "the move runs once")
    }

    /// The double-press time (FR12) is half a second while the store holds
    /// none; the Shortcuts tab's stepper saves it in tenths within 0.2 to 2
    /// seconds, and a change made in the store by anyone, config.json
    /// applied included, is published once and is in force at once.
    func testTheDoublePressTimeFollowsTheStoreInTenths() {
        let (manager, store) = makeManager("double-press-time")
        XCTAssertEqual(manager.doublePressTime, 0.5)
        var publications = 0
        let subscription = manager.objectWillChange.sink { publications += 1 }

        manager.setDoublePressTime(0.7999999999999999)
        XCTAssertEqual(manager.doublePressTime, 0.8)
        XCTAssertEqual(store.double(forKey: KeyboardShortcutManager.doublePressTimePreference.key), 0.8)
        XCTAssertEqual(publications, 1)

        manager.setDoublePressTime(0.8)
        XCTAssertEqual(publications, 1, "the same time publishes nothing")

        store.set(9.0, forKey: KeyboardShortcutManager.doublePressTimePreference.key)
        XCTAssertEqual(manager.doublePressTime, 2, "a stored value out of range reads as the nearest bound")
        XCTAssertEqual(publications, 2)
        subscription.cancel()
        XCTAssertEqual(KeyboardShortcutManager(userDefaults: store, installsEventMonitor: false).doublePressTime, 2)
    }

    /// A stored record with an entry this build cannot use, an action no
    /// build has yet, loads the rest.
    func testAStoredRecordWithAnUnusableEntryLoadsTheRest() {
        let store = makeSandboxedPreferences("shortcut-manager-lenient")
        let json = #"{"Release Media Controls":[{"command":false,"control":false,"key":"r","option":false,"shift":true}],"Spell Current Word":[]}"#
        store.set(Data(json.utf8), forKey: KeyboardShortcutManager.editsPreference.key)

        let manager = KeyboardShortcutManager(userDefaults: store, installsEventMonitor: false)

        XCTAssertEqual(manager.edits, ShortcutEdits([.releaseMediaControls: [shiftR]]))
        XCTAssertEqual(manager.bindingsFor(.releaseMediaControls), [shiftR])
    }
}
