import XCTest
@testable import TextMouth

/// A braille book read again with other braille file characters, as Book
/// Information asks for it (braillecodes, BRAILLE-CODES-RESEARCH-2026-10-25.md,
/// sections 8.3 and 8.9), through the one re-read an encoding uses too
/// (`TextEncodingRereadTests`): the text, the row, and the record after it; a
/// place, which moves with its words; the record's decision over a row that
/// lags behind it; the debug log's line; and every refusal, after which
/// nothing has changed.
///
/// The format samples are North American Braille ASCII files, so a book in
/// another code is the grade 1 sample's cells written in that code
/// (`copyOfBrailleSample(_:writtenIn:)`). Every import binds the table and
/// the code it names, never the user's settings, and every book is a package
/// in the hosted test root's library, whose index is put back after each
/// test (`CloudMaintenanceTestCase`).
@MainActor
final class BrailleFileCodeRereadTests: CloudMaintenanceTestCase {

    // MARK: - Fixtures

    /// The grade 1 BRF sample, a North American Braille ASCII file.
    private static let sample = "brf/pride-and-prejudice-ch1-grade1.brf"
    /// The PEF of the same chapter.
    private static let pefSample = "pef/pride-and-prejudice-ch1-grade1.pef"
    /// The table both samples are written in: uncontracted UEB.
    private static let table = "en-ueb-g1.ctb"
    /// A word of the sample's first paragraph that a wrong code leaves as it
    /// is, since only letters and spaces spell it and every code here writes
    /// the letters' cells alike, while the capital sign before the paragraph
    /// reads otherwise ("'it" for "It"), so the word stands elsewhere in
    /// each reading. It is in the chapter once.
    private static let placedWord = "universally"

    /// The book the file at `url` imports as, with the samples' table, and
    /// with `code` as the Braille setting's file code.
    private func imported(_ url: URL, settingCode code: BrailleFileCode) throws -> Book {
        try BraillePreferences.$tableForImports.withValue(Self.table) {
            try BraillePreferences.$fileCodeForImports.withValue(code.id) {
                try importedForTest(url).book
            }
        }
    }

    /// The grade 1 sample written in `code`, imported with `settingCode` as
    /// the Braille setting's file code, and titled `title` with a suffix of
    /// its own, in its row and its record, so the debug log's lines that
    /// name it are this test's.
    private func importedSample(
        writtenIn code: BrailleFileCode, settingCode: BrailleFileCode, title: String
    ) throws -> Book {
        var book = try imported(copyOfBrailleSample(Self.sample, writtenIn: code), settingCode: settingCode)
        book.title = "\(title) \(UUID().uuidString.prefix(8))"
        try book.saveBookInfoThrowing()
        return book
    }

    /// A Markdown book titled `title`, with a suffix of its own, in a package
    /// of its own in this test's folder, with its text cache committed, added
    /// from the listener's own file, so Book Information offers it the Text
    /// Encoding pop-up.
    private func makeTextBook(_ title: String) throws -> Book {
        var book = try makePackagedBook(title: "\(title) \(UUID().uuidString.prefix(8))")
        book.sourceFilePath = "/Users/someone/Documents/\(title).md"
        return try commitCache(of: book)
    }

    /// The bytes of the content.md in `book`'s package.
    private func contentMD(of book: Book) throws -> Data {
        try Data(contentsOf: MarkdownCacheService.cacheURL(for: book))
    }

    /// The bytes of the record in `book`'s package.
    private func recordBytes(of book: Book) throws -> Data {
        try Data(contentsOf: TextMouthPaths.bookInfoPath(in: book.tmbDirectory))
    }

    /// The code the record in `book`'s package keeps.
    private func recordedCode(of book: Book) throws -> String? {
        try BookInfo.load(from: book.tmbDirectory).metadata.brailleFileCode
    }

    /// The file at `url` read as North American Braille ASCII, with pages, as
    /// a generation writes content.md: its UTF-8.
    private func northAmericanReading(of url: URL) throws -> Data {
        Data(try BrailleBookReader.markdown(of: url, table: Self.table, fileCode: "ascii-na", includesPages: true).utf8)
    }

