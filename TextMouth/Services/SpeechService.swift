import AVFoundation
import Combine
import os

/// Whether a render succeeded, kept by the render's completion for the
/// render coordinator, which waits for that completion before it reports.
/// `@unchecked Sendable`: the value is read and changed only under `lock`.
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

/// Chooses a concrete recovery path for a paused TTS session. Keeping the
/// decision independent from AVFoundation makes every desynchronized backend
/// state testable, including the state seen in logs where TextMouth was paused
/// but neither synthesizer nor audio engine could actually continue.
enum SpeechResumePolicy {
    enum Action: Equatable {
        case switchToEngine(offset: Int)
        case resumeEngine(offset: Int)
        case continueDirect(offset: Int)
        case restartDirect(offset: Int)
        case startRenderedEngine(offset: Int)
        case alreadyPlaying
        case unavailable
    }

    static func action(
        usingDirectMode: Bool,
        pendingDirectSeekOffset: Int?,
        engineHasRenderedAudio: Bool,
        engineIsPaused: Bool,
        engineIsPlaying: Bool,
        directSynthIsPaused: Bool,
        currentOffset: Int,
        hasText: Bool
    ) -> Action {
        let safeOffset = max(0, currentOffset)

        if let pendingOffset = pendingDirectSeekOffset {
            if engineHasRenderedAudio {
                return .switchToEngine(offset: max(0, pendingOffset))
            }
            return hasText ? .restartDirect(offset: max(0, pendingOffset)) : .unavailable
        }
        if !usingDirectMode, engineIsPaused {
            return .resumeEngine(offset: safeOffset)
        }
        if usingDirectMode, engineHasRenderedAudio {
            return .switchToEngine(offset: safeOffset)
        }
        if usingDirectMode, directSynthIsPaused {
            return .continueDirect(offset: safeOffset)
        }
        if usingDirectMode {
            // App state can remain paused after AVSpeechSynthesizer silently
            // loses its utterance. A fresh utterance is the only useful path.
            return hasText ? .restartDirect(offset: safeOffset) : .unavailable
        }
        if engineHasRenderedAudio, !engineIsPlaying {
            return .startRenderedEngine(offset: safeOffset)
        }
        if engineIsPlaying {
            return .alreadyPlaying
        }
        return hasText ? .restartDirect(offset: safeOffset) : .unavailable
    }
}

/// An utterance a synthesizer callback hands over to the main queue, kept
/// alive until it is compared there with the live utterance. Every
/// callback that reaches the main queue (a word, a start, a pause, a
/// continue, a finish, and a cancel) hands its utterance over this way,
/// never by capturing the utterance itself, which is not `Sendable`.
///
/// An `ObjectIdentifier` alone is only an address: once its utterance is
/// released, the next utterance made can take the same address and the
/// same identifier. Holding the utterance keeps its address its own, so a
/// callback for a stopped utterance is never taken for the live one's.
/// `@unchecked Sendable` because the utterance is only held, never changed:
/// the main queue reads its identity and its text (`speechString`, which
/// cannot change once the utterance is made).
struct ReportedUtterance: @unchecked Sendable {
    /// The utterance the synthesizer reported on.
    let utterance: AVSpeechUtterance

    /// The utterance's identity, which no other live object shares.
    var id: ObjectIdentifier { ObjectIdentifier(utterance) }
}

/// One piece of a text that direct speech hands the synthesizer as a single
/// utterance. Kept independent of AVFoundation so its boundaries can be
/// tested on any text.
struct DirectSpeechChunk: Equatable {
    /// Where the chunk begins in the text, in UTF-16 units: the offset asked
    /// for, moved back to the start of the character it falls in.
    let start: Int
    /// Where the chunk ends: just past a word, never inside one, or at the
    /// end of the text.
    let end: Int
    /// Whether the rest of the text was longer than one chunk, so speech
    /// goes on from `end`.
    let isPartial: Bool

    /// The chunk of `text` that begins at UTF-16 offset `offset` and holds
    /// at most `maximumLength` units, extended to the end of the word that
    /// limit would cut; the whole rest of the text when that is no longer
    /// than `maximumLength`.
    static func starting(at offset: Int, in text: String, maximumLength: Int) -> DirectSpeechChunk {
        let startIndex = text.index(atUTF16Offset: max(0, min(offset, text.utf16Length)))
        let start = text.utf16Offset(of: startIndex)
        let length = text.utf16Length
        guard length - start > maximumLength else {
            return DirectSpeechChunk(start: start, end: length, isPartial: false)
        }
        var endIndex = text.index(atUTF16Offset: start + maximumLength)
        // Advance to the end of the current word so no word is cut.
        while endIndex < text.endIndex && !text[endIndex].isWhitespace {
            endIndex = text.index(after: endIndex)
        }
        return DirectSpeechChunk(start: start, end: text.utf16Offset(of: endIndex), isPartial: true)
    }

    /// The chunk's part of `text`, the text it was made from.
    func words(of text: String) -> String {
        guard start > 0 || end < text.utf16Length else { return text }
        return String(text[text.index(atUTF16Offset: start)..<text.index(atUTF16Offset: end)])
    }
}

/// A short, pre-volume-adjusted utterance used to fade direct speech.
/// `AVSpeechUtterance.volume` only takes effect when assigned before the
/// utterance is enqueued, so direct `AVSpeechSynthesizer` playback cannot use
/// the audio engine's live mixer-volume updates.
struct DirectSpeechFadeSegment: Equatable {
    let text: String
    let baseUTF16Offset: Int
    let volume: Float

    var endUTF16Offset: Int {
        baseUTF16Offset + text.utf16Length
    }
}

/// Builds the small utterance queue required to fade direct speech without
/// losing the reader's absolute position. Kept independent of AVFoundation so
/// Unicode offsets, volume progression, and edge cases can be unit-tested.
enum DirectSpeechFadePlanner {
    /// Two volume changes per second sound gradual without introducing the
    /// many tiny utterance boundaries that can make synthesized speech choppy.
    private static let segmentsPerSecond = 2.0
    private static let maximumSegmentCount = 8

    static func segments(
        in text: String,
        fromUTF16Offset requestedOffset: Int,
        duration: TimeInterval,
        wordsPerMinute: Double,
        startingVolume: Float = 1
    ) -> [DirectSpeechFadeSegment] {
        guard !text.isEmpty, duration > 0 else { return [] }

        let clampedOffset = max(0, min(requestedOffset, text.utf16Length))
        let startIndex = text.index(atUTF16Offset: clampedOffset)
        let normalizedOffset = text.utf16Offset(of: startIndex)
        guard startIndex < text.endIndex else { return [] }

        // Include a modest margin because voices do not all speak at exactly
        // the calibrated WPM. The timer still stops playback at the requested
        // wall-clock duration; extra queued words are never allowed to leak.
        let estimatedWords = max(
            1,
            Int(ceil(max(1, wordsPerMinute) * duration / 60.0 * 1.25))
        )
        let remaining = text[startIndex...]
        var wordRanges: [Range<String.Index>] = []
        text.enumerateSubstrings(
            in: startIndex..<text.endIndex,
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, stop in
            wordRanges.append(range)
            if wordRanges.count >= estimatedWords {
                stop = true
            }
        }

        // A punctuation-only tail has no `.byWords` ranges, but it is still
        // valid speakable input. Fade that remaining text as one utterance.
        guard !wordRanges.isEmpty else {
            return [DirectSpeechFadeSegment(
                text: String(remaining),
                baseUTF16Offset: normalizedOffset,
                volume: max(0, min(startingVolume, 1)) * 0.5
            )]
        }

        let requestedSegmentCount = max(1, Int(ceil(duration * segmentsPerSecond)))
        let segmentCount = min(wordRanges.count, maximumSegmentCount, requestedSegmentCount)
        var segments: [DirectSpeechFadeSegment] = []
        var segmentStart = startIndex

        for segmentIndex in 0..<segmentCount {
            // Proportional endpoints distribute an uneven word count across
            // the requested segment count without dropping any whitespace.
            let wordEndIndex = Int(
                ceil(Double(segmentIndex + 1) * Double(wordRanges.count) / Double(segmentCount))
            ) - 1
            let segmentEnd = wordRanges[wordEndIndex].upperBound
            let segmentText = String(text[segmentStart..<segmentEnd])
            // Use each interval's midpoint so even a one-second/two-segment
            // fade audibly decreases instead of spending its first half at
            // full volume and ending far above silence.
            let relativeVolume = 1 - Float(segmentIndex * 2 + 1) / Float(segmentCount * 2)
            let volume = max(0, min(startingVolume, 1)) * relativeVolume
            segments.append(DirectSpeechFadeSegment(
                text: segmentText,
                baseUTF16Offset: text.utf16Offset(of: segmentStart),
                volume: volume
            ))
            segmentStart = segmentEnd
        }

        return segments
    }

