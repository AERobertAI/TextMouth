import Foundation

/// A chapter of content.md read as it is written, without parsing it as
/// Markdown: the lines of a chapter that nests quotes, lists, or emphasis
/// past the reader's limit, which an export writes as plain paragraphs of
/// words (`ExportDocumentWalker`, FR24).
///
/// content.md is Markdown written by TextMouth's converters, so its lines are
/// not the words as they are read: every ASCII punctuation mark of an
/// imported book's words has a backslash before it (`MarkdownLiteral.escaped`),
/// U+FEFF is a character reference, and TextMouth's own page and heading
/// markers are HTML comments (`MarkdownMarkerWriter`) at a block's start, at a
/// quote's or list item's opening, at the end of a line, or within a line's
/// words. This undoes exactly that, line by line, and never nests:
///
/// - A **paragraph** is the lines between two blank lines, each line trimmed
///   of the spaces and tabs at its ends and joined to the next by a line feed
///   (a hard break in every writer), so a book whose source lines were
///   hard-wrapped does not come out one paragraph per line.
/// - A **marker** is a complete comment `MarkdownMarker.decode` reads, found
///   anywhere in a line, and is no words. A comment that is no marker of
///   TextMouth's stays as words, as written: a comment ends at its first
///   `-->`, as in CommonMark, so the scan is one pass.
/// - **Words** have each backslash that comes before an ASCII punctuation mark
///   dropped, which is CommonMark's own backslash escape (so right for a
///   Markdown book's lines as well), and `&#xFEFF;`, the one character
///   reference `MarkdownLiteral.escaped` writes, made U+FEFF. No other
///   character reference is decoded: every `&` TextMouth's converters write
///   is escaped (`\&`), so a reference in content.md is TextMouth's own
///   U+FEFF or a hand edit, and decoding the named ones would need a table of
///   two thousand names, which half a table would only make inconsistent.
///
/// The walk of an export keeps the paragraphs, with their markers as places;
/// the reader keeps the words alone (`readingText(of:)`, B16), so a chapter
/// kept raw shows, speaks, and exports as Plain Text without a marker or an
/// escape. That moves the text offsets inside such a chapter. A saved place
/// that has words (every one saved since T06's anchors) is carried by them
/// (`PlaceRelocator`). A place with none, saved by an older build and never
/// given words since, stands at its old numbers at load, and the launch pass
/// then gives it the words that are there in the shorter text: it can land on
/// other words. No offset map is kept for it; a chapter nested past the limit
/// is rare, and such a place in one is rarer.
enum RawChapterLines {

    /// One piece of a paragraph, in the order it is written.
    enum Piece {
        /// Words, with the escapes of content.md undone; may hold line feeds
        /// between the paragraph's lines.
        case words(String)
        /// A marker of TextMouth's own, with no words.
        case marker(MarkdownMarker)
    }

    /// One block of lines.
    struct Paragraph {
        /// The markers that begin the block, before any word: each names a
        /// place between blocks, as the markers that lead an HTML block do.
        var leadingMarkers: [MarkdownMarker]
        /// The rest, which begins with words when there are any; neighbouring
        /// words are one piece, and the block's ends are trimmed.
        var pieces: [Piece]
    }

    // MARK: Paragraphs

