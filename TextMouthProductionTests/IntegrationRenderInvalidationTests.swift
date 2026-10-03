import AVFoundation
import XCTest
@testable import TextMouth

/// Render invalidation at the real boundary (TODO Q04; repair P03): a book
/// imported and opened in a reader, whose look-ahead renders wait in the
/// held render queue, gets a new voice from the reader's own voice command
/// while the next chapter renders ahead, and its chapter ends the way the
/// speech service reports it.
@MainActor
final class IntegrationRenderInvalidationTests: XCTestCase {
    /// While the first chapter is spoken, the next one renders ahead in the
    /// voice in use. The listener chooses another voice for the book before
    /// that render finishes, and the render finishes anyway, as a cancelled
    /// synthesizer write still does. When the first chapter ends, the next
    /// one starts from its current text, in the new voice, and nothing
    /// rendered in the old voice is played; the choice is saved with the
    /// book and announced once.
    ///
    /// Speech is marked as under way without the synthesizer, and every
    /// chapter speech starts is silenced before the main run loop turns, so
    /// nothing is heard.
    ///
    /// Before the repair, rendered audio was kept and adopted for its chapter
    /// without asking what it was rendered from, and a voice change left the
    /// look-ahead alone. With those three decisions restored in
    /// `ReaderViewModel` (commits 779f7f8 and df3a159 no longer revert
    /// cleanly), this test fails with "XCTAssertNil failed" on the old voice's
    /// render signature, "Audio rendered before the voice change was
    /// played", then "The stale render kept its audio".
    func testVoiceChosenWhileTheNextChapterRendersStartsItFromItsText() throws {
        let world = try makeIntegrationWorld("Integration Look-Ahead")
        let book = try world.importBook(from: writeHarbourLogEPUB())
        let renders = HeldRenderQueue()
        let reader = world.openReader(for: book, renderScheduler: renders)
        waitForReaderToLoad(reader)
        let oldVoice = reader.speechService.currentVoice
        let newVoice = try anotherVoice(than: oldVoice)

        var stale: HeldRenderQueue.Render?
        var started: (chapter: Int, isSpeaking: Bool, spoken: String?, adopted: SpeechRenderSignature?)?
        let recorder = try recordingAnnouncements {
            // The first chapter is under way, so the next one is queued to
            // render ahead and starts rendering.
            reader.speechService.isSpeaking = true
            reader.preRenderNextChapter()
            stale = try XCTUnwrap(renders.startNext(), "The next chapter was not rendered ahead")

            // The listener chooses another voice for this book meanwhile, and
            // the render started in the old voice finishes anyway.
            reader.setLocalVoice(newVoice)
            renders.finishRunning()

            // The first chapter ends the way the speech service reports it.
            reader.speechService.stop()
            reader.speechService.onUtteranceFinished?()
            started = (
                reader.currentChapterIndex,
                reader.speechService.isSpeaking,
                reader.currentTransformation?.modifiedText,
                reader.speechService.audioEngine.renderedSignature
            )
            // Silence the chapter before the main run loop turns; the new
            // generation keeps any queued render from starting.
            reader.stop()
            reader.chapterPlaybackGeneration += 1
        }

        let staleRender = try XCTUnwrap(stale)
        let start = try XCTUnwrap(started)
        XCTAssertEqual(staleRender.request.voice?.identifier, oldVoice?.identifier)
        XCTAssertEqual(start.chapter, 1, "The next chapter did not start")
        XCTAssertTrue(start.isSpeaking, "The next chapter did not start speaking")
        XCTAssertNil(start.adopted, "Audio rendered before the voice change was played")
        XCTAssertFalse(staleRender.engine.hasRenderedAudio, "The stale render kept its audio")
        XCTAssertEqual(start.spoken, reader.preparedSpeech(forChapterAt: 1)?.text)
        XCTAssertEqual(reader.speechService.currentVoice?.identifier, newVoice.identifier)
        XCTAssertEqual(world.library.bookByID(book.id)?.localVoiceID, newVoice.identifier, "The voice was not saved")
        XCTAssertEqual(recorder.announcements.map(\.message), ["Voice changed to \(newVoice.name)"])
    }

    // MARK: - Fixtures

    /// A three-chapter book of harbour notes, each chapter long enough to be
    /// rendered ahead, written as an EPUB in a folder of this test's own.
    private func writeHarbourLogEPUB() throws -> URL {
        let epub = try makeSandboxDirectory("IntegrationLookAheadSources").appendingPathComponent("harbour-log.epub")
        try IntegrationEPUB.write(
            title: "Harbour Log",
            chapters: [
                IntegrationEPUBChapter(
                    fileName: "ch01.xhtml",
                    body: "<h1>Departure</h1><p>The ferry left the quay at noon with forty crates of oranges.</p>"
                ),
                IntegrationEPUBChapter(
                    fileName: "ch02.xhtml",
                    body: "<h1>Crossing</h1><p>Gulls circled the harbour wall. Spray rose over the bow.</p>"
                ),
                IntegrationEPUBChapter(
                    fileName: "ch03.xhtml",
                    body: "<h1>Arrival</h1><p>Lamps came on along the pier as the lines were made fast.</p>"
                ),
            ],
            contents: [
                IntegrationTOCEntry(label: "Departure", target: "ch01.xhtml"),
                IntegrationTOCEntry(label: "Crossing", target: "ch02.xhtml"),
                IntegrationTOCEntry(label: "Arrival", target: "ch03.xhtml"),
            ],
            to: epub
        )
        return epub
    }

    /// An installed voice other than `current`. The test is skipped on a Mac
    /// with only one voice, where no other voice can be chosen.
    private func anotherVoice(than current: AVSpeechSynthesisVoice?) throws -> AVSpeechSynthesisVoice {
        guard let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.identifier != current?.identifier }) else {
            throw XCTSkip("Choosing another voice needs a second installed voice")
        }
        return voice
    }
}
