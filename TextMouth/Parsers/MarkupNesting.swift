import Foundation

// MARK: - The Open Elements of an XML Parse

/// The elements SwiftSoup's XML parser holds open as it reads, which is exact
/// and simple: a start tag that does not close itself pushes its name, whatever
/// the name is (`<br>` too, and `<p>`, since XML has no void elements and
/// closes nothing by itself), and an end tag pops down to the nearest open
/// element of the same name, in the same letter case, and does nothing when
/// none is open (`XmlTreeBuilder.popStackToClose`).
struct XMLOpenElements {
    /// An open element's name: where it is in the bytes, with a hash of it, so
    /// that an end tag compares most names without touching their bytes.
    private struct Open {
        var name: Range<Int>
        var hash: UInt64
    }

    /// The markup.
    let bytes: [UInt8]
    /// The open elements, innermost last.
    private var open: [Open] = []

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// How many elements are open.
    var depth: Int { open.count }

    /// A start tag has been read.
    mutating func start(_ tag: MarkupScanner.Tag) {
        guard !tag.isSelfClosing else { return }
        open.append(Open(name: tag.name, hash: Self.hash(bytes[tag.name])))
    }

    /// An end tag has been read. The stack is as deep as the guard allows at
    /// most, so the search stays cheap whatever the markup holds.
    mutating func end(_ tag: MarkupScanner.Tag) {
        let hash = Self.hash(bytes[tag.name])
        guard let match = open.lastIndex(where: { candidate in
            candidate.hash == hash && bytes[candidate.name].elementsEqual(bytes[tag.name])
        }) else { return }
        open.removeSubrange(match...)
    }

    /// FNV-1a: fast, and an end tag's name is compared byte by byte when it matches.
    private static func hash(_ name: ArraySlice<UInt8>) -> UInt64 {
        name.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3 }
    }
}

// MARK: - The Tree of an HTML Parse

/// What SwiftSoup's HTML parser makes of markup, followed rule by rule without
/// building its tree: its insertion modes, its stack of open elements, its list
/// of active formatting elements, its form and head pointers, and where each
/// element it makes goes, so that the depth of every element is known.
///
/// It follows SwiftSoup 2.13.9's own code (`HtmlTreeBuilder` and
/// `HtmlTreeBuilderState`, MIT), with its slips, rather than the HTML standard:
/// `generateImpliedEndTags` with nothing to exclude does nothing; `<frameset>`
/// in the body is an ordinary element; `InBodyStartDrop` drops table parts; an
/// explicit `<body>` start tag goes through `AfterHead`; `InSelect` serves a
/// `select` in a table too; the adoption agency looks for its block among the
/// first 64 elements of the stack and makes no list entry for its copy; and
/// `InTableBody` asks whether `tfoot` is in the ordinary scope, where markers stop it.
///
/// What it counts is the depth of the deepest element, `html` at 1, and it must
/// never count less than the parser's real tree will have. So where the parser
/// moves elements (foster parenting, the adoption agency), an element's depth is
/// never lowered, only raised; where the markup cannot say which of two paths the
/// parser takes (whether text made of character references is whitespace), the
/// model takes the one that builds deeper; and where neither path can be followed
/// tag by tag (a `noscript` that may be in the head, holding what the tokeniser
/// would read differently there), it stops trusting tags (`tagsAreCertain`), and
/// the guard counts every one that could lie ahead. `MarkupGuardTests` and the
/// harness's differential of repeated units hold it against SwiftSoup's real trees.
struct HTMLTreeModel {

    // MARK: Elements

    /// An element the parser has made.
    private struct Element {
        let id: Int
        let name: String
        /// How deep it is in the tree: `html` is at 1.
        var depth: Int
        /// The deepest element at or inside it, so far as it is known.
        var reach: Int
        /// How many nodes had been made before it: more than the children it can ever hold.
        let madeBefore: Int
        /// Its tag's attributes, as bytes and as a count, which a copy of it takes too.
        let attributes: Range<Int>
        let attributeCount: Int
    }

    /// The parser's insertion modes (`HtmlTreeBuilderState`). `Text` and
    /// `InTableText` are folded into the modes that enter them: the tokeniser
    /// reads a raw text element's text and end tag at once, and table text is
    /// handled as it comes. `InSelectInTable` is never entered by this parser.
    private enum Mode {
        case initial, beforeHtml, beforeHead, inHead, inHeadNoscript, afterHead, inBody
        case inTable, inCaption, inColumnGroup, inTableBody, inRow, inCell, inSelect
        case afterBody, inFrameset, afterFrameset, afterAfterBody, afterAfterFrameset
    }

    /// A token, as the tree builder receives it. The end of the markup is kept
    /// among them as the parser has it, though the pass sends none: nothing
    /// the parser does at the end makes an element deeper than one already made.
    private enum Token {
        case start(StartTag)
        case end(String)
        case text(TextKind)
        case eof
    }

    /// A start tag: one in the markup, with its attributes, or one the parser makes up.
    private struct StartTag {
        let name: String
        var attributes: Range<Int> = 0..<0
        var attributeCount = 0
        var isSelfClosing = false
        /// Whether an `input`'s type is surely `hidden`, surely not, or unknown (nil).
        var isHiddenInput: Bool? = false
    }

    /// What a run of text is to the parser, which treats whitespace apart.
    enum TextKind {
        /// Only the parser's whitespace: tab, line feed, form feed, carriage return, space.
        case whitespace
        /// Something else, for certain.
        case words
        /// Only whitespace and character references, which might decode to whitespace.
        case uncertain
    }

    // MARK: Rules' Tag Sets (SwiftSoup's `TagSets` and `Constants`)

