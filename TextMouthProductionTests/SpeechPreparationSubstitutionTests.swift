import Foundation
import XCTest
@testable import TextMouth

/// The substitution rules build each rule's text in one forward pass
/// (PERF01). These tests hold the pass to the algorithm it replaced, kept
/// here line for line (`legacyTransform`): the same text, byte for byte, and
/// the same offset maps, over random texts full of emoji, combining marks,
/// line endings, adjacent matches, and empty replacements. The benchmark
/// times both on a long generated chapter, so the gain is in the test log.
@MainActor
final class SpeechPreparationSubstitutionTests: XCTestCase {

    // MARK: - The premise

    /// Foundation converts a UTF-16 range to string indices on scalar
    /// boundaries, even inside a character. The old back-to-front pass
    /// relied on that to convert each range against text already changed
    /// after it, and it is why the forward pass, which converts every range
    /// against the unchanged text, makes exactly the same replacements.
    func testRangesConvertOnScalarBoundariesInsideCharacters() {
        XCTAssertNotNil(Range(NSRange(location: 0, length: 1), in: "\r\n"), "a CR LF line ending split in two")
        XCTAssertNotNil(Range(NSRange(location: 0, length: 1), in: "e\u{0301}"), "a letter and its combining accent")
    }

    // MARK: - Oracle

    /// Random texts and random sets of rules give exactly what the old
    /// algorithm gave: the same characters, and the same map at every stage.
    ///
    /// The texts mix letters, spaces, both line endings and lone carriage
    /// returns, precomposed and decomposed accents, a lone combining mark,
    /// emoji with skin tones, a flag, curly quotes, em dashes, and the
    /// abbreviations the standard rules expand. The rules cover every
    /// matcher (plain, case-sensitive, whole-word, regular expressions with
    /// groups) and every kind of replacement: empty, shorter, longer, an
    /// emoji, and matches of no length, which sit right beside other matches.
    func testRandomTextsAndRulesMatchTheOldAlgorithm() {
        var random = BenchmarkProse(seed: 0xF0F0_2024)
        var comparedStages = 0
        for trial in 0..<400 {
            let text = (0..<random.roll(48)).map { _ in Self.alphabet[random.roll(Self.alphabet.count)] }.joined()
            // A random selection of the rules, in a random order: each later
            // rule reads the text the earlier ones made.
            let rules = Self.rulePool.filter { _ in random.chance(35) }.shuffled(using: &random)
            let service = TextSubstitutionService(rules: rules)
            let label = "trial \(trial): \(text.debugDescription) with \(rules.map(\.name))"

            let expected = legacyTransform(text, by: service)
            let actual = service.transform(text)

            XCTAssertTrue(haveIdenticalBytes(actual.modifiedText, expected.modifiedText), label)
            XCTAssertEqual(actual.offsetMap, expected.offsetMap, label)
            comparedStages += expected.offsetMap.stages.count
        }
        // An oracle that compared nothing would prove nothing.
        XCTAssertGreaterThan(comparedStages, 400, "too few rules changed anything")
    }

    /// A transformation keeps the text it made and its offset maps, and no
    /// copy of the text it started from (the audit's C17): nothing reads
    /// one, and a cached speech would keep a source chapter alive by it. The
    /// offsets still map both ways.
    func testATransformationKeepsNoCopyOfTheOriginalText() {
        let rule = SubstitutionRule(name: "Doctor", pattern: "Dr.", replacement: "Doctor")
        let transformation = TextSubstitutionService(rules: [rule]).transform("Dr. Hale arrived.")

        XCTAssertEqual(transformation.modifiedText, "Doctor Hale arrived.")
        XCTAssertEqual(
            Set(Mirror(reflecting: transformation).children.compactMap(\.label)),
            ["modifiedText", "offsetMap"]
        )
        XCTAssertEqual(transformation.toOriginalOffset(7), 4)
        XCTAssertEqual(transformation.toModifiedOffset(4), 7)
    }

    /// Generated prose with the standard rules matches the old algorithm on
    /// a whole chapter, the shape the benchmark times.
    func testAGeneratedChapterMatchesTheOldAlgorithm() {
        var prose = BenchmarkProse(seed: 7)
        let text = prose.text(utf16Length: 30_000)
        let service = TextSubstitutionService(rules: TextSubstitutionService.benchmarkRules)

        let expected = legacyTransform(text, by: service)
        let actual = service.transform(text)

        XCTAssertTrue(haveIdenticalBytes(actual.modifiedText, expected.modifiedText))
        XCTAssertEqual(actual.offsetMap, expected.offsetMap)
        XCTAssertFalse(expected.offsetMap.stages.isEmpty, "the standard rules should change generated prose")
    }

