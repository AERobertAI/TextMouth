import Foundation

// MARK: - Who Decided a Book's Encoding (encodingchoice)

/// Who decided the encoding a text book's file is read in, beside the
/// encoding itself (`Book.textEncoding`): kept in the book's row, its package
/// record, and its removal marker as `textEncodingSource`, and left out when
/// the import decided (FMT16), so every book imported before the listener
/// could choose is written exactly as it was.
///
/// An older TextMouth drops the key: a chosen encoding then reads as a guess
/// of the same encoding, which reads the file alike unless the choice
/// overruled what the bytes say of themselves (valid UTF-8, a byte-order
/// mark, or an HTML declaration), and Book Information says "guessed".
enum TextEncodingSource: String, Codable, Equatable, Sendable {
    /// The listener chose `textEncoding` in Book Information. The file is
    /// read in it, whatever its bytes say of themselves
    /// (`TextFileDecoder.EncodingPolicy.chosen(_:)`).
    case chosen = "chosen"
    /// The listener chose Automatic in Book Information, which read the file
    /// again as an import does: `textEncoding` is that reading's guess, or
    /// nil when it made none (the bytes named their encoding, or
    /// Windows-1252 read them well). Either stands as it is: a nil here is
    /// the listener's, never a row that lost its encoding, so no record's
    /// older encoding takes its place (`Book.bookInfo(replacing:...)`).
    case automatic = "automatic"
}

/// A text book's encoding and who decided it, as one value: the two fields
/// a row and a record keep (`textEncoding`, `textEncodingSource`) always
/// travel together, so a row that holds either is never given half of a
/// record's.
struct TextEncodingRecord: Equatable, Sendable {
    /// The encoding the file is read in when its bytes name none, or always
    /// for a choice, by its identifier: one of `TextEncodingCatalog`'s, or
    /// UTF-8 (`TextFileDecoder.utf8Identifier`) for a choice; nil for none.
    var identifier: String?
    /// Who decided it; nil for the import (FMT16).
    var source: TextEncodingSource?

    /// No encoding recorded, by nobody: a book whose bytes named their
    /// encoding at its import, that Windows-1252 read well, or imported
    /// before guesses were recorded, and a row that lost its encoding.
    static let unrecorded = TextEncodingRecord(identifier: nil, source: nil)

    /// Whether nothing is recorded: neither an encoding nor who decided.
    var isEmpty: Bool {
        identifier == nil && source == nil
    }

    /// Whether the listener chose the encoding.
    var isChosen: Bool {
        source == .chosen && identifier != nil
    }

    /// How the book's file is read (`TextFileDecoder.EncodingPolicy`): in
    /// the encoding chosen, whatever the bytes say; in the encoding guessed,
    /// when the bytes name none; or as every book was read before guesses,
    /// with nothing recorded.
    var policy: TextFileDecoder.EncodingPolicy {
        if isChosen, let identifier {
            return .chosen(identifier)
        }
        return .forBook(recording: identifier)
    }
}

// MARK: - The Fields as One

extension Book {
    /// The book's encoding and who decided it (`textEncoding`,
    /// `textEncodingSource`), read and written as one.
    var textEncodingRecord: TextEncodingRecord {
        get { TextEncodingRecord(identifier: textEncoding, source: textEncodingSource) }
        set {
            textEncoding = newValue.identifier
            textEncodingSource = newValue.source
        }
    }
}

extension BookMetadata {
    /// The record's encoding and who decided it (`textEncoding`,
    /// `textEncodingSource`), read and written as one.
    var textEncodingRecord: TextEncodingRecord {
        get { TextEncodingRecord(identifier: textEncoding, source: textEncodingSource) }
        set {
            textEncoding = newValue.identifier
            textEncodingSource = newValue.source
        }
    }
}
