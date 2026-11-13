import XCTest
@testable import TextMouth

/// Replace Existing keeps the braille file characters of the book it
/// replaces (braillecodes review, finding 3): a BRF or BRL copy of the same
/// file, which its import read in the Braille setting's characters, is read
/// again in the ones the library's copy is read in, which the listener may
/// have chosen in Book Information, before the old copy's places are carried
/// onto its text (`DuplicateReplacement.brailleFileCodeToReadAgain(replacing:with:)`).
/// A copy whose bytes are Unicode braille patterns keeps them; one that
/// cannot be read so is refused in the reading's own words, with nothing
/// changed; and a replacement that does not go ahead puts the copy's text and
/// record back as its import wrote them.
///
/// The format samples are North American Braille ASCII files, so a book in
/// another code is the grade 1 sample's cells written in that code
/// (`copyOfBrailleSample(_:writtenIn:)`). Every import binds the table and
/// the code it names, never the user's settings, and every book is a package
/// in the hosted test root's library, whose index is put back after each
/// test (`CloudMaintenanceTestCase`).
@MainActor
final class BrailleFileCodeReplaceTests: CloudMaintenanceTestCase {

    // MARK: - Fixtures

    /// The grade 1 BRF sample, a North American Braille ASCII file.
    private static let sample = "brf/pride-and-prejudice-ch1-grade1.brf"
    /// The table the sample is written in: uncontracted UEB.
    private static let table = "en-ueb-g1.ctb"
    /// The id of a code no TextMouth knows yet, as a later TextMouth might
    /// record one.
    private static let unknownCode = "ascii-braillo-no-047-01"
    /// When fixtures' dates fall, in whole seconds.
    private static let date = Date(timeIntervalSince1970: 1_790_000_000)

    /// The book the braille file at `url` imports as, with the sample's
    /// table and with `code` as the Braille setting's file code, titled
    /// `title` with a suffix of its own, in its row and its record, so the
    /// debug log's lines that name it are this test's.
    private func imported(_ url: URL, settingCode code: BrailleFileCode, title: String) throws -> Book {
        var book = try BraillePreferences.$tableForImports.withValue(Self.table) {
            try BraillePreferences.$fileCodeForImports.withValue(code.id) {
                try importedForTest(url).book
            }
        }
        book.title = "\(title) \(UUID().uuidString.prefix(8))"
        try book.saveBookInfoThrowing()
        return book
    }

