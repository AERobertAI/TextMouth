import XCTest
@testable import TextMouth

/// A text file imported with an encoding its bytes did not name (FMT16): the
/// import guesses it and records it with the book, every later reading of
/// the book uses the record, and a book with no record is read as every book
/// was before guesses were recorded, so that no book already in the library
/// changes under its reader.
final class TextEncodingImportTests: XCTestCase {

    // MARK: - Fixtures

    /// The Russian sentences of the KOI8-R and Windows-1251 sample files.
    private static let russian = "Съешь же ещё этих мягких французских булок, да выпей чаю.\nПаром отходит в семь.\n"

    /// The text a reader gets from a plain-text file holding `fileText`: the
    /// production line analysis, headings and paragraphs, joined by blank
    /// lines, as `allText(of:)` joins a book's chapters.
    private func reading(of fileText: String) -> String {
        PlainTextParser.parse(text: fileText, title: "Fixture").chapters.map(\.text).joined(separator: "\n\n")
    }

    /// A book imported from a new file named `name` that holds `bytes`, with
    /// its package removed when the test ends.
    private func importedBook(_ bytes: Data, named name: String) throws -> Book {
        let directory = try makeSandboxDirectory("TextEncodingImport")
        let file = directory.appendingPathComponent(name)
        try bytes.write(to: file)
        return try importedForTest(file).book
    }

    /// `text` as the bytes of a file in the encoding named `name`.
    private func bytes(of text: String, in name: String) throws -> Data {
        let encoding = try XCTUnwrap(TextEncodingFixtures.encoding(named: name), name)
        return try XCTUnwrap(text.data(using: encoding, allowLossyConversion: false), name)
    }

    /// Takes the encoding out of the package record of `book`, as it is in
    /// a package written before guesses were recorded.
    private func removeRecordedEncoding(of book: Book) throws {
        let url = TextMouthPaths.bookInfoPath(in: book.tmbDirectory)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var metadata = try XCTUnwrap(record["metadata"] as? [String: Any])
        XCTAssertNotNil(metadata["textEncoding"], "the record held the encoding")
        metadata["textEncoding"] = nil
        record["metadata"] = metadata
        try JSONSerialization.data(withJSONObject: record).write(to: url)
    }

    /// What content.md of `book` holds.
    private func cachedMarkdown(of book: Book) throws -> String {
        try String(contentsOf: MarkdownCacheService.cacheURL(for: book), encoding: .utf8)
    }

    // MARK: - Importing the Samples

    /// The 13 short files in TestData/format-samples/txt-encodings import as
    /// the text each holds. The nine whose bytes name no encoding and that
    /// Windows-1252 garbles record the encoding they were guessed to be in;
    /// the other four (UTF-8, UTF-16, and the two Windows-1252 reads) record
    /// none, as they always imported.
    func testEverySampleImportsAsTheTextItHolds() throws {
        for sample in TextEncodingFixtures.sampleFiles {
            let imported = try importedForTest(copyOfFormatSample("txt-encodings/\(sample.name).txt"))
            XCTAssertEqual(allText(of: try openedContent(of: imported.book)), reading(of: sample.text), sample.name)
            XCTAssertEqual(imported.book.textEncoding != nil, sample.basis == .guess, sample.name)
        }
    }

