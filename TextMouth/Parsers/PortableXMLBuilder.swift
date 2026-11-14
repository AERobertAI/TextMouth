import Foundation
import SwiftSoup

// MARK: - Building a Portable XML Tree
//
// A document is read into a `PortableXMLDocument` by one of two readers, both
// of which hand what they find to one `PortableXMLTreeBuilder`:
//
// - `PortableXMLStrictReader`, on Foundation's `XMLParser`, which reads a
//   well-formed document and fails on any other, as `XMLDocument` does;
// - `PortableXMLLenientReader`, on SwiftSoup's XML parser, which reads what
//   it can of a document that is not well-formed, as `XMLDocument` does with
//   `.documentTidyXML`.
//
// Where the portable tree differs from Foundation's, on purpose:
//
// - `XMLParser` hands an element's attributes over as a dictionary, so their
//   order is lost; they are put in a fixed order (see `attributes`).
// - A document that declares entities of its own (`<!ENTITY x "text">`) is
//   refused by the strict reader: `XMLParser` does not expand them, and drops
//   the text around a reference to an external one, where Foundation expands
//   the first and reads the second as nothing. The lenient reader keeps the
//   reference as it stands. An undeclared entity is an error in both.
//   That test is a byte search for `<!ENTITY`: a UTF-16 document that declares
//   entities slips past it (XMLParser then drops the entity text), and one that
//   has the string only in a comment or a CDATA section is refused needlessly.
//   Both are rare; they are follow-ups.
// - A reference to an entity that only an external DTD could declare (the
//   `&nbsp;` of an old DTD) is kept by Foundation as an empty node between
//   two text nodes; here it is nothing, and the text around it is one node.
// - The DTD itself and a document's own XML declaration are not nodes.
// - The lenient reader repairs a broken document in its own way; where it
//   differs from libxml2's, the differential tests say how.

// MARK: - The Builder

/// Builds the tree of a document from what a reader finds, in the order it
/// finds it, with no recursion. It does what Foundation's tree does on top of
/// the parse:
///
/// - joins the text, character references, and CDATA that run together into
///   one text node, and drops a text node made only of XML whitespace;
/// - when tidying (`isTidy`), also does what Foundation's tidying does to
///   text: collapses each run of whitespace to one space, trims the start of
///   every text node and the end of the last one in an element, keeps each
///   CDATA section as a node of its own, and drops characters XML forbids;
/// - resolves each element's and attribute's namespace from the `xmlns`
///   declarations in scope, which are kept out of the attributes, as in
///   Foundation;
/// - refuses a tree nested more than `PortableXMLDocument.maximumDepth` deep.
final class PortableXMLTreeBuilder {
    /// The namespace the `xml` prefix is always bound to.
    private static let xmlNamespace = "http://www.w3.org/XML/1998/namespace"

    /// The document being built.
    private let document: PortableXMLDocument
    /// Whether the tree is built as Foundation's `.documentTidyXML` builds
    /// it. When false (a strict reading), an unbound prefix, a malformed
    /// qualified name, and an empty prefix declaration are errors, as in
    /// Foundation; when true, a name that cannot be resolved is read as it
    /// stands, and the text is normalized (see the class).
    let isTidy: Bool
    /// The elements that are open, outermost first.
    private var open: [PortableXMLElement] = []
    /// The namespace declarations of each open element, by prefix (the empty
    /// string for the default namespace); nil for an element with none.
    private var scopes: [[String: String]?] = []
    /// The text read since the last node, not yet made a node.
    private var pendingText = ""

    /// A builder that adds nodes to `document`, which is empty.
    init(document: PortableXMLDocument, isTidy: Bool) {
        self.document = document
        self.isTidy = isTidy
    }

    // MARK: Events

