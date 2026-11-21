import Foundation
import SwiftSoup

/// One pass over the HTML that `/usr/bin/textutil` writes for a Word, RTF,
/// OpenDocument, or WordML file, run before `HTMLToMarkdownConverter` reads it.
///
/// textutil writes every heading as a plain `<p>` in bold or a larger size
/// (even from Word's Heading styles and OpenDocument's `text:h`), writes the
/// lists of some formats as literal tab, bullet, tab paragraphs, and names a
/// picture only by its attachment's file name. This pass restores what the
/// reader needs: headings (from the sizes and weights the document itself
/// uses), lists, and silence for pictures. It is a pure function on a parsed
/// document: no file, no process, and no knowledge of any format.
///
/// Bold and italic in body text are left exactly as they are, so the
/// converter still writes them as emphasis.
enum TextutilHTMLStructure {

    // MARK: - Entry point

    /// Rewrite `document` in place: remove pictures, remove the field
    /// instructions of Word documents, turn bullet paragraphs into lists,
    /// then turn the paragraphs that look like headings into `h1` to `h6`.
    /// The order matters: a bullet line must never become a heading, a
    /// picture's file name must not count as heading text, and a field's
    /// instruction must be neither a heading nor read aloud.
    ///
    /// The whole body is counted (for its body size and weight) after the
    /// pictures are gone but before the bullet paragraphs become list
    /// items: an item carries no class, so counted afterwards its characters
    /// would fall to the 12 px default and could outweigh a smaller body.
    /// It is counted before the field instructions go too: they stand in
    /// body paragraphs at the body's own size, and a page made mostly of
    /// fields has a body size only if they count (the sample
    /// `libreoffice-tdf81705_outlineLevel.doc` is a "Contents" line above
    /// one field line).
    ///
    /// `beforeFieldRemoval` runs once, on the document, after the pictures
    /// are gone and before the field instructions are: the page breaks of
    /// textutil's plain text are put in there (ST10). textutil writes a
    /// field's instruction as bare text into both its HTML and its plain
    /// text, so the two still hold the same letters until the instructions
    /// are removed from the HTML; lined up afterwards, every page after the
    /// first field would be dropped as unaligned.
    static func restore(in document: Document, beforeFieldRemoval: (Document) throws -> Void = { _ in }) throws {
        try removePictures(from: document)
        let rules = try classRules(in: document)
        let bodyCensus = Census(
            measuring: textNodes(under: document.body() ?? document),
            with: StyleResolver(rules: rules)
        )
        try beforeFieldRemoval(document)
        try TextutilFieldCodes.removeInstructions(from: document)
        try convertBulletParagraphs(in: document)
        try convertHeadingParagraphs(in: document, rules: rules, bodyCensus: bodyCensus)
    }

    // MARK: - Constants

    /// The size a character has when no element above it gives one: the
    /// default of a browser's 12 px body text, which textutil's own
    /// stylesheets assume.
    private static let defaultSize = 12.0

    /// The longest paragraph, in characters, that can be a heading.
    private static let longestHeading = 120

    /// The deepest heading level; smaller sizes share it.
    private static let deepestLevel = 6

    /// The characters that begin a bullet paragraph when a tab follows.
    static let bulletCharacters: Set<Character> = [
        "•", "◦", "▪", "▫", "‣", "⁃", "∙", "●", "○", "■", "□", "–", "-", "*"
    ]

    /// Tags whose elements are blocks of text: a character's size and weight
    /// come from the elements between it and its block.
    static let blockTags: Set<String> = [
        "p", "li", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6",
        "div", "blockquote", "pre"
    ]

    /// Tags inside which a paragraph is part of a list or table and is never
    /// a heading or a bullet line of its own.
    private static let containerTags: Set<String> = ["li", "td", "th", "table", "ul", "ol"]

    // MARK: - Pictures

    /// Remove every `img` and `object`: textutil names a picture only by its
    /// attachment's file name, which the converter would read aloud.
    private static func removePictures(from document: Document) throws {
        try document.select("img, object").remove()
    }

