import Foundation
import os
private import TextMouthFFmpegProtocol
private import TextMouthFFmpegSession

// FMT54: FFmpeg's session inside the iPhone app.
//
// The Mac runs TextMouth's FFmpeg session in a helper program under its
// watchdog. iOS lets an app start no program, so the iPhone links the same
// session (the FFmpeg_iOS library) and runs it here, on an engine of its own
// (`InProcessEngine`): one call at a time on a thread with the helper's 8 MB
// stack, each call within a time limit and above a floor of free memory that
// the session's stop check carries into every read of the file and every
// step (`SessionStopCheck`), and a call that runs past its limit abandoned. The stream is pulled one record a call into the reader both
// platforms share (`FFmpegHelperStream`), so every bound of it stays in one
// place, and a run ends as the helper's would, so every sentence is the Mac's.
// `FFmpegAudioConverter.runSession` is the one caller.

// MARK: - The Session in the App

/// Opens a session of the stream in the app, on the engine's thread, as an
/// in-process run asks (FMT54): the file, the demuxer its bytes name
/// (`FFmpegContainer.demuxer`), the mode, and the stop check of the engine's
/// call it runs in, which the open asks. It gives the session, or none with
/// the TMFF_EXIT_ status that says why (TMFF_EXIT_UNREADABLE for a file that
/// is not a regular one).
typealias InProcessSessionOpener = @Sendable (
    _ file: URL, _ demuxer: String, _ mode: FFmpegAudioConverter.SessionMode, _ check: SessionStopCheck
) -> (session: (any InProcessFFmpegSession)?, status: Int32)

/// One open session of the stream in the app (FMT54), which an in-process run
/// calls on the engine's thread, one call at a time: its next record, and its
/// end. TextMouth's FFmpeg session linked into the app is one
/// (`LinkedFFmpegSession`); a test stands in another.
protocol InProcessFFmpegSession: AnyObject, Sendable {
    /// The next record of the stream, header and payload, made while the
    /// engine's call of `check` runs, asking `check`: TMFF_EXIT_DONE with the
    /// record, TMFF_EXIT_DONE with none once END has been given, or another
    /// TMFF_EXIT_ status with none, after which the stream is over
    /// (TMFF_EXIT_STOPPED once the check has said stop).
    func next(asking check: SessionStopCheck) -> (status: Int32, record: [UInt8])

    /// Frees the session and what it holds; asked once, after its last record.
    func close()
}

// MARK: - The Session's Stop Check

/// A floor under the memory the app has left while an FFmpeg session runs in
/// it (the FMT54 review, finding 4), the iPhone's counterpart of the Mac
/// helper's watch on its memory. FFmpeg builds a file's tags, chapters,
/// attachments, and index in many small allocations while it reads the
/// header, which no single allocation's cap holds, and on the iPhone iOS ends
/// TextMouth itself past its memory limit, which the listener would meet as a
/// crash, mid-book.
struct SessionMemoryFloor: Sendable {
    /// The most memory the app keeps free while a session runs, in bytes:
    /// the app's, 512 MB, twice the most FFmpeg may allocate at once
    /// (`av_max_alloc`, 256 MB), so that no allocation between two asks can
    /// take the app from above the floor to its limit, and room for the rest
    /// of TextMouth to say what happened. A sound file's session needs tens
    /// of megabytes, so only a session that grows far past what any file
    /// means to hold reaches it. A run that begins with less than twice it
    /// free keeps half of what it began with (`run(beganWith:)`).
    let bytes: Int
    /// The memory the app has left before iOS ends it, in bytes:
    /// `os_proc_available_memory()`, unless a test scripts its own. Its 0
    /// means two things (`zeroMeansNoLimit`).
    let available: @Sendable () -> Int
    /// Whether `available`'s 0 means the system sets the app no limit, as it
    /// does in the simulator alone; on an iPhone, 0 means the app is over its
    /// limit already, which must stop a session at once (the check of the
    /// FMT54 review's fixes, item 3).
    var zeroMeansNoLimit = SessionMemoryFloor.onSimulator

