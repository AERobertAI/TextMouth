import Combine
import XCTest
@testable import TextMouth

/// The pause a multi-file audiobook's manifest puts between its tracks
/// (`ChapterPauses`), waited out by the reader before it starts the next
/// track: the cursor moves to the next track's start as the track before it
/// ends, nothing plays for the pause, and the next track then starts, from a
/// start that waits as a cancellable work item. While it waits the book is
/// still playing; a pause, a stop, closing the reader, a sleep timer's stop,
/// and any other start cancel it, so nothing ever starts twice. A book
/// without a manifest, or with a pause of 0, plays straight on as before,
/// the next track's file queued behind the one playing (TODO PERF09).
///
/// Every reader plays real, silent tracks through the real audio service
/// (`IntegrationWorld.makeSilentAudioBook`), with its sound effects
/// recorded, never played: nothing is heard. The pauses are a few hundred
/// milliseconds, waited for on the main run loop, never slept through.
@MainActor
final class ReaderChapterPauseTests: XCTestCase {
    /// The pause the books here keep between their tracks, in seconds: a
    /// few hundred milliseconds, long enough for a test to act during it on
    /// a busy Mac.
    private static let pause: TimeInterval = 0.6
    /// The manifest that gives that pause between every two tracks.
    private static let pausing = #"{"pauseBetweenTracksMs": 600}"#
    /// Long enough for a pause to have passed, with a margin.
    private static let pastThePause: TimeInterval = 1.0

    // MARK: - The Pause

    /// The track's end moves the cursor to the next track's start, the book
    /// still playing, its player stopped and holding no file; the next
    /// track starts once the pause has passed, and no sooner. No file is
    /// named to follow a track a pause follows, and none follows the last
    /// track, which ends the book.
    func testThePauseIsSilenceBeforeTheNextTrackStarts() throws {
        let world = try makeIntegrationWorld("Chapter Pause")
        let reader = try openBook(in: world, title: "Harbor Plays", trackDurations: [0.4, 0.4], manifest: Self.pausing)
        let service = reader.audioPlaybackService
        let files = reader.audioChapterFiles.map(resolvedPath)
        _ = try XCTUnwrap(files[safe: 1], "the book has fewer than two chapter files")
        let moments = Moments(of: reader)
        defer { reader.stop() }
        XCTAssertEqual(reader.pauseAfterChapter(0), Self.pause)
        XCTAssertEqual(reader.pauseAfterChapter(1), 0)

        reader.play()
        XCTAssertEqual(service.queuedFilePaths, [files[0]], "A file was named to follow a track a pause follows")
        XCTAssertTrue(eventually(within: 10) { reader.isWaitingOutChapterPause }, "The pause never began")

        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(reader.currentCharacterOffset, 0)
        XCTAssertFalse(service.isPlaying, "Something played during the pause")
        XCTAssertNil(service.loadedURL, "The player kept the file that ended")
        XCTAssertTrue(reader.isPlaybackUnderWay, "The book did not count as playing during the pause")
        XCTAssertTrue(reader.isCurrentlyPlaying)
        XCTAssertFalse(reader.isCurrentlyPaused)

        XCTAssertTrue(eventually(within: 5) { service.isPlaying }, "The next track never started")
        XCTAssertEqual(service.loadedURL.map { resolvedPath($0.path) }, files[1])
        XCTAssertFalse(reader.isWaitingOutChapterPause)
        let pause = try XCTUnwrap(moments.pause, "The pause was not measured")
        XCTAssertGreaterThanOrEqual(pause, Self.pause - 0.01, "The next track started before the pause had passed")
        XCTAssertTrue(eventually(within: 10) { !reader.isCurrentlyPlaying }, "The book never ended")
        XCTAssertFalse(reader.isWaitingOutChapterPause, "A pause followed the last track")
    }

