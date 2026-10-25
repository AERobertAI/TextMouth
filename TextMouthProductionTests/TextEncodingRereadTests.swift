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
    /// the library's storage work, the library's text being read again, Edit
    /// Text, an export, a file only in the cloud, a book gone, and a book
    /// that offers no choice.
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

        let sessions = BookTextEditSessions()
        model.textEditSessions = sessions
        let baseline = try BookTextEditSessions.baseline(of: book, access: .live).get()
        sessions.begin(book.id, BookTextEditSessions.Session(baseline: baseline, report: { _, _ in }))
        await expectRefusal(
            "“\(title)” is being edited with Edit Text, and reading its file again now would replace the text being edited. "
                + "Edit Text ends when TextMouth quits, so quit and open TextMouth again, then try again."
        )
        sessions.end(book.id)

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
