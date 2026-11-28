import Foundation

#if !PACK_PROBE
import XCTest
@testable import TextMouth
#endif

/// The lookups and the catalog reading that two checks of the interface-text pack share (FR39): how a format's arguments
/// are made, and how Apple's own lookup is asked, and the catalog the repository holds.
///
/// `Scripts/l10n/verify_packs.py` (run by `make l10n-check`) compiles this file with `Scripts/l10n/pack-probe/main.swift`
/// (`-D PACK_PROBE`, which leaves the catalog reading out) to compare the engine with Apple's own lookup, in a folder
/// that `xcstringstool` compiles from the catalog: the apps ship no Apple table. The hosted tests
/// (`InterfaceTextShippedPackTests`, `InterfaceTextTests`, and `SpanishLocalizationTests`) use the same lookups and the
/// catalog reading. The class that read the apps' own tables, `LanguagePackTests` (TL16), went with them (FR39 phase 8);
/// this file keeps its name.
///
/// `LanguagePackLookups` holds no stored state and uses Foundation only, so it compiles in a command-line tool.
enum LanguagePackLookups {
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

    /// The arguments a format takes, in argument order, with `count` for every count: a text is "text". The format is the
    /// string's English (the catalog is keyed by ID, so the key says nothing of its specifiers). Nil when
    /// `specifiers(in:)` cannot read it.
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

    /// The text Apple's lookup gives for `key` in `bundle`: the bundle's table text, or the key itself when no table holds
    /// it, as `String(localized:)` does. The harness reads Apple's tables this way, in a folder compiled from the catalog,
    /// and the plural-rule test reads its own sandbox tables this way.
    static func effectiveText(_ bundle: Bundle, key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }
}

#if !PACK_PROBE

/// The catalog's strings, read from the repository: the source the pack is built from.
struct LanguagePackCatalog {
    /// One string of the catalog in one language: its simple text, or its plural forms by category.
    enum Text: Equatable {
        case simple(String)
        case plural([String: String])
    }

    /// Every string by ID, then language, holding only what the pack builds: a text in the state `new` (an English
    /// text the code has not been translated from) is not shipped, so it is left out here too.
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

    /// The text of a `stringUnit` that the pack builds: any state but `new`.
    private static func unit(_ value: Any?) -> String? {
        guard let unit = value as? [String: Any], unit["state"] as? String != "new" else { return nil }
        return unit["value"] as? String
    }

    /// The IDs that have a text in `language`, sorted: every ID, simple and plural alike.
    func keys(in language: String) -> [String] {
        texts.filter { $0.value[language] != nil }.map(\.key).sorted()
    }

    /// Every language the catalog holds a text in, English included, sorted.
    var languages: [String] {
        Set(texts.values.flatMap { $0.keys }).sorted()
    }

    /// The English of the string `key` (an ID) as the code writes it: its English text, or a plural's `other` form; nil
    /// when the catalog holds no English for it.
    func english(of key: String) -> String? {
        switch texts[key]?["en"] {
        case .simple(let text)?: return text
        case .plural(let forms)?: return forms["other"]
        case nil: return nil
        }
    }

    /// The entry the pack holds for `id` in `language` (see `pack.py`'s `compile_localization`): nothing for no text (or an
    /// empty one), a plain text, or a plural's forms in the language's category order, squeezed to one plain text when every
    /// form is the same (the rule of `pack.py`'s `squeeze_forms`). A plural in a language with no rules comes back with the
    /// forms it has, in name order, so that a comparison with the pack's entry fails and names it.
    func entry(of id: String, language: String) -> InterfaceTextEntry {
        switch texts[id]?[language] {
        case .simple(let text)?:
            return text.isEmpty ? .absent : .plain(text)
        case .plural(let forms)?:
            guard let categories = PluralRules.categories[language] else { return .plural(forms.keys.sorted().map { forms[$0] ?? "" }) }
            let ordered = categories.compactMap { forms[$0] }
            return Set(ordered).count == 1 && categories.contains("other") ? .plain(ordered[0]) : .plural(ordered)
        case nil:
            return .absent
        }
    }
}

#endif
