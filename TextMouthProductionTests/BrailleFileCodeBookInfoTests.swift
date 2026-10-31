import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Book Information's Braille File Characters pop-up (braillecodes,
/// BRAILLE-CODES-RESEARCH-2026-10-25.md, section 8.3), which follows the Text
/// Encoding pop-up (`TextEncodingPopUpTests`) and shares its view, its alert,
/// and its checks: its items, with the book's code selected as its record
/// keeps it; a new code asked about first, Cancel leaving everything, a busy
/// book refused, and Read Again reading the book again; its label, value,
/// hint, and items, read from the hosted sheet; Speak Full Info's sentence;
/// and every new word, exactly.
@MainActor
final class BrailleFileCodeBookInfoTests: CloudMaintenanceTestCase {

    // MARK: - Fixtures

    /// The grade 1 BRF sample, a North American Braille ASCII file.
    private static let sample = "brf/pride-and-prejudice-ch1-grade1.brf"
    /// The table the sample is written in: uncontracted UEB.
    private static let table = "en-ueb-g1.ctb"
    /// The id of a code no TextMouth knows yet, as a later TextMouth might
    /// record one.
    private static let unknownCode = "ascii-braillo-no-047-01"
    /// Every code this TextMouth reads, as the pop-up lists them.
    private static let codeItems = BrailleFileCode.all.map(BrailleFileCodeChoiceModel.Item.code)
    /// Every code's name, in the catalog's order, as the pop-up lists them.
    private static let codeNames = [
        "North American Braille ASCII", "Eurobraille, six-dot (German-speaking countries)", "Unicode braille patterns",
    ]

    /// A braille book titled `title` whose row and package record hold
    /// `code`, nil for none, in a package of its own in this test's folder,
    /// its file named with `fileExtension` and holding a line of North
    /// American Braille ASCII, with no text cache: a book whose file nothing
    /// here reads.
    private func makeBrailleBook(_ title: String, code: String?, fileExtension: String = "brf") throws -> Book {
        let packageName = "\(title)-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let file = package.appendingPathComponent("\(title).\(fileExtension)")
        try Data(",LEDG] ,PAGE #A\n".utf8).write(to: file)
        let book = Book(
            title: title, format: .braille, filePath: file.path, md5Hash: UUID().uuidString, folderPath: folderPath,
            tmbDirectoryName: packageName, brailleTable: Self.table, brailleFileCode: code
        )
        try book.makeBookInfo().save(to: book.tmbDirectory)
        return book
    }

    /// The grade 1 sample written in `code`, imported with `settingCode` as
    /// the Braille setting's file code and with the sample's table, never the
    /// user's settings, as `BrailleFileCodeRereadTests` imports one: read
    /// wrongly when the two codes differ. Titled `title`, with a suffix of
    /// its own, in its row and its record.
    private func importedSample(writtenIn code: BrailleFileCode, settingCode: BrailleFileCode, title: String) throws -> Book {
        let copy = try copyOfBrailleSample(Self.sample, writtenIn: code)
        var book = try BraillePreferences.$tableForImports.withValue(Self.table) {
            try BraillePreferences.$fileCodeForImports.withValue(settingCode.id) {
                try importedForTest(copy).book
            }
        }
        book.title = "\(title) \(UUID().uuidString.prefix(8))"
        try book.saveBookInfoThrowing()
        return book
    }

    /// The code the record in `book`'s package keeps.
    private func recordedCode(of book: Book) throws -> String? {
        try BookInfo.load(from: book.tmbDirectory).metadata.brailleFileCode
    }

    // MARK: - The Items and the Selection

    /// A BRF book that records no code lists the three codes, plainly named,
    /// with North American Braille ASCII selected, which a pop-up button's
    /// value is; a record that names none leaves it so; the code already
    /// selected asks nothing.
    func testABookThatRecordsNoCodeShowsNorthAmericanAmongTheCodes() async throws {
        let book = try makeBrailleBook("Ledger", code: nil)
        let model = BrailleFileCodeChoiceModel(book: book, library: makeModel(with: [book]))

        XCTAssertEqual(model.items, Self.codeItems)
        XCTAssertEqual(model.items.map(model.name(of:)), Self.codeNames)
        XCTAssertEqual(model.selection, .code(.northAmerican))
        XCTAssertEqual(model.name(of: model.selection), "North American Braille ASCII")
        XCTAssertTrue(model.isEnabled)

        await model.load()
        XCTAssertNil(model.storedCode)
        XCTAssertEqual(model.selection, .code(.northAmerican))
        await model.choose(.code(.northAmerican))
        XCTAssertNil(model.pending, "the code already selected asks nothing")
    }

