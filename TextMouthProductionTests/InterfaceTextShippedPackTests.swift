import Foundation

#if !PACK_PROBE
import XCTest
@testable import TextMouth
#endif

/// What the two proofs that the interface-text pack says what the catalog says have in common (FR39): the counts a line is
/// asked for, and the call an ID makes. The harness (`make l10n-check`) takes an ID's English (the call's format) from the
/// catalog's `en` and Apple's text from tables compiled from the catalog; the hosted test, below, takes both from the
/// catalog.
///
/// `Scripts/l10n/verify_packs.py` (run by `make l10n-check`) compiles this file with the probe
/// `Scripts/l10n/pack-probe/main.swift` and the engine's core files (`-D PACK_PROBE`, which leaves the test class
/// below out), and compares the engine's text with Apple's lookup in a folder compiled from the catalog, in a process of
/// each language. `InterfaceTextShippedPackTests`, below, compares the `Strings.pack` the test host ships with the
/// repository's catalog, in the Mac app and, since the iPhone's unit bundle shares this file, in the iPhone app.
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

/// The interface-text pack (`Strings.pack`) as the built app ships it, in both apps, against the repository's String
/// Catalog (FR39, phases 4 and 8), and the bundle's layout. It is the hosted test that Apple's tables are gone and the
/// pack says what the catalog says.
///
/// - **Every entry** of the pack in every language equals the catalog's text, or its plural forms by category, with the
///   positions of the specifiers read alike. An ID the catalog has no text for in a language has no entry there (the engine
///   shows the English), and a plural whose forms all read alike is one plain text, as `pack.py` writes it.
/// - **Every lookup** through the engine equals `String(format:locale:arguments:)` of the catalog's form for the count,
///   which `PluralRules` picks, at the 13 counts of `InterfaceTextProof`, with the locale a test gives that language
///   (`InterfaceLanguage.locale(forScope:)`: the language with the United States as its region, as `es_US`).
/// - **The bundle** lists the 25 languages, holds an `InfoPlist.strings` in each language's folder, and ships no
///   `Localizable` table of Apple's anywhere.
///
/// **The plural trap.** In a process whose locale is English, Foundation may choose a stringsdict's plural form by the
/// locale's rules rather than the table's language. This test never asks Foundation to choose a form: `PluralRules` picks
/// it, and Foundation only writes it, with an explicit locale that is the language's. Apple's own rule is checked against
/// `PluralRules` where it is meant to be, in `InterfaceTextTests.testApplesPluralRuleAgreesWithTheTableForEveryLanguage`.
///
/// Shared with the iPhone's unit bundle (project.yml), so GitHub checks the iPhone app's pack and bundle too.
final class InterfaceTextShippedPackTests: XCTestCase {
    /// The most differences a failure lists.
    private static let listed = 10

    /// The folder of the app's resources: Contents/Resources in the Mac app, the bundle itself on the iPhone.
    private var resources: URL { Bundle.main.resourceURL ?? Bundle.main.bundleURL }

    /// What every test needs: the shipped pack, the repository's catalog (the English and the text of each ID), and the
    /// catalog's languages.
    private struct Shipped {
        let pack: InterfaceTextPack
        let ids: [String]
        let catalog: LanguagePackCatalog
        let languages: [String]
    }

