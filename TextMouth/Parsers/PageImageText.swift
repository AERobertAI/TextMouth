import CoreGraphics
import Foundation

// MARK: - One Page's Text

/// What text recognition read on one page of a book of pictures (FMT34),
/// with the title the page's chapter takes when the book has several pages.
struct PageImagePageText: Equatable, Sendable {
    /// The title of the page's chapter in a book of several pages ("Page 3",
    /// or a ComicInfo.xml's name for it); a book of one page has no chapters.
    var title: String
    /// The page's paragraphs, each the lines it holds in reading order;
    /// empty for a page on which no text was found.
    var paragraphs: [[String]]

    /// Whether any text was found on the page.
    var hasText: Bool { !paragraphs.isEmpty }
}

// MARK: - Lines into Paragraphs, Pages into Markdown

/// How a picture's recognized lines become the paragraphs of its page, and
/// a book's pages its content.md (FMT34).
///
/// Vision gives lines, not paragraphs. A letter's address, date, greeting,
/// and paragraphs are told apart by the space between them, and a book
/// page's paragraphs by their indented first lines, so a new paragraph
/// begins where either is seen (`paragraphs(of:)`). Each line is written as
/// a line of Markdown, so the reader speaks a line break as a space, and a
/// paragraph break as one.
enum PageImageText {
    /// How far apart two rows must be, measured from the foot of one to the
    /// top of the next, in the page's usual line height, for the second to
    /// begin a paragraph: lines of a paragraph are about a fifth of a line
    /// apart, and a blank line puts more than one line between them.
    static let paragraphGap: CGFloat = 0.75

    /// How much further right than its paragraph's lines a line must begin,
    /// as a share of the picture's width, to begin a paragraph of its own
    /// when the line before it ends a sentence: a book's first-line indent is
    /// a few letters wide, more than the drift of a photographed page's
    /// margin from one line to the next.
    static let paragraphIndent: CGFloat = 0.02

    /// How near in height, as a share of the picture's height, two lines
    /// must be to stand on one row, as the reading order judges it
    /// (`VisionTextRecognition`): a menu's dish and its price.
    static let sameRow: CGFloat = 0.01

    /// The characters a line ends a sentence with, for the indent rule: a
    /// period, an exclamation or question mark, a colon, or a closing quote
    /// after one of those (only the quote itself is looked at).
    private static let sentenceEnds: Set<Character> = [".", "!", "?", ":", "\u{201D}", "\u{2019}", "\"", "'"]

    /// The paragraphs of `lines`, given in reading order: each a run of
    /// lines, trimmed, with empty lines left out. A line begins a new
    /// paragraph when it stands below the line before it by more than
    /// `paragraphGap` of the page's usual line height, or when it begins
    /// more than `paragraphIndent` further right than its paragraph's lines
    /// and the line before it ends a sentence. A line on the same row as the
    /// one before it (`sameRow`) always joins it.
    static func paragraphs(of lines: [RecognizedTextLine]) -> [[String]] {
        let kept = lines.compactMap { line -> RecognizedTextLine? in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : RecognizedTextLine(text: text, normalizedBounds: line.normalizedBounds)
        }
        guard let first = kept.first else { return [] }
        let lineHeight = medianHeight(of: kept)

        var paragraphs: [[String]] = [[first.text]]
        var previous = first
        // The left edge of the paragraph being read: its leftmost line that
        // is not beside another on its row.
        var paragraphLeft = first.normalizedBounds.minX
        for line in kept.dropFirst() {
            let above = previous.normalizedBounds
            let bounds = line.normalizedBounds
            let onSameRow = abs(above.midY - bounds.midY) <= sameRow
            let gap = above.minY - bounds.maxY
            let afterGap = !onSameRow && gap > paragraphGap * lineHeight
            let indented = !onSameRow && bounds.minX - paragraphLeft > paragraphIndent && endsSentence(previous.text)
            if afterGap || indented {
                paragraphs.append([line.text])
                paragraphLeft = bounds.minX
            } else {
                paragraphs[paragraphs.count - 1].append(line.text)
                if !onSameRow { paragraphLeft = min(paragraphLeft, bounds.minX) }
            }
            previous = line
        }
        return paragraphs
    }

    /// The middle of the lines' heights: the page's usual line height, which
    /// a heading or a footnote among them does not move far.
    private static func medianHeight(of lines: [RecognizedTextLine]) -> CGFloat {
        let heights = lines.map(\.normalizedBounds.height).sorted()
        return heights[heights.count / 2]
    }

    /// Whether `line` ends with what ends a sentence (`sentenceEnds`).
    private static func endsSentence(_ line: String) -> Bool {
        line.last.map(sentenceEnds.contains) ?? false
    }

    // MARK: - The Book's Markdown

    /// The content.md of a book of `pages`, in order.
    ///
    /// A book of one page is one chapter, titled by the book: its page's
    /// marker, then its paragraphs. A book of several pages has a chapter for
    /// each page on which text was found, titled by the page; a page without
    /// text has no chapter, and its marker follows the text of the page
    /// before it, or, before the first page with text, precedes that page's
    /// own, so every page can still be gone to by number, as a PDF's pages
    /// without text keep their markers.
    ///
    /// Each line is written for the cache reader to read back exactly as
    /// recognized, with only the backslashes it needs, as a transcript's text
    /// is (`MarkdownLiteral.minimallyEscaped` with smart punctuation, and
    /// `guardingLineStart`), so that a page corrected in Edit Text reads
    /// plainly there.
    /// - Parameter includesPages: whether page markers are written (PG06);
    ///   false writes the text as it is read without pages.
    static func markdown(of pages: [PageImagePageText], includesPages: Bool) -> String {
        /// Writes the marker of page `number` (from 1) into `markdown`.
        func writeMarker(_ number: Int, into markdown: inout String) {
            guard includesPages else { return }
            let marker = MarkdownPageMarker(label: String(number), ordinal: number)
            MarkdownMarkerWriter.write(marker.markdown, inline: false, into: &markdown)
        }
        /// Writes `page`'s paragraphs after what `markdown` holds.
        func writeText(of page: PageImagePageText, into markdown: inout String) {
            MarkdownMarkerWriter.ensureBlankLine(&markdown)
            markdown += page.paragraphs.map { lines in
                lines.map { MarkdownLiteral.guardingLineStart(MarkdownLiteral.minimallyEscaped($0, smartPunctuation: true)) }
                    .joined(separator: "\n")
            }.joined(separator: "\n\n")
        }

        if pages.count == 1, let page = pages.first {
            var markdown = ""
            writeMarker(1, into: &markdown)
            writeText(of: page, into: &markdown)
            return markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var chapters: [String] = []
        // The pages without text before the first page with some.
        var markersBeforeText: [Int] = []
        for (index, page) in pages.enumerated() {
            let number = index + 1
            guard page.hasText else {
                if chapters.isEmpty {
                    markersBeforeText.append(number)
                } else {
                    writeMarker(number, into: &chapters[chapters.count - 1])
                }
                continue
            }
            var body = ""
            for waiting in markersBeforeText + [number] {
                writeMarker(waiting, into: &body)
            }
            markersBeforeText = []
            writeText(of: page, into: &body)
            chapters.append("\(MarkdownCacheService.chapterMarker(title: page.title))\n\(body)")
        }
        // A marker written as a block ends in a blank line of its own, which
        // the blank line between chapters makes enough.
        return chapters.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\n\n")
    }
}
