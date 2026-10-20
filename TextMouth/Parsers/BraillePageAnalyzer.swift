import Foundation

// MARK: - Result types

/// What a braille book's pages hold (FMT20): its blocks, in braille, and each page's numbers.
struct BrailleStructure: Equatable, Sendable {
    /// The headings and paragraphs, in order; each text is braille
    /// cells with one blank cell (U+2800) between words.
    var blocks: [BrailleBlock]
    /// One entry for each page of the file, in order.
    var pages: [BraillePageNumbers]
}

/// The numbers a braille page carries, kept for navigation by braille
/// or print page, which is a follow-up; each is braille cells, such as "⠼⠁".
struct BraillePageNumbers: Equatable, Sendable {
    var braillePageNumber: String?
    var printPageNumber: String?
    /// The number of each print page change line on the page, in order.
    var printPageChanges: [String] = []
    /// The index in `blocks` of the first block with text on this page
    /// (a paragraph continued from the page before counts); for a page
    /// with no text, the index of the next block that has some.
    var firstBlockIndex: Int
}

// MARK: - Analyzer

/// Reads the structure of a braille book from its pages (FMT20): the
/// headings, the paragraphs, and each page's numbers, following BANA's
/// Braille Formats (2016) as the prototype's layout writes them.
///
/// The analyzer is pure: it takes the compact pages a BRF or a PEF holds
/// (`BrailleFilePages`: every cell a byte of one buffer), and neither opens
/// a file nor starts a process. Everything it is given is untrusted, so
/// every count is bounded, and the work is linear in the size of the
/// input. It works on one page at a time and makes a `String` only for each
/// finished block and page number, so its memory is the book's cells, the
/// blocks it returns, and the rows of one page.
enum BraillePageAnalyzer {
    // MARK: Constants

    /// The shortest and longest line width the analyzer measures a file as.
    private static let widthRange = 18...80
    /// The most cells a number word (such as ⠼⠁ or ⠏⠼⠁) holds.
    private static let maxNumberWordLength = 8
    /// The fewest blank cells that stand before a page number at the right
    /// of a row, and on each side of a centered heading.
    private static let minGap = 3
    /// The fewest dots-3-6 cells a print page change line starts with.
    private static let minChangeDashes = 3
    /// The indent of a level-2 heading's rows: it starts in cell 5.
    static let cellFiveIndent = 4
    /// The indent of a level-3 heading's rows: it starts in cell 7.
    static let cellSevenIndent = 6

    // The cells the analyzer looks for, as the bytes of their dots.

    /// The blank cell: no dots (U+2800).
    private static let blank: UInt8 = 0x00
    /// The number sign, dots 3456 (U+283C).
    private static let numberSign: UInt8 = 0x3C
    /// Dots 3-6 (U+2824), the cell a print page change line is drawn with.
    private static let changeDash: UInt8 = 0x24
    /// The ten digit cells, a to j: ⠁⠃⠉⠙⠑⠋⠛⠓⠊⠚.
    private static let digits: Set<UInt8> = [0x01, 0x03, 0x09, 0x19, 0x11, 0x0B, 0x1B, 0x13, 0x0A, 0x1A]

    // MARK: Entry points

    /// The structure of the book whose pages are `pages`, each page a list of
    /// rows of Unicode braille: the compact form made of them, read as `pages(of:)`.
    ///
    /// - Parameter formatted: false for an unformatted BRL, where every row
    ///   that is not blank is a paragraph, there are no headings, and the
    ///   book has one page with no numbers.
    static func structure(of pages: [[String]], formatted: Bool) -> BrailleStructure {
        structure(of: BrailleFilePages(kind: formatted ? .brf : .brl, pages: pages))
    }

