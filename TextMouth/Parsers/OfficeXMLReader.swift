import Foundation

// MARK: - Names in Office XML

/// Reads the names of an XML part of an office document (OpenDocument, or
/// Word 2003 XML) by their namespaces, not by the prefixes a producer chose.
///
/// Every producer writes the same prefixes (`text:`, `style:`, `table:`, and
/// the rest for OpenDocument; `w:` and `wx:` for Word), but the specifications
/// bind the namespaces, not the prefixes, so a file that writes `t:p` for
/// `text:p` is as valid. The parser here reads names as written (it does not
/// process namespaces, as `PackageSAXParser` asks), so this scope follows
/// each `xmlns:` declaration and turns a name whose prefix is bound to a
/// namespace the format knows into the name with the usual prefix. A reader
/// then matches `text:p` and `text:style-name` only.
struct OfficeNameScope {
    /// The prefix each namespace of the format is read as.
    private let usualPrefixes: [String: String]

    init(usualPrefixes: [String: String]) {
        self.usualPrefixes = usualPrefixes
    }

    /// The prefixes the file binds to a namespace under another prefix than
    /// the usual one: written prefix to usual prefix. Empty for nearly every
    /// file, which is then read without any translation.
    private var translations: [String: String] = [:]

    /// The usual prefix of the default namespace (`xmlns="…"`), if the file
    /// binds one to a namespace of the format: names without a prefix are in it.
    private var defaultPrefix: String?

    /// One declaration an element made, to be undone when it closes: the
    /// prefix (nil for the default namespace) and what it was bound to before.
    private struct Change {
        let prefix: String?
        let before: String?
    }

    /// What each open element changed. An element that declares nothing, the
    /// common case, holds an empty array, which costs nothing: the time an
    /// element takes is the time of its own declarations, not of every
    /// prefix the file binds.
    private var changes: [[Change]] = []

    /// Opens an element whose attributes are `attributes`, noting any
    /// namespace declarations they hold.
    mutating func enter(_ attributes: [String: String]) {
        var made: [Change] = []
        for (name, uri) in attributes {
            if name == "xmlns" {
                made.append(Change(prefix: nil, before: defaultPrefix))
                defaultPrefix = usualPrefixes[uri]
            } else if name.hasPrefix("xmlns:") {
                let prefix = String(name.dropFirst("xmlns:".count))
                made.append(Change(prefix: prefix, before: translations[prefix]))
                if let usual = usualPrefixes[uri], usual != prefix {
                    translations[prefix] = usual
                } else {
                    // Bound to the usual prefix, or to a namespace not read.
                    translations[prefix] = nil
                }
            }
        }
        changes.append(made)
    }

    /// Closes the element opened last, undoing its declarations.
    mutating func leave() {
        guard let made = changes.popLast() else { return }
        for change in made.reversed() {
            if let prefix = change.prefix {
                translations[prefix] = change.before
            } else {
                defaultPrefix = change.before
            }
        }
    }

    /// The name of an element, as written, with its prefix translated to the
    /// usual one; a name without a prefix is in the default namespace.
    func usualElement(_ name: String) -> String {
        guard let colon = name.firstIndex(of: ":") else {
            return defaultPrefix.map { $0 + ":" + name } ?? name
        }
        return usual(name, colon: colon)
    }

    /// `name` (an attribute's, as written) with its prefix translated to the
    /// usual one. An attribute without a prefix is in no namespace.
    func usual(_ name: String) -> String {
        guard !translations.isEmpty, let colon = name.firstIndex(of: ":") else { return name }
        return usual(name, colon: colon)
    }

