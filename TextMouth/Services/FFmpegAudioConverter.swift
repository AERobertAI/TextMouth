import Foundation
import os
private import TextMouthFFmpegProtocol

/// Converts, at import, the audio of the formats macOS cannot read and FFmpeg
/// can (FMT31, FMT32): Windows Media Audio (versions 1 and 2, Pro, Lossless,
/// and Voice) and Windows Media video, Speex, Musepack, WebM and Matroska,
/// AVI, Flash video, and RealMedia. The result is what every other conversion
/// writes (`ImportAudioConverter`): an .m4a file beside the source, of Apple
/// Lossless for a lossless source and AAC for a lossy one, under the same
/// hidden temporary name, checked the same way, and named the same way. The
/// file's tags and chapters come along.
///
/// FFmpeg is built into TextMouth (FMT50): a pinned FFmpeg 9.0.x release that
/// Scripts/vendor/ffmpeg/build.py builds, linked into a small helper program
/// in the app's bundle, TextMouthFFmpeg, so no Homebrew is needed. The Mac app
/// is not sandboxed, so FFmpeg never runs in it: the helper runs as a child
/// process under a watchdog (`WatchedProcess`), and a hostile file can hang or
/// crash a helper, never the import. The helper reads the file through its
/// own callbacks, with no FFmpeg protocol compiled in, and with the demuxer
/// named from TextMouth's own reading of the first bytes (`FFmpegContainer`),
/// so FFmpeg never guesses a format. It first says what the file holds
/// (`probe`), then decodes it to plain samples on its standard output
/// (`FFmpegHelperStream`), which the app writes into the .m4a with the writer
/// TextMouth's own readers use (`OwnAudioConverter.writeBlocks`). TTA,
/// WavPack, and Monkey's Audio are not here: TextMouth reads those itself.
/// Ogg holding Vorbis, Opus, or FLAC stays with afconvert, as before; only Ogg
/// holding Speex comes here.
///
/// The iPhone starts no program, so it links the same session into the app
/// (the FFmpeg_iOS library, FMT54) and runs it in its own process, one record
/// a call on an engine of its own (`InProcessEngine`), reading the same stream
/// with the same reader: `runSession(_:of:as:kind:at:watching:limits:using:reading:)`
/// is the one place the two ways part, and everything before and after it is
/// shared, the limits, the plan, the writer, the checks, and every sentence.
enum FFmpegAudioConverter {
    // MARK: - Which Files

    /// The extensions, in lowercase, of the files FFmpeg converts at import:
    /// Windows Media (wma, asf, wmv), Speex (spx), Musepack (mpc, mp+),
    /// Matroska and WebM (mka, mkv, webm, weba), and the video files macOS
    /// cannot open whose sound is the book (avi, flv, and RealMedia's ra, rm,
    /// and rmvb). Musepack's rare .mpp is not here: it is Microsoft Project's
    /// extension too (the TODO's FU-FFMPEG item), and a Musepack file named
    /// so is still told by its bytes (`converts(_:)`).
    static let extensions: Set<String> = [
        "wma", "asf", "wmv", "spx", "mpc", "mp+", "mka", "mkv", "webm", "weba", "avi", "flv", "ra", "rm", "rmvb",
    ]

    /// Whether the import converts the file at `url` with FFmpeg: its
    /// extension is one of `extensions`, or its bytes are of a container
    /// only FFmpeg reads (`FFmpegContainer`), Speex in Ogg among them,
    /// whatever its name. Ogg of any other codec is afconvert's, and a file
    /// that holds TTA, WavPack, or Monkey's Audio is TextMouth's own readers'
    /// whatever its name (`OwnAudioConverter.format(of:)`, the readers' own sniff).
    /// This is asked of files the import converts (`ImportAudioConverter.convert`,
    /// the iPhone's refusal, the tags read before a conversion), and costs a
    /// few small reads.
    static func converts(_ url: URL) -> Bool {
        if OwnAudioConverter.format(of: url) != nil { return false }
        if extensions.contains(url.pathExtension.lowercased()) { return true }
        guard let container = FFmpegContainer.of(fileAt: url) else { return false }
        return container != .ogg
    }

    /// Whether the file at `url`, whose bytes are of `container`, is
    /// copy-protected, as its container's own header says: a Windows Media
    /// file with a protection object (`ASFHeader.isCopyProtected`), or a
    /// Matroska or WebM file whose every sound track is encrypted
    /// (`MatroskaHeader.isCopyProtected`, B19). No converter could help
    /// either: the one check `convert` makes before anything runs, and the
    /// iPhone's import before it refuses any other format
    /// (`PhoneImportRefusal.refuseConversion`, FU-FFMPEG). RealMedia's DRM
    /// has no mark in its public format description to look for, so a
    /// protected RealMedia file still ends as a damaged one (B19).
    static func isCopyProtected(_ url: URL, container: FFmpegContainer?) -> Bool {
        switch container {
        case .asf: return ASFHeader.isCopyProtected(fileAt: url)
        case .matroska: return MatroskaHeader.isCopyProtected(fileAt: url)
        default: return false
        }
    }

