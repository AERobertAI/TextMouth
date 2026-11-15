import Foundation
import os

/// Converts, at import, the audio of the formats macOS cannot read and the
/// installed ffmpeg can (FMT31, FMT32): Windows Media Audio (versions 1 and
/// 2, Pro, Lossless, and Voice) and Windows Media video, Speex, Musepack,
/// WebM and Matroska, AVI, Flash video, and RealMedia. The result is what
/// every other conversion writes (`ImportAudioConverter`): an .m4a file
/// beside the source, of Apple Lossless for a lossless source and AAC for a
/// lossy one, under the same hidden temporary name, checked the same way,
/// and named the same way; an AAC source of at most two channels is copied
/// into it without a second encoding. The file's tags and chapters come
/// along.
///
/// TextMouth bundles nothing of ffmpeg: it runs the one installed on the Mac
/// (`FFmpeg.locate`), with the ffprobe beside it, and refuses these formats
/// with a sentence saying what to install when there is none. Each program
/// runs as a child process under a watchdog (`WatchedProcess`), so a hostile
/// file can hang or crash a child, never the import; only the file
/// protocol is allowed (`-protocol_whitelist file`), and the demuxer is
/// named from TextMouth's own reading of the first bytes (`FFmpegContainer`),
/// so ffmpeg never guesses a format. TTA, WavPack, and Monkey's Audio are
/// not here: TextMouth reads those itself. Ogg holding Vorbis, Opus, or FLAC
/// stays with afconvert, as before; only Ogg holding Speex comes here.
enum FFmpegAudioConverter {
    // MARK: - Which Files

    /// The extensions, in lowercase, of the files the installed ffmpeg
    /// converts at import: Windows Media (wma, asf, wmv), Speex (spx),
    /// Musepack (mpc, mp+, mpp), Matroska and WebM (mka, mkv, webm, weba),
    /// and the video files macOS cannot open whose sound is the book (avi,
    /// flv, and RealMedia's ra, rm, and rmvb).
    static let extensions: Set<String> = [
        "wma", "asf", "wmv", "spx", "mpc", "mp+", "mpp", "mka", "mkv", "webm", "weba", "avi", "flv", "ra", "rm", "rmvb",
    ]

    /// Whether the import converts the file at `url` with ffmpeg: its
    /// extension is one of `extensions`, or its bytes are of a container
    /// only ffmpeg reads (`FFmpegContainer`), Speex in Ogg among them,
    /// whatever its name. Ogg of any other codec is afconvert's, and a file
    /// that holds TTA, WavPack, or Monkey's Audio is TextMouth's own readers'
    /// whatever its name (`FFmpegContainer.holdsOwnReaderFormat(fileAt:)`).
    /// This is asked of files the import converts (`ImportAudioConverter.convert`,
    /// the iPhone's refusal, the tags read before a conversion), and costs a
    /// few small reads.
    static func converts(_ url: URL) -> Bool {
        if FFmpegContainer.holdsOwnReaderFormat(fileAt: url) { return false }
        if extensions.contains(url.pathExtension.lowercased()) { return true }
        guard let container = FFmpegContainer.of(fileAt: url) else { return false }
        return container != .ogg
    }

    // MARK: - The Programs

    /// The installed ffmpeg, and the ffprobe that came with it.
    struct Programs: Equatable, Sendable {
        /// The ffmpeg executable, which converts.
        let ffmpeg: URL
        /// The ffprobe executable, which says what a file holds.
        let ffprobe: URL
    }

    /// What looking for the programs found.
    enum Located: Equatable, Sendable {
        /// Both programs.
        case found(Programs)
        /// No ffmpeg at all.
        case ffmpegMissing
        /// An ffmpeg with no ffprobe beside it or on the PATH.
        case ffprobeMissing
    }

    /// The programs installed on this Mac: ffmpeg where `FFmpeg.locate`
    /// finds it, and the ffprobe beside it (`FFmpeg.probe`). Reads only file
    /// metadata. On iOS, which starts no child process, there are none.
    static func locateInstalled() -> Located {
        guard let ffmpeg = FFmpeg.locate() else { return .ffmpegMissing }
        guard let ffprobe = ffmpeg.probe() else { return .ffprobeMissing }
        return .found(Programs(ffmpeg: ffmpeg.executable, ffprobe: ffprobe))
    }

