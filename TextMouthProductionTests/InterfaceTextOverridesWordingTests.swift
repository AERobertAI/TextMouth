import Foundation
import XCTest
@testable import TextMouth

// Tests of what the Interface Language group says about the person's own lines (FR39 phase 10, step 4): the counts, each
// ignored line as a sentence with its reason last, each line in use whose English has changed, and the commands' words.
//
// Shared with the iPhone's unit bundle (project.yml): the sentences are pure, and the iPhone's Settings draws the same ones
// the Mac's group does. Under hosted tests System is English, so the words below are English.

final class InterfaceTextOverridesWordingTests: XCTestCase {
    /// The name of a language the way the group says it, without the interface language's help.
    private let names: (String) -> String = { code in code == "es" ? "Spanish" : code }

    /// A key of the outcome.
    private func key(_ id: String, _ language: String = "es") -> InterfaceTextOverridesOutcome.Key {
        .init(language: language, id: id)
    }

    // MARK: - The counts

    func testNothingReadSaysNoLinesAndListsNothing() {
        let summary = InterfaceTextOverridesSummary(.empty, languageName: names)

        XCTAssertEqual(summary.inUse, "Your own lines in use: 0")
        XCTAssertEqual(summary.ignored, "Your own lines ignored: 0")
        XCTAssertEqual(summary.details, [])
    }

    func testTheCountsAreHowManyLinesAreInUseAndIgnored() {
        var outcome = InterfaceTextOverridesOutcome()
        outcome.inUse = [key("a.one"), key("a.two"), key("a.three")]
        outcome.ignored = [.init(key: key("b.one"), reason: .emptyForm)]
        outcome.unchanged = 400

        let summary = InterfaceTextOverridesSummary(outcome, languageName: names)

        XCTAssertEqual(summary.inUse, "Your own lines in use: 3")
        XCTAssertEqual(summary.ignored, "Your own lines ignored: 1")
    }

    // MARK: - The sentences

    /// Each ignored line is one sentence: its ID, its language, and the reason last.
    func testAnIgnoredLineSaysItsIDItsLanguageAndThenTheReason() {
        var outcome = InterfaceTextOverridesOutcome()
        outcome.ignored = [
            .init(key: key("common.sleepTimer"), reason: .placeholdersDiffer),
            .init(key: key("common.books", "xx"), reason: .unknownLanguage),
        ]

        let summary = InterfaceTextOverridesSummary(outcome, languageName: names)

        XCTAssertEqual(summary.details, [
            "Ignored line common.sleepTimer in Spanish. Its placeholders differ from the English line's.",
            "Ignored line common.books in xx. TextMouth does not have that language.",
        ])
    }

    /// A line in use whose English changed is listed, so the person can check it still says the same.
    func testALineWhoseEnglishChangedIsListed() {
        var outcome = InterfaceTextOverridesOutcome()
        outcome.inUse = [key("common.sleepTimer")]
        outcome.outdatedEnglish = [key("common.sleepTimer")]

        let summary = InterfaceTextOverridesSummary(outcome, languageName: names)

        XCTAssertEqual(summary.details, [
            "Check line common.sleepTimer in Spanish. Its English has changed since you wrote it, and your line still applies.",
        ])
    }

    /// A file ignored whole has one sentence of its own, first.
    func testAFileProblemComesFirst() {
        var outcome = InterfaceTextOverridesOutcome.ignoredWhole(.notJSON)
        outcome.ignored = [.init(key: key("a.b"), reason: .noText)]

        let summary = InterfaceTextOverridesSummary(outcome, languageName: names)

        XCTAssertEqual(summary.details.first, "Problem with your file of own lines. The file is not valid JSON.")
        XCTAssertEqual(summary.details.count, 2)
    }

    /// The list is cut at 50 lines, with a last line for the rest; the count above it stays exact.
    func testALongListIsCutAndSaysHowManyMoreThereAre() {
        var outcome = InterfaceTextOverridesOutcome()
        outcome.ignored = (0..<120).map { .init(key: key(String(format: "line.n%03d", $0)), reason: .unknownID) }

        let summary = InterfaceTextOverridesSummary(outcome, languageName: names)

        XCTAssertEqual(summary.ignored, "Your own lines ignored: 120")
        XCTAssertEqual(summary.details.count, InterfaceTextOverridesSummary.largestList + 1)
        XCTAssertEqual(summary.details.last, "And 70 more ignored lines. The debug log lists each one.")
    }

    /// The line for the rest is a plural line: "1 more" says line, not lines.
    func testTheMoreLineIsPlural() {
        var outcome = InterfaceTextOverridesOutcome()
        outcome.ignored = (0..<51).map { .init(key: key(String(format: "line.n%03d", $0)), reason: .unknownID) }

        let summary = InterfaceTextOverridesSummary(outcome, languageName: names)

        XCTAssertEqual(summary.details.last, "And 1 more ignored line. The debug log lists it.")
    }

    /// The list of lines whose English changed stops at 50 as well, and says how many more there are.
    func testTheOutdatedListIsCutToo() {
        var outcome = InterfaceTextOverridesOutcome()
        outcome.outdatedEnglish = (0..<55).map { key(String(format: "line.n%03d", $0)) }

        let summary = InterfaceTextOverridesSummary(outcome, languageName: names)

        XCTAssertEqual(summary.details.count, InterfaceTextOverridesSummary.largestList + 1)
        XCTAssertEqual(summary.details.last, "And 5 more lines to check, whose English has changed. They are in your file.")
        outcome.outdatedEnglish.removeLast(54)
        XCTAssertEqual(InterfaceTextOverridesSummary(outcome, languageName: names).details.count, 1)
    }

    // MARK: - Reasons

    /// Every reason has its own sentence, in full, ending as a sentence ends, none repeated.
    func testEveryReasonIsASentenceOfItsOwn() {
        let sentences = InterfaceTextIgnoredReason.allCases.map { InterfaceTextOverridesWording.reason($0) }
            + InterfaceTextFileProblem.allCases.map { InterfaceTextOverridesWording.reason($0) }

        XCTAssertEqual(Set(sentences).count, sentences.count)
        for sentence in sentences {
            XCTAssertTrue(sentence.hasSuffix("."), sentence)
            XCTAssertFalse(sentence.contains("%"), sentence)
            XCTAssertGreaterThan(sentence.count, 8, sentence)
        }
    }

    /// The debug log's English has a sentence for each reason too, none repeated.
    func testEveryReasonHasALogSentence() {
        let sentences = InterfaceTextIgnoredReason.allCases.map(\.logSentence) + InterfaceTextFileProblem.allCases.map(\.logSentence)

        XCTAssertEqual(Set(sentences).count, sentences.count)
        XCTAssertFalse(sentences.contains(""))
    }

    // MARK: - The commands

    func testTheCommandsAreNamedAndExplained() {
        XCTAssertEqual(InterfaceTextOverridesWording.editTitle, "Edit Interface Text…")
        XCTAssertEqual(InterfaceTextOverridesWording.exportTitle, "Export Interface Text…")
        XCTAssertFalse(InterfaceTextOverridesWording.editHint.isEmpty)
        XCTAssertFalse(InterfaceTextOverridesWording.exportHint.isEmpty)
        XCTAssertEqual(InterfaceTextOverridesWording.exported(fileName: "interface_text-es.json"), "Exported the interface text to interface_text-es.json.")
        XCTAssertEqual(PhoneSettingsRow.exportInterfaceText.title, "Export Interface Text…")
        XCTAssertEqual(PhoneSettingsRow.exportInterfaceText.hint, InterfaceTextOverridesWording.exportHint)
    }
}
