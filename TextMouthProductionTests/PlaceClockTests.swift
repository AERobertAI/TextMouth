import XCTest
@testable import TextMouth

/// The clock a book's places are named by (P08, `PlaceClock`): an
/// audiobook's recording, from its content index's measured chapters, and
/// a text book's words at its speed. Pure: every index is built the way the
/// app builds it (`RecordingTimeFixtures`), with no audio file, window, or
/// sound.
@MainActor
final class PlaceClockTests: XCTestCase {
    private typealias Fixtures = RecordingTimeFixtures

    // MARK: - One File

    /// One file of 9:41:07.4: a place's time is its offset's seconds, and
    /// every place found from its own time is the place again.
    func testOneFileCountsItsOwnTime() throws {
        let index = try Fixtures.audioContent(.oneFile).contentIndex
        let clock = PlaceClock.recording(of: index)

        XCTAssertEqual(index.audioLayout, .singleFile)
        XCTAssertEqual(clock.length, index.totalAudioDuration ?? -1, accuracy: 1e-9)
        XCTAssertEqual(clock.time(chapterIndex: 0, characterOffset: 79_850), 7_985, accuracy: 1e-9)
        XCTAssertEqual(clock.place(atTime: 7_985), PlaceClock.Place(chapterIndex: 0, characterOffset: 79_850))
        assertEveryPlaceComesBack(on: clock)
    }

    // MARK: - Chapter Marks

    /// One file with chapter marks: the clock is the file's own time line,
    /// on which the reader plays each chapter (from its placeholders' sum,
    /// `AudioLayout.chapterStartTime`) and the cursor ticks, so a time on
    /// the clock is the player's own time for that place.
    func testChapterMarksCountTheFilesOwnTimeLine() throws {
        let content = try Fixtures.audioContent(.chapterMarks)
        let clock = PlaceClock.recording(of: content.contentIndex)
        let lengths = content.chapters.map(\.text.utf16Length)
        let layout = ReaderViewModel.AudioLayout.chaptersInOneFile

        XCTAssertEqual(content.contentIndex.audioLayout, .singleFile)
        for chapterIndex in lengths.indices {
            let start = layout.chapterStartTime(chapterIndex: chapterIndex, chapterUTF16Lengths: lengths)
            for offset in [0, 1, lengths[chapterIndex] / 2, lengths[chapterIndex] - 1] {
                let playerTime = layout.absoluteSeekTime(characterOffset: offset, chapterStartTime: start)
                XCTAssertEqual(clock.time(chapterIndex: chapterIndex, characterOffset: offset), playerTime, accuracy: 1e-6)
            }
        }
        // A tick of the player at a file time lands where the clock says
        // that time is, to the unit the tick truncates to.
        for fileTime in stride(from: 0.0, to: clock.length, by: 997.3) {
            let ticked = content.location(forGlobalOffset: AudioBookParser.characterOffset(forTime: fileTime))
            let found = clock.place(atTime: fileTime)
            XCTAssertEqual(
                clock.time(chapterIndex: ticked.chapterIndex, characterOffset: ticked.localOffset),
                clock.time(of: found),
                accuracy: 0.1 + 1e-6,
                "at \(fileTime)"
            )
        }
        assertEveryPlaceComesBack(on: clock)
        assertEveryHeadingsTimeLandsOnIt(on: clock, headings: content.allHeadings)
    }

    // MARK: - A File per Chapter

    /// A file per chapter: the files one after another, each as long as the
    /// index records it, so a place's time is the same units over ten that
    /// Go to Time has always jumped to, and every heading's whole-second
    /// time typed back lands on it.
    func testFilePerChapterCountsTheFilesOneAfterAnother() throws {
        let content = try Fixtures.audioContent(.filePerChapter)
        let clock = PlaceClock.recording(of: content.contentIndex)

        XCTAssertEqual(content.contentIndex.audioLayout, .multiFile)
        for chapterIndex in content.chapters.indices {
            let offset = content.chapters[chapterIndex].text.utf16Length / 3
            let global = content.globalOffset(chapterIndex: chapterIndex, localOffset: offset)
            XCTAssertEqual(
                clock.time(chapterIndex: chapterIndex, characterOffset: offset),
                Double(global) / ReaderViewModel.audioCharsPerSecond,
                accuracy: 1e-6
            )
        }
        assertEveryPlaceComesBack(on: clock)
        assertEveryHeadingsTimeLandsOnIt(on: clock, headings: content.allHeadings)
    }

    // MARK: - DAISY Clips

