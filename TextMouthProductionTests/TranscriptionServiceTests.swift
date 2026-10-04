import os
import Speech
import XCTest
@testable import TextMouth

/// The transcription service (FR05) with an engine that follows a script:
/// files transcribed in the order the book plays them, progress as results
/// arrive, cancellation within a second, one transcription at a time, and
/// every refusal named before any audio is transcribed. The recognizer's
/// own results are turned into sentences by `TranscriptSentenceBuilder`,
/// tested here with results made by hand, and what this Mac offers is
/// checked against the system it runs on. No test here downloads a model.
@MainActor
final class TranscriptionServiceTests: XCTestCase {

    // MARK: - Transcribing a Book

    /// Each file is transcribed in the order the book plays it and kept with
    /// its place in the book, its length, and its fingerprint; the
    /// transcript names the language and model the engine resolved and this
    /// build, and nothing is written into the book's package.
    func testEachFileIsTranscribedInTheOrderTheBookPlaysThem() async throws {
        let world = try makeIntegrationWorld("Transcription Order")
        let book = try world.makeSilentAudioBook(title: "Two Tracks", trackDurations: [3, 2])
        let engine = ScriptedTranscriptionEngine(sentences: Self.script)
        let service = TranscriptionService(engine: engine, languagesToTry: { ["en-GB"] })
        let progress = ProgressRecorder()

        let transcript = try await service.transcribe(book, progress: progress.record)

        XCTAssertEqual(transcript.files.map(\.path), ["01.wav", "02.wav"])
        XCTAssertEqual(transcript.files.map(\.durationMilliseconds), [3_000, 2_000])
        XCTAssertEqual(transcript.files.map(\.sentences), [Self.script["01.wav"], Self.script["02.wav"]])
        let tracks = URL(fileURLWithPath: book.filePath, isDirectory: true)
        for file in transcript.files {
            XCTAssertEqual(file.fingerprint, FileFingerprint(of: tracks.appendingPathComponent(file.path), hasher: .md5))
        }
        XCTAssertEqual(transcript.version, Transcript.currentVersion)
        XCTAssertEqual(transcript.locale, "en-GB")
        XCTAssertEqual(transcript.model, ScriptedTranscriptionEngine.model)
        XCTAssertEqual(transcript.app, .current)
        XCTAssertEqual(transcript.createdAt.timeIntervalSince1970, transcript.createdAt.timeIntervalSince1970.rounded(.down))
        XCTAssertNil(transcript.validationFailure())
        let calls = await engine.calls.entries
        XCTAssertEqual(calls, ["prepare en-GB", "transcribe 01.wav", "transcribe 02.wav"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: book.tmbDirectory.path).sorted(),
                       ["Tracks", "bookInfo.json", "contentIndex.json"])
    }

    /// Progress names the file being transcribed, out of how many, and how
    /// much of the book's audio is done, as each file starts and each result
    /// arrives, rising throughout, and ends at the whole book.
    func testProgressRisesThroughTheBookAsResultsArrive() async throws {
        let world = try makeIntegrationWorld("Transcription Progress")
        let book = try world.makeSilentAudioBook(title: "Two Tracks", trackDurations: [3, 2])
        let service = TranscriptionService(
            engine: ScriptedTranscriptionEngine(sentences: Self.script),
            languagesToTry: { ["en-US"] }
        )
        let progress = ProgressRecorder()

        _ = try await service.transcribe(book, progress: progress.record)

        let events = progress.events
        XCTAssertEqual(events.map(\.fileIndex), [0, 0, 0, 1, 1, 2])
        XCTAssertEqual(events.map(\.secondsDone), [0, 1.2, 2.4, 3, 4.5, 5])
        XCTAssertTrue(events.allSatisfy { $0.fileCount == 2 && $0.secondsTotal == 5 })
        XCTAssertEqual(events.map(\.elapsed), events.map(\.elapsed).sorted())
        XCTAssertEqual(events.last?.fractionDone, 1)
        XCTAssertEqual(events.last?.percentDone, 100)
        XCTAssertEqual(events[3].percentDone, 60)
    }

