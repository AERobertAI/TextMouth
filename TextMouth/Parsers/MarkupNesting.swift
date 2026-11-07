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

// MARK: - The Open Elements of an HTML Parse

/// The elements SwiftSoup's HTML parser holds open as it reads, kept with no
/// tree: its stack of open elements, its active formatting elements, and which
/// of its rules applies to each tag.
///
/// It is a map of SwiftSoup 2.13.9's `HtmlTreeBuilderState` (MIT). A plain count
/// of tags would be wrong in both directions. `<p>` and `<li>` left open by a
/// real book do not nest, since the parser closes them; while `</span>` closes
/// nothing past a `<div>` (`<span><div></span>` opens two and closes none), and
/// `<div><b a=1></div>` opens more each time, since `b` comes back inside the
/// next `div` (the parser's reconstruction of formatting). So each rule is
/// followed as the parser has it, and where its modes make that uncertain the
/// model errs on the side of more elements open. Three things are set off by the
/// parser's modes, and each is met as `HTMLOpenElements.tagsAreCertain` says.
///
/// What it counts differs from the parser's stack by the `html` and `body`
/// elements, which are never pushed here, and by the table parts it leaves out
/// (`colgroup`, which holds only `col` and closes at anything else).
/// `MarkupGuardFidelityTests` holds it against SwiftSoup's real trees.
struct HTMLOpenElements {

    // MARK: Elements

    /// An element on the stack.
    private struct Open {
        var name: String
        /// Which active formatting entry this element is, if any.
        var activeID: Int?
    }

    /// An entry of the active formatting elements: an element to make again
    /// after it has been closed by something else, or a marker that stops that.
    private struct Active {
        var id: Int
        var name: String
        /// Its attributes' bytes: entries with the same name and the same
        /// bytes are the same to the three-of-a-kind rule.
        var attributes: Range<Int>
        var isOnStack: Bool
        var isMarker: Bool
    }

    /// What one start tag asks of the parser, by its name.
    private enum Role {
        /// A stack entry with no other effect, after remaking formatting.
        case plain
        /// Closes an open `p` first.
        case closesP
        /// `li`, `dd`, or `dt`: closes an open one first, and a `p`.
        case listItem
        case heading
        /// A formatting element: `a` has its own rule.
        case formatting, anchor
        /// An element with a marker of its own in the formatting list.
        case marker
        /// No element on the stack, after remaking formatting.
        case voidReconstructing
        /// No element on the stack, and nothing else.
        case void
        case form, select, table, tablePart, ruby, option
        /// Merges into what is open: `html` and `body`.
        case root
        /// `head` and `frame`: ignored where a book's text can be.
        case ignored
        case noscript, frameset, plaintext
        /// The tokeniser leaves `Data` for the element's text.
        case rawText(MarkupScanner.RawText)
    }

    /// The role of each start tag not `plain`, as `HtmlTreeBuilderState.InBody` has it.
    private static let roles: [String: Role] = {
        var roles: [String: Role] = [:]
        for name in ["address", "article", "aside", "blockquote", "center", "details", "dir", "div", "dl", "fieldset",
                     "figcaption", "figure", "footer", "header", "hgroup", "menu", "nav", "ol", "p", "section", "summary",
                     "ul", "pre", "listing"] {
            roles[name] = .closesP
        }
        for name in ["li", "dd", "dt"] { roles[name] = .listItem }
        for name in ["h1", "h2", "h3", "h4", "h5", "h6"] { roles[name] = .heading }
        for name in ["b", "big", "code", "em", "font", "i", "s", "small", "strike", "strong", "tt", "u"] {
            roles[name] = .formatting
        }
        roles["a"] = .anchor
        for name in ["applet", "marquee", "object"] { roles[name] = .marker }
        for name in ["area", "br", "hr", "img", "keygen", "wbr", "input"] { roles[name] = .voidReconstructing }
        for name in ["embed", "param", "source", "track", "base", "basefont", "bgsound", "command", "link", "meta", "col", "colgroup"] {
            roles[name] = .void
        }
        roles["form"] = .form
        roles["select"] = .select
        roles["table"] = .table
        for name in ["caption", "tbody", "thead", "tfoot", "tr", "td", "th"] { roles[name] = .tablePart }
        for name in ["rp", "rt"] { roles[name] = .ruby }
        for name in ["option", "optgroup"] { roles[name] = .option }
        for name in ["html", "body"] { roles[name] = .root }
        for name in ["head", "frame"] { roles[name] = .ignored }
        roles["noscript"] = .noscript
        roles["frameset"] = .frameset
        roles["plaintext"] = .plaintext
        roles["title"] = .rawText(.replaceable)
        for name in ["style", "noframes"] { roles[name] = .rawText(.plain) }
        roles["script"] = .rawText(.script)
        return roles
    }()

