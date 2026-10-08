import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// An editor's save changes, and records as edited by hand, only what the
/// user changed in it (REV07, library finding 3). Every editor keeps what it
/// opened with, and its save applies to the book's row as it is by then only
/// the fields saved with another value (`Book.MetadataEdit`): a field another
/// window or the launch metadata refresh changed while the editor was open is
/// neither put back nor marked, and the spaces the Book Info sheet trims are
/// no change.
///
/// Until October 7, 2026, the Book Info sheet compared its save with the row
/// as it was at the save, a reader's editors with the reader's metadata as it
/// was at the save, which takes every change the library makes, and every
/// save wrote all of an editor's fields over the row: the first launch's
/// refresh could replace "Unknown" while a book's editor was open, and a save
/// of the title then put Unknown back for good, marked as typed by hand.
@MainActor
final class MetadataEditorBaselineTests: XCTestCase {

    /// The author the launch refresh, or another window, gives a book while
    /// one of its editors is open, in these tests.
    private static let newerAuthor = "Charles Lutwidge Dodgson"

    // MARK: - The Library's Save

    /// A field the launch refresh changed while an editor was open keeps
    /// that change when the editor saves, and is not marked; the field the
    /// user changed is saved and marked.
    func testASaveKeepsAFieldChangedWhileItsEditorWasOpen() throws {
        let (model, book) = try makeLibrary()
        let opened = Self.epubMetadata(of: book)
        // The refresh records no edit of its own.
        model.updateBook(id: book.id) { $0.author = Self.newerAuthor }

        var edited = opened
        edited.title = "Tide Tables, Second Edition"
        let saved = model.updateBookMetadata(Book.MetadataEdit(opened: opened, saved: edited), of: book.id)

        XCTAssertEqual(saved?.title, "Tide Tables, Second Edition")
        XCTAssertEqual(saved?.author, Self.newerAuthor, "the save put back the author its editor opened with")
        XCTAssertEqual(saved?.handEdits, Book.HandEdits(fields: [.title], sinceImport: false))
        XCTAssertEqual(saved, model.bookByID(book.id))
    }

    /// A save that changes nothing leaves the library as it was: nothing is
    /// published, so no Library window redraws and nothing is written.
    func testASaveThatChangesNothingWritesNothing() throws {
        let (model, book) = try makeLibrary()
        var changes = 0
        let subscription = model.$library.dropFirst().sink { _ in changes += 1 }
        defer { subscription.cancel() }
        let opened = Self.epubMetadata(of: book)

        let saved = model.updateBookMetadata(Book.MetadataEdit(opened: opened, saved: opened), of: book.id)

        XCTAssertEqual(saved, book)
        XCTAssertEqual(changes, 0, "a save that changed nothing changed the library")
    }

    // MARK: - The Book Info Sheet

    /// The Book Info sheet compares what is typed with what it opened with,
    /// both trimmed as Save trims them: a title whose only change is its
    /// spaces, as one taken from a file named "Notes .txt" has, is neither
    /// saved nor marked, and stays as it was when the user changes only the
    /// author.
    func testTheBookInfoSheetCountsNoTrimmedSpacesAsAChange() throws {
        let (model, listed) = try makeLibrary(title: "Notes ")
        let opened = LibraryBookInfoSheet.values(title: listed.title, author: listed.author)

        let untouched = try XCTUnwrap(LibraryBookInfoSheet.edit(from: opened, title: listed.title, author: listed.author))
        XCTAssertEqual(untouched.changes, [:])
        XCTAssertEqual(model.updateBookMetadata(untouched, of: listed.id), listed)

        let attributed = try XCTUnwrap(LibraryBookInfoSheet.edit(from: opened, title: listed.title, author: "Harbour Survey"))
        let saved = model.updateBookMetadata(attributed, of: listed.id)
        XCTAssertEqual(saved?.title, "Notes ", "the title was trimmed although the user left it alone")
        XCTAssertEqual(saved?.author, "Harbour Survey")
        XCTAssertEqual(saved?.handEdits, Book.HandEdits(fields: [.author], sinceImport: false))
    }

