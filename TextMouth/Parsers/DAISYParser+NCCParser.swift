import Foundation
import SwiftSoup

// MARK: - DAISY 2.02 NCC Parser

/// Parsed NCC (Navigation Control Center) data from a DAISY 2.02 book
struct DAISY202NCCResult {
    var title: String = ""
    var author: String = ""
    var headings: [NCCHeading] = []
    /// The book's printed pages, in document order (PG08).
    var pages: [NCCPage] = []
}

/// A heading entry from the DAISY 2.02 NCC file
struct NCCHeading {
    var level: Int
    var text: String
    var href: String
}

/// A page entry from the DAISY 2.02 NCC file (PG08): a `span` whose class is
/// `page-normal`, `page-front`, or `page-special`, holding a link to the
/// SMIL `par` or `text` that synchronizes the page's number.
struct NCCPage {
    /// The page's name as the NCC gives it, whitespace collapsed; empty when
    /// the entry has no words (the marker then falls back to its ordinal).
    var label: String
    /// The destination of the entry's first link, empty when it has none.
    var href: String
}

/// Reads a DAISY 2.02 `ncc.html`: Dublin Core metadata from its `<meta>`
/// tags and the book's navigation from its `<h1>`–`<h6>` headings.
///
/// The DAISY 2.02 specification calls for XHTML, but NCC files in the wild
/// are often ordinary HTML, with unclosed `<meta>` and `<br>` tags, named
/// entities such as `&nbsp;`, and upper-case tag names, which no XML parser
/// accepts. The file is therefore parsed as HTML, the way a browser reads
/// it. HTML parsing hides one kind of damage: a file cut short simply ends,
/// its open elements closed. Truncation always removes the end of a file
/// first, and with it the closing `</body>` and `</html>` tags, so a file
/// missing both is reported instead of being read as a shorter book.
struct DAISY202NCCParser {
    /// The file's text.
    let html: String
    /// The file's path inside the package, named in errors.
    let file: String

    /// Heading tags and the navigation level each one gives.
    private static let headingLevels = ["h1": 1, "h2": 2, "h3": 3, "h4": 4, "h5": 5, "h6": 6]

    /// The classes that make a `span` a page entry.
    private static let pageClasses: Set<String> = ["page-normal", "page-front", "page-special"]

    /// Prepare to parse `html`, reporting problems under the name `file`.
    init(html: String, file: String) {
        self.html = html
        self.file = file
    }

