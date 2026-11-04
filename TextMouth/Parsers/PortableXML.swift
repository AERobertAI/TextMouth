import Foundation

// MARK: - A Portable XML Tree
//
// Foundation on the Mac reads an XML file into a tree (`XMLDocument`,
// `XMLElement`, `XMLNode`) that the EPUB, feed, and OPML readers walk and
// search with XPath. iOS's Foundation has only the streaming `XMLParser`,
// not the tree. These three classes are that tree, with exactly the part of
// Foundation's interface those readers use, so that the same reader files
// compile for both apps: on iOS, `Platform/iOS/Parsers/XMLTree+iOS.swift`
// names them `XMLDocument`, `XMLElement`, and `XMLNode`, and the Mac goes on
// using Foundation's own tree, which these classes only imitate.
//
// How the tree is read, and where it differs from Foundation's, is written
// beside the readers (`PortableXMLBuilder.swift`); the XPath subset is in
// `PortableXMLPath.swift`. `PortableXMLDifferentialTests` compares this tree
// with Foundation's on every XML fixture, on the Mac.

// MARK: - Errors

/// What the portable tree refuses, beyond the errors it takes over from
/// `XMLParser`.
enum PortableXMLError: LocalizedError, Equatable {
    /// The document nests elements deeper than
    /// `PortableXMLDocument.maximumDepth`.
    case tooDeep
    /// `nodes(forXPath:)` was given an expression outside the subset the
    /// readers use (`PortableXMLPath`): it is refused, never read as
    /// matching nothing. The associated value is the expression.
    case unsupportedXPath(String)

    /// The sentence a person may read.
    var errorDescription: String? {
        switch self {
        case .tooDeep:
            return "The XML document nests elements more than \(PortableXMLDocument.maximumDepth) levels deep."
        case let .unsupportedXPath(expression):
            return "The XPath expression \(expression) is not one the portable XML tree supports."
        }
    }
}

// MARK: - Nodes

/// A node of a portable XML tree: a document, an element, an attribute, a
/// text run, a comment, or a processing instruction. The counterpart of
/// Foundation's `XMLNode`, read-only, and holding only what the readers use.
class PortableXMLNode {
    /// What a node is. The same cases Foundation's `XMLNode.Kind` has that
    /// the portable tree builds; the readers' `switch` statements have a
    /// `default` for the rest.
    enum Kind {
        case document
        case element
        case attribute
        case processingInstruction
        case comment
        case text
    }

    /// The reading options this tree understands, with Foundation's names.
    struct Options: OptionSet {
        let rawValue: Int
        /// Accepted and always in force: the portable tree never loads an
        /// external entity, whatever the options say.
        static let nodeLoadExternalEntitiesNever = Options(rawValue: 1 << 0)
        /// Read a document that is not well-formed as far as it can be,
        /// as Foundation's tidying does: when the strict reading fails, the
        /// document is read again by a lenient XML reader.
        static let documentTidyXML = Options(rawValue: 1 << 1)
    }

    /// What kind of node this is.
    let kind: Kind
    /// Set only while a tree is built (`PortableXMLTreeBuilder`).
    /// The qualified name (`dc:title`) of an element or attribute, or the
    /// target of a processing instruction; nil for the others.
    var name: String?
    /// The name without its prefix (`title`); nil when `name` is.
    var localName: String?
    /// The prefix of the name (`dc`), or an empty string when the name has
    /// none; nil for a node that has no name. As in Foundation.
    var prefix: String?
    /// The namespace the name is in; nil when it is in none. As in
    /// Foundation, an element in a scope that undeclares its default
    /// namespace (`xmlns=""`) has the empty string.
    var uri: String?
    /// How deep the node is: 0 for the document, 1 for the root element.
    var level = 0
    /// The text of a text, comment, or processing instruction node, or the
    /// value of an attribute; empty for a document or an element.
    internal var content = ""
    /// The nodes inside a document or an element, in document order.
    internal var childNodes: [PortableXMLNode] = []

    /// A node of `kind` that has no name or content yet.
    init(kind: Kind) {
        self.kind = kind
    }

    /// The nodes inside this one, or nil when there are none (Foundation
    /// answers nil too).
    var children: [PortableXMLNode]? {
        childNodes.isEmpty ? nil : childNodes
    }

    /// The node's text. For a text, comment, or processing instruction node
    /// or an attribute it is its own text. For an element or a document it
    /// is, as in Foundation, the text of everything inside it joined in
    /// document order, comments and processing instructions included.
    ///
    /// Joined with an explicit stack, not by recursion, so that a deep tree
    /// cannot exhaust the stack.
    var stringValue: String? {
        switch kind {
        case .document, .element:
            var text = ""
            var pending = Array(childNodes.reversed())
            while let node = pending.popLast() {
                if node.childNodes.isEmpty {
                    text += node.content
                } else {
                    pending.append(contentsOf: node.childNodes.reversed())
                }
            }
            return text
        case .attribute, .text, .comment, .processingInstruction:
            return content
        }
    }

