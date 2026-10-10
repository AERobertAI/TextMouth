import XCTest
@testable import TextMouth

/// A book that plays to its end, in a real reader (TODO P07): where it
/// rests, what Play and a rewind do there, and how often it is counted.
///
/// The user decided on October 10, 2026 that a book that plays to its end
/// is saved exactly at its end and stays finished after TextMouth quits
/// (question 11). Every audiobook here is silent WAV or AAC audio, so a
/// reader that plays it is never heard, and announcements are recorded
/// instead of spoken.
@MainActor
final class FinishedBookReaderTests: XCTestCase {

    // MARK: - Resting at the End

    /// The ways an audiobook's chapters can lie in its files, each with its
    /// own way of reporting the end (`ReaderViewModel.AudioLayout`).
    private enum Layout: String, CaseIterable {
        /// A file per chapter: the last file's natural end.
        case filePerChapter
        /// One file, one chapter: the file's natural end.
        case oneFile
        /// One file with chapter marks, an m4b: the last chapter's clip end.
        case chapterMarks
        /// A DAISY audiobook's clips: the last clip of the last chapter's
        /// chain.
        case clips

        /// The layout the reader finds the book in.
        var audioLayout: ReaderViewModel.AudioLayout {
            switch self {
            case .filePerChapter: return .multiFile
            case .oneFile: return .singleFile
            case .chapterMarks: return .chaptersInOneFile
            case .clips: return .segmented
            }
        }
    }

    /// Every audiobook layout, played to its end with the Stop behavior,
    /// rests exactly at its end: the last chapter at its full length, the
    /// cursor's global offset the book's total, saved to the library's row.
    /// The player's clock, which ticks once more as it stops at the end,
    /// moves it no more, and closing the window keeps it there (TODO P07).
    /// It once rested at the last quarter-second tick the player reported,
    /// or a moment past the end, wherever the late tick put it.
    func testEveryAudiobookLayoutRestsExactlyAtItsEnd() throws {
        for layout in Layout.allCases {
            let world = try makeIntegrationWorld("Finished End \(layout.rawValue)")
            let book = try makeAudioBook(layout, titled: "Harbour Soundings", in: world)
            let reader = world.openReader(for: book, nowPlaying: privateMediaSession())
            waitForReaderToLoad(reader)
            XCTAssertNil(reader.errorMessage, "\(layout): the book did not open")
            XCTAssertEqual(reader.audioLayout, layout.audioLayout, "\(layout): the book opened in another layout")
            let end = try XCTUnwrap(reader.endOfBookPlace, "\(layout): no end")

            let recorder = recordingAnnouncements {
                reader.play()
                XCTAssertTrue(reader.audioPlaybackService.isPlaying, "\(layout): the book did not play")
                XCTAssertTrue(
                    eventually(within: 10) { reader.lastAnnouncement != nil },
                    "\(layout): the book never finished"
                )
                // Long enough for the player's last tick, as it stops at the
                // end, to have been handled.
                spinMainRunLoop(for: 0.5)
            }
            XCTAssertEqual(recorder.announcements.map(\.message), ["Finished: Harbour Soundings"], "\(layout)")
            assertRestsAtItsEnd(reader, end: end, in: world, "\(layout): after the end")

            // Closing lets go of the book's content, so its total is taken
            // first.
            let total = reader.content?.totalCharacterCount
            reader.close()
            assertSavedAtItsEnd(book, end: end, total: total, in: world, "\(layout): closed")
        }
    }

    // MARK: - Fixtures

    /// How many seconds of silence the last chapter of every audiobook
    /// holds: long enough for a skip of either unit to land inside it.
    private static let lastChapterSeconds: TimeInterval = 2

    /// Where every audiobook was last read: half a second before the end of
    /// its last chapter, ten characters standing for a second of audio.
    private static let lastHalfSecond = Int((lastChapterSeconds - 0.5) * ReaderViewModel.audioCharsPerSecond)

