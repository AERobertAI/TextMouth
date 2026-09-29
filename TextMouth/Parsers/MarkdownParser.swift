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
    static func parseChapter(
        markdown: String,
        title: String = "Untitled",
        includeNavigationHeadings: Bool = false
    ) throws -> Chapter {
        let document = Document(parsing: markdown)

        // Capture headings while emitting their text. Searching for their
        // labels afterwards can bind a heading to an earlier body paragraph.
        var textExtractor = PlainTextExtractor(includeNavigationHeadings: includeNavigationHeadings)
        textExtractor.visit(document)
        let plainText = textExtractor.result.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstContent = textExtractor.result.rangeOfCharacter(from: .whitespacesAndNewlines.inverted)?.lowerBound
            ?? textExtractor.result.endIndex
        let trimmedPrefixLength = textExtractor.result.utf16Offset(of: firstContent)
        var headings = textExtractor.headings
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { heading in
                Heading(level: heading.level, text: heading.text,
                        characterOffset: max(0, heading.offset - trimmedPrefixLength))
            }

        // An anchor at an existing semantic heading must not create a duplicate
        // row. Keep semantic labels/levels, then merge other TOC destinations in
        // text order. Coordinates come from the same walk that produces speech.
        var occupiedOffsets = Set(headings.map(\.characterOffset))
        let textLength = plainText.utf16.count
        for heading in textExtractor.navigationHeadings {
            let offset = min(textLength, max(0, heading.offset - trimmedPrefixLength))
            if occupiedOffsets.insert(offset).inserted {
                headings.append(Heading(level: heading.level, text: heading.text, characterOffset: offset))
            }
        }
        headings.sort { $0.characterOffset < $1.characterOffset }

        // Use first heading as title if available
        let docTitle = headings.first?.text ?? title

        return Chapter(title: docTitle, text: plainText, headings: headings)
    }
}

// MARK: - Plain Text Extractor

private struct PlainTextExtractor: MarkupWalker {
    var includeNavigationHeadings = false
    var result = ""
    var headings: [(level: Int, text: String, offset: Int)] = []
    var navigationHeadings: [(level: Int, text: String, offset: Int)] = []
    private var utf16Length = 0

    /// Only generated cache/EPUB Markdown opts into navigation annotations.
    init(includeNavigationHeadings: Bool) {
        self.includeNavigationHeadings = includeNavigationHeadings
    }

    /// Track offsets incrementally so books with many headings remain linear
    /// in size, including text containing emoji and combining characters.
    private mutating func append(_ text: String) {
        result += text
        utf16Length += text.utf16.count
    }

    /// Separate block elements while preserving the extractor's existing
    /// paragraph convention for navigation and speech pauses.
    private mutating func separateBlock() {
        if !result.isEmpty && !result.hasSuffix("\n\n") {
            append("\n\n")
        }
    }

    /// Text leaves provide ordinary prose and inline formatting contents.
    mutating func visitText(_ text: Markdown.Text) -> () {
        append(text.string)
    }

    /// Code is a leaf node, so the default walker would silently omit it.
    mutating func visitInlineCode(_ inlineCode: InlineCode) -> () {
        append(inlineCode.code)
    }

    /// Retain fenced and indented code, including its internal line breaks.
    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> () {
        separateBlock()
        append(codeBlock.code)
        separateBlock()
    }

    /// A wrapped Markdown source line is a space in the spoken paragraph.
    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> () {
        append(" ")
    }

    /// Explicit Markdown hard breaks retain a newline.
    mutating func visitLineBreak(_ lineBreak: LineBreak) -> () {
        append("\n")
    }

    /// Preserve paragraph boundaries without exposing Markdown syntax.
    mutating func visitParagraph(_ paragraph: Markdown.Paragraph) -> () {
        separateBlock()
        descendInto(paragraph)
    }

    /// Record the exact text position before walking the heading's children.
    mutating func visitHeading(_ heading: Markdown.Heading) -> () {
        separateBlock()
        headings.append((heading.level, heading.plainText, utf16Length))
        descendInto(heading)
        append("\n\n")
    }

    /// Block annotations precede a chapter or block target; establish the same
    /// paragraph boundary as the following block without adding label text.
    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        guard includeNavigationHeadings,
              let annotation = MarkdownHeadingAnnotation.decode(html.rawHTML) else { return }
        separateBlock()
        navigationHeadings.append((annotation.level, annotation.text, utf16Length))
    }

    /// Inline anchors keep their precise location within the current paragraph.
    mutating func visitInlineHTML(_ html: InlineHTML) {
        guard includeNavigationHeadings,
              let annotation = MarkdownHeadingAnnotation.decode(html.rawHTML) else { return }
        navigationHeadings.append((annotation.level, annotation.text, utf16Length))
    }
}
