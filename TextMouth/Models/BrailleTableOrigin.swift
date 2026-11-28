import Foundation

// MARK: - Who Chose a Braille Book's Table (brfguess)

/// Who chose the braille table a braille book is read with
/// (`Book.brailleTable`), kept beside it as `Book.brailleTableOrigin`, the
/// way the text encoding's guess is kept with `TextEncodingSource`.
///
/// Only a guess is recorded: nil is every book the listener's Braille
/// setting or Book Information chose a table for, and every book imported
/// before TextMouth could guess, so their rows and records are written
/// exactly as before. A value this TextMouth cannot read, as a later one's
/// might be, is nil too.
enum BrailleTableOrigin: String, Codable, Equatable, Sendable {
    /// The import found the book clearly written in English Braille,
    /// American Edition (`BrailleCodeDetector`, `BrailleTableGuess`) and read
    /// it with the bundled contracted EBAE table, not the Braille setting's
    /// contracted UEB table. Choosing a braille code in Book Information
    /// replaces the guess for good.
    case guessed = "guessed"
}

// MARK: - The Guess

/// The guess of a braille book's table at import: when the Braille setting
/// names a contracted UEB table and the book is clearly English Braille,
/// American Edition, the bundled contracted EBAE table reads it instead.
enum BrailleTableGuess {
    /// The bundled contracted EBAE table's stored value (`en_US.tbl`).
    static let ebaeTableID = "en_US.tbl"

    /// Whether `tableID` is a contracted UEB table, the only table the guess
    /// replaces: an uncontracted UEB table, any other code, and one of this
    /// Mac's tables are the listener's word, left as they are.
    static func isContractedUEB(_ tableID: String) -> Bool {
        guard let table = BrailleTableCatalog.table(withID: tableID) else { return false }
        return table.system == "ueb" && table.contraction == .full
    }

    /// The table to read the braille book at `url` with, and whether it was
    /// guessed: `settingTable`, the Braille setting's, unless the setting is
    /// on (`BraillePreferences.guessesTable`), the table is a contracted UEB
    /// one, the file is a BRF or BRL (a PEF is never guessed), and it is
    /// clearly English Braille, American Edition
    /// (`BrailleCodeDetector.isClearlyEBAE`).
    /// When unsure, nothing changes: the setting's table stands, and the
    /// suggestion in Book Information remains.
    static func table(
        forImportedFileAt url: URL,
        fileCode: String?,
        settingTable: String,
        guessing: Bool
    ) -> (table: String, origin: BrailleTableOrigin?) {
        guard guessing,
              BrailleBookReader.kind(of: url) != .pef,
              isContractedUEB(settingTable),
              BrailleTableCatalog.table(withID: ebaeTableID) != nil,
              BrailleCodeDetector.isClearlyEBAE(fileAt: url, fileCode: fileCode)
        else { return (settingTable, nil) }
        return (ebaeTableID, .guessed)
    }
}
