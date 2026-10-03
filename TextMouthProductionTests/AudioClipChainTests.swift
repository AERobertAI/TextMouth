import AVFoundation
import XCTest
@testable import TextMouth

/// A chapter whose audio is several clips, in one file or several, plays
/// them one after another as one chapter (TODO I03). The chapter's time
/// runs on unbroken across clips, seeking finds the clip holding a time,
/// and the chapter finishes once, after its last clip.
///
/// The first tests convert times without playing anything. The rest play
/// silent WAV files, written for each test into a folder of its own, with
/// the real audio service.
@MainActor
final class AudioClipChainTests: XCTestCase {

    // MARK: - Chapter Time and Clips

    /// Each clip starts in the chapter where the clips before it end.
    func testClipsStartWhereTheClipsBeforeThemEnd() throws {
        let chain = try makeChain([("a.wav", 10, 15), ("b.wav", 0, 2.5), ("c.wav", 3, 7)])

        XCTAssertEqual(chain.startTimes, [0, 5, 7.5])
    }

    /// A time in the chapter is found in the clip holding it, at the
    /// matching time in that clip's file. Where one clip ends and the next
    /// begins, the next clip plays.
    func testChapterTimeFindsItsClipAndTheTimeInItsFile() throws {
        let chain = try makeChain([("a.wav", 10, 15), ("b.wav", 0, 2.5), ("c.wav", 3, 7)])

        assertLocation(chain, at: 0, isClip: 0, fileTime: 10)
        assertLocation(chain, at: 4, isClip: 0, fileTime: 14)
        assertLocation(chain, at: 5, isClip: 1, fileTime: 0)
        assertLocation(chain, at: 6.5, isClip: 1, fileTime: 1.5)
        assertLocation(chain, at: 8, isClip: 2, fileTime: 3.5)
    }

    /// A time before the chapter is its start; one past its end lies past
    /// the last clip's end, where playback finishes at once; a time that is
    /// not a number is the start.
    func testTimesOutsideTheChapterFallInItsFirstOrLastClip() throws {
        let chain = try makeChain([("a.wav", 10, 15), ("b.wav", 0, 2.5), ("c.wav", 3, 7)])

        assertLocation(chain, at: -3, isClip: 0, fileTime: 10)
        assertLocation(chain, at: 20, isClip: 2, fileTime: 15.5)
        assertLocation(chain, at: .nan, isClip: 0, fileTime: 10)
    }

    /// A time in a clip's file is that far into the chapter, held within
    /// the clip: a player running a moment past a clip's end reports its
    /// end, where the next clip begins the chapter's time.
    func testFileTimeIsHeldWithinItsClip() throws {
        let chain = try makeChain([("a.wav", 10, 15), ("b.wav", 0, 2.5), ("c.wav", 3, 7)])

        XCTAssertEqual(chain.chapterTime(clipIndex: 1, fileTime: 1.5), 6.5)
        XCTAssertEqual(chain.chapterTime(clipIndex: 0, fileTime: 15.2), 5)
        XCTAssertEqual(chain.chapterTime(clipIndex: 2, fileTime: 1), 7.5)
    }

    /// A last clip that plays to its file's end runs on as far as the file.
    func testLastClipPlayingToItsFilesEndRunsOn() throws {
        let chain = try makeChain([("a.wav", 0, 2), ("b.wav", 1, nil)])

        XCTAssertEqual(chain.chapterTime(clipIndex: 1, fileTime: 30), 31)
        assertLocation(chain, at: 12, isClip: 1, fileTime: 11)
    }

    /// A clip that lasts no time is passed over.
    func testClipLastingNoTimeIsPassedOver() throws {
        let chain = try makeChain([("a.wav", 0, 2), ("b.wav", 5, 5), ("c.wav", 0, 1)])

        XCTAssertEqual(chain.startTimes, [0, 2, 2])
        assertLocation(chain, at: 2, isClip: 2, fileTime: 0)
    }

    /// A segment's chain finds each clip's file in the book's audio folder,
    /// and a clip ending at 0, or not after its start, plays to its file's
    /// end, as a segment's clip always has.
    func testSegmentChainFindsItsFilesInTheBooksFolder() throws {
        let folder = URL(fileURLWithPath: "/Library/Book.tmb/audio", isDirectory: true)
        let segment = try XCTUnwrap(AudioSegment(title: "Survey", clips: [
            AudioClip(file: "Disc 2/03.mp3", startTime: 4, endTime: 9),
            AudioClip(file: "04.mp3", startTime: 1, endTime: 0)
        ]))

        let chain = AudioClipChain(segment: segment, folder: folder)

        XCTAssertEqual(chain.clips, [
            AudioClipChain.Clip(url: folder.appendingPathComponent("Disc 2/03.mp3"), start: 4, end: 9),
            AudioClipChain.Clip(url: folder.appendingPathComponent("04.mp3"), start: 1, end: nil)
        ])
        XCTAssertEqual(chain.startTimes, [0, 5])
    }

