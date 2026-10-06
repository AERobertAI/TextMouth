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

        try withHostedView(sheet, until: { !self.nameFields(in: $0).isEmpty }) { hostingView in
            try type("Reports", into: hostingView)
            guard pressReturn(in: hostingView) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertEqual(creates.calls, ["Reports"], "Return did not press Create")
            XCTAssertTrue(moves.calls.isEmpty, "Return pressed Move as well: \(moves.calls)")

            // Refused, the fields stay with the name, and Return tries again.
            letViewSettle(hostingView)
            XCTAssertEqual(nameFields(in: hostingView).count, 1, "the refused folder's fields closed")
            XCTAssertTrue(pressReturn(in: hostingView))
            XCTAssertEqual(creates.calls, ["Reports", "Reports"], "Return did not press Create again")
            XCTAssertTrue(moves.calls.isEmpty, "Return pressed Move as well: \(moves.calls)")

            // Made, the folder is the destination and the fields are gone,
            // so Return moves the books there.
            XCTAssertTrue(waitUntil {
                hostingView.layoutSubtreeIfNeeded()
                return self.nameFields(in: hostingView).isEmpty
            }, "the made folder's fields stayed open")
            let popUp = descendants(of: hostingView, as: NSPopUpButton.self).first
            XCTAssertTrue(waitUntil { popUp?.titleOfSelectedItem == "Reports" }, "the destination is \(popUp?.titleOfSelectedItem ?? "none")")
            letViewSettle(hostingView)
            XCTAssertTrue(pressReturn(in: hostingView))
            XCTAssertTrue(waitUntil { moves.calls == ["Reports"] }, "Return did not press Move once the fields closed: \(moves.calls)")
            XCTAssertEqual(creates.calls.count, 2, "Return pressed Create once the fields closed")
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
        try withHostedView(sheet, until: { !self.nameFields(in: $0).isEmpty }) { hostingView in
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

    // MARK: - Keys and Fields

    /// Presses Return in `hostingView`'s window as the app receives a key:
    /// offered as a key equivalent first, which a button with that shortcut
    /// takes, and otherwise sent on to the control with keyboard focus.
    /// Returns whether a key equivalent took it; some macOS releases hand
    /// an offscreen window none.
    private func pressReturn(in hostingView: NSView) -> Bool {
        guard let window = hostingView.window, let event = keyDown(.return, in: window) else { return false }
        if window.performKeyEquivalent(with: event) { return true }
        window.sendEvent(event)
        return false
    }

    /// Gives the new folder's name field keyboard focus and types `text`
    /// into it through the window's field editor, as the keyboard does, so
    /// the picker's binding follows; skips where an offscreen window gives
    /// the field no focus.
    private func type(_ text: String, into hostingView: NSView) throws {
        let field = try XCTUnwrap(nameFields(in: hostingView).first, "the name field was not drawn")
        guard let window = hostingView.window, window.makeFirstResponder(field),
              let editor = window.firstResponder as? NSTextView else {
            throw XCTSkip("This macOS gives an offscreen window's field no keyboard focus")
        }
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        letViewSettle(hostingView)
    }

    /// Lets SwiftUI apply its pending updates, as after typing or a press.
    private func letViewSettle(_ hostingView: NSView) {
        _ = waitUntil(timeout: 0.25) {
            hostingView.layoutSubtreeIfNeeded()
            return false
        }
    }

    /// The editable text fields AppKit drew below `root`.
    private func editableFields(in root: NSView) -> [NSTextField] {
        descendants(of: root, as: NSTextField.self).filter(\.isEditable)
    }

    /// The new folder's name field, drawn while the fields are shown.
    private func nameFields(in root: NSView) -> [NSTextField] {
        editableFields(in: root).filter { $0.placeholderString == "Folder name" }
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