    // MARK: - The Tool

    /// What finds, asks, and runs the programs, and what watches them: the
    /// installed ffmpeg and ffprobe under the watchdog's rules in the app,
    /// replaced in tests by stand-ins (a canned report, `/bin/cp` copying a
    /// finished file, a `sleep` that hangs), since GitHub's runners have no
    /// ffmpeg.
    struct Tool: Sendable {
        /// Finds the programs.
        var locate: @Sendable () -> Located
        /// What ffprobe says the file holds, read as the `container` it was
        /// sniffed as; nil when it cannot say.
        var probe: @Sendable (_ file: URL, _ container: FFmpegContainer, _ programs: Programs) async throws -> FFprobeReport?
        /// Whether this ffmpeg has Apple's own AAC encoder (`aac_at`), which
        /// writes what afconvert writes; its own (`aac`) otherwise.
        var hasAppleAACEncoder: @Sendable (_ programs: Programs) async throws -> Bool
        /// The executable and arguments that write `output` from `input` as
        /// `plan` says.
        var command: @Sendable (_ input: URL, _ output: URL, _ plan: Plan, _ programs: Programs)
            -> (executable: URL, arguments: [String])
        /// What the watchdog allows a conversion of a source lasting the
        /// given seconds.
        var limits: @Sendable (_ duration: TimeInterval) -> WatchedProcess.Limits
        /// How the watchdog reads a child's resident memory.
        var residentMemory: @Sendable (pid_t) -> Int64?

        /// The installed ffmpeg and ffprobe. A conversion has the limits of
        /// afconvert's (`ImportAudioConverter.Tool.afconvert`), but for the
        /// stall: a video file's sound can lie far apart in it, so its output
        /// may wait on the reading of the pictures between.
        static let installed = Tool(
            locate: { FFmpegAudioConverter.locateInstalled() },
            probe: { file, container, programs in
                try await FFmpegAudioConverter.report(of: file, as: container, using: programs.ffprobe)
            },
            hasAppleAACEncoder: { programs in try await FFmpegAudioConverter.hasAppleAACEncoder(programs.ffmpeg) },
            command: { input, output, plan, programs in
                (programs.ffmpeg, FFmpegAudioConverter.arguments(from: input, to: output, plan: plan))
            },
            limits: { duration in
                WatchedProcess.Limits(
                    maximumSeconds: 60 + duration / 10,
                    maximumResidentBytes: 1_073_741_824,
                    maximumStalledSeconds: 60
                )
            },
            residentMemory: { WatchedProcess.residentMemory(of: $0) }
        )
    }

    /// The tool conversions use: the installed programs, unless a test binds
    /// a stand-in with `FFmpegAudioConverter.$tool.withValue(_:operation:)`.
    /// It is read on the caller's thread, as `TextutilConverter.tool` is: an
    /// import reads it before its conversions start in tasks of their own
    /// (`FileImportService.convertTracks`), which do not inherit it.
    @TaskLocal static var tool: Tool = .installed

    // MARK: - Asking ffprobe

    /// What ffprobe says the file at `file`, read as `container`, holds;
    /// nil when it cannot start, fails, prints what does not parse, or is
    /// killed by the watchdog (logged as `AUDIO_INFO_KILLED`, as an afinfo
    /// that is killed is). It prints only when it ends, so the stall
    /// allowance is the whole run's, as afinfo's is (`AudioFileInfo.Tool`).
    /// - Throws: `CancellationError` only.
    static func report(of file: URL, as container: FFmpegContainer, using ffprobe: URL) async throws -> FFprobeReport? {
        let bytes = ImportAudioConverter.fileSize(of: file)
        let seconds = 30 + Double(bytes) / 20_000_000
        let result = try await WatchedProcess.runCapturingOutput(
            ffprobe,
            arguments: probeArguments(for: file, as: container),
            limits: WatchedProcess.Limits(
                maximumSeconds: seconds, maximumResidentBytes: 536_870_912, maximumStalledSeconds: seconds
            ),
            maximumOutputBytes: maximumReportBytes
        )
        switch result.outcome {
        case .exited(status: 0):
            return FFprobeReport(json: result.output)
        case .exited, .couldNotStart:
            return nil
        case let .killed(reason):
            DiagnosticLog.event(.storage, "AUDIO_INFO_KILLED: \(file.lastPathComponent): \(reason.words)")
            return nil
        }
    }

