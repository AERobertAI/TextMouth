import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Book Information's Text Encoding pop-up (encodingchoice), as the sheet
/// draws it and VoiceOver meets it: its items, with the encoding the book is
/// read in now selected; a new option asked about first, Cancel leaving the
/// pop-up as it was, and Read Again reading the book again; a refusal shown
/// in the sheet; and its label, value, and hint, read from the hosted sheet.
@MainActor
final class TextEncodingPopUpTests: CloudMaintenanceTestCase {

    // MARK: - Fixtures

    /// A plain-text book titled `title`, in a package of this test's folder,
    /// whose file holds `bytes`, read as `record` says, with its text cache
    /// committed, as a book imported from the listener's file is.
    private func makeTextBook(
        _ title: String,
        bytes: Data,
        record: TextEncodingRecord = .unrecorded
    ) throws -> Book {
        let packageName = "\(title)-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let source = package.appendingPathComponent("\(title).txt")
        try bytes.write(to: source)
        var book = Book(
            title: title, format: .txt, filePath: source.path, md5Hash: UUID().uuidString, folderPath: folderPath,
            tmbDirectoryName: packageName, sourceFilePath: "/Users/someone/Documents/\(title).txt", cacheFormatVersion: "3.0.3"
        )
        book.textEncodingRecord = record
        return try commitCache(of: book)
    }

    /// Russian prose in Windows-1251, which TextMouth guesses.
    private static var russian1251: Data {
        let text = "Утренний паром отходит от северной пристани ровно в семь, и опоздавшие пассажиры долго машут ему с берега.\n"
        return text.data(using: TextFileDecoder.encoding(forLabel: "windows-1251") ?? .windowsCP1251) ?? Data()
    }

    // MARK: - The Items and the Selection

    /// A book whose record names its encoding shows it selected at once,
    /// among the options alone, named with what decided it, which a pop-up
    /// button's value is; every other option is named as the catalog names
    /// it.
    func testARecordedEncodingIsSelectedAtOnce() throws {
        let book = try makeTextBook("Ferry", bytes: Self.russian1251, record: TextEncodingRecord(identifier: "windows-1251", source: nil))
        let model = TextEncodingChoiceModel(book: book, library: makeModel(with: [book]))
        XCTAssertEqual(model.selection, .option(.encoding("windows-1251")))
        XCTAssertEqual(model.items, TextEncodingChoices.options.map(TextEncodingChoiceModel.Item.option))
        XCTAssertEqual(model.valueDescription, "Windows-1251 (Cyrillic), guessed")
        XCTAssertEqual(model.name(of: model.selection), "Windows-1251 (Cyrillic), guessed")
        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(model.items.first.map(model.name(of:)), "Automatic")
        XCTAssertEqual(model.name(of: .option(.encoding("koi8-r"))), "KOI8-R (Russian)")
    }

    /// A book whose record says nothing shows that its file is checked, with
    /// the pop-up dimmed, until the file is read; a UTF-16 file, which no
    /// option names, then shows as an item of its own, listed last.
    func testAFileIsCheckedAndAnEncodingNoOptionNamesIsListedLast() async throws {
        let utf16 = Data([0xFF, 0xFE]) + Data("Ferry at seven.\n".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
        let book = try makeTextBook("Timetable", bytes: utf16)
        let model = TextEncodingChoiceModel(book: book, library: makeModel(with: [book]))
        XCTAssertEqual(model.state, .checking)
        XCTAssertEqual(model.valueDescription, "Checking the file")
        XCTAssertEqual(model.selection, .current)
        XCTAssertEqual(model.name(of: .current), "Checking the file")
        XCTAssertFalse(model.isEnabled)

        await model.load()

        XCTAssertEqual(model.selection, .current)
        XCTAssertEqual(model.items.last, .current)
        XCTAssertEqual(model.items.first, .option(.automatic))
        XCTAssertEqual(model.name(of: .current), "UTF-16 (little-endian), from its byte order mark")
        XCTAssertEqual(model.valueDescription, "UTF-16 (little-endian), from its byte order mark")
        XCTAssertTrue(model.isEnabled)
    }

    // MARK: - Choosing

    /// A new option is asked about first; Cancel leaves the pop-up, the
    /// book, and its text as they were; the option already selected asks
    /// nothing.
    func testANewOptionIsAskedAboutAndCancelLeavesEverything() throws {
        let book = try makeTextBook("Gulls", bytes: Self.russian1251, record: TextEncodingRecord(identifier: "windows-1251", source: nil))
        let library = makeModel(with: [book])
        let model = TextEncodingChoiceModel(book: book, library: library)
        let textBefore = try Data(contentsOf: MarkdownCacheService.cacheURL(for: book))

        model.choose(.option(.encoding("windows-1251")))
        XCTAssertNil(model.pending, "the option already selected asks nothing")

        model.choose(.option(.encoding("koi8-r")))
        XCTAssertEqual(model.pending, .encoding("koi8-r"))
        XCTAssertEqual(model.confirmTitle(for: .encoding("koi8-r")), "Read “Gulls” again as KOI8-R (Russian)?")
        XCTAssertFalse(model.confirmMessage(for: .encoding("koi8-r")).contains("Edit Text"), "the book holds no edit")
        XCTAssertEqual(model.selection, .option(.encoding("windows-1251")), "the pop-up shows what it showed while it asks")

        model.cancel()
        XCTAssertNil(model.pending)
        XCTAssertEqual(model.selection, .option(.encoding("windows-1251")))
        XCTAssertEqual(try Data(contentsOf: MarkdownCacheService.cacheURL(for: book)), textBefore)
        XCTAssertEqual(library.bookByID(book.id)?.textEncodingRecord, book.textEncodingRecord)
    }

    /// Read Again reads the book again, and the pop-up then shows the choice.
    func testReadAgainReadsTheBookAgainAndThePopUpShowsTheChoice() async throws {
        let book = try makeTextBook("Nets", bytes: Self.russian1251, record: TextEncodingRecord(identifier: "windows-1251", source: nil))
        let library = makeModel(with: [book])
        let model = TextEncodingChoiceModel(book: book, library: library)

        model.choose(.option(.encoding("koi8-r")))
        await model.confirm(.encoding("koi8-r"))

        XCTAssertNil(model.failureMessage)
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.selection, .option(.encoding("koi8-r")))
        XCTAssertEqual(model.valueDescription, "KOI8-R (Russian), chosen")
        XCTAssertEqual(library.bookByID(book.id)?.textEncodingRecord, TextEncodingRecord(identifier: "koi8-r", source: .chosen))
    }

