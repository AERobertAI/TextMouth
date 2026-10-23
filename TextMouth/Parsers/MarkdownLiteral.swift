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

    // MARK: Minimal Escaping (for the exported Markdown)

    /// One piece of one line of text, escaped for a Markdown reader to read it
    /// back as exactly its characters, wherever in a line it stands, with only
    /// the backslashes that needs: the form of the Markdown an export writes
    /// (`MarkdownExportWriter`), which people and other programs read, where
    /// `escaped` (content.md's form, for TextMouth's own cache) escapes every
    /// ASCII punctuation character. The reader meant is CommonMark with
    /// GitHub's tables, strikethrough, and task lists. `text` has no line
    /// feed: the caller splits lines, and applies `guardingLineStart(_:)` to
    /// each line it writes.
    ///
    /// Backslash-escaped, by these rules:
    /// - always: `` ` ``, `*`, `[`, `]`, `|`, `~`, and `<` (raw HTML, comments,
    ///   and autolinks: an email address's autolink can begin with a digit or
    ///   with most of the ASCII punctuation, as in `<12345@example.com>` and
    ///   `<+44@x.co>`, so no character after the `<` makes it safe to leave);
    /// - `_`, unless the characters on both sides of it in the piece are
    ///   letters, digits, or marks (`isFlankingSafe`): an underscore inside a
    ///   word never makes emphasis;
    /// - `\`, when the next character in the piece is ASCII punctuation, or
    ///   it ends the piece;
    /// - `&`, when what follows it is a character reference's body: `#` and
    ///   one to seven digits and `;`, `#x` or `#X` and one to six hex digits
    ///   and `;`, or an ASCII letter, then ASCII letters or digits, and `;`
    ///   ("AT&T" and "Q&A" stay as they are, "&amp;" becomes "\&amp;");
    /// - `#`, when it is the first `#` of a run of `#` that ends the piece
    ///   (with only spaces or tabs after it) and has a space or tab, or
    ///   nothing, before it: an ATX heading's closing sequence ("Issue #"
    ///   becomes "Issue \#"; "C#" and "#378" stay);
    /// - with `smartPunctuation`, for a reader that substitutes curly quotes,
    ///   dashes, and ellipses (TextMouth's own): also `"` and `'` always, and
    ///   `-` or `.` when the character before or after it in the piece is the
    ///   same character (a lone hyphen or period, and a line's last period,
    ///   are never changed, so "Done." stays). A piece is a whole line or a
    ///   stretch between emphasis delimiters, which `MarkdownEmphasis` keeps
    ///   dashes and dots out of, so a run of them is never split across
    ///   pieces.
    ///
    /// U+FEFF is written as a character reference, as `escaped` writes it.
    /// Nothing else is escaped: never `,` `.` `:` `;` `?` `!` `(` `)` `/` `%`
    /// `$` `@` `^` `{` `}` `=` `+` `-` `>` `'` or `"` mid-line, quotes and
    /// dashes aside under `smartPunctuation`. Escapes apply per Unicode
    /// scalar, as in `escaped`.
    static func minimallyEscaped(_ text: String, smartPunctuation: Bool = false) -> String {
        let scalars = Array(text.unicodeScalars)
        var result = String.UnicodeScalarView()
        for index in scalars.indices {
            let scalar = scalars[index]
            // The parser drops U+FEFF as a byte-order mark at a document's
            // start, so it is written as a reference, as `escaped` does.
            if scalar == "\u{FEFF}" {
                result.append(contentsOf: "&#xFEFF;".unicodeScalars)
                continue
            }
            if needsEscape(at: index, in: scalars, smartPunctuation: smartPunctuation) {
                result.append("\\")
            }
            result.append(scalar)
        }
        return String(result)
    }

    /// Whether the scalar at `index` of `scalars`, one piece of a line, needs
    /// a backslash before it (`minimallyEscaped(_:smartPunctuation:)` gives
    /// the rules).
    private static func needsEscape(at index: Int, in scalars: [Unicode.Scalar], smartPunctuation: Bool) -> Bool {
        let scalar = scalars[index]
        let previous = index > 0 ? scalars[index - 1] : nil
        let next = index + 1 < scalars.count ? scalars[index + 1] : nil
        switch scalar {
        case "`", "*", "[", "]", "|", "~", "<":
            return true
        case "_":
            // Inside a word (a letter, digit, or mark on both sides) it
            // never makes emphasis.
            guard let previous, let next else { return true }
            return !(isFlankingSafe(previous) && isFlankingSafe(next))
        case "\\":
            guard let next else { return true }
            return isASCIIPunctuation(next)
        case "&":
            return startsCharacterReferenceBody(scalars, after: index)
        case "#":
            return isStartOfClosingHashRun(at: index, in: scalars)
        case "\"", "'":
            return smartPunctuation
        case "-", ".":
            return smartPunctuation && (previous == scalar || next == scalar)
        default:
            return false
        }
    }

    /// Whether the scalars after the `&` at `index` are the body of a
    /// character reference: `#` and one to seven digits and `;`, `#x` or
    /// `#X` and one to six hex digits and `;`, or an ASCII letter, then
    /// ASCII letters or digits, and `;`.
    private static func startsCharacterReferenceBody(_ scalars: [Unicode.Scalar], after index: Int) -> Bool {
        var position = index + 1
        guard position < scalars.count else { return false }
        /// The number of scalars from `position` on that satisfy `matches`.
        func run(of matches: (Unicode.Scalar) -> Bool) -> Int {
            var length = 0
            while position + length < scalars.count, matches(scalars[position + length]) { length += 1 }
            return length
        }
        let length: Int
        let allowed: ClosedRange<Int>
        if scalars[position] == "#" {
            position += 1
            if position < scalars.count, scalars[position] == "x" || scalars[position] == "X" {
                position += 1
                allowed = 1...6
                length = run { $0.properties.isASCIIHexDigit }
            } else {
                allowed = 1...7
                length = run { ("0"..."9").contains($0) }
            }
        } else if isASCIILetter(scalars[position]) {
            allowed = 1...Int.max
            length = run { isASCIILetter($0) || ("0"..."9").contains($0) }
        } else {
            return false
        }
        let end = position + length
        return allowed.contains(length) && end < scalars.count && scalars[end] == ";"
    }

    /// Whether the `#` at `index` is the first of a run of `#` that ends the
    /// piece (only spaces or tabs after it) and has a space or tab, or
    /// nothing, before it: what an ATX heading reads as its closing sequence.
    private static func isStartOfClosingHashRun(at index: Int, in scalars: [Unicode.Scalar]) -> Bool {
        if index > 0, scalars[index - 1] != " ", scalars[index - 1] != "\t" { return false }
        var position = index
        while position < scalars.count, scalars[position] == "#" { position += 1 }
        return scalars[position...].allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// Whether `scalar` is an ASCII letter.
    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    /// `line`, a line already written (from pieces `minimallyEscaped` wrote,
    /// and emphasis or link syntax), with the one backslash its start needs
    /// so that it cannot begin a block:
    /// - before a leading run of one to six `#` followed by a space, a tab,
    ///   or the end (an ATX heading);
    /// - before a leading `-` or `+` followed by a space, a tab, or the end
    ///   (a bullet);
    /// - before a leading `-` or `=` when the whole line is that character
    ///   with spaces or tabs (a thematic break or a setext underline);
    /// - before the first character of a table's delimiter row of one column
    ///   (`delimiterRowStart(of:)`): one or more `-` with a `:` before them,
    ///   after them, or both, as in `:-`, `-:`, and `:-:`. GitHub's tables
    ///   need no pipe in such a row, so after a hard break it would turn the
    ///   line before it into a table's header;
    /// - before a leading `>` (a quote);
    /// - before the `.` or `)` that follows one to nine leading digits when a
    ///   space, a tab, or the end comes after it (a numbered item): "2019.
    ///   That" becomes "2019\. That", and "1.5 million" stays.
    ///
    /// A line that begins with spaces is the caller's concern, as for
    /// `escaped`.
    static func guardingLineStart(_ line: String) -> String {
        let scalars = Array(line.unicodeScalars)
        guard let first = scalars.first else { return line }
        /// Whether the scalar at `position` is a space or a tab, or none is left.
        func isBlankOrEnd(_ position: Int) -> Bool {
            position >= scalars.count || scalars[position] == " " || scalars[position] == "\t"
        }
        /// `line` with a backslash inserted before the scalar at `position`.
        func guarded(at position: Int) -> String {
            var copy = scalars
            copy.insert("\\", at: position)
            return String(String.UnicodeScalarView(copy))
        }
        // A delimiter row, whatever its start (a hyphen, a colon, or a blank
        // the table scanner counts), before the starts below are looked at.
        if let start = delimiterRowStart(of: scalars) { return guarded(at: start) }
        switch first {
        case "#":
            let run = scalars.prefix { $0 == "#" }.count
            return run <= 6 && isBlankOrEnd(run) ? guarded(at: 0) : line
        case "-", "+", "=":
            // A bullet is `-` or `+` and a blank; an underline or thematic
            // break is a line of `-` or of `=` and blanks.
            let isBullet = first != "=" && isBlankOrEnd(1)
            let isUnderline = first != "+" && scalars.allSatisfy { $0 == first || $0 == " " || $0 == "\t" }
            return isBullet || isUnderline ? guarded(at: 0) : line
        case ">":
            return guarded(at: 0)
        case "0"..."9":
            let digits = scalars.prefix { ("0"..."9").contains($0) }.count
            let delimiter = digits < scalars.count ? scalars[digits] : nil
            let isNumberedItem = digits <= 9 && (delimiter == "." || delimiter == ")") && isBlankOrEnd(digits + 1)
            return isNumberedItem ? guarded(at: digits) : line
        default:
            return line
        }
    }

    /// The position of the first scalar of `scalars`, a line, that is not a
    /// blank, when the line is a table's delimiter row of one column; nil
    /// when it is not. Such a row is blanks, an optional `:`, one or more
    /// `-`, an optional `:`, and blanks: the form GitHub's table scanner
    /// (cmark-gfm's) reads without a pipe. Beneath a line of the same
    /// paragraph, as a hard break puts one, it makes that line the header of a
    /// table. A blank to the scanner is a space, a tab, a vertical tab, or a
    /// form feed, so a row of hyphens with no colon is a delimiter row too
    /// when one of the last two stands beside it, which the thematic break
    /// and the setext underline that guard the same hyphens do not allow.
    /// A row of more than one column holds a pipe, which a written line never
    /// holds unescaped.
    private static func delimiterRowStart(of scalars: [Unicode.Scalar]) -> Int? {
        /// Whether `scalar` is a blank to the table scanner.
        func isBlank(_ scalar: Unicode.Scalar) -> Bool {
            scalar == " " || scalar == "\t" || scalar == "\u{0B}" || scalar == "\u{0C}"
        }
        guard let start = scalars.firstIndex(where: { !isBlank($0) }) else { return nil }
        var position = start
        if scalars[position] == ":" { position += 1 }
        let hyphens = scalars[position...].prefix { $0 == "-" }.count
        guard hyphens > 0 else { return nil }
        position += hyphens
        if position < scalars.count, scalars[position] == ":" { position += 1 }
        return scalars[position...].allSatisfy(isBlank) ? start : nil
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
