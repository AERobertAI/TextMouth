import XCTest
@testable import TextMouth

/// Selecting without a waveform in the audio editor (FR04), on generated
/// audio through the real edit session, with a player that makes no sound:
/// In and Out at the cursor, each change announced by its length and the
/// whole said on request; a phrase, from the cursor to a pause; the
/// chapter the cursor is in; everything, or nothing; playing the
/// selection; and markers dropped, named, gone to, and deleted, beside the
/// pauses in the list.
@MainActor
final class AudioEditorSelectingTests: XCTestCase {

    // MARK: - In and Out

    /// In and Out at the cursor make a selection, each saying where it is
    /// and how long the selection is; the status line shows it in clock
    /// times and Speak Selection says it in words.
    func testInAndOutMakeASelectionAndSayIt() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        model.move(to: 2)
        model.perform(.editorMarkIn)
        XCTAssertEqual(harness.announcements.sentences.last, "In at 2 seconds. Selected 8 seconds.")
        XCTAssertEqual(model.selection, AudioTimeRange(start: 2, end: 10))

        model.move(to: 5.5)
        model.perform(.editorMarkOut)
        XCTAssertEqual(harness.announcements.sentences.last, "Out at 5.5 seconds. Selected 3.5 seconds.")
        XCTAssertEqual(model.selection, AudioTimeRange(start: 2, end: 5.5))
        XCTAssertEqual(model.statusSentence, "5.5 seconds of 10 seconds; selection from 0:02 to 0:05.5, 3.5 seconds")