    // MARK: - Edge cases

    /// Matches that touch, and an empty replacement between them, leave the
    /// text between matches exactly as it was.
    func testAdjacentMatchesAndEmptyReplacementsKeepTheTextBetween() {
        let service = TextSubstitutionService(rules: [
            SubstitutionRule(name: "Drop a", pattern: "a", replacement: ""),
            SubstitutionRule(name: "Lengthen b", pattern: "b", replacement: "BBB"),
        ])

        let result = service.transform("aab🙂abba")

        XCTAssertEqual(result.modifiedText, "BBB🙂BBBBBB")
        XCTAssertEqual(result.toModifiedOffset(3), 3, "the emoji, after the first b's three")
        XCTAssertEqual(result.toOriginalOffset(3), 3)
        XCTAssertEqual(result.toModifiedOffset(5), 5, "the a removed after the emoji, at the next b's three")
    }

    /// A rule whose every match has no length inserts its replacement
    /// between every two characters, and the map still finds each one.
    func testMatchesOfNoLengthInsertBetweenCharacters() {
        let service = TextSubstitutionService(rules: [
            SubstitutionRule(name: "Between", pattern: "x*", replacement: "-", isRegex: true),
        ])

        let result = service.transform("ab")

        XCTAssertEqual(result.modifiedText, "-a-b-")
        XCTAssertEqual(result.toModifiedOffset(1), 3, "b follows two inserted hyphens")
        XCTAssertEqual(result.toOriginalOffset(3), 1)
    }

    /// A rule that removes combining marks takes them out of the middle of
    /// characters, as the old algorithm did.
    func testRemovingCombiningMarksWorksInsideCharacters() {
        let service = TextSubstitutionService(rules: [
            SubstitutionRule(name: "Marks", pattern: "\\p{M}", replacement: "", isRegex: true),
        ])
        let text = "Cafe\u{0301} 👍🏽 cre\u{0300}me"

        XCTAssertTrue(haveIdenticalBytes(service.transform(text).modifiedText, legacyTransform(text, by: service).modifiedText))
        XCTAssertEqual(service.transform(text).modifiedText, "Cafe 👍🏽 creme")
    }

    // MARK: - Benchmark

    /// Times the user's own rules over generated chapters, the old algorithm
    /// first, then today's, checking they agree.
    ///
    /// In the performance review (Debug, hosted), the old algorithm took
    /// 236 ms at 250K UTF-16 units, 845 ms at 500K, and 3.24 s at a million.
    /// Sizes up to 500K run with the suite; set
    /// `TEST_RUNNER_TEXTMOUTH_LARGE_BENCHMARKS=1` for a million and two
    /// million as well.
    func testBenchmarkTheRulesOverALongChapter() {
        var prose = BenchmarkProse(seed: 11)
        let sizes = benchmarkSizes([250_000, 500_000], large: [1_000_000, 2_000_000])
        let source = prose.text(utf16Length: sizes.max() ?? 0)
        let service = TextSubstitutionService(rules: TextSubstitutionService.benchmarkRules)
        let emDashOnly = TextSubstitutionService(rules: TextSubstitutionService.benchmarkRules.filter { $0.name == "Em dash to pause" })

        for size in sizes {
            let chapter = BenchmarkProse.prefix(of: source, utf16Length: size)
            let old = benchmarkTiming { legacyTransform(freshCopy(of: chapter), by: service) }
            let new = benchmarkTiming { service.transform(freshCopy(of: chapter)) }
            let oldEmDash = benchmarkTiming { legacyTransform(freshCopy(of: chapter), by: emDashOnly) }
            let newEmDash = benchmarkTiming { emDashOnly.transform(freshCopy(of: chapter)) }

            XCTAssertTrue(haveIdenticalBytes(new.value.modifiedText, old.value.modifiedText), "size \(size)")
            XCTAssertEqual(new.value.offsetMap, old.value.offsetMap, "size \(size)")
            reportBenchmark("PERF01 substitution rules", [
                "utf16Length": chapter.utf16Length,
                "oldMilliseconds": old.milliseconds,
                "newMilliseconds": new.milliseconds,
                "emDashRuleOldMilliseconds": oldEmDash.milliseconds,
                "emDashRuleNewMilliseconds": newEmDash.milliseconds,
                "mapPoints": new.value.offsetMap.stages.reduce(0) { $0 + $1.points.count },
            ])
        }
    }

