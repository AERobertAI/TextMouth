import os
import XCTest
@testable import TextMouth

/// "Text as spoken audio" as a kind of the Export job runner (FMT43): a text
/// book offers it from its text cache, for one book at a time; it is never
/// copied, so the plan names its file by the speech conversion's request and
/// plans nothing for it without one; the export speaks it through
/// `SpeechExportJob` into a scratch file that is moved into the folder once
/// whole, with a chapter for each heading; Stop leaves nothing and is no
/// failure; a refusal names the file with its sentence; and the kind's words.
///
/// Every book lives in a library folder of the test's own, and every export
/// goes to a sandbox folder; nothing reaches the user's Documents or library.
/// Nothing is spoken by a real synthesizer and no sound is played: speech
/// comes from `FakeSpeechBufferSynthesizer`, the voice from a lookup of the
/// test's own (its Personal Voice is a name in that lookup, never one the Mac
/// has), the power assertion is a fake that keeps nothing awake, and the
/// spoken chapters are kept in a sandbox folder.
@MainActor
final class SpeechExportServiceTests: XCTestCase {

    // MARK: - The Offer

    /// A text book offers its text as spoken audio last of its own kinds,
    /// right after the plain text: one file named after the book, as M4B,
    /// read from its text cache, its size unknown before it is spoken.
    func testATextBookOffersItsTextAsSpokenAudio() throws {
        let world = try makeIntegrationWorld("Speech Export Offer")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let stem = BookExportService.fileNameStem(for: book.title)
        let cache = MarkdownCacheService.cacheURL(for: book)

        let offer = BookExportService.offer(for: book)

        XCTAssertEqual(offer.items.map(\.kind), [.originalFile, .markdown, .plainText, .spokenAudio])
        let spoken = try XCTUnwrap(offer.item(.spokenAudio))
        XCTAssertEqual(spoken.suggestedName, "\(stem) - Audio.m4b")
        XCTAssertNil(spoken.folderName, "the file stands alone")
        XCTAssertEqual(
            spoken.files,
            [BookExportFile(source: .spoken(fromMarkdown: cache), path: "\(stem) - Audio.m4b", byteCount: 0)]
        )
        XCTAssertEqual(spoken.byteCount, 0, "its size is not known before it is spoken")
        XCTAssertFalse(spoken.isInCloud)
    }

    /// Only a text book with its text cache offers spoken audio: an
    /// audiobook does not, even with a transcript's text as its content.md,
    /// and neither does a text book whose content.md is gone.
    func testOnlyATextBookWithItsTextCacheOffersSpokenAudio() throws {
        let world = try makeIntegrationWorld("Speech Export Offer Kinds")
        let audiobook = try world.makeSilentAudioBook(title: "Night Shift Notes", trackDurations: [1])
        try Data("<!-- chapter: Start -->\nThe tide turns at nine.".utf8)
            .write(to: MarkdownCacheService.cacheURL(for: audiobook))
        let textBook = try world.importBook(from: writeSource(named: "Lock Keeper.md"))
        try FileManager.default.removeItem(at: MarkdownCacheService.cacheURL(for: textBook))

        XCTAssertNil(BookExportService.offer(for: audiobook).item(.spokenAudio), "an audiobook offered spoken audio")
        XCTAssertNil(BookExportService.offer(for: textBook).item(.spokenAudio), "a book without its text cache offered it")
    }

    /// A text cache only in the cloud makes spoken audio in the cloud: its
    /// checkbox is unavailable and says so.
    func testATextCacheInTheCloudMakesSpokenAudioInTheCloud() throws {
        let world = try makeIntegrationWorld("Speech Export Cloud Offer")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let cache = MarkdownCacheService.cacheURL(for: book)
        let cloud = FakeCloudFiles()
        cloud.markDataless(cache)
        cloud.refuseReads(of: cache)

        let offer = BookExportService.offer(for: book, access: cloud.access)

        XCTAssertEqual(offer.item(.spokenAudio)?.fileInCloud, cache)
        let choice = try XCTUnwrap(BookExportChoice.choices(for: [offer]).first { $0.kind == .spokenAudio })
        XCTAssertFalse(choice.isAvailable)
        XCTAssertEqual(choice.label, "Text as spoken audio, in the cloud")
    }

