import XCTest
@testable import TextMouth

/// `PhoneHeadingsModel`: what the phone's Headings sheet offers, says, and
/// focuses, by the spec's "The Headings sheet", in the Mac's words.
@MainActor
final class PhoneHeadingsModelTests: XCTestCase {
    /// A book of three levels: a part, its chapter, the chapter's section,
    /// then a second part.
    private let partOne = Heading(level: 1, text: "Part One", chapterIndex: 0, characterOffset: 0)
    private let chapterOne = Heading(level: 2, text: "The Battle", chapterIndex: 0, characterOffset: 100)
    private let sectionOne = Heading(level: 3, text: "Dawn", chapterIndex: 0, characterOffset: 200)
    private let partTwo = Heading(level: 1, text: "Part Two", chapterIndex: 1, characterOffset: 0)

    /// The book's headings in reading order.
    private var headings: [Heading] { [partOne, chapterOne, sectionOne, partTwo] }

    /// A model whose place is at `chapterIndex`, `characterOffset`, with
    /// `skipped` sections.
    private func model(
        atChapter chapterIndex: Int,
        offset characterOffset: Int,
        skipped: Set<String> = []
    ) -> PhoneHeadingsModel {
        PhoneHeadingsModel(
            headings: headings,
            skippedHeadingIDs: skipped,
            currentHeadingIDs: HeadingNavigatorView.currentHeadingIDs(
                in: headings,
                chapterIndex: chapterIndex,
                characterOffset: characterOffset
            )
        )
    }

    /// The Mac's row details for the model's displayed headings, with a
    /// fixed suffix, as `HeadingNavigatorView.headingItems` gives them.
    private func items(for model: PhoneHeadingsModel) -> [HeadingNavigatorView.HeadingListItem] {
        model.displayedHeadings.map { heading in
            HeadingNavigatorView.HeadingListItem(
                heading: heading,
                isSkipped: model.skippedHeadingIDs.contains(heading.id),
                infoText: "1:03:00",
                accessibilitySuffix: "1 hour, 3 minutes"
            )
        }
    }

    // MARK: The level filter

    /// The filter's choices come in the Mac's order, for the levels the book
    /// has, with "All levels" last.
    func testTheLevelChoicesAreTheMacsInItsOrder() {
        let choices = model(atChapter: 0, offset: 0).levelChoices

        XCTAssertEqual(choices.map(\.label), ["Level 1", "Levels 1 to 2", "All levels"])
        XCTAssertEqual(choices.map(\.id), [1, 2, HeadingNavigatorView.deepestFilterLevel])
    }

    /// Show levels is offered only for a book with more than one level, as
    /// on the Mac.
    func testShowLevelsIsOfferedOnlyForSeveralLevels() {
        XCTAssertTrue(model(atChapter: 0, offset: 0).showsLevelFilter)

        let oneLevel = PhoneHeadingsModel(
            headings: [partOne, partTwo],
            skippedHeadingIDs: [],
            currentHeadingIDs: []
        )
        XCTAssertFalse(oneLevel.showsLevelFilter)
    }

    /// The filter starts at every level, and its value names the filter in
    /// force.
    func testTheLevelFilterStartsAtAllLevels() {
        var headingsModel = model(atChapter: 0, offset: 0)
        XCTAssertEqual(headingsModel.levelFilterValue, "All levels")
        XCTAssertEqual(headingsModel.displayedHeadings, headings)

        headingsModel.maximumLevel = 2
        XCTAssertEqual(headingsModel.levelFilterValue, "Levels 1 to 2")
        XCTAssertEqual(headingsModel.displayedHeadings, [partOne, chapterOne, partTwo])
    }

    // MARK: The display

    /// The display offers the Mac's three modes, starting at Duration.
    func testTheDisplayOffersTheMacsModes() {
        XCTAssertEqual(PhoneHeadingsModel.displayChoices.map(\.label), ["Duration", "Time In", "Percentage"])
        XCTAssertEqual(model(atChapter: 0, offset: 0).displayValue, "Duration")
    }

    // MARK: The rows

    /// The current heading's row says so in the Mac's words, and only that
    /// row does.
    func testTheCurrentHeadingsRowSaysSo() {
        let headingsModel = model(atChapter: 0, offset: 150)
        let rows = headingsModel.rows(from: items(for: headingsModel))

        XCTAssertEqual(rows.filter(\.isCurrent).map(\.id), [chapterOne.id])
        // Fewer rows than two fail here, never trap below.
        guard rows.count >= 2 else { return XCTFail("At least two rows, not \(rows.count)") }
        XCTAssertEqual(rows[1].label, "The Battle (current heading) - level 2, 1 hour, 3 minutes")
        XCTAssertEqual(rows[0].label, "Part One - level 1, 1 hour, 3 minutes")
    }

