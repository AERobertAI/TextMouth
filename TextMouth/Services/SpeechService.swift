import AVFoundation
import Combine

/// Manages TTS playback using two modes:
/// 1. **Audio Engine mode** (default): Pre-renders speech with AVSpeechSynthesizer.write(),
///    plays through AVAudioEngine + AVAudioUnitTimePitch for real-time speed changes and instant seeking.
/// 2. **Direct mode** (fallback): Uses AVSpeechSynthesizer.speak() directly with word-by-word callbacks.
class SpeechService: NSObject, ObservableObject {
    let audioEngine = AudioEngineService()

    /// Fallback direct synthesizer
    private let directSynth = AVSpeechSynthesizer()
    private var usingDirectMode = false

    /// Tracks whether we were cancelled/paused/stopped during async rendering
    private var renderGeneration: Int = 0
    /// Counts how many directSynth.didFinish callbacks to ignore (e.g. from internal stop during mode switch)
    private var ignoreDirectFinishCount: Int = 0

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
    /// Max characters to pass to direct-mode TTS at once. Keeps startup latency low
    /// while providing enough audio buffer for the engine to render in the background.
    private static let directModeChunkSize = 5000
    /// Timer to poll playback position from audio engine
    private var positionTimer: Timer?

    private var settingsCancellables = Set<AnyCancellable>()