    /// The pack the host ships and the repository's catalog; fails with what is missing.
    private func shipped() throws -> Shipped {
        let packURL = resources.appendingPathComponent("\(InterfaceTextPack.resourceName).\(InterfaceTextPack.resourceExtension)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: packURL.path), "the host ships no Strings.pack in \(resources.path)")
        let pack = try InterfaceTextPack(contentsOf: packURL)
        let catalog = try LanguagePackCatalog.load()
        let list = try pack.idList()
        return Shipped(pack: pack, ids: (0..<list.count).map { list.id(at: $0) }, catalog: catalog, languages: catalog.languages)
    }

    /// `entry` with its specifiers given positions (`InterfaceTextProof.withPositions`), so that forms that read alike
    /// compare equal whether or not they number their specifiers.
    private func positioned(_ entry: InterfaceTextEntry) -> InterfaceTextEntry {
        switch entry {
        case .absent: return .absent
        case .plain(let text): return .plain(InterfaceTextProof.withPositions(text))
        case .plural(let forms):
            // A plural whose forms all read alike is a plain text: the pack writes it so in every language.
            let numbered = forms.map(InterfaceTextProof.withPositions)
            return Set(numbered).count == 1 ? .plain(numbered[0]) : .plural(numbered)
        }
    }

    // MARK: - Every entry

    /// The pack holds every ID of the catalog, once, and a blob for each of the catalog's languages, which are the 25 the
    /// plural rules name.
    func testThePackHoldsEveryLineAndEveryLanguage() throws {
        let host = try shipped()
        XCTAssertEqual(host.ids, host.catalog.texts.keys.sorted(), "the pack's IDs are the catalog's")
        XCTAssertEqual(host.languages, PluralRules.categories.keys.sorted(), "the catalog's languages are the plural rules'")
        XCTAssertEqual(host.languages.count, 25)
        for language in host.languages { XCTAssertTrue(host.pack.hasLanguage(language), "the pack has no \(language) blob") }
    }

    /// Every entry of every language of the pack equals the catalog's text or plural forms for its ID, the specifiers'
    /// positions read alike. An ID the catalog has no text for in a language has no translation there: the pack has no
    /// entry for it (the engine shows the English).
    func testEveryEntryEqualsTheCatalog() throws {
        let host = try shipped()
        var compared = 0
        var wrong: [String] = []
        for language in host.languages {
            let entries = try host.pack.entries(language: language)
            for (position, id) in host.ids.enumerated() {
                compared += 1
                let want = host.catalog.entry(of: id, language: language)
                if positioned(entries[position]) != positioned(want) {
                    wrong.append("\(language) \(id): pack \(entries[position]), catalog \(want)")
                }
            }
        }
        XCTAssertEqual(compared, host.ids.count * host.languages.count)
        XCTAssertTrue(wrong.isEmpty, "\(wrong.count) entries differ; the first:\n" + wrong.prefix(Self.listed).joined(separator: "\n"))
    }

    // MARK: - Every lookup

    /// Every lookup through the engine, for every ID of every language at every asking, equals Foundation's
    /// `String(format:locale:arguments:)` of the catalog's form for the same call. The time is printed for the report.
    func testEveryLookupEqualsFoundationsFormatOfTheCatalogsForm() throws {
        let host = try shipped()
        let log = InterfaceTextReportLog()
        let engine = InterfaceTextEngine(tables: host.pack, report: log.sink)
        let started = Date()
        var compared = 0
        var wrong: [String] = []
        for language in host.languages {
            let locale = InterfaceLanguage.locale(forScope: language)
            for id in host.ids {
                // The ID's English, as the code writes it: the call's format.
                guard let source = host.catalog.english(of: id) else { wrong.append("\(language) \(id): the catalog has no English"); continue }
                // The catalog's entry, else English's (the engine's fallback), else the call's own English; and the language
                // whose plural rules choose the form: the entry's own, or English's for the fallback.
                let own = host.catalog.entry(of: id, language: language)
                let english = language == "en" ? InterfaceTextEntry.absent : host.catalog.entry(of: id, language: "en")
                let entry: InterfaceTextEntry = own != .absent ? own : (english != .absent ? english : .plain(source))
                let rules = own == .absent ? "en" : language
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

    // MARK: - The person's file

    /// A fill and an Export of every one of the 25 languages, made from the shipped pack, read back with no line ignored: a
    /// fill leaves every line unchanged (each equals its `base`), an Export applies every line in full, and the plural lines
    /// are `plural` in every language, though the pack stores a plural whose forms read alike as one text. Then one file
    /// filled for all 25 languages, the largest the app writes, is read, not refused for its size. The sizes are printed.
    func testAFillAndAnExportOfEveryLanguageReadBackWithNoLineIgnored() throws {
        let host = try shipped()
        let engine = InterfaceTextEngine(tables: host.pack, report: { _ in })
        let english = try XCTUnwrap(engine.reference(language: "en"))
        var wrong: [String] = []
        var everyLanguage: Data?
        var sizes: [String] = []
        for language in host.languages {
            let reference = try XCTUnwrap(engine.reference(language: language))
            let fill = try XCTUnwrap(InterfaceTextOverridesWriter.filled(existing: nil, reference: reference), "no fill for \(language)")
            let filled = InterfaceTextOverridesFile.read(fill, reference: english)
            if filled.fileProblem != nil || !filled.ignored.isEmpty || !filled.inUse.isEmpty || filled.unchanged != host.ids.count {
                wrong.append("fill \(language): problem \(String(describing: filled.fileProblem)), \(filled.ignored.count) ignored, \(filled.inUse.count) in use, \(filled.unchanged) unchanged")
            }
            let export = InterfaceTextOverridesWriter.export(reference: reference, own: [:])
            let exported = InterfaceTextOverridesFile.read(export, reference: english)
            if exported.fileProblem != nil || !exported.ignored.isEmpty || exported.inUse.count != host.ids.count {
                wrong.append("export \(language): \(exported.ignored.count) ignored, \(exported.inUse.count) in use; first \(exported.ignored.prefix(3))")
            }
            sizes.append("\(language) \(fill.count)")
            everyLanguage = InterfaceTextOverridesWriter.filled(existing: everyLanguage, reference: reference) ?? everyLanguage
        }
        XCTAssertTrue(wrong.isEmpty, "\(wrong.count) differ:\n" + wrong.prefix(Self.listed).joined(separator: "\n"))
        let all = try XCTUnwrap(everyLanguage)
        print("Shipped pack: fill sizes \(sizes.joined(separator: ", ")); all 25 languages in one file: \(all.count) bytes (limit \(InterfaceTextOverridesFile.largestSize))")
        let combined = InterfaceTextOverridesFile.read(all, reference: english)
        XCTAssertNil(combined.fileProblem, "a file filled for all 25 languages is refused: \(all.count) bytes")
        XCTAssertEqual(combined.ignored.count, 0)
        XCTAssertEqual(combined.unchanged, host.ids.count * host.languages.count)
    }

    // MARK: - The bundle

    /// The files a bundle must not hold, by name: Apple's language tables of text (`Localizable.strings`, its plural
    /// `.stringsdict`), the compiled form of a catalog (`.loctable`), and the catalog itself (`.xcstrings`). The pack
    /// carries every line, so a file of these in either app would be a leftover of the build.
    private static func isAppleTable(_ name: String) -> Bool {
        name == "Localizable.strings" || name == "Localizable.stringsdict" || name.hasSuffix(".loctable") || name.hasSuffix(".xcstrings")
    }

    /// The bundle lists the catalog's 25 languages (`CFBundleLocalizations`), each language's `.lproj` holds its
    /// `InfoPlist.strings` (which `pack.py` writes), and no Apple table of the lines ships anywhere in the bundle.
    func testTheBundleKeepsItsLanguagesAndShipsNoAppleTable() throws {
        let host = try shipped()
        // `Bundle.main.localizations` also lists "Base" in a bundle that has such a folder; the interface has none.
        let listed = Set(Bundle.main.localizations).subtracting(["Base"])
        XCTAssertEqual(listed, Set(host.languages), "Bundle.main.localizations is the catalog's languages: \(Bundle.main.localizations)")
        XCTAssertEqual(listed.count, 25)
        for language in host.languages {
            let table = resources.appendingPathComponent("\(language).lproj/InfoPlist.strings")
            XCTAssertTrue(FileManager.default.fileExists(atPath: table.path), "\(language).lproj has no InfoPlist.strings in \(resources.path)")
        }
        var tables: [String] = []
        let walker = FileManager.default.enumerator(at: Bundle.main.bundleURL, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            // The test bundle in PlugIns holds the tool tests' fixture catalogs: it is no part of the app's own language files.
            if url.lastPathComponent == "PlugIns" { walker?.skipDescendants(); continue }
            if Self.isAppleTable(url.lastPathComponent) { tables.append(url.path) }
        }
        XCTAssertTrue(tables.isEmpty, "Apple's language tables ship in the bundle: \(tables.prefix(Self.listed))")
    }

    /// A test build is named "TextMouth Test" in every language, so the Dock, the app switcher, and VoiceOver say which
    /// TextMouth is the tests' when the host comes to the front (the user's request of November 22, 2026). The tests run
    /// the Debug configuration, whose TEXTMOUTH_TEST_DISPLAY_NAME the build phase "Pack interface text" passes to
    /// `pack.py`, which writes it into each `InfoPlist.strings`; the bundle's own `CFBundleDisplayName` stays
    /// "TextMouth", the file's name, as Launch Services needs for a localized name to show. `make check` holds a Release
    /// app to its own name.
    func testATestBuildIsNamedTextMouthTestInEveryLanguage() throws {
        let host = try shipped()
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, "TextMouth Test",
                       "the language the host runs in names the test build")
        XCTAssertEqual(Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String, "TextMouth",
                       "the Info.plist's own name stays the bundle file's, which a localized name needs")
        for language in host.languages {
            let table = resources.appendingPathComponent("\(language).lproj/InfoPlist.strings")
            let entries = NSDictionary(contentsOf: table) as? [String: String]
            XCTAssertEqual(entries?["CFBundleDisplayName"], "TextMouth Test", "\(language).lproj/InfoPlist.strings")
        }
    }

    /// The test of the bundle test: what counts as one of Apple's tables, by name, and what does not (the pack, and the
    /// `InfoPlist.strings` each language keeps).
    func testWhichFilesAreAppleTables() {
        for name in ["Localizable.strings", "Localizable.stringsdict", "Localizable.loctable", "Localizable.xcstrings", "Other.xcstrings"] {
            XCTAssertTrue(Self.isAppleTable(name), name)
        }
        for name in ["Strings.pack", "InfoPlist.strings", "Info.plist", "Localizable", "es.lproj"] {
            XCTAssertFalse(Self.isAppleTable(name), name)
        }
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
