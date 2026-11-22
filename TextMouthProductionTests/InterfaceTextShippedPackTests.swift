import Foundation

#if !PACK_PROBE
import XCTest
@testable import TextMouth
#endif

/// What the two proofs that the interface-text pack says what Apple's tables say have in common (FR39, phase 4): the
/// counts a line is asked for, and the call an ID makes. Apple's tables are keyed by ID since the catalog was (phase 7), so
/// both proofs look an ID up in them, and take its English (the call's format) from the catalog's `en`.
///
/// `Scripts/l10n/verify_packs.py` (run by `make l10n-check`) compiles this file with the probe
/// `Scripts/l10n/pack-probe/main.swift` and the engine's core files (`-D PACK_PROBE`, which leaves the test class
/// below out), and compares the engine's text with Xcode's in a process of each language. `InterfaceTextShippedPackTests`,
/// below, compares the `Strings.pack` the test host ships with the tables the host ships, in the Mac app and, since the
/// iPhone's unit bundle shares this file, in the iPhone app.
///
/// Foundation only apart from the test class, and no stored state, so it compiles in a command-line tool.
enum InterfaceTextProof {
    /// The counts every number is asked for: 0, 1, 2, 3, 5, 11, 21, 101, 1,000, 12,345, 1,000,000, 2,000,000, and
    /// 1,234,567: each plural category of every language, the edges of Russian's and Arabic's rules, grouping
    /// separators, and the whole millions that Spanish, French, Italian, and Portuguese give `many`.
    static let counts: [Int64] = [0, 1, 2, 3, 5, 11, 21, 101, 1_000, 12_345, 1_000_000, 2_000_000, 1_234_567]

    /// How many places on in `counts` each further number of a key starts, so that a key with two numbers is not asked
    /// the same count twice: the first number is `counts[i]`, the second `counts[i + 3]`, and so on, wrapping.
    static let placesBetweenNumbers = 3

    /// A problem in the proof's own inputs, never in the pack.
    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - What a key is asked

    /// The specifiers of `english`, or nil when a lookup cannot feed one of them (a conversion other than `%@` and an
    /// integer's, or a position, which no English of the catalog holds).
    private static func feedableSpecifiers(of english: String) -> [LanguagePackLookups.Specifier]? {
        guard let specifiers = LanguagePackLookups.specifiers(in: english),
              specifiers.allSatisfy({ $0.position == nil && $0.kind != .real })
        else { return nil }
        return specifiers
    }

    /// How many numbers the English's format takes (zero for an English that is no count: it is asked once).
    static func numberCount(ofEnglish english: String) -> Int {
        feedableSpecifiers(of: english)?.filter { $0.kind == .count }.count ?? 0
    }

    /// How many times an ID is asked: once when its English takes no number, else once for each of the `counts`.
    static func askings(ofEnglish english: String) -> Int {
        numberCount(ofEnglish: english) == 0 ? 1 : counts.count
    }

    /// The call an ID makes at its `asking`th asking (0 up to `askings(ofEnglish:)`): its format is the `english`, as the
    /// call site's English is, every `%@` is given "text", and the `n`th number is `counts[asking + 3n]`, wrapping. Nil
    /// when a lookup cannot feed the English.
    static func call(forEnglish english: String, asking: Int) -> InterfaceText.Format? {
        guard let specifiers = feedableSpecifiers(of: english) else { return nil }
        var arguments: [InterfaceText.Format.Argument] = []
        var numbers = 0
        for specifier in specifiers {
            switch specifier.kind {
            case .text:
                arguments.append(.text("text"))
            case .count:
                arguments.append(.number(counts[(asking + placesBetweenNumbers * numbers) % counts.count]))
                numbers += 1
            case .real:
                return nil
            }
        }
        return InterfaceText.Format(format: english, arguments: arguments)
    }

    // MARK: - Texts

