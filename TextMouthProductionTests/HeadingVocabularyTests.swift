import XCTest
@testable import TextMouth

/// Every user-facing location is described by headings — the list the
/// headings panel shows — and never by internal content units (EPUB spine
/// documents, audio files, whole text files). These tests pin the shared
/// position lookup and its wording so each surface speaks the same numbers.
final class HeadingPositionTests: XCTestCase {
    /// Two content units: the first holds three headings, the second one
    /// heading part-way in, and a third unit holds none. Positions can then
    /// precede, match, sit between, and cross unit boundaries.
    private let headings = [
        Heading(level: 1, text: "Part One", chapterIndex: 0, characterOffset: 10),
        Heading(level: 2, text: "Arrival", chapterIndex: 0, characterOffset: 200),
        Heading(level: 2, text: "Departure", chapterIndex: 0, characterOffset: 500),
        Heading(level: 1, text: "Part Two", chapterIndex: 1, characterOffset: 300),
    ]

    /// Shorthand for locating a position within the shared fixture.
    private func position(chapter: Int, offset: Int) -> HeadingPosition {
        HeadingPosition(in: headings, chapterIndex: chapter, characterOffset: offset)
    }

    func testPositionBeforeFirstHeadingHasNoContainingHeading() {
        let position = position(chapter: 0, offset: 9)

        XCTAssertNil(position.heading)
        XCTAssertNil(position.number)
        XCTAssertEqual(position.count, 4)
        XCTAssertEqual(position.label, "Before heading 1 of 4")
    }

    func testPositionExactlyAtHeadingBelongsToThatHeading() {
        let position = position(chapter: 0, offset: 200)

        XCTAssertEqual(position.heading?.text, "Arrival")
        XCTAssertEqual(position.number, 2)
        XCTAssertEqual(position.label, "Heading 2 of 4")
    }

    func testPositionBetweenHeadingsBelongsToTheEarlierHeading() {
        let position = position(chapter: 0, offset: 499)

        XCTAssertEqual(position.heading?.text, "Arrival")
        XCTAssertEqual(position.label, "Heading 2 of 4")
    }

    func testPositionAfterLastHeadingBelongsToTheLastHeading() {
        let position = position(chapter: 1, offset: 10_000)

        XCTAssertEqual(position.heading?.text, "Part Two")
        XCTAssertEqual(position.label, "Heading 4 of 4")
    }

    /// The start of a content unit whose first heading comes later is still
    /// inside the previous unit's last heading, exactly as the panel shows it.
    func testLaterContentUnitStartBelongsToThePreviousUnitsLastHeading() {
        let position = position(chapter: 1, offset: 0)

        XCTAssertEqual(position.heading?.text, "Departure")
        XCTAssertEqual(position.label, "Heading 3 of 4")
    }

    func testContentUnitWithoutHeadingsBelongsToTheLastEarlierHeading() {
        let position = position(chapter: 2, offset: 50)

        XCTAssertEqual(position.heading?.text, "Part Two")
        XCTAssertEqual(position.label, "Heading 4 of 4")
    }

    /// Heading numbers count headings, so a book with many headings in few
    /// content units reports the heading total rather than the unit total.
    func testCountReflectsHeadingsNotContentUnits() {
        let manyHeadings = (0..<400).map {
            Heading(level: 2, text: "Section \($0 + 1)", chapterIndex: $0 / 5, characterOffset: ($0 % 5) * 100)
        }

        let position = HeadingPosition(in: manyHeadings, chapterIndex: 25, characterOffset: 250)

        XCTAssertEqual(position.heading?.text, "Section 128")
        XCTAssertEqual(position.label, "Heading 128 of 400")
    }

    func testBookWithoutHeadingsHasAnEmptyLabel() {
        let position = HeadingPosition(in: [], chapterIndex: 0, characterOffset: 500)

        XCTAssertNil(position.heading)
        XCTAssertNil(position.number)
        XCTAssertEqual(position.count, 0)
        XCTAssertEqual(position.label, "")
    }

    /// A part heading and its first chapter heading often share an offset;
    /// the later, more specific heading wins, matching the panel.
    func testHeadingsSharingAPositionResolveToTheLastListed() {
        let shared = [
            Heading(level: 1, text: "Book One", chapterIndex: 0, characterOffset: 0),
            Heading(level: 2, text: "Opening", chapterIndex: 0, characterOffset: 0),
        ]

        let position = HeadingPosition(in: shared, chapterIndex: 0, characterOffset: 0)

        XCTAssertEqual(position.heading?.text, "Opening")
        XCTAssertEqual(position.label, "Heading 2 of 2")
    }

    /// The navigation helper and the numbered position share one lookup.
    func testCurrentHeadingMatchesHeadingPositionEverywhere() {
        let probes = [(0, 0), (0, 10), (0, 350), (0, 500), (1, 0), (1, 299), (1, 300), (2, 0)]
        for (chapter, offset) in probes {
            XCTAssertEqual(
                ReaderViewModel.currentHeading(in: headings, chapterIndex: chapter, characterOffset: offset),
                position(chapter: chapter, offset: offset).heading,
                "Mismatch at chapter \(chapter), offset \(offset)"
            )
        }
    }

    func testHeadingTextIsPresentOnlyInsideAHeading() {
        XCTAssertEqual(position(chapter: 0, offset: 600).headingText, "Departure")
        XCTAssertNil(position(chapter: 0, offset: 0).headingText)
        XCTAssertNil(HeadingPosition(in: [], chapterIndex: 0, characterOffset: 0).headingText)
    }

    func testTitleIsTheContainingHeadingText() {
        XCTAssertEqual(
            position(chapter: 0, offset: 250).title(contentTitle: "Chapter 1", bookTitle: "Travels"),
            "Arrival"
        )
    }

    /// When headings exist, the content unit's title is never substituted,
    /// even before the first heading; the label already says where we are.
    func testTitleIsOmittedBeforeTheFirstHeading() {
        XCTAssertNil(position(chapter: 0, offset: 0).title(contentTitle: "Cover", bookTitle: "Travels"))
    }

    func testTitleFallsBackToTheContentTitleOnlyWithoutHeadings() {
        let position = HeadingPosition(in: [], chapterIndex: 0, characterOffset: 0)

        XCTAssertEqual(position.title(contentTitle: "Field Notes", bookTitle: "Travels"), "Field Notes")
    }

    func testFallbackTitleThatRepeatsTheBookTitleIsOmitted() {
        let position = HeadingPosition(in: [], chapterIndex: 0, characterOffset: 0)

        XCTAssertNil(position.title(contentTitle: " travels ", bookTitle: "Travels"))
        XCTAssertNil(position.title(contentTitle: nil, bookTitle: "Travels"))
    }

    func testBlankTitlesAreOmitted() {
        let blank = [Heading(level: 1, text: "  ", chapterIndex: 0, characterOffset: 0)]

        let position = HeadingPosition(in: blank, chapterIndex: 0, characterOffset: 5)

        XCTAssertNil(position.headingText)
        XCTAssertNil(position.title(contentTitle: "Unit", bookTitle: "Travels"))
        XCTAssertEqual(position.label, "Heading 1 of 1")
        XCTAssertNil(HeadingPosition(in: [], chapterIndex: 0, characterOffset: 0)
            .title(contentTitle: "\n", bookTitle: "Travels"))
    }
}
