import AVFoundation
import os
import XCTest
@testable import TextMouth

/// Settings' Preview Voice on the phone: it pauses a playing book while it
/// speaks and resumes it once, at the end, however previews follow one
/// another. Every preview here speaks into a recorder, which plays nothing.
@MainActor
final class PhoneSettingsVoicePreviewTests: XCTestCase {
    /// A book that counts its pauses and resumes, standing in for the reader
    /// `PhoneSession` holds. On the main actor, as the preview's `PauseBook`
    /// and the closure it returns are: a nested class isn't the test case's
    /// main actor by itself, and Swift 6 refuses its `self` in a main-actor
    /// closure ("sending 'self' risks causing data races").
    @MainActor
    private final class Book {
        /// Whether it's playing.
        var isPlaying: Bool
        /// How many times it was paused, and resumed.
        private(set) var pauses = 0
        private(set) var resumes = 0

        init(isPlaying: Bool) {
            self.isPlaying = isPlaying
        }

        /// Pauses it if it plays, and returns what resumes it then.
        func pauseForPreview() -> (@MainActor () -> Void)? {
            guard isPlaying else { return nil }
            isPlaying = false
            pauses += 1
            return { [weak self] in
                self?.isPlaying = true
                self?.resumes += 1
            }
        }
    }

    /// A preview over `book`, speaking into the recorders it makes, which
    /// `recorders` collects.
    private func makePreview(over book: Book?, recorders: Recorders) -> PhoneSettingsVoicePreview {
        var pauseBook: PhoneSettingsVoicePreview.PauseBook?
        if let book {
            pauseBook = { book.pauseForPreview() }
        }
        return PhoneSettingsVoicePreview(pauseBook: pauseBook, makingSynthesizersWith: { recorders.make() })
    }

    /// The recorders a preview made, in the order made.
    private final class Recorders {
        private(set) var made: [InfoSynthesizerRecorder] = []

        func make() -> InfoSynthesizerRecorder {
            let recorder = InfoSynthesizerRecorder()
            made.append(recorder)
            return recorder
        }

        /// Every utterance spoken, through any of them.
        var spoken: [AVSpeechUtterance] {
            made.flatMap(\.utterances)
        }
    }

    /// The preview's own sentence, made afresh, as each press makes one.
    private func sentence() -> AVSpeechUtterance {
        AVSpeechUtterance(string: "Hello! This is TextMouth, ready to read for you.")
    }

    // MARK: - Pausing and Resuming

    /// A playing book is paused before the preview speaks, and resumed when
    /// it ends.
    func testAPlayingBookPausesForThePreviewAndResumesAfter() {
        let book = Book(isPlaying: true)
        let recorders = Recorders()
        let preview = makePreview(over: book, recorders: recorders)
        let utterance = sentence()

        preview.speak(utterance)

        XCTAssertEqual(book.pauses, 1)
        XCTAssertFalse(book.isPlaying)
        XCTAssertTrue(preview.isSpeaking)
        XCTAssertEqual(recorders.spoken.map { ObjectIdentifier($0) }, [ObjectIdentifier(utterance)])

        preview.synthesizerFinished(ReportedUtterance(utterance: utterance))

        XCTAssertEqual(book.resumes, 1)
        XCTAssertTrue(book.isPlaying)
        XCTAssertFalse(preview.isSpeaking)
    }

    /// A paused book stays paused: nothing was playing to resume.
    func testAPausedBookStaysPaused() {
        let book = Book(isPlaying: false)
        let recorders = Recorders()
        let preview = makePreview(over: book, recorders: recorders)
        let utterance = sentence()

        preview.speak(utterance)
        preview.synthesizerFinished(ReportedUtterance(utterance: utterance))

        XCTAssertEqual(book.pauses, 0)
        XCTAssertEqual(book.resumes, 0)
        XCTAssertFalse(book.isPlaying)
    }

    /// With nothing to pause the book, the preview just speaks.
    func testWithNothingToPauseThePreviewJustSpeaks() {
        let recorders = Recorders()
        let preview = makePreview(over: nil, recorders: recorders)
        let utterance = sentence()

        preview.speak(utterance)

        XCTAssertEqual(recorders.spoken.count, 1)
        preview.synthesizerFinished(ReportedUtterance(utterance: utterance))
        XCTAssertFalse(preview.isSpeaking)
    }

    /// A second press while the first preview speaks replaces it: the book is
    /// paused once, isn't resumed by the first one's cancel, and resumes once
    /// the second ends.
    func testASecondPreviewKeepsTheBookPausedUntilItEnds() {
        let book = Book(isPlaying: true)
        let recorders = Recorders()
        let preview = makePreview(over: book, recorders: recorders)
        let first = sentence()
        let second = sentence()

        preview.speak(first)
        preview.speak(second)
        preview.synthesizerCancelled(ReportedUtterance(utterance: first))

        XCTAssertEqual(book.pauses, 1)
        XCTAssertEqual(book.resumes, 0, "the replaced preview's cancel resumed the book")
        XCTAssertTrue(preview.isSpeaking)
        XCTAssertEqual(recorders.made.count, 2, "the second preview went to a fresh synthesizer")

        preview.synthesizerFinished(ReportedUtterance(utterance: first))
        XCTAssertEqual(book.resumes, 0, "an end reported late for the first preview resumed the book")

        preview.synthesizerFinished(ReportedUtterance(utterance: second))
        XCTAssertEqual(book.resumes, 1)
        XCTAssertTrue(book.isPlaying)
    }

