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
/// - the pages are written as `TextutilPageBreaks` writes textutil's.
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

    /// How text looks: bold, italic, and the size in half-points.
    private struct Appearance {
        var bold: Bool
        var italic: Bool
        var size: Int
    }

    // Pages.
    /// The numbers of the pages that begin before the next letter or digit.
    private var pendingPages: [Int] = []
    /// How many page breaks have been met.
    private var pageBreakCount = 0
    /// Whether a letter or digit has been written.
    private var wroteCountedCharacter = false

    // Fields. Each entry is true while the field is in its instruction part.
    private var fields: [Bool] = []
    /// How many of the open fields are in their instruction part: the text
    /// is dropped while this is not zero.
    private var instructionDepth = 0

    /// Whether a bulleted list is open: a `ul` whose items are the paragraphs
    /// that begin with a bullet.
    private var listIsOpen = false

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
    init(
        styles: WordStyleSheet, sections: WordSections, includesPages: Bool, outputLimit: Int,
        paragraphs: WordFormatRuns<WordParagraphFormat>, characters: WordFormatRuns<WordCharacterFormat>
    ) {
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
            try addPageBreak(at: position)
            // A section break is a paragraph's mark as well.
            if sections.endsSection(at: position) { try endParagraph(mark: unit, at: position) }
        case 0x0B:
            addLineBreak()
        case 0x09:
            // A tab reads as white space; whether it was a tab matters to a bullet.
            addWhitespace(" ", isTab: true)
        case 0x0E:
            // A column break reads as white space.
            addWhitespace(" ")
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
        if scalar.properties.isWhitespace {
            addWhitespace(scalar)
            return
        }
        let format = characters.format(at: position) ?? WordCharacterFormat()
        // A special character in the text (a symbol from a font, 0x28, which
        // is "(" otherwise) has no words to read.
        if format.isSpecial && scalar == "(" { return }
        let paragraphFormat = currentParagraphFormat(at: position)
        let appearance = appearance(of: format, in: paragraphFormat)
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
        pageBreakCount += 1
        guard pageBreakCount < TextutilPageBreaks.maximumPages else { throw PageLimitExceeded() }
        // The first break begins page 2.
        pendingPages.append(pageBreakCount + 1)
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

    /// How text with `character` in a paragraph with `paragraph` looks.
    private mutating func appearance(of character: WordCharacterFormat, in paragraph: WordParagraphFormat) -> Appearance {
        if let cache = appearanceCache, cache.style == paragraph.style, cache.format == character {
            return cache.appearance
        }
        let appearance = Appearance(
            bold: styles.isEmphasized(
                paragraphStyle: paragraph.style, characterStyle: character.style, direct: character.bold, \.bold
            ),
            italic: styles.isEmphasized(
                paragraphStyle: paragraph.style, characterStyle: character.style, direct: character.italic, \.italic
            ),
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
        paragraphCensus = WordCharacterCensus()
        paragraphLength = 0
        pendingWhitespace = ""
        previousWasSpace = true
        documentCensus.merge(census)

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
            if hasText { write("<p>" + content + "</p>\n") }
            // The mark of a cell of this table ends the cell; a cell of a
            // table inside it is only the end of a paragraph.
            if mark == 0x07, depth == 1 { closeCell() }
        } else {
            closeTable()
            if hasText {
                if let level = headingLevel(of: format) {
                    hasRealHeading = true
                    write("<h\(level)>" + content + "</h\(level)>\n")
                } else {
                    // A paragraph short enough to be a heading by its size or
                    // weight, if the document has no real headings.
                    if let item = Self.bulletItem(in: content, first: first, followedByTab: tabAfterFirst) {
                        write("<li>" + item + "</li>\n", isListItem: true)
                    } else {
                        write("<p>" + content + "</p>\n")
                        if length <= Self.longestHeading, !(length == 1 && startsWithLetter) {
                            candidates.append((blocks.count - 1, census, content))
                        }
                    }
                }
            }
        }
        guard outputSize <= outputLimit else { throw DocumentTooLargeError(limit: Int64(outputLimit)) }
    }

    /// The longest paragraph, in characters, that can be a heading by its size or weight.
    private static let longestHeading = 120

    /// Adds a complete block to the output. A list item opens the list if it
    /// is not open; any other block closes it.
    private mutating func write(_ block: String, isListItem: Bool = false) {
        if isListItem != listIsOpen {
            let tag = isListItem ? "<ul>\n" : "</ul>\n"
            blocks.append(tag)
            outputSize += tag.utf8.count
            listIsOpen = isListItem
        }
        blocks.append(block)
        outputSize += block.utf8.count
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
        if listIsOpen { write("") }
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
