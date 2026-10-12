import Foundation

/// A sketch of the one helper `PatienceDiff.partners(of:in:)` (T06) and
/// `TranscriptEditAlignment.matches` (FR05) could share: PatienceDiff's
/// steps, made generic over the key, with TranscriptEditAlignment's two
/// tunables as parameters (the most pairs an anchorless stretch may hold and
/// still be lined up exactly, and an optional cap on the work).
///
/// If one parameterized copy reproduces BOTH shipped outputs exactly, the two
/// files differ only in tunables and key type, not in the algorithm.
enum SharedPatience {
    /// Lines up `old[oldRange]` with `new[newRange]`, writing each old word's
    /// partner (an index in `new`) into `partners`, which is indexed like
    /// `old`; words left unmatched keep what `partners` held (-1).
    ///
    /// - Parameters:
    ///   - exactLimit: PatienceDiff's `largestExactStretch` (4,000,000) or
    ///     TranscriptEditAlignment's `wordByWordLimit` (90,000).
    ///   - budget: nil for no cap (PatienceDiff), or
    ///     TranscriptEditAlignment's `40 * (|A| + |B| + 1)`.
    static func lineUp<Key: Hashable>(
        _ old: [Key], _ oldRange: Range<Int>, _ new: [Key], _ newRange: Range<Int>,
        exactLimit: Int, budget: Int?, into partners: inout [Int]
    ) {
        var remaining = budget
        var stretches: [(old: Range<Int>, new: Range<Int>)] = [(oldRange, newRange)]
        while let stretch = stretches.popLast() {
            var oldLow = stretch.old.lowerBound
            var oldHigh = stretch.old.upperBound
            var newLow = stretch.new.lowerBound
            var newHigh = stretch.new.upperBound
            // Common words at the stretch's start, then at its end.
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
            // TranscriptEditAlignment's cap, charged exactly where it charges
            // it: after the common ends, before the fixed points.
            if let left = remaining {
                let after = left - ((oldHigh - oldLow) + (newHigh - newLow))
                remaining = after
                guard after > 0 else { continue }
            }
            let fixed = longestRisingChain(of: wordsOnceInEach(old, oldLow..<oldHigh, new, newLow..<newHigh))
            guard !fixed.isEmpty else {
                lineUpExactly(old, oldLow..<oldHigh, new, newLow..<newHigh, limit: exactLimit, into: &partners)
                continue
            }
            // Each stretch between fixed points, on its own (an empty one is
            // dropped when popped, so pushing it changes nothing).
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
    }

    /// How often a word stands in each stretch, and where it stood last.
    /// (Swift does not allow a type nested in a generic function, so it
    /// lives here rather than inside `wordsOnceInEach` as in PatienceDiff.)
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

    /// The words standing exactly once in each stretch, in the old order.
    static func wordsOnceInEach<Key: Hashable>(
        _ old: [Key], _ oldRange: Range<Int>, _ new: [Key], _ newRange: Range<Int>
    ) -> [(old: Int, new: Int)] {
        var occurrences: [Key: Occurrences] = [:]
        occurrences.reserveCapacity(oldRange.count)
        for index in oldRange {
            occurrences[old[index], default: Occurrences()].noteOld(at: index)
        }
        for index in newRange {
            guard var entry = occurrences[new[index]] else { continue }
            entry.noteNew(at: index)
            occurrences[new[index]] = entry
        }
        return occurrences.values
            .filter { $0.oldCount == 1 && $0.newCount == 1 }
            .map { (old: $0.oldIndex, new: $0.newIndex) }
            .sorted { $0.old < $1.old }
    }

    /// The longest chain of `points` whose new indices rise: patience sorting
    /// (key-free, so TranscriptEditAlignment's whole-sentence step could use
    /// it too).
    static func longestRisingChain(of points: [(old: Int, new: Int)]) -> [(old: Int, new: Int)] {
        var tops: [Int] = []
        var follows = [Int](repeating: -1, count: points.count)
        for (index, point) in points.enumerated() {
            var low = 0
            var high = tops.count
            while low < high {
                let middle = (low + high) / 2
                if points[tops[middle]].new < point.new { low = middle + 1 } else { high = middle }
            }
            if low > 0 { follows[index] = tops[low - 1] }
            if low == tops.count { tops.append(index) } else { tops[low] = index }
        }
        var chain: [(old: Int, new: Int)] = []
        var index = tops.last ?? -1
        while index >= 0 {
            chain.append(points[index])
            index = follows[index]
        }
        return chain.reversed()
    }

    /// An exact longest common subsequence, each old word paired as early in
    /// the new stretch as it can be; a stretch over `limit` pairs stays
    /// unmatched.
    static func lineUpExactly<Key: Hashable>(
        _ old: [Key], _ oldRange: Range<Int>, _ new: [Key], _ newRange: Range<Int>,
        limit: Int, into partners: inout [Int]
    ) {
        let n = oldRange.count
        let m = newRange.count
        guard n > 0, m > 0, n <= limit / m else { return }
        let width = m + 1
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
    }
}

// MARK: - The two thin adapters the cleanup would leave behind

/// PatienceDiff.partners(of:in:) through the shared helper.
func patienceDiffViaShared(_ old: [UInt64], _ new: [UInt64]) -> [Int] {
    var partners = [Int](repeating: -1, count: old.count)
    SharedPatience.lineUp(old, 0..<old.count, new, 0..<new.count,
                          exactLimit: PatienceDiff.largestExactStretch, budget: nil, into: &partners)
    return partners
}

/// TranscriptEditAlignment.matches(_:_:_:_:) through the shared helper: the
/// same pairs, sorted by their first index.
func transcriptMatchesViaShared(_ a: [String], _ rangeA: Range<Int>, _ b: [String], _ rangeB: Range<Int>) -> [(Int, Int)] {
    var partners = [Int](repeating: -1, count: a.count)
    SharedPatience.lineUp(a, rangeA, b, rangeB,
                          exactLimit: TranscriptEditAlignment.wordByWordLimit,
                          budget: 40 * (rangeA.count + rangeB.count + 1), into: &partners)
    return rangeA.compactMap { partners[$0] >= 0 ? ($0, partners[$0]) : nil }
}