    /// The structure of the book `file` holds. A BRL (`.brl`) is unformatted:
    /// every row that is not blank is a paragraph, there are no headings,
    /// and the book has one page with no numbers.
    static func structure(of file: BrailleFilePages) -> BrailleStructure {
        let book = Book(file: file)
        guard file.kind != .brl else { return book.unformattedStructure() }

        // The line width is measured before anything is taken out of any row.
        let width = book.lineWidth()

        // One page at a time: take its numbers and change lines out, keeping
        // the rows left, and read its rows into blocks.
        var pageNumbers: [BraillePageNumbers] = []
        pageNumbers.reserveCapacity(file.pageCount)
        var reader = BlockReader(book: book, width: width, pageCount: file.pageCount)
        for pageIndex in 0..<file.pageCount {
            let (numbers, kept) = book.extractNumbers(fromPage: pageIndex, width: width)
            pageNumbers.append(numbers)
            reader.read(kept, onPage: pageIndex)
        }
        let (blocks, firstBlockOfPage) = reader.finish()

        // Say where each page's first block is. Working from the last page
        // back, a page with no text takes the first block of the next page
        // that has some (or the count of blocks, past the end).
        var nextFirstBlock = blocks.count
        for index in pageNumbers.indices.reversed() {
            nextFirstBlock = firstBlockOfPage[index] ?? nextFirstBlock
            pageNumbers[index].firstBlockIndex = nextFirstBlock
        }
        return BrailleStructure(blocks: blocks, pages: pageNumbers)
    }

    // MARK: Spans and rows

    /// A run of cells in the file's buffer, by its offsets; 32 bits each,
    /// since the buffer is never longer (see `BrailleFilePages`).
    private struct Span {
        var start: Int32
        var end: Int32

        init(_ range: Range<Int>) {
            start = Int32(clamping: range.lowerBound)
            end = Int32(clamping: range.upperBound)
        }

        var range: Range<Int> { Int(start)..<Int(end) }
        var count: Int { Int(end) - Int(start) }
        var isEmpty: Bool { end <= start }
    }

    /// One row of a formatted page that is left once the page's numbers and
    /// change lines are out: its indent, and its cells from the first to the
    /// last that is not blank.
    private struct Row {
        /// The number of blank cells before the first cell.
        let indent: Int
        /// The cells from the first not blank to the last not blank; empty for a blank row.
        let content: Span

        var isBlank: Bool { content.isEmpty }
    }

    /// The pages' cells, with the work on them that needs no state: the
    /// rows of a page, the line width, and the numbers on a page.
    private struct Book {
        let file: BrailleFilePages
        let cells: [UInt8]

        init(file: BrailleFilePages) {
            self.file = file
            self.cells = file.cells
        }

        // MARK: Rows

        /// The rows of page `page`, each with its trailing blank cells dropped.
        func rows(ofPage page: Int) -> [Span] {
            file.rows(ofPage: page).map { Span(trimmedTrailingBlanks(of: file.cellRange(ofRow: $0))) }
        }

        /// `range` with its trailing blank cells left out.
        func trimmedTrailingBlanks(of range: Range<Int>) -> Range<Int> {
            var end = range.upperBound
            while end > range.lowerBound, cells[end - 1] == blank { end -= 1 }
            return range.lowerBound..<end
        }

        /// The row `span` as a `Row`: its indent and its cells from the
        /// first that is not blank (the end is trimmed already).
        func makeRow(_ span: Span) -> Row {
            var lead = span.range.lowerBound
            while lead < span.range.upperBound, cells[lead] == blank { lead += 1 }
            return Row(indent: lead - span.range.lowerBound, content: Span(lead..<span.range.upperBound))
        }

        // MARK: Width