    /// `HtmlTreeBuilder.TagSets.special`: the elements an end tag of another
    /// name stops at, and that a formatting element's end tag moves.
    private static let special: Set<String> = [
        "address", "applet", "area", "article", "aside", "base", "basefont", "bgsound", "blockquote", "body", "br", "button",
        "caption", "center", "col", "colgroup", "command", "dd", "details", "dir", "div", "dl", "dt", "embed", "fieldset",
        "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header",
        "hgroup", "hr", "html", "iframe", "img", "input", "isindex", "li", "link", "listing", "marquee", "menu", "meta", "nav",
        "noembed", "noframes", "noscript", "object", "ol", "p", "param", "plaintext", "pre", "script", "section", "select",
        "style", "summary", "table", "tbody", "td", "textarea", "tfoot", "th", "thead", "title", "tr", "ul", "wbr", "xmp",
    ]
    /// What ends a search of the stack for an element in scope (`TagSets.inScope`).
    private static let scopeLimits: Set<String> = ["applet", "caption", "table", "td", "th", "marquee", "object"]
    /// End tags of these close what they name when it is in scope (`InBodyEndClosers`).
    private static let scopedClosers: Set<String> = [
        "address", "article", "aside", "blockquote", "button", "center", "details", "dir", "div", "dl", "fieldset",
        "figcaption", "figure", "footer", "header", "hgroup", "listing", "menu", "nav", "ol", "pre", "section", "summary", "ul",
    ]
    /// End tags of these go through the adoption agency (`InBodyEndAdoptionFormatters`).
    private static let adoptionNames: Set<String> = [
        "a", "b", "big", "code", "em", "font", "i", "nobr", "s", "small", "strike", "strong", "tt", "u",
    ]
    private static let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    private static let tableSections: Set<String> = ["tbody", "thead", "tfoot"]
    /// What makes the parser's mode that of a cell or a caption, and what a table part closes first.
    private static let cellsAndCaption: Set<String> = ["td", "th", "caption"]
    /// What says whether a `table` start tag nests or closes the table it stands in.
    private static let tableContext: Set<String> = ["table", "td", "th", "caption"]
    /// A special element these three pass through, looking for the list item to close.
    private static let listItemBreakers: Set<String> = ["address", "div", "p"]
    /// Tags that may come before the body without beginning it (`InHead`).
    private static let headContent: Set<String> = [
        "html", "head", "base", "basefont", "bgsound", "command", "link", "meta", "title", "noframes", "style", "noscript", "script",
    ]

    // MARK: State

    /// The markup.
    let bytes: [UInt8]
    /// The stack of open elements, innermost last, without `html` and `body`.
    private var stack: [Open] = []
    /// The active formatting elements and markers, last on the right, as the parser keeps them.
    private var active: [Active] = []
    /// The next ID for an active entry.
    private var nextActiveID = 0
    /// How many elements have been made, beyond each start tag's own: made
    /// again, or made by a stray end tag.
    private(set) var madeElements = 0
    /// A `form` element is current: another start tag of one is then ignored.
    private var formIsCurrent = false
    /// The parser is in its mode for `select`: nearly every tag is ignored.
    private var inSelect = false
    /// No text or tag so far has begun the body for certain.
    private var bodyMayNotHaveBegun = true
    /// The head has not been closed for certain.
    private var headMayBeOpen = true
    /// A `noscript` is open that began while the head may have been open.
    /// There SwiftSoup reads most tags as text.
    private var noscriptMayBeInHead = false

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// How many elements are open, by this count.
    var depth: Int { stack.count }