        model.perform(.editorSpeakSelection)
        XCTAssertEqual(harness.announcements.sentences.last, "Selection from 2 seconds to 5.5 seconds; 3.5 seconds long.")
    }

    /// Out alone selects from the start; In marked at or after Out clears
    /// Out, so the selection runs forward to the end.
    func testOneEndAloneSelectsToTheOtherEndOfTheAudio() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        model.move(to: 3)
        model.perform(.editorMarkOut)
        XCTAssertEqual(model.selection, AudioTimeRange(start: 0, end: 3))
        XCTAssertEqual(harness.announcements.sentences.last, "Out at 3 seconds. Selected 3 seconds.")

        model.move(to: 4)
        model.perform(.editorMarkIn)
        XCTAssertNil(model.selectionEnd)
        XCTAssertEqual(model.selection, AudioTimeRange(start: 4, end: 10))

        model.move(to: 4)
        model.perform(.editorMarkOut)
        XCTAssertNil(model.selectionStart, "an Out at In kept the In")
        XCTAssertEqual(model.selection, AudioTimeRange(start: 0, end: 4))
    }

    /// Select All, Select Chapter, and Clear Selection each say what they
    /// did; before the first chapter marker, Select Chapter selects the
    /// audio before it.
    func testSelectAllTheChapterOrNothing() async throws {
        let harness = try await openRamp(seconds: 30)
        let model = harness.model
        model.perform(.editorSelectChapter)
        XCTAssertEqual(harness.announcements.sentences.last, "This audio has no chapter markers.")

        try await model.session.perform(.setChapter(at: 5, title: "Quay"))
        try await model.session.perform(.setChapter(at: 12, title: "Locks"))
        model.move(to: 2)
        model.perform(.editorSelectChapter)
        XCTAssertEqual(model.selection, AudioTimeRange(start: 0, end: 5))
        XCTAssertEqual(harness.announcements.sentences.last, "Selected the 5 seconds before chapter 1.")
        model.move(to: 14)
        model.perform(.editorSelectChapter)
        XCTAssertEqual(model.selection, AudioTimeRange(start: 12, end: 30))
        XCTAssertEqual(harness.announcements.sentences.last, "Selected chapter 2: Locks, 18 seconds.")

        model.perform(.editorSelectAll)
        XCTAssertEqual(model.selection, AudioTimeRange(start: 0, end: 30))
        XCTAssertEqual(harness.announcements.sentences.last, "Selected all 30 seconds.")
        XCTAssertTrue(model.canPerform(.editorClearSelection))

        model.perform(.editorClearSelection)
        XCTAssertNil(model.selection)
        XCTAssertEqual(harness.announcements.sentences.last, "Selection cleared.")
        XCTAssertFalse(model.canPerform(.editorClearSelection))
        model.perform(.editorClearSelection)
        XCTAssertEqual(harness.announcements.sentences.last, "Nothing is selected.")
        model.perform(.editorSpeakSelection)
        XCTAssertEqual(harness.announcements.sentences.last, "Nothing is selected.")
    }

    /// From the start of a phrase, Select to Next Pause selects it with the
    /// pause after it; from its end, Select to Previous Pause selects the
    /// same phrase back to its start.
    func testAPhraseIsSelectedFromPauseToPause() async throws {
        let fixture = try AudioEditorTestBook.make(named: "Phrases.wav", for: self) { url in
            try AudioTestFixtures.writeTones([
                .init(seconds: 1, frequency: 440, amplitude: 0.3),
                .silence(0.8),
                .init(seconds: 1.5, frequency: 330, amplitude: 0.3),
                .silence(0.5),
                .init(seconds: 1, frequency: 550, amplitude: 0.3),
            ], to: url, sampleRate: AudioEditorTestBook.rate)
        }
        let harness = try await EditorHarness.open(fixture, for: self)
        AudioEditorPreferences.playAfterMoves.write(false, to: harness.store)
        let model = harness.model
        defer { model.windowClosed() }
        await model.loadPreview()
        let found = await eventually(timeout: 10) { model.pauseSearch == .found }
        XCTAssertTrue(found, "the pauses were never found")

        model.perform(.editorNextPause)
        model.perform(.editorSelectToNextPause)
        XCTAssertEqual(model.selection?.start ?? -1, 1.8, accuracy: 0.011)
        XCTAssertEqual(model.selection?.end ?? -1, 3.8, accuracy: 0.011)
        XCTAssertEqual(harness.announcements.sentences.last, "Selected 2 seconds.")

        model.perform(.editorClearSelection)
        model.perform(.editorNextPause)
        model.perform(.editorSelectToPreviousPause)
        XCTAssertEqual(model.selection?.start ?? -1, 1.8, accuracy: 0.011)
        XCTAssertEqual(model.selection?.end ?? -1, 3.8, accuracy: 0.011)
    }

    /// Play Selection plays from its start to its end, and the cursor stops
    /// there, with nothing said of the end of the audio.
    func testPlaySelectionStopsAtItsEnd() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        model.perform(.editorPlaySelection)
        XCTAssertEqual(harness.announcements.sentences.last, "Nothing is selected.")
        XCTAssertFalse(model.canPerform(.editorPlaySelection))

        model.select(AudioTimeRange(start: 2, end: 5))
        model.perform(.editorPlaySelection)
        XCTAssertEqual(harness.player.plays.last, .init(from: 2, until: 5))
        XCTAssertTrue(model.isPlaying)
        harness.player.tick(to: 3)
        XCTAssertEqual(model.cursor, 3)
        harness.player.finishPlaying(at: 5)
        XCTAssertEqual(model.cursor, 5)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(harness.announcements.sentences.last, "Selected 3 seconds.")
    }

    // MARK: - Markers

    /// Markers are dropped at the cursor at once, numbered in time order,
    /// named, gone to, and deleted, each saying so.
    func testMarkersAreDroppedNamedVisitedAndDeleted() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        model.move(to: 3)
        model.perform(.editorAddMarker)
        XCTAssertEqual(harness.announcements.sentences.last, "Marker 1 at 3 seconds.")
        model.move(to: 1)
        model.perform(.editorAddMarker)
        XCTAssertEqual(harness.announcements.sentences.last, "Marker 1 at 1 second.")
        XCTAssertEqual(model.orderedMarkers.map(\.time), [1, 3])

        let later = try XCTUnwrap(model.orderedMarkers.last)
        model.renameMarker(later.id, to: "  Intro ")
        XCTAssertEqual(harness.announcements.sentences.last, "Marker 2 named Intro.")
        model.perform(.editorShowMarkers)
        XCTAssertEqual(model.sheet, .markers)
        model.goToMarker(later.id)
        XCTAssertNil(model.sheet)
        XCTAssertEqual(model.cursor, 3)
        XCTAssertEqual(harness.announcements.sentences.last, "Marker 2, Intro, at 3 seconds.")

        let earlier = try XCTUnwrap(model.orderedMarkers.first)
        model.deleteMarker(earlier.id)
        XCTAssertEqual(harness.announcements.sentences.last, "Marker 1 deleted.")
        XCTAssertEqual(model.markers.map(\.name), ["Intro"])
        model.renameMarker(later.id, to: "")
        XCTAssertEqual(harness.announcements.sentences.last, "Marker 1 has no name now.")
    }

    /// The list's pauses go to where the sound after them begins, or
    /// select the pause itself, closing the list.
    func testThePausesInTheListAreGoneToOrSelected() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        let pause = AudioEditorPause(start: 4, end: 5.5)
        model.sheet = .markers

        model.selectPause(pause)
        XCTAssertNil(model.sheet)
        XCTAssertEqual(model.selection, AudioTimeRange(start: 4, end: 5.5))
        XCTAssertEqual(model.cursor, 4)

        model.sheet = .markers
        model.goToPause(pause)
        XCTAssertNil(model.sheet)
        XCTAssertEqual(model.cursor, 5.5)
        XCTAssertEqual(harness.announcements.sentences.last, "After a pause of 1.5 seconds, at 5.5 seconds.")
        XCTAssertEqual(AudioEditorWording.pauseRow(2, pause), "Pause 2, 1.5 seconds, at 4 seconds")
        XCTAssertEqual(AudioEditorWording.rowButton("Delete", "Marker 3"), "Delete Marker 3")
    }
}
