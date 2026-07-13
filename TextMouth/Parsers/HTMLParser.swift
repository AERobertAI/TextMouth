import Foundation
import SwiftSoup

enum HTMLParser {

    static func parse(html: String, title: String = "Untitled") throws -> DocumentContent {
        let doc = try SwiftSoup.parse(html)

        // Try to get title from <title> tag
        let docTitle = (try? doc.title()).flatMap({ $0.isEmpty ? nil : $0 }) ?? title

        // Remove executable/presentational elements
        try doc.select("script, style").remove()

        let body = doc.body() ?? doc

        // Strip <nav> only when headings exist outside it (nav is
        // duplicating them). If headings only exist inside nav,
        // keep them so TTS still reads the heading.
        let allH = try body.select("h1, h2, h3, h4, h5, h6").size()
        let navH = try body.select("nav h1, nav h2, nav h3, nav h4, nav h5, nav h6").size()
        if allH > navH {
            try body.select("nav").remove()
        }

        let fullText = try body.text()

        // Extract headings
        var headings: [Heading] = []
        let headingElements = try doc.select("h1, h2, h3, h4, h5, h6")
        var searchStart = fullText.startIndex

        for element in headingElements.array() {
            let tag = element.tagName()
            let level = tag.last.flatMap({ Int(String($0)) }) ?? 1
            let headingText = try element.text()

            let offset: Int
            if let range = fullText.range(of: headingText, range: searchStart..<fullText.endIndex) {
                offset = fullText.utf16Offset(of: range.lowerBound)
                searchStart = range.upperBound
            } else {
                offset = fullText.utf16Offset(of: searchStart)
            }

            headings.append(Heading(level: level, text: headingText, characterOffset: offset))
        }

        // Treat entire HTML as a single chapter
        let chapter = Chapter(title: docTitle, text: fullText, headings: headings)

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