    enum CompletionAction: Equatable {
        case continueFade(offset: Int)
        case finishChapter
    }

    /// A fade queue that ends before the chapter must enqueue another quiet
    /// continuation. Reaching the real text end follows ordinary chapter
    /// completion so the reader cannot remain logically active but silent.
    static func completionAction(queueEndOffset: Int, textUTF16Length: Int) -> CompletionAction {
        queueEndOffset < textUTF16Length
            ? .continueFade(offset: max(0, queueEndOffset))
            : .finishChapter
    }
}

/// Owns access to AVSpeechSynthesizer.write(), which is effectively a shared
/// macOS resource even when callers use different synthesizer instances.
/// Current-chapter and look-ahead renders must therefore never overlap, and
/// neither must the one-word renders that load a voice ahead of Play.
///
/// It holds its serial queue and, under a lock, the voices it has warmed up,
/// so the compiler checks that it is `Sendable`; state added later needs a
/// lock or an actor too.
final class SpeechRenderCoordinator: Sendable {
    static let shared = SpeechRenderCoordinator()
    static let maximumTextLength = 100_000

    private let queue = DispatchQueue(
        label: "com.textmouth.speech-render",
        qos: .userInitiated
    )

    /// The voices warmed up so far, by identifier, the system's default
    /// voice as the empty string; read and changed only under this lock.
    private let warmedVoices = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    /// Load `voice` into the system synthesizer ahead of the first Play, by
    /// rendering one word with it and dropping the audio (PERF03).
    func warmUp(_ voice: AVSpeechSynthesisVoice?) {
        warmUp(voice) { voice, finished in
            VoiceWarmUp.writeOneWord(in: voice, finished: finished)
        }
    }

    /// Warm `voice` up with `write`, which renders one word in a voice and
    /// calls its completion once, from any thread, with whether it finished;
    /// tests pass a stand-in.
    ///
    /// The process's first utterance in a voice waits while the synthesizer
    /// loads that voice: a session's first Play waited 3 to 4.5 s for its
    /// first word. A silent write() pays that once, after which a spoken
    /// utterance starts in about 15 ms. The write takes its turn on this
    /// queue like any render, so it never overlaps one, and each voice is
    /// warmed once, the first time it is asked for.
    func warmUp(
        _ voice: AVSpeechSynthesisVoice?,
        writing write: @escaping @MainActor @Sendable (AVSpeechSynthesisVoice?, @escaping @Sendable (Bool) -> Void) -> Void
    ) {
        let name = voice?.identifier ?? ""
        guard warmedVoices.withLock({ $0.insert(name).inserted }) else { return }
        enqueue(
            textLength: VoiceWarmUp.word.utf16Length,
            shouldStart: { true },
            start: { finished in write(voice, finished) },
            completion: { finished in
                DiagnosticLog.trace(
                    .playback,
                    "VOICE_WARM_UP: \(name.isEmpty ? "default voice" : name) \(finished ? "loaded" : "did not finish")"
                )
            }
        )
    }

