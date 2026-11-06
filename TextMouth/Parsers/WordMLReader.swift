import Foundation

// MARK: - The Reader of a Word 2003 XML Document

/// Reads a Word 2003 XML document (FMT53), `w:wordDocument`, into the blocks
/// `RTFHTMLWriter` writes, by the one policy of TextMouth's document readers
/// (the same as `ODTContentReader` keeps, and `OfficeBlockWriter` gathers):
/// - headings are the paragraphs whose style is "heading 1" to "heading 9"
///   (or based on one), or that carry an outline level; a document that names
///   none keeps the headings found by size;
/// - bold and italic are `w:b` and `w:i`, through the styles; a direct
///   property wins over a character style, and that over the paragraph's;
/// - lists are `w:listPr` paragraphs, numbered or bulleted by `w:lists` (or
///   else by the mark `wx:t` shows), and a bullet and tab that begin a
///   paragraph, which is how textutil writes a list, make it a bullet item;
/// - hidden text (`w:vanish`) and tracked deletions (an `aml:annotation` of
///   type Word.Deletion, and `w:delText`) are not read; insertions are;
///   comments, headers, and footers are not read; the body of a footnote or
///   endnote follows the main text; text boxes are read in place; a field is
///   read for its result (`w:instrText` never);
/// - pages begin at `w:br w:type="page"` and `w:pageBreakBefore`, direct or by
///   style.
///
/// Section breaks begin no page: a section's type is stated at its end, which
/// would need a second pass over the document, and textutil's reading loses
/// them too.
final class WordMLReader: OfficeXMLReader {
    /// The prefix each Word 2003 XML namespace is read as.
    fileprivate static let usualPrefixes: [String: String] = [
        "http://schemas.microsoft.com/office/word/2003/wordml": "w",
        "http://schemas.microsoft.com/office/word/2003/auxHint": "wx",
        "http://schemas.microsoft.com/aml/2001/core": "aml",
        "urn:schemas-microsoft-com:office:office": "o",
        "urn:schemas-microsoft-com:vml": "v",
    ]

    /// The title and author the document names, empty when it names none.
    private(set) var title = ""
    private(set) var author = ""

    private let sheet = WordMLStyleSheet()
    private let writer: OfficeBlockWriter

    /// The style being defined, and its type and id.
    private var style: (type: String, id: String, style: WordMLStyle)?
    /// The list definition and level being read, in `w:lists`.
    private var listDefinition: String?
    private var listLevel: Int?
    /// The text of the title or author element being read, and whether the
    /// document's own properties (`o:DocumentProperties`) are open: a title in
    /// the custom properties is not the document's.
    private var naming: String?
    private var inDocumentProperties = false

    /// Whether each open table row is hidden (`w:trPr` holding `w:hidden`),
    /// innermost last, and whether `w:trPr` is open.
    private var rowsHidden: [Bool] = []
    private var inRowProperties = false

    /// Whether each `wx:sect` after the first begins a page (its type is not
    /// continuous), found by a first pass (`WordMLSectionScanner`), and how
    /// many have started.
    private let sectionsStartPages: [Bool]
    private var sectionsStarted = 0

    /// Whether `w:body` has begun, and whether `w:pPr` and `w:rPr` are open.
    private var inBody = false
    private var inParagraphProperties = false
    private var inRunProperties = false
    /// Whether the text of a `w:t` is being read.
    private var inText = false

    /// A paragraph whose properties are being read, and then whose runs.
    private struct OpenParagraph {
        var properties = WordMLParagraphProperties()
        /// What the paragraph's style says of its text.
        var styleRun = WordMLRunProperties()
        var isStarted = false
    }
    private var paragraphs: [OpenParagraph] = []

    /// A run: its own properties, whether its look has been taken, and
    /// whether its text is hidden.
    private struct OpenRun {
        var properties = WordMLRunProperties()
        var isStarted = false
        var isHidden = false
    }
    private var runs: [OpenRun] = []

    /// Prepares to read `data`, the document, whose sections after the first
    /// begin pages as `sectionsStartPages` says (empty when pages are not asked for).
    init(data: Data, file: String, includesPages: Bool, limit: Int64, sectionsStartPages: [Bool] = []) {
        self.sectionsStartPages = sectionsStartPages
        writer = OfficeBlockWriter(includesPages: includesPages, limit: limit)
        super.init(data: data, file: file, format: .wordml, usualPrefixes: Self.usualPrefixes)
    }

    /// The document the part read, once `read()` has returned.
    /// - Throws: `DocumentTooLargeError`.
    func finish() throws -> (blocks: [RTFBlock], pageBreaks: Int) {
        try writer.finish()
    }

