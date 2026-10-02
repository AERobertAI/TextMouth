@preconcurrency import AVFoundation
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

/// Pre-renders speech to audio buffers using AVSpeechSynthesizer.write(),
/// then plays through AVAudioEngine with AVAudioUnitTimePitch for
/// real-time speed adjustment and instant seeking.
///
/// Position tracking uses the AVAudioEngine's node time (not wall clock)
/// for accurate position reporting.
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

    /// Reference to the in-progress render synthesizer so we can cancel stale renders.
    /// Without cancellation, old write() calls keep synthesizing in the background,
    /// competing with the direct-mode synthesizer for system TTS resources and causing delays.
    private var currentRenderSynth: AVSpeechSynthesizer?
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
        let synth = currentRenderSynth
        currentRenderSynth = nil
        renderLock.unlock()
        synth?.stopSpeaking(at: .immediate)
        isRendering = false
    }

    /// Claims the completion of the specified render if it still owns this
    /// engine. Cancellation or a newer render clears/replaces that ownership,
    /// preventing a late main-queue commit from restoring stale chapter audio.
    private func claimRenderCompletion(for synth: AVSpeechSynthesizer) -> Bool {
        renderLock.lock()
        defer { renderLock.unlock() }
        guard currentRenderSynth === synth else { return false }
        currentRenderSynth = nil
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

            // Store reference so it can be cancelled if a new render starts
            self.renderLock.lock()
            self.currentRenderSynth = renderSynth
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
            let wasCancelled = self.currentRenderSynth !== renderSynth
            self.renderLock.unlock()

            guard result == .success, !wasCancelled, !buffers.isEmpty, let audioFormat = format else {
                DispatchQueue.main.async {
                    if self.claimRenderCompletion(for: renderSynth) {
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
                    if self.claimRenderCompletion(for: renderSynth) {
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

            DispatchQueue.main.async {
                // Recheck ownership on the queue that installs the buffer.
                // A stop/new chapter can occur after the background render's
                // earlier cancellation check but before this closure executes.
                guard self.claimRenderCompletion(for: renderSynth) else {
                    completion(false)
                    return
                }
                self.renderedBuffer = combinedBuffer
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

            playerNode.scheduleBuffer(subBuffer, completionCallbackType: .dataPlayedBack) { _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.playbackGeneration == myGeneration else { return }
                    self.handlePlaybackComplete()
                }
            }
        } else {
            segmentStartFrame = 0
            segmentFrameCount = buffer.frameLength
            playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.playbackGeneration == myGeneration else { return }
                    self.handlePlaybackComplete()
                }
            }
        }

        playerNode.play()
        isPlaying = true
        isPaused = false
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

    func pause() {
        guard isPlaying && !isPaused else { return }
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
        return true
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
        guard totalFrames > 0, isPlaying || isPaused else {
            return charOffsetForFrame(segmentStartFrame)
        }

        // Get how many frames the player has actually played in the current segment
        guard let nodeTime = playerNode.lastRenderTime,
              nodeTime.isSampleTimeValid,
              let playerTime = playerNode.playerTime(forNodeTime: nodeTime) else {
            return charOffsetForFrame(segmentStartFrame)
        }

        // `playerTime.sampleTime` is already on the player node timeline.
        // The time-pitch unit changes audible speed, not the player's sample
        // progression through the scheduled buffer, so do not scale it again.
        let currentFrame = Self.currentFrame(
            segmentStartFrame: segmentStartFrame,
            playerSampleTime: playerTime.sampleTime
        )

        return charOffsetForFrame(currentFrame)
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

    /// Installs a minimal deterministic buffer so tests can verify render
    /// ownership and disposal without invoking the system speech synthesizer.
    ///
    /// - Parameter signature: What the stand-in audio is said to have been
    ///   rendered from, as a finished render would record it.
    func _installRenderedAudioForTesting(signature: SpeechRenderSignature? = nil) {
        let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
        buffer.frameLength = 1
        renderedBuffer = buffer
        renderedSignature = signature
        renderFormat = format
        wordFrameMap = [(charOffset: 0, frame: 0), (charOffset: 1, frame: 1)]
        totalFrames = 1
    }

    /// Runs the same interpolation used by production seeking.
    func _frameForCharOffsetForTesting(_ offset: Int) -> AVAudioFramePosition {
        frameForCharOffset(offset)
    }

    /// Runs the same reverse interpolation used by position reporting.
    func _charOffsetForFrameForTesting(_ frame: AVAudioFramePosition) -> Int {
        charOffsetForFrame(frame)
    }

    @discardableResult
    private func handlePlaybackComplete() -> Bool {
        // AVAudioPlayerNode can report a scheduled buffer as played back when an
        // output route disappears, even if the node was paused. Treating that as
        // natural completion advances to the next chapter and starts playback.
        guard isPlaying, !isPaused else { return false }
        isPlaying = false
        isPaused = false
        onPlaybackFinished?()
        return true
    }

    /// Test support for deterministic playback-completion policy coverage.
    @discardableResult
    func _handlePlaybackCompleteForTesting() -> Bool {
        handlePlaybackComplete()
    }

    deinit { stop() }
}
