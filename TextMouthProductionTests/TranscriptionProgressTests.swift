import Combine
import XCTest
@testable import TextMouth

/// A transcription's progress and end (FR05): the sheet's file count,
/// seconds done of the total, and progress bar value, shown at most four
/// times a second; VoiceOver hearing the start, each quarter once, and the
/// end; an open reader of the book showing its text once it is saved; and
/// the library row's note. Every transcription is heard by a scripted
/// engine, never the system's recognizer.
@MainActor
final class TranscriptionProgressTests: XCTestCase {

    // MARK: - The Progress Sheet's Words

    /// The progress lines name the file being transcribed, out of how many,
    /// and the audio done of the whole; the bar's value, which VoiceOver
    /// reads, gives the percent and the file; before the first file begins,
    /// the sheet says it is starting.
    func testTheProgressIsWordedByFileSecondsAndPercent() {
        let partway = TranscriptionProgress(fileIndex: 2, fileCount: 12, secondsDone: 2_400, secondsTotal: 22_320, elapsed: 12)
        let done = TranscriptionProgress(fileIndex: 12, fileCount: 12, secondsDone: 22_320, secondsTotal: 22_320, elapsed: 340)

        XCTAssertEqual(TranscriptionWording.fileLine(partway), "File 3 of 12")
        XCTAssertEqual(TranscriptionWording.secondsLine(partway), "40 minutes of 6 hours, 12 minutes transcribed")
        XCTAssertEqual(TranscriptionWording.progressValue(partway), "10 percent, file 3 of 12")
        XCTAssertEqual(TranscriptionWording.fileLine(done), "All 12 files")
        XCTAssertEqual(TranscriptionWording.progressValue(done), "100 percent, all 12 files")
        XCTAssertEqual(TranscriptionWording.progressValue(nil), "Starting")
        XCTAssertEqual(TranscriptionWording.elapsedLine(12), "Elapsed: 12 seconds")
        XCTAssertEqual(TranscriptionWording.progressLabel, "Transcription progress")
        XCTAssertEqual(
            TranscriptionWording.started(bookTitle: "Moby-Dick", audioSeconds: 3_060),
            "Transcribing Moby-Dick, about 1 minute."
        )
        XCTAssertEqual(TranscriptionWording.milestone(bookTitle: "Moby-Dick", percent: 25), "Moby-Dick: 25 percent transcribed.")
    }

    /// The sheet showing a transcription follows its progress: it says it
    /// is starting before the first file begins, then names the file and
    /// the seconds done, and the bar's value follows.
    func testTheSheetFollowsTheTranscriptionsProgress() async throws {
        let world = try makeIntegrationWorld("Transcription Progress Sheet")
        let book = try world.makeSilentAudioBook(title: "Long Pier Recordings", trackDurations: [20])
        let center = makeScriptedCenter(script: TranscriptionUIScripts.longTrack, pause: .milliseconds(40))
        let model = TranscriptionSheetModel(request: .book(book), library: world.library, services: makeSheetServices(center: center))
        await model.load()

        model.transcribe()

        XCTAssertEqual(model.progressLines, ["Starting…"])
        XCTAssertEqual(model.progressValue, "Starting")
        XCTAssertNotNil(model.transcriptionStartedAt)
        let moved = await eventuallyHolds { (model.progress?.secondsDone ?? 0) > 0 }
        XCTAssertTrue(moved, "the sheet never showed the transcription's progress")
        let progress = try XCTUnwrap(model.progress)
        XCTAssertEqual(model.progressLines, [
            "File 1 of 1",
            "\(TimeFormatting.spoken(progress.secondsDone)) of 20 seconds transcribed",
        ])
        XCTAssertEqual(model.progressValue, "\(progress.percentDone) percent, file 1 of 1")
        center.cancel()
        let ended = await eventuallyHolds { center.current == nil }
        XCTAssertTrue(ended, "the transcription never stopped")
    }

    // MARK: - What VoiceOver Hears