    // MARK: - Bullet paragraphs

    /// Turn each run of consecutive sibling bullet paragraphs into one `ul`.
    /// textutil writes the lists of .doc, .docx, and WordML files this way,
    /// as paragraphs reading tab, bullet, tab, and then the item's words.
    ///
    /// The work is linear in the size of the document: SwiftSoup removes a
    /// child in time linear in the parent's children, so removing each of
    /// tens of thousands of bullet paragraphs one by one would take quadratic
    /// time. Each parent that holds a run has its children rebuilt once.
    private static func convertBulletParagraphs(in document: Document) throws {
        let body = document.body() ?? document

        // Group the bullet paragraphs into runs of adjacent siblings.
        var runs: [[Element]] = []
        for paragraph in try body.select("p").array()
        where !isInsideContainer(paragraph) && bulletPrefixLength(of: paragraph) != nil {
            if let last = runs.last?.last, previousContentSibling(of: paragraph) === last {
                runs[runs.count - 1].append(paragraph)
            } else {
                runs.append([paragraph])
            }
        }

        // Group the runs by the parent that holds them, in document order.
        var parents: [Element] = []
        var runsByParent: [ObjectIdentifier: [[Element]]] = [:]
        for run in runs {
            guard let parent = run.first?.parent() else { continue }
            let key = ObjectIdentifier(parent)
            if runsByParent[key] == nil { parents.append(parent) }
            runsByParent[key, default: []].append(run)
        }

        for parent in parents {
            try replaceRuns(runsByParent[ObjectIdentifier(parent)] ?? [], in: parent)
        }
    }

    /// Replace each run of bullet paragraphs, all children of `parent`, with
    /// one `ul` of their items, rebuilding `parent`'s children in one pass:
    /// each list takes the place of its run's first paragraph, and the other
    /// paragraphs of the run go.
    private static func replaceRuns(_ runs: [[Element]], in parent: Element) throws {
        var listsByFirstParagraph: [ObjectIdentifier: Element] = [:]
        var replaced: Set<ObjectIdentifier> = []
        for run in runs {
            guard let first = run.first else { continue }
            let list = Element(try Tag.valueOf("ul"), "")
            // The list holds the items; `list.addChildren` runs once per
            // run, so the cost is that of the items alone.
            try list.addChildren(try run.map { try listItem(from: $0) })
            listsByFirstParagraph[ObjectIdentifier(first)] = list
            replaced.formUnion(run.map { ObjectIdentifier($0) })
        }

        // Lift all of the parent's children out, then put back the ones that
        // stay, with the lists in place of their runs.
        var rebuilt: [Node] = []
        for child in try detachAllChildren(of: parent) {
            let key = ObjectIdentifier(child)
            if let list = listsByFirstParagraph[key] {
                rebuilt.append(list)
            } else if !replaced.contains(key) {
                rebuilt.append(child)
            }
        }
        try parent.addChildren(rebuilt)
    }

    /// Remove every child of `element` and return them, in order. Children
    /// are removed from the last to the first: SwiftSoup renumbers the
    /// siblings after a removed child, so removing the last first renumbers
    /// none, and emptying an element takes linear time, not quadratic.
    private static func detachAllChildren(of element: Element) throws -> [Node] {
        let children = element.getChildNodes()
        for child in children.reversed() {
            try child.remove()
        }
        return children
    }

    /// A list item that holds the children of the bullet paragraph
    /// `paragraph`, less its leading white space, bullet, and tab.
    private static func listItem(from paragraph: Element) throws -> Element {
        var remaining = bulletPrefixLength(of: paragraph) ?? 0
        // The prefix may be spread over several text nodes and tab spans.
        for node in textNodes(under: paragraph) where remaining > 0 {
            let characters = Array(node.getWholeText())
            let dropped = min(remaining, characters.count)
            remaining -= dropped
            if dropped == characters.count {
                try removeWithEmptiedParents(node, upTo: paragraph)
            } else {
                _ = node.text(String(characters[dropped...]))
            }
        }
        let item = Element(try Tag.valueOf("li"), "")
        try item.addChildren(try detachAllChildren(of: paragraph))
        return item
    }

