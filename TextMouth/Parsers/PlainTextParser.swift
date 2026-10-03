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
enum PlainTextParser {

    /// One unit of a plain-text book's reading structure.
    enum Block: Equatable {
        /// A line the heading heuristics recognized, read as its label.
        case heading(level: Int, text: String)
        /// Consecutive trimmed body lines, read joined by single spaces.
        case paragraph(lines: [String])
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
            author: "Unknown",
            chapters: [chapter]
        )
    }

    /// The content.md representation of a plain-text source. Every character
    /// is written as a Markdown literal, so text that merely looks like
    /// Markdown or HTML is read exactly as written. Headings become ATX
    /// headings of their heuristic level; each paragraph line stays its own
    /// Markdown line, whose line break the reader speaks as a space.
    static func markdown(text: String) -> String {
        blocks(in: text).map { block -> String in
            switch block {
            case let .heading(level, label):
                return String(repeating: "#", count: level) + " " + MarkdownLiteral.escaped(label)
            case let .paragraph(lines):
                return lines.map(MarkdownLiteral.escaped).joined(separator: "\n")
            }
        }.joined(separator: blockSeparator)
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
        // A file's text arrives normalized already; text from anywhere else
        // is normalized the same way, so CR LF never ends two lines.
        let lines = TextFileDecoder.normalizingLineEndings(text)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let underlines = Set(lines.indices.filter { isSetextUnderline(lines[$0]) })

        var blocks: [Block] = []
        var paragraph: [String] = []
        // The underline of the setext heading most recently emitted, if any.
        var consumedUnderline: Int?

        /// Close the paragraph being collected, if it has any lines.
        func endParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(lines: paragraph))
            paragraph = []
        }

        for (index, line) in lines.enumerated() {
            if index == consumedUnderline {
                continue
            }
            if !underlines.contains(index),
               let heading = heading(at: index, in: lines, underlines: underlines) {
                endParagraph()
                blocks.append(.heading(level: heading.level, text: readable(heading.label)))
                if heading.isUnderlined {
                    consumedUnderline = index + 1
                }
            } else if line.isEmpty {
                endParagraph()
            } else {
                paragraph.append(readable(line))
            }
        }
        endParagraph()
        return blocks
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
