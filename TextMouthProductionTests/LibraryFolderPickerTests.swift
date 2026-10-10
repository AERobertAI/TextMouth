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

    // MARK: - Escape

    /// While the new folder's fields are shown, Escape closes them, says
    /// so, and keeps the folder chosen, rather than closing the Move sheet;
    /// once they are closed, a second Escape presses the sheet's Cancel. So
    /// it goes with the keyboard in the name field, where the fields put
    /// it, or out of it, as after a Tab to the buttons, each Escape offered
    /// to the window as the app offers a key (`pressKey(_:in:)`). Until
    /// October 10, 2026 the first Escape closed the whole sheet.
    func testEscapeClosesTheNewFolderFieldsBeforeTheSheet() throws {
        for keyboardInField in [true, false] {
            let cancels = CallLog<String>()
            let sheet = MoveFolderSheet(
                books: [makeBook()],
                library: makeLibrary(withFolders: ["Reports"]),
                lastMovedFolderPath: "Reports",
                onMove: { _ in .success(nil) },
                onCreateFolder: { _, _ in .success(nil) },
                onCancel: { cancels.record("Cancel") },
                makingFolder: true
            )
            let place = keyboardInField ? "in the name field" : "out of the fields"

            try withHostedView(sheet, until: { !self.newFolderNameFields(in: $0).isEmpty }) { hostingView in
                try typeNewFolderName("Charts", in: hostingView)
                if !keyboardInField {
                    hostingView.window?.makeFirstResponder(nil)
                }
                var tookEscape = false
                let recorder = try recordingAnnouncements {
                    tookEscape = pressKey(.escape, in: hostingView)
                    guard tookEscape else {
                        throw XCTSkip("This macOS hands an offscreen window no key equivalents")
                    }
                    XCTAssertTrue(waitUntil {
                        hostingView.layoutSubtreeIfNeeded()
                        return self.newFolderNameFields(in: hostingView).isEmpty
                    }, "Escape left the fields open, the keyboard \(place)")
                }
                XCTAssertEqual(cancels.calls, [], "Escape closed the sheet with the fields open, the keyboard \(place)")
                XCTAssertEqual(
                    recorder.announcements.map(\.message),
                    ["New Folder cancelled. Destination folder: Reports."],
                    "the keyboard \(place)"
                )
                let popUp = descendants(of: hostingView, as: NSPopUpButton.self).first
                XCTAssertEqual(popUp?.titleOfSelectedItem, "Reports", "the folder chosen changed")

                // The fields closed, the sheet's Cancel takes Escape back.
                settleHostedView(hostingView)
                XCTAssertTrue(pressKey(.escape, in: hostingView), "nothing took the second Escape, the keyboard \(place)")
                XCTAssertEqual(cancels.calls, ["Cancel"], "the second Escape did not close the sheet, the keyboard \(place)")
            }
        }
    }

    /// An owner that keeps Escape for a button of its own while the fields
    /// are shown, as Feed Info's Done does, still has Escape close the
    /// fields first: the picker's Cancel New Folder comes before the
    /// owner's buttons, and the first button in view order with a key
    /// takes it. Then the owner's button takes it. (Import OPML's Cancel,
    /// like the Move sheet's and Add Feed's, gives Escape up while the
    /// fields are shown.)
    func testEscapeClosesTheFieldsBeforeAnOwnersOwnEscapeButton() throws {
        let dones = CallLog<String>()
        let owner = PickerOwnerKeepingEscape(library: makeLibrary(withFolders: ["Reports"]), onDone: { dones.record("Done") })

        try withHostedView(owner, until: { !self.newFolderNameFields(in: $0).isEmpty }) { hostingView in
            try typeNewFolderName("Charts", in: hostingView)
            guard pressKey(.escape, in: hostingView) else {
                throw XCTSkip("This macOS hands an offscreen window no key equivalents")
            }
            XCTAssertTrue(waitUntil {
                hostingView.layoutSubtreeIfNeeded()
                return self.newFolderNameFields(in: hostingView).isEmpty
            }, "Escape left the fields open")
            XCTAssertEqual(dones.calls, [], "the owner's button took Escape while the fields were shown")

            settleHostedView(hostingView)
            XCTAssertTrue(pressKey(.escape, in: hostingView), "nothing took the second Escape")
            XCTAssertEqual(dones.calls, ["Done"])
        }
    }

    /// What VoiceOver hears as the fields close without a folder made: that
    /// New Folder was cancelled, then the pop-up by its spoken label with
    /// the folder still chosen in it, or the cancel alone when no folder
    /// offered is chosen.
    func testClosingTheFieldsIsAnnouncedWithTheFolderStillChosen() {
        XCTAssertEqual(
            LibraryFolderPicker.newFolderCancelledAnnouncement(pickerLabel: "Destination folder", chosen: "Reports"),
            "New Folder cancelled. Destination folder: Reports."
        )
        XCTAssertEqual(
            LibraryFolderPicker.newFolderCancelledAnnouncement(pickerLabel: FeedWording.folderLabel, chosen: LibraryFolderOption.rootLabel),
            "New Folder cancelled. Folder to hold the feed's own folder: Library Root."
        )
        XCTAssertEqual(
            LibraryFolderPicker.newFolderCancelledAnnouncement(pickerLabel: "Destination folder", chosen: nil),
            "New Folder cancelled."
        )
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

/// A folder picker with its New Folder fields shown from the start, above a
/// Done button that keeps Escape while they are shown, as Feed Info's Done
/// keeps it.
private struct PickerOwnerKeepingEscape: View {
    /// The library whose folders the picker offers.
    let library: Library
    /// Done's action.
    let onDone: () -> Void

    /// The place chosen, the top level at first.
    @State private var selection = ""
    /// Why a folder could not be made; none here.
    @State private var failure: String?
    /// Whether the picker's fields are shown, which they are at first.
    @State private var isMakingFolder = true

    var body: some View {
        VStack {
            LibraryFolderPicker(
                options: LibraryFolderOption.options(in: library),
                newFolderParents: LibraryFolderOption.options(in: library),
                selection: $selection,
                caption: "Folder",
                accessibilityLabel: "Folder",
                onCreateFolder: { _, _ in .success(nil) },
                failureMessage: $failure,
                isMakingFolder: $isMakingFolder
            )
            Button("Done", action: onDone)
                .keyboardShortcut(.cancelAction)
        }
        .padding()
    }
}
