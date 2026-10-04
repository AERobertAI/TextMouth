import XCTest
@testable import TextMouth

/// Selecting without a waveform in the audio editor (FR04), on generated
/// audio through the real edit session, with a player that makes no sound:
/// In and Out at the cursor, each change announced by its length and the
/// whole said on request; a phrase, from the cursor to a pause; the
/// chapter the cursor is in; everything, or nothing; playing the
/// selection; and markers dropped, named, gone to, and deleted, beside the
/// pauses in the list, kept in the file's edit list for the next window,
/// and deleted by Revert to Original.
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

    // MARK: - Markers Kept

    /// Markers dropped and named are kept in the file's edit list, and the
    /// next window on the book shows them again, in its list too.
    func testMarkersAreKeptAndComeBackWhenTheWindowReopens() async throws {
        let fixture = try AudioEditorTestBook.ramp(seconds: 10, for: self)
        let first = try await EditorHarness.open(fixture, for: self)
        AudioEditorPreferences.playAfterMoves.write(false, to: first.store)
        first.model.move(to: 7)
        first.model.addMarker()
        first.model.move(to: 3)
        first.model.addMarker()
        let later = try XCTUnwrap(first.model.orderedMarkers.last)
        first.model.renameMarker(later.id, to: "Weir")
        await first.model.session.markersKept()
        XCTAssertFalse(first.model.session.isKeepingMarkers)
        first.model.windowClosed()

        XCTAssertEqual(try keptMarkers(of: fixture).map(\.time), [7, 3], "kept in the order they were dropped")
        let second = try await EditorHarness.open(fixture, for: self)
        addTeardownBlock { @MainActor in second.model.windowClosed() }
        XCTAssertEqual(second.model.orderedMarkers.map(\.time), [3, 7])
        XCTAssertEqual(second.model.orderedMarkers.map(\.name), ["", "Weir"])
        XCTAssertEqual(second.model.orderedMarkers.map(\.id), first.model.orderedMarkers.map(\.id))
        second.model.perform(.editorShowMarkers)
        XCTAssertEqual(second.model.sheet, .markers)
        let restored = try XCTUnwrap(second.model.orderedMarkers.last)
        second.model.goToMarker(restored.id)
        XCTAssertEqual(second.announcements.sentences.last, "Marker 2, Weir, at 7 seconds.")
    }

    /// Markers moved by an edit, and back by its undo, are kept where they
    /// moved; markers dropped just before a save are kept with it.
    func testMarkersMovedByEditsAreKeptWhereTheyMoved() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        model.move(to: 3)
        model.addMarker()
        model.move(to: 6)
        model.addMarker()
        model.select(AudioTimeRange(start: 2, end: 4))

        await model.cut()
        await model.session.markersKept()
        XCTAssertEqual(try keptMarkers(of: harness.fixture).map(\.time), [2, 4])
        await model.undo()
        await model.session.markersKept()
        XCTAssertEqual(try keptMarkers(of: harness.fixture).map(\.time), [2, 6])

        await model.redo()
        model.move(to: 7)
        model.addMarker()
        let saved = await model.save()
        XCTAssertTrue(saved, "\(harness.announcements.sentences)")
        XCTAssertEqual(try keptMarkers(of: harness.fixture).map(\.time), [2, 4, 7], "a save waits for the markers asked to be kept")
    }

    /// Revert to Original deletes the markers, says so first and after, and
    /// Redo doesn't bring them back.
    func testRevertToOriginalDeletesTheMarkers() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        model.move(to: 5)
        model.addMarker()
        model.select(AudioTimeRange(start: 1, end: 2))
        await model.cut()
        XCTAssertEqual(AudioEditorWording.revertExplanation(1, markers: 1), "1 edit is undone. Redo brings them back until you make another edit. The marker is deleted, and Redo doesn't bring it back.")
        XCTAssertEqual(AudioEditorWording.revertExplanation(2, markers: 3), "2 edits are undone. Redo brings them back until you make another edit. The 3 markers are deleted, and Redo doesn't bring them back.")

        await model.revertToOriginal()

        XCTAssertTrue(model.markers.isEmpty)
        XCTAssertEqual(harness.announcements.sentences.last, "Reverted to the original audio. Redo brings back the 1 edit. The marker is deleted.")
        await model.session.markersKept()
        XCTAssertEqual(try keptMarkers(of: harness.fixture), [])
        await model.redo()
        XCTAssertTrue(model.markers.isEmpty)
        XCTAssertEqual(AudioEditorWording.reverted(2, markers: 4), "Reverted to the original audio. Redo brings back the 2 edits. The 4 markers are deleted.")
    }

    // MARK: - Helpers

    /// The markers the edit list of `fixture`'s book file keeps, as its
    /// edits.json holds them.
    private func keptMarkers(of fixture: AudioEditorTestBook) throws -> [AudioEditMarker] {
        let file = fixture.book.fileInPackage
        guard case .found(let history, _) = AudioEditHistoryStore.read(fromPackage: fixture.package, bookFile: file) else {
            XCTFail("the book's edit history couldn't be read")
            return []
        }
        return history.list(for: file)?.markers ?? []
    }
}
