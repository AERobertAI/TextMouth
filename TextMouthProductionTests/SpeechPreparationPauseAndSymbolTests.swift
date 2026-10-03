import Foundation
import XCTest
@testable import TextMouth

/// The punctuation pauses and the repeated-symbol scan read a chapter once,
/// a character at a time (PERF05). These tests hold each to the algorithm it
/// replaced, kept here line for line (`legacyPauses`, `legacyRuns`): the same
/// text, byte for byte, and the same maps, and the same runs, over random
/// texts made of the characters at each rule's edges. The benchmarks time
/// old and new on long generated chapters, so the gain is in the test log.
@MainActor
final class SpeechPreparationPauseAndSymbolTests: XCTestCase {

    // MARK: - Pauses: oracle

    /// Random texts at every level, whole and between levels, pause exactly
    /// as before: the same characters and the same map.
    ///
    /// The texts mix every pause pattern's characters with what can make
    /// them part of another character: a combining mark after a space or a
    /// period, CR LF line endings beside lone LFs and CRs, an Arabic number
    /// sign that joins the character after it, a zero-width joiner, and
    /// emoji with skin tones.
    func testRandomTextsPauseExactlyAsBefore() {
        var random = BenchmarkProse(seed: 0x9A05_E5)
        var pausesCompared = 0
        for trial in 0..<500 {
            let text = (0..<random.roll(40)).map { _ in Self.pauseAlphabet[random.roll(Self.pauseAlphabet.count)] }.joined()
            for level in [0, 0.5, 1, 1.5, 2, 2.5, 3, 4] {
                let label = "trial \(trial), level \(level): \(text.debugDescription)"
                let expected = legacyPauses(text, level: level)
                let actual = ReaderViewModel.applyPunctuationPauses(text, level: level)

                XCTAssertTrue(haveIdenticalBytes(actual.text, expected.text), label)
                XCTAssertEqual(actual.offsetMap, expected.offsetMap, label)
                pausesCompared += expected.offsetMap.points.count
            }
        }
        // An oracle that compared no pauses would prove nothing.
        XCTAssertGreaterThan(pausesCompared, 600, "too few pauses were added")
    }

    /// A generated chapter pauses exactly as before at every level.
    func testAGeneratedChapterPausesExactlyAsBefore() {
        var prose = BenchmarkProse(seed: 5)
        let text = prose.text(utf16Length: 30_000)
        for level in [1.0, 2, 3] {
            let expected = legacyPauses(text, level: level)
            let actual = ReaderViewModel.applyPunctuationPauses(text, level: level)

            XCTAssertTrue(haveIdenticalBytes(actual.text, expected.text), "level \(level)")
            XCTAssertEqual(actual.offsetMap, expected.offsetMap, "level \(level)")
            XCTAssertTrue(actual.offsetMap.hasChanges, "level \(level) should add pauses to prose")
        }
    }

    // MARK: - Pauses: edge cases

    /// Every level adds its pauses, and the map finds each character after
    /// them.
    func testEachLevelAddsItsPauses() {
        let text = "Wait. Then! Why? Yes, no.\n\nNext"

        XCTAssertEqual(ReaderViewModel.applyPunctuationPauses(text, level: 1).text, "Wait.. Then!. Why?. Yes, no.\n\nNext")
        XCTAssertEqual(ReaderViewModel.applyPunctuationPauses(text, level: 2).text, "Wait.. Then!. Why?. Yes,, no.\n\nNext")
        let heavy = ReaderViewModel.applyPunctuationPauses(text, level: 3)
        XCTAssertEqual(heavy.text, "Wait.. Then!. Why?. Yes,, no.\n\n.\n\nNext")
        let next = (text as NSString).range(of: "Next").location
        let pausedNext = (heavy.text as NSString).range(of: "Next").location
        XCTAssertEqual(heavy.offsetMap.toTarget(next), pausedNext)
        XCTAssertEqual(heavy.offsetMap.toSource(pausedNext), next)
    }

