import Foundation

// MARK: - The HTML Writer

/// Writes the body of the HTML document that stands for a Word 97-2003
/// document (the contract is the comment on `OwnDocumentReaders`), one
/// character at a time, in the order the characters are in the text.
///
/// The text holds its own structure in control characters: 0x0D ends a
/// paragraph, 0x07 ends a cell of a table (or, in the paragraph that ends a
/// row, the row), 0x0C is a page or section break, 0x0B a line break, and
/// 0x13, 0x14, and 0x15 begin, divide, and end a field, whose first part is
/// the instruction that makes it (its code) and whose second part is the
/// result a reader sees. The writer keeps the results and drops the
/// instructions; fields nest, so it keeps a stack.
///
/// The structure this reader reads:
/// - a paragraph in a heading style, or with an outline level of 1 to 9, is a
///   heading (`h1` to `h6`, as the DOCX reader names them), and a heading
///   carries no emphasis, since its style makes the whole line bold;
/// - other paragraphs are `p`, and bold and italic text is `strong` and `em`;
/// - the paragraphs of a table become `table`, `tr`, and `td`;
/// - the pages are written as `TextutilPageBreaks` writes textutil's;
/// - the paragraphs in lists (`sprmPIlfo`, directly or through the paragraph's
///   style) are counted as Word counts them (`WordListNumbering`), and what
///   Word shows before them and does not store in the text is written one of
///   two ways. By default the paragraph is an item of a list, nested by its
///   level: a `ul` for a bullet and an `ol` for a number, as the DOCX reader
///   reads a list, so no number is heard and a numbered heading is its words
///   alone. With `numbersAreWords` the number is written as the level's number
///   text ("A.", "1.2.3", "(b)") before the paragraph's words, in a heading as
///   in a paragraph, so a chapter-numbered book keeps its chapter numbers;
/// - hidden text (`sprmCFVanish`, through direct formatting and the
///   character and paragraph styles) and tracked deletions are not read: a
///   paragraph whose every word is hidden writes nothing, a page break inside
///   hidden text begins no page, and a hidden paragraph mark alone joins
///   nothing, so the paragraphs on either side of it stay separate.
///
/// Everything it keeps is in strings; there is no recursion, and nothing the
/// file says is used as a size or an index here.
struct WordHTMLWriter {

    // MARK: Inputs

    private let styles: WordStyleSheet
    private let sections: WordSections
    private let includesPages: Bool
    /// The most HTML the writer will write, in bytes.
    private let outputLimit: Int
    private var paragraphs: WordFormatRuns<WordParagraphFormat>.Cursor
    private var characters: WordFormatRuns<WordCharacterFormat>.Cursor
    /// Counts the numbered paragraphs, in the order they end.
    private var lists: WordListNumbering
    /// Whether a number is written as words before its paragraph, rather than
    /// the paragraph being an item of an `ol` whose number is not heard.
    private let numbersAreWords: Bool

    /// A document with more page breaks than this reader numbers has no
    /// pages (`TextutilPageBreaks.maximumPages`); the writer says so by
    /// throwing this, and the caller writes the document again without pages.
    struct PageLimitExceeded: Error {}

    /// The most nested fields the writer follows.
    private static let maximumFieldDepth = 10_000

    // MARK: Output

    /// The HTML written so far, one string for each block that is complete.
    private var blocks: [String] = []
    /// The bytes in `blocks`.
    private var outputSize = 0
    /// The paragraphs that could be headings by their size or weight, if the
    /// document has no real headings: the index of each one's block, its
    /// census, and its inline HTML.
    private var candidates: [(block: Int, census: WordCharacterCensus, content: String)] = []
    /// The census of every character of the document.
    private var documentCensus = WordCharacterCensus()
    /// Whether the document has a heading by style or outline level.
    private var hasRealHeading = false

