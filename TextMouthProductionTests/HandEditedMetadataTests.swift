import XCTest
@testable import TextMouth

/// The record of which metadata fields the user edited by hand
/// (`Book.handEdits`): the fields it names, how a row and a package record
/// keep and code it, and how a save records what it changed.
final class HandEditedMetadataTests: XCTestCase {

    // MARK: - The Fields

    /// The fields of a record are listed in the order the editors show
    /// them, each once, whatever order they were marked in.
    func testFieldsAreListedAsTheEditorsShowThem() {
        XCTAssertEqual(Book.MetadataField.ordered([.audioYear, .title, .publisher]), [.title, .publisher, .audioYear])
        XCTAssertEqual(Book.MetadataField.ordered([]), [])
        XCTAssertEqual(Book.MetadataField.ordered(Set(Book.MetadataField.allCases)), Book.MetadataField.allCases)
        XCTAssertEqual(Book.MetadataField.refreshable, [.title, .author, .publisher, .publicationDate])
    }

    /// Each field reads its own value of a book, a field the book keeps
    /// none of reading as none, and sets its own value and nothing else.
    func testEachFieldReadsAndSetsItsOwnValue() {
        var book = Self.makeBook()
        XCTAssertEqual(
            Book.MetadataField.values(in: book.editableMetadata),
            [.title: "Tide Tables", .author: "Port Authority"],
            "an EPUB with no publisher, date, album, genre, or year kept has values for its names alone"
        )

        for (number, field) in Book.MetadataField.allCases.enumerated() {
            field.set("Value \(number)", in: &book)
        }

        XCTAssertEqual(book.title, "Value 0")
        XCTAssertEqual(book.author, "Value 1")
        XCTAssertEqual(book.epubPublisher, "Value 2")
        XCTAssertEqual(book.epubPublicationDate, "Value 3")
        XCTAssertEqual(book.audioAlbum, "Value 4")
        XCTAssertEqual(book.audioGenre, "Value 5")
        XCTAssertEqual(book.audioYear, "Value 6")
        for (number, field) in Book.MetadataField.allCases.enumerated() {
            XCTAssertEqual(field.value(in: book.editableMetadata), "Value \(number)", "\(field)")
        }
        XCTAssertEqual(book.md5Hash, "hash", "only the fields change")
    }

    /// The values an EPUB editor and an audio editor open with or save, by
    /// field: the EPUB editor's four, and the audio editor's five with its
    /// artist as the author.
    func testTheEditorsValuesByField() {
        let epub = EPUBMetadata(
            title: "Tide Tables", author: "Port Authority", publisher: "Tollgate Press", publicationDate: "2026",
            isbn: "isbn", language: "en", identifier: "id", epubVersion: "3.0"
        )
        XCTAssertEqual(
            Book.MetadataField.values(in: epub),
            [.title: "Tide Tables", .author: "Port Authority", .publisher: "Tollgate Press", .publicationDate: "2026"]
        )

        let audio = AudioMetadata(
            title: "Soundings", artist: "Harbour Survey", album: "Coastal Series", genre: "Field Recording", year: "2024",
            duration: "1:00", fileFormat: "WAV"
        )
        XCTAssertEqual(
            Book.MetadataField.values(in: audio),
            [.title: "Soundings", .author: "Harbour Survey", .audioAlbum: "Coastal Series", .audioGenre: "Field Recording", .audioYear: "2024"]
        )
    }

    /// The changes of an editor's save are the fields saved with a value
    /// other than the one the editor opened with, each with the value
    /// saved: a changed value, and a value saved for a field the editor
    /// opened without; not a value saved as it opened, nor a field the save
    /// has no value for.
    func testAnEditsChangesAreTheFieldsSavedWithAnotherValue() {
        let opened: Book.MetadataValues = [.title: "Tide Tables", .author: "Port Authority", .publisher: "Tollgate Press"]
        let saved: Book.MetadataValues = [.title: "Tide Tables", .author: "Harbour Survey", .publicationDate: "2026"]

        XCTAssertEqual(
            Book.MetadataEdit(opened: opened, saved: saved).changes,
            [.author: "Harbour Survey", .publicationDate: "2026"]
        )
        XCTAssertEqual(Book.MetadataEdit(opened: opened, saved: opened).changes, [:])
        XCTAssertEqual(Book.MetadataEdit(opened: [:], saved: [:]).changes, [:])
    }

