import AVFoundation
import XCTest
@testable import TextMouth

/// Saving and closing in the audio editor (FR04), through the real edit
/// session and library, with a player that makes no sound: Save writes the
/// edits into the book's file in the format it keeps, saying the length
/// and format first and the result after, and says why when it can't;
/// Export writes another file and leaves the book's alone; Revert to
/// Original undoes every edit for Redo to bring back; Discard goes back to
/// the audio as saved; the book's own original policy is set and said; and
/// closing knows what it needs first.
@MainActor
final class AudioEditorSavingTests: XCTestCase {

    // MARK: - Saving

    /// Save writes the edits into the book's file, saying the length and
    /// the format the book keeps first and the new length after; the
    /// progress sheet closes as it ends.
    func testSaveWritesTheEditsIntoTheBooksFile() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        model.select(AudioTimeRange(start: 2, end: 4))
        await model.cut()
        XCTAssertTrue(model.canPerform(.editorSave))
        XCTAssertEqual(model.closeNeed, .unsavedEdits)

        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(model.session.hasUnsavedEdits)
        XCTAssertNil(model.progress)
        XCTAssertNil(model.sheet)
        XCTAssertEqual(model.saveFormatName, "WAV")
        XCTAssertTrue(harness.announcements.sentences.contains("Saving 8 seconds of audio as WAV, the format this book keeps."))
        XCTAssertEqual(harness.announcements.sentences.last, "Saved. The book's audio is now 8 seconds long.")
        let samples = try AudioTestFixtures.floatSamples(of: harness.fixture.book.bookFileURL)
        XCTAssertEqual(samples.count, 64_000)
        XCTAssertEqual(samples[checked: 16_000].map(AudioTestFixtures.rampSample), .frame(.book, 32_000))
        XCTAssertEqual(model.closeNeed, .nothing)
        XCTAssertFalse(model.canPerform(.editorSave))

