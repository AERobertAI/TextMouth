import AppKit

// MARK: - The Main Edit Menu in an Editor Window

/// The main Edit menu in an audio editor window (FR04): its Undo, Redo,
/// Cut, Copy, Paste, and Select All are the editor's own commands while an
/// editor window is the key window, named as the editor's buttons name them
/// ("Undo Cut 2 Seconds") and available when they are; in every other
/// window, and in a sheet over an editor, where the editor's shortcuts
/// don't work either, they keep their meaning.
///
/// The menu stays AppKit's own, so a text field anywhere keeps its Undo
/// Typing, its Cut, and the rest. Its items send their actions along the
/// responder chain, and an editor window answers the ones nothing in it
/// takes first: its window's undo manager is the editor's stand-in
/// (`AudioEditorUndoManager`), which `NSWindow`'s own Undo and Redo
/// validate and call, and the window's delegate, the editors' controller,
/// answers Cut, Copy, Paste, and Select All. Either way the command goes to
/// the editor as its shortcut does (`send(_:from:)`), and its model takes
/// it through `WindowCommandRouting`, as other windows' commands are taken.
enum AudioEditorEditMenu {
    /// The editor command the Edit menu's item sending `action` stands for;
    /// nil for any other. Undo and Redo reach the editor through its
    /// window's undo manager instead.
    static func command(for action: Selector) -> ShortcutAction? {
        switch action {
        case #selector(NSText.cut(_:)): return .editorCut
        case #selector(NSText.copy(_:)): return .editorCopy
        case #selector(NSText.paste(_:)): return .editorPaste
        case #selector(NSText.selectAll(_:)): return .editorSelectAll
        default: return nil
        }
    }

    /// Sends the editor command `action` from `window`, as the shortcut
    /// manager sends an editor key pressed there: every editor's model
    /// hears it, and the one whose window it is acts.
    @MainActor
    static func send(_ action: ShortcutAction, from window: NSWindow) {
        NotificationCenter.default.post(
            name: action.notificationName,
            object: nil,
            userInfo: ["action": action.rawValue, "sourceWindow": window]
        )
    }
}

// MARK: - Undo and Redo

/// The undo manager of an audio editor window (FR04), which the main Edit
/// menu's Undo and Redo reach through the window: it keeps no undo actions
/// of its own, but stands for the editor's, so the menu's items are titled
/// as the editor's buttons are, "Undo Cut 2 Seconds", are available when
/// they are, and undo and redo through the editor's commands. The editor
/// window holds no text field of its own, so nothing else registers here.
final class AudioEditorUndoManager: UndoManager {
    /// The editor whose Undo and Redo it stands for.
    private weak var model: AudioEditorModel?
    /// The editor's window, which its commands are sent from.
    private weak var window: NSWindow?

    /// The undo manager of `model`'s editor, in `window`.
    init(model: AudioEditorModel, window: NSWindow) {
        self.model = model
        self.window = window
        super.init()
    }

    /// Whether the editor's Undo is available, as its button is.
    override var canUndo: Bool {
        model?.canPerform(.editorUndo) ?? false
    }

    /// Whether the editor's Redo is available, as its button is.
    override var canRedo: Bool {
        model?.canPerform(.editorRedo) ?? false
    }

    /// The Undo item's title: the editor's Undo button's.
    override var undoMenuItemTitle: String {
        model?.title(for: .editorUndo) ?? super.undoMenuItemTitle
    }

    /// The Redo item's title: the editor's Redo button's.
    override var redoMenuItemTitle: String {
        model?.title(for: .editorRedo) ?? super.redoMenuItemTitle
    }

    /// Undoes through the editor's Undo.
    override func undo() {
        send(.editorUndo)
    }

    /// Redoes through the editor's Redo.
    override func redo() {
        send(.editorRedo)
    }

    /// Sends `action` from the editor's window, while it is open.
    private func send(_ action: ShortcutAction) {
        guard let window else { return }
        AudioEditorEditMenu.send(action, from: window)
    }
}

// MARK: - Cut, Copy, Paste, and Select All

/// An editor window's delegate answers the Edit menu's Cut, Copy, Paste,
/// and Select All when nothing in the window takes them first, and gives
/// each window its editor's undo manager.
extension AudioEditorWindowController: NSMenuItemValidation {
    /// The editor's stand-in undo manager, for its window's Undo and Redo.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        editor(in: window)?.undoManager
    }

    /// Edit > Cut: the editor's Cut.
    @objc func cut(_ sender: Any?) {
        sendEditMenuCommand(#selector(NSText.cut(_:)))
    }

    /// Edit > Copy: the editor's Copy.
    @objc func copy(_ sender: Any?) {
        sendEditMenuCommand(#selector(NSText.copy(_:)))
    }

    /// Edit > Paste: the editor's Paste.
    @objc func paste(_ sender: Any?) {
        sendEditMenuCommand(#selector(NSText.paste(_:)))
    }

    /// Edit > Select All: the editor's Select All.
    @objc func selectAll(_ sender: Any?) {
        sendEditMenuCommand(#selector(NSText.selectAll(_:)))
    }

    /// Whether the Edit menu's item is available: one of the editor's
    /// commands, while the key window is an editor's and the command can
    /// act there, as its button can.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action.flatMap(AudioEditorEditMenu.command(for:)),
              let editor = editorInFront() else { return false }
        return editor.model.canPerform(action)
    }

    /// Sends the editor command the Edit menu's `action` stands for to the
    /// editor in front, when there is one.
    private func sendEditMenuCommand(_ action: Selector) {
        guard let command = AudioEditorEditMenu.command(for: action), let editor = editorInFront() else { return }
        AudioEditorEditMenu.send(command, from: editor.window)
    }

    /// The editor whose window is the key window itself: the Edit menu's
    /// commands are its own there, and in no sheet over it, where AppKit
    /// may still send them along to its window.
    private func editorInFront() -> (model: AudioEditorModel, window: NSWindow)? {
        guard let window = keyWindow(), let editor = editor(in: window) else { return nil }
        return (editor.model, window)
    }
}
