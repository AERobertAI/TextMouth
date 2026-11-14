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
///   writes joined to the word that follows, where UEB writes "to" and "by"
///   in letters, and uses those cells only as punctuation, which ends a word
///   or stands alone. A word that begins with either, followed by a letter or
///   a capital sign, is EBAE's.
/// - the sign for "ation" and for "ally" (a capital sign, then n or y), which
///   EBAE writes in the middle of a word after a letter, where UEB's capital
///   sign begins a word or a capital in a name ("McNeil"), which is rare. UEB
///   dropped both contractions (BANA's "Overview of Changes from EBAE to
///   UEB"); its "-tion" and "-ity" are the dots 5-6 sign and n or y. A name
///   with a capital inside it could repeat many times in one book, so these
///   words are counted once for each distinct word, where a joined "to" or
///   "by" is counted at each place: EBAE's "ation" and "ally" words are many
///   different words, a name is one.
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
    private static let letterN: UInt8 = 0x1D
    private static let letterY: UInt8 = 0x3D
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

    /// The EBAE sign a word shows.
    private enum Sign {
        /// "to" or "by" joined to the next word.
        case joined
        /// "ation" or "ally" inside a word, which a name with a capital inside it also shows.
        case insideWord
    }

    /// The most distinct words with an inside-word sign that are kept to count them apart.
    private static let maxDistinctInsideWords = 5_000

    /// The EBAE sign the word `word` (cells, none of them blank) shows, if any.
    private static func sign(of word: ArraySlice<UInt8>) -> Sign? {
        guard word.count >= 2, let first = word.first else { return nil }
        let second = word[word.startIndex + 1]
        if first == toSign || first == bySign, letters.contains(second) || second == capitalSign {
            return .joined
        }
        // "ation" or "ally" in the middle of a word: a capital sign directly
        // after a letter, then n or y.
        for index in word.indices.dropFirst() where word[index] == capitalSign {
            let next = index + 1
            if letters.contains(word[index - 1]), next < word.endIndex, word[next] == letterN || word[next] == letterY {
                return .insideWord
            }
        }
        return nil
    }

    /// The count of the whole book `file` holds, row by row, in one pass
    /// that holds no more than the row it is on. A word is a run of cells
    /// between blank cells, and ends at a row's end.
    static func count(of file: BrailleFilePages) -> Count {
        var count = Count()
        let cells = file.cells
        // The words with an inside-word sign seen so far, counted once each.
        var insideWords: Set<[UInt8]> = []
        for rowIndex in 0..<file.rowCount {
            for word in cells[file.cellRange(ofRow: rowIndex)].split(separator: 0x00, omittingEmptySubsequences: true) {
                count.words += 1
                switch sign(of: word) {
                case .joined:
                    count.hits += 1
                case .insideWord:
                    // A new distinct word counts; a name repeated does not.
                    if insideWords.count < maxDistinctInsideWords, insideWords.insert(Array(word)).inserted {
                        count.hits += 1
                    }
                case nil:
                    break
                }
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
