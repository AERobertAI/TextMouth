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
    /// paragraph of its lines (a line feed between them: they have no blank
    /// line), with every mark kept as the character it is, and no block quote,
    /// list, or other structure; the decider is asked once, for a text with no
    /// chapter markers (chapter nil).
    func testEveryShapeOnePastTheLimitIsWrittenAsItsLines() throws {
        let shapes = DeepMarkdown.shapes().map { (name: $0.name, text: $0.text($0.edge + 1)) }
            + [(name: "quoted table", text: DeepMarkdown.quotedTable(limit + 1))]
        for shape in shapes {
            let asked = Asked()
            let document = try walk(shape.text, decider: asked.deciding(.writeAsWritten))

            XCTAssertEqual(paragraphs(of: document), [lines(of: shape.text).joined(separator: "\n")], shape.name)
            XCTAssertEqual(document.blocks.count, 1, "\(shape.name) is one paragraph and nothing else")
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

    /// A line is trimmed of the spaces and tabs at its ends, a blank line ends
    /// a paragraph and is none, and a CR LF ends a line like a line feed: the
    /// lines of a block are one paragraph, apart by a line feed.
    func testLinesAreTrimmedAndBlankLinesLeftOut() throws {
        let deep = DeepMarkdown.quotes(limit + 1)
        let text = deep + "\r\n\r\n   indented words  \r\n\t- a mark\r\n   \r\n"

        let document = try walk(text, decider: Asked().deciding(.writeAsWritten))

        XCTAssertEqual(
            paragraphs(of: document),
            [String(repeating: "> ", count: limit + 1) + "Quoted words", "indented words\n- a mark"]
        )
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

    // MARK: - Content.md as the converters write it

    /// The words of the sample line, as a book holds them: every kind of
    /// punctuation a sentence has, and a U+FEFF.
    private let sampleWords = "He said, \"Wait.\" It's 3:00 (or so); a_b *c* [d] <e> & f\u{FEFF}g"

    /// A line of `levels` quotes and then `words`, written as the converters
    /// write it: the quote marks as they are, the words through
    /// `MarkdownLiteral.escaped`.
    private func contentLine(levels: Int, words: String) -> String {
        String(repeating: "> ", count: levels) + MarkdownLiteral.escaped(words)
    }

    /// The words of the sample line, as the reader and every format give them,
    /// after `levels` quote marks that stay characters.
    private func writtenLine(levels: Int, words: String) -> String {
        String(repeating: "> ", count: levels) + words
    }

    /// Every page label of `document`, between blocks and inside paragraphs.
    private func pageLabels(of document: ExportDocument) -> [String] {
        document.blocks.flatMap { block -> [String] in
            switch block {
            case let .pageBreak(page):
                return [page.label]
            case let .paragraph(runs):
                return runs.compactMap { $0.pageBreak?.label }
            default:
                return []
            }
        }
    }

    /// A deep line as content.md holds it escapes every punctuation mark of its
    /// words with a backslash; written as written, the words are the book's
    /// own, with no backslash, and the U+FEFF is a character again.
    func testBackslashEscapesAreUndone() throws {
        let content = contentLine(levels: limit + 1, words: sampleWords)
        XCTAssertTrue(content.contains("\\,"), "the fixture is escaped, as the converters write it")
        XCTAssertTrue(content.contains("&#xFEFF;"))

        let document = try walk(content, decider: Asked().deciding(.writeAsWritten))

        XCTAssertEqual(paragraphs(of: document), [writtenLine(levels: limit + 1, words: sampleWords)])
    }

    /// A backslash before anything that is not ASCII punctuation is a backslash,
    /// and so is the last one on a line; a Markdown book's own `\*` is a star.
    func testOnlyAnEscapeIsUndone() {
        XCTAssertEqual(RawChapterLines.unescaped("a\\,b \\* \\\\ c\\d e\\"), "a,b * \\ c\\d e\\")
        XCTAssertEqual(RawChapterLines.unescaped("x&#xFEFF;y"), "x\u{FEFF}y")
        // A reference an escape came before is text, and no other reference is read.
        XCTAssertEqual(RawChapterLines.unescaped("\\&#xFEFF; &amp; &#65;"), "&#xFEFF; &amp; &#65;")
    }

    /// A marker at a quote's opening (the converters write it in a block of its
    /// own inside the quote, and the words go on the next line) is no words
    /// and its page is kept; the words that follow are as written.
    func testAMarkerAtAQuotesOpeningIsAPlaceNotWords() throws {
        var content = String(repeating: "> ", count: limit + 1)
        MarkdownMarkerWriter.write(MarkdownMarkers.page("12"), inline: true, into: &content)
        content += MarkdownLiteral.escaped(sampleWords)
        XCTAssertTrue(content.contains("<!-- page: 12 -->"), "the writer wrote the marker")

        let structured = try walk(content, options: .bookStructure, decider: Asked().deciding(.writeAsWritten))
        let plain = try walk(content, decider: Asked().deciding(.writeAsWritten))

        XCTAssertEqual(pageLabels(of: structured), ["12"])
        for document in [structured, plain] {
            let text = paragraphs(of: document).joined(separator: "\n")
            XCTAssertFalse(text.contains("<!--"), "the marker is no words: \(text)")
            XCTAssertTrue(text.contains(sampleWords), "the words are the book's own: \(text)")
        }
        XCTAssertEqual(pageLabels(of: plain), [], "a walk of the words alone keeps no page")
    }

    /// A marker within a line's words, as the converters write it (after
    /// the words before it, with the rest of the words after it) is a place in
    /// the words, and no words.
    func testAMarkerWithinWordsIsAPlaceInTheWords() throws {
        var content = String(repeating: "> ", count: limit + 1) + MarkdownLiteral.escaped("so (or so);")
        MarkdownMarkerWriter.write(MarkdownMarkers.page("13"), inline: true, into: &content)
        content += MarkdownLiteral.escaped(" then left.")

        let structured = try walk(content, options: .bookStructure, decider: Asked().deciding(.writeAsWritten))
        let plain = try walk(content, decider: Asked().deciding(.writeAsWritten))

        XCTAssertEqual(pageLabels(of: structured), ["13"])
        XCTAssertEqual(
            paragraphs(of: structured), [writtenLine(levels: limit + 1, words: "so (or so); then left.")]
        )
        XCTAssertEqual(paragraphs(of: plain), paragraphs(of: structured))
        // The page is a run of its own in the paragraph, at its place.
        let runs = structured.blocks.compactMap { block -> [ExportRun]? in
            if case let .paragraph(runs) = block { return runs }
            return nil
        }.first ?? []
        XCTAssertEqual(runs.map(\.text), [writtenLine(levels: limit + 1, words: "so (or so);"), "", " then left."])
    }

    /// A marker after the last line's words, the continuation of a paragraph the
    /// converters write at the end of the line before, keeps its page, with
    /// the line break between the words.
    func testAMarkerAtALinesEndKeepsTheLineBreak() throws {
        var content = String(repeating: "> ", count: limit + 1) + MarkdownLiteral.escaped("first line")
        MarkdownMarkerWriter.write(MarkdownMarkers.page("14"), inline: true, into: &content)
        content += "\n" + String(repeating: "> ", count: limit + 1) + MarkdownLiteral.escaped("second line")

        let document = try walk(content, options: .bookStructure, decider: Asked().deciding(.writeAsWritten))

        XCTAssertEqual(pageLabels(of: document), ["14"])
        XCTAssertEqual(
            paragraphs(of: document),
            [writtenLine(levels: limit + 1, words: "first line") + "\n" + writtenLine(levels: limit + 1, words: "second line")]
        )
    }

    /// A marker on a line of its own, or that begins a block, is a place between
    /// blocks, as the markers that lead an HTML block are; the page ids are
    /// the walk's own, in order.
    func testMarkersThatBeginABlockArePlacesBetweenBlocks() throws {
        let deep = DeepMarkdown.quotes(limit + 1)
        let chapter = "\(marker("Notes"))\n\(MarkdownMarkers.page("7"))\n\n\(deep)\n\n"
            + "\(MarkdownMarkers.page("8")) words after the marker\n"

        let structured = try walk(chapter, options: .bookStructure, decider: Asked().deciding(.writeAsWritten))
        let plain = try walk(chapter, decider: Asked().deciding(.writeAsWritten))

        let expected = [String(repeating: "> ", count: limit + 1) + "Quoted words", "words after the marker"]
        XCTAssertEqual(structured.blocks.compactMap { block -> String? in
            if case let .pageBreak(page) = block { return "\(page.label) \(page.id)" }
            return nil
        }, ["7 page_1", "8 page_2"])
        XCTAssertEqual(paragraphs(of: structured), expected)
        XCTAssertEqual(paragraphs(of: plain), expected)
        XCTAssertEqual(headings(of: plain), ["Notes"])
        XCTAssertEqual(pageLabels(of: plain), [])
    }

    /// A comment that is not one of TextMouth's markers stays as the book's
    /// words, whole, and so does one an escape made text.
    func testACommentThatIsNoMarkerStaysText() throws {
        let content = DeepMarkdown.quotes(limit + 1) + " <!-- a note: -- -->, then \\<!-- page: 9 -->"

        let document = try walk(content, options: .bookStructure, decider: Asked().deciding(.writeAsWritten))

        XCTAssertEqual(pageLabels(of: document), [])
        XCTAssertEqual(
            paragraphs(of: document),
            [DeepMarkdown.quotes(limit + 1) + " <!-- a note: -- -->, then <!-- page: 9 -->"]
        )
    }

    /// A deep rest of a marker line is refused part of the way through a walk,
    /// after the marker's page was numbered: written as written, the page keeps
    /// the first number, not the second, and the paragraph is the whole line.
    func testAnAbandonedWalkLeavesNoPageNumberUsed() throws {
        let deep = DeepMarkdown.quotes(limit + 1)
        let chapter = "\(marker("Notes"))\n\(MarkdownMarkers.page("1"))\(deep)\n"

        let document = try walk(chapter, options: .bookStructure, decider: Asked().deciding(.writeAsWritten))

        let pages = document.blocks.compactMap { block -> ExportPageBreak? in
            if case let .pageBreak(page) = block { return page }
            return nil
        }
        XCTAssertEqual(pages, [ExportPageBreak(label: "1", id: "page_1")])
        XCTAssertEqual(paragraphs(of: document), [String(repeating: "> ", count: limit + 1) + "Quoted words"])
    }

    /// A hard-wrapped book keeps one paragraph for each block of lines, with
    /// the line breaks where its lines end, rather than a paragraph to a line.
    func testABlocksLinesAreOneParagraph() {
        let paragraphs = RawChapterLines.paragraphs(of: "one\ntwo  \n\n\n  three\r\nfour\n")
        let texts = paragraphs.map { paragraph in
            paragraph.pieces.map { piece -> String in
                if case let .words(text) = piece { return text }
                return "<marker>"
            }.joined()
        }
        XCTAssertEqual(texts, ["one\ntwo", "three\nfour"])
    }

    // MARK: - The questioner

    /// A questioner whose person answers from `answers`, in order, and records
    /// each question.
    private func makeQuestioner(
        answers: [ExportDeepChapterAnswer],
        into questions: OSAllocatedUnfairLock<[ExportDeepChapterQuestion]>
    ) -> ExportDeepChapterQuestioner {
        let remaining = OSAllocatedUnfairLock(initialState: answers)
        return ExportDeepChapterQuestioner { question in
            questions.withLock { $0.append(question) }
            // Cancelling is what a script that ran out of answers says.
            return remaining.withLock { queue -> ExportDeepChapterAnswer in
                queue.isEmpty ? .cancelExport : queue.removeFirst()
            }
        }
    }

    /// The question names the book, the chapter, and the limit, and offers
    /// the same for every such chapter only when more chapters follow in the
    /// text, or more text files remain to be walked: not for the last chapter
    /// of the last file.
    func testTheQuestionOffersEveryChapterOnlyWhenMoreMayFollow() {
        let book = BookExportBookName(id: UUID(), title: "Deep Notes")
        let questions = OSAllocatedUnfairLock<[ExportDeepChapterQuestion]>(initialState: [])
        let questioner = makeQuestioner(
            answers: [.exportAsWritten, .exportAsWritten, .exportAsWritten, .exportAsWritten], into: questions
        )

        _ = questioner.decide(ExportDeepChapter(number: 2, limit: 128, chaptersAfter: 0), in: book, filesAfter: 0)
        _ = questioner.decide(ExportDeepChapter(number: 2, limit: 128, chaptersAfter: 3), in: book, filesAfter: 0)
        _ = questioner.decide(ExportDeepChapter(number: nil, limit: 128, chaptersAfter: 0), in: book, filesAfter: 1)
        _ = questioner.decider(for: book, filesAfter: 0)(ExportDeepChapter(number: 1, limit: 128, chaptersAfter: 0))

        XCTAssertEqual(
            questions.withLock { $0 },
            [
                ExportDeepChapterQuestion(bookTitle: "Deep Notes", chapter: 2, limit: 128, offersEveryOne: false),
                ExportDeepChapterQuestion(bookTitle: "Deep Notes", chapter: 2, limit: 128, offersEveryOne: true),
                ExportDeepChapterQuestion(bookTitle: "Deep Notes", chapter: nil, limit: 128, offersEveryOne: true),
                ExportDeepChapterQuestion(bookTitle: "Deep Notes", chapter: 1, limit: 128, offersEveryOne: false),
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

        let one = makeQuestioner(answers: [.exportAsWritten, .cancelExport], into: questions)
        XCTAssertEqual(one.decide(chapter, in: first, filesAfter: 1), .writeAsWritten)
        XCTAssertEqual(one.decide(chapter, in: second, filesAfter: 0), .cancel)
        XCTAssertEqual(questions.withLock { $0.count }, 2, "each chapter is asked until the person says otherwise")

        let everyOne = makeQuestioner(answers: [.exportEveryOneAsWritten], into: questions)
        XCTAssertEqual(everyOne.decider(for: first, filesAfter: 2)(chapter), .writeAsWritten)
        XCTAssertEqual(everyOne.decider(for: second, filesAfter: 1)(chapter), .writeAsWritten)
        XCTAssertEqual(everyOne.decider(for: second, filesAfter: 0)(chapter), .writeAsWritten)
        XCTAssertEqual(questions.withLock { $0.count }, 3, "only the first of the three was asked")

        // A new questioner, as a new export makes, asks again.
        let another = makeQuestioner(answers: [.exportAsWritten], into: questions)
        XCTAssertEqual(another.decide(chapter, in: first, filesAfter: 1), .writeAsWritten)
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
            "Chapter 2 of Deep Notes nests quotes, lists, or emphasis more than 128 levels deep, which "
                + "TextMouth can't export with its structure. Export as Written writes that chapter as plain "
                + "paragraphs of its lines, with its quote and list marks kept as characters, and exports "
                + "everything else as usual. Cancel Export stops the whole export. Files already written "
                + "stay."
        )

        let several = ExportDeepChapterQuestion(bookTitle: "Deep Notes", chapter: 2, limit: 128, offersEveryOne: true)
        XCTAssertEqual(
            BookExportDeepChapterWording.message(for: several),
            "Chapter 2 of Deep Notes nests quotes, lists, or emphasis more than 128 levels deep, which "
                + "TextMouth can't export with its structure. Export as Written writes that chapter as plain "
                + "paragraphs of its lines, with its quote and list marks kept as characters, and exports "
                + "everything else as usual. Export Every Such Chapter as Written does the same for every "
                + "such chapter of this export, without asking again. Cancel Export stops the whole export. "
                + "Files already written stay."
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
            "Writes this and every other too-deeply nested chapter of this export as plain paragraphs of "
                + "lines, without asking again."
        )
        XCTAssertEqual(
            BookExportDeepChapterWording.cancelHint,
            "Stops the whole export. Files already written stay."
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

// MARK: - Test Support

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