    // MARK: - The old algorithm

    /// `TextSubstitutionService.transform(_:)` as it was before PERF01, line
    /// for line: each rule's replacements were made in place, back to front.
    /// Each rule's matches are found by the app's own matchers, which PERF01
    /// left unchanged and PERF02 moved into `SubstitutionPass`.
    private func legacyTransform(_ text: String, by service: TextSubstitutionService) -> TextTransformation {
        // The enabled rules with a pattern, in order, or none while
        // substitutions are off.
        let pass = service.substitutionPass
        guard !pass.rules.isEmpty else { return .identity(text) }

        var current = text
        var stages: [OffsetMap] = []

        for rule in pass.rules {
            let replacements = pass.replacements(of: rule, in: current).filter {
                Range($0.range, in: current) != nil
            }
            guard !replacements.isEmpty else { continue }

            var shift = 0
            var totalDelta = 0
            var points: [(targetPos: Int, cumulativeDelta: Int)] = []
            for rep in replacements {
                let adjustedStart = rep.range.location + shift
                let replacementLength = rep.replacement.utf16Length
                let lenDiff = rep.range.length - replacementLength
                totalDelta += lenDiff
                let afterInModified = adjustedStart + replacementLength
                points.append((targetPos: afterInModified, cumulativeDelta: totalDelta))
                shift -= lenDiff
            }

            var newText = current
            for rep in replacements.reversed() {
                guard let stringRange = Range(rep.range, in: newText) else { continue }
                newText.replaceSubrange(stringRange, with: rep.replacement)
            }
            current = newText
            stages.append(OffsetMap(points: points))
        }

        return TextTransformation(modifiedText: current, offsetMaps: stages)
    }

    // MARK: - Fixtures

    /// The pieces random texts are made of.
    private static let alphabet = [
        "a", "a", "b", "A", "x", " ", " ", "  ", "\n", "\r\n", "\r", "é", "e\u{0301}", "\u{0301}",
        "🙂", "👍🏽", "🇳🇴", "—", "“", "”", ".", ",", "|", " | ", "Mr.", "ab", "\t",
    ]

    /// The rules random trials choose from.
    private static let rulePool: [SubstitutionRule] = [
        SubstitutionRule(name: "Drop a", pattern: "a", replacement: ""),
        SubstitutionRule(name: "Double a", pattern: "a", replacement: "AA"),
        SubstitutionRule(name: "ab to emoji", pattern: "ab", replacement: "🙂"),
        SubstitutionRule(name: "Case-sensitive x", pattern: "x", replacement: "why", caseSensitive: true),
        SubstitutionRule(name: "Whole word a", pattern: "a", replacement: "the letter a", wholeWord: true),
        SubstitutionRule(name: "Whole word bar", pattern: "|", replacement: "I", wholeWord: true),
        SubstitutionRule(name: "OCR bar", pattern: " | ", replacement: " I "),
        SubstitutionRule(name: "Spaces", pattern: "\\s+", replacement: " ", isRegex: true),
        SubstitutionRule(name: "Line endings", pattern: "\\r\\n?", replacement: "\n", isRegex: true),
        SubstitutionRule(name: "Swap", pattern: "(a)(b)", replacement: "$2$1", isRegex: true),
        SubstitutionRule(name: "Compose", pattern: "e\u{0301}", replacement: "é"),
        SubstitutionRule(name: "Marks", pattern: "\\p{M}", replacement: "", isRegex: true),
        SubstitutionRule(name: "Between", pattern: "x*", replacement: "-", isRegex: true),
        SubstitutionRule(name: "Em dash", pattern: "—", replacement: " — "),
        SubstitutionRule(name: "Mister", pattern: "\\bMr\\.", replacement: "Mister", isRegex: true),
        SubstitutionRule(name: "Skin tone", pattern: "\u{1F3FD}", replacement: ""),
        SubstitutionRule(name: "Quote", pattern: "“", replacement: "\""),
    ]
}
