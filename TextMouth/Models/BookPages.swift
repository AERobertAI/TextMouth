import Foundation

/// Where one page of a book begins (PG01): the page's label as its source
/// names it ("12", "xii", "A-3") and the place in the reading text where its
/// first word starts. A page is a navigation unit like a heading: it names a
/// place and adds no text, so it moves no saved position.
struct PageBreak: Equatable, Hashable, Sendable {
    /// The page's label, never empty.
    var label: String
    /// The chapter holding the page's first word. A parse leaves it 0 in
    /// `Chapter.pages`, as `Chapter.headings` carry 0; `DocumentContent.pages`
    /// holds each break with its chapter's index.
    var chapterIndex: Int
    /// UTF-16 offset into the chapter's reading text, at the start of the
    /// page's first word.
    var characterOffset: Int

    init(label: String, chapterIndex: Int = 0, characterOffset: Int) {
        self.label = label
        self.chapterIndex = chapterIndex
        self.characterOffset = characterOffset
    }

    /// Whether this page begins at or before a reading position. The last
    /// page satisfying this holds the position, by the same rule that finds a
    /// position's heading (`Heading.startsAtOrBefore`).
    func startsAtOrBefore(chapterIndex: Int, characterOffset: Int) -> Bool {
        self.chapterIndex < chapterIndex
            || (self.chapterIndex == chapterIndex && self.characterOffset <= characterOffset)
    }

    /// Where a page that a marker places at `offset` (UTF-16, clamped to `text`)
    /// begins: the start of its first word (PG01).
    ///
    /// At whitespace, the place moves forward past the whitespace to the next
    /// Character that is not whitespace, or to the text's end. Inside a word it
    /// moves back to the word's start. At a word's first Character, or at the
    /// text's end, it stays. An EPUB page-break element often stands just
    /// before the space that begins its page ("end.<span/> The next"), and a
    /// page can begin inside a hyphenated word; either way the page begins, for
    /// a listener, at its first whole word, so the place a move by page lands
    /// on and the page shown agree.
    static func firstWordStart(in text: String, at offset: Int) -> Int {
        let length = text.utf16Length
        let clamped = min(max(0, offset), length)
        guard clamped < length else { return length }

        var index = text.index(atUTF16Offset: clamped)
        guard text[index].isWhitespace else {
            // In a word or at its start: the reader's own snap decides.
            return ReaderViewModel.snappedWordStart(in: text, at: clamped)
        }
        // On whitespace: step forward to the next word, or to the end.
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        return text.utf16Offset(of: index)
    }
}

/// A book's pages in book order (PG01), with the lookups that turn a reading
/// position into "Page 12 of 300".
struct BookPages: Equatable, Sendable {
    /// A book without pages.
    static let none = BookPages(breaks: [])

    /// The pages, sorted by (chapter, offset, the order they were given), so
    /// pages at one place (blank pages) keep their order.
    let breaks: [PageBreak]

    /// N of "Page 12 of N": the largest label that is a whole number (only
    /// ASCII digits, and an `Int` can hold it), so a book numbered i to xiv and
    /// then 1 to 300 says "of 300"; the number of pages when no label is one;
    /// 0 with no pages.
    let total: Int

    init(breaks: [PageBreak]) {
        // Sorting the indices, not the breaks, keeps the given order among
        // equal places without relying on the sort being stable.
        self.breaks = breaks.indices.sortedStably { lhs, rhs in
            (breaks[lhs].chapterIndex, breaks[lhs].characterOffset, lhs)
                < (breaks[rhs].chapterIndex, breaks[rhs].characterOffset, rhs)
        }.map { breaks[$0] }
        total = breaks.compactMap { Self.wholeNumber($0.label) }.max() ?? breaks.count
    }

    /// Whether the book has no pages.
    var isEmpty: Bool { breaks.isEmpty }

    /// The number of pages.
    var count: Int { breaks.count }

    /// The index in `breaks` of the page holding a place: the last break at or
    /// before it, found by binary search. Nil before the first page. Where
    /// several breaks share an offset, the last of them holds the place.
    func index(ofPageAtChapter chapterIndex: Int, offset characterOffset: Int) -> Int? {
        // Find the first break that starts after the place; the one before it
        // (if any) holds the place.
        var low = 0
        var high = breaks.count
        while low < high {
            let middle = low + (high - low) / 2
            if breaks[middle].startsAtOrBefore(chapterIndex: chapterIndex, characterOffset: characterOffset) {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low > 0 ? low - 1 : nil
    }

    /// The place described by pages.
    func position(atChapter chapterIndex: Int, offset characterOffset: Int) -> PagePosition {
        PagePosition(pages: self, index: index(ofPageAtChapter: chapterIndex, offset: characterOffset))
    }

    /// The label as a whole number: nil unless it is not empty, holds only
    /// ASCII digits, and fits an `Int`. "+5", "-3", and Arabic-Indic digits
    /// are not whole numbers here.
    static func wholeNumber(_ label: String) -> Int? {
        guard !label.isEmpty, label.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) })
        else { return nil }
        return Int(label)
    }
}

/// A reading position described by the book's pages (PG01), modelled on
/// `HeadingPosition`: which page holds the place, and how many pages the book
/// has.
struct PagePosition: Equatable, Sendable {
    /// The page holding the position: the last page that starts at or before
    /// it. Nil before the first page, and in a book without pages.
    let page: PageBreak?
    /// 1-based index of `page` among the book's pages, or nil when `page` is.
    let number: Int?
    /// The number of pages in the book.
    let count: Int
    /// The book's page total (`BookPages.total`), the N of "Page 12 of N".
    let total: Int
    /// The first page's label, for "Before page i"; nil in a book without pages.
    let firstLabel: String?

    /// Describe the page at `index` of `pages` (nil for a place before the
    /// first page), as found by `BookPages.index(ofPageAtChapter:offset:)`.
    init(pages: BookPages, index: Int?) {
        // A stale or out-of-range index describes no page rather than trapping.
        let valid = index.flatMap { pages.breaks.indices.contains($0) ? $0 : nil }
        page = valid.map { pages.breaks[$0] }
        number = valid.map { $0 + 1 }
        count = pages.count
        total = pages.total
        firstLabel = pages.breaks.first?.label
    }

    /// The shared position label: "Page 12 of 300", "Before page i" before the
    /// first page, or an empty string for a book without pages (callers drop
    /// empty parts rather than speak them).
    var label: String {
        if let page { return "Page \(page.label) of \(total)" }
        if let firstLabel { return "Before page \(firstLabel)" }
        return ""
    }
}
