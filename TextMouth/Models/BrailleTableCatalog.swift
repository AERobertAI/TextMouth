import Foundation

// MARK: - A Table's Source

/// Where a braille table comes from (October 20, 2026).
///
/// - **Built into TextMouth** (`bundled`): English, which is Unified English
///   Braille and English Braille American Edition, each uncontracted and
///   contracted. It stays built in, and its contracted UEB table stays the
///   default (decision 1). A bundled table's stored value is its bare file
///   name, as it was before this source existed, so no setting, book, or
///   config.json value needs a migration.
/// - **This Mac's VoiceOver tables** (`mac`): a second source, read in place
///   from VoiceOver's own liblouis folder
///   (`BrailleTableCatalog.macTablesFolder`), never copied, changed, or
///   downloaded (decision 2). A Mac table's stored value is its file name
///   after `macPrefix`, such as "mac:fr-bfu-g2.ctb", in the setting,
///   config.json, `Book.brailleTable`, and the removal marker (decision 7).
///   A build from before this source reads such a value as a table it does
///   not have, and refuses it by name.
enum BrailleTableSource: Equatable, Hashable, Sendable {
    /// Built into TextMouth, in the bundle's tables folder.
    case bundled
    /// One of this Mac's VoiceOver tables, in the Mac's own folder.
    case mac

    /// The prefix of a Mac table's stored value: the one place it is named
    /// (decision 7).
    static let macPrefix = "mac:"

    /// The value stored for this source's table `fileName`: the file name
    /// itself for a bundled table, and `macPrefix` before it for a Mac one.
    func storedValue(ofFile fileName: String) -> String {
        self == .mac ? Self.macPrefix + fileName : fileName
    }

    /// The source and file name `storedValue` names: a Mac table's file name
    /// after `macPrefix`, and otherwise a bundled table's, the whole value.
    static func parse(_ storedValue: String) -> (source: BrailleTableSource, fileName: String) {
        guard storedValue.hasPrefix(macPrefix) else { return (.bundled, storedValue) }
        return (.mac, String(storedValue.dropFirst(macPrefix.count)))
    }

    /// Whether `storedValue` names a Mac table by a bare file name: the
    /// prefix, then a name that is not empty, does not start with a dot, and
    /// holds no slash or comma, as the helper's own check
    /// (`is_bare_table_name` in `TextMouthBraille/main.c`) requires. Such a
    /// value is kept by the setting even when this Mac no longer has the
    /// table, so that an import refuses it by name rather than reading the
    /// book with another table (`BraillePreferences`).
    static func isMacValue(_ storedValue: String) -> Bool {
        let (source, fileName) = parse(storedValue)
        guard source == .mac, let first = fileName.first, first != "." else { return false }
        return !fileName.contains("/") && !fileName.contains(",")
    }
}

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
    /// The table says neither its contraction nor its grade (review R6), as
    /// the Mac's Italian and Georgian tables do: the table's own rules
    /// decide.
    case unstated

    /// Where this contraction falls among the cases, for sorting.
    var rank: Int {
        Contraction.allCases.firstIndex(of: self) ?? Contraction.allCases.count
    }

    /// The contraction a `contraction` line states: "no", "partial", or
    /// "full", in any case; nil for any other value.
    static func stated(_ value: String) -> Contraction? {
        Contraction(rawValue: value.lowercased()).flatMap { $0 == .unstated ? nil : $0 }
    }

    /// The contraction a table's `grade` implies when it has no `contraction`
    /// line (review R6): grade 0 or 1 is uncontracted, as such tables of
    /// liblouis's are (the Indian, Catalan, Czech, Polish, and Latvian
    /// ones); a whole grade of 2 or more is contracted; a grade between, such
    /// as 1.5, is partly contracted. Nil for a grade that is no number.
    init?(grade: String) {
        guard let value = Double(grade), value.isFinite, value >= 0 else { return nil }
        if value <= 1 {
            self = .no
        } else if value == value.rounded() {
            self = .full
        } else {
            self = .partial
        }
    }
}

