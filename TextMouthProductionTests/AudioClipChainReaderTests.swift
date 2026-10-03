import XCTest
@testable import TextMouth

/// A reader playing a segmented audiobook whose second heading's
/// narration spans three audio files (TODO I03). The heading lasts as long
/// as its clips together; navigating to it starts at its first clip;
/// seeking within it loads the file that holds the time; its position runs
/// on unbroken across files; it moves on to the next heading once, after
/// its last clip; and a clip whose file is missing stops the reader there,
/// naming the file.
///
/// Each book is a package of silent tracks written for the test, with a
/// manifest of its sections, indexed and saved as an import leaves it, so
/// the reader opens it from its saved index.
@MainActor
final class AudioClipChainReaderTests: XCTestCase {

    // MARK: - Length

    /// The heading spanning three files lasts as long as its three clips
    /// together, in its text, its index, and the book's total, and the
    /// reader plays it from all three files.
    func testHeadingSpanningThreeFilesLastsAsLongAsItsClipsTogether() throws {
        try withSegmentedBook { reader, _ in
            XCTAssertEqual(
                reader.audioSegments.map { $0.clips.map(\.file) },
                [["intro.wav"], ["a.wav", "b.wav", "c.wav"], ["d.wav"]]
            )
            // Ten placeholder characters stand for each second.
            XCTAssertEqual(reader.content?.chapters.map(\.text.utf16Length), [10, 20, 10])
            let index = try XCTUnwrap(reader.content?.contentIndex)
            XCTAssertEqual(index.chapters.map { $0.audio?.duration }, [1, 2, 1])
            XCTAssertEqual(index.totalAudioDuration, 4)
            XCTAssertEqual(reader.totalEstimatedTime, 4)
            XCTAssertEqual(reader.timeEstimateForHeading(try XCTUnwrap(reader.content?.allHeadings[1])), 2)
        }
    }

    // MARK: - Navigating

    /// Navigating to the heading while playing starts it at its first clip:
    /// the first file, at the clip's start, at the heading's start.
    func testNavigatingToTheHeadingStartsAtItsFirstClip() throws {
        try withSegmentedBook(at: ReadingPosition(chapterIndex: 0, characterOffset: 0)) { reader, _ in
            reader.play()
            XCTAssertEqual(reader.audioPlaybackService.loadedURL?.lastPathComponent, "intro.wav")

            reader.navigateToHeading(try XCTUnwrap(reader.content?.allHeadings[1]))

            XCTAssertEqual(reader.currentChapterIndex, 1)
            XCTAssertEqual(reader.currentCharacterOffset, 0)
            XCTAssertEqual(reader.audioPlaybackService.loadedURL?.lastPathComponent, "a.wav")
            XCTAssertEqual(reader.audioPlaybackService.currentTime, 0)
            XCTAssertTrue(reader.isCurrentlyPlaying)
            reader.stop()
        }
    }

    /// Seeking within the heading, as skipping and navigating do, loads the
    /// file holding that time: 0.8 seconds in lies in the second clip, 1.8
    /// seconds in the third.
    func testSeekingWithinTheHeadingLoadsTheFileHoldingTheTime() throws {
        try withSegmentedBook { reader, _ in
            reader.play()
            XCTAssertEqual(reader.audioPlaybackService.loadedURL?.lastPathComponent, "a.wav")

            reader.navigateTo(chapterIndex: 1, characterOffset: 8)

            XCTAssertEqual(reader.audioPlaybackService.loadedURL?.lastPathComponent, "b.wav")
            XCTAssertEqual(reader.audioPlaybackService.currentTime, 0.8, accuracy: 0.001)
            XCTAssertEqual(reader.currentCharacterOffset, 8)

            reader.skipCharacters(count: 10)

            XCTAssertEqual(reader.currentChapterIndex, 1)
            XCTAssertEqual(reader.currentCharacterOffset, 18)
            XCTAssertEqual(reader.audioPlaybackService.loadedURL?.lastPathComponent, "c.wav")
            XCTAssertEqual(reader.audioPlaybackService.currentTime, 1.8, accuracy: 0.001)
            XCTAssertTrue(reader.audioPlaybackService.isPlaying)
            reader.stop()
        }
    }

    // MARK: - Playing Through

