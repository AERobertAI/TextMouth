import Foundation

/// Reads plain-text (.txt) books.
///
/// A plain-text book reaches the reader along one of two paths: directly,
/// through `parse(text:title:)` (the fallback when no cache can be written),
/// or through content.md, the Markdown cache written from `markdown(text:)`
/// and read by `MarkdownDocParser`. Both paths are built from one line
/// analysis, `blocks(in:)`, so they agree on every word, every heading, and
/// every heading position a listener meets.
///
/// The reading text keeps every character of the source, in order, except for
/// this whitespace normalization (the one the Markdown cache applies to
/// ordinary lines):
/// - A line ends at each line ending: a CR LF pair, or any one character of
///   `CharacterSet.newlines` (LF, VT, FF, CR, NEL, LS, PS). CR LF and a lone
///   CR first become LF exactly as `TextFileDecoder.normalizingLineEndings(_:)`
///   makes them in a file, so a Windows (CR LF) or classic Mac OS (CR) text
///   reads like its LF copy: one line per source line, a setext underline
///   directly below its heading line.
/// - Each line is trimmed of `CharacterSet.whitespaces` (Unicode space
///   separators, tab, and zero-width space) at both ends. Whitespace inside a
///   line, tabs included, is kept exactly.
/// - Consecutive non-empty lines form a paragraph, read with one space where
///   each line ended. Empty lines separate paragraphs; a run of them is one
///   separation.
/// - Paragraphs and headings are separated by exactly "\n\n", with nothing
///   before the first block or after the last.
///
/// Beyond whitespace, a heading line is read as its heading label: the `#`
/// markers of an ATX-style line and the underline of a setext heading are
/// heading syntax rather than words. U+0000 is read as U+FFFD, the
/// replacement the Markdown reader is required to make.
///
/// Form feeds begin pages (PG13), in content.md only, as every format's
/// pages are: the direct parse reads none, as DOCX's writes none. A form
/// feed still ends a line, so the reading text is the same with pages and
/// without them (`pagedBlocks(in:)`).
enum PlainTextParser {

    /// One unit of a plain-text book's reading structure.
    enum Block: Equatable {
        /// A line the heading heuristics recognized, read as its label.
        case heading(level: Int, text: String)
        /// Consecutive trimmed body lines, read joined by single spaces.
        case paragraph(lines: [String])
    }

    /// Where a page that a form feed begins starts (PG13): before line
    /// `line` of block `block`, a paragraph's line, or line 0 of a block,
    /// which is the block's start (a heading's, or a paragraph's first line).
    struct FormFeedPage: Equatable {
        var block: Int
        var line: Int
    }

    /// The paragraph break between blocks, in both the reading text and the
    /// cached Markdown (where it is a blank line).
    private static let blockSeparator = "\n\n"

    // MARK: - Reading Paths

    /// Parse plain text into a single chapter. Its text and headings are
    /// exactly those `MarkdownDocParser` reads back from `markdown(text:)`.
    static func parse(text: String, title: String = "Untitled") -> DocumentContent {
        let reading = readingContent(of: blocks(in: text))
        let chapter = Chapter(title: title, text: reading.text, headings: reading.headings)

        return DocumentContent(
            title: title,
            author: Book.unknownAuthor,
            chapters: [chapter]
        )
    }

    /// The content.md representation of a plain-text source. Every character
    /// is written as a Markdown literal, so text that merely looks like
    /// Markdown or HTML is read exactly as written. Headings become ATX
    /// headings of their heuristic level; each paragraph line stays its own
    /// Markdown line, whose line break the reader speaks as a space.
    ///
    /// A text whose form feeds begin pages (PG13, `pagedBlocks(in:)`) has a
    /// page marker where each page's first line begins, page 1 at the
    /// book's start and the rest numbered on from it: before the block that
    /// line begins, or at the end of the line before it, after its words,
    /// inside the paragraph (`MarkdownMarkerWriter`). The markers add no
    /// word, and every line and block is as without them.
    /// - Parameter includesPages: whether page markers are written (PG13);
    ///   false writes what cache format 3.0.7 wrote, as does a text whose
    ///   form feeds begin no page.
    static func markdown(text: String, includesPages: Bool = true) -> String {
        guard includesPages else { return markdown(of: blocks(in: text)) }
        let paged = pagedBlocks(in: text)
        return markdown(of: paged.blocks, pages: paged.pages)
    }

