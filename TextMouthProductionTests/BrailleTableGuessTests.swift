import XCTest
@testable import TextMouth

// MARK: - The Stricter Rule and the Guess (brfguess)

/// The guess of a braille book's table at import: the detector's stricter
/// rule (`BrailleCodeDetector.Count.isClearlyEBAE`) and the choice built on
/// it (`BrailleTableGuess`). Every text here is invented, and its braille
/// is liblouis's forward translation of it with the repo's own tables
/// (`BrailleGuessFixtures`), or counted cells made for one rule.
final class BrailleTableGuessTests: XCTestCase {

    // MARK: Helpers

    /// `ascii` as Unicode braille cells, a space becoming the blank cell.
    private func cells(_ ascii: String) -> String {
        String(String.UnicodeScalarView(ascii.utf8.compactMap { byte in
            byte == 0x20 ? BrailleCells.blank : BrailleCells.cell(forASCII: byte)
        }))
    }

    /// The detector's count of pages made of `rows`, in North American Braille ASCII.
    private func count(_ rows: [String]) -> BrailleCodeDetector.Count {
        BrailleCodeDetector.count(of: BrailleFilePages(kind: .brf, pages: [rows.map { cells($0) }]))
    }

    /// `rows` repeated `times` times, as a longer book of the same prose.
    private func repeated(_ rows: [String], _ times: Int) -> [String] {
        Array((0..<times).map { _ in rows }.joined())
    }

    /// A file named `name` in a folder of its own, holding `rows` as a BRF's lines.
    private func file(named name: String, rows: [String]) throws -> URL {
        let url = try makeSandboxDirectory("BrailleTableGuess").appendingPathComponent(name)
        try Data(rows.joined(separator: "\r\n").utf8).write(to: url)
        return url
    }

    /// The table and origin the guess gives the file at `url` when the setting is `setting`.
    private func guess(
        _ url: URL, setting: String = "en-ueb-g2.ctb", guessing: Bool = true
    ) -> (table: String, origin: BrailleTableOrigin?) {
        BrailleTableGuess.table(forImportedFileAt: url, fileCode: "ascii-na", settingTable: setting, guessing: guessing)
    }

    // MARK: The Counts

    /// Invented EBAE prose of about a thousand words is clearly EBAE; the
    /// same prose of about five hundred words looks like it, enough for the
    /// suggestion, but not clearly, so nothing is guessed from it.
    func testALongEBAEPassageIsClearlyEBAEAndAShortOneOnlyLooksLikeIt() {
        let long = count(repeated(BrailleGuessFixtures.ebaeProse, 2))
        XCTAssertTrue(long.isClearlyEBAE, "\(long)")
        XCTAssertGreaterThanOrEqual(long.toWords, BrailleCodeDetector.clearMinimumPerJoinedSign)
        XCTAssertGreaterThanOrEqual(long.byWords, BrailleCodeDetector.clearMinimumPerJoinedSign)

        let short = count(BrailleGuessFixtures.ebaeProse)
        XCTAssertTrue(short.looksLikeEBAE, "the suggestion's rule takes it: \(short)")
        XCTAssertFalse(short.isClearlyEBAE, "the guess's rule does not: \(short)")
    }

    /// The same words in UEB (liblouis forward with en-ueb-g2.ctb) show none of
    /// EBAE's signs, however long the book.
    func testUEBProseNeverShowsTheSigns() {
        let ueb = count(repeated(BrailleGuessFixtures.uebProse, 20))
        XCTAssertEqual(ueb.hits, 0)
        XCTAssertFalse(ueb.looksLikeEBAE)
        XCTAssertFalse(ueb.isClearlyEBAE)
    }