    // MARK: - The Choice

    /// The dialog lists spoken audio when it exports one book, as its
    /// range and sliders are that book's, and never for several.
    func testSpokenAudioIsAChoiceForOneBookAlone() throws {
        let world = try makeIntegrationWorld("Speech Export Choice")
        let first = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let second = try world.importBook(from: writeSource(named: "Lock Keeper.md"))

        let alone = BookExportChoice.choices(for: [BookExportService.offer(for: first)])
        let together = BookExportChoice.choices(for: [first, second].map { BookExportService.offer(for: $0) })

        XCTAssertEqual(alone.map(\.kind), [.originalFile, .markdown, .plainText, .spokenAudio])
        XCTAssertEqual(alone.last?.label, "Text as spoken audio")
        XCTAssertEqual(alone.last?.isAvailable, true)
        XCTAssertEqual(together.map(\.kind), [.originalFile, .markdown, .plainText], "several books were offered spoken audio")
    }

    // MARK: - The Conversion and the Plan

    /// A speech conversion makes the files of spoken audio alone, in its
    /// format's extension, and is named by its format as the Format pop-up
    /// lists it; a text conversion never makes them.
    func testTheSpeechConversionMakesSpokenAudioAloneInItsFormat() {
        // A book's value alone: nothing is read or written.
        let book = Book(title: "Ferry Timetables", format: .markdown, filePath: "Ferry Timetables.md", md5Hash: "ferry-timetables")
        let m4b = BookExportConversion.speech(Self.request(for: book, format: .m4b))
        let mp3 = BookExportConversion.speech(Self.request(for: book, format: .mp3))

        XCTAssertEqual(m4b.fileExtension, "m4b")
        XCTAssertEqual(m4b.name, "M4B Audiobook (AAC)")
        XCTAssertEqual(mp3.fileExtension, "mp3")
        XCTAssertEqual(mp3.name, "MP3")
        for format in SpeechExportFormat.allCases {
            let speech = BookExportConversion.speech(Self.request(for: book, format: format))
            XCTAssertEqual(speech.fileExtension, format.fileExtension, "\(format)")
            XCTAssertEqual(speech.name, format.title, "\(format)")
        }
        XCTAssertEqual(BookExportKind.allCases.filter { m4b.applies(to: $0) }, [.spokenAudio])
        XCTAssertFalse(BookExportConversion.markdown.applies(to: .spokenAudio), "a text conversion made spoken audio")
    }

