import XCTest
@testable import TextMouth

/// Copy Reading Position adds the place's time on the book's clock (P08, the
/// user's answer 20): "at 2:13:05 of 9:41:07 in the recording" for an
/// audiobook, "at 2:10:24 of 4:20:49 at 500 words a minute" for a text
/// book, which typed back into Go to Time comes back within a second of the
/// place at every speed. A finished book's copied position still says only
/// "Finished" (P07). Pure: the summary's formatter, and readers from
/// `RecordingTimeFixtures` whose copied text is read without the pasteboard.
@MainActor
final class CopiedPlaceRecordingTimeTests: XCTestCase {
    private typealias Fixtures = RecordingTimeFixtures

    /// The place's words, for an audiobook and a text book.
    func testTheCopiedPlacesWordsAreFixed() {
        XCTAssertEqual(
            ReaderTimeWording.copiedPlace(7_985, of: 34_867.4, .recording),
            "at 2:13:05 of 9:41:07 in the recording"
        )
        XCTAssertEqual(
            ReaderTimeWording.copiedPlace(7_824, of: 15_649, .words(perMinute: 500)),
            "at 2:10:24 of 4:20:49 at 500 words a minute"
        )
    }

    /// Copy Reading Position puts the place between the percent and the time
    /// left. A finished book says only that it is finished: its place, the
    /// end, would repeat it.
    func testTheCopiedPositionCarriesThePlace() {
        let summary = ReaderViewModel.readingPositionSummary(
            bookTitle: "Dune",
            author: "Frank Herbert",
            locationTitle: "The Battle",
            headingPosition: Fixtures.headingPosition(number: 26, of: 412),
            percentComplete: 22.9,
            formattedTimeRemaining: "3:44:01",
            place: "at 2:13:05 of 9:41:07 in the recording"
        )
        XCTAssertEqual(
            summary,
            "Dune | by Frank Herbert | The Battle | Heading 26 of 412 | 22.9% through | "
                + "at 2:13:05 of 9:41:07 in the recording | 3:44:01 remaining"
        )
        let finished = ReaderViewModel.readingPositionSummary(
            bookTitle: "Dune",
            author: "Frank Herbert",
            locationTitle: "Appendix",
            headingPosition: Fixtures.headingPosition(number: 40, of: 40),
            percentComplete: 100,
            formattedTimeRemaining: "0:00",
            isFinished: true,
            place: "at 9:41:07 of 9:41:07 in the recording",
            speed: .audio(2)
        )
        XCTAssertEqual(finished, "Dune | by Frank Herbert | Appendix | Heading 40 of 40 | \(EndOfBookWording.finishedProgress)")
    }

    /// The design's book, one file of 9:41:07.4 read at 2:13:05: at 2x its
    /// copied position says "22.9% through | at 2:13:05 of 9:41:07 in the
    /// recording", the place's own time, not half of it.
    func testTheDesignsBookCopiesItsRecordingTime() throws {
        let reader = Fixtures.makeReader(format: .audio)
        defer { reader.close() }
        reader.content = try Fixtures.audioContent(.oneFile)
        reader.audioSpeed = 2
        reader.currentCharacterOffset = 79_850

        XCTAssertTrue(
            reader.readingPositionText.contains(" | 22.9% through | at 2:13:05 of 9:41:07 in the recording | "),
            reader.readingPositionText
        )
    }

    /// For an audiobook of every layout at 0.5x, 1x, and 2x, the place Copy
    /// Reading Position copies is its time in the recording, the same at
    /// every speed, and typed back into Go to Time it comes back within a
    /// second of the place, give or take the half tenth a place is rounded
    /// to.
    func testACopiedPlaceComesBackForEveryLayoutAndSpeed() throws {
        for layout in Fixtures.Layout.allCases {
            let reader = Fixtures.makeReader(format: .audio)
            defer { reader.close() }
            let content = try Fixtures.audioContent(layout)
            reader.content = content
            let clock = PlaceClock.recording(of: content.contentIndex)

            for place in Fixtures.samplePlaces(on: clock) {
                let placeTime = clock.time(of: place)
                for speed in [0.5, 1, 2] {
                    reader.audioSpeed = speed
                    reader.currentChapterIndex = place.chapterIndex
                    reader.currentCharacterOffset = place.characterOffset
                    let copied = reader.readingPositionText
                    let expected = ReaderTimeWording.copiedPlace(placeTime, of: clock.length, .recording)
                    XCTAssertTrue(copied.contains(" | \(expected) | "), "\(layout) at \(speed)x: \(copied)")

                    let time = try XCTUnwrap(copiedTime(in: copied), copied)
                    XCTAssertNil(reader.goToTime(typed: time), "\(layout) at \(speed)x: \(time)")
                    let landed = clock.time(chapterIndex: reader.currentChapterIndex, characterOffset: reader.currentCharacterOffset)
                    XCTAssertLessThan(abs(placeTime - landed), 1.05 + 1e-9, "\(layout) at \(speed)x: \(time)")
                }
            }
        }
    }

    /// A text book's copied place is its time at its speed, named, and
    /// comes back within a second of the place at 200 and 500 words a
    /// minute.
    func testATextBooksCopiedPlaceComesBackAtItsSpeed() throws {
        let reader = Fixtures.makeReader(format: .txt)
        defer { reader.close() }
        reader.content = Fixtures.textContent()

        for wordsPerMinute in [200.0, 500.0] {
            reader.speechService.wordsPerMinute = wordsPerMinute
            let clock = try XCTUnwrap(reader.placeClock)
            for place in Fixtures.samplePlaces(on: clock) {
                reader.currentChapterIndex = place.chapterIndex
                reader.currentCharacterOffset = place.characterOffset
                let placeTime = clock.time(of: place)
                let copied = reader.readingPositionText
                XCTAssertTrue(copied.contains(" at \(Int(wordsPerMinute)) words a minute | "), copied)

                let time = try XCTUnwrap(copiedTime(in: copied), copied)
                XCTAssertNil(reader.goToTime(typed: time))
                let landed = clock.time(chapterIndex: reader.currentChapterIndex, characterOffset: reader.currentCharacterOffset)
                XCTAssertLessThan(abs(placeTime - landed), 1 + 0.5 / clock.unitsPerSecond + 1e-9, "\(time) at \(wordsPerMinute)")
            }
        }
    }

    // MARK: - Helpers

    /// The time in the copied place ("at 2:13:05 of ..."), as it would be
    /// typed back; nil when the text holds none.
    private func copiedTime(in copied: String) -> String? {
        guard let at = copied.range(of: " | at "),
              let of = copied.range(of: " of ", range: at.upperBound..<copied.endIndex) else { return nil }
        return String(copied[at.upperBound..<of.lowerBound])
    }
}