    // The paragraph being written.
    /// Its inline HTML.
    private var paragraph = ""
    /// Whether it holds a character that is not white space.
    private var paragraphHasText = false
    /// Its census by size and weight, and the number of characters it holds
    /// (white space between words included) and its first.
    private var paragraphCensus = WordCharacterCensus()
    private var paragraphLength = 0
    private var paragraphFirst: Unicode.Scalar = " "
    /// Whether the white space that came right after its first character
    /// began with a tab: what a bullet needs, if the bullet is a dash.
    private var firstIsFollowedByTab = false
    /// Whether the white space waiting to be written began with a tab.
    private var pendingWhitespaceIsTab = false
    /// White space met since the last character that is not, written when
    /// the next one comes (and dropped at the paragraph's end), so that it
    /// falls outside the emphasis that begins or ends there.
    private var pendingWhitespace = ""
    /// Whether the last thing written to the paragraph was white space, or
    /// nothing: where a page that begins needs a space of its own.
    private var previousWasSpace = true
    /// The emphasis tags now open.
    private var boldIsOpen = false
    private var italicIsOpen = false

    // Caches of the last answers, since most characters ask what the one before did.
    private var headingCache: (format: WordParagraphFormat, level: Int?)?
    private var appearanceCache: (style: Int, format: WordCharacterFormat, appearance: Appearance)?

    /// How text looks: bold, italic, whether it is hidden, and the size in
    /// half-points.
    private struct Appearance {
        var bold: Bool
        var italic: Bool
        var hidden: Bool
        var size: Int
    }

    // Pages.
    /// Whether the current paragraph has been asked if it begins a page.
    private var askedPageBreakBefore = false
    /// The numbers of the pages that begin before the next letter or digit.
    private var pendingPages: [Int] = []
    /// How many page breaks have been met.
    private var pageBreakCount = 0
    /// Whether a letter or digit has been written.
    private(set) var wroteCountedCharacter = false

    // Fields. Each entry is true while the field is in its instruction part.
    private var fields: [Bool] = []
    /// How many of the open fields are in their instruction part: the text
    /// is dropped while this is not zero.
    private var instructionDepth = 0

    /// The lists open, outermost first: the level of their items, and whether
    /// each is an `ol` (true) or a `ul`. The last item of each is still open,
    /// since a deeper list nests in it.
    private var openLists: [(level: Int, ordered: Bool)] = []

    // Tables.
    private var tableIsOpen = false
    private var rowIsOpen = false
    private var cellIsOpen = false

    /// The high half of a surrogate pair waiting for its low half.
    private var pendingHighSurrogate: UInt16?

    // MARK: Starting

    /// A writer for a document with these properties.
    /// - Parameters:
    ///   - paragraphs: the paragraph formats by character position.
    ///   - characters: the character formats by character position.
    ///   - outputLimit: the most HTML to write; more throws `DocumentTooLargeError`.
    ///   - lists: the document's lists, for the paragraphs that are in one.
    ///   - numbersAreWords: whether a list's numbers are written as words
    ///     (`WordDocumentReader.speaksListNumbers`).
    init(
        styles: WordStyleSheet, sections: WordSections, includesPages: Bool, outputLimit: Int,
        paragraphs: WordFormatRuns<WordParagraphFormat>, characters: WordFormatRuns<WordCharacterFormat>,
        lists: WordListTables = .none, numbersAreWords: Bool = false
    ) {
        self.lists = WordListNumbering(tables: lists)
        self.numbersAreWords = numbersAreWords
        self.styles = styles
        self.sections = sections
        self.includesPages = includesPages
        self.outputLimit = outputLimit
        self.paragraphs = paragraphs.cursor()
        self.characters = characters.cursor()
    }

    // MARK: Characters

