import Foundation

/// Tells, from a braille book's cells alone, whether it is written in
/// English Braille, American Edition (EBAE, the code before UEB) though it
/// is read as UEB (Life of Pi, November 13, 2026).
///
/// Nothing checks the code a braille file is in, so a BRF imported with the
/// default UEB table reads wrongly with no error when it is an old
/// transcription: "to the sea" reads "!the sea". The two codes share their
/// letters and many contractions, but write some signs that UEB does not
/// write at all, and those give EBAE away:
///
/// - the signs for "to" (⠖, dots 2-3-5) and for "by" (⠴, dots 3-5-6), which EBAE
///   writes joined to the word that follows. UEB writes "to" and "by" in
///   letters, and uses those cells otherwise only as "ff" (a groupsign that
///   never begins a word), "!", "+", the word "was" (alone), and the closing
///   quote, none of which has a letter or capital sign directly after it at
///   the start of a word. A word that begins with either, followed by a
///   letter or a capital sign, is EBAE's.
///
/// The capital sign before n or y in the middle of a word ("ation", "ally" in
/// EBAE) is not counted: it is UEB's own "-ation" and "-ity" groupsigns, which
/// every contracted UEB book is full of.
///
/// A book is taken for EBAE only when such words are not few: at least
/// `minimumWords` of them, and one in a hundred of the book's words.
enum BrailleCodeDetector {
    // MARK: Constants

    /// The fewest words with EBAE's signs a book has to be taken for EBAE.
    static let minimumWords = 10
    /// The words with those signs must be at least one in this many of the book's words.
    static let wordsPerHit = 100

    /// The cells, as the bytes of their dots (dot 1 is 0x01, dot 6 is 0x20).
    private static let toSign: UInt8 = 0x16
    private static let bySign: UInt8 = 0x34
    private static let capitalSign: UInt8 = 0x20
    /// The cells of the letters a to z.
    private static let letters: Set<UInt8> = [
        0x01, 0x03, 0x09, 0x19, 0x11, 0x0B, 0x1B, 0x13, 0x0A, 0x1A, 0x05, 0x07, 0x0D,
        0x1D, 0x15, 0x0F, 0x1F, 0x17, 0x0E, 0x1E, 0x25, 0x27, 0x3A, 0x2D, 0x3D, 0x35,
    ]

    // MARK: Counting

    /// How many words of the book are blank-parted runs of cells, and how
    /// many of them show EBAE's signs.
    struct Count: Equatable {
        var words = 0
        var hits = 0

        /// Whether the book is taken for EBAE: enough words show the signs, and not few of all.
        var looksLikeEBAE: Bool {
            hits >= BrailleCodeDetector.minimumWords && hits * BrailleCodeDetector.wordsPerHit >= words
        }
    }

    /// Whether the word `word` (cells, none of them blank) shows an EBAE sign.
    private static func showsEBAESign(_ word: ArraySlice<UInt8>) -> Bool {
        guard word.count >= 2, let first = word.first else { return false }
        let second = word[word.startIndex + 1]
        // "to" or "by" joined to the next word.
        if first == toSign || first == bySign, letters.contains(second) || second == capitalSign {
            return true
        }
        return false
    }

    /// The count of the whole book `file` holds, row by row, in one pass
    /// that holds no more than the row it is on. A word is a run of cells
    /// between blank cells, and ends at a row's end.
    static func count(of file: BrailleFilePages) -> Count {
        var count = Count()
        let cells = file.cells
        for rowIndex in 0..<file.rowCount {
            for word in cells[file.cellRange(ofRow: rowIndex)].split(separator: 0x00, omittingEmptySubsequences: true) {
                count.words += 1
                if showsEBAESign(word) { count.hits += 1 }
            }
        }
        return count
    }

    /// Whether the braille book at `url`, read with the braille file
    /// characters `fileCode` (the book's stored id, nil for North American
    /// Braille ASCII), looks like English Braille, American Edition. False
    /// for a file that cannot be read.
    static func looksLikeEBAE(fileAt url: URL, fileCode: String?) -> Bool {
        let kind = BrailleBookReader.kind(of: url)
        guard let code = BrailleFileCode.code(forStored: fileCode),
              let file = try? BrailleFileReader.read(url, as: kind, code: code) else { return false }
        return count(of: file).looksLikeEBAE
    }
}