    /// An author the refresh found while the Book Info sheet was open stays
    /// when the user saves a new title from it, and is not marked.
    func testTheBookInfoSheetKeepsAnAuthorFoundWhileItWasOpen() throws {
        let (model, listed) = try makeLibrary(author: Book.unknownAuthor)
        let opened = LibraryBookInfoSheet.values(title: listed.title, author: listed.author)
        model.updateBook(id: listed.id) { $0.author = Self.newerAuthor }

        let retitled = try XCTUnwrap(LibraryBookInfoSheet.edit(from: opened, title: "Tide Tables, Second Edition", author: listed.author))
        let saved = model.updateBookMetadata(retitled, of: listed.id)

        XCTAssertEqual(saved?.title, "Tide Tables, Second Edition")
        XCTAssertEqual(saved?.author, Self.newerAuthor, "the sheet put Unknown back")
        XCTAssertEqual(saved?.handEdits, Book.HandEdits(fields: [.title], sinceImport: false))
    }

    // MARK: - The EPUB Editor

    /// The library's EPUB save from an editor that opened before the
    /// refresh found the author keeps that author on the row, unmarked, and
    /// writes it into the library's copy of the EPUB file with the user's
    /// title, so the file agrees with the row, its new hash recorded.
    func testTheEPUBSaveWritesTheRowsNewerValueIntoTheFile() throws {
        let world = try makeIntegrationWorld("Editor Baseline EPUB Write")
        let book = try world.importBook(from: requireFile("alice.epub"))
        let opened = book.mergingEditableEPUBMetadata(try EPUBParser.readMetadata(url: book.bookFileURL))
        world.library.updateBook(id: book.id) { $0.author = Self.newerAuthor }
        var edited = opened
        edited.title = "Alice's Adventures Under Ground"

        let save = world.library.saveEPUBMetadata(edited, openedAs: opened, for: book, writingToFile: true)

        let saved = try XCTUnwrap(save.savedBook, save.message)
        XCTAssertEqual(saved.title, "Alice's Adventures Under Ground")
        XCTAssertEqual(saved.author, Self.newerAuthor, "the save put back the author its editor opened with")
        XCTAssertEqual(saved.handEdits?.fields, [.title])
        let file = try EPUBParser.readMetadata(url: book.bookFileURL)
        XCTAssertEqual(file.title, "Alice's Adventures Under Ground")
        XCTAssertEqual(file.author, Self.newerAuthor, "the file took the author the editor opened with")
        XCTAssertEqual(saved.md5Hash, try FileImportService.md5Hash(of: book.bookFileURL))
        XCTAssertNotEqual(saved.md5Hash, book.md5Hash)
    }

    // MARK: - The Reader's Saves

    /// The reader's EPUB editor is open on a book listed under "Unknown"
    /// when the launch refresh finds its author in the file. The user fixes
    /// the title and saves: the author the refresh found stays, unmarked,
    /// on the row and in the reader, and the title is saved and marked.
    func testTheReadersEPUBSaveKeepsTheAuthorTheRefreshFoundWhileItsEditorWasOpen() throws {
        let world = try makeIntegrationWorld("Editor Baseline Reader Refresh")
        let imported = try world.importBook(from: requireFile("alice.epub"))
        // Listed as a row from before readers were versioned, under the
        // placeholder, with no record of hand edits, as the user's are.
        world.library.updateBook(id: imported.id) { row in
            row.author = Book.unknownAuthor
            row.metadataReaderVersion = nil
            row.handEdits = nil
        }
        let book = try XCTUnwrap(world.library.bookByID(imported.id))
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")
        XCTAssertTrue(waitUntil(timeout: 10) { reader.epubMetadata != nil }, "The reader showed no EPUB metadata")
        let opened = try XCTUnwrap(reader.epubMetadata)
        XCTAssertEqual(opened.author, Book.unknownAuthor)

        runMetadataRefresh(of: world.library)
        XCTAssertEqual(reader.epubMetadata?.author, "Lewis Carroll", "the refresh did not reach the reader")

        var edited = opened
        edited.title = "Alice's Adventures Under Ground"
        let outcome = reader.saveEPUBMetadata(edited, openedAs: opened, writeToFile: false)

        XCTAssertTrue(outcome.succeeded, "\(outcome)")
        let row = try XCTUnwrap(world.library.bookByID(book.id))
        XCTAssertEqual(row.title, "Alice's Adventures Under Ground")
        XCTAssertEqual(row.author, "Lewis Carroll", "the save put Unknown back")
        XCTAssertEqual(row.handEdits, Book.HandEdits(fields: [.title], sinceImport: false))
        XCTAssertEqual(reader.book.author, "Lewis Carroll")
        XCTAssertEqual(reader.epubMetadata?.author, "Lewis Carroll")
        XCTAssertEqual(reader.epubMetadata?.title, "Alice's Adventures Under Ground")
    }

