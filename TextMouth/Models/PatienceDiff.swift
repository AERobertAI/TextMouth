import Foundation

/// Lines up two texts' words the way Git's patience diff lines up two
/// versions of a file (T06): for each word of the old text, the word of the
/// new text it stands for, if any. `PlaceRelocator` carries saved places
/// across a rebuilt text by it.
///
/// The measured rules (TEXT-ANCHORS-ADDENDUM-2026-10-10.md, sections 1 and 3):
///
/// 1. **Common ends.** The words the two share at the start, and then at the
///    end, are lined up first.
/// 2. **Fixed points.** Between them, the words that stand exactly once in
///    each are fixed points, and the longest chain of them that keeps the
///    same order in both (patience sorting) is lined up.
/// 3. **Recursion.** The stretches between fixed points are lined up the same
///    way, each on its own, from rule 1.
/// 4. **Small gaps.** A stretch with no fixed point is lined up exactly, by a
///    longest common subsequence, when it is small enough
///    (`largestExactStretch`); a larger one stays unmatched.
///
/// Words are compared by key (`FineWords`): two equal keys are the same
/// word. The lining up is monotonic (a later old word never stands for an
/// earlier new word than an earlier old word does) and the same on every
/// run.
///
/// Myers' diff, Git's default, was measured too: about as good with small
/// snapshots, worse with larger ones and with rewritten sentences, and it
/// gave up on long removals. Patience diff, which Git offers for exactly
/// this kind of text, is the one the addendum chose (section 3).
enum PatienceDiff {
    /// The most pairs of words (old words times new words) a stretch with no
    /// fixed point may hold and still be lined up exactly. Its table keeps a
    /// 32-bit length for each pair of a word or the stretch's end on each
    /// side, (old + 1) × (new + 1) of them: 32 MB at most (one old word
    /// against four million new), for the moment the stretch takes. The
    /// measured program's limit.
    static let largestExactStretch = 4_000_000

    /// How two texts' words line up (`alignment(of:in:)`).
    struct Alignment: Equatable, Sendable {
        /// For each old word, the index of the new word it lines up with, or
        /// -1 when it lines up with none.
        var partners: [Int]
        /// For each old word, whether it lies in a stretch with no fixed
        /// point too large to line up exactly (rule 4), which stays
        /// unmatched for its size, not because the new text changed it: a
        /// long repetitive passage, whose words stand too often to be fixed
        /// points. The diff says nothing of where such a word went.
        var leftForSize: [Bool]
    }

    /// For each word of `old`, the index in `new` of the word it lines up
    /// with, or -1 when it lines up with none (the new text removed or
    /// replaced it, or its stretch was too large to line up). The rules are
    /// the type's.
    static func partners(of old: [UInt64], in new: [UInt64]) -> [Int] {
        alignment(of: old, in: new).partners
    }

    /// How `old` lines up with `new`: each old word's partner, as
    /// `partners(of:in:)` gives it, and which old words were left unmatched
    /// for their stretch's size.
    static func alignment(of old: [UInt64], in new: [UInt64]) -> Alignment {
        var partners = [Int](repeating: -1, count: old.count)
        var leftForSize = [Bool](repeating: false, count: old.count)
        // The stretches still to line up: a range of old words and the range
        // of new words between the same lined-up neighbors. Kept on a stack
        // rather than by recursion, so a long chain of fixed points never
        // runs deep.
        var stretches: [(old: Range<Int>, new: Range<Int>)] = [(0..<old.count, 0..<new.count)]
        while let stretch = stretches.popLast() {
            var oldLow = stretch.old.lowerBound
            var oldHigh = stretch.old.upperBound
            var newLow = stretch.new.lowerBound
            var newHigh = stretch.new.upperBound
            // Rule 1: the words the stretch shares at its start, then at its end.
            while oldLow < oldHigh, newLow < newHigh, old[oldLow] == new[newLow] {
                partners[oldLow] = newLow
                oldLow += 1
                newLow += 1
            }
            while oldLow < oldHigh, newLow < newHigh, old[oldHigh - 1] == new[newHigh - 1] {
                partners[oldHigh - 1] = newHigh - 1
                oldHigh -= 1
                newHigh -= 1
            }
            guard oldLow < oldHigh, newLow < newHigh else { continue }
            let oldRange = oldLow..<oldHigh
            let newRange = newLow..<newHigh
            // Rule 2: the fixed points' longest chain in the same order.
            let fixed = longestRisingChain(of: wordsOnceInEach(old, oldRange, new, newRange))
            guard !fixed.isEmpty else {
                // Rule 4: a stretch with no fixed point.
                if !lineUpExactly(old, oldRange, new, newRange, into: &partners) {
                    for word in oldRange { leftForSize[word] = true }
                }
                continue
            }
            // Rule 3: each stretch between fixed points, on its own.
            var oldNext = oldLow
            var newNext = newLow
            for point in fixed {
                partners[point.old] = point.new
                stretches.append((oldNext..<point.old, newNext..<point.new))
                oldNext = point.old + 1
                newNext = point.new + 1
            }
            stretches.append((oldNext..<oldHigh, newNext..<newHigh))
        }
        return Alignment(partners: partners, leftForSize: leftForSize)
    }

