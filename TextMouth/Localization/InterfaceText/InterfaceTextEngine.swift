import Foundation
import os

/// The lookup of a line's text (FR39): given a line's ID, the English the code holds, and a language, it returns what
/// the interface shows. It never traps and never returns nothing: every failure shows the call's own English.
///
/// A lookup, in order:
/// 1. take the state (the tables, the person's own lines) under a lock; the tables are immutable, so the rest runs
///    without it;
/// 2. find the ID's index by binary search over the ID list, comparing the `StaticString`'s bytes, with no allocation;
/// 3. take the first of: the person's own line for the ID in this language; the language's entry; English;
///    English is the call's own format for a plain line, and for a plural line the pack's English forms whenever the
///    ID has a plural English entry that fits the call's arguments (Apple's English table always picks the form,
///    whichever form the code's literal is), else the call's format at every count;
/// 4. a plural entry gives the form `PluralRules` picks for the call's first number;
/// 5. the text's specifiers are checked against the call's arguments, once for each language and ID with the verdict
///    kept; a text that fails shows English and is reported once;
/// 6. a text without `%`, or for a call with no arguments, is returned as it is; any other goes to
///    `String(format:locale:arguments:)`.
///
/// The decoded entries of each language asked for are kept, so a second lookup of a line decodes nothing. The pack is
/// opened and the ID list decoded at the first lookup, a language at its first need, and the notes never. English is
/// decoded only for a call with a number (the only lines a plural entry can serve), at the first lookup in an English
/// session, and in another language only when a line falls back to English.
///
/// This is the core of the system: Foundation and `os` only, no type of the app. A problem reaches the app's debug log
/// through `report`, which the app sets; the engine never imports the logger. A problem is reported once, however
/// often it recurs.
final class InterfaceTextEngine: Sendable {
    /// One language's decoded entries, kept for the life of the engine, with the specifier check's verdict on each.
    fileprivate final class LanguageTable: Sendable {
        /// One entry for each ID, in the ID list's order.
        let entries: [InterfaceTextEntry]
        /// The verdict on each entry: 0 not yet checked, 1 accepted, 2 refused.
        private let verdicts: OSAllocatedUnfairLock<[UInt8]>

        init(entries: [InterfaceTextEntry]) {
            self.entries = entries
            self.verdicts = OSAllocatedUnfairLock(initialState: [UInt8](repeating: 0, count: entries.count))
        }

        /// Whether the entry at `index` fits a call whose arguments are of the kinds `kinds()` gives. The check runs
        /// the first time only; `kinds` is not called after that.
        func accepts(at index: Int, kinds: () -> [FormatSpecifiers.Kind]) -> Bool {
            let known = verdicts.withLock { $0[index] }
            if known != 0 { return known == 1 }
            let accepted = Self.fits(entries[index], kinds: kinds())
            verdicts.withLock { $0[index] = accepted ? 1 : 2 }
            return accepted
        }

        /// Whether every text of `entry` fits `kinds` (see below) and no form is empty.
        static func fits(_ entry: InterfaceTextEntry, kinds: [FormatSpecifiers.Kind]) -> Bool {
            switch entry {
            case .absent: return true
            case .plain(let text): return fits(text, kinds: kinds)
            case .plural(let forms): return forms.allSatisfy { fits($0, kinds: kinds) }
            }
        }

        /// Whether `text` is not empty and passes `FormatSpecifiers.accepts` for `kinds`. A call with no arguments never
        /// formats its text, so any non-empty text fits it, a lone `%` included (as with Apple's `String(localized:)`).
        private static func fits(_ text: String, kinds: [FormatSpecifiers.Kind]) -> Bool {
            !text.isEmpty && (kinds.isEmpty || FormatSpecifiers.accepts(text, arguments: kinds))
        }
    }

    /// Whether a language's table was decoded, or could not be (and is not tried again).
    fileprivate enum TableState: Sendable {
        case loaded(LanguageTable)
        case failed
    }

    /// Whether the pack was opened.
    fileprivate enum SourceState: Sendable {
        case unopened
        case open(any InterfaceTextTables, InterfaceTextIDList)
        case unavailable
    }

    /// What one lookup takes from the state: the IDs, the tables it needs, and the person's own lines.
    fileprivate struct Snapshot {
        var ids: InterfaceTextIDList?
        var table: LanguageTable?
        var englishTable: LanguageTable?
        var overrides: [String: InterfaceTextEntry] = [:]
    }