    /// The reader's audio editor is open when another window renames the
    /// book. The user changes the genre and saves: the new title stays,
    /// unmarked, on the row and in the reader, and the genre is saved and
    /// marked.
    func testTheReadersAudioSaveKeepsATitleChangedWhileItsEditorWasOpen() throws {
        let world = try makeIntegrationWorld("Editor Baseline Reader Audio")
        let book = try world.makeSilentAudioBook(title: "Breakwater Soundings", trackDurations: [1])
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")
        let opened = try XCTUnwrap(reader.audioMetadata, "The reader read no audio metadata")
        world.library.updateBook(id: book.id) { $0.title = "Breakwater Soundings, Second Survey" }
        XCTAssertEqual(reader.audioMetadata?.title, "Breakwater Soundings, Second Survey", "the rename did not reach the reader")

        var edited = opened
        edited.genre = "Field Recording"
        reader.saveAudioMetadata(edited, openedAs: opened)

        let row = try XCTUnwrap(world.library.bookByID(book.id))
        XCTAssertEqual(row.title, "Breakwater Soundings, Second Survey", "the save put back the title its editor opened with")
        XCTAssertEqual(row.audioGenre, "Field Recording")
        XCTAssertEqual(row.handEdits, Book.HandEdits(fields: [.audioGenre], sinceImport: false))
        XCTAssertEqual(reader.book.title, "Breakwater Soundings, Second Survey")
        XCTAssertEqual(reader.audioMetadata?.title, "Breakwater Soundings, Second Survey")
        XCTAssertEqual(reader.audioMetadata?.genre, "Field Recording")
        XCTAssertEqual(reader.lastAnnouncement, "Metadata updated")
    }

    /// The reader's audio save for a book that has left the library saves
    /// nothing, so the reader keeps its book and metadata as they were and
    /// says the edit had nowhere to go, as the EPUB editor's save does.
    func testTheReadersAudioSaveOfABookThatLeftTheLibraryChangesNothing() throws {
        let world = try makeIntegrationWorld("Editor Baseline Reader Audio Gone")
        let book = try world.makeSilentAudioBook(title: "Breakwater Soundings", trackDurations: [1])
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")
        let opened = try XCTUnwrap(reader.audioMetadata, "The reader read no audio metadata")
        world.library.library.removeBook(id: book.id)

        var edited = opened
        edited.title = "Breakwater Soundings, Second Survey"
        reader.saveAudioMetadata(edited, openedAs: opened)

        XCTAssertEqual(reader.book.title, "Breakwater Soundings")
        XCTAssertEqual(reader.audioMetadata?.title, "Breakwater Soundings")
        XCTAssertEqual(reader.lastAnnouncement, EPUBMetadataSaveWording.notInLibrary(title: "Breakwater Soundings"))
    }

    // MARK: - The Editors Keep What They Opened With

    /// The reader's Book Info for an EPUB, open while the refresh finds the
    /// book's author, keeps the author it opened with in its field; the
    /// user types a new title and presses Command-Return, and the save
    /// changes the title alone: the author the refresh found stays,
    /// unmarked.
    func testTheReadersEPUBEditorSavesOnlyWhatTheUserTyped() throws {
        let world = try makeIntegrationWorld("Editor Baseline Hosted EPUB")
        let book = try world.importBook(from: requireFile("alice.epub"))
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")
        XCTAssertTrue(waitUntil(timeout: 10) { reader.epubMetadata != nil }, "The reader showed no EPUB metadata")

        try withHostedView(ReaderBookInfoSheet(viewModel: reader), until: { self.editableFields(in: $0).count >= 4 }) { hostingView in
            world.library.updateBook(id: book.id) { $0.author = Self.newerAuthor }
            letViewSettle(hostingView)
            XCTAssertEqual(reader.epubMetadata?.author, Self.newerAuthor, "the refresh did not reach the reader")

            try replaceText(of: field(labelled: "Book title", in: hostingView), with: "Alice's Adventures Under Ground", in: hostingView)
            try pressReturn(holding: .command, in: hostingView)

            let row = try XCTUnwrap(world.library.bookByID(book.id))
            XCTAssertEqual(row.title, "Alice's Adventures Under Ground", "Command-Return did not save the title typed")
            XCTAssertEqual(row.author, Self.newerAuthor, "the editor put back the author it opened with")
            XCTAssertEqual(row.handEdits?.fields, [.title])
        }
    }

