import AVFoundation

// MARK: - Formats

/// A format the audio editor writes (FR04): AAC or Apple Lossless in an
/// MPEG-4 file, which holds chapter markers the way TextMouth's parser
/// reads them, linear PCM in a CAF, WAVE, or AIFF file, or, through an
/// installed ffmpeg, MP3, which Core Audio can't encode.
enum AudioRenderFormat: String, CaseIterable, Sendable {
    /// AAC in an MPEG-4 audio file (.m4a).
    case aacM4A
    /// AAC in an MPEG-4 audiobook file (.m4b).
    case aacM4B
    /// Apple Lossless in an MPEG-4 audio file (.m4a).
    case alacM4A
    /// Linear PCM in a Core Audio file (.caf).
    case pcmCAF
    /// Linear PCM in a WAVE file (.wav).
    case pcmWAV
    /// Linear PCM in an AIFF file (.aiff).
    case pcmAIFF
    /// MP3, encoded by an installed ffmpeg with LAME (.mp3).
    case mp3

    /// The extension of a file written in this format.
    var fileExtension: String {
        switch self {
        case .aacM4A, .alacM4A: return "m4a"
        case .aacM4B: return "m4b"
        case .pcmCAF: return "caf"
        case .pcmWAV: return "wav"
        case .pcmAIFF: return "aiff"
        case .mp3: return "mp3"
        }
    }

    /// The extensions a file of this format may already have, so writing it
    /// over a file keeps that file's name.
    var acceptedExtensions: Set<String> {
        self == .pcmAIFF ? ["aif", "aiff"] : [fileExtension]
    }

    /// The file type AVFoundation writes it as. An .m4b is an MPEG-4 audio
    /// file under the audiobook extension.
    var fileType: AVFileType {
        switch self {
        case .aacM4A, .aacM4B, .alacM4A: return .m4a
        case .pcmCAF: return .caf
        case .pcmWAV: return .wav
        case .pcmAIFF: return .aiff
        case .mp3: return .mp3
        }
    }

    /// Whether the file is an MPEG-4 file, which holds chapter markers and
    /// tags.
    var isMPEG4: Bool {
        switch self {
        case .aacM4A, .aacM4B, .alacM4A: return true
        case .pcmCAF, .pcmWAV, .pcmAIFF, .mp3: return false
        }
    }

    /// Whether its samples are linear PCM.
    var isPCM: Bool {
        switch self {
        case .pcmCAF, .pcmWAV, .pcmAIFF: return true
        case .aacM4A, .aacM4B, .alacM4A, .mp3: return false
        }
    }

    /// The codec its samples are stored with.
    var codec: AudioFormatID {
        switch self {
        case .aacM4A, .aacM4B: return kAudioFormatMPEG4AAC
        case .alacM4A: return kAudioFormatAppleLossless
        case .pcmCAF, .pcmWAV, .pcmAIFF: return kAudioFormatLinearPCM
        case .mp3: return kAudioFormatMPEGLayer3
        }
    }

    /// The format a book's file named `name`, whose samples are stored as
    /// `stored`, is written back in when its edits are rendered: its own,
    /// wherever TextMouth can write it, so the file keeps its name; MP3 when
    /// `ffmpeg` may write it. A lossless file without a writer of its kind
    /// (FLAC) becomes Apple Lossless; any other becomes AAC in an .m4a file
    /// (MP3 without ffmpeg, which Core Audio cannot encode, and raw AAC), as
    /// the research recommended.
    static func inPlace(forFileNamed name: String, stored: AudioStreamBasicDescription, ffmpeg: FFmpeg? = nil) -> AudioRenderFormat {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp3":
            return ffmpeg == nil ? .aacM4A : .mp3
        case "m4b":
            return .aacM4B
        case "m4a", "alac":
            return stored.mFormatID == kAudioFormatAppleLossless ? .alacM4A : .aacM4A
        case "flac":
            return .alacM4A
        case "wav":
            return .pcmWAV
        case "aif", "aiff":
            return .pcmAIFF
        case "caf":
            return stored.mFormatID == kAudioFormatLinearPCM ? .pcmCAF : .aacM4A
        default:
            return .aacM4A
        }
    }

    /// The name a file written in this format takes in place of one named
    /// `name`: the same, when its extension fits the format; otherwise the
    /// same stem with the format's extension.
    func fileName(replacing name: String) -> String {
        let file = name as NSString
        guard !acceptedExtensions.contains(file.pathExtension.lowercased()) else { return name }
        return "\(file.deletingPathExtension).\(fileExtension)"
    }
}

