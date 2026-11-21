import AppKit

/// The alert an export shows when a chapter of a book nests quotes, lists, or
/// emphasis past the reader's limit (FR24): Export as Written, optionally
/// Export Every Such Chapter as Written, and Cancel Export.
///
/// A native alert, so VoiceOver reads its title, its message, and each
/// button's title and hint as it opens. Return presses Export as Written, the
/// default, which only writes a new file and removes nothing, so that a
/// reflexive Return costs the person nothing they cannot delete; Escape
/// presses Cancel Export. Every sentence is `BookExportDeepChapterWording`'s.
///
/// The alert is a sheet on the Export dialog's own window, or a window of its
/// own when that is not on screen. The export waits for the answer, so the
/// answer is resumed exactly once, whichever of the buttons, `dismiss()`, and
/// AppKit's own completion comes first: an export can never wait for ever.
@MainActor
final class ExportDeepChapterAlert {
    /// How an alert reaches the screen.
    enum Presentation: Equatable {
        /// A sheet on the dialog's window.
        case sheet
        /// A window of its own, which holds the whole app until it is answered.
        case modal
    }

    /// Where an alert goes, given the window it would be a sheet on: a sheet
    /// on a window that is on screen and has no sheet yet, otherwise a window
    /// of its own. Never another window than the one given: the dialog's.
    static func presentation(windowIsOnScreen: Bool?, windowHasSheet: Bool) -> Presentation {
        windowIsOnScreen == true && !windowHasSheet ? .sheet : .modal
    }

    /// Shows `alert`, over `window` if it is a sheet, and calls `completion`
    /// with the button pressed: what the alert does on screen, and what a test
    /// replaces so that nothing is shown.
    typealias Present = @MainActor (_ alert: NSAlert, _ window: NSWindow?, _ completion: @escaping (NSApplication.ModalResponse) -> Void) -> Void
    /// Takes `alert` off the screen, which ends a sheet or a modal window.
    typealias Take = @MainActor (_ alert: NSAlert) -> Void

    /// The question being asked: its alert, and the answer the export waits
    /// for.
    private struct Pending {
        let alert: NSAlert
        let continuation: CheckedContinuation<ExportDeepChapterAnswer, Never>
    }

    /// The question on screen now, nil when there is none.
    private var pending: Pending?
    /// Shows an alert.
    private let present: Present
    /// Takes an alert down.
    private let take: Take

    /// An alert presenter that shows its alerts on screen, unless a test gives
    /// it a way of its own.
    init(present: @escaping Present = ExportDeepChapterAlert.showOnScreen, take: @escaping Take = ExportDeepChapterAlert.takeOffScreen) {
        self.present = present
        self.take = take
    }

    // MARK: The Alert

    /// The alert that puts `question`: its title and message, and a button for
    /// each answer, the default first. The default's key is Return and
    /// Cancel Export's is Escape, set here since AppKit gives Escape only to
    /// a button titled "Cancel".
    static func makeAlert(for question: ExportDeepChapterQuestion) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = BookExportDeepChapterWording.title(for: question)
        alert.informativeText = BookExportDeepChapterWording.message(for: question)
        alert.addButton(withTitle: BookExportDeepChapterWording.exportAsWrittenTitle)
            .setAccessibilityHelp(BookExportDeepChapterWording.exportAsWrittenHint)
        if question.offersEveryOne {
            alert.addButton(withTitle: BookExportDeepChapterWording.exportEveryOneAsWrittenTitle)
                .setAccessibilityHelp(BookExportDeepChapterWording.exportEveryOneAsWrittenHint)
        }
        let cancel = alert.addButton(withTitle: BookExportDeepChapterWording.cancelTitle)
        cancel.keyEquivalent = "\u{1b}"
        cancel.setAccessibilityHelp(BookExportDeepChapterWording.cancelHint)
        return alert
    }

    /// The answer a button's response stands for, given the buttons the alert
    /// has (`offersEveryOne` adds the second). Anything but a button pressed,
    /// such as the alert being ended from outside, is Cancel Export.
    static func answer(for response: NSApplication.ModalResponse, offersEveryOne: Bool) -> ExportDeepChapterAnswer {
        switch response {
        case .alertFirstButtonReturn:
            return .exportAsWritten
        case .alertSecondButtonReturn:
            return offersEveryOne ? .exportEveryOneAsWritten : .cancelExport
        default:
            return .cancelExport
        }
    }

    // MARK: Asking

    /// Shows the alert for `question`, over `window` (the Export dialog's own)
    /// when that is on screen, and returns the answer. The answer comes once,
    /// from a button or from `dismiss()`, whichever is first.
    func ask(_ question: ExportDeepChapterQuestion, in window: NSWindow?) async -> ExportDeepChapterAnswer {
        let alert = Self.makeAlert(for: question)
        return await withCheckedContinuation { continuation in
            pending = Pending(alert: alert, continuation: continuation)
            NSApp.activate()
            present(alert, window) { [weak self] response in
                self?.finish(with: Self.answer(for: response, offersEveryOne: question.offersEveryOne))
            }
        }
    }

    /// Takes the alert down, if one is on screen, answered as Cancel Export:
    /// Stop, or the dialog closing, while the export waits for the answer. The
    /// answer is given first, so the export is released whether or not AppKit
    /// goes on to call the alert's completion.
    func dismiss() {
        guard let alert = pending?.alert else { return }
        finish(with: .cancelExport)
        take(alert)
    }

    /// Gives the waiting export `answer`, once: the question is no longer
    /// pending, so a second finish, from the completion AppKit calls after
    /// `dismiss()`, resumes nothing.
    private func finish(with answer: ExportDeepChapterAnswer) {
        guard let waiting = pending else { return }
        pending = nil
        waiting.continuation.resume(returning: answer)
    }

    // MARK: On Screen

    /// Shows `alert` as a sheet on `window` when `presentation` says so, and
    /// otherwise in a window of its own.
    static func showOnScreen(_ alert: NSAlert, over window: NSWindow?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        switch presentation(windowIsOnScreen: window?.isVisible, windowHasSheet: window?.attachedSheet != nil) {
        case .sheet:
            if let window {
                alert.beginSheetModal(for: window, completionHandler: completion)
            }
        case .modal:
            completion(alert.runModal())
        }
    }

    /// Ends the sheet `alert` is, or the modal window it is.
    static func takeOffScreen(_ alert: NSAlert) {
        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .cancel)
        } else if NSApp.modalWindow === alert.window {
            // A window of its own: only a modal loop that is ours is aborted.
            NSApp.abortModal()
        }
    }
}
