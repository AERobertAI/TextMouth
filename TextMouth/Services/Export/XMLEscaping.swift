import Foundation

// MARK: - Escaping Text for XML (FMT18)

/// Escapes text for XML, which every writer of XML shares: HTML now, and
/// EPUB and braille's PEF later. A book's text comes from files that are
/// untrusted (content.md from a PDF or a text file can hold a form feed),
/// and one forbidden character, or one `&` left bare, makes a whole page
/// unreadable to an XML parser, so a writer puts nothing into its markup
/// that has not passed through here.
enum XMLEscaping {
    /// `text` made safe for the content of an element: `&` as `&amp;`, `<`
    /// as `&lt;`, and `>` as `&gt;`, and every character XML 1.0 forbids
    /// left out, but for vertical tab and form feed, which are white space
    /// and are each written as a space, so the words they kept apart stay
    /// apart ("page", a form feed, "Start" is "page Start"). Line feeds,
    /// tabs, and carriage returns are kept as they are.
    static func text(_ text: String) -> String {
        escape(text, replacing: textReplacements)
    }

    /// `text` made safe for the value of an attribute written in double
    /// quotes: what `text(_:)` does, `"` as `&quot;`, and tab, line feed,
    /// and carriage return as `&#9;`, `&#10;`, and `&#13;` (a parser would
    /// otherwise read each of them as a space).
    static func attribute(_ text: String) -> String {
        escape(text, replacing: attributeReplacements)
    }

    /// `text` made safe for markup that is read by an HTML or an XML parser,
    /// in element content or in a double-quoted attribute, where a tab or a
    /// line break may stay as it is: what `text(_:)` does, and `"` as
    /// `&quot;`. Not for an attribute whose line breaks must read back
    /// (`attribute(_:)`, which writes them as character references).
    static func markup(_ text: String) -> String {
        escape(text, replacing: markupReplacements)
    }

    /// `text` with only what XML 1.0 forbids dealt with, as `text(_:)` deals
    /// with it, and nothing escaped: for a writer that tidies a name before it
    /// escapes it.
    static func cleaned(_ text: String) -> String {
        escape(text, replacing: [:])
    }

    /// Whether `text` has a character a person can see or hear: one that is
    /// neither white space nor a format character (a zero-width space, joiner,
    /// non-joiner, or byte order mark, which take no room), once the
    /// characters XML forbids are gone. A heading or a name with none is
    /// nothing to a screen reader, and is written as if empty.
    static func hasVisibleText(_ text: String) -> Bool {
        cleaned(text).unicodeScalars.contains { scalar in
            !scalar.properties.isWhitespace && scalar.properties.generalCategory != .format
        }
    }

    // MARK: Private

    /// What `text(_:)` writes in place of the characters it escapes.
    private static let textReplacements: [Unicode.Scalar: String] = [
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
    ]

    /// What `markup(_:)` writes in place of the characters it escapes: those
    /// of `text(_:)` and the quote.
    private static let markupReplacements: [Unicode.Scalar: String] = textReplacements.merging([
        "\"": "&quot;",
    ]) { _, new in new }

    /// What `attribute(_:)` writes in place of the characters it escapes:
    /// those of `text(_:)` and the quote and the three white-space scalars.
    private static let attributeReplacements: [Unicode.Scalar: String] = textReplacements.merging([
        "\"": "&quot;",
        "\t": "&#9;",
        "\n": "&#10;",
        "\r": "&#13;",
    ]) { _, new in new }

    /// Whether XML 1.0 forbids `scalar` in a document: U+0000 to U+0008,
    /// U+000B, U+000C, U+000E to U+001F, U+FFFE, and U+FFFF. (A Swift string
    /// holds no lone surrogate, the only other forbidden values.)
    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0xFFFE, 0xFFFF:
            return true
        default:
            return false
        }
    }

    /// `text` with each scalar in `replacements` written as its
    /// replacement, and each forbidden scalar left out, or written as a
    /// space when it is white space (vertical tab and form feed). It walks scalars,
    /// not characters, because one Character can hold "\r\n" whole, and an
    /// emoji must pass through in one piece.
    private static func escape(_ text: String, replacing replacements: [Unicode.Scalar: String]) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isForbidden(scalar) {
                // White space XML cannot hold still keeps two words apart.
                if scalar.properties.isWhitespace {
                    result.append(" ")
                }
                continue
            }
            if let replacement = replacements[scalar] {
                // One scalar at a time: `append(contentsOf:)` on a scalar view
                // copies the whole result for each call, so a text of many
                // ampersands took time that grew with the square of its length.
                for part in replacement.unicodeScalars { result.append(part) }
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }
}
