import Foundation

/// Where the book's navigation and links point into its text: node ids, each
/// with the offsets (in code points) the book names in it. The walk writes
/// an anchor at each, so contents entries, links, and pages land on their
/// words once the HTML is converted.
struct KFXTargets {
    /// The offsets named, by node id.
    private(set) var offsets: [Int: Set<Int>] = [:]

    /// Names the place `offset` in node `node`. A negative offset names the
    /// node's start.
    mutating func add(node: Int, offset: Int) {
        offsets[node, default: []].insert(max(0, offset))
    }

    /// The id of the anchor written at `offset` in node `node`; the node's
    /// start has no offset in its id.
    static func anchorID(node: Int, offset: Int) -> String {
        offset == 0 ? "kfx-\(node)" : "kfx-\(node)-\(offset)"
    }

    /// The HTML of that anchor.
    static func anchorHTML(node: Int, offset: Int) -> String {
        "<a id=\"\(anchorID(node: node, offset: offset))\"></a>"
    }
}

/// Walks the sections of a KFX book and writes each as HTML for the shared
/// converter (`HTMLToMarkdownConverter`): paragraphs, headings, emphasis,
/// links, lists, tables, and images' alt text, in the book's reading order
/// (KFX-FORMAT-NOTES-2026-11-05.md, part 7).
///
/// A book is untrusted input. The walk keeps its own stack, never recursing
/// on the book's nesting, and bounds what a book can make large: the nodes
/// walked, how deep they nest, and the HTML written. A storyline or inline
/// fragment that names itself again is damage, not a loop.
struct KFXWalk {

    /// The most nodes one book may have.
    static let maximumNodes = 1_000_000
    /// The deepest nesting of nodes followed, and of storylines expanded in
    /// place. A book nests a dozen levels; Ion's own depth cap (two levels
    /// for each node) trips first for a book that nests its nodes deeper.
    static let maximumDepth = 60

    /// One section as HTML, with what the navigation needs to know of it.
    struct Section {
        var html: String
        /// The ids of the nodes the navigation targets that this section holds.
        var targetNodeIDs: Set<Int>
        /// The targeted nodes entered before any text of the section was
        /// written: the section's start, which names the chapter.
        var startNodeIDs: Set<Int>
        /// Whether the section holds any words at all.
        var holdsText: Bool
    }

    // MARK: State

    private let fragments: KFXFragments
    private let styles: KFXStyles
    private let targets: KFXTargets
    /// The heading level the book's headings container gives a node.
    private let headingLevels: [Int: Int]
    /// The most nodes the walk visits.
    private let nodeLimit: Int
    /// The nodes walked so far in the book.
    private var nodeCount = 0
    /// The HTML written so far in the book.
    private var byteCount = 0
    /// The level of the last heading, which a heading node without a level
    /// of its own takes.
    private var lastHeadingLevel = 1

    /// A walk over `fragments`.
    /// - Parameters:
    ///   - targets: The places the navigation and links point at.
    ///   - headingLevels: The level the headings container gives a node, by id.
    ///   - maximumNodes: The most nodes the walk visits in all; a test gives a small one.
    init(
        fragments: KFXFragments, targets: KFXTargets = KFXTargets(), headingLevels: [Int: Int] = [:],
        maximumNodes: Int = KFXWalk.maximumNodes
    ) {
        self.nodeLimit = maximumNodes
        self.fragments = fragments
        self.styles = KFXStyles(fragments)
        self.targets = targets
        self.headingLevels = headingLevels
    }

    // MARK: Steps

    /// What is left to do on the walk's stack.
    private enum Step {
        /// Visit a node.
        case node(IonValue, Context)
        /// Write text: a closing tag.
        case literal(String)
        /// A storyline or inline fragment has been left; it may be named again.
        case leave(String)
    }

    /// What a node needs to know of where it stands.
    private struct Context {
        enum Parent { case block, list, table, row }
        var parent = Parent.block
        /// The node flows within its line.
        var isInline = false
        var depth = 0
    }

    /// What one section's walk has written so far.
    private struct Output {
        var html = ""
        /// Anchors waiting for the next element they can stand in.
        var pendingAnchors = ""
        var targetNodeIDs: Set<Int> = []
        var startNodeIDs: Set<Int> = []
        var holdsText = false

        /// The waiting anchors, which a caller writes inside the element it
        /// has just opened.
        mutating func takeAnchors() -> String {
            defer { pendingAnchors = "" }
            return pendingAnchors
        }
    }

    // MARK: Sections

