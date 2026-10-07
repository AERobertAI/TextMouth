import AVFoundation
import XCTest
import os
@testable import TextMouth

/// Measuring the edited audio's levels (FR04) on a thread of its own: the
/// levels are those of the audio; a measurement never occupies Swift's
/// cooperative thread pool, however long its reader blocks, so a task of
/// the pool's own always runs beside it; one cancelled while reading ends
/// within a second with `CancellationError`; and an editor measures one
/// audio at a time: a newer measurement waits for the older, cancelled one
/// to stop before it reads, and of several started at once every one ends
/// and the last completes.
///
/// Every wait here has a timeout, and none needs a thread of the pool: the
/// tests are synchronous methods whose waits run the main run loop
/// (`spinUntil`), since a sleeping task could not wake while every pool
/// thread was held, which is how the hang these tests guard against froze
/// a whole test run on October 6, 2026. Each measurement a test starts is
/// cancelled as the test ends, so a reader that never returned would fail
/// its test, not hang the host.
@MainActor
final class AudioEditorLevelsTests: XCTestCase {

    // MARK: - The Levels

    /// The levels are those of the audio, a window every hundredth of a
    /// second: a sine at a peak of 0.3 measures its root mean square, -13.5
    /// dBFS; digital silence is the silence level; a steady 0.3 is -10.5.
    func testTheLevelsMeasuredAreThoseOfTheAudio() async throws {
        let url = try makePhrasesFile()
        let composition = try await Self.makeComposition(of: url, frames: Self.phrasesFrames, repeats: 1)

        let levels = try await AudioEditorLevels.measure(composition)

        XCTAssertEqual(levels.duration, 2.5)
        XCTAssertEqual(levels.decibels.count, 250)
        for window in 0..<100 {
            XCTAssertEqual(levels.decibels[checked: window] ?? .nan, -13.47, accuracy: 0.5, "window \(window)")
        }
        for window in 100..<150 {
            XCTAssertEqual(levels.decibels[checked: window], AudioEditorLevels.silence, "window \(window)")
        }
        for window in 150..<250 {
            XCTAssertEqual(levels.decibels[checked: window] ?? .nan, -10.46, accuracy: 0.05, "window \(window)")
        }
    }

    // MARK: - The Cooperative Pool

    /// More measurements than the Mac has cores, each held where its reader
    /// is about to start, leave the cooperative pool free: every one of them
    /// reaches that point, and a task of the pool's own still runs beside
    /// them. Released, every one completes with the audio's levels.
    func testHeldMeasurementsLeaveTheCooperativePoolFree() throws {
        let url = try makePhrasesFile()
        let count = ProcessInfo.processInfo.activeProcessorCount + 2
        let holds = DispatchSemaphore(value: 0)
        let started = OSAllocatedUnfairLock(initialState: 0)
        observeReading(of: Self.phrasesFrames) {
            started.withLock { $0 += 1 }
            _ = holds.wait(timeout: .now() + Self.longestHold)
        }
        // Whatever a failure leaves held is released as the test ends.
        addTeardownBlock { for _ in 0..<count { holds.signal() } }

        let measurements = (0..<count).map { _ in startMeasurement(of: url, frames: Self.phrasesFrames, repeats: 1) }
        addTeardownBlock { for measurement in measurements { measurement.task.cancel() } }
        let allHeld = spinUntil(timeout: 10) { started.withLock { $0 } == count }
        XCTAssertTrue(allHeld, "only \(started.withLock { $0 }) of \(count) measurements reached their reader: the rest could not get a thread")

        let probeRan = OSAllocatedUnfairLock(initialState: false)
        Task.detached(priority: .userInitiated) { probeRan.withLock { $0 = true } }
        let ran = spinUntil(timeout: 1) { probeRan.withLock { $0 } }
        XCTAssertTrue(ran, "a task could not run on the cooperative pool while the measurements were held")

        for _ in 0..<count { holds.signal() }
        let allEnded = spinUntil(timeout: 20) { measurements.allSatisfy { $0.result != nil } }
        XCTAssertTrue(allEnded, "a released measurement never ended")
        for measurement in measurements {
            guard case .success(let levels)? = measurement.result else {
                XCTFail("a released measurement did not complete: \(String(describing: measurement.result))")
                continue
            }
            XCTAssertEqual(levels.decibels.count, 250)
        }
    }

