import Combine
import os
import XCTest
@testable import TextMouth

/// A book read again in the encoding the listener chose in Book Information,
/// or automatically (encodingchoice): the text, the record, and the row
/// after it; the places, which move with their words; text changed with Edit
/// Text, kept beside the new reading; an open reader, which shows the new
/// text; and every refusal, after which nothing has changed. Each book is a
/// package in this test's own library folder (`CloudMaintenanceTestCase`).
@MainActor
final class TextEncodingRereadTests: CloudMaintenanceTestCase {

    // MARK: - Fixtures

    /// Three paragraphs of Russian prose, long enough that no line is taken
    /// for a heading.
    private static let russian = """
        Утренний паром отходит от северной пристани ровно в семь, и опоздавшие пассажиры долго машут ему с берега.

        На борту продают горячий чай, булки с маком и вчерашние газеты, а капитан не любит ни спешки, ни громких разговоров.

        Через час показывается остров с серыми скалами, рыбацкими сетями и единственной улицей, где живут двести человек.

        """

    /// The same prose with an English sentence between its paragraphs, which
    /// any reading of its bytes in a Western or Cyrillic encoding shares.
    private static let russianWithEnglish = """
        Утренний паром отходит от северной пристани ровно в семь, и опоздавшие пассажиры долго машут ему с берега.

        The ferry timetable is posted beside the harbour office door every spring.

        На борту продают горячий чай, булки с маком и вчерашние газеты, а капитан не любит ни спешки, ни громких разговоров.

        Через час показывается остров с серыми скалами, рыбацкими сетями и единственной улицей, где живут двести человек.

        """

    /// A plain-text book titled `title` in a package of its own in this
    /// test's folder, whose file holds `text` written in the encoding named
    /// `writtenIn`, read as `record` says, with its text cache committed, as
    /// a book imported from the listener's own file is.
    private func makeTextBook(
        _ title: String,
        text: String = TextEncodingRereadTests.russian,
        writtenIn: String = "windows-1251",
        record: TextEncodingRecord = TextEncodingRecord(identifier: "windows-1251", source: nil)
    ) throws -> Book {
        let packageName = "\(title)-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let source = package.appendingPathComponent("\(title).txt")
        let encoding = try XCTUnwrap(TextFileDecoder.encoding(forLabel: writtenIn), writtenIn)
        try XCTUnwrap(text.data(using: encoding, allowLossyConversion: false), writtenIn).write(to: source)
        var book = Book(
            title: title, format: .txt, filePath: source.path, md5Hash: UUID().uuidString, folderPath: folderPath,
            tmbDirectoryName: packageName, sourceFilePath: "/Users/someone/Documents/\(title).txt", cacheFormatVersion: "3.0.3"
        )
        book.textEncodingRecord = record
        return try commitCache(of: book)
    }

    /// `book`'s file read as `policy` says, as a reader's plain text.
    private func reading(of book: Book, _ policy: TextFileDecoder.EncodingPolicy) throws -> String {
        try TextFileDecoder.decode(
            Data(contentsOf: book.bookFileURL), fileName: book.bookFileURL.lastPathComponent, format: .txt, policy: policy
        ).text
    }

    /// What content.md of `book` holds.
    private func cachedText(of book: Book) throws -> String {
        try String(contentsOf: MarkdownCacheService.cacheURL(for: book), encoding: .utf8)
    }

    /// The encoding the package record of `book` holds, with who decided it.
    private func recordedEncoding(of book: Book) throws -> TextEncodingRecord {
        try BookInfo.load(from: book.tmbDirectory).metadata.textEncodingRecord
    }

    /// The copies of text TextMouth did not write, kept beside `book`'s
    /// content.md.
    private func keptCopies(of book: Book) -> [URL] {
        LibraryIndexQuarantine.existingCopies(of: MarkdownCacheService.cacheURL(for: book), marker: TextMouthPaths.keptTextCopyMarker)
    }

    /// An Edit Text editor for `model`, sharing its sessions, which stands in
    /// for the listener and the system: its first-use explanation is
    /// `explain`, which goes on unless a test gives its own, no app is
    /// chosen, a file it opens is only noted in `opened`, and TextMouth is
    /// active. The caller ends its sessions (`BookTextEditor.endAll()`).
    private func makeEditor(
        for model: LibraryViewModel,
        explain: @escaping BookTextEditor.Explainer = { _, _ in true }
    ) -> (editor: BookTextEditor, opened: OSAllocatedUnfairLock<[URL]>) {
        let sessions = BookTextEditSessions()
        model.textEditSessions = sessions
        let opened = OSAllocatedUnfairLock<[URL]>(initialState: [])
        let editor = BookTextEditor(
            sessions: sessions,
            preferences: makeSandboxedPreferences("Edit Text"),
            notificationCenter: NotificationCenter(),
            explain: explain,
            chooseApp: { _, _ in nil },
            open: { file, _ in opened.withLock { $0.append(file) } },
            isAppActive: { true }
        )
        model.bookTextEditor = { editor }
        return (editor, opened)
    }

