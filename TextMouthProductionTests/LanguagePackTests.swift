import Foundation

#if !PACK_PROBE
import XCTest
#endif

/// How a language's files are read back from a bundle, and how a plural string is asked for: the one copy of the
/// lookups that two checks of the compact language files (TL16) share.
///
/// `Scripts/l10n/verify_packs.py` (run by `make l10n-check`) compiles this file with `Scripts/l10n/pack-probe/main.swift`
/// (`-D PACK_PROBE`, which leaves the tests below out) to compare, key by key and language by language, the files
/// Xcode writes with the same files compacted. `LanguagePackTests`, below, reads the built app's own files, in the
/// Mac app and, since the iPhone's unit bundle shares this file, in the iPhone app.
///
/// Everything here is Foundation only and holds no stored state, so it compiles in a command-line tool.
enum LanguagePackLookups {
    /// The counts a plural string is asked for: zero, one, two, a few, a number that ends in one (21), a hundred, and
    /// a million (the Spanish `many` category).
    static let counts = [0, 1, 2, 5, 21, 100, 1_000_000]

    /// What a lookup returns for a key the bundle lacks: a text no catalog holds.
    static let absent = "\u{1}no such string\u{1}"

    /// One format specifier of a key: where its argument goes, and what kind of argument it takes.
    struct Specifier: Equatable {
        /// The 1-based argument number of `%2$lld`, or nil for a specifier that takes the next argument.
        let position: Int?
        /// The kind of argument: a text (`%@`), a count (`%lld`, `%d`, ...), or a real number (`%f`, ...).
        let kind: Kind
    }

    /// The kinds of argument a key's specifiers take; any other specifier (`%s`, `%c`, `%p`) is not supported.
    enum Kind { case text, count, real }

    /// The specifiers of `key` in order, skipping `%%`; nil when a specifier is not one the lookups can feed.
    ///
    /// A hand-written scanner rather than a regular expression, so the file holds no shared stored state: each
    /// `%` is followed by an optional `N$`, flags, a width, a precision, a length, and the conversion letter.
    static func specifiers(in key: String) -> [Specifier]? {
        let characters = Array(key)
        var found: [Specifier] = []
        var index = 0
        while index < characters.count {
            guard characters[index] == "%" else { index += 1; continue }
            var cursor = index + 1
            guard cursor < characters.count else { break }
            if characters[cursor] == "%" { index = cursor + 1; continue }
            // An optional argument number: digits and a dollar sign.
            var position: Int?
            var digits = cursor
            while digits < characters.count, characters[digits].isASCII, characters[digits].isNumber { digits += 1 }
            if digits > cursor, digits < characters.count, characters[digits] == "$" {
                position = Int(String(characters[cursor..<digits]))
                cursor = digits + 1
            }
            // Flags, width, precision, and length, none of which changes which argument is read.
            while cursor < characters.count, "-+ #0".contains(characters[cursor]) { cursor += 1 }
            while cursor < characters.count, characters[cursor].isASCII, characters[cursor].isNumber { cursor += 1 }
            if cursor < characters.count, characters[cursor] == "." {
                cursor += 1
                while cursor < characters.count, characters[cursor].isASCII, characters[cursor].isNumber { cursor += 1 }
            }
            while cursor < characters.count, "lhzqjtL".contains(characters[cursor]) { cursor += 1 }
            guard cursor < characters.count else { break }
            let conversion = characters[cursor]
            if conversion == "@" {
                found.append(Specifier(position: position, kind: .text))
            } else if "dDuUxXoO".contains(conversion) {
                found.append(Specifier(position: position, kind: .count))
            } else if "fFeEgGaA".contains(conversion) {
                found.append(Specifier(position: position, kind: .real))
            } else {
                return nil
            }
            index = cursor + 1
        }
        return found
    }

