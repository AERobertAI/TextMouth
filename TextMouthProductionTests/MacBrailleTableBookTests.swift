import XCTest
@testable import TextMouth

/// Braille books and exports with one of this Mac's tables (October 20,
/// 2026, decisions 7 and 8): a book imported with a Mac table keeps it, by
/// its stored value with the Mac prefix, in its row, its record, and the
/// removal marker; a book whose Mac table is gone keeps its text, and a
/// rebuild that needs the table fails by name and keeps the old content.md;
/// and an import or export naming a Mac table that is gone is refused by
/// name, never read with another table.
///
/// The tests of a gone table use a stored value no Mac has. The round trip
/// with this Mac's French table skips, saying why, on a Mac that lacks it.
/// Every import goes into the hosted tests' library, restored after each
/// test; nothing touches the real preferences store or plays sound.
final class MacBrailleTableBookTests: XCTestCase {
    /// The hosted test root's library index, put back after each test.
    private var sandbox: LibraryIndexSandbox?

    /// This Mac's contracted French table, and a sentence in French.
    private let french = "mac:fr-bfu-g2.ctb"
    private let sentence = "Le chat est noir."

    /// A Mac table's stored value no Mac has, as after a macOS update
    /// removed the table.
    private let gone = "mac:no-such-table-on-any-mac.ctb"

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Optional: tear-down also runs when set-up failed partway.
        sandbox?.restore()
    }

    // MARK: - Helpers

    /// The text lines `book` shows a reader, trimmed, without blank lines.
    private func lines(of book: Book) throws -> [String] {
        allText(of: try openedContent(of: book))
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - A Book Keeps Its Mac Table

    /// A BRF written with this Mac's French table, as Export writes one,
    /// imports with that table as the setting: the book keeps the table's
    /// stored value in its row and its record, and reads the French sentence
    /// back.
    func testABookOfThisMacsFrenchTableKeepsIt() throws {
        try XCTSkipIf(BrailleTableCatalog.table(withID: french) == nil,
                      "This Mac does not offer its French contracted table (\(BrailleTableCatalog.macTablesFolder.path))")
        let folder = try makeSandboxDirectory("MacBrailleBook")
        let brf = try BrailleDocumentWriter.brf(
            of: [.paragraph(text: sentence)], options: BrailleExportOptions(table: french), workingIn: folder
        )
        let url = folder.appendingPathComponent("Le chat.brf")
        try brf.write(to: url)

        let book = try BraillePreferences.$tableForImports.withValue(french) { try importedForTest(url).book }

        XCTAssertEqual(book.format, .braille)
        XCTAssertEqual(book.brailleTable, french)
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).metadata.brailleTable, french)
        XCTAssertEqual(try lines(of: book), [sentence])
    }

    /// The removal marker carries a Mac table's stored value as it is, and
    /// the Mac's liblouis version the book was read with (review R2), so a
    /// book added back keeps both.
    func testTheRemovalMarkerCarriesAMacTable() throws {
        let package = try makeSandboxDirectory("MacBrailleMarker")
        let book = Book(
            title: "Le chat", format: .braille, filePath: package.appendingPathComponent("Le chat.brf").path,
            md5Hash: "mac-braille-marker", brailleTable: french, brailleTableVersion: "3.34.0"
        )
        try RemovedFromLibraryMarker(book: book).write(into: package)
        let marker = try RemovedFromLibraryMarker.read(in: package)
        XCTAssertEqual(marker.brailleTable, french)
        XCTAssertEqual(marker.brailleTableVersion, "3.34.0")
        // The record keeps it too, and a row made from the record has it.
        XCTAssertEqual(book.makeBookInfo().metadata.brailleTableVersion, "3.34.0")
    }

    // MARK: - A Mac Table That Changed (review R2)

    /// A book of one of this Mac's tables records the Mac's liblouis
    /// version, in its row and its record; a book of a bundled table records
    /// none.
    func testABookRecordsTheMacsLiblouisVersion() throws {
        let bundled = try BraillePreferences.$tableForImports.withValue("en-ueb-g2.ctb") {
            try importedForTest(copyOfFormatSample("brf/grade2-short.brf")).book
        }
        XCTAssertNil(bundled.brailleTableVersion)
        XCTAssertNil(BrailleTableCatalog.versionToRecord(forTable: "en-ueb-g2.ctb"))

        try XCTSkipIf(BrailleTableCatalog.table(withID: french) == nil,
                      "This Mac does not offer its French contracted table (\(BrailleTableCatalog.macTablesFolder.path))")
        let version = try XCTUnwrap(BrailleTableCatalog.currentMacLiblouisVersion(), "this Mac's tables name no version")
        let folder = try makeSandboxDirectory("MacBrailleVersion")
        let url = folder.appendingPathComponent("Le chat.brf")
        try BrailleDocumentWriter.brf(
            of: [.paragraph(text: sentence)], options: BrailleExportOptions(table: french), workingIn: folder
        ).write(to: url)
        let book = try BraillePreferences.$tableForImports.withValue(french) { try importedForTest(url).book }
        XCTAssertEqual(book.brailleTableVersion, version)
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).metadata.brailleTableVersion, version)
    }

    /// A book read with one of this Mac's tables under one liblouis version
    /// keeps its text when the Mac's tables change: with a fixture whose
    /// version goes from 3.34.0 to 3.35.0, the same version passes, and the
    /// new one refuses the cache's rebuild and the content analysis's
    /// reading by name, leaving the old content.md. Tables that name no
    /// version refuse it too; a bundled table, and a book that recorded no
    /// version, are never refused.
    func testARebuildRefusesAChangedMacTableAndKeepsTheText() throws {
        let copy = try copyOfFormatSample("brf/grade2-short.brf")
        var book = try BraillePreferences.$tableForImports.withValue("en-ueb-g2.ctb") { try importedForTest(copy).book }
        let before = try lines(of: book)
        book.brailleTable = french
        book.brailleTableVersion = "3.34.0"

        let fixture = try makeSandboxDirectory("MacBrailleChangedTables").appendingPathComponent("Tables.plist")
        func setVersion(_ version: String) throws {
            try PropertyListSerialization.data(fromPropertyList: ["OpenSourceVersion": version], format: .xml, options: 0)
                .write(to: fixture)
        }
        try setVersion("3.34.0")
        try BrailleTableCatalog.$fixtureMacPropertyList.withValue(fixture) {
            XCTAssertNoThrow(try BrailleBookReader.requireUnchangedTable(french, recordedVersion: "3.34.0"))
            try setVersion("3.35.0")
            let changed = BrailleTranslator.Failure.changedTable(french, then: "3.34.0", now: "3.35.0")
            XCTAssertThrowsError(try MarkdownCacheService.generateReportedCacheContent(for: book)) {
                XCTAssertEqual($0 as? BrailleTranslator.Failure, changed)
            }
            XCTAssertThrowsError(try BookParser.parse(
                url: URL(fileURLWithPath: book.filePath), format: .braille,
                brailleTable: book.brailleTable, brailleTableVersion: book.brailleTableVersion
            )) {
                XCTAssertEqual($0 as? BrailleTranslator.Failure, changed)
            }
            XCTAssertEqual(
                changed.errorDescription,
                "This Mac's braille table \u{201C}\(french)\u{201D} has changed since the book was read with it, "
                    + "from liblouis 3.34.0 to 3.35.0, so TextMouth keeps the book's text as it was."
            )
            XCTAssertNoThrow(try BrailleBookReader.requireUnchangedTable("en-ueb-g2.ctb", recordedVersion: "3.34.0"))
            XCTAssertNoThrow(try BrailleBookReader.requireUnchangedTable(french, recordedVersion: nil))
        }
        XCTAssertEqual(try lines(of: book), before)

        // Tables that no longer name a version may have changed: refused.
        try BrailleTableCatalog.$fixtureMacPropertyList.withValue(fixture.deletingLastPathComponent().appendingPathComponent("none.plist")) {
            XCTAssertThrowsError(try BrailleBookReader.requireUnchangedTable(french, recordedVersion: "3.34.0")) {
                XCTAssertEqual(
                    ($0 as? LocalizedError)?.errorDescription,
                    "This Mac's braille table \u{201C}\(french)\u{201D} may have changed since the book was read with "
                        + "liblouis 3.34.0, so TextMouth keeps the book's text as it was."
                )
            }
        }
    }

    // MARK: - A Mac Table That Is Gone

    /// A book whose Mac table is gone keeps its text: a rebuild that needs
    /// the table fails by its stored value and leaves the old content.md,
    /// and Book Info names the table by that value.
    func testABookWhoseMacTableIsGoneKeepsItsText() throws {
        let copy = try copyOfFormatSample("brf/grade2-short.brf")
        var book = try BraillePreferences.$tableForImports.withValue("en-ueb-g2.ctb") { try importedForTest(copy).book }
        let before = try lines(of: book)
        XCTAssertFalse(before.isEmpty)
        book.brailleTable = gone

        XCTAssertThrowsError(try MarkdownCacheService.generateReportedCacheContent(for: book)) {
            XCTAssertEqual($0 as? BrailleTranslator.Failure, .unknownTable(gone))
        }

        XCTAssertEqual(try lines(of: book), before)
        XCTAssertEqual(book.brailleCodeDescription, gone)
    }

    /// An import whose setting names a Mac table that is gone is refused by
    /// name, never read with another table, and leaves nothing behind.
    func testAnImportWithAGoneMacTableIsRefusedByName() throws {
        let copy = try copyOfFormatSample("brf/grade2-short.brf")
        let folderPath = "Mac Braille Import \(UUID().uuidString.prefix(8))"
        defer {
            try? FileManager.default.removeItem(at: TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true))
        }
        try BraillePreferences.$tableForImports.withValue(gone) {
            XCTAssertThrowsError(try FileImportService.importFileWithReport(from: copy, toFolder: folderPath)) {
                XCTAssertEqual(
                    $0.localizedDescription,
                    "Could not import \u{201C}grade2-short.brf\u{201D}. Reading its text failed: "
                        + "TextMouth has no braille table named \u{201C}\(gone)\u{201D}."
                )
            }
        }
        let folder = TextMouthPaths.libraryDir.appendingPathComponent(folderPath, isDirectory: true)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [], [])
    }

    // MARK: - Export's Options (review R4)

    /// Export's options start from the default table, and say so, when the
    /// Braille setting names one of this Mac's tables that this Mac cannot
    /// use: one no Mac has, or one its check refused this session. A usable
    /// setting is kept, and choosing another table forgets the replacement.
    func testExportStartsFromTheDefaultWhenTheSettingsMacTableCannotBeUsed() throws {
        BraillePreferences.$tableForImports.withValue(gone) {
            let options = BrailleExportOptions.standard()
            XCTAssertEqual(options.table, BrailleTableCatalog.defaultTableID)
            XCTAssertEqual(options.replacedTable, gone)
        }
        BraillePreferences.$tableForImports.withValue("en-us-g1.ctb") {
            XCTAssertEqual(BrailleExportOptions.standard(), BrailleExportOptions(table: "en-us-g1.ctb"))
        }
        if let offered = BrailleTableCatalog.offeredTables.first(where: { $0.source == .mac })?.id {
            let verdicts = MacBrailleTableCheck.Verdicts()
            _ = verdicts.verdict(for: offered) { .refused(.doesNotLoad) }
            MacBrailleTableCheck.$verdicts.withValue(verdicts) {
                BraillePreferences.$tableForImports.withValue(offered) {
                    XCTAssertEqual(BrailleExportOptions.standard().replacedTable, offered)
                }
            }
            BraillePreferences.$tableForImports.withValue(offered) {
                XCTAssertEqual(BrailleExportOptions.standard(), BrailleExportOptions(table: offered), "a table not yet checked is kept")
            }
        }
        var options = BrailleExportOptions(table: BrailleTableCatalog.defaultTableID, replacedTable: gone)
        options.table = "en-us-g1.ctb"
        XCTAssertNil(options.replacedTable)
        XCTAssertEqual(
            BrailleExportWording.startsFromDefault(replacing: gone),
            "TextMouth can't use the braille table chosen in Settings, \u{201C}\(gone)\u{201D}, so this export starts from "
                + "Unified English Braille, contracted (Grade 2)."
        )
    }

    // MARK: - An Export During a Check (review R5)

    /// An export started while a table just chosen in the pop-ups is still
    /// being checked waits for that check before it reads its options, and
    /// the checks are counted as running meanwhile, which the Export
    /// button's hint tells of.
    @MainActor
    func testAnExportWaitsForTheCheckOfATableJustChosen() async {
        /// Whether the stand-in check has ended.
        final class Ended {
            var value = false
        }
        let ended = Ended()
        let checks = BrailleTableChoiceChecks.shared
        checks.run {
            try? await Task.sleep(nanoseconds: 300_000_000)
            ended.value = true
        }
        XCTAssertTrue(checks.isChecking)
        let model = BookExportModel(books: [])
        _ = await model.export()
        XCTAssertTrue(ended.value, "the export did not wait for the check")
        XCTAssertFalse(checks.isChecking)
    }

    // MARK: - config.json

    /// config.json may name one of this Mac's tables, which is taken by its
    /// stored value without reading this Mac's tables (review R3): one no
    /// Mac has is kept too, and refused by name when an import uses it; a
    /// malformed one leaves the setting alone.
    @MainActor
    func testConfigJSONNamesAMacTable() throws {
        func decoded(_ value: String) throws -> String {
            try JSONDecoder().decode(ConfigService.AppConfig.self, from: Data(#"{"brailleTable": "\#(value)"}"#.utf8)).brailleTable
        }
        XCTAssertEqual(try decoded(gone), gone)
        XCTAssertEqual(try decoded("mac:../escape.ctb"), "")
        let defaults = try isolatedDefaults()
        let service = ConfigService(fileURL: try makeConfigFileURL())
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(), initializeServices: false, userDefaults: defaults, configService: service
        )
        var edit = service.config
        edit.brailleTable = "mac:../escape.ctb"
        settings.applyConfigChanges(edit)
        XCTAssertEqual(settings.brailleTable, "en-ueb-g2.ctb")
        edit.brailleTable = gone
        settings.applyConfigChanges(edit)
        XCTAssertEqual(settings.brailleTable, gone)
        XCTAssertEqual(BraillePreferences.table.read(from: defaults), gone)

        let spanish = "mac:es.tbl"
        try XCTSkipIf(BrailleTableCatalog.table(withID: spanish) == nil,
                      "This Mac does not offer its Spanish table (\(BrailleTableCatalog.macTablesFolder.path))")
        XCTAssertEqual(try decoded(spanish), spanish)
        edit.brailleTable = spanish
        settings.applyConfigChanges(edit)
        XCTAssertEqual(settings.brailleTable, spanish)
        XCTAssertEqual(BraillePreferences.table.read(from: defaults), spanish)
    }

    /// A table that says six dots but writes a character with eight, as the
    /// Mac's Swedish table writes «, fails the book's export naming the
    /// character, in a BRF and a PEF alike, rather than dropping the extra
    /// dots (review R1); text without it exports.
    func testAnEightDotCellFailsTheExportNamingTheCharacter() throws {
        let swedish = "mac:sv-g1.ctb"
        try XCTSkipIf(BrailleTableCatalog.table(withID: swedish) == nil,
                      "This Mac does not offer its Swedish table (\(BrailleTableCatalog.macTablesFolder.path))")
        let folder = try makeSandboxDirectory("MacBrailleEightDots")
        let book = ExportBookDetails(title: "Bok", author: nil, language: "sv")
        let quoted = try ExportDocumentWalker.document(fromMarkdown: "Han sa \u{00AB}hej\u{00BB} till dem.\n", book: book)
        let options = BrailleExportOptions(table: swedish)
        let sentence = "The braille table writes \u{201C}\u{00AB}\u{201D} as an eight-dot cell, "
            + "and TextMouth writes BRF and PEF files in six-dot braille only."
        try MacBrailleTableCheck.$verdicts.withValue(MacBrailleTableCheck.Verdicts()) {
            XCTAssertThrowsError(try BRFExportWriter().write(
                quoted, options: options, to: folder.appendingPathComponent("bok.brf"), cancellation: BookExportCancellation()
            )) {
                XCTAssertEqual($0 as? TextExportError, TextExportError(sentence))
            }
            XCTAssertThrowsError(try PEFExportWriter().write(
                quoted, options: options, to: folder.appendingPathComponent("bok.pef"), cancellation: BookExportCancellation()
            )) {
                XCTAssertEqual($0 as? TextExportError, TextExportError(sentence))
            }
            let plain = try ExportDocumentWalker.document(fromMarkdown: "Han sa hej till dem.\n", book: book)
            XCTAssertNoThrow(try BRFExportWriter().write(
                plain, options: options, to: folder.appendingPathComponent("plain.brf"), cancellation: BookExportCancellation()
            ))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["plain.brf"])
    }

    /// An export with a Mac table that is gone is refused by name.
    func testAnExportWithAGoneMacTableIsRefusedByName() throws {
        let folder = try makeSandboxDirectory("MacBrailleExport")
        XCTAssertThrowsError(try BrailleDocumentWriter.brf(
            of: [.paragraph(text: "Words.")], options: BrailleExportOptions(table: gone), workingIn: folder
        )) {
            XCTAssertEqual(($0 as? LocalizedError)?.errorDescription, "TextMouth has no braille table named \u{201C}\(gone)\u{201D}.")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }
}
