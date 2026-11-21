import AppKit
import SwiftUI

/// Opens and closes the audio editor's windows (FR04): one for each book
/// being edited, each an AppKit window hosting `AudioEditorView`, as the
/// Record window is, so that closing it can be answered first; and, as
/// TextMouth quits, asks about every window's unsaved edits (`holdQuit`).
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
        /// What the main Edit menu's Undo and Redo reach in its window.
        let undoManager: AudioEditorUndoManager
    }

    /// The window receiving keys, which the main Edit menu's commands act
    /// in (`AudioEditorEditMenu`): AppKit's, unless a test sets its own.
    var keyWindow: @MainActor () -> NSWindow? = { NSApp.keyWindow }

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
        window.center()
        attach(model, to: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // The menu bar shows this window's menus: none of Library's or a
        // reader's.
        NotificationCenter.default.post(name: .refreshContextMenus, object: nil)
    }

    /// Makes `window` the window of `model`'s editor, kept with it until it
    /// closes: this controller answers for the window, and the model takes
    /// it as the window its shortcuts are pressed in and its announcements
    /// are posted from. `show` attaches the windows it opens; tests attach
    /// windows they never show.
    func attach(_ model: AudioEditorModel, to window: NSWindow) {
        window.delegate = self
        model.hostWindow = window
        editors[model.bookID] = Editor(
            window: window,
            model: model,
            undoManager: AudioEditorUndoManager(model: model, window: window)
        )
    }

    /// The model and the undo manager of the editor whose window is
    /// `window`, if it is an editor's.
    func editor(in window: NSWindow) -> (model: AudioEditorModel, undoManager: AudioEditorUndoManager)? {
        editors.values.first { $0.window === window }.map { ($0.model, $0.undoManager) }
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
            let alert = Self.unsavedEditsQuestion(about: model, explanation: AudioEditorWording.closeExplanation)
            alert.beginSheetModal(for: sender) { [weak self] response in
                Task { @MainActor in await self?.answer(response, closing: sender, model: model) }
            }
            return false
        }
    }

    /// Carries out the answer to the close question, then closes the window
    /// unless the answer was Cancel or the save failed, which the window
    /// says (`carryOut`).
    private func answer(_ response: NSApplication.ModalResponse, closing window: NSWindow, model: AudioEditorModel) async {
        if await carryOut(AudioEditorUnsavedEditsAnswer(response), for: model) {
            window.close()
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

    // MARK: The Question About Unsaved Edits

    /// The question asked about `model`'s unsaved edits, as its window closes
    /// or TextMouth quits, explained by `explanation`: Save, the default
    /// button, then Discard, then Cancel, which AppKit gives the Escape key
    /// by its title.
    private static func unsavedEditsQuestion(about model: AudioEditorModel, explanation: String) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AudioEditorWording.closeQuestion(book: model.bookTitle)
        alert.informativeText = explanation
        alert.addButton(withTitle: AudioEditorWording.saveButton)
        alert.addButton(withTitle: AudioEditorWording.discardButton)
        alert.addButton(withTitle: AudioEditorWording.cancelButton)
        return alert
    }

    /// Carries out `answer` about `model`'s unsaved edits: Save saves them,
    /// and Discard goes back to the audio as saved, saying so when the edits
    /// stay. Returns whether what asked may go on: false for Cancel, and for
    /// a save that failed, which the window says.
    private func carryOut(_ answer: AudioEditorUnsavedEditsAnswer, for model: AudioEditorModel) async -> Bool {
        switch answer {
        case .save:
            return await model.save()
        case .discard:
            if await !model.discardUnsavedEdits() {
                model.announce(AudioEditorWording.discardKept)
            }
            return true
        case .cancel:
            return false
        }
    }

    // MARK: Quitting

    /// Asks about an editor's unsaved edits as TextMouth quits: an alert over
    /// every window, its editor's window brought forward first (`askAsQuitting`),
    /// unless a test answers for it.
    var askBeforeQuitting: @MainActor (AudioEditorModel, NSWindow) async -> AudioEditorUnsavedEditsAnswer = { model, window in
        AudioEditorWindowController.askAsQuitting(about: model, in: window)
    }

    /// The questions asked as TextMouth quits, while they are asked and
    /// carried out; tests wait for it.
    private(set) var quitReview: Task<Void, Never>?

    /// Set by a review that let every editor go, for the one request to
    /// quit it makes, so that request quits. The request arrives later than
    /// the review's end, so the next `holdQuit` clears it, not the review;
    /// if another hold cancels that request first (a take, a library move),
    /// the mark waits for the next quit, whose editors were all answered for
    /// just before.
    private var quitReviewed = false

    /// Holds a request to quit while an editor needs something first, as the
    /// app delegate asks before TextMouth quits (FR04); returns whether the
    /// request is to be cancelled for now.
    ///
    /// An editor still working or recording holds the quit: its window comes
    /// forward and says so, and nothing more happens. Otherwise each editor
    /// with unsaved edits is asked about in turn, by its book's title, Save,
    /// Discard, or Cancel, as closing its window asks, and each answer is
    /// carried out before the next question; the markers every editor asked
    /// to keep are written too. Once all are answered, `quit` asks to quit
    /// again, and that request quits; Cancel, or a save that fails, keeps
    /// TextMouth open. A request that comes while the questions are asked is
    /// cancelled without asking again. Nothing of edits.json is lost: every
    /// change to it is written before its command ends.
    func holdQuit(then quit: @escaping @MainActor @Sendable () -> Void) -> Bool {
        if quitReviewed {
            quitReviewed = false
            return false
        }
        guard quitReview == nil else { return true }
        let open = editors.values.sortedStably {
            $0.model.bookTitle.localizedStandardCompare($1.model.bookTitle) == .orderedAscending
        }
        if let busy = open.first(where: { $0.model.closeNeed == .working || $0.model.closeNeed == .recording }) {
            Self.raise(busy.window)
            let book = busy.model.bookTitle
            busy.model.announce(busy.model.closeNeed == .recording
                ? AudioEditorWording.quitWhileRecording(book: book)
                : AudioEditorWording.quitWhileWorking(book: book))
            return true
        }
        guard open.contains(where: { $0.model.closeNeed == .unsavedEdits || $0.model.session.isKeepingMarkers }) else {
            return false
        }
        quitReview = Task { [weak self] in
            guard let self else { return }
            let goesOn = await review(open)
            quitReview = nil
            guard goesOn else { return }
            // `quit()` only schedules the request (`QuitRequest.ask()`), which
            // arrives on a later turn of the run loop, so the mark is not
            // cleared here: the next `holdQuit` uses it up.
            quitReviewed = true
            quit()
        }
        return true
    }

    /// Asks about each of the `open` editors that has unsaved edits when its
    /// turn comes, its window brought forward, carrying out each answer
    /// before the next question; then waits for every editor's markers to
    /// be kept. Returns whether quitting goes on.
    private func review(_ open: [Editor]) async -> Bool {
        for editor in open where editor.model.closeNeed == .unsavedEdits {
            Self.raise(editor.window)
            let answer = await askBeforeQuitting(editor.model, editor.window)
            guard await carryOut(answer, for: editor.model) else { return false }
        }
        for editor in open {
            await editor.model.session.markersKept()
        }
        return true
    }

    /// The app's question about `model`'s unsaved edits as TextMouth quits:
    /// an alert over every window, so it can be asked whatever sheet the
    /// editor shows, once TextMouth is in front.
    private static func askAsQuitting(about model: AudioEditorModel, in window: NSWindow) -> AudioEditorUnsavedEditsAnswer {
        NSApp.activate()
        let alert = unsavedEditsQuestion(about: model, explanation: AudioEditorWording.quitExplanation)
        return AudioEditorUnsavedEditsAnswer(alert.runModal())
    }

    /// Brings `window` forward, when it is on screen or in the Dock, so the
    /// editor a quit speaks of is the one in front; a window never shown,
    /// as a test's, stays hidden.
    private static func raise(_ window: NSWindow) {
        guard window.isVisible || window.isMiniaturized else { return }
        window.makeKeyAndOrderFront(nil)
    }
}

/// An answer to the question about an editor's unsaved edits, asked as its
/// window closes or as TextMouth quits (FR04).
enum AudioEditorUnsavedEditsAnswer: Equatable, Sendable {
    /// Save the edits into the book's file.
    case save
    /// Go back to the audio as saved; the edits stay for Redo.
    case discard
    /// Keep the window open, and TextMouth with it.
    case cancel

    /// The answer the question's alert gave as `response`: its buttons are
    /// Save, Discard, and Cancel, in that order, and anything else, as the
    /// alert ending without a button, is Cancel.
    init(_ response: NSApplication.ModalResponse) {
        switch response {
        case .alertFirstButtonReturn: self = .save
        case .alertSecondButtonReturn: self = .discard
        default: self = .cancel
        }
    }
}
