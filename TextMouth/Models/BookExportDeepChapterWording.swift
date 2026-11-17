import Foundation

/// The words of the question an export asks when a chapter of a book nests
/// quotes, lists, or emphasis past the reader's limit (FR24), built once for
/// the screen and VoiceOver alike: the alert's title, its message, and each
/// button's title and hint.
///
/// The chapter is named by its number, never by its title, as every sentence
/// about such a chapter is (`BookExportWording.nestedTooDeeply(chapter:limit:)`);
/// the book is named by its title, which the person chose.
enum BookExportDeepChapterWording {
    // MARK: The Alert

    /// What the question is about: "Chapter 2 of Deep Notes", or "The text of
    /// Deep Notes" for a text with no chapter markers.
    static func subject(of question: ExportDeepChapterQuestion) -> String {
        question.chapter.map { "Chapter \($0) of \(question.bookTitle)" } ?? "The text of \(question.bookTitle)"
    }

    /// The alert's title, which VoiceOver reads first: "Chapter 2 of Deep
    /// Notes nests too deeply".
    static func title(for question: ExportDeepChapterQuestion) -> String {
        "\(subject(of: question)) nests too deeply"
    }

    /// The alert's message: what is wrong, what each button does, and that
    /// Cancel Export keeps the files already written. The sentence that
    /// names the nesting is `MarkdownNestingWording`'s, as in the refusal.
    static func message(for question: ExportDeepChapterQuestion) -> String {
        let written = question.chapter == nil ? "writes the text" : "writes that chapter"
        var sentences = [
            "\(subject(of: question)) \(MarkdownNestingWording.nestsTooDeeply(limit: question.limit)), "
                + "which TextMouth can't export with its structure.",
            "\(exportAsWrittenTitle) \(written) as plain paragraphs of its lines, with its quote and list marks kept "
                + "as characters, and exports everything else as usual."
        ]
        if question.offersEveryOne {
            sentences.append(
                "\(exportEveryOneAsWrittenTitle) does the same for every chapter of this export that nests too "
                    + "deeply, without asking again."
            )
        }
        sentences.append("\(cancelTitle) stops the whole export: nothing more is written, and the files already written stay.")
        return sentences.joined(separator: " ")
    }

    // MARK: The Buttons

    /// The default button, which Return presses: writes the chapter as it is
    /// written.
    static let exportAsWrittenTitle = "Export as Written"

    /// The button that does the same for every such chapter of the export.
    static let exportEveryOneAsWrittenTitle = "Export Every Such Chapter as Written"

    /// The button Escape presses: stops the whole export.
    static let cancelTitle = "Cancel Export"

    /// What Export as Written does, as its hint.
    static let exportAsWrittenHint =
        "Writes this chapter as plain paragraphs of its lines, and exports everything else as usual."

    /// What Export Every Such Chapter as Written does, as its hint.
    static let exportEveryOneAsWrittenHint =
        "Writes this chapter and every other chapter of this export that nests too deeply as plain paragraphs of "
        + "their lines, without asking again."

    /// What Cancel Export does, as its hint.
    static let cancelHint = "Stops the whole export. Files already written stay, and nothing more is written."
}