    /// The most of ffprobe's report read: 8 MB, which holds the streams and
    /// tags of any real file many times over.
    static let maximumReportBytes = 8 << 20

    /// ffprobe's arguments for `file`, read as `container`: no banner, only
    /// errors (which go nowhere), only the file protocol, the demuxer named,
    /// and the format and streams as JSON.
    static func probeArguments(for file: URL, as container: FFmpegContainer) -> [String] {
        [
            "-hide_banner", "-loglevel", "error", "-protocol_whitelist", "file",
            "-f", container.demuxer, "-print_format", "json", "-show_format", "-show_streams",
            "file:" + file.path,
        ]
    }

    /// Whether each ffmpeg already asked has Apple's AAC encoder, by its
    /// path, so an import of many files asks once.
    private static let appleEncoderAnswers = OSAllocatedUnfairLock(initialState: [String: Bool]())

    /// Whether the ffmpeg at `ffmpeg` lists Apple's own AAC encoder,
    /// `aac_at`, among its encoders (`ffmpeg -encoders`, a line such as
    /// " A..... aac_at  aac (AudioToolbox)"); false when it cannot say.
    /// - Throws: `CancellationError` only.
    static func hasAppleAACEncoder(_ ffmpeg: URL) async throws -> Bool {
        if let known = appleEncoderAnswers.withLock({ $0[ffmpeg.path] }) { return known }
        let result = try await WatchedProcess.runCapturingOutput(
            ffmpeg,
            arguments: ["-hide_banner", "-loglevel", "error", "-encoders"],
            limits: WatchedProcess.Limits(maximumSeconds: 30, maximumResidentBytes: 536_870_912, maximumStalledSeconds: 30)
        )
        guard case .exited(status: 0) = result.outcome else { return false }
        let answer = listsAppleAACEncoder(String(decoding: result.output, as: UTF8.self))
        appleEncoderAnswers.withLock { $0[ffmpeg.path] = answer }
        return answer
    }

    /// Whether `encoders`, what `ffmpeg -encoders` prints, names `aac_at`:
    /// each encoder is a line of its flags, its name, and its description.
    static func listsAppleAACEncoder(_ encoders: String) -> Bool {
        encoders.split(whereSeparator: \.isNewline).contains { line in
            line.split(separator: " ").dropFirst().first == "aac_at"
        }
    }

    // MARK: - Tags Before the Conversion

    /// What a book of the file at `url` is named by, before it is converted:
    /// the tags of the sound it is made of, as ffprobe reports them
    /// (`FFprobeReport.tags(of:)`, keys in lowercase), and how long that
    /// sound lasts, when the file says. The import names a book of one file
    /// by them (`AudioPlaybackService.extractFullMetadata`), since no Apple
    /// framework opens such a file in the app. Nil when it is no file only
    /// ffmpeg reads (`converts(_:)`), no ffmpeg or ffprobe is installed, or
    /// ffprobe can't say; a cancellation answers nil too, as only tags are
    /// wanted.
    static func tags(of url: URL, using tool: Tool) async -> (tags: [String: String], duration: TimeInterval?)? {
        guard converts(url), let container = FFmpegContainer.of(fileAt: url),
              case let .found(programs) = tool.locate(),
              let report = try? await tool.probe(url, container, programs),
              let stream = report.chosenAudio else { return nil }
        return (report.tags(of: stream), report.duration(of: stream))
    }

    // MARK: - The Plan