    /// Replace the nodes inside this one with `children` (nil for none).
    /// The nodes it held are released without recursion, however deep their
    /// own trees are.
    func setChildren(_ children: [PortableXMLNode]?) {
        var released = childNodes
        childNodes = children ?? []
        Self.release(&released)
    }

    /// The nodes `expression` selects, in document order. Only the XPath
    /// subset of `PortableXMLPath` is understood.
    /// - Throws: `PortableXMLError.unsupportedXPath` for any other
    ///   expression, rather than answering that nothing matches.
    func nodes(forXPath expression: String) throws -> [PortableXMLNode] {
        try PortableXMLPath(expression).evaluate(from: self)
    }

    /// Releases a tree, so that Foundation-style recursive teardown cannot
    /// overflow the stack on a deep one. Foundation's own tree needs
    /// `EPUBParser.takeApart` for the same reason: an XML file nested
    /// thousands of levels deep, released by one nested call per level,
    /// ended the app.
    ///
    /// Each node that nothing else holds is stripped of its children before
    /// it is let go, with the children moved onto an explicit stack, so
    /// that releasing any one node never releases a deep tree.
    /// - Parameter nodes: The nodes to release; emptied.
    private static func release(_ nodes: inout [PortableXMLNode]) {
        var stack = nodes
        nodes = []
        while var node = stack.popLast() {
            if isKnownUniquelyReferenced(&node) {
                stack.append(contentsOf: node.childNodes)
                node.childNodes = []
            }
        }
    }

    /// Releases this node's children without recursion when it is let go.
    deinit {
        var released = childNodes
        childNodes = []
        Self.release(&released)
    }
}

// MARK: - Elements

/// An element of a portable XML tree. The counterpart of Foundation's
/// `XMLElement`, without the parts that change a tree.
class PortableXMLElement: PortableXMLNode {
    /// The attribute nodes, in the order they were read.
    internal var attributeNodes: [PortableXMLNode] = []

    /// A new element with no name yet.
    init() {
        super.init(kind: .element)
    }

    /// The element's attributes, or nil when it has none. Namespace
    /// declarations (`xmlns`, `xmlns:dc`) are not attributes, as in
    /// Foundation. An attribute's `name` is its qualified name
    /// (`opf:role`), and its `stringValue` its value.
    ///
    /// The attributes of an element read by `XMLParser` come unprefixed ones
    /// first and then by name, since `XMLParser` hands them over as an
    /// unordered dictionary; those of an element read by the lenient reader
    /// come in the document's order.
    var attributes: [PortableXMLNode]? {
        attributeNodes.isEmpty ? nil : attributeNodes
    }

    /// The attribute whose qualified name is exactly `name` (`role` finds
    /// only an unprefixed attribute, `opf:role` only that one), or nil.
    func attribute(forName name: String) -> PortableXMLNode? {
        attributeNodes.first { $0.name == name }
    }
}

// MARK: - Documents

/// A portable XML tree read from a document. The counterpart of
/// Foundation's `XMLDocument`.
final class PortableXMLDocument: PortableXMLNode {
    /// How deeply elements may nest. Foundation reads a document nested
    /// thousands of levels deep; a document deeper than this is refused
    /// with `PortableXMLError.tooDeep` instead, since no book, feed, or
    /// subscription list nests that deep and a crafted one could use the
    /// depth to exhaust memory or the stack.
    static let maximumDepth = 512

    /// Read `xmlString`, handed over as its UTF-8 bytes. Both readers honor
    /// the document's XML declaration, as Foundation's `XMLDocument` does: a
    /// declaration of another encoding makes the UTF-8 bytes read as that
    /// encoding (`café` under `ISO-8859-1` reads as `cafÃ©` in both trees), or
    /// fail where the encoding cannot be read.
    /// - Throws: The reading's error, as `init(data:options:)` does.
    convenience init(xmlString: String, options: Options = []) throws {
        try self.init(data: Data(xmlString.utf8), options: options)
    }

    /// Read the XML in `data`.
    ///
    /// The document is read strictly by `XMLParser`, with no external entity
    /// ever loaded. With `.documentTidyXML`, a document that fails the
    /// strict reading is read again by the lenient reader of
    /// `PortableXMLLenientReader`, as Foundation tidies one.
    /// - Throws: An `NSXMLParserErrorDomain` error when `data` is empty or
    ///   not well-formed (and, with `.documentTidyXML`, not readable
    ///   leniently either), or `PortableXMLError.tooDeep`.
    init(data: Data, options: Options = []) throws {
        super.init(kind: .document)
        let tidy = options.contains(.documentTidyXML)
        do {
            try PortableXMLStrictReader.read(data, into: PortableXMLTreeBuilder(document: self, isTidy: tidy))
        } catch let error as PortableXMLError where error == .tooDeep {
            // A tidy reading would meet the same depth.
            throw error
        } catch {
            guard tidy else { throw error }
            // Start again from an empty document.
            setChildren(nil)
            try PortableXMLLenientReader.read(data, into: PortableXMLTreeBuilder(document: self, isTidy: true))
        }
    }

    /// The document's root element, or nil when it has none.
    func rootElement() -> PortableXMLElement? {
        for node in childNodes {
            if let element = node as? PortableXMLElement { return element }
        }
        return nil
    }
}
