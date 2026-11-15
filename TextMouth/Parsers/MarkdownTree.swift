import Foundation
import cmark_gfm
import cmark_gfm_extensions

// MARK: - A Markdown Text as cmark Parses It

/// A Markdown text parsed by cmark (swift-cmark's cmark-gfm), read from
/// cmark's own tree.
///
/// Both walks of content.md read through this type: the reader's
/// (`MarkdownDocParser`) and the exporter's (`ExportDocumentWalker`). Until
/// November 15, 2026 they walked the tree swift-markdown builds on top of
/// cmark's, which cost 12% to 30% of a text import and 0.46 MB of the app.
/// The parse here is the one swift-markdown made, option for option, so the
/// tree is the same tree; `MarkdownWalkCorpusTests` holds the records that
/// prove every text reads as it did.
enum MarkdownTree {
    /// The options swift-markdown 0.9.0 parsed with (`MarkupParser.parseString`
    /// with no `ParseOptions`), kept exactly:
    /// - table spans, so a cell of `^` or an empty cell after `||` joins the
    ///   cell above or before it;
    /// - source positions, which change nothing a walk reads;
    /// - smart punctuation (`smartPunctuation`), which `read` adds.
    private static let options = CMARK_OPT_TABLE_SPANS | CMARK_OPT_SOURCEPOS

    /// Smart punctuation: straight quotes are curled, and `--`, `---`, and
    /// `...` become dashes and an ellipsis.
    private static let smartPunctuation = CMARK_OPT_SMART

    /// The GitHub extensions swift-markdown attached, in its order. Autolinks
    /// and the tag filter were never attached, so a bare address is plain
    /// text, as it always was.
    private static let extensions = ["table", "strikethrough", "tasklist"]

    /// Parses `markdown` and hands the tree's root, a document, to `body`.
    /// The tree lives only until `body` returns: no `MarkdownNode` may be
    /// kept past it.
    ///
    /// cmark builds a tree and frees it in loops, so only a walk's own
    /// recursion deepens the stack with the tree's depth.
    /// - Parameter smartPunctuation: Whether quotes, dashes, and dots are
    ///   read as smart punctuation. Every walk of the app reads with it, as
    ///   TextMouth always has; only a check of how another program would read
    ///   a Markdown file turns it off.
    static func read<Result>(
        _ markdown: String,
        smartPunctuation: Bool = true,
        _ body: (MarkdownNode) throws -> Result
    ) rethrows -> Result {
        // Registering twice is harmless: cmark does it once, under its own lock.
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(smartPunctuation ? options | Self.smartPunctuation : options) else {
            preconditionFailure("cmark could not make a parser: out of memory")
        }
        for name in extensions {
            cmark_parser_attach_syntax_extension(parser, cmark_find_syntax_extension(name))
        }
        // The text's UTF-8 bytes and their count, as swift-markdown fed them:
        // a NUL in the text is fed with the rest (cmark reads it as U+FFFD).
        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        let root = cmark_parser_finish(parser)
        // The tree stands on its own once the parser has finished it.
        cmark_parser_free(parser)
        guard let root else {
            preconditionFailure("cmark gave no document: out of memory")
        }
        defer { cmark_node_free(root) }
        return try body(MarkdownNode(root))
    }
}

// MARK: - A Node of the Tree

/// One node of a tree `MarkdownTree.read` parsed: a block or an inline of the
/// Markdown, with what the walks read from it. It is a view of cmark's node,
/// valid only inside the `read` that gave it.
struct MarkdownNode {
    /// What a node is. The names are swift-markdown's where it had one, so
    /// the walks read as they did.
    enum Kind {
        case document, blockQuote, list, listItem, codeBlock, htmlBlock, paragraph, heading, thematicBreak
        /// A table, its header row (always its first child), a body row, and a cell of either.
        case table, tableHeader, tableRow, tableCell
        case text, softBreak, lineBreak, inlineCode, inlineHTML
        case emphasis, strong, strikethrough, link, image
        /// swift-cmark's inline attributes, `^[text](attributes)`: a container of its text.
        case inlineAttributes
        /// A node cmark makes only when asked through its API, never from a
        /// text (a custom block or inline), or a kind added to cmark later.
        case other
    }

    /// cmark's node.
    private let pointer: UnsafeMutablePointer<cmark_node>

    /// A view of `pointer`, a node of a living tree.
    fileprivate init(_ pointer: UnsafeMutablePointer<cmark_node>) {
        self.pointer = pointer
    }