    /// An element starts. `attributes` are in the order the element's
    /// attributes are to have; `xmlns` declarations among them become the
    /// element's namespaces.
    /// - Throws: `PortableXMLError.tooDeep`; in a strict reading also an
    ///   `NSXMLParserErrorDomain` error for a name that cannot be resolved.
    func startElement(_ qualifiedName: String, attributes: [(name: String, value: String)]) throws {
        flushText()
        guard open.count < PortableXMLDocument.maximumDepth else { throw PortableXMLError.tooDeep }

        // Namespace declarations are scope, not attributes.
        var declared: [String: String] = [:]
        var plain: [(name: String, value: String)] = []
        for attribute in attributes {
            if attribute.name == "xmlns" {
                declared[""] = attribute.value
            } else if attribute.name.hasPrefix("xmlns:") {
                let prefix = String(attribute.name.dropFirst("xmlns:".count))
                // A prefix cannot be bound to nothing; tidying reads it as the empty namespace.
                if attribute.value.isEmpty && !isTidy { throw Self.error(201, "xmlns:\(prefix): Empty XML namespace is not allowed") }
                declared[prefix] = attribute.value
            } else {
                plain.append(attribute)
            }
        }
        scopes.append(declared.isEmpty ? nil : declared)

        let element = PortableXMLElement()
        try name(element, qualifiedName, isAttribute: false)
        element.level = open.count + 1
        for attribute in plain {
            let node = PortableXMLNode(kind: .attribute)
            try name(node, attribute.name, isAttribute: true)
            node.content = isTidy ? Self.tidied(attribute.value, endsElement: true) : attribute.value
            node.level = element.level + 1
            element.attributeNodes.append(node)
        }
        append(element)
        open.append(element)
    }

    /// The innermost open element ends.
    func endElement() {
        flushText(endsElement: true)
        guard !open.isEmpty else { return }
        open.removeLast()
        scopes.removeLast()
    }

    /// Text, a character reference, or CDATA: all of them join the text node
    /// they run into.
    func characters(_ text: String) {
        pendingText += isTidy ? Self.withoutForbiddenCharacters(text) : text
    }

    /// A CDATA section. It joins the text around it, except when tidying,
    /// which keeps it as a text node of its own, its text as it stands.
    ///
    /// Foundation (libxml2's rule for blank text before markup) drops the
    /// whitespace that comes just before a CDATA section when nothing but
    /// markup is before it in the element, so `<a>\n  <![CDATA[x]]>\n</a>`
    /// holds the text "x\n", the whitespace after the section being kept.
    func cdata(_ text: String) {
        guard let parent = open.last else { return }
        if isTidy {
            flushText()
            let node = PortableXMLNode(kind: .text)
            node.content = Self.withoutForbiddenCharacters(text)
            node.level = parent.level + 1
            if !node.content.isEmpty { parent.childNodes.append(node) }
            return
        }
        let isBlank = !pendingText.unicodeScalars.contains(where: { !Self.isXMLWhitespace($0) })
        if isBlank && parent.childNodes.first?.kind != .text { pendingText = "" }
        characters(text)
    }

    /// A comment.
    func comment(_ text: String) {
        flushText()
        let node = PortableXMLNode(kind: .comment)
        node.content = text
        append(node)
    }

    /// A processing instruction (`<?target data?>`) other than the XML declaration.
    func processingInstruction(target: String, data: String?) {
        flushText()
        let node = PortableXMLNode(kind: .processingInstruction)
        node.name = target
        node.localName = target
        node.prefix = ""
        // Tidying keeps the target in the text of the instruction.
        let text = data ?? ""
        node.content = isTidy ? [target, text].filter { !$0.isEmpty }.joined(separator: " ") : text
        append(node)
    }

    /// The document ends: the last text becomes a node.
    func finish() {
        flushText()
    }

    // MARK: Helpers

    /// Adds `node` to the innermost open element, or to the document when none is open.
    private func append(_ node: PortableXMLNode) {
        let parent: PortableXMLNode = open.last ?? document
        node.level = parent.level + 1
        parent.childNodes.append(node)
    }

