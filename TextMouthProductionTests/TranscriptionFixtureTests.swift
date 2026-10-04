import os
import XCTest
import ZIPFoundation
@testable import TextMouth

/// Transcription with this Mac's own recognizer (FR05), on the DAISY audio
/// books some checkouts keep in TestData: a person reading Fire Safety and
/// a synthetic voice reading Are You Ready.
///
/// Each test transcribes one short file, so the suite stays near its
/// length; set `TEXTMOUTH_TRANSCRIPTION_LONG=1` (through xcodebuild,
/// `TEST_RUNNER_TEXTMOUTH_TRANSCRIPTION_LONG=1`) to also transcribe both
/// books whole, about two minutes. Every test skips on a system older than
/// macOS 26, on a Mac that cannot run the recognizer, without an English
/// model installed, or without the fixture; none downloads a model, reserves
/// a language, or plays any audio. The recognizer's words can change as the
/// system updates its model, so the tests ask only for words any model
/// hears in these recordings, and for what every transcript must be:
/// sentences in order, each with timed words inside its file.
@MainActor
final class TranscriptionFixtureTests: XCTestCase {

    // MARK: - One File of Each Book

    /// The opening of Fire Safety, a person reading its title and author,
    /// is transcribed into sentences with timed words, as progress rises.
    func testTheOpeningOfFireSafetyIsTranscribedWithTimedWords() async throws {
        let locale = try await requireEnglishModel()
        let file = try extract(Self.fireSafetyOpening, from: try fixture(Self.fireSafety))

        let (sentences, progress) = try await transcribe(file, in: locale)

        try assertTranscript(of: sentences, from: file, contains: ["fire", "safety"])
        XCTAssertFalse(progress.isEmpty, "no progress was reported")
        XCTAssertEqual(progress, progress.sorted(), "progress went back")
    }

    /// A warning from Are You Ready, read by a synthetic voice, is
    /// transcribed the same way.
    func testAWarningFromAreYouReadyIsTranscribedWithTimedWords() async throws {
        let locale = try await requireEnglishModel()
        let file = try extract(Self.areYouReadyWarning, from: try fixture(Self.areYouReady))

        let (sentences, _) = try await transcribe(file, in: locale)

        try assertTranscript(of: sentences, from: file, contains: ["landslides", "dangerous"])
    }

    /// A book of one recorded file, transcribed by the service and saved,
    /// reads as text: its transcript.json names the model and language,
    /// its content.md holds what was heard under the book's heading, and a
    /// reader opening it shows that text while it keeps the book's audio.
    func testATranscribedRecordingReadsAsText() async throws {
        let locale = try await requireEnglishModel()
        let world = try makeIntegrationWorld("Transcription Fixture Book")
        let book = try await makeSingleFileBook(
            in: world,
            title: "Fire Safety",
            copying: try extract(Self.fireSafetyOpening, from: try fixture(Self.fireSafety))
        )
        let service = TranscriptionService(languagesToTry: { [locale.identifier(.bcp47)] })
        let progress = ProgressRecorder()

        let installation = try await service.transcribeAndSave(book, currentBook: { book }, progress: progress.record)

        guard case .found(let transcript) = TranscriptStore.read(from: book.tmbDirectory) else {
            return XCTFail("no transcript was saved")
        }
        XCTAssertEqual(transcript.model.engine, "SpeechTranscriber")
        XCTAssertEqual(transcript.locale, locale.identifier(.bcp47))
        XCTAssertEqual(transcript.files.map(\.path), ["Fire Safety.mp3"])
        XCTAssertEqual(progress.events.last?.percentDone, 100)
        let text = try XCTUnwrap(installation.text.chapterText(0)).lowercased()
        XCTAssertTrue(text.contains("fire") && text.contains("safety"), text)
        XCTAssertEqual(installation.text.index.chapters.first?.sentences.isEmpty, false)

        let reader = world.openReader(for: book)
        // Awaited rather than spun for: this test runs on the main actor as
        // a task, which a load's own hops to the main actor wait behind.
        let loaded = await waitAsync { !reader.isLoading }
        XCTAssertTrue(loaded, "the transcribed book never finished loading")
        XCTAssertNotNil(reader.content?.transcript)
        XCTAssertTrue(reader.displayVisibleTextWindow.lowercased().contains("safety"), reader.displayVisibleTextWindow)
        XCTAssertEqual(reader.chapterAudioSource(forChapterAt: 0), .file(book.bookFileURL))
    }

