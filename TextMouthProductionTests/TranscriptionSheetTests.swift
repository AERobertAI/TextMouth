import XCTest
@testable import TextMouth

/// Transcribe Audio… and its sheet (FR05), as the user meets them: the
/// command offered for audiobooks, one book at a time; the sheet naming the
/// book, its audio, the estimate, and the language with its model's status;
/// a download only when Download is pressed; the macOS version message; and
/// Transcribe saving the transcript, announcing it, and closing, with
/// Cancel and failures said plainly.
///
/// Every sheet here reaches services of the test's own: models and
/// downloads are scripted, and every transcription is heard by a scripted
/// engine, never the system's recognizer, which the engine's own tests
/// cover. No test downloads a model.
@MainActor
final class TranscriptionSheetTests: XCTestCase {

    // MARK: - The Command

    /// Transcribe Audio… is offered whenever an audiobook in a package of
    /// its own is among the books a row's commands act on, under the same
    /// name in the menu and among VoiceOver's actions, after Edit Audio…
    /// (FR04) when the row acts on that audiobook alone, and never for text
    /// books alone.
    func testTranscribeAudioIsOfferedWheneverAnAudiobookIsAmongTheBooks() {
        let audiobook = Self.audiobook("Harbour Bells")
        let textBook = Book(title: "Lock Keeper", format: .markdown, filePath: "/nonexistent/lock.md", md5Hash: "lock",
                            tmbDirectoryName: "lock.tmb")
        let unpackaged = Book(title: "Loose Track", format: .audio, filePath: "/nonexistent/loose.mp3", md5Hash: "loose")

        XCTAssertEqual(LibraryAudioCommand.commands(for: [audiobook]), [.editAudio(audiobook), .transcribe([audiobook])])
        XCTAssertEqual(LibraryAudioCommand.commands(for: [textBook, audiobook]), [.transcribe([textBook, audiobook])])
        XCTAssertEqual(LibraryAudioCommand.commands(for: [textBook]), [])
        XCTAssertEqual(LibraryAudioCommand.commands(for: [unpackaged]), [])
        XCTAssertEqual(LibraryAudioCommand.transcribe([audiobook]).title, "Transcribe Audio…")
        let row = BookRow(book: audiobook, audioCommands: LibraryAudioCommand.commands(for: [audiobook]))
        XCTAssertEqual(row.accessibilityActionNames, ["Edit Audio…", "Transcribe Audio…"])
    }

    /// One audiobook opens its sheet; several books, or a book that is not
    /// an audiobook, open a sheet that only says why, with OK, which takes
    /// VoiceOver's focus and hears the sentence.
    func testOneAudiobookOpensItsSheetAndAnythingElseIsRefusedWithASentence() async {
        let audiobook = Self.audiobook("Harbour Bells")
        let other = Self.audiobook("Tide Clock")
        let textBook = Book(title: "Lock Keeper", format: .markdown, filePath: "/nonexistent/lock.md", md5Hash: "lock",
                            tmbDirectoryName: "lock.tmb")

        XCTAssertEqual(TranscriptionRequest(books: [audiobook]), .book(audiobook))
        XCTAssertEqual(TranscriptionRequest(books: [audiobook, other]), .refused(TranscriptionWording.oneBookAtATime))
        XCTAssertEqual(TranscriptionRequest(books: [textBook]), .refused("Lock Keeper isn't an audiobook. "
            + "Only an audiobook's audio can be transcribed."))

        let announcements = SheetAnnouncements()
        let model = TranscriptionSheetModel(
            request: TranscriptionRequest(books: [audiobook, other]),
            library: nil,
            services: makeSheetServices(announcements: announcements)
        )
        await model.load()

        XCTAssertEqual(model.phase, .unavailable(TranscriptionWording.oneBookAtATime))
        XCTAssertEqual(model.heading, "Transcribe Audio")
        XCTAssertEqual(model.focusTarget, .ok)
        model.announceSheet()
        XCTAssertEqual(announcements.messages, [
            "Transcription works on one audiobook at a time. Select one audiobook, then choose Transcribe Audio again.",
        ])
    }

    // MARK: - The Sheet Before a Transcription

