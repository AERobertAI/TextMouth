import AudioToolbox
import AVFoundation
import Darwin

/// Converts Ogg audio (Vorbis or Opus, in .ogg, .oga, or .opus files) to
/// AAC-LC in an .m4a file beside it (B06), so TextMouth never hands Ogg to
/// a player.
///
/// On October 14, 2026 Apple's Vorbis decoder, playing an Ogg track through
/// AVPlayer at 1.5x, locked up inside AudioToolbox and grew TextMouth to
/// 34 GB until the Mac ran out of memory. The same decoder then froze every
/// conversion that decoded Ogg inside TextMouth with AVAssetReader (B09), and
/// no in-process call can be stopped once it spins. So TextMouth never
/// decodes Ogg itself: it runs Apple's own `/usr/bin/afconvert` as a child
/// process (`WatchedProcess`), which a watchdog kills when it runs too long,
/// holds too much memory, or stops writing (`ConversionLimits`). All that
/// TextMouth reads of the Ogg file is its header (`inspect(_:)`).
///
/// A file is written at the source's own average bit rate rounded up to the
/// next standard AAC rate, so a track stays about the same size and sounds
/// no worse (`bitRate(averaging:channels:accepted:)`), under a hidden
/// temporary name, checked by `AudioMediaProbe` (which decodes the AAC, never
/// the Ogg: it plays, and lasts as long as its source to within
/// `lengthTolerance`), and only then given its final name: the source's
/// stem with .m4a, made unique when taken.
enum OggAudioConverter {
    /// The extensions of Ogg audio, in lowercase: Vorbis's, the Ogg audio
    /// container's, and Opus's.
    static let fileExtensions: Set<String> = ["ogg", "oga", "opus"]

    /// How many files convert at once. Each conversion decodes and encodes
    /// one buffer at a time, so its memory stays small whatever the file's
    /// length. Measured on October 14, 2026 on the user's Mac (four
    /// performance cores, 8 GB) with 20-minute stereo Vorbis tracks: one at
    /// a time ran at 306 times real time with a peak footprint of 16 MB,
    /// four at once at 586 times real time with a peak of 39 MB, so a
    /// 176-track book of about 117 hours converts in about 12 minutes.
    static let maximumConcurrentConversions = 4

    /// How far a converted file's length may differ from its source's and
    /// still be taken: a second, as the task asks. AAC's priming and
    /// padding come to a few dozen milliseconds at most.
    static let lengthTolerance: TimeInterval = 1

    /// What ends the hidden name a file has while it is written and
    /// checked (`temporaryURL(beside:)`): the reader never lists a hidden
    /// file (`AudioBookParser.audioFiles(in:)` skips them), and a file left
    /// behind by an interrupted conversion is found by it and removed
    /// (`removeLeftovers(in:)`).
    static let temporarySuffix = ".ogg-conversion.m4a"

    /// The longest file name, in UTF-16 code units, that every supported
    /// file system accepts (exFAT and HFS+ count units; APFS counts
    /// characters, so it accepts at least as much).
    static let maximumNameLength = 255

    /// The standard AAC bit rates of stereo audio, in bits a second; mono's
    /// are half of each (`standardBitRates(channels:)`).
    static let stereoBitRates = [64_000, 80_000, 96_000, 112_000, 128_000, 160_000, 192_000]

    /// One file converted: where it came from and went, and what that took.
    struct Conversion: Equatable, Sendable {
        /// The Ogg file, which a conversion never changes or removes.
        let source: URL
        /// The .m4a file: under its hidden temporary name until it is
        /// given its final one (`givingFinalName(_:)`).
        var converted: URL
        /// How long the source lasts, in seconds.
        let duration: TimeInterval
        /// How long the conversion took, in seconds.
        let secondsTaken: TimeInterval
        /// The source's size in bytes.
        let bytesBefore: Int64
        /// The converted file's size in bytes.
        let bytesAfter: Int64
        /// The AAC bit rate written, in bits a second, or nil when the
        /// encoder chose its own.
        let bitRate: Int?
    }

