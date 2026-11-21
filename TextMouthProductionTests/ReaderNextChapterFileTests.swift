import AVFoundation
import Combine
import XCTest
@testable import TextMouth

/// A multi-file audiobook rolls straight on from each chapter's file into the
/// next (TODO PERF09). As each chapter starts, the reader names the next
/// chapter's file to its audio service, which queues it behind the one
/// playing, so the player plays on into it with no quarter-second gap. The
/// reader names none where playback may have to stop or wait at the
/// chapter's end: at the last chapter, while this reader's sleep timer is
/// set for the end of the heading, which an audiobook's chapter ends, and
/// before a file only in the cloud (see `ReaderCloudDownloadTests`).
/// However a chapter ends, the reader moves on
/// from it once, and its cursor never runs back within a chapter.
///
/// Every reader here plays real, silent tracks through the real audio
/// service (`IntegrationWorld.makeSilentAudioBook`); nothing is heard. Each
/// test stops its reader and lets go of the audio service's report hook
/// before it ends, so nothing reported later reaches a test that is over.
@MainActor
final class ReaderNextChapterFileTests: XCTestCase {

    // MARK: - Rolling On

    /// Each chapter plays straight on into the next on one player: the next
    /// chapter's file is queued as each chapter starts, and the chapter after
    /// it as soon as the reader takes the next one. Each chapter's end is
    /// reported once and ends the play under way, each chapter begins one
    /// play of its own, and the cursor never runs back within a chapter,
    /// not even for the moment between the player reaching the next file and
    /// the reader taking that chapter.
    func testEachChapterRollsStraightOnIntoTheNextOnOnePlayer() throws {
        let world = try makeIntegrationWorld("Next Chapter File")
        let book = try world.makeSilentAudioBook(title: "Harbour Soundings", trackDurations: [0.6, 1.2, 0.6])
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        let service = reader.audioPlaybackService
        let files = reader.audioChapterFiles.map(resolvedPath)
        // The reader made this list; a short one fails here, not at a subscript below.
        _ = try XCTUnwrap(files[safe: 2], "the book has no third chapter file")
        let reports = PlayerReportLog(observing: service)
        defer { service._reportHandledForTesting = nil }
        let trail = try CursorTrail(of: reader)
        let generationBefore = reader.chapterPlaybackGeneration
        defer { reader.stop() }

        reader.play()
        XCTAssertEqual(service.queuedFilePaths, [files[0], files[1]], "The second chapter's file was not queued")
        let player = try XCTUnwrap(service._playerForTesting)
        XCTAssertTrue(eventually(within: 10) { reader.currentChapterIndex == 1 }, "The second chapter never began")
        XCTAssertTrue(
            eventually(within: 1) { service.queuedFilePaths == [files[1], files[2]] },
            "The third chapter's file was not queued behind the second's: \(service.queuedFilePaths)"
        )
        XCTAssertTrue(service._playerForTesting === player, "The second chapter began on a new player")
        XCTAssertTrue(eventually(within: 10) { !reader.isCurrentlyPlaying }, "The book never ended")

        XCTAssertEqual(trail.chapters, [0, 1, 2], "A chapter was skipped or played twice")
        XCTAssertEqual(trail.placesRunningBack, [], "The cursor ran back within a chapter")
        XCTAssertFalse(trail.players.isEmpty, "Playback reported no position")
        XCTAssertTrue(trail.players.allSatisfy { $0 === player }, "A chapter played on a new player")
        XCTAssertEqual(reports.endOfFileOutcomes, [.endedPlay, .endedPlay, .endedPlay])
        XCTAssertEqual(reader.chapterPlaybackGeneration, generationBefore + 3, "Each chapter did not begin one play")
        XCTAssertEqual(reader.currentChapterIndex, 2)
    }

    // MARK: - Where Nothing Follows

    /// At the last chapter no file is named to follow: the book's end-of-book
    /// behavior decides what comes next, and the player stops at the last
    /// file's end, reporting it once. The chapter before names the last.
    func testTheLastChapterNamesNoFileToFollow() throws {
        let world = try makeIntegrationWorld("Next Chapter File Last")
        let book = try world.makeSilentAudioBook(title: "Harbour Soundings", trackDurations: [5, 0.6])
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        let service = reader.audioPlaybackService
        let files = reader.audioChapterFiles.map(resolvedPath)
        // The reader made this list; a short one fails here, not at a subscript below.
        _ = try XCTUnwrap(files[safe: 1], "the book has no second chapter file")
        defer { reader.stop() }

        reader.play()
        XCTAssertEqual(service.queuedFilePaths, files, "The last chapter's file was not named to follow the first's")
        reader.navigateTo(chapterIndex: 1, characterOffset: 0)
        let reports = PlayerReportLog(observing: service)
        defer { service._reportHandledForTesting = nil }

        XCTAssertEqual(service.queuedFilePaths, [files[1]], "A file was named to follow the last chapter")
        XCTAssertTrue(eventually(within: 10) { !reader.isCurrentlyPlaying }, "The last chapter never ended")
        XCTAssertEqual(reports.endOfFileOutcomes, [.endedPlay])
        XCTAssertFalse(service.isPlaying)
        XCTAssertEqual(service.loadedURL.map { resolvedPath($0.path) }, files[1], "The player moved past the last file")
    }

