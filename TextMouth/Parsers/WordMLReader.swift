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
    private static let usualPrefixes: [String: String] = [
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
    /// The text of the title or author element being read.
    private var naming: String?

    /// Whether `w:body` has begun, and whether `w:pPr` and `w:rPr` are open.
    private var inBody = false
    private var inParagraphProperties = false
    private var inRunProperties = false
    /// Whether the text of a `w:t` is being read.
    private var inText = false

    /// A paragraph whose properties are being read, and then whose runs.
    private struct OpenParagraph {
        var properties = WordMLParagraphProperties()
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

    /// Prepares to read `data`, the document.
    init(data: Data, file: String, includesPages: Bool, limit: Int64) {
        writer = OfficeBlockWriter(includesPages: includesPages, limit: limit)
        super.init(data: data, file: file, format: .wordml, usualPrefixes: Self.usualPrefixes)
    }

    /// The document the part read, once `read()` has returned.
    /// - Throws: `DocumentTooLargeError`.
    func finish() throws -> (blocks: [RTFBlock], pageBreaks: Int) {
        try writer.finish()
    }

    // MARK: Elements

    override func startElement(_ name: String, attributes: [String: String]) {
        do {
            try start(name, attributes)
        } catch {
            fail(error)
        }
    }

    override func endElement(_ name: String) {
        do {
            try end(name)
        } catch {
            fail(error)
        }
    }

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
        default: break
        }
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
                writer.pageBreak()
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
        case "w:tc": try writer.endCell()
        case "w:tr": try writer.endRow()
        case "w:tbl": try writer.endTable()
        default: break
        }
    }

    /// Whether the element `name` and everything in it is left unread.
    private func isSkipped(_ name: String, _ attributes: [String: String]) -> Bool {
        switch name {
        case "w:sectPr", "w:delText", "w:del", "w:instrText", "w:hdr", "w:ftr", "w:binData", "w:docPr":
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
        let level = direct.outlineLevel ?? style.paragraph.outlineLevel
        let kind: RTFBlockBuilder.Kind
        if let level {
            kind = .heading(min(level, 6))
        } else if let listID = direct.listID {
            let level = direct.listLevel ?? 0
            let numbered = sheet.isNumbered(list: listID, level: level)
                ?? direct.listMark.map { $0.first?.isLetter == true || $0.first?.isNumber == true }
                ?? false
            kind = .listItem(level: level, numbered: numbered)
        } else {
            kind = .body
        }
        let base = OfficeRun(size: style.run.size ?? 24).applying(bold: style.run.bold, italic: style.run.italic, size: nil)
        try writer.beginParagraph(
            kind: kind, run: base, startsPage: direct.pageBreakBefore ?? style.paragraph.pageBreakBefore ?? false
        )
        if style.run.hidden == true { writer.hideParagraph() }
    }

    /// Ends the paragraph open. A paragraph that begins with a bullet and a
    /// tab, which is how textutil writes a list item, becomes a bullet item.
    private func endParagraph() throws {
        try writer.endParagraph(bulletCharacters: TextutilHTMLStructure.bulletCharacters)
    }

    /// Takes the look of the run open: the paragraph's, then its character
    /// style's, then its own properties. Once.
    private func startRunIfNeeded() throws {
        guard let index = runs.indices.last, !runs[index].isStarted, !inRunProperties else { return }
        try startParagraphIfNeeded()
        runs[index].isStarted = true
        let direct = runs[index].properties
        let character = sheet.resolved(type: "character", id: direct.characterStyle).run
        let own = character.overridden(by: direct)
        runs[index].isHidden = own.hidden == true
        // The paragraph's own hidden text is the paragraph's alone.
        writer.beginSpan((writer.currentRun ?? OfficeRun()).applying(bold: own.bold, italic: own.italic, size: own.size))
    }

    // MARK: Definitions

    /// An element before the body starts: the names, the styles, the lists.
    private func startDefinition(_ name: String, _ attributes: [String: String]) {
        switch name {
        case "o:Title", "o:Author": naming = name
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
        case "o:Title", "o:Author": naming = nil
        case "w:pPr": inParagraphProperties = false
        case "w:rPr": inRunProperties = false
        case "w:style":
            if let finished = style { sheet.add(finished.style, type: finished.type, id: finished.id) }
            style = nil
        case "w:lvl": listLevel = nil
        case "w:listDef": listDefinition = nil
        case "w:list": currentList = nil
        default: break
        }
    }
}
