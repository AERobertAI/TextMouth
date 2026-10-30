import AVFoundation

// MARK: - The Seam

/// One utterance of a speech export (FMT43), as a synthesizer is to write
/// it into buffers.
struct SpeechExportUtterance: Equatable, Sendable {
    /// The words, exactly as the synthesizer is handed them: already
    /// guarded against being read as markup (`AudioEngineService.RenderGuard`).
    let text: String
    /// The identifier of the voice that speaks them
    /// (`AVSpeechSynthesisVoice.identifier`).
    let voiceIdentifier: String
    /// The speaking rate, as `AVSpeechUtterance.rate` takes it.
    let rate: Float
    /// The pitch, as `AVSpeechUtterance.pitchMultiplier` takes it.
    let pitchMultiplier: Float
}

/// How a write of an utterance into buffers ended, when it did not fail.
enum SpeechWriteEnd: Equatable, Sendable {
    /// The synthesizer delivered its last buffer: all of the speech was
    /// written.
    case finished
    /// The synthesizer cancelled the utterance on its own: the speech engine
    /// refused the text (see `SpeechMarkupGuard`). Any buffers it delivered
    /// before then hold only part of the speech.
    case refused
}

/// Why a write of an utterance into buffers failed.
enum SpeechWriteFailure: Error, Equatable {
    /// No buffer came for the synthesizer's stall limit
    /// (`SystemSpeechBufferSynthesizer.stallLimit`).
    case stalled
    /// The utterance names a voice the synthesizer may not write with: one
    /// that is not installed, or a Personal Voice, which speaks aloud rather
    /// than into buffers.
    case unusableVoice
}

/// Speaks utterances into buffers of audio, never aloud: the speech export's
/// seam, so that the app writes with the Mac's speech synthesizer
/// (`SystemSpeechBufferSynthesizer`) and tests with a fake that makes a
/// quiet tone in memory, and no test ever runs a real synthesizer or makes
/// a sound.
protocol SpeechBufferSynthesizing: Sendable {
    /// Speak `utterance` into buffers, never aloud.
    ///
    /// Each buffer is handed to `onBuffer` as it comes, one at a time and in
    /// order, on whichever thread the synthesizer delivers it, while the
    /// write waits for `onBuffer` to return. The call blocks its thread
    /// until the synthesizer has delivered its last buffer or refused the
    /// text, so it is made off the main thread.
    ///
    /// It throws `CancellationError` once `cancellation` is cancelled,
    /// noticed within a quarter of a second; `SpeechWriteFailure.stalled`
    /// when no buffer came for the stall limit; `.unusableVoice` for a voice
    /// it may not use; or whatever `onBuffer` threw, which stops the write.
    ///
    /// After it returns or throws, `onBuffer` is never running and is never
    /// called again: whatever `onBuffer` writes to is the caller's alone
    /// from then on.
    ///
    /// - Returns: `.finished` when the last buffer came, `.refused` when the
    ///   speech engine cancelled the utterance on its own.
    func write(
        _ utterance: SpeechExportUtterance,
        cancellation: BookExportCancellation,
        onBuffer: @escaping (AVAudioPCMBuffer) throws -> Void
    ) throws -> SpeechWriteEnd
}

// MARK: - The Mac's Synthesizer

/// The app's `SpeechBufferSynthesizing`: the Mac's speech synthesizer,
/// writing with `AVSpeechSynthesizer.write(_:toBufferCallback:)` as
/// `AudioEngineService` renders speech, on a fresh synthesizer for every
/// write, which that call needs to be reliable.
///
/// It holds no state, so it is Sendable as it is; what a write's callback
/// and its waiting thread share lives in a `SpeechBufferDelivery` of the
/// write's own.
struct SystemSpeechBufferSynthesizer: SpeechBufferSynthesizing {
    /// How long a write waits for a buffer, from its start until the first
    /// and from each buffer to the next, before it counts as stalled.
    static let stallLimit: TimeInterval = 60

    /// How long the calling thread waits at a time before it looks at the
    /// cancellation and the stall limit again: the "quarter of a second" of
    /// the protocol's contract.
    private static let waitSlice: TimeInterval = 0.25

    func write(
        _ utterance: SpeechExportUtterance,
        cancellation: BookExportCancellation,
        onBuffer: @escaping (AVAudioPCMBuffer) throws -> Void
    ) throws -> SpeechWriteEnd {
        // Refused before any synthesizer exists, so nothing can speak.
        let voice = try Self.usableVoice(identifiedBy: utterance.voiceIdentifier)
        try cancellation.checkCancelled()

        let synthesizer = AVSpeechSynthesizer()
        let wake = DispatchSemaphore(value: 0)
        // The synthesizer cancels a text its speech engine refuses before
        // delivering its last buffer, often before any: the observer wakes
        // the wait then, and remembers that the cancel happened.
        let observer = RenderCancellationObserver(waking: wake)
        let delivery = SpeechBufferDelivery(onBuffer: onBuffer, waking: wake)
        synthesizer.delegate = observer
        defer {
            // However the write ends, `onBuffer` is never called again, even
            // if the synthesizer calls back after being stopped.
            delivery.end()
            synthesizer.delegate = nil
            // The delegate is weak: the observer is held until here.
            withExtendedLifetime(observer) {}
        }

        synthesizer.write(Self.speechUtterance(for: utterance, in: voice)) { buffer in
            delivery.deliver(buffer)
        }

        // Wait for the last buffer, a refusal, or a failure of `onBuffer`,
        // a slice at a time, looking at Stop and the stall limit between
        // slices.
        while wake.wait(timeout: .now() + Self.waitSlice) == .timedOut {
            if cancellation.isCancelled {
                delivery.end()
                synthesizer.stopSpeaking(at: .immediate)
                throw CancellationError()
            }
            if delivery.endIfStalled(limit: Self.stallLimit) {
                synthesizer.stopSpeaking(at: .immediate)
                throw SpeechWriteFailure.stalled
            }
        }

        if let failure = delivery.failure {
            // `onBuffer` failed: the write ended as it did, and the rest of
            // the speech is not wanted.
            synthesizer.stopSpeaking(at: .immediate)
            throw failure
        }
        // This write cancels only on the ways out above, so a cancel seen
        // here is the speech engine's own: a refusal.
        return observer.wasCancelled ? .refused : .finished
    }