    /// The plan names the spoken file by its request: the file title, then
    /// the format's extension, MP3 as well as M4B, made unique when the name
    /// is taken, and made safe as one file's name, so a title can never
    /// reach another folder. The file is the text cache, converted by the
    /// speech conversion for the book, its size unknown.
    func testThePlanNamesTheSpokenFileByItsRequest() throws {
        let world = try makeIntegrationWorld("Speech Export Plan")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let stem = BookExportService.fileNameStem(for: book.title)
        let cache = MarkdownCacheService.cacheURL(for: book)
        let folder = try makeSandboxDirectory("Speech Export Plan Folder")
        let offer = BookExportService.offer(for: book)
        /// The targets planned for spoken audio converted by `speech`, with
        /// `taken` already in the folder.
        func targets(_ speech: BookExportConversion, taken: Set<String> = []) -> [URL] {
            BookExportService.plan(
                [offer],
                kinds: [.spokenAudio],
                conversions: [.spokenAudio: speech],
                in: folder,
                fileExists: { taken.contains($0.lastPathComponent) }
            ).files.map(\.target)
        }
        let speech = BookExportConversion.speech(Self.request(for: book, fileTitle: "Harbour Pilots - Read Aloud"))

        let planned = BookExportService.plan([offer], kinds: [.spokenAudio], conversions: [.spokenAudio: speech], in: folder)

        XCTAssertEqual(planned.files, [
            BookExportService.PlannedFile(
                book: BookExportBookName(book),
                file: BookExportFile(
                    source: .converted(from: cache, book: ExportBookDetails(book), by: speech),
                    path: "Harbour Pilots - Read Aloud.m4b",
                    byteCount: 0
                ),
                target: folder.appendingPathComponent("Harbour Pilots - Read Aloud.m4b")
            ),
        ])
        XCTAssertEqual(planned.booksInCloud, [])
        XCTAssertEqual(
            targets(.speech(Self.request(for: book, format: .mp3))).map(\.lastPathComponent),
            ["\(stem) - Audio.mp3"]
        )
        XCTAssertEqual(
            targets(.speech(Self.request(for: book)), taken: ["\(stem) - Audio.m4b"]).map(\.lastPathComponent),
            ["\(stem) - Audio 2.m4b"],
            "a name already taken was used again"
        )
        XCTAssertEqual(
            targets(.speech(Self.request(for: book, fileTitle: "../Elsewhere/Notes"))),
            [folder.appendingPathComponent("-Elsewhere-Notes.m4b")],
            "a file title reached another folder"
        )
        XCTAssertEqual(
            targets(.speech(Self.request(for: book, fileTitle: " "))).map(\.lastPathComponent),
            ["\(stem) - Audio.m4b"],
            "a title with nothing left is named as the offer names it"
        )
    }

    /// Spoken audio is never copied: as it is, with a speech conversion made
    /// for another book, or with a text conversion, nothing is planned for
    /// it, and that is no failure. A speech conversion given for another kind
    /// is ignored, and the other kinds' plans are as they were.
    func testWithoutItsBooksSpeechConversionNothingIsPlannedForSpokenAudio() throws {
        let world = try makeIntegrationWorld("Speech Export Plan Nothing")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let stem = BookExportService.fileNameStem(for: book.title)
        let folder = try makeSandboxDirectory("Speech Export Plan Nothing Folder")
        let offer = BookExportService.offer(for: book)
        let speech = BookExportConversion.speech(Self.request(for: book))
        var forAnotherBook = Self.request(for: book)
        forAnotherBook.bookID = UUID()
        /// The files planned for `kinds` with `conversions`.
        func plan(
            _ kinds: Set<BookExportKind>,
            _ conversions: [BookExportKind: BookExportConversion] = [:]
        ) -> [BookExportService.PlannedFile] {
            BookExportService.plan([offer], kinds: kinds, conversions: conversions, in: folder).files
        }

        XCTAssertEqual(plan([.spokenAudio]), [], "spoken audio was planned as it is")
        XCTAssertEqual(plan([.spokenAudio], [.spokenAudio: .speech(forAnotherBook)]), [], "another book's request was taken")
        XCTAssertEqual(plan([.spokenAudio], [.spokenAudio: .markdown]), [], "a text conversion made spoken audio")
        XCTAssertEqual(plan([.markdown], [.markdown: speech]), plan([.markdown]), "a speech conversion changed the Markdown")
        let others: Set<BookExportKind> = [.originalFile, .markdown, .plainText]
        XCTAssertEqual(plan(others.union([.spokenAudio])), plan(others), "the other kinds' plans changed")
        let withSpeech = plan(others.union([.spokenAudio]), [.spokenAudio: speech])
        XCTAssertEqual(Array(withSpeech.dropLast()), plan(others), "the speech conversion changed the other kinds' plans")
        XCTAssertEqual(withSpeech.last?.target, folder.appendingPathComponent("\(stem) - Audio.m4b"))
    }