    /// A refusal is shown in the sheet, and VoiceOver hears it: before the
    /// confirmation for a book that is busy, after it for bytes the encoding
    /// chosen cannot read. The pop-up shows what it showed.
    func testARefusalIsShownAndSaid() async throws {
        let book = try makeTextBook("Pier", bytes: Self.russian1251, record: TextEncodingRecord(identifier: "windows-1251", source: nil))
        let library = makeModel(with: [book])
        let model = TextEncodingChoiceModel(book: book, library: library)
        var announced: [String] = []
        let previous = VoiceOverAnnouncer.poster
        VoiceOverAnnouncer.poster = { announcement, _ in announced.append(announcement.message) }
        defer { VoiceOverAnnouncer.poster = previous }

        library.textExtraction.begin("Updating text cache", total: 1)
        model.choose(.option(.encoding("koi8-r")))
        library.textExtraction.end()
        let busy = "TextMouth is reading the library's text again. Try again when that finishes."
        XCTAssertNil(model.pending, "a busy book is not asked about")
        XCTAssertEqual(model.failureMessage, busy)

        model.choose(.option(.encoding("utf-8")))
        XCTAssertNil(model.failureMessage, "a new choice clears the last refusal")
        await model.confirm(.encoding("utf-8"))
        let notValid = "“Pier” can't be read as UTF-8: it holds bytes that are not valid in that encoding. Nothing was changed."
        XCTAssertEqual(model.failureMessage, notValid)
        XCTAssertEqual(announced, [busy, notValid])
        XCTAssertEqual(model.selection, .option(.encoding("windows-1251")))
    }

    // MARK: - VoiceOver

    /// The hosted sheet's pop-up is labelled "Text Encoding", its value (its
    /// selected item's title, which VoiceOver speaks before the label) names
    /// the encoding and what decided it, its hint says what it does, and it
    /// lists the options by the catalog's names, the selected one with what
    /// decided it.
    func testThePopUpIsLabelledAndValuedForVoiceOver() throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        let book = try makeTextBook("Wharf", bytes: Self.russian1251, record: TextEncodingRecord(identifier: "windows-1251", source: nil))
        let sheet = LibraryBookInfoSheet(book: book, libraryViewModel: makeModel(with: [book]))
            .frame(width: 400, height: 470)
        try withHostedView(sheet, size: NSSize(width: 400, height: 470), until: { [self] in
            accessibleControls(in: $0).contains { $0.label == TextEncodingWording.bookInfoLabel }
        }) { hosting in
            let control = try control(labelled: "Text Encoding", in: accessibleControls(in: hosting))
            XCTAssertEqual(control.role, .popUpButton)
            XCTAssertEqual(control.element.accessibilityValue() as? String, "Windows-1251 (Cyrillic), guessed")
            XCTAssertEqual(control.hint, TextEncodingWording.popUpHint)
            let popUp = try XCTUnwrap(descendants(of: hosting, as: NSPopUpButton.self).first)
            let expected = TextEncodingChoices.options.map { option in
                option == .encoding("windows-1251") ? "Windows-1251 (Cyrillic), guessed" : TextEncodingChoices.name(of: option)
            }
            XCTAssertEqual(popUp.itemTitles, expected)
            XCTAssertEqual(popUp.titleOfSelectedItem, "Windows-1251 (Cyrillic), guessed")
        }
    }

    /// A book of a format that has no use for an encoding, and text typed
    /// in, have no Text Encoding pop-up.
    func testOnlyTextBooksFromTheListenersFilesHaveThePopUp() throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        var typed = try makeTextBook("Typed", bytes: Data("Typed in.\n".utf8))
        typed.sourceFilePath = nil
        let sheet = LibraryBookInfoSheet(book: typed, libraryViewModel: makeModel(with: [typed]))
            .frame(width: 400, height: 350)
        withHostedView(sheet, size: NSSize(width: 400, height: 350), until: { [self] in
            accessibleControls(in: $0).contains { $0.role == .textField }
        }) { hosting in
            XCTAssertFalse(accessibleControls(in: hosting).contains { $0.label == TextEncodingWording.bookInfoLabel })
            XCTAssertTrue(descendants(of: hosting, as: NSPopUpButton.self).isEmpty)
        }
    }
}