    /// Whether the rest of the markup can be read tag by tag. The three modes of the
    /// parser that stop reading text as it is read everywhere else (a `frameset` page,
    /// and text elements inside a `noscript` of the head) can be told from the body
    /// only by whitespace in character references. When one of them may have begun,
    /// the guard stops trusting tags, and counts every one that could possibly lie ahead.
    private(set) var tagsAreCertain = true

    /// What the tokeniser must do for the start tag just handled, if anything.
    enum TokeniserChange {
        case none
        case rawText(MarkupScanner.RawText)
        /// The rest of the markup is text (`<plaintext>`).
        case rest
    }

    // MARK: Text

    /// Text has been read in the tokeniser's `Data` state: formatting comes back for it.
    mutating func text(_ range: Range<Int>) {
        if bodyMayNotHaveBegun, !noscriptMayBeInHead, isCertainlyWords(range) {
            bodyMayNotHaveBegun = false
            headMayBeOpen = false
        }
        guard !inSelect else { return }
        reconstructFormatting()
    }

    /// Whether the parser certainly reads `range` as more than whitespace,
    /// so that the body begins: a character reference could be a space.
    private func isCertainlyWords(_ range: Range<Int>) -> Bool {
        var hasWords = false
        for byte in bytes[range] {
            if byte == Ascii.ampersand { return false }
            if !Ascii.isTagSpace(byte), byte != Ascii.verticalTab { hasWords = true }
        }
        return hasWords
    }

    // MARK: Start Tags

    /// A start tag has been read; what the tokeniser does next.
    mutating func start(_ tag: MarkupScanner.Tag, name: String) -> TokeniserChange {
        if inSelect { return startInSelect(tag, name: name) }
        trackBodyStart(name: name)
        let role = Self.roles[name] ?? .plain
        // What SwiftSoup's `tb.insert` does for a tag that closes itself: it
        // pushes the element, and at once acts on a made-up end tag.
        var isInserted = true
        switch role {
        case .plain:
            reconstructFormatting()
            push(name)
        case .closesP:
            closeP()
            push(name)
        case .listItem:
            closeListItem(name: name)
            closeP()
            push(name)
        case .heading:
            let wasHeading = stack.last.map { Self.headings.contains($0.name) } ?? false
            closeP()
            if wasHeading, !stack.isEmpty { pop() }
            push(name)
        case .formatting:
            reconstructFormatting()
            push(name, attributes: tag.attributes)
        case .anchor:
            startAnchor(tag)
        case .marker:
            reconstructFormatting()
            push(name)
            addMarker()
        case .voidReconstructing:
            reconstructFormatting()
            isInserted = false
        case .void, .ignored, .root:
            isInserted = false
        case .form:
            // `insertForm` stays open whether the tag closes itself or not.
            isInserted = false
            if !formIsCurrent {
                closeP()
                push(name)
                formIsCurrent = true
            }
        case .select:
            guard !noscriptMayBeInHead else {
                tagsAreCertain = false
                return .none
            }
            reconstructFormatting()
            guard !tag.isSelfClosing else { return .none }
            push(name)
            inSelect = true
            isInserted = false
        case .table:
            startTable()
        case .tablePart:
            isInserted = startTablePart(name)
        case .ruby:
            if isInScope("ruby") {
                if stack.last?.name != "ruby", let ruby = stack.lastIndex(where: { $0.name == "ruby" }) {
                    popAll(above: ruby)
                }
                push(name)
            } else {
                isInserted = false
            }
        case .option:
            if stack.last?.name == "option" { pop() }
            reconstructFormatting()
            push(name)
        case .noscript:
            reconstructFormatting()
            if bodyMayNotHaveBegun, headMayBeOpen { noscriptMayBeInHead = true }
            push(name)
        case .frameset:
            // A page of frames, or a plain element, by whether the body has begun.
            if bodyMayNotHaveBegun {
                tagsAreCertain = false
                return .none
            }
            reconstructFormatting()
            push(name)
        case .plaintext:
            guard !noscriptMayBeInHead else {
                tagsAreCertain = false
                return .none
            }
            reconstructFormatting()
            push(name)
            return .rest
        case let .rawText(kind):
            // `script` and `title` are text themselves inside a `noscript` of the head.
            if noscriptMayBeInHead, name != "style", name != "noframes" {
                tagsAreCertain = false
                return .none
            }
            // The element itself closes with its text, and its made-up end tag if it closes itself.
            return tag.isSelfClosing ? .none : .rawText(kind)
        }
        if tag.isSelfClosing, isInserted { end(name: name) }
        return .none
    }

