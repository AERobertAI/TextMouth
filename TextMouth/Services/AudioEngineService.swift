import Accelerate
import AVFoundation
import Combine
import os

/// Identifies rendered speech audio by everything that went into it, so audio
/// rendered ahead of time is only ever played for exactly the speech it was
/// rendered from.
///
/// A render reads two things, the text and the voice (see
/// `SpeechRenderRequest`), and the signature covers both. The text is the end
/// of the reader's playback pipeline, so every setting that shapes it is
/// covered through the text itself: skipped sections, punctuation pauses,
/// substitution rules, and whether those rules are enabled. A setting that
/// changed the audio without changing the text would have to be added here.
///
/// Speed and pitch are deliberately not part of it. The engine renders every
/// text at one fixed rate and pitch, and its time-pitch unit applies the
/// listener's speed and pitch while the audio plays, so audio rendered while
/// one speed was chosen plays correctly at any other.
///
/// The text is identified by a hash of its exact characters together with its
/// length in UTF-16 code units. Swift seeds that hash anew in every process,
/// so a signature compares only with signatures made by the same run of the
/// app and is never stored.
struct SpeechRenderSignature: Hashable, Sendable {
    /// A hash of the text's exact characters.
    let textHash: Int
    /// The text's length in UTF-16 code units: the units of every offset into
    /// it, including the rendered audio's map from text to audio frames.
    let textUTF16Length: Int
    /// The voice's identifier, or nil for the system's default voice.
    let voiceIdentifier: String?

    /// The signature of rendering `text` with the voice `voiceIdentifier`
    /// names, or with the system's default voice when it is nil.
    init(text: String, voiceIdentifier: String?) {
        textHash = Self.exactHash(of: text)
        textUTF16Length = text.utf16Length
        self.voiceIdentifier = voiceIdentifier
    }

    /// A hash of `text`'s exact UTF-8 bytes.
    ///
    /// Hashing the `String` itself would not do: Swift hashes strings by
    /// canonical equivalence, so two encodings of the same accented letter
    /// would hash alike although the synthesizer is handed different
    /// characters, at different offsets.
    private static func exactHash(of text: String) -> Int {
        var hasher = Hasher()
        // `withUTF8` needs a mutable string because it may first copy a
        // bridged string into contiguous storage; the copy leaves `text` as is.
        var contiguousText = text
        contiguousText.withUTF8 { hasher.combine(bytes: UnsafeRawBufferPointer($0)) }
        return hasher.finalize()
    }
}

extension SpeechRenderSignature: CustomStringConvertible {
    /// A short form for the debug and transition logs: the text's length and
    /// hash, then the voice.
    var description: String {
        let hash = String(UInt(bitPattern: textHash), radix: 16)
        return "\(textUTF16Length) UTF-16 units #\(hash), voice \(voiceIdentifier ?? "default")"
    }
}

/// One render: the text to synthesize and the voice to synthesize it with.
///
/// `AudioEngineService.render(_:completion:)` reads nothing but this request,
/// and the request's signature covers every field, so the signature describes
/// the rendered audio exactly. A new input to rendering belongs here, and in
/// the signature.
struct SpeechRenderRequest: Sendable {
    /// The text to render. The engine hands the synthesizer its guarded
    /// form (`SpeechMarkupGuard`), of exactly this length, so the audio's
    /// offsets are this text's.
    let text: String
    /// The voice to render with; nil renders with the system's default voice.
    let voice: AVSpeechSynthesisVoice?
    /// Everything the rendered audio depends on.
    let signature: SpeechRenderSignature

    /// A request to render `text` with `voice`, signed once here so the text
    /// is hashed only once however often the signature is compared.
    init(text: String, voice: AVSpeechSynthesisVoice?) {
        self.text = text
        self.voice = voice
        signature = SpeechRenderSignature(text: text, voiceIdentifier: voice?.identifier)
    }
}

/// Hears, on whatever thread the synthesizer calls it, that a render's
/// synthesizer cancelled its utterance, and wakes the render queue, which
/// waits for the utterance's last piece of audio. An utterance the engine
/// refuses (see `SpeechMarkupGuard`) is cancelled before any piece, so
/// nothing else would wake the queue until its two-minute limit: measured
/// offline, a refused write made no buffer callback at all, and was
/// cancelled within 0.03 s.
///
/// It is Sendable, as every delegate of a synthesizer is (the SDK marks
/// `AVSpeechSynthesizerDelegate` `NS_SWIFT_SENDABLE`), and the compiler
/// checks that it is: a final class whose only state is a semaphore and a
/// flag kept in an `OSAllocatedUnfairLock`, both Sendable and never
/// replaced.
final class RenderCancellationObserver: NSObject, AVSpeechSynthesizerDelegate {
    /// The render queue's wait for the last piece.
    private let finished: DispatchSemaphore
    /// Whether the synthesizer cancelled the utterance.
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    /// An observer that signals `finished` once the synthesizer cancels.
    init(waking finished: DispatchSemaphore) {
        self.finished = finished
    }

    /// Whether the synthesizer cancelled the utterance.
    var wasCancelled: Bool { cancelled.withLock { $0 } }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        cancelled.withLock { $0 = true }
        finished.signal()
    }
}

/// Identifies one render of an `AudioEngineService` (TODO Q06). Each render
/// makes a fresh ticket and keeps it beside its synthesizer while it is the
/// engine's current render; its completion, which runs on the main queue,
/// carries the ticket there, since the synthesizer is not Sendable. Tickets
/// are compared by identity, and the completion's reference keeps its ticket
/// alive, so no later render can ever hold the same one.
private final class RenderTicket: Sendable {}

/// What the speech engine made of one report from its player node that a
/// segment of rendered audio it scheduled has played back.
enum SpeechSegmentEndOutcome: Equatable, Sendable {
    /// The segment under way played to its end, and playback finished.
    case finishedPlayback
    /// The segment under way played to its end just as the listener paused,
    /// and its report came after the pause. It is held until playback
    /// resumes, which finishes the play: the pause is never overridden by
    /// moving on, and resuming never leaves an empty player playing nothing.
    case heldUntilResume
    /// The report came while paused short of the segment's end, as the
    /// player node gives one when its output route disappears, although the
    /// segment never reached its end. It ends nothing, and the pause stands.
    case ignoredShortOfTheEnd
    /// The segment was scheduled before a seek, a stop, or a new play
    /// replaced it. The report was ignored.
    case scheduledDuringEarlierPlay
    /// Nothing was playing when the report was acted on. It was ignored.
    case nothingPlaying
}

/// Decides what a report from the speech engine's player node, that a
/// segment it scheduled has played back, means for the play under way.
///
/// The node reports on a thread of its own, and the report reaches the main
/// queue a moment later, by which time the listener may have paused, or a
/// seek, a stop, or a new play may have replaced the segment. A pause that
/// came as the segment ended must not swallow its end, or resuming plays an
/// empty node and the play never finishes. But the node also reports a
/// paused segment played back when its output route disappears, which is no
/// end at all. `AudioEndNoticePolicy` decides the same for audiobooks.
enum SpeechSegmentEndPolicy {
    /// What a report means for the play under way.
    ///
    /// - Parameters:
    ///   - scheduledGeneration: The play generation that scheduled the
    ///     segment.
    ///   - currentGeneration: The generation of the play under way.
    ///   - isPlaying: Whether the engine is playing, paused or not.
    ///   - isPaused: Whether that playback is paused.
    ///   - reachedSegmentEnd: Whether everything audible in the segment had
    ///     played when playback paused. Only paused playback asks.
    static func outcome(
        scheduledGeneration: Int,
        currentGeneration: Int,
        isPlaying: Bool,
        isPaused: Bool,
        reachedSegmentEnd: Bool
    ) -> SpeechSegmentEndOutcome {
        guard scheduledGeneration == currentGeneration else { return .scheduledDuringEarlierPlay }
        guard isPlaying else { return .nothingPlaying }
        guard isPaused else { return .finishedPlayback }
        return reachedSegmentEnd ? .heldUntilResume : .ignoredShortOfTheEnd
    }
}

// MARK: - Rendered Speech

/// Rendered speech as an `AudioEngineService` keeps it: the synthesizer's
/// audio, then the silence padding every render ends with
/// (`AudioEngineService.silencePaddingDuration`), as 16-bit samples in
/// blocks of `blockFrameCount` frames.
///
/// The synthesizer writes a render in pieces of about a hundredth of a
/// second, some 89,000 for a 40,000-unit chapter, as 32-bit floats. They
/// used to be kept until the render finished and then joined into one
/// float buffer, holding the speech twice over at that moment, and every
/// play that began part-way through copied the rest of the chapter once
/// more (TODO PERF04). Each piece is now converted into the blocks as it
/// arrives, at half the size, and a play converts back only the few seconds
/// it is about to schedule (`RenderedSpeechFeeder`).
///
/// Immutable once built, so the render queue can hand it to the main queue
/// and engines can share it, as the look-ahead's engine shares its render
/// with the speech service's.
final class RenderedSpeechAudio: Sendable {
    /// Frames in a full block: about three seconds at the synthesizer's
    /// 22,050 Hz. With the 32 bytes Swift keeps ahead of an array's
    /// elements, a one-channel block fills exactly 128 KB, a whole number of
    /// the 16 KB granules the allocator rounds blocks this large up to;
    /// 65,536 frames would waste most of a granule on every block.
    static let defaultBlockFrameCount = 65_520

    /// The format the audio plays in: the render's sample rate and channel
    /// count, as 32-bit floats with a buffer for each channel, the standard
    /// format of an audio engine's nodes.
    let format: AVAudioFormat
    /// Frames in each block but the last, which may hold fewer.
    let blockFrameCount: Int
    /// Frames of speech, before the padding.
    let speechFrameCount: Int
    /// Every frame: the speech, then the padding.
    let frameCount: Int
    /// Bytes the samples take: two a sample.
    let byteCount: Int
    /// The samples, `blockFrameCount` frames to a block, each frame's
    /// samples for its channels side by side.
    private let blocks: [[Int16]]

    /// The audio `Builder.finish(paddingFrameCount:)` built.
    fileprivate init(
        format: AVAudioFormat,
        blockFrameCount: Int,
        blocks: [[Int16]],
        speechFrameCount: Int,
        frameCount: Int
    ) {
        self.format = format
        self.blockFrameCount = blockFrameCount
        self.blocks = blocks
        self.speechFrameCount = speechFrameCount
        self.frameCount = frameCount
        byteCount = blocks.reduce(0) { $0 + $1.count * MemoryLayout<Int16>.stride }
    }