    /// The reader's Book Info for an audiobook, open while another window
    /// renames the book, keeps the title it opened with in its field; the
    /// user types a genre and presses Command-Return, and the save changes
    /// the genre alone: the new title stays, unmarked.
    func testTheReadersAudioEditorSavesOnlyWhatTheUserTyped() throws {
        let world = try makeIntegrationWorld("Editor Baseline Hosted Audio")
        let book = try world.makeSilentAudioBook(title: "Breakwater Soundings", trackDurations: [1])
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")
        XCTAssertNotNil(reader.audioMetadata, "The reader read no audio metadata")

        try withHostedView(ReaderBookInfoSheet(viewModel: reader), until: { self.editableFields(in: $0).count >= 5 }) { hostingView in
            world.library.updateBook(id: book.id) { $0.title = "Breakwater Soundings, Second Survey" }
            letViewSettle(hostingView)

            try replaceText(of: field(labelled: "Genre", in: hostingView), with: "Field Recording", in: hostingView)
            try pressReturn(holding: .command, in: hostingView)
            // The audio editor saves once it has closed.
            XCTAssertTrue(
                waitUntil(timeout: 5) { world.library.bookByID(book.id)?.audioGenre == "Field Recording" },
                "Command-Return did not save the genre typed"
            )

            let row = try XCTUnwrap(world.library.bookByID(book.id))
            XCTAssertEqual(row.title, "Breakwater Soundings, Second Survey", "the editor put back the title it opened with")
            XCTAssertEqual(row.handEdits, Book.HandEdits(fields: [.audioGenre], sinceImport: false))
        }
    }

    /// The reader's Book Info for a plain text book, the Book Info sheet,
    /// open while another window credits an author, keeps the author it
    /// opened with in its field; the user types a new title and presses
    /// Return, and the save changes the title alone: the new author stays,
    /// unmarked.
    func testTheReadersBookInfoSheetSavesOnlyWhatTheUserTyped() throws {
        let world = try makeIntegrationWorld("Editor Baseline Hosted Text")
        let source = try makeSandboxDirectory("Editor Baseline Text").appendingPathComponent("Tide Tables.txt")
        try Data("High water at the harbour mouth.\n".utf8).write(to: source)
        let book = try world.importBook(from: source)
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")

        try withHostedView(ReaderBookInfoSheet(viewModel: reader), until: { self.editableFields(in: $0).count >= 2 }) { hostingView in
            world.library.updateBook(id: book.id) { $0.author = "Port Authority" }
            letViewSettle(hostingView)

            try replaceText(of: field(labelled: "Book title", in: hostingView), with: "Tide Tables, Revised", in: hostingView)
            try pressReturn(holding: [], in: hostingView)
            // The sheet saves once it has closed.
            XCTAssertTrue(
                waitUntil(timeout: 5) { world.library.bookByID(book.id)?.title == "Tide Tables, Revised" },
                "Return did not save the title typed"
            )

            let row = try XCTUnwrap(world.library.bookByID(book.id))
            XCTAssertEqual(row.author, "Port Authority", "the sheet put back the author it opened with")
            XCTAssertEqual(row.handEdits?.fields, [.title])
        }
    }

    // MARK: - Hosted Editors

    /// The editable text fields AppKit drew below `root`.
    private func editableFields(in root: NSView) -> [NSTextField] {
        descendants(of: root, as: NSTextField.self).filter(\.isEditable)
    }

