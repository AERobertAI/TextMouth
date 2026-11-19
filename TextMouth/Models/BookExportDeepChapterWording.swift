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
        guard let chapter = question.chapter else {
            return String(localized: "The text of \(question.bookTitle)",
                          comment: "Names what the export's deep-nesting question is about: a book's whole text, which has no chapter markers. %@ is the book's title.")
        }
        // The chapter's number names it, so it is written without grouping.
        return String(localized: "Chapter \(String(chapter)) of \(question.bookTitle)",
                      comment: "Names what the export's deep-nesting question is about: one chapter of a book. %1$@ is the chapter's number, an identifier written without digit grouping, and %2$@ the book's title.")
    }

    /// The alert's title, which VoiceOver reads first: "Chapter 2 of Deep
    /// Notes nests too deeply".
    static func title(for question: ExportDeepChapterQuestion) -> String {
        String(localized: "\(subject(of: question)) nests too deeply",
               comment: "The title of the alert an export shows when a chapter nests quotes, lists, or emphasis too deeply. %@ names what nests, such as \"Chapter 2 of Deep Notes\".")
    }

    /// The alert's message: what is wrong, what each button does, and that
    /// Cancel Export keeps the files already written. The sentence that
    /// names the nesting is `MarkdownNestingWording`'s, as in the refusal.
    static func message(for question: ExportDeepChapterQuestion) -> String {
        let nests = MarkdownNestingWording.nestsTooDeeply(limit: question.limit)
        var sentences = [
            String(localized: "\(subject(of: question)) \(nests), which TextMouth can't export with its structure.",
                   comment: "The first sentence of the alert an export shows when a chapter nests too deeply. %1$@ names what nests, such as \"Chapter 2 of Deep Notes\", and %2$@ is the clause that says how deep, such as \"nests quotes, lists, or emphasis more than 128 levels deep\"."),
            question.chapter == nil
                ? String(localized: "\(exportAsWrittenTitle) writes the text as plain paragraphs of its lines, with its quote and list marks kept as characters, and exports everything else as usual.",
                         comment: "The second sentence of the alert an export shows when a book's text, which has no chapter markers, nests too deeply. %@ is the name of the Export as Written button.")
                : String(localized: "\(exportAsWrittenTitle) writes that chapter as plain paragraphs of its lines, with its quote and list marks kept as characters, and exports everything else as usual.",
                         comment: "The second sentence of the alert an export shows when a chapter nests too deeply. %@ is the name of the Export as Written button.")
        ]
        if question.offersEveryOne {
            sentences.append(
                String(localized: "\(exportEveryOneAsWrittenTitle) does the same for every such chapter of this export, without asking again.",
                       comment: "The third sentence of the alert an export shows when a chapter nests too deeply and others may too. %@ is the name of the Export Every Such Chapter as Written button.")
            )
        }
        sentences.append(String(localized: "\(cancelTitle) stops the whole export. Files already written stay.",
                                comment: "The last sentence of the alert an export shows when a chapter nests too deeply. %@ is the name of the Cancel Export button."))
        return SentenceWording.joined(sentences)
    }

    // MARK: The Buttons

    /// The default button, which Return presses: writes the chapter as it is
    /// written.
    static var exportAsWrittenTitle: String {
        String(localized: "Export as Written",
               comment: "The default button of the alert an export shows when a chapter nests too deeply: it writes the chapter as plain paragraphs.")
    }

    /// The button that does the same for every such chapter of the export.
    static var exportEveryOneAsWrittenTitle: String {
        String(localized: "Export Every Such Chapter as Written",
               comment: "A button of the alert an export shows when a chapter nests too deeply: it writes every such chapter of the export as plain paragraphs, without asking again.")
    }

    /// The button Escape presses: stops the whole export.
    static var cancelTitle: String {
        String(localized: "Cancel Export",
               comment: "The button of the alert an export shows when a chapter nests too deeply: it stops the whole export.")
    }

    /// What Export as Written does, as its hint.
    static var exportAsWrittenHint: String {
        String(localized: "Writes this chapter as plain paragraphs of its lines, and exports everything else as usual.",
               comment: "The hint of the Export as Written button in the alert an export shows when a chapter nests too deeply.")
    }

    /// What Export Every Such Chapter as Written does, as its hint.
    static var exportEveryOneAsWrittenHint: String {
        String(localized: "Writes this and every other too-deeply nested chapter of this export as plain paragraphs of lines, without asking again.",
               comment: "The hint of the Export Every Such Chapter as Written button in the alert an export shows when a chapter nests too deeply.")
    }

    /// What Cancel Export does, as its hint.
    static var cancelHint: String {
        String(localized: "Stops the whole export. Files already written stay.",
               comment: "The hint of the Cancel Export button in the alert an export shows when a chapter nests too deeply.")
    }
}
