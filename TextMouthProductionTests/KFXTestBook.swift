import Foundation
@testable import TextMouth

/// One piece of a paragraph that holds inline nodes, as Amazon writes it: the
/// paragraph's children are strings (the words, spaces included) and nodes.
enum KFXInlineSpec {
    case string(String)
    /// An inline picture with alt text.
    case image(alt: String)
    /// An inline container holding words, such as a floated span.
    case span(String)
    /// Inline math with its accessible name.
    case math(alt: String)
}

/// A node of a test book, which `KFXTestBook` writes as KFX nodes, giving each
/// an id and putting its text in a content fragment as Amazon's files do.
indirect enum KFXNodeSpec {
    /// A run of a text node: code points `start` for `length`, with a style
    /// (by name, see `KFXTestBook.styles`) and an optional link (an anchor name).
    struct Run {
        var start: Int
        var length: Int
        var style: String?
        var link: String?
    }

    /// A text block. `heading` makes it a heading of that level the way the
    /// books do: a style with the heading hint and a level on the node.
    case text(String, runs: [Run] = [], heading: Int? = nil)
    /// A container of children.
    case container([KFXNodeSpec])
    /// A list, numbered or not, of items.
    case list(ordered: Bool, [KFXNodeSpec])
    /// A list item with its own text and children.
    case item(String?, [KFXNodeSpec] = [])
    /// A table with an optional caption, a header row, and body rows.
    case table(caption: String?, header: [String], rows: [[String]])
    /// An image with alt text, or none.
    case image(alt: String?)
    case rule
    /// A node of this symbol type with these children and no text: for the
    /// kinds that are skipped.
    case typed(Int, [KFXNodeSpec])
    /// A text block with no text of its own that holds inline children.
    case inlineParent([String])
    /// A paragraph (a heading when `heading` is given) of strings and inline
    /// nodes, with runs that count each node as one code point.
    case mixed([KFXInlineSpec], runs: [Run] = [], heading: Int? = nil)
    /// A node written as it is, with its own fields.
    case raw(IonOut)
}

/// Builds a KFX book in code: sections of nodes, styles, anchors, navigation,
/// and metadata, written as a container (`build()`), for the tests of the
/// walk and of the whole reader.
struct KFXTestBook {
    var title: String? = "A Test Book"
    var authors = ["Test Author"]
    var language: String? = "en"
    /// Sections by name, in reading order, each its nodes.
    var sections: [(name: String, nodes: [KFXNodeSpec])] = []
    /// The styles by name: bold, italic, heading hint.
    var styles: [String: (bold: Bool, italic: Bool, heading: Bool)] = [
        "bold": (true, false, false), "italic": (false, true, false), "both": (true, true, false),
        "h": (false, false, true), "plain": (false, false, false),
    ]
    /// Anchors by name: a web address, or a node id and offset.
    var anchors: [String: (url: String?, node: Int?, offset: Int)] = [:]
    /// Capability entries of the metadata.
    var capabilities: [(key: String, value: IonOut)] = []
    /// Further fields of document data.
    var documentData: [(Int, IonOut)] = []
    /// Writes the book navigation (`$389`) from the ids of the nodes written,
    /// in the order they were written (`writtenIDs`).
    var navigation: (([Int]) -> IonOut)?
    /// Hands the container builder to a test before the bytes are made.
    var container = KFXContainerBuilder()

    private var nextNodeID = 800
    private var localNames: [String] = []
    private var contents: [String: [String]] = [:]
    /// The ids given to the nodes of `sections`, in the order they were written.
    private(set) var writtenIDs: [Int] = []

    // MARK: Writing nodes

    /// The symbol for the local name `name`, registered on first use.
    private mutating func symbol(_ name: String) -> IonOut {
        if !localNames.contains(name) { localNames.append(name) }
        return .symbol(860 + localNames.firstIndex(of: name)!)
    }

    private mutating func newID() -> Int {
        nextNodeID += 1
        return nextNodeID
    }

    /// The `$145` field for `text`, stored in the content fragment `content`.
    private mutating func textField(_ text: String, content: String) -> (Int, IonOut) {
        contents[content, default: []].append(text)
        return (145, .structure([(4, symbol(content)), (403, .int(Int64(contents[content]!.count - 1)))]))
    }

    private mutating func nodes(_ specs: [KFXNodeSpec], content: String) -> [IonOut] {
        var written: [IonOut] = []
        for spec in specs { written.append(node(spec, content: content)) }
        return written
    }

    /// A plain text node holding `text`.
    private mutating func textNode(_ text: String, content: String) -> IonOut {
        let id = newID()
        return .structure([(155, .int(Int64(id))), (159, .symbol(269)), textField(text, content: content)])
    }

