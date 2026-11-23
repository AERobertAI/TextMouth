import Foundation

/// Why one line of the person's file is ignored (FR39). Each is a rule of the check; the interface says it in the
/// person's language (`InterfaceTextOverridesWording`), and the debug log in English (`logSentence`).
enum InterfaceTextIgnoredReason: Equatable, Sendable, CaseIterable {
    /// The line's language is not one the app carries.
    case unknownLanguage
    /// The line's ID is not one the app has.
    case unknownID
    /// The app holds no English for the ID, so there is nothing to compare the line with.
    case noEnglish
    /// The line is not an object, or its `text` or `plural` is of the wrong kind.
    case notALine
    /// The line has neither `text` nor `plural`.
    case noText
    /// The line has both `text` and `plural`.
    case bothTextAndPlural
    /// The line gives `text` for a line that has plural forms.
    case textForPluralLine
    /// The line gives `plural` for a line that has one text.
    case pluralForPlainLine
    /// A specifier other than `%@`, `%lld`, `%n$@`, `%n$lld`, and `%%`, or a lone `%`.
    case unsupportedSpecifier
    /// Numbered (`%1$@`) and unnumbered (`%@`) placeholders mixed in one text.
    case mixedPlaceholders
    /// The placeholders differ from the English's by slot or type.
    case placeholdersDiffer
    /// The count of `%%` differs from the English's.
    case percentSignsDiffer
    /// The plural forms are not exactly the language's categories.
    case wrongPluralForms
    /// A form is empty.
    case emptyForm
    /// A form holds a control character other than a line feed or a tab.
    case controlCharacter
    /// Another key of the file names the same language and has the same line, which is the one in use.
    case shadowed

    /// The reason in English, for the debug log (never shown to a person, who reads
    /// `InterfaceTextOverridesWording.reason`).
    var logSentence: String {
        switch self {
        case .unknownLanguage: return "the language is not one TextMouth carries" // l10n: no (debug log text)
        case .unknownID: return "TextMouth has no line with that ID" // l10n: no (debug log text)
        case .noEnglish: return "TextMouth holds no English for the line" // l10n: no (debug log text)
        case .notALine: return "it is not an object with a text or plural forms" // l10n: no (debug log text)
        case .noText: return "it has neither text nor plural" // l10n: no (debug log text)
        case .bothTextAndPlural: return "it has both text and plural" // l10n: no (debug log text)
        case .textForPluralLine: return "it gives text for a line with plural forms" // l10n: no (debug log text)
        case .pluralForPlainLine: return "it gives plural forms for a line with one text" // l10n: no (debug log text)
        case .unsupportedSpecifier: return "it has a specifier other than the five, or a lone percent sign" // l10n: no (debug log text)
        case .mixedPlaceholders: return "it mixes numbered and unnumbered placeholders" // l10n: no (debug log text)
        case .placeholdersDiffer: return "its placeholders differ from the English's" // l10n: no (debug log text)
        case .percentSignsDiffer: return "its count of percent signs (%%) differs from the English's" // l10n: no (debug log text)
        case .wrongPluralForms: return "its plural forms are not the language's" // l10n: no (debug log text)
        case .emptyForm: return "a form is empty" // l10n: no (debug log text)
        case .controlCharacter: return "a form has a control character" // l10n: no (debug log text)
        case .shadowed: return "another key names the same language and has the same line, which is the one in use" // l10n: no (debug log text)
        }
    }
}

/// Why a whole file is ignored (FR39): it is not the shape the file has.
enum InterfaceTextFileProblem: Equatable, Sendable, CaseIterable {
    /// The file is not JSON.
    case notJSON
    /// The file is JSON, but not an object of `languages`, each holding `lines`, each an object.
    case notThisShape
    /// The file's `version` is not one this TextMouth reads.
    case unknownVersion
    /// The file is larger than any real one.
    case tooLarge
    /// The file exists and could not be read.
    case unreadable
    /// What the file's name holds is not a regular file (a folder, a pipe, a link to nothing).
    case notARegularFile

