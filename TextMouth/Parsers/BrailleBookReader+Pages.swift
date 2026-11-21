import Foundation

/// The pages of a braille book in the Markdown it is read into (PG12).
///
/// A braille book's page is the braille page, the file's own: every BRF and
/// PEF has it, and it is what an embosser or a braille display counts (the
/// user's answer to question 2 of `humanQuestions/2026-10-21.md`). Each page
/// becomes a page marker in content.md (`MarkdownPageMarker`) where its first
/// row's first word is read, labelled by its braille page number read as
/// print (`BraillePageNumbers.braillePageLabel`), or by its place among the
/// file's pages when it has none that reads. A BRL has no pages, and gets none.
///
/// The analyzer says where each page begins: its first block, and the cell
/// of that block's braille its first row begins at (`BraillePageNumbers
/// .firstCellOffset`). Markers stand between block lines, never inside one,
/// so none can come between the emphasis delimiters of a line
/// (`BrailleBookReader.markdownLine(of:)`):
/// - a page that begins a block is a marker of its own before the block;
/// - a page that begins inside a paragraph, as one that goes on over a page
///   does, splits the paragraph's Markdown into lines there, each its own
///   literal with its own emphasis, the marker after the words of the line
///   before (`MarkdownMarkerWriter`). The lines are one paragraph still, read
///   with one space where they meet, as the paragraph read without pages;
/// - a heading is never split, being one line: a page that begins inside a
///   heading is a marker before it.
///
/// So pages change no word of the reading text: each block's print is the
/// one it has without pages, translated whole. Where a page begins in that
/// print is found by translating the paragraph's braille again in pieces cut
/// at each page's first cell (`places(ofCutsIn:pieces:)`). A page begins at
/// a word, after the blank cell that joins two rows, and no contraction
/// spans a blank cell, so the print of the cells before a page is the start
/// of the whole print, up to the space before the page's first word. Where a
/// piece reads otherwise, because an indicator's passage (capitals, a
/// typeface) goes on over the page and only the piece that holds the
/// indicator reads it, the page begins at the last place found before it,
/// or at the block's start: never after its first word, so going to a page
/// never skips a word of it.
extension BrailleBookReader {

    // MARK: - Where Pages Begin

    /// Where one page of a braille book begins (PG12).
    struct PageStart: Equatable {
        /// The page's marker, with its label.
        var marker: MarkdownPageMarker
        /// The block its first row belongs to; the count of blocks for a page
        /// after the last block.
        var blockIndex: Int
        /// The cell of that block's braille the page begins at: 0 at the
        /// block's start.
        var cellOffset: Int
    }

    /// The pages of the book `structure` describes, in order: where each
    /// begins, and its label, its braille page number read as print, or,
    /// when it has none that reads, its place among these pages, 1 for the
    /// first (`MarkdownPageMarker.init(label:ordinal:)`).
    ///
    /// A page with neither text nor a braille page number is left out (the
    /// review of October 24): no reader can name it and no embosser numbers
    /// it, such as the blank back of a two-sided page, or the empty page a
    /// form feed leaves at a file's start, or, followed by a line end, at its
    /// end. Counted, such a page made a book of two pages say "of 3", and a
    /// form feed before the first page made it 1, 1, 2. The places count only
    /// the pages kept, so a book without numbers reads 1 to N, "of N".
    static func pageStarts(of structure: BrailleStructure) -> [PageStart] {
        var starts: [PageStart] = []
        for page in structure.pages where page.hasText || page.braillePageNumber != nil {
            starts.append(PageStart(
                marker: MarkdownPageMarker(label: page.braillePageLabel ?? "", ordinal: starts.count + 1),
                blockIndex: page.firstBlockIndex,
                cellOffset: page.firstCellOffset
            ))
        }
        return starts
    }

    // MARK: - Translating With Pages

    /// What the helper translates for a book read with its pages, and how its
    /// print becomes Markdown (PG12). The texts are every block whole, as a
    /// book without pages sends them, then the pieces of each paragraph a page
    /// begins inside, cut at each such page's first cell, which say where in
    /// the whole paragraph's print the page begins. Without pages (no
    /// starts), the texts are the blocks alone and the Markdown is what the
    /// reader wrote before pages, byte for byte.
    struct PagedTranslation {
        /// The book's blocks, in braille.
        let blocks: [BrailleBlock]
        /// The book's pages, in order.
        let starts: [PageStart]
        /// What the helper translates, in order: the blocks, then the pieces.
        let texts: [EmphasizedText]
        /// For each block cut into pieces, by its index: where it is cut.
        private let cuts: [Int: Cuts]

        /// Where one block is cut into pieces.
        private struct Cuts {
            /// The cells the pages inside it begin at, each once, in order.
            let offsets: [Int]
            /// The index in `texts` of its first piece; the others follow it.
            let firstPiece: Int
        }

