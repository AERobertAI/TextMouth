import AVFoundation
import os

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
    /// No buffer came for the synthesizer's stall limits
    /// (`SystemSpeechBufferSynthesizer.StallLimits`): the first in its time
    /// for the text's length, or the next a minute after the one before.
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
    /// write waits for `onBuffer` to return. The Mac's synthesizer delivers
    /// them on the main thread. The call blocks its thread until the
    /// synthesizer has delivered its last buffer or refused the text, so it
    /// is made off the main thread, which the buffers then reach.
    ///
    /// It throws `CancellationError` once `cancellation` is cancelled,
    /// noticed within a quarter of a second; `SpeechWriteFailure.stalled`
    /// when no buffer came for its stall limit; `.unusableVoice` for a voice
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
/// What it reaches is given to it: the synthesizer each write gets
/// (`makeWriter`, the Mac's own `AVSpeechBufferWriter` in the app), how a
/// voice is found and whether it is a Personal Voice, and how long it waits
/// for a buffer. So a test drives its wait through a refusal, a Stop, and a
/// stall with a fake synthesizer and short limits, never a real voice. It
/// holds nothing that changes, so it is Sendable as it is; what one write's
/// callback and its waiting thread share lives in a `SpeechBufferDelivery`
/// of the write's own.
struct SystemSpeechBufferSynthesizer: SpeechBufferSynthesizing {
    /// How long a write waits for a buffer before it counts as stalled.
    struct StallLimits: Equatable, Sendable {
        /// The least time the first buffer is waited for, in seconds.
        var firstBufferFloor: TimeInterval
        /// The time the first buffer is waited for for each UTF-16 unit of
        /// the utterance, in seconds, when that comes to more than the
        /// floor: a voice reads the whole text before its first buffer.
        var firstBufferPerUnit: TimeInterval
        /// The time from each buffer to the next, in seconds.
        var betweenBuffers: TimeInterval
        /// The quiet after an empty buffer, the end of one of the
        /// synthesizer's segments, after which the write counts as finished
        /// although the synthesizer never said so
        /// (`SpeechBufferDelivery.quietAfterSegmentEnd`).
        var afterSegmentEnd: TimeInterval = SpeechBufferDelivery.quietAfterSegmentEnd

        /// The app's limits.
        ///
        /// The Eloquence voices, eight of this Mac's 29 US English ones,
        /// read a whole utterance before their first buffer: Flo took 21.0 s
        /// for 99,883 units, against 0.15 s for Alex. So the first buffer is
        /// waited for 2 ms a unit, ten times Flo's 0.21 ms, and never less
        /// than three minutes: 200 s for the longest utterance. Between
        /// buffers no voice paused more than 0.41 s, and a minute is ample.
        static let standard = StallLimits(firstBufferFloor: 180, firstBufferPerUnit: 0.002, betweenBuffers: 60)

        /// How long the first buffer of an utterance `units` UTF-16 units
        /// long is waited for.
        func firstBuffer(forUnits units: Int) -> TimeInterval {
            max(firstBufferFloor, Double(max(0, units)) * firstBufferPerUnit)
        }
    }

    /// How long the calling thread waits at a time before it looks at the
    /// cancellation and the stall limit again: the "quarter of a second" of
    /// the protocol's contract.
    private static let waitSlice: TimeInterval = 0.25

    /// The clock the stall limits are timed by: the Mac's uptime, and the iPhone's running time, which does not count
    /// a suspension (`RunningClock.app`).
    static var defaultClock: RunningClock {
        #if os(macOS)
        .system
        #else
        .app
        #endif
    }

    /// How long a write waits for a buffer.
    let stallLimits: StallLimits
    /// What the limits are timed by.
    let clock: RunningClock
    /// Makes the synthesizer one write uses: a fresh one each time.
    let makeWriter: @Sendable () -> any SpeechBufferWriting
    /// The installed voice with an identifier, or nil when none has it.
    let findVoice: @Sendable (String) -> AVSpeechSynthesisVoice?
    /// Whether a voice is a Personal Voice.
    let isPersonalVoice: @Sendable (AVSpeechSynthesisVoice) -> Bool