    /// The files a book of several tracks leaves out rather than be refused
    /// for (`tracksToLeaveOut(of:located:)`).
    struct TracksLeftOut: Equatable, Sendable {
        /// Files of a container FFmpeg reads that can't be converted here:
        /// the Mac's helper is missing from the app (the iPhone converts them
        /// in the app itself, FMT54).
        var needingConverter: [URL] = []
        /// Files named for a format only FFmpeg reads whose bytes are of no
        /// container it reads, such as a System Information report (.spx).
        var holdingNoSound: [URL] = []
        /// What `located` found when it was asked: nil when no file was one
        /// only FFmpeg reads, so nothing was asked.
        var located: Located?

        /// Every file left out, those needing the converter first.
        var all: [URL] { needingConverter + holdingNoSound }
    }

    /// Which of `sources`, tracks of a book of several that the import
    /// converts, the book leaves out (review9 finding 2): a folder, ZIP, or
    /// playlist of MP3s may hold a stray video, or a file merely named like
    /// one of these formats, and it imported its MP3s before these formats
    /// were tracks. Of the files only FFmpeg reads (`converts(_:)`), those
    /// whose bytes are of no container FFmpeg reads are always left out, and
    /// the rest when `located`, asked only when there is such a file, found
    /// nothing that converts them (`Located.converts`: the Mac's helper
    /// missing; the iPhone's session, in the app, is never missing). A file
    /// of such a container is converted when it can be, and fails the book
    /// if that fails, as any track's conversion does.
    static func tracksToLeaveOut(of sources: [URL], located: () -> Located) -> TracksLeftOut {
        var leftOut = TracksLeftOut()
        let ffmpegFiles = sources.filter(converts)
        guard !ffmpegFiles.isEmpty else { return leftOut }
        let found = located()
        leftOut.located = found
        let convertible = found.converts
        for file in ffmpegFiles {
            if FFmpegContainer.of(fileAt: file) == nil {
                leftOut.holdingNoSound.append(file)
            } else if !convertible {
                leftOut.needingConverter.append(file)
            }
        }
        return leftOut
    }

    // MARK: - The Helper

    /// The name of the helper program in the app's Contents/MacOS.
    static let helperName = "TextMouthFFmpeg"

    /// Where the session runs, as looking for it found.
    enum Located: Equatable, Sendable {
        /// The Mac's helper, at this path.
        case found(URL)
        /// The session linked into the app, run in its own process (FMT54):
        /// the iPhone, which can start no helper program.
        case inProcess
        /// No helper: the Mac's app is damaged.
        case missing

        /// Whether a file only FFmpeg reads can be converted here: by the
        /// helper, or in the app itself.
        var converts: Bool { self != .missing }
    }

    /// Where the bundled session runs. On the Mac, the helper in the app's
    /// own bundle, beside its executable, where
    /// `Bundle.main.url(forAuxiliaryExecutable:)` finds it (the hosted tests'
    /// main bundle is the app, so they find it too), or none. On iOS, which
    /// starts no program, the session linked into the app (FMT54), which is
    /// never missing.
    static func locateBundled() -> Located {
        #if os(macOS)
        if let helper = Bundle.main.url(forAuxiliaryExecutable: helperName),
           FileManager.default.isExecutableFile(atPath: helper.path) {
            return .found(helper)
        }
        return .missing
        #else
        return .inProcess
        #endif
    }

    // MARK: - The Tool

    /// What finds the session and what holds it to its limits, the one
    /// reach for all of them on both platforms: the bundled helper under the
    /// watchdog's rules on the Mac, and on the iPhone the session in the app,
    /// on its engine, under the same limits (`runInProcess`). Tests replace
    /// it with a stand-in (a script, or on the iPhone a session, that writes
    /// a damaged stream or hangs) or a missing helper, and tight limits.
    struct Tool: Sendable {
        /// Finds where the session runs.
        var locate: @Sendable () -> Located
        /// What the watchdog allows the decode of a source lasting the given
        /// seconds.
        var limits: @Sendable (_ duration: TimeInterval) -> WatchedProcess.Limits
        /// What the watchdog allows the probe of a file of the given bytes.
        var probeLimits: @Sendable (_ bytes: Int64) -> WatchedProcess.Limits
        /// How the watchdog reads a child's resident memory.
        var residentMemory: @Sendable (pid_t) -> Int64?
        /// The bytes free on the volume that holds the given folder, or nil
        /// when unknown (the conversion then goes on): the real reading
        /// (`ImportAudioConverter.availableBytes(on:)`) unless a test fills
        /// the volume.
        var availableBytes: @Sendable (_ folder: URL) -> Int64? = { ImportAudioConverter.availableBytes(on: $0) }
        #if os(iOS)
        /// The engine the iPhone runs the session on (FMT54):
        /// `sessionEngine`, unless a test gives one of its own, so that a
        /// test that abandons a call refuses no other test's conversions.
        var engine: InProcessEngine = FFmpegAudioConverter.sessionEngine
        /// What an in-process run opens on the engine: TextMouth's session
        /// linked into the app (`LinkedFFmpegSession`), unless a test stands
        /// in for it with a stream written by hand or a call that hangs.
        var openSession: InProcessSessionOpener = LinkedFFmpegSession.open
        /// The floor under the memory the app keeps free while a session runs
        /// (the FMT54 review, finding 4): the app's, 512 MB, unless a test
        /// scripts what is left.
        var memoryFloor: SessionMemoryFloor = .app
        /// The clock an in-process run's whole time is counted by: the
        /// app's, which counts only the time TextMouth runs
        /// (`RunningClock.app`, B18), so a run frozen while iOS keeps the app
        /// suspended has spent none of it, unless a test scripts its own.
        var clock: RunningClock = .app
        #endif