    /// The problem in English, for the debug log.
    var logSentence: String {
        switch self {
        case .notJSON: return "the file is not JSON" // l10n: no (debug log text)
        case .notThisShape: return "the file is not an object of languages, each holding lines" // l10n: no (debug log text)
        case .unknownVersion: return "the file's version is not one TextMouth reads" // l10n: no (debug log text)
        case .tooLarge: return "the file is larger than any file of lines can be" // l10n: no (debug log text)
        case .unreadable: return "the file could not be read" // l10n: no (debug log text)
        case .notARegularFile: return "what the file's name holds is not a regular file" // l10n: no (debug log text)
        }
    }
}

/// What reading the person's file came to: the lines that apply, the lines ignored and why, and the lines in use whose
/// English the code has changed since (FR39).
struct InterfaceTextOverridesOutcome: Equatable, Sendable {
    /// One line of one language.
    struct Key: Hashable, Comparable, Sendable {
        let language: String
        let id: String

        static func < (lhs: Key, rhs: Key) -> Bool {
            (lhs.language, lhs.id) < (rhs.language, rhs.id)
        }
    }

    /// A line that is ignored, with the reason.
    struct Ignored: Equatable, Sendable {
        /// The line as the file names it (its language as written, so a report names what the person wrote).
        let key: Key
        let reason: InterfaceTextIgnoredReason
        /// Whether the ID is one the app has, and the language the app carries that the written one names (nil when none):
        /// only those go to the debug log, and the carried language by its own code, never the key as written (`es-my note`
        /// names Spanish, and is the person's own text); any other key is logged as its length.
        var idIsKnown = true
        var carriedLanguage: String?
    }

    /// The person's own lines that apply: language, then ID, as the engine takes them.
    var lines: [String: [String: InterfaceTextEntry]] = [:]
    /// The lines that apply, in order.
    var inUse: [Key] = []
    /// The lines that are ignored, in order of language and ID.
    var ignored: [Ignored] = []
    /// The lines in use whose `english` differs from the line's English now: the English changed after the line was
    /// written, so the line may say something else than the line it replaces.
    var outdatedEnglish: [Key] = []
    /// How many lines were left alone because the person did not change them (their text is their `base`).
    var unchanged = 0
    /// Set when the whole file is ignored.
    var fileProblem: InterfaceTextFileProblem?

    /// Nothing read: no file, or an empty one.
    static let empty = InterfaceTextOverridesOutcome()

    /// A file ignored whole, for `problem`.
    static func ignoredWhole(_ problem: InterfaceTextFileProblem) -> InterfaceTextOverridesOutcome {
        var outcome = InterfaceTextOverridesOutcome()
        outcome.fileProblem = problem
        return outcome
    }
}

/// The person's file of own lines, `interface_text.json` (FR39): read and checked against the pack, line by line.
///
/// The shape, which Export Interface Text writes too:
///
///     {"version": 1, "languages": {"es": {"lines": {
///       "common.sleepTimer": {"text": "Temporizador", "base": "Temporizador de apagado",
///                             "english": "Sleep Timer", "note": "The sleep timer's title."},
///       "common.countMinutes": {"plural": {"one": "%lld minuto", "many": "%lld de minutos", "other": "%lld minutos"},
///                               "basePlural": {"one": "%lld minuto", "many": "%lld de minutos", "other": "%lld minutos"}}
///     }}}}
///
/// - **A line applies** when its `text` differs from its `base` (or its `plural` from its `basePlural`), that is, the
///   person changed it; or when it has no `base` at all, that is, written by hand or copied from someone else's Export.
///   A line left alone never applies, so it keeps taking each update's better wording.
/// - **`english` and `note` are context only.** When a line applies and its `english` is not the line's English now, the
///   outcome says so, and the line still applies.
/// - **A line is ignored, with a reason, when** its language or ID is unknown, it has the wrong shape for the line, a
///   form is empty or holds a control character other than a line feed or a tab, its plural forms are not exactly the
///   language's, or its placeholders break the rules of `FormatSpecifiers`: only the five specifiers, no mixing of
///   numbered and unnumbered, the English's slots and types (in any order, with positions), the English's count of `%%`.
/// - **A file that is not this shape is ignored whole**, with one reason. A missing file is no lines and no problem.
///
/// The check never reaches Foundation's formatter: a text is only parsed by `FormatSpecifiers`, the engine's own check.
/// Foundation only.
enum InterfaceTextOverridesFile {
    /// The version of the shape this reads and writes.
    static let version = 1