    /// Words with a capital inside them before n or y (camel-case names in a
    /// programming book written in UEB) show many inside-word signs, enough
    /// for the suggestion's rule, but no joined "to" or "by", so the guess
    /// does not take them for EBAE.
    func testManyInsideWordSignsAloneAreNotClearlyEBAE() {
        // 150 different words, each a word, a capital N, and letters that tell it apart.
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var words: [String] = []
        for index in 0..<150 {
            let first = String(letters[index % 26])
            let second = String(letters[(index / 26) % 26])
            words.append("WORD,N\(first)\(second)")
        }
        let found = count([words.joined(separator: " ")])
        XCTAssertEqual(found.hits, 150)
        XCTAssertTrue(found.looksLikeEBAE)
        XCTAssertFalse(found.isClearlyEBAE)
    }

    /// An exclamation mark typed against the next word ("!word") is a joined
    /// "to" to the detector, and never a joined "by": a text of it alone is
    /// not clearly EBAE.
    func testOneJoinedSignAloneIsNotClearlyEBAE() {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var words: [String] = []
        for index in 0..<200 {
            words.append("6WORD\(letters[index % 26])")
        }
        let line = words.joined(separator: " ")
        let found = count([line])
        XCTAssertEqual(found.toWords, 200)
        XCTAssertEqual(found.byWords, 0)
        XCTAssertFalse(found.isClearlyEBAE)
    }

    /// Each limit of the rule, one step each side: 40 signs, one word in 50,
    /// five joined "to" and five joined "by".
    func testEveryLimitOfTheStricterRule() {
        typealias Count = BrailleCodeDetector.Count
        XCTAssertTrue(Count(words: 2000, hits: 40, toWords: 5, byWords: 5).isClearlyEBAE)
        XCTAssertFalse(Count(words: 2001, hits: 40, toWords: 5, byWords: 5).isClearlyEBAE, "fewer than one word in 50")
        XCTAssertFalse(Count(words: 1000, hits: 39, toWords: 5, byWords: 5).isClearlyEBAE, "fewer than 40 signs")
        XCTAssertFalse(Count(words: 1000, hits: 40, toWords: 4, byWords: 36).isClearlyEBAE, "fewer than five joined \"to\"")
        XCTAssertFalse(Count(words: 1000, hits: 40, toWords: 36, byWords: 4).isClearlyEBAE, "fewer than five joined \"by\"")
        // Every book that is clearly EBAE looks like it too: the suggestion is never stricter.
        XCTAssertTrue(Count(words: 2000, hits: 40, toWords: 5, byWords: 5).looksLikeEBAE)
    }

    // MARK: The Choice

    /// A BRF that is clearly EBAE, with the Braille setting a contracted UEB table, is read with
    /// the bundled contracted EBAE table, and says it was guessed.
    func testAClearlyEBAEBRFIsReadWithTheEBAETable() throws {
        let url = try file(named: "Ledger.brf", rows: repeated(BrailleGuessFixtures.ebaeProse, 2))
        let guessed = guess(url)
        XCTAssertEqual(guessed.table, "en_US.tbl")
        XCTAssertEqual(guessed.origin, .guessed)
        XCTAssertEqual(BrailleTableGuess.ebaeTableID, "en_US.tbl")
        XCTAssertEqual(BrailleTableCatalog.table(withID: guessed.table)?.system, "ebae")
        XCTAssertEqual(BrailleTableCatalog.table(withID: guessed.table)?.contraction, .full)
    }