    /// A Eurobraille book shows Eurobraille selected among the same codes,
    /// and a BRL book is offered the codes as a BRF is.
    func testAEurobrailleBookShowsEurobrailleSelected() throws {
        let book = try makeBrailleBook("Almanac", code: "ascii-eurobraille", fileExtension: "brl")
        XCTAssertTrue(book.offersBrailleFileCodeChoice)
        let model = BrailleFileCodeChoiceModel(book: book, library: makeModel(with: [book]))

        XCTAssertEqual(model.items, Self.codeItems)
        XCTAssertEqual(model.selection, .code(.eurobraille))
        XCTAssertEqual(model.name(of: model.selection), "Eurobraille, six-dot (German-speaking countries)")
    }

    /// A row that lags behind its record, as one does between a re-read's
    /// commit and the row's update, shows the row's code at once and the
    /// record's once `load()` has read it, since the record's stands.
    func testARowLaggingBehindItsRecordShowsTheRecordsCodeOnceLoaded() async throws {
        let recorded = try makeBrailleBook("Tide Tables", code: "ascii-eurobraille")
        var row = recorded
        row.brailleFileCode = "ascii-na"
        let model = BrailleFileCodeChoiceModel(book: row, library: makeModel(with: [row]))
        XCTAssertEqual(model.selection, .code(.northAmerican), "the row's code, at once")

        await model.load()

        XCTAssertEqual(model.storedCode, "ascii-eurobraille")
        XCTAssertEqual(model.selection, .code(.eurobraille))
        XCTAssertEqual(model.name(of: model.selection), "Eurobraille, six-dot (German-speaking countries)")
    }

    /// A code this TextMouth does not know is listed last, selected, and
    /// named as one it can't read; choosing it changes nothing, and nothing
    /// is asked.
    func testAnUnknownCodeIsListedLastAndChoosingItChangesNothing() async throws {
        let book = try makeBrailleBook("Codex", code: Self.unknownCode)
        let model = BrailleFileCodeChoiceModel(book: book, library: makeModel(with: [book]))
        let unknown = BrailleFileCodeChoiceModel.Item.unknown(Self.unknownCode)

        await model.load()
        XCTAssertEqual(model.items, Self.codeItems + [unknown])
        XCTAssertEqual(model.selection, unknown)
        XCTAssertEqual(model.name(of: unknown), "“ascii-braillo-no-047-01”, which this version of TextMouth can't read")
        XCTAssertEqual(model.items.map(model.name(of:)).last, BrailleFileCodeWording.unknownValue(Self.unknownCode))

        await model.choose(unknown)

        XCTAssertNil(model.pending)
        XCTAssertNil(model.failureMessage)
        XCTAssertEqual(model.selection, unknown)
    }

    // MARK: - Choosing

    /// Another code is asked about first, with what the confirmation says;
    /// Cancel leaves the pop-up, the row, and the record as they were.
    func testANewCodeIsAskedAboutAndCancelLeavesEverything() async throws {
        let book = try makeBrailleBook("Gulls", code: nil)
        let library = makeModel(with: [book])
        let model = BrailleFileCodeChoiceModel(book: book, library: library)
        let recordBefore = try Data(contentsOf: TextMouthPaths.bookInfoPath(in: book.tmbDirectory))

        await model.choose(.code(.eurobraille))

        let pending = try XCTUnwrap(model.pending)
        XCTAssertEqual(pending, BrailleFileCodeChoiceModel.Confirmation(option: .eurobraille, keepsText: false, stopsEditing: false))
        XCTAssertEqual(model.confirmTitle(for: .eurobraille), "Read “Gulls” again as Eurobraille, six-dot (German-speaking countries)?")
        XCTAssertEqual(model.confirmMessage(for: pending), BrailleFileCodeWording.confirmMessage(keepsText: false, stopsEditing: false))
        XCTAssertNil(model.failureMessage)
        XCTAssertEqual(model.selection, .code(.northAmerican), "the pop-up shows what it showed while it asks")

        model.cancel()

        XCTAssertNil(model.pending)
        XCTAssertEqual(model.selection, .code(.northAmerican))
        XCTAssertEqual(library.bookByID(book.id), book)
        XCTAssertEqual(try Data(contentsOf: TextMouthPaths.bookInfoPath(in: book.tmbDirectory)), recordBefore)
    }