    // MARK: Elements

    /// An element starts.
    override func startElement(_ name: String, attributes: [String: String]) {
        do {
            try start(name, attributes)
        } catch {
            fail(error)
        }
    }

    /// An element ends.
    override func endElement(_ name: String) {
        do {
            try end(name)
        } catch {
            fail(error)
        }
    }

    /// Text: a name's, or a `w:t`'s.
    override func characters(_ text: String) {
        do {
            if let naming {
                // A name is a few words; a part that holds more is not read further.
                if naming == "o:Title", title.utf8.count < 4_096 { title += text }
                if naming == "o:Author", author.utf8.count < 4_096 { author += text }
            } else if inText {
                try writer.addLiteral(text)
            }
        } catch {
            fail(error)
        }
    }

    /// What starting the element `name` does.
    private func start(_ name: String, _ attributes: [String: String]) throws {
        // Only a Word 2003 XML document is read.
        if depth == 1, name != "w:wordDocument" { return fail(TextutilConverter.Failure.unreadable(format)) }

        // Before the body: the names, the styles, and the lists.
        guard inBody else { return startDefinition(name, attributes) }

        // What is not read: comments, deletions, headers and footers (which
        // live in the sections' properties), and the text of deletions.
        if isSkipped(name, attributes) { return skipSubtree() }

        // Properties are read into the paragraph or the run they belong to.
        switch name {
        case "w:pPr": inParagraphProperties = true; return
        case "w:rPr": inRunProperties = true; return
        case "w:trPr": inRowProperties = true; return
        case "w:hidden" where inRowProperties:
            // A hidden row is not seen: its words are hidden text.
            if !rowsHidden.isEmpty { rowsHidden[rowsHidden.count - 1] = WordMLRunProperties.isOn(attributes) }
            return
        default: break
        }
        if inRowProperties { return }
        if inRunProperties {
            // The properties of a paragraph mark (inside `w:pPr`) are not the
            // paragraph's words'.
            if !inParagraphProperties, !runs.isEmpty { runs[runs.count - 1].properties.read(name, attributes) }
            return
        }
        if inParagraphProperties {
            if !paragraphs.isEmpty { paragraphs[paragraphs.count - 1].properties.read(name, attributes) }
            return
        }

        // Anything else inside a paragraph starts it, once its properties are read.
        try startParagraphIfNeeded()
        switch name {
        case "wx:sect":
            // A section after the first begins a page, unless it is continuous.
            sectionsStarted += 1
            if sectionsStarted > 1, sectionsStarted - 1 < sectionsStartPages.count, sectionsStartPages[sectionsStarted - 1] {
                writer.beginPage()
            }
        case "w:tr": rowsHidden.append(false)
        case "w:tc": try writer.beginCell()
        case "w:p": paragraphs.append(OpenParagraph())
        case "w:r": runs.append(OpenRun())
        case "w:t":
            try startRunIfNeeded()
            inText = !(runs.last?.isHidden ?? true)
        case "w:tab":
            try startRunIfNeeded()
            if runs.last?.isHidden == false { try writer.addLiteral("\t") }
        case "w:br", "w:cr":
            try startRunIfNeeded()
            guard runs.last?.isHidden == false else { return }
            if attributes["w:type"] == "page" {
                writer.hardPageBreak()
            } else if attributes["w:type"] != "column" {
                writer.addLineBreak()
            }
        case "w:noBreakHyphen":
            try startRunIfNeeded()
            if runs.last?.isHidden == false { try writer.addLiteral("-") }
        case "w:footnote", "w:endnote":
            try startRunIfNeeded()
            if runs.last?.isHidden == true { return skipSubtree() }
            writer.beginNote()
        case "w:pict", "w:object":
            // A drawing or text box anchored in hidden text is hidden with it.
            try startRunIfNeeded()
            if runs.last?.isHidden == true { return skipSubtree() }
        case "w:tbl": try writer.beginTable(startsPage: false, startsPageAfter: false)
        default: break
        }
    }

    /// What ending the element `name` does.
    private func end(_ name: String) throws {
        guard inBody else { return endDefinition(name) }
        switch name {
        case "w:pPr":
            inParagraphProperties = false
            try startParagraphIfNeeded()
        case "w:rPr":
            inRunProperties = false
            if !inParagraphProperties { try startRunIfNeeded() }
        case "w:t": inText = false
        case "w:r":
            if let run = runs.popLast(), run.isStarted { writer.endSpan() }
        case "w:p":
            if let paragraph = paragraphs.popLast(), paragraph.isStarted { try endParagraph() }
        case "w:footnote", "w:endnote": writer.endNote()
        case "w:trPr": inRowProperties = false
        case "w:tc": try writer.endCell()
        case "w:tr":
            _ = rowsHidden.popLast()
            try writer.endRow()
        case "w:tbl": try writer.endTable()
        default: break
        }
    }

