import XCTest
@testable import TextMouth

/// `PhoneExportOffer`: which kinds the iPhone's Export sheet offers, what
/// fills its list, which buttons its bar holds at each stage in which order,
/// and what its folder row says, all in the Mac's words (FR31).
final class PhoneExportOfferTests: XCTestCase {

    // MARK: - The Kinds

    /// The iPhone offers every kind the Mac does, spoken audio included since phase 2.
    func testTheIPhoneOffersEveryKind() {
        XCTAssertEqual(PhoneExportOffer.kinds, Set(BookExportKind.allCases))
        XCTAssertTrue(PhoneExportOffer.kinds.contains(.spokenAudio))
        XCTAssertTrue(PhoneExportOffer.kinds.isSuperset(of: [.originalFile, .markdown, .plainText, .audio, .headings, .bookmarks, .transcript]))
    }

    // MARK: - The Stages

    /// Each phase of the model is one stage of the sheet.
    func testEachPhaseOfTheModelIsAStage() {
        let outcome = BookExportOutcome(destination: URL(fileURLWithPath: "/Users/reader/Exports"))

        XCTAssertEqual(PhoneExportOffer.Stage(.listing), .listing)
        XCTAssertEqual(PhoneExportOffer.Stage(.ready), .ready)
        XCTAssertEqual(PhoneExportOffer.Stage(.exporting(done: 2, total: 5)), .exporting)
        XCTAssertEqual(PhoneExportOffer.Stage(.finished(outcome)), .finished)
    }

    /// The list says it is finding what can be exported while the books are
    /// listed, says there is nothing when no kind is offered, and otherwise
    /// shows the kinds, at every stage after the listing.
    func testWhatFillsTheList() {
        XCTAssertEqual(PhoneExportOffer.content(stage: .listing, kindCount: 0), .listing)
        XCTAssertEqual(PhoneExportOffer.content(stage: .listing, kindCount: 3), .listing)
        for stage in [PhoneExportOffer.Stage.ready, .exporting, .finished] {
            XCTAssertEqual(PhoneExportOffer.content(stage: stage, kindCount: 0), .nothingToExport, "\(stage)")
            XCTAssertEqual(PhoneExportOffer.content(stage: stage, kindCount: 3), .kinds, "\(stage)")
        }
    }

    // MARK: - The Bar

    /// Before an export the bar holds Cancel then Export, with Export's hint,
    /// the Mac's, and Export dimmed until it can be pressed.
    func testTheBarBeforeAnExport() {
        for stage in [PhoneExportOffer.Stage.listing, .ready] {
            let dimmed = PhoneExportOffer.bar(stage: stage, canExport: false).buttons
            XCTAssertEqual(dimmed.map(\.role), [.cancel, .export])
            XCTAssertEqual(dimmed.map(\.title), ["Cancel", "Export"])
            XCTAssertEqual(dimmed.map(\.hint), ["", "Exports the checked items to the folder."])
            XCTAssertEqual(dimmed.map(\.isEnabled), [true, false])

            let ready = PhoneExportOffer.bar(stage: stage, canExport: true).buttons
            XCTAssertEqual(ready.map(\.isEnabled), [true, true])
        }
    }

    /// While an export runs, Stop takes Cancel's place with the Mac's hint,
    /// and Export is dimmed whatever else is so.
    func testTheBarWhileAnExportRuns() {
        let bar = PhoneExportOffer.bar(stage: .exporting, canExport: false).buttons

        XCTAssertEqual(bar.map(\.role), [.stop, .export])
        XCTAssertEqual(bar.map(\.title), ["Stop", "Export"])
        XCTAssertEqual(bar.first?.hint, "Stops the export. The file being made is not kept.")
        XCTAssertEqual(bar.map(\.isEnabled), [true, false])
    }