    /// Everything that changes after the engine is made, behind one lock.
    fileprivate struct Storage: Sendable {
        var source: SourceState = .unopened
        var tables: [String: TableState] = [:]
        /// The person's own lines: language, then ID.
        var overrides: [String: [String: InterfaceTextEntry]] = [:]
        /// Problems already reported, so each is reported once; and the ones waiting to be delivered.
        var reported: Set<String> = []
        var outbox: [String] = []

        /// The most problems remembered: past it, new ones are dropped rather than kept, so a flood of bad IDs
        /// cannot grow the set without end.
        static let largestReportedCount = 500

        /// Queues `problem` for the report unless it was reported already.
        mutating func note(_ problem: String) {
            guard reported.count < Self.largestReportedCount, reported.insert(problem).inserted else { return }
            outbox.append(problem)
        }
    }

    /// Opens the pack: the tables, or nil when there is none. Throws when there is one and it cannot be read.
    private let open: @Sendable () throws -> (any InterfaceTextTables)?
    /// Where a problem goes: the app's debug log, set by the app at launch.
    private let report: @Sendable (String) -> Void
    private let storage = OSAllocatedUnfairLock(initialState: Storage())

    /// An engine that opens its tables with `open` at the first lookup, and passes each problem to `report`, once.
    init(open: @escaping @Sendable () throws -> (any InterfaceTextTables)?, report: @escaping @Sendable (String) -> Void) {
        self.open = open
        self.report = report
    }

    /// An engine over `tables` already in hand (a test's, in memory, or a pack read from a file).
    convenience init(tables: some InterfaceTextTables, report: @escaping @Sendable (String) -> Void) {
        self.init(open: { tables }, report: report)
    }

    // MARK: - The person's own lines

    /// Replaces the person's own lines (language, then ID), which win over the pack's. Empty until the file of
    /// overrides is read (a later phase); the slot is here so a lookup is made once.
    func setOverrides(_ overrides: [String: [String: InterfaceTextEntry]]) {
        locked { $0.overrides = overrides }
    }

    // MARK: - Lookup

    /// The text of the line `id` in `language`, whose English the code holds as `english`, formatted with `locale`.
    /// Safe from any thread; never traps.
    func text(id: StaticString, english: InterfaceText.Format, language: String, locale: Locale) -> String {
        id.withUTF8Buffer { text(idBytes: $0, english: english, language: language, locale: locale) }
    }

    /// The same lookup for an ID that is not a literal: a runtime `String`. Only tools and tests use it (the pack
    /// probe of `make l10n-check` and the hosted test of the shipped pack walk every ID of the pack); the app's own
    /// calls pass a `StaticString`, so a sync tool can read every ID from the source.
    func text(runtimeID id: String, english: InterfaceText.Format, language: String, locale: Locale) -> String {
        Array(id.utf8).withUnsafeBufferPointer { text(idBytes: $0, english: english, language: language, locale: locale) }
    }

    /// The lookup both entry points share, on the ID's UTF-8 bytes, which are compared in place and turned into a
    /// `String` only when the person has lines of their own or a problem is reported.
    private func text(idBytes: UnsafeBufferPointer<UInt8>, english: InterfaceText.Format, language: String, locale: Locale) -> String {
        let count = english.firstNumber
        // English is decoded up front only for an English session; another language takes it when a line falls back.
        let snapshot = locked { $0.snapshot(language: language, needsEnglish: language == "en" && count != nil, open: open) }
        let index = snapshot.ids?.index(ofUTF8: idBytes)
        let id = LazyID(idBytes)
        if index == nil, let ids = snapshot.ids, !ids.isEmpty {
            noteProblem("the pack has no line \(id)")  // l10n: no (English text for the debug log, never shown)
        }

        // The person's own line, then the language's entry. English is the language of the code: its entry would
        // only repeat the call, so it is not looked at (an English line shows the code's English at once).
        let candidate: (entry: InterfaceTextEntry, own: Bool)?
        if let own = ownLine(id, in: snapshot) {
            candidate = (own, true)
        } else if language != "en", let table = snapshot.table, let index, table.entries[index] != .absent {
            candidate = (table.entries[index], false)
        } else {
            candidate = nil
        }
        if let candidate, let chosen = chosenText(candidate.entry, own: candidate.own, id: id, index: index,
                                                  table: snapshot.table, english: english, language: language) {
            return render(chosen, english: english, locale: locale)
        }
        // The fallback: English, whose plural forms come from the pack's English table, decoded now if it is needed and
        // not yet had (a call with a number, a line the pack knows).
        var englishTable = snapshot.englishTable
        if englishTable == nil, count != nil, index != nil { englishTable = locked { $0.englishTable() } }
        return render(englishPattern(index: index, table: englishTable, english: english), english: english, locale: locale)
    }

