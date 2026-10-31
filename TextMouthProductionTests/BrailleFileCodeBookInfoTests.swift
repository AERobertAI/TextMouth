import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// Book Information's Braille File Characters pop-up (braillecodes,
/// BRAILLE-CODES-RESEARCH-2026-10-25.md, section 8.3), which follows the Text
/// Encoding pop-up (`TextEncodingPopUpTests`) and shares its view, its alert,
/// and its checks: its items, with the book's code selected as its record
/// keeps it; a new code asked about first, Cancel leaving everything, a busy
/// book refused, and Read Again reading the book again; its label, value,
/// hint, and items, read from the hosted sheet; Speak Full Info's sentence;
/// and every new word, exactly.
@MainActor
final class BrailleFileCodeBookInfoTests: CloudMaintenanceTestCase {

    // MARK: - The Words

    /// Every sentence of the pop-up, its alert, and Speak Info, exactly: the
    /// alert says first that nothing checks the choice, then the encoding's
    /// own sentences of what a re-read does, with the places' sentence less
    /// the encoding's Cyrillic example, and ends as the encoding's does.
    func testTheWordsArePinned() {
        XCTAssertEqual(BrailleFileCodeWording.bookInfoLabel, "Braille File Characters")
        XCTAssertEqual(BrailleFileCodeWording.popUpHint, "Choose other characters to read the book's file again with them.")
        XCTAssertEqual(
            BrailleFileCodeWording.unknownValue("ascii-braillo-no-047-01"),
            "“ascii-braillo-no-047-01”, which this version of TextMouth can't read"
        )
        XCTAssertEqual(
            BrailleFileCodeWording.speakInfoPart("North American Braille ASCII"), "Braille characters: North American Braille ASCII"
        )
        XCTAssertEqual(
            BrailleFileCodeWording.confirmTitle(bookTitle: "Ledger", code: .eurobraille),
            "Read “Ledger” again as Eurobraille, six-dot (German-speaking countries)?"
        )
        XCTAssertEqual(TextEncodingWording.confirmButton, "Read Again")

        let unchecked = "Nothing checks that this is the right choice. If numbers and punctuation sound wrong, choose another."
        let replaced = "Its text is replaced by the new reading."
        let places = "Your place and bookmarks move with their words. "
            + "Where none of their words are left, each goes to about the same point in its chapter, "
            + "or to the nearest passage the two readings share."
        let kept = "An edit of its text is kept beside the new reading, as a copy in the book's package."
        let stops = "Edit Text stops for this book; choose Edit Text again to edit the new reading."
        XCTAssertEqual(BrailleFileCodeWording.uncheckedNote, unchecked)
        XCTAssertEqual(BrailleFileCodeWording.placesNote, places)
        XCTAssertEqual(BrailleFileCodeWording.confirmMessage(keepsText: false, stopsEditing: false), [unchecked, replaced, places].joined(separator: " "))
        XCTAssertEqual(
            BrailleFileCodeWording.confirmMessage(keepsText: true, stopsEditing: false), [unchecked, replaced, places, kept].joined(separator: " ")
        )
        XCTAssertEqual(
            BrailleFileCodeWording.confirmMessage(keepsText: false, stopsEditing: true), [unchecked, replaced, places, stops].joined(separator: " ")
        )
        XCTAssertEqual(
            BrailleFileCodeWording.confirmMessage(keepsText: true, stopsEditing: true),
            [unchecked, replaced, places, kept, stops].joined(separator: " ")
        )
    }
}