    /// A chain always holds a clip.
    func testChainNeedsAClip() {
        XCTAssertNil(AudioClipChain(clips: []))
    }

    /// The time left in the chapter runs from a time in it to the end of its
    /// last clip, never below nothing. A last clip that plays to its file's
    /// end is measured by that file's length, and without it the time left
    /// is not known (TODO P01: a sleep timer's fade before the chapter's
    /// end).
    func testTimeLeftRunsToTheEndOfTheLastClip() throws {
        let chain = try makeChain([("a.wav", 10, 15), ("b.wav", 0, 2.5), ("c.wav", 3, 7)])

        XCTAssertEqual(chain.timeLeft(fromChapterTime: 0, lastClipFileLength: nil), 11.5)
        XCTAssertEqual(chain.timeLeft(fromChapterTime: 8, lastClipFileLength: nil), 3.5)
        XCTAssertEqual(chain.timeLeft(fromChapterTime: 20, lastClipFileLength: nil), 0)

        let endless = try makeChain([("a.wav", 0, 2), ("b.wav", 1, nil)])
        XCTAssertNil(endless.timeLeft(fromChapterTime: 1, lastClipFileLength: nil))
        XCTAssertEqual(endless.timeLeft(fromChapterTime: 1, lastClipFileLength: 9), 9)
        XCTAssertEqual(endless.timeLeft(fromChapterTime: 4, lastClipFileLength: 9), 6)
    }

    // MARK: - Playing a Chain

    /// A chapter whose clips lie in three files plays each file in turn,
    /// from each clip's start to its end. The chapter's time runs on
    /// without going back from 0 to the clips' total, and playback finishes
    /// once, after the last clip.
    func testChainOfThreeFilesPlaysEveryClipInOrderAndFinishesOnce() throws {
        let folder = try writeThreeFiles()
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = ChainEvents(observing: playback)

        XCTAssertTrue(playback.playClips(try threeFileChain(in: folder), fromChapterTime: 0))
        XCTAssertEqual(playback.loadedURL?.lastPathComponent, "a.wav")

        XCTAssertTrue(eventually(within: 15) { events.finishedCount == 1 }, "The chapter never finished")
        spinMainRunLoop(for: 0.5)

        XCTAssertEqual(events.finishedCount, 1)
        XCTAssertEqual(events.failures, [])
        XCTAssertEqual(events.filesInOrder, ["a.wav", "b.wav", "c.wav"])
        events.assertTimeNeverGoesBack()
        // Each clip took over exactly where the clips before it end, and the
        // chapter's time never passed its end.
        XCTAssertTrue(events.reported(0.5), "\(events.times)")
        XCTAssertTrue(events.reported(1.1), "\(events.times)")
        XCTAssertLessThanOrEqual(events.times.max() ?? 0, Self.threeFileTotal + 0.001)
        XCTAssertFalse(playback.isPlaying)
    }

    /// Seeking into the stretch of the chapter the second clip plays loads
    /// the second file, at the matching time in it, and plays on from there
    /// through the third clip to one finish.
    func testSeekingIntoTheSecondClipLoadsTheSecondFile() throws {
        let folder = try writeThreeFiles()
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = ChainEvents(observing: playback)
        XCTAssertTrue(playback.playClips(try threeFileChain(in: folder), fromChapterTime: 0))
        waitUntilReady(try XCTUnwrap(playback._playerItemForTesting))

        // 0.8 s into the chapter is 0.3 s into the second clip, which
        // starts at the second file's start.
        playback.seek(to: 0.8)

        XCTAssertEqual(playback.loadedURL?.lastPathComponent, "b.wav")
        XCTAssertEqual(playback.currentTime, 0.8, accuracy: 0.001)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertFalse(playback.isPaused)
        XCTAssertTrue(eventually(within: 15) { events.finishedCount == 1 }, "The chapter never finished")
        XCTAssertEqual(Array(events.filesInOrder.suffix(2)), ["b.wav", "c.wav"])
        XCTAssertEqual(events.failures, [])
    }