    /// Remove `node`, and each ancestor below `limit` that it leaves empty
    /// (such as the span that held a tab), so no empty shell remains.
    private static func removeWithEmptiedParents(_ node: Node, upTo limit: Element) throws {
        var current: Node = node
        while let parent = current.parent() as? Element, parent !== limit,
              parent.getChildNodes().count == 1 {
            current = parent
        }
        try current.remove()
    }

    /// The number of characters of `paragraph`'s text that make up its bullet
    /// prefix (white space, a bullet character, a tab, and the white space
    /// after it), or nil when the paragraph is not a bullet line. The tab is
    /// required: a dialogue line such as "– Hello, she said." begins with a
    /// dash and a space, and stays a paragraph.
    private static func bulletPrefixLength(of paragraph: Element) -> Int? {
        let characters = Array(textNodes(under: paragraph).map { $0.getWholeText() }.joined())
        var index = 0
        while index < characters.count, characters[index].isWhitespace { index += 1 }
        guard index + 1 < characters.count,
              bulletCharacters.contains(characters[index]),
              characters[index + 1] == "\t" else { return nil }
        index += 2
        while index < characters.count, characters[index].isWhitespace { index += 1 }
        return index
    }

    /// The sibling node before `node`, skipping white-space-only text and
    /// comments, or nil when there is none.
    private static func previousContentSibling(of node: Node) -> Node? {
        var sibling = node.previousSibling()
        while let current = sibling {
            if let text = current as? TextNode, text.isBlank() {
                sibling = current.previousSibling()
            } else if current is Comment {
                sibling = current.previousSibling()
            } else {
                return current
            }
        }
        return nil
    }

    // MARK: - Heading paragraphs

    /// Turn the paragraphs that are headings by their size or weight into
    /// `h1` to `h6`, keeping their children. `bodyCensus` is the count of the
    /// whole body made before the bullet paragraphs became items; the
    /// candidates' own characters are counted here, with a resolver of their
    /// own (the earlier one remembers elements the bullet pass has removed).
    private static func convertHeadingParagraphs(
        in document: Document,
        rules: [String: ClassRule],
        bodyCensus: Census?
    ) throws {
        let body = document.body() ?? document
        let styles = StyleResolver(rules: rules)

        guard let bodySize = bodyCensus?.bodySize else { return }
        let boldAllowed = !(bodyCensus?.isMostlyBold ?? false)

        // Find the candidates before renaming any: a renamed paragraph no
        // longer matches its class rule.
        var larger: [(paragraph: Element, size: Double)] = []
        var bold: [Element] = []
        for paragraph in try body.select("p").array() where !isInsideContainer(paragraph) {
            let nodes = textNodes(under: paragraph)
            guard let own = Census(measuring: nodes, with: styles),
                  isHeadingLength(of: paragraph) else { continue }
            if let size = own.bodySize, size > bodySize {
                larger.append((paragraph, size))
            } else if boldAllowed, own.isEveryCharacterBold, own.sizes == [bodySize] {
                bold.append(paragraph)
            }
        }

        // The larger sizes, largest first, give levels 1, 2, 3, and so on;
        // bold candidates take the next level after them.
        let sizes = Set(larger.map { $0.size }).sortedStably(by: >)
        for (paragraph, size) in larger {
            let rank = sizes.firstIndex(of: size) ?? 0
            try paragraph.tagName("h\(min(rank + 1, deepestLevel))")
        }
        for paragraph in bold {
            try paragraph.tagName("h\(min(sizes.count + 1, deepestLevel))")
        }
    }

