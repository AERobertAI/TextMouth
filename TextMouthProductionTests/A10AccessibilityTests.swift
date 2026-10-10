import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

// The wording and behavior TODO A10's audit fixed, one class for each kind
// of fix: what VoiceOver and a braille display are given, pinned in words.

// MARK: - The Capture-Group Hint

/// The substitution rule editor's replacement field tells VoiceOver how a
/// regular expression puts back what a group of its pattern matched: a
/// dollar sign and the group's number, which `NSRegularExpression` reads.
/// It used to say "backslash 1", which gives a plain digit.
@MainActor
final class SubstitutionCaptureGroupHintTests: XCTestCase {
    /// The hint names the dollar sign in words, since VoiceOver speaks "$1"
    /// as "one dollar", and shows it as typed, for a braille display.
    func testTheReplacementHintNamesTheDollarSign() {
        XCTAssertEqual(
            SubstitutionRuleEditorView.replacementHint,
            "In a regular expression, a dollar sign and a group's number, as in $1 or $2, put back what that group matched."
        )
    }

    /// What the hint says is what a regular-expression rule does: "$1" and
    /// "$2" put back their groups, and "\1" gives a plain "1".
    func testADollarSignAndANumberPutBackTheGroup() {
        let dollars = SubstitutionRule(pattern: "(\\w+)@(\\w+)", replacement: "$2 at $1", isRegex: true)
        XCTAssertEqual(SubstitutionRuleEditorView.testResult(of: dollars, on: "me@home"), "home at me")

        let backslash = SubstitutionRule(pattern: "(\\w+)@", replacement: "\\1 at", isRegex: true)
        XCTAssertEqual(SubstitutionRuleEditorView.testResult(of: backslash, on: "me@"), "1 at")
    }
}
