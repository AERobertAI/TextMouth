import Foundation

/// Lays a transcript text the user edited over the transcript's sentences
/// (FR05): which words of the edited text stand for which sentence the
/// recognizer heard, so each sentence keeps its time in the audio and takes
/// its words from the edit.
///
/// The original text and the edited one are split into words, matched as
/// words that read the same once their case and their surrounding
/// punctuation are set aside. First every sentence the user left word for
/// word as it was, and that reads differently from every other sentence, is
/// found whole in the edit: the longest run of them in the same order holds
/// the alignment in place, sentence by sentence. Between two such
/// sentences, the words are aligned the way a patience diff aligns lines:
/// words found once in each stretch are anchors, the longest run of anchors
/// in order holds the stretch in place, and each stretch between two
/// anchors is aligned the same way again, down to stretches small enough to
/// align word by word.
///
/// A sentence the user left alone keeps exactly its words; a word the user
/// changed, inserted, or rewrote goes to the sentence whose words it stands
/// among, by position; a sentence whose every word the user deleted is
/// gone. No word of the edit is ever lost: every one belongs to some
/// sentence, unless the chapter had none.
enum TranscriptEditAlignment {
    /// The most word pairs a stretch without anchors is aligned with, word
    /// by word, by the longest common subsequence: about three hundred words
    /// a side. A larger stretch, a passage rewritten whole, shares its words
    /// out by position instead.
    static let wordByWordLimit = 90_000

    /// One word of a text: what it is matched by, and where it lies.
    struct Word: Equatable {
        /// The word as matched: lower case, without the punctuation and
        /// symbols at either end, or, for a word of nothing else, as it is.
        let key: String
        /// Where the word lies in its text, in UTF-16 units.
        let range: NSRange
    }

    // MARK: - Laying the Edit over the Sentences

    /// Where each of `sentences`, the texts of a chapter's sentences in the
    /// order they were heard, lies in `text`, the chapter's text as the user
    /// edited it, apart from the stretches `excluded` (its headings): the
    /// UTF-16 range from the first to the last word of the edit that stands
    /// for the sentence, or nil when the edit deleted all of its words.
    ///
    /// The ranges are in order and never overlap, and together they hold
    /// every word of `text` outside `excluded`, so long as there is at least
    /// one sentence.
    static func ranges(of sentences: [String], in text: String, excluding excluded: [NSRange] = []) -> [NSRange?] {
        // The original words, each with its sentence, and each sentence's
        // stretch of them.
        var original: [(key: String, sentence: Int)] = []
        var sentenceWords: [Range<Int>] = []
        for (number, sentence) in sentences.enumerated() {
            let start = original.count
            original += words(in: sentence).map { (key: $0.key, sentence: number) }
            sentenceWords.append(start..<original.count)
        }
        let edited = words(in: text).filter { word in
            !excluded.contains { NSIntersectionRange($0, word.range).length > 0 }
        }
        let pairs = alignedWords(original.map(\.key), sentences: sentenceWords, edited.map(\.key))

        // The sentence each word of the edit stands for: a matched word,
        // its original's; any other, the sentence of the original words
        // among which it stands.
        var owners = [Int?](repeating: nil, count: edited.count)
        for (originalWord, editedWord) in pairs {
            owners[editedWord] = original[originalWord].sentence
        }
        var before = (original: -1, edited: -1)
        for after in pairs.map({ (original: $0.0, edited: $0.1) }) + [(original: original.count, edited: edited.count)] {
            let editedGap = (before.edited + 1)..<after.edited
            let originalGap = (before.original + 1)..<after.original
            for (position, editedWord) in editedGap.enumerated() {
                if !originalGap.isEmpty {
                    // Changed words: shared out by position among the
                    // sentences of the words they replace.
                    let originalWord = originalGap.lowerBound + position * originalGap.count / editedGap.count
                    owners[editedWord] = original[originalWord].sentence
                } else if before.original >= 0 {
                    // Inserted words: the sentence before them.
                    owners[editedWord] = original[before.original].sentence
                } else if after.original < original.count {
                    // Inserted before the first sentence: that sentence.
                    owners[editedWord] = original[after.original].sentence
                }
            }
            before = after
        }

        // Each sentence runs from its first word to its last.
        var ranges = [NSRange?](repeating: nil, count: sentences.count)
        for (editedWord, owner) in owners.enumerated() {
            guard let owner else { continue }
            let range = edited[editedWord].range
            ranges[owner] = ranges[owner].map { NSUnionRange($0, range) } ?? range
        }
        return ranges
    }

