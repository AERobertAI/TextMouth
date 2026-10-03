import XCTest
@testable import TextMouth

/// An open reader keeps up with what the library does to its book from
/// another window (TODO P10): a metadata edit, a move to another folder, a
/// rename of the folder holding it, and a move of the whole data directory.
///
/// After each change, everything the reader shows or uses must match the
/// library's row: the title and author it shows (the window title, Now
/// Playing, Where Am I?) and offers its metadata editor, the book's folder
/// and file path, the audio files it plays from, and the file its player
/// holds. Whatever it saves afterwards must land in the package where the
/// book is now. Each check collects every reader field left stale, so a
/// failure names all of them at once.
@MainActor
final class ReaderRefreshTests: XCTestCase {

    // MARK: - Reproduction

    /// A text book open in a reader is renamed and credited to another
    /// author in the library's metadata editor, moved to another folder,
    /// and then has that folder renamed, all through the library model as
    /// the Library window does. The reader must show and use the book as
    /// the library now has it after each step; a bookmark added and edited
    /// and a position saved afterwards land in the package where the book
    /// is now, no old package comes back, and reopening the book shows the
    /// new metadata at the saved position.
    func testTextReaderFollowsALibraryEditMoveAndFolderRename() throws {
        let world = try makeIntegrationWorld("Reader Refresh Text")
        let book = try world.importBook(from: writeTideTablesEPUB())
        let shelf = BookFolder(name: "Shelf", parentPath: world.folder.path)
        world.library.library.folders = [BookFolder(name: world.folder.path), shelf]
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")
        var stale: [String] = []

        // The Library window's metadata editor renames the book and credits
        // another author, saving to the library only.
        var edited = try XCTUnwrap(reader.epubMetadata, "The reader read no EPUB metadata")
        edited.title = Self.revisedTitle
        edited.author = Self.revisedAuthor
        let save = world.library.saveEPUBMetadata(edited, for: book, writingToFile: false)
        XCTAssertNotNil(save.savedBook, save.message)
        stale += staleFields(of: reader, in: world.library, after: "the metadata edit")

        // Move to Folder… moves the book into Shelf.
        let packageBeforeMove = try row(of: book, in: world.library).tmbDirectory
        let move = world.library.moveBooksReturningOutcome([book], toFolder: shelf.fullPath)
        XCTAssertTrue(move.succeeded, move.failureMessage ?? "")
        stale += staleFields(of: reader, in: world.library, after: "the move to Shelf")

        // Rename Folder… renames Shelf to Stacks, which moves the package again.
        let packageBeforeRename = try row(of: book, in: world.library).tmbDirectory
        let rename = world.library.renameFolderReturningOutcome(shelf, to: "Stacks")
        XCTAssertTrue(rename.succeeded, rename.failureMessage ?? "")
        stale += staleFields(of: reader, in: world.library, after: "the folder rename")

        XCTAssertTrue(stale.isEmpty, Self.report(stale))

        // A bookmark added and then edited, and a position saved, after the
        // moves all land in the package where the book is now.
        reader.navigateTo(chapterIndex: 1, characterOffset: 4)
        let bookmark = try XCTUnwrap(reader.addBookmarkAtCurrentPosition(label: "Neap tide"))
        reader.updateBookmarkLabel(bookmark, label: "Neap tide, second reading")
        reader.savePosition()
        LibraryPersistenceService.flushPendingSave()
        let current = try row(of: book, in: world.library)
        let record = try BookInfo.load(from: current.tmbDirectory)
        XCTAssertEqual(record.bookmarks.map(\.id), [bookmark.id], "The bookmark is not in the book's package")
        XCTAssertEqual(record.bookmarks.first?.label, "Neap tide, second reading")
        XCTAssertEqual(record.state.readingPosition?.chapterIndex, 1)
        XCTAssertEqual(record.state.readingPosition?.characterOffset, 4)
        XCTAssertEqual(record.metadata.title, Self.revisedTitle)
        for old in [packageBeforeMove, packageBeforeRename] {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: old.path),
                "A write recreated the package the book left at \(Self.displayPath(old.path))"
            )
        }

        // Reopening the book from the library shows the new metadata and
        // continues from the saved position, with the bookmark.
        reader.close()
        let reopened = world.openReader(for: try row(of: book, in: world.library))
        waitForReaderToLoad(reopened)
        XCTAssertNil(reopened.errorMessage, "The moved book did not reopen")
        XCTAssertEqual(reopened.book.title, Self.revisedTitle)
        XCTAssertEqual(reopened.book.author, Self.revisedAuthor)
        XCTAssertEqual(reopened.epubMetadata?.title, Self.revisedTitle)
        XCTAssertEqual(reopened.epubMetadata?.author, Self.revisedAuthor)
        XCTAssertEqual(reopened.currentChapterIndex, 1)
        XCTAssertEqual(reopened.currentCharacterOffset, 4)
        XCTAssertEqual(reopened.bookmarks.map(\.label), ["Neap tide, second reading"])
    }

    /// While an audiobook is open, the Library window's editor renames it.
    /// The reader must show the new title and offer it in its own metadata
    /// editor, so that editor, opened afterwards to change only the genre,
    /// saves the genre without putting the old title back.
    func testReaderMetadataEditorKeepsTheLibrarysNewerTitle() throws {
        let world = try makeIntegrationWorld("Reader Refresh Audio Metadata")
        let book = try world.makeSilentAudioBook(title: "Breakwater Soundings", trackDurations: [1])
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")

        var renamed = try row(of: book, in: world.library)
        renamed.title = "Breakwater Soundings, Second Survey"
        world.library.updateBookMetadata(renamed)
        var stale = staleFields(of: reader, in: world.library, after: "the library's edit")

        var metadata = try XCTUnwrap(reader.audioMetadata, "The reader read no audio metadata")
        metadata.genre = "Field Recording"
        reader.saveAudioMetadata(metadata)

        let saved = try row(of: book, in: world.library)
        if saved.title != "Breakwater Soundings, Second Survey" {
            stale.append("the reader's own metadata save put back the title \"\(saved.title)\"")
        }
        XCTAssertEqual(saved.audioGenre, "Field Recording")
        XCTAssertTrue(stale.isEmpty, Self.report(stale))
    }

    // MARK: - Applying Updates

    /// Two readers have the same book open when the library renames it:
    /// each applies the update once, at the book's next revision, and a
    /// reader of another book hears nothing. An update delivered again, or
    /// another book's, changes nothing.
    func testEveryOpenReaderOfTheBookAppliesEachUpdateOnce() throws {
        let world = try makeIntegrationWorld("Reader Refresh Two Readers")
        let book = try world.importBook(from: writeTideTablesEPUB())
        let other = try world.makeSilentAudioBook(title: "Breakwater Soundings", trackDurations: [1])
        let readers = [world.openReader(for: book), world.openReader(for: book)]
        let otherReader = world.openReader(for: other)
        for reader in readers + [otherReader] {
            waitForReaderToLoad(reader)
        }
        // Loading can publish a revision of its own: a reader that indexes
        // its book commits the analysis, which every reader takes.
        let revisionBefore = world.library.bookUpdates.revision(of: book.id)
        let otherRevisionBefore = otherReader.appliedLibraryRevision
        let original = try row(of: book, in: world.library)

        var renamed = original
        renamed.title = Self.revisedTitle
        world.library.updateBookMetadata(renamed)

        XCTAssertEqual(world.library.bookUpdates.revision(of: book.id), revisionBefore + 1)
        for reader in readers {
            XCTAssertEqual(reader.book.title, Self.revisedTitle)
            XCTAssertEqual(reader.epubMetadata?.title, Self.revisedTitle)
            XCTAssertEqual(reader.appliedLibraryRevision, revisionBefore + 1)
        }
        XCTAssertEqual(otherReader.book.title, "Breakwater Soundings")
        XCTAssertEqual(otherReader.appliedLibraryRevision, otherRevisionBefore, "Another book's reader applied the rename")

        // The same revision again, carrying the old row, is ignored.
        readers[0].applyLibraryUpdate(LibraryBookUpdate(book: original, revision: revisionBefore + 1))
        XCTAssertEqual(readers[0].book.title, Self.revisedTitle, "A repeated revision was applied")
        // So is another book's update, whatever its revision.
        readers[0].applyLibraryUpdate(LibraryBookUpdate(book: other, revision: revisionBefore + 2))
        XCTAssertEqual(readers[0].book.title, Self.revisedTitle, "Another book's update was applied")
    }

    /// While a text book is being spoken, the library renames it and moves
    /// it to another folder. The reader takes the new title and path without
    /// reloading the book and without stopping, restarting, or moving its
    /// speech: the same text, chapter, cursor, and playback generation.
    ///
    /// Speech is marked as under way without the synthesizer, so nothing is
    /// heard; stopping or restarting it would clear or replace that mark.
    func testSpeechGoesOnThroughAnEditAndAMoveWithoutReloading() throws {
        let world = try makeIntegrationWorld("Reader Refresh Speech")
        let book = try world.importBook(from: writeTideTablesEPUB())
        let reader = world.openReader(for: book)
        waitForReaderToLoad(reader)
        XCTAssertNil(reader.errorMessage, "The book did not open")
        reader.navigateTo(chapterIndex: 1, characterOffset: 6)
        var loadingStates: [Bool] = []
        let loading = reader.$isLoading.dropFirst().sink { loadingStates.append($0) }
        defer { loading.cancel() }
        let chapterTexts = reader.content?.chapters.map(\.text)
        let generation = reader.chapterPlaybackGeneration
        reader.speechService.isSpeaking = true

        var renamed = try row(of: book, in: world.library)
        renamed.title = Self.revisedTitle
        world.library.updateBookMetadata(renamed)
        let move = world.library.moveBooksReturningOutcome([book], toFolder: "\(world.folder.path)/Shelf")
        XCTAssertTrue(move.succeeded, move.failureMessage ?? "")

        XCTAssertEqual(reader.book.title, Self.revisedTitle)
        XCTAssertEqual(reader.book.filePath, try row(of: book, in: world.library).filePath)
        XCTAssertTrue(reader.speechService.isSpeaking, "Speech was stopped")
        XCTAssertEqual(reader.chapterPlaybackGeneration, generation, "Speech was restarted or moved")
        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(reader.currentCharacterOffset, 6)
        XCTAssertEqual(reader.content?.chapters.map(\.text), chapterTexts)
        XCTAssertEqual(loadingStates, [], "The book was loaded again")
        reader.speechService.isSpeaking = false
    }

    /// The library renames a book in the moment between a reader opening it
    /// and its content arriving. Once loaded, the reader shows the new title
    /// in its metadata editor too, not the title its load started from.
    func testAnEditMadeWhileTheBookLoadsIsShownOnceItHasLoaded() throws {
        let world = try makeIntegrationWorld("Reader Refresh Loading")
        let book = try world.importBook(from: writeTideTablesEPUB())
        let reader = world.openReader(for: book)

        // The load finishes on the main queue, which runs only once this
        // test waits for it, so the edit always lands while it is under way.
        XCTAssertTrue(reader.isLoading)
        var edited = book
        edited.title = Self.revisedTitle
        edited.author = Self.revisedAuthor
        world.library.updateBookMetadata(edited)
        waitForReaderToLoad(reader)

        XCTAssertNil(reader.errorMessage, "The book did not open")
        XCTAssertEqual(reader.book.title, Self.revisedTitle)
        XCTAssertEqual(reader.epubMetadata?.title, Self.revisedTitle)
        XCTAssertEqual(reader.epubMetadata?.author, Self.revisedAuthor)
    }

    // MARK: - Stale Fields

    /// Every field of `reader` that no longer matches `library`'s row for
    /// its book, each described as "<step>: <field> is …, the library has
    /// …", or a missing audio file or one outside the book's files.
    private func staleFields(
        of reader: ReaderViewModel,
        in library: LibraryViewModel,
        after step: String
    ) -> [String] {
        guard let row = library.bookByID(reader.book.id) else {
            return ["\(step): the book is no longer in the library"]
        }
        var stale: [String] = []
        /// Notes `field` when the reader's value differs from the library's.
        func compare(_ field: String, _ readerValue: String?, _ libraryValue: String?) {
            guard readerValue != libraryValue else { return }
            stale.append(
                "\(step): \(field) is \(Self.describe(readerValue)), the library has \(Self.describe(libraryValue))"
            )
        }

        compare("book.title", reader.book.title, row.title)
        compare("book.author", reader.book.author, row.author)
        compare("book.folderPath", reader.book.folderPath, row.folderPath)
        compare("book.filePath", Self.displayPath(reader.book.filePath), Self.displayPath(row.filePath))
        compare(
            "book.tmbDirectory",
            Self.displayPath(reader.book.tmbDirectory.path),
            Self.displayPath(row.tmbDirectory.path)
        )
        if let metadata = reader.epubMetadata {
            compare("epubMetadata.title", metadata.title, row.title)
            compare("epubMetadata.author", metadata.author, row.author)
        }
        if let metadata = reader.audioMetadata {
            compare("audioMetadata.title", metadata.title, row.title)
            compare("audioMetadata.artist", metadata.artist, row.author)
        }

        // An audiobook's files are its own path (a folder of tracks, or its
        // one file) or inside it.
        for (number, path) in reader.audioChapterFiles.enumerated() {
            if !FileManager.default.fileExists(atPath: path) {
                stale.append("\(step): audio chapter file \(number + 1) is missing at \(Self.displayPath(path))")
            } else if !Self.isWithin(path, bookPath: row.filePath) {
                stale.append(
                    "\(step): audio chapter file \(number + 1) is \(Self.displayPath(path)), "
                        + "outside the book's files at \(Self.displayPath(row.filePath))"
                )
            }
        }
        if let loaded = reader.audioPlaybackService.loadedURL {
            if !FileManager.default.fileExists(atPath: loaded.path) {
                stale.append("\(step): the player holds \(Self.displayPath(loaded.path)), which no longer exists")
            } else if !Self.isWithin(loaded.path, bookPath: row.filePath) {
                stale.append(
                    "\(step): the player holds \(Self.displayPath(loaded.path)), "
                        + "outside the book's files at \(Self.displayPath(row.filePath))"
                )
            }
        }
        return stale
    }

    /// Whether `path` is the book's own path or inside it.
    private static func isWithin(_ path: String, bookPath: String) -> Bool {
        let file = URL(fileURLWithPath: path).standardizedFileURL.path
        let home = URL(fileURLWithPath: bookPath).standardizedFileURL.path
        return file == home || file.hasPrefix(home + "/")
    }

    /// `path` with the hosted tests' sandbox home shortened to "~", so
    /// messages stay readable.
    private static func displayPath(_ path: String) -> String {
        let home = HostedTestSandbox.home.standardizedFileURL.path
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardized.hasPrefix(home) ? "~" + standardized.dropFirst(home.count) : standardized
    }

    /// A value for a stale-field message: quoted text, or "nothing".
    private static func describe(_ value: String?) -> String {
        value.map { "\"\($0)\"" } ?? "nothing"
    }

    /// The failure message listing every stale field, one a line.
    private static func report(_ stale: [String]) -> String {
        "The reader kept stale state:\n" + stale.joined(separator: "\n")
    }

    // MARK: - Fixtures

    /// The title and author the Library window's editor gives the book.
    private static let revisedTitle = "Tide Tables, Revised"
    private static let revisedAuthor = "Bronagh Adeyemi"

    /// `book`'s row in `library` now.
    private func row(of book: Book, in library: LibraryViewModel) throws -> Book {
        try XCTUnwrap(library.bookByID(book.id), "\(book.title) is no longer in the library")
    }

    /// A three-chapter EPUB about tides, each chapter listed in its table
    /// of contents, in a folder of this test's own.
    private func writeTideTablesEPUB() throws -> URL {
        let epub = try makeSandboxDirectory("ReaderRefreshSources").appendingPathComponent("tide-tables.epub")
        let chapters = [
            ("Spring Tides", "Twice a month the sun and moon pull in line and the range is widest."),
            ("Neap Tides", "Between them the pulls cross and the water barely climbs the harbour steps."),
            ("Slack Water", "At the turn the current rests for a few minutes before it runs again."),
        ]
        try IntegrationEPUB.write(
            title: "Tide Tables",
            chapters: chapters.enumerated().map { number, chapter in
                IntegrationEPUBChapter(fileName: "ch0\(number + 1).xhtml", body: "<h1>\(chapter.0)</h1><p>\(chapter.1)</p>")
            },
            contents: chapters.enumerated().map { number, chapter in
                IntegrationTOCEntry(label: chapter.0, target: "ch0\(number + 1).xhtml")
            },
            to: epub
        )
        return epub
    }
}