    /// Stopping the preview, as leaving Settings does, resumes the book once,
    /// and the cancel it causes changes nothing more.
    func testStoppingThePreviewResumesTheBookOnce() {
        let book = Book(isPlaying: true)
        let recorders = Recorders()
        let preview = makePreview(over: book, recorders: recorders)
        let utterance = sentence()
        preview.speak(utterance)

        preview.stop()
        preview.synthesizerCancelled(ReportedUtterance(utterance: utterance))

        XCTAssertEqual(book.resumes, 1)
        XCTAssertFalse(preview.isSpeaking)
        XCTAssertEqual(recorders.made.count, 1, "a cancel asked for doesn't replace the synthesizer")
    }

    /// Stopping with nothing speaking does nothing.
    func testStoppingWithNothingSpeakingDoesNothing() {
        let book = Book(isPlaying: true)
        let recorders = Recorders()
        let preview = makePreview(over: book, recorders: recorders)

        preview.stop()

        XCTAssertEqual(book.pauses, 0)
        XCTAssertEqual(book.resumes, 0)
        XCTAssertTrue(recorders.made.allSatisfy { $0.stops == 0 })
    }

    /// A cancel nobody asked for, as when the engine refuses the voice, ends
    /// the preview, resumes the book, and replaces the synthesizer, so the
    /// next preview speaks.
    func testACancelNobodyAskedForEndsThePreviewAndReplacesTheSynthesizer() {
        let book = Book(isPlaying: true)
        let recorders = Recorders()
        let preview = makePreview(over: book, recorders: recorders)
        let refused = sentence()
        preview.speak(refused)

        preview.synthesizerCancelled(ReportedUtterance(utterance: refused))

        XCTAssertEqual(book.resumes, 1)
        XCTAssertFalse(preview.isSpeaking)
        XCTAssertEqual(recorders.made.count, 2)

        let next = sentence()
        preview.speak(next)
        XCTAssertEqual(recorders.made.last?.utterances.map { ObjectIdentifier($0) }, [ObjectIdentifier(next)])
        XCTAssertEqual(book.pauses, 2, "the book, playing again, paused for the next preview")
    }

    /// The preview tells its synthesizer where to report, so its ends reach
    /// it.
    func testThePreviewIsTheSynthesizersDelegate() {
        let recorders = Recorders()
        let preview = makePreview(over: nil, recorders: recorders)

        preview.speak(sentence())

        XCTAssertNotNil(recorders.made.first?.delegate)
    }

    // MARK: - The Audio Session

    /// The preview asks whether the audio session may be active before it
    /// pauses or speaks anything, as a reader's Play does.
    func testThePreviewAsksTheAudioSessionBeforeItSpeaks() {
        let book = Book(isPlaying: true)
        let recorders = Recorders()
        var asked = 0
        let preview = PhoneSettingsVoicePreview(
            pauseBook: { book.pauseForPreview() },
            audioMayStart: {
                asked += 1
                // Nothing has been paused yet when the question is asked.
                XCTAssertEqual(book.pauses, 0)
                return true
            },
            makingSynthesizersWith: { recorders.make() }
        )

        preview.speak(sentence())

        XCTAssertEqual(asked, 1)
        XCTAssertEqual(recorders.spoken.count, 1)
        XCTAssertEqual(book.pauses, 1)
    }

    /// An audio session that may not start (during a call, say) leaves the
    /// book playing and the preview unspoken.
    func testARefusedAudioSessionPausesAndSpeaksNothing() {
        let book = Book(isPlaying: true)
        let recorders = Recorders()
        let preview = PhoneSettingsVoicePreview(
            pauseBook: { book.pauseForPreview() },
            audioMayStart: { false },
            makingSynthesizersWith: { recorders.make() }
        )

        preview.speak(sentence())

        XCTAssertEqual(book.pauses, 0)
        XCTAssertTrue(book.isPlaying)
        XCTAssertFalse(preview.isSpeaking)
        XCTAssertTrue(recorders.spoken.isEmpty)
    }

    /// A refusal while a preview already speaks leaves that one speaking and
    /// the book paused for it.
    func testARefusalDuringAPreviewLeavesItSpeaking() {
        let book = Book(isPlaying: true)
        let recorders = Recorders()
        // Read by the preview's closure and changed here: under a lock, since the closure is Sendable.
        let allowed = OSAllocatedUnfairLock(initialState: true)
        let preview = PhoneSettingsVoicePreview(
            pauseBook: { book.pauseForPreview() },
            audioMayStart: { allowed.withLock { $0 } },
            makingSynthesizersWith: { recorders.make() }
        )
        preview.speak(sentence())
        allowed.withLock { $0 = false }

        preview.speak(sentence())

        XCTAssertTrue(preview.isSpeaking)
        XCTAssertEqual(recorders.spoken.count, 1)
        XCTAssertEqual(book.resumes, 0)
    }
}
