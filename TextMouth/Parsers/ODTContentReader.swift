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
///   `text:display="none"` in a style (or on a variable field), a hidden
///   `text:section`, `text:hidden-paragraph`, and `text:hidden-text`;
/// - a tracked deletion is not read (its text lives under
///   `text:tracked-changes`, which is skipped), and a tracked insertion is;
/// - the body of a footnote or endnote follows the main text, in the order
///   the file keeps them, with no heading and without its mark
///   (`text:note-citation`), and only if its reference is read;
/// - comments (`office:annotation`) are not read, nor are headers and
///   footers (they live in `styles.xml`, which is read for styles alone);
/// - text boxes and shapes are read right after the paragraph that holds
///   their anchor, and a picture, formula, or chart is read as its
///   description (`svg:desc`, or else `svg:title`), the only way into it for
///   a listener who cannot see it;
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

    /// Whether the body of the document has begun, and the depth of
    /// `office:body` until its first child shows which kind of document it is.
    private var inBody = false
    private var bodyDepth: Int?

    /// What encloses the text being read and may hold a description: a note,
    /// a text box, a frame, or a shape. Between its tags only white space of
    /// the markup lies, which is not part of the paragraph around it.
    private struct Anchored {
        /// The flow and the number of paragraphs open when it began; while
        /// both are unchanged, no paragraph of its own is open.
        let flow: OfficeFlow
        let paragraphCount: Int
        /// The `svg:title` and `svg:desc` it holds.
        var title = ""
        var description = ""
        /// Whether it holds a text box or paragraphs of its own: those are
        /// read, and its description, which often repeats them, is not.
        var holdsWords = false
    }
    private var anchored: [Anchored] = []
    /// The `svg:title` or `svg:desc` being read, and its text so far.
    private var describing: (name: String, text: String)?

    /// How many lists beyond the deepest read are open (see `mostListLevels`).
    private var ignoredLists = 0

    /// The most spaces one `text:s` stands for. Real documents indent a
    /// few dozen; a count past this is a hostile file's.
    private static let mostSpaces = 1_000

    /// The most levels of list read; a list nested deeper is read at the
    /// deepest level (a deep nest overflows the stack of the HTML it makes).
    private static let mostListLevels = 40

    /// The children of `office:body` that are not text documents.
    private static let notTextBodies: Set<String> = [
        "office:spreadsheet", "office:drawing", "office:presentation", "office:chart", "office:image", "office:database",
    ]

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

    /// An element starts: a style before the body, then the body's text.
    override func startElement(_ name: String, attributes: [String: String]) {
        guard inBody else {
            // The body is the first child of `office:body` that is a text
            // document (a file may name it other than `office:text`). Before
            // it come the automatic styles.
            if name == "office:body" {
                bodyDepth = depth
            } else if let bodyDepth, depth == bodyDepth + 1 {
                if Self.notTextBodies.contains(name) {
                    self.bodyDepth = nil
                } else {
                    inBody = true
                }
            } else if ODTStyleCollector.handles(name) {
                collector.start(name, attributes: attributes)
            }
            return
        }
        do {
            try start(name, attributes)
        } catch {
            fail(error)
        }
    }

    /// An element ends.
    override func endElement(_ name: String) {
        guard inBody else {
            collector.end(name)
            // A style is added where it ends, so this is where the limit is met.
            if sheet.count > ODTStyleSheet.maximumStyles { fail(TextutilConverter.Failure.unreadable(format)) }
            return
        }
        do {
            try end(name)
        } catch {
            fail(error)
        }
    }

    /// Text: a description's, or a paragraph's words. White space of the
    /// markup between a note's or a frame's tags is no part of the paragraph.
    override func characters(_ text: String) {
        guard inBody else { return }
        if var current = describing {
            // A description is a few words; a part that holds more is cut.
            if current.text.utf8.count < 4_096 { current.text += text }
            describing = current
            return
        }
        if let around = anchored.last, around.flow === writer.flow, around.paragraphCount == writer.flow.paragraphs.count {
            return
        }
        do {
            try writer.addMarkupCharacters(text)
        } catch {
            fail(error)
        }
    }

    /// What starting the element `name` does.
    private func start(_ name: String, _ attributes: [String: String]) throws {
        // What is skipped altogether: not text, or text that is not read.
        if ODTContentReader.isSkipped(name, attributes) {
            // Hidden text left out of a paragraph is noted: a paragraph that
            // then holds no words begins no page.
            if ODTContentReader.isHiddenField(name) { writer.markHiddenText() }
            return skipSubtree()
        }
        if name == "text:note" || name.hasPrefix("draw:") {
            // A note, text box, or picture anchored in hidden text is hidden with it.
            if writer.currentRun?.hidden == true {
                writer.markHiddenText()
                return skipSubtree()
            }
            anchored.append(Anchored(flow: writer.flow, paragraphCount: writer.flow.paragraphs.count))
            // A text box belongs to the frame that holds it.
            if name == "draw:text-box", anchored.count >= 2 { anchored[anchored.count - 2].holdsWords = true }
        }
        switch name {
        // Text
        case "text:p", "text:h":
            // A shape with paragraphs of its own is read through them.
            if !anchored.isEmpty { anchored[anchored.count - 1].holdsWords = true }
            try beginParagraph(isHeading: name == "text:h", attributes)
        case "text:span", "text:a": beginSpan(attributes)
        case "text:s":
            try writer.addLiteral(String(repeating: " ", count: min(max(attributes["text:c"].flatMap { Int($0) } ?? 1, 0), Self.mostSpaces)))
        case "text:tab": try writer.addLiteral("\t")
        case "text:line-break": writer.addLineBreak()
        case "text:soft-page-break": writer.softPageBreak()
        case "text:hidden-paragraph":
            writer.noteHiddenParagraphField(isHiding: attributes["text:is-hidden"] == "true")
        // Descriptions of pictures, formulas, charts, and shapes
        case "svg:title", "svg:desc": describing = (name, "")
        // Lists
        case "text:list", "text:ordered-list", "text:unordered-list": beginList(name, attributes)
        case "text:list-item":
            if let last = writer.flow.lists.indices.last { writer.flow.lists[last].awaitsFirstParagraph = true }
        case "text:list-header":
            if let last = writer.flow.lists.indices.last { writer.flow.lists[last].awaitsFirstParagraph = false }
        // Tables
        case "table:table": try beginTable(attributes)
        case "table:table-cell":
            try writer.beginCell(repeated: attributes["table:number-columns-repeated"].flatMap { Int($0) } ?? 1)
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
        case "text:list", "text:ordered-list", "text:unordered-list":
            if ignoredLists > 0 { ignoredLists -= 1 } else { _ = writer.flow.lists.popLast() }
        case "text:list-item": consumeFirstParagraphOfListItem()
        case "svg:title", "svg:desc":
            // The description belongs to the shape that holds it.
            if let finished = describing, finished.name == name, !anchored.isEmpty {
                let words = finished.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if name == "svg:title" { anchored[anchored.count - 1].title = words } else { anchored[anchored.count - 1].description = words }
            }
            describing = nil
        case "table:table-cell": try writer.endCell()
        case "table:table-row": try writer.endRow()
        case "table:table": try writer.endTable()
        case "draw:text-box": writer.endTextBox()
        case "text:note-body": writer.endNote()
        default:
            break
        }
        if name == "text:note" || name.hasPrefix("draw:") {
            guard let finished = anchored.popLast() else { return }
            try readDescription(finished)
        }
    }

    /// A picture, formula, chart, or shape is read as its description
    /// (`svg:desc`, or else `svg:title`): a paragraph after the one holding
    /// its anchor, which the guess at headings leaves alone. One with neither
    /// is silent, and so is one that holds words of its own (a text box).
    private func readDescription(_ shape: Anchored) throws {
        let words = shape.description.isEmpty ? shape.title : shape.description
        guard !words.isEmpty, !shape.holdsWords else { return }
        writer.beginParagraph(kind: .body, run: OfficeRun(size: OfficeRun.descriptionSize))
        try writer.addLiteral(words)
        try writer.endParagraph()
    }

    /// Whether `name` is a field whose hiding is noted when it hides.
    private static func isHiddenField(_ name: String) -> Bool {
        name == "text:hidden-text" || variableFields.contains(name)
    }

    /// The variable fields that `text:display="none"` hides.
    private static let variableFields: Set<String> = ["text:variable-set", "text:user-field-get", "text:variable-input"]

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
        // Things that hold no text of the document: pictures and embedded
        // objects (a frame's description is read; an object holds a document
        // of its own), a table's title and description, scripts and forms,
        // and the cells a merged cell covers.
        case "draw:image", "draw:object", "draw:object-ole", "draw:floating-frame", "draw:applet", "draw:plugin",
             "table:title", "table:desc", "text:script", "office:scripts", "office:forms", "office:binary-data",
             "table:covered-table-cell":
            return true
        // Hidden text: a section that is hidden, a field that hides its text,
        // and a table that is not displayed.
        case "text:section":
            return attributes["text:display"] == "none"
                || (attributes["text:display"] == "condition" && attributes["text:is-hidden"] == "true")
        case "text:hidden-text":
            return attributes["text:is-hidden"] == "true"
        case _ where variableFields.contains(name):
            return attributes["text:display"] == "none"
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

        // Whether it is a heading: `text:h`, or a paragraph whose style
        // carries an outline level (an empty one carries none).
        let styleLevel = (style.outlineLevel ?? 0) > 0 ? style.outlineLevel : nil
        let kind: RTFBlockBuilder.Kind
        if isHeading || styleLevel != nil {
            let level = attributes["text:outline-level"].flatMap { Int($0) } ?? styleLevel
            kind = .heading(min(max(level ?? 1, 1), 6))
            consumeFirstParagraphOfListItem()
        } else {
            kind = itemKind(style) ?? .body
        }
        // A style that hides the paragraph's text hides it unless a span
        // shows it again (`text:display="true"`).
        writer.beginParagraph(
            kind: kind,
            run: OfficeRun(size: OfficeRun.halfPoints(sheet.defaultPointSize)).applying(style),
            startsPage: style.breaksBefore == true || style.hasMasterPage == true,
            startsPageAfter: style.breaksAfter == true,
            isHiddenByStyle: style.hidden == true
        )
    }

    /// A span or link begins: its text has the look its style gives it.
    private func beginSpan(_ attributes: [String: String]) {
        let style = sheet.properties(family: "text", name: attributes["text:style-name"])
        // Text whose style hides it is not read.
        if style.hidden == true {
            writer.markHiddenText()
            return skipSubtree()
        }
        if let run = writer.currentRun { writer.beginSpan(run.applying(style)) }
    }

    // MARK: Lists

    /// A list begins: its style is its own, or the one around it.
    private func beginList(_ name: String, _ attributes: [String: String]) {
        guard writer.flow.lists.count < Self.mostListLevels else {
            ignoredLists += 1
            return
        }
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
