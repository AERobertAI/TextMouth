import AppKit
import SwiftUI

/// Opens the Record window (FR04), one at a time, and asks before it closes
/// while recording.
///
/// The window is an AppKit window hosting `RecordingWindowView`, rather than
/// a SwiftUI scene, so that closing it can be answered first: while a take
/// is under way, or one could not be saved, its close button and Command-W
/// ask whether to stop and save, discard, or keep the window open
/// (`windowShouldClose(_:)`). Its identifier, "new-recording", tells the
/// menu bar it is neither a Library nor a reader window, so neither's menus
/// show while it is in front (`MenuVisibilityManager`).
///
/// File > New Recording… hands it the library model; the Library windows
/// attach it as they appear, so Library > New Recording… finds it too.
@MainActor
final class RecordingWindowController: NSObject, NSWindowDelegate {
    /// The app's controller.
    static let shared = RecordingWindowController()

    /// The identifier the Record window carries.
    nonisolated static let windowIdentifier = "new-recording"

    /// The library recordings are saved into.
    private weak var library: LibraryViewModel?
    /// The window, while it is open.
    private(set) var window: NSWindow?
    /// The window's model, while it is open.
    private(set) var model: RecordingWindowModel?

    /// Makes `library` the one recordings are saved into.
    func attach(_ library: LibraryViewModel) {
        self.library = library
    }

    /// Brings the Record window forward, opening it when it is not open.
    /// Does nothing before a library is attached, which happens as the
    /// first Library window appears.
    func show(library: LibraryViewModel? = nil) {
        if let library {
            attach(library)
        }
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        guard let library = self.library else {
            DiagnosticLog.event(.app, "RECORDING_WINDOW_REFUSED: no library to save recordings into yet")
            return
        }
        let model = makeModel(library: library)
        let window = NSWindow(contentViewController: NSHostingController(rootView: RecordingWindowView(model: model)))
        window.title = RecordingWording.windowTitle
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        // TextMouth reopens no window at launch (AppDelegate), this one too.
        window.isRestorable = false
        window.delegate = self
        window.center()
        self.window = window
        self.model = model
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // The menu bar shows this window's menus: none of Library's or a
        // reader's.
        NotificationCenter.default.post(name: .refreshContextMenus, object: nil)
    }

    /// The model of a new Record window saving into `library`, with this
    /// Mac's microphones, the app's preferences, and VoiceOver.
    private func makeModel(library: LibraryViewModel) -> RecordingWindowModel {
        RecordingWindowModel(
            service: RecordingService.system(),
            catalog: SystemRecordingInputCatalog(),
            store: TextMouthRuntime.current.preferences,
            saver: RecordingWindowModel.librarySaver(library),
            folderPaths: { [weak library] in
                library.map(RecordingWindowModel.libraryFolderPaths) ?? []
            },
            announce: { [weak self] sentence in
                VoiceOverAnnouncer.announce(sentence, from: self?.window)
            },
            openBook: { bookID in
                NotificationCenter.default.post(name: .openBookWindow, object: bookID)
            }
        )
    }

    // MARK: - Closing

    /// Lets the window close unless a take is under way or waits to be
    /// saved; then asks first, and closes once the answer is carried out.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model, let question = CloseQuestion(need: model.closeNeed) else { return true }
        // The question is already on screen: Command-W again changes nothing.
        guard sender.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = question.title
        alert.informativeText = question.explanation
        alert.addButton(withTitle: question.saveButton)
        alert.addButton(withTitle: RecordingWording.discardButton)
        // AppKit gives the button titled Cancel the Escape key.
        alert.addButton(withTitle: RecordingWording.cancelButton)
        alert.beginSheetModal(for: sender) { [weak self] response in
            Task { @MainActor in await self?.answer(response, for: sender) }
        }
        return false
    }

    /// Carries out the answer to the close question: save, then close once
    /// saved (a save that fails leaves the window open to say why);
    /// discard, then close; or keep the window open.
    private func answer(_ response: NSApplication.ModalResponse, for window: NSWindow) async {
        guard let model else { return }
        switch response {
        case .alertFirstButtonReturn:
            if model.service.isRecording {
                await model.stop()
            } else {
                await model.saveAgain()
            }
            if model.closeNeed == .nothing {
                window.close()
            }
        case .alertSecondButtonReturn:
            await model.discard()
            window.close()
        default:
            break
        }
    }

    /// Lets go of the window and its model as it closes. A save under way
    /// finishes, and still announces its outcome.
    func windowWillClose(_ notification: Notification) {
        model?.windowClosed()
        model = nil
        window = nil
        NotificationCenter.default.post(name: .refreshContextMenus, object: nil)
    }
}

/// The question asked before the Record window closes.
struct CloseQuestion: Equatable {
    /// The question.
    let title: String
    /// What each answer does.
    let explanation: String
    /// The first, default answer: save.
    let saveButton: String

    /// The question for `need`, or nil when closing needs none.
    init?(need: RecordingWindowModel.CloseNeed) {
        switch need {
        case .nothing:
            return nil
        case .stopOrDiscard:
            title = RecordingWording.closeWhileRecordingQuestion
            explanation = RecordingWording.closeWhileRecordingExplanation
            saveButton = RecordingWording.stopAndSaveButton
        case .saveOrDiscard:
            title = RecordingWording.closeWithUnsavedQuestion
            explanation = RecordingWording.closeWithUnsavedExplanation
            saveButton = RecordingWording.saveButton
        }
    }
}