    /// Why a file could not be converted, in words a listener can be told.
    enum Failure: LocalizedError, Equatable {
        /// The Ogg file could not be read as audio, or is only in the cloud.
        case unreadable(fileName: String)
        /// The converted file failed its check: it would not play, or its
        /// length was not its source's.
        case checkFailed(fileName: String, reason: String)
        /// The converted file could not be given its final name.
        case cannotName(fileName: String)
        /// The watchdog killed the converting process, for `reason`.
        case killed(fileName: String, reason: String)
        /// The converting process ended in failure with exit `status`, or
        /// could not be started (status -1).
        case processFailed(fileName: String, status: Int32)

        var errorDescription: String? {
            switch self {
            case let .unreadable(fileName):
                return "The Ogg audio file \(fileName) could not be read for converting to AAC."
            case let .checkFailed(fileName, reason):
                return "The AAC audio converted from \(fileName) failed its check: \(reason)."
            case let .cannotName(fileName):
                return "The AAC audio converted from \(fileName) could not be given its name."
            case let .killed(fileName, reason):
                return "Converting \(fileName) to AAC was stopped because \(reason)."
            case let .processFailed(fileName, status):
                return "Converting \(fileName) to AAC failed (the converter ended with code \(status))."
            }
        }
    }

    // MARK: - Which Files

    /// Whether the file at `url` is Ogg audio, by its extension in any case.
    static func isOgg(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    /// The Ogg files among the tracks of the folder `folder`, found by the
    /// reader's own rules (`AudioBookParser.audioFiles(in:)`: wrapper
    /// folders count; hidden files, AppleDouble sidecars, and symbolic links
    /// do not), in Finder's order; none when the folder can't be read.
    static func oggFiles(in folder: URL) -> [URL] {
        ((try? AudioBookParser.audioFiles(in: folder)) ?? []).filter(isOgg)
    }

    // MARK: - The Settings

    /// The standard AAC bit rates for `channels` channels, in bits a
    /// second: stereo's for two or more, half of each for mono.
    static func standardBitRates(channels: Int) -> [Int] {
        channels >= 2 ? stereoBitRates : stereoBitRates.map { $0 / 2 }
    }

    /// The bit rate a source of `average` bits a second in `channels`
    /// channels is encoded at: the next standard AAC rate at or above its
    /// average (the highest standard rate for anything above it), so a
    /// track stays about the same size and is no worse. Where the encoder
    /// doesn't take that rate at the sample rate written, `accepted` (the
    /// rates it does take) gives the nearest one above, or its highest;
    /// nil when it names none, so the encoder chooses.
    static func bitRate(averaging average: Double, channels: Int, accepted: [Int]) -> Int? {
        let standard = standardBitRates(channels: channels)
        let chosen = standard.first { Double($0) >= average } ?? standard.last ?? 64_000
        guard !accepted.isEmpty else { return nil }
        if accepted.contains(chosen) { return chosen }
        return accepted.filter { $0 >= chosen }.min() ?? accepted.max()
    }

    /// The sample rate a source at `rate` is encoded at: its own when the
    /// AAC encoder takes it (`RecordingEncoder.aacSampleRates`), otherwise
    /// 44.1 kHz for a rate of that family (a multiple of 11,025 Hz) and
    /// 48 kHz for any other.
    static func sampleRate(for rate: Double) -> Double {
        if RecordingEncoder.aacSampleRates.contains(rate) { return rate }
        let isOfCDFamily = rate > 0 && rate.truncatingRemainder(dividingBy: 11_025) == 0
        return isOfCDFamily ? 44_100 : 48_000
    }

    /// What the header of an Ogg file says: read without decoding a sample
    /// (`inspect(_:)`).
    struct SourceInfo: Equatable, Sendable {
        /// The sample rate, in hertz.
        let sampleRate: Double
        /// The number of channels.
        let channels: Int
        /// How long it lasts, in seconds, as the container estimates it.
        let duration: TimeInterval
    }

    /// The sample rate, channels, and length of the Ogg file at `url`, from
    /// its header alone through AudioFile: nothing is decoded, so Apple's
    /// Vorbis decoder is never run in TextMouth. Nil when the file isn't
    /// there, is only in the cloud, or isn't audio AudioFile reads.
    static func inspect(_ url: URL) -> SourceInfo? {
        guard FileManager.default.fileExists(atPath: url.path), !DatalessFiles.isDataless(url) else { return nil }
        var file: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &file) == noErr, let file else { return nil }
        defer { AudioFileClose(file) }
        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var seconds: Float64 = 0
        var secondsSize = UInt32(MemoryLayout<Float64>.size)
        guard AudioFileGetProperty(file, kAudioFilePropertyDataFormat, &formatSize, &format) == noErr,
              AudioFileGetProperty(file, kAudioFilePropertyEstimatedDuration, &secondsSize, &seconds) == noErr,
              format.mSampleRate > 0, format.mChannelsPerFrame > 0, seconds.isFinite, seconds > 0 else { return nil }
        return SourceInfo(sampleRate: format.mSampleRate, channels: Int(format.mChannelsPerFrame), duration: seconds)
    }

