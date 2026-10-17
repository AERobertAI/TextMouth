import Darwin
import Foundation

/// One running process, as the sweep sees it: only the facts its rules need.
struct ProcessSnapshot: Equatable {
    /// The process id.
    let pid: pid_t
    /// The parent's process id; 1 (launchd) once the parent has quit.
    let parentPid: pid_t
    /// The user the process runs as.
    let userID: uid_t
    /// The path of the executable (from `proc_pidpath`).
    let path: String
    /// The command line, `argv[0]` first.
    let arguments: [String]
}

/// Kills the `afconvert` processes an earlier TextMouth left running (REV17a
/// finding 4).
///
/// TextMouth converts Ogg audio by running `/usr/bin/afconvert` as a child.
/// When TextMouth is force-quit, or leaves through the memory guard's
/// `_exit`, the child is reparented to launchd and keeps holding memory and
/// CPU until it ends or the Mac restarts. `WatchedProcess` makes new
/// children die with the app; this sweep, run at launch, deals with the ones
/// already left behind.
///
/// A process is swept only when it is all of: `/usr/bin/afconvert`, run by
/// the current user, an orphan (parent pid 1), and given a hidden temporary
/// output name of TextMouth's (last argument `.…` followed by
/// `OggAudioConverter.temporarySuffix`). A converter whose parent is alive,
/// or that belongs to another app or user, is never touched.
enum OrphanedConversionSweep {

    // MARK: The Rules

    /// The one program the sweep may kill.
    static let converterPath = "/usr/bin/afconvert"

    /// The parent pid of an orphan: launchd adopts a process whose parent
    /// has quit.
    static let launchdPid: pid_t = 1

    /// Whether `argument` names one of TextMouth's hidden temporary
    /// conversion outputs: a path whose last component starts with "." and
    /// ends with the temporary suffix, with something before the suffix.
    static func isTemporaryOutputName(_ argument: String) -> Bool {
        let name = (argument as NSString).lastPathComponent
        let suffix = OggAudioConverter.temporarySuffix
        // The suffix itself starts with ".", so a name equal to it would
        // pass the first two tests with nothing in front.
        return name.hasPrefix(".") && name.hasSuffix(suffix) && name.count > suffix.count
    }

    /// Whether the sweep must kill `process`: every rule in the type's
    /// description holds.
    static func shouldKill(_ process: ProcessSnapshot, currentUser: uid_t = geteuid()) -> Bool {
        guard process.path == converterPath,
              process.userID == currentUser,
              process.parentPid == launchdPid,
              let output = process.arguments.last else { return false }
        return isTemporaryOutputName(output)
    }

    /// Kills, with SIGKILL, each process of `processes` that `shouldKill`
    /// accepts, and returns their pids.
    /// - Parameters:
    ///   - processes: The running processes.
    ///   - kill: What ends a process, given the pid and the signal. The real
    ///     `Darwin.kill` by default.
    /// - Returns: The pids it killed, in the order of `processes`.
    @discardableResult
    static func sweep(
        processes: [ProcessSnapshot],
        kill: (pid_t, Int32) -> Void = { _ = Darwin.kill($0, $1) }
    ) -> [pid_t] {
        let doomed = processes.filter { shouldKill($0) }.map(\.pid)
        for pid in doomed { kill(pid, SIGKILL) }
        return doomed
    }

    /// The log line for a sweep that killed `count` processes.
    static func logLine(killedCount count: Int) -> String {
        "OGG_ORPHAN_SWEPT: killed \(count) leftover afconvert process(es)"
    }

    // MARK: At Launch

