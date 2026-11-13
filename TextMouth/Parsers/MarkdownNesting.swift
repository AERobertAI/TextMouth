import Foundation

/// The first layer of the guard on Markdown's nesting: one pass over the bytes
/// of a Markdown text, as linear as reading them, that finds how deep its block
/// quotes and lists can nest, before any parser builds a tree of them.
///
/// Markdown is untrusted input like any markup: a text of five thousand `>`
/// marks is five thousand nested quotes, and the parser, the walk that reads
/// the tree, and the release of the tree each call themselves once for every
/// level. The HTML path refuses nesting past a limit with a sentence
/// (`MarkupGuard`); `MarkdownDocParser.parseChapter` does the same for Markdown
/// with this count, and runs the parse and the walk on `MarkupGuard.onLargeStack`.
///
/// The count is **never less than the tree's real depth in block containers**,
/// and is allowed to be more, since a refusal of a text that nests plausibly is
/// better than a crash, and no real text nests near the limit (the deepest real
/// book nests 12 levels). A line's depth is what its leading run of tokens opens:
///
/// - each `>` opens a block quote;
/// - each list marker (`-`, `+`, `*`, or digits then `.` or `)`, each followed by
///   a space, a tab, or the end of the line) opens a list item, and a marker
///   after another on the same line (`- - - x`) opens a list inside it;
/// - a list inside another is indented at least as far as the outer list's
///   content, which is two columns at the least, so each two columns of the
///   white space before a quote or a marker count as one more level (a tab as
///   four columns). The space after a `>` and the white space after a list
///   marker belong to the marker and are not counted.
///
/// A line made only of one repeated `-` or `*` marker, three or more, is a
/// thematic break (`* * *`), which opens nothing, and its markers are not counted.
/// Lines inside code fences are counted like any other: counting them can only
/// refuse more, never less.
enum MarkdownNesting {

    /// How deep the containers of `markdown` can nest, by the count above; the
    /// pass stops, and returns what it has found, as soon as that is more than
    /// `limit`, so a refusal costs no more than the lines before it.
    /// - Parameters:
    ///   - markdown: The text to count.
    ///   - limit: The depth the caller refuses past; the count is exact up to it.
    static func deepest(in markdown: String, stopAbove limit: Int) -> Int {
        var text = markdown
        // `withUTF8` makes the bytes contiguous, if they are not, once.
        return text.withUTF8 { deepest(in: $0, stopAbove: limit) }
    }

    /// Whether `markdown` nests its containers more than `limit` levels deep.
    static func isDeeper(_ markdown: String, than limit: Int) -> Bool {
        deepest(in: markdown, stopAbove: limit) > limit
    }

    // MARK: The pass

    /// Bytes the pass tells apart.
    private enum Byte {
        static let tab = UInt8(ascii: "\t")
        static let lineFeed = UInt8(ascii: "\n")
        static let carriageReturn = UInt8(ascii: "\r")
        static let space = UInt8(ascii: " ")
        static let quote = UInt8(ascii: ">")
        static let hyphen = UInt8(ascii: "-")
        static let plus = UInt8(ascii: "+")
        static let asterisk = UInt8(ascii: "*")
        static let period = UInt8(ascii: ".")
        static let parenthesis = UInt8(ascii: ")")
        static let zero = UInt8(ascii: "0")
        static let nine = UInt8(ascii: "9")
    }

    /// The most digits an ordered list's number may have (CommonMark's).
    private static let mostMarkerDigits = 9

    /// The count over contiguous `bytes`, line by line.
    private static func deepest(in bytes: UnsafeBufferPointer<UInt8>, stopAbove limit: Int) -> Int {
        var deepest = 0
        var index = 0
        while index < bytes.count {
            let line = prefix(of: bytes, from: &index)
            deepest = max(deepest, line.depth)
            if deepest > limit { return deepest }
            // The rest of the line holds text, which opens nothing.
            while index < bytes.count, bytes[index] != Byte.lineFeed, bytes[index] != Byte.carriageReturn {
                index += 1
            }
            // Past the line ending; the line feed of a CR LF pair is then an empty line, which opens nothing.
            if index < bytes.count { index += 1 }
        }
        return deepest
    }