    /// Paused playback seeking into another clip loads that clip's file and
    /// stays paused there; Resume then plays on from it.
    func testSeekWhilePausedIntoAnotherClipStaysPaused() throws {
        let folder = try writeThreeFiles()
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = ChainEvents(observing: playback)
        XCTAssertTrue(playback.playClips(try threeFileChain(in: folder), fromChapterTime: 0))
        waitUntilReady(try XCTUnwrap(playback._playerItemForTesting))
        playback.pause()

        // 1.3 s into the chapter is 0.2 s into the third clip, which starts
        // 0.2 s into the third file.
        playback.seek(to: 1.3)
        spinMainRunLoop(for: 0.4)

        XCTAssertEqual(playback.loadedURL?.lastPathComponent, "c.wav")
        XCTAssertTrue(playback.isPaused)
        XCTAssertEqual(playback.currentTime, 1.3, accuracy: 0.01)
        XCTAssertEqual(events.finishedCount, 0)

        XCTAssertTrue(playback.resume())
        XCTAssertTrue(eventually(within: 15) { events.finishedCount == 1 }, "The chapter never finished")
        XCTAssertEqual(events.failures, [])
    }

    /// A later clip's missing file is reported when playback reaches it,
    /// naming that file. The chapter's time stands where that clip begins,
    /// so playing again starts there, and playback never finishes.
    func testMissingFileOfALaterClipIsReportedWhenPlaybackReachesIt() throws {
        let folder = try writeThreeFiles()
        try FileManager.default.removeItem(at: folder.appendingPathComponent("b.wav"))
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = ChainEvents(observing: playback)

        XCTAssertTrue(playback.playClips(try threeFileChain(in: folder), fromChapterTime: 0))
        XCTAssertTrue(eventually(within: 15) { !events.failures.isEmpty }, "The missing file was never reported")
        spinMainRunLoop(for: 0.5)

        XCTAssertEqual(events.failures, [
            AudioPlaybackFailure(reason: .fileMissing, url: folder.appendingPathComponent("b.wav").standardizedFileURL)
        ])
        XCTAssertEqual(events.times.last, 0.5)
        XCTAssertEqual(events.finishedCount, 0)
        XCTAssertFalse(playback.isPlaying)
    }

    /// Two clips of one file play with a seek between them: the player and
    /// its item stay, the skipped stretch is not played, and the chapter
    /// finishes once, after the second clip.
    func testClipsSharingAFileSeekWithinIt() throws {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 1)
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = ChainEvents(observing: playback)
        let chain = try makeChain([("a.wav", 0, 0.3), ("a.wav", 0.6, 1)], in: folder)

        XCTAssertTrue(playback.playClips(chain, fromChapterTime: 0))
        let item = try XCTUnwrap(playback._playerItemForTesting)
        XCTAssertTrue(eventually(within: 15) { events.finishedCount == 1 }, "The chapter never finished")
        spinMainRunLoop(for: 0.5)

