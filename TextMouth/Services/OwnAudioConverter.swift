import AVFoundation

/// Converts a file that one of TextMouth's own audio readers reads (True
/// Audio, and the other formats of `OwnAudioFormat`) to an .m4a file, for
/// `ImportAudioConverter`: neither macOS nor iOS decodes these formats, so
/// no `afconvert` could do it.
///
/// The reader decodes the file inside the app, a block at a time, and the
/// whole-number samples go to Apple's encoder through `AVAssetWriter`, which
/// only ever sees plain PCM made here, never the source. A lossless source
/// becomes Apple Lossless at its own bit depth, and what the .m4a holds is
/// the source's samples exactly (measured on November 15, 2026, at 8, 16,
/// 20, 24, and 32 bits); a lossy one (a WavPack hybrid file without its
/// correction file) becomes AAC; with its correction file beside it
/// (`companion(of:)`) it is lossless. More than two channels are mixed to
/// stereo here (`OwnAudioSamples.stereo`). The file's tags (APEv2, ID3v2,
/// ID3v1) are written into the .m4a.
///
/// Nothing here runs on the main thread: `ImportAudioConverter.convert`
/// calls it from the import's own task, which the import's Stop cancels;
/// the cancellation is seen between two blocks.
enum OwnAudioConverter {
    /// The most frames handed to the encoder in one buffer.
    static let framesPerAppend = 32_768

    /// The Apple Lossless bit depth a book's own file is rewritten at when it
    /// holds `depth` bits a sample: the same, but 24 for 20. AVFoundation's
    /// writer makes a 20-bit file whose audio the media check cannot decode
    /// (train 1115-2137), and 24 bits hold every 20-bit sample exactly. An
    /// import never makes a 20-bit file now (`ImportAudioConverter.
    /// appleLosslessBitDepth(forBitsPerSample:)` widens it), but a book
    /// imported before may hold one, which the audio editor reads this way.
    static func writtenBitDepth(forAppleLossless depth: Int) -> Int {
        depth == 20 ? 24 : depth
    }

    /// The format of the file at `url` among those TextMouth's own readers
    /// read, told from its first bytes; nil for any other file, one that
    /// cannot be opened, and one only in the cloud (never downloaded).
    static func format(of url: URL) -> OwnAudioFormat? {
        guard !DatalessFiles.isDataless(url), let bytes = OwnAudioBytes(path: url.path) else { return nil }
        return OwnAudioFormat.of(bytes)
    }

    /// The companion of the file at `url`: the file beside it, of the same
    /// name, that completes it (a hybrid WavPack file's correction file,
    /// `OwnAudioFormat.companionExtension`), found by the names alone; nil
    /// when `url`'s extension is of no format that has one, when no such
    /// file is there, and when it is only in the cloud. An import copies it
    /// with its file, and it goes where its file goes once that is converted.
    static func companion(of url: URL) -> URL? {
        let ending = url.pathExtension.lowercased()
        guard let format = OwnAudioFormat.allCases.first(where: { $0.fileExtensions.contains(ending) }),
              let companionEnding = format.companionExtension else { return nil }
        let stem = url.deletingPathExtension()
        for candidate in [companionEnding, companionEnding.uppercased()] {
            let beside = stem.appendingPathExtension(candidate)
            var isFolder: ObjCBool = false
            if FileManager.default.fileExists(atPath: beside.path, isDirectory: &isFolder), !isFolder.boolValue,
               !DatalessFiles.isDataless(beside) {
                return beside
            }
        }
        return nil
    }

    /// The tags of the file at `url`, read by the own readers' tag reader;
    /// nil when it is not a file of one of the readers' formats, which
    /// AVFoundation reads no tag of. An import names its book by these.
    static func tags(of url: URL) -> OwnAudioTags? {
        guard !DatalessFiles.isDataless(url), let bytes = OwnAudioBytes(path: url.path),
              OwnAudioFormat.of(bytes) != nil else { return nil }
        return OwnAudioTagReader.read(bytes)
    }