    /// The confirmation says an edit of the text is kept whenever one will
    /// be, here a save no edit took, and that Edit Text stops, for a book
    /// being edited, as the encoding's does.
    func testTheConfirmationSaysAnEditIsKeptAndEditTextStops() async throws {
        let book = try importedSample(writtenIn: .northAmerican, settingCode: .northAmerican, title: "Dock")
        XCTAssertNotNil(book.textCacheFingerprint, "the import must vouch for the text it wrote, or no save reads as another's")
        let library = makeModel(with: [book])
        let model = BrailleFileCodeChoiceModel(book: book, library: library)
        try Data("Saved over by hand.\n".utf8).write(to: MarkdownCacheService.cacheURL(for: book))
        XCTAssertNil(book.editedText, "the save must not be an edit on record, or this proves nothing new")
        let sessions = BookTextEditSessions()
        library.textEditSessions = sessions
        let baseline = try BookTextEditSessions.baseline(of: book, access: .live).get()
        sessions.begin(book.id, BookTextEditSessions.Session(baseline: baseline, report: { _, _ in }))
        defer { sessions.end(book.id) }

        await model.choose(.code(.eurobraille))

        let pending = try XCTUnwrap(model.pending)
        XCTAssertEqual(pending, BrailleFileCodeChoiceModel.Confirmation(option: .eurobraille, keepsText: true, stopsEditing: true))
        XCTAssertEqual(model.confirmMessage(for: pending), BrailleFileCodeWording.confirmMessage(keepsText: true, stopsEditing: true))
        XCTAssertTrue(
            model.confirmMessage(for: pending).hasSuffix(TextEncodingWording.keptTextNote + " " + TextEncodingWording.stopsEditingNote),
            model.confirmMessage(for: pending)
        )
    }

    /// A busy book, and one gone from the library, are refused before the
    /// confirmation, which asks nothing: the sheet shows why, and VoiceOver
    /// hears it, in the braille re-read's own words for a re-read of the book
    /// under way. A new choice clears the last refusal. The pop-up shows
    /// what it showed.
    func testABusyOrGoneBookIsRefusedAndAskedNothing() async throws {
        let book = try makeBrailleBook("Pier", code: nil)
        let library = makeModel(with: [book])
        let model = BrailleFileCodeChoiceModel(book: book, library: library)
        // Each re-read under way in this model's own list.
        library.textRereads = TextRereads()
        defer { library.booksBeingReadAgain = [] }

        let announced = await announcements {
            library.textExtraction.begin("Updating text cache", total: 1)
            await model.choose(.code(.eurobraille))
            library.textExtraction.end()
            XCTAssertEqual(model.failureMessage, TextEncodingWording.extractionRefusal)

            library.booksBeingReadAgain = [book.id]
            await model.choose(.code(.unicode))
            library.booksBeingReadAgain = []
        }

        let rereading = "TextMouth is reading “Pier” again with other braille file characters. Try again when that finishes."
        XCTAssertNil(model.pending, "a busy book is not asked about")
        XCTAssertEqual(model.failureMessage, rereading)
        XCTAssertEqual(announced, [TextEncodingWording.extractionRefusal, rereading])
        XCTAssertEqual(model.selection, .code(.northAmerican))

        await model.choose(.code(.eurobraille))
        XCTAssertNil(model.failureMessage, "a new choice clears the last refusal")
        XCTAssertNotNil(model.pending)
        model.cancel()

        let gone = BrailleFileCodeChoiceModel(book: book, library: makeModel(with: []))
        await gone.choose(.code(.eurobraille))
        XCTAssertNil(gone.pending)
        XCTAssertEqual(gone.failureMessage, "The book is no longer in the library, so it was not read again.")
    }

    // MARK: - Reading Again

