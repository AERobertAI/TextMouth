import AVFoundation

// MARK: - Failures

/// Why one chapter of a speech export (FMT43) could not be spoken into its
/// file, in the words the export reports. Each names the chapter by its
/// title, except a voice that cannot be recorded at all, which no chapter
/// gets past.
enum SpeechRenderFailure: LocalizedError, Equatable {
    /// The speech engine refused part of the chapter, guarded as every
    /// render begins and again with every bracket silent; or refused it
    /// after part of its audio was written, which cannot be taken back.
    case refused(String)
    /// The voice wrote no sound for any of the chapter's text: no audio at
    /// all, or only silence, which is what the Mac's voices hand back for
    /// text they can't speak, such as a script they don't read or a line of
    /// symbols (`SpeechChapterRenderer.silenceCeiling`).
    case noSound(String)
    /// The voice wrote nothing for the synthesizer's stall limit: before its
    /// first buffer, in the time the text's length gives it, or for a minute
    /// after a buffer.
    case stalled(String)
    /// The voice's audio changed its sample rate, channel count, kind of
    /// sample, or interleaving partway through the chapter.
    case formatChanged(String)
    /// The book's voice cannot write to a file: it is not installed, or it
    /// is a Personal Voice.
    case unusableVoice

    var errorDescription: String? {
        switch self {
        case .refused(let title):
            return "The Mac's speech engine refused to speak part of “\(title)”, even with its brackets made silent."
        case .noSound(let title):
            return "The voice made no sound for “\(title)”. Check that the book's voice speaks the book's language."
        case .stalled(let title):
            return "The voice stopped making sound partway through “\(title)”, and TextMouth stopped waiting for it."
        case .formatChanged(let title):
            return "The voice changed its kind of audio partway through “\(title)”."
        case .unusableVoice:
            return "The book's voice can't be recorded to a file. "
                + "Choose another voice for this book with the Voice button in its reader, then export again."
        }
    }
}

// MARK: - The Renderer

/// What a chapter's file holds once it is spoken.
struct RenderedSpeechChapter: Equatable, Sendable {
    /// Frames in the file: the speech and the silence after it.
    let frameCount: Int64
    /// The file's frames a second: the voice's own rate.
    let sampleRate: Double
    /// The file's channels: the voice's own count.
    let channelCount: Int
}

/// Speaks one chapter of a speech export, a title and its texts, into a
/// 16-bit linear PCM CAF file (FMT43), as `AudioEngineService` renders
/// speech, but at the export's own rate and pitch, set on each utterance as
/// direct speech sets them, and through a `SpeechBufferSynthesizing`, so
/// that tests never run a real synthesizer.
enum SpeechChapterRenderer {
    /// The most silence a chapter's file can end with, in seconds: a pause
    /// between chapters is a few seconds long, and the cap keeps a wrong
    /// length from filling the disk.
    static let maximumTrailingSilence: TimeInterval = 3_600

    /// The loudest a chapter's speech can be, as a fraction of full scale,
    /// and still count as no sound: 0.001, which is -60 dBFS.
    ///
    /// For text a voice can't speak, the Mac's voices never hand back
    /// nothing. They hand back one buffer of 256 frames of silence, measured
    /// with Samantha, Eddy, Flo, and Alex for Japanese, "⁂", "❦", "—", and
    /// "* * *". Its loudest sample was 0.00024 (-72 dBFS) of dither, while
    /// speech peaks far above -20 dBFS. So a chapter that never rises above
    /// this is one the voice couldn't speak, however many frames it holds.
    static let silenceCeiling = 0.001