        /// The line width of a formatted book, held to `widthRange`: the most
        /// common length among the pages' last rows that end in a number word
        /// after at least 3 blank cells (a braille page number, as the layout
        /// writes it at the right margin), the longer length on a tie; and,
        /// when no page has such a row, the length of the longest row.
        ///
        /// The page-number column is what the width is, so one row that runs a
        /// cell past it (a stray overlong line) cannot shift it and leave the
        /// page numbers in the text.
        func lineWidth() -> Int {
            // How many pages have a numbered last row of each length.
            var numberedLengths: [Int: Int] = [:]
            var longest = 0
            for page in 0..<file.pageCount {
                let rows = self.rows(ofPage: page)
                for row in rows { longest = max(longest, row.count) }
                if let last = rows.last(where: { !$0.isEmpty }), numberWordAtRight(of: last) != nil {
                    numberedLengths[last.count, default: 0] += 1
                }
            }
            // The most common length; the longer of two that are as common.
            let common = numberedLengths.max { ($0.value, $0.key) < ($1.value, $1.key) }?.key
            return min(max(common ?? longest, widthRange.lowerBound), widthRange.upperBound)
        }

        // MARK: Unformatted files

        /// The structure of an unformatted BRL: one paragraph for each row that
        /// is not blank, no headings, and a single page with no numbers.
        func unformattedStructure() -> BrailleStructure {
            var blocks: [BrailleBlock] = []
            for rowIndex in 0..<file.rowCount {
                var text = CellText()
                text.append(row: cells[trimmedTrailingBlanks(of: file.cellRange(ofRow: rowIndex))])
                if !text.isEmpty { blocks.append(.paragraph(text: text.string)) }
            }
            return BrailleStructure(blocks: blocks, pages: [BraillePageNumbers(firstBlockIndex: 0)])
        }

        // MARK: Page numbers

        /// Whether `word` is a number word: at most 8 cells, none blank, with the
        /// number sign directly followed by a digit cell. It may have letters
        /// before or after (⠏⠼⠁ is page p1, ⠁⠼⠁ page a1).
        private func isNumberWord(_ word: Span) -> Bool {
            guard !word.isEmpty, word.count <= maxNumberWordLength else { return false }
            let slice = cells[word.range]
            guard !slice.contains(blank) else { return false }
            return zip(slice, slice.dropFirst()).contains { $0 == numberSign && digits.contains($1) }
        }

        /// Whether `row` is a print page change line: its leading blanks, then at
        /// least 3 cells of dots 3-6, then directly a number word, and nothing else.
        /// Returns the number word, or nil.
        private func changeLineNumber(of row: Span) -> Span? {
            var lead = row.range.lowerBound
            while lead < row.range.upperBound, cells[lead] == blank { lead += 1 }
            var dashEnd = lead
            while dashEnd < row.range.upperBound, cells[dashEnd] == changeDash { dashEnd += 1 }
            guard dashEnd - lead >= minChangeDashes else { return nil }
            let word = Span(dashEnd..<row.range.upperBound)
            return isNumberWord(word) ? word : nil
        }

        /// Splits a number word off the right of `row`: the word and what is left
        /// of the row before it. The word must be the row's last, end exactly at
        /// `width`, and stand after at least 3 blank cells (a word alone on a
        /// row has the whole margin before it, which is more than 3).
        private func numberAtRight(of row: Span, width: Int) -> (word: Span, rest: Span)? {
            guard row.count == width else { return nil }
            return numberWordAtRight(of: row)
        }

        /// `numberAtRight(of:width:)` for a row of any length: the number word
        /// that ends `row` after at least 3 blank cells, and the row before it.
        func numberWordAtRight(of row: Span) -> (word: Span, rest: Span)? {
            // The last word starts after the last blank cell; a word of more
            // cells than a number word has is no number, so the search for
            // its start stops one cell past that.
            let rowStart = row.range.lowerBound
            var start = row.range.upperBound
            while start > rowStart, cells[start - 1] != blank, row.range.upperBound - start <= maxNumberWordLength {
                start -= 1
            }
            let word = Span(start..<row.range.upperBound)
            guard isNumberWord(word) else { return nil }
            // Count the blank cells directly before the word.
            var gapStart = start
            while gapStart > rowStart, cells[gapStart - 1] == blank { gapStart -= 1 }
            guard start - gapStart >= minGap else { return nil }
            return (word, Span(rowStart..<gapStart))
        }

