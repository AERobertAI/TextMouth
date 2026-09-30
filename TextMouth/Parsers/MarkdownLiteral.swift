/// Writes text into Markdown as literal characters: the cache reader
/// (swift-markdown, which parses CommonMark with GitHub tables, strikethrough,
/// and task lists, plus smart punctuation) reads the result back as exactly
/// the input's characters, in order. Both Markdown writers whose output the
/// cache reader parses use it: `PlainTextParser.markdown(text:)` and
/// `HTMLToMarkdownConverter`.
///
/// Every ASCII punctuation character is backslash-escaped, the one form
/// CommonMark reads literally anywhere in a paragraph or heading. That
/// disarms emphasis, code spans, links, images, autolinks, raw HTML and its
/// comments, entity references, strikethrough, tables, inline attributes,
/// block markers at the start of a line, and the smart quotes, dashes, and
/// ellipses the reader would otherwise substitute. Escapes apply per Unicode
/// scalar, because a quote followed by a combining mark is one Swift
/// `Character` but still a quote to the parser. U+FEFF is written as a
/// character reference: the parser drops it as a byte-order mark when it
/// begins the document.
///
/// Whitespace remains the caller's concern. Markdown strips spaces and tabs
/// at the ends of a line and treats a line break as structure, so callers
/// escape single lines already trimmed of surrounding whitespace.
enum MarkdownLiteral {

    /// The text with every character Markdown could interpret made literal.
    static func escaped(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isASCIIPunctuation(scalar) {
                result.append("\\")
                result.append(scalar)
            } else if scalar == "\u{FEFF}" {
                result.append(contentsOf: "&#xFEFF;".unicodeScalars)
            } else {
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// CommonMark's escapable characters: U+0021–U+002F, U+003A–U+0040,
    /// U+005B–U+0060, and U+007B–U+007E. A backslash before any other
    /// character is itself literal text, so nothing else may be escaped.
    static func isASCIIPunctuation(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x21...0x2F, 0x3A...0x40, 0x5B...0x60, 0x7B...0x7E:
            return true
        default:
            return false
        }
    }
}
