import Combine
import XCTest
@testable import TextMouth

/// The iPhone's hooks in `BookExportModel` (FR31): the kinds offered, a folder
/// that must be chosen before Export can be pressed, what an export holds
/// while it runs, the words kept for the sheet once it has ended, the options
/// a row binds, and the guard that fails a book too large for the memory left.
/// The Mac's host runs them with the model as the iPhone's sheet makes it.
@MainActor
final class PhoneExportModelTests: XCTestCase {

    // MARK: - What Is Offered

    /// Offering the iPhone's kinds lists every kind the Mac lists, in the dialog's order, the first checked.
    func testTheIPhonesKindsAreTheMacsInTheMacsOrder() async throws {
        let world = try makeIntegrationWorld("Phone Export Offer")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let model = BookExportModel(
            books: [book],
            destination: try makeSandboxDirectory("Phone Export Offer Folder"),
            offering: PhoneExportOffer.kinds
        )

        await model.load()

        XCTAssertEqual(model.choices.map(\.kind), [.originalFile, .markdown, .plainText, .spokenAudio])
        XCTAssertEqual(model.checked, [.originalFile])
    }

    /// Without being told, the dialog offers every kind, as the Mac's does.
    func testTheMacOffersEveryKind() async throws {
        let world = try makeIntegrationWorld("Phone Export Mac Offer")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let model = BookExportModel(books: [book], destination: try makeSandboxDirectory("Phone Export Mac Folder"))

        await model.load()

        XCTAssertEqual(model.choices.map(\.kind), [.originalFile, .markdown, .plainText, .spokenAudio])
    }

    // MARK: - The Folder

    /// Export can't be pressed until a folder is chosen, however many kinds
    /// are on, and can once one is.
    func testExportWaitsForAFolder() async throws {
        let world = try makeIntegrationWorld("Phone Export Folder Wait")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let model = BookExportModel(books: [book], destinationIsChosen: false)
        await model.load()
        XCTAssertEqual(model.checked, [.originalFile])
        XCTAssertFalse(model.isDestinationChosen)
        XCTAssertFalse(model.canExport)

        model.chooseDestination(try makeSandboxDirectory("Phone Export Folder Chosen"))

        XCTAssertTrue(model.isDestinationChosen)
        XCTAssertTrue(model.canExport)
    }

    /// The Mac's dialog starts with a folder, so nothing changes there.
    func testTheMacsDialogStartsWithAFolder() async throws {
        let world = try makeIntegrationWorld("Phone Export Mac Folder")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let model = BookExportModel(books: [book], destination: try makeSandboxDirectory("Phone Export Mac Folder Chosen"))
        await model.load()

        XCTAssertTrue(model.isDestinationChosen)
        XCTAssertTrue(model.canExport)
    }

    // MARK: - An Export

    /// An export through the iPhone's way holds what it needs from its start
    /// to its end, for the folder it goes to, writes the files by the
    /// coordinated copy, and keeps its words for the sheet, as the Mac's
    /// dialog does not, though everything asked was done.
    func testAnExportHoldsWhatItNeedsAndKeepsItsWordsForTheSheet() async throws {
        let world = try makeIntegrationWorld("Phone Export Run")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let folder = try makeSandboxDirectory("Phone Export Run Folder")
        let holds = HoldRecord()
        let model = BookExportModel(
            books: [book],
            library: world.library,
            destination: folder,
            offering: PhoneExportOffer.kinds,
            destinationIsChosen: true,
            delivery: .coordinatedCopy,
            holdWhileExporting: { url in
                holds.began(url)
                return { holds.ended() }
            }
        )
        await model.load()
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        XCTAssertNil(model.finishedWords)

        let exported = await model.export()
        let outcome = try XCTUnwrap(exported)

        XCTAssertEqual(holds.events, ["began \(folder.path)", "ended"])
        XCTAssertEqual(outcome.exported.count, 1)
        XCTAssertTrue(BookExportModel.didEverything(outcome))
        let words = "Exported 1 item to \(BookExportWording.folderName(of: folder))."
        XCTAssertNil(model.summary, "the Mac's dialog closes, so it keeps nothing")
        XCTAssertEqual(model.finishedWords, words)
        XCTAssertEqual(announcements.messages, [words])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
    }

