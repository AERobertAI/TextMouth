import AVFoundation
import XCTest
@testable import TextMouth

/// Saving edited audio into a book (FR04), through an edit session and the
/// library: the book's file is replaced by the edited audio, to the sample;
/// the original is kept first under the policy, so an undo saved later puts
/// the book's audio back exactly; the library publishes the new length and
/// fingerprint; a transcript of the old audio no longer matches it and the
/// reading text kept of the book is dropped; a book open in a reader is
/// refused; and a file whose format TextMouth can't write again is saved
/// under a new name, the old file going only once the record names the new.
@MainActor
final class AudioEditSaveTests: XCTestCase {

    /// Frames a second of the books these tests write.
    private static let rate = 8_000.0

    // MARK: - Saving

    /// A cut saved into a WAVE book removes exactly its samples from the
    /// book's file, keeps the original first, and gives the library the new
    /// length and fingerprint; undoing it and saving again puts every sample
    /// back.
    func testAnEditIsSavedIntoTheBooksFileAndUndoneFromTheOriginal() async throws {
        let (model, book, package) = try makeLibraryBook(named: "Canal Survey.wav", frames: 80_000)
        let session = try await AudioEditSession.open(bookID: book.id, in: model)
        defer { session.close() }

        try await session.perform(.cut(AudioTimeRange(start: 1, end: 2)))
        XCTAssertEqual(session.duration, 9)
        XCTAssertTrue(session.hasUnsavedEdits)
        let outcome = try await session.save()

        XCTAssertTrue(outcome.rendered)
        XCTAssertEqual(outcome.duration, 9, accuracy: 0.000_1)
        let samples = try AudioTestFixtures.floatSamples(of: book.bookFileURL)
        XCTAssertEqual(samples.count, 72_000)
        XCTAssertEqual(samples[checked: 7_999].map(AudioTestFixtures.rampSample), .frame(.book, 7_999))
        XCTAssertEqual(samples[checked: 8_000].map(AudioTestFixtures.rampSample), .frame(.book, 16_000))
        XCTAssertEqual(samples[checked: 71_999].map(AudioTestFixtures.rampSample), .frame(.book, 79_999))
        let saved = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(try XCTUnwrap(saved.audioDuration), 9, accuracy: 0.01)
        XCTAssertEqual(saved.md5Hash, try FileImportService.md5Hash(of: book.bookFileURL))
        XCTAssertFalse(session.hasUnsavedEdits)

        let original = try XCTUnwrap(session.list.original)
        XCTAssertEqual(original.file, "audioEdits/originals/Canal Survey.wav")
        XCTAssertEqual(try AudioTestFixtures.floatSamples(of: package.appendingPathComponent(original.file)).count, 80_000)
        XCTAssertTrue(session.canUndo, "the original keeps the saved cut undoable")

        try await session.undo()
        XCTAssertEqual(session.duration, 10)
        try await session.save()
        let restored = try AudioTestFixtures.floatSamples(of: book.bookFileURL)
        XCTAssertEqual(restored.count, 80_000)
        XCTAssertEqual(restored.indices.filter { AudioTestFixtures.rampSample(restored[$0]) != .frame(.book, $0) }, [])
    }

    /// Saving a book open in a reader is refused, and its file stays.
    func testSavingABookOpenInAReaderIsRefused() async throws {
        let (model, book, _) = try makeLibraryBook(named: "Canal Survey.wav", frames: 16_000)
        let session = try await AudioEditSession.open(bookID: book.id, in: model)
        defer { session.close() }
        try await session.perform(.trimEnd(at: 1))
        model.openBookIDs = [book.id]

        do {
            try await session.save()
            XCTFail("a book open in a reader was saved")
        } catch {
            XCTAssertEqual(error as? AudioEditError, .bookIsOpen)
        }
        XCTAssertEqual(try AudioTestFixtures.floatSamples(of: book.bookFileURL).count, 16_000)
        XCTAssertTrue(session.hasUnsavedEdits)
    }

