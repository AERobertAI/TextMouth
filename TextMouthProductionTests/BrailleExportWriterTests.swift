import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The BRF and PEF writers of the Export dialog (FMT22, Phase B) with the
/// real liblouis helper: the braille blocks the export model makes, the two
/// writers' files, their options and the options view, the writers'
/// registration and cancellation, and the round trips through the dialog's
/// own path (a book exported, then the file imported again).
@MainActor
final class BrailleExportWriterTests: XCTestCase {

    // MARK: - Blocks

    /// A document with a title heading, headings of levels 1 to 3, a
    /// paragraph with emphasis and a link, an ordered list from 3 with an
    /// unordered list inside it, a quote, a two-line code block, a table, and
    /// a thematic break gives exactly the blocks the rules say, depths
    /// included: the paragraph's plain text only, the ordered items numbered,
    /// the unordered items not, and nothing for the break.
    func testBlocksOfAHandBuiltDocument() {
        let inner = ExportList(
            isOrdered: false, start: 1, depth: 1,
            items: [ExportListItem(blocks: [.paragraph([ExportRun("Xray")])]), ExportListItem(blocks: [.paragraph([ExportRun("Yankee")])])]
        )
        let outer = ExportList(
            isOrdered: true, start: 3, depth: 0,
            items: [
                ExportListItem(blocks: [.paragraph([ExportRun("Alpha")]), .list(inner)]),
                ExportListItem(blocks: [.paragraph([ExportRun("Bravo")])]),
            ]
        )
        let document = ExportDocument(
            book: ExportBookDetails(title: "Harbour Notes"),
            titleHeading: heading(1, "Harbour Notes"),
            blocks: [
                .heading(heading(1, "Part One")),
                .heading(heading(2, "Chapter")),
                .heading(heading(3, "Section")),
                .paragraph([
                    ExportRun("A "), ExportRun("sharp", isEmphasis: true), ExportRun(" turn, see "),
                    ExportRun("the chart", link: "https://example.org/chart"), ExportRun("."),
                ]),
                .list(outer),
                .blockQuote([.paragraph([ExportRun("Quoted words")])]),
                .codeBlock("first line\n\nsecond line"),
                .table(ExportTable(rows: [["Name", "Depth"], ["Pier", "4"]], hasHeaderRow: true)),
                .thematicBreak,
            ]
        )

        XCTAssertEqual(BrailleExportBlocks.blocks(of: document), [
            .heading(level: 1, text: "Harbour Notes"),
            .heading(level: 1, text: "Part One"),
            .heading(level: 2, text: "Chapter"),
            .heading(level: 3, text: "Section"),
            .paragraph(text: "A sharp turn, see the chart."),
            .listItem(depth: 1, text: "3. Alpha"),
            .listItem(depth: 2, text: "Xray"),
            .listItem(depth: 2, text: "Yankee"),
            .listItem(depth: 1, text: "4. Bravo"),
            .paragraph(text: "Quoted words"),
            .paragraph(text: "first line"),
            .paragraph(text: "second line"),
            .paragraph(text: "Name; Depth"),
            .paragraph(text: "Pier; 4"),
        ])
    }

    /// An empty document has no blocks. A numbered item that begins with a
    /// list or a heading keeps its number on a line of its own, a list in a
    /// numbered list is numbered from its own start at its own depth, and the
    /// text of a quote or a code block inside an item is the item's.
    func testNumbersAndTheTextInsideAnItem() {
        XCTAssertEqual(BrailleExportBlocks.blocks(of: ExportDocument(book: ExportBookDetails(title: "x"), blocks: [])), [])

        let nested = ExportList(
            isOrdered: true, start: 7, depth: 1,
            items: [ExportListItem(blocks: [.paragraph([ExportRun("Deep")])])]
        )
        let quoteInside = ExportListItem(blocks: [
            .blockQuote([.paragraph([ExportRun("Said")])]), .codeBlock("code one\ncode two"),
        ])
        let list = ExportList(
            isOrdered: true, start: 1, depth: 0,
            items: [
                ExportListItem(blocks: [.list(nested)]),
                ExportListItem(blocks: [.heading(heading(2, "Inside")), .paragraph([ExportRun("After")])]),
                quoteInside,
            ]
        )
        let document = ExportDocument(book: ExportBookDetails(title: "x"), blocks: [.list(list)])

        XCTAssertEqual(BrailleExportBlocks.blocks(of: document), [
            .listItem(depth: 1, text: "1."),
            .listItem(depth: 2, text: "7. Deep"),
            .listItem(depth: 1, text: "2."),
            .heading(level: 2, text: "Inside"),
            .listItem(depth: 1, text: "After"),
            .listItem(depth: 1, text: "3. Said"),
            .listItem(depth: 1, text: "code one"),
            .listItem(depth: 1, text: "code two"),
        ])
    }