    /// The largest file read. A fill of one language is 1.8 to 2.2 MB and a full Export 1.5 to 1.7 MB (measured on the
    /// shipped pack), so a file filled for all 25 languages is about 50 MB; this is above that, and below what a person's
    /// editor or the parser could not hold.
    static let largestSize = 64 * 1024 * 1024

    // MARK: - Reading

    /// The outcome of reading `data`, the bytes of the file, against `reference`.
    static func read(_ data: Data, reference: InterfaceTextReference) -> InterfaceTextOverridesOutcome {
        guard data.count <= largestSize else { return .ignoredWhole(.tooLarge) }
        if isBlank(data) { return .empty }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else { return .ignoredWhole(.notJSON) }
        guard let root = parsed as? [String: Any] else { return .ignoredWhole(.notThisShape) }
        // A missing version is read as this one, for a file written by hand.
        if let given = root["version"] {
            guard let number = given as? Int, number == version else { return .ignoredWhole(.unknownVersion) }
        }
        guard let languages = root["languages"] as? [String: Any] else { return .ignoredWhole(.notThisShape) }

        // The whole file is checked for its shape before any line, so a file that is not this shape applies nothing.
        var shaped: [(language: String, lines: [String: Any])] = []
        for language in languages.keys.sorted() {
            guard let body = languages[language] as? [String: Any], let lines = body["lines"] as? [String: Any] else {
                return .ignoredWhole(.notThisShape)
            }
            shaped.append((language, lines))
        }

        var outcome = InterfaceTextOverridesOutcome()
        for (written, lines) in shaped {
            // A language is named as the rest of the app names one: `pt` and `zh` and `es-MX` are carried languages.
            let language = InterfaceLanguage.carriedLanguage(written)
            for id in lines.keys.sorted() {
                let key = InterfaceTextOverridesOutcome.Key(language: written, id: id)
                switch read(line: lines[id] ?? NSNull(), id: id, language: language, reference: reference) {
                case .unchanged:
                    outcome.unchanged += 1
                case .ignored(let reason):
                    outcome.ignored.append(.init(
                        key: key, reason: reason, idIsKnown: reference.index(of: id) != nil, carriedLanguage: language
                    ))
                case .applies(let entry, let outdated):
                    // In use under the carried language's name, which the engine's lookups use. Two keys that name one language
                    // (`pt` and `pt-BR`) may both have a line: the first, in order of the keys, is in use, and the other is
                    // ignored and says so, not silently in its place.
                    let carried = language ?? written
                    if outcome.lines[carried]?[id] != nil {
                        outcome.ignored.append(.init(key: key, reason: .shadowed, idIsKnown: true, carriedLanguage: language))
                        continue
                    }
                    outcome.lines[carried, default: [:]][id] = entry
                    let used = InterfaceTextOverridesOutcome.Key(language: carried, id: id)
                    outcome.inUse.append(used)
                    if outdated { outcome.outdatedEnglish.append(used) }
                }
            }
        }
        return outcome
    }

    /// Whether `data` holds only whitespace: a file the person has not filled yet, or made empty.
    static func isBlank(_ data: Data) -> Bool {
        data.allSatisfy { [0x20, 0x09, 0x0A, 0x0D].contains($0) }
    }

    /// What one line comes to.
    private enum LineResult {
        /// The person left it as it was: it never applies.
        case unchanged
        case ignored(InterfaceTextIgnoredReason)
        /// It applies as `entry`; `outdated` when its `english` is not the English now.
        case applies(InterfaceTextEntry, outdated: Bool)
    }

