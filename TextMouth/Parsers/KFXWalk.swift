import Foundation

/// Walks the sections of a KFX book and writes each as HTML for the shared
/// converter (`HTMLToMarkdownConverter`): paragraphs, headings, emphasis,
/// links, lists, tables, and images' alt text, in the book's reading order
/// (KFX-FORMAT-NOTES-2026-11-05.md, part 7).
///
/// A book is untrusted input. The walk keeps its own stack, never recursing
/// on the book's nesting (the one recursion, into the inline nodes of a
/// paragraph, is held to `maximumDepth`), and bounds what a book can make
/// large with one counter of work against one limit: every step taken, every
/// field of a node, every run, and every byte of text, even text that is not
/// written. A real book visits each of its words once, so its work stays
/// near its size. A storyline or inline fragment that names itself again is
/// damage, not a loop.
struct KFXWalk {

    /// The most nodes one book may have.
    static let maximumNodes = 1_000_000
    /// The most work one book may ask for, in the units `spend(_:)` counts.
    /// A real book's is about its size in bytes, at most 64 million.
    static let maximumWork = 150_000_000
    /// The deepest nesting of nodes followed, and of storylines expanded in
    /// place. A book nests a dozen levels; Ion's own depth cap (two levels
    /// for each node) trips first for a book that nests its nodes deeper.
    static let maximumDepth = 60
    /// How many units of work pass between two asks whether the import was
    /// cancelled.
    private static let cancellationInterval = 4_096

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
        /// Whether the first block the section writes is a heading.
        var startsWithHeading: Bool
    }

    // MARK: State

    private let fragments: KFXFragments
    private let styles: KFXStyles
    private let targets: KFXTargets
    /// The heading level the book's headings container gives a node.
    private let headingLevels: [Int: Int]
    /// The most nodes the walk visits.
    private let nodeLimit: Int
    /// The most work the walk does.
    private let workLimit: Int
    /// The nodes walked so far in the book.
    private var nodeCount = 0
    /// The work done so far in the book.
    private var work = 0
    /// The work done since cancellation was last asked.
    private var workSinceCancellationCheck = 0
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
    ///   - maximumWork: The most work the walk does in all; a test gives a small one.
    init(
        fragments: KFXFragments, targets: KFXTargets = KFXTargets(), headingLevels: [Int: Int] = [:],
        maximumNodes: Int = KFXWalk.maximumNodes, maximumWork: Int = KFXWalk.maximumWork
    ) {
        self.nodeLimit = maximumNodes
        self.workLimit = maximumWork
        self.fragments = fragments
        self.styles = KFXStyles(fragments)
        self.targets = targets
        self.headingLevels = headingLevels
    }

    // MARK: Work

    /// Counts `units` of work against the limit, and asks every few thousand
    /// whether the import was cancelled.
    /// - Throws: `MOBIError.damaged` past the limit; `ImportCancelled`.
    private mutating func spend(_ units: Int) throws {
        work += units
        guard work <= workLimit else { throw MOBIError.damaged("the book asks for more work than TextMouth does") }
        workSinceCancellationCheck += units
        if workSinceCancellationCheck >= Self.cancellationInterval {
            workSinceCancellationCheck = 0
            try ImportCancellation.throwIfCancelled()
        }
    }

    // MARK: Steps

    /// What is left to do on the walk's stack.
    private enum Step {
        /// Visit a node.
        case node(IonValue, Context)
        /// Write text: a closing tag.
        case literal(String)
        /// Read a storyline's nodes (it is entered when its turn comes, so
        /// two page templates may name one storyline, one after the other).
        case storyline(String, depth: Int)
        /// A storyline or inline fragment has been left; it may be named again.
        case leave(String)
    }

    /// What a node needs to know of where it stands.
    private struct Context {
        enum Parent {
            case block, table, row
            /// The only child of a table cell: it is written without a
            /// paragraph of its own, so the row reads as one line.
            case soleCellChild
        }
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
        var wroteBlock = false
        var startsWithHeading = false

        /// The waiting anchors, which a caller writes inside the element it
        /// has just opened.
        mutating func takeAnchors() -> String {
            defer { pendingAnchors = "" }
            return pendingAnchors
        }

        /// Notes that a block of `tag` has been written; the first one says
        /// whether the section starts with a heading.
        mutating func noteBlock(_ tag: String?) {
            guard !wroteBlock else { return }
            wroteBlock = true
            startsWithHeading = tag?.hasPrefix("h") ?? false
        }
    }

    // MARK: Sections

    /// The HTML of the section called `name`.
    /// - Throws: `MOBIError.damaged` when the section, a storyline it names,
    ///   or text a paragraph points at is not in the book, when a storyline
    ///   names itself, or when the book holds more nodes or asks for more
    ///   work than it may. `DocumentTooLargeError` when the HTML passes
    ///   `DocumentByteLimit`. `ImportCancelled` when the import is cancelled.
    mutating func section(named name: String) throws -> Section {
        guard let section = fragments[KFXSymbol.section, name]?.structValue else {
            throw MOBIError.damaged("a section the reading order names is not in the book")
        }
        var output = Output()
        var stack: [Step] = []
        var active: Set<String> = []
        // The page templates, each a storyline, in order. A template's own
        // id is a place the navigation may point at: the section's start.
        let templates = section[KFXSymbol.pageTemplates]?.listValue ?? []
        for template in templates {
            guard let id = template.structValue?[KFXSymbol.nodeID]?.intValue, let offsets = targets.offsets[id] else { continue }
            output.targetNodeIDs.insert(id)
            output.startNodeIDs.insert(id)
            for offset in offsets.sortedStably() { output.pendingAnchors += KFXTargets.anchorHTML(node: id, offset: offset) }
        }
        for template in templates.reversed() {
            guard let storyline = template.structValue?[KFXSymbol.storylineName]?.stringValue else { continue }
            stack.append(.storyline(storyline, depth: 0))
        }

        while let step = stack.popLast() {
            try spend(1)
            switch step {
            case .literal(let text):
                output.html += text
            case .leave(let name):
                active.remove(name)
            case .storyline(let name, let depth):
                try push(storyline: name, depth: depth, onto: &stack, active: &active)
            case .node(let value, let context):
                try enter(value, context, &stack, &output, &active)
                try DocumentByteLimit.check(byteCount: Int64(output.html.utf8.count))
            }
        }
        // A last node that writes nothing leaves its places waiting: they
        // stand at the section's end rather than being lost.
        if !output.pendingAnchors.isEmpty { output.html += "<p>" + output.takeAnchors() + "</p>" }
        // The HTML of the whole book is held to the same limit as one document.
        byteCount += output.html.utf8.count
        try DocumentByteLimit.check(byteCount: Int64(byteCount))
        return Section(
            html: output.html, targetNodeIDs: output.targetNodeIDs, startNodeIDs: output.startNodeIDs,
            holdsText: output.holdsText, startsWithHeading: output.startsWithHeading)
    }

    /// Pushes the nodes of the storyline `name` so they are visited in order.
    private func push(storyline name: String, depth: Int, onto stack: inout [Step], active: inout Set<String>) throws {
        guard depth <= Self.maximumDepth else { throw MOBIError.damaged("storylines nest too deeply") }
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
        try spend(node.fields.count)

        let type = node[KFXSymbol.nodeType]?.symbolID
        if type == KFXSymbol.hiddenContent || type == KFXSymbol.vectorGraphic || type == KFXSymbol.plugin { return }

        let id = node[KFXSymbol.nodeID]?.intValue
        // The node's text: its own string, or the strings and inline nodes
        // of its children flattened into one text. A heading with no text of
        // its own that holds one child of text (Amazon's form for a heading
        // with a floated span in it) takes the child's text, runs, and places.
        var source = node
        var textIDs: [Int] = id.map { [$0] } ?? []
        var text = try string(of: node)
        var inserts: [String] = []
        var flatWords: Bool?
        var consumedChildren = false
        if text == nil, let flat = try flatten(node, depth: context.depth + 1, active: &active) {
            text = flat.text
            inserts = flat.inserts
            flatWords = flat.hasWords
            consumedChildren = true
        } else if text == nil, looksLikeHeading(node, id: id), let only = onlyChild(of: node) {
            if let own = try string(of: only) {
                text = own
            } else if let flat = try flatten(only, depth: context.depth + 1, active: &active) {
                text = flat.text
                inserts = flat.inserts
                flatWords = flat.hasWords
            }
            if text != nil {
                source = only
                consumedChildren = true
                if let childID = only[KFXSymbol.nodeID]?.intValue { textIDs.append(childID) }
            }
        }
        if let text { try spend(text.utf8.count) }
        let hasText = text.map { flatWords ?? hasWords($0) } ?? false

        // A targeted node is marked: its start waits for the next element,
        // unless the node writes the text itself, which places its anchors.
        var textAnchors: [Int: String] = [:]
        for named in textIDs {
            guard let offsets = targets.offsets[named] else { continue }
            output.targetNodeIDs.insert(named)
            if offsets.contains(0) && !output.holdsText { output.startNodeIDs.insert(named) }
            if hasText {
                for offset in offsets where textAnchors[offset] == nil {
                    textAnchors[offset] = KFXTargets.anchorHTML(node: named, offset: offset)
                }
            } else {
                // Any place named in a node that writes no text is its start.
                for offset in offsets.sortedStably() { output.pendingAnchors += KFXTargets.anchorHTML(node: named, offset: offset) }
            }
        }

        let bareInCell = context.parent == .soleCellChild
        let isInline = context.isInline || node[KFXSymbol.renderMode]?.symbolID == KFXSymbol.inlineRender
        // The children were read into the text when it was flattened.
        let children = consumedChildren ? [] : (node[KFXSymbol.children]?.listValue ?? [])
        // A node that names another storyline holds its nodes in place.
        if let expanded = node[KFXSymbol.storylineName]?.stringValue {
            stack.append(.storyline(expanded, depth: context.depth + 1))
        }
        var childContext = Context(parent: .block, isInline: false, depth: context.depth + 1)

        switch type ?? -1 {
        case KFXSymbol.image:
            writeImage(node, id: id, isInline: isInline || bareInCell, into: &output)
            return
        case KFXSymbol.rule:
            output.html += "<hr/>" + output.takeAnchors()
            return
        case KFXSymbol.list:
            let ordered = isOrdered(list: node)
            output.html += ordered ? "<ol>" : "<ul>"
            stack.append(.literal(ordered ? "</ol>" : "</ul>"))
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
            // block of inline children is one paragraph, and so is a picture
            // drop cap with the text it begins.
            let isCell = context.parent == .row
            let isItem = type == KFXSymbol.listItem
            let isCaption = context.parent == .table && node[KFXSymbol.classification]?.symbolID == KFXSymbol.caption
            let hasInlineChildren = children.contains { $0.structValue?[KFXSymbol.renderMode]?.symbolID == KFXSymbol.inlineRender }
            let wrapsInlineChildren = !isCell && !isItem && !isCaption && !isInline && !bareInCell && text == nil
                && (hasInlineChildren || startsWithFloat(children))
            let wrapper: String? = isCell ? "td" : isItem ? "li" : isCaption ? "caption" : wrapsInlineChildren ? "p" : nil
            if let wrapper {
                output.html += "<\(wrapper)>" + output.takeAnchors()
                stack.append(.literal("</\(wrapper)>"))
                output.noteBlock(wrapper)
            }
            if let text, hasText {
                // A cell's only child is written bare, keeping a heading tag.
                let heading = isInline ? nil : headingTag(of: node, id: id)
                let tag: String? = (wrapper != nil || isInline) ? nil : (heading ?? (bareInCell ? nil : "p"))
                if let tag { output.html += "<\(tag)>" + output.takeAnchors() }
                output.noteBlock(tag)
                output.html += try inline(text, of: source, id: textIDs.last, anchors: textAnchors, inserts: inserts, withBase: heading == nil)
                if let tag { output.html += "</\(tag)>" }
                output.holdsText = true
            }
            if isInline || wrapsInlineChildren && startsWithFloat(children) { childContext.isInline = true }
            // A floated block among the words of its paragraph is set off by a
            // space on each side, so the words beside it do not run into it.
            if isInline, node[KFXSymbol.floatMarker] != nil {
                output.html += " "
                stack.append(.literal(" "))
            }
            if isCell, children.count == 1, children[0].structValue != nil { childContext.parent = .soleCellChild }
        }

        // The children come next, in order: the first is on top.
        for child in children.reversed() { stack.append(.node(child, childContext)) }
    }

    /// Whether `children` are a picture or a floated block and then the text
    /// it belongs to: a picture drop cap, or a floated span of words, that
    /// does not flow inline, followed by a node of text. They are one paragraph.
    private func startsWithFloat(_ children: [IonValue]) -> Bool {
        guard children.count >= 2, let first = children[0].structValue, let second = children[1].structValue else { return false }
        let floated = first[KFXSymbol.nodeType]?.symbolID == KFXSymbol.image || first[KFXSymbol.floatMarker] != nil
        return floated && second[KFXSymbol.text] != nil
    }

    /// Whether the book marks the node a heading, by its level container or
    /// its style, without changing the level a heading without one takes.
    private func looksLikeHeading(_ node: IonStruct, id: Int?) -> Bool {
        if let id, headingLevels[id] != nil { return true }
        return styles.style(of: node).marksHeading
    }

    /// The node's only child, when it has just one and it is a node.
    private func onlyChild(of node: IonStruct) -> IonStruct? {
        guard let children = node[KFXSymbol.children]?.listValue, children.count == 1 else { return nil }
        return children[0].structValue
    }

    /// Writes an image: its alt text when it has any, and nothing otherwise.
    /// A picture the book makes a heading is written as one.
    private mutating func writeImage(_ node: IonStruct, id: Int?, isInline: Bool, into output: inout Output) {
        guard let alt = node[KFXSymbol.altText]?.stringValue, hasWords(alt) else { return }
        let image = "<img alt=\"\(KFXInlineText.escaped(alt))\"/>"
        if isInline {
            output.html += image
        } else {
            let tag = headingTag(of: node, id: id) ?? "p"
            output.html += "<\(tag)>" + output.takeAnchors() + image + "</\(tag)>"
            output.noteBlock(tag)
        }
        output.holdsText = true
    }

    // MARK: Text

    /// Whether `text` holds anything but white space. White space is read
    /// byte by byte, so a long run of it is passed quickly.
    private func hasWords(_ text: String) -> Bool {
        for byte in text.utf8 {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0D: continue
            case 0..<0x80: return true
            default: return text.unicodeScalars.contains { !$0.properties.isWhitespace }
            }
        }
        return false
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

    /// The text a node with no text of its own makes of its children, when
    /// they are strings and nodes in one list (Amazon writes a paragraph
    /// that holds a picture, math, or a floated span so): the strings kept as
    /// they are, spaces included, and a placeholder for each node, which
    /// counts as one code point, as the book's runs and places count it. A
    /// string that names an inline fragment (`$608`) is that fragment's node.
    /// Nil when the children hold no string of text.
    private mutating func flatten(
        _ node: IonStruct, depth: Int, active: inout Set<String>
    ) throws -> (text: String, inserts: [String], hasWords: Bool)? {
        guard node[KFXSymbol.text] == nil, let children = node[KFXSymbol.children]?.listValue else { return nil }
        let fragments = self.fragments
        func isText(_ child: IonValue) -> String? {
            if case .string(let name) = child.unannotated, fragments[KFXSymbol.inlineFragment, name] == nil { return name }
            return nil
        }
        guard children.contains(where: { isText($0) != nil }) else { return nil }
        var text = ""
        var inserts: [String] = []
        var words = false
        for child in children {
            try spend(1)
            if let piece = isText(child) {
                try spend(piece.utf8.count)
                for scalar in piece.unicodeScalars {
                    text.unicodeScalars.append(scalar == KFXInlineText.placeholder ? "\u{FFFD}" : scalar)
                }
                words = words || hasWords(piece)
            } else {
                text.unicodeScalars.append(KFXInlineText.placeholder)
                let inline = try inlineHTML(of: child, depth: depth, active: &active)
                inserts.append(inline.html)
                words = words || inline.hasWords
            }
        }
        return (text, inserts, words)
    }

    /// The HTML of an inline node among a paragraph's words, and whether it
    /// holds words: a picture's alt text, math's accessible name, or the
    /// words of a node that holds text (set off by a space on each side, so
    /// they do not run into the words beside them).
    private mutating func inlineHTML(
        of value: IonValue, depth: Int, active: inout Set<String>
    ) throws -> (html: String, hasWords: Bool) {
        guard depth <= Self.maximumDepth else { throw MOBIError.damaged("nodes nest too deeply") }
        let node: IonStruct
        var leaving: String?
        switch value.unannotated {
        case .structure(let members):
            node = members
        case .string(let name):
            guard let referenced = fragments[KFXSymbol.inlineFragment, name]?.structValue else { return ("", false) }
            guard active.insert(name).inserted else { throw MOBIError.damaged("an inline fragment names itself") }
            leaving = name
            node = referenced
        default:
            return ("", false)
        }
        defer { if let leaving { active.remove(leaving) } }
        nodeCount += 1
        guard nodeCount <= nodeLimit else { throw MOBIError.damaged("the book holds more nodes than TextMouth reads") }
        try spend(node.fields.count + 1)

        let type = node[KFXSymbol.nodeType]?.symbolID
        if type == KFXSymbol.hiddenContent || type == KFXSymbol.vectorGraphic || type == KFXSymbol.plugin { return ("", false) }
        if let name = try accessibleName(of: node) {
            return hasWords(name) ? (" " + KFXInlineText.escaped(name) + " ", true) : ("", false)
        }
        if type == KFXSymbol.image {
            guard let alt = node[KFXSymbol.altText]?.stringValue, hasWords(alt) else { return ("", false) }
            return ("<img alt=\"\(KFXInlineText.escaped(alt))\"/>", true)
        }
        var html = ""
        var words = false
        var text = try string(of: node)
        var inserts: [String] = []
        var consumed = false
        if text == nil, let flat = try flatten(node, depth: depth + 1, active: &active) {
            text = flat.text
            inserts = flat.inserts
            consumed = true
        }
        if let text {
            try spend(text.utf8.count)
            if consumed || hasWords(text) {
                html = try inline(text, of: node, id: nil, anchors: [:], inserts: inserts, withBase: true)
                words = hasWords(text.replacingOccurrences(of: String(KFXInlineText.placeholder), with: "")) || inserts.contains { !$0.isEmpty }
            }
        }
        if !consumed {
            for child in node[KFXSymbol.children]?.listValue ?? [] {
                let inner = try inlineHTML(of: child, depth: depth + 1, active: &active)
                html += inner.html
                words = words || inner.hasWords
            }
        }
        return words ? (" " + html + " ", true) : (html, false)
    }

    /// A node's accessible name when the book gives one: math carries its
    /// spoken form as an annotation of the kind "accessible name", and failing
    /// that the words of its MathML.
    private func accessibleName(of node: IonStruct) throws -> String? {
        guard let annotations = node[KFXSymbol.annotations]?.listValue else { return nil }
        var mathML: String?
        for annotation in annotations {
            guard let members = annotation.structValue, let kind = members[KFXSymbol.annotationKind]?.symbolID,
                  let text = try string(of: members) else { continue }
            if kind == KFXSymbol.accessibleName { return text }
            if kind == KFXSymbol.mathML, mathML == nil { mathML = text }
        }
        guard let mathML else { return nil }
        // The words of the markup: its text between the tags.
        var words: [String] = []
        var current = ""
        var insideTag = false
        for character in mathML {
            if character == "<" { insideTag = true; if !current.isEmpty { words.append(current); current = "" } }
            else if character == ">" { insideTag = false }
            else if !insideTag { current.append(character) }
        }
        if !current.isEmpty { words.append(current) }
        let joined = words.joined(separator: " ")
        return hasWords(joined) ? joined : nil
    }

    // MARK: Headings and inline HTML

    /// The tag `h1` to `h6` when the book marks the node a heading, nil
    /// otherwise. A heading with no level of its own takes the last one seen.
    private mutating func headingTag(of node: IonStruct, id: Int?) -> String? {
        if let id, let level = headingLevels[id] {
            lastHeadingLevel = level
            return "h\(min(max(level, 1), 6))"
        }
        guard styles.style(of: node).marksHeading else { return nil }
        let level = node[KFXSymbol.headingLevel]?.intValue ?? lastHeadingLevel
        lastHeadingLevel = level
        return "h\(min(max(level, 1), 6))"
    }

    /// The inline HTML of a node's text: its runs as emphasis and links, its
    /// own style as emphasis over the whole text (outside a heading), the
    /// places the navigation names, and its inline nodes.
    private mutating func inline(
        _ text: String, of node: IonStruct, id: Int?, anchors: [Int: String], inserts: [String], withBase: Bool
    ) throws -> String {
        let runs = node[KFXSymbol.runs]?.listValue ?? []
        try spend(runs.count)
        var context = KFXInlineText.Context(anchorAt: anchors, inserts: inserts)
        if withBase {
            let own = styles.style(of: node)
            context.baseBold = own.isBold
            context.baseItalic = own.isItalic
        }
        // A page's own number, standing where the page begins, is not read.
        if let id, let labels = targets.pageLabels[id], !labels.isEmpty {
            let scalars = Array(text.unicodeScalars)
            for (offset, label) in labels {
                let wanted = Array(label.unicodeScalars)
                // The offset comes from the book: compared before it is added to anything.
                if offset >= 0, offset < scalars.count, wanted.count <= scalars.count - offset,
                   scalars[offset..<(offset + wanted.count)].elementsEqual(wanted) {
                    context.skipAt[offset] = wanted.count
                }
            }
        }
        return KFXInlineText.html(of: text, runs: runs, context: context) { run in
            let style = styles.style(of: run)
            return (style.isBold, style.isItalic, href(ofRun: run))
        }
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
