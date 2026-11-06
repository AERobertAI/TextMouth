import Foundation

/// Writes one text block's string as inline HTML: its style runs as `strong`
/// and `em`, its links as `a`, its line breaks as `br`, and a named anchor
/// at each place the book's navigation points into it.
///
/// Offsets count Unicode code points, not UTF-16 units and not Characters
/// (KFX-FORMAT-NOTES-2026-11-05.md, part 6.2), so the text is walked as its
/// unicode scalars. Runs may overlap or nest, so the text is cut at every
/// run boundary and each piece carries the emphasis and link of every run
/// over it, which makes the HTML well nested whatever the runs do.
struct KFXInlineText {

    /// The emphasis and link in force over one piece of the text.
    private struct Marks: Equatable {
        var isBold = false
        var isItalic = false
        /// The web address or in-book anchor the piece links to.
        var href: String?
    }

    /// One style run, in code points, clamped to the text.
    private struct Run {
        var range: Range<Int>
        var marks: Marks
    }

    /// The most runs one text block may have. Beyond it the block is written
    /// without emphasis, so a hostile list of runs cannot cost time or memory.
    static let maximumRuns = 2_000

    /// Escapes the characters HTML gives meaning to.
    static func escaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            // A NUL or other control character other than the line and tab
            // characters has no place in a book's words, and breaks HTML.
            case "\u{0}"..."\u{8}", "\u{B}", "\u{C}", "\u{E}"..."\u{1F}": continue
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// The HTML for `text`.
    /// - Parameters:
    ///   - runs: The node's style runs (`$142`), as the book wrote them;
    ///     a run that is not a struct, or lies outside the text, is clamped
    ///     or ignored.
    ///   - anchorAt: The HTML of the anchor to write at each offset, in code
    ///     points, where the book's navigation points into the text.
    ///   - resolveRun: What a run's style and link mean (bold, italic, address).
    static func html(
        of text: String,
        runs: [IonValue],
        anchorAt: [Int: String],
        resolveRun: (IonStruct) -> (isBold: Bool, isItalic: Bool, href: String?)
    ) -> String {
        let scalars = Array(text.unicodeScalars)
        let count = scalars.count

        // The runs that cover at least one code point, clamped to the text.
        var parsed: [Run] = []
        if runs.count <= maximumRuns {
            for run in runs {
                guard let members = run.structValue,
                      let start = members[KFXSymbol.runStart]?.intValue,
                      let length = members[KFXSymbol.runLength]?.intValue,
                      start >= 0, length > 0, start < count else { continue }
                let end = min(count, start + min(length, count))
                let resolved = resolveRun(members)
                guard resolved.isBold || resolved.isItalic || resolved.href != nil else { continue }
                parsed.append(Run(range: start..<end, marks: Marks(isBold: resolved.isBold, isItalic: resolved.isItalic, href: resolved.href)))
            }
        }

        // Every offset where something changes: a run starts or ends, or an
        // anchor stands. The text is cut at these.
        var cuts: Set<Int> = [0, count]
        for run in parsed { cuts.insert(run.range.lowerBound); cuts.insert(run.range.upperBound) }
        for offset in anchorAt.keys where offset > 0 && offset < count { cuts.insert(offset) }
        let boundaries = cuts.sorted()

        var html = ""
        var open = Marks()
        // The anchor at the very end of the text, and any beyond it, closes the block.
        for (index, start) in boundaries.enumerated() {
            if let anchor = anchorAt[start] {
                // An anchor stands outside any emphasis, between pieces.
                close(&open, into: &html)
                html += anchor
            }
            guard index + 1 < boundaries.count else { break }
            let end = boundaries[index + 1]
            let current = marks(over: start, in: parsed)
            transition(from: &open, to: current, into: &html)
            html += piece(scalars[start..<end])
        }
        close(&open, into: &html)
        // Anchors past the end of the text stand at its end.
        for (offset, anchor) in anchorAt.sorted(by: { $0.key < $1.key }) where offset > count {
            html += anchor
        }
        return html
    }

    /// The marks in force at `offset`: every run over it adds to them.
    private static func marks(over offset: Int, in runs: [Run]) -> Marks {
        var marks = Marks()
        for run in runs where run.range.contains(offset) {
            marks.isBold = marks.isBold || run.marks.isBold
            marks.isItalic = marks.isItalic || run.marks.isItalic
            // The first link over the piece names it.
            if marks.href == nil { marks.href = run.marks.href }
        }
        return marks
    }

    /// Closes what is open and opens what `marks` asks for. Changing from
    /// one set of marks to another closes and reopens, which keeps the HTML
    /// well nested; adjacent pieces with the same marks stay in one element.
    private static func transition(from open: inout Marks, to marks: Marks, into html: inout String) {
        guard open != marks else { return }
        close(&open, into: &html)
        if let href = marks.href { html += "<a href=\"\(escaped(href))\">" }
        if marks.isBold { html += "<strong>" }
        if marks.isItalic { html += "<em>" }
        open = marks
    }

    /// Closes the elements `open` names, innermost first.
    private static func close(_ open: inout Marks, into html: inout String) {
        if open.isItalic { html += "</em>" }
        if open.isBold { html += "</strong>" }
        if open.href != nil { html += "</a>" }
        open = Marks()
    }

    /// The HTML of a piece of text: escaped, with each line feed a line break.
    private static func piece(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return escaped(String(view)).replacingOccurrences(of: "\n", with: "<br/>")
    }
}
