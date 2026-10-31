import Foundation
import SwiftSoup

enum HTMLParser {

    static func parse(html: String, title: String = "Untitled") throws -> DocumentContent {
        let doc = try HTMLNesting.parse(html)

        // Try to get title from <title> tag
        let docTitle = (try? doc.title()).flatMap({ $0.isEmpty ? nil : $0 }) ?? title

        // Standalone HTML must keep literal punctuation and escaped tags as
        // text. Record DOM heading positions during plain-text extraction
        // rather than interpreting that text as intermediate Markdown. The
        // reading follows the rules the Markdown cache shares (see
        // HTMLReadingText), so a fresh and a cached reading hear the same words.
        let body = doc.body() ?? doc
        try HTMLToMarkdownConverter.removeDuplicateNavigation(from: body)
        var reading = HTMLReadingText(recordsHeadings: true)
        reading.appendChildren(of: body)
        let chapter = reading.chapter(title: docTitle)

        return DocumentContent(
            title: docTitle,
            author: extractMetaAuthor(doc) ?? Book.unknownAuthor,
            chapters: [chapter]
        )
    }

    private static func extractMetaAuthor(_ doc: Document) -> String? {
        guard let meta = try? doc.select("meta[name=author]").first() else { return nil }
        return try? meta.attr("content")
    }
}

private extension HTMLReadingText {
    /// The reading as one chapter. Whitespace at either end is trimmed from
    /// the text and its heading coordinates together.
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