    // MARK: - The Writers

    /// The BRF of the Pride and Prejudice sample, walked from Markdown, is
    /// exactly what `BrailleDocumentWriter` writes for the blocks of the
    /// document, at 40 by 25 with the Grade 1 table, and leaves the working
    /// folder holding that one file.
    func testTheBRFWriterWritesWhatTheDocumentWriterWrites() throws {
        let document = try prideDocument()
        let blocks = BrailleExportBlocks.blocks(of: document)
        // The title, the chapter heading, and 12 paragraphs, with the
        // sample's text but for Markdown's reading of _You_ as emphasis.
        XCTAssertEqual(blocks.count, 14)
        let texts = try prideTexts().map { $0.replacingOccurrences(of: "_You_", with: "You") }
        XCTAssertEqual(blocks.map(\.text), texts)
        XCTAssertEqual(blocks.first, .heading(level: 1, text: "Pride and Prejudice"))

        let options = BrailleExportOptions(table: "en-ueb-g1.ctb")
        let folder = try makeSandboxDirectory("BrailleExportBRF")
        let url = folder.appendingPathComponent("book.brf")
        try BRFExportWriter().write(document, options: options, to: url, cancellation: BookExportCancellation())

        let expected = try BrailleDocumentWriter.brf(of: blocks, options: options, workingIn: folder)
        let written = try Data(contentsOf: url)
        XCTAssertFalse(written.isEmpty)
        XCTAssertEqual(written, expected)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["book.brf"])
    }

    /// The PEF has the book's title, author, and language, a `urn:uuid:`
    /// identifier, and today's date, and holds the pages the BRF's blocks
    /// make.
    func testThePEFWriterWritesTheBooksMetadataAndPages() throws {
        let document = try prideDocument(language: "en-GB")
        let options = BrailleExportOptions(table: "en-ueb-g1.ctb")
        let folder = try makeSandboxDirectory("BrailleExportPEF")
        let url = folder.appendingPathComponent("book.pef")
        // The day the file was made lies between these two, so a write at
        // midnight cannot fail the test.
        let before = PEFExportWriter.dayString(of: Date())
        try PEFExportWriter().write(document, options: options, to: url, cancellation: BookExportCancellation())
        let after = PEFExportWriter.dayString(of: Date())

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("<dc:title>Pride and Prejudice</dc:title>"))
        XCTAssertTrue(text.contains("<dc:creator>Jane Austen</dc:creator>"))
        XCTAssertTrue(text.contains("<dc:language>en-GB</dc:language>"))
        XCTAssertTrue(
            text.contains("<dc:date>\(before)</dc:date>") || text.contains("<dc:date>\(after)</dc:date>"),
            "no date of \(before) in the file"
        )
        let identifierPattern = #"<dc:identifier>urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}</dc:identifier>"#
        XCTAssertNotNil(text.range(of: identifierPattern, options: .regularExpression))
        let pages = try BrailleDocumentWriter.pef(
            of: BrailleExportBlocks.blocks(of: document),
            metadata: PEFExportWriter.metadata(of: document.book), options: options, workingIn: folder
        )
        // The same pages, whatever the identifier and date.
        XCTAssertEqual(
            text.components(separatedBy: "<page>").count, String(decoding: pages, as: UTF8.self).components(separatedBy: "<page>").count
        )
        XCTAssertTrue(text.contains(#"cols="40" rows="25""#))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["book.pef"])
    }

    /// The metadata names an unknown author as nothing and an unknown
    /// language as English, makes a new identifier each time, and writes the
    /// date as yyyy-MM-dd in the Gregorian calendar.
    func testThePEFMetadataDefaultsAndDate() throws {
        let book = ExportBookDetails(title: "Harbour Pilots")
        let first = PEFExportWriter.metadata(of: book)
        let second = PEFExportWriter.metadata(of: book)
        XCTAssertEqual(first.title, "Harbour Pilots")
        XCTAssertEqual(first.author, "")
        XCTAssertEqual(first.language, "en")
        XCTAssertTrue(first.identifier.hasPrefix("urn:uuid:"))
        XCTAssertNotEqual(first.identifier, second.identifier)
        XCTAssertNotNil(UUID(uuidString: String(first.identifier.dropFirst("urn:uuid:".count))))

        // A fixed day, made in the Mac's own time zone so it reads the same.
        let gregorian = Calendar(identifier: .gregorian)
        let day = try XCTUnwrap(gregorian.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12)))
        XCTAssertEqual(PEFExportWriter.dayString(of: day), "2026-03-09")
        XCTAssertEqual(first.date.count, 10)
    }

    /// An unknown table fails with the translator's sentence as a
    /// `TextExportError`, so the dialog says what stopped it, and leaves no
    /// file and no hidden file behind.
    func testATranslatorFailureBecomesTheExportsSentence() throws {
        let document = try prideDocument()
        let folder = try makeSandboxDirectory("BrailleExportFailure")
        let options = BrailleExportOptions(table: "en-xx.ctb")
        for (writer, name) in [(AnyBrailleWriter(BRFExportWriter()), "book.brf"), (AnyBrailleWriter(PEFExportWriter()), "book.pef")] {
            XCTAssertThrowsError(
                try writer.write(document, options, folder.appendingPathComponent(name), BookExportCancellation())
            ) {
                XCTAssertEqual(
                    $0 as? TextExportError,
                    TextExportError("TextMouth has no braille table named \u{201C}en-xx.ctb\u{201D}.")
                )
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    /// A file already at the planned place is an error and is left as it
    /// was.
    func testAnExistingFileIsNeverReplaced() throws {
        let document = try prideDocument()
        let folder = try makeSandboxDirectory("BrailleExportExisting")
        let url = folder.appendingPathComponent("book.brf")
        try Data("mine".utf8).write(to: url)
        XCTAssertThrowsError(
            try BRFExportWriter().write(
                document, options: BrailleExportOptions(table: "en-ueb-g1.ctb"), to: url, cancellation: BookExportCancellation()
            )
        )
        XCTAssertEqual(try Data(contentsOf: url), Data("mine".utf8))
    }

    /// A cancelled export makes the writers throw `CancellationError` and
    /// write nothing.
    func testACancelledExportWritesNothing() throws {
        let document = try prideDocument()
        let folder = try makeSandboxDirectory("BrailleExportCancelled")
        let cancellation = BookExportCancellation()
        cancellation.cancel()
        let options = BrailleExportOptions(table: "en-ueb-g1.ctb")
        for (writer, name) in [(AnyBrailleWriter(BRFExportWriter()), "book.brf"), (AnyBrailleWriter(PEFExportWriter()), "book.pef")] {
            XCTAssertThrowsError(try writer.write(document, options, folder.appendingPathComponent(name), cancellation)) {
                XCTAssertTrue($0 is CancellationError, "\($0)")
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [])
    }

    // MARK: - Registration and Wording

    /// The registry lists BRF and PEF after Word 97-2003, and finds both by
    /// their ids, with the names, hints, and extensions the picker shows.
    func testTheWritersAreRegisteredAfterWord() throws {
        let ids = TextExportWriters.all.map(\.id)
        XCTAssertEqual(Array(ids.suffix(3)), ["doc", "brf", "pef"])
        let brf = try XCTUnwrap(TextExportWriters.writer(id: "brf"))
        let pef = try XCTUnwrap(TextExportWriters.writer(id: "pef"))
        XCTAssertEqual([brf.name, pef.name], ["BRF", "PEF"])
        XCTAssertEqual([brf.fileExtension, pef.fileExtension], ["brf", "pef"])
        XCTAssertEqual(brf.hint, "Braille Ready Format: pages of braille ASCII, for braille displays and embossers.")
        XCTAssertEqual(pef.hint, "Portable Embosser Format: pages of Unicode braille in XML, for embossers.")
        // Both take braille options, which the dialog keeps and draws.
        XCTAssertTrue(TextExportWriters.optionsState(for: brf).hasOptions)
        XCTAssertTrue(TextExportWriters.optionsState(for: pef).hasOptions)
    }

    /// Each sentence the options view shows or speaks, pinned exactly.
    func testEveryWordingConstantIsPinned() {
        XCTAssertEqual(BrailleExportWording.languageHint, "The language of the braille code the book is written in.")
        XCTAssertEqual(BrailleExportWording.codeHint, "The braille code the book is written in.")
        XCTAssertEqual(BrailleExportWording.contractionHint, "Whether that code's braille is contracted.")
        XCTAssertEqual(BrailleExportWording.cellsLabel, "Cells per line")
        XCTAssertEqual(BrailleExportWording.cellsHint, "How many braille cells each line holds, from 18 to 80.")
        XCTAssertEqual(BrailleExportWording.cellsValue(40), "40 cells")
        XCTAssertEqual(BrailleExportWording.linesLabel, "Lines per page")
        XCTAssertEqual(BrailleExportWording.linesHint, "How many lines each braille page holds, from 4 to 50.")
        XCTAssertEqual(BrailleExportWording.linesValue(25), "25 lines")
        XCTAssertEqual(BrailleExportWording.numbersLabel, "Braille page numbers")
        XCTAssertEqual(BrailleExportWording.numbersHint, "Whether each page's last line carries its braille page number.")
        XCTAssertEqual(BrailleExportWording.lineEndsLabel, "Line ends")
        XCTAssertEqual(BrailleExportWording.lineEndsHint, "CR LF suits most braille displays and embossers.")
        XCTAssertEqual(BrailleExportWording.name(of: .crlf), "CR LF")
        XCTAssertEqual(BrailleExportWording.name(of: .lf), "LF")
        // The ranges the hints state are the layout's.
        XCTAssertEqual(BraillePageFormat.cellsPerLineRange, 18...80)
        XCTAssertEqual(BraillePageFormat.linesPerPageRange, 4...50)
    }

    /// The Export dialog's two buttons say what they do now that Export
    /// converts as well as copies, and that Stop keeps no part of the file
    /// being made.
    func testTheExportAndStopHintsAreCurrent() {
        XCTAssertEqual(BookExportWording.exportHint, "Exports the checked items to the folder.")
        XCTAssertEqual(
            BookExportWording.exportWaitsHint,
            "Exports the checked items to the folder once the braille table just chosen has been checked."
        )
        XCTAssertEqual(BookExportWording.stopHint, "Stops the export. The file being made is not kept.")
    }

    // MARK: - Options

    /// The writers start from the user's October 17 defaults with the
    /// Braille setting's table.
    func testDefaultOptionsTakeTheSettingsTable() {
        BraillePreferences.$tableForImports.withValue("en-us-g1.ctb") {
            for options in [BRFExportWriter().defaultOptions(), PEFExportWriter().defaultOptions()] {
                XCTAssertEqual(options.table, "en-us-g1.ctb")
                XCTAssertEqual(options.page, BraillePageFormat(cellsPerLine: 40, linesPerPage: 25, numbersPages: true))
                XCTAssertEqual(options.lineEnd, .crlf)
            }
        }
    }

    // MARK: - The Options View

    /// A BRF's options view has the three table pop-ups, the line ends pop-up,
    /// the two steppers saying their numbers with units, and the page numbers
    /// checkbox, each by its label with its hint exactly.
    func testTheBRFOptionsViewIsLabelledAndHinted() throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        let box = OptionsBox(BrailleExportOptions(table: "en-ueb-g2.ctb"))
        try withOptionsView(box, choosesLineEnds: true, popUps: 4) { hosting in
            let controls = accessibleControls(in: hosting)
            XCTAssertEqual(try control(labelled: "Language", in: controls).hint, "The language of the braille code the book is written in.")
            XCTAssertEqual(try control(labelled: "Braille code", in: controls).hint, "The braille code the book is written in.")
            XCTAssertEqual(try control(labelled: "Contraction", in: controls).hint, "Whether that code's braille is contracted.")
            let cells = try control(labelled: "Cells per line", in: controls)
            XCTAssertEqual(cells.role, .incrementor)
            XCTAssertEqual(cells.valueDescription, "40 cells")
            XCTAssertEqual(cells.hint, "How many braille cells each line holds, from 18 to 80.")
            let lines = try control(labelled: "Lines per page", in: controls)
            XCTAssertEqual(lines.role, .incrementor)
            XCTAssertEqual(lines.valueDescription, "25 lines")
            XCTAssertEqual(lines.hint, "How many lines each braille page holds, from 4 to 50.")
            XCTAssertEqual(try control(labelled: "Line ends", in: controls).hint, "CR LF suits most braille displays and embossers.")
            // The check box must be there. SwiftUI draws it as an AppKit
            // button (not a pop-up), but gives it its label, hint, and value
            // to the accessibility tree only for a connected assistive app,
            // so a session that lists the dialog's other controls may not
            // list it. A check box missing from the view fails the test
            // either way; where the tree lists it, its words are checked too
            // (the wording itself is pinned by the wording test above).
            let checkBoxes = descendants(of: hosting, as: NSButton.self).filter { !($0 is NSPopUpButton) }
            XCTAssertEqual(checkBoxes.count, 1, "the view should draw one check box: \(checkBoxes)")
            // Page numbers are on by default.
            XCTAssertEqual(checkBoxes.first?.state, .on)
            if let numbers = controls.first(where: { $0.role == .checkBox && $0.label == "Braille page numbers" }) {
                XCTAssertEqual(numbers.hint, "Whether each page's last line carries its braille page number.")
                XCTAssertEqual((numbers.element.accessibilityValue() as? NSNumber)?.boolValue, true)
            }
        }
    }

    /// A PEF's options view has everything but the line ends pop-up: only
    /// the language, code, and contraction pop-ups.
    func testThePEFOptionsViewHasNoLineEnds() throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        let box = OptionsBox(BrailleExportOptions(table: "en-ueb-g2.ctb"))
        try withOptionsView(box, choosesLineEnds: false, popUps: 3) { hosting in
            let controls = accessibleControls(in: hosting)
            XCTAssertFalse(controls.contains { $0.label == "Line ends" }, "\(controls.map(\.label))")
            _ = try control(labelled: "Braille code", in: controls)
            _ = try control(labelled: "Cells per line", in: controls)
            XCTAssertEqual(descendants(of: hosting, as: NSPopUpButton.self).count, 3)
        }
    }

    /// The pop-ups show the table's code and contraction and offer what the
    /// bundle has; choosing a code, a contraction, or a line end sets the
    /// options, as the Braille tab does, and a stepper raised as VoiceOver
    /// raises it sets its number.
    func testTheControlsSetTheOptions() throws {
        // The steppers are read through the accessibility tree, which a CI
        // runner does not expose: skip there, as the other hosted checks do.
        try skipUnlessHostedWindowsExposeAccessibility()
        let box = OptionsBox(BrailleExportOptions(table: "en-ueb-g2.ctb"))
        try withOptionsView(box, choosesLineEnds: true, popUps: 4) { hosting in
            let found = descendants(of: hosting, as: NSPopUpButton.self)
            XCTAssertEqual(found.count, 4)
            guard found.count == 4 else { return }
            // In reading order: language, code, contraction, line ends.
            let (language, code, contraction, lineEnds) = (found[0], found[1], found[2], found[3])
            XCTAssertEqual(language.itemTitles, [Locale.current.localizedString(forIdentifier: "en") ?? "en"])
            XCTAssertEqual(code.titleOfSelectedItem, "Unified English Braille")
            XCTAssertEqual(code.itemTitles, ["English Braille, American Edition", "Unified English Braille"])
            XCTAssertEqual(contraction.titleOfSelectedItem, "Contracted (Grade 2)")
            XCTAssertEqual(contraction.itemTitles, ["Uncontracted (Grade 1)", "Contracted (Grade 2)"])
            XCTAssertEqual(lineEnds.itemTitles, ["CR LF", "LF"])
            XCTAssertEqual(lineEnds.titleOfSelectedItem, "CR LF")

            // The American code, keeping the contraction.
            code.menu?.performActionForItem(at: 0)
            XCTAssertTrue(waitUntil { box.options.table == "en_US.tbl" }, "the table is \(box.options.table)")
            // The pop-ups follow: the code is the American one, still contracted.
            XCTAssertTrue(waitUntil {
                hosting.layoutSubtreeIfNeeded()
                let now = self.descendants(of: hosting, as: NSPopUpButton.self)
                return now.count == 4 && now[1].titleOfSelectedItem == "English Braille, American Edition"
                    && now[2].titleOfSelectedItem == "Contracted (Grade 2)"
            })
            // Then its Grade 1 table.
            let next = descendants(of: hosting, as: NSPopUpButton.self)
            guard next.count == 4 else { return XCTFail("\(next.count) pop-ups") }
            next[2].menu?.performActionForItem(at: 0)
            XCTAssertTrue(waitUntil { box.options.table == "en-us-g1.ctb" }, "the table is \(box.options.table)")

            // The line end.
            let again = descendants(of: hosting, as: NSPopUpButton.self)
            guard again.count == 4 else { return XCTFail("\(again.count) pop-ups") }
            again[3].menu?.performActionForItem(at: 1)
            XCTAssertTrue(waitUntil { box.options.lineEnd == .lf })

            // The steppers, raised once each, as VoiceOver raises them.
            let controls = accessibleControls(in: hosting)
            XCTAssertFalse(controls.isEmpty)
            _ = try control(labelled: "Cells per line", in: controls).element.accessibilityPerformIncrement()
            _ = try control(labelled: "Lines per page", in: controls).element.accessibilityPerformIncrement()
            XCTAssertTrue(waitUntil { box.options.page.cellsPerLine == 41 && box.options.page.linesPerPage == 26 })
            // The value spoken follows the number.
            XCTAssertTrue(waitUntil {
                let now = self.accessibleControls(in: hosting)
                return now.first { $0.label == "Cells per line" }?.valueDescription == "41 cells"
                    && now.first { $0.label == "Lines per page" }?.valueDescription == "26 lines"
            })
        }
    }

    // MARK: - Round Trips

    /// Decision 15: a book of the Grade 2 sample's three sentences, each its
    /// own paragraph, exported to BRF through the dialog's own path (the
    /// export service with the writer chosen and its options) and imported
    /// again, reads as its heading and the three sentences. Liblouis reads
    /// the contractions back as the print it was given (the table is the one
    /// the sample was written with).
    func testTheGrade2BookSurvivesTheRoundTrip() throws {
        let sentences = try String(contentsOf: formatSampleURL("brf/grade2-short.txt"), encoding: .utf8)
            .components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(sentences.count, 3)
        let markdown = "# Grade Two Sample\n\n" + sentences.joined(separator: "\n\n") + "\n"
        let table = "en-ueb-g2.ctb"
        let conversion = BookExportConversion.text(
            TextExportConversion(BRFExportWriter(), options: BrailleExportOptions(table: table))
        )
        let imported = try roundTrip(markdown: markdown, conversion: conversion, table: table)
        XCTAssertEqual(imported, ["Grade Two Sample"] + sentences)
    }

    /// M6 through the dialog's path: a book whose paragraphs are Москва,
    /// 中文, and a smiling face, which the table has no braille for, exports
    /// to BRF and to PEF and imports again from each: neither import is
    /// refused (the eight-dot cell of liblouis's escape backslash is written
    /// as six dots), and both read as the heading and the texts
    /// `BrailleDocumentWriterTests` pins for these three paragraphs, which
    /// are liblouis's reading of its own escape notation, not the print.
    func testTextTheTableCannotWriteSurvivesTheRoundTrip() throws {
        let markdown = "# Odd Scripts\n\nМосква\n\n中文\n\n\u{1F642}\n"
        let table = "en-ueb-g2.ctb"
        // The widest page, so that no paragraph wraps: a wrapped row would
        // be read back with a break in it.
        var options = BrailleExportOptions(table: table)
        options.page = BraillePageFormat(cellsPerLine: BraillePageFormat.cellsPerLineRange.upperBound)
        let expected = [
            "Odd Scripts",
            "'oux\"diseac''oux\"discce''oux\"dis.,''oux\"discca''oux\"disccbb''oux\".:\"'",
            "'oux.ebbd''ouxffen?\u{2032}'",
            "'ouyeaf!.be'",
        ]
        let conversions: [(name: String, conversion: BookExportConversion)] = [
            ("BRF", .text(TextExportConversion(BRFExportWriter(), options: options))),
            ("PEF", .text(TextExportConversion(PEFExportWriter(), options: options))),
        ]
        for (name, conversion) in conversions {
            XCTAssertEqual(try roundTrip(markdown: markdown, conversion: conversion, table: table), expected, name)
        }
    }

    // MARK: - Helpers

    /// A heading of `level` and `text` for a hand-built document.
    private func heading(_ level: Int, _ text: String) -> ExportHeading {
        ExportHeading(level: level, runs: [ExportRun(text)], id: "h-\(level)-\(text.count)")
    }

    /// The 14 print blocks of the Pride and Prejudice sample: the title, the
    /// heading, and 12 paragraphs, split at blank lines.
    private func prideTexts() throws -> [String] {
        let texts = try String(contentsOf: formatSampleURL("brf/pride-and-prejudice-ch1.txt"), encoding: .utf8)
            .trimmingCharacters(in: .newlines)
            .components(separatedBy: "\n\n")
        XCTAssertEqual(texts.count, 14)
        return texts
    }

    /// The sample as the walker makes it from Markdown: `# title`, `##
    /// chapter`, then the 12 paragraphs, of a book by Jane Austen.
    private func prideDocument(language: String? = nil) throws -> ExportDocument {
        let texts = try prideTexts()
        guard texts.count >= 2 else { throw XCTSkip("the sample has too few blocks") }
        let markdown = "# \(texts[0])\n\n## \(texts[1])\n\n" + texts.dropFirst(2).joined(separator: "\n\n") + "\n"
        return try ExportDocumentWalker.document(
            fromMarkdown: markdown,
            book: ExportBookDetails(title: texts[0], author: "Jane Austen", language: language)
        )
    }

    /// The text blocks of the book `markdown` makes, exported to a file
    /// through the export service with `conversion` chosen, then imported
    /// again with `table` as the Braille setting: the blocks the reader shows
    /// (blank lines left out).
    private func roundTrip(markdown: String, conversion: BookExportConversion, table: String) throws -> [String] {
        let world = try makeIntegrationWorld("Braille Export Round Trip")
        let source = try makeSandboxDirectory("Braille Export Source").appendingPathComponent("Round Trip.md")
        try Data(markdown.utf8).write(to: source)
        let book = try world.importBook(from: source)
        let destination = try makeSandboxDirectory("Braille Export Destination")

        let outcome = BookExportService.export(
            [BookExportService.offer(for: book)], kinds: [.markdown], conversions: [.markdown: conversion], to: destination
        )
        XCTAssertEqual(outcome.failures, [])
        XCTAssertEqual(outcome.exported.count, 1)
        guard let file = outcome.exported.first else { return [] }
        XCTAssertEqual(file.pathExtension, conversion.fileExtension)

        let reimported = try BraillePreferences.$tableForImports.withValue(table) {
            try importedForTest(file).book
        }
        XCTAssertEqual(reimported.format, .braille)
        return allText(of: try openedContent(of: reimported))
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Hosts the options view at the dialog's width until it has drawn
    /// `popUps` pop-up buttons, and passes the hosting view to `body`.
    private func withOptionsView(
        _ box: OptionsBox, choosesLineEnds: Bool, popUps: Int, _ body: (NSView) throws -> Void
    ) throws {
        let size = NSSize(width: 520, height: 320)
        let view = OptionsHarness(box: box, choosesLineEnds: choosesLineEnds).frame(width: size.width, height: size.height)
        try withHostedView(
            view, size: size,
            until: { self.descendants(of: $0, as: NSPopUpButton.self).count == popUps }
        ) { hosting in
            try body(hosting)
        }
    }
}

// MARK: - Test Support

/// The options a hosted options view sets, observable so the view redraws.
@MainActor
private final class OptionsBox: ObservableObject {
    /// The options as the view last set them.
    @Published var options: BrailleExportOptions

    init(_ options: BrailleExportOptions) {
        self.options = options
    }
}

/// The options view bound to a box, offering only the bundled codes, so
/// the pop-ups list the same items on any Mac, whatever tables it has.
private struct OptionsHarness: View {
    @ObservedObject var box: OptionsBox
    let choosesLineEnds: Bool

    var body: some View {
        BrailleExportOptionsView(options: $box.options, choosesLineEnds: choosesLineEnds, codes: BrailleTableCatalog.bundledCodes)
    }
}

/// A BRF or PEF writer, its type forgotten so a test loops over both.
private struct AnyBrailleWriter {
    /// The writer's `write`, with the arguments in the order the writers take them.
    let write: (ExportDocument, BrailleExportOptions, URL, BookExportCancellation) throws -> Void

    init<Writer: TextExportWriter>(_ writer: Writer) where Writer.Options == BrailleExportOptions {
        write = { document, options, url, cancellation in
            try writer.write(document, options: options, to: url, cancellation: cancellation)
        }
    }
}
