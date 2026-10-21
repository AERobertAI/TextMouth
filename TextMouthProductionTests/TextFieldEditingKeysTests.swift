import AppKit
import Combine
import SwiftUI
import XCTest
@testable import TextMouth

/// B03 (October 7, 2026): what the shortcut manager does with a key pressed
/// while a text field or text view has the keyboard.
///
/// The rule is checked through `KeyboardShortcutManager.shouldHandle` and
/// `TextEditingKeys`, and key presses go through the manager's own
/// decision, `handleKeyEvent(_:keyWindow:firstResponder:)`: each a key
/// press made up for the test, with a stand-in for the first responder, on
/// a manager of the test's own whose notifications go to a center of the
/// test's own, so no key is really pressed and no window of the app hears
/// an action.
@MainActor
final class TextFieldEditingKeysTests: XCTestCase {
    /// The center the test's manager posts its actions on, heard by no
    /// window of the app.
    private let center = NotificationCenter()
    /// The time, on the events' time line, at which the next call of `press`
    /// starts: the Mac's uptime to begin with, ten seconds on for each call.
    private var nextPressTime = ProcessInfo.processInfo.systemUptime

    // MARK: - A Field Being Edited

    /// A text field being edited, SwiftUI's as the app draws them, and a
    /// search field, as the Library's toolbar holds, each hand the keyboard
    /// to the window's field editor, a text view, which the manager counts
    /// as taking text, as it counts every text view, editable or only
    /// selectable. A view that takes no text, such as the Library's list,
    /// and no first responder at all, are not text input.
    func testAFieldBeingEditedIsTextInput() throws {
        let swiftUIField = TextField("Search books", text: .constant("Harbour"))
        try withHostedView(swiftUIField, size: NSSize(width: 320, height: 120), until: {
            !self.descendants(of: $0, as: NSTextField.self).filter(\.isEditable).isEmpty
        }) { hosting in
            let window = try XCTUnwrap(hosting.window)
            let drawnField = try XCTUnwrap(descendants(of: hosting, as: NSTextField.self).first(where: \.isEditable))
            let searchField = NSSearchField(string: "Harbour")
            hosting.addSubview(searchField)
            for field in [drawnField, searchField] {
                guard window.makeFirstResponder(field), let editor = window.firstResponder as? NSTextView else {
                    throw XCTSkip("This macOS gives an offscreen window's field no keyboard focus")
                }
                let name = String(describing: type(of: field))
                XCTAssertTrue(editor.isFieldEditor, "\(name) is not edited through the field editor")
                XCTAssertTrue(field.currentEditor() === editor, "the field editor is not \(name)'s")
                XCTAssertTrue(KeyboardShortcutManager.isTextInput(window.firstResponder), name)
            }
        }

        let readOnly = NSTextView()
        readOnly.isEditable = false
        XCTAssertTrue(KeyboardShortcutManager.isTextInput(readOnly), "a text view read and copied from")
        XCTAssertTrue(KeyboardShortcutManager.isTextInput(NSTextView()), "a text view typed in")
        XCTAssertTrue(KeyboardShortcutManager.isTextInput(NSTextField(string: "")), "a field before its editor")
        XCTAssertFalse(KeyboardShortcutManager.isTextInput(NSTableView()), "a list")
        XCTAssertFalse(KeyboardShortcutManager.isTextInput(NSButton()), "a button")
        XCTAssertFalse(KeyboardShortcutManager.isTextInput(NSView()), "a plain view")
        XCTAssertFalse(KeyboardShortcutManager.isTextInput(nil), "no first responder")
    }

    // MARK: - The Rule

    /// Delete, Forward Delete, the four arrows, Home, End, Page Up, and
    /// Page Down are a field's with each of the sixteen sets of modifiers:
    /// the manager leaves them to a field being edited and acts on them
    /// anywhere else.
    func testDeletingAndMovingKeysAreAFieldsWithAnyModifiers() {
        let keys = [
            "delete", TextEditingKeys.forwardDelete,
            "leftArrow", "rightArrow", "upArrow", "downArrow",
            TextEditingKeys.home, TextEditingKeys.end, TextEditingKeys.pageUp, TextEditingKeys.pageDown,
        ]
        for key in keys {
            for binding in withEveryModifierSet(key) {
                XCTAssertTrue(TextEditingKeys.contains(binding), binding.configText)
                XCTAssertFalse(KeyboardShortcutManager.shouldHandle(binding: binding, whenTextInputIsFocused: true), binding.configText)
                XCTAssertTrue(KeyboardShortcutManager.shouldHandle(binding: binding, whenTextInputIsFocused: false), binding.configText)
            }
        }
    }

