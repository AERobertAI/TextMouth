import AVFoundation
import Combine

private final class RenderResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func store(_ value: Bool) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

/// Owns access to AVSpeechSynthesizer.write(), which is effectively a shared
/// macOS resource even when callers use different synthesizer instances.
/// Current-chapter and look-ahead renders must therefore never overlap.
final class SpeechRenderCoordinator: @unchecked Sendable {
    static let shared = SpeechRenderCoordinator()
    static let maximumTextLength = 100_000

    private let queue = DispatchQueue(
        label: "com.textmouth.speech-render",
        qos: .userInitiated
    )

    func render(
        text: String,
        engine: AudioEngineService,
        voice: AVSpeechSynthesisVoice?,
        wpm: Double,
        shouldStart: @escaping @MainActor @Sendable () -> Bool,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        enqueue(
            textLength: text.utf16Length,
            shouldStart: shouldStart,
            start: { finish in
                engine.render(text: text, voice: voice, wpm: wpm, completion: finish)
            },
            completion: completion
        )
    }

    /// The closure-based core keeps serialization and admission independently
    /// testable without invoking the system speech synthesizer.
    func enqueue(
        textLength: Int,
        shouldStart: @escaping @MainActor @Sendable () -> Bool,
        start: @escaping @MainActor @Sendable (@escaping @Sendable (Bool) -> Void) -> Void,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        guard textLength <= Self.maximumTextLength else {
            DispatchQueue.main.async { completion(false) }
            return
        }

        queue.async {
            let admitted = DispatchQueue.main.sync { shouldStart() }
            guard admitted else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            let finished = DispatchSemaphore(value: 0)
            let result = RenderResultBox()
            DispatchQueue.main.async {
                start { succeeded in
                    result.store(succeeded)
                    finished.signal()
                }
            }
            finished.wait()

            DispatchQueue.main.async {
                completion(shouldStart() && result.value)
            }
        }
    }
}

/// Manages TTS playback using two modes:
/// 1. **Audio Engine mode** (default): Pre-renders speech with AVSpeechSynthesizer.write(),
///    plays through AVAudioEngine + AVAudioUnitTimePitch for real-time speed changes and instant seeking.
/// 2. **Direct mode** (fallback): Uses AVSpeechSynthesizer.speak() directly with word-by-word callbacks.
final class SpeechService: NSObject, ObservableObject, @unchecked Sendable {
    let audioEngine = AudioEngineService()

    /// Fallback direct synthesizer
    private let directSynth = AVSpeechSynthesizer()
    private var usingDirectMode = false

    /// Tracks whether we were cancelled/paused/stopped during async rendering
    private var renderGeneration: Int = 0

    /// Identity of the AVSpeechUtterance currently considered "live" by us.
    /// Set when we hand an utterance to `directSynth` in `speakDirect(_:fromCharOffset:)`,
    /// cleared whenever we deliberately stop the synthesizer or the utterance
    /// finishes naturally. The `didFinish` delegate compares the incoming
    /// `utterance` parameter to this — a mismatch means the callback is for
    /// a previously-stopped utterance and must be ignored. This replaces an
    /// older counter-based scheme that would silently swallow legitimate
    /// finishes if the system ever delivered fewer didFinish events than we
    /// expected (e.g. dropped under load), or let stale finishes through if
    /// it delivered more.
    ///
    /// This reference is deliberately strong. Delegate callbacks are forwarded
    /// to the main queue, and AVFoundation may release its final reference to
    /// an utterance as soon as `didFinish` returns. A weak reference could
    /// therefore become nil before the queued identity check ran, causing a
    /// legitimate finish (and the next direct-speech chunk) to be discarded.
    private var liveDirectUtterance: AVSpeechUtterance?

    @Published var isSpeaking = false
    @Published var isPaused = false
    @Published var currentWordRange: NSRange?
    @Published var currentVoice: AVSpeechSynthesisVoice?
    @Published var wordsPerMinute: Double = 200 {
        didSet {
            UserDefaults.standard.set(wordsPerMinute, forKey: "wordsPerMinute")
            if !usingDirectMode && audioEngine.isPlaying {
                audioEngine.setSpeed(wpm: wordsPerMinute)
            }
        }
    }
    /// Pitch multiplier (0.5 = half pitch, 1.0 = normal, 2.0 = double pitch)
    @Published var pitchMultiplier: Double = 1.0 {
        didSet {
            UserDefaults.standard.set(pitchMultiplier, forKey: "pitchMultiplier")
            if !usingDirectMode && (audioEngine.isPlaying || audioEngine.isPaused) {
                audioEngine.setPitch(multiplier: pitchMultiplier)
            }
        }
    }

    var onWordSpoken: ((NSRange, String) -> Void)?
    var onUtteranceFinished: (() -> Void)?