    /// Takes the UTF-16 code unit `unit` at character position `position`.
    /// Positions must not go back.
    /// - Throws: `PageLimitExceeded` or `DocumentTooLargeError`, as described
    ///   there.
    mutating func add(position: Int, unit: UInt16) throws {
        // A surrogate pair is one character; a half on its own is damage,
        // read as the replacement character.
        if let high = pendingHighSurrogate {
            pendingHighSurrogate = nil
            if (0xDC00...0xDFFF).contains(unit) {
                let value = 0x10000 + ((UInt32(high) - 0xD800) << 10) + (UInt32(unit) - 0xDC00)
                try addText(Unicode.Scalar(value) ?? "\u{FFFD}", at: position)
                return
            }
            try addText("\u{FFFD}", at: position)
        }
        if (0xD800...0xDBFF).contains(unit) {
            pendingHighSurrogate = unit
            return
        }
        if (0xDC00...0xDFFF).contains(unit) {
            try addText("\u{FFFD}", at: position)
            return
        }

        // Fields: the text of an instruction is dropped, the result kept.
        switch unit {
        case 0x13:
            guard fields.count < Self.maximumFieldDepth else { throw OLEDamage(reason: "fields nest too deep") }
            fields.append(true)
            instructionDepth += 1
            return
        case 0x14:
            if let last = fields.last, last {
                fields[fields.count - 1] = false
                instructionDepth -= 1
            }
            return
        case 0x15:
            if fields.popLast() == true { instructionDepth -= 1 }
            return
        default:
            break
        }
        guard instructionDepth == 0 else { return }

        switch unit {
        case 0x0D:
            try endParagraph(mark: unit, at: position)
        case 0x07:
            try endParagraph(mark: unit, at: position)
        case 0x0C:
            // A page break inside hidden or deleted text begins no page, but a
            // section break is a paragraph's mark all the same.
            if !isHidden(at: position) { try addPageBreak(at: position) }
            // A section break is a paragraph's mark as well.
            if sections.endsSection(at: position) { try endParagraph(mark: unit, at: position) }
        case 0x0B:
            if !isHidden(at: position) { addLineBreak() }
        case 0x09:
            // A tab reads as white space; whether it was a tab matters to a bullet.
            if !isHidden(at: position) { addWhitespace(" ", isTab: true) }
        case 0x0E:
            // A column break reads as white space.
            if !isHidden(at: position) { addWhitespace(" ") }
        case 0x1E:
            // A non-breaking hyphen.
            try addText("-", at: position)
        case 0x00..<0x20, 0x7F, 0xFFFE, 0xFFFF:
            // Pictures, objects, footnote and comment marks, and the rest
            // of the control characters have no words to read.
            break
        default:
            try addText(Unicode.Scalar(unit) ?? "\u{FFFD}", at: position)
        }
    }

    /// Writes the scalar `scalar` of the text at `position`.
    private mutating func addText(_ scalar: Unicode.Scalar, at position: Int) throws {
        let format = characters.format(at: position) ?? WordCharacterFormat()
        // Text a tracked change deleted is not in the document any more.
        if format.isDeleted { return }
        let paragraphFormat = currentParagraphFormat(at: position)
        let appearance = appearance(of: format, in: paragraphFormat)
        // Hidden text is not shown in the ordinary view, so it is not read;
        // its white space goes with it.
        if appearance.hidden { return }
        if scalar.properties.isWhitespace {
            addWhitespace(scalar)
            return
        }
        // A special character in the text (a symbol from a font, 0x28, which
        // is "(" otherwise) has no words to read.
        if format.isSpecial && scalar == "(" { return }
        // The first visible words of a paragraph decide whether it begins a
        // page, so a paragraph of hidden text begins none.
        if !askedPageBreakBefore {
            askedPageBreakBefore = true
            try beginPageIfParagraphDoes(paragraphFormat)
        }
        // A heading carries no emphasis.
        let heading = isHeading(paragraphFormat)
        let emphasis = (bold: appearance.bold && !heading, italic: appearance.italic && !heading)

        // The emphasis that ends closes before the white space that follows
        // it, and the emphasis that begins opens after it.
        if emphasis.bold != boldIsOpen || emphasis.italic != italicIsOpen { closeEmphasis() }
        let needsSeparator = !previousWasSpace && pendingWhitespace.isEmpty
        // White space that begins a paragraph is not written.
        if paragraphHasText { paragraph += pendingWhitespace }
        if !pendingWhitespace.isEmpty {
            previousWasSpace = true
            if paragraphHasText {
                if paragraphLength == 1 { firstIsFollowedByTab = pendingWhitespaceIsTab }
                paragraphLength += 1
            }
        }
        pendingWhitespace = ""
        if TextutilPageBreaks.isCounted(scalar) {
            wroteCountedCharacter = true
            if !pendingPages.isEmpty { writePendingPages(separated: needsSeparator) }
        }
        if emphasis.bold && !boldIsOpen {
            paragraph += "<strong>"
            boldIsOpen = true
        }
        if emphasis.italic && !italicIsOpen {
            paragraph += "<em>"
            italicIsOpen = true
        }
        Self.append(scalar, to: &paragraph)
        if !paragraphHasText { paragraphFirst = scalar }
        paragraphHasText = true
        paragraphLength += 1
        paragraphCensus.add(size: appearance.size, isBold: appearance.bold)
        previousWasSpace = false
    }