    /// The arguments a key's format takes, in argument order, with `count` for every count: a text is "text".
    /// Nil when `specifiers(in:)` cannot read the key.
    static func arguments(forKey key: String, count: Int) -> [CVarArg]? {
        guard let specifiers = specifiers(in: key) else { return nil }
        // Place each specifier at its argument number (the next one when it has none), then fill any gap.
        var placed: [Int: Kind] = [:]
        var next = 1
        for specifier in specifiers {
            placed[specifier.position ?? next] = specifier.kind
            next = (specifier.position ?? next) + 1
        }
        let last = placed.keys.max() ?? 0
        return (0..<last).map { slot -> CVarArg in
            switch placed[slot + 1] {
            case .text: return "text" as NSString
            case .real: return Double(count)
            case .count, nil: return count
            }
        }
    }

    /// The bundle of one language's folder (`es.lproj`) inside `resources`, or nil when there is none. Asking the
    /// folder itself skips the system's language choice, so the answer is that language's, not the person's.
    static func bundle(language: String, in resources: URL) -> Bundle? {
        Bundle(path: resources.appendingPathComponent("\(language).lproj").path)
    }

    /// The languages of the `*.lproj` folders in `resources` that hold a `Localizable` table, sorted.
    static func languages(in resources: URL) -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: resources.path)) ?? []
        return names.filter { $0.hasSuffix(".lproj") && hasTable(folder: resources.appendingPathComponent($0)) }
            .map { String($0.dropLast(".lproj".count)) }
            .sorted()
    }

    /// Whether `folder` holds a `Localizable.strings` or `Localizable.stringsdict`.
    private static func hasTable(folder: URL) -> Bool {
        ["strings", "stringsdict"].contains { kind in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("Localizable.\(kind)").path)
        }
    }

    /// The bundle's text for `key`, or nil when its table lacks the key.
    static func simpleText(_ bundle: Bundle, key: String) -> String? {
        let text = bundle.localizedString(forKey: key, value: absent, table: nil)
        return text == absent ? nil : text
    }

    /// The text the app shows for `key`: the bundle's table text, or the key itself when no table holds it, as
    /// `String(localized:)` does. A squeezed table (TL18) leaves out an entry whose text is its key, so a lookup that
    /// compares texts compares these, not `simpleText`'s.
    static func effectiveText(_ bundle: Bundle, key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    /// The text of the plural string `key` for `count` in `language`, as the bundle's plural rules pick it (or, in a
    /// language whose forms are all one text, the plain entry that holds it); nil when the key has a specifier the
    /// lookups cannot feed.
    static func pluralText(_ bundle: Bundle, key: String, language: String, count: Int) -> String? {
        guard let arguments = arguments(forKey: key, count: count) else { return nil }
        return String(format: effectiveText(bundle, key: key), locale: Locale(identifier: language), arguments: arguments)
    }
}

#if !PACK_PROBE

/// The catalog's strings, read from the repository: the source every language file is compiled from.
struct LanguagePackCatalog {
    /// One string of the catalog in one language: its simple text, or its plural forms by category.
    enum Text: Equatable {
        case simple(String)
        case plural([String: String])
    }

    /// Every string by key, then language, holding only what Xcode compiles: a text in the state `new` (an English
    /// text the code has not been translated from) is not compiled, so it is left out here too.
    let texts: [String: [String: Text]]

    /// The catalog beside this source file's repository folder (`TextMouth/Localization/Localizable.xcstrings`).
    static func load(from sourceFile: String = #filePath) throws -> LanguagePackCatalog {
        let repository = URL(fileURLWithPath: sourceFile).deletingLastPathComponent().deletingLastPathComponent()
        let url = repository.appendingPathComponent("TextMouth/Localization/Localizable.xcstrings")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = root?["strings"] as? [String: [String: Any]] ?? [:]
        var texts: [String: [String: Text]] = [:]
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
            for (language, localization) in localizations {
                if let unit = Self.unit(localization["stringUnit"]) {
                    texts[key, default: [:]][language] = .simple(unit)
                } else if let plural = (localization["variations"] as? [String: Any])?["plural"] as? [String: [String: Any]] {
                    let forms = plural.compactMapValues { Self.unit($0["stringUnit"]) }
                    if !forms.isEmpty { texts[key, default: [:]][language] = .plural(forms) }
                }
            }
        }
        return LanguagePackCatalog(texts: texts)
    }

    /// The text of a `stringUnit` that Xcode compiles: any state but `new`.
    private static func unit(_ value: Any?) -> String? {
        guard let unit = value as? [String: Any], unit["state"] as? String != "new" else { return nil }
        return unit["value"] as? String
    }

    /// The keys that have a text in `language`, sorted: every key, simple and plural alike.
    func keys(in language: String) -> [String] {
        texts.filter { $0.value[language] != nil }.map(\.key).sorted()
    }
}