    /// The bytes of the companion of the file at `url`, when it has one.
    private static func companionBytes(of url: URL) -> OwnAudioBytes? {
        companion(of: url).flatMap { OwnAudioBytes(path: $0.path) }
    }

    /// What `ImportAudioConverter` needs to know of the file at `url`, read
    /// from its header by its own reader; nil when it is not a file of one
    /// of the readers' formats.
    /// - Throws: `ImportAudioConverter.Failure.notRead` when it is one and
    ///   its reader refuses it, and for a .wv file from before WavPack 4,
    ///   which starts as a WAVE file does and must not be taken for one.
    static func sourceInfo(of url: URL) throws -> ImportAudioConverter.SourceInfo? {
        guard !DatalessFiles.isDataless(url), let bytes = OwnAudioBytes(path: url.path) else { return nil }
        guard let format = OwnAudioFormat.of(bytes) else {
            if OwnAudioFormat.wavPack.fileExtensions.contains(url.pathExtension.lowercased()),
               OwnAudioLittleEndian.holds(bytes.readUpTo(at: 0, count: 4), "RIFF", at: 0) {
                throw ImportAudioConverter.Failure.notRead(
                    fileName: url.lastPathComponent, problem: .unsupported(reason: OwnAudioWording.wavPackOld))
            }
            return nil
        }
        do {
            let decoder = try format.decoder(of: bytes, companion: companionBytes(of: url))
            // A header can promise any length. No watchdog stands over a
            // decoder that runs in the app, so a length no recording has (over
            // a year, as for every other source) is refused as damage before
            // any of it is decoded.
            guard decoder.stream.duration <= AudioFileInfo.maximumPlausibleDuration else { throw OwnAudioError.damaged }
            var info = sourceInfo(for: decoder.stream, format: format)
            info.chapters = chapters(in: OwnAudioTagReader.read(bytes), lasting: decoder.stream.duration)
            return info
        } catch let problem as OwnAudioError {
            throw ImportAudioConverter.Failure.notRead(fileName: url.lastPathComponent, problem: problem)
        }
    }

    /// The chapters that the cue sheet in `tags` places in a file lasting
    /// `duration` seconds (an APEv2 `Cuesheet` item, as WavPack's and
    /// Monkey's Audio's encoders write one): each track that begins in the
    /// sheet's first file, before the audio ends, titled as a cue sheet's
    /// tracks are (`CueSheetArrangement.heading(of:author:)`). None without
    /// a sheet. A conversion that keeps chapters writes them into the .m4a
    /// (`ImportAudioConverter.convert(_:naming:using:keepingChapters:)`).
    static func chapters(in tags: OwnAudioTags, lasting duration: TimeInterval) -> [NeroChapterReader.Chapter] {
        guard !tags.cueSheet.isEmpty else { return [] }
        let sheet = CueSheet.parse(tags.cueSheet)
        let author = tags.artist.isEmpty ? sheet.performer : tags.artist
        return sheet.tracks
            .filter { $0.fileIndex == 0 && $0.startTime < duration }
            .map { NeroChapterReader.Chapter(title: CueSheetArrangement.heading(of: $0, author: author), start: $0.startTime) }
    }

    /// `stream`, a stream of `format`, as `ImportAudioConverter` describes
    /// a source. Floating-point samples have no bit depth there, so they
    /// are written at 24 bits; a stream of more than two channels has a
    /// layout only when it names one.
    static func sourceInfo(for stream: OwnAudioStream, format: OwnAudioFormat) -> ImportAudioConverter.SourceInfo {
        ImportAudioConverter.SourceInfo(
            sampleRate: Double(stream.sampleRate), channels: stream.channels, duration: stream.duration,
            formatID: format.formatID, bitsPerSample: stream.isFloat ? nil : stream.bitsPerSample,
            isLossless: stream.isLossless,
            hasChannelLayout: stream.channels <= ImportAudioConverter.maximumChannels || stream.channelMask != nil,
            ownReader: format
        )
    }