    /// Notes white space, written when the next character that is not white
    /// space comes. A run of it is kept as its first scalar: HTML reads it as
    /// one space, and the shared converter collapses it.
    private mutating func addWhitespace(_ scalar: Unicode.Scalar, isTab: Bool = false) {
        guard pendingWhitespace.isEmpty else { return }
        pendingWhitespace.unicodeScalars.append(scalar)
        pendingWhitespaceIsTab = isTab
    }

    /// Writes the empty page-break spans of the pages that begin here. Where
    /// the words on either side of the break would run together, one space
    /// goes in first, as `TextutilPageBreaks` does for textutil's.
    private mutating func writePendingPages(separated: Bool) {
        if separated { paragraph += " " }
        for page in pendingPages {
            paragraph += "<span role=\"\(TextutilPageBreaks.pageBreakRole)\" aria-label=\"\(page)\"></span>"
        }
        pendingPages.removeAll()
        previousWasSpace = true
    }

    /// Writes a line break.
    private mutating func addLineBreak() {
        closeEmphasis()
        pendingWhitespace = ""
        paragraph += "<br>"
        previousWasSpace = true
    }

    /// Takes a form feed: a page break, or a section break that starts a page.
    private mutating func addPageBreak(at position: Int) throws {
        addWhitespace(" ")
        guard includesPages, sections.formFeedStartsPage(at: position) else { return }
        try beginPage()
    }

    /// Begins a page before the next letter or digit.
    private mutating func beginPage() throws {
        pageBreakCount += 1
        guard pageBreakCount < TextutilPageBreaks.maximumPages else { throw PageLimitExceeded() }
        // The first break begins page 2.
        pendingPages.append(pageBreakCount + 1)
    }

    /// Begins a page before the paragraph with `format`'s first words, if it
    /// says so itself or by its style (page break before), as the DOCX reader
    /// does for `w:pageBreakBefore`. A paragraph in a table does not. No page
    /// begins when none was asked for, when no words have been written (the
    /// first page begins there already), or when a break is waiting for the
    /// same words already (a form feed, or a section break, right before).
    private mutating func beginPageIfParagraphDoes(_ format: WordParagraphFormat) throws {
        guard includesPages, wroteCountedCharacter, pendingPages.isEmpty,
              !format.isInTable, format.tableDepth == 0,
              styles.beginsPage(styleIndex: format.style, direct: format.pageBreakBefore) else { return }
        try beginPage()
    }

    // MARK: Paragraphs

    /// The format of the paragraph that holds `position`. It moves the
    /// cursor forward, as every position asked for is at or after the last.
    private mutating func currentParagraphFormat(at position: Int) -> WordParagraphFormat {
        paragraphs.format(at: position) ?? WordParagraphFormat()
    }

    /// The heading level of a paragraph with `format`, or nil.
    private mutating func headingLevel(of format: WordParagraphFormat) -> Int? {
        if let cache = headingCache, cache.format == format { return cache.level }
        let level = styles.headingLevel(styleIndex: format.style, directOutlineLevel: format.outlineLevel)
        headingCache = (format, level)
        return level
    }

    /// Whether a paragraph with `paragraph` is a heading by its style or
    /// outline level, outside a table. A heading carries no emphasis: its
    /// style bolds it all.
    private mutating func isHeading(_ paragraph: WordParagraphFormat) -> Bool {
        headingLevel(of: paragraph) != nil && !paragraph.isInTable
    }

    /// Whether the character at `position` is not shown: hidden text, or text
    /// a tracked change deleted. Asking moves the cursors forward, so
    /// `position` must not be before any earlier one asked about.
    private mutating func isHidden(at position: Int) -> Bool {
        let format = characters.format(at: position) ?? WordCharacterFormat()
        return format.isDeleted || appearance(of: format, in: currentParagraphFormat(at: position)).hidden
    }

