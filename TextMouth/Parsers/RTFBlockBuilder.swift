import Foundation

// MARK: - Building the Body

/// Builds the body of a Rich Text Format document from what the
/// interpreter reads (FMT47): it gathers the words of a paragraph, places
/// the page breaks, groups the cells of a table, and keeps the budget that
/// stops a hostile file from making the result large.
///
/// It knows nothing of RTF's syntax; the interpreter tells it what the
/// document says in the document's order.
struct RTFBlockBuilder {

    // MARK: Kinds

    /// What a finished paragraph is, as the interpreter decides it from the
    /// paragraph's style, outline level, and list.
    enum Kind: Equatable {
        /// A paragraph of body text.
        case body
        /// A heading at this level, 1 to 6.
        case heading(Int)
        /// An item of a list, at this depth (0 is the outermost list).
        case listItem(RTFListPosition)
    }

    // MARK: State

    /// Whether page breaks are placed (the caller asked for pages).
    private let includesPages: Bool
    /// What is left to spend (bytes of text, plus an allowance for each run
    /// and paragraph): once it is gone the document is too large.
    private var budget: Int64
    /// The limit, for the error that names it.
    let limit: Int64
    /// What the budget was when this builder began, so that what it spent
    /// can be charged to the builder it works beside (`spentBytes`).
    private let startingBudget: Int64

    /// The finished blocks.
    private(set) var blocks: [RTFBlock] = []
    /// The paragraph being read, less its open run.
    private var paragraph = RTFParagraph()
    /// The run being written: text joins it, in place, while its style stays
    /// the same, so a paragraph built of many small pieces is not copied
    /// again with each. It is closed into the paragraph when anything else
    /// is added, and when the paragraph ends.
    private var openRun: (text: String, bold: Bool, italic: Bool, size: Int)?

    /// The table being read: its finished rows, the row's finished cells,
    /// and the paragraphs of the cell being read.
    private var table: RTFTable?
    private var row: [[RTFParagraph]] = []
    private var cell: [RTFParagraph] = []

    // MARK: Pages

    /// How many page breaks the document holds. Breaks with no word after
    /// them count: a document with too many has no pages at all.
    private(set) var pageBreaks = 0
    /// The breaks waiting for the next letter or digit, where their pages
    /// begin.
    private var pendingBreaks = 0
    /// The number of the page most recently begun; page 1 begins at the
    /// start of the body.
    private var pageNumber = 1
    /// Whether a `\sect` has been read and the first text of the section it
    /// begins has not.
    private var sectionBreakPending = false
    /// Whether the section being begun starts a page: `\sbkpage` (the
    /// default, restored by `\sectd`), `\sbkeven`, and `\sbkodd` do;
    /// `\sbknone` and `\sbkcol` do not.
    private var sectionStartsPage = true
    /// Whether the paragraph being read already counted its `\pagebb`.
    private var paragraphBreakCounted = false
    /// Whether the paragraph being read began a page by its `\pagebb` (or its
    /// style's), and whether words were left out of it because they are not
    /// read (hidden or deleted). A paragraph that held only such words
    /// begins no page.
    private var paragraphBreakAdded = false
    private var paragraphHadUnreadWords = false

    /// Whether the document has had a letter or a digit yet. A paragraph
    /// that begins a page (`\pagebb`, or a style with it) before any words
    /// begins the document's first page, which is page 1 already: Word's
    /// chapter styles all begin a page, and the first chapter must not make
    /// a blank page of its own. (A hard `\page` or `\sect` at the start does,
    /// as it does in Word and in textutil's plain text.)
    private var hasCountedText = false

    /// The room a run or a paragraph is charged beyond its words.
    private static let runAllowance: Int64 = 16
    private static let paragraphAllowance: Int64 = 64

    /// A builder for the text of a document, or, with `budget`, for part of
    /// it (a note) that may spend no more than what is left of the whole.
    /// - Parameters:
    ///   - limit: the most text the whole document may make.
    ///   - budget: what is left of `limit` to spend; all of it by default.
    init(includesPages: Bool, limit: Int64, budget: Int64? = nil) {
        self.includesPages = includesPages
        self.limit = limit
        self.budget = budget ?? limit
        self.startingBudget = budget ?? limit
    }

    /// What is left of the budget.
    var remainingBudget: Int64 { budget }

    /// What this builder has spent since it began.
    var spentBytes: Int64 { startingBudget - budget }

    // MARK: Words

    /// Charges `bytes` to the budget.
    /// - Throws: `DocumentTooLargeError` when the budget is spent.
    mutating func spend(_ bytes: Int64) throws {
        budget -= bytes
        guard budget >= 0 else { throw DocumentTooLargeError(limit: limit) }
    }