    /// Every value an edit saves loses the blanks around it: a field of
    /// nothing but blanks over an empty or unknown one is no change (and
    /// marks nothing as edited by hand), a typed value is saved trimmed,
    /// and a value whose only change is its blanks is no change.
    func testAnEditSavesEveryValueWithoutItsBlanks() {
        let opened: Book.MetadataValues = [.title: "Tide Tables", .author: "Port Authority", .publisher: "Tollgate Press"]
        let saved: Book.MetadataValues = [
            .title: "Tide Tables ",
            .author: "  Harbour Survey\n",
            .publisher: "Tollgate Press",
            .publicationDate: "   ",
            .audioAlbum: "\t\n ",
            .audioGenre: "  Field Recording "
        ]

        let edit = Book.MetadataEdit(opened: opened, saved: saved)

        XCTAssertEqual(edit.changes, [.author: "Harbour Survey", .audioGenre: "Field Recording"])
        var book = Self.makeBook()
        book.applyMetadataEdit(Book.MetadataEdit(opened: [:], saved: [.publisher: "  ", .audioYear: " \n"]))
        XCTAssertNil(book.handEdits, "blanks over empty fields marked something as edited by hand")
        XCTAssertNil(book.epubPublisher)
        XCTAssertNil(book.audioYear)
    }

    /// Clearing a field the editor opened with a value is still a change,
    /// saved as empty; and a value an older version saved with blanks
    /// around it, left alone, is no change, so it is not rewritten, while
    /// retyping it without the blanks is.
    func testClearingAFieldAndValuesSavedWithBlanksBefore() {
        XCTAssertEqual(
            Book.MetadataEdit(opened: [.publisher: "Tollgate Press"], saved: [.publisher: "   "]).changes,
            [.publisher: ""]
        )
        XCTAssertEqual(Book.MetadataEdit(opened: [.author: "  Port Authority "], saved: [.author: "  Port Authority "]).changes, [:])
        XCTAssertEqual(
            Book.MetadataEdit(opened: [.author: "  Port Authority "], saved: [.author: "Port Authority"]).changes,
            [.author: "Port Authority"]
        )
    }

    /// The EPUB and the audio editors' edits are made of the values each
    /// shows (`Book.MetadataField.values(in:)`), as it opened with them and
    /// as they were saved.
    func testTheEditorsEditsAreMadeOfTheValuesEachShows() {
        let epub = EPUBMetadata(
            title: "Tide Tables", author: "Port Authority", publisher: "Tollgate Press", publicationDate: "2026",
            isbn: "isbn", language: "en", identifier: "id", epubVersion: "3.0"
        )
        var retitled = epub
        retitled.title = "Tide Tables, Revised"
        XCTAssertEqual(
            Book.MetadataEdit(opened: epub, saved: retitled),
            Book.MetadataEdit(opened: Book.MetadataField.values(in: epub), saved: Book.MetadataField.values(in: retitled))
        )

        let audio = AudioMetadata(title: "Soundings", artist: "Harbour Survey", album: "Coastal Series")
        var regenred = audio
        regenred.genre = "Field Recording"
        XCTAssertEqual(
            Book.MetadataEdit(opened: audio, saved: regenred),
            Book.MetadataEdit(opened: Book.MetadataField.values(in: audio), saved: Book.MetadataField.values(in: regenred))
        )
        XCTAssertEqual(Book.MetadataEdit(opened: audio, saved: regenred).changes, [.audioGenre: "Field Recording"])
    }

