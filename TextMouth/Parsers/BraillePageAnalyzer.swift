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
/// The analyzer is pure: it takes pages of rows of Unicode braille, as a
/// BRF or a PEF holds them, and neither opens a file nor starts a process.
/// Everything it is given is untrusted, so every index is checked, and the
/// work is linear in the size of the input.
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

    /// The cell between words: U+2800.
    private static let blank = BrailleCells.blank
    /// The number sign, dots 3456 (U+283C).
    private static let numberSign = Unicode.Scalar(0x283C)!
    /// Dots 3-6 (U+2824), the cell a print page change line is drawn with.
    private static let changeDash = Unicode.Scalar(0x2824)!
    /// The ten digit cells, a to j: ⠁⠃⠉⠙⠑⠋⠛⠓⠊⠚.
    private static let digits: Set<Unicode.Scalar> = Set(
        ([0x2801, 0x2803, 0x2809, 0x2819, 0x2811, 0x280B, 0x281B, 0x2813, 0x280A, 0x281A] as [UInt32])
            .compactMap { Unicode.Scalar($0) })

    // MARK: Entry point

    /// The structure of the book whose pages are `pages`, each page a list of
    /// rows of Unicode braille.
    ///
    /// - Parameter formatted: false for an unformatted BRL, where every row
    ///   that is not blank is a paragraph, there are no headings, and the
    ///   book has one page with no numbers.
    static func structure(of pages: [[String]], formatted: Bool) -> BrailleStructure {
        // Row by row, as arrays of cells with each row's trailing blanks
        // dropped, so that all later work is on arrays and linear.
        let rawPages = pages.map { page in page.map(trimmedTrailingBlanks) }
        guard formatted else { return unformattedStructure(of: rawPages) }

        // The line width is measured before anything is taken out of any row.
        let width = lineWidth(of: rawPages)

        // Take each page's numbers and change lines out, keeping the rows left.
        var pageNumbers: [BraillePageNumbers] = []
        var rows: [Row] = []
        for (pageIndex, rawRows) in rawPages.enumerated() {
            let (numbers, kept) = extractNumbers(from: rawRows, width: width)
            pageNumbers.append(numbers)
            rows.append(contentsOf: kept.map { Row(cells: $0, page: pageIndex) })
        }

        // Read the blocks, then say where each page's first block is. Working
        // from the last page back, a page with no text takes the first block
        // of the next page that has some (or the count of blocks, past the end).
        let (blocks, firstBlockOfPage) = readBlocks(from: rows, width: width, pageCount: rawPages.count)
        var nextFirstBlock = blocks.count
        for index in pageNumbers.indices.reversed() {
            nextFirstBlock = firstBlockOfPage[index] ?? nextFirstBlock
            pageNumbers[index].firstBlockIndex = nextFirstBlock
        }
        return BrailleStructure(blocks: blocks, pages: pageNumbers)
    }

    /// The line width of a formatted book, held to `widthRange`: the most
    /// common length among the pages' last rows that end in a number word
    /// after at least 3 blank cells (a braille page number, as the layout
    /// writes it at the right margin), the longer length on a tie; and,
    /// when no page has such a row, the length of the longest row.
    ///
    /// The page-number column is what the width is, so one row that runs a
    /// cell past it (a stray overlong line) cannot shift it and leave the
    /// page numbers in the text.
    private static func lineWidth(of rawPages: [[[Unicode.Scalar]]]) -> Int {
        // How many pages have a numbered last row of each length.
        var numberedLengths: [Int: Int] = [:]
        var longest = 0
        for rawRows in rawPages {
            for row in rawRows { longest = max(longest, row.count) }
            if let last = rawRows.last(where: { !$0.isEmpty }), numberWordAtRight(of: last) != nil {
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
    private static func unformattedStructure(of rawPages: [[[Unicode.Scalar]]]) -> BrailleStructure {
        var blocks: [BrailleBlock] = []
        for row in rawPages.lazy.flatMap({ $0 }) {
            let text = joinedText(of: [row])
            if !text.isEmpty { blocks.append(.paragraph(text: text)) }
        }
        return BrailleStructure(blocks: blocks, pages: [BraillePageNumbers(firstBlockIndex: 0)])
    }

    // MARK: Rows

    /// One row of a formatted page that is left once the page's numbers and
    /// change lines are out: its indent, and its cells from the first to the
    /// last that is not blank.
    private struct Row {
        /// The number of blank cells before the first cell.
        let indent: Int
        /// The cells from the first not blank to the last not blank; empty for a blank row.
        let content: [Unicode.Scalar]
        /// The index of the row's page in the file.
        let page: Int

        init(cells: [Unicode.Scalar], page: Int) {
            // A row arrives without trailing blanks, so only the front is trimmed.
            let lead = cells.firstIndex { $0 != BraillePageAnalyzer.blank } ?? cells.count
            self.indent = lead
            self.content = Array(cells[lead...])
            self.page = page
        }

        var isBlank: Bool { content.isEmpty }
    }

    /// `row` with its trailing blank cells dropped.
    private static func trimmedTrailingBlanks(_ row: String) -> [Unicode.Scalar] {
        var cells = Array(row.unicodeScalars)
        while cells.last == blank { cells.removeLast() }
        return cells
    }

    // MARK: Page numbers

    /// Whether `word` is a number word: at most 8 cells, none blank, with the
    /// number sign directly followed by a digit cell. It may have letters
    /// before or after (⠏⠼⠁ is page p1, ⠁⠼⠁ page a1).
    private static func isNumberWord(_ word: ArraySlice<Unicode.Scalar>) -> Bool {
        guard !word.isEmpty, word.count <= maxNumberWordLength, !word.contains(blank) else { return false }
        return zip(word, word.dropFirst()).contains { $0 == numberSign && digits.contains($1) }
    }

    /// Whether `row` is a print page change line: its leading blanks, then at
    /// least 3 cells of dots 3-6, then directly a number word, and nothing else.
    /// Returns the number word, or nil.
    private static func changeLineNumber(of row: [Unicode.Scalar]) -> ArraySlice<Unicode.Scalar>? {
        let lead = row.firstIndex { $0 != blank } ?? row.count
        let dashEnd = row[lead...].firstIndex { $0 != changeDash } ?? row.count
        guard dashEnd - lead >= minChangeDashes else { return nil }
        let word = row[dashEnd...]
        return isNumberWord(word) ? word : nil
    }

    /// Splits a number word off the right of `row`: the word and what is left
    /// of the row before it. The word must be the row's last, end exactly at
    /// `width`, and stand after at least 3 blank cells (a word alone on a
    /// row has the whole margin before it, which is more than 3).
    private static func numberAtRight(of row: [Unicode.Scalar], width: Int)
        -> (word: ArraySlice<Unicode.Scalar>, rest: [Unicode.Scalar])? {
        guard row.count == width else { return nil }
        return numberWordAtRight(of: row)
    }

    /// `numberAtRight(of:width:)` for a row of any length: the number word
    /// that ends `row` after at least 3 blank cells, and the row before it.
    private static func numberWordAtRight(of row: [Unicode.Scalar])
        -> (word: ArraySlice<Unicode.Scalar>, rest: [Unicode.Scalar])? {
        // The last word starts after the last blank cell.
        let start = (row.lastIndex(of: blank) ?? -1) + 1
        let word = row[start...]
        guard isNumberWord(word) else { return nil }
        // Count the blank cells directly before the word.
        var gapStart = start
        while gapStart > 0, row[gapStart - 1] == blank { gapStart -= 1 }
        guard start - gapStart >= minGap else { return nil }
        return (word, Array(row[..<gapStart]))
    }

    /// Takes a page's numbers out of its rows: the braille page number from
    /// the last row, the print page number from the first, and every print
    /// page change line. Returns the numbers and the rows left, in order: a
    /// row that held nothing but a number is dropped (it is not a blank row,
    /// and must not end a paragraph that goes on over the page), a row that
    /// was blank stays blank (except at the page's top, where blank rows
    /// go), and the rows after the braille page number go.
    private static func extractNumbers(from rawRows: [[Unicode.Scalar]], width: Int)
        -> (BraillePageNumbers, [[Unicode.Scalar]]) {
        var numbers = BraillePageNumbers(firstBlockIndex: 0)
        // nil marks a row that is dropped.
        var rows: [[Unicode.Scalar]?] = rawRows
        let changeNumbers = rawRows.map(changeLineNumber(of:))

        /// Takes the number word off the right of row `index`, if it has one
        /// there, and returns it.
        func takeNumber(at index: Int?) -> String? {
            guard let index, changeNumbers[index] == nil,
                  let (word, rest) = numberAtRight(of: rawRows[index], width: width) else { return nil }
            rows[index] = rest.isEmpty ? nil : rest
            return String(String.UnicodeScalarView(word))
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
        for (index, word) in changeNumbers.enumerated() {
            guard let word else { continue }
            numbers.printPageChanges.append(String(String.UnicodeScalarView(word)))
            rows[index] = nil
        }
        // Anything after the braille page number's row is past the end of the
        // page (a reader may leave an empty piece after a file's last line
        // break), and must not end a paragraph that goes on over the page.
        if numbers.braillePageNumber != nil, let lastIndex {
            rows.removeSubrange((lastIndex + 1)...)
        }
        // BANA never starts a page with a blank line, so a blank row at the
        // top is the file's own doing: a form feed followed by a line end, or
        // on a line of its own, starts the next page with an empty row. It
        // must not end a paragraph that goes on over the page, so the blank
        // rows before the page's first row with text (after the numbers are
        // out) are dropped.
        return (numbers, Array(rows.compactMap { $0 }.drop { $0.isEmpty }))
    }

    // MARK: Blocks

    /// A block being read: a paragraph, or a heading below level 1 (a centered
    /// heading is read whole, so it is never open).
    private struct OpenBlock {
        /// 2 or 3 for a heading, nil for a paragraph.
        let headingLevel: Int?
        /// The indent of the heading's rows (its following rows must match).
        let indent: Int
        var rows: [[Unicode.Scalar]]
    }

    /// Whether `row` is centered: at least 3 blank cells on each side, the
    /// two sides differing by at most 1.
    private static func isCentered(_ row: Row, width: Int) -> Bool {
        let left = row.indent
        let right = width - row.indent - row.content.count
        return left >= minGap && right >= minGap && abs(left - right) <= 1
    }

    /// Reads the blocks from the rows of all the pages, in order. Returns the
    /// blocks and, for each page that holds text, the index of the first block
    /// that has a row there (nil for a page with no text).
    private static func readBlocks(from rows: [Row], width: Int, pageCount: Int)
        -> (blocks: [BrailleBlock], firstBlockOfPage: [Int?]) {
        var blocks: [BrailleBlock] = []
        var firstBlockOfPage = [Int?](repeating: nil, count: pageCount)
        var open: OpenBlock?
        // Whether the row before this one belonged to a heading.
        var previousWasHeading = false

        /// Ends the open block, if any.
        func closeOpenBlock() {
            guard let block = open else { return }
            let text = joinedText(of: block.rows)
            if let level = block.headingLevel {
                blocks.append(.heading(level: level, text: text))
            } else {
                blocks.append(.paragraph(text: text))
            }
            open = nil
        }
        /// Notes that row `index` belongs to the block that will have index
        /// `blocks.count` once it closes: the open block, or a new one.
        func noteRow(_ index: Int) {
            let page = rows[index].page
            if firstBlockOfPage.indices.contains(page), firstBlockOfPage[page] == nil {
                firstBlockOfPage[page] = blocks.count
            }
        }
        /// Whether row `index` comes after a blank row, the top of its page,
        /// or the start of the book.
        func startsAfterBreak(_ index: Int) -> Bool {
            index == 0 || rows[index - 1].isBlank || rows[index - 1].page != rows[index].page
        }
        /// Whether row `index`, as the first row after a run, is a blank row,
        /// on a later page than the run, or past the end of the book.
        func endsRun(before index: Int) -> Bool {
            index >= rows.count || rows[index].isBlank || rows[index].page != rows[index - 1].page
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
                noteRow(index)
                open?.rows.append(row.content)
                previousWasHeading = true
                index += 1
                continue
            }
            // 2. A centered heading: a run of centered rows, set apart on both ends.
            if startsAfterBreak(index), isCentered(row, width: width) {
                var end = index
                while end < rows.count, rows[end].page == row.page, !rows[end].isBlank,
                      isCentered(rows[end], width: width) { end += 1 }
                if endsRun(before: end) {
                    closeOpenBlock()
                    noteRow(index)
                    blocks.append(.heading(level: 1, text: joinedText(of: rows[index..<end].map(\.content))))
                    previousWasHeading = true
                    index = end
                    continue
                }
            }
            // 3. A cell-5 (level 2) or cell-7 (level 3) heading.
            if (row.indent == 4 || row.indent == 6), !isCentered(row, width: width),
               startsAfterBreak(index) || previousWasHeading {
                closeOpenBlock()
                noteRow(index)
                open = OpenBlock(headingLevel: row.indent == 4 ? 2 : 3, indent: row.indent, rows: [row.content])
                previousWasHeading = true
                index += 1
                continue
            }
            // 4 and 5. A paragraph: a row of indent 0 goes on the open
            // paragraph, or starts one; any other indent starts one.
            if row.indent == 0, let paragraph = open, paragraph.headingLevel == nil {
                open?.rows.append(row.content)
            } else {
                closeOpenBlock()
                open = OpenBlock(headingLevel: nil, indent: row.indent, rows: [row.content])
            }
            noteRow(index)
            previousWasHeading = false
            index += 1
        }
        closeOpenBlock()
        return (blocks, firstBlockOfPage)
    }

    // MARK: Text

    /// The text of `rows`: the cells of each row with runs of blank cells made
    /// one, the rows joined by one blank cell, and no blank cell at either end.
    /// Built in one pass into one scalar view, so the cost is linear.
    private static func joinedText(of rows: [[Unicode.Scalar]]) -> String {
        var scalars = String.UnicodeScalarView()
        // Whether the last scalar appended was a blank (or nothing yet).
        var pendingBlank = false
        for row in rows {
            // A row break counts as a blank between words.
            pendingBlank = pendingBlank || !scalars.isEmpty
            for cell in row {
                if cell == blank {
                    pendingBlank = !scalars.isEmpty
                    continue
                }
                if pendingBlank { scalars.append(blank) }
                pendingBlank = false
                scalars.append(cell)
            }
        }
        return String(scalars)
    }
}
