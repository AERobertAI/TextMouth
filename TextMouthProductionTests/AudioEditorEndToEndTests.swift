import AVFoundation
import XCTest
@testable import TextMouth

/// The audio editor from end to end (FR04): a book opened as Edit Audio…
/// opens it, through the launcher, into a real edit session of the
/// library; edited through the window's model as its commands edit it, the
/// filters run by TextMouth's own engine, with a player that makes no sound
/// and a capture backend that needs no microphone; then saved into the
/// book, exported, and closed. Each step's own rules are tested on their
/// own elsewhere; these tests check that they hold together.
@MainActor
final class AudioEditorEndToEndTests: XCTestCase {

    /// A phrase found between pauses is selected with the pause after it,
    /// cut, and pasted at the end, as one move; chapter markers are set, a
    /// filter runs over the whole file, and a recording is inserted at the
    /// end, which Undo takes back and Redo brings back. Save writes it all
    /// into the book, saying its WAV file can't hold the chapter markers,
    /// and the library measures the book afresh; an export as M4B keeps the
    /// chapter markers; and closing the window lets go of the book.
    func testABookIsEditedSavedExportedAndClosed() async throws {
        // Three phrases at steady levels a sample tells apart, with a pause
        // after each of the first two: 0.4 for a second, 0.8 seconds of
        // silence, 0.2 for a second, 0.6 seconds of silence, and 0.1 for a
        // second.
        let fixture = try AudioEditorTestBook.make(named: "Ferry Notes.wav", for: self) { url in
            try AudioTestFixtures.writeTones([
                .init(seconds: 1, frequency: 0, amplitude: 0.4),
                .silence(0.8),
                .init(seconds: 1, frequency: 0, amplitude: 0.2),
                .silence(0.6),
                .init(seconds: 1, frequency: 0, amplitude: 0.1),
            ], to: url, sampleRate: AudioEditorTestBook.rate)
        }
        fixture.library.audioFilterEngine = { .builtIn }
        let script = LauncherScript()
        let opened = await AudioEditorLauncher.open(fixture.book, in: fixture.library, from: nil, controller: script.windows, services: script.services)
        XCTAssertEqual(opened, .opened(track: nil))
        let harness = try EditorHarness.make(session: try XCTUnwrap(script.presented.first?.session), of: fixture, for: self)
        let model = harness.model
        addTeardownBlock { @MainActor in model.windowClosed() }
        AudioEditorPreferences.playAfterMoves.write(false, to: harness.store)
        XCTAssertTrue(fixture.library.audioEditActivity.isBeingEdited(fixture.book.id))

        // The second phrase, found between the pauses, moves to the end.
        await model.loadPreview()
        let found = await eventually(timeout: 10) { model.pauseSearch == .found }
        XCTAssertTrue(found, "the pauses were never found: \(model.pauseSearch)")
        model.perform(.editorNextPause)
        model.perform(.editorSelectToNextPause)
        XCTAssertEqual(harness.announcements.sentences.last, "Selected 1.6 seconds.")
        await model.cut()
        model.perform(.editorGoToEnd)
        await model.paste()
        XCTAssertEqual(model.undoName, "Move 1.6 Seconds")
        XCTAssertEqual(model.duration, 4.4, accuracy: 0.000_1)

        // Chapter markers at the start and where the moved phrase begins.
        model.perform(.editorGoToStart)
        await model.insertChapter(titled: "Crossing")
        model.move(to: 2.8)
        await model.insertChapter(titled: "Return")
        XCTAssertEqual(model.chapters.map(\.title), ["Crossing", "Return"])

        // A filter over the whole file.
        await model.applyFilter(AudioFilterPreset(id: UUID(), name: "Quieter", chain: "volume=-6dB"), to: .wholeFile)
        XCTAssertEqual(harness.announcements.sentences.last, "Applied Quieter to all of the audio. Now 4.4 seconds long.")

        // A recording inserted at the end, with nothing selected, which
        // Undo takes back and Redo brings back.
        model.perform(.editorClearSelection)
        model.perform(.editorGoToEnd)
        await model.startPunchIn()
        await harness.backend.record(seconds: 0.5)
        await model.stopPunchIn()
        XCTAssertEqual(model.undoName, "Insert 0.5 Seconds of Audio")
        XCTAssertEqual(model.duration, 4.9, accuracy: 0.000_1)
        await model.undo()
        XCTAssertEqual(model.duration, 4.4, accuracy: 0.000_1)
        await model.redo()
        XCTAssertEqual(model.duration, 4.9, accuracy: 0.000_1)

        // Save writes every edit into the book's WAV file, which holds no
        // chapter markers, as it says; the library measures the book again.
        // The book keeps its original, so its edits, chapter markers and
        // all, stay to export, whatever the global setting.
        await model.setPolicy(.keep, days: 1)
        let saved = await model.save()
        XCTAssertTrue(saved)
        XCTAssertTrue(harness.announcements.sentences.contains(
            "Saving 4.9 seconds of audio as WAV, the format this book keeps. "
                + "WAV files can't hold chapter markers, so its 2 chapter markers are left out of this file."
        ), "\(harness.announcements.sentences)")
        XCTAssertEqual(harness.announcements.sentences.last, "Saved. The book's audio is now 4.9 seconds long.")
        XCTAssertEqual(fixture.library.bookByID(fixture.book.id)?.audioDuration ?? 0, 4.9, accuracy: 0.01)
        let samples = try AudioTestFixtures.floatSamples(of: fixture.book.bookFileURL)
        let gain = Float(pow(10, -6.0 / 20))
        XCTAssertEqual(samples.count, 39_200)
        XCTAssertEqual(samples[checked: 4_000] ?? 0, 0.4 * gain, accuracy: 0.001, "the first phrase")
        XCTAssertEqual(samples[checked: 11_200] ?? 1, 0, accuracy: 0.001, "the first pause")
        XCTAssertEqual(samples[checked: 18_400] ?? 0, 0.1 * gain, accuracy: 0.001, "the third phrase, second now")
        XCTAssertEqual(samples[checked: 26_400] ?? 0, 0.2 * gain, accuracy: 0.001, "the second phrase, moved")
        XCTAssertEqual(samples[checked: 32_800] ?? 1, 0, accuracy: 0.001, "the pause moved with it")
        XCTAssertEqual(AudioTestFixtures.peak(samples.suffix(4_000)), 0.25, accuracy: 0.01, "the recording")

        // An export as M4B keeps the chapter markers where they were set.
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("ferry-\(UUID().uuidString).m4b")
        addTeardownBlock { try? FileManager.default.removeItem(at: destination) }
        await model.export(as: .m4b, to: destination)
        XCTAssertEqual(harness.announcements.sentences.last, "Exported “\(destination.lastPathComponent)”.")
        let chapters = await AudioPlaybackService.extractChapters(from: destination)
        XCTAssertEqual(chapters.map(\.title), ["Crossing", "Return"])
        XCTAssertEqual(chapters[checked: 1]?.startTime ?? -1, 2.8, accuracy: 0.02)

        // Closing the window lets go of the book.
        model.windowClosed()
        XCTAssertFalse(fixture.library.audioEditActivity.isBeingEdited(fixture.book.id))
        XCTAssertTrue(harness.player.isClosed)
    }

