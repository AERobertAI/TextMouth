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

    /// The most pages one book may have, one limit for every reader that
    /// writes them. A real book has far fewer (a 64 MB braille book has about
    /// 65,000 braille pages), so a source that marks more is taken as
    /// hostile, such as a plain text that is almost all form feeds, whose
    /// markers would otherwise cost memory and time each. Each reader says
    /// what it does past the limit: textutil's reads such a document without
    /// pages (`TextutilPageBreaks.maximumPages`), and plain text's begins no
    /// further page (`PlainTextParser.pagedBlocks(in:)`).
    static let maximumPagesPerBook = 100_000

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
    /// `maximumLabelLength` Characters and trimmed again. A label that names
    /// no page (`namesNoPage`: nothing left, or only the word "Page", from a
    /// source that gives no name) becomes `ordinal`, the page's 1-based
    /// number among the book's pages.
    init(label: String, ordinal: Int) {
        let normalized = Self.normalized(label)
        self.label = Self.namesNoPage(normalized) ? String(ordinal) : normalized
    }

    // MARK: - Labels that name no page

    /// Whether `label` gives a page no name of its own: it holds nothing but
    /// white space and a lone period, or only the word "Page" in any
    /// capitals, with a period or a colon or neither, which a generator
    /// writes when it has no number for the page (`aria-label="Page "`).
    /// Every reader of a book's page labels asks this one rule before it
    /// takes a label, so no page is named "Page", which the reader would
    /// show as "Page Page of 1". It asks after taking a leading "Page" off
    /// as a marker does (`withoutPagePrefix`), so a label it accepts never
    /// becomes one that names no page ("Page page").
    static func namesNoPage(_ label: String) -> Bool {
        let key = comparisonKey(withoutPagePrefix(collapsingWhitespace(label)))
        return key.isEmpty || key == "PAGE" || key == "PAGE:"
    }

    /// Whether `label` is a page number as `isNoMoreThanLabel` reads one:
    /// ASCII digits, or a Roman numeral in its canonical form, with case,
    /// white space, one trailing period, and a leading word "Page" set aside
    /// ("12", "xii", "XII.", "Page 12").
    static func isPageNumber(_ label: String) -> Bool {
        pageNumber(comparisonKey(withoutPagePrefix(collapsingWhitespace(label)))) != nil
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

    // MARK: - Page numbers and real words

    /// Whether `text`, found where a page begins, is no more than that page's
    /// own `label`, which the marker stands in for, and not words a listener
    /// must hear (ST02, PG08). Both formats that carry page numbers as text
    /// (EPUB's page-break elements and DAISY 2.02's page fragments) use this
    /// one rule.
    ///
    /// Whitespace runs in both strings are collapsed to one space and trimmed
    /// first. Then:
    /// - empty text is no more than any label (true);
    /// - text longer than `maximumLabelLength` Characters is words (false);
    /// - an empty label cannot tell a number from words, so short text counts
    ///   as a number (true);
    /// - otherwise the text must be the page's own label: the same text once
    ///   case, spaces, and a trailing period are ignored ("12" or "12." under
    ///   the label "12", "XII" under "xii"), or the label's twin in the other
    ///   numbering, Roman for Arabic and Arabic for Roman ("V" under "5", "5"
    ///   under "V"; see `areNumberingTwins`).
    ///
    /// Any other text is real words, never dropped, however much it looks
    /// like a number (stable020 review, finding 2): a heading "IV", "XII.",
    /// "I", "1984", or "1, 2, 3." under the label "5", a caption "Page 12"
    /// under "12", or a word made of Roman numeral letters ("Mix", "Civil").
    /// Hearing a page's caption costs a listener a moment; losing a heading
    /// would cost them its words.
    static func isNoMoreThanLabel(_ text: String, label: String) -> Bool {
        let collapsedText = collapsingWhitespace(text)
        if collapsedText.isEmpty { return true }
        guard collapsedText.count <= maximumLabelLength else { return false }
        if collapsingWhitespace(label).isEmpty { return true }
        let textKey = comparisonKey(collapsedText)
        let labelKey = comparisonKey(label)
        return textKey == labelKey || areNumberingTwins(textKey, labelKey)
    }

    /// The form of a label, or of text found where a page begins, that
    /// `isNoMoreThanLabel` compares: with no whitespace, without one trailing
    /// period, and in capitals, so "xii." and "XII", or "Page 12" and
    /// "page12", share a key.
    private static func comparisonKey(_ text: String) -> String {
        var key = String(text.filter { !$0.isWhitespace })
        if key.hasSuffix(".") {
            key.removeLast()
        }
        return key.uppercased()
    }

    /// Whether two comparison keys (`comparisonKey`) write one number in the
    /// two numberings a page can be numbered in: an Arabic number and the
    /// Roman numeral of the same value ("5" and "V", "1984" and "MCMLXXXIV").
    /// Two Arabic numbers, or two Roman numerals, are never twins; equal ones
    /// are the same text.
    private static func areNumberingTwins(_ first: String, _ second: String) -> Bool {
        guard let firstNumber = pageNumber(first), let secondNumber = pageNumber(second) else { return false }
        return firstNumber.isRoman != secondNumber.isRoman && firstNumber.value == secondNumber.value
    }

    /// The value a comparison key writes as a page number, and whether it is
    /// written in Roman numerals: ASCII digits alone ("12"), or a Roman
    /// numeral in its canonical form ("XII"); nil for anything else. Only the
    /// canonical form counts ("IV", never "IIII"), so a word that happens to
    /// be made of Roman numeral letters is at most the twin of one number
    /// ("MIX" is 1009), and most such words are none ("CIVIL").
    private static func pageNumber(_ key: String) -> (value: Int, isRoman: Bool)? {
        if !key.isEmpty, key.allSatisfy({ $0.isASCII && $0.isNumber }) {
            // A number too long for an Int is no page's.
            return Int(key).map { (value: $0, isRoman: false) }
        }
        return romanNumeralValue(key).map { (value: $0, isRoman: true) }
    }

    /// The symbols of canonical Roman numerals and their values, largest
    /// first, the subtractive pairs among them.
    private static let romanNumeralSymbols: [(symbol: String, value: Int)] = [
        ("M", 1000), ("CM", 900), ("D", 500), ("CD", 400), ("C", 100), ("XC", 90),
        ("L", 50), ("XL", 40), ("X", 10), ("IX", 9), ("V", 5), ("IV", 4), ("I", 1),
    ]

    /// The values of the Roman numeral letters.
    private static let romanLetterValues: [Character: Int] = [
        "I": 1, "V": 5, "X": 10, "L": 50, "C": 100, "D": 500, "M": 1000,
    ]

    /// The canonical Roman numeral of `value` ("XIV" for 14), in capitals;
    /// nil outside 1 to 3999, which Roman numerals do not write.
    private static func romanNumeral(_ value: Int) -> String? {
        guard (1...3999).contains(value) else { return nil }
        var remaining = value
        var numeral = ""
        for (symbol, symbolValue) in romanNumeralSymbols {
            while remaining >= symbolValue {
                numeral += symbol
                remaining -= symbolValue
            }
        }
        return numeral
    }

    /// The value of `key` when it is a Roman numeral in capitals, written in
    /// its canonical form ("XIV" is 14); nil for anything else ("IIII",
    /// "IL", "CIVIL", "XIV" with a lowercase letter).
    private static func romanNumeralValue(_ key: String) -> Int? {
        guard !key.isEmpty else { return nil }
        // Read from the right: a letter smaller than the largest one after it
        // is subtracted ("IV"), any other is added. Any string of letters
        // gives some total; only the canonical spelling of that total counts.
        var total = 0
        var largestAfter = 0
        for letter in key.reversed() {
            guard let value = romanLetterValues[letter] else { return nil }
            if value < largestAfter {
                total -= value
            } else {
                total += value
                largestAfter = value
            }
        }
        return romanNumeral(total) == key ? total : nil
    }

    /// `text` with each run of whitespace and line breaks as one space and
    /// no whitespace at its ends.
    private static func collapsingWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: - Normalizing

    /// The label's normal form: trimmed, each inner run of whitespace one space,
    /// a leading word "Page" taken off (`withoutPagePrefix`), cut to
    /// `maximumLabelLength` Characters, trimmed again (the cut may end on a
    /// space). Shared by `init` and `decode`, so both agree on every label,
    /// and a content.md written with "Page 12" reads as page "12".
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
        let unprefixed = withoutPagePrefix(result)
        return String(unprefixed.prefix(maximumLabelLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `label`, its whitespace runs already made single spaces, without a
    /// leading word "Page" when a page's name follows it: the reader says
    /// "Page" itself, so a source's "Page 12" would be shown as "Page Page
    /// 12 of 300" (the user's choice, November 4, 2026). The word, in any
    /// capitals, may end in a period or a colon, and the name follows a
    /// space or begins with a digit: "Page 12", "page xii", "PAGE: 3", and
    /// "Page12" name the pages "12", "xii", "3", and "12". "Page" alone
    /// stays, and names no page (`namesNoPage`); so do words that only
    /// begin with the letters, such as "Pages 4", "Pageant", and "Page-1".
    private static func withoutPagePrefix(_ label: String) -> String {
        let word = "page"
        guard String(label.prefix(word.count)).lowercased() == word else { return label }
        var rest = label.dropFirst(word.count)
        // A period or a colon may close the word: "Page: 4".
        if rest.first == "." || rest.first == ":" {
            rest = rest.dropFirst()
        }
        if rest.first == " " {
            rest = rest.drop(while: { $0 == " " })
        } else if !(rest.first.map { $0.isASCII && $0.isNumber } ?? false) {
            // Not the word "Page" before a name: "Pages", "Pageant", "Page".
            return label
        }
        return rest.isEmpty ? label : String(rest)
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