    /// The installed voice identified by `identifier`, unless it is a
    /// Personal Voice.
    ///
    /// A Personal Voice renders to the speakers instead of into buffers
    /// (research 7.5), and a voice that is not installed would leave the
    /// utterance's voice nil, which is the system's default, and that can be
    /// a Personal Voice too: a synthesizer is never handed either.
    ///
    /// - Throws: `SpeechWriteFailure.unusableVoice` for either.
    private static func usableVoice(identifiedBy identifier: String) throws -> AVSpeechSynthesisVoice {
        guard let voice = AVSpeechSynthesisVoice(identifier: identifier),
              !voice.voiceTraits.contains(.isPersonalVoice) else {
            throw SpeechWriteFailure.unusableVoice
        }
        return voice
    }

    /// The synthesizer's utterance for `utterance`, spoken in `voice`, at its
    /// rate and pitch, as direct speech sets them
    /// (`SpeechService.makeDirectUtterance`): the listener's VoiceOver
    /// settings, which an utterance prefers by default, never override them.
    private static func speechUtterance(
        for utterance: SpeechExportUtterance,
        in voice: AVSpeechSynthesisVoice
    ) -> AVSpeechUtterance {
        let speech = AVSpeechUtterance(string: utterance.text)
        speech.voice = voice
        speech.rate = utterance.rate
        speech.pitchMultiplier = utterance.pitchMultiplier
        speech.prefersAssistiveTechnologySettings = false
        return speech
    }
}

// MARK: - One Write's Shared State

/// What one write's buffer callback, on the synthesizer's thread, shares
/// with the thread waiting for the write, all under one lock.
///
/// The callback calls `onBuffer` while holding the lock, and ending the
/// write sets `hasEnded` under the same lock, so once `end()` has returned,
/// no call of `onBuffer` is running and none can start: the protocol's
/// promise holds even though the synthesizer may call back after it is
/// stopped.
///
/// Not Sendable, and need not be: only the synthesizer's buffer callback,
/// which is not a Sendable closure, captures it, as `AudioEngineService`'s
/// callback captures its audio builder.
private final class SpeechBufferDelivery {
    /// Guards every property below.
    private let lock = NSLock()
    /// Where each buffer goes: the caller's.
    private let onBuffer: (AVAudioPCMBuffer) throws -> Void
    /// The waiting thread's semaphore: signalled at the last buffer and when
    /// `onBuffer` fails.
    private let wake: DispatchSemaphore
    /// Whether the write has ended, after which nothing is handed on.
    private var hasEnded = false
    /// What `onBuffer` threw, which ended the write.
    private var keptFailure: (any Error)?
    /// When the latest buffer was handed on; until the first, when the
    /// write began.
    private var lastProgress = DispatchTime.now()

    /// A delivery to `onBuffer` that signals `wake` at its end.
    init(onBuffer: @escaping (AVAudioPCMBuffer) throws -> Void, waking wake: DispatchSemaphore) {
        self.onBuffer = onBuffer
        self.wake = wake
    }

    /// What `onBuffer` threw, which ended the write; nil while it has thrown
    /// nothing.
    var failure: (any Error)? {
        lock.withLock { keptFailure }
    }

    /// On the synthesizer's thread: hand `buffer` on, unless the write has
    /// ended. A zero-length buffer is the synthesizer's last: it wakes the
    /// waiting thread instead. A failure of `onBuffer` is kept, ends the
    /// write, and wakes the waiting thread. Anything but PCM audio is
    /// ignored.
    func deliver(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        lock.withLock {
            guard !hasEnded else { return }
            guard pcm.frameLength > 0 else {
                wake.signal()
                return
            }
            do {
                try onBuffer(pcm)
                lastProgress = .now()
            } catch {
                keptFailure = error
                hasEnded = true
                wake.signal()
            }
        }
    }

    /// End the write: `onBuffer` is never called again. Waits for a call of
    /// it that is under way.
    func end() {
        lock.withLock { hasEnded = true }
    }

    /// End the write if no buffer has come for `limit` seconds, and say
    /// whether it did. The time is read under the lock, so a buffer handed
    /// on meanwhile counts.
    func endIfStalled(limit: TimeInterval) -> Bool {
        lock.withLock {
            guard !hasEnded, DispatchTime.now() >= lastProgress + limit else { return false }
            hasEnded = true
            return true
        }
    }
}
