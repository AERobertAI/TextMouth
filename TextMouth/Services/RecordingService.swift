import Foundation

// MARK: - Why a Recording Stopped or Never Started

/// Why a recording could not start, or stopped on its own, in the words the
/// Record window shows and VoiceOver speaks: what happened, and, when audio
/// was recorded, that it is kept.
enum RecordingFailure: Error, Equatable, Sendable, LocalizedError {
    /// macOS's microphone permission said no (`AudioInputPermission`).
    case permission(AudioInputPermissionError)
    /// The chosen microphone, named, is not available now.
    case deviceUnavailable(String)
    /// Recording from the named microphone could not begin.
    case couldNotStart(String)
    /// The named microphone went away while recording.
    case deviceDisconnected(String)
    /// The disk was nearly full, so recording stopped.
    case diskFull
    /// Recording stopped because capture failed.
    case stoppedUnexpectedly
    /// Stop could not finish the file properly.
    case couldNotFinish
    /// Stopped before any audio was written, so there is nothing to keep.
    case nothingRecorded

    var errorDescription: String? {
        switch self {
        case .permission(let refusal):
            return refusal.errorDescription
        case .deviceUnavailable(let name):
            return "\(name) isn't available, so TextMouth can't record from it. Choose another microphone."
        case .couldNotStart(let name):
            return "TextMouth couldn't start recording from \(name)."
        case .deviceDisconnected(let name):
            return "\(name) was disconnected, so recording stopped. What was recorded until then is kept."
        case .diskFull:
            return "The disk is almost full, so recording stopped. What was recorded until then is kept."
        case .stoppedUnexpectedly:
            return "Recording stopped because the microphone reported a problem. What was recorded until then is kept."
        case .couldNotFinish:
            return "The recording couldn't be finished properly. What was recorded is kept."
        case .nothingRecorded:
            return "Nothing was recorded, so there is nothing to save."
        }
    }
}

// MARK: - The Recorder

/// Records one take at a time from a chosen microphone, into a file in this
/// Mac's Recordings folder (`MachineLocalPaths.recordings`): start, pause,
/// resume, and stop, with the time recorded and the levels as it goes.
///
/// macOS's permission is asked for first (`AudioInputPermission`), so a
/// denial is an error and nothing is recorded. The device work happens in
/// the capture backend, on a queue of its own: this main-actor model only
/// awaits it, so the main thread never waits on the microphone. A lost
/// microphone, a full disk, or a failed capture stops the take and reports
/// why, keeping what was recorded.
@MainActor
final class RecordingService: ObservableObject {
    /// Where the recorder is.
    enum State: Equatable {
        /// Nothing is recording, and no take is waiting.
        case idle
        /// A recording is starting: asking permission, opening the device.
        case starting
        /// Audio is being recorded.
        case recording
        /// Recording is paused; Resume continues into the same file.
        case paused
        /// Recording is ending and the file is being finished.
        case stopping
        /// Stopped: the take is complete in its file.
        case finished(RecordedTake)
        /// It never started, or stopped on its own: why, and the take
        /// recorded until then, if any.
        case failed(RecordingFailure, RecordedTake?)
    }

    /// Where the recorder is now.
    @Published private(set) var state: State = .idle
    /// How much the take holds, in seconds, pauses left out.
    @Published private(set) var elapsed: TimeInterval = 0
    /// How loud the microphone is, while it records or is paused.
    @Published private(set) var levels: RecordingLevels?

    /// Whether a take is under way, recording or paused.
    var isRecording: Bool {
        state == .recording || state == .paused
    }

    /// Whether a new take can start: nothing is under way, and any take
    /// that ended has been saved or discarded.
    var canStart: Bool {
        state == .idle
    }

    /// The capture backend: AVFoundation's in the app, a fake in tests.
    private let backend: any RecordingCaptureBackend
    /// Whether TextMouth may use microphones.
    private let permission: AudioInputPermission
    /// The folder takes are recorded into.
    private let takesFolder: URL
    /// How often the time and levels are read while recording; nil reads
    /// them only when asked (`refresh()`), as tests do.
    private let pollInterval: Duration?
    /// The clock that dates each take.
    private let now: @Sendable () -> Date