    /// How text with `character` in a paragraph with `paragraph` looks.
    private mutating func appearance(of character: WordCharacterFormat, in paragraph: WordParagraphFormat) -> Appearance {
        if let cache = appearanceCache, cache.style == paragraph.style, cache.format == character {
            return cache.appearance
        }
        let appearance = Appearance(
            bold: styles.isToggledOn(
                paragraphStyle: paragraph.style, characterStyle: character.style, direct: character.bold, \.bold
            ),
            italic: styles.isToggledOn(
                paragraphStyle: paragraph.style, characterStyle: character.style, direct: character.italic, \.italic
            ),
            hidden: styles.hides(character, in: paragraph),
            size: styles.fontSize(paragraphStyle: paragraph.style, characterStyle: character.style, direct: character.fontSize)
        )
        appearanceCache = (paragraph.style, character, appearance)
        return appearance
    }

    /// Closes the emphasis tags that are open.
    private mutating func closeEmphasis() {
        if italicIsOpen { paragraph += "</em>" }
        if boldIsOpen { paragraph += "</strong>" }
        italicIsOpen = false
        boldIsOpen = false
    }

    /// Ends the paragraph at the mark `mark` at `position`, writing it as a
    /// heading, a paragraph, or a part of a table.
    private mutating func endParagraph(mark: UInt16, at position: Int) throws {
        let format = currentParagraphFormat(at: position)
        closeEmphasis()
        let content = paragraph
        let hasText = paragraphHasText
        let census = paragraphCensus
        let length = paragraphLength
        let startsWithLetter = paragraphFirst.properties.isAlphabetic
        let first = paragraphFirst
        let tabAfterFirst = firstIsFollowedByTab
        firstIsFollowedByTab = false
        paragraph = ""
        paragraphHasText = false
        askedPageBreakBefore = false
        paragraphCensus = WordCharacterCensus()
        paragraphLength = 0
        pendingWhitespace = ""
        previousWasSpace = true
        documentCensus.merge(census)

        // Its place in a list, if it has one. Every paragraph of a list is
        // counted, empty or not, as Word counts it. The mark that ends a row
        // is no paragraph.
        let isRowEnd = mark == 0x07 && format.isRowEnd
        let markFormat = characters.format(at: position) ?? WordCharacterFormat()
        let markIsDeleted = markFormat.isDeleted
        let marker: WordListNumbering.Marker = isRowEnd ? .none : paragraphMarker(of: format, hasText: hasText, markIsDeleted: markIsDeleted)
        let level = listLevel
        // What a number written as words says: a level's number, or the words
        // of a level that has none.
        var label = ""
        switch marker {
        case .numbered(let text), .labelled(let text): label = numbersAreWords ? text : ""
        case .bullet, .none: break
        }
        // A number written as words goes in front of the paragraph's words;
        // with no words of its own the paragraph is its number, unless its
        // mark is hidden or deleted (Word shows a numbered empty paragraph's number).
        var shown = content
        var standsAlone = false
        if !label.isEmpty {
            if hasText {
                shown = Self.inserting(Self.escaped(label) + " ", into: content)
            } else if !(markIsDeleted || styles.hides(markFormat, in: format)) {
                standsAlone = true
                shown = Self.escaped(label)
            }
        }
        // A paragraph that is an item of a list: a bullet, or a number that is not written as words.
        let itemKind: Bool? = {
            switch marker {
            case .bullet: return false
            case .numbered: return numbersAreWords ? nil : true
            case .labelled, .none: return nil
            }
        }()

        // A paragraph in a table, however deep.
        let depth = max(format.tableDepth, format.isInTable ? 1 : 0)
        if depth > 0 {
            if !tableIsOpen {
                write("<table>\n")
                tableIsOpen = true
            }
            // The mark that ends a row has no text of its own.
            if mark == 0x07, format.isRowEnd, depth == 1 {
                closeCell()
                closeRow()
                return
            }
            if !rowIsOpen {
                write("<tr>")
                rowIsOpen = true
            }
            if !cellIsOpen {
                write("<td>")
                cellIsOpen = true
            }
            if hasText || standsAlone {
                if let ordered = itemKind, hasText { writeItem(content, level: level, ordered: ordered) } else { write("<p>" + shown + "</p>\n") }
            }
            // The mark of a cell of this table ends the cell; a cell of a
            // table inside it is only the end of a paragraph.
            if mark == 0x07, depth == 1 { closeCell() }
        } else {
            closeTable()
            if standsAlone {
                write("<p>" + shown + "</p>\n")
            } else if hasText {
                if let level = headingLevel(of: format) {
                    hasRealHeading = true
                    write("<h\(level)>" + shown + "</h\(level)>\n")
                } else if let ordered = itemKind {
                    // A bullet, or a number that is not heard, is an item of a list.
                    writeItem(content, level: level, ordered: ordered)
                } else {
                    // A paragraph short enough to be a heading by its size or
                    // weight, if the document has no real headings.
                    if marker == .none, let item = Self.bulletItem(in: content, first: first, followedByTab: tabAfterFirst) {
                        writeItem(item, level: 0, ordered: false)
                    } else {
                        write("<p>" + shown + "</p>\n")
                        if length <= Self.longestHeading, !(length == 1 && startsWithLetter) {
                            candidates.append((blocks.count - 1, census, shown))
                        }
                    }
                }
            }
        }
        guard outputSize <= outputLimit else { throw DocumentTooLargeError(limit: Int64(outputLimit)) }
    }

