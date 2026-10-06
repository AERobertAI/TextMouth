import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The Book Information sheet as VoiceOver meets it: one way to close
/// without saving, the Cancel button that Escape presses, beside Save. A
/// Close button in the sheet's header did the same as Cancel until October
/// 6, 2026, so VoiceOver met two controls for it; the user asked for such
/// duplicate controls to go.
///
/// SwiftUI builds the elements of its buttons only for a connected assistive
/// app; where it exposes no button here, the check is skipped, as the sleep
/// timer sheet's is.
@MainActor
final class BookInfoSheetTests: XCTestCase {

    /// Among the sheet's buttons are one Cancel and the Save button, and no
    /// Close.
    func testTheSheetOffersOneWayToCloseWithoutSaving() throws {
        let metadata = EPUBMetadata(
            title: "Ferry Timetable", author: "Harbour Board", publisher: "", publicationDate: "",
            isbn: "", language: "en", identifier: "", epubVersion: "3.0"
        )
        let sheet = MetadataEditorView(metadata: metadata, isEPUB: true) { _, _ in .success(nil) }

        try withHostedControls(sheet) { controls in
            let buttons = controls.filter { $0.role == .button }.map(\.label)
            guard !buttons.isEmpty else {
                throw XCTSkip("SwiftUI exposed no button to accessibility in this run")
            }
            XCTAssertEqual(buttons.filter { $0 == "Cancel" }.count, 1, "Cancel is not the one way to close: \(buttons)")
            XCTAssertFalse(buttons.contains("Close"), "The header's Close button is back: \(buttons)")
            XCTAssertTrue(
                buttons.contains(EPUBMetadataSaveWording.saveButtonLabel(writesToFile: false)),
                "No Save button: \(buttons)"
            )
        }
    }
}