    /// Whether `paragraph`'s text is short enough to be a heading and is not
    /// a decorative initial: not empty, at most `longestHeading` characters,
    /// and not a single letter (a single digit, a chapter's number, may be).
    private static func isHeadingLength(of paragraph: Element) -> Bool {
        let label = HTMLReadingText.label(of: paragraph)
        guard !label.isEmpty, label.count <= longestHeading else { return false }
        return !(label.count == 1 && label.first?.isLetter == true)
    }

    /// Whether `element` sits inside a list or a table.
    private static func isInsideContainer(_ element: Element) -> Bool {
        var current = element.parent()
        while let ancestor = current {
            if containerTags.contains(ancestor.tagName().lowercased()) { return true }
            current = ancestor.parent()
        }
        return false
    }

    // MARK: - Counting characters by size and weight

    /// What a set of text nodes holds: how many characters at each size
    /// (rounded to the half pixel), and how many of them are bold.
    private struct Census {
        /// Characters other than white space, by size.
        private(set) var charactersBySize: [Double: Int] = [:]
        /// Bold characters other than white space, by size.
        private(set) var boldBySize: [Double: Int] = [:]

        /// Count `nodes`, or nil when they hold no character other than white space.
        init?(measuring nodes: [TextNode], with styles: StyleResolver) {
            for node in nodes {
                let count = node.getWholeText().reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
                guard count > 0 else { continue }
                let (size, isBold) = styles.sizeAndWeight(of: node)
                charactersBySize[size, default: 0] += count
                if isBold { boldBySize[size, default: 0] += count }
            }
            if charactersBySize.isEmpty { return nil }
        }

        /// The sizes present.
        var sizes: Set<Double> { Set(charactersBySize.keys) }

        /// The size holding the most characters; a tie goes to the smaller.
        var bodySize: Double? {
            charactersBySize.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
        }

        /// Whether every character counted is bold.
        var isEveryCharacterBold: Bool {
            charactersBySize.allSatisfy { boldBySize[$0.key] == $0.value }
        }

        /// Whether more than half the characters at the body size are bold:
        /// a document in bold throughout has no headings from bold.
        var isMostlyBold: Bool {
            guard let size = bodySize else { return false }
            return (boldBySize[size] ?? 0) * 2 > (charactersBySize[size] ?? 0)
        }
    }

    /// Every text node under `root`, in document order.
    static func textNodes(under root: Node) -> [TextNode] {
        var found: [TextNode] = []
        // An explicit stack, so a deeply nested document cannot exhaust the call stack.
        var pending: [Node] = [root]
        while let node = pending.popLast() {
            if let text = node as? TextNode {
                found.append(text)
            } else {
                pending.append(contentsOf: node.getChildNodes().reversed())
            }
        }
        return found
    }

    /// Round `size` to the nearest half pixel: 13.5 and 13.4 are one size.
    fileprivate static func roundedToHalfPixel(_ size: Double) -> Double {
        (size * 2).rounded() / 2
    }

    // MARK: - Class rules

    /// What a `tag.class` rule of a `<style>` element says about its text.
    fileprivate struct ClassRule {
        /// The size in px, when the rule gives one.
        var size: Double?
        /// Whether the rule makes its text bold.
        var isBold = false
    }

    /// Every one-class rule (`tag.class { ... }`) of every `<style>` element
    /// of `document`, by lower-cased `tag.class`. Anything else in the
    /// stylesheets is ignored.
    private static func classRules(in document: Document) throws -> [String: ClassRule] {
        var rules: [String: ClassRule] = [:]
        for style in try document.select("style").array() {
            for (selectors, declarations) in ruleBlocks(in: style.data()) {
                let rule = classRule(from: declarations)
                // A rule may name several selectors: "p.p1, p.p2 { ... }".
                for selector in selectors.split(separator: ",") {
                    let key = selector.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if isTagDotClass(key) { rules[key] = rule }
                }
            }
        }
        return rules
    }

