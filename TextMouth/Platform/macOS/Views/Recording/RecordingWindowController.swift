import AppKit
import SwiftUI

/// Opens the Record window (FR04), one at a time, and asks before it closes,
/// or TextMouth quits, while recording.
///
/// The window is an AppKit window hosting `RecordingWindowView`, rather than
/// a SwiftUI scene, so that closing it can be answered first: while a take
/// is under way, or one could not be saved, its close button and Command-W
/// ask whether to stop and save, discard, or keep the window open
/// (`windowShouldClose(_:)`), and so does quitting, through the app's quit
/// hold (`holdQuit(then:)`). Its identifier, "new-recording", tells the
/// menu bar it is neither a Library nor a reader window, so neither's menus
/// show while it is in front (`MenuVisibilityManager`).
///
/// File > New Recording… hands it the library model; the Library windows
/// attach it as they appear, so Library > New Recording… finds it too. The
/// first to appear has it look, once, for recordings a crash left behind,
/// and open the window on them (`lookForRecoveredTakes`).
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
    /// Whether launch has looked for recordings left behind, which it does
    /// once.
    private var hasLookedForRecoveredTakes = false

    /// Shows the close question for the window and hands back the answer:
    /// AppKit's sheet in the app (`askWithSheet`); tests answer it
    /// themselves, so nothing is shown.
    var askQuestion: @MainActor (_ question: CloseQuestion, _ window: NSWindow, _ answered: @escaping @MainActor (CloseAnswer) -> Void) -> Void
        = RecordingWindowController.askWithSheet
    /// Brings the window forward before a quit asks about it: AppKit's in
    /// the app; tests leave their windows where they are.
    var bringForward: @MainActor (NSWindow) -> Void = { window in
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
    /// Whether the close question is on screen, so another close or quit
    /// asks nothing more: its answer serves them all.
    private(set) var isAsking = false
    /// What a quit held for the question's answer does once the answer is
    /// carried out: asks AppKit to quit again.
    private var quitWhenAnswered: (@MainActor @Sendable () -> Void)?

    /// Makes `library` the one recordings are saved into. The first time,
    /// as the first Library window appears, looks for recordings left behind.
    func attach(_ library: LibraryViewModel) {
        self.library = library
        lookForRecoveredTakes()
    }

    /// At launch, once: when the Recordings folder holds takes that a crash,
    /// a forced quit, or a save that failed after its window closed left
    /// behind, opens the Record window, which lists them and says so, so
    /// nobody has to know where to look. Reads the folder off the main
    /// thread, and deletes nothing. A test host's launch never looks: its
    /// windows are the tests' own.
    private func lookForRecoveredTakes() {
        guard !hasLookedForRecoveredTakes, !TextMouthRuntime.current.isHostedTest else { return }
        hasLookedForRecoveredTakes = true
        Task { [weak self] in
            let found = await RecordingTakeFiles.readLeftovers()
            // A take a recorder holds, as an audio editor's punch-in, is no
            // recording left behind.
            let inUse = RecordingService.takesInUse
            let recovered = found.filter { !inUse.contains($0.url.standardizedFileURL) }
            guard !recovered.isEmpty, let self, self.window == nil else { return }
            DiagnosticLog.event(.playback, "RECORDING_TAKES_RECOVERED: \(recovered.count) take(s) left in the Recordings folder")
            self.show(recovered: recovered)
        }
    }

    /// Brings the Record window forward, opening it when it is not open:
    /// on `recovered`, the takes left behind that launch found, when given.
    /// Does nothing before a library is attached, which happens as the
    /// first Library window appears.
    func show(library: LibraryViewModel? = nil, recovered: [RecoveredTake] = []) {
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
        let model = makeModel(library: library, recovered: recovered)
        let window = NSWindow(contentViewController: NSHostingController(rootView: RecordingWindowView(model: model)))
        window.title = RecordingWording.windowTitle
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        // TextMouth reopens no window at launch (AppDelegate), this one too.
        window.isRestorable = false
        window.center()
        present(model, in: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // The menu bar shows this window's menus: none of Library's or a
        // reader's.
        NotificationCenter.default.post(name: .refreshContextMenus, object: nil)
    }

    /// Makes `window`, showing `model`, the Record window: the one this
    /// controller answers for until it closes. `show` makes both in the
    /// app; tests hand in their own, kept off screen.
    func present(_ model: RecordingWindowModel, in window: NSWindow) {
        window.delegate = self
        self.window = window
        self.model = model
    }

    /// The model of a new Record window saving into `library`, with this
    /// Mac's microphones, the app's preferences, and VoiceOver, opening on
    /// `recovered`.
    private func makeModel(library: LibraryViewModel, recovered: [RecoveredTake]) -> RecordingWindowModel {
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
            },
            recovered: recovered
        )
    }

    // MARK: - Closing and Quitting

    /// Lets the window close unless a take is under way or waits to be
    /// saved; then asks first, and closes once the answer is carried out.
    /// Command-W again while the question is on screen changes nothing.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model, let question = CloseQuestion(need: model.closeNeed) else { return true }
        if !isAsking {
            ask(question, about: sender)
        }
        return false
    }

    /// Holds a quit while the Record window has a take TextMouth would lose
    /// (FR04), for the app's quit hold (`AppDelegate.applicationShouldTerminate`).
    /// Returns whether it holds this one; the request is then to be
    /// cancelled, and `quit` asks to quit again once the take is dealt with.
    ///
    /// - A take recording, paused, or starting, or one that could not be
    ///   saved: the window comes forward and asks the close question, Stop
    ///   and Save (or Save), Discard, or Cancel; a question already on screen
    ///   answers for the quit too. Stop and Save saves the take, and the quit
    ///   is asked again only once it is saved, so the save finishes before
    ///   TextMouth ends; a save that fails keeps TextMouth open, the window
    ///   saying why. Discard deletes the take, then quits. Cancel keeps the
    ///   take, still recording, and TextMouth open.
    /// - A save under way, as Stop or a lost microphone starts one, or a take
    ///   ending: let finish first, then asked about again, so a save that
    ///   failed is asked about too.
    /// - Anything else, or no window: nothing is held.
    func holdQuit(then quit: @escaping @MainActor @Sendable () -> Void) -> Bool {
        guard let model, let window else { return false }
        if let question = CloseQuestion(need: model.closeNeed) {
            quitWhenAnswered = quit
            bringForward(window)
            if !isAsking {
                ask(question, about: window)
            }
            return true
        }
        guard model.isSettling else { return false }
        Task { [weak self] in
            await model.settle()
            // Asked again: a take saved holds nothing; one that failed asks.
            if self?.holdQuit(then: quit) != true {
                quit()
            }
        }
        return true
    }

    /// Asks `question` about `window`, and carries out the answer.
    private func ask(_ question: CloseQuestion, about window: NSWindow) {
        isAsking = true
        askQuestion(question, window) { [weak self] answer in
            Task { await self?.carryOut(answer, for: window) }
        }
    }

    /// Carries out the answer to the close question: the save answer saves
    /// the take (`RecordingWindowModel.stopAndSave`), Discard deletes it,
    /// and Cancel keeps it, with the window. Once the take is dealt with, a
    /// quit held for the answer asks AppKit to quit again; otherwise the
    /// window closes. A save that fails leaves the window open to say why,
    /// and TextMouth open with it.
    func carryOut(_ answer: CloseAnswer, for window: NSWindow) async {
        isAsking = false
        let quit = quitWhenAnswered
        quitWhenAnswered = nil
        guard let model else { return }
        switch answer {
        case .save:
            await model.stopAndSave()
        case .discard:
            await model.discard()
        case .cancel:
            return
        }
        guard model.closeNeed == .nothing else { return }
        if let quit {
            quit()
        } else {
            window.close()
        }
    }

    /// The close question as AppKit's sheet on `window`: the save answer
    /// first, the default, which Return chooses, then Discard, then Cancel,
    /// to which AppKit gives the Escape key, as the button titled Cancel.
    static func askWithSheet(
        _ question: CloseQuestion,
        window: NSWindow,
        answered: @escaping @MainActor (CloseAnswer) -> Void
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = question.title
        alert.informativeText = question.explanation
        alert.addButton(withTitle: question.saveButton)
        alert.addButton(withTitle: RecordingWording.discardButton)
        alert.addButton(withTitle: RecordingWording.cancelButton)
        alert.beginSheetModal(for: window) { response in
            Task { @MainActor in answered(CloseAnswer(response)) }
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

/// How the question asked before the Record window closes, or TextMouth
/// quits, was answered.
enum CloseAnswer: Equatable, Sendable {
    /// Stop and Save, or Save: save the take.
    case save
    /// Discard: delete the take.
    case discard
    /// Cancel: keep the take and the window.
    case cancel

    /// The answer the button of the sheet's `response` gives: its first
    /// button saves, its second discards, and any other cancels.
    init(_ response: NSApplication.ModalResponse) {
        switch response {
        case .alertFirstButtonReturn: self = .save
        case .alertSecondButtonReturn: self = .discard
        default: self = .cancel
        }
    }
}

/// The question asked before the Record window closes, or TextMouth quits.
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
