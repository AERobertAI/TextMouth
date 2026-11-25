import XCTest
@testable import TextMouth

/// `PhoneExportOffer`: which kinds the iPhone's Export sheet offers, what
/// fills its list, which buttons its bar holds at each stage in which order,
/// and what its folder row says, all in the Mac's words (FR31).
final class PhoneExportOfferTests: XCTestCase {

    // MARK: - The Kinds

    /// The iPhone offers every kind but spoken audio, which waits for phase 2.
    func testTheIPhoneOffersEveryKindButSpokenAudio() {
        XCTAssertEqual(PhoneExportOffer.kinds, Set(BookExportKind.allCases).subtracting([.spokenAudio]))
        XCTAssertFalse(PhoneExportOffer.kinds.contains(.spokenAudio))
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
            let dimmed = PhoneExportOffer.bar(stage: stage, canExport: false)
            XCTAssertEqual(dimmed.map(\.role), [.cancel, .export])
            XCTAssertEqual(dimmed.map(\.title), ["Cancel", "Export"])
            XCTAssertEqual(dimmed.map(\.hint), ["", "Exports the checked items to the folder."])
            XCTAssertEqual(dimmed.map(\.isEnabled), [true, false])

            let ready = PhoneExportOffer.bar(stage: stage, canExport: true)
            XCTAssertEqual(ready.map(\.isEnabled), [true, true])
        }
    }

    /// While an export runs, Stop takes Cancel's place with the Mac's hint,
    /// and Export is dimmed whatever else is so.
    func testTheBarWhileAnExportRuns() {
        let bar = PhoneExportOffer.bar(stage: .exporting, canExport: false)

        XCTAssertEqual(bar.map(\.role), [.stop, .export])
        XCTAssertEqual(bar.map(\.title), ["Stop", "Export"])
        XCTAssertEqual(bar.first?.hint, "Stops the export. The file being made is not kept.")
        XCTAssertEqual(bar.map(\.isEnabled), [true, false])
    }

    /// Once an export has ended, Close takes Cancel's place, so the sheet,
    /// which stays open to say what the export did, can be closed, and a
    /// second export can be made from it.
    func testTheBarOnceAnExportHasEnded() {
        let bar = PhoneExportOffer.bar(stage: .finished, canExport: true)

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
}