    /// Once an export has ended, Close takes Cancel's place, so the sheet,
    /// which stays open to say what the export did, can be closed, and a
    /// second export can be made from it.
    func testTheBarOnceAnExportHasEnded() {
        let bar = PhoneExportOffer.bar(stage: .finished, canExport: true).buttons

        XCTAssertEqual(bar.map(\.role), [.close, .export])
        XCTAssertEqual(bar.map(\.title), ["Close", "Export"])
        XCTAssertEqual(bar.map(\.isEnabled), [true, true])
    }

    // MARK: - The Folder Row

    /// The folder row reads "Choose Folder…" until a folder is chosen, then
    /// "Export to:" and the folder's name, with the Mac's hint either way.
    func testTheFolderRow() {
        let none = PhoneExportOffer.folderRow(folderName: nil)
        XCTAssertEqual(none.label, "Choose Folder…")
        XCTAssertEqual(none.hint, "Chooses the folder the checked items are exported to.")

        let chosen = PhoneExportOffer.folderRow(folderName: "Downloads")
        XCTAssertEqual(chosen.label, "Export to: Downloads")
        XCTAssertEqual(chosen.hint, none.hint)
    }

    // MARK: - The Braille Rows

    /// A BRF's rows are the Mac's six, in the Mac's order, each with its label, its value, and its hint: the sheet reads
    /// these three from each row and draws nothing else, so this is what VoiceOver says.
    func testABRFsBrailleRowsSayTheirLabelsValuesAndHints() {
        var options = BrailleExportOptions()
        options.page.cellsPerLine = 32
        options.page.linesPerPage = 20
        options.lineEnd = .lf

        let rows = PhoneExportOffer.brailleRows(options, choosesLineEnds: true)

        XCTAssertEqual(
            rows.map(\.label),
            ["Braille code", "Cells per line", "Lines per page", "Braille page numbers", "Line ends", "Braille file characters"]
        )
        XCTAssertEqual(
            rows.map(\.control),
            [.choice(.code), .cellsPerLine, .linesPerPage, .pageNumbers, .choice(.lineEnds), .choice(.fileCode)]
        )
        XCTAssertEqual(rows.map(\.hint), [
            "The braille code the book is written in.",
            "How many braille cells each line holds, from 18 to 80.",
            "How many lines each braille page holds, from 4 to 50.",
            "Whether each page's last line carries its braille page number.",
            "CR LF suits most braille displays and embossers.",
            BrailleExportWording.fileCodeHint
        ])
        XCTAssertTrue(rows.first?.value?.hasPrefix("Unified English Braille") == true, "The code says \(String(describing: rows.first?.value))")
        // After the code: the cells, the lines, nothing for the switch (which says its own value), the line end, the file characters.
        XCTAssertEqual(rows.dropFirst().map(\.value), ["32 cells", "20 lines", nil, "LF", "North American Braille ASCII"])
        XCTAssertTrue(rows.allSatisfy { !$0.hint.isEmpty }, "A braille row has no hint")
    }

    /// A PEF's rows stop after the page numbers: it has no line ends or braille file characters.
    func testAPEFsBrailleRowsLeaveOutTheLineEndsAndTheFileCharacters() {
        let rows = PhoneExportOffer.brailleRows(BrailleExportOptions(), choosesLineEnds: false)

        XCTAssertEqual(rows.map(\.label), ["Braille code", "Cells per line", "Lines per page", "Braille page numbers"])
        XCTAssertEqual(rows.dropFirst().map(\.value), ["40 cells", "25 lines", nil])
    }

    /// The braille file characters row says the code chosen, and a choice sheet is asked for by each of the three choice rows.
    func testTheChoiceRowsAskForTheirOwnSheets() {
        var options = BrailleExportOptions()
        options.fileCode = BrailleFileCode.all.last ?? options.fileCode

        let rows = PhoneExportOffer.brailleRows(options, choosesLineEnds: true)
        let choices = rows.compactMap { row -> PhoneExportOffer.BrailleChoice? in
            if case .choice(let choice) = row.control { return choice }
            return nil
        }

        XCTAssertEqual(choices, [.code, .lineEnds, .fileCode])
        XCTAssertEqual(rows.last?.value, options.fileCode.name)
    }
}
