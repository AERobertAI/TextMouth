import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Recordings a crash left behind (FR04): the takes in the Recordings
/// folder that no window's recorder holds, the Record window's or an audio
/// editor's, are found, each with when it was recorded, read from its name,
/// and how long it lasts, read from its file, even one a crash cut off; the
/// window lists them, says so once, and saves each as an audiobook titled
/// for when it was recorded, or discards it with what a cut-off save left
/// beside it; and nothing is ever deleted on its own. Every take is a file
/// the test writes or a fake recorder makes: nothing is recorded or spoken.
@MainActor
final class RecordingRecoveryTests: XCTestCase {

    /// When the takes of these tests were recorded: whole seconds, as a
    /// take's name keeps them.
    private nonisolated static let recordedAt = Date(timeIntervalSince1970: 1_790_990_000)

    // MARK: - Finding Takes

    /// A take's name gives when it started; a name of another form gives
    /// nothing; a take's encoding sits beside it as an M4A.
    func testATakesNameGivesWhenItStarted() throws {
        let folder = try RecordingAudioFixtures.makeTakesFolder(for: self)
        let url = try RecordingTakeFiles.newTakeURL(startedAt: Self.recordedAt, in: folder)

        XCTAssertEqual(RecordingTakeFiles.startDate(fromName: url.lastPathComponent), Self.recordedAt)
        XCTAssertNil(RecordingTakeFiles.startDate(fromName: "Interview.caf"))
        XCTAssertNil(RecordingTakeFiles.startDate(fromName: "Take soon.caf"))
        XCTAssertEqual(
            RecordingTakeFiles.encodingURL(for: url).lastPathComponent,
            url.deletingPathExtension().lastPathComponent + ".m4a"
        )
    }