    /// A chapter marker set in an M4B audiobook is saved into its file,
    /// beside the chapters it had, with nothing said of chapters left out.
    func testAChapterMarkerIsSavedIntoAnM4B() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("tales-\(UUID().uuidString).m4b")
        addTeardownBlock { try? FileManager.default.removeItem(at: source) }
        try await AudioTestFixtures.writeChapteredAAC(to: source, duration: 6, chapters: [
            .init(title: "Quay", start: 0, duration: 3),
            .init(title: "Locks", start: 3, duration: 3),
        ])
        let fixture = try AudioEditorTestBook.make(named: "Ferry Tales.m4b", for: self) { url in
            try FileManager.default.copyItem(at: source, to: url)
        }
        let harness = try await EditorHarness.open(fixture, for: self)
        let model = harness.model
        addTeardownBlock { @MainActor in model.windowClosed() }
        AudioEditorPreferences.playAfterMoves.write(false, to: harness.store)
        XCTAssertEqual(model.chapters.map(\.title), ["Quay", "Locks"])

        model.move(to: 4.5)
        await model.insertChapter(titled: "Weir")
        let saved = await model.save()

        XCTAssertTrue(saved)
        let saving = try XCTUnwrap(harness.announcements.sentences.first { $0.hasPrefix("Saving ") })
        XCTAssertTrue(saving.hasSuffix(" of audio as M4B audiobook (AAC), the format this book keeps."), saving)
        let chapters = await AudioPlaybackService.extractChapters(from: fixture.book.bookFileURL)
        XCTAssertEqual(chapters.map(\.title), ["Quay", "Locks", "Weir"])
        XCTAssertEqual(chapters[checked: 2]?.startTime ?? -1, 4.5, accuracy: 0.05)
    }
}