    /// The person's own entry for `id` in `language`, if the person has one.
    private func ownLine(_ id: LazyID, in snapshot: Snapshot) -> InterfaceTextEntry? {
        snapshot.overrides.isEmpty ? nil : snapshot.overrides[id.text]
    }

    /// The text of `entry` for the call's first number if it passes the specifier check, else nil after reporting it.
    /// A pack entry's verdict is kept in its table; the person's own line is checked each time, since the lines can
    /// change under the same ID.
    private func chosenText(
        _ entry: InterfaceTextEntry, own: Bool, id: LazyID, index: Int?, table: LanguageTable?,
        english: InterfaceText.Format, language: String
    ) -> String? {
        let kinds = { FormatSpecifiers.kinds(of: english.arguments) }
        let accepted: Bool
        if own {
            accepted = LanguageTable.fits(entry, kinds: kinds())
        } else if let table, let index {
            accepted = table.accepts(at: index, kinds: kinds)
        } else {
            accepted = false
        }
        guard accepted else {
            noteProblem("the \(language) text of \(id) does not fit the call's arguments, so its English is shown")  // l10n: no (English text for the debug log, never shown)
            return nil
        }
        return pattern(of: entry, count: english.firstNumber, language: language)
    }

    /// The pattern of `entry` for `count` in `language`: a plain text, or the plural form the language's rule picks
    /// (the last form, `other`, for a call with no number).
    private func pattern(of entry: InterfaceTextEntry, count: Int64?, language: String) -> String? {
        switch entry {
        case .absent:
            return nil
        case .plain(let text):
            return text
        case .plural(let forms):
            let position = count.flatMap { PluralRules.formIndex(of: Int(clamping: $0), language: language) } ?? forms.count - 1
            return forms.indices.contains(position) ? forms[position] : forms.last
        }
    }

    /// The English pattern: the call's own format, except for a line with a number whose ID has a plural English entry in
    /// the pack that passes the specifier check for the call's arguments, which gives the form for the call's number.
    /// The code's literal may be any form (often `one`: "...%lld is kept..."), so it is not compared with the entry:
    /// the build packs the catalog at every build, and the sync tool and the lint hold the code's English to the
    /// catalog's, so the entry is the code's own text. The forms may number their specifiers (`%1$@ ... %2$lld`).
    private func englishPattern(index: Int?, table: LanguageTable?, english: InterfaceText.Format) -> String {
        guard let count = english.firstNumber, let index, let table,
              case .plural(let forms) = table.entries[index],
              table.accepts(at: index, kinds: { FormatSpecifiers.kinds(of: english.arguments) }),
              let form = pattern(of: .plural(forms), count: count, language: "en")
        else { return english.format }
        return form
    }

    /// `pattern` with the call's arguments: returned as it is when the call has none (as Apple's `String(localized:)`
    /// does) or the pattern has no `%`, else through Foundation's formatter with `locale`. Only a pattern that passed
    /// the check, or the call's own format, gets here.
    private func render(_ pattern: String, english: InterfaceText.Format, locale: Locale) -> String {
        guard !english.arguments.isEmpty, pattern.utf8.contains(UInt8(ascii: "%")) else { return pattern }
        return String(format: pattern, locale: locale, arguments: english.formatterArguments)
    }

    // MARK: - Locking and reporting

    /// Runs `body` on the storage under the lock, then delivers what it queued for the report with the lock released,
    /// so the report (a log write) never runs inside the lock.
    private func locked<T>(_ body: (inout Storage) -> T) -> T {
        let (result, problems) = storage.withLockUnchecked { storage -> (T, [String]) in
            let result = body(&storage)
            let problems = storage.outbox
            storage.outbox = []
            return (result, problems)
        }
        for problem in problems { report(problem) }
        return result
    }

    /// Reports `problem` once.
    private func noteProblem(_ problem: String) {
        locked { $0.note(problem) }
    }
}

extension InterfaceTextEngine {
    /// How many IDs there are, or nil before the pack is opened or when it is not: for tests and the report.
    var idCount: Int? {
        locked { storage -> Int? in
            if case .open(_, let ids) = storage.source { return ids.count }
            return nil
        }
    }
}