    /// The Mac's synthesizer, as the app writes with it, unless a test gives
    /// its own parts.
    init(
        stallLimits: StallLimits = .standard,
        clock: RunningClock = SystemSpeechBufferSynthesizer.defaultClock,
        makeWriter: @escaping @Sendable () -> any SpeechBufferWriting = { AVSpeechBufferWriter() },
        findVoice: @escaping @Sendable (String) -> AVSpeechSynthesisVoice? = { AVSpeechSynthesisVoice(identifier: $0) },
        isPersonalVoice: @escaping @Sendable (AVSpeechSynthesisVoice) -> Bool = { $0.voiceTraits.contains(.isPersonalVoice) }
    ) {
        self.stallLimits = stallLimits
        self.clock = clock
        self.makeWriter = makeWriter
        self.findVoice = findVoice
        self.isPersonalVoice = isPersonalVoice
    }

    func write(
        _ utterance: SpeechExportUtterance,
        cancellation: BookExportCancellation,
        onBuffer: @escaping (AVAudioPCMBuffer) throws -> Void
    ) throws -> SpeechWriteEnd {
        // Refused before any synthesizer exists, so nothing can speak.
        let voice = try usableVoice(identifiedBy: utterance.voiceIdentifier)
        try cancellation.checkCancelled()

        let writer = makeWriter()
        let wake = DispatchSemaphore(value: 0)
        // The synthesizer cancels a text its speech engine refuses before
        // delivering its last buffer, often before any: the cancel wakes the
        // wait then, and is remembered.
        let refused = OSAllocatedUnfairLock(initialState: false)
        // The clock's heartbeat runs for the write, so that running time is counted whole and only a suspension is not.
        clock.hold()
        let delivery = SpeechBufferDelivery(onBuffer: onBuffer, waking: wake, clock: clock)
        defer {
            clock.release()
            // However the write ends, `onBuffer` is never called again, even
            // if the synthesizer calls back after being stopped. The writer is
            // held until here, and lets go of the synthesizer then.
            delivery.end()
            withExtendedLifetime(writer) {}
        }

        writer.start(
            Self.speechUtterance(for: utterance, in: voice),
            onBuffer: { buffer in delivery.deliver(buffer) },
            onFinish: { wake.signal() },
            onCancel: {
                refused.withLock { $0 = true }
                wake.signal()
            }
        )

        // Wait for the synthesizer's finish, a refusal, or a failure of
        // `onBuffer`, a slice at a time, looking at Stop, the quiet after a
        // segment's end, and the stall limits between slices.
        let firstBufferLimit = stallLimits.firstBuffer(forUnits: utterance.text.utf16.count)
        while wake.wait(timeout: .now() + Self.waitSlice) == .timedOut {
            if cancellation.isCancelled {
                delivery.end()
                writer.stop()
                throw CancellationError()
            }
            // A synthesizer that never reports its finish has finished once
            // nothing has followed a segment's end for the limit.
            if delivery.endIfQuietAfterSegmentEnd(limit: stallLimits.afterSegmentEnd) {
                break
            }
            if delivery.endIfStalled(firstBufferLimit: firstBufferLimit, betweenBuffersLimit: stallLimits.betweenBuffers) {
                writer.stop()
                throw SpeechWriteFailure.stalled
            }
        }

        if let failure = delivery.failure {
            // `onBuffer` failed: the write ended as it did, and the rest of
            // the speech is not wanted.
            writer.stop()
            throw failure
        }
        // This write stops the synthesizer only on the ways out above, so a
        // cancel seen here is the speech engine's own: a refusal.
        return refused.withLock { $0 } ? .refused : .finished
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
    private func usableVoice(identifiedBy identifier: String) throws -> AVSpeechSynthesisVoice {
        guard let voice = findVoice(identifier), !isPersonalVoice(voice) else {
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

// MARK: - One Write's Synthesizer

/// The synthesizer one write of `SystemSpeechBufferSynthesizer` drives: the
/// Mac's `AVSpeechSynthesizer` in the app (`AVSpeechBufferWriter`), a fake in
/// tests, so that the write's wait is tested through a refusal, a Stop, and a
/// stall without a real voice.
protocol SpeechBufferWriting: AnyObject {
    /// Starts writing `utterance` into buffers, never aloud. Each buffer goes
    /// to `onBuffer` as it comes, on whichever thread the synthesizer
    /// delivers it (the Mac's synthesizer delivers them on the main thread).
    /// An empty buffer ends one of the synthesizer's segments, not the
    /// utterance: macOS 27 sends one after about every sentence. Once the
    /// last buffer has come, `onFinish` is called; should the speech engine
    /// cancel the utterance on its own, `onCancel` is called instead.
    func start(
        _ utterance: AVSpeechUtterance,
        onBuffer: @escaping (AVAudioBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onCancel: @escaping @Sendable () -> Void
    )
    /// Stops the write at once.
    func stop()
}

/// The app's `SpeechBufferWriting`: a fresh `AVSpeechSynthesizer` for one
/// write, whose finish and cancel it relays.
final class AVSpeechBufferWriter: SpeechBufferWriting {
    /// The synthesizer the write uses, and only this write.
    private let synthesizer = AVSpeechSynthesizer()
    /// Relays the synthesizer's finish and cancel. The synthesizer's
    /// delegate is weak, so the relay is held here for the write's length.
    private var relay: SpeechWriteRelay?

    func start(
        _ utterance: AVSpeechUtterance,
        onBuffer: @escaping (AVAudioBuffer) -> Void,
        onFinish: @escaping @Sendable () -> Void,
        onCancel: @escaping @Sendable () -> Void
    ) {
        let relay = SpeechWriteRelay(onFinish: onFinish, onCancel: onCancel)
        self.relay = relay
        synthesizer.delegate = relay
        synthesizer.write(utterance, toBufferCallback: onBuffer)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }

    deinit {
        // A synthesizer stopped late can still call its delegate; there is
        // none by then.
        synthesizer.delegate = nil
    }
}

/// The delegate that tells a write of `AVSpeechSynthesizer.write(_:toBufferCallback:)`
/// how it ended, for the speech export's writes and `AudioEngineService`'s
/// renders alike:
/// - **finished**: the synthesizer has delivered its last buffer. This, and
///   not an empty buffer, is the write's end: on macOS 27 the synthesizer
///   sends an empty buffer after each of its segments, about a sentence
///   each, and the finish only after the last (probed November 28, 2026). A
///   render that took the first empty buffer for its end kept one sentence
///   of each chapter, and the reader moved on to the next chapter after it.
/// - **cancelled**: while the write still holds it, the speech engine
///   refused the text (see `SpeechMarkupGuard`). Measured offline, a refused
///   write made no buffer callback at all and was cancelled within 0.03 s,
///   so only the cancel wakes the wait before its limit.
///
/// It is Sendable, as every delegate of a synthesizer is
/// (`NS_SWIFT_SENDABLE`), with nothing but Sendable closures in it.
final class SpeechWriteRelay: NSObject, AVSpeechSynthesizerDelegate {
    /// Called once the synthesizer finishes the utterance.
    private let onFinish: @Sendable () -> Void
    /// Called once the synthesizer cancels the utterance.
    private let onCancel: @Sendable () -> Void

    /// A relay calling `onFinish` at the utterance's finish and `onCancel`
    /// at its cancel.
    init(onFinish: @escaping @Sendable () -> Void, onCancel: @escaping @Sendable () -> Void) {
        self.onFinish = onFinish
        self.onCancel = onCancel
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onCancel()
    }
}

// MARK: - One Write's Shared State

/// What one write's buffer callback shares with the thread waiting for the
/// write, all under one lock. The callback runs on whichever thread the
/// synthesizer delivers on: the Mac's synthesizer delivers on the main
/// thread, whatever thread the write was asked on.
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
final class SpeechBufferDelivery {
    /// Guards every property below.
    private let lock = NSLock()
    /// Where each buffer goes: the caller's.
    private let onBuffer: (AVAudioPCMBuffer) throws -> Void
    /// The waiting thread's semaphore: signalled when `onBuffer` fails (the
    /// synthesizer's finish and cancel signal it through the write's relay).
    private let wake: DispatchSemaphore
    /// Whether the write has ended, after which nothing is handed on.
    private var hasEnded = false
    /// What `onBuffer` threw, which ended the write.
    private var keptFailure: (any Error)?
    /// What the stall limits are timed by: the Mac's own uptime, or, on the iPhone, the time the app has run, which
    /// leaves out the time iOS held it suspended (`RunningClock`). A system clock keeps counting through a
    /// suspension, and a chapter would be ended as stalled after a minute away.
    private let clock: RunningClock
    /// When the latest buffer was handed on, by `clock`; until the first, when the write began.
    private var lastProgress: TimeInterval
    /// Whether a buffer has been handed on, after which the limit between
    /// buffers applies rather than the first buffer's.
    private var hasHandedOn = false
    /// When, by `clock`, the latest empty buffer came, the end of one of the
    /// synthesizer's segments, while no buffer with audio has come since;
    /// nil otherwise.
    private var segmentEndedAt: TimeInterval?

    /// The quiet after a segment's end, in seconds, after which a write
    /// counts as finished although its synthesizer never said so
    /// (`endIfQuietAfterSegmentEnd(limit:)`): a fallback for a synthesizer
    /// that never reports `didFinish` for a write. Between buffers no voice
    /// has paused more than 0.41 s (`StallLimits.standard`), so ten seconds
    /// never cuts off a segment still to come.
    static let quietAfterSegmentEnd: TimeInterval = 10

    /// A delivery to `onBuffer` that signals `wake` at its end, timing its stall limits by `clock`.
    init(
        onBuffer: @escaping (AVAudioPCMBuffer) throws -> Void,
        waking wake: DispatchSemaphore,
        clock: RunningClock = SystemSpeechBufferSynthesizer.defaultClock
    ) {
        self.onBuffer = onBuffer
        self.wake = wake
        self.clock = clock
        lastProgress = clock.now()
    }

    /// What `onBuffer` threw, which ended the write; nil while it has thrown
    /// nothing.
    var failure: (any Error)? {
        lock.withLock { keptFailure }
    }

    /// On the synthesizer's delivering thread: hand `buffer` on, unless the
    /// write has ended. A zero-length buffer ends one of the synthesizer's
    /// segments, not the write: it is not handed on, and only its time is
    /// kept (`endIfQuietAfterSegmentEnd(limit:)`); the synthesizer's finish
    /// ends the write. A failure of `onBuffer` is kept, ends the write, and
    /// wakes the waiting thread. Anything but PCM audio is ignored.
    func deliver(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        lock.withLock {
            guard !hasEnded else { return }
            guard pcm.frameLength > 0 else {
                segmentEndedAt = clock.now()
                return
            }
            do {
                try onBuffer(pcm)
                lastProgress = clock.now()
                hasHandedOn = true
                segmentEndedAt = nil
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

    /// End the write if a segment's end came `limit` seconds ago or more,
    /// with no buffer of audio since, and say whether it did: the fallback
    /// end of a write whose synthesizer never reports its finish. The time
    /// is read under the lock, so a buffer handed on meanwhile counts.
    func endIfQuietAfterSegmentEnd(limit: TimeInterval) -> Bool {
        lock.withLock {
            guard !hasEnded, let segmentEndedAt, clock.now() >= segmentEndedAt + limit else { return false }
            hasEnded = true
            return true
        }
    }

    /// End the write if no buffer has come for its limit, and say whether it
    /// did: `firstBufferLimit` seconds from the write's start until the
    /// first buffer, and `betweenBuffersLimit` from each buffer to the next.
    /// The time is read under the lock, so a buffer handed on meanwhile
    /// counts.
    func endIfStalled(firstBufferLimit: TimeInterval, betweenBuffersLimit: TimeInterval) -> Bool {
        lock.withLock {
            let limit = hasHandedOn ? betweenBuffersLimit : firstBufferLimit
            guard !hasEnded, clock.now() >= lastProgress + limit else { return false }
            hasEnded = true
            return true
        }
    }
}
