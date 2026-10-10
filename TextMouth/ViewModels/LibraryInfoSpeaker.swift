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

/// Tells a `LibraryInfoSpeaker` how each of its utterances ended, finished
/// or cancelled, with the utterance itself, held as a `ReportedUtterance`,
/// so the speaker can tell the announcement speaking from one it stopped or
/// replaced, as the reader's Where Am I does (`WhereAmIDelegateHelper`).
/// Each report reaches the main actor at once when the synthesizer calls on
/// the main thread, as it does, and otherwise on the next main-queue turn.
/// Reporting at once lets a hosted test, which runs as a main-queue job and
/// so cannot drain other main-queue blocks from a run loop it spins, end an
/// announcement itself. It needs no Sendable conformance: only its Sendable
/// closures and the Sendable reports are captured for the main queue.
final class LibraryInfoSpeechDelegate: NSObject, AVSpeechSynthesizerDelegate {
    /// Told of an utterance that finished by itself.
    private let onFinished: @MainActor @Sendable (ReportedUtterance) -> Void
    /// Told of an utterance that was cancelled: by the speaker's own stop,
    /// or by the system, as when the speech engine refuses its text.
    private let onCancelled: @MainActor @Sendable (ReportedUtterance) -> Void

    init(
        onFinished: @escaping @MainActor @Sendable (ReportedUtterance) -> Void,
        onCancelled: @escaping @MainActor @Sendable (ReportedUtterance) -> Void
    ) {
        self.onFinished = onFinished
        self.onCancelled = onCancelled
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        report(utterance, to: onFinished)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        report(utterance, to: onCancelled)
    }

    /// Hands `utterance` to `handler` on the main actor: at once on the
    /// main thread, and otherwise on the next main-queue turn.
    private func report(_ utterance: AVSpeechUtterance, to handler: @escaping @MainActor @Sendable (ReportedUtterance) -> Void) {
        let reported = ReportedUtterance(utterance: utterance)
        if Thread.isMainThread {
            MainActor.assumeIsolated { handler(reported) }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { handler(reported) }
            }
        }
    }
}

/// Speaks the selected row's information in a Library window as Where Am I
/// speaks a position in a reader: with the app's own voice at its speed,
/// through a synthesizer of its own, so it works with VoiceOver off, and
/// over VoiceOver's speech when that is on, as Where Am I's does. Speak Info
/// (the I key, Library > Speak Info) asks for the brief summary and Speak
/// Full Info (I twice, Library > Speak Full Info) for the full one, and what
/// each press does follows `SummaryPress` (FR12): a brief press stops a
/// summary speaking, a full press switches the brief summary to the full
/// one, and a press on another row speaks that row's summary in place of
/// the one speaking. Each Library window has one, kept with its state.
@MainActor
final class LibraryInfoSpeaker {
    /// Makes the synthesizers a speaker made without a factory of its own
    /// speaks through: the app's own. A test replaces it with one making
    /// recorders that play nothing before the first press in a hosted
    /// Library window, whose speaker makes its synthesizer at that press.
    static var makeSynthesizer: @MainActor () -> any LibraryInfoSynthesizing = { AVSpeechSynthesizer() }

    /// An announcement speaking.
    private struct Announcement {
        /// The summary it says.
        let detail: SummaryDetail
        /// The row it describes, by `LibraryInfoRow.id`; nil when nothing
        /// was selected and it says so.
        let rowID: UUID?
        /// The utterance speaking it, by which its end is told from that of
        /// one stopped or replaced since.
        let utterance: AVSpeechUtterance
    }

    /// The announcement speaking now, or nil.
    private var announcement: Announcement?
    /// What was last spoken, for tests and for the window's own checks.
    private(set) var lastSpokenText: String?
    /// Makes each synthesizer the speaker speaks through: its first, at the
    /// first press, and a fresh one after the system cancels an
    /// announcement.
    private let synthesizerFactory: @MainActor () -> any LibraryInfoSynthesizing
    /// The synthesizer, made at the first press.
    private lazy var synthesizer: any LibraryInfoSynthesizing = synthesizerFactory()
    /// The synthesizer's delegate, kept while the synthesizer may report.
    private var delegate: LibraryInfoSpeechDelegate?

    /// A speaker speaking through the synthesizers `factory` makes, the
    /// app's own unless a test passes another.
    init(makingSynthesizersWith factory: @escaping @MainActor () -> any LibraryInfoSynthesizing = { LibraryInfoSpeaker.makeSynthesizer() }) {
        synthesizerFactory = factory
    }

    /// A speaker speaking through `synthesizer` alone, which also stands in
    /// for the fresh one a cancel nobody asked for would make.
    convenience init(synthesizer: any LibraryInfoSynthesizing) {
        self.init(makingSynthesizersWith: { synthesizer })
    }

    /// Whether an announcement is speaking now.
    var isSpeaking: Bool {
        announcement != nil
    }

    /// The summary the announcement speaking says, or nil while none
    /// speaks.
    var detailSpeaking: SummaryDetail? {
        announcement?.detail
    }