    /// The `selectors { declarations }` blocks of a stylesheet's text.
    private static func ruleBlocks(in css: String) -> [(selectors: String, declarations: String)] {
        let pattern = try? NSRegularExpression(pattern: "([^{}]+)\\{([^}]*)\\}")
        let range = NSRange(css.startIndex..., in: css)
        return pattern?.matches(in: css, range: range).compactMap { match in
            guard let selectors = Range(match.range(at: 1), in: css),
                  let declarations = Range(match.range(at: 2), in: css) else { return nil }
            return (String(css[selectors]), String(css[declarations]))
        } ?? []
    }

    /// Whether `selector` is exactly one tag name, a dot, and one class name.
    private static func isTagDotClass(_ selector: String) -> Bool {
        let parts = selector.split(separator: ".", omittingEmptySubsequences: false)
        let simple: (Substring) -> Bool = { name in
            !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
        return parts.count == 2 && parts.allSatisfy(simple)
    }

    /// The size and weight in a rule's declarations. A size is `font-size`,
    /// or else the first px token of the `font` shorthand (which may read
    /// `12.0px/14px`). Bold is a `font-weight` of bold, bolder, or 600 or
    /// more, or the word bold in the shorthand.
    private static func classRule(from declarations: String) -> ClassRule {
        var rule = ClassRule()
        var shorthandSize: Double?
        for declaration in declarations.split(separator: ";") {
            let pair = declaration.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let name = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch name {
            case "font-size":
                rule.size = firstPixelSize(in: value) ?? rule.size
            case "font":
                shorthandSize = firstPixelSize(in: value)
                if value.split(whereSeparator: { $0 == " " }).contains("bold") { rule.isBold = true }
            case "font-weight":
                if value == "bold" || value == "bolder" || (Int(value) ?? 0) >= 600 { rule.isBold = true }
            default:
                break
            }
        }
        // font-size wins over the shorthand wherever each one stands.
        rule.size = rule.size ?? shorthandSize
        return rule
    }

    /// The first `<n>px` token in `value`, rounded to the half pixel.
    private static func firstPixelSize(in value: String) -> Double? {
        guard let pattern = try? NSRegularExpression(pattern: "(\\d+(?:\\.\\d+)?)px"),
              let match = pattern.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value),
              let size = Double(value[range]) else { return nil }
        return roundedToHalfPixel(size)
    }

    // MARK: - Size and weight of a character

    /// Finds the size and weight of the characters in a text node from the
    /// class rules, remembering each element's answer: many text nodes share
    /// their paragraph and spans.
    private final class StyleResolver {
        private let rules: [String: ClassRule]
        private var cache: [ObjectIdentifier: ClassRule] = [:]

        init(rules: [String: ClassRule]) {
            self.rules = rules
        }

        /// The size and weight of the characters of `node`. The size is that
        /// of the nearest element, from the node up to its block, whose class
        /// rule gives one (12 px when none does). The text is bold when an
        /// element between it and its block is `b` or `strong`, or has a bold
        /// class rule.
        func sizeAndWeight(of node: TextNode) -> (size: Double, isBold: Bool) {
            var size: Double?
            var isBold = false
            var current = node.parent() as? Element
            while let element = current {
                let rule = rule(for: element)
                size = size ?? rule.size
                isBold = isBold || rule.isBold
                if blockTags.contains(element.tagName().lowercased()) { break }
                current = element.parent()
            }
            return (size ?? TextutilHTMLStructure.defaultSize, isBold)
        }

        /// What `element` itself says: bold when it is `b` or `strong`, and
        /// the size and weight of its class rules, the last class winning.
        private func rule(for element: Element) -> ClassRule {
            let key = ObjectIdentifier(element)
            if let known = cache[key] { return known }
            let tag = element.tagName().lowercased()
            var result = ClassRule(size: nil, isBold: tag == "b" || tag == "strong")
            for name in (try? element.classNames()) ?? [] {
                guard let rule = rules["\(tag).\(name.lowercased())"] else { continue }
                result.size = rule.size ?? result.size
                result.isBold = result.isBold || rule.isBold
            }
            cache[key] = result
            return result
        }
    }
}
