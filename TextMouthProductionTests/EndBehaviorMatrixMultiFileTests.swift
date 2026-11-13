import XCTest
@testable import TextMouth

// The end-behavior matrix, part 2: the multi-file audio column (a package of
// several tracks, like a ZIP of MP3s). See EndBehaviorMatrixTests.swift for
// the grid and the inventory.

extension EndBehaviorMatrixTests {

    /// The multi-file audio column's cells no other test pins: the
    /// inventory's multi-file column, less its covered cells.
    static let multiFileAudioCells = cells(except: [
        Cell(behavior: .stop, timer: .none),
        Cell(behavior: .stop, timer: .endOfBook),
        Cell(behavior: .stopAndPlayStartsOver, timer: .none),
        Cell(behavior: .loop, timer: .none),
        Cell(behavior: .loop, timer: .endOfBook),
        Cell(behavior: .continueNext, timer: .none),
        Cell(behavior: .continueNext, timer: .endOfBook),
        Cell(behavior: .continueNext, timer: .endOfHeading),
        Cell(behavior: .continueNext, timer: .minutesRunning),
    ])

    /// A book of two tracks, saved a moment (`secondsLeftWhenSaved`) from
    /// the end of the last, played to its end does what the cell says, for
    /// each cell of the multi-file audio column that no other test pins. The
    /// last track is long, so a loop plays on for long after the end.
    func testMultiFileAudioEndBehaviorMatrix() throws {
        preserveSleepTimers()
        // A loop starts the first track again, which must outlast the moments
        // the test spends after the end, or the cursor moves on.
        let firstTrackSeconds: TimeInterval = 5
        let lastTrackSeconds: TimeInterval = 10
        for cell in Self.multiFileAudioCells {
            let world = try makeIntegrationWorld("Matrix Multi-File \(cell.behavior) \(cell.timer)")
            world.settings.sleepFadeOutDuration = 0
            let book = try world.makeSilentAudioBook(
                title: "Ferry Timetable",
                trackDurations: [firstTrackSeconds, lastTrackSeconds],
                savedPosition: ReadingPosition(
                    chapterIndex: 1,
                    characterOffset: Self.offsetBeforeTheEnd(ofChapterOf: lastTrackSeconds)
                ),
                endOfBook: cell.behavior
            )
            let nextBook = try world.makeSilentAudioBook(title: "Harbour Almanac", trackDurations: [5])
            assertAudioBookEnd(
                of: cell, content: "multi-file audio", in: world, book: book, nextBook: nextBook,
                layout: .multiFile, lastChapter: 1
            )
        }
    }
}
