import Foundation

// MARK: - Names in OpenDocument XML

/// Reads the names of an OpenDocument part by their namespaces, not by the
/// prefixes a producer chose.
///
/// Every OpenDocument producer writes the same prefixes (`text:`, `style:`,
/// `table:`, and the rest), but the specification binds the namespaces, not
/// the prefixes, so a file that writes `t:p` for `text:p` is as valid. The
/// parser here reads names as written (it does not process namespaces, as
/// `PackageSAXParser` asks), so this scope follows each `xmlns:` declaration
/// and turns a name whose prefix is bound to a known OpenDocument namespace
/// into the name with the usual prefix. A reader then matches `text:p` and
/// `text:style-name` only.
struct ODTNameScope {
    /// The prefix each OpenDocument namespace is read as.
    private static let usualPrefixes: [String: String] = [
        "urn:oasis:names:tc:opendocument:xmlns:office:1.0": "office",
        "urn:oasis:names:tc:opendocument:xmlns:text:1.0": "text",
        "urn:oasis:names:tc:opendocument:xmlns:table:1.0": "table",
        "urn:oasis:names:tc:opendocument:xmlns:style:1.0": "style",
        "urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0": "fo",
        "urn:oasis:names:tc:opendocument:xmlns:drawing:1.0": "draw",
        "urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0": "svg",
        "urn:oasis:names:tc:opendocument:xmlns:meta:1.0": "meta",
        "http://purl.org/dc/elements/1.1/": "dc",
    ]

    /// The prefixes the file binds to a namespace under another prefix than
    /// the usual one: written prefix to usual prefix. Empty for nearly every
    /// file, which is then read without any translation.
    private var translations: [String: String] = [:]

    /// The translations in force before each open element declared its
    /// own, or nil for an element that declared none.
    private var enclosing: [[String: String]?] = []

    /// Opens an element whose attributes are `attributes`, noting any
    /// namespace declarations they hold.
    mutating func enter(_ attributes: [String: String]) {
        // The common case: an element declares no namespace.
        guard attributes.keys.contains(where: { $0.hasPrefix("xmlns:") }) else {
            enclosing.append(nil)
            return
        }
        enclosing.append(translations)
        for (name, uri) in attributes where name.hasPrefix("xmlns:") {
            let prefix = String(name.dropFirst("xmlns:".count))
            if let usual = Self.usualPrefixes[uri], usual != prefix {
                translations[prefix] = usual
            } else {
                // Bound to the usual prefix, or to a namespace not read.
                translations[prefix] = nil
            }
        }
    }

    /// Closes the element opened last, forgetting its declarations.
    mutating func leave() {
        guard let before = enclosing.popLast() else { return }
        if let before { translations = before }
    }

    /// `name` (an element's or an attribute's, as written) with its prefix
    /// translated to the usual one.
    func usual(_ name: String) -> String {
        guard !translations.isEmpty, let colon = name.firstIndex(of: ":"),
              let usual = translations[String(name[..<colon])] else { return name }
        return usual + name[colon...]
    }

    /// `attributes` with every name translated.
    func usual(_ attributes: [String: String]) -> [String: String] {
        guard !translations.isEmpty else { return attributes }
        var result: [String: String] = [:]
        for (name, value) in attributes { result[usual(name)] = value }
        return result
    }
}

// MARK: - The XML Reader of an OpenDocument Package

/// The base of the readers of the XML parts of an OpenDocument package
/// (FMT27): `meta.xml`, `styles.xml`, and `content.xml`. It drives
/// `XMLParser` through `PackageSAXParser`, which describes damaged markup,
/// and adds what every part needs:
/// - names read by namespace (`ODTNameScope`);
/// - a refusal of any document type declaration, which an OpenDocument part
///   never has, so that no entity can be declared and expanded into a huge
///   text (a "billion laughs" part);
/// - a depth limit of its own, whatever the parser's;
/// - skipping an element's whole subtree (`skipSubtree()`), as hidden text
///   and the parts that are not text are skipped;
/// - a way for a subclass to end the read with an error of its own
///   (`fail(_:)`), since a delegate method cannot throw.
///
/// A part that is damaged ends the read with
/// `TextutilConverter.Failure.unreadable(.odt)`, the sentence TextMouth has
/// always given for an OpenDocument file it cannot read.
class ODTXMLReader: PackageSAXParser {
    /// The deepest nesting of elements read. OpenDocument text nests a
    /// dozen levels in a long table of lists; `libxml2` itself stops at 256.
    private static let deepestNesting = 200

    /// The names of the elements open, as the subclass sees them.
    private(set) var depth = 0

    /// The depth of the element whose subtree is being skipped, if any.
    private var skippedDepth: Int?

    /// The names in force.
    private var names = ODTNameScope()

    /// The error a subclass ended the read with, if any.
    private var failure: Error?

    /// The parser that is running, so that `fail(_:)` can stop it.
    private var running: XMLParser?

    /// Prepares to read `data`, the part at `file` in the package.
    init(data: Data, file: String) {
        super.init(data: data, file: file) { _, _ in TextutilConverter.Failure.unreadable(.odt) }
    }

    // MARK: Reading

    /// Reads the part.
    /// - Throws: `TextutilConverter.Failure.unreadable(.odt)` for markup
    ///   that is damaged, declares a document type, or nests too deeply, and
    ///   whatever error a subclass ended the read with.
    final func read() throws {
        // XML declares entities only in a document type declaration.
        // Looking in the raw bytes costs nothing against the parse.
        if data.range(of: Data("<!DOCTYPE".utf8)) != nil || data.range(of: Data("<!ENTITY".utf8)) != nil {
            throw TextutilConverter.Failure.unreadable(.odt)
        }
        do {
            try parseDocument()
        } catch {
            // A stop the subclass asked for, then the parser's own report of
            // it, which only says that it was stopped.
            throw failure ?? error
        }
        if let failure { throw failure }
    }

    /// Ends the read with `error`, which `read()` throws.
    final func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error
        running?.abortParsing()
    }

    /// Skips the element being started and everything inside it: the
    /// subclass hears of neither its content nor its end.
    final func skipSubtree() {
        if skippedDepth == nil { skippedDepth = depth }
    }

    // MARK: For subclasses

    /// An element starts. `name` and `attributes` are read by namespace
    /// (`ODTNameScope`).
    func startElement(_ name: String, attributes: [String: String]) {}

    /// An element ends.
    func endElement(_ name: String) {}

    /// Text inside the element open now.
    func characters(_ text: String) {}

    // MARK: XMLParserDelegate

    final func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        running = parser
        depth += 1
        names.enter(attributeDict)
        guard depth <= Self.deepestNesting else {
            fail(TextutilConverter.Failure.unreadable(.odt))
            return
        }
        guard skippedDepth == nil else { return }
        startElement(names.usual(elementName), attributes: names.usual(attributeDict))
    }

    final func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        running = parser
        defer {
            names.leave()
            depth -= 1
        }
        if let skipped = skippedDepth {
            // The end of the skipped element itself resumes the reading.
            if skipped == depth { skippedDepth = nil }
            return
        }
        endElement(names.usual(elementName))
    }

    final func parser(_ parser: XMLParser, foundCharacters string: String) {
        running = parser
        guard skippedDepth == nil else { return }
        characters(string)
    }

    final func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        running = parser
        guard skippedDepth == nil, let text = String(data: CDATABlock, encoding: .utf8) else { return }
        characters(text)
    }
}
