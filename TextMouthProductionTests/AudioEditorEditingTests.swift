import AVFoundation
import XCTest
@testable import TextMouth

/// Editing in the audio editor (FR04), on generated audio through the real
/// edit session, with a player that makes no sound and a recorder that
/// needs no microphone: Cut, Copy, and Paste, each landing on its exact
/// sample, a Paste right after a Cut making one move; Trim to Selection,
/// undone as one; silence and chapter markers through their sheets'
/// answers; Undo and Redo, named as the Edit menu names them; markers
/// following the sound; a filter previewed, then applied; and punch-ins
/// that replace the selection or insert at the cursor, or are discarded.
@MainActor
final class AudioEditorEditingTests: XCTestCase {

    // MARK: - The Time Map

    /// Times follow a cut, a trim, an insertion, a replacement, and a filter
    /// as chapter markers do, and back through an undo.
    func testTimesFollowAnEditAndComeBackThroughItsUndo() {
        let cut = AudioEdit.cut(AudioTimeRange(start: 2, end: 4))
        XCTAssertEqual(AudioEditorTimeMap.forward(1, through: cut, before: 10, after: 8), 1)
        XCTAssertEqual(AudioEditorTimeMap.forward(3, through: cut, before: 10, after: 8), 2)
        XCTAssertEqual(AudioEditorTimeMap.forward(6, through: cut, before: 10, after: 8), 4)
        XCTAssertEqual(AudioEditorTimeMap.backward(4, through: cut, before: 10, after: 8), 6)
        XCTAssertEqual(AudioEditorTimeMap.backward(2, through: cut, before: 10, after: 8), 2, "the cut point stays before the sound put back")

        XCTAssertEqual(AudioEditorTimeMap.forward(3, through: .trimStart(to: 2), before: 10, after: 8), 1)
        XCTAssertEqual(AudioEditorTimeMap.forward(1, through: .trimStart(to: 2), before: 10, after: 8), 0)
        XCTAssertEqual(AudioEditorTimeMap.forward(9, through: .trimEnd(at: 7), before: 10, after: 7), 7)
        XCTAssertEqual(AudioEditorTimeMap.backward(1, through: .trimStart(to: 2), before: 10, after: 8), 3)

        let silence = AudioEdit.insertSilence(at: 5, duration: 1.5)
        XCTAssertEqual(AudioEditorTimeMap.forward(5, through: silence, before: 10, after: 11.5), 5, "a time where sound goes in stays before it")
        XCTAssertEqual(AudioEditorTimeMap.forward(6, through: silence, before: 10, after: 11.5), 7.5)
        XCTAssertEqual(AudioEditorTimeMap.backward(6, through: silence, before: 10, after: 11.5), 5)
        XCTAssertEqual(AudioEditorTimeMap.backward(8, through: silence, before: 10, after: 11.5), 6.5)

        let replace = AudioEdit.replace(AudioTimeRange(start: 2, end: 4), with: AudioEditTake(file: "take", range: AudioTimeRange(start: 0, end: 4)))
        XCTAssertEqual(AudioEditorTimeMap.forward(3, through: replace, before: 10, after: 12), 4, "inside goes to the same proportion")
        XCTAssertEqual(AudioEditorTimeMap.forward(5, through: replace, before: 10, after: 12), 7)
        XCTAssertEqual(AudioEditorTimeMap.backward(4, through: replace, before: 10, after: 12), 3)

        let filter = AudioEdit.filter(chain: "atempo=2", range: nil)
        XCTAssertEqual(AudioEditorTimeMap.forward(8, through: filter, before: 10, after: 5), 4)
        XCTAssertEqual(AudioEditorTimeMap.backward(4, through: filter, before: 10, after: 5), 8)
        XCTAssertEqual(AudioEditorTimeMap.forward(3, through: .setChapter(at: 1, title: "Quay"), before: 10, after: 10), 3)
    }