    /// `text` with every specifier given the position it has: an unnumbered `%@` or `%lld` takes the next number, and a
    /// numbered one keeps its own. Xcode's compile of a plural writes `%1$@ ... %2$lld` where the catalog (and so the
    /// pack) writes `%@ ... %lld`; the two read alike once both are numbered. `%%` stays.
    static func withPositions(_ text: String) -> String {
        let characters = Array(text)
        var result = ""
        var next = 1
        var index = 0
        while index < characters.count {
            guard characters[index] == "%" else { result.append(characters[index]); index += 1; continue }
            // `%%` is a percent sign, not a specifier.
            if index + 1 < characters.count, characters[index + 1] == "%" { result += "%%"; index += 2; continue }
            // An explicit position (`2$`), the flags, width, and length, then the conversion letter.
            var cursor = index + 1
            var digits = cursor
            while digits < characters.count, characters[digits].isASCII, characters[digits].isNumber { digits += 1 }
            var position: Int?
            if digits > cursor, digits < characters.count, characters[digits] == "$" {
                position = Int(String(characters[cursor..<digits]))
                cursor = digits + 1
            }
            var tail = ""
            while cursor < characters.count, !characters[cursor].isLetter, characters[cursor] != "@" { tail.append(characters[cursor]); cursor += 1 }
            while cursor < characters.count, "lhzqjtL".contains(characters[cursor]) { tail.append(characters[cursor]); cursor += 1 }
            guard cursor < characters.count else { result += String(characters[index...]); break }
            tail.append(characters[cursor])
            result += "%\(position ?? next)$" + tail
            if position == nil { next += 1 }
            index = cursor + 1
        }
        return result
    }
}

#if !PACK_PROBE

/// The interface-text pack (`Strings.pack`) as the built app ships it, in both apps, against the language tables the
/// same app ships (FR39, phase 4), until Apple's tables leave at the switch. It succeeds the pack's part of
/// `LanguagePackTests` the way the engine will succeed Apple's lookup.
///
/// - **Every entry** of the pack in every language equals what the tables hold: the text, or the plural forms by
///   category. A key the tables lack in a language reads as its key (English), which the pack writes as no entry (or
///   as the key itself, the squeeze `compact_packs.py` makes in the tables).
/// - **Every lookup** through the engine equals `String(format:locale:arguments:)` of the table's form, which
///   `PluralRules` picks, at the 13 counts of `InterfaceTextProof`, with the locale a test gives that language
///   (`InterfaceLanguage.locale(forScope:)`: the language with the United States as its region, as `es_US`).
///
/// **The plural trap.** In a process whose locale is English, Foundation may choose a stringsdict's plural form by the
/// locale's rules rather than the table's language, so a Russian table read through `String(localized:)` or
/// `Bundle.localizedString` could be judged by English's rules. This test never asks Foundation to choose a form:
/// the tables' own property lists are read as data (`NSStringLocalizedFormatKey` names the plural variable and the
/// language's forms sit beside it), `PluralRules` picks the form, and Foundation only writes it, with an explicit
/// locale that is the table's language. And Apple's own rule is checked against `PluralRules` where it is meant to
/// be, in `LanguagePackTests.testApplesPluralRuleAgreesWithTheTableForEveryLanguage`, which asks it in each language
/// from a bundle of its own and now covers these counts too (`LanguagePackTests.pluralProbeCounts`).
///
/// Shared with the iPhone's unit bundle (project.yml), so GitHub checks the iPhone app's pack too.
final class InterfaceTextShippedPackTests: XCTestCase {
    /// The most differences a failure lists.
    private static let listed = 10

    /// The folder of the app's resources: Contents/Resources in the Mac app, the bundle itself on the iPhone.
    private var resources: URL { Bundle.main.resourceURL ?? Bundle.main.bundleURL }

    /// What every test needs: the shipped pack, the repository's catalog (the English of each ID), and the languages of the
    /// tables.
    private struct Shipped {
        let pack: InterfaceTextPack
        let ids: [String]
        let catalog: LanguagePackCatalog
        let languages: [String]
    }

