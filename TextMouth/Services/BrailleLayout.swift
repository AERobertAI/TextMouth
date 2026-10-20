import Foundation

// MARK: - Page format

/// How braille pages are laid out (FMT22): the export's page options.
struct BraillePageFormat: Equatable, Hashable, Sendable {
    /// Cells per line, 18 to 80 (BANA's 40 by default).
    var cellsPerLine = 40
    /// Lines per page, 4 to 50 (BANA's 25 by default).
    var linesPerPage = 25
    /// Whether each page's last line carries its braille page number.
    var numbersPages = true

    /// The cells per line a page may have.
    static let cellsPerLineRange = 18...80
    /// The lines per page a page may have.
    static let linesPerPageRange = 4...50

    /// This format with each number held to its range, so that a page always
    /// has room for a margin, a centered heading, and a page number.
    var clamped: BraillePageFormat {
        var format = self
        format.cellsPerLine = min(max(cellsPerLine, Self.cellsPerLineRange.lowerBound), Self.cellsPerLineRange.upperBound)
        format.linesPerPage = min(max(linesPerPage, Self.linesPerPageRange.lowerBound), Self.linesPerPageRange.upperBound)
        return format
    }
}

// MARK: - Layout

/// Lays braille blocks out in pages as BANA's Braille Formats (2016) says
/// (FMT22, Phase A): the pages a BRF or a PEF file holds.
///
/// Pure Swift, with no file or process access. Its input is braille already
/// translated: each block's text is Unicode cells with a blank cell (U+2800)
/// between words. A scalar of the text counts as one cell; the layout looks
/// at which cell it is only to cut a word too long for a line well
/// (`cutLength(of:room:)`). Any white space in the text is treated as a
/// blank cell, so a stray newline cannot break a row.
enum BrailleLayout {
    /// A row of cells while it is built: scalars, joined into a `String` once
    /// the row is final, so that building a book's rows takes linear time.
    private typealias Row = [Unicode.Scalar]

    /// The margins BANA gives, as the number of blank cells before the text.
    private enum Margin {
        /// A paragraph's first line starts in cell 3.
        static let paragraphFirst = 2
        /// A paragraph's runover lines start in cell 1.
        static let paragraphRun = 0
        /// A level-3 heading starts in cell 5, runovers too.
        static let heading3 = 4
        /// Headings of levels 4 to 6 start in cell 7, runovers too.
        static let heading4to6 = 6
        /// A centered heading keeps at least 3 blank cells on each side.
        static let centeredSide = 3
        /// The side margin a centered heading wrapped again keeps: the
        /// first that is past both cells where a level-2 or level-3
        /// heading would start (the margins 4 and 6, below).
        static let centeredSideWhenNarrowed = 7
        /// The left margins at which a centered line would read back as a
        /// heading that starts in cell 5 or 7 (`heading3`, `heading4to6`).
        static let ambiguousForCentered: Set<Int> = [heading3, heading4to6]
    }

    /// The pages `blocks` make at `format` (held to its ranges), each exactly
    /// `linesPerPage` rows. A row is its cells with no trailing blank cells,
    /// and "" for a blank row. No blocks give no pages; a block whose text is
    /// empty or only blank cells is skipped.
    static func pages(of blocks: [BrailleBlock], format: BraillePageFormat) -> [[String]] {
        let format = format.clamped
        // Lay each block out in its own rows first; the paginator then only
        // has to place whole blocks, and look ahead from a heading.
        let laidOut = blocks.compactMap { laidOutBlock($0, width: format.cellsPerLine) }
        var paginator = Paginator(
            blocks: laidOut,
            width: format.cellsPerLine,
            linesPerPage: format.linesPerPage,
            numbersPages: format.numbersPages
        )
        return paginator.run()
    }

    /// The digit cells for 0 to 9, as braille writes them after the number
    /// sign: the letter cells a to j (1 is ⠁, 0 is ⠚).
    private static let digitCells: [Character: Unicode.Scalar] = [
        "1": "\u{2801}", "2": "\u{2803}", "3": "\u{2809}", "4": "\u{2819}", "5": "\u{2811}",
        "6": "\u{280B}", "7": "\u{281B}", "8": "\u{2813}", "9": "\u{280A}", "0": "\u{281A}",
    ]

