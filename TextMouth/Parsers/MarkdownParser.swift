import Foundation
import Markdown

enum MarkdownDocParser {

    static func parse(markdown: String, title: String = "Untitled") throws -> DocumentContent {
        let chapter = try parseChapter(markdown: markdown, title: title)
        return DocumentContent(
            title: chapter.title,
            author: "Unknown",
            chapters: [chapter]
        )
    }

    /// Parse one chapter without constructing an intermediate DocumentContent.
    /// Multi-chapter cache loading uses this to avoid calculating book metrics
    /// once per chapter and then again for the assembled document.
    static func parseChapter(markdown: String, title: String = "Untitled") throws -> Chapter {
        let document = Document(parsing: markdown)

        // Collect headings
        var collector = HeadingCollector()
        collector.visit(document)

        // Get plain text (strip markdown formatting)
        var textExtractor = PlainTextExtractor()
        textExtractor.visit(document)
        let plainText = textExtractor.result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Map headings to character offsets in the plain text
        var headings: [Heading] = []
        var searchStart = plainText.startIndex
        for (level, headingText) in collector.headings {
            let offset: Int
            if let range = plainText.range(of: headingText, range: searchStart..<plainText.endIndex) {
                offset = plainText.utf16Offset(of: range.lowerBound)
                searchStart = range.upperBound
            } else {
                offset = plainText.utf16Offset(of: searchStart)
            }
            headings.append(Heading(level: level, text: headingText, characterOffset: offset))
        }

        // Use first heading as title if available
        let docTitle = headings.first?.text ?? title

        return Chapter(title: docTitle, text: plainText, headings: headings)
    }
}

// MARK: - Heading Collector

private struct HeadingCollector: MarkupWalker {
    var headings: [(level: Int, text: String)] = []

    mutating func visitHeading(_ heading: Markdown.Heading) -> () {
        let text = heading.plainText
        headings.append((level: heading.level, text: text))
        descendInto(heading)
    }
}

// MARK: - Plain Text Extractor

private struct PlainTextExtractor: MarkupWalker {
    var result = ""

    mutating func visitText(_ text: Markdown.Text) -> () {
        result += text.string
    }

    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> () {
        result += " "
    }

    mutating func visitLineBreak(_ lineBreak: LineBreak) -> () {
        result += "\n"
    }

    mutating func visitParagraph(_ paragraph: Markdown.Paragraph) -> () {
        if !result.isEmpty && !result.hasSuffix("\n\n") {
            result += "\n\n"
        }
        descendInto(paragraph)
    }

    mutating func visitHeading(_ heading: Markdown.Heading) -> () {
        if !result.isEmpty && !result.hasSuffix("\n\n") {
            result += "\n\n"
        }
        descendInto(heading)
        result += "\n\n"
    }
}