    /// Once the book's audio changes, a transcript made of the old audio no
    /// longer matches its fingerprint, so it is stale, and the reading text
    /// kept of the book is dropped.
    func testSavingMakesATranscriptStaleAndDropsTheReadingText() async throws {
        let (model, book, _) = try makeLibraryBook(named: "Canal Survey.wav", frames: 16_000)
        let fingerprint = try XCTUnwrap(FileFingerprint(of: book.bookFileURL, hasher: .md5))
        let transcribed = [TranscriptAudioFile(path: "Canal Survey.wav", fingerprint: fingerprint)]
        let index = BookContentIndex.build(
            fromChapters: [Chapter(title: "Canal Survey", text: String(repeating: " ", count: 20), headings: [])],
            format: .audio
        )
        XCTAssertEqual(audioCheck(transcribed, book: book, index: index), "current")
        let kept = ReadingTextCache.shared.url(for: book.id)
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("kept reading text".utf8).write(to: kept)

        let session = try await AudioEditSession.open(bookID: book.id, in: model)
        defer { session.close() }
        try await session.perform(.insertSilence(at: 0.5, duration: 0.25))
        try await session.save()

        let saved = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(audioCheck(transcribed, book: saved, index: index), "changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.path), "the reading text outlived the audio")
    }

    /// Saving with nothing waiting changes nothing.
    func testSavingWithNothingWaitingChangesNothing() async throws {
        let (model, book, _) = try makeLibraryBook(named: "Canal Survey.wav", frames: 16_000)
        let before = try Data(contentsOf: book.bookFileURL)
        let session = try await AudioEditSession.open(bookID: book.id, in: model)
        defer { session.close() }

        let outcome = try await session.save()

        XCTAssertFalse(outcome.rendered)
        XCTAssertEqual(try Data(contentsOf: book.bookFileURL), before)
    }

    /// A raw AAC book, which TextMouth can't write again as it is, is saved
    /// as AAC in an .m4a file: the book's record names the new file, the old
    /// one is deleted after that, and the edit list follows the file.
    func testAFileOfAFormatTextMouthCantWriteIsSavedUnderANewName() async throws {
        let (model, book, package) = try makeLibraryBook(named: "Lock Keeper's Log.aac", frames: 24_000, writer: .adts)
        let session = try await AudioEditSession.open(bookID: book.id, in: model)
        defer { session.close() }
        try await session.perform(.trimEnd(at: 2))

        let outcome = try await session.save()

        XCTAssertEqual(outcome.audioFile, "Lock Keeper's Log.m4a")
        XCTAssertEqual(session.audioFile, "Lock Keeper's Log.m4a")
        let saved = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(saved.bookFileURL.lastPathComponent, "Lock Keeper's Log.m4a")
        let duration = try await AVURLAsset(url: saved.bookFileURL).load(.duration).seconds
        XCTAssertEqual(duration, 2, accuracy: 0.03)
        XCTAssertFalse(FileManager.default.fileExists(atPath: book.bookFileURL.path), "the old file stayed")
        XCTAssertEqual(try StoredBookRecord.read(from: package).info.metadata.originalFileName, "Lock Keeper's Log.m4a")
        XCTAssertEqual(session.list.audioFile, "Lock Keeper's Log.m4a")
    }

    // MARK: - Helpers

    /// How a book's file is written.
    private enum Writer {
        /// An identity ramp of 32-bit floats, as the extension names the
        /// file type.
        case ramp
        /// AAC silence in an ADTS stream (raw AAC, ".aac").
        case adts
    }

    /// A library of one audiobook named `name`, `frames` frames long, in a
    /// package in a folder of the sandbox's library of this test's own, and
    /// its package.
    private func makeLibraryBook(named name: String, frames: Int, writer: Writer = .ramp) throws -> (LibraryViewModel, Book, URL) {
        let folderPath = "Audio Edits \(UUID().uuidString.prefix(8))"
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        let package = folder.appendingPathComponent("Canal-Unknown-1-\(UUID().uuidString.prefix(8)).tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library()
        let book = Book(
            title: (name as NSString).deletingPathExtension,
            format: .audio,
            filePath: package.appendingPathComponent(name).path,
            md5Hash: "before-\(UUID().uuidString)",
            folderPath: folderPath,
            tmbDirectoryName: package.lastPathComponent
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: folder)
            AudioEditScratch.remove(for: book.id)
            ReadingTextCache.shared.remove(bookID: book.id)
        }
        switch writer {
        case .ramp:
            try AudioTestFixtures.writeIdentityRamp(to: book.bookFileURL, frames: frames, sampleRate: Self.rate)
        case .adts:
            try writeADTSSilence(to: book.bookFileURL, frames: frames)
        }
        model.library.addBook(book)
        return (model, book, package)
    }

    /// Writes `frames` frames of AAC silence to `url` as an ADTS stream, the
    /// raw AAC a ".aac" file holds.
    private func writeADTSSilence(to url: URL, frames: Int) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.rate, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        try XCTUnwrap(buffer.floatChannelData)[0].update(repeating: 0, count: frames)
        let file = try AVAudioFile(
            forWriting: url,
            settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: Self.rate, AVNumberOfChannelsKey: 1],
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    /// What the transcription engine's audio check makes of `files`, a
    /// transcript's record of `book`'s audio: "current" or "changed".
    private func audioCheck(_ files: [TranscriptAudioFile], book: Book, index: BookContentIndex) -> String {
        switch TranscriptTextLoader.audioCheck(of: files, for: book, audioIndex: index, isDataless: { _ in false }, hasher: .md5) {
        case .current: return "current"
        case .changed: return "changed"
        }
    }
}
