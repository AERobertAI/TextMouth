import Foundation

/// Why a Kindle (MOBI) book cannot be read. Every case's sentence is one a
/// listener can act on; none names the file, which an import's failure
/// does (`ImportFailure`).
enum MOBIError: LocalizedError, Equatable {
    /// The file is not a Palm database of a kind that holds a book
    /// (`MOBIPalmDatabase`): too short, a type and creator that are not
    /// `BOOKMOBI` or `TEXtREAd`, or no record 0.
    case notAKindleBook
    /// The file is a Kindle book that stops short or contradicts itself: a
    /// record, offset, count, or length that points outside the data, a
    /// compressed text that does not decompress, or an index that does not
    /// read. `detail` completes "This Kindle book is damaged or incomplete: ..."
    /// for the log and for tests; the sentence a listener hears adds the
    /// way out.
    case damaged(String)
    /// The book is encrypted (the PalmDOC header's encryption field is not
    /// 0) or carries DRM (the MOBI header's DRM offset is not 0xFFFFFFFF).
    /// TextMouth never removes copy protection, and no code may try.
    case copyProtected
    /// The text is compressed in a way this reader does not read: a
    /// compression type no one defined (PalmDOC and HUFF/CDIC are read).
    case unsupportedCompression

    var errorDescription: String? {
        switch self {
        case .notAKindleBook:
            return "This file is not a Kindle book that TextMouth can read."
        case .damaged(let detail):
            // A fault only a programmer can name (a table's place, a count)
            // is left out of what a listener hears: the sentence says what to do.
            guard !detail.isEmpty else {
                return "This Kindle book is damaged or incomplete. Get a fresh copy of the book, then import it again."
            }
            return "This Kindle book is damaged or incomplete: \(detail). Get a fresh copy of the book, then import it again."
        case .copyProtected:
            return "This Kindle book is copy-protected, and TextMouth can't read copy-protected books."
        case .unsupportedCompression:
            return "This Kindle book is compressed in a way TextMouth can't read yet."
        }
    }
}
