import Foundation

/// The names speech gives symbols when it reads a run of one as a count,
/// such as "7 asterisks" or "80 equals signs".
///
/// A run always has at least two symbols, so every name is plural.
enum RepeatedSymbolNames {
    /// The plural name for a run of `symbol`: the table's natural name for
    /// a common symbol, and otherwise the symbol's Unicode name in lower
    /// case, such as "black star".
    static func plural(of symbol: Character) -> String {
        common[symbol] ?? unicodeName(of: symbol)
    }

    /// Natural plural names for the common symbols: all ASCII punctuation
    /// and symbols, and the Unicode bullets, dashes, ellipsis, quotation
    /// marks, and box-drawing lines that books use. Non-ASCII keys are
    /// written as escapes so that look-alike characters stay distinct.
    static let common: [Character: String] = [
        // ASCII, in code order.
        "!": "exclamation marks",
        "\"": "quotation marks",
        "#": "number signs",
        "$": "dollar signs",
        "%": "percent signs",
        "&": "ampersands",
        "'": "apostrophes",
        "(": "opening parentheses",
        ")": "closing parentheses",
        "*": "asterisks",
        "+": "plus signs",
        ",": "commas",
        "-": "hyphens",
        ".": "periods",
        "/": "slashes",
        ":": "colons",
        ";": "semicolons",
        "<": "less-than signs",
        "=": "equals signs",
        ">": "greater-than signs",
        "?": "question marks",
        "@": "at signs",
        "[": "opening brackets",
        "\\": "backslashes",
        "]": "closing brackets",
        "^": "carets",
        "_": "underscores",
        "`": "backticks",
        "{": "opening braces",
        "|": "vertical bars",
        "}": "closing braces",
        "~": "tildes",
        // Bullets and dots.
        "\u{2022}": "bullets",  // •
        "\u{25E6}": "white bullets",  // ◦
        "\u{2023}": "triangular bullets",  // ‣
        "\u{2043}": "hyphen bullets",  // ⁃
        "\u{00B7}": "middle dots",  // ·
        "\u{2042}": "asterisms",  // ⁂
        // Hyphens and dashes.
        "\u{2010}": "hyphens",  // ‐
        "\u{2011}": "non-breaking hyphens",  // ‑
        "\u{2012}": "figure dashes",  // ‒
        "\u{2013}": "en dashes",  // –
        "\u{2014}": "em dashes",  // —
        "\u{2015}": "horizontal bars",  // ―
        "\u{2E3A}": "two-em dashes",  // ⸺
        "\u{2E3B}": "three-em dashes",  // ⸻
        "\u{2212}": "minus signs",  // −
        "\u{00AF}": "macrons",  // ¯
        // Ellipsis and quotation marks.
        "\u{2026}": "ellipses",  // …
        "\u{201C}": "opening quotation marks",  // “
        "\u{201D}": "closing quotation marks",  // ”
        "\u{2018}": "opening single quotation marks",  // ‘
        "\u{2019}": "closing single quotation marks",  // ’
        // Other marks books use.
        "\u{00A7}": "section signs",  // §
        "\u{00B6}": "pilcrows",  // ¶
        "\u{00B0}": "degree signs",  // °
        // Box-drawing lines.
        "\u{2500}": "horizontal lines",  // ─
        "\u{2501}": "heavy horizontal lines",  // ━
        "\u{2550}": "double horizontal lines",  // ═
        "\u{2504}": "dashed horizontal lines",  // ┄
        "\u{2505}": "heavy dashed horizontal lines",  // ┅
        "\u{2508}": "dashed horizontal lines",  // ┈
        "\u{2509}": "heavy dashed horizontal lines",  // ┉
        "\u{254C}": "dashed horizontal lines",  // ╌
        "\u{254D}": "heavy dashed horizontal lines",  // ╍
        "\u{2502}": "vertical lines",  // │
        "\u{2503}": "heavy vertical lines",  // ┃
        "\u{2551}": "double vertical lines",  // ║
    ]

    /// The Unicode name of `symbol` in lower case, for a symbol the table
    /// does not name: "black star" for ★. A character built from several
    /// scalars, such as an emoji with a skin tone, gives the names of its
    /// visible parts in order; variation selectors and invisible joiners add
    /// nothing. A symbol with no name at all, such as one in a private-use
    /// area, is called "symbols".
    static func unicodeName(of symbol: Character) -> String {
        let names = symbol.unicodeScalars
            .filter { !$0.properties.isVariationSelector && $0.properties.generalCategory != .format }
            .compactMap { $0.properties.name ?? $0.properties.nameAlias }
        return names.isEmpty ? "symbols" : names.joined(separator: " ").lowercased()
    }
}