    /// What `model` makes of reading `book` again as `option`, with every
    /// announcement it makes on the way.
    private func readAgain(
        _ book: Book,
        as option: TextEncodingOption,
        in model: LibraryViewModel,
        access: MaintenanceFileAccess = .live
    ) async -> (outcome: OperationOutcome, announced: [String]) {
        var announced: [String] = []
        let previous = VoiceOverAnnouncer.poster
        VoiceOverAnnouncer.poster = { announcement, _ in announced.append(announcement.message) }
        defer { VoiceOverAnnouncer.poster = previous }
        let outcome = await model.readTextAgain(bookID: book.id, as: option, access: access)
        return (outcome, announced)
    }

    /// What `model` makes of reading `book` again as `option`, held inside its
    /// rebuild, once it has chosen where content.md goes and before it reads
    /// the book's file (`MarkdownCacheService.extractionObserver`), while
    /// `meanwhile` runs on the main actor; then let go to finish.
    private func readAgainHeldInItsRebuild(
        _ book: Book,
        as option: TextEncodingOption,
        in model: LibraryViewModel,
        meanwhile: () async throws -> Void
    ) async throws -> OperationOutcome {
        let reached = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        let bookID = book.id
        MarkdownCacheService.extractionObserver = { observed in
            guard observed.id == bookID else { return }
            reached.withLock { $0 = true }
            _ = release.wait(timeout: .now() + 20)
        }
        defer { MarkdownCacheService.extractionObserver = nil }
        let run = Task { await model.readTextAgain(bookID: bookID, as: option) }
        var held = false
        for _ in 0..<1_000 where !held {
            held = reached.withLock { $0 }
            if !held { try await Task.sleep(nanoseconds: 10_000_000) }
        }
        XCTAssertTrue(held, "the re-read never reached its rebuild")
        do {
            try await meanwhile()
        } catch {
            release.signal()
            _ = await run.value
            throw error
        }
        release.signal()
        return await run.value
    }

    // MARK: - Reading Again

    /// A choice reads the book again in the encoding chosen: content.md, the
    /// row, and the record hold the new reading and the choice, VoiceOver
    /// hears it, and the log says it.
    func testAChoiceReadsTheBookAgainAndRecordsIt() async throws {
        let title = "Ferry \(UUID().uuidString.prefix(8))"
        let book = try makeTextBook(title)
        let model = makeModel(with: [book])
        let koi8 = try reading(of: book, .chosen("koi8-r"))
        XCTAssertNotEqual(koi8, Self.russian, "KOI8-R must read the file otherwise, or this proves nothing")

        let (outcome, announced) = await readAgain(book, as: .encoding("koi8-r"), in: model)

        let said = "“\(title)” is now read as KOI8-R (Russian), chosen."
        XCTAssertEqual(outcome, .success(said))
        XCTAssertEqual(announced, [said])
        XCTAssertEqual(try cachedText(of: book), PlainTextParser.markdown(text: koi8))
        let chosen = TextEncodingRecord(identifier: "koi8-r", source: .chosen)
        XCTAssertEqual(model.bookByID(book.id)?.textEncodingRecord, chosen)
        XCTAssertEqual(try recordedEncoding(of: book), chosen)
        XCTAssertEqual(logLineCount("TEXT_ENCODING_CHANGED: \(title): read again as koi8-r, chosen"), 1)
        XCTAssertEqual(keptCopies(of: book), [], "TextMouth's own text is not kept")
    }

    /// Automatic reads the book again as an import does, which puts the
    /// guess back, and records that the listener chose Automatic.
    func testAutomaticPutsTheGuessBack() async throws {
        let title = "Island \(UUID().uuidString.prefix(8))"
        let book = try makeTextBook(title, record: TextEncodingRecord(identifier: "koi8-r", source: .chosen))
        let model = makeModel(with: [book])
        XCTAssertNotEqual(try cachedText(of: book), PlainTextParser.markdown(text: Self.russian))

        let (outcome, _) = await readAgain(book, as: .automatic, in: model)

        XCTAssertEqual(outcome, .success("“\(title)” is now read as Windows-1251 (Cyrillic), guessed."))
        XCTAssertEqual(try cachedText(of: book), PlainTextParser.markdown(text: Self.russian))
        let guessed = TextEncodingRecord(identifier: "windows-1251", source: .automatic)
        XCTAssertEqual(model.bookByID(book.id)?.textEncodingRecord, guessed)
        XCTAssertEqual(try recordedEncoding(of: book), guessed)
        XCTAssertEqual(logLineCount("TEXT_ENCODING_CHANGED: \(title): read again automatically, as windows-1251, guessed"), 1)
    }