    /// The Edit menu's Select All, Copy, Paste, Cut, Undo, and Redo keys
    /// are a field's. Every other key with Command, those letters with
    /// other modifiers included, is an app shortcut and acts from a field:
    /// Book Info, Show Sleep Timer, and the rest. So are Control or Command
    /// with Return or Tab, which end editing or move the keyboard rather
    /// than edit.
    func testTheEditMenusCommandKeysAreAFieldsAndNoOtherCommandKey() throws {
        let editMenus = ["command+a", "command+c", "command+v", "command+x", "command+z", "shift+command+z"]
        let appShortcuts = [
            "command+i", "command+b", "command+e", "command+l", "command+s", "command+f", "command+n",
            "command+[", "command++", "shift+command+t", "shift+command+r", "shift+command+b",
            "option+command+z", "shift+command+a", "option+command+a", "shift+command+c",
            "option+shift+command+v", "control+command+a", "command+return", "control+return", "control+tab",
        ]
        for text in editMenus + appShortcuts {
            let binding = try XCTUnwrap(KeyBinding(configText: text), text)
            let isAFields = editMenus.contains(text)
            XCTAssertEqual(TextEditingKeys.contains(binding), isAFields, text)
            XCTAssertEqual(KeyboardShortcutManager.shouldHandle(binding: binding, whenTextInputIsFocused: true), !isAFields, text)
            XCTAssertTrue(KeyboardShortcutManager.shouldHandle(binding: binding, whenTextInputIsFocused: false), text)
        }
    }

    /// The Edit menu's keys are written once, in `KeyBinding.editMenuCommands`,
    /// with their command names: a field's `editMenuKeys` are those six, and
    /// `systemCommands` (which no shortcut may take) holds all fifteen,
    /// the six with the same names. Paste and Match Style is a system
    /// command's key but no key a field keeps.
    func testTheEditMenuKeysAreWrittenOnceAndSystemCommandsHoldThem() {
        let sixKeys: Set<KeyBinding> = [
            KeyBinding(key: "a", command: true),
            KeyBinding(key: "c", command: true),
            KeyBinding(key: "v", command: true),
            KeyBinding(key: "x", command: true),
            KeyBinding(key: "z", command: true),
            KeyBinding(key: "z", command: true, shift: true),
        ]
        XCTAssertEqual(TextEditingKeys.editMenuKeys, sixKeys)
        XCTAssertEqual(KeyBinding.editMenuCommands.count, 6)
        XCTAssertEqual(KeyBinding.systemCommands.count, 15)
        for (binding, name) in KeyBinding.editMenuCommands {
            XCTAssertEqual(KeyBinding.systemCommands[binding], name, name)
        }
        XCTAssertEqual(KeyBinding.systemCommands[KeyBinding(key: "z", command: true, shift: true)], "Redo")

        let pasteAndMatchStyle = KeyBinding(key: "v", command: true, option: true, shift: true)
        XCTAssertEqual(KeyBinding.systemCommands[pasteAndMatchStyle], "Paste and Match Style")
        XCTAssertFalse(TextEditingKeys.editMenuKeys.contains(pasteAndMatchStyle))
    }

    /// A double press belongs to a field when its stroke does, and a key
    /// spelled in upper case is the same key: the Edit menu's keys are
    /// matched by the stroke, not the whole binding.
    func testADoublePressOrAnUpperCaseKeyIsAFieldsWhenItsStrokeIs() {
        // Double Command-A and double Shift-Command-Z: strokes of the Edit menu.
        XCTAssertTrue(TextEditingKeys.contains(KeyBinding(key: "a", command: true, isDoublePress: true)))
        XCTAssertTrue(TextEditingKeys.contains(KeyBinding(key: "z", command: true, shift: true, isDoublePress: true)))
        // Command with "A" in upper case is Command-A.
        XCTAssertTrue(TextEditingKeys.contains(KeyBinding(key: "A", command: true)))
        // Double Command-B is an app shortcut's stroke, so it is not a field's.
        XCTAssertFalse(TextEditingKeys.contains(KeyBinding(key: "b", command: true, isDoublePress: true)))
    }

