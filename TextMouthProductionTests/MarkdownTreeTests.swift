import XCTest
@testable import TextMouth

/// `MarkdownTree` (November 15, 2026): a Markdown text as cmark parses it,
/// which the reader and the exporter walk. These tests pin the parse the
/// walks stand on: the options and extensions swift-markdown parsed with,
/// each kind of node, and what a node says of itself. Hermetic: no library,
/// no file.
final class MarkdownTreeTests: XCTestCase {

    // MARK: - Helpers

    /// The tree of `markdown` written out: each node's kind, with its text in
    /// quotes when it has one, and its children in parentheses.
    private func outline(_ markdown: String, smartPunctuation: Bool = true) -> String {
        MarkdownTree.read(markdown, smartPunctuation: smartPunctuation) { Self.outline(of: $0) }
    }

    /// The outline of `node` and everything under it.
    private static func outline(of node: MarkdownNode) -> String {
        var text = "\(node.kind)"
        let literal = node.literal
        if !literal.isEmpty { text += " \"\(literal)\"" }
        let children = node.children.map(outline(of:))
        return children.isEmpty ? text : "\(text)(\(children.joined(separator: ", ")))"
    }

    /// The first node of `kind` in the tree of `markdown`, in reading order, handed to `read`.
    private func first<Value>(_ kind: MarkdownNode.Kind, in markdown: String, _ read: (MarkdownNode) -> Value) -> Value? {
        /// The first node of the kind at or under `node`.
        func find(_ node: MarkdownNode) -> MarkdownNode? {
            if node.kind == kind { return node }
            for child in node.children {
                if let found = find(child) { return found }
            }
            return nil
        }
        return MarkdownTree.read(markdown) { find($0).map(read) }
    }

    // MARK: - Blocks

    /// An empty text is a document with nothing in it, and a paragraph is its
    /// text; a wrapped line is a soft break and a line ended by two spaces or
    /// a backslash a hard one.
    func testParagraphsAndBreaks() {
        XCTAssertEqual(outline(""), "document")
        XCTAssertEqual(outline("words"), "document(paragraph(text \"words\"))")
        XCTAssertEqual(
            outline("one\ntwo  \nthree\\\nfour"),
            "document(paragraph(text \"one\", softBreak, text \"two\", lineBreak, text \"three\", lineBreak, text \"four\"))"
        )
    }

    /// A heading knows its level, by either syntax, and any other node's is 0.
    func testHeadingsKnowTheirLevel() {
        XCTAssertEqual(first(.heading, in: "### Three") { $0.headingLevel }, 3)
        XCTAssertEqual(first(.heading, in: "Title\n=====") { $0.headingLevel }, 1)
        XCTAssertEqual(first(.heading, in: "Title\n-----") { $0.headingLevel }, 2)
        XCTAssertEqual(first(.paragraph, in: "words") { $0.headingLevel }, 0)
        XCTAssertEqual(outline("####### seven"), "document(paragraph(text \"####### seven\"))")
    }

    /// A list knows whether it is numbered and where it starts, and holds
    /// list items; a task is a list item that says so, its checkbox kept out
    /// of its words.
    func testListsAndTasks() {
        XCTAssertEqual(first(.list, in: "- a\n- b") { $0.isOrderedList }, false)
        XCTAssertEqual(first(.list, in: "7. a\n8. b") { $0.isOrderedList }, true)
        XCTAssertEqual(first(.list, in: "7. a\n8. b") { $0.listStart }, 7)
        XCTAssertEqual(first(.list, in: "0. a") { $0.listStart }, 0)
        XCTAssertEqual(first(.list, in: "999999999. a") { $0.listStart }, 999_999_999)
        XCTAssertEqual(outline("- a\n- b"), "document(list(listItem(paragraph(text \"a\")), listItem(paragraph(text \"b\"))))")
        XCTAssertEqual(outline("- [x] done"), "document(list(listItem(paragraph(text \"done\"))))")
        XCTAssertEqual(first(.listItem, in: "- [x] done") { $0.isTaskListItem }, true)
        XCTAssertEqual(first(.listItem, in: "- [ ] open") { $0.isTaskListItem }, true)
        XCTAssertEqual(first(.listItem, in: "- plain") { $0.isTaskListItem }, false)
        XCTAssertEqual(first(.paragraph, in: "- [x] done") { $0.isTaskListItem }, false)
    }

    /// Quotes, code, raw HTML, and thematic breaks are the blocks they are;
    /// code keeps the line feed that ends it, and raw HTML is as written.
    func testQuotesCodeAndRawHTML() {
        XCTAssertEqual(outline("> quoted"), "document(blockQuote(paragraph(text \"quoted\")))")
        XCTAssertEqual(outline("```swift\nlet x = 1\n```"), "document(codeBlock \"let x = 1\n\")")
        XCTAssertEqual(outline("    indented"), "document(codeBlock \"indented\n\")")
        XCTAssertEqual(outline("<!-- page: 7 -->"), "document(htmlBlock \"<!-- page: 7 -->\n\")")
        XCTAssertEqual(outline("a <!-- c --> b"), "document(paragraph(text \"a \", inlineHTML \"<!-- c -->\", text \" b\"))")
        XCTAssertEqual(outline("a\n\n---\n\nb"), "document(paragraph(text \"a\"), thematicBreak, paragraph(text \"b\"))")
    }

