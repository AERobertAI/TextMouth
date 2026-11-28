import XCTest
@testable import TextMouth

/// When the Speech Stopped sheet shows over the phone's reader, and what the
/// session's snapshot says of the report that opens it.
@MainActor
final class PhoneSpeechRefusalPresentationTests: XCTestCase {
    /// The sheet shows when the reader keeps a report and nothing else is over
    /// the reader.
    func testItShowsWhenNothingElseIsOverTheReader() {
        XCTAssertTrue(PhoneSpeechRefusalPresentation.shows(
            hasReport: true, panelSheetShows: false, errorAlertShows: false, otherAlertShows: false
        ))
    }

    /// With no report, it never shows.
    func testItNeverShowsWithoutAReport() {
        XCTAssertFalse(PhoneSpeechRefusalPresentation.shows(
            hasReport: false, panelSheetShows: false, errorAlertShows: false, otherAlertShows: false
        ))
    }

    /// It waits for each thing that can be over the reader, one at a time.
    func testItWaitsForAPanelAnErrorAlertOrAnotherAlert() {
        XCTAssertFalse(PhoneSpeechRefusalPresentation.shows(
            hasReport: true, panelSheetShows: true, errorAlertShows: false, otherAlertShows: false
        ))
        XCTAssertFalse(PhoneSpeechRefusalPresentation.shows(
            hasReport: true, panelSheetShows: false, errorAlertShows: true, otherAlertShows: false
        ))
        XCTAssertFalse(PhoneSpeechRefusalPresentation.shows(
            hasReport: true, panelSheetShows: false, errorAlertShows: false, otherAlertShows: true
        ))
    }

    /// The snapshot says whether the reader keeps a report, and changes when
    /// the report comes or goes, so the screen presents the sheet then and not
    /// as the place moves.
    func testTheSnapshotFollowsTheReadersReport() throws {
        let world = try makeIntegrationWorld("Phone Refusal Snapshot")
        let book = Book(
            title: "Quay Ledger",
            format: .txt,
            filePath: world.folder.path + "/\(UUID().uuidString) missing.txt",
            md5Hash: UUID().uuidString,
            folderPath: world.folder.path
        )
        world.library.library.addBook(book)
        let reader = world.openReader(for: book, renderScheduler: HeldRenderQueue())
        waitForReaderToLoad(reader)
        let before = PhoneReaderSnapshot(of: reader)
        XCTAssertFalse(before.hasSpeechRefusalReport)

        reader.speechRefusalAlert.show(SpeechRefusalReportTests.sampleReport())
        let shown = PhoneReaderSnapshot(of: reader)
        XCTAssertTrue(shown.hasSpeechRefusalReport)
        XCTAssertNotEqual(before, shown)

        reader.closeSpeechRefusalReport()
        XCTAssertEqual(PhoneReaderSnapshot(of: reader), before)
    }
}
