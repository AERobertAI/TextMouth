import AVFoundation
import os

// MARK: - What Capture Reports

/// Something a capture backend noticed while it recorded, reported from
/// whatever thread noticed it.
enum RecordingCaptureEvent: Equatable, Sendable {
    /// The microphone went away, as AirPods put back in their case or a USB
    /// microphone unplugged do. The file holds what was recorded until then.
    case deviceDisconnected
    /// The disk came within `CaptureSessionRecordingBackend.minimumFreeDiskSpace`
    /// of full, so capture stopped. The file holds what was recorded.
    case diskFull
    /// Capture stopped for another reason, described for the debug log.
    case failed(String)
}

/// How loud the audio being captured is, in decibels relative to full
/// scale (dBFS): 0 is the loudest a sample can be, and every other level is
/// below it, so the numbers are negative.
struct RecordingLevels: Equatable, Sendable {
    /// The average power of the audio just captured.
    var average: Float
    /// The highest level reached lately, held for a moment, as meters hold
    /// a peak so that a short one can be seen.
    var peak: Float
}

/// A moment of a capture: how much it has recorded and how loud it is.
struct RecordingCaptureSnapshot: Equatable, Sendable {
    /// How much audio the file holds, in seconds, pauses left out.
    var recordedDuration: TimeInterval
    /// The levels of the audio coming in, or nil while none is measured.
    var levels: RecordingLevels?
}

/// Why capture could not start or finish.
enum RecordingCaptureError: Error, Equatable, Sendable {
    /// The microphone is not connected, or macOS no longer offers it.
    case deviceUnavailable
    /// The capture session could not use the microphone or the file; the
    /// words are AVFoundation's, for the debug log.
    case setupFailed(String)
    /// Recording did not begin.
    case didNotStart(String)
    /// The file could not be finished properly.
    case didNotFinish(String)
}

// MARK: - A Capture Backend

/// Records the audio of one microphone into a file. The app's backend is
/// AVFoundation's capture session (`CaptureSessionRecordingBackend`); tests
/// use a fake that writes a file of generated sound, so the suite never
/// needs a microphone or macOS's permission.
///
/// Every method is asynchronous, and the app's backend does its work on a
/// queue of its own, so nothing on the main thread waits on the device.
protocol RecordingCaptureBackend: Sendable {
    /// Starts recording from the microphone `deviceID` into a new 16-bit
    /// linear PCM file in the Core Audio Format at `url`, and returns once
    /// audio is being written. `events` hears about a lost device, a full
    /// disk, or a failure, from any thread, after `start` returned.
    func start(
        deviceID: String,
        writingTo url: URL,
        events: @escaping @Sendable (RecordingCaptureEvent) -> Void
    ) async throws

    /// Stops writing audio into the file, keeping it open for `resume()`.
    func pause() async

    /// Writes audio into the file again after `pause()`.
    func resume() async

    /// Stops recording and returns once the file is complete, then lets go
    /// of the microphone. A recording that already ended on its own, as a
    /// lost device ends one, is only let go of.
    /// - Throws: `RecordingCaptureError.didNotFinish` when the file could not
    ///   be finished; what was written so far stays in it.
    func stop() async throws

    /// The capture now: how much it has recorded, and how loud.
    func snapshot() async -> RecordingCaptureSnapshot
}

// MARK: - AVFoundation's Capture Session

