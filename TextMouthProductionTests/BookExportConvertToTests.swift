import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The Export dialog's Convert to picker (FMT18) as the user meets it: beside
/// the "Text as Markdown" checkbox, offered only while that is checked, with
/// Markdown first (today's export, the default) and then each text writer;
/// the checkbox's words saying which is chosen; and the export making the
/// file of the writer chosen.
///
/// SwiftUI builds the spoken labels of its own checkboxes only for a
/// connected assistive app, so their words are pinned through
/// `BookExportWording` and the model, where they come from, and the picker is
/// found as the AppKit pop-up button SwiftUI draws for it. Every export goes
/// to a sandbox folder, never the user's Documents.
@MainActor
final class BookExportConvertToTests: XCTestCase {

    // MARK: - The Words

    /// Every new word of the picker, exactly as it is shown and spoken.
    func testTheConvertToWords() {
        XCTAssertEqual(BookExportWording.convertToLabel, "Convert to")
        XCTAssertEqual(BookExportWording.markdownChoiceName, "Markdown")
        XCTAssertEqual(
            BookExportWording.markdownChoiceHint,
            "The book's text as Markdown, the file TextMouth reads it from, as it is."
        )
    }

    /// The checkbox's name and hint say the conversion for the text kind
    /// alone, and are today's words without one.
    func testTheCheckboxNameAndHintSayTheConversion() {
        XCTAssertEqual(BookExportWording.name(of: .markdown, convertedTo: "HTML"), "Text as HTML")
        XCTAssertEqual(
            BookExportWording.name(of: .markdown, convertedTo: "Word 97-2003 (.doc)"),
            "Text as Word 97-2003 (.doc)"
        )
        XCTAssertEqual(
            BookExportWording.hint(for: .markdown, convertedTo: "HTML"),
            "The book's text as HTML, made from the Markdown TextMouth reads it from."
        )
        XCTAssertEqual(
            BookExportWording.hint(for: .markdown, convertedTo: "Word 97-2003 (.doc)"),
            "The book's text as Word 97-2003 (.doc), made from the Markdown TextMouth reads it from."
        )
        // Without a conversion, and for a kind that converts nothing, every
        // word is today's.
        for kind in BookExportKind.allCases {
            XCTAssertEqual(BookExportWording.name(of: kind, convertedTo: nil), BookExportWording.name(of: kind))
            XCTAssertEqual(BookExportWording.hint(for: kind, convertedTo: nil), BookExportWording.hint(for: kind))
            if !kind.convertsText {
                XCTAssertEqual(BookExportWording.name(of: kind, convertedTo: "HTML"), BookExportWording.name(of: kind))
                XCTAssertEqual(BookExportWording.hint(for: kind, convertedTo: "HTML"), BookExportWording.hint(for: kind))
            }
        }
    }

    /// A converted checkbox's label names the conversion and sizes it as
    /// "about", for one book and for several; without a conversion, every
    /// label is today's.
    func testAConvertedChoiceLabel() {
        let size = ByteCountFormatter.string(fromByteCount: 1_200_000, countStyle: .file)
        XCTAssertEqual(
            BookExportWording.choiceLabel(
                kind: .markdown, bookCount: 1, availableItemCount: 1, fileCount: 1, byteCount: 1_200_000,
                inCloudCount: 0, convertedTo: "HTML"
            ),
            "Text as HTML, about \(size)"
        )
        XCTAssertEqual(
            BookExportWording.choiceLabel(
                kind: .markdown, bookCount: 3, availableItemCount: 2, fileCount: 2, byteCount: 1_200_000,
                inCloudCount: 1, convertedTo: "RTF"
            ),
            "Text as RTF, 2 books, about \(size), 1 book in the cloud"
        )
        XCTAssertEqual(
            BookExportWording.choiceLabel(
                kind: .markdown, bookCount: 1, availableItemCount: 0, fileCount: 0, byteCount: 0,
                inCloudCount: 1, convertedTo: "HTML"
            ),
            "Text as HTML, in the cloud"
        )
        XCTAssertEqual(
            BookExportWording.choiceLabel(
                kind: .markdown, bookCount: 1, availableItemCount: 1, fileCount: 1, byteCount: 1_200_000,
                inCloudCount: 0
            ),
            "Text as Markdown, \(size)"
        )
        // A kind that converts nothing ignores a conversion name.
        XCTAssertEqual(
            BookExportWording.choiceLabel(
                kind: .originalFile, bookCount: 1, availableItemCount: 1, fileCount: 1, byteCount: 1_200_000,
                inCloudCount: 0, convertedTo: "HTML"
            ),
            "Original file, \(size)"
        )
    }