    /// Adds `text` to the paragraph, in the given emphasis and size, with
    /// the page breaks that wait written right before its first letter or
    /// digit. Text that continues a run in the same style joins it.
    /// - Throws: `DocumentTooLargeError`.
    mutating func appendText(_ text: String, bold: Bool, italic: Bool, size: Int) throws {
        guard !text.isEmpty else { return }
        try spend(Int64(text.utf8.count) + Self.runAllowance)
        // A section break is settled by the first words after it, not by
        // white space.
        if text.contains(where: { !$0.isWhitespace }) { resolveSectionBreak() }
        var remaining = Substring(text)
        if pendingBreaks > 0, let split = firstCountedIndex(in: remaining) {
            // The text before the first letter or digit, then the pages
            // that begin there, then the rest.
            let before = remaining[..<split]
            if !before.isEmpty { add(String(before), bold: bold, italic: italic, size: size) }
            closeRun()
            for _ in 0..<pendingBreaks {
                pageNumber += 1
                paragraph.inlines.append(.pageBreak(pageNumber))
            }
            pendingBreaks = 0
            remaining = remaining[split...]
        }
        add(String(remaining), bold: bold, italic: italic, size: size)
        if !hasCountedText { hasCountedText = text.unicodeScalars.contains(where: TextutilPageBreaks.isCounted) }
    }

    /// The index of the first letter or digit in `text`, or nil.
    private func firstCountedIndex(in text: Substring) -> Substring.Index? {
        var index = text.unicodeScalars.startIndex
        while index < text.unicodeScalars.endIndex {
            if TextutilPageBreaks.isCounted(text.unicodeScalars[index]) { return index }
            index = text.unicodeScalars.index(after: index)
        }
        return nil
    }

    /// Appends text to the open run when its style is the same, and to a
    /// new run otherwise.
    private mutating func add(_ text: String, bold: Bool, italic: Bool, size: Int) {
        guard !text.isEmpty else { return }
        if let open = openRun, open.bold == bold, open.italic == italic, open.size == size {
            openRun?.text.append(text)
        } else {
            closeRun()
            openRun = (text, bold, italic, size)
        }
    }

    /// Moves the open run into the paragraph.
    private mutating func closeRun() {
        if let open = openRun {
            paragraph.inlines.append(.text(open.text, bold: open.bold, italic: open.italic, size: open.size))
            openRun = nil
        }
    }

    /// If the paragraph so far is a bullet character alone (the way writers
    /// that have no list write one: a bullet, a tab, and the item's words),
    /// takes it out of the paragraph and returns it; otherwise leaves the
    /// paragraph as it is and returns nil.
    /// - Parameter bullets: the characters that are bullets.
    mutating func takeBulletMark(from bullets: Set<Character>) -> String? {
        closeRun()
        guard paragraph.inlines.count == 1, case .text(let text, _, _, _) = paragraph.inlines[0] else { return nil }
        let mark = text.trimmingCharacters(in: .whitespaces)
        guard mark.count == 1, let character = mark.first, bullets.contains(character) else { return nil }
        paragraph = RTFParagraph()
        return mark
    }

    /// `\line`: a line break inside the paragraph.
    mutating func appendLineBreak() {
        closeRun()
        paragraph.inlines.append(.lineBreak)
    }

    // MARK: Page breaks

    /// A hard page break (`\page`): the next letter or digit begins a page.
    mutating func addPageBreak() {
        guard includesPages else { return }
        pageBreaks += 1
        pendingBreaks += 1
    }

    /// `\pagebb`, or a style with it: the paragraph begins a page, once.
    mutating func addParagraphPageBreak() {
        guard !paragraphBreakCounted else { return }
        paragraphBreakCounted = true
        if hasCountedText {
            addPageBreak()
            paragraphBreakAdded = includesPages
        }
    }

    /// Words of the paragraph were left out because they are not read.
    mutating func noteUnreadWords(_ text: String) {
        if text.contains(where: { !$0.isWhitespace }) { paragraphHadUnreadWords = true }
    }

    /// Takes back the page the paragraph that has ended began by its
    /// `\pagebb`, when every word it held was left out (`finished` is what it
    /// holds), and forgets what was noted of the paragraph.
    private mutating func settleParagraphBreak(of finished: RTFParagraph) {
        if paragraphBreakAdded && paragraphHadUnreadWords && !finished.hasWords && pendingBreaks > 0 {
            pendingBreaks -= 1
            pageBreaks -= 1
        }
        paragraphBreakAdded = false
        paragraphHadUnreadWords = false
    }

    /// Whether the paragraph being read holds a word so far.
    var currentParagraphHasWords: Bool {
        if paragraph.hasWords { return true }
        return openRun?.text.contains(where: { !$0.isWhitespace }) ?? false
    }

    /// `\sect`: a section ends. Whether the next one begins a page is known
    /// when its first words come (`\sbknone` and the rest come before them).
    mutating func beginSectionBreak() {
        sectionBreakPending = true
        sectionStartsPage = true
    }

    /// `\sectd` and `\sbk…`: whether the section being begun starts a page.
    mutating func setSectionStartsPage(_ startsPage: Bool) {
        sectionStartsPage = startsPage
    }