    /// The setting off, a table that is not contracted UEB, a book that is not clearly EBAE, a
    /// UEB book, a PEF, and a file that is not there each leave the setting's table alone, with
    /// no guess said.
    func testWhenUnsureTheSettingsTableStands() throws {
        let long = try file(named: "Ledger.brf", rows: repeated(BrailleGuessFixtures.ebaeProse, 2))

        XCTAssertEqual(guess(long, guessing: false).table, "en-ueb-g2.ctb", "the setting is off")
        XCTAssertNil(guess(long, guessing: false).origin)
        for setting in ["en-ueb-g1.ctb", "en-us-g1.ctb", "en_US.tbl", "mac:fr-bfu-g2.ctb", "no-such-table.ctb"] {
            let result = guess(long, setting: setting)
            XCTAssertEqual(result.table, setting, "a choice other than contracted UEB is the listener's word")
            XCTAssertNil(result.origin, setting)
        }

        let short = try file(named: "Short.brf", rows: BrailleGuessFixtures.ebaeProse)
        XCTAssertEqual(guess(short).table, "en-ueb-g2.ctb", "not clearly EBAE")
        XCTAssertNil(guess(short).origin)

        let ueb = try file(named: "Ueb.brf", rows: repeated(BrailleGuessFixtures.uebProse, 4))
        XCTAssertEqual(guess(ueb).table, "en-ueb-g2.ctb")
        XCTAssertNil(guess(ueb).origin)

        let pef = try file(named: "Ledger.pef", rows: repeated(BrailleGuessFixtures.ebaeProse, 2))
        XCTAssertEqual(guess(pef).table, "en-ueb-g2.ctb", "a PEF is never guessed")
        XCTAssertNil(guess(pef).origin)

        let missing = try makeSandboxDirectory("BrailleTableGuess").appendingPathComponent("Nothing.brf")
        XCTAssertEqual(guess(missing).table, "en-ueb-g2.ctb")
        XCTAssertNil(guess(missing).origin)
    }

    /// The guess is on by default, the setting's key is its own, and a test's bound value wins over
    /// the preferences store.
    @MainActor
    func testTheGuessIsOnByDefaultAndTheSettingTurnsItOff() throws {
        let defaults = try isolatedDefaults()
        XCTAssertEqual(BraillePreferences.guessesTable.key, "brailleGuessesTable")
        XCTAssertTrue(BraillePreferences.guessesTable.read(from: defaults), "on until the listener turns it off")
        BraillePreferences.$guessesTableForImports.withValue(false) {
            XCTAssertFalse(BraillePreferences.importGuessesTable())
        }

        // The Settings model turns it off and on, announcing each change.
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: defaults,
            configService: ConfigService(fileURL: try makeConfigFileURL())
        )
        var announced = 0
        let subscription = settings.objectWillChange.sink { announced += 1 }
        defer { subscription.cancel() }
        XCTAssertTrue(settings.guessesBrailleTable)
        settings.guessesBrailleTable = false
        XCTAssertFalse(settings.guessesBrailleTable)
        XCTAssertEqual(defaults.object(forKey: "brailleGuessesTable") as? Bool, false)
        XCTAssertGreaterThan(announced, 0, "turning it off announced nothing")
        settings.guessesBrailleTable = true
        XCTAssertTrue(BraillePreferences.guessesTable.read(from: defaults))
    }

    // MARK: The Words

    /// A guess is said as the text encoding's is, a choice as the table's name alone.
    func testAGuessIsSaidInPlainWords() {
        let name = "English Braille, American Edition, contracted (Grade 2)"
        XCTAssertEqual(BrailleCodeWording.describe(name, origin: .guessed), name + ", guessed")
        XCTAssertEqual(BrailleCodeWording.describe(name, origin: nil), name)
        XCTAssertEqual(BrailleCodeWording.guessedNote, "guessed")
    }

    /// The Braille tab's switch, its hint, and its caption, exactly, and their place after the
    /// braille file characters' own caption.
    func testTheBrailleTabsSwitchWording() {
        XCTAssertEqual(BrailleSettingsWording.guessLabel, "Guess the braille code of new books")
        XCTAssertEqual(
            BrailleSettingsWording.guessHint,
            "When on, a braille file read as Unified English Braille, contracted, that is clearly English Braille, American Edition, is read with that code instead."
        )
        XCTAssertEqual(
            BrailleSettingsWording.guessCaption,
            "Only a book that clearly shows English Braille, American Edition is changed, when it is added. Book Information says the code was guessed and can choose another."
        )
    }
}

// MARK: - The Record of the Guess (brfguess)

