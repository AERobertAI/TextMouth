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

/// The newest lines a speech service wrote to its transition log
/// (`DiagnosticLog.File.speechTransitions`), each with the time it was
/// written, kept in memory so that the report of a refusal can show them
/// without reading the log files on the main thread (B05).
///
/// They are the service's own lines, which hold offsets and lengths, never
/// the book's words. Every line is kept, the routine trace lines too, which
/// the log file gets only while tracing is on: they show how speech came to
/// the refusal.
struct RecentTransitionLines: Equatable, Sendable {
    /// How many lines a speech service keeps: enough for the chunks, the
    /// cancels, and the retries that lead up to a refusal.
    static let defaultCapacity = 40

    /// One line, with when it was written.
    struct Line: Equatable, Sendable {
        /// When the line was written.
        let time: Date
        /// Whether it is an event, which the file always gets, or routine
        /// chatter, which it gets only while tracing is on.
        let level: DiagnosticLog.Level
        /// The line's words, as the service wrote them.
        let message: String

        /// The line as the log file holds it, so that it can be found
        /// there: the time as the log writer writes it
        /// (`LogWriter.line(_:)`), and a trace line's mark as the policy's
        /// gate writes it (`DiagnosticLog.Gate`), before the words.
        var logged: String {
            let mark = level == .trace ? "TRACE \(DiagnosticLog.Category.playback.rawValue): " : ""
            return "\(time): \(mark)\(message)"
        }
    }

    /// The most lines kept.
    let capacity: Int
    /// The lines kept, oldest first.
    private(set) var lines: [Line] = []

    /// An empty record that keeps at most `capacity` lines.
    init(capacity: Int = Self.defaultCapacity) {
        self.capacity = max(0, capacity)
    }

    /// Keeps `message`, written at `level` at `time`, and lets go of the
    /// oldest lines beyond `capacity`.
    mutating func append(_ message: String, level: DiagnosticLog.Level, at time: Date = Date()) {
        lines.append(Line(time: time, level: level, message: message))
        if lines.count > capacity {
            lines.removeFirst(lines.count - capacity)
        }
    }
}

extension SpeechRefusal.Voice {
    /// `voice` as the report of a refusal names it, its quality as the voice
    /// pickers say it.
    init(_ voice: AVSpeechSynthesisVoice) {
        self.init(name: voice.name, identifier: voice.identifier, language: voice.language, quality: voice.qualityLabel)
    }
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
        // Written as typed steps, which multiply and divide in the order the
        // single expression did, so the count is the same to the last bit:
        // as one expression of untyped literals and `ceil`'s overloads it
        // took the type checker 231 ms (board #1141).
        let calibratedWordsPerMinute: Double = max(1.0, wordsPerMinute)
        let wordsWithMargin: Double = calibratedWordsPerMinute * duration / 60.0 * 1.25
        let estimatedWords = max(1, Int(wordsWithMargin.rounded(.up)))
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

/// Puts the reader's renders through AVSpeechSynthesizer.write() one at a
/// time: the current chapter's, the look-ahead's, and the one-word renders
/// that load a voice ahead of Play. Taking turns keeps the look-ahead from
/// competing with the chapter Play waits for, and lets a render that went
/// stale, or is too long, be refused before it starts.
///
/// Overlapping writes don't change what each one writes. Measured on
/// November 7, 2026: two and three writes at once, in one voice (Samantha)
/// and in two (Samantha and the Eloquence voice Eddy), each wrote the very
/// samples it wrote alone, digest for digest; the outside review saw the
/// same in Flo. So the speech export (FMT43), whose writes run for hours,
/// writes beside the reader's renders, through synthesizers of its own, and
/// never waits here.
///
/// Not measured: a write beside the reader speaking aloud in direct mode.
/// On March 23, 2026 (62fc142e) a background write of a very long chapter
/// made direct mode's speak() loop back to text it had already spoken at a
/// chunk's change, about 30 seconds in, which is why a text over
/// `maximumTextLength` is never rendered; and on July 12 (5ca5535f) this
/// comment called write() a shared resource whose calls must never overlap.
/// Whether an export's writes bring that looping back is still open, as are
/// premium and neural voices.
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

    #if os(iOS)
    /// Whether a look-ahead render may start now, held under its own lock.
    /// True unless the iPhone's life cycle (Slice 6) sets a check of its own:
    /// the thermal state and the memory left.
    private let renderPermission = OSAllocatedUnfairLock<@Sendable () -> Bool>(initialState: { true })

    /// Whether the next chapter may be rendered ahead now
    /// (`renderPermission`), asked by the reader's look-ahead
    /// (`ReaderViewModel.preRenderNextChapter()`) before it renders. The
    /// chapter being read is never held off: a chapter not rendered plays on
    /// directly, and its next chapter starts the ordinary way.
    var mayRenderAhead: @Sendable () -> Bool {
        get { renderPermission.withLock { $0 } }
        set { renderPermission.withLock { $0 = newValue } }
    }

    /// Whether `voice` is left out of rendering: a Personal Voice, which
    /// `write` can't take. One report says "Cannot use
    /// AVSpeechSynthesizerBufferCallback with Personal Voices, defaulting to
    /// output channel" (thread 736148): a render or a warm-up would be heard.
    static func leavesOutOfRendering(_ voice: AVSpeechSynthesisVoice?) -> Bool {
        voice?.voiceTraits.contains(.isPersonalVoice) == true
    }

    /// Forgets which voices were warmed up, after the system's media services
    /// were reset and every voice it had loaded went with them.
    func forgetWarmedVoices() {
        warmedVoices.withLock { $0.removeAll() }
    }
    #endif

    /// Load `voice` into the system synthesizer ahead of the first Play, by
    /// rendering one word with it and dropping the audio (PERF03).
    func warmUp(_ voice: AVSpeechSynthesisVoice?) {
        #if os(iOS)
        // A Personal Voice's warm-up word would be spoken aloud.
        guard !Self.leavesOutOfRendering(voice) else { return }
        #endif
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
        #if os(iOS)
        guard !Self.leavesOutOfRendering(request.voice) else {
            DiagnosticLog.trace(.playback, "RENDER_SKIP: a Personal Voice is never rendered")
            DispatchQueue.main.async { completion(false) }
            return
        }
        #endif
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

// MARK: - Watchdog Timers

/// A repeating timer one of direct speech's watchdogs ticks on, until it is
/// cancelled (`SpeechService.startWatchdogTimer(tick:)`).
protocol SpeechWatchdogTimer: AnyObject {
    /// Keeps the timer from ticking again.
    func cancel()
}

/// The app's watchdog timer: a repeating timer on the main run loop, in its
/// common modes, so that it ticks while a menu is open too.
final class RunLoopWatchdogTimer: SpeechWatchdogTimer {
    /// The timer ticking.
    let timer: Timer

    /// Starts calling `tick` every `interval` seconds on the main run loop.
    /// Made on the main thread, as the speech service makes it.
    init(interval: TimeInterval, tick: @escaping @Sendable () -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in tick() }
        // A watchdog's recovery may come a tenth of its interval later;
        // that lets macOS coalesce its wake-up with other work.
        TimerCoalescing.loosen(timer)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer.invalidate()
    }
}

/// A watchdog timer that never ticks: the watchdogs' timer while a test
/// stands in for the synthesizer (`SpeechService._directUtteranceRecorderForTesting`)
/// without giving timers of its own, since there no utterance starts,
/// speaks, or ends unless the test says so, and a watchdog ticking on the
/// clock would recover from that silence in the middle of a slow test.
final class StoppedWatchdogTimer: SpeechWatchdogTimer {
    func cancel() {}
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
        #if os(iOS)
        engine.onConfigurationChange = { [weak self] in
            self?.engineConfigurationChanged()
        }
        #endif
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
    /// The word being spoken, in the text. Not published: nothing observes it
    /// (the reader takes each word from `onWordSpoken`), and publishing it
    /// announced a change of the service 3 to 5 times a second for nothing.
    var currentWordRange: NSRange?
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
    /// (`endDirectSpeechRefused(at:refusing:spanning:)`), after speech shows
    /// itself stopped at the cursor, with what was refused
    /// (`SpeechRefusal`), for the report of the refusal (B05). The reader
    /// tells the listener, by the report's sheet or by an announcement of
    /// its own, so that one message is heard; with no reader set, speech
    /// says `engineRefusedAnnouncement` itself. A reader may show playback
    /// stopped in turn; Play speaks on from the cursor.
    var onSpeechRefused: ((SpeechRefusal) -> Void)?
    /// Called on the main queue when speech paused itself, the cursor where
    /// it paused, because the voice did not start a passage, on fresh
    /// synthesizers too (`pauseAfterStalls(at:because:)`). The reader makes the
    /// pause its own and tells the listener; with no reader set, speech says
    /// `voiceDidNotStartAnnouncement` itself. Play speaks on from there.
    var onSpeechStalled: (() -> Void)?

    /// The full text currently being spoken, kept after a stop for a later
    /// seek or resume until `releaseSpeech()`. Readable outside this class
    /// so tests can tell that it was let go.
    private(set) var currentText: String = ""

