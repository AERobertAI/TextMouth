import Foundation

/// Why a Kindle (MOBI) book cannot be read. Every case's sentence is one a
/// listener can act on; none names the file, which an import's failure
/// does (`ImportFailure`).
enum MOBIError: LocalizedError, LogDescribing, Equatable {
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
            // Translators: Why a file could not be imported as a Kindle (MOBI) book: it is not a Kindle book of a kind TextMouth reads.
            return InterfaceText.line("mobiError.notAKindleBook", "This file is not a Kindle book that TextMouth can read.")
        case .damaged(let detail):
            // A fault only a programmer can name (a table's place, a count)
            // is left out of what a listener hears: the sentence says what to do.
            guard !detail.isEmpty else {
                // Translators: Why a Kindle (MOBI) book could not be imported: it is damaged, and what to do.
                return InterfaceText.line("mobiError.damaged.kindleBookIncompleteGet", "This Kindle book is damaged or incomplete. Get a fresh copy, then import it again.")
            }
            // Translators: Why a Kindle (MOBI) book could not be imported: it is damaged, and what to do. %@ is the reason, a phrase in English that begins with a lowercase letter and has no full stop.
            return InterfaceText.line("mobiError.damaged.kindleBookIncompleteReason", "This Kindle book is damaged or incomplete: \(detail). Get a fresh copy, then import it again.")
        case .copyProtected:
            // Translators: Why a Kindle (MOBI) book could not be imported: it is encrypted or carries copy protection (DRM), which TextMouth never removes.
            return InterfaceText.line("mobiError.copyProtected", "This Kindle book is copy-protected, and TextMouth can't read copy-protected books.")
        case .unsupportedCompression:
            // Translators: Why a Kindle (MOBI) book could not be imported: its text is compressed in a way TextMouth does not read.
            return InterfaceText.line("mobiError.unsupportedCompression", "This Kindle book is compressed in a way TextMouth can't read yet.")
        }
    }

    /// The error in English for the debug log, which stays English whatever
    /// language the interface speaks (FR34).
    var logDescription: String {
        switch self {
        case .notAKindleBook: return "This file is not a Kindle book that TextMouth can read." // l10n: no (debug log)
        case .damaged(let detail):
            return detail.isEmpty
                ? "This Kindle book is damaged or incomplete. Get a fresh copy, then import it again." // l10n: no (debug log)
                : "This Kindle book is damaged or incomplete: \(detail). Get a fresh copy, then import it again." // l10n: no (debug log)
        case .copyProtected: return "This Kindle book is copy-protected, and TextMouth can't read copy-protected books." // l10n: no (debug log)
        case .unsupportedCompression: return "This Kindle book is compressed in a way TextMouth can't read yet." // l10n: no (debug log)
        }
    }
}
