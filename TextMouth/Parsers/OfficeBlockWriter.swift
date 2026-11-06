import Foundation

// MARK: - Writing the Blocks of an Office Document

/// Gathers what the reader of an OpenDocument text (FMT27) or a Word 2003
/// XML document (FMT53) finds, in reading order, into the blocks
/// `RTFHTMLWriter` writes: headings, paragraphs, list items, and tables,
/// with the pages. It knows nothing of either format's markup; the readers
/// tell it what the document says.
///
/// The paragraphs of a document are kept in `OfficeFlow`s: one for the main
/// text, one for the notes that follow it. A paragraph is held until it ends,
/// so that one that turns out to be hidden is dropped whole, and a block that
/// begins inside a paragraph (a text box holds paragraphs of its own) writes
/// out the words before it first, so that the words stay in order.
///
/// It reuses the rich-text reader's block builder (`RTFBlockBuilder`) for the
/// words, the pages, the cells of a table, and the budget that stops a
/// hostile file from making the result large, and its guess at headings by
/// size (`RTFSizeHeadings`).
final class OfficeBlockWriter {
    /// Whether the pages are marked.
    private let includesPages: Bool

    /// The most bytes of text the document may hold, and how many have been
    /// read (`text:s` with a count of a billion, say).
    private let limit: Int64
    private var spent: Int64 = 0

    /// The main text, the notes, and the one being read now.
    private let main: OfficeFlow
    private let notes: OfficeFlow
    private(set) var flow: OfficeFlow
    /// How many notes' bodies are open.
    private var noteDepth = 0

    /// Whether a page begins at the next letter or digit, and whether a
    /// letter or digit has been read at all (a break before any words begins
    /// no page: the document's first page is page 1 already).
    private var pagePending = false
    private var hasCountedText = false

    /// Whether any paragraph is a heading by its style or its outline level.
    private var hasHeadings = false

    init(includesPages: Bool, limit: Int64) {
        self.includesPages = includesPages
        self.limit = limit
        main = OfficeFlow(includesPages: includesPages, limit: limit)
        notes = OfficeFlow(includesPages: false, limit: limit)
        flow = main
    }

    // MARK: The result

    /// The document that was read: the blocks, and how many page breaks the
    /// body holds. A document that names no heading keeps the headings
    /// textutil's reading finds by size, as the rich-text reader does; the
    /// notes follow the body.
    /// - Throws: `DocumentTooLargeError`.
    func finish() throws -> (blocks: [RTFBlock], pageBreaks: Int) {
        var blocks = try main.builder.finish(lastParagraph: .body, inTable: false)
        if !hasHeadings { blocks = RTFSizeHeadings.apply(to: blocks) }
        blocks += try notes.builder.finish(lastParagraph: .body, inTable: false)
        return (blocks, main.builder.pageBreaks)
    }

    // MARK: Words

    /// Spends `bytes` of the budget.
    /// - Throws: `DocumentTooLargeError` when it is gone.
    private func charge(_ bytes: Int) throws {
        spent += Int64(bytes)
        if spent > limit { throw DocumentTooLargeError(limit: limit) }
    }

    /// Adds characters of OpenDocument's markup to the paragraph open, with
    /// white space read as OpenDocument reads it (`OfficeOpenParagraph`).
    /// Characters outside a paragraph are not words.
    /// - Throws: `DocumentTooLargeError`.
    func addMarkupCharacters(_ characters: String) throws {
        guard let last = flow.paragraphs.indices.last else { return }
        try charge(flow.paragraphs[last].addCharacters(characters))
    }

    /// Adds words that stand as they are to the paragraph open: spaces and
    /// tabs the file asks for, and Word 2003 XML's text.
    /// - Throws: `DocumentTooLargeError`.
    func addLiteral(_ text: String) throws {
        guard let last = flow.paragraphs.indices.last else { return }
        try charge(text.utf8.count)
        flow.paragraphs[last].addExplicit(text)
    }

    /// A line break inside the paragraph open.
    func addLineBreak() {
        if let last = flow.paragraphs.indices.last { flow.paragraphs[last].addLineBreak() }
    }

    /// A span or link begins: its text has the look `run`.
    func beginSpan(_ run: OfficeRun) {
        if let last = flow.paragraphs.indices.last { flow.paragraphs[last].beginSpan(run) }
    }

    /// The span or link begun last ends.
    func endSpan() {
        if let last = flow.paragraphs.indices.last { flow.paragraphs[last].endSpan() }
    }

    /// The look of the text in the paragraph open now, or nil outside one.
    var currentRun: OfficeRun? {
        flow.paragraphs.last?.run
    }

    /// Hides the paragraph open: it is dropped whole when it ends.
    func hideParagraph() {
        if let last = flow.paragraphs.indices.last { flow.paragraphs[last].isHidden = true }
    }

    // MARK: Paragraphs

    /// A paragraph begins. Any words of a paragraph around it are written out
    /// first.
    /// - Parameters:
    ///   - kind: what the paragraph becomes when it ends.
    ///   - run: the look of its text.
    ///   - startsPage: whether a page begins before it.
    ///   - startsPageAfter: whether a page begins after it.
    /// - Throws: `DocumentTooLargeError`.
    func beginParagraph(
        kind: RTFBlockBuilder.Kind,
        run: OfficeRun,
        startsPage: Bool = false,
        startsPageAfter: Bool = false
    ) throws {
        try writeOutOpenParagraph()
        if case .heading = kind { hasHeadings = true }
        var paragraph = OfficeOpenParagraph(kind: kind, run: run)
        paragraph.startsPageAfter = startsPageAfter
        if startsPage { paragraph.addPageStart() }
        flow.paragraphs.append(paragraph)
    }