    /// Automatic with nothing to record clears a choice from the row and the
    /// record alike, so no later reading takes the old choice back: a UTF-8
    /// file, chosen to be read as Windows-1251, is UTF-8 again for good.
    func testAutomaticWithNothingToRecordClearsAChoice() async throws {
        let title = "Harbour \(UUID().uuidString.prefix(8))"
        let english = "The ferry leaves at seven; café, naïve, “quoted”, and £5 are all in UTF-8 here.\n"
        let book = try makeTextBook(
            title, text: english, writtenIn: "utf-8", record: TextEncodingRecord(identifier: "windows-1251", source: .chosen)
        )
        let model = makeModel(with: [book])
        XCTAssertNotEqual(try cachedText(of: book), PlainTextParser.markdown(text: english))

        let (outcome, _) = await readAgain(book, as: .automatic, in: model)

        XCTAssertEqual(outcome, .success("“\(title)” is now read as UTF-8."))
        XCTAssertEqual(try cachedText(of: book), PlainTextParser.markdown(text: english))
        let automatic = TextEncodingRecord(identifier: nil, source: .automatic)
        let row = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(row.textEncodingRecord, automatic)
        XCTAssertEqual(try recordedEncoding(of: book), automatic)
        // A row that lost both fields takes the record's nothing, not the old choice.
        var lost = row
        lost.textEncodingRecord = .unrecorded
        XCTAssertEqual(lost.recordedTextEncodingRecord(), automatic)
        XCTAssertEqual(logLineCount("TEXT_ENCODING_CHANGED: \(title): read again automatically, with no encoding to record"), 1)
    }

    /// A name the catalog gives two entries is read in the one that reads
    /// every byte: a Big5 file holding 碁 as Windows writes it (0xF9 0xD6,
    /// which Big5 itself lacks) is read as CP950 when Big5 is chosen.
    func testANameOfTwoEntriesIsReadInTheOneThatReadsTheFile() async throws {
        let title = "Go \(UUID().uuidString.prefix(8))"
        let text = "圍棋的棋子叫做碁子，渡輪七點開。\n"
        let book = try makeTextBook(title, text: text, writtenIn: "cp950", record: .unrecorded)
        let model = makeModel(with: [book])

        let (outcome, _) = await readAgain(book, as: .encoding("big5"), in: model)

        XCTAssertEqual(outcome, .success("“\(title)” is now read as Big5 (Traditional Chinese), chosen."))
        XCTAssertEqual(model.bookByID(book.id)?.textEncodingRecord, TextEncodingRecord(identifier: "cp950", source: .chosen))
        XCTAssertEqual(try cachedText(of: book), PlainTextParser.markdown(text: text))
    }

    // MARK: - Refused, With Nothing Changed

    /// Bytes that are not valid in the encoding chosen are refused, naming
    /// it, and nothing changes: not the text, not the record, not the row,
    /// and no copy is kept.
    func testBytesNotValidInTheChoiceAreRefusedAndNothingChanges() async throws {
        let title = "Pier \(UUID().uuidString.prefix(8))"
        let book = try makeTextBook(title)
        let model = makeModel(with: [book])
        let textBefore = try Data(contentsOf: MarkdownCacheService.cacheURL(for: book))
        let recordBefore = try recordedEncoding(of: book)

        let (outcome, announced) = await readAgain(book, as: .encoding("utf-8"), in: model)

        XCTAssertEqual(
            outcome,
            .failure("“\(title)” can't be read as UTF-8: it holds bytes that are not valid in that encoding. Nothing was changed.")
        )
        XCTAssertEqual(announced, [], "the sheet says a refusal, not the library")
        XCTAssertEqual(try Data(contentsOf: MarkdownCacheService.cacheURL(for: book)), textBefore)
        XCTAssertEqual(try recordedEncoding(of: book), recordBefore)
        XCTAssertEqual(model.bookByID(book.id)?.textEncodingRecord, book.textEncodingRecord)
        XCTAssertEqual(keptCopies(of: book), [])
    }

