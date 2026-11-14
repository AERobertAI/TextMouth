import AVFoundation
import Darwin

/// Converts the audio the import converts to an .m4a file beside it, so
/// TextMouth never hands such a source to a player or decoder. Ogg (Vorbis
/// or Opus, in .ogg, .oga, or .opus files) was the first format (B06);
/// `convertedExtensions` lists them all (FMT09).
///
/// A lossy source (Ogg, AC-3, AMR, MP2, and the like) becomes AAC-LC; a
/// lossless one (PCM, ALAC, FLAC) becomes Apple Lossless, which loses
/// nothing (`Plan`, `plan(for:info:)`). The source is read by `afinfo` and
/// converted by `afconvert`, both from the Mac itself (the app's oldest
/// macOS is 14.0): a format that Mac cannot read or convert is refused by
/// the file's name ("Converting its audio" stops the import, and nothing is
/// left behind); no other check is needed.
///
/// On October 14, 2026 Apple's Vorbis decoder, playing an Ogg track through
/// AVPlayer at 1.5x, locked up inside AudioToolbox and grew TextMouth to
/// 34 GB until the Mac ran out of memory. The same decoder then froze every
/// conversion that decoded Ogg inside TextMouth with AVAssetReader (B09), and
/// no in-process call can be stopped once it spins. So TextMouth never
/// decodes such audio itself: it runs Apple's own `/usr/bin/afconvert` as a
/// child process (`WatchedProcess`), which a watchdog kills when it runs too
/// long, holds too much memory, or stops writing (`ConversionLimits`). All
/// that TextMouth reads of an Ogg file is its first and last bytes, parsed
/// by hand (`OggHeaderReader`, through `inspect(_:)`), with no Apple audio
/// API.
///
/// AAC is written at the source's own average bit rate rounded up to the
/// next standard AAC rate (`bitRate(averaging:channels:accepted:)`), so a
/// track keeps about its size and loses as little as a second lossy encoding
/// can (it can lose a little, even at a higher rate: which is why a lossless
/// source becomes Apple Lossless instead). A file is written under a hidden
/// temporary name, checked by `AudioMediaProbe` (which decodes the .m4a,
/// never the source: it plays, and lasts as long as its source to within
/// `lengthTolerance`), and only then given its final name: the source's
/// stem with .m4a, made unique when taken.
enum ImportAudioConverter {
    /// The extensions of Ogg audio, in lowercase: Vorbis's, the Ogg audio
    /// container's, and Opus's.
    static let oggExtensions: Set<String> = ["ogg", "oga", "opus"]

    /// The extensions, in lowercase, of the formats macOS decodes that the
    /// import converts (FMT09): the coded ones (AC-3 and Enhanced AC-3, MP1
    /// and MP2, AMR, 3GPP audio, and CAF's, AIFC's, and AU's compressed
    /// forms), so that Apple's rarer decoders stay out of the player; and the
    /// containers that hold PCM as often as coded audio (AIFC, CAF, AU, Wave64,
    /// whose extension says nothing of what is inside), so that the reader
    /// guards can decide by extension alone. The extensions TextMouth already
    /// plays (mp3, m4a, wav, aiff, flac, and the rest of `BookFormat.audio`)
    /// are not here.
    static let coreAudioExtensions: Set<String> = [
        "aifc", "caf", "au", "snd", "w64", "ac3", "ec3", "eac3", "mp1", "mp2", "mpa", "amr", "awb", "3gp", "3g2", "3ga",
    ]

    /// The extensions, in lowercase, of every audio format the import
    /// converts (FMT09): Ogg's and `coreAudioExtensions`.
    static let convertedExtensions: Set<String> = oggExtensions.union(coreAudioExtensions)

    /// The extensions, in lowercase, of files TextMouth writes itself from
    /// its own samples with Apple's encoder and reads back in the app: a
    /// recording's take (`BookOrigin.originalTakeFileName`) and the audio
    /// editor's takes and passes (`AudioEditPackage`,
    /// `AudioFilterProcessor`) are CAF. An imported CAF is converted at
    /// import like every other format in `convertedExtensions`, so no CAF
    /// from outside ever reaches a reader.
    static let ownWorkingExtensions: Set<String> = ["caf"]

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
    static let temporarySuffix = ".audio-conversion.m4a"

    /// The suffix before October 18, 2026 (when the converter took every
    /// format the import converts): still recognized, so a leftover from an
    /// earlier version is removed (`isTemporaryName(_:)`).
    static let legacyTemporarySuffix = ".ogg-conversion.m4a"

    /// What ends the hidden name of the stereo PCM file that step 1 of a
    /// downmix writes (`downmixURL(beside:)`), a suffix of its own so that
    /// `isTemporaryName(_:)` knows it: `removeLeftovers(in:)` and the
    /// orphaned-converter sweep find it as they find the .m4a.
    static let downmixSuffix = ".audio-downmix.caf"

    /// The free space a downmix leaves on the volume beyond its stereo PCM
    /// file: 512 MB, for the .m4a written next and for the rest of the
    /// system (`downmixBytesNeeded(duration:target:)`).
    static let downmixReserveBytes: Int64 = 512 * 1_048_576

    /// The longest file name, in UTF-16 code units, that every supported
    /// file system accepts (exFAT and HFS+ count units; APFS counts
    /// characters, so it accepts at least as much).
    static let maximumNameLength = 255

    /// The standard AAC bit rates of stereo audio, in bits a second; mono's
    /// are half of each (`standardBitRates(channels:)`).
    static let stereoBitRates = [64_000, 80_000, 96_000, 112_000, 128_000, 160_000, 192_000]

