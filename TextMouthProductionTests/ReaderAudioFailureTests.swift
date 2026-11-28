import Combine
import XCTest
@testable import TextMouth

/// How a reader responds when a chapter's audio cannot be played: it stops
/// exactly as Stop stops it, names the chapter and the file, says what to
/// do, speaks that once, and plays the chapter again from the same place on
/// Retry. It never advances past the failed chapter or ends the book.
///
/// Each book is a package of silent tracks written for the test and indexed
/// as an import indexes it; a track is then deleted or damaged, so the
/// reader opens an index that still lists it. Every announcement is
/// recorded, so VoiceOver on the machine running the suite speaks none.
@MainActor
final class ReaderAudioFailureTests: XCTestCase {
    /// Where every fixture reader opens: the second chapter, half a second
    /// in (ten characters stand for one second of audio).
    private static let openingPosition = ReadingPosition(chapterIndex: 1, characterOffset: 5)

    /// What the reader says about the fixture's missing second track.
    private static let missingTrackMessage = "Chapter 2 could not be played: the file 02.wav is "
        + "missing from the book's package. Re-import the book to restore it."

    // MARK: - A missing track

    /// Play on a track deleted after indexing stops the reader as Stop
    /// would, and says once which chapter and file failed and what to do.
    func testMissingTrackStopsTheReaderAndSaysWhatToDo() throws {
        try withAudioBook(damage: Self.deleteSecondTrack) { reader, _ in
            // A cursor moved without saving shows the failure saves it.
            reader.currentCharacterOffset = 7
            // A Where Am I announcement that paused playback must not try to
            // resume it once it ends.
            reader.wasPlayingBeforeWhereAmI = true

            let recorder = recordingAnnouncements { reader.play() }

            assertStoppedAfterFailure(reader, message: Self.missingTrackMessage, reason: .fileMissing)
            XCTAssertEqual(recorder.announcements.map(\.message), [Self.missingTrackMessage])
            XCTAssertEqual(reader.currentCharacterOffset, 7)
            XCTAssertNotNil(reader.book.lastPlaybackStopped)
            XCTAssertFalse(reader.wasPlayingBeforeWhereAmI)
            // Nothing arriving later starts playback or moves on.
            spinMainRunLoop(for: 0.3)
            assertStoppedAfterFailure(reader, message: Self.missingTrackMessage, reason: .fileMissing)
            XCTAssertEqual(reader.currentCharacterOffset, 7)
        }
    }

    /// Once the track is back, Retry plays the chapter from where it failed
    /// and claims the listening session and Now Playing again.
    func testRetryAfterRestoringTheTrackPlaysFromTheSamePlace() throws {
        try withAudioBook(damage: Self.deleteSecondTrack) { reader, tracks in
            recordingAnnouncements { reader.play() }
            try AudioTestFixtures.writeSilence(to: tracks[1])

            let recorder = recordingAnnouncements { reader.retryAudioPlayback() }

            XCTAssertTrue(reader.isCurrentlyPlaying)
            XCTAssertFalse(reader.isCurrentlyPaused)
            XCTAssertTrue(reader.audioPlaybackService.isPlaying)
            XCTAssertEqual(reader.audioPlaybackService.loadedURL?.lastPathComponent, "02.wav")
            // Half a second in, where the chapter failed.
            XCTAssertEqual(reader.audioPlaybackService.currentTime, 0.5, accuracy: 0.001)
            XCTAssertEqual(reader.currentChapterIndex, 1)
            XCTAssertNil(reader.errorMessage)
            XCTAssertNil(reader.audioPlaybackFailure)
            XCTAssertTrue(ReadingStatsService.shared.hasActiveSession)
            XCTAssertEqual(NowPlayingService.shared.playingOwnerID, reader.nowPlayingService.ownerID)
            XCTAssertEqual(recorder.announcements, [])
        }
    }

    /// Retry while the track is still missing fails the same way, and says
    /// so again.
    func testRetryWhileTheTrackIsStillMissingSaysSoAgain() throws {
        try withAudioBook(damage: Self.deleteSecondTrack) { reader, _ in
            let recorder = recordingAnnouncements {
                reader.play()
                reader.retryAudioPlayback()
            }

            assertStoppedAfterFailure(reader, message: Self.missingTrackMessage, reason: .fileMissing)
            XCTAssertEqual(
                recorder.announcements.map(\.message),
                [Self.missingTrackMessage, Self.missingTrackMessage]
            )
        }
    }