    // MARK: - Words

    /// The punctuation and symbols a word is matched without, at its ends.
    private static let trimmed = CharacterSet.punctuationCharacters.union(.symbols)

    /// The words of `text`: each run of characters that are not white
    /// space, with what it is matched by and where it lies.
    static func words(in text: String) -> [Word] {
        var words: [Word] = []
        var offset = 0
        var start: Int?
        var current = String.UnicodeScalarView()
        /// Ends the word being read, if any, at the current offset.
        func endWord() {
            guard let wordStart = start else { return }
            words.append(Word(key: key(of: String(current)), range: NSRange(location: wordStart, length: offset - wordStart)))
            start = nil
            current = String.UnicodeScalarView()
        }
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                endWord()
            } else {
                if start == nil {
                    start = offset
                }
                current.append(scalar)
            }
            offset += scalar.utf16.count
        }
        endWord()
        return words
    }

    /// What `word` is matched by: lower case, without the punctuation and
    /// symbols at either end, so "Porter." matches "porter"; a word of
    /// nothing but punctuation is matched as it is.
    static func key(of word: String) -> String {
        let lowered = word.lowercased()
        let stripped = lowered.trimmingCharacters(in: trimmed)
        return stripped.isEmpty ? lowered : stripped
    }

    // MARK: - Whole Sentences

    /// The words of `a`, the original words, whose sentences are the
    /// stretches `sentences`, matched with words of `b`, the edit's, as
    /// pairs of their indices, each pair later in both than the one before:
    /// whole sentences found word for word in the edit first, then the
    /// words between them (`matches`).
    static func alignedWords(_ a: [String], sentences: [Range<Int>], _ b: [String]) -> [(Int, Int)] {
        var found: [(Int, Int)] = []
        var nextA = 0
        var nextB = 0
        for (sentence, start) in wholeSentences(a, sentences: sentences, b) {
            let words = sentences[sentence]
            found += matches(a, nextA..<words.lowerBound, b, nextB..<start)
            for offset in 0..<words.count {
                found.append((words.lowerBound + offset, start + offset))
            }
            nextA = words.upperBound
            nextB = start + words.count
        }
        return found + matches(a, nextA..<a.count, b, nextB..<b.count)
    }

    /// The sentences of `a` found word for word in `b`, each as its index
    /// in `sentences` and the index in `b` of its first word: of the
    /// sentences whose words no other sentence shares, and that are found
    /// once in `b`, the longest run in the same order in both, none
    /// overlapping the one before.
    ///
    /// Each stretch of `b` as long as such a sentence is compared by a
    /// rolling hash, and a stretch whose hash matches is compared word by
    /// word, so the search takes one pass over `b` for each length of
    /// sentence.
    private static func wholeSentences(_ a: [String], sentences: [Range<Int>], _ b: [String]) -> [(Int, Int)] {
        let hashesA = a.map(\.hashValue)
        let hashesB = b.map(\.hashValue)
        // Each sentence's hash, and how many sentences have it.
        let sentenceHashes = sentences.map { rollingHash(of: hashesA[$0]) }
        var sentencesWithHash: [Int: Int] = [:]
        for (sentence, words) in sentences.enumerated() where !words.isEmpty {
            sentencesWithHash[sentenceHashes[sentence], default: 0] += 1
        }
        // The hashes wanted, by length: those of sentences found once.
        var wanted: [Int: Set<Int>] = [:]
        for (sentence, words) in sentences.enumerated()
        where !words.isEmpty && words.count <= b.count && sentencesWithHash[sentenceHashes[sentence]] == 1 {
            wanted[words.count, default: []].insert(sentenceHashes[sentence])
        }
        // Where each wanted hash starts in `b`, or -1 when it does more
        // than once.
        var starts: [Int: Int] = [:]
        for (length, hashes) in wanted {
            var hash = rollingHash(of: hashesB[0..<length])
            let highest = power(length - 1)
            for start in 0...(b.count - length) {
                if start > 0 {
                    // Slides the window one word on: the first word out,
                    // the next word in.
                    hash = (hash &- hashesB[start - 1] &* highest) &* hashBase &+ hashesB[start + length - 1]
                }
                if hashes.contains(hash) {
                    starts[hash] = starts[hash] == nil ? start : -1
                }
            }
        }
        // The sentences found once, in their order, each checked word by
        // word against the stretch found.
        var candidates: [(Int, Int)] = []
        for (sentence, words) in sentences.enumerated() where !words.isEmpty {
            let hash = sentenceHashes[sentence]
            guard sentencesWithHash[hash] == 1, let start = starts[hash], start >= 0, start + words.count <= b.count,
                  a[words].elementsEqual(b[start..<(start + words.count)]) else { continue }
            candidates.append((sentence, start))
        }
        var anchored: [(Int, Int)] = []
        var nextStart = 0
        for (sentence, start) in longestIncreasingRun(of: candidates) where start >= nextStart {
            anchored.append((sentence, start))
            nextStart = start + sentences[sentence].count
        }
        return anchored
    }

    /// The multiplier of the rolling hash: a large odd number, so the
    /// hashes of different stretches seldom meet.
    private static let hashBase = 1_000_003

    /// The rolling hash of the word hashes `hashes`, in order.
    private static func rollingHash(of hashes: some Collection<Int>) -> Int {
        hashes.reduce(0) { $0 &* hashBase &+ $1 }
    }

    /// `hashBase` to the power `exponent`, wrapping.
    private static func power(_ exponent: Int) -> Int {
        var result = 1
        for _ in 0..<max(0, exponent) {
            result = result &* hashBase
        }
        return result
    }

    // MARK: - Words Between Sentences

    /// The words of the stretch `rangeA` of `a` matched with words of the
    /// stretch `rangeB` of `b` that read the same, as pairs of their
    /// indices, each pair later in both than the one before.
    static func matches(_ a: [String], _ rangeA: Range<Int>, _ b: [String], _ rangeB: Range<Int>) -> [(Int, Int)] {
        var found: [(Int, Int)] = []
        var pending: [(Range<Int>, Range<Int>)] = [(rangeA, rangeB)]
        // About forty passes over both stretches at most, however
        // pathological the edit: anything left unmatched then is shared out
        // by position.
        var budget = 40 * (rangeA.count + rangeB.count + 1)
        while let (stretchA, stretchB) = pending.popLast() {
            var lowA = stretchA.lowerBound
            var lowB = stretchB.lowerBound
            var highA = stretchA.upperBound
            var highB = stretchB.upperBound
            // The words both stretches begin and end with.
            while lowA < highA, lowB < highB, a[lowA] == b[lowB] {
                found.append((lowA, lowB))
                lowA += 1
                lowB += 1
            }
            while lowA < highA, lowB < highB, a[highA - 1] == b[highB - 1] {
                highA -= 1
                highB -= 1
                found.append((highA, highB))
            }
            guard lowA < highA, lowB < highB else { continue }
            budget -= (highA - lowA) + (highB - lowB)
            guard budget > 0 else { continue }
            let anchors = uniqueAnchors(a, lowA..<highA, b, lowB..<highB)
            guard !anchors.isEmpty else {
                if (highA - lowA) * (highB - lowB) <= wordByWordLimit {
                    found += longestCommonSubsequence(a, lowA..<highA, b, lowB..<highB)
                }
                continue
            }
            // The anchors hold the stretch in place; what lies between two
            // of them is aligned the same way, in turn.
            var nextA = lowA
            var nextB = lowB
            for (anchorA, anchorB) in anchors {
                found.append((anchorA, anchorB))
                if nextA < anchorA, nextB < anchorB {
                    pending.append((nextA..<anchorA, nextB..<anchorB))
                }
                nextA = anchorA + 1
                nextB = anchorB + 1
            }
            if nextA < highA, nextB < highB {
                pending.append((nextA..<highA, nextB..<highB))
            }
        }
        return found.sortedStably { $0.0 < $1.0 }
    }

    /// The words found once in each of the stretches `rangeA` of `a` and
    /// `rangeB` of `b`, paired, in the longest run that is in the same order
    /// in both.
    private static func uniqueAnchors(_ a: [String], _ rangeA: Range<Int>, _ b: [String], _ rangeB: Range<Int>) -> [(Int, Int)] {
        // Each word's index when it is found once, and -1 when more often.
        var onceInA: [String: Int] = [:]
        for index in rangeA {
            onceInA[a[index]] = onceInA[a[index]] == nil ? index : -1
        }
        var onceInB: [String: Int] = [:]
        for index in rangeB {
            onceInB[b[index]] = onceInB[b[index]] == nil ? index : -1
        }
        var candidates: [(Int, Int)] = []
        for (word, indexA) in onceInA where indexA >= 0 {
            if let indexB = onceInB[word], indexB >= 0 {
                candidates.append((indexA, indexB))
            }
        }
        candidates.sortStably { $0.0 < $1.0 }
        return longestIncreasingRun(of: candidates)
    }

    /// The longest run of `pairs`, which are in order of their first index,
    /// whose second indices rise too, found by patience sorting.
    private static func longestIncreasingRun(of pairs: [(Int, Int)]) -> [(Int, Int)] {
        // The pair ending the best run of each length found so far, by
        // index into `pairs`, and the pair before each in its run.
        var tails: [Int] = []
        var previous = [Int](repeating: -1, count: pairs.count)
        for (index, pair) in pairs.enumerated() {
            var low = 0
            var high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if pairs[tails[middle]].1 < pair.1 {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            if low > 0 {
                previous[index] = tails[low - 1]
            }
            if low == tails.count {
                tails.append(index)
            } else {
                tails[low] = index
            }
        }
        var run: [(Int, Int)] = []
        var cursor = tails.last ?? -1
        while cursor >= 0 {
            run.append(pairs[cursor])
            cursor = previous[cursor]
        }
        return run.reversed()
    }

    /// The longest common subsequence of the stretches `rangeA` of `a` and
    /// `rangeB` of `b`, as pairs of the indices of its words, by dynamic
    /// programming: for stretches small enough (`wordByWordLimit`).
    private static func longestCommonSubsequence(
        _ a: [String],
        _ rangeA: Range<Int>,
        _ b: [String],
        _ rangeB: Range<Int>
    ) -> [(Int, Int)] {
        let rows = rangeA.count
        let columns = rangeB.count
        let width = columns + 1
        // lengths[i * width + j]: the subsequence's length from word i of
        // the stretch of `a` and word j of the stretch of `b` onwards.
        var lengths = [Int32](repeating: 0, count: (rows + 1) * width)
        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                let cell = row * width + column
                if a[rangeA.lowerBound + row] == b[rangeB.lowerBound + column] {
                    lengths[cell] = lengths[cell + width + 1] + 1
                } else {
                    lengths[cell] = max(lengths[cell + width], lengths[cell + 1])
                }
            }
        }
        var pairs: [(Int, Int)] = []
        var row = 0
        var column = 0
        while row < rows, column < columns {
            if a[rangeA.lowerBound + row] == b[rangeB.lowerBound + column] {
                pairs.append((rangeA.lowerBound + row, rangeB.lowerBound + column))
                row += 1
                column += 1
            } else if lengths[(row + 1) * width + column] >= lengths[row * width + column + 1] {
                row += 1
            } else {
                column += 1
            }
        }
        return pairs
    }
}