        /// The translation of `blocks` with the pages `starts`.
        init(blocks: [BrailleBlock], starts: [PageStart]) {
            self.blocks = blocks
            self.starts = starts
            var texts = blocks.map { EmphasizedText($0.text) }
            var cuts: [Int: Cuts] = [:]
            // The starts come in book order, so each block's are together.
            var first = starts.startIndex
            while first < starts.endIndex {
                let blockIndex = starts[first].blockIndex
                var end = first
                while end < starts.endIndex, starts[end].blockIndex == blockIndex { end += 1 }
                defer { first = end }
                // A heading is one line, never split; a page past the end has no block.
                guard blocks.indices.contains(blockIndex) else { continue }
                if case .heading = blocks[blockIndex] { continue }
                let cells = Array(blocks[blockIndex].text.unicodeScalars)
                let offsets = Self.cutOffsets(starts[first..<end].map(\.cellOffset), in: cells)
                guard !offsets.isEmpty else { continue }
                cuts[blockIndex] = Cuts(offsets: offsets, firstPiece: texts.count)
                texts += Self.pieces(of: cells, cutAt: offsets).map { EmphasizedText($0) }
            }
            self.texts = texts
            self.cuts = cuts
        }

        /// The cells of `offsets` a block whose braille is `cells` can be cut
        /// at, each once, in order: inside the block, at a cell that is not
        /// blank, after a blank cell (where two rows were joined). Any other
        /// offset, which the analyzer never gives, is not cut at, and its
        /// page begins at the last place before it (`places(of:in:print:printed:)`).
        private static func cutOffsets(_ offsets: [Int], in cells: [Unicode.Scalar]) -> [Int] {
            let usable = offsets.filter { offset in
                offset > 0 && offset < cells.count
                    && cells[offset - 1] == BrailleCells.blank && cells[offset] != BrailleCells.blank
            }
            return Array(Set(usable)).sortedStably()
        }

        /// The braille `cells` cut at each of `offsets` (from `cutOffsets`),
        /// the blank cell before each cut left out: one more piece than
        /// offsets, none of them empty.
        private static func pieces(of cells: [Unicode.Scalar], cutAt offsets: [Int]) -> [String] {
            var pieces: [String] = []
            var start = 0
            for offset in offsets {
                pieces.append(String(String.UnicodeScalarView(cells[start..<(offset - 1)])))
                start = offset
            }
            pieces.append(String(String.UnicodeScalarView(cells[start...])))
            return pieces
        }

        /// The Markdown of the book from the helper's print of `texts`, in
        /// order, with each page's marker; nil when no block has any print,
        /// markers or none. A block whose print is empty is left out, its
        /// pages' markers standing where its line would have.
        func markdown(from printed: [EmphasizedText]) -> String? {
            var markdown = ""
            var wroteText = false
            /// Writes a page's marker as a block of its own.
            func writeBlockMarker(_ start: PageStart) {
                MarkdownMarkerWriter.write(start.marker.markdown, inline: false, into: &markdown)
            }
            // The next page to write.
            var next = starts.startIndex
            for (blockIndex, block) in blocks.enumerated() {
                // The pages that begin in this block (any before it, which
                // the analyzer never gives, are written here rather than lost).
                let firstHere = next
                while next < starts.endIndex, starts[next].blockIndex <= blockIndex { next += 1 }
                let pagesHere = starts[firstHere..<next]

                let whole = text(at: blockIndex, of: printed).trimmingWhitespace()
                guard !whole.text.isEmpty else {
                    pagesHere.forEach(writeBlockMarker)
                    continue
                }
                let pagePlaces = places(of: pagesHere, in: blockIndex, print: whole, printed: printed)
                // The pages that begin at the block's start, before its line.
                for (start, place) in zip(pagesHere, pagePlaces) where place == 0 {
                    writeBlockMarker(start)
                }
                MarkdownMarkerWriter.ensureBlankLine(&markdown)
                if case let .heading(level, _) = block {
                    markdown += String(repeating: "#", count: level) + " " + BrailleBookReader.markdownLine(of: whole)
                } else {
                    let inside = zip(pagesHere, pagePlaces).filter { $0.1 > 0 }.map { (start: $0.0, place: $0.1) }
                    writeParagraph(whole, pages: inside, into: &markdown)
                }
                wroteText = true
            }
            // The pages after the last block.
            starts[next...].forEach(writeBlockMarker)
            return wroteText ? markdown : nil
        }

        /// Writes the paragraph `whole` into `markdown`, as lines split where
        /// each of `pages` begins: each page with the offset in `whole` of the
        /// one space it begins after, in order. Each line is its own literal
        /// with its own emphasis, and the markers of the pages that begin at
        /// its end follow its words, before the line break.
        private func writeParagraph(
            _ whole: EmphasizedText,
            pages: [(start: PageStart, place: Int)],
            into markdown: inout String
        ) {
            let scalars = Array(whole.text.unicodeScalars)
            var lineStart = 0
            var index = pages.startIndex
            while index < pages.endIndex {
                let place = pages[index].place
                markdown += BrailleBookReader.markdownLine(of: Self.slice(of: whole, scalars: scalars, lineStart..<place))
                // Every page that begins at this place, in order, its markers
                // side by side and written at once (the review of October
                // 24): the writer reads the line it adds to, so writing them
                // one by one read a line that grew with each, in time that
                // grew as their number squared, and a hostile file of form
                // feeds put a hundred thousand pages at one place.
                var markers = ""
                while index < pages.endIndex, pages[index].place == place {
                    markers += pages[index].start.marker.markdown
                    index += 1
                }
                MarkdownMarkerWriter.write(markers, inline: true, into: &markdown)
                markdown += "\n"
                lineStart = place + 1
            }
            markdown += BrailleBookReader.markdownLine(of: Self.slice(of: whole, scalars: scalars, lineStart..<scalars.count))
        }