    /// Whether the element `name` and everything in it is left unread.
    private func isSkipped(_ name: String, _ attributes: [String: String]) -> Bool {
        switch name {
        case "w:sectPr", "w:delText", "w:del", "w:moveFrom", "w:instrText", "w:hdr", "w:ftr", "w:binData", "w:docPr":
            return true
        case "aml:annotation":
            // Only an insertion holds words that are read: a deletion is gone,
            // a comment is not read, and the rest (a bookmark, a formatting
            // change) hold none.
            return attributes["w:type"] != "Word.Insertion"
        default:
            return false
        }
    }

    // MARK: Paragraphs and runs

    /// Starts the paragraph open, once its properties are known: a heading,
    /// a list item, or a paragraph of text.
    private func startParagraphIfNeeded() throws {
        guard let index = paragraphs.indices.last, !paragraphs[index].isStarted, !inParagraphProperties else { return }
        paragraphs[index].isStarted = true
        let direct = paragraphs[index].properties
        let style = sheet.resolved(type: "paragraph", id: direct.style)
        paragraphs[index].styleRun = style.run
        // An outline level of 0 to 8 is a heading; level 9 (body text) or
        // any other number is not, whatever the style says.
        let level = (direct.outline ?? style.paragraph.outline)?.headingLevel
        let kind: RTFBlockBuilder.Kind
        if let level {
            kind = .heading(level)
        } else if let listID = direct.listID ?? style.paragraph.listID {
            let level = direct.listLevel ?? style.paragraph.listLevel ?? 0
            let mark = direct.listMark ?? style.paragraph.listMark
            let numbered = sheet.isNumbered(list: listID, level: level)
                ?? mark.map { $0.first?.isLetter == true || $0.first?.isNumber == true }
                ?? false
            kind = .listItem(level: level, numbered: numbered)
        } else {
            kind = .body
        }
        // Hidden text is settled run by run (`startRunIfNeeded`), not here.
        let base = OfficeRun(size: style.run.size ?? 24).applying(bold: style.run.bold, italic: style.run.italic, size: nil)
        writer.beginParagraph(
            kind: kind, run: base, startsPage: direct.pageBreakBefore ?? style.paragraph.pageBreakBefore ?? false
        )
    }

    /// Ends the paragraph open. A paragraph that begins with a bullet and a
    /// tab, which is how textutil writes a list item, becomes a bullet item.
    private func endParagraph() throws {
        try writer.endParagraph(bulletCharacters: TextutilHTMLStructure.bulletCharacters)
    }

    /// What a toggle property comes to for a run (ECMA-376 17.7.3): the
    /// paragraph's style and the character style each say on or off, and a
    /// property both turn on is off again, but a property the run itself
    /// states is the run's. Nil when nothing states it.
    private static func toggled(paragraphStyle: Bool?, characterStyle: Bool?, direct: Bool?) -> Bool? {
        if let direct { return direct }
        guard paragraphStyle != nil || characterStyle != nil else { return nil }
        return (paragraphStyle ?? false) != (characterStyle ?? false)
    }

    /// Takes the look of the run open: the paragraph's style and the character
    /// style, by the toggle rule, then its own properties. Once.
    private func startRunIfNeeded() throws {
        guard let index = runs.indices.last, !runs[index].isStarted, !inRunProperties else { return }
        try startParagraphIfNeeded()
        runs[index].isStarted = true
        let direct = runs[index].properties
        let character = sheet.resolved(type: "character", id: direct.characterStyle).run
        let paragraphStyle = paragraphs.last?.styleRun ?? WordMLRunProperties()
        func settle(_ property: KeyPath<WordMLRunProperties, Bool?>) -> Bool? {
            Self.toggled(paragraphStyle: paragraphStyle[keyPath: property], characterStyle: character[keyPath: property], direct: direct[keyPath: property])
        }
        runs[index].isHidden = settle(\.hidden) == true || rowsHidden.contains(true)
        if runs[index].isHidden { writer.markHiddenText() }
        let size = direct.size ?? character.size ?? paragraphStyle.size
        writer.beginSpan(OfficeRun(size: size ?? 24).applying(bold: settle(\.bold) ?? false, italic: settle(\.italic) ?? false, size: nil))
    }

    // MARK: Definitions

