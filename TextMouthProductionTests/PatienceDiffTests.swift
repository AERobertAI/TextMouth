import XCTest
@testable import TextMouth

/// Lining up two texts' words by a patience diff (T06, `PatienceDiff`): the
/// common ends first, then the words found once in each as fixed points in
/// their longest chain of the same order, recursively, and an exact longest
/// common subsequence for a small stretch with no fixed point. Pure: no
/// window, no file.
final class PatienceDiffTests: XCTestCase {

    // MARK: - Helpers

    /// The fine words' keys of `text`, one word a key.
    private func keys(_ text: String) -> [UInt64] {
        FineWords.keys(in: text)
    }

    /// The old words' partners when `old` is lined up with `new`, both read
    /// as fine words.
    private func partners(_ old: String, _ new: String) -> [Int] {
        PatienceDiff.partners(of: keys(old), in: keys(new))
    }

    /// Asserts what every lining up promises: one partner (or -1) for each
    /// old word, each partner the same word, no new word taken twice, and
    /// partners rising through the old text.
    private func assertWellFormed(_ partners: [Int], old: [UInt64], new: [UInt64], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(partners.count, old.count, file: file, line: line)
        var last = -1
        for (index, partner) in partners.enumerated() where partner >= 0 {
            guard partner < new.count, index < old.count else {
                XCTFail("old word \(index)'s partner \(partner) is past the new text", file: file, line: line)
                return
            }
            XCTAssertEqual(old[index], new[partner], "old word \(index) lines up with another word", file: file, line: line)
            XCTAssertGreaterThan(partner, last, "old word \(index) lines up out of order", file: file, line: line)
            last = partner
        }
    }

    // MARK: - The Rules

    /// Two texts the same line up word for word.
    func testIdenticalTextsLineUpWordForWord() {
        let text = "The volunteers met at the mill on the first dry Saturday of March, with spades and a borrowed pump."
        XCTAssertEqual(partners(text, text), Array(0..<keys(text).count))
    }

    /// The words the two share at both ends line up first, and a word put
    /// in or taken out between them lines up with nothing.
    func testTheCommonEndsLineUpFirst() {
        let old = "the wheel was oak eleven feet across"
        let new = "the wheel was seasoned oak eleven feet across"
        XCTAssertEqual(partners(old, new), [0, 1, 2, 4, 5, 6, 7])
        XCTAssertEqual(partners(new, old), [0, 1, 2, -1, 3, 4, 5, 6])
    }

    /// Between the common ends, words found once in each text are fixed
    /// points, and the stretches between them line up on their own: the
    /// repeated "the" lines up within its own stretch, never across a fixed
    /// point.
    func testWordsFoundOnceInEachAreFixedPoints() {
        let old = "sluice the weir the granary the hopper"
        let new = "pump sluice the weir and the granary then the hopper"
        let lined = partners(old, new)
        XCTAssertEqual(lined, [1, 2, 3, 5, 6, 8, 9])
        assertWellFormed(lined, old: keys(old), new: keys(new))
    }

    /// When fixed points stand in another order in the new text, the longest
    /// chain of them in the same order lines up, and the words that moved
    /// against it line up with nothing.
    func testTheLongestChainInTheSameOrderLinesUp() {
        let old = "alder birch cedar damson elder"
        let new = "damson elder alder birch cedar"
        XCTAssertEqual(partners(old, new), [2, 3, 4, -1, -1])
    }

    /// A stretch with no fixed point lines up exactly, by a longest common
    /// subsequence, each old word as early in the new stretch as it can.
    func testAStretchWithoutAFixedPointLinesUpExactly() {
        // "spade" and "rake" each stand once in one text and twice in the
        // other, so nothing between "first" and "last" is a fixed point.
        let lined = partners("first spade rake spade last", "first rake spade rake last")
        XCTAssertEqual(lined, [0, -1, 1, 2, 4])
    }