    /// Applying an edit sets each field the user changed and records it as
    /// edited by hand; every other field keeps the book's value, even one
    /// the editor opened with an older value of, and the content hash is
    /// left alone. An edit that changed nothing changes nothing.
    func testApplyingAnEditChangesAndMarksOnlyWhatTheUserChanged() {
        var book = Self.makeBook()
        book.author = "Harbour Survey"
        let edit = Book.MetadataEdit(
            opened: [.title: "Tide Tables", .author: "Port Authority", .publisher: ""],
            saved: [.title: "Neap Tides", .author: "Port Authority", .publisher: ""]
        )

        book.applyMetadataEdit(edit)

        XCTAssertEqual(book.title, "Neap Tides")
        XCTAssertEqual(book.author, "Harbour Survey", "a field the user left alone keeps the book's newer value")
        XCTAssertNil(book.epubPublisher, "a field saved as the editor showed it is not kept")
        XCTAssertEqual(book.md5Hash, "hash")
        XCTAssertEqual(book.handEdits, Book.HandEdits(fields: [.title], sinceImport: false))

        let before = book
        book.applyMetadataEdit(Book.MetadataEdit(opened: edit.saved, saved: edit.saved))
        XCTAssertEqual(book, before, "an edit that changed nothing changed something")
    }

    // MARK: - The Record

    /// A new book has no record. Marking a field begins one, kept from
    /// that edit on; marking more adds to it and never removes a field;
    /// marking nothing changes nothing; and a record kept since the import
    /// stays one.
    func testMarkingBeginsAndGrowsTheRecord() {
        var book = Self.makeBook()
        XCTAssertNil(book.handEdits, "nothing has recorded a new book's edits")

        book.markEditedByHand([])
        XCTAssertNil(book.handEdits, "a save that changed nothing records nothing")

        book.markEditedByHand([.author])
        XCTAssertEqual(book.handEdits, Book.HandEdits(fields: [.author], sinceImport: false))

        book.markEditedByHand([.title, .author])
        XCTAssertEqual(book.handEdits?.fields, [.title, .author])
        XCTAssertEqual(book.handEdits?.sinceImport, false, "a record begun by an edit stays one begun by an edit")
        XCTAssertTrue(book.handEdits?.contains(.title) == true)
        XCTAssertFalse(book.handEdits?.contains(.publisher) == true)

        var imported = Self.makeBook()
        imported.handEdits = .noneSinceImport
        imported.markEditedByHand([.publicationDate])
        XCTAssertEqual(imported.handEdits, Book.HandEdits(fields: [.publicationDate], sinceImport: true))
    }

    /// A record is written as the same bytes whatever order its fields
    /// were marked in, and reads back equal to what was written.
    func testARecordIsWrittenAsTheSameBytesWhateverTheOrderOfItsEdits() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var markedLate = Book.HandEdits(fields: [.audioYear], sinceImport: true)
        markedLate.mark([.title, .publisher])
        let markedAtOnce = Book.HandEdits(fields: [.publisher, .title, .audioYear], sinceImport: true)

        let bytes = try encoder.encode(markedLate)