    /// A table section (`$151` head, `$454` body) of rows of cells, each cell
    /// a text block holding a text block, as Amazon's files write them.
    private mutating func tableSection(_ type: Int, rows: [[String]], content: String) -> IonOut {
        let sectionID = newID()
        var rowNodes: [IonOut] = []
        for cells in rows {
            let rowID = newID()
            var cellNodes: [IonOut] = []
            for cell in cells {
                let cellID = newID()
                cellNodes.append(.structure([
                    (155, .int(Int64(cellID))), (159, .symbol(269)), (146, .list([textNode(cell, content: content)])),
                ]))
            }
            rowNodes.append(.structure([(155, .int(Int64(rowID))), (159, .symbol(279)), (146, .list(cellNodes))]))
        }
        return .structure([(155, .int(Int64(sectionID))), (159, .symbol(type)), (146, .list(rowNodes))])
    }

    /// One child of a paragraph of strings and inline nodes.
    private mutating func inlineChild(_ piece: KFXInlineSpec, content: String) -> IonOut {
        let id = Int64(newID())
        switch piece {
        case .string(let text):
            return .string(text)
        case .image(let alt):
            return .structure([(155, .int(id)), (584, .string(alt)), (601, .symbol(283)), (159, .symbol(271))])
        case .span(let words):
            let inner = textNode(words, content: content)
            return .structure([(155, .int(id)), (601, .symbol(283)), (159, .symbol(270)), (146, .list([inner]))])
        case .math(let alt):
            let name = textField(alt, content: content)
            return .structure([
                (155, .int(id)), (615, .symbol(688)), (601, .symbol(283)), (159, .symbol(270)),
                (683, .list([.structure([name, (687, .symbol(584))])])),
            ])
        }
    }

    /// One node as Ion.
    private mutating func node(_ spec: KFXNodeSpec, content: String) -> IonOut {
        if case .raw(let value) = spec { return value }
        let id = newID()
        writtenIDs.append(id)
        var fields: [(Int, IonOut)] = [(155, .int(Int64(id)))]
        switch spec {
        case .text(let text, let runs, let heading):
            fields.append((159, .symbol(269)))
            if let heading {
                fields.append((157, symbol("h")))
                fields.append((790, .int(Int64(heading))))
            }
            if !runs.isEmpty {
                var written: [IonOut] = []
                for run in runs {
                    var members: [(Int, IonOut)] = [(143, .int(Int64(run.start))), (144, .int(Int64(run.length)))]
                    if let style = run.style { members.append((157, symbol(style))) }
                    if let link = run.link { members.append((179, symbol(link))) }
                    written.append(.structure(members))
                }
                fields.append((142, .list(written)))
            }
            fields.append(textField(text, content: content))
        case .container(let children):
            fields.append((159, .symbol(270)))
            fields.append((146, .list(nodes(children, content: content))))
        case .list(let ordered, let items):
            fields.append((159, .symbol(276)))
            fields.append((100, .symbol(ordered ? 343 : 342)))
            fields.append((146, .list(nodes(items, content: content))))
        case .item(let text, let children):
            fields.append((159, .symbol(277)))
            if let text { fields.append(textField(text, content: content)) }
            if !children.isEmpty { fields.append((146, .list(nodes(children, content: content)))) }
        case .table(let caption, let header, let rows):
            fields.append((159, .symbol(278)))
            var children: [IonOut] = []
            if let caption {
                // The caption is a text block holding a text block, classified as a caption.
                let captionID = newID()
                children.append(.structure([
                    (155, .int(Int64(captionID))), (159, .symbol(269)), (615, .symbol(453)),
                    (146, .list([textNode(caption, content: content)])),
                ]))
            }
            children.append(tableSection(151, rows: [header], content: content))
            children.append(tableSection(454, rows: rows, content: content))
            fields.append((146, .list(children)))
        case .image(let alt):
            fields.append((159, .symbol(271)))
            if let alt { fields.append((584, .string(alt))) }
        case .rule:
            fields.append((159, .symbol(596)))
        case .typed(let type, let children):
            fields.append((159, .symbol(type)))
            if !children.isEmpty { fields.append((146, .list(nodes(children, content: content)))) }
        case .inlineParent(let pieces):
            fields.append((159, .symbol(269)))
            var children: [IonOut] = []
            for piece in pieces {
                children.append(.structure([
                    (155, .int(Int64(newID()))), (159, .symbol(269)), (601, .symbol(283)), textField(piece, content: content),
                ]))
            }
            fields.append((146, .list(children)))
        case .mixed(let pieces, let runs, let heading):
            fields.append((159, .symbol(269)))
            if let heading {
                fields.append((157, symbol("h")))
                fields.append((790, .int(Int64(heading))))
            }
            if !runs.isEmpty {
                var written: [IonOut] = []
                for run in runs {
                    var members: [(Int, IonOut)] = [(143, .int(Int64(run.start))), (144, .int(Int64(run.length)))]
                    if let style = run.style { members.append((157, symbol(style))) }
                    if let link = run.link { members.append((179, symbol(link))) }
                    written.append(.structure(members))
                }
                fields.append((142, .list(written)))
            }
            var children: [IonOut] = []
            for piece in pieces { children.append(inlineChild(piece, content: content)) }
            fields.append((146, .list(children)))
        case .raw:
            break
        }
        return .structure(fields)
    }