    /// While this reader's sleep timer is set for the end of the heading,
    /// which ends where every audiobook chapter does, since each chapter
    /// begins with its heading, no file is named to follow the chapter
    /// playing, so playback stops at its end. Setting such a timer while a
    /// chapter plays withdraws the file named; cancelling it, or setting a
    /// timer that counts minutes instead, names it again, and so does a
    /// timer set for the end of the book, which lets every chapter but the
    /// last roll on into the next.
    func testAnEndOfHeadingSleepTimerNamesNoFileToFollow() throws {
        preserveSleepTimers()
        let world = try makeIntegrationWorld("Next Chapter File Timer")
        let book = try world.makeSilentAudioBook(title: "Harbour Soundings", trackDurations: [5, 5])
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        let service = reader.audioPlaybackService
        let files = reader.audioChapterFiles.map(resolvedPath)
        let firstFile = Array(files.prefix(1))
        defer { reader.stop() }

        reader.startSleepTimer(duration: .endOfHeading)
        reader.play()
        XCTAssertTrue(service.isPlaying, "The first chapter did not play")
        XCTAssertEqual(service.queuedFilePaths, firstFile, "A file was named to follow under an end-of-heading timer")

        reader.cancelSleepTimer()
        XCTAssertEqual(service.queuedFilePaths, files, "Cancelling the timer did not name the next chapter's file")

        reader.startSleepTimer(duration: .endOfHeading)
        XCTAssertEqual(service.queuedFilePaths, firstFile, "Setting the timer as the chapter played kept the file named")

        reader.startSleepTimer(duration: .minutes(30))
        XCTAssertEqual(service.queuedFilePaths, files, "A timer counting minutes kept the next chapter's file from following")

        reader.startSleepTimer(duration: .endOfHeading)
        reader.startSleepTimer(duration: .endOfBook)
        XCTAssertEqual(
            service.queuedFilePaths,
            files,
            "A timer for the end of the book kept the next chapter's file from following"
        )
    }
}

// MARK: - Watching the Cursor

/// One place a reader's cursor stood: a chapter, and an offset in it.
private struct ReaderPlace: Equatable {
    /// The chapter.
    let chapter: Int
    /// The offset in the chapter, in characters (ten a second of audio).
    let offset: Int
}

/// What a reader's cursor did while a test watched: every chapter it was in,
/// and every place it stood as its audio service reported where playback
/// was, with the player that reported it.
///
/// Each place is recorded after the reader has handled the report, so a
/// report the reader took for the wrong chapter shows as the cursor running
/// back. Everything is captured weakly, so a report that arrives after the
/// test has let go of the trail changes nothing.
@MainActor
private final class CursorTrail {
    /// Every place the cursor stood after a report, in order, starting with
    /// where it stood when the trail began.
    private(set) var places: [ReaderPlace]
    /// The player the audio service held at each report, in order.
    private(set) var players: [AVPlayer] = []
    /// Every chapter the cursor was set to, in order, starting with the one
    /// it was in when the trail began.
    private var chaptersSet: [Int] = []
    /// Keeps the subscription to the reader's chapter alive.
    private var subscription: AnyCancellable?

    /// Starts following `reader`, whose audio callbacks must be set up: each
    /// report goes to the reader as before, and is recorded afterwards.
    init(of reader: ReaderViewModel) throws {
        let service = reader.audioPlaybackService
        let readerHandles = try XCTUnwrap(service.onPositionUpdate, "The reader takes no position reports")
        places = [ReaderPlace(chapter: reader.currentChapterIndex, offset: reader.currentCharacterOffset)]
        service.onPositionUpdate = { [weak self, weak reader, weak service] time in
            readerHandles(time)
            guard let self, let reader else { return }
            self.places.append(ReaderPlace(chapter: reader.currentChapterIndex, offset: reader.currentCharacterOffset))
            if let player = service?._playerForTesting {
                self.players.append(player)
            }
        }
        subscription = reader.$currentChapterIndex.sink { [weak self] chapter in
            self?.chaptersSet.append(chapter)
        }
    }

    /// The chapters the cursor was in, in order, each stay in one chapter
    /// named once.
    var chapters: [Int] {
        chaptersSet.runs
    }

    /// Each pair of consecutive places in one chapter where the second lies
    /// before the first.
    var placesRunningBack: [[ReaderPlace]] {
        zip(places, places.dropFirst())
            .filter { earlier, later in earlier.chapter == later.chapter && later.offset < earlier.offset }
            .map { [$0, $1] }
    }
}

// MARK: - The Player's Queue

extension AudioPlaybackService {
    /// The files this service's player holds, in the order it plays them:
    /// the loaded file first, then any named to follow it
    /// (`setFileAfterCurrent(_:)`), each by its path with symbolic links
    /// resolved. Empty without a player.
    @MainActor
    var queuedFilePaths: [String] {
        guard let player = _playerForTesting as? AVQueuePlayer else { return [] }
        return player.items()
            .compactMap { ($0.asset as? AVURLAsset)?.url }
            .map { resolvedPath($0.path) }
    }
}

/// `path` with symbolic links resolved and standardized, so two spellings of
/// one file compare equal.
func resolvedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
}