// MARK: - Settings

/// How a render stores its samples: the format, and everything AVFoundation
/// needs to write it, chosen to keep as much of the audio the edits start
/// from as the format can hold.
struct AudioRenderSettings: Equatable, Sendable {
    /// The format.
    let format: AudioRenderFormat
    /// The sample rate written.
    let sampleRate: Double
    /// The channels written.
    let channels: Int
    /// AAC's bit rate in bits a second, or nil to let the encoder choose;
    /// nil for every other format.
    let bitRate: Int?
    /// Bits a sample, for PCM and Apple Lossless.
    let bitsPerSample: Int
    /// Whether PCM samples are floating point.
    let isFloat: Bool

    /// The bit rate of AAC made from audio that wasn't AAC: 64 kbit/s a
    /// channel, the rate spoken-word audiobooks use for clear speech
    /// (`RecordingEncoder.speechBitRate`).
    static let bitRatePerChannel = RecordingEncoder.speechBitRate

    /// The settings that render `base` in `format`: its own rate and channels
    /// wherever the format takes them, AAC at the base's own bit rate (or
    /// 64 kbit/s a channel), and PCM and Apple Lossless at its own sample
    /// layout when the format holds it.
    static func make(_ format: AudioRenderFormat, for base: AudioEditBase) -> AudioRenderSettings {
        let stored = base.format
        let isPCM = stored.mFormatID == kAudioFormatLinearPCM
        let isFloat = isPCM && stored.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = Int(stored.mBitsPerChannel)
        switch format {
        case .aacM4A, .aacM4B:
            let rate = RecordingEncoder.outputSampleRate(for: base.sampleRate)
            let channels = min(base.channelCount, 2)
            let target = stored.mFormatID == kAudioFormatMPEG4AAC
                ? base.bitRate ?? Double(bitRatePerChannel * channels)
                : Double(bitRatePerChannel * channels)
            return AudioRenderSettings(
                format: format, sampleRate: rate, channels: channels,
                bitRate: nearestAACBitRate(to: target, sampleRate: rate, channels: channels),
                bitsPerSample: 16, isFloat: false
            )
        case .mp3:
            // LAME takes the rates AAC takes; an MP3 keeps its own bit rate,
            // and anything else gets 64 kbit/s a channel.
            let channels = min(base.channelCount, 2)
            let target = stored.mFormatID == kAudioFormatMPEGLayer3
                ? base.bitRate ?? Double(bitRatePerChannel * channels)
                : Double(bitRatePerChannel * channels)
            return AudioRenderSettings(
                format: format, sampleRate: RecordingEncoder.outputSampleRate(for: base.sampleRate), channels: channels,
                bitRate: Int(target.rounded()), bitsPerSample: 16, isFloat: false
            )
        case .alacM4A:
            let depth = !isFloat && [16, 20, 24, 32].contains(bits) ? bits : (isFloat ? 24 : 16)
            return AudioRenderSettings(
                format: format, sampleRate: base.sampleRate, channels: base.channelCount,
                bitRate: nil, bitsPerSample: depth, isFloat: false
            )
        case .pcmCAF:
            // A CAF file holds any PCM, and compressed audio is decoded to
            // floats, which lose nothing more.
            return pcm(format, base, bits: isPCM ? bits : 32, isFloat: isPCM ? isFloat : true)
        case .pcmWAV, .pcmAIFF:
            // AVAssetWriter writes WAVE and AIFF files of integers only (it
            // refuses floats there). Floats become 32-bit integers, which keep
            // them far more finely than any recording needs (steps of about
            // -186 dB); compressed audio becomes 16-bit, as on a CD.
            let keeps = isPCM && !isFloat && [8, 16, 24, 32].contains(bits)
            return pcm(format, base, bits: keeps ? bits : (isFloat ? 32 : 16), isFloat: false)
        }
    }