    /// Runs the sweep once, off the main thread at utility priority, and
    /// logs one line when anything was killed. It does nothing in hosted
    /// tests.
    /// - Parameters:
    ///   - isHostedTest: Whether this is a hosted test run.
    ///   - lister: Lists the running processes.
    ///   - kill: Ends a process.
    ///   - completion: Called on the background queue when the sweep has
    ///     finished (tests wait on it); not called when nothing is run.
    static func sweepInBackground(
        isHostedTest: Bool = TextMouthRuntime.current.isHostedTest,
        lister: @escaping @Sendable () -> [ProcessSnapshot] = { runningProcesses() },
        kill: @escaping @Sendable (pid_t, Int32) -> Void = { _ = Darwin.kill($0, $1) },
        completion: (@Sendable () -> Void)? = nil
    ) {
        guard !isHostedTest else { return }
        DispatchQueue.global(qos: .utility).async {
            let killed = sweep(processes: lister(), kill: kill)
            if !killed.isEmpty {
                DiagnosticLog.event(.storage, logLine(killedCount: killed.count))
            }
            completion?()
        }
    }

    // MARK: Listing Processes

    /// Every process the current user may inspect, through libproc. A process
    /// that ends mid-listing, or that cannot be inspected, is left out.
    static func runningProcesses() -> [ProcessSnapshot] {
        // The count can grow before the second call, so ask for room to spare.
        let expected = proc_listallpids(nil, 0)
        guard expected > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(expected) + 64)
        let capacity = Int32(pids.count * MemoryLayout<pid_t>.stride)
        // The call returns the number of pids it wrote (despite the name of
        // its size argument, which is in bytes).
        let written = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, capacity)
        }
        guard written > 0 else { return [] }
        return pids.prefix(Int(written)).filter { $0 > 0 }.compactMap(snapshot(of:))
    }

    /// The snapshot of `pid`, or nil when it has gone or cannot be read.
    static func snapshot(of pid: pid_t) -> ProcessSnapshot? {
        guard let path = executablePath(of: pid),
              let (parent, user) = parentAndUser(of: pid),
              let arguments = arguments(of: pid) else { return nil }
        return ProcessSnapshot(pid: pid, parentPid: parent, userID: user, path: path, arguments: arguments)
    }

    /// The executable's path from `proc_pidpath`, or nil on failure.
    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        // `length` is the number of bytes written, without the NUL.
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// The parent pid and user id from `PROC_PIDTBSDINFO`, or nil on failure.
    private static func parentAndUser(of pid: pid_t) -> (pid_t, uid_t)? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        // A short result means the process vanished or the call was refused.
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return (pid_t(info.pbi_ppid), uid_t(info.pbi_uid))
    }

    /// The command line from `sysctl(KERN_PROCARGS2)`, or nil on failure.
    private static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0, size > 0,
              size <= buffer.count else { return nil }
        return parseProcessArguments(Array(buffer.prefix(size)))
    }

    /// Parses a `KERN_PROCARGS2` buffer: an Int32 argc, the executable path
    /// and its NUL padding, then argc NUL-terminated strings (the
    /// environment follows and is ignored). Returns nil for a buffer that is
    /// short, has a negative or impossible argc, or ends inside the strings.
    static func parseProcessArguments(_ buffer: [UInt8]) -> [String]? {
        let header = MemoryLayout<Int32>.size
        guard buffer.count >= header else { return nil }
        // Assemble argc byte by byte (little-endian): the buffer has no
        // alignment guarantee, so it is not read through a typed pointer.
        var raw: UInt32 = 0
        for offset in 0..<header { raw |= UInt32(buffer[offset]) << UInt32(8 * offset) }
        let argc = Int32(bitPattern: raw)
        // Every argument takes at least its NUL, so argc can never exceed
        // the buffer's length.
        guard argc >= 0, Int(argc) <= buffer.count else { return nil }
        var index = header
        // Skip the executable path, then the NULs that pad it.
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var result: [String] = []
        for _ in 0..<Int(argc) {
            guard index < buffer.count else { return nil }
            // An argument runs to its NUL; a missing NUL means a cut buffer.
            guard let end = buffer[index...].firstIndex(of: 0) else { return nil }
            result.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return result
    }
}