    /// A move carries the times inside it with it, closes up behind it, and
    /// opens up where it lands, either way; its undo puts every time back.
    func testTimesFollowAMoveEitherWayAndBack() {
        let later = AudioEdit.move(AudioTimeRange(start: 2, end: 4), to: 8)
        for (before, after) in [(1.0, 1.0), (3.0, 7.0), (5.0, 3.0), (8.0, 6.0), (9.0, 9.0)] {
            XCTAssertEqual(AudioEditorTimeMap.forward(before, through: later, before: 10, after: 10), after, "\(before)")
            if before != 8 {
                XCTAssertEqual(AudioEditorTimeMap.backward(after, through: later, before: 10, after: 10), before, "back from \(after)")
            }
        }
        let earlier = AudioEdit.move(AudioTimeRange(start: 6, end: 8), to: 2)
        for (before, after) in [(1.0, 1.0), (2.0, 2.0), (3.0, 5.0), (7.0, 3.0), (9.0, 9.0)] {
            XCTAssertEqual(AudioEditorTimeMap.forward(before, through: earlier, before: 10, after: 10), after, "\(before)")
            if before != 2 {
                XCTAssertEqual(AudioEditorTimeMap.backward(after, through: earlier, before: 10, after: 10), before, "back from \(after)")
            }
        }
        XCTAssertEqual(AudioEditorTimeMap.place(of: later), 2)
        XCTAssertEqual(AudioEditorTimeMap.place(of: .trimEnd(at: 7)), 7)
    }

    // MARK: - The Engine's Insertion

    /// An insertion is recorded, read back from edits.json, named, and laid
    /// into the timeline as sound from its take, a marker at its place
    /// staying before it.
    func testAnInsertionIsATakeLaidInAtItsPlace() throws {
        let insert = AudioEdit.insert(at: 1, with: AudioEditTake(file: "audioEdits/takes/clip.caf", range: AudioTimeRange(start: 0, end: 0.5)))
        let data = try JSONEncoder().encode(insert)
        XCTAssertEqual(try JSONDecoder().decode(AudioEdit.self, from: data), insert)
        XCTAssertEqual(AudioEditWording.actionName(insert), "Insert 0.5 Seconds of Audio")
        XCTAssertEqual(insert.take?.file, "audioEdits/takes/clip.caf")
        XCTAssertTrue(insert.changesAudio)

        var timeline = AudioEditTimeline(sampleRate: 8_000, baseFrames: 16_000, chapters: [.init(frame: 8_000, title: "Locks")])
        try timeline.applyRearranging(insert)
        XCTAssertEqual(timeline.length, 20_000)
        XCTAssertEqual(timeline.segments.map(\.length), [8_000, 4_000, 8_000])
        XCTAssertEqual(timeline.segments[checked: 1]?.source, .take("audioEdits/takes/clip.caf"))
        XCTAssertEqual(timeline.chapters.map(\.frame), [8_000], "the marker at the place stayed before the new sound")
        XCTAssertThrowsError(try timeline.applyRearranging(.insert(at: 5, with: AudioEditTake(file: "t", range: AudioTimeRange(start: 0, end: 1)))))
    }

    // MARK: - Cut, Copy, and Paste

    /// Cut removes the selection to the sample, says the new length, and
    /// keeps it for Paste; Undo puts it back and says so; Redo cuts again.
    func testCutUndoAndRedo() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        model.select(AudioTimeRange(start: 2, end: 4))

        await model.cut()
        XCTAssertEqual(model.duration, 8, accuracy: 0.000_1)
        XCTAssertEqual(model.cursor, 2)
        XCTAssertNil(model.selection)
        XCTAssertEqual(harness.announcements.sentences.last, "Cut 2 seconds. Now 8 seconds long.")
        XCTAssertEqual(model.undoName, "Cut 2 Seconds")
        XCTAssertEqual(model.title(for: .editorUndo), "Undo Cut 2 Seconds")
        let samples = try await editedSamples(model)
        XCTAssertEqual(samples[checked: 15_999].map(AudioTestFixtures.rampSample), .frame(.book, 15_999))
        XCTAssertEqual(samples[checked: 16_000].map(AudioTestFixtures.rampSample), .frame(.book, 32_000))
        XCTAssertNotNil(model.clip?.file)
        XCTAssertEqual(harness.player.loadedFrames.last, 64_000, "the preview wasn't reloaded with the cut")

