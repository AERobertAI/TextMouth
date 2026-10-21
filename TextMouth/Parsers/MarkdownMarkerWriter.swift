import Foundation

/// Writes the inert HTML-comment markers of content.md (heading annotations
/// and page markers, PG01) into the Markdown a converter is building, so
/// every converter places them alike and none can delete a paragraph's words
/// from speech.
enum MarkdownMarkerWriter {

    /// Where the next output lands in the Markdown being built.
    enum LinePosition: Equatable {
        /// After visible content on the current line.
        case withinLine
        /// At the start of a line that continues a paragraph (after a hard break).
        case continuationLine
        /// At the start of a new block: the beginning, or after a blank line.
        case blockStart
    }

    /// Classify the end of `markdown` from its last two lines only, so the cost
    /// does not grow with the chapter. Spaces and tabs are indentation, not
    /// content, as in CommonMark. Scalars keep "\r\n" from hiding a newline.
    static func linePosition(of markdown: String) -> LinePosition {
        let scalars = markdown.unicodeScalars
        let isIndentation: (Unicode.Scalar) -> Bool = { $0 == " " || $0 == "\t" }
        guard let lineBreak = scalars.lastIndex(of: "\n") else {
            return scalars.allSatisfy(isIndentation) ? .blockStart : .withinLine
        }
        guard scalars[scalars.index(after: lineBreak)...].allSatisfy(isIndentation) else { return .withinLine }
        let earlierLines = scalars[..<lineBreak]
        let previousLineStart = earlierLines.lastIndex(of: "\n").map { earlierLines.index(after: $0) }
            ?? earlierLines.startIndex
        return earlierLines[previousLineStart...].allSatisfy(isIndentation) ? .blockStart : .continuationLine
    }

    /// Write a marker without changing the words around it. CommonMark
    /// opens an HTML block at any line that begins with "<!--", and that block
    /// swallows the rest of the line: an anchor at the start of a paragraph
    /// used to delete the paragraph's words from speech. A marker therefore
    /// never begins a line. At a block boundary (or when `inline` is false) it
    /// becomes a block of its own, which names the same position as the block
    /// that follows. After a hard line break, four spaces keep it inside the
    /// paragraph, because an HTML block may be indented by at most three and a
    /// continuation line's indentation is not part of its text.
    ///
    /// - Parameters:
    ///   - marker: The complete comment to write.
    ///   - inline: Whether the marker names a place inside running text
    ///     rather than the start of a block.
    ///   - keepingWordsApart: For a source whose page break joined two words
    ///     (a DOCX page `w:br`, textutil's HTML): within a line, a space is
    ///     written first unless the Markdown already ends in whitespace.
    ///   - markdown: The Markdown being built.
    static func write(_ marker: String, inline: Bool, keepingWordsApart: Bool = false, into markdown: inout String) {
        switch inline ? linePosition(of: markdown) : .blockStart {
        case .withinLine:
            // A space is added only when none ends the text already, so a
            // marker never doubles a space the source wrote.
            if keepingWordsApart, let last = markdown.last, !last.isWhitespace {
                markdown += " "
            }
            markdown += marker
        case .continuationLine:
            markdown += "    " + marker
        case .blockStart:
            ensureBlankLine(&markdown)
            markdown += marker + "\n\n"
        }
    }

    /// Ensure `markdown` ends with a blank line (two newlines), unless it is
    /// empty or already does.
    static func ensureBlankLine(_ markdown: inout String) {
        if markdown.isEmpty { return }
        if !markdown.hasSuffix("\n\n") {
            if markdown.hasSuffix("\n") {
                markdown += "\n"
            } else {
                markdown += "\n\n"
            }
        }
    }
}