    /// The encoding is named by its catalog identifier, the same for Windows-1251
    /// and KOI8-R as for the encodings the brief names, and lands in the row
    /// the import returns and the package record it saved.
    func testTheEncodingIsRecordedInTheRowAndThePackageRecord() throws {
        for (file, identifier) in [("koi8-r", "koi8-r"), ("windows-1251", "windows-1251"), ("mac-roman", "macintosh")] {
            let book = try importedForTest(copyOfFormatSample("txt-encodings/\(file).txt")).book
            XCTAssertEqual(book.textEncoding, identifier, file)
            XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).metadata.textEncoding, identifier, file)
        }
    }

    // MARK: - Reading It Again

    /// A rebuild of the Markdown cache reads the book in its recorded
    /// encoding, so content.md comes out as it was, byte for byte, and the
    /// direct reading of the file (the fallback when no cache can be written)
    /// agrees with it.
    func testALaterReadingUsesTheRecordedEncoding() throws {
        let book = try importedForTest(copyOfFormatSample("txt-encodings/koi8-r.txt")).book
        let imported = try cachedMarkdown(of: book)
        XCTAssertEqual(imported, PlainTextParser.markdown(text: Self.russian))

        MarkdownCacheService.deleteCache(for: book)
        _ = try MarkdownCacheService.generateReportedCacheContent(for: book)
        XCTAssertEqual(try cachedMarkdown(of: book), imported)

        let direct = try BookParser.parse(url: book.bookFileURL, format: book.format, textEncoding: book.textEncoding)
        XCTAssertEqual(direct.chapters.map(\.text).joined(separator: "\n\n"), reading(of: Self.russian))
    }

    /// The re-read for pages compares content.md with what reading the file
    /// again would write (PG09, PG16): for a book with a recorded encoding
    /// they are the same text, so the batch finds nothing changed by hand.
    func testTheReReadForPagesFindsTheSameTextForABookWithARecord() throws {
        let book = try importedForTest(copyOfFormatSample("txt-encodings/windows-1251.txt")).book
        let written = try cachedMarkdown(of: book)
        let again = try XCTUnwrap(MarkdownCacheService.extractedText(for: book, includesPages: true))
        XCTAssertEqual(again.markdown, written)
    }

    // MARK: - Books Already in the Library

    /// A book with no record of an encoding, in its row or its package, which
    /// is every book imported before guesses were recorded, is read as it
    /// always was, however well the guesser would read it now: a rebuild gives
    /// the Windows-1252 reading it had, and the re-read for pages finds that
    /// same text, so nothing in the library changes under its reader's places.
    func testABookWithNoRecordIsReadAsItAlwaysWas() throws {
        let sample = try Data(contentsOf: formatSampleURL("txt-encodings/koi8-r.txt"))
        // An old book: imported when guesses were not recorded, so read by the fallback.
        var old = try importedForTest(copyOfFormatSample("txt-encodings/koi8-r.txt")).book
        old.textEncoding = nil
        try removeRecordedEncoding(of: old)
        let legacyText = try TextFileDecoder.decode(sample, fileName: "koi8-r.txt", format: .txt).text
        XCTAssertNotEqual(legacyText, Self.russian, "the sample must be garbled by the fallback, or this proves nothing")

        _ = try MarkdownCacheService.generateReportedCacheContent(for: old)
        XCTAssertEqual(try cachedMarkdown(of: old), PlainTextParser.markdown(text: legacyText))

        let again = try XCTUnwrap(MarkdownCacheService.extractedText(for: old, includesPages: true))
        XCTAssertEqual(again.markdown, try cachedMarkdown(of: old))
        let direct = try BookParser.parse(url: old.bookFileURL, format: old.format)
        XCTAssertEqual(direct.chapters.map(\.text).joined(separator: "\n\n"), reading(of: legacyText))
    }

    /// A row that lost its encoding (a value in library.json that could not be
    /// read, or a row an older build wrote) is read in the encoding the
    /// package's record keeps when its cache is rebuilt, so the rebuild does
    /// not turn the book into Windows-1252 text, and the row has the encoding
    /// again afterwards. The direct reading of the file agrees.
    func testARowThatLostItsEncodingIsReadInTheRecordsAndTakesItBack() throws {
        let book = try importedForTest(copyOfFormatSample("txt-encodings/koi8-r.txt")).book
        let imported = try cachedMarkdown(of: book)
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).metadata.textEncoding, "koi8-r")

        var lost = book
        lost.textEncoding = nil
        XCTAssertEqual(lost.recordedTextEncoding(), "koi8-r")
        let direct = try BookParser.parse(url: lost.bookFileURL, format: lost.format, textEncoding: lost.recordedTextEncoding())
        XCTAssertEqual(direct.chapters.map(\.text).joined(separator: "\n\n"), reading(of: Self.russian))

        MarkdownCacheService.deleteCache(for: lost)
        XCTAssertNotNil(try MarkdownCacheService.generateReportedCacheAnalyzeAndStamp(for: &lost))
        XCTAssertEqual(try cachedMarkdown(of: lost), imported, "read in the record's encoding, not as Windows-1252")
        XCTAssertEqual(lost.textEncoding, "koi8-r", "the row has its encoding again")
    }

    /// A record helps a row that lost its encoding only when it names the
    /// same book and can be read: another book's record in the package, a
    /// record that is no JSON, and a book with no package give nothing, and
    /// the text is read as it always was.
    func testARecordThatCannotHelpGivesNoEncoding() throws {
        let book = try importedForTest(copyOfFormatSample("txt-encodings/koi8-r.txt")).book
        var lost = book
        lost.textEncoding = nil
        XCTAssertEqual(lost.recordedTextEncoding(), "koi8-r")

        let another = Book(
            id: UUID(), title: book.title, format: book.format, filePath: book.filePath,
            md5Hash: book.md5Hash, tmbDirectoryName: book.tmbDirectoryName
        )
        XCTAssertNil(another.recordedTextEncoding(), "the record names another book")

        let unpackaged = Book(title: "Loose", format: .txt, filePath: "/nowhere/Loose.txt", md5Hash: "loose")
        XCTAssertNil(unpackaged.recordedTextEncoding(), "no package, no record")

        XCTAssertEqual(book.recordedTextEncoding(), "koi8-r", "a row's own encoding is used as it is")

        try Data("not json".utf8).write(to: TextMouthPaths.bookInfoPath(in: book.tmbDirectory))
        XCTAssertNil(lost.recordedTextEncoding(), "an unreadable record")
        XCTAssertEqual(book.recordedTextEncoding(), "koi8-r", "a row's own encoding needs no record")
    }

    /// A book removed from the library only and added back from its package
    /// keeps its encoding and its text. The removal deletes the record that
    /// held the encoding, so the rebuilt book takes it from the removal
    /// marker; without it the text would be read again by the fallback.
    @MainActor
    func testABookAddedBackFromItsPackageKeepsItsEncodingAndItsText() throws {
        let book = try importedForTest(copyOfFormatSample("txt-encodings/koi8-r.txt")).book
        let textBefore = allText(of: try openedContent(of: book))
        XCTAssertEqual(textBefore, reading(of: Self.russian))

        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        model.removeBooksFromLibraryOnly([book])
        XCTAssertNil(model.bookByID(book.id))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: TextMouthPaths.bookInfoPath(in: book.tmbDirectory).path),
            "the removal deletes the record that held the encoding"
        )
        LibraryPersistenceService.flushPendingSave()

        let returned = try FileImportService.importTMBPackageWithReport(from: book.tmbDirectory).book
        XCTAssertEqual(returned.id, book.id)
        XCTAssertEqual(returned.textEncoding, "koi8-r")
        XCTAssertEqual(allText(of: try openedContent(of: returned)), textBefore)
    }

    // MARK: - Other Ways Text Arrives

    /// A text file inside an archive is guessed as one on its own is.
    func testATextFileInAnArchiveIsGuessedToo() throws {
        let archive = try makeTemporaryZip(
            prefix: "TextEncodingZip", entries: ["Letter \(UUID().uuidString).txt": try bytes(of: Self.russian, in: "windows-1251")]
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: archive) }
        let result = try FileImportService.importZip(from: archive)
        XCTAssertEqual(result.failures, [])
        let book = try XCTUnwrap(result.books.first)
        addTeardownBlock { try? FileManager.default.removeItem(at: book.tmbDirectory) }
        XCTAssertEqual(book.textEncoding, "windows-1251")
        XCTAssertEqual(allText(of: try openedContent(of: book)), reading(of: Self.russian))
    }

    /// Markdown and HTML files are guessed at too when their bytes name no
    /// encoding; an HTML file that declares one is read as it declares and
    /// records none.
    func testMarkdownAndHTMLFilesAreGuessedWhenTheyNameNoEncoding() throws {
        let czech = "Příliš žluťoučký kůň úpěl ďábelské ódy a Zażółć gęślą jaźń."
        let markdown = try importedBook(try bytes(of: "# Nadpis\n\n\(czech)\n", in: "windows-1250"), named: "Poznámky \(UUID().uuidString).md")
        XCTAssertEqual(markdown.textEncoding, "windows-1250")
        XCTAssertTrue(allText(of: try openedContent(of: markdown)).contains(czech))

        let page = "<html><head><title>Stránka</title></head><body><p>\(czech)</p></body></html>"
        let html = try importedBook(try bytes(of: page, in: "iso-8859-2"), named: "Stránka \(UUID().uuidString).html")
        XCTAssertNotNil(html.textEncoding)
        XCTAssertTrue(allText(of: try openedContent(of: html)).contains(czech))

        let declared = "<html><head><meta charset=\"windows-1250\"><title>Stránka</title></head><body><p>\(czech)</p></body></html>"
        let declaredBook = try importedBook(try bytes(of: declared, in: "windows-1250"), named: "Deklarace \(UUID().uuidString).html")
        XCTAssertNil(declaredBook.textEncoding)
        XCTAssertTrue(allText(of: try openedContent(of: declaredBook)).contains(czech))
    }

    /// A Japanese file in ISO-2022-JP, valid UTF-8 as every file in it is,
    /// imports as Japanese and records its encoding, and a rebuild reads it
    /// the same way; text with only ASCII in it records nothing.
    func testAFileInISO2022JPIsGuessedThoughItIsValidUTF8() throws {
        let japanese = "いろはにほへと ちりぬるを。\nフェリーは七時に出ます。\n"
        let data = try XCTUnwrap(japanese.data(using: .iso2022JP))
        let book = try importedBook(data, named: "Poem \(UUID().uuidString).txt")
        XCTAssertEqual(book.textEncoding, "iso-2022-jp")
        XCTAssertEqual(allText(of: try openedContent(of: book)), reading(of: japanese))

        let imported = try cachedMarkdown(of: book)
        MarkdownCacheService.deleteCache(for: book)
        _ = try MarkdownCacheService.generateReportedCacheContent(for: book)
        XCTAssertEqual(try cachedMarkdown(of: book), imported)

        let ascii = try importedBook(Data("Plain ASCII text.\n".utf8), named: "Plain \(UUID().uuidString).txt")
        XCTAssertNil(ascii.textEncoding)
    }

    /// Text typed or pasted in is UTF-8 and is never guessed at, whatever
    /// accents it holds.
    func testTextTypedInIsNotGuessed() throws {
        let imported = try FileImportService.importText(
            "Café au lait, señor — «naïve» Привет", title: "Typed \(UUID().uuidString)", author: "", fileName: "Typed.txt"
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: imported.book.tmbDirectory) }
        XCTAssertNil(imported.book.textEncoding)
    }
}