/// The plural category a count falls in, by language (CLDR's rules), for the languages TextMouth ships. A language
/// missing here fails `testEveryShippedLanguageHasAPluralRule`, which names it: add its rule beside the others.
///
/// The rules are written out here, independently of the operating system, so that
/// `testApplesPluralRuleAgreesWithTheTableForEveryLanguage` can check Apple's own rule against them for every language,
/// whether or not the built app carries it yet.
enum LanguagePackPluralRules {
    /// The plural categories each language uses, in CLDR's order: the table `Scripts/l10n/catalog.py` keeps in
    /// `PLURAL_CATEGORIES`. One language to a line: `Scripts/l10n/tests/test_plural_rules_swift.py` reads these lines
    /// and fails when they differ from that table.
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
    private static func isWholeMillions(_ count: Int) -> Bool {
        count != 0 && count % 1_000_000 == 0
    }

    /// The category of `count` in `language`, or nil for a language with no rule here. For the whole numbers the
    /// tests use (0 and up), by CLDR's cardinal rules:
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
    static func category(of count: Int, language: String) -> String? {
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
}

/// The compact language files (TL16) as the built app carries them, on both platforms: `.strings` files are the
/// text form and `.stringsdict` files are binary (so the build phase that compacts them cannot silently stop), and
/// every lookup, simple or plural, gives what the catalog holds for that language.
///
/// Shared with the iPhone's unit bundle (project.yml), so GitHub checks the iPhone app's files too. Each language
/// is read through its own `*.lproj` folder, which skips the person's language choice, so the suite's English
/// language does not matter.
final class LanguagePackTests: XCTestCase {
    /// The folder of the app's `*.lproj` folders: Contents/Resources in the Mac app, the bundle itself on the iPhone.
    private var resources: URL { Bundle.main.resourceURL ?? Bundle.main.bundleURL }

    /// The catalog and the app's languages, or a failure that says what is missing.
    private func load() throws -> (catalog: LanguagePackCatalog, languages: [String]) {
        let catalog = try LanguagePackCatalog.load()
        let languages = LanguagePackLookups.languages(in: resources)
        XCTAssertTrue(languages.contains("es"), "The app's language folders: \(languages), in \(resources.path)")
        return (catalog, languages)
    }

    /// The first bytes of a file, to tell the property list forms apart.
    private func head(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 8) ?? Data()
    }