    /// Speak the chapter `title`, whose texts are `texts`, into a new CAF at
    /// `url`, followed by `trailingSilence` seconds of silence, and close it.
    ///
    /// Each text is cut into utterances with the reader's own chunking
    /// (`DirectSpeechChunk`), at most `maximumUtteranceLength` UTF-16 units
    /// each and never inside a word; a chunk with nothing to say is passed
    /// over. By default a chapter of up to 100,000 units is one utterance,
    /// as the engine renders it, so its intonation stays whole. Each
    /// utterance is guarded as every render begins
    /// (`AudioEngineService.RenderGuard.markup`); one the speech engine
    /// refuses before writing any of its audio is written once more with
    /// every bracket silent (`.everyBracket`).
    ///
    /// The file is made at the first buffer, in that buffer's sample rate
    /// and channel count, as 16-bit little-endian interleaved integers; every
    /// later buffer must have the same rate, channel count, kind of sample,
    /// and interleaving. The file is closed before this returns, so the
    /// caller may rename it at once.
    ///
    /// Call it off the main thread: it blocks while the voice speaks.
    ///
    /// - Parameters:
    ///   - title: The chapter's title, which a failure names.
    ///   - texts: The chapter's texts, spoken in order.
    ///   - voiceIdentifier: The voice that speaks them.
    ///   - wordsPerMinute: The speaking rate (`SpeechService.rateForWPM`).
    ///   - pitch: The pitch, clamped as direct speech clamps it
    ///     (`SpeechService.clampedPitch`).
    ///   - trailingSilence: Seconds of silence after the speech, rounded to
    ///     whole frames at the file's rate: none when it is not positive or
    ///     not a number, and at most `maximumTrailingSilence`.
    ///   - url: Where the file goes: a path with the extension `caf`, from
    ///     which `AVAudioFile` takes the file's type, and nothing there yet.
    ///   - synthesizer: What speaks the utterances into buffers.
    ///   - maximumUtteranceLength: The most UTF-16 units of an utterance
    ///     before the word that limit would cut; at least 1.
    ///   - cancellation: The export's Stop.
    ///   - framesWritten: Hears the chapter's frames of speech so far after
    ///     each buffer is written, on the thread the synthesizer delivers it
    ///     on, the main thread for the Mac's synthesizer, while the write
    ///     waits for it: it must be quick and must not wait for the thread
    ///     that called `render`. It is escaping because the synthesizer's
    ///     buffer handler, which calls it, is.
    /// - Returns: The frames written, speech and silence, and the file's
    ///   sample rate and channel count.
    /// - Throws: A `SpeechRenderFailure`; `CancellationError` at Stop; or the
    ///   file system's error. Whatever is at `url` is removed first.
    static func render(
        title: String,
        texts: [String],
        voiceIdentifier: String,
        wordsPerMinute: Double,
        pitch: Double,
        trailingSilence: TimeInterval,
        to url: URL,
        synthesizer: any SpeechBufferSynthesizing,
        maximumUtteranceLength: Int = SpeechRenderCoordinator.maximumTextLength,
        cancellation: BookExportCancellation,
        framesWritten: @escaping (Int64) -> Void = { _ in }
    ) throws -> RenderedSpeechChapter {
        let file = ChapterAudioFile(url: url, title: title)
        let speaker = ChapterSpeaker(
            title: title,
            voiceIdentifier: voiceIdentifier,
            rate: SpeechService.rateForWPM(wordsPerMinute),
            pitchMultiplier: Float(SpeechService.clampedPitch(pitch)),
            synthesizer: synthesizer,
            cancellation: cancellation,
            file: file,
            framesWritten: framesWritten
        )
        do {
            for text in texts {
                for words in utterances(in: text, maximumLength: maximumUtteranceLength) {
                    try speaker.speak(words)
                }
            }
            // `finish` is the one place that refuses a chapter with no sound
            // in it (a voice that made none, or only silence), so no file
            // is ever completed without it; the catch below removes it.
            return try file.finish(trailingSilence: trailingSilence)
        } catch {
            // A chapter left partway is no use to anyone: closed first, so
            // that nothing writes to it again, then removed.
            file.close()
            try? FileManager.default.removeItem(at: url)
            throw chapterFailure(for: error, title: title)
        }
    }

