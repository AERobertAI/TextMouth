import Foundation

// The whole of this file is compiled into debug builds only: both of its uses
// (`TextMouthRuntime.detect` and the iPhone's scene delegate) are inside
// `#if DEBUG`, so a release build holds neither the type nor its two variable
// names, and no environment variable can steer it.
#if DEBUG

/// What a UI test, or a run in the iOS simulator, asks of the iPhone app at
/// launch through the app's environment, in debug builds only: to run with a
/// library of its own, and to be sent a book as another app would send one.
///
/// A UI test drives the app from a process of its own, and XCTest names its
/// configuration (`TextMouthRuntime.testConfigurationVariable`) only in a
/// process that hosts a test bundle, which the app a UI test drives does not.
/// So without asking, that app would use its real container's library, and
/// each test would find what the last one left there. With
/// `sandboxVariable`, `TextMouthRuntime` gives the launch what a hosted test
/// has: an empty library and preferences in a sandbox of its own, feeds that
/// never reach the network, and no joining of the system's media session.
///
/// With `openVariable`, the scene delegate hands the file to the life cycle
/// as if another app had sent it at a cold launch, so the book comes in the
/// way a person's would: held until the library starts, copied by the
/// import's copier, imported, and opened. The file is never moved or deleted:
/// the copier works from a copy, and the phone keeps every original
/// (`PhoneDefaults`).
///
/// From a Mac's shell, `xcrun simctl launch` passes each variable with the
/// prefix `SIMCTL_CHILD_`, as in `SIMCTL_CHILD_TEXTMOUTH_UI_TEST=1`.
enum PhoneLaunchRequest {
    /// Set to "1": the launch runs in a sandbox of its own, as a hosted test does.
    static let sandboxVariable = "TEXTMOUTH_UI_TEST"
    /// An absolute path: the file the launch is sent, as another app would send it.
    static let openVariable = "TEXTMOUTH_OPEN_AT_LAUNCH"

    /// Whether `environment` asks for a sandbox: only the exact value "1", so
    /// an empty or mistyped value leaves the app as it is.
    static func runsInSandbox(_ environment: [String: String]) -> Bool {
        environment[sandboxVariable] == "1"
    }

    /// The file `environment` sends, or none. Only an absolute path counts: a
    /// relative one would be read against a working folder the launch doesn't
    /// choose.
    static func filesToOpen(_ environment: [String: String]) -> [URL] {
        guard let path = environment[openVariable], path.hasPrefix("/") else { return [] }
        return [URL(fileURLWithPath: path)]
    }
}

#endif
