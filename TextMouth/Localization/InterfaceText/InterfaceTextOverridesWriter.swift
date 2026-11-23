import Foundation

/// The one writer of the person's file of own lines (FR39), for both commands that write it: Edit Interface Text… fills
/// `interface_text.json` with the lines of the interface language as they read now, and Export Interface Text… writes the
/// lines of the interface language as they read now, the person's own lines included, to a file the person chooses. Both
/// write the shape `InterfaceTextOverridesFile` reads, one language's `lines`; they differ in two fields of each line:
///
/// - the fill writes `base`, the pack's text when the file was written (or `basePlural`), so that a line the person
///   leaves alone keeps taking each update's better wording;
/// - the export writes no `base`, and `"changed": true` on the lines that are the person's own, so that what someone else
///   imports applies in full.
///
/// A line is written in a fixed order, so that a VoiceOver or braille reader meets the field to edit first and its twin
/// last: `text` or `plural` (its forms in the language's own category order), then `english`, then `note`, then `base` or
/// `basePlural` (or, in an export, `changed`). The same input is always the same bytes. A line is plural when its English
/// is (`InterfaceTextReference.isPlural`), whatever the pack stores for the language.
///
/// Nothing else writes the file: no launch, sync, or move of the data folder does. Foundation only.
enum InterfaceTextOverridesWriter {
    // MARK: - Edit Interface Text…

    /// The bytes of `interface_text.json` with the interface language added, or nil when the file is to be left as it is.
    ///
    /// - A missing (or empty) file is made, holding the interface language alone.
    /// - A file that lacks the interface language gets it; every other language is kept as it was.
    /// - A file that already has the language is left alone, whatever its lines: the person's edits are theirs. So is a
    ///   file that is not JSON or not the file's shape, which the person is mending, and one whose `version` this TextMouth
    ///   does not know (`hasUnknownVersion`).
    ///
    /// - Parameters:
    ///   - existing: The file's bytes now, nil when there is no file.
    ///   - reference: The pack's lines for the interface language (`reference.language`).
    static func filled(existing: Data?, reference: InterfaceTextReference) -> Data? {
        let added = Node.object([("lines", lines(of: reference, own: [:], forExport: false))])
        guard let existing, !InterfaceTextOverridesFile.isBlank(existing) else {
            return root(languages: [(reference.language, added)]).rendered
        }
        guard let parsed = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any],
              !hasUnknownVersion(parsed),
              let languages = parsed["languages"] as? [String: Any],
              languages[reference.language] == nil
        else { return nil }
        // Every other part of the file as it was: its other top-level keys, and each other language's lines.
        var kept = parsed
        kept["languages"] = nil
        kept["version"] = nil
        let others = kept.keys.sorted().map { ($0, Node(any: kept[$0] ?? NSNull())) }
        // Each other language keeps its lines, in the fixed order of a line (a person's editor may have put `base` first).
        let all = (languages.keys.sorted().map { ($0, Node.existingLanguage(languages[$0] ?? NSNull(), code: $0)) } + [(reference.language, added)])
            .sorted { $0.0 < $1.0 }
        return root(languages: all, others: others).rendered
    }

    /// Whether the file's `version` is one this TextMouth does not read: Edit leaves such a file as it is, and says so.
    static func hasUnknownVersion(_ existing: Data) -> Bool {
        guard let parsed = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else { return false }
        return hasUnknownVersion(parsed)
    }

    private static func hasUnknownVersion(_ root: [String: Any]) -> Bool {
        guard let given = root["version"] else { return false }
        return (given as? Int) != InterfaceTextOverridesFile.version
    }

    // MARK: - Export Interface Text…

    /// The bytes an Export writes: every line of the interface language as it reads now, each with its English and its
    /// note, the person's own lines (`own`, by ID) in place of the pack's and marked `"changed": true`, and no `base`.
    static func export(reference: InterfaceTextReference, own: [String: InterfaceTextEntry]) -> Data {
        let language = Node.object([("lines", lines(of: reference, own: own, forExport: true))])
        return root(languages: [(reference.language, language)]).rendered
    }

    // MARK: - The lines

    /// The file: its version, then its other keys, then its languages.
    private static func root(languages: [(String, Node)], others: [(String, Node)] = []) -> Node {
        .object([("version", .int(InterfaceTextOverridesFile.version))] + others + [("languages", .object(languages))])
    }

    /// One object for each line of the pack, in the pack's order of IDs.
    private static func lines(of reference: InterfaceTextReference, own: [String: InterfaceTextEntry], forExport: Bool) -> Node {
        var lines: [(String, Node)] = []
        for index in 0..<reference.ids.count {
            let id = reference.ids.id(at: index)
            guard let english = reference.englishWording(at: index) else { continue }
            // The person's own line where one applies (the export only: the fill is made where there is none).
            let ownWording = own[id].flatMap { InterfaceTextWording(entry: $0, language: reference.language) }
            guard let wording = ownWording ?? reference.wording(at: index) else { continue }

            var line: [(String, Node)] = []
            let twin: (String, Node)
            switch wording {
            case .text(let text):
                line.append(("text", .string(text)))
                twin = ("base", .string(text))
            case .plural(let forms):
                let node = Node.forms(forms, language: reference.language)
                line.append(("plural", node))
                twin = ("basePlural", node)
            }
            line.append(("english", english.node(language: "en")))
            let note = reference.note(at: index)
            if !note.isEmpty { line.append(("note", .string(note))) }
            if forExport {
                if ownWording != nil { line.append(("changed", .bool(true))) }
            } else {
                line.append(twin)
            }
            lines.append((id, .object(line)))
        }
        return .object(lines)
    }
}

