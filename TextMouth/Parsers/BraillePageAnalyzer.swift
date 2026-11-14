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

/// The numbers a braille page carries, each braille cells such as "⠼⠁", and
/// where the page begins in the book's blocks. The braille page number names
/// the page in the reader (PG12, `braillePageLabel`); the print page numbers
/// are kept for navigation by print page, which is a follow-up.
struct BraillePageNumbers: Equatable, Sendable {
    var braillePageNumber: String?
    var printPageNumber: String?
    /// The number of each print page change line on the page, in order.
    var printPageChanges: [String] = []
    /// The index in `blocks` of the first block with text on this page
    /// (a paragraph continued from the page before counts); for a page
    /// with no text, the index of the next block that has some.
    var firstBlockIndex: Int
    /// Where the page begins in that block (PG12): the offset, in cells of
    /// the block's text, of the page's first cell. It is 0 for a page that
    /// begins its first block, and inside the block for a page whose first
    /// row goes on a paragraph or heading from the page before. A page with
    /// no text takes the offset of the next page that has some, and so
    /// begins where that page does; a page after the last block has 0.
    ///
    /// A page always begins at the start of a row, and a block's rows are
    /// joined by one blank cell, so inside a block the cell before a page's
    /// first cell is that blank, and the page begins at a word.
    var firstCellOffset: Int = 0
    /// Whether any of the page's rows holds text: belongs to a block, rather
    /// than being blank, a page number, or a print page change line. A page
    /// without, such as the blank back of a two-sided page or the empty page
    /// a form feed leaves at a file's start or end, takes the next page's
    /// place (above), and is a page only when it has a number (PG12).
    var hasText = false
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

    /// The shortest and longest line width the analyzer measures a file as
    /// (and the widths a PEF's `cols` may declare).
    static let widthRange = 18...80
    /// The most cells a number word (such as ⠼⠁ or ⠏⠼⠁) holds.
    private static let maxNumberWordLength = 8
    /// The fewest blank cells that stand before a page number at the right
    /// of a row, and on each side of a centered heading.
    private static let minGap = 3
    /// The most rows a heading that stands alone may have, to count toward
    /// the implied width of a book (see `Book.measure()`).
    private static let maxStandAloneRows = 12
    /// The most rows of text (rules left out) a centered heading may have when
    /// it runs straight on into an indented row with no blank row between.
    private static let maxRunOnHeadingRows = 3
    /// The fewest cells a rule is drawn with, and the cells it is drawn
    /// with: dots 5, 2-5, 3-6, 4-5-6, and all six, which a transcriber
    /// repeats across a line to set a chapter off (not letters, so that a row of
    /// letters is never one).
    private static let minRuleCells = 4
    private static let ruleCells: Set<UInt8> = [0x10, 0x12, 0x24, 0x38, 0x3F]
    /// The fewest pages a head's text must repeat on to be a running head.
    private static let minHeadRepeats = 3
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
    /// The hyphen and the dash end with the same cell, dots 3-6, and a word
    /// may be divided after either at a line's end.
    private static let hyphen: UInt8 = changeDash
    /// The letter sign, dots 5-6 (U+2830), and the capital sign, dot 6
    /// (U+2820): what a Roman numeral's letters follow in a change line.
    private static let letterSign: UInt8 = 0x30
    private static let capitalSign: UInt8 = 0x20
    /// The cells of the Roman numeral letters i, v, x, l, c, d, and m.
    private static let romanLetters: Set<UInt8> = [0x0A, 0x27, 0x2D, 0x07, 0x09, 0x19, 0x0D]
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

        // The line width, and the book's style of paragraph, are measured
        // before anything is taken out of any row.
        let measure = book.measure()
        let width = measure.width
        // The running heads: first rows whose text repeats on several pages.
        let runningHeads = book.runningHeads(width: width)

        // One page at a time: take its numbers and change lines out, keeping
        // the rows left, and read its rows into blocks.
        var pageNumbers: [BraillePageNumbers] = []
        pageNumbers.reserveCapacity(file.pageCount)
        var reader = BlockReader(book: book, width: width, pageCount: file.pageCount)
        for pageIndex in 0..<file.pageCount {
            let (numbers, kept) = book.extractNumbers(
                fromPage: pageIndex, width: width, dropsTopBlankRows: measure.dropsPageTopBlankRows,
                runningHeads: runningHeads)
            pageNumbers.append(numbers)
            reader.read(kept, onPage: pageIndex)
        }
        let (blocks, firstPlaceOfPage) = reader.finish()

