import XCTest
@testable import TextMouth

/// The repeated-symbol rule on its own: what a run is, the threshold, the
/// three styles, the names a count uses, and the offset map between the
/// text and the speech made from it. Speech preparation, settings, and the
/// Settings controls are covered by their own test classes.
final class RepeatedSymbolRuleTests: XCTestCase {

    // MARK: - Threshold

    /// Until the user changes anything, a run of 4 or more of the default
    /// symbols is read as a count, and a shorter run as written.
    func testTheStandardRuleCountsRunsOfFourOrMore() {
        let rule = RepeatedSymbolRule.standard

        XCTAssertEqual(rule.style, .sayCount)
        XCTAssertEqual(rule.threshold, 4)
        XCTAssertEqual(rule.symbols, SettingsPolicy.repeatedSymbolSet.defaultValue)
        XCTAssertEqual(spoken("A *** B", by: rule), "A *** B")
        XCTAssertEqual(spoken("A **** B", by: rule), "A 4 asterisks B")
    }

    /// The threshold is the shortest run collapsed: a run of exactly that
    /// many symbols is collapsed, one fewer is not.
    func testTheThresholdIsTheShortestRunCollapsed() {
        let rule = makeRule(threshold: 5)

        XCTAssertEqual(spoken("----", by: rule), "----")
        XCTAssertEqual(spoken("-----", by: rule), "5 hyphens")
        XCTAssertEqual(spoken("------", by: rule), "6 hyphens")
    }

    /// -1 never collapses a run, in any style, however long the run.
    func testMinusOneNeverCollapses() {
        let text = "Line\n" + String(repeating: "=", count: 80) + "\n* * * * * * *"
        for style in RepeatedSymbolStyle.allCases {
            let rule = makeRule(style, threshold: -1)
            XCTAssertFalse(rule.collapsesRuns, "\(style)")
            let result = rule.apply(to: text)
            XCTAssertEqual(result.text, text, "\(style)")
            XCTAssertFalse(result.offsetMap.hasChanges, "\(style)")
        }
    }

    /// Every negative threshold means -1, and 0 and 1 act as 2, since every
    /// run already has two symbols; past 99 the threshold is 99.
    func testThresholdsAreValidatedAsTheyAreMade() {
        XCTAssertEqual(makeRule(threshold: -7).threshold, -1)
        XCTAssertEqual(makeRule(threshold: Int.min).threshold, -1)
        XCTAssertEqual(makeRule(threshold: 0).threshold, 2)
        XCTAssertEqual(makeRule(threshold: 1).threshold, 2)
        XCTAssertEqual(makeRule(threshold: 2).threshold, 2)
        XCTAssertEqual(makeRule(threshold: 99).threshold, 99)
        XCTAssertEqual(makeRule(threshold: 100).threshold, 99)
        XCTAssertEqual(makeRule(threshold: Int.max).threshold, 99)
        XCTAssertEqual(spoken("A ** B", by: makeRule(threshold: 0)), "A 2 asterisks B")
    }

    /// Repeating each symbol reads every run as written, whatever the
    /// threshold.
    func testRepeatEachLeavesEveryRunAsWritten() {
        let rule = makeRule(.repeatEach, threshold: 2)
        let text = "Rule:\n" + String(repeating: "_", count: 30) + "\n**"

        XCTAssertFalse(rule.collapsesRuns)
        XCTAssertEqual(spoken(text, by: rule), text)
    }

    // MARK: - What a run is