// MARK: - Ordered JSON

/// JSON in an order the writer chooses, since `JSONSerialization` can only sort keys: indented with two spaces, strings with
/// only the escapes JSON needs, and every other letter as it is.
private indirect enum Node {
    case string(String)
    case int(Int)
    /// A number of someone's file, as JSON writes it (`0.5`, a whole number past `Int`'s range).
    case number(String)
    case bool(Bool)
    case null
    case array([Node])
    case object([(String, Node)])

    /// Plural forms in the order of `language`'s categories (the forms the language lacks, last, by name).
    static func forms(_ forms: [String: String], language: String) -> Node {
        let order = PluralRules.categories[language] ?? []
        let named = order.filter { forms[$0] != nil } + forms.keys.filter { !order.contains($0) }.sorted()
        return .object(named.map { ($0, .string(forms[$0] ?? "")) })
    }

    /// A node for what `JSONSerialization` parsed, its objects' keys sorted (a part of someone's file keeps its content,
    /// not its order).
    init(any value: Any) {
        switch value {
        case let text as String:
            self = .string(text)
        case let number as NSNumber:
            // A boolean is an NSNumber too; its type code tells it from a number.
            if String(cString: number.objCType) == "c" {
                self = .bool(number.boolValue)
            } else if let data = try? JSONSerialization.data(withJSONObject: number, options: [.fragmentsAllowed]) {
                self = .number(String(decoding: data, as: UTF8.self))
            } else {
                self = .null
            }
        case let list as [Any]:
            self = .array(list.map(Node.init(any:)))
        case let object as [String: Any]:
            self = .object(object.keys.sorted().map { ($0, Node(any: object[$0] ?? NSNull())) })
        default:
            self = .null
        }
    }

    /// A language of someone's file that Edit does not fill: its content as it was, with each line's fields in the fixed order
    /// (`text` or `plural`, `english`, `note`, `base` or `basePlural`, `changed`, then any other field by name) and its plural
    /// forms in the language's own order. `code` is the key the file names the language by.
    static func existingLanguage(_ value: Any, code: String) -> Node {
        guard let body = value as? [String: Any] else { return Node(any: value) }
        return .object(body.keys.sorted().map { key -> (String, Node) in
            guard key == "lines", let lines = body[key] as? [String: Any] else { return (key, Node(any: body[key] ?? NSNull())) }
            return (key, .object(lines.keys.sorted().map { ($0, existingLine(lines[$0] ?? NSNull(), code: code)) }))
        })
    }

    /// One line of someone's file in the fixed order of a line.
    private static func existingLine(_ value: Any, code: String) -> Node {
        guard let line = value as? [String: Any] else { return Node(any: value) }
        let first = ["text", "plural", "english", "note", "base", "basePlural", "changed"] // l10n: no (the file's own keys)
        let ordered = first.filter { line[$0] != nil } + line.keys.filter { !first.contains($0) }.sorted()
        let language = InterfaceLanguage.carriedLanguage(code) ?? code
        return .object(ordered.map { key -> (String, Node) in
            if ["plural", "basePlural", "english"].contains(key), let forms = line[key] as? [String: String] { // l10n: no (the file's own keys)
                return (key, .forms(forms, language: key == "english" ? "en" : language)) // l10n: no (a language code)
            }
            return (key, Node(any: line[key] ?? NSNull()))
        })
    }

    /// The UTF-8 bytes, with a line feed at the end.
    var rendered: Data {
        var out = ""
        write(into: &out, depth: 0)
        out += "\n"
        return Data(out.utf8)
    }

    private func write(into out: inout String, depth: Int) {
        let inner = String(repeating: "  ", count: depth + 1)
        let outer = String(repeating: "  ", count: depth)
        switch self {
        case .string(let text): out += Self.quoted(text)
        case .int(let number): out += String(number)
        case .number(let text): out += text
        case .bool(let flag): out += flag ? "true" : "false"
        case .null: out += "null"
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (index, item) in items.enumerated() {
                out += inner
                item.write(into: &out, depth: depth + 1)
                out += index == items.count - 1 ? "\n" : ",\n"
            }
            out += outer + "]"
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (index, member) in members.enumerated() {
                out += inner + Self.quoted(member.0) + ": "
                member.1.write(into: &out, depth: depth + 1)
                out += index == members.count - 1 ? "\n" : ",\n"
            }
            out += outer + "}"
        }
    }

    /// `text` as a JSON string: quotes, backslashes, and control characters escaped.
    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

private extension InterfaceTextWording {
    /// This wording as a node: a string, or plural forms in `language`'s category order.
    func node(language: String) -> Node {
        switch self {
        case .text(let text): return .string(text)
        case .plural(let forms): return .forms(forms, language: language)
        }
    }
}
