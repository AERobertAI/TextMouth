import AVFoundation
import Foundation

/// Speaks Settings' Preview Voice on the phone, pausing the book that's playing
/// while it speaks and resuming it once it ends, as Where Am I? does (the
/// spec's outside reviews, November 7). With nothing to pause the book, it
/// just speaks, as the Mac's preview does.
///
/// Each preview takes the place of one still speaking, as on the Mac. The book
/// is paused only by the first of a run of previews, and resumed once: when
/// the last one ends, by itself or cancelled, or when the preview is stopped,
/// as when Settings is left. An end reported for a preview since replaced or
/// stopped is ignored, told apart by its utterance, as Speak Info's speaker
/// tells them (`LibraryInfoSpeaker`), so a book is never resumed under a
/// preview still speaking, nor twice.
@MainActor
final class PhoneSettingsVoicePreview {
    /// Pauses the open book if it's playing, and returns what resumes it, or
    /// nil when nothing was playing. `PhoneSession` gives it. It's called just
    /// before each run of previews speaks, so it's also where the audio
    /// session is made active first, whether or not a book plays, as the
    /// engineering review's F7 asks of the phone's Preview Voice. The resume
    /// is called once, at the end, and should leave alone a book the listener
    /// has started or stopped in the meantime.
    typealias PauseBook = @MainActor () -> (@MainActor () -> Void)?

    /// Pauses the book for a preview, when there is one to pause.
    private let pauseBook: PauseBook?
    /// Makes the synthesizers the preview speaks through: the app's own,
    /// unless a test gives recorders that play nothing.
    private let synthesizerFactory: @MainActor () -> any LibraryInfoSynthesizing
    /// The synthesizer, made at the first preview.
    private lazy var synthesizer: any LibraryInfoSynthesizing = synthesizerFactory()
    /// The synthesizer's delegate, kept while the synthesizer may report.
    private var delegate: LibraryInfoSpeechDelegate?
    /// The preview speaking now, by which its end is told from the end of one
    /// replaced or stopped since.
    private var speaking: AVSpeechUtterance?
    /// Resumes the book the first preview of a run paused, once the last ends.
    private var resumeBook: (@MainActor () -> Void)?

    /// A preview pausing the book with `pauseBook`, when given, and speaking
    /// through the synthesizers `factory` makes.
    init(
        pauseBook: PauseBook?,
        makingSynthesizersWith factory: @escaping @MainActor () -> any LibraryInfoSynthesizing = { AVSpeechSynthesizer() }
    ) {
        self.pauseBook = pauseBook
        synthesizerFactory = factory
    }

    /// Whether a preview is speaking now.
    var isSpeaking: Bool {
        speaking != nil
    }

    /// Speaks `utterance` in place of any preview speaking, pausing the book
    /// first when nothing was speaking.
    func speak(_ utterance: AVSpeechUtterance) {
        let replacesOneSpeaking = speaking != nil
        if !replacesOneSpeaking {
            resumeBook = pauseBook?()
        }
        // What speaks is forgotten before it's silenced, so its cancel is
        // known for one asked for. One that takes the place of another goes to
        // a fresh synthesizer, since an utterance handed to one just told to
        // stop can be cancelled along with what it was saying, as Speak Info's
        // speaker found.
        speaking = nil
        if replacesOneSpeaking {
            replaceSynthesizer()
        } else {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let delegate = LibraryInfoSpeechDelegate(
            onFinished: { [weak self] finished in self?.synthesizerFinished(finished) },
            onCancelled: { [weak self] cancelled in self?.synthesizerCancelled(cancelled) }
        )
        self.delegate = delegate
        synthesizer.delegate = delegate
        speaking = utterance
        synthesizer.speak(utterance)
    }

    /// Stops the preview speaking, if one is, and resumes the book it paused.
    func stop() {
        guard speaking != nil else { return }
        speaking = nil
        synthesizer.stopSpeaking(at: .immediate)
        resumeTheBook()
    }

    /// The synthesizer says `finished` ended by itself: when it's the preview
    /// speaking, the book resumes. The delegate calls it on the main actor;
    /// tests call it in the synthesizer's place.
    func synthesizerFinished(_ finished: ReportedUtterance) {
        guard isSpeaking(finished) else { return }
        speaking = nil
        resumeTheBook()
    }

    /// The synthesizer says `cancelled` was cancelled. One asked for, of a
    /// preview replaced or stopped, changes nothing. One nobody asked for, as
    /// when the speech engine refuses the voice, ends the preview, resumes
    /// the book, and replaces the synthesizer, which may never speak again.
    func synthesizerCancelled(_ cancelled: ReportedUtterance) {
        guard isSpeaking(cancelled) else { return }
        speaking = nil
        replaceSynthesizer()
        resumeTheBook()
    }

    /// Whether `reported` is the preview speaking now.
    private func isSpeaking(_ reported: ReportedUtterance) -> Bool {
        speaking.map { ObjectIdentifier($0) } == reported.id
    }

    /// Resumes the book the run of previews paused, once.
    private func resumeTheBook() {
        let resume = resumeBook
        resumeBook = nil
        resume?()
    }

    /// Replaces the synthesizer with a fresh one, the old one stopped and its
    /// delegate let go, so nothing it still reports reaches the preview.
    private func replaceSynthesizer() {
        synthesizer.delegate = nil
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer = synthesizerFactory()
    }
}