    /// One file converted: where it came from and went, and what that took.
    struct Conversion: Equatable, Sendable {
        /// The source file, which a conversion never changes or removes.
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
        /// The audio file could not be read as audio, or is only in the cloud.
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
        /// The volume holds too little free space for the stereo PCM file of
        /// a downmix and the room to spare (`downmixBytesNeeded`); nothing
        /// was run. `bytesNeeded` is the free space it needs.
        case notEnoughSpace(fileName: String, bytesNeeded: Int64)
        /// The file has `channels` channels (more than two) and does not say
        /// which is which, so a mix to stereo would keep two arbitrary
        /// channels, often not the speech. Nothing was run.
        case unlabelledChannels(fileName: String, channels: Int)

        var errorDescription: String? {
            switch self {
            case let .unreadable(fileName):
                return "The audio file \(fileName) could not be read for converting."
            case let .checkFailed(fileName, reason):
                return "The audio converted from \(fileName) failed its check: \(reason)."
            case let .cannotName(fileName):
                return "The audio converted from \(fileName) could not be given its name."
            case let .killed(fileName, reason):
                return "Converting \(fileName) was stopped because \(reason)."
            case let .processFailed(fileName, status):
                return "Converting \(fileName) failed (the converter ended with code \(status))."
            case let .notEnoughSpace(fileName, bytesNeeded):
                return "There is not enough free disk space to convert \(fileName): "
                    + "it needs \(ImportProgressWording.size(bytesNeeded)) free."
            case let .unlabelledChannels(fileName, channels):
                return "The audio file \(fileName) has \(channels) channels but does not say which is which, "
                    + "so TextMouth cannot mix it to stereo."
            }
        }
    }

    // MARK: - Which Files

