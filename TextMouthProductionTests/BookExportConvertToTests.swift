import AppKit
import os
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
            "The book's text as Markdown, with its headings, lists, and emphasis."
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

    /// A converted checkbox's label names the conversion and says no size (a
    /// converted file's size is not known until it is written), for one book
    /// and for several; without a conversion, every label is today's, size
    /// included.
    func testAConvertedChoiceLabel() {
        let size = ByteCountFormatter.string(fromByteCount: 1_200_000, countStyle: .file)
        XCTAssertEqual(
            BookExportWording.choiceLabel(
                kind: .markdown, bookCount: 1, availableItemCount: 1, fileCount: 1, byteCount: 1_200_000,
                inCloudCount: 0, convertedTo: "HTML"
            ),
            "Text as HTML"
        )
        XCTAssertEqual(
            BookExportWording.choiceLabel(
                kind: .markdown, bookCount: 3, availableItemCount: 2, fileCount: 2, byteCount: 1_200_000,
                inCloudCount: 1, convertedTo: "RTF"
            ),
            "Text as RTF, 2 books, 1 book in the cloud"
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
    /// with the hints the user hears; no other kind has a picker. The first
    /// four choices are pinned exactly (Markdown and tonight's three
    /// writers); every choice after Markdown is then checked against
    /// `TextExportWriters.all`, so a writer added later is checked against
    /// itself and this test stays green.
    func testThePickersChoicesAreMarkdownThenEachWriter() {
        let model = BookExportModel(books: [])
        let choices = model.conversionChoices(for: .markdown)
        XCTAssertEqual(
            Array(choices.prefix(4)),
            [
                BookExportConversionChoice(
                    id: "markdown",
                    name: "Markdown",
                    hint: "The book's text as Markdown, with its headings, lists, and emphasis."
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
        // After Markdown, the choices are exactly the writers, in order.
        XCTAssertEqual(
            Array(choices.dropFirst()),
            TextExportWriters.all.map { BookExportConversionChoice(id: $0.id, name: $0.name, hint: $0.hint) }
        )
        for kind in BookExportKind.allCases where kind != .markdown {
            XCTAssertEqual(model.conversionChoices(for: kind), [], "\(kind) has no picker")
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
        XCTAssertEqual(model.label(for: markdownChoice), "Text as HTML", "a conversion says no size")
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

    /// Tonight's writers (HTML, RTF, and Word 97-2003) take no options, so no
    /// options view shows under the picker for Markdown or for any of them,
    /// checked or not. Only those three are checked: a writer added later may
    /// have options.
    func testNoOptionsViewShowsForTonightsWriters() async throws {
        let dialog = try await makeDialog("Export Convert Options")
        let model = dialog.model
        model.setChecked(true, for: .markdown)

        XCTAssertNil(model.optionsView(for: .markdown), "Markdown has no options")
        for id in ["html", "rtf", "doc"] {
            model.setConversionID(id, for: .markdown)
            XCTAssertEqual(model.conversionID(for: .markdown), id, "\(id) is chosen")
            XCTAssertNil(model.optionsView(for: .markdown), "\(id) has no options")
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

    /// With Markdown chosen, the export is the book's text written as
    /// Markdown (`MarkdownExportWriter`), without content.md's chapter
    /// markers or its escapes.
    func testExportingWithMarkdownChosenWritesTheBooksMarkdown() async throws {
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
            try String(contentsOf: dialog.folder.appendingPathComponent("\(stem) - Text.md"), encoding: .utf8),
            "# First\n\nOne two three.\n\n# Second\n\nFour five.\n"
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

    // MARK: - A Writer With Options

    /// A model given a writer of its own offers Markdown, then that writer,
    /// and shows the writer's options view only while the kind is checked and
    /// the writer chosen.
    func testAWriterWithOptionsShowsItsViewWhileChosenAndChecked() {
        let writer = OptionsTestWriter()
        let model = BookExportModel(books: [], writers: [writer])

        XCTAssertEqual(
            model.conversionChoices(for: .markdown).map(\.id),
            ["markdown", "options-test"],
            "the model offers the writers it was given"
        )
        model.setChecked(true, for: .markdown)
        XCTAssertNil(model.optionsView(for: .markdown), "Markdown has no options")

        model.setConversionID("options-test", for: .markdown)
        XCTAssertNotNil(model.optionsView(for: .markdown), "the writer chosen and the kind checked")

        model.setChecked(false, for: .markdown)
        XCTAssertNil(model.optionsView(for: .markdown), "the kind unchecked")

        model.setChecked(true, for: .markdown)
        model.setConversionID("markdown", for: .markdown)
        XCTAssertNil(model.optionsView(for: .markdown), "back on Markdown")
    }

    /// The dialog draws the writer's option as one more checkbox while the
    /// kind is checked and the writer chosen, and takes it away when the kind
    /// is unchecked.
    func testTheDialogDrawsTheWritersOptionsOnlyWhileChosenAndChecked() throws {
        let world = try makeIntegrationWorld("Export Convert Options Drawn")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let model = BookExportModel(
            books: [book],
            destination: try makeSandboxDirectory("Export Convert Options Drawn Folder"),
            writers: [OptionsTestWriter()]
        )

        withHostedView(BookExportSheet(model: model, close: {}), until: { self.checkboxes(in: $0).count == 3 }) { hostingView in
            model.setChecked(true, for: .markdown)
            XCTAssertTrue(waitUntil(timeout: 5) {
                hostingView.layoutSubtreeIfNeeded()
                return self.popUps(in: hostingView).count == 1
            }, "checking the kind draws the picker")
            let withMarkdown = checkboxes(in: hostingView).count
            XCTAssertEqual(withMarkdown, 3, "Markdown has no options to draw")

            model.setConversionID("options-test", for: .markdown)
            XCTAssertTrue(waitUntil(timeout: 5) {
                hostingView.layoutSubtreeIfNeeded()
                return self.checkboxes(in: hostingView).count == withMarkdown + 1
            }, "the writer chosen draws its option as one more checkbox")

            model.setChecked(false, for: .markdown)
            XCTAssertTrue(waitUntil(timeout: 5) {
                hostingView.layoutSubtreeIfNeeded()
                return self.checkboxes(in: hostingView).count == withMarkdown
            }, "unchecking the kind takes the option away")
        }
    }

    /// While an export runs, the writer's option is disabled with the
    /// checkboxes and the picker, and enabled again once the export ends.
    func testTheWritersOptionsAreDisabledWhileExporting() throws {
        let world = try makeIntegrationWorld("Export Convert Options Busy")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let folder = try makeSandboxDirectory("Export Convert Options Busy Folder")
        // The writer holds the export until the test lets it go (it gives up
        // after 10 seconds, so a failing test never hangs).
        let writer = OptionsTestWriter(holdsExport: true)
        let model = BookExportModel(books: [book], destination: folder, writers: [writer])
        let announcements = AnnouncementCapture()
        defer {
            writer.letGo()
            announcements.stop()
        }

        withHostedView(BookExportSheet(model: model, close: {}), until: { self.checkboxes(in: $0).count == 3 }) { hostingView in
            model.setChecked(false, for: .originalFile)
            model.setChecked(true, for: .markdown)
            model.setConversionID("options-test", for: .markdown)
            XCTAssertTrue(waitUntil(timeout: 5) {
                hostingView.layoutSubtreeIfNeeded()
                return self.optionCheckbox(in: hostingView)?.isEnabled == true
            }, "the option is drawn, and enabled while nothing is exported")
            XCTAssertTrue(model.choices.allSatisfy(\.isAvailable), "every kind is on this Mac")

            let export = Task { await model.export() }
            _ = export
            XCTAssertTrue(waitUntil(timeout: 10) { writer.hasStarted && model.isExporting }, "the export is under way")
            XCTAssertTrue(waitUntil(timeout: 5) {
                hostingView.layoutSubtreeIfNeeded()
                return self.optionCheckbox(in: hostingView)?.isEnabled == false
            }, "the option is disabled while the export runs")
            XCTAssertTrue(
                checkboxes(in: hostingView).allSatisfy { !$0.isEnabled },
                "so are the kinds' checkboxes"
            )

            writer.letGo()
            XCTAssertTrue(waitUntil(timeout: 10) { self.hasFinished(model) }, "the export ends")
            XCTAssertTrue(waitUntil(timeout: 5) {
                hostingView.layoutSubtreeIfNeeded()
                return self.optionCheckbox(in: hostingView)?.isEnabled == true
            }, "the option is enabled again once the export has ended")
        }
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: folder.path),
            ["\(BookExportService.fileNameStem(for: book.title)) - Text.tst"],
            "the export wrote the test writer's file"
        )
    }

    /// An option set in the drawn dialog reaches the writer's `write`: the
    /// writer is given the options as the user left them. SwiftUI gives its
    /// checkboxes no action a test can press, so the option is set through
    /// the binding the options view was given, which the checkbox sets when
    /// it is pressed; the drawn checkbox must then show it.
    func testTheOptionsSetInTheDialogReachTheWriter() throws {
        let world = try makeIntegrationWorld("Export Convert Options Reach")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md"))
        let folder = try makeSandboxDirectory("Export Convert Options Reach Folder")
        let probe = OptionsProbe()
        let writer = OptionsTestWriter(probe: probe)
        let model = BookExportModel(books: [book], destination: folder, writers: [writer])
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        withHostedView(BookExportSheet(model: model, close: {}), until: { self.checkboxes(in: $0).count == 3 }) { hostingView in
            model.setChecked(false, for: .originalFile)
            model.setChecked(true, for: .markdown)
            model.setConversionID("options-test", for: .markdown)
            XCTAssertTrue(waitUntil(timeout: 5) {
                hostingView.layoutSubtreeIfNeeded()
                return self.optionCheckbox(in: hostingView) != nil && probe.binding != nil
            }, "the option is drawn")
            XCTAssertEqual(optionCheckbox(in: hostingView)?.state, .off, "the option starts off")

            probe.binding?.wrappedValue.isOn = true
            XCTAssertEqual(
                model.conversions[.markdown],
                .text(TextExportConversion(writer, options: OptionsTestWriter.Options(isOn: true))),
                "setting the option changes the options the export will take"
            )
            XCTAssertTrue(waitUntil(timeout: 5) {
                hostingView.layoutSubtreeIfNeeded()
                return self.optionCheckbox(in: hostingView)?.state == .on
            }, "the drawn checkbox shows the option on")

            let export = Task { await model.export() }
            _ = export
            XCTAssertTrue(waitUntil(timeout: 10) { self.hasFinished(model) }, "the export ends")
        }
        XCTAssertEqual(writer.givenOptions, [OptionsTestWriter.Options(isOn: true)])
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

    /// The checkbox of the test writer's option inside `view`: the one drawn
    /// furthest right, since the options view is indented under its row while
    /// every kind's checkbox is at the left edge; nil while only the kinds'
    /// checkboxes are drawn.
    private func optionCheckbox(in view: NSView) -> NSButton? {
        /// Where the left edge of `box` is in `view`.
        func leftEdge(_ box: NSButton) -> CGFloat {
            box.convert(box.bounds, to: view).minX
        }
        let boxes = checkboxes(in: view)
        guard let furthest = boxes.max(by: { leftEdge($0) < leftEdge($1) }),
              let nearest = boxes.min(by: { leftEdge($0) < leftEdge($1) }),
              leftEdge(furthest) > leftEdge(nearest) + 1
        else { return nil }
        return furthest
    }

    /// Whether the export of `model` has ended.
    private func hasFinished(_ model: BookExportModel) -> Bool {
        if case .finished = model.phase { return true }
        return false
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

// MARK: - A Test Writer With Options

/// Keeps the binding a test writer's options view was last given, so a test
/// can set the option as the checkbox does.
@MainActor
private final class OptionsProbe {
    /// The binding of the options, as the options view last drew them.
    var binding: Binding<OptionsTestWriter.Options>?
}

/// A text writer of the tests' own, which has one option (a checkbox), writes
/// a short file, and records the options it was given. Given `holdsExport`,
/// its `write` waits, at most 10 seconds, until the test calls `letGo()`, so
/// a test can look at the dialog while an export runs and a failing test can
/// never hang.
private struct OptionsTestWriter: TextExportWriter {
    /// The writer's one option.
    struct Options: TextExportOptions {
        /// Whether the test option is on.
        var isOn = false
    }

    let id = "options-test"
    let name = "Test Writer"
    let hint = "A writer for tests."
    let fileExtension = "tst"

    /// Whether `write` waits for `letGo()`.
    let holdsExport: Bool
    /// Where the options view leaves its binding, if a test wants it.
    private let probe: OptionsProbe?
    /// Signalled by `letGo()`.
    private let release = DispatchSemaphore(value: 0)
    /// Whether `write` has begun.
    private let started = OSAllocatedUnfairLock(initialState: false)
    /// The options each `write` was given, in order.
    private let given = OSAllocatedUnfairLock(initialState: [Options]())

    /// A writer that holds its export while `holdsExport`, and leaves the
    /// options view's binding in `probe`.
    init(holdsExport: Bool = false, probe: OptionsProbe? = nil) {
        self.holdsExport = holdsExport
        self.probe = probe
    }

    /// Whether `write` has begun.
    var hasStarted: Bool {
        started.withLock { $0 }
    }

    /// The options each `write` was given.
    var givenOptions: [Options] {
        given.withLock { $0 }
    }

    /// Lets a held `write` go on.
    func letGo() {
        release.signal()
    }

    @MainActor func defaultOptions() -> Options {
        Options()
    }

    @MainActor func optionsView(_ options: Binding<Options>) -> some View {
        probe?.binding = options
        return Toggle("Test option", isOn: options.isOn)
            .toggleStyle(.checkbox)
            .accessibilityHint("A test option.")
    }

    /// Records `options`, says it has begun, waits when it holds the export,
    /// and writes a short file.
    func write(
        _ document: ExportDocument,
        options: Options,
        to url: URL,
        cancellation: BookExportCancellation
    ) throws {
        given.withLock { $0.append(options) }
        started.withLock { $0 = true }
        if holdsExport {
            _ = release.wait(timeout: .now() + 10)
        }
        try Data("test writer file".utf8).write(to: url)
    }
}
