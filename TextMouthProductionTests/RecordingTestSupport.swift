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
    /// Whether its microphone goes away while it is still starting, before
    /// `start` returns, as a microphone unplugged at that moment does.
    private let losesMicrophoneWhileStarting: Bool

    /// A backend writing files at `sampleRate`, whose first start throws
    /// `startError` when given, and whose microphone goes away while it
    /// starts when `losesMicrophoneWhileStarting`.
    init(sampleRate: Double = 8_000, startError: Error? = nil, losesMicrophoneWhileStarting: Bool = false) {
        self.sampleRate = sampleRate
        self.startError = startError
        self.losesMicrophoneWhileStarting = losesMicrophoneWhileStarting
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
        if losesMicrophoneWhileStarting {
            recorded = 0.5
            try disconnect()
        }
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

// MARK: - A Record Window Without Hardware

/// A Record window model with fakes for everything outside it: a recorder
/// that needs no microphone, recording into a folder of the test's own, a
/// fixed list of microphones, a preferences store of the test's own, a
/// save that records what it was asked, and announcements and opened books
/// caught in lists. Nothing is spoken, recorded, or saved for real.
@MainActor
struct RecordingWindowHarness {
    let model: RecordingWindowModel
    let backend: FakeCaptureBackend
    let catalog: FakeRecordingInputCatalog
    let store: UserDefaults
    let saver: FakeRecordingSaver
    let announcements: SentenceLog
    /// The folder the window's recorder records into, where it finds the
    /// takes recordings left behind.
    let takesFolder: URL
    private let opened: BookLog

    /// The books the window opened in a reader.
    var openedBooks: [UUID] { opened.ids }

    /// A window opening at a fixed moment on `devices`, macOS's default
    /// input `systemDefault`, and the microphone `remembered`, with
    /// `permission`'s answer; recording into `takesFolder`, a new folder
    /// unless given; pausing the readers of `readers`, a coordinator of the
    /// test's own, as a recording starts, and none without one, so no reader
    /// of another test is ever touched; and opening on `recovered`, as
    /// launch opens it.
    init(
        test: XCTestCase,
        devices: [AudioInputDevice] = [TestMicrophones.builtIn, TestMicrophones.airPods, TestMicrophones.usb],
        systemDefault: String? = nil,
        remembered: String = "",
        permission: FakeMicrophonePermission = FakeMicrophonePermission(.authorized),
        takesFolder: URL? = nil,
        readers: NowPlayingService? = nil,
        recovered: [RecoveredTake] = []
    ) throws {
        let backend = FakeCaptureBackend()
        let catalog = FakeRecordingInputCatalog(devices, systemDefault: systemDefault)
        let store = test.makeSandboxedPreferences("recording-window")
        RecordingInputChoice.preference.write(remembered, to: store)
        let saver = FakeRecordingSaver()
        let announcements = SentenceLog()
        let opened = BookLog()
        let folder = try takesFolder ?? RecordingAudioFixtures.makeTakesFolder(for: test)
        let service = RecordingService(
            backend: backend,
            permission: permission.permission,
            takesFolder: folder,
            pollInterval: nil
        )
        model = RecordingWindowModel(
            service: service,
            catalog: catalog,
            store: store,
            saver: saver.saver,
            folderPaths: { ["Fiction/Sci-Fi", "Fiction"] },
            announce: { announcements.sentences.append($0) },
            openBook: { opened.ids.append($0) },
            now: { RecordingWindowHarness.opensAt },
            announcementLead: .zero,
            pauseReaders: { readers?.pauseEveryPlayingReader() ?? 0 },
            recovered: recovered
        )
        self.backend = backend
        self.catalog = catalog
        self.store = store
        self.saver = saver
        self.announcements = announcements
        self.takesFolder = folder
        self.opened = opened
    }

    /// When every window of these tests opens.
    nonisolated static let opensAt = Date(timeIntervalSince1970: 1_791_000_000)
}

/// The sentences a window announced, in order.
@MainActor
final class SentenceLog {
    var sentences: [String] = []
}

/// The books a window opened, in order.
@MainActor
final class BookLog {
    var ids: [UUID] = []
}

/// A save that records what it was asked and fails when told to. A save
/// that succeeds removes the take from the Recordings folder, as the
/// library's save does once the book holds it.
@MainActor
final class FakeRecordingSaver {
    /// One save asked of it.
    struct Call {
        let take: RecordedTake
        let title: String
        let folderPath: String
        let policy: AudioOriginalPolicy
    }

    /// The saves asked, in order.
    private(set) var calls: [Call] = []
    /// The error the next saves throw, while set.
    var failure: Error?
    /// Whether saves wait, once asked, until `releaseSaves()`, as a slow
    /// save does, so a test can act while one is under way.
    var holdsSaves = false
    /// The saves waiting for `releaseSaves()`.
    private var heldSaves: [CheckedContinuation<Void, Never>] = []

    /// Whether a save is waiting for `releaseSaves()`.
    var isHoldingASave: Bool {
        !heldSaves.isEmpty
    }

    /// Lets every save waiting go on, and the saves after them too.
    func releaseSaves() {
        holdsSaves = false
        let held = heldSaves
        heldSaves = []
        held.forEach { $0.resume() }
    }

    /// The save to hand the window. It holds the saver weakly, so a save a
    /// window starts after its test ended fails rather than reaching a
    /// saver that is gone.
    var saver: RecordingWindowModel.Saver {
        { [weak self] take, title, folderPath, policy in
            guard let self else { throw CancellationError() }
            calls.append(Call(take: take, title: title, folderPath: folderPath, policy: policy))
            if holdsSaves {
                await withCheckedContinuation { heldSaves.append($0) }
            }
            if let failure { throw failure }
            RecordingTakeFiles.remove(take.url)
            return Book(title: title, format: .audio, filePath: "/Recordings/\(title).m4a", md5Hash: UUID().uuidString, folderPath: folderPath)
        }
    }
}

extension XCTestCase {
    /// Every accessibility element below `root` whose identifier is
    /// `identifier`.
    @MainActor
    func accessibilityElements(identified identifier: String, in root: Any) -> [NSAccessibilityProtocol] {
        guard let node = root as? NSAccessibilityProtocol else { return [] }
        let match = node.accessibilityIdentifier() == identifier ? [node] : []
        return match + (node.accessibilityChildren() ?? []).flatMap {
            accessibilityElements(identified: identifier, in: $0)
        }
    }
}
