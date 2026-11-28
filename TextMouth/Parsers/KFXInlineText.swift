import Foundation

/// Writes one text block's string as inline HTML: its style runs as `strong`
/// and `em`, its links as `a`, its line breaks as `br`, a named anchor at
/// each place the book's navigation points into it, and the HTML of the
/// inline nodes (pictures, math, floated spans) that stand among its words.
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

    /// Stands for an inline node in a text that is built from a list of
    /// strings and nodes: a noncharacter, which no book's words hold. The
    /// node counts as one code point, as the book's offsets count it.
    static let placeholder: Unicode.Scalar = Unicode.Scalar(0xFDD0 as UInt32) ?? "\u{FFFD}"

    /// Writes `scalar` as HTML into `out`: the characters HTML gives meaning
    /// to escaped, and the control characters (other than the line and tab
    /// characters, which have no place in a book's words) left out.
    private static func append(_ scalar: Unicode.Scalar, to out: inout String) {
        switch scalar {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "\u{0}"..."\u{8}", "\u{B}", "\u{C}", "\u{E}"..."\u{1F}": break
        default: out.unicodeScalars.append(scalar)
        }
    }

    /// Escapes the characters HTML gives meaning to.
    static func escaped(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars { append(scalar, to: &out) }
        return out
    }

    /// What `html(of:...)` is told of the text it writes.
    struct Context {
        /// The HTML of the anchor to write at each offset, in code points,
        /// where the book's navigation points into the text.
        var anchorAt: [Int: String] = [:]
        /// The HTML of each inline node, in order; the text holds a
        /// `placeholder` for each.
        var inserts: [String] = []
        /// The text to leave out, by its offset and length in code points: a
        /// page's own number that stands where the page begins (the EPUB
        /// reader leaves such a number out as well).
        var skipAt: [Int: Int] = [:]
        /// Emphasis the whole text has, from its node's own style.
        var baseBold = false
        var baseItalic = false
    }

    /// The HTML for `text`.
    /// - Parameters:
    ///   - runs: The node's style runs (`$142`), as the book wrote them;
    ///     a run that is not a struct, or lies outside the text, is clamped
    ///     or ignored.
    ///   - context: Anchors, inline nodes, text to leave out, and base emphasis.
    ///   - resolveRun: What a run's style and link mean (bold, italic, address).
    static func html(
        of text: String,
        runs: [IonValue],
        context: Context = Context(),
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

        // Every offset where something changes: a run starts or ends, an
        // anchor stands, or text is left out. The text is cut at these.
        var cuts: Set<Int> = [0, count]
        for run in parsed { cuts.insert(run.range.lowerBound); cuts.insert(run.range.upperBound) }
        for offset in context.anchorAt.keys where offset > 0 && offset < count { cuts.insert(offset) }
        var skipped: [Range<Int>] = []
        for (offset, length) in context.skipAt where offset >= 0 && length > 0 && offset < count {
            let range = offset..<min(count, offset + min(length, count))
            skipped.append(range)
            cuts.insert(range.lowerBound)
            cuts.insert(range.upperBound)
        }
        let boundaries = cuts.sortedStably()
        // The ranges left out do not overlap in a sound book; sorted, one pass
        // along the boundaries finds the one a piece falls in.
        skipped.sortStably { $0.lowerBound < $1.lowerBound }
        var nextSkipped = 0

        var html = ""
        var open = Marks()
        var nextInsert = 0
        for (index, start) in boundaries.enumerated() {
            if let anchor = context.anchorAt[start] {
                // An anchor stands outside any emphasis, between pieces.
                close(&open, into: &html)
                html += anchor
            }
            guard index + 1 < boundaries.count else { break }
            let end = boundaries[index + 1]
            // An inline node is not left out with the text beside it.
            while nextSkipped < skipped.count, skipped[nextSkipped].upperBound <= start { nextSkipped += 1 }
            if nextSkipped < skipped.count, skipped[nextSkipped].contains(start) { continue }
            var current = marks(over: start, in: parsed)
            current.isBold = current.isBold || context.baseBold
            current.isItalic = current.isItalic || context.baseItalic
            transition(from: &open, to: current, into: &html)
            html += piece(scalars[start..<end], inserts: context.inserts, next: &nextInsert)
        }
        close(&open, into: &html)
        // Anchors past the end of the text stand at its end.
        for (offset, anchor) in context.anchorAt.sortedStably(by: { $0.key < $1.key }) where offset > count {
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

    /// The HTML of a piece of text: escaped, each line feed a line break, and
    /// each placeholder the next inline node's HTML (the nodes come in the
    /// order of the placeholders).
    private static func piece(_ scalars: ArraySlice<Unicode.Scalar>, inserts: [String], next: inout Int) -> String {
        var out = ""
        for scalar in scalars {
            if scalar == placeholder, !inserts.isEmpty {
                if next < inserts.count { out += inserts[next] }
                next += 1
            } else if scalar == "\n" {
                out += "<br/>"
            } else {
                append(scalar, to: &out)
            }
        }
        return out
    }
}