    /// What a conversion writes, decided from ffprobe's report before
    /// anything runs.
    struct Plan: Equatable, Sendable {
        /// How the sound is written.
        enum Encoding: Equatable, Sendable {
            /// An AAC source of at most two channels, copied as it is.
            case copy
            /// A lossy source, encoded as AAC-LC by `encoder` ("aac_at",
            /// Apple's own, or ffmpeg's "aac").
            case aac(encoder: String)
            /// A lossless source, written as Apple Lossless.
            case appleLossless
        }

        /// One tag the conversion writes itself, besides the file's own.
        struct Tag: Equatable, Sendable {
            let key: String
            let value: String
        }

        /// The container, whose demuxer reads the file.
        let container: FFmpegContainer
        /// The index of the sound stream converted (`-map 0:<index>`).
        let streamIndex: Int
        /// How it is written.
        let encoding: Encoding
        /// The channels, sample rate, bit rate, and Apple Lossless depth
        /// written, as every conversion's (`ImportAudioConverter.Target`).
        let target: ImportAudioConverter.Target
        /// The source's channels.
        let sourceChannels: Int
        /// The source's sample rate, in hertz.
        let sourceSampleRate: Double
        /// How long the source lasts, in seconds, when it says.
        let duration: TimeInterval?
        /// The stream's tags the file leaves out, written as the file's own.
        let tags: [Tag]
    }

    /// Whether ffmpeg's codec `codec` keeps every bit of its source, so it
    /// becomes Apple Lossless: linear PCM of any kind but the companded
    /// A-law and μ-law, FLAC, ALAC, WMA Lossless, RealAudio Lossless, MLP,
    /// TrueHD, and the three lossless formats TextMouth also reads itself.
    static func isLossless(codec: String) -> Bool {
        if codec.hasPrefix("pcm_") { return !["pcm_alaw", "pcm_mulaw", "pcm_vidc"].contains(codec) }
        return ["flac", "alac", "wmalossless", "ralf", "mlp", "truehd", "tta", "wavpack", "ape"].contains(codec)
    }

    /// The plan for the file named `fileName`, read as `container`, of
    /// which ffprobe said `report`, with `aacEncoder` for a lossy source.
    /// The sound is the stream the report chooses (`FFprobeReport.chosenAudio`).
    /// An AAC stream of at most two channels is copied; a lossless one
    /// becomes Apple Lossless; any other becomes AAC at its own bit rate
    /// rounded up to a standard one (`ImportAudioConverter.target(for:averageBitRate:)`),
    /// or at 64 kbit/s a channel when its rate is unknown, as the audio
    /// editor writes. More than two channels are mixed to stereo.
    /// - Throws: `Failure.noSound` when the file holds no sound to convert.
    static func plan(
        for report: FFprobeReport,
        container: FFmpegContainer,
        fileName: String,
        aacEncoder: String
    ) throws -> Plan {
        guard let stream = report.chosenAudio, let channels = stream.channels, let rate = stream.sampleRate else {
            throw Failure.noSound(fileName: fileName)
        }
        let duration = report.duration(of: stream)
        let lossless = isLossless(codec: stream.codecName)
        // Floating-point PCM keeps no depth of whole bits, as afinfo's
        // reading of it says none (`SourceInfo.bitsPerSample`), so it becomes
        // Apple Lossless of 24 bits, as it does through afconvert.
        let isFloat = stream.codecName.hasPrefix("pcm_f")
        let info = ImportAudioConverter.SourceInfo(
            sampleRate: rate, channels: channels, duration: duration ?? 0, formatID: stream.codecName,
            bitsPerSample: isFloat ? nil : stream.bitsPerSample, isLossless: lossless
        )
        let encoding: Plan.Encoding
        let target: ImportAudioConverter.Target
        if stream.codecName == "aac", channels <= ImportAudioConverter.maximumChannels {
            encoding = .copy
            target = ImportAudioConverter.Target(channels: channels, sampleRate: rate, bitRate: report.bitRate(of: stream))
        } else if lossless {
            encoding = .appleLossless
            target = ImportAudioConverter.target(for: info, averageBitRate: 0)
        } else {
            encoding = .aac(encoder: aacEncoder)
            let unknownRate = AudioRenderSettings.bitRatePerChannel * min(channels, ImportAudioConverter.maximumChannels)
            target = ImportAudioConverter.target(for: info, averageBitRate: Double(report.bitRate(of: stream) ?? unknownRate))
        }
        return Plan(
            container: container,
            streamIndex: stream.index,
            encoding: encoding,
            target: target,
            sourceChannels: channels,
            sourceSampleRate: rate,
            duration: duration,
            tags: report.streamTagsToCarry(of: stream).map { Plan.Tag(key: $0.key, value: $0.value) }
        )
    }