    /// VoiceOver hears the transcription start, each quarter it passes once,
    /// and its end with the words it found.
    func testEachQuarterIsAnnouncedOnceBetweenTheStartAndTheEnd() async throws {
        let world = try makeIntegrationWorld("Transcription Milestones")
        let book = try world.makeSilentAudioBook(title: "Breakwater Notes", trackDurations: [3, 2])
        let center = makeScriptedCenter(script: TranscriptionUIScripts.twoTracks)
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        XCTAssertTrue(center.start(book, language: "en-US", library: world.library, window: nil))
        let ended = await eventuallyHolds { center.current == nil }

        XCTAssertTrue(ended, "the transcription never ended")
        let messages = announcements.messages
        XCTAssertEqual(Array(messages.dropLast()), [
            "Transcribing Breakwater Notes.",
            "Breakwater Notes: 25 percent transcribed.",
            "Breakwater Notes: 50 percent transcribed.",
            "Breakwater Notes: 75 percent transcribed.",
        ])
        XCTAssertTrue(messages.last?.hasPrefix("Transcribed Breakwater Notes: 17 words in ") == true, "\(messages)")
    }

    /// Results arriving many times a second are shown at most four times a
    /// second, whenever the transcription moves to another file, and once
    /// it is done.
    func testProgressIsShownAtMostFourTimesASecond() async throws {
        let world = try makeIntegrationWorld("Transcription Progress Rate")
        let book = try world.makeSilentAudioBook(title: "Long Pier Recordings", trackDurations: [20])
        let center = makeScriptedCenter(script: TranscriptionUIScripts.longTrack)
        var shown: [TranscriptionProgress] = []
        let subscription = center.$current.sink { job in
            if let progress = job?.progress {
                shown.append(progress)
            }
        }
        defer { subscription.cancel() }

        XCTAssertTrue(center.start(book, language: "en-US", library: world.library, window: nil))
        let ended = await eventuallyHolds { center.current == nil }

        XCTAssertTrue(ended, "the transcription never ended")
        XCTAssertLessThan(shown.count, TranscriptionUIScripts.longTrack["01.wav", default: []].count,
                          "every result was shown: \(shown.count)")
        XCTAssertEqual(shown.last?.fractionDone, 1, "the end was not shown")
        XCTAssertEqual(shown.first?.fileIndex, 0)
    }

    // MARK: - The Debug Log

    /// A transcription writes one line as it starts, with its language, and
    /// one as it finishes, with the words it found and the seconds it took,
    /// each naming the book by its title and never quoting a word heard.
    func testATranscriptionLogsItsStartAndItsWordsAndSeconds() async throws {
        let title = "Gull Rock Soundings \(UUID().uuidString.prefix(8))"
        let world = try makeIntegrationWorld("Transcription Log Finished")
        let book = try world.makeSilentAudioBook(title: title, trackDurations: [3, 2])
        let center = makeScriptedCenter(script: TranscriptionUIScripts.twoTracks)

        XCTAssertTrue(center.start(book, language: "en-US", library: world.library, window: nil))
        let ended = await eventuallyHolds { center.current == nil }

        XCTAssertTrue(ended, "the transcription never ended")
        let lines = debugLogLines(containing: title)
        XCTAssertEqual(lines.filter { $0.contains("TRANSCRIPTION_STARTED: \(title): en-US") }.count, 1, "\(lines)")
        let finished = lines.filter { $0.contains("TRANSCRIPTION_FINISHED: \(title): 17 words in ") }
        XCTAssertEqual(finished.count, 1, "\(lines)")
        XCTAssertTrue(finished.first?.hasSuffix(" seconds") == true, "\(finished)")
        assertQuotesNothingHeard(lines)
    }