    /// Makes the pending text a text node of the innermost open element.
    /// Foundation keeps no text node made only of XML whitespace (space, tab,
    /// line feed, carriage return), anywhere, and no text outside the root
    /// element, so neither does this. When tidying, the text is also
    /// normalized (`tidied(_:endsElement:)`); `endsElement` says that the
    /// text is the last thing in its element.
    private func flushText(endsElement: Bool = false) {
        defer { pendingText = "" }
        guard !pendingText.isEmpty, let parent = open.last else { return }
        let text = isTidy ? Self.tidied(pendingText, endsElement: endsElement) : pendingText
        guard text.unicodeScalars.contains(where: { !Self.isXMLWhitespace($0) }) else { return }
        let node = PortableXMLNode(kind: .text)
        node.content = text
        node.level = parent.level + 1
        parent.childNodes.append(node)
    }

    /// `text` as Foundation's tidying has it: each run of XML whitespace
    /// replaced by one space, and none left at the start, nor at the end when
    /// `endsElement` (the text is the last thing in its element).
    private static func tidied(_ text: String, endsElement: Bool) -> String {
        var result = String.UnicodeScalarView()
        var spacePending = false
        for scalar in text.unicodeScalars {
            if isXMLWhitespace(scalar) {
                spacePending = true
            } else {
                if spacePending && !result.isEmpty { result.append(" ") }
                spacePending = false
                result.append(scalar)
            }
        }
        if spacePending && !endsElement && !result.isEmpty { result.append(" ") }
        return String(result)
    }

    /// `text` without the characters XML 1.0 forbids (the control characters
    /// other than tab, line feed, and carriage return, and U+FFFE and U+FFFF),
    /// which tidying drops.
    private static func withoutForbiddenCharacters(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isForbidden) else { return text }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: text.unicodeScalars.filter { !isForbidden($0) })
        return String(kept)
    }

    /// Whether XML 1.0 forbids `scalar`.
    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value < 0x20 && !isXMLWhitespace(scalar)) || scalar.value == 0xFFFE || scalar.value == 0xFFFF
    }

    /// Whether `scalar` is XML whitespace.
    private static func isXMLWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r"
    }

    /// Gives `node` the name, prefix, local name, and namespace of
    /// `qualifiedName`, read in the namespaces now in scope. An unprefixed
    /// element is in the default namespace; an unprefixed attribute is in none.
    /// - Throws: In a strict reading, a malformed name or an unbound prefix.
    private func name(_ node: PortableXMLNode, _ qualifiedName: String, isAttribute: Bool) throws {
        node.name = qualifiedName
        // Split at the first colon; a colon at either end, or a second one, is no prefix.
        guard let colon = qualifiedName.firstIndex(of: ":") else {
            node.localName = qualifiedName
            node.prefix = ""
            node.uri = isAttribute ? nil : namespace(forPrefix: "")
            return
        }
        let prefix = String(qualifiedName[..<colon])
        let local = String(qualifiedName[qualifiedName.index(after: colon)...])
        if prefix.isEmpty || local.isEmpty {
            if !isTidy { throw Self.error(202, "Failed to parse QName '\(qualifiedName)'") }
            node.localName = qualifiedName
            node.prefix = ""
            return
        }
        if local.contains(":") && !isTidy { throw Self.error(201, "Failed to parse QName '\(qualifiedName)'") }
        node.localName = local
        node.prefix = prefix
        node.uri = namespace(forPrefix: prefix)
        if node.uri == nil && !isTidy {
            throw Self.error(201, "Namespace prefix \(prefix) on \(local) is not defined")
        }
    }

    /// The namespace `prefix` is bound to in the open elements (the empty
    /// prefix for the default namespace), or nil when it is bound to none.
    private func namespace(forPrefix prefix: String) -> String? {
        if prefix == "xml" { return Self.xmlNamespace }
        for scope in scopes.reversed() {
            if let uri = scope?[prefix] { return uri }
        }
        return nil
    }

    /// An error of `XMLParser`'s domain, as Foundation raises for the same
    /// fault: `code` is the code libxml2 gives it.
    static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: XMLParser.errorDomain, code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - The Strict Reader