    /// A measurement cancelled while its reader is reading ends within a
    /// second, with `CancellationError`.
    func testACancelledMeasurementEndsPromptly() throws {
        let url = try makeLongFile()
        let started = OSAllocatedUnfairLock(initialState: false)
        observeReading(of: Self.longFrames * Int64(Self.longRepeats)) { started.withLock { $0 = true } }

        let measurement = startMeasurement(of: url, frames: Self.longFrames, repeats: Self.longRepeats)
        addTeardownBlock { measurement.task.cancel() }
        let reading = spinUntil(timeout: 20) { started.withLock { $0 } }
        XCTAssertTrue(reading, "the measurement never started reading")
        // The measurement has hours of audio to read: it is reading now.
        let clock = ContinuousClock()
        let cancelled = clock.now
        measurement.task.cancel()

        let ended = spinUntil(timeout: 10) { measurement.result != nil }
        let took = clock.now - cancelled
        XCTAssertTrue(ended, "the cancelled measurement never ended")
        XCTAssertLessThan(took, .seconds(1), "the cancelled measurement took \(took) to end")
        switch measurement.result {
        case .failure(let error)?:
            XCTAssertTrue(error is CancellationError, "ended with \(error) instead of a cancellation")
        case .success?:
            XCTFail("the measurement completed before it could be cancelled: its audio is too short for this test")
        case nil:
            break
        }
    }

    // MARK: - One Measurement at a Time

    /// Of several measurements started at once, each cancelled by the next,
    /// every one ends and the last completes, with the levels of the audio.
    func testMeasurementsStartedAtOnceAllEndAndTheLastCompletes() throws {
        let harness = try openRampForSpinning(seconds: 5)
        let model = harness.model
        var tasks: [Task<Void, Never>] = []
        for _ in 0..<5 {
            model.measureLevels()
            tasks.append(try XCTUnwrap(model.measuring))
            // Each older measurement gets going before the next cancels it.
            spin(for: 0.02)
        }

        for (index, task) in tasks.enumerated() {
            XCTAssertTrue(endsInTime(task, within: 10), "measurement \(index + 1) never ended")
        }
        let found = spinUntil(timeout: 10) { model.pauseSearch == .found }
        XCTAssertTrue(found, "the last measurement never completed: \(model.pauseSearch)")
        XCTAssertEqual(model.levels?.decibels.count, 500)
        XCTAssertEqual(model.levels?.duration, 5)
        XCTAssertEqual(model.measuring, tasks.last)
    }

    // MARK: - Helpers

    /// How long a held measurement waits before going on by itself, so a
    /// failure never holds a thread for good; read on the reading thread.
    private nonisolated static let longestHold: DispatchTimeInterval = .seconds(20)

    /// The phrases file: a second of a 440 hertz sine at a peak of 0.3,
    /// half a second of silence, and a second of a steady 0.3, at 8,000
    /// frames a second.
    private static let phrasesFrames: Int64 = 20_000

    /// The long file: a minute of the sine, repeated `longRepeats` times in
    /// a composition for twelve hours of audio, which a measurement reads
    /// in a few seconds (an hour took 0.24 seconds on October 6, 2026):
    /// long enough that a cancellation lands while it is reading.
    private static let longFrames: Int64 = 480_000
    private static let longRepeats = 720

