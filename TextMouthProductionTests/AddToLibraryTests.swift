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

    // MARK: - The Model

    /// A model whose `perform` records the choices it runs instead of running
    /// them, and for which every choice works except those in `dimmed`.
    private func makeModel(dimmed: Set<AddToLibraryChoice> = [], performed: @escaping (AddToLibraryChoice) -> Void) -> AddToLibraryModel {
        AddToLibraryModel(isEnabled: { !dimmed.contains($0) }, perform: performed)
    }

    /// Choosing closes the sheet and runs nothing; the choice runs when the
    /// sheet has gone, once, and a second dismissal runs nothing.
    func testAChoiceRunsOnlyAfterTheSheetHasGoneAndOnlyOnce() {
        var performed: [AddToLibraryChoice] = []
        let model = makeModel { performed.append($0) }
        model.isPresented = true

        model.choose(.newFromText)

        XCTAssertFalse(model.isPresented, "choosing did not close the sheet")
        XCTAssertEqual(performed, [], "the choice ran while the sheet was still closing")

        model.sheetDidDismiss()
        XCTAssertEqual(performed, [.newFromText])

        model.sheetDidDismiss()
        XCTAssertEqual(performed, [.newFromText], "a second dismissal ran the choice again")
    }

    /// A dismissal with nothing chosen runs nothing.
    func testADismissalWithNothingChosenRunsNothing() {
        var performed: [AddToLibraryChoice] = []
        let model = makeModel { performed.append($0) }
        model.sheetDidDismiss()
        XCTAssertEqual(performed, [])
    }

    /// Cancel closes the sheet and runs nothing, even after the sheet's
    /// dismissal, and even for a choice made before it.
    func testCancelClosesAndRunsNothing() {
        var performed: [AddToLibraryChoice] = []
        let model = makeModel { performed.append($0) }
        model.isPresented = true

        model.cancel()
        model.sheetDidDismiss()
        XCTAssertFalse(model.isPresented)
        XCTAssertEqual(performed, [])

        model.choose(.addFeed)
        model.cancel()
        model.sheetDidDismiss()
        XCTAssertEqual(performed, [], "a choice made before Cancel still ran")
    }

    /// A choice that does not work in this window is ignored: the sheet stays
    /// open and nothing runs.
    func testADimmedChoiceIsIgnored() {
        var performed: [AddToLibraryChoice] = []
        let model = makeModel(dimmed: [.newRecording]) { performed.append($0) }
        model.isPresented = true

        model.choose(.newRecording)
        XCTAssertTrue(model.isPresented, "a dimmed choice closed the sheet")
        model.sheetDidDismiss()
        XCTAssertEqual(performed, [])
        XCTAssertFalse(model.isEnabled(.newRecording))
        XCTAssertTrue(model.isEnabled(.openBook))
    }

    /// Choosing twice before the sheet has gone runs only the last, once.
    func testTwoChoicesBeforeTheDismissalRunOnlyTheLast() {
        var performed: [AddToLibraryChoice] = []
        let model = makeModel { performed.append($0) }
        model.isPresented = true

        model.choose(.openBook)
        model.choose(.importFolder)
        model.sheetDidDismiss()
        model.sheetDidDismiss()

        XCTAssertEqual(performed, [.importFolder])
    }

    /// The model can be used again: a second showing and choice runs again.
    func testTheModelServesASecondShowing() {
        var performed: [AddToLibraryChoice] = []
        let model = makeModel { performed.append($0) }
        for choice in [AddToLibraryChoice.openBook, .addFeed] {
            model.isPresented = true
            model.choose(choice)
            model.sheetDidDismiss()
        }
        XCTAssertEqual(performed, [.openBook, .addFeed])
    }

    // MARK: - The Menu Commands' Rules

    /// A shortcut manager with a store of its own and no event monitor.
    private func makeManager(_ label: String) -> KeyboardShortcutManager {
        KeyboardShortcutManager(userDefaults: makeSandboxedPreferences(label), installsEventMonitor: false)
    }

    /// Every choice works wherever its menu command does: in every window by
    /// default, and, once a scope excludes Library windows, not in them.
    func testAChoiceIsEnabledWhereItsMenuCommandWorks() {
        let manager = makeManager("add-to-library-enabled")
        let kinds: [ShortcutWindowKind?] = [nil] + ShortcutWindowKind.allCases.map { Optional($0) }
        for choice in AddToLibraryChoice.allCases {
            XCTAssertTrue(choice.isEnabled(under: manager, in: .library), choice.title)
            XCTAssertTrue(choice.isEnabled(under: manager, in: nil), choice.title)
            for kind in kinds {
                XCTAssertEqual(
                    choice.isEnabled(under: manager, in: kind),
                    manager.scope(of: choice.action).admitsMenuCommand(in: kind),
                    "\(choice.title) in \(String(describing: kind))"
                )
            }
        }

        manager.setScope(.reader, for: .newFromText)
        XCTAssertEqual(manager.scope(of: .newFromText), .reader)
        XCTAssertFalse(AddToLibraryChoice.newFromText.isEnabled(under: manager, in: .library), "New from Text… stayed enabled in a Library window")
        XCTAssertTrue(AddToLibraryChoice.newFromText.isEnabled(under: manager, in: .reader))
        XCTAssertTrue(AddToLibraryChoice.newFromText.isEnabled(under: manager, in: nil), "any command acts with no window open")
        XCTAssertTrue(AddToLibraryChoice.openBook.isEnabled(under: manager, in: .library), "another choice followed it")
    }

    /// A choice's key in words is its action's key equivalent in force, nil
    /// for none, and follows the user's edit.
    func testAChoicesKeyInWords() {
        let manager = makeManager("add-to-library-keys")
        XCTAssertEqual(AddToLibraryChoice.openBook.keyDescription(under: manager), "Command + O")
        XCTAssertEqual(AddToLibraryChoice.newFromText.keyDescription(under: manager), "Shift + Command + T")
        XCTAssertEqual(AddToLibraryChoice.newRecording.keyDescription(under: manager), "Option + Command + N")
        for choice in AddToLibraryChoice.allCases {
            XCTAssertEqual(
                choice.keyDescription(under: manager),
                manager.keyEquivalent(for: choice.action)?.accessibleDisplayString,
                choice.title
            )
        }

        manager.updateBindings(for: .openBook, to: [KeyBinding(key: "b", command: true, shift: true)])
        XCTAssertEqual(AddToLibraryChoice.openBook.keyDescription(under: manager), "Shift + Command + B")

        manager.updateBindings(for: .addFeed, to: [])
        XCTAssertNil(AddToLibraryChoice.addFeed.keyDescription(under: manager), "a choice with no key described one")
    }
}
