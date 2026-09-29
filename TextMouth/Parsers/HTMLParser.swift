import Foundation
import SwiftSoup

enum HTMLParser {

    static func parse(html: String, title: String = "Untitled") throws -> DocumentContent {
        let doc = try SwiftSoup.parse(html)

        // Try to get title from <title> tag
        let docTitle = (try? doc.title()).flatMap({ $0.isEmpty ? nil : $0 }) ?? title

        // Standalone HTML must keep literal punctuation and escaped tags as
        // text. Record DOM heading positions during plain-text extraction
        // rather than interpreting that text as intermediate Markdown.
        let body = doc.body() ?? doc
        try HTMLToMarkdownConverter.removeDuplicateNavigation(from: body)
        var extractor = HTMLReadingTextExtractor()
        try extractor.visit(body)
        let chapter = extractor.chapter(title: docTitle)

        return DocumentContent(
            title: docTitle,
            author: extractMetaAuthor(doc) ?? "Unknown",
            chapters: [chapter]
        )
    }

    private static func extractMetaAuthor(_ doc: Document) -> String? {
        guard let meta = try? doc.select("meta[name=author]").first() else { return nil }
        return try? meta.attr("content")
    }
}

/// Match SwiftSoup's plain-text whitespace rules while recording positions at
/// the actual heading nodes. No substring search or marker text is involved.
private struct HTMLReadingTextExtractor {
    private var text = ""
    private var utf16Length = 0
    private var headings: [Heading] = []

    /// Visit each node once, skipping executable content and preserving the
    /// same block separators and preformatted text used by direct HTML reading.
    mutating func visit(_ node: Node) throws {
        if let textNode = node as? TextNode {
            let parent = textNode.parent() as? Element
            let preservesWhitespace = parent?.tag().preserveWhitespace() == true
                || parent?.parent()?.tag().preserveWhitespace() == true
            var value = textNode.getWholeText()
            if !preservesWhitespace {
                value = StringUtil.normaliseWhitespace(value)
                if (text.isEmpty || text.hasSuffix(" ")), value.hasPrefix(" ") {
                    value.removeFirst()
                }
            }
            append(value)
            return
        }
        if let element = node as? Element {
            let tag = element.tagName().lowercased()
            // Match the cached Markdown conversion: hidden content, page lists,
            // and landmarks are outside the rendered reading flow.
            guard tag != "script", tag != "style",
                  !PublicationSemantics.isExcludedFromReadingFlow(element) else { return }
            if !text.isEmpty, (element.isBlock() || tag == "br"), !text.hasSuffix(" ") {
                append(" ")
            }
            if ["h1", "h2", "h3", "h4", "h5", "h6"].contains(tag),
               let level = tag.last?.wholeNumberValue {
                let label = try element.text()
                if !label.isEmpty {
                    headings.append(Heading(level: level, text: label, characterOffset: utf16Length))
                }
            }
        }
        for child in node.getChildNodes() {
            try visit(child)
        }
    }

    /// Advance UTF-16 coordinates incrementally, including non-BMP characters.
    private mutating func append(_ value: String) {
        text += value
        utf16Length += value.utf16.count
    }

    /// Apply outer whitespace trimming to the text and its coordinates together.
    func chapter(title: String) -> Chapter {
        let firstContent = text.rangeOfCharacter(from: .whitespacesAndNewlines.inverted)?.lowerBound ?? text.endIndex
        let prefixLength = text.utf16Offset(of: firstContent)
        let plainText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHeadings = headings.map {
            Heading(level: $0.level, text: $0.text, characterOffset: max(0, $0.characterOffset - prefixLength))
        }
        return Chapter(title: title, text: plainText, headings: normalizedHeadings)
    }
}