        /// The bundled helper. A decode has the limits of afconvert's
        /// (`ImportAudioConverter.Tool.afconvert`), but for the stall: a video
        /// file's sound can lie far apart in it, so its samples may wait on
        /// the reading of the pictures between. A probe has ffprobe's limits
        /// of before: 30 seconds and one more for each 20 MB, and 512 MB; it
        /// writes most of what it says at its end, so the stall allowance is
        /// the whole run's.
        static let bundled = Tool(
            locate: { FFmpegAudioConverter.locateBundled() },
            limits: { duration in
                WatchedProcess.Limits(
                    maximumSeconds: 60 + duration / 10,
                    maximumResidentBytes: 1_073_741_824,
                    maximumStalledSeconds: 60
                )
            },
            probeLimits: { bytes in
                let seconds = 30 + Double(bytes) / 20_000_000
                return WatchedProcess.Limits(
                    maximumSeconds: seconds, maximumResidentBytes: 536_870_912, maximumStalledSeconds: seconds
                )
            },
            residentMemory: { WatchedProcess.residentMemory(of: $0) }
        )
    }

    /// The tool conversions use: the bundled helper on the Mac, the session
    /// in the app on the iPhone, unless a test binds a stand-in with
    /// `FFmpegAudioConverter.$tool.withValue(_:operation:)`.
    /// It is read on the caller's thread, as `TextutilConverter.tool` is: an
    /// import reads it before its conversions start in tasks of their own
    /// (`FileImportService.convertTracks`), which do not inherit it.
    @TaskLocal static var tool: Tool = .bundled

    // MARK: - Running the Session

    /// What a run of the session is asked for, as TextMouthFFmpegProtocol.h
    /// names its modes: what the file holds, or that and its sound.
    enum SessionMode: Sendable {
        case probe, decode

        /// The helper's argument for it.
        var argument: String { self == .probe ? TMFF_MODE_PROBE : TMFF_MODE_DECODE }
    }

    /// Runs the session on `file`, read as `container`, in `mode`, where
    /// `located` says it runs, and hands `read` its stream in pieces, the
    /// one place the Mac and the iPhone part (FMT54):
    /// - **The Mac** runs its helper under the watchdog
    ///   (`WatchedProcess.runStreaming`), whose watched file is `output`
    ///   (the .m4a a decode writes; nil for a probe), exactly as before.
    /// - **The iPhone** runs the session linked into the app, in this
    ///   process, on the tool's engine (`runInProcess`), under the same
    ///   limits.
    ///
    /// Both end alike: how the run ended, an exit status of
    /// TextMouthFFmpegProtocol.h or a kill and its reason, and what `read`
    /// returned or threw, which `failure(of:read:fileName:kind:limits:logTag:)`
    /// turns into the same sentence on both. `kind` names the format in a
    /// refusal.
    /// - Throws: `Failure.helperMissing` when there is no session to run
    ///   (only a damaged Mac app), and `CancellationError` when the task is
    ///   cancelled.
    static func runSession<Value: Sendable>(
        _ mode: SessionMode,
        of file: URL,
        as container: FFmpegContainer,
        kind: String,
        at located: Located,
        watching output: URL?,
        limits: WatchedProcess.Limits,
        using tool: Tool,
        reading read: (_ nextPiece: @escaping () async throws -> [UInt8]) async throws -> Value
    ) async throws -> (ending: WatchedProcess.Ending, read: Result<Value, any Error>) {
        // The session's own opener refuses a symbolic link (`O_NOFOLLOW`, FU04), but the import stages a
        // source as it is, and a copy of a link is a link: the path is resolved once, here, so a link to
        // a good file converts as it does for every other converter, and the opener's refusal stays the
        // backstop for a link made after this point.
        let file = file.resolvingSymlinksInPath()
        switch located {
        case let .found(helper):
            return try await WatchedProcess.runStreaming(
                helper, arguments: [mode.argument, container.demuxer, file.path], watching: output, limits: limits,
                residentMemory: tool.residentMemory
            ) { pipe in
                try await read { try await pipe.read(upTo: FFmpegHelperStream.pieceBytes) }
            }
        case .inProcess:
            #if os(iOS)
            return try await runInProcess(mode, of: file, demuxer: container.demuxer, limits: limits, using: tool, reading: read)
            #else
            // The Mac never runs FFmpeg in its own process, which is not sandboxed: only its helper does.
            throw Failure.helperMissing(kind: kind)
            #endif
        case .missing:
            throw Failure.helperMissing(kind: kind)
        }
    }

    // MARK: - Asking the Helper