    /// A tag that begins the body for certain, unless a `noscript` of the head may be open.
    private mutating func trackBodyStart(name: String) {
        guard bodyMayNotHaveBegun, !noscriptMayBeInHead, !Self.headContent.contains(name), name != "frameset" else { return }
        bodyMayNotHaveBegun = false
        headMayBeOpen = false
    }

    /// `a`: an open one is closed first, and taken off the stack even if it could not be.
    private mutating func startAnchor(_ tag: MarkupScanner.Tag) {
        if lastActive(named: "a") != nil {
            end(name: "a")
            if let index = stack.lastIndex(where: { $0.name == "a" }) {
                if let id = stack[index].activeID { removeActive(id: id) }
                stack.remove(at: index)
            }
        }
        reconstructFormatting()
        push("a", attributes: tag.attributes)
    }

    /// `table`: directly in a table it closes that table first; in a cell or
    /// caption, or outside any table, it nests.
    private mutating func startTable() {
        let context = stack.last { Self.tableContext.contains($0.name) }
        if context?.name == "table", let table = stack.lastIndex(where: { $0.name == "table" }) {
            popAll(from: table)
        }
        closeP()
        push("table")
    }

    /// `caption`, `tbody`, `thead`, `tfoot`, `tr`, `td`, or `th`, which the
    /// parser ignores outside a table and otherwise makes room for, supplying
    /// what is missing between them (`InTable`, `InTableBody`, `InRow`, `InCell`).
    /// - Returns: whether an element was pushed.
    private mutating func startTablePart(_ name: String) -> Bool {
        guard let table = stack.lastIndex(where: { $0.name == "table" }) else { return false }
        closeCellOrCaption(above: table)
        switch name {
        case "caption":
            popAll(above: table)
            push(name)
            addMarker()
        case "tbody", "thead", "tfoot":
            popAll(above: table)
            push(name)
        case "tr":
            popToRowContext(above: table)
            push(name)
        default:
            // A cell needs a row, and a row a section.
            if let row = stack[(table + 1)...].lastIndex(where: { $0.name == "tr" }) {
                popAll(above: row)
            } else {
                popToRowContext(above: table)
                push("tr")
                madeElements += 1
            }
            push(name)
            addMarker()
        }
        return true
    }

    /// Makes the stack end at the row's parent, a section (supplied if the table has none).
    private mutating func popToRowContext(above table: Int) {
        if let section = stack[(table + 1)...].lastIndex(where: { Self.tableSections.contains($0.name) }) {
            popAll(above: section)
        } else {
            popAll(above: table)
            push("tbody")
            madeElements += 1
        }
    }

    /// An open cell, or caption, of the table at `table` closes, as the table's parts do.
    private mutating func closeCellOrCaption(above table: Int) {
        guard let part = stack[(table + 1)...].lastIndex(where: { Self.cellsAndCaption.contains($0.name) }) else { return }
        popAll(from: part)
        clearFormattingToMarker()
    }

    /// Closes a `p` in button scope, as most block elements do first.
    private mutating func closeP() {
        if let index = indexInScope("p", extraLimits: ["button"]) { popAll(from: index) }
    }

