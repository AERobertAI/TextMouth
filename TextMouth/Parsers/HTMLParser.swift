import Foundation
import SwiftSoup

enum HTMLParser {

    static func parse(html: String, title: String = "Untitled") throws -> DocumentContent {
        let doc = try SwiftSoup.parse(html)

        // Try to get title from <title> tag
        let docTitle = (try? doc.title()).flatMap({ $0.isEmpty ? nil : $0 }) ?? title

        // Remove non-content elements: script/style (executable/presentational)
        // and nav (navigation TOC that duplicates heading text).
        try doc.select("script, style, nav").remove()

        let body = doc.body() ?? doc
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
                offset = fullText.distance(from: fullText.startIndex, to: range.lowerBound)
                searchStart = range.upperBound
            } else {
                offset = fullText.distance(from: fullText.startIndex, to: searchStart)
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
