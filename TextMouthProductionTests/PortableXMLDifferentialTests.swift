import XCTest
import ZIPFoundation
@testable import TextMouth

/// The portable XML tree (`PortableXMLDocument`, PortableXML.swift), which
/// iOS uses in place of Foundation's `XMLDocument`, against Foundation's own
/// tree, which only the Mac has.
///
/// The EPUB, feed, and OPML readers walk a tree and search it with XPath. On
/// the Mac they go on using Foundation's; on iOS the same files compile
/// against the portable tree. These tests read the same documents with both
/// trees, with the options the readers pass, and compare every node's name,
/// local name, prefix, namespace, level, and text, every attribute, and the
/// answer to every XPath expression the readers use. The documents are every
/// EPUB package, navigation, and container document in TestData, every feed
/// and subscription-list fixture, and a corpus of small documents
/// (PortableXMLCorpus.swift) that covers each shape the readers meet and
/// each way a strict reading fails.
///
/// The trees agree everywhere except where `knownDifferences` says, each with
/// its reason; a listed difference that goes away fails the test, so the list
/// cannot grow stale.
final class PortableXMLDifferentialTests: XCTestCase {

    // MARK: - What the Readers Ask of a Tree

    /// The XPath expressions the readers pass to a document (all start with
    /// `//`), and a few more of the same forms.
    static let documentPaths = [
        "//*[local-name()='title']", "//*[local-name()='publisher']", "//*[local-name()='date']",
        "//*[local-name()='language']", "//*[local-name()='identifier']", "//*[local-name()='package']",
        "//*[local-name()='creator']", "//*[local-name()='contributor']",
        "//*[local-name()='meta'][@property='dcterms:creator']",
        "//*[local-name()='meta'][@refines][@property='role']",
        "//*[local-name()='metadata']", "//*[local-name()='rootfile']", "//*[local-name()='item']",
        "//*[local-name()='itemref']", "//*[local-name()='spine']",
        "//*[local-name()='guide']/*[local-name()='reference']", "//*[local-name()='navMap']",
        "//*[local-name()='pageList']/*[local-name()='pageTarget']",
        // The same forms, on other names and nestings.
        "//*[local-name()='navPoint']", "//*[local-name()='text']", "//*[local-name()='nonexistent']",
        "//*[local-name()='navPoint']/*[local-name()='navPoint']",
        "//*[local-name()='navPoint']/*[local-name()='navLabel']/*[local-name()='text']",
        "//*", "//*[@id]", "//*[@href][@media-type=\"application/xhtml+xml\"]", "//*[@plain='1']",
    ]

    /// The XPath expressions the readers pass to an element, and a few more.
    static let elementPaths = [
        "*[local-name()='navLabel']/*[local-name()='text']", "*[local-name()='content']",
        "*", "*[local-name()='navPoint']", "*[local-name()='x']/*[local-name()='y']", "*[@id]",
    ]

    /// Every XPath expression this test compares.
    static var comparedPaths: Set<String> { Set(documentPaths + elementPaths) }

    // MARK: - Where the Trees Differ, and Why

    /// A known difference: why the trees differ, and a fragment of the
    /// difference the comparison reports, which it must contain, so that a
    /// different difference in the same document is not hidden behind the entry.
    struct KnownDifference {
        /// Why the two trees differ.
        let reason: String
        /// Text the reported difference must contain.
        let evidence: String
    }

