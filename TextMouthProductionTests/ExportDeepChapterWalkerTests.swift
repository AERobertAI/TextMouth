import XCTest
import os
@testable import TextMouth

/// A chapter nested too deeply, exported as it is written (FR24): the walk of
/// content.md hands such a chapter to a decider instead of refusing it, and
/// writes it as plain paragraphs of its lines when the decider says so, or
/// stops the export when it says to cancel. The questioner that sits behind
/// the decider remembers "every such chapter" for one export, and the
/// question's words are pinned here.
///
/// Every depth that reaches the walk is one the old walk survives, since a
/// chapter past the limit is refused before anything is walked, and the chapter
/// written as written is never walked at all (a few hundred levels at the
/// most, as in `ExportDocumentWalkerNestingTests`). Hermetic: no library, no
/// file, and nothing is shown to a person.
final class ExportDeepChapterWalkerTests: XCTestCase {

    // MARK: - Helpers

    /// The limits every reading has.
    private let limits = MarkupGuard.Limits.standard

    /// The deepest nesting read (128).
    private var limit: Int { limits.deepestNesting }

    /// The chapters a decider was asked about, kept under a lock since the
    /// walk calls the decider on a thread of its own.
    private final class Asked: Sendable {
        private let chapters = OSAllocatedUnfairLock<[ExportDeepChapter]>(initialState: [])

        /// A decider that records its chapter and says `decision`.
        func deciding(_ decision: ExportDeepChapterDecision) -> ExportDeepChapterDecider {
            { [self] chapter in
                chapters.withLock { $0.append(chapter) }
                return decision
            }
        }

        /// The chapters asked about, in order.
        var all: [ExportDeepChapter] { chapters.withLock { $0 } }
    }

    /// The document of `markdown`, walked with `decider`.
    private func walk(
        _ markdown: String,
        options: ExportWalkOptions = .plain,
        decider: ExportDeepChapterDecider?
    ) throws -> ExportDocument {
        try ExportDocumentWalker.document(
            fromMarkdown: markdown, book: ExportBookDetails(title: ""), options: options, deepChapters: decider
        )
    }

    /// The text of each paragraph of `document`, in order.
    private func paragraphs(of document: ExportDocument) -> [String] {
        document.blocks.compactMap { block in
            if case let .paragraph(runs) = block { return runs.plainText }
            return nil
        }
    }

    /// The text of each heading of `document`, in order.
    private func headings(of document: ExportDocument) -> [String] {
        document.blocks.compactMap { block in
            if case let .heading(heading) = block { return heading.runs.plainText }
            return nil
        }
    }

