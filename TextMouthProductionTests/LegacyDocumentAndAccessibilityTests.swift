import XCTest
@testable import TextMouth

final class LegacyDocumentContentModelTests: XCTestCase {
    private func document(lengths: [Int]) -> DocumentContent {
        DocumentContent(
            title: "Test",
            author: "Author",
            chapters: lengths.enumerated().map { index, length in
                Chapter(title: "Chapter \(index + 1)", text: String(repeating: "a", count: length))
            }
        )
    }

    func testStableHeadingIDsAreDeterministicAndPositionSensitive() {
        let heading = Heading(level: 1, text: "Introduction", chapterIndex: 0, characterOffset: 0)
        XCTAssertEqual(
            heading.id,
            Heading(level: 1, text: "Introduction", chapterIndex: 0, characterOffset: 0).id
        )
        XCTAssertNotEqual(
            heading.id,
            Heading(level: 1, text: "Introduction", chapterIndex: 1, characterOffset: 0).id
        )
        XCTAssertNotEqual(
            heading.id,
            Heading(level: 1, text: "Introduction", chapterIndex: 0, characterOffset: 50).id
        )
    }

    func testAllHeadingsAssignsChapterIndicesAndStableIDs() {
        let content = DocumentContent(
            title: "Test",
            author: "Author",
            chapters: [
                Chapter(headings: [Heading(level: 1, text: "First")]),
                Chapter(headings: [Heading(level: 2, text: "Second")]),
            ]
        )
        let firstRead = content.allHeadings
        let secondRead = content.allHeadings
        XCTAssertEqual(firstRead.map(\.chapterIndex), [0, 1])
        XCTAssertTrue(firstRead[0].id.hasPrefix("0-"))
        XCTAssertTrue(firstRead[1].id.hasPrefix("1-"))
        XCTAssertEqual(firstRead.map(\.id), secondRead.map(\.id))
    }

    func testTotalWordCountUsesAllWhitespaceKinds() {
        let content = DocumentContent(
            title: "Test",
            author: "Author",
            chapters: [Chapter(text: "one\ttwo\nthree  four\n\nfive")]
        )
        XCTAssertEqual(content.totalWordCount, 5)
    }

    func testChapterStartOffsetClampsIndices() {
        let content = document(lengths: [100, 200, 150])
        XCTAssertEqual(content.chapterStartOffset(-1), 0)
        XCTAssertEqual(content.chapterStartOffset(0), 0)
        XCTAssertEqual(content.chapterStartOffset(1), 100)
        XCTAssertEqual(content.chapterStartOffset(2), 300)
        XCTAssertEqual(content.chapterStartOffset(99), 450)
    }

    func testChapterOffsetsUseUTF16Coordinates() {
        let content = DocumentContent(
            title: "Unicode",
            author: "Author",
            chapters: [Chapter(text: "🙂a"), Chapter(text: "next")]
        )
        XCTAssertEqual(content.chapterStartOffset(1), 3)
        XCTAssertEqual(content.globalOffset(chapterIndex: 1, localOffset: 2), 5)
    }

    func testGlobalOffsetCombinesChapterAndLocalOffsets() {
        let content = document(lengths: [100, 200])
        XCTAssertEqual(content.globalOffset(chapterIndex: 0, localOffset: 50), 50)
        XCTAssertEqual(content.globalOffset(chapterIndex: 1, localOffset: 50), 150)
    }

    func testEstimatedReadingTimeUsesWordCountAndHandlesZeroWPM() {
        let words = Array(repeating: "word", count: 100).joined(separator: " ")
        let content = DocumentContent(title: "Test", author: "Author", chapters: [Chapter(text: words)])
        XCTAssertEqual(content.estimatedReadingTime(wpm: 100), 60, accuracy: 0.001)
        XCTAssertEqual(content.estimatedReadingTime(wpm: 0), 0)
    }

    func testPercentCompleteUsesProductionCharacterCountAndCapsAtEnd() {
        let content = document(lengths: [400, 600])
        XCTAssertEqual(content.percentComplete(globalOffset: 0), 0)
        XCTAssertEqual(content.percentComplete(globalOffset: 500), 50)
        XCTAssertEqual(content.percentComplete(globalOffset: 1_000), 100)
        XCTAssertEqual(content.percentComplete(globalOffset: 2_000), 100)
    }

    func testTimeFormattingHandlesVisualDurations() {
        XCTAssertEqual(TimeFormatting.format(0), "0:00")
        XCTAssertEqual(TimeFormatting.format(59), "0:59")
        XCTAssertEqual(TimeFormatting.format(60), "1:00")
        XCTAssertEqual(TimeFormatting.format(3_600), "1:00:00")
        XCTAssertEqual(TimeFormatting.format(3_661), "1:01:01")
        XCTAssertEqual(TimeFormatting.format(-5), "0:00")
    }

    func testTimeFormattingProducesUsefulSpokenAccessibilityText() {
        XCTAssertEqual(TimeFormatting.spoken(0), "0 seconds")
        XCTAssertEqual(TimeFormatting.spoken(61), "1 minute, 1 second")
        XCTAssertEqual(TimeFormatting.spoken(3_661), "1 hour, 1 minute, 1 second")
    }

