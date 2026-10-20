import Foundation

// MARK: - A Table

/// How far a braille table contracts words (FMT21), as its `contraction`
/// metadata says. The cases are in the order a list shows them.
enum Contraction: String, Sendable, CaseIterable {
    /// Every letter is written out (Grade 1).
    case no
    /// Some contractions are used.
    case partial
    /// Every contraction the code has is used (Grade 2).
    case full

    /// Where this contraction falls among the cases, for sorting.
    var rank: Int {
        Contraction.allCases.firstIndex(of: self) ?? Contraction.allCases.count
    }
}

/// A braille table TextMouth offers (FMT21), as its own metadata says.
struct BrailleTable: Equatable, Hashable, Sendable, Identifiable {
    /// The file name in the tables folder, such as "en-ueb-g2.ctb": what a
    /// book's record keeps, and what the braille helper is given.
    let id: String
    /// The table's `display-name`, such as "Unified English contracted
    /// braille".
    let displayName: String
    /// The table's `index-name`, such as "English, unified, contracted".
    let indexName: String?
    /// The table's `language`, such as "en".
    let language: String
    /// The table's `system`, such as "ueb".
    let system: String
    /// How far the table contracts words.
    let contraction: Contraction
    /// The table's `grade`, such as "2", when it has one.
    let grade: String?

    /// The contraction in words the listener hears: "Uncontracted
    /// (Grade 1)", "Contracted (Grade 2)", or "Partly contracted". A table
    /// with no grade leaves the bracket out.
    var contractionLabel: String {
        let bracket = grade.map { " (Grade \($0))" } ?? ""
        switch contraction {
        case .no: return "Uncontracted" + bracket
        case .full: return "Contracted" + bracket
        case .partial: return "Partly contracted"
        }
    }
}

// MARK: - A Code

/// A braille code (FMT21): a system in a language, such as Unified
/// English Braille, with the tables of each contraction it has.
struct BrailleCode: Equatable, Hashable, Sendable, Identifiable {
    /// "<language>/<system>", such as "en/ueb".
    let id: String
    /// The language the code writes, such as "en".
    let language: String
    /// The code's system, such as "ueb".
    let system: String
    /// The code's name, such as "Unified English Braille".
    let name: String
    /// The code's tables, in the order no, partial, full.
    let tables: [BrailleTable]
}

// MARK: - The Catalog

/// The braille tables TextMouth offers (FMT21), read from the tables' own
/// metadata: the header comments liblouis reads in `analyzeTable`
/// (`Vendor/liblouis/liblouis/metadata.c`). Adding a table is only adding a
/// resource to the bundled tables folder.
enum BrailleTableCatalog {
    // MARK: Metadata

    /// The most bytes of a table file read for its header; a header is a
    /// few hundred bytes, so this is far more than any needs.
    static let maximumHeaderBytes = 65_536