    /// Whether the engine holds audio rendered from exactly the text being
    /// spoken, in the voice chosen now.
    ///
    /// Direct speech switches to rendered audio, at a seek, a resume, or a
    /// recovery, only then. Any other audio is stale: rendered in the
    /// previous voice when a voice was chosen part-way through the text, or
    /// from another text when a render finished after it was abandoned.
    /// Speech then carries on directly in the current voice. Rendered audio
    /// already playing keeps playing until its text ends, since switching
    /// mid-playback is never seamless.
    private var renderedAudioMatchesSpeech: Bool {
        renderedAudioMatches(text: currentText)
    }

    /// Whether the engine holds audio rendered from exactly `text`, in the
    /// voice chosen now. The one test behind `renderedAudioMatchesSpeech` and
    /// `speak(_:)`'s decision to keep a chapter's render (audit C9).
    private func renderedAudioMatches(text: String) -> Bool {
        // Most direct speech has no rendered audio yet; skip hashing the text.
        guard let rendered = madeAudioEngine?.renderedSignature else { return false }
        return rendered == SpeechRenderSignature(text: text, voiceIdentifier: currentVoice?.identifier)
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
    /// speech was last stopped, or since speech reported a word past it
    /// (`forgetRetryPlace(passedBy:)`). A cancel that comes back to the same
    /// offset before speech moves past it means the engine refuses the text
    /// there on a fresh synthesizer too: speech then ends
    /// (`endDirectSpeechRefused(at:refusing:spanning:)`) instead of trying
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
    /// How often direct speech's two watchdogs tick, in seconds: the
    /// playback watchdog, which looks at AVFoundation's own playback state
    /// once the live utterance has started, and the start watchdog, which
    /// waits for it to start.
    static let directWatchdogInterval: TimeInterval = 0.5
    /// Two consecutive idle observations leave time for a normal `didFinish`
    /// callback to reach the main queue before recovery is attempted.
    private static let directPlaybackWatchdogRequiredIdleChecks = 2
    private var directPlaybackWatchdogTimer: SpeechWatchdogTimer?
    private var directPlaybackWatchdogIdleChecks = 0
    /// How long the live utterance may go without starting, in seconds,
    /// while speech should be heard, before the start watchdog recovers
    /// (`recoverFromUnstartedDirectUtterance()`), on a synthesizer that has
    /// started an utterance before: longer than the 3 to 4.5 s a voice not
    /// loaded yet once made the first word wait (PERF03).
    static let directStartWatchdogTimeout: TimeInterval = 5
    /// The same for a synthesizer that has not started an utterance yet, as
    /// the service's first and every fresh one are: twice the slowest cold
    /// start measured (4.5 s, PERF03), since a voice still loading on a busy
    /// Mac can take longer. A recovery that comes too soon skips and repeats
    /// nothing, since nothing of the utterance was heard; a longer wait would
    /// only lengthen the silence before a voice that never starts is noticed.
    static let directStartWatchdogColdTimeout: TimeInterval = 10
    /// How many ticks in a row the start watchdog must find the live
    /// utterance not started before it recovers, on a synthesizer that has
    /// started one: the timeout's worth, and one more, so that a start
    /// reported on the main queue just before the deadline is handled before
    /// the watchdog acts on it.
    static var directStartWatchdogRequiredTicks: Int {
        requiredTicks(waiting: directStartWatchdogTimeout)
    }
    /// The same on a synthesizer that has not started an utterance yet
    /// (`directStartWatchdogColdTimeout`).
    static var directStartWatchdogColdRequiredTicks: Int {
        requiredTicks(waiting: directStartWatchdogColdTimeout)
    }
    /// How many ticks of `directWatchdogInterval` wait out `timeout`, and
    /// one more.
    private static func requiredTicks(waiting timeout: TimeInterval) -> Int {
        Int((timeout / directWatchdogInterval).rounded(.up)) + 1
    }
    /// How many times the start watchdog recovers an utterance that never
    /// starts at one place, the utterance's start offset, before it stops
    /// speech there as a pause and tells the listener
    /// (`pauseAfterStalls(at:because:)`), rather than recovering in silence
    /// forever.
    static let directStartWatchdogRecoveriesPerPlace = 2
    private var directStartWatchdogTimer: SpeechWatchdogTimer?
    private var directStartWatchdogTicks = 0
    /// How many ticks the start watchdog watching now must count: the cold
    /// timeout's on a synthesizer that has not started an utterance yet.
    private var directStartWatchdogTicksNeeded = 0
    /// Whether the direct synthesizer has started an utterance since it was
    /// made: false for the service's first one, and for each fresh one
    /// (`replaceDirectSynthesizer(after:)`), until one starts.
    private var directSynthHasStarted = false
    /// The place where the start watchdog last recovered an utterance that
    /// never started, and how many times it has recovered there since an
    /// utterance last started, speech stopped, or speech paused after them.
    private var startStallRecoveries: WatchdogRecoveries?
    /// How many times the playback watchdog recovers an utterance that went
    /// idle at one place, the last word reported (else the chunk's base),
    /// before it stops speech there as a pause and tells the listener
    /// (`pauseAfterStalls(at:because:)`), rather than restarting at the same
    /// word without end. The start watchdog's cap is
    /// `directStartWatchdogRecoveriesPerPlace`.
    static let directIdleWatchdogRecoveriesPerPlace = 2
    /// The place where the playback watchdog last recovered an idle
    /// utterance, and how many times it has recovered there since speech
    /// last reported a word past it, stopped, or paused after them. An
    /// utterance's start does not clear it: a start shows that the
    /// synthesizer can start, not that it speaks.
    private var idleRecoveries: WatchdogRecoveries?

    /// Where one watchdog has recovered, and how often.
    private struct WatchdogRecoveries {
        /// The offset the recovered utterances began at (the start watchdog)
        /// or went idle at (the playback watchdog).
        let place: Int
        /// How many times the watchdog recovered at that place.
        let count: Int

        /// How many times `record` says a watchdog has recovered at `place`:
        /// none when it holds another place, or nothing.
        static func count(in record: WatchdogRecoveries?, at place: Int) -> Int {
            guard let record, record.place == place else { return 0 }
            return record.count
        }
    }

    /// The two ways a watchdog's recoveries at one place run out, which
    /// pause speech there (`pauseAfterStalls(at:because:)`) in words that
    /// differ only by what the utterance did.
    private enum DirectStall {
        /// The utterance never started (the start watchdog).
        case neverStarted
        /// The utterance started, then went idle without a finish (the
        /// playback watchdog).
        case wentIdle

        /// The log line's tag.
        var logTag: String {
            switch self {
            case .neverStarted: return "DIRECT_START_STALLED"
            case .wentIdle: return "DIRECT_IDLE_STALLED"
            }
        }
        /// What the utterance did, as the log line says it.
        var whatItDid: String {
            switch self {
            case .neverStarted: return "never started"
            case .wentIdle: return "went idle"
            }
        }
        /// How many recoveries the watchdog made at the place first.
        var recoveriesPerPlace: Int {
            switch self {
            case .neverStarted: return SpeechService.directStartWatchdogRecoveriesPerPlace
            case .wentIdle: return SpeechService.directIdleWatchdogRecoveriesPerPlace
            }
        }
        /// What the old synthesizer did, for `replaceDirectSynthesizer(after:)`.
        var replacementReason: String {
            switch self {
            case .neverStarted: return "the live utterance never started"
            case .wentIdle: return "the live utterance went idle"
            }
        }
    }
    /// Timer to poll playback position from audio engine
    private var positionTimer: Timer?

    #if os(iOS)
    /// Tells when direct speech has gone silent while the synthesizer says it
    /// speaks (`PhoneAudioWordWatchdog`), ticked by the playback watchdog.
    private var wordWatchdog = PhoneAudioWordWatchdog(tickInterval: SpeechService.directWatchdogInterval)
    /// Counts the engine's restarts after a configuration change, so that only
    /// the latest one runs.
    private var engineRestartToken = 0
    /// When the direct utterance speaking now started to be timed, and how many
    /// words it has reported since, for the first run's pace line (F35).
    private var directPace: (startedAt: Date, words: Int)?
    #endif

    /// Generation counter for the position timer's ticks. The timer runs
    /// every 100 ms and publishes the engine's offset in its own turn on
    /// the main thread. A seek bumps the generation, so that a timer
    /// started before it, which would put the stale offset over the
    /// now-correct one, publishes nothing more; each tick carries the
    /// generation its timer started in, and the publish guard drops it if
    /// the generation moved. Bumped by `startPositionTracking`,
    /// `stopPositionTracking`, and any path that seeks
    /// (`seek(toCharOffset:)`).
    private(set) var positionGeneration: Int = 0
    /// The offset the position timer last published, nil before its first,
    /// so a tick at an offset that did not move publishes nothing
    /// (`publishRenderedPosition(_:generation:)`).
    private var lastPublishedPositionOffset: Int?

    private var settingsCancellables = Set<AnyCancellable>()

    /// The newest lines this service wrote to its transition log, the
    /// routine ones included, for the report of a refusal (B05). Written
    /// only by `transitionLog(_:_:)`, on the main thread.
    private(set) var recentTransitionLines = RecentTransitionLines()

    /// Records a playback-mode transition in speech's own log
    /// (`DiagnosticLog.File.speechTransitions`). An anomaly, such as a
    /// failed render or resume, a watchdog recovery, or an unexpected
    /// cancellation, is an event and always written; the routine start and
    /// finish of chunks, renders, and mode switches are trace, written only
    /// while tracing is on. Lines hold offsets and lengths, never the text.
    ///
    /// Every line, written to the file or not, is kept in
    /// `recentTransitionLines` too, so its words are made at every call: a
    /// few numbers, at most a few times a chunk.
    private func transitionLog(_ level: DiagnosticLog.Level, _ message: @autoclosure () -> String) {
        let line = message()
        recentTransitionLines.append(line, level: level)
        DiagnosticLog.log(level, .playback, line, in: .speechTransitions)
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
        #if os(iOS)
        // Before the lines below discard rendered audio: on the iPhone a Play
        // whose chapter is rendered already starts on it, so nothing switches.
        if startOnFinishedRender(of: text, from: charOffset) { return }
        #endif
        stop()
        // Rendered audio of this very text in this very voice (a Play after
        // a Stop, or a return to a chapter) is kept, and not rendered again
        // (audit C9). Speech still starts directly, as always; a seek or a
        // resume finds the audio ready.
        let keepsRender = renderedAudioMatches(text: text)
        // `AudioEngineService.stop()` deliberately preserves a completed
        // buffer for ordinary pause/resume flows. This call begins unrelated
        // text, so keeping that buffer would let seek/resume play audio from
        // the previous chapter when the new text is too large to render.
        if !keepsRender, madeAudioEngine?.discardRenderedAudio() == true {
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

        if keepsRender {
            transitionLog(.trace, "RENDER_KEPT: the engine already holds this text's rendered audio in this voice; no new render")
            return
        }

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
            // - The direct-speech watchdog, or a refusal's recovery, recovers
            // A sleep fade never switches: it fades the backend being heard.
            }
        )
    }

