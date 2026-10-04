import AVFoundation
import os
import XCTest
@testable import TextMouth

// Fakes shared by the recording tests, so each exists once. No test of
// recording ever reaches a microphone or macOS's permission prompt: each
// hands the recorder one of these instead.

// MARK: - Microphone Permission

/// A microphone permission that answers as a test tells it, and counts how
/// often it was asked, so a test can tell that a recording asked once, or
/// never. Asking while nobody has answered changes the answer it holds, as
/// macOS's prompt does: to authorized for a yes, and for a no to denied, or
/// to restricted when `restrictsWhenAsked` says something forbade asking.
final class FakeMicrophonePermission: Sendable {
    /// What the permission holds: the answer, how a question is answered,
    /// and how many were asked. Behind a lock, since the recorder asks from
    /// whatever thread its task runs on.
    private struct State {
        var status: AudioInputAuthorization
        var answer: Bool
        var restrictsWhenAsked: Bool
        var questions = 0
    }

    /// The state, read and changed only under its lock.
    private let state: OSAllocatedUnfairLock<State>

    /// A permission holding `status`, which answers a question with
    /// `answer` while nobody has answered.
    init(_ status: AudioInputAuthorization, whenAsked answer: Bool = false, restrictsWhenAsked: Bool = false) {
        state = OSAllocatedUnfairLock(initialState: State(
            status: status,
            answer: answer,
            restrictsWhenAsked: restrictsWhenAsked
        ))
    }

    /// How many times the permission was asked.
    var questions: Int {
        state.withLock { $0.questions }
    }

    /// The answer it holds now.
    var status: AudioInputAuthorization {
        state.withLock { $0.status }
    }

    /// The permission to hand a recorder.
    var permission: AudioInputPermission {
        AudioInputPermission(
            status: { [self] in status },
            request: { [self] in
                state.withLock { state in
                    state.questions += 1
                    if state.status == .notDetermined {
                        state.status = state.answer
                            ? .authorized
                            : (state.restrictsWhenAsked ? .restricted : .denied)
                    }
                    return state.status == .authorized
                }
            }
        )
    }
}

// MARK: - Generated Audio

/// Writes the audio the recording tests need: a quiet tone, as a take holds
/// a voice, into the 16-bit mono PCM CAF files capture writes.
enum RecordingAudioFixtures {
    /// The settings of a take's file: 16-bit little-endian integer samples,
    /// one channel, at `sampleRate`, as capture writes them.
    static func takeSettings(sampleRate: Double) -> [String: Any] {
        CaptureSessionRecordingBackend.pcmSettings(sampleRate: sampleRate)
    }

    /// Writes `duration` seconds of a 440 Hz tone at a quarter of full scale
    /// to `url`, a CAF file, at `sampleRate`. No duration writes a file with
    /// a header and no audio.
    static func writeTake(to url: URL, duration: TimeInterval, sampleRate: Double = 8_000) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(
            forWriting: url,
            settings: takeSettings(sampleRate: sampleRate),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let total = AVAudioFrameCount((duration * sampleRate).rounded())
        let chunk: AVAudioFrameCount = 4_096
        var written: AVAudioFrameCount = 0
        while written < total {
            let count = min(chunk, total - written)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count),
                  let samples = buffer.floatChannelData?[0] else {
                throw CocoaError(.fileWriteUnknown)
            }
            buffer.frameLength = count
            for index in 0..<Int(count) {
                let time = Double(Int(written) + index) / sampleRate
                samples[index] = 0.25 * Float(sin(2 * Double.pi * 440 * time))
            }
            try file.write(from: buffer)
            written += count
        }
    }

    /// A new, empty folder for one test's takes, removed when the test ends.
    static func makeTakesFolder(for test: XCTestCase) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingTakes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }
}

// MARK: - A Capture Backend Without a Microphone