    /// The spoken placeholder is never written as it is: met by a text
    /// conversion's mapping it is left out, and should one ever be planned as
    /// it is, it fails alone, named with the reason, leaving nothing.
    func testASpokenPlaceholderIsLeftOutOrFailsAloneButNeverWritten() throws {
        let world = try makeIntegrationWorld("Speech Export Placeholder")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let cache = MarkdownCacheService.cacheURL(for: book)
        let folder = try makeSandboxDirectory("Speech Export Placeholder Folder")
        let placeholder = BookExportFile(source: .spoken(fromMarkdown: cache), path: "Stray.m4b", byteCount: 0)
        let offer = BookExportOffer(
            book: book,
            items: [
                BookExportItem(kind: .markdown, folderName: nil, files: [placeholder], fileInCloud: nil),
                BookExportItem(kind: .plainText, folderName: nil, files: [placeholder], fileInCloud: nil),
            ],
            isPackageInCloud: false
        )

        let converted = BookExportService.plan([offer], kinds: [.markdown], conversions: [.markdown: .markdown], in: folder)
        let outcome = BookExportService.export([offer], kinds: [.plainText], to: folder)

        XCTAssertEqual(converted.files, [], "a text conversion planned the placeholder")
        XCTAssertEqual(outcome.exported, [])
        XCTAssertFalse(outcome.wasCancelled)
        XCTAssertEqual(
            outcome.failures,
            [BookExportFailure(name: "Stray.m4b", reason: CocoaError(.featureUnsupported).localizedDescription)]
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    // MARK: - Exporting

    /// Exporting spoken audio with its speech conversion speaks the book's
    /// words into one M4B in the folder, with a chapter for each heading,
    /// the level-2 one included; the context's progress hears the speaking,
    /// then the encoding, to its end; and the outcome lists the file.
    func testExportingSpeaksTheTextIntoOneFileWithAChapterPerHeading() async throws {
        let world = try makeIntegrationWorld("Speech Export Run")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let stem = BookExportService.fileNameStem(for: book.title)
        let folder = try makeSandboxDirectory("Speech Export Run Folder")
        // About a second of tone for each chapter's words.
        let synthesizer = FakeSpeechBufferSynthesizer(framesPerUnit: 1_000)
        let progress = ProgressRecord()
        let context = try speechContext(synthesizer: synthesizer, progress: progress)
        let offer = BookExportService.offer(for: book)
        let conversions: [BookExportKind: BookExportConversion] = [.spokenAudio: .speech(Self.request(for: book))]

        let outcome = await OffMainWork.run {
            BookExportService.export([offer], kinds: [.spokenAudio], conversions: conversions, to: folder, speech: context)
        }

        let file = folder.appendingPathComponent("\(stem) - Audio.m4b")
        XCTAssertEqual(outcome.failures, [])
        XCTAssertFalse(outcome.wasCancelled)
        XCTAssertEqual(outcome.exported, [file])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["\(stem) - Audio.m4b"])
        XCTAssertEqual(BookExportWording.finished(outcome, folderName: "Exports"), "Exported 1 item to Exports.")

        let chapters = await AudioPlaybackService.extractChapters(from: file)
        XCTAssertEqual(chapters.map(\.title), ["First", "Second", "Later"])
        let spoken = synthesizer.written.map(\.text).joined(separator: " ")
        for words in ["One two three.", "Four five.", "Six seven eight."] {
            XCTAssertTrue(spoken.contains(words), "\(words) was not spoken")
        }

        let reports = progress.reports
        XCTAssertEqual(reports.first, .speaking(done: 0, total: 3, fraction: 0), "\(reports)")
        XCTAssertTrue(reports.contains(where: \.isEncoding), "the encoding was not heard: \(reports)")
        XCTAssertTrue(
            reports.drop(while: { !$0.isEncoding }).allSatisfy(\.isEncoding),
            "the speaking was heard after the encoding began: \(reports)"
        )
        XCTAssertEqual(reports.last, .encoding(chapters: 3, fraction: 1), "\(reports)")
    }

    /// Stop pressed while the book is spoken (the fake presses it as the
    /// second chapter begins) ends the export: nothing is left in the folder,
    /// nothing more is spoken or encoded, and the outcome says it was
    /// stopped, with no failure.
    func testStopWhileSpeakingLeavesNothingAndIsNoFailure() async throws {
        let world = try makeIntegrationWorld("Speech Export Stop")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let folder = try makeSandboxDirectory("Speech Export Stop Folder")
        let cancellation = BookExportCancellation()
        let synthesizer = FakeSpeechBufferSynthesizer(framesPerUnit: 1_000, beforeWrite: { utterance in
            if utterance.text.contains("Four") {
                cancellation.cancel()
            }
        })
        let progress = ProgressRecord()
        let context = try speechContext(synthesizer: synthesizer, progress: progress)
        let offer = BookExportService.offer(for: book)
        let conversions: [BookExportKind: BookExportConversion] = [.spokenAudio: .speech(Self.request(for: book))]

        let outcome = await OffMainWork.run {
            BookExportService.export(
                [offer],
                kinds: [.spokenAudio],
                conversions: conversions,
                to: folder,
                cancellation: cancellation,
                speech: context
            )
        }

        XCTAssertTrue(cancellation.isCancelled, "the fake never pressed Stop")
        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(outcome.exported, [])
        XCTAssertEqual(outcome.failures, [], "Stop was a failure")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
        XCTAssertEqual(BookExportWording.finished(outcome, folderName: "Exports"), "Export stopped. Nothing was exported.")
        XCTAssertFalse(synthesizer.written.contains { $0.text.contains("Six") }, "the speaking went on after Stop")
        XCTAssertFalse(progress.reports.contains(where: \.isEncoding), "the encoding began after Stop")
    }

    /// A speech export refused before it speaks (the book's voice is a
    /// Personal Voice) fails alone: the file is named with the refusal's
    /// sentence, nothing is spoken or left of it, and the plain text
    /// exported beside it is written.
    func testAPersonalVoiceIsAFailureNamingTheFileAndTheRestIsExported() async throws {
        let world = try makeIntegrationWorld("Speech Export Personal Voice")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let stem = BookExportService.fileNameStem(for: book.title)
        let folder = try makeSandboxDirectory("Speech Export Personal Voice Folder")
        let synthesizer = FakeSpeechBufferSynthesizer()
        let context = try speechContext(synthesizer: synthesizer, voiceIsPersonal: true)
        let offer = BookExportService.offer(for: book)
        let conversions: [BookExportKind: BookExportConversion] = [.spokenAudio: .speech(Self.request(for: book))]

        let outcome = await OffMainWork.run {
            BookExportService.export(
                [offer],
                kinds: [.plainText, .spokenAudio],
                conversions: conversions,
                to: folder,
                speech: context
            )
        }

        XCTAssertFalse(outcome.wasCancelled)
        XCTAssertEqual(outcome.exported, [folder.appendingPathComponent("\(stem) - Text.txt")], "the plain text was not written")
        XCTAssertEqual(outcome.failures, [
            BookExportFailure(
                name: "\(stem) - Audio.m4b",
                reason: SpeechExportError.personalVoice(name: "Test Personal").localizedDescription
            ),
        ])
        XCTAssertEqual(
            BookExportWording.failureSentence(outcome.failures),
            "Couldn't export \(stem) - Audio.m4b: “Test Personal” is a Personal Voice, which macOS can't record to a file. "
                + "Choose another voice for this book with the Voice button in its reader, then export again."
        )
        XCTAssertEqual(synthesizer.written, [], "a word was spoken")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["\(stem) - Text.txt"])
    }