    /// An element before the body starts: the names, the styles, the lists.
    private func startDefinition(_ name: String, _ attributes: [String: String]) {
        switch name {
        case "o:DocumentProperties": inDocumentProperties = true
        case "o:Title", "o:Author": if inDocumentProperties { naming = name }
        case "w:style":
            style = (attributes["w:type"] ?? "paragraph", attributes["w:styleId"] ?? "", WordMLStyle())
            style?.style.isDefault = attributes["w:default"].map { $0 == "on" || $0 == "1" || $0 == "true" } ?? false
        case "w:name": style?.style.name = attributes["w:val"]
        case "w:basedOn": style?.style.basedOn = attributes["w:val"]
        case "w:pPr": inParagraphProperties = true
        case "w:rPr": inRunProperties = true
        case "w:listDef": listDefinition = attributes["w:listDefId"]
        case "w:lvl": listLevel = attributes["w:ilvl"].flatMap { Int($0) }
        case "w:nfc":
            if let definition = listDefinition, let level = listLevel, let format = attributes["w:val"].flatMap({ Int($0) }) {
                sheet.addListLevel(definition: definition, level: level, numberFormat: format)
            }
        case "w:list": listDefinition = nil; currentList = attributes["w:ilfo"]
        case "w:ilst":
            if let list = currentList, let definition = attributes["w:val"] { sheet.addList(list, definition: definition) }
        case "w:body": inBody = true
        default:
            if style != nil, inRunProperties {
                style?.style.run.read(name, attributes)
            } else if style != nil, inParagraphProperties {
                style?.style.paragraph.read(name, attributes)
            }
        }
        if sheet.count > WordMLStyleSheet.maximumStyles { fail(TextutilConverter.Failure.unreadable(format)) }
    }

    /// The list (`w:list`, by `w:ilfo`) being read in `w:lists`.
    private var currentList: String?

    /// An element before the body ends.
    private func endDefinition(_ name: String) {
        switch name {
        case "o:DocumentProperties": inDocumentProperties = false
        case "o:Title", "o:Author": naming = nil
        case "w:pPr": inParagraphProperties = false
        case "w:rPr": inRunProperties = false
        case "w:style":
            if let finished = style { sheet.add(finished.style, type: finished.type, id: finished.id) }
            style = nil
            // A style is added where it ends, so this is where the limit is met.
            if sheet.count > WordMLStyleSheet.maximumStyles { fail(TextutilConverter.Failure.unreadable(format)) }
        case "w:lvl": listLevel = nil
        case "w:listDef": listDefinition = nil
        case "w:list": currentList = nil
        default: break
        }
    }
}

// MARK: - The Sections

/// A first pass over a Word 2003 XML document that finds how each of its
/// sections (`wx:sect`) begins. A section's type is stated at its end, in
/// its `w:sectPr` (`w:type`: next page is the default, then continuous, even
/// page, and odd page), after the words the section begins, so the reader
/// that writes the pages needs it beforehand.
final class WordMLSectionScanner: OfficeXMLReader {
    /// For each section in document order, whether it begins a page (its type
    /// is not continuous).
    private(set) var startsPage: [Bool] = []
    /// The sections open, innermost last: the depth each is at and its place
    /// in `startsPage`; and whether the innermost one's own `w:sectPr` is open.
    private var openSections: [(depth: Int, index: Int)] = []
    private var inSectionProperties = false

    /// The most sections noted; a document with more has pages only up to them.
    private static let mostSections = 100_000

    /// For each section of the Word 2003 XML in `data`, whether it begins a page.
    /// - Throws: whatever reading the document throws.
    static func scan(_ data: Data) throws -> [Bool] {
        let scanner = WordMLSectionScanner(
            data: data, file: "the document", format: .wordml, usualPrefixes: WordMLReader.usualPrefixes
        )
        try scanner.read()
        return scanner.startsPage
    }

    /// A section starts, or its properties, or their type.
    override func startElement(_ name: String, attributes: [String: String]) {
        switch name {
        case "wx:sect":
            if startsPage.count < Self.mostSections { startsPage.append(true) }
            openSections.append((depth, startsPage.count - 1))
        case "w:sectPr":
            // The section's own properties are its direct children.
            inSectionProperties = openSections.last.map { depth == $0.depth + 1 } ?? false
        case "w:type":
            if inSectionProperties, attributes["w:val"] == "continuous", let section = openSections.last {
                startsPage[section.index] = false
            }
        default:
            break
        }
    }

    /// A section or its properties end.
    override func endElement(_ name: String) {
        if name == "wx:sect" { _ = openSections.popLast() }
        if name == "w:sectPr" { inSectionProperties = false }
    }
}