    /// Where `word` first stands in `content`: its chapter, and its offset
    /// there as the reader counts it (UTF-16), or nil when no chapter has it.
    private func place(of word: String, in content: DocumentContent) -> (chapterIndex: Int, offset: Int)? {
        for (index, chapter) in content.chapters.enumerated() {
            let found = (chapter.text as NSString).range(of: word)
            if found.location != NSNotFound {
                return (index, found.location)
            }
        }
        return nil
    }

    /// An Edit Text editor for `model`, sharing its sessions, which stands in
    /// for the listener and the system: it explains nothing, chooses no app,
    /// opens nothing, and finds TextMouth active. The caller ends its
    /// sessions (`BookTextEditor.endAll()`).
    private func makeEditor(for model: LibraryViewModel) -> BookTextEditor {
        let sessions = BookTextEditSessions()
        model.textEditSessions = sessions
        let editor = BookTextEditor(
            sessions: sessions,
            preferences: makeSandboxedPreferences("Edit Text"),
            notificationCenter: NotificationCenter(),
            explain: { _, _ in true },
            chooseApp: { _, _ in nil },
            open: { _, _ in },
            isAppActive: { true }
        )
        model.bookTextEditor = { editor }
        return editor
    }

    /// What `model` makes of reading `book` again as `choice` says, with
    /// every announcement it makes on the way.
    private func readAgain(
        _ book: Book, choosing choice: TextRereadChoice, in model: LibraryViewModel
    ) async -> (outcome: OperationOutcome, announced: [String]) {
        var announced: [String] = []
        let previous = VoiceOverAnnouncer.poster
        VoiceOverAnnouncer.poster = { announcement, _ in announced.append(announcement.message) }
        defer { VoiceOverAnnouncer.poster = previous }
        let outcome = await model.readTextAgain(bookID: book.id, choosing: choice)
        return (outcome, announced)
    }

    // MARK: - Reading Again