    /// The level (0 to 8) of the list paragraph last given a marker.
    private var listLevel = 0
    /// Whether the paragraph just ended had its mark deleted by a tracked
    /// change and so is joined in the document Word keeps to the paragraph
    /// after it: that one is the same item, counted once.
    private var joinsNextToItem = false

    /// The marker of the paragraph with `format` that has words (`hasText`)
    /// or not and whose mark a tracked change deleted (`markIsDeleted`), or
    /// none when it is not counted. A paragraph with no words and a deleted
    /// mark is gone; one with words and a deleted mark is joined in the
    /// document Word keeps to the next paragraph (and the next, while their
    /// marks are deleted too), so the join is one item, counted once, with
    /// its number on the first. The words stay in their own paragraphs.
    private mutating func paragraphMarker(of format: WordParagraphFormat, hasText: Bool, markIsDeleted: Bool) -> WordListNumbering.Marker {
        if joinsNextToItem {
            joinsNextToItem = markIsDeleted
            return .none
        }
        if markIsDeleted && !hasText { return .none }
        let marker = listMarker(of: format)
        if markIsDeleted && marker != .none { joinsNextToItem = true }
        return marker
    }

    /// The marker of the paragraph with `format`, counting it in its list;
    /// `listLevel` is then its level.
    private mutating func listMarker(of format: WordParagraphFormat) -> WordListNumbering.Marker {
        guard !lists.isEmpty,
              let membership = styles.listMembership(styleIndex: format.style, listIndex: format.listIndex, listLevel: format.listLevel)
        else { return .none }
        listLevel = membership.level
        return lists.marker(instance: membership.instance, level: membership.level)
    }

    /// `content` (a paragraph's inline HTML) with `text` put before its
    /// words: after the page-break spans it begins with, so that a page
    /// begins where its number does.
    private static func inserting(_ text: String, into content: String) -> String {
        let span = "<span role=\"\(TextutilPageBreaks.pageBreakRole)\""
        var index = content.startIndex
        while content[index...].hasPrefix(span), let close = content[index...].range(of: "</span>") {
            index = close.upperBound
        }
        return String(content[..<index]) + text + String(content[index...])
    }

    /// The longest paragraph, in characters, that can be a heading by its size or weight.
    private static let longestHeading = 120

    /// Adds a complete block to the output, closing the lists that are open.
    private mutating func write(_ block: String) {
        closeLists()
        append(block: block)
    }

    /// Adds `block` to the output as it is.
    private mutating func append(block: String) {
        blocks.append(block)
        outputSize += block.utf8.count
    }

    /// Closes every list that is open.
    private mutating func closeLists() {
        while !openLists.isEmpty { closeInnermostList() }
    }

    /// Closes the innermost open list, and the item it ends with.
    private mutating func closeInnermostList() {
        guard let list = openLists.popLast() else { return }
        append(block: list.ordered ? "</li>\n</ol>\n" : "</li>\n</ul>\n")
    }

    /// Writes an item of a list whose inline HTML is `content`, at `level`
    /// (0 to 8). The lists whose items are deeper are closed; an item of the
    /// level the innermost list is at is its next item (or, when it is the
    /// other kind of list, `ol` for `ul`, begins a new list); and an item
    /// deeper than any open one begins a list nested in the open item, so a
    /// list that begins at level 3 is a list at that level, and its next
    /// items are its own.
    private mutating func writeItem(_ content: String, level: Int, ordered: Bool) {
        while let innermost = openLists.last, innermost.level > level { closeInnermostList() }
        if let innermost = openLists.last, innermost.level == level {
            if innermost.ordered == ordered {
                append(block: "</li>\n")
            } else {
                closeInnermostList()
                openList(level: level, ordered: ordered)
            }
        } else {
            openList(level: level, ordered: ordered)
        }
        append(block: "<li>" + content)
    }