    // MARK: - The Command

    /// ffmpeg's arguments for writing `output` from `input` as `plan` says:
    ///
    /// - no banner, no questions, only errors (which go nowhere), and any
    ///   earlier output replaced (`FFmpeg.quietOptions`);
    /// - only the file protocol, and the demuxer named (`-f`), each path
    ///   given with "file:" so no name can be read as another protocol;
    /// - the one sound stream (`-map 0:<index>`), the file's chapters and
    ///   tags (`-map_chapters 0`, `-map_metadata 0`), and the stream's own
    ///   tags the file leaves out (`-metadata`);
    /// - for an encoding, the timestamps made again from the samples
    ///   (`asetpts=N/SR/TB`), since some containers give many packets one
    ///   time (RealMedia does), which leaves an MPEG-4 file that says it is
    ///   shorter than its sound; then AAC at the bit rate and, where it
    ///   differs, the sample rate of the plan, or Apple Lossless in 16 or 32
    ///   bits a sample with the depth it keeps (`-bits_per_raw_sample` for 20
    ///   and 24); and a mix to stereo for more than two channels (`-ac 2`);
    /// - an MPEG-4 audio file (`-f ipod`), whatever the output's name.
    static func arguments(from input: URL, to output: URL, plan: Plan) -> [String] {
        var arguments = FFmpeg.quietOptions + [
            "-protocol_whitelist", "file",
            "-f", plan.container.demuxer, "-i", "file:" + input.path,
            "-map", "0:\(plan.streamIndex)", "-map_chapters", "0", "-map_metadata", "0",
        ]
        for tag in plan.tags {
            arguments += ["-metadata", "\(tag.key)=\(tag.value)"]
        }
        switch plan.encoding {
        case .copy:
            arguments += ["-c:a", "copy"]
        case let .aac(encoder):
            arguments += ["-af", "asetpts=N/SR/TB", "-c:a", encoder]
            if let bitRate = plan.target.bitRate { arguments += ["-b:a", String(bitRate)] }
            if plan.target.sampleRate != plan.sourceSampleRate { arguments += ["-ar", String(Int(plan.target.sampleRate))] }
        case .appleLossless:
            let depth = plan.target.appleLosslessBitDepth ?? 24
            arguments += ["-af", "asetpts=N/SR/TB", "-c:a", "alac", "-sample_fmt", depth == 16 ? "s16p" : "s32p"]
            if depth == 20 || depth == 24 { arguments += ["-bits_per_raw_sample", String(depth)] }
        }
        if plan.encoding != .copy, plan.sourceChannels > plan.target.channels {
            arguments += ["-ac", String(plan.target.channels)]
        }
        return arguments + ["-f", "ipod", "file:" + output.path]
    }

    // MARK: - Converting

    /// Why a file was not converted, besides the reasons every conversion
    /// shares (`ImportAudioConverter.Failure`), in the words a listener hears
    /// (`FFmpegImportWording`).
    enum Failure: LocalizedError, Equatable {
        /// No ffmpeg is installed; `kind` names the format.
        case ffmpegMissing(kind: String)
        /// The ffmpeg installed has no ffprobe; `kind` names the format.
        case ffprobeMissing(kind: String)
        /// A Windows Media file is copy-protected.
        case copyProtected
        /// The file's bytes are not of the format `kind` its name says, or
        /// ffprobe could not read them.
        case notRecognized(fileName: String, kind: String)
        /// The file holds no sound, as a video without a sound track.
        case noSound(fileName: String)