    /// Control with each letter AppKit binds with Control is a field's,
    /// alone or with Shift or Option or both; Control with any other
    /// letter, and Control-Command with any letter, are not.
    func testTheControlLettersAppKitBindsAreAFields() {
        let bound = Set("abdefhklnoptvy".map(String.init))
        for letter in "abcdefghijklmnopqrstuvwxyz".map(String.init) {
            for (shift, option) in [(false, false), (true, false), (false, true), (true, true)] {
                let binding = KeyBinding(key: letter, option: option, shift: shift, control: true)
                XCTAssertEqual(TextEditingKeys.contains(binding), bound.contains(letter), binding.configText)
                XCTAssertEqual(
                    KeyboardShortcutManager.shouldHandle(binding: binding, whenTextInputIsFocused: true),
                    !bound.contains(letter),
                    binding.configText
                )
            }
            let withCommand = KeyBinding(key: letter, command: true, control: true)
            XCTAssertFalse(TextEditingKeys.contains(withCommand), withCommand.configText)
        }
    }

    /// Forward Delete, Home, End, Page Up, and Page Down have no names of
    /// their own: the Shortcuts tab records each as the character AppKit
    /// gives the key, which is the one the rule holds, so a binding
    /// recorded on any of them is left to a field.
    func testTheUnnamedKeysAreHeldAsTheShortcutsTabRecordsThem() throws {
        let keys: [(name: String, keyCode: UInt16, appKit: Int, held: String)] = [
            ("Forward Delete", 117, NSDeleteFunctionKey, TextEditingKeys.forwardDelete),
            ("Home", 115, NSHomeFunctionKey, TextEditingKeys.home),
            ("End", 119, NSEndFunctionKey, TextEditingKeys.end),
            ("Page Up", 116, NSPageUpFunctionKey, TextEditingKeys.pageUp),
            ("Page Down", 121, NSPageDownFunctionKey, TextEditingKeys.pageDown),
        ]
        for key in keys {
            let scalar = try XCTUnwrap(Unicode.Scalar(key.appKit), key.name)
            let characters = String(Character(scalar))
            XCTAssertEqual(key.held, characters, "\(key.name) is not held as AppKit's character")
            let event = try ShortcutKeyPresses.keyDown(keyCode: key.keyCode, characters: characters, modifiers: [.function, .command])
            let recorded = try XCTUnwrap(KeyBinding.from(event: event), key.name)
            XCTAssertEqual(recorded, KeyBinding(key: key.held, command: true), key.name)
            XCTAssertTrue(TextEditingKeys.contains(recorded), key.name)
        }
    }

    // MARK: - The Default Keys

    /// The default keys a text field edits with itself, by action. AppKit's
    /// standard key bindings give Command with each arrow, Shift-Command
    /// with Up and Down, and Command-Delete a command of the text system:
    /// to an end of the line or of the text, selecting to it, and deleting
    /// to the start of the line. The Edit menu's Select All, Undo, Redo,
    /// Cut, Copy, and Paste are Command with A, Z, Shift-Z, X, C, and V.
    /// The audio editor's are listed too, though its window holds no text
    /// field and a sheet over it matches no shortcut.
    private static let defaultsAFieldEditsWith: [ShortcutAction: [String]] = [
        .skipForward: ["command+rightArrow"],
        .skipBackward: ["command+leftArrow"],
        .navigateUpLevel: ["command+upArrow"],
        .moveBookUp: ["shift+command+upArrow"],
        .moveBookDown: ["shift+command+downArrow"],
        .removeFromLibrary: ["command+delete"],
        .selectAll: ["command+a"],
        .editorGoToStart: ["command+upArrow"],
        .editorGoToEnd: ["command+downArrow"],
        .editorSelectAll: ["command+a"],
        .editorUndo: ["command+z"],
        .editorRedo: ["shift+command+z"],
        .editorCut: ["command+x"],
        .editorCopy: ["command+c"],
        .editorPaste: ["command+v"],
    ]