    /// The pack the host ships, the repository's catalog, and the languages of the host's tables; fails with what is
    /// missing.
    private func shipped() throws -> Shipped {
        let packURL = resources.appendingPathComponent("\(InterfaceTextPack.resourceName).\(InterfaceTextPack.resourceExtension)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: packURL.path), "the host ships no Strings.pack in \(resources.path)")
        let pack = try InterfaceTextPack(contentsOf: packURL)
        let catalog = try LanguagePackCatalog.load()
        let languages = LanguagePackLookups.languages(in: resources)
        XCTAssertTrue(languages.contains("es"), "the app's language folders: \(languages), in \(resources.path)")
        let list = try pack.idList()
        return Shipped(pack: pack, ids: (0..<list.count).map { list.id(at: $0) }, catalog: catalog, languages: languages)
    }

    // MARK: - The tables, as data

    /// One language's tables read as data: its plural forms by key (the stringsdict's property list) and its bundle,
    /// which Apple's own parser answers for the plain texts.
    private struct Tables {
        let language: String
        let bundle: Bundle
        /// The stringsdict's entries: key, then the dictionary of the plural variable and its forms.
        let plurals: [String: [String: Any]]

        /// Reads `language`'s tables from the `*.lproj` folder in `resources`.
        init(language: String, in resources: URL) throws {
            self.language = language
            guard let bundle = LanguagePackLookups.bundle(language: language, in: resources) else {
                throw InterfaceTextProof.Failure("no \(language).lproj in \(resources.path)")
            }
            self.bundle = bundle
            let url = resources.appendingPathComponent("\(language).lproj/Localizable.stringsdict")
            if let data = try? Data(contentsOf: url) {
                let list = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                plurals = list as? [String: [String: Any]] ?? [:]
            } else {
                plurals = [:]
            }
        }

        /// The table's entry for `key`: the plural forms in the language's category order, the plain text, or nil when
        /// the table has none. Throws when a stringsdict entry is not the one shape Xcode writes.
        func entry(forKey key: String) throws -> InterfaceTextEntry? {
            if let plural = plurals[key] {
                guard let format = plural["NSStringLocalizedFormatKey"] as? String,
                      let variable = Self.variable(in: format), let forms = plural[variable] as? [String: Any],
                      let categories = PluralRules.categories[language]
                else { throw InterfaceTextProof.Failure("\(language): the stringsdict entry of \(key.debugDescription) is not `%#@variable@` and its forms") }
                let ordered = try categories.map { category -> String in
                    guard let form = forms[category] as? String else {
                        throw InterfaceTextProof.Failure("\(language): the stringsdict entry of \(key.debugDescription) has no \(category) form")
                    }
                    return form
                }
                return .plural(ordered)
            }
            return LanguagePackLookups.simpleText(bundle, key: key).map { .plain($0) }
        }

        /// The variable a plural entry's format names, when the format is exactly `%#@name@` or `%2$#@name@`.
        private static func variable(in format: String) -> String? {
            guard format.hasSuffix("@"), let marker = format.range(of: "#@") else { return nil }
            let before = format[format.startIndex..<marker.lowerBound]
            guard before == "%" || (before.hasPrefix("%") && before.hasSuffix("$") && before.dropFirst().dropLast().allSatisfy(\.isNumber)) else { return nil }
            return String(format[marker.upperBound..<format.index(before: format.endIndex)])
        }
    }

    /// `entry` with its specifiers given positions (`InterfaceTextProof.withPositions`), so that Xcode's numbered forms
    /// and the pack's unnumbered ones compare equal when they read alike.
    private func positioned(_ entry: InterfaceTextEntry) -> InterfaceTextEntry {
        switch entry {
        case .absent: return .absent
        case .plain(let text): return .plain(InterfaceTextProof.withPositions(text))
        case .plural(let forms):
            // A plural whose forms all read alike is a plain text: the pack writes it so in every language, while
            // Xcode's English table keeps nine of them as plurals (a finding of the first train, 1121-2027).
            let numbered = forms.map(InterfaceTextProof.withPositions)
            return Set(numbered).count == 1 ? .plain(numbered[0]) : .plural(numbered)
        }
    }

    // MARK: - Every entry

    /// The pack holds every ID of the table, once, and the host's tables are of the languages the pack knows (the 25 the
    /// plural rules name), each of which has a blob in the pack.
    func testThePackHoldsEveryLineAndEveryLanguage() throws {
        let host = try shipped()
        XCTAssertEqual(host.ids, host.catalog.texts.keys.sorted(), "the pack's IDs are the catalog's")
        XCTAssertEqual(host.languages, PluralRules.categories.keys.sorted(), "the tables' languages are the plural rules'")
        XCTAssertEqual(host.languages.count, 25)
        for language in host.languages { XCTAssertTrue(host.pack.hasLanguage(language), "the pack has no \(language) blob") }
    }

    /// Every entry of every language of the pack equals the table's text or plural forms for its ID, once the
    /// numbered specifiers of Xcode's plurals and the pack's unnumbered ones are read alike. An ID the table lacks in a
    /// language has no translation there: the pack has no entry for it (the engine shows the English).
    func testEveryEntryEqualsTheTables() throws {
        let host = try shipped()
        var compared = 0
        var wrong: [String] = []
        for language in host.languages {
            let tables = try Tables(language: language, in: resources)
            let entries = try host.pack.entries(language: language)
            for (position, id) in host.ids.enumerated() {
                let got = entries[position]
                compared += 1
                if let want = try tables.entry(forKey: id) {
                    if positioned(got) != positioned(want) { wrong.append("\(language) \(id): pack \(got), tables \(want)") }
                } else if got != .absent {
                    wrong.append("\(language) \(id): pack \(got), tables none (no translation)")
                }
            }
        }
        XCTAssertEqual(compared, host.ids.count * host.languages.count)
        XCTAssertTrue(wrong.isEmpty, "\(wrong.count) entries differ; the first:\n" + wrong.prefix(Self.listed).joined(separator: "\n"))
    }

    // MARK: - Every lookup

    /// Every lookup through the engine, for every ID of every language at every asking, equals Foundation's
    /// `String(format:locale:arguments:)` of the table's form for the same call. The time is printed for the report.
    func testEveryLookupEqualsFoundationsFormatOfTheTablesForm() throws {
        let host = try shipped()
        let log = InterfaceTextReportLog()
        let engine = InterfaceTextEngine(tables: host.pack, report: log.sink)
        let started = Date()
        var compared = 0
        var wrong: [String] = []
        for language in host.languages {
            let locale = InterfaceLanguage.locale(forScope: language)
            let tables = try Tables(language: language, in: resources)
            // English is the tables' fallback for a key a language lacks, as it is the app's (Bundle's own choice).
            let english = language == "en" ? nil : try Tables(language: "en", in: resources)
            for id in host.ids {
                // The ID's English, as the code writes it: the call's format.
                guard let source = host.catalog.english(of: id) else { wrong.append("\(language) \(id): the catalog has no English"); continue }
                // The table's entry, and the language whose plural rules choose its form.
                let own = try tables.entry(forKey: id)
                let entry = try own ?? english?.entry(forKey: id) ?? .plain(source)
                let rules = own == nil && english != nil ? "en" : language
                for asking in 0..<InterfaceTextProof.askings(ofEnglish: source) {
                    guard let call = InterfaceTextProof.call(forEnglish: source, asking: asking) else {
                        wrong.append("\(language) \(id): the lookups cannot feed this English")
                        break
                    }
                    let want = Self.text(of: entry, rules: rules, call: call, locale: locale)
                    let got = engine.text(runtimeID: id, english: call, language: language, locale: locale)
                    compared += 1
                    if got != want { wrong.append("\(language) \(id) asking \(asking): engine \(got.debugDescription), Foundation \(want.debugDescription)") }
                }
            }
        }
        print("Shipped pack: \(compared) lookups compared in \(host.languages.count) languages took \(Date().timeIntervalSince(started)) s")
        XCTAssertGreaterThan(compared, 200_000, "too few lookups were compared")
        XCTAssertEqual(log.messages, [], "the engine reported problems")
        XCTAssertTrue(wrong.isEmpty, "\(wrong.count) lookups differ; the first:\n" + wrong.prefix(Self.listed).joined(separator: "\n"))
    }

    /// The text Foundation writes for `entry`: a plain text as it is when the call has no arguments (as Apple's lookup
    /// does), else formatted; a plural's form is the one `PluralRules` picks for the call's first number in `rules`.
    private static func text(of entry: InterfaceTextEntry, rules: String, call: InterfaceText.Format, locale: Locale) -> String {
        let pattern: String
        switch entry {
        case .absent:
            pattern = call.format
        case .plain(let text):
            pattern = text
        case .plural(let forms):
            let position = call.firstNumber.flatMap { PluralRules.formIndex(of: Int(clamping: $0), language: rules) } ?? forms.count - 1
            pattern = forms.indices.contains(position) ? forms[position] : forms[forms.count - 1]
        }
        return call.arguments.isEmpty ? pattern : String(format: pattern, locale: locale, arguments: call.formatterArguments)
    }

    // MARK: - The helpers

    /// What the shared helpers compute: positions, the specifiers' kinds, the counts, and the second number.
    func testTheProofsHelpers() throws {
        XCTAssertEqual(InterfaceTextProof.withPositions("%@ has %lld books"), "%1$@ has %2$lld books")
        XCTAssertEqual(InterfaceTextProof.withPositions("%2$lld of %1$@, 100%%"), "%2$lld of %1$@, 100%%")
        XCTAssertEqual(InterfaceTextProof.withPositions("No specifier"), "No specifier")
        XCTAssertEqual(InterfaceTextProof.counts.count, 13)
        XCTAssertEqual(InterfaceTextProof.numberCount(ofEnglish: "%lld of %lld"), 2)
        XCTAssertEqual(InterfaceTextProof.askings(ofEnglish: "Plain"), 1)
        XCTAssertEqual(InterfaceTextProof.askings(ofEnglish: "%lld books"), 13)
        let two = try XCTUnwrap(InterfaceTextProof.call(forEnglish: "%@: %lld of %lld", asking: 11))
        // Asking 11: the first number is counts[11] = 2,000,000, the second counts[(11 + 3) % 13] = counts[1] = 1.
        XCTAssertEqual(two.arguments, [.text("text"), .number(2_000_000), .number(1)])
        XCTAssertNil(InterfaceTextProof.call(forEnglish: "%s", asking: 0))
        XCTAssertNil(InterfaceTextProof.call(forEnglish: "%f", asking: 0))
    }
}

#endif