    /// A transcription cancelled, or one that fails, writes how long it ran
    /// and, for a failure, why, in the words VoiceOver hears; neither
    /// quotes a word heard.
    func testACancelledOrFailedTranscriptionLogsHowItEnded() async throws {
        let world = try makeIntegrationWorld("Transcription Log Ended")
        let cancelledTitle = "Long Pier Recordings \(UUID().uuidString.prefix(8))"
        let cancelled = try world.makeSilentAudioBook(title: cancelledTitle, trackDurations: [20])
        let slow = makeScriptedCenter(script: TranscriptionUIScripts.longTrack, pause: .milliseconds(50))
        XCTAssertTrue(slow.start(cancelled, language: "en-US", library: world.library, window: nil))
        slow.cancel()
        let cancelEnded = await eventuallyHolds { slow.current == nil }
        XCTAssertTrue(cancelEnded, "the cancelled transcription never ended")

        let failedTitle = "Breakwater Notes \(UUID().uuidString.prefix(8))"
        let failing = try world.makeSilentAudioBook(title: failedTitle, trackDurations: [3, 2])
        let refusing = makeScriptedCenter(script: [:], refusal: .recognitionFailed("the recognizer stopped"))
        XCTAssertTrue(refusing.start(failing, language: "en-US", library: world.library, window: nil))
        let failEnded = await eventuallyHolds { refusing.current == nil }
        XCTAssertTrue(failEnded, "the failing transcription never ended")

        let cancelledLines = debugLogLines(containing: cancelledTitle)
        XCTAssertEqual(
            cancelledLines.filter { $0.contains("TRANSCRIPTION_CANCELLED: \(cancelledTitle): after ") && $0.hasSuffix(" seconds") }.count,
            1,
            "\(cancelledLines)"
        )
        let failedLines = debugLogLines(containing: failedTitle)
        XCTAssertEqual(
            failedLines.filter {
                $0.contains("TRANSCRIPTION_FAILED: \(failedTitle): after ")
                    && $0.hasSuffix(" seconds: Transcription stopped: the recognizer stopped.")
            }.count,
            1,
            "\(failedLines)"
        )
        assertQuotesNothingHeard(cancelledLines + failedLines)
    }

    /// The lines' words: the word count in words, one word or many, and
    /// every time to a tenth of a second.
    func testTheLogLinesSayTheWordsAndTheTime() {
        XCTAssertEqual(TranscriptionLog.started(bookTitle: "Harbor Notes", language: "en-GB"), "TRANSCRIPTION_STARTED: Harbor Notes: en-GB")
        XCTAssertEqual(
            TranscriptionLog.ended(.finished(wordCount: 1, seconds: 2.44), bookTitle: "Harbor Notes", elapsed: 9),
            "TRANSCRIPTION_FINISHED: Harbor Notes: 1 word in 2.4 seconds"
        )
        XCTAssertEqual(
            TranscriptionLog.ended(.finished(wordCount: 1_204, seconds: 61), bookTitle: "Harbor Notes", elapsed: 9),
            "TRANSCRIPTION_FINISHED: Harbor Notes: 1204 words in 61.0 seconds"
        )
        XCTAssertEqual(
            TranscriptionLog.ended(.cancelled, bookTitle: "Harbor Notes", elapsed: 0.96),
            "TRANSCRIPTION_CANCELLED: Harbor Notes: after 1.0 seconds"
        )
        XCTAssertEqual(
            TranscriptionLog.ended(.failed("Transcription stopped: the recognizer stopped."), bookTitle: "Harbor Notes", elapsed: 0.3),
            "TRANSCRIPTION_FAILED: Harbor Notes: after 0.3 seconds: Transcription stopped: the recognizer stopped."
        )
    }

    /// Fails when any of `lines` quotes a word the scripted narration says.
    private func assertQuotesNothingHeard(_ lines: [String], file: StaticString = #filePath, line: UInt = #line) {
        for word in ["Gannet", "breakwater.", "coils", "ferry", "Buoy", "tilts"] {
            XCTAssertFalse(lines.contains { $0.contains(word) }, "\(word) reached the log: \(lines)", file: file, line: line)
        }
    }

    // MARK: - After the Transcript Is Saved

    /// A reader with the book open shows the transcript's text once it is
    /// saved, at the sentence heard where its cursor stands, as the book
    /// plays on from where it was.
    func testAnOpenReaderShowsTheTextOnceTheTranscriptIsSaved() async throws {
        let world = try makeIntegrationWorld("Transcription Reader")
        let book = try world.makeSilentAudioBook(title: "Breakwater Notes", trackDurations: [3, 2])
        let reader = world.openReader(for: book)
        let loaded = await eventuallyHolds { !reader.isLoading }
        XCTAssertTrue(loaded, "the reader never loaded")
        XCTAssertNil(reader.content?.transcript)
        let chapterBefore = reader.currentChapterIndex
        let offsetBefore = reader.currentCharacterOffset
        let center = makeScriptedCenter(script: TranscriptionUIScripts.twoTracks)

        XCTAssertTrue(center.start(book, language: "en-US", library: world.library, window: nil))
        let shown = await eventuallyHolds { reader.content?.transcript != nil }

        XCTAssertTrue(shown, "the reader never showed the transcript")
        XCTAssertEqual(reader.content?.transcript?.chapterText(0), "01\n\nGannet wings fold over the breakwater. "
            + "Rope coils dry on the pier.")
        XCTAssertTrue(reader.displayVisibleTextWindow.contains("Gannet wings fold over the breakwater."),
                      "the text shown: \(reader.displayVisibleTextWindow.count) characters")
        XCTAssertEqual(reader.currentChapterIndex, chapterBefore)
        XCTAssertEqual(reader.currentCharacterOffset, offsetBefore)
        let ended = await eventuallyHolds { center.current == nil }
        XCTAssertTrue(ended, "the transcription never ended")
    }

