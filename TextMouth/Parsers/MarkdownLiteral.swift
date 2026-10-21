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
    ///
    /// Written a UTF-8 byte at a time, which the scalars it escapes allow
    /// (PERF23: one scalar at a time took six times as long). Every
    /// escaped scalar is ASCII, a single byte that UTF-8 never uses inside
    /// another scalar's bytes, and U+FEFF is the only scalar whose bytes are
    /// EF BB BF, since EF can only begin a scalar. Every other byte is
    /// copied, so each other scalar is copied whole.
    static func escaped(_ text: String) -> String {
        var source = text
        return source.withUTF8 { bytes in
            var output: [UInt8] = []
            output.reserveCapacity(bytes.count + bytes.count / 8)
            var index = 0
            while index < bytes.count {
                let byte = bytes[index]
                if isASCIIPunctuation(Unicode.Scalar(byte)) {
                    output.append(UInt8(ascii: "\\"))
                    output.append(byte)
                    index += 1
                } else if byte == byteOrderMark[0], bytes[index...].starts(with: byteOrderMark) {
                    output.append(contentsOf: byteOrderMarkReference)
                    index += byteOrderMark.count
                } else {
                    output.append(byte)
                    index += 1
                }
            }
            return String(decoding: output, as: UTF8.self)
        }
    }

    /// U+FEFF in UTF-8.
    private static let byteOrderMark = Array("\u{FEFF}".utf8)

    /// The character reference written for U+FEFF, in UTF-8.
    private static let byteOrderMarkReference = Array("&#xFEFF;".utf8)

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

    /// Letters, digits, and marks. CommonMark counts none of them as
    /// whitespace or punctuation, so an emphasis delimiter beside one is
    /// flanking on that side whatever stands on its other side. Both
    /// writers of emphasis keep their delimiters beside such characters:
    /// `HTMLToMarkdownConverter` and `MarkdownEmphasis`.
    static func isFlankingSafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .nonspacingMark, .spacingMark, .enclosingMark:
            return true
        default:
            return false
        }
    }
}