    /// `li`, `dd`, `dt`: closes the nearest of the same kind, unless a special
    /// element other than `address`, `div`, and `p` stands between.
    private mutating func closeListItem(name: String) {
        let kinds: Set<String> = name == "li" ? ["li"] : ["dd", "dt"]
        for index in stack.indices.reversed() {
            let open = stack[index].name
            if kinds.contains(open) {
                popAll(from: index)
                return
            }
            if Self.special.contains(open), !Self.listItemBreakers.contains(open) { return }
        }
    }

    // MARK: End Tags

    /// An end tag has been read.
    mutating func end(_ tag: MarkupScanner.Tag, name: String) {
        if inSelect {
            endInSelect(name: name)
            return
        }
        // In a `noscript` of the head, no end tag but its own does anything.
        if !noscriptMayBeInHead {
            if name == "head" { headMayBeOpen = false }
            if name == "body" || name == "html" {
                bodyMayNotHaveBegun = false
                headMayBeOpen = false
            }
        }
        end(name: name)
    }

    /// The rules for an end tag, also followed for the one `tb.insert` makes up.
    private mutating func end(name: String) {
        if name == "noscript" { noscriptMayBeInHead = false }
        if Self.adoptionNames.contains(name) {
            endFormatting(name: name)
        } else if Self.scopedClosers.contains(name) || name == "dd" || name == "dt" {
            if let index = indexInScope(name) { popAll(from: index) }
        } else if Self.headings.contains(name) {
            for index in stack.indices.reversed() {
                if Self.headings.contains(stack[index].name) {
                    popAll(from: index)
                    return
                }
                if Self.scopeLimits.contains(stack[index].name) { return }
            }
        } else {
            switch name {
            case "li":
                if let index = indexInScope(name, extraLimits: ["ol", "ul"]) { popAll(from: index) }
            case "p":
                if let index = indexInScope(name, extraLimits: ["button"]) {
                    popAll(from: index)
                } else {
                    // No p to close: an empty one is made.
                    madeElements += 1
                }
            case "body", "html", "head":
                break
            case "form":
                endForm()
            case "applet", "marquee", "object":
                // An element named "name" in scope stops this, by a slip in the parser.
                if !isInScope("name"), let index = indexInScope(name) {
                    popAll(from: index)
                    clearFormattingToMarker()
                }
            case "br":
                reconstructFormatting()
                madeElements += 1
            case "table":
                endTable()
            case "caption", "td", "th":
                endCellOrCaption(name: name)
            case "tr":
                endRow()
            case "tbody", "thead", "tfoot":
                endSection(name: name)
            case "col", "colgroup":
                break
            default:
                endOther(name: name)
            }
        }
    }

    /// `anyOtherEndTag`: closes the nearest of the name, unless a special element stands between.
    private mutating func endOther(name: String) {
        for index in stack.indices.reversed() {
            if stack[index].name == name {
                if Self.adoptionNames.contains(name), let id = stack[index].activeID {
                    removeActive(id: id)
                    stack[index].activeID = nil
                }
                popAll(from: index)
                return
            }
            if Self.special.contains(stack[index].name) { return }
        }
    }

    /// `</form>`: the form stops being current whatever else happens, and only
    /// its own element is taken off the stack, leaving what is inside it.
    private mutating func endForm() {
        let wasCurrent = formIsCurrent
        formIsCurrent = false
        if wasCurrent, let index = indexInScope("form") { stack.remove(at: index) }
    }

    /// `</table>`: closes the nearest table, with a cell or caption in it.
    private mutating func endTable() {
        guard let table = stack.lastIndex(where: { $0.name == "table" }) else { return }
        closeCellOrCaption(above: table)
        popAll(from: table)
    }

    /// `</td>`, `</th>`, or `</caption>`, within the nearest table.
    private mutating func endCellOrCaption(name: String) {
        for index in stack.indices.reversed() {
            if stack[index].name == name {
                popAll(from: index)
                clearFormattingToMarker()
                return
            }
            if stack[index].name == "table" { return }
        }
    }

