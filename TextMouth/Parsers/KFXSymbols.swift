import Foundation

/// The symbols of one KFX container: the shared table `YJ_symbols`, which a
/// reader knows only by number, and the container's own local symbols, which
/// the file names (KFX-FORMAT-NOTES-2026-11-05.md, part 5).
///
/// KFX counts differently from Ion: the import's `max_id` includes the nine
/// system symbols, so with a `max_id` of 859 the shared symbols are ids 10
/// to 859 and the first local symbol has id 860.
struct KFXSymbols: Equatable {
    /// The highest id the shared tables hold; local symbols follow it.
    var sharedMaximum: Int
    /// The text of the local symbols, the first having id `sharedMaximum + 1`.
    var local: [String]

    /// The most any shared `max_id` may be. The real table holds under a
    /// thousand symbols, so a larger count is a book that lies, and it must
    /// not be trusted to place the local ones.
    static let sharedMaximumLimit = 100_000

    /// A table with no local symbols: the shared ones alone.
    static let sharedOnly = KFXSymbols(sharedMaximum: 0, local: [])

    // MARK: Names

    /// The name of symbol `id`: the local symbol's text, or `$` and the
    /// number for a shared symbol, id 0, and an id the table does not hold
    /// (which is handled, never a trap). The same name stands for the same
    /// symbol in the book's other containers, whose numbers differ.
    func name(of id: Int) -> String {
        let index = id - sharedMaximum - 1
        if id > sharedMaximum, local.indices.contains(index) {
            return local[index]
        }
        return "$\(id)"
    }

    /// The name a symbol value stands for, nil for a value that is not a
    /// symbol or a string. A reference in a book is a local symbol, but a
    /// string is taken as the name it spells.
    func name(of value: IonValue?) -> String? {
        switch value?.unannotated {
        case .symbol(let id): return name(of: id)
        case .string(let text): return text
        default: return nil
        }
    }

    // MARK: Reading

    /// The symbols a container's document symbol table (an Ion struct, which
    /// the file annotates `$ion_symbol_table`) declares.
    ///
    /// A table with no imports puts the local symbols right after Ion's nine
    /// system symbols.
    /// - Throws: `MOBIError.damaged` for a table that is not a struct or
    ///   whose counts are not plausible.
    init(table: IonValue) throws {
        guard let members = table.structValue else {
            throw MOBIError.damaged("the symbol table is not a struct")
        }
        // Field ids of Ion's system symbols.
        let importsField = 6, symbolsField = 7, maxIDField = 8
        var maximum = 0
        for entry in members[importsField]?.listValue ?? [] {
            guard let count = entry.structValue?[maxIDField]?.intValue,
                  count >= 0, count <= Self.sharedMaximumLimit else {
                throw MOBIError.damaged("the symbol table imports an impossible number of symbols")
            }
            maximum += count
        }
        sharedMaximum = maximum == 0 ? Self.systemSymbolCount : maximum
        local = (members[symbolsField]?.listValue ?? []).map { $0.stringValue ?? "" }
    }

    /// A table of these parts.
    init(sharedMaximum: Int, local: [String]) {
        self.sharedMaximum = sharedMaximum
        self.local = local
    }

    /// Ion's nine system symbols, which a table that imports nothing starts after.
    private static let systemSymbolCount = 9
}
