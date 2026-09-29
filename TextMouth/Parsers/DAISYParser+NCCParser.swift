import Foundation
import SwiftSoup

// MARK: - DAISY 2.02 NCC Parser

/// Parsed NCC (Navigation Control Center) data from a DAISY 2.02 book
struct DAISY202NCCResult {
    var title: String = ""
    var author: String = ""
    var headings: [NCCHeading] = []
}

/// A heading entry from the DAISY 2.02 NCC file
struct NCCHeading {
    var level: Int
    var text: String
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
        Self.collect(from: try SwiftSoup.parse(html), into: &result)
        return result
    }

    // MARK: - Document Walk

    /// Whether the file still ends with a closing body or html tag.
    /// Searching backwards finds them at once in an intact file.
    private static func containsDocumentEnd(_ html: String) -> Bool {
        ["</body", "</html"].contains { html.range(of: $0, options: [.caseInsensitive, .backwards]) != nil }
    }

    /// Gather metadata and headings from `node`'s descendants in document
    /// order. A direct walk keeps SwiftSoup's selector cache, whose cached
    /// results retain the document, out of a one-shot parse.
    private static func collect(from node: Node, into result: inout DAISY202NCCResult) {
        for child in node.getChildNodes() {
            guard let element = child as? Element else { continue }
            let tag = element.tagName().lowercased()
            if tag == "meta" {
                recordMetadata(from: element, into: &result)
            } else if let level = headingLevels[tag] {
                // HTML never nests headings, so nothing inside one is another entry.
                if let heading = heading(from: element, level: level) {
                    result.headings.append(heading)
                }
            } else {
                collect(from: element, into: &result)
            }
        }
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

    /// The `href` of the first link inside `node` that has one.
    private static func firstLinkDestination(in node: Node) -> String? {
        for child in node.getChildNodes() {
            guard let element = child as? Element else { continue }
            if element.tagName().lowercased() == "a",
               let href = try? element.attr("href"), !href.isEmpty {
                return href
            }
            if let nested = firstLinkDestination(in: element) {
                return nested
            }
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
