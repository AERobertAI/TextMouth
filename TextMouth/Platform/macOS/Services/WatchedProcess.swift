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
/// the file it writes has not grown for too long, or that file has grown
/// past its cap. The child's standard
/// input, output, and errors are closed (the null device), so nothing it
/// prints can fill a pipe and stall it.
///
/// Four more guards keep a runaway child from outliving its watcher:
/// - the kernel itself ends the child (SIGXCPU) when it has used its CPU
///   allowance, `ulimit -t`, even if TextMouth is not watching any more;
/// - when the output has a cap, the kernel ends the child (SIGXFSZ) the
///   moment a write would pass it, `ulimit -f`: the watchdog looks once a
///   second, and a fast writer can put gigabytes on the disk between two
///   looks;
/// - a tiny reaper shell kills the child as soon as TextMouth's own process
///   is gone, however it went (quit, force-quit, or the memory guard's
///   `_exit`);
/// - `terminateAll()` kills every running child at once, for the app's
///   termination.
/// The watchdog's clock is the monotonic system uptime, so a sleep or a
/// change of the wall clock never ages a healthy child.
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
        /// The most processor time the child may use, in seconds, enforced by
        /// the kernel (`ulimit -t`). Nil means four times `maximumSeconds`:
        /// a few cores' work for the whole wall-clock allowance.
        var maximumCPUSeconds: TimeInterval?
        /// The most the watched file may grow to, in bytes. Nil means no cap.
        /// A child whose output passes it is killed (`wroteTooMuch`): a
        /// header that lies about a file's length can make a converter
        /// reserve and write gigabytes the disk does not have.
        var maximumOutputBytes: Int64?

        /// The CPU allowance in force: the explicit one, else four times
        /// `maximumSeconds`.
        var effectiveMaximumCPUSeconds: TimeInterval {
            maximumCPUSeconds ?? maximumSeconds * 4
        }
    }

    /// Why the watchdog killed a child, in words for the debug log.
    enum KillReason: Equatable, Sendable {
        /// It ran longer than `seconds`.
        case tookTooLong(seconds: TimeInterval)
        /// Its resident memory passed `bytes`.
        case usedTooMuchMemory(bytes: Int64)
        /// Its output file did not grow for `seconds`.
        case madeNoProgress(seconds: TimeInterval)
        /// The kernel ended it (SIGXCPU) after `seconds` of processor time.
        case usedTooMuchProcessorTime(seconds: TimeInterval)
        /// Its watched output file grew past `bytes`.
        case wroteTooMuch(bytes: Int64)

        /// The reason as a phrase: "it ran longer than 62 seconds" (counted with
        /// `CountWording`, so one second reads "1 second").
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

    // MARK: - Cancelling, and the children that are running

    /// The child's pid and whether its task was cancelled, under one lock, so
    /// that a cancellation and the child's start can meet in either order and
    /// the child is killed all the same: `cancel()` kills a published pid,
    /// and `publish(_:)` kills at once a pid published after the
    /// cancellation. The kill is injected so a test can drive both orders.
    final class ChildGate: Sendable {
        /// What the lock guards.
        private struct State {
            var pid: pid_t?
            var isCancelled = false
        }

        private let state = OSAllocatedUnfairLock(initialState: State())
        private let kill: @Sendable (pid_t) -> Void

        /// A gate that ends a child with `kill` (SIGKILL by default).
        init(kill: @escaping @Sendable (pid_t) -> Void = { _ = Darwin.kill($0, SIGKILL) }) {
            self.kill = kill
        }

        /// Whether the task has been cancelled.
        var isCancelled: Bool { state.withLock { $0.isCancelled } }

        /// The task was cancelled: remember it, and kill the child when it
        /// is already published. The kill runs inside the lock so it can
        /// never hit a pid that `clear()` has since released.
        func cancel() {
            state.withLock { state in
                state.isCancelled = true
                if let pid = state.pid { kill(pid) }
            }
        }

        /// The child has started as `pid`: publish it and read the flag in
        /// the same critical section, killing the child at once when the
        /// task was cancelled first. Returns whether it was cancelled.
        @discardableResult
        func publish(_ pid: pid_t) -> Bool {
            state.withLock { state in
                state.pid = pid
                if state.isCancelled { kill(pid) }
                return state.isCancelled
            }
        }

        /// The child has ended: a later cancellation must not signal its pid.
        func clear() {
            state.withLock { $0.pid = nil }
        }
    }

    /// Every child that is running, from the moment its pid is published
    /// until it ends, for `terminateAll()`. `Process` is not `Sendable`, so
    /// the lock is the unchecked kind; every access goes through it.
    private static let registry = OSAllocatedUnfairLock<[pid_t: Process]>(uncheckedState: [:])

    /// How many children are running now (for tests).
    static var runningChildCount: Int { registry.withLockUnchecked { $0.count } }

    /// How many children have been launched in this process (for tests).
    /// It only ever grows, so a test can tell that no child started at all,
    /// which `runningChildCount` cannot: a child started and killed at once
    /// leaves it as it was.
    static var launchCount: Int { launches.withLock { $0 } }

    /// Backs `launchCount`: each child is counted as it is registered. An
    /// `Int` is `Sendable`, so the lock is the checked kind.
    private static let launches = OSAllocatedUnfairLock(initialState: 0)

    /// Kills every running child with SIGKILL, checking first that it still
    /// runs. Callable from any thread; takes only a short lock and never
    /// waits for a child: the app's termination calls it.
    static func terminateAll() {
        registry.withLockUnchecked { children in
            for (pid, process) in children where process.isRunning {
                kill(pid, SIGKILL)
            }
        }
    }

    // MARK: - The reaper

    /// The reaper's script: `$1` is the pid whose death kills the tool, `$2`
    /// the tool's pid. It ends by itself when the tool has ended.
    private static let reaperScript = """
    while kill -0 "$2" 2>/dev/null; do
        if ! kill -0 "$1" 2>/dev/null; then
            kill -9 "$2" 2>/dev/null
            exit 0
        fi
        sleep 1
    done
    """

    /// Starts a shell that kills `child` as soon as `parent` is gone, so a
    /// runaway tool dies with TextMouth however TextMouth ends. It ends by
    /// itself when the child ends first. Nil when it could not start, which
    /// is not an error for the run it guards. `parent` is TextMouth's own
    /// pid except in tests.
    static func startReaper(watching child: pid_t, parent: pid_t = getpid()) -> Process? {
        let reaper = Process()
        reaper.executableURL = URL(fileURLWithPath: "/bin/sh")
        reaper.arguments = ["-c", reaperScript, "sh", String(parent), String(child)]
        reaper.standardInput = FileHandle.nullDevice
        reaper.standardOutput = FileHandle.nullDevice
        reaper.standardError = FileHandle.nullDevice
        do {
            try reaper.run()
        } catch {
            return nil
        }
        return reaper
    }

    // MARK: - Running

    /// Whether `url` is a file this process may execute (a directory is not).
    private static func canExecute(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// The whole seconds `ulimit -t` is given for `seconds` of processor
    /// time: rounded up, at least 1, and clamped so a huge limit cannot
    /// overflow.
    private static func cpuSecondsForShell(_ seconds: TimeInterval) -> Int {
        Int(min(max(seconds.rounded(.up), 1), 1_000_000_000))
    }

    /// What `ulimit -f` is given for an output cap of `bytes`: whole
    /// kilobytes (the unit of `/bin/sh`'s `ulimit -f`, measured: 3 stops a
    /// writer at 3,072 bytes), rounded up, at least 1; "unlimited" without a
    /// cap. A cap above a petabyte is given as a petabyte: the shell refuses
    /// a number whose bytes overflow, and the child could not start.
    static func fileSizeLimitForShell(_ bytes: Int64?) -> String {
        guard let requested = bytes else { return "unlimited" }
        let bytes = min(requested, 1 << 50)
        let kilobyte: Int64 = 1_024
        return String(max(1, bytes / kilobyte + (bytes % kilobyte > 0 ? 1 : 0)))
    }

    /// Runs `executable` with `arguments` and waits for it, off the main
    /// thread, under `limits`, watching the growth of the file `output`.
    /// - Parameters:
    ///   - residentMemory: How the watchdog reads a child's memory; tests
    ///     replace it.
    ///   - uptime: The watchdog's clock, in seconds, which must never run
    ///     backwards (the system uptime); tests replace it.
    /// - Throws: `CancellationError` when the task is cancelled, which kills
    ///   the child; a task already cancelled starts no child.
    static func run(
        _ executable: URL,
        arguments: [String],
        watching output: URL,
        limits: Limits,
        residentMemory: @escaping @Sendable (pid_t) -> Int64? = WatchedProcess.residentMemory(of:),
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) async throws -> Outcome {
        try await runWatched(
            executable, arguments: arguments, output: output, standardOutput: nil,
            outputIsProgress: true, limits: limits, residentMemory: residentMemory, uptime: uptime
        )
    }

    /// Runs `executable` as `run` does, and keeps what the child prints
    /// (FMT09): its standard output goes to a new hidden file,
    /// `.<UUID>.watched-output`, in the temporary directory, which the
    /// watchdog watches. The file is removed however the run ends: an exit, a
    /// kill, a failure to start, or a cancellation.
    ///
    /// Output is not progress here: a child that prints without end must
    /// still end at its time limit, and one that prints only when it ends
    /// (afinfo) must not be killed for being silent, so the stall clock runs
    /// from the child's start whatever it prints.
    /// - Parameters:
    ///   - maximumOutputBytes: How much of the output is returned, and the
    ///     most the file may grow to: a child that writes more is killed
    ///     (`wroteTooMuch`) and the bytes up to the cap are still returned.
    ///   - outputFolder: Where the hidden file is made: the temporary
    ///     directory, unless a test gives its own.
    /// - Returns: How the child ended, and the first `maximumOutputBytes`
    ///   bytes it printed (empty when it printed nothing or never started).
    /// - Throws: `CancellationError`, as `run` does.
    static func runCapturingOutput(
        _ executable: URL,
        arguments: [String],
        limits: Limits,
        maximumOutputBytes: Int = 1 << 20,
        outputFolder: URL = FileManager.default.temporaryDirectory,
        residentMemory: @escaping @Sendable (pid_t) -> Int64? = WatchedProcess.residentMemory(of:),
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) async throws -> (outcome: Outcome, output: Data) {
        let file = outputFolder.appendingPathComponent(".\(UUID().uuidString)\(outputFileSuffix)")
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file)
        else {
            // No place to put the output: the child is not started.
            try? FileManager.default.removeItem(at: file)
            return (.couldNotStart, Data())
        }
        // However the run ends, the file goes (the handle first closes).
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
        }
        // The file itself is capped at the number of bytes that come back.
        var cappedLimits = limits
        cappedLimits.maximumOutputBytes = min(limits.maximumOutputBytes ?? .max, Int64(maximumOutputBytes))
        let outcome = try await runWatched(
            executable, arguments: arguments, output: file, standardOutput: handle,
            outputIsProgress: false, limits: cappedLimits, residentMemory: residentMemory, uptime: uptime
        )
        return (outcome, firstBytes(of: file, upTo: maximumOutputBytes))
    }

    /// What every captured-output file's name ends with (the launch sweeps
    /// look for it).
    static let outputFileSuffix = ".watched-output"

    /// The first `count` bytes of the file at `url`; empty when it cannot be
    /// read.
    private static func firstBytes(of url: URL, upTo count: Int) -> Data {
        guard count > 0, let reader = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? reader.close() }
        return (try? reader.read(upToCount: count)) ?? Data()
    }

    /// The core of `run` and `runCapturingOutput`: starts the child on a
    /// background queue, under `limits`, with the cancellation handler.
    /// `standardOutput`, when given, takes the null device's place for the
    /// child's standard output. `outputIsProgress` says whether the watched
    /// file's growth resets the stall clock.
    private static func runWatched(
        _ executable: URL,
        arguments: [String],
        output: URL,
        standardOutput: FileHandle?,
        outputIsProgress: Bool,
        limits: Limits,
        residentMemory: @escaping @Sendable (pid_t) -> Int64?,
        uptime: @escaping @Sendable () -> TimeInterval
    ) async throws -> Outcome {
        try Task.checkCancellation()
        // The child's pid and the cancellation flag, shared with the handler.
        let gate = ChildGate()
        let outcome: Outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    continuation.resume(returning: watch(
                        executable, arguments: arguments, output: output,
                        standardOutput: standardOutput, outputIsProgress: outputIsProgress, limits: limits,
                        residentMemory: residentMemory, uptime: uptime, gate: gate
                    ))
                }
            }
        } onCancel: {
            gate.cancel()
        }
        try Task.checkCancellation()
        return outcome
    }

    /// Starts the child and watches it until it ends or is killed; blocks
    /// its thread, so call it on a background queue.
    ///
    /// The child is `/bin/sh` setting the CPU and file-size limits and then
    /// replacing itself with the tool (`exec`), so the pid seen, measured, and killed here is
    /// the tool's own.
    private static func watch(
        _ executable: URL,
        arguments: [String],
        output: URL,
        standardOutput: FileHandle?,
        outputIsProgress: Bool,
        limits: Limits,
        residentMemory: @Sendable (pid_t) -> Int64?,
        uptime: @Sendable () -> TimeInterval,
        gate: ChildGate
    ) -> Outcome {
        // A tool that cannot run, or a task cancelled already, starts nothing.
        guard canExecute(executable), !gate.isCancelled else { return .couldNotStart }
        let maximumCPU = limits.effectiveMaximumCPUSeconds
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "ulimit -t \"$1\" || exit 126; ulimit -f \"$2\" || exit 126; shift 2; exec \"$@\"", "sh",
            String(cpuSecondsForShell(maximumCPU)), fileSizeLimitForShell(limits.maximumOutputBytes),
            executable.path,
        ] + arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = standardOutput ?? FileHandle.nullDevice
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
        // Registered and published together: a cancellation that came first
        // kills the child now, one that comes later finds the pid. It is
        // counted as it is registered (`launchCount`).
        registry.withLockUnchecked { $0[pid] = process }
        launches.withLock { $0 += 1 }
        gate.publish(pid)
        // The reaper kills the child if TextMouth dies before this watch ends.
        let reaper = startReaper(watching: pid)
        defer {
            gate.clear()
            registry.withLockUnchecked { _ = $0.removeValue(forKey: pid) }
            // However the child ended, the reaper has nothing left to do.
            if let reaper, reaper.isRunning { reaper.terminate() } // quit-ok: ends a helper Process, not TextMouth
        }

        let started = uptime()
        var lastSize = size(of: output)
        var lastGrowth = started
        while ended.wait(timeout: .now() + limits.pollInterval) == .timedOut {
            let now = uptime()
            let reason: KillReason?
            let currentSize = size(of: output)
            if currentSize > lastSize {
                lastSize = currentSize
                // Output counts as progress only when the caller says so.
                if outputIsProgress { lastGrowth = now }
            }
            if now - started > limits.maximumSeconds {
                reason = .tookTooLong(seconds: limits.maximumSeconds)
            } else if let memory = residentMemory(pid), memory > limits.maximumResidentBytes {
                reason = .usedTooMuchMemory(bytes: limits.maximumResidentBytes)
            } else if let cap = limits.maximumOutputBytes, currentSize > cap {
                reason = .wroteTooMuch(bytes: cap)
            } else if now - lastGrowth > limits.maximumStalledSeconds {
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
        // The kernel's own limits ended it: say so rather than "exited".
        if process.terminationReason == .uncaughtSignal {
            if process.terminationStatus == SIGXCPU {
                return .killed(.usedTooMuchProcessorTime(seconds: maximumCPU))
            }
            if process.terminationStatus == SIGXFSZ, let cap = limits.maximumOutputBytes {
                return .killed(.wroteTooMuch(bytes: cap))
            }
        }
        return .exited(status: process.terminationStatus)
    }
}
