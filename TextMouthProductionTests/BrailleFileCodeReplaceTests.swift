import os
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
    /// Another table, contracted UEB, which the listener may choose for the
    /// book in Book Information (FMT21).
    private static let otherTable = "en-ueb-g2.ctb"
    /// The id of a code no TextMouth knows yet, as a later TextMouth might
    /// record one.
    private static let unknownCode = "ascii-braillo-no-047-01"
    /// When fixtures' dates fall, in whole seconds.
    private static let date = Date(timeIntervalSince1970: 1_790_000_000)

    /// The book the braille file at `url` imports as, with the sample's
    /// table and with `code` as the Braille setting's file code, titled
    /// `title` with a suffix of its own, in its row and its record, so the
    /// debug log's lines that name it are this test's.
    private func imported(
        _ url: URL, settingCode code: BrailleFileCode, title: String, settingTable table: String = BrailleFileCodeReplaceTests.table
    ) throws -> Book {
        var book = try BraillePreferences.$tableForImports.withValue(table) {
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
    private func northAmericanReading(table: String = BrailleFileCodeReplaceTests.table) throws -> Data {
        Data(try BrailleBookReader.markdown(
            of: copyOfFormatSample(Self.sample), table: table, fileCode: "ascii-na", includesPages: true
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

    /// The sample imported with the Braille setting's uncontracted table,
    /// then read again with the contracted table in Book Information (the
    /// Braille Code pop-up). The same file added again is translated with the
    /// setting's table too; answered Replace Existing, the copy taking the
    /// book's place is read again with the table the listener chose: its row
    /// and record hold it, its content.md is the contracted reading, and the
    /// debug log says the copy was read again with a table, and with no file
    /// code, for the characters were not in question.
    func testReplaceExistingKeepsTheBrailleCodeChosenInBookInformation() async throws {
        keepDeletionsOutOfTheTrash()
        let file = try copyOfFormatSample(Self.sample)
        let existing = try imported(file, settingCode: .northAmerican, title: "Concordance")
        let model = makeModel(with: [existing])
        let contracted = try XCTUnwrap(BrailleTableCatalog.table(withID: Self.otherTable))
        let corrected = await model.readTextAgain(bookID: existing.id, choosing: .brailleTable(contracted))
        XCTAssertTrue(corrected.succeeded, "the book was not read again: \(corrected)")
        let copy = try imported(file, settingCode: .northAmerican, title: "Second Concordance")
        let expected = try northAmericanReading(table: Self.otherTable)
        XCTAssertEqual(copy.md5Hash, existing.md5Hash, "the same file must have the same content hash, or this proves nothing")
        XCTAssertEqual(copy.brailleTable, Self.table)
        XCTAssertNotEqual(try contentMD(in: copy.tmbDirectory), expected, "the setting's table must read the copy otherwise, or this proves nothing")

        XCTAssertFalse(model.addBookCheckingDuplicate(copy), "the copy was not asked about as a duplicate")
        let outcome = model.answerCurrentImportDecision(.replaceExisting)

        XCTAssertEqual(outcome, .success(nil))
        let row = try XCTUnwrap(model.bookByID(existing.id))
        XCTAssertEqual(row.tmbDirectoryName, copy.tmbDirectoryName, "the copy did not take the book's place")
        XCTAssertEqual(row.brailleTable, Self.otherTable)
        XCTAssertEqual(try BookInfo.load(from: row.tmbDirectory).metadata.brailleTable, Self.otherTable)
        XCTAssertEqual(try contentMD(in: row.tmbDirectory), expected)
        XCTAssertEqual(logLineCount("BRAILLE_TABLE_CHANGED: \(copy.title): read again with \(Self.otherTable)"), 1)
        XCTAssertEqual(logLineCount("BRAILLE_FILE_CODE_CHANGED: \(copy.title)"), 0, "a table was logged as a file code's")
    }

    /// A book whose listener chose both its braille file characters and its
    /// braille code, each with its own pop-up, keeps both through Replace
    /// Existing, in one re-read of the copy: its row and record hold the
    /// Eurobraille and the contracted table, its content.md is the North
    /// American sample's own text translated with the contracted table, and
    /// the debug log says each.
    func testReplaceExistingKeepsBothCodesChosenInBookInformation() async throws {
        keepDeletionsOutOfTheTrash()
        let file = try copyOfBrailleSample(Self.sample, writtenIn: .eurobraille)
        let existing = try imported(file, settingCode: .northAmerican, title: "Lexicon")
        let model = makeModel(with: [existing])
        let contracted = try XCTUnwrap(BrailleTableCatalog.table(withID: Self.otherTable))
        let firstRead = await model.readTextAgain(bookID: existing.id, choosing: .brailleFileCode(.eurobraille))
        let secondRead = await model.readTextAgain(bookID: existing.id, choosing: .brailleTable(contracted))
        XCTAssertTrue(firstRead.succeeded && secondRead.succeeded, "the book was not read again: \(firstRead) \(secondRead)")
        let copy = try imported(file, settingCode: .northAmerican, title: "Second Lexicon")
        let expected = try northAmericanReading(table: Self.otherTable)
        XCTAssertNotEqual(try contentMD(in: copy.tmbDirectory), expected, "the setting must misread the copy, or this proves nothing")

        XCTAssertFalse(model.addBookCheckingDuplicate(copy), "the copy was not asked about as a duplicate")
        let outcome = model.answerCurrentImportDecision(.replaceExisting)

        XCTAssertEqual(outcome, .success(nil))
        let row = try XCTUnwrap(model.bookByID(existing.id))
        XCTAssertEqual(row.tmbDirectoryName, copy.tmbDirectoryName, "the copy did not take the book's place")
        XCTAssertEqual(row.brailleFileCode, "ascii-eurobraille")
        XCTAssertEqual(row.brailleTable, Self.otherTable)
        let record = try BookInfo.load(from: row.tmbDirectory).metadata
        XCTAssertEqual(record.brailleFileCode, "ascii-eurobraille")
        XCTAssertEqual(record.brailleTable, Self.otherTable)
        XCTAssertEqual(try contentMD(in: row.tmbDirectory), expected)
        XCTAssertEqual(logLineCount("BRAILLE_FILE_CODE_CHANGED: \(copy.title): read again with ascii-eurobraille"), 1)
        XCTAssertEqual(logLineCount("BRAILLE_TABLE_CHANGED: \(copy.title): read again with \(Self.otherTable)"), 1)
    }

    // MARK: - When a Copy Is Read Again

    /// A copy is read again with the book's table only when both are braille
    /// books of the same bytes, and the book's table, as its stored value
    /// names it (none is the default table), is not the copy's. A PEF has a
    /// table too; a text book has none.
    func testACopyIsTranslatedAgainOnlyWithTheBooksOtherTable() {
        /// A book of the file named `name`, of content `hash`, translated
        /// with `table`.
        func book(_ name: String, hash: String = "same", table: String?, format: BookFormat = .braille) -> Book {
            Book(title: "Gazetteer", format: format, filePath: "/nonexistent/\(name)", md5Hash: hash, brailleTable: table)
        }
        let copy = book("Copy.brf", table: Self.table)
        let cases: [(existing: Book, copy: Book, expected: String?, label: String)] = [
            (book("Book.brf", table: Self.otherTable), copy, Self.otherTable, "another table"),
            (book("Book.pef", table: Self.otherTable), book("Copy.pef", table: Self.table), Self.otherTable, "a PEF"),
            (book("Book.brf", table: Self.table), copy, nil, "the same table"),
            (book("Book.brf", table: nil), book("Copy.brf", table: BrailleTableCatalog.defaultTableID), nil, "none, the default"),
            (book("Book.brf", table: nil), copy, BrailleTableCatalog.defaultTableID, "none against another table"),
            (book("Book.brf", table: Self.otherTable), book("Copy.brf", table: nil), nil, "the default, which is the book's"),
            (book("Book.brf", hash: "other", table: Self.otherTable), copy, nil, "other bytes"),
            (book("Book.brf", hash: "", table: Self.otherTable), book("Copy.brf", hash: "", table: Self.table), nil, "no content hash"),
            (book("Book.txt", table: Self.otherTable, format: .txt), copy, nil, "a text book"),
        ]
        for testCase in cases {
            XCTAssertEqual(
                DuplicateReplacement.brailleTableToReadAgain(replacing: testCase.existing, with: testCase.copy),
                testCase.expected,
                testCase.label
            )
        }
    }

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

    // MARK: - Off the Main Actor

    /// The words of an answer carried out off the main actor, exactly.
    func testTheWordsOfAnAnswerCarriedOutOffTheMainActor() {
        XCTAssertEqual(
            DuplicateCopyWording.answerUnderWay,
            "TextMouth is still carrying out your last answer. Wait until it finishes."
        )
        XCTAssertEqual(
            DuplicateCopyWording.replacing(bookTitle: "Gazetteer"), "Replacing “Gazetteer”. This can take a moment."
        )
        XCTAssertEqual(
            DuplicateCopyWording.changedWhileReplacing(bookTitle: "Gazetteer"),
            "“Gazetteer” changed while it was being replaced, so TextMouth left both copies as they are. "
                + "Choose Replace Existing again."
        )
    }

    /// A library whose Eurobraille book was read again as Eurobraille in
    /// Book Information, asked whether the same file, imported with the
    /// Braille setting's North American Braille ASCII, replaces it: so that
    /// answering Replace Existing must read the copy again, the long work
    /// the sheets do off the main actor.
    private func askedWhetherToReplace(
        _ title: String
    ) async throws -> (model: LibraryViewModel, existing: Book, copy: Book, questionID: ImportDecision.ID) {
        keepDeletionsOutOfTheTrash()
        let file = try copyOfBrailleSample(Self.sample, writtenIn: .eurobraille)
        let original = try imported(file, settingCode: .northAmerican, title: title)
        let model = makeModel(with: [original])
        // Its own list of re-reads under way, so no other test's shows here.
        model.textRereads = TextRereads()
        let corrected = await model.readTextAgain(bookID: original.id, choosing: .brailleFileCode(.eurobraille))
        XCTAssertTrue(corrected.succeeded, "the book was not read again: \(corrected)")
        let copy = try imported(file, settingCode: .northAmerican, title: "Second \(title)")
        XCTAssertFalse(model.addBookCheckingDuplicate(copy), "the copy was not asked about as a duplicate")
        return (model, try XCTUnwrap(model.bookByID(original.id)), copy, try XCTUnwrap(model.importDecisions.current?.id))
    }

    /// A preparation that does the library's own, then waits at `gate` until
    /// the test lets it go (or twenty seconds pass, so no test waits for
    /// ever), having said it reached the wait through `reached`: the long
    /// work of a replacement, held where the test can look at the library.
    private func heldPreparer(
        reached: OSAllocatedUnfairLock<Bool>, gate: DispatchSemaphore
    ) -> LibraryViewModel.ReplacementPreparer {
        { existing, copy in
            let preparation = try LibraryViewModel.replacementPreparer(existing, copy)
            reached.withLock { $0 = true }
            _ = gate.wait(timeout: .now() + 20)
            return preparation
        }
    }

    /// Waits, at most ten seconds, until `reached` is set.
    private func waitUntilReached(_ reached: OSAllocatedUnfairLock<Bool>) async throws {
        for _ in 0..<1_000 where !reached.withLock({ $0 }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(reached.withLock { $0 }, "the preparation never began")
    }

    /// Replace Existing, answered the way the sheets answer it, reads the
    /// copy again off the main thread, and ends as the synchronous answer
    /// does: the copy takes the book's place in Eurobraille, nothing is left
    /// marked as under way, and the question is settled.
    func testReplaceExistingReadsTheCopyAgainOffTheMainThread() async throws {
        let (model, existing, copy, questionID) = try await askedWhetherToReplace("Cartulary")
        let ranOnMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)

        let outcome = await model.answerImportDecisionOffMain(questionID, with: .replaceExisting) { existing, copy in
            ranOnMain.withLock { $0 = Thread.isMainThread }
            return try LibraryViewModel.replacementPreparer(existing, copy)
        }

        XCTAssertEqual(ranOnMain.withLock { $0 }, false, "the copy was made ready on the main thread")
        XCTAssertEqual(outcome, .success(nil))
        let row = try XCTUnwrap(model.bookByID(existing.id))
        XCTAssertEqual(row.tmbDirectoryName, copy.tmbDirectoryName, "the copy did not take the book's place")
        XCTAssertEqual(row.brailleFileCode, "ascii-eurobraille")
        XCTAssertEqual(try recordedCode(in: row.tmbDirectory), "ascii-eurobraille")
        XCTAssertEqual(try contentMD(in: row.tmbDirectory), try northAmericanReading())
        XCTAssertNil(model.importDecisions.current, "the question was not settled")
        XCTAssertNil(model.importDecisions.answering)
        XCTAssertTrue(model.booksBeingReadAgain.isEmpty, "the book stayed marked as read again")
    }

    /// While the copy is made ready the question is marked as being
    /// answered, the book is marked as being read again, and no other answer
    /// acts, whichever way it is given: the question stays, saying so, and
    /// the library is as it was. When the work ends, the answer goes on.
    func testWhileTheCopyIsMadeReadyNoOtherAnswerActs() async throws {
        let (model, existing, copy, questionID) = try await askedWhetherToReplace("Chartulary")
        let reached = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        let answer = Task { @MainActor in
            await model.answerImportDecisionOffMain(
                questionID, with: .replaceExisting, prepare: heldPreparer(reached: reached, gate: gate)
            )
        }
        try await waitUntilReached(reached)

        XCTAssertEqual(model.importDecisions.answering, questionID)
        XCTAssertTrue(model.booksBeingReadAgain.contains(existing.id))
        XCTAssertEqual(
            model.readingAgainRefusal(of: existing.id), DuplicateCopyWording.replacingRefusal(bookTitle: existing.title),
            "what would rewrite the book's text does not wait, or does not say it is being replaced"
        )
        let busy = OperationOutcome.failure(DuplicateCopyWording.answerUnderWay)
        XCTAssertEqual(model.answerImportDecision(questionID, with: .keepBoth), busy)
        XCTAssertEqual(model.answerImportDecision(questionID, with: .cancel), busy)
        let secondSheet = await model.answerImportDecisionOffMain(questionID, with: .replaceExisting)
        XCTAssertEqual(secondSheet, busy)
        XCTAssertEqual(model.bookByID(existing.id), existing, "an answer changed the library meanwhile")
        XCTAssertEqual(model.importDecisions.current?.id, questionID)

        gate.signal()
        let outcome = await answer.value

        XCTAssertEqual(outcome, .success(nil))
        XCTAssertEqual(model.bookByID(existing.id)?.tmbDirectoryName, copy.tmbDirectoryName)
        XCTAssertNil(model.importDecisions.answering)
        XCTAssertTrue(model.booksBeingReadAgain.isEmpty)
    }

    /// If the library's copy changes while the new copy is made ready, what
    /// was carried over is out of date: the new copy is put back as its
    /// import wrote it, both copies stay, the question stays asking, and the
    /// sentence says to choose Replace Existing again.
    func testACopyThatChangesMeanwhileIsNotReplacedFromOutOfDateWork() async throws {
        let (model, existing, copy, questionID) = try await askedWhetherToReplace("Cartulary Revised")
        let asImported = try textIndexAndRecord(in: copy.tmbDirectory)
        let reached = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        let answer = Task { @MainActor in
            await model.answerImportDecisionOffMain(
                questionID, with: .replaceExisting, prepare: heldPreparer(reached: reached, gate: gate)
            )
        }
        try await waitUntilReached(reached)
        var edited = existing
        edited.title = "Edited by hand \(UUID().uuidString.prefix(8))"
        model.library.books = model.library.books.map { $0.id == existing.id ? edited : $0 }

        gate.signal()
        let outcome = await answer.value

        XCTAssertEqual(outcome, .failure(DuplicateCopyWording.changedWhileReplacing(bookTitle: existing.title)))
        XCTAssertEqual(try textIndexAndRecord(in: copy.tmbDirectory), asImported, "the new copy was not put back")
        XCTAssertEqual(model.bookByID(existing.id), edited, "the library's copy was replaced")
        XCTAssertEqual(model.importDecisions.current?.id, questionID, "the question went")
        XCTAssertNil(model.importDecisions.answering)
        XCTAssertTrue(model.booksBeingReadAgain.isEmpty)
    }

    /// A question withdrawn while its answer is carried out (its batch was
    /// cancelled) is not answered when the work ends: the new copy is put
    /// back as its import wrote it, the library's copy stays, and the answer
    /// neither fails nor settles another question.
    func testAQuestionWithdrawnMeanwhileIsNotAnswered() async throws {
        let (model, existing, copy, questionID) = try await askedWhetherToReplace("Cartulary Withdrawn")
        let asImported = try textIndexAndRecord(in: copy.tmbDirectory)
        let reached = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        let answer = Task { @MainActor in
            await model.answerImportDecisionOffMain(
                questionID, with: .replaceExisting, prepare: heldPreparer(reached: reached, gate: gate)
            )
        }
        try await waitUntilReached(reached)
        _ = model.importDecisions.withdrawAll { $0.id == questionID }

        gate.signal()
        let outcome = await answer.value

        XCTAssertEqual(outcome, .success(nil))
        XCTAssertEqual(try textIndexAndRecord(in: copy.tmbDirectory), asImported, "the new copy was not put back")
        XCTAssertEqual(model.bookByID(existing.id), existing)
        XCTAssertNil(model.importDecisions.answering)
        XCTAssertTrue(model.booksBeingReadAgain.isEmpty)
    }

    /// Holds the preparation at its wait, runs `disturbance` on the library
    /// there, lets the work end, and returns the answer's outcome, with the
    /// new copy as its import wrote it, to compare with. The two disturbances
    /// the re-check after the wait must meet: a data-directory move that
    /// begins, and a reader that opens the book.
    private func answerDisturbed(
        _ title: String, by disturbance: (LibraryViewModel, Book) -> Void
    ) async throws -> (outcome: OperationOutcome, model: LibraryViewModel, existing: Book, copy: Book,
                       questionID: ImportDecision.ID, asImported: [Data]) {
        let (model, existing, copy, questionID) = try await askedWhetherToReplace(title)
        let asImported = try textIndexAndRecord(in: copy.tmbDirectory)
        let reached = OSAllocatedUnfairLock(initialState: false)
        let gate = DispatchSemaphore(value: 0)
        let answer = Task { @MainActor in
            await model.answerImportDecisionOffMain(
                questionID, with: .replaceExisting, prepare: heldPreparer(reached: reached, gate: gate)
            )
        }
        try await waitUntilReached(reached)
        disturbance(model, existing)
        gate.signal()
        let outcome = await answer.value
        return (outcome, model, existing, copy, questionID, asImported)
    }

    /// A data-directory move that begins while the copy is made ready would
    /// copy the library with the old copy's package half replaced: when the
    /// work ends, the answer is refused in the move's words, the new copy is
    /// put back as its import wrote it, the library's copy stays, and the
    /// question stays asking.
    func testAMoveThatBeginsMeanwhileRefusesTheAnswerAndPutsEverythingBack() async throws {
        let result = try await answerDisturbed("Cartulary Moving") { model, _ in
            model.dataDirectoryMove = DataDirectoryMoveProgress(destination: URL(fileURLWithPath: "/Volumes/Spare Disk/TextMouth"))
        }
        result.model.dataDirectoryMove = nil

        XCTAssertEqual(result.outcome, .failure(DataDirectoryMoveWording.importAnswerRefusal))
        XCTAssertEqual(try textIndexAndRecord(in: result.copy.tmbDirectory), result.asImported, "the new copy was not put back")
        XCTAssertEqual(result.model.bookByID(result.existing.id), result.existing, "the library's copy was replaced")
        XCTAssertEqual(result.model.importDecisions.current?.id, result.questionID, "the question went")
        XCTAssertNil(result.model.importDecisions.answering)
        XCTAssertTrue(result.model.booksBeingReadAgain.isEmpty)
    }

    /// A reader that opens the library's copy while the copy is made ready
    /// would show a book whose package then moves under it: when the work
    /// ends, the answer is refused in the words of a book in use, the new
    /// copy is put back as its import wrote it, the library's copy stays, and
    /// the question stays asking.
    func testAReaderOpenedMeanwhileRefusesTheAnswerAndPutsEverythingBack() async throws {
        let result = try await answerDisturbed("Cartulary Opened") { model, existing in
            model.openBookIDs.insert(existing.id)
        }
        result.model.openBookIDs.remove(result.existing.id)

        let refusal = DuplicateReplacement.Refusal.inUse(.openInReader, title: result.existing.title)
        XCTAssertEqual(result.outcome, .failure(refusal.sentence))
        XCTAssertEqual(try textIndexAndRecord(in: result.copy.tmbDirectory), result.asImported, "the new copy was not put back")
        XCTAssertEqual(result.model.bookByID(result.existing.id), result.existing, "the library's copy was replaced")
        XCTAssertEqual(result.model.importDecisions.current?.id, result.questionID, "the question went")
        XCTAssertNil(result.model.importDecisions.answering)
        XCTAssertTrue(result.model.booksBeingReadAgain.isEmpty)
    }

    /// Both sheets that show the question, the Mac's through its presenter
    /// and the iPhone's through its copier, give the answer through the form
    /// that carries it out off the main actor, never the synchronous one,
    /// which would freeze every window and VoiceOver's focus for as long as a
    /// long braille book takes to be read again. The form's behavior is held
    /// by the tests above; this holds the sheets to calling it.
    func testBothSheetsAnswerOffTheMainActor() throws {
        for path in ["Views/Library/ImportDecisionPresenter.swift", "Platform/iOS/Services/PhoneImportCopier.swift"] {
            let source = try String(contentsOf: AppSourceFile.folder.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(source.contains(".answerImportDecisionOffMain("), "\(path) does not answer off the main actor")
            XCTAssertFalse(source.contains(".answerImportDecision("), "\(path) answers on the main actor")
            XCTAssertFalse(source.contains(".answerCurrentImportDecision("), "\(path) answers on the main actor")
        }
    }
}