/// A braille table TextMouth offers (FMT21), as its own metadata says.
struct BrailleTable: Equatable, Hashable, Sendable, Identifiable {
    /// The table's stored value (`BrailleTableSource`): its file name, such
    /// as "en-ueb-g2.ctb", for a bundled table, and "mac:" before it for one
    /// of this Mac's, such as "mac:fr-bfu-g2.ctb". What the setting and a
    /// book's record keep.
    let id: String
    /// The table's `display-name`, such as "Unified English contracted
    /// braille".
    let displayName: String
    /// The table's `index-name`, such as "English, unified, contracted".
    let indexName: String?
    /// The table's language: the first part of its `language` tag, or of the
    /// older `locale` of a table that has no `language`, as liblouis reads
    /// it, such as "en" for "en" and "akk" for "akk-Latn".
    let language: String
    /// The table's `system`, such as "ueb"; empty for a table that names
    /// none, as many of this Mac's tables do.
    let system: String
    /// How far the table contracts words.
    let contraction: Contraction
    /// The table's `grade`, such as "2", when it has one.
    let grade: String?
    /// The table's region, such as "en-US", when its `region` (or `locale`)
    /// names one other than its language; nil otherwise.
    let region: String?
    /// Whether the table's metadata says `dots: 6`. Decision 3 offers such a
    /// table on its word; one with no `dots` line is taken only once its
    /// check's sample comes out in six-dot cells (`MacBrailleTableCheck`).
    let declaresSixDots: Bool

    /// A table of these fields; `region` is nil and `declaresSixDots` false
    /// unless given.
    init(
        id: String,
        displayName: String,
        indexName: String?,
        language: String,
        system: String,
        contraction: Contraction,
        grade: String?,
        region: String? = nil,
        declaresSixDots: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.indexName = indexName
        self.language = language
        self.system = system
        self.contraction = contraction
        self.grade = grade
        self.region = region
        self.declaresSixDots = declaresSixDots
    }

    /// Where the table comes from, as its stored value says.
    var source: BrailleTableSource { BrailleTableSource.parse(id).source }

    /// The table's file name in its source's folder, such as
    /// "fr-bfu-g2.ctb": what the braille helper is given.
    var fileName: String { BrailleTableSource.parse(id).fileName }

    /// The contraction in words the listener hears: "Uncontracted
    /// (Grade 1)", "Contracted (Grade 2)", "Partly contracted", or, for a
    /// table that says neither its contraction nor its grade, "As the table
    /// defines". A table with no grade leaves the bracket out.
    var contractionLabel: String {
        let bracket = grade.map { " (Grade \($0))" } ?? ""
        switch contraction {
        case .no: return "Uncontracted" + bracket
        case .full: return "Contracted" + bracket
        case .partial: return "Partly contracted"
        case .unstated: return "As the table defines"
        }
    }
}

// MARK: - A Code

/// A braille code (FMT21): a system in a language, such as Unified
/// English Braille, with the tables of each contraction it has.
struct BrailleCode: Equatable, Hashable, Sendable, Identifiable {
    /// "<language>/<name>", such as "en/Unified English Braille": unique,
    /// since a code is the tables of one language that share a name
    /// (`BrailleTableCatalog.codes(of:)`).
    let id: String
    /// The language the code writes, as the Language pop-up lists it: its
    /// tables' language, such as "en", or their region, such as "de-CH",
    /// when that language's tables need their regions told apart.
    let language: String
    /// The system of the code's first table, such as "ueb"; empty when it
    /// names none.
    let system: String
    /// The code's name, such as "Unified English Braille".
    let name: String
    /// The code's tables, in the order no, partial, full.
    let tables: [BrailleTable]
}

// MARK: - A Language

/// A language the Language pop-up offers (October 20, 2026, decision 4),
/// with its codes.
struct BrailleLanguage: Equatable, Identifiable, Sendable {
    /// The language as its codes carry it (`BrailleCode.language`), such as
    /// "en", or "de-CH" where regions are needed.
    let id: String
    /// Its name in the user's own language, such as "English" or "German
    /// (Switzerland)".
    let name: String
    /// Its codes, in the order the catalog gives them.
    let codes: [BrailleCode]
}

// MARK: - The Catalog

