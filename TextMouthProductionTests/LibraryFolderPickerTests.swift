import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The folder picker the Move dialog and the feed sheets share
/// (`LibraryFolderPicker`): while its New Folder fields are shown, Return
/// presses their Create and nothing else, and the fields' Cancel is told
/// apart from the sheet's own. SwiftUI builds the accessibility elements of
/// its buttons only for a connected assistive app, so a test that reads
/// them skips, rather than fails, when it finds none; the wording tests
/// cover the labels either way.
@MainActor
final class LibraryFolderPickerTests: XCTestCase {

    // MARK: - Return

    /// In the Move sheet, with the new folder's fields shown and keyboard
    /// focus in the name field, Return presses Create and never Move: a
    /// folder that can't be made keeps the fields, and Return tries again;
    /// one that is made becomes the destination and closes the fields,
    /// after which Return moves the books there.
    func testReturnCreatesTheNewFolderWhileItsFieldsAreShownAndMovesOtherwise() throws {
        let creates = CallLog<String>()
        let moves = CallLog<String>()
        // "Reports" is in the library from the start so the pop-up can show
        // it chosen once "made", as it does in the app once the library
        // publishes the new folder; the first try is refused, as a name in
        // use is, and the second works.
        let sheet = MoveFolderSheet(
            books: [makeBook()],
            library: makeLibrary(withFolders: ["Reports"]),
            lastMovedFolderPath: "",
            onMove: { path in
                moves.record(path)
                return .success(nil)
            },
            onCreateFolder: { name, parent in
                creates.record(parent.isEmpty ? name : "\(parent)/\(name)")
                return creates.calls.count == 1
                    ? .failure("Could not create folder: refused once for the test")
                    : .success(nil)
            },
            onCancel: {},
            makingFolder: true
        )

        try withHostedView(sheet, until: { !self.newFolderNameFields(in: $0).isEmpty }) { hostingView in
            try typeNewFolderName("Reports", in: hostingView)
            guard pressReturnKey(in: hostingView) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertEqual(creates.calls, ["Reports"], "Return did not press Create")
            XCTAssertTrue(moves.calls.isEmpty, "Return pressed Move as well: \(moves.calls)")

            // Refused, the fields stay with the name, and Return tries again.
            settleHostedView(hostingView)
            XCTAssertEqual(newFolderNameFields(in: hostingView).count, 1, "the refused folder's fields closed")
            XCTAssertTrue(pressReturnKey(in: hostingView))
            XCTAssertEqual(creates.calls, ["Reports", "Reports"], "Return did not press Create again")
            XCTAssertTrue(moves.calls.isEmpty, "Return pressed Move as well: \(moves.calls)")

            // Made, the folder is the destination and the fields are gone,
            // so Return moves the books there.
            XCTAssertTrue(waitUntil {
                hostingView.layoutSubtreeIfNeeded()
                return self.newFolderNameFields(in: hostingView).isEmpty
            }, "the made folder's fields stayed open")
            let popUp = descendants(of: hostingView, as: NSPopUpButton.self).first
            XCTAssertTrue(waitUntil { popUp?.titleOfSelectedItem == "Reports" }, "the destination is \(popUp?.titleOfSelectedItem ?? "none")")
            settleHostedView(hostingView)
            XCTAssertTrue(pressReturnKey(in: hostingView))
            XCTAssertTrue(waitUntil { moves.calls == ["Reports"] }, "Return did not press Move once the fields closed: \(moves.calls)")
            XCTAssertEqual(creates.calls.count, 2, "Return pressed Create once the fields closed")
        }
    }

    // MARK: - The Keyboard in the Name Field

    /// As the new folder's fields appear, the keyboard goes to their name
    /// field, so typing names the folder at once, and VoiceOver, which
    /// follows the keyboard, lands where the user types rather than on the
    /// New Folder... button that went away. (SwiftUI draws that button as no
    /// AppKit button a test can press, so the fields are shown from the
    /// start here; they take the keyboard the same way, as they appear.)
    func testTheNameFieldTakesTheKeyboardAsTheFieldsAppear() throws {
        let sheet = MoveFolderSheet(
            books: [makeBook()],
            library: makeLibrary(withFolders: ["Reports"]),
            lastMovedFolderPath: "",
            onMove: { _ in .success(nil) },
            onCreateFolder: { _, _ in .success(nil) },
            onCancel: {},
            makingFolder: true
        )

        try withHostedView(sheet, until: { !self.newFolderNameFields(in: $0).isEmpty }) { hostingView in
            let window = try XCTUnwrap(hostingView.window)
            let field = try XCTUnwrap(newFolderNameFields(in: hostingView).first)
            XCTAssertTrue(
                waitUntil { self.isEditing(field, in: window) },
                "the name field did not take the keyboard; \(String(describing: window.firstResponder)) has it"
            )
        }
    }

    // MARK: - Cancel New Folder

    /// The button that closes the new folder's fields says which Cancel it
    /// is, and its hint says the fields close and the folder chosen stays.
    func testCancelNewFolderIsToldApartFromTheSheetsCancel() {
        XCTAssertEqual(LibraryFolderPicker.cancelNewFolderTitle, "Cancel New Folder")
        XCTAssertEqual(
            LibraryFolderPicker.cancelNewFolderHint,
            "Closes the new folder's fields and keeps the folder chosen."
        )
    }

    /// In the Move sheet with the new folder's fields shown, VoiceOver
    /// meets one Cancel, the sheet's, and one Cancel New Folder with its
    /// hint, beside Create and Move.
    func testTheFieldsCancelIsNamedApartFromTheSheetsCancel() throws {
        let sheet = MoveFolderSheet(
            books: [makeBook()],
            library: makeLibrary(withFolders: ["Reports"]),
            lastMovedFolderPath: "",
            onMove: { _ in .success(nil) },
            onCreateFolder: { _, _ in .success(nil) },
            onCancel: {},
            makingFolder: true
        )

        try skipUnlessHostedWindowsExposeAccessibility()
        try withHostedView(sheet, until: { !self.newFolderNameFields(in: $0).isEmpty }) { hostingView in
            let buttons = accessibleControls(in: hostingView).filter { $0.role == .button }
            guard !buttons.isEmpty else {
                throw XCTSkip("SwiftUI exposed no buttons to accessibility in this run")
            }
            let labels = buttons.map(\.label)
            XCTAssertEqual(labels.filter { $0 == "Cancel" }.count, 1, "Cancel is not the sheet's alone: \(labels)")
            let fieldsCancel = try XCTUnwrap(
                buttons.first { $0.label == LibraryFolderPicker.cancelNewFolderTitle },
                "No Cancel New Folder: \(labels)"
            )
            XCTAssertEqual(fieldsCancel.hint, LibraryFolderPicker.cancelNewFolderHint)
            XCTAssertTrue(labels.contains("Create") && labels.contains("Move"), "\(labels)")
        }
    }

    // MARK: - Fixtures

    /// A book to move, needing no files: the sheet only names it.
    private func makeBook() -> Book {
        Book(
            title: "Harbour Soundings",
            format: .txt,
            filePath: "/nowhere/Harbour Soundings.tmb/book.txt",
            md5Hash: "picker-fixture",
            folderPath: "",
            tmbDirectoryName: "Harbour Soundings.tmb"
        )
    }

    /// A library holding top-level folders named `names` and no books.
    private func makeLibrary(withFolders names: [String]) -> Library {
        var library = Library()
        library.folders = names.map { BookFolder(name: $0) }
        return library
    }
}
