import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The Record window (FR04), as VoiceOver, a braille display, and the
/// keyboard meet it: its words, what its model does with a recorder that
/// needs no microphone, its controls' labels read the way VoiceOver reads
/// them, and its shortcuts, which clash with no menu command and no default
/// shortcut of the reader or the library. Every announcement is caught by
/// the test; nothing is spoken and nothing is recorded.
@MainActor
final class RecordingWindowTests: XCTestCase {

    /// When every window in these tests opened.
    private nonisolated static let opened = RecordingWindowHarness.opensAt

    // MARK: - Words

    /// A recording is titled "Recording" and when it was made, to the
    /// minute, as New from Text titles a paste; its folder pop-up names the
    /// top of the library "Library".
    func testTheDefaultTitleAndFolderNames() {
        let title = RecordingWording.defaultTitle(at: Self.opened)
        XCTAssertNotNil(title.range(of: #"^Recording \d{4}-\d{2}-\d{2} \d{2}:\d{2}$"#, options: .regularExpression), title)
        XCTAssertEqual(title, TextImportPolicy.timestampedTitle("Recording", at: Self.opened))
        XCTAssertEqual(TextImportPolicy.defaultTitle(for: Self.opened), TextImportPolicy.timestampedTitle("Paste", at: Self.opened))
        XCTAssertEqual(TextImportPolicy.fileName(for: "Day 3: Notes", extension: "m4a"), "Day 3- Notes.m4a")
        XCTAssertEqual(RecordingWording.folderName(""), "Library")
        XCTAssertEqual(RecordingWording.folderName("Fiction/Sci-Fi"), "Library / Fiction / Sci-Fi")
    }

    /// The level is judged by its peak: silent, quiet, good for a voice,
    /// loud, or too loud.
    func testTheLevelIsJudgedByItsPeak() {
        XCTAssertEqual(RecordingWording.loudness(peak: -.infinity), .silent)
        XCTAssertEqual(RecordingWording.loudness(peak: -90), .silent)
        XCTAssertEqual(RecordingWording.loudness(peak: -50), .quiet)
        XCTAssertEqual(RecordingWording.loudness(peak: -18), .good)
        XCTAssertEqual(RecordingWording.loudness(peak: -6), .loud)
        XCTAssertEqual(RecordingWording.loudness(peak: -0.5), .tooLoud)
        XCTAssertEqual(RecordingWording.loudness(peak: .nan), .silent)
    }

    /// The level shows in figures and is spoken in words, briefly enough
    /// for a braille display: the peak and how loud it is.
    func testTheLevelIsShownAndSpoken() {
        let levels = RecordingLevels(average: -24.4, peak: -11.6)
        XCTAssertEqual(RecordingWording.levelText(levels), "Level: \u{2212}12 dB peak, \u{2212}24 dB average, good")
        XCTAssertEqual(RecordingWording.levelValue(levels), "minus 12 decibels, good")
        XCTAssertEqual(RecordingWording.levelAnnouncement(levels), "Level minus 12 decibels, good")
        XCTAssertEqual(RecordingWording.levelValue(RecordingLevels(average: -2, peak: -1)), "minus 1 decibel, loud")
        XCTAssertEqual(RecordingWording.levelText(nil), "Level: not recording")
        XCTAssertEqual(RecordingWording.levelValue(nil), "Not recording")
        XCTAssertEqual(RecordingWording.levelValue(RecordingLevels(average: -160, peak: -160)), "Silent")
        XCTAssertEqual(RecordingWording.levelAnnouncement(nil), "Level not recording")
    }

    /// The elapsed time shows as a clock and is spoken in words.
    func testTheElapsedTimeIsShownAndSpoken() {
        XCTAssertEqual(RecordingWording.elapsedText(64.7), "Elapsed: 1:04")
        XCTAssertEqual(RecordingWording.elapsedValue(64.7), "1 minute, 4 seconds")
        XCTAssertEqual(RecordingWording.elapsedText(3_725), "Elapsed: 1:02:05")
    }

    /// Each button's hint says what it does and its shortcut; Record names
    /// the microphone it records from.
    func testTheButtonsSayWhatTheyDoAndTheirShortcuts() {
        XCTAssertEqual(RecordingWording.recordHint(device: "AirPods Pro"), "Starts recording from AirPods Pro. Shortcut: Command-R.")
        XCTAssertEqual(RecordingWording.recordHint(device: nil), "Starts recording once a microphone is connected. Shortcut: Command-R.")
        XCTAssertTrue(RecordingWording.pauseHint.hasSuffix("Shortcut: Command-P."))
        XCTAssertTrue(RecordingWording.resumeHint.hasSuffix("Shortcut: Command-P."))
        XCTAssertTrue(RecordingWording.stopHint.hasSuffix("Shortcut: Command-Period."))
        XCTAssertEqual(RecordingWording.savedAnnouncement(title: "Notes"), "Saved Recording as Notes")
        XCTAssertNil(CloseQuestion(need: .nothing))
        XCTAssertEqual(CloseQuestion(need: .stopOrDiscard)?.title, "Stop and save the recording?")
        XCTAssertEqual(CloseQuestion(need: .stopOrDiscard)?.saveButton, "Stop and Save")
        XCTAssertEqual(CloseQuestion(need: .saveOrDiscard)?.title, "Save the recording?")
        XCTAssertEqual(CloseQuestion(need: .saveOrDiscard)?.saveButton, "Save")
    }

    // MARK: - Choosing a Microphone

    /// The window opens on the remembered microphone, saying nothing about
    /// it, and is ready to record from it.
    func testTheWindowOpensOnTheRememberedMicrophone() throws {
        let harness = try RecordingWindowHarness(test: self, remembered: TestMicrophones.usb.id)

        XCTAssertEqual(harness.model.selectedDeviceID, TestMicrophones.usb.id)
        XCTAssertEqual(harness.model.status, "Ready to record from Studio Microphone.")
        XCTAssertEqual(harness.announcements.sentences, [])
        XCTAssertEqual(harness.model.devices.map(\.name), ["MacBook Air Microphone", "AirPods Pro", "Studio Microphone"])
    }

    /// A remembered microphone that is not connected falls back to the
    /// default, says so, and stays remembered for when it is back.
    func testAMissingMicrophoneFallsBackAndIsStillRemembered() throws {
        let harness = try RecordingWindowHarness(
            test: self,
            devices: [TestMicrophones.builtIn, TestMicrophones.airPods],
            systemDefault: TestMicrophones.airPods.id,
            remembered: TestMicrophones.usb.id
        )

        XCTAssertEqual(harness.model.selectedDeviceID, TestMicrophones.airPods.id)
        let sentence = "The microphone TextMouth used last isn't connected, so recordings use AirPods Pro."
        XCTAssertEqual(harness.announcements.sentences, [sentence])
        XCTAssertEqual(harness.model.status, sentence)
        XCTAssertEqual(RecordingInputChoice.preference.read(from: harness.store), TestMicrophones.usb.id)

        harness.catalog.change(to: [TestMicrophones.builtIn, TestMicrophones.airPods, TestMicrophones.usb])
        XCTAssertEqual(harness.model.selectedDeviceID, TestMicrophones.usb.id, "the remembered microphone was not used again")
        XCTAssertEqual(harness.announcements.sentences.last, "Studio Microphone was connected, so recordings use it.")
    }

    /// A microphone connected while the window is open is listed at once and
    /// said to be there, recordings still using the one chosen; one
    /// connected when there was none is used; and nothing is said while a
    /// recording could pick it up, though the list follows.
    func testAMicrophoneConnectedWhileTheWindowIsOpenIsListedAndSaid() async throws {
        let harness = try RecordingWindowHarness(test: self, devices: [], remembered: "")
        XCTAssertNil(harness.model.selectedDevice)

        harness.catalog.change(to: [TestMicrophones.builtIn])
        XCTAssertEqual(harness.model.selectedDeviceID, TestMicrophones.builtIn.id)
        XCTAssertEqual(harness.announcements.sentences.last, "MacBook Air Microphone was connected, so recordings use it.")

        harness.catalog.change(to: [TestMicrophones.builtIn, TestMicrophones.airPods, TestMicrophones.usb])
        XCTAssertEqual(harness.model.devices.map(\.name), ["MacBook Air Microphone", "AirPods Pro", "Studio Microphone"])
        XCTAssertEqual(harness.model.selectedDeviceID, TestMicrophones.builtIn.id, "a new microphone was chosen for the user")
        XCTAssertEqual(
            harness.announcements.sentences.last,
            RecordingWording.microphonesConnected(["AirPods Pro", "Studio Microphone"])
        )
        XCTAssertTrue(harness.announcements.sentences.last?.hasSuffix("were connected; choose one in the Microphone pop-up to record from it.") ?? false)

        harness.catalog.change(to: [TestMicrophones.builtIn, TestMicrophones.airPods])
        XCTAssertEqual(harness.model.devices.map(\.name), ["MacBook Air Microphone", "AirPods Pro"])
        XCTAssertEqual(harness.model.status, "Ready to record from MacBook Air Microphone.")

        await harness.model.record()
        let said = harness.announcements.sentences.count
        harness.catalog.change(to: [TestMicrophones.builtIn, TestMicrophones.airPods, TestMicrophones.usb])
        XCTAssertEqual(harness.model.devices.count, 3, "the list stopped following while recording")
        XCTAssertEqual(harness.announcements.sentences.count, said, "a connection was announced while recording")
        await harness.model.stop()
    }

    /// The Microphone pop-up itself follows a microphone connected while
    /// the window is open, as the catalog reports it.
    func testTheMicrophonePopUpListsAMicrophoneConnectedWhileOpen() throws {
        let harness = try RecordingWindowHarness(test: self, devices: [TestMicrophones.builtIn])

        withHostedView(RecordingWindowView(model: harness.model), size: NSSize(width: 520, height: 640), until: {
            !self.descendants(of: $0, as: NSPopUpButton.self).isEmpty
        }) { hosting in
            let microphone = { () -> NSPopUpButton? in
                self.descendants(of: hosting, as: NSPopUpButton.self).first { $0.itemTitles.contains("MacBook Air Microphone") }
            }
            XCTAssertEqual(microphone()?.itemTitles, ["MacBook Air Microphone"])

            harness.catalog.change(to: [TestMicrophones.builtIn, TestMicrophones.airPods])

            XCTAssertTrue(waitUntil(timeout: 5) {
                hosting.layoutSubtreeIfNeeded()
                return microphone()?.itemTitles == ["MacBook Air Microphone", "AirPods Pro"]
            }, "the pop-up lists \(microphone()?.itemTitles ?? [])")
        }
    }

    /// The level announcement is remembered: a window opened later, as on
    /// the next launch, announces the level as the last one was left, at its
    /// interval, kept within 5 to 60 seconds.
    func testTheLevelAnnouncementIsRememberedByTheNextWindow() async throws {
        let store = makeSandboxedPreferences("recording-level")
        let first = try RecordingWindowHarness(test: self, store: store)
        XCTAssertFalse(first.model.announcesLevel)
        XCTAssertEqual(first.model.levelAnnouncementInterval, 10)

        first.model.announcesLevel = true
        first.model.levelAnnouncementInterval = 20
        first.model.windowClosed()
        let second = try RecordingWindowHarness(test: self, store: store)

        XCTAssertTrue(second.model.announcesLevel)
        XCTAssertEqual(second.model.levelAnnouncementInterval, 20)
        XCTAssertEqual(RecordingWording.announceIntervals, 5...60)
        RecordingLevelAnnouncements.interval.write(500, to: store)
        XCTAssertEqual(RecordingLevelAnnouncements.interval.read(from: store), 60)

        await second.model.record()
        await second.backend.record(seconds: 1, levels: RecordingLevels(average: -30, peak: -15))
        await second.model.service.refresh()
        let before = second.announcements.sentences.count
        for _ in 0..<20 { second.model.tick() }
        XCTAssertEqual(Array(second.announcements.sentences.dropFirst(before)), ["Level minus 15 decibels, good"])
        await second.model.stop()
    }

    /// Choosing a microphone uses it and remembers it, apart from macOS's
    /// input.
    func testAChosenMicrophoneIsRemembered() throws {
        let harness = try RecordingWindowHarness(test: self)

        harness.model.chooseDevice(TestMicrophones.airPods.id)

        XCTAssertEqual(harness.model.selectedDeviceID, TestMicrophones.airPods.id)
        XCTAssertEqual(RecordingInputChoice.preference.read(from: harness.store), TestMicrophones.airPods.id)
        harness.model.chooseDevice("not-connected")
        XCTAssertEqual(harness.model.selectedDeviceID, TestMicrophones.airPods.id)
    }

    /// The microphone in use unplugged while nothing records falls back to
    /// the default, saying why; with none left, Record cannot be pressed.
    func testAnUnpluggedMicrophoneFallsBackSayingWhy() throws {
        let harness = try RecordingWindowHarness(test: self, systemDefault: TestMicrophones.builtIn.id, remembered: TestMicrophones.usb.id)

        harness.catalog.change(to: [TestMicrophones.builtIn])
        XCTAssertEqual(harness.model.selectedDeviceID, TestMicrophones.builtIn.id)
        XCTAssertEqual(harness.announcements.sentences.last, "Studio Microphone was disconnected, so recordings use MacBook Air Microphone.")

        harness.catalog.change(to: [])
        XCTAssertNil(harness.model.selectedDevice)
        XCTAssertFalse(harness.model.canRecord)
        XCTAssertEqual(harness.announcements.sentences.last, "MacBook Air Microphone was disconnected. Connect a microphone to record.")
    }

    // MARK: - Recording

    /// Record announces the start before capture begins, then records;
    /// Pause and Resume each say so; Stop saves with the title and folder
    /// chosen under the global policy, announces "Saved Recording as", and
    /// gets ready for another recording.
    func testARecordingIsMadeAndSaved() async throws {
        let harness = try RecordingWindowHarness(test: self, remembered: TestMicrophones.airPods.id)
        harness.model.title = "Kitchen Notes"
        harness.model.folderPath = "Fiction"
        AudioOriginalPolicy.saveGlobal(.keep, in: harness.store)

        await harness.model.record()
        XCTAssertEqual(harness.model.service.state, .recording)
        XCTAssertEqual(harness.announcements.sentences, ["Recording from AirPods Pro."])
        XCTAssertFalse(harness.model.canRecord)
        XCTAssertTrue(harness.model.canStop)

        await harness.backend.record(seconds: 1.5)
        await harness.model.togglePause()
        await harness.model.togglePause()
        XCTAssertEqual(harness.announcements.sentences.suffix(2), ["Paused.", "Resuming."])
        await harness.model.stop()

        let call = try XCTUnwrap(harness.saver.calls.first)
        XCTAssertEqual(harness.saver.calls.count, 1)
        XCTAssertEqual(call.title, "Kitchen Notes")
        XCTAssertEqual(call.folderPath, "Fiction")
        XCTAssertEqual(call.policy, .keep)
        XCTAssertEqual(call.take.deviceName, "AirPods Pro")
        XCTAssertEqual(call.take.duration, 1.5, accuracy: 0.01)
        guard case .saved(let book) = harness.model.phase else {
            return XCTFail("not saved: \(harness.model.phase)")
        }
        XCTAssertEqual(book.title, "Kitchen Notes")
        XCTAssertEqual(harness.announcements.sentences.last, "Saved Recording as Kitchen Notes")
        XCTAssertEqual(harness.model.status, "Saved Recording as Kitchen Notes.")
        XCTAssertEqual(harness.model.service.state, .idle)
        XCTAssertTrue(harness.model.canRecord, "the window is not ready for another recording")
        XCTAssertEqual(harness.model.title, RecordingWording.defaultTitle(at: Self.opened))

        harness.model.openInReader()
        XCTAssertEqual(harness.openedBooks, [book.id])
    }

    /// An empty title is saved as "Untitled", as New from Text names one.
    func testAnEmptyTitleIsSavedAsUntitled() async throws {
        let harness = try RecordingWindowHarness(test: self)
        harness.model.title = "   "

        await harness.model.record()
        await harness.backend.record(seconds: 1)
        await harness.model.stop()

        XCTAssertEqual(harness.saver.calls.first?.title, "Untitled")
    }

    /// A save that fails keeps the take: the window says why, Record waits
    /// until the take is saved or discarded, Save Again saves it, and
    /// Discard Recording deletes it.
    func testAFailedSaveKeepsTheTakeUntilSavedOrDiscarded() async throws {
        let harness = try RecordingWindowHarness(test: self)
        harness.saver.failure = CocoaError(.fileWriteOutOfSpace)
        await harness.model.record()
        await harness.backend.record(seconds: 1)

        await harness.model.stop()

        guard case .saveFailed(let take, _) = harness.model.phase else {
            return XCTFail("the failure was not kept: \(harness.model.phase)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: take.url.path))
        XCTAssertFalse(harness.model.canRecord)
        XCTAssertEqual(harness.model.closeNeed, .saveOrDiscard)
        XCTAssertTrue(harness.announcements.sentences.last?.hasPrefix("The recording couldn't be saved: ") ?? false)

        harness.saver.failure = nil
        await harness.model.saveAgain()
        XCTAssertEqual(harness.saver.calls.count, 2)
        guard case .saved = harness.model.phase else {
            return XCTFail("Save Again did not save: \(harness.model.phase)")
        }

        // Another take that fails, then is discarded.
        harness.saver.failure = CocoaError(.fileWriteOutOfSpace)
        await harness.model.record()
        await harness.backend.record(seconds: 1)
        await harness.model.stop()
        guard case .saveFailed(let second, _) = harness.model.phase else {
            return XCTFail("the second failure was not kept")
        }
        await harness.model.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertEqual(harness.model.phase, .recordingControls)
        XCTAssertTrue(harness.model.canRecord)
        XCTAssertEqual(harness.announcements.sentences.last, "The recording was discarded.")
    }

    /// A microphone lost while recording is announced with its reason, and
    /// what was recorded is saved.
    func testALostMicrophoneIsAnnouncedAndTheTakeSaved() async throws {
        let harness = try RecordingWindowHarness(test: self, remembered: TestMicrophones.airPods.id)
        await harness.model.record()
        await harness.backend.record(seconds: 2)

        try await harness.backend.disconnect()

        let saved = await eventually {
            if case .saved = harness.model.phase { return true }
            return false
        }
        XCTAssertTrue(saved, "the take was not saved: \(harness.model.phase)")
        XCTAssertTrue(harness.announcements.sentences.contains(
            "AirPods Pro was disconnected, so recording stopped. What was recorded until then is kept."
        ))
        XCTAssertEqual(harness.saver.calls.first?.take.duration ?? 0, 2, accuracy: 0.01)
    }

    /// A no to the microphone is announced, the window offers to open the
    /// privacy settings, and Record can be tried again.
    func testADenialIsAnnouncedAndOffersThePrivacySettings() async throws {
        let harness = try RecordingWindowHarness(test: self, permission: FakeMicrophonePermission(.denied))

        await harness.model.record()

        let reported = await eventually { harness.model.offersPrivacySettings }
        XCTAssertTrue(reported)
        XCTAssertEqual(harness.announcements.sentences.last, AudioInputPermissionError.denied.errorDescription)
        XCTAssertTrue(harness.model.canRecord, "Record cannot be tried again")
        let calls = await harness.backend.calls
        XCTAssertEqual(calls, [])
    }

    /// Once a second the window reads the time and the level; when asked,
    /// it announces the level every so many seconds, and never otherwise.
    func testTheLevelIsAnnouncedOnlyWhenAsked() async throws {
        let harness = try RecordingWindowHarness(test: self)
        await harness.model.record()
        await harness.backend.record(seconds: 3, levels: RecordingLevels(average: -30, peak: -15))
        await harness.model.service.refresh()
        let before = harness.announcements.sentences.count

        for _ in 0..<12 { harness.model.tick() }
        XCTAssertEqual(harness.model.elapsed, 3)
        XCTAssertEqual(harness.model.levels, RecordingLevels(average: -30, peak: -15))
        XCTAssertEqual(harness.announcements.sentences.count, before, "the level was announced while switched off")

        harness.model.announcesLevel = true
        harness.model.levelAnnouncementInterval = 5
        for _ in 0..<10 { harness.model.tick() }
        XCTAssertEqual(
            Array(harness.announcements.sentences.dropFirst(before)),
            ["Level minus 15 decibels, good", "Level minus 15 decibels, good"]
        )
        await harness.model.stop()
    }

    /// A take that holds nothing but silence, as a muted microphone gives,
    /// is announced once, after five seconds of it, so a user who cannot see
    /// a meter learns of it; a voice, however quiet, never is.
    func testSilenceIsAnnouncedOnceAfterFiveSeconds() async throws {
        let harness = try RecordingWindowHarness(test: self, remembered: TestMicrophones.usb.id)
        await harness.model.record()
        let warning = "No sound is reaching TextMouth from Studio Microphone. Check that the microphone is on and not muted."

        await harness.backend.record(seconds: 1, levels: RecordingLevels(average: -70, peak: -60))
        await harness.model.service.refresh()
        for _ in 0..<10 { harness.model.tick() }
        XCTAssertFalse(harness.announcements.sentences.contains(warning), "a quiet voice was taken for silence")

        await harness.backend.record(seconds: 1, levels: RecordingLevels(average: -160, peak: -160))
        await harness.model.service.refresh()
        for _ in 0..<4 { harness.model.tick() }
        XCTAssertFalse(harness.announcements.sentences.contains(warning), "silence was announced too soon")
        for _ in 0..<10 { harness.model.tick() }
        XCTAssertEqual(harness.announcements.sentences.filter { $0 == warning }.count, 1)
        XCTAssertEqual(harness.model.status, warning)
        XCTAssertTrue(RecordingWording.isDigitalSilence(peak: -.infinity))
        XCTAssertFalse(RecordingWording.isDigitalSilence(peak: -90))
        await harness.model.stop()
    }

    // MARK: - Readers Playing

    /// Starting a recording pauses every reader that is playing, here two,
    /// each as its own Pause would, so the microphone doesn't pick up a
    /// book, and says so once, before "Recording from"; a reader already
    /// paused is left alone; and nothing resumes them afterwards.
    func testStartingARecordingPausesEveryPlayingReader() async throws {
        let readers = NowPlayingService(installsSystemIntegrations: false, diagnosticSink: { _ in })
        let first = FakeReader(playing: true, in: readers)
        let second = FakeReader(playing: true, in: readers)
        let paused = FakeReader(playing: false, in: readers)
        let harness = try RecordingWindowHarness(test: self, remembered: TestMicrophones.airPods.id, readers: readers)

        await harness.model.record()

        XCTAssertEqual(harness.model.service.state, .recording)
        XCTAssertEqual([first.pauses, second.pauses, paused.pauses], [1, 1, 0])
        XCTAssertFalse(first.isPlaying || second.isPlaying)
        XCTAssertEqual(harness.announcements.sentences, ["Paused 2 books that were playing. Recording from AirPods Pro."])

        await harness.backend.record(seconds: 1)
        await harness.model.stop()
        XCTAssertFalse(first.isPlaying || second.isPlaying || paused.isPlaying, "a book was resumed")
        XCTAssertEqual([first.pauses, second.pauses, paused.pauses], [1, 1, 0])
    }

    /// With no book playing, a recording starts as it always did, saying
    /// nothing of books; resuming it pauses a book started meanwhile, saying
    /// so before "Resuming".
    func testResumingARecordingPausesABookStartedMeanwhile() async throws {
        let readers = NowPlayingService(installsSystemIntegrations: false, diagnosticSink: { _ in })
        let reader = FakeReader(playing: false, in: readers)
        let other = FakeReader(playing: false, in: readers)
        let harness = try RecordingWindowHarness(test: self, remembered: TestMicrophones.airPods.id, readers: readers)

        await harness.model.record()
        XCTAssertEqual(harness.announcements.sentences, ["Recording from AirPods Pro."])
        await harness.model.togglePause()
        reader.isPlaying = true
        await harness.model.togglePause()

        XCTAssertEqual(harness.model.service.state, .recording)
        XCTAssertEqual([reader.pauses, other.pauses], [1, 0])
        XCTAssertEqual(harness.announcements.sentences.suffix(2), ["Paused.", "Paused the book that was playing. Resuming."])
        await harness.model.stop()
    }

    /// The coordinator pauses only the readers playing, once each, and says
    /// how many; with none playing it does nothing.
    func testOnlyPlayingReadersArePaused() {
        let readers = NowPlayingService(installsSystemIntegrations: false, diagnosticSink: { _ in })
        let playing = [FakeReader(playing: true, in: readers), FakeReader(playing: true, in: readers)]
        let idle = FakeReader(playing: false, in: readers)

        XCTAssertEqual(readers.pauseEveryPlayingReader(), 2)
        XCTAssertEqual(readers.pauseEveryPlayingReader(), 0)
        XCTAssertEqual(playing.map(\.pauses), [1, 1])
        XCTAssertEqual(idle.pauses, 0)
        XCTAssertEqual(RecordingWording.pausedReaders(0), nil)
        XCTAssertEqual(RecordingWording.afterPausingReaders(1, "Resuming."), "Paused the book that was playing. Resuming.")
    }

    /// Closing needs nothing while idle, a question while recording, and
    /// another while a take waits to be saved.
    func testWhatClosingNeeds() async throws {
        let harness = try RecordingWindowHarness(test: self)
        XCTAssertEqual(harness.model.closeNeed, .nothing)

        await harness.model.record()
        XCTAssertEqual(harness.model.closeNeed, .stopOrDiscard)
        await harness.model.togglePause()
        XCTAssertEqual(harness.model.closeNeed, .stopOrDiscard)

        await harness.model.discard()
        XCTAssertEqual(harness.model.closeNeed, .nothing)
        let take = await harness.backend.url
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(take).path), "Discard kept the take")
    }

    // MARK: - The Window, as VoiceOver Reads It

    /// VoiceOver finds the Microphone pop-up by its label, with its hint,
    /// the microphones by name as its items, and the one in use as its
    /// value; the Save in pop-up and the stepper have labels of their own.
    func testTheControlsAreLabelled() throws {
        let harness = try RecordingWindowHarness(test: self, remembered: TestMicrophones.airPods.id)
        try skipUnlessHostedWindowsExposeAccessibility()

        try withHostedView(RecordingWindowView(model: harness.model), size: NSSize(width: 520, height: 640), until: {
            self.descendants(of: $0, as: NSPopUpButton.self).count >= 2
        }) { hosting in
            let controls = accessibleControls(in: hosting)
            let microphone = try XCTUnwrap(controls.first { $0.label == "Microphone" }, "\(controls.map(\.label))")
            XCTAssertEqual(microphone.hint, RecordingWording.microphoneHint)
            XCTAssertEqual(microphone.element.accessibilityValue() as? String, "AirPods Pro")
            let folder = try XCTUnwrap(controls.first { $0.label == "Save in" }, "\(controls.map(\.label))")
            XCTAssertEqual(folder.hint, RecordingWording.folderHint)
            XCTAssertNotNil(controls.first { $0.label == RecordingWording.announceIntervalLabel }, "\(controls.map(\.label))")

            let popUps = descendants(of: hosting, as: NSPopUpButton.self)
            XCTAssertTrue(popUps.contains { $0.itemTitles == ["MacBook Air Microphone", "AirPods Pro", "Studio Microphone"] })
            XCTAssertTrue(popUps.contains { $0.itemTitles == ["Library", "Library / Fiction", "Library / Fiction / Sci-Fi"] })
        }
    }

    /// VoiceOver starts on the Microphone pop-up: the window makes exactly
    /// one focus request, and, where SwiftUI exposes its elements, the one
    /// element carrying the identifier that request looks for is the
    /// pop-up.
    func testVoiceOverStartsOnTheMicrophonePopUp() throws {
        let harness = try RecordingWindowHarness(test: self)

        withHostedView(RecordingWindowView(model: harness.model), size: NSSize(width: 520, height: 640), until: {
            !self.descendants(of: $0, as: VoiceOverFocusTriggerView.self).isEmpty
        }) { hosting in
            XCTAssertEqual(descendants(of: hosting, as: VoiceOverFocusTriggerView.self).count, 1)
            let targets = accessibilityElements(identified: voiceOverFocusID, in: hosting)
            if !targets.isEmpty {
                XCTAssertEqual(targets.map { $0.accessibilityLabel() ?? "" }, ["Microphone"])
            }
        }
    }

    // MARK: - Shortcuts and Menus

    /// The window's shortcuts, and File > New Recording…'s, are their own
    /// actions' defaults since they became editable (FR12's branch D), and
    /// none of the reader's or the library's.
    func testTheShortcutsAreNoneOfTheReadersOrTheLibrarys() {
        let shortcuts: [(shortcut: KeyboardShortcut, action: ShortcutAction)] = [
            (RecordingShortcuts.record, .recordingRecord),
            (RecordingShortcuts.pauseOrResume, .recordingPauseOrResume),
            (RecordingShortcuts.stop, .recordingStop),
            (RecordingShortcuts.newRecording, .newRecording),
        ]
        for (shortcut, action) in shortcuts {
            let binding = KeyBinding(
                key: String(shortcut.key.character),
                command: shortcut.modifiers.contains(.command),
                option: shortcut.modifiers.contains(.option),
                shift: shortcut.modifiers.contains(.shift),
                control: shortcut.modifiers.contains(.control)
            )
            XCTAssertEqual(ShortcutAction.defaultBindings[action], [binding], action.rawValue)
            let others = ShortcutAction.defaultBindings.filter { $0.key != action }.values.flatMap { $0 }
            XCTAssertFalse(others.contains(binding), "\(binding.displayString) is another action's default too")
        }
    }

    /// No menu command answers the Record window's shortcuts, and File >
    /// New Recording… alone answers Option-Command-N, right after New from
    /// Text; the Library menu offers it too.
    func testTheMenusOfferNewRecordingAndNothingClashes() throws {
        let menu = try XCTUnwrap(NSApp.mainMenu)
        let items = Self.allItems(of: menu)
        func answering(_ key: String, _ modifiers: NSEvent.ModifierFlags) -> [NSMenuItem] {
            items.filter { $0.keyEquivalent.lowercased() == key && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == modifiers }
        }
        XCTAssertEqual(answering("r", .command).map(\.title), [])
        XCTAssertEqual(answering("p", .command).map(\.title), [])
        XCTAssertEqual(answering(".", .command).map(\.title), [])
        XCTAssertEqual(answering("n", [.option, .command]).map(\.title), [RecordingWording.menuTitle])

        let file = try XCTUnwrap(menu.items.first { $0.title == "File" }?.submenu)
        let titles = file.items.map(\.title)
        let fromText = try XCTUnwrap(titles.firstIndex(of: "New from Text..."))
        XCTAssertEqual(titles[safe: fromText + 1], RecordingWording.menuTitle)
        let library = try XCTUnwrap(menu.items.first { $0.title == "Library" }?.submenu)
        XCTAssertTrue(library.items.contains { $0.title == RecordingWording.menuTitle })
    }

    /// The Record window shows neither the Library's nor a reader's menus.
    func testTheRecordWindowShowsNoContextMenus() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier(RecordingWindowController.windowIdentifier)
        window.title = RecordingWording.windowTitle

        XCTAssertNil(MenuVisibilityManager.detectWindowType(for: window))
    }

    // MARK: - Helpers

    /// Every item of `menu` and of its submenus.
    private static func allItems(of menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(allItems(of:)) ?? []) }
    }
}

private extension Array {
    /// The element at `index`, or nil when there is none.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// A reader as the Now Playing coordinator knows one: whether it plays, and
/// how often it was paused, registered with a coordinator of the test's
/// own, never the app's. Its handlers hold it weakly, so a coordinator
/// outliving it reaches nothing.
@MainActor
private final class FakeReader {
    /// Whether it is playing.
    var isPlaying: Bool
    /// How many times it was paused.
    private(set) var pauses = 0

    /// A reader playing or not, registered with `readers`.
    init(playing: Bool, in readers: NowPlayingService) {
        isPlaying = playing
        readers.setup(
            ownerID: UUID(),
            onPlay: { [weak self] in self?.isPlaying = true },
            onPause: { [weak self] in
                self?.isPlaying = false
                self?.pauses += 1
            },
            onAudioRouteInvalidated: {},
            onAudioRouteChangePause: {},
            onTogglePlayPause: {},
            onSkipForward: {},
            onSkipBackward: {},
            isCurrentlyPlaying: { [weak self] in self?.isPlaying ?? false },
            bluetoothMonitoring: false
        )
    }
}