    // MARK: - Tables

    /// A table holds its header row first, then its body rows, each of cells:
    /// the table extension is attached.
    func testATableIsItsHeaderRowThenItsBodyRows() {
        XCTAssertEqual(
            outline("| a | b |\n|---|---|\n| c | d |"),
            "document(table(tableHeader(tableCell(text \"a\"), tableCell(text \"b\")), "
                + "tableRow(tableCell(text \"c\"), tableCell(text \"d\"))))"
        )
        XCTAssertEqual(outline("| a |\n|---|"), "document(table(tableHeader(tableCell(text \"a\"))))")
        // Words before a table with no blank line between are a paragraph before it.
        XCTAssertEqual(
            outline("words\n| a |\n|---|"),
            "document(paragraph(text \"words\"), table(tableHeader(tableCell(text \"a\"))))"
        )
    }

    // MARK: - Inlines

    /// Emphasis, strong text, struck-through text, code, links, images, and
    /// inline attributes are the inlines they are: the strikethrough
    /// extension is attached, and swift-cmark's attributes are read.
    func testInlines() {
        XCTAssertEqual(
            outline("*a* **b** ~~c~~ `d`"),
            "document(paragraph(emphasis(text \"a\"), text \" \", strong(text \"b\"), text \" \", "
                + "strikethrough(text \"c\"), text \" \", inlineCode \"d\"))"
        )
        XCTAssertEqual(outline("[t](u) ![alt](p.png)"), "document(paragraph(link(text \"t\"), text \" \", image(text \"alt\")))")
        XCTAssertEqual(outline("^[t](k: v)"), "document(paragraph(inlineAttributes(text \"t\")))")
    }

    /// A link's address and an image's source are read, and none is nil, as
    /// for any node that is neither.
    func testDestinations() {
        XCTAssertEqual(first(.link, in: "[t](https://example.org/a)") { $0.destination }, "https://example.org/a")
        XCTAssertEqual(first(.image, in: "![alt](pic.png)") { $0.destination }, "pic.png")
        XCTAssertEqual(first(.link, in: "[t]()") { $0.destination }, .some(nil))
        XCTAssertEqual(first(.paragraph, in: "words") { $0.destination }, .some(nil))
        XCTAssertEqual(first(.link, in: "<https://example.org/auto>") { $0.destination }, "https://example.org/auto")
    }

    /// A bare address is plain text: the autolink extension was never attached.
    func testABareAddressIsPlainText() {
        XCTAssertEqual(outline("see https://example.org now"), "document(paragraph(text \"see https://example.org now\"))")
    }

    // MARK: - Smart Punctuation and Odd Characters

    /// Quotes are curled and dashes and dots joined, as TextMouth has always
    /// read them, unless smart punctuation is turned off.
    func testSmartPunctuation() {
        /// The words of the one paragraph of `markdown`, joined.
        func words(_ markdown: String, smart: Bool) -> String {
            MarkdownTree.read(markdown, smartPunctuation: smart) { document in
                document.firstChild?.children.map(\.literal).joined() ?? ""
            }
        }
        XCTAssertEqual(words("\"a\" 'b' c--d e---f g...", smart: true), "“a” ‘b’ c–d e—f g…")
        XCTAssertEqual(words("\"a\" 'b' c--d e---f g...", smart: false), "\"a\" 'b' c--d e---f g...")
    }

    /// Entities are decoded, a NUL reads as U+FFFD, and a text's own
    /// characters pass through byte for byte.
    func testEntitiesAndOddCharacters() {
        XCTAssertEqual(first(.text, in: "&amp;&#65;&copy;") { $0.literal }, "&A©")
        XCTAssertEqual(first(.paragraph, in: "a\u{0}b") { $0.children.map(\.literal).joined() }, "a\u{FFFD}b")
        let odd = "Cafe\u{301} 👩‍👧 שלום \u{200B}\u{A0}"
        XCTAssertEqual(first(.text, in: odd) { $0.literal }, odd)
        XCTAssertEqual(first(.text, in: odd) { Array($0.literalBytes) }, Array(odd.utf8))
    }

    /// A node with no text has no bytes, and one with no children has none to walk.
    func testNodesWithoutTextOrChildren() {
        XCTAssertEqual(first(.paragraph, in: "words") { $0.literalBytes.count }, 0)
        XCTAssertEqual(first(.softBreak, in: "a\nb") { $0.literal }, "")
        XCTAssertEqual(first(.text, in: "words") { $0.firstChild == nil }, true)
        XCTAssertEqual(first(.text, in: "words") { $0.next == nil }, true)
        XCTAssertEqual(first(.text, in: "words") { Array($0.children).count }, 0)
    }

    /// Children come in reading order, and the same on every walk of them.
    func testChildrenAreInReadingOrder() {
        let kinds = MarkdownTree.read("# h\n\np\n\n- i\n\n> q") { document in
            (document.children.map(\.kind), document.children.map(\.kind))
        }
        XCTAssertEqual(kinds.0, [.heading, .paragraph, .list, .blockQuote])
        XCTAssertEqual(kinds.0, kinds.1)
    }
}