    // MARK: - Whole Books (Opt-In)

    /// Both books, imported as a user imports them, are transcribed whole
    /// and read as text: every file transcribed, a chapter of text for each
    /// of the book's headings, each chapter's sentences in order and inside
    /// its audio, and progress reaching the whole book. Runs only with
    /// `TEXTMOUTH_TRANSCRIPTION_LONG=1`.
    func testWholeBooksAreTranscribedAndReadAsText() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TEXTMOUTH_TRANSCRIPTION_LONG"] == "1",
            "set TEST_RUNNER_TEXTMOUTH_TRANSCRIPTION_LONG=1 to transcribe both fixture books whole"
        )
        let locale = try await requireEnglishModel()
        let world = try makeIntegrationWorld("Transcription Whole Books")
        let service = TranscriptionService(languagesToTry: { [locale.identifier(.bcp47)] })

        for name in [Self.fireSafety, Self.areYouReady] {
            // Imported as the library imports a DAISY ZIP that holds audio,
            // as an audiobook, off the main thread, which reading and
            // hashing the audio would hold up.
            let source = try fixture(name)
            let folder = world.folder.path
            let book = try await OffMainWork.runThrowing {
                try FileImportService.importDAISYAudioZipWithReport(from: source, toFolder: folder).book
            }
            world.library.library.addBook(book)
            let plan = try await OffMainWork.runThrowing { try TranscriptionPlan.make(for: book) }
            let progress = ProgressRecorder()

            let installation = try await service.transcribeAndSave(book, currentBook: { book }, progress: progress.record)

            guard case .found(let transcript) = TranscriptStore.read(from: book.tmbDirectory) else {
                return XCTFail("\(name): no transcript was saved")
            }
            XCTAssertEqual(transcript.files.map(\.path), plan.files.map(\.path), name)
            XCTAssertGreaterThan(transcript.files.filter { !$0.sentences.isEmpty }.count, plan.files.count / 2, name)
            XCTAssertEqual(installation.text.chapters.count, installation.index.chapters.count, name)
            for (number, chapter) in installation.index.chapters.enumerated() {
                let sentences = installation.text.index.chapters[number].sentences
                XCTAssertEqual(sentences.map(\.startMilliseconds), sentences.map(\.startMilliseconds).sorted(), "\(name) chapter \(number)")
                let length = Transcript.milliseconds(chapter.audio?.duration ?? 0)
                XCTAssertTrue(sentences.allSatisfy { $0.startMilliseconds <= length + 1_000 }, "\(name) chapter \(number)")
            }
            XCTAssertEqual(progress.events.last?.percentDone, 100, name)
            print("TRANSCRIPTION \(name): \(plan.files.count) files, \(Int(plan.totalDuration)) s of audio in "
                + "\(Int(progress.events.last?.elapsed ?? 0)) s, \(installation.text.index.totalWordCount) words")
        }
    }

    // MARK: - Fixtures

    /// The Fire Safety archive and its opening file, 6 seconds long.
    static let fireSafety = "fire-safety-d202-audio.zip"
    static let fireSafetyOpening = "FireSafety/01_Fire_Safety__by_Wendy_Blaxland.mp3"
    /// The Are You Ready archive and its warning about landslides, 15
    /// seconds long.
    static let areYouReady = "are-you-ready-d3-audio.zip"
    static let areYouReadyWarning = "Are_you_ready_z3986/speechgen0029.mp3"

    /// The English model's locale, skipping the test unless this Mac can
    /// transcribe English now: macOS 26, a Mac that runs the recognizer,
    /// and the English model installed. Nothing is downloaded to get it.
    private func requireEnglishModel() async throws -> Locale {
        try XCTSkipUnless(
            TranscriptionAvailability.systemSupport == .available,
            "transcription needs macOS 26 on a Mac that runs its model"
        )
        guard case .installed(let locale) = await TranscriptionAvailability.modelStatus(for: Locale(identifier: "en-US")) else {
            throw XCTSkip("the English speech model is not installed on this Mac, and the tests never download it")
        }
        return locale
    }

    /// The TestData archive `name`, skipping the test when this checkout
    /// does not keep it (git ignores these archives).
    private func fixture(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: testFilePath(name))
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path), "\(name) is not in this checkout's TestData")
        return url
    }

    /// The archive entry `path`, extracted from the archive at `archive`
    /// into a sandbox folder of this test's own.
    private func extract(_ path: String, from archive: URL) throws -> URL {
        let opened = try ArchiveExtractor.open(archive)
        let entry = try XCTUnwrap(opened[path], "\(path) is not in \(archive.lastPathComponent)")
        let destination = try makeSandboxDirectory("transcription-fixture")
            .appendingPathComponent((path as NSString).lastPathComponent)
        _ = try opened.extract(entry, to: destination)
        return destination
    }

    /// The sentences this Mac's engine hears in `file`, in `locale`, and
    /// every progress report it gave, in order.
    private func transcribe(_ file: URL, in locale: Locale) async throws -> ([TranscriptSentence], [TimeInterval]) {
        let engine = SystemTranscriptionEngine()
        let model = try await engine.prepare(locale: locale)
        let reports = OSAllocatedUnfairLock(initialState: [TimeInterval]())
        let sentences = try await engine.transcribe(fileAt: file, locale: Locale(identifier: model.locale)) { seconds in
            reports.withLock { $0.append(seconds) }
        }
        return (sentences, reports.withLock { $0 })
    }

    /// Asserts that `sentences`, heard in `file`, are a transcript: at least
    /// one, in order, each timed inside the file with timed words, valid as
    /// a transcript is, and holding each of `words`, lowercased.
    private func assertTranscript(
        of sentences: [TranscriptSentence],
        from file: URL,
        contains words: [String],
        line: UInt = #line
    ) throws {
        let duration = Transcript.milliseconds(try TranscriptionPlan.duration(ofAudioFileAt: file))
        XCTAssertFalse(sentences.isEmpty, "nothing was heard", line: line)
        XCTAssertNil(
            TranscriptFixtures.transcript([(path: file.lastPathComponent, duration: duration, sentences: sentences)])
                .validationFailure(),
            line: line
        )
        for sentence in sentences {
            XCTAssertFalse(sentence.words.isEmpty, "a sentence without timed words", line: line)
            XCTAssertLessThanOrEqual(sentence.endMilliseconds, duration + 1_000, line: line)
        }
        let heard = sentences.map(\.text).joined(separator: " ").lowercased()
        for word in words {
            XCTAssertTrue(heard.contains(word), "\(word) was not heard in: \(heard)", line: line)
        }
    }

    /// An audiobook of one file, a copy of `source`, in a package of its
    /// own in `world`'s folder, indexed as an import indexes it, off the
    /// main thread, and listed in the library.
    private func makeSingleFileBook(in world: IntegrationWorld, title: String, copying source: URL) async throws -> Book {
        let packageName = "\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: world.folder.path, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let audio = package.appendingPathComponent("\(title).mp3")
        try FileManager.default.copyItem(at: source, to: audio)
        let book = Book(
            title: title,
            format: .audio,
            filePath: audio.path,
            md5Hash: try FileImportService.md5Hash(of: audio),
            folderPath: world.folder.path,
            tmbDirectoryName: packageName
        )
        // Reading the audio waits for AVFoundation, which the main thread
        // must not do.
        try await OffMainWork.runThrowing {
            try book.saveBookInfoThrowing(contentIndex: try BookContentAnalysisService.load(book: book).index)
        }
        world.library.library.addBook(book)
        return book
    }

    /// Waits, a few milliseconds at a time and at most ten seconds, until
    /// `condition` holds, letting the main actor run meanwhile, and says
    /// whether it did.
    private func waitAsync(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1_000 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}