    /// A Eurobraille BRF imported as North American Braille ASCII reads with
    /// no error, and wrongly. Read again with Eurobraille, its content.md is
    /// the North American sample's own text, its row and record hold
    /// "ascii-eurobraille", VoiceOver hears the code's name, the debug log
    /// says it in the braille line and never in the encoding's, and the
    /// reading position moves with its word.
    func testEurobrailleReadsAMisreadBookAgainAndRecordsIt() async throws {
        var book = try importedSample(writtenIn: .eurobraille, settingCode: .northAmerican, title: "Ledger")
        let expected = try northAmericanReading(of: copyOfFormatSample(Self.sample))
        XCTAssertEqual(book.brailleFileCode, "ascii-na")
        XCTAssertNotEqual(try contentMD(of: book), expected, "the wrong code must read otherwise, or this proves nothing")
        let wordBefore = try XCTUnwrap(place(of: Self.placedWord, in: openedContent(of: book)))
        book.readingPosition = ReadingPosition(chapterIndex: wordBefore.chapterIndex, characterOffset: wordBefore.offset)
        try book.saveBookInfoThrowing()
        let model = makeModel(with: [book])

        let (outcome, announced) = await readAgain(book, choosing: .brailleFileCode(.eurobraille), in: model)

        let said = "“\(book.title)” is now read as Eurobraille, six-dot (German-speaking countries)."
        XCTAssertEqual(outcome, .success(said))
        XCTAssertEqual(announced, [said])
        XCTAssertEqual(try contentMD(of: book), expected)
        let row = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(row.brailleFileCode, "ascii-eurobraille")
        XCTAssertEqual(try recordedCode(of: book), "ascii-eurobraille")
        XCTAssertEqual(logLineCount("BRAILLE_FILE_CODE_CHANGED: \(book.title): read again with ascii-eurobraille"), 1)
        XCTAssertEqual(logLineCount("TEXT_ENCODING_CHANGED: \(book.title)"), 0, "a braille re-read was logged as an encoding's")
        // The place stood at the word in the wrong reading, and stands at it
        // in the right one, which puts it elsewhere.
        let wordAfter = try XCTUnwrap(place(of: Self.placedWord, in: openedContent(of: row)))
        XCTAssertNotEqual(wordAfter.offset, wordBefore.offset, "the readings must place the word apart, or this proves nothing")
        let position = try XCTUnwrap(row.readingPosition)
        XCTAssertEqual(position.chapterIndex, wordAfter.chapterIndex)
        XCTAssertEqual(position.characterOffset, wordAfter.offset)
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).state.readingPosition?.characterOffset, wordAfter.offset)
    }

    /// Read again with North American Braille ASCII, a book records
    /// "ascii-na" by name, never nil, so the record's decision stands over a
    /// row that lags behind it: a later save of the row as it was before the
    /// re-read, still holding Eurobraille, as a reader's checkpoint between
    /// the commit and the row's update could save it, keeps "ascii-na" in
    /// the record.
    func testNorthAmericanIsRecordedByNameOverALaggingRow() async throws {
        let book = try importedSample(writtenIn: .eurobraille, settingCode: .eurobraille, title: "Almanac")
        XCTAssertEqual(try recordedCode(of: book), "ascii-eurobraille")
        let model = makeModel(with: [book])

        let (outcome, _) = await readAgain(book, choosing: .brailleFileCode(.northAmerican), in: model)

        XCTAssertEqual(outcome, .success("“\(book.title)” is now read as North American Braille ASCII."))
        XCTAssertEqual(try contentMD(of: book), try northAmericanReading(of: book.bookFileURL))
        XCTAssertEqual(model.bookByID(book.id)?.brailleFileCode, "ascii-na")
        XCTAssertEqual(try recordedCode(of: book), "ascii-na")

        // The row as it was before the re-read, saved as a checkpoint saves it.
        XCTAssertEqual(book.brailleFileCode, "ascii-eurobraille")
        LibraryPersistenceService.saveBookInfo(for: book)
        LibraryPersistenceService.flushPendingSave()

        XCTAssertEqual(try recordedCode(of: book), "ascii-na")
    }

    // MARK: - Refused, With Nothing Changed

    /// A file that is not braille in the code chosen is refused in the
    /// reader's own words, and nothing changes: the sample written in Unicode
    /// braille patterns, which an import knows by its bytes, chosen to be
    /// read as Eurobraille. Its first line begins with blank cells (nine
    /// spaces in the North American sample), so with the blank pattern,
    /// U+2800, which the reader names by its code. content.md, the row, and
    /// the record keep their bytes, and Edit Text, which was editing the
    /// book, begins again, so the listener's later saves are still taken.
    func testAFileNotBrailleInTheCodeChosenIsRefusedAndNothingChanges() async throws {
        let book = try importedSample(writtenIn: .unicode, settingCode: .northAmerican, title: "Codex")
        XCTAssertEqual(book.brailleFileCode, "unicode")
        XCTAssertEqual(
            [UInt8](try Data(contentsOf: book.bookFileURL).prefix(3)), [0xE2, 0xA0, 0x80],
            "the file must begin with U+2800, or the sentence below is not the reader's"
        )
        let model = makeModel(with: [book])
        let editor = makeEditor(for: model)
        defer { editor.endAll() }
        let baseline = try BookTextEditSessions.baseline(of: book, access: .live).get()
        editor.begin(book.id, baseline: baseline)
        let textBefore = try contentMD(of: book)
        let recordBefore = try recordBytes(of: book)

        let (outcome, announced) = await readAgain(book, choosing: .brailleFileCode(.eurobraille), in: model)

        XCTAssertEqual(outcome, .failure(
            "“\(book.title)” can't be read as Eurobraille, six-dot (German-speaking countries): "
                + "Line 1 holds the character U+2800, which is not Eurobraille. Nothing was changed."
        ))
        XCTAssertEqual(announced, [], "the sheet says a refusal, not the library")
        XCTAssertEqual(try contentMD(of: book), textBefore)
        XCTAssertEqual(try recordBytes(of: book), recordBefore)
        XCTAssertEqual(model.bookByID(book.id), book)
        XCTAssertTrue(editor.sessions.isEditing(book.id), "Edit Text did not begin again")
    }

    /// A choice a book is not offered is refused, though Book Information
    /// never offers it, in the words of a failed re-read, and changes
    /// nothing: braille file characters for a PEF, whose rows are always
    /// Unicode braille patterns, or for a text book; and an encoding for a
    /// braille book.
    func testAChoiceTheBookIsNotOfferedIsRefused() async throws {
        let pef = try imported(copyOfFormatSample(Self.pefSample), settingCode: .northAmerican)
        let brf = try importedSample(writtenIn: .northAmerican, settingCode: .northAmerican, title: "Primer")
        let text = try makeTextBook("Gazette")
        XCTAssertFalse(pef.offersBrailleFileCodeChoice)
        XCTAssertTrue(brf.offersBrailleFileCodeChoice, "a BRF must be offered the choice, or this proves nothing")
        XCTAssertTrue(text.offersTextEncodingChoice, "the text book must be offered an encoding, or this proves nothing")
        let books = [pef, brf, text]
        let model = makeModel(with: books)
        let textsBefore = try books.map { try contentMD(of: $0) }
        let choices: [(book: Book, choice: TextRereadChoice)] = [
            (pef, .brailleFileCode(.unicode)),
            (pef, .brailleFileCode(.eurobraille)),
            (text, .brailleFileCode(.northAmerican)),
            (brf, .textEncoding(.encoding("utf-8"))),
            (brf, .textEncoding(.automatic)),
        ]

        for (book, choice) in choices {
            let (outcome, _) = await readAgain(book, choosing: choice, in: model)
            XCTAssertEqual(
                outcome, .failure("TextMouth couldn't read “\(book.title)” again, so it left the book as it was."), "\(choice)"
            )
        }

        XCTAssertEqual(try books.map { try contentMD(of: $0) }, textsBefore)
        XCTAssertEqual(books.compactMap { model.bookByID($0.id) }, books)
    }

    /// While a braille book is read again, a second re-read of it waits, in
    /// the braille re-read's own words; a text book busy the same way still
    /// says the encoding's.
    func testABusyBookIsRefusedInTheWordsOfItsReread() async throws {
        let braille = try importedSample(writtenIn: .eurobraille, settingCode: .northAmerican, title: "Folio")
        let text = try makeTextBook("Gazette")
        let model = makeModel(with: [braille, text])
        // A re-read of each under way, in this model's own list.
        model.textRereads = TextRereads()
        model.booksBeingReadAgain = [braille.id, text.id]
        defer { model.booksBeingReadAgain = [] }

        let (brailleAgain, _) = await readAgain(braille, choosing: .brailleFileCode(.eurobraille), in: model)
        let (textAgain, _) = await readAgain(text, choosing: .textEncoding(.encoding("utf-8")), in: model)

        XCTAssertEqual(
            brailleAgain,
            .failure("TextMouth is reading “\(braille.title)” again with other braille file characters. Try again when that finishes.")
        )
        XCTAssertEqual(
            textAgain, .failure("TextMouth is reading “\(text.title)” again in another encoding. Try again when that finishes.")
        )
    }

    // MARK: - The Pieces

    /// Book Information offers the choice of braille file characters to a
    /// BRF or BRL braille book only: not to a PEF, named .pef or .xml, whose
    /// rows are always Unicode braille patterns, not to a feed's item, and
    /// not to a book of another format.
    func testOnlyABRFOrBRLBookIsOfferedTheChoice() {
        func book(_ fileName: String, format: BookFormat = .braille) -> Book {
            Book(title: "Ledger", format: format, filePath: "/library/Ledger.tmb/\(fileName)", md5Hash: "ledger")
        }
        XCTAssertTrue(book("Ledger.brf").offersBrailleFileCodeChoice)
        XCTAssertTrue(book("Ledger.BRL").offersBrailleFileCodeChoice)
        XCTAssertFalse(book("Ledger.pef").offersBrailleFileCodeChoice)
        XCTAssertFalse(book("Ledger.xml").offersBrailleFileCodeChoice)
        XCTAssertFalse(book("Ledger.txt", format: .txt).offersBrailleFileCodeChoice)
        var item = book("Ledger.brf")
        item.feedLink = FeedBookLink(feedID: UUID(), itemID: "item")
        XCTAssertFalse(item.offersBrailleFileCodeChoice)
    }

    /// The check a re-read makes before it writes anything reads the file's
    /// pages with the code chosen, after the size limit: the sample's Unicode
    /// copy reads in Unicode braille patterns and is refused in Eurobraille
    /// with the reader's own refusal, the blank pattern it begins with named
    /// by its code; a file past 32 MB is refused before it is read.
    func testTheCheckReadsThePagesWithTheCodeChosenAfterTheSizeLimit() throws {
        let unicode = try copyOfBrailleSample(Self.sample, writtenIn: .unicode)
        XCTAssertNoThrow(try BrailleBookReader.requireReadable(unicode, as: .unicode))
        XCTAssertThrowsError(try BrailleBookReader.requireReadable(unicode, as: .eurobraille)) {
            XCTAssertEqual($0 as? BrailleFileError, .notInFileCode(.unseenCharacter(0x2800), line: 1, characters: "Eurobraille"))
        }

        // A file one byte past the limit, all holes (a sparse file, made at once).
        let huge = try makeSandboxDirectory("BrailleFileCodeReread").appendingPathComponent("huge.brf")
        XCTAssertTrue(FileManager.default.createFile(atPath: huge.path, contents: nil))
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(BrailleBookReader.maximumFileBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try BrailleBookReader.requireReadable(huge, as: .northAmerican)) {
            XCTAssertEqual($0 as? BrailleFileError, .fileTooLarge)
        }
    }

    /// The debug log's line for a braille re-read names the title and the
    /// code's id, and, when text TextMouth did not write was kept, the copy,
    /// in the clause the encoding's line ends with too; each choice's lines
    /// begin with its own tag.
    func testTheLogLineNamesTheCodeAndAKeptCopy() {
        XCTAssertEqual(LibraryViewModel.brailleFileCodeChangedLogTag, "BRAILLE_FILE_CODE_CHANGED")
        XCTAssertEqual(
            LibraryViewModel.brailleFileCodeLogLine(title: "Ledger", code: .eurobraille, keptCopy: nil),
            "BRAILLE_FILE_CODE_CHANGED: Ledger: read again with ascii-eurobraille"
        )
        let copy = URL(fileURLWithPath: "/library/Ledger.tmb/content.md.edited-20261024T120000Z")
        XCTAssertEqual(
            LibraryViewModel.brailleFileCodeLogLine(title: "Ledger", code: .northAmerican, keptCopy: copy),
            "BRAILLE_FILE_CODE_CHANGED: Ledger: read again with ascii-na; its earlier text was kept as content.md.edited-20261024T120000Z"
        )
        XCTAssertEqual(
            LibraryViewModel.textEncodingLogLine(
                title: "Ledger", record: TextEncodingRecord(identifier: "koi8-r", source: .chosen), keptCopy: copy
            ),
            "TEXT_ENCODING_CHANGED: Ledger: read again as koi8-r, chosen; its earlier text was kept as content.md.edited-20261024T120000Z"
        )
        XCTAssertEqual(TextRereadChoice.textEncoding(.automatic).logTag, "TEXT_ENCODING_CHANGED")
        XCTAssertEqual(TextRereadChoice.brailleFileCode(.unicode).logTag, "BRAILLE_FILE_CODE_CHANGED")
    }

    /// Every sentence of `BrailleFileCodeWording`, exactly, and the
    /// announcement both re-reads share, with the code's name as the reading.
    func testTheWordsOfARefusalAndOfDone() {
        XCTAssertEqual(
            BrailleFileCodeWording.notReadableRefusal(
                bookTitle: "Ledger", codeName: "Eurobraille, six-dot (German-speaking countries)",
                reason: "Line 3 holds the control character U+0007, which is not Eurobraille."
            ),
            "“Ledger” can't be read as Eurobraille, six-dot (German-speaking countries): "
                + "Line 3 holds the control character U+0007, which is not Eurobraille. Nothing was changed."
        )
        XCTAssertEqual(
            BrailleFileCodeWording.readingAgainRefusal(bookTitle: "Ledger"),
            "TextMouth is reading “Ledger” again with other braille file characters. Try again when that finishes."
        )
        XCTAssertEqual(
            TextEncodingWording.readAgainAnnouncement(
                bookTitle: "Ledger", readingDescription: BrailleFileCode.eurobraille.name, keptCopy: nil
            ),
            "“Ledger” is now read as Eurobraille, six-dot (German-speaking countries)."
        )
        XCTAssertEqual(
            TextEncodingWording.readAgainAnnouncement(bookTitle: "Ledger", readingDescription: nil, keptCopy: nil),
            "“Ledger” was read again."
        )
    }
}