    /// What the session says the file at `file`, read as `container`, holds
    /// (its `probe` mode): its sound stream, length, tags, and chapters.
    /// `kind` names the format in a refusal.
    /// - Throws: `Failure` or `ImportAudioConverter.Failure` saying why it
    ///   cannot (`failure(of:read:fileName:kind:limits:)`), or
    ///   `CancellationError`.
    static func probe(
        _ file: URL,
        as container: FFmpegContainer,
        kind: String,
        using tool: Tool
    ) async throws -> FFmpegReport {
        let located = tool.locate()
        guard located.converts else { throw Failure.helperMissing(kind: kind) }
        let name = file.lastPathComponent
        let limits = tool.probeLimits(ImportAudioConverter.fileSize(of: file))
        let (ending, read) = try await runSession(
            .probe, of: file, as: container, kind: kind, at: located, watching: nil, limits: limits, using: tool
        ) { nextPiece in
            var stream = FFmpegHelperStream(reading: nextPiece)
            let report = try await stream.readReport()
            // A probe's stream ends at END, with no samples.
            guard try await stream.nextBlock() == nil else { throw FFmpegHelperStream.StreamError.damaged }
            return report
        }
        if let failure = failure(of: ending, read: read, fileName: name, kind: kind, limits: limits, logTag: "AUDIO_INFO_KILLED") {
            throw failure
        }
        return try read.get()
    }

    /// The failure a run of the helper on the file named `name` ended in, or
    /// nil when it ended well. In order:
    /// - a kill by the watchdog, logged with `logTag`, as every kill is, or
    ///   the reader's own stop at the output cap (`WroteTooMuch`), the same;
    /// - a cancellation, as it is;
    /// - a whole stream, read to its END, is success, however the helper
    ///   then ended;
    /// - a stream that ended early ends in what the helper's ending says: its
    ///   exit status (`failure(forExitStatus:fileName:kind:limits:)`), a
    ///   signal (`crashed`), or, after a clean exit, that it stopped before
    ///   the end (`endedEarly`);
    /// - a stream that broke the protocol is `unreadableStream`, the helper
    ///   being killed when it was still writing;
    /// - any other error, the reader's own (a sound the converter can't
    ///   write), as it is, and so the iPhone engine's own, a call abandoned
    ///   or refused (`InProcessEngine.Failure`), in its own sentence.
    ///
    /// A run in the iPhone app ends as the helper's would (`runInProcess`):
    /// the session's status is the helper's exit status, and a stop for a
    /// limit is the watchdog's kill for the same reason.
    static func failure<Value>(
        of ending: WatchedProcess.Ending,
        read: Result<Value, any Error>,
        fileName name: String,
        kind: String,
        limits: WatchedProcess.Limits,
        logTag: String
    ) -> (any Error)? {
        if case let .killed(reason) = ending.outcome {
            return killed(reason, fileName: name, logTag: logTag)
        }
        guard case let .failure(error) = read else { return nil }
        if error is CancellationError { return error }
        // The reader's own check of the output cap: the same kill, as the watchdog would have made it.
        if let tooMuch = error as? WroteTooMuch { return killed(.wroteTooMuch(bytes: tooMuch.bytes), fileName: name, logTag: logTag) }
        guard let streamError = error as? FFmpegHelperStream.StreamError else { return error }
        switch streamError {
        case .endedEarly:
            if ending.signal != nil { return Failure.crashed(fileName: name) }
            switch ending.outcome {
            case .exited(status: 0): return Failure.endedEarly(fileName: name)
            case let .exited(status): return failure(forExitStatus: status, fileName: name, kind: kind, limits: limits)
            case .couldNotStart: return ImportAudioConverter.Failure.processFailed(fileName: name, status: -1)
            case .killed: return nil  // Answered above.
            }
        case .damaged, .otherProtocol:
            return Failure.unreadableStream(fileName: name)
        }
    }

    /// The failure of a run of the helper that was killed for `reason`, by
    /// the watchdog or by the reader's own check: the sentence every killed
    /// conversion says, with the kill logged under `logTag`.
    private static func killed(_ reason: WatchedProcess.KillReason, fileName: String, logTag: String) -> any Error {
        DiagnosticLog.event(.storage, "\(logTag): \(fileName): \(reason.words)")
        return ImportAudioConverter.Failure.killed(fileName: fileName, reason: reason.words)
    }

    /// Thrown by the reader of a decode when the .m4a it writes has passed
    /// the output cap (`checkOutputCap(of:against:)`). The helper writes to a
    /// pipe, so the kernel's file-size limit never ends it, and the watchdog
    /// looks at the file only four times a second: this is the count the reader
    /// makes itself, before each block it writes.
    struct WroteTooMuch: Error, Equatable, Sendable {
        /// The cap that was passed, in bytes.
        let bytes: Int64
    }

    /// Checks that the file at `file`, which the decode is writing, has not
    /// passed the output cap of `limits` (none: any size is allowed); a file
    /// that is not there yet is no bytes.
    /// - Throws: `WroteTooMuch` naming the cap.
    static func checkOutputCap(of file: URL, against limits: WatchedProcess.Limits) throws {
        guard let cap = limits.maximumOutputBytes, ImportAudioConverter.fileSize(of: file) > cap else { return }
        throw WroteTooMuch(bytes: cap)
    }

