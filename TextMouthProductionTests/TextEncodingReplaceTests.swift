import XCTest
@testable import TextMouth

/// Replace Existing keeps the text encoding the listener chose for the book
/// it replaces (encodingchoice): a text copy, which its import read as it
/// reads any new file, is read again in that encoding before the old copy's
/// places are carried onto its text, when the choice is about the new file
/// too (`DuplicateReplacement.textEncodingToReadAgain(replacing:with:)`): the
/// same bytes, or bytes that name no encoding of their own. A new file that
/// names its encoding, or one the choice cannot read, keeps its import's
/// reading; the same bytes that cannot be read in the choice are refused in
/// the re-read's own words, with nothing changed; and a
/// replacement that does not go ahead puts the copy's text and record back as
/// its import wrote them.
///
/// Each book is a package in the hosted test root's library, whose index is
/// put back after each test (`CloudMaintenanceTestCase`). A copy "imported
/// wrongly" is a book recorded with no encoding, which reads a Cyrillic
/// Windows-1251 file as Windows-1252.
@MainActor
final class TextEncodingReplaceTests: CloudMaintenanceTestCase {

    // MARK: - Fixtures

    /// Three paragraphs of Russian prose, long enough that no line is taken
    /// for a heading.
    private static let russian = """
        Утренний паром отходит от северной пристани ровно в семь, и опоздавшие пассажиры долго машут ему с берега.

        На борту продают горячий чай, булки с маком и вчерашние газеты, а капитан не любит ни спешки, ни громких разговоров.

        Через час показывается остров с серыми скалами, рыбацкими сетями и единственной улицей, где живут двести человек.

        """

    /// Other Russian prose, as a second edition of the same file would hold.
    private static let russianRevised = """
        Утренний паром отходит от южной пристани ровно в восемь, и опоздавшие пассажиры долго машут ему с берега.

        На борту продают горячий чай, булки с маком и свежие газеты, а капитан не любит ни спешки, ни громких разговоров.

        Через два часа показывается остров с чёрными скалами, рыбацкими сетями и единственной улицей, где живут сто человек.

        """

    /// A plain-text book titled `title` (made unique by a suffix, so the
    /// debug log's lines that name it are this test's), in a package of its
    /// own in this test's folder, whose file holds `text` written in the
    /// encoding named `writtenIn`, with the content hash `hash`, read as
    /// `record` says, with its text cache committed, as a book imported from
    /// the listener's own file is.
    private func makeTextBook(
        _ title: String,
        hash: String,
        text: String = TextEncodingReplaceTests.russian,
        writtenIn: String = "windows-1251",
        record: TextEncodingRecord = .unrecorded
    ) throws -> Book {
        let unique = "\(title) \(UUID().uuidString.prefix(8))"
        let packageName = "\(unique)-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let source = package.appendingPathComponent("\(unique).txt")
        let encoding = try XCTUnwrap(TextFileDecoder.encoding(forLabel: writtenIn), writtenIn)
        try XCTUnwrap(text.data(using: encoding, allowLossyConversion: false), writtenIn).write(to: source)
        var book = Book(
            title: unique, format: .txt, filePath: source.path, md5Hash: hash, folderPath: folderPath,
            tmbDirectoryName: packageName, sourceFilePath: "/Users/someone/Documents/\(unique).txt", cacheFormatVersion: "3.0.3"
        )
        book.textEncodingRecord = record
        return try commitCache(of: book)
    }

    /// What content.md of `book` holds.
    private func cachedText(of book: Book) throws -> String {
        try String(contentsOf: MarkdownCacheService.cacheURL(for: book), encoding: .utf8)
    }

    /// The text a reader of `text` shows once it is cached: the Markdown
    /// `PlainTextParser` writes for it.
    private func markdown(_ text: String) -> String {
        PlainTextParser.markdown(text: text)
    }

    /// The encoding the package record of `book` holds, with who decided it.
    private func recordedEncoding(of book: Book) throws -> TextEncodingRecord {
        try BookInfo.load(from: book.tmbDirectory).metadata.textEncodingRecord
    }

    /// The bytes of the files a re-read writes in the package at `package`:
    /// its content.md, contentIndex.json, and bookInfo.json, in that order.
    private func textIndexAndRecord(in package: URL) throws -> [Data] {
        try [
            TextMouthPaths.contentMarkdownPath(in: package),
            TextMouthPaths.contentIndexPath(in: package),
            TextMouthPaths.bookInfoPath(in: package),
        ].map { try Data(contentsOf: $0) }
    }

