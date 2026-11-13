import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Book Information's Braille Code pop-up (FMT21), which follows the Braille
/// File Characters pop-up (`BrailleFileCodeBookInfoTests`) and the Text
/// Encoding pop-up (`TextEncodingPopUpTests`) and shares their view, their
/// alert, and their checks: its items, with the book's table selected; a new
/// code asked about first, Cancel leaving everything, a busy book refused,
/// and Read Again reading the book again; its label, value, and hint, read
/// from the hosted sheet; and every new word, exactly.
@MainActor
final class BrailleCodeBookInfoTests: CloudMaintenanceTestCase {

    // MARK: - Fixtures

    /// The grade 1 BRF sample, a North American Braille ASCII file.
    private static let sample = "brf/pride-and-prejudice-ch1-grade1.brf"
    /// The table the sample is written in: uncontracted UEB.
    private static let grade1 = "en-ueb-g1.ctb"
    /// Contracted UEB, the table a book that stores none is read with.
    private static let grade2 = "en-ueb-g2.ctb"
    /// A Mac table no Mac has, as one a macOS update removed.
    private static let goneTable = "mac:no-such-table-for-this-test.ctb"
    /// What the pop-up says of the two bundled tables.
    private static let grade1Name = "Unified English Braille, uncontracted (Grade 1)"
    private static let grade2Name = "Unified English Braille, contracted (Grade 2)"

    /// The bundled table with the stored value `id`.
    private func table(_ id: String) throws -> BrailleTable {
        try XCTUnwrap(BrailleTableCatalog.table(withID: id), id)
    }

    /// A braille book titled `title` whose row and package record hold
    /// `table`, nil for none, in a package of its own in this test's folder,
    /// its file holding a line of North American Braille ASCII, with no text
    /// cache: a book whose file nothing here reads.
    private func makeBrailleBook(_ title: String, table: String?, fileExtension: String = "brf") throws -> Book {
        let packageName = "\(title)-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let file = package.appendingPathComponent("\(title).\(fileExtension)")
        try Data(",LEDG] ,PAGE #A\n".utf8).write(to: file)
        let book = Book(
            title: title, format: .braille, filePath: file.path, md5Hash: UUID().uuidString, folderPath: folderPath,
            tmbDirectoryName: packageName, brailleTable: table, brailleFileCode: nil
        )
        try book.makeBookInfo().save(to: book.tmbDirectory)
        return book
    }

    /// The grade 1 sample imported with the contracted table as the Braille
    /// setting's, never the user's settings, so it is read as other words
    /// until the listener reads it again with the uncontracted one. Titled
    /// `title`, with a suffix of its own, in its row and its record.
    private func importedSample(title: String) throws -> Book {
        let copy = try copyOfFormatSample(Self.sample)
        var book = try BraillePreferences.$tableForImports.withValue(Self.grade2) {
            try BraillePreferences.$fileCodeForImports.withValue("ascii-na") {
                try importedForTest(copy).book
            }
        }
        book.title = "\(title) \(UUID().uuidString.prefix(8))"
        try book.saveBookInfoThrowing()
        return book
    }

    // MARK: - The Items and the Selection

    /// Before the tables are listed the pop-up holds the book's own table
    /// alone, named as the book's row names it, and takes no choice; once
    /// listed it holds every table TextMouth offers, in the catalog's order,
    /// with the book's selected, and takes one.
    func testThePopUpListsTheOfferedTablesOnceLoaded() async throws {
        let book = try makeBrailleBook("Ledger", table: Self.grade1)
        let model = BrailleCodeChoiceModel(book: book, library: makeModel(with: [book]))

        XCTAssertEqual(model.items, [.table(Self.grade1)])
        XCTAssertEqual(model.name(of: model.selection), Self.grade1Name)
        XCTAssertFalse(model.isEnabled, "no choice before the tables are listed")
        await model.choose(.table(Self.grade2))
        XCTAssertNil(model.pending, "a choice before the tables are listed asks nothing")

        await model.load()

        XCTAssertEqual(model.items, BrailleTableCatalog.offeredTables.map { .table($0.id) })
        XCTAssertTrue(model.items.contains(.table(Self.grade1)))
        XCTAssertEqual(model.selection, .table(Self.grade1))
        XCTAssertEqual(model.name(of: model.selection), Self.grade1Name)
        XCTAssertEqual(model.name(of: .table(Self.grade2)), Self.grade2Name)
        XCTAssertTrue(model.isEnabled)
        await model.choose(.table(Self.grade1))
        XCTAssertNil(model.pending, "the table already selected asks nothing")
    }