    /// Settles the section break that waits, now that the section has words.
    private mutating func resolveSectionBreak() {
        guard sectionBreakPending else { return }
        sectionBreakPending = false
        if sectionStartsPage { addPageBreak() }
    }

    // MARK: Paragraphs

    /// Ends the paragraph being read as `kind`. A paragraph with no words is
    /// dropped (but ends a table that is open, unless it is in the table).
    /// - Parameter inTable: whether the paragraph is part of a table cell.
    /// - Throws: `DocumentTooLargeError`.
    mutating func finishParagraph(_ kind: Kind, inTable: Bool) throws {
        closeRun()
        let finished = paragraph
        paragraph = RTFParagraph()
        paragraphBreakCounted = false
        settleParagraphBreak(of: finished)
        try spend(Self.paragraphAllowance)
        if inTable {
            if finished.hasWords { cell.append(Self.markingListItem(finished, as: kind)) }
            return
        }
        closeTable()
        guard finished.hasWords else { return }
        switch kind {
        case .body: blocks.append(.paragraph(finished))
        case .heading(let level): blocks.append(.heading(finished, level: level))
        case .listItem(let position): blocks.append(.listItem(finished, position))
        }
    }

    // MARK: Text boxes

    /// Adds the text of shapes' text boxes right after the paragraph or cell
    /// that has just ended and held their anchors: as blocks of the body, or as
    /// paragraphs of the cell (a cell holds paragraphs, not blocks).
    /// - Parameters:
    ///   - inTable: whether the paragraph that ended is in a table's cell.
    ///   - afterCell: whether a `\cell` ended it, so that the cell has been
    ///     closed into its row.
    mutating func appendBoxBlocks(_ boxes: [RTFBlock], inTable: Bool, afterCell: Bool) {
        guard inTable else {
            blocks.append(contentsOf: boxes)
            return
        }
        let paragraphs = RTFHTMLWriter.paragraphs(of: boxes).filter(\.hasWords)
        if afterCell, !row.isEmpty {
            row[row.count - 1].append(contentsOf: paragraphs)
        } else {
            cell.append(contentsOf: paragraphs)
        }
    }

    // MARK: Tables

    /// `paragraph` for a table's cell: when it is a list item, carrying its
    /// place in the list (a heading or body paragraph carries nothing).
    private static func markingListItem(_ paragraph: RTFParagraph, as kind: Kind) -> RTFParagraph {
        guard case .listItem(let position) = kind else { return paragraph }
        var marked = paragraph
        marked.listItem = position
        return marked
    }

    /// `\cell`: the cell ends. Its paragraph, if it holds words, is the
    /// cell's last.
    /// - Parameter kind: what that last paragraph is, which matters when it
    ///   is a list item: the cell then writes its number or bullet. A
    ///   paragraph that `\cell` ends has no `\par` of its own.
    /// - Throws: `DocumentTooLargeError`: every cell is charged to the budget,
    ///   empty or not.
    mutating func endCell(lastParagraph kind: Kind = .body) throws {
        // A cell costs what a paragraph does: it writes a `td`, and may write more
        try spend(Self.paragraphAllowance)
        closeRun()
        settleParagraphBreak(of: paragraph)
        if paragraph.hasWords { cell.append(Self.markingListItem(paragraph, as: kind)) }
        paragraph = RTFParagraph()
        paragraphBreakCounted = false
        row.append(cell)
        cell = []
        if table == nil { table = RTFTable() }
    }

    /// `\row`: the row ends.
    /// - Parameter kind: what the words not yet closed in a cell are.
    /// - Throws: `DocumentTooLargeError`.
    mutating func endRow(lastParagraph kind: Kind = .body) throws {
        // Words not yet closed in a cell are kept in one.
        closeRun()
        if paragraph.hasWords || !cell.isEmpty { try endCell(lastParagraph: kind) }
        guard !row.isEmpty else { return }
        if table == nil { table = RTFTable() }
        table?.rows.append(row)
        row = []
    }

    /// Ends the table that is open, if any. A table in which no cell holds
    /// a word (a layout grid) is dropped.
    private mutating func closeTable() {
        guard table != nil || !row.isEmpty || !cell.isEmpty else { return }
        // Cells and rows left open by a damaged table are closed here.
        if !cell.isEmpty { row.append(cell); cell = [] }
        if !row.isEmpty {
            // Words in a table's cell that no `\cell` or `\row` ever closed are
            // in a table all the same
            if table == nil { table = RTFTable() }
            table?.rows.append(row)
            row = []
        }
        if let finished = table, finished.rows.contains(where: { $0.contains { !$0.isEmpty } }) {
            blocks.append(.table(finished))
        }
        table = nil
    }

    /// Ends the document: an unfinished paragraph and an open table are
    /// closed as `kind` and returned with every block.
    mutating func finish(lastParagraph kind: Kind, inTable: Bool) throws -> [RTFBlock] {
        try finishParagraph(kind, inTable: inTable)
        closeTable()
        return blocks
    }
}
