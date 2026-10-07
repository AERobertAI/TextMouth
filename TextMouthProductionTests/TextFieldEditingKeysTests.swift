import AppKit
import Combine
import SwiftUI
import XCTest
@testable import TextMouth

/// B03 (October 7, 2026): what the shortcut manager does with a key pressed
/// while a text field or text view has the keyboard.
///
/// Every key here goes through the manager's own decision,
/// `KeyboardShortcutManager.handleKeyEvent(_:keyWindow:firstResponder:)`,
/// as a key press made up for the test, with a stand-in for the first
/// responder, on a manager of the test's own whose notifications go to a
/// center of the test's own: no key is really pressed, and no window of the
/// app hears an action.
@MainActor
final class TextFieldEditingKeysTests: XCTestCase {
    /// The center the test's manager posts its actions on, heard by no
    /// window of the app.
    private let center = NotificationCenter()

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

    // MARK: - Measured Before B03's Rule

    /// Before B03, Command-Delete and Command-A act while a text field is
    /// edited: the manager posts Remove from Library and Select All and
    /// keeps the press from the field, so the field never deletes to the
    /// start of its line or selects its text. Command-Left Arrow, Skip
    /// Backward's key, likewise never moves the field's insertion point to
    /// the start of the line.
    func testCommandDeleteAndCommandAActWhileAFieldIsEdited() throws {
        let manager = makeManager()
        let pressed: [(binding: KeyBinding, action: ShortcutAction)] = [
            (KeyBinding(key: "delete", command: true), .removeFromLibrary),
            (KeyBinding(key: "a", command: true), .selectAll),
            (KeyBinding(key: "leftArrow", command: true), .skipBackward),
        ]
        for (binding, action) in pressed {
            let result = try press(binding, on: manager, firstResponder: fieldEditor())
            XCTAssertTrue(result.consumed, "\(binding.configText) reached the field")
            XCTAssertEqual(result.posted, [action.rawValue], binding.configText)
        }
    }

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

    /// Before B03, every default key with Command or Control acts even
    /// from a field being edited, the keys the field edits with among them;
    /// a key with neither, Shift and Option alone included, is left to the
    /// field's typing.
    func testEveryDefaultCommandOrControlKeyActsFromAField() {
        for (action, bindings) in ShortcutAction.defaultBindings {
            for binding in bindings {
                XCTAssertEqual(
                    KeyboardShortcutManager.shouldHandle(binding: binding, whenTextInputIsFocused: true),
                    binding.command || binding.control,
                    "\(action.rawValue): \(binding.configText)"
                )
            }
        }
        for (action, texts) in Self.defaultsAFieldEditsWith {
            for text in texts {
                guard let binding = KeyBinding(configText: text) else {
                    XCTFail("\(text) is no shortcut")
                    continue
                }
                XCTAssertTrue(
                    ShortcutAction.defaultBindings[action]?.contains(binding) == true,
                    "\(action.rawValue) has no default \(text)"
                )
                XCTAssertTrue(
                    KeyboardShortcutManager.shouldHandle(binding: binding, whenTextInputIsFocused: true),
                    "\(action.rawValue): \(text) is left to the field"
                )
            }
        }
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

    /// Presses `binding` once through `manager`, in `keyWindow` while
    /// `firstResponder` has the keyboard. Returns whether the manager
    /// consumed the press, and every notification it posted: each action's
    /// name, or the notification's own name if it carried no action.
    private func press(
        _ binding: KeyBinding,
        on manager: KeyboardShortcutManager,
        firstResponder: NSResponder?,
        keyWindow: NSWindow? = nil
    ) throws -> (consumed: Bool, posted: [String]) {
        let event = try keyPress(of: binding)
        var posted: [String] = []
        // Every action's notification; the audio editor's actions share one.
        let names = Set(ShortcutAction.allCases.map(\.notificationName))
        let subscription = Publishers.MergeMany(names.map { center.publisher(for: $0) })
            .sink { notification in
                posted.append(notification.userInfo?["action"] as? String ?? notification.name.rawValue)
            }
        defer { subscription.cancel() }
        let consumed = manager.handleKeyEvent(event, keyWindow: keyWindow, firstResponder: firstResponder)
        return (consumed, posted)
    }

    /// The key code and characters the keyboard gives each key a binding
    /// names rather than spells; a binding matches these keys by code.
    private static let namedKeyPresses: [String: (keyCode: UInt16, characters: String)] = [
        "space": (49, " "),
        "tab": (48, "\t"),
        "return": (36, "\r"),
        "delete": (51, "\u{7F}"),
        "escape": (53, "\u{1B}"),
        "leftArrow": (123, "\u{F702}"),
        "rightArrow": (124, "\u{F703}"),
        "downArrow": (125, "\u{F701}"),
        "upArrow": (126, "\u{F700}"),
    ]

    /// A key-down event for `binding`'s key with exactly its modifiers, as
    /// the manager's event monitor is handed one, made up for the test and
    /// never sent to any window.
    private func keyPress(of binding: KeyBinding) throws -> NSEvent {
        var flags: NSEvent.ModifierFlags = []
        if binding.command { flags.insert(.command) }
        if binding.option { flags.insert(.option) }
        if binding.shift { flags.insert(.shift) }
        if binding.control { flags.insert(.control) }
        let named = Self.namedKeyPresses[binding.key]
        // A key a binding spells is matched by its character, which Shift
        // capitalizes as the keyboard does; its code goes unread.
        let characters = named?.characters ?? (binding.shift ? binding.key.uppercased() : binding.key)
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: named?.keyCode ?? 0
        )
        return try XCTUnwrap(event, "no key press for \(binding.configText)")
    }
}
