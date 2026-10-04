import AVFoundation

// MARK: - The Answer macOS Holds

/// Whether TextMouth may record from microphones, as macOS's privacy
/// settings (Privacy & Security, Microphone) hold the answer.
enum AudioInputAuthorization: Equatable, Sendable {
    /// Nobody has answered yet: asking shows macOS's prompt.
    case notDetermined
    /// The user allowed TextMouth to use microphones.
    case authorized
    /// The user turned it off, in the prompt or in System Settings.
    case denied
    /// Something other than the user, such as a device management profile
    /// or Screen Time, does not allow it; the user cannot change that here.
    case restricted

    /// The answer AVFoundation reports as `status`. A status added in a
    /// later macOS counts as denied, so TextMouth never records without an
    /// answer it knows to be yes.
    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        @unknown default: self = .denied
        }
    }
}

// MARK: - Why TextMouth Can't Record

/// Why TextMouth can't record from a microphone, in words the Record window
/// shows and VoiceOver speaks: what is wrong, and what the user can do.
enum AudioInputPermissionError: LocalizedError, Equatable, Sendable {
    /// The user said no, in macOS's prompt or in System Settings.
    case denied
    /// Something other than the user does not allow microphones.
    case restricted

    var errorDescription: String? {
        switch self {
        case .denied:
            return "TextMouth isn't allowed to use the microphone. To record, turn on TextMouth in "
                + "System Settings, Privacy & Security, Microphone."
        case .restricted:
            return "This Mac doesn't allow TextMouth to use the microphone: a device management profile "
                + "or Screen Time restricts it."
        }
    }

    /// Whether the user can change this in System Settings, so the Record
    /// window offers a button that opens the Microphone privacy settings.
    var canBeChangedInSystemSettings: Bool {
        self == .denied
    }
}

// MARK: - Asking

/// Asks macOS for permission to record from microphones, and says whether
/// TextMouth has it.
///
/// Every recording asks through `ensureAccess()` before it starts. Without
/// permission macOS gives an app silence, not an error ("it captures only
/// silence (zeroed out audio samples)", AVAudioApplication's documentation),
/// so a denial here is an error the Record window speaks, and nothing is
/// recorded at all.
///
/// The answer comes from two closures, so a test hands the recorder an
/// answer of its own and macOS's prompt never appears while the suite runs.
/// Even the system's own answer (`system`) never asks inside a process
/// hosting tests, unless a person running the opt-in microphone test has
/// said so (`mayAsk(isHostedTest:environment:)`).
struct AudioInputPermission: Sendable {
    /// The answer macOS holds now, read without asking.
    var status: @Sendable () -> AudioInputAuthorization
    /// Asks the user, which shows macOS's prompt only while nobody has
    /// answered, and returns whether TextMouth may now record.
    var request: @Sendable () async -> Bool

    /// The environment variable that lets the opt-in microphone test ask
    /// for real permission inside the test host. xcodebuild hands the host
    /// `TEST_RUNNER_TEXTMOUTH_MICROPHONE` under this name, without its
    /// prefix.
    nonisolated static let microphoneTestVariable = "TEXTMOUTH_MICROPHONE"

    /// Where System Settings shows the apps allowed to use microphones,
    /// which the Record window opens after a denial.
    nonisolated static let privacySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")

    /// macOS's own answer, through AVFoundation, for this process.
    static var system: AudioInputPermission {
        let runtime = TextMouthRuntime.current
        let mayAsk = mayAsk(isHostedTest: runtime.isHostedTest, environment: ProcessInfo.processInfo.environment)
        return AudioInputPermission(
            status: { AudioInputAuthorization(AVCaptureDevice.authorizationStatus(for: .audio)) },
            request: {
                // A hosted test that forgot to hand in its own answer gets
                // a no rather than macOS's prompt on the developer's screen.
                guard mayAsk else { return false }
                return await AVCaptureDevice.requestAccess(for: .audio)
            }
        )
    }

    /// Whether a process may show macOS's microphone prompt: always in the
    /// app, and in a process hosting tests only when `environment` opts in
    /// to the real-microphone test.
    nonisolated static func mayAsk(isHostedTest: Bool, environment: [String: String]) -> Bool {
        !isHostedTest || environment[microphoneTestVariable] == "1"
    }

    /// Makes sure TextMouth may record: returns at once when it may, asks
    /// when nobody has answered yet, and throws when the answer is no.
    /// - Throws: `AudioInputPermissionError.denied` when the user said no,
    ///   now or before, and `.restricted` when something else forbids it.
    func ensureAccess() async throws {
        switch status() {
        case .authorized:
            return
        case .denied:
            throw AudioInputPermissionError.denied
        case .restricted:
            throw AudioInputPermissionError.restricted
        case .notDetermined:
            guard await request() else {
                // The answer just given, or a restriction that kept macOS
                // from asking at all.
                throw status() == .restricted ? AudioInputPermissionError.restricted : AudioInputPermissionError.denied
            }
        }
    }
}
