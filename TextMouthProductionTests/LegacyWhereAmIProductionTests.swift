import XCTest
@testable import TextMouth

final class LegacyWhereAmIProductionTests: XCTestCase {
    private func alice() throws -> DocumentContent {
        try EPUBParser.parse(url: requireFile("alice.epub"))
    }

    func testWhereAmIBuildsCorrectSummaryParts() throws {
        let content = try alice()
        let chapterIndex = min(2, content.chapters.count - 1)
        let localOffset = min(100, content.chapters[chapterIndex].text.utf16Length)
        let globalOffset = content.globalOffset(
            chapterIndex: chapterIndex,
            localOffset: localOffset
        )
        let percent = content.percentComplete(globalOffset: globalOffset)
        let remaining = content.estimatedTimeRemaining(fromGlobalOffset: globalOffset, wpm: 200)
        let heading = ReaderViewModel.currentHeading(
            in: content.allHeadings,
            chapterIndex: chapterIndex,
            characterOffset: localOffset
        )

        let summary = ReaderViewModel.briefWhereAmISummary(
            bookTitle: content.title,
            headingTitle: heading?.text,
            chapterTitle: content.chapters[chapterIndex].title,
            chapterIndex: chapterIndex,
            chapterCount: content.chapters.count,
            percentComplete: percent,
            timeRemaining: remaining
        )

        XCTAssertGreaterThanOrEqual(percent, 0)
        XCTAssertLessThanOrEqual(percent, 100)
        XCTAssertGreaterThanOrEqual(remaining, 0)
        XCTAssertTrue(summary.contains("Chapter \(chapterIndex + 1) of \(content.chapters.count)"))
        XCTAssertTrue(summary.contains("percent"))
        XCTAssertTrue(summary.contains("remaining"))
    }

    func testWhereAmIFindsCurrentHeadingAtPosition() throws {
        let content = try alice()
        let heading = try XCTUnwrap(content.allHeadings.first)
        let result = ReaderViewModel.currentHeading(
            in: content.allHeadings,
            chapterIndex: heading.chapterIndex,
            characterOffset: heading.characterOffset + 50
        )

        XCTAssertEqual(result?.id, heading.id)
        XCTAssertLessThanOrEqual(result?.characterOffset ?? .max, heading.characterOffset + 50)
    }

    func testWhereAmIHeadingTimeRemainingCalculation() throws {
        let content = try alice()
        let headings = content.allHeadings
        // Image-only cover chapters now have navigation entries too. Select
        // a heading with actual reading text for this positive-duration check.
        let starts = headings.map {
            content.globalOffset(chapterIndex: $0.chapterIndex, localOffset: $0.characterOffset)
        }
        let ends = Array(starts.dropFirst()) + [content.totalCharacterCount]
        let span = try XCTUnwrap(zip(starts, ends).first { $0 < $1 })
        let (start, end) = span

        let atStart = content.estimatedTimeRemaining(fromGlobalOffset: start, wpm: 200)
        let atEnd = content.estimatedTimeRemaining(fromGlobalOffset: end, wpm: 200)

        XCTAssertGreaterThan(end, start)
        XCTAssertGreaterThan(atStart, atEnd)
        XCTAssertGreaterThan(atStart - atEnd, 0)
    }

    func testWhereAmIAtStartOfBook() throws {
        let content = try alice()
        let total = content.estimatedReadingTime(wpm: 200)
        let remaining = content.estimatedTimeRemaining(fromGlobalOffset: 0, wpm: 200)

        XCTAssertEqual(content.percentComplete(globalOffset: 0), 0, accuracy: 0.001)
        XCTAssertEqual(remaining, total, accuracy: 0.001)
    }

    func testWhereAmIAtEndOfBook() throws {
        let content = try alice()
        let end = content.totalCharacterCount

        XCTAssertEqual(content.percentComplete(globalOffset: end), 100, accuracy: 0.001)
        XCTAssertEqual(
            content.estimatedTimeRemaining(fromGlobalOffset: end, wpm: 200),
            0,
            accuracy: 0.001
        )
    }

    func testWhereAmIHeadingAtStartMiddleAndEnd() throws {
        let content = try alice()
        let headings = content.allHeadings
        XCTAssertFalse(headings.isEmpty)

        let middleChapter = content.chapters.count / 2
        let middle = ReaderViewModel.currentHeading(
            in: headings,
            chapterIndex: middleChapter,
            characterOffset: content.chapters[middleChapter].text.utf16Length / 2
        )
        let lastChapter = content.chapters.count - 1
        let end = ReaderViewModel.currentHeading(
            in: headings,
            chapterIndex: lastChapter,
            characterOffset: content.chapters[lastChapter].text.utf16Length
        )

        XCTAssertNotNil(middle)
        XCTAssertNotNil(end)
        XCTAssertLessThanOrEqual(middle?.chapterIndex ?? .max, middleChapter)
        XCTAssertLessThanOrEqual(end?.chapterIndex ?? .max, lastChapter)
    }

    func testWhereAmIFindsClosestHeadingAtPosition() {
        let headings = [
            Heading(level: 1, text: "Chapter 1", chapterIndex: 0, characterOffset: 0),
            Heading(level: 2, text: "Section 1.1", chapterIndex: 0, characterOffset: 500),
            Heading(level: 2, text: "Section 1.2", chapterIndex: 0, characterOffset: 1_000),
            Heading(level: 1, text: "Chapter 2", chapterIndex: 1, characterOffset: 0),
        ]

        XCTAssertEqual(
            ReaderViewModel.currentHeading(
                in: headings,
                chapterIndex: 0,
                characterOffset: 750
            )?.text,
            "Section 1.1"
        )
        XCTAssertEqual(
            ReaderViewModel.currentHeading(
                in: headings,
                chapterIndex: 1,
                characterOffset: 100
            )?.text,
            "Chapter 2"
        )
    }

    func testWhereAmIWithNoHeadingsReturnsNil() {
        XCTAssertNil(
            ReaderViewModel.currentHeading(
                in: [],
                chapterIndex: 0,
                characterOffset: 500
            )
        )
    }
}