    /// Single spaces between neighbours belong to the run, so a spaced
    /// separator line is one run of 7 asterisks, spanning all 13 characters.
    func testASpacedLineIsOneRun() {
        let text = "* * * * * * *"
        let runs = RepeatedSymbolRule.runs(in: text, of: ["*"], minimumCount: 2)

        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.symbol, "*")
        XCTAssertEqual(runs.first?.count, 7)
        XCTAssertEqual(runs.first?.utf16Range, 0..<13)
        XCTAssertEqual(spoken("End.\n\n" + text + "\n\nStart.", by: .standard), "End.\n\n7 asterisks\n\nStart.")
    }

    /// Neighbours may be written together or a space apart within one run.
    func testARunMayMixSpacedAndAdjacentSymbols() {
        XCTAssertEqual(spoken("** ** **", by: .standard), "6 asterisks")
        XCTAssertEqual(spoken("== = ==", by: .standard), "5 equals signs")
    }

    /// One space of any width separates neighbours, a no-break space or a
    /// tab included, as books set their separators.
    func testOneSpaceOfAnyWidthKeepsARunTogether() {
        for space in ["\u{00A0}", "\t", "\u{2009}", "\u{202F}", "\u{3000}"] {
            let text = ["*", "*", "*", "*"].joined(separator: space)
            XCTAssertEqual(spoken(text, by: .standard), "4 asterisks", space.debugDescription)
        }
    }

    /// Two spaces in a row, or a line break, end a run.
    func testTwoSpacesOrALineBreakEndARun() {
        XCTAssertEqual(spoken("*  *  *  *", by: .standard), "*  *  *  *")
        XCTAssertEqual(spoken("**\n**", by: .standard), "**\n**")
        XCTAssertEqual(spoken("** \n **", by: .standard), "** \n **")
        XCTAssertEqual(spoken("****\r\n****", by: .standard), "4 asterisks\r\n4 asterisks")
    }

    /// Different symbols are different runs: side by side each is counted
    /// on its own, and symbols that alternate form no run at all.
    func testDifferentSymbolsAreDifferentRuns() {
        XCTAssertEqual(spoken("****====", by: .standard), "4 asterisks 4 equals signs")
        XCTAssertEqual(spoken("*=*=*=*=", by: .standard), "*=*=*=*=")
        XCTAssertEqual(spoken("-*-*-*-*", by: .standard), "-*-*-*-*")
        XCTAssertEqual(spoken("* = * = * = * =", by: .standard), "* = * = * = * =")
    }

    /// Only symbols in the set form runs: letters and digits never do, and
    /// neither does a symbol left out of the set.
    func testOnlySymbolsInTheSetFormRuns() {
        let asterisksOnly = makeRule(symbols: "*")

        XCTAssertEqual(spoken("==== ****", by: asterisksOnly), "==== 4 asterisks")
        XCTAssertEqual(spoken("aaaaaa 111111", by: .standard), "aaaaaa 111111")
        // Sentence punctuation is not in the default set.
        XCTAssertEqual(spoken("Wait.... What!!!! Really????", by: .standard), "Wait.... What!!!! Really????")
        XCTAssertEqual(spoken("Wait.... now", by: makeRule(symbols: ".")), "Wait 4 periods now")
    }

    /// A run too short to collapse is passed over whole: none of its symbols
    /// begins another run, and the text after it is still searched.
    func testAShortRunIsPassedOverWhole() {
        XCTAssertEqual(spoken("***-****", by: .standard), "***- 4 asterisks")
        let runs = RepeatedSymbolRule.runs(in: "***x****", of: ["*"], minimumCount: 4)
        XCTAssertEqual(runs.map(\.count), [4])
        XCTAssertEqual(runs.map(\.utf16Range), [4..<8])
    }

    /// A symbol that is one character of two UTF-16 units forms runs too,
    /// and its run spans every unit.
    func testSymbolsBeyondTheBasicPlaneFormRuns() {
        let rule = makeRule(threshold: 2, symbols: "\u{1F525}")  // 🔥
        let runs = RepeatedSymbolRule.runs(in: "a 🔥 🔥 🔥 b", of: ["\u{1F525}"], minimumCount: 2)

        XCTAssertEqual(runs.first?.count, 3)
        XCTAssertEqual(runs.first?.utf16Range, 2..<10)
        XCTAssertEqual(spoken("a 🔥 🔥 🔥 b", by: rule), "a 3 fire b")
    }

    // MARK: - Saying how many

    /// The count replaces the run, with a space wherever the words would
    /// otherwise touch a neighbouring character.
    func testACountNeverTouchesItsNeighbours() {
        XCTAssertEqual(spoken("Name:________", by: .standard), "Name: 8 underscores")
        XCTAssertEqual(spoken("****word", by: .standard), "4 asterisks word")
        XCTAssertEqual(spoken("word****", by: .standard), "word 4 asterisks")
        XCTAssertEqual(spoken("1~~~~2", by: .standard), "1 4 tildes 2")
        XCTAssertEqual(spoken("(####)", by: .standard), "( 4 number signs )")
        XCTAssertEqual(spoken("one **** two", by: .standard), "one 4 asterisks two")
    }

    /// Eighty equals signs are read as "80 equals signs", the user's own
    /// example, and every default symbol reads by its natural name.
    func testCountsReadNaturalNames() {
        XCTAssertEqual(spoken(String(repeating: "=", count: 80), by: .standard), "80 equals signs")
        XCTAssertEqual(spoken("— — — —", by: .standard), "4 em dashes")
        XCTAssertEqual(spoken("────────", by: .standard), "8 horizontal lines")
        XCTAssertEqual(spoken("• • • •", by: .standard), "4 bullets")
        XCTAssertEqual(spoken("-- --", by: .standard), "4 hyphens")
    }

    // MARK: - Leaving out

    /// A separator line left out leaves a sentence boundary in its place, so
    /// the voice pauses between the scenes it separated.
    func testLeavingOutLeavesASentenceBoundary() {
        let rule = makeRule(.leaveOut)

        XCTAssertEqual(spoken("The end.\n\n* * * * * * *\n\nThe start.", by: rule), "The end.\n\n.\n\nThe start.")
        XCTAssertEqual(spoken("Chapter one***** Chapter two", by: rule), "Chapter one . Chapter two")
        XCTAssertEqual(spoken("left====right", by: rule), "left . right")
    }

    /// Nothing is left where speech has not begun or will not go on, so no
    /// chapter starts or ends on a stray pause, and a chapter of nothing but
    /// separators has nothing to say.
    func testLeavingOutAtEitherEndLeavesNothing() {
        let rule = makeRule(.leaveOut)

        XCTAssertEqual(spoken("* * * *\nText", by: rule), "\nText")
        XCTAssertEqual(spoken("Text\n* * * *", by: rule), "Text\n")
        XCTAssertEqual(spoken("Text\n* * * *\n= = = =\n", by: rule), "Text\n.\n\n")
        XCTAssertEqual(spoken("* * * *", by: rule), "")
        let separatorsOnly = spoken("====\n\n* * * *\n", by: rule)
        XCTAssertFalse(ReaderViewModel.hasSpeakableText(separatorsOnly), separatorsOnly.debugDescription)
    }

    /// Shorter runs are read as written when leaving out, as when counting.
    func testLeavingOutKeepsShorterRuns() {
        XCTAssertEqual(spoken("Wait -- no ***", by: makeRule(.leaveOut)), "Wait -- no ***")
    }

    // MARK: - Names

    /// Each common symbol has a natural plural name.
    func testCommonSymbolsHaveNaturalPluralNames() {
        let expected: [Character: String] = [
            "*": "asterisks", "-": "hyphens", "=": "equals signs", "_": "underscores", "~": "tildes",
            "#": "number signs", "+": "plus signs", ".": "periods", "!": "exclamation marks",
            "?": "question marks", "/": "slashes", "\\": "backslashes", "|": "vertical bars",
            "<": "less-than signs", ">": "greater-than signs", "^": "carets", "&": "ampersands",
            "%": "percent signs", "$": "dollar signs", "@": "at signs", "\u{2022}": "bullets",
            "\u{2013}": "en dashes", "\u{2014}": "em dashes", "\u{2500}": "horizontal lines",
            "\u{2026}": "ellipses", "\u{2550}": "double horizontal lines",
        ]
        for (symbol, name) in expected {
            XCTAssertEqual(RepeatedSymbolNames.plural(of: symbol), name, String(symbol))
        }
    }

    /// Every symbol in the default set, and every ASCII punctuation mark or
    /// symbol, has a name of its own rather than its Unicode name.
    func testEveryDefaultAndASCIISymbolHasANaturalName() {
        let ascii = (0x21...0x7E).compactMap(Unicode.Scalar.init).map(Character.init)
            .filter(RepeatedSymbolRule.canFormRuns)
        XCTAssertEqual(ascii.count, 32)
        for symbol in ascii + Array(SettingsPolicy.repeatedSymbolSet.defaultValue) {
            XCTAssertNotNil(RepeatedSymbolNames.common[symbol], String(symbol))
        }
    }

    /// A symbol the table does not name is called by its Unicode name in
    /// lower case; variation selectors and joiners add nothing, and a symbol
    /// without a name is called "symbols".
    func testOtherSymbolsFallBackToTheirUnicodeName() {
        XCTAssertEqual(RepeatedSymbolNames.plural(of: "\u{2605}"), "black star")  // ★
        XCTAssertEqual(
            RepeatedSymbolNames.plural(of: "\u{256C}"),  // ╬
            "box drawings double vertical and horizontal"
        )
        XCTAssertEqual(RepeatedSymbolNames.plural(of: "\u{263A}\u{FE0F}"), "white smiling face")  // ☺️
        XCTAssertEqual(RepeatedSymbolNames.plural(of: "\u{E000}"), "symbols")
        XCTAssertEqual(spoken("★★★★", by: makeRule(symbols: "\u{2605}")), "4 black star")
    }

    // MARK: - Which characters can form runs

    /// Punctuation and symbols can form runs; letters, digits, spaces, line
    /// breaks, and invisible characters cannot.
    func testOnlyPunctuationAndSymbolsCanFormRuns() {
        for symbol: Character in ["*", "-", "_", "(", "\u{201C}", "$", "+", "^", "\u{2500}", "\u{1F525}"] {
            XCTAssertTrue(RepeatedSymbolRule.canFormRuns(symbol), String(symbol))
        }
        for other: Character in ["a", "Z", "\u{00E9}", "7", "\u{0663}", " ", "\u{00A0}", "\n", "\u{200B}", "\u{0301}"] {
            XCTAssertFalse(RepeatedSymbolRule.canFormRuns(other), other.unicodeScalars.map { String($0.value, radix: 16) }.joined())
        }
    }

    // MARK: - Offsets

    /// Outside a rewritten run every offset maps exactly, both ways: each
    /// word of the text is found at its mapped place in the speech.
    func testOffsetsOutsideRunsMapExactly() throws {
        let text = "Alpha ******** beta\n* * * *\ngamma ~~~~ delta"
        let result = RepeatedSymbolRule.standard.apply(to: text)
        XCTAssertEqual(result.text, "Alpha 8 asterisks beta\n4 asterisks\ngamma 4 tildes delta")

        for word in ["Alpha", "beta", "gamma", "delta"] {
            let source = try utf16Offset(of: word, in: text)
            let target = try utf16Offset(of: word, in: result.text)
            XCTAssertEqual(result.offsetMap.toTarget(source), target, word)
            XCTAssertEqual(result.offsetMap.toSource(target), source, word)
        }
    }

    /// Every offset inside a long run maps into its count, and every offset
    /// of the count maps back into the run, so seeking into the middle of a
    /// separator never skips the sentence after it.
    func testOffsetsInsideARunStayInsideItsCount() {
        let text = "Before\n" + String(repeating: "=", count: 80) + "\nAfter"
        let result = RepeatedSymbolRule.standard.apply(to: text)

        XCTAssertEqual(result.text, "Before\n80 equals signs\nAfter")
        assertFold(result.offsetMap, source: 7..<87, target: 7..<22)
    }

    /// The same holds for a count longer than its run, and for a run left
    /// out with a pause or with nothing at all.
    func testOffsetsInsideShortAndOmittedRunsStayInsideTheirReplacement() {
        let short = makeRule(threshold: 2).apply(to: "a ** b")
        XCTAssertEqual(short.text, "a 2 asterisks b")
        assertFold(short.offsetMap, source: 2..<4, target: 2..<13)

        let paused = makeRule(.leaveOut).apply(to: "End.\n* * * * *\nStart")
        XCTAssertEqual(paused.text, "End.\n.\nStart")
        assertFold(paused.offsetMap, source: 5..<14, target: 5..<6)

        let removed = makeRule(.leaveOut).apply(to: "* * * * *\nStart")
        XCTAssertEqual(removed.text, "\nStart")
        assertFold(removed.offsetMap, source: 0..<9, target: 0..<0)
    }

    /// Spans replaced by text of every relative length fold as promised:
    /// shorter by any amount, one character, nothing, longer by less than
    /// the span, longer by many times the span, and equal.
    func testSpanReplacementMapFoldsEveryLength() {
        let cases: [(sourceLength: Int, targetLength: Int)] = [
            (80, 15), (9, 2), (9, 1), (9, 0), (2, 0), (3, 4), (3, 5), (2, 13), (5, 30), (4, 4),
        ]
        for (sourceLength, targetLength) in cases {
            var builder = SpanReplacementMap()
            builder.replace(sourceRange: 10..<(10 + sourceLength), withLength: targetLength)
            let map = builder.offsetMap
            let label = "\(sourceLength) replaced by \(targetLength)"
            assertFold(map, source: 10..<(10 + sourceLength), target: 10..<(10 + targetLength), label)
            // The text after the span moves by the difference in length.
            XCTAssertEqual(map.toTarget(10 + sourceLength + 7), 10 + targetLength + 7, label)
            XCTAssertEqual(map.toSource(10 + targetLength + 7), 10 + sourceLength + 7, label)
            XCTAssertEqual(map.toTarget(3), 3, label)
            XCTAssertEqual(builder.points.isEmpty, sourceLength == targetLength, label)
        }
    }

    /// Texts built at random from symbols, spaces, line breaks, letters, and
    /// an emoji keep every promise in every collapsing style: each character
    /// outside a run is found at its mapped offset, offsets inside a run and
    /// its replacement stay inside each other, and the breakpoints stay in
    /// order, as `OffsetMap` requires.
    func testRandomTextsKeepEveryOffsetPromise() throws {
        var random = SeededRandom(seed: 0x5EED)
        let alphabet = ["*", "*", "*", "=", "=", " ", " ", "\n", "a", "b", "🙂", "-"]
        for trial in 0..<300 {
            let text = (0..<Int(random.next() % 40)).map { _ in alphabet[Int(random.next() % UInt64(alphabet.count))] }
                .joined()
            for rule in [makeRule(threshold: 2), makeRule(threshold: 3), makeRule(.leaveOut, threshold: 2)] {
                let label = "trial \(trial), \(rule.style), \(text.debugDescription)"
                let result = rule.apply(to: text)
                let map = result.offsetMap
                assertBreakpointsInOrder(map, label)

                let runs = RepeatedSymbolRule.runs(in: text, of: ["*", "=", "-"], minimumCount: rule.threshold)
                let source = text.utf16.map { $0 }
                let target = result.text.utf16.map { $0 }
                var outside = Set(0..<source.count)
                for run in runs {
                    outside.subtract(run.utf16Range)
                    let replacement = map.toTarget(run.utf16Range.lowerBound)..<map.toTarget(run.utf16Range.upperBound)
                    // Where the next run starts at this one's end and is left
                    // out with nothing, both runs end at one target offset,
                    // which maps back to the later end.
                    let nextStartsAtEnd = runs.contains { $0.utf16Range.lowerBound == run.utf16Range.upperBound }
                    assertFold(map, source: run.utf16Range, target: replacement, label, exactEnd: !nextStartsAtEnd)
                }
                for offset in outside {
                    let mapped = map.toTarget(offset)
                    XCTAssertTrue(target.indices.contains(mapped), label)
                    guard target.indices.contains(mapped) else { continue }
                    XCTAssertEqual(target[mapped], source[offset], "\(label) at \(offset)")
                    XCTAssertEqual(map.toSource(mapped), offset, "\(label) at \(offset)")
                }
            }
        }
    }

    // MARK: - Helpers

    /// A rule with the standard settings except those given.
    private func makeRule(
        _ style: RepeatedSymbolStyle = .sayCount,
        threshold: Int = 4,
        symbols: String = SettingsPolicy.repeatedSymbolSet.defaultValue
    ) -> RepeatedSymbolRule {
        RepeatedSymbolRule(style: style, threshold: threshold, symbols: symbols)
    }

    /// What speech reads for `text` under `rule`.
    private func spoken(_ text: String, by rule: RepeatedSymbolRule) -> String {
        rule.apply(to: text).text
    }

    /// The UTF-16 offset of the first `word` in `text`.
    private func utf16Offset(of word: String, in text: String) throws -> Int {
        let range = try XCTUnwrap(text.range(of: word), word)
        return text.utf16Offset(of: range.lowerBound)
    }

    /// Checks the promises the map makes for one replaced span: its start and
    /// end map exactly both ways (the start of an empty replacement is its
    /// end), every offset inside the source span maps inside the replacement,
    /// and every offset inside the replacement maps inside the source span.
    ///
    /// - Parameter exactEnd: False where the next span begins at this one's
    ///   end and was removed: the shared target end then maps back to the
    ///   removed span's end, at or after this one's.
    private func assertFold(
        _ map: OffsetMap,
        source: Range<Int>,
        target: Range<Int>,
        _ label: String = "",
        exactEnd: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(map.toTarget(source.lowerBound), target.lowerBound, "start \(label)", file: file, line: line)
        XCTAssertEqual(map.toTarget(source.upperBound), target.upperBound, "end \(label)", file: file, line: line)
        if exactEnd {
            XCTAssertEqual(map.toSource(target.upperBound), source.upperBound, "end back \(label)", file: file, line: line)
        } else {
            XCTAssertGreaterThanOrEqual(map.toSource(target.upperBound), source.upperBound, "end back \(label)", file: file, line: line)
        }
        if !target.isEmpty {
            XCTAssertEqual(map.toSource(target.lowerBound), source.lowerBound, "start back \(label)", file: file, line: line)
        }
        for offset in source {
            XCTAssertTrue(
                (target.lowerBound...target.upperBound).contains(map.toTarget(offset)),
                "source \(offset) maps to \(map.toTarget(offset)), outside \(target) \(label)",
                file: file,
                line: line
            )
        }
        for offset in target {
            XCTAssertTrue(
                (source.lowerBound...source.upperBound).contains(map.toSource(offset)),
                "target \(offset) maps to \(map.toSource(offset)), outside \(source) \(label)",
                file: file,
                line: line
            )
        }
    }

    /// Checks that the breakpoints never go back in either text, which the
    /// linear search of `OffsetMap.toTarget` relies on.
    private func assertBreakpointsInOrder(
        _ map: OffsetMap,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (earlier, later) in zip(map.points, map.points.dropFirst()) {
            XCTAssertLessThanOrEqual(earlier.targetPos, later.targetPos, label, file: file, line: line)
            XCTAssertLessThanOrEqual(
                earlier.targetPos + earlier.cumulativeDelta,
                later.targetPos + later.cumulativeDelta,
                label,
                file: file,
                line: line
            )
        }
    }
}

/// A small deterministic random number generator (SplitMix64), so a failing
/// random text can be reproduced from its trial number.
private struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// The next pseudo-random number.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}