    /// PCM settings for `format` at `base`'s rate and channels.
    private static func pcm(_ format: AudioRenderFormat, _ base: AudioEditBase, bits: Int, isFloat: Bool) -> AudioRenderSettings {
        AudioRenderSettings(
            format: format, sampleRate: base.sampleRate, channels: base.channelCount,
            bitRate: nil, bitsPerSample: bits, isFloat: isFloat
        )
    }

    /// The bit rates the AAC encoder takes at `sampleRate` in `channels`
    /// channels, asked of the encoder itself, since they depend on both;
    /// empty when it names none.
    static func acceptedAACBitRates(sampleRate: Double, channels: Int) -> [Int] {
        guard let pcm = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sampleRate,
                  channels: AVAudioChannelCount(channels),
                  interleaved: false
              ),
              let aac = AVAudioFormat(settings: [
                  AVFormatIDKey: kAudioFormatMPEG4AAC,
                  AVSampleRateKey: sampleRate,
                  AVNumberOfChannelsKey: channels,
              ]),
              let converter = AVAudioConverter(from: pcm, to: aac) else { return [] }
        return converter.applicableEncodeBitRates?.map(\.intValue) ?? []
    }

    /// The accepted AAC bit rate nearest `target`, or nil when the encoder
    /// names none, so it picks its own.
    static func nearestAACBitRate(to target: Double, sampleRate: Double, channels: Int) -> Int? {
        acceptedAACBitRates(sampleRate: sampleRate, channels: channels)
            .min { abs(Double($0) - target) < abs(Double($1) - target) }
    }

    /// The settings of the writer's input.
    var outputSettings: [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: format.codec,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        switch format {
        case .aacM4A, .aacM4B, .mp3:
            if let bitRate { settings[AVEncoderBitRateKey] = bitRate }
        case .alacM4A:
            settings[AVEncoderBitDepthHintKey] = bitsPerSample
        case .pcmCAF, .pcmWAV, .pcmAIFF:
            settings.merge(pcmKeys) { _, new in new }
        }
        if let layout = channelLayout { settings[AVChannelLayoutKey] = layout }
        return settings
    }

    /// The linear PCM the reader decodes the composition to: exactly the
    /// samples written, for a PCM format; floats, which the encoders take,
    /// for the others.
    var readerSettings: [String: Any] {
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        if format.isPCM {
            settings.merge(pcmKeys) { _, new in new }
        } else {
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = true
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        }
        if let layout = channelLayout { settings[AVChannelLayoutKey] = layout }
        return settings
    }

    /// The keys describing this PCM sample layout: big-endian for AIFF.
    private var pcmKeys: [String: Any] {
        [
            AVLinearPCMBitDepthKey: bitsPerSample,
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: format == .pcmAIFF,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// The channel layout of more than two channels, which AVFoundation
    /// needs spelled out: each channel on its own, in order. Nil for mono
    /// and stereo, which it knows.
    private var channelLayout: Data? {
        guard channels > 2 else { return nil }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
        return Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
    }
}

// MARK: - Tags and Chapters

/// What a render tags its file with: the book's title and author, beside
/// the tags the audio the edits start from already had (its album, cover
/// art, and the rest of its common metadata).
struct AudioRenderMetadata: Equatable, Sendable {
    /// The book's title: the file's title tag, and the title of the chapter
    /// standing for the sound before the first marker, when that isn't at
    /// the start.
    var title: String
    /// The book's author, or nil to keep the file's own.
    var author: String?
}

/// One chapter marker as a render writes it: where it starts and how long
/// it lasts, in seconds, and its title.
struct AudioRenderChapter: Equatable, Sendable {
    let start: TimeInterval
    let duration: TimeInterval
    let title: String
}

/// The chapter list of an MPEG-4 file, as audiobooks store it and
/// AVFoundation reads it back (`AudioPlaybackService.extractChapters`): a
/// disabled 3GPP timed-text track whose samples are the titles, which the
/// audio track names as its chapter list.
enum AudioChapterTrack {
    /// The description of the chapter track's samples: one font and plain
    /// colours, since the titles are read, never shown. AVAssetWriter needs
    /// every one of these fields; without them it fails with "Media format -
    /// invalid parameter".
    static func formatDescription() throws -> CMFormatDescription {
        let black: [String: Any] = [
            kCMTextFormatDescriptionColor_Red as String: 0,
            kCMTextFormatDescriptionColor_Green as String: 0,
            kCMTextFormatDescriptionColor_Blue as String: 0,
            kCMTextFormatDescriptionColor_Alpha as String: 255,
        ]
        let extensions: [String: Any] = [
            kCMTextFormatDescriptionExtension_DisplayFlags as String: 0,
            kCMTextFormatDescriptionExtension_BackgroundColor as String: black,
            kCMTextFormatDescriptionExtension_DefaultTextBox as String: [
                kCMTextFormatDescriptionRect_Top as String: 0,
                kCMTextFormatDescriptionRect_Left as String: 0,
                kCMTextFormatDescriptionRect_Bottom as String: 0,
                kCMTextFormatDescriptionRect_Right as String: 0,
            ],
            kCMTextFormatDescriptionExtension_DefaultStyle as String: [
                kCMTextFormatDescriptionStyle_StartChar as String: 0,
                kCMTextFormatDescriptionStyle_EndChar as String: 0,
                kCMTextFormatDescriptionStyle_Font as String: 1,
                kCMTextFormatDescriptionStyle_FontFace as String: 0,
                kCMTextFormatDescriptionStyle_FontSize as String: 12,
                kCMTextFormatDescriptionStyle_ForegroundColor as String: black,
            ],
            kCMTextFormatDescriptionExtension_HorizontalJustification as String: 0,
            kCMTextFormatDescriptionExtension_VerticalJustification as String: 0,
            kCMTextFormatDescriptionExtension_FontTable as String: ["1": "Helvetica"],
        ]
        var format: CMFormatDescription?
        let status = CMFormatDescriptionCreate(
            allocator: nil,
            mediaType: kCMMediaType_Text,
            mediaSubType: kCMTextFormatType_3GText,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &format
        )
        guard status == noErr, let format else { throw AudioEditError.renderFailed("\(NSOSStatusErrorDomain) \(status)") }
        return format
    }

    /// `chapter`'s title as one timed-text sample shown from its start for
    /// its duration: the title's UTF-8 byte count as a big-endian 16-bit
    /// number, then the bytes. A title too long for that count is shortened
    /// at a character boundary.
    static func sample(_ chapter: AudioRenderChapter, format: CMFormatDescription) throws -> CMSampleBuffer {
        var title = Array(chapter.title.utf8)
        if title.count > Int(UInt16.max) {
            title = Array(String(decoding: title.prefix(Int(UInt16.max)), as: UTF8.self).utf8.prefix(Int(UInt16.max)))
        }
        var bytes = [UInt8(title.count >> 8), UInt8(title.count & 0xFF)] + title
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        guard status == noErr, let block else { throw AudioEditError.renderFailed("\(NSOSStatusErrorDomain) \(status)") }
        status = CMBlockBufferReplaceDataBytes(with: &bytes, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        guard status == noErr else { throw AudioEditError.renderFailed("\(NSOSStatusErrorDomain) \(status)") }

        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: chapter.duration, preferredTimescale: 1_000_000),
            presentationTimeStamp: CMTime(seconds: chapter.start, preferredTimescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var size = bytes.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: nil,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { throw AudioEditError.renderFailed("\(NSOSStatusErrorDomain) \(status)") }
        return sample
    }
}

// MARK: - The Renderer

/// Writes an edit timeline's audio to a file (FR04): the composition read
/// with AVAssetReader and written with AVAssetWriter in one pass, buffer by
/// buffer, so memory stays small whatever the length, never on the main
/// thread.
///
/// AAC is always encoded again, since AVFoundation refuses to copy edited
/// AAC as it is stored (the research prototype); only a file whose sound no
/// edit changed, its chapter markers aside, keeps its AAC or Apple Lossless
/// samples untouched. Linear PCM is copied as it is stored when nothing but
/// cuts, trims, and moves of it applied and the file type holds its layout;
/// should the writer refuse, it is decoded and written again instead. An
/// MPEG-4 file gets the timeline's chapter markers, laid out ahead of the
/// audio: interleaved with it, the writer refuses a title until the audio
/// reaches it and stalls a long file (the research prototype).
enum AudioEditRenderer {
    /// What a render wrote.
    struct Outcome: Equatable, Sendable {
        /// How many frames the file lasts, at the timeline's rate.
        let frames: Int64
        /// Whether its samples were copied as they were stored.
        let copiedSamples: Bool
    }

    /// Renders `timeline`, whose stretches come from `sources`, into a new
    /// file at `destination` in `format`, tagged with `metadata`, telling
    /// `progress` how far it is, from 0 to 1. `settings` replaces the ones the
    /// format would choose (`AudioRenderSettings.make`), as a filter renders
    /// its stretch to floats; samples are copied as stored only under the
    /// format's own. A file already at `destination` is replaced.
    /// - Throws: the composition's errors, `AudioEditError.renderFailed`, or
    ///   `CancellationError` when the task is cancelled; nothing is left at
    ///   `destination` after a failure.
    static func render(
        _ timeline: AudioEditTimeline,
        sources: AudioEditComposition.Sources,
        to destination: URL,
        format: AudioRenderFormat,
        settings requested: AudioRenderSettings? = nil,
        metadata: AudioRenderMetadata,
        ffmpeg: FFmpeg? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Outcome {
        if format == .mp3 {
            return try await renderMP3(timeline, sources: sources, to: destination, metadata: metadata, ffmpeg: ffmpeg, progress: progress)
        }
        let made = try await AudioEditComposition.make(timeline, sources: sources)
        let standard = AudioRenderSettings.make(format, for: sources.base)
        let settings = requested ?? standard
        let chapters = format.isMPEG4 ? chapterList(of: timeline, leadingTitle: metadata.title) : []
        let tags = format.isMPEG4 ? await metadataItems(from: sources.base.url, overriding: metadata) : []
        try? FileManager.default.removeItem(at: destination)

        if settings == standard, canCopySamples(of: timeline, base: sources.base, into: format) {
            do {
                try await write(made, to: destination, settings: settings, copyingSamples: true, chapters: chapters, tags: tags, progress: progress)
                return Outcome(frames: made.frames, copiedSamples: true)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The writer refused the samples as stored: they are decoded
                // and written again below.
                try? FileManager.default.removeItem(at: destination)
            }
        }
        try await write(made, to: destination, settings: settings, copyingSamples: false, chapters: chapters, tags: tags, progress: progress)
        return Outcome(frames: made.frames, copiedSamples: false)
    }

    /// Renders `timeline` as MP3 at `destination`: to 32-bit float PCM first,
    /// in the scratch folder, then encoded by `ffmpeg` with the timeline's
    /// chapter markers as ID3 chapter frames.
    /// - Throws: `AudioEditError.mp3NeedsFFmpeg` without ffmpeg, the render's
    ///   errors, or ffmpeg's.
    private static func renderMP3(
        _ timeline: AudioEditTimeline,
        sources: AudioEditComposition.Sources,
        to destination: URL,
        metadata: AudioRenderMetadata,
        ffmpeg: FFmpeg?,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Outcome {
        guard let ffmpeg else { throw AudioEditError.mp3NeedsFFmpeg }
        let settings = AudioRenderSettings.make(.mp3, for: sources.base)
        try AudioEditScratch.make(sources.scratch)
        let intermediate = sources.scratch.appendingPathComponent(".\(UUID().uuidString).mp3-source.caf")
        defer { try? FileManager.default.removeItem(at: intermediate) }
        let rendered = try await render(
            timeline,
            sources: sources,
            to: intermediate,
            format: .pcmCAF,
            settings: AudioRenderSettings.floatCAF(for: sources.base),
            metadata: metadata,
            progress: { progress?($0 / 2) }
        )
        try? FileManager.default.removeItem(at: destination)
        try await ffmpeg.encodeMP3(
            intermediate,
            to: destination,
            bitRate: settings.bitRate ?? AudioRenderSettings.bitRatePerChannel,
            sampleRate: settings.sampleRate,
            channels: settings.channels,
            metadata: metadata,
            chapters: chapterList(of: timeline, leadingTitle: metadata.title),
            scratch: sources.scratch
        )
        progress?(1)
        return Outcome(frames: rendered.frames, copiedSamples: false)
    }

    /// Whether `timeline`'s samples can be copied as `base` stores them into
    /// a file of `format`, as the type describes.
    static func canCopySamples(of timeline: AudioEditTimeline, base: AudioEditBase, into format: AudioRenderFormat) -> Bool {
        let stored = base.format
        guard format.isPCM else {
            return stored.mFormatID == format.codec && timeline.isUnchangedBase(baseFrames: base.frames)
        }
        guard base.isLinearPCM, timeline.isOnlyBase else { return false }
        let isFloat = stored.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isBigEndian = stored.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        switch format {
        case .pcmCAF: return true
        case .pcmWAV: return !isBigEndian
        case .pcmAIFF: return isBigEndian && !isFloat
        case .aacM4A, .aacM4B, .alacM4A, .mp3: return false
        }
    }

    /// The chapter list a render writes for `timeline`: its markers, each
    /// lasting until the next or the end, after one titled `leadingTitle`
    /// for the sound before the first marker when that isn't at the start,
    /// so every moment of the file is in a chapter. None without markers.
    static func chapterList(of timeline: AudioEditTimeline, leadingTitle: String) -> [AudioRenderChapter] {
        guard !timeline.chapters.isEmpty else { return [] }
        var markers = timeline.chapters
        if let first = markers.first, first.frame > 0 {
            markers.insert(AudioEditTimeline.Chapter(frame: 0, title: leadingTitle), at: 0)
        }
        return markers.enumerated().map { index, marker in
            let end = index + 1 < markers.count ? markers[index + 1].frame : timeline.length
            return AudioRenderChapter(
                start: timeline.seconds(at: marker.frame),
                duration: timeline.seconds(at: end - marker.frame),
                title: marker.title
            )
        }
    }

    /// The tags of the file at `base`, as common metadata, with the title
    /// and, when given, the author of `metadata` in place of its own.
    private static func metadataItems(from base: URL, overriding metadata: AudioRenderMetadata) async -> [AVMetadataItem] {
        var replaced: Set<AVMetadataKey> = [.commonKeyTitle]
        if metadata.author != nil { replaced.insert(.commonKeyArtist) }
        var items: [AVMetadataItem] = []
        let common = (try? await AVURLAsset(url: base).load(.commonMetadata)) ?? []
        for item in common {
            guard let key = item.commonKey, !replaced.contains(key),
                  let value = try? await item.load(.value) else { continue }
            items.append(tag(AVMetadataItem.identifier(forKey: key, keySpace: .common), value))
        }
        items.append(tag(.commonIdentifierTitle, metadata.title as NSString))
        if let author = metadata.author {
            items.append(tag(.commonIdentifierArtist, author as NSString))
        }
        return items
    }

    /// A common metadata item: `identifier` holding `value`.
    private static func tag(_ identifier: AVMetadataIdentifier?, _ value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        item.extendedLanguageTag = "und"
        return item
    }

    /// The pass itself: reads `made` and appends its sound to a writer of
    /// `settings`, after the chapter titles, as the type describes.
    private static func write(
        _ made: AudioEditComposition,
        to destination: URL,
        settings: AudioRenderSettings,
        copyingSamples: Bool,
        chapters: [AudioRenderChapter],
        tags: [AVMetadataItem],
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        let tracks = try await made.composition.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw AudioEditError.renderFailed("the composition has no audio") }
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: made.composition)
        } catch {
            throw failure(error)
        }
        let output: AVAssetReaderOutput
        var hint: CMFormatDescription?
        if copyingSamples {
            output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            hint = try await track.load(.formatDescriptions).first
        } else {
            output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings.readerSettings)
        }
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioEditError.renderFailed("the reader refused the audio") }
        reader.add(output)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: destination, fileType: settings.format.fileType)
        } catch {
            throw failure(error)
        }
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: copyingSamples ? nil : settings.outputSettings,
            sourceFormatHint: hint
        )
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw AudioEditError.renderFailed("the writer refused the audio") }
        writer.add(input)

        var chapterInput: AVAssetWriterInput?
        var chapterFormat: CMFormatDescription?
        if !chapters.isEmpty {
            let format = try AudioChapterTrack.formatDescription()
            let titles = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: format)
            titles.marksOutputTrackAsEnabled = false
            titles.mediaDataLocation = .beforeMainMediaDataNotInterleaved
            guard writer.canAdd(titles) else { throw AudioEditError.renderFailed("the writer refused the chapter list") }
            writer.add(titles)
            input.addTrackAssociation(withTrackOf: titles, type: AVAssetTrack.AssociationType.chapterList.rawValue)
            chapterInput = titles
            chapterFormat = format
        }
        if !tags.isEmpty {
            writer.metadata = tags
        }

        guard reader.startReading() else { throw failure(reader.error) }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw failure(writer.error)
        }
        writer.startSession(atSourceTime: .zero)

        do {
            if let chapterInput, let chapterFormat {
                for chapter in chapters {
                    try await append(try AudioChapterTrack.sample(chapter, format: chapterFormat), to: chapterInput, of: writer)
                }
                chapterInput.markAsFinished()
            }
            let total = Double(made.frames) * settings.sampleRate / made.sampleRate
            // Decoded audio is written up to the end of the edits and no
            // further: a compressed take that ends them, as a punch-in at the
            // very end leaves, is decoded to the end of its last packet,
            // padding included. Samples copied as stored are whole packets,
            // never cut, and hold no padding of that kind.
            let limit = copyingSamples ? nil : Int(total.rounded())
            var written = 0
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                // The rest is still read, so the reader ends as completed.
                guard let sample = try trimmed(buffer, toAtMost: limit.map { $0 - written }) else { continue }
                try await append(sample, to: input, of: writer)
                written += CMSampleBufferGetNumSamples(sample)
                progress?(total > 0 ? min(1, Double(written) / total) : 1)
            }
            guard reader.status == .completed else { throw failure(reader.error) }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: destination)
            throw failure(writer.error)
        }
    }

    /// `buffer`, decoded audio, cut to at most `frames` frames: all of it
    /// when that many fit, or when `frames` is nil; nil when none may be
    /// written. A cut buffer loses the trim its end had, which the cut has
    /// made, so a writer that applies trims never cuts it again.
    /// - Throws: `AudioEditError.renderFailed` when the frames can't be
    ///   copied.
    private static func trimmed(_ buffer: CMSampleBuffer, toAtMost frames: Int?) throws -> CMSampleBuffer? {
        guard let frames else { return buffer }
        guard frames > 0 else { return nil }
        guard CMSampleBufferGetNumSamples(buffer) > frames else { return buffer }
        var kept: CMSampleBuffer?
        let status = CMSampleBufferCopySampleBufferForRange(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleRange: CFRange(location: 0, length: frames),
            sampleBufferOut: &kept
        )
        guard status == noErr, let kept else { throw AudioEditError.renderFailed("\(NSOSStatusErrorDomain) \(status)") }
        CMRemoveAttachment(kept, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
        return kept
    }

    /// Appends `sample` to `input` once it is ready for more.
    private static func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput, of writer: AVAssetWriter) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw failure(writer.error) }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard input.append(sample) else { throw failure(writer.error) }
    }

    /// `error`, from AVFoundation, as a render failure naming its domain and
    /// code only: its description can name files by their full paths.
    private static func failure(_ error: Error?) -> AudioEditError {
        guard let error else { return .renderFailed("no error was given") }
        let failure = error as NSError
        return .renderFailed("\(failure.domain) \(failure.code)")
    }
}
