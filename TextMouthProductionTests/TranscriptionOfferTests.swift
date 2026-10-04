import Combine
import XCTest
@testable import TextMouth

/// The offer to transcribe after an import (FR05): with "Offer to
/// transcribe after importing an audiobook" on, each audiobook an import
/// adds is offered for transcription as an import question, after the
/// import's own questions, naming the book and the estimate, with
/// Transcribe and Not Now. Transcribe hands the book to the Library window
/// that asked, which opens the same Transcribe Audio sheet as the command;
/// Not Now leaves the book alone. With the setting off, or for a text book,
/// nothing is offered.
///
/// Each test imports real files through the library's own import queue, as
/// Open Book... does, into a library folder of its own. Nothing is
/// transcribed here; the sheet the offer opens is tested with the command's.
@MainActor
final class TranscriptionOfferTests: XCTestCase {

    /// An audiobook imported while the offer is on is offered for
    /// transcription after its own question, about its original file; the
    /// question names the book, and Transcribe hands it on, once.
    func testAnAudiobookIsOfferedAfterItsImportsOwnQuestion() throws {
        let scene = try makeScene()
        scene.model.offersTranscription = { $0.format.isAudio }
        useAfterImportingBehavior(.askEachTime)
        let source = try writeAudio("Harbour Bells", in: scene)
        var accepted: [TranscriptionOfferAcceptance] = []
        let subscription = scene.model.acceptedTranscriptionOffers.sink { accepted.append($0) }
        defer { subscription.cancel() }

        scene.model.importFiles(urls: [source], toFolder: scene.folder.path)
        drainImports(of: scene.model)

        XCTAssertEqual(questions(of: scene.model), ["original: Harbour Bells.wav", "transcribe: Harbour Bells"])
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.cancel).succeeded)
        let offer = try XCTUnwrap(scene.model.importDecisions.current)
        let wording = try XCTUnwrap(scene.model.currentImportDecisionWording)
        XCTAssertEqual(wording.title, "Transcribe the Audiobook? 2 of 2")
        XCTAssertTrue(wording.message.hasPrefix("“Harbour Bells” was imported"), wording.message)
        XCTAssertTrue(wording.message.hasSuffix("Transcribe it now?"), wording.message)
        XCTAssertFalse(ImportDecisionAnswer.deleteOriginal.fits(offer.kind))
        XCTAssertTrue(ImportDecisionAnswer.transcribe.fits(offer.kind))

        XCTAssertTrue(scene.model.answerCurrentImportDecision(.transcribe).succeeded)

        let book = try XCTUnwrap(scene.model.library.books.first { $0.title == "Harbour Bells" })
        XCTAssertEqual(accepted, [TranscriptionOfferAcceptance(bookID: book.id, origin: nil)])
        XCTAssertTrue(scene.model.importDecisions.isEmpty)
    }

    /// Not Now leaves the audiobook as it is: nothing is handed on.
    func testNotNowLeavesTheAudiobookAlone() throws {
        let scene = try makeScene()
        scene.model.offersTranscription = { $0.format.isAudio }
        useAfterImportingBehavior(.keepOriginal)
        let source = try writeAudio("Harbour Bells", in: scene)
        var accepted: [TranscriptionOfferAcceptance] = []
        let subscription = scene.model.acceptedTranscriptionOffers.sink { accepted.append($0) }
        defer { subscription.cancel() }

        scene.model.importFiles(urls: [source], toFolder: scene.folder.path)
        drainImports(of: scene.model)

        XCTAssertEqual(questions(of: scene.model), ["transcribe: Harbour Bells"])
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.cancel).succeeded)
        XCTAssertEqual(accepted, [])
        XCTAssertTrue(scene.model.importDecisions.isEmpty)
    }

    /// An offer whose book left the library before it was answered hands
    /// nothing on.
    func testAnOfferForABookNoLongerInTheLibraryHandsNothingOn() throws {
        let scene = try makeScene()
        scene.model.offersTranscription = { $0.format.isAudio }
        useAfterImportingBehavior(.keepOriginal)
        let source = try writeAudio("Harbour Bells", in: scene)
        var accepted: [TranscriptionOfferAcceptance] = []
        let subscription = scene.model.acceptedTranscriptionOffers.sink { accepted.append($0) }
        defer { subscription.cancel() }
        scene.model.importFiles(urls: [source], toFolder: scene.folder.path)
        drainImports(of: scene.model)

        scene.model.library = Library()
        XCTAssertTrue(scene.model.answerCurrentImportDecision(.transcribe).succeeded)

        XCTAssertEqual(accepted, [])
    }

    /// With the setting off, as it is until turned on, an audiobook import
    /// asks nothing; with it on, a text book is never offered, and neither
    /// is anything on a Mac that cannot transcribe.
    func testNothingIsOfferedWhileTheSettingIsOffOrForATextBook() throws {
        preservePreferences([TranscriptionPreferences.offerAfterImport.key])
        let store = TextMouthRuntime.current.preferences
        let audiobook = Book(title: "Harbour Bells", format: .audio, filePath: "/nonexistent/bells.mp3", md5Hash: "bells",
                             tmbDirectoryName: "bells.tmb")
        let textBook = Book(title: "Lock Keeper", format: .markdown, filePath: "/nonexistent/lock.md", md5Hash: "lock",
                            tmbDirectoryName: "lock.tmb")

        store.removeObject(forKey: TranscriptionPreferences.offerAfterImport.key)
        XCTAssertFalse(TranscriptionOffers.offersTranscription(of: audiobook), "offered with the setting off")

        TranscriptionPreferences.offerAfterImport.write(true, to: store)
        XCTAssertFalse(TranscriptionOffers.offersTranscription(of: textBook))
        XCTAssertEqual(
            TranscriptionOffers.offersTranscription(of: audiobook),
            TranscriptionAvailability.systemSupport == .available
        )

        let scene = try makeScene()
        useAfterImportingBehavior(.keepOriginal)
        scene.model.offersTranscription = { _ in false }
        scene.model.importFiles(urls: [try writeAudio("Harbour Bells", in: scene)], toFolder: scene.folder.path)
        drainImports(of: scene.model)
        XCTAssertEqual(questions(of: scene.model), [])
    }

    /// The offer's words: the book, its audio, the estimate, and its
    /// buttons, each with a hint.
    func testTheOffersWords() {
        XCTAssertEqual(
            TranscriptionWording.offerMessage(bookTitle: "Moby-Dick", audioSeconds: 22_320),
            "“Moby-Dick” was imported, with 6 hours, 12 minutes of audio. Transcribing it takes about 6 minutes. "
                + "Transcribe it now?"
        )
        XCTAssertEqual(TranscriptionWording.offerMessage(bookTitle: "Moby-Dick", audioSeconds: nil),
                       "“Moby-Dick” was imported. Transcribe it now?")
        XCTAssertEqual(ImportDecisionChoiceWording.transcribe.title, "Transcribe")
        XCTAssertEqual(ImportDecisionChoiceWording.notNow.title, "Not Now")
        XCTAssertFalse(ImportDecisionChoiceWording.transcribe.hint.isEmpty)
        XCTAssertFalse(ImportDecisionChoiceWording.notNow.hint.isEmpty)
    }

    // MARK: - Fixtures

    /// A library model of this test's own, inert, with no books, importing
    /// into a library folder of its own from a sandbox folder of sources.
    private struct Scene {
        let folder: IntegrationLibraryFolder
        let sources: URL
        let model: LibraryViewModel
    }

    /// A scene of this test's own. The library index is put back, and
    /// deletions are kept out of the Trash, until the test ends; the books
    /// it would open are recorded instead.
    private func makeScene() throws -> Scene {
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        keepDeletionsOutOfTheTrash()
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        _ = OpenedBooks(recordingFor: model)
        return Scene(
            folder: makeIntegrationLibraryFolder("Transcription Offers"),
            sources: try makeSandboxDirectory("TranscriptionOfferSources"),
            model: model
        )
    }

    /// A second of silence as a WAV file named `title`, outside the
    /// library, which imports as an audiobook.
    private func writeAudio(_ title: String, in scene: Scene) throws -> URL {
        let url = scene.sources.appendingPathComponent("\(title).wav")
        try AudioTestFixtures.writeSilence(to: url, duration: 1)
        return url
    }

    /// Waits until every import `model` has queued so far has run, then
    /// until the main queue has run the work those imports sent it.
    private func drainImports(of model: LibraryViewModel) {
        let imported = expectation(description: "the import queue ran everything queued before")
        model.importOperationQueue.enqueue { imported.fulfill() }
        wait(for: [imported], timeout: 60)
        let mainQueue = expectation(description: "the main queue ran what the imports sent it")
        DispatchQueue.main.async { mainQueue.fulfill() }
        wait(for: [mainQueue], timeout: 10)
    }

    /// The questions `model` is waiting to ask, in order, each named by its
    /// kind and what it is about.
    private func questions(of model: LibraryViewModel) -> [String] {
        model.importDecisions.waiting.map { decision in
            switch decision.kind {
            case .duplicate(let duplicate): return "duplicate: \(duplicate.book.title)"
            case .originalFile(let original): return "original: \(original.url.lastPathComponent)"
            case .zipFolder(let batch): return "folder: \(batch.archiveURL.lastPathComponent)"
            case .transcriptionOffer(let offer): return "transcribe: \(offer.bookTitle)"
            }
        }
    }
}
