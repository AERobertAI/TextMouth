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
/// The alert is a sheet on the window in front, the Export dialog, or a
/// window of its own when no sheet can be attached.
@MainActor
final class ExportDeepChapterAlert {
    /// The alert on screen now, nil when there is none.
    private var showing: NSAlert?

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

    /// Shows the alert for `question` and returns the answer. Takes the
    /// window in front as the sheet's parent when it can hold one.
    func ask(_ question: ExportDeepChapterQuestion) async -> ExportDeepChapterAnswer {
        let alert = Self.makeAlert(for: question)
        showing = alert
        defer { showing = nil }
        NSApp.activate()
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow, window.isVisible, window.attachedSheet == nil {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        return Self.answer(for: response, offersEveryOne: question.offersEveryOne)
    }

    /// Takes the alert down, if one is on screen, as Cancel Export: Stop, or
    /// the dialog closing, while the export waits for the answer.
    func dismiss() {
        guard let alert = showing else { return }
        if let parent = alert.window.sheetParent {
            parent.endSheet(alert.window, returnCode: .cancel)
        } else if NSApp.modalWindow === alert.window {
            // A window of its own: only a modal loop that is ours is aborted.
            NSApp.abortModal()
        }
    }
}