    /// A word standing exactly once in each of two stretches: where it
    /// stands in the old and in the new.
    typealias FixedPoint = (old: Int, new: Int)

    /// The words that stand exactly once in `old[oldRange]` and exactly once
    /// in `new[newRange]`, in the old text's order.
    static func wordsOnceInEach(_ old: [UInt64], _ oldRange: Range<Int>, _ new: [UInt64], _ newRange: Range<Int>) -> [FixedPoint] {
        /// How often a word stands in each stretch, and where it stood last.
        struct Occurrences {
            var oldCount = 0
            var oldIndex = 0
            var newCount = 0
            var newIndex = 0

            /// Counts the word once more in the old stretch, at `index`.
            mutating func noteOld(at index: Int) {
                oldCount += 1
                oldIndex = index
            }

            /// Counts the word once more in the new stretch, at `index`.
            mutating func noteNew(at index: Int) {
                newCount += 1
                newIndex = index
            }
        }
        var occurrences: [UInt64: Occurrences] = [:]
        occurrences.reserveCapacity(oldRange.count)
        for index in oldRange {
            occurrences[old[index], default: Occurrences()].noteOld(at: index)
        }
        // Only words the old stretch holds can be fixed points, so a word
        // only the new stretch holds is not counted at all. Looked up, then
        // written back: mutating through the optional subscript
        // (`occurrences[key]?.noteNew(at:)`) measured two and a half times
        // slower over a whole book.
        for index in newRange {
            guard var entry = occurrences[new[index]] else { continue }
            entry.noteNew(at: index)
            occurrences[new[index]] = entry
        }
        // The dictionary's order changes from run to run; sorting by the old
        // index, which no two words share, makes the result the same on
        // every run.
        return occurrences.values
            .filter { $0.oldCount == 1 && $0.newCount == 1 }
            .map { FixedPoint(old: $0.oldIndex, new: $0.newIndex) }
            .sortedStably { $0.old < $1.old }
    }

    /// The longest chain of `points` (in the old text's order) whose places
    /// in the new text rise too: patience sorting. Each pile keeps the point
    /// that ends the best chain of its length found so far, with the smallest
    /// new index, and each point remembers the point it follows.
    static func longestRisingChain(of points: [FixedPoint]) -> [FixedPoint] {
        guard !points.isEmpty else { return [] }
        // tops[length - 1]: the index in `points` of the point ending the
        // best chain of that length.
        var tops: [Int] = []
        var follows = [Int](repeating: -1, count: points.count)
        for (index, point) in points.enumerated() {
            // The first pile whose top stands at or after this point in the new text.
            var low = 0
            var high = tops.count
            while low < high {
                let middle = (low + high) / 2
                if points[tops[middle]].new < point.new {
                    low = middle + 1
                } else {
                    high = middle
                }
            }
            if low > 0 { follows[index] = tops[low - 1] }
            if low == tops.count {
                tops.append(index)
            } else {
                tops[low] = index
            }
        }
        var chain: [FixedPoint] = []
        var index = tops.last ?? -1
        while index >= 0 {
            chain.append(points[index])
            index = follows[index]
        }
        return chain.reversed()
    }

    /// Lines up `old[oldRange]` with `new[newRange]` by an exact longest
    /// common subsequence, writing each old word's partner into `partners`;
    /// a stretch larger than `largestExactStretch` stays unmatched, and the
    /// result is false then (true when the stretch was lined up, or one
    /// side of it is empty). Of the longest subsequences, the one taken
    /// pairs each old word as early in the new stretch as it can, as the
    /// measured program did.
    @discardableResult
    static func lineUpExactly(_ old: [UInt64], _ oldRange: Range<Int>, _ new: [UInt64], _ newRange: Range<Int>, into partners: inout [Int]) -> Bool {
        let n = oldRange.count
        let m = newRange.count
        guard n > 0, m > 0 else { return true }
        guard n <= largestExactStretch / m else { return false }
        let width = m + 1
        // lengths[i * width + j]: the longest common subsequence of the old
        // stretch's words from i on and the new stretch's from j on.
        var lengths = [Int32](repeating: 0, count: (n + 1) * width)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lengths[i * width + j] = old[oldRange.lowerBound + i] == new[newRange.lowerBound + j]
                    ? lengths[(i + 1) * width + j + 1] + 1
                    : max(lengths[(i + 1) * width + j], lengths[i * width + j + 1])
            }
        }
        var i = 0
        var j = 0
        while i < n, j < m {
            if old[oldRange.lowerBound + i] == new[newRange.lowerBound + j] {
                partners[oldRange.lowerBound + i] = newRange.lowerBound + j
                i += 1
                j += 1
            } else if lengths[(i + 1) * width + j] >= lengths[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return true
    }
}