    /// A book that stores no table is read with the default, which the pop-up
    /// selects and names as the row does; a PEF book is offered the tables
    /// as a BRF is.
    func testABookThatStoresNoTableShowsTheDefaultSelected() async throws {
        let book = try makeBrailleBook("Almanac", table: nil, fileExtension: "pef")
        XCTAssertTrue(book.offersBrailleTableChoice)
        let model = BrailleCodeChoiceModel(book: book, library: makeModel(with: [book]))

        await model.load()

        XCTAssertEqual(model.selection, .table(BrailleTableCatalog.defaultTableID))
        XCTAssertEqual(model.name(of: model.selection), Self.grade2Name)
        XCTAssertEqual(model.name(of: model.selection), book.brailleCodeDescription, "the pop-up and Speak Info never differ")
    }

    /// A table this Mac does not offer is listed last, selected, and named by
    /// its stored value, as the book's row and Speak Info name it; choosing it
    /// changes nothing, and nothing is asked.
    func testATableThisMacDoesNotOfferIsListedLastAndChoosingItChangesNothing() async throws {
        let book = try makeBrailleBook("Codex", table: Self.goneTable)
        let model = BrailleCodeChoiceModel(book: book, library: makeModel(with: [book]))
        let gone = BrailleCodeChoiceModel.Item.unavailable(Self.goneTable)

        await model.load()

        XCTAssertEqual(model.items, BrailleTableCatalog.offeredTables.map { .table($0.id) } + [gone])
        XCTAssertEqual(model.selection, gone)
        XCTAssertEqual(model.name(of: gone), Self.goneTable)
        XCTAssertEqual(model.name(of: gone), book.brailleCodeDescription)
        await model.choose(gone)
        XCTAssertNil(model.pending)
        XCTAssertNil(model.failureMessage)
        XCTAssertEqual(model.selection, gone)
    }

    // MARK: - Choosing

