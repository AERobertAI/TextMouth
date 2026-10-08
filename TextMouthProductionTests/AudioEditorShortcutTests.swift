import AppKit
import XCTest
@testable import TextMouth

/// The audio editor's shortcuts (FR04): a group of their own, matched only
/// while an editor window is key, so they share Space, J, K, and L with
/// the reader; within the group no two actions share a key, every action
/// has one, and no Command shortcut is a menu command's but the Edit
/// menu's own, which the editor answers itself. A key moved to an editor
/// action leaves the reader's actions alone, and the other way round; and
/// every shortcut is said in words.
@MainActor
final class AudioEditorShortcutTests: XCTestCase {

    /// The editor's actions, in the order Settings lists them.
    private var editorActions: [ShortcutAction] {
        ShortcutAction.allCases.filter { $0.scope == .audioEditor }
    }

    // MARK: - Where the Keys Work

    /// An editor window matches the editor's keys; a sheet over it matches
    /// none, so its fields take every key; every other window, or none,
    /// matches the app's.
    func testTheEditorsKeysAreMatchedOnlyInItsWindows() {
        let editor = AudioEditorWindowController.windowIdentifier
        XCTAssertEqual(KeyboardShortcutManager.scope(windowIdentifier: editor, sheetParentIdentifier: nil), .audioEditor)
        XCTAssertNil(KeyboardShortcutManager.scope(windowIdentifier: nil, sheetParentIdentifier: editor))
        XCTAssertEqual(KeyboardShortcutManager.scope(windowIdentifier: "book-reader-AppWindow-2", sheetParentIdentifier: nil), .app)
        XCTAssertEqual(KeyboardShortcutManager.scope(windowIdentifier: nil, sheetParentIdentifier: "book-reader-AppWindow-2"), .app)
        XCTAssertEqual(KeyboardShortcutManager.scope(windowIdentifier: nil, sheetParentIdentifier: nil), .app)
        XCTAssertEqual(ShortcutAction.togglePlayback.scope, .app)
        XCTAssertEqual(ShortcutAction.editorPlayPause.scope, .audioEditor)
        XCTAssertEqual(ShortcutAction.editorPlayPause.title, "Play / Pause")
        XCTAssertEqual(ShortcutAction.editorPlayPause.category, "Audio Editor")
        XCTAssertEqual(ShortcutAction.togglePlayback.title, "Play / Pause")
        XCTAssertEqual(ShortcutAction.editorPlayPause.notificationName, .audioEditorShortcut)
    }

    // MARK: - The Defaults

    /// Within the editor's group no two actions share a key, every action
    /// has at least one, and its names, with the group's, are unique
    /// among all actions, as config.json keys them.
    func testTheEditorsDefaultsClashWithNothingInTheirGroup() {
        let defaults = ShortcutAction.defaultBindings
        var owners: [KeyBinding: ShortcutAction] = [:]
        for action in editorActions {
            let bindings = defaults[action] ?? []
            XCTAssertFalse(bindings.isEmpty, "\(action.rawValue) has no default shortcut")
            for binding in bindings {
                XCTAssertNil(owners[binding], "\(binding.displayString) is \(owners[binding]?.rawValue ?? "")'s and \(action.rawValue)'s")
                owners[binding] = action
            }
        }
        XCTAssertEqual(Set(ShortcutAction.allCases.map(\.rawValue)).count, ShortcutAction.allCases.count)
        XCTAssertEqual(defaults[.editorPlayPause], [KeyBinding(key: "space"), KeyBinding(key: "k")])
        XCTAssertEqual(defaults[.editorSkipBack], [KeyBinding(key: "j"), KeyBinding(key: ",")])
        XCTAssertEqual(defaults[.editorSkipForward], [KeyBinding(key: "l"), KeyBinding(key: ".")])
    }

