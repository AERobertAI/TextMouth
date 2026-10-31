import Combine
import XCTest
@testable import TextMouth

// MARK: - What the Test Reads of a Pop-up's Model

/// What this test reads of a re-read pop-up's model besides what the pop-up
/// needs of it (`BookRereadChoosing`): the flow it runs its choice in, and the
/// flow's state as the model forwards it to Book Information's sheet. Both
/// models have it, so one test drives either.
@MainActor
private protocol RereadFlowModel: BookRereadChoosing {
    /// The flow the model runs its choice, confirmation, and re-read in.
    var flow: RereadChoiceFlow<Option> { get }
    /// The book the model's pop-up reads again, as the flow has it.
    var bookID: UUID { get }
    /// Whether a re-read is under way, as the flow has it.
    var isWorking: Bool { get }
    /// Why the last choice changed nothing, as the flow has it.
    var failureMessage: String? { get }
}

extension TextEncodingChoiceModel: RereadFlowModel {}
extension BrailleFileCodeChoiceModel: RereadFlowModel {}

// MARK: - The Tests

/// The flow both of Book Information's re-read pop-ups run
/// (`RereadChoiceFlow`, review of October 30, finding 8), driven through each
/// pop-up's model alike: the Text Encoding pop-up's of a text book
/// (`TextEncodingChoiceModel`) and the Braille File Characters pop-up's of a
/// BRF book (`BrailleFileCodeChoiceModel`). A choice is asked about, Cancel
/// leaves it, a book being read again is refused with the busy sentence shown
/// and announced, and Read Again reads the book again, after which the pop-up
/// shows the new choice. At each step the model shows the flow's state, and
/// the views observing the model redraw as the flow changes.
@MainActor
final class BookRereadFlowTests: CloudMaintenanceTestCase {

    // MARK: - Fixtures

    /// Russian prose in Windows-1251, which KOI8-R reads otherwise.
    private static var russian1251: Data {
        let text = "Утренний паром отходит от северной пристани ровно в семь, и опоздавшие пассажиры долго машут ему с берега.\n"
        return text.data(using: TextFileDecoder.encoding(forLabel: "windows-1251") ?? .windowsCP1251) ?? Data()
    }

    /// The grade 1 BRF sample, a North American Braille ASCII file.
    private static let brailleSample = "brf/pride-and-prejudice-ch1-grade1.brf"
    /// The table the sample is written in: uncontracted UEB.
    private static let brailleTable = "en-ueb-g1.ctb"

    /// A plain-text book titled `title`, in a package of this test's folder,
    /// whose file holds Russian prose in Windows-1251, recorded as guessed,
    /// with its text cache committed, as a book imported from the listener's
    /// file is.
    private func makeRussianTextBook(_ title: String) throws -> Book {
        let packageName = "\(title)-\(UUID().uuidString).tmb"
        let package = TextMouthPaths.tmbPath(folderPath: folderPath, tmbName: packageName)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let source = package.appendingPathComponent("\(title).txt")
        try Self.russian1251.write(to: source)
        var book = Book(
            title: title, format: .txt, filePath: source.path, md5Hash: UUID().uuidString, folderPath: folderPath,
            tmbDirectoryName: packageName, sourceFilePath: "/Users/someone/Documents/\(title).txt", cacheFormatVersion: "3.0.3"
        )
        book.textEncodingRecord = TextEncodingRecord(identifier: "windows-1251", source: nil)
        return try commitCache(of: book)
    }

    /// The grade 1 sample written in Eurobraille and imported as North
    /// American Braille ASCII, with the sample's table, the code and table
    /// bound for the import and never the user's settings: a book read
    /// wrongly, which Eurobraille reads right.
    private func makeMisreadBrailleBook() throws -> Book {
        let copy = try copyOfBrailleSample(Self.brailleSample, writtenIn: .eurobraille)
        return try BraillePreferences.$tableForImports.withValue(Self.brailleTable) {
            try BraillePreferences.$fileCodeForImports.withValue(BrailleFileCode.northAmerican.id) {
                try importedForTest(copy).book
            }
        }
    }

    // MARK: - The Flow, Through Each Pop-up