    /// The default keys with Command or Control a field being edited keeps,
    /// by action: the ones it edits with, and the Option-Command arrows of
    /// Next and Previous Heading, the Option-Command left and right arrows of
    /// Next and Previous Page, and of the editor's chapter markers, which move
    /// nothing in a field but are arrows. Every other default key with
    /// Command or Control still acts from a field, and a key with neither,
    /// Shift and Option alone included, is the field's typing, as before.
    func testTheDefaultKeysAFieldKeeps() {
        var kept: [ShortcutAction: [String]] = [:]
        for (action, bindings) in ShortcutAction.defaultBindings {
            for binding in bindings where !KeyboardShortcutManager.shouldHandle(binding: binding, whenTextInputIsFocused: true) {
                if binding.command || binding.control {
                    kept[action, default: []].append(binding.configText)
                }
            }
            for binding in bindings where !binding.command && !binding.control {
                XCTAssertFalse(
                    KeyboardShortcutManager.shouldHandle(binding: binding, whenTextInputIsFocused: true),
                    "\(action.rawValue): \(binding.configText) is taken from typing"
                )
            }
        }
        var expected = Self.defaultsAFieldEditsWith
        expected[.nextHeading] = ["option+command+downArrow"]
        expected[.previousHeading] = ["option+command+upArrow"]
        expected[.nextPage] = ["option+command+rightArrow"]
        expected[.previousPage] = ["option+command+leftArrow"]
        expected[.editorNextChapter] = ["option+command+downArrow"]
        expected[.editorPreviousChapter] = ["option+command+upArrow"]
        XCTAssertEqual(kept, expected)
    }

    // MARK: - What the Field Gets

    /// Command-Delete and Command-A go to a text field being edited: the
    /// manager posts nothing and leaves the press to the field, which
    /// deletes to the start of its line or selects its text, as Command-Left
    /// Arrow moves its insertion point to the start of the line. With the
    /// keyboard in the Library's list, a view that takes no text, the same
    /// keys act as before.
    func testCommandDeleteAndCommandAReachAFieldBeingEdited() throws {
        let manager = makeManager()
        let pressed: [(binding: KeyBinding, action: ShortcutAction)] = [
            (KeyBinding(key: "delete", command: true), .removeFromLibrary),
            (KeyBinding(key: "a", command: true), .selectAll),
            (KeyBinding(key: "leftArrow", command: true), .skipBackward),
        ]
        for (binding, action) in pressed {
            let inField = try press(binding, on: manager, firstResponder: fieldEditor())
            XCTAssertFalse(inField.consumed, "\(binding.configText) was kept from the field")
            XCTAssertEqual(inField.posted, [], binding.configText)
            let inList = try press(binding, on: manager, firstResponder: NSTableView())
            XCTAssertTrue(inList.consumed, "\(binding.configText) reached the list")
            XCTAssertEqual(inList.posted, [action.rawValue], binding.configText)
        }
    }

    /// A key the manager leaves to a field meets the menus before the
    /// field does. The Edit menu's Select All, Copy, Paste, Cut, Undo, and
    /// Redo take Command with A, C, V, X, Z, and Shift-Z and send their
    /// commands along the responder chain, which starts at the field. No
    /// other menu item takes a key a field keeps, so Command-Delete and the
    /// arrows reach the field itself.
    func testOnlyTheEditMenuTakesAFieldsKeyOnItsWay() throws {
        let mainMenu = try XCTUnwrap(NSApp.mainMenu)
        let items = Self.allItems(of: mainMenu)
        let editMenu: [KeyBinding: Selector] = [
            KeyBinding(key: "a", command: true): #selector(NSText.selectAll(_:)),
            KeyBinding(key: "c", command: true): #selector(NSText.copy(_:)),
            KeyBinding(key: "v", command: true): #selector(NSText.paste(_:)),
            KeyBinding(key: "x", command: true): #selector(NSText.cut(_:)),
            KeyBinding(key: "z", command: true): Selector(("undo:")),
            KeyBinding(key: "z", command: true, shift: true): Selector(("redo:")),
        ]
        for item in items {
            guard let binding = Self.binding(answeredBy: item), TextEditingKeys.contains(binding) else { continue }
            XCTAssertEqual(item.action, editMenu[binding], "\(item.title) takes \(binding.configText) before the field")
            XCTAssertNil(item.target, "\(item.title) sends \(binding.configText) past the field")
        }
        for (binding, action) in editMenu {
            XCTAssertTrue(
                items.contains { $0.action == action && Self.binding(answeredBy: $0) == binding },
                "no menu item sends \(action) for \(binding.configText)"
            )
        }
    }

    // MARK: - Nothing Acts for a Key a Field Takes

