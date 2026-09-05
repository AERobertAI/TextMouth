import XCTest
@testable import TextMouth

/// Regression coverage for mappings across sequential pronunciation rules.
@MainActor
final class SubstitutionCompositionTests: XCTestCase {
    /// Editing an earlier word in a later rule shifts an existing breakpoint.
    func testLaterExpansionPreservesEarlierReplacementCoordinates() {
        let service = TextSubstitutionService(rules: [
            SubstitutionRule(pattern: "dog", replacement: "D"),
            SubstitutionRule(pattern: "cat", replacement: "kitten")
        ])

        let result = service.transform("cat dog tail")

        XCTAssertEqual(result.modifiedText, "kitten D tail")
        XCTAssertEqual(result.toOriginalOffset(7), 4)
        XCTAssertEqual(result.toModifiedOffset(4), 7)
        XCTAssertEqual(result.toOriginalOffset(9), 8)
        XCTAssertEqual(result.toModifiedOffset(8), 9)
    }

    /// Three rules with Unicode and both expansion/deletion must preserve an
    /// unchanged suffix in both directions, regardless of rule order.
    func testMixedRulesKeepUTF16SuffixCoordinates() throws {
        let original = "🙂 cat dog tail"
        let rules = [
            SubstitutionRule(pattern: "dog", replacement: "D"),
            SubstitutionRule(pattern: "🙂 ", replacement: ""),
            SubstitutionRule(pattern: "cat", replacement: "kitten")
        ]
        for orderedRules in [rules, Array(rules.reversed())] {
            let result = TextSubstitutionService(rules: orderedRules).transform(original)
            let source = try XCTUnwrap(original.range(of: "tail"))
            let target = try XCTUnwrap(result.modifiedText.range(of: "tail"))
            let sourceOffset = original.utf16Offset(of: source.lowerBound)
            let targetOffset = result.modifiedText.utf16Offset(of: target.lowerBound)

            XCTAssertEqual(result.toOriginalOffset(targetOffset), sourceOffset)
            XCTAssertEqual(result.toModifiedOffset(sourceOffset), targetOffset)
        }
    }
}