    /// DAISY sections, one of three clips in three files and one shorter
    /// than a second: each lasts as long as its clips together, as the index
    /// measured them, not its placeholder's tenths, so the clock's length is
    /// the recording's and a section's start is its clips' sum before it.
    func testDAISYSectionsCountTheirClips() throws {
        let segments = try Fixtures.daisySections().segments
        let content = try Fixtures.audioContent(.daisyClips)
        let index = content.contentIndex
        let clock = PlaceClock.recording(of: index)
        let measured = segments.map { $0.clips.reduce(0) { $0 + ($1.endTime - $1.startTime) } }

        XCTAssertEqual(index.audioLayout, .segmented)
        XCTAssertEqual(clock.length, index.totalAudioDuration ?? -1, accuracy: 1e-9)
        XCTAssertEqual(clock.length, measured.reduce(0, +), accuracy: 1e-9)
        var start: TimeInterval = 0
        for (chapterIndex, duration) in measured.enumerated() {
            XCTAssertEqual(clock.time(chapterIndex: chapterIndex, characterOffset: 0), start, accuracy: 1e-9)
            start += duration
        }
        // The placeholders' tenths fall behind the clips: by the last
        // section, units over ten no longer name the recording's time.
        let placeholderSeconds = Double(index.totalCharacterCount) / ReaderViewModel.audioCharsPerSecond
        XCTAssertGreaterThan(clock.length - placeholderSeconds, 2)

        // The short section's placeholder holds a whole second; the clock
        // ends it with its clip, where the next section starts.
        let short = Fixtures.shortSectionIndex
        XCTAssertEqual(content.chapters[short].text.utf16Length, 10)
        XCTAssertEqual(
            clock.time(chapterIndex: short, characterOffset: 9),
            clock.time(chapterIndex: short + 1, characterOffset: 0),
            accuracy: 1e-9
        )
        assertEveryPlaceComesBack(on: clock, skippingOffsetsPastTheClips: true)
        assertEveryHeadingsTimeLandsOnIt(on: clock, headings: content.allHeadings)
    }

    // MARK: - Text Books

    /// A text book's places count its words at its speed, exactly as the
    /// reader's times always have: a place's time is its share of the
    /// book's reading time, and a time's place the unit nearest that share,
    /// at 200 and at 500 words a minute.
    func testATextBookCountsItsWordsAtItsSpeed() {
        let content = Fixtures.textContent()
        for wordsPerMinute in [200.0, 500.0] {
            let readingTime = content.estimatedReadingTime(wpm: wordsPerMinute)
            let clock = PlaceClock.reading(of: content.contentIndex, readingTime: readingTime)
            let total = Double(content.totalCharacterCount)

            XCTAssertEqual(clock.length, readingTime, accuracy: 1e-6)
            for chapterIndex in content.chapters.indices {
                let length = content.chapters[chapterIndex].text.utf16Length
                for offset in [0, length / 2, length] {
                    let global = content.globalOffset(chapterIndex: chapterIndex, localOffset: offset)
                    XCTAssertEqual(
                        clock.time(chapterIndex: chapterIndex, characterOffset: offset),
                        readingTime * Double(global) / total,
                        accuracy: 1e-6
                    )
                }
            }
            // The place of a time is where Go to Time's text jump has always
            // gone: the share of the book's units, rounded.
            for time in stride(from: 0.0, to: readingTime, by: readingTime / 37) {
                let jumped = content.location(forGlobalOffset: Int((time / readingTime * total).rounded()))
                let found = clock.place(atTime: time)
                let jumpedGlobal = content.globalOffset(chapterIndex: jumped.chapterIndex, localOffset: jumped.localOffset)
                let foundGlobal = content.globalOffset(chapterIndex: found.chapterIndex, localOffset: found.characterOffset)
                XCTAssertLessThanOrEqual(abs(jumpedGlobal - foundGlobal), 1, "at \(time), \(wordsPerMinute) words a minute")
            }
            assertEveryPlaceComesBack(on: clock, step: 97)
            assertEveryHeadingsTimeLandsOnIt(on: clock, headings: content.allHeadings)
        }
    }

    /// A text book without words has no reading time: every place is at 0,
    /// and every time past 0 is the book's end, without trapping.
    func testATextBookWithoutWordsHasNoTime() {
        let content = DocumentContent(title: "Blank", author: "", chapters: [Chapter(title: "", text: "   ")])
        let clock = PlaceClock.reading(of: content.contentIndex, readingTime: content.estimatedReadingTime(wpm: 300))

        XCTAssertEqual(clock.length, 0)
        XCTAssertEqual(clock.time(chapterIndex: 0, characterOffset: 2), 0)
        XCTAssertEqual(clock.place(atTime: 0), PlaceClock.Place(chapterIndex: 0, characterOffset: 0))
        XCTAssertEqual(clock.place(atTime: 5), PlaceClock.Place(chapterIndex: 0, characterOffset: 3))
    }

