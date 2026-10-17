import AppKit
import XCTest
@testable import TextMouth

/// Speak Info's place in the key map (October 7, 2026; moved to
/// Shift-Command-I on October 17, 2026, so that a letter alone jumps to
/// books in a Library window): the action, its default key, its
/// notification, the menu item, and that the key clashes with nothing else
/// in the app's scope while Book Info keeps Command-I.
@MainActor
final class SpeakInfoShortcutTests: XCTestCase {

    /// Speak Info's default key since October 17: Shift-Command-I.
    private let shiftCommandI = KeyBinding(key: "i", command: true, shift: true)

    // MARK: - The Action and Its Key

    /// The action is "Speak Info" (config.json's key for it), Shift-Command-I
    /// by default, in the app's scope, listed in Settings beside Where Am I?
    /// under Information, and posts its own notification.
    func testSpeakInfoIsShiftCommandIBesideWhereAmI() {
        XCTAssertEqual(ShortcutAction.speakInfo.rawValue, "Speak Info")
        XCTAssertEqual(ShortcutAction.speakInfo.title, "Speak Info")
        XCTAssertEqual(ShortcutAction(rawValue: "Speak Info"), .speakInfo)
        XCTAssertEqual(ShortcutAction.defaultBindings[.speakInfo], [shiftCommandI])
        XCTAssertEqual(ShortcutAction.speakInfo.defaultScope, .app)
        XCTAssertEqual(ShortcutAction.speakInfo.category, "Information")
        XCTAssertEqual(ShortcutAction.speakInfo.category, ShortcutAction.whereAmI.category)
        XCTAssertEqual(ShortcutAction.speakInfo.notificationName, .speakInfo)
        XCTAssertEqual(Notification.Name.speakInfo.rawValue, "speakInfo")
        // Settings shows the key as the others: by its display strings.
        XCTAssertEqual(shiftCommandI.displayString, "⇧⌘I")
        XCTAssertEqual(shiftCommandI.accessibleDisplayString, "Shift + Command + I")
        // config.json writes the modifiers in Settings' order, then the key.
        XCTAssertEqual(shiftCommandI.configText, "shift+command+i")
        XCTAssertEqual(
            ShortcutAction.defaultBindings[.speakFullInfo],
            [KeyBinding(key: "i", command: true, shift: true, isDoublePress: true)]
        )
    }

    /// No other action outside the audio editor has a plain I by default
    /// (a letter alone belongs to the Library list's letter navigation), no
    /// action but Speak Info has Shift-Command-I, and Book Info keeps
    /// Command-I. The audio editor's Mark In has I too, in its own scope,
    /// where the app's shortcuts never match.
    func testNoAppShortcutIsAPlainIAndBookInfoKeepsCommandI() {
        let plainI = KeyBinding(key: "i")
        let plainOwners = ShortcutAction.allCases.filter { action in
            action.defaultScope != .audioEditor && ShortcutAction.defaultBindings[action]?.contains(plainI) == true
        }
        XCTAssertEqual(plainOwners, [])
        let shiftCommandOwners = ShortcutAction.allCases.filter {
            ShortcutAction.defaultBindings[$0]?.contains(shiftCommandI) == true
        }
        XCTAssertEqual(shiftCommandOwners, [.speakInfo])
        XCTAssertEqual(ShortcutAction.defaultBindings[.showBookInfo], [KeyBinding(key: "i", command: true)])
        XCTAssertEqual(ShortcutAction.defaultBindings[.editorMarkIn], [plainI])
        XCTAssertEqual(ShortcutAction.editorMarkIn.defaultScope, .audioEditor)
        // Every kind of window stays free of shared defaults: New from Text
        // and Show Sleep Timer share Shift-Command-T, each in its own kind of
        // window (FR12's branch E).
        XCTAssertEqual(ShortcutKeyOwners.keysOnTwoActions(in: ShortcutAction.defaultBindings), [])
    }

    /// Typing an I in the search field, or any text field, never speaks
    /// the selection's information: a plain key is left to typing, as the
    /// manager treats every plain key; Shift-Command-I acts from a field, as
    /// Command-I does.
    func testTypingAnIInAFieldNeverSpeaksInfo() {
        let plainI = KeyBinding(key: "i")
        XCTAssertFalse(KeyboardShortcutManager.shouldHandle(binding: plainI, whenTextInputIsFocused: true))
        XCTAssertTrue(KeyboardShortcutManager.shouldHandle(binding: plainI, whenTextInputIsFocused: false))
        XCTAssertTrue(KeyboardShortcutManager.shouldHandle(binding: shiftCommandI, whenTextInputIsFocused: true))
        XCTAssertTrue(KeyboardShortcutManager.shouldHandle(binding: KeyBinding(key: "i", command: true), whenTextInputIsFocused: true))
    }

    /// A user who put Shift-Command-I on another action keeps it there: the
    /// whole map saved then moves to a record with that action edited
    /// (FR12), and the new default is left out rather than put on two
    /// actions, as every new default is.
    func testAnOlderCustomShiftCommandIKeepsItsActionAndLeavesSpeakInfoUnbound() {
        let moved = ShortcutEdits.migrating(savedMap: [.whereAmI: [shiftCommandI]], fileLists: nil)
        let loaded = moved.edits.effectiveBindings(defaults: ShortcutAction.defaultBindings)
        XCTAssertEqual(loaded[.whereAmI], [shiftCommandI])
        XCTAssertEqual(loaded[.speakInfo], [])
        // With no such binding, the default is adopted.
        XCTAssertEqual(ShortcutEdits().effectiveBindings(defaults: ShortcutAction.defaultBindings)[.speakInfo], [shiftCommandI])
    }

    // MARK: - The Menu

    /// The Library menu, the one shown while a Library window is key,
    /// offers Speak Info, named as the action is.
    func testTheLibraryMenuOffersSpeakInfo() throws {
        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        let library = try XCTUnwrap(mainMenu.items.first { $0.title == "Library" }?.submenu, "no Library menu")
        let titles = library.items.map(\.title)
        XCTAssertTrue(titles.contains(ShortcutAction.speakInfo.title), titles.joined(separator: ", "))
        XCTAssertTrue(MenuVisibilityManager.libraryMenuTitles.contains("Library"))
    }
}
