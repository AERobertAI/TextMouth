import Combine
import Foundation

/// The question an export on the iPhone puts to the person when a chapter of a
/// book nests quotes, lists, or emphasis past the reader's limit (FR24, FR31):
/// the Mac's alert, `ExportDeepChapterAlert`, as an alert of the iPhone's own.
///
/// Its title and message are the Mac's, and the message says what each button
/// does, since an iOS alert's buttons have no hints. The buttons are the Mac's
/// too: Export as Written, the default, which only writes a new file and
/// removes nothing; Export Every Such Chapter as Written, while more such
/// chapters may follow; and Cancel Export, which the escape gesture presses
/// and which any dismissal of the alert counts as.
struct PhoneExportQuestion: Equatable, Identifiable {
    /// One button of the alert.
    enum Choice: Hashable, Sendable {
        /// Write this chapter as plain paragraphs of its lines.
        case exportAsWritten
        /// Do so for every such chapter of the export, without asking again.
        case exportEveryOneAsWritten
        /// Stop the whole export.
        case cancelExport

        /// The button's title.
        var title: String {
            switch self {
            case .exportAsWritten: return BookExportDeepChapterWording.exportAsWrittenTitle
            case .exportEveryOneAsWritten: return BookExportDeepChapterWording.exportEveryOneAsWrittenTitle
            case .cancelExport: return BookExportDeepChapterWording.cancelTitle
            }
        }

        /// The answer the export gets when this button is pressed.
        var answer: ExportDeepChapterAnswer {
            switch self {
            case .exportAsWritten: return .exportAsWritten
            case .exportEveryOneAsWritten: return .exportEveryOneAsWritten
            case .cancelExport: return .cancelExport
            }
        }
    }

    /// Tells one question from the next one the same export asks.
    let id: UUID
    /// The question the export asked.
    let question: ExportDeepChapterQuestion

    /// A question that puts `question`.
    init(_ question: ExportDeepChapterQuestion, id: UUID = UUID()) {
        self.question = question
        self.id = id
    }

    /// The alert's title, the Mac's: "Chapter 2 of Deep Notes nests too deeply".
    var title: String {
        BookExportDeepChapterWording.title(for: question)
    }

    /// The alert's message, the Mac's, which says what each button does.
    var message: String {
        BookExportDeepChapterWording.message(for: question)
    }

    /// The buttons, in the order the alert lists them: the default first, the
    /// every-chapter button only while more such chapters may follow, and
    /// Cancel Export last, which is the alert's cancel role.
    var choices: [Choice] {
        question.offersEveryOne
            ? [.exportAsWritten, .exportEveryOneAsWritten, .cancelExport]
            : [.exportAsWritten, .cancelExport]
    }

    /// What a dismissal of the alert without a button, such as the escape
    /// gesture or the export being stopped, answers: Cancel Export.
    static let dismissalChoice = Choice.cancelExport
}

/// The question an export waits on, shown by the Export sheet as an alert,
/// and its answer: what `BookExportModel`'s prompt is on the iPhone
/// (`DeepChapterPrompting.standard`), the counterpart of the Mac's alert
/// presenter.
///
/// The export runs off the main thread and waits for the answer, so the
/// answer is given exactly once, whichever of a button, `dismiss()`, and a
/// second question's arrival comes first: an export can never wait for ever.
/// The sheet observes `pending` and shows an alert while it is not nil.
@MainActor
final class PhoneExportQuestionPrompt: ObservableObject {
    /// The question being asked, nil when there is none.
    @Published private(set) var pending: PhoneExportQuestion?
    /// The export's wait for the answer to `pending`.
    private var continuation: CheckedContinuation<ExportDeepChapterAnswer, Never>?
    /// Whether the sheet that shows the alert has closed, after which nobody can answer.
    private var isSheetClosed = false
    /// Whether a question came after that, and was answered Cancel Export at once.
    private var wasAskedWithTheSheetClosed = false

    /// What the end of the export says when a question came with the sheet closed, so that nobody could answer it; nil
    /// when none did.
    var wordsAfterTheEnd: String? {
        wasAskedWithTheSheetClosed ? PhoneExportWording.questionWithNoSheet : nil
    }

    /// The sheet that shows the alert has closed, the spoken audio file being made: no question can be put now. One asked
    /// from here on is answered Cancel Export at once, the safest answer, since the export would wait for ever for a
    /// person who cannot see it (nobody can be asked, which the Mac's export meets with no question at all, but the walk's
    /// choices for a chapter nested too deeply are to write it as it is or to stop).
    func sheetClosed() {
        isSheetClosed = true
    }

    /// Shows `question` and returns the answer, once the person has pressed
    /// a button or the prompt was dismissed. A question asked while another
    /// waits cancels the export: an export asks one at a time, so this is
    /// only an export that went wrong, and none waits for ever.
    func ask(_ question: ExportDeepChapterQuestion) async -> ExportDeepChapterAnswer {
        guard !isSheetClosed else {
            wasAskedWithTheSheetClosed = true
            return .cancelExport
        }
        guard continuation == nil else { return .cancelExport }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            pending = PhoneExportQuestion(question)
        }
    }

    /// The person pressed `choice` of the question shown: the export is given
    /// its answer, and the alert goes.
    func answer(_ choice: PhoneExportQuestion.Choice) {
        finish(with: choice.answer)
    }

    /// Takes the question down if one is shown, answered as Cancel Export:
    /// Stop, the sheet closing, or the alert dismissed by the system while
    /// the export waits.
    func dismiss() {
        finish(with: PhoneExportQuestion.dismissalChoice.answer)
    }

    /// Gives the waiting export `answer`, once: the question is no longer
    /// pending, so a second call resumes nothing.
    private func finish(with answer: ExportDeepChapterAnswer) {
        pending = nil
        guard let waiting = continuation else { return }
        continuation = nil
        waiting.resume(returning: answer)
    }
}