    /// An audiobook titled `title` in `layout`, in `world`, whose last
    /// chapter lasts `lastChapterSeconds`, saved half a second before its
    /// end, ending with the Stop behavior unless `endOfBook` says otherwise.
    private func makeAudioBook(
        _ layout: Layout,
        titled title: String,
        in world: IntegrationWorld,
        endOfBook: EndOfBookBehavior = .stop
    ) throws -> Book {
        switch layout {
        case .filePerChapter:
            return try world.makeSilentAudioBook(
                title: title,
                trackDurations: [1, Self.lastChapterSeconds],
                savedPosition: ReadingPosition(chapterIndex: 1, characterOffset: Self.lastHalfSecond),
                endOfBook: endOfBook
            )
        case .oneFile:
            return try world.makeSilentAudioFileBook(
                title: title,
                duration: Self.lastChapterSeconds,
                savedPosition: ReadingPosition(chapterIndex: 0, characterOffset: Self.lastHalfSecond),
                endOfBook: endOfBook
            )
        case .chapterMarks:
            return try makeChapteredAudioBook(
                title: title,
                in: world,
                duration: 1 + Self.lastChapterSeconds,
                markers: [
                    AudioTestFixtures.ChapterMarker(title: "Approach", start: 0, duration: 1),
                    AudioTestFixtures.ChapterMarker(title: "Breakwater", start: 1, duration: Self.lastChapterSeconds),
                ],
                savedPosition: ReadingPosition(chapterIndex: 1, characterOffset: Self.lastHalfSecond),
                endOfBook: endOfBook
            )
        case .clips:
            // The last chapter plays two clips, the first sharing its file
            // with the chapter before.
            return try world.makeSegmentedAudioBook(
                title: title,
                files: ["a.wav": 1.5, "b.wav": 1.5],
                sections: [
                    AudioSegment(title: "Approach", file: "a.wav", startTime: 0, endTime: 1),
                    try XCTUnwrap(AudioSegment(title: "Breakwater", clips: [
                        AudioClip(file: "a.wav", startTime: 1, endTime: 1.5),
                        AudioClip(file: "b.wav", startTime: 0, endTime: 1.5),
                    ])),
                ],
                savedPosition: ReadingPosition(chapterIndex: 1, characterOffset: Self.lastHalfSecond),
                endOfBook: endOfBook
            )
        }
    }

    /// A media session of the test's own, as a reader's only member, so the
    /// reader is the active owner, as a finished book's reader is while no
    /// other book plays: readers of other tests may still be registered in
    /// the app's shared session.
    private func privateMediaSession() -> NowPlayingService {
        NowPlayingService(installsSystemIntegrations: false, diagnosticSink: { _ in })
    }

    // MARK: - Checks

    /// Check that `reader`'s book rests exactly at its end, `end`: the cursor
    /// there, which the reader reads as the end, and the book saved there.
    private func assertRestsAtItsEnd(
        _ reader: ReaderViewModel,
        end: (chapterIndex: Int, characterOffset: Int),
        in world: IntegrationWorld,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(reader.currentChapterIndex, end.chapterIndex, "\(context): the cursor is in another chapter", file: file, line: line)
        XCTAssertEqual(reader.currentCharacterOffset, end.characterOffset, "\(context): the cursor is not at the end", file: file, line: line)
        XCTAssertTrue(reader.cursorRestsAtEnd, "\(context): the reader does not read its cursor as the end", file: file, line: line)
        assertSavedAtItsEnd(reader.book, end: end, total: reader.content?.totalCharacterCount, in: world, context, file: file, line: line)
    }

    /// Check that the library's row of `book` is saved exactly at its end,
    /// `end`, whose global offset is the book's `total`, and so reads as
    /// finished once measured, as the library measures every book.
    private func assertSavedAtItsEnd(
        _ book: Book,
        end: (chapterIndex: Int, characterOffset: Int),
        total: Int?,
        in world: IntegrationWorld,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var row = world.library.bookByID(book.id)
        let saved = row?.readingPosition
        XCTAssertEqual(saved?.chapterIndex, end.chapterIndex, "\(context): saved in another chapter", file: file, line: line)
        XCTAssertEqual(saved?.characterOffset, end.characterOffset, "\(context): saved short of the end", file: file, line: line)
        XCTAssertEqual(saved?.globalCharacterOffset, total, "\(context): the saved place is not the book's end", file: file, line: line)
        row?.totalCharacterCount = total
        XCTAssertEqual(row?.restsAtEnd, true, "\(context): the measured row is not finished", file: file, line: line)
    }
}
