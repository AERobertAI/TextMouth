import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The braille options of the Export dialog (FMT22, Phase B): the options
/// view's controls, labels, hints, and spoken values.
@MainActor
final class BrailleExportWriterTests: XCTestCase {

    // MARK: - The Wording

    /// Each sentence the options view shows or speaks, pinned exactly.
    func testEveryWordingConstantIsPinned() {
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

    // MARK: - The Options View

    /// A BRF's options view has the two table pop-ups, the line ends pop-up,
    /// the two steppers saying their numbers with units, and the page numbers
    /// checkbox, each by its label with its hint exactly.
    func testTheBRFOptionsViewIsLabelledAndHinted() throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        let box = OptionsBox(BrailleExportOptions(table: "en-ueb-g2.ctb"))
        try withOptionsView(box, choosesLineEnds: true, popUps: 3) { hosting in
            let controls = accessibleControls(in: hosting)
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
            // SwiftUI's checkbox joins the tree only for some sessions.
            if let numbers = controls.first(where: { $0.role == .checkBox && $0.label == "Braille page numbers" }) {
                XCTAssertEqual(numbers.hint, "Whether each page's last line carries its braille page number.")
                XCTAssertEqual((numbers.element.accessibilityValue() as? NSNumber)?.boolValue, true)
            }
        }
    }

    /// A PEF's options view has everything but the line ends pop-up: only
    /// the code and contraction pop-ups.
    func testThePEFOptionsViewHasNoLineEnds() throws {
        try skipUnlessHostedWindowsExposeAccessibility()
        let box = OptionsBox(BrailleExportOptions(table: "en-ueb-g2.ctb"))
        try withOptionsView(box, choosesLineEnds: false, popUps: 2) { hosting in
            let controls = accessibleControls(in: hosting)
            XCTAssertFalse(controls.contains { $0.label == "Line ends" }, "\(controls.map(\.label))")
            _ = try control(labelled: "Braille code", in: controls)
            _ = try control(labelled: "Cells per line", in: controls)
            XCTAssertEqual(descendants(of: hosting, as: NSPopUpButton.self).count, 2)
        }
    }

    /// The pop-ups show the table's code and contraction and offer what the
    /// bundle has; choosing a code, a contraction, or a line end sets the
    /// options, as the Braille tab does, and a stepper raised as VoiceOver
    /// raises it sets its number.
    func testTheControlsSetTheOptions() throws {
        let box = OptionsBox(BrailleExportOptions(table: "en-ueb-g2.ctb"))
        try withOptionsView(box, choosesLineEnds: true, popUps: 3) { hosting in
            let found = descendants(of: hosting, as: NSPopUpButton.self)
            XCTAssertEqual(found.count, 3)
            guard found.count == 3 else { return }
            // In reading order: code, contraction, line ends.
            let (code, contraction, lineEnds) = (found[0], found[1], found[2])
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
                return now.count == 3 && now[0].titleOfSelectedItem == "English Braille, American Edition"
                    && now[1].titleOfSelectedItem == "Contracted (Grade 2)"
            })
            // Then its Grade 1 table.
            let next = descendants(of: hosting, as: NSPopUpButton.self)
            guard next.count == 3 else { return XCTFail("\(next.count) pop-ups") }
            next[1].menu?.performActionForItem(at: 0)
            XCTAssertTrue(waitUntil { box.options.table == "en-us-g1.ctb" }, "the table is \(box.options.table)")

            // The line end.
            let again = descendants(of: hosting, as: NSPopUpButton.self)
            guard again.count == 3 else { return XCTFail("\(again.count) pop-ups") }
            again[2].menu?.performActionForItem(at: 1)
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

    // MARK: - Helpers

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

/// The options view bound to a box.
private struct OptionsHarness: View {
    @ObservedObject var box: OptionsBox
    let choosesLineEnds: Bool

    var body: some View {
        BrailleExportOptionsView(options: $box.options, choosesLineEnds: choosesLineEnds)
    }
}