    /// Cancelling the task that awaits a transcription stops it within a
    /// second, says it was cancelled, writes nothing, and frees the service
    /// for the next transcription.
    func testCancellingStopsWithinASecondAndLeavesNothingBehind() async throws {
        let world = try makeIntegrationWorld("Transcription Cancel")
        let book = try world.makeSilentAudioBook(title: "Long Track", trackDurations: [20])
        let service = TranscriptionService(
            engine: ScriptedTranscriptionEngine(sentences: ["01.wav": Self.longScript], pause: .milliseconds(50)),
            languagesToTry: { ["en-US"] }
        )
        let progress = ProgressRecorder()
        let transcription = Task { try await service.transcribe(book, progress: progress.record) }
        let started = await waitAsync { progress.events.count > 2 }
        XCTAssertTrue(started, "the transcription never started")

        let clock = ContinuousClock()
        let cancelled = clock.now
        transcription.cancel()
        let outcome = await transcription.result

        XCTAssertLessThan(clock.now - cancelled, .seconds(1))
        XCTAssertThrowsError(try outcome.get()) { error in
            XCTAssertEqual(error as? TranscriptionError, .cancelled)
        }
        XCTAssertLessThan(progress.events.count, Self.longScript.count, "the transcription ran to its end")
        let isTranscribing = await service.isTranscribing
        XCTAssertFalse(isTranscribing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: TextMouthPaths.transcriptPath(in: book.tmbDirectory).path))
    }

    /// One transcription runs at a time: a second, asked for while one
    /// runs, is refused naming the book under way.
    func testOneTranscriptionRunsAtATime() async throws {
        let world = try makeIntegrationWorld("Transcription One at a Time")
        let first = try world.makeSilentAudioBook(title: "First Book", trackDurations: [20])
        let second = try world.makeSilentAudioBook(title: "Second Book", trackDurations: [1])
        let service = TranscriptionService(
            engine: ScriptedTranscriptionEngine(sentences: ["01.wav": Self.longScript], pause: .milliseconds(50)),
            languagesToTry: { ["en-US"] }
        )
        let progress = ProgressRecorder()
        let transcription = Task { try await service.transcribe(first, progress: progress.record) }
        let started = await waitAsync { progress.events.count > 1 }
        XCTAssertTrue(started, "the first transcription never started")

        do {
            _ = try await service.transcribe(second)
            XCTFail("a second transcription ran beside the first")
        } catch {
            XCTAssertEqual(error as? TranscriptionError, .busy("First Book"))
            XCTAssertEqual(
                error.localizedDescription,
                "TextMouth is already transcribing First Book. Try again when that finishes."
            )
        }
        transcription.cancel()
        _ = await transcription.result
        let isTranscribing = await service.isTranscribing
        XCTAssertFalse(isTranscribing)
    }

    /// A book with a file only in the cloud is refused before any audio is
    /// transcribed, naming the file by its place in the book.
    func testAFileOnlyInTheCloudIsRefusedBeforeAnyIsTranscribed() async throws {
        let world = try makeIntegrationWorld("Transcription Cloud")
        let book = try world.makeSilentAudioBook(title: "Two Tracks", trackDurations: [3, 2])
        let engine = ScriptedTranscriptionEngine(sentences: Self.script)
        let service = TranscriptionService(
            engine: engine,
            planner: { book in
                try TranscriptionPlan.make(for: book, isDataless: { url in url.lastPathComponent == "02.wav" })
            },
            languagesToTry: { ["en-US"] }
        )

        await assertTranscription(of: book, by: service, fails: .fileInCloud("02.wav"))

        let calls = await engine.calls.entries
        XCTAssertEqual(calls, ["prepare en-US"])
    }

    /// A file that cannot be read as audio is named by its place in the
    /// book, before any audio is transcribed.
    func testAnUnreadableFileIsNamedByItsPlaceInTheBook() async throws {
        let world = try makeIntegrationWorld("Transcription Unreadable")
        let book = try world.makeSilentAudioBook(title: "Two Tracks", trackDurations: [3, 2])
        let damaged = URL(fileURLWithPath: book.filePath).appendingPathComponent("02.wav")
        try Data("not audio at all".utf8).write(to: damaged)
        let engine = ScriptedTranscriptionEngine(sentences: Self.script)
        let service = TranscriptionService(engine: engine, languagesToTry: { ["en-US"] })

        await assertTranscription(
            of: book,
            by: service,
            fails: .unreadableFile(file: "02.wav", reason: TranscriptionError.unreadableAudioReason)
        )
        let calls = await engine.calls.entries
        XCTAssertEqual(calls, ["prepare en-US"])
    }

    /// A language whose model is not on this Mac is reported before any of
    /// the book is read: no download is started, and no file transcribed.
    func testAModelNotOnThisMacIsReportedBeforeAnythingIsRead() async throws {
        let world = try makeIntegrationWorld("Transcription No Model")
        let book = try world.makeSilentAudioBook(title: "Two Tracks", trackDurations: [3, 2])
        let refusal = TranscriptionError.modelNotInstalled("English (India)")
        let engine = ScriptedTranscriptionEngine(sentences: Self.script, refusal: refusal)
        let planned = OSAllocatedUnfairLock(initialState: 0)
        let service = TranscriptionService(
            engine: engine,
            planner: { book in
                planned.withLock { $0 += 1 }
                return try TranscriptionPlan.make(for: book)
            },
            languagesToTry: { ["en-IN"] }
        )

        await assertTranscription(of: book, by: service, fails: refusal)

        XCTAssertEqual(planned.withLock { $0 }, 0)
        let calls = await engine.calls.entries
        XCTAssertEqual(calls, ["prepare en-IN"])
    }

    /// The system's English, which nobody chose, gives way to US English
    /// when the recognizer does not support it; a language someone chose is
    /// refused instead.
    func testAnUnsupportedSystemEnglishGivesWayToUSEnglish() async throws {
        let world = try makeIntegrationWorld("Transcription Fallback")
        let book = try world.makeSilentAudioBook(title: "Two Tracks", trackDurations: [3, 2])
        let engine = ScriptedTranscriptionEngine(sentences: Self.script, unsupported: ["en-DE", "en-FR"])
        let fallingBack = TranscriptionService(engine: engine, languagesToTry: { ["en-DE", "en-US"] })

        let transcript = try await fallingBack.transcribe(book)

        XCTAssertEqual(transcript.locale, "en-US")
        let calls = await engine.calls.entries
        XCTAssertEqual(Array(calls.prefix(2)), ["prepare en-DE", "prepare en-US"])
        await assertTranscription(
            of: book,
            by: TranscriptionService(engine: engine, languagesToTry: { ["en-DE", "en-US"] }),
            language: "en-FR",
            fails: .unsupportedLanguage(TranscriptionLanguage.name(of: "en-FR"))
        )
    }

    /// Only an audiobook can be transcribed.
    func testOnlyAudiobooksCanBeTranscribed() async throws {
        let book = Book(title: "Plain Text", format: .txt, filePath: "/nonexistent/plain.txt", md5Hash: "text")
        let service = TranscriptionService(
            engine: ScriptedTranscriptionEngine(sentences: [:]),
            languagesToTry: { ["en-US"] }
        )

        await assertTranscription(of: book, by: service, fails: .notAnAudiobook)
    }

    /// Every refusal and failure says what went wrong in plain words.
    func testErrorsNameTheirCausePlainly() {
        let cases: [(TranscriptionError, String)] = [
            (.needsNewerSystem, "Transcription needs macOS 26 or later."),
            (.unavailableOnThisMac, "This Mac can't run the speech model that transcription uses."),
            (.unsupportedLanguage("Klingon"), "Transcription doesn't support Klingon."),
            (
                .modelNotInstalled("English (India)"),
                "The speech model for English (India) isn't on this Mac yet. It needs to be downloaded first."
            ),
            (.notAnAudiobook, "Only audiobooks can be transcribed."),
            (.noAudio, "This audiobook has no audio to transcribe."),
            (.fileInCloud("Disc 2/03.mp3"), "“Disc 2/03.mp3” is only in the cloud. Download the book, then transcribe it."),
            (
                .unreadableFile(file: "03.mp3", reason: TranscriptionError.unreadableAudioReason),
                "“03.mp3” couldn't be read: it is damaged, unreadable, or not an audio file."
            ),
            (.cancelled, "Transcription was cancelled."),
            (.recognitionFailed("the speech recognizer stopped"), "Transcription stopped: the speech recognizer stopped."),
        ]
        for (error, description) in cases {
            XCTAssertEqual(error.localizedDescription, description)
        }
    }

    // MARK: - The Language to Try

    /// A transcription in no particular language tries the language chosen,
    /// alone; with none chosen, the system's English, then US English.
    func testTheLanguagesToTryFollowTheSetting() {
        let store = makeSandboxedPreferences("transcription-languages-to-try")
        let systems = TranscriptionLanguage.defaultIdentifier
        XCTAssertEqual(
            TranscriptionLanguage.languagesToTry(in: store),
            systems == "en-US" ? ["en-US"] : [systems, "en-US"]
        )
        store.set("en-IN", forKey: "transcriptionLocale")
        XCTAssertEqual(TranscriptionLanguage.languagesToTry(in: store), ["en-IN"])
        store.set("not a language", forKey: "transcriptionLocale")
        XCTAssertEqual(TranscriptionLanguage.languagesToTry(in: store).last, "en-US")
    }

    // MARK: - Sentences from the Recognizer's Results

    /// A result's pieces become one line of single-spaced words, each word
    /// kept where it lies in the sentence, with its times in milliseconds
    /// and its confidence to three places.
    func testPiecesBecomeSingleSpacedWordsWithTheirTimes() throws {
        var builder = TranscriptSentenceBuilder(languageCode: "en")
        builder.add(TranscribedResult(start: 0, end: 3.54, pieces: [
            piece("Fire", 0, 0.84, 0.857_4),
            piece(" safety", 0.84, 1.56, 0.784),
            piece("  by\n", 1.56, 2.04, 0.872),
            piece("Wendy", 2.04, 2.28, nil),
            piece(" Blacksland.", 2.28, 3.48, 0.549),
        ]))

        let sentence = try XCTUnwrap(builder.sentences.first)
        XCTAssertEqual(builder.sentences.count, 1)
        XCTAssertEqual(sentence.text, "Fire safety by Wendy Blacksland.")
        XCTAssertEqual(sentence.startMilliseconds, 0)
        XCTAssertEqual(sentence.endMilliseconds, 3_480)
        XCTAssertEqual(sentence.words.map(\.characterOffset), [0, 5, 12, 15, 21])
        XCTAssertEqual(sentence.words.map(\.characterCount), [4, 6, 2, 5, 11])
        XCTAssertEqual(sentence.words.map(\.startMilliseconds), [0, 840, 1_560, 2_040, 2_280])
        XCTAssertEqual(sentence.words.map(\.confidence), [0.857, 0.784, 0.872, nil, 0.549])
        XCTAssertNil(TranscriptFixtures.transcript([(path: "01.mp3", duration: 5_825, sentences: builder.sentences)])
            .validationFailure())
    }

    /// A result holding two sentences is divided between them, each with
    /// its own words and times.
    func testAResultHoldingTwoSentencesIsDividedBetweenThem() throws {
        var builder = TranscriptSentenceBuilder(languageCode: "en")
        builder.add(TranscribedResult(start: 10, end: 14, pieces: [
            piece(" Glossary,", 10, 10.6), piece(" page", 10.6, 10.9), piece(" 31.", 10.9, 11.5),
            piece(" Index,", 11.5, 12.1), piece(" page", 12.1, 12.4), piece(" 32.", 12.4, 13.2),
        ]))

        XCTAssertEqual(builder.sentences.map(\.text), ["Glossary, page 31.", "Index, page 32."])
        XCTAssertEqual(builder.sentences.map(\.startMilliseconds), [10_000, 11_500])
        XCTAssertEqual(builder.sentences.map(\.endMilliseconds), [11_500, 13_200])
        XCTAssertEqual(builder.sentences[1].words.map(\.characterOffset), [0, 7, 12])
    }

    /// Text the recognizer gave no time is kept in its sentence but makes
    /// no word, and a sentence with no timed word joins its neighbor; a
    /// result with no timed word at all is one sentence spanning it.
    func testUntimedTextIsKeptInATimedSentence() throws {
        var builder = TranscriptSentenceBuilder(languageCode: "en")
        builder.add(TranscribedResult(start: 0, end: 4, pieces: [
            piece("Okay.", nil, nil), piece(" Carts", 1, 1.5), piece(" wait", 1.5, 2), piece(" here.", 2, 2.6),
        ]))
        builder.add(TranscribedResult(start: 4, end: 6, pieces: [piece("Hm.", nil, nil)]))

        XCTAssertEqual(builder.sentences.map(\.text), ["Okay. Carts wait here.", "Hm."])
        XCTAssertEqual(builder.sentences[0].words.map(\.characterOffset), [6, 12, 17])
        XCTAssertEqual(builder.sentences[0].startMilliseconds, 1_000)
        XCTAssertEqual(builder.sentences[1].words, [])
        XCTAssertEqual(builder.sentences[1].startMilliseconds, 4_000)
        XCTAssertEqual(builder.sentences[1].endMilliseconds, 6_000)
    }

    /// Times the recognizer gives out of order are kept in order, so a
    /// transcript always passes validation.
    func testTimesAreKeptInOrderWhateverTheRecognizerSays() {
        var builder = TranscriptSentenceBuilder(languageCode: "en")
        builder.add(TranscribedResult(start: 5, end: 7, pieces: [piece("Later", 5, 6), piece(" words.", 6, 7)]))
        builder.add(TranscribedResult(start: 3, end: 4, pieces: [piece("Earlier", 3.5, 3.2), piece(" ones.", 3.0, 4)]))

        XCTAssertNil(TranscriptFixtures.transcript([(path: "01.mp3", duration: 8_000, sentences: builder.sentences)])
            .validationFailure())
        XCTAssertEqual(builder.sentences.map(\.startMilliseconds), [5_000, 5_000])
    }

    /// A piece of whitespace alone separates the words around it, and
    /// empty results add nothing.
    func testWhitespaceAlonePiecesSeparateWords() {
        var builder = TranscriptSentenceBuilder(languageCode: nil)
        builder.add(TranscribedResult(start: 0, end: 1, pieces: []))
        builder.add(TranscribedResult(start: 0, end: 2, pieces: [piece("Toll", 0, 1), piece(" ", nil, nil), piece("road.", 1, 2)]))

        XCTAssertEqual(builder.sentences.map(\.text), ["Toll road."])
    }

    // MARK: - What This Mac Offers

    /// The system's support follows the system: macOS 26 transcribes when
    /// its recognizer can run here, and anything older needs macOS 26.
    func testTheSystemsSupportFollowsTheSystem() {
        if #available(macOS 26.0, *) {
            XCTAssertEqual(
                TranscriptionAvailability.systemSupport,
                SpeechTranscriber.isAvailable ? .available : .unavailableOnThisMac
            )
        } else {
            XCTAssertEqual(TranscriptionAvailability.systemSupport, .needsNewerSystem)
        }
    }

    /// Every installed language is a supported one and reports its model as
    /// installed, and a language the recognizer cannot transcribe reports as
    /// unsupported. Asking downloads and reserves nothing.
    func testInstalledLanguagesAreSupportedAndReportAsInstalled() async throws {
        try XCTSkipUnless(TranscriptionAvailability.systemSupport == .available, "transcription needs macOS 26")
        let supported = await TranscriptionAvailability.supportedLocales()
        let installed = await TranscriptionAvailability.installedLocales()

        XCTAssertFalse(supported.isEmpty)
        for locale in installed {
            XCTAssertTrue(supported.contains { TranscriptionAvailability.isSameLocale($0, locale) }, locale.identifier)
            let status = await TranscriptionAvailability.modelStatus(for: locale)
            guard case .installed(let served) = status else {
                return XCTFail("\(locale.identifier) is installed but reports \(status)")
            }
            XCTAssertTrue(TranscriptionAvailability.isSameLocale(served, locale))
        }
        let klingon = await TranscriptionAvailability.modelStatus(for: Locale(identifier: "tlh"))
        XCTAssertEqual(klingon, .unsupported)
    }

    /// This Mac's engine names the model it would use for an installed
    /// language, without transcribing anything; on a system without the
    /// recognizer it says transcription needs macOS 26.
    func testThisMacsEngineNamesTheModelForAnInstalledLanguage() async throws {
        guard TranscriptionAvailability.systemSupport == .available else {
            do {
                _ = try await SystemTranscriptionEngine().prepare(locale: Locale(identifier: "en-US"))
                XCTFail("an engine without the recognizer prepared a model")
            } catch {
                XCTAssertTrue(
                    [.needsNewerSystem, .unavailableOnThisMac].contains(error as? TranscriptionError),
                    "\(error)"
                )
            }
            return
        }
        guard let installed = await TranscriptionAvailability.installedLocales().first else {
            throw XCTSkip("no speech model is installed on this Mac")
        }

        let info = try await SystemTranscriptionEngine().prepare(locale: installed)

        XCTAssertEqual(info.locale, installed.identifier(.bcp47))
        XCTAssertEqual(info.model.engine, "SpeechTranscriber")
        XCTAssertTrue(["installed", "supported", "downloading"].contains(info.model.assetStatus), info.model.assetStatus)
        XCTAssertEqual(info.model.systemVersion, ProcessInfo.processInfo.operatingSystemVersionString)
    }

    // MARK: - Helpers

    /// Each file's scripted sentences: three in the first file, two in the
    /// second, as `ScriptedTranscriptionEngine` says them.
    static let script: [String: [TranscriptSentence]] = [
        "01.wav": [
            TranscriptFixtures.sentence("Quillwort grows by the ferry slip.", from: 0, to: 1_200),
            TranscriptFixtures.sentence("Tide tables hang in the office.", from: 1_200, to: 2_400),
        ],
        "02.wav": [
            TranscriptFixtures.sentence("The salt road bends east.", from: 0, to: 1_500),
        ],
    ]

    /// A long script: four hundred short sentences, which take twenty
    /// seconds to say at the cancellation tests' pace.
    static let longScript: [TranscriptSentence] = (0..<400).map { number in
        TranscriptFixtures.sentence("Carts wait at the toll.", from: number * 50, to: number * 50 + 50)
    }

    /// A piece of a recognizer's result, timed from `start` to `end`
    /// seconds when both are given.
    private func piece(_ text: String, _ start: TimeInterval?, _ end: TimeInterval?, _ confidence: Double? = 0.9) -> TranscribedPiece {
        TranscribedPiece(text: text, start: start, end: end, confidence: confidence)
    }

    /// Asserts that `service` refuses to transcribe `book`, in `language`
    /// when given, with `error`.
    private func assertTranscription(
        of book: Book,
        by service: TranscriptionService,
        language: String? = nil,
        fails error: TranscriptionError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await service.transcribe(book, language: language)
            XCTFail("the transcription ran", file: file, line: line)
        } catch let thrown {
            XCTAssertEqual(thrown as? TranscriptionError, error, file: file, line: line)
        }
    }

    /// Waits, a few milliseconds at a time and at most five seconds, until
    /// `condition` holds, and says whether it did.
    private func waitAsync(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

// MARK: - A Scripted Engine

/// An engine that hears nothing: for each file, by its name, it says the
/// sentences a script gives, one after another with `pause` between them,
/// reporting each sentence's end as progress, and refuses what it is told
/// to refuse. It records every call, in order.
struct ScriptedTranscriptionEngine: TranscriptionEngine {
    /// The model it names for every language it prepares.
    static let model = TranscriptSpeechModel(engine: "Scripted", assetStatus: "installed", systemVersion: "test")

    /// Each file's sentences, by the file's name.
    var sentences: [String: [TranscriptSentence]]
    /// How long it takes to say each sentence.
    var pause: Duration = .zero
    /// What preparing any language throws, if anything.
    var refusal: TranscriptionError?
    /// The languages, as BCP 47 identifiers, it does not support.
    var unsupported: Set<String> = []
    /// Every call, in order.
    let calls = EngineCalls()

    func prepare(locale: Locale) async throws -> TranscriptionModelInfo {
        let identifier = locale.identifier(.bcp47)
        await calls.note("prepare \(identifier)")
        if let refusal { throw refusal }
        if unsupported.contains(identifier) {
            throw TranscriptionError.unsupportedLanguage(TranscriptionLanguage.name(of: identifier))
        }
        return TranscriptionModelInfo(locale: identifier, model: Self.model)
    }

    func transcribe(
        fileAt url: URL,
        locale: Locale,
        progress: @escaping @Sendable (TimeInterval) -> Void
    ) async throws -> [TranscriptSentence] {
        await calls.note("transcribe \(url.lastPathComponent)")
        let script = sentences[url.lastPathComponent] ?? []
        for sentence in script {
            if pause > .zero {
                try await Task.sleep(for: pause)
            }
            try Task.checkCancellation()
            progress(Transcript.seconds(sentence.endMilliseconds))
        }
        return script
    }
}

/// The calls a scripted engine was asked to make, in order.
actor EngineCalls {
    /// One line per call: what was asked, and of what.
    private(set) var entries: [String] = []

    /// Records one call.
    func note(_ entry: String) {
        entries.append(entry)
    }
}

/// The progress a transcription reported, in the order it reported it, from
/// whatever thread it reported on.
final class ProgressRecorder: Sendable {
    /// The progress reported so far, guarded by its lock.
    private let reported = OSAllocatedUnfairLock(initialState: [TranscriptionProgress]())

    /// Every report so far, in order.
    var events: [TranscriptionProgress] {
        reported.withLock { $0 }
    }

    /// Records one report; pass it as a transcription's progress handler.
    @Sendable func record(_ progress: TranscriptionProgress) {
        reported.withLock { $0.append(progress) }
    }
}