    /// A pause is added only where its pattern's characters are whole
    /// characters: a combining mark after the space or the period, a CR LF
    /// line ending, and an Arabic number sign joined to the period each make
    /// another character, as they did before.
    func testAPauseNeedsWholeCharacters() {
        for text in [". \u{0301}x", ".\u{0301} x", "\u{0600}. x", "a\r\n\nb"] {
            let paused = ReaderViewModel.applyPunctuationPauses(text, level: 3)
            XCTAssertTrue(haveIdenticalBytes(paused.text, legacyPauses(text, level: 3).text), text.debugDescription)
            XCTAssertFalse(paused.offsetMap.hasChanges, text.debugDescription)
        }
        // The same characters with nothing joined to them do pause.
        XCTAssertEqual(ReaderViewModel.applyPunctuationPauses("a\n\n\nb", level: 3).text, "a\n\n.\n\n\nb")
    }

    // MARK: - Pauses: benchmark

    /// Times the pauses over generated chapters, the old algorithm first,
    /// then today's, checking they agree.
    ///
    /// In the performance review, the old algorithm took 640 ms at 250K
    /// UTF-16 units (hosted Debug) and 1.9 to 3.1 s at 500K (optimized), at
    /// level 1. The suite times level 1 at 250K; set
    /// `TEST_RUNNER_TEXTMOUTH_LARGE_BENCHMARKS=1` for 500K and level 3 too.
    func testBenchmarkThePauses() {
        var prose = BenchmarkProse(seed: 13)
        let sizes = benchmarkSizes([250_000], large: [500_000])
        let levels: [Double] = largeBenchmarksRequested ? [1, 3] : [1]
        let source = prose.text(utf16Length: sizes.max() ?? 0)

        for size in sizes {
            let chapter = BenchmarkProse.prefix(of: source, utf16Length: size)
            for level in levels {
                let old = benchmarkTiming { legacyPauses(freshCopy(of: chapter), level: level) }
                let new = benchmarkTiming { ReaderViewModel.applyPunctuationPauses(freshCopy(of: chapter), level: level) }

                XCTAssertTrue(haveIdenticalBytes(new.value.text, old.value.text), "size \(size), level \(level)")
                XCTAssertEqual(new.value.offsetMap, old.value.offsetMap, "size \(size), level \(level)")
                reportBenchmark("PERF05 punctuation pauses", [
                    "utf16Length": chapter.utf16Length,
                    "level": level,
                    "oldMilliseconds": old.milliseconds,
                    "newMilliseconds": new.milliseconds,
                    "pauses": new.value.offsetMap.points.count,
                ])
            }
        }
    }

    // MARK: - Repeated symbols: oracle

    /// Random texts give exactly the runs found before, for the default
    /// symbols and for a set of symbols that other spellings equal.
    ///
    /// The texts mix symbols, the spaces that join a run and the line breaks
    /// that end one, a symbol a combining mark is joined to, a keycap, and
    /// the canonically equivalent spellings a character comparison matches:
    /// "≠" and "=" with a combining stroke, the Greek question mark and ";",
    /// the Greek ano teleia and the middle dot, and the Greek varia and the
    /// backtick.
    func testRandomTextsFindExactlyTheRunsFoundBefore() {
        var random = BenchmarkProse(seed: 0x5E4B_0105)
        let symbolSets: [Set<Character>] = [
            Set(SettingsPolicy.repeatedSymbolSet.defaultValue),
            ["≠", ";", "·", "`", "#️⃣", "*", "\u{037E}", "—"],
        ]
        var runsCompared = 0
        for trial in 0..<500 {
            let text = (0..<random.roll(40)).map { _ in Self.symbolAlphabet[random.roll(Self.symbolAlphabet.count)] }.joined()
            for symbols in symbolSets {
                for minimumCount in [2, 3, 4] {
                    let label = "trial \(trial), minimum \(minimumCount), \(symbols.count) symbols: \(text.debugDescription)"
                    let expected = legacyRuns(in: text, of: symbols, minimumCount: minimumCount)

                    XCTAssertEqual(RepeatedSymbolRule.runs(in: text, of: symbols, minimumCount: minimumCount), expected, label)
                    runsCompared += expected.count
                }
            }
        }
        // An oracle that compared no runs would prove nothing.
        XCTAssertGreaterThan(runsCompared, 250, "too few runs were found")
    }

    /// The standard rule finds exactly the runs it found before in a
    /// generated chapter.
    func testAGeneratedChapterHasExactlyTheRunsFoundBefore() {
        var prose = BenchmarkProse(seed: 17)
        let text = prose.text(utf16Length: 200_000)
        let symbols = Set(SettingsPolicy.repeatedSymbolSet.defaultValue)
        let expected = legacyRuns(in: text, of: symbols, minimumCount: 4)

        XCTAssertEqual(RepeatedSymbolRule.runs(in: text, of: symbols, minimumCount: 4), expected)
        XCTAssertFalse(expected.isEmpty, "generated prose should hold separator lines")
    }

