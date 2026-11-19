import AVFoundation

// MARK: - Formats

/// A format the audio editor writes (FR04): AAC or Apple Lossless in an
/// MPEG-4 file, which holds chapter markers the way TextMouth's parser
/// reads them, linear PCM in a CAF, WAVE, or AIFF file, or MP3, which Core
/// Audio can't encode, with the LAME encoder built into TextMouth
/// (`MP3Route`).
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
    /// MP3, encoded by LAME (.mp3): TextMouth's own, or, should that be
    /// unavailable, an installed ffmpeg's (`MP3Route`).
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
    /// wherever TextMouth can write it, so the file keeps its name; MP3 with
    /// the LAME built into TextMouth, or, when `builtInMP3` says that is
    /// unavailable, with `ffmpeg` (`MP3Route`). A lossless file without a
    /// writer of its kind (FLAC) becomes Apple Lossless; any other becomes
    /// AAC in an .m4a file (MP3 with neither encoder, since Core Audio cannot
    /// encode it, and raw AAC), as the research recommended.
    static func inPlace(
        forFileNamed name: String,
        stored: AudioStreamBasicDescription,
        ffmpeg: FFmpeg? = nil,
        builtInMP3: Bool = MP3Encoder.isAvailable
    ) -> AudioRenderFormat {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp3":
            return MP3Route.preferred(ffmpeg: ffmpeg, builtInIsAvailable: builtInMP3) == nil ? .aacM4A : .mp3
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
            // The depth of the source, written as Apple Lossless writes it
            // (20 bits as 24, which its writer makes a file the media check
            // can decode); floats and depths it can't hold become 24 and 16.
            let source = storedIntegerDepth(of: stored).map(OwnAudioConverter.writtenBitDepth(forAppleLossless:))
            let depth = source.flatMap { [16, 24, 32].contains($0) ? $0 : nil } ?? (isFloat ? 24 : 16)
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
            // -186 dB); lossy audio becomes 16-bit, as on a CD. Integers keep
            // their depth, a lossless file's too (Apple Lossless and FLAC
            // books, whose depth is in their format flags): a depth
            // AVFoundation refuses between two it takes goes up to the next,
            // and a deeper one (64 bits) is a 32-bit integer.
            let source = storedIntegerDepth(of: stored)
            return pcm(format, base, bits: source.map { min($0, 32) } ?? (isPCM ? 32 : 16), isFloat: false)
        }
    }

    /// The bits of each sample of the integer audio `stored` describes, as the
    /// file holds it: a linear PCM file's, or a lossless file's (Apple Lossless
    /// or FLAC), which reports 0 bits a channel for its compressed samples and
    /// gives the depth of its source in its format flags instead (1 for 16
    /// bits, 2 for 20, 3 for 24, 4 for 32, the values of
    /// `kAppleLosslessFormatFlag_…`). Nil for floats and lossy audio.
    static func storedIntegerDepth(of stored: AudioStreamBasicDescription) -> Int? {
        let reported = Int(stored.mBitsPerChannel)
        switch stored.mFormatID {
        case kAudioFormatLinearPCM:
            return stored.mFormatFlags & kAudioFormatFlagIsFloat == 0 && reported > 0 ? reported : nil
        case kAudioFormatAppleLossless, kAudioFormatFLAC:
            if reported > 0 { return reported }
            switch stored.mFormatFlags {
            case 1: return 16
            case 2: return 20
            case 3: return 24
            case 4: return 32
            default: return nil
            }
        default:
            return nil
        }
    }

    /// The depths of integer samples AVFoundation's readers and writers take
    /// (the message of the exception it raises for any other:
    /// "Bit depth can only be one of: 24, 16, 8, 32").
    static let acceptedIntegerDepths = [8, 16, 24, 32]

    /// The sample layout a render stores `bits`-bit samples in (floating
    /// point or not), as far as AVFoundation takes it: integers of 8, 16, 24,
    /// and 32 bits and 32-bit floats as they are; an integer depth between
    /// those (12 or 20 bits) at the next one up, which holds every sample
    /// exactly; and everything else, which the readers refuse by raising an
    /// Objective-C exception (a 64-bit float, a 64-bit integer, a depth
    /// not known), as 32-bit floats, which keep a deeper sample to 24 bits
    /// of precision, finer than any recording's noise.
    static func readableDepth(bits: Int, isFloat: Bool) -> (bits: Int, isFloat: Bool) {
        if !isFloat, bits > 0, let accepted = acceptedIntegerDepths.first(where: { $0 >= bits }) {
            return (accepted, false)
        }
        return (32, true)
    }

    /// PCM settings for `format` at `base`'s rate and channels, in the
    /// layout of `bits` and `isFloat` where AVFoundation takes it
    /// (`readableDepth(bits:isFloat:)`). Every PCM setting a render makes is
    /// made here (the format's own in `make`, and a filter's floats in
    /// `floatCAF`), so no reader or writer is given a depth it refuses.
    static func pcm(_ format: AudioRenderFormat, _ base: AudioEditBase, bits: Int, isFloat: Bool) -> AudioRenderSettings {
        let depth = readableDepth(bits: bits, isFloat: isFloat)
        return AudioRenderSettings(
            format: format, sampleRate: base.sampleRate, channels: base.channelCount,
            bitRate: nil, bitsPerSample: depth.bits, isFloat: depth.isFloat
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
            kCMTextFormatDescriptionExtension_FontTable as String: ["1": "Helvetica"], // l10n: no (a font name)
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

/// Writes an edit timeline's audio to a file (FR04): its stretches read with
/// AVAssetReader, one after another (`readStretches`), and written with
/// AVAssetWriter in one pass, buffer by buffer, so memory stays small
/// whatever the length, never on the main thread. Samples copied as they
/// are stored are read through the timeline's composition instead.
///
/// AAC is always encoded again, since AVFoundation refuses to copy edited
/// AAC as it is stored (the research prototype); only a file whose sound no
/// edit changed, its chapter markers aside, keeps its AAC or Apple Lossless
/// samples untouched. Linear PCM is copied as it is stored when nothing but
/// cuts, trims, and moves of it applied and the file type holds its layout;
/// should the writer refuse, it is decoded and written again instead. An
/// MPEG-4 file gets the timeline's chapter markers, laid out ahead of the
/// audio: interleaved with it, the writer refuses a title until the audio
/// reaches it and stalls a long file (the research prototype). A WAVE,
/// AIFF, or CAF file gets them as its marker list once its audio is
/// written (FMT11).
enum AudioEditRenderer {
    /// What a render wrote.
    struct Outcome: Equatable, Sendable {
        /// How many frames the file lasts, at the timeline's rate.
        let frames: Int64
        /// Whether its samples were copied as they were stored.
        let copiedSamples: Bool
        /// Whether a WAVE, AIFF, or CAF file was written without the chapter
        /// markers the timeline has, their marker list refused (FMT11): the
        /// save or export that asked says so, rather than "saved" alone.
        var chapterMarkersLeftOut = false
    }

    /// Renders `timeline`, whose stretches come from `sources`, into a new
    /// file at `destination` in `format`, tagged with `metadata`, telling
    /// `progress` how far it is, from 0 to 1. `settings` replaces the ones the
    /// format would choose (`AudioRenderSettings.make`), as a filter renders
    /// its stretch to floats; samples are copied as stored only under the
    /// format's own. A file already at `destination` is replaced. MP3 is
    /// written with the LAME built into TextMouth, or, should that be
    /// unavailable, with `ffmpeg` (`renderMP3(_:sources:to:metadata:route:progress:)`).
    /// - Throws: the sources' errors (`AudioEditStretchSound.pieces(of:sources:)`),
    ///   `AudioEditError.renderFailed`, `.mp3NeedsFFmpeg` for MP3 with
    ///   neither encoder, or `CancellationError` when the task is
    ///   cancelled. A file already at `destination` stays as it was until
    ///   every source has been opened; a failure after that leaves nothing
    ///   there.
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
            return try await renderMP3(
                timeline,
                sources: sources,
                to: destination,
                metadata: metadata,
                route: MP3Route.preferred(ffmpeg: ffmpeg),
                progress: progress
            )
        }
        let standard = AudioRenderSettings.make(format, for: sources.base)
        let settings = requested ?? standard
        let chapters = format.isMPEG4 ? chapterList(of: timeline, leadingTitle: metadata.title) : []
        // A WAVE, AIFF, or CAF file keeps its chapters as markers, written
        // once its audio is (FMT11). A render to settings of a caller's own (a
        // filter's stretch, MP3's intermediate file) is no file anyone keeps,
        // and gets none.
        let markers = format.isPCM && requested == nil ? chapterList(of: timeline, leadingTitle: metadata.title) : []
        let tags = format.isMPEG4 ? await metadataItems(from: sources.base.url, overriding: metadata) : []
        // Every source is opened, and every stretch checked against it,
        // before the file a render replaces is removed, so a render that
        // can't read its sources leaves that file as it was. Samples copied
        // as stored are read through the timeline's composition, whole
        // packets, never decoded.
        let pieces = try await AudioEditStretchSound.pieces(of: timeline, sources: sources)
        // Samples are copied only under the format's own settings, never under
        // those a caller asked for (a filter's input, a copy's stretch, MP3's
        // intermediate file): since depths AVFoundation refuses are stored
        // as 32-bit floats, a caller's 32-bit floats can equal the standard
        // settings of a 64-bit float book, whose samples would be copied
        // at twice the size they ask for.
        let copied = requested == nil && canCopySamples(of: timeline, base: sources.base, into: format)
        let composition: AudioEditComposition? = try copied ? AudioEditComposition.make(pieces, sampleRate: timeline.sampleRate) : nil
        try? FileManager.default.removeItem(at: destination)

        if let made = composition {
            do {
                let (reader, output, storedFormat) = try await copyReader(of: made)
                try await write(.stored(storedFormat), to: destination, settings: settings, chapters: chapters, tags: tags) { consume in
                    try await drain(output, of: reader, made: made, progress: progress, consume: consume)
                }
                let keptMarkers = writeMarkers(markers, to: destination)
                return Outcome(frames: made.frames, copiedSamples: true, chapterMarkersLeftOut: !keptMarkers)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The writer refused the samples as stored: they are decoded
                // and written again below.
                try? FileManager.default.removeItem(at: destination)
            }
        }
        try await write(.decoded, to: destination, settings: settings, chapters: chapters, tags: tags) { consume in
            try await readStretches(pieces, timelineRate: timeline.sampleRate, settings: settings, progress: progress, consume: consume)
        }
        let keptMarkers = writeMarkers(markers, to: destination)
        return Outcome(frames: timeline.length, copiedSamples: false, chapterMarkersLeftOut: !keptMarkers)
    }

    /// The tag of the debug-log line saying a render's chapter markers could
    /// not be written (FMT11).
    static let markersNotWrittenLogTag = "AUDIO_MARKERS_NOT_WRITTEN"

    /// Writes `markers`, a render's chapters, into the WAVE, AIFF, or CAF
    /// file just written at `destination` as its marker list (FMT11,
    /// `AudioMarkerList`): each at its start, named by its title, the same
    /// list an MPEG-4 file's chapter track holds, the sound before the first
    /// marker included, so the chapters read back exactly
    /// (`FileChapterReaders`). Nothing for no markers. A failure leaves the
    /// file whole without markers, and is recorded as one line,
    /// `AUDIO_MARKERS_NOT_WRITTEN: <file>: <reason>`, which names no folder.
    /// - Returns: whether the file holds every marker given: false only when
    ///   there were markers and they could not be written.
    private static func writeMarkers(_ markers: [AudioRenderChapter], to destination: URL) -> Bool {
        guard !markers.isEmpty else { return true }
        do {
            try AudioMarkerList.write(markers.map { (title: $0.title, start: $0.start) }, to: destination)
            return true
        } catch {
            DiagnosticLog.event(.storage, "\(markersNotWrittenLogTag): \(destination.lastPathComponent): \(error)")
            return false
        }
    }

    /// Renders `timeline` as MP3 at `destination` through an installed
    /// `ffmpeg`, the route MP3 takes only when TextMouth's own LAME is
    /// unavailable (`MP3Route`): to 32-bit float PCM first, in the scratch
    /// folder, then encoded by ffmpeg with the timeline's chapter markers as
    /// ID3 chapter frames.
    /// - Throws: the render's errors, or ffmpeg's.
    static func renderMP3ThroughFFmpeg(
        _ timeline: AudioEditTimeline,
        sources: AudioEditComposition.Sources,
        to destination: URL,
        metadata: AudioRenderMetadata,
        ffmpeg: FFmpeg,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Outcome {
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
    static func tag(_ identifier: AVMetadataIdentifier?, _ value: NSCopying & NSObjectProtocol) -> AVMetadataItem {
        let item = AVMutableMetadataItem()
        item.identifier = identifier
        item.value = value
        item.extendedLanguageTag = "und"
        return item
    }

    /// What a pass hands its writer: samples copied as they are stored, in
    /// the format given, when the composition names one; or decoded linear
    /// PCM, which the writer encodes in the render's own format.
    private enum Samples {
        case stored(CMFormatDescription?)
        case decoded
    }

    /// The pass itself, as the type describes: a writer of `settings` at
    /// `destination`, given the chapter titles first and then, buffer by
    /// buffer, the audio `feed` hands it, of the kind `samples` names.
    /// Nothing is left at `destination` when it throws.
    private static func write(
        _ samples: Samples,
        to destination: URL,
        settings: AudioRenderSettings,
        chapters: [AudioRenderChapter],
        tags: [AVMetadataItem],
        feed: (_ consume: (CMSampleBuffer) async throws -> Void) async throws -> Void
    ) async throws {
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: destination, fileType: settings.format.fileType)
        } catch {
            throw failure(error)
        }
        let input: AVAssetWriterInput
        switch samples {
        case .stored(let format):
            input = try makingWithoutRaising { AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: format) }
        case .decoded:
            input = try makingWithoutRaising { AVAssetWriterInput(mediaType: .audio, outputSettings: settings.outputSettings) }
        }
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw AudioEditError.renderFailed("the writer refused the audio") } // l10n: no (a technical reason for the debug log (AudioEditError.renderFailed); the listener hears its fixed sentence)
        writer.add(input)

        var chapterInput: AVAssetWriterInput?
        var chapterFormat: CMFormatDescription?
        if !chapters.isEmpty {
            let format = try AudioChapterTrack.formatDescription()
            let titles = AVAssetWriterInput(mediaType: .text, outputSettings: nil, sourceFormatHint: format)
            titles.marksOutputTrackAsEnabled = false
            titles.mediaDataLocation = .beforeMainMediaDataNotInterleaved
            guard writer.canAdd(titles) else { throw AudioEditError.renderFailed("the writer refused the chapter list") } // l10n: no (a technical reason for the debug log (AudioEditError.renderFailed); the listener hears its fixed sentence)
            writer.add(titles)
            input.addTrackAssociation(withTrackOf: titles, type: AVAssetTrack.AssociationType.chapterList.rawValue)
            chapterInput = titles
            chapterFormat = format
        }
        if !tags.isEmpty {
            writer.metadata = tags
        }

        guard writer.startWriting() else { throw failure(writer.error) }
        writer.startSession(atSourceTime: .zero)

        do {
            if let chapterInput, let chapterFormat {
                for chapter in chapters {
                    try await append(try AudioChapterTrack.sample(chapter, format: chapterFormat), to: chapterInput, of: writer)
                }
                chapterInput.markAsFinished()
            }
            try await feed { try await append($0, to: input, of: writer) }
        } catch {
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

    /// A reader of `made`'s samples as they are stored, not yet started,
    /// with the description of them a writer copies them by, when the
    /// composition gives one.
    /// - Throws: `AudioEditError.renderFailed` when AVFoundation refuses the
    ///   reader.
    private static func copyReader(
        of made: AudioEditComposition
    ) async throws -> (reader: AVAssetReader, output: AVAssetReaderOutput, storedFormat: CMFormatDescription?) {
        let tracks = try await made.composition.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw AudioEditError.renderFailed("the composition has no audio") } // l10n: no (a technical reason for the debug log (AudioEditError.renderFailed); the listener hears its fixed sentence)
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: made.composition)
        } catch {
            throw failure(error)
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioEditError.renderFailed("the reader refused the audio") } // l10n: no (a technical reason for the debug log (AudioEditError.renderFailed); the listener hears its fixed sentence)
        reader.add(output)
        return (reader, output, try await track.load(.formatDescriptions).first)
    }

    /// Starts `reader`, of `made`'s samples as they are stored, reads its
    /// `output` to the end, and hands each buffer to `consume`, telling
    /// `progress` how far it is. Samples copied as stored are whole packets,
    /// never cut, and hold no padding a decoder would leave.
    /// - Throws: `CancellationError`, what `consume` throws, or
    ///   `AudioEditError.renderFailed` when the reader fails; the reader is
    ///   cancelled then.
    private static func drain(
        _ output: AVAssetReaderOutput,
        of reader: AVAssetReader,
        made: AudioEditComposition,
        progress: (@Sendable (Double) -> Void)?,
        consume: (CMSampleBuffer) async throws -> Void
    ) async throws {
        guard reader.startReading() else { throw failure(reader.error) }
        let total = Double(made.frames)
        var written = 0
        do {
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                try await consume(buffer)
                written += CMSampleBufferGetNumSamples(buffer)
                progress?(total > 0 ? min(1, Double(written) / total) : 1)
            }
        } catch {
            reader.cancelReading()
            throw error
        }
        guard reader.status == .completed else { throw failure(reader.error) }
    }

    /// The frames of `buffer`, decoded audio, from frame `offset` on, at
    /// most `count` of them: `buffer` itself when that is all of it; nil
    /// when none are left to keep. A cut buffer loses the trims its ends
    /// had, which the cut has made, so a writer that applies trims never
    /// cuts it again.
    /// - Throws: `AudioEditError.renderFailed` when the frames can't be
    ///   copied.
    private static func slice(of buffer: CMSampleBuffer, from offset: Int, atMost count: Int) throws -> CMSampleBuffer? {
        let frames = CMSampleBufferGetNumSamples(buffer)
        let kept = min(frames - offset, count)
        guard kept > 0 else { return nil }
        guard kept < frames else { return buffer }
        var cut: CMSampleBuffer?
        let status = CMSampleBufferCopySampleBufferForRange(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleRange: CFRange(location: offset, length: kept),
            sampleBufferOut: &cut
        )
        guard status == noErr, let cut else { throw AudioEditError.renderFailed("\(NSOSStatusErrorDomain) \(status)") }
        CMRemoveAttachment(cut, key: kCMSampleBufferAttachmentKey_TrimDurationAtStart)
        CMRemoveAttachment(cut, key: kCMSampleBufferAttachmentKey_TrimDurationAtEnd)
        return cut
    }

    /// How long before a piece its read starts, in seconds: sound decoded
    /// and dropped, so the decoder has settled by the piece's first frame.
    /// An MP3 frame decodes right only after the frames before it: read
    /// from its own start, a piece in the middle of an MP3 began with 20 to
    /// 85 ms of zeros or wrong sound at 22.05 and 44.1 kHz (the review of
    /// November 15, 2026). Read from half a second before, every cut of
    /// MP3s from 8 kHz at 8 kbit/s to 48 kHz at 320 kbit/s decoded as its
    /// file does whole.
    static let readRunUp: TimeInterval = 0.5

    /// How long past a piece its read runs, in seconds: sound decoded and
    /// cut off, so the piece's last frames are whole. A decoder hands over a
    /// frame's sound only once it has read on, and a resampler likewise:
    /// read to its own end, a piece ending in the middle of an MP3 could
    /// end in some 196 frames of zeros (22.05 kHz at 32 kbit/s), and one of
    /// a file at another rate than the render's came up 8 to 31 frames
    /// short.
    static let readRunPast: TimeInterval = 0.25

    /// Reads the sound of `pieces`, every piece of the stretches of a
    /// timeline at `timelineRate`, their files opened and their ranges
    /// checked (`AudioEditStretchSound.pieces(of:sources:)`), piece by
    /// piece: each from its own file, by an asset reader of its own over
    /// that piece and a little either side of it (`readRunUp`,
    /// `readRunPast`), decoded to `settings.readerSettings`, cut to the
    /// piece's own frames, and handed to `consume` buffer by buffer, timed
    /// at its place in the edits; telling `progress` how far it is. Memory
    /// stays flat however many pieces there are (`read`'s autorelease
    /// pools, and a pause after each piece).
    ///
    /// Every render that decodes reads so, not through the timeline's
    /// composition (`AudioEditComposition`): AVFoundation decodes an MP3
    /// wrongly through one. In a harness of an MP3 book's save, a cut of its
    /// second second, every read through the composition silenced some
    /// 100 ms around the cut (796 frames at 8 kHz), and 192 reads in 1,200
    /// shifted the sound after the cut 337 frames early, most of them ending
    /// that much short of the edits, which the save then refused
    /// (`AudioEditBookRender`; the full suites of November 13 to 15, 2026).
    /// Read piece by piece, each from its run-up to its run-past, every cut
    /// of MP3s at seven encodings, AAC, AIFF, FLAC, and Apple Lossless
    /// decoded as its file does whole; read over just its range, as at
    /// first, a piece of an MP3 at 22.05 or 44.1 kHz began wrong.
    /// - Throws: `CancellationError`, what `consume` throws, or
    ///   `AudioEditError.renderFailed` when a reader fails or a piece
    ///   decodes short by more than `fillableShortfall`.
    static func readStretches(
        _ pieces: [AudioEditStretchSound.Piece],
        timelineRate: Double,
        settings: AudioRenderSettings,
        progress: (@Sendable (Double) -> Void)?,
        consume: (CMSampleBuffer) async throws -> Void
    ) async throws {
        // Frames at the render's rate for each frame of the edits.
        let ratio = settings.sampleRate / timelineRate
        let total = Int((Double(pieces.reduce(0) { $0 + $1.length }) * ratio).rounded())
        var position: Int64 = 0
        var written = 0
        // The format the readers decode to, as the last buffer read was:
        // silence making up a piece is made in it.
        var format: CMFormatDescription?
        for piece in pieces {
            position += piece.length
            // Each piece ends where the edits so far end at the render's
            // rate, so rounding never adds up from piece to piece.
            let end = Int((Double(position) * ratio).rounded())
            try await read(
                piece,
                settings: settings,
                handingOver: end - written,
                from: written,
                of: total,
                format: &format,
                progress: progress,
                consume: consume
            )
            written = end
            // A pause after each piece lets go of whatever else was
            // autoreleased while it was read (`read`'s pools).
            await Task.yield()
        }
    }

    /// The most a piece may decode short of its length, in seconds, made up
    /// with silence at its end: as much as a save lets its file differ from
    /// the edits (`AudioEditBookRender.lengthTolerance`). A resampler keeps
    /// back the last 8 to 31 frames of a file read to its very end, as a
    /// take recorded at another rate than the book's is when used to its
    /// last frame; a piece short by more is refused, its sound not all
    /// there.
    static let fillableShortfall = AudioEditBookRender.lengthTolerance

    /// Reads `piece` with an asset reader of its own, decoded to
    /// `settings.readerSettings`, from `readRunUp` before it to
    /// `readRunPast` past it, as far as its file goes either way, and hands
    /// `consume` exactly `frames` frames of the piece's own, buffer by
    /// buffer, each timed as following the `start` frames handed over
    /// before it, telling `progress` how far the render's `total` frames it
    /// has come. Frames the read comes up short of, at most
    /// `fillableShortfall`, are made up with silence in `format`, the
    /// format the readers decode to, which each buffer read updates.
    /// - Throws: `CancellationError`, what `consume` throws, or
    ///   `AudioEditError.renderFailed` when AVFoundation refuses or fails the
    ///   read, or it comes up shorter; the reader is cancelled then.
    private static func read(
        _ piece: AudioEditStretchSound.Piece,
        settings: AudioRenderSettings,
        handingOver frames: Int,
        from start: Int,
        of total: Int,
        format: inout CMFormatDescription?,
        progress: (@Sendable (Double) -> Void)?,
        consume: (CMSampleBuffer) async throws -> Void
    ) async throws {
        let scale = CMTimeScale(settings.sampleRate.rounded())
        // The run-up in whole frames at the render's rate, so that the
        // piece's first frame is the first one kept: half a second, or as
        // much as the file has before the piece.
        let runUp = min(
            Int64((readRunUp * settings.sampleRate).rounded()),
            CMTimeConvertScale(piece.range.start, timescale: scale, method: .roundTowardNegativeInfinity).value
        )
        let readStart = CMTimeSubtract(piece.range.start, CMTime(value: runUp, timescale: scale))
        let runPastEnd = CMTimeAdd(piece.range.end, CMTime(seconds: readRunPast, preferredTimescale: scale))
        // A piece ends at most a frame past its file's end
        // (`AudioEditStretchSound.pieces(of:sources:)`), so the read ends
        // after it starts; the bound only keeps the range well formed.
        let readEnd = CMTimeMaximum(CMTimeMinimum(runPastEnd, piece.sourceEnd), piece.range.start)
        // The reader is made, and each buffer copied, in an autorelease pool
        // of its own, so what AVFoundation autoreleases for them goes with
        // them rather than when the render's task next pauses, which an MP3
        // render with TextMouth's own LAME never does: some 250 KB stayed
        // for each piece, 150 MB for 600 in mp3render's probe.
        let (reader, output) = try autoreleasepool {
            try startedReader(of: piece, over: CMTimeRange(start: readStart, end: readEnd), settings: settings)
        }
        // The run-up's frames dropped so far, and the piece's handed over.
        var dropped = 0
        var handed = 0
        do {
            while let buffer = autoreleasepool(invoking: { output.copyNextSampleBuffer() }) {
                try Task.checkCancellation()
                // The run-up is dropped and the run-past cut off; the
                // run-past is still read to its end, so the reader ends as
                // completed.
                let drop = min(Int(runUp) - dropped, CMSampleBufferGetNumSamples(buffer))
                dropped += drop
                format = CMSampleBufferGetFormatDescription(buffer) ?? format
                let placed = try autoreleasepool {
                    try slice(of: buffer, from: drop, atMost: frames - handed).map {
                        try timed($0, at: start + handed, rate: settings.sampleRate)
                    }
                }
                guard let sample = placed else { continue }
                try await consume(sample)
                handed += CMSampleBufferGetNumSamples(sample)
                progress?(total > 0 ? min(1, Double(start + handed) / Double(total)) : 1)
            }
        } catch {
            reader.cancelReading()
            throw error
        }
        guard reader.status == .completed else { throw failure(reader.error) }
        let missing = frames - handed
        guard missing > 0 else { return }
        guard Double(missing) <= settings.sampleRate * fillableShortfall else {
            throw AudioEditError.renderFailed("a stretch of the edits decoded to \(handed) of \(frames) frames") // l10n: no (a technical reason for the debug log (AudioEditError.renderFailed); the listener hears its fixed sentence)
        }
        // Should no buffer have been read yet, the format is the one the
        // settings describe, which differs from the readers' only in making
        // 8-bit integers unsigned (`silence` fills those with their middle).
        guard let silentFormat = format ?? AVAudioFormat(settings: settings.readerSettings)?.formatDescription else {
            throw AudioEditError.renderFailed("the decoded audio has no format") // l10n: no (a technical reason for the debug log (AudioEditError.renderFailed); the listener hears its fixed sentence)
        }
        try await consume(try silence(missing, in: silentFormat, at: start + handed, rate: settings.sampleRate))
        progress?(total > 0 ? min(1, Double(start + frames) / Double(total)) : 1)
    }

    /// A started reader of `range` of `piece`'s file, in that file's own
    /// time, and its output, decoded to `settings.readerSettings`.
    /// - Throws: `AudioEditError.renderFailed` when AVFoundation refuses the
    ///   reader or fails to start it.
    private static func startedReader(
        of piece: AudioEditStretchSound.Piece,
        over range: CMTimeRange,
        settings: AudioRenderSettings
    ) throws -> (reader: AVAssetReader, output: AVAssetReaderAudioMixOutput) {
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: piece.asset)
        } catch {
            throw failure(error)
        }
        reader.timeRange = range
        let output = try makingWithoutRaising {
            AVAssetReaderAudioMixOutput(audioTracks: [piece.track], audioSettings: settings.readerSettings)
        }
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioEditError.renderFailed("the reader refused the audio") } // l10n: no (a technical reason for the debug log (AudioEditError.renderFailed); the listener hears its fixed sentence)
        reader.add(output)
        guard reader.startReading() else { throw failure(reader.error) }
        return (reader, output)
    }

    /// `frames` frames of silence in `format`, decoded audio as a reader
    /// hands it over, timed to start `frame` frames into the render at
    /// `rate`.
    /// - Throws: `AudioEditError.renderFailed` when the buffer can't be made.
    private static func silence(_ frames: Int, in format: CMFormatDescription, at frame: Int, rate: Double) throws -> CMSampleBuffer {
        guard let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee, stream.mBytesPerFrame > 0 else {
            throw AudioEditError.renderFailed("the decoded audio has no frame size") // l10n: no (a technical reason for the debug log (AudioEditError.renderFailed); the listener hears its fixed sentence)
        }
        let length = frames * Int(stream.mBytesPerFrame)
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        )
        guard status == noErr, let block else { throw AudioEditError.renderFailed("\(NSOSStatusErrorDomain) \(status)") }
        // Silence is zero in floats and in signed integers; an 8-bit integer
        // without a sign holds it at its middle, 128.
        let isUnsignedByte = stream.mBitsPerChannel == 8
            && stream.mFormatFlags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsSignedInteger) == 0
        status = CMBlockBufferFillDataBytes(
            with: CChar(bitPattern: isUnsignedByte ? 0x80 : 0),
            blockBuffer: block,
            offsetIntoDestination: 0,
            dataLength: length
        )
        guard status == noErr else { throw AudioEditError.renderFailed("\(NSOSStatusErrorDomain) \(status)") }
        var sample: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format,
            sampleCount: frames,
            presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(rate.rounded())),
            packetDescriptions: nil,
            sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { throw AudioEditError.renderFailed("\(NSOSStatusErrorDomain) \(status)") }
        return sample
    }

    /// `sample`, decoded audio, timed to start `frame` frames into the
    /// render at `rate`, each of its frames lasting one frame there: so the
    /// pieces a writer is given follow one another, whatever their files'
    /// own times.
    /// - Throws: `AudioEditError.renderFailed` when the buffer can't be
    ///   copied.
    private static func timed(_ sample: CMSampleBuffer, at frame: Int, rate: Double) throws -> CMSampleBuffer {
        let scale = CMTimeScale(rate.rounded())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: scale),
            presentationTimeStamp: CMTime(value: CMTimeValue(frame), timescale: scale),
            decodeTimeStamp: .invalid
        )
        var placed: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sample,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &placed
        )
        guard status == noErr, let placed else { throw AudioEditError.renderFailed("\(NSOSStatusErrorDomain) \(status)") }
        return placed
    }

    /// Appends `sample` to `input` once it is ready for more. Internal so the
    /// import's chapter track writer appends the same way (`ChapterTrackWriter`).
    static func append(_ sample: CMSampleBuffer, to input: AVAssetWriterInput, of writer: AVAssetWriter) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw failure(writer.error) }
            try await Task.sleep(for: .milliseconds(1))
        }
        guard input.append(sample) else { throw failure(writer.error) }
    }

    /// Makes what `make` creates through an AVFoundation initializer, which
    /// raises an Objective-C exception, ending the app, for settings it
    /// refuses (a sample depth it doesn't take). The render fails instead, as
    /// any other refusal of the writer does.
    /// - Throws: `AudioEditError.renderFailed`, naming the exception.
    static func makingWithoutRaising<Value>(_ make: () -> Value) throws -> Value {
        do {
            return try ObjCException.making(make)
        } catch let raised as ObjCException.Raised {
            throw AudioEditError.renderFailed(raised.summary)
        }
    }

    /// `error`, from AVFoundation, as a render failure naming its domain and
    /// code only: its description can name files by their full paths.
    static func failure(_ error: Error?) -> AudioEditError {
        guard let error else { return .renderFailed("no error was given") } // l10n: no (a technical reason for the debug log (AudioEditError.renderFailed); the listener hears its fixed sentence)
        let failure = error as NSError
        return .renderFailed("\(failure.domain) \(failure.code)")
    }
}
