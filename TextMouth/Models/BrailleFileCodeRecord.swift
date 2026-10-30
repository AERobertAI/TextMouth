import Foundation

// MARK: - The Braille File Code That Stands (braillecodes)

/// The braille file characters a BRF or BRL book's file writes its cells in,
/// as its library row and its package record keep them (`Book.brailleFileCode`,
/// `BookMetadata.brailleFileCode`): one optional string, the code's id
/// (`BrailleFileCode`), such as "ascii-na" for North American Braille ASCII,
/// and the rule by which the two settle on one.
///
/// It is the text encoding's rule (`TextEncodingRecord.standing(row:recorded:)`)
/// without a field saying who decided: TextMouth guesses no code, so only an
/// import, which writes the code it read the file with, and a re-read in
/// other braille file characters in Book Information ever record one, and
/// there is no guess for a decision to stand over.
enum BrailleFileCodeRecord {
    /// The code that stands when a braille book's library row holds `row`
    /// and its package record holds `recorded`: the record's when it names
    /// one, whatever the row holds, and otherwise the row's.
    ///
    /// A re-read in other braille file characters writes its code into the
    /// package record first, with the new text, and the library row takes
    /// it afterwards, so the record is never behind the row: a row that
    /// differs lags behind a re-read (after a stop before library.json was
    /// saved, or another Mac's re-read), and taking its code would label the
    /// new text with the old characters. A re-read always writes an explicit
    /// id, North American Braille ASCII's included, never nil, so a record
    /// that names none was never re-read, and the row's code stands, its nil
    /// included. Every place the two meet follows this rule: a write of the
    /// record (`Book.bookInfo(replacing:contentIndex:revisionFloor:decidingTextEncoding:decidingBrailleFileCode:)`),
    /// a reading of the book's file (`Book.recordedBrailleFileCode()`), and
    /// an analysis recovered from the record (`ContentAnalysisSummary.apply(to:)`).
    ///
    /// Neither value is checked against the codes this TextMouth knows: an
    /// id a later TextMouth wrote stands exactly as it is stored, so the
    /// book's reading can refuse it by name rather than read it as another
    /// code.
    static func standing(row: String?, recorded: String?) -> String? {
        recorded ?? row
    }
}
