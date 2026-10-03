import AVFoundation
import Combine

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
    /// The exact text handed to the synthesizer.
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

/// Identifies one render of an `AudioEngineService` (TODO Q06). Each render
/// makes a fresh ticket and keeps it beside its synthesizer while it is the
/// engine's current render; its completion, which runs on the main queue,
/// carries the ticket there, since the synthesizer is not Sendable. Tickets
/// are compared by identity, and the completion's reference keeps its ticket
/// alive, so no later render can ever hold the same one.
private final class RenderTicket: Sendable {}

/// Rendered speech the render queue hands over to the main queue, which
/// installs it. `@unchecked Sendable` because `AVAudioPCMBuffer` is not
/// `Sendable`, yet only one thread ever touches the buffer at a time: the
/// render queue makes and fills it, then hands it over as its last act.
private struct HandedOverBuffer: @unchecked Sendable {
    /// The rendered speech, with its silence padding.
    let buffer: AVAudioPCMBuffer
}

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
/// synthesizer and buffers of its own and hands the result over
/// (`HandedOverBuffer`), and the player node's reports hop to the main
/// queue, reading only the test hook `_segmentPlayedBackForTesting` first.
final class AudioEngineService: ObservableObject, @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var timePitch = AVAudioUnitTimePitch()

    private var renderedBuffer: AVAudioPCMBuffer?
    private var renderFormat: AVAudioFormat?
    /// Everything the audio in `renderedBuffer` was rendered from, or nil
    /// while the engine holds no rendered audio. Set, cleared, and adopted
    /// together with the buffer, so the audio always carries its signature.
    private(set) var renderedSignature: SpeechRenderSignature?

    private var wordFrameMap: [(charOffset: Int, frame: AVAudioFramePosition)] = []
    private var totalFrames: AVAudioFrameCount = 0

    /// The frame in the full buffer where current playback segment starts
    private var segmentStartFrame: AVAudioFramePosition = 0
    /// The number of frames in the currently scheduled segment
    private var segmentFrameCount: AVAudioFrameCount = 0

    /// Where the last pause found playback, in frames of the full buffer, or
    /// nil when that is unknown or playback has not paused since it last
    /// started or resumed. Read by `pausedAtSegmentEnd`.
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

    /// Silence padding appended to rendered buffers (in seconds).
    /// The AVAudioUnitTimePitch node buffers audio internally — when the
    /// playerNode finishes and fires .dataPlayedBack, the timePitch may
    /// still have unplayed samples in its processing pipeline. Without
    /// padding, those final samples get discarded on chapter transitions,
    /// clipping the last word. 200ms provides enough runway at any rate.
    static let silencePaddingDuration: Double = 0.2

    /// The render in progress, or nil, read and written under `renderLock`.
    /// Its synthesizer is kept so we can cancel stale renders: without
    /// cancellation, old write() calls keep synthesizing in the background,
    /// competing with the direct-mode synthesizer for system TTS resources
    /// and causing delays. Its ticket identifies the render to its own
    /// completion (`claimRenderCompletion(for:)`).
    private var currentRender: (synth: AVSpeechSynthesizer, ticket: RenderTicket)?
    private let renderLock = NSLock()

    init() {
        setupEngine()
    }

    private func setupEngine() {
        engine.attach(playerNode)
        engine.attach(timePitch)
        let defaultFormat = AVAudioFormat(standardFormatWithSampleRate: 22050, channels: 1)!
        engine.connect(playerNode, to: timePitch, format: defaultFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: defaultFormat)
        timePitch.rate = 1.0
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

    /// Render `request` into this engine's buffer, replacing any audio it
    /// held, then report on the main queue whether the audio was installed.
    ///
    /// Everything rendering reads comes from `request`, and the installed
    /// audio carries `request.signature` as `renderedSignature`. Speech is
    /// always rendered at one fixed rate and pitch; the listener's speed and
    /// pitch are applied while it plays (see `setSpeed` and `setPitch`).
    func render(_ request: SpeechRenderRequest, completion: @escaping @Sendable (Bool) -> Void) {
        // Cancel any in-progress render first to free TTS resources
        cancelRender()

        let text = request.text
        isRendering = true
        wordFrameMap = []
        renderedBuffer = nil
        renderedSignature = nil
        // Render at 0.7 rate (~457 WPM empirically) for a good balance of speed and quality
        renderWPM = 457.0

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // Fresh instance per render (required for write() reliability)
            let renderSynth = AVSpeechSynthesizer()
            // Identifies this render to its completion on the main queue,
            // where the synthesizer, which is not Sendable, cannot go.
            let ticket = RenderTicket()

            // Store reference so it can be cancelled if a new render starts
            self.renderLock.lock()
            self.currentRender = (renderSynth, ticket)
            self.renderLock.unlock()

            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = request.voice
            utterance.rate = 0.7
            utterance.prefersAssistiveTechnologySettings = false

            var buffers: [AVAudioPCMBuffer] = []
            var format: AVAudioFormat?
            let semaphore = DispatchSemaphore(value: 0)

            renderSynth.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength > 0 {
                    buffers.append(pcm)
                    if format == nil { format = pcm.format }
                } else {
                    semaphore.signal()
                }
            }

            let result = semaphore.wait(timeout: .now() + 120)

            // Check if this render was cancelled while we were waiting
            self.renderLock.lock()
            let wasCancelled = self.currentRender?.ticket !== ticket
            self.renderLock.unlock()

            guard result == .success, !wasCancelled, !buffers.isEmpty, let audioFormat = format else {
                DispatchQueue.main.async {
                    if self.claimRenderCompletion(for: ticket) {
                        self.isRendering = false
                    }
                    completion(false)
                }
                return
            }

            // Concatenate buffers, then append silence padding so the
            // timePitch node can flush its internal processing buffer
            // before the .dataPlayedBack completion fires. Without this,
            // the last fraction-of-a-second of each chapter gets clipped
            // because the playerNode reports "done" while timePitch still
            // has unplayed samples queued.
            let speechFrameCount = buffers.reduce(0) { $0 + Int($1.frameLength) }
            let paddingFrames = Self.silencePaddingFrameCount(sampleRate: audioFormat.sampleRate)
            let totalFrameCount = speechFrameCount + paddingFrames
            guard let combinedBuffer = AVAudioPCMBuffer(
                pcmFormat: audioFormat,
                frameCapacity: AVAudioFrameCount(totalFrameCount)
            ) else {
                DispatchQueue.main.async {
                    if self.claimRenderCompletion(for: ticket) {
                        self.isRendering = false
                    }
                    completion(false)
                }
                return
            }

            var offset: AVAudioFrameCount = 0
            for buf in buffers {
                guard let dst = combinedBuffer.floatChannelData,
                      let src = buf.floatChannelData else { continue }
                for ch in 0..<Int(audioFormat.channelCount) {
                    dst[ch].advanced(by: Int(offset)).update(from: src[ch], count: Int(buf.frameLength))
                }
                offset += buf.frameLength
            }
            // Zero-fill the padding region (silence). The buffer was
            // allocated with frameCapacity covering both speech + padding,
            // and AVAudioPCMBuffer zero-initializes its storage, but we
            // explicitly zero here for clarity and safety.
            if let channelData = combinedBuffer.floatChannelData {
                for ch in 0..<Int(audioFormat.channelCount) {
                    let padStart = channelData[ch].advanced(by: Int(offset))
                    padStart.initialize(repeating: 0, count: paddingFrames)
                }
            }
            combinedBuffer.frameLength = AVAudioFrameCount(totalFrameCount)

            // Build char-to-frame mapping using only the speech frames
            // (not the silence padding). Characters map to real audio;
            // the padding exists solely to let timePitch flush.
            let charCount = text.utf16Length
            let framesPerChar = charCount > 0 ? Double(speechFrameCount) / Double(charCount) : 0
            var map: [(charOffset: Int, frame: AVAudioFramePosition)] = []
            let step = max(1, charCount / 200)
            for i in stride(from: 0, to: charCount, by: step) {
                map.append((charOffset: i, frame: AVAudioFramePosition(Double(i) * framesPerChar)))
            }
            map.append((charOffset: charCount, frame: AVAudioFramePosition(speechFrameCount)))
            let completedMap = map
            // This queue's last use of the buffer: from here on only the
            // main queue touches it.
            let handedOver = HandedOverBuffer(buffer: combinedBuffer)

            DispatchQueue.main.async {
                // Recheck ownership on the queue that installs the buffer.
                // A stop/new chapter can occur after the background render's
                // earlier cancellation check but before this closure executes.
                guard self.claimRenderCompletion(for: ticket) else {
                    completion(false)
                    return
                }
                self.renderedBuffer = handedOver.buffer
                self.renderedSignature = request.signature
                self.renderFormat = audioFormat
                self.wordFrameMap = completedMap
                // totalFrames tracks only the speech portion for position
                // calculations. The buffer is longer (includes silence
                // padding) but characters only map to speech frames.
                self.totalFrames = AVAudioFrameCount(speechFrameCount)
                self.isRendering = false
                completion(true)
            }
        }
    }

    // MARK: - Playback

    func play(fromCharOffset charOffset: Int = 0) {
        guard let buffer = renderedBuffer, let format = renderFormat else { return }

        playerNode.stop()
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(playerNode, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)

        if !engine.isRunning {
            do { try engine.start() } catch {
                print("AudioEngine failed to start: \(error)")
                return
            }
        }

        // Re-apply the tracked volume after engine start. The
        // stop→reconnect→start cycle during chapter transitions can
        // reset mainMixerNode.outputVolume to 1.0, discarding any
        // volume set by the sleep timer or other callers.
        engine.mainMixerNode.outputVolume = currentVolume

        scheduleAndPlay(buffer: buffer, format: format, fromCharOffset: charOffset)
    }

    private func scheduleAndPlay(buffer: AVAudioPCMBuffer, format: AVAudioFormat, fromCharOffset charOffset: Int) {
        // Increment generation so completion handlers from prior schedules are ignored.
        // This prevents seek() from falsely triggering "playback finished".
        playbackGeneration += 1
        let myGeneration = playbackGeneration
        // A new play has not paused yet, and holds no earlier play's end.
        pausedFrame = nil
        segmentEndHeldUntilResume = nil

        // reset() clears all scheduled events AND resets playerTime.sampleTime to 0
        playerNode.reset()

        let startFrame = frameForCharOffset(charOffset)
        segmentStartFrame = startFrame

        if startFrame > 0 && startFrame < AVAudioFramePosition(buffer.frameLength) {
            let remaining = AVAudioFrameCount(AVAudioFramePosition(buffer.frameLength) - startFrame)
            guard let subBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: remaining),
                  let src = buffer.floatChannelData,
                  let dst = subBuffer.floatChannelData else { return }
            for ch in 0..<Int(format.channelCount) {
                dst[ch].update(from: src[ch].advanced(by: Int(startFrame)), count: Int(remaining))
            }
            subBuffer.frameLength = remaining
            segmentFrameCount = remaining

            applyFadeIn(to: subBuffer, format: format)
            schedule(subBuffer, generation: myGeneration)
        } else {
            segmentStartFrame = 0
            segmentFrameCount = buffer.frameLength
            schedule(buffer, generation: myGeneration)
        }

        playerNode.play()
        isPlaying = true
        isPaused = false
    }

    /// Schedule `segment` on the player node as play `generation`. The
    /// node's report that it played back, which it gives on a thread of its
    /// own (and also when it is stopped), is carried to the main queue, where
    /// `handleSegmentEnd(generation:)` decides what it means.
    private func schedule(_ segment: AVAudioPCMBuffer, generation: Int) {
        playerNode.scheduleBuffer(segment, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self._segmentPlayedBackForTesting?(self)
            DispatchQueue.main.async { [weak self] in
                self?.handleSegmentEnd(generation: generation)
            }
        }
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
    private func applyFadeIn(to buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
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
        playerNode.pause()
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
        playerNode.stop()
        if engine.isRunning { engine.stop() }
        segmentStartFrame = frameForCharOffset(offset)
        isPlaying = false
        isPaused = false
        return offset
    }

    /// Resume a scheduled buffer, restarting the audio engine first when
    /// macOS has stopped it during sleep or an output-device interruption.
    /// Returns false only when there is no paused playback or the engine
    /// cannot be restarted, allowing the caller to retain a recoverable state.
    ///
    /// Playback whose segment played to its end as it paused has nothing
    /// left to play, so it finishes instead, once this call has returned
    /// (`releaseHeldSegmentEnd()`).
    @discardableResult
    func resume() -> Bool {
        guard isPaused else { return false }

        // A player node cannot resume while its containing engine is stopped.
        // This state can arise after the Mac sleeps for several hours even
        // though our scheduled buffer and logical pause state remain intact.
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                print("AudioEngine failed to restart while resuming: \(error)")
                return false
            }
        }

        // Engine restarts can reset mixer state, so preserve the user's
        // current volume just as the normal play path does.
        engine.mainMixerNode.outputVolume = currentVolume
        playerNode.play()
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
        playerNode.stop()
        if engine.isRunning { engine.stop() }
        isPlaying = false
        isPaused = false
    }

    /// Stops playback and releases all audio and position data retained from a
    /// completed render. Starting unrelated text must call this before direct
    /// speech so seek/resume cannot reuse the preceding chapter's buffer.
    @discardableResult
    func discardRenderedAudio() -> Bool {
        let discardedAudio = renderedBuffer != nil
        stop()
        renderedBuffer = nil
        renderedSignature = nil
        renderFormat = nil
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
        engine.mainMixerNode.outputVolume = currentVolume
    }

    func restoreVolume() {
        currentVolume = 1.0
        engine.mainMixerNode.outputVolume = 1.0
    }

    /// Intended and effective mixer volume. Internal visibility supports
    /// hosted verification of fade persistence without exposing engine nodes.
    var outputVolume: Float { engine.mainMixerNode.outputVolume }
    var intendedVolume: Float { currentVolume }

    /// The speed and pitch the time-pitch unit applies to rendered audio as it
    /// plays. Internal visibility lets hosted tests confirm that audio
    /// rendered ahead plays at the speed and pitch chosen when it starts.
    var playbackRate: Float { timePitch.rate }
    var playbackPitchCents: Float { timePitch.pitch }

    /// Seek within the current rendered buffer. No re-rendering, no engine restart.
    func seek(toCharOffset charOffset: Int) {
        guard let buffer = renderedBuffer, let format = renderFormat else { return }
        let wasPlaying = isPlaying && !isPaused

        playerNode.stop()

        if wasPlaying {
            scheduleAndPlay(buffer: buffer, format: format, fromCharOffset: charOffset)
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

    /// Where the player node stands in the full buffer, in frames, from how
    /// many frames it has actually played of the current segment; nil when
    /// the node has no valid time, as before it first renders.
    private func currentPlayerFrame() -> AVAudioFramePosition? {
        guard let nodeTime = playerNode.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return nil
        }

        // `playerTime.sampleTime` is already on the player node timeline.
        // The time-pitch unit changes audible speed, not the player's sample
        // progression through the scheduled buffer, so do not scale it again.
        return Self.currentFrame(
            segmentStartFrame: segmentStartFrame,
            playerSampleTime: playerTime.sampleTime
        )
    }

    /// Whether the last pause found everything audible in the current
    /// segment played: at or past its end, or inside the silence padding
    /// that ends every render (`silencePaddingDuration`). False when where
    /// it paused is unknown.
    private var pausedAtSegmentEnd: Bool {
        guard let pausedFrame, let format = renderFormat else { return false }
        let segmentEnd = segmentStartFrame + AVAudioFramePosition(segmentFrameCount)
        let padding = AVAudioFramePosition(Self.silencePaddingFrameCount(sampleRate: format.sampleRate))
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
        guard let format = renderFormat, totalFrames > 0 else { return 0 }
        return Double(totalFrames) / format.sampleRate
    }

    var hasRenderedAudio: Bool { renderedBuffer != nil }

    /// Current retained PCM size. Used by the opt-in production profiling
    /// harness to distinguish document-memory growth from rendered audio.
    var renderedAudioByteCount: Int {
        guard let buffer = renderedBuffer else { return 0 }
        return Int(buffer.frameLength) * Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
    }

    /// Size of the segment currently scheduled on the player node. After a
    /// nonzero seek this is a separate PCM allocation in addition to the full
    /// rendered buffer; the profiling harness reports both sizes explicitly.
    var scheduledSegmentAudioByteCount: Int {
        guard let format = renderFormat else { return 0 }
        return Int(segmentFrameCount) * Int(format.streamDescription.pointee.mBytesPerFrame)
    }

    /// Adopt pre-rendered audio from another AudioEngineService instance.
    /// Used for seamless chapter transitions where the next chapter was pre-rendered.
    /// The audio's signature comes with it, so this engine can still tell
    /// what its audio was rendered from.
    func adoptRenderedAudio(from other: AudioEngineService) {
        stop()
        renderedBuffer = other.renderedBuffer
        renderedSignature = other.renderedSignature
        renderFormat = other.renderFormat
        wordFrameMap = other.wordFrameMap
        totalFrames = other.totalFrames
        renderWPM = other.renderWPM
    }

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

    /// Installs a deterministic buffer of silence so tests can verify render
    /// ownership, disposal, and playback without invoking the system speech
    /// synthesizer. Its one character spans the whole buffer.
    ///
    /// - Parameters:
    ///   - signature: What the stand-in audio is said to have been rendered
    ///     from, as a finished render would record it.
    ///   - duration: How long the buffer plays, in seconds; it is always at
    ///     least one frame long.
    func _installRenderedAudioForTesting(signature: SpeechRenderSignature? = nil, lasting duration: TimeInterval = 0) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
        let frameCount = AVAudioFrameCount(max(1, Int(duration * format.sampleRate)))
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        // Silence, whatever the allocation held.
        buffer.floatChannelData?[0].update(repeating: 0, count: Int(frameCount))
        renderedBuffer = buffer
        renderedSignature = signature
        renderFormat = format
        wordFrameMap = [(charOffset: 0, frame: 0), (charOffset: 1, frame: AVAudioFramePosition(frameCount))]
        totalFrames = frameCount
    }

    /// Runs the same interpolation used by production seeking.
    func _frameForCharOffsetForTesting(_ offset: Int) -> AVAudioFramePosition {
        frameForCharOffset(offset)
    }

    /// Runs the same reverse interpolation used by position reporting.
    func _charOffsetForFrameForTesting(_ frame: AVAudioFramePosition) -> Int {
        charOffsetForFrame(frame)
    }

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
