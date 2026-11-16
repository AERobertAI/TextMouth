// Phase 0 stand-in: the Mac's WatchedProcess (Platform/macOS/Services) runs
// textutil, afconvert, afinfo and the braille helper as child processes that a
// watchdog kills when they hang or grow too large. iOS lets an app start no
// child process at all, so here nothing is ever started. `run`, which does a
// conversion, throws `IOSUnavailable`, and the callers' existing error paths
// report that the conversion cannot be done. `runCapturingOutput`, which only
// asks a helper a question, answers that the helper could not start, which its
// caller reads as "no answer" (see its comment). `Limits`, `KillReason` (with
// its `words`), and `Outcome` are plain values that callers build and switch
// over, so they are copied here from the Mac file with the same members; a
// phase 1 clean-up could move them to a file both platforms share.

import Foundation

/// The iOS stand-in for the Mac's watched child processes: it starts nothing.
enum WatchedProcess {
    /// What the watchdog allows a child (a copy of the Mac's value type).
    struct Limits: Equatable, Sendable {
        /// The longest the child may run, in seconds.
        var maximumSeconds: TimeInterval
        /// The most resident memory the child may hold, in bytes.
        var maximumResidentBytes: Int64
        /// The longest the watched file may go without growing, in seconds.
        var maximumStalledSeconds: TimeInterval
        /// How often the watchdog looks, in seconds.
        var pollInterval: TimeInterval = 1
        /// The most processor time the child may use, in seconds. Nil means
        /// four times `maximumSeconds`.
        var maximumCPUSeconds: TimeInterval?
        /// The most the watched file may grow to, in bytes. Nil means no cap.
        var maximumOutputBytes: Int64?

        /// The CPU allowance in force: the explicit one, else four times
        /// `maximumSeconds`.
        var effectiveMaximumCPUSeconds: TimeInterval {
            maximumCPUSeconds ?? maximumSeconds * 4
        }
    }

    /// Why the watchdog killed a child (a copy of the Mac's value type).
    enum KillReason: Equatable, Sendable {
        /// It ran longer than `seconds`.
        case tookTooLong(seconds: TimeInterval)
        /// Its resident memory passed `bytes`.
        case usedTooMuchMemory(bytes: Int64)
        /// Its output file did not grow for `seconds`.
        case madeNoProgress(seconds: TimeInterval)
        /// It used more than `seconds` of processor time.
        case usedTooMuchProcessorTime(seconds: TimeInterval)
        /// Its watched output file grew past `bytes`.
        case wroteTooMuch(bytes: Int64)

        /// The reason as a phrase, worded exactly as on the Mac: "it ran
        /// longer than 62 seconds".
        var words: String {
            switch self {
            case let .tookTooLong(seconds):
                return "it ran longer than \(CountWording.seconds(Int(seconds.rounded(.up))))"
            case let .usedTooMuchMemory(bytes):
                return "it held more than \(bytes / 1_048_576) MB of memory"
            case let .madeNoProgress(seconds):
                return "its output did not grow for \(CountWording.seconds(Int(seconds.rounded(.up))))"
            case let .usedTooMuchProcessorTime(seconds):
                return "it used more than \(CountWording.seconds(Int(seconds.rounded(.up)))) of processor time"
            case let .wroteTooMuch(bytes):
                return "its output passed \(bytes / 1_048_576) MB"
            }
        }
    }

    /// How a child ended (a copy of the Mac's value type).
    enum Outcome: Equatable, Sendable {
        /// It ended by itself with this exit status (0 is success).
        case exited(status: Int32)
        /// The watchdog killed it, for this reason.
        case killed(KillReason)
        /// It could not be started.
        case couldNotStart
    }

    /// How a child ended, with the signal that ended it (a copy of the Mac's
    /// value type).
    struct Ending: Equatable, Sendable {
        /// How it ended.
        var outcome: Outcome
        /// The signal that ended it, when the watchdog did not send it.
        var signal: Int32?
    }

    /// The reading end of a child's pipe (a stand-in for the Mac's, with its
    /// members): no child runs on iOS, so it never holds a byte.
    final class PipeReader: Sendable {
        /// How many bytes have been read: none.
        var bytesRead: Int64 { 0 }

        /// Nothing to note: no child runs.
        func childEnded() {}

        /// The end at once: no child writes.
        func read(upTo count: Int) async throws -> [UInt8] { [] }
    }

    /// What every captured-output file's name ends with (the same string as
    /// the Mac's).
    static let outputFileSuffix = ".watched-output"

    /// The resident memory of another process: iOS lets an app read none, so
    /// this is always nil.
    static func residentMemory(of pid: pid_t) -> Int64? { nil }

    /// There are never any running children on iOS, so there is nothing to end.
    static func terminateAll() {}

    /// Would run `executable` under a watchdog; on iOS it starts nothing and
    /// throws `IOSUnavailable`, which callers report as a failed conversion.
    /// The parameters match the Mac's so callers compile unchanged.
    static func run(
        _ executable: URL,
        arguments: [String],
        watching output: URL,
        limits: Limits,
        residentMemory: @escaping @Sendable (pid_t) -> Int64? = WatchedProcess.residentMemory(of:),
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) async throws -> Outcome {
        throw IOSUnavailable.feature("Converting this kind of file")
    }

    /// Would run `executable` and return what it prints; on iOS it starts
    /// nothing, and answers that the helper could not start, with nothing
    /// printed. The parameters match the Mac's.
    ///
    /// It answers rather than throws because its one caller,
    /// `AudioFileInfo.read`, is documented to throw only for cancellation, and
    /// reads `.couldNotStart` as "no answer". That is what an M4B, M4A, or MP4
    /// needs: its bytes leave open what it holds, so the import asks afinfo
    /// (`ImportAudioConverter.needsConversion(among:using:)`), and a file with
    /// no answer is left as it is and played by `AVPlayer`. A throw here once
    /// stopped every such import at "Converting its audio".
    static func runCapturingOutput(
        _ executable: URL,
        arguments: [String],
        limits: Limits,
        maximumOutputBytes: Int = 1 << 20,
        outputFolder: URL = FileManager.default.temporaryDirectory,
        residentMemory: @escaping @Sendable (pid_t) -> Int64? = WatchedProcess.residentMemory(of:),
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) async throws -> (outcome: Outcome, output: Data) {
        (outcome: .couldNotStart, output: Data())
    }

    /// Would run `executable` and hand its output to `read` as it comes
    /// (the Mac's FFmpeg helper, FMT50); on iOS it starts nothing and throws
    /// `IOSUnavailable`, as `run` does. The parameters match the Mac's.
    static func runStreaming<Value: Sendable>(
        _ executable: URL,
        arguments: [String],
        watching output: URL?,
        limits: Limits,
        residentMemory: @escaping @Sendable (pid_t) -> Int64? = WatchedProcess.residentMemory(of:),
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        reading read: (PipeReader) async throws -> Value
    ) async throws -> (ending: Ending, read: Result<Value, any Error>) {
        throw IOSUnavailable.feature("Converting this kind of file")
    }
}