/// Reads a document with `XMLParser` into a tree builder. Any fault in the
/// document ends the reading with an error, as `XMLDocument(data:)` does.
final class PortableXMLStrictReader: NSObject, XMLParserDelegate {
    /// Where what the parser finds goes.
    private let builder: PortableXMLTreeBuilder
    /// The error that stopped the reading, when the builder or the reader
    /// stopped it rather than a fault in the document.
    private var failure: Error?
    /// Whether the document refers to an entity that it does not declare
    /// and `XMLParser` could not resolve (the `&nbsp;` of a feed that names
    /// an old DTD): `XMLParser` reads such a reference as nothing.
    private var sawUnresolvedEntity = false

    private init(builder: PortableXMLTreeBuilder) {
        self.builder = builder
    }

    /// Reads `data` into `builder`.
    ///
    /// No namespace is processed by the parser (the builder resolves them
    /// itself, the same way for both readers), and no external entity is
    /// ever loaded, whatever a DTD declares.
    /// - Throws: The parser's error, or the builder's.
    static func read(_ data: Data, into builder: PortableXMLTreeBuilder) throws {
        guard !data.isEmpty else { throw PortableXMLTreeBuilder.error(XMLParser.ErrorCode.emptyDocumentError.rawValue, "zero length data") }
        // `XMLParser` does not expand a document's own entities (see the top of the file).
        if data.range(of: Data("<!ENTITY".utf8)) != nil {
            throw PortableXMLTreeBuilder.error(
                XMLParser.ErrorCode.internalError.rawValue,
                "The document declares entities of its own, which the portable XML reader does not expand."
            )
        }
        let reader = PortableXMLStrictReader(builder: builder)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let completed = parser.parse()
        if let failure = reader.failure { throw failure }
        // Tidying makes the text of such an entity (`&nbsp;` is a no-break
        // space); the lenient reader does, and so reads the document instead.
        if reader.sawUnresolvedEntity && builder.isTidy {
            throw PortableXMLTreeBuilder.error(XMLParser.ErrorCode.undeclaredEntityError.rawValue, "The document refers to an entity it does not declare.")
        }
        guard completed else {
            throw parser.parserError ?? PortableXMLTreeBuilder.error(XMLParser.ErrorCode.internalError.rawValue, "The XML could not be read.")
        }
        builder.finish()
    }

    /// Stops the parse and remembers `error`, which is then thrown.
    private func stop(_ parser: XMLParser, because error: Error) {
        failure = error
        parser.abortParsing()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        guard failure == nil else { return }
        // The dictionary has no order; fix one: unprefixed names first, then by name.
        let ordered = attributeDict
            .map { (name: $0.key, value: $0.value) }
            .sortedStably { lhs, rhs in
                let (lhsPlain, rhsPlain) = (!lhs.name.contains(":"), !rhs.name.contains(":"))
                return lhsPlain != rhsPlain ? lhsPlain : lhs.name < rhs.name
            }
        do {
            try builder.startElement(elementName, attributes: ordered)
        } catch {
            stop(parser, because: error)
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        builder.endElement()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        builder.characters(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        builder.cdata(String(decoding: CDATABlock, as: UTF8.self))
    }

    func parser(_ parser: XMLParser, foundComment comment: String) {
        builder.comment(comment)
    }

    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? {
        // Never load anything; note that the document used an entity it did not declare.
        sawUnresolvedEntity = true
        return nil
    }

    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        builder.processingInstruction(target: target, data: data)
    }
}

// MARK: - The Lenient Reader

/// Reads a document that is not well-formed with SwiftSoup's XML parser,
/// which recovers from almost any fault, into a tree builder. Used for
/// `.documentTidyXML`, when `XMLParser` has failed.
enum PortableXMLLenientReader {
    /// What is left to do in the walk of SwiftSoup's tree.
    private enum Work {
        /// Hand `node` and everything inside it to the builder.
        case visit(Node)
        /// The element visited last ends.
        case close
    }

