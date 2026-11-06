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
/// The paragraphs of a document are kept in `ODTFlow`s: one for the main
/// text, one for the notes. A paragraph is held until it ends, so that one
/// that turns out to be hidden is dropped whole.
final class ODTContentReader: ODTXMLReader {
    /// The styles (from `styles.xml`, and this part's automatic styles).
    private let sheet: ODTStyleSheet
    private let collector: ODTStyleCollector

    /// Whether the pages are marked.
    private let includesPages: Bool

    /// The most bytes of text the document may hold, and how many have been
    /// read: the budget that stops a hostile file from making the result
    /// large (`text:s` with a count of a billion, say).
    private let limit: Int64
    private var spent: Int64 = 0

    /// The main text, the notes, and the one being read now.
    private let main: ODTFlow
    private let notes: ODTFlow
    private var flow: ODTFlow
    /// How many `text:note-body` elements are open.
    private var noteDepth = 0

    /// Whether `office:text`, the body, has begun.
    private var inBody = false
    /// Whether a page begins at the next letter or digit, and whether a
    /// letter or digit has been read at all (a break before any words begins
    /// no page: the document's first page is page 1 already).
    private var pagePending = false
    private var hasCountedText = false
    /// Whether any paragraph is a heading by its style or its outline level.
    private var hasHeadings = false

    /// The most spaces one `text:s` stands for. Real documents indent a
    /// few dozen; a count past this is a hostile file's.
    private static let mostSpaces = 1_000

    /// Prepares to read `data`, the document's `content.xml`.
    init(data: Data, file: String, sheet: ODTStyleSheet, includesPages: Bool, limit: Int64) {
        self.sheet = sheet
        collector = ODTStyleCollector(sheet: sheet)
        self.includesPages = includesPages
        self.limit = limit
        main = ODTFlow(includesPages: includesPages, limit: limit)
        notes = ODTFlow(includesPages: false, limit: limit)
        flow = main
        super.init(data: data, file: file)
    }

    // MARK: The result

    /// The document the part read, once `read()` has returned: the blocks,
    /// and how many page breaks the body holds.
    /// - Throws: `DocumentTooLargeError`.
    func finish() throws -> (blocks: [RTFBlock], pageBreaks: Int) {
        var blocks = try main.builder.finish(lastParagraph: .body, inTable: false)
        // A document that names no heading keeps the headings textutil's
        // reading finds by size, as the rich-text reader does.
        if !hasHeadings { blocks = RTFSizeHeadings.apply(to: blocks) }
        blocks += try notes.builder.finish(lastParagraph: .body, inTable: false)
        return (blocks, main.builder.pageBreaks)
    }

    // MARK: Elements

