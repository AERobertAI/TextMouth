import AppKit
import XCTest
@testable import TextMouth

/// Speak Info's place in the key map (October 7, 2026): the action, its
/// default key, the plain I, its notification, the menu item, and that the
/// key clashes with nothing else in the app's scope while Book Info keeps
/// Command-I.
@MainActor
final class SpeakInfoShortcutTests: XCTestCase {

    // MARK: - The Action and Its Key

    /// The action is "Speak Info" (config.json's key for it), the plain I
    /// key by default, in the app's scope, listed in Settings beside Where
    /// Am I? under Information, and posts its own notification.
    func testSpeakInfoIsThePlainIKeyBesideWhereAmI() {
        XCTAssertEqual(ShortcutAction.speakInfo.rawValue, "Speak Info")
        XCTAssertEqual(ShortcutAction.speakInfo.title, "Speak Info")
        XCTAssertEqual(ShortcutAction(rawValue: "Speak Info"), .speakInfo)
        XCTAssertEqual(ShortcutAction.defaultBindings[.speakInfo], [KeyBinding(key: "i")])
        XCTAssertEqual(ShortcutAction.speakInfo.scope, .app)
        XCTAssertEqual(ShortcutAction.speakInfo.category, "Information")
        XCTAssertEqual(ShortcutAction.speakInfo.category, ShortcutAction.whereAmI.category)
        XCTAssertEqual(ShortcutAction.speakInfo.notificationName, .speakInfo)
        XCTAssertEqual(Notification.Name.speakInfo.rawValue, "speakInfo")
        // Settings shows the key as the others: by its display strings.
        XCTAssertEqual(KeyBinding(key: "i").displayString, "I")
        XCTAssertEqual(KeyBinding(key: "i").accessibleDisplayString, "I")
        XCTAssertEqual(KeyBinding(key: "i").configText, "i")
    }

    /// No other action of the app's scope has the plain I by default, and
    /// Book Info keeps Command-I. The audio editor's Mark In has I too, in
    /// its own scope, where the app's shortcuts never match.
    func testThePlainIIsNoOtherAppShortcutAndBookInfoKeepsCommandI() {
        let plainI = KeyBinding(key: "i")
        let owners = ShortcutAction.allCases.filter { action in
            action.scope == .app && ShortcutAction.defaultBindings[action]?.contains(plainI) == true
        }
        XCTAssertEqual(owners, [.speakInfo])
        XCTAssertEqual(ShortcutAction.defaultBindings[.showBookInfo], [KeyBinding(key: "i", command: true)])
        XCTAssertEqual(ShortcutAction.defaultBindings[.editorMarkIn], [plainI])
        XCTAssertEqual(ShortcutAction.editorMarkIn.scope, .audioEditor)
        // The whole app scope stays free of shared defaults.
        var ownersByBinding: [KeyBinding: ShortcutAction] = [:]
        for action in ShortcutAction.allCases where action.scope == .app {
            for binding in ShortcutAction.defaultBindings[action] ?? [] {
                XCTAssertNil(ownersByBinding[binding], "\(binding.displayString) is \(ownersByBinding[binding]?.rawValue ?? "")'s and \(action.rawValue)'s")
                ownersByBinding[binding] = action
            }
        }
    }

    /// Typing an I in the search field, or any text field, never speaks
    /// the selection's information: a plain key is left to typing, as the
    /// manager treats every plain key; Command-I still opens Book Info from
    /// a field.
    func testTypingAnIInAFieldNeverSpeaksInfo() {
        let plainI = KeyBinding(key: "i")
        XCTAssertFalse(KeyboardShortcutManager.shouldHandle(binding: plainI, whenTextInputIsFocused: true))
        XCTAssertTrue(KeyboardShortcutManager.shouldHandle(binding: plainI, whenTextInputIsFocused: false))
        XCTAssertTrue(KeyboardShortcutManager.shouldHandle(binding: KeyBinding(key: "i", command: true), whenTextInputIsFocused: true))
    }

    /// A user who put the plain I on another action before this release
    /// keeps it there: the whole map saved then moves to a record with that
    /// action edited (FR12), and the new default is left out rather than put
    /// on two actions, as every new default is.
    func testAnOlderCustomIKeepsItsActionAndLeavesSpeakInfoUnbound() {
        let plainI = KeyBinding(key: "i")
        let moved = ShortcutEdits.migrating(savedMap: [.whereAmI: [plainI]], fileLists: nil)
        let loaded = moved.edits.effectiveBindings(defaults: ShortcutAction.defaultBindings)
        XCTAssertEqual(loaded[.whereAmI], [plainI])
        XCTAssertEqual(loaded[.speakInfo], [])
        // With no such binding, the default is adopted.
        XCTAssertEqual(ShortcutEdits().effectiveBindings(defaults: ShortcutAction.defaultBindings)[.speakInfo], [plainI])
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