    /// The app's floor.
    static let app = SessionMemoryFloor(bytes: 512 * 1_048_576, available: { os_proc_available_memory() })

    /// Whether this is the iOS simulator, where the system sets an app no
    /// memory limit.
    static let onSimulator: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }()

    /// The memory the app has left now, 0 when it is over its limit, and nil
    /// when the system sets it no limit, which no floor can be under.
    var left: Int? {
        let left = available()
        if left > 0 { return left }
        return zeroMeansNoLimit ? nil : 0
    }

    /// What one run keeps, as it begins with `leftAtStart` bytes left (nil:
    /// no limit): its floor, `bytes` or half of what was left if that is less,
    /// so that a phone that begins short of memory still converts an ordinary
    /// file; and the most FFmpeg may allocate at once in its calls, half its
    /// floor and never more than 256 MB, which keeps the floor's promise that
    /// no allocation between two asks crosses from above it to the limit (the
    /// check of the FMT54 review's fixes, item 2).
    func run(beganWith leftAtStart: Int?) -> RunMemory {
        let largest = Int(TMFF_MAX_ALLOCATION_BYTES)
        guard let leftAtStart else {
            return RunMemory(reader: self, floor: bytes, allocationCap: largest, leftAtStart: nil)
        }
        let floor = min(bytes, leftAtStart / 2)
        return RunMemory(reader: self, floor: floor, allocationCap: min(largest, floor / 2), leftAtStart: leftAtStart)
    }
}

/// What one FFmpeg run in the app keeps of the memory it began with
/// (`SessionMemoryFloor.run(beganWith:)`).
struct RunMemory: Sendable, Equatable {
    /// What reads the memory the app has left.
    let reader: SessionMemoryFloor
    /// The least memory the app may have left while the run goes on, in
    /// bytes.
    let floor: Int
    /// The most FFmpeg may allocate at once in the run's calls, in bytes.
    let allocationCap: Int
    /// The memory the app had left as the run began, nil with no limit.
    let leftAtStart: Int?

    /// Whether the run began short of memory: its floor is below the app's,
    /// half of what it began with.
    var beganShort: Bool { floor < reader.bytes }

    /// The memory the app has left now when that is under the run's floor,
    /// or none (over its limit, even in a run that began so): the app is
    /// then too near its limit to go on. Nil when it has enough, and when
    /// the system sets it no limit. The one test of the floor, for an FFmpeg
    /// session's stop check and for TextMouth's own readers' conversions.
    func leftWhenCrossed() -> Int? {
        guard let left = reader.left, left == 0 || left < floor else { return nil }
        return left
    }

    /// Why the run stopped with `left` bytes of memory left (what
    /// `leftWhenCrossed()` gave): a run that began short of memory says that
    /// it did, with what it began with; any other, what the app's memory
    /// grew by since it began (at least 1 MB).
    func stopReason(whenLeft left: Int) -> WatchedProcess.KillReason {
        let leftAtStart = leftAtStart ?? left
        return beganShort
            ? .beganShortOfMemory(freeBytes: Int64(leftAtStart))
            : .memoryGrew(bytes: Int64(max(leftAtStart - left, 1_048_576)))
    }

    static func == (lhs: RunMemory, rhs: RunMemory) -> Bool {
        lhs.floor == rhs.floor && lhs.allocationCap == rhs.allocationCap && lhs.leftAtStart == rhs.leftAtStart
            && lhs.reader.bytes == rhs.reader.bytes
    }
}

/// The stop check one engine call gives its FFmpeg session in the app
/// (FMT54), as `tmff_stop_check` with this as its context: stop once the
/// engine says the call's time is spent or its import is cancelled
/// (`InProcessEngine.Call.shouldStop`), or once the app has less memory left
/// than its run's floor. The session asks it before every read and seek of
/// its file and at each of its steps, and FFmpeg at its own checkpoints, so
/// the floor is watched as closely as the time. It carries its run's
/// allocation cap too, which the linked session gives FFmpeg before each
/// call.
///
/// It lives in its call's work, on the engine's thread, and the session
/// asks it there alone, so it is not Sendable: the work hands back what it
/// found (`memoryLeftWhenStopped`).
final class SessionStopCheck {
    /// The engine's call it is asked in.
    let call: InProcessEngine.Call
    /// What its run keeps of the app's memory.
    let memory: RunMemory
    /// The memory the app had left when the floor said stop, in bytes; nil
    /// unless it did.
    private(set) var memoryLeftWhenStopped: Int?