    /// The bytes of the content.md in the package at `package`.
    private func contentMD(in package: URL) throws -> Data {
        try Data(contentsOf: TextMouthPaths.contentMarkdownPath(in: package))
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

    /// The code the record in the package at `package` keeps.
    private func recordedCode(in package: URL) throws -> String? {
        try BookInfo.load(from: package).metadata.brailleFileCode
    }

    /// The North American sample read as North American Braille ASCII, with
    /// pages, as a generation writes content.md: its UTF-8, which the sample
    /// written in any code reads as when it is read in that code.
    private func northAmericanReading() throws -> Data {
        Data(try BrailleBookReader.markdown(
            of: copyOfFormatSample(Self.sample), table: Self.table, fileCode: "ascii-na", includesPages: true
        ).utf8)
    }

    // MARK: - Replace Existing

    /// The sample written in Eurobraille, imported with the setting North
    /// American Braille ASCII, reads wrongly until the listener reads it
    /// again as Eurobraille in Book Information. The same file added again is
    /// read with the setting too; answered Replace Existing, the copy taking
    /// the book's place is read in Eurobraille: its row and record hold
    /// "ascii-eurobraille", its content.md is the North American sample's own
    /// text, and the debug log says the copy was read again.
    func testReplaceExistingKeepsTheCharactersChosenInBookInformation() async throws {
        keepDeletionsOutOfTheTrash()
        let file = try copyOfBrailleSample(Self.sample, writtenIn: .eurobraille)
        let existing = try imported(file, settingCode: .northAmerican, title: "Gazetteer")
        let model = makeModel(with: [existing])
        let corrected = await model.readTextAgain(bookID: existing.id, choosing: .brailleFileCode(.eurobraille))
        XCTAssertTrue(corrected.succeeded, "the book was not read again: \(corrected)")
        let copy = try imported(file, settingCode: .northAmerican, title: "Second Gazetteer")
        let expected = try northAmericanReading()
        XCTAssertEqual(copy.md5Hash, existing.md5Hash, "the same file must have the same content hash, or this proves nothing")
        XCTAssertEqual(copy.brailleFileCode, "ascii-na")
        XCTAssertNotEqual(try contentMD(in: copy.tmbDirectory), expected, "the setting's code must misread the copy, or this proves nothing")

        XCTAssertFalse(model.addBookCheckingDuplicate(copy), "the copy was not asked about as a duplicate")
        let outcome = model.answerCurrentImportDecision(.replaceExisting)

        XCTAssertEqual(outcome, .success(nil))
        let row = try XCTUnwrap(model.bookByID(existing.id))
        XCTAssertEqual(row.tmbDirectoryName, copy.tmbDirectoryName, "the copy did not take the book's place")
        XCTAssertEqual(row.brailleFileCode, "ascii-eurobraille")
        XCTAssertEqual(try recordedCode(in: row.tmbDirectory), "ascii-eurobraille")
        XCTAssertEqual(try BookInfo.load(from: row.tmbDirectory).metadata.bookID, existing.id)
        XCTAssertEqual(try contentMD(in: row.tmbDirectory), expected)
        XCTAssertEqual(logLineCount("BRAILLE_FILE_CODE_CHANGED: \(copy.title): read again with ascii-eurobraille"), 1)
    }

    /// A copy whose bytes are Unicode braille patterns, which its import
    /// knows for certain, keeps "unicode" in the place of a book of the same
    /// file whose code an earlier TextMouth dropped from its row and its
    /// record. That book records none, which names North American Braille
    /// ASCII, but the copy's bytes say what they are: it is not read again in
    /// characters those bytes are not, which could only refuse it, and its
    /// content.md is the North American sample's own text.
    func testACopyOfUnicodeBraillePatternsKeepsThem() throws {
        keepDeletionsOutOfTheTrash()
        let file = try copyOfBrailleSample(Self.sample, writtenIn: .unicode)
        let existing = try droppingBrailleFileCode(of: imported(file, settingCode: .northAmerican, title: "Portolan"))
        XCTAssertNil(existing.recordedBrailleFileCode(), "the book must record no code, or this proves nothing")
        let copy = try imported(file, settingCode: .northAmerican, title: "Second Portolan")
        XCTAssertEqual(copy.brailleFileCode, "unicode")
        let model = makeModel(with: [existing])

        XCTAssertFalse(model.addBookCheckingDuplicate(copy), "the copy was not asked about as a duplicate")
        let outcome = model.answerCurrentImportDecision(.replaceExisting)

        XCTAssertEqual(outcome, .success(nil))
        let row = try XCTUnwrap(model.bookByID(existing.id))
        XCTAssertEqual(row.tmbDirectoryName, copy.tmbDirectoryName, "the copy did not take the book's place")
        XCTAssertEqual(row.brailleFileCode, "unicode")
        XCTAssertEqual(try recordedCode(in: row.tmbDirectory), "unicode")
        XCTAssertEqual(try contentMD(in: row.tmbDirectory), try northAmericanReading())
        XCTAssertEqual(logLineCount("BRAILLE_FILE_CODE_CHANGED: \(copy.title)"), 0, "the copy was read again")
    }

    // MARK: - When a Copy Is Read Again

    /// A copy is read again only when both books are BRF or BRL braille books
    /// of the same bytes, and the book's characters, as each stored code
    /// names them, are not the copy's: in the book's characters, by an
    /// explicit id, North American Braille ASCII's for a book that records
    /// none, and an id this TextMouth does not know as it is stored, for the
    /// reading to refuse by name. The books have no packages, and their
    /// files are not there, so nothing about their bytes is certain.
    func testACopyIsReadAgainOnlyInTheBooksOtherCharacters() {
        /// A book of the file named `name`, in a folder that is not there, of
        /// content `hash`, recording `code`.
        func book(_ name: String, hash: String = "same", code: String?, format: BookFormat = .braille) -> Book {
            Book(title: "Gazetteer", format: format, filePath: "/nonexistent/\(name)", md5Hash: hash, brailleFileCode: code)
        }
        let copy = book("Copy.brf", code: "ascii-na")
        let eurobraille = "ascii-eurobraille"
        let cases: [(existing: Book, copy: Book, expected: String?, label: String)] = [
            (book("Book.brf", code: eurobraille), copy, eurobraille, "other characters"),
            (book("Book.brl", code: eurobraille), copy, eurobraille, "a BRL"),
            (book("Book.brf", code: "ascii-na"), copy, nil, "the same characters"),
            (book("Book.brf", code: nil), copy, nil, "none, read as North American"),
            (book("Book.brf", code: ""), copy, nil, "an empty id, read as North American"),
            (book("Book.brf", code: nil), book("Copy.brf", code: eurobraille), "ascii-na", "North American by name"),
            (book("Book.brf", code: Self.unknownCode), copy, Self.unknownCode, "an id this TextMouth does not know"),
            (book("Book.brf", hash: "other", code: eurobraille), copy, nil, "other bytes"),
            (book("Book.brf", hash: "", code: eurobraille), book("Copy.brf", hash: "", code: "ascii-na"), nil, "no content hash"),
            (book("Book.pef", code: eurobraille), book("Copy.pef", code: nil), nil, "PEFs"),
            (book("Book.txt", code: eurobraille, format: .txt), copy, nil, "a text book"),
        ]
        for testCase in cases {
            XCTAssertEqual(
                DuplicateReplacement.brailleFileCodeToReadAgain(replacing: testCase.existing, with: testCase.copy),
                testCase.expected,
                testCase.label
            )
        }
    }

    // MARK: - Nothing Changed When the Replacement Does Not Go Ahead

    /// A replacement prepared, then undone, as one whose commit fails is: the
    /// copy read again in the book's Eurobraille holds it in its row, its
    /// record, and its content.md, whose digest its row's analysis holds; the
    /// undo puts its content.md, contentIndex.json, and bookInfo.json back,
    /// byte for byte, as its import wrote them.
    func testAnUndoPutsTheCopyBackAsItsImportReadIt() throws {
        let file = try copyOfBrailleSample(Self.sample, writtenIn: .eurobraille)
        let existing = try imported(file, settingCode: .eurobraille, title: "Herbal")
        let copy = try imported(file, settingCode: .northAmerican, title: "Second Herbal")
        let asImported = try textIndexAndRecord(in: copy.tmbDirectory)

        let preparation = try DuplicateReplacement.prepare(replacing: existing, with: copy)

        XCTAssertEqual(preparation.book.id, existing.id)
        XCTAssertEqual(preparation.book.brailleFileCode, "ascii-eurobraille")
        XCTAssertEqual(try recordedCode(in: preparation.movedTo), "ascii-eurobraille")
        let text = try contentMD(in: preparation.movedTo)
        XCTAssertEqual(text, try northAmericanReading())
        XCTAssertEqual(
            preparation.book.textCacheFingerprint?.cache.digest, FingerprintHasher.md5.digestOfData(text),
            "the row's analysis is not the new text's"
        )

        preparation.undo()

        XCTAssertEqual(try textIndexAndRecord(in: copy.tmbDirectory), asImported, "the undo left the copy read again")
        XCTAssertEqual(try recordedCode(in: copy.tmbDirectory), "ascii-na")
    }

    /// A replacement refused once the copy was read again, here because the
    /// book's edited text is only in the cloud, says why and puts the copy's
    /// content.md, contentIndex.json, and bookInfo.json back as its import
    /// wrote them; the debug log says the copy had been read again.
    func testARefusalAfterTheCopyWasReadAgainPutsItBack() throws {
        let file = try copyOfBrailleSample(Self.sample, writtenIn: .eurobraille)
        var existing = try imported(file, settingCode: .eurobraille, title: "Bestiary")
        existing.editedText = EditedText(cacheDigest: "edited", takenAt: Self.date)
        let copy = try imported(file, settingCode: .northAmerican, title: "Second Bestiary")
        let asImported = try textIndexAndRecord(in: copy.tmbDirectory)
        cloud.markDataless(MarkdownCacheService.cacheURL(for: existing))

        XCTAssertThrowsError(try DuplicateReplacement.prepare(replacing: existing, with: copy, access: cloud.access)) {
            XCTAssertEqual($0 as? DuplicateReplacement.Refusal, .filesInCloud(title: existing.title))
        }

        XCTAssertEqual(
            logLineCount("BRAILLE_FILE_CODE_CHANGED: \(copy.title): read again with ascii-eurobraille"), 1,
            "the copy was not read again before the refusal, so this proves nothing"
        )
        XCTAssertEqual(try textIndexAndRecord(in: copy.tmbDirectory), asImported, "the refusal left the copy read again")
    }

    /// Braille file characters this TextMouth does not know, which a later
    /// TextMouth may have recorded for the book, are refused by name, never
    /// read as other characters: the replacement is refused in the words the
    /// re-read gives a reading that failed, and the copy is as its import
    /// wrote it.
    func testCharactersThisTextMouthDoesNotKnowAreRefusedByName() throws {
        let file = try copyOfBrailleSample(Self.sample, writtenIn: .eurobraille)
        let existing = try imported(file, settingCode: .eurobraille, title: "Lapidary")
        try editRecordMetadata(of: existing) { $0["brailleFileCode"] = Self.unknownCode }
        let copy = try imported(file, settingCode: .northAmerican, title: "Second Lapidary")
        let asImported = try textIndexAndRecord(in: copy.tmbDirectory)
        let sentence = "TextMouth couldn't read “\(copy.title)” again, so it left the book as it was: "
            + "TextMouth has no braille file characters named “ascii-braillo-no-047-01”."

        XCTAssertThrowsError(try DuplicateReplacement.prepare(replacing: existing, with: copy)) {
            XCTAssertEqual($0 as? DuplicateReplacement.Refusal, .copyNotReadAgain(sentence))
            XCTAssertEqual($0.localizedDescription, sentence)
        }
        XCTAssertEqual(try textIndexAndRecord(in: copy.tmbDirectory), asImported)
    }

    /// A copy that cannot be read again, here because its file is only in
    /// the cloud, is refused in the re-read's own words, and nothing changes:
    /// taken as its import read it, it would undo the book's characters.
    func testACopyThatCannotBeReadAgainIsRefusedInTheRereadsWords() throws {
        let file = try copyOfBrailleSample(Self.sample, writtenIn: .eurobraille)
        let existing = try imported(file, settingCode: .eurobraille, title: "Herbarium")
        let copy = try imported(file, settingCode: .northAmerican, title: "Second Herbarium")
        let asImported = try textIndexAndRecord(in: copy.tmbDirectory)
        cloud.markDataless(copy.bookFileURL)

        XCTAssertThrowsError(try DuplicateReplacement.prepare(replacing: existing, with: copy, access: cloud.access)) {
            XCTAssertEqual(
                $0 as? DuplicateReplacement.Refusal,
                .copyNotReadAgain(LibraryCloudWording.notDownloaded(titles: [copy.title]))
            )
        }
        XCTAssertEqual(try textIndexAndRecord(in: copy.tmbDirectory), asImported)
    }
}