    /// A book without a manifest, and one whose manifest gives a pause of 0,
    /// play straight on from track to track as every book always has: the
    /// next track's file is queued behind the one playing.
    func testWithoutAManifestOrWithAPauseOfZeroTracksPlayStraightOn() throws {
        let world = try makeIntegrationWorld("Chapter Pause None")
        for manifest in [nil, #"{"pauseBetweenTracksMs": 0}"#] {
            let reader = try openBook(in: world, title: "Ferry Log", trackDurations: [3, 3], manifest: manifest)
            let service = reader.audioPlaybackService
            let files = reader.audioChapterFiles.map(resolvedPath)

            XCTAssertEqual(reader.pauseAfterChapter(0), 0, String(describing: manifest))
            reader.play()
            XCTAssertEqual(service.queuedFilePaths, files, "The next track was not queued: \(String(describing: manifest))")
            reader.stop()
        }
    }

    /// A track's own pause takes the place of the book's, a pause of 0
    /// included, which plays straight on; with no pause of its own a track
    /// takes the book's; a manifest giving none at all, of either kind,
    /// gives a quarter of a second. The pauses come from the manifest at
    /// every load, the same whether the book loads from its saved index or
    /// is read afresh.
    func testATracksOwnPauseOrTheBooksOrTheDefaultFollowsIt() throws {
        let world = try makeIntegrationWorld("Chapter Pause Each")
        let reader = try openBook(
            in: world,
            title: "Harbor Plays",
            trackDurations: [3, 0.5, 0.5],
            manifest: #"{"pauseBetweenTracksMs": 300, "tracks": [{"file": "01.wav", "pauseAfterMs": 0}, "02.wav", "03.wav"]}"#
        )
        defer { reader.stop() }
        XCTAssertEqual([0, 1, 2].map(reader.pauseAfterChapter), [0, 0.3, 0])
        reader.play()
        XCTAssertEqual(
            reader.audioPlaybackService.queuedFilePaths,
            reader.audioChapterFiles.prefix(2).map(resolvedPath),
            "A track whose own pause is 0 did not play straight on"
        )

        let defaulted = try openBook(in: world, title: "Ferry Log", trackDurations: [0.5, 0.5], manifest: #"{"title": "Ferry Log"}"#)
        XCTAssertEqual([0, 1].map(defaulted.pauseAfterChapter), [0.25, 0])
        let saved = try BookContentAnalysisService.load(book: defaulted.book)
        let afresh = try BookContentAnalysisService.analyzeAudio(book: defaulted.book, url: defaulted.book.bookFileURL)
        XCTAssertTrue(saved.usedPersistedIndex)
        XCTAssertEqual(
            ChapterPauses.betweenTracks(of: saved.index, inAudioFolder: defaulted.book.bookFileURL),
            ChapterPauses.betweenTracks(of: afresh.index, inAudioFolder: defaulted.book.bookFileURL)
        )
    }

    // MARK: - Playing Still

    /// Play during the pause leaves it as it is: the next track starts once,
    /// when the pause has passed.
    func testPlayDuringThePauseLeavesItWaiting() throws {
        let world = try makeIntegrationWorld("Chapter Pause Play")
        let reader = try openBook(in: world, title: "Harbor Plays", trackDurations: [0.4, 3], manifest: Self.pausing)
        let service = reader.audioPlaybackService
        defer { reader.stop() }
        try playIntoThePause(reader)
        let generation = reader.chapterPlaybackGeneration

        reader.playOrResume()
        reader.playUnlessUnderWay()

        XCTAssertTrue(reader.isWaitingOutChapterPause, "Play ended the pause")
        XCTAssertFalse(service.isPlaying, "Play started the next track at once")
        XCTAssertTrue(eventually(within: 5) { service.isPlaying }, "The next track never started")
        XCTAssertEqual(reader.chapterPlaybackGeneration, generation + 1, "The next track did not start exactly once")
    }

    /// Play/Pause during the pause pauses the book at the start of the next
    /// track, with the pause sound; nothing starts when the pause would have
    /// passed, and Play/Pause again plays the next track from its start.
    func testPausingDuringThePauseRestsAtTheNextTrackAndPlayStartsIt() throws {
        let world = try makeIntegrationWorld("Chapter Pause Paused")
        let reader = try openBook(in: world, title: "Harbor Plays", trackDurations: [0.4, 3], manifest: Self.pausing)
        let service = reader.audioPlaybackService
        let files = reader.audioChapterFiles.map(resolvedPath)
        _ = try XCTUnwrap(files[safe: 1], "the book has fewer than two chapter files")
        let sounds = try XCTUnwrap(reader.soundEffectService as? RecordedSoundEffects)
        defer { reader.stop() }
        try playIntoThePause(reader)

        reader.togglePlayPause()

        XCTAssertFalse(reader.isWaitingOutChapterPause)
        XCTAssertFalse(reader.isPlaybackUnderWay)
        XCTAssertTrue(reader.isCurrentlyPaused, "The book does not show paused")
        XCTAssertEqual(sounds.played.last, .pause)
        XCTAssertFalse(eventually(within: Self.pastThePause) { service.isPlaying }, "The next track started after a pause")
        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(reader.currentCharacterOffset, 0)

        reader.togglePlayPause()

        XCTAssertTrue(service.isPlaying, "Play did not start the next track")
        XCTAssertEqual(service.loadedURL.map { resolvedPath($0.path) }, files[1])
        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertFalse(reader.isCurrentlyPaused)
    }

    // MARK: - Cancelled

    /// A stop during the pause, as Release Media Controls makes, and closing
    /// the reader, which stops it, leave nothing to start.
    func testStoppingOrClosingDuringThePauseStartsNothing() throws {
        let world = try makeIntegrationWorld("Chapter Pause Stop")
        for closing in [false, true] {
            let reader = try openBook(in: world, title: "Harbor Plays", trackDurations: [0.4, 3], manifest: Self.pausing)
            let service = reader.audioPlaybackService
            try playIntoThePause(reader)

            if closing {
                reader.close()
            } else {
                reader.stop()
            }

            XCTAssertFalse(reader.isWaitingOutChapterPause, "closing: \(closing)")
            XCTAssertFalse(reader.isCurrentlyPlaying, "closing: \(closing)")
            XCTAssertFalse(eventually(within: Self.pastThePause) { service.isPlaying }, "The next track started after the reader stopped; closing: \(closing)")
            reader.stop()
        }
    }

    /// This reader's sleep timer running out during the pause pauses the
    /// book, as anywhere: the next track never starts.
    func testASleepTimerRunningOutDuringThePauseStartsNothing() throws {
        preserveSleepTimers()
        let world = try makeIntegrationWorld("Chapter Pause Timer")
        world.settings.sleepFadeOutDuration = 0
        let reader = try openBook(in: world, title: "Harbor Plays", trackDurations: [0.4, 3], manifest: Self.pausing)
        let service = reader.audioPlaybackService
        defer { reader.stop() }
        reader.startSleepTimer(duration: .minutes(30))
        try playIntoThePause(reader)

        // The timer is the reader's window's.
        reader.sleepTimerService._expireForTesting()

        XCTAssertFalse(reader.isWaitingOutChapterPause)
        XCTAssertTrue(reader.isCurrentlyPaused)
        XCTAssertEqual(reader.lastAnnouncement, ReaderViewModel.sleepTimerExpiredAnnouncement)
        XCTAssertFalse(eventually(within: Self.pastThePause) { service.isPlaying }, "The next track started after the timer ran out")
    }

    /// Any start of playback during the pause starts the chapter now, and
    /// the pause's own start is cancelled: the chapter starts once.
    func testAStartDuringThePauseStartsTheTrackOnce() throws {
        let world = try makeIntegrationWorld("Chapter Pause Start")
        let reader = try openBook(in: world, title: "Harbor Plays", trackDurations: [0.4, 3], manifest: Self.pausing)
        let service = reader.audioPlaybackService
        let files = reader.audioChapterFiles.map(resolvedPath)
        _ = try XCTUnwrap(files[safe: 1], "the book has fewer than two chapter files")
        defer { reader.stop() }
        try playIntoThePause(reader)

        reader.restartPlaybackAtCursor()
        let generation = reader.chapterPlaybackGeneration

        XCTAssertTrue(service.isPlaying, "The start did not play the next track")
        XCTAssertFalse(reader.isWaitingOutChapterPause, "The pause's own start is still waiting")
        spinMainRunLoop(for: Self.pastThePause)
        XCTAssertEqual(reader.chapterPlaybackGeneration, generation, "The next track started a second time")
        XCTAssertEqual(service.loadedURL.map { resolvedPath($0.path) }, files[1])
    }

    // MARK: - Moving During the Pause

    /// A jump during the pause moves the cursor and starts nothing; the
    /// start, once the pause has passed, plays from where the jump went: in
    /// another track, or later in the one waiting.
    func testAJumpDuringThePausePlaysFromWhereItWent() throws {
        let world = try makeIntegrationWorld("Chapter Pause Jump")
        for (chapter, offset) in [(2, 5), (1, 7)] {
            let reader = try openBook(in: world, title: "Harbor Plays", trackDurations: [0.4, 3, 3], manifest: Self.pausing)
            let service = reader.audioPlaybackService
            let files = reader.audioChapterFiles.map(resolvedPath)
            _ = try XCTUnwrap(files[safe: chapter], "the book has no chapter file for the jump")
            try playIntoThePause(reader)

            reader.navigateTo(chapterIndex: chapter, characterOffset: offset)

            XCTAssertEqual(reader.currentChapterIndex, chapter)
            XCTAssertEqual(reader.currentCharacterOffset, offset)
            XCTAssertFalse(service.isPlaying, "The jump started playback: \(chapter):\(offset)")
            XCTAssertTrue(reader.isWaitingOutChapterPause, "The jump ended the pause: \(chapter):\(offset)")
            XCTAssertTrue(eventually(within: 5) { service.isPlaying }, "Nothing started after the pause: \(chapter):\(offset)")
            XCTAssertEqual(service.loadedURL.map { resolvedPath($0.path) }, files[chapter])
            XCTAssertEqual(reader.currentChapterIndex, chapter)
            XCTAssertGreaterThanOrEqual(service.currentTime, Double(offset) / 10 - 0.01, "It did not play from where the jump went")
            XCTAssertLessThan(service.currentTime, Double(offset) / 10 + 1, "It did not play from where the jump went")
            reader.stop()
        }
    }

    /// Where Am I? asked during the pause pauses nothing, since nothing
    /// plays; a pause that ends while it speaks holds the next track, the
    /// book still playing, until the announcement has ended, and the track
    /// then plays.
    func testThePauseEndingDuringWhereAmIHoldsTheTrackForItsEnd() throws {
        let world = try makeIntegrationWorld("Chapter Pause Where Am I")
        let reader = try openBook(in: world, title: "Harbor Plays", trackDurations: [0.4, 3], manifest: Self.pausing)
        let service = reader.audioPlaybackService
        let files = reader.audioChapterFiles.map(resolvedPath)
        _ = try XCTUnwrap(files[safe: 1], "the book has fewer than two chapter files")
        reader._whereAmIUtteranceRecorderForTesting = { _ in }
        let endSound = WhereAmIEndSoundClock(holdingFor: reader)
        defer { reader.stop() }
        try playIntoThePause(reader)

        reader.whereAmI()

        XCTAssertTrue(reader.isWhereAmISpeaking)
        XCTAssertTrue(eventually(within: 5) { reader.isChapterHeldByWhereAmI }, "The pause's end did not hold the track")
        XCTAssertFalse(service.isPlaying, "The track played over the announcement")
        XCTAssertTrue(reader.isPlaybackUnderWay)

        reader.whereAmIAnnouncementFinished()
        endSound.passEndSound()

        XCTAssertTrue(service.isPlaying, "The track did not play as the announcement ended")
        XCTAssertEqual(service.loadedURL.map { resolvedPath($0.path) }, files[1])
    }

    /// The same where the pause ends while the announcement's end sound
    /// plays, which is no longer the announcement speaking: the track is
    /// held as well, the book still playing, and plays once the end sound
    /// has had its moment (REV18a, item 7).
    func testThePauseEndingDuringWhereAmIsEndSoundHoldsTheTrackForIt() throws {
        let world = try makeIntegrationWorld("Chapter Pause End Sound")
        let reader = try openBook(in: world, title: "Harbor Plays", trackDurations: [0.4, 3], manifest: Self.pausing)
        let service = reader.audioPlaybackService
        let files = reader.audioChapterFiles.map(resolvedPath)
        let secondFile = try XCTUnwrap(files[safe: 1], "the book has fewer than two chapter files")
        reader._whereAmIUtteranceRecorderForTesting = { _ in }
        let endSound = WhereAmIEndSoundClock(holdingFor: reader)
        defer { reader.stop() }
        try playIntoThePause(reader)

        // The announcement ends by itself while the pause still runs; its end
        // sound plays until the test lets it pass.
        reader.whereAmI()
        reader.whereAmIAnnouncementFinished()
        XCTAssertFalse(reader.isWhereAmISpeaking)
        XCTAssertTrue(reader.isWhereAmIEndSoundPlaying)

        XCTAssertTrue(eventually(within: 5) { reader.isChapterHeldByWhereAmI }, "The pause's end did not hold the track")
        XCTAssertFalse(service.isPlaying, "The track played over the end sound")
        XCTAssertTrue(reader.isPlaybackUnderWay)

        endSound.passEndSound()

        XCTAssertFalse(reader.isChapterHeldByWhereAmI)
        XCTAssertTrue(service.isPlaying, "The track did not play once the end sound had passed")
        XCTAssertEqual(service.loadedURL.map { resolvedPath($0.path) }, secondFile)
    }

    // MARK: - Helpers

    /// A reader of a new book of silent tracks lasting `trackDurations`
    /// seconds, with `manifest` beside them, loaded, its sound effects
    /// recorded rather than played.
    private func openBook(
        in world: IntegrationWorld,
        title: String,
        trackDurations: [TimeInterval],
        manifest: String?
    ) throws -> ReaderViewModel {
        let book = try world.makeSilentAudioBook(title: title, trackDurations: trackDurations, manifest: manifest)
        let reader = world.openReader(for: book)
        reader.soundEffectService = RecordedSoundEffects()
        waitForReaderToLoad(reader)
        return reader
    }

    /// Plays `reader` from its first track, and waits until that track has
    /// ended and the reader waits out the pause after it.
    ///
    /// - Throws: `PauseNeverBegan`, after failing the test, when it never
    ///   does, so the test stops there.
    private func playIntoThePause(_ reader: ReaderViewModel, file: StaticString = #filePath, line: UInt = #line) throws {
        reader.play()
        guard eventually(within: 10, { reader.isWaitingOutChapterPause }) else {
            XCTFail("The pause after the first track never began", file: file, line: line)
            throw PauseNeverBegan()
        }
    }
}

/// Thrown by a test whose reader never began the pause it was to act in.
private struct PauseNeverBegan: Error {}

/// When the pause between a reader's first two tracks began, the moment
/// its cursor moved to the second, and how long it lasted: until its audio
/// service played again.
@MainActor
private final class Moments {
    /// When the cursor moved to the second track.
    private var pauseBegan: Date?
    /// When the audio service played again afterwards.
    private var playedAgain: Date?
    /// Keeps the subscriptions alive.
    private var subscriptions: Set<AnyCancellable> = []

    /// Starts watching `reader`.
    init(of reader: ReaderViewModel) {
        reader.$currentChapterIndex.sink { [weak self] chapter in
            guard let self, chapter == 1, self.pauseBegan == nil else { return }
            self.pauseBegan = Date()
        }.store(in: &subscriptions)
        reader.audioPlaybackService.$isPlaying.sink { [weak self] playing in
            guard let self, playing, self.pauseBegan != nil, self.playedAgain == nil else { return }
            self.playedAgain = Date()
        }.store(in: &subscriptions)
    }

    /// The seconds from the pause's beginning to the next play, once both
    /// are known.
    var pause: TimeInterval? {
        guard let pauseBegan, let playedAgain else { return nil }
        return playedAgain.timeIntervalSince(pauseBegan)
    }
}