    /// The check of `call`, keeping `memory`.
    init(call: InProcessEngine.Call, memory: RunMemory) {
        self.call = call
        self.memory = memory
    }

    /// Whether the session should stop now: its call should, or the app has
    /// less memory left than its run's floor, or none (over its limit, even
    /// in a run that began so), which stops it for good.
    var shouldStop: Bool {
        if memoryLeftWhenStopped != nil || call.shouldStop { return true }
        guard let left = memory.leftWhenCrossed() else { return false }
        memoryLeftWhenStopped = left
        return true
    }

    /// This check as the context `function` is given, valid while the call's
    /// work holds it.
    var context: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    /// `shouldStop` as the session's C check: 1 to stop and 0 to go on, for
    /// the check whose `context` it is given, and 0 for none.
    static var function: @convention(c) (UnsafeMutableRawPointer?) -> Int32 {
        { context in
            guard let context else { return 0 }
            return Unmanaged<SessionStopCheck>.fromOpaque(context).takeUnretainedValue().shouldStop ? 1 : 0
        }
    }
}

// MARK: - The Linked Session

/// TextMouth's FFmpeg session linked into the app (TextMouthFFmpegSession.h),
/// one open file of it (FMT54).
///
/// `@unchecked Sendable`: its session pointer and descriptor are used only
/// on the FFmpeg engine's one thread (`FFmpegAudioConverter.sessionEngine`, or
/// a test's engine), one call at a time, from the open that makes it to the
/// close that frees it; the engine's lock orders each call after the one
/// before, and nothing else ever holds them.
final class LinkedFFmpegSession: InProcessFFmpegSession, @unchecked Sendable {
    /// The session, `tmff_session *`.
    private let session: OpaquePointer
    /// The file's descriptor, which the session reads and `close()` closes.
    private let descriptor: Int32
    /// Whether `close()` has freed the session.
    private var isClosed = false

    private init(session: OpaquePointer, descriptor: Int32) {
        self.session = session
        self.descriptor = descriptor
    }

    /// Opens the file at `file` as the Mac's helper opens its own
    /// (`tmff_open_regular_file`: a regular file only, never a FIFO waited
    /// on), then the session on it with the demuxer `demuxer` in `mode`,
    /// asking `check` while FFmpeg reads the file's header and finds its
    /// streams. An `InProcessSessionOpener`.
    static func open(
        _ file: URL,
        demuxer: String,
        mode: FFmpegAudioConverter.SessionMode,
        check: SessionStopCheck
    ) -> (session: (any InProcessFFmpegSession)?, status: Int32) {
        let descriptor = file.withUnsafeFileSystemRepresentation { path in path.map { tmff_open_regular_file($0) } ?? -1 }
        guard descriptor >= 0 else { return (nil, TMFF_EXIT_UNREADABLE) }
        tmff_set_allocation_cap(check.memory.allocationCap)
        var status = TMFF_EXIT_DONE
        let opened = demuxer.withCString { name in
            tmff_session_open_checked(
                descriptor, name, mode == .decode ? TMFF_SESSION_DECODE : TMFF_SESSION_PROBE,
                SessionStopCheck.function, check.context, &status
            )
        }
        guard let opened else {
            Darwin.close(descriptor)
            return (nil, status)
        }
        // The open's check is this call's, whose context ends with it: each later call sets its own.
        tmff_session_set_stop_check(opened, nil, nil)
        return (LinkedFFmpegSession(session: opened, descriptor: descriptor), TMFF_EXIT_DONE)
    }