    private func usual(_ name: String, colon: String.Index) -> String {
        guard let usual = translations[String(name[..<colon])] else { return name }
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

// MARK: - The XML Reader of an Office Document

/// The base of the readers of the XML parts of an OpenDocument package
/// (FMT27: `meta.xml`, `styles.xml`, and `content.xml`) and of a Word 2003
/// XML document (FMT53). It drives
/// `XMLParser` through `PackageSAXParser`, which describes damaged markup,
/// and adds what every part needs:
/// - names read by namespace (`OfficeNameScope`);
/// - a refusal of any document type declaration, which neither format ever
///   has, so that no entity can be declared and expanded into a huge
///   text (a "billion laughs" part);
/// - a depth limit of its own, whatever the parser's;
/// - skipping an element's whole subtree (`skipSubtree()`), as hidden text
///   and the parts that are not text are skipped;
/// - a way for a subclass to end the read with an error of its own
///   (`fail(_:)`), since a delegate method cannot throw.
///
/// A part that is damaged ends the read with
/// `TextutilConverter.Failure.unreadable`, the sentence TextMouth has always
/// given for a document it cannot read, naming the format it was read as.
class OfficeXMLReader: PackageSAXParser {
    /// The deepest nesting of elements read. Office text nests a dozen
    /// levels in a long table of lists. The parser itself reads far deeper
    /// (5,000 levels parse on this Mac), so this limit is the only guard.
    private static let deepestNesting = 200

    /// How many elements are open.
    private(set) var depth = 0

    /// The depth of the element whose subtree is being skipped, if any.
    private var skippedDepth: Int?

    /// The names in force.
    private var names: OfficeNameScope

    /// The format the part is read as, for the sentence of a part that is
    /// damaged.
    let format: TextutilInputFormat

    /// The error a subclass ended the read with, if any.
    private var failure: Error?

    /// The parser that is running, so that `fail(_:)` can stop it.
    private var running: XMLParser?

    /// Prepares to read `data`, the part at `file` in the package, as a
    /// document of `format` whose names have the prefixes `usualPrefixes`
    /// (namespace to prefix).
    init(data: Data, file: String, format: TextutilInputFormat, usualPrefixes: [String: String]) {
        self.format = format
        names = OfficeNameScope(usualPrefixes: usualPrefixes)
        super.init(data: data, file: file) { _, _ in TextutilConverter.Failure.unreadable(format) }
    }

    // MARK: Reading

    /// Reads the part.
    /// - Throws: `TextutilConverter.Failure.unreadable` for markup
    ///   that is damaged, declares a document type, or nests too deeply, and
    ///   whatever error a subclass ended the read with.
    final func read() throws {
        // No part has a document type declaration (entities declared there
        // can expand into gigabytes), and none has a start tag that long
        // (the parser takes time that grows with the square of its attributes).
        // Both are found in the raw bytes, in any encoding (`XMLInputGuard`).
        if XMLInputGuard.declaresDocumentType(data) || XMLInputGuard.hasStartTag(in: data) {
            throw TextutilConverter.Failure.unreadable(format)
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

    /// Ends the read with `ImportCancelled` if the import running on this
    /// thread was cancelled, as a conversion by textutil is stopped. A read
    /// outside an import is never stopped. This is the one place the reader
    /// asks.
    private func stopIfCancelled() {
        do { try ImportCancellation.throwIfCancelled() } catch { fail(error) }
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
    /// (`OfficeNameScope`).
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
        // Asked at every element: the ask costs about 16 ns (a task-local and
        // a lock), a tenth of what XMLParser spends on an element with nothing
        // done to it, and so under 1% of the reading. A part of few, slow
        // elements (a long start tag costs the parser seconds) is stopped
        // between them.
        stopIfCancelled()
        names.enter(attributeDict)
        guard depth <= Self.deepestNesting else {
            fail(TextutilConverter.Failure.unreadable(format))
            return
        }
        guard skippedDepth == nil else { return }
        startElement(names.usualElement(elementName), attributes: names.usual(attributeDict))
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
        endElement(names.usualElement(elementName))
    }

    final func parser(_ parser: XMLParser, foundCharacters string: String) {
        running = parser
        // A paragraph of millions of characters arrives in a few calls.
        stopIfCancelled()
        guard skippedDepth == nil else { return }
        characters(string)
    }

    final func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        running = parser
        guard skippedDepth == nil, let text = String(data: CDATABlock, encoding: .utf8) else { return }
        characters(text)
    }
}