    /// The braille page number of page `number`: the number sign ⠼ and the
    /// page's digits in the digit cells (page 12 is ⠼⠁⠃).
    static func pageNumberCells(_ number: Int) -> String {
        var scalars: Row = ["\u{283C}"]
        for digit in String(max(number, 0)) {
            if let cell = digitCells[digit] { scalars.append(cell) }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    // MARK: Laying out one block

    /// One block's rows, and how it sits among the blocks around it.
    private struct LaidOutBlock {
        /// The block's text lines, wrapped, indented, or centered.
        var rows: [Row]
        /// Whether the block is a heading, which keeps with the text after it.
        var isHeading: Bool
        /// Whether a blank line comes before the block (unless the page's top
        /// or the line above is blank already).
        var blankBefore: Bool
        /// Whether a blank line comes after the block.
        var blankAfter: Bool
    }

    /// `block` laid out in rows for lines of `width` cells, or nil when its
    /// text holds no word.
    private static func laidOutBlock(_ block: BrailleBlock, width: Int) -> LaidOutBlock? {
        let words = words(of: block.text)
        guard !words.isEmpty else { return nil }
        switch block {
        case .paragraph:
            // First line in cell 3, runovers in cell 1.
            let rows = wrap(words, width: width, firstIndent: Margin.paragraphFirst, runIndent: Margin.paragraphRun)
            return LaidOutBlock(rows: rows, isHeading: false, blankBefore: false, blankAfter: false)
        case let .listItem(depth, _):
            // First line in cell 2d-1, runovers in cell 2d+1, with the depth
            // held so that the runover indent (2d cells) is at most a third
            // of the line. A depth below 1 is read as 1.
            let heldDepth = min(max(depth, 1), max(width / 6, 1))
            let rows = wrap(words, width: width, firstIndent: 2 * heldDepth - 2, runIndent: 2 * heldDepth)
            return LaidOutBlock(rows: rows, isHeading: false, blankBefore: false, blankAfter: false)
        case let .heading(level, _):
            if level <= 2 {
                // Levels 1 and 2 are centered, in at most width-6 cells so
                // that 3 blank cells remain on each side, and have a blank
                // line before and after.
                let lines = centeredHeadingLines(words, width: width)
                let rows = lines.map { centered($0, width: width) }
                return LaidOutBlock(rows: rows, isHeading: true, blankBefore: true, blankAfter: true)
            }
            // Level 3 starts in cell 5, levels 4 to 6 (and above) in cell 7,
            // their runovers at the same cell, with a blank line before only.
            let indent = level == 3 ? Margin.heading3 : Margin.heading4to6
            let rows = wrap(words, width: width, firstIndent: indent, runIndent: indent)
            return LaidOutBlock(rows: rows, isHeading: true, blankBefore: true, blankAfter: false)
        }
    }

    /// The lines of a centered heading of `words`, before they are centered.
    ///
    /// They are wrapped at `width - 6` cells, so that 3 blank cells remain
    /// on each side. A line centered with a left margin of 4 or 6 cells
    /// would read back as a heading that starts in cell 5 or 7 (the reader
    /// decides by the indent first), which is a different level, and a
    /// heading of several lines as several. When any line would, the whole
    /// heading is wrapped again at `width - 14` cells, so that every margin
    /// is at least 7.
    ///
    /// On a narrow page a word wider than that takes its line whole (it is
    /// never cut for this), and the line may still have such a margin;
    /// `centered` then moves it a cell when it can, and otherwise the line
    /// is read back as a heading of another level, with its text whole.
    private static func centeredHeadingLines(_ words: [Row], width: Int) -> [Row] {
        let widest = width - 2 * Margin.centeredSide
        let first = wrap(words, width: widest, firstIndent: 0, runIndent: 0)
        let ambiguous = first.contains {
            Margin.ambiguousForCentered.contains(centeringPadding(of: $0, width: width))
        }
        guard ambiguous else { return first }

        // The longest word is kept whole, as far as the first width allows.
        let longestWord = min(words.map(\.count).max() ?? 1, widest)
        let narrowed = max(width - 2 * Margin.centeredSideWhenNarrowed, longestWord)
        return wrap(words, width: narrowed, firstIndent: 0, runIndent: 0)
    }

    /// The words of `text`, each a run of cells between blank cells or white
    /// space. Empty runs, from doubled blanks, are dropped.
    private static func words(of text: String) -> [Row] {
        var words: [Row] = []
        var word: Row = []
        for scalar in text.unicodeScalars {
            if scalar == BrailleCells.blank || scalar.properties.isWhitespace {
                if !word.isEmpty { words.append(word); word = [] }
            } else {
                word.append(scalar)
            }
        }
        if !word.isEmpty { words.append(word) }
        return words
    }

    /// `words` filled into lines of at most `width` cells with whole words and
    /// one blank cell between them (BANA 1.10.1: words are never divided at a
    /// line's end). The first line starts after `firstIndent` blank cells, the
    /// others after `runIndent`.
    ///
    /// The one exception is a word longer than a whole line from its own
    /// indent: it begins a line (a word that follows others begins a new
    /// one), is cut where `cutLength(of:room:)` says, and goes on at the next
    /// line's indent, as many lines as it needs. A word exactly a line long
    /// fits whole.
    private static func wrap(_ words: [Row], width: Int, firstIndent: Int, runIndent: Int) -> [Row] {
        var lines: [Row] = []
        var line = Row(repeating: BrailleCells.blank, count: firstIndent)
        // Whether the line holds a word yet (an indent alone is not one).
        var hasWord = false
        let runIndentCells = Row(repeating: BrailleCells.blank, count: runIndent)

        for word in words {
            // The word follows on the line, with a blank cell before it when
            // the line already has a word.
            let separator = hasWord ? 1 : 0
            if line.count + separator + word.count <= width {
                if hasWord { line.append(BrailleCells.blank) }
                line.append(contentsOf: word)
                hasWord = true
                continue
            }
            if hasWord {
                // It does not fit here: go to the next line. A word that
                // fits a whole line from the run indent takes it whole.
                lines.append(line)
                line = runIndentCells
                hasWord = false
                if line.count + word.count <= width {
                    line.append(contentsOf: word)
                    hasWord = true
                    continue
                }
            }
            // A word longer than a whole line from its indent: cut it to fit
            // each line and put the rest at the next indent.
            var rest = word[...]
            while line.count + rest.count > width {
                let room = max(width - line.count, 1)
                let cut = cutLength(of: rest, room: room)
                line.append(contentsOf: rest.prefix(cut))
                rest = rest.dropFirst(cut)
                lines.append(line)
                line = runIndentCells
            }
            line.append(contentsOf: rest)
            hasWord = true
        }
        lines.append(line)
        return lines
    }

    // MARK: Cutting a long word

    /// The cells of the number sign (dots 3456, U+283C), the hyphen (dots 36,
    /// U+2824), and the slash (the two cells dots 456 and dots 34, U+2838
    /// U+280C), which decide where a word too long for a line is cut.
    private enum CutCells {
        static let numberSign: Unicode.Scalar = "\u{283C}"
        static let hyphen: Unicode.Scalar = "\u{2824}"
        /// The slash's first cell (dots 456) and its second (dots 34).
        static let slashFirst: Unicode.Scalar = "\u{2838}"
        static let slashSecond: Unicode.Scalar = "\u{280C}"
        /// The cells a number holds after its number sign: the digit cells
        /// (the cells of the letters a to j), the comma, and the period.
        static let numberCells = Set("\u{2801}\u{2803}\u{2809}\u{2819}\u{2811}\u{280B}\u{281B}\u{2813}\u{280A}\u{281A}\u{2802}\u{2832}".unicodeScalars)
    }

    /// How many cells of `word`, which is longer than `room`, go on the
    /// line that has `room` cells left (FMT22, second review round, E7).
    ///
    /// - The cut falls just after a hyphen or after a slash within the room,
    ///   the last such place, so that the break reads as the print's own.
    /// - Without one, it falls at the line's end, except that it never
    ///   separates a number sign from the cells after it: when the line's last
    ///   cell would be a number sign or a cell of the number it begins, the cut
    ///   moves back to just before that number sign, unless that leaves
    ///   the line with nothing of the word. A number is one word to the
    ///   reader, and on import the cells after a stranded sign would be
    ///   read as letters ("1342" as "acdb"). For the same reason the
    ///   slash's two cells are not parted: a cut between them moves back
    ///   to just before the slash.
    ///
    /// No indicator is added at the cut, neither BANA's hyphen nor UEB's
    /// continuation indicator: the follow-up the reviewer named, to be made
    /// before narrow pages become usual. At the 40 cells BANA gives, a book
    /// has hardly a word to cut.
    /// - Returns: A number from 1 to `room`.
    private static func cutLength(of word: ArraySlice<Unicode.Scalar>, room: Int) -> Int {
        let head = Array(word.prefix(room))
        // The last place just after a hyphen or a slash, from the end.
        for end in stride(from: head.count, through: 1, by: -1) {
            let afterHyphen = head[end - 1] == CutCells.hyphen
            let afterSlash = end >= 2 && head[end - 2] == CutCells.slashFirst && head[end - 1] == CutCells.slashSecond
            if afterHyphen || afterSlash { return end }
        }
        // Else the line's end, which keeps a slash's two cells together.
        var end = head.count
        if end >= 2, head[end - 1] == CutCells.slashFirst, word.dropFirst(end).first == CutCells.slashSecond {
            end -= 1
        }
        // The cut keeps a number whole: when the last cell before it lies in a
        // number, it moves back to the number's sign, if something of the
        // word stays before the sign.
        var sign = end - 1
        while sign >= 0, CutCells.numberCells.contains(head[sign]) { sign -= 1 }
        if sign >= 1, head[sign] == CutCells.numberSign { return sign }
        return end
    }

    /// `line` centered in `width` cells: (width - length) / 2 blank cells
    /// before it, rounded down, so the extra cell of an odd difference falls
    /// on the right (BANA 4.4.2).
    ///
    /// When even that leaves a margin of 4 or 6 cells (a heading wrapped
    /// again cannot always avoid it, as a word of one of those lengths
    /// takes its line whole), an odd difference puts its extra cell on the
    /// left instead: the margin is then 5 or 7, and the line is still
    /// centered to within a cell, as the reader measures it.
    private static func centered(_ line: Row, width: Int) -> Row {
        var padding = centeringPadding(of: line, width: width)
        if Margin.ambiguousForCentered.contains(padding), (width - line.count) % 2 == 1 { padding += 1 }
        return Row(repeating: BrailleCells.blank, count: padding) + line
    }

    /// The blank cells BANA puts before `line` to center it in `width`
    /// cells: half the difference, rounded down.
    private static func centeringPadding(of line: Row, width: Int) -> Int {
        max((width - line.count) / 2, 0)
    }

    // MARK: Placing blocks on pages

    /// Places laid-out blocks on pages, one row at a time.
    private struct Paginator {
        let blocks: [LaidOutBlock]
        /// Cells per line.
        let width: Int
        let linesPerPage: Int
        let numbersPages: Bool
        /// The text rows the page being filled holds so far.
        private var current: [Row] = []
        /// The finished pages.
        private var pages: [[String]] = []

        init(blocks: [LaidOutBlock], width: Int, linesPerPage: Int, numbersPages: Bool) {
            self.blocks = blocks
            self.width = width
            self.linesPerPage = linesPerPage
            self.numbersPages = numbersPages
        }

        /// The lines of a page that hold text: all but the page-number line.
        private var usableLines: Int { numbersPages ? linesPerPage - 1 : linesPerPage }

        /// Places every block and returns the finished pages.
        mutating func run() -> [[String]] {
            for index in blocks.indices {
                let block = blocks[index]
                // A heading is never the last text on a page (BANA 4.3.9):
                // when it, its blank line after, and a line of what follows
                // do not fit in what is left, the page ends and it begins
                // the next one. The book's last block is never moved.
                if block.isHeading, index < blocks.count - 1, !current.isEmpty,
                   linesNeeded(fromHeadingAt: index) > usableLines - current.count {
                    finishPage()
                }
                if block.blankBefore { addBlank() }
                for row in block.rows { addText(row) }
                if block.blankAfter { addBlank() }
            }
            if !current.isEmpty { finishPage() }
            return pages
        }

        /// The lines that the heading at `index` and what it must stay with
        /// take if placed now: its blank line before (when one would be
        /// added), its lines, its blank line after, and further headings that
        /// follow it directly, then one line of the first block that is not a
        /// heading. Counting stops as soon as the total passes a page, since
        /// no more can be learned from it.
        private func linesNeeded(fromHeadingAt index: Int) -> Int {
            var needed = 0
            // A blank line is added only below text, so one is already
            // present at a page's top (an empty page counts as blank).
            var aboveIsBlank = current.last?.isEmpty ?? true
            for block in blocks[index...] {
                guard block.isHeading else {
                    needed += 1
                    break
                }
                if block.blankBefore && !aboveIsBlank { needed += 1 }
                needed += block.rows.count
                aboveIsBlank = false
                if block.blankAfter {
                    needed += 1
                    aboveIsBlank = true
                }
                if needed > usableLines { break }
            }
            return needed
        }

        /// Adds a blank line, unless the page is empty or full (the blank
        /// would be at a page's top) or its last line is blank (never two in
        /// a row).
        private mutating func addBlank() {
            guard let last = current.last, !last.isEmpty, current.count < usableLines else { return }
            current.append([])
        }

        /// Adds a line of text, starting a new page when the page is full.
        private mutating func addText(_ row: Row) {
            if current.count >= usableLines { finishPage() }
            current.append(row)
        }

        /// Ends the page being filled: its remaining text lines are blank and
        /// its last line carries the braille page number, when numbered.
        private mutating func finishPage() {
            var rows = current.map { String(String.UnicodeScalarView($0)) }
            rows.append(contentsOf: [String](repeating: "", count: usableLines - rows.count))
            if numbersPages {
                // The number at the right margin of the last line, with the
                // blank cells before it (at least 3, as a line has 18 cells
                // and a number rarely more than 5).
                let number = Array(BrailleLayout.pageNumberCells(pages.count + 1).unicodeScalars)
                let padding = Row(repeating: BrailleCells.blank, count: max(width - number.count, 0))
                rows.append(String(String.UnicodeScalarView(padding + number)))
            }
            pages.append(rows)
            current = []
        }
    }
}