        /// Takes a page's numbers out of its rows: the braille page number from
        /// the last row, the print page number from the first, and every print
        /// page change line. Returns the numbers and the rows left, in order: a
        /// row that held nothing but a number is dropped (it is not a blank row,
        /// and must not end a paragraph that goes on over the page), a row that
        /// was blank stays blank (except at the page's top, where blank rows
        /// go), and the rows after the braille page number go.
        func extractNumbers(fromPage page: Int, width: Int) -> (BraillePageNumbers, [Row]) {
            let rawRows = rows(ofPage: page)
            var numbers = BraillePageNumbers(firstBlockIndex: 0)
            // The rows a number was taken from (shortened, or dropped when
            // nothing is left of them), and the change lines (dropped).
            var shortened: [Int: Span] = [:]
            var dropped: Set<Int> = []
            var changeWords: [(row: Int, word: Span)] = []
            for (index, row) in rawRows.enumerated() {
                if let word = changeLineNumber(of: row) { changeWords.append((index, word)) }
            }
            let changeRows = Set(changeWords.map(\.row))

            /// Takes the number word off the right of row `index`, if it has one
            /// there, and returns it.
            func takeNumber(at index: Int?) -> String? {
                guard let index, !changeRows.contains(index),
                      let (word, rest) = numberAtRight(of: rawRows[index], width: width) else { return nil }
                if rest.isEmpty { dropped.insert(index) } else { shortened[index] = rest }
                return BrailleFilePages.string(of: cells[word.range])
            }

            // The braille page number: the last row that is not blank.
            let lastIndex = rawRows.lastIndex { !$0.isEmpty }
            numbers.braillePageNumber = takeNumber(at: lastIndex)
            // The print page number: the first row that is not blank, unless the
            // braille page number came from it.
            let firstIndex = rawRows.firstIndex { !$0.isEmpty }
            if firstIndex != lastIndex || numbers.braillePageNumber == nil {
                numbers.printPageNumber = takeNumber(at: firstIndex)
            }
            // Change lines leave the page altogether.
            for (index, word) in changeWords {
                numbers.printPageChanges.append(BrailleFilePages.string(of: cells[word.range]))
                dropped.insert(index)
            }

            // The rows left. Anything after the braille page number's row is
            // past the end of the page (a reader may leave an empty piece
            // after a file's last line break), and must not end a paragraph
            // that goes on over the page. BANA never starts a page with a
            // blank line, so a blank row at the top is the file's own doing:
            // a form feed followed by a line end, or on a line of its own,
            // starts the next page with an empty row. It must not end a
            // paragraph that goes on over the page either, so the blank rows
            // before the page's first row with text (after the numbers are
            // out) are dropped.
            let end = numbers.braillePageNumber != nil ? (lastIndex ?? -1) + 1 : rawRows.count
            var kept: [Row] = []
            for index in 0..<end where !dropped.contains(index) {
                let row = makeRow(shortened[index] ?? rawRows[index])
                if kept.isEmpty && row.isBlank { continue }
                kept.append(row)
            }
            return (numbers, kept)
        }
    }

    // MARK: Text

    /// The text of a block as it is read: the cells of each row with runs of
    /// blank cells made one, the rows joined by one blank cell, and no blank
    /// cell at either end. Built in one pass, so the cost is linear.
    private struct CellText {
        private var cells: [UInt8] = []
        /// Whether a blank is owed before the next cell.
        private var pendingBlank = false

        var isEmpty: Bool { cells.isEmpty }

        /// Swaps this text's buffer for `other`, so that one buffer can serve
        /// block after block (see `BlockReader`); the text starts again.
        mutating func exchangeBuffer(with other: inout [UInt8]) {
            swap(&cells, &other)
            pendingBlank = false
        }