    // MARK: - Edges

    /// Times and places outside the book are kept inside it, and nothing
    /// damaged traps: no chapters, a time that is no number, a negative or
    /// infinite time, a chapter or offset past the end, and a chapter
    /// lasting no time, whose start belongs to the chapter after it.
    func testEdgesStayInsideTheBook() {
        let empty = PlaceClock(chapterDurations: [], chapterLengths: [], unitsPerSecond: 10)
        XCTAssertEqual(empty.length, 0)
        XCTAssertEqual(empty.time(chapterIndex: 3, characterOffset: 7), 0)
        XCTAssertEqual(empty.place(atTime: 12), PlaceClock.Place(chapterIndex: 0, characterOffset: 0))

        // 2 s, then a chapter of no time, then 3 s; a damaged duration
        // counts as none.
        let clock = PlaceClock(chapterDurations: [2, 0, 3, .nan], chapterLengths: [20, 1, 30, 4], unitsPerSecond: 10)
        XCTAssertEqual(clock.length, 5)
        XCTAssertEqual(clock.chapterStarts, [0, 2, 2, 5])
        XCTAssertEqual(clock.place(atTime: .nan), PlaceClock.Place(chapterIndex: 0, characterOffset: 0))
        XCTAssertEqual(clock.place(atTime: -4), PlaceClock.Place(chapterIndex: 0, characterOffset: 0))
        XCTAssertEqual(clock.place(atTime: .infinity), PlaceClock.Place(chapterIndex: 3, characterOffset: 4))
        XCTAssertEqual(clock.place(atTime: 99), PlaceClock.Place(chapterIndex: 3, characterOffset: 4))
        XCTAssertEqual(clock.place(atTime: 2), PlaceClock.Place(chapterIndex: 2, characterOffset: 0))
        XCTAssertEqual(clock.place(atTime: 1.96), PlaceClock.Place(chapterIndex: 0, characterOffset: 20))
        XCTAssertEqual(clock.place(atTime: 3.04), PlaceClock.Place(chapterIndex: 2, characterOffset: 10))
        XCTAssertEqual(clock.time(chapterIndex: -1, characterOffset: 5), 0)
        XCTAssertEqual(clock.time(chapterIndex: 9, characterOffset: 0), 5)
        XCTAssertEqual(clock.time(chapterIndex: 0, characterOffset: 500), 2)
        XCTAssertEqual(clock.time(chapterIndex: 0, characterOffset: -3), 0)
        XCTAssertEqual(clock.time(chapterIndex: 1, characterOffset: 0), 2)
    }

    /// A typed time less than a second before a heading lands on the
    /// heading; one a second or more before it, or after it, lands on the
    /// time itself; and of two headings within the second after the time,
    /// the earlier is taken, whatever order the headings come in.
    func testATypedTimeJustBeforeAHeadingLandsOnIt() {
        let clock = PlaceClock(chapterDurations: [10, 10], chapterLengths: [100, 100], unitsPerSecond: 10)
        let early = Heading(level: 2, text: "Early", chapterIndex: 0, characterOffset: 43)
        let late = Heading(level: 2, text: "Late", chapterIndex: 0, characterOffset: 48)
        let second = Heading(level: 1, text: "Second", chapterIndex: 1, characterOffset: 0)
        let headings = [second, late, early]

        XCTAssertEqual(clock.place(forTypedTime: 9.2, headings: headings), PlaceClock.Place(chapterIndex: 1, characterOffset: 0))
        XCTAssertEqual(clock.place(forTypedTime: 9, headings: headings), PlaceClock.Place(chapterIndex: 0, characterOffset: 90))
        XCTAssertEqual(clock.place(forTypedTime: 4, headings: headings), PlaceClock.Place(chapterIndex: 0, characterOffset: 43))
        XCTAssertEqual(clock.place(forTypedTime: 4.5, headings: headings), PlaceClock.Place(chapterIndex: 0, characterOffset: 48))
        XCTAssertEqual(clock.place(forTypedTime: 4.9, headings: headings), PlaceClock.Place(chapterIndex: 0, characterOffset: 49))
        XCTAssertEqual(clock.place(forTypedTime: 12, headings: headings), PlaceClock.Place(chapterIndex: 1, characterOffset: 20))
        XCTAssertEqual(clock.place(forTypedTime: 12, headings: []), PlaceClock.Place(chapterIndex: 1, characterOffset: 20))
    }

