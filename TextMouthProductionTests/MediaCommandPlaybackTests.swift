import AVFoundation
import Combine
import CoreAudio
import XCTest
@testable import TextMouth

/// The system's media commands, from the AirPods, the media keys, or
/// Control Center, end to end through a real reader (report of 2026-10-04:
/// "My AirPods aren't controlling playback of the book").
///
/// Each test joins real readers to a real `NowPlayingService`, made as the
/// app makes its own but without system integrations, and delivers commands
/// exactly as MediaPlayer does: the coordinator accepts each one and
/// MediaPlayer hears the result at once (`acceptRemoteCommand(_:)`), then the
/// main queue runs the command's action, which the test runs in its place.
/// Each test checks what the listener hears (speech resumed where it paused,
/// at full volume; paused; moved back or forward) and what the app tells the
/// system: its Now Playing item, playing or paused but never stopped, which
/// decides where macOS sends the next press, and which reader owns media
/// controls.
///
/// Nothing is ever heard. A text book's chapter is longer than speech ever
/// renders (`SpeechRenderCoordinator.maximumTextLength`), so its speech is
/// always direct, and every direct utterance goes to a recorder in place of
/// the synthesizer; look-ahead renders are held. Audiobooks play silent
/// tracks. Announcements are recorded, not spoken.
@MainActor
final class MediaCommandPlaybackTests: XCTestCase {

    // MARK: - Pause and Play

    /// The AirPods pause speech and play it again from where it paused. The
    /// system is told the book is paused, not stopped, so macOS sends the
    /// next press to TextMouth as Play, and then that it plays again.
    func testPauseThenPlayResumesSpeechWhereItPaused() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Pause")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let speech = quay.reader.speechService

        quay.reader.play()
        reportWordSpoken(by: quay)
        assertSpeaks(quay, from: Self.openingOffset, "Play")
        assertToldSystem(system, that: quay.reader, plays: true, "Play")

        XCTAssertEqual(system.press(.pause), .success)
        handleQueuedCallbacks()
        XCTAssertTrue(speech.isPaused, "Pause did not pause speech")
        XCTAssertTrue(quay.reader.isCurrentlyPaused, "The reader does not show Paused")
        assertToldSystem(system, that: quay.reader, plays: false, "Pause")