    /// What the helper's exit `status` says of the file named `fileName`, of
    /// the format `kind`, run under `limits`: the sentence a listener hears
    /// for each of TextMouthFFmpegProtocol.h's statuses, and the converter's
    /// code for any other.
    static func failure(forExitStatus status: Int32, fileName: String, kind: String, limits: WatchedProcess.Limits) -> any Error {
        switch status {
        case TMFF_EXIT_UNREADABLE:
            return ImportAudioConverter.Failure.unreadable(fileName: fileName)
        case TMFF_EXIT_NOT_RECOGNIZED:
            return Failure.notRecognized(fileName: fileName, kind: kind)
        case TMFF_EXIT_NO_SOUND:
            return Failure.noSound(fileName: fileName)
        case TMFF_EXIT_NO_DECODER:
            return Failure.soundNotDecoded(fileName: fileName)
        case TMFF_EXIT_DAMAGED:
            return ImportAudioConverter.Failure.notRead(fileName: fileName, problem: .damaged)
        case TMFF_EXIT_FORM_CHANGED:
            return Failure.formChanged(fileName: fileName)
        case TMFF_EXIT_FRAME_TOO_LARGE:
            return Failure.frameTooLarge(fileName: fileName)
        case TMFF_EXIT_MEMORY:
            return ImportAudioConverter.Failure.killed(fileName: fileName, reason: FFmpegImportWording.neededTooMuchMemory)
        case TMFF_EXIT_NOT_CONFINED:
            return Failure.notConfined(fileName: fileName)
        case TMFF_EXIT_CRASHED:
            return Failure.crashed(fileName: fileName)
        case TMFF_EXIT_PROCESSOR_TIME:
            let reason = WatchedProcess.KillReason.usedTooMuchProcessorTime(seconds: limits.effectiveMaximumCPUSeconds)
            return ImportAudioConverter.Failure.killed(fileName: fileName, reason: reason.words)
        default:
            return ImportAudioConverter.Failure.processFailed(fileName: fileName, status: status)
        }
    }

    // MARK: - Tags and Length Before the Conversion

    /// What a book of the file at `url` is named by, before it is converted:
    /// the tags of the sound it is made of, as the helper reports them
    /// (`FFmpegReport.bookTags(in:)`), and how long that sound lasts, when the
    /// file says. The import names a book of one file by them
    /// (`AudioPlaybackService.extractFullMetadata`), since no Apple framework
    /// opens such a file in the app. Nil when it is no file only FFmpeg reads
    /// (`converts(_:)`), there is no helper, or it can't say; a cancellation
    /// answers nil too, as only tags are wanted.
    static func tags(of url: URL, using tool: Tool) async -> (tags: OwnAudioTags, duration: TimeInterval?)? {
        guard converts(url), let container = FFmpegContainer.of(fileAt: url),
              let report = try? await probe(url, as: container, kind: FFmpegImportWording.kindName(of: url, container: container), using: tool),
              report.isUsableSound else { return nil }
        return (report.bookTags(in: container), report.duration)
    }

    /// How long the sound of the file at `url` lasts, as the helper reads it,
    /// when its size can hold that length (`believedDuration`); nil when it
    /// is no file only FFmpeg reads, it says no length, or it can't say. A
    /// cue sheet over a WMA or Matroska file is measured so
    /// (`FileImportService.measuredLengths(of:)`), which afinfo cannot read
    /// (the TODO's FU-FFMPEG item).
    static func length(of url: URL, using tool: Tool) async -> TimeInterval? {
        guard let probed = await tags(of: url, using: tool) else { return nil }
        return believedDuration(probed.duration, ofFileNamed: url.lastPathComponent, bytes: ImportAudioConverter.fileSize(of: url))
    }

    // MARK: - What Is Written

    /// Whether FFmpeg's codec `codec` keeps every bit of its source, so it
    /// becomes Apple Lossless: linear PCM of any kind but the companded
    /// A-law and μ-law, FLAC, ALAC, WMA Lossless, RealAudio Lossless, MLP,
    /// TrueHD, and the three lossless formats TextMouth also reads itself.
    static func isLossless(codec: String) -> Bool {
        if codec.hasPrefix("pcm_") { return !["pcm_alaw", "pcm_mulaw", "pcm_vidc"].contains(codec) }
        return ["flac", "alac", "wmalossless", "ralf", "mlp", "truehd", "tta", "wavpack", "ape"].contains(codec)
    }

    /// What a conversion writes from the sound `report` describes, for the
    /// file named `fileName`: the source as `ImportAudioConverter` describes
    /// one, and the target every conversion's rules make of it. A lossless
    /// source becomes Apple Lossless at its own depth (24 bits for floating
    /// point, which keeps none); any other becomes AAC at its own bit rate
    /// rounded up to a standard one (`ImportAudioConverter.target(for:averageBitRate:)`),
    /// or at 64 kbit/s a channel when its rate is unknown, as the audio
    /// editor writes. More than two channels are mixed to stereo. An AAC
    /// source is encoded again, at its own rate or higher, as every lossy
    /// source is: the helper hands over samples, not packets.
    /// - Throws: `Failure.noSound` when the report says no usable sound.
    static func plan(for report: FFmpegReport, fileName: String) throws
        -> (info: ImportAudioConverter.SourceInfo, target: ImportAudioConverter.Target)
    {
        guard report.isUsableSound, let channels = report.channels, let rate = report.sampleRate else {
            throw Failure.noSound(fileName: fileName)
        }
        let lossless = isLossless(codec: report.codecName)
        let info = ImportAudioConverter.SourceInfo(
            sampleRate: rate, channels: channels, duration: report.duration ?? 0, formatID: report.codecName,
            bitsPerSample: report.bitsPerSample, isLossless: lossless
        )
        if lossless {
            return (info, ImportAudioConverter.target(for: info, averageBitRate: 0))
        }
        let unknownRate = AudioRenderSettings.bitRatePerChannel * min(channels, ImportAudioConverter.maximumChannels)
        return (info, ImportAudioConverter.target(for: info, averageBitRate: Double(report.bitRate ?? unknownRate)))
    }