    /// Whether the file at `url` is Ogg audio, by its extension in any case.
    static func isOgg(_ url: URL) -> Bool {
        oggExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether the extension of the file at `url`, in any case, is one of
    /// `convertedExtensions`. This is the extension's answer alone: at import
    /// the content decides as well (`verdict(for:)`, `needsConversion(among:using:)`),
    /// since a file's extension may say .mp3 or .m4a of an MP2 or Ogg file.
    /// It still answers where the name settles a file at no cost
    /// (`metadataAsset`, which asks it before it reads a file's first bytes
    /// for the Ogg signature) and what `verdict(for:)` counts first.
    static func isConvertedAtImport(_ url: URL) -> Bool {
        convertedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Whether no reader may decode the file at `url`: the import converts
    /// it by its extension, and it is not a file of TextMouth's own making
    /// (`ownWorkingExtensions`); or it starts with "OggS", whatever its
    /// extension, so an old book's misnamed Ogg file is never opened in the
    /// app. This is the question every reader guard asks before Apple's
    /// decoder sees a file, some on the main thread: it costs one open and
    /// four bytes, of a regular file that is not only in the cloud
    /// (`AudioContentSniffer.isOgg(at:)`), and is not reached for a name the
    /// extension settles.
    static func isNeverDecodedInApp(_ url: URL) -> Bool {
        if isConvertedAtImport(url), !ownWorkingExtensions.contains(url.pathExtension.lowercased()) { return true }
        return AudioContentSniffer.isOgg(at: url) // lint-ok: this is the guard itself, adding the Ogg content check to the extension's
    }

    /// The tracks of the folder `folder` that the import converts whatever
    /// their extension and wherever the bytes alone settle it
    /// (`verdict(for:)` is `.convert`), found by the reader's own rules. A
    /// track the bytes leave open (MPEG-4, unknown content) is not listed: it
    /// needs `afinfo`, which `needsConversion(among:using:)` asks.
    static func filesToConvert(in folder: URL) -> [URL] {
        tracks(in: folder) { verdict(for: $0) == .convert }
    }

    // MARK: - Which Files, by Content

    /// What the import does about the file at `url`, going by its extension
    /// and its first bytes (`AudioContentSniffer`): `.convert` when the
    /// extension is one the import converts or the bytes are of a format it
    /// converts (a file is converted whatever it is named, and the guards
    /// refuse a converted extension all the same); `.leave` when the bytes
    /// are of a format TextMouth plays; `.askAfinfo` when they do not settle
    /// it (MPEG-4, QuickTime, unrecognized or unreadable content).
    static func verdict(for url: URL) -> AudioContentSniffer.Verdict {
        if isConvertedAtImport(url) { return .convert }
        return AudioContentSniffer.verdict(for: AudioContentSniffer.kind(of: url))
    }

    /// Whether a file that `afinfo` describes by `formatID` (its first
    /// track's codec) and `fileType` (its container) plays as it is: AAC
    /// (`aac `, `aach`, `aacp`) in MPEG-4, QuickTime, or ADTS; Apple Lossless
    /// (`alac`) in MPEG-4 or QuickTime; MP3 (`.mp3`) in MPEG audio, MPEG-4,
    /// or QuickTime. Every other codec or container is converted. A nil
    /// `fileType` (the container is not known) asks about the codec alone.
    static func playsAsIs(formatID: String, fileType: String?) -> Bool {
        let mpeg4Containers: Set<String> = ["m4af", "m4bf", "mp4f", "qt", "moov"]
        let containers: Set<String>
        switch formatID.trimmingCharacters(in: .whitespaces) {
        case "aac", "aach", "aacp": containers = mpeg4Containers.union(["adts"])
        case "alac": containers = mpeg4Containers
        case ".mp3": containers = mpeg4Containers.union(["mpg3"])
        default: return false
        }
        guard let fileType else { return true }
        return containers.contains(fileType.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// The files among `files` that the import converts, in their order: by
    /// their extension and bytes (`verdict(for:)`), and, for those the bytes
    /// leave open, by what `afinfo` names (`playsAsIs(formatID:fileType:)`),
    /// at most `maximumConcurrentConversions` asked at once. A file `afinfo`
    /// cannot read is left as it is: `afconvert` could not convert it either,
    /// and the probe refuses it as before.
    /// - Throws: `CancellationError` only.
    static func needsConversion(among files: [URL], using tool: AudioFileInfo.Tool = .afinfo) async throws -> [URL] {
        let verdicts = files.map(verdict(for:))
        var converts = verdicts.map { $0 == .convert }
        let undecided = verdicts.indices.filter { verdicts[$0] == .askAfinfo }
        // Ask afinfo about the open ones, one group of the maximum at a time.
        for start in stride(from: 0, to: undecided.count, by: maximumConcurrentConversions) {
            let group = undecided[start..<min(start + maximumConcurrentConversions, undecided.count)]
            let answers = try await withThrowingTaskGroup(of: (Int, Bool).self, returning: [(Int, Bool)].self) { tasks in
                for index in group {
                    let file = files[index]
                    tasks.addTask { (index, try await isConvertedByWhatItHolds(file, using: tool)) }
                }
                var results: [(Int, Bool)] = []
                for try await answer in tasks { results.append(answer) }
                return results
            }
            for (index, answer) in answers { converts[index] = answer }
        }
        return zip(files, converts).filter(\.1).map(\.0)
    }

    /// Whether `afinfo` names, for the file at `url`, a codec or container
    /// that the import converts; false when it cannot read the file.
    private static func isConvertedByWhatItHolds(_ url: URL, using tool: AudioFileInfo.Tool) async throws -> Bool {
        guard let facts = try await AudioFileInfo.read(url, using: tool) else { return false }
        return !playsAsIs(formatID: facts.formatID, fileType: facts.fileType)
    }

    /// The tracks of the folder `folder` that the import converts, by
    /// extension and content, `needsConversion(among:using:)` deciding the
    /// ones the bytes leave open.
    /// - Throws: `CancellationError` only.
    static func tracksNeedingConversion(in folder: URL, using tool: AudioFileInfo.Tool = .afinfo) async throws -> [URL] {
        try await needsConversion(among: tracks(in: folder) { _ in true }, using: tool)
    }

    /// The Ogg files among the tracks of the folder `folder` (the library's
    /// conversion of Ogg books uses it), found like `filesToConvert(in:)`.
    static func oggFiles(in folder: URL) -> [URL] {
        tracks(in: folder, where: isOgg) // lint-ok: selects the Ogg tracks the library converts alone, opening no reader
    }

    /// The tracks of `folder` that `accepts`, found by the reader's own
    /// rules (`AudioBookParser.audioFiles(in:)`: wrapper folders count;
    /// hidden files, AppleDouble sidecars, and symbolic links do not), in
    /// Finder's order; none when the folder can't be read.
    private static func tracks(in folder: URL, where accepts: (URL) -> Bool) -> [URL] {
        ((try? AudioBookParser.audioFiles(in: folder, scan: .importing)) ?? []).filter(accepts)
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
    /// track keeps about its size and loses as little as it can. Where the encoder
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

    /// What the converter knows of a source before it converts it: read from
    /// an Ogg file's own bytes (`OggHeaderReader`) or from `afinfo` in a
    /// watched child process (`AudioFileInfo`), never by decoding a sample in
    /// the app (`inspect(_:)`).
    struct SourceInfo: Equatable, Sendable {
        /// The sample rate, in hertz.
        let sampleRate: Double
        /// The number of channels.
        let channels: Int
        /// How long it lasts, in seconds, as the container says.
        let duration: TimeInterval
        /// The codec: "vorbis" or "opus" for Ogg, otherwise afinfo's format
        /// ("lpcm", "alac", "flac", "ac-3", "samr", ".mp2", "ima4", ...).
        let formatID: String
        /// The bits in a sample of PCM, or of the source a lossless codec
        /// kept; nil for floating-point PCM and for lossy codecs.
        let bitsPerSample: Int?
        /// Whether the codec keeps every bit of its source (PCM, ALAC, FLAC),
        /// so the import writes Apple Lossless rather than AAC.
        let isLossless: Bool
        /// Whether the file says which channel is which. Always true for an
        /// Ogg file, whose channel order its specification fixes, and for
        /// mono and stereo; false only for a file of more than two channels
        /// that gives no layout (`AudioFileInfo.hasChannelLayout`), which
        /// cannot be mixed to stereo (`Failure.unlabelledChannels`).
        var hasChannelLayout = true
    }

    /// What the import does with one audio file.
    enum Plan: Equatable, Sendable {
        /// The file is of a format TextMouth plays as it is.
        case leaveAsItIs
        /// A lossy source is encoded as AAC-LC in an .m4a file.
        case convertToAAC
        /// A lossless source is written as Apple Lossless in an .m4a file.
        case convertToAppleLossless
    }

    /// What the import does with `source`, described by `info`: nothing for
    /// a file it plays as it is, Apple Lossless for a lossless source
    /// (nothing is lost), AAC for any other. The file is converted when its
    /// extension is one the import converts, when its bytes are of a format
    /// it converts, or when its bytes leave it open (MPEG-4, QuickTime, or
    /// unrecognized content) and `info`'s codec is not one it plays
    /// (`playsAsIs(formatID:fileType:)`), as `needsConversion(among:using:)`
    /// decides. A file whose bytes cannot be read is judged by its extension
    /// alone.
    static func plan(for source: URL, info: SourceInfo) -> Plan {
        var converts = isConvertedAtImport(source)
        if !converts {
            let kind = AudioContentSniffer.kind(of: source)
            switch AudioContentSniffer.verdict(for: kind) {
            case .convert: converts = true
            case .leave: converts = false
            case .askAfinfo:
                // Like needsConversion(among:), the codec decides MPEG-4 and unrecognized
                // content; a file that cannot be read at all keeps its extension's answer.
                let isReadable = AudioContentSniffer.firstBytes(of: source, upTo: 1) != nil
                converts = isReadable && !playsAsIs(formatID: info.formatID, fileType: nil)
            }
        }
        guard converts else { return .leaveAsItIs }
        return info.isLossless ? .convertToAppleLossless : .convertToAAC
    }

    /// The sample rate, channels, length, and codec of the file at `url`. An
    /// Ogg file's come from its own bytes by `OggHeaderReader` (REV17a); any
    /// other file's from `afinfo` in a child process (`AudioFileInfo`). No
    /// Apple audio API opens the file in this process, so neither AudioFile's
    /// demuxer nor Apple's Vorbis decoder ever runs in TextMouth. Nil when
    /// the file isn't there, is only in the cloud, or can't be read as audio.
    /// - Parameter afinfo: what runs afinfo: Apple's tool in a watched
    ///   child, unless a test of a lying header stands in for it.
    /// - Throws: `CancellationError` only.
    static func inspect(_ url: URL, using afinfo: AudioFileInfo.Tool = .afinfo) async throws -> SourceInfo? {
        guard FileManager.default.fileExists(atPath: url.path), !DatalessFiles.isDataless(url) else { return nil }
        if isOgg(url) { // lint-ok: Ogg alone is read from its own bytes; every other format by afinfo
            guard let header = OggHeaderReader.read(at: url) else { return nil }
            return SourceInfo(
                sampleRate: header.sampleRate, channels: header.channels, duration: header.duration,
                formatID: formatID(of: header.codec), bitsPerSample: header.bitsPerSample,
                // FLAC keeps every bit of its source, so it becomes Apple Lossless; Vorbis and Opus are lossy.
                isLossless: header.codec == .flac
            )
        }
        guard let facts = try await AudioFileInfo.read(url, using: afinfo) else { return nil }
        return SourceInfo(
            sampleRate: facts.sampleRate, channels: facts.channels, duration: facts.duration,
            formatID: facts.formatID, bitsPerSample: facts.bitsPerSample, isLossless: facts.isLossless,
            hasChannelLayout: facts.hasChannelLayout
        )
    }

    /// The format an Ogg stream's codec is known by in `SourceInfo`, as
    /// afinfo would name it; a switch, so that a codec the header reader
    /// learns must be named here too.
    private static func formatID(of codec: OggHeaderReader.Codec) -> String {
        switch codec {
        case .vorbis: return "vorbis"
        case .opus: return "opus"
        case .flac: return "flac"
        }
    }

    /// The most channels TextMouth writes, AAC or Apple Lossless: two. A
    /// source of more is mixed down to stereo (`needsDownmix(_:)`).
    static let maximumChannels = 2

    /// Whether the source described by `info` has more channels than
    /// TextMouth writes, so it is converted in two steps (`downmixArguments`,
    /// then `afconvertArguments`).
    static func needsDownmix(_ info: SourceInfo) -> Bool {
        info.channels > maximumChannels
    }

    /// The Apple Lossless bit depth that holds a source of `bits` bits a
    /// sample: 16, 20, 24, or 32, the smallest that fits; 24 when the depth
    /// is unknown or the samples are floating-point numbers (nil).
    static func appleLosslessBitDepth(forBitsPerSample bits: Int?) -> Int {
        guard let bits else { return 24 }
        switch bits {
        case ...16: return 16
        case ...20: return 20
        case ...24: return 24
        default: return 32
        }
    }

    /// The flag afconvert takes after `alac/` for an Apple Lossless bit
    /// depth: 1, 2, 3, or 4 for 16, 20, 24, or 32 bits. Without it afconvert
    /// writes 32-bit samples, five times the size of a 16-bit source's.
    static func appleLosslessFlag(forBitDepth depth: Int) -> Int {
        switch depth {
        case 16: return 1
        case 20: return 2
        case 24: return 3
        default: return 4
        }
    }

    /// How a source described by `info`, a file of `bytes` bytes, is written.
    /// TextMouth writes at most two channels: an audiobook is one listening
    /// stream, and a film's or a radio drama's dialogue lives in the centre
    /// channel, which a stereo mix puts in both ears on every path (the
    /// player, the editor, transcription, MP3 export). A source of more than
    /// two channels, lossy or lossless, is mixed down to stereo
    /// (`downmixArguments`); mono and stereo are written as they are. A lossy
    /// source becomes AAC-LC at its channels (two at most), its own sample
    /// rate where AAC takes it (`sampleRate(for:)`), and its average bit
    /// rate, bytes × 8 ÷ duration, rounded up to the next standard rate of
    /// stereo (or mono). A lossless source (`appleLosslessBitDepth` set)
    /// becomes Apple Lossless at its own rate and channels (two at most),
    /// with no bit rate.
    struct Target: Equatable, Sendable {
        /// The channels written: one or two, for AAC and Apple Lossless
        /// alike.
        let channels: Int
        /// The sample rate written, in hertz.
        let sampleRate: Double
        /// The bit rate written, in bits a second; nil when the encoder
        /// chooses, and always nil for Apple Lossless.
        let bitRate: Int?
        /// The bit depth of Apple Lossless samples; nil means AAC.
        var appleLosslessBitDepth: Int? = nil
    }

    /// The `Target` for `info` and `bytes`; see `Target`.
    static func target(for info: SourceInfo, bytes: Int64) -> Target {
        if info.isLossless {
            return Target(
                channels: min(max(info.channels, 1), maximumChannels),
                sampleRate: info.sampleRate,
                bitRate: nil,
                appleLosslessBitDepth: appleLosslessBitDepth(forBitsPerSample: info.bitsPerSample)
            )
        }
        let channels = min(max(info.channels, 1), maximumChannels)
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
    /// rate, with the sample rate (`-d aac@rate`) only where it differs from
    /// the source's, or of Apple Lossless (`-d alac/<flag>`,
    /// `appleLosslessFlag`) at the source's rate. The channel count is never
    /// passed (`-c`): afconvert refuses it for AAC above stereo and for
    /// Apple Lossless above eight channels ("ExtAudioFileSetProperty
    /// ('cclo') failed"), so a source of more than two channels is first
    /// mixed down to a stereo PCM file (`downmixArguments`), and this is
    /// called with that file as `input`.
    static func afconvertArguments(from input: URL, to output: URL, info: SourceInfo, target: Target) -> [String] {
        if let depth = target.appleLosslessBitDepth {
            return ["-f", "m4af", "-d", "alac/\(appleLosslessFlag(forBitDepth: depth))", input.path, output.path]
        }
        var format = "aac"
        if target.sampleRate != info.sampleRate { format += "@\(Int(target.sampleRate))" }
        var arguments = ["-f", "m4af", "-d", format]
        if let bitRate = target.bitRate { arguments += ["-b", String(bitRate)] }
        return arguments + [input.path, output.path]
    }

    /// The bit depth of the stereo PCM file that step 1 of a downmix writes
    /// for `target`: 16 bits for AAC, which keeps no more; for Apple
    /// Lossless the depth of its samples, 24 for a depth of 20 (PCM has no
    /// 20-bit form), so nothing is lost.
    static func downmixBitDepth(for target: Target) -> Int {
        guard let depth = target.appleLosslessBitDepth else { return 16 }
        return depth == 20 ? 24 : depth
    }

    /// The free space a downmix of a track lasting `duration` seconds,
    /// written as `target`, needs on the volume: the stereo PCM file of
    /// step 1 (duration × sample rate × two channels × bytes a sample,
    /// uncompressed, so a long track's file is large) and the reserve
    /// (`downmixReserveBytes`). The length and the rate are capped as an
    /// output cap's are (`cappedSeconds(_:)`, `cappedSampleRate(_:)`), so
    /// no header can overflow the count.
    static func downmixBytesNeeded(duration: TimeInterval, target: Target) -> Int64 {
        let frames = Int64((cappedSeconds(duration) * cappedSampleRate(target.sampleRate)).rounded())
        return frames * Int64(maximumChannels) * Int64(downmixBitDepth(for: target) / 8) + downmixReserveBytes
    }

    /// The two processes a conversion can run, for the cap on what each may
    /// write.
    enum Step: Equatable, Sendable {
        /// Step 1 of a downmix: stereo linear PCM in a CAF.
        case downmix
        /// The encoder: AAC or Apple Lossless in an .m4a.
        case encode
    }

    /// The bit rate the cap assumes where the AAC encoder chooses its own
    /// (`Target.bitRate` is nil): 320,000 bits a second, the most it writes.
    static let encoderChosenBitRate = 320_000

    /// A cap, or the free space a downmix needs, never counts a track
    /// longer than this many seconds or a sample rate above
    /// `maximumCappedSampleRate`, so a lying header cannot overflow the
    /// arithmetic (`AudioFileInfo` already refuses lengths over a year, and
    /// `convert` refuses a rate above `maximumCappedSampleRate`).
    private static let maximumCappedSeconds: Double = 366 * 24 * 3_600
    private static let maximumCappedSampleRate: Double = 10_000_000

    /// `duration` as the size arithmetic (an output cap, a downmix's free
    /// space) counts it: from 0 to `maximumCappedSeconds`, and 0 when it is
    /// not a finite number.
    private static func cappedSeconds(_ duration: TimeInterval) -> Double {
        duration.isFinite ? min(max(duration, 0), maximumCappedSeconds) : 0
    }

    /// `sampleRate` as the size arithmetic (an output cap, a downmix's free
    /// space) counts it: from 0 to `maximumCappedSampleRate`, and 0 when it
    /// is not a finite number.
    private static func cappedSampleRate(_ sampleRate: Double) -> Double {
        sampleRate.isFinite ? min(max(sampleRate, 0), maximumCappedSampleRate) : 0
    }

    /// How many bytes `step` is expected to write for a track lasting
    /// `duration` seconds, converted as `target`: AAC, duration × bit rate ÷
    /// 8 (`encoderChosenBitRate` where the encoder chooses); Apple Lossless
    /// and the downmix's PCM, duration × rate × channels × bytes a sample
    /// (`downmixBitDepth(for:)`; two channels for the PCM). Uncompressed
    /// size is the most Apple Lossless can take.
    static func expectedOutputBytes(of step: Step, duration: TimeInterval, target: Target) -> Int64 {
        let seconds = cappedSeconds(duration)
        let rate = cappedSampleRate(target.sampleRate)
        let bytesPerSample = Double(downmixBitDepth(for: target) / 8)
        switch step {
        case .downmix:
            return Int64(seconds * rate * Double(maximumChannels) * bytesPerSample)
        case .encode where target.appleLosslessBitDepth != nil:
            return Int64(seconds * rate * Double(target.channels) * bytesPerSample)
        case .encode:
            return Int64(seconds * Double(target.bitRate ?? encoderChosenBitRate) / 8)
        }
    }

    /// The most a step may write before the watchdog and the kernel stop it:
    /// four times what it is expected to write, and 16 MB more
    /// (`outputCapReserveBytes`), so a header that lies about a file's length
    /// cannot fill the disk.
    static func outputCap(of step: Step, duration: TimeInterval, target: Target) -> Int64 {
        expectedOutputBytes(of: step, duration: duration, target: target) * 4 + outputCapReserveBytes
    }

    /// The bytes added to four times a step's expected output to make its cap.
    static let outputCapReserveBytes: Int64 = 16 * 1_048_576

    /// The bytes free on the volume that holds `folder` for TextMouth's use
    /// (`volumeAvailableCapacityForImportantUsageKey`, which counts space the
    /// system can purge); nil when the volume can't say.
    static func availableBytes(on folder: URL) -> Int64? {
        (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    /// The arguments of afconvert for step 1 of a downmix: writing `input`,
    /// a source of more than two channels in any layout, to `output`, a
    /// CAF of stereo linear PCM (`-f caff -d LEI<bits>@<rate> -c 2`) at the
    /// bit depth (`downmixBitDepth(for:)`) and the sample rate `target`
    /// writes, so step 2 changes neither. Measured on macOS 26.3.1:
    /// afconvert mixes 3.0 and 5.1 AC-3, 5.1 E-AC-3, and a 10-channel
    /// Wave64 down to stereo PCM in this one step, where it refuses `-c 2`
    /// with the AAC and Apple Lossless encoders themselves.
    ///
    /// `--mix` is essential: without it `-c` "adds or removes channels
    /// without regard to order", and a 5.1 PCM source whose dialogue is in
    /// the centre channel came out silent in both channels (-93 dBFS
    /// against the centre's -21 dBFS); with it both channels carry the
    /// centre, 10.7 dB down (the normalized ITU downmix). AC-3 and E-AC-3
    /// are mixed by their own decoder either way. A PCM source with no
    /// channel layout cannot be mixed: afconvert keeps its first two
    /// channels, so `convert` refuses it first (`Failure.unlabelledChannels`).
    /// These arguments are in this one function so that the mix
    /// can be changed in one place.
    static func downmixArguments(from input: URL, to output: URL, target: Target) -> [String] {
        [
            "-f", "caff", "-d", "LEI\(downmixBitDepth(for: target))@\(Int(target.sampleRate))",
            "-c", String(maximumChannels), "--mix", input.path, output.path,
        ]
    }

    // MARK: - The Converting Process

    /// What runs a conversion, and what watches it: afconvert under the
    /// watchdog's rules in the app, replaced in tests by a stand-in child
    /// (a `sleep`, or a script that writes slowly) and tight limits.
    struct Tool: Sendable {
        /// The executable and arguments that write `output` from `input`.
        var command: @Sendable (_ input: URL, _ output: URL, _ info: SourceInfo, _ target: Target)
            -> (executable: URL, arguments: [String])
        /// The executable and arguments that write `output`, a CAF of stereo
        /// PCM, from `input`, a source of more than two channels: step 1 of
        /// a downmix. Afconvert's by default; a test's stand-in replaces it
        /// together with `command`, so it drives each step.
        var downmixCommand: @Sendable (_ input: URL, _ output: URL, _ target: Target)
            -> (executable: URL, arguments: [String]) = { input, output, target in
                (URL(fileURLWithPath: "/usr/bin/afconvert"), downmixArguments(from: input, to: output, target: target))
            }
        /// The bytes free on the volume that holds the given folder, or nil
        /// when unknown (the conversion then goes on). The real reading by
        /// default; a test replaces it.
        var availableBytes: @Sendable (_ folder: URL) -> Int64? = { ImportAudioConverter.availableBytes(on: $0) }
        /// What reads the facts of a source that is not Ogg before it is
        /// converted (`inspect(_:using:)`): afinfo in a watched child by
        /// default. It is here for tests of lying headers, whose stand-in
        /// prints the facts such a header states.
        var info: AudioFileInfo.Tool = .afinfo
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
    /// ".<UUID>.audio-conversion.m4a", beside `source`. It is built from the
    /// UUID alone, 58 characters whatever the source's name, so a source
    /// with a long stem (up to the file system's limit) can still be
    /// converted; the UUID makes it unique, and `removeLeftovers(in:)` finds
    /// it by `temporarySuffix`.
    static func temporaryURL(beside source: URL) -> URL {
        source.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)\(temporarySuffix)")
    }

    /// The hidden name of the stereo PCM file that step 1 of a downmix
    /// writes: ".<UUID>.audio-downmix.caf", beside `source` for the same
    /// reason as `temporaryURL(beside:)`.
    static func downmixURL(beside source: URL) -> URL {
        source.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString)\(downmixSuffix)")
    }

    /// Converts `source`, a file the import converts, to AAC or Apple
    /// Lossless (`target(for:bytes:)`) in an .m4a file beside it,
    /// under a hidden temporary name, and checks the result: it must play,
    /// and last as long as the source to within `allowedLengthError(for:)`.
    /// With `naming`, it then gets its final name (`givingFinalName(_:)`);
    /// without, it keeps the temporary one, for a caller that names a whole
    /// book's files in one step. A source of more than two channels is
    /// converted in two steps through a hidden stereo PCM file
    /// (`write(_:to:info:target:using:)`). The source is never changed, and
    /// nothing is left behind by a failure. Nothing is downloaded: a file only in
    /// the cloud is refused. A source whose header cannot be read, or states
    /// a sample rate that is no finite number or is above
    /// `maximumCappedSampleRate`, is refused as unreadable before anything
    /// runs. The conversion runs in a child process the
    /// watchdog of `tool` kills when it hangs (`AUDIO_CONVERSION_KILLED` in the
    /// debug log).
    /// - Throws: `Failure`, or `CancellationError` when the task is
    ///   cancelled.
    static func convert(_ source: URL, naming: Bool = true, using tool: Tool = .afconvert) async throws -> Conversion {
        let started = Date()
        let name = source.lastPathComponent
        guard let info = try await inspect(source, using: tool.info) else {
            #if os(iOS)
            // iOS has no afinfo, so `inspect` has no answer for any format but
            // Ogg, and every file reaching this line is one the import would
            // convert. It is not unreadable: the phone cannot convert it, and
            // says so as Ogg's refusal does, in `WatchedProcess.run`.
            throw IOSUnavailable.feature("Converting this kind of file")
            #else
            throw Failure.unreadable(fileName: name)
            #endif
        }
        // A header can state any sample rate. One that is no number, or past
        // the most a cap counts, is a damaged header, refused as an
        // unreadable one is before the target is worked out from it: a
        // lossless target keeps the source's rate, and the downmix's
        // arguments turn it into whole hertz (`Int(_:)`), which traps there.
        guard info.sampleRate.isFinite, info.sampleRate <= maximumCappedSampleRate else {
            throw Failure.unreadable(fileName: name)
        }
        // Without a layout afconvert keeps the first two channels, and the speech is often the third.
        if needsDownmix(info), !info.hasChannelLayout {
            throw Failure.unlabelledChannels(fileName: name, channels: info.channels)
        }
        let bytesBefore = fileSize(of: source)
        let target = target(for: info, bytes: bytesBefore)
        let staged = temporaryURL(beside: source)
        do {
            try await write(source, to: staged, info: info, target: target, using: tool)
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

    /// Writes `staged` from `source`, described by `info`, as `target`. A
    /// source of mono or stereo is written in one step. A source of more
    /// channels is mixed down first, to a hidden stereo PCM file
    /// (`downmixArguments`, written by `tool.downmixCommand`) that the second
    /// step reads (`afconvertArguments`, by `tool.command`, with the PCM
    /// file's facts); the PCM file is removed as soon as the second step
    /// ends, however it ends. Each step is a watched child. Before the first
    /// step, the volume's free space must hold the PCM file
    /// (`downmixBytesNeeded(duration:target:)`), or nothing runs.
    /// - Throws: `Failure`, or `CancellationError`.
    private static func write(
        _ source: URL,
        to staged: URL,
        info: SourceInfo,
        target: Target,
        using tool: Tool
    ) async throws {
        let name = source.lastPathComponent
        guard needsDownmix(info) else {
            try await run(
                tool.command(source, staged, info, target), named: name, duration: info.duration, tool: tool,
                watching: staged, cap: outputCap(of: .encode, duration: info.duration, target: target)
            )
            return
        }
        let stereo = downmixURL(beside: source)
        // Refuse before any child runs when the stereo PCM file would not fit.
        let needed = downmixBytesNeeded(duration: info.duration, target: target)
        if let available = tool.availableBytes(stereo.deletingLastPathComponent()), available < needed {
            throw Failure.notEnoughSpace(fileName: name, bytesNeeded: needed)
        }
        defer { try? FileManager.default.removeItem(at: stereo) }
        try await run(
            tool.downmixCommand(source, stereo, target), named: name, duration: info.duration, tool: tool,
            watching: stereo, cap: outputCap(of: .downmix, duration: info.duration, target: target)
        )
        // What step 1 wrote: linear PCM in stereo, at the rate and depth step 2 keeps.
        let stereoInfo = SourceInfo(
            sampleRate: target.sampleRate, channels: maximumChannels, duration: info.duration, formatID: "lpcm",
            bitsPerSample: downmixBitDepth(for: target), isLossless: true
        )
        try await run(
            tool.command(stereo, staged, stereoInfo, target), named: name, duration: info.duration, tool: tool,
            watching: staged, cap: outputCap(of: .encode, duration: info.duration, target: target)
        )
    }

    /// Runs one converting process, `command`, of a conversion of the file
    /// named `name` lasting `duration` seconds, under the watchdog's limits
    /// of `tool` and watching `output` grow, and turns how it ended into
    /// success or a `Failure`; a kill is logged. The output may grow to
    /// `cap` bytes (`outputCap(of:duration:target:)`), unless the tool's
    /// own limits set a cap, as a test's stand-in may.
    private static func run(
        _ command: (executable: URL, arguments: [String]),
        named name: String,
        duration: TimeInterval,
        tool: Tool,
        watching output: URL,
        cap: Int64
    ) async throws {
        var limits = tool.limits(duration)
        limits.maximumOutputBytes = limits.maximumOutputBytes ?? cap
        let outcome = try await WatchedProcess.run(
            command.executable,
            arguments: command.arguments,
            watching: output,
            limits: limits,
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
            DiagnosticLog.event(.storage, "AUDIO_CONVERSION_KILLED: \(name): \(reason.words)")
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

    /// Whether `name` is a hidden temporary name of a conversion: it starts
    /// with ".", ends with one of the suffixes (`temporarySuffix`,
    /// `legacyTemporarySuffix`, `downmixSuffix`), and has something before
    /// the suffix.
    static func isTemporaryName(_ name: String) -> Bool {
        guard name.hasPrefix(".") else { return false }
        // Each suffix starts with ".", so a name equal to one would pass the
        // first two tests with nothing in front.
        return [temporarySuffix, legacyTemporarySuffix, downmixSuffix].contains { suffix in
            name.hasSuffix(suffix) && name.count > suffix.count
        }
    }

    /// Removes the files an interrupted conversion left under their hidden
    /// temporary names anywhere in `folder`, so a book converted again
    /// starts clean.
    static func removeLeftovers(in folder: URL) {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return }
        for case let file as URL in enumerator where isTemporaryName(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// About how many bytes `sources` take once converted: each lossy one's
    /// length at the bit rate it would be written at (`target(for:bytes:)`),
    /// with a hundredth more and 64 KB for the file's own tables; each
    /// lossless one's own size and 64 KB; or a file's own size when it can't
    /// be read. Reads only each file's header; never decodes.
    static func estimatedSize(of sources: [URL]) async -> Int64 {
        var total: Int64 = 0
        for source in sources {
            let bytes = fileSize(of: source)
            // A cancellation counts as an unreadable file: only a size is wanted.
            guard let info = try? await inspect(source) else {
                total += bytes
                continue
            }
            // Apple Lossless takes about the source's own size.
            if info.isLossless {
                total += bytes + 65_536
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
    /// - Parameter sourceNames: Each source's path from `folder`
    ///   (`AudioBookParser.relativeName(of:in:)`), in the order of
    ///   `conversions`, read while the sources still existed; the import
    ///   removes its sources before its converted files take their final
    ///   names, and a removed file's path cannot be resolved. When nil, each
    ///   is read from the source, which must then still be there.
    static func renameTracks(
        of conversions: [Conversion],
        inManifestOf folder: URL,
        bookID: UUID?,
        sourceNames: [String]? = nil
    ) throws {
        guard !conversions.isEmpty, let location = AudioManifestLocation.find(in: folder) else { return }
        try BookManifestFile.change(manifestAt: location, of: bookID) { object in
            for (index, conversion) in conversions.enumerated() {
                let sourceName = sourceNames.flatMap { $0.indices.contains(index) ? $0[index] : nil }
                    ?? AudioBookParser.relativeName(of: conversion.source, in: folder)
                BookManifestFile.renameTrack(
                    location.name(ofTrackAt: sourceName),
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

    /// The hidden folder at the top of a book's package that holds the
    /// originals an import kept of the audio it converted (the "Keep
    /// originals of converted audio" setting), each under its path from the
    /// book's folder of tracks, or under its own name for a single file.
    /// Hidden so that every track scan, manifest, playlist, and player passes
    /// it by: `AudioBookParser.audioFiles(in:)` and the others skip hidden
    /// files, and `FileImportService.isPackageContentName` refuses names
    /// that start with ".". A kept Ogg file is never opened by anything in
    /// TextMouth (the October 14 rule); only Export copies it out.
    static let keptOriginalsFolderName = ".convertedOriginals"

    /// Moves the files `conversions` were made from into the package's kept
    /// originals folder, in place of removing them
    /// (`removeSources(of:)`): each goes to
    /// `package/.convertedOriginals/<its path from base>`, the folders
    /// made as needed. `base` is the book's folder of tracks for a book of
    /// several tracks, or the single file's own folder. Only the staged copy
    /// is ever moved: what the import came from is never touched.
    /// - Throws: the file system's error; the import then fails at
    ///   Converting its audio, with everything staged removed.
    static func keepSources(of conversions: [Conversion], from base: URL, inPackage package: URL) throws {
        let keptFolder = package.appendingPathComponent(keptOriginalsFolderName, isDirectory: true)
        for conversion in conversions {
            // The path is read before the move, while the source exists to
            // be resolved.
            let destination = keptFolder.appendingPathComponent(
                AudioBookParser.relativeName(of: conversion.source, in: base)
            )
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.moveItem(at: conversion.source, to: destination)
        }
    }

    /// The original files an import kept in `package`, in Finder's order by
    /// their paths in the kept originals folder; none when it has no such
    /// folder. Export offers them as the Original file.
    static func keptOriginals(inPackage package: URL) -> [URL] {
        let keptFolder = package.appendingPathComponent(keptOriginalsFolderName, isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: keptFolder,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        var files: [URL] = []
        for case let file as URL in enumerator
        where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            files.append(file)
        }
        return files.sortedStably {
            AudioBookParser.relativeName(of: $0, in: keptFolder).localizedStandardCompare(
                AudioBookParser.relativeName(of: $1, in: keptFolder)
            ) == .orderedAscending
        }
    }

    /// The size of the file at `url` in bytes, or 0 when it can't be read.
    static func fileSize(of url: URL) -> Int64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else { return 0 }
        return size.int64Value
    }
}