    // MARK: - Repeated symbols: edge cases

    /// A spelling the symbol equals as a character still forms its runs,
    /// although it begins with another scalar: "=" with a combining long
    /// stroke is "≠", and the Greek question mark is ";".
    func testCanonicallyEquivalentSpellingsFormRuns() {
        let decomposedUnequal = String(repeating: "=\u{0338}", count: 4)
        let greekQuestionMarks = String(repeating: "\u{037E}", count: 5)

        XCTAssertEqual(RepeatedSymbolRule.runs(in: decomposedUnequal, of: ["≠"], minimumCount: 4).map(\.count), [4])
        XCTAssertEqual(RepeatedSymbolRule.runs(in: greekQuestionMarks, of: [";"], minimumCount: 4).map(\.count), [5])
        // "=" alone is no "≠", and a combining mark makes "*" another character.
        XCTAssertTrue(RepeatedSymbolRule.runs(in: "= = = =", of: ["≠"], minimumCount: 2).isEmpty)
        XCTAssertTrue(RepeatedSymbolRule.runs(in: String(repeating: "*\u{0301}", count: 4), of: ["*"], minimumCount: 2).isEmpty)
    }

    /// Runs after non-ASCII text keep exact UTF-16 offsets.
    func testRunsAfterNonASCIITextKeepExactOffsets() {
        let text = "🙂 “Café” **** then 👍🏽 ===="
        let runs = RepeatedSymbolRule.runs(in: text, of: ["*", "="], minimumCount: 4)
        let nsText = text as NSString

        XCTAssertEqual(runs.map(\.utf16Range), [
            nsText.range(of: "****").location..<NSMaxRange(nsText.range(of: "****")),
            nsText.range(of: "====").location..<NSMaxRange(nsText.range(of: "====")),
        ])
    }

    // MARK: - Repeated symbols: benchmark

    /// Times the standard rule's scan over generated chapters, the old scan
    /// first, then today's, checking they agree.
    ///
    /// In the performance review (hosted Debug), the old scan took 63 ms per
    /// million UTF-16 units and 341 ms at 5.24 million, the user's largest
    /// chapter. The suite times a million; set
    /// `TEST_RUNNER_TEXTMOUTH_LARGE_BENCHMARKS=1` for 5.24 million too.
    func testBenchmarkTheRepeatedSymbolScan() {
        var prose = BenchmarkProse(seed: 19)
        let sizes = benchmarkSizes([1_000_000], large: [5_240_000])
        let source = prose.text(utf16Length: sizes.max() ?? 0)
        let rule = RepeatedSymbolRule.standard
        let symbols = Set(rule.symbols)

        for size in sizes {
            let chapter = BenchmarkProse.prefix(of: source, utf16Length: size)
            let old = benchmarkTiming { legacyRuns(in: freshCopy(of: chapter), of: symbols, minimumCount: rule.threshold) }
            let new = benchmarkTiming { RepeatedSymbolRule.runs(in: freshCopy(of: chapter), of: symbols, minimumCount: rule.threshold) }
            let apply = benchmarkTiming { rule.apply(to: freshCopy(of: chapter)) }

            XCTAssertEqual(new.value.map(\.utf16Range), old.value.map(\.utf16Range), "size \(size)")
            XCTAssertEqual(new.value.map(\.count), old.value.map(\.count), "size \(size)")
            reportBenchmark("PERF05 repeated symbols", [
                "utf16Length": chapter.utf16Length,
                "oldScanMilliseconds": old.milliseconds,
                "newScanMilliseconds": new.milliseconds,
                "newApplyMilliseconds": apply.milliseconds,
                "runs": new.value.count,
            ])
        }
    }

    // MARK: - The old algorithms