    /// The session's next record, made while `check`'s call runs, the check
    /// set for this call alone and taken off before it returns, since its
    /// context ends with the call; the record is copied out of the session,
    /// which reuses its buffer at the next call.
    func next(asking check: SessionStopCheck) -> (status: Int32, record: [UInt8]) {
        guard !isClosed else { return (TMFF_EXIT_USAGE, []) }
        tmff_set_allocation_cap(check.memory.allocationCap)
        tmff_session_set_stop_check(session, SessionStopCheck.function, check.context)
        defer { tmff_session_set_stop_check(session, nil, nil) }
        var bytes: UnsafePointer<UInt8>?
        var length = 0
        let status = tmff_session_next(session, &bytes, &length)
        guard status == TMFF_EXIT_DONE, let bytes, length > 0 else { return (status, []) }
        return (status, Array(UnsafeBufferPointer(start: bytes, count: length)))
    }

    /// Frees the session and everything FFmpeg holds for it, then closes the
    /// file; a second call does nothing.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        tmff_session_close(session)
        Darwin.close(descriptor)
    }
}

// MARK: - The Run

extension FFmpegAudioConverter {
    /// The engine the iPhone's FFmpeg sessions run on (FMT54): TextMouth's
    /// session around FFmpeg, linked into the app, one call at a time on a
    /// thread of its own, since iOS lets an app start no helper program. A
    /// call past its time is abandoned, and every later conversion is refused
    /// until TextMouth is closed and opened again, in the engine's sentences
    /// (`InProcessEngineWording`, with `FFmpegImportWording.inAppWork`):
    /// "TextMouth stopped the audio conversion because it ran longer than 62
    /// seconds, and won't try again until TextMouth is closed and opened
    /// again."
    static let sessionEngine = InProcessEngine(name: "FFmpeg", work: FFmpegImportWording.inAppWork)

    /// Runs the session on `file`, read with the demuxer named `demuxer`
    /// (`FFmpegContainer.demuxer`), in `mode`, in this process on the tool's
    /// engine (FMT54), handing `read` its stream one record a piece, and
    /// returns how the run ended as the Mac's helper's run would
    /// (`WatchedProcess.runStreaming`), with what `read` returned or threw:
    /// - **The stream.** The first piece opens the session, and each piece
    ///   after it is the session's next record, so `FFmpegHelperStream`
    ///   checks every record as it checks the helper's.
    /// - **The time.** The run's whole time is `limits.maximumSeconds`, from
    ///   its start, over every call and the reader's own work between them,
    ///   as the watchdog counts it, but by the tool's clock, which counts only
    ///   the time TextMouth runs (B18), held for the run so its heartbeat
    ///   counts that time whole; each call may take at most
    ///   `limits.maximumStalledSeconds`, since no record for that long is a
    ///   stall, and no more than the run has left. A call past its limit is
    ///   told to stop through the session's stop check, and the run ends in
    ///   the watchdog's kill for the same reason; a call still running its
    ///   grace later is abandoned by the engine, whose failure `read` throws.
    /// - **The task's cancellation** stops the call in progress through the
    ///   same check, and the run ends in `CancellationError`, as on the Mac.
    /// - **The memory.** The helper's memory watch is, in one process, a floor
    ///   under the memory the app has left (`tool.memoryFloor`, the FMT54
    ///   review's finding 4): the session's check says stop once less is left,
    ///   and the run ends in a kill for memory: the app's memory grew by more
    ///   than so much since the run began, or, for a run that began short of
    ///   memory, which keeps half of what it began with, that it did. FFmpeg's
    ///   allocations are held to 256 MB each (`av_max_alloc`), less in a run
    ///   that began short, a decoded frame to 16,777,216 samples, and the
    ///   records to the protocol's sizes.
    /// - **The end.** Once `read` is done the session is freed, in a call of
    ///   its own; an engine that refuses (a call was abandoned) leaves it to
    ///   the thread that still holds it.
    ///
    /// The processor time is held by the time limit, which one thread cannot
    /// pass.
    /// - Throws: `CancellationError` when the task is cancelled, after the
    ///   session is freed.
    static func runInProcess<Value: Sendable>(
        _ mode: SessionMode,
        of file: URL,
        demuxer: String,
        limits: WatchedProcess.Limits,
        using tool: Tool,
        reading read: (_ nextPiece: @escaping () async throws -> [UInt8]) async throws -> Value
    ) async throws -> (ending: WatchedProcess.Ending, read: Result<Value, any Error>) {
        try Task.checkCancellation()
        tool.clock.hold()
        defer { tool.clock.release() }
        let run = InProcessFFmpegRun(file: file, demuxer: demuxer, mode: mode, limits: limits, tool: tool)
        let result: Result<Value, any Error>
        do {
            result = .success(try await read { try await run.nextPiece() })
        } catch {
            result = .failure(error)
        }
        await run.close()
        let ending = await run.ending
        try Task.checkCancellation()
        return (ending, result)
    }
}

