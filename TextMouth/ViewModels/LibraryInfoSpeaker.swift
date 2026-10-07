import AVFoundation
import Foundation

// MARK: - Speak Info (October 7, 2026)

/// What `LibraryInfoSpeaker` speaks through: the app's own
/// `AVSpeechSynthesizer`, or a test's recorder, which plays nothing.
protocol LibraryInfoSynthesizing: AnyObject {
    /// Told when an utterance ends.
    var delegate: (any AVSpeechSynthesizerDelegate)? { get set }
    /// Speaks `utterance`.
    func speak(_ utterance: AVSpeechUtterance)
    /// Stops speaking at `boundary`; whether anything was speaking.
    @discardableResult
    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool
}

extension AVSpeechSynthesizer: LibraryInfoSynthesizing {}

/// Tells a `LibraryInfoSpeaker` when its utterance ends, on the main
/// actor: at once when the synthesizer calls on the main thread, as it
/// does, and otherwise on the next main-queue turn. Ending at once lets a
/// hosted test, which runs as a main-queue job and so cannot drain other
/// main-queue blocks from a run loop it spins, end an announcement itself.
/// It needs no Sendable conformance: its one property is a Sendable
/// closure, which alone is captured for the main queue.
final class LibraryInfoSpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    /// What to do when the utterance ends.
    private let onFinished: @MainActor @Sendable () -> Void

    init(onFinished: @escaping @MainActor @Sendable () -> Void) {
        self.onFinished = onFinished
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let onFinished = onFinished
        if Thread.isMainThread {
            MainActor.assumeIsolated { onFinished() }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { onFinished() }
            }
        }
    }
}

/// Speaks the selected row's information in a Library window (the I key,
/// Library > Speak Info) as Where Am I speaks a position in a reader: with
/// the app's own voice at its speed, through a synthesizer of its own, so
/// it works with VoiceOver off, and over VoiceOver's speech when that is
/// on, as Where Am I's does. The first press speaks the brief summary; a
/// second press within `escalationInterval` of the press that started an
/// announcement speaks the full one; a press while an announcement speaks
/// stops it. Each Library window has one, kept with its state.
@MainActor
final class LibraryInfoSpeaker {
    /// Makes the synthesizer a speaker made without one speaks through: the
    /// app's own. A test replaces it with a recorder that plays nothing
    /// before the first press in a hosted Library window, whose speaker
    /// makes its synthesizer at that press.
    static var makeSynthesizer: @MainActor () -> any LibraryInfoSynthesizing = { AVSpeechSynthesizer() }

    /// How soon a second press must follow the one that started an
    /// announcement to ask for the full summary: Where Am I's own interval,
    /// shared so the two keys feel alike.
    nonisolated static let escalationInterval = ReaderViewModel.whereAmIEscalationInterval

    /// Whether an announcement is speaking now.
    private(set) var isSpeaking = false
    /// What was last spoken, for tests and for the window's own checks.
    private(set) var lastSpokenText: String?
    /// When the press that started the last announcement came.
    private var lastPressTime: Date = .distantPast
    /// The synthesizer: the one given, or the app's, made at the first
    /// press.
    private lazy var synthesizer: any LibraryInfoSynthesizing = Self.makeSynthesizer()
    /// The synthesizer's delegate, kept while an announcement speaks.
    private var delegate: LibraryInfoSpeechDelegate?

    /// A speaker speaking through `synthesizer`, or, given none, through
    /// the one `makeSynthesizer` makes at its first press.
    init(synthesizer: (any LibraryInfoSynthesizing)? = nil) {
        if let synthesizer {
            self.synthesizer = synthesizer
        }
    }

    /// Handles a press: stops the announcement speaking, if one is;
    /// otherwise speaks the brief summary of the subject `subject` gives,
    /// or its full one when the press follows the one that started the
    /// last announcement within `escalationInterval` (the window counts
    /// from that press, as Where Am I's does, so a quick third press after
    /// a stop asks for the full summary), with `voice` at `wordsPerMinute`.
    /// `subject` is asked once, with whether the full summary is wanted,
    /// so a fact only the full one says, like a file's size, is gathered
    /// only then; nil from it means nothing is selected, which the press
    /// says.
    /// - Returns: The text spoken, or nil when the press stopped an
    ///   announcement.
    @discardableResult
    func press(
        voice: AVSpeechSynthesisVoice?,
        wordsPerMinute: Double,
        now: Date = Date(),
        subject: (_ full: Bool) -> LibraryInfoSubject?
    ) -> String? {
        if isSpeaking {
            stop()
            return nil
        }
        let full = ReaderViewModel.shouldUseFullWhereAmI(last: lastPressTime, now: now)
        lastPressTime = now
        let text = Self.text(for: subject(full), full: full, now: now)
        speak(text, voice: voice, wordsPerMinute: wordsPerMinute)
        return text
    }

    /// What a press speaks for `subject`: its brief summary, or its full
    /// one when `full`, as of `now`; with no subject, that nothing is
    /// selected.
    nonisolated static func text(for subject: LibraryInfoSubject?, full: Bool, now: Date) -> String {
        guard let subject else { return LibraryInfoWording.nothingSelected }
        return full ? LibraryInfoWording.full(subject, now: now) : LibraryInfoWording.brief(subject)
    }

    /// Stops the announcement speaking, if one is.
    func stop() {
        guard isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

    /// Ends an announcement that finished by itself. The synthesizer's
    /// delegate calls it on the main actor; tests call it in the
    /// announcement's place.
    func announcementFinished() {
        isSpeaking = false
    }

    /// Speaks `text` with `voice` at `wordsPerMinute` in place of whatever
    /// was speaking, as Where Am I speaks: with the app's voice and speed,
    /// never VoiceOver's.
    private func speak(_ text: String, voice: AVSpeechSynthesisVoice?, wordsPerMinute: Double) {
        synthesizer.stopSpeaking(at: .immediate)
        let delegate = LibraryInfoSpeechDelegate { [weak self] in
            self?.announcementFinished()
        }
        self.delegate = delegate
        synthesizer.delegate = delegate
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = SpeechService.rateForWPM(wordsPerMinute)
        utterance.prefersAssistiveTechnologySettings = false
        lastSpokenText = text
        isSpeaking = true
        synthesizer.speak(utterance)
    }
}
