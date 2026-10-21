/// Writes one line of text whose characters carry emphasis as Markdown that
/// TextMouth's own reader (swift-markdown, through `MarkdownDocParser`)
/// reads back as exactly those characters, with that emphasis: italic as
/// `*…*`, strong as `**…**`, and both as `***…***`. The braille reader
/// writes the emphasis liblouis reports with it (`BrailleBookReader`).
///
/// Emphasis is never spoken. A delimiter CommonMark does not pair is read
/// as an asterisk, so the writer only writes delimiters it will pair:
///
/// - Every character is written as a Markdown literal
///   (`MarkdownLiteral.escaped`), so the text's own asterisks, underscores,
///   and backslashes never turn into formatting.
/// - Each stretch of one style is wrapped on its own, and whatever is not a
///   letter, digit, or mark at either of its ends (white space, punctuation,
///   symbols) is left outside the delimiters, unstyled: "*Titanic*." rather
///   than "*Titanic.*", as `HTMLToMarkdownConverter` writes it. Each
///   delimiter run then touches a letter, digit, or mark on its inner side
///   (`MarkdownLiteral.isFlankingSafe`), so it opens or closes whatever
///   stands on its outer side. A stretch with no letter, digit, or mark at
///   all is written unstyled.
/// - No two stretches' delimiters ever touch. With at least one unstyled
///   character between every two stretches, each closer meets its own
///   opener first, and CommonMark pairs them: one asterisk each (lengths 1
///   and 1), two (2 and 2), or three (3 and 3, which its "multiple of 3"
///   rule allows since both are multiples of 3). Stretches that would touch,
///   a word whose letters change from one emphasis straight to another
///   (bold "a", then both on "b", then italic "c"), are written as one
///   stretch in the emphasis they all share, if any, since runs of
///   delimiters that meet (`**a*****b****c*`) are where CommonMark stops
///   pairing them. Emphasis that changes to or from none within a word
///   ("un*believ*able") is written as it is.
///
/// So the reader's text is the input text, scalar for scalar, no character
/// gains emphasis, and a letter's emphasis is kept but where it changes
/// straight to another inside a word. `MarkdownEmphasisTests` checks that
/// against swift-markdown itself for every mix of styles.
enum MarkdownEmphasis {
    /// The emphasis Markdown holds: emphasis, strong, both, or neither.
    struct Style: OptionSet, Hashable, Sendable {
        let rawValue: UInt8

        /// Emphasis, `*…*`: italic.
        static let emphasis = Style(rawValue: 1)
        /// Strong emphasis, `**…**`: bold.
        static let strong = Style(rawValue: 2)

        /// The delimiter written on each side of a stretch in this style:
        /// one asterisk for emphasis, two for strong, three for both.
        fileprivate var delimiter: String {
            String(repeating: "*", count: (contains(.emphasis) ? 1 : 0) + (contains(.strong) ? 2 : 0))
        }
    }

    /// `text` as one line of Markdown, its Unicode scalars in order, each in
    /// the style at its place in `styles`. `styles` is empty, or holds one
    /// style for each scalar; any other count is taken as no style at all,
    /// and the text is written plain. The caller gives one line, trimmed of
    /// white space at its ends, as `MarkdownLiteral.escaped` asks.
    static func markdown(_ text: String, styles: [Style]) -> String {
        let scalars = Array(text.unicodeScalars)
        guard styles.count == scalars.count, styles.contains(where: { !$0.isEmpty }) else {
            return MarkdownLiteral.escaped(text)
        }
        // Everything between the spans is written as plain literal text.
        var result = ""
        var position = 0
        for span in spans(of: scalars, styles: styles) {
            result += literal(scalars[position..<span.range.lowerBound])
            // A span of touching stretches that share no emphasis has none.
            let delimiter = span.style.delimiter
            result += delimiter + literal(scalars[span.range]) + delimiter
            position = span.range.upperBound
        }
        return result + literal(scalars[position...])
    }

    /// The spans `markdown(_:styles:)` wraps in delimiters, in order: each
    /// stretch of one style but none, trimmed to begin and end with a
    /// letter, digit, or mark (a stretch with none is left out), and
    /// stretches that then touch, with no character between them, made one
    /// span in the style they share.
    private static func spans(of scalars: [Unicode.Scalar], styles: [Style]) -> [(range: Range<Int>, style: Style)] {
        var spans: [(range: Range<Int>, style: Style)] = []
        var start = 0
        while start < scalars.count {
            // The stretch of one style that begins here.
            let style = styles[start]
            var end = start + 1
            while end < scalars.count, styles[end] == style { end += 1 }
            var lower = start
            var upper = end
            while lower < upper, !MarkdownLiteral.isFlankingSafe(scalars[lower]) { lower += 1 }
            while upper > lower, !MarkdownLiteral.isFlankingSafe(scalars[upper - 1]) { upper -= 1 }
            if !style.isEmpty, lower < upper {
                if let last = spans.last, last.range.upperBound == lower {
                    spans[spans.count - 1] = (last.range.lowerBound..<upper, last.style.intersection(style))
                } else {
                    spans.append((lower..<upper, style))
                }
            }
            start = end
        }
        return spans
    }

    /// `scalars` as Markdown literal text.
    private static func literal(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        scalars.isEmpty ? "" : MarkdownLiteral.escaped(String(String.UnicodeScalarView(scalars)))
    }
}