        await model.save()
        XCTAssertEqual(harness.announcements.sentences.last, "There's nothing to save: the book's audio already holds every edit.")
    }

    /// A save that renders a filter and a silence, the book keeping its
    /// original, lets the editor edit on: the scratch folder the save
    /// cleared is made again as the edits are read back, so a silence
    /// inserted after it, and an export, find every stretch they need.
    func testEditingGoesOnAfterSavingAFilterAndASilence() async throws {
        let fixture = try AudioEditorTestBook.ramp(seconds: 4, for: self)
        fixture.library.audioFilterEngine = { .builtIn }
        let harness = try await EditorHarness.open(fixture, for: self)
        let model = harness.model
        addTeardownBlock { @MainActor in model.windowClosed() }
        AudioEditorPreferences.playAfterMoves.write(false, to: harness.store)
        await model.loadPreview()
        await model.applyFilter(AudioFilterPreset(id: UUID(), name: "Quieter", chain: "volume=-6dB"), to: .wholeFile)
        await model.insertSilence(1)
        await model.setPolicy(.keep, days: 1)

        let saved = await model.save()
        XCTAssertTrue(saved, "\(harness.announcements.sentences)")
        XCTAssertEqual(harness.announcements.sentences.last, "Saved. The book's audio is now 5 seconds long.")
        await model.insertSilence(0.5)
        XCTAssertEqual(harness.announcements.sentences.last, "Inserted 0.5 seconds of silence. Now 5.5 seconds long.")

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("after-save-\(UUID().uuidString).wav")
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
        await model.export(as: .wav, to: destination)
        XCTAssertEqual(harness.announcements.sentences.last, "Exported “\(destination.lastPathComponent)”.")
        XCTAssertEqual(try AVAudioFile(forReading: destination).length, 44_000)
    }

    /// A recording inserted at the very end, kept compressed, is saved to
    /// the frame: nothing of its last packet's padding follows it, in the
    /// book's file or in the levels the editor measures.
    func testARecordingAtTheEndIsSavedToTheFrame() async throws {
        let harness = try await openRamp(seconds: 2)
        let model = harness.model
        model.perform(.editorGoToEnd)
        await model.startPunchIn()
        await harness.backend.record(seconds: 0.5)
        await model.stopPunchIn()
        XCTAssertEqual(model.duration, 2.5, accuracy: 0.000_1)
        let measured = await eventually { model.levels?.duration == model.duration }
        XCTAssertTrue(measured, "the levels were never measured")
        XCTAssertEqual(model.levels?.decibels.count, 250, "a level for each hundredth of a second")

        let saved = await model.save()

        XCTAssertTrue(saved, "\(harness.announcements.sentences)")
        let samples = try AudioTestFixtures.floatSamples(of: harness.fixture.book.bookFileURL)
        XCTAssertEqual(samples.count, 20_000)
        XCTAssertEqual(samples[checked: 15_999].map(AudioTestFixtures.rampSample), .frame(.book, 15_999))
        XCTAssertEqual(AudioTestFixtures.peak(samples.suffix(4_000)), 0.25, accuracy: 0.01, "the recording")
    }

    /// A save the library refuses, as it refuses one for a book open in a
    /// reader, is said, and the edits stay waiting.
    func testARefusedSaveIsSaidAndTheEditsWait() async throws {
        let harness = try await openRamp(seconds: 4)
        let model = harness.model
        model.select(AudioTimeRange(start: 1, end: 2))
        await model.cut()
        harness.fixture.library.openBookIDs = [harness.fixture.book.id]

        let saved = await model.save()
        XCTAssertFalse(saved)
        XCTAssertTrue(model.session.hasUnsavedEdits)
        XCTAssertNil(model.sheet)
        XCTAssertEqual(
            harness.announcements.sentences.last,
            "The edits couldn't be saved. The book is open in a reader. Close it there, then save the edited audio again."
        )
    }

    /// The save's words name a file written under a new name, and each
    /// format by the name people know it by.
    func testTheSavesWordsNameTheFormatAndANewFile() {
        XCTAssertEqual(
            AudioEditorWording.saved(90, renamedTo: "Interview.m4a"),
            "Saved. The book's audio is now 1 minute, 30 seconds long. Its file is now “Interview.m4a”, "
                + "since TextMouth can't write its old format."
        )
        XCTAssertEqual(AudioEditorWording.savingDetail(5, format: nil), "Saving 5 seconds of audio into the book.")
        XCTAssertEqual(AudioEditorWording.formatName(.aacM4B), "M4B Audiobook (AAC)")
        XCTAssertEqual(AudioEditorWording.formatName(.mp3), "MP3")
        XCTAssertEqual(AudioEditorWording.percentDone(75), "75 percent")
    }

    /// A save and an export name each format alike, by the name Export
    /// lists it by; only MP3's there adds what it needs.
    func testSavesAndExportsNameEachFormatAlike() {
        for format in AudioExportFormat.allCases where format != .mp3 {
            XCTAssertEqual(AudioEditorWording.formatName(format.renderFormat), format.title, format.rawValue)
        }
    }

    /// A save or an export in a format with no place for chapter markers
    /// says they are left out of the file; an export as M4A keeps them, and
    /// says nothing of them.
    func testAFormatWithoutChaptersSaysTheyAreLeftOut() async throws {
        let harness = try await openRamp(seconds: 4)
        let model = harness.model
        await model.insertChapter(titled: "Quay")

        await model.save()
        XCTAssertTrue(harness.announcements.sentences.contains(
            "Saving 4 seconds of audio as WAV, the format this book keeps. "
                + "WAV files can't hold chapter markers, so its chapter marker is left out of this file."
        ), "\(harness.announcements.sentences)")
        XCTAssertTrue(AudioRenderFormat.aacM4B.holdsChapterMarkers)
        XCTAssertTrue(AudioRenderFormat.mp3.holdsChapterMarkers)
        XCTAssertFalse(AudioRenderFormat.pcmAIFF.holdsChapterMarkers)
        XCTAssertEqual(
            AudioEditorWording.chaptersLeftOut(3, format: "CAF"),
            "CAF files can't hold chapter markers, so its 3 chapter markers are left out of this file."
        )

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("chapters-\(UUID().uuidString).m4a")
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
        await model.export(as: .m4a, to: destination)
        let exporting = harness.announcements.sentences.first { $0.hasPrefix("Exporting 4 seconds of audio as M4A (AAC)") }
        XCTAssertFalse(exporting?.contains("can't hold") ?? true, "\(harness.announcements.sentences)")
        let chapters = await AudioPlaybackService.extractChapters(from: destination)
        XCTAssertEqual(chapters.map(\.title), ["Quay"])
    }

    // MARK: - Exporting

    /// Export writes the edited audio, unsaved edits and all, to another
    /// file in the format chosen, names it after the book, and leaves the
    /// book's own file as it is.
    func testExportWritesAnotherFileAndLeavesTheBooksAlone() async throws {
        let harness = try await openRamp(seconds: 6)
        let model = harness.model
        model.select(AudioTimeRange(start: 0, end: 1))
        await model.cut()
        let before = try Data(contentsOf: harness.fixture.book.bookFileURL)
        XCTAssertEqual(model.exportFileName(for: .wav), "Harbour Survey.wav")
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString).wav")
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }

        await model.export(as: .wav, to: destination)

        XCTAssertEqual(harness.announcements.sentences.last, "Exported “\(destination.lastPathComponent)”.")
        XCTAssertNil(model.sheet)
        let exported = try AVAudioFile(forReading: destination)
        XCTAssertEqual(Double(exported.length) / exported.fileFormat.sampleRate, 5, accuracy: 0.001)
        XCTAssertEqual(try Data(contentsOf: harness.fixture.book.bookFileURL), before, "the book's own file changed")
        XCTAssertTrue(model.session.hasUnsavedEdits)
    }

    // MARK: - Reverting and Discarding

    /// Revert to Original asks first, then undoes every edit, saying how
    /// many Redo brings back.
    func testRevertToOriginalUndoesEveryEdit() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        model.askToRevert()
        XCTAssertFalse(model.confirmingRevert)
        XCTAssertEqual(harness.announcements.sentences.last, "There's nothing to revert: no edit can be undone.")

        model.select(AudioTimeRange(start: 1, end: 2))
        await model.cut()
        await model.insertSilence(2)
        XCTAssertTrue(model.canRevert)
        model.perform(.editorRevert)
        XCTAssertTrue(model.confirmingRevert)

        await model.revertToOriginal()
        XCTAssertFalse(model.confirmingRevert)
        XCTAssertEqual(model.duration, 10, accuracy: 0.000_1)
        XCTAssertFalse(model.session.canUndo)
        XCTAssertEqual(harness.announcements.sentences.last, "Reverted to the original audio. Redo brings back the 2 edits.")
        XCTAssertEqual(AudioEditorWording.revertExplanation(1), "1 edit is undone. Redo brings them back until you make another edit.")
    }

    /// Discard goes back to the audio as last saved: unsaved edits are
    /// undone, and undone ones the file holds redone.
    func testDiscardGoesBackToTheAudioAsSaved() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        model.select(AudioTimeRange(start: 1, end: 2))
        await model.cut()
        await model.save()
        model.select(AudioTimeRange(start: 3, end: 5))
        await model.cut()
        XCTAssertEqual(model.duration, 7, accuracy: 0.000_1)

        let discarded = await model.discardUnsavedEdits()
        XCTAssertTrue(discarded)
        XCTAssertFalse(model.session.hasUnsavedEdits)
        XCTAssertEqual(model.duration, 9, accuracy: 0.000_1)

        await model.undo()
        XCTAssertTrue(model.session.hasUnsavedEdits)
        let back = await model.discardUnsavedEdits()
        XCTAssertTrue(back)
        XCTAssertEqual(model.duration, 9, accuracy: 0.000_1, "the saved cut wasn't redone")
    }

    // MARK: - The Book's Original Policy

    /// The book follows the global setting until given a policy of its own,
    /// each said as it is set.
    func testTheBooksOwnPolicyIsSetAndSaid() async throws {
        let harness = try await openRamp(seconds: 2)
        let model = harness.model
        XCTAssertEqual(model.policyChoice, .global)
        XCTAssertEqual(AudioEditorWording.choiceTitle(.global, global: .keep), "Use the global setting (Keep)")

        await model.setPolicy(.keep, days: 1)
        XCTAssertEqual(model.session.policyOverride, .keep)
        XCTAssertEqual(model.policyChoice, .keep)
        XCTAssertEqual(harness.announcements.sentences.last, "This book keeps its original audio until the book is removed.")

        await model.setPolicy(.deleteAfterDays, days: 3)
        XCTAssertEqual(model.session.policyOverride, .deleteAfter(days: 3))
        XCTAssertEqual(model.policyDays, 3)
        XCTAssertEqual(
            harness.announcements.sentences.last,
            "This book keeps its original audio for 3 days after it was saved or last edited."
        )

        await model.setPolicy(.global, days: 3)
        XCTAssertNil(model.session.policyOverride)
        XCTAssertTrue(harness.announcements.sentences.last?.hasPrefix("This book follows the global setting now.") == true)
    }

    // MARK: - Closing

    /// Closing needs nothing with every edit saved, a question with edits
    /// waiting, and a stop first while a punch-in records; the question
    /// names the book.
    func testWhatClosingNeeds() async throws {
        let harness = try await openRamp(seconds: 4)
        let model = harness.model
        XCTAssertEqual(model.closeNeed, .nothing)
        await model.insertSilence(1)
        XCTAssertEqual(model.closeNeed, .unsavedEdits)
        await model.startPunchIn()
        XCTAssertEqual(model.closeNeed, .recording)
        await model.cancelPunchIn()
        XCTAssertEqual(model.closeNeed, .unsavedEdits)
        XCTAssertEqual(AudioEditorWording.closeQuestion(book: "Harbour Survey"), "Save the edits to “Harbour Survey”?")
    }

    /// An alert's buttons answer the question about unsaved edits in order:
    /// Save, Discard, then Cancel, as anything else is.
    func testTheQuestionsButtonsAnswerInOrder() {
        XCTAssertEqual(AudioEditorUnsavedEditsAnswer(.alertFirstButtonReturn), .save)
        XCTAssertEqual(AudioEditorUnsavedEditsAnswer(.alertSecondButtonReturn), .discard)
        XCTAssertEqual(AudioEditorUnsavedEditsAnswer(.alertThirdButtonReturn), .cancel)
        XCTAssertEqual(AudioEditorUnsavedEditsAnswer(.abort), .cancel)
    }

    // MARK: - Quitting

    /// A quit through the app delegate asks about each editor with unsaved
    /// edits in turn, by its book's title, and carries out each answer, Save
    /// for one and Discard for the other, then asks to quit again; an editor
    /// with nothing unsaved isn't asked, and a request while the questions
    /// are asked asks nothing more.
    func testQuittingAsksAboutEachEditorsUnsavedEdits() async throws {
        let ferry = try await quittingEditor(named: "Ferry Log.wav")
        let weir = try await quittingEditor(named: "Weir Notes.wav")
        let tides = try await quittingEditor(named: "Tide Tables.wav")
        ferry.model.select(AudioTimeRange(start: 1, end: 2))
        await ferry.model.cut()
        weir.model.select(AudioTimeRange(start: 0, end: 1))
        await weir.model.cut()
        let (delegate, controller, recorder) = quitting([weir, tides, ferry])
        recorder.answers = ["Ferry Log": .save, "Weir Notes": .discard]

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel, "a request while asking")
        await controller.quitReview?.value

        XCTAssertEqual(recorder.asked, ["Ferry Log", "Weir Notes"])
        XCTAssertEqual(recorder.quits, 1)
        XCTAssertFalse(ferry.model.session.hasUnsavedEdits)
        XCTAssertEqual(try AVAudioFile(forReading: ferry.fixture.book.bookFileURL).length, 24_000, "Save wrote the cut")
        XCTAssertFalse(weir.model.session.hasUnsavedEdits)
        XCTAssertEqual(weir.model.duration, 4, accuracy: 0.000_1, "Discard went back to the audio as saved")
        XCTAssertTrue(weir.model.session.canRedo, "the discarded edit waits in edits.json for Redo")
        XCTAssertFalse(controller.holdQuit(then: { XCTFail("asked to quit again with nothing to ask") }))
    }

    /// Cancel keeps TextMouth open and asks about no other editor; a save
    /// that fails does too, saying why; the next quit asks again.
    func testCancelOrAFailedSaveKeepsTextMouthOpen() async throws {
        let ferry = try await quittingEditor(named: "Ferry Log.wav")
        let weir = try await quittingEditor(named: "Weir Notes.wav")
        await ferry.model.insertSilence(1)
        await weir.model.insertSilence(1)
        let (delegate, controller, recorder) = quitting([ferry, weir])
        recorder.answers = ["Ferry Log": .cancel]

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        await controller.quitReview?.value
        XCTAssertEqual(recorder.asked, ["Ferry Log"])
        XCTAssertEqual(recorder.quits, 0)
        XCTAssertTrue(ferry.model.session.hasUnsavedEdits)
        XCTAssertTrue(weir.model.session.hasUnsavedEdits)

        recorder.answers = ["Ferry Log": .save]
        ferry.fixture.library.openBookIDs = [ferry.fixture.book.id]
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        await controller.quitReview?.value
        XCTAssertEqual(recorder.asked, ["Ferry Log", "Ferry Log"])
        XCTAssertEqual(recorder.quits, 0)
        XCTAssertTrue(ferry.announcements.sentences.last?.hasPrefix("The edits couldn't be saved.") == true)
    }

    /// An editor still working, or recording a punch-in, holds the quit and
    /// says so, naming its book, and nothing is asked.
    func testAnEditorWorkingOrRecordingHoldsTheQuit() async throws {
        let ferry = try await quittingEditor(named: "Ferry Log.wav")
        await ferry.model.insertSilence(1)
        let (delegate, controller, recorder) = quitting([ferry])

        ferry.model.isWorking = true
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        XCTAssertEqual(ferry.announcements.sentences.last, "The editor of “Ferry Log” is still working. Quit TextMouth once the change is done.")
        ferry.model.isWorking = false

        await ferry.model.startPunchIn()
        XCTAssertTrue(controller.holdQuit(then: { XCTFail("quit while recording") }))
        XCTAssertEqual(
            ferry.announcements.sentences.last,
            "A recording is under way in the editor of “Ferry Log”. Stop it, or discard it with Clear Selection, then quit TextMouth."
        )
        await ferry.model.cancelPunchIn()
        XCTAssertNil(controller.quitReview)
        XCTAssertTrue(recorder.asked.isEmpty)
        XCTAssertEqual(recorder.quits, 0)
    }

    /// A Discard that can't reach the audio as saved keeps the edits, says
    /// so, and still lets TextMouth quit: the request the review makes is
    /// not asked about again, though a later one is.
    func testADiscardThatKeepsTheEditsStillLetsTextMouthQuit() async throws {
        let ferry = try await quittingEditor(named: "Ferry Log.wav")
        ferry.model.select(AudioTimeRange(start: 1, end: 2))
        await ferry.model.cut()
        await ferry.model.save()
        await ferry.model.undo()
        ferry.model.select(AudioTimeRange(start: 0, end: 1))
        await ferry.model.cut()
        let (_, controller, recorder) = quitting([ferry])
        recorder.answers = ["Ferry Log": .discard]
        let repeated = QuitRecorder()

        // The request to quit again arrives on a later turn of the run loop,
        // as QuitRequest.ask() delivers it, not inside the review's own call:
        // the mark that lets it quit must still be there when it arrives.
        XCTAssertTrue(controller.holdQuit(then: {
            repeated.quits += 1
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    repeated.held.append(controller.holdQuit(then: {}))
                }
            }
        }))
        await controller.quitReview?.value
        let askedAgain = await eventually { repeated.held.count == 1 }

        XCTAssertTrue(askedAgain, "the review never asked to quit again")
        XCTAssertEqual(ferry.announcements.sentences.last, AudioEditorWording.discardKept)
        XCTAssertTrue(ferry.model.session.hasUnsavedEdits)
        XCTAssertEqual(repeated.quits, 1)
        XCTAssertEqual(repeated.held, [false], "the request the review made, on a later turn, was asked about again")
        XCTAssertTrue(controller.holdQuit(then: {}), "a later request asks again")
        await controller.quitReview?.value
    }

    /// Markers waiting to be written hold the quit until they are in
    /// edits.json, asking nothing.
    func testMarkersWaitingToBeKeptHoldTheQuitUntilWritten() async throws {
        let ferry = try await quittingEditor(named: "Ferry Log.wav")
        let (delegate, controller, recorder) = quitting([ferry])
        ferry.model.move(to: 2)
        ferry.model.addMarker()

        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        await controller.quitReview?.value

        XCTAssertTrue(recorder.asked.isEmpty)
        XCTAssertEqual(recorder.quits, 1)
        let file = ferry.fixture.book.fileInPackage
        guard case .found(let history, _) = AudioEditHistoryStore.read(fromPackage: ferry.fixture.package, bookFile: file) else {
            return XCTFail("the history couldn't be read")
        }
        XCTAssertEqual(history.list(for: file)?.markers.map(\.time), [2])
    }

    // MARK: - Helpers

    /// An editor on a 4-second ramp in a book named `name` (its file's
    /// name), its preview loaded, closed as the test ends.
    private func quittingEditor(named name: String) async throws -> EditorHarness {
        let harness = try await EditorHarness.open(try AudioEditorTestBook.ramp(seconds: 4, named: name, for: self), for: self)
        AudioEditorPreferences.playAfterMoves.write(false, to: harness.store)
        await harness.model.loadPreview()
        addTeardownBlock { @MainActor in harness.model.windowClosed() }
        return harness
    }

    /// An app delegate whose quits go through a controller of its own over
    /// `editors`, each in a window never shown, which a recorder answers
    /// for: what it asked, and how often TextMouth asked to quit again.
    private func quitting(_ editors: [EditorHarness]) -> (AppDelegate, AudioEditorWindowController, QuitRecorder) {
        let controller = AudioEditorWindowController()
        for editor in editors {
            controller.attach(editor.model, to: NSWindow())
        }
        let recorder = QuitRecorder()
        controller.askBeforeQuitting = { model, _ in
            recorder.asked.append(model.bookTitle)
            return recorder.answers[model.bookTitle] ?? .cancel
        }
        let delegate = AppDelegate()
        delegate.audioEditors = controller
        delegate.requestTermination = { recorder.quits += 1 }
        return (delegate, controller, recorder)
    }
}

/// What the quit tests' stand-ins heard: the books asked about, the answers
/// to give by title, the requests to quit again, and what holding them
/// said.
@MainActor
private final class QuitRecorder {
    var asked: [String] = []
    var answers: [String: AudioEditorUnsavedEditsAnswer] = [:]
    var quits = 0
    var held: [Bool] = []
}