    private func transitionLog(_ msg: String) {
        let logPath = TextMouthPaths.logsDir.appendingPathComponent("textmouth_transition.log").path
        let line = "\(Date()): \(msg)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logPath),
               let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath))
            }
        }
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

    /// Speak text. Starts playback immediately in direct mode for zero latency.
    /// Pre-renders in background so audio engine is ready for seeking, speed changes,
    /// or to play the next chapter without delay. Does NOT switch mid-playback to avoid
    /// audible glitches — the engine is used on the next natural break (seek, pause, chapter end).
    func speak(_ text: String, fromCharOffset charOffset: Int = 0) {
        stop()
        currentText = text

        // Increment generation so stale render completions are ignored
        renderGeneration += 1
        let myGeneration = renderGeneration

        isSpeaking = true
        isPaused = false

        // Start direct mode immediately for zero-latency playback
        speakDirect(text, fromCharOffset: charOffset)

        // Pre-render in background so engine is ready for seeks, pauses, or next chapter.
        // We do NOT switch mid-playback — direct mode runs until a natural break.
        audioEngine.render(text: text, voice: currentVoice, wpm: wordsPerMinute) { [weak self] success in
            guard let self = self else { return }
            guard self.renderGeneration == myGeneration else { return }

            if success {
                self.transitionLog("RENDER_READY: engine rendered \(text.count) chars, direct mode still active=\(self.usingDirectMode)")
            } else {
                self.transitionLog("RENDER_FAILED: engine render failed, staying in direct mode")
            }
            // Engine is now ready. It will be used when:
            // - User seeks (seek() checks audioEngine.hasRenderedAudio)
            // - User pauses then resumes (resume() switches to engine)
            // - Chapter ends (next chapter can start directly in engine mode)
        }
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

            audioEngine.render(text: text, voice: currentVoice, wpm: wordsPerMinute) { [weak self] success in
                guard let self = self else { return }
                guard self.renderGeneration == myGeneration else { return }
                if success {
                    self.transitionLog("RENDER_READY (speakWithEngine): rendered, direct still active=\(self.usingDirectMode)")
                }
            }
        }
    }

    private func speakDirect(_ text: String, fromCharOffset charOffset: Int) {
        usingDirectMode = true
        let startOffset = max(0, min(charOffset, text.count))
        let startIdx = text.index(text.startIndex, offsetBy: startOffset)
        let remainingCount = text.distance(from: startIdx, to: text.endIndex)

        let speakText: String
        if remainingCount > Self.directModeChunkSize {
            // Chunk: take only directModeChunkSize chars, snapped to a word boundary
            var endIdx = text.index(startIdx, offsetBy: Self.directModeChunkSize)
            // Advance to end of current word so we don't cut mid-word
            while endIdx < text.endIndex && !text[endIdx].isWhitespace {
                endIdx = text.index(after: endIdx)
            }
            speakText = String(text[startIdx..<endIdx])
            directModeBaseOffset = startOffset
            directModeChunkEnd = startOffset + speakText.count
            directModeChunked = true
        } else if startOffset > 0 {
            speakText = String(text[startIdx...])
            directModeBaseOffset = startOffset
            directModeChunkEnd = text.count
            directModeChunked = false
        } else {
            speakText = text
            directModeBaseOffset = 0
            directModeChunkEnd = text.count
            directModeChunked = false
        }

        let utterance = AVSpeechUtterance(string: speakText)
        utterance.voice = currentVoice
        utterance.rate = Self.rateForWPM(wordsPerMinute)
        utterance.pitchMultiplier = Float(max(0.5, min(pitchMultiplier, 2.0)))
        utterance.prefersAssistiveTechnologySettings = false
        directSynth.speak(utterance)
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

    func resume() {
        guard isPaused else { return }
        isPaused = false

        if !usingDirectMode && audioEngine.isPaused {
            // Already in engine mode and paused — just resume
            audioEngine.resume()
            startPositionTracking()
        } else if usingDirectMode && audioEngine.hasRenderedAudio {
            // Paused in direct mode but engine is ready — switch to engine for better seeking/speed
            let offset = currentWordRange?.location ?? 0
            transitionLog("RESUME_SWITCH: direct→engine at offset=\(offset)")
            ignoreDirectFinishCount += 1
            directSynth.stopSpeaking(at: .immediate)
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
        // Suppress the didFinish callback that stopSpeaking triggers,
        // so it doesn't fire after a new utterance starts and cause chapter-advance.
        if directSynth.isSpeaking || directSynth.isPaused {
            ignoreDirectFinishCount += 1
        }
        directSynth.stopSpeaking(at: .immediate)
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

        transitionLog("PRE_RENDERED_START: playing chapter (\(text.count) chars) from offset \(charOffset)")
    }

    // MARK: - Seeking

    /// Seek to a character offset within the current text.
    /// If audio engine is ready, switches to it for instant seeking.
    /// Otherwise restarts direct speech from the new offset.
    func seek(toCharOffset offset: Int) {
        if audioEngine.hasRenderedAudio {
            // Engine is ready — use it (switch from direct mode if needed)
            if usingDirectMode {
                transitionLog("SEEK_SWITCH: direct→engine at offset=\(offset)")
                ignoreDirectFinishCount += 1
                directSynth.stopSpeaking(at: .immediate)
                usingDirectMode = false
                let wasPlaying = isSpeaking && !isPaused
                audioEngine.setSpeed(wpm: wordsPerMinute)
                audioEngine.setPitch(multiplier: pitchMultiplier)
                if wasPlaying {
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
            // No engine yet — restart direct mode from new position
            ignoreDirectFinishCount += 1
            directSynth.stopSpeaking(at: .immediate)
            speakDirect(currentText, fromCharOffset: offset)
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
        pitchMultiplier = max(minimumPitch, min(newPitch, maximumPitch))
        // pitchMultiplier didSet handles audioEngine.setPitch
    }

    // MARK: - Position Tracking

    func currentCharOffset() -> Int {
        if usingDirectMode {
            return currentWordRange?.location ?? 0
        }
        return audioEngine.currentCharOffset()
    }

    private func startPositionTracking() {
        stopPositionTracking()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self, !self.usingDirectMode,
                  self.audioEngine.isPlaying || self.audioEngine.isPaused else { return }
            let offset = self.audioEngine.currentCharOffset()
            let range = NSRange(location: offset, length: 1)

            DispatchQueue.main.async {
                self.currentWordRange = range
                if offset >= 0 && offset < self.currentText.count {
                    let idx = self.currentText.index(self.currentText.startIndex, offsetBy: offset)
                    var end = idx
                    while end < self.currentText.endIndex && !self.currentText[end].isWhitespace {
                        end = self.currentText.index(after: end)
                    }
                    let word = String(self.currentText[idx..<end])
                    self.onWordSpoken?(range, word)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        positionTimer = timer
    }

    private func stopPositionTracking() {
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

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        guard usingDirectMode else { return }
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
            self?.isSpeaking = true
            self?.isPaused = false
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Ignore finish callbacks caused by internal stopSpeaking (e.g. mode switch)
            if self.ignoreDirectFinishCount > 0 {
                self.ignoreDirectFinishCount -= 1
                return
            }
            guard self.usingDirectMode else { return }

            // If this was a chunked utterance, continue with next chunk or switch to engine
            if self.directModeChunked {
                let nextOffset = self.directModeChunkEnd
                if self.audioEngine.hasRenderedAudio {
                    // Engine is ready — switch to it for the rest of the chapter
                    self.transitionLog("CHUNK_SWITCH: direct chunk ended at \(nextOffset), switching to engine")
                    self.usingDirectMode = false
                    self.directModeChunked = false
                    self.audioEngine.setSpeed(wpm: self.wordsPerMinute)
                    self.audioEngine.setPitch(multiplier: self.pitchMultiplier)
                    self.audioEngine.play(fromCharOffset: nextOffset)
                    self.startPositionTracking()
                    return
                } else if nextOffset < self.currentText.count {
                    // Engine not ready yet — speak the next chunk
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

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        guard usingDirectMode else { return }
        DispatchQueue.main.async { [weak self] in
            self?.isPaused = true
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        guard usingDirectMode else { return }
        DispatchQueue.main.async { [weak self] in
            self?.isPaused = false
        }
    }
}
