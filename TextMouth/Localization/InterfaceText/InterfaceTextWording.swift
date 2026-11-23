import Foundation

/// One line's wording as the person's file holds it (FR39): a text, or the forms of a plural line by the name of their
/// category (`one`, `many`, `other`, ...). The pack's entries (`InterfaceTextEntry`) hold plural forms by position, in
/// the language's category order; this holds them by name, which is how a person reads and edits them.
///
/// Foundation only, like the rest of the engine's core.
enum InterfaceTextWording: Equatable, Sendable {
    /// A text for every count.
    case text(String)
    /// The forms of a plural line, by category name.
    case plural([String: String])

    // MARK: - From and to the pack's entries

    /// The wording of `entry` in `language`; nil for an entry with no text, and for a plural entry whose form count is
    /// not the language's (which the pack reader refuses, so it does not happen).
    init?(entry: InterfaceTextEntry, language: String) {
        switch entry {
        case .absent:
            return nil
        case .plain(let text):
            self = .text(text)
        case .plural(let forms):
            guard let names = PluralRules.categories[language], names.count == forms.count else { return nil }
            self = .plural(Dictionary(uniqueKeysWithValues: zip(names, forms)))
        }
    }

    /// The entry this wording stands for in `language`; nil for plural forms that are not exactly the language's
    /// categories, or for a language with no rule.
    func entry(language: String) -> InterfaceTextEntry? {
        switch self {
        case .text(let text):
            return .plain(text)
        case .plural(let forms):
            guard let names = PluralRules.categories[language], Set(forms.keys) == Set(names) else { return nil }
            return .plural(names.compactMap { forms[$0] })
        }
    }

    /// This wording, an English one, as the line would read in `language` where the pack has no text of its own: a text
    /// as it is, and each plural form of `language` taken from the English form of the same name, else from `other`
    /// (Spanish's `many` is English's `other`).
    func adapted(toLanguage language: String) -> InterfaceTextWording {
        guard case .plural(let forms) = self, let names = PluralRules.categories[language] else { return self }
        let fallback = forms["other"] ?? forms.values.first ?? "" // l10n: no (a plural category's name)
        return .plural(Dictionary(uniqueKeysWithValues: names.map { ($0, forms[$0] ?? fallback) }))
    }

    // MARK: - From and to JSON

    /// The wording a JSON value stands for: a string is a text, an object of strings is plural forms; nil for anything
    /// else (a number, a list, an object holding a non-string).
    init?(json: Any?) {
        if let text = json as? String {
            self = .text(text)
        } else if let forms = json as? [String: Any] {
            var named: [String: String] = [:]
            for (name, form) in forms {
                guard let text = form as? String else { return nil }
                named[name] = text
            }
            self = .plural(named)
        } else {
            return nil
        }
    }

    /// The JSON value of this wording: a string, or an object of strings.
    var json: Any {
        switch self {
        case .text(let text): return text
        case .plural(let forms): return forms
        }
    }

    /// Every text of the wording, in a fixed order (a text, or the forms by category name).
    var texts: [String] {
        switch self {
        case .text(let text): return [text]
        case .plural(let forms): return forms.keys.sorted().compactMap { forms[$0] }
        }
    }
}

/// What the person's file is read and written against: the pack's IDs, English, and notes, and the entries of one
/// language, as the engine holds them (`InterfaceTextEngine.reference(language:)`). The person's own lines are not in it.
struct InterfaceTextReference: Sendable {
    /// The IDs, in the pack's order.
    let ids: InterfaceTextIDList
    /// The English entry of each ID.
    let english: [InterfaceTextEntry]
    /// The translators' note of each ID ("" for none); empty when the pack has none.
    let notes: [String]
    /// The language `entries` are for.
    let language: String
    /// The entry of each ID in `language`; empty when the language's table is unavailable.
    let entries: [InterfaceTextEntry]

    /// The position of `id` among the IDs, or nil when it is not one.
    func index(of id: String) -> Int? {
        Array(id.utf8).withUnsafeBufferPointer { ids.index(ofUTF8: $0) }
    }

    /// The English wording of the line at `index`; nil when the pack has none.
    func englishWording(at index: Int) -> InterfaceTextWording? {
        english.indices.contains(index) ? InterfaceTextWording(entry: english[index], language: "en") : nil // l10n: no (a language code)
    }

    /// The note of the line at `index`, "" for none.
    func note(at index: Int) -> String {
        notes.indices.contains(index) ? notes[index] : ""
    }

    /// The wording of the line at `index` in the language as the pack has it: its own text, else the English adapted to
    /// the language (a line the translators have not reached shows its English).
    func wording(at index: Int) -> InterfaceTextWording? {
        if entries.indices.contains(index), let own = InterfaceTextWording(entry: entries[index], language: language) {
            return own
        }
        return englishWording(at: index)?.adapted(toLanguage: language)
    }
}
