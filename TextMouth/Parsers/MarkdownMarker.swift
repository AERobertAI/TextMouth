import Foundation

/// A navigation marker of TextMouth's own that content.md carries as an inert
/// HTML comment: a heading annotation or a page marker (PG01).
///
/// Everything that reads content.md's markers asks this one type, so the
/// reader (`MarkdownDocParser`) and the exporters (`ExportDocumentWalker`)
/// find exactly the same markers in exactly the same places, including a
/// line that holds markers followed by words (ST05).
enum MarkdownMarker {
    /// A heading annotation: a navigation destination that is no heading.
    case heading(MarkdownHeadingAnnotation)
    /// The start of a page.
    case page(MarkdownPageMarker)

    /// The marker a complete comment holds, or nil for any other text.
    static func decode(_ comment: String) -> MarkdownMarker? {
        if let annotation = MarkdownHeadingAnnotation.decode(comment) {
            return .heading(annotation)
        }
        return MarkdownPageMarker.decode(comment).map(MarkdownMarker.page)
    }

    /// The markers of ours that an HTML block begins with, in order, and the
    /// Markdown after them (ST05); nil unless at least one marker is followed
    /// by something other than whitespace.
    ///
    /// CommonMark makes a line that begins with `<!--` an HTML block, the
    /// whole line included, so words that follow a marker on that line belong
    /// to the block. A marker is a comment from `<!--` to its first `-->`;
    /// markers are separated only by spaces or tabs, and the block may be
    /// indented up to three spaces, as CommonMark allows. The markers are
    /// peeled in a loop, never by recursion, so a line of ten thousand of
    /// them cannot deepen the stack.
    static func leading(of rawHTML: String) -> (markers: [MarkdownMarker], rest: Substring)? {
        var rest = Substring(rawHTML)
        // At most three leading spaces precede an HTML block's first character.
        var indent = 0
        while indent < 3, rest.first == " " {
            rest = rest.dropFirst()
            indent += 1
        }
        var markers: [MarkdownMarker] = []
        while rest.hasPrefix("<!--"), let close = rest.firstRange(of: "-->"),
              let found = decode(String(rest[..<close.upperBound])) {
            markers.append(found)
            rest = rest[close.upperBound...].drop(while: { $0 == " " || $0 == "\t" })
        }
        guard !markers.isEmpty, rest.contains(where: { !$0.isWhitespace }) else { return nil }
        return (markers, rest)
    }
}