    /// The parts of `text` spoken as one utterance each, in order: the
    /// reader's chunks of at most `maximumLength` units, each extended to the
    /// end of the word that limit would cut, going on from each chunk's end
    /// while the text goes on; a chunk with nothing to say left out.
    private static func utterances(in text: String, maximumLength: Int) -> [String] {
        // A limit below 1 could step backwards through the text.
        let limit = max(1, maximumLength)
        var parts: [String] = []
        var offset = 0
        while true {
            let chunk = DirectSpeechChunk.starting(at: offset, in: text, maximumLength: limit)
            let words = chunk.words(of: text)
            if ReaderViewModel.hasSpeakableText(words) {
                parts.append(words)
            }
            guard chunk.isPartial else { return parts }
            // A chunk ends where it began only when one white-space
            // character, such as a line break with marks combined onto it,
            // is longer than the limit: step past it, as it says nothing,
            // so the loop always moves on.
            offset = chunk.end > chunk.start
                ? chunk.end
                : text.utf16Offset(of: text.index(after: text.index(atUTF16Offset: chunk.start)))
        }
    }

    /// `error` as the chapter's failure: a synthesizer's stall or unusable
    /// voice in the chapter's own words; anything else, Stop's
    /// `CancellationError`, the chapter's own failures, and the file
    /// system's errors among them, as it is.
    private static func chapterFailure(for error: any Error, title: String) -> any Error {
        switch error as? SpeechWriteFailure {
        case .stalled?:
            return SpeechRenderFailure.stalled(title)
        case .unusableVoice?:
            return SpeechRenderFailure.unusableVoice
        case nil:
            return error
        }
    }
}

// MARK: - One Chapter's Speech

/// What every utterance of one chapter shares, and how each is spoken into
/// the chapter's file.
private struct ChapterSpeaker {
    /// The chapter's title, which a refusal names.
    let title: String
    /// The voice that speaks every utterance.
    let voiceIdentifier: String
    /// The speaking rate, as `AVSpeechUtterance.rate` takes it.
    let rate: Float
    /// The pitch, as `AVSpeechUtterance.pitchMultiplier` takes it.
    let pitchMultiplier: Float
    /// What speaks the utterances into buffers.
    let synthesizer: any SpeechBufferSynthesizing
    /// The export's Stop.
    let cancellation: BookExportCancellation
    /// The file the buffers go into.
    let file: ChapterAudioFile
    /// Hears the chapter's frames of speech after each buffer.
    let framesWritten: (Int64) -> Void

    /// Speak `words` into the file, guarded as every render begins; when the
    /// speech engine refuses that before any of its audio is written, once
    /// more with every bracket silent, as `AudioEngineService` retries a
    /// refused render.
    ///
    /// - Throws: `SpeechRenderFailure.refused` when the retry is refused too,
    ///   or when the first write was refused after some of its audio was
    ///   written, which cannot be taken back out of the file.
    func speak(_ words: String) throws {
        let framesBefore = file.speechFrameCount
        if try write(words, guarded: .markup) == .finished {
            return
        }
        // Refused. Audio it wrote first stays in the file, so only a refusal
        // before its first frame can be tried again.
        guard file.speechFrameCount == framesBefore else {
            throw SpeechRenderFailure.refused(title)
        }
        if try write(words, guarded: .everyBracket) == .refused {
            throw SpeechRenderFailure.refused(title)
        }
    }

    /// Write `words`, guarded by `guarding`, into the file, through the
    /// synthesizer, unless Stop was pressed.
    private func write(_ words: String, guarded guarding: AudioEngineService.RenderGuard) throws -> SpeechWriteEnd {
        try cancellation.checkCancelled()
        let utterance = SpeechExportUtterance(
            text: guarding.apply(to: words),
            voiceIdentifier: voiceIdentifier,
            rate: rate,
            pitchMultiplier: pitchMultiplier
        )
        return try synthesizer.write(utterance, cancellation: cancellation) { buffer in
            try file.append(buffer)
            framesWritten(file.speechFrameCount)
        }
    }
}

