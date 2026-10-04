import AppKit
import SwiftUI

/// Opens and closes the audio editor's windows (FR04): one for each book
/// being edited, each an AppKit window hosting `AudioEditorView`, as the
/// Record window is, so that closing it can be answered first.
///
/// Every editor window carries the identifier "audio-editor", which tells
/// the menu bar it is neither a Library nor a reader window, so neither's
/// menus show while it is in front (`MenuVisibilityManager`), and tells the
/// shortcut manager to match the editor's own keys there. Edit Audio… for a
/// book whose editor is open brings that window forward instead of opening
/// another.
@MainActor
final class AudioEditorWindowController: NSObject, NSWindowDelegate {
    /// The app's controller.
    static let shared = AudioEditorWindowController()

    /// The identifier every editor window carries.
    nonisolated static let windowIdentifier = "audio-editor"

    /// One open editor: its window and its model.
    private struct Editor {
        let window: NSWindow
        let model: AudioEditorModel
    }

    /// The open editors, by book.
    private var editors: [UUID: Editor] = [:]
    /// The books whose editors are being opened now, so a second Edit
    /// Audio… meanwhile opens nothing more.
    private var opening: Set<UUID> = []

    // MARK: Which Editors Are Open

    /// Whether `bookID`'s editor is open.
    func isOpen(_ bookID: UUID) -> Bool {
        editors[bookID] != nil
    }

    /// The model of `bookID`'s editor, while it is open.
    func model(for bookID: UUID) -> AudioEditorModel? {
        editors[bookID]?.model
    }

    /// The window of `bookID`'s editor, while it is open.
    func window(for bookID: UUID) -> NSWindow? {
        editors[bookID]?.window
    }

    /// Brings `bookID`'s editor forward, if it is open.
    func bringForward(_ bookID: UUID) {
        guard let window = editors[bookID]?.window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Notes that `bookID`'s editor is being opened, unless it is already
    /// open or opening; the result says whether it may open.
    func beginOpening(_ bookID: UUID) -> Bool {
        guard editors[bookID] == nil, !opening.contains(bookID) else { return false }
        opening.insert(bookID)
        return true
    }

    /// Notes that opening `bookID`'s editor has ended, opened or not.
    func endOpening(_ bookID: UUID) {
        opening.remove(bookID)
    }

    // MARK: Opening

    /// Opens a window around `model` and brings it forward. VoiceOver starts
    /// on its time display (`AudioEditorView`).
    func show(_ model: AudioEditorModel) {
        if let open = editors[model.bookID] {
            // Never two windows on one book: the new model lets go of what
            // it holds, and the open window comes forward.
            model.windowClosed()
            open.window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: AudioEditorView(model: model)))
        window.title = model.windowTitle
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        // TextMouth reopens no window at launch (AppDelegate), this one too.
        window.isRestorable = false
        window.delegate = self
        window.center()
        // The window the editor's shortcuts are pressed in, and its
        // announcements are posted from.
        model.hostWindow = window
        editors[model.bookID] = Editor(window: window, model: model)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // The menu bar shows this window's menus: none of Library's or a
        // reader's.
        NotificationCenter.default.post(name: .refreshContextMenus, object: nil)
    }

    // MARK: Closing

    /// Lets the window close unless closing needs something first: work
    /// under way, or a recording, is said, and the window stays; edits
    /// waiting to be saved are asked about, Save, Discard, or Cancel, and
    /// the window closes once the answer is carried out.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model = editors.values.first(where: { $0.window === sender })?.model else { return true }
        switch model.closeNeed {
        case .nothing:
            return true
        case .working:
            model.announce(AudioEditorWording.closeWhileWorking)
            return false
        case .recording:
            model.announce(AudioEditorWording.closeWhileRecording)
            return false
        case .unsavedEdits:
            // The question is already on screen: Command-W again changes
            // nothing.
            guard sender.attachedSheet == nil else { return false }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = AudioEditorWording.closeQuestion(book: model.bookTitle)
            alert.informativeText = AudioEditorWording.closeExplanation
            alert.addButton(withTitle: AudioEditorWording.saveButton)
            alert.addButton(withTitle: AudioEditorWording.discardButton)
            // AppKit gives the button titled Cancel the Escape key.
            alert.addButton(withTitle: AudioEditorWording.cancelButton)
            alert.beginSheetModal(for: sender) { [weak self] response in
                Task { @MainActor in await self?.answer(response, closing: sender, model: model) }
            }
            return false
        }
    }

    /// Carries out the answer to the close question: save, then close once
    /// saved (a save that fails leaves the window open to say why); discard,
    /// then close; or keep the window open.
    private func answer(_ response: NSApplication.ModalResponse, closing window: NSWindow, model: AudioEditorModel) async {
        switch response {
        case .alertFirstButtonReturn:
            if await model.save() {
                window.close()
            }
        case .alertSecondButtonReturn:
            let discarded = await model.discardUnsavedEdits()
            if !discarded {
                model.announce(AudioEditorWording.discardKept)
            }
            window.close()
        default:
            break
        }
    }

    /// Lets go of the window and its model as it closes: playing stops, and
    /// the edit session's use of the book ends. A reader the editor closed
    /// to open opens the book again.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let entry = editors.first(where: { $0.value.window === window }) else { return }
        let reopensReader = entry.value.model.reopensReaderOnClose
        entry.value.model.windowClosed()
        editors[entry.key] = nil
        NotificationCenter.default.post(name: .refreshContextMenus, object: nil)
        if reopensReader {
            NotificationCenter.default.post(name: .openBookWindow, object: entry.key)
        }
    }
}
