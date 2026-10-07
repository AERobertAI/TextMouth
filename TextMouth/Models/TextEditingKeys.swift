import Foundation

/// The keys a text field or text view edits with, which it keeps from the
/// shortcut manager while it has the keyboard (B03, October 7, 2026): a key
/// pressed to edit text never acts on the library or a reader.
///
/// How the line is drawn. A key is a field's when the text system deletes,
/// moves, or selects with it, by AppKit's standard key bindings (the
/// StandardKeyBinding.dict in AppKit's resources), or when the Edit menu
/// takes it and sends its command to the field:
/// - Delete and Forward Delete, with any modifiers: a character, a word,
///   or to the start of the line.
/// - The four arrows, Home, End, Page Up, and Page Down, with any
///   modifiers: by a character, a word, a line, a page, or to an end of the
///   text, and with Shift selecting as they go. Option-Command with Up or
///   Down Arrow moves nothing in a field, but every arrow is the field's
///   alike, so an arrow pressed in a field never moves a book or a reader.
/// - Command with A, C, V, X, or Z, and Shift-Command-Z: the Edit menu's
///   Select All, Copy, Paste, Cut, Undo, and Redo.
/// - Control with A, B, D, E, F, H, K, L, N, O, P, T, V, or Y, the letters
///   AppKit binds with Control (Emacs's keys), with or without Shift or
///   Option, which AppKit binds to select as the key moves and to move by a
///   word.
///
/// A key with neither Command nor Control types, and is left to a field as
/// it always was (`KeyboardShortcutManager.shouldHandle`). Every other key
/// with Command or Control is an app shortcut and still acts from a field: a
/// field has no use for Command-I's Book Info, and the sleep timer's
/// minutes field needs Shift-Command-T to close the panel it opened.
/// Return, Tab, Escape, and Space are none of these: they end editing, move
/// the keyboard to another control, or type, and a panel's own buttons
/// answer Return and Escape. The menu bar's own key equivalents are not the
/// manager's and are unchanged.
///
/// The default shortcuts this leaves to a field. In the app's windows: Skip
/// Forward and Skip Backward (Command-Right and Command-Left Arrow), Up One
/// Level (Command-Up Arrow), Next Heading and Previous Heading
/// (Option-Command-Down and Option-Command-Up Arrow), Move Book Down and
/// Move Book Up (Shift-Command-Down and Shift-Command-Up Arrow), Remove from
/// Library (Command-Delete), and Select All (Command-A). In an audio
/// editor's, whose window holds no text field: Go to Start and Go to End
/// (Command-Up and Command-Down Arrow), Previous and Next Chapter Marker
/// (Option-Command-Up and Option-Command-Down Arrow), and Select All, Undo,
/// Redo, Cut, Copy, and Paste.
enum TextEditingKeys {
    /// Forward Delete as a binding holds it: by the character AppKit gives
    /// the key (`NSDeleteFunctionKey`), which the Shortcuts tab records for
    /// a key with no name of its own (`KeyBinding.from(event:)`).
    static let forwardDelete = "\u{F728}"
    /// Home, by AppKit's `NSHomeFunctionKey`.
    static let home = "\u{F729}"
    /// End, by AppKit's `NSEndFunctionKey`.
    static let end = "\u{F72B}"
    /// Page Up, by AppKit's `NSPageUpFunctionKey`.
    static let pageUp = "\u{F72C}"
    /// Page Down, by AppKit's `NSPageDownFunctionKey`.
    static let pageDown = "\u{F72D}"

    /// The keys a field deletes or moves with whatever modifiers are held,
    /// as bindings hold them.
    static let keysWithAnyModifiers: Set<String> = [
        "delete", forwardDelete,
        "leftArrow", "rightArrow", "upArrow", "downArrow",
        home, end, pageUp, pageDown,
    ]

    /// The Edit menu's Select All, Copy, Paste, Cut, Undo, and Redo.
    static let editMenuKeys: Set<KeyBinding> = [
        KeyBinding(key: "a", command: true),
        KeyBinding(key: "c", command: true),
        KeyBinding(key: "v", command: true),
        KeyBinding(key: "x", command: true),
        KeyBinding(key: "z", command: true),
        KeyBinding(key: "z", command: true, shift: true),
    ]

    /// The letters AppKit's standard key bindings give a command with
    /// Control held.
    static let controlLetters: Set<String> = [
        "a", "b", "d", "e", "f", "h", "k", "l", "n", "o", "p", "t", "v", "y",
    ]

    /// Whether a text field or text view keeps a key press matching
    /// `binding` from the shortcut manager while it has the keyboard.
    static func contains(_ binding: KeyBinding) -> Bool {
        keysWithAnyModifiers.contains(binding.key)
            || editMenuKeys.contains(binding)
            || (binding.control && !binding.command && controlLetters.contains(binding.key))
    }
}