    /// `</tr>`, within the nearest table, with a cell in it.
    private mutating func endRow() {
        guard let row = indexInTable("tr") else { return }
        closeCellOrCaption(above: row)
        popAll(from: row)
    }

    /// `</tbody>`, `</thead>`, or `</tfoot>`, closing that section of the nearest
    /// table; an open row makes the parser ignore it, though an open cell still closes.
    private mutating func endSection(name: String) {
        guard let section = indexInTable(name) else { return }
        closeCellOrCaption(above: section)
        guard !stack[(section + 1)...].contains(where: { $0.name == "tr" }) else { return }
        popAll(from: section)
    }

    /// The adoption agency's effect on the stack: a formatting element with no
    /// block in it closes, with what is above it; one with a block in it comes
    /// off the stack alone, and a copy goes inside the block.
    private mutating func endFormatting(name: String) {
        for _ in 0..<8 {
            guard let entry = lastActive(named: name) else {
                endOther(name: name)
                return
            }
            guard entry.isOnStack, let format = stack.lastIndex(where: { $0.activeID == entry.id }) else {
                removeActive(id: entry.id)
                endOther(name: name)
                return
            }
            guard isInScope(name) else { return }
            guard let furthest = stack[(format + 1)...].firstIndex(where: { Self.special.contains($0.name) }) else {
                if let last = stack.lastIndex(where: { $0.name == name }) { popAll(from: last) }
                removeActive(id: entry.id)
                return
            }
            // Between the two, the parser takes one element that is not
            // active off the stack, and copies up to three that are.
            var above = furthest
            var block = furthest
            for _ in 0..<3 {
                above -= 1
                guard above > format else { break }
                if stack[above].activeID == nil {
                    stack.remove(at: above)
                    block -= 1
                    break
                }
                madeElements += 1
            }
            // The copy of the formatting element, which is not active.
            madeElements += 1
            stack.insert(Open(name: name, activeID: nil), at: block + 1)
            stack.remove(at: format)
            removeActive(id: entry.id)
        }
    }

    // MARK: Select

    /// `InSelect`: a start tag does nothing but in the few cases it has.
    private mutating func startInSelect(_ tag: MarkupScanner.Tag, name: String) -> TokeniserChange {
        switch name {
        case "input", "keygen", "textarea":
            endInSelect(name: "select")
            return start(tag, name: name)
        case "script":
            return tag.isSelfClosing ? .none : .rawText(.script)
        case "option":
            if stack.last?.name == "option" { pop() }
            pushInSelect(tag, name: name)
        case "optgroup":
            if stack.last?.name == "option" {
                pop()
            } else if stack.last?.name == "optgroup" {
                pop()
            }
            pushInSelect(tag, name: name)
        case "select":
            endInSelect(name: "select")
        default:
            break
        }
        return .none
    }

    /// Pushes `option` or `optgroup`, closing it at once if its tag closes itself.
    private mutating func pushInSelect(_ tag: MarkupScanner.Tag, name: String) {
        push(name)
        if tag.isSelfClosing { endInSelect(name: name) }
    }

    /// `InSelect`: an end tag does nothing but for what is in a `select`.
    private mutating func endInSelect(name: String) {
        switch name {
        case "optgroup":
            if stack.last?.name == "option", stack.dropLast().last?.name == "optgroup" { pop() }
            if stack.last?.name == "optgroup" { pop() }
        case "option":
            if stack.last?.name == "option" { pop() }
        case "select":
            if let index = stack.lastIndex(where: { $0.name == "select" }) { popAll(from: index) }
            inSelect = false
        default:
            break
        }
    }

    // MARK: The Stack

    /// Pushes an element, with `attributes` when it is a formatting element.
    private mutating func push(_ name: String, attributes: Range<Int>? = nil) {
        guard let attributes else {
            stack.append(Open(name: name, activeID: nil))
            return
        }
        // `pushActiveFormattingElements`: since the last marker, a fourth of
        // the same kind pushes the first out of the list, not off the stack.
        var seen = 0
        for index in active.indices.reversed() {
            if active[index].isMarker { break }
            if isSameFormatting(active[index], name: name, attributes: attributes) { seen += 1 }
            if seen == 3 {
                forgetActive(at: index)
                break
            }
        }
        let id = nextActiveID
        nextActiveID += 1
        active.append(Active(id: id, name: name, attributes: attributes, isOnStack: true, isMarker: false))
        stack.append(Open(name: name, activeID: id))
    }