    /// Each refusal says why, and changes nothing: another operation holding
    /// the library's storage work, the library's text being read again, an
    /// export, a file only in the cloud, a book gone, and a book that offers
    /// no choice. Edit Text is no refusal: it stops for the re-read
    /// (`testEditTextStopsForTheRereadAndItsEditIsKept`).
    func testEachRefusalSaysWhyAndChangesNothing() async throws {
        let title = "Quay \(UUID().uuidString.prefix(8))"
        let book = try makeTextBook(title)
        let model = makeModel(with: [book])
        let cache = MarkdownCacheService.cacheURL(for: book)
        let textBefore = try Data(contentsOf: cache)
        func expectRefusal(_ expected: String, access: MaintenanceFileAccess = .live, line: UInt = #line) async {
            let (outcome, _) = await readAgain(book, as: .encoding("koi8-r"), in: model, access: access)
            XCTAssertEqual(outcome, .failure(expected), line: line)
            XCTAssertEqual(try? Data(contentsOf: cache), textBefore, "the text changed", line: line)
            XCTAssertEqual(model.bookByID(book.id)?.textEncodingRecord, book.textEncodingRecord, line: line)
        }

        let hold = try StorageBoundary.shared.holdWork(for: .movingBooksBetweenFolders)
        await expectRefusal("TextMouth is moving books between folders. Try again when that finishes.")
        hold.release()

        model.textExtraction.begin("Updating text cache", total: 1)
        await expectRefusal("TextMouth is reading the library's text again. Try again when that finishes.")
        model.textExtraction.end()

        BookExportModel.noteExportStarted([book.id])
        await expectRefusal("“\(title)” is being exported. Wait until the export ends, then try again.")
        BookExportModel.noteExportEnded([book.id])

        cloud.markDataless(book.bookFileURL)
        await expectRefusal(LibraryCloudWording.notDownloaded(titles: [title]), access: cloud.access)
        XCTAssertEqual(cloud.refusedReads, [], "nothing was read to find it in the cloud")

        let (gone, _) = await readAgain(Book(title: "Gone", format: .txt, filePath: "/nowhere", md5Hash: "gone"), as: .automatic, in: model)
        XCTAssertEqual(gone, .failure("The book is no longer in the library, so it was not read again."))

        var typed = try makeTextBook("Typed \(UUID().uuidString.prefix(8))", record: .unrecorded)
        typed.sourceFilePath = nil
        model.library.books.append(typed)
        let (offered, _) = await readAgain(typed, as: .encoding("koi8-r"), in: model)
        XCTAssertEqual(offered, .failure("TextMouth couldn't read “\(typed.title)” again, so it left the book as it was."))
    }

    /// A commit the book's record drops, here because its file was replaced
    /// meanwhile, leaves the book as it was, as the refusal says: content.md
    /// is put back, byte for byte and with its dates, so no later load takes
    /// the new reading for text changed by hand (review of October 24,
    /// finding 2).
    func testADroppedCommitPutsTheTextBack() async throws {
        let title = "Breakwater \(UUID().uuidString.prefix(8))"
        let book = try makeTextBook(title)
        let model = makeModel(with: [book])
        let cache = MarkdownCacheService.cacheURL(for: book)
        let textBefore = try Data(contentsOf: cache)
        let stampBefore = FileStamp(of: cache)

        let outcome = try await readAgainHeldInItsRebuild(book, as: .encoding("koi8-r"), in: model) {
            // The record now names another file, as after a replacement.
            let recordURL = TextMouthPaths.bookInfoPath(in: book.tmbDirectory)
            var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
            var metadata = try XCTUnwrap(record["metadata"] as? [String: Any])
            metadata["md5Hash"] = "another file"
            record["metadata"] = metadata
            try JSONSerialization.data(withJSONObject: record).write(to: recordURL)
        }

        XCTAssertEqual(outcome, .failure("TextMouth couldn't read “\(title)” again, so it left the book as it was."))
        XCTAssertEqual(try Data(contentsOf: cache), textBefore, "content.md kept the new reading")
        XCTAssertEqual(FileStamp(of: cache), stampBefore, "content.md was not put back with its dates")
        XCTAssertEqual(try recordedEncoding(of: book), book.textEncodingRecord)
        XCTAssertEqual(model.bookByID(book.id)?.textEncodingRecord, book.textEncodingRecord)
    }

    /// A reader opened while the book is read again is given the new text, as
    /// one open when it began is: which readers are open is decided at the
    /// commit, as the batch decides it (review of October 24, finding 4).
    func testAReaderOpenedDuringTheReadIsGivenTheNewText() async throws {
        let book = try makeTextBook("Slipway \(UUID().uuidString.prefix(8))")
        let model = makeModel(with: [book])
        var events: [LibraryBookEvent] = []
        let subscription = model.bookUpdates.events(for: book.id).sink { events.append($0) }
        defer { subscription.cancel() }

        let outcome = try await readAgainHeldInItsRebuild(book, as: .encoding("koi8-r"), in: model) {
            model.openBookIDs.insert(book.id)
            model.bookUpdates.watch(book)
        }

        XCTAssertTrue(outcome.succeeded, "\(outcome)")
        XCTAssertTrue(events.contains { if case .textReplaced = $0 { return true } else { return false } }, "\(events)")
    }

