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
        XCTAssertEqual(AudioEditorWording.formatName(.aacM4B), "M4B audiobook (AAC)")
        XCTAssertEqual(AudioEditorWording.formatName(.mp3), "MP3")
        XCTAssertEqual(AudioEditorWording.percentDone(75), "75 percent")
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

    // MARK: - Helpers

    /// An editor on `seconds` seconds of an identity ramp in a WAVE file,
    /// its preview loaded, playing nothing after moves.
    private func openRamp(seconds: Double) async throws -> EditorHarness {
        let harness = try await EditorHarness.open(try AudioEditorTestBook.ramp(seconds: seconds, for: self), for: self)
        AudioEditorPreferences.playAfterMoves.write(false, to: harness.store)
        await harness.model.loadPreview()
        let model = harness.model
        addTeardownBlock { @MainActor in model.windowClosed() }
        return harness
    }
}