    func testSleepTimerDurationNamesAndPresetsComeFromProductionModel() {
        XCTAssertEqual(SleepTimerDuration.minutes(10).displayName, "10 minutes")
        XCTAssertEqual(SleepTimerDuration.endOfHeading.displayName, "End of heading")
        XCTAssertEqual(SleepTimerDuration.endOfBook.displayName, "End of book")
        // The sheet's minute presets, then its Stop At timers: End of heading,
        // the one place-based timer for any document, then End of book.
        XCTAssertEqual(SleepTimerDuration.presets.count, 7)
        XCTAssertEqual(Array(SleepTimerDuration.presets.suffix(2)), [.endOfHeading, .endOfBook])
    }

    func testGlobalLocationRoundTripsAcrossChapters() {
        let content = document(lengths: [100, 200, 150])
        for (chapter, local) in [
            (0, 0), (0, 99), (1, 0), (1, 199), (2, 0), (2, 149),
        ] {
            let global = content.globalOffset(chapterIndex: chapter, localOffset: local)
            let recovered = content.location(forGlobalOffset: global)
            XCTAssertEqual(recovered.chapterIndex, chapter)
            XCTAssertEqual(recovered.localOffset, local)
        }
    }

    func testGlobalLocationMapsBoundaryToNextChapter() {
        let result = document(lengths: [100, 200]).location(forGlobalOffset: 100)
        XCTAssertEqual(result.chapterIndex, 1)
        XCTAssertEqual(result.localOffset, 0)
    }

    func testGlobalLocationClampsNegativeAndOversizedOffsets() {
        let content = document(lengths: [100, 200])
        let negative = content.location(forGlobalOffset: -42)
        XCTAssertEqual(negative.chapterIndex, 0)
        XCTAssertEqual(negative.localOffset, 0)
        let oversized = content.location(forGlobalOffset: 999)
        XCTAssertEqual(oversized.chapterIndex, 1)
        XCTAssertEqual(oversized.localOffset, 199)
    }

    func testGlobalLocationHandlesEmptyDocument() {
        let result = DocumentContent(title: "Empty", author: "Author", chapters: [])
            .location(forGlobalOffset: 50)
        XCTAssertEqual(result.chapterIndex, 0)
        XCTAssertEqual(result.localOffset, 0)
    }

    func testGlobalLocationSkipsEmptyChapters() {
        let content = DocumentContent(
            title: "Test",
            author: "Author",
            chapters: [
                Chapter(text: String(repeating: "a", count: 50)),
                Chapter(text: ""),
                Chapter(text: String(repeating: "b", count: 100)),
            ]
        )
        let result = content.location(forGlobalOffset: 80)
        XCTAssertEqual(result.chapterIndex, 2)
        XCTAssertEqual(result.localOffset, 30)
    }

    func testPlainTextHeadingStylesDoNotCreateDuplicates() {
        let content = PlainTextParser.parse(
            text: "# CHAPTER ONE\n\nSome text.\n\nCHAPTER TWO\n\nMore text.",
            title: "Test"
        )
        XCTAssertEqual(content.allHeadings.filter { $0.text.contains("ONE") }.count, 1)
        XCTAssertEqual(content.allHeadings.filter { $0.text.contains("TWO") }.count, 1)
    }
}

/// Bookmark rows are SwiftUI views, so their labels are read on the main actor.
@MainActor
final class LegacyBookmarkAccessibilityTests: XCTestCase {
    // Each label ends with the day the bookmark was added, as its row shows
    // it (TODO A10).

    func testLabelIncludesBookmarkNumberAndContainingHeading() {
        let row = BookmarkRow(
            bookmark: Bookmark(number: 3, chapterIndex: 4, characterOffset: 0),
            headingText: "The Long Walk"
        )
        XCTAssertEqual(row.bookmarkAccessibilityLabel, "Bookmark 3, The Long Walk, added \(row.bookmark.dateText)")
    }

    func testLabelIncludesNoteWhenPresent() {
        let bookmark = Bookmark(
            number: 1,
            chapterIndex: 0,
            characterOffset: 0,
            label: "Important passage"
        )
        XCTAssertEqual(
            BookmarkRow(bookmark: bookmark, headingText: "Opening").bookmarkAccessibilityLabel,
            "Bookmark 1, Opening, Note: Important passage, added \(bookmark.dateText)"
        )
    }

    func testLabelOmitsNoteWhenEmpty() {
        let row = BookmarkRow(
            bookmark: Bookmark(number: 2, chapterIndex: 1, characterOffset: 0),
            headingText: "Second Part"
        )
        XCTAssertEqual(row.bookmarkAccessibilityLabel, "Bookmark 2, Second Part, added \(row.bookmark.dateText)")
    }

    func testLabelContainsBookmarkOnlyOnce() {
        let row = BookmarkRow(
            bookmark: Bookmark(number: 1, chapterIndex: 0, characterOffset: 0),
            headingText: "Opening"
        )
        XCTAssertEqual(row.bookmarkAccessibilityLabel.components(separatedBy: "ookmark").count - 1, 1)
    }

    /// A late content unit with no known heading still never exposes its
    /// internal unit number; the location is simply left out.
    func testUnknownLocationIsOmittedRatherThanNumbered() {
        let row = BookmarkRow(
            bookmark: Bookmark(number: 5, chapterIndex: 99, characterOffset: 0),
            headingText: nil
        )
        XCTAssertEqual(row.bookmarkAccessibilityLabel, "Bookmark 5, added \(row.bookmark.dateText)")
    }

    func testRowProvidesNavigationHint() {
        let row = BookmarkRow(
            bookmark: Bookmark(number: 1, chapterIndex: 0, characterOffset: 0),
            headingText: nil
        )
        // The result, never a gesture (TODO A10).
        XCTAssertEqual(row.accessibilityHintText, "Goes to this bookmark and closes the list.")
    }
}