    /// The stream of samples `report` describes, as the shared writer takes
    /// one (`OwnAudioConverter.writeBlocks`): its rate, channels, and depth,
    /// whether the samples are floats, whether its codec is lossless, and
    /// which loudspeaker each channel is.
    static func samplesStream(of report: FFmpegReport) -> OwnAudioStream {
        OwnAudioStream(
            sampleRate: Int(report.sampleRate ?? 0), channels: report.channels ?? 0,
            bitsPerSample: report.sampleFormat == .f32 ? 32 : report.bits,
            isFloat: report.sampleFormat == .f32, isLossless: isLossless(codec: report.codecName),
            frames: 0, channelMask: report.channelMask
        )
    }

    // MARK: - Converting

    /// Why a file was not converted, besides the reasons every conversion
    /// shares (`ImportAudioConverter.Failure`), in the words a listener hears
    /// (`FFmpegImportWording`).
    enum Failure: LocalizedError, Equatable {
        /// The helper is missing from the app (it is damaged); `kind` names
        /// the format.
        case helperMissing(kind: String)
        /// The file is copy-protected: a Windows Media file with a protection
        /// object, or a Matroska or WebM file whose every sound track is
        /// encrypted (`isCopyProtected(_:container:)`).
        case copyProtected
        /// The file's bytes are not of the format `kind` its name says, or
        /// the helper's FFmpeg could not read them.
        case notRecognized(fileName: String, kind: String)
        /// The file holds no sound, as a video without a sound track.
        case noSound(fileName: String)
        /// The file's sound is in a codec TextMouth's FFmpeg does not decode.
        case soundNotDecoded(fileName: String)
        /// The sound changes its rate, channels, or form partway through.
        case formChanged(fileName: String)
        /// One frame of the sound holds more samples than the session
        /// decodes at once (TMFF_EXIT_FRAME_TOO_LARGE).
        case frameTooLarge(fileName: String)
        /// The helper crashed (a fatal signal) reading the file (the TODO's
        /// FU-FFMPEG item: a crashed helper's own sentence).
        case crashed(fileName: String)
        /// The helper could not confine itself, so it read nothing.
        case notConfined(fileName: String)
        /// The helper ended, with no error, before the end of the sound.
        case endedEarly(fileName: String)
        /// What the helper wrote is not the stream it writes.
        case unreadableStream(fileName: String)

        var errorDescription: String? {
            switch self {
            case let .helperMissing(kind): return FFmpegImportWording.helperMissing(kind: kind)
            case .copyProtected: return FFmpegImportWording.copyProtected
            case let .notRecognized(fileName, kind): return FFmpegImportWording.notRecognized(fileName: fileName, kind: kind)
            case let .noSound(fileName): return FFmpegImportWording.noSound(fileName: fileName)
            case let .soundNotDecoded(fileName): return FFmpegImportWording.soundNotDecoded(fileName: fileName)
            case let .formChanged(fileName): return FFmpegImportWording.formChanged(fileName: fileName)
            case let .frameTooLarge(fileName): return FFmpegImportWording.frameTooLarge(fileName: fileName)
            case let .notConfined(fileName): return FFmpegImportWording.notConfined(fileName: fileName)
            case let .crashed(fileName): return FFmpegImportWording.crashed(fileName: fileName)
            case let .endedEarly(fileName): return FFmpegImportWording.endedEarly(fileName: fileName)
            case let .unreadableStream(fileName): return FFmpegImportWording.unreadableStream(fileName: fileName)
            }
        }
    }

    /// The bit rate a source whose length is unknown is assumed to have, for
    /// its limits only, in bits a second: 6 kbit/s, below the lowest speech
    /// codec's, so the time allowed and the output cap err on the long side.
    static let lowestAssumedBitRate = 6_000

    /// How long a source of `bytes` bytes that does not say its length is
    /// taken to last, for its limits only: as long as `lowestAssumedBitRate`
    /// would make it, at most a year.
    static func assumedDuration(ofBytes bytes: Int64) -> TimeInterval {
        min(Double(max(bytes, 0)) * 8 / Double(lowestAssumedBitRate), FFmpegReport.maximumDuration)
    }

    /// The least a source that says no length may write: 64 MB, room for
    /// the small files that most grow, such as Speex at 2 kbit/s written as
    /// AAC at 32 kbit/s (15 times its size).
    static let unknownLengthOutputFloorBytes: Int64 = 64 * 1_048_576

    /// How many times its own size a source that says no length may write:
    /// 50. Its assumed length alone (`assumedDuration(ofBytes:)`) would let
    /// it write 1,536 bytes for each of its own as 24-bit stereo Apple
    /// Lossless at 48 kHz: ten minutes of silence as FLAC in Matroska,
    /// 159 KB with no length, became 55 MB in 0.6 s, so 100 MB of it could
    /// fill the disk.
    static let unknownLengthGrowth: Int64 = 50