    /// What the node is. cmark's own kinds are told by number. Those of its
    /// extensions (the table's parts and strikethrough) get their numbers when
    /// the extensions are registered, so they are told by name, as
    /// swift-markdown told every kind. A task-list item is a list item.
    var kind: Kind {
        switch cmark_node_get_type(pointer) {
        case CMARK_NODE_TEXT: return .text
        case CMARK_NODE_PARAGRAPH: return .paragraph
        case CMARK_NODE_SOFTBREAK: return .softBreak
        case CMARK_NODE_LINEBREAK: return .lineBreak
        case CMARK_NODE_EMPH: return .emphasis
        case CMARK_NODE_STRONG: return .strong
        case CMARK_NODE_HEADING: return .heading
        case CMARK_NODE_HTML_INLINE: return .inlineHTML
        case CMARK_NODE_HTML_BLOCK: return .htmlBlock
        case CMARK_NODE_CODE: return .inlineCode
        case CMARK_NODE_CODE_BLOCK: return .codeBlock
        case CMARK_NODE_LINK: return .link
        case CMARK_NODE_IMAGE: return .image
        case CMARK_NODE_LIST: return .list
        case CMARK_NODE_ITEM: return .listItem
        case CMARK_NODE_BLOCK_QUOTE: return .blockQuote
        case CMARK_NODE_THEMATIC_BREAK: return .thematicBreak
        case CMARK_NODE_DOCUMENT: return .document
        case CMARK_NODE_ATTRIBUTE: return .inlineAttributes
        case CMARK_NODE_CUSTOM_BLOCK, CMARK_NODE_CUSTOM_INLINE, CMARK_NODE_FOOTNOTE_DEFINITION,
             CMARK_NODE_FOOTNOTE_REFERENCE, CMARK_NODE_NONE:
            return .other
        default:
            return Self.extensionKinds[String(cString: cmark_node_get_type_string(pointer))] ?? .other
        }
    }

    /// The kinds cmark's extensions add, by the names cmark gives them.
    private static let extensionKinds: [String: Kind] = [
        "table": .table, "table_header": .tableHeader, "table_row": .tableRow, "table_cell": .tableCell,
        "strikethrough": .strikethrough,
    ]

    /// The node's first child, or nil for a node without children.
    var firstChild: MarkdownNode? {
        cmark_node_first_child(pointer).map(MarkdownNode.init)
    }

    /// The node after this one under the same parent, or nil for the last.
    var next: MarkdownNode? {
        cmark_node_next(pointer).map(MarkdownNode.init)
    }

    /// The node's children, in order.
    var children: Children {
        Children(upcoming: firstChild)
    }

    /// A node's children, one after another: each is asked of the one before,
    /// so nothing is built to list them.
    struct Children: Sequence, IteratorProtocol {
        /// The child `next()` gives next.
        fileprivate var upcoming: MarkdownNode?

        mutating func next() -> MarkdownNode? {
            defer { upcoming = upcoming?.next }
            return upcoming
        }
    }

    /// The UTF-8 bytes of the node's text, without the NUL that ends them: a
    /// text's characters, an inline code's or a code block's code, or raw
    /// HTML as the Markdown has it. No bytes for any other node. The bytes
    /// are cmark's, valid as long as the tree is.
    var literalBytes: UnsafeRawBufferPointer {
        guard let text = cmark_node_get_literal(pointer) else { return UnsafeRawBufferPointer(start: nil, count: 0) }
        return UnsafeRawBufferPointer(start: text, count: strlen(text))
    }

    /// The node's text as a string (`literalBytes`).
    var literal: String {
        String(decoding: literalBytes, as: UTF8.self)
    }

    /// A heading's level, 1 to 6; 0 for any other node.
    var headingLevel: Int {
        Int(cmark_node_get_heading_level(pointer))
    }

    /// Whether a list item is a task: its text began with `[ ]` or `[x]`,
    /// which cmark keeps as the item's checkbox and out of its words. Every
    /// walk reads a task as the list item it is.
    var isTaskListItem: Bool {
        kind == .listItem && strcmp(cmark_node_get_type_string(pointer), "tasklist") == 0
    }

    /// Whether a list numbers its items.
    var isOrderedList: Bool {
        cmark_node_get_list_type(pointer) == CMARK_ORDERED_LIST
    }

    /// The number an ordered list starts at; 0 for any other node.
    var listStart: Int {
        Int(cmark_node_get_list_start(pointer))
    }

    /// A link's address or an image's source, or nil when it has none.
    var destination: String? {
        guard let address = cmark_node_get_url(pointer), address.pointee != 0 else { return nil }
        return String(cString: address)
    }
}