    /// The number of channels each frame holds.
    private var channelCount: Int { Int(format.channelCount) }

    /// Copy frames `frames` of the audio into `buffer` as the floats it
    /// plays, from the buffer's first frame on, and set its frame length to
    /// how many they are. The buffer must be in `format`, with room for them.
    func copyFrames(_ frames: Range<Int>, into buffer: AVAudioPCMBuffer) {
        precondition(frames.lowerBound >= 0 && frames.upperBound <= frameCount, "frames outside the audio")
        precondition(Int(buffer.frameCapacity) >= frames.count, "no room for the frames")
        guard let destination = buffer.floatChannelData else { return }
        var frame = frames.lowerBound
        var copied = 0
        while frame < frames.upperBound {
            let block = blocks[frame / blockFrameCount]
            let offset = frame % blockFrameCount
            // A run ends where the frames end or the block does.
            let run = min(frames.upperBound - frame, block.count / channelCount - offset)
            block.withUnsafeBufferPointer { samples in
                guard let first = samples.baseAddress else { return }
                for channel in 0..<channelCount {
                    SpeechSampleCodec.decode(
                        first + offset * channelCount + channel, stride: channelCount,
                        into: destination[channel] + copied,
                        count: run
                    )
                }
            }
            frame += run
            copied += run
        }
        buffer.frameLength = AVAudioFrameCount(copied)
    }
}

/// Converts between the 32-bit float samples an audio engine plays and the
/// 16-bit samples rendered speech is kept in, at half the size. Sixteen bits
/// keep speech at compact-disc quality: a step lies about 90 dB below full
/// scale.
enum SpeechSampleCodec {
    /// A full-scale float sample's value in 16 bits.
    static let fullScale: Float = 32_767

    /// Encode `count` float samples, every `sourceStride`th of `source`,
    /// into every `destinationStride`th of `destination`: each clipped to
    /// -1...1, scaled, and rounded to the nearest 16-bit step. `scratch`
    /// holds the clipped samples on the way, and grows as needed.
    static func encode(
        _ source: UnsafePointer<Float>,
        stride sourceStride: Int,
        into destination: UnsafeMutablePointer<Int16>,
        stride destinationStride: Int,
        count: Int,
        scratch: inout [Float]
    ) {
        guard count > 0 else { return }
        if scratch.count < count {
            scratch = [Float](repeating: 0, count: count)
        }
        var low: Float = -1
        var high: Float = 1
        var scale = fullScale
        scratch.withUnsafeMutableBufferPointer { clipped in
            guard let clippedSamples = clipped.baseAddress else { return }
            vDSP_vclip(source, sourceStride, &low, &high, clippedSamples, 1, vDSP_Length(count))
            vDSP_vsmul(clippedSamples, 1, &scale, clippedSamples, 1, vDSP_Length(count))
            vDSP_vfixr16(clippedSamples, 1, destination, destinationStride, vDSP_Length(count))
        }
    }

    /// Decode `count` 16-bit samples, every `sourceStride`th of `source`,
    /// into consecutive float samples at `destination`.
    static func decode(
        _ source: UnsafePointer<Int16>,
        stride sourceStride: Int,
        into destination: UnsafeMutablePointer<Float>,
        count: Int
    ) {
        guard count > 0 else { return }
        var scale = fullScale
        vDSP_vflt16(source, sourceStride, destination, 1, vDSP_Length(count))
        vDSP_vsdiv(destination, 1, &scale, destination, 1, vDSP_Length(count))
    }

    /// Copy `count` 16-bit samples, every `sourceStride`th of `source`, into
    /// every `destinationStride`th of `destination`, as they are.
    static func copy(
        _ source: UnsafePointer<Int16>,
        stride sourceStride: Int,
        into destination: UnsafeMutablePointer<Int16>,
        stride destinationStride: Int,
        count: Int
    ) {
        for index in 0..<count {
            destination[index * destinationStride] = source[index * sourceStride]
        }
    }
}

extension RenderedSpeechAudio {
    /// Builds rendered speech from the pieces the synthesizer writes,
    /// converting each into the blocks as it arrives, so no piece outlives
    /// the callback that delivers it.
    ///
    /// Used on one thread at a time: the synthesizer's callback appends the
    /// pieces, and the render queue finishes the audio once the synthesizer
    /// has signalled its last piece (`AudioEngineService.render`).
    final class Builder {
        /// The audio's format: as given, or the first piece's.
        private(set) var format: AVAudioFormat?
        /// Frames appended so far.
        private(set) var frameCount = 0
        /// Why a piece could not be kept, which fails the whole render, or
        /// nil while every piece has been kept.
        private(set) var failure: String?

        /// Frames in each full block.
        private let blockFrameCount: Int
        /// The blocks filled so far; the last may have room for more.
        private var blocks: [[Int16]] = []
        /// Frames in the last block.
        private var framesInLastBlock = 0
        /// Room for one channel of a piece on its way to 16 bits.
        private var scratch: [Float] = []

        /// - Parameters:
        ///   - format: The audio's format when it is known before any piece
        ///     arrives, as for silence; otherwise the first piece's is used.
        ///   - blockFrameCount: Frames in each full block.
        init(format: AVAudioFormat? = nil, blockFrameCount: Int = RenderedSpeechAudio.defaultBlockFrameCount) {
            precondition(blockFrameCount > 0, "a block holds at least one frame")
            self.format = format
            self.blockFrameCount = blockFrameCount
        }

        /// Convert `piece`'s frames to the end of the audio: 32-bit float
        /// samples, as the synthesizer writes them, become 16-bit ones, and
        /// 16-bit samples are kept as they are. A piece in another sample
        /// rate or channel count than the audio's, or of other samples,
        /// cannot be kept: it fails the render, and speech carries on
        /// without rendered audio.
        func append(_ piece: AVAudioPCMBuffer) {
            guard failure == nil, piece.frameLength > 0 else { return }
            let pieceFormat = piece.format
            if format == nil {
                format = AVAudioFormat(
                    standardFormatWithSampleRate: pieceFormat.sampleRate,
                    channels: pieceFormat.channelCount
                )
            }
            guard let format,
                  pieceFormat.sampleRate == format.sampleRate,
                  pieceFormat.channelCount == format.channelCount else {
                failure = "a piece in \(pieceFormat) among audio in \(format.map { "\($0)" } ?? "no standard format")"
                return
            }
            let channelCount = Int(format.channelCount)
            // Each channel's samples lie `sampleStride` apart: 1 in a buffer
            // of its own, the channel count when the piece interleaves them.
            let sampleStride = piece.stride
            if let source = piece.floatChannelData {
                appendFrames(Int(piece.frameLength)) { destination, run, done in
                    for channel in 0..<channelCount {
                        SpeechSampleCodec.encode(
                            source[channel] + done * sampleStride, stride: sampleStride,
                            into: destination + channel, stride: channelCount,
                            count: run,
                            scratch: &scratch
                        )
                    }
                }
            } else if let source = piece.int16ChannelData {
                appendFrames(Int(piece.frameLength)) { destination, run, done in
                    for channel in 0..<channelCount {
                        SpeechSampleCodec.copy(
                            source[channel] + done * sampleStride, stride: sampleStride,
                            into: destination + channel, stride: channelCount,
                            count: run
                        )
                    }
                }
            } else {
                failure = "a piece of samples neither 32-bit floats nor 16-bit integers: \(pieceFormat)"
            }
        }

        /// Append `count` frames of silence. New blocks start out silent,
        /// so nothing need be written.
        func appendSilence(frameCount count: Int) {
            appendFrames(count) { _, _, _ in }
        }

        /// The rendered speech: everything appended, then
        /// `paddingFrameCount` frames of silence. Nil when nothing was
        /// appended or a piece could not be kept. Finish a builder once.
        func finish(paddingFrameCount: Int) -> RenderedSpeechAudio? {
            guard failure == nil, let format, frameCount > 0 else { return nil }
            let speechFrameCount = frameCount
            appendSilence(frameCount: paddingFrameCount)
            // Give back the room the last block kept for frames that never
            // came.
            if let last = blocks.last, framesInLastBlock < blockFrameCount {
                blocks[blocks.count - 1] = Array(last.prefix(framesInLastBlock * Int(format.channelCount)))
            }
            return RenderedSpeechAudio(
                format: format,
                blockFrameCount: blockFrameCount,
                blocks: blocks,
                speechFrameCount: speechFrameCount,
                frameCount: frameCount
            )
        }

        /// Append `count` frames, starting a block whenever the last is
        /// full. `fill` writes each run of them into its block: it is given
        /// where the run's first frame goes (each frame's channels side by
        /// side), how many frames the run holds, and how many of the `count`
        /// came before it. Nothing is appended before the format is known.
        private func appendFrames(
            _ count: Int,
            fill: (_ destination: UnsafeMutablePointer<Int16>, _ run: Int, _ done: Int) -> Void
        ) {
            guard let format else { return }
            let channelCount = Int(format.channelCount)
            var done = 0
            while done < count {
                if blocks.isEmpty || framesInLastBlock == blockFrameCount {
                    blocks.append([Int16](repeating: 0, count: blockFrameCount * channelCount))
                    framesInLastBlock = 0
                }
                let run = min(count - done, blockFrameCount - framesInLastBlock)
                let start = framesInLastBlock * channelCount
                blocks[blocks.count - 1].withUnsafeMutableBufferPointer { samples in
                    if let first = samples.baseAddress {
                        fill(first + start, run, done)
                    }
                }
                framesInLastBlock += run
                done += run
            }
            frameCount += count
        }
    }
}

// MARK: - Feeding the Player Node

/// One slice of rendered speech an `AudioEngineService` scheduled on its
/// player node, as hosted tests are told of it
/// (`AudioEngineService._observeScheduledSlicesForTesting(_:)`).
struct ScheduledSpeechSlice: Equatable, Sendable {
    /// The frames of the render it holds.
    let frames: Range<Int>
    /// Its first channel's samples as scheduled: faded in when it begins a
    /// play part-way through the render.
    let samples: [Float]
    /// Bytes of audio scheduled on the node and not yet done with, this
    /// slice's included.
    let bytesScheduled: Int
}