    /// The documents the two trees read differently, as "strict: name" or
    /// "tidy: name". "Strict" is the reading the EPUB reader makes
    /// (`.nodeLoadExternalEntitiesNever`); "tidy" the feed and OPML readers'
    /// second reading of a document their own parser refused
    /// (`.documentTidyXML`).
    ///
    /// The tidy differences are all in documents that are broken in ways
    /// libxml2 and Tidy repair in their own way, and in the tidied text of
    /// whitespace character references and `xml:space="preserve"`, which the
    /// portable tree does not imitate.
    static let knownDifferences: [String: KnownDifference] = [
        "strict: fault-external-entity.xml": entityDifference,
        "strict: an internal entity": entityDifference,
        "strict: an external entity": entityDifference,
        "strict: fault-netscape-doctype.xml": unresolvedEntityDifference,
        "strict: an undefined entity beside a DTD naming an external subset": unresolvedEntityDifference,
        "tidy: references and whitespace": KnownDifference(
            reason: "tidying keeps whitespace written as a character reference (&#32;) and the portable tree collapses it",
            evidence: "Foundation: element L1 name=a local=a prefix= uri=nil text=\"& &   \\n\""
        ),
        "tidy: xml:space preserve": KnownDifference(
            reason: "tidying keeps the whitespace inside an element marked xml:space=\"preserve\"; the portable tree does not",
            evidence: "Foundation: element L1 name=a local=a prefix= uri=nil text=\"    \""
        ),
        "tidy: a qualified name starting with a colon": KnownDifference(
            reason: "tidying reads <:b/> as text; SwiftSoup reads an element",
            evidence: "text=\"<:b/>\""
        ),
        "tidy: a qualified name ending with a colon": KnownDifference(
            reason: "tidying splits b: into the prefix b and no local name",
            evidence: "name=b: local= prefix=b"
        ),
        "tidy: a prefix bound to nothing": KnownDifference(
            reason: "tidying gives the element the empty namespace; SwiftSoup drops the empty declaration",
            evidence: "name=p:b local=b prefix=p uri= text"
        ),
        "tidy: a duplicate attribute": KnownDifference(
            reason: "tidying keeps both attributes; SwiftSoup keeps the last",
            evidence: "portable:     @x|x||nil=\"2\""
        ),
        "tidy: an attribute without a value": KnownDifference(
            reason: "tidying drops the attribute; SwiftSoup keeps it with an empty value",
            evidence: "portable:     @b|b||nil=\"\""
        ),
        "tidy: an unquoted attribute value": KnownDifference(
            reason: "SwiftSoup reads the / of <a b=c/> into the value",
            evidence: "portable:     @b|b||nil=\"c/\""
        ),
        "tidy: unclosed void elements that the item's end tag closes": KnownDifference(
            reason: "Foundation's tidying leaves each unclosed <br> open past its item, nesting the items inside one another; SwiftSoup closes them with the item's end tag",
            evidence: "from channel selects 1 and 60"
        ),
        // Project Gutenberg's A Modest Proposal (a sample of the KF8 reader's, FMT48): its contents write the title
        // across two lines with a character reference to a carriage return (`&#13;`, then a line feed), which the
        // tidy reading of Foundation keeps in the text and the portable tree collapses: the class of "tidy:
        // references and whitespace" above. The report names only the first node that differs (the root
        // element's text), so these two entries pass any report that starts with it and cannot tell another tidy
        // difference in these two files apart; the strict reading, which the EPUB reader uses on both platforms,
        // agrees on both.
        "tidy: pg1080-modest-proposal.epub/OEBPS/toc.xhtml": carriageReturnDifference(
            "Foundation: element L1 name=html local=html prefix= uri=http://www.w3.org/1999/xhtml text=\"A Modest Proposal\\r For"
        ),
        "tidy: pg1080-modest-proposal.epub/OEBPS/toc.ncx": carriageReturnDifference(
            "Foundation: element L1 name=ncx local=ncx prefix= uri=http://www.daisy.org/z3986/2005/ncx/ text=\"A Modest Proposal\\r For"
        ),
    ]

    /// Why a text that holds a character reference to a carriage return is read differently when tidied, and the
    /// start of the report that shows it.
    private static func carriageReturnDifference(_ evidence: String) -> KnownDifference {
        KnownDifference(
            reason: "tidying keeps whitespace written as a character reference (&#13;); the portable tree collapses it",
            evidence: evidence
        )
    }

    /// Why a document that declares an entity is read differently.
    private static let entityDifference = KnownDifference(
        reason: "XMLParser does not expand entities a document declares, so the strict reading refuses the document",
        evidence: "Foundation reads the document and the portable tree refuses it"
    )
    /// Why a reference to an entity only an external DTD declares is read differently.
    private static let unresolvedEntityDifference = KnownDifference(
        reason: "Foundation keeps an empty entity-reference node between two text nodes; the portable tree has one text node",
        evidence: "text=\"Onetwo\""
    )

    // MARK: - The Comparisons

    /// A node of either tree in a form the two share, one line per node.
    private func line(
        kind: String, level: Int, name: String?, localName: String?, prefix: String?, uri: String?, text: String?
    ) -> String {
        "\(kind) L\(level) name=\(name ?? "nil") local=\(localName ?? "nil") prefix=\(prefix ?? "nil") "
            + "uri=\(uri ?? "nil") text=\(String(reflecting: text ?? "nil"))"
    }

    /// One attribute of either tree as a line.
    private func attributeLine(name: String?, localName: String?, prefix: String?, uri: String?, value: String?) -> String {
        "  @\(name ?? "nil")|\(localName ?? "nil")|\(prefix ?? "nil")|\(uri ?? "nil")=\(String(reflecting: value ?? "nil"))"
    }

