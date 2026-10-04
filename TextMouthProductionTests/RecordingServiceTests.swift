import AVFoundation
import XCTest
@testable import TextMouth

/// The recorder (FR04) with a capture backend that needs no microphone
/// (`FakeCaptureBackend`): it asks permission before anything else, records
/// into a new take in its folder, follows the time and levels, pauses and
/// resumes into the same take, and stops with the take's length read from
/// its file. A lost microphone or a full disk stops the take and keeps what
/// was recorded; a denial records nothing at all.
@MainActor
final class RecordingServiceTests: XCTestCase {

    /// The moment every take in these tests starts.
    private nonisolated static let startDate = Date(timeIntervalSince1970: 1_791_000_000)

    // MARK: - Starting

    /// Start asks macOS's permission, then records from the chosen
    /// microphone into a new CAF take in the recorder's folder.
    func testStartAsksPermissionThenRecordsIntoANewTake() async throws {
        let folder = try RecordingAudioFixtures.makeTakesFolder(for: self)
        let backend = FakeCaptureBackend()
        let permission = FakeMicrophonePermission(.notDetermined, whenAsked: true)
        let service = makeService(backend: backend, permission: permission, folder: folder)

        await service.start(from: TestMicrophones.usb)

        XCTAssertEqual(service.state, .recording)
        XCTAssertTrue(service.isRecording)
        XCTAssertEqual(permission.questions, 1)
        let calls = await backend.calls
        XCTAssertEqual(calls, ["start \(TestMicrophones.usb.id)"])
        let recordedInto = await backend.url
        let url = try XCTUnwrap(recordedInto)
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(url.pathExtension, "caf")
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Take "), url.lastPathComponent)
    }

    /// A denied microphone records nothing: no capture starts, no file is
    /// made, and the error says why.
    func testADeniedMicrophoneRecordsNothing() async throws {
        for (answer, refusal) in [(AudioInputAuthorization.denied, AudioInputPermissionError.denied),
                                  (.restricted, .restricted)] {
            let folder = try RecordingAudioFixtures.makeTakesFolder(for: self)
            let backend = FakeCaptureBackend()
            let service = makeService(backend: backend, permission: FakeMicrophonePermission(answer), folder: folder)

            await service.start(from: TestMicrophones.builtIn)

            XCTAssertEqual(service.state, .failed(.permission(refusal), nil))
            let calls = await backend.calls
            XCTAssertEqual(calls, [], "capture started without permission")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        }
    }