        XCTAssertEqual(events.finishedCount, 1)
        XCTAssertTrue(playback._playerItemForTesting === item, "The second clip of the same file replaced the item")
        XCTAssertTrue(events.reported(0.3), "\(events.times)")
        events.assertTimeNeverGoesBack()
        XCTAssertLessThanOrEqual(events.times.max() ?? 0, 0.7 + 0.001)
    }

    /// A file told to stop exactly where it ends hears its end twice, from
    /// the clip-end check and from AVFoundation's end-of-file notice, and
    /// still finishes once.
    func testClipEndingWhereItsFileEndsFinishesOnce() throws {
        let folder = try writeThreeFiles()
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        let events = ChainEvents(observing: playback)
        XCTAssertTrue(playback.load(url: folder.appendingPathComponent("b.wav")))
        playback.setClipEndTime(0.6)

        XCTAssertTrue(playback.play(fromTime: 0.2))
        XCTAssertTrue(eventually(within: 15) { events.finishedCount >= 1 }, "The file never finished")
        spinMainRunLoop(for: 0.5)

        XCTAssertEqual(events.finishedCount, 1)
        XCTAssertFalse(playback.isPlaying)
    }

    /// Play, given a time while a chain plays, plays from that time in the
    /// chapter.
    func testPlayDuringAChainPlaysFromATimeInTheChapter() throws {
        let folder = try writeThreeFiles()
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        XCTAssertTrue(playback.playClips(try threeFileChain(in: folder), fromChapterTime: 0))

        XCTAssertTrue(playback.play(fromTime: 1.3))

        XCTAssertEqual(playback.loadedURL?.lastPathComponent, "c.wav")
        XCTAssertEqual(playback.currentTime, 1.3, accuracy: 0.001)
    }

    /// A file loaded on its own ends the chain: its times are its own again.
    func testLoadingAFileEndsTheChain() throws {
        let folder = try writeThreeFiles()
        let playback = AudioPlaybackService()
        defer { playback.stop() }
        XCTAssertTrue(playback.playClips(try threeFileChain(in: folder), fromChapterTime: 1.3))

        XCTAssertTrue(playback.load(url: folder.appendingPathComponent("b.wav")))
        XCTAssertTrue(playback.play(fromTime: 0.25))
        XCTAssertEqual(playback.currentTime, 0.25, accuracy: 0.001)
        playback.seek(to: 0.5)

        XCTAssertEqual(playback.loadedURL?.lastPathComponent, "b.wav")
        XCTAssertEqual(playback.currentTime, 0.5, accuracy: 0.001)
    }

    // MARK: - Fixtures

    /// The clips' lengths together in `threeFileChain`: 0.5 + 0.6 + 0.6.
    private static let threeFileTotal: TimeInterval = 1.7

    /// A new folder, removed when the test ends, holding three silent WAVs:
    /// a.wav lasting a second, b.wav 0.6 seconds, and c.wav 0.8 seconds.
    private func writeThreeFiles() throws -> URL {
        let folder = try AudioTestFixtures.makeTemporaryDirectory()
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 1)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("b.wav"), duration: 0.6)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("c.wav"), duration: 0.8)
        return folder
    }

    /// One chapter over `writeThreeFiles()`: the second half of a.wav, all
    /// of b.wav, and c.wav from 0.2 seconds in. Each clip ends at its file's
    /// end, so the chapter's clips begin at 0, 0.5, and 1.1 seconds.
    private func threeFileChain(in folder: URL) throws -> AudioClipChain {
        try makeChain([("a.wav", 0.5, 1), ("b.wav", 0, 0.6), ("c.wav", 0.2, 0.8)], in: folder)
    }

    /// A chain of `clips`, each a file name in `folder`, a start, and an end
    /// (nil to play to the end of the file).
    private func makeChain(
        _ clips: [(file: String, start: TimeInterval, end: TimeInterval?)],
        in folder: URL = URL(fileURLWithPath: "/tmp/audio", isDirectory: true)
    ) throws -> AudioClipChain {
        try XCTUnwrap(AudioClipChain(clips: clips.map {
            AudioClipChain.Clip(url: folder.appendingPathComponent($0.file), start: $0.start, end: $0.end)
        }))
    }

    /// Assert that `time` seconds into `chain`'s chapter lies in clip
    /// `clipIndex`, `fileTime` seconds into its file.
    private func assertLocation(
        _ chain: AudioClipChain,
        at time: TimeInterval,
        isClip clipIndex: Int,
        fileTime: TimeInterval,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let location = chain.location(atChapterTime: time)
        XCTAssertEqual(location.clipIndex, clipIndex, "Clip at \(time)", file: file, line: line)
        XCTAssertEqual(location.fileTime, fileTime, accuracy: 1e-9, "File time at \(time)", file: file, line: line)
    }
}

/// What an audio service reported while it played a chain: each position
/// with the file loaded as it came, each failure, and how many times
/// playback finished. Written and read on the main queue, where the
/// service calls back.
@MainActor
private final class ChainEvents {
    /// Every position `onPositionUpdate` reported, with the name of the
    /// file loaded at that moment.
    private(set) var positions: [(file: String?, time: TimeInterval)] = []
    /// Every failure `onPlaybackFailed` delivered.
    private(set) var failures: [AudioPlaybackFailure] = []
    /// How many times `onPlaybackFinished` was called.
    private(set) var finishedCount = 0

    /// Start recording `playback`'s reports, replacing its callbacks.
    init(observing playback: AudioPlaybackService) {
        playback.onPositionUpdate = { [unowned self, weak playback] time in
            self.positions.append((playback?.loadedURL?.lastPathComponent, time))
        }
        playback.onPlaybackFailed = { [unowned self] failure in
            self.failures.append(failure)
        }
        playback.onPlaybackFinished = { [unowned self] in
            self.finishedCount += 1
        }
    }

    /// The reported times, in order.
    var times: [TimeInterval] { positions.map(\.time) }

    /// Whether `time` was reported, to within the rounding of adding up
    /// clip lengths.
    func reported(_ time: TimeInterval) -> Bool {
        times.contains { abs($0 - time) < 1e-9 }
    }

    /// The files positions were reported from, in order, each run of
    /// reports from one file named once.
    var filesInOrder: [String] {
        positions.compactMap(\.file).reduce(into: []) { files, file in
            if files.last != file { files.append(file) }
        }
    }

    /// Assert that no reported time is earlier than the one before it,
    /// allowing a millisecond for the player's own rounding.
    func assertTimeNeverGoesBack(file: StaticString = #filePath, line: UInt = #line) {
        for (earlier, later) in zip(times, times.dropFirst()) where later < earlier - 0.001 {
            XCTFail("The chapter's time went back from \(earlier) to \(later): \(times)", file: file, line: line)
            return
        }
    }
}
