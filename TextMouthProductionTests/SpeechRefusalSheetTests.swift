import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The sheet that shows the report of a speech refusal (B05): the whole
/// report in a read-only text area VoiceOver reads line by line, Close by
/// Return and Escape, Copy Details on a pasteboard of the test's own, one
/// report at a time updated in place, and where a book's window must stand
/// for the sheet to move VoiceOver.
///
/// Each view is hosted in an offscreen window that is never shown, and asks
/// VoiceOver to move nowhere. No test writes to the general pasteboard.
@MainActor
final class SpeechRefusalSheetTests: XCTestCase {

    // MARK: - The Details

    /// The whole report, line by line, is in a text area VoiceOver reads as
    /// one, called "Details": read-only, its text selectable.
    func testTheSheetShowsTheWholeReportInAReadOnlyTextArea() {
        let report = SpeechRefusalReportTests.sampleReport()
        let view = SpeechRefusalReportView(report: report, takesVoiceOverFocus: false, onCopy: {}, onClose: {})

        withHostedView(view, size: NSSize(width: 660, height: 600), until: {
            !self.descendants(of: $0, as: NSTextView.self).isEmpty
        }) { hosting in
            let textView = descendants(of: hosting, as: NSTextView.self).first { $0.string == report.text }
            XCTAssertNotNil(textView, "the report's text was not drawn")
            XCTAssertEqual(textView?.isEditable, false)
            XCTAssertEqual(textView?.isSelectable, true)
            XCTAssertEqual(textView?.accessibilityLabel(), SpeechRefusalWording.detailsLabel)
        }
    }

    /// Return presses Close, and Escape closes the sheet too, from the
    /// text area, where focus may be; the key that takes Escape takes no
    /// space and is no element to VoiceOver.
    func testReturnAndEscapeCloseTheSheetFromTheTextArea() throws {
        let report = SpeechRefusalReportTests.sampleReport()
        var closes = 0
        let view = SpeechRefusalReportView(report: report, takesVoiceOverFocus: false, onCopy: {}, onClose: { closes += 1 })

        try withHostedView(view, size: NSSize(width: 660, height: 600), until: {
            self.descendants(of: $0, as: NSTextView.self).contains { $0.string == report.text }
        }) { hosting in
            let window = try XCTUnwrap(hosting.window)
            let textView = try XCTUnwrap(descendants(of: hosting, as: NSTextView.self).first { $0.string == report.text })
            window.makeFirstResponder(textView)
            XCTAssertTrue(window.firstResponder === textView, "the text area has no focus")

            guard pressKeyEquivalent(.return, in: hosting) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertTrue(waitUntil { closes == 1 }, "Return did not press Close")

            XCTAssertTrue(pressKeyEquivalent(.escape, in: hosting), "nothing took Escape")
            XCTAssertTrue(waitUntil { closes == 2 }, "Escape did not close the sheet from the text area")

            let catcher = try XCTUnwrap(descendants(of: hosting, as: SilentKeyEquivalentView.self).first)
            XCTAssertEqual(catcher.frame.size, .zero, "the key's view takes space")
            XCTAssertFalse(catcher.isAccessibilityElement(), "the key's view is an element to VoiceOver")
        }
    }

    // MARK: - Copy Details