        await model.undo()
        XCTAssertEqual(model.duration, 10, accuracy: 0.000_1)
        XCTAssertEqual(model.cursor, 2)
        XCTAssertEqual(harness.announcements.sentences.last, "Undid Cut 2 Seconds. Now 10 seconds long.")
        XCTAssertEqual(model.redoName, "Cut 2 Seconds")
        await model.redo()
        XCTAssertEqual(model.duration, 8, accuracy: 0.000_1)
        XCTAssertEqual(harness.announcements.sentences.last, "Redid Cut 2 Seconds. Now 8 seconds long.")
        await model.redo()
        XCTAssertEqual(harness.announcements.sentences.last, "There's nothing to redo.")
    }

    /// Copy keeps the selection, and Paste puts a copy at the cursor, every
    /// sample in place, as one edit named for the audio it inserted.
    func testCopyAndPasteAtTheCursor() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        await model.paste()
        XCTAssertEqual(harness.announcements.sentences.last, "Nothing has been cut or copied.")
        model.select(AudioTimeRange(start: 1, end: 2))
        await model.copy()
        XCTAssertEqual(harness.announcements.sentences.last, "Copied 1 second.")
        model.clearSelection()
        model.move(to: 5)

        await model.paste()
        XCTAssertEqual(model.duration, 11, accuracy: 0.000_1)
        XCTAssertEqual(model.cursor, 6, accuracy: 0.000_1)
        XCTAssertEqual(harness.announcements.sentences.last, "Pasted 1 second. Now 11 seconds long.")
        XCTAssertEqual(model.undoName, "Insert 1 Second of Audio")
        let samples = try await editedSamples(model)
        XCTAssertEqual(samples[checked: 39_999].map(AudioTestFixtures.rampSample), .frame(.book, 39_999))
        XCTAssertEqual(samples[checked: 40_000].map(AudioTestFixtures.rampSample), .frame(.book, 8_000))
        XCTAssertEqual(samples[checked: 47_999].map(AudioTestFixtures.rampSample), .frame(.book, 15_999))
        XCTAssertEqual(samples[checked: 48_000].map(AudioTestFixtures.rampSample), .frame(.book, 40_000))
    }

    /// A Paste over a selection replaces it with the audio copied.
    func testPasteOverASelectionReplacesIt() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        model.select(AudioTimeRange(start: 1, end: 2))
        await model.copy()
        model.select(AudioTimeRange(start: 6, end: 9))

        await model.paste()
        XCTAssertEqual(model.duration, 8, accuracy: 0.000_1)
        XCTAssertEqual(harness.announcements.sentences.last, "Pasted 1 second over 3 seconds. Now 8 seconds long.")
        XCTAssertEqual(model.undoName, "Replace 3 Seconds")
        let samples = try await editedSamples(model)
        XCTAssertEqual(samples[checked: 48_000].map(AudioTestFixtures.rampSample), .frame(.book, 8_000))
        XCTAssertEqual(samples[checked: 56_000].map(AudioTestFixtures.rampSample), .frame(.book, 72_000))
    }

    /// A Paste right after a Cut moves the audio cut, as one edit undone in
    /// one, every sample in place; at the cut's own place it puts the audio
    /// back, the cut left to redo.
    func testAPasteRightAfterACutMovesTheAudio() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        model.select(AudioTimeRange(start: 2, end: 4))
        await model.cut()
        model.move(to: 6)

        await model.paste()
        XCTAssertEqual(model.duration, 10, accuracy: 0.000_1)
        XCTAssertEqual(model.undoName, "Move 2 Seconds")
        XCTAssertEqual(harness.announcements.sentences.last, "Moved 2 seconds to 6 seconds.")
        XCTAssertEqual(model.cursor, 8, accuracy: 0.000_1)
        let samples = try await editedSamples(model)
        XCTAssertEqual(samples[checked: 16_000].map(AudioTestFixtures.rampSample), .frame(.book, 32_000))
        XCTAssertEqual(samples[checked: 48_000].map(AudioTestFixtures.rampSample), .frame(.book, 16_000))
        XCTAssertEqual(samples[checked: 64_000].map(AudioTestFixtures.rampSample), .frame(.book, 64_000))
        await model.undo()
        XCTAssertFalse(model.session.canUndo, "the move and the cut took two undos")
        XCTAssertEqual(model.duration, 10, accuracy: 0.000_1)

        model.select(AudioTimeRange(start: 3, end: 5))
        await model.cut()
        await model.paste()
        XCTAssertEqual(harness.announcements.sentences.last, "Pasted 2 seconds back where they were cut.")
        XCTAssertEqual(model.duration, 10, accuracy: 0.000_1)
        XCTAssertTrue(model.session.canRedo)
        XCTAssertNil(model.clip?.cut, "a second Paste would move nothing")
    }

    // MARK: - Trim, Silence, and Chapter Markers

    /// Trim to Selection keeps only the selection, as one step Undo and
    /// Redo name and take as one.
    func testTrimToSelectionIsOneStep() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        model.select(AudioTimeRange(start: 2, end: 7))

        await model.trimToSelection()
        XCTAssertEqual(model.duration, 5, accuracy: 0.000_1)
        XCTAssertEqual(harness.announcements.sentences.last, "Trimmed to the selection: 5 seconds kept.")
        XCTAssertEqual(model.undoName, "Trim to Selection")
        let samples = try await editedSamples(model)
        XCTAssertEqual(samples.first.map(AudioTestFixtures.rampSample), .frame(.book, 16_000))
        XCTAssertEqual(samples.count, 40_000)

        await model.undo()
        XCTAssertEqual(model.duration, 10, accuracy: 0.000_1)
        XCTAssertEqual(harness.announcements.sentences.last, "Undid Trim to Selection. Now 10 seconds long.")
        XCTAssertEqual(model.redoName, "Trim to Selection")
        await model.redo()
        XCTAssertEqual(model.duration, 5, accuracy: 0.000_1)

        model.select(AudioTimeRange(start: 0, end: 5))
        await model.trimToSelection()
        XCTAssertEqual(harness.announcements.sentences.last, "The selection is all of the audio, so there's nothing to trim.")
    }

    /// Insert Silence takes a length typed in its sheet, refusing none at
    /// all, and inserts it at the cursor, which goes past it.
    func testInsertSilenceTakesALengthTyped() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        model.move(to: 4)
        model.perform(.editorInsertSilence)
        XCTAssertEqual(model.prompt, .insertSilence)
        XCTAssertEqual(model.initialText(for: .insertSilence), "1")
        XCTAssertEqual(model.answer(.insertSilence, with: "0"), "Silence has to last longer than no time at all.")
        XCTAssertEqual(model.answer(.insertSilence, with: "48:00:00"), "Silence can last at most a day.")

        XCTAssertNil(model.answer(.insertSilence, with: "1.5"))
        XCTAssertNil(model.sheet)
        let inserted = await eventually { abs(model.duration - 11.5) < 0.000_1 && !model.isWorking }
        XCTAssertTrue(inserted, "the silence was never inserted")
        XCTAssertEqual(model.cursor, 5.5, accuracy: 0.000_1)
        XCTAssertEqual(harness.announcements.sentences.last, "Inserted 1.5 seconds of silence. Now 11.5 seconds long.")
        let samples = try await editedSamples(model)
        XCTAssertEqual(samples[checked: 32_000].map(AudioTestFixtures.rampSample), .silence)
        XCTAssertEqual(samples[checked: 44_000].map(AudioTestFixtures.rampSample), .frame(.book, 32_000))
    }

    /// Insert Chapter Marker offers the next chapter's number, refuses a
    /// blank title, and sets the marker; its row renames and removes it,
    /// each an edit Undo takes back.
    func testChapterMarkersAreSetRenamedAndRemoved() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        model.move(to: 3)
        XCTAssertEqual(model.initialText(for: .insertChapter), "Chapter 1")
        XCTAssertEqual(model.answer(.insertChapter, with: "  "), "A chapter marker needs a title.")
        await model.insertChapter(titled: "Quay")
        XCTAssertEqual(model.chapters.map(\.title), ["Quay"])
        XCTAssertEqual(harness.announcements.sentences.last, "Chapter marker “Quay” set at 3 seconds.")
        XCTAssertEqual(model.initialText(for: .insertChapter), "Quay", "a marker at the cursor is offered for renaming")
        model.move(to: 6)
        XCTAssertEqual(model.initialText(for: .insertChapter), "Chapter 2")

        await model.renameChapter(at: 3, to: "Harbour")
        XCTAssertEqual(model.chapters.map(\.title), ["Harbour"])
        XCTAssertEqual(harness.announcements.sentences.last, "Chapter marker renamed “Harbour”.")
        await model.removeChapter(at: 3, titled: "Harbour")
        XCTAssertTrue(model.chapters.isEmpty)
        XCTAssertEqual(harness.announcements.sentences.last, "Chapter marker “Harbour” removed.")
        XCTAssertEqual(model.undoName, "Remove Chapter Marker")
        await model.undo()
        XCTAssertEqual(model.chapters.map(\.title), ["Harbour"])
    }

    /// Markers follow the sound through an edit and back through its undo.
    func testMarkersFollowTheSound() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        model.move(to: 3)
        model.addMarker()
        model.move(to: 6)
        model.addMarker()
        model.select(AudioTimeRange(start: 2, end: 4))

        await model.cut()
        XCTAssertEqual(model.orderedMarkers.map(\.time), [2, 4])
        await model.undo()
        XCTAssertEqual(model.orderedMarkers.map(\.time), [2, 6], "a marker inside the cut stays at the cut point")
    }

    // MARK: - Filters

    /// A filter's preview plays the processed stretch without changing the
    /// audio, and the edited audio comes back when it ends; applying it
    /// changes the selection's level alone, keeps it selected, and says so.
    func testAFilterIsPreviewedThenApplied() async throws {
        let fixture = try AudioEditorTestBook.ramp(seconds: 6, for: self)
        fixture.library.audioFilterEngine = { .builtIn }
        let harness = try await EditorHarness.open(fixture, for: self)
        let model = harness.model
        addTeardownBlock { @MainActor in model.windowClosed() }
        AudioEditorPreferences.playAfterMoves.write(false, to: harness.store)
        await model.loadPreview()
        let louder = AudioFilterPreset(id: UUID(), name: "Louder", chain: "volume=6dB")
        await model.previewFilter(louder, on: .selection)
        XCTAssertEqual(harness.announcements.sentences.last, "Nothing is selected.")

        model.select(AudioTimeRange(start: 2, end: 4))
        await model.previewFilter(louder, on: .selection)
        XCTAssertEqual(harness.player.plays.last, .init(from: 2, until: 4))
        XCTAssertEqual(model.filterPreview?.presetID, louder.id)
        XCTAssertEqual(model.duration, 6, accuracy: 0.000_1, "a preview changed the audio")
        XCTAssertFalse(model.session.canUndo)
        let loads = harness.player.loadedFrames.count
        harness.player.finishPlaying(at: 4)
        XCTAssertNil(model.filterPreview)
        let restored = await eventually { harness.player.loadedFrames.count > loads }
        XCTAssertTrue(restored, "the edited audio never came back after the preview")

        await model.applyFilter(louder, to: .selection)
        XCTAssertEqual(harness.announcements.sentences.last, "Applied Louder to 2 seconds. Now 6 seconds long.")
        XCTAssertEqual(model.selection, AudioTimeRange(start: 2, end: 4))
        XCTAssertEqual(model.undoName, "Apply Filter")
        let samples = try await editedSamples(model)
        let gain = Float(pow(10, 6.0 / 20))
        let inside = try XCTUnwrap(samples[checked: 20_000])
        XCTAssertEqual(inside, Float(20_001) * Float(AudioTestFixtures.rampStep) * gain, accuracy: 0.000_01)
        XCTAssertEqual(samples[checked: 40_000].map(AudioTestFixtures.rampSample), .frame(.book, 40_000))
    }

    // MARK: - Punch In

    /// A punch-in over the selection says what it will record and from
    /// which microphone, records through the recorder, and on Stop replaces
    /// the selection with the take, which is then selected.
    func testAPunchInReplacesTheSelection() async throws {
        let harness = try await openRamp(seconds: 6)
        let model = harness.model
        XCTAssertEqual(model.microphones.map(\.name), ["MacBook Air Microphone", "AirPods Pro"])
        model.select(AudioTimeRange(start: 2, end: 3))

        await model.togglePunchIn()
        XCTAssertEqual(model.punchIn?.isRecording, true)
        XCTAssertTrue(harness.announcements.sentences.contains(
            "Recording over 1 second at 2 seconds, from MacBook Air Microphone, after the beep. "
                + "Punch In or Stop ends it; Clear Selection discards it."
        ))
        XCTAssertEqual(model.title(for: .editorPunchIn), "Stop Recording")
        XCTAssertFalse(model.canPerform(.editorCut))
        model.perform(.editorSkipForward)
        XCTAssertEqual(harness.announcements.sentences.last, "Recording. Stop the recording first.")
        await harness.backend.record(seconds: 1.5)
        await model.recorder.service.refresh()
        XCTAssertTrue(model.statusSentence.hasPrefix("Recording, 1.5 seconds, level minus 9 decibels"), model.statusSentence)

        await model.togglePunchIn()
        XCTAssertNil(model.punchIn)
        XCTAssertEqual(model.duration, 6.5, accuracy: 0.001)
        XCTAssertEqual(model.selection?.start ?? -1, 2, accuracy: 0.000_1)
        XCTAssertEqual(model.selection?.end ?? -1, 3.5, accuracy: 0.001)
        XCTAssertEqual(
            harness.announcements.sentences.last,
            "Replaced 1 second with 1.5 seconds of new recording, which is selected. Now 6.5 seconds long."
        )
        XCTAssertEqual(model.undoName, "Replace 1 Second")
        let samples = try await editedSamples(model)
        XCTAssertEqual(samples[checked: 15_999].map(AudioTestFixtures.rampSample), .frame(.book, 15_999))
        XCTAssertEqual(samples[checked: 28_000].map(AudioTestFixtures.rampSample), .frame(.book, 24_000))
        let takeFile = await harness.backend.url
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(takeFile).path), "the take outlived its edit")
    }

    /// With nothing selected, a punch-in is inserted at the cursor; one
    /// discarded with Clear Selection changes nothing.
    func testAPunchInInsertsAtTheCursorOrIsDiscarded() async throws {
        let harness = try await openRamp(seconds: 6)
        let model = harness.model
        model.move(to: 4)
        await model.startPunchIn()
        await harness.backend.record(seconds: 1)
        model.perform(.editorClearSelection)
        let discarded = await eventually { model.punchIn == nil }
        XCTAssertTrue(discarded)
        XCTAssertEqual(harness.announcements.sentences.last, "Recording discarded.")
        XCTAssertEqual(model.duration, 6, accuracy: 0.000_1)

        await model.startPunchIn()
        await harness.backend.record(seconds: 1)
        await model.stopPunchIn()
        XCTAssertEqual(model.duration, 7, accuracy: 0.001)
        XCTAssertEqual(model.selection?.start ?? -1, 4, accuracy: 0.000_1)
        XCTAssertEqual(harness.announcements.sentences.last, "Inserted 1 second of new recording, which is selected. Now 7 seconds long.")
        XCTAssertEqual(model.undoName, "Insert 1 Second of Audio")
    }

    /// A microphone lost mid-take ends it, says why, and keeps what was
    /// recorded; a refused permission records nothing and says why.
    func testALostMicrophoneKeepsTheTakeAndARefusalRecordsNothing() async throws {
        let harness = try await openRamp(seconds: 6)
        let model = harness.model
        model.select(AudioTimeRange(start: 1, end: 2))
        await model.startPunchIn()
        await harness.backend.record(seconds: 0.5)
        try await harness.backend.disconnect()
        let kept = await eventually { model.punchIn == nil && !model.isWorking && abs(model.duration - 5.5) < 0.001 }
        XCTAssertTrue(kept, "the take recorded before the loss wasn't kept")
        XCTAssertTrue(harness.announcements.sentences.contains(RecordingFailure.deviceDisconnected("MacBook Air Microphone").errorDescription ?? "-"))

        let refusing = try await EditorHarness.open(try AudioEditorTestBook.ramp(seconds: 2, for: self), for: self, permission: FakeMicrophonePermission(.denied))
        let refused = refusing.model
        addTeardownBlock { @MainActor in refused.windowClosed() }
        await refused.startPunchIn()
        XCTAssertNil(refused.punchIn)
        XCTAssertEqual(refusing.announcements.sentences.last, RecordingFailure.permission(.denied).errorDescription)
    }

    // MARK: - Helpers

    /// Every sample of `model`'s edited audio as it stands, rendered without
    /// loss.
    private func editedSamples(_ model: AudioEditorModel) async throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("edited-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try await model.session.renderStretch(AudioTimeRange(start: 0, end: model.duration), to: url)
        return try AudioTestFixtures.floatSamples(of: url)
    }
}
