import XCTest
@testable import TextMouth

// The end-behavior matrix, part 2: the DAISY column (segmented audio, whose
// sections play clips of the files). See EndBehaviorMatrixTests.swift for the
// grid and the inventory.

extension EndBehaviorMatrixTests {

    /// The DAISY column's cells no other test pins: every cell but Stop with
    /// no timer, which `FinishedBookReaderTests` pins.
    static let daisyCells = cells(except: [Cell(behavior: .stop, timer: .none)])

    /// A segmented book of two sections, the last of two clips, saved half a
    /// second from its end, played to its end does what the cell says, for
    /// each cell of the DAISY column that no other test pins. The last
    /// section is long, so a loop plays on for long after the end.
    func testDAISYEndBehaviorMatrix() throws {
        preserveSleepTimers()
        // The first section is long enough to outlast the moments the test
        // spends after a loop starts it again. The last section plays half a second of the first file's tail and
        // ten seconds of the second.
        let lastSectionSeconds: TimeInterval = 10.5
        for cell in Self.daisyCells {
            let world = try makeIntegrationWorld("Matrix DAISY \(cell.behavior) \(cell.timer)")
            world.settings.sleepFadeOutDuration = 0
            let book = try world.makeSegmentedAudioBook(
                title: "Ferry Timetable",
                files: ["a.wav": 5.5, "b.wav": 10],
                sections: [
                    AudioSegment(title: "Approach", file: "a.wav", startTime: 0, endTime: 5),
                    try XCTUnwrap(AudioSegment(title: "Breakwater", clips: [
                        AudioClip(file: "a.wav", startTime: 5, endTime: 5.5),
                        AudioClip(file: "b.wav", startTime: 0, endTime: 10),
                    ])),
                ],
                savedPosition: ReadingPosition(
                    chapterIndex: 1,
                    characterOffset: Self.offsetBeforeTheEnd(ofChapterOf: lastSectionSeconds)
                ),
                endOfBook: cell.behavior
            )
            let nextBook = try world.makeSilentAudioBook(title: "Harbour Almanac", trackDurations: [5])
            assertAudioBookEnd(
                of: cell, content: "DAISY", in: world, book: book, nextBook: nextBook,
                layout: .segmented, lastChapter: 1
            )
        }
    }
}