extension InterfaceTextEngine {
    /// What the person's file of own lines is read and written against: the IDs, the English, the notes, and `language`'s
    /// entries, all as the pack holds them (the person's own lines are not in them). Nil when there is no usable pack or no
    /// English in it. Decodes the tables it needs (kept as for a lookup) and, when asked, the notes (not kept); safe from any thread.
    func reference(language: String, withNotes: Bool = true) -> InterfaceTextReference? {
        let (snapshot, tables) = locked { storage -> (Snapshot, (any InterfaceTextTables)?) in
            let snapshot = storage.snapshot(language: language, needsEnglish: true, open: open)
            if case .open(let tables, _) = storage.source { return (snapshot, tables) }
            return (snapshot, nil)
        }
        guard let ids = snapshot.ids, let english = snapshot.englishTable else { return nil }
        // A read for checking the person's file needs no notes; the commands that write the file ask for them.
        let notes = withNotes ? ((try? tables?.notes()) ?? []) : []
        return InterfaceTextReference(
            ids: ids,
            english: english.entries,
            notes: notes.count == ids.count ? notes : [],
            language: language,
            entries: language == "en" ? english.entries : (snapshot.table?.entries ?? [])
        )
    }

    /// The person's own lines now in force (language, then ID), for the Export.
    var ownLines: [String: [String: InterfaceTextEntry]] {
        locked { $0.overrides }
    }
}

/// An ID's bytes, which become a `String` only when asked (for the person's own lines and for a report), so a plain
/// lookup allocates nothing for its ID.
private struct LazyID: CustomStringConvertible {
    let bytes: UnsafeBufferPointer<UInt8>

    init(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    /// The ID as a string.
    var text: String { String(decoding: bytes, as: UTF8.self) }

    var description: String { text }
}

private extension InterfaceTextIDList {
    /// Whether there are no IDs.
    var isEmpty: Bool { count == 0 }
}

private extension InterfaceTextEngine.Storage {
    /// The state a lookup of `language` needs, opening the pack and decoding tables as the first need arises. A pack
    /// that is missing or unreadable, and a table that cannot be decoded, are noted once and not tried again.
    mutating func snapshot(language: String, needsEnglish: Bool, open: () throws -> (any InterfaceTextTables)?) -> InterfaceTextEngine.Snapshot {
        var snapshot = InterfaceTextEngine.Snapshot()
        snapshot.overrides = overrides[language] ?? [:]
        openIfNeeded(open)
        guard case .open(let tables, let ids) = source else { return snapshot }
        snapshot.ids = ids
        if language != "en" { snapshot.table = table(language, tables: tables, ids: ids) }
        if needsEnglish { snapshot.englishTable = table("en", tables: tables, ids: ids) }
        return snapshot
    }

    /// The English table, decoded the first time it is asked for; nil when the pack is not open or the table is unusable.
    mutating func englishTable() -> InterfaceTextEngine.LanguageTable? {
        guard case .open(let tables, let ids) = source else { return nil }
        return table("en", tables: tables, ids: ids)
    }

    /// Opens the pack at the first lookup: the tables and the decoded ID list.
    private mutating func openIfNeeded(_ open: () throws -> (any InterfaceTextTables)?) {
        guard case .unopened = source else { return }
        do {
            guard let tables = try open() else {
                note("there is no interface text pack, so every line shows its English")  // l10n: no (English text for the debug log, never shown)
                source = .unavailable
                return
            }
            source = .open(tables, try tables.idList())
        } catch {
            note("the interface text pack is unusable, so every line shows its English: \(error)")  // l10n: no (English text for the debug log, never shown)
            source = .unavailable
        }
    }

    /// `language`'s decoded table, decoding it the first time; nil when it cannot be decoded.
    private mutating func table(_ language: String, tables: any InterfaceTextTables, ids: InterfaceTextIDList) -> InterfaceTextEngine.LanguageTable? {
        if case .loaded(let table)? = self.tables[language] { return table }
        if case .failed? = self.tables[language] { return nil }
        do {
            let entries = try tables.entries(language: language)
            guard entries.count == ids.count else { throw InterfaceTextFailure("\(entries.count) entries, not \(ids.count)") }  // l10n: no (English text for the debug log, never shown)
            let table = InterfaceTextEngine.LanguageTable(entries: entries)
            self.tables[language] = .loaded(table)
            return table
        } catch {
            note("the \(language) interface text is unusable, so its lines show English: \(error)")  // l10n: no (English text for the debug log, never shown)
            self.tables[language] = .failed
            return nil
        }
    }
}