    /// Read `path` from `provider` and decode it as UTF-8 when valid, or as
    /// ISO Latin 1, the encoding older NCC files use, when it is not.
    /// - Throws: the provider's error when the file cannot be read.
    init(path: String, in provider: DAISYFileProvider) throws {
        let data = try provider.readFile(at: path)
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw DAISYParserError.parseError("Cannot decode \(path)")
        }
        self.init(html: html, file: path)
    }

    /// Parse the file's metadata and headings, in document order.
    /// - Throws: `DAISYParserError.malformedXML` naming the file when it has
    ///   neither closing tag, since the headings after the cut are missing.
    func parse() throws -> DAISY202NCCResult {
        guard Self.containsDocumentEnd(html) else {
            throw DAISYParserError.malformedXML(
                file: file,
                reason: "it stops before its closing body and html tags, so the end of the book's navigation is missing"
            )
        }
        var result = DAISY202NCCResult()
        Self.collect(from: try HTMLNesting.parse(html), into: &result)
        return result
    }

    // MARK: - Document Walk

    /// Whether the file still ends with a closing body or html tag.
    /// Searching backwards finds them at once in an intact file.
    private static func containsDocumentEnd(_ html: String) -> Bool {
        ["</body", "</html"].contains { html.range(of: $0, options: [.caseInsensitive, .backwards]) != nil }
    }

    /// Gather metadata, headings, and page entries from `node`'s descendants
    /// in document order. A direct walk keeps SwiftSoup's selector cache, whose cached
    /// results retain the document, out of a one-shot parse.
    ///
    /// The walk keeps its own stack of the elements still to visit rather
    /// than calling itself for every element: SwiftSoup reads an NCC nested
    /// thousands deep, and imports run on a worker thread's 512 KiB stack,
    /// which such a call chain overflowed. Children are pushed last first,
    /// so they are visited in document order.
    private static func collect(from node: Node, into result: inout DAISY202NCCResult) {
        var stack = childElementsLastFirst(of: node)
        while let element = stack.popLast() {
            let tag = element.tagName().lowercased()
            if tag == "meta" {
                recordMetadata(from: element, into: &result)
            } else if let level = headingLevels[tag] {
                // HTML never nests headings, so nothing inside one is another entry.
                if let heading = heading(from: element, level: level) {
                    result.headings.append(heading)
                }
            } else if tag == "span", isPageEntry(element) {
                // A page entry holds only its number and link; nothing
                // inside it is another entry.
                result.pages.append(page(from: element))
            } else {
                stack += childElementsLastFirst(of: element)
            }
        }
    }

    /// The elements among `node`'s children, last first: pushed onto a
    /// walk's stack of the elements still to visit, they are visited in
    /// document order.
    private static func childElementsLastFirst(of node: Node) -> [Element] {
        node.getChildNodes().reversed().compactMap { $0 as? Element }
    }

    /// Whether `element`'s `class` attribute lists a page class. The
    /// attribute is a space-separated list, matched without regard to case.
    private static func isPageEntry(_ element: Element) -> Bool {
        let classes = ((try? element.attr("class")) ?? "")
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        return classes.contains(where: pageClasses.contains)
    }

    /// The navigation entry for a page: its words and the destination of its
    /// first link. Unlike a heading, an entry without words is kept, since
    /// its place in the NCC gives it its ordinal label.
    private static func page(from element: Element) -> NCCPage {
        NCCPage(
            label: normalizedWhitespace((try? element.text()) ?? ""),
            href: firstLinkDestination(in: element) ?? ""
        )
    }

    /// Keep the first non-empty `dc:title` and `dc:creator` values. Meta
    /// names match regardless of case, as DAISY producers vary.
    private static func recordMetadata(from meta: Element, into result: inout DAISY202NCCResult) {
        let name = ((try? meta.attr("name")) ?? "").lowercased()
        let content = normalizedWhitespace((try? meta.attr("content")) ?? "")
        switch name {
        case "dc:title" where result.title.isEmpty:
            result.title = content
        case "dc:creator" where result.author.isEmpty:
            result.author = content
        default:
            break
        }
    }

    /// The navigation entry for a heading: its words, and the destination of
    /// its first link. A heading without words is no destination at all.
    private static func heading(from element: Element, level: Int) -> NCCHeading? {
        let text = normalizedWhitespace((try? element.text()) ?? "")
        guard !text.isEmpty else { return nil }
        return NCCHeading(level: level, text: text, href: firstLinkDestination(in: element) ?? "")
    }

    /// The `href` of the first link inside `node` that has one, in document
    /// order. Like `collect(from:into:)`, the search keeps its own stack of
    /// the elements still to visit, so a heading nested thousands deep
    /// cannot overflow a worker thread's stack.
    private static func firstLinkDestination(in node: Node) -> String? {
        var stack = childElementsLastFirst(of: node)
        while let element = stack.popLast() {
            if element.tagName().lowercased() == "a",
               let href = try? element.attr("href"), !href.isEmpty {
                return href
            }
            stack += childElementsLastFirst(of: element)
        }
        return nil
    }

    /// Collapse each run of whitespace, including the no-break spaces that
    /// `&nbsp;` produces, to one space, and trim the ends. Labels and titles
    /// then read and compare the same however the file was laid out.
    private static func normalizedWhitespace(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