/// A command to the player node other than starting it, which the feeder
/// carries out with the node's own call, or with a hosted test's stand-in
/// (`AudioEngineService._playerCommandForTesting(_:)`).
enum PlayerNodeCommand: String {
    /// `AVAudioPlayerNode.stop()`.
    case stop
    /// `AVAudioPlayerNode.reset()`.
    case reset
    /// `AVAudioPlayerNode.pause()`.
    case pause
}

/// Feeds one play of rendered speech to the speech engine's player node a
/// few slices at a time, so the audio waiting in the node stays a few
/// seconds long however long the chapter is (TODO PERF04).
///
/// A play schedules its first `slicesAhead` slices at once. Each time the
/// node reports a slice consumed, the next one is filled from the render
/// and scheduled, off the main thread, so a busy main thread can never
/// leave the node without audio. The last slice, which ends with the
/// render's silence padding, reports when it has played back: the end of
/// the play's segment, which the engine judges on the main queue.
///
/// The node's header asks that calls made on it from its completion
/// handlers be synchronised to the same queue as every other call on it,
/// and warns that stopping it from a handler can deadlock. So every call
/// here on the node runs on `queue`, which main-thread callers enter
/// synchronously and the node's handlers enter only asynchronously: a
/// handler never waits on the feeder, and a stop never waits on a handler
/// that waits on it.
///
/// `@unchecked Sendable`: its variables, and every call it makes on the
/// player node, are confined to `queue`, a serial queue that never waits
/// on the main thread or on the node's completion thread.
private final class RenderedSpeechFeeder: @unchecked Sendable {
    /// Told of each slice scheduled, by hosted tests only.
    typealias SliceObserver = @Sendable (ScheduledSpeechSlice) -> Void

    /// One play of a render: what to feed the node, and whom to tell when
    /// its last slice has played back.
    struct Play: Sendable {
        /// The render the play takes its frames from.
        let audio: RenderedSpeechAudio
        /// The frames it plays: from where it starts to the render's end.
        let frames: Range<Int>
        /// Whether its first slice fades in, as a play that begins part-way
        /// through does, to avoid a click.
        let fadesIn: Bool
        /// Called on the node's completion thread when the last slice has
        /// played back, or has been dropped by a stop after it was
        /// scheduled, as the node reports both.
        let onSegmentPlayedBack: @Sendable () -> Void
    }

    /// Where everything here happens, one thing at a time.
    private let queue = DispatchQueue(label: "com.textmouth.speech-feeder", qos: .userInteractive)
    private let node: AVAudioPlayerNode
    /// Frames in each slice but a play's last.
    private let sliceFrameCount: Int
    /// How many slices of a play stand scheduled at a time.
    private let slicesAhead: Int

    /// The play being fed, or nil when none is.
    private var play: Play?
    /// Counts the plays begun and ended. A slice's report carries its
    /// play's number and acts only while that play is being fed.
    private var playNumber = 0
    /// The first frame of the play not yet scheduled.
    private var nextFrame = 0
    /// Bytes of audio scheduled for the play and not yet done with.
    private var bytesScheduled = 0
    /// Told of each slice scheduled; set by hosted tests only.
    private var sliceObserver: SliceObserver?
    /// How the node is started. Always the node's own `play()` in the app;
    /// a hosted test swaps in one that raises, as AVFAudio does when the
    /// Mac's audio output has stopped cycling.
    private var startPlayer: (AVAudioPlayerNode) -> Void = { $0.play() }
    /// How the node's other commands are carried out: nil in the app, which
    /// calls the node's own `stop()`, `reset()`, and `pause()`; a hosted test
    /// swaps in one that raises, as AVFAudio may in the same glitch that
    /// stops the node starting.
    private var commandRunner: ((PlayerNodeCommand, AVAudioPlayerNode) -> Void)?

    init(node: AVAudioPlayerNode, sliceFrameCount: Int, slicesAhead: Int) {
        precondition(sliceFrameCount > 0 && slicesAhead > 0, "a play schedules at least one frame at a time")
        self.node = node
        self.sliceFrameCount = sliceFrameCount
        self.slicesAhead = slicesAhead
    }

    /// Feed `play` to the node from its first frame, and start the node.
    ///
    /// - Returns: False when not even the first slice could be made; then
    ///   nothing was scheduled, and the node was not started. Also false
    ///   when the node raised an exception as it started (`playNode()`);
    ///   then the play has ended and the node is stopped, so nothing stays
    ///   scheduled.
    func start(_ play: Play) -> Bool {
        let (slices, observer) = queue.sync { () -> ([ScheduledSpeechSlice], SliceObserver?) in
            playNumber += 1
            self.play = play
            nextFrame = play.frames.lowerBound
            bytesScheduled = 0
            var slices: [ScheduledSpeechSlice] = []
            while slices.count < slicesAhead, let slice = scheduleNextSlice(of: playNumber) {
                slices.append(slice)
            }
            guard !slices.isEmpty else {
                self.play = nil
                return ([], nil)
            }
            guard playNode() else {
                // The node cannot play: end the play, and clear the slices
                // it was given, so none stays scheduled over silence.
                endPlay()
                stopNodeCatchingExceptions()
                return ([], nil)
            }
            return (slices, sliceObserver)
        }
        slices.forEach { observer?($0) }
        return !slices.isEmpty
    }

    /// Stop the node, ending the play being fed first, so the reports the
    /// stop brings from slices still scheduled schedule nothing more, even
    /// when the node raises as it stops (`callNode(_:)`).
    func stopNode() {
        queue.sync {
            endPlay()
            stopNodeCatchingExceptions()
        }
    }

    /// Reset the node, clearing anything scheduled and setting its clock
    /// back to 0, ending the play being fed first, even when the node
    /// raises as it resets (`callNode(_:)`).
    func resetNode() {
        queue.sync {
            endPlay()
            _ = callNode(.reset)
        }
    }

    /// Pause the node where it stands. A node that raises as it pauses is
    /// logged (`callNode(_:)`) and changes nothing else.
    func pauseNode() {
        queue.sync { _ = callNode(.pause) }
    }

    /// Start the node again where it paused.
    ///
    /// - Returns: False when the node raised an exception as it started
    ///   (`playNode()`), and so is not playing.
    func resumeNode() -> Bool {
        queue.sync { playNode() }
    }

    /// Swap how the node is started, or restore the node's own `play()`
    /// with nil; for hosted tests only.
    func useNodeStarter(_ starter: ((AVAudioPlayerNode) -> Void)?) {
        queue.sync { startPlayer = starter ?? { $0.play() } }
    }

    /// Swap how the node's stop, reset, and pause are carried out, or
    /// restore the node's own calls with nil; for hosted tests only.
    func useNodeCommands(_ runner: ((PlayerNodeCommand, AVAudioPlayerNode) -> Void)?) {
        queue.sync { commandRunner = runner }
    }

    /// On `queue`: run `call`, a call to the player node. AVFAudio raises an
    /// Objective-C exception when the Mac's audio output has stopped cycling
    /// ("player did not see an IO cycle"), which Swift cannot catch and
    /// which would end the app; it is caught here and logged as one
    /// `SPEECH_PLAYER_EXCEPTION` line, whichever call raised.
    ///
    /// - Returns: Whether `call` returned normally.
    private func callNode(_ call: () -> Void) -> Bool {
        guard let exception = ObjCException.catching(call) else { return true }
        DiagnosticLog.event(
            .playback,
            ObjCException.logLine(tag: "SPEECH_PLAYER_EXCEPTION", for: exception),
            in: .speechTransitions
        )
        return false
    }

    /// On `queue`: carry out `command` on the node (`callNode(_:)`), by the
    /// test's stand-in when it set one.
    ///
    /// - Returns: Whether the node took it without raising.
    private func callNode(_ command: PlayerNodeCommand) -> Bool {
        let node = self.node
        let runner = commandRunner
        return callNode {
            if let runner {
                runner(command, node)
                return
            }
            switch command {
            case .stop: node.stop()
            case .reset: node.reset()
            case .pause: node.pause()
            }
        }
    }

    /// On `queue`: start the node (`callNode(_:)`).
    ///
    /// - Returns: Whether the node started.
    private func playNode() -> Bool {
        let node = self.node
        let starter = startPlayer
        return callNode { starter(node) }
    }

    /// On `queue`: stop the node, whether to clear a play that failed to
    /// start or to end one (`callNode(_:)`). A node that raises is already
    /// unusable, so nothing but the log hears of it.
    private func stopNodeCatchingExceptions() {
        _ = callNode(.stop)
    }

    /// How many frames the node has played since it last started from a
    /// stop, or nil while it has no valid time, as before it first renders.
    func playedFrameCount() -> AVAudioFramePosition? {
        queue.sync {
            guard let nodeTime = node.lastRenderTime,
                  nodeTime.isSampleTimeValid,
                  let playerTime = node.playerTime(forNodeTime: nodeTime) else {
                return nil
            }
            return playerTime.sampleTime
        }
    }

    /// Bytes of audio scheduled on the node for the play being fed and not
    /// yet done with.
    var scheduledByteCount: Int {
        queue.sync { bytesScheduled }
    }

    /// Tell `observer` of each slice scheduled from now on, or no one when
    /// it is nil. It is told on the main thread of a play's first slices
    /// and on `queue` of the rest, and must not call back into the feeder.
    func observeSlices(_ observer: SliceObserver?) {
        queue.sync { sliceObserver = observer }
    }

    /// On `queue`: end the play being fed. Nothing more of it is scheduled,
    /// and no report of a slice already scheduled acts on anything.
    private func endPlay() {
        playNumber += 1
        play = nil
        bytesScheduled = 0
    }