    /// A microphone gone before the take starts is named in the error, and
    /// the file made for it is removed.
    func testAMicrophoneThatIsGoneIsNamed() async throws {
        let folder = try RecordingAudioFixtures.makeTakesFolder(for: self)
        let backend = FakeCaptureBackend(startError: RecordingCaptureError.deviceUnavailable)
        let service = makeService(backend: backend, folder: folder)

        await service.start(from: TestMicrophones.airPods)

        XCTAssertEqual(service.state, .failed(.deviceUnavailable("AirPods Pro"), nil))
        XCTAssertEqual(
            RecordingFailure.deviceUnavailable("AirPods Pro").errorDescription,
            "AirPods Pro isn't available, so TextMouth can't record from it. Choose another microphone."
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    /// Any other failure to begin says recording from that microphone
    /// could not start.
    func testAStartThatFailsSaysSo() async throws {
        let backend = FakeCaptureBackend(startError: RecordingCaptureError.didNotStart("no audio"))
        let service = makeService(backend: backend, folder: try RecordingAudioFixtures.makeTakesFolder(for: self))

        await service.start(from: TestMicrophones.builtIn)

        XCTAssertEqual(service.state, .failed(.couldNotStart("MacBook Air Microphone"), nil))
    }

    // MARK: - While Recording

    /// The time recorded and the levels follow the capture.
    func testTheTimeAndLevelsFollowTheCapture() async throws {
        let backend = FakeCaptureBackend()
        let service = makeService(backend: backend, folder: try RecordingAudioFixtures.makeTakesFolder(for: self))
        await service.start(from: TestMicrophones.builtIn)

        await backend.record(seconds: 2.5, levels: RecordingLevels(average: -30, peak: -12))
        await service.refresh()

        XCTAssertEqual(service.elapsed, 2.5, accuracy: 0.001)
        XCTAssertEqual(service.levels, RecordingLevels(average: -30, peak: -12))
    }

    /// While recording, the recorder reads the time by itself.
    func testTheRecorderReadsTheTimeByItself() async throws {
        let backend = FakeCaptureBackend()
        let service = makeService(
            backend: backend,
            folder: try RecordingAudioFixtures.makeTakesFolder(for: self),
            pollInterval: .milliseconds(10)
        )
        await service.start(from: TestMicrophones.builtIn)

        await backend.record(seconds: 1.5)

        let updated = await eventually { service.elapsed == 1.5 }
        XCTAssertTrue(updated, "the time recorded was not read: \(service.elapsed)")
        await service.stop()
    }

    /// Pause stops the take growing and Resume continues it, both on the
    /// same take.
    func testPauseAndResumeContinueTheSameTake() async throws {
        let backend = FakeCaptureBackend()
        let service = makeService(backend: backend, folder: try RecordingAudioFixtures.makeTakesFolder(for: self))
        await service.start(from: TestMicrophones.builtIn)
        await backend.record(seconds: 1)

        await service.pause()
        XCTAssertEqual(service.state, .paused)
        XCTAssertTrue(service.isRecording)
        await backend.record(seconds: 5)
        await service.refresh()
        XCTAssertEqual(service.elapsed, 1, accuracy: 0.001, "a paused take grew")

        await service.resume()
        XCTAssertEqual(service.state, .recording)
        await backend.record(seconds: 2)
        await service.refresh()
        XCTAssertEqual(service.elapsed, 3, accuracy: 0.001)

        let calls = await backend.calls
        XCTAssertEqual(calls, ["start \(TestMicrophones.builtIn.id)", "pause", "resume"])
    }

    // MARK: - Stopping

    /// Stop finishes the take; its length is read from its file.
    func testStopFinishesTheTake() async throws {
        let backend = FakeCaptureBackend()
        let service = makeService(backend: backend, folder: try RecordingAudioFixtures.makeTakesFolder(for: self))
        await service.start(from: TestMicrophones.usb)
        await backend.record(seconds: 3)

        await service.stop()

        guard case .finished(let take) = service.state else {
            return XCTFail("the take did not finish: \(service.state)")
        }
        XCTAssertEqual(take.duration, 3, accuracy: 0.01)
        XCTAssertEqual(take.deviceName, "Studio Microphone")
        XCTAssertEqual(take.startedAt, Self.startDate)
        XCTAssertTrue(FileManager.default.fileExists(atPath: take.url.path))
        XCTAssertEqual(service.elapsed, 3, accuracy: 0.01)
        XCTAssertNil(service.levels)
        XCTAssertFalse(service.isRecording)
        XCTAssertFalse(service.canStart, "a take waiting to be saved blocks another")
    }

    /// A take stopped before any audio was written leaves nothing behind.
    func testStoppingWithNothingRecordedKeepsNothing() async throws {
        let folder = try RecordingAudioFixtures.makeTakesFolder(for: self)
        let service = makeService(backend: FakeCaptureBackend(), folder: folder)
        await service.start(from: TestMicrophones.builtIn)

        await service.stop()

        XCTAssertEqual(service.state, .failed(.nothingRecorded, nil))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    /// Discard deletes the take that ended and gets ready for another;
    /// Reset gets ready while leaving the file to whoever saved it.
    func testDiscardDeletesTheTakeAndResetKeepsIt() async throws {
        let backend = FakeCaptureBackend()
        let service = makeService(backend: backend, folder: try RecordingAudioFixtures.makeTakesFolder(for: self))

        await service.start(from: TestMicrophones.builtIn)
        await backend.record(seconds: 1)
        await service.stop()
        let discarded = try XCTUnwrap(finishedTake(of: service))
        service.discard()
        XCTAssertEqual(service.state, .idle)
        XCTAssertTrue(service.canStart)
        XCTAssertFalse(FileManager.default.fileExists(atPath: discarded.url.path))

        await service.start(from: TestMicrophones.builtIn)
        await backend.record(seconds: 1)
        await service.stop()
        let saved = try XCTUnwrap(finishedTake(of: service))
        service.reset()
        XCTAssertEqual(service.state, .idle)
        XCTAssertEqual(service.elapsed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.url.path))
    }

    /// Nothing new starts while a take is under way, and Discard and Reset
    /// leave one under way alone.
    func testATakeUnderWayIsNeverInterrupted() async throws {
        let backend = FakeCaptureBackend()
        let service = makeService(backend: backend, folder: try RecordingAudioFixtures.makeTakesFolder(for: self))
        await service.start(from: TestMicrophones.builtIn)

        await service.start(from: TestMicrophones.usb)
        service.discard()
        service.reset()

        XCTAssertEqual(service.state, .recording)
        let calls = await backend.calls
        XCTAssertEqual(calls, ["start \(TestMicrophones.builtIn.id)"])
        await service.stop()
    }

    // MARK: - A Take That Ends on Its Own

    /// A microphone lost while recording stops the take with an error that
    /// names it, and keeps what was recorded until then.
    func testALostMicrophoneStopsTheTakeAndKeepsWhatWasRecorded() async throws {
        let backend = FakeCaptureBackend()
        let service = makeService(backend: backend, folder: try RecordingAudioFixtures.makeTakesFolder(for: self))
        await service.start(from: TestMicrophones.airPods)
        await backend.record(seconds: 2)

        try await backend.disconnect()

        let stopped = await eventually {
            if case .failed = service.state { return true }
            return false
        }
        XCTAssertTrue(stopped, "the take did not stop: \(service.state)")
        guard case .failed(let failure, let take?) = service.state else {
            return XCTFail("the take was not kept: \(service.state)")
        }
        XCTAssertEqual(failure, .deviceDisconnected("AirPods Pro"))
        XCTAssertEqual(
            failure.errorDescription,
            "AirPods Pro was disconnected, so recording stopped. What was recorded until then is kept."
        )
        XCTAssertEqual(take.duration, 2, accuracy: 0.01)
        XCTAssertTrue(FileManager.default.fileExists(atPath: take.url.path))
        XCTAssertFalse(service.canStart, "the kept take must be saved or discarded first")
    }

    /// A disk come near full stops the take the same way, keeping it.
    func testAFullDiskStopsTheTakeAndKeepsIt() async throws {
        let backend = FakeCaptureBackend()
        let service = makeService(backend: backend, folder: try RecordingAudioFixtures.makeTakesFolder(for: self))
        await service.start(from: TestMicrophones.builtIn)
        await backend.record(seconds: 1)

        try await backend.fillDisk()

        let stopped = await eventually {
            if case .failed(.diskFull, _?) = service.state { return true }
            return false
        }
        XCTAssertTrue(stopped, "\(service.state)")
    }

    // MARK: - How Capture Ends, as AVFoundation Reports It

    /// The errors AVFoundation finishes a recording with become what the
    /// recorder hears: a lost device, a full disk, a finish that still left
    /// a complete file, or a failure.
    func testAVFoundationsEndingsAreRecognized() {
        func error(_ code: AVError.Code, finished: Bool? = nil) -> NSError {
            NSError(
                domain: AVFoundationErrorDomain,
                code: code.rawValue,
                userInfo: finished.map { [AVErrorRecordingSuccessfullyFinishedKey: $0] } ?? [:]
            )
        }
        XCTAssertEqual(FileRecordingDelegate.outcome(of: nil), .finished)
        XCTAssertEqual(FileRecordingDelegate.outcome(of: error(.deviceWasDisconnected, finished: true)), .deviceDisconnected)
        XCTAssertEqual(FileRecordingDelegate.outcome(of: error(.diskFull, finished: true)), .diskFull)
        XCTAssertEqual(FileRecordingDelegate.outcome(of: error(.maximumDurationReached, finished: true)), .finished)
        XCTAssertEqual(
            FileRecordingDelegate.outcome(of: error(.unknown)),
            .failed("\(AVFoundationErrorDomain) \(AVError.Code.unknown.rawValue)")
        )
        XCTAssertEqual(FileRecordingDelegate.Outcome.deviceDisconnected.event, .deviceDisconnected)
        XCTAssertEqual(FileRecordingDelegate.Outcome.diskFull.event, .diskFull)
    }

    /// A take is 16-bit linear PCM, one channel, at the microphone's own
    /// rate: the format the research found survives a crash.
    func testATakeIsSixteenBitMonoPCM() {
        let settings = CaptureSessionRecordingBackend.pcmSettings(sampleRate: 24_000)
        XCTAssertEqual(settings[AVFormatIDKey] as? AudioFormatID, kAudioFormatLinearPCM)
        XCTAssertEqual(settings[AVLinearPCMBitDepthKey] as? Int, 16)
        XCTAssertEqual(settings[AVLinearPCMIsFloatKey] as? Bool, false)
        XCTAssertEqual(settings[AVNumberOfChannelsKey] as? Int, 1)
        XCTAssertEqual(settings[AVSampleRateKey] as? Double, 24_000)
    }

    // MARK: - Helpers

    /// A recorder with `backend` and `permission`, recording into `folder`,
    /// reading the time only when asked unless `pollInterval` says, and
    /// starting every take at `startDate`.
    private func makeService(
        backend: FakeCaptureBackend,
        permission: FakeMicrophonePermission = FakeMicrophonePermission(.authorized),
        folder: URL,
        pollInterval: Duration? = nil
    ) -> RecordingService {
        RecordingService(
            backend: backend,
            permission: permission.permission,
            takesFolder: folder,
            pollInterval: pollInterval,
            now: { Self.startDate }
        )
    }

    /// The take `service` finished, if it finished one.
    private func finishedTake(of service: RecordingService) -> RecordedTake? {
        if case .finished(let take) = service.state { return take }
        return nil
    }
}