    /// The full text currently being spoken
    private var currentText: String = ""
    /// In direct mode, the character offset into currentText where the trimmed utterance starts.
    /// Added to delegate-reported ranges so callers always get absolute positions.
    private var directModeBaseOffset: Int = 0
    /// Whether the current direct-mode utterance was truncated (chunked) for faster TTS startup
    private var directModeChunked: Bool = false
    /// The character offset where the current direct-mode chunk ends (for continuing to next chunk)
    private var directModeChunkEnd: Int = 0
    /// If the user seeks while paused before the audio engine is ready,
    /// keep the requested offset here and restart from it on resume
    /// instead of immediately speaking a new utterance.
    private var pendingDirectSeekOffset: Int?
    /// Max characters to pass to direct-mode TTS at once. Keeps startup latency low
    /// while providing enough audio buffer for the engine to render in the background.
    private static let directModeChunkSize = 5000
    /// Polls AVFoundation's own playback state after direct speech has started.
    /// Two consecutive idle observations leave time for a normal `didFinish`
    /// callback to reach the main queue before recovery is attempted.
    private static let directPlaybackWatchdogInterval: TimeInterval = 0.5
    private static let directPlaybackWatchdogRequiredIdleChecks = 2
    private var directPlaybackWatchdogTimer: Timer?
    private var directPlaybackWatchdogIdleChecks = 0
    /// Timer to poll playback position from audio engine
    private var positionTimer: Timer?

    /// Generation counter for in-flight position-tracking dispatches. The
    /// poll timer runs every 100 ms, captures the current offset on main,
    /// hops to a background queue to extract the current word, then hops
    /// back to main to publish via `currentWordRange` / `onWordSpoken`.
    /// A seek that happens between the offset capture and the final main-
    /// queue publish would otherwise cause the stale offset to overwrite
    /// the now-correct one. Each tick captures the generation at the
    /// start; the publish guard drops the result if the generation moved.
    /// Bumped by `startPositionTracking`, `stopPositionTracking`, and any
    /// path that seeks (`seek(toCharOffset:)`).
    private var positionGeneration: Int = 0

    private var settingsCancellables = Set<AnyCancellable>()

    /// Log transition events (mode switches, render status) to the
    /// transition log file. Dispatched to a background queue so
    /// FileHandle I/O doesn't block the main thread during playback.
    private func transitionLog(_ msg: String) {
        let logFile = TextMouthPaths.logsDir.appendingPathComponent("textmouth_transition.log")
        TextMouthPaths.appendLog(to: logFile, message: msg)
    }

    override init() {
        super.init()
        directSynth.delegate = self

        let savedWPM = UserDefaults.standard.double(forKey: "wordsPerMinute")
        if savedWPM > 0 {
            wordsPerMinute = savedWPM
        }

        let savedPitch = UserDefaults.standard.double(forKey: "pitchMultiplier")
        if savedPitch > 0 {
            pitchMultiplier = savedPitch
        }

        let savedVoiceID = UserDefaults.standard.string(forKey: "selectedVoiceID")
        if let voiceID = savedVoiceID {
            currentVoice = AVSpeechSynthesisVoice(identifier: voiceID)
        }
        if currentVoice == nil {
            currentVoice = AVSpeechSynthesisVoice(language: "en-US")
        }

        NotificationCenter.default.publisher(for: .speechSettingsChanged)
            .sink { [weak self] _ in self?.reloadSettings() }
            .store(in: &settingsCancellables)

        audioEngine.onPlaybackFinished = { [weak self] in
            self?.handleEngineFinished()
        }
    }

    func reloadSettings() {
        let savedWPM = UserDefaults.standard.double(forKey: "wordsPerMinute")
        if savedWPM > 0 && savedWPM != wordsPerMinute {
            wordsPerMinute = savedWPM
        }

        let savedPitch = UserDefaults.standard.double(forKey: "pitchMultiplier")
        if savedPitch > 0 && savedPitch != pitchMultiplier {
            pitchMultiplier = savedPitch
        }

        let savedVoiceID = UserDefaults.standard.string(forKey: "selectedVoiceID")
        if let voiceID = savedVoiceID, voiceID != currentVoice?.identifier {
            if let newVoice = AVSpeechSynthesisVoice(identifier: voiceID) {
                currentVoice = newVoice
            }
        }
    }

    // MARK: - Voice Management

    static func availableVoices(language: String? = nil) -> [AVSpeechSynthesisVoice] {
        var voices = AVSpeechSynthesisVoice.speechVoices()
        voices = voices.filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
        if let lang = language {
            voices = voices.filter { $0.language.hasPrefix(lang) }
        }
        return voices.sorted { $0.name < $1.name }
    }

    func selectVoice(_ voice: AVSpeechSynthesisVoice) {
        currentVoice = voice
        UserDefaults.standard.set(voice.identifier, forKey: "selectedVoiceID")
    }

    var minimumWPM: Double { 50 }
    var maximumWPM: Double { 650 }
    var minimumPitch: Double { 0.5 }
    var maximumPitch: Double { 2.0 }

    // MARK: - Playback