    /// A save of the book's row that lags behind the re-read, as a reader's
    /// checkpoint between the record's commit and the row's update can, does
    /// not write the old encoding back beside the new text: only a re-read
    /// replaces the decision the record holds (review of October 24,
    /// finding 5).
    func testALaggingRowDoesNotWriteTheOldEncodingBack() async throws {
        let book = try makeTextBook("Bollard \(UUID().uuidString.prefix(8))")
        let model = makeModel(with: [book])
        let (outcome, _) = await readAgain(book, as: .encoding("koi8-r"), in: model)
        XCTAssertTrue(outcome.succeeded, "\(outcome)")

        // The row as it was before the re-read, saved as a checkpoint saves it.
        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try recordedEncoding(of: book), TextEncodingRecord(identifier: "koi8-r", source: .chosen))
    }

    /// While a book is read again, what would rewrite its text waits, in the
    /// same words: a second re-read of it, Redo Text Extraction, which
    /// starts no pass, and Edit Text, which opens nothing and begins no
    /// session. The book is busy no longer once the re-read ends (review of
    /// October 24, finding 3).
    func testWhatWouldRewriteTheTextWaitsForTheReread() async throws {
        let title = "Mooring \(UUID().uuidString.prefix(8))"
        let book = try makeTextBook(title)
        let model = makeModel(with: [book])
        let (editor, opened) = makeEditor(for: model)
        defer { editor.endAll() }
        let busy = "TextMouth is reading “\(title)” again in another encoding. Try again when that finishes."
        var announced: [String] = []

        let outcome = try await readAgainHeldInItsRebuild(book, as: .encoding("koi8-r"), in: model) {
            let (second, _) = await readAgain(book, as: .automatic, in: model)
            XCTAssertEqual(second, .failure(busy))
            XCTAssertFalse(model.redoAllTextExtraction(), "Redo Text Extraction started")
            let redo = await model.redoAllTextExtractionReturningOutcome()
            XCTAssertEqual(redo, .failure(busy))
            let previous = VoiceOverAnnouncer.poster
            VoiceOverAnnouncer.poster = { announcement, _ in announced.append(announcement.message) }
            defer { VoiceOverAnnouncer.poster = previous }
            await editor.edit(book, choosingApp: false, in: model, from: nil)
        }

        XCTAssertTrue(outcome.succeeded, "\(outcome)")
        XCTAssertEqual(announced, [busy])
        XCTAssertFalse(editor.sessions.isEditing(book.id), "a session began")
        XCTAssertEqual(opened.withLock { $0 }, [], "an editor opened")
        XCTAssertNil(model.readingAgainRefusal(), "the book is still busy")
        XCTAssertFalse(model.isExtracting)
    }

    // MARK: - Around the Re-read

    /// A quit waits while a book is read again and goes ahead once the
    /// re-read is over: stopped between content.md's write and the record's,
    /// the re-read would leave the new reading beside the old record, which
    /// the next launch takes for an edit saved while TextMouth was closed
    /// (review of October 25, item 1). A library reading nothing again holds
    /// no quit.
    func testAQuitWaitsForTheReread() async throws {
        let book = try makeTextBook("Halyard \(UUID().uuidString.prefix(8))")
        let model = makeModel(with: [book])
        model.textRereads = TextRereads()
        let rereads = model.textRereads
        var replies: [Bool] = []
        XCTAssertFalse(QuitHold.hold([rereads.quitWork()]) { _ in XCTFail("a library reading nothing again held the quit") })

        let outcome = try await readAgainHeldInItsRebuild(book, as: .encoding("koi8-r"), in: model) {
            XCTAssertTrue(QuitHold.hold([rereads.quitWork()]) { replies.append($0) }, "the quit was not held")
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(replies, [], "the quit went ahead while the book was read again")
        }

        XCTAssertTrue(outcome.succeeded, "\(outcome)")
        for _ in 0..<500 where replies.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(replies, [true], "the quit was not answered once the re-read was over")
    }

    /// The content.md a re-read has written, before its record is
    /// committed, with the book marked as being read again, as the re-read
    /// leaves it between the two writes; returns that text.
    private func markAsMidReread(_ book: Book, in model: LibraryViewModel) throws -> String {
        let written = PlainTextParser.markdown(text: try reading(of: book, .chosen("koi8-r")))
        try written.write(to: MarkdownCacheService.cacheURL(for: book), atomically: true, encoding: .utf8)
        model.booksBeingReadAgain.insert(book.id)
        return written
    }

    /// The launch's text batch leaves a book being read again alone: the
    /// content.md the re-read has written is neither taken for an edit
    /// saved while TextMouth was closed nor read again from the book's file
    /// (review of October 25, item 2).
    func testTheLaunchBatchLeavesABookBeingReadAgainAlone() async throws {
        let book = try makeTextBook("Lantern \(UUID().uuidString.prefix(8))")
        let model = makeModel(with: [book])
        let written = try markAsMidReread(book, in: model)
        defer { model.booksBeingReadAgain.remove(book.id) }

        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            model.extractMissingContentCaches(access: .live) { finished.resume() }
        }

        XCTAssertEqual(try cachedText(of: book), written, "the batch rewrote content.md")
        XCTAssertNil(try BookInfo.load(from: book.tmbDirectory).state.editedText, "the batch took the new reading for an edit")
    }

    /// A reader that opens a book while it is read again loads it only once
    /// the re-read is over: before, its load took the content.md the re-read
    /// had written for a stale cache and read the file again over it, in
    /// the old encoding (review of October 25, item 2).
    func testAReaderOpenedDuringTheRereadLoadsOnceItIsOver() async throws {
        let book = try makeTextBook("Tidewater \(UUID().uuidString.prefix(8))")
        let model = makeModel(with: [book])
        let written = try markAsMidReread(book, in: model)
        let loads = DispatchQueue(label: "TextEncodingRereadTests.loads")

        let reader = ReaderViewModel(
            book: book,
            libraryViewModel: model,
            settingsViewModel: SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false),
            loadQueue: loads
        )
        addTeardownBlock { @MainActor in reader.close() }
        // Whatever read the load began has run.
        loads.sync {}

        XCTAssertTrue(reader.isLoading)
        XCTAssertEqual(try cachedText(of: book), written, "the load read the file again over the re-read's text")

        model.booksBeingReadAgain.remove(book.id)
        for _ in 0..<500 where reader.isLoading {
            try await Task.sleep(nanoseconds: 10_000_000)
            loads.sync {}
        }
        XCTAssertFalse(reader.isLoading, "the reader never loaded once the re-read was over")
    }

    /// Edit Text, asked to begin while a re-read runs from start to end
    /// behind its first-use explanation, begins from the text the re-read
    /// left, so it never takes the new reading for the listener's edit
    /// (review of October 25, item 2).
    func testEditTextBeginsFromTheTextAReadAgainBehindItsDialogLeft() async throws {
        let book = try makeTextBook("Ropewalk \(UUID().uuidString.prefix(8))")
        let model = makeModel(with: [book])
        let (editor, _) = makeEditor(for: model) { _, _ in
            let (outcome, _) = await self.readAgain(book, as: .encoding("koi8-r"), in: model)
            XCTAssertTrue(outcome.succeeded, "\(outcome)")
            return true
        }
        defer { editor.endAll() }

        await editor.edit(book, choosingApp: false, in: model, from: nil)
        XCTAssertTrue(editor.sessions.isEditing(book.id), "no session began")
        // A check of the book, as TextMouth becoming active makes one.
        editor.check(book.id)
        let checks = editor.sessions.queue
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in checks.async { done.resume() } }

        XCTAssertNil(model.bookByID(book.id)?.editedText, "the new reading was taken for an edit")
        XCTAssertNil(try BookInfo.load(from: book.tmbDirectory).state.editedText)
    }

    /// A rebuild reads the book in the decision its record holds, as the
    /// record's saves keep it, even while the library row lags behind it,
    /// as after a stop before library.json was saved, or another Mac's
    /// re-read; the rebuilt book takes the decision it was read in (review
    /// of October 25, item 3).
    func testARebuildReadsTheRecordsDecisionOverALaggingRow() throws {
        let book = try makeTextBook("Sounding \(UUID().uuidString.prefix(8))")
        let chosen = TextEncodingRecord(identifier: "koi8-r", source: .chosen)
        var decided = book
        decided.textEncodingRecord = chosen
        try decided.saveBookInfoThrowing()
        XCTAssertEqual(try recordedEncoding(of: book), chosen, "the record must hold the decision, or this proves nothing")
        let koi8 = try reading(of: book, .chosen("koi8-r"))

        XCTAssertEqual(book.recordedTextEncodingRecord(), chosen)
        var rebuilt = book
        XCTAssertNotNil(try MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(for: &rebuilt))

        XCTAssertEqual(try cachedText(of: book), PlainTextParser.markdown(text: koi8))
        XCTAssertEqual(rebuilt.textEncodingRecord, chosen)
    }

    // MARK: - Places

    /// The book's places move with the text. Where the new reading shares
    /// none of a place's words, as when text garbled by a wrong encoding
    /// becomes Cyrillic, and the two readings share no passage at all, the
    /// place goes to about the same point in its chapter (`PlaceRelocator`'s
    /// last guess), which, for two encodings of one byte to a character,
    /// whose readings are as long, is the word it was at, or within a
    /// character of it.
    func testPlacesMoveWithTheTextWhereNoWordIsShared() async throws {
        let title = "Gulls \(UUID().uuidString.prefix(8))"
        var book = try makeTextBook(title, record: TextEncodingRecord(identifier: "windows-1252", source: .chosen))
        let chapter = try XCTUnwrap(openedContent(of: book).chapters.first).text as NSString
        // "булки" and "остров" as Windows-1252 reads their Windows-1251 bytes.
        let bunsAt = chapter.range(of: "áóëêè").location
        let islandAt = chapter.range(of: "îñòðîâ").location
        XCTAssertNotEqual(bunsAt, NSNotFound)
        XCTAssertNotEqual(islandAt, NSNotFound)
        book.bookmarks = [Bookmark(number: 1, chapterIndex: 0, characterOffset: bunsAt, label: "Buns")]
        book.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: islandAt)
        try book.saveBookInfoThrowing()
        let model = makeModel(with: [book])

        let (outcome, _) = await readAgain(book, as: .encoding("windows-1251"), in: model)
        XCTAssertTrue(outcome.succeeded, "\(outcome)")

        let row = try XCTUnwrap(model.bookByID(book.id))
        let newChapter = try XCTUnwrap(openedContent(of: row).chapters.first).text as NSString
        XCTAssertEqual(newChapter.length, chapter.length, "the two readings are as long")
        let bookmark = try XCTUnwrap(row.bookmarks.first)
        let position = try XCTUnwrap(row.readingPosition)
        let bunsNowAt = newChapter.range(of: "булки").location
        let islandNowAt = newChapter.range(of: "остров").location
        XCTAssertLessThanOrEqual(
            abs(bookmark.characterOffset - bunsNowAt), 1, "the bookmark went to: \(newChapter.substring(from: bookmark.characterOffset).prefix(40))"
        )
        XCTAssertLessThanOrEqual(
            abs(position.characterOffset - islandNowAt), 1, "the position went to: \(newChapter.substring(from: position.characterOffset).prefix(40))"
        )
        // The record holds the moved places as the row does.
        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.bookmarks.first?.characterOffset, bookmark.characterOffset)
        XCTAssertEqual(record.state.readingPosition?.characterOffset, position.characterOffset)
    }

    /// Where the two readings do share a passage (an English sentence in a
    /// Russian book), a place in a garbled passage after it, whose words are
    /// all gone, goes to the start of that passage: just after the last words
    /// the two readings share (`PlaceRelocator`'s rule for words gone).
    func testAPlaceWhoseWordsAreGoneGoesToTheStartOfItsPassageAfterSharedWords() async throws {
        let title = "Timetable \(UUID().uuidString.prefix(8))"
        var book = try makeTextBook(
            title, text: Self.russianWithEnglish, record: TextEncodingRecord(identifier: "windows-1252", source: .chosen)
        )
        let chapter = try XCTUnwrap(openedContent(of: book).chapters.first).text as NSString
        let islandAt = chapter.range(of: "îñòðîâ").location
        XCTAssertNotEqual(islandAt, NSNotFound)
        book.readingPosition = ReadingPosition(chapterIndex: 0, characterOffset: islandAt)
        try book.saveBookInfoThrowing()
        let model = makeModel(with: [book])

        let (outcome, _) = await readAgain(book, as: .encoding("windows-1251"), in: model)
        XCTAssertTrue(outcome.succeeded, "\(outcome)")

        let row = try XCTUnwrap(model.bookByID(book.id))
        let newChapter = try XCTUnwrap(openedContent(of: row).chapters.first).text as NSString
        let position = try XCTUnwrap(row.readingPosition)
        let landed = newChapter.substring(from: position.characterOffset)
        XCTAssertTrue(landed.hasPrefix("На борту"), "the place went to: \(landed.prefix(60))")
    }

    // MARK: - Text Changed With Edit Text

    /// Text changed with Edit Text is kept beside the new reading, as a copy
    /// named as Edit Text names its copies, and VoiceOver hears where; the
    /// book's record of the edit goes, since content.md is no longer it.
    func testAnEditIsKeptAsACopyAndVoiceOverHearsWhere() async throws {
        let title = "Nets \(UUID().uuidString.prefix(8))"
        var book = try makeTextBook(title)
        let cache = MarkdownCacheService.cacheURL(for: book)
        let edited = try cachedText(of: book).replacingOccurrences(of: "двести", with: "триста")
        try edited.write(to: cache, atomically: true, encoding: .utf8)
        book.editedText = EditedText(cacheDigest: try FileImportService.md5Hash(of: cache), takenAt: Date())
        try book.saveBookInfoThrowing()
        let model = makeModel(with: [book])

        let (outcome, announced) = await readAgain(book, as: .encoding("koi8-r"), in: model)

        let copy = try XCTUnwrap(keptCopies(of: book).first, "the edit was not kept")
        XCTAssertEqual(keptCopies(of: book).count, 1, "one copy, not one for each step")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), edited)
        let said = "“\(title)” is now read as KOI8-R (Russian), chosen. "
            + "Its earlier text was kept as \(copy.lastPathComponent), in the book's package."
        XCTAssertEqual(outcome, .success(said))
        XCTAssertEqual(announced, [said])
        XCTAssertNil(model.bookByID(book.id)?.editedText, "content.md is no longer the edit")
        XCTAssertEqual(
            logLineCount("TEXT_ENCODING_CHANGED: \(title): read again as koi8-r, chosen; its earlier text was kept as \(copy.lastPathComponent)"),
            1
        )
    }

    /// A book being edited with Edit Text is read again: its session stops,
    /// as Replace Existing stops one, its edit is kept beside the new
    /// reading, and VoiceOver hears both in one announcement, with what to
    /// do to edit the new text. A re-read refused first begins the session
    /// again, so the listener's later saves are still taken (review of
    /// October 24, finding 6).
    func testEditTextStopsForTheRereadAndItsEditIsKept() async throws {
        let title = "Capstan \(UUID().uuidString.prefix(8))"
        var book = try makeTextBook(title)
        let cache = MarkdownCacheService.cacheURL(for: book)
        let edited = try cachedText(of: book).replacingOccurrences(of: "двести", with: "триста")
        try edited.write(to: cache, atomically: true, encoding: .utf8)
        book.editedText = EditedText(cacheDigest: try FileImportService.md5Hash(of: cache), takenAt: Date())
        try book.saveBookInfoThrowing()
        let model = makeModel(with: [book])
        let (editor, _) = makeEditor(for: model)
        defer { editor.endAll() }
        let baseline = try BookTextEditSessions.baseline(of: book, access: .live).get()
        editor.begin(book.id, baseline: baseline)
        let koi8 = try reading(of: book, .chosen("koi8-r"))

        let (refused, _) = await readAgain(book, as: .encoding("utf-8"), in: model)
        XCTAssertFalse(refused.succeeded, "UTF-8 must refuse these bytes, or this proves nothing: \(refused)")
        XCTAssertTrue(editor.sessions.isEditing(book.id), "the session did not begin again")

        let (outcome, announced) = await readAgain(book, as: .encoding("koi8-r"), in: model)

        let copy = try XCTUnwrap(keptCopies(of: book).first, "the edit was not kept")
        XCTAssertEqual(keptCopies(of: book).count, 1)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), edited)
        let said = "“\(title)” is now read as KOI8-R (Russian), chosen. "
            + "Its earlier text was kept as \(copy.lastPathComponent), in the book's package. "
            + "Edit Text has stopped for \(title), since its file was read again. Choose Edit Text again to edit the new text."
        XCTAssertEqual(outcome, .success(said))
        XCTAssertEqual(announced, [said])
        XCTAssertFalse(editor.sessions.isEditing(book.id), "the session went on")
        XCTAssertEqual(try cachedText(of: book), PlainTextParser.markdown(text: koi8))
    }

    // MARK: - An Open Reader

    /// A reader that has the book open is given the new text, with the moves
    /// of its places, and its copy of the book takes the new encoding.
    func testAnOpenReaderIsGivenTheNewTextAndTheChoice() async throws {
        let book = try makeTextBook("Wharf \(UUID().uuidString.prefix(8))")
        let model = makeModel(with: [book])
        // Open in a reader, as a reader's window notes it, without the
        // quick-resume setting registering one also saves.
        model.openBookIDs.insert(book.id)
        model.bookUpdates.watch(book)
        var events: [LibraryBookEvent] = []
        let subscription = model.bookUpdates.events(for: book.id).sink { events.append($0) }
        defer { subscription.cancel() }
        let koi8 = try reading(of: book, .chosen("koi8-r"))

        let (outcome, _) = await readAgain(book, as: .encoding("koi8-r"), in: model)
        XCTAssertTrue(outcome.succeeded, "\(outcome)")

        let texts: [DocumentContent] = events.compactMap {
            guard case .textReplaced(_, let content, _) = $0 else { return nil }
            return content
        }
        XCTAssertEqual(texts.count, 1, "\(events)")
        XCTAssertEqual(texts.first.map(allText(of:)), PlainTextParser.parse(text: koi8, title: "x").chapters.map(\.text).joined(separator: "\n\n"))
        let updates: [Book] = events.compactMap {
            guard case .updated(let update) = $0 else { return nil }
            return update.book
        }
        XCTAssertEqual(updates.last?.libraryFields.textEncoding, TextEncodingRecord(identifier: "koi8-r", source: .chosen))
    }
}