    /// The sheet names the book, its audio's length, how long transcribing
    /// takes, and the language with its model's status; with the model
    /// installed, Transcribe can be pressed and takes VoiceOver's focus,
    /// and VoiceOver hears the sheet's lines together.
    func testTheSheetNamesTheBookItsAudioTheEstimateAndTheLanguage() async {
        let announcements = SheetAnnouncements()
        let statuses = ScriptedModelStatuses(["en-US": .installed(Locale(identifier: "en-US"))])
        let model = TranscriptionSheetModel(
            request: .book(Self.audiobook("Harbour Bells", seconds: 3_060)),
            library: nil,
            services: makeSheetServices(statuses: statuses, announcements: announcements)
        )
        XCTAssertEqual(model.phase, .checking)
        XCTAssertNil(model.focusTarget, "nothing takes focus while the model is checked")

        await model.load()

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.heading, "Transcribe Harbour Bells")
        XCTAssertEqual(model.audioLine, "Audio: 51 minutes.")
        XCTAssertEqual(model.estimateLine, "Time to transcribe: about 1 minute.")
        XCTAssertEqual(model.language, "en-US")
        XCTAssertEqual(model.languageLine, "Language: \(TranscriptionLanguage.name(of: "en-US")), installed.")
        XCTAssertTrue(model.canTranscribe)
        XCTAssertFalse(model.offersDownload)
        XCTAssertEqual(model.transcribeTitle, "Transcribe")
        XCTAssertEqual(model.focusTarget, .transcribe)
        XCTAssertEqual(statuses.askedLanguages, ["en-US"])