        /// Adds the cells of a row (any blank cells in it are word breaks).
        mutating func append<Cells: Sequence>(row: Cells) where Cells.Element == UInt8 {
            // A row break counts as a blank between words.
            pendingBlank = pendingBlank || !cells.isEmpty
            for cell in row {
                if cell == BraillePageAnalyzer.blank {
                    pendingBlank = !cells.isEmpty
                    continue
                }
                if pendingBlank { cells.append(BraillePageAnalyzer.blank) }
                pendingBlank = false
                cells.append(cell)
            }
        }

        /// The braille text: the cells as Unicode patterns.
        var string: String { BrailleFilePages.string(of: cells) }
    }

    // MARK: Blocks

    /// A block being read: a paragraph, or a heading below level 1 (a centered
    /// heading is read whole, so it is never open).
    private struct OpenBlock {
        /// 2 or 3 for a heading, nil for a paragraph.
        let headingLevel: Int?
        /// The indent of the heading's rows (its following rows must match).
        let indent: Int
        var text: CellText
    }

    /// Whether `row` is centered: at least 3 blank cells on each side, the
    /// two sides differing by at most 1.
    private static func isCentered(_ row: Row, width: Int) -> Bool {
        let left = row.indent
        let right = width - row.indent - row.content.count
        return left >= minGap && right >= minGap && abs(left - right) <= 1
    }

    /// Whether `row` starts where a cell-5 or a cell-7 heading does.
    private static func isCellFiveOrSeven(_ row: Row) -> Bool {
        row.indent == cellFiveIndent || row.indent == cellSevenIndent
    }

    /// Reads the blocks from the rows of the pages, one page at a time, in
    /// order. What a page leaves open (a paragraph that goes on over the page
    /// break, a heading that does) carries to the next.
    private struct BlockReader {
        let book: Book
        let width: Int
        private(set) var blocks: [BrailleBlock] = []
        /// For each page that holds text, the index of the first block that
        /// has a row there (nil for a page with no text).
        private var firstBlockOfPage: [Int?]
        private var open: OpenBlock?
        /// Whether the row before this one belonged to a heading.
        private var previousWasHeading = false
        /// The buffer the text of each block is built in, and handed back to
        /// when the block is made a string. It has room for the whole file's
        /// cells, which no block can pass, so it never grows, and the room
        /// not used is never touched; the book's memory is not doubled by it.
        private var spareBuffer: [UInt8] = []

        init(book: Book, width: Int, pageCount: Int) {
            self.book = book
            self.width = width
            self.firstBlockOfPage = [Int?](repeating: nil, count: pageCount)
            self.spareBuffer.reserveCapacity(book.cells.count)
        }

        /// A text that builds in the spare buffer.
        private mutating func newText() -> CellText {
            var text = CellText()
            text.exchangeBuffer(with: &spareBuffer)
            return text
        }

        /// The string of `text`, which then gives its buffer back.
        private mutating func finish(_ text: inout CellText) -> String {
            let string = text.string
            text.exchangeBuffer(with: &spareBuffer)
            spareBuffer.removeAll(keepingCapacity: true)
            return string
        }

        /// Ends the open block, if any.
        private mutating func closeOpenBlock() {
            // Taken out of `open`, so that its buffer has no other owner.
            guard var block = open else { return }
            open = nil
            let text = finish(&block.text)
            if let level = block.headingLevel {
                blocks.append(.heading(level: level, text: text))
            } else {
                blocks.append(.paragraph(text: text))
            }
        }

        /// Notes that a row of page `page` belongs to the block that will
        /// have index `blocks.count` once it closes: the open block, or a new one.
        private mutating func noteRow(onPage page: Int) {
            if firstBlockOfPage.indices.contains(page), firstBlockOfPage[page] == nil {
                firstBlockOfPage[page] = blocks.count
            }
        }