    /// Playing again any other way, such as with the Play key, also settles
    /// the failure, so its alert does not linger over playing audio.
    func testPlayingAgainAnyOtherWayClearsTheFailure() throws {
        try withAudioBook(damage: Self.deleteSecondTrack) { reader, tracks in
            recordingAnnouncements { reader.play() }
            try AudioTestFixtures.writeSilence(to: tracks[1])

            recordingAnnouncements { reader.togglePlayPause() }

            XCTAssertTrue(reader.isCurrentlyPlaying)
            XCTAssertNil(reader.errorMessage)
            XCTAssertNil(reader.audioPlaybackFailure)
        }
    }

    /// Resuming after an audio route change reloads the chapter. A track
    /// deleted while paused fails there, and the reader stops just as Play
    /// stops it.
    func testResumeThatReloadsAMissingTrackStopsTheReader() throws {
        try withAudioBook(trackDuration: 5, damage: { _ in }) { reader, tracks in
            recordingAnnouncements {
                reader.play()
                reader.pause()
            }
            XCTAssertTrue(reader.isCurrentlyPaused)
            reader.invalidatePlaybackBackendForAudioRouteChange()
            try FileManager.default.removeItem(at: tracks[1])

            let recorder = recordingAnnouncements { reader.playOrResume() }

            assertStoppedAfterFailure(reader, message: Self.missingTrackMessage, reason: .fileMissing)
            XCTAssertEqual(recorder.announcements.map(\.message), [Self.missingTrackMessage])
        }
    }

    // MARK: - Failures while playing

    /// A chapter that finishes into a missing next track stops at that
    /// track, at its start, rather than skipping ahead to the one after.
    func testFinishingIntoAMissingTrackStopsThereWithoutSkippingAhead() throws {
        let start = ReadingPosition(chapterIndex: 0, characterOffset: 0)
        try withAudioBook(trackDuration: 0.3, at: start, damage: Self.deleteSecondTrack) { reader, _ in
            let failed = expectFailure(of: reader)

            let recorder = recordingAnnouncements {
                reader.play()
                wait(for: [failed], timeout: 10)
                spinMainRunLoop(for: 0.3)
            }

            assertStoppedAfterFailure(reader, message: Self.missingTrackMessage, reason: .fileMissing)
            XCTAssertEqual(reader.currentCharacterOffset, 0)
            XCTAssertEqual(recorder.announcements.map(\.message), [Self.missingTrackMessage])
        }
    }

    /// A damaged track fails only once AVFoundation tries to open it, after
    /// the reader started playing; it then stops just as for a missing one.
    func testDamagedTrackStopsTheReaderOnceItFails() throws {
        try withAudioBook(damage: Self.damageSecondTrack) { reader, _ in
            let failed = expectFailure(of: reader)

            let recorder = try recordingAnnouncements {
                reader.play()
                XCTAssertTrue(reader.isCurrentlyPlaying, "Play was not claimed before the failure")
                wait(for: [failed], timeout: 10)
                // A second signal for the same file, if any, is not reported.
                spinMainRunLoop(for: 0.3)
                _ = try XCTUnwrap(reader.errorMessage)
            }

            let message = "Chapter 2 could not be played: the file 02.wav is damaged, "
                + "unreadable, or not an audio file. Re-import the book to replace it."
            assertStoppedAfterFailure(reader, message: message, reason: .fileUnreadable)
            XCTAssertEqual(recorder.announcements.map(\.message), [message])
            XCTAssertEqual(reader.currentCharacterOffset, Self.openingPosition.characterOffset)
        }
    }

    /// A failure in the last chapter neither loops back to the start nor
    /// finishes the book, even when the book is set to loop.
    func testFailedLastChapterNeitherLoopsNorFinishesTheBook() throws {
        try withAudioBook(trackCount: 2, endOfBook: .loop, damage: Self.damageSecondTrack) { reader, _ in
            let failed = expectFailure(of: reader)

            let recorder = recordingAnnouncements {
                reader.play()
                wait(for: [failed], timeout: 10)
                spinMainRunLoop(for: 0.3)
            }

            XCTAssertEqual(reader.currentChapterIndex, 1)
            XCTAssertFalse(reader.isCurrentlyPlaying)
            XCTAssertFalse(reader.audioPlaybackService.isPlaying)
            XCTAssertEqual(recorder.announcements.count, 1)
            XCTAssertEqual(reader.lastAnnouncement, reader.errorMessage)
            XCTAssertEqual(ReadingStatsService.shared.stats.finishedBooks.map(\.bookID), [])
        }
    }

