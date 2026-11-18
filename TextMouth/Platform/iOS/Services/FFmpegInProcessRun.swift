import Foundation
private import TextMouthFFmpegProtocol
private import TextMouthFFmpegSession

// FMT54: FFmpeg's session inside the iPhone app.
//
// The Mac runs TextMouth's FFmpeg session in a helper program under its
// watchdog. iOS lets an app start no program, so the iPhone links the same
// session (the FFmpeg_iOS library) and runs it here, on an engine of its own
// (`InProcessEngine`): one call at a time on a thread with the helper's 8 MB
// stack, each call within a time limit that the session's stop check carries
// into FFmpeg's interrupt callback, and a call that runs past its limit
// abandoned. The stream is pulled one record a call into the reader both
// platforms share (`FFmpegHelperStream`), so every bound of it stays in one
// place, and a run ends as the helper's would, so every sentence is the Mac's.
// `FFmpegAudioConverter.runSession` is the one caller.

// MARK: - The Session in the App

/// Opens a session of the stream in the app, on the engine's thread, as an
/// in-process run asks (FMT54): the file, the demuxer its bytes name
/// (`FFmpegContainer.demuxer`), the mode, and the engine's call it runs in,
/// whose stop check the open asks. It gives the session, or none with the
/// TMFF_EXIT_ status that says why (TMFF_EXIT_UNREADABLE for a file that is
/// not a regular one).
typealias InProcessSessionOpener = @Sendable (
    _ file: URL, _ demuxer: String, _ mode: FFmpegAudioConverter.SessionMode, _ call: InProcessEngine.Call
) -> (session: (any InProcessFFmpegSession)?, status: Int32)

/// One open session of the stream in the app (FMT54), which an in-process run
/// calls on the engine's thread, one call at a time: its next record, and its
/// end. TextMouth's FFmpeg session linked into the app is one
/// (`LinkedFFmpegSession`); a test stands in another.
protocol InProcessFFmpegSession: AnyObject, Sendable {
    /// The next record of the stream, header and payload, made while `call`
    /// runs and asking its stop check: TMFF_EXIT_DONE with the record,
    /// TMFF_EXIT_DONE with none once END has been given, or another
    /// TMFF_EXIT_ status with none, after which the stream is over
    /// (TMFF_EXIT_STOPPED once the check has said stop).
    func next(asking call: InProcessEngine.Call) -> (status: Int32, record: [UInt8])

    /// Frees the session and what it holds; asked once, after its last record.
    func close()
}

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
    /// asking `call`'s stop check while FFmpeg reads the file's header and
    /// finds its streams. An `InProcessSessionOpener`.
    static func open(
        _ file: URL,
        demuxer: String,
        mode: FFmpegAudioConverter.SessionMode,
        call: InProcessEngine.Call
    ) -> (session: (any InProcessFFmpegSession)?, status: Int32) {
        let descriptor = file.withUnsafeFileSystemRepresentation { path in path.map { tmff_open_regular_file($0) } ?? -1 }
        guard descriptor >= 0 else { return (nil, TMFF_EXIT_UNREADABLE) }
        var status = TMFF_EXIT_DONE
        let opened = demuxer.withCString { name in
            tmff_session_open_checked(
                descriptor, name, mode == .decode ? TMFF_SESSION_DECODE : TMFF_SESSION_PROBE,
                InProcessEngine.Call.stopCheck, call.context, &status
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

    /// The session's next record, made while `call` runs, its stop check
    /// set for this call alone and taken off before it returns, since the
    /// call's context ends with it; the record is copied out of the session,
    /// which reuses its buffer at the next call.
    func next(asking call: InProcessEngine.Call) -> (status: Int32, record: [UInt8]) {
        guard !isClosed else { return (TMFF_EXIT_USAGE, []) }
        tmff_session_set_stop_check(session, InProcessEngine.Call.stopCheck, call.context)
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
    /// - **The end.** Once `read` is done the session is freed, in a call of
    ///   its own; an engine that refuses (a call was abandoned) leaves it to
    ///   the thread that still holds it.
    ///
    /// The memory limit has no counterpart in one process: FFmpeg's
    /// allocations are held to 256 MB each (`av_max_alloc`), the records to
    /// the protocol's sizes, and the processor time to the time limit, which
    /// one thread cannot pass.
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
            let (file, demuxer, mode, open) = (file, demuxer, mode, tool.openSession)
            let opening = try await tool.engine.runForTask(limit: callLimit) { call in open(file, demuxer, mode, call) }
            guard let opened = opening.session else {
                end(with: opening.status)
                return []
            }
            session = opened
            guard let nextLimit = timeForTheNextCall() else { return [] }
            return try await record(from: opened, within: nextLimit)
        }
        guard let session else { return [] }
        return try await record(from: session, within: callLimit)
    }

    /// The next record of `session`, in a call of `limit` seconds; nothing
    /// once the stream has ended.
    private func record(from session: any InProcessFFmpegSession, within limit: TimeInterval) async throws -> [UInt8] {
        let (status, record) = try await tool.engine.runForTask(limit: limit) { call in session.next(asking: call) }
        guard status == TMFF_EXIT_DONE else {
            end(with: status)
            return []
        }
        // No record after END: the stream is whole.
        if record.isEmpty { self.status = TMFF_EXIT_DONE }
        return record
    }

    /// How long the next call may take: the stall limit, and no more than
    /// the run has left; nil, with the run stopped as the watchdog stops a
    /// helper that ran too long, once the run's time is spent.
    private func timeForTheNextCall() -> TimeInterval? {
        let elapsed = tool.clock.now() - started
        guard elapsed < limits.maximumSeconds else {
            stopped = .tookTooLong(seconds: limits.maximumSeconds)
            return nil
        }
        return min(limits.maximumSeconds - elapsed, limits.maximumStalledSeconds)
    }

    /// Ends the stream with `status`. A stop the task's cancellation did not
    /// ask for (TMFF_EXIT_STOPPED) was a limit's: the run's whole time when
    /// it is spent, else the call's, the stall.
    private func end(with status: Int32) {
        self.status = status
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