    /// The HTML of the section called `name`.
    /// - Throws: `MOBIError.damaged` when the section, a storyline it names,
    ///   or text a paragraph points at is not in the book, when a storyline
    ///   names itself, or when the book holds more nodes than it may.
    ///   `DocumentTooLargeError` when the HTML passes `DocumentByteLimit`.
    mutating func section(named name: String) throws -> Section {
        guard let section = fragments[KFXSymbol.section, name]?.structValue else {
            throw MOBIError.damaged("a section the reading order names is not in the book")
        }
        var output = Output()
        var stack: [Step] = []
        var active: Set<String> = []
        // The page templates, each a storyline, in order.
        for template in (section[KFXSymbol.pageTemplates]?.listValue ?? []).reversed() {
            guard let storyline = template.structValue?[KFXSymbol.storylineName]?.stringValue else { continue }
            try push(storyline: storyline, depth: 0, onto: &stack, active: &active)
        }

        while let step = stack.popLast() {
            switch step {
            case .literal(let text):
                output.html += text
            case .leave(let name):
                active.remove(name)
            case .node(let value, let context):
                try enter(value, context, &stack, &output, &active)
                try DocumentByteLimit.check(byteCount: Int64(output.html.utf8.count))
            }
        }
        // The HTML of the whole book is held to the same limit as one document.
        byteCount += output.html.utf8.count
        try DocumentByteLimit.check(byteCount: Int64(byteCount))
        return Section(
            html: output.html, targetNodeIDs: output.targetNodeIDs,
            startNodeIDs: output.startNodeIDs, holdsText: output.holdsText)
    }

    /// Pushes the nodes of the storyline `name` so they are visited in order.
    private func push(storyline name: String, depth: Int, onto stack: inout [Step], active: inout Set<String>) throws {
        guard let storyline = fragments[KFXSymbol.storyline, name]?.structValue else {
            throw MOBIError.damaged("a storyline a section names is not in the book")
        }
        guard active.insert(name).inserted else {
            throw MOBIError.damaged("a storyline names itself")
        }
        stack.append(.leave(name))
        for node in (storyline[KFXSymbol.nodes]?.listValue ?? []).reversed() {
            stack.append(.node(node, Context(depth: depth)))
        }
    }

    // MARK: Nodes

    /// Visits one node: writes what it holds and pushes its children.
    private mutating func enter(
        _ value: IonValue, _ context: Context,
        _ stack: inout [Step], _ output: inout Output, _ active: inout Set<String>
    ) throws {
        guard context.depth <= Self.maximumDepth else { throw MOBIError.damaged("nodes nest too deeply") }
        // A child is a node, or the name of an inline fragment holding one.
        let node: IonStruct
        switch value.unannotated {
        case .structure(let members):
            node = members
        case .string(let name):
            guard let referenced = fragments[KFXSymbol.inlineFragment, name]?.structValue else { return }
            guard active.insert(name).inserted else { throw MOBIError.damaged("an inline fragment names itself") }
            stack.append(.leave(name))
            node = referenced
        default:
            return
        }
        nodeCount += 1
        guard nodeCount <= nodeLimit else { throw MOBIError.damaged("the book holds more nodes than TextMouth reads") }

        let type = node[KFXSymbol.nodeType]?.symbolID
        if type == KFXSymbol.hiddenContent || type == KFXSymbol.vectorGraphic || type == KFXSymbol.plugin { return }

        let id = node[KFXSymbol.nodeID]?.intValue
        let text = try string(of: node)
        let hasText = text.map { !$0.allSatisfy(\.isWhitespace) } ?? false
        // A targeted node is marked: its start waits for the next element,
        // unless the node writes the text itself, which places its anchors.
        var textAnchors: [Int: String] = [:]
        if let id, let offsets = targets.offsets[id] {
            output.targetNodeIDs.insert(id)
            if offsets.contains(0) && !output.holdsText { output.startNodeIDs.insert(id) }
            if hasText {
                for offset in offsets { textAnchors[offset] = KFXTargets.anchorHTML(node: id, offset: offset) }
            } else if offsets.contains(0) {
                output.pendingAnchors += KFXTargets.anchorHTML(node: id, offset: 0)
            }
        }

        let isInline = context.isInline || node[KFXSymbol.renderMode]?.symbolID == KFXSymbol.inlineRender
        let children = node[KFXSymbol.children]?.listValue ?? []
        // A node that names another storyline holds its nodes in place.
        if let expanded = node[KFXSymbol.storylineName]?.stringValue {
            try push(storyline: expanded, depth: context.depth + 1, onto: &stack, active: &active)
        }
        var childContext = Context(parent: .block, isInline: false, depth: context.depth + 1)

        switch type ?? -1 {
        case KFXSymbol.image:
            writeImage(node, isInline: isInline, into: &output)
            return
        case KFXSymbol.rule:
            output.html += "<hr/>" + output.takeAnchors()
            return
        case KFXSymbol.list:
            let ordered = isOrdered(list: node)
            output.html += ordered ? "<ol>" : "<ul>"
            stack.append(.literal(ordered ? "</ol>" : "</ul>"))
            childContext.parent = .list
        case KFXSymbol.table:
            output.html += "<table>"
            stack.append(.literal("</table>"))
            childContext.parent = .table
        case KFXSymbol.tableHead, KFXSymbol.tableBody, KFXSymbol.tableFoot:
            let tag = type == KFXSymbol.tableHead ? "thead" : type == KFXSymbol.tableFoot ? "tfoot" : "tbody"
            output.html += "<\(tag)>"
            stack.append(.literal("</\(tag)>"))
        case KFXSymbol.tableRow:
            output.html += "<tr>"
            stack.append(.literal("</tr>"))
            childContext.parent = .row
        default:
            // A text block, a list item, a container, or a node of a kind not
            // named: its own text first, then its children. What wraps the
            // text depends on where the node stands: a cell of a table is a
            // child of a row, a caption a child of the table; the text of a
            // block of inline children is one paragraph.
            let isCell = context.parent == .row
            let isItem = type == KFXSymbol.listItem
            let isCaption = context.parent == .table && node[KFXSymbol.classification]?.symbolID == KFXSymbol.caption
            let wrapsInlineChildren = !isCell && !isItem && !isCaption && !isInline && text == nil
                && children.contains { $0.structValue?[KFXSymbol.renderMode]?.symbolID == KFXSymbol.inlineRender }
            let wrapper: String? = isCell ? "td" : isItem ? "li" : isCaption ? "caption" : wrapsInlineChildren ? "p" : nil
            if let wrapper {
                output.html += "<\(wrapper)>" + output.takeAnchors()
                stack.append(.literal("</\(wrapper)>"))
            }
            if let text, hasText {
                let tag = (wrapper != nil || isInline) ? nil : blockTag(of: node, id: id)
                if let tag { output.html += "<\(tag)>" + output.takeAnchors() }
                output.html += inline(text, of: node, anchors: textAnchors)
                if let tag { output.html += "</\(tag)>" }
                output.holdsText = true
            }
            if isInline { childContext.isInline = true }
        }

        // The children come next, in order: the first is on top.
        for child in children.reversed() { stack.append(.node(child, childContext)) }
    }