    /// Whether an entry is the same to the three-of-a-kind rule as `name` with `attributes`.
    private func isSameFormatting(_ entry: Active, name: String, attributes: Range<Int>) -> Bool {
        entry.name == name && entry.attributes.count == attributes.count
            && bytes[entry.attributes].elementsEqual(bytes[attributes])
    }

    /// Pops the innermost element.
    private mutating func pop() {
        guard let open = stack.popLast(), let id = open.activeID else { return }
        markOffStack(id: id)
    }

    /// Pops the element at `index` and everything above it.
    private mutating func popAll(from index: Int) {
        while stack.count > index { pop() }
    }

    /// Pops everything above the element at `index`.
    private mutating func popAll(above index: Int) {
        popAll(from: index + 1)
    }

    /// The nearest element named `name`, unless a limit of its scope comes first.
    private func indexInScope(_ name: String, extraLimits: Set<String> = []) -> Int? {
        for index in stack.indices.reversed() {
            let open = stack[index].name
            if open == name { return index }
            if Self.scopeLimits.contains(open) || extraLimits.contains(open) { return nil }
        }
        return nil
    }

    /// Whether an element named `name` is in scope.
    private func isInScope(_ name: String) -> Bool {
        indexInScope(name) != nil
    }

    /// The nearest element named `name` within the nearest table.
    private func indexInTable(_ name: String) -> Int? {
        for index in stack.indices.reversed() {
            if stack[index].name == name { return index }
            if stack[index].name == "table" { return nil }
        }
        return nil
    }

    // MARK: Active Formatting Elements

    /// `getActiveFormattingElement`: the last entry named `name`, since the last marker.
    private func lastActive(named name: String) -> Active? {
        for entry in active.reversed() {
            if entry.isMarker { return nil }
            if entry.name == name { return entry }
        }
        return nil
    }

    /// The entry with `id` has gone from the stack but stays in the list, to be remade.
    private mutating func markOffStack(id: Int) {
        if let index = active.lastIndex(where: { $0.id == id }) { active[index].isOnStack = false }
    }

    /// Takes the entry with `id` out of the list.
    private mutating func removeActive(id: Int) {
        if let index = active.lastIndex(where: { $0.id == id }) { active.remove(at: index) }
    }

    /// Takes the entry at `index` out of the list, leaving its element, if it is open, unlinked.
    private mutating func forgetActive(at index: Int) {
        let id = active[index].id
        if active[index].isOnStack, let open = stack.lastIndex(where: { $0.activeID == id }) {
            stack[open].activeID = nil
        }
        active.remove(at: index)
    }

    /// Adds a marker to the list.
    private mutating func addMarker() {
        let id = nextActiveID
        nextActiveID += 1
        active.append(Active(id: id, name: "", attributes: 0..<0, isOnStack: false, isMarker: true))
    }

    /// `clearFormattingElementsToLastMarker`.
    private mutating func clearFormattingToMarker() {
        while let last = active.popLast(), !last.isMarker {
            if last.isOnStack, let open = stack.lastIndex(where: { $0.activeID == last.id }) {
                stack[open].activeID = nil
            }
        }
    }

    /// `reconstructFormattingElements`: the entries since the last one still
    /// on the stack, or the last marker, are made again, in order.
    private mutating func reconstructFormatting() {
        guard let last = active.last, !last.isMarker, !last.isOnStack else { return }
        var index = active.count - 1
        while index > 0, !active[index - 1].isMarker, !active[index - 1].isOnStack { index -= 1 }
        for position in index..<active.count {
            active[position].isOnStack = true
            stack.append(Open(name: active[position].name, activeID: active[position].id))
            madeElements += 1
        }
    }
}