    /// Decodes `source`, a file of `format`, and writes it to `staged` as
    /// `target` says: Apple Lossless at `target.appleLosslessBitDepth`, or
    /// AAC. Nothing is left at `staged` by a failure.
    /// - Throws: `ImportAudioConverter.Failure` (`notRead` when the reader
    ///   gives the file up, `notWritten` when the encoder does, and on the
    ///   iPhone `killed` when the app is short of memory), or
    ///   `CancellationError`.
    static func write(
        _ source: URL,
        of format: OwnAudioFormat,
        to staged: URL,
        target: ImportAudioConverter.Target
    ) async throws {
        let name = source.lastPathComponent
        do {
            guard let bytes = OwnAudioBytes(path: source.path) else { throw OwnAudioError.truncated }
            var decoder = try format.decoder(of: bytes, companion: companionBytes(of: source))
            #if os(iOS)
            // A header may ask for far more memory a block than a recording needs, and iOS ends the app
            // past its limit: the iPhone asks the memory floor between blocks (`OwnAudioMemoryWatch`).
            let beforeEachBlock = OwnAudioMemoryWatch(fileName: name).check
            #else
            let beforeEachBlock: () throws -> Void = {}
            #endif
            try await write(
                &decoder, tags: OwnAudioTagReader.read(bytes), to: staged, target: target, beforeEachBlock: beforeEachBlock)
        } catch let problem as OwnAudioError {
            try? FileManager.default.removeItem(at: staged)
            throw ImportAudioConverter.Failure.notRead(fileName: name, problem: problem)
        } catch let AudioEditError.renderFailed(reason) {
            // The reason is an error's domain and code, which never quote a path.
            try? FileManager.default.removeItem(at: staged)
            throw ImportAudioConverter.Failure.notWritten(fileName: name, reason: reason)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    /// The pass of one of the own readers: `writeBlocks` with `decoder`'s
    /// stream and blocks, `beforeEachBlock` run before each is decoded (the
    /// iPhone's memory check; nothing on the Mac).
    /// - Throws: `OwnAudioError` from the decoder, what `beforeEachBlock`
    ///   throws, `AudioEditError` naming an AVFoundation error's domain and
    ///   code, or `CancellationError`.
    private static func write(
        _ decoder: inout any OwnAudioDecoder,
        tags: OwnAudioTags,
        to staged: URL,
        target: ImportAudioConverter.Target,
        beforeEachBlock: () throws -> Void
    ) async throws {
        try await writeBlocks(of: decoder.stream, tags: tags, to: staged, target: target) {
            try beforeEachBlock()
            return try decoder.nextBlock()
        }
    }

    /// The pass every conversion that decodes in TextMouth's own code writes
    /// through (DRY: one writer): every block `next` gives, samples of
    /// `stream`, made whole numbers, mixed to `target`'s channels, packed,
    /// and appended to a writer of `staged` that carries `tags`. TextMouth's
    /// own readers give their decoder's blocks; the FFmpeg import gives the
    /// bundled helper's (`FFmpegAudioConverter`, FMT50), which writes its
    /// samples as these readers do. Nothing is left at `staged` by a failure
    /// of the writer; the caller removes the file for any other.
    /// - Throws: what `next` throws, `AudioEditError` naming an AVFoundation
    ///   error's domain and code, or `CancellationError`.
    static func writeBlocks(
        of stream: OwnAudioStream,
        tags: OwnAudioTags,
        to staged: URL,
        target: ImportAudioConverter.Target,
        next: () async throws -> [Int32]?
    ) async throws {
        let bits = stream.isFloat ? OwnAudioSamples.bitsForFloats : stream.bitsPerSample
        // Sixteen bits go to the encoder as they are; anything wider in 32-bit numbers.
        let container = bits <= 16 ? 16 : 32
        let gains = stream.channels > target.channels
            ? OwnAudioSamples.stereoGains(channels: stream.channels, mask: stream.channelMask ?? 0) : []
        let settings = AudioRenderSettings(
            format: target.appleLosslessBitDepth == nil ? .aacM4A : .alacM4A,
            sampleRate: target.sampleRate, channels: target.channels, bitRate: target.bitRate,
            bitsPerSample: target.appleLosslessBitDepth ?? 16, isFloat: false
        )
        let description = try pcmDescription(sampleRate: stream.sampleRate, channels: target.channels, container: container)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: staged, fileType: settings.format.fileType)
        } catch {
            throw AudioEditRenderer.failure(error)
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings.outputSettings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw AudioEditError.renderFailed("the writer refused the audio") } // l10n: no (a technical reason in English inside AudioEditError.renderFailed, as the other writers give it)
        writer.add(input)
        let items = metadataItems(for: tags)
        if !items.isEmpty { writer.metadata = items }
        guard writer.startWriting() else { throw AudioEditRenderer.failure(writer.error) }
        writer.startSession(atSourceTime: .zero)

        do {
            var written = 0
            while var block = try await next() {
                try Task.checkCancellation()
                if stream.isFloat { block = OwnAudioSamples.wholeNumbers(fromFloats: block) }
                if !gains.isEmpty { block = OwnAudioSamples.stereo(block, gains: gains) }
                // A decoder's block may hold half a minute (a Monkey's Audio
                // frame at Insane); the encoder is fed a piece at a time.
                let frames = block.count / target.channels
                for start in stride(from: 0, to: frames, by: Self.framesPerAppend) {
                    let count = min(Self.framesPerAppend, frames - start)
                    let piece = Array(block[start * target.channels..<(start + count) * target.channels])
                    let buffer = try sampleBuffer(
                        OwnAudioSamples.packed(piece, bits: bits, container: container),
                        frames: count, startingAt: written, sampleRate: stream.sampleRate, description: description
                    )
                    try await AudioEditRenderer.append(buffer, to: input, of: writer)
                    written += count
                }
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw AudioEditRenderer.failure(writer.error) }
    }

    // MARK: - Tags

    /// `tags` as the common metadata an .m4a carries and the import reads
    /// back (`AudioPlaybackService.extractFullMetadata`): the title,
    /// artist, album, genre, and date that are not empty.
    static func metadataItems(for tags: OwnAudioTags) -> [AVMetadataItem] {
        let fields: [(AVMetadataIdentifier, String)] = [
            (.commonIdentifierTitle, tags.title),
            (.commonIdentifierArtist, tags.artist),
            (.commonIdentifierAlbumName, tags.album),
            (.commonIdentifierType, tags.genre),
            (.commonIdentifierCreationDate, tags.date),
        ]
        return fields.filter { !$0.1.isEmpty }.map { AudioEditRenderer.tag($0.0, $0.1 as NSString) }
    }

    // MARK: - Sample Buffers

    /// The description of interleaved signed whole-number PCM, `container`
    /// bits a sample, as the writer is fed it.
    private static func pcmDescription(sampleRate: Int, channels: Int, container: Int) throws -> CMAudioFormatDescription {
        let bytesPerFrame = UInt32(container / 8 * channels)
        var basic = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: UInt32(container), mReserved: 0
        )
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &basic, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description
        )
        guard status == noErr, let description else { throw osFailure(status) }
        return description
    }

    /// One buffer of PCM for the writer: `bytes`, holding `frames` frames
    /// as `description` says, the first of them frame number `start` of the
    /// file.
    private static func sampleBuffer(
        _ bytes: [UInt8],
        frames: Int,
        startingAt start: Int,
        sampleRate: Int,
        description: CMAudioFormatDescription
    ) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        guard status == noErr, let block else { throw osFailure(status) }
        status = bytes.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard status == noErr else { throw osFailure(status) }
        var buffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block, formatDescription: description, sampleCount: frames,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(clamping: sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &buffer
        )
        guard status == noErr, let buffer else { throw osFailure(status) }
        return buffer
    }

    /// A Core Media call's failure `status`, named by its domain and code
    /// as every render failure is.
    private static func osFailure(_ status: OSStatus) -> AudioEditError {
        .renderFailed("\(NSOSStatusErrorDomain) \(status)")
    }
}