    /// The most the conversion of a source of `bytes` bytes that says no
    /// length may write: 50 times its size (`unknownLengthGrowth`), and at
    /// least 64 MB (`unknownLengthOutputFloorBytes`). A size too large to
    /// multiply has no cap of this kind.
    static func unknownLengthOutputCap(ofBytes bytes: Int64) -> Int64 {
        let (grown, overflowed) = max(bytes, 0).multipliedReportingOverflow(by: unknownLengthGrowth)
        return overflowed ? .max : max(unknownLengthOutputFloorBytes, grown)
    }

    /// The lowest bit rate a stated length is believed at, in bits a second:
    /// 1 kbit/s, the floor afinfo's reading gives a codec it has no table
    /// for (`AudioFileInfo.lowestPlausibleBitRate`). No real file of these
    /// formats is smaller for its length.
    static let lowestPlausibleBitRate: Double = 1_000

    /// `stated`, the length a source of `bytes` bytes named `name` says it
    /// lasts, when its size can hold it: at most its bits at
    /// `lowestPlausibleBitRate`, as `AudioFileInfo.isPlausible(inFileOfBytes:)`
    /// believes afinfo's. A header can say anything, and the time limit and
    /// the output cap follow the length, so one the file cannot hold is taken
    /// as unknown (nil), logged as `AUDIO_INFO_IMPLAUSIBLE`, and the converted
    /// file is measured instead.
    static func believedDuration(_ stated: TimeInterval?, ofFileNamed name: String, bytes: Int64) -> TimeInterval? {
        guard let stated else { return nil }
        guard stated <= Double(max(bytes, 0)) * 8 / lowestPlausibleBitRate else {
            DiagnosticLog.event(.storage, AudioFileInfo.implausibleLogLine(file: name, duration: stated, bytes: bytes))
            return nil
        }
        return stated
    }

