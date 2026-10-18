import Foundation

// MARK: - DTBook Title and Author

/// SAX parser for the title and author of a DTBook file that has no OPF
/// beside it (FMT04): a DTBook kept on its own, or in an archive without a
/// package file.
///
/// The title is the first `meta` in `head` named `dc:Title` (compared
/// without regard to case) with its `content`, else the text of the first
/// `doctitle`. The author is the first `meta` named `dc:Creator`, else the
/// text of the first `docauthor`. White space is collapsed and trimmed, and
/// a name the file does not give is empty.
class DAISYDTBookHeadParser: DAISYSAXParser {
    /// What the file says, from its `head` and from its front matter.
    private var metaTitle = ""
    private var metaCreator = ""
    private var docTitle = ""
    private var docAuthor = ""

    /// Whether the parse is inside the `head` element.
    private var insideHead = false
    /// The element whose text is being collected (`doctitle` or
    /// `docauthor`), how deep inside it the parse is (it may hold inline
    /// elements), and the text so far.
    private var collecting: String?
    private var collectingDepth = 0
    private var collectedText = ""

    /// Parse the file for its title and author.
    /// - Throws: `DAISYParserError.malformedXML` naming the file when it is
    ///   truncated or not well-formed.
    func parse() throws -> DAISYMetadata {
        try parseDocument()
        return DAISYMetadata(
            title: metaTitle.isEmpty ? docTitle : metaTitle,
            author: metaCreator.isEmpty ? docAuthor : metaCreator
        )
    }

    /// Note the head, a meta element inside it, or the start of a
    /// `doctitle` or `docauthor` whose text is still wanted.
    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let name = ParserUtilities.stripNamespacePrefix(elementName).lowercased()

        // Inside doctitle or docauthor, an inline element is part of the text.
        if collecting != nil {
            collectingDepth += 1
            return
        }

        switch name {
        case "head":
            insideHead = true
        case "meta" where insideHead:
            readMeta(attributes)
        case "doctitle" where docTitle.isEmpty:
            startCollecting(name)
        case "docauthor" where docAuthor.isEmpty:
            startCollecting(name)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting != nil { collectedText += string }
    }

    /// Close the head, or finish the doctitle or docauthor being collected.
    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if let element = collecting {
            if collectingDepth > 0 {
                collectingDepth -= 1
            } else {
                finishCollecting(element)
            }
            return
        }
        if ParserUtilities.stripNamespacePrefix(elementName).lowercased() == "head" {
            insideHead = false
        }
    }

    // MARK: - Helpers

    /// Take the title or the creator from a `meta` element of the head, when
    /// it is the first of its kind and has a content.
    private func readMeta(_ attributes: [String: String]) {
        let content = Self.collapsed(attributes["content"] ?? "")
        guard !content.isEmpty else { return }
        switch (attributes["name"] ?? "").lowercased() {
        case "dc:title" where metaTitle.isEmpty: metaTitle = content
        case "dc:creator" where metaCreator.isEmpty: metaCreator = content
        default: break
        }
    }

    /// Begin collecting the text of `element`.
    private func startCollecting(_ element: String) {
        collecting = element
        collectingDepth = 0
        collectedText = ""
    }

    /// Keep the collected text as the doctitle or the docauthor.
    private func finishCollecting(_ element: String) {
        let text = Self.collapsed(collectedText)
        if element == "doctitle" { docTitle = text } else { docAuthor = text }
        collecting = nil
    }

    /// `text` with each run of white space replaced by one space, trimmed.
    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