    /// A transcript text that changes while the reader still loads is shown
    /// once loading ends, rather than lost behind what the load read.
    func testATranscriptArrivingWhileTheReaderLoadsIsShownAfterwards() async throws {
        let world = try makeIntegrationWorld("Transcription Reader Loading")
        let book = try world.makeSilentAudioBook(title: "Breakwater Notes", trackDurations: [3, 2])
        let transcript = try TranscriptFixtures.transcript(of: book, sentences: TranscriptionUIScripts.twoTracks)
        let installation = try TranscriptStore.install(transcript, for: book)
        let reader = world.openReader(for: book)
        XCTAssertTrue(reader.isLoading)

        reader.showTranscript(nil)

        XCTAssertNotNil(reader.transcriptWaitingForLoad)
        let loaded = await eventuallyHolds { !reader.isLoading }
        XCTAssertTrue(loaded, "the reader never loaded")
        XCTAssertNil(reader.transcriptWaitingForLoad)
        XCTAssertNil(reader.content?.transcript, "the change made while loading was lost")
        reader.showTranscript(installation.text)
        XCTAssertEqual(reader.content?.transcript?.chapterText(1), "02\n\nThe ferry bell rings twice.")
    }

    /// The library row says "Transcribed" after the cloud notes, and
    /// "Transcribing" while the book is transcribed, shown and spoken; a
    /// book without a transcript says neither.
    func testTheRowSaysTranscribedOrTranscribing() {
        let book = TranscriptionSheetTests.audiobook("Harbour Bells")

        let transcribed = BookRow(book: book, transcriptionNote: .transcribed).rowAccessibilityLabel
        let transcribing = BookRow(book: book, cloudState: .downloaded, transcriptionNote: .transcribing).rowAccessibilityLabel
        let plain = BookRow(book: book).rowAccessibilityLabel

        XCTAssertEqual(transcribed, "Harbour Bells, by Unknown, New, Transcribed, Audio")
        XCTAssertTrue(transcribing.contains(", Transcribing, "), transcribing)
        XCTAssertLessThan(
            transcribing.range(of: "Downloaded")?.lowerBound ?? transcribing.endIndex,
            transcribing.range(of: "Transcribing")?.lowerBound ?? transcribing.startIndex,
            "the cloud note comes first"
        )
        XCTAssertFalse(plain.contains("Transcrib"), plain)
        XCTAssertEqual(TranscriptionRowNote.transcribed.text, "Transcribed")
        XCTAssertEqual(TranscriptionRowNote.transcribing.text, "Transcribing")
    }

    /// The store finds each audiobook's transcript by looking for its
    /// transcript.json, leaves text books alone, follows a transcript
    /// deleted, and gives each row its note; a transcription under way
    /// makes its row say so, and the saved transcript is recorded at once.
    func testTheStoreFindsTranscriptsAndGivesEachRowItsNote() async throws {
        let world = try makeIntegrationWorld("Transcribed Books")
        let transcribed = try world.makeSilentAudioBook(title: "Breakwater Notes", trackDurations: [3, 2])
        let untranscribed = try world.makeSilentAudioBook(title: "Long Pier Recordings", trackDurations: [1])
        try TranscriptStore.install(
            try TranscriptFixtures.transcript(of: transcribed, sentences: TranscriptionUIScripts.twoTracks),
            for: transcribed
        )
        let store = TranscribedBooks()

        await store.refresh([transcribed, untranscribed])

        XCTAssertEqual(store.bookIDs, [transcribed.id])
        XCTAssertEqual(store.note(for: transcribed.id), .transcribed)
        XCTAssertNil(store.note(for: untranscribed.id))

        store.setTranscribing(untranscribed.id)
        XCTAssertEqual(store.note(for: untranscribed.id), .transcribing)
        store.record(untranscribed.id, isTranscribed: true)
        store.setTranscribing(nil)
        XCTAssertEqual(store.note(for: untranscribed.id), .transcribed)

        try FileManager.default.removeItem(at: TextMouthPaths.transcriptPath(in: transcribed.tmbDirectory))
        await store.refresh([transcribed])
        XCTAssertEqual(store.bookIDs, [], "a book no longer looked at, or without a transcript, kept its note")
    }