    /// Opens a list at `level`.
    private mutating func openList(level: Int, ordered: Bool) {
        append(block: ordered ? "<ol>\n" : "<ul>\n")
        openLists.append((level, ordered))
    }

    /// The characters that begin a bullet only before a tab, as in textutil's
    /// rule: a line of dialogue may begin with a dash and a space.
    private static let bulletsNeedingATab: Set<Character> = ["–", "-", "*"]

    /// The inline HTML of the paragraph `content` without its bullet, when
    /// the paragraph begins with one of textutil's bullet characters
    /// (`TextutilHTMLStructure.bulletCharacters`) and white space; nil when
    /// it does not. Word writes a typed bullet as the character, a tab, and
    /// the words. A dash or an asterisk is a bullet only before a tab
    /// (`followedByTab`); a bullet glyph may be followed by a space too.
    /// - Parameter first: the paragraph's first character.
    private static func bulletItem(in content: String, first: Unicode.Scalar, followedByTab: Bool) -> String? {
        let bullet = Character(first)
        guard TextutilHTMLStructure.bulletCharacters.contains(bullet),
              !bulletsNeedingATab.contains(bullet) || followedByTab,
              content.first == bullet else { return nil }
        let rest = content.dropFirst()
        guard rest.first == " " else { return nil }
        let item = rest.drop { $0 == " " }
        return item.isEmpty ? nil : String(item)
    }

    /// Closes the cell, row, and table that are open, in that order.
    private mutating func closeTable() {
        closeCell()
        closeRow()
        if tableIsOpen { write("</table>\n") }
        tableIsOpen = false
    }

    private mutating func closeRow() {
        if rowIsOpen { write("</tr>\n") }
        rowIsOpen = false
    }

    private mutating func closeCell() {
        if cellIsOpen { write("</td>") }
        cellIsOpen = false
    }

    // MARK: Finishing

    /// Ends the text, writing any paragraph no mark ended and closing any
    /// table, and returns the body of the document: with page 1 at its
    /// start when pages are asked for and the text holds a letter or digit.
    mutating func finish(endingAt position: Int) throws -> String {
        if pendingHighSurrogate != nil {
            pendingHighSurrogate = nil
            try addText("\u{FFFD}", at: position)
        }
        if paragraphHasText || !paragraph.isEmpty { try endParagraph(mark: 0x0D, at: position) }
        closeTable()
        closeLists()
        // A document with no real headings gets the guess textutil's readers
        // make: larger paragraphs, then paragraphs wholly in bold.
        if !hasRealHeading {
            let levels = WordHeadingGuess.levels(of: candidates.map(\.census), in: documentCensus)
            for (candidate, level) in zip(candidates, levels) {
                guard let level else { continue }
                blocks[candidate.block] = "<h\(level)>" + Self.withoutEmphasis(candidate.content) + "</h\(level)>\n"
            }
        }
        let firstPage = includesPages && wroteCountedCharacter
            ? "<span role=\"\(TextutilPageBreaks.pageBreakRole)\" aria-label=\"1\"></span>"
            : ""
        return firstPage + blocks.joined()
    }

    /// `html` without its emphasis tags (the text is escaped, so these
    /// strings are never text).
    private static func withoutEmphasis(_ html: String) -> String {
        ["<strong>", "</strong>", "<em>", "</em>"].reduce(html) { $0.replacingOccurrences(of: $1, with: "") }
    }

    // MARK: Escaping

    /// Appends `scalar` to `text`, escaped for HTML text.
    private static func append(_ scalar: Unicode.Scalar, to text: inout String) {
        switch scalar {
        case "&": text += "&amp;"
        case "<": text += "&lt;"
        case ">": text += "&gt;"
        default: text.unicodeScalars.append(scalar)
        }
    }

    /// `text` escaped for HTML text and attribute values.
    static func escaped(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            if scalar == "\"" { result += "&quot;" } else { append(scalar, to: &result) }
        }
        return result
    }
}