    /// No default key a field being edited takes posts any action, so no
    /// window acts on it and TextMouth says nothing: what is heard is
    /// VoiceOver reading the field's own edit, as in any app. Every other
    /// default key posts its own action from a field, and every default key
    /// posts its own action from a view that takes no text, each pressed in
    /// a window of its own scope, the app's or an audio editor's; a double
    /// press, W twice or Shift-Command-I twice, is pressed twice, its
    /// first press posting the brief summary it escalates. A key
    /// equivalent's key, a menu command's or a Record window button's
    /// (FR12's branch D), posts nothing and goes on to its menu item or
    /// button, from a field and elsewhere. The keys are each action's in force, each pressed in a
    /// window where the action works (FR12's branch E): none for one working
    /// in every window, and a reader's, a Library window, or the Record
    /// window for one working in a kind of window. Restart Sleep Timer's
    /// key, which is no field's, is left out: its press writes the sleep
    /// timer's diagnostic log.
    func testNoActionFiresForAKeyAFieldTakes() throws {
        let manager = makeManager()
        try withEditorWindow { editorWindow in
            for action in ShortcutAction.allCases where action != .restartSleepTimer {
                let keyWindow: NSWindow?
                switch action.defaultScope {
                case .app: keyWindow = nil
                case .audioEditor: keyWindow = editorWindow
                case .library: keyWindow = makeShortcutWindow(.library)
                case .reader: keyWindow = makeShortcutWindow(.reader)
                case .recording: keyWindow = makeShortcutWindow(.recording)
                }
                let bindings = manager.bindingsFor(action)
                if action.isKeyEquivalent {
                    for binding in bindings {
                        let label = "\(action.rawValue): \(binding.configText)"
                        let firstResponders: [NSResponder] = [fieldEditor(), NSTableView()]
                        for firstResponder in firstResponders {
                            let pressed = try press(binding, on: manager, firstResponder: firstResponder, keyWindow: keyWindow)
                            XCTAssertFalse(pressed.consumed, label)
                            XCTAssertEqual(pressed.posted, [], label)
                        }
                    }
                    continue
                }
                for binding in bindings {
                    let label = "\(action.rawValue): \(binding.configText)"
                    let fieldTakesIt = !KeyboardShortcutManager.shouldHandle(binding: binding, whenTextInputIsFocused: true)
                    // A double press's first press posts the action it
                    // escalates, at once, and its second its own (FR12's
                    // branch C: W twice and Shift-Command-I twice).
                    let posts = (binding.isDoublePress ? [action.escalates].compactMap { $0 } : []) + [action]
                    let inField = try press(binding, on: manager, firstResponder: fieldEditor(), keyWindow: keyWindow)
                    XCTAssertEqual(inField.consumed, !fieldTakesIt, label)
                    XCTAssertEqual(inField.posted, fieldTakesIt ? [] : posts.map(\.rawValue), label)
                    let elsewhere = try press(binding, on: manager, firstResponder: NSTableView(), keyWindow: keyWindow)
                    XCTAssertTrue(elsewhere.consumed, label)
                    XCTAssertEqual(elsewhere.posted, posts.map(\.rawValue), label)
                }
            }
        }
    }

    /// A key of the user's own on a key a field edits with, Control-K for
    /// Where Am I? say, is the field's too: in a field it posts nothing and
    /// goes on to the field, which deletes to the end of the paragraph;
    /// away from text it acts.
    func testAUsersOwnKeyOnAFieldsKeyIsTheFieldsToo() throws {
        let manager = makeManager()
        let controlK = KeyBinding(key: "k", control: true)
        manager.addBinding(controlK, to: .whereAmI)

        let inField = try press(controlK, on: manager, firstResponder: fieldEditor())
        XCTAssertFalse(inField.consumed, "Control-K was kept from the field")
        XCTAssertEqual(inField.posted, [])
        let elsewhere = try press(controlK, on: manager, firstResponder: NSTableView())
        XCTAssertTrue(elsewhere.consumed, "Control-K did not reach Where Am I?")
        XCTAssertEqual(elsewhere.posted, [ShortcutAction.whereAmI.rawValue])
    }

    // MARK: - Helpers

    /// A shortcut manager with the default keys, from a preferences store
    /// of the test's own, watching no key presses and posting on `center`.
    private func makeManager() -> KeyboardShortcutManager {
        KeyboardShortcutManager(
            userDefaults: makeSandboxedPreferences("text-field-editing-keys"),
            installsEventMonitor: false,
            notificationCenter: center
        )
    }

    /// A stand-in for the first responder of a text field being edited:
    /// the field editor, a text view (the first test shows that a real
    /// field, SwiftUI's or a search field, is edited through one).
    private func fieldEditor() -> NSTextView {
        let editor = NSTextView()
        editor.isFieldEditor = true
        return editor
    }

