import Foundation

// MARK: - The Reader of content.xml

/// Reads the text of an OpenDocument document's `content.xml` (FMT27) into
/// the blocks `RTFHTMLWriter` writes: headings, paragraphs, lists, and
/// tables, with the pages, in reading order, by what a person reading the
/// document sees in its ordinary view.
///
/// What is read, and what is not, by the one policy of TextMouth's document
/// readers:
/// - hidden text is not read, in any of the forms OpenDocument has:
///   `text:display="none"` in a style, a hidden `text:section`,
///   `text:hidden-paragraph`, and `text:hidden-text`;
/// - a tracked deletion is not read (its text lives under
///   `text:tracked-changes`, which is skipped), and a tracked insertion is;
/// - the body of a footnote or endnote follows the main text, in the order
///   the file keeps them, with no heading and without its mark
///   (`text:note-citation`);
/// - comments (`office:annotation`) are not read, nor are headers and
///   footers (they live in `styles.xml`, which is read for styles alone);
/// - text boxes are read in place;
/// - a field is read for its result;
/// - the phonetic guide above a word (`text:ruby-text`) is not read, only
///   the word it guides.
///
/// The words, the pages, and the tables are gathered by `OfficeBlockWriter`,
/// which Word 2003 XML's reader uses too; this class knows OpenDocument's
/// elements and styles.
final class ODTContentReader: ODTXMLReader {
    /// The styles (from `styles.xml`, and this part's automatic styles).
    private let sheet: ODTStyleSheet
    private let collector: ODTStyleCollector

    /// Gathers the blocks.
    private let writer: OfficeBlockWriter

    /// Whether `office:text`, the body, has begun.
    private var inBody = false

    /// The most spaces one `text:s` stands for. Real documents indent a
    /// few dozen; a count past this is a hostile file's.
    private static let mostSpaces = 1_000

    /// Prepares to read `data`, the document's `content.xml`.
    init(data: Data, file: String, sheet: ODTStyleSheet, includesPages: Bool, limit: Int64) {
        self.sheet = sheet
        collector = ODTStyleCollector(sheet: sheet)
        writer = OfficeBlockWriter(includesPages: includesPages, limit: limit)
        super.init(data: data, file: file)
    }

    // MARK: The result

    /// The document the part read, once `read()` has returned: the blocks,
    /// and how many page breaks the body holds.
    /// - Throws: `DocumentTooLargeError`.
    func finish() throws -> (blocks: [RTFBlock], pageBreaks: Int) {
        try writer.finish()
    }

    // MARK: Elements

    override func startElement(_ name: String, attributes: [String: String]) {
        guard inBody else {
            // Before the body come the automatic styles.
            if name == "office:text" {
                inBody = true
            } else if ODTStyleCollector.handles(name) {
                collector.start(name, attributes: attributes)
                if sheet.count > ODTStyleSheet.maximumStyles { fail(TextutilConverter.Failure.unreadable(format)) }
            }
            return
        }
        do {
            try start(name, attributes)
        } catch {
            fail(error)
        }
    }

    override func endElement(_ name: String) {
        guard inBody else {
            collector.end(name)
            return
        }
        do {
            try end(name)
        } catch {
            fail(error)
        }
    }

    override func characters(_ text: String) {
        guard inBody else { return }
        do {
            try writer.addMarkupCharacters(text)
        } catch {
            fail(error)
        }
    }

    /// What starting the element `name` does.
    private func start(_ name: String, _ attributes: [String: String]) throws {
        // What is skipped altogether: not text, or text that is not read.
        if ODTContentReader.isSkipped(name, attributes) { return skipSubtree() }
        switch name {
        // Text
        case "text:p": try beginParagraph(isHeading: false, attributes)
        case "text:h": try beginParagraph(isHeading: true, attributes)
        case "text:span", "text:a": beginSpan(attributes)
        case "text:s":
            try writer.addLiteral(String(repeating: " ", count: min(max(attributes["text:c"].flatMap { Int($0) } ?? 1, 0), Self.mostSpaces)))
        case "text:tab": try writer.addLiteral("\t")
        case "text:line-break": writer.addLineBreak()
        case "text:soft-page-break": writer.pageBreak()
        case "text:hidden-paragraph":
            if attributes["text:is-hidden"] == "true" { writer.hideParagraph() }
        // Lists
        case "text:list", "text:ordered-list", "text:unordered-list": try beginList(name, attributes)
        case "text:list-item":
            if let last = writer.flow.lists.indices.last { writer.flow.lists[last].awaitsFirstParagraph = true }
        case "text:list-header":
            if let last = writer.flow.lists.indices.last { writer.flow.lists[last].awaitsFirstParagraph = false }
        // Tables
        case "table:table": try beginTable(attributes)
        // Text boxes
        case "draw:text-box": writer.beginTextBox()
        // Notes
        case "text:note-body": writer.beginNote()
        default:
            break
        }
    }

    /// What ending the element `name` does.
    private func end(_ name: String) throws {
        switch name {
        case "text:p", "text:h": try writer.endParagraph()
        case "text:span", "text:a": writer.endSpan()
        case "text:list", "text:ordered-list", "text:unordered-list": _ = writer.flow.lists.popLast()
        case "text:list-item": consumeFirstParagraphOfListItem()
        case "table:table-cell": try writer.endCell()
        case "table:table-row": try writer.endRow()
        case "table:table": try writer.endTable()
        case "draw:text-box": writer.endTextBox()
        case "text:note-body": writer.endNote()
        default:
            break
        }
    }