    /// Every `.strings` the app carries is UTF-8 text or a binary property list (whichever is smaller for its language,
    /// TL18; never XML) and every `.stringsdict` is a binary property list: the compact forms the build phase writes.
    /// A phase that stopped running shows here.
    func testTheAppsStringsAreCompactAndItsStringsdictsAreBinary() throws {
        let (_, languages) = try load()
        var checked = 0
        for language in languages {
            let folder = resources.appendingPathComponent("\(language).lproj")
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() {
                let url = folder.appendingPathComponent(name)
                let bytes = try head(of: url)
                if name.hasSuffix(".stringsdict") {
                    XCTAssertEqual(bytes, Data("bplist00".utf8), "\(language).lproj/\(name) is not a binary property list")
                    checked += 1
                } else if name.hasSuffix(".strings") {
                    // The text form starts with a quoted key; the binary form with its magic; XML with its prolog.
                    let isBinary = bytes == Data("bplist00".utf8)
                    let isXML = bytes.starts(with: Data("<?xml".utf8)) || bytes.starts(with: Data("<plist".utf8))
                    XCTAssertFalse(isXML, "\(language).lproj/\(name) is an XML property list, not a compact form")
                    XCTAssertTrue(isBinary || bytes.first == UInt8(ascii: "\""), "\(language).lproj/\(name) is neither text starting with a key nor a binary list")
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 3, "English's plurals and Spanish's strings and plurals: \(languages)")
    }

    /// Every simple string of every language the app carries reads back the catalog's text (a string whose text is its
    /// key may be absent from the table, which reads as the key), and a string the catalog has no compiled text for is
    /// absent from that language's table.
    func testEverySimpleLookupEqualsTheCatalog() throws {
        let (catalog, languages) = try load()
        var verified = 0
        var wrong: [String] = []
        for language in languages {
            let bundle = try XCTUnwrap(LanguagePackLookups.bundle(language: language, in: resources))
            for (key, byLanguage) in catalog.texts.sorted(by: { $0.key < $1.key }) {
                guard case .simple(let want)? = byLanguage[language] else { continue }
                verified += 1
                // The app shows the key when no table holds it, so an entry equal to its key may be left out (TL18).
                let got = LanguagePackLookups.effectiveText(bundle, key: key)
                if got != want { wrong.append("\(language) \(key.debugDescription): \(got.debugDescription), not \(want.debugDescription)") }
            }
        }
        XCTAssertGreaterThan(verified, 3000, "Too few simple strings were checked; the languages: \(languages)")
        XCTAssertTrue(wrong.isEmpty, "\(wrong.count) lookups differ from the catalog; the first:\n" + wrong.prefix(10).joined(separator: "\n"))
    }

    /// A key that the catalog gives no simple text in a language (English holds none of the compiled ones: its text is
    /// the key) is absent from that language's `.strings`, so the app falls back to the key, as the catalog says.
    func testAKeyWithoutACompiledTextIsAbsent() throws {
        let (catalog, languages) = try load()
        var present: [String] = []
        for language in languages {
            let bundle = try XCTUnwrap(LanguagePackLookups.bundle(language: language, in: resources))
            for key in catalog.texts.keys.sorted() {
                let kind = catalog.texts[key]?[language]
                if case .simple? = kind { continue }
                if case .plural? = kind { continue }
                if LanguagePackLookups.simpleText(bundle, key: key) != nil { present.append("\(language) \(key.debugDescription)") }
            }
        }
        XCTAssertTrue(present.isEmpty, "Keys the catalog does not compile for a language are in its table: \(present.prefix(10))")
    }

    /// Every plural string gives the form the catalog holds for the count's category, at 0, 1, 2, 5, 21, 100, and
    /// 1,000,000, with the arguments formatted in the language's locale.
    func testEveryPluralLookupGivesTheCatalogsFormAtEachCount() throws {
        let (catalog, languages) = try load()
        var verified = 0
        var wrong: [String] = []
        for language in languages {
            let bundle = try XCTUnwrap(LanguagePackLookups.bundle(language: language, in: resources))
            for key in catalog.keys(in: language) {
                guard case .plural(let forms)? = catalog.texts[key]?[language] else { continue }
                for count in LanguagePackLookups.counts {
                    guard let category = LanguagePackPluralRules.category(of: count, language: language),
                          let form = forms[category] ?? forms["other"],
                          let arguments = LanguagePackLookups.arguments(forKey: key, count: count)
                    else {
                        wrong.append("\(language) \(key.debugDescription) at \(count): no rule, form, or arguments")
                        continue
                    }
                    let want = String(format: form, locale: Locale(identifier: language), arguments: arguments)
                    let got = LanguagePackLookups.pluralText(bundle, key: key, language: language, count: count)
                    verified += 1
                    if got != want { wrong.append("\(language) \(key.debugDescription) at \(count): \(String(describing: got)), not \(want.debugDescription)") }
                }
            }
        }
        XCTAssertGreaterThan(verified, 2000, "Too few plural lookups were checked")
        XCTAssertTrue(wrong.isEmpty, "\(wrong.count) plural lookups differ from the catalog; the first:\n" + wrong.prefix(10).joined(separator: "\n"))
    }

    /// Every language the app carries has a plural rule in `LanguagePackPluralRules`, so a language added later is
    /// checked at every count, not skipped.
    func testEveryShippedLanguageHasAPluralRule() throws {
        let (_, languages) = try load()
        let without = languages.filter { LanguagePackPluralRules.category(of: 1, language: $0) == nil }
        XCTAssertTrue(without.isEmpty, "Add a plural rule to LanguagePackPluralRules for: \(without)")
    }

    /// Apple's own plural rule picks, at each count the helpers use, the category `LanguagePackPluralRules` expects (CLDR's,
    /// and the table `Scripts/l10n/catalog.py` keeps), for every language the table names, whether or not the built app
    /// carries it yet. Each language gets a small bundle in the test's own sandbox whose `.stringsdict` has a form for every
    /// category that names it, so the text that comes back is the category Apple chose.
    func testApplesPluralRuleAgreesWithTheTableForEveryLanguage() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("LanguagePackPluralRules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        // Every category the languages use, each form's text being the category's own name. `zero` goes in only for
        // a language whose own rule has it (Arabic): Foundation reads an explicit `zero` form as "the count is 0" in
        // every language, which is not a language's own rule (the first run of this test, on GitHub, showed German at
        // 0 choosing `zero`).
        let key = "%lld probe"
        func probeTable(withZero: Bool) throws -> Data {
            var forms: [String: Any] = ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld"]
            for category in ["one", "two", "few", "many", "other"] + (withZero ? ["zero"] : []) {
                forms[category] = "\(category) %lld"
            }
            let table: [String: Any] = [key: ["NSStringLocalizedFormatKey": "%#@value@", "value": forms]]
            return try PropertyListSerialization.data(fromPropertyList: table, format: .binary, options: 0)
        }

        var checked = 0
        for (language, categories) in LanguagePackPluralRules.categories.sorted(by: { $0.key < $1.key }) {
            let folder = root.appendingPathComponent("\(language).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try probeTable(withZero: categories.contains("zero")).write(to: folder.appendingPathComponent("Localizable.stringsdict"))
            let bundle = try XCTUnwrap(LanguagePackLookups.bundle(language: language, in: root), language)
            for count in LanguagePackLookups.counts {
                let expected = try XCTUnwrap(LanguagePackPluralRules.category(of: count, language: language), "\(language) has no rule")
                XCTAssertTrue(categories.contains(expected), "\(language): \(expected) is not one of its categories \(categories)")
                let text = try XCTUnwrap(LanguagePackLookups.pluralText(bundle, key: key, language: language, count: count))
                // The text is "<category> <count>": the category is the first word.
                let chosen = text.split(separator: " ").first.map(String.init)
                XCTAssertEqual(chosen, expected, "\(language) at \(count): Apple picked \(String(describing: chosen))")
                checked += 1
            }
        }
        XCTAssertEqual(checked, LanguagePackPluralRules.categories.count * LanguagePackLookups.counts.count)
    }

    /// The reader of a key's format arguments: sequential and positional specifiers, `%%`, and a precision.
    func testTheArgumentsOfAKeyFollowItsSpecifiers() {
        XCTAssertEqual(LanguagePackLookups.arguments(forKey: "No specifier", count: 3)?.count, 0)
        XCTAssertEqual(LanguagePackLookups.arguments(forKey: "%lld books", count: 3)?.count, 1)
        // `%%` takes no argument: the text, the count, then the text.
        XCTAssertEqual(LanguagePackLookups.arguments(forKey: "%lld%% of %@ and %@", count: 3)?.count, 3)
        // A positional specifier goes to its own slot, and a gap before it is filled.
        XCTAssertEqual(LanguagePackLookups.arguments(forKey: "%2$lld then %1$@", count: 3)?.count, 2)
        XCTAssertEqual(LanguagePackLookups.arguments(forKey: "%3$lld", count: 3)?.count, 3)
        // A conversion the lookups cannot feed is reported, not guessed.
        XCTAssertNil(LanguagePackLookups.arguments(forKey: "%s", count: 3))
        XCTAssertEqual(LanguagePackLookups.specifiers(in: "%1$@ of %2$lld")?.map(\.position), [1, 2])
    }
}

#endif