/// Records through AVFoundation: an `AVCaptureSession` holding the chosen
/// microphone and an `AVCaptureAudioFileOutput` that writes 16-bit PCM into
/// a CAF file, mono, at the microphone's own sample rate. AVCaptureAudioFileOutput
/// pauses and resumes into the same file, and its connection's audio
/// channels give the levels.
///
/// An actor running on a serial queue of its own: `startRunning()` and
/// `stopRunning()` block until the session starts or stops, which must
/// never happen on the main thread, and the capture objects, which are not
/// thread-safe, are only ever touched on this queue.
actor CaptureSessionRecordingBackend: RecordingCaptureBackend {
    /// The queue every capture call runs on.
    private let queue = DispatchSerialQueue(label: "com.textmouth.recording.capture", qos: .userInitiated)

    /// Runs this actor on `queue`.
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// The free space capture leaves on the disk: rather than fill it, it
    /// stops a recording, keeping what it wrote, once less than this is
    /// free (`AVCaptureFileOutput.minFreeDiskSpaceLimit`).
    static let minimumFreeDiskSpace: Int64 = 512 * 1024 * 1024

    /// How long a recording may take to begin before it counts as failed.
    static let startTimeout: Duration = .seconds(10)

    /// The session, while recording.
    private var session: AVCaptureSession?
    /// The file output, while recording.
    private var output: AVCaptureAudioFileOutput?
    /// The delegate that hears the file output, while recording.
    private var delegate: FileRecordingDelegate?
    /// The observers of the microphone going away and of the session
    /// failing, while recording.
    private var observers: [NSObjectProtocol] = []

    /// A backend that records nothing until asked.
    init() {}

    func start(
        deviceID: String,
        writingTo url: URL,
        events: @escaping @Sendable (RecordingCaptureEvent) -> Void
    ) async throws {
        guard session == nil else { throw RecordingCaptureError.setupFailed("a recording is already under way") }
        guard let device = AVCaptureDevice(uniqueID: deviceID), device.isConnected else {
            throw RecordingCaptureError.deviceUnavailable
        }

        let session = AVCaptureSession()
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw RecordingCaptureError.setupFailed(Self.describe(error))
        }
        guard session.canAddInput(input) else { throw RecordingCaptureError.setupFailed("the session refused the microphone") }
        session.addInput(input)
        let output = AVCaptureAudioFileOutput()
        output.minFreeDiskSpaceLimit = Self.minimumFreeDiskSpace
        guard session.canAddOutput(output) else { throw RecordingCaptureError.setupFailed("the session refused the file output") }
        session.addOutput(output)

        // Blocks this queue until the session runs or fails.
        session.startRunning()
        guard session.isRunning else {
            throw RecordingCaptureError.didNotStart("the capture session did not start")
        }
        self.session = session
        self.output = output
        observe(device: device, session: session, reporting: events)

        // 16-bit PCM first, as the take should be; should capture refuse
        // those settings, once more with the microphone's own PCM format,
        // which a CAF file holds just as safely.
        do {
            try await record(to: url, with: Self.pcmSettings(sampleRate: Self.sampleRate(of: device)), events: events)
        } catch {
            DiagnosticLog.event(.playback, "RECORDING_FORMAT_FALLBACK: 16-bit capture did not start (\(Self.describe(error))); recording in the microphone's own format")
            try? FileManager.default.removeItem(at: url)
            do {
                try await record(to: url, with: nil, events: events)
            } catch {
                tearDown()
                throw error
            }
        }
    }

    func pause() async {
        guard let output, output.isRecording, !output.isRecordingPaused else { return }
        output.pauseRecording()
    }

    func resume() async {
        guard let output, output.isRecordingPaused else { return }
        output.resumeRecording()
    }

    func stop() async throws {
        defer { tearDown() }
        guard let output, let delegate else { return }
        if output.isRecording {
            try await delegate.waitForFinish { output.stopRecording() }
        } else if let failure = delegate.unfinishedFailure {
            throw RecordingCaptureError.didNotFinish(failure)
        }
    }

    func snapshot() async -> RecordingCaptureSnapshot {
        guard let output else { return RecordingCaptureSnapshot(recordedDuration: 0, levels: nil) }
        let duration = output.recordedDuration.seconds
        let channels = output.connections.flatMap(\.audioChannels)
        // The loudest channel stands for the take, which is mixed to mono.
        let levels = channels.isEmpty ? nil : RecordingLevels(
            average: channels.map(\.averagePowerLevel).max() ?? -.infinity,
            peak: channels.map(\.peakHoldLevel).max() ?? -.infinity
        )
        return RecordingCaptureSnapshot(recordedDuration: duration.isFinite ? max(0, duration) : 0, levels: levels)
    }

    // MARK: Helpers

    /// Starts the file output recording into `url` with `settings` (nil for
    /// the microphone's own format) and waits until it has begun, or failed,
    /// or `startTimeout` passed.
    private func record(
        to url: URL,
        with settings: [String: Any]?,
        events: @escaping @Sendable (RecordingCaptureEvent) -> Void
    ) async throws {
        guard let output else { throw RecordingCaptureError.didNotStart("no file output") }
        output.audioSettings = settings
        let delegate = FileRecordingDelegate(events: events)
        self.delegate = delegate
        try await delegate.waitForStart(timeout: Self.startTimeout) {
            output.startRecording(to: url, outputFileType: .caf, recordingDelegate: delegate)
        }
    }

    /// Reports the microphone going away, and the session failing, to
    /// `events`.
    private func observe(
        device: AVCaptureDevice,
        session: AVCaptureSession,
        reporting events: @escaping @Sendable (RecordingCaptureEvent) -> Void
    ) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { _ in
            events(.deviceDisconnected)
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            events(.failed(error.map { "\($0.domain) \($0.code)" } ?? "the capture session failed"))
        })
    }

    /// Lets go of the microphone and forgets the recording.
    private func tearDown() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        if let session, session.isRunning {
            // Blocks this queue until the session has stopped.
            session.stopRunning()
        }
        session = nil
        output = nil
        delegate = nil
    }

    /// The settings of a take: 16-bit little-endian integer samples,
    /// interleaved, one channel, at `sampleRate`.
    static func pcmSettings(sampleRate: Double) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// The sample rate `device` captures at: 48 kHz for a Mac's own
    /// microphone, 24 kHz for AirPods. 48 kHz when it does not say.
    private static func sampleRate(of device: AVCaptureDevice) -> Double {
        let rate = device.activeFormat.formatDescription.audioStreamBasicDescription?.mSampleRate ?? 0
        return rate > 0 ? rate : 48_000
    }

    /// An error as the debug log names it: its domain and code, never its
    /// description, which can hold a path.
    static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)"
    }
}