    /// On `queue`: fill the next slice of play `number` from its render and
    /// schedule it.
    ///
    /// - Returns: What a test observing slices is told of it, its samples
    ///   left out when none is, or nil when the play is not being fed, has
    ///   no frames left, or the slice could not be made.
    private func scheduleNextSlice(of number: Int) -> ScheduledSpeechSlice? {
        guard number == playNumber, let play, nextFrame < play.frames.upperBound else { return nil }
        let frames = nextFrame..<min(nextFrame + sliceFrameCount, play.frames.upperBound)
        let format = play.audio.format
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames.count)) else {
            return nil
        }
        play.audio.copyFrames(frames, into: buffer)
        if play.fadesIn, frames.lowerBound == play.frames.lowerBound {
            AudioEngineService.applyFadeIn(to: buffer)
        }
        // Copied for a test before the node can read the buffer.
        let samples = sliceObserver == nil
            ? []
            : buffer.floatChannelData.map { Array(UnsafeBufferPointer(start: $0[0], count: frames.count)) } ?? []
        nextFrame = frames.upperBound
        let bytes = frames.count * Int(format.channelCount) * MemoryLayout<Float>.stride
        bytesScheduled += bytes
        // The node reports on a thread of its own; each report hops onto
        // `queue` without waiting for it.
        if frames.upperBound == play.frames.upperBound {
            // The last slice: once it has played back, so has the segment.
            let onSegmentPlayedBack = play.onSegmentPlayedBack
            node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                onSegmentPlayedBack()
                guard let self else { return }
                self.queue.async { self.sliceDone(of: number, bytes: bytes) }
            }
        } else {
            node.scheduleBuffer(buffer, completionCallbackType: .dataConsumed) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.sliceDone(of: number, bytes: bytes) }
            }
        }
        return ScheduledSpeechSlice(frames: frames, samples: samples, bytesScheduled: bytesScheduled)
    }

    /// On `queue`: the node is done with a slice of play `number`. It
    /// consumed it, played it back, or dropped it in a stop. While that play
    /// is being fed, its bytes leave the count and the next slice takes its
    /// place.
    private func sliceDone(of number: Int, bytes: Int) {
        guard number == playNumber else { return }
        bytesScheduled -= bytes
        if let slice = scheduleNextSlice(of: number) {
            sliceObserver?(slice)
        }
    }
}

/// Pre-renders speech to audio buffers using AVSpeechSynthesizer.write(),
/// then plays through AVAudioEngine with AVAudioUnitTimePitch for
/// real-time speed adjustment and instant seeking.
///
/// Position tracking uses the AVAudioEngine's node time (not wall clock)
/// for accurate position reporting.
///
/// `@unchecked Sendable`: everything it holds is read and changed on the
/// main thread, where its owners, the speech service and the reader's
/// look-ahead, call it, except `currentRender`, which the render queue
/// shares under `renderLock`. The render queue otherwise works on a
/// synthesizer and a builder of its own and hands over the finished,
/// immutable `RenderedSpeechAudio`. The feeder, which the player node's
/// completion thread also reaches, keeps its state on its own queue, and
/// the node's report that a segment played back hops to the main queue,
/// reading only the test hook `_segmentPlayedBackForTesting` first.
final class AudioEngineService: ObservableObject, @unchecked Sendable {
    /// The audio engine, built with its node graph at the first thing that
    /// needs one (`engine`), or nil until then. A look-ahead only renders
    /// and lends its audio to the speech service's engine, so it never
    /// builds one (audit C8).
    private var builtEngine: AVAudioEngine?
    /// How many engine graphs this service has built: 0 or 1. Lets a test
    /// show that a service which only rendered, or lent its audio, built none.
    private(set) var _engineBuildCountForTesting = 0
    private let playerNode: AVAudioPlayerNode
    private var timePitch = AVAudioUnitTimePitch()
    /// Feeds each play to `playerNode` a few slices at a time.
    private let feeder: RenderedSpeechFeeder

    /// The rendered speech the engine holds, or nil.
    private var renderedAudio: RenderedSpeechAudio?
    /// Everything `renderedAudio` was rendered from, or nil while the engine
    /// holds no rendered audio. Set, cleared, and adopted together with the
    /// audio, so the audio always carries its signature.
    private(set) var renderedSignature: SpeechRenderSignature?

    private var wordFrameMap: [(charOffset: Int, frame: AVAudioFramePosition)] = []
    private var totalFrames: AVAudioFrameCount = 0

    /// The frame of the rendered audio where the current play's segment
    /// starts.
    private var segmentStartFrame: AVAudioFramePosition = 0
    /// The number of frames in the current play's segment: from its start
    /// to the end of the rendered audio, padding included.
    private var segmentFrameCount: AVAudioFrameCount = 0

    /// Where the last pause found playback, in frames of the rendered
    /// audio, or nil when that is unknown or playback has not paused since
    /// it last started or resumed. Read by `pausedAtSegmentEnd`.
    private var pausedFrame: AVAudioFramePosition?

    /// The play generation whose segment played to its end as the listener
    /// paused, held until `resume()` finishes it; nil when none is held.
    private var segmentEndHeldUntilResume: Int?

    /// Increments each time we schedule new playback. Completion handlers from
    /// prior schedules check this to avoid falsely signaling "playback finished"
    /// when we stop+reschedule during a seek.
    private var playbackGeneration: Int = 0

    @Published var isPlaying = false
    @Published var isPaused = false
    @Published var isRendering = false

    /// Tracks the intended output volume independently of the engine's
    /// mixer node. When the engine is stopped and restarted during
    /// chapter transitions, mainMixerNode.outputVolume can reset to 1.0.
    /// This property is re-applied after every engine.start() so the
    /// volume remains consistent across chapters.
    private var currentVolume: Float = 1.0

    var onPlaybackFinished: (() -> Void)?
    var renderWPM: Double = 350.0

    #if os(iOS)
    /// Called on the main queue when the engine stopped itself over a change of
    /// hardware format, with a play under way, paused or not
    /// (`AVAudioEngineConfigurationChangeNotification`): the speech service
    /// plays on from its place, a natural break.
    var onConfigurationChange: (() -> Void)?
    /// The observation of this engine's configuration changes, removed as the
    /// service goes.
    private var configurationObservation: EngineNotificationObservation?
    #endif

    /// Silence padding appended to rendered buffers (in seconds).
    /// The AVAudioUnitTimePitch node buffers audio internally — when the
    /// playerNode finishes and fires .dataPlayedBack, the timePitch may
    /// still have unplayed samples in its processing pipeline. Without
    /// padding, those final samples get discarded on chapter transitions,
    /// clipping the last word. 200ms provides enough runway at any rate.
    static let silencePaddingDuration: Double = 0.2

    /// Frames in each slice of a play the engine schedules on its player
    /// node: about a second and a half at the synthesizer's 22,050 Hz.
    static let defaultSliceFrameCount = 32_768

    /// How many slices of a play stand scheduled at a time: about nine
    /// seconds at 22,050 Hz, over six at the fastest speech, so the player
    /// node's report that it needs another can come late with time to spare.
    static let defaultSlicesAhead = 6

    /// The render in progress, or nil, read and written under `renderLock`.
    /// Its synthesizer is kept so we can cancel stale renders: without
    /// cancellation, old write() calls keep synthesizing in the background,
    /// competing with the direct-mode synthesizer for system TTS resources
    /// and causing delays. Its ticket identifies the render to its own
    /// completion (`claimRenderCompletion(for:)`).
    private var currentRender: (synth: AVSpeechSynthesizer, ticket: RenderTicket)?
    private let renderLock = NSLock()

    /// Where a render's job runs, off the main thread: the global queue in
    /// the app; a test passes a queue of its own, held until it lets it go.
    private let renderQueue: DispatchQueue

    /// - Parameters:
    ///   - sliceFrameCount: Frames in each slice of a play scheduled on the
    ///     player node. Hosted tests make slices short, to watch a play cross
    ///     many of them.
    ///   - slicesAhead: How many slices of a play stand scheduled at a time.
    ///   - renderQueue: Where a render's job runs.
    init(
        sliceFrameCount: Int = AudioEngineService.defaultSliceFrameCount,
        slicesAhead: Int = AudioEngineService.defaultSlicesAhead,
        renderQueue: DispatchQueue = .global(qos: .userInitiated)
    ) {
        let node = AVAudioPlayerNode()
        playerNode = node
        feeder = RenderedSpeechFeeder(node: node, sliceFrameCount: sliceFrameCount, slicesAhead: slicesAhead)
        self.renderQueue = renderQueue
        timePitch.rate = 1.0
    }

    /// The audio engine, with the player node and time-pitch unit attached
    /// and connected, built on first use. Everything that only needs to know
    /// whether the engine runs reads `builtEngine` instead, so that stopping
    /// or asking never builds one.
    private var engine: AVAudioEngine {
        if let builtEngine { return builtEngine }
        let engine = AVAudioEngine()
        builtEngine = engine
        _engineBuildCountForTesting += 1
        setupEngine(engine)
        #if os(iOS)
        observeConfigurationChanges(of: engine)
        #endif
        // The tracked volume holds from the first play on, set before the
        // graph existed.
        engine.mainMixerNode.outputVolume = currentVolume
        return engine
    }

    /// Builds the engine graph now, if it is not built. The speech service
    /// calls this as it makes its own engine, while direct speech already
    /// speaks, so that the first seek, resume, or chapter handoff onto the
    /// engine does not wait for the build (PERF08: 142 ms, 2.5 s cold). A
    /// look-ahead never calls it.
    func prepareGraph() {
        _ = engine
    }

    /// Whether the engine is built and running; false, without building one,
    /// when it is not built.
    private var engineIsRunning: Bool { builtEngine?.isRunning ?? false }

    /// Stops the engine if it is built and running; nothing otherwise.
    private func stopEngineIfRunning() {
        if let builtEngine, builtEngine.isRunning { builtEngine.stop() }
    }

    /// Stops the player node and ends the play being fed. A service whose
    /// engine was never built has nothing playing and its node is attached
    /// to nothing, so it is left alone.
    private func stopPlayerNodeIfBuilt() {
        if builtEngine != nil { feeder.stopNode() }
    }

    private func setupEngine(_ engine: AVAudioEngine) {
        engine.attach(playerNode)
        engine.attach(timePitch)
        let defaultFormat = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
        #if os(iOS)
        // A play connects the nodes again in its own format, so a failure here
        // costs nothing but its log line.
        _ = connectNodes(format: defaultFormat, for: "the engine's setup")
        #else
        engine.connect(playerNode, to: timePitch, format: defaultFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: defaultFormat)
        #endif
    }

    // MARK: - Rendering (AVSpeechSynthesizer.write)

    /// Cancel any in-progress render. Stops the background synthesizer so it doesn't
    /// compete with direct-mode TTS for system resources.
    func cancelRender() {
        renderLock.lock()
        let synth = currentRender?.synth
        currentRender = nil
        renderLock.unlock()
        synth?.stopSpeaking(at: .immediate)
        isRendering = false
    }