    /// The lines of `text` that hold something, each trimmed: what a chapter
    /// written as written has for paragraphs.
    private func lines(of text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A chapter marker line, as content.md carries one.
    private func marker(_ title: String) -> String {
        MarkdownCacheService.chapterMarker(title: title)
    }

    // MARK: - Written as it is

    /// Every shape of nesting, one level past the limit, is written as one
    /// paragraph for each of its lines, with every mark kept as the character
    /// it is, and no block quote, list, or other structure; the decider is
    /// asked once, for a text with no chapter markers (chapter nil).
    func testEveryShapeOnePastTheLimitIsWrittenAsItsLines() throws {
        let shapes = DeepMarkdown.shapes().map { (name: $0.name, text: $0.text($0.edge + 1)) }
            + [(name: "quoted table", text: DeepMarkdown.quotedTable(limit + 1))]
        for shape in shapes {
            let asked = Asked()
            let document = try walk(shape.text, decider: asked.deciding(.writeAsWritten))

            XCTAssertEqual(paragraphs(of: document), lines(of: shape.text), shape.name)
            XCTAssertEqual(document.blocks.count, lines(of: shape.text).count, "\(shape.name) has paragraphs and nothing else")
            XCTAssertEqual(
                asked.all, [ExportDeepChapter(number: nil, limit: limit, chaptersAfter: 0)], shape.name
            )
        }
    }

    /// The lines of a deep quote keep their marks exactly: 129 quote marks and
    /// the words, one paragraph, the marks not read as quotes.
    func testTheMarksStayAsCharacters() throws {
        let deep = DeepMarkdown.quotes(limit + 1)
        let document = try walk(deep, decider: Asked().deciding(.writeAsWritten))

        XCTAssertEqual(paragraphs(of: document), [String(repeating: "> ", count: limit + 1) + "Quoted words"])
        XCTAssertFalse(document.blocks.contains { if case .blockQuote = $0 { return true } else { return false } })
    }

    /// A text at the limit is walked as it always was, with its words and its
    /// structure, and the decider is never asked.
    func testATextAtTheLimitIsWalkedAndNeverAsked() throws {
        for shape in DeepMarkdown.shapes() {
            let asked = Asked()
            let document = try walk(shape.text(shape.edge), decider: asked.deciding(.cancel))

            XCTAssertEqual(asked.all, [], "\(shape.name) at \(shape.edge)")
            XCTAssertTrue(document.blocks.map(\.plainText).joined(separator: " ").contains(shape.word), shape.name)
        }
    }

    /// Only the chapter nested too deeply is written as written: the chapters
    /// around it keep their headings, lists, and the rest, the decider is told
    /// which chapter by its number and how many follow it, and the chapter
    /// that has no heading of its own begins with its title, as any chapter
    /// does.
    func testOnlyTheDeepChapterIsWrittenAsItIsWritten() throws {
        let deep = DeepMarkdown.quotes(limit + 1)
        let book = "\(marker("First"))\n# Heading One\n\nPlain words.\n\n"
            + "\(marker("Second"))\n\(deep)\n\n"
            + "\(marker("Third"))\n- one\n- two\n"
        let asked = Asked()

        let document = try walk(book, decider: asked.deciding(.writeAsWritten))

        XCTAssertEqual(asked.all, [ExportDeepChapter(number: 2, limit: limit, chaptersAfter: 1)])
        XCTAssertEqual(headings(of: document), ["Heading One", "Second", "Third"])
        XCTAssertEqual(paragraphs(of: document), ["Plain words.", String(repeating: "> ", count: limit + 1) + "Quoted words"])
        let lists = document.blocks.filter { if case .list = $0 { return true } else { return false } }
        XCTAssertEqual(lists.count, 1, "the third chapter's list is still a list")
    }

    /// Two chapters nested too deeply are two questions, each told its own
    /// number and how many chapters follow.
    func testEachDeepChapterIsAskedAbout() throws {
        let deep = DeepMarkdown.quotes(limit + 1)
        let book = "\(marker("One"))\n\(deep)\n\n\(marker("Two"))\nWords.\n\n\(marker("Three"))\n\(deep)"
        let asked = Asked()

        _ = try walk(book, decider: asked.deciding(.writeAsWritten))

        XCTAssertEqual(
            asked.all,
            [
                ExportDeepChapter(number: 1, limit: limit, chaptersAfter: 2),
                ExportDeepChapter(number: 3, limit: limit, chaptersAfter: 0),
            ]
        )
    }

    /// A line is trimmed of the spaces and tabs at its ends, a blank line is
    /// no paragraph, and a CR LF ends a line like a line feed: the words and
    /// the marks are exactly as written.
    func testLinesAreTrimmedAndBlankLinesLeftOut() throws {
        let deep = DeepMarkdown.quotes(limit + 1)
        let text = deep + "\r\n\r\n   indented words  \r\n\t- a mark\r\n   \r\n"

        let document = try walk(text, decider: Asked().deciding(.writeAsWritten))

        XCTAssertEqual(paragraphs(of: document), [String(repeating: "> ", count: limit + 1) + "Quoted words", "indented words", "- a mark"])
    }

    /// Cancelling stops the walk with `CancellationError`, so the export
    /// stops as Stop stops it and nothing is written for the book.
    func testCancellingStopsTheWalk() {
        let asked = Asked()
        XCTAssertThrowsError(
            try walk(DeepMarkdown.quotes(limit + 1), decider: asked.deciding(.cancel))
        ) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(asked.all.count, 1)
    }

    /// With no decider the chapter is refused as before, naming its number:
    /// Edit Text's check and every walk that asks nothing.
    func testWithoutADeciderTheChapterIsStillRefused() {
        let book = "\(marker("One"))\nWords.\n\n\(marker("Two"))\n\(DeepMarkdown.quotes(limit + 1))"
        XCTAssertThrowsError(try walk(book, decider: nil)) { error in
            XCTAssertEqual(error as? ExportWalkError, .nestedTooDeeply(chapter: 2, limit: self.limit))
        }
    }

    // MARK: - TextMouth's markers

    /// A marker at the start of a line of the chapter is no words: it is the
    /// place it marks when the walk keeps places, and the words after it, if
    /// any, are the line. A walk of the words alone leaves the marker out.
    func testMarkersInADeepChapterAreKeptAsPlacesNotWords() throws {
        let deep = DeepMarkdown.quotes(limit + 1)
        let chapter = "\(marker("Notes"))\n\(MarkdownWalkCorpusKit.page("7"))\n\(deep)\n"
            + "\(MarkdownWalkCorpusKit.page("8")) words after the marker\n"
        let expected = [String(repeating: "> ", count: limit + 1) + "Quoted words", "words after the marker"]

        let structured = try walk(chapter, options: .bookStructure, decider: Asked().deciding(.writeAsWritten))
        let pages = structured.blocks.compactMap { block -> String? in
            if case let .pageBreak(page) = block { return page.label }
            return nil
        }
        XCTAssertEqual(pages, ["7", "8"])
        XCTAssertEqual(paragraphs(of: structured), expected)

        let plain = try walk(chapter, decider: Asked().deciding(.writeAsWritten))
        XCTAssertEqual(paragraphs(of: plain), expected)
        XCTAssertEqual(headings(of: plain), ["Notes"])
        XCTAssertFalse(plain.blocks.contains { if case .pageBreak = $0 { return true } else { return false } })
    }

    /// A deep rest of a marker line is refused part of the way through a walk,
    /// after the marker's page was numbered: written as written, the page keeps
    /// the first number, not the second, and the paragraph is the whole line.
    func testAnAbandonedWalkLeavesNoPageNumberUsed() throws {
        let deep = DeepMarkdown.quotes(limit + 1)
        let chapter = "\(marker("Notes"))\n\(MarkdownWalkCorpusKit.page("1"))\(deep)\n"

        let document = try walk(chapter, options: .bookStructure, decider: Asked().deciding(.writeAsWritten))

        let pages = document.blocks.compactMap { block -> ExportPageBreak? in
            if case let .pageBreak(page) = block { return page }
            return nil
        }
        XCTAssertEqual(pages, [ExportPageBreak(label: "1", id: "page_1")])
        XCTAssertEqual(paragraphs(of: document), [String(repeating: "> ", count: limit + 1) + "Quoted words"])
    }

    // MARK: - The questioner

    /// A questioner for an export of `bookCount` books whose person answers
    /// from `answers`, in order, and records each question.
    private func makeQuestioner(
        bookCount: Int,
        answers: [ExportDeepChapterAnswer],
        into questions: OSAllocatedUnfairLock<[ExportDeepChapterQuestion]>
    ) -> ExportDeepChapterQuestioner {
        let remaining = OSAllocatedUnfairLock(initialState: answers)
        return ExportDeepChapterQuestioner(bookCount: bookCount) { question in
            questions.withLock { $0.append(question) }
            // Cancelling is what a script that ran out of answers says.
            return remaining.withLock { queue -> ExportDeepChapterAnswer in
                queue.isEmpty ? .cancelExport : queue.removeFirst()
            }
        }
    }

    /// The question names the book, the chapter, and the limit, and offers
    /// the same for every such chapter only when the export holds another
    /// book, or the book has chapters after this one.
    func testTheQuestionOffersEveryChapterOnlyWhenMoreMayFollow() {
        let book = BookExportBookName(id: UUID(), title: "Deep Notes")
        let questions = OSAllocatedUnfairLock<[ExportDeepChapterQuestion]>(initialState: [])

        let single = makeQuestioner(bookCount: 1, answers: [.exportAsWritten, .exportAsWritten], into: questions)
        _ = single.decide(ExportDeepChapter(number: 2, limit: 128, chaptersAfter: 0), in: book)
        _ = single.decide(ExportDeepChapter(number: 2, limit: 128, chaptersAfter: 3), in: book)
        let several = makeQuestioner(bookCount: 2, answers: [.exportAsWritten], into: questions)
        _ = several.decide(ExportDeepChapter(number: nil, limit: 128, chaptersAfter: 0), in: book)

        XCTAssertEqual(
            questions.withLock { $0 },
            [
                ExportDeepChapterQuestion(bookTitle: "Deep Notes", chapter: 2, limit: 128, offersEveryOne: false),
                ExportDeepChapterQuestion(bookTitle: "Deep Notes", chapter: 2, limit: 128, offersEveryOne: true),
                ExportDeepChapterQuestion(bookTitle: "Deep Notes", chapter: nil, limit: 128, offersEveryOne: true),
            ]
        )
    }

    /// Each answer is the decision it says, and "every such chapter" is
    /// remembered: no later chapter, of any book, is asked about.
    func testAnswersBecomeDecisionsAndEveryChapterIsRemembered() {
        let first = BookExportBookName(id: UUID(), title: "First")
        let second = BookExportBookName(id: UUID(), title: "Second")
        let chapter = ExportDeepChapter(number: 1, limit: 128, chaptersAfter: 0)
        let questions = OSAllocatedUnfairLock<[ExportDeepChapterQuestion]>(initialState: [])

        let one = makeQuestioner(bookCount: 2, answers: [.exportAsWritten, .cancelExport], into: questions)
        XCTAssertEqual(one.decide(chapter, in: first), .writeAsWritten)
        XCTAssertEqual(one.decide(chapter, in: second), .cancel)
        XCTAssertEqual(questions.withLock { $0.count }, 2, "each chapter is asked until the person says otherwise")

        let everyOne = makeQuestioner(bookCount: 2, answers: [.exportEveryOneAsWritten], into: questions)
        XCTAssertEqual(everyOne.decider(for: first)(chapter), .writeAsWritten)
        XCTAssertEqual(everyOne.decider(for: second)(chapter), .writeAsWritten)
        XCTAssertEqual(everyOne.decider(for: second)(chapter), .writeAsWritten)
        XCTAssertEqual(questions.withLock { $0.count }, 3, "only the first of the three was asked")

        // A new questioner, as a new export makes, asks again.
        let another = makeQuestioner(bookCount: 2, answers: [.exportAsWritten], into: questions)
        XCTAssertEqual(another.decide(chapter, in: first), .writeAsWritten)
        XCTAssertEqual(questions.withLock { $0.count }, 4)
    }

    // MARK: - The words

    /// The question's words, exactly as the alert shows and VoiceOver reads
    /// them: the chapter by its number, the book by its title.
    func testTheQuestionWords() {
        let single = ExportDeepChapterQuestion(bookTitle: "Deep Notes", chapter: 2, limit: 128, offersEveryOne: false)
        XCTAssertEqual(BookExportDeepChapterWording.title(for: single), "Chapter 2 of Deep Notes nests too deeply")
        XCTAssertEqual(
            BookExportDeepChapterWording.message(for: single),
            "Chapter 2 of Deep Notes nests quotes, lists, or emphasis more than 128 levels deep, "
                + "which TextMouth can't export with its structure. "
                + "Export as Written writes that chapter as plain paragraphs of its lines, with its quote and list marks "
                + "kept as characters, and exports everything else as usual. "
                + "Cancel Export stops the whole export: nothing more is written, and the files already written stay."
        )

        let several = ExportDeepChapterQuestion(bookTitle: "Deep Notes", chapter: 2, limit: 128, offersEveryOne: true)
        XCTAssertEqual(
            BookExportDeepChapterWording.message(for: several),
            "Chapter 2 of Deep Notes nests quotes, lists, or emphasis more than 128 levels deep, "
                + "which TextMouth can't export with its structure. "
                + "Export as Written writes that chapter as plain paragraphs of its lines, with its quote and list marks "
                + "kept as characters, and exports everything else as usual. "
                + "Export Every Such Chapter as Written does the same for every chapter of this export that nests too "
                + "deeply, without asking again. "
                + "Cancel Export stops the whole export: nothing more is written, and the files already written stay."
        )

        let whole = ExportDeepChapterQuestion(bookTitle: "Deep Notes", chapter: nil, limit: 128, offersEveryOne: false)
        XCTAssertEqual(BookExportDeepChapterWording.title(for: whole), "The text of Deep Notes nests too deeply")
        XCTAssertTrue(BookExportDeepChapterWording.message(for: whole).contains("Export as Written writes the text as plain paragraphs"))
    }

    /// The buttons' titles and hints, exactly.
    func testTheButtonWords() {
        XCTAssertEqual(BookExportDeepChapterWording.exportAsWrittenTitle, "Export as Written")
        XCTAssertEqual(BookExportDeepChapterWording.exportEveryOneAsWrittenTitle, "Export Every Such Chapter as Written")
        XCTAssertEqual(BookExportDeepChapterWording.cancelTitle, "Cancel Export")
        XCTAssertEqual(
            BookExportDeepChapterWording.exportAsWrittenHint,
            "Writes this chapter as plain paragraphs of its lines, and exports everything else as usual."
        )
        XCTAssertEqual(
            BookExportDeepChapterWording.exportEveryOneAsWrittenHint,
            "Writes this chapter and every other chapter of this export that nests too deeply as plain paragraphs of "
                + "their lines, without asking again."
        )
        XCTAssertEqual(
            BookExportDeepChapterWording.cancelHint,
            "Stops the whole export. Files already written stay, and nothing more is written."
        )
    }

    /// The refusal for a caller that asks nothing keeps its words, which Edit
    /// Text's refusal shares the nesting phrase of.
    func testTheRefusalWordsAreUnchanged() {
        XCTAssertEqual(
            ExportWalkError.nestedTooDeeply(chapter: 3, limit: 128).localizedDescription,
            "Chapter 3 of this book nests quotes, lists, or emphasis more than 128 levels deep, "
                + "which TextMouth can't export safely. Choose Edit Text, flatten the nesting, and save; then export again."
        )
    }
}