    // MARK: Building

    /// The book's container bytes, with whatever `adjust` does to the
    /// container's builder before they are made.
    mutating func build(adjust: (inout KFXContainerBuilder) -> Void = { _ in }) -> [UInt8] {
        // Write the sections first, so every local name is registered.
        var storylineValues: [(String, IonOut)] = []
        var sectionValues: [(String, IonOut)] = []
        var order: [IonOut] = []
        for (index, section) in sections.enumerated() {
            let content = "content_\(index + 1)"
            let storyline = "story_\(section.name)"
            let body = nodes(section.nodes, content: content)
            let templateID = newID()
            storylineValues.append((storyline, .structure([(176, symbol(storyline)), (146, .list(body))])))
            sectionValues.append((section.name, .structure([
                (174, symbol(section.name)),
                (141, .list([.structure([(155, .int(Int64(templateID))), (176, symbol(storyline)), (159, .symbol(269))])])),
            ])))
            order.append(symbol(section.name))
        }
        var styleValues: [(String, IonOut)] = []
        for name in styles.keys.sorted() {
            guard let style = styles[name] else { continue }
            var fields: [(Int, IonOut)] = [(173, symbol(name))]
            if style.bold { fields.append((13, .symbol(362))) }
            if style.italic { fields.append((12, .symbol(382))) }
            if style.heading { fields.append((761, .list([.symbol(760)]))) }
            styleValues.append((name, .structure(fields)))
        }
        var anchorValues: [(String, IonOut)] = []
        for name in anchors.keys.sorted() {
            guard let anchor = anchors[name] else { continue }
            var fields: [(Int, IonOut)] = [(180, symbol(name))]
            if let url = anchor.url { fields.append((186, .string(url))) }
            if let node = anchor.node {
                var position: [(Int, IonOut)] = [(155, .int(Int64(node)))]
                if anchor.offset != 0 { position.append((143, .int(Int64(anchor.offset)))) }
                fields.append((183, .structure(position)))
            }
            anchorValues.append((name, .structure(fields)))
        }
        var contentValues: [(String, IonOut)] = []
        for name in contents.keys.sorted() {
            let strings = contents[name] ?? []
            contentValues.append((name, .structure([(4, symbol(name)), (146, .list(strings.map { .string($0) }))])))
        }

        var entries: [IonOut] = []
        if let title { entries.append(.structure([(492, .string("title")), (307, .string(title))])) }
        for author in authors { entries.append(.structure([(492, .string("author")), (307, .string(author))])) }
        if let language { entries.append(.structure([(492, .string("language")), (307, .string(language))])) }
        let capabilityEntries = capabilities.map { IonOut.structure([(492, .string($0.key)), (307, $0.value)]) }

        var out = container
        out.sharedMaximum = 859
        out.localSymbols = localNames
        out.add(type: 490, .structure([(491, .list([
            .structure([(495, .string("kindle_title_metadata")), (258, .list(entries))]),
            .structure([(495, .string("kindle_capability_metadata")), (258, .list(capabilityEntries))]),
        ]))]))
        out.add(type: 538, .structure(documentData + [
            (169, .list([.structure([(178, .symbol(351)), (170, .list(order))])])),
        ]))
        if let navigation { out.add(type: 389, navigation(writtenIDs)) }
        for (name, value) in sectionValues { out.entities.append(.init(id: out.id(of: name), type: 260, value: value)) }
        for (name, value) in storylineValues { out.entities.append(.init(id: out.id(of: name), type: 259, value: value)) }
        for (name, value) in contentValues { out.entities.append(.init(id: out.id(of: name), type: 145, value: value)) }
        for (name, value) in styleValues { out.entities.append(.init(id: out.id(of: name), type: 157, value: value)) }
        for (name, value) in anchorValues { out.entities.append(.init(id: out.id(of: name), type: 266, value: value)) }
        adjust(&out)
        return out.build()
    }
}

/// The book navigation (`$389`) of the default reading order holding one
/// container of `type` (212 contents, 237 page list) whose units, with their
/// labels, point at a node and an offset in code points.
func kfxNavigation(type: Int, name: String = "n1", _ units: [(label: String, node: Int, offset: Int)]) -> IonOut {
    var written: [IonOut] = []
    for unit in units {
        let label: IonOut = .structure([(244, .string(unit.label))])
        let position: IonOut = .structure([(155, .int(Int64(unit.node))), (143, .int(Int64(unit.offset)))])
        written.append(.annotated([393], .structure([(241, label), (246, position)])))
    }
    let container: IonOut = .annotated([391], .structure([(235, .symbol(type)), (239, .string(name)), (247, .list(written))]))
    return .list([.structure([(178, .symbol(351)), (392, .list([container]))])])
}