/// One chapter's CAF file, as its speech arrives and then its silence:
/// 16-bit linear PCM, made at the first buffer in that buffer's sample rate
/// and channel count.
///
/// Used on one thread at a time: while a write runs, the thread the
/// synthesizer delivers on, the main thread for the Mac's synthesizer,
/// appends its buffers; between writes, the renderer's thread reads the
/// count, and finishes or closes the file. `SpeechBufferSynthesizing`
/// promises that no buffer is handed on once a write has returned or
/// thrown, so the two never overlap.
private final class ChapterAudioFile {
    /// Where the file is.
    private enum State {
        /// No buffer has come: the file is made at the first.
        case awaitingFirstBuffer
        /// The file is open for writing, and every buffer must be of the
        /// first buffer's kind, `format`.
        case open(AVAudioFile, format: AVAudioFormat)
        /// The file is closed: nothing more is written to it.
        case closed
    }

    /// Frames in each buffer of the silence written after the speech.
    private static let silencePieceFrameCount: AVAudioFrameCount = 16_384

    /// Where the file goes.
    private let url: URL
    /// The chapter's title, which a change of format names.
    private let title: String
    /// Where the file is.
    private var state = State.awaitingFirstBuffer
    /// Frames of speech written so far.
    private(set) var speechFrameCount: Int64 = 0
    /// The loudest sample of the speech written so far, as a fraction of
    /// full scale, from 0 to 1.
    private(set) var loudestSample = 0.0

    /// Whether the speech written so far has sound in it: a frame louder
    /// than `SpeechChapterRenderer.silenceCeiling`. Frames alone are not
    /// enough, since a voice hands back silence for text it can't speak.
    var hasSound: Bool {
        loudestSample > SpeechChapterRenderer.silenceCeiling
    }

    /// A file at `url` for the chapter `title`, made at its first buffer.
    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    /// Write `buffer`'s frames after those written so far, making the file
    /// at the first buffer. A buffer with no frames is passed over, and so
    /// is anything that comes once the file is closed.
    ///
    /// - Throws: `SpeechRenderFailure.formatChanged` for a buffer of another
    ///   kind than the first, which `AVAudioFile` would write without
    ///   complaint, as if it were of the first's kind; or the file's error.
    func append(_ buffer: AVAudioPCMBuffer) throws {
        guard buffer.frameLength > 0 else { return }
        let file: AVAudioFile
        switch state {
        case .awaitingFirstBuffer:
            file = try AVAudioFile(
                forWriting: url,
                settings: Self.fileSettings(for: buffer.format),
                commonFormat: buffer.format.commonFormat,
                interleaved: buffer.format.isInterleaved
            )
            state = .open(file, format: buffer.format)
        case .open(let openFile, let format):
            guard Self.isSameKind(buffer.format, as: format) else {
                throw SpeechRenderFailure.formatChanged(title)
            }
            file = openFile
        case .closed:
            return
        }
        try file.write(from: buffer)
        speechFrameCount += Int64(buffer.frameLength)
        loudestSample = max(loudestSample, Self.loudestSample(of: buffer))
    }

    /// The loudest sample of `buffer`'s frames, in any of its channels, as a
    /// fraction of full scale: for 32-bit float samples their magnitude, and
    /// for 16-bit and 32-bit integers their magnitude over the largest. A
    /// kind of sample this doesn't read counts as full scale, so it is never
    /// taken for silence and refused.
    private static func loudestSample(of buffer: AVAudioPCMBuffer) -> Double {
        let format = buffer.format
        // Interleaved samples sit one after another behind one pointer.
        let pointers = format.isInterleaved ? 1 : Int(format.channelCount)
        let samples = Int(buffer.frameLength) * (format.isInterleaved ? Int(format.channelCount) : 1)
        /// The loudest of the samples behind `channels`, each read by `magnitude`.
        func loudest<Sample>(_ channels: UnsafePointer<UnsafeMutablePointer<Sample>>, _ magnitude: (Sample) -> Double) -> Double {
            var loudest = 0.0
            for pointer in 0..<pointers {
                let channel = channels[pointer]
                for index in 0..<samples {
                    loudest = max(loudest, magnitude(channel[index]))
                }
            }
            return loudest
        }
        if let channels = buffer.floatChannelData {
            return loudest(channels) { Double(abs($0)) }
        }
        if let channels = buffer.int16ChannelData {
            return loudest(channels) { Double(abs(Int32($0))) / Double(Int16.max) }
        }
        if let channels = buffer.int32ChannelData {
            return loudest(channels) { Double(abs(Int64($0))) / Double(Int32.max) }
        }
        return 1
    }