    /// A chapter whose audio stops arriving, and does not recover, stops
    /// the reader with a message about the disk it is read from.
    func testStalledChapterStopsTheReader() throws {
        try withAudioBook(trackDuration: 5, damage: { _ in }) { reader, _ in
            let playback = reader.audioPlaybackService
            playback.stallRecoveryTimeout = 1
            let failed = expectFailure(of: reader)

            let recorder = try recordingAnnouncements {
                reader.play()
                waitUntilReady(try XCTUnwrap(playback._playerItemForTesting))
                // Stall the player the way a stall does, without telling the
                // service, and let the recovery time run out.
                playback._pausePlayerForTesting()
                wait(for: [failed], timeout: 10)
            }

            let message = "Chapter 2 could not be played: the file 02.wav could not be read "
                + "quickly enough. Check that the disk holding your library is connected, then choose Retry."
            assertStoppedAfterFailure(reader, message: message, reason: .stalled)
            XCTAssertEqual(recorder.announcements.map(\.message), [message])
        }
    }

    // MARK: - Sleep timer

    /// The sleep timer's countdown halts while a failure leaves nothing
    /// playing, and runs again once the chapter plays.
    func testFailureHaltsTheSleepTimerCountdownUntilPlayingAgain() throws {
        // Stops every window's timer when the test ends, and puts back the
        // duration last used, the one preference every window's timer shares.
        preserveSleepTimers()
        try withAudioBook(damage: Self.deleteSecondTrack) { reader, tracks in
            // The timer of the reader's window.
            let timer = reader.sleepTimerService
            reader.startSleepTimer(duration: .minutes(1))
            let remainingAtFailure = timer.remainingSeconds

            recordingAnnouncements {
                reader.play()
                spinMainRunLoop(for: 1.5)
            }
            XCTAssertTrue(timer.isActive)
            XCTAssertEqual(timer.remainingSeconds, remainingAtFailure)

            try AudioTestFixtures.writeSilence(to: tracks[1])
            recordingAnnouncements {
                reader.retryAudioPlayback()
                spinMainRunLoop(for: 1.5)
            }
            XCTAssertLessThan(timer.remainingSeconds, remainingAtFailure)
        }
    }

    // MARK: - Presenting the failure

    /// A playback failure is shown as an alert offering Retry over the
    /// loaded reader, never in place of it as a book that failed to load
    /// is. Closing the alert forgets the failure and leaves the reader
    /// stopped.
    func testFailureIsShownAsAnAlertOfferingRetry() throws {
        try withAudioBook(damage: Self.deleteSecondTrack) { reader, _ in
            recordingAnnouncements { reader.play() }

            XCTAssertNil(reader.loadErrorMessage)
            XCTAssertEqual(reader.errorAlert, ReaderViewModel.ErrorAlert(
                title: "Playback Problem",
                message: Self.missingTrackMessage,
                offersRetry: true
            ))

            reader.dismissErrorAlert()

            XCTAssertNil(reader.errorAlert)
            XCTAssertNil(reader.errorMessage)
            XCTAssertNil(reader.audioPlaybackFailure)
            XCTAssertFalse(reader.isCurrentlyPlaying)
        }
    }

    /// Any other error over a loaded reader, such as metadata that could
    /// not be saved, is a plain alert without Retry.
    func testOtherErrorsOverTheReaderAreShownWithoutRetry() throws {
        try withAudioBook(damage: { _ in }) { reader, _ in
            reader.errorMessage = "The metadata could not be saved."

            XCTAssertNil(reader.loadErrorMessage)
            XCTAssertEqual(reader.errorAlert, ReaderViewModel.ErrorAlert(
                title: "Error",
                message: "The metadata could not be saved.",
                offersRetry: false
            ))
        }
    }

    /// A book that cannot be opened still shows its error in place of the
    /// reader, with no alert over it.
    func testBookThatFailsToLoadShowsItsErrorInPlaceOfTheReader() throws {
        let book = Book(
            title: "Vanished",
            format: .txt,
            filePath: "/tmp/\(UUID().uuidString)-vanished.txt",
            md5Hash: UUID().uuidString
        )
        let library = LibraryViewModel()
        library.library = Library(books: [book])
        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: library,
            settingsViewModel: SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        )
        defer { reader.close() }

        waitUntilLoaded(reader)