    override func startElement(_ name: String, attributes: [String: String]) {
        guard inBody else {
            // Before the body come the automatic styles.
            if name == "office:text" {
                inBody = true
            } else if ODTStyleCollector.handles(name) {
                collector.start(name, attributes: attributes)
                if sheet.count > ODTStyleSheet.maximumStyles { fail(TextutilConverter.Failure.unreadable(.odt)) }
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
        guard inBody, let last = flow.paragraphs.indices.last else { return }
        let bytes = flow.paragraphs[last].addCharacters(text)
        charge(bytes)
    }

    /// Spends `bytes` of the budget, ending the read when it is gone.
    private func charge(_ bytes: Int) {
        spent += Int64(bytes)
        if spent > limit { fail(DocumentTooLargeError(limit: limit)) }
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
            let count = min(max(attributes["text:c"].flatMap { Int($0) } ?? 1, 0), Self.mostSpaces)
            charge(count)
            addExplicit(String(repeating: " ", count: count))
        case "text:tab": addExplicit("\t")
        case "text:line-break":
            if let last = flow.paragraphs.indices.last { flow.paragraphs[last].addLineBreak() }
        case "text:soft-page-break": softPageBreak()
        case "text:hidden-paragraph":
            if attributes["text:is-hidden"] == "true", let last = flow.paragraphs.indices.last {
                flow.paragraphs[last].isHidden = true
            }
        // Lists
        case "text:list", "text:ordered-list", "text:unordered-list": try beginList(name, attributes)
        case "text:list-item":
            if let last = flow.lists.indices.last { flow.lists[last].awaitsFirstParagraph = true }
        case "text:list-header":
            if let last = flow.lists.indices.last { flow.lists[last].awaitsFirstParagraph = false }
        // Tables
        case "table:table": try beginTable(attributes)
        // Text boxes
        case "draw:text-box":
            flow.listsOutsideTextBoxes.append(flow.lists)
            flow.lists = []
        // Notes
        case "text:note-body":
            noteDepth += 1
            if noteDepth == 1 { flow = notes }
        default:
            break
        }
    }

    /// What ending the element `name` does.
    private func end(_ name: String) throws {
        switch name {
        case "text:p", "text:h": try endParagraph()
        case "text:span", "text:a":
            if let last = flow.paragraphs.indices.last { flow.paragraphs[last].endSpan() }
        case "text:list", "text:ordered-list", "text:unordered-list": _ = flow.lists.popLast()
        case "text:list-item":
            if let last = flow.lists.indices.last { flow.lists[last].awaitsFirstParagraph = false }
        case "table:table-cell":
            // A cell of a table inside a cell is part of the cell around it.
            if flow.tableDepth == 1 { try flow.builder.endCell() }
        case "table:table-row":
            if flow.tableDepth == 1 { try flow.builder.endRow() }
        case "table:table": try endTable()
        case "draw:text-box":
            if let outside = flow.listsOutsideTextBoxes.popLast() { flow.lists = outside }
        case "text:note-body":
            noteDepth = max(noteDepth - 1, 0)
            if noteDepth == 0 { flow = main }
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
        // A paragraph inside a text box that is inside a paragraph: the
        // words so far are written out first, so they stay in order.
        try writeOutOpenParagraph()

        // Whether it is a heading: `text:h`, or a paragraph whose style
        // carries an outline level.
        let level = attributes["text:outline-level"].flatMap { Int($0) } ?? style.outlineLevel
        let kind: RTFBlockBuilder.Kind
        if isHeading || style.outlineLevel != nil {
            hasHeadings = true
            kind = .heading(min(max(level ?? 1, 1), 6))
            consumeFirstParagraphOfListItem()
        } else {
            kind = itemKind(style) ?? .body
        }

        var paragraph = ODTOpenParagraph(
            kind: kind,
            run: ODTRun(size: ODTRun.halfPoints(sheet.defaultPointSize)).applying(style)
        )
        paragraph.startsPageAfter = style.breaksAfter == true
        if style.breaksBefore == true || style.hasMasterPage == true { paragraph.addPageStart() }
        flow.paragraphs.append(paragraph)
    }

    /// A paragraph or heading ends: it is written out.
    private func endParagraph() throws {
        guard var paragraph = flow.paragraphs.popLast() else { return }
        try write(&paragraph, atEnd: true)
    }

    /// Writes out the words of the paragraph open at the innermost level
    /// and goes on with the rest of it as a paragraph of text, for a block
    /// that begins inside a paragraph (a text box holds paragraphs and
    /// tables of its own).
    private func writeOutOpenParagraph() throws {
        guard let last = flow.paragraphs.indices.last else { return }
        var paragraph = flow.paragraphs[last]
        try write(&paragraph, atEnd: false)
        flow.paragraphs[last] = paragraph
    }

    /// Writes `paragraph`'s pieces into the builder, and ends the
    /// paragraph there.
    /// - Parameter atEnd: whether the paragraph itself ended; its break
    ///   after it is written then, and not for a paragraph that goes on.
    private func write(_ paragraph: inout ODTOpenParagraph, atEnd: Bool) throws {
        defer { paragraph.pieces = [] }
        // A hidden paragraph leaves nothing, not even its pages.
        guard !paragraph.isHidden else { return }
        for piece in paragraph.pieces {
            switch piece {
            case .text(let words, let run):
                let isCounted = words.unicodeScalars.contains(where: TextutilPageBreaks.isCounted)
                // The page that waits begins at the first letter or digit.
                if isCounted, pagePending, flow === main {
                    flow.builder.addPageBreak()
                    pagePending = false
                }
                try flow.builder.appendText(words, bold: run.bold, italic: run.italic, size: run.size)
                if isCounted, flow === main { hasCountedText = true }
            case .lineBreak:
                flow.builder.appendLineBreak()
            case .pageStart:
                beginPage()
            }
        }
        try flow.builder.finishParagraph(paragraph.kind, inTable: flow.tableDepth > 0)
        // What remains of a paragraph that goes on is plain text.
        paragraph.kind = .body
        if atEnd, paragraph.startsPageAfter { beginPage() }
    }

    /// Adds words that stand as they are to the paragraph open.
    private func addExplicit(_ text: String) {
        if let last = flow.paragraphs.indices.last { flow.paragraphs[last].addExplicit(text) }
    }

    /// A span or link begins: its text has the look its style gives it.
    private func beginSpan(_ attributes: [String: String]) {
        let style = sheet.properties(family: "text", name: attributes["text:style-name"])
        // Text whose style hides it is not read.
        if style.hidden == true { return skipSubtree() }
        guard let last = flow.paragraphs.indices.last else { return }
        flow.paragraphs[last].beginSpan(flow.paragraphs[last].run.applying(style))
    }

    // MARK: Pages

    /// A `text:soft-page-break`: where the layout last put a page. Inside a
    /// paragraph it is held with the paragraph's words until the paragraph
    /// ends, so that one that turns out to be hidden begins no page.
    private func softPageBreak() {
        if let last = flow.paragraphs.indices.last {
            flow.paragraphs[last].addPageStart()
        } else {
            beginPage()
        }
    }

    /// A page begins at the next letter or digit, as the pages of textutil's
    /// reading do, if a letter or digit has been read (the first page is
    /// page 1 already), pages are wanted, and the main text, not the notes
    /// that follow it, is being read. Breaks that meet before a letter or
    /// digit begin one page.
    private func beginPage() {
        guard includesPages, flow === main, hasCountedText else { return }
        pagePending = true
    }

    // MARK: Lists

    /// A list begins: its style is its own, or the one around it.
    private func beginList(_ name: String, _ attributes: [String: String]) throws {
        try writeOutOpenParagraph()
        flow.lists.append(ODTOpenList(
            styleName: attributes["text:style-name"] ?? flow.lists.last?.styleName,
            isNumbered: name == "text:ordered-list" ? true : (name == "text:unordered-list" ? false : nil)
        ))
    }

    /// Takes the mark of a list item's first paragraph.
    private func consumeFirstParagraphOfListItem() {
        if let last = flow.lists.indices.last { flow.lists[last].awaitsFirstParagraph = false }
    }

    /// What a paragraph of `style` becomes when it is the first of a list
    /// item: an item of the list, numbered or bulleted by the level's style.
    /// Nil when it is not, or when the level shows no mark.
    private func itemKind(_ style: ODTStyleProperties) -> RTFBlockBuilder.Kind? {
        guard let last = flow.lists.indices.last, flow.lists[last].awaitsFirstParagraph else { return nil }
        consumeFirstParagraphOfListItem()
        let list = flow.lists[last]
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
        try writeOutOpenParagraph()
        let style = sheet.properties(family: "table", name: attributes["table:style-name"])
        if flow.tableDepth == 0, style.breaksBefore == true || style.hasMasterPage == true { beginPage() }
        flow.tableDepth += 1
        flow.tablesStartPageAfter.append(style.breaksAfter == true)
    }

    /// A table ends. The outermost one is closed in the builder by a
    /// paragraph that holds nothing, which also keeps the table from joining
    /// one that follows it.
    private func endTable() throws {
        guard flow.tableDepth > 0 else { return }
        flow.tableDepth -= 1
        let startsPageAfter = flow.tablesStartPageAfter.popLast() ?? false
        guard flow.tableDepth == 0 else { return }
        try flow.builder.finishParagraph(.body, inTable: false)
        if startsPageAfter { beginPage() }
    }
}