        model.announceSheet()
        model.announceSheet()
        XCTAssertEqual(announcements.messages, [
            "Transcribe Harbour Bells Audio: 51 minutes. Time to transcribe: about 1 minute. "
                + "Language: \(TranscriptionLanguage.name(of: "en-US")), installed.",
        ], "the lines are heard once")
    }

    /// On a system older than macOS 26 the sheet only says that
    /// transcription needs macOS 26, with OK: no model is asked about, no
    /// transcript read, and nothing offered.
    func testOlderSystemsHearThatTranscriptionNeedsMacOS26AndNothingElse() async {
        let statuses = ScriptedModelStatuses([:])
        let model = TranscriptionSheetModel(
            request: .book(Self.audiobook("Harbour Bells")),
            library: nil,
            services: makeSheetServices(support: .needsNewerSystem, statuses: statuses)
        )

        await model.load()

        XCTAssertEqual(model.phase, .unavailable("Transcription needs macOS 26 or later."))
        XCTAssertEqual(model.announcement, "Transcription needs macOS 26 or later.")
        XCTAssertEqual(model.focusTarget, .ok)
        XCTAssertFalse(model.canTranscribe)
        XCTAssertFalse(model.offersDownload)
        XCTAssertEqual(statuses.askedLanguages, [], "a model was asked about")
    }

    /// A Mac whose system is new enough but cannot run the model says so.
    func testAMacThatCannotRunTheModelSaysSo() async {
        let model = TranscriptionSheetModel(
            request: .book(Self.audiobook("Harbour Bells")),
            library: nil,
            services: makeSheetServices(support: .unavailableOnThisMac)
        )

        await model.load()

        XCTAssertEqual(model.phase, .unavailable("This Mac can't run the speech model that transcription uses."))
    }

    /// The system's English, which nobody chose, gives way to US English
    /// when the recognizer does not support it, as a transcription does, so
    /// the sheet names the language that will be used.
    func testTheSystemsEnglishGivesWayToUSEnglishWhenUnsupported() async {
        let statuses = ScriptedModelStatuses(["en-US": .installed(Locale(identifier: "en-US"))])
        let model = TranscriptionSheetModel(
            request: .book(Self.audiobook("Harbour Bells")),
            library: nil,
            services: makeSheetServices(languages: ["en-NZ", "en-US"], statuses: statuses)
        )

        await model.load()

        XCTAssertEqual(statuses.askedLanguages, ["en-NZ", "en-US"])
        XCTAssertEqual(model.language, "en-US")
        XCTAssertTrue(model.canTranscribe)
    }

    /// A language the recognizer does not support says so, and Transcribe
    /// cannot be pressed.
    func testAnUnsupportedLanguageSaysSo() async {
        let model = TranscriptionSheetModel(
            request: .book(Self.audiobook("Harbour Bells")),
            library: nil,
            services: makeSheetServices(languages: ["xh-ZA"], statuses: ScriptedModelStatuses([:]))
        )

        await model.load()

        XCTAssertEqual(model.languageLine, "Language: \(TranscriptionLanguage.name(of: "xh-ZA")), not supported.")
        XCTAssertFalse(model.canTranscribe)
        XCTAssertFalse(model.offersDownload)
        XCTAssertEqual(model.focusTarget, .cancel)
    }

    /// A model not on this Mac is offered for download, by the language's
    /// name and size, and takes VoiceOver's focus; Transcribe cannot be
    /// pressed, and nothing downloads until Download is pressed.
    func testAMissingModelOffersItsDownloadAndKeepsTranscribeUnavailable() async {
        let statuses = ScriptedModelStatuses(["en-US": .needsDownload(Locale(identifier: "en-US"))])
        let installer = ScriptedModelInstaller(statuses: statuses)
        let model = TranscriptionSheetModel(
            request: .book(Self.audiobook("Harbour Bells")),
            library: nil,
            services: makeSheetServices(statuses: statuses, installer: installer)
        )

        await model.load()

        XCTAssertEqual(model.languageLine, "Language: \(TranscriptionLanguage.name(of: "en-US")), needs download.")
        XCTAssertTrue(model.offersDownload)
        XCTAssertFalse(model.canTranscribe)
        XCTAssertEqual(model.focusTarget, .download)
        XCTAssertEqual(model.modelLanguageName, TranscriptionWording.modelLanguageName(of: "en-US"))
        XCTAssertEqual(
            TranscriptionWording.downloadTitle(languageName: "English"),
            "Download the English model, about 140 MB"
        )
        XCTAssertEqual(installer.requestedLanguages, [], "a model downloaded unasked")
    }

    /// Download shows its progress while it runs, with Cancel Download
    /// taking focus; once the model is installed, VoiceOver hears so, and
    /// Transcribe can be pressed and takes focus.
    func testDownloadShowsItsProgressAndInstallsTheModel() async {
        let statuses = ScriptedModelStatuses(["en-US": .needsDownload(Locale(identifier: "en-US"))])
        let installer = ScriptedModelInstaller(statuses: statuses)
        let announcements = SheetAnnouncements()
        let model = TranscriptionSheetModel(
            request: .book(Self.audiobook("Harbour Bells")),
            library: nil,
            services: makeSheetServices(statuses: statuses, installer: installer, announcements: announcements)
        )
        await model.load()

        model.downloadModel()

        XCTAssertEqual(model.modelState, .downloading(nil))
        XCTAssertEqual(model.focusTarget, .cancelDownload)
        let name = model.modelLanguageName
        XCTAssertEqual(model.downloadLine, "Downloading the \(name) model…")
        let installed = await eventuallyHolds { model.modelState == .installed }
        XCTAssertTrue(installed, "the model never installed")
        XCTAssertEqual(installer.requestedLanguages, ["en-US"])
        XCTAssertTrue(model.canTranscribe)
        XCTAssertEqual(model.focusTarget, .transcribe)
        XCTAssertNil(model.downloadLine)
        XCTAssertEqual(announcements.messages, ["The \(name) model is downloaded. The book can be transcribed now."])
        XCTAssertEqual(
            TranscriptionWording.downloading(languageName: "English", fraction: 0.4),
            "Downloading the English model: 40 percent."
        )
    }

    /// Cancel Download stops the download: nothing is installed, the sheet
    /// offers the download again, and says it was cancelled.
    func testCancellingADownloadInstallsNothingAndSaysSo() async {
        let statuses = ScriptedModelStatuses(["en-US": .needsDownload(Locale(identifier: "en-US"))])
        let installer = ScriptedModelInstaller(waitsForCancel: true, statuses: statuses)
        let announcements = SheetAnnouncements()
        let model = TranscriptionSheetModel(
            request: .book(Self.audiobook("Harbour Bells")),
            library: nil,
            services: makeSheetServices(statuses: statuses, installer: installer, announcements: announcements)
        )
        await model.load()
        model.downloadModel()
        let reported = await eventuallyHolds { model.modelState == .downloading(0.75) }
        XCTAssertTrue(reported, "the download's progress never showed")
        XCTAssertEqual(model.downloadLine, "Downloading the \(model.modelLanguageName) model: 75 percent.")

        model.cancelDownload()

        let stopped = await eventuallyHolds { model.modelState == .needsDownload }
        XCTAssertTrue(stopped, "the download never stopped")
        let notice = "The \(model.modelLanguageName) model's download was cancelled."
        XCTAssertEqual(model.downloadNotice, notice)
        XCTAssertEqual(announcements.messages, [notice])
        XCTAssertTrue(model.offersDownload)
        XCTAssertFalse(model.canTranscribe)
        XCTAssertEqual(statuses.status(for: Locale(identifier: "en-US")), .needsDownload(Locale(identifier: "en-US")))
    }

    /// A download that fails says why, and offers the download again.
    func testAFailedDownloadSaysWhy() async {
        let statuses = ScriptedModelStatuses(["en-US": .needsDownload(Locale(identifier: "en-US"))])
        let failure = URLError(.notConnectedToInternet)
        let installer = ScriptedModelInstaller(steps: [], failure: failure, statuses: statuses)
        let announcements = SheetAnnouncements()
        let model = TranscriptionSheetModel(
            request: .book(Self.audiobook("Harbour Bells")),
            library: nil,
            services: makeSheetServices(statuses: statuses, installer: installer, announcements: announcements)
        )
        await model.load()

        model.downloadModel()

        let ended = await eventuallyHolds { model.downloadNotice != nil }
        XCTAssertTrue(ended, "the download never ended")
        let words = "The \(model.modelLanguageName) model couldn't be downloaded: \(failure.localizedDescription)"
        XCTAssertEqual(model.downloadNotice, words)
        XCTAssertEqual(announcements.messages, [words])
        XCTAssertTrue(model.offersDownload)
    }

    /// A book transcribed already says when, and in which language, and
    /// offers Transcribe Again.
    func testABookTranscribedAlreadyOffersTranscribeAgain() async {
        let transcript = TranscriptFixtures.transcript([(path: "01.mp3", duration: 1_000, sentences: [])], locale: "en-GB")
        let model = TranscriptionSheetModel(
            request: .book(Self.audiobook("Harbour Bells")),
            library: nil,
            services: makeSheetServices(transcript: .found(transcript))
        )

        await model.load()

        let line = "Transcribed on \(TranscriptionWording.day(TranscriptFixtures.date)), in "
            + "\(TranscriptionLanguage.name(of: "en-GB")). Transcribing again replaces this transcript."
        XCTAssertEqual(model.existingLine, line)
        XCTAssertEqual(model.noticeLines, [line])
        XCTAssertEqual(model.transcribeTitle, "Transcribe Again")
        XCTAssertEqual(model.transcribeHint, TranscriptionWording.transcribeAgainHint)
    }

    /// While another book is transcribed, the sheet says so and Transcribe
    /// cannot be pressed; once that transcription ends, it can.
    func testAnotherBooksTranscriptionKeepsTranscribeUnavailableUntilItEnds() async throws {
        let world = try makeIntegrationWorld("Transcription Sheet Busy")
        let running = try world.makeSilentAudioBook(title: "Long Pier Recordings", trackDurations: [20])
        let center = makeScriptedCenter(script: TranscriptionUIScripts.longTrack, pause: .milliseconds(100))
        XCTAssertTrue(center.start(running, language: "en-US", library: world.library, window: nil))
        let model = TranscriptionSheetModel(
            request: .book(Self.audiobook("Harbour Bells")),
            library: world.library,
            services: makeSheetServices(center: center)
        )

        await model.load()

        XCTAssertEqual(model.busyLine, "TextMouth is already transcribing Long Pier Recordings. Try again when that finishes.")
        XCTAssertFalse(model.canTranscribe)
        XCTAssertEqual(model.focusTarget, .cancel)
        center.cancel()
        let freed = await eventuallyHolds { center.current == nil }
        XCTAssertTrue(freed, "the other transcription never stopped")
        XCTAssertNil(model.busyLine)
        XCTAssertTrue(model.canTranscribe)
    }

    // MARK: - Transcribing

    /// Transcribe transcribes the book with the engine, saves the
    /// transcript into the book, announces the words and the time it took,
    /// and closes the sheet.
    func testTranscribeSavesTheTranscriptAnnouncesItAndClosesTheSheet() async throws {
        let world = try makeIntegrationWorld("Transcription Sheet Transcribe")
        let book = try world.makeSilentAudioBook(title: "Breakwater Notes", trackDurations: [3, 2])
        let center = makeScriptedCenter(script: TranscriptionUIScripts.twoTracks)
        let model = TranscriptionSheetModel(
            request: .book(book),
            library: world.library,
            services: makeSheetServices(center: center)
        )
        var closed = false
        model.onClose = { closed = true }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        await model.load()

        model.transcribe()

        XCTAssertEqual(model.phase, .transcribing)
        XCTAssertEqual(model.heading, "Transcribing Breakwater Notes")
        XCTAssertEqual(model.focusTarget, .progress)
        XCTAssertEqual(center.current?.bookID, book.id)
        let ended = await eventuallyHolds { closed }
        XCTAssertTrue(ended, "the sheet never closed")
        XCTAssertNil(center.current)
        guard case .found(let transcript) = TranscriptStore.read(from: book.tmbDirectory) else {
            return XCTFail("no transcript was saved")
        }
        XCTAssertEqual(transcript.wordCount, 17)
        XCTAssertEqual(transcript.files.flatMap(\.sentences).count, 3)
        XCTAssertEqual(announcements.messages.first, "Transcribing Breakwater Notes.")
        XCTAssertTrue(
            announcements.messages.last?.hasPrefix("Transcribed Breakwater Notes: 17 words in ") == true,
            "\(announcements.messages)"
        )
        guard case .finished(let words, _)? = center.lastEnding?.ending else {
            return XCTFail("the transcription did not finish: \(String(describing: center.lastEnding))")
        }
        XCTAssertEqual(words, 17)
    }

    /// Cancel stops the transcription: the sheet closes, VoiceOver hears
    /// that it was cancelled, and the book is left as it was.
    func testCancelStopsTheTranscriptionAndLeavesTheBookAsItWas() async throws {
        let world = try makeIntegrationWorld("Transcription Sheet Cancel")
        let book = try world.makeSilentAudioBook(title: "Long Pier Recordings", trackDurations: [20])
        let center = makeScriptedCenter(script: TranscriptionUIScripts.longTrack, pause: .milliseconds(50))
        let model = TranscriptionSheetModel(request: .book(book), library: world.library, services: makeSheetServices(center: center))
        var closed = false
        model.onClose = { closed = true }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        await model.load()
        model.transcribe()

        model.cancelTranscription()

        let ended = await eventuallyHolds { closed }
        XCTAssertTrue(ended, "the sheet never closed")
        XCTAssertEqual(center.lastEnding?.ending, .cancelled)
        XCTAssertEqual(announcements.messages, ["Transcribing Long Pier Recordings.", "Transcription was cancelled."])
        XCTAssertFalse(FileManager.default.fileExists(atPath: TextMouthPaths.transcriptPath(in: book.tmbDirectory).path))
    }

    /// A transcription that fails says why, in the sheet, with Close, which
    /// takes focus, and to VoiceOver; Escape closes the sheet.
    func testAFailedTranscriptionSaysWhyWithClose() async throws {
        let world = try makeIntegrationWorld("Transcription Sheet Failure")
        let book = try world.makeSilentAudioBook(title: "Breakwater Notes", trackDurations: [3, 2])
        let center = makeScriptedCenter(script: [:], refusal: .recognitionFailed("the recognizer stopped"))
        let model = TranscriptionSheetModel(request: .book(book), library: world.library, services: makeSheetServices(center: center))
        var closed = false
        model.onClose = { closed = true }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        await model.load()

        model.transcribe()

        let failed = await eventuallyHolds { model.phase != .transcribing }
        XCTAssertTrue(failed, "the transcription never ended")
        XCTAssertEqual(model.phase, .failed("Transcription stopped: the recognizer stopped."))
        XCTAssertEqual(model.focusTarget, .close)
        XCTAssertNil(model.announcement, "the center announced it already")
        XCTAssertEqual(announcements.messages, [
            "Transcribing Breakwater Notes.",
            "Transcription stopped: the recognizer stopped.",
        ])
        XCTAssertFalse(closed)
        model.escape()
        XCTAssertTrue(closed)
    }

    /// A sheet opened for a book being transcribed shows that
    /// transcription, and its Cancel stops it.
    func testASheetOpenedDuringItsBooksTranscriptionShowsIt() async throws {
        let world = try makeIntegrationWorld("Transcription Sheet Reopened")
        let book = try world.makeSilentAudioBook(title: "Long Pier Recordings", trackDurations: [20])
        let center = makeScriptedCenter(script: TranscriptionUIScripts.longTrack, pause: .milliseconds(100))
        XCTAssertTrue(center.start(book, language: "en-US", library: world.library, window: nil))
        let model = TranscriptionSheetModel(request: .book(book), library: world.library, services: makeSheetServices(center: center))
        var closed = false
        model.onClose = { closed = true }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        await model.load()

        XCTAssertEqual(model.phase, .transcribing)
        XCTAssertEqual(model.heading, "Transcribing Long Pier Recordings")
        model.cancelTranscription()
        let ended = await eventuallyHolds { closed }
        XCTAssertTrue(ended, "the sheet never closed")
        XCTAssertNil(center.current)
    }

    /// A sheet asked to start at once, as the offer after an import asks,
    /// starts transcribing as soon as it is ready, and downloads nothing
    /// when the model is missing, waiting for Download instead.
    func testASheetAskedToStartAtOnceStartsOnlyWhenItCan() async throws {
        let world = try makeIntegrationWorld("Transcription Sheet At Once")
        let book = try world.makeSilentAudioBook(title: "Breakwater Notes", trackDurations: [3, 2])
        let center = makeScriptedCenter(script: TranscriptionUIScripts.twoTracks)
        let ready = TranscriptionSheetModel(
            request: .book(book),
            library: world.library,
            startsAtOnce: true,
            services: makeSheetServices(center: center)
        )
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        await ready.load()

        XCTAssertEqual(ready.phase, .transcribing)
        let ended = await eventuallyHolds { center.current == nil }
        XCTAssertTrue(ended, "the transcription never ended")

        let statuses = ScriptedModelStatuses(["en-US": .needsDownload(Locale(identifier: "en-US"))])
        let installer = ScriptedModelInstaller(statuses: statuses)
        let waiting = TranscriptionSheetModel(
            request: .book(book),
            library: world.library,
            startsAtOnce: true,
            services: makeSheetServices(statuses: statuses, installer: installer, center: center)
        )
        await waiting.load()
        XCTAssertEqual(waiting.phase, .ready)
        XCTAssertTrue(waiting.offersDownload)
        XCTAssertEqual(installer.requestedLanguages, [])
    }

    // MARK: - Words

    /// The estimate counts 65 seconds of audio a second after a start of a
    /// few seconds: under 45 seconds is "less than a minute", and anything
    /// longer is "about" the nearest whole minutes.
    func testTheEstimateIsWordedInMinutes() {
        XCTAssertNil(TranscriptionEstimate.words(forAudio: nil))
        XCTAssertNil(TranscriptionEstimate.words(forAudio: 0))
        XCTAssertEqual(TranscriptionEstimate.words(forAudio: 1_572), "less than a minute", "26 minutes of audio")
        XCTAssertEqual(TranscriptionEstimate.words(forAudio: 3_060), "about 1 minute", "51 minutes of audio")
        XCTAssertEqual(TranscriptionEstimate.words(forAudio: 22_320), "about 6 minutes", "6 hours, 12 minutes")
        XCTAssertEqual(TranscriptionEstimate.words(forAudio: 234_000), "about 1 hour", "65 hours")
        XCTAssertEqual(TranscriptionWording.estimateLine(forAudio: nil), "Time to transcribe: not known until the audio's length is.")
        XCTAssertEqual(TranscriptionWording.audioLength(nil), "Audio: length not known yet.")
        XCTAssertEqual(TranscriptionWording.audioLength(22_324), "Audio: 6 hours, 12 minutes, 4 seconds.")
    }

    /// A finished transcription is announced with its words, grouped as the
    /// user writes numbers, and its time; a failure in its own words.
    func testTheEndOfATranscriptionIsAnnouncedPlainly() {
        XCTAssertEqual(
            TranscriptionWording.finished(bookTitle: "Moby-Dick", wordCount: 7_077, seconds: 51),
            "Transcribed Moby-Dick: \(7_077.formatted()) words in 51 seconds."
        )
        XCTAssertEqual(
            TranscriptionWording.finished(bookTitle: "Moby-Dick", wordCount: 1, seconds: 75),
            "Transcribed Moby-Dick: 1 word in 1 minute, 15 seconds."
        )
        XCTAssertEqual(TranscriptionJobEnding.ending(for: CancellationError()), .cancelled)
        XCTAssertEqual(TranscriptionJobEnding.ending(for: TranscriptionError.cancelled), .cancelled)
        XCTAssertEqual(
            TranscriptionJobEnding.ending(for: TranscriptionError.noAudio),
            .failed("This audiobook has no audio to transcribe.")
        )
        XCTAssertEqual(TranscriptionJobEnding.cancelled.announcement(bookTitle: "Moby-Dick"), "Transcription was cancelled.")
    }

    // MARK: - Fixtures

    /// An audiobook in a package of its own, never on disk, `seconds` long
    /// when given, for sheets whose services never read its files.
    static func audiobook(_ title: String, seconds: TimeInterval? = nil) -> Book {
        Book(
            title: title,
            format: .audio,
            filePath: "/nonexistent/\(title).mp3",
            md5Hash: title,
            tmbDirectoryName: "\(title).tmb",
            audioDuration: seconds
        )
    }
}
