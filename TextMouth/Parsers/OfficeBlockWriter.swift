import Foundation

// MARK: - Writing the Blocks of an Office Document

/// Gathers what the reader of an OpenDocument text (FMT27) or a Word 2003
/// XML document (FMT53) finds, in reading order, into the blocks
/// `RTFHTMLWriter` writes: headings, paragraphs, list items, and tables,
/// with the pages. It knows nothing of either format's markup; the readers
/// tell it what the document says.
///
/// The paragraphs of a document are kept in `OfficeFlow`s: one for the main
/// text, and one for each note, which follows the main text. A paragraph is
/// held until it ends, so that one that turns out to be hidden is dropped
/// whole. What is anchored in a paragraph (the paragraphs and tables of a
/// text box or shape, a picture's description) and the notes whose
/// references it holds wait with the paragraph and are written right after
/// it, in file order, and not at all if the paragraph is hidden.
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

    /// The main text, and the one being read now: the main text, or the body
    /// of a note.
    private let main: OfficeFlow
    private(set) var flow: OfficeFlow
    /// The flows the open notes are inside, innermost last.
    private var flowsOutsideNotes: [OfficeFlow] = []

    /// How many pages wait to begin at the next letter or digit. Two breaks
    /// with nothing between them are one page; a paragraph between them
    /// (even an empty one) is a page of its own.
    private var pendingBreaks = 0
    /// Whether a paragraph was written since the page that waits was asked for.
    private var paragraphSincePendingBreak = false
    /// Whether a letter or digit has been read in the main flow's own
    /// paragraphs (a hard break before any words begins no page: the
    /// document's first page is page 1 already). The words of text boxes and
    /// shapes anchored before them do not count: they are not the first page's
    /// text, and the text proper has not begun.
    private var hasCountedText = false
    /// How many paragraphs that hold what is anchored in another are being
    /// written (text boxes, shapes, and the descriptions of pictures).
    private var anchoredDepth = 0
    /// Whether the row of the table open has had its soft page break: the
    /// layout records one for each cell it breaks, and a row breaks once.
    private var rowHasSoftBreak = false

    /// Whether any paragraph is a heading by its style or its outline level.
    private var hasHeadings = false

    /// The most pages that can wait (a file cannot make a loop of them).
    private static let mostPendingBreaks = 1_000

    /// Prepares to gather the blocks of a document, with pages if
    /// `includesPages`, and no more than `limit` bytes of text.
    init(includesPages: Bool, limit: Int64) {
        self.includesPages = includesPages
        self.limit = limit
        main = OfficeFlow(includesPages: includesPages, limit: limit)
        flow = main
    }

    // MARK: The result

    /// The document that was read: the blocks, and how many page breaks the
    /// body holds. A document that names no heading keeps the headings
    /// textutil's reading finds by size, as the rich-text reader does; the
    /// notes follow the body, each followed by its own.
    /// - Throws: `DocumentTooLargeError`.
    func finish() throws -> (blocks: [RTFBlock], pageBreaks: Int) {
        var blocks = try main.builder.finish(lastParagraph: .body, inTable: false)
        if !hasHeadings { blocks = Self.withHeadingsBySize(blocks) }
        try appendNotes(of: main, to: &blocks)
        return (blocks, main.builder.pageBreaks)
    }

    /// `blocks` with the headings found by size, as the rich-text reader
    /// finds them, but without the descriptions of pictures: those are not
    /// the document's text, so they are neither counted in the body size nor
    /// ever a heading. (The guess ignores a paragraph with no words, so the
    /// descriptions are emptied for it and the original paragraphs put back.)
    private static func withHeadingsBySize(_ blocks: [RTFBlock]) -> [RTFBlock] {
        let emptied = blocks.map { block -> RTFBlock in
            switch block {
            case .paragraph(let paragraph): return .paragraph(withoutDescription(paragraph))
            case .heading(let paragraph, let level): return .heading(withoutDescription(paragraph), level: level)
            case .listItem(let paragraph, let level, let numbered):
                return .listItem(withoutDescription(paragraph), level: level, numbered: numbered)
            case .table(var table):
                table.rows = table.rows.map { $0.map { $0.map(withoutDescription) } }
                return .table(table)
            }
        }
        let guessed = RTFSizeHeadings.apply(to: emptied)
        // A paragraph the guess made a heading, with its own words back.
        return zip(blocks, guessed).map { original, found in
            guard case .paragraph(let paragraph) = original, case .heading(_, let level) = found else { return original }
            return .heading(paragraph, level: level)
        }
    }

    /// `paragraph`, or an empty one if it is a description.
    private static func withoutDescription(_ paragraph: RTFParagraph) -> RTFParagraph {
        let isDescription = paragraph.inlines.contains { inline in
            if case .text(_, _, _, let size) = inline { return size == OfficeRun.descriptionSize }
            return false
        }
        return isDescription ? RTFParagraph() : paragraph
    }

    /// Appends the blocks of the notes of `flow`, each followed by the notes
    /// of its own.
    private func appendNotes(of flow: OfficeFlow, to blocks: inout [RTFBlock]) throws {
        for note in flow.committedNotes {
            blocks += try note.builder.finish(lastParagraph: .body, inTable: false)
            try appendNotes(of: note, to: &blocks)
        }
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

    /// Notes that hidden text was left out of the paragraph open: if it then
    /// holds no words, it begins no page.
    func markHiddenText() {
        if let last = flow.paragraphs.indices.last { flow.paragraphs[last].hasHiddenText = true }
    }

    /// A `text:hidden-paragraph` field in the paragraph open, hiding it or
    /// not: the paragraph is hidden when it holds some and all of them hide it.
    func noteHiddenParagraphField(isHiding: Bool) {
        guard let last = flow.paragraphs.indices.last else { return }
        if isHiding {
            flow.paragraphs[last].hidingFields += 1
        } else {
            flow.paragraphs[last].shownFields += 1
        }
    }

    // MARK: Paragraphs

    /// A paragraph begins. One that begins inside a paragraph (a text box or
    /// a shape anchored in it) waits until the paragraph around it is
    /// written.
    /// - Parameters:
    ///   - kind: what the paragraph becomes when it ends.
    ///   - run: the look of its text.
    ///   - startsPage: whether a page begins before it.
    ///   - startsPageAfter: whether a page begins after it. Neither counts
    ///     in a table or inside another paragraph: a page cannot begin there.
    ///   - isHiddenByStyle: whether its style hides its text; it is then
    ///     dropped unless some of its words are shown again.
    func beginParagraph(
        kind: RTFBlockBuilder.Kind,
        run: OfficeRun,
        startsPage: Bool = false,
        startsPageAfter: Bool = false,
        isHiddenByStyle: Bool = false
    ) {
        let allowsPages = flow.tableDepth == 0 && flow.paragraphs.isEmpty
        var paragraph = OfficeOpenParagraph(kind: kind, run: run)
        paragraph.startsPageAfter = startsPageAfter && allowsPages
        paragraph.isHiddenByStyle = isHiddenByStyle
        if startsPage, allowsPages { paragraph.addPageStart() }
        flow.paragraphs.append(paragraph)
    }

    /// The paragraph open ends: it is written out, or, if it is inside
    /// another, kept with that one.
    /// - Parameter bulletCharacters: when given, a paragraph of text that
    ///   begins with one of them and a tab is a bullet item, the bullet left
    ///   out (how a writer without lists marks an item).
    /// - Throws: `DocumentTooLargeError`.
    func endParagraph(bulletCharacters: Set<Character>? = nil) throws {
        guard var paragraph = flow.paragraphs.popLast() else { return }
        if let bullets = bulletCharacters, paragraph.kind == .body, paragraph.removeLeadingBullet(from: bullets) {
            paragraph.kind = .listItem(level: 0, numbered: false)
        }
        if let outer = flow.paragraphs.indices.last {
            // The notes it holds come in file order among the outer's.
            if !paragraph.isHidden { flow.paragraphs[outer].notes += paragraph.notes }
            paragraph.notes = []
            flow.paragraphs[outer].deferred.append(.paragraph(paragraph))
            return
        }
        try write(&paragraph, atEnd: true)
    }

    /// Writes `paragraph`'s pieces into the builder, and ends the paragraph
    /// there; then what waited with it.
    /// - Parameter atEnd: whether the paragraph itself ended; its break
    ///   after it is written then.
    private func write(_ paragraph: inout OfficeOpenParagraph, atEnd: Bool) throws {
        defer {
            paragraph.pieces = []
            paragraph.notes = []
            paragraph.deferred = []
        }
        let hasWords = paragraph.hasWords
        // A hidden paragraph leaves nothing, not even its pages, its notes,
        // or what is anchored in it; so does one whose style hides its text
        // and whose spans show none.
        guard !paragraph.isHidden, !(paragraph.isHiddenByStyle && !hasWords) else { return }
        // A paragraph whose every word is hidden begins no page.
        let isWordless = !hasWords && (paragraph.hasHiddenText || paragraph.isHiddenByStyle)
        if isWordless {
            paragraph.pieces.removeAll { if case .text = $0 { return false } else if case .lineBreak = $0 { return false } else { return true } }
            paragraph.startsPageAfter = false
        }
        try record(paragraph)
        for piece in paragraph.pieces {
            switch piece {
            case .text(let words, let run):
                let isCounted = words.unicodeScalars.contains(where: TextutilPageBreaks.isCounted)
                // The pages that wait begin at the first letter or digit.
                if isCounted, pendingBreaks > 0, flow === main {
                    for _ in 0..<pendingBreaks { flow.builder.addPageBreak() }
                    pendingBreaks = 0
                }
                try flow.builder.appendText(words, bold: run.bold, italic: run.italic, size: run.size)
                if isCounted, flow === main, anchoredDepth == 0 { hasCountedText = true }
            case .lineBreak:
                flow.builder.appendLineBreak()
            case .pageStart:
                beginPage()
            case .softPageStart:
                beginPage(requiresText: false)
            }
        }
        try flow.builder.finishParagraph(paragraph.kind, inTable: flow.tableDepth > 0)
        // Only a heading with words is a heading: one whose words are all
        // hidden writes none, and does not turn off the guess at headings.
        if hasWords, flow.tableDepth == 0, flow === main, case .heading = paragraph.kind { hasHeadings = true }
        // The notes of a paragraph that is read are read, after the text.
        flow.committedNotes += paragraph.notes
        if !isWordless { paragraphSincePendingBreak = true }
        if atEnd, paragraph.startsPageAfter { beginPage() }
        // What is anchored in the paragraph follows it, in order.
        anchoredDepth += 1
        defer { anchoredDepth -= 1 }
        for item in paragraph.deferred { try run(item) }
    }

    /// Keeps a copy of `paragraph` for each repeat of the cell open, when a
    /// file repeats it (`table:number-columns-repeated`).
    private func record(_ paragraph: OfficeOpenParagraph) throws {
        guard flow.tableDepth == 1, flow.repeatedCell != nil else { return }
        var copy = paragraph
        // The notes would be read once more, and what is anchored in it was
        // written with it.
        copy.notes = []
        copy.deferred = []
        flow.repeatedCell?.paragraphs.append(copy)
    }

    /// Writes what waited with a paragraph.
    private func run(_ item: OfficeDeferred) throws {
        switch item {
        case .paragraph(var paragraph):
            try write(&paragraph, atEnd: true)
        case .beginTable(let startsPage, let startsPageAfter):
            if flow.tableDepth == 0, startsPage { beginPage() }
            flow.tableDepth += 1
            flow.tablesStartPageAfter.append(startsPageAfter)
        case .beginCell(let repeated):
            // A cell is repeated when a file asks, up to a limit.
            if flow.tableDepth == 1, repeated > 1 {
                flow.repeatedCell = (min(repeated, Self.mostRepeatedCells), [])
            }
        case .endCell:
            if flow.tableDepth == 1 {
                let repeated = flow.repeatedCell
                flow.repeatedCell = nil
                try flow.builder.endCell()
                if let repeated {
                    for _ in 1..<repeated.times {
                        for var again in repeated.paragraphs { try write(&again, atEnd: true) }
                        try flow.builder.endCell()
                    }
                }
            }
        case .endRow:
            if flow.tableDepth == 1 { try flow.builder.endRow() }
            rowHasSoftBreak = false
        case .endTable:
            guard flow.tableDepth > 0 else { return }
            flow.tableDepth -= 1
            let startsPageAfter = flow.tablesStartPageAfter.popLast() ?? false
            guard flow.tableDepth == 0 else { return }
            // The outermost table is closed in the builder by a paragraph that
            // holds nothing, which also keeps it from joining one that follows.
            try flow.builder.finishParagraph(.body, inTable: false)
            if startsPageAfter { beginPage() }
        }
    }

    /// The most times a repeated cell is read.
    private static let mostRepeatedCells = 16

    // MARK: Pages

    /// A hard page break (`w:br`): inside a paragraph it is held with the
    /// paragraph's words until the paragraph ends, so that one that turns out
    /// to be hidden begins no page, and it keeps touching words apart.
    func hardPageBreak() {
        if let last = flow.paragraphs.indices.last {
            flow.paragraphs[last].addPageStart()
        } else {
            beginPage()
        }
    }

    /// A `text:soft-page-break`: where the layout last put a page. A row of a
    /// table has one, however many of its cells the layout broke. It begins a
    /// page even before the first words, and adds no space to the words.
    func softPageBreak() {
        if flow.tableDepth > 0 {
            guard !rowHasSoftBreak else { return }
            rowHasSoftBreak = true
        }
        if let last = flow.paragraphs.indices.last {
            flow.paragraphs[last].addPageStart(soft: true)
        } else {
            beginPage(requiresText: false)
        }
    }

    /// A page begins at the next letter or digit, as the pages of textutil's
    /// reading do, if pages are wanted and the main text, not the notes that
    /// follow it, is being read. A hard break before any letter or digit
    /// begins none (the first page is page 1 already). Breaks with no
    /// paragraph between them are one page.
    func beginPage(requiresText: Bool = true) {
        guard includesPages, flow === main, !requiresText || hasCountedText else { return }
        if pendingBreaks > 0, !paragraphSincePendingBreak { return }
        pendingBreaks = min(pendingBreaks + 1, Self.mostPendingBreaks)
        paragraphSincePendingBreak = false
    }

    // MARK: Tables

    /// A table begins; one inside a cell is read into the cell around it,
    /// and one inside a paragraph (in a text box) waits for it. Its style's
    /// page breaks count only for a table outside a table and a paragraph.
    /// - Throws: `DocumentTooLargeError`.
    func beginTable(startsPage: Bool, startsPageAfter: Bool) throws {
        let allowsPages = flow.tableDepth == 0 && flow.paragraphs.isEmpty
        try perform(.beginTable(startsPage: startsPage && allowsPages, startsPageAfter: startsPageAfter && allowsPages))
    }

    /// A cell begins, which a file may ask to read `repeated` times.
    /// - Throws: `DocumentTooLargeError`.
    func beginCell(repeated: Int = 1) throws {
        try perform(.beginCell(repeated: repeated))
    }

    /// A cell ends.
    /// - Throws: `DocumentTooLargeError`.
    func endCell() throws {
        try perform(.endCell)
    }

    /// A row ends.
    /// - Throws: `DocumentTooLargeError`.
    func endRow() throws {
        try perform(.endRow)
    }

    /// A table ends.
    /// - Throws: `DocumentTooLargeError`.
    func endTable() throws {
        try perform(.endTable)
    }

    /// Does `item` now, or keeps it with the paragraph open, which it is
    /// anchored in.
    private func perform(_ item: OfficeDeferred) throws {
        if let outer = flow.paragraphs.indices.last {
            flow.paragraphs[outer].deferred.append(item)
        } else {
            try run(item)
        }
    }

    // MARK: Notes

    /// The body of a note begins: its paragraphs follow the main text, are
    /// not paged, and are read only if the paragraph that holds its
    /// reference is read.
    func beginNote() {
        let note = OfficeFlow(includesPages: false, limit: limit)
        if let last = flow.paragraphs.indices.last {
            flow.paragraphs[last].notes.append(note)
        } else {
            flow.committedNotes.append(note)
        }
        flowsOutsideNotes.append(flow)
        flow = note
    }

    /// The body of a note ends.
    func endNote() {
        if let outside = flowsOutsideNotes.popLast() { flow = outside }
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