    /// Maximum text length for background engine rendering. Texts larger than
    /// this stay in direct mode for the entire playback. Attempting to render
    /// very large texts (e.g. 900K+ chars) via AVSpeechSynthesizer.write()
    /// competes with the direct-mode .speak() for macOS speech synthesis
    /// resources, causing chunks to loop or stutter at boundaries.
    /// Speak text. Starts playback immediately in direct mode for zero latency.
    /// Pre-renders in background so audio engine is ready for seeking, speed changes,
    /// or to play the next chapter without delay. Does NOT switch mid-playback to avoid
    /// audible glitches — the engine is used on the next natural break (seek, pause, chapter end).
    func speak(_ text: String, fromCharOffset charOffset: Int = 0) {
        stop()
        // `AudioEngineService.stop()` deliberately preserves a completed
        // buffer for ordinary pause/resume flows. This call begins unrelated
        // text, so keeping that buffer would let seek/resume play audio from
        // the previous chapter when the new text is too large to render.
        if audioEngine.discardRenderedAudio() {
            transitionLog("RENDER_DISCARD: removed previous text's rendered audio before starting new direct speech")
        }
        currentText = text

        // Increment generation so stale render completions are ignored
        renderGeneration += 1
        let myGeneration = renderGeneration

        isSpeaking = true
        isPaused = false

        // Start direct mode immediately for zero-latency playback
        speakDirect(text, fromCharOffset: charOffset)

        // Skip background render for very large texts. The concurrent
        // AVSpeechSynthesizer.write() competes with the direct-mode
        // .speak() for the macOS speech synthesis engine, causing chunk
        // transitions to loop or stutter. Direct mode chunking handles
        // arbitrarily long texts on its own.
        guard text.utf16Length <= SpeechRenderCoordinator.maximumTextLength else {
            transitionLog("RENDER_SKIP: text too large (\(text.utf16Length) UTF-16 units > \(SpeechRenderCoordinator.maximumTextLength)), staying in direct mode")
            return
        }

        // Pre-render in background so engine is ready for seeks, pauses, or next chapter.
        // We do NOT switch mid-playback — direct mode runs until a natural break.
        SpeechRenderCoordinator.shared.render(
            text: text,
            engine: audioEngine,
            voice: currentVoice,
            wpm: wordsPerMinute,
            shouldStart: { [weak self] in self?.renderGeneration == myGeneration },
            completion: { [weak self] success in
            guard let self = self else { return }
            guard self.renderGeneration == myGeneration else { return }

            if success {
                self.transitionLog("RENDER_READY: engine rendered \(text.utf16Length) UTF-16 units, direct mode still active=\(self.usingDirectMode)")
            } else {
                self.transitionLog("RENDER_FAILED: engine render failed, staying in direct mode")
            }
            // Engine is now ready. It will be used when:
            // - User seeks (seek() checks audioEngine.hasRenderedAudio)
            // - User pauses then resumes (resume() switches to engine)
            // - Chapter ends (next chapter can start directly in engine mode)
            }
        )
    }

    /// Speak text using the audio engine directly (no direct mode fallback).
    /// Used when the engine already has rendered audio ready (e.g. after a seek or for next chapter).
    func speakWithEngine(_ text: String, fromCharOffset charOffset: Int = 0) {
        stop()
        currentText = text

        renderGeneration += 1
        let myGeneration = renderGeneration

        isSpeaking = true
        isPaused = false

        if audioEngine.hasRenderedAudio {
            // Engine already has audio for this text — play immediately
            usingDirectMode = false
            audioEngine.setSpeed(wpm: wordsPerMinute)
            audioEngine.setPitch(multiplier: pitchMultiplier)
            audioEngine.play(fromCharOffset: charOffset)
            startPositionTracking()
        } else {
            // Need to render first — start direct mode while waiting
            speakDirect(text, fromCharOffset: charOffset)

            SpeechRenderCoordinator.shared.render(
                text: text,
                engine: audioEngine,
                voice: currentVoice,
                wpm: wordsPerMinute,
                shouldStart: { [weak self] in self?.renderGeneration == myGeneration },
                completion: { [weak self] success in
                guard let self = self else { return }
                guard self.renderGeneration == myGeneration else { return }
                if success {
                    self.transitionLog("RENDER_READY (speakWithEngine): rendered, direct still active=\(self.usingDirectMode)")
                }
                }
            )
        }
    }

    private func speakDirect(_ text: String, fromCharOffset charOffset: Int) {
        usingDirectMode = true
        let startOffset = max(0, min(charOffset, text.utf16Length))
        let startIdx = text.index(atUTF16Offset: startOffset)
        let normalizedStartOffset = text.utf16Offset(of: startIdx)
        let remainingCount = text.utf16Length - normalizedStartOffset

        let speakText: String
        if remainingCount > Self.directModeChunkSize {
            // Chunk: take only directModeChunkSize chars, snapped to a word boundary
            var endIdx = text.index(atUTF16Offset: normalizedStartOffset + Self.directModeChunkSize)
            // Advance to end of current word so we don't cut mid-word
            while endIdx < text.endIndex && !text[endIdx].isWhitespace {
                endIdx = text.index(after: endIdx)
            }
            speakText = String(text[startIdx..<endIdx])
            directModeBaseOffset = normalizedStartOffset
            directModeChunkEnd = text.utf16Offset(of: endIdx)
            directModeChunked = true
            transitionLog("CHUNK_START: offset=\(normalizedStartOffset) len=\(speakText.utf16Length) end=\(directModeChunkEnd) totalText=\(text.utf16Length)")
        } else if normalizedStartOffset > 0 {
            speakText = String(text[startIdx...])
            directModeBaseOffset = normalizedStartOffset
            directModeChunkEnd = text.utf16Length
            directModeChunked = false
        } else {
            speakText = text
            directModeBaseOffset = 0
            directModeChunkEnd = text.utf16Length
            directModeChunked = false
        }

        let utterance = AVSpeechUtterance(string: speakText)
        utterance.voice = currentVoice
        utterance.rate = Self.rateForWPM(wordsPerMinute)
        utterance.pitchMultiplier = Float(Self.clampedPitch(pitchMultiplier))
        utterance.prefersAssistiveTechnologySettings = false
        // Mark this utterance as live BEFORE handing it to the synth.
        // The didFinish delegate compares against `liveDirectUtterance`
        // to filter callbacks for previously-stopped utterances.
        liveDirectUtterance = utterance
        directSynth.speak(utterance)
    }