    /// Claims the completion of the render `ticket` identifies if it still
    /// owns this engine. Cancellation or a newer render clears/replaces that
    /// ownership, preventing a late main-queue commit from restoring stale
    /// chapter audio.
    private func claimRenderCompletion(for ticket: RenderTicket) -> Bool {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard currentRender?.ticket === ticket else { return false }
        currentRender = nil
        return true
    }

    /// How strictly a render's text is guarded before the synthesizer has
    /// it (`SpeechMarkupGuard`). Either way the guarded text keeps the
    /// text's length, so the frame map, which counts the request's offsets,
    /// fits the audio.
    enum RenderGuard: Sendable {
        /// Tag-shaped runs made harmless (`SpeechMarkupGuard.neutralized`),
        /// as every render begins.
        case markup
        /// Every bracket made silent too
        /// (`SpeechMarkupGuard.neutralizedStrictly`), for the one retry of
        /// a render the speech engine refused.
        case everyBracket

        /// `text` guarded so.
        func apply(to text: String) -> String {
            switch self {
            case .markup:
                return SpeechMarkupGuard.neutralized(text)
            case .everyBracket:
                return SpeechMarkupGuard.neutralizedStrictly(text)
            }
        }
    }

    /// Render `request` into this engine, replacing any audio it held, then
    /// report on the main queue whether the audio was installed.
    ///
    /// Everything rendering reads comes from `request`, and the installed
    /// audio carries `request.signature` as `renderedSignature`. Speech is
    /// always rendered at one fixed rate and pitch; the listener's speed and
    /// pitch are applied while it plays (see `setSpeed` and `setPitch`).
    ///
    /// When the speech engine refuses the text as the markup guard leaves
    /// it (`RENDER_REFUSED`), the render is tried once more, on a fresh
    /// synthesizer, with every bracket silent (`RenderGuard.everyBracket`),
    /// as direct speech retries a refused passage, so that the chapter has
    /// rendered audio for speech to go on from after a refusal of its own.
    /// That audio leaves a lone "less than" unsaid, the price of the rest.
    /// Refused again, nothing is installed.
    func render(_ request: SpeechRenderRequest, completion: @escaping @Sendable (Bool) -> Void) {
        // Cancel any in-progress render first to free TTS resources
        cancelRender()

        let text = request.text
        // What the synthesizer is handed for the text at each guard, unless a
        // test hands it something else. Chosen here, on the main thread,
        // where the hook is set; applied on the render queue, off it.
        let spokenText = _spokenTextForTesting ?? { text, guarding in guarding.apply(to: text) }
        isRendering = true
        wordFrameMap = []
        renderedAudio = nil
        renderedSignature = nil
        // Render at 0.7 rate (~457 WPM empirically) for a good balance of speed and quality
        renderWPM = 457.0
        #if os(iOS)
        // Read here, on the main thread, for the render queue's pace line.
        let assumedRenderWPM = renderWPM
        #endif

        renderQueue.async { [weak self] in
            // An engine let go of before its render began renders nothing,
            // but still reports, so that whatever waits for the report, as
            // the render coordinator's queue does, is never left waiting:
            // the job once returned without a word, which would have held
            // every later render and voice warm-up forever.
            guard let self = self else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            // Identifies this render to its completion on the main queue,
            // where the synthesizer, which is not Sendable, cannot go.
            let ticket = RenderTicket()

            var written = self.write(spokenText(text, .markup), voice: request.voice, for: ticket, asRetry: false)
            // A cancel that was not this engine's own is the speech engine's
            // refusal of the text: once more with every bracket silent.
            if written.wasRefused {
                DiagnosticLog.event(
                    .playback,
                    "RENDER_REFUSED: the speech engine cancelled the render after \(written.builder.frameCount) frames "
                        + "of \(text.utf16Length) UTF-16 units; rendering it again strictly guarded",
                    in: .speechTransitions
                )
                written = self.write(spokenText(text, .everyBracket), voice: request.voice, for: ticket, asRetry: true)
                if written.wasRefused {
                    // Nothing is installed, and speech, which began
                    // directly, goes on directly, with the text guarded.
                    DiagnosticLog.event(
                        .playback,
                        "RENDER_REFUSED: the speech engine cancelled the strictly guarded render after "
                            + "\(written.builder.frameCount) frames of \(text.utf16Length) UTF-16 units; "
                            + "nothing installed, direct speech goes on",
                        in: .speechTransitions
                    )
                } else if written.isComplete {
                    DiagnosticLog.event(
                        .playback,
                        "RENDER_RETRY_RENDERED: the strictly guarded render delivered \(written.builder.frameCount) frames "
                            + "of \(text.utf16Length) UTF-16 units",
                        in: .speechTransitions
                    )
                }
            }

            // Reports on the main queue that the render installed nothing.
            let reportFailure = {
                DispatchQueue.main.async {
                    if self.claimRenderCompletion(for: ticket) {
                        self.isRendering = false
                    }
                    completion(false)
                }
            }
            // A render that timed out may still be writing pieces, so its
            // builder is left alone; one the synthesizer cancelled holds at
            // most part of the speech, which the frame map could not fit.
            guard written.isComplete else {
                reportFailure()
                return
            }
            let builder = written.builder
            // The synthesizer has signalled its last piece: the builder is
            // this queue's alone now. The speech is followed by silence
            // padding, so the time-pitch unit can flush its internal buffer
            // before the player node reports the audio played back; without
            // it the last fraction of a second of each chapter was clipped.
            if let failure = builder.failure {
                DiagnosticLog.trace(.playback, "speech render kept no audio: \(failure)")
            }
            guard let format = builder.format,
                  let audio = builder.finish(
                      paddingFrameCount: Self.silencePaddingFrameCount(sampleRate: format.sampleRate)
                  ) else {
                reportFailure()
                return
            }
            let completedMap = Self.frameMap(utf16Length: text.utf16Length, speechFrameCount: audio.speechFrameCount)
            #if os(iOS)
            // The rate table and the 457 words a minute assumed here were
            // measured on a Mac; what a phone's voices do is unknown. Counted
            // here, on the render queue, and logged as numbers alone.
            let renderedWords = PhoneAudioPace.wordCount(in: text)
            let pace = PhoneAudioPace.description(
                words: renderedWords,
                seconds: Double(audio.speechFrameCount) / format.sampleRate,
                expectedWordsPerMinute: assumedRenderWPM
            )
            DiagnosticLog.event(
                .playback,
                "RENDER_PACE: \(pace) sampleRate=\(Int(format.sampleRate)) channels=\(format.channelCount)",
                in: .speechTransitions
            )
            #endif

            DispatchQueue.main.async {
                // Recheck ownership on the queue that installs the audio.
                // A stop/new chapter can occur after the background render's
                // earlier cancellation check but before this closure executes.
                guard self.claimRenderCompletion(for: ticket) else {
                    completion(false)
                    return
                }
                self.install(audio, signature: request.signature, wordFrameMap: completedMap)
                self.isRendering = false
                completion(true)
            }
        }
    }

    /// What one write of a render's text came to.
    private struct RenderWrite {
        /// The audio the synthesizer delivered: all of the speech only when
        /// the write is complete (`isComplete`).
        let builder: RenderedSpeechAudio.Builder
        /// Whether the synthesizer delivered its last piece within the time
        /// limit.
        let deliveredItsLastPiece: Bool
        /// Whether the engine let go of the render meanwhile, by cancelling
        /// it or beginning another.
        let wasLetGo: Bool
        /// Whether the synthesizer cancelled the utterance.
        let synthesizerCancelled: Bool

        /// Whether the synthesizer cancelled the utterance on its own while
        /// the engine still held the render: the speech engine refused the
        /// text.
        var wasRefused: Bool { synthesizerCancelled && !wasLetGo }

        /// Whether the audio can be installed: the last piece delivered,
        /// nothing cancelled, the render still the engine's.
        var isComplete: Bool { deliveredItsLastPiece && !wasLetGo && !synthesizerCancelled }

        /// A retry not written because the engine had let go of its render
        /// already.
        static var notWritten: RenderWrite {
            RenderWrite(
                builder: RenderedSpeechAudio.Builder(),
                deliveredItsLastPiece: false,
                wasLetGo: true,
                synthesizerCancelled: false
            )
        }
    }

    /// On the render queue: write `spokenText` in `voice` with a fresh
    /// synthesizer, required for write()'s reliability, and wait for its
    /// last piece, its cancel, or two minutes. The synthesizer is held as
    /// the engine's current render under `ticket`, so that `cancelRender()`
    /// can stop it. A retry (`asRetry`) writes nothing once the engine has
    /// let go of the render (`RenderWrite.notWritten`), which it checks as
    /// it takes the render over, under the same lock.
    private func write(
        _ spokenText: String,
        voice: AVSpeechSynthesisVoice?,
        for ticket: RenderTicket,
        asRetry: Bool
    ) -> RenderWrite {
        let renderSynth = AVSpeechSynthesizer()
        renderLock.lock()
        let letGoAlready = asRetry && currentRender?.ticket !== ticket
        if !letGoAlready {
            currentRender = (renderSynth, ticket)
        }
        renderLock.unlock()
        guard !letGoAlready else { return .notWritten }

        let utterance = AVSpeechUtterance(string: spokenText)
        utterance.voice = voice
        utterance.rate = 0.7
        utterance.prefersAssistiveTechnologySettings = false

        // Each piece is copied into the audio's blocks as it arrives,
        // so no piece outlives the callback that delivers it.
        let builder = RenderedSpeechAudio.Builder()
        let semaphore = DispatchSemaphore(value: 0)
        // A cancel wakes the wait too: the synthesizer's delegate is
        // weak, so the observer is held here until the wait returns.
        let cancellation = RenderCancellationObserver(waking: semaphore)
        renderSynth.delegate = cancellation

        renderSynth.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            if pcm.frameLength > 0 {
                builder.append(pcm)
            } else {
                semaphore.signal()
            }
        }

        let result = semaphore.wait(timeout: .now() + 120)
        renderSynth.delegate = nil