        // Say where each page begins: its first block, and the cell of that
        // block its first row begins at. Working from the last page back, a
        // page with no text begins where the next page that has some does
        // (or past the end, after the last block).
        var nextPlace = PagePlace(blockIndex: blocks.count, cellOffset: 0)
        for index in pageNumbers.indices.reversed() {
            pageNumbers[index].hasText = firstPlaceOfPage[index] != nil
            nextPlace = firstPlaceOfPage[index] ?? nextPlace
            pageNumbers[index].firstBlockIndex = nextPlace.blockIndex
            pageNumbers[index].firstCellOffset = nextPlace.cellOffset
        }
        return BrailleStructure(blocks: blocks, pages: pageNumbers)
    }

    // MARK: Spans and rows

    /// Where a page's first row lands in the blocks (PG12): the index of the
    /// block it belongs to, and the offset in that block's text of the row's
    /// first cell.
    private struct PagePlace {
        var blockIndex: Int
        var cellOffset: Int
    }

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

        /// What a formatted book's pages measure before its rows are read.
        struct Measure {
            /// The line width, held to `widthRange` (see `lineWidth`).
            let width: Int
            /// Whether a blank row at a page's top is dropped: whether the
            /// book's paragraphs are BANA's (see `ParagraphStarts`).
            let dropsPageTopBlankRows: Bool
        }

        /// Measures the book in one pass over its rows: the line width and the
        /// style of its paragraphs.
        ///
        /// The line width is held to `widthRange`:
        ///
        /// 1. a PEF's declared width (its volume's `cols`), when there is one;
        /// 2. else the most common length among the pages' last rows that end
        ///    in a number word after at least 3 blank cells (a braille page
        ///    number, as the layout writes it at the right margin), the longer
        ///    length on a tie;
        /// 3. else, when no page has such a row, the longest row, or a wider
        ///    width that the headings set apart in the book imply (see
        ///    `WidthVotes.bestWidth(atLeast:)`).
        ///
        /// The page-number column is what the width is, so one row that runs a
        /// cell past it (a stray overlong line) cannot shift it and leave the
        /// page numbers in the text.
        func measure() -> Measure {
            // How many pages have a numbered last row of each length, which
            // widths the headings set apart vote for, and where paragraphs begin.
            var numberedLengths: [Int: Int] = [:]
            var votes = WidthVotes()
            var starts = ParagraphStarts()
            var longest = 0
            for page in 0..<file.pageCount {
                let rows = self.rows(ofPage: page)
                for row in rows { longest = max(longest, row.count) }
                if let last = rows.last(where: { !$0.isEmpty }), numberWordAtRight(of: last) != nil {
                    numberedLengths[last.count, default: 0] += 1
                }
                noteImpliedWidths(ofRows: rows, in: &votes)
                noteParagraphStarts(ofRows: rows, in: &starts)
            }
            return Measure(width: lineWidth(longest: longest, numberedLengths: numberedLengths, votes: votes),
                           dropsPageTopBlankRows: starts.beginInCellThree)
        }

        /// The line width of a book that has been measured (see `measure`).
        private func lineWidth(longest: Int, numberedLengths: [Int: Int], votes: WidthVotes) -> Int {
            if let declared = file.lineWidth, widthRange.contains(declared) { return declared }
            // The most common length; the longer of two that are as common.
            if let common = numberedLengths.max(by: { ($0.value, $0.key) < ($1.value, $1.key) })?.key {
                return min(max(common, widthRange.lowerBound), widthRange.upperBound)
            }
            // Without a page number to measure, a short book's centered
            // heading would measure off center against its longest row, which
            // may be shorter than the line. TextMouth's own export centers its
            // headings, so a heading that stands alone gives the width it was
            // centered in: the book is at least that wide.
            let atLeast = min(max(longest, widthRange.lowerBound), widthRange.upperBound)
            return votes.bestWidth(atLeast: atLeast) ?? atLeast
        }

        // MARK: Paragraph style

        /// How many paragraphs of each style begin in a book (FMT20).
        ///
        /// BANA's paragraphs begin in cell 3 (indent 2) and run over in cell 1.
        /// A book of block-style paragraphs begins them in cell 1 after a
        /// blank row instead. A blank row at the top of a page is the file's
        /// own doing in the first (a form feed followed by a line end starts
        /// the next page with an empty row, and it must not end a paragraph
        /// that goes on over the page), but it is a paragraph's end in the
        /// second, whose paragraphs are set apart by blank rows.
        struct ParagraphStarts {
            /// The rows that begin in cell 3.
            var indentTwo = 0
            /// The rows that begin in cell 1 after a blank row in the middle of a page.
            var indentZeroAfterBlank = 0

            /// Whether the book's paragraphs are BANA's: more begin in cell 3
            /// than in cell 1 after a blank row.
            var beginInCellThree: Bool { indentTwo > indentZeroAfterBlank }
        }

        /// Counts the paragraph starts in the rows of a page. A blank row at the
        /// page's top (before any row with text) does not count a start after
        /// it: that is the very case the style decides.
        private func noteParagraphStarts(ofRows rows: [Span], in starts: inout ParagraphStarts) {
            var seenText = false
            var afterBlankInPage = false
            for row in rows {
                guard !row.isEmpty else { afterBlankInPage = seenText; continue }
                let indent = makeRow(row).indent
                if indent == 2 {
                    starts.indentTwo += 1
                } else if indent == 0, afterBlankInPage, changeLineNumber(of: row) == nil {
                    starts.indentZeroAfterBlank += 1
                }
                seenText = true
                afterBlankInPage = false
            }
        }

        /// The widths that the rows set apart in a book vote for (FMT20).
        ///
        /// A row centered in a line of `width` cells has an implied width, twice
        /// its left margin plus its length, of `width` or one less (the extra
        /// cell of an odd difference falls on the right), or one more (the
        /// layout moves it to the left when the margin would be 4 or 6). So a
        /// row votes for every width from its implied width less one to its
        /// implied width plus one at which it is still centered: with at
        /// least 3 blank cells on its right as on its left. The width with the
        /// most votes is the one the most rows are centered in.
        struct WidthVotes {
            /// How many votes begin at each width, less those that ended before it
            /// (a difference array: the votes for a width are the sum up to it).
            private var changes = [Int](repeating: 0, count: widthRange.upperBound + 2)

            /// Adds the vote of a row of `length` cells, margin included, that has
            /// `margin` blank cells before it.
            mutating func add(margin: Int, length: Int) {
                let implied = margin + length
                let first = max(implied - 1, length + minGap, widthRange.lowerBound)
                let last = min(implied + 1, widthRange.upperBound)
                guard first <= last else { return }
                changes[first] += 1
                changes[last + 1] -= 1
            }

            /// The width of at least `floor` that most rows vote for, or nil when
            /// none does. Of several runs of widths with as many votes the last
            /// (widest) run is taken, and the middle of that run, the lower
            /// middle for an even run: one row votes for three widths, and its
            /// own implied width is the middle one.
            func bestWidth(atLeast floor: Int) -> Int? {
                var votes = 0
                var best = 0
                var run: ClosedRange<Int>?
                for width in widthRange.lowerBound...widthRange.upperBound {
                    votes += changes[width]
                    guard width >= floor, votes > 0, votes >= best else { continue }
                    if votes > best {
                        best = votes
                        run = width...width
                    } else if let current = run, current.upperBound == width - 1 {
                        run = current.lowerBound...width
                    } else {
                        run = width...width
                    }
                }
                return run.map { ($0.lowerBound + $0.upperBound) / 2 }
            }
        }

        /// Adds the votes of the rows of a page that stand alone.
        ///
        /// A row stands alone when a blank row or a page's edge comes before
        /// and after it, or, for a heading of several rows, before its first
        /// row and after its last (up to `maxStandAloneRows` rows, each with
        /// at least 3 blank cells before it). A print page change line is
        /// no such row, and neither is a row that starts where a cell-5 or
        /// cell-7 heading does: a long heading there is as likely to be one,
        /// and its implied width is far past the line's.
        private func noteImpliedWidths(ofRows rows: [Span], in votes: inout WidthVotes) {
            var start = 0
            while start < rows.count {
                // Skip blank rows; a stretch of rows with text begins here.
                guard !rows[start].isEmpty else { start += 1; continue }
                var end = start
                while end < rows.count, !rows[end].isEmpty { end += 1 }
                defer { start = end }
                // A stretch is set apart on both ends by construction; a long
                // one is a paragraph or a list, not a heading.
                guard end - start <= maxStandAloneRows else { continue }
                let margins = rows[start..<end].map { makeRow($0).indent }
                guard margins.allSatisfy({ $0 >= minGap }) else { continue }
                for (row, margin) in zip(rows[start..<end], margins)
                where margin != cellFiveIndent && margin != cellSevenIndent && changeLineNumber(of: row) == nil {
                    votes.add(margin: margin, length: row.count)
                }
            }
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
            return BrailleStructure(blocks: blocks, pages: [BraillePageNumbers(firstBlockIndex: 0, hasText: !blocks.isEmpty)])
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

        /// Whether `word` is a Roman numeral word: a letter sign (or a capital
        /// sign) and then one to `maxNumberWordLength` Roman numeral letters,
        /// the way a front matter page's number is written (";IX" is "ix").
        private func isRomanNumeralWord(_ word: Span) -> Bool {
            guard word.count >= 2, word.count <= maxNumberWordLength else { return false }
            let slice = cells[word.range]
            guard let sign = slice.first, sign == letterSign || sign == capitalSign else { return false }
            return slice.dropFirst().allSatisfy { romanLetters.contains($0) }
        }

        /// Whether `row` is a print page change line: its leading blanks, then at
        /// least 3 cells of dots 3-6, then directly a number word (a Roman
        /// numeral word for a front matter page), and nothing else.
        /// Returns the number word, or nil.
        private func changeLineNumber(of row: Span) -> Span? {
            var lead = row.range.lowerBound
            while lead < row.range.upperBound, cells[lead] == blank { lead += 1 }
            var dashEnd = lead
            while dashEnd < row.range.upperBound, cells[dashEnd] == changeDash { dashEnd += 1 }
            guard dashEnd - lead >= minChangeDashes else { return nil }
            let word = Span(dashEnd..<row.range.upperBound)
            return isNumberWord(word) || isRomanNumeralWord(word) ? word : nil
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

        // MARK: Running heads

        /// The first row of a page read as a running head: the number words
        /// at its two ends, and the text between them.
        struct PageHead {
            /// The index of the row among the page's rows.
            let rowIndex: Int
            /// The number word at the row's left (a braille page number that a
            /// book puts before its head), when it has one.
            let left: Span?
            /// The text between the number words, with no blank cell at either end.
            let text: Span
        }

        /// Splits a number word off the left of `row`: the word, which must
        /// start in the row's first cell and be followed by a blank cell, and
        /// what is left of the row after the blanks that follow it.
        private func numberWordAtLeft(of row: Span) -> (word: Span, rest: Span)? {
            let rowStart = row.range.lowerBound
            guard rowStart < row.range.upperBound, cells[rowStart] != blank else { return nil }
            // The word ends at the first blank cell; one longer than a number
            // word is no number, so the search stops a cell past that length.
            var wordEnd = rowStart
            while wordEnd < row.range.upperBound, cells[wordEnd] != blank, wordEnd - rowStart <= maxNumberWordLength {
                wordEnd += 1
            }
            let word = Span(rowStart..<wordEnd)
            guard isNumberWord(word), wordEnd < row.range.upperBound else { return nil }
            var restStart = wordEnd
            while restStart < row.range.upperBound, cells[restStart] == blank { restStart += 1 }
            return (word, Span(restStart..<row.range.upperBound))
        }

        /// The first row of the page `rows` read as a running head: the first
        /// row with text, less a print page number at its right (ending the
        /// line) and a number word at its left. Nil when the row has neither
        /// number word, or is a print page change line, or has no text
        /// between a lone number word and the row's end: such a row is no head.
        func pageHead(ofRows rows: [Span], width: Int) -> PageHead? {
            guard let index = rows.firstIndex(where: { !$0.isEmpty }),
                  changeLineNumber(of: rows[index]) == nil else { return nil }
            var body = rows[index]
            var hasRight = false
            if body.count == width, let (_, rest) = numberWordAtRight(of: body) {
                body = rest
                hasRight = true
            }
            var left: Span?
            if let (word, rest) = numberWordAtLeft(of: body) {
                left = word
                body = rest
            }
            guard hasRight || left != nil else { return nil }
            // A number word alone with no text is not a head (a page number's row).
            guard !body.isEmpty || (hasRight && left != nil) else { return nil }
            return PageHead(rowIndex: index, left: left, text: body)
        }

        /// The texts of the running heads of the book: the head texts
        /// (`pageHead(ofRows:width:)`) that repeat on at least
        /// `minHeadRepeats` pages. A book's running heads are the same line
        /// page after page (its title on one side of a spread, the chapter's
        /// on the other), where a row of text is not; that a head carries a
        /// number word as well is what keeps text from being taken for one.
        func runningHeads(width: Int) -> Set<[UInt8]> {
            var counts: [[UInt8]: Int] = [:]
            for page in 0..<file.pageCount {
                guard let head = pageHead(ofRows: rows(ofPage: page), width: width) else { continue }
                counts[Array(cells[head.text.range]), default: 0] += 1
            }
            return Set(counts.filter { $0.value >= BraillePageAnalyzer.minHeadRepeats }.keys)
        }

        /// Takes a page's numbers out of its rows: the braille page number from
        /// the last row, the print page number from the first, and every print
        /// page change line. Returns the numbers and the rows left, in order: a
        /// row that held nothing but a number is dropped (it is not a blank row,
        /// and must not end a paragraph that goes on over the page), a row that
        /// was blank stays blank (except at the page's top, where blank rows
        /// go when `dropsTopBlankRows`), and the rows after the braille page number go.
        func extractNumbers(
            fromPage page: Int, width: Int, dropsTopBlankRows: Bool, runningHeads: Set<[UInt8]> = []
        ) -> (BraillePageNumbers, [Row]) {
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
            // A running head leaves the page, row and numbers: the text that
            // repeats on several pages is no part of the book's text. A
            // number word at its left is the braille page number when the
            // page's last row held none (a book may put it at the top left).
            if let head = pageHead(ofRows: rawRows, width: width),
               !(firstIndex == lastIndex && lastIndex != nil && numbers.braillePageNumber != nil),
               runningHeads.contains(Array(cells[head.text.range])) {
                if numbers.braillePageNumber == nil, let left = head.left {
                    numbers.braillePageNumber = BrailleFilePages.string(of: cells[left.range])
                }
                dropped.insert(head.rowIndex)
                shortened[head.rowIndex] = nil
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
            // out) are dropped. In a book of block-style paragraphs (see
            // `ParagraphStarts`) they are kept, and end the paragraph before.
            let end = numbers.braillePageNumber != nil ? (lastIndex ?? -1) + 1 : rawRows.count
            var kept: [Row] = []
            for index in 0..<end where !dropped.contains(index) {
                let row = makeRow(shortened[index] ?? rawRows[index])
                if dropsTopBlankRows && kept.isEmpty && row.isBlank { continue }
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

        /// The offset at which the first cell of the next row appended will
        /// stand (PG12): after the one blank cell a row break adds, or at 0 in
        /// an empty text. A row is appended from its first cell that is not
        /// blank (`Row.content`), so that cell is the one that stands there.
        var nextRowOffset: Int { cells.isEmpty ? 0 : cells.count + 1 }

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
        /// The indent of the block's first row (a heading's following rows must match).
        let indent: Int
        /// For a paragraph, the indent of its first row that goes on, nil
        /// until it has one: 0 for BANA's paragraph, and the first row's
        /// indent plus 2 for a list item (cell 3 for an item in cell 1).
        var runoverIndent: Int?
        var text: CellText

        init(headingLevel: Int?, indent: Int, text: CellText) {
            self.headingLevel = headingLevel
            self.indent = indent
            self.text = text
        }
    }

    /// Whether `row` is centered: at least 3 blank cells on each side, the
    /// two sides differing by at most 1.
    private static func isCentered(_ row: Row, width: Int) -> Bool {
        let left = row.indent
        let right = width - row.indent - row.content.count
        return left >= minGap && right >= minGap && abs(left - right) <= 1
    }

    /// Whether `row` is only a rule: at least `minRuleCells` of one cell that
    /// a rule is drawn with, and nothing else. A rule sets a heading off and
    /// is never part of its text.
    private static func isRule(_ row: Row, in cells: [UInt8]) -> Bool {
        guard row.content.count >= minRuleCells, let first = cells[row.content.range].first,
              ruleCells.contains(first) else { return false }
        return cells[row.content.range].allSatisfy { $0 == first }
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
        /// For each page that holds text, where its first row lands: the
        /// first block that has a row there, and the cell that row begins at
        /// in that block's text (nil for a page with no text).
        private var firstPlaceOfPage: [PagePlace?]
        private var open: OpenBlock?
        /// Whether the row before this one belonged to a heading.
        private var previousWasHeading = false
        /// The length of the open paragraph's last row, its indent included,
        /// and whether that row ends in a hyphen or a dash (see `goesOn`).
        private var lastRowLength = 0
        private var lastRowEndsInHyphen = false
        /// The buffer the text of each block is built in, and handed back to
        /// when the block is made a string. It has room for the whole file's
        /// cells, which no block can pass, so it never grows, and the room
        /// not used is never touched; the book's memory is not doubled by it.
        private var spareBuffer: [UInt8] = []

        init(book: Book, width: Int, pageCount: Int) {
            self.book = book
            self.width = width
            self.firstPlaceOfPage = [PagePlace?](repeating: nil, count: pageCount)
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
        /// have index `blocks.count` once it closes, the open block or a new
        /// one, and that its first cell stands at `cellOffset` of that block's
        /// text: 0 in a new block, and the open block's `nextRowOffset` in a
        /// block the row goes on. Called before the row is appended. Only a
        /// page's first row is kept, as where the page begins (PG12).
        private mutating func noteRow(onPage page: Int, atCell cellOffset: Int) {
            if firstPlaceOfPage.indices.contains(page), firstPlaceOfPage[page] == nil {
                firstPlaceOfPage[page] = PagePlace(blockIndex: blocks.count, cellOffset: cellOffset)
            }
        }

        /// Notes `row` as the last row of the open paragraph.
        private mutating func noteLastRow(_ row: Row) {
            lastRowLength = row.indent + row.content.count
            lastRowEndsInHyphen = book.cells[row.content.range.upperBound - 1] == BraillePageAnalyzer.hyphen
        }

        /// Whether the first word of `row` could not have fitted on the open
        /// paragraph's last row: the row's length, a blank cell, and the
        /// word's length come to more than the line. A layout never divides
        /// a word and fills each line greedily (BANA 1.10.1), so a row that
        /// goes on a block could not have fitted on the row above it, and a
        /// row that could have is the start of another block. A row that
        /// follows a row ending in a hyphen or a dash is taken as going on,
        /// since a word may be divided there.
        private func couldNotHaveFitted(_ row: Row) -> Bool {
            guard !lastRowEndsInHyphen else { return true }
            // The first word's length, counted no further than the line
            // (a row may be very long, and a longer word could not fit anyway).
            var wordLength = 0
            var cell = row.content.range.lowerBound
            while cell < row.content.range.upperBound, book.cells[cell] != BraillePageAnalyzer.blank, wordLength <= width {
                wordLength += 1
                cell += 1
            }
            return lastRowLength + 1 + wordLength > width
        }

        /// Whether `row`, which is not blank, goes on the open paragraph
        /// `paragraph` (FMT20, E6). The row's indent tells where it goes:
        ///
        /// - A row in cell 1 goes on the paragraph, as it always has (BANA's
        ///   paragraph runs over in cell 1, and so does one in block style),
        ///   unless the paragraph has already run over in a further cell: a
        ///   list item does, in cell 3 for an item in cell 1, and a row in
        ///   cell 1 is then the next item. Rows are not told apart by length
        ///   here: few files fill every line, and BANA's paragraph begins
        ///   its runovers in cell 1 whatever the row above holds.
        /// - A row two cells further in than the paragraph's first row (or in
        ///   the cell its first runover was in) is a list item's runover when
        ///   it could not have fitted on the row above (`couldNotHaveFitted`),
        ///   and the first row of the next item when it could. At a page's
        ///   top, though, the first such row is a heading when the row above
        ///   is the paragraph's only row (a heading in cell 5 follows a
        ///   paragraph of one row as a runover would, and the page break
        ///   leaves no blank row to tell them apart).
        /// - A row of any other indent begins another block.
        private func goesOn(_ row: Row, _ paragraph: OpenBlock, atPageTop: Bool) -> Bool {
            if row.indent == 0 { return (paragraph.runoverIndent ?? 0) == 0 }
            if atPageTop && paragraph.runoverIndent == nil { return false }
            let expected = paragraph.runoverIndent ?? paragraph.indent + 2
            return row.indent == expected && couldNotHaveFitted(row)
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
                if endsRun(before: end) || runsOnIntoIndentedText(start..<end) { return end }
                noRunBefore = end
                return nil
            }

            /// Whether the centered rows `run`, which no blank row follows, are
            /// a heading that goes straight on into the first row of a
            /// paragraph: a few rows of text (rules apart) followed by a row
            /// that starts in cell 3, as a transcriber who sets "Chapter 1"
            /// on the line above its text writes it.
            func runsOnIntoIndentedText(_ run: Range<Int>) -> Bool {
                guard run.upperBound < rows.count, rows[run.upperBound].indent == 2 else { return false }
                let textRows = rows[run].filter { !BraillePageAnalyzer.isRule($0, in: book.cells) }.count
                return textRows >= 1 && textRows <= BraillePageAnalyzer.maxRunOnHeadingRows
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
                    noteRow(onPage: page, atCell: heading.text.nextRowOffset)
                    open?.text.append(row: book.cells[row.content.range])
                    previousWasHeading = true
                    index += 1
                    continue
                }
                // 2. A row that goes on the open paragraph, a list item's runover
                // among them. It comes before the headings, so that a runover at
                // a page's top, in the cell where a heading of level 2 or 3
                // starts, is not read as one.
                if let paragraph = open, paragraph.headingLevel == nil, goesOn(row, paragraph, atPageTop: index == 0) {
                    noteRow(onPage: page, atCell: paragraph.text.nextRowOffset)
                    open?.runoverIndent = paragraph.runoverIndent ?? row.indent
                    open?.text.append(row: book.cells[row.content.range])
                    noteLastRow(row)
                    index += 1
                    continue
                }
                // 3 and 4. A heading, at a row that may begin one: after a blank
                // row, at the top of a page, or after another heading.
                if startsAfterBreak(index) || previousWasHeading {
                    // 3. A centered heading: the run of centered rows here, every
                    // indent counted (a line with a margin of 4 or 6 cells is
                    // as centered as any other). It is one level-1 heading,
                    // unless all its rows share the indent of a cell-5 or
                    // cell-7 heading, which a long heading in cell 5 or 7
                    // also measures as (it ends within a cell of the right
                    // margin that its indent has on the left): that is rule 4's.
                    if let end = centeredRun(from: index),
                       !(isCellFiveOrSeven(row) && rows[index..<end].allSatisfy({ $0.indent == row.indent })) {
                        closeOpenBlock()
                        // A rule is no part of the heading's text; a run of rules
                        // alone makes no heading.
                        let textRows = rows[index..<end].filter { !BraillePageAnalyzer.isRule($0, in: book.cells) }
                        guard !textRows.isEmpty else {
                            previousWasHeading = false
                            index = end
                            continue
                        }
                        noteRow(onPage: page, atCell: 0)
                        var text = newText()
                        for line in textRows { text.append(row: book.cells[line.content.range]) }
                        blocks.append(.heading(level: 1, text: finish(&text)))
                        previousWasHeading = true
                        index = end
                        continue
                    }
                    // 4. A cell-5 (level 2) or cell-7 (level 3) heading, which
                    // takes the following rows of its indent.
                    if isCellFiveOrSeven(row) {
                        closeOpenBlock()
                        noteRow(onPage: page, atCell: 0)
                        open = OpenBlock(headingLevel: row.indent == cellFiveIndent ? 2 : 3, indent: row.indent,
                                         text: newText())
                        open?.text.append(row: book.cells[row.content.range])
                        previousWasHeading = true
                        index += 1
                        continue
                    }
                }
                // 5. Any other row starts a paragraph (one that goes on the
                // open paragraph was taken by rule 2).
                closeOpenBlock()
                noteRow(onPage: page, atCell: 0)
                open = OpenBlock(headingLevel: nil, indent: row.indent, text: newText())
                open?.text.append(row: book.cells[row.content.range])
                noteLastRow(row)
                previousWasHeading = false
                index += 1
            }
        }

        /// Ends the last block. Returns the blocks and, for each page, where
        /// its first row landed: the first block that has a row there, and
        /// the cell of that block the row begins at (nil for a page with no text).
        mutating func finish() -> (blocks: [BrailleBlock], firstPlaceOfPage: [PagePlace?]) {
            closeOpenBlock()
            return (blocks, firstPlaceOfPage)
        }
    }
}

// MARK: - Page labels

extension BraillePageNumbers {
    /// The page's label in the reader (PG12): its braille page number read
    /// as print, as "⠼⠁⠃" reads "12" and "⠏⠼⠁" reads "p1"
    /// (`printLabel(of:)`). Nil for a page without a braille page number, or
    /// with one that reading does not know, which the reader labels by the
    /// page's place among the file's pages instead.
    var braillePageLabel: String? {
        braillePageNumber.flatMap(Self.printLabel(of:))
    }

    /// The print that the number word `number` writes, read the same way in
    /// every English braille code, since a page number uses only the cells
    /// UEB and EBAE share: nil for anything else.
    ///
    /// The word is read cell by cell, as its North American Braille ASCII
    /// (`SevenBitBrailleTable.northAmerican`), in three parts:
    /// 1. letters before the number, such as the "p" of a preliminary page
    ///    ("⠏⠼⠁", p1) or the "t" of a transcriber's page;
    /// 2. the number sign and at least one digit, a to j for 1 to 9 and 0;
    /// 3. letters after it, such as the "a" of "1a": a letter sign (⠰) before
    ///    one of a to j, which would otherwise be a digit, or any of k to z,
    ///    which ends the number by itself.
    ///
    /// A capital sign (⠠) before a letter makes it a capital, and ends the
    /// number's digits. Letters are lowercase otherwise. A word with a second
    /// number, a cell outside these, an indicator with no letter after it, or
    /// no digit at all is not read: a reading that guessed could name a page
    /// wrongly, while the page's place names it rightly.
    static func printLabel(of number: String) -> String? {
        var label = ""
        // While the number's digits go on: after the number sign, until a
        // cell that is no digit.
        var inNumber = false
        // Whether a number sign and a digit after it were read.
        var readNumber = false
        // An indicator waiting for the letter it applies to.
        var capitalizesNext = false
        var letterSignWaits = false
        for scalar in number.unicodeScalars {
            // North American Braille ASCII's letters only name the cells
            // here, whatever characters the book's file wrote them with
            // (`BrailleFileCode`, research section 8.7): the cells are what
            // count, so a Eurobraille book's pages get the same labels.
            guard let byte = SevenBitBrailleTable.northAmerican.byte(forCell: scalar) else { return nil }
            switch byte {
            case UInt8(ascii: "#"):
                // The number sign: one number in a word, and no indicator
                // waiting for a letter before it.
                guard !readNumber, !inNumber, !capitalizesNext, !letterSignWaits else { return nil }
                inNumber = true
            case UInt8(ascii: "A")...UInt8(ascii: "J") where inNumber:
                // A digit: "A" (⠁) is 1, up to "I" (⠊), 9; "J" (⠚) is 0.
                let digit = byte == UInt8(ascii: "J") ? UInt8(ascii: "0") : byte - UInt8(ascii: "A") + UInt8(ascii: "1")
                label.unicodeScalars.append(Unicode.Scalar(digit))
                readNumber = true
            case UInt8(ascii: ","):
                // The capital sign, which ends the digits; never straight
                // after the number sign, nor after another indicator.
                guard !capitalizesNext, !letterSignWaits, !(inNumber && !readNumber) else { return nil }
                inNumber = false
                capitalizesNext = true
            case UInt8(ascii: ";"):
                // The letter sign: only after the digits, which it ends.
                guard inNumber, readNumber else { return nil }
                inNumber = false
                letterSignWaits = true
            case UInt8(ascii: "A")...UInt8(ascii: "Z"):
                // A letter. In the number, a to j were digits (above), so
                // this is k to z, which ends the number, and only after a digit.
                if inNumber {
                    guard readNumber else { return nil }
                    inNumber = false
                }
                // Braille ASCII writes letters in capitals; print them in
                // lowercase unless a capital sign came first.
                let letter = capitalizesNext ? byte : byte + (UInt8(ascii: "a") - UInt8(ascii: "A"))
                label.unicodeScalars.append(Unicode.Scalar(letter))
                capitalizesNext = false
                letterSignWaits = false
            default:
                return nil
            }
        }
        guard readNumber, !capitalizesNext, !letterSignWaits else { return nil }
        return label
    }
}
