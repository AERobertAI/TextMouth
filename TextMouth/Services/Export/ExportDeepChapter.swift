import Foundation
import os

// MARK: - A Chapter Nested Too Deeply (FR24)

/// What the walk of content.md knows of a chapter that nests quotes, lists,
/// or emphasis past the reader's limit (`ExportWalkError.nestedTooDeeply`),
/// handed to whoever decides what the export does with it.
///
/// The chapter is named by its number, never its title, which is the book's
/// text.
struct ExportDeepChapter: Equatable, Sendable {
    /// The chapter's number among the text's chapter markers, from 1; nil for
    /// a text with no chapter markers, whose one chapter is the whole text.
    let number: Int?
    /// The deepest nesting read (`MarkupGuard.Limits.deepestNesting`), which
    /// the chapter passes.
    let limit: Int
    /// How many chapters follow this one in the same text, which may be
    /// nested too deeply as well.
    let chaptersAfter: Int
}

/// What an export does with a chapter nested too deeply.
enum ExportDeepChapterDecision: Equatable, Sendable {
    /// Write the chapter as plain paragraphs, one for each block of its lines
    /// (`RawChapterLines`): the lines trimmed at their ends, blank lines and
    /// TextMouth's own markers left out of the words (markers become places
    /// where the format keeps them), and content.md's backslash escapes
    /// undone, so that its quote and list marks are the characters they are.
    case writeAsWritten
    /// Stop the whole export, as Stop does: the book's text file is not
    /// written and no book after it is exported; files already written, this
    /// book's others included, stay.
    case cancel
}

/// Decides, for a chapter nested too deeply, what the walk does. The walk
/// calls it on the thread it runs on, which waits for the answer, so it may
/// take as long as a person does. A walk given none refuses such a chapter
/// with `ExportWalkError.nestedTooDeeply`, as Edit Text's check does.
typealias ExportDeepChapterDecider = @Sendable (_ chapter: ExportDeepChapter) -> ExportDeepChapterDecision

// MARK: - The Question

/// The question an export asks when it meets a chapter nested too deeply: what
/// the dialog says, and what its buttons offer. The words are
/// `BookExportDeepChapterWording`'s.
struct ExportDeepChapterQuestion: Equatable, Sendable {
    /// The title of the book the chapter is in.
    let bookTitle: String
    /// The chapter's number, from 1; nil for a text with no chapter markers.
    let chapter: Int?
    /// The deepest nesting read, which the chapter passes.
    let limit: Int
    /// Whether the question offers to do the same for every such chapter of
    /// the export: when more chapters follow this one in its text, or more
    /// text files remain to be walked.
    let offersEveryOne: Bool
}

/// The answer to an `ExportDeepChapterQuestion`: the buttons of its dialog.
enum ExportDeepChapterAnswer: Equatable, Sendable {
    /// Write this chapter as it is written.
    case exportAsWritten
    /// Write this chapter as it is written, and every other chapter of the
    /// export that nests too deeply, without asking again.
    case exportEveryOneAsWritten
    /// Stop the whole export.
    case cancelExport
}

// MARK: - The Questioner

/// Asks the question of one export, and remembers its answer, so that "every
/// such chapter" holds for the rest of that export alone.
///
/// An export makes one of these (`BookExportService.export`), and each file it
/// converts takes a decider from it (`decider(for:filesAfter:)`). The ask closure is the
/// seam between the export's thread and the person: the app's blocks that
/// thread until the dialog is answered, and a test's answers at once, so that
/// no test shows an alert.
final class ExportDeepChapterQuestioner: Sendable {
    /// Shows `question` and returns the answer; called on the export's own
    /// thread, once for each chapter asked about.
    typealias Ask = @Sendable (_ question: ExportDeepChapterQuestion) -> ExportDeepChapterAnswer

    /// How the question is put to the person.
    private let ask: Ask
    /// Whether the person chose every such chapter as written, guarded by the
    /// lock itself.
    private let everyOneAsWritten = OSAllocatedUnfairLock(initialState: false)

    /// A questioner that puts its questions through `ask`.
    init(ask: @escaping Ask) {
        self.ask = ask
    }

    /// The decider for the walk of `book`'s text, after which `filesAfter`
    /// more text files of the export remain to be walked.
    func decider(for book: BookExportBookName, filesAfter: Int) -> ExportDeepChapterDecider {
        { [self] chapter in decide(chapter, in: book, filesAfter: filesAfter) }
    }

    /// What to do with `chapter` of `book`: write it as written, without
    /// asking, once the person chose that for every such chapter; otherwise
    /// as the answer to the question says.
    func decide(
        _ chapter: ExportDeepChapter,
        in book: BookExportBookName,
        filesAfter: Int
    ) -> ExportDeepChapterDecision {
        if everyOneAsWritten.withLock({ $0 }) {
            return .writeAsWritten
        }
        let question = ExportDeepChapterQuestion(
            bookTitle: book.title,
            chapter: chapter.number,
            limit: chapter.limit,
            offersEveryOne: filesAfter > 0 || chapter.chaptersAfter > 0
        )
        switch ask(question) {
        case .exportAsWritten:
            return .writeAsWritten
        case .exportEveryOneAsWritten:
            everyOneAsWritten.withLock { $0 = true }
            return .writeAsWritten
        case .cancelExport:
            return .cancel
        }
    }
}