    private static let special: Set<String> = [
        "address", "applet", "area", "article", "aside", "base", "basefont", "bgsound", "blockquote", "body", "br", "button",
        "caption", "center", "col", "colgroup", "command", "dd", "details", "dir", "div", "dl", "dt", "embed", "fieldset",
        "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header",
        "hgroup", "hr", "html", "iframe", "img", "input", "isindex", "li", "link", "listing", "marquee", "menu", "meta", "nav",
        "noembed", "noframes", "noscript", "object", "ol", "p", "param", "plaintext", "pre", "script", "section", "select",
        "style", "summary", "table", "tbody", "td", "textarea", "tfoot", "th", "thead", "title", "tr", "ul", "wbr", "xmp",
    ]
    /// What ends a search of the stack for an element in scope (`TagSets.inScope`).
    private static let scopeLimits: Set<String> = ["applet", "caption", "html", "table", "td", "th", "marquee", "object"]
    /// What `generateImpliedEndTags` pops (`TagSets.endTags`).
    private static let impliedEnds: Set<String> = ["dd", "dt", "li", "option", "optgroup", "p", "rp", "rt"]
    private static let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    private static let formatters: Set<String> = ["b", "big", "code", "em", "font", "i", "s", "small", "strike", "strong", "tt", "u"]
    private static let adoptionFormatters: Set<String> = [
        "a", "b", "big", "code", "em", "font", "i", "nobr", "s", "small", "strike", "strong", "tt", "u",
    ]
    private static let pClosers: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "dir", "div", "dl", "fieldset", "figcaption", "figure",
        "footer", "header", "hgroup", "menu", "nav", "ol", "p", "section", "summary", "ul",
    ]
    private static let endClosers: Set<String> = [
        "address", "article", "aside", "blockquote", "button", "center", "details", "dir", "div", "dl", "fieldset", "figcaption",
        "figure", "footer", "header", "hgroup", "listing", "menu", "nav", "ol", "pre", "section", "summary", "ul",
    ]
    private static let toHead: Set<String> = ["base", "basefont", "bgsound", "command", "link", "meta", "noframes", "script", "style", "title"]
    private static let emptyFormatters: Set<String> = ["area", "br", "embed", "hr", "img", "keygen", "wbr"]
    private static let media: Set<String> = ["param", "source", "track"]
    private static let dropped: Set<String> = ["caption", "col", "colgroup", "frame", "head", "tbody", "td", "tfoot", "th", "thead", "tr"]
    private static let liBreakers: Set<String> = ["address", "div", "p"]
    private static let tableElements: Set<String> = ["table", "tbody", "tfoot", "thead", "tr"]
    private static let tableSections: Set<String> = ["tbody", "tfoot", "thead"]
    private static let tableRowsAndCols: Set<String> = ["caption", "col", "colgroup", "tbody", "td", "tfoot", "th", "thead", "tr"]
    private static let tableMix: Set<String> = ["body", "caption", "col", "colgroup", "html", "tbody", "td", "tfoot", "th", "thead", "tr"]
    private static let baseEtc: Set<String> = ["base", "basefont", "bgsound", "command", "link"]
    private static let baseEtc2: Set<String> = ["basefont", "bgsound", "link", "meta", "noframes", "style"]
    private static let baseEtc3: Set<String> = ["base", "basefont", "bgsound", "link", "meta", "noframes", "script", "style", "title"]
    /// What the tokeniser would read differently in a `noscript` of the head, as text there.
    private static let readDifferentlyInHeadNoscript: Set<String> = ["title", "script", "plaintext", "select"]

    // MARK: State

    /// The markup.
    let bytes: [UInt8]
    /// The stack of open elements, `html` first.
    private var stack: [Element] = []
    /// The active formatting elements; nil is a marker.
    private var active: [Element?] = []
    private var mode = Mode.initial
    /// Inserts go to the foster parent, beside the table (`fosterInserts`).
    private var fosterInserts = false
    /// The form element pointer: the form a later `<form>` would be ignored for.
    private var form: Element?
    /// The head element pointer.
    private var head: Element?
    /// A fragment parse in a body (`parseBodyFragment`): `html` stands for the body.
    private let isFragment: Bool
    private var nextID = 0
    /// How deep the deepest element is.
    private(set) var deepest = 0
    /// What SwiftSoup spends beyond each tag's own node.
    struct Costs: Equatable {
        /// Elements made again, or made up by the parser for a tag that implies them.
        var elements = 0
        /// How many of them hold attributes.
        var elementsWithAttributes = 0
        /// The attributes copied onto them.
        var attributes = 0
        /// Time that grows with the square of the markup, in about a nanosecond each.
        var work = 0
    }
    private(set) var costs = Costs()
    /// How many start tags have been read.
    private var startTags = 0
    /// The attributes `html` and `body` tags have added to the one of each.
    private var rootAttributes = 0
    /// End tags the parser makes up for a self-closed element, to read after the tag.
    private var madeUpEnds: [String] = []
    /// What the tokeniser does after the start tag being read.
    private var tokeniserChange = TokeniserChange.none
    /// How deep the rules are in each other, to stop a rule that would never end.
    private var nesting = 0
    /// Whether the rest of the markup can be read tag by tag.
    private(set) var tagsAreCertain = true
    /// Text that may have been whitespace began the body, so the head may still be open.
    private var bodyMayBeHead = false
    /// The `noscript` elements opened while the head may still have been open.
    private var noscriptsMaybeInHead: Set<Int> = []

    init(bytes: [UInt8], fragment: Bool = false) {
        self.bytes = bytes
        isFragment = fragment
        if fragment {
            // parseFragment: a root `html` on the stack, with the body as context, read in the body's mode.
            // The fragment's nodes end up in the body of the document, so the root stands at the body's depth.
            let root = Element(id: takeID(), name: "html", depth: 2, reach: 2, madeBefore: 0, attributes: 0..<0, attributeCount: 0)
            stack = [root]
            mode = .inBody
            deepest = 2
        }
    }

    /// What the tokeniser must do for the start tag just handled, if anything.
    enum TokeniserChange {
        case none
        case rawText(MarkupScanner.RawText)
        /// The rest of the markup is text (`<plaintext>`).
        case rest
    }

    /// How deep the current node is, below which every tag still to come could open.
    var openDepth: Int { stack.last?.depth ?? 0 }

    // MARK: Tokens In

    /// Text has been read in the tokeniser's `Data` state.
    mutating func text(_ range: Range<Int>) {
        let kind = Self.kind(of: bytes[range])
        if kind == .words { bodyMayBeHead = false }
        process(.text(kind))
        readMadeUpEnds()
    }

    /// A start tag has been read; what the tokeniser does next.
    mutating func start(_ tag: MarkupScanner.Tag, name: String) -> TokeniserChange {
        startTags += 1
        tokeniserChange = .none
        if name == "html" || name == "body" {
            // Each attribute that goes onto the one `html` or `body` is first looked for among those there: 100 nanoseconds each.
            rootAttributes += tag.attributeCount
            costs.work += tag.attributeCount * rootAttributes * 100
        }
        // Where the head might still be open, anything but what a head holds would have ended it there too.
        if bodyMayBeHead, !Self.headCompatible.contains(name) { bodyMayBeHead = false }
        var start = StartTag(name: name, attributes: tag.attributes, attributeCount: tag.attributeCount, isSelfClosing: tag.isSelfClosing)
        if name == "input" { start.isHiddenInput = isHidden(tag) }
        process(.start(start))
        readMadeUpEnds()
        return tagsAreCertain ? tokeniserChange : .none
    }

    /// An end tag has been read.
    mutating func end(name: String) {
        if bodyMayBeHead, ["head", "body", "html", "br"].contains(name) { bodyMayBeHead = false }
        process(.end(name))
        readMadeUpEnds()
    }

    /// What can stand in a head without ending it (`InHead`'s own start tags).
    private static let headCompatible: Set<String> = [
        "html", "head", "base", "basefont", "bgsound", "command", "link", "meta", "title", "noframes", "style", "noscript", "script",
    ]

    /// The end tags `insert` made up for self-closed elements, read as the tokeniser emits them, after the tag.
    private mutating func readMadeUpEnds() {
        while !madeUpEnds.isEmpty, tagsAreCertain {
            process(.end(madeUpEnds.removeFirst()))
        }
    }

    // MARK: Text Kinds

    /// What `text` is to the parser: whitespace for certain, words for certain, or
    /// whitespace and character references, which the tokeniser decodes first.
    static func kind(of text: ArraySlice<UInt8>) -> TextKind {
        var sawReference = false
        var index = text.startIndex
        while index < text.endIndex {
            let byte = text[index]
            if byte == Ascii.ampersand {
                // A reference's own letters, digits, `#`, and `;` might decode to whitespace.
                sawReference = true
                index += 1
                while index < text.endIndex, Ascii.isLetter(text[index]) || Ascii.isDigit(text[index]) || text[index] == Ascii.hash
                    || text[index] == Ascii.semicolon {
                    index += 1
                }
                continue
            }
            if !Self.isParserWhitespace(byte) { return .words }
            index += 1
        }
        return sawReference ? .uncertain : .whitespace
    }

    /// `HtmlTreeBuilderState.whitespaceTable`: tab, line feed, form feed, carriage return, space.
    private static func isParserWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D || byte == 0x20
    }

    /// Whether `tag`'s `type` attribute is `hidden` (`InTable` puts such an
    /// `input` in the table itself), or nil when a character reference in it
    /// keeps that unknown.
    private func isHidden(_ tag: MarkupScanner.Tag) -> Bool? {
        guard let value = Self.firstValue(of: Array("type".utf8), in: bytes[tag.attributes]) else { return false }
        if value.contains(Ascii.ampersand) { return nil }
        return value.count == 6 && zip(value, Array("hidden".utf8)).allSatisfy { Ascii.lowercased($0) == $1 }
    }

    /// The value of the first attribute named `name` (in lower case) among a
    /// tag's attributes, as the tokeniser reads them: a name ends at
    /// whitespace, `/`, `=`, or the tag's end, and a value is quoted or runs
    /// to whitespace. Nil when there is no such attribute; empty for one
    /// without a value.
    private static func firstValue(of name: [UInt8], in attributes: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        var index = attributes.startIndex
        let end = attributes.endIndex
        while index < end {
            // Before a name.
            while index < end, Ascii.isTagSpace(attributes[index]) || attributes[index] == Ascii.slash { index += 1 }
            let nameStart = index
            index += 1
            while index < end, !Ascii.isTagSpace(attributes[index]), attributes[index] != Ascii.slash, attributes[index] != Ascii.equals {
                index += 1
            }
            let found = attributes[nameStart..<min(index, end)]
            let matches = found.count == name.count && zip(found, name).allSatisfy { Ascii.lowercased($0) == $1 }
            // After the name: an `=` and a value, or another name.
            var probe = index
            while probe < end, Ascii.isTagSpace(attributes[probe]) { probe += 1 }
            guard probe < end, attributes[probe] == Ascii.equals else {
                if matches { return attributes[end..<end] }
                index = probe
                continue
            }
            probe += 1
            while probe < end, Ascii.isTagSpace(attributes[probe]) { probe += 1 }
            var value = attributes[end..<end]
            if probe < end, attributes[probe] == Ascii.doubleQuote || attributes[probe] == Ascii.singleQuote {
                let quote = attributes[probe]
                let valueStart = probe + 1
                probe = valueStart
                while probe < end, attributes[probe] != quote { probe += 1 }
                value = attributes[valueStart..<probe]
                probe = min(probe + 1, end)
            } else {
                let valueStart = probe
                while probe < end, !Ascii.isTagSpace(attributes[probe]) { probe += 1 }
                value = attributes[valueStart..<probe]
            }
            if matches { return value }
            index = probe
        }
        return nil
    }

    // MARK: Processing

    /// `process(t)`: the token by the rules of the current mode.
    @discardableResult
    private mutating func process(_ token: Token) -> Bool {
        process(token, in: mode)
    }

    /// `process(t, state)`: the token by the rules of `mode`, which the mode itself does not change.
    @discardableResult
    private mutating func process(_ token: Token, in mode: Mode) -> Bool {
        guard tagsAreCertain else { return true }
        nesting += 1
        defer { nesting -= 1 }
        // The parser's rules hand a token on a few times at most; a model that went on would be wrong.
        guard nesting < 64 else {
            tagsAreCertain = false
            return true
        }
        switch mode {
        case .initial: return initial(token)
        case .beforeHtml: return beforeHtml(token)
        case .beforeHead: return beforeHead(token)
        case .inHead: return inHead(token)
        case .inHeadNoscript: return inHeadNoscript(token)
        case .afterHead: return afterHead(token)
        case .inBody: return inBody(token)
        case .inTable: return inTable(token)
        case .inCaption: return inCaption(token)
        case .inColumnGroup: return inColumnGroup(token)
        case .inTableBody: return inTableBody(token)
        case .inRow: return inRow(token)
        case .inCell: return inCell(token)
        case .inSelect: return inSelect(token)
        case .afterBody: return afterBody(token)
        case .inFrameset: return inFrameset(token)
        case .afterFrameset: return afterFrameset(token)
        case .afterAfterBody: return afterAfterBody(token)
        case .afterAfterFrameset: return afterAfterFrameset(token)
        }
    }

    /// `processStartTag(name)`: a start tag the parser makes up, by the current mode.
    @discardableResult
    private mutating func processStartTag(_ name: String) -> Bool {
        process(.start(StartTag(name: name)))
    }

    /// `processEndTag(name)`: an end tag the parser makes up, by the current mode.
    @discardableResult
    private mutating func processEndTag(_ name: String) -> Bool {
        process(.end(name))
    }

    /// Text in a mode before the body: words for certain, or text that may be
    /// whitespace, which the model reads as words, since the body that begins
    /// then holds what the head would. The head may then still be open.
    private mutating func isWordsBeforeBody(_ kind: TextKind) -> Bool {
        switch kind {
        case .whitespace: return false
        case .words: return true
        case .uncertain:
            bodyMayBeHead = true
            return true
        }
    }

    // MARK: Before the Body

    /// `Initial`.
    private mutating func initial(_ token: Token) -> Bool {
        if case let .text(kind) = token, !isWordsBeforeBody(kind) { return true }
        mode = .beforeHtml
        return process(token)
    }

    /// `BeforeHtml`.
    private mutating func beforeHtml(_ token: Token) -> Bool {
        func anythingElse(_ model: inout HTMLTreeModel) -> Bool {
            model.insertMadeUp("html", counted: false)
            model.mode = .beforeHead
            return model.process(token)
        }
        switch token {
        case let .text(kind):
            return isWordsBeforeBody(kind) ? anythingElse(&self) : true
        case let .start(start) where start.name == "html":
            insert(start)
            mode = .beforeHead
            return true
        case let .end(name):
            return ["head", "body", "html", "br"].contains(name) ? anythingElse(&self) : false
        default:
            return anythingElse(&self)
        }
    }

    /// `BeforeHead`.
    private mutating func beforeHead(_ token: Token) -> Bool {
        switch token {
        case let .text(kind) where !isWordsBeforeBody(kind):
            return true
        case let .start(start) where start.name == "html":
            return inBody(token)
        case let .start(start) where start.name == "head":
            head = insert(start)
            mode = .inHead
            return true
        case let .end(name) where !["head", "body", "html", "br"].contains(name):
            return false
        default:
            // The made-up head is the parser's own, and costs what any element does once.
            processStartTag("head")
            return process(token)
        }
    }

    /// `InHead`.
    private mutating func inHead(_ token: Token) -> Bool {
        func anythingElse(_ model: inout HTMLTreeModel) -> Bool {
            model.processEndTag("head")
            return model.process(token)
        }
        switch token {
        case let .text(kind):
            return isWordsBeforeBody(kind) ? anythingElse(&self) : true
        case let .start(start):
            switch start.name {
            case "html": return inBody(token)
            case "meta": insertEmpty(start)
            case "title": insertRawText(start, .replaceable)
            case "noframes", "style": insertRawText(start, .plain)
            case "noscript":
                insert(start)
                mode = .inHeadNoscript
            case "script": insertRawText(start, .script)
            case "head": return false
            default:
                if Self.baseEtc.contains(start.name) {
                    insertEmpty(start)
                } else {
                    return anythingElse(&self)
                }
            }
            return true
        case let .end(name):
            if name == "head" {
                pop()
                mode = .afterHead
                return true
            }
            return ["body", "html", "br"].contains(name) ? anythingElse(&self) : false
        case .eof:
            return anythingElse(&self)
        }
    }

    /// `InHeadNoscript`: what is not allowed there is read as text.
    private mutating func inHeadNoscript(_ token: Token) -> Bool {
        switch token {
        case let .start(start) where start.name == "html":
            return process(token, in: .inBody)
        case let .end(name) where name == "noscript":
            pop()
            mode = .inHead
            return true
        case .text(.whitespace):
            return process(token, in: .inHead)
        case let .start(start) where Self.baseEtc2.contains(start.name):
            return process(token, in: .inHead)
        case let .end(name) where name == "br":
            return true
        case let .start(start) where start.name == "head" || start.name == "noscript":
            return false
        case .end:
            return false
        default:
            // Inserted as text, which makes no element.
            return true
        }
    }

    /// `AfterHead`.
    private mutating func afterHead(_ token: Token) -> Bool {
        func anythingElse(_ model: inout HTMLTreeModel) -> Bool {
            model.processStartTag("body")
            return model.process(token)
        }
        switch token {
        case let .text(kind):
            return isWordsBeforeBody(kind) ? anythingElse(&self) : true
        case let .start(start):
            switch start.name {
            case "html": return process(token, in: .inBody)
            case "body":
                insert(start)
                mode = .inBody
            case "frameset":
                insert(start)
                mode = .inFrameset
            case "head": return false
            default:
                guard Self.baseEtc3.contains(start.name), let head else { return anythingElse(&self) }
                // The head goes back on the stack for the tag alone.
                push(head)
                process(token, in: .inHead)
                removeFromStack(head.id)
            }
            return true
        case let .end(name):
            return name == "body" || name == "html" ? anythingElse(&self) : false
        case .eof:
            return anythingElse(&self)
        }
    }

    // MARK: The Body

    /// `InBody`.
    private mutating func inBody(_ token: Token) -> Bool {
        switch token {
        case .text:
            if lastFormattingElement != nil { reconstructFormatting() }
            return true
        case .eof:
            return true
        case let .start(start):
            return inBodyStart(start, token)
        case let .end(name):
            return inBodyEnd(name, token)
        }
    }

    /// `InBody`'s start tags.
    private mutating func inBodyStart(_ start: StartTag, _ token: Token) -> Bool {
        let name = start.name
        noteMaybeInHeadNoscript(name)
        // The parser reads the current node once, as the tag begins, and its rules below ask after it as it was then.
        let current = stack.last?.name
        switch name {
        case "a":
            if activeElement(named: "a") != nil {
                processEndTag("a")
                if let remaining = stack.last(where: { $0.name == "a" }) {
                    removeActive(remaining.id)
                    removeFromStack(remaining.id)
                }
            }
            reconstructIfNeeded()
            pushActive(insert(start))
        case "span":
            reconstructIfNeeded()
            insert(start)
        case "li", "dd", "dt":
            closeListItem(named: name)
            closePIfInButtonScope(current)
            insert(start)
        case "applet", "marquee", "object":
            reconstructIfNeeded()
            insert(start)
            insertMarker()
        case "embed":
            insertEmpty(start)
        case "rp", "rt":
            if isInScope("ruby") {
                if stack.last?.name != "ruby" { popStackToBefore("ruby") }
                insert(start)
            }
        case "table":
            closePIfInButtonScope(current)
            insert(start)
            mode = .inTable
        case "form":
            guard form == nil else { return false }
            if isInButtonScope("p") { processEndTag("p") }
            insertForm(start, onStack: true)
        case "html":
            break
        case "body":
            guard stack.contains(where: { $0.name == "body" }) else { return false }
        case "input", "br", "img", "hr":
            reconstructIfNeeded()
            insertEmpty(start)
        case "meta", "script", "style", "title":
            return process(token, in: .inHead)
        case "select":
            reconstructIfNeeded()
            insert(start)
            mode = .inSelect
        case "plaintext":
            reconstructIfNeeded()
            insert(start)
            tokeniserChange = .rest
        case "option", "optgroup":
            if stack.last?.name == "option" { processEndTag("option") }
            reconstructIfNeeded()
            insert(start)
        default:
            if Self.formatters.contains(name) {
                reconstructIfNeeded()
                pushActive(insert(start))
            } else if Self.emptyFormatters.contains(name) {
                reconstructIfNeeded()
                insertEmpty(start)
            } else if Self.pClosers.contains(name) {
                closePIfInButtonScope(current)
                insert(start)
            } else if Self.toHead.contains(name) {
                return process(token, in: .inHead)
            } else if Self.headings.contains(name) {
                closePIfInButtonScope(current)
                // A heading in a heading: the parser pops whatever is current now, if a heading was current when the tag began.
                if let current, Self.headings.contains(current) { pop() }
                insert(start)
            } else if name == "pre" || name == "listing" {
                closePIfInButtonScope(current)
                insert(start)
            } else if Self.media.contains(name) {
                insertEmpty(start)
            } else if Self.dropped.contains(name) {
                return false
            } else {
                reconstructIfNeeded()
                let element = insert(start)
                // A noscript that would have been in the head, had text of character references been whitespace.
                if name == "noscript", bodyMayBeHead { noscriptsMaybeInHead.insert(element.id) }
            }
        }
        return true
    }

    /// A tag the tokeniser would read differently in a `noscript` of the head,
    /// inside a `noscript` that may be in the head: the markup can no longer be
    /// read tag by tag.
    private mutating func noteMaybeInHeadNoscript(_ name: String) {
        guard !noscriptsMaybeInHead.isEmpty, Self.readDifferentlyInHeadNoscript.contains(name),
              stack.contains(where: { noscriptsMaybeInHead.contains($0.id) }) else { return }
        tagsAreCertain = false
    }

    /// `li`, `dd`, `dt`: closes the nearest of the same kind, unless a special
    /// element other than `address`, `div`, and `p` stands between.
    private mutating func closeListItem(named name: String) {
        let kinds: Set<String> = name == "li" ? ["li"] : ["dd", "dt"]
        if let current = stack.last, kinds.contains(current.name) {
            processEndTag(current.name)
            return
        }
        var index = stack.count
        while index > 1 {
            index -= 1
            let element = stack[index]
            if kinds.contains(element.name) {
                processEndTag(element.name)
                return
            }
            if Self.special.contains(element.name), !Self.liBreakers.contains(element.name) { return }
        }
    }

    /// `closePIfInButtonScope`, with the current node as it was when the tag began.
    private mutating func closePIfInButtonScope(_ current: String?) {
        if current == "p" {
            processEndTag("p")
        } else if isInButtonScope("p") {
            processEndTag("p")
        }
    }

    /// `InBody`'s end tags.
    private mutating func inBodyEnd(_ name: String, _ token: Token) -> Bool {
        if Self.adoptionFormatters.contains(name) { return adoptionAgency(name) }
        switch name {
        case "span":
            return anyOtherEnd(name)
        case "div":
            guard isInScope("div") else { return false }
            popStackToClose("div")
        case "li":
            guard isInScope("li", extraLimits: ["ol", "ul"]) else { return false }
            generateImpliedEnds(except: "li")
            popStackToClose("li")
        case "body":
            guard isInScope("body") else { return false }
            mode = .afterBody
        case "html":
            if processEndTag("body") { return process(token) }
        case "form":
            let current = form
            form = nil
            guard let current, isInScope("form") else { return false }
            removeFromStack(current.id)
        case "p":
            guard isInButtonScope("p") else {
                // No paragraph to close: an empty one is made, and closed.
                processMadeUpStart("p")
                return process(token)
            }
            generateImpliedEnds(except: "p")
            popStackToClose("p")
        case "dd", "dt":
            guard isInScope(name) else { return false }
            generateImpliedEnds(except: name)
            popStackToClose(name)
        case "applet", "marquee", "object":
            // By a slip, the parser first asks after an element named "name".
            guard !isInScope("name") else { break }
            guard isInScope(name) else { return false }
            popStackToClose(name)
            clearFormattingToMarker()
        case "br":
            processMadeUpStart("br")
            return false
        default:
            if Self.endClosers.contains(name) {
                guard isInScope(name) else { return false }
                popStackToClose(name)
            } else if Self.headings.contains(name) {
                guard stack.reversed().first(where: { Self.headings.contains($0.name) || Self.scopeLimits.contains($0.name) })
                    .map({ Self.headings.contains($0.name) }) == true else { return false }
                generateImpliedEnds(except: name)
                if let index = stack.lastIndex(where: { Self.headings.contains($0.name) }) { popAll(from: index) }
            } else {
                return anyOtherEnd(name)
            }
        }
        return true
    }

    /// `anyOtherEndTag`: closes the nearest element of the name, unless a special element stands between.
    @discardableResult
    private mutating func anyOtherEnd(_ name: String) -> Bool {
        var index = stack.count
        while index > 0 {
            index -= 1
            let element = stack[index]
            if element.name == name {
                generateImpliedEnds(except: name)
                if Self.adoptionFormatters.contains(name) { removeActive(element.id) }
                popStackToClose(name)
                return true
            }
            if Self.special.contains(element.name) { return false }
        }
        return true
    }

    /// The adoption agency, as SwiftSoup runs it, eight times at most.
    private mutating func adoptionAgency(_ name: String) -> Bool {
        for _ in 0..<8 {
            guard let format = activeElement(named: name) else { return anyOtherEnd(name) }
            guard let formatIndex = stack.lastIndex(where: { $0.id == format.id }) else {
                removeActive(format.id)
                return anyOtherEnd(name)
            }
            guard isInScope(format.name) else { return false }
            // The block is looked for among the first 64 elements of the stack only.
            var furthest: Int?
            var formatSeen: Int?
            for index in 0..<min(stack.count, 64) {
                if stack[index].id == format.id {
                    formatSeen = index
                } else if formatSeen != nil, Self.special.contains(stack[index].name) {
                    furthest = index
                    break
                }
            }
            guard let furthest, let seen = formatSeen, seen > 0 else {
                popStackToClose(format.name)
                removeActive(format.id)
                return true
            }
            _ = formatIndex
            let common = stack[seen - 1]
            var block = stack[furthest]
            // The block's children move to a copy of the formatting element, one
            // at a time, each shifting those after it: 2 nanoseconds a pair.
            let children = startTags + costs.elements - block.madeBefore
            costs.work += 2 * children * children
            // What the block's tree reaches before anything moves: its closed part, and what stands open above it.
            let closedReach = block.reach
            let openReach = stack[(furthest + 1)...].map(\.reach).max() ?? 0
            // Up to three elements between: those not active come off the stack, those active are copied.
            var node: Element? = block
            var chain: [Element] = []
            for _ in 0..<3 {
                if let current = node, let index = stack.lastIndex(where: { $0.id == current.id }) {
                    node = index > 0 ? stack[index - 1] : nil
                }
                guard let candidate = node else { break }
                if !isInActive(candidate.id) {
                    removeFromStack(candidate.id)
                    continue
                }
                if candidate.id == format.id { break }
                let copy = makeElement(candidate.name, depth: candidate.depth, attributes: 0..<0, attributeCount: 0)
                costs.elements += 1
                replaceActive(candidate.id, with: copy)
                replaceOnStack(candidate.id, with: copy)
                node = copy
                chain.append(copy)
            }
            // The chain, outermost first, goes into the common ancestor, or beside the last table.
            let base = Self.tableElements.contains(common.name) ? fosterDepth() - 1 : common.depth
            // The block goes inside the innermost copy, which may be higher or deeper than it was.
            let blockDepth = base + 1 + chain.count
            let delta = blockDepth - block.depth
            // Its children go into the copy of the formatting element, inside it: one level more than the block's move.
            let subtreeMove = delta + 1
            // What stands above the block on the stack is its own, open, unless foster parenting put it elsewhere,
            // where it stays: so it never goes higher, and goes deeper as the block's children do.
            let openMove = max(delta, 0) + 1
            let newReach = max(blockDepth + 1, closedReach + subtreeMove, openReach + openMove)
            if let blockIndex = stack.lastIndex(where: { $0.id == block.id }) {
                for index in (blockIndex + 1)..<stack.count {
                    stack[index].depth += openMove
                    stack[index].reach += openMove
                }
                stack[blockIndex].depth = blockDepth
                stack[blockIndex].reach = newReach
                block = stack[blockIndex]
            }
            // The copies stand where they go: new elements, one inside the other, around the block.
            for (offset, copy) in chain.reversed().enumerated() {
                if let index = stack.lastIndex(where: { $0.id == copy.id }) {
                    stack[index].depth = base + 1 + offset
                    stack[index].reach = newReach
                }
            }
            let adopter = makeElement(format.name, depth: blockDepth + 1, attributes: format.attributes, attributeCount: format.attributeCount)
            costs.elements += 1
            if format.attributeCount > 0 { costs.elementsWithAttributes += 1 }
            costs.attributes += format.attributeCount
            // Every element that was in the block's tree is now where its move puts it; none of them was counted less.
            note(depth: newReach)
            var placed = adopter
            placed.reach = newReach
            removeActive(format.id)
            removeFromStack(format.id)
            if let index = stack.lastIndex(where: { $0.id == block.id }) {
                stack.insert(placed, at: index + 1)
            }
        }
        return true
    }

    // MARK: Tables

    /// `InTable`.
    private mutating func inTable(_ token: Token) -> Bool {
        func anythingElse(_ model: inout HTMLTreeModel) -> Bool {
            model.inBodyFostered(token)
        }
        switch token {
        case let .text(kind):
            // `InTableText`: whitespace stays in the table; anything else, or what may be, goes to the body's rules, beside the table.
            if kind == .whitespace { return true }
            return inBodyFostered(.text(.words))
        case let .start(start):
            switch start.name {
            case "table":
                if processEndTag("table") { return process(token) }
                return true
            case "tbody", "thead", "tfoot":
                clearStack(toContext: ["table"])
                insert(start)
                mode = .inTableBody
            case "td", "th", "tr":
                processMadeUpStart("tbody")
                return process(token)
            case "caption":
                clearStack(toContext: ["table"])
                insertMarker()
                insert(start)
                mode = .inCaption
            case "colgroup":
                clearStack(toContext: ["table"])
                insert(start)
                mode = .inColumnGroup
            case "col":
                processMadeUpStart("colgroup")
                return process(token)
            case "script", "style":
                return process(token, in: .inHead)
            case "input":
                switch start.isHiddenInput {
                case true?:
                    insertEmpty(start)
                case false?:
                    return anythingElse(&self)
                case nil:
                    // Both, since which is unknown: a hidden one is a level deeper, the other may remake formatting.
                    note(depth: openDepth + 1)
                    return anythingElse(&self)
                }
            case "form":
                guard form == nil else { return false }
                insertForm(start, onStack: false)
            default:
                return anythingElse(&self)
            }
            return true
        case let .end(name):
            if name == "table" {
                guard isInTableScope("table") else { return false }
                popStackToClose("table")
                resetInsertionMode()
                return true
            }
            if Self.tableMix.contains(name) { return false }
            return anythingElse(&self)
        case .eof:
            return true
        }
    }

    /// `InTable`'s anything else: the body's rules, beside the table when what is current is a table's own element.
    private mutating func inBodyFostered(_ token: Token) -> Bool {
        guard let current = stack.last, Self.tableElements.contains(current.name) else { return process(token, in: .inBody) }
        fosterInserts = true
        let processed = process(token, in: .inBody)
        fosterInserts = false
        return processed
    }

    /// `InCaption`.
    private mutating func inCaption(_ token: Token) -> Bool {
        switch token {
        case let .end(name) where name == "caption":
            guard isInTableScope("caption") else { return false }
            popStackToClose("caption")
            clearFormattingToMarker()
            mode = .inTable
            return true
        case let .end(name) where ["body", "col", "colgroup", "html", "tbody", "td", "tfoot", "th", "thead", "tr"].contains(name):
            return false
        case let .start(start) where Self.tableRowsAndCols.contains(start.name):
            if processEndTag("caption") { return process(token) }
            return true
        case let .end(name) where name == "table":
            if processEndTag("caption") { return process(token) }
            return true
        default:
            return process(token, in: .inBody)
        }
    }

    /// `InColumnGroup`.
    private mutating func inColumnGroup(_ token: Token) -> Bool {
        func anythingElse(_ model: inout HTMLTreeModel) -> Bool {
            if model.processEndTag("colgroup") { return model.process(token) }
            return true
        }
        switch token {
        case .text(.whitespace):
            return true
        case let .start(start) where start.name == "html":
            return process(token, in: .inBody)
        case let .start(start) where start.name == "col":
            insertEmpty(start)
            return true
        case let .end(name) where name == "colgroup":
            guard stack.last?.name != "html" else { return false }
            pop()
            mode = .inTable
            return true
        case .eof:
            return stack.last?.name == "html" ? true : anythingElse(&self)
        default:
            return anythingElse(&self)
        }
    }

    /// `InTableBody`.
    private mutating func inTableBody(_ token: Token) -> Bool {
        func exitTableBody(_ model: inout HTMLTreeModel) -> Bool {
            // `tfoot` is asked after in the ordinary scope, where markers stop it: a slip of the parser.
            guard model.isInTableScope("tbody") || model.isInTableScope("thead") || model.isInScope("tfoot") else { return false }
            model.clearStack(toContext: Self.tableSections)
            if let current = model.stack.last { model.processEndTag(current.name) }
            return model.process(token)
        }
        switch token {
        case let .start(start):
            switch start.name {
            case "tr":
                clearStack(toContext: Self.tableSections)
                insert(start)
                mode = .inRow
                return true
            case "td", "th":
                processMadeUpStart("tr")
                return process(token)
            case "caption", "col", "colgroup", "tbody", "thead", "tfoot":
                return exitTableBody(&self)
            default:
                return process(token, in: .inTable)
            }
        case let .end(name):
            if Self.tableSections.contains(name) {
                guard isInTableScope(name) else { return false }
                clearStack(toContext: Self.tableSections)
                pop()
                mode = .inTable
                return true
            }
            if name == "table" { return exitTableBody(&self) }
            if ["body", "caption", "col", "colgroup", "html", "td", "th", "tr"].contains(name) { return false }
            return process(token, in: .inTable)
        default:
            return process(token, in: .inTable)
        }
    }

    /// `InRow`.
    private mutating func inRow(_ token: Token) -> Bool {
        func handleMissingTr(_ model: inout HTMLTreeModel) -> Bool {
            model.processEndTag("tr") ? model.process(token) : false
        }
        switch token {
        case let .start(start):
            switch start.name {
            case "td", "th":
                clearStack(toContext: ["tr"])
                insert(start)
                mode = .inCell
                insertMarker()
                return true
            case "caption", "col", "colgroup", "tbody", "tfoot", "thead", "tr":
                return handleMissingTr(&self)
            default:
                return process(token, in: .inTable)
            }
        case let .end(name):
            switch name {
            case "tr":
                guard isInTableScope("tr") else { return false }
                clearStack(toContext: ["tr"])
                pop()
                mode = .inTableBody
                return true
            case "table":
                return handleMissingTr(&self)
            case "body", "caption", "col", "colgroup", "html", "td", "th":
                return false
            default:
                return process(token, in: .inTable)
            }
        default:
            return process(token, in: .inTable)
        }
    }

    /// `InCell`.
    private mutating func inCell(_ token: Token) -> Bool {
        func closeCell(_ model: inout HTMLTreeModel) {
            if model.isInTableScope("td") {
                model.processEndTag("td")
            } else {
                model.processEndTag("th")
            }
        }
        switch token {
        case let .end(name):
            switch name {
            case "td", "th":
                guard isInTableScope(name) else {
                    mode = .inRow
                    return false
                }
                popStackToClose(name)
                clearFormattingToMarker()
                mode = .inRow
                return true
            case "body", "caption", "col", "colgroup", "html":
                return false
            default:
                if Self.tableElements.contains(name) {
                    guard isInTableScope(name) else { return false }
                    closeCell(&self)
                    return process(token)
                }
                return process(token, in: .inBody)
            }
        case let .start(start) where Self.tableRowsAndCols.contains(start.name):
            guard isInTableScope("td") || isInTableScope("th") else { return false }
            closeCell(&self)
            return process(token)
        default:
            return process(token, in: .inBody)
        }
    }

    // MARK: Select

    /// `InSelect`, which serves a `select` in a table too.
    private mutating func inSelect(_ token: Token) -> Bool {
        switch token {
        case .text, .eof:
            return true
        case let .start(start):
            switch start.name {
            case "input", "keygen", "textarea":
                guard isInSelectScope("select") else { return false }
                processEndTag("select")
                return process(token)
            case "script":
                return process(token, in: .inHead)
            case "html":
                return process(token, in: .inBody)
            case "option":
                if stack.last?.name == "option" { processEndTag("option") }
                insert(start)
            case "optgroup":
                if stack.last?.name == "option" {
                    processEndTag("option")
                } else if stack.last?.name == "optgroup" {
                    processEndTag("optgroup")
                }
                insert(start)
            case "select":
                return processEndTag("select")
            default:
                return false
            }
            return true
        case let .end(name):
            switch name {
            case "optgroup":
                // The parser reads the current node once, before closing an option, and asks after it again as it was.
                let current = stack.last?.name
                if current == "option", stack.count > 1, stack[stack.count - 2].name == "optgroup" { processEndTag("option") }
                if current == "optgroup" { pop() }
            case "option":
                if stack.last?.name == "option" { pop() }
            case "select":
                guard isInSelectScope("select") else { return false }
                popStackToClose("select")
                resetInsertionMode()
            default:
                return false
            }
            return true
        }
    }

    // MARK: After the Body, and Frames

    /// `AfterBody`.
    private mutating func afterBody(_ token: Token) -> Bool {
        switch token {
        case .text(.whitespace):
            return process(token, in: .inBody)
        case let .start(start) where start.name == "html":
            return process(token, in: .inBody)
        case let .end(name) where name == "html":
            if isFragment { return false }
            mode = .afterAfterBody
            return true
        case .eof:
            return true
        default:
            mode = .inBody
            return process(token)
        }
    }

    /// `InFrameset`.
    private mutating func inFrameset(_ token: Token) -> Bool {
        switch token {
        case .text, .eof:
            return true
        case let .start(start):
            switch start.name {
            case "html": return process(token, in: .inBody)
            case "frameset": insert(start)
            case "frame": insertEmpty(start)
            case "noframes": return process(token, in: .inHead)
            default: return false
            }
            return true
        case let .end(name):
            guard name == "frameset" else { return false }
            guard stack.last?.name != "html" else { return false }
            pop()
            if !isFragment, stack.last?.name != "frameset" { mode = .afterFrameset }
            return true
        }
    }

    /// `AfterFrameset`.
    private mutating func afterFrameset(_ token: Token) -> Bool {
        switch token {
        case .text, .eof:
            return true
        case let .start(start) where start.name == "html":
            return process(token, in: .inBody)
        case let .start(start) where start.name == "noframes":
            return process(token, in: .inHead)
        case let .end(name) where name == "html":
            mode = .afterAfterFrameset
            return true
        default:
            return false
        }
    }

    /// `AfterAfterBody`.
    private mutating func afterAfterBody(_ token: Token) -> Bool {
        switch token {
        case .text(.whitespace):
            return process(token, in: .inBody)
        case let .start(start) where start.name == "html":
            return process(token, in: .inBody)
        case .eof:
            return true
        default:
            mode = .inBody
            return process(token)
        }
    }

    /// `AfterAfterFrameset`.
    private mutating func afterAfterFrameset(_ token: Token) -> Bool {
        switch token {
        case .text(.whitespace):
            return process(token, in: .inBody)
        case let .start(start) where start.name == "html":
            return process(token, in: .inBody)
        case let .start(start) where start.name == "noframes":
            return process(token, in: .inHead)
        default:
            return true
        }
    }

    // MARK: Making Elements

    /// A new element's ID.
    private mutating func takeID() -> Int {
        nextID += 1
        return nextID
    }

    /// A new element, not yet anywhere.
    private mutating func makeElement(_ name: String, depth: Int, attributes: Range<Int>, attributeCount: Int) -> Element {
        Element(id: takeID(), name: name, depth: depth, reach: depth, madeBefore: startTags + costs.elements,
                attributes: attributes, attributeCount: attributeCount)
    }

    /// How deep an element the parser puts in the tree now goes (`insertNode`):
    /// into the current node, or, while inserts are fostered, beside the last
    /// table, in that table's parent.
    private func depthOfNextNode() -> Int {
        if stack.isEmpty { return 1 }
        if fosterInserts { return fosterDepth() }
        return stack[stack.count - 1].depth + 1
    }

    /// `insertInFosterParent`: before the last table on the stack, in its parent; or, with none, into `html`.
    private func fosterDepth() -> Int {
        if let table = stack.last(where: { $0.name == "table" }) { return table.depth }
        return stack[0].depth + 1
    }

    /// Records an element at `depth`.
    private mutating func note(depth: Int) {
        deepest = max(deepest, depth)
    }

    /// Puts a new element in the tree where the parser would, and records it: what the parser makes of a start tag, or of a name.
    private mutating func place(_ start: StartTag) -> Element {
        let depth = depthOfNextNode()
        let element = makeElement(start.name, depth: depth, attributes: start.attributes, attributeCount: start.attributeCount)
        note(depth: depth)
        // The parent's reach: the current node, or for a fostered one the table's own parent, near enough.
        if !stack.isEmpty {
            if fosterInserts, let table = stack.lastIndex(where: { $0.name == "table" }), table > 0 {
                stack[table - 1].reach = max(stack[table - 1].reach, depth)
            } else {
                stack[stack.count - 1].reach = max(stack[stack.count - 1].reach, depth)
            }
        }
        return element
    }

    /// `insert(startTag)`: the element goes in the tree and on the stack. One
    /// whose tag closes itself is followed by an end tag the parser makes up.
    @discardableResult
    private mutating func insert(_ start: StartTag) -> Element {
        let element = place(start)
        push(element)
        if start.isSelfClosing { madeUpEnds.append(start.name) }
        return element
    }

    /// `insertStartTag(name)`, for an element the parser makes up: counted as a
    /// node of its own, except the document's `html`, `head`, and `body`.
    private mutating func insertMadeUp(_ name: String, counted: Bool) {
        if counted { costs.elements += 1 }
        insert(StartTag(name: name))
    }

    /// `insertEmpty(startTag)`: the element goes in the tree, not on the stack.
    private mutating func insertEmpty(_ start: StartTag) {
        _ = place(start)
    }

    /// `insertForm`: the form goes in the tree, and on the stack too in the body.
    private mutating func insertForm(_ start: StartTag, onStack: Bool) {
        let element = place(start)
        form = element
        if onStack { push(element) }
    }

    /// A raw text element (`handleRcData`, `handleRawtext`, a script): it
    /// holds its text, which the tokeniser reads with its end tag, so it is
    /// made and closed at once. One whose tag closes itself has no text.
    private mutating func insertRawText(_ start: StartTag, _ kind: MarkupScanner.RawText) {
        _ = place(start)
        if !start.isSelfClosing { tokeniserChange = .rawText(kind) }
    }

    /// A start tag in the body that the parser makes up: `p` for a stray `</p>`, `br` for `</br>`.
    private mutating func processMadeUpStart(_ name: String) {
        costs.elements += 1
        processStartTag(name)
    }

    // MARK: The Stack

    /// Pushes an element.
    private mutating func push(_ element: Element) {
        stack.append(element)
    }

    /// Pops the current node; what it reached goes to the node below it.
    private mutating func pop() {
        guard let element = stack.popLast() else { return }
        if !stack.isEmpty { stack[stack.count - 1].reach = max(stack[stack.count - 1].reach, element.reach) }
    }

    /// Pops the element at `index` and everything above it.
    private mutating func popAll(from index: Int) {
        while stack.count > index { pop() }
    }

    /// `removeFromStack`: the element with `id` leaves the stack, and what is above it stays.
    private mutating func removeFromStack(_ id: Int) {
        guard let index = stack.lastIndex(where: { $0.id == id }) else { return }
        let element = stack.remove(at: index)
        if index > 0 { stack[index - 1].reach = max(stack[index - 1].reach, element.reach) }
    }

    /// `replaceOnStack`.
    private mutating func replaceOnStack(_ id: Int, with element: Element) {
        guard let index = stack.lastIndex(where: { $0.id == id }) else { return }
        var replacement = element
        replacement.reach = max(replacement.reach, stack[index].reach)
        stack[index] = replacement
    }

    /// `popStackToClose(name)`: from the last element of the name, if there is one.
    private mutating func popStackToClose(_ name: String) {
        if let index = stack.lastIndex(where: { $0.name == name }) { popAll(from: index) }
    }

    /// `popStackToBefore(name)`: pops until the current node is of the name.
    private mutating func popStackToBefore(_ name: String) {
        while let current = stack.last, current.name != name { pop() }
    }

    /// `clearStackToContext`: pops until the current node is one of `names`, or `html`.
    private mutating func clearStack(toContext names: Set<String>) {
        while let current = stack.last, !names.contains(current.name), current.name != "html" { pop() }
    }

    /// `generateImpliedEndTags(excludeTag)`: pops what closes by itself, but `name`.
    private mutating func generateImpliedEnds(except name: String) {
        while let current = stack.last, current.name != name, Self.impliedEnds.contains(current.name) { pop() }
    }

    /// `resetInsertionMode`.
    private mutating func resetInsertionMode() {
        for index in stack.indices.reversed() {
            let last = index == 0
            let name = last ? "body" : stack[index].name
            switch name {
            case "select": mode = .inSelect
            case "td" where true, "th" where !last: mode = .inCell
            case "tr": mode = .inRow
            case "tbody", "thead", "tfoot": mode = .inTableBody
            case "caption": mode = .inCaption
            case "colgroup": mode = .inColumnGroup
            case "table": mode = .inTable
            case "head", "body": mode = .inBody
            case "frameset": mode = .inFrameset
            case "html": mode = .beforeHead
            default:
                guard last else { continue }
                mode = .inBody
            }
            return
        }
    }

    // MARK: Scopes

    /// `inSpecificScope`: whether an element of the name is open before one of `limits`.
    private func isInScope(_ name: String, extraLimits: Set<String> = []) -> Bool {
        for element in stack.reversed() {
            if element.name == name { return true }
            if Self.scopeLimits.contains(element.name) || extraLimits.contains(element.name) { return false }
        }
        return false
    }

    /// `inButtonScope`. For `p`, the parser keeps where its `p` and `button`
    /// elements are on the stack, and while every element there is one it has an
    /// id for, it answers from those alone (`inButtonScopePFast`): a `p` is in
    /// scope when one is open above the last `button`, whatever else stands between.
    private func isInButtonScope(_ name: String) -> Bool {
        if name == "p", stack.allSatisfy({ Self.knownTags.contains($0.name) }) {
            guard let lastP = stack.lastIndex(where: { $0.name == "p" }) else { return false }
            guard let lastButton = stack.lastIndex(where: { $0.name == "button" }) else { return true }
            return lastP > lastButton
        }
        return isInScope(name, extraLimits: ["button"])
    }

    /// The names SwiftSoup has a tag id for (`Token.Tag.TagId`).
    private static let knownTags: Set<String> = [
        "a", "span", "p", "div", "em", "strong", "b", "i", "small", "li", "body", "html", "head", "title", "form", "br", "meta", "img",
        "script", "style", "caption", "col", "colgroup", "table", "tbody", "thead", "tfoot", "tr", "td", "th", "input", "hr", "select",
        "option", "optgroup", "textarea", "noscript", "noframes", "plaintext", "button", "base", "frame", "frameset", "iframe", "noembed",
        "embed", "dd", "dt", "dl", "ol", "ul", "pre", "listing", "address", "article", "aside", "blockquote", "center", "dir", "fieldset",
        "figcaption", "figure", "footer", "header", "hgroup", "menu", "nav", "section", "summary", "h1", "h2", "h3", "h4", "h5", "h6",
        "applet", "marquee", "object", "ruby", "rp", "rt", "rb", "sub", "sup", "code",
    ]

    /// `inTableScope`: only `html` and `table` stop it.
    private func isInTableScope(_ name: String) -> Bool {
        for element in stack.reversed() {
            if element.name == name { return true }
            if element.name == "html" || element.name == "table" { return false }
        }
        return false
    }

    /// `inSelectScope`: everything but `optgroup` and `option` stops it.
    private func isInSelectScope(_ name: String) -> Bool {
        for element in stack.reversed() {
            if element.name == name { return true }
            if element.name != "optgroup", element.name != "option" { return false }
        }
        return false
    }

    // MARK: Active Formatting Elements

    /// `lastFormattingElement`: the last entry, unless it is a marker.
    private var lastFormattingElement: Element? {
        active.last ?? nil
    }

    /// `getActiveFormattingElement`: the last entry of the name, since the last marker.
    private func activeElement(named name: String) -> Element? {
        for entry in active.reversed() {
            guard let entry else { return nil }
            if entry.name == name { return entry }
        }
        return nil
    }

    /// `isInActiveFormattingElements`.
    private func isInActive(_ id: Int) -> Bool {
        active.contains { $0?.id == id }
    }

    /// `removeFromActiveFormattingElements`: the last entry for the element.
    private mutating func removeActive(_ id: Int) {
        if let index = active.lastIndex(where: { $0?.id == id }) { active.remove(at: index) }
    }

    /// `replaceActiveFormattingElement`.
    private mutating func replaceActive(_ id: Int, with element: Element) {
        if let index = active.lastIndex(where: { $0?.id == id }) { active[index] = element }
    }

    /// `pushActiveFormattingElements`: since the last marker, a fourth of the same kind pushes the first out of the list.
    private mutating func pushActive(_ element: Element) {
        var seen = 0
        for index in active.indices.reversed() {
            guard let entry = active[index] else { break }
            if entry.name == element.name, entry.attributes.count == element.attributes.count,
               bytes[entry.attributes].elementsEqual(bytes[element.attributes]) {
                seen += 1
            }
            if seen == 3 {
                active.remove(at: index)
                break
            }
        }
        active.append(element)
    }

    /// `insertMarkerToFormattingElements`.
    private mutating func insertMarker() {
        active.append(nil)
    }

    /// `clearFormattingElementsToLastMarker`.
    private mutating func clearFormattingToMarker() {
        while let last = active.popLast(), last != nil {}
    }

    /// `reconstructFormattingElements` when there is a last formatting element.
    private mutating func reconstructIfNeeded() {
        if lastFormattingElement != nil { reconstructFormatting() }
    }

    /// `reconstructFormattingElements`: the entries since the last one still on
    /// the stack, or the last marker, are made again, in order, as elements of
    /// their own with their attributes.
    private mutating func reconstructFormatting() {
        guard let last = lastFormattingElement, !stack.contains(where: { $0.id == last.id }) else { return }
        var position = active.count - 1
        var skip = false
        while true {
            if position == 0 {
                skip = true
                break
            }
            position -= 1
            guard let entry = active[position], !stack.contains(where: { $0.id == entry.id }) else { break }
        }
        let size = active.count
        while true {
            if !skip { position += 1 }
            skip = false
            guard let entry = active[position] else { return }
            costs.elements += 1
            if entry.attributeCount > 0 { costs.elementsWithAttributes += 1 }
            costs.attributes += entry.attributeCount
            let copy = insert(StartTag(name: entry.name, attributes: entry.attributes, attributeCount: entry.attributeCount))
            active[position] = copy
            if position == size - 1 { break }
        }
    }
}