        var errorDescription: String? {
            switch self {
            case let .ffmpegMissing(kind): return FFmpegImportWording.ffmpegMissing(kind: kind)
            case let .ffprobeMissing(kind): return FFmpegImportWording.ffprobeMissing(kind: kind)
            case .copyProtected: return FFmpegImportWording.copyProtected
            case let .notRecognized(fileName, kind): return FFmpegImportWording.notRecognized(fileName: fileName, kind: kind)
            case let .noSound(fileName): return FFmpegImportWording.noSound(fileName: fileName)
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
        min(Double(max(bytes, 0)) * 8 / Double(lowestAssumedBitRate), FFprobeReport.maximumDuration)
    }

    /// Converts `source`, a file the import converts with ffmpeg
    /// (`converts(_:)`), to an .m4a file beside it, as `plan(for:...)`
    /// decides, under the hidden temporary name every conversion has
    /// (`ImportAudioConverter.temporaryURL(beside:)`), and checks it: it must
    /// play and, when the source says its length, last as long to within
    /// `ImportAudioConverter.allowedLengthError(for:)`. With `naming`, it then
    /// gets its final name (`ImportAudioConverter.givingFinalName(_:)`). The
    /// source is never changed, and nothing is left behind by a failure.
    ///
    /// In order: a file that is missing or only in the cloud is unreadable;
    /// one whose bytes are of no container only ffmpeg reads is not
    /// recognized; a copy-protected Windows Media file is refused; a Mac
    /// without ffmpeg, or with no ffprobe beside it, refuses with what to
    /// install; then ffprobe reads it, and ffmpeg converts it.
    /// - Throws: `Failure`, `ImportAudioConverter.Failure` (a kill, a failed
    ///   run, a failed check, a name), or `CancellationError`.
    static func convert(_ source: URL, naming: Bool = true, using tool: Tool) async throws -> ImportAudioConverter.Conversion {
        let started = Date()
        let name = source.lastPathComponent
        guard FileManager.default.fileExists(atPath: source.path), !DatalessFiles.isDataless(source) else {
            throw ImportAudioConverter.Failure.unreadable(fileName: name)
        }
        let container = FFmpegContainer.of(fileAt: source)
        let kind = FFmpegImportWording.kindName(of: source, container: container)
        guard let container else { throw Failure.notRecognized(fileName: name, kind: kind) }
        // A protected file is refused whether or not ffmpeg is installed:
        // installing it would not help.
        if container == .asf, ASFHeader.isCopyProtected(fileAt: source) { throw Failure.copyProtected }
        let programs: Programs
        switch tool.locate() {
        case let .found(found): programs = found
        case .ffmpegMissing: throw Failure.ffmpegMissing(kind: kind)
        case .ffprobeMissing: throw Failure.ffprobeMissing(kind: kind)
        }
        guard let report = try await tool.probe(source, container, programs) else {
            throw Failure.notRecognized(fileName: name, kind: kind)
        }
        let encoder = try await tool.hasAppleAACEncoder(programs) ? "aac_at" : "aac"
        let plan = try plan(for: report, container: container, fileName: name, aacEncoder: encoder)
        let bytesBefore = ImportAudioConverter.fileSize(of: source)
        let duration = plan.duration ?? assumedDuration(ofBytes: bytesBefore)
        var limits = tool.limits(duration)
        limits.maximumOutputBytes = limits.maximumOutputBytes
            ?? ImportAudioConverter.outputCap(of: .encode, duration: duration, target: plan.target)
        let staged = ImportAudioConverter.temporaryURL(beside: source)
        let lasts: TimeInterval
        do {
            try await ImportAudioConverter.runConverting(
                tool.command(source, staged, plan, programs), named: name, limits: limits,
                residentMemory: tool.residentMemory, watching: staged
            )
            lasts = try await check(staged, against: plan.duration, from: name)
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
            bitRate: plan.encoding == .copy ? nil : plan.target.bitRate
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