    /// `ReaderViewModel.applyPunctuationPauses(_:level:)` as it was before
    /// PERF05, line for line.
    private func legacyPauses(_ text: String, level: Double) -> (text: String, offsetMap: OffsetMap) {
        guard level > 0, ReaderViewModel.hasSpeakableText(text) else { return (text, .identity) }

        var replacements: [(pattern: String, replacement: String)] = []
        if level >= 1 {
            replacements.append((pattern: ". ", replacement: ".. "))
            replacements.append((pattern: "! ", replacement: "!. "))
            replacements.append((pattern: "? ", replacement: "?. "))
        }
        if level >= 2 {
            replacements.append((pattern: ", ", replacement: ",, "))
        }
        if level >= 3 {
            replacements.append((pattern: "\n\n", replacement: "\n\n.\n\n"))
        }

        var result = ""
        result.reserveCapacity(text.count + text.count / 10)
        var sourcePos = 0
        var cumulativeDelta = 0
        var points: [(targetPos: Int, cumulativeDelta: Int)] = []

        while sourcePos < text.utf16Length {
            var matched = false
            for (pattern, replacement) in replacements {
                let patternLen = pattern.utf16Length
                if sourcePos + patternLen > text.utf16Length { continue }
                let startIdx = text.index(atUTF16Offset: sourcePos)
                let endIdx = text.index(atUTF16Offset: sourcePos + patternLen)
                if text[startIdx..<endIdx] == pattern {
                    result += replacement
                    let extraChars = replacement.utf16Length - patternLen
                    cumulativeDelta -= extraChars
                    let targetPosAfter = result.utf16Length
                    points.append((targetPos: targetPosAfter, cumulativeDelta: cumulativeDelta))
                    sourcePos += patternLen
                    matched = true
                    break
                }
            }
            if !matched {
                let idx = text.index(atUTF16Offset: sourcePos)
                let character = text[idx]
                result.append(character)
                sourcePos += String(character).utf16Length
            }
        }

        if points.isEmpty {
            return (text, .identity)
        }
        return (result, OffsetMap(points: points))
    }

    /// `RepeatedSymbolRule.runs(in:of:minimumCount:)` as it was before
    /// PERF05, line for line.
    private func legacyRuns(in text: String, of symbols: Set<Character>, minimumCount: Int) -> [RepeatedSymbolRule.Run] {
        var runs: [RepeatedSymbolRule.Run] = []
        var index = text.startIndex
        var offset = 0
        while index < text.endIndex {
            let symbol = text[index]
            let symbolEnd = text.index(after: index)
            let symbolLength = symbol.utf16.count
            guard symbols.contains(symbol) else {
                index = symbolEnd
                offset += symbolLength
                continue
            }
            var count = 1
            var runEnd = symbolEnd
            var runEndOffset = offset + symbolLength
            while let copy = legacyNextCopy(of: symbol, in: text, at: runEnd) {
                count += 1
                runEnd = copy.end
                runEndOffset += copy.utf16Length
            }
            if count >= max(minimumCount, 2) {
                runs.append(RepeatedSymbolRule.Run(
                    symbol: symbol,
                    count: count,
                    range: index..<runEnd,
                    utf16Range: offset..<runEndOffset
                ))
            }
            index = runEnd
            offset = runEndOffset
        }
        return runs
    }

    /// `RepeatedSymbolRule.nextCopy(of:in:at:)` as it was before PERF05.
    private func legacyNextCopy(
        of symbol: Character,
        in text: String,
        at start: String.Index
    ) -> (end: String.Index, utf16Length: Int)? {
        guard start < text.endIndex else { return nil }
        var position = start
        var length = 0
        if RepeatedSymbolRule.isGap(text[position]) {
            length += text[position].utf16.count
            position = text.index(after: position)
            guard position < text.endIndex else { return nil }
        }
        guard text[position] == symbol else { return nil }
        length += text[position].utf16.count
        return (text.index(after: position), length)
    }

    // MARK: - Fixtures

    /// The pieces random pause texts are made of.
    private static let pauseAlphabet = [
        ".", ".", "!", "?", ",", ",", " ", " ", " ", "\n", "\n", "\r\n", "\r", "a", "b", "\u{0301}",
        "🙂", "👍🏽", "\u{0600}", "\u{200D}", "’", "—", "e\u{0301}", "\t", "\u{00A0}",
    ]

    /// The pieces random repeated-symbol texts are made of.
    private static let symbolAlphabet = [
        "*", "*", "*", "=", "=", "-", "—", "•", "·", "\u{0387}", ";", "\u{037E}", "≠", "=\u{0338}",
        "`", "\u{1FEF}", "#️⃣", "#", "*\u{0301}", " ", " ", " ", "\u{00A0}", "\t", "\n", "\r\n",
        "a", "b", "🙂", "👍🏽", "’", "“",
    ]
}