    /// Copy Details puts the whole report on the pasteboard as plain text,
    /// in place of what was there, and VoiceOver hears "Details copied".
    func testCopyDetailsCopiesTheWholeReportAndSaysSo() {
        let report = SpeechRefusalReportTests.sampleReport()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TextMouth.SpeechRefusalSheetTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("Something copied before", forType: .string)

        let announced = recordingAnnouncements {
            SpeechRefusalReportSheet.copyDetails(of: report, to: pasteboard)
        }

        XCTAssertEqual(pasteboard.string(forType: .string), report.text)
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 1)
        XCTAssertEqual(announced.announcements.map(\.message), [SpeechRefusalWording.copiedAnnouncement])
        XCTAssertEqual(SpeechRefusalWording.copiedAnnouncement, "Details copied")
        XCTAssertEqual(SpeechRefusalWording.notCopiedAnnouncement, "The details could not be copied")
    }

    // MARK: - One Report at a Time

    /// The sheet over a reader shows the report the reader keeps, and a
    /// second refusal while it is open updates it in place, its count and
    /// all, rather than opening another.
    func testTheSheetFollowsTheReadersReportInPlace() throws {
        let world = try makeIntegrationWorld("Refusal Sheet")
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
        reader.speechRefusalAlert.show(SpeechRefusalReportTests.sampleReport())
        let first = try XCTUnwrap(reader.speechRefusalAlert.report)

        withHostedView(SpeechRefusalReportSheet(viewModel: reader), size: NSSize(width: 660, height: 600), until: {
            self.descendants(of: $0, as: NSTextView.self).contains { $0.string == first.text }
        }) { hosting in
            XCTAssertTrue(first.text.contains("Refused here: 1 time while this window has been open."))
            reader.speechRefusalAlert.show(SpeechRefusalReportTests.sampleReport())
            let second = reader.speechRefusalAlert.report
            XCTAssertEqual(second?.timesRefusedHere, 2)

            XCTAssertTrue(
                waitUntil(timeout: 5) {
                    self.descendants(of: hosting, as: NSTextView.self).contains { $0.string == second?.text }
                },
                "the open sheet did not show the second refusal"
            )
            XCTAssertEqual(descendants(of: hosting, as: NSTextView.self).count, 1, "a second text area was drawn")
        }
    }

    /// The report waits while one of the reader's panels shows, since a
    /// window shows one sheet at a time, and every panel counts: one added
    /// to `ReaderPanels` without being added to `isShowingAny` fails here.
    func testTheReportWaitsWhileAnyPanelShows() {
        XCTAssertFalse(ReaderPanels().isShowingAny)
        let eachPanel: [WritableKeyPath<ReaderPanels, Bool>] = [\.headings, \.bookmarks, \.sleepTimer, \.bookInfo, \.voice, \.search]
        for panel in eachPanel {
            var panels = ReaderPanels()
            panels[keyPath: panel] = true
            XCTAssertTrue(panels.isShowingAny, "\(panel) does not count")
        }
        XCTAssertEqual(Mirror(reflecting: ReaderPanels()).children.count, eachPanel.count, "a panel is missing from isShowingAny")
    }

    // MARK: - Where the Book's Window Stands

    /// The sheet moves VoiceOver only when it opens in front of the
    /// listener: TextMouth active, and the book's window, or a sheet over
    /// it, the key window. Another window or app in front leaves the sheet
    /// waiting on its window, and the keyboard and VoiceOver where they are.
    func testTheSheetMovesVoiceOverOnlyInFrontOfTheListener() {
        typealias Standing = SpeechRefusalWindowStanding
        XCTAssertEqual(Standing.of(appIsActive: true, windowIsKey: true, windowHasSheet: false, keyWindowIsItsSheet: false), .inFront)
        XCTAssertEqual(Standing.of(appIsActive: true, windowIsKey: false, windowHasSheet: true, keyWindowIsItsSheet: true), .underASheet)
        XCTAssertEqual(Standing.of(appIsActive: true, windowIsKey: true, windowHasSheet: true, keyWindowIsItsSheet: false), .underASheet)
        XCTAssertEqual(Standing.of(appIsActive: true, windowIsKey: false, windowHasSheet: false, keyWindowIsItsSheet: false), .behind)
        XCTAssertEqual(Standing.of(appIsActive: true, windowIsKey: false, windowHasSheet: true, keyWindowIsItsSheet: false), .behind)
        XCTAssertEqual(Standing.of(appIsActive: false, windowIsKey: true, windowHasSheet: false, keyWindowIsItsSheet: false), .behind)
        XCTAssertEqual(Standing.of(appIsActive: false, windowIsKey: false, windowHasSheet: true, keyWindowIsItsSheet: true), .behind)

        XCTAssertTrue(Standing.inFront.sheetTakesVoiceOverFocus)
        XCTAssertTrue(Standing.underASheet.sheetTakesVoiceOverFocus)
        XCTAssertFalse(Standing.behind.sheetTakesVoiceOverFocus)
    }

    /// One message at the stop: the sheet speaks for itself only when it
    /// opens at once in front of the listener; under another sheet, or
    /// with the report open already, or behind, VoiceOver hears the
    /// announcement instead.
    func testTheSheetSpeaksForItselfOnlyWhenItOpensAtOnceInFront() {
        XCTAssertTrue(SpeechRefusalWindowStanding.inFront.sheetSpeaksForItself)
        XCTAssertFalse(SpeechRefusalWindowStanding.underASheet.sheetSpeaksForItself)
        XCTAssertFalse(SpeechRefusalWindowStanding.behind.sheetSpeaksForItself)
    }
}