    /// The take under way: its file, when it started, and its microphone.
    private struct Take {
        let url: URL
        let startedAt: Date
        let device: AudioInputDevice
    }

    /// The take under way, from its start until it is finished.
    private var current: Take?
    /// Reads the time and levels while a take is under way.
    private var pollTask: Task<Void, Never>?
    /// An event the backend reported before `start` had finished, such as a
    /// microphone lost at once, handled as soon as the take is under way.
    private var eventBeforeStart: RecordingCaptureEvent?

    /// A recorder using `backend` and `permission`, recording into
    /// `takesFolder`.
    init(
        backend: any RecordingCaptureBackend,
        permission: AudioInputPermission,
        takesFolder: URL = MachineLocalPaths.recordings,
        pollInterval: Duration? = .milliseconds(100),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.backend = backend
        self.permission = permission
        self.takesFolder = takesFolder
        self.pollInterval = pollInterval
        self.now = now
    }

    /// The app's recorder: AVFoundation's capture session and macOS's
    /// permission.
    static func system() -> RecordingService {
        RecordingService(backend: CaptureSessionRecordingBackend(), permission: .system)
    }

    // MARK: Recording

    /// Starts a take from `device`: asks permission when nobody has
    /// answered, runs `beforeCapture` once permission is there, then
    /// records. Afterwards `state` is `.recording`, or `.failed` saying why
    /// nothing is recorded. The Record window's `beforeCapture` announces
    /// the start and waits a moment, so the announcement is not recorded.
    func start(from device: AudioInputDevice, beforeCapture: (@MainActor () async -> Void)? = nil) async {
        guard canStart else { return }
        state = .starting
        elapsed = 0
        levels = nil
        eventBeforeStart = nil

        do {
            try await permission.ensureAccess()
        } catch let refusal as AudioInputPermissionError {
            state = .failed(.permission(refusal), nil)
            return
        } catch {
            state = .failed(.permission(.denied), nil)
            return
        }
        await beforeCapture?()

        let startedAt = now()
        let url: URL
        do {
            url = try RecordingTakeFiles.newTakeURL(startedAt: startedAt, in: takesFolder)
        } catch {
            DiagnosticLog.event(.playback, "RECORDING_START_FAILED: the Recordings folder could not be made (\(CaptureSessionRecordingBackend.describe(error)))")
            state = .failed(.couldNotStart(device.name), nil)
            return
        }

        do {
            try await backend.start(deviceID: device.id, writingTo: url) { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
        } catch {
            RecordingTakeFiles.remove(url)
            let failure: RecordingFailure = error as? RecordingCaptureError == .deviceUnavailable
                ? .deviceUnavailable(device.name)
                : .couldNotStart(device.name)
            DiagnosticLog.event(.playback, "RECORDING_START_FAILED: \(Self.describe(error))")
            state = .failed(failure, nil)
            return
        }

        current = Take(url: url, startedAt: startedAt, device: device)
        state = .recording
        DiagnosticLog.event(.playback, "RECORDING_STARTED")
        startPolling()
        if let early = eventBeforeStart {
            eventBeforeStart = nil
            handle(early)
        }
    }

    /// Pauses the take: nothing more is written until `resume()`.
    func pause() async {
        guard state == .recording else { return }
        state = .paused
        await backend.pause()
        await refresh()
    }

    /// Resumes a paused take, into the same file.
    func resume() async {
        guard state == .paused else { return }
        state = .recording
        await backend.resume()
    }

    /// Stops the take and finishes its file. Afterwards `state` is
    /// `.finished` with the take, or `.failed` when the file could not be
    /// finished properly, keeping what was written.
    func stop() async {
        guard isRecording, let take = current else { return }
        state = .stopping
        stopPolling()
        await refresh()

        var failure: RecordingFailure?
        do {
            try await backend.stop()
        } catch {
            DiagnosticLog.event(.playback, "RECORDING_STOP_FAILED: \(Self.describe(error))")
            failure = .couldNotFinish
        }
        let recorded = await finished(take)
        current = nil
        levels = nil
        if let failure {
            state = .failed(failure, recorded)
        } else if let recorded {
            DiagnosticLog.event(.playback, "RECORDING_STOPPED: \(Self.seconds(recorded.duration)) seconds")
            state = .finished(recorded)
        } else {
            // The file holds no audio: there is no take to keep.
            state = .failed(.nothingRecorded, nil)
        }
    }

    /// Deletes the take that ended, finished or not, and gets ready for
    /// another. Does nothing while a take is under way.
    func discard() {
        switch state {
        case .finished(let take), .failed(_, let take?):
            RecordingTakeFiles.remove(take.url)
        default:
            break
        }
        reset()
    }

    /// Gets ready for another take once the one that ended has been saved
    /// elsewhere, leaving its file to whoever saved it. Does nothing while
    /// a take is under way.
    func reset() {
        guard !isRecording, state != .starting, state != .stopping else { return }
        state = .idle
        elapsed = 0
        levels = nil
    }

    // MARK: Time and Levels

    /// Reads the time recorded and the levels from the backend now. The
    /// recorder does this every `pollInterval` while a take is under way.
    func refresh() async {
        let snapshot = await backend.snapshot()
        guard isRecording || state == .stopping else { return }
        elapsed = snapshot.recordedDuration
        levels = snapshot.levels
    }

    /// Reads the time and levels every `pollInterval` until stopped.
    private func startPolling() {
        guard let pollInterval else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, let self else { return }
                await self.refresh()
            }
        }
    }

    /// Stops reading the time and levels.
    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: A Take That Ends on Its Own

    /// Stops the take the backend says ended: a lost microphone, a full
    /// disk, or a failure. What was recorded is kept, as the failure's
    /// words say.
    private func handle(_ event: RecordingCaptureEvent) {
        if state == .starting {
            // `start` is still finishing: the event waits for it.
            eventBeforeStart = eventBeforeStart ?? event
            return
        }
        guard isRecording, let take = current else { return }
        let failure: RecordingFailure
        switch event {
        case .deviceDisconnected:
            failure = .deviceDisconnected(take.device.name)
        case .diskFull:
            failure = .diskFull
        case .failed(let reason):
            DiagnosticLog.event(.playback, "RECORDING_CAPTURE_FAILED: \(reason)")
            failure = .stoppedUnexpectedly
        }
        state = .stopping
        stopPolling()
        Task {
            // The backend lets go of the microphone; the file AVFoundation
            // finished holds what came before.
            try? await backend.stop()
            let recorded = await finished(take)
            current = nil
            levels = nil
            DiagnosticLog.event(
                .playback,
                "RECORDING_INTERRUPTED: \(event.logDescription) after \(Self.seconds(recorded?.duration ?? 0)) seconds"
            )
            state = .failed(failure, recorded)
        }
    }

    // MARK: Helpers

    /// The take `take` became, measured from its file off the main thread;
    /// nil when the file holds no audio, which is then removed.
    private func finished(_ take: Take) async -> RecordedTake? {
        let url = take.url
        let measured = await Task.detached { RecordingTakeFiles.duration(of: url) }.value
        guard let duration = measured, duration > 0 else {
            RecordingTakeFiles.remove(url)
            return nil
        }
        elapsed = duration
        return RecordedTake(url: url, startedAt: take.startedAt, duration: duration, deviceName: take.device.name)
    }

    /// An error as the debug log names it.
    private static func describe(_ error: Error) -> String {
        if let capture = error as? RecordingCaptureError {
            return "\(capture)"
        }
        return CaptureSessionRecordingBackend.describe(error)
    }

    /// Seconds to one decimal place, for the debug log.
    private static func seconds(_ value: TimeInterval) -> String {
        String(format: "%.1f", value)
    }
}

private extension RecordingCaptureEvent {
    /// The event as the debug log names it.
    var logDescription: String {
        switch self {
        case .deviceDisconnected: return "the microphone was disconnected"
        case .diskFull: return "the disk was nearly full"
        case .failed(let reason): return "capture failed (\(reason))"
        }
    }
}