    // MARK: - The Picker's Choices

    /// The picker beside "Text as Markdown" lists Markdown, then each writer,
    /// with the hints the user hears; no other kind has a picker.
    func testThePickersChoicesAreMarkdownThenEachWriter() {
        XCTAssertEqual(
            BookExportModel.conversionChoices(for: .markdown),
            [
                BookExportConversionChoice(
                    id: "markdown",
                    name: "Markdown",
                    hint: "The book's text as Markdown, the file TextMouth reads it from, as it is."
                ),
                BookExportConversionChoice(
                    id: "html",
                    name: "HTML",
                    hint: "A web page of the book's text, with a contents list linking each heading."
                ),
                BookExportConversionChoice(
                    id: "rtf",
                    name: "RTF",
                    hint: "Rich text, with each heading at its outline level, for Word, Pages, and TextEdit."
                ),
                BookExportConversionChoice(
                    id: "doc",
                    name: "Word 97-2003 (.doc)",
                    hint: "Word 97-2003 document. Its headings are plain text, so Word's navigation pane does not list them."
                ),
            ]
        )
        for kind in BookExportKind.allCases where kind != .markdown {
            XCTAssertEqual(BookExportModel.conversionChoices(for: kind), [], "\(kind) has no picker")
        }
    }

    // MARK: - The Model's State

    /// A new dialog is on Markdown. Choosing HTML puts the writer in the
    /// checkbox's label and hint; going back to Markdown restores today's
    /// words exactly; an unknown id and a kind without a picker change
    /// nothing.
    func testChoosingAWriterChangesTheCheckboxWords() async throws {
        let dialog = try await makeDialog("Export Convert Words")
        let model = dialog.model
        let markdownChoice = try XCTUnwrap(model.choices.first { $0.kind == .markdown })
        let size = ByteCountFormatter.string(
            fromByteCount: FileStamp(of: MarkdownCacheService.cacheURL(for: dialog.book))?.byteCount ?? -1,
            countStyle: .file
        )

        XCTAssertEqual(model.conversionID(for: .markdown), "markdown")
        XCTAssertEqual(model.conversionChoice(for: .markdown)?.name, "Markdown")
        XCTAssertEqual(model.label(for: markdownChoice), "Text as Markdown, \(size)")
        XCTAssertEqual(model.label(for: markdownChoice), markdownChoice.label)
        XCTAssertEqual(model.hint(for: .markdown), BookExportWording.hint(for: .markdown))

        model.setConversionID("html", for: .markdown)

        XCTAssertEqual(model.conversionID(for: .markdown), "html")
        XCTAssertEqual(model.conversionChoice(for: .markdown)?.name, "HTML")
        XCTAssertEqual(model.label(for: markdownChoice), "Text as HTML, about \(size)")
        XCTAssertEqual(
            model.hint(for: .markdown),
            "The book's text as HTML, made from the Markdown TextMouth reads it from."
        )

        model.setConversionID("markdown", for: .markdown)

        XCTAssertEqual(model.label(for: markdownChoice), "Text as Markdown, \(size)")
        XCTAssertEqual(model.hint(for: .markdown), BookExportWording.hint(for: .markdown))

        model.setConversionID("html", for: .markdown)
        model.setConversionID("no such writer", for: .markdown)
        model.setConversionID("html", for: .originalFile)

        XCTAssertEqual(model.conversionID(for: .markdown), "html", "an unknown id changes nothing")
        XCTAssertEqual(model.conversionID(for: .originalFile), "markdown", "a kind without a picker stays as it was")
        XCTAssertNil(model.conversionChoice(for: .originalFile))
        let original = try XCTUnwrap(model.choices.first { $0.kind == .originalFile })
        XCTAssertEqual(model.label(for: original), original.label)
        XCTAssertEqual(model.hint(for: .originalFile), BookExportWording.hint(for: .originalFile))
    }

