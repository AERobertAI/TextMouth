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

    /// Offering the iPhone's kinds leaves spoken audio out of the checkboxes,
    /// the rest in the dialog's order, the first checked.
    func testTheIPhonesKindsLeaveSpokenAudioOut() async throws {
        let world = try makeIntegrationWorld("Phone Export Offer")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let model = BookExportModel(
            books: [book],
            destination: try makeSandboxDirectory("Phone Export Offer Folder"),
            offering: PhoneExportOffer.kinds
        )

        await model.load()

        XCTAssertEqual(model.choices.map(\.kind), [.originalFile, .markdown, .plainText])
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
        let model = BookExportModel(
            books: [book],
            library: world.library,
            destination: folder,
            offering: PhoneExportOffer.kinds,
            memoryGuard: { _ in throw TextExportError("There is no room.") }
        )
        await model.load()
        model.setChecked(true, for: .markdown)
        model.setChecked(false, for: .originalFile)
        model.setConversionID("html", for: .markdown)

        let exported = await model.export()
        let outcome = try XCTUnwrap(exported)

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
