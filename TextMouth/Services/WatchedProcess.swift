import Darwin
import Foundation
import os

/// Runs a command-line tool as a child process that a watchdog can kill
/// (B09). Whatever the tool does, a hang or a runaway in it costs the app a
/// child process and never the app itself: on October 14, 2026 Apple's
/// Vorbis decoder spun at 100% CPU inside TextMouth for good, and no
/// in-process call can be stopped once it does.
///
/// Once a second the watchdog (`Limits`) kills the child, with SIGKILL, when
/// it has run longer than allowed, its resident memory has passed the limit,
/// or the file it writes has not grown for too long. The child's standard
/// input, output, and errors are closed (the null device), so nothing it
/// prints can fill a pipe and stall it.
enum WatchedProcess {
    /// What the watchdog allows a child.
    struct Limits: Equatable, Sendable {
        /// The longest the child may run, in seconds.
        var maximumSeconds: TimeInterval
        /// The most resident memory the child may hold, in bytes.
        var maximumResidentBytes: Int64
        /// The longest the watched file may go without growing, in seconds.
        var maximumStalledSeconds: TimeInterval
        /// How often the watchdog looks, in seconds.
        var pollInterval: TimeInterval = 1
    }

    /// Why the watchdog killed a child, in words for the debug log.
    enum KillReason: Equatable, Sendable {
        /// It ran longer than `seconds`.
        case tookTooLong(seconds: TimeInterval)
        /// Its resident memory passed `bytes`.
        case usedTooMuchMemory(bytes: Int64)
        /// Its output file did not grow for `seconds`.
        case madeNoProgress(seconds: TimeInterval)

        /// The reason as a phrase: "it ran longer than 62 seconds".
        var words: String {
            switch self {
            case let .tookTooLong(seconds):
                return "it ran longer than \(Int(seconds.rounded(.up))) seconds"
            case let .usedTooMuchMemory(bytes):
                return "it held more than \(bytes / 1_048_576) MB of memory"
            case let .madeNoProgress(seconds):
                return "its output did not grow for \(Int(seconds.rounded(.up))) seconds"
            }
        }
    }

    /// How a child ended.
    enum Outcome: Equatable, Sendable {
        /// It ended by itself with this exit status (0 is success).
        case exited(status: Int32)
        /// The watchdog killed it, for this reason.
        case killed(KillReason)
        /// It could not be started.
        case couldNotStart
    }

    /// The resident memory of the process `pid` in bytes, or nil when it
    /// cannot be read (it has just ended): one `proc_pidinfo` call.
    static func residentMemory(of pid: pid_t) -> Int64? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Int64(info.pti_resident_size)
    }

    /// The size of the file at `url` in bytes, 0 when it is not there yet.
    private static func size(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Runs `executable` with `arguments` and waits for it, off the main
    /// thread, under `limits`, watching the growth of the file `output`.
    /// - Parameters:
    ///   - residentMemory: How the watchdog reads a child's memory; tests
    ///     replace it.
    /// - Throws: `CancellationError` when the task is cancelled, which kills
    ///   the child.
    static func run(
        _ executable: URL,
        arguments: [String],
        watching output: URL,
        limits: Limits,
        residentMemory: @escaping @Sendable (pid_t) -> Int64? = WatchedProcess.residentMemory(of:)
    ) async throws -> Outcome {
        // The child's pid, shared with the cancellation handler.
        let running = OSAllocatedUnfairLock<pid_t?>(initialState: nil)
        let outcome: Outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: watch(
                        executable, arguments: arguments, output: output, limits: limits,
                        residentMemory: residentMemory, running: running
                    ))
                }
            }
        } onCancel: {
            if let pid = running.withLock({ $0 }) { kill(pid, SIGKILL) }
        }
        try Task.checkCancellation()
        return outcome
    }

    /// Starts the child and watches it until it ends or is killed; blocks
    /// its thread, so call it on a background queue.
    private static func watch(
        _ executable: URL,
        arguments: [String],
        output: URL,
        limits: Limits,
        residentMemory: @Sendable (pid_t) -> Int64?,
        running: OSAllocatedUnfairLock<pid_t?>
    ) -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Signalled as the child ends, so the loop below wakes at once.
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        do {
            try process.run()
        } catch {
            return .couldNotStart
        }
        let pid = process.processIdentifier
        running.withLock { $0 = pid }
        defer { running.withLock { $0 = nil } }

        let started = Date()
        var lastSize = size(of: output)
        var lastGrowth = started
        while ended.wait(timeout: .now() + limits.pollInterval) == .timedOut {
            let now = Date()
            let reason: KillReason?
            let currentSize = size(of: output)
            if currentSize > lastSize {
                lastSize = currentSize
                lastGrowth = now
            }
            if now.timeIntervalSince(started) > limits.maximumSeconds {
                reason = .tookTooLong(seconds: limits.maximumSeconds)
            } else if let memory = residentMemory(pid), memory > limits.maximumResidentBytes {
                reason = .usedTooMuchMemory(bytes: limits.maximumResidentBytes)
            } else if now.timeIntervalSince(lastGrowth) > limits.maximumStalledSeconds {
                reason = .madeNoProgress(seconds: limits.maximumStalledSeconds)
            } else {
                reason = nil
            }
            if let reason {
                kill(pid, SIGKILL)
                // SIGKILL cannot be caught; wait for the system to reap it.
                _ = ended.wait(timeout: .now() + 10)
                return .killed(reason)
            }
        }
        return .exited(status: process.terminationStatus)
    }
}