/// A capture backend that needs no microphone: the test says how much it
/// records and how loud, and it writes a file of that length of generated
/// tone when the take ends, as capture finishes its file. It can lose its
/// microphone or fill the disk, as a real one can.
actor FakeCaptureBackend: RecordingCaptureBackend {
    /// What the recorder asked of it, in order: "start <device ID>",
    /// "pause", "resume", and "stop".
    private(set) var calls: [String] = []
    /// The error the next start throws, if any.
    private var startError: Error?
    /// The sample rate of the file it writes.
    private let sampleRate: Double
    /// The file it records into, once started.
    private(set) var url: URL?
    /// Where it reports a take that ends on its own.
    private var events: (@Sendable (RecordingCaptureEvent) -> Void)?
    /// Seconds recorded so far, pauses left out.
    private var recorded: TimeInterval = 0
    /// The levels it reports.
    private var levels: RecordingLevels?
    /// Whether it is paused.
    private var isPaused = false
    /// Whether its file is finished.
    private var isFinished = false

    /// A backend writing files at `sampleRate`, whose first start throws
    /// `startError` when given.
    init(sampleRate: Double = 8_000, startError: Error? = nil) {
        self.sampleRate = sampleRate
        self.startError = startError
    }

    func start(
        deviceID: String,
        writingTo url: URL,
        events: @escaping @Sendable (RecordingCaptureEvent) -> Void
    ) async throws {
        calls.append("start \(deviceID)")
        if let startError {
            self.startError = nil
            throw startError
        }
        self.url = url
        self.events = events
        recorded = 0
        isPaused = false
        isFinished = false
        // Capture creates its file at once.
        try RecordingAudioFixtures.writeTake(to: url, duration: 0, sampleRate: sampleRate)
    }

    func pause() async {
        calls.append("pause")
        isPaused = true
    }

    func resume() async {
        calls.append("resume")
        isPaused = false
    }

    func stop() async throws {
        calls.append("stop")
        try finishFile()
    }

    func snapshot() async -> RecordingCaptureSnapshot {
        RecordingCaptureSnapshot(recordedDuration: recorded, levels: levels)
    }

    // MARK: What the Test Does

    /// Records `seconds` more, unless paused, at `levels`.
    func record(seconds: TimeInterval, levels: RecordingLevels? = RecordingLevels(average: -24, peak: -9)) {
        if !isPaused {
            recorded += seconds
        }
        self.levels = levels
    }

    /// The microphone goes away: the file is finished with what was
    /// recorded, as AVFoundation finishes it, and the loss is reported.
    func disconnect() throws {
        try finishFile()
        events?(.deviceDisconnected)
    }

    /// The disk comes near full: the file is finished, and that reported.
    func fillDisk() throws {
        try finishFile()
        events?(.diskFull)
    }

    /// Writes the file of what was recorded, once.
    private func finishFile() throws {
        guard !isFinished, let url else { return }
        isFinished = true
        try RecordingAudioFixtures.writeTake(to: url, duration: recorded, sampleRate: sampleRate)
    }
}

// MARK: - Microphones Without Hardware

/// A fixed list of microphones for the Record window, which a test changes
/// as plugging one in or out would.
@MainActor
final class FakeRecordingInputCatalog: RecordingInputCatalog {
    /// The microphones connected.
    var connected: [AudioInputDevice]
    /// macOS's default input.
    var systemDefault: String?
    var onChange: (@MainActor () -> Void)?

    /// A catalog of `connected`, whose default input is `systemDefault`, or
    /// else the first.
    init(_ connected: [AudioInputDevice], systemDefault: String? = nil) {
        self.connected = connected
        self.systemDefault = systemDefault ?? connected.first?.id
    }

    func devices() -> [AudioInputDevice] {
        connected
    }

    func systemDefaultDeviceID() -> String? {
        systemDefault
    }

    /// Plugs in or unplugs microphones: the list becomes `devices`, and the
    /// window hears of it.
    func change(to devices: [AudioInputDevice]) {
        connected = devices
        onChange?()
    }
}

/// Three microphones as a Mac has them: its own, AirPods, and a USB
/// microphone, with the kinds of identifiers macOS gives each.
enum TestMicrophones {
    static let builtIn = AudioInputDevice(id: "BuiltInMicrophoneDevice", name: "MacBook Air Microphone")
    static let airPods = AudioInputDevice(id: "AA-BB-CC-DD-EE-FF:input", name: "AirPods Pro")
    static let usb = AudioInputDevice(id: "AppleUSBAudioEngine:Studio Microphone:4100000:1", name: "Studio Microphone")
}

// MARK: - Waiting

extension XCTestCase {
    /// Waits, letting the main actor run, until `condition` holds or
    /// `timeout` seconds pass, and returns whether it held: for what the
    /// recorder does in tasks of its own.
    @MainActor
    func eventually(timeout: TimeInterval = 5, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}