    /// A library model listing `existing`, whose encoding the listener has
    /// chosen as `option` in Book Information (a re-read), and the book the
    /// model lists now.
    private func modelWithChoice(
        for existing: Book, option: TextEncodingOption
    ) async throws -> (model: LibraryViewModel, existing: Book) {
        let model = makeModel(with: [existing])
        let corrected = await model.readTextAgain(bookID: existing.id, choosing: .textEncoding(option))
        XCTAssertTrue(corrected.succeeded, "the book was not read again: \(corrected)")
        return (model, try XCTUnwrap(model.bookByID(existing.id)))
    }

    // MARK: - Replace Existing

    /// A Windows-1251 file imported with no encoding to go by reads as
    /// Windows-1252 until the listener reads it again as Windows-1251 in Book
    /// Information. The same file added again is read as Windows-1252 too;
    /// answered Replace Existing, the copy taking the book's place is read in
    /// Windows-1251: its row and record hold the choice, its content.md is
    /// the Russian text, and the debug log says the copy was read again.
    func testReplaceExistingKeepsTheEncodingChosenInBookInformation() async throws {
        keepDeletionsOutOfTheTrash()
        let original = try makeTextBook("Ferry", hash: "ferry-bytes")
        let (model, existing) = try await modelWithChoice(for: original, option: .encoding("windows-1251"))
        let copy = try makeTextBook("Second Ferry", hash: "ferry-bytes")
        XCTAssertEqual(try cachedText(of: existing), markdown(Self.russian), "the choice must correct the book, or this proves nothing")
        XCTAssertNotEqual(try cachedText(of: copy), markdown(Self.russian), "the import's reading must misread the copy, or this proves nothing")

        XCTAssertFalse(model.addBookCheckingDuplicate(copy), "the copy was not asked about as a duplicate")
        let outcome = model.answerCurrentImportDecision(.replaceExisting)

        XCTAssertEqual(outcome, .success(nil))
        let row = try XCTUnwrap(model.bookByID(existing.id))
        XCTAssertEqual(row.tmbDirectoryName, copy.tmbDirectoryName, "the copy did not take the book's place")
        let chosen = TextEncodingRecord(identifier: "windows-1251", source: .chosen)
        XCTAssertEqual(row.textEncodingRecord, chosen)
        XCTAssertEqual(try recordedEncoding(of: row), chosen)
        XCTAssertEqual(try BookInfo.load(from: row.tmbDirectory).metadata.bookID, existing.id)
        XCTAssertEqual(try cachedText(of: row), markdown(Self.russian))
        XCTAssertEqual(logLineCount("TEXT_ENCODING_CHANGED: \(copy.title): read again as windows-1251, chosen"), 1)
    }

    /// A second edition of the file, other bytes that name no encoding, is
    /// the same book from the same source: the choice made for the first is
    /// the second's too, so it is read in it, and the old copy's bookmark,
    /// saved by the words around it, is found in the revised text.
    func testAChoiceIsCarriedToAnotherFileThatNamesNoEncoding() async throws {
        keepDeletionsOutOfTheTrash()
        let original = try makeTextBook("Timetable", hash: "first-edition")
        let (model, existing) = try await modelWithChoice(for: original, option: .encoding("windows-1251"))
        let copy = try makeTextBook("Timetable Second Edition", hash: "second-edition", text: Self.russianRevised)
        // The two are a duplicate by their source path, not their bytes.
        var sameSource = copy
        sameSource.sourceFilePath = existing.sourceFilePath
        try sameSource.saveBookInfoThrowing()
        XCTAssertNotEqual(existing.md5Hash, sameSource.md5Hash)
        XCTAssertNotNil(DuplicateReplacement.textEncodingToReadAgain(replacing: existing, with: sameSource))

        XCTAssertFalse(model.addBookCheckingDuplicate(sameSource), "the copy was not asked about as a duplicate")
        let outcome = model.answerCurrentImportDecision(.replaceExisting)

        XCTAssertEqual(outcome, .success(nil))
        let row = try XCTUnwrap(model.bookByID(existing.id))
        XCTAssertEqual(row.textEncodingRecord, TextEncodingRecord(identifier: "windows-1251", source: .chosen))
        XCTAssertEqual(try cachedText(of: row), markdown(Self.russianRevised))
    }

    /// A new file that names its encoding, here valid UTF-8, is not the file
    /// the choice was made about, so it is read as it says and the choice is
    /// not carried over it, which would turn its text into other letters.
    func testAChoiceIsNotCarriedToAFileThatNamesItsOwnEncoding() throws {
        let existing = try makeTextBook(
            "Ledger", hash: "old-bytes", record: TextEncodingRecord(identifier: "windows-1251", source: .chosen)
        )
        let copy = try makeTextBook("Ledger Again", hash: "new-bytes", text: Self.russian, writtenIn: "utf-8")

        XCTAssertNil(DuplicateReplacement.textEncodingToReadAgain(replacing: existing, with: copy))
    }