    /// The editable text field below `hostingView` that VoiceOver names
    /// `label`: found among the controls the hosted window exposes to
    /// accessibility, or else among the fields AppKit drew. Skips where
    /// SwiftUI drew no AppKit text field at all, which leaves nothing to
    /// type into.
    private func field(labelled label: String, in hostingView: NSView) throws -> NSTextField {
        let fields = editableFields(in: hostingView)
        guard !fields.isEmpty else {
            throw XCTSkip("SwiftUI drew no AppKit text field for the hosted editor in this run")
        }
        let exposed = accessibleControls(in: hostingView)
            .first { $0.role == .textField && $0.label == label }?
            .element as? NSTextField
        return try XCTUnwrap(
            exposed ?? fields.first { $0.accessibilityLabel() == label },
            "No field is labelled \(label): \(fields.map { $0.accessibilityLabel() ?? "unlabelled" })"
        )
    }

    /// Gives `field` keyboard focus and replaces its text with `text`
    /// through the window's field editor, as typing does, so the editor's
    /// binding follows; skips where an offscreen window gives a field no
    /// focus.
    private func replaceText(of field: NSTextField, with text: String, in hostingView: NSView) throws {
        guard let window = hostingView.window, window.makeFirstResponder(field),
              let editor = window.firstResponder as? NSTextView else {
            throw XCTSkip("This macOS gives an offscreen window's field no keyboard focus")
        }
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        letViewSettle(hostingView)
    }

    /// Presses Return with `modifiers` held in the window hosting
    /// `hostingView`, offered as a key equivalent, as AppKit offers a key
    /// pressed in a window first, so the button with that shortcut takes
    /// it: Command-Return is the metadata editor's Save, and Return alone
    /// the Book Info sheet's. Skips where an offscreen window takes no key
    /// equivalent, as some macOS releases hand it none. The key is never
    /// sent on as a key press, which, left unanswered, would beep.
    private func pressReturn(holding modifiers: NSEvent.ModifierFlags, in hostingView: NSView) throws {
        guard let window = hostingView.window,
              let event = NSEvent.keyEvent(
                  with: .keyDown,
                  location: .zero,
                  modifierFlags: modifiers,
                  timestamp: ProcessInfo.processInfo.systemUptime,
                  windowNumber: window.windowNumber,
                  context: nil,
                  characters: "\r",
                  charactersIgnoringModifiers: "\r",
                  isARepeat: false,
                  keyCode: 36
              ) else {
            throw XCTSkip("No key event could be made for the hosting window")
        }
        guard window.performKeyEquivalent(with: event) else {
            throw XCTSkip("This macOS hands an offscreen window no key equivalents")
        }
        letViewSettle(hostingView)
    }

    /// Lets SwiftUI apply its pending updates, as after typing, a press, or
    /// a change of what a view shows.
    private func letViewSettle(_ hostingView: NSView) {
        _ = waitUntil(timeout: 0.25) {
            hostingView.layoutSubtreeIfNeeded()
            return false
        }
    }

    // MARK: - Fixtures

    /// A library model listing one EPUB without a package, titled `title`
    /// and credited to `author`, with nothing else kept and no record of
    /// hand edits, without the app's services; its index is put back when
    /// the test ends.
    private func makeLibrary(title: String = "Tide Tables", author: String = "Port Authority") throws -> (LibraryViewModel, Book) {
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        let book = Book(title: title, author: author, format: .epub, filePath: "/nowhere/tide.epub", md5Hash: "hash")
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        return (model, book)
    }

    /// The metadata an EPUB editor opens with for `book`, whose file names
    /// a publisher and a date the row keeps none of.
    private static func epubMetadata(of book: Book) -> EPUBMetadata {
        book.mergingEditableEPUBMetadata(EPUBMetadata(
            title: "Tide Tables", author: "Port Authority", publisher: "Tollgate Press", publicationDate: "2024",
            isbn: "", language: "en", identifier: "", epubVersion: "3.0"
        ))
    }

    /// Runs the launch metadata refresh of `library` to its end, reading the
    /// books' files where they are.
    private func runMetadataRefresh(of library: LibraryViewModel) {
        let finished = expectation(description: "The metadata refresh finished")
        library.refreshOutdatedMetadata { finished.fulfill() }
        wait(for: [finished], timeout: 10)
    }
}