    /// Runs `body` with a window identified as an audio editor's, never
    /// shown and holding no editor, so that a key pressed in it matches the
    /// editor's shortcuts.
    private func withEditorWindow(_ body: (NSWindow) throws -> Void) rethrows {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        // The test owns the window; AppKit must not release it again on close.
        window.isReleasedWhenClosed = false
        // A titled window that is not key stays off screen, as a hosted
        // test view's does (`withHostedView`).
        window.title = "Hosted test view"
        window.identifier = NSUserInterfaceItemIdentifier(AudioEditorWindowController.windowIdentifier)
        defer { window.close() }
        try body(window)
    }

    /// Presses `binding` through `manager`, in `keyWindow` while
    /// `firstResponder` has the keyboard: its key once, or, for a double
    /// press, twice in quick succession (FR12). Returns whether the manager
    /// consumed the presses, failing the test should it consume some and
    /// not others, and every notification it posted: each action's name,
    /// or the notification's own name if it carried no action.
    private func press(
        _ binding: KeyBinding,
        on manager: KeyboardShortcutManager,
        firstResponder: NSResponder?,
        keyWindow: NSWindow? = nil
    ) throws -> (consumed: Bool, posted: [String]) {
        var posted: [String] = []
        // Every action's notification; the audio editor's actions share one.
        let names = Set(ShortcutAction.allCases.map(\.notificationName))
        let subscription = Publishers.MergeMany(names.map { center.publisher(for: $0) })
            .sink { notification in
                posted.append(notification.userInfo?["action"] as? String ?? notification.name.rawValue)
            }
        defer { subscription.cancel() }
        // Each call's presses are timed on the events' time line from the
        // Mac's uptime as the test began: a double's second press 0.1
        // seconds after its first, well within the double-press time, and
        // each call ten seconds after the one before, so the presses of one
        // call never chain with another's into a double press, as they
        // would for a key the field does not keep, such as Shift-Command-I,
        // which counts as a press from a field too.
        var consumed: [Bool] = []
        let start = nextPressTime
        nextPressTime += 10
        for pressNumber in 0..<(binding.isDoublePress ? 2 : 1) {
            let event = try ShortcutKeyPresses.keyPress(of: binding, at: start + Double(pressNumber) * 0.1)
            consumed.append(manager.handleKeyEvent(event, keyWindow: keyWindow, firstResponder: firstResponder))
        }
        XCTAssertEqual(Set(consumed).count, 1, "the manager consumed some presses of \(binding.configText) and not others")
        return (consumed.allSatisfy { $0 }, posted)
    }


    /// `key` with each of the sixteen sets of Command, Option, Shift, and
    /// Control, none held included.
    private func withEveryModifierSet(_ key: String) -> [KeyBinding] {
        (0..<16).map { bits in
            KeyBinding(
                key: key,
                command: bits & 1 != 0,
                option: bits & 2 != 0,
                shift: bits & 4 != 0,
                control: bits & 8 != 0
            )
        }
    }

    /// Every item of `menu` and of its submenus, depth first.
    private static func allItems(of menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(allItems(of:)) ?? []) }
    }

    /// The characters menus give the keys a binding names.
    private static let menuKeyNames: [String: String] = [
        "\u{F700}": "upArrow", "\u{F701}": "downArrow", "\u{F702}": "leftArrow", "\u{F703}": "rightArrow",
        "\u{8}": "delete", "\u{7F}": "delete", " ": "space", "\r": "return", "\t": "tab", "\u{1B}": "escape",
    ]

    /// The binding a menu item's key equivalent stands for, its key spelled
    /// as a binding spells it; nil for an item with no key equivalent, or
    /// with the Globe key held, which no binding holds (the Window menu's
    /// Move & Resize items).
    private static func binding(answeredBy item: NSMenuItem) -> KeyBinding? {
        let equivalent = item.keyEquivalent
        let modifiers = item.keyEquivalentModifierMask
        guard !equivalent.isEmpty, !modifiers.contains(.function) else { return nil }
        return KeyBinding(
            key: menuKeyNames[equivalent] ?? equivalent.lowercased(),
            command: modifiers.contains(.command),
            option: modifiers.contains(.option),
            // A capital letter is a key equivalent with Shift held, as
            // AppKit reads it.
            shift: modifiers.contains(.shift) || equivalent != equivalent.lowercased(),
            control: modifiers.contains(.control)
        )
    }
}