    /// A stretch without a fixed point too large to line up exactly (more
    /// than `largestExactStretch` pairs of words) stays unmatched rather
    /// than fill a table of that size, while the common ends around it still
    /// line up, though no word of them stands once; a small stretch lines up.
    func testAStretchTooLargeToLineUpExactlyStaysUnmatched() {
        let pairs = PatienceDiff.largestExactStretch / 4
        let side = Int(Double(pairs).squareRoot()) + 1
        // `side` pairs of words a side, the two words alternating, between
        // ends of words that stand several times, so no word stands once:
        // the stretch holds about 4 × side² > largestExactStretch pairs.
        let ends = ["the", "end", "the", "end"]
        let old = ends + Array(repeating: ["spade", "rake"], count: side).flatMap { $0 } + ends
        let new = ends + Array(repeating: ["rake", "spade"], count: side).flatMap { $0 } + ends
        let large = PatienceDiff.partners(of: keys(old.joined(separator: " ")), in: keys(new.joined(separator: " ")))
        XCTAssertEqual(Array(large.prefix(4)), [0, 1, 2, 3], "the common start lines up")
        XCTAssertEqual(Array(large.suffix(4)), Array((new.count - 4)..<new.count), "the common end lines up")
        XCTAssertEqual(large.dropFirst(4).dropLast(4).filter { $0 >= 0 }.count, 0, "the large stretch stays unmatched")

        let small = partners("first spade rake spade rake last", "first rake spade rake spade last")
        XCTAssertEqual(small.filter { $0 >= 0 }.count, 5, "a small stretch lines up: first, three of the four, last")
    }

    /// A paragraph moved elsewhere is, to a diff, a removal there and the
    /// same words put in here: the larger part of the text keeps its
    /// order, and the moved words line up with nothing.
    func testAMovedPassageLinesUpWithNothing() {
        let old = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda"
        let new = "alpha beta delta epsilon zeta eta theta iota kappa lambda gamma"
        let lined = partners(old, new)
        XCTAssertEqual(lined.count, 11)
        XCTAssertEqual(lined.first, 0)
        XCTAssertEqual(lined.dropFirst(2).first, -1, "gamma moved: it lines up with nothing")
        XCTAssertEqual(Array(lined.dropFirst(3)), [2, 3, 4, 5, 6, 7, 8, 9])
    }

    /// Whatever the texts, the lining up is well formed and the same on
    /// every run: texts of a few common words, put in, taken out, and
    /// replaced at random.
    func testTheLiningUpIsWellFormedAndTheSameEveryRun() {
        var generator = SeededWords(seed: 7)
        for _ in 0..<40 {
            let old = generator.words(count: 60)
            var new = old
            for _ in 0..<8 {
                let at = generator.next(below: max(1, new.count))
                switch generator.next(below: 3) {
                case 0: new.insert(generator.word(), at: at)
                case 1: if !new.isEmpty { new.remove(at: min(at, new.count - 1)) }
                default: if !new.isEmpty { new[min(at, new.count - 1)] = generator.word() }
                }
            }
            let oldKeys = keys(old.joined(separator: " "))
            let newKeys = keys(new.joined(separator: " "))
            let lined = PatienceDiff.partners(of: oldKeys, in: newKeys)
            assertWellFormed(lined, old: oldKeys, new: newKeys)
            XCTAssertEqual(PatienceDiff.partners(of: oldKeys, in: newKeys), lined, "the same on every run")
        }
    }

    /// Empty texts line up with nothing, and never trap.
    func testEmptyTextsNeverTrap() {
        XCTAssertEqual(PatienceDiff.partners(of: [], in: []), [])
        XCTAssertEqual(PatienceDiff.partners(of: [], in: keys("mill")), [])
        XCTAssertEqual(PatienceDiff.partners(of: keys("mill wheel"), in: []), [-1, -1])
        XCTAssertEqual(PatienceDiff.longestRisingChain(of: []).count, 0)
    }
}

/// A small seeded source of common words, so a test's texts are the same on
/// every run.
private struct SeededWords {
    /// The words drawn from: common ones, which stand many times, and a few
    /// rarer ones, which may stand once.
    private static let vocabulary = ["the", "and", "of", "a", "to", "in", "mill", "wheel", "stone", "flour", "sluice", "weir"]
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// The next number below `bound` (SplitMix64).
    mutating func next(below bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Int(z % UInt64(max(1, bound)))
    }

    /// A word of the vocabulary.
    mutating func word() -> String {
        Self.vocabulary[next(below: Self.vocabulary.count)]
    }

    /// `count` words.
    mutating func words(count: Int) -> [String] {
        (0..<count).map { _ in word() }
    }
}
