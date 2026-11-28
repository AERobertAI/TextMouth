import Foundation

// MARK: - A Count of Characters by Size and Weight

/// How many characters of a stretch of text are at each font size, and how
/// many of those are bold. The sizes are in half-points, as Word stores them.
struct WordCharacterCensus {
    /// The characters other than white space, by size.
    private(set) var charactersBySize: [Int: Int] = [:]
    /// The bold characters other than white space, by size.
    private(set) var boldBySize: [Int: Int] = [:]

    /// Counts one character.
    mutating func add(size: Int, isBold: Bool) {
        charactersBySize[size, default: 0] += 1
        if isBold { boldBySize[size, default: 0] += 1 }
    }

    /// Counts everything `other` counted.
    mutating func merge(_ other: WordCharacterCensus) {
        for (size, count) in other.charactersBySize { charactersBySize[size, default: 0] += count }
        for (size, count) in other.boldBySize { boldBySize[size, default: 0] += count }
    }

    /// The sizes present.
    var sizes: Set<Int> { Set(charactersBySize.keys) }

    /// The size holding the most characters; a tie goes to the smaller.
    var bodySize: Int? {
        charactersBySize.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
    }

    /// Whether every character counted is bold.
    var isEveryCharacterBold: Bool {
        charactersBySize.allSatisfy { boldBySize[$0.key] == $0.value }
    }

    /// Whether more than half the characters at the body size are bold: a
    /// document in bold throughout has no headings from bold.
    var isMostlyBold: Bool {
        guard let size = bodySize else { return false }
        return (boldBySize[size] ?? 0) * 2 > (charactersBySize[size] ?? 0)
    }
}

// MARK: - Guessing Headings

/// Guesses the headings of a document that names none: the paragraphs set
/// in a larger size than the body, ranked by size, and then the paragraphs
/// set wholly in bold at the body size. This is the guess textutil's readers
/// get from `TextutilHTMLStructure` for every document, since textutil loses
/// the styles; a Word document with real heading styles or outline levels
/// does not need it, and the writer uses it only for one that has none.
enum WordHeadingGuess {

    /// The deepest heading level; smaller sizes share it.
    private static let deepestLevel = 6

    /// The heading level of each candidate paragraph (nil for a paragraph
    /// that is not a heading), in the order given.
    /// - Parameters:
    ///   - candidates: the census of each paragraph that is short enough to be
    ///     a heading and not in a table.
    ///   - document: the census of the whole document.
    static func levels(of candidates: [WordCharacterCensus], in document: WordCharacterCensus) -> [Int?] {
        guard let bodySize = document.bodySize else { return candidates.map { _ in nil } }
        let boldAllowed = !document.isMostlyBold
        // A paragraph set in a larger size than the body is a heading by size.
        let larger = candidates.map { census -> Int? in
            guard let size = census.bodySize, size > bodySize else { return nil }
            return size
        }
        let sizes = Set(larger.compactMap { $0 }).sortedStably(by: >)
        return zip(candidates, larger).map { census, size in
            if let size {
                // The largest size is level 1, the next level 2, and so on.
                return min((sizes.firstIndex(of: size) ?? 0) + 1, deepestLevel)
            }
            // Wholly bold at the body size: the level after the sizes'.
            if boldAllowed, census.isEveryCharacterBold, census.sizes == [bodySize] {
                return min(sizes.count + 1, deepestLevel)
            }
            return nil
        }
    }
}