    /// A skipped section's row starts "Skipped, " and offers Include
    /// Section; any other offers Skip Section.
    func testASkippedRowSaysSoAndOffersToIncludeIt() {
        let headingsModel = model(atChapter: 0, offset: 0, skipped: [sectionOne.id])
        let rows = headingsModel.rows(from: items(for: headingsModel))
        // Fewer rows than three fail here, never trap below.
        guard rows.count >= 3 else { return XCTFail("At least three rows, not \(rows.count)") }

        XCTAssertEqual(rows[2].label, "Skipped, Dawn - level 3, 1 hour, 3 minutes")
        XCTAssertEqual(rows[2].toggleSkipActionName, "Include Section")
        XCTAssertEqual(rows[1].toggleSkipActionName, "Skip Section")
    }

    /// Focus lands on the current heading, under the filter shown: with
    /// levels 1 and 2 shown, a place in the section is in its chapter.
    func testFocusLandsOnTheCurrentHeadingUnderTheFilter() {
        var headingsModel = model(atChapter: 0, offset: 250)
        XCTAssertEqual(headingsModel.initialFocusID(in: headingsModel.rows(from: items(for: headingsModel))), sectionOne.id)

        headingsModel.maximumLevel = 2
        XCTAssertEqual(headingsModel.initialFocusID(in: headingsModel.rows(from: items(for: headingsModel))), chapterOne.id)
    }

    /// Before the first heading, focus lands on the first row; an empty list
    /// has nowhere to land.
    func testFocusFallsToTheFirstRowOrNowhere() {
        let laterHeading = Heading(level: 1, text: "Late", chapterIndex: 2, characterOffset: 10)
        let beforeAny = PhoneHeadingsModel(
            headings: [laterHeading],
            skippedHeadingIDs: [],
            currentHeadingIDs: HeadingNavigatorView.currentHeadingIDs(in: [laterHeading], chapterIndex: 0, characterOffset: 0)
        )
        let rows = beforeAny.rows(from: [
            HeadingNavigatorView.HeadingListItem(heading: laterHeading, isSkipped: false, infoText: "", accessibilitySuffix: "")
        ])
        XCTAssertNil(beforeAny.currentHeadingID)
        XCTAssertEqual(beforeAny.initialFocusID(in: rows), laterHeading.id)

        let empty = PhoneHeadingsModel(headings: [], skippedHeadingIDs: [], currentHeadingIDs: [])
        XCTAssertNil(empty.initialFocusID(in: []))
    }

    // MARK: After a jump

    /// A text book that plays after the jump says nothing, since its own
    /// words say where it is; paused, it says the Mac's heading words.
    func testATextBooksJumpSaysTheHeadingOnlyWhilePaused() {
        XCTAssertNil(PhoneHeadingsModel.jumpAnnouncement(
            arrivingAt: chapterOne, in: headings, isAudioBook: false, playsAfterJump: true
        ))
        XCTAssertEqual(PhoneHeadingsModel.jumpAnnouncement(
            arrivingAt: chapterOne, in: headings, isAudioBook: false, playsAfterJump: false
        ), "Heading: The Battle")
    }

    /// An audiobook says the heading playing or paused, since its recording
    /// can't name the place.
    func testAnAudiobooksJumpAlwaysSaysTheHeading() {
        XCTAssertEqual(PhoneHeadingsModel.jumpAnnouncement(
            arrivingAt: partTwo, in: headings, isAudioBook: true, playsAfterJump: true
        ), "Heading: Part Two")
        XCTAssertEqual(PhoneHeadingsModel.jumpAnnouncement(
            arrivingAt: partTwo, in: headings, isAudioBook: true, playsAfterJump: false
        ), "Heading: Part Two")
    }
}

/// `PhoneHeadingsVocabulary`: each word is the Mac's Headings sheet's, read
/// from its own source, so the two apps can't drift apart.
final class PhoneHeadingsVocabularyTests: XCTestCase {
    /// Every inline word is in `HeadingNavigatorView` as the phone has it.
    func testEveryWordIsTheMacsHeadingsSheets() throws {
        let macView = try String(
            contentsOf: AppSourceFile.folder.appendingPathComponent("Views/Reader/HeadingNavigatorView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(macView.contains("Text(\"\(PhoneHeadingsVocabulary.title)\")"))
        XCTAssertTrue(macView.contains("Button(\"\(PhoneHeadingsVocabulary.backToBook)\")"))
        XCTAssertTrue(macView.contains(".accessibilityHint(\"\(PhoneHeadingsVocabulary.backToBookHint)\")"))
        XCTAssertTrue(macView.contains("Picker(\"\(PhoneHeadingsVocabulary.displayTitle)\", selection: $displayMode)"))
        XCTAssertTrue(macView.contains(".accessibilityLabel(\"\(PhoneHeadingsVocabulary.displayLabel)\")"))
        XCTAssertTrue(macView.contains("Text(\"\(PhoneHeadingsVocabulary.empty)\")"))
        XCTAssertTrue(macView.contains("\"\(PhoneHeadingsVocabulary.rowHint)\""))
    }
}