    /// Speak `text` directly from `charOffset`, starting with a short chunk
    /// so the first word comes quickly; each later chunk is queued as the
    /// one before it starts (`queueNextDirectChunk()`).
    private func speakDirect(_ text: String, fromCharOffset charOffset: Int) {
        #if os(iOS)
        // The word watchdog waits for this play's first word (F19).
        wordWatchdog.playStarted()
        #endif
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
        // Watched until it starts, when the playback watchdog takes over.
        startDirectStartWatchdog(for: utterance)
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

    /// Starts the repeating timer a direct-speech watchdog ticks on, every
    /// `directWatchdogInterval` seconds: the timers a test gave
    /// (`_watchdogTimerForTesting`), else one that never ticks while a test
    /// stands in for the synthesizer (`StoppedWatchdogTimer`), else the main
    /// run loop's (`RunLoopWatchdogTimer`), as in the app.
    private func startWatchdogTimer(tick: @escaping @Sendable () -> Void) -> SpeechWatchdogTimer {
        if let startTimer = _watchdogTimerForTesting {
            return startTimer(Self.directWatchdogInterval, tick)
        }
        if _directUtteranceRecorderForTesting != nil {
            return StoppedWatchdogTimer()
        }
        return RunLoopWatchdogTimer(interval: Self.directWatchdogInterval, tick: tick)
    }

    /// Monitor a direct utterance after AVFoundation confirms that it started.
    /// This does not estimate speech duration. It recovers only when both the
    /// app and AVFoundation agree playback should be active, but the system
    /// synthesizer remains idle for two consecutive checks. It takes over
    /// from the start watchdog, which watched the utterance until then.
    private func startDirectPlaybackWatchdog(for utterance: AVSpeechUtterance) {
        stopDirectWatchdogs()
        let watchedUtteranceID = ObjectIdentifier(utterance)
        directPlaybackWatchdogTimer = startWatchdogTimer { [weak self] in
            self?.directPlaybackWatchdogTicked(watching: watchedUtteranceID)
        }
    }

    /// One tick of the playback watchdog watching the utterance
    /// `watchedUtteranceID` names: once the synthesizer has been idle for
    /// two ticks in a row while speech should be heard, recover
    /// (`recoverFromIdleDirectSynthesizer(watchedUtteranceID:)`).
    private func directPlaybackWatchdogTicked(watching watchedUtteranceID: ObjectIdentifier) {
        guard liveDirectUtterance.map(ObjectIdentifier.init) == watchedUtteranceID else {
            // A newer utterance owns playback now, and a watchdog of its own
            // watches it, so this one is obsolete.
            stopDirectPlaybackWatchdog()
            return
        }

        let shouldRecover = Self.shouldRecoverIdleDirectSpeech(
            appIsSpeaking: isSpeaking,
            appIsPaused: isPaused,
            usingDirectMode: usingDirectMode,
            synthesizerIsSpeaking: directSynth.isSpeaking,
            synthesizerIsPaused: directSynth.isPaused,
            hasLiveUtterance: liveDirectUtterance != nil
        )
        guard shouldRecover else {
            directPlaybackWatchdogIdleChecks = 0
            #if os(iOS)
            // The synthesizer says it speaks, or is paused while the app
            // plays: the word watchdog decides whether anything is heard.
            if wordsHaveStalled() {
                stopDirectPlaybackWatchdog()
                recoverFromIdleDirectSynthesizer(watchedUtteranceID: watchedUtteranceID)
            }
            #endif
            return
        }

        directPlaybackWatchdogIdleChecks += 1
        guard directPlaybackWatchdogIdleChecks >= Self.directPlaybackWatchdogRequiredIdleChecks else {
            return
        }

        stopDirectPlaybackWatchdog()
        recoverFromIdleDirectSynthesizer(watchedUtteranceID: watchedUtteranceID)
    }

    /// Cancel the playback watchdog whenever playback deliberately stops,
    /// switches backend, or completes normally.
    private func stopDirectPlaybackWatchdog() {
        directPlaybackWatchdogTimer?.cancel()
        directPlaybackWatchdogTimer = nil
        directPlaybackWatchdogIdleChecks = 0
    }

    /// Watch `utterance`, just handed to the synthesizer as the live one,
    /// until it starts, when the playback watchdog takes over
    /// (`startDirectPlaybackWatchdog(for:)`). An utterance that neither
    /// starts, nor is cancelled, nor finishes was watched by nothing, since
    /// the playback watchdog arms at a start, and speech showed itself
    /// speaking in silence until the listener pressed Pause and Play.
    private func startDirectStartWatchdog(for utterance: AVSpeechUtterance) {
        stopDirectWatchdogs()
        directStartWatchdogTicksNeeded = directSynthHasStarted
            ? Self.directStartWatchdogRequiredTicks
            : Self.directStartWatchdogColdRequiredTicks
        let watchedUtteranceID = ObjectIdentifier(utterance)
        directStartWatchdogTimer = startWatchdogTimer { [weak self] in
            self?.directStartWatchdogTicked(watching: watchedUtteranceID)
        }
    }

    /// The live utterance has started, as its start or a word of it shows:
    /// the synthesizer can speak, so its next utterances wait the ordinary
    /// timeout to start, the place's stall count goes, and the playback
    /// watchdog takes over from the start watchdog.
    private func directUtteranceStarted(_ utterance: AVSpeechUtterance) {
        #if os(iOS)
        wordWatchdog.utteranceStarted()
        if directPace == nil {
            directPace = (startedAt: Date(), words: 0)
        }
        #endif
        directSynthHasStarted = true
        startStallRecoveries = nil
        startDirectPlaybackWatchdog(for: utterance)
    }

    /// One tick of the start watchdog watching the utterance
    /// `watchedUtteranceID` names, which has not started: once it has gone
    /// unstarted for `directStartWatchdogTicksNeeded` ticks in a row while
    /// speech should be heard, recover
    /// (`recoverFromUnstartedDirectUtterance()`). A tick while speech is
    /// paused, stopped, playing rendered audio, or fading counts nothing and
    /// starts the count again.
    private func directStartWatchdogTicked(watching watchedUtteranceID: ObjectIdentifier) {
        guard liveDirectUtterance.map(ObjectIdentifier.init) == watchedUtteranceID else {
            // Another utterance, or none, is live now: speech stopped or
            // moved on, and whatever is live is watched afresh.
            stopDirectStartWatchdog()
            return
        }
        guard Self.shouldAwaitDirectStart(
            appIsSpeaking: isSpeaking,
            appIsPaused: isPaused,
            usingDirectMode: usingDirectMode,
            isSleepFadeActive: isDirectSleepFadeActive
        ) else {
            directStartWatchdogTicks = 0
            return
        }
        directStartWatchdogTicks += 1
        guard directStartWatchdogTicks >= directStartWatchdogTicksNeeded else { return }
        stopDirectStartWatchdog()
        recoverFromUnstartedDirectUtterance()
    }

    /// Cancel the start watchdog, as the utterance it watches starts, or as
    /// speech stops, switches backend, or finishes.
    private func stopDirectStartWatchdog() {
        directStartWatchdogTimer?.cancel()
        directStartWatchdogTimer = nil
        directStartWatchdogTicks = 0
    }

    /// Cancel both of direct speech's watchdogs.
    private func stopDirectWatchdogs() {
        stopDirectStartWatchdog()
        stopDirectPlaybackWatchdog()
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

        // At most `directIdleWatchdogRecoveriesPerPlace` recoveries at one
        // place, whichever branch below makes them: an utterance that starts
        // and goes idle again at the same word would otherwise restart there
        // without end. The next one pauses speech there instead.
        let recoveriesHere = WatchdogRecoveries.count(in: idleRecoveries, at: safeOffset)
        guard recoveriesHere < Self.directIdleWatchdogRecoveriesPerPlace else {
            pauseAfterStalls(at: safeOffset, because: .wentIdle)
            return
        }
        idleRecoveries = WatchdogRecoveries(place: safeOffset, count: recoveriesHere + 1)

        #if os(iOS)
        // The word watchdog's stall: the synthesizer says it speaks, and has
        // reported no word for its limit. A synthesizer stalled so may never
        // speak again, as one that refused may not, so a fresh one takes its
        // place first.
        let isWordStall = directSynth.isSpeaking || directSynth.isPaused
        if isWordStall {
            replaceDirectSynthesizer(after: "no word was reported while it said it spoke")
        }
        #endif

        if renderedAudioMatchesSpeech {
            transitionLog(.event, "DIRECT_WATCHDOG_RECOVERY: synthesizer idle without usable didFinish; switching to rendered audio at offset=\(safeOffset) chunkEnd=\(directModeChunkEnd)")
            switchToRenderedAudioOrSpeakDirectly(at: safeOffset, failureTag: "DIRECT_WATCHDOG_ENGINE_FAILED")
            return
        }

        #if os(iOS)
        // Nothing of the chunk after the last reported word was heard, so
        // speech goes on from that word, never from the chunk's end.
        if isWordStall {
            transitionLog(.event, "DIRECT_WORD_WATCHDOG_RECOVERY: restarting direct speech at offset=\(safeOffset) chunkEnd=\(directModeChunkEnd)")
            speakDirect(currentText, fromCharOffset: safeOffset)
            return
        }
        #endif

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

    /// Recover the live utterance, which the synthesizer was handed its
    /// start timeout ago, or more, while speech should be heard, and which
    /// it has neither started, nor cancelled, nor finished
    /// (`DIRECT_START_WATCHDOG_RECOVERY`), as the playback watchdog recovers
    /// from an idle synthesizer: from rendered audio of this speech when the
    /// engine holds some, else directly, from where the utterance begins,
    /// since nothing of it was heard.
    ///
    /// A fresh synthesizer takes the place of the one that held it first
    /// (`replaceDirectSynthesizer(after:)`): one that refused an utterance
    /// never starts another (on October 7 a plain text waited ten seconds on
    /// it for nothing, while a fresh one spoke it at once), so speaking
    /// again on it would stall again.
    ///
    /// At most `directStartWatchdogRecoveriesPerPlace` times at one place,
    /// the utterance's start offset: when fresh synthesizers do not start
    /// it either, speech pauses there and the listener is told
    /// (`pauseAfterStalls(at:because:)`), where it once recovered in silence
    /// every few seconds, without end.
    private func recoverFromUnstartedDirectUtterance() {
        let place = directModeBaseOffset
        let offset = retryOffset(from: directModeBaseOffset, to: directModeChunkEnd)
        let recoveriesHere = WatchdogRecoveries.count(in: startStallRecoveries, at: place)
        guard recoveriesHere < Self.directStartWatchdogRecoveriesPerPlace else {
            pauseAfterStalls(at: offset, because: .neverStarted)
            return
        }
        startStallRecoveries = WatchdogRecoveries(place: place, count: recoveriesHere + 1)
        transitionLog(
            .event,
            "DIRECT_START_WATCHDOG_RECOVERY: utterance at offset=\(place) chunkEnd=\(directModeChunkEnd) never started; "
                + "going on at offset=\(offset), recovery \(recoveriesHere + 1) of \(Self.directStartWatchdogRecoveriesPerPlace) there"
        )
        replaceDirectSynthesizer(after: "the live utterance never started")
        if renderedAudioMatchesSpeech {
            switchToRenderedAudioOrSpeakDirectly(at: offset, failureTag: "DIRECT_START_WATCHDOG_ENGINE_FAILED")
        } else {
            speakDirect(currentText, fromCharOffset: offset)
        }
    }

    /// What the listener hears when the voice did not start a passage, on
    /// fresh synthesizers too, and speech paused there
    /// (`pauseAfterStalls(at:because:)`): "Speech paused", as the reader shows
    /// it, Paused, with Play to go on from there (REV11; it once said
    /// "Speech stopped").
    nonisolated static let voiceDidNotStartAnnouncement = "Speech paused: the voice did not start. Press Play to try again."

    /// Stop speech at `offset` as a pause, the cursor kept there, once a
    /// watchdog's recoveries at the place have all ended in the same stall
    /// (`stall`): an utterance that never started (`DIRECT_START_STALLED`),
    /// or one that went idle (`DIRECT_IDLE_STALLED`), offsets only. The voice
    /// will not speak, and recovering on would leave speech silent while it
    /// showed itself speaking. The synthesizer that held the last one is let
    /// go, and Play speaks from `offset` afresh, on a fresh one
    /// (`pendingDirectSeekOffset`), the place's recoveries to come again
    /// (both watchdogs' records go).
    /// The reader is told and tells the listener once (`onSpeechStalled`);
    /// with no reader, speech says `voiceDidNotStartAnnouncement` itself.
    private func pauseAfterStalls(at offset: Int, because stall: DirectStall) {
        transitionLog(
            .event,
            "\(stall.logTag): offset=\(offset) chunkEnd=\(directModeChunkEnd) \(stall.whatItDid) after "
                + "\(stall.recoveriesPerPlace) recoveries; speech paused there"
        )
        startStallRecoveries = nil
        idleRecoveries = nil
        replaceDirectSynthesizer(after: stall.replacementReason)
        pendingDirectSeekOffset = offset
        isPaused = true
        stopPositionTracking()
        // The cursor stays where speech paused, for the reader too.
        let range = NSRange(location: offset, length: 0)
        currentWordRange = range
        onWordSpoken?(range, "")
        if let onSpeechStalled {
            onSpeechStalled()
        } else {
            // The watchdog ticks on the main thread, where announcements are
            // made.
            MainActor.assumeIsolated {
                VoiceOverAnnouncer.announce(Self.voiceDidNotStartAnnouncement)
            }
        }
    }

    // MARK: - Recovery after the system cancels the live utterance

    /// What the listener hears when the Mac's speech engine refused the
    /// text twice, on a fresh synthesizer too, and speech ended where it
    /// was (`endDirectSpeechRefused(at:refusing:spanning:)`), when speech
    /// has no reader to tell (`onSpeechRefused`); a reader tells the
    /// listener itself (`SpeechRefusalWording.announcement`). Play speaks on
    /// from there.
    nonisolated static let engineRefusedAnnouncement = "Speech stopped: the Mac's speech engine refused this text."

    /// Speak again after the system cancelled the live utterance on its own
    /// (`DIRECT_CANCEL_UNEXPECTED`), as it does when the speech engine
    /// refuses a text it reads as broken markup (`SpeechMarkupGuard`): the
    /// refused utterance never starts, so the playback watchdog, which its
    /// start would arm, never looks, and the start watchdog would act only
    /// once its timeout passed; and the synthesizer that refused it never
    /// speaks again, so speaking again on it would be silent too.
    ///
    /// A fresh synthesizer takes its place first, whatever follows
    /// (`DIRECT_SYNTH_REPLACED`): kept, the one that refused would take the
    /// next Play too, and speak it into silence while speech showed itself
    /// speaking, which is how the reading stopped and could not restart on
    /// October 7.
    ///
    /// When the engine holds audio rendered from this speech in the
    /// current voice (`renderedAudioMatchesSpeech`), that audio plays on
    /// from where the cancelled chunk would have gone on
    /// (`DIRECT_RETRY_ENGINE`). Nothing is heard at this moment, so the
    /// switch neither repeats nor cuts a word, and the render, made from the
    /// whole chapter, can hold what the engine refused in a chunk alone: on
    /// October 7 a chunk holding only a closing tag was refused, while the
    /// chapter, its tags balanced, had rendered.
    ///
    /// Otherwise, or when the engine does not start, the fresh synthesizer
    /// speaks the cancelled chunk again from where it was cancelled
    /// (`DIRECT_RETRY`), and strictly guarded to the chunk's end
    /// (`strictlyGuardedRange`): the default guard had already passed this
    /// text, so only every bracket made silent keeps a shape it misses from
    /// being refused twice. A lone "less than" there is then not spoken,
    /// which is the price of hearing the rest; the chunks after it go back
    /// to the default guard. Once per place: a cancel that comes back to
    /// the same offset means the engine refuses this text on any
    /// synthesizer, even with no bracket in it, and speech ends there
    /// instead (`endDirectSpeechRefused(at:refusing:spanning:)`), as it does
    /// when there is no text to speak again.
    ///
    /// - Parameter refused: The live utterance the system cancelled, which
    ///   the report of a refusal shows as it was handed over.
    private func recoverFromCancelledDirectUtterance(_ refused: AVSpeechUtterance) {
        let offset = retryOffset(from: directModeBaseOffset, to: directModeChunkEnd)
        let refusedChunk = liveDirectChunkRange
        let refusedChunkEnd = directModeChunkEnd
        replaceDirectSynthesizer()
        if renderedAudioMatchesSpeech {
            transitionLog(.event, "DIRECT_RETRY_ENGINE: rendered audio of this speech plays on at offset=\(offset) chunkEnd=\(refusedChunkEnd)")
            if switchToRenderedAudio(at: offset) { return }
            // A rendered buffer can survive an engine-start failure: speak
            // directly again instead, as if there were no rendered audio.
            transitionLog(.event, "DIRECT_RETRY_ENGINE_FAILED: rendered audio did not start at offset=\(offset); speaking it again directly")
            audioEngine.stop()
        }
        guard takeRetry(from: offset, to: refusedChunkEnd) else {
            endDirectSpeechRefused(at: offset, refusing: refused, spanning: refusedChunk)
            return
        }
        transitionLog(.event, "DIRECT_RETRY offset=\(offset) chunkStart=\(directModeBaseOffset) chunkEnd=\(refusedChunkEnd); strictly guarded to the chunk's end")
        speakDirect(currentText, fromCharOffset: offset)
    }

    /// Where the direct chunk speaking now begins and ends in the text,
    /// its end never before its start, which only a test's adopted
    /// utterance could make it (`_adoptLiveDirectUtteranceForTesting`).
    private var liveDirectChunkRange: Range<Int> {
        directModeBaseOffset..<max(directModeBaseOffset, directModeChunkEnd)
    }

    /// The live utterance was cancelled while speech was paused, which the
    /// app itself never does: a pause pauses the synthesizer, and every
    /// stop of the app's lets go of the live utterance before it stops the
    /// synthesizer (`stopDirectSynthesizer()`). The engine refused it, or
    /// the system dropped it, and the synthesizer that held it may never
    /// speak again, so resuming would continue nothing on it, or speak again
    /// on it into silence while speech showed itself playing.
    ///
    /// A fresh synthesizer takes its place now (`DIRECT_SYNTH_REPLACED`),
    /// and the pause stands: nothing is heard until Play. Play then goes on
    /// from where the utterance was cancelled (`pendingDirectSeekOffset`),
    /// as after a seek made while paused: from audio rendered from this
    /// speech when the engine holds some, and otherwise directly, the rest
    /// of the cancelled chunk strictly guarded, as the retry would speak it
    /// (`DIRECT_RETRY_AT_RESUME`). That counts as this place's one retry:
    /// refused there again after Play, speech ends with the announcement.
    /// When the place's retry was taken already, speech ends now
    /// (`endDirectSpeechRefused(at:refusing:spanning:)`).
    ///
    /// - Parameter refused: The live utterance the system cancelled, which
    ///   the report of a refusal shows as it was handed over.
    private func retryCancelledDirectUtteranceAtResume(_ refused: AVSpeechUtterance) {
        let offset = retryOffset(from: directModeBaseOffset, to: directModeChunkEnd)
        let refusedChunk = liveDirectChunkRange
        let refusedChunkEnd = directModeChunkEnd
        replaceDirectSynthesizer()
        guard takeRetry(from: offset, to: refusedChunkEnd) else {
            endDirectSpeechRefused(at: offset, refusing: refused, spanning: refusedChunk)
            return
        }
        pendingDirectSeekOffset = offset
        transitionLog(.event, "DIRECT_RETRY_AT_RESUME offset=\(offset) chunkStart=\(directModeBaseOffset) chunkEnd=\(refusedChunkEnd); speech stays paused")
    }

    /// A segment of a direct sleep fade, `segment`, which begins at
    /// `segmentStart` in the text, was cancelled while the fade still held
    /// it. The app never does that: each of its stops lets go of the fade's
    /// segments before it stops the synthesizer (`stopDirectSynthesizer()`).
    /// So the engine refused the segment's text, and the synthesizer that
    /// held it, with the quieter segments queued after it, never speaks
    /// again: the fade would fall silent early, and Play after the timer's
    /// pause would restart speech on it, into silence.
    ///
    /// A fresh synthesizer takes its place (`DIRECT_SYNTH_REPLACED`), and
    /// the fade goes on from where the segment was cancelled, planned anew
    /// as a fade's continuation is, starting no louder than the segment
    /// was, with the rest of the segment strictly guarded
    /// (`SLEEP_FADE_DIRECT_SEGMENT_REFUSED`). Once per place, as for any
    /// refusal: refused there again, speech ends with the announcement
    /// (`endDirectSpeechRefused(at:refusing:spanning:)`), the segment
    /// reported as what was refused.
    private func recoverFromRefusedFadeSegment(_ segment: AVSpeechUtterance, at segmentStart: Int) {
        let segmentEnd = segmentStart + max(0, directFadeLengths[ObjectIdentifier(segment)] ?? 0)
        let offset = retryOffset(from: segmentStart, to: segmentEnd)
        // Read before the synthesizer is replaced, which ends the fade's
        // bookkeeping.
        let continuationDuration = directFadeContinuationDuration
        replaceDirectSynthesizer()
        guard takeRetry(from: offset, to: segmentEnd) else {
            endDirectSpeechRefused(at: offset, refusing: segment, spanning: segmentStart..<segmentEnd)
            return
        }
        transitionLog(.event, "SLEEP_FADE_DIRECT_SEGMENT_REFUSED: offset=\(offset) segmentEnd=\(segmentEnd); the fade goes on strictly guarded")
        prepareDirectSleepFade(
            fromUTF16Offset: offset,
            duration: continuationDuration,
            startingVolume: segment.volume
        )
    }

    /// Where to speak again after the system cancelled an utterance that
    /// spoke `start..<end` of the text: its last reported word, when one was
    /// reported within it, so that nothing heard is heard twice; else its
    /// start, since an utterance the engine refused never said a word, and
    /// a word reported before it belongs to the utterance before it.
    private func retryOffset(from start: Int, to end: Int) -> Int {
        guard let reported = currentWordRange?.location, reported >= start, reported < end else {
            return start
        }
        return reported
    }

    /// Take the one retry of the place at `offset`, the start of what is
    /// left of a refused utterance that ran to `end`: that rest is spoken
    /// strictly guarded (`strictlyGuardedRange`). False, taking nothing,
    /// when speech was refused at `offset` before and has not moved past it
    /// since (`lastDirectRetryOffset`), so that the engine refuses this text
    /// on any synthesizer, even with no bracket in it, or when there is no
    /// text to speak again; speech should then end there
    /// (`endDirectSpeechRefused(at:refusing:spanning:)`).
    private func takeRetry(from offset: Int, to end: Int) -> Bool {
        guard !currentText.isEmpty, lastDirectRetryOffset != offset else { return false }
        lastDirectRetryOffset = offset
        strictlyGuardedRange = offset..<max(offset, end)
        return true
    }

    /// Replace the direct synthesizer with a fresh one, the old one stopped
    /// and let go with whatever it still held (`stopDirectSynthesizer()`):
    /// after the engine refuses an utterance, the synthesizer that held it
    /// never speaks again (a plain text on it waited 10 s for nothing,
    /// while a fresh instance spoke it at once). `reason`, which the log
    /// line gives, says what the old one did: by default, that the system
    /// cancelled the live utterance.
    private func replaceDirectSynthesizer(after reason: String = "the system cancelled the live utterance") {
        stopDirectSynthesizer()
        directSynth.delegate = nil
        directSynth = AVSpeechSynthesizer()
        directSynth.delegate = self
        directSynthHasStarted = false
        transitionLog(.event, "DIRECT_SYNTH_REPLACED: fresh synthesizer after \(reason)")
    }

    /// End direct speech at `offset` because the engine refused its text on
    /// a fresh synthesizer too (`DIRECT_RETRY_FAILED`). Speech shows itself
    /// stopped, not paused, and keeps its text and the cursor at `offset`,
    /// so that Play speaks on from there, as the reader restarts stopped
    /// speech from its cursor, and the chapter neither ends nor moves on.
    /// The reader is told what was refused (`onSpeechRefused`,
    /// `SpeechRefusal`) and tells the listener; with no reader to tell, the
    /// listener hears `engineRefusedAnnouncement`.
    ///
    /// The caller has already let go of the synthesizer that refused, and
    /// of what it held (`replaceDirectSynthesizer()`), so that Play speaks
    /// on a synthesizer that can still speak.
    ///
    /// - Parameters:
    ///   - refused: The utterance the engine refused the second time, as it
    ///     was handed over: its text, voice, rate, pitch, and volume.
    ///   - refusedRange: Where that utterance begins and ends in the text:
    ///     the chunk, or the sleep fade's segment, it spoke.
    private func endDirectSpeechRefused(at offset: Int, refusing refused: AVSpeechUtterance, spanning refusedRange: Range<Int>) {
        transitionLog(.event, "DIRECT_RETRY_FAILED: offset=\(offset) chunkStart=\(refusedRange.lowerBound) chunkEnd=\(refusedRange.upperBound); speech stopped, the listener told")
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
        // Made after DIRECT_RETRY_FAILED is logged, so its lines end there.
        let refusal = SpeechRefusal(
            offset: offset,
            refusedRange: refusedRange,
            refusedText: refused.speechString,
            strictlyGuardedRange: strictlyGuardedRange,
            voice: refused.voice.map { SpeechRefusal.Voice($0) },
            wordsPerMinute: wordsPerMinute,
            rate: refused.rate,
            pitchMultiplier: refused.pitchMultiplier,
            volume: refused.volume,
            recentLines: recentTransitionLines.lines
        )
        if let onSpeechRefused {
            // One message: the reader tells the listener, by the report's
            // sheet or by an announcement of its own (B05).
            onSpeechRefused(refusal)
        } else {
            // The synthesizer's callbacks reach this service on the main
            // queue, where announcements are made.
            MainActor.assumeIsolated {
                VoiceOverAnnouncer.announce(Self.engineRefusedAnnouncement)
            }
        }
    }

    /// Stop the direct synthesizer and clear the live-utterance marker so
    /// any pending `didFinish` callback for the stopped utterance is
    /// recognised as stale and ignored. Replaces the older
    /// `ignoreDirectFinishCount += 1; directSynth.stopSpeaking(...)` pair
    /// at every internal stop site — that scheme could desync if the
    /// system delivered a different number of didFinish events than we
    /// expected. Identity comparison can't desync.
    private func stopDirectSynthesizer() {
        #if os(iOS)
        directPace = nil
        #endif
        stopDirectWatchdogs()
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

    /// Switch from direct speech to the engine's rendered audio of this
    /// speech, playing it from `offset` at the listener's speed and pitch,
    /// and follow its position once it plays. Returns whether the engine
    /// is playing; when it is not, as a rendered buffer that survived an
    /// engine-start failure can leave it, speech is in neither backend, and
    /// the caller decides how to go on.
    ///
    /// The synthesizer is stopped first and its utterance let go
    /// (`stopDirectSynthesizer()`). The place `willSpeakRangeOfSpeechString`
    /// reports is a few words from the place heard, so a switch while an
    /// utterance is heard can repeat or cut words. Every caller switches
    /// where nothing is heard: a seek, a resume, the watchdog's recovery
    /// from an idle synthesizer, and the recovery from an utterance the
    /// engine refused; a sleep fade never switches
    /// (`setSleepTimerFadeVolume(_:duration:)`). Every caller has checked
    /// that the audio is of this speech in the current voice
    /// (`renderedAudioMatchesSpeech`).
    @discardableResult
    private func switchToRenderedAudio(at offset: Int) -> Bool {
        stopDirectSynthesizer()
        usingDirectMode = false
        audioEngine.setSpeed(wpm: wordsPerMinute)
        audioEngine.setPitch(multiplier: pitchMultiplier)
        audioEngine.play(fromCharOffset: offset)
        guard audioEngine.isPlaying else { return false }
        startPositionTracking()
        return true
    }

    /// Switch to rendered audio of this speech at `offset`, where nothing is
    /// heard (`switchToRenderedAudio(at:)`), or, when the engine does not
    /// start, as a rendered buffer that survived an engine-start failure can
    /// leave it, speak directly from `offset` instead, logging an event
    /// tagged `failureTag`: speech that shows itself speaking is never left
    /// in neither backend. A seek and the watchdog's recovery go on this way;
    /// a refusal's recovery, which must speak the refused text strictly
    /// guarded, goes on its own way.
    private func switchToRenderedAudioOrSpeakDirectly(at offset: Int, failureTag: String) {
        guard !switchToRenderedAudio(at: offset) else { return }
        transitionLog(.event, "\(failureTag): rendered audio did not start; speaking directly at offset=\(offset)")
        audioEngine.stop()
        speakDirect(currentText, fromCharOffset: offset)
    }

    /// Apply one step of a sleep timer's fade, `volume`, to the speech being
    /// heard, in the backend it is heard from: speech never moves to the
    /// other backend for a fade.
    ///
    /// Speech playing from rendered audio fades through the engine's mixer,
    /// step by step. Direct speech fades through quieter utterances
    /// (`prepareDirectSleepFade`, planned by `DirectSpeechFadePlanner`) from
    /// the last word reported, planned at the fade's first step over what
    /// is left of the fade, `duration` times `volume`; the steps after it
    /// find that fade under way.
    ///
    /// Direct speech once switched to rendered audio of this speech as the
    /// fade began, whenever the engine held some, since only the engine
    /// follows a volume while it plays (`SLEEP_FADE_SWITCH`). That was the
    /// one switch made while speech was heard: the place the synthesizer
    /// last reported is a few words from the place heard, and the engine
    /// spreads its frames evenly over the text, so the switch could repeat
    /// or skip a few words just as the listener was falling asleep. The
    /// utterance fade, which served already when the engine could not
    /// start and for chapters too long to render, now serves every fade of
    /// direct speech. Rendered audio is switched to only where nothing is
    /// heard: a seek, a resume, or a recovery (`switchToRenderedAudio(at:)`).
    func setSleepTimerFadeVolume(_ volume: Float, duration: TimeInterval) {
        guard isSpeaking, !isPaused else { return }
        guard usingDirectMode else {
            madeAudioEngine?.setVolume(volume)
            return
        }
        guard !isDirectSleepFadeActive else { return }
        let offset = max(
            0,
            min(currentWordRange?.location ?? directModeBaseOffset, currentText.utf16Length)
        )
        prepareDirectSleepFade(
            fromUTF16Offset: offset,
            duration: duration * Double(max(0, volume)),
            startingVolume: volume
        )
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
        #if os(iOS)
        directPace = nil
        #endif
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

    /// The character offset a resume starts from (ST03).
    ///
    /// - A reported word is the speech the listener last heard, so its
    ///   location wins.
    /// - With no word reported yet (Pause came within about 0.3 seconds of
    ///   Play) in direct mode, the engine's offset is not the speech being
    ///   heard (it is 0, or stale), so the offset is where the direct
    ///   utterance began. That is where the listener pressed Play, snapped to
    ///   its word, so a quick Play and Pause keeps the place instead of
    ///   restarting the chapter.
    /// - Otherwise the engine's own offset, or the start when it knows none.
    nonisolated static func resumeOffset(
        reportedWord: NSRange?,
        usingDirectMode: Bool,
        directModeBaseOffset: Int,
        engineOffset: Int?
    ) -> Int {
        if let reportedWord { return reportedWord.location }
        if usingDirectMode { return directModeBaseOffset }
        return engineOffset ?? 0
    }

    /// Resumes a paused backend and reports whether an audible path was
    /// accepted. Callers can cold-start the chapter when false is returned
    /// instead of publishing a false "playing" state.
    @discardableResult
    func resume() -> Bool {
        guard isPaused else { return false }

        let offset = Self.resumeOffset(
            reportedWord: currentWordRange,
            usingDirectMode: usingDirectMode,
            directModeBaseOffset: directModeBaseOffset,
            engineOffset: madeAudioEngine?.currentCharOffset()
        )
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
            resumed = switchToRenderedAudio(at: resumeOffset)

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
        startStallRecoveries = nil
        idleRecoveries = nil
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

        audioEngine.onPlaybackFinished = { [weak self] in
            self?.handleEngineFinished()
        }

        // The engine may not play: it could not start, or its player node
        // raised as it started (`SPEECH_PLAYER_EXCEPTION`). Speech then goes
        // on directly from here, as a seek's does, rather than showing itself
        // speaking over silence.
        guard audioEngine.isPlaying else {
            transitionLog(.event, "PRE_RENDERED_START_FAILED: rendered audio did not start; speaking directly at offset=\(charOffset)")
            audioEngine.stop()
            speakDirect(text, fromCharOffset: charOffset)
            return
        }
        startPositionTracking()

        transitionLog(.trace, "PRE_RENDERED_START: playing chapter (\(text.utf16Length) UTF-16 units) from offset \(charOffset)")
    }

    // MARK: - Seeking

    /// Seek to a character offset within the current text.
    /// Rendered audio already playing seeks within itself. Direct speech
    /// switches to rendered audio of this speech, in the current voice, for
    /// instant seeking once it is ready, and otherwise restarts direct speech
    /// from the new offset. When the engine does not start, as after an
    /// output device went away, direct speech restarts there too
    /// (`SEEK_ENGINE_FAILED`), as the watchdog's switch falls back: the seek
    /// once left speech in neither backend while it showed itself speaking.
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
                // The switch stops the synthesizer again, which, stopped
                // above, changes nothing.
                switchToRenderedAudioOrSpeakDirectly(at: offset, failureTag: "SEEK_ENGINE_FAILED")
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

    /// How far past its time the position timer may fire: 20 ms of its
    /// 100 ms, which lets macOS coalesce its wake-up with other work and
    /// moves a word's highlight no more than a frame.
    static let positionTimerTolerance: TimeInterval = 0.02

    /// The word that starts at UTF-16 `offset` of `text`, through the next
    /// white space; empty for an offset outside the text or on white space,
    /// where no word is spoken. Ran on a background queue until November
    /// 13, 2026, when its cost fell to the word's length: a string's
    /// UTF-16 index is a constant-time lookup once its first use has made
    /// the string's lookup table (`warmPositionLookup(in:)`).
    nonisolated static func wordStarting(at offset: Int, in text: String) -> String {
        guard offset >= 0, offset < text.utf16Length else { return "" }
        let start = text.index(atUTF16Offset: offset)
        var end = start
        while end < text.endIndex && !text[end].isWhitespace {
            end = text.index(after: end)
        }
        return String(text[start..<end])
    }

    /// Makes `text`'s UTF-16 lookup table off the main thread, so that the
    /// first position tick, which runs on it, does not pay for the walk over
    /// a long chapter's text. A text of ASCII needs none.
    private static func warmPositionLookup(in text: String) {
        DispatchQueue.global(qos: .utility).async {
            _ = text.index(atUTF16Offset: text.utf16Length / 2)
        }
    }

    /// Publishes the position `offset` that the audio engine reports, as
    /// the position timer does on each tick, on the main thread: the word
    /// range, and the word there to `onWordSpoken` when there is one. Only
    /// a position that moved since the last published one is published: a
    /// paused or still engine reports the same offset every tick, and
    /// publishing it again changed nothing and woke the reader for it.
    ///
    /// - Parameters:
    ///   - offset: The engine's character offset.
    ///   - generation: The position generation the timer started in; a seek
    ///     or a stop since then drops the position (`shouldPublishPosition`).
    /// - Returns: Whether the position was published.
    @discardableResult
    func publishRenderedPosition(_ offset: Int, generation: Int) -> Bool {
        guard Self.shouldPublishPosition(capturedGeneration: generation, currentGeneration: positionGeneration),
              offset != lastPublishedPositionOffset else { return false }
        lastPublishedPositionOffset = offset
        let range = NSRange(location: offset, length: 1)
        currentWordRange = range
        let word = Self.wordStarting(at: offset, in: currentText)
        if !word.isEmpty {
            onWordSpoken?(range, word)
        }
        return true
    }

    private func startPositionTracking() {
        // stopPositionTracking() invalidates the previous timer AND bumps
        // the generation, so a tick of the old timer is dropped before the
        // new timer starts. Capture the post-bump generation for the new
        // timer's ticks.
        stopPositionTracking()
        let myGeneration = positionGeneration
        // The new timer's first position is always published.
        lastPublishedPositionOffset = nil
        Self.warmPositionLookup(in: currentText)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            // The timer runs on the main run loop, and publishes from its own
            // turn, with no hop to another queue and back.
            guard let self = self, !self.usingDirectMode, let engine = self.madeAudioEngine,
                  engine.isPlaying || engine.isPaused else { return }
            // currentCharOffset() reads the audio node's render time,
            // which is safe from the main thread (the timer's thread)
            self.publishRenderedPosition(engine.currentCharOffset(), generation: myGeneration)
        }
        timer.tolerance = Self.positionTimerTolerance
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

    #if os(iOS)
    // MARK: - The iPhone

    /// Starts Play on rendered audio of exactly this speech, `text` in the
    /// current voice, from `offset`, when the engine holds it finished
    /// (`renderedAudioMatchesSpeech`): the spec's "start on the engine, so
    /// nothing switches at all". Starting is a natural break, so the user's
    /// rule holds. Should the engine not start, speech goes on directly from
    /// `offset`, the rendered audio kept for the next break.
    ///
    /// - Returns: Whether speech started here; false leaves everything as it
    ///   was, for `speak` to go on as on the Mac.
    private func startOnFinishedRender(of text: String, from offset: Int) -> Bool {
        guard madeAudioEngine?.hasRenderedAudio == true else { return false }
        let previousText = currentText
        currentText = text
        guard renderedAudioMatchesSpeech else {
            currentText = previousText
            return false
        }
        // The engine's stop keeps its rendered audio (`AudioEngineService.stop()`).
        stop()
        isSpeaking = true
        isPaused = false
        transitionLog(.trace, "PLAY_ON_RENDERED: rendered audio of this speech is ready; starting on it at offset=\(offset)")
        guard switchToRenderedAudio(at: offset) else {
            transitionLog(.event, "PLAY_ON_RENDERED_FAILED: rendered audio did not start; speaking directly at offset=\(offset)")
            audioEngine.stop()
            speakDirect(text, fromCharOffset: offset)
            return true
        }
        return true
    }

    /// One tick of the word watchdog (`PhoneAudioWordWatchdog`): whether direct
    /// speech should be heard and has reported no word for its limit. Disarmed
    /// while the system has taken the audio away (F19).
    private func wordsHaveStalled() -> Bool {
        let isInterrupted = MainActor.assumeIsolated { PhoneAudioSession.shared.isInterrupted }
        let stalled = wordWatchdog.tick(
            isExpectedToSpeak: isSpeaking && !isPaused && usingDirectMode && !isDirectSleepFadeActive && !isInterrupted,
            voiceIdentifier: currentVoice?.identifier,
            wordsPerMinute: wordsPerMinute
        )
        if stalled {
            transitionLog(
                .event,
                "DIRECT_WORD_WATCHDOG: no word reported for "
                    + "\(Int(PhoneAudioWordWatchdog.silenceLimit(wordsPerMinute: wordsPerMinute))) s "
                    + "while the synthesizer said it spoke; offset=\(currentWordRange?.location ?? directModeBaseOffset)"
            )
        }
        return stalled
    }

    /// Logs the pace the chunk that just finished was spoken at, measured from
    /// its start to its end, against the speed asked for (F35). Numbers only.
    private func logDirectPace() {
        guard let pace = directPace else { return }
        directPace = nil
        let line = PhoneAudioPace.description(
            words: pace.words,
            seconds: Date().timeIntervalSince(pace.startedAt),
            expectedWordsPerMinute: wordsPerMinute
        )
        transitionLog(.event, "DIRECT_PACE: \(line) voice=\(currentVoice?.identifier ?? "default")")
    }

    /// A cancel the app didn't ask for, of the live utterance or a sleep fade's
    /// segment, while the system has taken the audio away
    /// (`PhoneAudioSession.isInterrupted`): an interruption or a media reset
    /// did it, and the engine refused nothing. Speech holds its place, paused,
    /// on a fresh synthesizer, and Play speaks on from there
    /// (`pendingDirectSeekOffset`); no retry is spent, nothing is strictly
    /// guarded, and no refusal is announced.
    ///
    /// - Returns: Whether the cancel was the interruption's, and is handled.
    private func keepsPlaceForInterruption(_ cancelled: ReportedUtterance) -> Bool {
        let isFadeSegment = isDirectSleepFadeActive && directFadeOffsets[cancelled.id] != nil
        let isLiveUtterance = usingDirectMode && isSpeaking
            && Self.isLiveDirectUtterance(cancelled.utterance, liveUtterance: liveDirectUtterance)
        guard isFadeSegment || isLiveUtterance,
              MainActor.assumeIsolated({ PhoneAudioSession.shared.isInterrupted }) else { return false }
        let place = retryOffset(from: directModeBaseOffset, to: directModeChunkEnd)
        transitionLog(.event, "DIRECT_CANCEL_INTERRUPTED: live utterance cancelled during an audio interruption at offset=\(place); speech holds its place")
        replaceDirectSynthesizer(after: "an audio interruption cancelled the live utterance")
        pendingDirectSeekOffset = place
        if !isPaused {
            isPaused = true
            stopPositionTracking()
        }
        // The cursor stays where speech stopped, for the reader too.
        let range = NSRange(location: place, length: 0)
        currentWordRange = range
        onWordSpoken?(range, "")
        return true
    }

    /// On the main queue: the speech engine stopped itself over a change of
    /// hardware format (`AudioEngineService.onConfigurationChange`), as AirPods
    /// coming or going make it. Nothing is heard, so it is a natural break: the
    /// engine is stopped at its place, which holds, and rendered audio playing
    /// plays on from there a moment later, once the route change that may come
    /// with it has had its turn (`PhoneAudioEventPolicy.engineRestartDelay`).
    /// Paused, the next resume starts the engine afresh at the place.
    private func engineConfigurationChanged() {
        guard !usingDirectMode, isSpeaking, let engine = madeAudioEngine else { return }
        var policy = PhoneAudioEventPolicy()
        let response = policy.respond(to: .engineConfigurationChanged, bookCountsAsPlaying: !isPaused)
        // The position poll's last word is the place last heard.
        let place = max(0, min(currentWordRange?.location ?? engine.currentCharOffset(), currentText.utf16Length))
        engine.stop()
        stopPositionTracking()
        currentWordRange = NSRange(location: place, length: 0)
        transitionLog(.event, "ENGINE_CONFIGURATION_CHANGED: offset=\(place) response=\(response)")
        guard response == .restartFromPlace else { return }
        engineRestartToken += 1
        let token = engineRestartToken
        DispatchQueue.main.asyncAfter(deadline: .now() + PhoneAudioEventPolicy.engineRestartDelay) { [weak self] in
            self?.restartEngineAfterConfigurationChange(token: token)
        }
    }

    /// Plays rendered audio on from the place after a configuration change,
    /// unless speech paused, stopped, or moved to another backend meanwhile,
    /// or a later change took over (`engineRestartToken`). A seek meanwhile
    /// moved the place, which is where it plays on from.
    private func restartEngineAfterConfigurationChange(token: Int) {
        guard token == engineRestartToken, isSpeaking, !isPaused, !usingDirectMode else {
            transitionLog(.trace, "ENGINE_CONFIGURATION_RESTART_SKIPPED: playback changed before the restart")
            return
        }
        let offset = currentWordRange?.location ?? 0
        transitionLog(.event, "ENGINE_CONFIGURATION_RESTART: rendered audio plays on at offset=\(offset)")
        switchToRenderedAudioOrSpeakDirectly(at: offset, failureTag: "ENGINE_CONFIGURATION_RESTART_FAILED")
    }

    /// Readies speech for the iPhone's session to be let go, while it isn't
    /// playing: the engine, paused or done, stops running, so no audio runs
    /// as the session deactivates (the engineer's review, F8).
    func pauseEngineForSessionDeactivation() {
        guard !(isSpeaking && !isPaused) else { return }
        madeAudioEngine?.pauseEngine()
    }
    #endif

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

    /// Sets the text being spoken, as speech preparation does, so hosted
    /// tests can publish rendered positions (`publishRenderedPosition`) in a
    /// text of their own without rendering any speech.
    func _setTextForTesting(_ text: String) {
        currentText = text
    }

    /// Takes every utterance direct speech would hand the synthesizer, in
    /// its place, so hosted tests can follow the chunks speech is made of and
    /// deliver the synthesizer's callbacks for them without a sound. Nil, as
    /// in the app, hands them to the synthesizer.
    var _directUtteranceRecorderForTesting: ((AVSpeechUtterance) -> Void)?

    /// The synthesizer direct speech hands its utterances to now, so hosted
    /// tests can see it replaced after the system cancelled an utterance.
    var _directSynthesizerForTesting: AVSpeechSynthesizer { directSynth }

    /// Starts the timers direct speech's watchdogs tick on, given the
    /// interval and the tick, in place of the main run loop's, so hosted
    /// tests tick them by hand and never wait for one. Nil, as in the app,
    /// starts the run loop's, or none that ticks while a test hands
    /// utterances to its recorder (`startWatchdogTimer(tick:)`).
    var _watchdogTimerForTesting: ((TimeInterval, @escaping @Sendable () -> Void) -> SpeechWatchdogTimer)?

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

    /// Whether `range`, which the synthesizer reports it will speak, lies
    /// within its utterance's text of `length` UTF-16 units, so the word
    /// can be read from it: `NSString.substring(with:)` raises an
    /// Objective-C exception, ending TextMouth, for a range past the end.
    /// The synthesizer reports ranges by its own accounting, so none is
    /// trusted. An empty range at the very end lies within the text; a
    /// location of `NSNotFound`, or a negative location or length, does not.
    ///
    /// The comparison subtracts rather than adding the location to the
    /// length (`NSMaxRange`), which would overflow, and trap, for a location
    /// as large as `NSNotFound`.
    nonisolated static func isUsableSpokenRange(_ range: NSRange, inTextOfLength length: Int) -> Bool {
        range.location >= 0 && range.length >= 0
            && range.location <= length && range.length <= length - range.location
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

    /// Decide whether a tick of the start watchdog counts toward its
    /// recovery: direct speech should be heard, and its live utterance, the
    /// one the watchdog watches, has not started. A pause, a stop, rendered
    /// audio, and a sleep fade, whose segments the watchdog does not watch
    /// (the timer's own end stops them), count nothing. Kept pure, as
    /// `shouldRecoverIdleDirectSpeech` is, so every condition is tested
    /// without a synthesizer.
    nonisolated static func shouldAwaitDirectStart(
        appIsSpeaking: Bool,
        appIsPaused: Bool,
        usingDirectMode: Bool,
        isSleepFadeActive: Bool
    ) -> Bool {
        appIsSpeaking && !appIsPaused && usingDirectMode && !isSleepFadeActive
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
    ///
    /// Nor does a word whose range does not lie within its utterance's text
    /// (`isUsableSpokenRange(_:inTextOfLength:)`): the synthesizer reports
    /// ranges by its own accounting, and reading the word of one past the
    /// end raised an exception that ended TextMouth. Such a report leaves
    /// the cursor where it was, with one trace line naming the range and
    /// the text's length; a live utterance it names still counts as
    /// started, since the synthesizer is speaking it.
    private func placeSpokenWord(at characterRange: NSRange, of spoken: ReportedUtterance) {
        guard usingDirectMode else { return }
        let baseOffset: Int
        if isDirectSleepFadeActive, let fadeOffset = directFadeOffsets[spoken.id] {
            baseOffset = fadeOffset
        } else if Self.isLiveDirectUtterance(spoken.utterance, liveUtterance: liveDirectUtterance) {
            baseOffset = directModeBaseOffset
            #if os(iOS)
            wordWatchdog.wordReported(voiceIdentifier: currentVoice?.identifier)
            directPace?.words += 1
            #endif
            // A word of the live utterance shows that it started, even had
            // its start not been reported: the playback watchdog takes over,
            // so the start watchdog never speaks again what is being heard.
            if directStartWatchdogTimer != nil {
                directUtteranceStarted(spoken.utterance)
            }
        } else {
            return
        }
        let spokenText = spoken.utterance.speechString as NSString
        let spokenTextLength = spokenText.length
        guard Self.isUsableSpokenRange(characterRange, inTextOfLength: spokenTextLength) else {
            transitionLog(
                .trace,
                "SPOKEN_RANGE_IGNORED: location=\(characterRange.location) length=\(characterRange.length) "
                    + "utteranceLength=\(spokenTextLength)"
            )
            return
        }
        let word = spokenText.substring(with: characterRange)
        // The range counts from the start of its utterance; the cursor counts
        // from the start of the whole chapter text.
        let absoluteRange = NSRange(location: characterRange.location + baseOffset, length: characterRange.length)
        currentWordRange = absoluteRange
        forgetRetryPlace(passedBy: absoluteRange.location)
        forgetIdleRecoveries(passedBy: absoluteRange.location)
        onWordSpoken?(absoluteRange, word)
    }

    /// Forget the place of the last retry (`lastDirectRetryOffset`) once a
    /// word past it is reported at `offset`: speech has moved on from the
    /// refused passage, so a refusal met at that same place later, after a
    /// seek back to it, is a new refusal, which earns its own retry. A word
    /// reported at the place itself is not past it: refused there again,
    /// speech still ends (`endDirectSpeechRefused(at:refusing:spanning:)`).
    ///
    /// The place was once kept until speech stopped, so a refusal met there
    /// again, however long after speech had moved on, ended speech at once,
    /// without its one retry.
    private func forgetRetryPlace(passedBy offset: Int) {
        guard let place = lastDirectRetryOffset, offset > place else { return }
        lastDirectRetryOffset = nil
        transitionLog(.trace, "DIRECT_RETRY_PLACE_PASSED: offset=\(offset) place=\(place)")
    }

    /// Forget the playback watchdog's idle recoveries (`idleRecoveries`)
    /// once a word past their place is reported at `offset`: speech has
    /// moved on, so a later idle at that place is a new stall. A word at the
    /// place itself is not past it: the restart at the last reported word
    /// speaks that word again, and going idle there again is the same stall.
    private func forgetIdleRecoveries(passedBy offset: Int) {
        guard let record = idleRecoveries, offset > record.place else { return }
        idleRecoveries = nil
        transitionLog(.trace, "DIRECT_IDLE_PLACE_PASSED: offset=\(offset) place=\(record.place)")
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
            // Read before logging, so the line says what the synthesizer reports now.
            let synthesizerIsSpeaking = self.directSynth.isSpeaking
            self.transitionLog(.trace, "DIRECT_START_ACCEPTED: offset=\(self.directModeBaseOffset) chunkEnd=\(self.directModeChunkEnd) synthSpeaking=\(synthesizerIsSpeaking)")
            self.isSpeaking = true
            self.isPaused = false
            self.directUtteranceStarted(started.utterance)
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
                        self.stopDirectWatchdogs()
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
                // Read before logging, so the line says what the synthesizer reports now.
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
            #if os(iOS)
            self.logDirectPace()
            #endif
            self.stopDirectWatchdogs()

            // This utterance has finished naturally — clear the marker so
            // a future stop-without-start doesn't accidentally process its
            // own didFinish twice.
            self.liveDirectUtterance = nil

            // The synthesizer goes straight on to the chunk queued after this
            // one, which is the one speaking now. Until its start arms the
            // playback watchdog and queues the chunk after it, the start
            // watchdog watches it: a queued chunk the synthesizer never
            // starts would otherwise leave speech showing itself speaking
            // in silence.
            if let queued = self.queuedDirectChunk {
                self.transitionLog(.trace, "CHUNK_CONTINUE: queued chunk at offset \(queued.chunk.start)")
                self.promoteQueuedDirectChunk()
                self.startDirectStartWatchdog(for: queued.utterance)
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
            #if os(iOS)
            if self.keepsPlaceForInterruption(cancelled) { return }
            #endif
            // Every stop of the app's lets go of the fade's segments before
            // it stops the synthesizer, so a segment the fade still holds
            // was cancelled by the system: refused.
            if self.isDirectSleepFadeActive,
               let segmentStart = self.directFadeOffsets[cancelled.id] {
                self.transitionLog(.event, "DIRECT_CANCEL_UNEXPECTED: sleep fade segment cancelled while the fade still held it, at offset=\(segmentStart)")
                self.recoverFromRefusedFadeSegment(cancelled.utterance, at: segmentStart)
                return
            }
            let isCurrent = Self.isLiveDirectUtterance(cancelled.utterance, liveUtterance: self.liveDirectUtterance)
            if isCurrent, self.usingDirectMode, self.isSpeaking {
                // The app never cancels the live utterance itself: every
                // stop lets go of it first. The playback watchdog cannot
                // look into this: its start arms it, and an utterance the
                // engine refuses never starts; the start watchdog would wait
                // out its timeout. Speech goes on from a fresh synthesizer
                // instead, now, or at Play when paused.
                // Read before logging, so the line says what the synthesizer reports now.
                let synthesizerIsSpeaking = self.directSynth.isSpeaking
                let synthesizerIsPaused = self.directSynth.isPaused
                let appState = self.isPaused ? "was paused" : "expected playback"
                self.transitionLog(.event, "DIRECT_CANCEL_UNEXPECTED: live utterance cancelled while app \(appState); watchdog armed=\(self.directPlaybackWatchdogTimer != nil) synthSpeaking=\(synthesizerIsSpeaking) synthPaused=\(synthesizerIsPaused)")
                if self.isPaused {
                    self.retryCancelledDirectUtteranceAtResume(cancelled.utterance)
                } else {
                    self.recoverFromCancelledDirectUtterance(cancelled.utterance)
                }
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