    /// The Markdown of `blocks`, each block on its lines, apart by blank lines.
    private static func markdown(of blocks: [Block]) -> String {
        blocks.map { block -> String in
            switch block {
            case let .heading(level, label):
                return headingLine(level: level, label: label)
            case let .paragraph(lines):
                return lines.map(MarkdownLiteral.escaped).joined(separator: "\n")
            }
        }.joined(separator: blockSeparator)
    }

    /// The Markdown of `blocks` with a marker for each of `pages`, and for
    /// page 1 at the start: the markers are labelled 1, 2, 3, and so on, in
    /// order. No pages give exactly `markdown(of:)`.
    private static func markdown(of blocks: [Block], pages: [FormFeedPage]) -> String {
        guard !pages.isEmpty else { return markdown(of: blocks) }
        // Page 1 begins the book; the form feeds' pages follow it.
        let starts = [FormFeedPage(block: 0, line: 0)] + pages
        var markdown = ""
        var next = 0
        /// Writes the marker of every page that begins at `line` of block
        /// `block`: a block of its own at a block's start, and after the
        /// words of the line before it inside a paragraph.
        func writeMarkers(block: Int, line: Int) {
            while next < starts.count, starts[next] == FormFeedPage(block: block, line: line) {
                let marker = MarkdownPageMarker(label: String(next + 1), ordinal: next + 1)
                MarkdownMarkerWriter.write(marker.markdown, inline: line > 0, into: &markdown)
                next += 1
            }
        }
        for (index, block) in blocks.enumerated() {
            writeMarkers(block: index, line: 0)
            MarkdownMarkerWriter.ensureBlankLine(&markdown)
            switch block {
            case let .heading(level, label):
                markdown += headingLine(level: level, label: label)
            case let .paragraph(lines):
                for (lineIndex, line) in lines.enumerated() {
                    if lineIndex > 0 {
                        writeMarkers(block: index, line: lineIndex)
                        markdown += "\n"
                    }
                    markdown += MarkdownLiteral.escaped(line)
                }
            }
        }
        return markdown
    }

    /// A heading's line in content.md: its level's `#` markers and its
    /// label as a Markdown literal.
    private static func headingLine(level: Int, label: String) -> String {
        String(repeating: "#", count: level) + " " + MarkdownLiteral.escaped(label)
    }

    // MARK: - Shared Line Analysis

    /// Divide a plain-text source into headings and paragraphs. This is the
    /// one analysis behind both reading paths.
    ///
    /// Headings follow three heuristics, tried in this order for each line:
    /// 1. ATX style: the line starts with one to six `#` characters and a
    ///    label remains after trimming whitespace and `#` from both ends.
    /// 2. Setext style: a non-empty line directly above an underline of three
    ///    or more `=` (level 1) or `-` (level 2) characters.
    /// 3. A short all-caps line: 3 to 80 characters, unchanged by uppercasing,
    ///    containing letters, at least three of them (level 2).
    /// A line shaped like an underline is never a heading itself. Only the
    /// underline directly below a setext heading is dropped as heading syntax;
    /// any other one, like every other line, is read as written.
    static func blocks(in text: String) -> [Block] {
        analysis(of: text, findingPages: false).blocks
    }

    /// The blocks of `text`, exactly as `blocks(in:)` finds them, and the
    /// pages its form feeds begin (PG13).
    ///
    /// A form feed (U+000C) ends a line, as it always has, and begins a page
    /// at the first line after it that is read: a heading, or a paragraph's
    /// line, but not an empty line, nor the underline a setext heading took.
    /// Several form feeds before the same line begin a page each there, a
    /// blank page kept in its order. A form feed with no words before it
    /// begins no page, being the start of page 1, as a printout's first form
    /// feed often is; nor does one with no words after it, which ends the
    /// last page. Page 1, at the book's start, is not among the pages
    /// returned, and a text with none has no pages at all.
    ///
    /// A book has at most `MarkdownPageMarker.maximumPagesPerBook` pages,
    /// page 1 among them (the review of October 24): past them a form feed
    /// begins no page, though it still ends its line, so the text is
    /// unchanged. Plain text has no size limit, and a text of nothing but
    /// form feeds would otherwise write a page for each, a million pages in
    /// a megabyte, costing half a gigabyte to read.
    static func pagedBlocks(in text: String) -> (blocks: [Block], pages: [FormFeedPage]) {
        analysis(of: text, findingPages: true)
    }