    /// One line, checked in the order of the rules: its shape, whether the person changed it, its language and ID, and
    /// then its text.
    private static func read(line raw: Any, id: String, language: String?, reference: InterfaceTextReference) -> LineResult {
        guard let object = raw as? [String: Any] else { return .ignored(.notALine) }
        let hasText = object["text"] != nil
        let hasPlural = object["plural"] != nil
        if hasText && hasPlural { return .ignored(.bothTextAndPlural) }
        guard hasText || hasPlural else { return .ignored(.noText) }
        guard let wording = InterfaceTextWording(json: object[hasText ? "text" : "plural"]), isCorrectKind(wording, hasText: hasText) else {
            return .ignored(.notALine)
        }

        // A line the person did not change never applies, whatever else is wrong with it, so an update that retires or
        // reshapes a line does not leave the person a list of lines they never touched.
        if let base = InterfaceTextWording(json: object[hasText ? "base" : "basePlural"]), base == wording {
            return .unchanged
        }

        guard let language else { return .ignored(.unknownLanguage) }
        guard let index = reference.index(of: id) else { return .ignored(.unknownID) }
        guard let english = reference.englishWording(at: index) else { return .ignored(.noEnglish) }
        if let reason = problem(with: wording, english: english, language: language) {
            return .ignored(reason)
        }
        guard let entry = wording.entry(language: language) else { return .ignored(.wrongPluralForms) }
        let writtenEnglish = InterfaceTextWording(json: object["english"])
        return .applies(entry, outdated: writtenEnglish.map { $0 != english } ?? false)
    }

    /// Whether `wording` is the kind the line's key named: a string for `text`, an object for `plural`.
    private static func isCorrectKind(_ wording: InterfaceTextWording, hasText: Bool) -> Bool {
        switch wording {
        case .text: return hasText
        case .plural: return !hasText
        }
    }

    // MARK: - The rules of a line

    /// The first rule `wording` breaks against `english` (the line's English) in `language`, nil when it breaks none.
    static func problem(with wording: InterfaceTextWording, english: InterfaceTextWording, language: String) -> InterfaceTextIgnoredReason? {
        switch (wording, english) {
        case (.text(let text), .text(let reference)):
            return problem(inForm: text, against: reference, mayDropNumbers: false)
        case (.plural(let forms), .plural(let englishForms)):
            guard let names = PluralRules.categories[language], Set(forms.keys) == Set(names) else { return .wrongPluralForms }
            // The English `other` is the form that always shows the number: every form is compared with it.
            guard let reference = englishForms["other"] else { return .noEnglish }
            for name in names {
                // A `one` form may leave the number out where it means exactly 1 ("un libro").
                let mayDrop = name == "one" && oneMeansExactlyOne.contains(language)
                if let reason = problem(inForm: forms[name] ?? "", against: reference, mayDropNumbers: mayDrop) { return reason }
            }
            return nil
        case (.text, .plural):
            return .textForPluralLine
        case (.plural, .text):
            return .pluralForPlainLine
        }
    }

    /// The languages whose `one` form is for the number 1 alone, so that it may say "one" in words: not French (`one`
    /// covers 0), Russian (21, 31, ...), or Hindi. Decided from `PluralRules` on the whole numbers up to 1000, as the
    /// catalog tool decides it from CLDR's.
    private static let oneMeansExactlyOne: Set<String> = Set(PluralRules.categories.keys.filter { language in
        (0...1000).filter { PluralRules.category(of: $0, language: language) == "one" } == [1]
    })

    /// The first rule one form `text` breaks against the English text `reference`.
    private static func problem(inForm text: String, against reference: String, mayDropNumbers: Bool) -> InterfaceTextIgnoredReason? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyForm }
        if text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t" }) {
            return .controlCharacter
        }
        // An English text that holds a lone `%` is a line of no arguments ("Save 50%"): the lookup never formats it, so
        // neither it nor any text of the person's for it has specifiers to check.
        guard let wanted = FormatSpecifiers.parse(reference) else { return nil }
        // The specifiers of the person's text: the engine's own check parses them (only the five, no lone `%`).
        guard let found = FormatSpecifiers.parse(text) else { return .unsupportedSpecifier }
        guard !FormatSpecifiers.mixesNumbering(found.slots) else { return .mixedPlaceholders }
        guard let got = FormatSpecifiers.argumentKinds(of: found.slots), let wantedKinds = FormatSpecifiers.argumentKinds(of: wanted.slots) else {
            return .placeholdersDiffer
        }
        for (argument, kind) in wantedKinds where got[argument] == nil {
            // Only a number may be left out, and only where the form is allowed to.
            if !(mayDropNumbers && kind == .number) { return .placeholdersDiffer }
        }
        for (argument, kind) in got where wantedKinds[argument] != kind { return .placeholdersDiffer }
        guard found.percentSigns == wanted.percentSigns else { return .percentSignsDiffer }
        return nil
    }
}