    /// How a source described by `info`, a file of `bytes` bytes, is written:
    /// AAC-LC at its own channels (two at most: more are mixed down to
    /// stereo), its own sample rate where AAC takes it
    /// (`sampleRate(for:)`), and its average bit rate, bytes × 8 ÷ duration,
    /// rounded up to the next standard rate.
    struct Target: Equatable, Sendable {
        /// The channels written: one or two.
        let channels: Int
        /// The sample rate written, in hertz.
        let sampleRate: Double
        /// The bit rate written, in bits a second; nil when the encoder
        /// chooses.
        let bitRate: Int?
    }

    /// The `Target` for `info` and `bytes`; see `Target`.
    static func target(for info: SourceInfo, bytes: Int64) -> Target {
        let channels = min(max(info.channels, 1), 2)
        let rate = sampleRate(for: info.sampleRate)
        let average = Double(bytes) * 8 / info.duration
        return Target(
            channels: channels,
            sampleRate: rate,
            bitRate: bitRate(
                averaging: average,
                channels: channels,
                accepted: AudioRenderSettings.acceptedAACBitRates(sampleRate: rate, channels: channels)
            )
        )
    }

    /// The arguments of afconvert for writing `input` to `output` as `target`
    /// from a source described by `info`: an .m4a file of AAC at the bit
    /// rate; the sample rate (`-d aac@rate`) only where it differs from the
    /// source's, and the channel count (`-c`) only where the source has more
    /// than two.
    static func afconvertArguments(from input: URL, to output: URL, info: SourceInfo, target: Target) -> [String] {
        var format = "aac"
        if target.sampleRate != info.sampleRate { format += "@\(Int(target.sampleRate))" }
        var arguments = ["-f", "m4af", "-d", format]
        if info.channels > 2 { arguments += ["-c", String(target.channels)] }
        if let bitRate = target.bitRate { arguments += ["-b", String(bitRate)] }
        return arguments + [input.path, output.path]
    }

    // MARK: - The Converting Process

    /// What runs a conversion, and what watches it: afconvert under the
    /// watchdog's rules in the app, replaced in tests by a stand-in child
    /// (a `sleep`, or a script that writes slowly) and tight limits.
    struct Tool: Sendable {
        /// The executable and arguments that write `output` from `input`.
        var command: @Sendable (_ input: URL, _ output: URL, _ info: SourceInfo, _ target: Target)
            -> (executable: URL, arguments: [String])
        /// What the watchdog allows a conversion of a track lasting the
        /// given seconds.
        var limits: @Sendable (_ duration: TimeInterval) -> WatchedProcess.Limits
        /// How the watchdog reads the child's resident memory.
        var residentMemory: @Sendable (pid_t) -> Int64?

        /// Apple's own converter, which reads Ogg through AudioFile and
        /// ExtAudioFile; it converted a 34-minute Vorbis track whole in
        /// 9.5 seconds on October 13, 2026.
        static let afconvert = Tool(
            command: { input, output, info, target in
                (URL(fileURLWithPath: "/usr/bin/afconvert"), afconvertArguments(from: input, to: output, info: info, target: target))
            },
            limits: { duration in
                WatchedProcess.Limits(
                    maximumSeconds: 60 + duration / 10,
                    maximumResidentBytes: 1_073_741_824,
                    maximumStalledSeconds: 20
                )
            },
            residentMemory: { WatchedProcess.residentMemory(of: $0) }
        )
    }

    // MARK: - Converting