    /// Whether the element `name` and everything in it is left unread.
    private static func isSkipped(_ name: String, _ attributes: [String: String]) -> Bool {
        switch name {
        // Comments, the tracked changes (a deletion's text lives there),
        // a note's mark, and the number a heading or list item shows (the
        // converter numbers list items itself, as for every reader).
        case "office:annotation", "text:tracked-changes", "text:note-citation", "text:number":
            return true
        // The phonetic guide above a word.
        case "text:ruby-text":
            return true
        // Things that hold no text of the document: pictures, embedded
        // objects (which hold documents of their own), their titles and
        // descriptions, scripts and forms, and the cells a merged cell
        // covers.
        case "draw:image", "draw:object", "draw:object-ole", "draw:floating-frame", "draw:applet", "draw:plugin",
             "svg:title", "svg:desc", "text:script", "office:scripts", "office:forms", "office:binary-data",
             "table:covered-table-cell":
            return true
        // Hidden text: a section that is hidden, a field that hides its text,
        // and a table that is not displayed.
        case "text:section":
            return attributes["text:display"] == "none"
                || (attributes["text:display"] == "condition" && attributes["text:is-hidden"] == "true")
        case "text:hidden-text":
            return attributes["text:is-hidden"] == "true"
        case "table:table":
            return attributes["table:display"] == "false"
        default:
            // What an index is made from (its source), not what it shows.
            return name.hasPrefix("text:") && name.hasSuffix("-source")
        }
    }

    // MARK: Paragraphs

    /// A paragraph or heading starts.
    private func beginParagraph(isHeading: Bool, _ attributes: [String: String]) throws {
        let style = sheet.properties(family: "paragraph", name: attributes["text:style-name"])
        // A paragraph whose style hides its text is not read at all.
        if style.hidden == true { return skipSubtree() }

        // Whether it is a heading: `text:h`, or a paragraph whose style
        // carries an outline level.
        let kind: RTFBlockBuilder.Kind
        if isHeading || style.outlineLevel != nil {
            let level = attributes["text:outline-level"].flatMap { Int($0) } ?? style.outlineLevel
            kind = .heading(min(max(level ?? 1, 1), 6))
            consumeFirstParagraphOfListItem()
        } else {
            kind = itemKind(style) ?? .body
        }
        try writer.beginParagraph(
            kind: kind,
            run: OfficeRun(size: OfficeRun.halfPoints(sheet.defaultPointSize)).applying(style),
            startsPage: style.breaksBefore == true || style.hasMasterPage == true,
            startsPageAfter: style.breaksAfter == true
        )
    }

    /// A span or link begins: its text has the look its style gives it.
    private func beginSpan(_ attributes: [String: String]) {
        let style = sheet.properties(family: "text", name: attributes["text:style-name"])
        // Text whose style hides it is not read.
        if style.hidden == true { return skipSubtree() }
        if let run = writer.currentRun { writer.beginSpan(run.applying(style)) }
    }

    // MARK: Lists

    /// A list begins: its style is its own, or the one around it.
    private func beginList(_ name: String, _ attributes: [String: String]) throws {
        try writer.writeOutOpenParagraph()
        writer.flow.lists.append(OfficeOpenList(
            styleName: attributes["text:style-name"] ?? writer.flow.lists.last?.styleName,
            isNumbered: name == "text:ordered-list" ? true : (name == "text:unordered-list" ? false : nil)
        ))
    }

    /// Takes the mark of a list item's first paragraph.
    private func consumeFirstParagraphOfListItem() {
        if let last = writer.flow.lists.indices.last { writer.flow.lists[last].awaitsFirstParagraph = false }
    }

    /// What a paragraph of `style` becomes when it is the first of a list
    /// item: an item of the list, numbered or bulleted by the level's style.
    /// Nil when it is not, or when the level shows no mark.
    private func itemKind(_ style: ODTStyleProperties) -> RTFBlockBuilder.Kind? {
        guard let last = writer.flow.lists.indices.last, writer.flow.lists[last].awaitsFirstParagraph else { return nil }
        consumeFirstParagraphOfListItem()
        let list = writer.flow.lists[last]
        let level = last
        let marker: ODTListMarker
        if let isNumbered = list.isNumbered {
            marker = isNumbered ? .number : .bullet
        } else {
            // The level's style, else a bullet: a list that names none
            // shows its items as bullets.
            marker = sheet.marker(ofList: list.styleName ?? style.listStyleName, level: level + 1) ?? .bullet
        }
        switch marker {
        case .number: return .listItem(level: level, numbered: true)
        case .bullet: return .listItem(level: level, numbered: false)
        case .none: return nil
        }
    }

    // MARK: Tables

    /// A table begins.
    private func beginTable(_ attributes: [String: String]) throws {
        let style = sheet.properties(family: "table", name: attributes["table:style-name"])
        try writer.beginTable(
            startsPage: style.breaksBefore == true || style.hasMasterPage == true,
            startsPageAfter: style.breaksAfter == true
        )
    }
}