    /// Render `request` into `engine` once every earlier render has finished.
    ///
    /// - Parameters:
    ///   - request: The text and voice to render; the engine records the
    ///     request's signature with the audio.
    ///   - engine: The engine that receives the audio.
    ///   - shouldStart: Asked on the main queue when the render reaches the
    ///     front of the queue, and again when it finishes. A render that is no
    ///     longer wanted never starts, and its completion reports false.
    ///   - completion: Called on the main queue with whether the render
    ///     succeeded and was still wanted when it finished.
    func render(
        _ request: SpeechRenderRequest,
        engine: AudioEngineService,
        shouldStart: @escaping @MainActor @Sendable () -> Bool,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        enqueue(
            textLength: request.text.utf16Length,
            shouldStart: shouldStart,
            start: { finish in
                engine.render(request, completion: finish)
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

/// Renders speech for the reader's look-ahead: the shared
/// `SpeechRenderCoordinator` in the app, and in tests a stand-in that holds
/// each render until the test lets it start and finish.
@MainActor
protocol SpeechRenderScheduling: AnyObject {
    /// Render `request` into `engine` when its turn comes, exactly as
    /// `SpeechRenderCoordinator.render(_:engine:shouldStart:completion:)`
    /// does.
    func render(
        _ request: SpeechRenderRequest,
        engine: AudioEngineService,
        shouldStart: @escaping @MainActor @Sendable () -> Bool,
        completion: @escaping @MainActor @Sendable (Bool) -> Void
    )

    /// Load `voice` into the system synthesizer ahead of the first Play, as
    /// `SpeechRenderCoordinator.warmUp(_:)` does.
    func warmUp(_ voice: AVSpeechSynthesisVoice?)
}

extension SpeechRenderScheduling {
    /// Warms nothing: a stand-in that renders nothing has no voice to load.
    func warmUp(_ voice: AVSpeechSynthesisVoice?) {}
}

extension SpeechRenderCoordinator: SpeechRenderScheduling {}

/// Renders one word in a voice and drops the audio, so that the system
/// synthesizer loads the voice before anything has to be spoken in it
/// (PERF03). `write()` never plays anything.
enum VoiceWarmUp {
    /// The word rendered: short, so that once the voice has loaded the
    /// render itself takes a moment.
    static let word = "Ready."

    /// How long a warm-up may hold the render queue before its turn ends
    /// anyway, so a voice that never answers cannot stop every later render.
    static let timeout: DispatchTimeInterval = .seconds(30)

    /// Render `word` in `voice` with a synthesizer of its own, dropping the
    /// audio, and call `finished` exactly once, from any thread: true when
    /// the synthesizer delivered its last buffer, false when `timeout`
    /// passed first.
    @MainActor
    static func writeOneWord(in voice: AVSpeechSynthesisVoice?, finished: @escaping @Sendable (Bool) -> Void) {
        let report = reportingOnce(finished)
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: word)
        utterance.voice = voice
        utterance.prefersAssistiveTechnologySettings = false
        synthesizer.write(utterance, toBufferCallback: lastBufferReporter(keepingAlive: synthesizer, report: report))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            report(false)
        }
    }

    /// The buffer callback of a warm-up's write: once the synthesizer
    /// delivers its last buffer, the empty one that ends its output, it
    /// reports the warm-up finished through `report`, and it holds
    /// `synthesizer` until then, so the synthesizer lives to deliver it.
    ///
    /// The callback is made here, outside the main actor, so that it is not
    /// isolated to it (board #732). The synthesizer calls it on a thread of
    /// its own choosing: the main thread so far, when `write` is called
    /// there (38 calls of 38), but nothing promises that. A callback made in
    /// main-actor code would be isolated to the main actor, which the Swift 6
    /// language mode checks as the callback begins, stopping the app on any
    /// other thread. This one touches nothing but `report`, which a lock
    /// makes safe on any thread (`reportingOnce`), and the synthesizer it
    /// keeps alive, so it may run on any thread.
    nonisolated static func lastBufferReporter(
        keepingAlive synthesizer: AVSpeechSynthesizer,
        report: @escaping @Sendable (Bool) -> Void
    ) -> AVSpeechSynthesizer.BufferCallback {
        { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength == 0 else { return }
            withExtendedLifetime(synthesizer) {
                report(true)
            }
        }
    }

    /// `finished`, made to run only the first time it is called: the last
    /// buffer and the timeout race to report one warm-up.
    static func reportingOnce(_ finished: @escaping @Sendable (Bool) -> Void) -> @Sendable (Bool) -> Void {
        let reported = OSAllocatedUnfairLock(initialState: false)
        return { succeeded in
            let isFirst = reported.withLock { alreadyReported in
                defer { alreadyReported = true }
                return !alreadyReported
            }
            if isFirst {
                finished(succeeded)
            }
        }
    }
}

/// Manages TTS playback using two modes:
/// 1. **Audio Engine mode** (default): Pre-renders speech with AVSpeechSynthesizer.write(),
///    plays through AVAudioEngine + AVAudioUnitTimePitch for real-time speed changes and instant seeking.
/// 2. **Direct mode** (fallback): Uses AVSpeechSynthesizer.speak() directly with word-by-word callbacks.
///
/// `@unchecked Sendable`: everything it holds is read and changed on the
/// main thread, where its owner, the main-actor reader, calls it. The
/// synthesizer's callbacks hand their work to the main queue without
/// reading any of it (see the delegate extension), its timers run on the
/// main run loop, and the position queue works only on a copy of the text.
final class SpeechService: NSObject, ObservableObject, @unchecked Sendable {
    /// The engine that renders speech and plays the rendered audio, made the
    /// first time speech needs one: its first render, or the first chapter
    /// it plays from audio rendered ahead (PERF08). The first engine of a
    /// session cost 142 ms, and 2.5 s with the audio system cold, which every
    /// reader paid as it opened, even an audiobook's, which never speaks a
    /// chapter. Nil until then: whatever only asks about the engine reads
    /// this, and never makes one.
    private var madeAudioEngine: AudioEngineService?

    /// The speech engine, made now if speech has not needed one yet. Only
    /// what needs an engine reads this: a render, rendered playback, and the
    /// tests.
    var audioEngine: AudioEngineService {
        if let madeAudioEngine { return madeAudioEngine }
        let engine = AudioEngineService()
        engine.onPlaybackFinished = { [weak self] in
            self?.handleEngineFinished()
        }
        madeAudioEngine = engine
        return engine
    }

    /// Whether speech has made its engine yet (`audioEngine`).
    var hasAudioEngine: Bool {
        madeAudioEngine != nil
    }

    /// Fallback direct synthesizer. Replaced with a fresh one when the
    /// system cancels its live utterance on its own
    /// (`replaceDirectSynthesizer()`): after the speech engine refuses an
    /// utterance, the synthesizer that held it never speaks again.
    private var directSynth = AVSpeechSynthesizer()
    /// Whether speech comes straight from the synthesizer rather than from
    /// rendered audio. Readable outside this class so tests can tell which
    /// backend a seek or resume chose.
    private(set) var usingDirectMode = false

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

    /// Absolute offsets for the short utterances queued during a direct-mode
    /// sleep fade. AVFoundation reports ranges relative to each utterance, so
    /// callbacks need identity-based offsets to preserve the reader cursor.
    private var directFadeOffsets: [ObjectIdentifier: Int] = [:]
    private var directFadeLengths: [ObjectIdentifier: Int] = [:]
    private var directFadeFinalUtteranceID: ObjectIdentifier?
    private var isDirectSleepFadeActive = false
    private var directFadeStartOffset = 0
    private var directFadeContinuationDuration: TimeInterval = 0
    private var directFadeTerminalVolume: Float = 0

    @Published var isSpeaking = false
    @Published var isPaused = false
    @Published var currentWordRange: NSRange?
    @Published var currentVoice: AVSpeechSynthesisVoice?
    @Published var wordsPerMinute: Double = 200 {
        didSet {
            // This is a reader's effective speed. Only SettingsViewModel may
            // persist global defaults; per-book overrides must stay local.
            if !usingDirectMode, let engine = madeAudioEngine, engine.isPlaying {
                engine.setSpeed(wpm: wordsPerMinute)
            }
        }
    }
    /// Pitch multiplier (0.5 = half pitch, 1.0 = normal, 2.0 = double pitch)
    @Published var pitchMultiplier: Double = 1.0 {
        didSet {
            // Applying a book's pitch must not overwrite the global setting.
            if !usingDirectMode, let engine = madeAudioEngine, engine.isPlaying || engine.isPaused {
                engine.setPitch(multiplier: pitchMultiplier)
            }
        }
    }

    var onWordSpoken: ((NSRange, String) -> Void)?
    var onUtteranceFinished: (() -> Void)?
    /// Called on the main queue when speech ended because the Mac's speech
    /// engine refused its text on a fresh synthesizer too
    /// (`endDirectSpeechRefused(at:)`), after speech shows itself stopped
    /// at the cursor and the listener has heard
    /// `engineRefusedAnnouncement`. A reader may show playback stopped in
    /// turn; nothing else is needed, since Play speaks on from the cursor.
    var onSpeechRefused: (() -> Void)?

    /// The full text currently being spoken, kept after a stop for a later
    /// seek or resume until `releaseSpeech()`. Readable outside this class
    /// so tests can tell that it was let go.
    private(set) var currentText: String = ""

    /// Whether the engine holds audio rendered from exactly the text being
    /// spoken, in the voice chosen now.
    ///
    /// Direct speech switches to rendered audio, at a seek, a resume, the
    /// start of a sleep fade, or a recovery, only then. Any other audio is
    /// stale: rendered in the previous voice when a voice was chosen part-way
    /// through the text, or from another text when a render finished after
    /// it was abandoned. Speech then carries on directly in the current
    /// voice. Rendered audio already playing keeps playing until its text
    /// ends, since switching mid-playback is never seamless.
    private var renderedAudioMatchesSpeech: Bool {
        // Most direct speech has no rendered audio yet; skip hashing the text.
        guard let rendered = madeAudioEngine?.renderedSignature else { return false }
        return rendered == SpeechRenderSignature(text: currentText, voiceIdentifier: currentVoice?.identifier)
    }

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
    /// Where direct speech last spoke again from after the system cancelled
    /// its live utterance (`DIRECT_RETRY`), or nil when it has not since
    /// speech was last stopped. A cancel that comes back to the same offset
    /// means the engine refuses the text there on a fresh synthesizer too:
    /// speech then ends (`endDirectSpeechRefused(at:)`) instead of trying
    /// forever.
    private var lastDirectRetryOffset: Int?
    /// The part of the text being spoken, in its UTF-16 offsets, that direct
    /// speech hands the synthesizer strictly guarded, every bracket silent
    /// (`SpeechMarkupGuard.neutralizedStrictly(_:)`): the rest of the last
    /// chunk the engine refused, from where it is spoken again to the
    /// chunk's end. Nil when nothing was refused since speech last stopped.
    /// Every other part goes through the default guard, which leaves a lone
    /// "less than" to be spoken. Kept until speech stops, so that the same
    /// passage spoken again, after a seek back, is not refused again.
    private var strictlyGuardedRange: Range<Int>?
    /// The chunk handed to the synthesizer to follow the one speaking, so
    /// it goes straight on; nil when none is queued. It becomes the one
    /// speaking when the one before it ends, or when it starts, whichever
    /// the main queue hears first.
    private var queuedDirectChunk: QueuedDirectChunk?
    /// Most UTF-16 units direct speech hands the synthesizer first, at Play,
    /// a seek, a skip, or a restart: the synthesizer reads a whole utterance
    /// before its first word, which took 111 ms at 5,000 units and 66 ms at
    /// 1,000 (PERF06).
    static let directModeFirstChunkSize = 1_000
    /// Most UTF-16 units of each later chunk, queued while the one before it
    /// speaks, so its length delays nothing. Keeps the utterances few while
    /// providing enough audio buffer for the engine to render in the
    /// background.
    static let directModeChunkSize = 5_000
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

    /// Records a playback-mode transition in speech's own log
    /// (`DiagnosticLog.File.speechTransitions`). An anomaly, such as a
    /// failed render or resume, a watchdog recovery, or an unexpected
    /// cancellation, is an event and always written; the routine start and
    /// finish of chunks, renders, and mode switches are trace, written only
    /// while tracing is on. Lines hold offsets and lengths, never the text.
    private func transitionLog(_ level: DiagnosticLog.Level, _ message: @autoclosure () -> String) {
        DiagnosticLog.log(level, .playback, message(), in: .speechTransitions)
    }

    /// Preferences store holding the global speed, pitch, and voice. The app
    /// uses the standard defaults; tests inject an isolated suite.
    private let userDefaults: UserDefaults

    /// Reads the global speech defaults from the app's standard preferences.
    override convenience init() {
        self.init(userDefaults: .standard)
    }

    /// - Parameter userDefaults: Store holding the global speed, pitch, and voice.
    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
        super.init()
        directSynth.delegate = self

        // Read speed and pitch through the settings policy, so a value
        // stored with `defaults write` is clamped exactly as the Settings
        // window shows it instead of reaching the speech engine raw.
        wordsPerMinute = SettingsPolicy.wordsPerMinute.storedValue(in: userDefaults)
        pitchMultiplier = SettingsPolicy.pitchMultiplier.storedValue(in: userDefaults)

        let savedVoiceID = userDefaults.string(forKey: "selectedVoiceID")
        if let voiceID = savedVoiceID {
            currentVoice = AVSpeechSynthesisVoice(identifier: voiceID)
        }
        if currentVoice == nil {
            currentVoice = AVSpeechSynthesisVoice(language: "en-US")
        }

        NotificationCenter.default.publisher(for: .speechSettingsChanged)
            .sink { [weak self] _ in self?.reloadSettings() }
            .store(in: &settingsCancellables)
    }

    /// Re-reads the global speech defaults after Settings changes them,
    /// validated the same way as at launch.
    func reloadSettings() {
        let savedWPM = SettingsPolicy.wordsPerMinute.storedValue(in: userDefaults)
        if savedWPM != wordsPerMinute {
            wordsPerMinute = savedWPM
        }

        let savedPitch = SettingsPolicy.pitchMultiplier.storedValue(in: userDefaults)
        if savedPitch != pitchMultiplier {
            pitchMultiplier = savedPitch
        }

        let savedVoiceID = userDefaults.string(forKey: "selectedVoiceID")
        if let voiceID = savedVoiceID, voiceID != currentVoice?.identifier {
            if let newVoice = AVSpeechSynthesisVoice(identifier: voiceID) {
                currentVoice = newVoice
            }
        }
    }

    // MARK: - Voice Management

    // The voices offered are listed once and shared by `VoiceCatalog`
    // (TODO PERF07), never here.

    func selectVoice(_ voice: AVSpeechSynthesisVoice) {
        currentVoice = voice
        userDefaults.set(voice.identifier, forKey: "selectedVoiceID")
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
        if madeAudioEngine?.discardRenderedAudio() == true {
            transitionLog(.trace, "RENDER_DISCARD: removed previous text's rendered audio before starting new direct speech")
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
            transitionLog(.trace, "RENDER_SKIP: text too large (\(text.utf16Length) UTF-16 units > \(SpeechRenderCoordinator.maximumTextLength)), staying in direct mode")
            return
        }

        // Pre-render in background so engine is ready for seeks, pauses, or next chapter.
        // We do NOT switch mid-playback — direct mode runs until a natural break.
        SpeechRenderCoordinator.shared.render(
            SpeechRenderRequest(text: text, voice: currentVoice),
            engine: audioEngine,
            shouldStart: { [weak self] in self?.renderGeneration == myGeneration },
            completion: { [weak self] success in
            guard let self = self else { return }
            guard self.renderGeneration == myGeneration else { return }

            if success {
                self.transitionLog(.trace, "RENDER_READY: engine rendered \(text.utf16Length) UTF-16 units, direct mode still active=\(self.usingDirectMode)")
            } else {
                self.transitionLog(.event, "RENDER_FAILED: engine render failed, staying in direct mode")
            }
            // Engine is now ready. While its audio still matches this text
            // in the current voice (renderedAudioMatchesSpeech), it is used when:
            // - User seeks (seek() switches to engine)
            // - User pauses then resumes (resume() switches to engine)
            // - A sleep fade starts, or the direct-speech watchdog recovers
            }
        )
    }

    /// Speak `text` directly from `charOffset`, starting with a short chunk
    /// so the first word comes quickly; each later chunk is queued as the
    /// one before it starts (`queueNextDirectChunk()`).
    private func speakDirect(_ text: String, fromCharOffset charOffset: Int) {
        usingDirectMode = true
        let chunk = DirectSpeechChunk.starting(
            at: charOffset,
            in: text,
            maximumLength: Self.directModeFirstChunkSize
        )
        directModeBaseOffset = chunk.start
        directModeChunkEnd = chunk.end
        directModeChunked = chunk.isPartial
        if chunk.isPartial {
            transitionLog(.trace, "CHUNK_START: offset=\(chunk.start) len=\(chunk.end - chunk.start) end=\(chunk.end) totalText=\(text.utf16Length)")
        }

        let utterance = makeDirectUtterance(speaking: chunk.words(of: text), at: chunk.start)
        // Mark this utterance as live BEFORE handing it to the synth.
        // The didFinish delegate compares against `liveDirectUtterance`
        // to filter callbacks for previously-stopped utterances.
        liveDirectUtterance = utterance
        handToSynthesizer(utterance)
    }

    /// Hand the synthesizer the chunk after the one that just started, so
    /// it goes straight on when that one ends (PERF06). Starting a chunk only
    /// once the end of the one before had reached the main queue kept the
    /// synthesizer waiting on the main thread at every boundary, often
    /// mid-sentence, for as long as the main thread was busy; queued, the
    /// next chunk follows after the synthesizer's own pause between
    /// utterances. Nothing is queued after the last chunk, or a second time,
    /// or during a sleep fade, which queues its own segments.
    private func queueNextDirectChunk() {
        guard usingDirectMode, directModeChunked, queuedDirectChunk == nil, !isDirectSleepFadeActive,
              directModeChunkEnd < currentText.utf16Length else { return }
        let chunk = DirectSpeechChunk.starting(
            at: directModeChunkEnd,
            in: currentText,
            maximumLength: Self.directModeChunkSize
        )
        let utterance = makeDirectUtterance(speaking: chunk.words(of: currentText), at: chunk.start)
        queuedDirectChunk = QueuedDirectChunk(utterance: utterance, chunk: chunk)
        transitionLog(.trace, "CHUNK_QUEUED: offset=\(chunk.start) len=\(chunk.end - chunk.start) end=\(chunk.end)")
        handToSynthesizer(utterance)
    }

    /// Make the queued chunk the one speaking: the synthesizer has gone on
    /// to it, so its words, its end, and its finish are the ones that count.
    private func promoteQueuedDirectChunk() {
        guard let queued = queuedDirectChunk else { return }
        queuedDirectChunk = nil
        liveDirectUtterance = queued.utterance
        directModeBaseOffset = queued.chunk.start
        directModeChunkEnd = queued.chunk.end
        directModeChunked = queued.chunk.isPartial
    }

    /// A chunk handed to the synthesizer to follow the one speaking.
    private struct QueuedDirectChunk {
        /// The utterance speaking it, told apart from every other by identity.
        let utterance: AVSpeechUtterance
        /// Where it lies in the text being spoken.
        let chunk: DirectSpeechChunk
    }

    /// An utterance of `text`, the part of the text being spoken that
    /// begins at UTF-16 offset `offset`, in the voice, speed, and pitch
    /// chosen now. The synthesizer is handed `text` with its tag-shaped runs
    /// made harmless (`SpeechMarkupGuard`), and every bracket of its part in
    /// `strictlyGuardedRange` too, at exactly the text's length, so a range
    /// it reports for the utterance is a range of `text`, and the chunk's
    /// place in the whole text counts as before.
    private func makeDirectUtterance(speaking text: String, at offset: Int) -> AVSpeechUtterance {
        let guarded = strictlyGuardedRange.map { strict in
            // The strict part in the utterance's own offsets; the guard
            // ignores whatever of it lies outside the utterance.
            SpeechMarkupGuard.neutralized(text, strictlyWithin: (strict.lowerBound - offset)..<(strict.upperBound - offset))
        } ?? SpeechMarkupGuard.neutralized(text)
        let utterance = AVSpeechUtterance(string: guarded)
        utterance.voice = currentVoice
        utterance.rate = Self.rateForWPM(wordsPerMinute)
        utterance.pitchMultiplier = Float(Self.clampedPitch(pitchMultiplier))
        utterance.prefersAssistiveTechnologySettings = false
        return utterance
    }

    /// Hand `utterance` to the direct synthesizer, which speaks it after
    /// any it is speaking already; in tests, to the recorder standing in for
    /// the synthesizer (`_directUtteranceRecorderForTesting`).
    private func handToSynthesizer(_ utterance: AVSpeechUtterance) {
        if let record = _directUtteranceRecorderForTesting {
            record(utterance)
        } else {
            directSynth.speak(utterance)
        }
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
    /// a usable finish callback. Prefer rendered audio of this speech when
    /// available. Without it, continue a nearly-complete chunk at its known
    /// boundary; otherwise restart at the last reported word so content is
    /// not skipped.
    private func recoverFromIdleDirectSynthesizer(watchedUtteranceID: ObjectIdentifier) {
        guard liveDirectUtterance.map(ObjectIdentifier.init) == watchedUtteranceID,
              usingDirectMode,
              isSpeaking,
              !isPaused else {
            transitionLog(.trace, "DIRECT_WATCHDOG_CANCELLED: playback state changed before recovery")
            return
        }

        let reportedOffset = currentWordRange?.location ?? directModeBaseOffset
        let safeOffset = max(0, min(reportedOffset, currentText.utf16Length))
        if renderedAudioMatchesSpeech {
            transitionLog(.event, "DIRECT_WATCHDOG_RECOVERY: synthesizer idle without usable didFinish; switching to rendered audio at offset=\(safeOffset) chunkEnd=\(directModeChunkEnd)")
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
                transitionLog(.event, "DIRECT_WATCHDOG_ENGINE_FAILED: rendered audio did not start; restarting direct speech at offset=\(safeOffset)")
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
            transitionLog(.event, "DIRECT_WATCHDOG_RECOVERY: synthesizer idle near chunk end; continuing at offset=\(nextOffset) lastReportedOffset=\(safeOffset)")
            stopDirectSynthesizer()
            speakDirect(currentText, fromCharOffset: nextOffset)
            return
        }

        transitionLog(.event, "DIRECT_WATCHDOG_RECOVERY: synthesizer idle before confirmed finish; restarting direct speech at offset=\(safeOffset) chunkEnd=\(directModeChunkEnd)")
        stopDirectSynthesizer()
        speakDirect(currentText, fromCharOffset: safeOffset)
    }

    // MARK: - Recovery after the system cancels the live utterance

    /// What the listener hears when the Mac's speech engine refused the
    /// text twice, on a fresh synthesizer too, and speech ended where it
    /// was (`endDirectSpeechRefused(at:)`). Play speaks on from there.
    nonisolated static let engineRefusedAnnouncement = "Speech stopped: the Mac's speech engine refused this text."

    /// Speak again after the system cancelled the live utterance on its own
    /// (`DIRECT_CANCEL_UNEXPECTED`), as it does when the speech engine
    /// refuses a text it reads as broken markup (`SpeechMarkupGuard`): the
    /// refused utterance never starts, so the watchdog, which its start
    /// would arm, never looks, and the synthesizer that refused it never
    /// speaks again, so speaking again on it would be silent too.
    ///
    /// A fresh synthesizer takes its place first, whatever follows
    /// (`DIRECT_SYNTH_REPLACED`): kept, the one that refused would take the
    /// next Play too, and speak it into silence while speech showed itself
    /// speaking, which is how the reading stopped and could not restart on
    /// October 7. The fresh one speaks the cancelled chunk again from where
    /// it was cancelled (`DIRECT_RETRY`), and strictly guarded to the
    /// chunk's end (`strictlyGuardedRange`): the default guard had already
    /// passed this text, so only every bracket made silent keeps a shape it
    /// misses from being refused twice. A lone "less than" there is then
    /// not spoken, which is the price of hearing the rest; the chunks after
    /// it go back to the default guard. Once per place: a cancel that
    /// comes back to the same offset means the engine refuses this text on
    /// any synthesizer, even with no bracket in it, and speech ends there
    /// instead (`endDirectSpeechRefused(at:)`), as it does when there is no
    /// text to speak again.
    private func recoverFromCancelledDirectUtterance() {
        let offset = directRetryOffset()
        let refusedChunkEnd = directModeChunkEnd
        replaceDirectSynthesizer()
        guard !currentText.isEmpty, lastDirectRetryOffset != offset else {
            endDirectSpeechRefused(at: offset)
            return
        }
        lastDirectRetryOffset = offset
        strictlyGuardedRange = offset..<max(offset, refusedChunkEnd)
        transitionLog(.event, "DIRECT_RETRY offset=\(offset) chunkStart=\(directModeBaseOffset) chunkEnd=\(refusedChunkEnd); strictly guarded to the chunk's end")
        speakDirect(currentText, fromCharOffset: offset)
    }

    /// Where to speak again after the live chunk was cancelled: its last
    /// reported word, when one was reported within the chunk, so that
    /// nothing heard is heard twice; else the chunk's start, since a chunk
    /// the engine refused never said a word, and a word reported before it
    /// belongs to the chunk before it.
    private func directRetryOffset() -> Int {
        let chunkStart = directModeBaseOffset
        guard let reported = currentWordRange?.location,
              reported >= chunkStart, reported < directModeChunkEnd else {
            return chunkStart
        }
        return reported
    }

    /// Replace the direct synthesizer with a fresh one, the old one stopped
    /// and let go with whatever it still held (`stopDirectSynthesizer()`):
    /// after the engine refuses an utterance, the synthesizer that held it
    /// never speaks again (a plain text on it waited 10 s for nothing,
    /// while a fresh instance spoke it at once).
    private func replaceDirectSynthesizer() {
        stopDirectSynthesizer()
        directSynth.delegate = nil
        directSynth = AVSpeechSynthesizer()
        directSynth.delegate = self
        transitionLog(.event, "DIRECT_SYNTH_REPLACED: fresh synthesizer after the system cancelled the live utterance")
    }

    /// End direct speech at `offset` because the engine refused its text on
    /// a fresh synthesizer too (`DIRECT_RETRY_FAILED`). Speech shows itself
    /// stopped, not paused, and keeps its text and the cursor at `offset`,
    /// so that Play speaks on from there, as the reader restarts stopped
    /// speech from its cursor, and the chapter neither ends nor moves on.
    /// The listener hears `engineRefusedAnnouncement`, and the reader is
    /// told (`onSpeechRefused`).
    ///
    /// The caller has already let go of the synthesizer that refused, and
    /// of what it held (`replaceDirectSynthesizer()`), so that Play speaks
    /// on a synthesizer that can still speak.
    private func endDirectSpeechRefused(at offset: Int) {
        transitionLog(.event, "DIRECT_RETRY_FAILED: offset=\(offset) chunkStart=\(directModeBaseOffset) chunkEnd=\(directModeChunkEnd); speech stopped, the listener told")
        stopPositionTracking()
        isSpeaking = false
        isPaused = false
        usingDirectMode = false
        directModeChunked = false
        pendingDirectSeekOffset = nil
        lastDirectRetryOffset = nil
        // The cursor stays where speech stopped, for the reader too, as a
        // seek leaves it.
        let range = NSRange(location: offset, length: 0)
        currentWordRange = range
        onWordSpoken?(range, "")
        // The synthesizer's callbacks reach this service on the main queue,
        // where announcements are made.
        MainActor.assumeIsolated {
            VoiceOverAnnouncer.announce(Self.engineRefusedAnnouncement)
        }
        onSpeechRefused?()
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
        // Stopping the synthesizer drops the chunk queued behind the live
        // one too; any callback for it is then for no chunk at all.
        queuedDirectChunk = nil
        clearDirectSleepFadeState()
        directSynth.stopSpeaking(at: .immediate)
    }

    /// Clear bookkeeping for a direct-speech fade. This does not alter the
    /// synthesizer by itself and is safe from every stop and recovery path.
    private func clearDirectSleepFadeState() {
        directFadeOffsets.removeAll(keepingCapacity: false)
        directFadeLengths.removeAll(keepingCapacity: false)
        directFadeFinalUtteranceID = nil
        isDirectSleepFadeActive = false
        directFadeStartOffset = 0
        directFadeContinuationDuration = 0
        directFadeTerminalVolume = 0
    }

    /// Apply a sleep timer volume update to whichever speech backend is
    /// actually audible. Rendered playback supports mixer updates directly.
    /// Direct synthesis is switched to rendered audio of this speech when
    /// available; otherwise, as for very large chapters, it fades through
    /// pre-volume-adjusted utterance segments.
    func setSleepTimerFadeVolume(_ volume: Float, duration: TimeInterval) {
        guard isSpeaking, !isPaused else { return }

        if usingDirectMode && !isDirectSleepFadeActive {
            let offset = max(
                0,
                min(currentWordRange?.location ?? directModeBaseOffset, currentText.utf16Length)
            )

            if renderedAudioMatchesSpeech {
                transitionLog(.trace, "SLEEP_FADE_SWITCH: direct→engine at offset=\(offset)")
                stopDirectSynthesizer()
                usingDirectMode = false
                audioEngine.setSpeed(wpm: wordsPerMinute)
                audioEngine.setPitch(multiplier: pitchMultiplier)
                audioEngine.play(fromCharOffset: offset)
                if audioEngine.isPlaying {
                    startPositionTracking()
                } else {
                    // Preserve an audible fade when a retained render cannot
                    // restart, for example after a device-route transition.
                    transitionLog(.event, "SLEEP_FADE_ENGINE_FAILED: using direct utterance fade at offset=\(offset)")
                    audioEngine.stop()
                    prepareDirectSleepFade(
                        fromUTF16Offset: offset,
                        duration: duration * Double(max(0, volume)),
                        startingVolume: volume
                    )
                }
            } else {
                prepareDirectSleepFade(
                    fromUTF16Offset: offset,
                    duration: duration * Double(max(0, volume)),
                    startingVolume: volume
                )
            }
        }

        if !usingDirectMode {
            madeAudioEngine?.setVolume(volume)
        }
    }

    /// Replace the current direct utterance with a bounded queue whose volume
    /// decreases segment by segment. The queue deliberately contains slightly
    /// more speech than the timer should need; expiry always stops it at the
    /// exact wall-clock deadline.
    private func prepareDirectSleepFade(
        fromUTF16Offset offset: Int,
        duration: TimeInterval,
        startingVolume: Float
    ) {
        let segments = DirectSpeechFadePlanner.segments(
            in: currentText,
            fromUTF16Offset: offset,
            duration: duration,
            wordsPerMinute: wordsPerMinute,
            startingVolume: startingVolume
        )
        guard !segments.isEmpty else { return }

        stopDirectSynthesizer()
        usingDirectMode = true
        directModeChunked = false
        directModeBaseOffset = segments[0].baseUTF16Offset
        directModeChunkEnd = segments.last?.endUTF16Offset ?? offset
        directFadeStartOffset = segments[0].baseUTF16Offset
        directFadeContinuationDuration = duration
        directFadeTerminalVolume = segments.last?.volume ?? startingVolume
        isDirectSleepFadeActive = true

        let utterances = segments.map { segment -> AVSpeechUtterance in
            let utterance = makeDirectUtterance(speaking: segment.text, at: segment.baseUTF16Offset)
            utterance.volume = segment.volume
            let identifier = ObjectIdentifier(utterance)
            directFadeOffsets[identifier] = segment.baseUTF16Offset
            directFadeLengths[identifier] = segment.text.utf16Length
            return utterance
        }
        guard let finalUtterance = utterances.last else { return }
        directFadeFinalUtteranceID = ObjectIdentifier(finalUtterance)
        // Keep a strong reference to the final queued utterance so resume
        // policy sees a live direct session until the fade is stopped.
        liveDirectUtterance = finalUtterance
        transitionLog(
            .trace,
            "SLEEP_FADE_DIRECT_STARTED: offset=\(directFadeStartOffset) segments=\(utterances.count) "
                + "plannedEnd=\(directModeChunkEnd) duration=\(duration)"
        )
        for utterance in utterances {
            handToSynthesizer(utterance)
        }
    }

    /// Restore normal-volume direct speech when a running fade is cancelled.
    /// Rendered playback only needs its mixer volume restored.
    func cancelSleepTimerFade() {
        madeAudioEngine?.restoreVolume()
        guard isDirectSleepFadeActive else { return }

        let offset = max(
            directFadeStartOffset,
            min(currentWordRange?.location ?? directFadeStartOffset, currentText.utf16Length)
        )
        let shouldRestart = isSpeaking && !isPaused
        transitionLog(.trace, "SLEEP_FADE_CANCELLED: offset=\(offset) restart=\(shouldRestart)")
        stopDirectSynthesizer()
        if shouldRestart {
            speakDirect(currentText, fromCharOffset: offset)
        }
    }

    /// Stop a queued direct fade while retaining the latest confirmed reader
    /// position. Returns true when this method owned the active backend.
    @discardableResult
    private func stopDirectSleepFadePreservingPosition() -> Bool {
        guard isDirectSleepFadeActive else { return false }
        let offset = max(
            directFadeStartOffset,
            min(currentWordRange?.location ?? directFadeStartOffset, currentText.utf16Length)
        )
        stopDirectSynthesizer()
        currentWordRange = NSRange(location: offset, length: 0)
        usingDirectMode = true
        return true
    }

    func pause() {
        guard isSpeaking && !isPaused else { return }
        if stopDirectSleepFadePreservingPosition() {
            // The helper stopped the fade queue and retained direct mode so a
            // later resume recreates normal-volume speech at this cursor.
        } else if usingDirectMode {
            directSynth.pauseSpeaking(at: .immediate)
        } else if let engine = madeAudioEngine, engine.isPlaying {
            engine.pause()
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
            madeAudioEngine?.restoreVolume()
        }

        guard isSpeaking && !isPaused else { return }

        if stopDirectSleepFadePreservingPosition() {
            // The helper stopped the fade queue before engine volume is reset.
        } else if usingDirectMode {
            directSynth.pauseSpeaking(at: .immediate)
        } else if let engine = madeAudioEngine, engine.isPlaying || engine.isPaused {
            let offset = engine.stopAfterFadePreservingPosition()
            currentWordRange = NSRange(location: offset, length: 0)
        }

        isPaused = true
        stopPositionTracking()
    }

    /// Resumes a paused backend and reports whether an audible path was
    /// accepted. Callers can cold-start the chapter when false is returned
    /// instead of publishing a false "playing" state.
    @discardableResult
    func resume() -> Bool {
        guard isPaused else { return false }

        let offset = currentWordRange?.location ?? madeAudioEngine?.currentCharOffset() ?? 0
        let action = SpeechResumePolicy.action(
            usingDirectMode: usingDirectMode,
            pendingDirectSeekOffset: pendingDirectSeekOffset,
            // Only audio of this speech, in the current voice, counts: stale
            // audio is never switched to. A paused engine resumes its own
            // audio whatever this says.
            engineHasRenderedAudio: renderedAudioMatchesSpeech,
            engineIsPaused: madeAudioEngine?.isPaused ?? false,
            engineIsPlaying: madeAudioEngine?.isPlaying ?? false,
            directSynthIsPaused: directSynth.isPaused,
            currentOffset: offset,
            hasText: !currentText.isEmpty
        )
        pendingDirectSeekOffset = nil

        var resumed: Bool
        switch action {
        case .switchToEngine(let resumeOffset), .startRenderedEngine(let resumeOffset):
            transitionLog(.trace, "RESUME_SWITCH: starting rendered engine at offset=\(resumeOffset)")
            stopDirectSynthesizer()
            usingDirectMode = false
            audioEngine.setSpeed(wpm: wordsPerMinute)
            audioEngine.setPitch(multiplier: pitchMultiplier)
            audioEngine.play(fromCharOffset: resumeOffset)
            resumed = audioEngine.isPlaying
            if resumed {
                startPositionTracking()
            }

        case .resumeEngine(let resumeOffset):
            // The Mac may have stopped AVAudioEngine while sleeping. The
            // audio service restarts it before asking the player node to
            // continue. If restart fails, restart direct speech below.
            resumed = audioEngine.resume()
            if resumed {
                transitionLog(.trace, "ENGINE_RESUME: resumed at offset=\(resumeOffset)")
                startPositionTracking()
            } else {
                transitionLog(
                    .event,
                    "ENGINE_RESUME_FAILED: falling back to direct speech at offset=\(resumeOffset)"
                )
                audioEngine.stop()
                resumed = restartDirectSpeech(at: resumeOffset)
            }

        case .continueDirect(let resumeOffset):
            if directSynth.continueSpeaking() {
                resumed = true
            } else {
                transitionLog(
                    .event,
                    "DIRECT_RESUME_FAILED: restarting utterance at offset=\(resumeOffset)"
                )
                resumed = restartDirectSpeech(at: resumeOffset)
            }

        case .restartDirect(let resumeOffset):
            transitionLog(.trace, "DIRECT_RESUME_RECOVERY: restarting utterance at offset=\(resumeOffset)")
            resumed = restartDirectSpeech(at: resumeOffset)

        case .alreadyPlaying:
            resumed = true

        case .unavailable:
            transitionLog(.event, "RESUME_UNAVAILABLE: no rendered audio, live utterance, or text")
            resumed = false
        }

        isPaused = !resumed
        if resumed {
            isSpeaking = true
        }
        return resumed
    }

    /// Recreates direct speech after AVFoundation loses the paused utterance.
    /// The live-utterance marker provides a synchronous acceptance signal.
    private func restartDirectSpeech(at offset: Int) -> Bool {
        guard !currentText.isEmpty else { return false }
        stopDirectSynthesizer()
        speakDirect(currentText, fromCharOffset: offset)
        return liveDirectUtterance != nil
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
        madeAudioEngine?.cancelRender()
        madeAudioEngine?.stop()
        isSpeaking = false
        isPaused = false
        currentWordRange = nil
        usingDirectMode = false
        directModeBaseOffset = 0
        directModeChunked = false
        directModeChunkEnd = 0
        pendingDirectSeekOffset = nil
        lastDirectRetryOffset = nil
        strictlyGuardedRange = nil
        stopPositionTracking()
    }

    var isActive: Bool {
        return isSpeaking || isPaused
    }

    /// Restore the speech engine's full volume after a sleep-timer fade;
    /// speech that never made an engine has no volume to restore.
    func restoreEngineVolume() {
        madeAudioEngine?.restoreVolume()
    }

    /// Stop, then let go of what a stopped speech service keeps for a later
    /// seek or resume: the text it was speaking and the engine's rendered
    /// audio, without making an engine to do it. For a reader that has
    /// closed, whose window SwiftUI may keep alive (PERF27).
    func releaseSpeech() {
        stop()
        currentText = ""
        madeAudioEngine?.discardRenderedAudio()
    }

    /// Start playback using a pre-rendered AudioEngineService (for seamless chapter transitions).
    /// Swaps the pre-rendered engine in and starts playing immediately — no direct mode, no rendering delay.
    /// The caller has checked that `preEngine` holds audio rendered from exactly
    /// `text` in the current voice (see `ReaderViewModel.takeLookAheadEngine(for:)`);
    /// its signature comes along, so later seeks and resumes can check it too.
    func usePreRenderedEngine(_ preEngine: AudioEngineService, text: String, fromCharOffset charOffset: Int = 0) {
        stop()
        currentText = text
        renderGeneration += 1

        // Move the pre-rendered engine's audio into this service's engine,
        // which is made now if speech has not needed one before, and which
        // keeps its own volume, speed, and pitch.
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

        transitionLog(.trace, "PRE_RENDERED_START: playing chapter (\(text.utf16Length) UTF-16 units) from offset \(charOffset)")
    }

    // MARK: - Seeking

    /// Seek to a character offset within the current text.
    /// Rendered audio already playing seeks within itself. Direct speech
    /// switches to rendered audio of this speech, in the current voice, for
    /// instant seeking once it is ready, and otherwise restarts direct speech
    /// from the new offset.
    func seek(toCharOffset offset: Int) {
        // Bump the position-tracking generation so any in-flight 100ms
        // polling dispatch (offset captured pre-seek, word extraction
        // running on the background queue) is dropped on its way back
        // to main and doesn't overwrite the now-correct position.
        positionGeneration += 1

        if usingDirectMode {
            // Direct speech stops either way. stopDirectSynthesizer() clears
            // the live-utterance marker so the OLD utterance's didFinish (if
            // it fires after speakDirect assigns a new live utterance) is
            // correctly seen as stale. Paused, the move waits for resume,
            // which then chooses how to continue.
            stopDirectSynthesizer()
            if isPaused {
                pendingDirectSeekOffset = offset
            } else if renderedAudioMatchesSpeech {
                transitionLog(.trace, "SEEK_SWITCH: direct→engine at offset=\(offset)")
                usingDirectMode = false
                audioEngine.setSpeed(wpm: wordsPerMinute)
                audioEngine.setPitch(multiplier: pitchMultiplier)
                audioEngine.play(fromCharOffset: offset)
                startPositionTracking()
            } else {
                // No rendered audio of this speech yet, or only audio from
                // before the voice changed: restart direct speech here.
                speakDirect(currentText, fromCharOffset: offset)
            }
        } else if let engine = madeAudioEngine, engine.hasRenderedAudio {
            // Rendered audio is the backend already: seek within it.
            engine.seek(toCharOffset: offset)
            if engine.isPlaying {
                startPositionTracking()
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
        return madeAudioEngine?.currentCharOffset() ?? 0
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
            guard let self = self, !self.usingDirectMode, let engine = self.madeAudioEngine,
                  engine.isPlaying || engine.isPaused else { return }
            // currentCharOffset() reads the audio node's render time,
            // which is safe from the main thread (the timer's thread)
            let offset = engine.currentCharOffset()
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
        transitionLog(.trace, "ENGINE_FINISHED: audio fully played back, advancing chapter")
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

    // MARK: - Test Support

    /// Makes `utterance` the live direct utterance, as `speakDirect` does
    /// just before it hands one to the synthesizer, without handing it over,
    /// so hosted tests can deliver the synthesizer's callbacks for it, and
    /// for utterances that are not live, without a sound. Speech counts as
    /// direct, and the ranges the synthesizer reports for `utterance` count
    /// from `baseOffset`. The text being spoken is left as it was, empty for
    /// a new service, so even a recovery by the direct-speech watchdog,
    /// which a started utterance arms, would speak nothing.
    func _adoptLiveDirectUtteranceForTesting(_ utterance: AVSpeechUtterance, baseOffset: Int = 0) {
        usingDirectMode = true
        directModeBaseOffset = baseOffset
        liveDirectUtterance = utterance
    }

    /// Takes every utterance direct speech would hand the synthesizer, in
    /// its place, so hosted tests can follow the chunks speech is made of and
    /// deliver the synthesizer's callbacks for them without a sound. Nil, as
    /// in the app, hands them to the synthesizer.
    var _directUtteranceRecorderForTesting: ((AVSpeechUtterance) -> Void)?

    /// The synthesizer direct speech hands its utterances to now, so hosted
    /// tests can see it replaced after the system cancelled an utterance.
    var _directSynthesizerForTesting: AVSpeechSynthesizer { directSynth }

    deinit {
        stop()
    }
}

// MARK: - AVSpeechSynthesizerDelegate (direct mode fallback)

/// The synthesizer's callbacks are handled on the main queue. AVFoundation
/// does not say which thread it calls them on, so a callback reads nothing
/// of this service's state where it is called: it only queues its work for
/// the main queue, which alone reads and changes that state. Two rules keep
/// what reaches the main queue `Sendable`: each callback hands its utterance
/// over as a `ReportedUtterance`, and the main queue reads the synthesizer's
/// state from `directSynth`, the one synthesizer this service is the
/// delegate of, never from the callback's own `synthesizer`.
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
        // Held for the main queue (`ReportedUtterance`), which decides what
        // the word means (`placeSpokenWord(at:of:)`).
        let spoken = ReportedUtterance(utterance: utterance)
        DispatchQueue.main.async { [weak self] in
            self?.placeSpokenWord(at: characterRange, of: spoken)
        }
    }

    /// Move the cursor to the word the synthesizer said it will speak,
    /// `characterRange` of `spoken`'s text, at the word's place in the whole
    /// text. Runs on the main queue, where everything this decides by is
    /// read and changed: whether speech is direct, which utterance is live,
    /// the segments of a sleep fade, and the offsets their ranges count from.
    ///
    /// Only a word of the live utterance, or of a segment of the sleep fade
    /// under way, moves the cursor. A word of any other utterance is the
    /// tail of an internal stopSpeaking (a mode switch, a seek, a new
    /// chunk), as a finish of one is (see `didFinish`): its range counts
    /// from the start of the old utterance, and combining it with the offset
    /// of the new one would put the cursor somewhere unrelated, which made
    /// seeks seem to jump to a random place.
    private func placeSpokenWord(at characterRange: NSRange, of spoken: ReportedUtterance) {
        guard usingDirectMode else { return }
        let baseOffset: Int
        if isDirectSleepFadeActive, let fadeOffset = directFadeOffsets[spoken.id] {
            baseOffset = fadeOffset
        } else if Self.isLiveDirectUtterance(spoken.utterance, liveUtterance: liveDirectUtterance) {
            baseOffset = directModeBaseOffset
        } else {
            return
        }
        let word = (spoken.utterance.speechString as NSString).substring(with: characterRange)
        // The range counts from the start of its utterance; the cursor counts
        // from the start of the whole chapter text.
        let absoluteRange = NSRange(location: characterRange.location + baseOffset, length: characterRange.length)
        currentWordRange = absoluteRange
        onWordSpoken?(absoluteRange, word)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        // Held for the main queue (`ReportedUtterance`).
        let started = ReportedUtterance(utterance: utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isDirectSleepFadeActive,
               let fadeOffset = self.directFadeOffsets[started.id] {
                self.transitionLog(.trace, "SLEEP_FADE_DIRECT_SEGMENT_STARTED: offset=\(fadeOffset)")
                self.isSpeaking = true
                self.isPaused = false
                return
            }
            // The chunk queued after the one speaking may report its start
            // before that one's end reaches the main queue. The synthesizer
            // has gone on to it, so it is the one speaking now, and the end
            // of the one before is then for a chunk no longer live.
            if self.usingDirectMode,
               let queued = self.queuedDirectChunk,
               Self.isLiveDirectUtterance(started.utterance, liveUtterance: queued.utterance) {
                self.transitionLog(.trace, "CHUNK_CONTINUE: queued chunk started at offset \(queued.chunk.start)")
                self.promoteQueuedDirectChunk()
            }
            guard Self.isLiveDirectUtterance(started.utterance, liveUtterance: self.liveDirectUtterance),
                  self.usingDirectMode else {
                self.transitionLog(.trace, "DIRECT_START_IGNORED: stale utterance or direct mode inactive")
                return
            }
            // Read before logging: the message is built lazily.
            let synthesizerIsSpeaking = self.directSynth.isSpeaking
            self.transitionLog(.trace, "DIRECT_START_ACCEPTED: offset=\(self.directModeBaseOffset) chunkEnd=\(self.directModeChunkEnd) synthSpeaking=\(synthesizerIsSpeaking)")
            self.isSpeaking = true
            self.isPaused = false
            self.startDirectPlaybackWatchdog(for: started.utterance)
            // The next chunk waits in the synthesizer while this one speaks.
            self.queueNextDirectChunk()
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        // The utterance itself goes to the main queue, not only its
        // identity, and stays alive until it is compared there. A stop or a
        // seek made in the meantime releases it and starts another utterance,
        // which could otherwise be made at its address and take this finish
        // for its own, ending the chapter just as it restarted.
        let finished = ReportedUtterance(utterance: utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let finishedUtteranceID = finished.id
            if self.isDirectSleepFadeActive,
               let baseOffset = self.directFadeOffsets.removeValue(forKey: finishedUtteranceID),
               let length = self.directFadeLengths.removeValue(forKey: finishedUtteranceID) {
                let endOffset = min(baseOffset + length, self.currentText.utf16Length)
                self.currentWordRange = NSRange(location: endOffset, length: 0)
                if self.directFadeFinalUtteranceID == finishedUtteranceID {
                    self.liveDirectUtterance = nil
                    self.transitionLog(.trace, "SLEEP_FADE_DIRECT_QUEUE_FINISHED: offset=\(endOffset)")
                    switch DirectSpeechFadePlanner.completionAction(
                        queueEndOffset: endOffset,
                        textUTF16Length: self.currentText.utf16Length
                    ) {
                    case .continueFade(let continuationOffset):
                        let continuationDuration = self.directFadeContinuationDuration
                        let continuationVolume = self.directFadeTerminalVolume
                        self.prepareDirectSleepFade(
                            fromUTF16Offset: continuationOffset,
                            duration: continuationDuration,
                            startingVolume: continuationVolume
                        )

                    case .finishChapter:
                        self.stopDirectPlaybackWatchdog()
                        self.clearDirectSleepFadeState()
                        self.isSpeaking = false
                        self.isPaused = false
                        self.currentWordRange = nil
                        self.directModeChunked = false
                        self.onUtteranceFinished?()
                    }
                }
                // Timer expiry, not natural utterance completion, owns the
                // pause unless the content itself reached its natural end.
                return
            }
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
                // Read before logging: the message is built lazily.
                let synthesizerIsSpeaking = self.directSynth.isSpeaking
                let synthesizerIsPaused = self.directSynth.isPaused
                self.transitionLog(.trace, "DIRECT_FINISH_IGNORED: utterance mismatch finished=\(finishedUtteranceID) live=\(liveDescription) directMode=\(self.usingDirectMode) synthSpeaking=\(synthesizerIsSpeaking) synthPaused=\(synthesizerIsPaused)")
                return
            }
            guard self.usingDirectMode else {
                self.transitionLog(.trace, "DIRECT_FINISH_IGNORED: matching utterance but direct mode inactive finished=\(finishedUtteranceID)")
                return
            }

            self.transitionLog(.trace, "DIRECT_FINISH_ACCEPTED: offset=\(self.directModeBaseOffset) chunkEnd=\(self.directModeChunkEnd) chunked=\(self.directModeChunked)")
            self.stopDirectPlaybackWatchdog()

            // This utterance has finished naturally — clear the marker so
            // a future stop-without-start doesn't accidentally process its
            // own didFinish twice.
            self.liveDirectUtterance = nil

            // The synthesizer goes straight on to the chunk queued after this
            // one, which is the one speaking now; its start re-arms the
            // watchdog and queues the chunk after it.
            if let queued = self.queuedDirectChunk {
                self.transitionLog(.trace, "CHUNK_CONTINUE: queued chunk at offset \(queued.chunk.start)")
                self.promoteQueuedDirectChunk()
                return
            }

            // A chunked utterance whose successor was never queued, because
            // its start never reached the main queue, continues with a new
            // utterance from where it ended.
            if self.directModeChunked {
                let nextOffset = self.directModeChunkEnd
                if nextOffset < self.currentText.utf16Length {
                    // speakDirect assigns a fresh `liveDirectUtterance`
                    // for the new chunk.
                    self.transitionLog(.trace, "CHUNK_CONTINUE: next chunk at offset \(nextOffset)")
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
        // Held for the main queue (`ReportedUtterance`), so a cancel of a
        // stopped utterance is never taken for one of the live utterance.
        let cancelled = ReportedUtterance(utterance: utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isDirectSleepFadeActive,
               self.directFadeOffsets[cancelled.id] != nil {
                self.transitionLog(.trace, "SLEEP_FADE_DIRECT_SEGMENT_CANCELLED: expected timer cleanup")
                return
            }
            let isCurrent = Self.isLiveDirectUtterance(cancelled.utterance, liveUtterance: self.liveDirectUtterance)
            if isCurrent, self.usingDirectMode, self.isSpeaking, !self.isPaused {
                // The watchdog cannot look into this: its start arms it,
                // and an utterance the engine refuses never starts. Speech
                // goes on from a fresh synthesizer instead.
                // Read before logging: the message is built lazily.
                let synthesizerIsSpeaking = self.directSynth.isSpeaking
                let synthesizerIsPaused = self.directSynth.isPaused
                self.transitionLog(.event, "DIRECT_CANCEL_UNEXPECTED: live utterance cancelled while app expected playback; watchdog armed=\(self.directPlaybackWatchdogTimer != nil) synthSpeaking=\(synthesizerIsSpeaking) synthPaused=\(synthesizerIsPaused)")
                self.recoverFromCancelledDirectUtterance()
            } else {
                self.transitionLog(.trace, "DIRECT_CANCEL_EXPECTED: stale or deliberately stopped utterance cancelled current=\(isCurrent) directMode=\(self.usingDirectMode) appSpeaking=\(self.isSpeaking) appPaused=\(self.isPaused)")
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        // Held for the main queue (`ReportedUtterance`).
        let paused = ReportedUtterance(utterance: utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isDirectSleepFadeActive,
               self.directFadeOffsets[paused.id] != nil {
                self.isPaused = true
                return
            }
            guard self.usingDirectMode,
                  Self.isLiveDirectUtterance(paused.utterance, liveUtterance: self.liveDirectUtterance) else {
                self.transitionLog(.trace, "DIRECT_PAUSE_IGNORED: stale utterance or direct mode inactive")
                return
            }
            self.isPaused = true
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        // Held for the main queue (`ReportedUtterance`).
        let continued = ReportedUtterance(utterance: utterance)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.isDirectSleepFadeActive,
               self.directFadeOffsets[continued.id] != nil {
                self.isPaused = false
                return
            }
            guard self.usingDirectMode,
                  Self.isLiveDirectUtterance(continued.utterance, liveUtterance: self.liveDirectUtterance) else {
                self.transitionLog(.trace, "DIRECT_CONTINUE_IGNORED: stale utterance or direct mode inactive")
                return
            }
            self.isPaused = false
        }
    }
}