    /// A copy of other bytes that are not valid in the encoding chosen for the
    /// book is not the file the choice was made about: it keeps the reading
    /// its import gave it, and Replace Existing goes ahead with it instead of
    /// refusing, which would leave only Keep Both or Cancel. Here the book was
    /// read as UTF-8 by choice and the new file is Windows-1251.
    func testACopyNotValidInTheChoiceKeepsItsImportReadingAndReplaces() throws {
        let existing = try makeTextBook(
            "Atlas", hash: "old-bytes", text: "Ferry café, naïve, “quoted”.\n", writtenIn: "utf-8",
            record: TextEncodingRecord(identifier: "utf-8", source: .chosen)
        )
        let copy = try makeTextBook("Second Atlas", hash: "new-bytes")
        let asImported = try textIndexAndRecord(in: copy.tmbDirectory)
        let bytes = try Data(contentsOf: copy.bookFileURL)
        XCTAssertThrowsError(
            try TextFileDecoder.decode(bytes, fileName: "x.txt", format: .txt, policy: .chosen("utf-8")),
            "the copy must be unreadable in the choice, or this proves nothing"
        )

        XCTAssertNil(DuplicateReplacement.textEncodingToReadAgain(replacing: existing, with: copy))
        let preparation = try DuplicateReplacement.prepare(replacing: existing, with: copy)

        XCTAssertEqual(preparation.book.id, existing.id)
        XCTAssertFalse(preparation.book.textEncodingRecord.isChosen, "the choice was carried over bytes it cannot read")
        XCTAssertEqual(
            try Data(contentsOf: TextMouthPaths.contentMarkdownPath(in: preparation.movedTo)), asImported[0],
            "the copy was read again"
        )
        preparation.undo()
        XCTAssertEqual(try textIndexAndRecord(in: copy.tmbDirectory), asImported)
    }

    /// The same bytes the choice was made about, held by a copy that the
    /// choice cannot read (a hash that claims what the file does not), are
    /// still refused in the re-read's own words and left as imported: the
    /// listener's choice was made about exactly these bytes.
    func testTheSameBytesNotValidInTheChoiceAreRefusedAndLeftAsImported() throws {
        let existing = try makeTextBook(
            "Gazetteer", hash: "same-bytes", text: "Ferry café, naïve, “quoted”.\n", writtenIn: "utf-8",
            record: TextEncodingRecord(identifier: "utf-8", source: .chosen)
        )
        let copy = try makeTextBook("Second Gazetteer", hash: "same-bytes")
        let asImported = try textIndexAndRecord(in: copy.tmbDirectory)

        XCTAssertThrowsError(try DuplicateReplacement.prepare(replacing: existing, with: copy)) {
            let sentence = "“\(copy.title)” can't be read as UTF-8: it holds bytes that are not valid in that encoding. "
                + "Nothing was changed."
            XCTAssertEqual($0 as? DuplicateReplacement.Refusal, .copyNotReadAgain(sentence))
            XCTAssertEqual($0.localizedDescription, sentence)
        }
        XCTAssertEqual(try textIndexAndRecord(in: copy.tmbDirectory), asImported)
    }

    /// A well-formed ISO-2022-JP file is recognised by its structure, not
    /// guessed, though its escape sequences are ASCII and so valid in Shift
    /// JIS: read in a Shift JIS choice they would be text. Other bytes of
    /// that structure keep the reading their import gave them.
    func testAStructurallyRecognisedCopyIsNotReadInTheChoice() throws {
        let japanese = "いろはにほへと ちりぬるを。\nフェリーは七時に出ます。\n"
        let existing = try makeTextBook(
            "Haiku", hash: "old-bytes", text: japanese, writtenIn: "shift_jis",
            record: TextEncodingRecord(identifier: "shift_jis", source: .chosen)
        )
        let copy = try makeTextBook("Second Haiku", hash: "new-bytes", text: japanese, writtenIn: "iso-2022-jp")
        let bytes = try Data(contentsOf: copy.bookFileURL)
        XCTAssertNotNil(TextEncodingGuesser.guessSevenBit(bytes), "the copy must be recognised by its structure")
        XCTAssertNoThrow(
            try TextFileDecoder.decode(bytes, fileName: "x.txt", format: .txt, policy: .chosen("shift_jis")),
            "the copy must be readable in the choice, or only the structure keeps it from being carried"
        )

        XCTAssertNil(DuplicateReplacement.textEncodingToReadAgain(replacing: existing, with: copy))
    }

    // MARK: - When a Copy Is Read Again

