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
        /// or setext underline, a code fence, or a list item's marker alone),
        /// or one that may be code (`Line.mayBeCode`).
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
    /// - None of these is written on a line indented four columns or more
    ///   before its first opening or word, which may be code in a list the
    ///   source's whitespace broke apart (a DTBook's item holding a
    ///   paragraph): the marker is a block of its own there, at the margin,
    ///   where nothing can make it code.
    ///
    /// - Parameters:
    ///   - marker: The complete comment to write.
    ///   - inline: Whether the marker names a place inside running text
    ///     rather than the start of a block.
    ///   - keepingWordsApart: For a source whose page break joined two words
    ///     (a DOCX page `w:br`, textutil's HTML): within a line, a space is
    ///     written beside the marker unless the words are apart already
    ///     (`spaceSide(keepingWordsApartAfter:in:)`).
    ///   - continuationAtMargin: Whether the caller writes each line of a
    ///     block at that block's own margin and indents it there itself, as
    ///     the HTML converter does, converting a list item's or quote's
    ///     content apart from its opening. The marker is then placed by
    ///     indentation alone, as every marker was before list items, quotes,
    ///     and headings were read, and one after a line break begins its line
    ///     with four spaces, which keep it in the paragraph there. So the HTML
    ///     converter's heading annotations stay byte for byte where cache
    ///     format 3.0.7 wrote them, since their places are exact, never moved
    ///     to a word as a page's is. False for a caller whose Markdown may end
    ///     in a container's opening, or become a list item's after the marker
    ///     is placed (DAISY writes the source's openings and whitespace, DOCX a
    ///     paragraph's text before its list marker): the marker is placed as
    ///     described above.
    ///   - markdown: The Markdown being built.
    static func write(
        _ marker: String,
        inline: Bool,
        keepingWordsApart: Bool = false,
        continuationAtMargin: Bool = false,
        into markdown: inout String
    ) {
        var forgotten = RunMemo()
        write(
            marker, inline: inline, keepingWordsApart: keepingWordsApart,
            continuationAtMargin: continuationAtMargin, remembering: &forgotten, into: &markdown)
    }

    /// What a caller that writes many markers in a row keeps between its
    /// writes (`write(_:inline:keepingWordsApart:continuationAtMargin:remembering:into:)`):
    /// where the last marker went, when it went at the end of the line before
    /// a blank last line, and the Markdown's length after it.
    struct RunMemo {
        /// The Markdown's length in UTF-8 bytes right after the write that made
        /// this memo; -1 when there is nothing to remember.
        fileprivate var length = -1
        /// The UTF-8 offset just after the marker that write inserted, where the
        /// next marker of the run goes.
        fileprivate var offset = 0
        /// The marker inserted, to check the place before it is used.
        fileprivate var marker = ""
        fileprivate var keepingWordsApart = false

        /// A memo with nothing remembered: the first marker is placed from the line.
        init() {}
    }

    /// `write(_:inline:keepingWordsApart:continuationAtMargin:into:)` for a
    /// caller that writes many markers one after another, remembering the last
    /// in `memo`. A marker written after a line break goes at the end of the
    /// line before, whose words and openings the writer reads to place it,
    /// from the line's start: on a line of megabytes that is the whole line,
    /// for every marker of the run (5,000 markers after a 2 MB line took 15.7
    /// s). While nothing else has been written, the next marker goes just
    /// after the last: inserting a comment at the end of a line's words changes
    /// nothing the placement reads (the line's openings, indentation, heading
    /// opening, and whether it ends its paragraph depend on how it begins and
    /// on its whole being one repeated mark or a fence, none of which a
    /// comment of letters can change), and the words end after the comment.
    /// So the marker is inserted there, and the memo moves on. Anything
    /// written since (the Markdown's length is not the memo's) or any other
    /// kind of write is placed from the line, as ever, and forgets the memo.
    static func write(
        _ marker: String,
        inline: Bool,
        keepingWordsApart: Bool = false,
        continuationAtMargin: Bool = false,
        remembering memo: inout RunMemo,
        into markdown: inout String
    ) {
        if inline, !continuationAtMargin, memo.length >= 0, memo.length == markdown.utf8.count, isRememberable(marker),
           memo.keepingWordsApart == keepingWordsApart, memo.offset >= memo.marker.utf8.count,
           memo.offset <= memo.length, endsWithMemoMarker(markdown, memo) {
            let at = markdown.utf8.index(markdown.utf8.startIndex, offsetBy: memo.offset)
            markdown.unicodeScalars.insert(contentsOf: marker.unicodeScalars, at: at)
            memo.length = markdown.utf8.count
            memo.offset += marker.utf8.count
            memo.marker = marker
            return
        }
        memo = RunMemo()
        let place = inline
            ? placement(atEndOf: markdown, continuationAtMargin: continuationAtMargin)
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
        case .continuationLine where continuationAtMargin:
            markdown += "    " + marker
        case .continuationLine:
            let offset = markdown.utf8.distance(from: markdown.utf8.startIndex, to: place.index)
            markdown.unicodeScalars.insert(contentsOf: marker.unicodeScalars, at: place.index)
            // The next marker of a run goes just after this one, when the
            // marker holds a scalar only words hold (a comment does), so the
            // line cannot become a marker alone or an underline, and ends in
            // a scalar that the words end with.
            if isRememberable(marker) {
                memo.length = markdown.utf8.count
                memo.offset = offset + marker.utf8.count
                memo.marker = marker
                memo.keepingWordsApart = keepingWordsApart
            }
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
            markdown += marker + "\n\n"
        }
    }

    /// Whether a run of markers can go on after `marker` without the line being
    /// read again: it holds a scalar only words hold (a comment does), so the
    /// line cannot become a marker alone or an underline, and ends in a scalar
    /// that the line's words end with (not indentation or a backslash, which
    /// a hard break leaves out of the words).
    private static func isRememberable(_ marker: String) -> Bool {
        guard let last = marker.unicodeScalars.last, !Line.isIndentation(last), last != "\\" else { return false }
        return marker.unicodeScalars.contains(where: provesWords)
    }

    /// Whether the Markdown holds the memo's marker just before the memo's
    /// offset, as the memo says.
    private static func endsWithMemoMarker(_ markdown: String, _ memo: RunMemo) -> Bool {
        let bytes = markdown.utf8
        let end = bytes.index(bytes.startIndex, offsetBy: memo.offset)
        let start = bytes.index(end, offsetBy: -memo.marker.utf8.count)
        return bytes[start..<end].elementsEqual(memo.marker.utf8)
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
    /// `withinLine` the index is where the last line's words begin, or, when
    /// the scan back from the end met a scalar that only a word holds before
    /// it met the line's start (`scanBackFromEnd`), that scalar, which words
    /// begin at or before; for
    /// `continuationLine` where the words of the line before it end, or the
    /// end when the marker begins its own line (`continuationAtMargin`); for
    /// `containerStart` and `headingStart` the end of the opening, after
    /// which everything (whitespace only) is replaced; for `blockStart` the
    /// end.
    fileprivate struct Placement {
        let position: LinePosition
        let index: String.Index
    }

    /// The place of a marker written inline at the end of `markdown`, from its
    /// last two lines. With `continuationAtMargin`, by indentation alone:
    /// within a line that holds anything but indentation, at the start of a
    /// line after one that does, and at a block's start after a blank line
    /// or at the beginning.
    private static func placement(atEndOf markdown: String, continuationAtMargin: Bool = false) -> Placement {
        let scalars = markdown.unicodeScalars
        let lastStart: String.Index
        switch scanBackFromEnd(of: scalars) {
        case .wordsProved(at: let wordScalar):
            // The last line holds words, wherever it begins: a long line is
            // not walked to its start for every marker written in it.
            return Placement(position: .withinLine, index: wordScalar)
        case .lineStart(let start):
            lastStart = start
        }
        let last = Line(scalars[lastStart...])
        if !last.words.isEmpty || (continuationAtMargin && last.opensContainer) {
            return Placement(position: .withinLine, index: last.wordsStart)
        }
        if last.opensContainer {
            return last.mayBeCode ? Placement(position: .blockStart, index: scalars.endIndex) : last.containerStart
        }

        // The last line is blank: what comes before it decides.
        guard lastStart > scalars.startIndex else {
            return Placement(position: .blockStart, index: scalars.endIndex)
        }
        let previousEnd = scalars.index(before: lastStart)
        let previousStart = startOfLine(endingAt: previousEnd, in: markdown)
        let previous = Line(scalars[previousStart..<previousEnd])
        if previous.words.isEmpty && !previous.opensContainer {
            // After a blank line a new block begins.
            return Placement(position: .blockStart, index: scalars.endIndex)
        }
        if continuationAtMargin {
            return Placement(position: .continuationLine, index: scalars.endIndex)
        }
        guard !previous.mayBeCode else {
            return Placement(position: .blockStart, index: scalars.endIndex)
        }
        if previous.words.isEmpty {
            // An opening followed by a line of whitespace has no words yet
            // either.
            return previous.containerStart
        }
        if let headingEnd = previous.headingOpeningEnd {
            return Placement(position: .headingStart, index: headingEnd)
        }
        guard !previous.endsParagraph, let wordsEnd = previous.wordsEnd else {
            return Placement(position: .blockStart, index: scalars.endIndex)
        }
        return Placement(position: .continuationLine, index: wordsEnd)
    }

    /// Where the line that ends at `end` begins: just after the last line
    /// feed before `end`, or the start of `markdown`. A line feed is one byte
    /// that no longer scalar holds, so the bytes are searched, which is
    /// several times faster than decoding every scalar of a long line.
    private static func startOfLine(endingAt end: String.Index, in markdown: String) -> String.Index {
        let bytes = markdown.utf8
        guard let lineFeed = bytes[..<end].lastIndex(of: UInt8(ascii: "\n")) else { return markdown.startIndex }
        return bytes.index(after: lineFeed)
    }

    /// What the scan back from the end of the Markdown met first.
    private enum EndScan {
        /// A scalar that only the words of a line can hold, so the last line
        /// has words, and begins before it.
        case wordsProved(at: String.Index)
        /// The start of the last line: just after the last line feed, or the
        /// start of the Markdown.
        case lineStart(String.Index)
    }

    /// Scan back from the end of `scalars` to the first line feed, stopping
    /// early at a scalar that proves the last line holds words
    /// (`provesWords(_:)`). A paragraph of many pages is one line of many
    /// thousands of scalars, and walking it back to its start for every
    /// marker written in it made the whole conversion quadratic (20,000 pages
    /// in 2 MB took 116 s). The marker written last holds letters, so a scan
    /// stops within a marker or the words before it. Only a last line made
    /// wholly of openings, indentation, and marker characters is read to its
    /// start, and nothing is written in such a line until a marker is.
    private static func scanBackFromEnd(of scalars: String.UnicodeScalarView) -> EndScan {
        var index = scalars.endIndex
        while index > scalars.startIndex {
            let before = scalars.index(before: index)
            let scalar = scalars[before]
            if scalar == "\n" { return .lineStart(index) }
            if provesWords(scalar) { return .wordsProved(at: before) }
            index = before
        }
        return .lineStart(scalars.startIndex)
    }

    /// Whether `scalar`, found in a line, proves the line has words, and that
    /// those words are not a list item's or heading's marker alone, nor only
    /// emphasis delimiters (`Line.isMarkerAlone`, `spaceSide`). Every scalar
    /// the openings (`Line.init`) and those markers are made of is left out:
    /// indentation, ">", "-", "*", "+", digits, ".", ")", "#", "_", and "~".
    /// A scalar anywhere else cannot be part of an opening, so the words
    /// begin at or before it.
    private static func provesWords(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case " ", "\t", ">", "-", "*", "+", ".", ")", "#", "_", "~", "0"..."9":
            return false
        default:
            return true
        }
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
        /// The columns of indentation before the first opening or word, a tab
        /// reaching the next multiple of four, as in CommonMark.
        let leadingColumns: Int

        /// The line's words: everything after its openings.
        var words: Substring.UnicodeScalarView { scalars[wordsStart...] }

        /// Whether the line is indented four columns or more before its first
        /// opening or word, so that it is code wherever no container holds it,
        /// as in a list the source's whitespace broke apart: no marker is
        /// written on it, nor after its opening.
        var mayBeCode: Bool { leadingColumns >= 4 }

        init(_ scalars: Substring.UnicodeScalarView) {
            self.scalars = scalars
            var columns = 0
            for scalar in scalars {
                guard Self.isIndentation(scalar) else { break }
                columns += scalar == "\t" ? 4 - columns % 4 : 1
            }
            leadingColumns = columns
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
            // The line's marks (everything but indentation) are all one scalar,
            // counted without building them into an array: the walk ends at
            // the first mark that differs, so an ordinary line costs a step or
            // two however long it is.
            var mark: Unicode.Scalar?
            var markCount = 0
            var allAlike = true
            for scalar in words where !Self.isIndentation(scalar) {
                if let first = mark, scalar != first { allAlike = false; break }
                mark = scalar
                markCount += 1
            }
            if allAlike, let mark {
                // "===" or "---" under a line (of any length), or a thematic
                // break of three or more "*", "-", or "_".
                if mark == "=" || mark == "-" { return true }
                if (mark == "*" || mark == "_"), markCount >= 3 { return true }
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