    /// The takes in the folder are found oldest first, each with when it
    /// started and how long it lasts; those a window holds, hidden files,
    /// and files of other kinds, such as the encoding a cut-off save left,
    /// are left out; and finding them deletes nothing.
    func testTakesLeftBehindAreFoundOldestFirst() async throws {
        let folder = try RecordingAudioFixtures.makeTakesFolder(for: self)
        let later = try writeTake(in: folder, startedAt: Self.recordedAt.addingTimeInterval(3_600), seconds: 2)
        let earlier = try writeTake(in: folder, startedAt: Self.recordedAt, seconds: 1.5)
        let held = try writeTake(in: folder, startedAt: Self.recordedAt.addingTimeInterval(7_200), seconds: 1)
        try Data("encoded".utf8).write(to: RecordingTakeFiles.encodingURL(for: earlier))
        try Data("hidden".utf8).write(to: folder.appendingPathComponent(".DS_Store"))

        let found = await RecordingTakeFiles.readLeftovers(in: folder)
        let unheld = RecordingTakeFiles.leftovers(in: folder, excluding: [held])

        XCTAssertEqual(found.map(\.url), [earlier, later, held])
        XCTAssertEqual(found.map(\.startedAt), [0, 3_600, 7_200].map { Self.recordedAt.addingTimeInterval($0) })
        XCTAssertEqual(found.first?.duration ?? 0, 1.5, accuracy: 0.001)
        XCTAssertEqual(found.first?.take?.deviceName, "", "a take left behind does not know its microphone")
        XCTAssertEqual(unheld.map(\.url), [earlier, later])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 5, "finding takes deleted a file")
    }

    /// A take a crash cut off, its data running to wherever writing stopped,
    /// part of a frame included, with no size recorded, as capture leaves it
    /// while it records, still reads as long as the sound it holds.
    func testATakeACrashCutOffIsFoundWithTheSoundItHolds() throws {
        let folder = try RecordingAudioFixtures.makeTakesFolder(for: self)
        let url = try writeTake(in: folder, startedAt: Self.recordedAt, seconds: 2)
        try Self.cutOff(url, keepingFrames: 12_000)

        let found = RecordingTakeFiles.leftovers(in: folder)

        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.duration ?? 0, 1.5, accuracy: 0.001, "the take does not read as long as what it holds")
    }

    // MARK: - The Window

    /// A window opening on a folder that holds a take left behind lists it,
    /// with when it was recorded and how long it lasts, and says so once.
    func testTheWindowListsATakeLeftBehindAndSaysSoOnce() async throws {
        let folder = try RecordingAudioFixtures.makeTakesFolder(for: self)
        let url = try writeTake(in: folder, startedAt: Self.recordedAt, seconds: 4)

        let harness = try RecordingWindowHarness(test: self, takesFolder: folder)
        await harness.model.refreshRecoveredTakes()
        await harness.model.refreshRecoveredTakes()

        XCTAssertEqual(harness.model.recoveredTakes.map(\.url), [url])
        XCTAssertEqual(harness.model.recoveredTakes.first?.startedAt, Self.recordedAt)
        XCTAssertEqual(harness.model.recoveredTakes.first?.duration ?? 0, 4, accuracy: 0.001)
        let announcement = RecordingWording.recoveredAnnouncement(count: 1)
        let told = await eventually { harness.announcements.sentences.contains(announcement) }
        XCTAssertTrue(told)
        XCTAssertEqual(harness.announcements.sentences.filter { $0 == announcement }.count, 1, "announced more than once")
        XCTAssertNil(harness.model.recoveredTakeFocusedAtOpen, "a window the user opened moved VoiceOver to the list")
        XCTAssertTrue(harness.model.canHandleRecoveredTakes)
    }

    /// A take left behind is saved as an audiobook titled for when it was
    /// recorded, in the folder chosen, from its own file; it leaves the
    /// list, and the Title field stays for the next recording.
    func testATakeLeftBehindIsSavedUnderItsOwnDate() async throws {
        let folder = try RecordingAudioFixtures.makeTakesFolder(for: self)
        let url = try writeTake(in: folder, startedAt: Self.recordedAt, seconds: 4)
        let harness = try RecordingWindowHarness(test: self, takesFolder: folder)
        await harness.model.refreshRecoveredTakes()
        harness.model.folderPath = "Fiction"
        harness.model.title = "Kitchen Notes"
        let recovered = try XCTUnwrap(harness.model.recoveredTakes.first)

        await harness.model.saveRecovered(recovered)

        let call = try XCTUnwrap(harness.saver.calls.first)
        XCTAssertEqual(harness.saver.calls.count, 1)
        XCTAssertEqual(call.title, RecordingWording.defaultTitle(at: Self.recordedAt))
        XCTAssertEqual(call.folderPath, "Fiction")
        XCTAssertEqual(call.take.url, url)
        XCTAssertEqual(call.take.startedAt, Self.recordedAt)
        XCTAssertEqual(call.take.duration, 4, accuracy: 0.001)
        XCTAssertEqual(harness.model.recoveredTakes, [])
        XCTAssertEqual(harness.model.title, "Kitchen Notes", "the Title field was replaced")
        guard case .saved(let book) = harness.model.phase else {
            return XCTFail("not saved: \(harness.model.phase)")
        }
        XCTAssertEqual(book.title, call.title)
        XCTAssertEqual(harness.announcements.sentences.last, RecordingWording.savedAnnouncement(title: call.title))
    }

    /// A take left behind that can't be saved becomes the window's, out of
    /// the list, and Save Again saves it under its own date, not the Title
    /// field's.
    func testAFailedSaveOfATakeLeftBehindIsSavedAgainUnderItsOwnDate() async throws {
        let folder = try RecordingAudioFixtures.makeTakesFolder(for: self)
        let url = try writeTake(in: folder, startedAt: Self.recordedAt, seconds: 2)
        let harness = try RecordingWindowHarness(test: self, takesFolder: folder)
        await harness.model.refreshRecoveredTakes()
        harness.saver.failure = CocoaError(.fileWriteOutOfSpace)

        await harness.model.saveRecovered(try XCTUnwrap(harness.model.recoveredTakes.first))

        guard case .saveFailed(let take, _) = harness.model.phase else {
            return XCTFail("the failure was not kept: \(harness.model.phase)")
        }
        XCTAssertEqual(take.url, url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        await harness.model.refreshRecoveredTakes()
        XCTAssertEqual(harness.model.recoveredTakes, [], "the window's own take was listed as left behind")
        XCTAssertFalse(harness.model.canHandleRecoveredTakes)

        harness.saver.failure = nil
        await harness.model.saveAgain()

        XCTAssertEqual(harness.saver.calls.map(\.title), Array(repeating: RecordingWording.defaultTitle(at: Self.recordedAt), count: 2))
        guard case .saved = harness.model.phase else {
            return XCTFail("Save Again did not save: \(harness.model.phase)")
        }
    }

    /// Discard deletes a take left behind, with the encoding a cut-off save
    /// left beside it, says which, and leaves the other takes alone.
    func testDiscardDeletesATakeLeftBehindAndItsEncoding() async throws {
        let folder = try RecordingAudioFixtures.makeTakesFolder(for: self)
        let discarded = try writeTake(in: folder, startedAt: Self.recordedAt, seconds: 2)
        let kept = try writeTake(in: folder, startedAt: Self.recordedAt.addingTimeInterval(60), seconds: 1)
        let encoding = RecordingTakeFiles.encodingURL(for: discarded)
        try Data("encoded".utf8).write(to: encoding)
        let harness = try RecordingWindowHarness(test: self, takesFolder: folder)
        await harness.model.refreshRecoveredTakes()
        let recovered = try XCTUnwrap(harness.model.recoveredTakes.first)

        harness.model.discardRecovered(recovered)

        XCTAssertFalse(FileManager.default.fileExists(atPath: discarded.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: encoding.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertEqual(harness.model.recoveredTakes.map(\.url), [kept])
        XCTAssertEqual(
            harness.announcements.sentences.last,
            RecordingWording.recoveredDiscarded(RecordingWording.recoveredTake(startedAt: Self.recordedAt, duration: recovered.duration))
        )
        XCTAssertEqual(harness.saver.calls.count, 0)
    }

    /// Nothing left behind is deleted on its own: takes stay through a
    /// window closing and another opening, and one holding no sound is
    /// listed too, to discard, as it can't be saved.
    func testNothingLeftBehindIsDeletedOnItsOwn() async throws {
        let folder = try RecordingAudioFixtures.makeTakesFolder(for: self)
        let sound = try writeTake(in: folder, startedAt: Self.recordedAt, seconds: 2)
        let silent = try writeTake(in: folder, startedAt: Self.recordedAt.addingTimeInterval(60), seconds: 0)
        let first = try RecordingWindowHarness(test: self, takesFolder: folder)
        await first.model.refreshRecoveredTakes()
        XCTAssertEqual(first.model.recoveredTakes.map(\.url), [sound, silent])
        first.model.windowClosed()

        let second = try RecordingWindowHarness(test: self, takesFolder: folder)
        await second.model.refreshRecoveredTakes()

        XCTAssertEqual(second.model.recoveredTakes.map(\.url), [sound, silent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sound.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: silent.path))
        let empty = try XCTUnwrap(second.model.recoveredTakes.last)
        XCTAssertNil(empty.take, "a take holding no sound can be saved")
        XCTAssertEqual(
            RecordingWording.recoveredTake(startedAt: empty.startedAt, duration: empty.duration),
            RecordingWording.recoveredTake(startedAt: empty.startedAt, duration: nil)
        )
        await second.model.saveRecovered(empty)
        XCTAssertEqual(second.saver.calls.count, 0)
        second.model.discardRecovered(empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: silent.path))
    }

    /// The window's own take, recorded, failing to save, or saved, is never
    /// taken for one left behind; while it is recorded, or waits to be saved
    /// again, takes left behind wait.
    func testTheWindowsOwnTakeIsNeverLeftBehind() async throws {
        let harness = try RecordingWindowHarness(test: self)
        await harness.model.record()
        await harness.backend.record(seconds: 1)

        await harness.model.refreshRecoveredTakes()
        XCTAssertEqual(harness.model.recoveredTakes, [], "the take being recorded was listed")
        XCTAssertFalse(harness.model.canHandleRecoveredTakes)

        harness.saver.failure = CocoaError(.fileWriteOutOfSpace)
        await harness.model.stop()
        await harness.model.refreshRecoveredTakes()
        XCTAssertEqual(harness.model.recoveredTakes, [], "the take waiting to be saved again was listed")
        XCTAssertFalse(harness.model.canHandleRecoveredTakes)

        harness.saver.failure = nil
        await harness.model.saveAgain()
        await harness.model.refreshRecoveredTakes()
        XCTAssertEqual(harness.model.recoveredTakes, [])
        XCTAssertTrue(harness.model.canHandleRecoveredTakes)
    }

    /// A take another window's recorder holds, as an audio editor's
    /// punch-in recorded into the same folder, is never taken for one left
    /// behind, while it is recorded or once it has stopped; when that
    /// recorder lets it go without removing it, as a punch-in whose edit
    /// could not be kept, it is left behind and listed.
    func testATakeAnotherWindowsRecorderHoldsIsNeverLeftBehind() async throws {
        let folder = try RecordingAudioFixtures.makeTakesFolder(for: self)
        let leftBehind = try writeTake(in: folder, startedAt: Self.recordedAt, seconds: 2)
        let editorBackend = FakeCaptureBackend()
        let editorRecorder = RecordingService(
            backend: editorBackend,
            permission: FakeMicrophonePermission(.authorized).permission,
            takesFolder: folder,
            pollInterval: nil
        )
        await editorRecorder.start(from: TestMicrophones.builtIn)
        await editorBackend.record(seconds: 1)
        let punchIn = try XCTUnwrap(editorRecorder.takeInUse, "the editor's recorder holds no take")
        XCTAssertTrue(FileManager.default.fileExists(atPath: punchIn.path))
        let harness = try RecordingWindowHarness(test: self, takesFolder: folder)

        await harness.model.refreshRecoveredTakes()
        XCTAssertEqual(harness.model.recoveredTakes.map(\.url), [leftBehind], "the punch-in being recorded was listed")

        await editorRecorder.stop()
        await harness.model.refreshRecoveredTakes()
        XCTAssertEqual(harness.model.recoveredTakes.map(\.url), [leftBehind], "the punch-in that stopped was listed")

        editorRecorder.reset()
        await harness.model.refreshRecoveredTakes()
        XCTAssertEqual(Set(harness.model.recoveredTakes.map(\.url)), [leftBehind, punchIn])
    }

    /// A window launch opens on takes left behind lists them at once and
    /// asks once to start VoiceOver on the first one's Save as Audiobook,
    /// not on the Microphone pop-up.
    func testAWindowOpenedOnTakesLeftBehindStartsVoiceOverOnTheFirst() throws {
        let folder = try RecordingAudioFixtures.makeTakesFolder(for: self)
        let first = try writeTake(in: folder, startedAt: Self.recordedAt, seconds: 2)
        _ = try writeTake(in: folder, startedAt: Self.recordedAt.addingTimeInterval(60), seconds: 1)
        let recovered = RecordingTakeFiles.leftovers(in: folder)

        let harness = try RecordingWindowHarness(test: self, takesFolder: folder, recovered: recovered)

        XCTAssertEqual(harness.model.recoveredTakes, recovered)
        XCTAssertEqual(harness.model.recoveredTakeFocusedAtOpen, first)
        withHostedView(RecordingWindowView(model: harness.model), size: NSSize(width: 560, height: 760), until: {
            !self.descendants(of: $0, as: VoiceOverFocusTriggerView.self).isEmpty
        }) { hosting in
            XCTAssertEqual(descendants(of: hosting, as: VoiceOverFocusTriggerView.self).count, 1)
            let targets = accessibilityElements(identified: voiceOverFocusID, in: hosting)
            if !targets.isEmpty {
                let take = RecordingWording.recoveredTake(startedAt: Self.recordedAt, duration: recovered.first?.duration)
                XCTAssertEqual(targets.map { $0.accessibilityLabel() ?? "" }, [RecordingWording.saveRecoveredLabel(take)])
            }
        }
    }

    // MARK: - Words

    /// A take left behind is named by when it was recorded and how long it
    /// lasts, or as holding no sound; each button names its take; and the
    /// announcement counts the takes.
    func testTheWordsOfTakesLeftBehind() {
        let when = Self.recordedAt.formatted(date: .long, time: .shortened)
        let take = RecordingWording.recoveredTake(startedAt: Self.recordedAt, duration: 64.4)

        XCTAssertEqual(take, "Recording of \(when), 1 minute, 4 seconds")
        XCTAssertEqual(RecordingWording.recoveredTake(startedAt: Self.recordedAt, duration: nil), "Recording of \(when), which holds no sound")
        XCTAssertEqual(RecordingWording.saveRecoveredLabel(take), "Save as Audiobook: \(take)")
        XCTAssertEqual(RecordingWording.discardRecoveredLabel(take), "Discard: \(take)")
        XCTAssertEqual(RecordingWording.recoveredDiscarded(take), "Discarded the recording of \(when), 1 minute, 4 seconds.")
        XCTAssertTrue(RecordingWording.recoveredAnnouncement(count: 1).hasPrefix("TextMouth kept a recording from before it last quit"))
        XCTAssertTrue(RecordingWording.recoveredAnnouncement(count: 3).hasPrefix("TextMouth kept 3 recordings from before it last quit"))
    }

    // MARK: - Helpers

    /// Writes a take in `folder`, named for `startedAt`, holding `seconds`
    /// of tone, none for 0, as capture writes takes.
    private func writeTake(in folder: URL, startedAt: Date, seconds: TimeInterval) throws -> URL {
        let url = try RecordingTakeFiles.newTakeURL(startedAt: startedAt, in: folder)
        try RecordingAudioFixtures.writeTake(to: url, duration: seconds)
        return url
    }

    /// Cuts the take at `url` off as a crash would: its data chunk's size
    /// becomes −1, "to the end of the file", as it is while capture records,
    /// and the file ends `frames` frames of 16-bit mono into the data, with
    /// half a frame more. Reads the file's chunks only while whole headers
    /// remain, so a file of another layout fails the test.
    private static func cutOff(_ url: URL, keepingFrames frames: Int) throws {
        var bytes = [UInt8](try Data(contentsOf: url))
        // The file header, "caff" and its version and flags, takes 8 bytes;
        // each chunk then has a type of 4 bytes and a size of 8.
        var offset = 8
        var dataChunk: Int?
        while offset + 12 <= bytes.count {
            let type = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
            if type == "data" {
                dataChunk = offset
                break
            }
            let size = bytes[offset + 4..<offset + 12].reduce(0) { ($0 << 8) | Int($1) }
            guard size >= 0 else { break }
            offset += 12 + size
        }
        let chunk = try XCTUnwrap(dataChunk, "the take has no data chunk")
        for index in chunk + 4..<chunk + 12 {
            bytes[index] = 0xFF
        }
        // The data starts with a four-byte edit count, then the frames.
        let end = chunk + 12 + 4 + frames * 2 + 1
        guard end <= bytes.count else {
            return XCTFail("the take is shorter than \(frames) frames")
        }
        try Data(bytes[0..<end]).write(to: url)
    }
}