    /// Spoken audio whose text cache is only in the cloud is never spoken: an
    /// export of it with its speech conversion names the book among those in
    /// the cloud, never reading its text or speaking a word.
    func testSpokenAudioInTheCloudIsNeverSpoken() async throws {
        let world = try makeIntegrationWorld("Speech Export Cloud Export")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let cache = MarkdownCacheService.cacheURL(for: book)
        let cloud = FakeCloudFiles()
        cloud.markDataless(cache)
        cloud.refuseReads(of: cache)
        let access = cloud.access
        let folder = try makeSandboxDirectory("Speech Export Cloud Export Folder")
        let synthesizer = FakeSpeechBufferSynthesizer()
        let context = try speechContext(synthesizer: synthesizer)
        let offer = BookExportService.offer(for: book, access: access)
        let conversions: [BookExportKind: BookExportConversion] = [.spokenAudio: .speech(Self.request(for: book))]

        let outcome = await OffMainWork.run {
            BookExportService.export(
                [offer],
                kinds: [.spokenAudio],
                conversions: conversions,
                to: folder,
                access: access,
                speech: context
            )
        }

        XCTAssertEqual(outcome.booksInCloud, [BookExportBookName(book)])
        XCTAssertEqual(outcome.exported, [])
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(cloud.refusedReads, [], "the text in the cloud was read")
        XCTAssertEqual(synthesizer.written, [], "a word was spoken")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    // MARK: - The Words

    /// The kind's name, hint, and checkbox label, which says no size, even
    /// given one, and no file count; a conversion's name never changes them.
    func testTheKindsWords() {
        XCTAssertEqual(BookExportKind.spokenAudio.order, BookExportKind.plainText.order + 1, "listed right after the plain text")
        XCTAssertFalse(BookExportKind.spokenAudio.convertsText)
        XCTAssertEqual(BookExportWording.name(of: .spokenAudio), "Text as spoken audio")
        XCTAssertEqual(
            BookExportWording.hint(for: .spokenAudio),
            "The book's text spoken by its voice into one audio file, with a chapter for each heading."
        )
        XCTAssertEqual(BookExportWording.name(of: .spokenAudio, convertedTo: "HTML"), "Text as spoken audio")
        XCTAssertEqual(BookExportWording.hint(for: .spokenAudio, convertedTo: "HTML"), BookExportWording.hint(for: .spokenAudio))
        XCTAssertEqual(
            BookExportWording.choiceLabel(kind: .spokenAudio, bookCount: 1, availableItemCount: 1, fileCount: 1, byteCount: 0, inCloudCount: 0),
            "Text as spoken audio"
        )
        XCTAssertEqual(
            BookExportWording.choiceLabel(
                kind: .spokenAudio, bookCount: 1, availableItemCount: 1, fileCount: 2, byteCount: 1_200_000, inCloudCount: 0
            ),
            "Text as spoken audio",
            "a size or a file count was said"
        )
        XCTAssertEqual(
            BookExportWording.choiceLabel(
                kind: .spokenAudio, bookCount: 1, availableItemCount: 1, fileCount: 1, byteCount: 0, inCloudCount: 0,
                convertedTo: "HTML"
            ),
            "Text as spoken audio"
        )
        XCTAssertEqual(
            BookExportWording.choiceLabel(kind: .spokenAudio, bookCount: 1, availableItemCount: 0, fileCount: 0, byteCount: 0, inCloudCount: 1),
            "Text as spoken audio, in the cloud"
        )
    }

    // MARK: - Fixtures

    /// Two chapters with three headings, the last of level 2, as a Markdown
    /// book with chapter markers holds them: one chapter of the spoken file
    /// for each heading.
    private static let twoChapters = """
    <!-- chapter: First -->
    # First

    One two three.

    <!-- chapter: Second -->
    # Second

    Four five.

    ## Later

    Six seven eight.
    """

    /// The identifier of the tests' voice, which no Mac has: only the test's
    /// own lookup knows it.
    private static let voiceIdentifier = "com.textmouth.tests.speech-export-service"

    /// Settings that prepare speech as the text is written: runs of a symbol
    /// read as written, no pauses, and no substitutions.
    private static let asWritten = SpeechPreparationSettings(
        repeatedSymbolRule: RepeatedSymbolRule(
            style: .repeatEach,
            threshold: SettingsPolicy.repeatedSymbolThreshold.defaultValue,
            symbols: SettingsPolicy.repeatedSymbolSet.defaultValue
        ),
        punctuationPauseLevel: 0,
        substitutions: .none
    )

    /// Writes the two-chapter book as a file named `name` in a sandbox
    /// folder of its own, for an import to read.
    private func writeSource(named name: String) throws -> URL {
        let file = try makeSandboxDirectory("Speech Export Source").appendingPathComponent(name)
        try Data(Self.twoChapters.utf8).write(to: file)
        return file
    }

    /// The request the Export dialog makes for `book`: the whole book,
    /// spoken by the tests' voice at 200 words a minute and its own pitch,
    /// as written, into a file of `format` named `fileTitle`, or as the offer
    /// names it ("<stem> - Audio") when none is given, titled after the book.
    private static func request(
        for book: Book,
        fileTitle: String? = nil,
        format: SpeechExportFormat = .m4b
    ) -> SpeechExportRequest {
        SpeechExportRequest(
            bookID: book.id,
            bookTitle: book.title,
            fileTitle: fileTitle ?? "\(BookExportService.fileNameStem(for: book.title)) - Audio",
            titleTag: book.title,
            author: nil,
            format: format,
            range: .wholeBook,
            voice: SpeechExportVoiceSettings(voiceIdentifier: voiceIdentifier, wordsPerMinute: 200, pitch: 1),
            skippedHeadingIDs: [],
            preparation: asWritten
        )
    }

    /// What a speech export runs with in these tests: `synthesizer`; a voice
    /// lookup that knows the tests' voice alone, as "Test Voice", or as the
    /// Personal Voice "Test Personal" when `voiceIsPersonal`; a power
    /// assertion the system never takes, so nothing is kept awake; 100 GB
    /// free on every disk, all one volume; and a store root in a sandbox
    /// folder of its own. Its progress goes to `progress`, when given.
    private func speechContext(
        synthesizer: FakeSpeechBufferSynthesizer,
        voiceIsPersonal: Bool = false,
        progress: ProgressRecord? = nil
    ) throws -> SpeechExportContext {
        // Read here, on the main actor, for the lookup to capture.
        let voice = Self.voiceIdentifier
        let name = voiceIsPersonal ? "Test Personal" : "Test Voice"
        let storeRoot = try makeSandboxDirectory("Speech Export Service Store")
            .appendingPathComponent("Speech Export", isDirectory: true)
        let environment = SpeechExportEnvironment(
            synthesizer: synthesizer,
            voiceInfo: { identifier in
                identifier == voice
                    ? SpeechExportVoiceInfo(identifier: identifier, name: name, isPersonalVoice: voiceIsPersonal)
                    : nil
            },
            power: SpeechExportPower(hold: { _ in nil }, release: { _ in }),
            freeSpace: { _ in 100_000_000_000 },
            sameVolume: { _, _ in true },
            storeRoot: storeRoot
        )
        return SpeechExportContext(environment: environment, progress: { report in progress?.add(report) })
    }
}

// MARK: - Progress Heard

/// The progress a speech export reports, kept in order: the export reports on
/// its own thread, and the test reads once it has ended.
private final class ProgressRecord: Sendable {
    /// Every report so far, in order.
    private let record = OSAllocatedUnfairLock<[SpeechExportProgress]>(initialState: [])

    /// Keeps `report`.
    func add(_ report: SpeechExportProgress) {
        record.withLock { $0.append(report) }
    }

    /// Every report so far, in order.
    var reports: [SpeechExportProgress] {
        record.withLock { $0 }
    }
}

private extension SpeechExportProgress {
    /// Whether this reports the encoding, rather than the speaking.
    var isEncoding: Bool {
        if case .encoding = self { return true }
        return false
    }
}