    /// The choice, Cancel, a refusal, and Read Again, through each pop-up's
    /// model and the one flow behind both: a Windows-1251 book's Text
    /// Encoding pop-up reads it again as KOI8-R, and a misread BRF book's
    /// Braille File Characters pop-up reads it again as Eurobraille.
    func testBothPopUpsChooseCancelRefuseAndReadAgainThroughTheSharedFlow() async throws {
        let text = try makeRussianTextBook("Ferry")
        let textLibrary = makeModel(with: [text])
        await driveTheFlow(
            of: TextEncodingChoiceModel(book: text, library: textLibrary),
            in: textLibrary,
            choosing: .option(.encoding("koi8-r")),
            option: .encoding("koi8-r"),
            busy: "TextMouth is reading “Ferry” again in another encoding. Try again when that finishes.",
            done: "“Ferry” is now read as KOI8-R (Russian), chosen."
        )

        let braille = try makeMisreadBrailleBook()
        XCTAssertEqual(braille.brailleFileCode, "ascii-na", "the book must be read wrongly, or this proves nothing")
        let brailleLibrary = makeModel(with: [braille])
        await driveTheFlow(
            of: BrailleFileCodeChoiceModel(book: braille, library: brailleLibrary),
            in: brailleLibrary,
            choosing: .code(.eurobraille),
            option: .eurobraille,
            busy: "TextMouth is reading “\(braille.title)” again with other braille file characters. Try again when that finishes.",
            done: "“\(braille.title)” is now read as Eurobraille, six-dot (German-speaking countries)."
        )
    }

    /// Drives `model`, the pop-up's model of a book in `library`, through
    /// its flow: `item`, which stands for `option`, is asked about, and
    /// Cancel leaves it; the book, while it is being read again, refuses it,
    /// with `busy` shown and announced; then Read Again reads the book again,
    /// working while it does, announces `done`, and the pop-up shows `item`.
    /// At each step the model shows the flow's state, and its observers
    /// redraw as the flow changes. Failures are reported at the caller's
    /// `file` and `line`.
    private func driveTheFlow<Model: RereadFlowModel>(
        of model: Model,
        in library: LibraryViewModel,
        choosing item: Model.Item,
        option: Model.Option,
        busy: String,
        done: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let flow = model.flow
        let shownBefore = model.selection
        XCTAssertNotEqual(shownBefore, item, "the choice must be another, or nothing is asked", file: file, line: line)
        XCTAssertEqual(model.bookID, flow.bookID, file: file, line: line)
        // Each re-read under way in this library's own list, never the app's.
        library.textRereads = TextRereads()
        defer { library.booksBeingReadAgain = [] }
        // Every change the model's observers hear of, as SwiftUI hears it.
        var redraws = 0
        let redrawing = model.objectWillChange.sink { _ in redraws += 1 }
        defer { redrawing.cancel() }

        // A choice is asked about first, and the pop-up shows what it showed.
        await model.choose(item)
        let asked = RereadConfirmation(option: option, keepsText: false, stopsEditing: false)
        XCTAssertEqual(flow.pending, asked, file: file, line: line)
        XCTAssertEqual(model.pending, asked, file: file, line: line)
        XCTAssertNil(model.failureMessage, file: file, line: line)
        XCTAssertEqual(model.selection, shownBefore, file: file, line: line)
        XCTAssertGreaterThan(redraws, 0, "the model's observers must redraw as the flow asks", file: file, line: line)

        // Cancel leaves everything as it was.
        let redrawsBeforeCancel = redraws
        model.cancel()
        XCTAssertNil(flow.pending, file: file, line: line)
        XCTAssertNil(model.pending, file: file, line: line)
        XCTAssertEqual(model.selection, shownBefore, file: file, line: line)
        XCTAssertGreaterThan(redraws, redrawsBeforeCancel, "the model's observers must redraw as the flow cancels", file: file, line: line)

        // A book being read again is refused before anything is asked.
        library.booksBeingReadAgain = [model.bookID]
        let refusals = await announcements { await model.choose(item) }
        library.booksBeingReadAgain = []
        XCTAssertNil(model.pending, "a busy book is not asked about", file: file, line: line)
        XCTAssertEqual(flow.failureMessage, busy, file: file, line: line)
        XCTAssertEqual(model.failureMessage, busy, file: file, line: line)
        XCTAssertEqual(refusals, [busy], file: file, line: line)
        XCTAssertEqual(model.selection, shownBefore, file: file, line: line)

        // Read Again reads the book again, and the pop-up shows the choice.
        await model.choose(item)
        XCTAssertNil(model.failureMessage, "a new choice clears the last refusal", file: file, line: line)
        XCTAssertEqual(model.pending, asked, file: file, line: line)
        var working: [Bool] = []
        let watching = flow.$isWorking.sink { working.append($0) }
        defer { watching.cancel() }
        let said = await announcements { await model.confirm(option) }
        XCTAssertEqual(working, [false, true, false], "working while the book is read again, and only then", file: file, line: line)
        XCTAssertFalse(model.isWorking, file: file, line: line)
        XCTAssertNil(model.pending, file: file, line: line)
        XCTAssertNil(model.failureMessage, file: file, line: line)
        XCTAssertEqual(said, [done], file: file, line: line)
        XCTAssertEqual(model.selection, item, "the pop-up shows the new choice", file: file, line: line)
        XCTAssertTrue(model.isEnabled, "the pop-up takes a choice again", file: file, line: line)
    }
}