    /// No Command shortcut of the editor's is a menu command's, but the
    /// Edit menu's Undo, Redo, Cut, Copy, Paste, and Select All, which the
    /// editor answers itself; so Close, Quit, Minimize, Settings, and the
    /// rest keep working in its window.
    func testTheEditorsCommandShortcutsAreNoMenuCommands() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let editMenuCommands: Set<String> = ["z", "Z", "x", "c", "v", "a"]
        var answered: [String: String] = [:]
        for item in Self.allItems(of: menu) where !item.keyEquivalent.isEmpty {
            let modifiers = item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask)
            answered[Self.signature(item.keyEquivalent, modifiers)] = item.title
        }
        for action in editorActions {
            for binding in ShortcutAction.defaultBindings[action] ?? [] where binding.command || binding.control {
                guard let signature = Self.signature(of: binding) else { continue }
                if let title = answered[signature] {
                    let isEditMenus = editMenuCommands.contains(binding.shift ? binding.key.uppercased() : binding.key)
                    XCTAssertTrue(isEditMenus, "\(action.rawValue)'s \(binding.displayString) is the menu command \(title)'s")
                }
            }
        }
    }

    // MARK: - Changing Them

    /// A key given to an editor action leaves the other editor actions,
    /// and only them: the reader's Space stays.
    func testAKeyMovesOnlyWithinItsGroup() {
        let store = makeSandboxedPreferences("editor-shortcuts")
        let manager = KeyboardShortcutManager(userDefaults: store, installsEventMonitor: false)

        manager.addBinding(KeyBinding(key: "space"), to: .editorStop)

        XCTAssertEqual(manager.bindingsFor(.editorStop), [KeyBinding(key: "s"), KeyBinding(key: "space")])
        XCTAssertEqual(manager.bindingsFor(.editorPlayPause), [KeyBinding(key: "k")])
        XCTAssertEqual(manager.bindingsFor(.togglePlayback), [KeyBinding(key: "space"), KeyBinding(key: "k")])

        manager.addBinding(KeyBinding(key: "s"), to: .whereAmI)
        XCTAssertEqual(manager.bindingsFor(.editorStop), [KeyBinding(key: "s"), KeyBinding(key: "space")], "a reader key took an editor key")
    }

    /// The editor's defaults reach shortcuts saved before the editor
    /// existed, moved to the record of the user's edits (FR12), skipping
    /// only the keys the editor's own group holds.
    func testDefaultsAddedLaterSkipOnlyTheirOwnGroupsKeys() {
        var saved = ShortcutAction.defaultBindings.filter { $0.key.scope == .app }
        saved[.whereAmI] = [KeyBinding(key: "w"), KeyBinding(key: "j", command: true)]

        let moved = ShortcutEdits.migrating(savedMap: saved, fileLists: nil)
        let loaded = moved.edits.effectiveBindings(defaults: ShortcutAction.defaultBindings)

        XCTAssertEqual(moved.edits.editedActions, [.whereAmI])
        XCTAssertEqual(loaded[.editorPlayPause], [KeyBinding(key: "space"), KeyBinding(key: "k")])
        XCTAssertEqual(loaded[.editorWhereAmI], [KeyBinding(key: "w")])
        XCTAssertEqual(loaded[.togglePlayback], [KeyBinding(key: "space"), KeyBinding(key: "k")])
    }

    /// A shortcut config.json gives an editor action moves from the other
    /// editor actions only.
    func testConfigMovesAKeyOnlyWithinItsGroup() {
        let adopted = ShortcutEdits().adopting([.editorStop: ["space"]]).edits
            .effectiveBindings(defaults: ShortcutAction.defaultBindings)

        XCTAssertEqual(adopted[.editorStop], [KeyBinding(key: "space")])
        XCTAssertEqual(adopted[.editorPlayPause], [KeyBinding(key: "k")])
        XCTAssertEqual(adopted[.togglePlayback], [KeyBinding(key: "space"), KeyBinding(key: "k")])
    }

    // MARK: - Words

    /// Every shortcut is said in words, its modifiers first.
    func testShortcutsAreSaidInWords() {
        XCTAssertEqual(AudioEditorWording.spokenShortcut(KeyBinding(key: "j", shift: true)), "Shift-J")
        XCTAssertEqual(AudioEditorWording.spokenShortcut(KeyBinding(key: ",", option: true)), "Option-Comma")
        XCTAssertEqual(AudioEditorWording.spokenShortcut(KeyBinding(key: "upArrow", command: true, option: true)), "Option-Command-Up Arrow")
        XCTAssertEqual(AudioEditorWording.spokenShortcut(KeyBinding(key: "space")), "Space")
        XCTAssertEqual(AudioEditorWording.shortcutSentence([]), "No shortcut.")
        XCTAssertEqual(AudioEditorWording.shortcutSentence([KeyBinding(key: "w")]), "Shortcut: W.")
        XCTAssertEqual(AudioEditorWording.shortcutSentence([KeyBinding(key: "j"), KeyBinding(key: ",")]), "Shortcuts: J or Comma.")
        XCTAssertEqual(
            AudioEditorWording.shortcutSentence([KeyBinding(key: "j"), KeyBinding(key: ","), KeyBinding(key: "delete")]),
            "Shortcuts: J, Comma, or Delete."
        )
        for action in editorActions {
            XCTAssertFalse(AudioEditorWording.explanation(of: action).isEmpty, "\(action.rawValue) says nothing of what it does")
        }
    }

    // MARK: - Helpers

    /// Every item of `menu` and of its submenus.
    private static func allItems(of menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(allItems(of:)) ?? []) }
    }

    /// A menu key equivalent and its modifiers, as one string; a capital
    /// letter counts as Shift held, as AppKit reads it.
    private static func signature(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> String {
        let shift = modifiers.contains(.shift) || key != key.lowercased()
        return "\(modifiers.contains(.control) ? "^" : "")\(modifiers.contains(.option) ? "~" : "")"
            + "\(shift ? "$" : "")\(modifiers.contains(.command) ? "@" : "")\(key.lowercased())"
    }

    /// A binding as a menu would hold it, or nil for a key no menu uses.
    private static func signature(of binding: KeyBinding) -> String? {
        let named: [String: Int] = [
            "upArrow": NSUpArrowFunctionKey, "downArrow": NSDownArrowFunctionKey,
            "leftArrow": NSLeftArrowFunctionKey, "rightArrow": NSRightArrowFunctionKey,
        ]
        let key: String
        if let code = named[binding.key], let scalar = UnicodeScalar(code) {
            key = String(Character(scalar))
        } else if binding.key == "delete" {
            key = "\u{8}"
        } else if binding.key.count == 1 {
            key = binding.key
        } else {
            return nil
        }
        var modifiers: NSEvent.ModifierFlags = []
        if binding.control { modifiers.insert(.control) }
        if binding.option { modifiers.insert(.option) }
        if binding.shift { modifiers.insert(.shift) }
        if binding.command { modifiers.insert(.command) }
        return signature(key, modifiers)
    }
}