    /// Monitor a direct utterance after AVFoundation confirms that it started.
    /// This does not estimate speech duration. It recovers only when both the
    /// app and AVFoundation agree playback should be active, but the system
    /// synthesizer remains idle for two consecutive checks.
    private func startDirectPlaybackWatchdog(for utterance: AVSpeechUtterance) {
        stopDirectPlaybackWatchdog()
        let watchedUtteranceID = ObjectIdentifier(utterance)
        let timer = Timer(timeInterval: Self.directPlaybackWatchdogInterval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }

            guard self.liveDirectUtterance.map(ObjectIdentifier.init) == watchedUtteranceID else {
                // A newer utterance owns playback now. Its didStart callback
                // installs a replacement watchdog, so this timer is obsolete.
                timer.invalidate()
                return
            }

            let shouldRecover = Self.shouldRecoverIdleDirectSpeech(
                appIsSpeaking: self.isSpeaking,
                appIsPaused: self.isPaused,
                usingDirectMode: self.usingDirectMode,
                synthesizerIsSpeaking: self.directSynth.isSpeaking,
                synthesizerIsPaused: self.directSynth.isPaused,
                hasLiveUtterance: self.liveDirectUtterance != nil
            )
            guard shouldRecover else {
                self.directPlaybackWatchdogIdleChecks = 0
                return
            }

            self.directPlaybackWatchdogIdleChecks += 1
            guard self.directPlaybackWatchdogIdleChecks >= Self.directPlaybackWatchdogRequiredIdleChecks else {
                return
            }

            timer.invalidate()
            if self.directPlaybackWatchdogTimer === timer {
                self.directPlaybackWatchdogTimer = nil
            }
            self.directPlaybackWatchdogIdleChecks = 0
            self.recoverFromIdleDirectSynthesizer(watchedUtteranceID: watchedUtteranceID)
        }
        RunLoop.main.add(timer, forMode: .common)
        directPlaybackWatchdogTimer = timer
    }

    /// Cancel the direct-speech watchdog whenever playback deliberately stops,
    /// switches backend, or completes normally.
    private func stopDirectPlaybackWatchdog() {
        directPlaybackWatchdogTimer?.invalidate()
        directPlaybackWatchdogTimer = nil
        directPlaybackWatchdogIdleChecks = 0
    }

    /// Recover an utterance for which AVFoundation became idle without sending
    /// a usable finish callback. Prefer rendered audio when available. Without
    /// rendered audio, continue a nearly-complete chunk at its known boundary;
    /// otherwise restart at the last reported word so content is not skipped.
    private func recoverFromIdleDirectSynthesizer(watchedUtteranceID: ObjectIdentifier) {
        guard liveDirectUtterance.map(ObjectIdentifier.init) == watchedUtteranceID,
              usingDirectMode,
              isSpeaking,
              !isPaused else {
            transitionLog("DIRECT_WATCHDOG_CANCELLED: playback state changed before recovery")
            return
        }

        let reportedOffset = currentWordRange?.location ?? directModeBaseOffset
        let safeOffset = max(0, min(reportedOffset, currentText.utf16Length))
        if audioEngine.hasRenderedAudio {
            transitionLog("DIRECT_WATCHDOG_RECOVERY: synthesizer idle without usable didFinish; switching to rendered audio at offset=\(safeOffset) chunkEnd=\(directModeChunkEnd)")
            stopDirectSynthesizer()
            usingDirectMode = false
            audioEngine.setSpeed(wpm: wordsPerMinute)
            audioEngine.setPitch(multiplier: pitchMultiplier)
            audioEngine.play(fromCharOffset: safeOffset)
            if audioEngine.isPlaying {
                startPositionTracking()
            } else {
                // A rendered buffer can survive an engine-start failure. Fall
                // back to direct speech rather than leaving the logical state
                // active with a second silent backend.
                transitionLog("DIRECT_WATCHDOG_ENGINE_FAILED: rendered audio did not start; restarting direct speech at offset=\(safeOffset)")
                audioEngine.stop()
                speakDirect(currentText, fromCharOffset: safeOffset)
            }
            return
        }

        // A final word callback near the expected chunk boundary means the
        // chunk almost certainly played to completion. Continuing at the exact
        // boundary avoids replaying a word while still refusing to skip a large
        // unconfirmed span of text.
        let unconfirmedChunkUnits = directModeChunkEnd - safeOffset
        if directModeChunked,
           directModeChunkEnd < currentText.utf16Length,
           unconfirmedChunkUnits >= 0,
           unconfirmedChunkUnits <= 200 {
            let nextOffset = directModeChunkEnd
            transitionLog("DIRECT_WATCHDOG_RECOVERY: synthesizer idle near chunk end; continuing at offset=\(nextOffset) lastReportedOffset=\(safeOffset)")
            stopDirectSynthesizer()
            speakDirect(currentText, fromCharOffset: nextOffset)
            return
        }

        transitionLog("DIRECT_WATCHDOG_RECOVERY: synthesizer idle before confirmed finish; restarting direct speech at offset=\(safeOffset) chunkEnd=\(directModeChunkEnd)")
        stopDirectSynthesizer()
        speakDirect(currentText, fromCharOffset: safeOffset)
    }

    /// Stop the direct synthesizer and clear the live-utterance marker so
    /// any pending `didFinish` callback for the stopped utterance is
    /// recognised as stale and ignored. Replaces the older
    /// `ignoreDirectFinishCount += 1; directSynth.stopSpeaking(...)` pair
    /// at every internal stop site — that scheme could desync if the
    /// system delivered a different number of didFinish events than we
    /// expected. Identity comparison can't desync.
    private func stopDirectSynthesizer() {
        stopDirectPlaybackWatchdog()
        liveDirectUtterance = nil
        directSynth.stopSpeaking(at: .immediate)
    }

    func pause() {
        guard isSpeaking && !isPaused else { return }
        if usingDirectMode {
            directSynth.pauseSpeaking(at: .immediate)
        } else if audioEngine.isPlaying {
            audioEngine.pause()
        }
        // Always set isPaused — even if engine hasn't started yet (still rendering)
        // The render completion checks isPaused before starting playback
        isPaused = true
        stopPositionTracking()
    }

    /// Complete a sleep-timer fade by halting the active TTS backend before
    /// restoring engine volume. In engine mode, `pause()` alone is not enough:
    /// the time-pitch/mixer path can still have downstream audio after the
    /// player node pauses, so restoring the mixer immediately can produce a
    /// final full-volume tail.
    func pauseForSleepTimerFadeCompletion() {
        defer {
            audioEngine.restoreVolume()
        }

        guard isSpeaking && !isPaused else { return }

        if usingDirectMode {
            directSynth.pauseSpeaking(at: .immediate)
        } else if audioEngine.isPlaying || audioEngine.isPaused {
            let offset = audioEngine.stopAfterFadePreservingPosition()
            currentWordRange = NSRange(location: offset, length: 0)
        }

        isPaused = true
        stopPositionTracking()
    }

    func resume() {
        guard isPaused else { return }
        isPaused = false

        if usingDirectMode, let pendingOffset = pendingDirectSeekOffset {
            pendingDirectSeekOffset = nil
            if audioEngine.hasRenderedAudio {
                transitionLog("RESUME_SWITCH: direct→engine at offset=\(pendingOffset)")
                stopDirectSynthesizer()
                usingDirectMode = false
                audioEngine.setSpeed(wpm: wordsPerMinute)
                audioEngine.setPitch(multiplier: pitchMultiplier)
                audioEngine.play(fromCharOffset: pendingOffset)
                startPositionTracking()
            } else {
                speakDirect(currentText, fromCharOffset: pendingOffset)
            }
        } else if !usingDirectMode && audioEngine.isPaused {
            // The Mac may have stopped AVAudioEngine while sleeping. The
            // audio service restarts it before asking the player node to
            // continue. If restart itself fails, direct speech provides a
            // usable fallback at the same reading position.
            let offset = currentWordRange?.location ?? audioEngine.currentCharOffset()
            if audioEngine.resume() {
                transitionLog("ENGINE_RESUME: resumed at offset=\(offset)")
                startPositionTracking()
            } else {
                transitionLog("ENGINE_RESUME_FAILED: falling back to direct speech at offset=\(offset)")
                audioEngine.stop()
                speakDirect(currentText, fromCharOffset: offset)
            }
        } else if usingDirectMode && audioEngine.hasRenderedAudio {
            // Paused in direct mode but engine is ready — switch to engine for better seeking/speed
            let offset = currentWordRange?.location ?? 0
            transitionLog("RESUME_SWITCH: direct→engine at offset=\(offset)")
            stopDirectSynthesizer()
            usingDirectMode = false
            audioEngine.setSpeed(wpm: wordsPerMinute)
            audioEngine.setPitch(multiplier: pitchMultiplier)
            audioEngine.play(fromCharOffset: offset)
            startPositionTracking()
        } else if usingDirectMode {
            // Still in direct mode, engine not ready — just continue direct
            directSynth.continueSpeaking()
        } else if audioEngine.hasRenderedAudio && !audioEngine.isPlaying {
            // Engine ready but not playing — start it
            let offset = currentWordRange?.location ?? 0
            audioEngine.setSpeed(wpm: wordsPerMinute)
            audioEngine.setPitch(multiplier: pitchMultiplier)
            audioEngine.play(fromCharOffset: offset)
            startPositionTracking()
        }
    }

    func togglePlayPause() {
        if isPaused {
            resume()
        } else if isSpeaking {
            pause()
        }
    }

    func stop() {
        renderGeneration += 1  // Invalidate any in-flight render
        // Clear the live-utterance marker so any pending didFinish for
        // the in-flight direct-mode utterance is recognised as stale
        // and ignored — without this, a finish callback delivered after
        // a new utterance had started would cause an unwanted chapter
        // advance.
        stopDirectSynthesizer()
        // Cancel any in-progress background render so it doesn't compete
        // with the next direct-mode TTS for system resources
        audioEngine.cancelRender()
        audioEngine.stop()
        isSpeaking = false
        isPaused = false
        currentWordRange = nil
        usingDirectMode = false
        directModeBaseOffset = 0
        directModeChunked = false
        directModeChunkEnd = 0
        pendingDirectSeekOffset = nil
        stopPositionTracking()
    }

    var isActive: Bool {
        return isSpeaking || isPaused
    }

    /// Start playback using a pre-rendered AudioEngineService (for seamless chapter transitions).
    /// Swaps the pre-rendered engine in and starts playing immediately — no direct mode, no rendering delay.
    func usePreRenderedEngine(_ preEngine: AudioEngineService, text: String, fromCharOffset charOffset: Int = 0) {
        stop()
        currentText = text
        renderGeneration += 1

        // Swap the pre-rendered engine's buffers into our engine
        // We can't swap the engine object itself since it's a let, so copy the rendered data
        audioEngine.adoptRenderedAudio(from: preEngine)

        isSpeaking = true
        isPaused = false
        usingDirectMode = false

        audioEngine.setSpeed(wpm: wordsPerMinute)
        audioEngine.setPitch(multiplier: pitchMultiplier)
        audioEngine.play(fromCharOffset: charOffset)
        startPositionTracking()

        audioEngine.onPlaybackFinished = { [weak self] in
            self?.handleEngineFinished()
        }

        transitionLog("PRE_RENDERED_START: playing chapter (\(text.utf16Length) UTF-16 units) from offset \(charOffset)")
    }

    // MARK: - Seeking

    /// Seek to a character offset within the current text.
    /// If audio engine is ready, switches to it for instant seeking.
    /// Otherwise restarts direct speech from the new offset.
    func seek(toCharOffset offset: Int) {
        // Bump the position-tracking generation so any in-flight 100ms
        // polling dispatch (offset captured pre-seek, word extraction
        // running on the background queue) is dropped on its way back
        // to main and doesn't overwrite the now-correct position.
        positionGeneration += 1

        if audioEngine.hasRenderedAudio {
            // Engine is ready — use it (switch from direct mode if needed)
            if usingDirectMode {
                stopDirectSynthesizer()
                if isPaused {
                    pendingDirectSeekOffset = offset
                } else {
                    transitionLog("SEEK_SWITCH: direct→engine at offset=\(offset)")
                    usingDirectMode = false
                    audioEngine.setSpeed(wpm: wordsPerMinute)
                    audioEngine.setPitch(multiplier: pitchMultiplier)
                    audioEngine.play(fromCharOffset: offset)
                    startPositionTracking()
                }
            } else {
                audioEngine.seek(toCharOffset: offset)
                if audioEngine.isPlaying {
                    startPositionTracking()
                }
            }
        } else if usingDirectMode {
            // No engine yet — restart direct mode from new position.
            // stopDirectSynthesizer() clears the live-utterance marker so
            // the OLD utterance's didFinish (if it fires after speakDirect
            // assigns a new live utterance) is correctly seen as stale.
            stopDirectSynthesizer()
            if isPaused {
                pendingDirectSeekOffset = offset
            } else {
                speakDirect(currentText, fromCharOffset: offset)
            }
        }
        let range = NSRange(location: offset, length: 0)
        currentWordRange = range
        onWordSpoken?(range, "")
    }

    /// Change speed in real-time without interrupting playback.
    func setSpeedRealtime(_ newWPM: Double) {
        wordsPerMinute = max(minimumWPM, min(newWPM, maximumWPM))
        // wordsPerMinute didSet handles audioEngine.setSpeed
    }

    /// Change pitch in real-time without interrupting playback.
    func setPitchRealtime(_ newPitch: Double) {
        pitchMultiplier = Self.clampedPitch(newPitch)
        // pitchMultiplier didSet handles audioEngine.setPitch
    }

    /// Clamp a pitch multiplier to the range supported by both speech backends.
    nonisolated static func clampedPitch(_ pitch: Double) -> Double {
        max(0.5, min(pitch, 2.0))
    }

    /// User-facing pitch label shared by reader and global settings screens.
    nonisolated static func pitchLabel(_ pitch: Double) -> String {
        if abs(pitch - 1.0) < 0.05 { return "Normal (1.0x)" }
        return String(format: "%.1fx", pitch)
    }

    // MARK: - Position Tracking

    func currentCharOffset() -> Int {
        if usingDirectMode {
            return currentWordRange?.location ?? 0
        }
        return audioEngine.currentCharOffset()
    }

    /// Background queue for position tracking string operations.
    /// String.index(offsetBy:) is O(n) for Swift strings — running
    /// it on the main thread every 100ms with large chapter texts
    /// (30K+ chars) causes UI freezes. The word extraction happens
    /// here; only the final result is dispatched to main.
    private static let positionQueue = DispatchQueue(
        label: "com.textmouth.positionTracking",
        qos: .userInteractive
    )

    private func startPositionTracking() {
        // stopPositionTracking() invalidates the previous timer AND bumps
        // the generation, so any in-flight dispatch from the old timer is
        // dropped before the new timer starts. Capture the post-bump
        // generation for the new timer's ticks.
        stopPositionTracking()
        let myGeneration = positionGeneration
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, !self.usingDirectMode,
                  self.audioEngine.isPlaying || self.audioEngine.isPaused else { return }
            // currentCharOffset() reads the audio node's render time,
            // which is safe from the main thread (the timer's thread)
            let offset = self.audioEngine.currentCharOffset()
            let range = NSRange(location: offset, length: 1)
            // Capture the text for background processing. The text
            // doesn't change during playback so this reference is safe.
            let text = self.currentText
            let publish: @MainActor @Sendable (String) -> Void = { [weak self] word in
                guard let self else { return }
                guard Self.shouldPublishPosition(
                    capturedGeneration: myGeneration,
                    currentGeneration: self.positionGeneration
                ) else { return }
                self.currentWordRange = range
                if !word.isEmpty {
                    self.onWordSpoken?(range, word)
                }
            }

            // Move the O(n) string indexing off the main thread.
            // String.index(startIndex, offsetBy:) iterates through
            // Unicode scalars from the start — expensive for large texts.
            Self.positionQueue.async {
                let word: String
                if offset >= 0 && offset < text.utf16Length {
                    let idx = text.index(atUTF16Offset: offset)
                    var end = idx
                    while end < text.endIndex && !text[end].isWhitespace {
                        end = text.index(after: end)
                    }
                    word = String(text[idx..<end])
                } else {
                    word = ""
                }
                // Drop the publish if the position generation moved while
                // extraction ran; the main-actor closure owns that check.
                DispatchQueue.main.async { publish(word) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        positionTimer = timer
    }

    private func stopPositionTracking() {
        // Bump the generation BEFORE invalidating so any dispatch already
        // captured by the soon-to-be-invalidated tick is also dropped on
        // its way back to main.
        positionGeneration += 1
        positionTimer?.invalidate()
        positionTimer = nil
    }

    private func handleEngineFinished() {
        transitionLog("ENGINE_FINISHED: audio fully played back, advancing chapter")
        stopPositionTracking()
        isSpeaking = false
        isPaused = false
        currentWordRange = nil
        onUtteranceFinished?()
    }

    // MARK: - Rate Table (for direct mode fallback)

    private static let rateTable: [(rate: Double, wpm: Double)] = [
        (0.0, 50), (0.1, 80), (0.2, 120), (0.3, 167), (0.4, 190),
        (0.5, 216), (0.6, 344), (0.7, 457), (0.8, 604), (0.9, 759), (1.0, 871),
    ]

    /// Convert WPM to AVSpeechUtterance rate using the calibrated rate table.
    /// Public so voice preview UI can use the same calculation.
    static func rateForWPM(_ wpm: Double) -> Float {
        let table = Self.rateTable
        guard let first = table.first, let last = table.last else { return 0.5 }
        if wpm <= first.wpm { return Float(first.rate) }
        if wpm >= last.wpm { return Float(last.rate) }

        for i in 0..<(table.count - 1) {
            let lo = table[i]
            let hi = table[i + 1]
            if wpm >= lo.wpm && wpm <= hi.wpm {
                let fraction = (wpm - lo.wpm) / (hi.wpm - lo.wpm)
                return Float(lo.rate + fraction * (hi.rate - lo.rate))
            }
        }
        return 0.5
    }

    deinit {
        stop()
    }
}

// MARK: - AVSpeechSynthesizerDelegate (direct mode fallback)

extension SpeechService: AVSpeechSynthesizerDelegate {

    nonisolated static func isLiveDirectUtterance(
        _ utterance: AVSpeechUtterance,
        liveUtterance: AVSpeechUtterance?
    ) -> Bool {
        liveUtterance.map(ObjectIdentifier.init) == ObjectIdentifier(utterance)
    }

    nonisolated static func shouldPublishPosition(capturedGeneration: Int, currentGeneration: Int) -> Bool {
        capturedGeneration == currentGeneration
    }

    /// Decide whether the system synthesizer is unexpectedly idle while the
    /// app still considers direct speech active. Kept as a pure policy method
    /// so every safety condition can be regression-tested without producing
    /// real speech in the test process.
    nonisolated static func shouldRecoverIdleDirectSpeech(
        appIsSpeaking: Bool,
        appIsPaused: Bool,
        usingDirectMode: Bool,
        synthesizerIsSpeaking: Bool,
        synthesizerIsPaused: Bool,
        hasLiveUtterance: Bool
    ) -> Bool {
        appIsSpeaking
            && !appIsPaused
            && usingDirectMode
            && !synthesizerIsSpeaking
            && !synthesizerIsPaused
            && hasLiveUtterance
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        // Identity check mirrors the one in didFinish — a willSpeak
        // for an utterance we no longer consider live is the tail of
        // an internal stopSpeaking (mode switch / seek / new chunk).
        // Without this guard, a stale willSpeak could combine its
        // characterRange (relative to the OLD utterance) with the
        // CURRENT directModeBaseOffset (which already advanced for the
        // NEW utterance) and emit a wildly wrong absolute position —
        // exactly the symptom that makes seeks feel like they jumped
        // to a random place.
        guard usingDirectMode,
              Self.isLiveDirectUtterance(utterance, liveUtterance: liveDirectUtterance) else { return }
        let baseOffset = directModeBaseOffset
        let word = (utterance.speechString as NSString).substring(with: characterRange)
        DispatchQueue.main.async { [weak self] in
            // Adjust range to be absolute within the full chapter text
            let absoluteRange = NSRange(location: characterRange.location + baseOffset, length: characterRange.length)
            self?.currentWordRange = absoluteRange
            self?.onWordSpoken?(absoluteRange, word)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard Self.isLiveDirectUtterance(utterance, liveUtterance: self.liveDirectUtterance),
                  self.usingDirectMode else {
                self.transitionLog("DIRECT_START_IGNORED: stale utterance or direct mode inactive")
                return
            }
            self.transitionLog("DIRECT_START_ACCEPTED: offset=\(self.directModeBaseOffset) chunkEnd=\(self.directModeChunkEnd) synthSpeaking=\(synthesizer.isSpeaking)")
            self.isSpeaking = true
            self.isPaused = false
            self.startDirectPlaybackWatchdog(for: utterance)
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let finishedUtteranceID = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Identity check: a finish for an utterance we no longer
            // consider live is an artefact of an internal stopSpeaking
            // (mode switch / seek / stop). Drop it so it doesn't trigger
            // chapter advance after a new utterance has already started.
            // Compares to `liveDirectUtterance` rather than counting calls,
            // so we can't desync if the system delivers an unexpected
            // number of didFinish events.
            guard self.liveDirectUtterance.map(ObjectIdentifier.init) == finishedUtteranceID else {
                let liveDescription = self.liveDirectUtterance
                    .map { String(describing: ObjectIdentifier($0)) } ?? "nil"
                self.transitionLog("DIRECT_FINISH_IGNORED: utterance mismatch finished=\(finishedUtteranceID) live=\(liveDescription) directMode=\(self.usingDirectMode) synthSpeaking=\(synthesizer.isSpeaking) synthPaused=\(synthesizer.isPaused)")
                return
            }
            guard self.usingDirectMode else {
                self.transitionLog("DIRECT_FINISH_IGNORED: matching utterance but direct mode inactive finished=\(finishedUtteranceID)")
                return
            }

            self.transitionLog("DIRECT_FINISH_ACCEPTED: offset=\(self.directModeBaseOffset) chunkEnd=\(self.directModeChunkEnd) chunked=\(self.directModeChunked)")
            self.stopDirectPlaybackWatchdog()

            // This utterance has finished naturally — clear the marker so
            // a future stop-without-start doesn't accidentally process its
            // own didFinish twice.
            self.liveDirectUtterance = nil

            // If this was a chunked utterance, continue with the next direct chunk.
            if self.directModeChunked {
                let nextOffset = self.directModeChunkEnd
                if nextOffset < self.currentText.utf16Length {
                    // speakDirect assigns a fresh `liveDirectUtterance`
                    // for the new chunk.
                    self.transitionLog("CHUNK_CONTINUE: next chunk at offset \(nextOffset)")
                    self.speakDirect(self.currentText, fromCharOffset: nextOffset)
                    return
                }
                // else: reached end of text, fall through to normal finish
            }

            self.isSpeaking = false
            self.isPaused = false
            self.currentWordRange = nil
            self.directModeChunked = false
            self.onUtteranceFinished?()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let cancelledUtteranceID = ObjectIdentifier(utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let isCurrent = self.liveDirectUtterance.map(ObjectIdentifier.init) == cancelledUtteranceID
            if isCurrent, self.usingDirectMode, self.isSpeaking, !self.isPaused {
                // Do not advance or restart directly from the callback. The
                // watchdog verifies that the synthesizer remains idle before
                // choosing a content-preserving recovery offset.
                self.transitionLog("DIRECT_CANCEL_UNEXPECTED: live utterance cancelled while app expected playback; watchdog armed=\(self.directPlaybackWatchdogTimer != nil) synthSpeaking=\(synthesizer.isSpeaking) synthPaused=\(synthesizer.isPaused)")
            } else {
                self.transitionLog("DIRECT_CANCEL_EXPECTED: stale or deliberately stopped utterance cancelled current=\(isCurrent) directMode=\(self.usingDirectMode) appSpeaking=\(self.isSpeaking) appPaused=\(self.isPaused)")
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.usingDirectMode,
                  Self.isLiveDirectUtterance(utterance, liveUtterance: self.liveDirectUtterance) else {
                self.transitionLog("DIRECT_PAUSE_IGNORED: stale utterance or direct mode inactive")
                return
            }
            self.isPaused = true
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.usingDirectMode,
                  Self.isLiveDirectUtterance(utterance, liveUtterance: self.liveDirectUtterance) else {
                self.transitionLog("DIRECT_CONTINUE_IGNORED: stale utterance or direct mode inactive")
                return
            }
            self.isPaused = false
        }
    }
}