    // MARK: - The Reader's Clock

    /// An audiobook's places keep their times at every speed: the reader's
    /// clock is its recording's at 0.5x, 1x, and 2x alike. A text book's
    /// clock follows its words per minute.
    func testTheReadersClockIsTheRecordingsAtEverySpeed() throws {
        let audioReader = Fixtures.makeReader(format: .audio)
        defer { audioReader.close() }
        audioReader.content = try Fixtures.audioContent(.chapterMarks)
        let atNormalSpeed = try XCTUnwrap(audioReader.placeClock)
        for speed in [0.5, 1, 2] {
            audioReader.audioSpeed = speed
            XCTAssertEqual(audioReader.placeClock, atNormalSpeed, "at \(speed)x")
        }
        XCTAssertEqual(atNormalSpeed.length, audioReader.content?.contentIndex.totalAudioDuration ?? -1, accuracy: 1e-9)

        let textReader = Fixtures.makeReader(format: .txt)
        defer { textReader.close() }
        let text = Fixtures.textContent()
        textReader.content = text
        for wordsPerMinute in [200.0, 500.0] {
            textReader.speechService.wordsPerMinute = wordsPerMinute
            XCTAssertEqual(try XCTUnwrap(textReader.placeClock).length, text.estimatedReadingTime(wpm: wordsPerMinute), accuracy: 1e-6)
        }
    }

    // MARK: - Assertions

    /// Every place, sampled through each chapter, is found again from its
    /// own time, and a time shown in whole seconds, as every surface shows
    /// one, comes back within a second of its place, give or take the half
    /// unit a place is rounded to. A chapter's end is the next chapter's
    /// start, so offsets stop short of it; with
    /// `skippingOffsetsPastTheClips`, so do a DAISY section's offsets past
    /// its clips, which all name the section's end.
    private func assertEveryPlaceComesBack(
        on clock: PlaceClock,
        step: Int = 7,
        skippingOffsetsPastTheClips: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let halfUnit = 0.5 / clock.unitsPerSecond
        for chapterIndex in clock.chapterLengths.indices {
            var lastOffset = clock.chapterLengths[chapterIndex] - 1
            if skippingOffsetsPastTheClips {
                let clipUnits = Int(clock.chapterDurations[chapterIndex] * clock.unitsPerSecond) - 1
                lastOffset = min(lastOffset, clipUnits)
            }
            guard lastOffset >= 0 else { continue }
            let stride = max(1, lastOffset / step)
            for offset in Swift.stride(from: 0, through: lastOffset, by: stride) {
                let place = PlaceClock.Place(chapterIndex: chapterIndex, characterOffset: offset)
                let time = clock.time(of: place)
                XCTAssertEqual(clock.place(atTime: time), place, "at \(time)", file: file, line: line)
                // As the time is shown, read back as Go to Time reads it.
                guard let typed = Fixtures.typedBack(TimeFormatting.format(time)) else {
                    XCTFail("\(TimeFormatting.format(time)) was not read", file: file, line: line)
                    continue
                }
                let landed = clock.time(of: clock.place(atTime: typed))
                XCTAssertLessThan(time - landed, 1 + halfUnit + 1e-9, "\(TimeFormatting.format(time))", file: file, line: line)
                XCTAssertGreaterThan(time - landed, -halfUnit - 1e-9, "\(TimeFormatting.format(time))", file: file, line: line)
            }
        }
    }

    /// Each heading's time, shown in whole seconds and typed back into Go
    /// to Time, lands exactly on the heading.
    private func assertEveryHeadingsTimeLandsOnIt(
        on clock: PlaceClock,
        headings: [Heading],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(headings.isEmpty, file: file, line: line)
        for heading in headings {
            let shown = TimeFormatting.format(clock.time(chapterIndex: heading.chapterIndex, characterOffset: heading.characterOffset))
            guard let typed = Fixtures.typedBack(shown) else {
                XCTFail("\(shown) was not read", file: file, line: line)
                continue
            }
            XCTAssertEqual(
                clock.place(forTypedTime: typed, headings: headings),
                PlaceClock.Place(chapterIndex: heading.chapterIndex, characterOffset: heading.characterOffset),
                "\(heading.text) at \(shown)",
                file: file,
                line: line
            )
        }
    }
}