    /// Writes an image: its alt text when it has any, and nothing otherwise.
    private func writeImage(_ node: IonStruct, isInline: Bool, into output: inout Output) {
        guard let alt = node[KFXSymbol.altText]?.stringValue,
              !alt.allSatisfy(\.isWhitespace) else { return }
        let image = "<img alt=\"\(KFXInlineText.escaped(alt))\"/>"
        output.html += isInline ? image : "<p>" + output.takeAnchors() + image + "</p>"
        output.holdsText = true
    }

    /// The text of a node: its own string, or the string of a content
    /// fragment it points at; nil for a node with none.
    /// - Throws: `MOBIError.damaged` when it points at text the book lacks.
    private func string(of node: IonStruct) throws -> String? {
        guard let value = node[KFXSymbol.text]?.unannotated else { return nil }
        switch value {
        case .string(let text):
            return text
        case .structure(let pointer):
            guard let name = pointer[KFXSymbol.contentName]?.stringValue,
                  let index = pointer[KFXSymbol.contentIndex]?.intValue, index >= 0,
                  let strings = fragments[KFXSymbol.content, name]?.structValue?[KFXSymbol.contentStrings]?.listValue,
                  index < strings.count, let text = strings[index].stringValue else {
                throw MOBIError.damaged("a paragraph points at text that is not in the book")
            }
            return text
        default:
            return nil
        }
    }

    /// The HTML tag of a block of text: a heading `h1` to `h6` when the book
    /// marks the node a heading, and a paragraph otherwise.
    private mutating func blockTag(of node: IonStruct, id: Int?) -> String {
        if let id, let level = headingLevels[id] {
            lastHeadingLevel = level
            return "h\(min(max(level, 1), 6))"
        }
        guard styles.style(of: node).marksHeading else { return "p" }
        // A heading with no level of its own takes the last one seen.
        let level = node[KFXSymbol.headingLevel]?.intValue ?? lastHeadingLevel
        lastHeadingLevel = level
        return "h\(min(max(level, 1), 6))"
    }

    /// The inline HTML of a node's text: its runs as emphasis and links.
    private func inline(_ text: String, of node: IonStruct, anchors: [Int: String]) -> String {
        KFXInlineText.html(
            of: text, runs: node[KFXSymbol.runs]?.listValue ?? [], anchorAt: anchors,
            resolveRun: { run in
                let style = styles.style(of: run)
                return (style.isBold, style.isItalic, href(ofRun: run))
            })
    }

    /// Where a run's link goes: the web address of its anchor, or an in-book
    /// anchor written for the position the anchor names; nil for no link.
    private func href(ofRun run: IonStruct) -> String? {
        guard let name = run[KFXSymbol.runLink]?.stringValue,
              let anchor = fragments[KFXSymbol.anchor, name]?.structValue else { return nil }
        if let address = anchor[KFXSymbol.anchorURL]?.stringValue { return address }
        guard let position = anchor[KFXSymbol.anchorPosition]?.structValue,
              let node = position[KFXSymbol.positionNode]?.intValue else { return nil }
        return "#" + KFXTargets.anchorID(node: node, offset: position[KFXSymbol.positionOffset]?.intValue ?? 0)
    }

    /// Whether a list is numbered.
    private func isOrdered(list node: IonStruct) -> Bool {
        guard let style = node[KFXSymbol.listStyle]?.symbolID else { return false }
        return KFXSymbol.orderedListStyles.contains(style)
    }
}