        // Whether this render was let go of while the write was waited for.
        renderLock.lock()
        let wasLetGo = currentRender?.ticket !== ticket
        renderLock.unlock()
        return RenderWrite(
            builder: builder,
            deliveredItsLastPiece: result == .success,
            wasLetGo: wasLetGo,
            synthesizerCancelled: cancellation.wasCancelled
        )
    }

    /// The map from offsets into a text `charCount` UTF-16 units long to
    /// frames of the `speechFrameCount` frames of speech rendered from it:
    /// a point every two-hundredth of the text, with frames spread evenly
    /// over the characters, and the text's end at the speech's end. The
    /// silence padding after the speech maps to no character.
    private static func frameMap(
        utf16Length charCount: Int,
        speechFrameCount: Int
    ) -> [(charOffset: Int, frame: AVAudioFramePosition)] {
        let framesPerChar = charCount > 0 ? Double(speechFrameCount) / Double(charCount) : 0
        var map: [(charOffset: Int, frame: AVAudioFramePosition)] = []
        let step = max(1, charCount / 200)
        for i in stride(from: 0, to: charCount, by: step) {
            map.append((charOffset: i, frame: AVAudioFramePosition(Double(i) * framesPerChar)))
        }
        map.append((charOffset: charCount, frame: AVAudioFramePosition(speechFrameCount)))
        return map
    }

    /// Hold `audio`, rendered from what `signature` describes, in place of
    /// any audio held before, with `map` taking its text's offsets to its
    /// frames.
    private func install(
        _ audio: RenderedSpeechAudio,
        signature: SpeechRenderSignature?,
        wordFrameMap map: [(charOffset: Int, frame: AVAudioFramePosition)]
    ) {
        renderedAudio = audio
        renderedSignature = signature
        wordFrameMap = map
        // totalFrames tracks only the speech portion for position
        // calculations. The audio is longer (it includes the silence
        // padding), but characters map only to speech frames.
        totalFrames = AVAudioFrameCount(audio.speechFrameCount)
    }

    // MARK: - Playback

    func play(fromCharOffset charOffset: Int = 0) {
        guard let audio = renderedAudio else { return }

        // The first play builds the engine graph; the player node must be
        // attached to it before it is stopped and scheduled.
        _ = engine
        feeder.stopNode()
        #if os(iOS)
        guard connectNodes(format: audio.format, for: "a play") else {
            // Nothing plays, and the caller, which checks `isPlaying`, goes on
            // another way.
            isPlaying = false
            isPaused = false
            return
        }
        #else
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(playerNode, to: timePitch, format: audio.format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: audio.format)
        #endif

        guard startEngineIfStopped(for: "a play") else { return }

        // Re-apply the tracked volume after engine start. The
        // stop→reconnect→start cycle during chapter transitions can
        // reset mainMixerNode.outputVolume to 1.0, discarding any
        // volume set by the sleep timer or other callers.
        engine.mainMixerNode.outputVolume = currentVolume

        scheduleAndPlay(audio, fromCharOffset: charOffset)
    }

    /// Starts the audio engine unless it is running already, as a play and
    /// a resume need, and says whether it runs. It cannot start when macOS
    /// has no output it can use, as when an output device has gone away;
    /// the failure is logged with `purpose`, "a play" or "a resume"
    /// (`AUDIO_ENGINE_START_FAILED`), and the caller then plays nothing.
    private func startEngineIfStopped(for purpose: String) -> Bool {
        guard !engineIsRunning else { return true }
        do {
            if _refusesToStartForTesting {
                throw CocoaError(.featureUnsupported)
            }
            #if os(iOS)
            try startEngineCatchingExceptions()
            #else
            try engine.start()
            #endif
            return true
        } catch {
            // The system error's words, never book text.
            DiagnosticLog.event(
                .playback,
                "AUDIO_ENGINE_START_FAILED: could not start for \(purpose): \(error.localizedDescription)",
                in: .speechTransitions
            )
            return false
        }
    }

    /// Begin a new play of `audio` from the frame `charOffset` maps to. Its
    /// segment runs from there to the audio's end, padding included, and is
    /// fed to the player node a few slices at a time; a play that begins
    /// part-way through fades in. Nothing plays when not even the first
    /// slice can be made.
    private func scheduleAndPlay(_ audio: RenderedSpeechAudio, fromCharOffset charOffset: Int) {
        // Increment generation so completion handlers from prior schedules are ignored.
        // This prevents seek() from falsely triggering "playback finished".
        playbackGeneration += 1
        let myGeneration = playbackGeneration
        // A new play has not paused yet, and holds no earlier play's end.
        pausedFrame = nil
        segmentEndHeldUntilResume = nil

        // reset() clears all scheduled events AND resets playerTime.sampleTime to 0
        feeder.resetNode()

        // Text offsets map no further than the speech's end, so a play
        // always keeps the padding after it; the bounds only guard the map.
        let startFrame = min(max(0, Int(frameForCharOffset(charOffset))), audio.frameCount - 1)
        segmentStartFrame = AVAudioFramePosition(startFrame)
        segmentFrameCount = AVAudioFrameCount(audio.frameCount - startFrame)

        // The node reports the segment's last slice played back on a thread
        // of its own (and also when it is stopped); the report is carried to
        // the main queue, where `handleSegmentEnd(generation:)` decides what
        // it means.
        let started = feeder.start(RenderedSpeechFeeder.Play(
            audio: audio,
            frames: startFrame..<audio.frameCount,
            fadesIn: startFrame > 0,
            onSegmentPlayedBack: { [weak self] in
                guard let self else { return }
                self._segmentPlayedBackForTesting?(self)
                DispatchQueue.main.async { [weak self] in
                    self?.handleSegmentEnd(generation: myGeneration)
                }
            }
        ))
        guard started else {
            // Nothing plays: the listener is not shown playing over silence,
            // and the caller, which checks `isPlaying`, decides how to go on.
            isPlaying = false
            isPaused = false
            return
        }
        isPlaying = true
        isPaused = false
    }

    /// Act on a report, now on the main queue, that the segment scheduled
    /// as play `generation` has played back, as `SpeechSegmentEndPolicy`
    /// decides. A finished play is reported through `onPlaybackFinished`; a
    /// report that ends nothing is ignored with one trace line saying why.
    ///
    /// - Parameter knownToHaveReachedItsEnd: Whether the segment is already
    ///   known to have played to its end, as an end held through a pause
    ///   is. Otherwise where the last pause found playback decides.
    /// - Returns: What the report came to.
    @discardableResult
    private func handleSegmentEnd(
        generation: Int,
        knownToHaveReachedItsEnd: Bool = false
    ) -> SpeechSegmentEndOutcome {
        let outcome = SpeechSegmentEndPolicy.outcome(
            scheduledGeneration: generation,
            currentGeneration: playbackGeneration,
            isPlaying: isPlaying,
            isPaused: isPaused,
            reachedSegmentEnd: knownToHaveReachedItsEnd || pausedAtSegmentEnd
        )
        #if os(iOS)
        // An engine that stopped itself, over a change of hardware format or
        // an interruption, plays nothing more, and a report that reaches the
        // main queue now is no end of the chapter: the speech service plays on
        // from its place, or the next Play starts cold. Taken for the end, the
        // engine's silence would start the next chapter.
        if outcome == .finishedPlayback, !knownToHaveReachedItsEnd, !engineIsRunning {
            DiagnosticLog.trace(.playback, "speech audio end ignored: the engine stopped itself before the report arrived")
            _segmentEndHandledForTesting?(.ignoredShortOfTheEnd)
            return .ignoredShortOfTheEnd
        }
        #endif
        switch outcome {
        case .finishedPlayback:
            isPlaying = false
            isPaused = false
            onPlaybackFinished?()
        case .heldUntilResume:
            segmentEndHeldUntilResume = generation
            DiagnosticLog.trace(
                .playback,
                "speech audio end held: playback was paused at the segment's end; resuming finishes the play"
            )
        case .ignoredShortOfTheEnd:
            DiagnosticLog.trace(
                .playback,
                "speech audio end ignored: paused short of the segment's end, as when its output route disappears"
            )
        case .scheduledDuringEarlierPlay:
            DiagnosticLog.trace(
                .playback,
                "speech audio end ignored: scheduled during an earlier play "
                    + "(generation \(generation), now \(playbackGeneration))"
            )
        case .nothingPlaying:
            DiagnosticLog.trace(.playback, "speech audio end ignored: nothing was playing")
        }
        _segmentEndHandledForTesting?(outcome)
        return outcome
    }

    /// Apply a short linear fade-in (~10ms) to avoid clicks at playback start
    fileprivate static func applyFadeIn(to buffer: AVAudioPCMBuffer) {
        let format = buffer.format
        let fadeFrames = min(Int(format.sampleRate * 0.01), Int(buffer.frameLength))
        guard fadeFrames > 0, let channelData = buffer.floatChannelData else { return }
        for ch in 0..<Int(format.channelCount) {
            for i in 0..<fadeFrames {
                let gain = Float(i) / Float(fadeFrames)
                channelData[ch][i] *= gain
            }
        }
    }

    /// Pause playback, keeping where it stood: the node's report that its
    /// segment played back can reach the main queue after this pause, and
    /// only a pause that found the segment played to its end makes that
    /// report an end (`pausedAtSegmentEnd`).
    func pause() {
        guard isPlaying && !isPaused else { return }
        pausedFrame = currentPlayerFrame()
        feeder.pauseNode()
        isPaused = true
    }

    /// Stop engine output at the current playback position while keeping
    /// rendered audio available for a later resume. Used after a sleep
    /// timer fade has already brought the mixer to silence; stopping the
    /// engine before volume restoration prevents any buffered downstream
    /// samples from being heard at full volume.
    func stopAfterFadePreservingPosition() -> Int {
        let offset = currentCharOffset()
        playbackGeneration += 1
        stopPlayerNodeIfBuilt()
        stopEngineIfRunning()
        segmentStartFrame = frameForCharOffset(offset)
        isPlaying = false
        isPaused = false
        return offset
    }

    /// Resume the play under way, restarting the audio engine first when
    /// macOS has stopped it during sleep or an output-device interruption.
    /// Returns false only when there is no paused playback, the engine
    /// cannot be restarted, or the player node raises as it starts again
    /// (`SPEECH_PLAYER_EXCEPTION`), allowing the caller to retain a
    /// recoverable state.
    ///
    /// Playback whose segment played to its end as it paused has nothing
    /// left to play, so it finishes instead, once this call has returned
    /// (`releaseHeldSegmentEnd()`).
    @discardableResult
    func resume() -> Bool {
        guard isPaused else { return false }

        // A player node cannot resume while its containing engine is stopped.
        // This state can arise after the Mac sleeps for several hours even
        // though our scheduled slices and logical pause state remain intact.
        guard startEngineIfStopped(for: "a resume") else { return false }

        // Engine restarts can reset mixer state, so preserve the user's
        // current volume just as the normal play path does.
        engine.mainMixerNode.outputVolume = currentVolume
        // A node that raises as it starts leaves the play paused and the
        // caller to go on another way (`SpeechService.resume()`).
        guard feeder.resumeNode() else { return false }
        isPaused = false
        pausedFrame = nil
        releaseHeldSegmentEnd()
        return true
    }

    /// Finish, once `resume()` has returned, the play whose segment played
    /// to its end as the listener paused, so the caller sees playback resume
    /// before it ends, as `AudioPlaybackService.resume()` does. The node has
    /// nothing left to play, so no other report of the end will come. By
    /// then a stop, a seek, or a new play may have replaced the play, which
    /// then ends nothing, or the listener may have paused again, which holds
    /// the end once more.
    private func releaseHeldSegmentEnd() {
        guard let generation = segmentEndHeldUntilResume else { return }
        segmentEndHeldUntilResume = nil
        DispatchQueue.main.async { [weak self] in
            self?.handleSegmentEnd(generation: generation, knownToHaveReachedItsEnd: true)
        }
    }

    func stop() {
        playbackGeneration += 1  // Invalidate pending completion handlers
        stopPlayerNodeIfBuilt()
        stopEngineIfRunning()
        isPlaying = false
        isPaused = false
    }

    /// Stops playback and releases all audio and position data retained from a
    /// completed render. Starting unrelated text must call this before direct
    /// speech so seek/resume cannot reuse the preceding chapter's audio.
    @discardableResult
    func discardRenderedAudio() -> Bool {
        let discardedAudio = renderedAudio != nil
        stop()
        renderedAudio = nil
        renderedSignature = nil
        wordFrameMap = []
        totalFrames = 0
        segmentStartFrame = 0
        segmentFrameCount = 0
        return discardedAudio
    }

    func setSpeed(wpm: Double) {
        timePitch.rate = Float(Self.speedMultiplier(wpm: wpm, renderWPM: renderWPM))
    }

    /// Computes the rate applied to the time-pitch unit, including the limits
    /// supported by AVAudioUnitTimePitch. Shared with tests to prevent a copied
    /// formula from drifting away from playback behavior.
    static func speedMultiplier(wpm: Double, renderWPM: Double) -> Double {
        guard renderWPM > 0 else { return 1 }
        return max(0.25, min(wpm / renderWPM, 4.0))
    }

    /// Converts the fixed tail-padding duration into frames for a render's
    /// actual sample rate.
    static func silencePaddingFrameCount(sampleRate: Double) -> Int {
        max(0, Int(sampleRate * silencePaddingDuration))
    }

    /// Set pitch using a multiplier (0.5 = half pitch, 1.0 = normal, 2.0 = double pitch).
    /// Converts to cents for AVAudioUnitTimePitch: cents = 1200 * log2(multiplier)
    func setPitch(multiplier: Double) {
        timePitch.pitch = Float(Self.pitchCents(for: multiplier))
    }

    /// Convert a user-facing pitch multiplier into AVAudioUnitTimePitch cents.
    /// Values outside the supported half- to double-pitch range are clamped.
    nonisolated static func pitchCents(for multiplier: Double) -> Double {
        let clamped = max(0.5, min(multiplier, 2.0))
        return 1200.0 * log2(clamped)
    }

    func setVolume(_ volume: Float) {
        currentVolume = max(0.0, min(volume, 1.0))
        // An engine not yet built takes the volume when it is built.
        builtEngine?.mainMixerNode.outputVolume = currentVolume
    }

    func restoreVolume() {
        currentVolume = 1.0
        builtEngine?.mainMixerNode.outputVolume = 1.0
    }

    /// Intended and effective mixer volume. Internal visibility supports
    /// hosted verification of fade persistence without exposing engine nodes.
    var outputVolume: Float { builtEngine?.mainMixerNode.outputVolume ?? currentVolume }
    var intendedVolume: Float { currentVolume }

    /// The speed and pitch the time-pitch unit applies to rendered audio as it
    /// plays. Internal visibility lets hosted tests confirm that audio
    /// rendered ahead plays at the speed and pitch chosen when it starts.
    var playbackRate: Float { timePitch.rate }
    var playbackPitchCents: Float { timePitch.pitch }

    /// Seek within the current rendered audio. No re-rendering, no engine
    /// restart, and no copy beyond the few slices the new play schedules.
    func seek(toCharOffset charOffset: Int) {
        guard let audio = renderedAudio else { return }
        let wasPlaying = isPlaying && !isPaused

        stopPlayerNodeIfBuilt()

        if wasPlaying {
            scheduleAndPlay(audio, fromCharOffset: charOffset)
        } else {
            segmentStartFrame = frameForCharOffset(charOffset)
            isPlaying = false
            isPaused = false
        }
    }

    // MARK: - Position Tracking (using actual audio node time)

    /// Get current character offset using the player node's actual playback position.
    /// This is accurate regardless of speed changes or timing drift.
    func currentCharOffset() -> Int {
        guard totalFrames > 0, isPlaying || isPaused, let frame = currentPlayerFrame() else {
            return charOffsetForFrame(segmentStartFrame)
        }
        return charOffsetForFrame(frame)
    }

    /// Where the player node stands in the rendered audio, in frames, from
    /// how many frames it has actually played of the current segment; nil
    /// when the node has no valid time, as before it first renders.
    private func currentPlayerFrame() -> AVAudioFramePosition? {
        // The node's sample time is already on its own timeline, and runs on
        // unbroken across the segment's slices, which are scheduled back to
        // back. The time-pitch unit changes audible speed, not the player's
        // sample progression through what is scheduled, so do not scale it
        // again.
        guard let playedFrames = feeder.playedFrameCount() else { return nil }
        return Self.currentFrame(segmentStartFrame: segmentStartFrame, playerSampleTime: playedFrames)
    }

    /// Whether the last pause found everything audible in the current
    /// segment played: at or past its end, or inside the silence padding
    /// that ends every render (`silencePaddingDuration`). False when where
    /// it paused is unknown.
    private var pausedAtSegmentEnd: Bool {
        guard let pausedFrame, let audio = renderedAudio else { return false }
        let segmentEnd = segmentStartFrame + AVAudioFramePosition(segmentFrameCount)
        let padding = AVAudioFramePosition(audio.frameCount - audio.speechFrameCount)
        return pausedFrame >= segmentEnd - padding
    }

    /// Combine the segment start and player-node sample time on the player
    /// timeline. Exposed for tests so the offset math can be exercised through
    /// the production type instead of duplicating the calculation there.
    static func currentFrame(
        segmentStartFrame: AVAudioFramePosition,
        playerSampleTime: AVAudioFramePosition
    ) -> AVAudioFramePosition {
        segmentStartFrame + playerSampleTime
    }

    var renderedDuration: TimeInterval {
        guard let audio = renderedAudio, totalFrames > 0 else { return 0 }
        return Double(totalFrames) / audio.format.sampleRate
    }

    var hasRenderedAudio: Bool { renderedAudio != nil }

    /// Current retained PCM size. Used by the opt-in production profiling
    /// harness to distinguish document-memory growth from rendered audio.
    var renderedAudioByteCount: Int {
        renderedAudio?.byteCount ?? 0
    }

    /// Bytes of audio scheduled on the player node for the play under way
    /// and not yet consumed: the few slices filled from the rendered audio
    /// ahead of the playhead, a separate allocation from the rendered audio
    /// itself, whatever the chapter's length or where a seek landed (TODO
    /// PERF04). The profiling harness reports both sizes.
    var scheduledSegmentAudioByteCount: Int {
        feeder.scheduledByteCount
    }

    /// Adopt pre-rendered audio from another AudioEngineService instance.
    /// Used for seamless chapter transitions where the next chapter was pre-rendered.
    /// The audio's signature comes with it, so this engine can still tell
    /// what its audio was rendered from. The audio is shared, not copied.
    func adoptRenderedAudio(from other: AudioEngineService) {
        stop()
        renderedAudio = other.renderedAudio
        renderedSignature = other.renderedSignature
        wordFrameMap = other.wordFrameMap
        totalFrames = other.totalFrames
        renderWPM = other.renderWPM
    }

    #if os(iOS)
    // MARK: - The iPhone's Engine

    /// Connects the player to the time-pitch unit and that to the mixer, in
    /// `format`, catching the exception AVFAudio raises for a format the
    /// hardware can't take, which Swift cannot catch and which would end the
    /// app (the engineer's review, F6). A failure is logged as the start's
    /// failure is (`AUDIO_ENGINE_START_FAILED`), naming `purpose`.
    ///
    /// - Returns: Whether the nodes are connected.
    private func connectNodes(format: AVAudioFormat, for purpose: String) -> Bool {
        let engine = self.engine
        let playerNode = self.playerNode
        let timePitch = self.timePitch
        guard let exception = ObjCException.catching({
            engine.disconnectNodeOutput(playerNode)
            engine.disconnectNodeOutput(timePitch)
            engine.connect(playerNode, to: timePitch, format: format)
            engine.connect(timePitch, to: engine.mainMixerNode, format: format)
        }) else { return true }
        DiagnosticLog.event(
            .playback,
            "AUDIO_ENGINE_START_FAILED: could not connect for \(purpose): "
                + ObjCException.logLine(tag: "AUDIO_ENGINE_EXCEPTION", for: exception),
            in: .speechTransitions
        )
        return false
    }

    /// Starts the engine, turning the exception AVFAudio raises for a broken
    /// precondition (an output that went away, an interrupted session) into a
    /// thrown error, which `startEngineIfStopped(for:)` logs as it logs any
    /// failure to start (F6).
    private func startEngineCatchingExceptions() throws {
        let engine = self.engine
        var startError: Error?
        if let exception = ObjCException.catching({
            do {
                try engine.start()
            } catch {
                startError = error
            }
        }) {
            throw EngineException(line: ObjCException.logLine(tag: "AUDIO_ENGINE_EXCEPTION", for: exception))
        }
        if let startError { throw startError }
    }

    /// An exception AVFAudio raised, as an error whose description is its log
    /// line.
    private struct EngineException: LocalizedError {
        /// `ObjCException.logLine(tag:for:)`'s line for it.
        let line: String
        var errorDescription: String? { line }
    }

    /// Pauses the engine itself, and not only its player node, so that no
    /// audio runs while the iPhone's session is let go: deactivating with I/O
    /// running fails with `IsBusy` (`AVAudioSession.h:247-254`) and other apps'
    /// audio is never told to resume (the engineer's review, F8). The play and
    /// its place are kept; `resume()` starts the engine again
    /// (`startEngineIfStopped(for:)`), though the reader's next Play starts cold.
    func pauseEngine() {
        guard let engine = builtEngine, engine.isRunning else { return }
        if let exception = ObjCException.catching({ engine.pause() }) {
            DiagnosticLog.event(
                .playback,
                ObjCException.logLine(tag: "AUDIO_ENGINE_EXCEPTION", for: exception),
                in: .speechTransitions
            )
        }
    }

    /// Observes this engine's configuration changes. Each engine is its own
    /// notification's `object`, and there can be two at once, the speech
    /// service's and the look-ahead's (the engineer's review, F5).
    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        configurationObservation = EngineNotificationObservation(
            NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil,
                using: Self.configurationChangeHandler(for: self)
            )
        )
    }

    /// The block the notification center calls for a configuration change,
    /// made here, outside any instance method, as `NowPlayingService` makes its
    /// command handlers (`NowPlayingService.swift:798-805`).
    ///
    /// The header says the callback "happens on an internal dispatch queue",
    /// where the engine "must not be deallocated" (`AVAudioEngine.h:885-895`).
    /// So the block does nothing there but hand the change to the main queue,
    /// asynchronously, holding the service weakly and never reading it on that
    /// queue. Given the main queue as its queue instead, the notification
    /// center would make the engine's queue wait for the main thread, which
    /// stops and starts this very engine in answer: two waits on each other.
    private static func configurationChangeHandler(
        for service: AudioEngineService
    ) -> @Sendable (Notification) -> Void {
        let handOver: @Sendable () -> Void = { [weak service] in
            service?.engineConfigurationChanged()
        }
        return { _ in
            DispatchQueue.main.async(execute: handOver)
        }
    }

    /// On the main queue: the engine stopped itself over a change of hardware
    /// format. A play under way ends here: whatever the player node reports of
    /// it from now on is stale, so its silence is never taken for the chapter's
    /// end, and the speech service plays on from its place
    /// (`onConfigurationChange`).
    private func engineConfigurationChanged() {
        DiagnosticLog.event(
            .playback,
            "AUDIO_ENGINE_CONFIGURATION_CHANGED: running=\(engineIsRunning) playing=\(isPlaying) paused=\(isPaused)",
            in: .speechTransitions
        )
        guard isPlaying else { return }
        playbackGeneration += 1
        onConfigurationChange?()
    }
    #endif

    // MARK: - Mapping

    private func frameForCharOffset(_ charOffset: Int) -> AVAudioFramePosition {
        guard !wordFrameMap.isEmpty else { return 0 }
        var lo = 0, hi = wordFrameMap.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if wordFrameMap[mid].charOffset <= charOffset { lo = mid } else { hi = mid - 1 }
        }
        let entry = wordFrameMap[lo]
        if lo + 1 < wordFrameMap.count {
            let next = wordFrameMap[lo + 1]
            let charRange = next.charOffset - entry.charOffset
            if charRange > 0 {
                let fraction = Double(charOffset - entry.charOffset) / Double(charRange)
                return entry.frame + AVAudioFramePosition(fraction * Double(next.frame - entry.frame))
            }
        }
        return entry.frame
    }

    private func charOffsetForFrame(_ frame: AVAudioFramePosition) -> Int {
        guard !wordFrameMap.isEmpty else { return 0 }
        let clamped = max(0, min(frame, AVAudioFramePosition(totalFrames)))
        var lo = 0, hi = wordFrameMap.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if wordFrameMap[mid].frame <= clamped { lo = mid } else { hi = mid - 1 }
        }
        let entry = wordFrameMap[lo]
        if lo + 1 < wordFrameMap.count {
            let next = wordFrameMap[lo + 1]
            let frameRange = next.frame - entry.frame
            if frameRange > 0 {
                let fraction = Double(clamped - entry.frame) / Double(frameRange)
                return entry.charOffset + Int(fraction * Double(next.charOffset - entry.charOffset))
            }
        }
        return entry.charOffset
    }

    // MARK: - Test Support

    /// Installs deterministic frame anchors without invoking platform TTS.
    func _configureFrameMapForTesting(
        _ map: [(charOffset: Int, frame: AVAudioFramePosition)],
        totalFrames: AVAudioFrameCount
    ) {
        wordFrameMap = map
        self.totalFrames = totalFrames
    }

    /// Installs deterministic silence standing for rendered speech, so tests
    /// can verify render ownership, disposal, and playback without invoking
    /// the system speech synthesizer. Like a render, it is followed by the
    /// silence padding, and its one character spans the speech.
    ///
    /// - Parameters:
    ///   - signature: What the stand-in audio is said to have been rendered
    ///     from, as a finished render would record it.
    ///   - duration: How long the speech lasts, in seconds, before the
    ///     padding; it is always at least one frame long.
    func _installRenderedAudioForTesting(signature: SpeechRenderSignature? = nil, lasting duration: TimeInterval = 0) {
        let frameCount = max(1, Int(duration * Self.testSampleRate))
        _installRenderedAudioForTesting(samples: [Float](repeating: 0, count: frameCount), signature: signature)
    }

    /// Installs `samples`, one channel at 22,050 Hz, as rendered speech built
    /// the way a render builds it, in blocks of `blockFrameCount` frames and
    /// followed by the silence padding. Its one character spans the speech.
    /// No samples install nothing, as a render of nothing installs nothing.
    func _installRenderedAudioForTesting(
        samples: [Float],
        signature: SpeechRenderSignature? = nil,
        blockFrameCount: Int = RenderedSpeechAudio.defaultBlockFrameCount
    ) {
        guard !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: Self.testSampleRate, channels: 1),
              let piece = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = piece.floatChannelData?[0] else { return }
        samples.withUnsafeBufferPointer { source in
            if let first = source.baseAddress {
                channel.update(from: first, count: samples.count)
            }
        }
        piece.frameLength = AVAudioFrameCount(samples.count)
        let builder = RenderedSpeechAudio.Builder(blockFrameCount: blockFrameCount)
        builder.append(piece)
        guard let audio = builder.finish(
            paddingFrameCount: Self.silencePaddingFrameCount(sampleRate: Self.testSampleRate)
        ) else { return }
        install(
            audio,
            signature: signature,
            wordFrameMap: [(charOffset: 0, frame: 0), (charOffset: 1, frame: AVAudioFramePosition(audio.speechFrameCount))]
        )
    }

    /// The sample rate of the audio tests install, the synthesizer's own.
    private static let testSampleRate: Double = 22_050

    /// Tell `observer` of each slice of rendered speech scheduled on the
    /// player node from now on, or no one when it is nil. It is told on the
    /// main thread of a play's first slices and on the feeder's own queue of
    /// the rest, and must not call back into the engine.
    func _observeScheduledSlicesForTesting(_ observer: (@Sendable (ScheduledSpeechSlice) -> Void)?) {
        feeder.observeSlices(observer)
    }

    /// Starts the player node with `starter` in place of the node's own
    /// `play()`, so that a test can make the start raise an Objective-C
    /// exception as AVFAudio does when the audio output stops cycling; nil
    /// restores `play()`.
    func _playerStartForTesting(_ starter: ((AVAudioPlayerNode) -> Void)?) {
        feeder.useNodeStarter(starter)
    }

    /// Carries out the player node's stop, reset, and pause with `runner`
    /// in place of the node's own calls, so that a test can make them raise
    /// an Objective-C exception as AVFAudio may when the audio output stops
    /// cycling; nil restores the node's own calls. The runner is called on
    /// the feeder's own queue.
    func _playerCommandForTesting(_ runner: ((PlayerNodeCommand, AVAudioPlayerNode) -> Void)?) {
        feeder.useNodeCommands(runner)
    }

    /// Stops the audio engine and nothing else, as macOS does when the Mac
    /// sleeps or an output device is interrupted: the play stays, paused or
    /// not, as the engine's own state shows it. Lets a test see what a
    /// resume does when the engine must start again
    /// (`startEngineIfStopped(for:)`).
    func _stopEngineOnlyForTesting() {
        stopEngineIfRunning()
    }

    /// Runs the same interpolation used by production seeking.
    func _frameForCharOffsetForTesting(_ offset: Int) -> AVAudioFramePosition {
        frameForCharOffset(offset)
    }

    /// Runs the same reverse interpolation used by position reporting.
    func _charOffsetForFrameForTesting(_ frame: AVAudioFramePosition) -> Int {
        charOffsetForFrame(frame)
    }

    /// Makes the audio engine fail to start, as it does when macOS has no
    /// output it can use, so that a test can see what speech does when its
    /// rendered audio cannot play (`startEngineIfStopped(for:)`); false,
    /// as in the app, starts it. An engine already running is not stopped.
    var _refusesToStartForTesting = false

    /// What the synthesizer is handed for a render's text at each guard, in
    /// place of the guard (`RenderGuard.apply(to:)`), so a test can hand it
    /// a text the engine refuses, at the first write or at the strictly
    /// guarded retry, and see what the render does; nil, as in the app,
    /// guards the text.
    var _spokenTextForTesting: (@Sendable (String, RenderGuard) -> String)?

    /// Called with this engine, on the player node's own thread, each time
    /// the node reports a scheduled segment played back, just before the
    /// report is sent to the main queue, so a test can put work on the main
    /// queue ahead of it.
    var _segmentPlayedBackForTesting: (@Sendable (AudioEngineService) -> Void)?

    /// Called on the main queue with what each report of a segment played
    /// back came to (`SpeechSegmentEndPolicy`).
    var _segmentEndHandledForTesting: ((SpeechSegmentEndOutcome) -> Void)?

    /// Act on a report that the segment under way played back, as the
    /// player node's own report is acted on.
    ///
    /// - Returns: Whether the report finished playback.
    @discardableResult
    func _handlePlaybackCompleteForTesting() -> Bool {
        handleSegmentEnd(generation: playbackGeneration) == .finishedPlayback
    }

    deinit { stop() }
}

#if os(iOS)
/// Holds a block observer's token and removes the observer as it goes, so
/// that `AudioEngineService`'s observation ends with the service, its deinit
/// unchanged.
private final class EngineNotificationObservation {
    /// The token `addObserver(forName:object:queue:using:)` returned.
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        NotificationCenter.default.removeObserver(token)
    }
}
#endif