    /// No writer of tonight takes options, so no options view shows under
    /// the picker for Markdown or for any of them, checked or not.
    func testNoOptionsViewShowsForTonightsWriters() async throws {
        let dialog = try await makeDialog("Export Convert Options")
        let model = dialog.model
        model.setChecked(true, for: .markdown)

        XCTAssertNil(model.optionsView(for: .markdown), "Markdown has no options")
        for writer in TextExportWriters.all {
            model.setConversionID(writer.id, for: .markdown)
            XCTAssertNil(model.optionsView(for: .markdown), "\(writer.name) has no options")
        }
    }

    /// Unchecking "Text as Markdown" leaves the picker's choice as it was,
    /// and an export of a dialog whose only conversion is on an unchecked
    /// kind makes no conversion and copies as it always did.
    func testUncheckingTheKindKeepsItsChoiceAndPassesNoConversion() async throws {
        let dialog = try await makeDialog("Export Convert Unchecked")
        let model = dialog.model
        model.setChecked(true, for: .markdown)
        model.setConversionID("rtf", for: .markdown)
        XCTAssertEqual(Set(model.conversions.keys), [.markdown])
        XCTAssertEqual(model.conversions[.markdown]?.fileExtension, "rtf")

        model.setChecked(false, for: .markdown)

        XCTAssertEqual(model.conversionID(for: .markdown), "rtf", "the choice outlives the checkbox")
        XCTAssertTrue(model.conversions.isEmpty, "an unchecked kind passes no conversion")
        XCTAssertEqual(model.checked, [.originalFile])

        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        let exported = await model.export()
        let outcome = try XCTUnwrap(exported)

        XCTAssertTrue(BookExportModel.didEverything(outcome))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dialog.folder.path),
            ["Harbour Pilots.md"],
            "only the original file went"
        )

        model.setChecked(true, for: .markdown)
        XCTAssertEqual(model.conversionID(for: .markdown), "rtf", "checking it again finds the choice")
    }

    // MARK: - The Export

    /// With HTML chosen, the export writes "<stem> - Text.html" and no
    /// Markdown, announces it, and leaves the dialog nothing to say, so it
    /// closes.
    func testExportingWithHTMLChosenWritesAnHTMLFile() async throws {
        let dialog = try await makeDialog("Export Convert Html")
        let model = dialog.model
        model.setChecked(false, for: .originalFile)
        model.setChecked(true, for: .markdown)
        model.setConversionID("html", for: .markdown)
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        let exported = await model.export()
        let outcome = try XCTUnwrap(exported)

        let stem = BookExportService.fileNameStem(for: dialog.book.title)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dialog.folder.path),
            ["\(stem) - Text.html"]
        )
        XCTAssertEqual(outcome.exported.map(\.lastPathComponent), ["\(stem) - Text.html"])
        XCTAssertTrue(BookExportModel.didEverything(outcome), "the dialog closes")
        XCTAssertNil(model.summary, "the dialog has nothing to say")
        XCTAssertEqual(
            announcements.messages,
            ["Exported 1 item to \(BookExportWording.folderName(of: dialog.folder))."]
        )
    }

    /// With Markdown chosen, the export is the file it always was, byte for
    /// byte the book's content.md.
    func testExportingWithMarkdownChosenCopiesTheBooksMarkdown() async throws {
        let dialog = try await makeDialog("Export Convert Markdown")
        let model = dialog.model
        model.setChecked(false, for: .originalFile)
        model.setChecked(true, for: .markdown)
        model.setConversionID("html", for: .markdown)
        model.setConversionID("markdown", for: .markdown)
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        let exported = await model.export()
        let outcome = try XCTUnwrap(exported)

        let stem = BookExportService.fileNameStem(for: dialog.book.title)
        XCTAssertTrue(BookExportModel.didEverything(outcome))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: dialog.folder.path),
            ["\(stem) - Text.md"]
        )
        XCTAssertEqual(
            try Data(contentsOf: dialog.folder.appendingPathComponent("\(stem) - Text.md")),
            try Data(contentsOf: MarkdownCacheService.cacheURL(for: dialog.book))
        )
    }

    // MARK: - The Dialog Drawn

    /// The dialog draws the picker only while "Text as Markdown" is checked,
    /// on Markdown at first, and shows the writer chosen.
    func testTheDialogDrawsThePickerOnlyWhileTheKindIsChecked() throws {
        let world = try makeIntegrationWorld("Export Convert Drawn")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let model = BookExportModel(
            books: [book],
            destination: try makeSandboxDirectory("Export Convert Drawn Folder")
        )

        withHostedView(BookExportSheet(model: model, close: {}), until: { self.checkboxes(in: $0).count == 3 }) { hostingView in
            XCTAssertEqual(popUps(in: hostingView).count, 0, "Text as Markdown is unchecked: no picker")

            model.setChecked(true, for: .markdown)
            XCTAssertTrue(waitUntil(timeout: 5) {
                hostingView.layoutSubtreeIfNeeded()
                return self.popUps(in: hostingView).count == 1
            }, "checking the kind draws the picker")
            XCTAssertEqual(popUps(in: hostingView).first?.titleOfSelectedItem, "Markdown")

            model.setConversionID("rtf", for: .markdown)
            XCTAssertTrue(waitUntil(timeout: 5) {
                hostingView.layoutSubtreeIfNeeded()
                return self.popUps(in: hostingView).first?.titleOfSelectedItem == "RTF"
            }, "the picker shows the writer chosen")

            model.setChecked(false, for: .markdown)
            XCTAssertTrue(waitUntil(timeout: 5) {
                hostingView.layoutSubtreeIfNeeded()
                return self.popUps(in: hostingView).isEmpty
            }, "unchecking the kind takes the picker away")
        }
    }

    // MARK: - Support

    /// A dialog on a one-book library, listed, with the folder it exports to.
    private struct Dialog {
        /// Keeps the library alive for the test's length.
        let world: IntegrationWorld
        /// The book the dialog exports.
        let book: Book
        /// The sandbox folder the export goes to.
        let folder: URL
        /// The dialog's model, listed.
        let model: BookExportModel
    }

    /// Imports a two-chapter text book and lists a dialog on it, the first
    /// kind (the original file) checked.
    private func makeDialog(_ label: String) async throws -> Dialog {
        let world = try makeIntegrationWorld(label)
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let folder = try makeSandboxDirectory("\(label) Folder")
        let model = BookExportModel(books: [book], library: world.library, destination: folder)
        await model.load()
        return Dialog(world: world, book: book, folder: folder, model: model)
    }

    /// The Markdown of the two-chapter book.
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
        let file = try makeSandboxDirectory("Export Convert Source").appendingPathComponent(name)
        try Data(Self.twoChapters.utf8).write(to: file)
        return file
    }

    /// The checkboxes SwiftUI drew inside `view`: the untitled AppKit
    /// buttons, leaving out the picker's pop-up button.
    private func checkboxes(in view: NSView) -> [NSButton] {
        descendants(of: view, as: NSButton.self).filter { !($0 is NSPopUpButton) && $0.title.isEmpty }
    }

    /// The pop-up buttons SwiftUI drew inside `view`: the Convert to picker.
    private func popUps(in view: NSView) -> [NSPopUpButton] {
        descendants(of: view, as: NSPopUpButton.self)
    }
}