        XCTAssertEqual(system.press(.play), .success)
        handleQueuedCallbacks()
        assertSpeaks(quay, from: Self.openingOffset, "Play after Pause")
        XCTAssertFalse(quay.reader.isCurrentlyPaused, "The reader still shows Paused")
        assertToldSystem(system, that: quay.reader, plays: true, "Play after Pause")
    }

    /// The pause sound says that something paused, so it is made only when
    /// a pause pauses something: a Pause from the AirPods that reaches the
    /// book before it ever played, or once it is paused already, makes no
    /// sound, while the Pause that pauses it as it plays makes the sound
    /// once. Before, every pause made it. The sounds are recorded, never
    /// heard.
    func testThePauseSoundIsMadeOnlyWhenAPausePausesSomething() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Pause Sound")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let sounds = RecordedSoundEffects(preferences: makeSandboxedPreferences("Media Commands Pause Sound"))
        quay.reader.soundEffectService = sounds

        XCTAssertEqual(system.press(.pause), .success)
        XCTAssertEqual(sounds.played, [], "A Pause before the book ever played made a sound")

        quay.reader.play()
        reportWordSpoken(by: quay)
        XCTAssertEqual(system.press(.pause), .success)
        XCTAssertTrue(quay.reader.speechService.isPaused, "Pause did not pause speech")
        XCTAssertEqual(system.press(.pause), .success)
        XCTAssertEqual(sounds.played, [.play, .pause], "The pause sound was not made exactly once, as the book paused")
    }

    /// A Pause that pauses nothing tells the system nothing unless the book
    /// holds the media controls: one reaching a book that never played, or
    /// one that released the controls, leaves the system as it was, so the
    /// AirPods stay with the app they are with, and the book does not take
    /// the controls. Before, each told the system the stopped book was
    /// paused, which took them. A Pause reaching the book that holds them,
    /// paused already, shows it paused again, as before.
    func testAPauseThatPausesNothingLeavesTheSystemAlone() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Pause Nothing")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let owner = quay.reader.nowPlayingService.ownerID

        XCTAssertEqual(system.press(.pause), .success)
        XCTAssertEqual(system.told, [], "A Pause before the book ever played told the system it was paused")
        XCTAssertFalse(system.coordinator.holdsMediaControls(ownerID: owner), "A Pause that paused nothing took the controls")

        quay.reader.play()
        reportWordSpoken(by: quay)
        XCTAssertEqual(system.press(.pause), .success)
        XCTAssertEqual(system.press(.pause), .success)
        assertToldSystem(system, that: quay.reader, plays: false, "A second Pause while the book holds the controls")

        recordingAnnouncements {
            quay.reader.releaseMediaControls()
        }
        let toldAtTheRelease = system.told.count
        XCTAssertEqual(system.press(.pause), .success)
        XCTAssertEqual(system.told.count, toldAtTheRelease, "A Pause after Release Media Controls told the system something")
        XCTAssertEqual(system.told.last, .some(nil))
        XCTAssertFalse(system.coordinator.holdsMediaControls(ownerID: owner), "A Pause took back the controls the book released")
    }

    // MARK: - A Pause During Where Am I?

    /// A minutes sleep timer that runs out while Where Am I? speaks ends
    /// the announcement, and the book it paused stays paused, the timer
    /// gone: the announcement's end changes nothing. Before, the timer's
    /// pause found the book paused already, and the announcement's end
    /// resumed it at full volume with no timer left to stop it.
    func testASleepTimerRunningOutDuringWhereAmILeavesTheBookPaused() throws {
        let timer = SleepTimerService.shared
        preserveSleepTimers()
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Timer \(kind)")
            world.settings.sleepFadeOutDuration = 0
            let book = try openPlayingBook(kind, in: world, joining: system)
            book.reader.startSleepTimer(duration: .minutes(15))
            let announcement = try pressWhereAmI(in: book)

            let expiry = recordingAnnouncements {
                timer.remainingSeconds = 1
                timer._advanceCountdownForTesting()
            }

            XCTAssertEqual(expiry.announcements.map(\.message), [ReaderViewModel.sleepTimerExpiredAnnouncement], "\(kind)")
            XCTAssertFalse(timer.isActive, "\(kind): the timer did not run out")
            assertStaysPausedAfterTheAnnouncementEnds(book, announcement, "\(kind): the sleep timer ran out during Where Am I?")
        }
    }

    /// A Pause from the AirPods while Where Am I? speaks ends the
    /// announcement, and the book stays paused when the announcement's end
    /// would have come. Before, the Pause found the book paused already
    /// and changed nothing, and the announcement's end resumed the book.
    func testAPauseFromTheAirPodsDuringWhereAmILeavesTheBookPaused() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Pause \(kind)")
            let book = try openPlayingBook(kind, in: world, joining: system)
            let announcement = try pressWhereAmI(in: book)

            XCTAssertEqual(system.press(.pause), .success, "\(kind)")

            assertStaysPausedAfterTheAnnouncementEnds(book, announcement, "\(kind): a Pause during Where Am I?")
            assertToldSystem(system, that: book.reader, plays: false, "\(kind): a Pause during Where Am I?")
        }
    }

    /// The AirPods leaving while Where Am I? speaks pause the book, which
    /// counts as playing while the announcement holds it paused, so the
    /// announcement ends and the book stays paused. Before, the book counted
    /// as paused, nothing was paused, and once the announcement ended the
    /// book played on through the Mac's speakers.
    func testTheAirPodsLeavingDuringWhereAmILeaveTheBookPaused() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I AirPods \(kind)")
            world.settings.bluetoothMonitoringEnabled = true
            world.settings.bluetoothDisconnectDelay = 2
            let book = try openPlayingBook(kind, in: world, joining: system)
            system.coordinator.refreshPreviousDeviceInfo()
            XCTAssertTrue(system.coordinator.previousDeviceWasBluetooth, "\(kind): the AirPods are not the output")
            let announcement = try pressWhereAmI(in: book)

            system.takeAirPodsOut()

            assertStaysPausedAfterTheAnnouncementEnds(book, announcement, "\(kind): the AirPods left during Where Am I?")
        }
    }

    /// A recording that starts while Where Am I? speaks pauses the book the
    /// announcement holds paused, as it pauses every book playing, so the
    /// microphone never hears the book once the announcement ends.
    func testARecordingStartingDuringWhereAmILeavesTheBookPaused() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Recording \(kind)")
            let book = try openPlayingBook(kind, in: world, joining: system)
            let announcement = try pressWhereAmI(in: book)

            XCTAssertEqual(system.coordinator.pauseEveryPlayingReader(), 1, "\(kind): the book Where Am I? held was not paused")

            assertStaysPausedAfterTheAnnouncementEnds(book, announcement, "\(kind): a recording started during Where Am I?")
        }
    }

    // MARK: - The Output Changing During Where Am I?

    /// The AirPods connecting while Where Am I? speaks over a playing book
    /// change the output under the book the announcement paused, which
    /// marks it to be played afresh, since a paused synthesizer, engine, or
    /// player can stay bound to the output it began on. The announcement
    /// goes on, and as its end sound passes the book plays on afresh from
    /// where it paused, started once more and shown playing: the text book
    /// in direct speech, the voice, never moved to rendered audio. Before,
    /// Where Am I's own resume took up the paused backend, ignoring the mark
    /// (REV13's leftovers).
    func testTheAirPodsConnectingDuringWhereAmIHaveTheBookPlayAfreshAsItEnds() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            system.takeAirPodsOut()
            let world = try makeIntegrationWorld("Where Am I AirPods Connect \(kind)")
            world.settings.bluetoothMonitoringEnabled = true
            world.settings.bluetoothDisconnectDelay = 2
            let book = try openPlayingBook(kind, in: world, joining: system)
            system.coordinator.refreshPreviousDeviceInfo()
            XCTAssertFalse(system.coordinator.previousDeviceWasBluetooth, "\(kind): the AirPods are the output already")
            let place: Place = (book.reader.currentChapterIndex, book.reader.currentCharacterOffset)
            let announcement = try pressWhereAmI(in: book)
            let generation = book.reader.chapterPlaybackGeneration

            system.putAirPodsIn()

            XCTAssertTrue(book.reader.isWhereAmISpeaking, "\(kind): the AirPods connecting ended the announcement")
            XCTAssertTrue(book.isPaused, "\(kind): the AirPods connecting resumed the book")
            XCTAssertTrue(book.reader.restartPlaybackBackendOnNextResume, "\(kind): the book was not marked to be played afresh")
            finishWhereAmIByItself(book, announcement)
            book.endSound.passEndSound()

            XCTAssertTrue(waitUntil(timeout: 5) { book.isPlaying }, "\(kind): the book did not play on as the announcement ended")
            XCTAssertFalse(book.reader.restartPlaybackBackendOnNextResume, "\(kind): the mark was left for the next resume")
            XCTAssertEqual(book.reader.chapterPlaybackGeneration, generation + 1, "\(kind): the book was not played afresh, once")
            assertPlays(book, from: place, "\(kind): the book played afresh as Where Am I? ended")
            if kind == .text {
                XCTAssertTrue(book.reader.speechService.usingDirectMode, "text: speech moved to rendered audio")
            }
            assertToldSystem(system, that: book.reader, plays: true, "\(kind): the book played afresh as Where Am I? ended")
        }
    }

    // MARK: - A Play During Where Am I?

    /// A Play from the AirPods or a media key while Where Am I? speaks does
    /// nothing, as Play in the book's window does: the announcement goes on
    /// with the book paused, and the book plays again as the announcement
    /// ends. Before, the Play resumed the book over the announcement, since
    /// only a book that was stopped was held back during it.
    func testAPlayFromTheAirPodsDuringWhereAmILetsTheAnnouncementFinish() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Play \(kind)")
            let book = try openPlayingBook(kind, in: world, joining: system)
            let announcement = try pressWhereAmI(in: book)

            XCTAssertEqual(system.press(.play), .success, "\(kind)")

            XCTAssertTrue(book.reader.isWhereAmISpeaking, "\(kind): the Play ended the announcement")
            XCTAssertFalse(book.isPlaying, "\(kind): the Play resumed the book over the announcement")
            XCTAssertTrue(book.isPaused, "\(kind): the book is not paused where it was")
            finishWhereAmIByItself(book, announcement)
            book.endSound.passEndSound()
            XCTAssertTrue(book.isPlaying, "\(kind): the book did not play again as the announcement ended")
            assertToldSystem(system, that: book.reader, plays: true, "\(kind): the announcement's end")
        }
    }

    /// A Play from the AirPods while Where Am I? speaks, for a book paused
    /// before the announcement, waits for it: the announcement goes on, and
    /// the book plays from where it paused once the announcement's end
    /// sound has played, as a Play plays it, with the play sound, and is
    /// shown playing. Before, the Play was dropped without a word, and the
    /// book stayed paused (REV11).
    func testAPlayDuringWhereAmIStartsABookPausedBeforeAsItEnds() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Held Play \(kind)")
            let book = try openPlayingBook(kind, in: world, joining: system)
            XCTAssertEqual(system.press(.pause), .success, "\(kind)")
            let sounds = recordSounds(of: book, "Where Am I Held Play \(kind)")
            let announcement = try pressWhereAmI(in: book)

            XCTAssertEqual(system.press(.play), .success, "\(kind)")

            XCTAssertTrue(book.reader.isWhereAmISpeaking, "\(kind): the Play ended the announcement")
            XCTAssertTrue(book.isPaused, "\(kind): the Play started the book over the announcement")
            finishWhereAmIByItself(book, announcement)
            book.endSound.passEndSound()
            XCTAssertTrue(waitUntil(timeout: 5) { book.isPlaying }, "\(kind): the book did not start as the announcement ended")
            XCTAssertEqual(sounds.played, [.whereAmIStart, .whereAmIEnd, .play], "\(kind)")
            assertToldSystem(system, that: book.reader, plays: true, "\(kind): the Play held for Where Am I?")
        }
    }

    /// A Play from the AirPods while Where Am I? speaks, for a book stopped
    /// before the announcement, starts the book from its place once the
    /// announcement's end sound has played.
    func testAPlayDuringWhereAmIStartsAStoppedBookAsItEnds() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Held Play Stopped \(kind)")
            let book = try openPlayingBook(kind, in: world, joining: system)
            book.reader.stop()
            book.reader.whereAmI()
            XCTAssertTrue(book.reader.isWhereAmISpeaking, "\(kind): Where Am I? does not speak")
            let announcement = try XCTUnwrap(book.announcements.utterances.last, "\(kind): no announcement was handed over")

            XCTAssertEqual(system.press(.play), .success, "\(kind)")

            XCTAssertFalse(book.isPlaying, "\(kind): the Play started the book over the announcement")
            book.reader.whereAmIDelegate?.speechSynthesizer(AVSpeechSynthesizer(), didFinish: announcement)
            handleQueuedCallbacks()
            book.endSound.passEndSound()
            XCTAssertTrue(waitUntil(timeout: 5) { book.isPlaying }, "\(kind): the book did not start as the announcement ended")
        }
    }

    /// Where Am I? pressed again while it speaks stops it, and a Play held
    /// for its end starts the book at once, as the announcement's end would
    /// have.
    func testAPlayHeldByWhereAmIStartsAtOnceWhenAPressEndsIt() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Held Play Pressed \(kind)")
            let book = try openPlayingBook(kind, in: world, joining: system)
            XCTAssertEqual(system.press(.pause), .success, "\(kind)")
            _ = try pressWhereAmI(in: book)
            XCTAssertEqual(system.press(.play), .success, "\(kind)")

            book.reader.whereAmI()

            XCTAssertFalse(book.reader.isWhereAmISpeaking, "\(kind): the press did not stop the announcement")
            XCTAssertTrue(waitUntil(timeout: 5) { book.isPlaying }, "\(kind): the held Play did not start the book")
            assertToldSystem(system, that: book.reader, plays: true, "\(kind): the held Play")
        }
    }

    /// A Play held for the end of Where Am I? counts as the book playing,
    /// so whatever pauses a playing book lets it go: a Pause from the
    /// AirPods, Play/Pause, or a recording starting ends the announcement,
    /// the book stays paused as it was, and nothing starts it once the end
    /// sound's moment would have passed.
    func testAPlayHeldByWhereAmIIsLetGoByAPause() throws {
        let pauses: [(name: String, pause: (PlayingBook, MediaSystem) -> Void)] = [
            ("a Pause from the AirPods", { _, system in
                XCTAssertEqual(system.press(.pause), .success)
            }),
            ("Play/Pause", { book, _ in
                book.reader.togglePlayPause()
            }),
            ("a recording starting", { _, system in
                XCTAssertEqual(system.coordinator.pauseEveryPlayingReader(), 1, "the book holding a Play was not paused")
            }),
        ]
        for kind in BookKind.allCases {
            for (name, pause) in pauses {
                let context = "\(kind), \(name)"
                let system = MediaSystem()
                let world = try makeIntegrationWorld("Where Am I Held Play Let Go \(kind) \(name)")
                let book = try openPlayingBook(kind, in: world, joining: system)
                XCTAssertEqual(system.press(.pause), .success, context)
                _ = try pressWhereAmI(in: book)
                XCTAssertEqual(system.press(.play), .success, context)

                pause(book, system)

                XCTAssertFalse(book.reader.isWhereAmIUnderWay, "\(context): Where Am I? still holds the Play")
                book.endSound.passEndSound()
                XCTAssertFalse(book.isPlaying, "\(context): the held Play started the book")
                XCTAssertTrue(book.isPaused, "\(context): the book is not paused where it was")
            }
        }
    }

    /// A Play held for the end of Where Am I?, for a book paused or stopped
    /// before the announcement, survives the system cancelling the
    /// announcement, as the speech engine does with a text it refuses: the
    /// announcement ends without its end sound, and the book starts at once,
    /// as the Play asked, with the play sound, and is shown playing. Before,
    /// the cancel let the held Play go with the announcement, and the book
    /// stayed as it was, the Play dropped without a word (REV12).
    func testAPlayHeldByWhereAmIStartsTheBookWhenTheSystemCancelsTheAnnouncement() throws {
        for kind in BookKind.allCases {
            for (name, leaveNotPlaying) in Self.waysToLeaveABookNotPlaying {
                let context = "\(kind), \(name)"
                let system = MediaSystem()
                let world = try makeIntegrationWorld("Where Am I Held Play Cancelled \(kind) \(name)")
                let book = try openPlayingBook(kind, in: world, joining: system)
                leaveNotPlaying(book, system)
                let sounds = recordSounds(of: book, "Where Am I Held Play Cancelled \(kind) \(name)")
                book.reader.whereAmI()
                let announcement = try XCTUnwrap(book.announcements.utterances.last, "\(context): no announcement was handed over")
                XCTAssertEqual(system.press(.play), .success, context)
                XCTAssertTrue(book.reader.isPlayHeldByWhereAmI, "\(context): the Play was not held for the announcement")

                book.reader.whereAmIDelegate?.speechSynthesizer(AVSpeechSynthesizer(), didCancel: announcement)
                handleQueuedCallbacks()

                XCTAssertFalse(book.reader.isWhereAmIUnderWay, "\(context): Where Am I? still has the book")
                XCTAssertTrue(waitUntil(timeout: 5) { book.isPlaying }, "\(context): the held Play did not start the book")
                XCTAssertEqual(sounds.played, [.whereAmIStart, .play], context)
                XCTAssertFalse(book.endSound.hasWorkWaiting, "\(context): work waits for an end sound")
                let playing = NowPlayingItem(title: book.reader.book.title, author: book.reader.book.author, isPlaying: true)
                XCTAssertEqual(system.told.last, .some(playing), "\(context): the system was not told the book plays")
                XCTAssertEqual(system.coordinator.playingOwnerID, book.reader.nowPlayingService.ownerID, context)
            }
        }
    }

    /// A Play from the AirPods while Where Am I? speaks over the book it
    /// paused, which the announcement's end would have played again, starts
    /// the book when the system cancels the announcement instead, as the
    /// speech engine does with a text it refuses: the announcement ends
    /// without its end sound, and the book plays on from where it paused,
    /// with the play sound, shown playing. Before, the cancel left the book
    /// paused and the Play was dropped without a word (REV13's leftovers).
    /// With no Play, a cancel still leaves the book paused
    /// (`WhereAmIAnnouncementEndTests`), and the end's own resume answers a
    /// Play with no second start (`testAPlayFromTheAirPodsDuringWhereAmILetsTheAnnouncementFinish`).
    func testAPlayDuringWhereAmIStartsTheBookItPausedWhenTheSystemCancelsIt() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Play Then Cancel \(kind)")
            let book = try openPlayingBook(kind, in: world, joining: system)
            let sounds = recordSounds(of: book, "Where Am I Play Then Cancel \(kind)")
            let announcement = try pressWhereAmI(in: book)
            XCTAssertEqual(system.press(.play), .success, "\(kind)")
            XCTAssertTrue(book.isPaused, "\(kind): the Play resumed the book over the announcement")

            book.reader.whereAmIDelegate?.speechSynthesizer(AVSpeechSynthesizer(), didCancel: announcement)
            handleQueuedCallbacks()

            XCTAssertFalse(book.reader.isWhereAmIUnderWay, "\(kind): Where Am I? still has the book")
            XCTAssertTrue(waitUntil(timeout: 5) { book.isPlaying }, "\(kind): the Play did not start the book")
            XCTAssertEqual(sounds.played, [.whereAmIStart, .play], "\(kind)")
            XCTAssertFalse(book.endSound.hasWorkWaiting, "\(kind): work waits for an end sound")
            assertToldSystem(system, that: book.reader, plays: true, "\(kind): a Play during Where Am I?, then a cancel")
        }
    }

    // MARK: - Where Am I? Over a Book That Was Not Playing

    /// Where Am I? over a book paused or stopped before it, ending by
    /// itself, leaves the book as it was: nothing plays once its end sound
    /// has played, and the system is told nothing more. Only a book the
    /// announcement paused as it played, or one a Play during it asked for,
    /// plays as it ends.
    func testWhereAmIOverABookThatWasNotPlayingLeavesItAsItWas() throws {
        for kind in BookKind.allCases {
            for (name, leaveNotPlaying) in Self.waysToLeaveABookNotPlaying {
                let context = "\(kind), \(name)"
                let system = MediaSystem()
                let world = try makeIntegrationWorld("Where Am I Over A Book Not Playing \(kind) \(name)")
                let book = try openPlayingBook(kind, in: world, joining: system)
                leaveNotPlaying(book, system)
                let wasPaused = book.isPaused
                let toldBefore = system.told
                book.reader.whereAmI()
                let announcement = try XCTUnwrap(book.announcements.utterances.last, "\(context): no announcement was handed over")

                book.reader.whereAmIDelegate?.speechSynthesizer(AVSpeechSynthesizer(), didFinish: announcement)
                handleQueuedCallbacks()
                XCTAssertTrue(book.endSound.hasWorkWaiting, "\(context): nothing waits for the end sound")
                book.endSound.passEndSound()

                XCTAssertFalse(book.reader.isWhereAmIUnderWay, "\(context): Where Am I? still has the book")
                XCTAssertFalse(book.isPlaying, "\(context): the announcement's end played the book")
                XCTAssertEqual(book.isPaused, wasPaused, "\(context): the announcement's end changed the book")
                XCTAssertEqual(system.told, toldBefore, "\(context): the system was told more")
            }
        }
    }

    // MARK: - Another Book Started During Where Am I?

    /// Another book started while Where Am I? speaks pauses the book the
    /// announcement holds paused, as it pauses a book that plays: the
    /// announcement ends, the held book stays paused once the
    /// announcement's end would have come, and only the book that started
    /// plays, with the media controls. Before, the held book, which had
    /// told the system it paused, was not paused, and it played again
    /// beside the other as the announcement ended.
    func testABookStartedDuringWhereAmIPausesTheBookTheAnnouncementHolds() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Another Book \(kind)")
            let held = try openPlayingBook(kind, in: world, joining: system)
            let announcement = try pressWhereAmI(in: held)
            let slipway = openTextBook(titled: "Slipway Ledger", in: world, joining: system)

            slipway.reader.play()
            reportWordSpoken(by: slipway)

            XCTAssertEqual(system.exclusivePauses.count, 1, "\(kind): the held book was not paused once: \(system.exclusivePauses)")
            assertStaysPausedAfterTheAnnouncementEnds(held, announcement, "\(kind): another book started during Where Am I?")
            assertSpeaks(slipway, from: Self.openingOffset, "\(kind): the book started during Where Am I?")
            assertToldSystem(system, that: slipway.reader, plays: true, "\(kind): the book started during Where Am I?")
        }
    }

    // MARK: - A Pause as Where Am I? Ends

    /// A minutes sleep timer that runs out in the moment after Where Am I?
    /// ends by itself, before the book it paused resumes as the end sound
    /// has played, takes that resume: the book stays paused, the timer gone.
    /// Before, the timer's pause found the book paused already and paused
    /// nothing, and the book resumed at full volume with no timer left to
    /// stop it (REV11).
    func testASleepTimerRunningOutAsWhereAmIEndsLeavesTheBookPaused() throws {
        let timer = SleepTimerService.shared
        preserveSleepTimers()
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Ends Timer \(kind)")
            world.settings.sleepFadeOutDuration = 0
            let book = try openPlayingBook(kind, in: world, joining: system)
            book.reader.startSleepTimer(duration: .minutes(15))
            finishWhereAmIByItself(book, try pressWhereAmI(in: book))

            let expiry = recordingAnnouncements {
                timer.remainingSeconds = 1
                timer._advanceCountdownForTesting()
            }

            XCTAssertEqual(expiry.announcements.map(\.message), [ReaderViewModel.sleepTimerExpiredAnnouncement], "\(kind)")
            XCTAssertFalse(timer.isActive, "\(kind): the timer did not run out")
            assertStaysPausedAsTheEndSoundPasses(book, "\(kind): the sleep timer ran out as Where Am I? ended")
        }
    }

    /// A Pause from the AirPods in the moment after Where Am I? ends by
    /// itself takes the resume the announcement owed: the book stays paused,
    /// and the system is told so. Before, the Pause found the book paused
    /// already and changed nothing, and the book resumed.
    func testAPauseFromTheAirPodsAsWhereAmIEndsLeavesTheBookPaused() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Ends Pause \(kind)")
            let book = try openPlayingBook(kind, in: world, joining: system)
            finishWhereAmIByItself(book, try pressWhereAmI(in: book))

            XCTAssertEqual(system.press(.pause), .success, "\(kind)")

            assertStaysPausedAsTheEndSoundPasses(book, "\(kind): a Pause as Where Am I? ended")
            assertToldSystem(system, that: book.reader, plays: false, "\(kind): a Pause as Where Am I? ended")
        }
    }

    /// The AirPods leaving in the moment after Where Am I? ends by itself
    /// pause the book, which counts as playing until its resume, so the
    /// book stays paused. Before, it counted as paused, nothing paused it,
    /// and it resumed through the Mac's speakers.
    func testTheAirPodsLeavingAsWhereAmIEndsLeaveTheBookPaused() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Ends AirPods \(kind)")
            world.settings.bluetoothMonitoringEnabled = true
            world.settings.bluetoothDisconnectDelay = 2
            let book = try openPlayingBook(kind, in: world, joining: system)
            system.coordinator.refreshPreviousDeviceInfo()
            XCTAssertTrue(system.coordinator.previousDeviceWasBluetooth, "\(kind): the AirPods are not the output")
            finishWhereAmIByItself(book, try pressWhereAmI(in: book))

            system.takeAirPodsOut()

            assertStaysPausedAsTheEndSoundPasses(book, "\(kind): the AirPods left as Where Am I? ended")
        }
    }

    /// A recording that starts in the moment after Where Am I? ends by
    /// itself pauses the book about to resume, as it pauses every book
    /// playing, so the microphone never hears it.
    func testARecordingStartingAsWhereAmIEndsLeavesTheBookPaused() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Ends Recording \(kind)")
            let book = try openPlayingBook(kind, in: world, joining: system)
            finishWhereAmIByItself(book, try pressWhereAmI(in: book))

            XCTAssertEqual(system.coordinator.pauseEveryPlayingReader(), 1, "\(kind): the book about to resume was not paused")

            assertStaysPausedAsTheEndSoundPasses(book, "\(kind): a recording started as Where Am I? ended")
        }
    }

    /// Another book started in the moment after Where Am I? ends by itself
    /// pauses the book about to resume, as it pauses a book that plays, and
    /// only the book that started plays, with the media controls.
    func testABookStartedAsWhereAmIEndsPausesTheBookAboutToResume() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Ends Another Book \(kind)")
            let held = try openPlayingBook(kind, in: world, joining: system)
            finishWhereAmIByItself(held, try pressWhereAmI(in: held))
            let slipway = openTextBook(titled: "Slipway Ledger", in: world, joining: system)

            slipway.reader.play()
            reportWordSpoken(by: slipway)

            XCTAssertEqual(system.exclusivePauses.count, 1, "\(kind): the book about to resume was not paused once: \(system.exclusivePauses)")
            assertStaysPausedAsTheEndSoundPasses(held, "\(kind): another book started as Where Am I? ended")
            assertSpeaks(slipway, from: Self.openingOffset, "\(kind): the book started as Where Am I? ended")
            assertToldSystem(system, that: slipway.reader, plays: true, "\(kind): the book started as Where Am I? ended")
        }
    }

    /// Play/Pause pressed in the moment after Where Am I? ends by itself
    /// pauses the book that was about to resume, as it would a moment
    /// later, and as it does during the announcement: the book stays
    /// paused, its pause settled, the listening session ended.
    func testPlayPauseAsWhereAmIEndsLeavesTheBookPaused() throws {
        let statistics = ReadingStatsService.shared
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Ends Play Pause \(kind)")
            let book = try openPlayingBook(kind, in: world, joining: system)
            finishWhereAmIByItself(book, try pressWhereAmI(in: book))

            book.reader.togglePlayPause()

            assertStaysPausedAsTheEndSoundPasses(book, "\(kind): Play/Pause as Where Am I? ended")
            XCTAssertFalse(statistics.hasActiveSession, "\(kind): the listening session stayed open")
            assertToldSystem(system, that: book.reader, plays: false, "\(kind): Play/Pause as Where Am I? ended")
        }
    }

    /// A Play from the AirPods in the moment after Where Am I? ends by
    /// itself changes nothing then: the book resumes once, as the end sound
    /// has played, with no play sound, and is shown playing.
    func testAPlayAsWhereAmIEndsLetsTheBookResumeOnce() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Ends Play \(kind)")
            let book = try openPlayingBook(kind, in: world, joining: system)
            let sounds = recordSounds(of: book, "Where Am I Ends Play \(kind)")
            finishWhereAmIByItself(book, try pressWhereAmI(in: book))

            XCTAssertEqual(system.press(.play), .success, "\(kind)")

            XCTAssertFalse(book.isPlaying, "\(kind): the Play resumed the book before the end sound")
            book.endSound.passEndSound()
            XCTAssertTrue(book.isPlaying, "\(kind): the book did not resume as the end sound passed")
            XCTAssertEqual(sounds.played, [.whereAmIStart, .whereAmIEnd], "\(kind)")
            assertToldSystem(system, that: book.reader, plays: true, "\(kind): a Play as Where Am I? ended")
        }
    }

    /// Where Am I? pressed again in the moment after one ends by itself
    /// takes over the resume that one owed: the book stays paused under the
    /// new announcement as the first one's end sound passes, and plays again
    /// as the new one ends. Before, the book counted as not playing, and the
    /// first announcement's resume played it under the second.
    func testWhereAmIPressedAgainAsOneEndsTakesItsResumeOver() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Again As It Ends \(kind)")
            let book = try openPlayingBook(kind, in: world, joining: system)
            finishWhereAmIByItself(book, try pressWhereAmI(in: book))

            let second = try pressWhereAmI(in: book)
            book.endSound.passEndSound()

            XCTAssertTrue(book.reader.isWhereAmISpeaking, "\(kind): the second announcement ended")
            XCTAssertFalse(book.isPlaying, "\(kind): the first announcement's resume played the book under the second")
            finishWhereAmIByItself(book, second)
            book.endSound.passEndSound()
            XCTAssertTrue(book.isPlaying, "\(kind): the book did not play again as the second announcement ended")
            assertToldSystem(system, that: book.reader, plays: true, "\(kind): the second announcement's end")
        }
    }

    /// A skip in the moment after Where Am I? ends by itself resumes the
    /// book at once, as a skip during the announcement does, so it moves the
    /// book playing; the end sound's moment passing changes nothing more.
    func testASkipAsWhereAmIEndsResumesTheBookAtOnce() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Ends Skip \(kind)")
            world.settings.skipForwardUnit = .seconds15
            let book = try openPlayingBook(kind, in: world, joining: system)
            finishWhereAmIByItself(book, try pressWhereAmI(in: book))
            let before = book.reader.currentCharacterOffset

            book.reader.lastSkipTime = .distantPast
            book.reader.skipForward()

            XCTAssertTrue(book.isPlaying, "\(kind): the skip did not resume the book")
            XCTAssertGreaterThan(book.reader.currentCharacterOffset, before, "\(kind): the skip did not move forward")
            XCTAssertFalse(book.reader.isWhereAmIUnderWay, "\(kind): Where Am I? still owes the book its resume")
            book.endSound.passEndSound()
            XCTAssertTrue(book.isPlaying, "\(kind): the end sound's moment paused the book")
            assertToldSystem(system, that: book.reader, plays: true, "\(kind): a skip as Where Am I? ended")
        }
    }

    /// Release Media Controls in the moment after Where Am I? ends by itself
    /// stops the book for good: the resume the announcement owed is
    /// forgotten, and the end sound's moment passing tells the system
    /// nothing, so the AirPods stay released.
    func testReleasingAsWhereAmIEndsKeepsTheControlsReleased() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Ends Release \(kind)")
            let book = try openPlayingBook(kind, in: world, joining: system)
            finishWhereAmIByItself(book, try pressWhereAmI(in: book))
            recordingAnnouncements {
                book.reader.releaseMediaControls()
            }
            let toldAtTheRelease = system.told.count

            book.endSound.passEndSound()

            XCTAssertFalse(book.isPlaying, "\(kind): the book resumed after the release")
            XCTAssertEqual(system.told.count, toldAtTheRelease, "\(kind): the system was told more: \(system.told)")
            XCTAssertEqual(system.told.last, .some(nil), "\(kind)")
            XCTAssertFalse(
                system.coordinator.holdsMediaControls(ownerID: book.reader.nowPlayingService.ownerID),
                "\(kind): the media controls came back"
            )
        }
    }

    // MARK: - A Stop During Where Am I?

    /// Release Media Controls, Shift-R by the user's choice, while Where Am
    /// I? speaks ends the announcement with the book, and the controls stay
    /// released: the announcement's finish, as the synthesizer then reports
    /// it, makes no end sound, resumes nothing, and tells the system nothing,
    /// so the AirPods stay with the app they go to. Before, the announcement
    /// went on, and its end told the system the stopped book played, which
    /// took the AirPods back, and Shift-R then said the book did not hold
    /// them (REV11). A Play from the AirPods takes them back, as after any
    /// release, and Release Media Controls is offered again.
    func testReleaseMediaControlsDuringWhereAmIEndsItAndTheControlsStayReleased() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Release \(kind)")
            let book = try openPlayingBook(kind, in: world, joining: system)
            let sounds = recordSounds(of: book, "Where Am I Release \(kind)")
            let announcement = try pressWhereAmI(in: book)

            let released = recordingAnnouncements {
                book.reader.releaseMediaControls()
            }

            XCTAssertEqual(released.announcements.map(\.message), [MediaControlsWording.released], "\(kind)")
            assertWhereAmIEndedWithTheStop(book, announcement, system: system, sounds: sounds, "\(kind): Release Media Controls")
            XCTAssertFalse(book.reader.canReleaseMediaControls, "\(kind): Release Media Controls is offered with nothing held")

            XCTAssertEqual(system.press(.play), .success, "\(kind)")
            handleQueuedCallbacks()
            XCTAssertTrue(waitUntil(timeout: 5) { book.isPlaying }, "\(kind): Play after the release did not play")
            let playing = NowPlayingItem(title: book.reader.book.title, author: book.reader.book.author, isPlaying: true)
            XCTAssertEqual(system.told.last, .some(playing), "\(kind): Play after the release was not shown")
            XCTAssertTrue(book.reader.canReleaseMediaControls, "\(kind): Release Media Controls is not offered after Play")
        }
    }

    /// Edit Text taken while Where Am I? speaks over a playing book stops
    /// the book to show the edited text, and the announcement ends with it;
    /// the book, which the announcement would have played again as it ended,
    /// plays on in the edited text from its place, with the play sound, as
    /// Edit Text plays on a book that plays. The announcement's finish, as
    /// the synthesizer then reports it, changes nothing more: no end sound,
    /// and nothing left for one. Before, the book stayed stopped (REV12's
    /// leftovers), and before that, the announcement's end told the system
    /// the stopped book played, taking the AirPods.
    func testEditTextDuringWhereAmIEndsItAndTheBookPlaysOn() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Where Am I Edit Text")
        let book = try openPlayingBook(.text, in: world, joining: system)
        let text = try XCTUnwrap(book.text, "the text book's speech is not recorded")
        let sounds = recordSounds(of: book, "Where Am I Edit Text")
        let announcement = try pressWhereAmI(in: book)
        // The reader shows the pause before the edit arrives, as it has long
        // since when an edit is taken.
        handleQueuedCallbacks()
        var edited = Self.ledgerChapter()
        edited.text += " The ledger is closed for the season."

        book.reader.showEditedText(DocumentContent(title: book.reader.book.title, author: book.reader.book.author, chapters: [edited]))

        XCTAssertEqual(book.reader.content?.chapters.first?.text, edited.text, "the edited text is not shown")
        XCTAssertFalse(book.reader.isWhereAmIUnderWay, "Where Am I? still has the book")
        assertSpeaks(text, from: Self.openingOffset, "Edit Text during Where Am I?")

        book.reader.whereAmIDelegate?.speechSynthesizer(AVSpeechSynthesizer(), didFinish: announcement)
        handleQueuedCallbacks()

        XCTAssertEqual(sounds.played, [.whereAmIStart, .play], "the announcement's finish made a sound")
        XCTAssertFalse(book.endSound.hasWorkWaiting, "work waits for the announcement's end sound")
        XCTAssertTrue(book.isPlaying, "the announcement's finish stopped the book")
        let playing = NowPlayingItem(title: book.reader.book.title, author: book.reader.book.author, isPlaying: true)
        XCTAssertEqual(system.told.last, .some(playing), "the system was not told the book plays")
        XCTAssertEqual(system.coordinator.playingOwnerID, book.reader.nowPlayingService.ownerID)
    }

    /// Any stop while Where Am I? speaks, as when the files of the chapter
    /// about to play cannot be downloaded, ends the announcement with the
    /// book: its finish resumes nothing and tells the system nothing.
    func testAStopDuringWhereAmIEndsItWithTheBook() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Stop \(kind)")
            let book = try openPlayingBook(kind, in: world, joining: system)
            let sounds = recordSounds(of: book, "Where Am I Stop \(kind)")
            let announcement = try pressWhereAmI(in: book)

            book.reader.stop()

            assertWhereAmIEndedWithTheStop(book, announcement, system: system, sounds: sounds, "\(kind): a stop")
        }
    }

    /// A skip after Release Media Controls during Where Am I? moves the
    /// stopped book's cursor and takes nothing back. Before, the
    /// announcement still spoke, and the skip, which ends it, told the
    /// system that the book it had paused played again, though it was
    /// stopped, so the AirPods came back.
    func testASkipAfterReleasingDuringWhereAmILeavesTheControlsReleased() throws {
        for kind in BookKind.allCases {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Release Skip \(kind)")
            let book = try openPlayingBook(kind, in: world, joining: system)
            _ = try pressWhereAmI(in: book)
            recordingAnnouncements {
                book.reader.releaseMediaControls()
            }
            let toldAtTheRelease = system.told.count

            book.reader.lastSkipTime = .distantPast
            book.reader.skipForward()

            XCTAssertFalse(book.isPlaying, "\(kind): the skip played the stopped book")
            XCTAssertEqual(system.told.count, toldAtTheRelease, "\(kind): the skip told the system something: \(system.told)")
            XCTAssertFalse(
                system.coordinator.holdsMediaControls(ownerID: book.reader.nowPlayingService.ownerID),
                "\(kind): the skip took the media controls back"
            )
        }
    }

    /// A book whose playback will not resume as Where Am I? ends, by a skip
    /// or by itself, its speech or its player let go while the announcement
    /// held it paused, is not shown playing: the system stays told it is
    /// paused, so the AirPods' next press is Play, and its pause is settled,
    /// the listening session ended. Before, the system was told the book
    /// played whatever the resume did.
    func testABookThatWillNotResumeAfterWhereAmIIsNotShownPlaying() throws {
        let statistics = ReadingStatsService.shared
        let endings: [(name: String, end: (PlayingBook, AVSpeechUtterance) -> Void)] = [
            ("a skip", { book, _ in
                book.reader.lastSkipTime = .distantPast
                book.reader.skipForward()
            }),
            ("its own end", { book, announcement in
                book.reader.whereAmIDelegate?.speechSynthesizer(AVSpeechSynthesizer(), didFinish: announcement)
                self.handleQueuedCallbacks()
                book.endSound.passEndSound()
            }),
        ]
        for kind in BookKind.allCases {
            for ending in endings {
                let context = "\(kind), \(ending.name)"
                let system = MediaSystem()
                let world = try makeIntegrationWorld("Where Am I Resume Refused \(kind) \(ending.name)")
                let book = try openPlayingBook(kind, in: world, joining: system)
                let announcement = try pressWhereAmI(in: book)
                // Let go behind the reader's back, so nothing is left to resume.
                switch kind {
                case .text: book.reader.speechService.stop()
                case .audio: book.reader.audioPlaybackService.stop()
                }
                XCTAssertTrue(statistics.hasActiveSession, "\(context): no listening session is open")

                ending.end(book, announcement)

                XCTAssertFalse(book.reader.isWhereAmIUnderWay, "\(context): Where Am I? did not end")
                XCTAssertFalse(book.isPlaying, context)
                assertToldSystem(system, that: book.reader, plays: false, "\(context): a resume refused")
                XCTAssertFalse(statistics.hasActiveSession, "\(context): the listening session stayed open")
            }
        }
    }

    // MARK: - A Jump During Where Am I?

    /// Next Heading while Where Am I? speaks over a playing book ends the
    /// announcement, and the book plays on from the heading: the text book
    /// from its Tides heading, later in the same chapter, and the audiobook
    /// from its second track's heading, in the next chapter. Before, the
    /// jump found the book paused and stopped its speech, or the
    /// audiobook's player, so the announcement's end had nothing to resume
    /// and the book fell silent (REV12).
    func testNextHeadingDuringWhereAmIPlaysOnFromTheHeading() throws {
        for kind in BookKind.allCases {
            try assertAJumpDuringWhereAmIPlaysOn(kind, from: Self.nextHeadingPlace(kind), "Next Heading") { reader in
                reader.nextHeading()
            }
        }
    }

    /// A bookmark picked from the Bookmarks panel while Where Am I? speaks
    /// over a playing book ends the announcement, and the book plays on
    /// from the bookmark, as after Next Heading.
    func testABookmarkPickedDuringWhereAmIPlaysOnFromIt() throws {
        for kind in BookKind.allCases {
            let place = Self.bookmarkPlace(kind)
            try assertAJumpDuringWhereAmIPlaysOn(kind, from: place, "a bookmark") { reader in
                reader.navigateToBookmark(Bookmark(number: 1, chapterIndex: place.chapter, characterOffset: place.offset))
            }
        }
    }

    /// With Auto-play on navigate, a bookmark picked while Where Am I?
    /// speaks over a book paused before it ends the announcement, and the
    /// play that follows the jump plays the book from the bookmark, with the
    /// play sound, as when nothing is announced. Before, that play only
    /// ended the announcement, and the book stayed paused (REV12).
    func testABookmarkPickedDuringWhereAmIWithAutoPlayPlaysTheBookFromIt() throws {
        for kind in BookKind.allCases {
            let context = "\(kind): Auto-play after a bookmark during Where Am I?"
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Where Am I Bookmark Auto-play \(kind)")
            world.settings.autoPlayOnNavigate = true
            let book = try openPlayingBook(kind, in: world, joining: system, audioTracks: Self.twoTracks)
            XCTAssertEqual(system.press(.pause), .success, context)
            let sounds = recordSounds(of: book, "Where Am I Bookmark Auto-play \(kind)")
            _ = try pressWhereAmI(in: book)
            let place = Self.bookmarkPlace(kind)

            book.reader.navigateToBookmark(Bookmark(number: 1, chapterIndex: place.chapter, characterOffset: place.offset))

            XCTAssertFalse(book.reader.isWhereAmIUnderWay, "\(context): Where Am I? still has the book")
            assertPlays(book, from: place, context)
            XCTAssertEqual(sounds.played, [.whereAmIStart, .play], context)
            assertToldSystem(system, that: book.reader, plays: true, context)
        }
    }

    // MARK: - A Sleep Timer Set During Where Am I?

    /// A sleep timer set to start playback while Where Am I? speaks, as the
    /// sleep timer's sheet, Restart Sleep Timer, and the AirPods' gesture
    /// all set one, starts its countdown and lets the announcement finish,
    /// and the book plays as the announcement ends, as a Play during it
    /// does: the book the announcement paused plays again, and one paused
    /// before it starts. Before, the timer's start went through Play/Pause,
    /// which ended the announcement and left the book paused (REV12's
    /// leftovers).
    func testASleepTimerSetDuringWhereAmIPlaysTheBookAsItEnds() throws {
        let timer = SleepTimerService.shared
        preserveSleepTimers()
        for kind in BookKind.allCases {
            for pausedBefore in [false, true] {
                let context = "\(kind), \(pausedBefore ? "paused before" : "playing")"
                let system = MediaSystem()
                let world = try makeIntegrationWorld("Where Am I Sleep Timer \(kind) \(pausedBefore)")
                let book = try openPlayingBook(kind, in: world, joining: system)
                if pausedBefore {
                    XCTAssertEqual(system.press(.pause), .success, context)
                }
                let announcement = try pressWhereAmI(in: book)
                // The reader shows the pause before the timer is set, as it
                // has long since when a listener sets one.
                handleQueuedCallbacks()

                book.reader.startSleepTimer(duration: .minutes(15), startPlaybackIfNeeded: true)

                XCTAssertTrue(timer.isActive, "\(context): the timer did not start")
                XCTAssertEqual(timer.ownerID, book.reader.readerID, "\(context): the timer is not the reader's")
                XCTAssertTrue(book.reader.isWhereAmISpeaking, "\(context): setting the timer ended the announcement")
                XCTAssertFalse(book.isPlaying, "\(context): the book plays under the announcement")
                finishWhereAmIByItself(book, announcement)
                book.endSound.passEndSound()
                XCTAssertTrue(waitUntil(timeout: 5) { book.isPlaying }, "\(context): the book did not play as the announcement ended")
                assertToldSystem(system, that: book.reader, plays: true, context)
            }
        }
    }

    // MARK: - After the Sleep Timer

    /// A 15-minute sleep timer with a two-second fade runs out and pauses
    /// speech; Play from the AirPods then resumes it where the fade began,
    /// at full volume, and the system is told it plays again.
    func testPlayAfterTheSleepTimerFadesOutResumesAtFullVolume() throws {
        let timer = SleepTimerService.shared
        preserveSleepTimers()
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Sleep Timer")
        world.settings.sleepFadeOutDuration = 2
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)

        quay.reader.play()
        reportWordSpoken(by: quay)
        let recorder = recordingAnnouncements {
            expireFifteenMinuteTimerWithItsFade(in: quay, timer: timer)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), [ReaderViewModel.sleepTimerExpiredAnnouncement])
        XCTAssertEqual(quay.reader.speechService.currentWordRange?.location, Self.openingOffset, "The fade lost the place")
        assertToldSystem(system, that: quay.reader, plays: false, "The timer's pause")

        XCTAssertEqual(system.press(.play), .success)
        assertSpeaks(quay, from: Self.openingOffset, "Play after the timer")
        assertToldSystem(system, that: quay.reader, plays: true, "Play after the timer")
    }

    /// After the sleep timer has paused speech, Previous Track from the
    /// AirPods moves the place back while speech stays paused, and Play then
    /// speaks from there at full volume.
    func testPreviousTrackAfterTheSleepTimerMovesBackAndPlayStartsThere() throws {
        let timer = SleepTimerService.shared
        preserveSleepTimers()
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Timer Skip")
        world.settings.sleepFadeOutDuration = 2
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let speech = quay.reader.speechService

        quay.reader.play()
        reportWordSpoken(by: quay)
        recordingAnnouncements {
            expireFifteenMinuteTimerWithItsFade(in: quay, timer: timer)
        }
        let handedOverBefore = quay.handedOver.utterances.count

        XCTAssertEqual(system.press(.previousTrack), .success)
        let movedTo = quay.reader.currentCharacterOffset
        XCTAssertLessThan(movedTo, Self.openingOffset, "Previous Track did not move back")
        XCTAssertGreaterThan(movedTo, Self.openingOffset - 2_000, "Previous Track moved too far")
        XCTAssertTrue(speech.isSpeaking && speech.isPaused, "Previous Track did not leave speech paused")
        XCTAssertEqual(quay.handedOver.utterances.count, handedOverBefore, "Previous Track spoke while paused")
        assertToldSystem(system, that: quay.reader, plays: false, "Previous Track while paused")

        XCTAssertEqual(system.press(.play), .success)
        assertSpeaks(quay, from: movedTo, "Play after Previous Track")
        assertToldSystem(system, that: quay.reader, plays: true, "Play after Previous Track")
    }

    // MARK: - Next and Previous Track While Playing

    /// Next Track and Previous Track from the AirPods skip speech forward
    /// and back while it plays, and the book plays on.
    func testTrackCommandsSkipSpeechForwardAndBackWhilePlaying() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Skips")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)

        quay.reader.play()
        reportWordSpoken(by: quay)
        assertTrackCommandsSkipForwardAndBack(quay, system: system)
    }

    /// The same with an End of heading sleep timer set: skips that stay in
    /// the heading move speech and keep the timer, also once the reader has
    /// checked, at its usual pace, whether playback left the heading.
    func testTrackCommandsSkipWithinTheHeadingOfAnEndOfHeadingTimer() throws {
        let timer = SleepTimerService.shared
        preserveSleepTimers()
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Heading Timer")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)

        quay.reader.play()
        reportWordSpoken(by: quay)
        quay.reader.startSleepTimer(duration: .endOfHeading)
        // Several of the reader's playback refreshes, each of which asks
        // whether playback has left the timer's heading.
        spinMainRunLoop(for: ReaderViewModel.playbackUIRefreshInterval * 4)
        XCTAssertTrue(quay.reader.speechService.isSpeaking, "The heading timer stopped speech inside its heading")

        assertTrackCommandsSkipForwardAndBack(quay, system: system)
        spinMainRunLoop(for: ReaderViewModel.playbackUIRefreshInterval * 4)
        XCTAssertTrue(timer.isActive, "A skip within the heading ended the timer")
        XCTAssertEqual(timer.duration, .endOfHeading)
        XCTAssertFalse(quay.reader.speechService.isPaused, "The heading timer paused speech inside its heading")
    }

    // MARK: - Play Waiting for the Chapter's Speech

    /// Play from the AirPods while the opened chapter's speech is still
    /// being prepared in the background waits for it, showing Playing; Pause
    /// then stops the wait, so the speech, once ready, is not spoken; and
    /// Play speaks it from the cursor.
    func testPauseAndPlayWhilePlayWaitsForTheChaptersSpeech() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Waiting Play")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let inputs = try XCTUnwrap(quay.reader.speechInputs(forChapterAt: 0))

        quay.reader.prepareOpenedChapterSpeech()
        XCTAssertEqual(system.press(.play), .success)
        XCTAssertTrue(quay.reader.isWaitingForChapterSpeech, "Play did not wait for the chapter's speech")
        XCTAssertTrue(quay.handedOver.utterances.isEmpty, "Play spoke before the speech was ready")
        assertToldSystem(system, that: quay.reader, plays: true, "Play while waiting")

        XCTAssertEqual(system.press(.pause), .success)
        XCTAssertFalse(quay.reader.isWaitingForChapterSpeech, "Pause did not stop the wait")
        assertToldSystem(system, that: quay.reader, plays: false, "Pause while waiting")

        XCTAssertTrue(
            waitUntil(timeout: 10) { !quay.reader.chapterSpeechCache.isPreparingInBackground(inputs) },
            "The chapter's speech was never prepared"
        )
        handleQueuedCallbacks()
        XCTAssertTrue(quay.handedOver.utterances.isEmpty, "The paused play spoke once the speech was ready")
        XCTAssertFalse(quay.reader.speechService.isSpeaking, "The paused play started once the speech was ready")

        XCTAssertEqual(system.press(.play), .success)
        assertSpeaks(quay, from: Self.openingOffset, "Play once the speech was ready")
        assertToldSystem(system, that: quay.reader, plays: true, "Play once the speech was ready")
    }

    /// A play waiting for its chapter's speech counts as playing for the
    /// system's media commands, as it shows Playing: a recording starting
    /// pauses it, as it pauses every book playing, and so do the AirPods
    /// leaving, so it stops waiting and says nothing once its speech is
    /// ready, and the system is told it paused. Before, it counted as not
    /// playing, nothing paused it, and it began to speak once its speech was
    /// ready, under the recording or through the Mac's speakers (REV12's
    /// leftovers).
    func testAPlayWaitingForItsChaptersSpeechIsPausedAsAPlayingBookIs() throws {
        let pauses: [(name: String, pause: (MediaSystem) -> Void)] = [
            ("a recording starting", { system in
                XCTAssertEqual(system.coordinator.pauseEveryPlayingReader(), 1, "the waiting play was not paused")
            }),
            ("the AirPods leaving", { system in
                system.takeAirPodsOut()
            }),
        ]
        for (name, pause) in pauses {
            let system = MediaSystem()
            let world = try makeIntegrationWorld("Waiting Play Paused \(name)")
            world.settings.bluetoothMonitoringEnabled = true
            world.settings.bluetoothDisconnectDelay = 2
            let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
            let inputs = try XCTUnwrap(quay.reader.speechInputs(forChapterAt: 0), name)
            // The chapter's speech is "prepared off the main thread" by the
            // test, which hands it over when it chooses, so nothing can
            // start while the run loop turns.
            XCTAssertTrue(quay.reader.chapterSpeechCache.beginPreparingInBackground(inputs), name)
            quay.reader.play()
            XCTAssertTrue(quay.reader.isWaitingForChapterSpeech, "\(name): Play did not wait for the chapter's speech")
            system.coordinator.refreshPreviousDeviceInfo()
            XCTAssertTrue(system.coordinator.previousDeviceWasBluetooth, "\(name): the AirPods are not the output")

            pause(system)

            XCTAssertFalse(quay.reader.isWaitingForChapterSpeech, "\(name): the play still waits")
            quay.reader.finishPreparingInBackground(inputs.prepare())
            XCTAssertTrue(quay.handedOver.utterances.isEmpty, "\(name): the paused play spoke once its speech was ready")
            XCTAssertFalse(quay.reader.speechService.isSpeaking, "\(name): the paused play started once its speech was ready")
            assertToldSystem(system, that: quay.reader, plays: false, name)
        }
    }

    // MARK: - Continue to Next Book

    /// The book Continue to Next Book started takes the AirPods: Pause
    /// pauses it, and Play plays it again, while the finished book's reader
    /// stays open and silent.
    func testPauseAndPlayReachTheBookContinueToNextBookStarted() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Continue")
        let finishedBook = try world.makeSilentAudioBook(
            title: "First Crossing", trackDurations: [30], endOfBook: .continueNext
        )
        let nextBook = try world.makeSilentAudioBook(title: "Second Crossing", trackDurations: [30])
        let finished = world.openReader(for: finishedBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(finished)

        // The first book plays to its end and continues to the next one,
        // whose reader then opens, as its window does, and starts it.
        finished.play()
        XCTAssertTrue(finished.audioPlaybackService.isPlaying, "The first book did not play")
        finished.audioPlaybackService.stop()
        _ = recordingAnnouncements {
            finished.handleEndOfBook()
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }
        XCTAssertTrue(world.autoplayRequests.hasRequest(for: nextBook.id), "The next book was not asked for")
        let next = world.openReader(for: nextBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(next)
        let audio = next.audioPlaybackService
        XCTAssertTrue(audio.isPlaying && !audio.isPaused, "Continue to Next Book did not start the next book")
        assertToldSystem(system, that: next, plays: true, "The next book's start")

        XCTAssertEqual(system.press(.pause), .success)
        XCTAssertTrue(audio.isPaused, "Pause did not pause the next book")
        assertToldSystem(system, that: next, plays: false, "Pause")

        XCTAssertEqual(system.press(.play), .success)
        XCTAssertTrue(audio.isPlaying && !audio.isPaused, "Play did not play the next book again")
        assertToldSystem(system, that: next, plays: true, "Play")
        XCTAssertFalse(finished.audioPlaybackService.isPlaying, "The finished book played again")
    }

    /// A book that finishes with Continue to Next Book hands the AirPods
    /// over to the next book as it says "Starting: <title>" (REV07, speech
    /// finding 5): it rests finished no longer. The AirPods' rewind in the
    /// moment before the next book is asked for moves its cursor back and
    /// plays nothing; once the next book plays, the finished book's window
    /// offers no Release Media Controls, and its keyboard Skip Backward
    /// moves its cursor only, leaving the next book playing and holding the
    /// controls. Before the repair the rewind played the finished book's
    /// end until the next book's start paused it, and the keyboard's skip
    /// played the finished book again and paused the next.
    func testABookThatContinuedToTheNextLeavesTheAirPodsToIt() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Continue Hand-over")
        world.settings.skipBackwardUnit = .seconds15
        // Forty seconds into a minute: each 15-second skip back lands
        // exactly, well inside the track.
        let finishedBook = try world.makeSilentAudioBook(
            title: "First Crossing",
            trackDurations: [60],
            savedPosition: ReadingPosition(chapterIndex: 0, characterOffset: 400),
            endOfBook: .continueNext
        )
        let nextBook = try world.makeSilentAudioBook(title: "Second Crossing", trackDurations: [30])
        let finished = world.openReader(for: finishedBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(finished)
        let audio = finished.audioPlaybackService

        // The first book plays, and ends with the hand-over. The main run
        // loop has not turned since, so the next book is not asked for yet.
        finished.play()
        XCTAssertTrue(audio.isPlaying, "The first book did not play")
        audio.stop()
        let ending = recordingAnnouncements {
            finished.handleEndOfBook()
        }
        XCTAssertEqual(ending.announcements.map(\.message), ["Starting: Second Crossing"])
        XCTAssertFalse(finished.hasFinishedBook, "The book that continued still rests finished at its end")
        XCTAssertFalse(world.autoplayRequests.hasRequest(for: nextBook.id), "The next book was asked for at once")

        // The AirPods' rewind in that moment only moves the cursor back.
        let atTheRewind = finished.currentCharacterOffset
        let rewinding = recordingAnnouncements {
            XCTAssertEqual(system.press(.previousTrack), .success)
        }
        XCTAssertFalse(audio.isPlaying, "The rewind played the book that continued")
        XCTAssertFalse(finished.isCurrentlyPlaying, "The book that continued shows Playing after the rewind")
        XCTAssertEqual(
            finished.currentCharacterOffset,
            atTheRewind - Self.fifteenSecondsOfAudio,
            "The rewind did not move the cursor back by the skip unit"
        )
        XCTAssertEqual(rewinding.announcements, [], "The rewind announced something")

        // The next book's window opens for the request and starts it.
        XCTAssertTrue(
            eventually { world.autoplayRequests.hasRequest(for: nextBook.id) },
            "The next book was never asked for"
        )
        let next = world.openReader(for: nextBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(next)
        let nextAudio = next.audioPlaybackService
        XCTAssertTrue(nextAudio.isPlaying && !nextAudio.isPaused, "Continue to Next Book did not start the next book")
        assertToldSystem(system, that: next, plays: true, "The next book's start")

        // Back in the finished book's window, which becomes key.
        finished.windowBecameKey()
        XCTAssertFalse(finished.canReleaseMediaControls, "Release Media Controls is offered for the book that continued")
        let atTheKeyboardSkip = finished.currentCharacterOffset
        finished.lastSkipTime = .distantPast
        let skipping = recordingAnnouncements {
            finished.skipBackward()
        }
        XCTAssertFalse(audio.isPlaying, "The keyboard's Skip Backward played the book that continued")
        XCTAssertEqual(
            finished.currentCharacterOffset,
            atTheKeyboardSkip - Self.fifteenSecondsOfAudio,
            "The keyboard's Skip Backward did not move the cursor back by the skip unit"
        )
        XCTAssertTrue(nextAudio.isPlaying && !nextAudio.isPaused, "The keyboard's Skip Backward paused the next book")
        assertToldSystem(system, that: next, plays: true, "The keyboard's Skip Backward in the finished book's window")
        XCTAssertEqual(skipping.announcements, [], "The keyboard's Skip Backward announced something")
    }

    /// A book that hands over to the next one tells the system, as it says
    /// "Starting: <title>", that it no longer plays: the system shows it
    /// paused until the next book plays, and the next book's start finds no
    /// book playing to pause. Before, the system went on showing it playing,
    /// and the next book's start paused it as a book still playing, which in
    /// the app made the pause sound with the next book's play sound.
    func testABookThatHandsOverIsShownPausedAndTheNextBooksStartPausesNothing() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Hand-over Paused")
        let finishedBook = try world.makeSilentAudioBook(
            title: "First Crossing", trackDurations: [30], endOfBook: .continueNext
        )
        let nextBook = try world.makeSilentAudioBook(title: "Second Crossing", trackDurations: [30])
        let finished = world.openReader(for: finishedBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(finished)

        // The first book plays, and ends with the hand-over.
        finished.play()
        XCTAssertTrue(finished.audioPlaybackService.isPlaying, "The first book did not play")
        assertToldSystem(system, that: finished, plays: true, "The first book's play")
        finished.audioPlaybackService.stop()
        let ending = recordingAnnouncements {
            finished.handleEndOfBook()
        }
        XCTAssertEqual(ending.announcements.map(\.message), ["Starting: Second Crossing"])
        assertToldSystem(system, that: finished, plays: false, "The hand-over")

        // The next book's window opens for the request and starts it.
        XCTAssertTrue(
            eventually { world.autoplayRequests.hasRequest(for: nextBook.id) },
            "The next book was never asked for"
        )
        let next = world.openReader(for: nextBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(next)
        let nextAudio = next.audioPlaybackService
        XCTAssertTrue(nextAudio.isPlaying && !nextAudio.isPaused, "Continue to Next Book did not start the next book")
        assertToldSystem(system, that: next, plays: true, "The next book's start")
        XCTAssertEqual(system.exclusivePauses, [], "The next book's start paused the book that handed over")
    }

    /// A Play from the AirPods in the moment a finished book hands over to
    /// the next one, after "Starting: <title>" and before the next book is
    /// asked for, goes to the hand-over: the next book is asked for at once,
    /// and only once, and its reader starts it, while the finished book
    /// plays nothing and says nothing more. Before, the Play reached the
    /// finished book, which played from its end, finished again, and said
    /// "Starting" a second time.
    func testAPlayDuringTheHandOverStartsTheNextBookAtOnce() throws {
        try assertAPressDuringTheHandOverStartsTheNextBookAtOnce(.play, "Play")
    }

    /// The same for Play/Pause, which the AirPods usually send: the
    /// finished book plays nothing, so the press reaches it as a Play.
    func testAPlayPauseDuringTheHandOverStartsTheNextBookAtOnce() throws {
        try assertAPressDuringTheHandOverStartsTheNextBookAtOnce(.togglePlayPause, "Play/Pause")
    }

    /// `command`, named `label`, pressed in the moment a finished book
    /// hands over to the next one, before the next book is asked for, asks
    /// for it at once, and only once, its reader starts it, and the finished
    /// book plays nothing and says nothing more.
    private func assertAPressDuringTheHandOverStartsTheNextBookAtOnce(
        _ command: RemoteMediaCommandRequest,
        _ label: String
    ) throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Hand-over \(label)")
        let finishedBook = try world.makeSilentAudioBook(
            title: "First Crossing", trackDurations: [30], endOfBook: .continueNext
        )
        let nextBook = try world.makeSilentAudioBook(title: "Second Crossing", trackDurations: [30])
        let finished = world.openReader(for: finishedBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(finished)
        var asked = 0
        let watching = world.notifications.publisher(for: .continueToNextBook).sink { _ in asked += 1 }
        defer { watching.cancel() }

        // The first book plays, and ends with the hand-over. The main run
        // loop has not turned since, so the next book is not asked for yet.
        finished.play()
        XCTAssertTrue(finished.audioPlaybackService.isPlaying, "The first book did not play")
        finished.audioPlaybackService.stop()
        let handingOver = recordingAnnouncements {
            finished.handleEndOfBook()
            XCTAssertEqual(asked, 0, "The next book was asked for before the announcement had a moment")

            XCTAssertEqual(system.press(command), .success, label)
            XCTAssertEqual(asked, 1, "\(label) did not ask for the next book at once")
            XCTAssertTrue(world.autoplayRequests.hasRequest(for: nextBook.id), "\(label) left the next book no request")
            // Long enough for the hand-over's own request to have come.
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }
        XCTAssertEqual(asked, 1, "\(label): the next book was asked for more than once")
        XCTAssertEqual(handingOver.announcements.map(\.message), ["Starting: Second Crossing"], label)
        XCTAssertFalse(finished.audioPlaybackService.isPlaying, "\(label) played the finished book")
        XCTAssertFalse(finished.isCurrentlyPlaying, "\(label): the finished book shows Playing")

        // The next book's window opens for the request and starts it.
        let next = world.openReader(for: nextBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(next)
        let nextAudio = next.audioPlaybackService
        XCTAssertTrue(nextAudio.isPlaying && !nextAudio.isPaused, "\(label): the next book did not start")
        assertToldSystem(system, that: next, plays: true, "\(label): the next book's start")
        XCTAssertEqual(system.exclusivePauses, [], "\(label): the next book's start paused the finished book")
    }

    /// Once the next book has been asked for, and until its reader claims
    /// the request and starts it, a Play that reaches the finished book
    /// changes nothing, even after the AirPods' rewind has moved its cursor
    /// back: nothing of the finished book plays over the book announced,
    /// and the next book is not asked for again. VoiceOver hears that the
    /// next book is still starting, so the press is heard: before, it did
    /// nothing and said nothing for as long as the next book took to open,
    /// and before that it played the finished book from where the rewind
    /// left it, until the next book's start paused it. Once the next book
    /// plays, the hand-over is over, and a Play in the finished book's
    /// window plays it from there, as a Play in any book's window does.
    func testAPlayAfterTheNextBookIsAskedForPlaysNothingOfTheFinishedBook() throws {
        try assertAPressAfterTheNextBookIsAskedForPlaysNothingOfTheFinishedBook(.play, "Play")
    }

    /// The same for Play/Pause, which the AirPods usually send.
    func testAPlayPauseAfterTheNextBookIsAskedForPlaysNothingOfTheFinishedBook() throws {
        try assertAPressAfterTheNextBookIsAskedForPlaysNothingOfTheFinishedBook(.togglePlayPause, "Play/Pause")
    }

    /// `command`, named `label`, pressed once the next book has been asked
    /// for, after a rewind, plays nothing of the finished book, asks for
    /// nothing more, and says the next book is still starting; once the
    /// next book plays, Play in the finished book's window plays it.
    private func assertAPressAfterTheNextBookIsAskedForPlaysNothingOfTheFinishedBook(
        _ command: RemoteMediaCommandRequest,
        _ label: String
    ) throws {
        XCTAssertEqual(EndOfBookWording.stillStarting("Second Crossing"), "Still starting: Second Crossing")
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Hand-over \(label) Asked")
        world.settings.skipBackwardUnit = .seconds15
        // Forty seconds into a minute: the 15-second rewind lands exactly,
        // well inside the track.
        let finishedBook = try world.makeSilentAudioBook(
            title: "First Crossing",
            trackDurations: [60],
            savedPosition: ReadingPosition(chapterIndex: 0, characterOffset: 400),
            endOfBook: .continueNext
        )
        let nextBook = try world.makeSilentAudioBook(title: "Second Crossing", trackDurations: [30])
        let finished = world.openReader(for: finishedBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(finished)
        var asked = 0
        let watching = world.notifications.publisher(for: .continueToNextBook).sink { _ in asked += 1 }
        defer { watching.cancel() }

        finished.play()
        XCTAssertTrue(finished.audioPlaybackService.isPlaying, "The first book did not play")
        finished.audioPlaybackService.stop()
        var rewoundTo = 0
        let pressing = recordingAnnouncements {
            finished.handleEndOfBook()
            XCTAssertTrue(eventually { asked == 1 }, "The next book was never asked for")

            let atTheRewind = finished.currentCharacterOffset
            XCTAssertEqual(system.press(.previousTrack), .success)
            rewoundTo = finished.currentCharacterOffset
            XCTAssertEqual(rewoundTo, atTheRewind - Self.fifteenSecondsOfAudio, "The rewind did not move the cursor back")
            XCTAssertEqual(system.press(command), .success, label)
        }
        XCTAssertEqual(
            pressing.announcements.map(\.message),
            ["Starting: Second Crossing", "Still starting: Second Crossing"],
            "\(label) did not say that the next book is still starting"
        )
        XCTAssertFalse(finished.audioPlaybackService.isPlaying, "\(label) played the finished book")
        XCTAssertFalse(finished.isCurrentlyPlaying, "\(label): the finished book shows Playing")
        XCTAssertEqual(asked, 1, "\(label): the next book was asked for again")
        XCTAssertTrue(world.autoplayRequests.hasRequest(for: nextBook.id), "\(label): the next book's request is gone")

        // The next book's window opens for the request and starts it.
        let next = world.openReader(for: nextBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(next)
        XCTAssertTrue(next.audioPlaybackService.isPlaying, "\(label): the next book did not start")
        assertToldSystem(system, that: next, plays: true, "\(label): the next book's start")

        // The hand-over is over: Play in the finished book's window plays it
        // from where the rewind left it, and pauses the next book.
        finished.windowBecameKey()
        finished.play()
        assertPlaysAudio(finished, inChapter: 0, from: rewoundTo, "\(label): Play in the finished book's window once the next book played")
        XCTAssertTrue(next.audioPlaybackService.isPaused, "\(label): the next book was not paused")
        assertToldSystem(system, that: finished, plays: true, "\(label): Play in the finished book's window once the next book played")
    }

    // MARK: - Two Windows, One Closed

    /// The listener opens another book's window and closes it again, while
    /// the first book plays. SwiftUI keeps the closed window's reader alive.
    /// The AirPods go on pausing and playing the first book.
    func testClosingAnotherWindowLeavesTheCommandsWithTheBookPlaying() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Other Window")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let slipway = openTextBook(titled: "Slipway Ledger", in: world, joining: system)

        quay.reader.play()
        reportWordSpoken(by: quay)
        slipway.reader.nowPlayingService.focus()
        slipway.reader.close()

        XCTAssertEqual(system.press(.pause), .success)
        XCTAssertTrue(quay.reader.speechService.isPaused, "Pause did not reach the playing book")
        assertToldSystem(system, that: quay.reader, plays: false, "Pause")

        XCTAssertEqual(system.press(.play), .success)
        assertSpeaks(quay, from: Self.openingOffset, "Play")
        assertToldSystem(system, that: quay.reader, plays: true, "Play")
        XCTAssertTrue(slipway.handedOver.utterances.isEmpty, "The closed window's book spoke")
    }

    /// The listener starts a second book in its own window, which pauses the
    /// first, and closes the first book's window. The AirPods pause and play
    /// the second book, and the closed window's book stays silent.
    func testClosingTheFormerBooksWindowLeavesTheCommandsWithTheBookNowPlaying() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Former Window")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let slipway = openTextBook(titled: "Slipway Ledger", in: world, joining: system)

        quay.reader.play()
        reportWordSpoken(by: quay)
        slipway.reader.nowPlayingService.focus()
        slipway.reader.play()
        reportWordSpoken(by: slipway)
        XCTAssertTrue(quay.reader.speechService.isPaused, "Starting the second book did not pause the first")
        quay.reader.close()
        let quaySpoke = quay.handedOver.utterances.count

        XCTAssertEqual(system.press(.pause), .success)
        XCTAssertTrue(slipway.reader.speechService.isPaused, "Pause did not reach the playing book")
        assertToldSystem(system, that: slipway.reader, plays: false, "Pause")

        XCTAssertEqual(system.press(.play), .success)
        assertSpeaks(slipway, from: Self.openingOffset, "Play")
        assertToldSystem(system, that: slipway.reader, plays: true, "Play")
        XCTAssertEqual(quay.handedOver.utterances.count, quaySpoke, "The closed window's book spoke")
    }

    /// The listener's book is paused, as a sleep timer leaves it, when
    /// another book's window, which never played, opens and closes again.
    /// The system goes on showing the paused book, never told that playback
    /// stopped, and Play from the AirPods resumes it.
    func testClosingAWindowThatNeverPlayedKeepsThePausedBookShown() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Idle Window")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let slipway = openTextBook(titled: "Slipway Ledger", in: world, joining: system)

        quay.reader.play()
        reportWordSpoken(by: quay)
        quay.reader.pause()
        slipway.reader.nowPlayingService.focus()
        slipway.reader.close()
        assertToldSystem(system, that: quay.reader, plays: false, "Closing the idle window")

        XCTAssertEqual(system.press(.play), .success)
        assertSpeaks(quay, from: Self.openingOffset, "Play")
        assertToldSystem(system, that: quay.reader, plays: true, "Play")
    }

    /// The listener pauses their book and moves to another book's window,
    /// which never played, while the system still shows the paused book;
    /// then the paused book's window closes. The system is told, once, that
    /// TextMouth stopped, so the AirPods go back to other apps, rather than
    /// going on showing a book whose window is closed.
    func testClosingThePausedBooksWindowWhileAnotherIsInFrontTakesItsItemDown() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Closed Behind")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let slipway = openTextBook(titled: "Slipway Ledger", in: world, joining: system)

        quay.reader.play()
        reportWordSpoken(by: quay)
        quay.reader.pause()
        slipway.reader.windowBecameKey()
        XCTAssertEqual(
            system.told.last,
            .some(NowPlayingItem(title: quay.reader.book.title, author: quay.reader.book.author, isPlaying: false)),
            "The paused book is not shown paused"
        )
        quay.reader.close()

        XCTAssertEqual(system.told.last, .some(nil), "The closed window's book is still shown")
        XCTAssertEqual(system.told.filter { $0 == nil }.count, 1, "The system was told more than once that TextMouth stopped")
        XCTAssertEqual(system.coordinator.activeOwnerID, slipway.reader.nowPlayingService.ownerID)
        XCTAssertFalse(slipway.reader.canReleaseMediaControls, "The window in front offers to release what it never held")
    }

    /// The same when the paused book stops from behind, its window still
    /// open, as when its chapter cannot be got from the cloud or its text
    /// is replaced: its item is taken down, once, as if its window had
    /// closed, so the AirPods go back to other apps rather than staying
    /// with a book that stopped. Before, only the active reader's stop took
    /// its item down.
    func testStoppingThePausedBookFromBehindAnotherWindowTakesItsItemDown() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Stopped Behind")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let slipway = openTextBook(titled: "Slipway Ledger", in: world, joining: system)

        quay.reader.play()
        reportWordSpoken(by: quay)
        quay.reader.pause()
        slipway.reader.windowBecameKey()
        quay.reader.stop()

        XCTAssertEqual(system.told.last, .some(nil), "The stopped book is still shown")
        XCTAssertEqual(system.told.filter { $0 == nil }.count, 1, "The system was told more than once that TextMouth stopped")
        XCTAssertEqual(system.coordinator.activeOwnerID, slipway.reader.nowPlayingService.ownerID)
        XCTAssertFalse(quay.reader.canReleaseMediaControls, "The stopped book offers to release controls")
        XCTAssertFalse(slipway.reader.canReleaseMediaControls, "The window in front offers to release what it never held")
    }

    // MARK: - A Book That Pauses Behind Another Window

    /// The listener's book plays while another book's window, which never
    /// played, is in front, and the AirPods pause it. The system is told the
    /// book that paused is paused, whichever window is in front, so the
    /// next press is Play, which reaches that book and resumes it where it
    /// paused, and the book in front stays silent. Before the repair the
    /// system went on showing the book playing: the next press was a Pause,
    /// which reached the window in front, and the press after that played
    /// the book in front.
    func testABookPausedBehindAnotherWindowIsShownPausedAndPlayResumesIt() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Paused Behind")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let slipway = openTextBook(titled: "Slipway Ledger", in: world, joining: system)

        quay.reader.play()
        reportWordSpoken(by: quay)
        slipway.reader.windowBecameKey()

        XCTAssertEqual(system.press(.pause), .success)
        XCTAssertTrue(quay.reader.speechService.isPaused, "Pause did not reach the playing book")
        assertToldSystem(system, that: quay.reader, plays: false, "Pause behind another window")

        XCTAssertEqual(system.press(.play), .success)
        assertSpeaks(quay, from: Self.openingOffset, "Play after the pause behind another window")
        assertToldSystem(system, that: quay.reader, plays: true, "Play after the pause behind another window")
        XCTAssertTrue(slipway.handedOver.utterances.isEmpty, "The book in front spoke")
    }

    /// The same when the book's sleep timer runs out while another book's
    /// window is in front: the timer's fade pauses the book, the system is
    /// told it is paused, and Play from the AirPods resumes it where the
    /// fade began, at full volume, while the book in front stays silent.
    func testABookWhoseSleepTimerRunsOutBehindAnotherWindowIsShownPausedAndPlayResumesIt() throws {
        let timer = SleepTimerService.shared
        preserveSleepTimers()
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Timer Behind")
        world.settings.sleepFadeOutDuration = 2
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let slipway = openTextBook(titled: "Slipway Ledger", in: world, joining: system)

        quay.reader.play()
        reportWordSpoken(by: quay)
        slipway.reader.windowBecameKey()
        recordingAnnouncements {
            expireFifteenMinuteTimerWithItsFade(in: quay, timer: timer)
        }
        assertToldSystem(system, that: quay.reader, plays: false, "The timer's pause behind another window")

        XCTAssertEqual(system.press(.play), .success)
        assertSpeaks(quay, from: Self.openingOffset, "Play after the timer ran out behind another window")
        assertToldSystem(system, that: quay.reader, plays: true, "Play after the timer ran out behind another window")
        XCTAssertTrue(slipway.handedOver.utterances.isEmpty, "The book in front spoke")
    }

    // MARK: - Bluetooth

    /// The AirPods go back in their case while speech plays: CoreAudio
    /// reports the default output leaving the AirPods, which pauses speech
    /// and opens the window in which macOS's spurious Play is ignored. Play
    /// inside that window changes nothing; Play after it starts speech again
    /// from the place, on the current output.
    func testPlayInsideTheBluetoothWindowIsIgnoredAndAfterItResumes() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Bluetooth")
        world.settings.bluetoothMonitoringEnabled = true
        world.settings.bluetoothDisconnectDelay = 2
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        system.coordinator.refreshPreviousDeviceInfo()
        XCTAssertTrue(system.coordinator.previousDeviceWasBluetooth, "The AirPods are not the output")

        quay.reader.play()
        reportWordSpoken(by: quay)
        system.takeAirPodsOut()
        XCTAssertTrue(quay.reader.speechService.isPaused, "Taking the AirPods out did not pause speech")
        assertToldSystem(system, that: quay.reader, plays: false, "The AirPods out")
        let handedOverBefore = quay.handedOver.utterances.count

        system.advanceClock(by: 1)
        XCTAssertEqual(system.press(.play), .success)
        XCTAssertTrue(quay.reader.speechService.isPaused, "Play inside the window started speech")
        XCTAssertEqual(quay.handedOver.utterances.count, handedOverBefore, "Play inside the window spoke")
        assertToldSystem(system, that: quay.reader, plays: false, "Play inside the window")

        system.advanceClock(by: 2)
        XCTAssertEqual(system.press(.play), .success)
        assertSpeaks(quay, from: Self.openingOffset, "Play after the window")
        assertToldSystem(system, that: quay.reader, plays: true, "Play after the window")
    }

    // MARK: - Releasing Media Controls

    /// Only Release Media Controls tells the system that TextMouth stopped,
    /// handing the AirPods back to other apps; pausing never does.
    func testOnlyReleasingMediaControlsTellsTheSystemPlaybackStopped() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Release")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)

        quay.reader.play()
        reportWordSpoken(by: quay)
        system.press(.pause)
        system.press(.play)
        system.press(.pause)
        assertToldSystem(system, that: quay.reader, plays: false, "Pausing")

        _ = recordingAnnouncements {
            quay.reader.releaseMediaControls()
        }
        XCTAssertEqual(system.told.last, .some(nil), "Releasing media controls did not clear Now Playing")
        XCTAssertEqual(system.told.filter { $0 == nil }.count, 1, "Now Playing was cleared more than once")
        XCTAssertNil(system.coordinator.playingOwnerID)
    }

    /// Release Media Controls chosen by a key in a window whose book holds
    /// nothing, here one that never played while another book plays,
    /// releases nothing and changes nothing, and says so: the book playing
    /// plays on with the controls, the system is never told that TextMouth
    /// stopped, and the window's book is not marked as having released them.
    /// Before, it said nothing, so the listener could not tell the key had
    /// been heard.
    func testReleaseMediaControlsWhereTheBookHoldsNothingSaysSoAndChangesNothing() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Release Nothing Held")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let slipway = openTextBook(titled: "Slipway Ledger", in: world, joining: system)

        quay.reader.play()
        reportWordSpoken(by: quay)
        slipway.reader.windowBecameKey()
        XCTAssertFalse(slipway.reader.canReleaseMediaControls, "A window that never played offers Release Media Controls")

        let refused = recordingAnnouncements {
            slipway.reader.releaseMediaControls()
        }
        XCTAssertEqual(refused.announcements.map(\.message), [MediaControlsWording.notHeld])
        XCTAssertFalse(slipway.reader.mediaControlsReleased, "The window that held nothing is marked as having released them")
        assertSpeaks(quay, from: Self.openingOffset, "Release Media Controls in another window")
        assertToldSystem(system, that: quay.reader, plays: true, "Release Media Controls in another window")
    }

    /// The words VoiceOver hears for Release Media Controls, pinned: the
    /// release, and the refusal of a window whose book holds nothing, which
    /// begins as the release does.
    func testTheWordsOfReleaseMediaControls() {
        XCTAssertEqual(MediaControlsWording.released, "Media controls released")
        XCTAssertEqual(MediaControlsWording.notHeld, "Media controls not released: this book does not hold them.")
    }

    // MARK: - After the Speech Engine Refuses the Text

    /// The Mac's speech engine refuses the text where speech goes on, on
    /// the fresh synthesizer too, and speech stops there (#1308). The reader
    /// makes the stop its own, as a pause: the book's listening session
    /// ends, so no time away is credited as listening; the system is told
    /// the book is paused, never stopped, so the AirPods stay with TextMouth
    /// and their next press is Play; and the place where speech stopped and
    /// the stop itself are saved. VoiceOver hears once that speech stopped
    /// and that the details are in the book's window, which is not in front
    /// (B05). Play then speaks on from that place.
    func testARefusedTextStopsAsAPauseAndPlaySpeaksOnFromThere() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Refusal")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let reader = quay.reader
        let statistics = ReadingStatsService.shared

        reader.play()
        XCTAssertTrue(statistics.hasActiveSession, "Play opened no listening session")
        assertToldSystem(system, that: reader, plays: true, "Play")
        var refusedAt = 0
        let recorder = recordingAnnouncements {
            refusedAt = refuseTheChunkAfterTheFirst(of: quay)
        }

        XCTAssertEqual(recorder.announcements.map(\.message), [SpeechRefusalWording.announcement])
        XCTAssertFalse(reader.speechService.isSpeaking, "Speech did not stop")
        XCTAssertEqual(reader.currentCharacterOffset, refusedAt, "The cursor is not where speech stopped")
        XCTAssertFalse(statistics.hasActiveSession, "The listening session stayed open")
        assertToldSystem(system, that: reader, plays: false, "The refusal")
        let row = try XCTUnwrap(world.library.bookByID(reader.book.id))
        XCTAssertEqual(row.readingPosition?.characterOffset, refusedAt, "The place where speech stopped was not saved")
        XCTAssertNotNil(row.lastPlaybackStopped, "The stop was not recorded")
        // The report of the refusal waits for the window to show it (B05).
        let report = try XCTUnwrap(reader.speechRefusalAlert.report, "The reader keeps no report of the refusal")
        XCTAssertEqual(report.chapterOffset, refusedAt)
        XCTAssertEqual(report.timesRefusedHere, 1)

        XCTAssertEqual(system.press(.play), .success)
        handleQueuedCallbacks()
        assertSpeaks(quay, from: refusedAt, "Play after the refusal")
        assertToldSystem(system, that: reader, plays: true, "Play after the refusal")
        XCTAssertTrue(statistics.hasActiveSession, "Play after the refusal opened no listening session")
        XCTAssertEqual(reader.speechRefusalAlert.report, report, "Play changed the report, which stays until it is closed")
    }

    /// A 15-minute sleep timer's countdown halts where the speech engine's
    /// refusal stopped speech, as it halts at a pause, so it cannot run out
    /// while nothing plays; Play resumes it.
    func testARefusedTextHaltsTheSleepTimersCountdownUntilPlay() throws {
        let timer = SleepTimerService.shared
        preserveSleepTimers()
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Refusal Timer")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)

        quay.reader.play()
        quay.reader.startSleepTimer(duration: .minutes(15))
        let atTheRefusal = logLines(in: .sleepTimer) {
            _ = recordingAnnouncements {
                _ = refuseTheChunkAfterTheFirst(of: quay)
            }
        }

        XCTAssertTrue(timer.isActive, "The refusal ended the timer")
        XCTAssertTrue(atTheRefusal.contains { $0.contains("COUNTDOWN_PAUSED") }, "\(atTheRefusal)")
        let atPlay = logLines(in: .sleepTimer) {
            XCTAssertEqual(system.press(.play), .success)
        }
        XCTAssertTrue(atPlay.contains { $0.contains("COUNTDOWN_RESUMED") }, "\(atPlay)")
        XCTAssertTrue(quay.reader.speechService.isSpeaking, "Play did not speak")
    }

    /// A 15-minute sleep timer's countdown halts where Release Media
    /// Controls stops the book, as it halts at a pause, so its time left
    /// holds while nothing plays; Play resumes it. Every stop halts it
    /// (`ReaderViewModel.finishStopping`); before, only a pause did, and a
    /// stop left the countdown running on, or running out, over silence.
    func testReleasingMediaControlsHaltsTheSleepTimersCountdownUntilPlay() throws {
        let timer = SleepTimerService.shared
        preserveSleepTimers()
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Release Timer")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)

        quay.reader.play()
        reportWordSpoken(by: quay)
        quay.reader.startSleepTimer(duration: .minutes(15))
        let atTheRelease = logLines(in: .sleepTimer) {
            _ = recordingAnnouncements {
                quay.reader.releaseMediaControls()
            }
        }

        XCTAssertFalse(quay.reader.speechService.isSpeaking, "Releasing the media controls did not stop speech")
        XCTAssertTrue(timer.isActive, "Releasing the media controls ended the timer")
        XCTAssertTrue(atTheRelease.contains { $0.contains("COUNTDOWN_PAUSED") }, "\(atTheRelease)")
        let timeLeft = timer.remainingSeconds
        timer._advanceCountdownForTesting()
        XCTAssertEqual(timer.remainingSeconds, timeLeft, "The countdown ran on while nothing played")
        let atPlay = logLines(in: .sleepTimer) {
            XCTAssertEqual(system.press(.play), .success)
        }
        XCTAssertTrue(atPlay.contains { $0.contains("COUNTDOWN_RESUMED") }, "\(atPlay)")
        XCTAssertTrue(quay.reader.speechService.isSpeaking, "Play did not speak")
    }

    /// Where the speech engine's refusal stopped speech, the book is shown
    /// paused and holds the media controls, so Release Media Controls is
    /// offered, as it is for a paused book, and hands them back: the system
    /// is told once that playback stopped, and VoiceOver hears so. Before,
    /// it was not offered until Play, though the book held the controls.
    func testReleaseMediaControlsIsOfferedWhereARefusalStoppedSpeech() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Refusal Release")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let reader = quay.reader

        reader.play()
        recordingAnnouncements {
            refuseTheChunkAfterTheFirst(of: quay)
        }
        XCTAssertFalse(reader.speechService.isSpeaking, "Speech did not stop")
        assertToldSystem(system, that: reader, plays: false, "The refusal")
        XCTAssertTrue(reader.canReleaseMediaControls, "Release Media Controls is not offered where the refusal stopped speech")

        let releasing = recordingAnnouncements {
            reader.releaseMediaControls()
        }
        XCTAssertEqual(releasing.announcements.map(\.message), ["Media controls released"])
        XCTAssertEqual(system.told.last, .some(nil), "Releasing media controls did not clear Now Playing")
        XCTAssertEqual(system.told.filter { $0 == nil }.count, 1, "Now Playing was cleared more than once")
        XCTAssertNil(system.coordinator.playingOwnerID)
        XCTAssertFalse(reader.canReleaseMediaControls, "Release Media Controls is offered again")
    }

    // MARK: - When the Voice Never Starts

    /// The voice never starts the passage where speech begins, nor on the
    /// fresh synthesizers the start watchdog speaks it again on, and speech
    /// pauses there after the watchdog's second recovery, where it once
    /// spoke the passage again in silence every few seconds without end.
    /// The reader makes the pause its own: it shows Paused, the listening
    /// session ends, the system is told the book is paused, so the next
    /// press of the AirPods is Play, the place and the stop are saved, and
    /// VoiceOver hears once that the voice did not start. Play speaks from
    /// the place again. The watchdog's timers are ticked by hand.
    func testAVoiceThatNeverStartsPausesTheBookAndPlaySpeaksFromThere() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Voice Never Starts")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let reader = quay.reader
        let statistics = ReadingStatsService.shared
        let timers = ManualWatchdogTimers()
        reader.speechService._watchdogTimerForTesting = { interval, tick in
            timers.start(interval: interval, tick: tick)
        }

        reader.play()
        assertToldSystem(system, that: reader, plays: true, "Play")
        let recorder = recordingAnnouncements {
            letTheVoiceNeverStart(on: timers)
        }
        handleQueuedCallbacks()

        XCTAssertEqual(recorder.announcements.map(\.message), [SpeechService.voiceDidNotStartAnnouncement])
        XCTAssertTrue(reader.speechService.isPaused, "Speech did not pause where the voice did not start")
        XCTAssertTrue(reader.isCurrentlyPaused, "The reader does not show Paused")
        XCTAssertEqual(
            quay.handedOver.utterances.count,
            1 + SpeechService.directStartWatchdogRecoveriesPerPlace,
            "The passage was not spoken again exactly as often as the watchdog recovers"
        )
        XCTAssertEqual(reader.currentCharacterOffset, Self.openingOffset, "The cursor left the place")
        XCTAssertFalse(statistics.hasActiveSession, "The listening session stayed open")
        assertToldSystem(system, that: reader, plays: false, "The voice never started")
        let row = try XCTUnwrap(world.library.bookByID(reader.book.id))
        XCTAssertEqual(row.readingPosition?.characterOffset, Self.openingOffset, "The place was not saved")
        XCTAssertNotNil(row.lastPlaybackStopped, "The stop was not recorded")

        XCTAssertEqual(system.press(.play), .success)
        handleQueuedCallbacks()
        assertSpeaks(quay, from: Self.openingOffset, "Play after the voice never started")
        assertToldSystem(system, that: reader, plays: true, "Play after the voice never started")
        XCTAssertTrue(statistics.hasActiveSession, "Play opened no listening session")
    }

    // MARK: - After the Book Has Finished

    /// Report of 2026-10-07: "after a book 'finished' trying to use the
    /// rewind track on my AirPods didn't seem to work to hear the last
    /// little bit." An audiobook plays its last half second and finishes
    /// with the Stop behavior. Nothing is lost on the way to the reader: it
    /// keeps its media session, shown paused at the end rather than
    /// stopped, so macOS goes on sending the AirPods here; it is still the
    /// owner, and Previous Track is accepted and not dropped. The skip
    /// itself was what was lost: it moved the cursor back and left the
    /// stopped player silent, since a skip only played on when something
    /// was playing. Now Previous Track moves the cursor back by the skip
    /// unit from the end and plays from there, as a skip during playback
    /// plays on, and the system is told the book plays; the listener heard
    /// once that the book finished.
    func testPreviousTrackAfterAnAudiobookFinishesMovesBackFromTheEndAndPlays() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Finished Audio")
        let ferry = try finishSilentAudioBook(titled: "Ferry Timetable", in: world, joining: system)
        let reader = ferry.reader
        assertToldSystem(system, that: reader, plays: false, "The book's end")

        let recorder = recordingAnnouncements {
            XCTAssertEqual(system.press(.previousTrack), .success)
        }
        assertPlaysAudio(reader, from: ferry.endOffset - Self.fifteenSecondsOfAudio, "Previous Track after the end")
        assertToldSystem(system, that: reader, plays: true, "Previous Track after the end")
        XCTAssertEqual(recorder.announcements, [], "Previous Track after the end announced something")
    }

    /// The same for a text book, through the Skip Backward command, which
    /// the media keys send and an AirPods gesture can be set to: the book's
    /// last words are spoken and speech finishes with the Stop behavior,
    /// and the reader keeps its media session, shown paused at the end.
    /// Skip Backward then moves the cursor back by the skip unit and
    /// speaks from there at full volume, as it does while playing, and the
    /// system is told the book plays. Before the repair the skip seeked the
    /// finished speech, which started direct speech again on its own,
    /// outside Play: the system went on showing the book paused, nothing
    /// counted the listening, and the reader showed Playing by accident.
    func testSkipBackwardAfterATextBookFinishesMovesBackFromTheEndAndSpeaks() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Finished Text")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let end = finishSpeech(of: quay, in: system)

        let recorder = recordingAnnouncements {
            XCTAssertEqual(system.press(.skipBackward), .success)
        }
        let movedTo = quay.reader.currentCharacterOffset
        XCTAssertLessThan(movedTo, end, "Skip Backward did not move back")
        XCTAssertGreaterThan(movedTo, end - 2_000, "Skip Backward moved too far")
        assertSpeaks(quay, from: movedTo, "Skip Backward after the end")
        handleQueuedCallbacks()
        XCTAssertTrue(quay.reader.isCurrentlyPlaying, "The reader does not show Playing")
        assertToldSystem(system, that: quay.reader, plays: true, "Skip Backward after the end")
        XCTAssertEqual(recorder.announcements, [], "Skip Backward after the end announced something")
    }

    /// After an audiobook has finished, Next Track at the end stays exactly
    /// at the end, where the finished book rests (TODO P07), plays nothing,
    /// and announces nothing more, and Pause changes nothing either; the
    /// keyboard's Skip Backward then moves the cursor back by the skip unit
    /// from the end and plays, as the AirPods' rewind does. The keyboard's
    /// shortcut, the playback bar's button, and the AirPods all reach
    /// `skipBackward()`. Next Track once moved the cursor a tenth of a
    /// second back from the end, where a skip forward stops.
    func testNextTrackAndPauseAtTheEndChangeNothingAndTheKeyboardsSkipBackwardPlays() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Finished Keyboard Audio")
        let ferry = try finishSilentAudioBook(titled: "Ferry Timetable", in: world, joining: system)
        let reader = ferry.reader
        let audio = reader.audioPlaybackService
        let chapterEnd = try XCTUnwrap(reader.content?.chapters.last?.text.utf16Length)

        let recorder = recordingAnnouncements {
            XCTAssertEqual(system.press(.nextTrack), .success)
            XCTAssertFalse(audio.isPlaying, "Next Track at the end played")
            XCTAssertEqual(reader.currentChapterIndex, 1, "Next Track at the end left the last chapter")
            XCTAssertEqual(reader.currentCharacterOffset, chapterEnd, "Next Track at the end did not stay at the end")
            XCTAssertTrue(reader.cursorRestsAtEnd, "Next Track left the book short of its end")
            assertToldSystem(system, that: reader, plays: false, "Next Track at the end")

            XCTAssertEqual(system.press(.pause), .success)
            XCTAssertFalse(audio.isPlaying, "Pause at the end played")
            assertToldSystem(system, that: reader, plays: false, "Pause at the end")

            reader.lastSkipTime = .distantPast
            reader.skipBackward()
        }
        assertPlaysAudio(reader, from: chapterEnd - Self.fifteenSecondsOfAudio, "Skip Backward after the end")
        assertToldSystem(system, that: reader, plays: true, "Skip Backward after the end")
        XCTAssertEqual(recorder.announcements, [], "A skip or Pause at the end announced something")
    }

    /// The same for a text book: the keyboard's Skip Forward at the end
    /// stays at the end and speaks nothing, as a stopped reader's skip
    /// never speaks on its own, and Skip Backward then speaks from the skip
    /// unit before the end at full volume, the system told the book plays.
    func testTheKeyboardsSkipForwardAtTheEndStaysSilentAndSkipBackwardThenSpeaks() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Finished Keyboard Text")
        let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
        let reader = quay.reader
        let end = finishSpeech(of: quay, in: system)
        let handedOverBefore = quay.handedOver.utterances.count

        let recorder = recordingAnnouncements {
            reader.skipForward()
            XCTAssertFalse(reader.speechService.isSpeaking, "Skip Forward at the end spoke")
            XCTAssertEqual(quay.handedOver.utterances.count, handedOverBefore, "Skip Forward at the end handed speech over")
            XCTAssertGreaterThanOrEqual(reader.currentCharacterOffset, end, "Skip Forward at the end moved back")
            assertToldSystem(system, that: reader, plays: false, "Skip Forward at the end")

            reader.lastSkipTime = .distantPast
            reader.skipBackward()
        }
        let movedTo = reader.currentCharacterOffset
        XCTAssertLessThan(movedTo, end, "Skip Backward did not move back")
        XCTAssertGreaterThan(movedTo, end - 2_000, "Skip Backward moved too far")
        assertSpeaks(quay, from: movedTo, "Skip Backward after the end")
        assertToldSystem(system, that: reader, plays: true, "Skip Backward after the end")
        XCTAssertEqual(recorder.announcements, [], "A skip at the end announced something")
    }

    /// A jump away from the end, here to the first chapter, leaves the
    /// finished book a stopped reader like any other: a Skip Backward then
    /// moves the cursor without playing, the system still shows the book
    /// paused, and Play starts it from there.
    func testAJumpAwayFromTheEndLeavesASkipMovingTheCursorOnly() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Finished Jump")
        let ferry = try finishSilentAudioBook(titled: "Ferry Timetable", in: world, joining: system)
        let reader = ferry.reader

        reader.navigateTo(chapterIndex: 0, characterOffset: 5)
        XCTAssertFalse(reader.hasFinishedBook, "The book is still finished after the jump")
        reader.lastSkipTime = .distantPast
        reader.skipBackward()
        XCTAssertFalse(reader.audioPlaybackService.isPlaying, "A skip after the jump played")
        XCTAssertEqual(reader.currentChapterIndex, 0, "The skip left the first chapter")
        XCTAssertEqual(reader.currentCharacterOffset, 0, "The skip did not move to the start")
        assertToldSystem(system, that: reader, plays: false, "The skip after the jump")

        XCTAssertEqual(system.press(.play), .success)
        assertPlaysAudio(reader, inChapter: 0, from: 0, "Play after the jump")
        assertToldSystem(system, that: reader, plays: true, "Play after the jump")
    }

    /// A finished book still owns the media controls, so Release Media
    /// Controls is offered, and hands them back: the system is told
    /// playback stopped, and the book is finished no longer, so a Skip
    /// Backward then moves the cursor without playing or reclaiming the
    /// controls, as a stopped reader's does.
    func testReleasingMediaControlsAfterTheBookFinishesHandsThemBack() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Finished Release")
        let ferry = try finishSilentAudioBook(titled: "Ferry Timetable", in: world, joining: system)
        let reader = ferry.reader
        XCTAssertTrue(reader.canReleaseMediaControls, "Release Media Controls is not offered after the end")

        let recorder = recordingAnnouncements {
            reader.releaseMediaControls()
        }
        XCTAssertEqual(recorder.announcements.map(\.message), ["Media controls released"])
        XCTAssertEqual(system.told.last, .some(nil), "Releasing media controls did not clear Now Playing")
        XCTAssertFalse(reader.hasFinishedBook, "The released book is still finished")
        XCTAssertFalse(reader.canReleaseMediaControls, "Release Media Controls is offered again")

        reader.lastSkipTime = .distantPast
        reader.skipBackward()
        XCTAssertFalse(reader.audioPlaybackService.isPlaying, "A skip after releasing played")
        XCTAssertLessThan(reader.currentCharacterOffset, ferry.endOffset, "The skip did not move the cursor")
        XCTAssertEqual(system.told.last, .some(nil), "The skip reclaimed Now Playing")
    }

    /// A finished book offers Release Media Controls only while it holds
    /// them, its book the one the system shows (REV07, speech finding 5).
    /// Once another book plays, the finished book's window, which asks
    /// again as it becomes key, offers nothing, and Release Media Controls
    /// chosen anyway, as a key can choose it, releases nothing and says so:
    /// the playing book plays on with the controls, and the system is never
    /// told that TextMouth stopped. Before, the finished book stopped and
    /// said "Media controls released" while the other book kept them, and
    /// then said nothing at all. Nor is it offered while the system shows
    /// that book paused; that book's own window releases them.
    func testAFinishedBookOffersReleaseMediaControlsOnlyWhileItHoldsThem() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Finished Release Owner")
        let ferry = try finishSilentAudioBook(titled: "Ferry Timetable", in: world, joining: system)
        let finished = ferry.reader
        XCTAssertTrue(finished.canReleaseMediaControls, "Release Media Controls is not offered while the finished book holds the controls")

        // Another book's window opens, becomes key, and plays its book.
        let otherBook = try world.makeSilentAudioBook(title: "Harbour Timetable", trackDurations: [30])
        let other = world.openReader(for: otherBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(other)
        other.windowBecameKey()
        other.play()
        let otherAudio = other.audioPlaybackService
        XCTAssertTrue(otherAudio.isPlaying && !otherAudio.isPaused, "The other book did not play")
        assertToldSystem(system, that: other, plays: true, "The other book's start")

        // The finished book's window becomes key again and asks afresh.
        var republished = 0
        let watching = finished.objectWillChange.sink { _ in republished += 1 }
        finished.windowBecameKey()
        watching.cancel()
        XCTAssertGreaterThan(republished, 0, "The finished book's window did not ask afresh as it became key")
        XCTAssertEqual(system.coordinator.focusedOwnerID, finished.nowPlayingService.ownerID, "The finished book's reader is not focused")
        XCTAssertFalse(finished.canReleaseMediaControls, "Release Media Controls is offered while another book plays")
        let refused = recordingAnnouncements {
            finished.releaseMediaControls()
        }
        XCTAssertEqual(
            refused.announcements.map(\.message),
            [MediaControlsWording.notHeld],
            "Release Media Controls did not say the finished book holds nothing"
        )
        XCTAssertTrue(otherAudio.isPlaying && !otherAudio.isPaused, "Release Media Controls paused the book playing")
        assertToldSystem(system, that: other, plays: true, "Release Media Controls in the finished book's window")

        // The other book pauses, and the system shows it paused.
        other.windowBecameKey()
        other.pause()
        finished.windowBecameKey()
        XCTAssertEqual(
            system.told.last,
            .some(NowPlayingItem(title: other.book.title, author: other.book.author, isPlaying: false)),
            "The system does not show the other book paused"
        )
        XCTAssertFalse(finished.canReleaseMediaControls, "Release Media Controls is offered while the system shows another book")

        // That book's own window releases them.
        other.windowBecameKey()
        XCTAssertTrue(other.canReleaseMediaControls, "The paused book's window does not offer Release Media Controls")
        let released = recordingAnnouncements {
            other.releaseMediaControls()
        }
        XCTAssertEqual(released.announcements.map(\.message), ["Media controls released"])
        XCTAssertEqual(system.told.last, .some(nil), "Releasing media controls did not clear Now Playing")
        XCTAssertEqual(system.told.filter { $0 == nil }.count, 1, "Now Playing was cleared more than once")
    }

    /// While another book plays, the keyboard's Skip Backward in a finished
    /// book's window moves its cursor back by the skip unit and plays
    /// nothing (REV07, speech finding 5): the book being listened to plays
    /// on and keeps the controls, and the finished book rests at its end no
    /// longer. Before, the skip played the finished book again and paused
    /// the other.
    func testAFinishedBooksSkipBackwardWhileAnotherBookPlaysMovesItsCursorOnly() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Finished Skip Owner")
        let ferry = try finishSilentAudioBook(titled: "Ferry Timetable", in: world, joining: system)
        let finished = ferry.reader

        // Another book's window opens, becomes key, and plays its book.
        let otherBook = try world.makeSilentAudioBook(title: "Harbour Timetable", trackDurations: [30])
        let other = world.openReader(for: otherBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(other)
        other.windowBecameKey()
        other.play()
        let otherAudio = other.audioPlaybackService
        XCTAssertTrue(otherAudio.isPlaying && !otherAudio.isPaused, "The other book did not play")

        // Back in the finished book's window, Skip Backward.
        finished.windowBecameKey()
        finished.lastSkipTime = .distantPast
        let skipping = recordingAnnouncements {
            finished.skipBackward()
        }
        XCTAssertFalse(finished.audioPlaybackService.isPlaying, "Skip Backward played the finished book while another played")
        XCTAssertEqual(
            finished.currentCharacterOffset,
            ferry.endOffset - Self.fifteenSecondsOfAudio,
            "Skip Backward did not move the cursor back by the skip unit"
        )
        XCTAssertFalse(finished.hasFinishedBook, "The finished book still rests at its end after its cursor moved")
        XCTAssertTrue(otherAudio.isPlaying && !otherAudio.isPaused, "Skip Backward in the finished book's window paused the book playing")
        assertToldSystem(system, that: other, plays: true, "Skip Backward in the finished book's window")
        XCTAssertEqual(skipping.announcements, [], "Skip Backward announced something")
    }

    /// While nothing plays, a finished book's Skip Backward plays it again,
    /// though another book was played since and is shown paused: the
    /// finished book's reader, its window key, is the active owner, and the
    /// rewind exists to hear the end again while nothing else plays. The
    /// paused book stays paused.
    func testAFinishedBooksSkipBackwardWhileNothingPlaysPlaysItAgain() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Finished Skip Paused Other")
        let ferry = try finishSilentAudioBook(titled: "Ferry Timetable", in: world, joining: system)
        let finished = ferry.reader

        // Another book's window opens, becomes key, and plays its book, then
        // pauses it.
        let otherBook = try world.makeSilentAudioBook(title: "Harbour Timetable", trackDurations: [30])
        let other = world.openReader(for: otherBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(other)
        other.windowBecameKey()
        other.play()
        other.pause()
        let otherAudio = other.audioPlaybackService
        XCTAssertTrue(otherAudio.isPaused, "The other book did not pause")

        // Back in the finished book's window, Skip Backward.
        finished.windowBecameKey()
        finished.lastSkipTime = .distantPast
        finished.skipBackward()
        assertPlaysAudio(finished, from: ferry.endOffset - Self.fifteenSecondsOfAudio, "Skip Backward while nothing plays")
        assertToldSystem(system, that: finished, plays: true, "Skip Backward while nothing plays")
        XCTAssertTrue(otherAudio.isPaused, "The paused book did not stay paused")
    }

    /// The user's decision of October 7 evening, pinned (REV07, speech
    /// finding 4): "the timer should finish the book / stop it, then if the
    /// user hits rewind it should go 15 seconds or whatevr rewind does back
    /// and play from them then when it reaches the end of a book again it
    /// wwould continue to the next because there would be no timer". With an
    /// End of book sleep timer and Continue to Next Book, the timer stops
    /// the book at its end, keeps the next book from starting, and is spent;
    /// the AirPods' rewind then plays the end again from the skip back, at
    /// full volume; and at the end, with no timer left, Continue to Next
    /// Book starts the next book.
    func testAfterAnEndOfBookTimerStopsTheBookARewindReplaysItsEndThenItContinues() throws {
        let timer = SleepTimerService.shared
        preserveSleepTimers()
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Finished Timer Continue")
        world.settings.skipBackwardUnit = .seconds15
        world.settings.skipForwardUnit = .seconds30
        // The audio fades out toward the timer's stop, as a listener's can.
        world.settings.sleepFadeOutDuration = 2
        let lastHalfSecond = Int((Self.lastTrackSeconds - 0.5) * ReaderViewModel.audioCharsPerSecond)
        let firstBook = try world.makeSilentAudioBook(
            title: "First Crossing",
            trackDurations: [1, Self.lastTrackSeconds],
            savedPosition: ReadingPosition(chapterIndex: 1, characterOffset: lastHalfSecond),
            endOfBook: .continueNext
        )
        let nextBook = try world.makeSilentAudioBook(title: "Second Crossing", trackDurations: [30])
        let reader = world.openReader(for: firstBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(reader)
        let audio = reader.audioPlaybackService

        // The book plays its last half second under an End of book timer,
        // which stops it at its end and keeps the next book from starting.
        reader.startSleepTimer(duration: .endOfBook)
        let stopping = recordingAnnouncements {
            reader.play()
            XCTAssertTrue(audio.isPlaying, "The book did not play")
            XCTAssertTrue(
                eventually(within: 10) { !reader.isCurrentlyPlaying && !audio.isPlaying },
                "The book never finished"
            )
            // Long enough for a next book to have been asked for.
            spinMainRunLoop(for: ReaderViewModel.continueToNextBookDelay * 2)
        }
        XCTAssertEqual(
            stopping.announcements.map(\.message),
            ["Finished: First Crossing. Next book not started because of the sleep timer."]
        )
        XCTAssertFalse(timer.isActive, "The timer was not spent at the book's end")
        XCTAssertFalse(world.autoplayRequests.hasRequest(for: nextBook.id), "The next book was asked for past the timer")
        XCTAssertTrue(reader.hasFinishedBook, "The book the timer stopped does not rest finished at its end")
        assertToldSystem(system, that: reader, plays: false, "The timer's stop at the end")
        let endOffset = reader.currentCharacterOffset

        // The AirPods' rewind plays the end again from the skip back.
        let rewinding = recordingAnnouncements {
            XCTAssertEqual(system.press(.previousTrack), .success)
        }
        assertPlaysAudio(reader, from: endOffset - Self.fifteenSecondsOfAudio, "The rewind after the timer's stop")
        XCTAssertEqual(audio.intendedVolume, 1, "The end plays again faded, as if the timer were still set")
        assertToldSystem(system, that: reader, plays: true, "The rewind after the timer's stop")
        XCTAssertEqual(rewinding.announcements, [], "The rewind announced something")

        // The book plays on to its end, which Next Track brings near, where,
        // with no timer left, Continue to Next Book starts the next book.
        let continuing = recordingAnnouncements {
            reader.lastSkipTime = .distantPast
            XCTAssertEqual(system.press(.nextTrack), .success)
            XCTAssertTrue(
                eventually(within: 10) { world.autoplayRequests.hasRequest(for: nextBook.id) },
                "The next book was never asked for at the end"
            )
        }
        XCTAssertEqual(continuing.announcements.map(\.message), ["Starting: Second Crossing"])
        XCTAssertFalse(reader.hasFinishedBook, "The book that continued still rests finished at its end")
        let next = world.openReader(for: nextBook, nowPlaying: system.coordinator)
        waitForReaderToLoad(next)
        let nextAudio = next.audioPlaybackService
        XCTAssertTrue(nextAudio.isPlaying && !nextAudio.isPaused, "Continue to Next Book did not start the next book")
        assertToldSystem(system, that: next, plays: true, "The next book's start")
    }

    // MARK: - Saving Metadata

    /// #1498: a metadata save shows the book's new title in Now Playing only
    /// while its reader holds the media controls. Readers that never played,
    /// an audiobook's and an EPUB's, save without telling the system
    /// anything, so a save never takes the AirPods from the app they were
    /// with, and neither window offers Release Media Controls. Before, each
    /// save showed its book paused, which took them.
    func testSavingMetadataInAReaderThatNeverPlayedTellsTheSystemNothing() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Metadata Stopped")
        let soundings = try world.makeSilentAudioBook(title: "Breakwater Soundings", trackDurations: [1])
        let audioReader = world.openReader(for: soundings, nowPlaying: system.coordinator)
        waitForReaderToLoad(audioReader)
        let openedAudio = try XCTUnwrap(audioReader.audioMetadata, "The reader read no audio metadata")
        var editedAudio = openedAudio
        editedAudio.title = "Breakwater Soundings, Second Survey"

        let alice = try world.importBook(from: requireFile("alice.epub"))
        let epubReader = world.openReader(for: alice, nowPlaying: system.coordinator)
        waitForReaderToLoad(epubReader)
        XCTAssertTrue(waitUntil(timeout: 10) { epubReader.epubMetadata != nil }, "The reader showed no EPUB metadata")
        let openedEPUB = try XCTUnwrap(epubReader.epubMetadata)
        var editedEPUB = openedEPUB
        editedEPUB.title = "Alice's Adventures Under Ground"

        recordingAnnouncements {
            audioReader.saveAudioMetadata(editedAudio, openedAs: openedAudio)
            let outcome = epubReader.saveEPUBMetadata(editedEPUB, openedAs: openedEPUB, writeToFile: false)
            XCTAssertTrue(outcome.succeeded, "\(outcome)")
        }

        XCTAssertEqual(audioReader.book.title, "Breakwater Soundings, Second Survey", "The audio save did not reach its reader")
        XCTAssertEqual(epubReader.book.title, "Alice's Adventures Under Ground", "The EPUB save did not reach its reader")
        XCTAssertEqual(system.told, [], "A save told the system about a book that never played")
        XCTAssertFalse(audioReader.canReleaseMediaControls, "The audiobook's save took the media controls")
        XCTAssertFalse(epubReader.canReleaseMediaControls, "The EPUB's save took the media controls")
    }

    /// While its reader holds the media controls, a save shows the book's
    /// new title as the book is: playing while it plays, and paused once it
    /// is paused.
    func testSavingMetadataWhileTheReaderHoldsTheControlsShowsTheNewTitle() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Metadata Held")
        let soundings = try world.makeSilentAudioBook(title: "Breakwater Soundings", trackDurations: [30])
        let reader = world.openReader(for: soundings, nowPlaying: system.coordinator)
        waitForReaderToLoad(reader)

        reader.play()
        XCTAssertTrue(reader.audioPlaybackService.isPlaying, "The book did not play")
        let opened = try XCTUnwrap(reader.audioMetadata, "The reader read no audio metadata")
        var whilePlaying = opened
        whilePlaying.title = "Breakwater Soundings, Second Survey"
        recordingAnnouncements {
            reader.saveAudioMetadata(whilePlaying, openedAs: opened)
        }
        XCTAssertEqual(reader.book.title, "Breakwater Soundings, Second Survey", "The save did not reach the reader")
        assertToldSystem(system, that: reader, plays: true, "A save while the book plays")

        reader.pause()
        let reopened = try XCTUnwrap(reader.audioMetadata, "The reader kept no audio metadata")
        var whilePaused = reopened
        whilePaused.title = "Breakwater Soundings, Third Survey"
        recordingAnnouncements {
            reader.saveAudioMetadata(whilePaused, openedAs: reopened)
        }
        XCTAssertEqual(reader.book.title, "Breakwater Soundings, Third Survey", "The second save did not reach the reader")
        assertToldSystem(system, that: reader, plays: false, "A save while the book is paused")
    }

    /// A rename in the Library window reaches a finished book's reader,
    /// which holds the media controls resting paused at the end, and its
    /// new title is shown in Now Playing, by the rule the reader's own
    /// saves follow. Before, only a book playing or paused was shown anew,
    /// so a finished book kept its old title there.
    func testARenameInTheLibraryShowsAFinishedBooksNewTitle() throws {
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Media Commands Finished Rename")
        let ferry = try finishSilentAudioBook(titled: "Ferry Timetable", in: world, joining: system)
        let reader = ferry.reader
        assertToldSystem(system, that: reader, plays: false, "The book's end")
        let row = try XCTUnwrap(world.library.bookByID(reader.book.id))

        world.library.updateBookMetadata(
            Book.MetadataEdit(opened: [.title: row.title], saved: [.title: "Ferry Timetable, Winter Sailings"]),
            of: row.id
        )
        handleQueuedCallbacks()

        XCTAssertEqual(reader.book.title, "Ferry Timetable, Winter Sailings", "The rename did not reach the reader")
        assertToldSystem(system, that: reader, plays: false, "The rename")
    }

    // MARK: - The System's Side

    /// The system's side of the media session as a test plays it: the
    /// coordinator the readers join, made as the app makes its own but
    /// without system integrations; the commands MediaPlayer delivered, whose
    /// actions wait for the main queue; everything the app told the system's
    /// Now Playing center; the clock commands are received by; and the
    /// audio outputs CoreAudio reports.
    @MainActor
    private final class MediaSystem {
        /// The AirPods, a Bluetooth output, and the Mac's own speakers.
        nonisolated static let airPods: AudioDeviceID = 41
        nonisolated static let speakers: AudioDeviceID = 73

        /// What the coordinator reaches through the providers it was made
        /// with; kept apart so they can be made before the coordinator.
        @MainActor
        private final class State {
            var now = Date(timeIntervalSince1970: 1_000)
            var defaultOutput: AudioDeviceID? = MediaSystem.airPods
            var outputs: [AudioDeviceID] = [MediaSystem.airPods, MediaSystem.speakers]
            var waitingActions: [@MainActor @Sendable () -> Void] = []
            var told: [NowPlayingItem?] = []
            var routeLog: [String] = []
        }

        private let state: State
        /// The coordinator the test's readers join.
        let coordinator: NowPlayingService

        init() {
            let state = State()
            self.state = state
            coordinator = NowPlayingService(
                installsSystemIntegrations: false,
                diagnosticSink: { state.routeLog.append($0) },
                now: { state.now },
                defaultOutputDevice: { state.defaultOutput },
                audioDeviceIDs: { state.outputs },
                isBluetoothDevice: { $0 == MediaSystem.airPods },
                scheduleRemoteCommandAction: { state.waitingActions.append($0) },
                systemNowPlaying: { state.told.append($0) }
            )
        }

        /// Everything the app told the system's Now Playing center, oldest
        /// first: an item shown, or nil where it cleared the center.
        var told: [NowPlayingItem?] { state.told }

        /// The routing diagnostics of commands accepted but then dropped.
        var droppedCommands: [String] {
            state.routeLog.filter { $0.contains("result=commandFailed") }
        }

        /// The routing diagnostics of readers paused because another reader
        /// started (`NowPlayingService.prepareForPlayback(ownerID:)`): in the
        /// app, each such pause makes the pause sound.
        var exclusivePauses: [String] {
            state.routeLog.filter { $0.contains("exclusive pause") }
        }

        /// Deliver `request` as MediaPlayer does when the AirPods are
        /// pressed: the coordinator accepts it and MediaPlayer hears the
        /// result at once, then the main queue runs the command's action.
        ///
        /// - Returns: What MediaPlayer heard.
        @discardableResult
        func press(_ request: RemoteMediaCommandRequest) -> RemoteCommandDispatchResult {
            let heard = coordinator.acceptRemoteCommand(request)
            while !state.waitingActions.isEmpty {
                state.waitingActions.removeFirst()()
            }
            return heard
        }

        /// Move the clock commands are received by.
        func advanceClock(by seconds: TimeInterval) {
            state.now = state.now.addingTimeInterval(seconds)
        }

        /// The AirPods go back in their case: CoreAudio removes them and
        /// reports the default output changed to the Mac's speakers.
        func takeAirPodsOut() {
            state.defaultOutput = MediaSystem.speakers
            state.outputs = [MediaSystem.speakers]
            coordinator.handleDefaultOutputChange()
        }

        /// The AirPods come out of their case and connect: CoreAudio adds
        /// them and reports the default output changed to them.
        func putAirPodsIn() {
            state.defaultOutput = MediaSystem.airPods
            state.outputs = [MediaSystem.airPods, MediaSystem.speakers]
            coordinator.handleDefaultOutputChange()
        }
    }

    // MARK: - A Text Book That Is Never Heard

    /// The utterances a reader's speech handed over in place of the
    /// synthesizer, oldest first.
    private final class HandedOverUtterances {
        var utterances: [AVSpeechUtterance] = []
    }

    /// A text book's reader, joined to a test's media system.
    private struct TextBookReader {
        let reader: ReaderViewModel
        /// The book's one chapter, which is also exactly what is spoken: no
        /// pauses, substitutions, or skipped sections change it.
        let text: String
        let handedOver: HandedOverUtterances
    }

    /// Where every text book opens: the start of the 200th mooring, well
    /// inside the Moorings heading and far from either end of the chapter.
    private static let openingOffset = ledgerText.utf16OffsetOfFirst("Mooring 200 ")

    /// The one chapter of every text book: the Moorings heading at its
    /// start and the Tides heading past its middle, in all longer than
    /// speech ever renders, so speech stays direct and never reaches the
    /// audio engine.
    private static let ledgerText: String = {
        var text = "Moorings\n\n"
        for entry in 1...1_400 {
            text += "Mooring \(entry) of the harbour ledger is checked. "
        }
        text += "\n\nTides\n\n"
        for entry in 1...1_200 {
            text += "Tide \(entry) of the harbour ledger is noted. "
        }
        return text
    }()

    /// The chapter of `ledgerText`, with its two headings.
    private static func ledgerChapter() -> Chapter {
        Chapter(
            title: "Harbour Ledger",
            text: ledgerText,
            headings: [
                Heading(level: 1, text: "Moorings"),
                Heading(level: 1, text: "Tides", characterOffset: ledgerText.utf16OffsetOfFirst("Tides\n")),
            ]
        )
    }

    /// Opens a reader of a text book titled `title` in `world`, joined to
    /// `system`, at `openingOffset` of its one chapter (`ledgerChapter()`).
    ///
    /// The reader's direct utterances go to a recorder before it can speak,
    /// and its look-ahead renders are held. The book names a file that is not
    /// there, so its own load fails before the chapter is given to it, and
    /// nothing is read from disk. Punctuation pauses are off, so the spoken
    /// text is the chapter's own.
    private func openTextBook(
        titled title: String,
        in world: IntegrationWorld,
        joining system: MediaSystem
    ) -> TextBookReader {
        XCTAssertGreaterThan(
            Self.ledgerText.utf16Length,
            SpeechRenderCoordinator.maximumTextLength,
            "The chapter is short enough to render, so speech could be heard"
        )
        world.settings.punctuationPauseLevel = 0
        let book = Book(
            title: title,
            author: "Harbour Office",
            format: .txt,
            filePath: world.folder.path + "/\(UUID().uuidString) missing.txt",
            md5Hash: UUID().uuidString,
            folderPath: world.folder.path,
            readingPosition: ReadingPosition(chapterIndex: 0, characterOffset: Self.openingOffset)
        )
        world.library.library.addBook(book)
        let reader = world.openReader(for: book, renderScheduler: HeldRenderQueue(), nowPlaying: system.coordinator)
        let handedOver = HandedOverUtterances()
        reader.speechService._directUtteranceRecorderForTesting = { handedOver.utterances.append($0) }
        waitForReaderToLoad(reader)
        reader.errorMessage = nil
        reader.content = DocumentContent(title: title, author: book.author, chapters: [Self.ledgerChapter()])
        return TextBookReader(reader: reader, text: Self.ledgerText, handedOver: handedOver)
    }

    /// Tell `book`'s speech, as the synthesizer does once it begins, that it
    /// speaks the first word of the utterance handed over last, and let the
    /// main queue handle it, so the place is where speech really is.
    private func reportWordSpoken(
        by book: TextBookReader,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let spoken = book.handedOver.utterances.last else {
            XCTFail("Nothing was handed to the synthesizer", file: file, line: line)
            return
        }
        let firstWord = (spoken.speechString as NSString).range(of: " ")
        book.reader.speechService.speechSynthesizer(
            AVSpeechSynthesizer(),
            willSpeakRangeOfSpeechString: NSRange(location: 0, length: max(1, firstWord.location)),
            utterance: spoken
        )
        handleQueuedCallbacks(file: file, line: line)
    }

    /// Has the Mac's speech engine refuse the text where `book`'s speech
    /// goes on after its first chunk, as the synthesizer reports it: the
    /// first chunk starts, which queues the next, and finishes, which makes
    /// the next the one speaking; the engine cancels that one before it
    /// says a word, and then the fresh synthesizer's retry of it, and the
    /// main queue handles each report. Speech then stops where the second
    /// chunk begins, a place nothing saved before the refusal.
    ///
    /// - Returns: Where speech stopped: the second chunk's start.
    @discardableResult
    private func refuseTheChunkAfterTheFirst(
        of book: TextBookReader,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int {
        let speech = book.reader.speechService
        let synthesizer = AVSpeechSynthesizer()
        guard let first = book.handedOver.utterances.last else {
            XCTFail("Nothing was handed to the synthesizer", file: file, line: line)
            return 0
        }
        speech.speechSynthesizer(synthesizer, didStart: first)
        handleQueuedCallbacks(file: file, line: line)
        guard let second = book.handedOver.utterances.last, second !== first else {
            XCTFail("The second chunk was not queued", file: file, line: line)
            return 0
        }
        speech.speechSynthesizer(synthesizer, didFinish: first)
        handleQueuedCallbacks(file: file, line: line)
        speech.speechSynthesizer(synthesizer, didCancel: second)
        handleQueuedCallbacks(file: file, line: line)
        guard let retry = book.handedOver.utterances.last, retry !== second else {
            XCTFail("The refused chunk was not spoken again", file: file, line: line)
            return 0
        }
        speech.speechSynthesizer(synthesizer, didCancel: retry)
        handleQueuedCallbacks(file: file, line: line)
        let firstChunk = DirectSpeechChunk.starting(
            at: Self.openingOffset,
            in: book.text,
            maximumLength: SpeechService.directModeFirstChunkSize
        )
        return DirectSpeechChunk.starting(at: firstChunk.end, in: book.text, maximumLength: SpeechService.directModeChunkSize).start
    }

    /// Has the voice never start what speech hands over, while `timers`
    /// tick its start watchdog: the watchdog waits out its timeout for each
    /// utterance, the first on a synthesizer that has started none, and
    /// speaks it again on a fresh one, until, past its recoveries at the
    /// place, speech pauses there and nothing is watched.
    private func letTheVoiceNeverStart(
        on timers: ManualWatchdogTimers,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for _ in 0...SpeechService.directStartWatchdogRecoveriesPerPlace {
            guard let watchdog = timers.running.last else {
                XCTFail("Nothing watches the utterance handed over", file: file, line: line)
                return
            }
            timers.tick(watchdog, times: SpeechService.directStartWatchdogColdRequiredTicks)
        }
        XCTAssertTrue(timers.running.isEmpty, "A watchdog still watches the paused speech", file: file, line: line)
    }

    /// Set a 15-minute sleep timer in `book`'s reader and run it out on its
    /// own clock: one second left, then the next tick, then its fade, which
    /// the main run loop plays out in steps, as in the app.
    private func expireFifteenMinuteTimerWithItsFade(
        in book: TextBookReader,
        timer: SleepTimerService,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        book.reader.startSleepTimer(duration: .minutes(15))
        XCTAssertEqual(timer.remainingSeconds, 15 * 60, file: file, line: line)
        timer.remainingSeconds = 1
        timer._advanceCountdownForTesting()
        XCTAssertTrue(timer.isFadingOut, "The timer did not begin its fade", file: file, line: line)
        let speech = book.reader.speechService
        XCTAssertTrue(
            waitUntil(timeout: 6) { !timer.isActive && speech.isPaused },
            "The timer never paused speech",
            file: file,
            line: line
        )
        handleQueuedCallbacks(file: file, line: line)
        XCTAssertTrue(book.handedOver.utterances.contains { $0.volume < 1 }, "Speech did not fade", file: file, line: line)
        XCTAssertTrue(speech.isSpeaking, "The timer stopped speech instead of pausing it", file: file, line: line)
    }

    /// Next Track then Previous Track from the AirPods while `book` plays:
    /// each moves speech, which goes on playing from the new place, and the
    /// system is told it plays. The presses come more than the skip
    /// debounce apart, as a listener's do.
    private func assertTrackCommandsSkipForwardAndBack(
        _ book: TextBookReader,
        system: MediaSystem,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reader = book.reader
        let before = reader.currentCharacterOffset

        reader.lastSkipTime = .distantPast
        XCTAssertEqual(system.press(.nextTrack), .success, file: file, line: line)
        let forward = reader.currentCharacterOffset
        XCTAssertGreaterThan(forward, before, "Next Track did not move forward", file: file, line: line)
        assertSpeaks(book, from: forward, "Next Track", file: file, line: line)
        assertToldSystem(system, that: reader, plays: true, "Next Track", file: file, line: line)

        reader.lastSkipTime = .distantPast
        XCTAssertEqual(system.press(.previousTrack), .success, file: file, line: line)
        let back = reader.currentCharacterOffset
        XCTAssertLessThan(back, forward, "Previous Track did not move back", file: file, line: line)
        assertSpeaks(book, from: back, "Previous Track", file: file, line: line)
        assertToldSystem(system, that: reader, plays: true, "Previous Track", file: file, line: line)
    }

    // MARK: - A Book That Has Finished

    /// Seconds of silence in the last track of every finished audiobook:
    /// long enough for a skip of either unit to land inside it.
    private static let lastTrackSeconds: TimeInterval = 30

    /// How far the 15-second skip moves an audiobook's cursor: ten
    /// characters stand for one second of audio.
    private static let fifteenSecondsOfAudio = Int(15 * ReaderViewModel.audioCharsPerSecond)

    /// An audiobook's reader, joined to a test's media system, whose book
    /// has just finished.
    private struct FinishedAudioBook {
        let reader: ReaderViewModel
        /// Where the cursor rests at the end: the last position the player
        /// reported, within the last second of the last track.
        let endOffset: Int
    }

    /// Opens a reader of a silent audiobook titled `title` in `world`,
    /// joined to `system`, half a second before the end of its last track,
    /// and plays it to its end, where it finishes with the Stop behavior:
    /// the listener hears once that the book finished, the reader shows
    /// nothing playing, and the system is told the book is paused, not
    /// stopped. The skip units are set to 15 seconds back and 30 forward,
    /// as the app's defaults are, so that a skip's landing is known.
    private func finishSilentAudioBook(
        titled title: String,
        in world: IntegrationWorld,
        joining system: MediaSystem,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> FinishedAudioBook {
        world.settings.skipBackwardUnit = .seconds15
        world.settings.skipForwardUnit = .seconds30
        let lastHalfSecond = Int((Self.lastTrackSeconds - 0.5) * ReaderViewModel.audioCharsPerSecond)
        let book = try world.makeSilentAudioBook(
            title: title,
            trackDurations: [1, Self.lastTrackSeconds],
            savedPosition: ReadingPosition(chapterIndex: 1, characterOffset: lastHalfSecond),
            endOfBook: .stop
        )
        let reader = world.openReader(for: book, nowPlaying: system.coordinator)
        waitForReaderToLoad(reader, file: file, line: line)
        let audio = reader.audioPlaybackService
        let recorder = recordingAnnouncements {
            reader.play()
            XCTAssertTrue(audio.isPlaying, "\(title) did not play", file: file, line: line)
            XCTAssertTrue(
                eventually(within: 10) { !reader.isCurrentlyPlaying && !audio.isPlaying },
                "\(title) never finished",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(recorder.announcements.map(\.message), ["Finished: \(title)"], file: file, line: line)
        XCTAssertEqual(reader.currentChapterIndex, 1, "The cursor left the last chapter", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            reader.currentCharacterOffset, lastHalfSecond, "The cursor is not at the end", file: file, line: line
        )
        return FinishedAudioBook(reader: reader, endOffset: reader.currentCharacterOffset)
    }

    /// Where the text book's last words begin: inside the last chunk direct
    /// speech speaks, which ends where the chapter does.
    private static let lastWordsOffset = ledgerText.utf16Length - 400

    /// Speaks `book`'s last words and finishes its speech, as the
    /// synthesizer reports the end of the utterance handed over, so that
    /// the book finishes with the Stop behavior: the listener hears once
    /// that it finished, the reader shows nothing playing, and the system
    /// is told the book is paused, not stopped.
    ///
    /// - Returns: Where the cursor rests at the end: the last word speech
    ///   reported.
    private func finishSpeech(
        of book: TextBookReader,
        in system: MediaSystem,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Int {
        let reader = book.reader
        reader.navigateTo(chapterIndex: 0, characterOffset: Self.lastWordsOffset)
        let recorder = recordingAnnouncements {
            reader.play()
            reportWordSpoken(by: book, file: file, line: line)
            guard let spoken = book.handedOver.utterances.last else {
                XCTFail("Nothing was handed to the synthesizer", file: file, line: line)
                return
            }
            reader.speechService.speechSynthesizer(AVSpeechSynthesizer(), didFinish: spoken)
            handleQueuedCallbacks(file: file, line: line)
        }
        XCTAssertEqual(
            recorder.announcements.map(\.message), ["Finished: \(reader.book.title)"], file: file, line: line
        )
        XCTAssertFalse(reader.speechService.isSpeaking, "Speech did not finish", file: file, line: line)
        XCTAssertTrue(
            waitUntil(timeout: 2) { !reader.isCurrentlyPlaying },
            "The reader still shows Playing",
            file: file,
            line: line
        )
        assertToldSystem(system, that: reader, plays: false, "The book's end", file: file, line: line)
        return reader.currentCharacterOffset
    }

    // MARK: - A Book Where Am I? Holds Paused

    /// The two kinds of book a reader plays.
    private enum BookKind: CaseIterable {
        /// A text book, whose speech is never heard (`openTextBook`).
        case text
        /// A silent audiobook.
        case audio
    }

    /// A reader playing a book of either kind, joined to a test's media
    /// system, whose Where Am I? announcements go to a recorder in place of
    /// its synthesizer, so that nothing is heard, and whose announcements'
    /// end sound passes only when the test lets it.
    @MainActor
    private struct PlayingBook {
        let kind: BookKind
        let reader: ReaderViewModel
        /// The text book, with what its speech handed over in place of the
        /// synthesizer, so a test can check where it speaks from; nil for an
        /// audiobook.
        let text: TextBookReader?
        /// The announcements handed over, oldest first.
        let announcements: HandedOverUtterances
        /// Holds what an announcement that ended by itself leaves for once
        /// its end sound has played.
        let endSound: WhereAmIEndSoundClock

        /// Whether the book plays: playing, not paused.
        var isPlaying: Bool {
            switch kind {
            case .text:
                return reader.speechService.isSpeaking && !reader.speechService.isPaused
            case .audio:
                return reader.audioPlaybackService.isPlaying && !reader.audioPlaybackService.isPaused
            }
        }

        /// Whether the book is paused, ready to go on where it paused.
        var isPaused: Bool {
            switch kind {
            case .text:
                return reader.speechService.isSpeaking && reader.speechService.isPaused
            case .audio:
                return reader.audioPlaybackService.isPaused
            }
        }
    }

    /// Opens a book of `kind` in `world`, joined to `system`, and plays it:
    /// the text book at `openingOffset`, its first word reported, or a
    /// silent audiobook from its start, one chapter for each of
    /// `audioTracks` (seconds), one 30-second track unless given.
    private func openPlayingBook(
        _ kind: BookKind,
        in world: IntegrationWorld,
        joining system: MediaSystem,
        audioTracks: [TimeInterval] = [30],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> PlayingBook {
        let reader: ReaderViewModel
        var text: TextBookReader?
        switch kind {
        case .text:
            let quay = openTextBook(titled: "Quay Ledger", in: world, joining: system)
            quay.reader.play()
            reportWordSpoken(by: quay, file: file, line: line)
            reader = quay.reader
            text = quay
        case .audio:
            let soundings = try world.makeSilentAudioBook(title: "Harbour Soundings", trackDurations: audioTracks)
            reader = world.openReader(for: soundings, nowPlaying: system.coordinator)
            waitForReaderToLoad(reader, file: file, line: line)
            reader.play()
        }
        let announcements = HandedOverUtterances()
        reader._whereAmIUtteranceRecorderForTesting = { announcements.utterances.append($0) }
        let book = PlayingBook(
            kind: kind,
            reader: reader,
            text: text,
            announcements: announcements,
            endSound: WhereAmIEndSoundClock(holdingFor: reader)
        )
        XCTAssertTrue(waitUntil(timeout: 5) { book.isPlaying }, "\(kind): the book did not play", file: file, line: line)
        return book
    }

    /// The ways a test leaves a playing book not playing before it presses
    /// Where Am I? over it: paused, by a Pause from the AirPods, or stopped.
    private static var waysToLeaveABookNotPlaying: [(name: String, leave: (PlayingBook, MediaSystem) -> Void)] {
        [
            ("paused before", { _, system in
                XCTAssertEqual(system.press(.pause), .success)
            }),
            ("stopped before", { book, _ in
                book.reader.stop()
            }),
        ]
    }

    /// Presses Where Am I? in `book`'s window, which pauses the book and
    /// hands its announcement over, and returns the announcement.
    private func pressWhereAmI(
        in book: PlayingBook,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AVSpeechUtterance {
        let before = book.announcements.utterances.count
        book.reader.whereAmI()
        XCTAssertTrue(book.reader.isWhereAmISpeaking, "\(book.kind): Where Am I? does not speak", file: file, line: line)
        XCTAssertTrue(book.isPaused, "\(book.kind): Where Am I? did not pause the book", file: file, line: line)
        let handedOver = book.announcements.utterances
        return try XCTUnwrap(
            handedOver.count > before ? handedOver.last : nil,
            "\(book.kind): no announcement was handed over",
            file: file,
            line: line
        )
    }

    /// Check that `book`'s Where Am I? announcement, `announcement`, has
    /// ended, and that the synthesizer's report of its finish, which once
    /// resumed the book, changes nothing: once the moment the book would
    /// have resumed in has passed (`whereAmIEndSoundDelay`), it is still
    /// paused.
    private func assertStaysPausedAfterTheAnnouncementEnds(
        _ book: PlayingBook,
        _ announcement: AVSpeechUtterance,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(book.reader.isWhereAmISpeaking, "\(context): Where Am I? still speaks", file: file, line: line)
        book.reader.whereAmIDelegate?.speechSynthesizer(AVSpeechSynthesizer(), didFinish: announcement)
        handleQueuedCallbacks(file: file, line: line)
        book.endSound.passEndSound()
        XCTAssertFalse(book.isPlaying, "\(context): the announcement's end resumed the book", file: file, line: line)
        XCTAssertTrue(book.isPaused, "\(context): the book is not paused where it was", file: file, line: line)
    }

    /// Has `book`'s Where Am I? announcement, `announcement`, end by itself,
    /// as the synthesizer reports its finish: the announcement is over, and
    /// the book it paused waits, still paused, for the end sound's moment to
    /// pass (`WhereAmIEndSoundClock`) before it resumes.
    private func finishWhereAmIByItself(
        _ book: PlayingBook,
        _ announcement: AVSpeechUtterance,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        book.reader.whereAmIDelegate?.speechSynthesizer(AVSpeechSynthesizer(), didFinish: announcement)
        handleQueuedCallbacks(file: file, line: line)
        XCTAssertFalse(book.reader.isWhereAmISpeaking, "\(book.kind): Where Am I? still speaks", file: file, line: line)
        XCTAssertTrue(book.endSound.hasWorkWaiting, "\(book.kind): nothing waits for the end sound", file: file, line: line)
        XCTAssertTrue(book.isPaused, "\(book.kind): the book resumed before the end sound", file: file, line: line)
    }

    /// Check that whatever paused `book` in the moment after its Where Am
    /// I? announcement ended by itself took the resume the announcement owed
    /// it, and that the book stays paused once the end sound's moment passes.
    private func assertStaysPausedAsTheEndSoundPasses(
        _ book: PlayingBook,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(book.reader.isWhereAmIUnderWay, "\(context): Where Am I? still owes the book its resume", file: file, line: line)
        book.endSound.passEndSound()
        XCTAssertFalse(book.isPlaying, "\(context): the book resumed as the end sound passed", file: file, line: line)
        XCTAssertTrue(book.isPaused, "\(context): the book is not paused where it was", file: file, line: line)
    }

    // MARK: - A Jump During Where Am I?, Its Places

    /// The audiobook a jump test plays: two 30-second tracks, each a chapter
    /// of its own with its heading at its start.
    private static let twoTracks: [TimeInterval] = [30, 30]

    /// A place in a book: a chapter, and an offset in it.
    private typealias Place = (chapter: Int, offset: Int)

    /// Where Next Heading lands from where a playing book of `kind` is: the
    /// text book's Tides heading, later in its one chapter, or the second
    /// track's heading, at the start of the audiobook's next chapter.
    private static func nextHeadingPlace(_ kind: BookKind) -> Place {
        switch kind {
        case .text: return (0, ledgerText.utf16OffsetOfFirst("Tides\n"))
        case .audio: return (1, 0)
        }
    }

    /// The bookmark a jump test picks in a book of `kind`: the 300th tide in
    /// the text book's Tides heading, or five seconds into the audiobook's
    /// second track.
    private static func bookmarkPlace(_ kind: BookKind) -> Place {
        switch kind {
        case .text: return (0, ledgerText.utf16OffsetOfFirst("Tide 300 "))
        case .audio: return (1, Int(5 * ReaderViewModel.audioCharsPerSecond))
        }
    }

    /// Plays a book of `kind` in a world of its own, two tracks for an
    /// audiobook, presses Where Am I? over it, and makes `jump` while the
    /// announcement speaks; then checks that the jump ended the announcement
    /// and that the book plays on from `place`, the system told it plays,
    /// and that the announcement's finish, as the synthesizer then reports
    /// it, changes nothing more: no end sound, nothing left for one, and the
    /// book still playing.
    private func assertAJumpDuringWhereAmIPlaysOn(
        _ kind: BookKind,
        from place: Place,
        _ name: String,
        file: StaticString = #filePath,
        line: UInt = #line,
        jump: (ReaderViewModel) -> Void
    ) throws {
        let context = "\(kind): \(name) during Where Am I?"
        let system = MediaSystem()
        let world = try makeIntegrationWorld("Where Am I Jump \(name) \(kind)")
        let book = try openPlayingBook(kind, in: world, joining: system, audioTracks: Self.twoTracks, file: file, line: line)
        let sounds = recordSounds(of: book, "Where Am I Jump \(name) \(kind)")
        let announcement = try pressWhereAmI(in: book, file: file, line: line)

        jump(book.reader)

        XCTAssertFalse(book.reader.isWhereAmIUnderWay, "\(context): Where Am I? still has the book", file: file, line: line)
        assertPlays(book, from: place, context, file: file, line: line)
        assertToldSystem(system, that: book.reader, plays: true, context, file: file, line: line)

        book.reader.whereAmIDelegate?.speechSynthesizer(AVSpeechSynthesizer(), didFinish: announcement)
        handleQueuedCallbacks(file: file, line: line)

        XCTAssertFalse(book.endSound.hasWorkWaiting, "\(context): the announcement's finish left work for its end sound", file: file, line: line)
        XCTAssertEqual(sounds.played, [.whereAmIStart], "\(context): the announcement's finish made a sound", file: file, line: line)
        XCTAssertTrue(book.isPlaying, "\(context): the announcement's finish stopped the book", file: file, line: line)
    }

    /// Check that `book` plays from `place`: the text book's speech from
    /// that offset, the cursor there (`assertSpeaks`), or the audiobook's
    /// audio from that place in that chapter (`assertPlaysAudio`).
    private func assertPlays(
        _ book: PlayingBook,
        from place: Place,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let text = book.text else {
            assertPlaysAudio(book.reader, inChapter: place.chapter, from: place.offset, context, file: file, line: line)
            return
        }
        XCTAssertEqual(book.reader.currentChapterIndex, place.chapter, "\(context): the cursor is in another chapter", file: file, line: line)
        XCTAssertEqual(book.reader.currentCharacterOffset, place.offset, "\(context): the cursor is not at the place", file: file, line: line)
        assertSpeaks(text, from: place.offset, context, file: file, line: line)
    }

    /// Records the sound effects `book`'s reader asks for from now on, in
    /// place of playing them, in a preferences store named after `label`.
    private func recordSounds(of book: PlayingBook, _ label: String) -> RecordedSoundEffects {
        let sounds = RecordedSoundEffects(preferences: makeSandboxedPreferences(label))
        book.reader.soundEffectService = sounds
        return sounds
    }

    /// Check that `book`'s Where Am I? announcement, `announcement`, ended
    /// with the book as a stop stopped it, and that its finish, as the
    /// synthesizer then reports it, changes nothing: no end sound beside the
    /// start sound `sounds` heard, the book not resumed, and the system told
    /// nothing more, the stop having taken the book out of Now Playing, so
    /// the AirPods are no longer the book's.
    private func assertWhereAmIEndedWithTheStop(
        _ book: PlayingBook,
        _ announcement: AVSpeechUtterance,
        system: MediaSystem,
        sounds: RecordedSoundEffects,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let reader = book.reader
        XCTAssertFalse(reader.isWhereAmISpeaking, "\(context): Where Am I? still speaks", file: file, line: line)
        let toldAtTheStop = system.told.count

        reader.whereAmIDelegate?.speechSynthesizer(AVSpeechSynthesizer(), didFinish: announcement)
        handleQueuedCallbacks(file: file, line: line)

        XCTAssertEqual(sounds.played, [.whereAmIStart], "\(context): the announcement's finish made a sound", file: file, line: line)
        XCTAssertFalse(book.isPlaying, "\(context): the book plays", file: file, line: line)
        XCTAssertEqual(system.told.count, toldAtTheStop, "\(context): the system was told more: \(system.told)", file: file, line: line)
        XCTAssertEqual(system.told.last, .some(nil), "\(context): the stop left the book in Now Playing", file: file, line: line)
        XCTAssertFalse(
            system.coordinator.holdsMediaControls(ownerID: reader.nowPlayingService.ownerID),
            "\(context): the book holds the media controls",
            file: file,
            line: line
        )
        XCTAssertNil(system.coordinator.playingOwnerID, "\(context): a book is shown playing", file: file, line: line)
    }

    // MARK: - Checks

    /// Check that `book`'s speech plays from `offset` of its chapter at full
    /// volume: speaking, not paused, and the utterance handed over last is
    /// the first chunk direct speech speaks from there.
    private func assertSpeaks(
        _ book: TextBookReader,
        from offset: Int,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let speech = book.reader.speechService
        XCTAssertTrue(speech.isSpeaking, "\(context): speech is not playing", file: file, line: line)
        XCTAssertFalse(speech.isPaused, "\(context): speech is paused", file: file, line: line)
        let expected = DirectSpeechChunk.starting(
            at: offset,
            in: book.text,
            maximumLength: SpeechService.directModeFirstChunkSize
        ).words(of: book.text)
        let spoken = book.handedOver.utterances.last
        XCTAssertEqual(
            spoken?.speechString.prefix(60),
            expected.prefix(60),
            "\(context): speech does not start at the place",
            file: file,
            line: line
        )
        XCTAssertEqual(spoken?.volume, 1, "\(context): speech is not at full volume", file: file, line: line)
    }

    /// Check that `reader`'s audio plays from `offset` of chapter
    /// `chapterIndex`, the last by default: the player playing, not paused,
    /// the reader showing Playing, and the cursor and the player within a
    /// second of the place.
    private func assertPlaysAudio(
        _ reader: ReaderViewModel,
        inChapter chapterIndex: Int = 1,
        from offset: Int,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let audio = reader.audioPlaybackService
        XCTAssertTrue(audio.isPlaying && !audio.isPaused, "\(context): the audio is not playing", file: file, line: line)
        XCTAssertTrue(
            reader.isCurrentlyPlaying && !reader.isCurrentlyPaused,
            "\(context): the reader does not show Playing",
            file: file,
            line: line
        )
        XCTAssertEqual(reader.currentChapterIndex, chapterIndex, "\(context): the cursor is in another chapter", file: file, line: line)
        XCTAssertLessThanOrEqual(
            abs(reader.currentCharacterOffset - offset),
            Int(ReaderViewModel.audioCharsPerSecond),
            "\(context): the cursor is not at the place",
            file: file,
            line: line
        )
        let seconds = Double(offset) / ReaderViewModel.audioCharsPerSecond
        XCTAssertTrue(
            eventually(within: 2) { abs(audio.currentTime - seconds) <= 1.5 },
            "\(context): the audio does not play from the place",
            file: file,
            line: line
        )
    }

    /// Check what the system was last told: `reader`'s book, playing or
    /// paused as `playing` says, never that playback stopped; that
    /// `reader` owns media controls, as the playing reader when it plays;
    /// and that no command was dropped after it was accepted.
    private func assertToldSystem(
        _ system: MediaSystem,
        that reader: ReaderViewModel,
        plays playing: Bool,
        _ context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let shown = NowPlayingItem(title: reader.book.title, author: reader.book.author, isPlaying: playing)
        XCTAssertEqual(system.told.last, .some(shown), "\(context): the system was told otherwise", file: file, line: line)
        XCTAssertFalse(system.told.contains(nil), "\(context): the system was told playback stopped", file: file, line: line)
        let owner = reader.nowPlayingService.ownerID
        XCTAssertEqual(system.coordinator.activeOwnerID, owner, "\(context): another reader owns media controls", file: file, line: line)
        XCTAssertEqual(
            system.coordinator.playingOwnerID,
            playing ? owner : nil,
            "\(context): the playing owner is wrong",
            file: file,
            line: line
        )
        XCTAssertEqual(system.droppedCommands, [], "\(context): a command was dropped", file: file, line: line)
    }
}

private extension String {
    /// The UTF-16 offset where `fragment` first occurs; 0 when it does not.
    func utf16OffsetOfFirst(_ fragment: String) -> Int {
        let found = (self as NSString).range(of: fragment)
        return found.location == NSNotFound ? 0 : found.location
    }
}