    /// The one line analysis behind `blocks(in:)` and `pagedBlocks(in:)`,
    /// which looks for form feeds only when `findingPages` asks it to.
    private static func analysis(of text: String, findingPages: Bool) -> (blocks: [Block], pages: [FormFeedPage]) {
        // A file's text arrives normalized already; text from anywhere else
        // is normalized the same way, so CR LF never ends two lines.
        let normalized = TextFileDecoder.normalizingLineEndings(text)
        let lines = normalized
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let underlines = Set(lines.indices.filter { isSetextUnderline(lines[$0]) })
        // The lines a form feed begins, in order, when pages are asked for,
        // and the next of them to meet.
        let afterFormFeed = findingPages ? linesAfterFormFeeds(in: normalized) : []
        var nextFormFeed = afterFormFeed.startIndex

        var blocks: [Block] = []
        var paragraph: [String] = []
        // The underline of the setext heading most recently emitted, if any.
        var consumedUnderline: Int?
        var pages: [FormFeedPage] = []
        // The most pages the form feeds may begin: page 1 is one of the
        // pages a book may have.
        let mostPages = MarkdownPageMarker.maximumPagesPerBook - 1
        // The form feeds since the last line read, whose pages begin at the
        // next line read, and whether any line has been read yet.
        var waitingPages = 0
        var readAnyLine = false

        /// Close the paragraph being collected, if it has any lines.
        func endParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(lines: paragraph))
            paragraph = []
        }

        /// Notes that the next line read is line `line` of block `block`: the
        /// pages waiting for it begin there, unless no words came before.
        func noteLineRead(block: Int, line: Int) {
            if readAnyLine, waitingPages > 0, pages.count < mostPages {
                pages += repeatElement(FormFeedPage(block: block, line: line), count: min(waitingPages, mostPages - pages.count))
            }
            waitingPages = 0
            readAnyLine = true
        }

        for (index, line) in lines.enumerated() {
            // A line begins after one form feed at most: the line before it
            // ended at one line ending.
            if nextFormFeed < afterFormFeed.endIndex, afterFormFeed[nextFormFeed] == index {
                waitingPages += 1
                nextFormFeed += 1
            }
            if index == consumedUnderline {
                continue
            }
            if !underlines.contains(index),
               let heading = heading(at: index, in: lines, underlines: underlines) {
                endParagraph()
                noteLineRead(block: blocks.count, line: 0)
                blocks.append(.heading(level: heading.level, text: readable(heading.label)))
                if heading.isUnderlined {
                    consumedUnderline = index + 1
                }
            } else if line.isEmpty {
                endParagraph()
            } else {
                // The paragraph being collected becomes block `blocks.count`.
                noteLineRead(block: blocks.count, line: paragraph.count)
                paragraph.append(readable(line))
            }
        }
        endParagraph()
        // Form feeds still waiting have no words after them: no pages.
        return (blocks, pages)
    }

    /// The indexes of the lines of `text`, as `components(separatedBy:
    /// .newlines)` cuts them, that a form feed begins, in order: each line
    /// after one that a form feed ended (PG13). Every line ending of
    /// `CharacterSet.newlines` is one UTF-16 unit, and a CR LF pair is one LF
    /// in `text` already, so each one counts as the end of one line, as the
    /// cut makes it. Empty for a text without a form feed, found without
    /// counting its lines.
    private static func linesAfterFormFeeds(in text: String) -> [Int] {
        guard text.utf8.contains(0x0C) else { return [] }
        var lines: [Int] = []
        var lineIndex = 0
        for unit in text.utf16 where isLineEnding(unit) {
            lineIndex += 1
            if unit == 0x0C {
                lines.append(lineIndex)
            }
        }
        return lines
    }

    /// Whether the UTF-16 unit `unit` is one of `CharacterSet.newlines`: LF,
    /// VT, FF, CR, NEL, LS, or PS.
    private static func isLineEnding(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x0A...0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }

    /// A line the heading heuristics recognized.
    private struct HeadingLine {
        var level: Int
        var label: String
        /// Whether the next line is this heading's setext underline.
        var isUnderlined: Bool
    }

    /// Apply the heading heuristics to one trimmed line. The rules and their
    /// order are the plain-text heading detection TextMouth has always used,
    /// so existing books keep the same headings.
    private static func heading(at index: Int, in lines: [String], underlines: Set<Int>) -> HeadingLine? {
        let line = lines[index]

        // 1. Markdown-style headings: "#" markers, then a label.
        if line.hasPrefix("#") {
            let level = line.prefix(while: { $0 == "#" }).count
            if level <= 6 {
                let label = String(line.dropFirst(level))
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
                    .trimmingCharacters(in: .whitespaces)
                if !label.isEmpty {
                    return HeadingLine(level: level, label: label, isUnderlined: false)
                }
            }
        }

        // 2. Setext-style: a line followed by === (level 1) or --- (level 2).
        if !line.isEmpty && underlines.contains(index + 1) {
            let level = lines[index + 1].hasPrefix("=") ? 1 : 2
            return HeadingLine(level: level, label: line, isUnderlined: true)
        }

        // 3. Short all-caps lines, likely section headers. A line holding an
        // ASCII small letter never is one, so most prose is turned away
        // here, before its Characters are counted and an uppercase copy is
        // made (PERF23). Uppercasing maps each scalar on its own, and no
        // mapping leaves fewer base characters than it found, so the copy
        // has more base characters than the line, or the same ones in the
        // same places but for that letter's capital: never canonically equal.
        if line.utf8.contains(where: { (0x61...0x7A).contains($0) }) {
            return nil
        }
        if line.count >= 3 && line.count <= 80
            && line.uppercased() == line
            && line.rangeOfCharacter(from: .letters) != nil
            && line.filter({ $0.isLetter }).count >= 3 {
            return HeadingLine(level: 2, label: line, isUnderlined: false)
        }

        return nil
    }

    /// Three or more `=`, or three or more `-`, and nothing else.
    private static func isSetextUnderline(_ line: String) -> Bool {
        line.count >= 3 && (line.allSatisfy({ $0 == "=" }) || line.allSatisfy({ $0 == "-" }))
    }

    /// The Markdown reader replaces U+0000 with U+FFFD, as CommonMark requires,
    /// so the analysis reads it the same way on both paths.
    private static func readable(_ line: String) -> String {
        guard line.unicodeScalars.contains("\u{0}") else { return line }
        return String(String.UnicodeScalarView(line.unicodeScalars.map { $0 == "\u{0}" ? "\u{FFFD}" : $0 }))
    }

    // MARK: - Direct Reading Text

    /// Render blocks as the reading text and headings `MarkdownDocParser`
    /// produces for `markdown(text:)`: blocks joined by "\n\n", paragraph
    /// lines joined by a space, and each heading placed at the UTF-16 offset
    /// where its label begins.
    private static func readingContent(of blocks: [Block]) -> (text: String, headings: [Heading]) {
        var text = ""
        // Counted as text grows, so books with many headings stay linear.
        var utf16Length = 0
        var headings: [Heading] = []

        /// Append a piece of reading text and advance the UTF-16 length.
        func append(_ piece: String) {
            text += piece
            utf16Length += piece.utf16.count
        }

        for block in blocks {
            if !text.isEmpty {
                append(blockSeparator)
            }
            switch block {
            case let .heading(level, label):
                headings.append(Heading(level: level, text: label, characterOffset: utf16Length))
                append(label)
            case let .paragraph(lines):
                append(lines.joined(separator: " "))
            }
        }
        return (text, headings)
    }
}