    /// Every node of Foundation's tree `root`, depth first, with each
    /// element's attributes (sorted by name, since the portable tree's order
    /// is its own). The document's own text is left out, since it is the
    /// text of the nodes below it, and so is the DTD node, which the portable
    /// tree does not have.
    private func lines(of root: XMLNode) -> [String] {
        var result: [String] = []
        func visit(_ node: XMLNode) {
            let kind: String
            switch node.kind {
            case .document: kind = "document"
            case .element: kind = "element"
            case .text: kind = "text"
            case .comment: kind = "comment"
            case .processingInstruction: kind = "pi"
            case _ where node.kind.rawValue == 8: return // the DTD
            default: kind = "other\(node.kind.rawValue)"
            }
            result.append(line(
                kind: kind, level: node.level, name: node.name, localName: node.localName, prefix: node.prefix,
                uri: node.uri, text: node.kind == .document ? "-" : node.stringValue
            ))
            if let element = node as? XMLElement {
                for attribute in (element.attributes ?? []).sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
                    result.append(attributeLine(
                        name: attribute.name, localName: attribute.localName, prefix: attribute.prefix,
                        uri: attribute.uri, value: attribute.stringValue
                    ))
                }
            }
            node.children?.forEach(visit)
        }
        visit(root)
        return result
    }

    /// The same lines for a portable tree.
    private func lines(of root: PortableXMLNode) -> [String] {
        var result: [String] = []
        func visit(_ node: PortableXMLNode) {
            let kind: String
            switch node.kind {
            case .document: kind = "document"
            case .element: kind = "element"
            case .text: kind = "text"
            case .comment: kind = "comment"
            case .processingInstruction: kind = "pi"
            case .attribute: kind = "attribute"
            }
            result.append(line(
                kind: kind, level: node.level, name: node.name, localName: node.localName, prefix: node.prefix,
                uri: node.uri, text: node.kind == .document ? "-" : node.stringValue
            ))
            if let element = node as? PortableXMLElement {
                for attribute in (element.attributes ?? []).sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
                    result.append(attributeLine(
                        name: attribute.name, localName: attribute.localName, prefix: attribute.prefix,
                        uri: attribute.uri, value: attribute.stringValue
                    ))
                }
            }
            node.children?.forEach(visit)
        }
        visit(root)
        return result
    }

    /// What a path selected in Foundation's tree: its elements (Foundation
    /// also lets `*` select a processing instruction, which no reader uses),
    /// each as name, local name, text, and attributes.
    private func answer(_ nodes: [XMLNode]) -> [String] {
        nodes.compactMap { $0 as? XMLElement }.map { element in
            let attributes = (element.attributes ?? []).sorted { ($0.name ?? "") < ($1.name ?? "") }
            return "\(element.name ?? "nil")|\(element.localName ?? "nil")|\(String(reflecting: element.stringValue ?? "nil"))|"
                + attributes.map { "\($0.name ?? "")=\($0.stringValue ?? "")" }.joined(separator: ",")
        }
    }

    /// The same for a portable tree.
    private func answer(_ nodes: [PortableXMLNode]) -> [String] {
        nodes.compactMap { $0 as? PortableXMLElement }.map { element in
            let attributes = (element.attributes ?? []).sorted { ($0.name ?? "") < ($1.name ?? "") }
            return "\(element.name ?? "nil")|\(element.localName ?? "nil")|\(String(reflecting: element.stringValue ?? "nil"))|"
                + attributes.map { "\($0.name ?? "")=\($0.stringValue ?? "")" }.joined(separator: ",")
        }
    }

    /// Every element of Foundation's tree, in document order.
    private func elements(in root: XMLNode) -> [XMLElement] {
        var found: [XMLElement] = []
        var pending: [XMLNode] = [root]
        while let node = pending.popLast() {
            if let element = node as? XMLElement { found.append(element) }
            pending.append(contentsOf: (node.children ?? []).reversed())
        }
        return found
    }

    /// Every element of a portable tree, in document order.
    private func elements(in root: PortableXMLNode) -> [PortableXMLElement] {
        var found: [PortableXMLElement] = []
        var pending: [PortableXMLNode] = [root]
        while let node = pending.popLast() {
            if let element = node as? PortableXMLElement { found.append(element) }
            pending.append(contentsOf: (node.children ?? []).reversed())
        }
        return found
    }

    /// How the two trees' readings of `data` differ, one sentence each; none
    /// when they agree, which includes both refusing the document.
    private func differences(in data: Data, tidy: Bool) -> [String] {
        let foundationOptions: XMLNode.Options = tidy
            ? [.documentTidyXML, .nodeLoadExternalEntitiesNever] : [.nodeLoadExternalEntitiesNever]
        let portableOptions: PortableXMLNode.Options = tidy
            ? [.documentTidyXML, .nodeLoadExternalEntitiesNever] : [.nodeLoadExternalEntitiesNever]
        let foundation = try? XMLDocument(data: data, options: foundationOptions)
        let portable = try? PortableXMLDocument(data: data, options: portableOptions)
        switch (foundation, portable) {
        case (nil, nil):
            return []
        case (nil, _?):
            return ["Foundation refuses the document and the portable tree reads it"]
        case (_?, nil):
            return ["Foundation reads the document and the portable tree refuses it"]
        case let (foundation?, portable?):
            var found: [String] = []
            let foundationLines = lines(of: foundation), portableLines = lines(of: portable)
            if foundationLines != portableLines {
                let shared = min(foundationLines.count, portableLines.count)
                let first = (0..<shared).first { foundationLines[$0] != portableLines[$0] } ?? shared
                found.append("""
                    the trees differ at node \(first) of \(foundationLines.count) and \(portableLines.count):
                    Foundation: \(first < foundationLines.count ? foundationLines[first] : "(none)")
                    portable:   \(first < portableLines.count ? portableLines[first] : "(none)")
                    """)
            }
            for path in Self.documentPaths {
                let expected = (try? foundation.nodes(forXPath: path)).map(answer)
                let actual = (try? portable.nodes(forXPath: path)).map(answer)
                if expected != actual { found.append("the path \(path) selects \(expected?.count ?? -1) and \(actual?.count ?? -1)") }
            }
            let foundationElements = elements(in: foundation), portableElements = elements(in: portable)
            if foundationElements.count == portableElements.count {
                for (expectedElement, actualElement) in zip(foundationElements, portableElements) {
                    for path in Self.elementPaths {
                        let expected = (try? expectedElement.nodes(forXPath: path)).map(answer)
                        let actual = (try? actualElement.nodes(forXPath: path)).map(answer)
                        if expected != actual {
                            found.append("the path \(path) from \(expectedElement.name ?? "?") selects \(expected?.count ?? -1) and \(actual?.count ?? -1)")
                            break
                        }
                    }
                }
            }
            return found
        }
    }

    /// Reads `data` both ways, strictly and tidily, and checks that the trees
    /// agree, or differ as `knownDifferences` says. `name` names the document.
    private func assertTreesAgree(_ name: String, _ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        for tidy in [false, true] {
            let key = "\(tidy ? "tidy" : "strict"): \(name)"
            let found = differences(in: data, tidy: tidy)
            if let known = Self.knownDifferences[key] {
                let report = found.joined(separator: "\n")
                XCTAssertFalse(found.isEmpty, "\(key) is listed as differing (\(known.reason)) but the trees now agree; remove it from knownDifferences", file: file, line: line)
                XCTAssertTrue(
                    found.isEmpty || report.contains(known.evidence),
                    "\(key) differs, but not as listed (\(known.reason)); expected the report to contain \(known.evidence), got:\n\(report)",
                    file: file, line: line
                )
            } else {
                XCTAssertTrue(found.isEmpty, "\(key) differs:\n" + found.joined(separator: "\n"), file: file, line: line)
            }
        }
    }

    // MARK: - The Documents

    /// The TestData folder.
    private func testDataFolder() throws -> URL {
        try requireFile("alice.epub").deletingLastPathComponent()
    }

    /// The XML documents of the EPUB at `url`, copied first into a folder of
    /// this test's own (the fixtures are untrusted input and are never read
    /// where they lie): its container, package, and NCX documents, and each
    /// navigation or SMIL document, as name and bytes.
    private func xmlDocuments(ofEPUB url: URL) throws -> [(name: String, data: Data)] {
        let copy = try makeSandboxDirectory("PortableXML").appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        let archive = try Archive(url: copy, accessMode: .read)
        var documents: [(name: String, data: Data)] = []
        for entry in IndexedArchive(archive).entries where entry.type == .file {
            let lower = entry.path.lowercased()
            let isPackage = lower.hasSuffix(".opf") || lower.hasSuffix(".ncx") || lower.hasSuffix("container.xml")
            let couldBeNavigation = lower.hasSuffix(".xhtml") || lower.hasSuffix(".html") || lower.hasSuffix(".smil")
            guard isPackage || couldBeNavigation else { continue }
            let (data, _) = try ArchiveEntryReader.read(entry, in: archive)
            let isNavigation = couldBeNavigation && (
                lower.hasSuffix(".smil") || ["toc", "page-list", "landmarks"].contains { data.range(of: Data("epub:type=\"\($0)\"".utf8)) != nil }
            )
            if isPackage || isNavigation { documents.append((url.lastPathComponent + "/" + entry.path, data)) }
        }
        return documents
    }

    // MARK: - Tests: Foundation's Tree and the Portable One Agree

    /// Every package, navigation, and container document of every EPUB in
    /// TestData reads the same in both trees, strictly and tidily.
    func testEveryEPUBXMLDocumentReadsTheSame() throws {
        let enumerator = FileManager.default.enumerator(at: try testDataFolder(), includingPropertiesForKeys: nil)
        var epubs: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "epub" { epubs.append(url) }
        }
        var checked = 0
        for epub in epubs.sorted(by: { $0.path < $1.path }) {
            for document in try xmlDocuments(ofEPUB: epub) {
                assertTreesAgree(document.name, document.data)
                checked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(epubs.count, 5, "the EPUB fixtures in TestData")
        XCTAssertGreaterThanOrEqual(checked, 16, "the XML documents of those EPUBs")
    }

    /// Every feed, subscription list, and package fixture of TestData reads
    /// the same in both trees, strictly and tidily: the strict reading is the
    /// EPUB reader's, the tidy one the feed and OPML readers' second reading.
    func testEveryFeedAndSubscriptionListFixtureReadsTheSame() throws {
        let enumerator = FileManager.default.enumerator(at: try testDataFolder(), includingPropertiesForKeys: nil)
        var fixtures: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            let path = url.path
            let isFeedFixture = path.contains("/feeds/") && ["xml", "opml"].contains(url.pathExtension)
            let isOtherXML = ["opml", "opf"].contains(url.pathExtension)
            if isFeedFixture || isOtherXML { fixtures.append(url) }
        }
        let folder = try makeSandboxDirectory("PortableXML")
        for fixture in fixtures.sorted(by: { $0.path < $1.path }) {
            // Read a copy, never the fixture where it lies.
            let copy = folder.appendingPathComponent(fixture.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: fixture, to: copy)
            assertTreesAgree(fixture.lastPathComponent, try Data(contentsOf: copy))
        }
        XCTAssertGreaterThanOrEqual(fixtures.count, 25, "the feed, OPML, and package fixtures in TestData")
    }

    /// Every document of the corpus reads the same in both trees, strictly
    /// and tidily, except as `knownDifferences` says.
    func testEveryCorpusDocumentReadsTheSame() {
        for sample in PortableXMLCorpus.samples {
            assertTreesAgree(sample.name, sample.data)
        }
    }

    /// Every XPath expression in the four reader files is one the comparisons
    /// above make, so a reader that starts using another cannot go unchecked.
    func testEveryXPathTheReadersPassIsCompared() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TextMouth", isDirectory: true)
        let files = [
            "Parsers/EPUBParser.swift", "Parsers/EPUBParser+Navigation.swift",
            "Services/Feeds/FeedParser.swift", "Services/Feeds/FeedOPML.swift",
        ]
        let literal = try NSRegularExpression(pattern: #""((?://)?\*\[[^"]*)""#)
        var found = Set<String>()
        for file in files {
            let text = try String(contentsOf: sources.appendingPathComponent(file), encoding: .utf8)
            for match in literal.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { found.insert(String(text[range])) }
            }
        }
        XCTAssertGreaterThanOrEqual(found.count, 15, "the XPath expressions found in the four reader files")
        XCTAssertTrue(found.isSubset(of: Self.comparedPaths), "not compared: \(found.subtracting(Self.comparedPaths).sorted())")
        // And the portable tree understands every one.
        for path in found {
            XCTAssertNoThrow(try PortableXMLPath(path), path)
        }
    }

    // MARK: - Tests: The XPath Subset

    /// A package-like document for the XPath tests.
    private func sampleDocument() throws -> PortableXMLDocument {
        try PortableXMLDocument(xmlString: """
            <package xmlns:dc="urn:dc">
              <metadata>
                <dc:title id="t">Title</dc:title>
                <meta property="role" refines="#a">aut</meta>
                <meta property="other">x</meta>
                <meta refines="#b" property="role">ill</meta>
              </metadata>
              <wrap><metadata><dc:title>Inner</dc:title></metadata></wrap>
            </package>
            """)
    }

    /// Paths of every supported form select what they say, in document order.
    func testSupportedPathsSelectInDocumentOrder() throws {
        let document = try sampleDocument()
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='title']").map { $0.stringValue }, ["Title", "Inner"])
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='metadata']/*[local-name()='title']").map { $0.stringValue }, ["Title", "Inner"])
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='package']/*[local-name()='metadata']").count, 1)
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='meta'][@property='role']").map { $0.stringValue }, ["aut", "ill"])
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='meta'][@refines][@property=\"role\"]").map { $0.stringValue }, ["aut", "ill"])
        XCTAssertEqual(try document.nodes(forXPath: "//*[@id]").map { $0.name }, ["dc:title"])
        XCTAssertEqual(try document.nodes(forXPath: "//*[local-name()='none']").count, 0)
        XCTAssertEqual(try document.nodes(forXPath: "//*").count, 9)
    }

    /// Where a path's steps nest, the matches come in document order, not
    /// grouped by the element they were found under.
    func testNestedMatchesComeInDocumentOrder() throws {
        let document = try PortableXMLDocument(xmlString: "<a><y>1</y><b><a><y>2</y></a></b><y>3</y></a>")
        let nested = try document.nodes(forXPath: "//*[local-name()='a']/*[local-name()='y']")
        XCTAssertEqual(nested.map { $0.stringValue }, ["1", "2", "3"])
    }

    /// A relative path starts with the children of the node it is evaluated
    /// from, and from a document that is its root element.
    func testRelativePathsStartWithTheChildren() throws {
        let document = try sampleDocument()
        let metadata = try XCTUnwrap(try document.nodes(forXPath: "//*[local-name()='metadata']").first as? PortableXMLElement)
        XCTAssertEqual(try metadata.nodes(forXPath: "*").count, 4)
        XCTAssertEqual(try metadata.nodes(forXPath: "*[local-name()='meta'][@property='other']").map { $0.stringValue }, ["x"])
        XCTAssertEqual(try document.nodes(forXPath: "*[local-name()='package']/*[local-name()='wrap']/*[local-name()='metadata']").count, 1)
        XCTAssertEqual(try document.nodes(forXPath: "*[local-name()='wrap']").count, 0, "the root is the package, not the wrap")
    }

    /// An expression outside the subset throws, however plausible, so that it
    /// can never read as matching nothing.
    func testAnUnsupportedPathThrowsInsteadOfMatchingNothing() throws {
        let document = try sampleDocument()
        let unsupported = [
            "", "/", "//", "title", "//title", "//*[local-name()='a'", "//*[local-name()=a]", "//*[1]", "//*[last()]",
            "//*[name()='a']", "//*[@a=b]", "//*[@a:b]", "//*[@]", "/*", "/package", "child::*", "//*|//*", "..", ".",
            "//*[local-name()='a'] ", " //*", "//*/", "//*[local-name()='a' and @b]", "//@id", "//*[@id='x]",
            "//text()", "//*[local-name()='a']/@id",
        ]
        for expression in unsupported {
            XCTAssertThrowsError(try document.nodes(forXPath: expression), expression) { error in
                XCTAssertEqual(error as? PortableXMLError, .unsupportedXPath(expression), expression)
            }
        }
    }

    /// A path that starts with `//` is read from a document; from an element
    /// it throws, since the tree keeps no link from a node to its document.
    func testADescendantPathFromAnElementThrows() throws {
        let element = try XCTUnwrap(try sampleDocument().rootElement())
        XCTAssertThrowsError(try element.nodes(forXPath: "//*[local-name()='title']")) { error in
            XCTAssertEqual(error as? PortableXMLError, .unsupportedXPath("//*[local-name()='title']"))
        }
    }

    // MARK: - Tests: The Tree

    /// An element's text is everything inside it, comments and processing
    /// instructions included, as in Foundation; a namespace declaration is no
    /// attribute; an unprefixed attribute and a prefixed one are two.
    func testNodesKeepFoundationsTextNamesAndNamespaces() throws {
        let document = try PortableXMLDocument(xmlString: """
            <a xmlns:p="urn:p" xmlns="urn:d" p:k="1" k="2"><b>one<!--two--><?three four?></b>five<p:c/></a>
            """)
        let root = try XCTUnwrap(document.rootElement())
        XCTAssertEqual(root.stringValue, "one" + "two" + "four" + "five")
        XCTAssertEqual(root.attributes?.map { $0.name }, ["k", "p:k"], "unprefixed first, then by name")
        XCTAssertEqual(root.attribute(forName: "k")?.stringValue, "2")
        XCTAssertEqual(root.attribute(forName: "p:k")?.stringValue, "1")
        XCTAssertNil(root.attribute(forName: "xmlns"))
        XCTAssertNil(root.attribute(forName: "xmlns:p"))
        XCTAssertEqual(root.uri, "urn:d")
        let prefixed = try XCTUnwrap(root.children?.last as? PortableXMLElement)
        XCTAssertEqual([prefixed.name, prefixed.localName, prefixed.prefix, prefixed.uri], ["p:c", "c", "p", "urn:p"])
        XCTAssertEqual([root.level, prefixed.level, document.level], [1, 2, 0])
        XCTAssertEqual(document.rootElement()?.kind, .element)
        XCTAssertNil(try PortableXMLDocument(xmlString: "<a/>").rootElement()?.children)
    }

    /// The order of an element's attributes does not change from one reading
    /// to the next, though XMLParser hands them over unordered.
    func testAttributeOrderIsStable() throws {
        let xml = "<a z=\"1\" y=\"2\" x=\"3\" w=\"4\" v=\"5\" u=\"6\" xml:lang=\"en\" a:b=\"7\" xmlns:a=\"urn:a\"/>"
        let expected: [String?] = ["u", "v", "w", "x", "y", "z", "a:b", "xml:lang"]
        for _ in 0..<5 {
            let root = try XCTUnwrap(PortableXMLDocument(xmlString: xml).rootElement())
            XCTAssertEqual(root.attributes?.map { $0.name }, expected)
        }
    }

    // MARK: - Tests: Documents That Are Not Well-Formed

    /// A strict reading refuses a document that is not well-formed, with an
    /// error of XMLParser's domain, and the tidy reading reads what it can.
    func testAMalformedDocumentIsRefusedStrictlyAndRepairedWhenTidied() throws {
        let truncated = "<rss><channel><title>T</title><item><title>I"
        XCTAssertThrowsError(try PortableXMLDocument(xmlString: truncated, options: [.nodeLoadExternalEntitiesNever])) { error in
            XCTAssertEqual((error as NSError).domain, XMLParser.errorDomain)
        }
        let tidied = try PortableXMLDocument(xmlString: truncated, options: [.documentTidyXML, .nodeLoadExternalEntitiesNever])
        XCTAssertEqual(tidied.rootElement()?.name, "rss")
        XCTAssertEqual(try tidied.nodes(forXPath: "//*[local-name()='title']").map { $0.stringValue }, ["T", "I"])
    }

    /// No data is an error in both readings; a document of text only has no
    /// root element when tidied.
    func testEmptyAndRootlessDocuments() throws {
        XCTAssertThrowsError(try PortableXMLDocument(data: Data()))
        XCTAssertThrowsError(try PortableXMLDocument(data: Data(), options: [.documentTidyXML]))
        XCTAssertThrowsError(try PortableXMLDocument(xmlString: "hello"))
        XCTAssertNil(try PortableXMLDocument(xmlString: "hello", options: [.documentTidyXML]).rootElement())
    }

    /// An unbound prefix is an error in a strict reading and is read as it
    /// stands, with no namespace, when tidied.
    func testAnUnboundPrefixIsAnErrorOnlyWhenStrict() throws {
        let xml = "<a><dc:b opf:r=\"1\">t</dc:b></a>"
        XCTAssertThrowsError(try PortableXMLDocument(xmlString: xml))
        let tidied = try XCTUnwrap(PortableXMLDocument(xmlString: xml, options: [.documentTidyXML]).rootElement()?.children?.first as? PortableXMLElement)
        XCTAssertEqual([tidied.name, tidied.localName, tidied.prefix], ["dc:b", "b", "dc"])
        XCTAssertNil(tidied.uri)
        XCTAssertEqual(tidied.attribute(forName: "opf:r")?.stringValue, "1")
    }

    // MARK: - Tests: Depth

    /// A document nested exactly `PortableXMLDocument.maximumDepth` levels
    /// deep is read, with its text; one level more is refused, strictly and
    /// tidily, and so is a broken document whose unclosed elements nest that
    /// deep.
    func testTheDepthBound() throws {
        let limit = PortableXMLDocument.maximumDepth
        func nested(_ depth: Int) -> String {
            String(repeating: "<a>", count: depth) + "x" + String(repeating: "</a>", count: depth)
        }
        let atLimit = try PortableXMLDocument(xmlString: nested(limit))
        XCTAssertEqual(atLimit.stringValue, "x")
        XCTAssertEqual(try atLimit.nodes(forXPath: "//*").count, limit)
        for options: PortableXMLNode.Options in [[], [.documentTidyXML]] {
            XCTAssertThrowsError(try PortableXMLDocument(xmlString: nested(limit + 1), options: options)) { error in
                XCTAssertEqual(error as? PortableXMLError, .tooDeep)
            }
        }
        // Unclosed void elements, as a broken feed's HTML has them.
        let unclosed = "<a>" + String(repeating: "<br>", count: limit + 10) + "</a>"
        XCTAssertThrowsError(try PortableXMLDocument(xmlString: unclosed, options: [.documentTidyXML])) { error in
            XCTAssertEqual(error as? PortableXMLError, .tooDeep)
        }
        // Many siblings are not depth.
        let wide = "<a>" + String(repeating: "<br/>", count: 5_000) + "</a>"
        XCTAssertEqual(try PortableXMLDocument(xmlString: wide).rootElement()?.children?.count, 5_000)
    }

    /// The depth scan of the lenient reader counts what a tag-by-tag reading
    /// would, and not what is inside comments, CDATA, and quoted attributes.
    func testTheLenientDepthScanSkipsWhatIsNotAnElement() {
        let limit = PortableXMLDocument.maximumDepth
        let comments = String(repeating: "<!-- <a><a><a> -->", count: limit)
        let cdata = "<![CDATA[" + String(repeating: "<a>", count: limit + 5) + "]]>"
        let attributes = "<a title=\"" + String(repeating: "<b>", count: limit + 5) + "\"/>"
        let instructions = String(repeating: "<?x <a> ?>", count: limit)
        let closed = String(repeating: "<a/>", count: limit * 2) + String(repeating: "<a></a>", count: limit * 2)
        for text in [comments, cdata, attributes, instructions, closed] {
            XCTAssertFalse(nestsTooDeeply(text))
        }
        XCTAssertTrue(nestsTooDeeply(String(repeating: "<a>", count: limit + 1)))
        XCTAssertFalse(nestsTooDeeply("1 < 2 and 3 > 2 <"))
    }

    /// Whether the lenient reader's scan, `MarkupGuard`'s, refuses `text` as nested past the tree's limit.
    private func nestsTooDeeply(_ text: String) -> Bool {
        var limits = MarkupGuard.Limits.standard
        limits.deepestNesting = PortableXMLDocument.maximumDepth
        return (try? MarkupGuard.inspect(Array(text.utf8), as: .xml, limits: limits)) == nil
    }

    /// A chain of `depth` elements, each inside the one before, built by
    /// hand, since the reader refuses documents this deep. Returns the
    /// outermost.
    private func chain(ofDepth depth: Int) -> PortableXMLElement {
        let outermost = PortableXMLElement()
        var innermost: PortableXMLNode = outermost
        for _ in 0..<depth {
            let child = PortableXMLElement()
            innermost.childNodes.append(child)
            innermost = child
        }
        return outermost
    }

    /// The depth scan models SwiftSoup's stack, not a count of tags: unclosed
    /// `<br>` elements that an ancestor's end tag closes do not add up (a
    /// damaged feed of any length is read), while stray end tags that close
    /// nothing, which leave SwiftSoup's stack growing, are refused.
    func testTheLenientDepthScanFollowsSwiftSoupsStack() throws {
        let limit = PortableXMLDocument.maximumDepth
        let items = String(repeating: "<item><description>One<br>Two<br>Three<br></description></item>", count: 300)
        let feed = "<rss><channel>" + items + "</channel></rss>"
        XCTAssertFalse(nestsTooDeeply(feed))
        let tidied = try PortableXMLDocument(xmlString: feed, options: [.documentTidyXML])
        XCTAssertEqual(try tidied.nodes(forXPath: "//*[local-name()='item']").count, 300)

        // An end tag closes the nearest open element of its name, and those above it.
        let rounds = String(repeating: "<a>" + String(repeating: "<b><c>", count: 200) + "</a>", count: 5)
        XCTAssertFalse(nestsTooDeeply(rounds))
        // Stray end tags close nothing: the opens pile up.
        let stray = "<a>" + String(repeating: "<b></q>", count: limit + 88) + "</a>"
        XCTAssertTrue(nestsTooDeeply(stray))
        XCTAssertThrowsError(try PortableXMLDocument(xmlString: stray, options: [.documentTidyXML])) { error in
            XCTAssertEqual(error as? PortableXMLError, .tooDeep)
        }
        // 600 stray end tags around nested opens.
        let around = String(repeating: "</q>", count: 600) + String(repeating: "<a>", count: limit + 1) + String(repeating: "</q>", count: 600)
        XCTAssertTrue(nestsTooDeeply(around))
    }

    /// A hostile document of 100,000 pairs `<a></q>` is refused promptly by
    /// the scan, before SwiftSoup is asked to build a tree 100,000 deep
    /// (with a search of its whole stack for every stray end tag).
    func testAHugeDocumentOfStrayEndTagsIsRefusedPromptly() {
        let hostile = String(repeating: "<a></q>", count: 100_000)
        let started = Date()
        XCTAssertThrowsError(try PortableXMLDocument(xmlString: hostile, options: [.documentTidyXML])) { error in
            XCTAssertEqual(error as? PortableXMLError, .tooDeep)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the refusal reads only the first few hundred tags")
    }

    /// Letting a tree go does not recurse, however deep it is, so a crafted
    /// document cannot exhaust the stack: Foundation's tree needed
    /// `EPUBParser.takeApart` for this. Releasing the root of a chain 300,000
    /// deep, and emptying it with `setChildren`, would overflow the stack of
    /// this thread several times over if either recursed.
    func testReleasingADeepTreeDoesNotOverflowTheStack() {
        var root: PortableXMLElement? = chain(ofDepth: 300_000)
        XCTAssertNotNil(root?.children)
        root = nil
        XCTAssertNil(root)
        let outer = chain(ofDepth: 300_000)
        outer.setChildren(nil)
        XCTAssertNil(outer.children)
    }

    // MARK: - Tests: External Entities

    /// A document naming a local file as an entity never has the file's text
    /// in its tree, however it is read: the strict reading refuses the
    /// document, and the tidy one keeps the reference as text.
    func testNoExternalEntityIsEverLoaded() throws {
        let folder = try makeSandboxDirectory("PortableXMLEntity")
        let secret = folder.appendingPathComponent("secret.txt")
        try "TOP-SECRET-MARKER".write(to: secret, atomically: true, encoding: .utf8)
        let xml = "<!DOCTYPE a [<!ENTITY x SYSTEM \"\(secret.absoluteString)\">]><a>[&x;]</a>"
        XCTAssertThrowsError(try PortableXMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever]))
        let tidied = try PortableXMLDocument(xmlString: xml, options: [.documentTidyXML, .nodeLoadExternalEntitiesNever])
        XCTAssertFalse((tidied.stringValue ?? "").contains("TOP-SECRET-MARKER"))
        // Nor with the option left out: the portable tree never loads one.
        XCTAssertThrowsError(try PortableXMLDocument(xmlString: xml))
        let tidiedWithoutTheOption = try PortableXMLDocument(xmlString: xml, options: [.documentTidyXML])
        XCTAssertFalse((tidiedWithoutTheOption.stringValue ?? "").contains("TOP-SECRET-MARKER"))
    }

    /// The `<!ENTITY` pre-scan refuses the document above before XMLParser
    /// runs, so that test does not exercise XMLParser's own settings. Here the
    /// document names a DTD file as its external subset, and the entity is
    /// declared in that file, so the document has no `<!ENTITY` in it: the
    /// entity's text could reach the tree only if XMLParser loaded the file.
    /// It never does, strictly or tidily. (Probed on the Mac: XMLParser does
    /// not load an external subset even with `shouldResolveExternalEntities`
    /// on, and instead asks its delegate for the entity, so the guard is
    /// `PortableXMLStrictReader` answering nil; this test fails if it ever
    /// answers with the file.)
    func testNoExternalSubsetIsEverLoaded() throws {
        let folder = try makeSandboxDirectory("PortableXMLSubset")
        let subset = folder.appendingPathComponent("subset.dtd")
        try "<!ENTITY x \"TOP-SECRET-MARKER\">".write(to: subset, atomically: true, encoding: .utf8)
        let xml = "<!DOCTYPE a SYSTEM \"\(subset.absoluteString)\"><a>[&x;]</a>"
        XCTAssertNil(xml.range(of: "<!ENTITY"), "the pre-scan must not be what stops this document")
        for options: PortableXMLNode.Options in [[], [.nodeLoadExternalEntitiesNever], [.documentTidyXML]] {
            // The document may be read or refused, but the file's text is never in it.
            if let document = try? PortableXMLDocument(xmlString: xml, options: options) {
                XCTAssertFalse((document.stringValue ?? "").contains("TOP-SECRET-MARKER"))
            }
        }
    }
}