    /// What one line's leading tokens open.
    private struct LinePrefix {
        /// Block quotes opened by `>`.
        var quotes = 0
        /// List items opened by markers.
        var markers = 0
        /// Columns of white space before a `>` or a marker, apart from the one
        /// space a `>` takes and the white space after a marker.
        var indentColumns = 0
        /// The one character every marker has so far been, or nil when the
        /// markers differ or there are none: a line of one repeated `-` or `*`
        /// is a thematic break.
        var commonMarker: UInt8?
        /// Whether a marker has been read.
        var hasMarker = false
        /// Whether the line ends after its last token, with no text.
        var endsAfterTokens = false

        /// What the line opens in all: a thematic break opens no list.
        var depth: Int {
            let isThematicBreak = endsAfterTokens && markers >= 3 && commonMarker != nil
            return quotes + (isThematicBreak ? 0 : markers) + indentColumns / 2
        }
    }

    /// Reads the tokens that begin the line at `index`, and leaves `index` at the
    /// first byte that is none of them (text, or the line's end).
    private static func prefix(of bytes: UnsafeBufferPointer<UInt8>, from index: inout Int) -> LinePrefix {
        var line = LinePrefix()
        // White space met since the last token, counted if a token follows.
        var pendingColumns = 0
        // Whether the last token was a `>`, whose one following space is its own.
        var afterQuote = false
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case Byte.space, Byte.tab:
                var columns = byte == Byte.tab ? 4 : 1
                if afterQuote, columns == 1 { columns = 0 }
                afterQuote = false
                pendingColumns += columns
                index += 1
            case Byte.quote:
                line.indentColumns += pendingColumns
                pendingColumns = 0
                line.quotes += 1
                afterQuote = true
                index += 1
            default:
                guard let width = markerWidth(in: bytes, at: index) else {
                    // Text follows, unless the line ends here.
                    line.endsAfterTokens = byte == Byte.lineFeed || byte == Byte.carriageReturn
                    return line
                }
                line.indentColumns += pendingColumns
                pendingColumns = 0
                afterQuote = false
                line.markers += 1
                if !line.hasMarker {
                    line.hasMarker = true
                    line.commonMarker = isThematicCharacter(byte) ? byte : nil
                } else if line.commonMarker != byte {
                    line.commonMarker = nil
                }
                index += width
            }
        }
        // The bytes ran out among tokens and white space.
        line.endsAfterTokens = true
        return line
    }

    /// Whether `byte` is one a thematic break repeats among list markers.
    private static func isThematicCharacter(_ byte: UInt8) -> Bool {
        byte == Byte.hyphen || byte == Byte.asterisk
    }

    /// The number of bytes of the list marker at `index`, or nil when none
    /// begins there: `-`, `+`, or `*`, or up to nine digits and `.` or `)`,
    /// and then a space, a tab, a line ending, or the end of the text.
    private static func markerWidth(in bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Int? {
        var end = index
        let first = bytes[index]
        if first == Byte.hyphen || first == Byte.plus || first == Byte.asterisk {
            end += 1
        } else if first >= Byte.zero, first <= Byte.nine {
            while end < bytes.count, bytes[end] >= Byte.zero, bytes[end] <= Byte.nine { end += 1 }
            guard end - index <= mostMarkerDigits, end < bytes.count,
                  bytes[end] == Byte.period || bytes[end] == Byte.parenthesis else { return nil }
            end += 1
        } else {
            return nil
        }
        // A marker is followed by white space or the line's end.
        guard end == bytes.count || [Byte.space, Byte.tab, Byte.lineFeed, Byte.carriageReturn].contains(bytes[end]) else {
            return nil
        }
        return end - index
    }
}
