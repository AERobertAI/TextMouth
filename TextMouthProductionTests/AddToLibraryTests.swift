import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The Add to Library choices, their words, the model that runs a choice
/// only after the sheet has gone, and the sheet itself (FR20, part one). No
/// test posts a real notification or shows a window: the model's `perform`
/// is always a recording closure.
@MainActor
final class AddToLibraryTests: XCTestCase {

    // MARK: - The Choices

    /// Five ways to add, in the order the sheet lists them.
    func testTheFiveChoicesAreInTheSheetsOrder() {
        XCTAssertEqual(AddToLibraryChoice.allCases, [.openBook, .importFolder, .newFromText, .newRecording, .addFeed])
        XCTAssertEqual(AddToLibraryChoice.allCases.map(\.id), AddToLibraryChoice.allCases)
    }

    /// Each choice stands for one shortcut action and is titled by it, so the
    /// sheet and the menus say the same words.
    func testEachChoiceIsTitledByItsAction() {
        let expected: [(AddToLibraryChoice, ShortcutAction, String)] = [
            (.openBook, .openBook, "Open Book…"),
            (.importFolder, .importDAISYFolder, "Import Folder…"),
            (.newFromText, .newFromText, "New from Text…"),
            (.newRecording, .newRecording, "New Recording…"),
            (.addFeed, .addFeed, "Add Feed…"),
        ]
        for (choice, action, title) in expected {
            XCTAssertEqual(choice.action, action)
            XCTAssertEqual(choice.title, action.title)
            XCTAssertEqual(choice.title, title)
        }
    }

    /// Each choice runs what its menu item runs.
    func testEachChoiceRunsWhatItsMenuItemRuns() {
        XCTAssertEqual(AddToLibraryChoice.openBook.run, .notification(.openBookFile))
        XCTAssertEqual(AddToLibraryChoice.importFolder.run, .notification(.importDAISYFolder))
        XCTAssertEqual(AddToLibraryChoice.newFromText.run, .notification(.newFromText))
        XCTAssertEqual(AddToLibraryChoice.newRecording.run, .recordingWindow)
        XCTAssertEqual(AddToLibraryChoice.addFeed.run, .notification(.addFeed))
    }

    /// A choice and its menu command cannot drift apart: a choice that posts
    /// a notification posts the one its action names, and New Recording,
    /// which acts without one, runs the Record window.
    func testAChoiceAndItsMenuCommandRunTheSameThing() {
        for choice in AddToLibraryChoice.allCases {
            switch choice.run {
            case .notification(let name):
                XCTAssertEqual(choice.action.notificationName, name, choice.title)
            case .recordingWindow:
                XCTAssertEqual(choice.action.notificationName, .actsWithoutNotification, choice.title)
                XCTAssertEqual(choice, .newRecording)
            }
        }
        XCTAssertEqual(
            AddToLibraryChoice.allCases.filter { $0.run == .recordingWindow },
            [.newRecording],
            "only New Recording opens a window itself"
        )
    }

    // MARK: - The Wording

    /// Every string of the button and the sheet, pinned.
    func testTheWordingIsPinned() {
        XCTAssertEqual(AddToLibraryWording.sheetTitle, "Add to Library")
        XCTAssertEqual(AddToLibraryWording.buttonTitle, "Add to Library")
        XCTAssertEqual(AddToLibraryWording.buttonLabel, "Add to Library")
        XCTAssertEqual(
            AddToLibraryWording.buttonHint,
            "Opens a sheet with the ways to add to the library: open a book, import a folder, make a book from text, record audio, or add a feed"
        )
        XCTAssertEqual(AddToLibraryWording.cancel, "Cancel")
    }

    /// Each choice's one-line summary, pinned; Open Book and Add Feed reuse
    /// the constants their old toolbar buttons used.
    func testTheSummariesArePinnedAndReuseTheOldHints() {
        XCTAssertEqual(AddToLibraryWording.summary(.openBook), "Opens a file picker to import books in any format TextMouth reads.")
        XCTAssertEqual(AddToLibraryWording.summary(.openBook), LibraryView.importBookHint)
        XCTAssertEqual(
            AddToLibraryWording.summary(.importFolder),
            "Chooses a folder that holds a DAISY book or audio tracks and imports it as one book."
        )
        XCTAssertEqual(AddToLibraryWording.summary(.newFromText), "Makes a new book from text you paste or type.")
        XCTAssertEqual(AddToLibraryWording.summary(.newRecording), "Records from a microphone into a new audiobook.")
        XCTAssertEqual(
            AddToLibraryWording.summary(.addFeed),
            "Opens a sheet where you type a feed's address and choose where its folder goes"
        )
        XCTAssertEqual(AddToLibraryWording.summary(.addFeed), FeedWording.addFeedButtonHint)
        for choice in AddToLibraryChoice.allCases {
            XCTAssertEqual(choice.summary, AddToLibraryWording.summary(choice))
        }
    }

    /// A dimmed choice says why, after its summary; a label carries the key
    /// in words when there is one.
    func testTheHintOfADimmedChoiceAndTheSpokenLabel() {
        XCTAssertEqual(
            AddToLibraryWording.unavailableHint(.newFromText),
            "Makes a new book from text you paste or type. Not available in this window."
        )
        XCTAssertEqual(AddToLibraryWording.label(.openBook, key: "Command + O"), "Open Book…, Command + O")
        XCTAssertEqual(AddToLibraryWording.label(.openBook, key: nil), "Open Book…")
    }
}