    /// Reads `data` into `builder`.
    /// - Throws: `PortableXMLError.tooDeep` when the markup nests deeper than
    ///   the tree allows (checked by `MarkupGuard` before SwiftSoup builds a
    ///   tree of its own that deep), an empty-document error for no data,
    ///   `MarkupRefusal` for too many tags, or SwiftSoup's error.
    static func read(_ data: Data, into builder: PortableXMLTreeBuilder) throws {
        guard !data.isEmpty else { throw PortableXMLTreeBuilder.error(XMLParser.ErrorCode.emptyDocumentError.rawValue, "zero length data") }
        let parsed: Document
        do {
            parsed = try MarkupGuard.parseXML(decodedText(of: data), deepestNesting: PortableXMLDocument.maximumDepth)
        } catch MarkupRefusal.nestedTooDeeply {
            throw PortableXMLError.tooDeep
        }

        // Depth first, in document order, with an explicit stack. Only the first
        // element at the top is a root; Foundation's tidying drops any other.
        var rootSeen = false
        let topLevel = parsed.getChildNodes().filter { node in
            guard node is Element else { return true }
            defer { rootSeen = true }
            return !rootSeen
        }
        var work: [Work] = topLevel.reversed().map { .visit($0) }
        while let item = work.popLast() {
            switch item {
            case .close:
                builder.endElement()
            case let .visit(node):
                if let element = node as? Element {
                    let attributes = (element.getAttributes()?.asList() ?? []).map { (name: $0.getKey(), value: $0.getValue()) }
                    try builder.startElement(element.tagName(), attributes: attributes)
                    work.append(.close)
                    work.append(contentsOf: element.getChildNodes().reversed().map { .visit($0) })
                } else if let text = node as? TextNode {
                    builder.characters(text.getWholeText())
                } else if let comment = node as? Comment {
                    // SwiftSoup reads the rest of a DTD, past the first `>`, as comments.
                    if !isDeclaration(comment.getData()) { builder.comment(comment.getData()) }
                } else if let declaration = node as? XmlDeclaration, declaration.name().lowercased() != "xml" {
                    builder.processingInstruction(target: declaration.name(), data: try? declaration.getWholeDeclaration())
                }
                // The XML declaration, the DOCTYPE, and anything else are not nodes of the tree.
            }
        }
        builder.finish()
    }

    /// Whether the text of a comment is a DTD's markup declaration that
    /// SwiftSoup took for one (`ENTITY inner "expanded"`).
    private static func isDeclaration(_ text: String) -> Bool {
        ["ENTITY", "ELEMENT", "ATTLIST", "NOTATION"].contains { text.hasPrefix($0) }
    }

    /// `data` as text: in the encoding its XML declaration names when that
    /// is not UTF-8, else as UTF-8, with U+FFFD for every byte that is not
    /// valid UTF-8, as libxml2's recovery reads a document that claims to be
    /// UTF-8 and is not. A byte order mark is dropped.
    private static func decodedText(of data: Data) -> String {
        if let declared = declaredEncoding(in: data), declared != .utf8, let text = String(data: data, encoding: declared) {
            return text
        }
        let text = String(decoding: data, as: UTF8.self)
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    /// The encoding the XML declaration at the start of `data` names, if it
    /// names one Foundation knows.
    private static func declaredEncoding(in data: Data) -> String.Encoding? {
        let start = String(decoding: data.prefix(200), as: UTF8.self)
        guard let range = start.range(of: "encoding=") else { return nil }
        let name = start[range.upperBound...].drop { $0 == "\"" || $0 == "'" }.prefix { $0 != "\"" && $0 != "'" && $0 != "?" }
        let encoding = CFStringConvertIANACharSetNameToEncoding(String(name) as CFString)
        guard encoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
    }
}
