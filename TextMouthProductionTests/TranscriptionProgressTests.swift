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
}
