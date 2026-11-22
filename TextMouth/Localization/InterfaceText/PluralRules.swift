import Foundation

/// The plural category a count falls in, by language (CLDR's cardinal rules), for the languages TextMouth ships.
///
/// The interface-text lookup (`InterfaceTextEngine`) uses it to pick the form of a plural line, and the pack stores a
/// plural entry's forms in each language's category order from `categories`, so the reader needs no category names.
/// `InterfaceTextTests.testApplesPluralRuleAgreesWithTheTableForEveryLanguage` checks Apple's own rule against this table at every count from 0 to 10,000 and at the large
/// counts, so an operating system that changes a rule shows, and `Scripts/l10n/tests/test_plural_rules_swift.py` checks
/// the table against the catalog tool's `PLURAL_CATEGORIES`.
///
/// Foundation only, no stored state: the file compiles into a command-line probe as well as the apps.
enum PluralRules {
    /// The plural categories each language uses, in CLDR's order: the table `Scripts/l10n/catalog.py` keeps in
    /// `PLURAL_CATEGORIES`. One language to a line: `Scripts/l10n/tests/test_plural_rules_swift.py` reads these lines
    /// and fails when they differ from that table. Every language ends with `other`.
    static let categories: [String: [String]] = [
        "ar": ["zero", "one", "two", "few", "many", "other"],
        "bn": ["one", "other"],
        "de": ["one", "other"],
        "en": ["one", "other"],
        "es": ["one", "many", "other"],
        "fa": ["one", "other"],
        "fr": ["one", "many", "other"],
        "he": ["one", "two", "other"],
        "hi": ["one", "other"],
        "id": ["other"],
        "it": ["one", "many", "other"],
        "ja": ["other"],
        "ko": ["other"],
        "nl": ["one", "other"],
        "pl": ["one", "few", "many", "other"],
        "pt-BR": ["one", "many", "other"],
        "ru": ["one", "few", "many", "other"],
        "sv": ["one", "other"],
        "th": ["other"],
        "tr": ["one", "other"],
        "uk": ["one", "few", "many", "other"],
        "ur": ["one", "other"],
        "vi": ["other"],
        "zh-Hans": ["other"],
        "zh-Hant": ["other"],
    ]

    /// Whether `count` is a whole number of millions (1 000 000, 2 000 000, ...), the numbers that have `many` in
    /// Spanish, French, Italian, and Portuguese.
    private static func isWholeMillions(_ count: UInt) -> Bool {
        count != 0 && count % 1_000_000 == 0
    }

    /// The category of `signedCount` in `language`, or nil for a language with no rule here. A negative count is
    /// judged by its size (CLDR's rules are written for the absolute value), so `Int.min` cannot trap. For whole
    /// numbers, by CLDR's cardinal rules:
    /// - English, German, Dutch, Swedish, Turkish, Urdu: `one` for 1, else `other`.
    /// - Hindi, Bengali, Persian: `one` for 0 and 1, else `other`.
    /// - Spanish, Italian: `one` for 1, `many` for a whole number of millions, else `other`.
    /// - French, Brazilian Portuguese: `one` for 0 and 1, `many` for a whole number of millions, else `other`.
    /// - Russian, Ukrainian: `one` for a number ending in 1 but not 11, `few` for one ending in 2 to 4 but not 12 to 14,
    ///   else `many`.
    /// - Polish: `one` for 1, `few` for a number ending in 2 to 4 but not 12 to 14, else `many`.
    /// - Arabic: `zero` for 0, `one` for 1, `two` for 2, `few` when the last two digits are 3 to 10, `many` when they
    ///   are 11 to 99, else `other`.
    /// - Hebrew: `one` for 1, `two` for 2, else `other`.
    /// - Chinese, Japanese, Korean, Indonesian, Thai, Vietnamese: always `other`. (CLDR 49 gives Vietnamese a `one`
    ///   for 0 and 1, but Apple's Foundation still uses `other` alone, and Foundation is what picks the form.)
    static func category(of signedCount: Int, language: String) -> String? {
        let count = signedCount.magnitude
        switch language {
        case "en", "de", "nl", "sv", "tr", "ur":
            return count == 1 ? "one" : "other"
        case "hi", "bn", "fa":
            return count == 0 || count == 1 ? "one" : "other"
        case "es", "it":
            return count == 1 ? "one" : (isWholeMillions(count) ? "many" : "other")
        case "fr", "pt-BR":
            return count == 0 || count == 1 ? "one" : (isWholeMillions(count) ? "many" : "other")
        case "ru", "uk":
            let lastDigit = count % 10
            let lastTwoDigits = count % 100
            if lastDigit == 1 && lastTwoDigits != 11 { return "one" }
            if (2...4).contains(lastDigit) && !(12...14).contains(lastTwoDigits) { return "few" }
            return "many"
        case "pl":
            if count == 1 { return "one" }
            let lastDigit = count % 10
            let lastTwoDigits = count % 100
            return (2...4).contains(lastDigit) && !(12...14).contains(lastTwoDigits) ? "few" : "many"
        case "ar":
            let lastTwoDigits = count % 100
            switch count {
            case 0: return "zero"
            case 1: return "one"
            case 2: return "two"
            default:
                if (3...10).contains(lastTwoDigits) { return "few" }
                if (11...99).contains(lastTwoDigits) { return "many" }
                return "other"
            }
        case "he":
            return count == 1 ? "one" : (count == 2 ? "two" : "other")
        case "zh-Hans", "zh-Hant", "ja", "ko", "id", "th", "vi":
            return "other"
        default:
            return nil
        }
    }

    /// The position of the form for `count` in a plural entry of `language`, whose forms follow `categories[language]`;
    /// nil for a language with no rule here. The last form (`other`) answers a category the entry somehow lacks.
    static func formIndex(of count: Int, language: String) -> Int? {
        guard let names = categories[language], let category = category(of: count, language: language) else { return nil }
        return names.firstIndex(of: category) ?? names.count - 1
    }
}