    /// The paragraph open ends: it is written out.
    /// - Parameter bulletCharacters: when given, a paragraph of text that
    ///   begins with one of them and white space is a bullet item, the
    ///   bullet left out (how a writer without lists marks an item).
    /// - Throws: `DocumentTooLargeError`.
    func endParagraph(bulletCharacters: Set<Character>? = nil) throws {
        guard var paragraph = flow.paragraphs.popLast() else { return }
        if let bullets = bulletCharacters, paragraph.kind == .body, paragraph.removeLeadingBullet(from: bullets) {
            paragraph.kind = .listItem(level: 0, numbered: false)
        }
        try write(&paragraph, atEnd: true)
    }

    /// Writes out the words of the paragraph open at the innermost level and
    /// goes on with the rest of it as a paragraph of text, for a block that
    /// begins inside a paragraph.
    /// - Throws: `DocumentTooLargeError`.
    func writeOutOpenParagraph() throws {
        guard let last = flow.paragraphs.indices.last else { return }
        var paragraph = flow.paragraphs[last]
        try write(&paragraph, atEnd: false)
        flow.paragraphs[last] = paragraph
    }

    /// Writes `paragraph`'s pieces into the builder, and ends the
    /// paragraph there.
    /// - Parameter atEnd: whether the paragraph itself ended; its break
    ///   after it is written then, and not for a paragraph that goes on.
    private func write(_ paragraph: inout OfficeOpenParagraph, atEnd: Bool) throws {
        defer { paragraph.pieces = [] }
        // A hidden paragraph leaves nothing, not even its pages.
        guard !paragraph.isHidden else { return }
        for piece in paragraph.pieces {
            switch piece {
            case .text(let words, let run):
                let isCounted = words.unicodeScalars.contains(where: TextutilPageBreaks.isCounted)
                // The page that waits begins at the first letter or digit.
                if isCounted, pagePending, flow === main {
                    flow.builder.addPageBreak()
                    pagePending = false
                }
                try flow.builder.appendText(words, bold: run.bold, italic: run.italic, size: run.size)
                if isCounted, flow === main { hasCountedText = true }
            case .lineBreak:
                flow.builder.appendLineBreak()
            case .pageStart:
                beginPage()
            }
        }
        try flow.builder.finishParagraph(paragraph.kind, inTable: flow.tableDepth > 0)
        // What remains of a paragraph that goes on is plain text.
        paragraph.kind = .body
        if atEnd, paragraph.startsPageAfter { beginPage() }
    }

    // MARK: Pages

    /// A page break: where a layout last put a page, or a hard break. Inside
    /// a paragraph it is held with the paragraph's words until the paragraph
    /// ends, so that one that turns out to be hidden begins no page.
    func pageBreak() {
        if let last = flow.paragraphs.indices.last {
            flow.paragraphs[last].addPageStart()
        } else {
            beginPage()
        }
    }

    /// A page begins at the next letter or digit, as the pages of textutil's
    /// reading do, if a letter or digit has been read (the first page is
    /// page 1 already), pages are wanted, and the main text, not the notes
    /// that follow it, is being read. Breaks that meet before a letter or
    /// digit begin one page.
    func beginPage() {
        guard includesPages, flow === main, hasCountedText else { return }
        pagePending = true
    }

    // MARK: Tables

    /// A table begins; one inside a cell is read into the cell around it.
    /// - Throws: `DocumentTooLargeError`.
    func beginTable(startsPage: Bool, startsPageAfter: Bool) throws {
        try writeOutOpenParagraph()
        if flow.tableDepth == 0, startsPage { beginPage() }
        flow.tableDepth += 1
        flow.tablesStartPageAfter.append(startsPageAfter)
    }

    /// A table ends. The outermost one is closed in the builder by a
    /// paragraph that holds nothing, which also keeps the table from joining
    /// one that follows it.
    /// - Throws: `DocumentTooLargeError`.
    func endTable() throws {
        guard flow.tableDepth > 0 else { return }
        flow.tableDepth -= 1
        let startsPageAfter = flow.tablesStartPageAfter.popLast() ?? false
        guard flow.tableDepth == 0 else { return }
        try flow.builder.finishParagraph(.body, inTable: false)
        if startsPageAfter { beginPage() }
    }

    /// A row of the outermost table ends; a row of a table in a cell is part
    /// of the cell around it.
    /// - Throws: `DocumentTooLargeError`.
    func endRow() throws {
        if flow.tableDepth == 1 { try flow.builder.endRow() }
    }

    /// A cell of the outermost table ends.
    /// - Throws: `DocumentTooLargeError`.
    func endCell() throws {
        if flow.tableDepth == 1 { try flow.builder.endCell() }
    }

    // MARK: Notes

    /// The body of a note begins: its paragraphs follow the main text, and
    /// are not paged.
    func beginNote() {
        noteDepth += 1
        if noteDepth == 1 { flow = notes }
    }

    /// The body of a note ends.
    func endNote() {
        noteDepth = max(noteDepth - 1, 0)
        if noteDepth == 0 { flow = main }
    }

    // MARK: Text boxes

    /// A text box begins: it starts lists of its own.
    func beginTextBox() {
        flow.listsOutsideTextBoxes.append(flow.lists)
        flow.lists = []
    }

    /// A text box ends.
    func endTextBox() {
        if let outside = flow.listsOutsideTextBoxes.popLast() { flow.lists = outside }
    }
}
