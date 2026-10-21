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
        /// At the start of a line that continues a paragraph (after a line
        /// break).
        case continuationLine
        /// At the start of a new block: the beginning, after a blank line, or
        /// after a line no paragraph continues (a heading, a thematic break
        /// or setext underline, a code fence, or a list item's marker alone).
        case blockStart
        /// After the opening of a list item or block quote ("- ", "1. ", "> ",
        /// "> - "), before any of its words, also when a line of whitespace
        /// follows the opening. `continuation` begins the container's next
        /// line: the opening's quote markers, and spaces for the rest.
        case containerStart(continuation: String)
        /// After the opening of a heading line ("## ") whose words have not
        /// begun, followed by a line of whitespace.
        case headingStart
    }

    /// Classify the end of `markdown` from its last two lines only, so the cost
    /// does not grow with the chapter. Spaces and tabs are indentation, not
    /// content, as in CommonMark. Scalars keep "\r\n" from hiding a newline.
    static func linePosition(of markdown: String) -> LinePosition {
        placement(atEndOf: markdown).position
    }

    /// Write a marker without changing the words around it. CommonMark
    /// opens an HTML block at any line whose content begins with "<!--", in
    /// a list item or block quote too, and that block swallows the rest of
    /// the line: an anchor at the start of a paragraph used to delete the
    /// paragraph's words from speech. A marker therefore never begins a
    /// line's content where words follow it:
    /// - Inside running text it is written where it stands.
    /// - At a block boundary (or when `inline` is false) it is a block of its
    ///   own, which names the same position as the block that follows.
    /// - At the opening of a list item or quote, before its words, it is a
    ///   block of its own inside the item or quote, and the words go on in it
    ///   on the next line; at the opening of a heading it is written in the
    ///   heading.
    /// - After a line break it is written at the end of the line before, after
    ///   its words: inline in every container, where four spaces before it on
    ///   its own line would be too few in a list item. The page still begins
    ///   at the next word, since a page that begins in whitespace begins at
    ///   the word after it (`PageBreak.firstWordStart`).
    ///
    /// - Parameters:
    ///   - marker: The complete comment to write.
    ///   - inline: Whether the marker names a place inside running text
    ///     rather than the start of a block.
    ///   - keepingWordsApart: For a source whose page break joined two words
    ///     (a DOCX page `w:br`, textutil's HTML): within a line, a space is
    ///     written beside the marker unless the words are apart already
    ///     (`spaceSide(keepingWordsApartAfter:in:)`).
    ///   - indentation: Written before a marker that is a block of its own, so
    ///     that it stays in the list item holding the list being written (a
    ///     DAISY list's items keep theirs); none for any other converter.
    ///   - markdown: The Markdown being built.
    static func write(
        _ marker: String,
        inline: Bool,
        keepingWordsApart: Bool = false,
        indentation: String = "",
        into markdown: inout String
    ) {
        let place = inline
            ? placement(atEndOf: markdown)
            : Placement(position: .blockStart, index: markdown.endIndex)
        switch place.position {
        case .withinLine:
            // A space is added only when the words are not apart already, so
            // a marker never doubles a space the source wrote.
            let space = keepingWordsApart
                ? spaceSide(keepingWordsApartAfter: markdown.unicodeScalars[place.index...], in: markdown)
                : nil
            if space == .before { markdown += " " }
            markdown += marker
            if space == .after { markdown += " " }
        case .continuationLine:
            markdown.unicodeScalars.insert(contentsOf: marker.unicodeScalars, at: place.index)
        case .containerStart(let continuation):
            // The opening keeps one space after its last marker, so the
            // whitespace a source wrote after it cannot make the marker code.
            markdown.unicodeScalars.removeSubrange(place.index...)
            markdown += " " + marker + "\n" + continuation
        case .headingStart:
            markdown.unicodeScalars.removeSubrange(place.index...)
            markdown += " " + marker
        case .blockStart:
            ensureBlankLine(&markdown)
            markdown += indentation + marker + "\n\n"
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

    // MARK: - Finding the Place

    /// Where a marker goes at the end of the Markdown: its position, and the
    /// index `write` works at, in the Markdown's Unicode scalars. For
    /// `withinLine` the index is where the last line's words begin; for
    /// `continuationLine` where the words of the line before it end; for
    /// `containerStart` and `headingStart` the end of the opening, after
    /// which everything (whitespace only) is replaced; for `blockStart` the
    /// end.
    fileprivate struct Placement {
        let position: LinePosition
        let index: String.Index
    }

    /// The place of a marker written inline at the end of `markdown`, from its
    /// last two lines.
    private static func placement(atEndOf markdown: String) -> Placement {
        let scalars = markdown.unicodeScalars
        let lastStart = scalars.lastIndex(of: "\n").map { scalars.index(after: $0) } ?? scalars.startIndex
        let last = Line(scalars[lastStart...])
        if !last.words.isEmpty {
            return Placement(position: .withinLine, index: last.wordsStart)
        }
        if last.opensContainer {
            return last.containerStart
        }

        // The last line is blank: what comes before it decides.
        guard lastStart > scalars.startIndex else {
            return Placement(position: .blockStart, index: scalars.endIndex)
        }
        let previousEnd = scalars.index(before: lastStart)
        let previousStart = scalars[..<previousEnd].lastIndex(of: "\n").map { scalars.index(after: $0) }
            ?? scalars.startIndex
        let previous = Line(scalars[previousStart..<previousEnd])
        if previous.words.isEmpty {
            // An opening followed by a line of whitespace has no words yet
            // either; after a blank line a new block begins.
            return previous.opensContainer
                ? previous.containerStart
                : Placement(position: .blockStart, index: scalars.endIndex)
        }
        if let headingEnd = previous.headingOpeningEnd {
            return Placement(position: .headingStart, index: headingEnd)
        }
        guard !previous.endsParagraph, let wordsEnd = previous.wordsEnd else {
            return Placement(position: .blockStart, index: scalars.endIndex)
        }
        return Placement(position: .continuationLine, index: wordsEnd)
    }

    /// Which side of a marker the one space that keeps two words apart goes.
    private enum Space {
        case before
        case after
    }

    /// Where a page that joined two words writes the one space that stands
    /// for the break between them, beside its marker written after `words`,
    /// the last line's words: nowhere when whitespace already ends the
    /// Markdown, and before the marker as a rule. After it when the words
    /// are only a list item's or heading's marker ("*", "1.", "##") or only
    /// emphasis delimiters, as an italic "Roses" whose line break is inside
    /// the emphasis leaves them ("*Roses\n*"): a space before the marker
    /// would complete a list item's marker ("* <!--"), whose first line the
    /// marker would then turn into raw HTML, or a heading's.
    private static func spaceSide(keepingWordsApartAfter words: Substring.UnicodeScalarView, in markdown: String) -> Space? {
        guard let last = markdown.last, !last.isWhitespace else { return nil }
        let isDelimiter: (Unicode.Scalar) -> Bool = { "*_~".unicodeScalars.contains($0) }
        return Line.isMarkerAlone(words) || words.allSatisfy(isDelimiter) ? .after : .before
    }
}

// MARK: - Lines

extension MarkdownMarkerWriter {
    /// One line of the Markdown, split where its words begin: first its
    /// openings, the indentation, block quote markers, and list item markers
    /// (each with the whitespace after it) that begin or continue a
    /// container, then its words.
    fileprivate struct Line {
        /// The line, without its line feed.
        let scalars: Substring.UnicodeScalarView
        /// Where the openings end and the words begin.
        let wordsStart: String.Index
        /// Whether the openings hold a block quote or list item marker, rather
        /// than only indentation.
        let opensContainer: Bool

        /// The line's words: everything after its openings.
        var words: Substring.UnicodeScalarView { scalars[wordsStart...] }

        init(_ scalars: Substring.UnicodeScalarView) {
            self.scalars = scalars
            var index = scalars.startIndex
            var opensContainer = false
            while true {
                // The indentation before an opening, or before the words.
                index = scalars[index...].firstIndex { !Self.isIndentation($0) } ?? scalars.endIndex
                guard index < scalars.endIndex else { break }
                if scalars[index] == ">" {
                    // A quote marker, with the one space it may have.
                    index = scalars.index(after: index)
                    if index < scalars.endIndex, Self.isIndentation(scalars[index]) {
                        index = scalars.index(after: index)
                    }
                } else if let markerEnd = Self.listMarkerEnd(in: scalars, at: index),
                          markerEnd < scalars.endIndex, Self.isIndentation(scalars[markerEnd]) {
                    // A list item marker opens an item only with whitespace after it.
                    index = markerEnd
                } else {
                    break
                }
                opensContainer = true
            }
            wordsStart = index
            self.opensContainer = opensContainer
        }

        /// The place of a marker at this line's opening, before its words:
        /// the end of the opening without the whitespace after it, and the
        /// line that continues the container.
        var containerStart: Placement {
            let openingEnd = scalars[..<wordsStart].lastIndex { !Self.isIndentation($0) }
                .map { scalars.index(after: $0) } ?? scalars.startIndex
            // Quote markers and whitespace stay; every list marker becomes
            // spaces, so the next line begins where the item's words do.
            var continuation = String.UnicodeScalarView()
            for scalar in scalars[..<openingEnd] {
                continuation.append(scalar == ">" || Self.isIndentation(scalar) ? scalar : " ")
            }
            continuation.append(" ")
            return Placement(position: .containerStart(continuation: String(continuation)), index: openingEnd)
        }

        /// Where a heading's opening ends ("##" of "## "), when the words are
        /// only that opening: a heading whose words have not begun.
        var headingOpeningEnd: String.Index? {
            let hashes = words.prefix { $0 == "#" }
            guard (1...6).contains(hashes.count),
                  words[hashes.endIndex...].allSatisfy(Self.isIndentation) else { return nil }
            return hashes.endIndex
        }

        /// Where the words end for a marker written after them: before the
        /// whitespace and backslashes that end the line, so a hard break
        /// ("  " or "\" before the line feed) stays one. Nil when nothing
        /// else is there.
        var wordsEnd: String.Index? {
            words.lastIndex { !Self.isIndentation($0) && $0 != "\\" }.map { scalars.index(after: $0) }
        }

        /// Whether no paragraph continues this line: an ATX heading, a setext
        /// underline or thematic break, a code fence, or a list item's marker
        /// alone, after which a line of four spaces would begin code.
        var endsParagraph: Bool {
            let hashes = words.prefix { $0 == "#" }
            let afterHashes = words[hashes.endIndex...]
            if (1...6).contains(hashes.count), afterHashes.first.map(Self.isIndentation) ?? true {
                return true
            }
            let marks = words.filter { !Self.isIndentation($0) }
            if let mark = marks.first, marks.allSatisfy({ $0 == mark }) {
                // "===" or "---" under a line (of any length), or a thematic
                // break of three or more "*", "-", or "_".
                if mark == "=" || mark == "-" { return true }
                if (mark == "*" || mark == "_"), marks.count >= 3 { return true }
            }
            return words.starts(with: "```".unicodeScalars) || words.starts(with: "~~~".unicodeScalars)
                || Self.isMarkerAlone(words)
        }

        /// Whether `words` are a list item's or a heading's marker alone, with
        /// nothing after it: "-", "*", "+", "1." or "1)" (up to nine digits),
        /// or one to six "#".
        static func isMarkerAlone(_ words: Substring.UnicodeScalarView) -> Bool {
            guard !words.isEmpty else { return false }
            if words.allSatisfy({ $0 == "#" }) { return words.count <= 6 }
            return listMarkerEnd(in: words, at: words.startIndex) == words.endIndex
        }

        /// The end of the list item marker at `index` of `scalars`: a bullet
        /// ("-", "*", "+"), or one to nine digits and "." or ")"; nil when
        /// none begins there.
        static func listMarkerEnd(in scalars: Substring.UnicodeScalarView, at index: String.Index) -> String.Index? {
            guard index < scalars.endIndex else { return nil }
            if "-*+".unicodeScalars.contains(scalars[index]) {
                return scalars.index(after: index)
            }
            let digits = scalars[index...].prefix { ("0"..."9").contains($0) }
            guard (1...9).contains(digits.count), digits.endIndex < scalars.endIndex,
                  scalars[digits.endIndex] == "." || scalars[digits.endIndex] == ")" else { return nil }
            return scalars.index(after: digits.endIndex)
        }

        /// Whether `scalar` is indentation: a space or a tab, as in CommonMark.
        static func isIndentation(_ scalar: Unicode.Scalar) -> Bool {
            scalar == " " || scalar == "\t"
        }
    }
}