    /// Write `seconds` of silence after the speech, close the file, and say
    /// what it holds.
    ///
    /// - Throws: `SpeechRenderFailure.noSound` when no speech with sound in
    ///   it was written: none at all, or only silence, however many frames.
    ///   This is the only check of it (`SpeechChapterRenderer.render` relies
    ///   on it); or the file's error.
    func finish(trailingSilence seconds: TimeInterval) throws -> RenderedSpeechChapter {
        guard case .open(let file, _) = state, hasSound else {
            throw SpeechRenderFailure.noSound(title)
        }
        let format = file.processingFormat
        let silenceFrameCount = Self.frameCount(of: seconds, atRate: format.sampleRate)
        try Self.writeSilence(frameCount: silenceFrameCount, to: file)
        close()
        return RenderedSpeechChapter(
            frameCount: speechFrameCount + silenceFrameCount,
            sampleRate: format.sampleRate,
            channelCount: Int(format.channelCount)
        )
    }

    /// Close the file, if it is open, so the next owner of its path finds
    /// it whole; nothing more is written to it. Before macOS 15, which has
    /// no `close()`, an `AVAudioFile` closes when it is let go of, and this
    /// object holds the only lasting reference to it.
    func close() {
        if #available(macOS 15.0, *), case .open(let file, _) = state {
            file.close()
        }
        state = .closed
    }

    /// The file's settings for speech in `format`: linear PCM at its sample
    /// rate and channel count, as 16-bit little-endian interleaved
    /// integers.
    private static func fileSettings(for format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// Whether audio in `format` can follow audio in `first` in one file:
    /// the same sample rate, channel count, kind of sample, and
    /// interleaving.
    private static func isSameKind(_ format: AVAudioFormat, as first: AVAudioFormat) -> Bool {
        format.sampleRate == first.sampleRate
            && format.channelCount == first.channelCount
            && format.commonFormat == first.commonFormat
            && format.isInterleaved == first.isInterleaved
    }

    /// `seconds` at `rate` frames a second, rounded to whole frames: none
    /// for a length that is not positive or not a number, and at most
    /// `SpeechChapterRenderer.maximumTrailingSilence` seconds' worth.
    private static func frameCount(of seconds: TimeInterval, atRate rate: Double) -> Int64 {
        let frames = (min(seconds, SpeechChapterRenderer.maximumTrailingSilence) * rate).rounded()
        // False for a NaN as well; and a count too big for Int64 is none.
        guard frames > 0, let count = Int64(exactly: frames) else { return 0 }
        return count
    }

    /// Write `frameCount` frames of silence to `file`, in pieces of one
    /// buffer, zeroed here, since a new buffer's memory is not.
    private static func writeSilence(frameCount: Int64, to file: AVAudioFile) throws {
        guard frameCount > 0 else { return }
        let capacity = AVAudioFrameCount(min(frameCount, Int64(silencePieceFrameCount)))
        guard let piece = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: file.url])
        }
        // Setting the length sizes each channel's bytes to match, so every
        // byte of the piece is zeroed, whatever its kind of sample.
        piece.frameLength = capacity
        for channel in UnsafeMutableAudioBufferListPointer(piece.mutableAudioBufferList) {
            channel.mData?.initializeMemory(as: UInt8.self, repeating: 0, count: Int(channel.mDataByteSize))
        }
        var remaining = frameCount
        while remaining > 0 {
            piece.frameLength = AVAudioFrameCount(min(remaining, Int64(capacity)))
            try file.write(from: piece)
            remaining -= Int64(piece.frameLength)
        }
    }
}