// MARK: - Hearing the File Output

/// Hears what the file output reports: that recording began, that it
/// finished, and why. AVFoundation calls it on a thread of its own, so what
/// it keeps is behind a lock, and the waits it ends are continuations,
/// each resumed exactly once.
final class FileRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, Sendable {
    /// Where events after the start go: a recording that ended on its own.
    private let events: @Sendable (RecordingCaptureEvent) -> Void

    /// What the delegate keeps between calls.
    private struct State {
        /// The wait for recording to begin, until it ends.
        var start: CheckedContinuation<Void, Error>?
        /// The wait for a requested stop, until the file is finished.
        var finish: CheckedContinuation<Void, Error>?
        /// Whether recording began.
        var started = false
        /// Whether the file is finished.
        var finished = false
        /// Why the file could not be finished properly, when it couldn't.
        var unfinishedFailure: String?
    }

    /// The state, read and changed only under its lock.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A delegate reporting a recording that ends on its own to `events`.
    init(events: @escaping @Sendable (RecordingCaptureEvent) -> Void) {
        self.events = events
    }

    /// Why the file could not be finished, once it ended without being
    /// stopped; nil while it did not, or ended well.
    var unfinishedFailure: String? {
        state.withLock { $0.unfinishedFailure }
    }

    /// Runs `begin`, which starts recording, and waits until recording has
    /// begun. Throws when it ended before beginning, or did not begin
    /// within `timeout`. Runs on the caller's actor (`isolation`), the
    /// capture queue, where `begin` may touch the capture objects.
    func waitForStart(
        timeout: Duration,
        isolation: isolated (any Actor)? = #isolation,
        _ begin: () -> Void
    ) async throws {
        try await withCheckedThrowingContinuation(isolation: isolation) { (continuation: CheckedContinuation<Void, Error>) in
            state.withLock { $0.start = continuation }
            begin()
            // Whichever comes first, the start or the timeout, ends the wait.
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resumeStart(with: .failure(RecordingCaptureError.didNotStart("recording did not begin in time")))
            }
        }
    }

    /// Runs `end`, which stops recording, and waits until the file is
    /// finished. Throws when it could not be finished properly. Runs on the
    /// caller's actor (`isolation`), as `waitForStart` does.
    func waitForFinish(
        isolation: isolated (any Actor)? = #isolation,
        _ end: () -> Void
    ) async throws {
        try await withCheckedThrowingContinuation(isolation: isolation) { (continuation: CheckedContinuation<Void, Error>) in
            let alreadyFinished = state.withLock { state -> Bool in
                guard !state.finished else { return true }
                state.finish = continuation
                return false
            }
            if alreadyFinished {
                continuation.resume()
            } else {
                end()
            }
        }
    }

    /// Ends the wait for the start, if one is waiting, with `result`.
    private func resumeStart(with result: Result<Void, Error>) {
        let waiting = state.withLock { state -> CheckedContinuation<Void, Error>? in
            defer { state.start = nil }
            return state.start
        }
        waiting?.resume(with: result)
    }

    // MARK: AVCaptureFileOutputRecordingDelegate

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        state.withLock { $0.started = true }
        resumeStart(with: .success(()))
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let outcome = Self.outcome(of: error)
        let (startWait, finishWait, wasStarted) = state.withLock { state in
            defer {
                state.start = nil
                state.finish = nil
                state.finished = true
                if case .failed(let reason) = outcome { state.unfinishedFailure = reason }
            }
            return (state.start, state.finish, state.started)
        }
        if let startWait {
            // It ended before it began.
            startWait.resume(throwing: RecordingCaptureError.didNotStart(outcome.description))
        } else if let finishWait {
            // A requested stop: the file is finished, unless it failed.
            if case .failed(let reason) = outcome {
                finishWait.resume(throwing: RecordingCaptureError.didNotFinish(reason))
            } else {
                finishWait.resume()
            }
        } else if wasStarted, let event = outcome.event {
            // It ended on its own: a lost device, a full disk, a failure.
            events(event)
        }
    }

    // MARK: Outcomes

    /// How a recording ended, from the error AVFoundation finished it with.
    enum Outcome: Equatable {
        /// It ended as asked, or with an error that still left a complete
        /// file (`AVErrorRecordingSuccessfullyFinishedKey`) other than the
        /// two below.
        case finished
        /// The microphone went away; the file holds what came before.
        case deviceDisconnected
        /// The disk was nearly full; the file holds what came before.
        case diskFull
        /// It failed, for the reason given.
        case failed(String)

        /// What to tell the recorder about a recording that ended this way
        /// without being stopped.
        var event: RecordingCaptureEvent? {
            switch self {
            case .finished: return .failed("recording ended on its own")
            case .deviceDisconnected: return .deviceDisconnected
            case .diskFull: return .diskFull
            case .failed(let reason): return .failed(reason)
            }
        }

        /// A description for an error and the debug log.
        var description: String {
            switch self {
            case .finished: return "finished"
            case .deviceDisconnected: return "the microphone was disconnected"
            case .diskFull: return "the disk was full"
            case .failed(let reason): return reason
            }
        }
    }

    /// How a recording that AVFoundation finished with `error` ended.
    static func outcome(of error: Error?) -> Outcome {
        guard let error else { return .finished }
        let nsError = error as NSError
        if nsError.domain == AVFoundationErrorDomain {
            switch nsError.code {
            case AVError.Code.deviceWasDisconnected.rawValue:
                return .deviceDisconnected
            case AVError.Code.diskFull.rawValue:
                return .diskFull
            default:
                break
            }
        }
        if nsError.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true {
            return .finished
        }
        return .failed("\(nsError.domain) \(nsError.code)")
    }
}