        XCTAssertEqual(bytes, try encoder.encode(markedAtOnce))
        XCTAssertEqual(
            String(decoding: bytes, as: UTF8.self),
            #"{"fields":["title","publisher","audioYear"],"sinceImport":true}"#
        )
        XCTAssertEqual(try JSONDecoder().decode(Book.HandEdits.self, from: bytes), markedAtOnce)
    }

    /// A record that names a field this version cannot edit, as a newer
    /// version of TextMouth may write, decodes without that field rather
    /// than failing; a record without `sinceImport` counts as begun by an
    /// edit.
    func testARecordWithAnUnknownFieldDecodesWithoutIt() throws {
        let newer = Data(#"{"fields":["narrator","title"],"sinceImport":true}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(Book.HandEdits.self, from: newer),
            Book.HandEdits(fields: [.title], sinceImport: true)
        )

        let bare = Data(#"{"fields":["author"]}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder().decode(Book.HandEdits.self, from: bare),
            Book.HandEdits(fields: [.author], sinceImport: false)
        )
    }

    // MARK: - The Row

    /// A row keeps its record through library.json; a row saved before
    /// edits were recorded loads with none; and a row whose record cannot
    /// be read loads with none instead of failing the library.
    func testARowKeepsItsRecordThroughTheLibraryIndex() throws {
        var book = Self.makeBook()
        book.markEditedByHand([.title, .publisher])

        let row = try Self.jsonObject(of: book)
        XCTAssertEqual(
            row["handEdits"] as? NSDictionary,
            ["fields": ["title", "publisher"], "sinceImport": false]
        )
        XCTAssertEqual(try Self.decode(Book.self, from: row), book)

        var older = row
        older.removeValue(forKey: "handEdits")
        XCTAssertNil(try Self.decode(Book.self, from: older).handEdits)

        var damaged = row
        damaged["handEdits"] = "edited"
        XCTAssertNil(try Self.decode(Book.self, from: damaged).handEdits)
    }

    /// The editable metadata carries the record, so a reader's copy that
    /// takes a row's editable metadata, or its library fields, takes the
    /// record with it.
    func testTheEditableMetadataCarriesTheRecord() {
        var row = Self.makeBook()
        row.markEditedByHand([.author])
        var copy = Self.makeBook()
        XCTAssertNil(copy.handEdits)

        copy.applyEditableMetadata(from: row)
        XCTAssertEqual(copy.handEdits, row.handEdits)

        var another = Self.makeBook()
        another.libraryFields = row.libraryFields
        XCTAssertEqual(another.handEdits, row.handEdits)
    }

    // MARK: - The Package Record

    /// The record goes into bookInfo.json's metadata and comes back on a
    /// book rebuilt from it; a record written before edits were recorded
    /// gives none.
    func testThePackageRecordKeepsIt() throws {
        var book = Self.makeBook()
        book.markEditedByHand([.publicationDate])

        let info = book.makeBookInfo()
        XCTAssertEqual(info.metadata.handEdits, book.handEdits)
        let rebuilt = Book(record: info, filePath: book.filePath, folderPath: book.folderPath, tmbDirectoryName: book.tmbDirectoryName)
        XCTAssertEqual(rebuilt.handEdits, book.handEdits)

        var older = try Self.jsonObject(of: info.metadata)
        older.removeValue(forKey: "handEdits")
        XCTAssertNil(try Self.decode(BookMetadata.self, from: older).handEdits)
    }

    // MARK: - The Saves

    /// A save through the library records the fields it changed, on the
    /// row, which it returns; a later save adds the fields it changes; a
    /// save that changes nothing, or that puts an earlier value back,
    /// leaves the record as it is; and a book that has left the library is
    /// not saved.
    @MainActor
    func testASaveRecordsTheFieldsItChangedOnTheRow() throws {
        let (model, book) = try makeLibrary()
        let names: Book.MetadataValues = [.title: book.title, .author: book.author]

        let retitled = Book.MetadataEdit(opened: names, saved: [.title: "Tide Tables, Second Edition", .author: book.author])
        let saved = model.updateBookMetadata(retitled, of: book.id)
        XCTAssertEqual(saved?.handEdits, Book.HandEdits(fields: [.title], sinceImport: false))
        XCTAssertEqual(saved?.title, "Tide Tables, Second Edition")
        XCTAssertEqual(saved, model.bookByID(book.id), "the row as saved is returned")

        let attributed = Book.MetadataEdit(opened: retitled.saved, saved: [.title: "Tide Tables, Second Edition", .author: "Harbour Survey"])
        XCTAssertEqual(model.updateBookMetadata(attributed, of: book.id)?.handEdits?.fields, [.title, .author])

        let unchanged = try XCTUnwrap(model.bookByID(book.id))
        XCTAssertEqual(
            model.updateBookMetadata(Book.MetadataEdit(opened: attributed.saved, saved: attributed.saved), of: book.id),
            unchanged,
            "a save that changes nothing changes nothing"
        )

        let putBack = Book.MetadataEdit(opened: attributed.saved, saved: [.title: book.title, .author: "Harbour Survey"])
        XCTAssertEqual(
            model.updateBookMetadata(putBack, of: book.id)?.handEdits?.fields, [.title, .author],
            "a field put back to an earlier value by a later save stays the user's own"
        )

        model.library = Library(books: [])
        XCTAssertNil(model.updateBookMetadata(Book.MetadataEdit(opened: names, saved: [.title: "Nowhere"]), of: book.id))
    }

    /// An editor's save is compared with what the editor opened with, not
    /// with the row: an editor shows the file's publisher and date for a
    /// row that keeps none, so saving them unchanged records nothing and
    /// leaves the row keeping none, while the title the user changed is
    /// saved and recorded. Compared with the row instead, the same save
    /// would count the file's values as typed.
    @MainActor
    func testAnEditorsSaveIsComparedWithWhatItOpenedWith() throws {
        let (model, book) = try makeLibrary()
        XCTAssertNil(book.epubPublisher)
        let opened = EPUBMetadata(
            title: book.title, author: book.author, publisher: "Tollgate Press", publicationDate: "2024",
            isbn: "", language: "", identifier: "", epubVersion: "3.0"
        )
        var edited = opened
        edited.title = "Tide Tables, Second Edition"

        let saved = model.updateBookMetadata(Book.MetadataEdit(opened: opened, saved: edited), of: book.id)

        XCTAssertEqual(saved?.title, "Tide Tables, Second Edition")
        XCTAssertEqual(saved?.handEdits, Book.HandEdits(fields: [.title], sinceImport: false))
        XCTAssertNil(saved?.epubPublisher, "the file's publisher, saved unchanged, is still the file's alone")
        XCTAssertNil(saved?.epubPublicationDate, "the file's date, saved unchanged, is still the file's alone")
    }

    /// The record of hand edits is the row's: a save from an editor that
    /// opened before the row's record grew keeps what the row recorded
    /// since, and adds what the save changed.
    @MainActor
    func testTheRowsRecordOutlivesAnEditorsOlderCopy() throws {
        let (model, book) = try makeLibrary()
        let opened: Book.MetadataValues = [.title: book.title, .author: book.author]
        model.updateBook(id: book.id) { $0.markEditedByHand([.author]) }

        let retitled = Book.MetadataEdit(opened: opened, saved: [.title: "Tide Tables, Second Edition", .author: book.author])
        let saved = model.updateBookMetadata(retitled, of: book.id)

        XCTAssertEqual(saved?.handEdits?.fields, [.title, .author])
    }

    /// The reader's audio metadata save records the fields it changed,
    /// compared with the tags the editor opened with, on the row and on
    /// the reader's own copy of the book.
    @MainActor
    func testTheReadersAudioSaveRecordsWhatItChanged() throws {
        let world = try makeIntegrationWorld("Hand Edited Audio Metadata")
        let book = try world.makeSilentAudioBook(title: "Breakwater Soundings", trackDurations: [1])
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")
        let opened = try XCTUnwrap(reader.audioMetadata, "The reader read no audio metadata")
        var metadata = opened

        metadata.genre = "Field Recording"
        reader.saveAudioMetadata(metadata, openedAs: opened)

        let expected = Book.HandEdits(fields: [.audioGenre], sinceImport: false)
        XCTAssertEqual(reader.book.handEdits, expected)
        XCTAssertEqual(world.library.bookByID(book.id)?.handEdits, expected)
        XCTAssertEqual(world.library.bookByID(book.id)?.audioGenre, "Field Recording")
    }

    // MARK: - What Book Info Says

    /// A field the user edited by hand is labeled so, "Book title, edited
    /// by hand", in the EPUB and audio editors and the simple sheet alike;
    /// any other field keeps its label alone, as does every field of a
    /// book without a record.
    func testAFieldEditedByHandSaysSoInItsLabel() {
        XCTAssertEqual(MetadataEditorWording.editedByHand, "edited by hand")
        let record = Book.HandEdits(fields: [.title, .audioGenre], sinceImport: false)
        XCTAssertEqual(MetadataEditorWording.fieldLabel("Book title", for: .title, in: record), "Book title, edited by hand")
        XCTAssertEqual(MetadataEditorWording.fieldLabel("Genre", for: .audioGenre, in: record), "Genre, edited by hand")
        XCTAssertEqual(MetadataEditorWording.fieldLabel("Author", for: .author, in: record), "Author")
        XCTAssertEqual(MetadataEditorWording.fieldLabel("Book title", for: .title, in: nil), "Book title")
    }

    /// The reader's Book Info for an audiobook, opened again after its
    /// audio editor saved a new title, labels the title field "Book title,
    /// edited by hand" and the artist field "Artist or narrator" alone, as
    /// the Library window's Book Info would: the reader's copy of the book
    /// holds the record its save made.
    @MainActor
    func testTheReadersAudioEditorOpenedAgainSaysWhatItsSaveEditedByHand() throws {
        let world = try makeIntegrationWorld("Reader Audio Editor Labels")
        let book = try world.makeSilentAudioBook(title: "Breakwater Soundings", trackDurations: [1])
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")
        let opened = try XCTUnwrap(reader.audioMetadata, "The reader read no audio metadata")
        var metadata = opened

        metadata.title = "Breakwater Soundings, Revised"
        reader.saveAudioMetadata(metadata, openedAs: opened)

        XCTAssertEqual(reader.book.handEdits?.fields, [.title])
        let labels = try textFieldLabels(ofBookInfoOver: reader)
        XCTAssertTrue(labels.contains("Book title, edited by hand"), "\(labels)")
        XCTAssertTrue(labels.contains("Artist or narrator"), "\(labels)")
    }

    /// The reader's Book Info for an EPUB, opened again after its metadata
    /// editor saved a new author to the library, labels the author field
    /// "Author, edited by hand" and the title field "Book title" alone.
    @MainActor
    func testTheReadersEPUBEditorOpenedAgainSaysWhatItsSaveEditedByHand() throws {
        let world = try makeIntegrationWorld("Reader EPUB Editor Labels")
        let book = try world.importBook(from: requireFile("alice.epub"))
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")
        XCTAssertTrue(waitUntil(timeout: 10) { reader.epubMetadata != nil }, "The reader showed no EPUB metadata")
        let opened = try XCTUnwrap(reader.epubMetadata)
        var metadata = opened

        metadata.author = "The Hatter"
        let outcome = reader.saveEPUBMetadata(metadata, openedAs: opened, writeToFile: false)

        XCTAssertTrue(outcome.succeeded, "\(outcome)")
        XCTAssertEqual(reader.book.handEdits?.fields, [.author])
        let labels = try textFieldLabels(ofBookInfoOver: reader)
        XCTAssertTrue(labels.contains("Author, edited by hand"), "\(labels)")
        XCTAssertTrue(labels.contains("Book title"), "\(labels)")
    }

    /// The labels VoiceOver reads for the text fields of the reader's Book
    /// Info sheet (`ReaderBookInfoSheet`) over `reader`, hosted offscreen.
    /// The test is skipped where hosted windows expose no controls.
    @MainActor
    private func textFieldLabels(ofBookInfoOver reader: ReaderViewModel) throws -> [String] {
        var labels: [String] = []
        try withHostedControls(ReaderBookInfoSheet(viewModel: reader)) { controls in
            labels = controls.filter { $0.role == .textField }.map(\.label)
        }
        return labels
    }

    // MARK: - Fixtures

    /// An EPUB row as an import lists one: named, with nothing else kept.
    /// `inPackage` false lists it without a package, so a save of it writes
    /// no record anywhere.
    static func makeBook(inPackage: Bool = true) -> Book {
        Book(
            title: "Tide Tables",
            author: "Port Authority",
            format: .epub,
            filePath: "/nowhere/Tide Tables.tmb/tide.epub",
            md5Hash: "hash",
            tmbDirectoryName: inPackage ? "Tide Tables.tmb" : ""
        )
    }

    /// The rule: a save that would leave the book with no title is refused.
    /// The user emptied one the editor opened with, or left only blanks. A
    /// book that opened without a title may be saved without one, so a
    /// change to another field is never held back.
    func testASaveThatEmptiesTheTitleIsRefused() {
        XCTAssertTrue(Book.MetadataEdit.clearsTitle(opened: "Dune", edited: ""))
        XCTAssertTrue(Book.MetadataEdit.clearsTitle(opened: "Dune", edited: "  \n "))
        XCTAssertFalse(Book.MetadataEdit.clearsTitle(opened: "Dune", edited: "Dune Messiah"))
        XCTAssertFalse(Book.MetadataEdit.clearsTitle(opened: "", edited: ""))
        XCTAssertFalse(Book.MetadataEdit.clearsTitle(opened: "   ", edited: ""))
        XCTAssertTrue(MetadataEditorWording.titleCleared.hasSuffix("save again."))
    }

    /// The model holds the rule too, so it does not rest on the editor's
    /// refusal alone: an edit that empties the title changes every other
    /// field it changes, and leaves the row's title and its record of hand
    /// edits as they were.
    @MainActor
    func testAnEditThatEmptiesTheTitleLeavesTheRowsTitleAlone() throws {
        let (model, book) = try makeLibrary()
        let opened: Book.MetadataValues = [.title: book.title, .author: book.author]

        for emptied in ["", "   "] {
            let edit = Book.MetadataEdit(opened: opened, saved: [.title: emptied, .author: "Harbour Survey"])
            XCTAssertEqual(edit.changes, [.author: "Harbour Survey"], "only the author changes")
            let saved = try XCTUnwrap(model.updateBookMetadata(edit, of: book.id))
            XCTAssertEqual(saved.title, book.title)
            XCTAssertEqual(saved.author, "Harbour Survey")
            XCTAssertEqual(saved.handEdits?.fields, [.author], "the title is not marked as edited by hand")
            XCTAssertEqual(model.bookByID(book.id)?.title, book.title)
        }

        // A title that was blank to begin with is a title like any other.
        let nameless = Book.MetadataEdit(opened: [.title: ""], saved: [.title: "Named at last"])
        XCTAssertEqual(nameless.changes, [.title: "Named at last"])

        // A blank swapped for another blank is not an edit, and spaces are
        // not a name: nothing changes, and nothing is marked edited by hand.
        for (openedTitle, savedTitle) in [("", "   "), ("   ", ""), ("   ", "  \n"), ("", "")] {
            let blank = Book.MetadataEdit(opened: [.title: openedTitle], saved: [.title: savedTitle])
            XCTAssertEqual(blank.changes, [:], "\"\(openedTitle)\" saved as \"\(savedTitle)\"")
        }
    }

    /// A library model listing one book without a package, without the
    /// app's services, whose index is put back when the test ends.
    @MainActor
    private func makeLibrary() throws -> (LibraryViewModel, Book) {
        let sandbox = try LibraryIndexSandbox.capture()
        addTeardownBlock { sandbox.restore() }
        let book = Self.makeBook(inPackage: false)
        let model = LibraryViewModel(initializeServices: false)
        model.library = Library(books: [book])
        return (model, book)
    }

    /// `value` as JSON, as an object.
    static func jsonObject(of value: some Encodable) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// `object` decoded as a `T`.
    static func decode<T: Decodable>(_ type: T.Type, from object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: try JSONSerialization.data(withJSONObject: object))
    }
}