    /// A transcription records its book in the store it was given: the row
    /// says "Transcribing" while it runs, and "Transcribed" once its
    /// transcript is saved.
    func testATranscriptionMarksItsRowWhileItRunsAndOnceSaved() async throws {
        let world = try makeIntegrationWorld("Transcription Row Note")
        let book = try world.makeSilentAudioBook(title: "Breakwater Notes", trackDurations: [3, 2])
        let store = TranscribedBooks()
        let center = makeScriptedCenter(script: TranscriptionUIScripts.twoTracks, transcribedBooks: store)

        XCTAssertTrue(center.start(book, language: "en-US", library: world.library, window: nil))

        XCTAssertEqual(store.note(for: book.id), .transcribing)
        let ended = await eventuallyHolds { center.current == nil }
        XCTAssertTrue(ended, "the transcription never ended")
        XCTAssertEqual(store.note(for: book.id), .transcribed)
        XCTAssertNil(store.transcribingBookID)
    }

    // MARK: - The Edit Text Session

    /// An install that fails after the book's Edit Text session was paused
    /// begins the session again, once, for the book, so the user's later
    /// saves are still taken.
    func testAFailedInstallResumesTheEditTextSession() async throws {
        let world = try makeIntegrationWorld("Transcription Install Fails")
        let book = try world.makeSilentAudioBook(title: "Breakwater Notes", trackDurations: [3, 2])
        let paused = CallLog<UUID>()
        let resumed = CallLog<UUID>()
        let center = makeScriptedCenter(
            script: TranscriptionUIScripts.twoTracks,
            install: { _, _ in throw InstallFailure() },
            pauseTextEdit: { paused.record($0.id); return true },
            resumeTextEdit: { resumed.record($0.id) }
        )

        XCTAssertTrue(center.start(book, language: "en-US", library: world.library, window: nil))
        let ended = await eventuallyHolds { center.current == nil }

        XCTAssertTrue(ended, "the transcription never ended")
        XCTAssertEqual(paused.calls, [book.id])
        XCTAssertEqual(resumed.calls, [book.id])
        guard case .failed(_)? = center.lastEnding?.ending else {
            return XCTFail("the transcription did not end as failed: \(String(describing: center.lastEnding))")
        }
    }

    /// An install that works leaves the session ended: the new transcript
    /// replaced the text it watched, and nothing begins it again. A book not
    /// being edited is never resumed either, even when the install fails.
    func testASavedTranscriptDoesNotResumeTheEditTextSession() async throws {
        let world = try makeIntegrationWorld("Transcription Install Works")
        let book = try world.makeSilentAudioBook(title: "Breakwater Notes", trackDurations: [3, 2])
        let paused = CallLog<UUID>()
        let resumed = CallLog<UUID>()
        let center = makeScriptedCenter(
            script: TranscriptionUIScripts.twoTracks,
            pauseTextEdit: { paused.record($0.id); return true },
            resumeTextEdit: { resumed.record($0.id) }
        )

        XCTAssertTrue(center.start(book, language: "en-US", library: world.library, window: nil))
        let ended = await eventuallyHolds { center.current == nil }

        XCTAssertTrue(ended, "the transcription never ended")
        XCTAssertEqual(paused.calls, [book.id])
        XCTAssertEqual(resumed.calls, [])

        // A book that was not being edited: the pause says so, and a failed install resumes nothing.
        let other = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [3, 2])
        let notEditing = makeScriptedCenter(
            script: TranscriptionUIScripts.twoTracks,
            install: { _, _ in throw InstallFailure() },
            pauseTextEdit: { _ in false },
            resumeTextEdit: { resumed.record($0.id) }
        )
        XCTAssertTrue(notEditing.start(other, language: "en-US", library: world.library, window: nil))
        let endedAgain = await eventuallyHolds { notEditing.current == nil }
        XCTAssertTrue(endedAgain, "the second transcription never ended")
        XCTAssertEqual(resumed.calls, [])
    }

    /// The error a test's install fails with.
    private struct InstallFailure: Error {}
}