/// The braille tables TextMouth offers (FMT21), read from the tables' own
/// metadata: the header comments liblouis reads in `analyzeTable`
/// (`Vendor/liblouis/liblouis/metadata.c`). Adding a table is only adding a
/// resource to the bundled tables folder.
///
/// Since October 20, 2026 the tables come from two sources
/// (`BrailleTableSource`): the bundled English tables, built in and the
/// default, and this Mac's own VoiceOver tables, read in place. The same
/// metadata rules choose the tables of both, and a Mac table is checked by
/// the helper before it is used (`MacBrailleTableCheck`).
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
        headerFields(of: text).fields
    }

    /// The fields of `text`'s header, as `metadata(fromHeader:)` reads them,
    /// and whether the header's end, a line that is neither blank nor a
    /// comment, is in `text`. Lines are looked at one at a time from the top,
    /// and none past the header's end is split off (review R3), so a table
    /// of 64 KB costs no more than its header.
    private static func headerFields(of text: String) -> (fields: [String: String], ended: Bool) {
        var fields: [String: String] = [:]
        var rest = text[...]
        while !rest.isEmpty {
            let end = rest.firstIndex(where: \.isNewline) ?? rest.endIndex
            let line = rest[..<end].trimmingCharacters(in: .whitespaces)
            rest = end == rest.endIndex ? rest[end...] : rest[rest.index(after: end)...]
            if line.isEmpty { continue }
            // The first line of anything but comment ends the header.
            guard line.hasPrefix("#") else { return (fields, true) }
            guard let (key, value) = field(inCommentLine: line), fields[key] == nil else { continue }
            fields[key] = value
        }
        return (fields, false)
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

    /// How many bytes of a table file are read at a time for its header: a
    /// header is a few hundred bytes, so one read nearly always holds it.
    static let headerChunkBytes = 4_096

    /// The fields in the header of the table file at `url` (UTF-8, with
    /// invalid bytes replaced), from the bytes `headerData(ofTableAt:)`
    /// reads. A file that cannot be read has none.
    static func metadata(ofTableAt url: URL) -> [String: String] {
        headerFields(of: String(decoding: headerData(ofTableAt: url), as: UTF8.self)).fields
    }

    /// The first bytes of the table file at `url`, read `headerChunkBytes`
    /// at a time until they hold the header's end (review R3), the file
    /// ends, or `maximumHeaderBytes` are read: no more of the file than its
    /// header needs. Empty for a file that cannot be read.
    static func headerData(ofTableAt url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        var data = Data()
        while data.count < maximumHeaderBytes,
              let chunk = try? handle.read(upToCount: min(headerChunkBytes, maximumHeaderBytes - data.count)),
              !chunk.isEmpty {
            data.append(chunk)
            if headerFields(of: String(decoding: data, as: UTF8.self)).ended { break }
        }
        return data
    }

    // MARK: Tables

    /// The table `file` of `source` is, or nil when it is not one TextMouth
    /// offers. Its metadata must give:
    /// - `type` `literary`: never computer braille, a math table, or a file
    ///   only included by other tables, which has no metadata (decision 3);
    /// - `dots` `6`, or no `dots` at all: never an eight-dot table
    ///   (decision 3). A Mac table with no `dots` line is offered, but taken
    ///   only once its check shows six-dot cells (`MacBrailleTableCheck`,
    ///   decision 5); every Mac table is checked so;
    /// - a `display-name`;
    /// - a `language`, or else the older `locale`, which liblouis reads as
    ///   both the language and the region (`analyzeTable` in `metadata.c`);
    /// - a `contraction` of `no`, `partial`, or `full`, or no `contraction`
    ///   line at all (review R6: decision 3 asks for none), when the
    ///   contraction is the one its `grade` implies (`Contraction(grade:)`),
    ///   else `unstated`, as for the Mac's Italian, Latvian, and Georgian
    ///   tables;
    /// - a `direction` of `both`, or none, since TextMouth reads braille as
    ///   well as writing it.
    ///
    /// A `system` is kept when the table names one. Many of this Mac's
    /// tables name none, such as its German and Spanish ones, and their
    /// codes are named from their display names (`codeName(of:)`).
    private static func table(at file: URL, source: BrailleTableSource) -> BrailleTable? {
        let fields = metadata(ofTableAt: file)
        guard fields["type"]?.lowercased() == "literary",
              fields["dots"].map({ $0 == "6" }) ?? true,
              let displayName = fields["display-name"],
              let tag = fields["language"] ?? fields["locale"],
              let language = tag.split(separator: "-").first.map(String.init)
        else { return nil }
        // A stated contraction must be one TextMouth knows; with none, the
        // grade says it, or the table's own rules decide.
        let contraction: Contraction
        if let stated = fields["contraction"] {
            guard let known = Contraction.stated(stated) else { return nil }
            contraction = known
        } else {
            contraction = fields["grade"].flatMap(Contraction.init(grade:)) ?? .unstated
        }
        if let direction = fields["direction"], direction.lowercased() != "both" { return nil }
        return BrailleTable(
            id: source.storedValue(ofFile: file.lastPathComponent),
            displayName: displayName,
            indexName: fields["index-name"],
            language: language,
            system: fields["system"] ?? "",
            contraction: contraction,
            grade: fields["grade"],
            // liblouis's own default: a table with no region has its
            // language tag's, so "akk-Latn" and a `locale` of "de-CH" keep
            // what follows their language as a region.
            region: region(fields["region"] ?? fields["locale"] ?? tag, of: language),
            declaresSixDots: fields["dots"] == "6"
        )
    }

    /// The table each candidate twin among `found` includes, by file name: a
    /// table whose only rule is one include of a table found here in the
    /// same language (review F2).
    private static func twinTargets(of found: [(file: URL, table: BrailleTable)]) -> [String: String] {
        let languages = Dictionary(found.map { ($0.table.fileName, $0.table.language) }) { first, _ in first }
        var targets: [String: String] = [:]
        for entry in found {
            guard let includes = includeOnlyTargets(ofTableAt: entry.file), includes.count == 1,
                  let target = includes.first, target != entry.table.fileName,
                  languages[target] == entry.table.language
            else { continue }
            targets[entry.table.fileName] = target
        }
        return targets
    }

    /// Whether the table `name` is a true twin: following its include
    /// through `twins` ends at a table that is no twin, which is offered and
    /// holds the same rules. A loop of twins ends nowhere, and keeps them.
    private static func isTrueTwin(_ name: String, twins: [String: String]) -> Bool {
        var seen: Set<String> = [name]
        var current = name
        while let next = twins[current] {
            guard seen.insert(next).inserted else { return false }
            current = next
        }
        return current != name
    }

    /// The most bytes a table that only includes others is thought to hold:
    /// such a table is a few lines (the Mac's `lt-6dot.tbl` is 260 bytes),
    /// so a longer file is read no further and taken to have rules of its own.
    static let maximumIncludeOnlyBytes = 4_096

    /// The tables the table file at `url` includes when it does nothing else
    /// (review R6): every line that is neither blank nor a comment is
    /// `include` and a file name, such as "include lt-6dot.utb". Nil for any
    /// other file, for one that cannot be read, and for one longer than
    /// `maximumIncludeOnlyBytes`.
    static func includeOnlyTargets(ofTableAt url: URL) -> [String]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumIncludeOnlyBytes + 1),
              data.count <= maximumIncludeOnlyBytes
        else { return nil }
        var targets: [String] = []
        for rawLine in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let words = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = words.first, !first.hasPrefix("#") else { continue }
            guard first.lowercased() == "include", words.count >= 2 else { return nil }
            targets.append(String(words[1]))
        }
        return targets.isEmpty ? nil : targets
    }

    /// A table's region as the catalog keeps it: `region`, unless it is
    /// absent, the language itself (as liblouis's `locale` makes it), or a
    /// pattern such as "*-IL", which names no one region.
    private static func region(_ region: String?, of language: String) -> String? {
        guard let region, region.caseInsensitiveCompare(language) != .orderedSame, !region.contains("*") else {
            return nil
        }
        return region
    }

    /// The tables TextMouth offers among the regular files of `folder`, by
    /// language, then system, then contraction (no, partial, full, then
    /// unstated), then file name, each with `source`'s stored value.
    /// Included files, other files, and tables that cannot be read both ways
    /// are left out, and so is a true twin (review R6, F2): a table whose
    /// only rule is one include of a table offered here in the same
    /// language, such as the Mac's `lt-6dot.tbl`, which holds only "include
    /// lt-6dot.utb". The table it includes is listed instead, whatever its
    /// code. A table of another language that includes one stays, under its
    /// own language, as the Mac's isiXhosa table includes UEB grade 1; so
    /// does a table that adds rules or includes more than one table, as the
    /// Mac's Ukrainian table with capitals includes its plain Ukrainian
    /// table and the Russian one with capitals.
    static func tables(in folder: URL, source: BrailleTableSource = .bundled) -> [BrailleTable] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let found = files
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .compactMap { file in table(at: file, source: source).map { (file: file, table: $0) } }
        let twins = twinTargets(of: found)
        return found
            .filter { !isTrueTwin($0.table.fileName, twins: twins) }
            .map(\.table)
            .sortedStably { lhs, rhs in
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

    /// The liblouis TextMouth's braille helper is built from
    /// (`Vendor/liblouis`, `PACKAGE_VERSION` in its config.h), which reads
    /// the tables of both sources. A test keeps the two the same.
    static let bundledLiblouisVersion = "3.39.0"

    // MARK: This Mac's Tables

    /// VoiceOver's own liblouis tables (decision 2). On macOS 26.3 the folder
    /// holds 485 files of liblouis 3.34.0, unmodified, under LGPL 2.1. It is
    /// world-readable on the sealed system volume; Apple's braille table
    /// interface (`AXBrailleTable`) lists none of these tables to TextMouth,
    /// but the files can be read. TextMouth reads them where they are and
    /// never copies, changes, or downloads them.
    static let macTablesFolder = URL(
        fileURLWithPath: "/System/Library/ScreenReader/BrailleTables/LiblouisBrailleTranslator.brailletable"
            + "/Contents/Resources/liblouis/tables",
        isDirectory: true
    )

    /// The property list beside the Mac's tables that records their liblouis
    /// version, as `OpenSourceVersion` ("3.34.0" on macOS 26.3).
    static let macTablesPropertyList = URL(
        fileURLWithPath: "/System/Library/ScreenReader/BrailleTables/LiblouisBrailleTranslator.brailletable"
            + "/Contents/Resources/LiblouisBrailleTables.plist"
    )

    /// What a Mac's folder of tables offers.
    struct MacTables: Equatable, Sendable {
        /// The tables the metadata rules offer (`tables(in:source:)`), with
        /// the Mac's stored values, before the bundled tables' twins are
        /// left out (`merged(bundled:mac:)`).
        let tables: [BrailleTable]
        /// The folder's liblouis version, from its property list, or nil
        /// when the property list does not say.
        let liblouisVersion: String?
    }

    /// The tables of the Mac's folder `folder`, with the version
    /// `propertyList` records; nil when there is no such folder, as on an
    /// older macOS or after Apple moves it.
    static func macTables(in folder: URL, propertyList: URL) -> MacTables? {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            return nil
        }
        return MacTables(tables: tables(in: folder, source: .mac), liblouisVersion: liblouisVersion(inPropertyList: propertyList))
    }

    /// The liblouis version the property list at `url` records
    /// (`OpenSourceVersion`), or nil when it cannot be read or names none.
    static func liblouisVersion(inPropertyList url: URL) -> String? {
        let properties = (try? Data(contentsOf: url))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [String: Any]
        return properties?["OpenSourceVersion"] as? String
    }

    /// The property list of a fixture's tables, whose liblouis version
    /// `currentMacLiblouisVersion()` reads, freshly each time, in place of
    /// this Mac's: a test binds it with `$fixtureMacPropertyList
    /// .withValue(_:operation:)` and changes the version under a book
    /// (review R2). Read on the caller's thread.
    @TaskLocal static var fixtureMacPropertyList: URL?

    /// The liblouis version of this Mac's tables now: the Mac's property
    /// list's, read once with its tables (`mac`), or a test's fixture's;
    /// nil when none says.
    static func currentMacLiblouisVersion() -> String? {
        if let fixture = fixtureMacPropertyList { return liblouisVersion(inPropertyList: fixture) }
        return mac?.liblouisVersion
    }

    /// The version a book read with `table` keeps (`Book.brailleTableVersion`,
    /// review R2): the liblouis version of this Mac's tables for one of
    /// them, and nil for a bundled table, which changes only with TextMouth.
    static func versionToRecord(forTable table: String) -> String? {
        BrailleTableSource.parse(table).source == .mac ? currentMacLiblouisVersion() : nil
    }

    /// This Mac's tables, read once, when first needed (the Braille tab, the
    /// Export dialog's braille options, or a Mac table's stored value); nil
    /// when the Mac has no such folder, and TextMouth then offers only its
    /// own tables, with no error (decision 2).
    static let mac: MacTables? = macTables(in: macTablesFolder, propertyList: macTablesPropertyList)

    // MARK: The Offered Tables

    /// The tables offered from both sources: every bundled table, then every
    /// Mac table whose file name no bundled table has. Where the Mac has a
    /// bundled table's twin, as it has all four of TextMouth's English
    /// tables, the bundled one wins and only it is listed (decision 3).
    /// Making codes leaves out the tables listed with the same words as an
    /// earlier one (`codes(of:)`).
    static func merged(bundled: [BrailleTable], mac: [BrailleTable]) -> [BrailleTable] {
        let bundledFiles = Set(bundled.map(\.fileName))
        return bundled + mac.filter { !bundledFiles.contains($0.fileName) }
    }

    /// The codes TextMouth offers, from the bundled tables and this Mac's,
    /// made once, when first needed.
    static let offeredCodes: [BrailleCode] = codes(of: merged(bundled: bundled, mac: mac?.tables ?? []))

    /// Every table the offered codes list: the whole of what TextMouth
    /// offers, and so the whole of what the setting, config.json, and the
    /// braille helper accept.
    static let offeredTables: [BrailleTable] = offeredCodes.flatMap(\.tables)

    /// The offered table with this stored value, if there is one. A bundled
    /// table is found among the bundled tables alone, so naming one never
    /// reads this Mac's folder.
    static func table(withID id: String) -> BrailleTable? {
        switch BrailleTableSource.parse(id).source {
        case .bundled: return bundled.first { $0.id == id }
        case .mac: return offeredTables.first { $0.id == id }
        }
    }

    /// The value the setting and config.json keep for `value`: a bundled
    /// table's file name when the bundle offers it, and a Mac table's value
    /// as it is when it names one by a bare file name
    /// (`BrailleTableSource.isMacValue(_:)`); nil for anything else. It
    /// never reads this Mac's folder (review R3), so reading the setting or
    /// decoding config.json, which happens on the main thread at every
    /// launch, never reads the Mac's table headers. A Mac table this Mac
    /// does not offer is kept so, and refused by name when it is used
    /// (decision 5).
    static func storableValue(_ value: String) -> String? {
        if BrailleTableSource.isMacValue(value) { return value }
        return bundled.first { $0.id == value }?.id
    }

    /// Reads this Mac's tables, and makes the offered codes, on a background
    /// task (review R3): the app asks once at launch, so the Braille tab,
    /// Export's braille options, and Book Info find them made and never read
    /// the Mac's 485 table headers on the main thread. Asking again, or
    /// using them meanwhile, reads nothing twice: Swift makes each `static
    /// let` once, and a thread that needs one while another makes it waits.
    /// - Parameter load: The loading, which a test replaces to see where it
    ///   runs; the app's reads the offered tables.
    @discardableResult
    static func loadInBackground(_ load: @escaping @Sendable () -> Void = { _ = offeredTables }) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            load()
        }
    }

    /// The table braille is read and written with until one is chosen:
    /// Unified English Braille, contracted (the user's choice, October 17).
    static let defaultTableID = "en-ueb-g2.ctb"

    // MARK: Codes

    /// The codes `tables` make, in the order the tables first show them.
    ///
    /// - A code is the tables of one language that share a code name
    ///   (`codeName(of:)`): a known system's name, else the display name
    ///   without its contraction words, so "German uncontracted braille with
    ///   indication of capitals" and "German partially contracted braille
    ///   with indication of capitals" make one code. Many of this Mac's
    ///   tables name no system, and one system can hold two standards (the
    ///   Mac's Danish 1993 and 2022 tables are both "ddp"), so the name, not
    ///   the system, is what the listener can tell apart.
    /// - A table's language is its own, such as "de", or its region, such
    ///   as "de-CH", in a language whose tables need regions
    ///   (`languagesNeedingRegions(in:)`, decision 4).
    /// - A code's tables are in the order no, partial, full, a bundled table
    ///   before a Mac one, then by file name. Of two that would be listed
    ///   with the same words (`BrailleTable.contractionLabel`), only the
    ///   first is kept: the Mac's `no.tbl` only includes its
    ///   `no-no-g3.ctb`, and its `ga.tbl` its `ga-g2.ctb`, and a listener
    ///   could not tell either pair apart.
    static func codes(of tables: [BrailleTable]) -> [BrailleCode] {
        let regional = languagesNeedingRegions(in: tables)
        /// The language a table is listed under.
        func language(of table: BrailleTable) -> String {
            regional.contains(table.language) ? table.region ?? table.language : table.language
        }
        var order: [String] = []
        var groups: [String: [BrailleTable]] = [:]
        for table in tables {
            let id = "\(language(of: table))/\(codeName(of: table))"
            if groups[id] == nil { order.append(id) }
            groups[id, default: []].append(table)
        }
        return order.compactMap { id in
            guard let members = groups[id], let first = members.first else { return nil }
            let sorted = members.sortedStably { lhs, rhs in
                // A tuple of the sort keys, compared in order: contraction,
                // then a bundled table (0) before a Mac one (1), then name.
                (lhs.contraction.rank, lhs.source == .bundled ? 0 : 1, lhs.fileName)
                    < (rhs.contraction.rank, rhs.source == .bundled ? 0 : 1, rhs.fileName)
            }
            var labels = Set<String>()
            return BrailleCode(
                id: id,
                language: language(of: first),
                system: first.system,
                name: codeName(of: first),
                tables: sorted.filter { labels.insert($0.contractionLabel).inserted }
            )
        }
    }

    /// The languages whose tables must be listed by region (decision 4):
    /// those with two tables that would be listed with the same words, a
    /// code name and a contraction, but for different regions, such as a
    /// German table for Germany and one for Switzerland. Every other
    /// language is listed once, without a region, whatever regions its
    /// tables name.
    static func languagesNeedingRegions(in tables: [BrailleTable]) -> Set<String> {
        /// What a listener hears of a table in the pop-ups.
        struct Listing: Hashable {
            let language: String
            let codeName: String
            let contraction: String
        }
        var regions: [Listing: Set<String>] = [:]
        for table in tables {
            let listing = Listing(language: table.language, codeName: codeName(of: table), contraction: table.contractionLabel)
            regions[listing, default: []].insert(table.region ?? table.language)
        }
        return Set(regions.filter { $0.value.count > 1 }.map(\.key.language))
    }

    /// The codes of the bundled tables.
    static let bundledCodes = codes(of: bundled)

    /// The code `table` is listed in: among the bundled codes for a bundled
    /// table, so that naming one never reads this Mac's folder, and among
    /// the offered codes for a Mac one.
    static func code(of table: BrailleTable) -> BrailleCode? {
        (table.source == .bundled ? bundledCodes : offeredCodes).first { $0.tables.contains(table) }
    }

    /// A table's code name: a known system's own, else the table's display
    /// name without the words that say how far it contracts, so a table
    /// added later, or one of this Mac's, is named with no change here.
    static func codeName(of table: BrailleTable) -> String {
        switch table.system {
        case "ueb": return "Unified English Braille"
        case "ebae": return "English Braille, American Edition"
        default: return withoutContractionWords(table.displayName)
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

    // MARK: Languages

    /// The languages `codes` are in, as the Language pop-up lists them
    /// (decision 4): English first, then every other language in the
    /// alphabetical order of its name in the user's own language. Each
    /// language keeps its codes' order.
    static func languages(of codes: [BrailleCode]) -> [BrailleLanguage] {
        var order: [String] = []
        var groups: [String: [BrailleCode]] = [:]
        for code in codes {
            if groups[code.language] == nil { order.append(code.language) }
            groups[code.language, default: []].append(code)
        }
        let languages = order.compactMap { id -> BrailleLanguage? in
            guard let members = groups[id] else { return nil }
            let tables = members.lazy.flatMap(\.tables)
            let name = languageName(id, indexName: tables.compactMap(\.indexName).first, displayName: tables.first?.displayName)
            return BrailleLanguage(id: id, name: name, codes: members)
        }
        return languages.sortedStably { lhs, rhs in
            let (lhsEnglish, rhsEnglish) = (isEnglish(lhs.id), isEnglish(rhs.id))
            if lhsEnglish != rhsEnglish { return lhsEnglish }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }

    /// Whether the language `id` is English, with or without a region.
    private static func isEnglish(_ id: String) -> Bool {
        id.split(separator: "-").first?.lowercased() == "en"
    }

    /// The name of a language in the user's own language
    /// (`Locale.current.localizedString(forIdentifier:)`), such as "English"
    /// for "en" and "German (Switzerland)" for "de-CH". A language the
    /// system cannot name, such as Classical Hebrew ("hbo"), is named by the
    /// first part of a table's `indexName` (liblouis's index names begin
    /// with the language, as "Hebrew, classical, IHBC" does), else by the
    /// words of its `displayName` before "braille", as Munda ("mun") is by
    /// "Munda braille" (review F4), else by its code itself.
    static func languageName(_ language: String, indexName: String? = nil, displayName: String? = nil) -> String {
        if let name = Locale.current.localizedString(forIdentifier: language) { return name }
        let fromIndex = indexName?.split(separator: ",").first?.trimmingCharacters(in: .whitespaces)
        let fromDisplay = displayName
            .flatMap { name in name.range(of: " braille", options: .caseInsensitive).map { String(name[..<$0.lowerBound]) } }?
            .trimmingCharacters(in: .whitespaces)
        return [fromIndex, fromDisplay].lazy.compactMap { $0 }.first { !$0.isEmpty } ?? language
    }

    // MARK: Words

    /// A table in words the listener hears: its code's name, a comma, and
    /// how far it contracts, such as "Unified English Braille, contracted
    /// (Grade 2)". One of this Mac's tables also names its language, as its
    /// code's name may not (decision 8): "French braille, contracted (Grade
    /// 2), in French". For a stored value no offered table has, such as a
    /// Mac table a macOS update removed, the value itself. Book Info and
    /// Speak Info use it.
    static func description(ofTableID id: String) -> String {
        guard let table = table(withID: id) else { return id }
        let language = table.source == .mac
            ? code(of: table).map { languageName($0.language, indexName: table.indexName, displayName: table.displayName) }
            : nil
        return description(of: table, language: language)
    }

    /// `table` in words the listener hears, as `description(ofTableID:)`
    /// says them, with ", in" and `language` after them when it is given. A
    /// table that says nothing of its contraction is named by its code alone,
    /// as "Italian braille, in Italian".
    static func description(of table: BrailleTable, language: String?) -> String {
        let label = table.contractionLabel
        var words = codeName(of: table)
        if table.contraction != .unstated {
            words += ", \(label.prefix(1).lowercased() + label.dropFirst())"
        }
        return language.map { "\(words), in \($0)" } ?? words
    }
}

// MARK: - The Setting

/// The preferences that choose how braille files are read, kept in the
/// preferences store: the braille table (FMT21), mirrored in config.json as
/// `brailleTable`, and the braille file characters an import reads a BRF or
/// BRL file in (braillecodes).
enum BraillePreferences {
    /// The table braille files are read and written with, by its stored
    /// value (`BrailleTableSource`): a bundled table's file name, or "mac:"
    /// and the file name of one of this Mac's tables. It reads as the stored
    /// value when that is a bundled table or names a Mac table
    /// (`BrailleTableSource.isMacValue(_:)`), and as the default table
    /// otherwise. A Mac table is kept even when this Mac no longer has it,
    /// as after a macOS update, so that an import or an export refuses it by
    /// name rather than quietly using another table (decision 5); reading
    /// the setting so never reads this Mac's folder.
    static let table = StoredPreference<String>(
        key: "brailleTable",
        read: { store, key in
            store.string(forKey: key).flatMap(BrailleTableCatalog.storableValue) ?? BrailleTableCatalog.defaultTableID
        },
        write: { id, store, key in store.set(id, forKey: key) }
    )

    /// The table an import uses in place of the setting, bound by a hosted
    /// test (`$tableForImports.withValue("en-ueb-g1.ctb") { ... }`) so it
    /// never writes the real preferences store. Like
    /// `DocumentByteLimit.current`, it is read on the caller's thread.
    @TaskLocal static var tableForImports: String? = nil

    /// The table an import reads or writes braille with: the one a test
    /// bound, else the setting in the runtime's preferences store. That store
    /// is `UserDefaults.standard` in the app and the sandboxed store in hosted
    /// tests, as every other runtime read of a preference uses it, so an
    /// import in a test never reads the user's real setting.
    static func importTable() -> String {
        tableForImports ?? table.read(from: TextMouthRuntime.current.preferences)
    }

    /// The braille file characters a BRF or BRL file is read in when it is
    /// imported (braillecodes), by the code's id (`BrailleFileCode`). It
    /// reads as the stored id when that is one of the import's choices
    /// (`BrailleFileCode.importChoices`, the seven-bit codes), and as North
    /// American Braille ASCII (`BrailleFileCode.defaultCode`) otherwise: when
    /// nothing is stored, the value is empty, it names Unicode braille
    /// patterns, which an import recognizes and never takes from the setting
    /// (review finding 4), or it names a code this TextMouth does not know.
    /// Unlike a book's own code, which is
    /// refused by name when unknown, the setting only chooses for books not
    /// yet imported, so an unknown value falls back to the default. A book
    /// keeps the code it was imported with whatever the setting says later.
    static let fileCode = StoredPreference<String>(
        key: "brailleFileCode",
        read: { store, key in
            store.string(forKey: key).flatMap(BrailleFileCode.importChoice(withID:))?.id ?? BrailleFileCode.defaultCode.id
        },
        write: { id, store, key in store.set(id, forKey: key) }
    )

    /// The braille file code an import uses in place of the setting, by its
    /// id, bound by a hosted test
    /// (`$fileCodeForImports.withValue("ascii-eurobraille") { ... }`) so it
    /// never writes the real preferences store, as `tableForImports` is.
    @TaskLocal static var fileCodeForImports: String? = nil

    /// The braille file code an import reads a BRF or BRL file in when its
    /// bytes name none for certain, by its id: the one a test bound, else the
    /// setting in the runtime's preferences store, read as `importTable()`
    /// reads the table, so an import in a test never reads the user's real
    /// setting.
    static func importFileCode() -> String {
        guard let bound = fileCodeForImports else { return fileCode.read(from: TextMouthRuntime.current.preferences) }
        // A bound id is held to the import's choices as a stored one is:
        // Unicode braille patterns, or an unknown id, reads as the default.
        return BrailleFileCode.importChoice(withID: bound)?.id ?? BrailleFileCode.defaultCode.id
    }

    /// Whether an import of a BRF or BRL read with a contracted Unified
    /// English Braille table may read a book clearly written in English
    /// Braille, American Edition with that code's table instead
    /// (`BrailleTableGuess`). On unless the listener turns it off in the
    /// Braille tab; it changes only books not yet imported.
    static let guessesTable = StoredPreference.flag("brailleGuessesTable", default: true)

    /// Whether imports guess the table in place of the setting, bound by a
    /// hosted test, as `tableForImports` is.
    @TaskLocal static var guessesTableForImports: Bool? = nil

    /// Whether this import guesses the table: the one a test bound, else the
    /// setting in the runtime's preferences store.
    static func importGuessesTable() -> Bool {
        guessesTableForImports ?? guessesTable.read(from: TextMouthRuntime.current.preferences)
    }
}
