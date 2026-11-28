import XCTest
@testable import TextMouth

// The end-behavior matrix, part 2: the chaptered audio column (one m4b with
// chapter markers). See EndBehaviorMatrixTests.swift for the grid and the
// inventory.

extension EndBehaviorMatrixTests {

    /// The chaptered audio column's cells no other test pins: every cell but
    /// Stop with no timer, which `FinishedBookReaderTests` pins.
    static let chapteredAudioCells = cells(except: [Cell(behavior: .stop, timer: .none)])

    /// An m4b of two chapters, saved a moment (`secondsLeftWhenSaved`) from
    /// its end, played to its end does what the cell says, for each cell of
    /// the chaptered audio column that no other test pins. The last chapter
    /// is long, so a loop plays on for long after the end.
    ///
    /// Writing an m4b encodes AAC and takes a moment, so the file is written
    /// once, for the first cell's book, and every other cell's book (a row
    /// of its own in a world of its own) gets a copy of it.
    func testChapteredAudioEndBehaviorMatrix() throws {
        preserveSleepTimers()
        // A loop starts the first chapter again, which must outlast the moments
        // the test spends after the end, or the cursor moves on.
        let firstChapterSeconds: TimeInterval = 5
        let lastChapterSeconds: TimeInterval = 10
        let savedPosition = ReadingPosition(
            chapterIndex: 1,
            characterOffset: Self.offsetBeforeTheEnd(ofChapterOf: lastChapterSeconds)
        )
        // The first cell's m4b, once it is written, which later cells copy.
        var template: URL?
        for cell in Self.chapteredAudioCells {
            let world = try makeIntegrationWorld("Matrix Chaptered \(cell.behavior) \(cell.timer)")
            world.settings.sleepFadeOutDuration = 0
            let book: Book
            if let template {
                book = try world.makeOneFileAudioBook(
                    title: "Ferry Timetable", fileName: "Ferry Timetable.m4b",
                    savedPosition: savedPosition, endOfBook: cell.behavior
                ) { file in
                    // The book's package does not exist yet: the writer makes it.
                    try FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(), withIntermediateDirectories: true
                    )
                    try FileManager.default.copyItem(at: template, to: file)
                }
            } else {
                book = try makeChapteredAudioBook(
                    title: "Ferry Timetable",
                    in: world,
                    duration: firstChapterSeconds + lastChapterSeconds,
                    markers: [
                        AudioTestFixtures.ChapterMarker(title: "Approach", start: 0, duration: firstChapterSeconds),
                        AudioTestFixtures.ChapterMarker(title: "Breakwater", start: firstChapterSeconds, duration: lastChapterSeconds),
                    ],
                    savedPosition: savedPosition,
                    endOfBook: cell.behavior
                )
                // The next cell's world replaces this one's folder, so the
                // file is kept in a folder of its own, removed at tear-down.
                let kept = try AudioTestFixtures.makeTemporaryDirectory()
                addTeardownBlock { try? FileManager.default.removeItem(at: kept) }
                let copy = kept.appendingPathComponent("template.m4b")
                try FileManager.default.copyItem(at: URL(fileURLWithPath: book.filePath), to: copy)
                template = copy
            }
            let nextBook = try world.makeSilentAudioBook(title: "Harbour Almanac", trackDurations: [5])
            assertAudioBookEnd(
                of: cell, content: "chaptered audio", in: world, book: book, nextBook: nextBook,
                layout: .chaptersInOneFile, lastChapter: 1
            )
        }
    }
}