    /// Handles a press of Speak Info (`.brief`) or Speak Full Info (`.full`)
    /// on the row whose ID is `rowID`, nil when nothing is selected, as
    /// `SummaryPress` decides: it stops the summary speaking, or speaks the
    /// summary it asks for, in place of any speaking, with `voice` at
    /// `wordsPerMinute`. `subject` is asked once, only when a summary is
    /// spoken, with the summary spoken, so a fact only the full one says,
    /// like a file's size, is gathered only then; nil from it means nothing
    /// is selected, which the press says.
    /// - Returns: The text spoken, or nil when the press stopped the
    ///   summary speaking.
    @discardableResult
    func press(
        _ detail: SummaryDetail,
        about rowID: UUID?,
        voice: AVSpeechSynthesisVoice?,
        wordsPerMinute: Double,
        now: Date = Date(),
        subject: (_ spoken: SummaryDetail) -> LibraryInfoSubject?
    ) -> String? {
        let outcome = SummaryPress.outcome(
            pressing: detail,
            while: announcement?.detail,
            sameSubject: announcement?.rowID == rowID
        )
        switch outcome {
        case .stop:
            stop()
            return nil
        case .speak(let spoken), .replace(with: let spoken):
            let text = Self.text(for: subject(spoken), detail: spoken, now: now)
            speak(text, detail: spoken, about: rowID, voice: voice, wordsPerMinute: wordsPerMinute)
            return text
        }
    }

    /// What a press speaks for `subject`: its brief summary or its full one,
    /// as `detail` says, as of `now`; with no subject, that nothing is
    /// selected.
    nonisolated static func text(for subject: LibraryInfoSubject?, detail: SummaryDetail, now: Date) -> String {
        guard let subject else { return LibraryInfoWording.nothingSelected }
        switch detail {
        case .brief: return LibraryInfoWording.brief(subject)
        case .full: return LibraryInfoWording.full(subject, now: now)
        }
    }

    /// Stops the announcement speaking, if one is. It is forgotten first,
    /// so that the cancel the synthesizer then reports for it is known for
    /// one the speaker asked for (`synthesizerCancelled(_:)`).
    func stop() {
        guard announcement != nil else { return }
        announcement = nil
        synthesizer.stopSpeaking(at: .immediate)
    }

    /// The synthesizer says `finished` ended by itself. When it is the
    /// announcement speaking, the announcement ends; the end of one stopped
    /// or replaced since is ignored, so it never ends a newer one. The
    /// synthesizer's delegate calls it on the main actor; tests call it in
    /// the synthesizer's place.
    func synthesizerFinished(_ finished: ReportedUtterance) {
        guard isLive(finished) else { return }
        announcement = nil
    }

    /// The synthesizer says `cancelled` was cancelled. A cancel the speaker
    /// asked for, of an announcement it forgot as it stopped or replaced
    /// it, changes nothing here.
    ///
    /// A cancel of the announcement speaking, which the speaker did not ask
    /// for, as when the speech engine refuses its text, ends it, so the next
    /// press speaks rather than stopping nothing (REV07, Library finding 4;
    /// board #1378), and replaces the synthesizer, since one the engine
    /// refused never speaks again, as the reader's Where Am I replaces its
    /// own.
    func synthesizerCancelled(_ cancelled: ReportedUtterance) {
        guard isLive(cancelled) else { return }
        DiagnosticLog.event(
            .playback,
            "SPEAK_INFO_CANCEL_UNEXPECTED: the summary was cancelled before it ended; synthesizer replaced"
        )
        announcement = nil
        replaceSynthesizer()
    }

    /// Whether `reported` is the announcement speaking now.
    private func isLive(_ reported: ReportedUtterance) -> Bool {
        announcement.map { ObjectIdentifier($0.utterance) } == reported.id
    }

    /// Replaces the synthesizer with a fresh one, the old one stopped and
    /// its delegate let go, so that nothing it still reports reaches the
    /// speaker. The next announcement gives the fresh one its delegate.
    private func replaceSynthesizer() {
        synthesizer.delegate = nil
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer = synthesizerFactory()
    }

    /// Speaks `text`, the `detail` summary of the row `rowID`, with `voice`
    /// at `wordsPerMinute` in place of whatever was speaking, as Where Am I
    /// speaks: with the app's voice and speed, never VoiceOver's.
    private func speak(_ text: String, detail: SummaryDetail, about rowID: UUID?, voice: AVSpeechSynthesisVoice?, wordsPerMinute: Double) {
        // What speaks is forgotten before it is silenced, so its cancel is
        // known for one the speaker asked for.
        announcement = nil
        synthesizer.stopSpeaking(at: .immediate)
        let delegate = LibraryInfoSpeechDelegate(
            onFinished: { [weak self] finished in self?.synthesizerFinished(finished) },
            onCancelled: { [weak self] cancelled in self?.synthesizerCancelled(cancelled) }
        )
        self.delegate = delegate
        synthesizer.delegate = delegate
        // A title can hold a tag-shaped run the synthesizer would take as
        // markup ("<sm>"): neutralized, as every book text is.
        let utterance = AVSpeechUtterance(string: SpeechMarkupGuard.neutralized(text))
        utterance.voice = voice
        utterance.rate = SpeechService.rateForWPM(wordsPerMinute)
        utterance.prefersAssistiveTechnologySettings = false
        lastSpokenText = text
        announcement = Announcement(detail: detail, rowID: rowID, utterance: utterance)
        synthesizer.speak(utterance)
    }
}