    /// Read Again reads a Eurobraille book imported as North American
    /// Braille ASCII again with Eurobraille: the pop-up then shows it, the
    /// row and the record hold it, and VoiceOver hears the code's name.
    func testReadAgainReadsTheBookAgainAndThePopUpShowsTheCode() async throws {
        let book = try importedSample(writtenIn: .eurobraille, settingCode: .northAmerican, title: "Ledger")
        XCTAssertEqual(book.brailleFileCode, "ascii-na", "the book must be read wrongly, or this proves nothing")
        let library = makeModel(with: [book])
        let model = BrailleFileCodeChoiceModel(book: book, library: library)
        XCTAssertEqual(model.selection, .code(.northAmerican))

        await model.choose(.code(.eurobraille))
        XCTAssertNotNil(model.pending)
        let announced = await announcements {
            await model.confirm(.eurobraille)
        }

        XCTAssertNil(model.pending)
        XCTAssertNil(model.failureMessage)
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.selection, .code(.eurobraille))
        XCTAssertEqual(model.name(of: model.selection), "Eurobraille, six-dot (German-speaking countries)")
        XCTAssertEqual(library.bookByID(book.id)?.brailleFileCode, "ascii-eurobraille")
        XCTAssertEqual(try recordedCode(of: book), "ascii-eurobraille")
        XCTAssertEqual(announced, ["“\(book.title)” is now read as Eurobraille, six-dot (German-speaking countries)."])
    }

    /// A file that holds a character the code chosen has no cell for is
    /// refused after the confirmation in the reader's own words, shown and
    /// said, and the pop-up shows what it showed: the sample in Unicode
    /// braille patterns, which an import picks by the file's bytes and the
    /// pop-up names plainly, chosen to be read as Eurobraille.
    func testAFileNotBrailleInTheCodeChosenIsRefusedAndShown() async throws {
        let book = try importedSample(writtenIn: .unicode, settingCode: .northAmerican, title: "Codex")
        XCTAssertEqual(book.brailleFileCode, "unicode")
        let library = makeModel(with: [book])
        let model = BrailleFileCodeChoiceModel(book: book, library: library)
        XCTAssertEqual(model.name(of: model.selection), "Unicode braille patterns")

        await model.choose(.code(.eurobraille))
        let announced = await announcements {
            await model.confirm(.eurobraille)
        }

        let refusal = "“\(book.title)” can't be read as Eurobraille, six-dot (German-speaking countries): "
            + "Line 1 holds the character U+2800, which is not Eurobraille. Nothing was changed."
        XCTAssertEqual(model.failureMessage, refusal)
        XCTAssertEqual(announced, [refusal])
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.selection, .code(.unicode))
        XCTAssertEqual(try recordedCode(of: book), "unicode")
    }

    // MARK: - VoiceOver

    /// The hosted sheet of a BRF book has a pop-up labelled "Braille File
    /// Characters", its value (its selected item's title, which VoiceOver
    /// speaks before the label) the book's code, its hint saying what it
    /// does, and its items the codes by their names; it has no Text
    /// Encoding pop-up.
    func testThePopUpIsLabelledAndValuedForVoiceOver() throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        let book = try makeBrailleBook("Wharf", code: nil)
        let sheet = LibraryBookInfoSheet(book: book, libraryViewModel: makeModel(with: [book]))
            .frame(width: 400, height: 470)
        try withHostedView(sheet, size: NSSize(width: 400, height: 470), until: { [self] in
            accessibleControls(in: $0).contains { $0.label == BrailleFileCodeWording.bookInfoLabel }
        }) { hosting in
            let controls = accessibleControls(in: hosting)
            let control = try control(labelled: "Braille File Characters", in: controls)
            XCTAssertEqual(control.role, .popUpButton)
            XCTAssertEqual(control.element.accessibilityValue() as? String, "North American Braille ASCII")
            XCTAssertEqual(control.hint, "Choose other characters to read the book's file again with them.")
            XCTAssertFalse(controls.contains { $0.label == TextEncodingWording.bookInfoLabel })
            let popUps = descendants(of: hosting, as: NSPopUpButton.self)
            XCTAssertEqual(popUps.count, 1, "the sheet shows one pop-up")
            let popUp = try XCTUnwrap(popUps.first)
            XCTAssertEqual(popUp.itemTitles, Self.codeNames)
            XCTAssertEqual(popUp.titleOfSelectedItem, "North American Braille ASCII")
        }
    }

    /// A PEF book's sheet, whose rows are always Unicode braille patterns,
    /// has no Braille File Characters pop-up, nor any; a text book's has its
    /// Text Encoding pop-up alone.
    func testOnlyABRFOrBRLBooksSheetHasThePopUp() throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        let pef = try makeBrailleBook("Atlas", code: nil, fileExtension: "pef")
        XCTAssertFalse(pef.offersBrailleFileCodeChoice)
        let pefSheet = LibraryBookInfoSheet(book: pef, libraryViewModel: makeModel(with: [pef]))
            .frame(width: 400, height: 350)
        withHostedView(pefSheet, size: NSSize(width: 400, height: 350), until: { [self] in
            accessibleControls(in: $0).contains { $0.role == .textField }
        }) { hosting in
            XCTAssertFalse(accessibleControls(in: hosting).contains { $0.label == BrailleFileCodeWording.bookInfoLabel })
            XCTAssertTrue(descendants(of: hosting, as: NSPopUpButton.self).isEmpty)
        }

        let text = Book(
            title: "Gazette", format: .txt, filePath: "/nowhere/Gazette.txt", md5Hash: "braille-file-code-sheet-text",
            textEncoding: "windows-1251"
        )
        XCTAssertTrue(text.offersTextEncodingChoice, "the text book must have its own pop-up, or this proves less")
        let textSheet = LibraryBookInfoSheet(book: text, libraryViewModel: makeModel(with: [text]))
            .frame(width: 400, height: 470)
        withHostedView(textSheet, size: NSSize(width: 400, height: 470), until: { [self] in
            accessibleControls(in: $0).contains { $0.label == TextEncodingWording.bookInfoLabel }
        }) { hosting in
            XCTAssertTrue(accessibleControls(in: hosting).contains { $0.label == TextEncodingWording.bookInfoLabel })
            XCTAssertFalse(accessibleControls(in: hosting).contains { $0.label == BrailleFileCodeWording.bookInfoLabel })
            XCTAssertEqual(descendants(of: hosting, as: NSPopUpButton.self).count, 1)
        }
    }

    // MARK: - The Words

    /// Every sentence of the pop-up, its alert, and Speak Info, exactly: the
    /// alert says first that nothing checks the choice, then the encoding's
    /// own sentences of what a re-read does, with the places' sentence less
    /// the encoding's Cyrillic example, and ends as the encoding's does.
    func testTheWordsArePinned() {
        XCTAssertEqual(BrailleFileCodeWording.bookInfoLabel, "Braille File Characters")
        XCTAssertEqual(BrailleFileCodeWording.popUpHint, "Choose other characters to read the book's file again with them.")
        XCTAssertEqual(
            BrailleFileCodeWording.unknownValue("ascii-braillo-no-047-01"),
            "“ascii-braillo-no-047-01”, which this version of TextMouth can't read"
        )
        XCTAssertEqual(
            BrailleFileCodeWording.speakInfoPart("North American Braille ASCII"), "Braille characters: North American Braille ASCII"
        )
        XCTAssertEqual(
            BrailleFileCodeWording.confirmTitle(bookTitle: "Ledger", code: .eurobraille),
            "Read “Ledger” again as Eurobraille, six-dot (German-speaking countries)?"
        )
        XCTAssertEqual(TextEncodingWording.confirmButton, "Read Again")

        let unchecked = "Nothing checks that this is the right choice. If numbers and punctuation sound wrong, choose another."
        let replaced = "Its text is replaced by the new reading."
        let places = "Your place and bookmarks move with their words. "
            + "Where none of their words are left, each goes to about the same point in its chapter, "
            + "or to the nearest passage the two readings share."
        let kept = "An edit of its text is kept beside the new reading, as a copy in the book's package."
        let stops = "Edit Text stops for this book; choose Edit Text again to edit the new reading."
        XCTAssertEqual(BrailleFileCodeWording.uncheckedNote, unchecked)
        XCTAssertEqual(BrailleFileCodeWording.placesNote, places)
        XCTAssertEqual(BrailleFileCodeWording.confirmMessage(keepsText: false, stopsEditing: false), [unchecked, replaced, places].joined(separator: " "))
        XCTAssertEqual(
            BrailleFileCodeWording.confirmMessage(keepsText: true, stopsEditing: false), [unchecked, replaced, places, kept].joined(separator: " ")
        )
        XCTAssertEqual(
            BrailleFileCodeWording.confirmMessage(keepsText: false, stopsEditing: true), [unchecked, replaced, places, stops].joined(separator: " ")
        )
        XCTAssertEqual(
            BrailleFileCodeWording.confirmMessage(keepsText: true, stopsEditing: true),
            [unchecked, replaced, places, kept, stops].joined(separator: " ")
        )
    }
}