    /// The fields in a table's header, as liblouis reads them.
    ///
    /// Lines are read from the top. A blank line is skipped. A line starting
    /// with "#" is a comment, and one starting "#+" or "#-" (but not "#--")
    /// is a field, `key: value`, the colon needing no space after it. The
    /// first line that is neither blank nor a comment ends the header, so a
    /// later line is never read. Keys are lowercased; values are trimmed,
    /// with each run of white space made one space; the first value of a
    /// key wins.
    static func metadata(fromHeader text: String) -> [String: String] {
        var fields: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // The first line of anything but comment ends the header.
            guard line.hasPrefix("#") else { break }
            guard let (key, value) = field(inCommentLine: line), fields[key] == nil else { continue }
            fields[key] = value
        }
        return fields
    }

    /// The key and value a comment line holds, or nil when it is a plain
    /// comment, a "#--" line, or a field with no colon, key, or value.
    private static func field(inCommentLine line: String) -> (key: String, value: String)? {
        guard line.hasPrefix("#+") || (line.hasPrefix("#-") && !line.hasPrefix("#--")) else { return nil }
        let body = line.dropFirst(2)
        guard let colon = body.firstIndex(of: ":") else { return nil }
        let key = body[..<colon].lowercased()
        // A key is one word; "#- some remark: of this kind" is a comment.
        guard !key.isEmpty, key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        // Each run of white space becomes one space, and the ends go.
        let value = body[body.index(after: colon)...]
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !value.isEmpty else { return nil }
        return (key, value)
    }

    /// The fields in the header of the table file at `url`, read from its
    /// first `maximumHeaderBytes` bytes (UTF-8, with invalid bytes
    /// replaced). A file that cannot be read has none.
    static func metadata(ofTableAt url: URL) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumHeaderBytes) else { return [:] }
        return metadata(fromHeader: String(decoding: data, as: UTF8.self))
    }

    // MARK: Tables

    /// The table `file` is, or nil when it is not one TextMouth offers: its
    /// metadata must give `type` `literary`, a `display-name`, a
    /// `language`, a `system`, and a `contraction` of `no`, `partial`, or
    /// `full`, and its `direction` must be `both` or absent, since
    /// TextMouth reads braille as well as writing it.
    private static func table(at file: URL) -> BrailleTable? {
        let fields = metadata(ofTableAt: file)
        guard fields["type"]?.lowercased() == "literary",
              let displayName = fields["display-name"],
              let language = fields["language"],
              let system = fields["system"],
              let contraction = fields["contraction"].flatMap({ Contraction(rawValue: $0.lowercased()) })
        else { return nil }
        if let direction = fields["direction"], direction.lowercased() != "both" { return nil }
        return BrailleTable(
            id: file.lastPathComponent,
            displayName: displayName,
            indexName: fields["index-name"],
            language: language,
            system: system,
            contraction: contraction,
            grade: fields["grade"]
        )
    }

    /// The tables TextMouth offers among the regular files of `folder`, by
    /// language, then system, then contraction (no, partial, full), then
    /// file name. Included files, other files, and tables that cannot be
    /// read both ways are left out.
    static func tables(in folder: URL) -> [BrailleTable] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return files
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .compactMap(table(at:))
            .sorted { lhs, rhs in
                // A tuple of the sort keys, compared in order.
                (lhs.language, lhs.system, lhs.contraction.rank, lhs.id)
                    < (rhs.language, rhs.system, rhs.contraction.rank, rhs.id)
            }
    }

    /// The tables of the bundled tables folder, empty when the bundle has
    /// none, read once.
    static let bundled: [BrailleTable] = {
        guard let folder = BrailleTranslator.Tool.helper.tablesFolder else { return [] }
        return tables(in: folder)
    }()

    /// The bundled table with this file name, if there is one.
    static func table(withID id: String) -> BrailleTable? {
        bundled.first { $0.id == id }
    }

    /// The table braille is read and written with until one is chosen:
    /// Unified English Braille, contracted (the user's choice, October 17).
    static let defaultTableID = "en-ueb-g2.ctb"

    // MARK: Codes

    /// The codes `tables` make, one for each language and system, in the
    /// order the tables first show them; a code's tables stay in the
    /// tables' order.
    static func codes(of tables: [BrailleTable]) -> [BrailleCode] {
        var order: [String] = []
        var groups: [String: [BrailleTable]] = [:]
        for table in tables {
            let id = "\(table.language)/\(table.system)"
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(table)
        }
        return order.compactMap { id in
            guard let members = groups[id], let first = members.first else { return nil }
            return BrailleCode(
                id: id,
                language: first.language,
                system: first.system,
                name: codeName(system: first.system, firstTable: first),
                tables: members
            )
        }
    }

    /// The codes of the bundled tables.
    static let bundledCodes = codes(of: bundled)

    /// The bundled code `table` belongs to.
    static func code(of table: BrailleTable) -> BrailleCode? {
        bundledCodes.first { $0.tables.contains(table) }
    }

    /// A code's name: a known system's own, else its first table's display
    /// name without the words that say how far it contracts, so a table
    /// added later is named with no change here.
    private static func codeName(system: String, firstTable: BrailleTable) -> String {
        switch system {
        case "ueb": return "Unified English Braille"
        case "ebae": return "English Braille, American Edition"
        default: return withoutContractionWords(firstTable.displayName)
        }
    }

    /// The words that say how far a table contracts, as display names put
    /// them. " partially contracted" holds " contracted", so the phrase that
    /// begins first in the name is the one removed.
    private static let contractionPhrases = [" uncontracted", " partially contracted", " contracted"]

    /// `name` without the first contraction phrase in it, and its first
    /// letter capitalized.
    private static func withoutContractionWords(_ name: String) -> String {
        let found = contractionPhrases
            .compactMap { name.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
        var result = name
        if let found { result.removeSubrange(found) }
        return result.prefix(1).uppercased() + result.dropFirst()
    }

    /// The name of a language for grouping tables, such as "English" for
    /// "en", or the code itself when the system does not know it.
    static func languageName(_ language: String) -> String {
        Locale.current.localizedString(forLanguageCode: language) ?? language
    }

    // MARK: Words

    /// A bundled table in words the listener hears: its code's name, a
    /// comma, and how far it contracts, such as "Unified English Braille,
    /// contracted (Grade 2)". For a file name no bundled table has, the file
    /// name itself. Book Info and Speak Info use it.
    static func description(ofTableID id: String) -> String {
        guard let table = table(withID: id) else { return id }
        let label = table.contractionLabel
        return "\(code(of: table)?.name ?? table.displayName), \(label.prefix(1).lowercased() + label.dropFirst())"
    }
}