    /// Played through, the heading plays its three files in turn while its
    /// position only moves forward, from its start to near its end, then
    /// moves on to the next heading once, after its last clip.
    func testPlayingThroughTheHeadingRunsOnAcrossFilesAndMovesOnOnce() throws {
        try withSegmentedBook { reader, _ in
            reader.play()

            let samples = trackPlayback(of: reader, within: 15) { reader.currentChapterIndex == 2 }
            XCTAssertEqual(reader.currentChapterIndex, 2, "The heading never moved on")
            spinMainRunLoop(for: 0.3)
            // One move on: still the closing heading, playing its own file.
            XCTAssertEqual(reader.currentChapterIndex, 2)
            XCTAssertEqual(reader.audioPlaybackService.loadedURL?.lastPathComponent, "d.wav")
            reader.stop()

            let heading = samples.filter { $0.chapter == 1 }
            XCTAssertEqual(heading.compactMap(\.file).runs, ["a.wav", "b.wav", "c.wav"])
            let offsets = heading.map(\.offset)
            XCTAssertEqual(offsets, offsets.sorted(), "The heading's position went back: \(offsets)")
            XCTAssertGreaterThanOrEqual(offsets.max() ?? 0, 15, "\(offsets)")
            XCTAssertLessThanOrEqual(offsets.max() ?? 0, 20, "\(offsets)")
        }
    }

    // MARK: - A Missing File

    /// A clip whose file is missing stops the reader when playback reaches
    /// it, naming that file, with the cursor where the clip begins; once the
    /// file is back, Retry plays on from there.
    func testMissingFileOfALaterClipStopsTheReaderThere() throws {
        let deleteSecondFile: (URL) throws -> Void = { folder in
            try FileManager.default.removeItem(at: folder.appendingPathComponent("b.wav"))
        }
        try withSegmentedBook(damage: deleteSecondFile) { reader, folder in
            let message = "Chapter 2 could not be played: the file b.wav is missing from the book's "
                + "package. Re-import the book to restore it."

            reader.play()
            XCTAssertTrue(eventually(within: 15) { reader.errorMessage != nil }, "The missing file was never reported")

            XCTAssertEqual(reader.errorMessage, message)
            XCTAssertEqual(reader.audioPlaybackFailure?.reason, .fileMissing)
            XCTAssertFalse(reader.isCurrentlyPlaying)
            XCTAssertEqual(reader.currentChapterIndex, 1)
            XCTAssertEqual(reader.currentCharacterOffset, 5)

            try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("b.wav"), duration: 0.75)
            reader.retryAudioPlayback()

            XCTAssertTrue(reader.isCurrentlyPlaying)
            XCTAssertNil(reader.errorMessage)
            XCTAssertEqual(reader.audioPlaybackService.loadedURL?.lastPathComponent, "b.wav")
            XCTAssertEqual(reader.audioPlaybackService.currentTime, 0.5, accuracy: 0.001)
            reader.stop()
        }
    }

    // MARK: - Fixture

    /// The book's audio files and how long each plays, in seconds.
    private static let files: [String: TimeInterval] = [
        "intro.wav": 1, "a.wav": 1, "b.wav": 0.75, "c.wav": 1, "d.wav": 1
    ]

    /// The book's headings: an opening of one second; a heading playing
    /// the second half of a.wav, all of b.wav, and c.wav from a quarter
    /// second in, two seconds in all, its clips starting 0, 0.5, and 1.25
    /// seconds into it; and a closing second. Every time is exact in binary,
    /// so lengths add up exactly.
    private static func sections() throws -> [AudioSegment] {
        [
            AudioSegment(title: "Opening", file: "intro.wav", startTime: 0, endTime: 1),
            try XCTUnwrap(AudioSegment(title: "Harbor Survey", clips: [
                AudioClip(file: "a.wav", startTime: 0.5, endTime: 1),
                AudioClip(file: "b.wav", startTime: 0, endTime: 0.75),
                AudioClip(file: "c.wav", startTime: 0.25, endTime: 1)
            ])),
            AudioSegment(title: "Closing", file: "d.wav", startTime: 0, endTime: 1)
        ]
    }

    /// Run `body` with a reader opened at `position` on the book of
    /// `sections()`, whose audio folder is passed along. Its end-of-book
    /// behavior is Stop; `damage` changes its files after it was indexed
    /// (see `withSegmentedAudioBook`).
    private func withSegmentedBook(
        at position: ReadingPosition = ReadingPosition(chapterIndex: 1, characterOffset: 0),
        damage: (URL) throws -> Void = { _ in },
        _ body: (ReaderViewModel, URL) throws -> Void
    ) throws {
        try withSegmentedAudioBook(
            title: "Harbor Soundings",
            files: Self.files,
            sections: try Self.sections(),
            at: position,
            damage: damage
        ) { audiobook in
            try body(audiobook.openReader(), audiobook.folder)
        }
    }
}
