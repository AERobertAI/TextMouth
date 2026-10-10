import XCTest
@testable import TextMouth

/// The Headings sheet's times (P08): an audiobook's time into the book
/// counts its recording, the same at every speed, so each heading's time
/// typed into Go to Time lands on that heading; each heading's length is
/// heard at the book's speed; a text book's times count its words at its
/// speed, as before. Pure: the sheet's rows are made without a window, from
/// readers whose content each test assigns (`RecordingTimeFixtures`).
@MainActor
final class HeadingSheetRecordingTimeTests: XCTestCase {
    private typealias Fixtures = RecordingTimeFixtures

    /// For an audiobook of every layout, at 0.5x, 1x, and 2x, the time into
    /// the book each row shows is the heading's time in the recording, the
    /// same at every speed, and typed back into Go to Time it lands exactly
    /// on that heading.
    func testAnAudiobooksTimeInCountsTheRecordingAtEverySpeed() throws {
        for layout in Fixtures.Layout.allCases {
            let reader = Fixtures.makeReader(format: .audio)
            defer { reader.close() }
            let content = try Fixtures.audioContent(layout)
            reader.content = content
            let clock = PlaceClock.recording(of: content.contentIndex)
            let headings = content.allHeadings

            var shownAtNormalSpeed: [String]?
            for speed in [0.5, 1, 2] {
                reader.audioSpeed = speed
                let rows = rows(of: reader, mode: .timeIntoBook)
                XCTAssertEqual(rows.count, headings.count, "\(layout)")
                for row in rows {
                    let recordingTime = clock.time(chapterIndex: row.heading.chapterIndex, characterOffset: row.heading.characterOffset)
                    XCTAssertEqual(row.infoText, TimeFormatting.format(recordingTime), "\(layout) at \(speed)x")
                    XCTAssertEqual(row.accessibilitySuffix, "\(TimeFormatting.spoken(recordingTime)) in")
                    guard let typed = Fixtures.typedBack(row.infoText) else {
                        XCTFail("\(row.infoText) was not read")
                        continue
                    }
                    XCTAssertEqual(
                        clock.place(forTypedTime: typed, headings: headings),
                        PlaceClock.Place(chapterIndex: row.heading.chapterIndex, characterOffset: row.heading.characterOffset),
                        "\(layout) at \(speed)x: \(row.heading.text) at \(row.infoText)"
                    )
                }
                let shown = rows.map(\.infoText)
                if let shownAtNormalSpeed {
                    XCTAssertEqual(shown, shownAtNormalSpeed, "\(layout) at \(speed)x")
                } else {
                    shownAtNormalSpeed = shown
                }
            }
        }
    }

    /// A DAISY book's time into the book is its clips' measured time, not
    /// its placeholders' tenths, which by its last section have fallen
    /// more than two seconds behind.
    func testADAISYBooksTimeInIsItsClipsTime() throws {
        let reader = Fixtures.makeReader(format: .audio)
        defer { reader.close() }
        let content = try Fixtures.audioContent(.daisyClips)
        reader.content = content
        let segments = try Fixtures.daisySections().segments
        let measuredStart = segments.dropLast().reduce(0) { total, segment in
            total + segment.clips.reduce(0) { $0 + ($1.endTime - $1.startTime) }
        }

        let last = try XCTUnwrap(rows(of: reader, mode: .timeIntoBook).last)
        XCTAssertEqual(last.infoText, TimeFormatting.format(measuredStart))
        let placeholderStart = Double(content.globalOffset(chapterIndex: last.heading.chapterIndex, localOffset: 0))
            / ReaderViewModel.audioCharsPerSecond
        XCTAssertGreaterThan(measuredStart - placeholderStart, 2)
    }

    /// Each heading's length is heard at the book's speed: half its
    /// recorded length at 2x, twice it at 0.5x, and its recorded length at
    /// 1x, the last heading lasting to the end of the recording.
    func testAnAudiobooksLengthsAreHeardAtItsSpeed() throws {
        let reader = Fixtures.makeReader(format: .audio)
        defer { reader.close() }
        let content = try Fixtures.audioContent(.filePerChapter)
        reader.content = content
        let clock = PlaceClock.recording(of: content.contentIndex)

        for speed in [0.5, 1, 2] {
            reader.audioSpeed = speed
            let rows = rows(of: reader, mode: .timeEstimate)
            XCTAssertEqual(rows.count, clock.chapterDurations.count)
            for (chapterIndex, row) in rows.enumerated() {
                let recorded = recordedSpan(ofChapter: chapterIndex, in: content, on: clock)
                XCTAssertEqual(recorded, clock.chapterDurations[chapterIndex], accuracy: 1e-6)
                XCTAssertEqual(row.infoText, TimeFormatting.format(recorded / speed), "\(row.heading.text) at \(speed)x")
                XCTAssertEqual(row.accessibilitySuffix, TimeFormatting.spoken(recorded / speed))
            }
        }
    }

