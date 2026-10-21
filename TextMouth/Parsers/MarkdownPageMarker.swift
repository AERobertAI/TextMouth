import Foundation

/// Where one page of a book begins, written into content.md (PG01) as an inert
/// HTML comment: `<!-- page: 12 -->`. A marker is never spoken and adds no
/// reading text, so writing one moves no saved place. The label is the page's
/// name as its source gives it ("12", "xii", "A-3"), kept as text because a
/// page is not always a number.
struct MarkdownPageMarker: Equatable, Sendable {

    /// The longest label kept, in Characters. A longer one is cut, so a hostile
    /// or damaged source cannot put a paragraph into a page's name.
    static let maximumLabelLength = 32

    /// The page's label, normalized (see `init(label:ordinal:)`); never empty.
    let label: String

    /// The comment's fixed opening and closing text. A complete marker is
    /// exactly `prefix + escaped label + suffix`.
    private static let prefix = "<!-- page: "
    private static let suffix = " -->"

    /// Make a marker for a page the source calls `label`.
    ///
    /// The label is normalized: whitespace at its ends is trimmed, each inner
    /// run of whitespace and line breaks becomes one space, and it is cut to
    /// `maximumLabelLength` Characters and trimmed again. A label with nothing
    /// left (a source that gives no name) becomes `ordinal`, the page's
    /// 1-based number among the book's pages.
    init(label: String, ordinal: Int) {
        let normalized = Self.normalized(label)
        self.label = normalized.isEmpty ? String(ordinal) : normalized
    }

    /// A marker whose label is already normalized and not empty.
    private init(normalizedLabel: String) {
        label = normalizedLabel
    }

    /// The marker as it is written in content.md.
    var markdown: String {
        Self.prefix + Self.escaped(label) + Self.suffix
    }

    /// The marker a complete comment holds, or nil when the comment is
    /// anything else (a heading annotation, a chapter line, or a comment the
    /// source itself carried). Only our exact form is accepted, so ordinary
    /// source comments stay invisible, as with heading annotations.
    static func decode(_ comment: String) -> MarkdownPageMarker? {
        // Compared as Unicode scalars, not Characters: a label that begins
        // with a combining mark makes one Character of it and the prefix's
        // last space, which a Character comparison would not find, and the
        // page would be lost.
        let scalars = comment.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        let prefixScalars = prefix.unicodeScalars
        let suffixScalars = suffix.unicodeScalars
        // The count check also refuses a prefix and a suffix that overlap
        // ("<!-- page: -->"), which `dropFirst` and `dropLast` would mishandle.
        guard scalars.count >= prefixScalars.count + suffixScalars.count,
              scalars.starts(with: prefixScalars),
              scalars.reversed().starts(with: suffixScalars.reversed()) else { return nil }
        let encoded = String(String.UnicodeScalarView(
            scalars.dropFirst(prefixScalars.count).dropLast(suffixScalars.count)
        ))
        // Our writer escapes these, so a raw one means the text is not ours:
        // `<` and `>` could open or close other markup, and `--` is where a
        // comment ends or is refused.
        guard !encoded.isEmpty, !encoded.contains("<"), !encoded.contains(">"),
              !encoded.contains("--"),
              let decoded = percentDecoded(encoded) else { return nil }
        let label = normalized(decoded)
        return label.isEmpty ? nil : MarkdownPageMarker(normalizedLabel: label)
    }

    // MARK: - Normalizing

    /// The label's normal form: trimmed, each inner run of whitespace one space,
    /// cut to `maximumLabelLength` Characters, trimmed again (the cut may end
    /// on a space). Shared by `init` and `decode`, so both agree on every label.
    private static func normalized(_ label: String) -> String {
        var result = ""
        var pendingSpace = false
        for character in label.trimmingCharacters(in: .whitespacesAndNewlines) {
            if isWhitespace(character) {
                pendingSpace = true
                continue
            }
            if pendingSpace {
                result.append(" ")
                pendingSpace = false
            }
            result.append(character)
        }
        return String(result.prefix(maximumLabelLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether every scalar of `character` is whitespace or a line break, so a
    /// "\r\n" pair counts as one run member.
    private static func isWhitespace(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    // MARK: - Escaping

    /// Percent-encode the characters that would break a comment or its line:
    /// - `%`, because it starts an escape, so a literal "%41" survives a round trip;
    /// - `<` and `>`, because `>` can end the comment early and `<` can open other markup;
    /// - controls (Cc), line separators (Zl), and paragraph separators (Zp),
    ///   which could end the line the marker stands on;
    /// - a `-` that follows another `-`, because CommonMark (and cmark-gfm)
    ///   end or refuse a comment at `--`.
    /// Everything else, including non-ASCII text, is written as it is.
    private static func escaped(_ label: String) -> String {
        var result = ""
        var previous: Unicode.Scalar?
        for scalar in label.unicodeScalars {
            if needsEscape(scalar, after: previous) {
                for byte in String(scalar).utf8 {
                    result += "%" + hexadecimal(byte)
                }
            } else {
                result.unicodeScalars.append(scalar)
            }
            previous = scalar
        }
        return result
    }

    /// Whether `scalar` (which follows `previous` in the label) is written escaped.
    private static func needsEscape(_ scalar: Unicode.Scalar, after previous: Unicode.Scalar?) -> Bool {
        switch scalar {
        case "%", "<", ">":
            return true
        case "-":
            return previous == "-"
        default:
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }

    /// Two uppercase hexadecimal digits for `byte`.
    private static func hexadecimal(_ byte: UInt8) -> String {
        let digits = String(byte, radix: 16, uppercase: true)
        return digits.count == 1 ? "0" + digits : digits
    }

    /// The text with each `%` followed by two hexadecimal digits (either case)
    /// replaced by that byte; any other `%` stays a `%`. Nil when the bytes
    /// are not valid UTF-8.
    private static func percentDecoded(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            // `index + 2 < bytes.count` keeps both digit reads inside the array.
            if bytes[index] == UInt8(ascii: "%"), index + 2 < bytes.count,
               let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                output.append(high * 16 + low)
                index += 3
            } else {
                output.append(bytes[index])
                index += 1
            }
        }
        return String(bytes: output, encoding: .utf8)
    }

    /// The value of one hexadecimal digit, or nil for any other byte.
    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }
}