    /// Another table is asked about first, with what the confirmation says;
    /// Cancel leaves the pop-up, the row, and the record as they were.
    func testANewTableIsAskedAboutAndCancelLeavesEverything() async throws {
        let book = try makeBrailleBook("Gulls", table: Self.grade1)
        let library = makeModel(with: [book])
        let model = BrailleCodeChoiceModel(book: book, library: library)
        await model.load()
        let recordBefore = try Data(contentsOf: TextMouthPaths.bookInfoPath(in: book.tmbDirectory))
        let contracted = try table(Self.grade2)

        await model.choose(.table(Self.grade2))

        let pending = try XCTUnwrap(model.pending)
        XCTAssertEqual(pending, BrailleCodeChoiceModel.Confirmation(option: contracted, keepsText: false, stopsEditing: false))
        XCTAssertEqual(model.confirmTitle(for: contracted), "Read “Gulls” again as \(Self.grade2Name)?")
        XCTAssertEqual(model.confirmMessage(for: pending), BrailleCodeWording.confirmMessage(keepsText: false, stopsEditing: false))
        XCTAssertNil(model.failureMessage)
        XCTAssertEqual(model.selection, .table(Self.grade1), "the pop-up shows what it showed while it asks")

        model.cancel()

        XCTAssertNil(model.pending)
        XCTAssertEqual(model.selection, .table(Self.grade1))
        XCTAssertEqual(library.bookByID(book.id), book)
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.bookInfoPath(in: book.tmbDirectory)), recordBefore)
    }

    /// The confirmation says an edit of the text is kept whenever one will
    /// be, here a save no edit took, and that Edit Text stops, for a book
    /// being edited, as the other re-reads' do.
    func testTheConfirmationSaysAnEditIsKeptAndEditTextStops() async throws {
        let book = try importedSample(title: "Dock")
        XCTAssertNotNil(book.textCacheFingerprint, "the import must vouch for the text it wrote, or no save reads as another's")
        let library = makeModel(with: [book])
        let model = BrailleCodeChoiceModel(book: book, library: library)
        await model.load()
        try Data("Saved over by hand.\n".utf8).write(to: MarkdownCacheService.cacheURL(for: book))
        let sessions = BookTextEditSessions()
        library.textEditSessions = sessions
        let baseline = try BookTextEditSessions.baseline(of: book, access: .live).get()
        sessions.begin(book.id, BookTextEditSessions.Session(baseline: baseline, report: { _, _ in }))
        defer { sessions.end(book.id) }

        await model.choose(.table(Self.grade1))

        let pending = try XCTUnwrap(model.pending)
        XCTAssertEqual(pending.keepsText, true)
        XCTAssertEqual(pending.stopsEditing, true)
        XCTAssertTrue(
            model.confirmMessage(for: pending).hasSuffix(TextEncodingWording.keptTextNote + " " + TextEncodingWording.stopsEditingNote),
            model.confirmMessage(for: pending)
        )
    }

    /// A busy book, and one gone from the library, are refused before the
    /// confirmation, which asks nothing: the sheet shows why, and VoiceOver
    /// hears it. A new choice clears the last refusal. The pop-up shows what
    /// it showed.
    func testABusyOrGoneBookIsRefusedAndAskedNothing() async throws {
        let book = try makeBrailleBook("Pier", table: Self.grade1)
        let library = makeModel(with: [book])
        let model = BrailleCodeChoiceModel(book: book, library: library)
        await model.load()
        library.textRereads = TextRereads()
        defer { library.booksBeingReadAgain = [] }

        let announced = await announcements {
            library.textExtraction.begin("Updating text cache", total: 1)
            await model.choose(.table(Self.grade2))
            library.textExtraction.end()
            XCTAssertEqual(model.failureMessage, TextEncodingWording.extractionRefusal)
        }

        XCTAssertNil(model.pending, "a busy book is not asked about")
        XCTAssertEqual(announced, [TextEncodingWording.extractionRefusal])
        XCTAssertEqual(model.selection, .table(Self.grade1))

        await model.choose(.table(Self.grade2))
        XCTAssertNil(model.failureMessage, "a new choice clears the last refusal")
        XCTAssertNotNil(model.pending)
        model.cancel()

        // The book leaves the library while its sheet is open.
        library.library = Library(books: [])
        await model.choose(.table(Self.grade2))
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.failureMessage, "The book is no longer in the library, so it was not read again.")
    }

    // MARK: - Reading Again

    /// Read Again reads a book imported with the contracted table again with
    /// the uncontracted one: the pop-up then shows it, the row and the record
    /// hold it, and VoiceOver hears the code's name. The pop-up is not
    /// working afterwards, and takes another choice.
    func testReadAgainReadsTheBookAgainAndThePopUpShowsTheTable() async throws {
        let book = try importedSample(title: "Ledger")
        XCTAssertEqual(book.brailleTable, Self.grade2, "the book must be read with the other table, or this proves nothing")
        let library = makeModel(with: [book])
        let model = BrailleCodeChoiceModel(book: book, library: library)
        await model.load()
        XCTAssertEqual(model.selection, .table(Self.grade2))
        let uncontracted = try table(Self.grade1)

        await model.choose(.table(Self.grade1))
        XCTAssertNotNil(model.pending)
        let announced = await announcements {
            await model.confirm(uncontracted)
        }

        XCTAssertNil(model.pending)
        XCTAssertNil(model.failureMessage)
        XCTAssertFalse(model.isWorking)
        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(model.selection, .table(Self.grade1))
        XCTAssertEqual(model.name(of: model.selection), Self.grade1Name)
        XCTAssertEqual(library.bookByID(book.id)?.brailleTable, Self.grade1)
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).metadata.brailleTable, Self.grade1)
        XCTAssertEqual(announced, ["“\(book.title)” is now read as \(Self.grade1Name)."])
    }

    /// A reading that fails after the confirmation, here with a table that is
    /// not there, is shown and said in the re-read's own words, and the
    /// pop-up shows what it showed.
    func testAFailedReadingIsShownAndThePopUpKeepsTheOldTable() async throws {
        let book = try importedSample(title: "Codex")
        let library = makeModel(with: [book])
        let model = BrailleCodeChoiceModel(book: book, library: library)
        await model.load()
        let gone = BrailleTable(
            id: Self.goneTable, displayName: "Gone", indexName: nil, language: "en", system: "", contraction: .unstated, grade: nil
        )

        let announced = await announcements {
            await model.confirm(gone)
        }

        let failure = try XCTUnwrap(model.failureMessage)
        XCTAssertTrue(failure.hasPrefix("TextMouth couldn't read “\(book.title)” again, so it left the book as it was"), failure)
        XCTAssertEqual(announced, [failure])
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.selection, .table(Self.grade2))
        XCTAssertEqual(library.bookByID(book.id)?.brailleTable, Self.grade2)
    }

    // MARK: - Words

    /// Every word the pop-up adds, exactly.
    func testTheWords() {
        XCTAssertEqual(BrailleCodeWording.bookInfoLabel, "Braille Code")
        XCTAssertEqual(BrailleCodeWording.popUpHint, "Choose another braille code to read the book's file again with it.")
        XCTAssertEqual(
            BrailleCodeWording.confirmTitle(bookTitle: "Ledger", codeName: Self.grade1Name),
            "Read “Ledger” again as Unified English Braille, uncontracted (Grade 1)?"
        )
        XCTAssertEqual(
            BrailleCodeWording.translatedAgainNote,
            "The braille is translated to print again with this code. "
                + "Nothing checks that it is the right choice. If words read wrongly, choose another."
        )
        XCTAssertEqual(
            BrailleCodeWording.confirmMessage(keepsText: false, stopsEditing: false),
            BrailleCodeWording.translatedAgainNote + " " + TextEncodingWording.replacedNote + " " + BrailleFileCodeWording.placesNote
        )
        XCTAssertEqual(
            BrailleCodeWording.confirmMessage(keepsText: true, stopsEditing: true),
            BrailleCodeWording.confirmMessage(keepsText: false, stopsEditing: false)
                + " " + TextEncodingWording.keptTextNote + " " + TextEncodingWording.stopsEditingNote
        )
    }

    // MARK: - VoiceOver

    /// The hosted sheet of a braille book has a pop-up labelled "Braille
    /// Code", its value (its selected item's title, which VoiceOver speaks
    /// before the label) the book's code, and its hint saying what it does;
    /// it has no plain "Braille Code" row beside it. A PEF has the pop-up too.
    func testThePopUpIsLabelledAndValuedForVoiceOver() throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        for fileExtension in ["brf", "pef"] {
            let book = try makeBrailleBook("Wharf", table: Self.grade1, fileExtension: fileExtension)
            let sheet = LibraryBookInfoSheet(book: book, libraryViewModel: makeModel(with: [book]))
                .frame(width: 400, height: 470)
            try withHostedView(sheet, size: NSSize(width: 400, height: 470), until: { [self] in
                accessibleControls(in: $0).contains { $0.label == BrailleCodeWording.bookInfoLabel }
            }) { hosting in
                let controls = accessibleControls(in: hosting)
                let control = try control(labelled: "Braille Code", in: controls)
                XCTAssertEqual(control.role, .popUpButton, fileExtension)
                XCTAssertEqual(control.element.accessibilityValue() as? String, Self.grade1Name, fileExtension)
                XCTAssertEqual(control.hint, "Choose another braille code to read the book's file again with it.", fileExtension)
                XCTAssertEqual(
                    controls.filter { $0.label == BrailleCodeWording.bookInfoLabel }.count, 1, "the pop-up replaces the row"
                )
            }
        }
    }
}