    /// A text book's times count its words at its speed, as they always
    /// have: at 200 and at 500 words a minute, each heading's time into the
    /// book is its share of the book's reading time, typed back it lands on
    /// the heading, and a heading shown alone under the level filter lasts
    /// to the next heading shown.
    func testATextBooksTimesAreItsWordsAtItsSpeed() throws {
        let reader = Fixtures.makeReader(format: .txt)
        defer { reader.close() }
        let content = Fixtures.textContent()
        reader.content = content
        let headings = content.allHeadings
        let total = Double(content.totalCharacterCount)

        for wordsPerMinute in [200.0, 500.0] {
            reader.speechService.wordsPerMinute = wordsPerMinute
            let readingTime = content.estimatedReadingTime(wpm: wordsPerMinute)
            let clock = try XCTUnwrap(reader.placeClock)
            for row in rows(of: reader, mode: .timeIntoBook) {
                let global = content.globalOffset(chapterIndex: row.heading.chapterIndex, localOffset: row.heading.characterOffset)
                let start = clock.time(chapterIndex: row.heading.chapterIndex, characterOffset: row.heading.characterOffset)
                XCTAssertEqual(start, readingTime * Double(global) / total, accuracy: 1e-6)
                XCTAssertEqual(row.infoText, TimeFormatting.format(start))
                guard let typed = Fixtures.typedBack(row.infoText) else {
                    XCTFail("\(row.infoText) was not read")
                    continue
                }
                XCTAssertEqual(
                    clock.place(forTypedTime: typed, headings: headings),
                    PlaceClock.Place(chapterIndex: row.heading.chapterIndex, characterOffset: row.heading.characterOffset),
                    "\(row.heading.text) at \(row.infoText), \(wordsPerMinute) words a minute"
                )
            }

            // Chapters alone: each lasts its whole chapter, its midway
            // heading hidden, and the last to the book's end.
            let chaptersOnly = HeadingNavigatorView.filteredHeadings(headings, maximumLevel: 1)
            let lengths = rows(of: reader, mode: .timeEstimate, displayed: chaptersOnly)
            XCTAssertEqual(lengths.count, content.chapters.count)
            for (chapterIndex, row) in lengths.enumerated() {
                let seconds = recordedSpan(ofChapter: chapterIndex, in: content, on: clock)
                XCTAssertEqual(seconds, readingTime * Double(content.chapters[chapterIndex].text.utf16Length) / total, accuracy: 1e-6)
                XCTAssertEqual(row.infoText, TimeFormatting.format(seconds), "\(row.heading.text)")
            }
        }
    }

    // MARK: - Helpers

    /// How long chapter `chapterIndex` lasts on `clock`, from its start to
    /// the next chapter's, or for the last chapter to its own end, measured
    /// as the sheet measures a heading that spans its whole chapter.
    private func recordedSpan(ofChapter chapterIndex: Int, in content: DocumentContent, on clock: PlaceClock) -> TimeInterval {
        let start = clock.time(chapterIndex: chapterIndex, characterOffset: 0)
        let end = chapterIndex + 1 < content.chapters.count
            ? clock.time(chapterIndex: chapterIndex + 1, characterOffset: 0)
            : clock.time(chapterIndex: chapterIndex, characterOffset: content.chapters[chapterIndex].text.utf16Length)
        return end - start
    }

    /// The rows the sheet shows for `reader`'s headings in `mode`, every
    /// heading displayed unless `displayed` says which.
    private func rows(
        of reader: ReaderViewModel,
        mode: HeadingNavigatorView.HeadingDisplayMode,
        displayed: [Heading]? = nil
    ) -> [HeadingNavigatorView.HeadingListItem] {
        let headings = reader.content?.allHeadings ?? []
        return HeadingNavigatorView.headingItems(
            for: reader,
            displayed: displayed ?? headings,
            allHeadings: headings,
            skippedIDs: [],
            mode: mode
        )
    }
}