        /// Reads the rows `rows` of page `page`.
        mutating func read(_ rows: [Row], onPage page: Int) {
            /// Whether row `index` comes after a blank row, or the top of its page.
            func startsAfterBreak(_ index: Int) -> Bool { index == 0 || rows[index - 1].isBlank }
            /// Whether row `index`, as the first row after a run, is a blank
            /// row or past the end of the page.
            func endsRun(before index: Int) -> Bool { index >= rows.count || rows[index].isBlank }

            // Rows before this index cannot begin a centered run: a scan from one
            // of them already ran past the run's end without finding a blank
            // row. It keeps a long stretch of centered-looking rows linear.
            var noRunBefore = 0
            /// The index just past the centered run that begins at row `start`:
            /// the consecutive rows from there, none blank, each centered,
            /// that end at a blank row or at the page's end. Nil when row
            /// `start` is not centered or the rows go on into one that is
            /// neither blank nor centered.
            func centeredRun(from start: Int) -> Int? {
                guard start >= noRunBefore else { return nil }
                var end = start
                while end < rows.count, !rows[end].isBlank, isCentered(rows[end], width: width) { end += 1 }
                guard end > start else { return nil }
                if endsRun(before: end) { return end }
                noRunBefore = end
                return nil
            }

            var index = 0
            while index < rows.count {
                let row = rows[index]
                // 1. A blank row ends the current block.
                if row.isBlank {
                    closeOpenBlock()
                    previousWasHeading = false
                    index += 1
                    continue
                }
                // A further row of the same indent belongs to a cell-5 or cell-7 heading.
                if let heading = open, heading.headingLevel != nil, heading.indent == row.indent {
                    noteRow(onPage: page)
                    open?.text.append(row: book.cells[row.content.range])
                    previousWasHeading = true
                    index += 1
                    continue
                }
                // 2 to 4. A heading, at a row that may begin one: after a blank
                // row, at the top of a page, or after another heading.
                if startsAfterBreak(index) || previousWasHeading {
                    // 2. A centered heading: the run of centered rows here, every
                    // indent counted (a line with a margin of 4 or 6 cells is
                    // as centered as any other). It is one level-1 heading,
                    // unless all its rows share the indent of a cell-5 or
                    // cell-7 heading, which a long heading in cell 5 or 7
                    // also measures as (it ends within a cell of the right
                    // margin that its indent has on the left): that is rule 3's.
                    if let end = centeredRun(from: index),
                       !(isCellFiveOrSeven(row) && rows[index..<end].allSatisfy({ $0.indent == row.indent })) {
                        closeOpenBlock()
                        noteRow(onPage: page)
                        var text = newText()
                        for line in rows[index..<end] { text.append(row: book.cells[line.content.range]) }
                        blocks.append(.heading(level: 1, text: finish(&text)))
                        previousWasHeading = true
                        index = end
                        continue
                    }
                    // 3. A cell-5 (level 2) or cell-7 (level 3) heading, which
                    // takes the following rows of its indent.
                    if isCellFiveOrSeven(row) {
                        closeOpenBlock()
                        noteRow(onPage: page)
                        open = OpenBlock(headingLevel: row.indent == cellFiveIndent ? 2 : 3, indent: row.indent,
                                         text: newText())
                        open?.text.append(row: book.cells[row.content.range])
                        previousWasHeading = true
                        index += 1
                        continue
                    }
                }
                // 4 and 5. A paragraph: a row of indent 0 goes on the open
                // paragraph, or starts one; any other indent starts one.
                if row.indent == 0, let paragraph = open, paragraph.headingLevel == nil {
                    open?.text.append(row: book.cells[row.content.range])
                } else {
                    closeOpenBlock()
                    open = OpenBlock(headingLevel: nil, indent: row.indent, text: newText())
                    open?.text.append(row: book.cells[row.content.range])
                }
                noteRow(onPage: page)
                previousWasHeading = false
                index += 1
            }
        }

        /// Ends the last block. Returns the blocks and, for each page, the
        /// index of the first block that has a row there (nil for a page with no text).
        mutating func finish() -> (blocks: [BrailleBlock], firstBlockOfPage: [Int?]) {
            closeOpenBlock()
            return (blocks, firstBlockOfPage)
        }
    }
}