    /// The hidden name a conversion of `source` has until it is named:
    /// ".<UUID>.ogg-conversion.m4a", beside `source`. It is built from the
    /// UUID alone, 56 characters whatever the source's name, so a source
    /// with a long stem (up to the file system's limit) can still be
    /// converted; the UUID makes it unique, and `removeLeftovers(in:)` finds
    /// it by `temporarySuffix`.
    static func temporaryURL(beside source: URL) -> URL {
        source.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)\(temporarySuffix)")
    }

    /// Converts the Ogg file `source` to AAC in an .m4a file beside it,
    /// under a hidden temporary name, and checks the result: it must play,
    /// and last as long as the source to within `allowedLengthError(for:)`.
    /// With `naming`, it then gets its final name (`givingFinalName(_:)`);
    /// without, it keeps the temporary one, for a caller that names a whole
    /// book's files in one step. The source is never changed, and nothing
    /// is left behind by a failure. Nothing is downloaded: a file only in
    /// the cloud is refused. The conversion runs in a child process the
    /// watchdog of `tool` kills when it hangs (`OGG_CONVERSION_KILLED` in the
    /// debug log).
    /// - Throws: `Failure`, or `CancellationError` when the task is
    ///   cancelled.
    static func convert(_ source: URL, naming: Bool = true, using tool: Tool = .afconvert) async throws -> Conversion {
        let started = Date()
        let name = source.lastPathComponent
        guard let info = inspect(source) else { throw Failure.unreadable(fileName: name) }
        let bytesBefore = fileSize(of: source)
        let target = target(for: info, bytes: bytesBefore)
        let staged = temporaryURL(beside: source)
        do {
            try await run(tool, from: source, to: staged, info: info, target: target)
            try await check(staged, against: info.duration, from: name)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        var conversion = Conversion(
            source: source,
            converted: staged,
            duration: info.duration,
            secondsTaken: Date().timeIntervalSince(started),
            bytesBefore: bytesBefore,
            bytesAfter: fileSize(of: staged),
            bitRate: target.bitRate
        )
        if naming {
            do {
                conversion = try givingFinalName(conversion)
            } catch {
                try? FileManager.default.removeItem(at: staged)
                throw error
            }
        }
        return conversion
    }

    /// Runs the converting process of `tool` for `source`, writing `staged`,
    /// and turns how it ended into success or a `Failure`; a kill is logged.
    private static func run(
        _ tool: Tool,
        from source: URL,
        to staged: URL,
        info: SourceInfo,
        target: Target
    ) async throws {
        let name = source.lastPathComponent
        let command = tool.command(source, staged, info, target)
        let outcome = try await WatchedProcess.run(
            command.executable,
            arguments: command.arguments,
            watching: staged,
            limits: tool.limits(info.duration),
            residentMemory: tool.residentMemory
        )
        switch outcome {
        case .exited(status: 0):
            return
        case let .exited(status):
            throw Failure.processFailed(fileName: name, status: status)
        case .couldNotStart:
            throw Failure.processFailed(fileName: name, status: -1)
        case let .killed(reason):
            DiagnosticLog.event(.storage, "OGG_CONVERSION_KILLED: \(name): \(reason.words)")
            throw Failure.killed(fileName: name, reason: reason.words)
        }
    }

    /// How far the length of a converted file may differ from its source's
    /// `duration`: `lengthTolerance`, and a half of a percent more, since an
    /// Ogg file's length is the container's estimate, not a count of decoded
    /// samples.
    static func allowedLengthError(for duration: TimeInterval) -> TimeInterval {
        lengthTolerance + duration * 0.005
    }

    /// Checks the converted file at `url`, made from the file named
    /// `sourceName` lasting `duration` seconds: it must open and decode as
    /// audio (`AudioMediaProbe`), and last as long to within
    /// `lengthTolerance`.
    /// - Throws: `Failure.checkFailed`.
    private static func check(_ url: URL, against duration: TimeInterval, from sourceName: String) async throws {
        switch await AudioMediaProbe.duration(of: url) {
        case let .failure(problem):
            throw Failure.checkFailed(fileName: sourceName, reason: problem.reason)
        case let .success(seconds):
            guard abs(seconds - duration) <= allowedLengthError(for: duration) else {
                throw Failure.checkFailed(
                    fileName: sourceName,
                    reason: String(format: "it lasts %.1f seconds, not %.1f", seconds, duration)
                )
            }
        }
    }

    /// The exclusive rename that takes a final name: `from` becomes `to`
    /// only if nothing has the name `to` (`RENAME_EXCL`). Returns 0, or -1
    /// with `errno` set. This is `givingFinalName`'s default `exclusiveRename`.
    static func renameWithoutReplacing(_ from: String, _ to: String) -> Int32 {
        renamex_np(from, to, UInt32(RENAME_EXCL))
    }

    /// The name of the `number`th candidate for a final name: `stem` with
    /// .m4a for the first, "<stem> 2.m4a" and so on after. Should the name
    /// pass `maximumNameLength` UTF-16 units, whole characters (never half
    /// a grapheme cluster) are dropped from the end of the stem until it
    /// fits; the stem itself is not changed, so each candidate is fitted on
    /// its own.
    static func candidateName(stem: String, number: Int) -> String {
        let ending = number == 1 ? ".m4a" : " \(number).m4a"
        var characters = Substring(stem)
        // Drop the stem's last character until the whole name fits.
        while characters.utf16.count + ending.utf16.count > maximumNameLength, !characters.isEmpty {
            characters.removeLast()
        }
        return String(characters) + ending
    }

    /// `conversion` with its file given its final name: its source's stem
    /// with .m4a, or, when a file has that name already, the first of
    /// "<stem> 2.m4a", "<stem> 3.m4a", … that is free (`candidateName`).
    /// Each name is taken with one rename that refuses an existing file
    /// (`RENAME_EXCL`), so two conversions finishing at once never take the
    /// same name, and no file is ever replaced. A file system that does not
    /// support that rename (exFAT answers ENOTSUP) is served by reserving the
    /// name with an exclusive create, which is as safe, and then renaming
    /// over the empty reservation.
    /// - Parameter exclusiveRename: How the exclusive rename is made: 0, or
    ///   -1 with `errno` set. A test passes one that fails as it chooses.
    /// - Throws: `Failure.cannotName` when the rename fails otherwise.
    static func givingFinalName(
        _ conversion: Conversion,
        exclusiveRename: (_ from: String, _ to: String) -> Int32 = renameWithoutReplacing
    ) throws -> Conversion {
        let folder = conversion.source.deletingLastPathComponent()
        let stem = conversion.source.deletingPathExtension().lastPathComponent
        let failure = Failure.cannotName(fileName: conversion.source.lastPathComponent)
        var number = 1
        while true {
            let target = folder.appendingPathComponent(candidateName(stem: stem, number: number))
            var taken = exclusiveRename(conversion.converted.path, target.path) == 0
            // Read errno at once: nothing may run between the failure and it.
            let reason = taken ? 0 : errno
            if !taken, reason == ENOTSUP || reason == EOPNOTSUPP {
                taken = try renamingOverReservation(of: conversion.converted, to: target, failure: failure)
            } else if !taken, reason != EEXIST {
                throw failure
            }
            if taken {
                var named = conversion
                named.converted = target
                return named
            }
            number += 1
        }
    }

    /// The fallback for a file system without `RENAME_EXCL`: reserves
    /// `target` by creating it exclusively (it fails when anything has the
    /// name), closes it, and renames `file` over it. No file that was there
    /// before is replaced, and of two conversions only one creates the name.
    /// - Returns: true when `file` now has the name `target`; false when
    ///   the name is taken, so the caller tries the next.
    /// - Throws: `failure` when the name cannot be reserved or the rename
    ///   fails (the reservation is then removed).
    private static func renamingOverReservation(of file: URL, to target: URL, failure: Failure) throws -> Bool {
        let descriptor = open(target.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard descriptor >= 0 else {
            if errno == EEXIST { return false }
            throw failure
        }
        close(descriptor)
        guard rename(file.path, target.path) == 0 else {
            // Only the empty reservation made above is removed.
            unlink(target.path)
            throw failure
        }
        return true
    }

    /// Converts each of `sources` as `convert(_:naming:)` does, at most
    /// `maximumConcurrentConversions` at once, telling `progress` how many
    /// are done as each ends. The conversions are returned in the order of
    /// `sources`. Should one fail, the others are stopped, every file
    /// already converted is removed, and its error is thrown.
    static func convertEach(
        _ sources: [URL],
        naming: Bool = true,
        using tool: Tool = .afconvert,
        progress: (@Sendable (Int) -> Void)? = nil
    ) async throws -> [Conversion] {
        var results = [Conversion?](repeating: nil, count: sources.count)
        do {
            try await withThrowingTaskGroup(of: (Int, Conversion).self) { group in
                var next = 0
                // The first few start at once; each one that ends starts
                // the next, so at most the maximum run together.
                while next < min(maximumConcurrentConversions, sources.count) {
                    let index = next
                    group.addTask { (index, try await convert(sources[index], naming: naming, using: tool)) }
                    next += 1
                }
                var done = 0
                do {
                    while let (index, conversion) = try await group.next() {
                        if results.indices.contains(index) { results[index] = conversion }
                        done += 1
                        progress?(done)
                        if next < sources.count {
                            let index = next
                            group.addTask { (index, try await convert(sources[index], naming: naming, using: tool)) }
                            next += 1
                        }
                    }
                } catch {
                    // The conversions still running stop; any that finished
                    // meanwhile are kept to be removed below.
                    group.cancelAll()
                    while !group.isEmpty {
                        if let (index, conversion) = try? await group.next(), results.indices.contains(index) {
                            results[index] = conversion
                        }
                    }
                    throw error
                }
            }
        } catch {
            discard(results.compactMap { $0 })
            throw error
        }
        return results.compactMap { $0 }
    }

    /// Removes the converted files of `conversions`, leaving their sources.
    static func discard(_ conversions: [Conversion]) {
        for conversion in conversions {
            try? FileManager.default.removeItem(at: conversion.converted)
        }
    }

    /// Removes the files an interrupted conversion left under their hidden
    /// temporary names anywhere in `folder`, so a book converted again
    /// starts clean.
    static func removeLeftovers(in folder: URL) {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in enumerator where file.lastPathComponent.hasPrefix(".")
            && file.lastPathComponent.hasSuffix(temporarySuffix) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// About how many bytes `sources` take once converted: each one's length
    /// at the bit rate it would be written at (`target(for:bytes:)`), with
    /// a hundredth more and 64 KB for the file's own tables, or its own size
    /// when it can't be read. Reads only each file's header; never decodes.
    static func estimatedSize(of sources: [URL]) async -> Int64 {
        var total: Int64 = 0
        for source in sources {
            let bytes = fileSize(of: source)
            guard let info = inspect(source) else {
                total += bytes
                continue
            }
            let channels = min(max(info.channels, 1), 2)
            let bitRate = Double(target(for: info, bytes: bytes).bitRate ?? AudioRenderSettings.bitRatePerChannel * channels)
            total += Int64((info.duration * bitRate / 8 * 1.01).rounded(.up)) + 65_536
        }
        return total
    }

    // MARK: - A Book's Tracks

    /// Renames each converted track of the book whose folder of tracks is
    /// `folder` in the folder's manifest, wherever the reader finds it,
    /// inside the folder's one folder too (`AudioManifestLocation`), each
    /// spelled as the manifest spells it: its tracks, order, chapter titles,
    /// and sections' clips (`BookManifestFile.renameTrack`). All of them
    /// are renamed in one write, through the one write of a manifest
    /// (`BookManifestFile.change`), which tells an Edit Manifest session of
    /// the book `bookID`, as the audio editor renames a track it renders to
    /// .m4a. A folder without a manifest is left as it is.
    static func renameTracks(of conversions: [Conversion], inManifestOf folder: URL, bookID: UUID?) throws {
        guard !conversions.isEmpty, let location = AudioManifestLocation.find(in: folder) else { return }
        try BookManifestFile.change(manifestAt: location, of: bookID) { object in
            for conversion in conversions {
                BookManifestFile.renameTrack(
                    location.name(ofTrackAt: AudioBookParser.relativeName(of: conversion.source, in: folder)),
                    to: location.name(ofTrackAt: AudioBookParser.relativeName(of: conversion.converted, in: folder)),
                    in: &object
                )
            }
        }
    }

    /// Removes the Ogg files `conversions` were made from, once their
    /// converted files have taken their places.
    static func removeSources(of conversions: [Conversion]) throws {
        for conversion in conversions {
            try FileManager.default.removeItem(at: conversion.source)
        }
    }

    /// The size of the file at `url` in bytes, or 0 when it can't be read.
    static func fileSize(of url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }
}
