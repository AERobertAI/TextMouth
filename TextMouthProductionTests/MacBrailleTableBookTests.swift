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

    /// The removal marker carries a Mac table's stored value as it is, so a
    /// book added back keeps it.
    func testTheRemovalMarkerCarriesAMacTable() throws {
        let package = try makeSandboxDirectory("MacBrailleMarker")
        let book = Book(
            title: "Le chat", format: .braille, filePath: package.appendingPathComponent("Le chat.brf").path,
            md5Hash: "mac-braille-marker", brailleTable: french
        )
        try RemovedFromLibraryMarker(book: book).write(into: package)
        XCTAssertEqual(try RemovedFromLibraryMarker.read(in: package).brailleTable, french)
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