    /// A Stop pressed as the export begins ends it as stopped, and the hold the run took is let go; so is the hold of
    /// an export whose writer fails (below).
    func testTheHoldEndsOnAnEarlyStop() async throws {
        let world = try makeIntegrationWorld("Phone Export Early Stop")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let folder = try makeSandboxDirectory("Phone Export Early Stop Folder")
        let holds = HoldRecord()
        let stopper = WordsSeenWhileHolding()
        let model = BookExportModel(
            books: [book],
            library: world.library,
            destination: folder,
            offering: PhoneExportOffer.kinds,
            delivery: .coordinatedCopy,
            holdWhileExporting: { url in
                holds.began(url)
                // Stop, as a person presses it the moment the export begins.
                stopper.model?.stop()
                return { holds.ended() }
            }
        )
        stopper.model = model
        await model.load()

        let exported = await model.export()
        let outcome = try XCTUnwrap(exported)

        XCTAssertTrue(outcome.wasCancelled)
        XCTAssertEqual(outcome.exported, [])
        XCTAssertEqual(holds.events, ["began \(folder.path)", "ended"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    /// The hold of an export whose writer fails is let go too, and the failure is the writer's sentence.
    func testTheHoldEndsWhenTheWriterFails() async throws {
        let world = try makeIntegrationWorld("Phone Export Writer Error")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let folder = try makeSandboxDirectory("Phone Export Writer Error Folder")
        let holds = HoldRecord()
        let model = BookExportModel(
            books: [book],
            library: world.library,
            destination: folder,
            writers: [FailingWriter()],
            offering: PhoneExportOffer.kinds,
            delivery: .coordinatedCopy,
            holdWhileExporting: { url in
                holds.began(url)
                return { holds.ended() }
            }
        )
        await model.load()
        model.setChecked(true, for: .markdown)
        model.setChecked(false, for: .originalFile)
        model.setConversionID("failing", for: .markdown)

        let exported = await model.export()
        let outcome = try XCTUnwrap(exported)

        XCTAssertEqual(outcome.failures.map(\.reason), ["The writer cannot write this book."])
        XCTAssertEqual(holds.events, ["began \(folder.path)", "ended"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    /// The end of an export names the folder as the caller read it under its scope, and not as the model finds it later.
    func testTheEndNamesTheFolderAsTheCallerReadIt() async throws {
        let world = try makeIntegrationWorld("Phone Export Folder Name")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let folder = try makeSandboxDirectory("Phone Export Folder Name Folder")
        let model = BookExportModel(
            books: [book], library: world.library, destination: folder, offering: PhoneExportOffer.kinds,
            destinationName: "Downloads", delivery: .coordinatedCopy
        )
        await model.load()

        _ = await model.export()

        XCTAssertEqual(model.finishedWords, "Exported 1 item to Downloads.")
    }

    /// An export that cannot start holds nothing.
    func testAnExportThatCannotStartHoldsNothing() async throws {
        let world = try makeIntegrationWorld("Phone Export No Hold")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let holds = HoldRecord()
        let model = BookExportModel(
            books: [book],
            destinationIsChosen: false,
            holdWhileExporting: { url in
                holds.began(url)
                return { holds.ended() }
            }
        )
        await model.load()

        let outcome = await model.export()

        XCTAssertNil(outcome)
        XCTAssertEqual(holds.events, [])
    }

    /// The words of an export are forgotten when the next begins, so the
    /// sheet never shows an old export's end beside a new export's progress:
    /// what the export holds as it starts finds none.
    func testTheWordsAreForgottenWhenTheNextExportBegins() async throws {
        let world = try makeIntegrationWorld("Phone Export Forget")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let folder = try makeSandboxDirectory("Phone Export Forget Folder")
        let seen = WordsSeenWhileHolding()
        let model = BookExportModel(
            books: [book],
            library: world.library,
            destination: folder,
            offering: PhoneExportOffer.kinds,
            holdWhileExporting: { _ in
                seen.words.append(seen.model?.finishedWords)
                return {}
            }
        )
        seen.model = model
        await model.load()

        _ = await model.export()
        XCTAssertNotNil(model.finishedWords)
        _ = await model.export()

        XCTAssertEqual(seen.words.count, 2)
        XCTAssertNil(seen.words.last ?? "", "the second export began with the first one's words")
    }

    // MARK: - The Options a Row Binds

    /// A writer without options has no state to bind; a braille writer's
    /// state gives and takes its braille options, and an export converts with
    /// them as they stand.
    func testABrailleWritersOptionsAreBoundThroughTheState() async throws {
        let world = try makeIntegrationWorld("Phone Export Options")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let model = BookExportModel(
            books: [book],
            destination: try makeSandboxDirectory("Phone Export Options Folder"),
            offering: PhoneExportOffer.kinds
        )
        await model.load()
        model.setChecked(true, for: .markdown)
        XCTAssertNil(model.optionsState(for: .markdown), "Markdown takes no options")
        model.setConversionID("html", for: .markdown)
        XCTAssertNil(model.optionsState(for: .markdown), "HTML takes no options")

        model.setConversionID("brf", for: .markdown)
        let state = try XCTUnwrap(model.optionsState(for: .markdown))
        var options = try XCTUnwrap(state.brailleOptions)
        options.page.cellsPerLine = 30
        options.page.numbersPages = false
        options.lineEnd = .lf
        state.brailleOptions = options

        XCTAssertEqual(state.brailleOptions, options)
        XCTAssertEqual(
            model.conversions[.markdown],
            .text(TextExportConversion(BRFExportWriter(), options: options))
        )
        XCTAssertNil(model.optionsState(for: .plainText), "an unchecked kind has no options")
    }

    /// A change of the options is announced once, which is what draws the iPhone's rows
    /// again, and the state's own first value is no change.
    func testAChangeOfTheOptionsIsAnnouncedOnce() {
        let state = TextExportWriters.optionsState(for: BRFExportWriter())
        var heard = 0
        let listening = state.changes.sink { heard += 1 }
        defer { listening.cancel() }
        XCTAssertEqual(heard, 0, "the first value counted as a change")

        var options = state.brailleOptions ?? BrailleExportOptions()
        options.page.cellsPerLine = 33
        state.brailleOptions = options

        XCTAssertEqual(heard, 1)
        XCTAssertEqual(state.brailleOptions?.page.cellsPerLine, 33)
    }

    /// A writer that is not braille's has no braille options, and setting
    /// some changes nothing.
    func testAWriterThatIsNotBraillesTakesNoBrailleOptions() async throws {
        let state = TextExportWriters.optionsState(for: HTMLExportWriter())

        XCTAssertNil(state.brailleOptions)
        state.brailleOptions = BrailleExportOptions()
        XCTAssertNil(state.brailleOptions)
    }

    // MARK: - The Memory Guard

    /// A book the guard refuses fails its file with the guard's sentence,
    /// and the export ends, the failure kept in the sheet's words.
    func testABookTheGuardRefusesFailsItsFile() async throws {
        let world = try makeIntegrationWorld("Phone Export Guard")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let folder = try makeSandboxDirectory("Phone Export Guard Folder")
        let holds = HoldRecord()
        let model = BookExportModel(
            books: [book],
            library: world.library,
            destination: folder,
            offering: PhoneExportOffer.kinds,
            memoryGuard: { _, _ in throw TextExportError("There is no room.") },
            holdWhileExporting: { url in
                holds.began(url)
                return { holds.ended() }
            }
        )
        await model.load()
        model.setChecked(true, for: .markdown)
        model.setChecked(false, for: .originalFile)
        model.setConversionID("html", for: .markdown)

        let exported = await model.export()
        let outcome = try XCTUnwrap(exported)

        XCTAssertEqual(holds.events, ["began \(folder.path)", "ended"], "the hold was kept after a refusal")

        XCTAssertEqual(outcome.exported, [])
        XCTAssertEqual(outcome.failures.map(\.reason), ["There is no room."])
        XCTAssertEqual(
            model.finishedWords,
            "Couldn't export \(BookExportService.fileNameStem(for: book.title)) - Text.html: There is no room."
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    // MARK: - Helpers

    /// The words the model showed each time an export began to hold what it
    /// needs.
    private final class WordsSeenWhileHolding {
        var model: BookExportModel?
        var words: [String?] = []
    }

    /// A writer whose every book fails, with a sentence of its own.
    private struct FailingWriter: TextExportWriter {
        let id = "failing"
        let name = "Failing"
        let hint = "Fails."
        let fileExtension = "fail"

        func write(_ document: ExportDocument, options: NoTextExportOptions, to url: URL, cancellation: BookExportCancellation) throws {
            throw TextExportError("The writer cannot write this book.")
        }
    }

    // MARK: - The Sheet's Other Rows

    /// What the sheet's kind switches and its Convert to row say, which it reads from the model and draws as it finds it:
    /// each switch names its kind and carries the Mac's hint, and the Convert to row, once its kind is on, is labelled
    /// "Convert to", valued with the conversion chosen and hinted with what that conversion exports.
    func testTheKindSwitchesAndTheConvertToRowSayTheirLabelsValuesAndHints() async throws {
        let world = try makeIntegrationWorld("Phone Export Rows")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let model = BookExportModel(books: [book], offering: PhoneExportOffer.kinds, destinationIsChosen: false)
        await model.load()

        // The kinds, in the dialog's order, each named and hinted.
        let labels = model.choices.map { model.label(for: $0) }
        let starts = ["Original file", "Text as Markdown", "Text as plain text", "Text as spoken audio"]
        XCTAssertEqual(labels.count, starts.count, "\(labels)")
        for (label, start) in zip(labels, starts) {
            XCTAssertTrue(label.hasPrefix(start), "\(label) does not begin \(start)")
        }
        for choice in model.choices {
            XCTAssertFalse(model.hint(for: choice.kind).isEmpty, "\(choice.kind) has no hint")
        }

        // The Convert to row: there while the kind is on, and saying the conversion chosen.
        model.setChecked(true, for: .markdown)
        let choice = try XCTUnwrap(model.conversionChoice(for: .markdown))
        XCTAssertEqual(BookExportWording.convertToLabel(for: .markdown), "Convert to")
        XCTAssertEqual(choice.name, "Markdown")
        XCTAssertFalse(choice.hint.isEmpty, "The Convert to row has no hint")
        // Choosing BRF changes the row's value and its hint to the writer's.
        model.setConversionID(BRFExportWriter().id, for: .markdown)
        let brf = try XCTUnwrap(model.conversionChoice(for: .markdown))
        XCTAssertEqual(brf.name, "BRF")
        XCTAssertNotEqual(brf.hint, choice.hint)
    }

    /// The folder's name has one fallback, for the sheet's row and for the end of an export: the name read under the
    /// folder's scope when there is one, else the name its path gives.
    func testTheFolderHasOneNameForTheRowAndTheEnd() async throws {
        let world = try makeIntegrationWorld("Phone Export Shown Name")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let folder = try makeSandboxDirectory("Phone Export Shown Folder")
        let model = BookExportModel(books: [book], destination: folder, offering: PhoneExportOffer.kinds)
        await model.load()

        XCTAssertEqual(model.shownFolderName, BookExportWording.folderName(of: folder), "No name was read: the path's name")
        model.chooseDestination(folder, named: "Reading Folder")
        XCTAssertEqual(model.shownFolderName, "Reading Folder")

        // The end of the export says the same name the row does.
        await model.export()
        XCTAssertTrue(model.finishedWords?.contains("Reading Folder") == true, "\\(String(describing: model.finishedWords))")
    }

    /// What an export held and let go, in order.
    private final class HoldRecord {
        private(set) var events: [String] = []
        func began(_ url: URL) { events.append("began \(url.path)") }
        func ended() { events.append("ended") }
    }

    /// A two-chapter book's Markdown.
    private static let twoChapters = """
    <!-- chapter: First -->
    # First

    One two three.

    <!-- chapter: Second -->
    # Second

    Four five.
    """

    /// Writes the two-chapter book as a file named `name` in a sandbox
    /// folder of its own, for an import to read.
    private func writeSource(named name: String) throws -> URL {
        let file = try makeSandboxDirectory("Phone Export Source").appendingPathComponent(name)
        try Data(Self.twoChapters.utf8).write(to: file)
        return file
    }
}