    /// The paragraphs of `content`, a chapter of content.md, in order. A line
    /// ends at any newline `Character.isNewline` names (a line feed, a CR LF,
    /// a lone CR, U+0085, U+2028, U+2029), each of which is one line feed in
    /// the words, so no offset moves for it; a line with nothing but spaces and tabs
    /// is blank and ends a paragraph, and a paragraph with no words or markers
    /// is none.
    static func paragraphs(of content: String) -> [Paragraph] {
        var paragraphs: [Paragraph] = []
        // The pieces of each line of the paragraph being read.
        var lines: [[Piece]] = []
        /// Ends the paragraph being read, if it has lines.
        func endParagraph() {
            guard !lines.isEmpty else { return }
            paragraphs.append(paragraph(joining: lines))
            lines = []
        }
        for rawLine in content.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                endParagraph()
            } else {
                lines.append(pieces(ofLine: line))
            }
        }
        endParagraph()
        return paragraphs
    }

    /// The reading text of `content`, a chapter of content.md that nests too
    /// deeply to be parsed, as the reader keeps it (B16): the words of its
    /// paragraphs, with a blank line between one paragraph and the next, and
    /// the markers and the escapes of content.md left out. A paragraph of
    /// markers alone has no words and is no paragraph here; a chapter with
    /// no words at all is empty.
    ///
    /// This is the one reading of a raw chapter's words: the export's walk
    /// (`ExportDocumentWalker`) keeps the same paragraphs, with their markers
    /// as places, and the reader and Plain Text export take these words.
    static func readingText(of content: String) -> String {
        paragraphs(of: content).compactMap { paragraph in
            // Markers carry no words; the pieces' words, in order, are the paragraph.
            let words = paragraph.pieces.reduce(into: "") { text, piece in
                if case let .words(more) = piece { text += more }
            }
            return words.isEmpty ? nil : words
        }.joined(separator: "\n\n")
    }

    /// The pieces of one line, already trimmed of the spaces and tabs at its
    /// ends: its words, unescaped, and its markers, in order, with the white
    /// space a marker leaves at the line's ends trimmed too.
    static func pieces(ofLine line: String) -> [Piece] {
        let scalars = Array(line.unicodeScalars)
        var pieces: [Piece] = []
        // Where the words not yet made a piece begin.
        var wordsStart = 0
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "<", hasPrefix(commentOpening, in: scalars, at: index), !isEscaped(scalars, at: index) else {
                index += 1
                continue
            }
            // A comment ends at its first "-->", marker or not; one with no
            // end leaves the rest of the line as words.
            guard let end = commentEnd(in: scalars, after: index + commentOpening.count) else { break }
            let comment = String(String.UnicodeScalarView(scalars[index..<end]))
            if let marker = MarkdownMarker.decode(comment) {
                if index > wordsStart {
                    pieces.append(.words(unescapedScalars(Array(scalars[wordsStart..<index]))))
                }
                pieces.append(.marker(marker))
                wordsStart = end
            }
            index = end
        }
        if scalars.count > wordsStart {
            pieces.append(.words(unescapedScalars(Array(scalars[wordsStart...]))))
        }
        return trimmingMarkerEdges(of: pieces)
    }

    /// `text` with each backslash before an ASCII punctuation mark dropped, and
    /// `&#xFEFF;` made U+FEFF: what `MarkdownLiteral.escaped` wrote, undone.
    /// One pass; a backslash before anything else is a backslash.
    static func unescaped(_ text: String) -> String {
        unescapedScalars(Array(text.unicodeScalars))
    }

    // MARK: Parts

    /// The opening of an HTML comment.
    private static let commentOpening: [Unicode.Scalar] = ["<", "!", "-", "-"]
    /// The end of an HTML comment.
    private static let commentClosing: [Unicode.Scalar] = ["-", "-", ">"]
    /// The character reference `MarkdownLiteral.escaped` writes for U+FEFF.
    private static let byteOrderMarkReference: [Unicode.Scalar] = Array("&#xFEFF;".unicodeScalars)

    /// Whether `scalars` holds `prefix` at `index`.
    private static func hasPrefix(_ prefix: [Unicode.Scalar], in scalars: [Unicode.Scalar], at index: Int) -> Bool {
        index + prefix.count <= scalars.count && scalars[index..<(index + prefix.count)].elementsEqual(prefix)
    }

    /// Whether the scalar at `index` has an odd number of backslashes right
    /// before it, so that it is escaped and is text, not markup.
    private static func isEscaped(_ scalars: [Unicode.Scalar], at index: Int) -> Bool {
        var count = 0
        var position = index - 1
        while position >= 0, scalars[position] == "\\" {
            count += 1
            position -= 1
        }
        return count % 2 == 1
    }

    /// The index just past the first `-->` that begins at or after `start`;
    /// nil if there is none.
    private static func commentEnd(in scalars: [Unicode.Scalar], after start: Int) -> Int? {
        var position = start
        while position + commentClosing.count <= scalars.count {
            if hasPrefix(commentClosing, in: scalars, at: position) {
                return position + commentClosing.count
            }
            position += 1
        }
        return nil
    }

    /// `scalars` made words, as `unescaped(_:)` makes a string's.
    private static func unescapedScalars(_ scalars: [Unicode.Scalar]) -> String {
        var words = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if scalar == "\\", index + 1 < scalars.count, MarkdownLiteral.isASCIIPunctuation(scalars[index + 1]) {
                words.append(scalars[index + 1])
                index += 2
            } else if scalar == "&", hasPrefix(byteOrderMarkReference, in: scalars, at: index) {
                words.append("\u{FEFF}")
                index += byteOrderMarkReference.count
            } else {
                words.append(scalar)
                index += 1
            }
        }
        return String(words)
    }

    /// `pieces` of one line with the spaces a marker leaves at its ends gone:
    /// the leading ones of the first words, when only markers come before
    /// them, and the trailing ones of the last words, when only markers follow.
    private static func trimmingMarkerEdges(of pieces: [Piece]) -> [Piece] {
        var pieces = pieces
        if let first = pieces.firstIndex(where: { $0.isWords }), pieces[..<first].allSatisfy({ !$0.isWords }),
           case let .words(text) = pieces[first] {
            pieces[first] = .words(String(text.drop(while: { $0 == " " || $0 == "\t" })))
        }
        if let last = pieces.lastIndex(where: { $0.isWords }), case let .words(text) = pieces[last] {
            var trimmed = text
            while let end = trimmed.last, end == " " || end == "\t" { trimmed.removeLast() }
            pieces[last] = .words(trimmed)
        }
        return pieces.filter { piece in
            if case let .words(text) = piece { return !text.isEmpty }
            return true
        }
    }

    /// `pieces` with neighbouring words made one piece. The words are appended
    /// in place to one string and flushed at each marker, so a paragraph of
    /// thousands of lines is joined in one pass, not copied once for every
    /// line (internal, so a test can time it alone).
    static func joiningNeighbouringWords(_ pieces: [Piece]) -> [Piece] {
        var joined: [Piece] = []
        var pendingWords: String?
        for piece in pieces {
            switch piece {
            case let .words(text):
                if pendingWords == nil { pendingWords = text } else { pendingWords?.append(text) }
            case .marker:
                if let words = pendingWords { joined.append(.words(words)) }
                pendingWords = nil
                joined.append(piece)
            }
        }
        if let words = pendingWords { joined.append(.words(words)) }
        return joined
    }

    /// The paragraph whose lines have the pieces `lines`, in order: a line
    /// feed between two lines (none before a line of markers alone, which
    /// names a place and is no line of words), neighbouring words made one
    /// piece, the markers that begin the block set apart, and its ends trimmed.
    private static func paragraph(joining lines: [[Piece]]) -> Paragraph {
        var flat: [Piece] = []
        for line in lines {
            let isMarkersAlone = line.allSatisfy { !$0.isWords }
            if !flat.isEmpty, !isMarkersAlone {
                flat.append(.words("\n"))
            }
            flat += line
        }
        var merged = joiningNeighbouringWords(flat)
        // The markers that begin the block come out, and the white space
        // between them and the words, and at the block's end, goes.
        var leading: [MarkdownMarker] = []
        while case let .marker(marker)? = merged.first {
            leading.append(marker)
            merged.removeFirst()
        }
        if case let .words(text)? = merged.first {
            merged[0] = .words(String(text.drop(while: { $0.isWhitespace })))
        }
        if case let .words(text)? = merged.last {
            var trimmed = text
            while let end = trimmed.last, end.isWhitespace { trimmed.removeLast() }
            merged[merged.count - 1] = .words(trimmed)
        }
        return Paragraph(leadingMarkers: leading, pieces: merged.filter { piece in
            if case let .words(text) = piece { return !text.isEmpty }
            return true
        })
    }
}

private extension RawChapterLines.Piece {
    /// Whether the piece is words.
    var isWords: Bool {
        if case .words = self { return true }
        return false
    }
}
