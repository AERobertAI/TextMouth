import AVFoundation
import Combine

/// Pre-renders speech to audio buffers using AVSpeechSynthesizer.write(),
/// then plays through AVAudioEngine with AVAudioUnitTimePitch for
/// real-time speed adjustment and instant seeking.
///
/// Position tracking uses the AVAudioEngine's node time (not wall clock)
/// for accurate position reporting.
class AudioEngineService: ObservableObject {
    private var engine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()
    private var timePitch = AVAudioUnitTimePitch()

    private var renderedBuffer: AVAudioPCMBuffer?
    private var renderFormat: AVAudioFormat?

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
    private static let silencePaddingDuration: Double = 0.2

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

    func render(text: String, voice: AVSpeechSynthesisVoice?, wpm: Double, completion: @escaping (Bool) -> Void) {
        // Cancel any in-progress render first to free TTS resources
        cancelRender()

        isRendering = true
        wordFrameMap = []
        renderedBuffer = nil
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
            utterance.voice = voice
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
                    self.isRendering = false
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
            let paddingFrames = Int(audioFormat.sampleRate * Self.silencePaddingDuration)
            let totalFrameCount = speechFrameCount + paddingFrames
            guard let combinedBuffer = AVAudioPCMBuffer(
                pcmFormat: audioFormat,
                frameCapacity: AVAudioFrameCount(totalFrameCount)
            ) else {
                DispatchQueue.main.async { self.isRendering = false; completion(false) }
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

            // Clear render synth reference now that we're done
            self.renderLock.lock()
            if self.currentRenderSynth === renderSynth {
                self.currentRenderSynth = nil
            }
            self.renderLock.unlock()

            DispatchQueue.main.async {
                self.renderedBuffer = combinedBuffer
                self.renderFormat = audioFormat
                self.wordFrameMap = map
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

    func resume() {
        guard isPaused else { return }
        playerNode.play()
        isPaused = false
    }

    func stop() {
        playbackGeneration += 1  // Invalidate pending completion handlers
        playerNode.stop()
        if engine.isRunning { engine.stop() }
        isPlaying = false
        isPaused = false
    }

    func setSpeed(wpm: Double) {
        timePitch.rate = Float(max(0.25, min(wpm / renderWPM, 4.0)))
    }

    /// Set pitch using a multiplier (0.5 = half pitch, 1.0 = normal, 2.0 = double pitch).
    /// Converts to cents for AVAudioUnitTimePitch: cents = 1200 * log2(multiplier)
    func setPitch(multiplier: Double) {
        let clamped = max(0.5, min(multiplier, 2.0))
        let cents = 1200.0 * log2(clamped)
        timePitch.pitch = Float(cents)
    }

    func setVolume(_ volume: Float) {
        currentVolume = max(0.0, min(volume, 1.0))
        engine.mainMixerNode.outputVolume = currentVolume
    }

    func restoreVolume() {
        currentVolume = 1.0
        engine.mainMixerNode.outputVolume = 1.0
    }

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

    /// Adopt pre-rendered audio from another AudioEngineService instance.
    /// Used for seamless chapter transitions where the next chapter was pre-rendered.
    func adoptRenderedAudio(from other: AudioEngineService) {
        stop()
        renderedBuffer = other.renderedBuffer
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

    private func handlePlaybackComplete() {
        guard isPlaying else { return }
        isPlaying = false
        isPaused = false
        onPlaybackFinished?()
    }

    deinit { stop() }
}