/// Who chose a braille book's table, kept in the row, the package record, and the removal marker:
/// written only for a guess, read from files written before it existed, repaired when damaged, and
/// replaced by a choice.
final class BrailleTableOriginRecordTests: XCTestCase {

    // MARK: Fixtures

    /// A braille book read with `table`, its origin `origin`.
    private func book(
        table: String? = "en_US.tbl", origin: BrailleTableOrigin? = .guessed, version: String? = nil
    ) -> Book {
        Book(
            title: "Ledger", format: .braille, filePath: "/nowhere/Ledger.brf", md5Hash: "braille-origin-fixture",
            tmbDirectoryName: "Ledger.tmb", brailleTable: table, brailleTableVersion: version, brailleTableOrigin: origin
        )
    }

    /// The JSON a library row of `book` is written as.
    private func row(of book: Book) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(book)) as? [String: Any])
    }

    /// The book a library row's JSON decodes as.
    private func decoded(_ row: [String: Any]) throws -> Book {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Book.self, from: JSONSerialization.data(withJSONObject: row))
    }

    /// The package record of `book` over `stored`, as a save writes it.
    private func written(_ book: Book, over stored: Book?) -> BookMetadata {
        let storedRecord = stored.map { StoredBookRecord(info: $0.makeBookInfo(), keepsContentIndex: true) }
        return book.bookInfo(replacing: storedRecord, contentIndex: nil).metadata
    }

    // MARK: The Row

    /// A guess writes "guessed" in its row and reads it back; a book with no guess writes no key, so
    /// every other row of the library is exactly as it was.
    func testARowHoldsTheOriginOnlyForAGuess() throws {
        let guessed = try row(of: book())
        XCTAssertEqual(guessed["brailleTableOrigin"] as? String, "guessed")
        XCTAssertEqual(try decoded(guessed).brailleTableOrigin, .guessed)
        XCTAssertNil(try row(of: book(origin: nil))["brailleTableOrigin"])
    }

    /// An older row (written before the field), and one whose value cannot be read, decode with
    /// none, keeping the table and the rest of the book.
    func testAnOlderRowOrADamagedOneDecodesWithNoOrigin() throws {
        var older = try row(of: book())
        older.removeValue(forKey: "brailleTableOrigin")
        let olderBook = try decoded(older)
        XCTAssertNil(olderBook.brailleTableOrigin)
        XCTAssertEqual(olderBook.brailleTable, "en_US.tbl")

        for damaged in ["picked", 17, ["guessed"]] as [Any] {
            var damagedRow = try row(of: book())
            damagedRow["brailleTableOrigin"] = damaged
            let repaired = try decoded(damagedRow)
            XCTAssertNil(repaired.brailleTableOrigin, "\(damaged)")
            XCTAssertEqual(repaired.brailleTable, "en_US.tbl", "\(damaged)")
            XCTAssertEqual(repaired.title, "Ledger", "\(damaged)")
        }
    }

    // MARK: The Package Record

    /// The record keeps the origin, written and read, and the book made from it has it.
    func testThePackageRecordKeepsTheOrigin() throws {
        let guessed = book()
        let info = guessed.makeBookInfo()
        XCTAssertEqual(info.metadata.brailleTableOrigin, .guessed)

        let package = try makeSandboxDirectory("BrailleOrigin").appendingPathComponent("Ledger.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try info.save(to: package)
        let loaded = try BookInfo.load(from: package)
        XCTAssertEqual(loaded.metadata.brailleTableOrigin, .guessed)
        let rebuilt = Book(record: loaded, filePath: guessed.filePath, folderPath: "", tmbDirectoryName: "Ledger.tmb")
        XCTAssertEqual(rebuilt.brailleTableOrigin, .guessed)
        XCTAssertEqual(rebuilt.brailleTable, "en_US.tbl")

        // A record written before the field, and one whose value cannot be read, still load.
        let recordURL = TextMouthPaths.bookInfoPath(in: package)
        for value in [nil, NSNull(), "picked", 3] as [Any?] {
            try info.save(to: package)
            var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
            var metadata = try XCTUnwrap(record["metadata"] as? [String: Any])
            XCTAssertEqual(metadata["brailleTableOrigin"] as? String, "guessed")
            metadata["brailleTableOrigin"] = value
            record["metadata"] = metadata
            try JSONSerialization.data(withJSONObject: record).write(to: recordURL)
            let reloaded = try BookInfo.load(from: package)
            XCTAssertNil(reloaded.metadata.brailleTableOrigin, "\(String(describing: value))")
            XCTAssertEqual(reloaded.metadata.brailleTable, "en_US.tbl", "\(String(describing: value))")
        }
    }

    /// The origin goes into the record with the table: the row's own whenever the row holds a table
    /// (so a choice, which sets the table and clears the guess, replaces a guess the record holds),
    /// and the record's only when the row holds no table.
    func testTheRecordTakesTheOriginWithTheTable() {
        let guessedRecord = book()
        // A choice of another table, and a choice of the very table that was guessed.
        XCTAssertNil(written(book(table: "en-ueb-g2.ctb", origin: nil), over: guessedRecord).brailleTableOrigin)
        XCTAssertNil(written(book(origin: nil), over: guessedRecord).brailleTableOrigin)
        // The guess itself, over a record that has none.
        XCTAssertEqual(written(book(), over: book(origin: nil)).brailleTableOrigin, .guessed)
        XCTAssertEqual(written(book(), over: nil).brailleTableOrigin, .guessed)
        // A row that lost its table takes the record's table and its origin.
        let lost = written(book(table: nil, origin: nil), over: guessedRecord)
        XCTAssertEqual(lost.brailleTable, "en_US.tbl")
        XCTAssertEqual(lost.brailleTableOrigin, .guessed)
    }

    // MARK: The Marker

    /// The removal marker keeps the origin, so a book added back keeps "guessed" said of its
    /// table; a marker without it, or with an unreadable one, still reads, with none.
    func testTheMarkerKeepsTheOrigin() throws {
        let package = try makeSandboxDirectory("BrailleOrigin").appendingPathComponent("Ledger.tmb", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try RemovedFromLibraryMarker(book: book()).write(into: package)
        XCTAssertEqual(try RemovedFromLibraryMarker.read(in: package).brailleTableOrigin, .guessed)

        let url = TextMouthPaths.removedFromLibraryMarkerPath(in: package)
        for value in [nil, "picked", 5] as [Any?] {
            try RemovedFromLibraryMarker(book: book()).write(into: package)
            var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            fields["brailleTableOrigin"] = value
            try JSONSerialization.data(withJSONObject: fields).write(to: url)
            let marker = try RemovedFromLibraryMarker.read(in: package)
            XCTAssertNil(marker.brailleTableOrigin, "\(String(describing: value))")
            XCTAssertEqual(marker.brailleTable, "en_US.tbl", "\(String(describing: value))")
        }
        XCTAssertNil(RemovedFromLibraryMarker(book: book(origin: nil)).brailleTableOrigin)
    }

    /// A braille book rebuilt from its marker keeps the origin; a book of another format takes none.
    func testABookRebuiltFromItsMarkerKeepsTheOrigin() throws {
        for (format, fileName, expected) in [
            (BookFormat.braille, "Ledger.brf", BrailleTableOrigin?.some(.guessed)),
            (.txt, "Ledger.txt", nil),
        ] {
            let package = try makeSandboxDirectory("BrailleOrigin").appendingPathComponent("Ledger.tmb", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try Data("Hello\n".utf8).write(to: package.appendingPathComponent(fileName))
            var source = book()
            source.format = format
            let marker = RemovedFromLibraryMarker(book: source)

            let rebuilt = try FileImportService.reconstructedBook(
                inPackage: package, marker: marker, folderPath: "", dateAdded: Date()
            )
            XCTAssertEqual(rebuilt.brailleTableOrigin, expected, fileName)
        }
    }

    // MARK: The Analysis Summary and the Reader's Fields

    /// An analysis summary brings a lagging row to the record's table and its origin together.
    func testAnAnalysisSummaryTakesTheOriginWithTheTable() {
        var lagging = book(table: "en-ueb-g2.ctb", origin: nil)
        ContentAnalysisSummary(committed: book()).apply(to: &lagging)
        XCTAssertEqual(lagging.brailleTable, "en_US.tbl")
        XCTAssertEqual(lagging.brailleTableOrigin, .guessed)

        var choice = book()
        ContentAnalysisSummary(committed: book(table: "en-ueb-g2.ctb", origin: nil)).apply(to: &choice)
        XCTAssertEqual(choice.brailleTable, "en-ueb-g2.ctb")
        XCTAssertNil(choice.brailleTableOrigin, "a choice replaced the guess")
    }

    /// An open reader takes the origin with the library's other fields.
    func testTheReadersLibraryFieldsCarryTheOrigin() {
        var reader = book(table: "en-ueb-g2.ctb", origin: nil)
        reader.libraryFields = book().libraryFields
        XCTAssertEqual(reader.brailleTableOrigin, .guessed)
    }

    // MARK: Words

    /// Book Information's row and Speak Info say a guess as "…, guessed", and a book whose table was
    /// chosen, or never guessed, as the table's name alone.
    func testTheBookInformationRowSaysGuessed() {
        XCTAssertEqual(
            book().brailleCodeDescription, "English Braille, American Edition, contracted (Grade 2), guessed"
        )
        XCTAssertEqual(book(origin: nil).brailleCodeDescription, "English Braille, American Edition, contracted (Grade 2)")
        XCTAssertEqual(book().bookInfoBrailleCodeRow?.label, "Braille Code")
    }
}

// MARK: - The Guess at Import, and a Choice After It (brfguess)

/// A BRF imported through the real import and read again: the guess recorded in its row and its
/// record, said in Book Information, and replaced for good by a choice of a braille code. Every
/// import binds the table, the braille file characters, and the guess it names, never the user's
/// settings.
@MainActor
final class BrailleTableGuessImportTests: CloudMaintenanceTestCase {

    // MARK: Fixtures

    /// Contracted UEB, the table the Braille setting names here.
    private static let grade2 = "en-ueb-g2.ctb"
    /// The bundled contracted EBAE table, the guess.
    private static let ebae = BrailleTableGuess.ebaeTableID

    /// A BRF of invented EBAE prose, long enough to be clearly EBAE, in a folder of its own.
    private func ebaeFile() throws -> URL {
        let url = try makeSandboxDirectory("BrailleGuessImport").appendingPathComponent("Ledger Book.brf")
        let rows = Array((0..<2).map { _ in BrailleGuessFixtures.ebaeProse }.joined())
        try Data(rows.joined(separator: "\r\n").utf8).write(to: url)
        return url
    }

    /// `url` imported with the Braille setting's table `setting` and the guess `guessing`.
    private func imported(_ url: URL, setting: String = BrailleTableGuessImportTests.grade2, guessing: Bool = true) throws -> Book {
        try BraillePreferences.$tableForImports.withValue(setting) {
            try BraillePreferences.$fileCodeForImports.withValue("ascii-na") {
                try BraillePreferences.$guessesTableForImports.withValue(guessing) {
                    try importedForTest(url).book
                }
            }
        }
    }

    // MARK: The Import

    /// An EBAE BRF imported while the setting is contracted UEB is read with the EBAE table, the row
    /// and the record say it was guessed, and the text is the EBAE table's reading, not UEB's.
    func testAnEBAEBRFIsImportedWithTheGuessedTable() throws {
        let book = try imported(try ebaeFile())

        XCTAssertEqual(book.brailleTable, Self.ebae)
        XCTAssertEqual(book.brailleTableOrigin, .guessed)
        XCTAssertNil(book.brailleTableVersion, "a bundled table records no liblouis version")
        XCTAssertEqual(
            book.brailleCodeDescription, "English Braille, American Edition, contracted (Grade 2), guessed"
        )
        let record = try BookInfo.load(from: book.tmbDirectory).metadata
        XCTAssertEqual(record.brailleTable, Self.ebae)
        XCTAssertEqual(record.brailleTableOrigin, .guessed)

        let expected = Data(try BrailleBookReader.markdown(
            of: book.bookFileURL, table: Self.ebae, fileCode: "ascii-na", includesPages: true
        ).utf8)
        XCTAssertEqual(try Data(contentsOf: MarkdownCacheService.cacheURL(for: book)), expected)
        let asUEB = Data(try BrailleBookReader.markdown(
            of: book.bookFileURL, table: Self.grade2, fileCode: "ascii-na", includesPages: true
        ).utf8)
        XCTAssertNotEqual(expected, asUEB, "UEB must read the file otherwise, or the guess proves nothing")
    }

    /// With the guess off, or a setting that is not contracted UEB, the setting's table stands and
    /// the book records no guess, in its row or its record.
    func testWithTheGuessOffOrAnotherTableTheSettingsTableStands() throws {
        let url = try ebaeFile()
        let off = try imported(url, guessing: false)
        XCTAssertEqual(off.brailleTable, Self.grade2)
        XCTAssertNil(off.brailleTableOrigin)
        XCTAssertNil(try BookInfo.load(from: off.tmbDirectory).metadata.brailleTableOrigin)

        let uncontracted = try imported(try ebaeFile(), setting: "en-ueb-g1.ctb")
        XCTAssertEqual(uncontracted.brailleTable, "en-ueb-g1.ctb")
        XCTAssertNil(uncontracted.brailleTableOrigin)
    }

    // MARK: Book Information

    /// The Braille Code pop-up of a guessed book names the code with ", guessed", suggests nothing
    /// (the book is not read as UEB), and, once another code is chosen, names that code alone.
    func testThePopUpSaysGuessedUntilACodeIsChosen() async throws {
        let book = try imported(try ebaeFile())
        let model = BrailleCodeChoiceModel(book: book, library: makeModel(with: [book]))
        await model.load()

        XCTAssertEqual(
            model.name(of: model.selection), "English Braille, American Edition, contracted (Grade 2), guessed"
        )
        XCTAssertEqual(
            model.name(of: .table(Self.grade2)), "Unified English Braille, contracted (Grade 2)",
            "another table is named as it always is"
        )
        XCTAssertNil(model.suggestion)
    }

    /// Choosing a braille code replaces the guess for good: reading the book again with another table
    /// leaves its table, with no guess in the row or the record; and so does choosing the very table
    /// that was guessed (the listener's word now).
    func testChoosingACodeReplacesTheGuessForGood() async throws {
        for chosen in [Self.grade2, Self.ebae] {
            let book = try imported(try ebaeFile())
            XCTAssertEqual(book.brailleTableOrigin, .guessed)
            let model = makeModel(with: [book])
            let table = try XCTUnwrap(BrailleTableCatalog.table(withID: chosen))

            let outcome = await model.readTextAgain(bookID: book.id, choosing: .brailleTable(table))

            guard case .success = outcome else { return XCTFail("\(chosen): \(outcome)") }
            let row = try XCTUnwrap(model.bookByID(book.id))
            XCTAssertEqual(row.brailleTable, chosen)
            XCTAssertNil(row.brailleTableOrigin, "\(chosen): the row still says guessed")
            let record = try BookInfo.load(from: book.tmbDirectory).metadata
            XCTAssertEqual(record.brailleTable, chosen)
            XCTAssertNil(record.brailleTableOrigin, "\(chosen): the record still says guessed")
            XCTAssertEqual(row.brailleCodeDescription, BrailleTableCatalog.description(ofTableID: chosen))
        }
    }
}