        let message = try XCTUnwrap(reader.errorMessage)
        XCTAssertEqual(reader.loadErrorMessage, message)
        XCTAssertNil(reader.errorAlert)
    }

    // MARK: - Wording

    /// Every message names the chapter by its number and the file by its
    /// name, and says what to do about that kind of failure.
    func testFailureMessagesNameTheChapterTheFileAndWhatToDo() {
        let url = URL(fileURLWithPath: "/Library/Book.tmb/Tracks/03.mp3")
        func message(_ reason: AudioPlaybackFailure.Reason, packaged: Bool = true) -> String {
            ReaderViewModel.audioPlaybackFailureMessage(
                for: AudioPlaybackFailure(reason: reason, url: url),
                chapterNumber: 3,
                bookHasPackage: packaged
            )
        }

        XCTAssertEqual(
            message(.fileMissing),
            "Chapter 3 could not be played: the file 03.mp3 is missing from the book's package. "
                + "Re-import the book to restore it."
        )
        // A book from before packages keeps its files elsewhere.
        XCTAssertEqual(
            message(.fileMissing, packaged: false),
            "Chapter 3 could not be played: the file 03.mp3 is missing. Re-import the book to restore it."
        )
        XCTAssertEqual(
            message(.fileUnreadable),
            "Chapter 3 could not be played: the file 03.mp3 is damaged, unreadable, or not an audio file. "
                + "Re-import the book to replace it."
        )
        XCTAssertEqual(
            message(.failedDuringPlayback),
            "Chapter 3 could not be played: the file 03.mp3 failed partway through. "
                + "Choose Retry to try again, or re-import the book if it keeps failing."
        )
        XCTAssertEqual(
            message(.stalled),
            "Chapter 3 could not be played: the file 03.mp3 could not be read quickly enough. "
                + "Check that the disk holding your library is connected, then choose Retry."
        )
    }

    // MARK: - The Debug Log

    /// The failure is an event in the debug log, naming the track by its
    /// path inside the data directory, and is written whether or not
    /// tracing is on; the reader's routine playback lines are trace, written
    /// only while tracing is on (TODO Q07).
    func testFailureIsLoggedAsAnEventAndRoutineLinesAsTrace() throws {
        try XCTSkipIf(
            DiagnosticLog.TraceSwitch.environmentTurnsTracingOn(ProcessInfo.processInfo.environment),
            "TEXTMOUTH_TRACE_LOG turns tracing on for this whole run"
        )
        try withAudioBook(damage: Self.deleteSecondTrack) { reader, tracks in
            let track = DiagnosticLog.loggablePath(tracks[1])
            XCTAssertTrue(track.hasPrefix("Library/"), track)

            setAppTracing(false)
            let quiet = logLines(in: .debug) {
                reader.invalidatePlaybackBackendForAudioRouteChange()
                _ = recordingAnnouncements { reader.play() }
            }
            XCTAssertTrue(
                quiet.contains { $0.contains(": AUDIO_PLAYBACK_FAILED: reason=fileMissing file=\(track) error=") },
                "\(quiet)"
            )
            XCTAssertFalse(quiet.contains { $0.contains("audio route changed") }, "\(quiet)")

            setAppTracing(true)
            let traced = logLines(in: .debug) {
                reader.invalidatePlaybackBackendForAudioRouteChange()
            }
            XCTAssertTrue(
                traced.contains {
                    $0.hasSuffix(": TRACE playback: audio route changed; next resume will cold-start playback backend")
                },
                "\(traced)"
            )
        }
    }

    // MARK: - Checks

    /// Check that `reader` stopped as Stop stops it after its audio failed
    /// for `reason`: nothing playing or paused, `message` shown and spoken
    /// last, no listening session, Now Playing given up, the cursor still in
    /// the failed chapter, and the cursor saved.
    private func assertStoppedAfterFailure(
        _ reader: ReaderViewModel,
        message: String,
        reason: AudioPlaybackFailure.Reason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(reader.isCurrentlyPlaying, "Playing state", file: file, line: line)
        XCTAssertFalse(reader.isCurrentlyPaused, "Paused state", file: file, line: line)
        XCTAssertFalse(reader.audioPlaybackService.isPlaying, "Player playing", file: file, line: line)
        XCTAssertEqual(reader.errorMessage, message, file: file, line: line)
        XCTAssertEqual(reader.lastAnnouncement, message, file: file, line: line)
        XCTAssertEqual(reader.audioPlaybackFailure?.reason, reason, file: file, line: line)
        XCTAssertFalse(
            ReadingStatsService.shared.hasActiveSession, "Open listening session", file: file, line: line
        )
        XCTAssertNotEqual(
            NowPlayingService.shared.playingOwnerID,
            reader.nowPlayingService.ownerID,
            "Now Playing still claimed",
            file: file,
            line: line
        )
        XCTAssertEqual(reader.currentChapterIndex, Self.openingPosition.chapterIndex, "Chapter", file: file, line: line)
        let saved = reader.libraryViewModel.bookByID(reader.book.id)?.readingPosition
        XCTAssertEqual(saved?.chapterIndex, reader.currentChapterIndex, "Saved chapter", file: file, line: line)
        XCTAssertEqual(saved?.characterOffset, reader.currentCharacterOffset, "Saved offset", file: file, line: line)
    }

    // MARK: - Fixture

    /// Delete the second track, as a user or a sync tool might.
    private nonisolated static func deleteSecondTrack(_ tracks: [URL]) throws {
        try FileManager.default.removeItem(at: tracks[1])
    }

    /// Replace the second track with bytes that are not audio, as a damaged
    /// copy would hold.
    private nonisolated static func damageSecondTrack(_ tracks: [URL]) throws {
        try AudioTestFixtures.writeNonAudioBytes(to: tracks[1])
    }

    /// Subscriptions a test keeps until it ends; each test has its own.
    private var subscriptions = Set<AnyCancellable>()

    /// Wait until `reader` has finished loading its book, successfully or
    /// not.
    private func waitUntilLoaded(_ reader: ReaderViewModel) {
        let loaded = expectation(description: "Loading ended")
        reader.$isLoading
            .filter { !$0 }
            .prefix(1)
            .sink { _ in loaded.fulfill() }
            .store(in: &subscriptions)
        wait(for: [loaded], timeout: 10)
    }

    /// An expectation fulfilled when `reader` first shows an error.
    private func expectFailure(of reader: ReaderViewModel) -> XCTestExpectation {
        let failed = expectation(description: "Failure shown")
        reader.$errorMessage
            .compactMap { $0 }
            .prefix(1)
            .sink { _ in failed.fulfill() }
            .store(in: &subscriptions)
        return failed
    }

    /// Run `body` with a reader opened at `position` on an audio book of
    /// `trackCount` silent tracks named "01.wav" onwards.
    ///
    /// The book is indexed as an import indexes it before `damage` changes
    /// its tracks, so the reader loads an index that still lists every
    /// track. Settings live in a private preferences suite, and the shared
    /// listening statistics start empty with no open session and are put
    /// back afterwards, when the reader is also closed and the package
    /// removed.
    ///
    /// - Parameters:
    ///   - trackCount: How many tracks, and so chapters, the book has.
    ///   - trackDuration: Each track's length in seconds.
    ///   - position: Where the reader opens; `openingPosition` unless a
    ///     test needs to start elsewhere.
    ///   - endOfBook: The book's own end-of-book behavior.
    ///   - damage: Changes made to the tracks after indexing.
    ///   - body: The test, given the loaded reader and the tracks' URLs.
    private func withAudioBook(
        trackCount: Int = 3,
        trackDuration: TimeInterval = 1,
        at position: ReadingPosition? = nil,
        endOfBook: EndOfBookBehavior = .stop,
        damage: ([URL]) throws -> Void,
        _ body: (ReaderViewModel, [URL]) throws -> Void
    ) throws {
        let packageName = "\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: "", tmbName: packageName)
        defer { try? FileManager.default.removeItem(at: package) }
        let tracksFolder = package.appendingPathComponent("Tracks", isDirectory: true)
        let tracks = (1...trackCount).map {
            tracksFolder.appendingPathComponent(String(format: "%02d.wav", $0))
        }
        for track in tracks {
            try AudioTestFixtures.writeSilence(to: track, duration: trackDuration)
        }
        var book = Book(
            title: "Unplayable Tracks",
            format: .audio,
            filePath: tracksFolder.path,
            md5Hash: UUID().uuidString,
            readingPosition: position ?? Self.openingPosition,
            tmbDirectoryName: packageName
        )
        book.localEndOfBookBehavior = endOfBook.rawValue
        let analysis = try BookContentAnalysisService.load(book: book)
        try book.saveBookInfoThrowing(contentIndex: analysis.index)
        try damage(tracks)

        let defaults = makeSandboxedPreferences("reader-audio-failures")
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: defaults
        )
        let library = LibraryViewModel()
        library.library = Library(books: [book])

        let statistics = ReadingStatsService.shared
        let savedStatistics = statistics.stats
        statistics.endSession()
        statistics.stats = ReadingStats()
        defer {
            statistics.endSession()
            statistics.stats = savedStatistics
            statistics.save()
        }

        let reader = ReaderViewModel(book: book, libraryViewModel: library, settingsViewModel: settings)
        defer { reader.close() }
        waitUntilLoaded(reader)
        XCTAssertNil(reader.errorMessage, "The book did not load")
        XCTAssertEqual(reader.content?.chapters.count, trackCount)
        XCTAssertEqual(reader.audioChapterFiles.map { URL(fileURLWithPath: $0).lastPathComponent },
                       tracks.map(\.lastPathComponent))

        try body(reader, tracks)
    }
}
