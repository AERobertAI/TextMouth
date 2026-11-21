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
        "!": "exclamation marks", // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\"": "quotation marks", // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "#": "number signs", // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "$": "dollar signs", // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "%": "percent signs", // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "&": "ampersands",
        "'": "apostrophes",
        "(": "opening parentheses", // l10n: no (spoken by the voice; follows the voice's language, a later item)
        ")": "closing parentheses", // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "*": "asterisks",
        "+": "plus signs", // l10n: no (spoken by the voice; follows the voice's language, a later item)
        ",": "commas",
        "-": "hyphens",
        ".": "periods",
        "/": "slashes",
        ":": "colons",
        ";": "semicolons",
        "<": "less-than signs", // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "=": "equals signs", // l10n: no (spoken by the voice; follows the voice's language, a later item)
        ">": "greater-than signs", // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "?": "question marks", // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "@": "at signs", // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "[": "opening brackets", // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\\": "backslashes",
        "]": "closing brackets", // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "^": "carets",
        "_": "underscores",
        "`": "backticks",
        "{": "opening braces", // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "|": "vertical bars", // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "}": "closing braces", // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "~": "tildes",
        // Bullets and dots.
        "\u{2022}": "bullets",  // •
        "\u{25E6}": "white bullets",  // ◦ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2023}": "triangular bullets",  // ‣ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2043}": "hyphen bullets",  // ⁃ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{00B7}": "middle dots",  // · // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2042}": "asterisms",  // ⁂
        // Hyphens and dashes.
        "\u{2010}": "hyphens",  // ‐
        "\u{2011}": "non-breaking hyphens",  // ‑ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2012}": "figure dashes",  // ‒ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2013}": "en dashes",  // – // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2014}": "em dashes",  // — // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2015}": "horizontal bars",  // ― // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2E3A}": "two-em dashes",  // ⸺ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2E3B}": "three-em dashes",  // ⸻ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2212}": "minus signs",  // − // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{00AF}": "macrons",  // ¯
        // Ellipsis and quotation marks.
        "\u{2026}": "ellipses",  // …
        "\u{201C}": "opening quotation marks",  // “ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{201D}": "closing quotation marks",  // ” // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2018}": "opening single quotation marks",  // ‘ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2019}": "closing single quotation marks",  // ’ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        // Other marks books use.
        "\u{00A7}": "section signs",  // § // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{00B6}": "pilcrows",  // ¶
        "\u{00B0}": "degree signs",  // ° // l10n: no (spoken by the voice; follows the voice's language, a later item)
        // Box-drawing lines.
        "\u{2500}": "horizontal lines",  // ─ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2501}": "heavy horizontal lines",  // ━ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2550}": "double horizontal lines",  // ═ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2504}": "dashed horizontal lines",  // ┄ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2505}": "heavy dashed horizontal lines",  // ┅ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2508}": "dashed horizontal lines",  // ┈ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2509}": "heavy dashed horizontal lines",  // ┉ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{254C}": "dashed horizontal lines",  // ╌ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{254D}": "heavy dashed horizontal lines",  // ╍ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2502}": "vertical lines",  // │ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2503}": "heavy vertical lines",  // ┃ // l10n: no (spoken by the voice; follows the voice's language, a later item)
        "\u{2551}": "double vertical lines",  // ║ // l10n: no (spoken by the voice; follows the voice's language, a later item)
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