/// One run of the session in the app (FMT54), as its reader asks for the
/// stream: the session opened on the engine at the first piece, one record
/// for each piece after it, and how the run ended, which
/// `FFmpegAudioConverter.runInProcess` hands back as the helper's ending.
/// Its reader asks for one piece at a time, awaiting each before the next
/// (`FFmpegHelperStream`), and the actor keeps the run's state whole across
/// the threads its awaits resume on.
private actor InProcessFFmpegRun {
    let file: URL
    let demuxer: String
    let mode: FFmpegAudioConverter.SessionMode
    let limits: WatchedProcess.Limits
    let tool: FFmpegAudioConverter.Tool
    /// When the run began, by the tool's clock: its whole time counts from
    /// here, as the watchdog's counts from the helper's start.
    private let started: TimeInterval
    /// What the run keeps of the memory the app had left as it began: its
    /// floor and its allocation cap, and what a stop for memory measures the
    /// app's growth from.
    private let memory: RunMemory
    /// Whether the open has been asked for; it is asked once.
    private var openAsked = false
    /// The open session, until it is freed.
    private var session: (any InProcessFFmpegSession)?
    /// The status the stream ended with, once it has: TMFF_EXIT_DONE after
    /// END, or the status of a failed open or record.
    private var status: Int32?
    /// The watchdog's reason the run was stopped for, when a limit ended it.
    private var stopped: WatchedProcess.KillReason?

    init(file: URL, demuxer: String, mode: FFmpegAudioConverter.SessionMode, limits: WatchedProcess.Limits, tool: FFmpegAudioConverter.Tool) {
        self.file = file
        self.demuxer = demuxer
        self.mode = mode
        self.limits = limits
        self.tool = tool
        started = tool.clock.now()
        memory = tool.memoryFloor.run(beganWith: tool.memoryFloor.left)
    }

    /// How the run ended, as the helper's run says it: the watchdog's kill
    /// for a limit, else the exit status, which is the stream's status
    /// (TMFF_EXIT_DONE for a reader that stopped before the stream's end, as
    /// a helper killed for its reader's failure reports nothing more).
    var ending: WatchedProcess.Ending {
        if let stopped { return WatchedProcess.Ending(outcome: .killed(stopped)) }
        return WatchedProcess.Ending(outcome: .exited(status: status ?? TMFF_EXIT_DONE))
    }

    /// The next piece of the stream: one record, or nothing at the stream's
    /// end, at a limit, or after a status other than done.
    /// - Throws: the engine's failure for a call abandoned past its time, or
    ///   refused after one was (`InProcessEngine.Failure`).
    func nextPiece() async throws -> [UInt8] {
        guard status == nil, stopped == nil else { return [] }
        guard let callLimit = timeForTheNextCall() else { return [] }
        if !openAsked {
            openAsked = true
            let (file, demuxer, mode, open, memory) = (file, demuxer, mode, tool.openSession, memory)
            let opening = try await engineCall(within: callLimit) { call in
                let check = SessionStopCheck(call: call, memory: memory)
                let (session, status) = open(file, demuxer, mode, check)
                return (session: session, status: status, memoryLeft: check.memoryLeftWhenStopped)
            }
            guard let opened = opening.session else {
                end(with: opening.status, memoryLeft: opening.memoryLeft)
                return []
            }
            session = opened
            guard let nextLimit = timeForTheNextCall() else { return [] }
            return try await record(from: opened, within: nextLimit)
        }
        guard let session else { return [] }
        return try await record(from: session, within: callLimit)
    }

    /// The next record of `session`, in a call within `limit`; nothing once
    /// the stream has ended.
    private func record(from session: any InProcessFFmpegSession, within limit: CallLimit) async throws -> [UInt8] {
        let memory = memory
        let (status, record, memoryLeft) = try await engineCall(within: limit) { call in
            let check = SessionStopCheck(call: call, memory: memory)
            let (status, record) = session.next(asking: check)
            return (status, record, check.memoryLeftWhenStopped)
        }
        guard status == TMFF_EXIT_DONE else {
            end(with: status, memoryLeft: memoryLeft)
            return []
        }
        // No record after END: the stream is whole.
        if record.isEmpty { self.status = TMFF_EXIT_DONE }
        return record
    }

    /// How long one call may take, and the limit a call abandoned past it is
    /// told by (the FMT54 review, finding 5).
    private struct CallLimit {
        /// The call's own time, in seconds: the stall limit, and no more than
        /// the run has left.
        let seconds: TimeInterval
        /// What an abandoned call's sentence names: the stall limit, or the
        /// run's whole time when what was left of it cut the call, so a long
        /// conversion stuck in its last call never ran "longer than 3
        /// seconds".
        let named: TimeInterval
    }

    /// How long the next call may take (`CallLimit`); nil, with the run
    /// stopped as the watchdog stops a helper that ran too long, once the
    /// run's time is spent.
    private func timeForTheNextCall() -> CallLimit? {
        let elapsed = tool.clock.now() - started
        guard elapsed < limits.maximumSeconds else {
            stopped = .tookTooLong(seconds: limits.maximumSeconds)
            return nil
        }
        let left = limits.maximumSeconds - elapsed
        return left < limits.maximumStalledSeconds
            ? CallLimit(seconds: left, named: limits.maximumSeconds)
            : CallLimit(seconds: limits.maximumStalledSeconds, named: limits.maximumStalledSeconds)
    }

    /// Runs `body` on the tool's engine within `limit`; a call abandoned past
    /// it fails with the engine's sentence, naming `limit.named`.
    private func engineCall<Value: Sendable>(
        within limit: CallLimit,
        _ body: @escaping @Sendable (InProcessEngine.Call) -> Value
    ) async throws -> Value {
        do {
            return try await tool.engine.runForTask(limit: limit.seconds, body)
        } catch InProcessEngine.Failure.abandoned(let work, _) {
            throw InProcessEngine.Failure.abandoned(work: work, limit: limit.named)
        }
    }

    /// Ends the stream with `status`. A stop the memory floor asked for, the
    /// app having `memoryLeft` bytes left, is a kill for memory: for a run
    /// that began short of memory, that it did, with what it began with; for
    /// any other, what the app's memory grew by since the run began (at least
    /// 1 MB), other conversions of the import counted with it. Any other stop
    /// the task's cancellation did not ask for (TMFF_EXIT_STOPPED) was a time
    /// limit's: the run's whole time when it is spent, else the call's, the
    /// stall.
    private func end(with status: Int32, memoryLeft: Int? = nil) {
        self.status = status
        if let memoryLeft {
            stopped = memory.stopReason(whenLeft: memoryLeft)
            return
        }
        guard status == TMFF_EXIT_STOPPED, !Task.isCancelled else { return }
        stopped = tool.clock.now() - started >= limits.maximumSeconds
            ? .tookTooLong(seconds: limits.maximumSeconds)
            : .madeNoProgress(seconds: limits.maximumStalledSeconds)
    }

    /// Frees the session, if one was opened, in an engine call of the stall
    /// limit's time: freeing asks no check and returns at once. An engine
    /// that refuses, after a call was abandoned, leaves the session to the
    /// thread that still holds it.
    func close() async {
        guard let session else { return }
        self.session = nil
        _ = try? await tool.engine.runForTask(limit: limits.maximumStalledSeconds) { _ in session.close() }
    }
}