    /// A folder of this test's own for its audio, removed as it ends.
    private func makeAudioFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("audio-editor-levels-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// The phrases file, written for this test.
    private func makePhrasesFile() throws -> URL {
        let url = try makeAudioFolder().appendingPathComponent("Phrases.wav")
        try AudioTestFixtures.writeTones([
            .init(seconds: 1, frequency: 440, amplitude: 0.3),
            .silence(0.5),
            .init(seconds: 1, frequency: 0, amplitude: 0.3),
        ], to: url, sampleRate: 8_000)
        return url
    }

    /// The long file, written for this test.
    private func makeLongFile() throws -> URL {
        let url = try makeAudioFolder().appendingPathComponent("Long.wav")
        try AudioTestFixtures.writeTones([.init(seconds: 60, frequency: 440, amplitude: 0.3)], to: url, sampleRate: 8_000)
        return url
    }

    /// A composition of `repeats` copies of the `frames` frames of audio at
    /// `url`, one after another, as the editor's preview is of its
    /// stretches.
    private static func makeComposition(of url: URL, frames: Int64, repeats: Int) async throws -> sending AudioEditComposition {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let range = try await track.load(.timeRange)
        let composition = AVMutableComposition()
        let target = try XCTUnwrap(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        for index in 0..<repeats {
            try target.insertTimeRange(range, of: track, at: CMTime(value: frames * Int64(index), timescale: 8_000))
        }
        return AudioEditComposition(composition: composition, sources: [asset], frames: frames * Int64(repeats), sampleRate: 8_000)
    }

    /// A measurement under way in a task of its own, with its outcome once
    /// it ends; the task is never awaited without a bound.
    private struct Measurement {
        let task: Task<Void, Never>
        let outcome: OSAllocatedUnfairLock<Result<AudioEditorLevels, any Error>?>

        /// The levels or the error, once the measurement has ended.
        var result: Result<AudioEditorLevels, any Error>? {
            outcome.withLock { $0 }
        }
    }

    /// Starts measuring `repeats` copies of the `frames` frames of audio at
    /// `url`, in a task of its own, as the editor measures: on the main
    /// actor, reading off it.
    private func startMeasurement(of url: URL, frames: Int64, repeats: Int) -> Measurement {
        let outcome = OSAllocatedUnfairLock<Result<AudioEditorLevels, any Error>?>(initialState: nil)
        let task = Task {
            do {
                let composition = try await Self.makeComposition(of: url, frames: frames, repeats: repeats)
                let levels = try await AudioEditorLevels.measure(composition)
                outcome.withLock { $0 = .success(levels) }
            } catch {
                outcome.withLock { $0 = .failure(error) }
            }
        }
        return Measurement(task: task, outcome: outcome)
    }

    /// Tells `body`, on the reading thread, of each measurement about to
    /// read `frames` frames of audio: this test's own, since a measurement
    /// an earlier test left ending reads another length. The observer is
    /// removed as the test ends.
    private func observeReading(of frames: Int64, _ body: @escaping @Sendable () -> Void) {
        AudioEditorLevels.readingObserver = { read in
            if read == frames {
                body()
            }
        }
        addTeardownBlock { AudioEditorLevels.readingObserver = nil }
    }

    /// A value a task on the main actor hands a synchronous test.
    @MainActor
    private final class MainBox<Value> {
        var value: Value?
    }

    /// An editor on `seconds` seconds of a ramp, its preview not loaded, for
    /// a synchronous test: `openRamp` runs in a task of its own while the
    /// main run loop spins. A synchronous test's body is no job of the main
    /// actor, so the actor's other jobs, the session's and the
    /// measurements', run while it spins; an async test's body is one, and
    /// would have to sleep as a task to let them, which needs the pool.
    private func openRampForSpinning(seconds: Double) throws -> EditorHarness {
        let opened = MainBox<Result<EditorHarness, any Error>>()
        Task {
            do {
                opened.value = .success(try await openRamp(seconds: seconds, loadsPreview: false))
            } catch {
                opened.value = .failure(error)
            }
        }
        _ = spinUntil(timeout: 30) { opened.value != nil }
        return try XCTUnwrap(opened.value, "the editor did not open in time").get()
    }

    /// Waits on the main thread, running its run loop, until `condition`
    /// holds or `timeout` seconds pass, and returns whether it held. The
    /// run loop needs no thread of Swift's cooperative pool, so the wait
    /// ends on time even while every pool thread is held, which a sleeping
    /// task (`eventually`) could not. For a synchronous test only: see
    /// `openRampForSpinning`.
    private func spinUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    /// Waits `seconds` on the main thread, running its run loop meanwhile.
    private func spin(for seconds: TimeInterval) {
        _ = spinUntil(timeout: seconds) { false }
    }

    /// Whether `task` ends within `seconds`. One that has not is left to
    /// end on its own, never awaited without a bound.
    private func endsInTime(_ task: Task<Void, Never>, within seconds: TimeInterval) -> Bool {
        let ended = OSAllocatedUnfairLock(initialState: false)
        Task.detached {
            await task.value
            ended.withLock { $0 = true }
        }
        return spinUntil(timeout: seconds) { ended.withLock { $0 } }
    }
}