    /// Converts `source`, a file the import converts with FFmpeg
    /// (`converts(_:)`), to an .m4a file beside it, as `plan(for:fileName:)`
    /// decides, under the hidden temporary name every conversion has
    /// (`ImportAudioConverter.temporaryURL(beside:)`), and checks it: it must
    /// play and, when the source says a length its size can hold
    /// (`believedDuration(_:ofFileNamed:bytes:)`), last as long to within
    /// `ImportAudioConverter.allowedLengthError(for:)`. With `keepingChapters`
    /// the file's chapters are then written into it as every conversion's are
    /// (`ImportAudioConverter.keepChapters`). With `naming`, it then gets its
    /// final name (`ImportAudioConverter.givingFinalName(_:)`). The source is
    /// never changed, and nothing is left behind by a failure.
    ///
    /// In order: a file that is missing or only in the cloud is unreadable;
    /// one whose bytes are of no container only FFmpeg reads is not
    /// recognized; a copy-protected file (Windows Media, Matroska, or WebM,
    /// `isCopyProtected(_:container:)`) is refused; an app
    /// whose helper is missing refuses; then the session (the Mac's helper,
    /// or the iPhone's in the app) says what the file holds, a source of no
    /// stated length is refused when the volume lacks room for what it may
    /// write, and the session decodes it while the app writes the .m4a.
    /// - Throws: `Failure`, `ImportAudioConverter.Failure` (a kill, a failed
    ///   run, a failed check, a name, a writer's failure), or
    ///   `CancellationError`.
    static func convert(
        _ source: URL,
        naming: Bool = true,
        keepingChapters: Bool = true,
        using tool: Tool
    ) async throws -> ImportAudioConverter.Conversion {
        let started = Date()
        let name = source.lastPathComponent
        guard FileManager.default.fileExists(atPath: source.path), !DatalessFiles.isDataless(source) else {
            throw ImportAudioConverter.Failure.unreadable(fileName: name)
        }
        let container = FFmpegContainer.of(fileAt: source)
        let kind = FFmpegImportWording.kindName(of: source, container: container)
        guard let container else { throw Failure.notRecognized(fileName: name, kind: kind) }
        // A protected file is refused before anything runs: no converter
        // could help.
        if isCopyProtected(source, container: container) { throw Failure.copyProtected }
        let located = tool.locate()
        guard located.converts else { throw Failure.helperMissing(kind: kind) }
        let report = try await probe(source, as: container, kind: kind, using: tool)
        let planned = try plan(for: report, fileName: name)
        let bytesBefore = ImportAudioConverter.fileSize(of: source)
        // A length the file's size cannot hold is no length (as afinfo's is
        // not): the limits and the check then go by what is measured.
        let stated = believedDuration(report.duration, ofFileNamed: name, bytes: bytesBefore)
        let duration = stated ?? assumedDuration(ofBytes: bytesBefore)
        var limits = tool.limits(duration)
        limits.maximumOutputBytes = limits.maximumOutputBytes
            ?? ImportAudioConverter.outputCap(of: .encode, duration: duration, target: planned.target)
        let staged = ImportAudioConverter.temporaryURL(beside: source)
        if stated == nil {
            // A length assumed from the size lets the output grow far past
            // it, so it is capped by the size too (`unknownLengthOutputCap`),
            // and refused before the decode runs when the volume lacks room
            // for that cap and the reserve left for the rest of the system
            // (`downmixReserveBytes`).
            let sizeCap = unknownLengthOutputCap(ofBytes: bytesBefore)
            limits.maximumOutputBytes = min(limits.maximumOutputBytes ?? .max, sizeCap)
            let (needed, overflowed) = sizeCap.addingReportingOverflow(ImportAudioConverter.downmixReserveBytes)
            if let available = tool.availableBytes(staged.deletingLastPathComponent()),
               overflowed || available < needed {
                throw ImportAudioConverter.Failure.notEnoughSpace(fileName: name, bytesNeeded: overflowed ? .max : needed)
            }
        }
        let lasts: TimeInterval
        let written: ImportAudioConverter.Target
        let partlyDecoded: Bool
        do {
            (written, lasts, partlyDecoded) = try await decode(
                source, as: container, kind: kind, at: located, into: staged, limits: limits, tool: tool, stated: stated
            )
            if keepingChapters, report.chapterMarks.count > 0 {
                try await ImportAudioConverter.keepChapters(report.chapterMarks, in: staged, lasting: lasts, from: name)
            }
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        var conversion = ImportAudioConverter.Conversion(
            source: source,
            converted: staged,
            duration: lasts,
            secondsTaken: Date().timeIntervalSince(started),
            bytesBefore: bytesBefore,
            bytesAfter: ImportAudioConverter.fileSize(of: staged),
            bitRate: written.bitRate,
            partlyDecoded: partlyDecoded
        )
        if naming {
            do {
                conversion = try ImportAudioConverter.givingFinalName(conversion)
            } catch {
                try? FileManager.default.removeItem(at: staged)
                throw error
            }
        }
        return conversion
    }

    /// Runs the session's decode of `source`, read as `container`, where
    /// `located` says, under `limits`, writing its samples into `staged` as
    /// the decode's own report plans (`plan(for:fileName:)`: the samples
    /// decoded are what it describes, which may differ from the probe's, as
    /// HE-AAC's rate does), with the file's tags (`FFmpegReport.bookTags(in:)`);
    /// then checks the .m4a (`check(_:against:from:)`). Returns what was
    /// written and how long the .m4a lasts.
    /// - Throws: as `convert` does; a writer's failure as
    ///   `ImportAudioConverter.Failure.notWritten`.
    private static func decode(
        _ source: URL,
        as container: FFmpegContainer,
        kind: String,
        at located: Located,
        into staged: URL,
        limits: WatchedProcess.Limits,
        tool: Tool,
        stated: TimeInterval?
    ) async throws -> (target: ImportAudioConverter.Target, lasts: TimeInterval, partlyDecoded: Bool) {
        let name = source.lastPathComponent
        let (ending, read) = try await runSession(
            .decode, of: source, as: container, kind: kind, at: located, watching: staged, limits: limits, using: tool
        ) { nextPiece -> (target: ImportAudioConverter.Target, refusedPackets: UInt32) in
            var stream = FFmpegHelperStream(reading: nextPiece)
            let report = try await stream.readReport()
            let target = try plan(for: report, fileName: name).target
            do {
                try await OwnAudioConverter.writeBlocks(
                    of: samplesStream(of: report), tags: report.bookTags(in: container), to: staged, target: target
                ) {
                    // Before each block, so a decode that writes fast is stopped at the cap, not a second later.
                    try checkOutputCap(of: staged, against: limits)
                    return try await stream.nextBlock()
                }
                // And once more for what the last blocks and the closing of the file added.
                try checkOutputCap(of: staged, against: limits)
            } catch let AudioEditError.renderFailed(reason) {
                // The reason is an error's domain and code, which never quote a path.
                throw ImportAudioConverter.Failure.notWritten(fileName: name, reason: reason)
            }
            if stream.refusedPackets > 0 || stream.refusedFrames > 0 {
                DiagnosticLog.event(.storage, "\(refusedLogTag): \(name): \(stream.refusedPackets) packets, \(stream.refusedFrames) frames")
            }
            return (target, stream.refusedPackets)
        }
        if let failure = failure(of: ending, read: read, fileName: name, kind: kind, limits: limits, logTag: "AUDIO_CONVERSION_KILLED") {
            throw failure
        }
        let (target, refusedPackets) = try read.get()
        return (target, try await check(staged, against: stated, from: name), refusedPackets > 0)
    }

    /// The tag of the debug-log line saying how many packets and frames the
    /// decoder refused in a file it converted all the same (a damaged file).
    static let refusedLogTag = "AUDIO_DECODER_REFUSED"

    /// Checks the converted file at `url`, made from the file named
    /// `sourceName`: when the source said it lasts `duration` seconds, as
    /// every conversion is checked (`ImportAudioConverter.check`); when it
    /// did not, it must open and decode as audio (`AudioMediaProbe`) and
    /// last longer than nothing. Returns how long the converted file lasts:
    /// the source's length, else the one measured.
    /// - Throws: `ImportAudioConverter.Failure.checkFailed`.
    private static func check(_ url: URL, against duration: TimeInterval?, from sourceName: String) async throws -> TimeInterval {
        if let duration {
            try await ImportAudioConverter.check(url, against: duration, from: sourceName)
            return duration
        }
        switch await AudioMediaProbe.duration(of: url) {
        case let .failure(problem):
            throw ImportAudioConverter.Failure.checkFailed(fileName: sourceName, reason: problem.reason)
        case let .success(seconds):
            guard seconds > 0 else {
                throw ImportAudioConverter.Failure.checkFailed(fileName: sourceName, reason: FFmpegImportWording.convertedFileIsSilent)
            }
            return seconds
        }
    }
}
