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

    /// The HTML written so far: the blocks that are complete.
    private var body = ""

    // The paragraph being written.
    /// Its inline HTML.
    private var paragraph = ""
    /// Whether it holds a character that is not white space.
    private var paragraphHasText = false
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
    /// The last paragraph format seen, which the text after the last mark takes.
    private var lastParagraphFormat = WordParagraphFormat()

    // Caches of the last answers, since most characters ask what the one before did.
    private var headingCache: (format: WordParagraphFormat, level: Int?)?
    private var emphasisCache: (style: Int, format: WordCharacterFormat, bold: Bool, italic: Bool)?

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
        case 0x09, 0x0E:
            // A tab or a column break reads as white space.
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
        let emphasis = emphasis(of: format, in: paragraphFormat)

        // The emphasis that ends closes before the white space that follows
        // it, and the emphasis that begins opens after it.
        if emphasis.bold != boldIsOpen || emphasis.italic != italicIsOpen { closeEmphasis() }
        let needsSeparator = !previousWasSpace && pendingWhitespace.isEmpty
        // White space that begins a paragraph is not written.
        if paragraphHasText { paragraph += pendingWhitespace }
        if !pendingWhitespace.isEmpty { previousWasSpace = true }
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
        paragraphHasText = true
        previousWasSpace = false
    }

    /// Notes white space, written when the next character that is not white
    /// space comes. A run of it is kept as its first scalar: HTML reads it as
    /// one space, and the shared converter collapses it.
    private mutating func addWhitespace(_ scalar: Unicode.Scalar) {
        if pendingWhitespace.isEmpty { pendingWhitespace.unicodeScalars.append(scalar) }
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

    /// The format of the paragraph that holds `position`, remembered as the
    /// format of the text after the last mark.
    private mutating func currentParagraphFormat(at position: Int) -> WordParagraphFormat {
        let format = paragraphs.format(at: position) ?? WordParagraphFormat()
        lastParagraphFormat = format
        return format
    }

    /// The heading level of a paragraph with `format`, or nil.
    private mutating func headingLevel(of format: WordParagraphFormat) -> Int? {
        if let cache = headingCache, cache.format == format { return cache.level }
        let level = styles.headingLevel(styleIndex: format.style, directOutlineLevel: format.outlineLevel)
        headingCache = (format, level)
        return level
    }

    /// Whether text with `character` in a paragraph with `paragraph` is bold
    /// and italic. A heading is neither: its style bolds it all.
    private mutating func emphasis(
        of character: WordCharacterFormat, in paragraph: WordParagraphFormat
    ) -> (bold: Bool, italic: Bool) {
        if headingLevel(of: paragraph) != nil, !paragraph.isInTable { return (false, false) }
        if let cache = emphasisCache, cache.style == paragraph.style, cache.format == character {
            return (cache.bold, cache.italic)
        }
        let bold = styles.isEmphasized(
            paragraphStyle: paragraph.style, characterStyle: character.style, direct: character.bold, \.bold
        )
        let italic = styles.isEmphasized(
            paragraphStyle: paragraph.style, characterStyle: character.style, direct: character.italic, \.italic
        )
        emphasisCache = (paragraph.style, character, bold, italic)
        return (bold, italic)
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
        paragraph = ""
        paragraphHasText = false
        pendingWhitespace = ""
        previousWasSpace = true

        // A paragraph in a table, however deep.
        let depth = max(format.tableDepth, format.isInTable ? 1 : 0)
        if depth > 0 {
            if !tableIsOpen {
                body += "<table>\n"
                tableIsOpen = true
            }
            // The mark that ends a row has no text of its own.
            if mark == 0x07, format.isRowEnd, depth == 1 {
                closeCell()
                closeRow()
                return
            }
            if !rowIsOpen {
                body += "<tr>"
                rowIsOpen = true
            }
            if !cellIsOpen {
                body += "<td>"
                cellIsOpen = true
            }
            if hasText { body += "<p>" + content + "</p>\n" }
            // The mark of a cell of this table ends the cell; a cell of a
            // table inside it is only the end of a paragraph.
            if mark == 0x07, depth == 1 { closeCell() }
        } else {
            closeTable()
            if hasText {
                if let level = headingLevel(of: format) {
                    body += "<h\(level)>" + content + "</h\(level)>\n"
                } else {
                    body += "<p>" + content + "</p>\n"
                }
            }
        }
        guard body.utf8.count <= outputLimit else { throw DocumentTooLargeError(limit: Int64(outputLimit)) }
    }

    /// Closes the cell, row, and table that are open, in that order.
    private mutating func closeTable() {
        closeCell()
        closeRow()
        if tableIsOpen { body += "</table>\n" }
        tableIsOpen = false
    }

    private mutating func closeRow() {
        if rowIsOpen { body += "</tr>\n" }
        rowIsOpen = false
    }

    private mutating func closeCell() {
        if cellIsOpen { body += "</td>" }
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
        let firstPage = includesPages && wroteCountedCharacter
            ? "<span role=\"\(TextutilPageBreaks.pageBreakRole)\" aria-label=\"1\"></span>"
            : ""
        return firstPage + body
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
