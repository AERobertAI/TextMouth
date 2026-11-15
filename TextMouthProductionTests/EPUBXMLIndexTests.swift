import XCTest
@testable import TextMouth

// MARK: - The Package Document Read from One Walk, Not by XPath

/// The EPUB reader finds the elements of its package document, container, and
/// NCX from one walk of the tree (`XMLElementIndex`) instead of by XPath (the
/// November 14, 2026 import speed-up, H7). What it reads must be what the
/// XPath queries read. This keeps those queries, as they were, as the
/// reference, and compares the two on package documents of every shape the
/// readers see: namespaces declared, undeclared, default, and prefixed; a
/// guide inside a guide; attributes missing; authors by `opf:role`, by a
/// refining `meta`, by `dcterms:creator`, and by `contributor`.
final class EPUBXMLIndexTests: XCTestCase {

    // MARK: - The reference: the XPath queries as they were

    /// The elements `//*[local-name()='name']` finds in `doc`.
    private func xpath(_ doc: XMLDocument, _ path: String) -> [XMLElement] {
        ((try? doc.nodes(forXPath: path)) ?? []).compactMap { $0 as? XMLElement }
    }

    /// The reference author: what `EPUBParser.authorName(in:)` read through XPath.
    private func referenceAuthor(_ doc: XMLDocument) -> String? {
        func name(of element: XMLElement) -> String? {
            let text = (element.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Book.isUnknownAuthor(text) ? nil : text
        }
        func hasAuthorRole(_ element: XMLElement, _ refined: [String: String]) -> Bool {
            var role = element.attribute(forName: "opf:role")?.stringValue ?? element.attribute(forName: "role")?.stringValue
            if role == nil, let id = element.attribute(forName: "id")?.stringValue { role = refined[id] }
            return role?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "aut"
        }
        var roles: [String: String] = [:]
        for meta in xpath(doc, "//*[local-name()='meta'][@refines][@property='role']") {
            guard let refines = meta.attribute(forName: "refines")?.stringValue, let role = meta.stringValue else { continue }
            let id = refines.hasPrefix("#") ? String(refines.dropFirst()) : refines
            if roles[id] == nil { roles[id] = role }
        }
        let named = xpath(doc, "//*[local-name()='creator']").filter { name(of: $0) != nil }
        if let creator = named.first(where: { hasAuthorRole($0, roles) }) ?? named.first { return name(of: creator) }
        let termMetas = xpath(doc, "//*[local-name()='meta'][@property='dcterms:creator']")
        if let found = termMetas.lazy.compactMap(name(of:)).first { return found }
        let contributors = xpath(doc, "//*[local-name()='contributor']")
        return contributors.first { name(of: $0) != nil && hasAuthorRole($0, roles) }.flatMap(name(of:))
    }

    /// The reference package data: what `EPUBParser.parseOPF` read through XPath.
    private func referenceOPF(_ xml: String) throws -> EPUBParser.OPFData {
        let doc = try XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever])
        let title = try doc.nodes(forXPath: "//*[local-name()='title']").first?.stringValue ?? "Untitled"
        var manifest: [String: EPUBParser.ManifestItem] = [:]
        for node in try doc.nodes(forXPath: "//*[local-name()='item']") {
            guard let element = node as? XMLElement, let id = element.attribute(forName: "id")?.stringValue,
                  let href = element.attribute(forName: "href")?.stringValue,
                  let mediaType = element.attribute(forName: "media-type")?.stringValue else { continue }
            manifest[id] = EPUBParser.ManifestItem(
                href: href, mediaType: mediaType, properties: element.attribute(forName: "properties")?.stringValue ?? ""
            )
        }
        let refs = try doc.nodes(forXPath: "//*[local-name()='itemref']").compactMap {
            ($0 as? XMLElement)?.attribute(forName: "idref")?.stringValue
        }
        let spine = try doc.nodes(forXPath: "//*[local-name()='spine']").first as? XMLElement
        let guide = try doc.nodes(forXPath: "//*[local-name()='guide']/*[local-name()='reference']").compactMap { node -> String? in
            guard let element = node as? XMLElement, element.attribute(forName: "type")?.stringValue == "toc" else { return nil }
            return element.attribute(forName: "href")?.stringValue
        }
        return EPUBParser.OPFData(
            title: title, author: referenceAuthor(doc) ?? Book.unknownAuthor, manifest: manifest, spineItemRefs: refs,
            spineTOCID: spine?.attribute(forName: "toc")?.stringValue, guideTOCHrefs: guide
        )
    }

    // MARK: - Package documents

    /// The namespace attributes and the prefix a package document is written with.
    private let shapes: [(root: String, dc: String, opf: String)] = [
        ("<package xmlns=\"http://www.idpf.org/2007/opf\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:opf=\"http://www.idpf.org/2007/opf\" version=\"3.0\">", "dc:", "opf:"),
        ("<opf:package xmlns:opf=\"http://www.idpf.org/2007/opf\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" version=\"2.0\">", "dc:", "opf:"),
        ("<package version=\"2.0\">", "dc:", "opf:"),
        ("<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\">", "", ""),
        ("<package xmlns:dc=\"urn:one\" xmlns:x=\"urn:two\"><!-- two namespaces for the same local names -->", "x:", ""),
    ]

    /// The metadata fragments a package may hold; `dc` is the Dublin Core prefix.
    private func metadataFragments(_ dc: String) -> [String] {
        [
            "<\(dc)title>The Title</\(dc)title>", "<\(dc)title>Second Title</\(dc)title>", "<\(dc)title/>",
            "<\(dc)creator opf:role=\"ill\">An Illustrator</\(dc)creator>", "<\(dc)creator opf:role=\"aut\">The Author</\(dc)creator>",
            "<\(dc)creator id=\"c1\">Refined Author</\(dc)creator><meta refines=\"#c1\" property=\"role\" scheme=\"marc:relators\">aut</meta>",
            "<\(dc)creator>Unknown</\(dc)creator>", "<\(dc)creator>  </\(dc)creator>", "<\(dc)creator>Plain Creator</\(dc)creator>",
            "<meta property=\"dcterms:creator\">Term Creator</meta>", "<meta property=\"dcterms:creator\">Unknown</meta>",
            "<meta property=\"dcterms:modified\">2026-01-01</meta>", "<meta name=\"cover\" content=\"cover-image\"/>",
            "<meta refines=\"#x\" property=\"role\">aut</meta>", "<meta property=\"role\">aut</meta>", "<meta refines=\"#c2\" property=\"title-type\">main</meta>",
            "<\(dc)contributor opf:role=\"aut\">Contributor Author</\(dc)contributor>", "<\(dc)contributor>Other Contributor</\(dc)contributor>",
            "<\(dc)publisher>The Publisher</\(dc)publisher>", "<\(dc)date>2020-05-01</\(dc)date>", "<\(dc)date>1999</\(dc)date>",
            "<\(dc)language>en</\(dc)language>", "<\(dc)language> und </\(dc)language>", "<\(dc)language>fr</\(dc)language>",
            "<\(dc)identifier id=\"id\">urn:uuid:1234</\(dc)identifier>", "<\(dc)identifier opf:scheme=\"ISBN\">978-3-16-148410-0</\(dc)identifier>",
            "<\(dc)identifier scheme=\"isbn\">xyz</\(dc)identifier>", "<\(dc)identifier>0-306-40615-2</\(dc)identifier>",
            "<\(dc)identifier>9780306406157</\(dc)identifier>", "<\(dc)identifier>not an isbn</\(dc)identifier>",
        ]
    }

    /// The rest of the package: manifest, spine, and guide fragments.
    private let bodyFragments: [String] = [
        "<item id=\"a\" href=\"a.xhtml\" media-type=\"application/xhtml+xml\"/>", "<item id=\"b\" href=\"b.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>",
        "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>", "<item id=\"nohref\" media-type=\"text/css\"/>", "<item href=\"noid.css\" media-type=\"text/css\"/>",
        "<item id=\"a\" href=\"again.xhtml\" media-type=\"application/xhtml+xml\"/>", "<opf:item id=\"p\" href=\"p.xhtml\" media-type=\"application/xhtml+xml\"/>",
        "<itemref idref=\"a\"/>", "<itemref idref=\"b\" linear=\"no\"/>", "<itemref/>", "<opf:itemref idref=\"p\"/>",
        "<guide><reference type=\"toc\" href=\"toc.xhtml#t\"/><reference type=\"cover\" href=\"cover.xhtml\"/><reference type=\"toc\"/></guide>",
        "<guide><guide><reference type=\"toc\" href=\"inner.xhtml\"/></guide><reference type=\"toc\" href=\"outer.xhtml\"/></guide>",
        "<reference type=\"toc\" href=\"stray.xhtml\"/>", "<opf:guide><opf:reference type=\"toc\" href=\"pfx.xhtml\"/></opf:guide>",
    ]

    /// A package document built from a shape and a selection of fragments.
    private func package(shape: Int, metadata: [String], body: [String], spineAttribute: String) -> String {
        let (root, _, _) = shapes[shape]
        let closing = root.hasPrefix("<opf:package") ? "</opf:package>" : "</package>"
        let items = body.filter { $0.contains("<item") }.joined()
        let refs = body.filter { $0.contains("<itemref") }.joined()
        let others = body.filter { !$0.contains("<item") }.joined()
        return "<?xml version=\"1.0\"?>\(root)<metadata>\(metadata.joined())</metadata><manifest>\(items)</manifest>"
            + "<spine\(spineAttribute)>\(refs)</spine>\(others)\(closing)"
    }

    /// Every field of the package data, compared.
    private func assertSameOPF(_ xml: String, file: StaticString = #filePath, line: UInt = #line) throws {
        // A package the XML parser refuses (a prefix with no namespace, say) is refused by both readings.
        guard (try? XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever])) != nil else {
            XCTAssertThrowsError(try EPUBParser.parseOPF(xml), xml, file: file, line: line)
            return
        }
        let expected = try referenceOPF(xml)
        let actual: EPUBParser.OPFData
        do {
            actual = try EPUBParser.parseOPF(xml)
        } catch EPUBParserError.missingSpine {
            XCTAssertTrue(expected.spineItemRefs.isEmpty, "the new reading found no spine, the old did: \(xml)", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.title, expected.title, xml, file: file, line: line)
        XCTAssertEqual(actual.author, expected.author, xml, file: file, line: line)
        XCTAssertEqual(actual.spineItemRefs, expected.spineItemRefs, xml, file: file, line: line)
        XCTAssertEqual(actual.spineTOCID, expected.spineTOCID, xml, file: file, line: line)
        XCTAssertEqual(actual.guideTOCHrefs, expected.guideTOCHrefs, xml, file: file, line: line)
        XCTAssertEqual(actual.manifest.mapValues { [$0.href, $0.mediaType, $0.properties] },
                       expected.manifest.mapValues { [$0.href, $0.mediaType, $0.properties] }, xml, file: file, line: line)
    }

    /// The package data of a hundred crafted shapes and a thousand random
    /// selections of fragments is the XPath reading's.
    func testThePackageDocumentReadsAsTheXPathReadingDid() throws {
        // The first few: every shape with the whole of what a package holds.
        for shape in shapes.indices {
            let dc = shapes[shape].dc
            try assertSameOPF(package(shape: shape, metadata: metadataFragments(dc), body: bodyFragments, spineAttribute: " toc=\"ncx\""))
            try assertSameOPF(package(shape: shape, metadata: [], body: ["<itemref idref=\"a\"/>"], spineAttribute: ""))
        }
        var generator = KFXSeededGenerator(seed: 1114)
        for _ in 0..<1_000 {
            let shape = Int.random(in: 0..<shapes.count, using: &generator)
            let dc = shapes[shape].dc
            let metadata = metadataFragments(dc).filter { _ in Bool.random(using: &generator) && Bool.random(using: &generator) }
            var body = bodyFragments.filter { _ in Bool.random(using: &generator) }
            if !body.contains(where: { $0.contains("<itemref") }) { body.append("<itemref idref=\"a\"/>") }
            let spineAttribute = Bool.random(using: &generator) ? " toc=\"ncx\"" : ""
            try assertSameOPF(package(shape: shape, metadata: metadata, body: body, spineAttribute: spineAttribute))
        }
    }

    /// The metadata a package gives (what the library lists) is the XPath reading's.
    func testThePackageMetadataReadsAsTheXPathReadingDid() throws {
        var generator = KFXSeededGenerator(seed: 47)
        for round in 0..<600 {
            let shape = Int.random(in: 0..<shapes.count, using: &generator)
            let dc = shapes[shape].dc
            let metadata = round < 5 ? metadataFragments(dc) : metadataFragments(dc).filter { _ in Bool.random(using: &generator) }
            let xml = package(shape: shape, metadata: metadata, body: ["<itemref idref=\"a\"/>"], spineAttribute: "")
            guard let doc = try? XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever]) else {
                XCTAssertThrowsError(try EPUBParser.parseMetadata(xml, file: "package"), xml)
                continue
            }
            func first(_ name: String) -> String { xpath(doc, "//*[local-name()='\(name)']").first?.stringValue ?? "" }
            let actual = try EPUBParser.parseMetadata(xml, file: "package")
            XCTAssertEqual(actual.title, first("title"), xml)
            XCTAssertEqual(actual.author, referenceAuthor(doc) ?? "", xml)
            XCTAssertEqual(actual.publisher, first("publisher"), xml)
            XCTAssertEqual(actual.publicationDate, first("date"), xml)
            XCTAssertEqual(actual.epubVersion, (xpath(doc, "//*[local-name()='package']").first)?.attribute(forName: "version")?.stringValue ?? "", xml)
            var language = first("language")
            if language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "und" { language = "" }
            XCTAssertEqual(actual.language, language, xml)
            // The identifier and ISBN, read as they were.
            var isbn = "", main = ""
            for element in xpath(doc, "//*[local-name()='identifier']") {
                let value = element.stringValue ?? ""
                main = value
                let scheme = element.attribute(forName: "scheme")?.stringValue ?? ""
                let opfScheme = element.attribute(forName: "opf:scheme")?.stringValue ?? ""
                if scheme.uppercased().contains("ISBN") || opfScheme.uppercased().contains("ISBN") { isbn = value }
                let stripped = value.replacingOccurrences(of: "-", with: "")
                if stripped.count == 10 || stripped.count == 13, stripped.allSatisfy({ $0.isNumber || $0 == "X" }) { isbn = value }
            }
            XCTAssertEqual(actual.isbn, isbn, xml)
            XCTAssertEqual(actual.identifier, main, xml)
        }
    }

    // MARK: - The container and the index

    /// The container's first rootfile is found as XPath finds it, and a
    /// container with none is refused as it was.
    func testTheContainerNamesItsPackageAsItDid() throws {
        let xmlns = "xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\""
        XCTAssertEqual(try EPUBParser.parseContainerForOPFPath(
            "<container \(xmlns)><rootfiles><rootfile full-path=\"OEBPS/content.opf\"/><rootfile full-path=\"second.opf\"/></rootfiles></container>"
        ), "OEBPS/content.opf")
        XCTAssertEqual(try EPUBParser.parseContainerForOPFPath(
            "<c:container xmlns:c=\"urn:oasis:names:tc:opendocument:xmlns:container\"><c:rootfiles><c:rootfile full-path=\"a.opf\"/></c:rootfiles></c:container>"
        ), "a.opf")
        XCTAssertThrowsError(try EPUBParser.parseContainerForOPFPath("<container \(xmlns)><rootfiles/></container>"))
        XCTAssertThrowsError(try EPUBParser.parseContainerForOPFPath("<container \(xmlns)><rootfiles><rootfile/></rootfiles></container>"))
    }

    /// Whatever the names and nesting, the index lists the elements XPath
    /// finds, in the same order: including a document whose root is the
    /// element asked for, names with several colons, and names of other case.
    func testTheIndexListsWhatXPathFinds() throws {
        let documents = [
            "<package xmlns=\"http://www.idpf.org/2007/opf\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><metadata><dc:title>T</dc:title></metadata><item/></package>",
            "<package><metadata><dc:title>T</dc:title></metadata><opf:item id=\"a\"/></package>",
            "<opf:package xmlns:opf=\"http://www.idpf.org/2007/opf\"><opf:metadata><opf:item/></opf:metadata><opf:package/></opf:package>",
            "<package xmlns:a=\"urn:a\" xmlns:b=\"urn:b\"><a:title>1</a:title><b:title>2</b:title><title>3</title></package>",
            "<package xmlns:dc=\"urn:x\"><metadata xmlns:dc=\"urn:y\"><dc:title>1</dc:title></metadata><dc:title>2</dc:title></package>",
            "<Package><Title>1</Title><title>2</title><TITLE>3</TITLE></Package>",
            "<package><guide><guide><reference/></guide><reference/></guide><reference/></package>",
            "<title><title><title/></title></title>",
            "<package><x:y:title xmlns:x=\"urn:x\"/></package>",
        ]
        let names = ["title", "item", "package", "metadata", "reference", "guide", "Title", "TITLE", "y:title", "x:y:title"]
        for xml in documents {
            guard let doc = try? XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever]) else { continue }
            let index = XMLElementIndex(doc)
            for name in names {
                let expected = xpath(doc, "//*[local-name()='\(name)']")
                let actual = index.elements(named: name)
                XCTAssertTrue(expected.count == actual.count && zip(expected, actual).allSatisfy { $0 === $1 }, "\(name) in \(xml)")
            }
            let expected = xpath(doc, "//*[local-name()='guide']/*[local-name()='reference']")
            let actual = index.elements(named: "reference", insideParentNamed: "guide")
            XCTAssertTrue(expected.count == actual.count && zip(expected, actual).allSatisfy { $0 === $1 }, "guide/reference in \(xml)")
        }
    }

    /// The NCX's entries: a label is the first `text` inside a `navLabel`,
    /// as `*[local-name()='navLabel']/*[local-name()='text']` found it, and a
    /// content element is the first child of that name.
    func testNCXLabelsAndContentAreFoundAsXPathFoundThem() throws {
        let xml = """
            <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/"><navMap>
            <navPoint id="a"><navLabel><text>One</text></navLabel><content src="a.xhtml"/><navPoint id="a1"><navLabel><text>One A</text></navLabel><content src="a1.xhtml"/></navPoint></navPoint>
            <navPoint id="b"><navLabel><audio/></navLabel><navLabel><text>Second Label</text><text>Third</text></navLabel><content src="b.xhtml"/><content src="b2.xhtml"/></navPoint>
            <navPoint id="c"><content src="c.xhtml"/></navPoint><navPoint id="d"><navLabel><text/></navLabel></navPoint>
            </navMap><pageList><pageTarget id="p1" value="1"><navLabel><text>i</text></navLabel><content src="p1.xhtml"/></pageTarget><pageTarget value="2"/></pageList></ncx>
            """
        let doc = try XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever])
        let index = XMLElementIndex(doc)
        for point in index.elements(named: "navPoint") {
            let label = (try? point.nodes(forXPath: "*[local-name()='navLabel']/*[local-name()='text']"))?.first?.stringValue
            XCTAssertEqual(point.firstNavLabelText?.stringValue, label, point.attribute(forName: "id")?.stringValue ?? "")
            let content = (try? point.nodes(forXPath: "*[local-name()='content']"))?.first as? XMLElement
            XCTAssertTrue(point.childElements(localName: "content").first === content)
        }
        XCTAssertEqual(index.elements(named: "navMap").count, 1)
        XCTAssertEqual(index.elements(named: "pageTarget", insideParentNamed: "pageList").count, 2)
        XCTAssertEqual(index.elements(named: "navPoint").count, 5)
    }

    /// A document nested thousands of levels deep is walked without recursion.
    func testADeepDocumentIsWalkedWithoutRecursion() throws {
        let depth = 2_000
        let xml = String(repeating: "<a>", count: depth) + "<item/>" + String(repeating: "</a>", count: depth)
        let doc = try XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever])
        let index = XMLElementIndex(doc)
        XCTAssertEqual(index.elements(named: "a").count, depth)
        XCTAssertEqual(index.elements(named: "item").count, 1)
    }
}