        /// Where each of `pages`, which begin in block `blockIndex`, begins in
        /// its print `whole`: 0 at the block's start, or the offset of the one
        /// space the page begins after. A page at the block's first cell, any
        /// page in a heading, and a page whose place the pieces' print does
        /// not show begin at the last place found before them, or at 0. The
        /// places are in order, each at or after the one before.
        private func places(
            of pages: ArraySlice<PageStart>,
            in blockIndex: Int,
            print whole: EmphasizedText,
            printed: [EmphasizedText]
        ) -> [Int] {
            guard let cuts = cuts[blockIndex] else { return pages.map { _ in 0 } }
            let pieces = (0...cuts.offsets.count).map { piece in
                Array(text(at: cuts.firstPiece + piece, of: printed).trimmingWhitespace().text.unicodeScalars)
            }
            let found = BrailleBookReader.places(ofCutsIn: Array(whole.text.unicodeScalars), pieces: pieces)
            // Each cut's index by its cell, looked up at once: a search of
            // the cuts for each page took time that grew as their number
            // squared, in a paragraph a hostile file cuts at every word.
            let cutIndex = Dictionary(uniqueKeysWithValues: cuts.offsets.enumerated().map { ($0.element, $0.offset) })
            var last = 0
            return pages.map { start in
                if let cut = cutIndex[start.cellOffset], let place = found[cut] {
                    last = place
                }
                return last
            }
        }

        /// The print of text `index`, or none when the helper answered short
        /// (it never does: a short answer fails the translation).
        private func text(at index: Int, of printed: [EmphasizedText]) -> EmphasizedText {
            printed.indices.contains(index) ? printed[index] : EmphasizedText()
        }

        /// The scalars `range` of `text`, whose scalars are `scalars`, with
        /// their emphasis.
        private static func slice(of text: EmphasizedText, scalars: [Unicode.Scalar], _ range: Range<Int>) -> EmphasizedText {
            let part = String(String.UnicodeScalarView(scalars[range]))
            let emphasis = text.hasEmphasis ? Array(text.emphasis[range]) : []
            return EmphasizedText(part, emphasis: emphasis) ?? EmphasizedText(part)
        }
    }

    // MARK: - Finding a Page in the Print

    /// Where each cut between two of `pieces` falls in a paragraph's print
    /// `whole` (PG12): the offset of the one space the page begins after, or
    /// nil where the print does not show it.
    ///
    /// `whole` is the paragraph's print, trimmed, and `pieces` the print of
    /// each piece of its braille between the cuts, in order, each trimmed:
    /// one more piece than cuts. From the start, each piece must be exactly
    /// the next stretch of `whole`, followed by one space between two
    /// characters that are not white space: that space is the cut. The
    /// pieces after the first that differs (an indicator's passage, read only
    /// in the piece that holds it) are then matched from the end, each the
    /// stretch of `whole` just before the piece after it, after one such
    /// space. A cut found neither way is nil. The cuts found are in order,
    /// each after the one before.
    ///
    /// The space must be exactly one space (U+0020) between words: the
    /// reader writes a line break there, which reads as one space.
    static func places(ofCutsIn whole: [Unicode.Scalar], pieces: [[Unicode.Scalar]]) -> [Int?] {
        let cutCount = max(pieces.count - 1, 0)
        var places = [Int?](repeating: nil, count: cutCount)
        /// Whether `whole[index]` is one space with a character that is not
        /// white space on each side.
        func isLoneSpace(at index: Int) -> Bool {
            index > 0 && index < whole.count - 1 && whole[index] == " "
                && !whole[index - 1].properties.isWhitespace && !whole[index + 1].properties.isWhitespace
        }
        // From the start: piece `found` begins at `start`, and cut `found` follows it.
        var start = 0
        var found = 0
        while found < cutCount {
            let piece = pieces[found]
            let end = start + piece.count
            guard !piece.isEmpty, end < whole.count, whole[start..<end].elementsEqual(piece), isLoneSpace(at: end) else {
                break
            }
            places[found] = end
            start = end + 1
            found += 1
        }
        // From the end: piece `cut + 1` ends at `end`, and cut `cut` comes before it.
        var end = whole.count
        var cut = cutCount - 1
        while cut >= found {
            let piece = pieces[cut + 1]
            let space = end - piece.count - 1
            guard !piece.isEmpty, space >= start, whole[(space + 1)..<end].elementsEqual(piece), isLoneSpace(at: space) else {
                break
            }
            places[cut] = space
            end = space
            cut -= 1
        }
        return places
    }
}