    /// A copy is read again only when both are text books of one format that
    /// offer the choice, the old copy's encoding was chosen by the listener,
    /// and the choice is about the new file: the same bytes, or bytes that
    /// name no encoding. The option is the one Book Information offers for
    /// the choice, and an identifier no option names is carried as it is.
    /// The books have no packages, and their files are not there, so no new
    /// file's bytes can be read, and only the same bytes count.
    func testACopyIsReadAgainOnlyInAnEncodingTheListenerChose() {
        /// A book of the file named `name`, of content `hash`, recording `record`.
        func book(
            _ name: String, hash: String = "same", record: TextEncodingRecord, format: BookFormat = .txt,
            source: String? = "/Users/someone/Documents/Ledger.txt", isFeedItem: Bool = false
        ) -> Book {
            var book = Book(
                title: "Ledger", format: format, filePath: "/nonexistent/\(name)", md5Hash: hash, sourceFilePath: source
            )
            book.textEncodingRecord = record
            if isFeedItem { book.feedLink = FeedBookLink(feedID: UUID(), itemID: "encoding-replace-feed-item") }
            return book
        }
        let chosen = TextEncodingRecord(identifier: "windows-1251", source: .chosen)
        let guessed = TextEncodingRecord(identifier: "windows-1251", source: nil)
        let automatic = TextEncodingRecord(identifier: "windows-1251", source: .automatic)
        let copy = book("Copy.txt", record: .unrecorded)
        let cases: [(existing: Book, copy: Book, expected: TextEncodingOption?, label: String)] = [
            (book("Book.txt", record: chosen), copy, .encoding("windows-1251"), "a chosen encoding"),
            (book("Book.txt", record: TextEncodingRecord(identifier: "cp950", source: .chosen)), copy, .encoding("big5"), "the option of a name two entries share"),
            (book("Book.txt", record: TextEncodingRecord(identifier: "utf-8", source: .chosen)), copy, .encoding("utf-8"), "UTF-8 chosen"),
            (book("Book.txt", record: TextEncodingRecord(identifier: "x-klingon", source: .chosen)), copy, .encoding("x-klingon"), "an identifier no option names"),
            (book("Book.txt", record: guessed), copy, nil, "a guess"),
            (book("Book.txt", record: automatic), copy, nil, "Automatic"),
            (book("Book.txt", record: .unrecorded), copy, nil, "none"),
            (book("Book.txt", record: TextEncodingRecord(identifier: nil, source: .chosen)), copy, nil, "a choice with no encoding"),
            (book("Book.md", record: chosen, format: .markdown), copy, nil, "another format"),
            (book("Book.txt", record: chosen), book("Copy.txt", record: .unrecorded, source: nil), nil, "a new copy that offers no choice"),
            (book("Book.txt", record: chosen, isFeedItem: true), book("Copy.txt", record: .unrecorded, isFeedItem: true), nil, "a feed item"),
            (book("Book.txt", hash: "other", record: chosen), copy, nil, "other bytes, which cannot be read here"),
            (book("Book.txt", hash: "", record: chosen), book("Copy.txt", hash: "", record: .unrecorded), nil, "no content hash"),
            (book("Book.epub", record: chosen, format: .epub), book("Copy.epub", record: .unrecorded, format: .epub), nil, "a book that reads no text file"),
        ]
        for testCase in cases {
            XCTAssertEqual(
                DuplicateReplacement.textEncodingToReadAgain(replacing: testCase.existing, with: testCase.copy),
                testCase.expected,
                testCase.label
            )
        }
    }

    // MARK: - Nothing Changed When the Replacement Does Not Go Ahead

    /// A replacement prepared, then undone, as one whose commit fails is: the
    /// copy read again in the book's chosen encoding holds it in its row, its
    /// record, and its content.md; the undo puts its content.md,
    /// contentIndex.json, and bookInfo.json back, byte for byte, as its
    /// import wrote them.
    func testAnUndoPutsTheCopyBackAsItsImportReadIt() throws {
        let existing = try makeTextBook(
            "Herbal", hash: "herbal-bytes", record: TextEncodingRecord(identifier: "windows-1251", source: .chosen)
        )
        let copy = try makeTextBook("Second Herbal", hash: "herbal-bytes")
        let asImported = try textIndexAndRecord(in: copy.tmbDirectory)
        let chosen = TextEncodingRecord(identifier: "windows-1251", source: .chosen)

        let preparation = try DuplicateReplacement.prepare(replacing: existing, with: copy)

        XCTAssertEqual(preparation.book.id, existing.id)
        XCTAssertEqual(preparation.book.textEncodingRecord, chosen)
        XCTAssertEqual(try recordedEncoding(of: preparation.book), chosen)
        XCTAssertEqual(
            try String(contentsOf: TextMouthPaths.contentMarkdownPath(in: preparation.movedTo), encoding: .utf8),
            markdown(Self.russian)
        )

        preparation.undo()

        XCTAssertEqual(try textIndexAndRecord(in: copy.tmbDirectory), asImported, "the undo left the copy read again")
        XCTAssertEqual(try recordedEncoding(of: copy), .unrecorded)
    }
}
