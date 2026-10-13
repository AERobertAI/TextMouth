import os
import XCTest
@testable import TextMouth

/// Edit Text in Default Editor (FR05): a text book's content.md opens in
/// the user's own editor, explained the first time, and what the user
/// saves becomes the book's text: indexed afresh, its fingerprints those
/// of the edited bytes so it is never rebuilt from the source, its kept
/// reading text dropped, its open readers refreshed near where they were,
/// and "Text updated" announced. An edit that leaves no chapter, one made
/// while the book's own file changed too, and one of a text only in the
/// cloud are left alone; one made during a hold on the storage work waits
/// for the hold. An edit that cannot be taken is kept beside content.md,
/// and neither a reader nor any rebuild of the text replaces it; a rebuild
/// that replaces text the user saved keeps it first. An edit saved while
/// TextMouth was closed, with no session to see it, is taken by the
/// launch's cache pass when it parses, and kept beside content.md before
/// any rebuild otherwise.
///
/// Every editor here is the test's own: it opens no app, shows no dialog,
/// remembers its explanation in a sandboxed store, and takes TextMouth to
/// be active. Books live in a library folder of the test's own, and no
/// reader speaks.
@MainActor
final class BookTextEditTests: XCTestCase {

    // MARK: - Opening the Editor

    /// The first Edit Text explains what will happen, then opens the
    /// book's content.md in the default app; later ones open it at once.
    /// Edit Text With… opens it in the app chosen.
    func testTheFirstEditExplainsThenEveryEditOpensContentMarkdown() async throws {
        let world = try makeIntegrationWorld("Edit Text Open")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let other = try world.importBook(from: writeSource(named: "Lock Keeper.md", Self.twoChapters))
        let editor = makeEditor()
        defer { editor.endAll() }
        let app = URL(fileURLWithPath: "/Applications/TextEdit.app", isDirectory: true)
        editor.recorder.chosenApp = app

        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        await editor.editor.edit(other, choosingApp: true, in: world.library, from: nil)

        XCTAssertEqual(editor.recorder.explained, [book.title], "the explanation is given once")
        XCTAssertEqual(editor.recorder.choseAppFor, [other.title])
        XCTAssertEqual(editor.recorder.opened.map(\.file), [
            MarkdownCacheService.cacheURL(for: book),
            MarkdownCacheService.cacheURL(for: other),
        ])
        XCTAssertEqual(editor.recorder.opened.map(\.app), [nil, app])
        XCTAssertEqual(editor.sessions.bookIDs, [book.id, other.id])
    }

    /// Cancelling the explanation, or the app chooser, opens nothing and
    /// edits nothing; the explanation is given again next time.
    func testCancellingOpensNothing() async throws {
        let world = try makeIntegrationWorld("Edit Text Cancel")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let editor = makeEditor()
        defer { editor.endAll() }

        editor.recorder.goesOn = false
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        editor.recorder.goesOn = true
        editor.recorder.chosenApp = nil
        await editor.editor.edit(book, choosingApp: true, in: world.library, from: nil)

        XCTAssertEqual(editor.recorder.explained, [book.title, book.title])
        XCTAssertEqual(editor.recorder.opened.count, 0)
        XCTAssertEqual(editor.sessions.bookIDs, [])
    }

    /// An audiobook has no text to edit here yet, and a text only in the
    /// cloud is not downloaded to be edited: each says why, and opens
    /// nothing.
    func testAnAudiobookAndATextInTheCloudAreNotOpened() async throws {
        let world = try makeIntegrationWorld("Edit Text Refused")
        let audiobook = try world.makeSilentAudioBook(title: "Tide Clock Recordings", trackDurations: [1])
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let cloud = CloudSwitch(MarkdownCacheService.cacheURL(for: book))
        cloud.isInCloud = true
        let editor = makeEditor(access: cloud.access)
        defer { editor.endAll() }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        await editor.editor.edit(audiobook, choosingApp: false, in: world.library, from: nil)
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)

        XCTAssertEqual(announcements.messages, [
            BookTextEditWording.noText(bookTitle: audiobook.title),
            LibraryCloudWording.notDownloaded(titles: [book.title]),
        ])
        XCTAssertEqual(editor.recorder.opened.count, 0)
        XCTAssertFalse(BookTextEditor.canEditText(of: audiobook))
        XCTAssertTrue(BookTextEditor.canEditText(of: book))
    }

    /// An editor that cannot open the text says so, and ends the session
    /// it began.
    func testAnEditorThatCannotOpenSaysWhy() async throws {
        let world = try makeIntegrationWorld("Edit Text Open Failure")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let editor = makeEditor()
        defer { editor.endAll() }
        editor.recorder.openError = CocoaError(.fileReadNoPermission)
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)

        let reason = CocoaError(.fileReadNoPermission).localizedDescription
        XCTAssertEqual(announcements.messages, [BookTextEditWording.openFailed(bookTitle: book.title, reason: reason)])
        XCTAssertEqual(editor.sessions.bookIDs, [])
    }

    // MARK: - Taking an Edit

    /// An edit saved in the editor is the book's text once TextMouth is
    /// active again: content.md is indexed afresh (its new paragraph,
    /// renamed heading, and counts), the record's fingerprints become those
    /// of the edited bytes beside the unchanged source's, so the next open
    /// uses that index and rebuilds nothing from the source; the kept
    /// reading text is dropped; the library row and the open reader take
    /// the edit, the reader's cursor staying at the words it was at; and
    /// VoiceOver hears "Text updated".
    func testAnEditIsTakenAsTheBooksText() async throws {
        let world = try makeIntegrationWorld("Edit Text Taken")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let reader = world.openReader(for: book)
        await waitForReaderToLoadYielding(reader)
        let channel = try XCTUnwrap(reader.content?.chapters[1].text)
        reader.navigateTo(chapterIndex: 1, characterOffset: (channel as NSString).range(of: "Buoys").location)
        let sourceBefore = try XCTUnwrap(BookInfo.load(from: book.tmbDirectory).state.textCacheFingerprint?.source)
        let editor = makeEditor()
        defer { editor.endAll() }
        let kept = editor.readingTexts.url(for: book.id)
        try FileManager.default.createDirectory(at: kept.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("kept reading text".utf8).write(to: kept)
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        let cache = MarkdownCacheService.cacheURL(for: book)
        try Self.editedChapters.write(to: cache, atomically: true, encoding: .utf8)
        editor.editor.appBecameActive()

        let shown = await eventually(timeout: 10) { reader.content?.chapters[1].text.contains("A pilot boat waits") == true }
        XCTAssertTrue(shown, "the reader never showed the edit")
        // content.md is the edit, never rebuilt from the source.
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), Self.editedChapters)
        XCTAssertEqual(debugLogLines(containing: "CACHE_STALE: \(book.title):"), [])
        // The record indexes the edit, fingerprinted as it is.
        let record = try BookInfo.load(from: book.tmbDirectory)
        let index = try XCTUnwrap(record.contentIndex)
        XCTAssertEqual(index.allHeadings.map(\.text), ["Harbour", "Channel", "Sandbanks"])
        XCTAssertEqual(record.state.cacheFormatVersion, MarkdownCacheService.currentCacheVersion)
        let fingerprint = try XCTUnwrap(record.state.textCacheFingerprint)
        XCTAssertEqual(fingerprint.cache.digest, try FileImportService.md5Hash(of: cache))
        XCTAssertEqual(fingerprint.cache.stamp, FileStamp(of: cache))
        XCTAssertEqual(fingerprint.source, sourceBefore)
        XCTAssertEqual(index.textCacheFingerprint, fingerprint)
        // The kept reading text is gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.path), "the kept reading text was not dropped")
        // The row and the reader's copy take the edit's counts.
        let row = try XCTUnwrap(world.library.bookByID(book.id))
        XCTAssertEqual(row.totalWordCount, index.totalWordCount)
        XCTAssertEqual(row.textCacheFingerprint, fingerprint)
        XCTAssertEqual(reader.book.textCacheFingerprint, fingerprint)
        // The reader shows the edit at the words it was at.
        let edited = try XCTUnwrap(reader.content?.chapters[1].text)
        XCTAssertEqual(reader.currentChapterIndex, 1)
        XCTAssertEqual(reader.currentCharacterOffset, (edited as NSString).range(of: "Buoys").location)
        XCTAssertEqual(reader.headings.map(\.text), ["Harbour", "Channel", "Sandbanks"])
        XCTAssertEqual(announcements.messages, [BookTextEditWording.updated])
        // The next open reads the edit through its saved index.
        let reopened = try BookContentAnalysisService.load(book: row)
        XCTAssertTrue(reopened.usedPersistedIndex, "the next open did not use the edit's index")
        XCTAssertTrue(reopened.content.chapters[1].text.contains("A pilot boat waits"))
    }

    /// A save the watcher hears is taken without TextMouth becoming active,
    /// even when the editor saves by replacing the file, as TextEdit does.
    func testTheWatcherHearsAnEditorReplacingTheFile() async throws {
        let world = try makeIntegrationWorld("Edit Text Watched")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let editor = makeEditor()
        defer { editor.endAll() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        let wordsBefore = try XCTUnwrap(world.library.bookByID(book.id)?.totalWordCount)

        let cache = MarkdownCacheService.cacheURL(for: book)
        let saving = book.tmbDirectory.appendingPathComponent(".content.md.saving")
        try Self.editedChapters.write(to: saving, atomically: false, encoding: .utf8)
        _ = try FileManager.default.replaceItemAt(cache, withItemAt: saving)

        let taken = await eventually(timeout: 10) { world.library.bookByID(book.id)?.totalWordCount != wordsBefore }
        XCTAssertTrue(taken, "the watcher never took the edit")
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), Self.editedChapters)
    }

    /// A reader about to read a book whose edit has not been taken yet has
    /// it taken first, so it reads the edit rather than finding content.md
    /// changed and rebuilding it from the source.
    func testAReaderOpeningBeforeTheEditIsTakenReadsTheEdit() async throws {
        let world = try makeIntegrationWorld("Edit Text Before Open")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let editor = makeEditor(sessions: .shared)
        defer { editor.endAll() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        try Self.editedChapters.write(to: MarkdownCacheService.cacheURL(for: book), atomically: true, encoding: .utf8)

        let loaded = try ReaderViewModel.readContent(of: book, readingTexts: nil)

        XCTAssertTrue(loaded.content.chapters[1].text.contains("A pilot boat waits"), "the read missed the edit")
        XCTAssertFalse(loaded.shouldPersistContentIndex, "the edit's index was not already saved")
        XCTAssertEqual(debugLogLines(containing: "CACHE_STALE: \(book.title):"), [])
        XCTAssertEqual(
            try String(contentsOf: MarkdownCacheService.cacheURL(for: book), encoding: .utf8),
            Self.editedChapters
        )
    }

    // MARK: - Edits Left Alone

    /// An edit leaving no chapter with anything in it, or bytes that are not
    /// UTF-8, is refused and kept beside content.md exactly as saved, and
    /// VoiceOver hears why and the copy's name once, however often it is
    /// checked; content.md stays as the user saved it, and the record, the
    /// row, and the reader keep the text they had.
    func testARefusedEditIsKeptAndTheEarlierTextStays() async throws {
        let world = try makeIntegrationWorld("Edit Text Refused Edit")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let reader = world.openReader(for: book)
        await waitForReaderToLoadYielding(reader)
        let indexBefore = try XCTUnwrap(BookInfo.load(from: book.tmbDirectory).contentIndex)
        let textBefore = reader.content?.chapters.map(\.text)
        let editor = makeEditor()
        defer { editor.endAll() }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        let cache = MarkdownCacheService.cacheURL(for: book)

        let blank = Data("   \n\n\t\n".utf8)
        try blank.write(to: cache)
        let blankHeard = await check(book, with: editor, in: announcements)
        let blankCopy = try XCTUnwrap(keptCopies(of: book).last, "the refused edit was not kept")
        XCTAssertEqual(try Data(contentsOf: blankCopy), blank)
        XCTAssertEqual(blankHeard, [BookTextEditWording.notTaken(.noChapters, bookTitle: book.title, keptCopy: blankCopy)])
        let blankAgain = await check(book, with: editor, in: announcements)
        XCTAssertEqual(blankAgain, [], "the same refusal was announced again")
        XCTAssertEqual(keptCopies(of: book), [blankCopy], "the same edit was kept twice")

        let notText = Data([0x48, 0xFF, 0xFE, 0x69])
        try notText.write(to: cache)
        let notTextHeard = await check(book, with: editor, in: announcements)
        let notTextCopy = try XCTUnwrap(keptCopies(of: book).first { (try? Data(contentsOf: $0)) == notText })
        XCTAssertEqual(keptCopies(of: book).count, 2)
        XCTAssertEqual(notTextHeard, [BookTextEditWording.notTaken(.notText, bookTitle: book.title, keptCopy: notTextCopy)])

        XCTAssertEqual(try Data(contentsOf: cache), notText, "content.md is not as the user saved it")
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).contentIndex, indexBefore)
        XCTAssertEqual(world.library.bookByID(book.id)?.totalWordCount, indexBefore.totalWordCount)
        XCTAssertEqual(reader.content?.chapters.map(\.text), textBefore)
    }

    /// content.md edited while the book's own file changed too is not taken:
    /// it is kept beside content.md, and VoiceOver hears so once, with the
    /// copy's name. Reading the book then reads its text from the changed
    /// file, as the announcement says, which says nothing more, and the
    /// user's next save is checked against that text, so it is taken.
    func testAnEditBesideAChangedSourceIsKeptThenTheChangedFileIsRead() async throws {
        let world = try makeIntegrationWorld("Edit Text Source Changed")
        let book = try world.importBook(from: writeSource(named: "Tide Tables.md", Self.twoChapters))
        let indexBefore = try XCTUnwrap(BookInfo.load(from: book.tmbDirectory).contentIndex)
        let editor = makeEditor(sessions: .shared)
        defer { editor.endAll() }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        let cache = MarkdownCacheService.cacheURL(for: book)

        try (Self.twoChapters + "\n\nA new closing line.").write(to: book.bookFileURL, atomically: true, encoding: .utf8)
        try Self.editedChapters.write(to: cache, atomically: true, encoding: .utf8)
        let heard = await check(book, with: editor, in: announcements)
        let kept = try XCTUnwrap(keptCopies(of: book).first, "the edit was not kept")
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), Self.editedChapters)
        XCTAssertEqual(heard, [BookTextEditWording.notTaken(.sourceChanged, bookTitle: book.title, keptCopy: kept)])
        let heardAgain = await check(book, with: editor, in: announcements)
        XCTAssertEqual(heardAgain, [])
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).contentIndex, indexBefore)

        let loaded = try ReaderViewModel.readContent(of: book, readingTexts: nil)
        XCTAssertTrue(loaded.content.chapters.last?.text.contains("A new closing line.") == true, "the changed file was not read")
        XCTAssertFalse(try String(contentsOf: cache, encoding: .utf8).contains("A pilot boat waits"))
        XCTAssertEqual(keptCopies(of: book), [kept], "the edit was kept twice")
        let afterRead = await eventually(timeout: 1) { announcements.messages.count > heard.count }
        XCTAssertFalse(afterRead, "the copy already named was announced again: \(announcements.messages)")

        try (Self.editedChapters + "\n\nA new closing line.").write(to: cache, atomically: true, encoding: .utf8)
        let nextSave = await check(book, with: editor, in: announcements)
        XCTAssertEqual(nextSave, [BookTextEditWording.updated], "the next save was not taken")
    }

    /// A reader opening a book whose saved edit cannot be taken reads
    /// nothing, which would rebuild the text over the edit: it shows why,
    /// naming the copy kept, and content.md stays as the user saved it. Once
    /// the user saves text that can be taken, the reader opens the book with
    /// it.
    func testAReaderStopsOverAnEditNotTakenAndOpensOnceOneIsTaken() async throws {
        let world = try makeIntegrationWorld("Edit Text Held Reader")
        let book = try world.importBook(from: writeSource(named: "Ferry Timetable.md", Self.twoChapters))
        let editor = makeEditor(sessions: .shared)
        defer { editor.endAll() }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        let cache = MarkdownCacheService.cacheURL(for: book)
        let staleLines = debugLogLines(containing: "CACHE_STALE: \(book.title):").count
        let notText = Data([0x48, 0xFF, 0xFE, 0x69])
        try notText.write(to: cache)

        XCTAssertThrowsError(try ReaderViewModel.readContent(of: book, readingTexts: nil)) { error in
            guard let held = error as? BookTextEditPending else {
                return XCTFail("the read was not held: \(error)")
            }
            XCTAssertEqual(held.refusal, .notText)
            XCTAssertNotNil(held.keptCopy)
        }
        let reader = world.openReader(for: book)
        await waitForReaderToLoadYielding(reader)
        let kept = try XCTUnwrap(keptCopies(of: book).first, "the edit was not kept")
        XCTAssertEqual(keptCopies(of: book), [kept], "the edit was kept twice")
        XCTAssertEqual(reader.loadErrorMessage, BookTextEditWording.held(.notText, bookTitle: book.title, keptCopy: kept))
        XCTAssertNil(reader.content)
        XCTAssertEqual(try Data(contentsOf: cache), notText, "the text was rebuilt over the edit")
        XCTAssertEqual(debugLogLines(containing: "CACHE_STALE: \(book.title):").count, staleLines)

        try Self.editedChapters.write(to: cache, atomically: true, encoding: .utf8)
        editor.editor.appBecameActive()
        let opened = await eventually(timeout: 10) { reader.content?.chapters[1].text.contains("A pilot boat waits") == true }
        XCTAssertTrue(opened, "the reader did not open the book once the edit was taken")
        XCTAssertNil(reader.loadErrorMessage)
        XCTAssertEqual(reader.headings.map(\.text), ["Harbour", "Channel", "Sandbanks"])
    }

    /// Redo Text Extraction reads each book's text from its own file again,
    /// but never over an edit not taken, which it leaves as the user saved
    /// it. Text the user saved and TextMouth took is kept beside content.md
    /// before it is replaced, VoiceOver hears where, and the user's next
    /// check is made against the text read again, so nothing is taken twice.
    func testRedoTextExtractionKeepsWhatTheUserSaved() async throws {
        let world = try makeIntegrationWorld("Edit Text Redo")
        let taken = try world.importBook(from: writeSource(named: "Pier Lamps.md", Self.twoChapters))
        // Text of its own: the library lists one book of each content.
        let refused = try world.importBook(
            from: writeSource(named: "Canal Locks.md", Self.twoChapters + "\n\nBarges wait at the lower gate.")
        )
        XCTAssertNotNil(world.library.bookByID(refused.id), "the second book was not listed")
        let takenCache = MarkdownCacheService.cacheURL(for: taken)
        let refusedCache = MarkdownCacheService.cacheURL(for: refused)
        let extracted = try String(contentsOf: takenCache, encoding: .utf8)
        let editor = makeEditor(sessions: .shared)
        defer { editor.endAll() }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        await editor.editor.edit(taken, choosingApp: false, in: world.library, from: nil)
        await editor.editor.edit(refused, choosingApp: false, in: world.library, from: nil)
        let heldLines = debugLogLines(containing: "TEXT_EDIT_HELD: \(refused.title):").count

        try Self.editedChapters.write(to: takenCache, atomically: true, encoding: .utf8)
        let blank = Data(" \n\t\n".utf8)
        try blank.write(to: refusedCache)
        editor.editor.appBecameActive()
        let settled = await eventually(timeout: 10) {
            announcements.messages.contains(BookTextEditWording.updated) && announcements.messages.count == 2
        }
        XCTAssertTrue(settled, "the edits were not checked: \(announcements.messages)")
        let refusedCopies = keptCopies(of: refused)
        XCTAssertEqual(refusedCopies.count, 1)

        let outcome = await world.library.redoAllTextExtractionReturningOutcome()
        XCTAssertEqual(
            outcome,
            .success("Done. 1 book whose edited text can't be used yet was skipped."),
            "Redo Text Extraction did not say it skipped the book held over its edit"
        )

        XCTAssertEqual(try Data(contentsOf: refusedCache), blank, "the text was rebuilt over an edit not taken")
        XCTAssertEqual(keptCopies(of: refused), refusedCopies)
        XCTAssertEqual(debugLogLines(containing: "TEXT_EDIT_HELD: \(refused.title):").count, heldLines + 1)
        XCTAssertEqual(try String(contentsOf: takenCache, encoding: .utf8), extracted, "the text was not read again")
        let kept = try XCTUnwrap(keptCopies(of: taken).first, "the text taken was not kept")
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), Self.editedChapters)
        let replaced = BookTextEditWording.replaced(bookTitle: taken.title, keptCopy: kept)
        let heard = await eventually(timeout: 5) { announcements.messages.contains(replaced) }
        XCTAssertTrue(heard, "VoiceOver was not told where the text was kept: \(announcements.messages)")

        let next = await check(taken, with: editor, in: announcements)
        XCTAssertFalse(next.contains(BookTextEditWording.updated), "the text read again was taken as an edit")
    }

    /// A copy kept of the user's text is TextMouth's own file: a package
    /// whose record is lost still recovers its one book file beside it, and
    /// a loose DAISY book never counts it among its files.
    func testAKeptCopyIsNeverTakenForPartOfTheBook() throws {
        let package = try makeSandboxDirectory("Edit Text Kept Copy Package")
        let bookFile = package.appendingPathComponent("Harbour Pilots.md")
        try Data(Self.twoChapters.utf8).write(to: bookFile)
        try Data(Self.twoChapters.utf8).write(to: package.appendingPathComponent("content.md"))
        let kept = try XCTUnwrap(BookTextEditSessions.keepCopy(
            of: package.appendingPathComponent("content.md"),
            bytes: Data(Self.editedChapters.utf8)
        ))

        XCTAssertTrue(kept.lastPathComponent.hasPrefix("content.md.edited-"), kept.lastPathComponent)
        XCTAssertTrue(TextMouthPaths.isKeptTextCopy(kept.lastPathComponent))
        XCTAssertFalse(FileImportService.isPackageContentName(kept.lastPathComponent))
        XCTAssertFalse(DAISYPackageInventory.isBookPath(kept.lastPathComponent))
        XCTAssertEqual(
            try FileImportService.retainedContentURL(in: package).standardizedFileURL,
            bookFile.standardizedFileURL
        )
        XCTAssertTrue(FileImportService.isPackageContentName("content.md edited by hand.md"), "a book file of another name was refused")
    }

    /// The statistics pass leaves a book being edited to its session: it
    /// reads nothing of it, so an edit not taken is neither rebuilt over nor
    /// committed as the book's analysis.
    func testTheStatisticsPassLeavesABookBeingEditedAlone() async throws {
        let world = try makeIntegrationWorld("Edit Text Statistics")
        let book = try world.importBook(from: writeSource(named: "Breakwater Survey.md", Self.twoChapters))
        let indexBefore = try XCTUnwrap(BookInfo.load(from: book.tmbDirectory).contentIndex)
        let editor = makeEditor(sessions: .shared)
        defer { editor.endAll() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        let cache = MarkdownCacheService.cacheURL(for: book)
        let staleLines = debugLogLines(containing: "CACHE_STALE: \(book.title):").count
        let blank = Data(" \n\t\n".utf8)
        try blank.write(to: cache)
        // The row lacks its counts, as a book the pass analyzes does.
        let row = try XCTUnwrap(world.library.library.books.firstIndex { $0.id == book.id })
        world.library.library.books[row].totalWordCount = nil
        XCTAssertTrue(LibraryViewModel.needsContentAnalysis(world.library.library.books[row]))

        let finished = expectation(description: "The statistics pass finished")
        world.library.calculateMissingBookStats { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 10)

        XCTAssertEqual(try Data(contentsOf: cache), blank, "the text was rebuilt over an edit not taken")
        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).contentIndex, indexBefore)
        XCTAssertEqual(debugLogLines(containing: "CACHE_STALE: \(book.title):").count, staleLines, "the pass read the book")
    }

    /// An edit of a content.md only in the cloud is left alone until the
    /// file is on this Mac again, and then taken.
    func testAnEditInTheCloudWaitsUntilItIsHere() async throws {
        let world = try makeIntegrationWorld("Edit Text Cloud")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let cache = MarkdownCacheService.cacheURL(for: book)
        let cloud = CloudSwitch(cache)
        let editor = makeEditor(access: cloud.access)
        defer { editor.endAll() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        let wordsBefore = try XCTUnwrap(world.library.bookByID(book.id)?.totalWordCount)

        try Self.editedChapters.write(to: cache, atomically: true, encoding: .utf8)
        cloud.isInCloud = true
        let found = await checkResult(of: book, in: editor.sessions)

        guard case .inCloud = found else { return XCTFail("an edit in the cloud was read: \(found)") }
        XCTAssertEqual(world.library.bookByID(book.id)?.totalWordCount, wordsBefore)

        cloud.isInCloud = false
        editor.editor.appBecameActive()
        let taken = await eventually(timeout: 10) { world.library.bookByID(book.id)?.totalWordCount != wordsBefore }
        XCTAssertTrue(taken, "the edit was not taken once it was here")
    }

    /// An edit saved while a folder edit or a data-directory move holds the
    /// storage work is taken only once the hold ends.
    func testAnEditWaitsForAHoldOnTheStorageWork() async throws {
        let world = try makeIntegrationWorld("Edit Text Hold")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let boundary = StorageBoundary(root: TextMouthPaths.root)
        let editor = makeEditor(boundary: boundary)
        defer { editor.endAll() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        let wordsBefore = try XCTUnwrap(world.library.bookByID(book.id)?.totalWordCount)
        let hold = try boundary.holdWork(for: .movingBooksBetweenFolders)
        defer { hold.release() }

        try Self.editedChapters.write(to: MarkdownCacheService.cacheURL(for: book), atomically: true, encoding: .utf8)
        editor.editor.appBecameActive()

        let takenWhileHeld = await eventually(timeout: 1.5) { world.library.bookByID(book.id)?.totalWordCount != wordsBefore }
        XCTAssertFalse(takenWhileHeld, "the edit was taken while the storage work was held")
        hold.release()
        let taken = await eventually(timeout: 10) { world.library.bookByID(book.id)?.totalWordCount != wordsBefore }
        XCTAssertTrue(taken, "the edit was not taken once the hold ended")
    }

    // MARK: - Edits Saved While TextMouth Was Closed

    /// content.md saved in an editor while TextMouth was closed, beside an
    /// unchanged source, is the book's text once the launch's cache pass
    /// has run: indexed afresh and fingerprinted as the edited bytes beside
    /// the source, so neither the pass nor the next open rebuilds it, and
    /// nothing is kept beside it, since nothing replaced it. The next
    /// launch has nothing to do for it.
    func testAnEditSavedWhileClosedIsTakenAtLaunch() async throws {
        let world = try makeIntegrationWorld("Edit Text Closed Taken")
        let book = try world.importBook(from: writeSource(named: "Lantern Quay.md", Self.twoChapters))
        let sourceBefore = try XCTUnwrap(BookInfo.load(from: book.tmbDirectory).state.textCacheFingerprint?.source)
        let adoptedBefore = debugLogLines(containing: "TEXT_EDIT_ADOPTED: \(book.title):").count
        let cache = MarkdownCacheService.cacheURL(for: book)

        try Self.editedChapters.write(to: cache, atomically: true, encoding: .utf8)
        await runLaunchCachePass(of: world.library)

        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), Self.editedChapters, "the edit was rebuilt over")
        XCTAssertEqual(keptCopies(of: book), [], "a copy was kept of an edit nothing replaced")
        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(try XCTUnwrap(record.contentIndex).allHeadings.map(\.text), ["Harbour", "Channel", "Sandbanks"])
        let fingerprint = try XCTUnwrap(record.state.textCacheFingerprint)
        XCTAssertEqual(fingerprint.cache.digest, try FileImportService.md5Hash(of: cache))
        XCTAssertEqual(fingerprint.source, sourceBefore)
        let row = try XCTUnwrap(world.library.bookByID(book.id))
        XCTAssertEqual(row.textCacheFingerprint, fingerprint)
        XCTAssertEqual(debugLogLines(containing: "TEXT_EDIT_ADOPTED: \(book.title):").count, adoptedBefore + 1)
        let reopened = try BookContentAnalysisService.load(book: row)
        XCTAssertTrue(reopened.usedPersistedIndex, "the next open did not use the edit's index")
        XCTAssertTrue(reopened.content.chapters[1].text.contains("A pilot boat waits"))
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([row], access: .live), [], "the next launch would check it again")
    }

    /// An edit of the same length, which only content.md's date tells
    /// apart, is found by the launch's cache pass and taken all the same.
    func testASameLengthEditSavedWhileClosedIsFoundByItsDateAndTaken() async throws {
        let world = try makeIntegrationWorld("Edit Text Closed Same Length")
        let book = try world.importBook(from: writeSource(named: "Tide Mill.md", Self.twoChapters))
        let row = try XCTUnwrap(world.library.bookByID(book.id))
        let recorded = try XCTUnwrap(row.textCacheFingerprint)
        let cache = MarkdownCacheService.cacheURL(for: book)
        let text = try String(contentsOf: cache, encoding: .utf8)
        let edited = text.replacingOccurrences(of: "Buoys mark", with: "Spars mark")
        XCTAssertEqual(edited.utf8.count, text.utf8.count, "the edit changed the length")

        try edited.write(to: cache, atomically: true, encoding: .utf8)
        try setModificationTime(of: cache, nanoseconds: recorded.cache.modificationTimeNanoseconds + 2_000_000_000)
        XCTAssertFalse(LibraryViewModel.hasResizedTextCacheFile(row))
        XCTAssertTrue(LibraryViewModel.hasRedatedTextCache(row))
        await runLaunchCachePass(of: world.library)

        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), edited, "the edit was rebuilt over")
        let fingerprint = try XCTUnwrap(BookInfo.load(from: book.tmbDirectory).state.textCacheFingerprint)
        XCTAssertEqual(fingerprint.cache.digest, try FileImportService.md5Hash(of: cache))
        XCTAssertEqual(world.library.bookByID(book.id)?.textCacheFingerprint, fingerprint)
        XCTAssertEqual(keptCopies(of: book), [])
    }

    /// content.md only touched, its bytes the same, is read once for its
    /// digest and left as it is: nothing is taken, kept, or rewritten, and
    /// the row records the new date, so the next launch reads nothing.
    func testATouchedContentMarkdownIsReadOnceAndLeftAsItIs() async throws {
        let world = try makeIntegrationWorld("Edit Text Closed Touched")
        let book = try world.importBook(from: writeSource(named: "Ferry Steps.md", Self.twoChapters))
        let recorded = try XCTUnwrap(world.library.bookByID(book.id)?.textCacheFingerprint)
        let adoptedBefore = debugLogLines(containing: "TEXT_EDIT_ADOPTED: \(book.title):").count
        let cache = MarkdownCacheService.cacheURL(for: book)
        let bytes = try Data(contentsOf: cache)
        try setModificationTime(of: cache, nanoseconds: recorded.cache.modificationTimeNanoseconds + 2_000_000_000)
        let touched = FileStamp(of: cache)
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate(world.library.library.books, access: .live).map(\.id), [book.id])

        await runLaunchCachePass(of: world.library)

        XCTAssertEqual(try Data(contentsOf: cache), bytes)
        XCTAssertEqual(FileStamp(of: cache), touched, "content.md was written again")
        XCTAssertEqual(keptCopies(of: book), [])
        XCTAssertEqual(debugLogLines(containing: "TEXT_EDIT_ADOPTED: \(book.title):").count, adoptedBefore)
        let row = try XCTUnwrap(world.library.bookByID(book.id))
        XCTAssertEqual(row.textCacheFingerprint?.cache.stamp, touched, "the row did not record the new date")
        XCTAssertEqual(row.textCacheFingerprint?.cache.digest, recorded.cache.digest)
        XCTAssertEqual(LibraryViewModel.booksNeedingCacheUpdate([row], access: .live), [], "the next launch would read it again")
    }

    /// An edit saved while closed that cannot be taken, holding no chapter
    /// or bytes that are not UTF-8, is kept beside content.md exactly as
    /// saved, and only then is the book's text read again from its own
    /// file.
    func testAnEditSavedWhileClosedThatCannotBeTakenIsKeptBeforeTheRebuild() async throws {
        for (name, saved) in [("Pier Lamps", Data("  \n\n\t\n".utf8)), ("Net Lofts", Data([0x48, 0xFF, 0xFE, 0x69]))] {
            let world = try makeIntegrationWorld("Edit Text Closed Refused \(name)")
            let book = try world.importBook(from: writeSource(named: "\(name).md", Self.twoChapters))
            let cache = MarkdownCacheService.cacheURL(for: book)
            let extracted = try Data(contentsOf: cache)

            try saved.write(to: cache)
            await runLaunchCachePass(of: world.library)

            let copies = keptCopies(of: book)
            XCTAssertEqual(copies.count, 1, "\(name): the edit was not kept once")
            XCTAssertEqual(copies.first.flatMap { try? Data(contentsOf: $0) }, saved, "\(name): the copy is not the edit")
            XCTAssertEqual(try Data(contentsOf: cache), extracted, "\(name): the text was not read again from the book's file")
            let fingerprint = try XCTUnwrap(world.library.bookByID(book.id)?.textCacheFingerprint, name)
            XCTAssertEqual(fingerprint.cache.digest, try FileImportService.md5Hash(of: cache), name)
        }
    }

    /// An edit saved while closed beside a source that changed too is kept
    /// beside content.md, and the book's text is read from the changed file.
    func testAnEditSavedWhileClosedBesideAChangedSourceIsKeptThenTheFileRead() async throws {
        let world = try makeIntegrationWorld("Edit Text Closed Source Changed")
        let book = try world.importBook(from: writeSource(named: "Salt Road.md", Self.twoChapters))
        let cache = MarkdownCacheService.cacheURL(for: book)

        try Self.editedChapters.write(to: cache, atomically: true, encoding: .utf8)
        try (Self.twoChapters + "\n\n<!-- chapter: Moorings -->\n# Moorings\n\nChains rust in the shallows.\n")
            .write(to: book.bookFileURL, atomically: true, encoding: .utf8)
        await runLaunchCachePass(of: world.library)

        let copy = try XCTUnwrap(keptCopies(of: book).first, "the edit was not kept")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), Self.editedChapters)
        let text = try String(contentsOf: cache, encoding: .utf8)
        XCTAssertTrue(text.contains("Chains rust in the shallows."), "the changed file was not read")
        XCTAssertFalse(text.contains("A pilot boat waits"), "the edit beside a changed file was taken")
    }

    /// Any rebuild keeps text content.md holds that TextMouth did not write
    /// or take there, though no session saw it saved: Redo Text Extraction
    /// keeps it beside content.md before reading the book's text from its
    /// own file again, says nothing was skipped, and keeps nothing for a
    /// book whose content.md is as TextMouth wrote it.
    func testEveryRebuildKeepsTextSavedWithoutASession() async throws {
        let world = try makeIntegrationWorld("Edit Text Closed Redo")
        let edited = try world.importBook(from: writeSource(named: "Chandlery.md", Self.twoChapters))
        let untouched = try world.importBook(
            from: writeSource(named: "Boatyard.md", Self.twoChapters + "\n\nHulls dry on the slip.")
        )
        let cache = MarkdownCacheService.cacheURL(for: edited)
        let extracted = try Data(contentsOf: cache)
        let keptBefore = debugLogLines(containing: "TEXT_EDIT_KEPT: \(edited.title):").count

        try Self.editedChapters.write(to: cache, atomically: true, encoding: .utf8)
        let outcome = await world.library.redoAllTextExtractionReturningOutcome()

        XCTAssertEqual(outcome, .success(nil))
        let copy = try XCTUnwrap(keptCopies(of: edited).first, "the text saved without a session was not kept")
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), Self.editedChapters)
        XCTAssertEqual(try Data(contentsOf: cache), extracted, "the text was not read again from the book's file")
        XCTAssertEqual(debugLogLines(containing: "TEXT_EDIT_KEPT: \(edited.title):").count, keptBefore + 1)
        XCTAssertEqual(keptCopies(of: untouched), [], "text TextMouth wrote was kept")
    }

    /// Redo Text Extraction says how many books it skipped, those in the
    /// cloud and those held over an edit not taken, each in a sentence of
    /// its own, and says nothing more when it skipped none.
    func testRedoTextExtractionSaysWhichBooksItSkipped() {
        typealias Model = LibraryViewModel
        XCTAssertEqual(Model.textReextractionOutcome(skippedInCloud: 0, heldByEdits: 0), .success(nil))
        XCTAssertEqual(
            Model.textReextractionOutcome(skippedInCloud: 0, heldByEdits: 1),
            .success("Done. 1 book whose edited text can't be used yet was skipped.")
        )
        XCTAssertEqual(
            Model.textReextractionOutcome(skippedInCloud: 0, heldByEdits: 2),
            .success("Done. 2 books whose edited text can't be used yet were skipped.")
        )
        XCTAssertEqual(
            Model.textReextractionOutcome(skippedInCloud: 12, heldByEdits: 1),
            .success("Done. 12 books in the cloud were skipped. 1 book whose edited text can't be used yet was skipped.")
        )
        XCTAssertEqual(Model.textReextractionOutcome(skippedInCloud: 1), .success("Done. 1 book in the cloud was skipped."))
    }

    // MARK: - The Session's Copy of Its Old Text (T06's branch E)

    /// Beginning a session keeps one copy of the book's text in the Edit Text
    /// snapshots: content.md's exact bytes, with the book's places as the
    /// library holds them.
    func testBeginningASessionKeepsACopyOfTheText() async throws {
        let world = try makeIntegrationWorld("Edit Copy Begin")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let editor = makeEditor()
        defer { editor.endAll() }
        XCTAssertEqual(editCopies(of: book), [], "a copy was kept before the session began")

        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        await waitForChecks(of: editor.sessions)

        let copy = try XCTUnwrap(editCopies(of: book).first, "no copy was kept")
        XCTAssertEqual(editCopies(of: book).count, 1)
        XCTAssertEqual(textKept(in: copy), try Data(contentsOf: MarkdownCacheService.cacheURL(for: book)))
        let record = try recordKept(in: copy)
        let row = try XCTUnwrap(world.library.bookByID(book.id))
        XCTAssertEqual(record.bookID, book.id)
        XCTAssertEqual(record.title, book.title)
        XCTAssertEqual(record.places, row.relocatablePlaces)
    }

    /// The copy holds the book's saved places: a bookmark the book holds
    /// when the copy is kept is in the copy's record.
    func testTheCopyHoldsTheBooksPlaces() async throws {
        let world = try makeIntegrationWorld("Edit Copy Places")
        var book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        book.bookmarks = [Bookmark(number: 1, chapterIndex: 1, characterOffset: 4, label: "Buoys", anchor: nil)]
        let sessions = BookTextEditSessions()
        let baseline = try XCTUnwrap(try? BookTextEditSessions.baseline(of: book, access: .live).get())
        sessions.begin(book.id, BookTextEditSessions.Session(baseline: baseline, report: { _, _ in }))
        defer { sessions.end(book.id) }

        sessions.keepOldText(of: book)
        await waitForChecks(of: sessions)

        let copy = try XCTUnwrap(editCopies(of: book).first, "no copy was kept")
        let record = try recordKept(in: copy)
        XCTAssertEqual(record.places.bookmarks.map(\.label), ["Buoys"])
        XCTAssertEqual(record.places, book.relocatablePlaces)
        // A session that holds a copy keeps no second.
        sessions.keepOldText(of: book)
        await waitForChecks(of: sessions)
        XCTAssertEqual(editCopies(of: book), [copy])
    }

    /// An edit taken replaces the copy with exactly the bytes taken, and one
    /// copy of the book remains: the earlier one is deleted.
    func testAnEditTakenReplacesTheCopyWithTheBytesTaken() async throws {
        let world = try makeIntegrationWorld("Edit Copy Taken")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let editor = makeEditor()
        defer { editor.endAll() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        await waitForChecks(of: editor.sessions)
        let first = try XCTUnwrap(editCopies(of: book).first, "no copy was kept")

        let edited = Data(Self.editedChapters.utf8)
        try edited.write(to: MarkdownCacheService.cacheURL(for: book))
        editor.editor.appBecameActive()
        await waitForChecks(of: editor.sessions)

        let copies = editCopies(of: book)
        XCTAssertEqual(copies.count, 1, "one copy of the book remains")
        let second = try XCTUnwrap(copies.first)
        XCTAssertNotEqual(second, first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path), "the earlier copy was not deleted")
        XCTAssertEqual(textKept(in: second), edited)
        XCTAssertEqual(try recordKept(in: second).bookID, book.id)
    }

    /// A later edit replaces the copy again, so the copy is always the text
    /// last taken, never one a save before.
    func testEachEditTakenReplacesTheCopyAgain() async throws {
        let world = try makeIntegrationWorld("Edit Copy Twice")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let editor = makeEditor()
        defer { editor.endAll() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        let cache = MarkdownCacheService.cacheURL(for: book)

        let once = Data(Self.editedChapters.utf8)
        let twice = Data((Self.editedChapters + "\n\nThe launches return at dusk.").utf8)
        for bytes in [once, twice] {
            try bytes.write(to: cache)
            editor.editor.appBecameActive()
            await waitForChecks(of: editor.sessions)
            XCTAssertEqual(editCopies(of: book).count, 1)
            XCTAssertEqual(editCopies(of: book).first.flatMap(textKept(in:)), bytes)
        }
    }

    /// A refused edit leaves the copy as it was.
    func testARefusedEditLeavesTheCopyAsItWas() async throws {
        let world = try makeIntegrationWorld("Edit Copy Refused")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let editor = makeEditor()
        defer { editor.endAll() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        await waitForChecks(of: editor.sessions)
        let before = editCopies(of: book)
        let bytesBefore = try XCTUnwrap(before.first.flatMap(textKept(in:)))

        // Nothing in it: refused, and kept beside content.md.
        try Data("   \n\n\t\n".utf8).write(to: MarkdownCacheService.cacheURL(for: book))
        editor.editor.appBecameActive()
        await waitForChecks(of: editor.sessions)

        XCTAssertEqual(before.count, 1)
        XCTAssertEqual(editCopies(of: book), before)
        XCTAssertEqual(before.first.flatMap(textKept(in:)), bytesBefore)
    }

    /// Ending the session deletes the copy; a session started again over
    /// one that holds a copy deletes that copy unless it is the same; both
    /// are checked without a library.
    func testEndingOrRestartingASessionDeletesItsCopy() throws {
        let sessions = BookTextEditSessions()
        let folder = try makeSandboxDirectory("Edit Copy Folder")
        let bookID = UUID()
        let baseline = BookTextBaseline(source: nil, cache: FileFingerprint(stamp: FileStamp(byteCount: 0, modificationTimeNanoseconds: 0), digest: ""))
        let record = PlaceSnapshot.Record(
            bookID: bookID, title: "Harbour Pilots", author: "A. Volunteer",
            places: PlaceRelocator.Places(position: nil, bookmarks: [], skippedHeadings: [], waitingSkippedHeadings: []),
            takenAt: Date()
        )
        func keepCopy() throws -> PlaceSnapshot {
            try PlaceSnapshot.keep(text: Data("Words.".utf8), record: record, in: folder)
        }
        func session(holding copy: PlaceSnapshot?) -> BookTextEditSessions.Session {
            BookTextEditSessions.Session(baseline: baseline, report: { _, _ in }, oldText: copy)
        }
        func exists(_ copy: PlaceSnapshot) -> Bool {
            FileManager.default.fileExists(atPath: copy.folder.path)
        }

        let first = try keepCopy()
        sessions.begin(bookID, session(holding: first))
        XCTAssertTrue(exists(first))
        // Started again with the same copy: kept.
        sessions.begin(bookID, session(holding: first))
        XCTAssertTrue(exists(first), "the same copy was deleted")
        // Started again with another: the first is deleted.
        let second = try keepCopy()
        sessions.begin(bookID, session(holding: second))
        XCTAssertFalse(exists(first), "a replaced copy was kept")
        XCTAssertTrue(exists(second))
        // Started again with none: the copy it held is deleted.
        sessions.begin(bookID, session(holding: nil))
        XCTAssertFalse(exists(second))
        // Ended: the copy it holds is deleted.
        let third = try keepCopy()
        sessions.begin(bookID, session(holding: third))
        sessions.end(bookID)
        XCTAssertFalse(exists(third), "an ended session's copy was kept")
        XCTAssertFalse(sessions.isEditing(bookID))
        // Ending a session that is not there is no error.
        sessions.end(bookID)
    }

    /// Ending the session through the editor deletes the copy it kept.
    func testEndingTheSessionDeletesTheCopy() async throws {
        let world = try makeIntegrationWorld("Edit Copy End")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let editor = makeEditor()
        defer { editor.endAll() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        await waitForChecks(of: editor.sessions)
        XCTAssertEqual(editCopies(of: book).count, 1)

        editor.editor.end(book.id)

        XCTAssertEqual(editCopies(of: book), [])
    }

    /// A session that ends before its copy is kept leaves no copy behind.
    func testASessionEndedBeforeItsCopyIsKeptLeavesNone() async throws {
        let world = try makeIntegrationWorld("Edit Copy Ended Early")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let editor = makeEditor()
        defer { editor.endAll() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        editor.editor.end(book.id)
        await waitForChecks(of: editor.sessions)
        XCTAssertEqual(editCopies(of: book), [])

        // Asked for a book that is not being edited, nothing is kept.
        editor.sessions.keepOldText(of: book)
        await waitForChecks(of: editor.sessions)
        XCTAssertEqual(editCopies(of: book), [])
    }

    /// A rebuild of the text during the session makes the copy the rebuilt
    /// bytes, and the earlier copy is deleted.
    func testARebuildDuringTheSessionMakesTheCopyTheRebuiltText() async throws {
        let world = try makeIntegrationWorld("Edit Copy Rebuilt")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let editor = makeEditor()
        defer { editor.endAll() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        await waitForChecks(of: editor.sessions)
        let first = try XCTUnwrap(editCopies(of: book).first, "no copy was kept")

        // A rebuild writes content.md, then tells the session.
        let rebuilt = Data(Self.editedChapters.utf8)
        try rebuilt.write(to: MarkdownCacheService.cacheURL(for: book))
        editor.sessions.textRebuilt(book, writing: rebuilt, fingerprint: nil)

        let copies = editCopies(of: book)
        XCTAssertEqual(copies.count, 1)
        XCTAssertNotEqual(copies.first, first)
        XCTAssertEqual(copies.first.flatMap(textKept(in:)), rebuilt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    /// A transcribed audiobook's session keeps no copy, at its start or for
    /// an edit of its transcript.
    func testATranscribedAudiobooksSessionKeepsNoCopy() async throws {
        let world = try makeIntegrationWorld("Edit Copy Audiobook")
        let title = "Breakwater Notes \(UUID().uuidString.prefix(8))"
        let book = try world.makeSilentAudioBook(title: title, trackDurations: [3, 2])
        try TranscriptStore.install(try TranscriptFixtures.transcript(of: book, sentences: TranscriptionUIScripts.twoTracks), for: book)
        let editor = makeEditor()
        defer { editor.endAll() }
        let cache = MarkdownCacheService.cacheURL(for: book)
        let edited = try String(contentsOf: cache, encoding: .utf8)
            .replacingOccurrences(of: MarkdownLiteral.escaped("on the pier."), with: MarkdownLiteral.escaped("on the jetty."))

        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        XCTAssertTrue(editor.sessions.isEditing(book.id), "the session did not begin")
        await waitForChecks(of: editor.sessions)
        XCTAssertEqual(editCopies(of: book), [])

        try edited.write(to: cache, atomically: true, encoding: .utf8)
        editor.editor.appBecameActive()
        await waitForChecks(of: editor.sessions)
        XCTAssertEqual(editCopies(of: book), [])
    }

    /// The rebuilds' recovery never lists a session's copy, and the copy is
    /// not in the rebuilds' folder.
    func testTheRebuildRecoveryNeverListsASessionsCopy() async throws {
        let world = try makeIntegrationWorld("Edit Copy Recovery")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let editor = makeEditor()
        defer { editor.endAll() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        await waitForChecks(of: editor.sessions)
        let copy = try XCTUnwrap(editCopies(of: book).first, "no copy was kept")

        // As after a quit, when no copy is in use any more.
        PlaceSnapshot.forgetCopiesInUse()
        let listed = PlaceSnapshot.leftovers()

        XCTAssertFalse(listed.contains { $0.record.bookID == book.id }, "a session's copy was listed for recovery")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path), "the recovery removed a session's copy")
        XCTAssertNotEqual(copy.deletingLastPathComponent().standardizedFileURL, MachineLocalPaths.placeSnapshots.standardizedFileURL)
        let rebuilds = (try? FileManager.default.contentsOfDirectory(atPath: MachineLocalPaths.placeSnapshots.path)) ?? []
        XCTAssertFalse(rebuilds.contains { $0.hasPrefix("\(book.id.uuidString) ") })
    }

    // MARK: - Places Moved by Each Edit Taken (T06's branch E)

    /// An edit that puts a paragraph before every place moves the book's
    /// position, bookmark, and skipped heading onto their words, in the
    /// library's row and in the book's record, with no reader open, and the
    /// debug log says once that they were moved. The moves are silent.
    func testAnEditTakenMovesThePlacesWithTheirWords() async throws {
        let world = try makeIntegrationWorld("Edit Places Moved")
        let book = try world.importBook(from: writeSource(named: "Pilot Rota One.md", Self.twoChapters))
        let before = try landmarks(in: Self.twoChapters)
        let after = try landmarks(in: Self.paragraphAdded)
        XCTAssertNotEqual(before.coordinates, after.coordinates, "the edit moves nothing: the test shows nothing")
        savePlaces(before, on: book, in: world)
        let editor = makeEditor()
        defer { editor.endAll() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        await waitForChecks(of: editor.sessions)
        let movedBefore = debugLogLines(containing: "PLACES_RELOCATED: \(book.title):").count
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        try await saveEdit(Self.paragraphAdded, of: book, through: editor, in: world)

        XCTAssertEqual(coordinates(of: try XCTUnwrap(world.library.bookByID(book.id))), after.coordinates, "the row's places stayed")
        XCTAssertEqual(coordinates(of: try recordedBook(like: book)), after.coordinates, "the record's places stayed")
        XCTAssertEqual(debugLogLines(containing: "PLACES_RELOCATED: \(book.title):").count, movedBefore + 1)
        XCTAssertEqual(announcements.messages, [BookTextEditWording.updated], "a move was announced")
    }

    /// A second edit in the same session moves the places again, from the
    /// text the first edit took.
    func testASecondEditInTheSessionMovesThePlacesAgain() async throws {
        let world = try makeIntegrationWorld("Edit Places Moved Twice")
        let book = try world.importBook(from: writeSource(named: "Pilot Rota Two.md", Self.twoChapters))
        try savePlaces(landmarks(in: Self.twoChapters), on: book, in: world)
        let editor = makeEditor()
        defer { editor.endAll() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        await waitForChecks(of: editor.sessions)
        try await saveEdit(Self.paragraphAdded, of: book, through: editor, in: world)
        let first = try landmarks(in: Self.paragraphAdded)
        XCTAssertEqual(coordinates(of: try XCTUnwrap(world.library.bookByID(book.id))), first.coordinates)

        let twice = Self.paragraphAdded.replacingOccurrences(of: "A pilot boat waits", with: "The launches return at dusk.\n\nA pilot boat waits")
        try await saveEdit(twice, of: book, through: editor, in: world)

        let second = try landmarks(in: twice)
        XCTAssertNotEqual(first.coordinates, second.coordinates)
        XCTAssertEqual(coordinates(of: try XCTUnwrap(world.library.bookByID(book.id))), second.coordinates)
        XCTAssertEqual(coordinates(of: try recordedBook(like: book)), second.coordinates)
    }

    /// A copy that is not the text the places were saved in moves nothing:
    /// the places stay as they were, the edit is still taken, and the debug
    /// log says once, with the title alone, that they were not moved.
    func testACopyThatIsNotTheTextThePlacesWereSavedInMovesNothing() async throws {
        let world = try makeIntegrationWorld("Edit Places Wrong Copy")
        let book = try world.importBook(from: writeSource(named: "Pilot Rota Three.md", Self.twoChapters))
        let before = try landmarks(in: Self.twoChapters)
        savePlaces(before, on: book, in: world)
        let editor = makeEditor()
        defer { editor.endAll() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        await waitForChecks(of: editor.sessions)
        // The copy holds other bytes than TextMouth last took.
        let copy = try XCTUnwrap(editCopies(of: book).first, "no copy was kept")
        try Data("Some other text, never the book's.".utf8).write(to: copy.appendingPathComponent(PlaceSnapshot.textFileName))
        let refusals = debugLogLines(containing: "PLACES_NOT_MOVED: \(book.title): its earlier text was not kept as its places knew it").count

        try await saveEdit(Self.paragraphAdded, of: book, through: editor, in: world)

        XCTAssertEqual(coordinates(of: try XCTUnwrap(world.library.bookByID(book.id))), before.coordinates)
        XCTAssertEqual(coordinates(of: try recordedBook(like: book)), before.coordinates)
        XCTAssertEqual(debugLogLines(containing: "PLACES_NOT_MOVED: \(book.title): its earlier text was not kept as its places knew it").count, refusals + 1)
        // The edit itself was taken.
        let record = try BookInfo.load(from: book.tmbDirectory)
        XCTAssertEqual(record.contentIndex?.textCacheFingerprint?.cache.digest, try FileImportService.md5Hash(of: MarkdownCacheService.cacheURL(for: book)))
    }

    /// An edit saved while TextMouth was closed is taken at launch, and the
    /// places follow their words from the copy a quit left: the row and the
    /// record hold them, and the copy is gone.
    func testAnEditSavedWhileClosedMovesThePlacesFromTheCopyAQuitLeft() async throws {
        let world = try makeIntegrationWorld("Edit Places Closed Copy")
        let book = try world.importBook(from: writeSource(named: "Pilot Rota Four.md", Self.twoChapters))
        let before = try landmarks(in: Self.twoChapters)
        let after = try landmarks(in: Self.paragraphAdded)
        savePlaces(before, on: book, in: world)
        let left = try leaveACopyAsAQuitDoes(of: book, in: world)
        let movedBefore = debugLogLines(containing: "PLACES_RELOCATED: \(book.title):").count

        try Self.paragraphAdded.write(to: MarkdownCacheService.cacheURL(for: book), atomically: true, encoding: .utf8)
        await runLaunchCachePass(of: world.library)

        XCTAssertEqual(coordinates(of: try XCTUnwrap(world.library.bookByID(book.id))), after.coordinates)
        XCTAssertEqual(coordinates(of: try recordedBook(like: book)), after.coordinates)
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.path), "the copy was not deleted")
        XCTAssertEqual(editCopies(of: book), [])
        XCTAssertEqual(debugLogLines(containing: "PLACES_RELOCATED: \(book.title):").count, movedBefore + 1)
    }

    /// An edit saved while TextMouth was closed, with no copy, is taken and
    /// the places stay where they were saved: a reader's next load finds
    /// them by their saved words.
    func testAnEditSavedWhileClosedWithNoCopyLeavesThePlaces() async throws {
        let world = try makeIntegrationWorld("Edit Places Closed No Copy")
        let book = try world.importBook(from: writeSource(named: "Pilot Rota Five.md", Self.twoChapters))
        let before = try landmarks(in: Self.twoChapters)
        savePlaces(before, on: book, in: world)
        XCTAssertEqual(editCopies(of: book), [])
        let adoptedBefore = debugLogLines(containing: "TEXT_EDIT_ADOPTED: \(book.title):").count

        try Self.paragraphAdded.write(to: MarkdownCacheService.cacheURL(for: book), atomically: true, encoding: .utf8)
        await runLaunchCachePass(of: world.library)

        XCTAssertEqual(debugLogLines(containing: "TEXT_EDIT_ADOPTED: \(book.title):").count, adoptedBefore + 1, "the edit was not taken")
        XCTAssertEqual(coordinates(of: try XCTUnwrap(world.library.bookByID(book.id))), before.coordinates)
        XCTAssertEqual(coordinates(of: try recordedBook(like: book)), before.coordinates)
    }

    /// A copy left for a book that is not in an edit session is deleted by
    /// the launch's cache pass when content.md holds what its record says;
    /// the copy of a session begun in this run is kept.
    func testTheLaunchPassSweepsLeftoverCopiesButNotASessionsOwn() async throws {
        let world = try makeIntegrationWorld("Edit Places Sweep")
        let idle = try world.importBook(from: writeSource(named: "Pilot Rota Six.md", Self.twoChapters))
        // Other words than the first book's, which an import would skip as a duplicate.
        let editing = try world.importBook(from: writeSource(named: "Pilot Rota Seven.md", Self.twoChapters + "\n\nThe pilots go home at dusk."))
        savePlaces(try landmarks(in: Self.twoChapters), on: idle, in: world)
        let left = try leaveACopyAsAQuitDoes(of: idle, in: world)
        let editor = makeEditor()
        defer { editor.endAll() }
        // Begun after the quit: this run's own copy.
        await editor.editor.edit(editing, choosingApp: false, in: world.library, from: nil)
        await waitForChecks(of: editor.sessions)
        let own = try XCTUnwrap(editCopies(of: editing).first, "no copy was kept")

        await runLaunchCachePass(of: world.library)

        XCTAssertFalse(FileManager.default.fileExists(atPath: left.path), "the leftover copy was not swept")
        XCTAssertEqual(editCopies(of: idle), [])
        XCTAssertEqual(editCopies(of: editing), [own], "the session's own copy was swept")
    }

    // MARK: Helpers of the Places Section

    /// The twoChapters text with a paragraph put in before "Buoys", so every
    /// place that follows moves; "Shoals" keeps its name.
    private static let paragraphAdded = twoChapters.replacingOccurrences(
        of: "Buoys mark the channel.",
        with: "A pilot boat waits at the outer mark.\n\nBuoys mark the channel."
    )

    /// Where the test's three places stand in a text: a reading position at
    /// "Buoys", a bookmark at "Sand moves", and the skipped heading "Shoals".
    private struct Landmarks {
        /// The text, parsed.
        let content: DocumentContent
        /// The reading position, at "Buoys".
        let reading: TextPlace
        /// The bookmark, at "Sand moves".
        let marked: TextPlace
        /// The heading the book skips.
        let shoals: Heading

        /// The places as [chapter, offset] each, in the order position,
        /// bookmark, skipped heading.
        var coordinates: [[Int]] {
            [[reading.chapter, reading.offset], [marked.chapter, marked.offset], [shoals.chapterIndex, shoals.characterOffset]]
        }
    }

    /// The test's landmarks in `markdown`, which must hold the words.
    private func landmarks(in markdown: String) throws -> Landmarks {
        let content = MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: "Pilot Rota", bookAuthor: "")
        let channel = try XCTUnwrap(content.chapters.dropFirst().first?.text as NSString?, "no second chapter")
        let shoals = try XCTUnwrap(content.allHeadings.first { $0.text == "Shoals" }, "no Shoals heading")
        return Landmarks(
            content: content,
            reading: TextPlace(chapter: 1, offset: channel.range(of: "Buoys").location),
            marked: TextPlace(chapter: 1, offset: channel.range(of: "Sand moves").location),
            shoals: shoals
        )
    }

    /// Saves `marks` as the places of `book` in the library's row and in
    /// its record, each with its words as a reader captures them.
    private func savePlaces(_ marks: Landmarks, on book: Book, in world: IntegrationWorld) {
        let measure = TextAnchor.currentMeasure
        world.library.updateBook(id: book.id) { saved in
            saved.readingPosition = ReadingPosition(
                chapterIndex: marks.reading.chapter,
                characterOffset: marks.reading.offset,
                globalCharacterOffset: marks.content.chapterStartOffset(marks.reading.chapter) + marks.reading.offset,
                anchor: marks.content.anchor(at: marks.reading, measuredIn: measure)
            )
            saved.bookmarks = [Bookmark(
                number: 1,
                chapterIndex: marks.marked.chapter,
                characterOffset: marks.marked.offset,
                label: "Sand",
                anchor: marks.content.anchor(at: marks.marked, measuredIn: measure)
            )]
            let skipped = TextPlace(chapter: marks.shoals.chapterIndex, offset: marks.shoals.characterOffset)
            saved.setSkippedHeadings([SkippedHeading(marks.shoals, anchor: marks.content.anchor(at: skipped, measuredIn: measure))])
        }
        LibraryPersistenceService.flushPendingSave()
    }

    /// The places of `book` as [chapter, offset] each, in the order
    /// position, bookmark, skipped heading (`Landmarks.coordinates`).
    private func coordinates(of book: Book) -> [[Int]] {
        let position = book.readingPosition.map { [[$0.chapterIndex, $0.characterOffset]] } ?? []
        let marks = book.bookmarks.map { [$0.chapterIndex, $0.characterOffset] }
        let skips = (book.skippedHeadings ?? []).map { [$0.chapterIndex, $0.characterOffset] }
        return position + marks + skips
    }

    /// The book as its package record holds it, read from disk after every
    /// queued library write has landed.
    private func recordedBook(like book: Book) throws -> Book {
        LibraryPersistenceService.flushPendingSave()
        return Book(
            record: try BookInfo.load(from: book.tmbDirectory),
            filePath: book.filePath,
            folderPath: book.folderPath,
            tmbDirectoryName: book.tmbDirectoryName
        )
    }

    /// Saves `markdown` as `book`'s content.md as an editor does, has the
    /// session check it as TextMouth becoming active does, and waits until
    /// the library's row has taken the edit.
    private func saveEdit(_ markdown: String, of book: Book, through editor: TestEditor, in world: IntegrationWorld) async throws {
        let cache = MarkdownCacheService.cacheURL(for: book)
        try markdown.write(to: cache, atomically: true, encoding: .utf8)
        let digest = try FileImportService.md5Hash(of: cache)
        editor.editor.appBecameActive()
        await waitForChecks(of: editor.sessions)
        let taken = await eventually(timeout: 10) { world.library.bookByID(book.id)?.textCacheFingerprint?.cache.digest == digest }
        XCTAssertTrue(taken, "the row never took the edit")
    }

    /// Leaves a copy of `book`'s content.md and places in the Edit Text
    /// snapshots, as a quit during an edit session does: no session of this
    /// run uses it. Returns its folder.
    private func leaveACopyAsAQuitDoes(of book: Book, in world: IntegrationWorld) throws -> URL {
        let row = try XCTUnwrap(world.library.bookByID(book.id))
        let copy = try PlaceSnapshot.keep(
            textAt: MarkdownCacheService.cacheURL(for: book),
            record: PlaceSnapshot.Record(bookID: book.id, title: book.title, author: book.author, places: row.relocatablePlaces, takenAt: Date()),
            in: MachineLocalPaths.editTextSnapshots
        )
        PlaceSnapshot.forgetCopiesInUse()
        return copy.folder
    }

    // MARK: - An Open Reader Follows an Edit (T06's branch E)

    /// A reader open and paused at its book's saved place follows an edit
    /// that puts a paragraph before every place: its cursor stands at its
    /// words in the edited text, its bookmark list and its skipped heading
    /// follow, the row and the record agree, and the position it saves next
    /// holds the edited text's words at the cursor.
    func testAReaderPausedAtItsSavedPlaceFollowsAnEdit() async throws {
        let world = try makeIntegrationWorld("Edit Reader Paused")
        let book = try world.importBook(from: writeSource(named: "Pilot Rota Eight.md", Self.twoChapters))
        let before = try landmarks(in: Self.twoChapters)
        let after = try landmarks(in: Self.paragraphAdded)
        XCTAssertNotEqual(before.coordinates, after.coordinates, "the edit moves nothing: the test shows nothing")
        savePlaces(before, on: book, in: world)
        let editor = makeEditor()
        defer { editor.endAll() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        await waitForChecks(of: editor.sessions)
        let reader = world.openReader(for: try XCTUnwrap(world.library.bookByID(book.id)))
        await waitForReaderToLoadYielding(reader)
        XCTAssertEqual(cursor(of: reader), before.reading, "the reader did not open at its saved place")
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        try await saveEdit(Self.paragraphAdded, of: book, through: editor, in: world)

        try assertReaderFollowed(reader, to: after, book: book, in: world)
        XCTAssertEqual(cursor(of: reader), after.reading)
        // The position the reader saves next keeps the edited text's words.
        reader.savePosition()
        let saved = try XCTUnwrap(world.library.bookByID(book.id)?.readingPosition)
        XCTAssertEqual([saved.chapterIndex, saved.characterOffset], [after.reading.chapter, after.reading.offset])
        XCTAssertEqual(saved.anchor, after.content.anchor(at: after.reading, measuredIn: TextAnchor.currentMeasure))
        // The moves are silent: only the edit's own announcement is made.
        XCTAssertEqual(announcements.messages, [BookTextEditWording.updated])
    }

    /// A cursor moved past the saved place without saving, as while playing,
    /// follows its own words; the position saved after the edit is the
    /// cursor's, not the saved place's, and the other places still follow.
    func testACursorMovedPastTheSavedPlaceFollowsItsOwnWords() async throws {
        let world = try makeIntegrationWorld("Edit Reader Moved On")
        let book = try world.importBook(from: writeSource(named: "Pilot Rota Nine.md", Self.twoChapters))
        let before = try landmarks(in: Self.twoChapters)
        let after = try landmarks(in: Self.paragraphAdded)
        savePlaces(before, on: book, in: world)
        let editor = makeEditor()
        defer { editor.endAll() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        await waitForChecks(of: editor.sessions)
        let reader = world.openReader(for: try XCTUnwrap(world.library.bookByID(book.id)))
        await waitForReaderToLoadYielding(reader)
        // The cursor goes on to "The tide", unsaved, as speech moves it.
        let oldChannel = try XCTUnwrap(before.content.chapters.dropFirst().first?.text as NSString?)
        reader.currentCharacterOffset = oldChannel.range(of: "The tide").location

        try await saveEdit(Self.paragraphAdded, of: book, through: editor, in: world)

        let newChannel = try XCTUnwrap(after.content.chapters.dropFirst().first?.text as NSString?)
        let tide = TextPlace(chapter: 1, offset: newChannel.range(of: "The tide").location)
        XCTAssertEqual(cursor(of: reader), tide)
        // The edit saved the cursor's place, with the edited text's words there.
        let saved = try XCTUnwrap(world.library.bookByID(book.id)?.readingPosition)
        XCTAssertEqual([saved.chapterIndex, saved.characterOffset], [tide.chapter, tide.offset])
        XCTAssertEqual(saved.anchor, after.content.anchor(at: tide, measuredIn: TextAnchor.currentMeasure))
        // The bookmark and the skipped heading followed their words.
        XCTAssertEqual(reader.bookmarks.map { [$0.chapterIndex, $0.characterOffset] }, [[after.marked.chapter, after.marked.offset]])
        XCTAssertEqual(reader.book.skippedHeadings?.map { [$0.chapterIndex, $0.characterOffset] }, [[after.shoals.chapterIndex, after.shoals.characterOffset]])
    }

    /// An edit taken while a reader loads, through the settle a load makes
    /// of an edit not yet taken: the reader opens on the edited text, its
    /// cursor, bookmark, and skipped heading at their moved places.
    func testAReaderLoadingWhenTheEditIsTakenOpensOnTheMovedPlaces() async throws {
        let world = try makeIntegrationWorld("Edit Reader Loading")
        let book = try world.importBook(from: writeSource(named: "Pilot Rota Ten.md", Self.twoChapters))
        let before = try landmarks(in: Self.twoChapters)
        let after = try landmarks(in: Self.paragraphAdded)
        savePlaces(before, on: book, in: world)
        let editor = makeEditor(sessions: .shared)
        defer { editor.endAll() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        await waitForChecks(of: editor.sessions)
        // The edit is saved but not yet taken when the reader opens.
        try Self.paragraphAdded.write(to: MarkdownCacheService.cacheURL(for: book), atomically: true, encoding: .utf8)
        let reader = world.openReader(for: try XCTUnwrap(world.library.bookByID(book.id)))

        await waitForReaderToLoadYielding(reader)
        // The row may take the edit just after the load: wait until it has.
        let digest = try FileImportService.md5Hash(of: MarkdownCacheService.cacheURL(for: book))
        let taken = await eventually(timeout: 10) { world.library.bookByID(book.id)?.textCacheFingerprint?.cache.digest == digest }
        XCTAssertTrue(taken, "the row never took the edit")

        XCTAssertTrue(
            reader.content?.chapters.dropFirst().first?.text.contains("A pilot boat waits") == true,
            "the reader opened on the earlier text"
        )
        XCTAssertEqual(cursor(of: reader), after.reading)
        try assertReaderFollowed(reader, to: after, book: book, in: world)
    }

    /// An edit saved while TextMouth was closed, with no session's copy of
    /// the old text: the launch pass takes it and leaves the places, and a
    /// reader's open then moves them by their saved words, which the row and
    /// the record hold afterwards.
    func testAReaderOpenedAfterAnEditSavedWhileClosedFindsThePlacesByTheirWords() async throws {
        let world = try makeIntegrationWorld("Edit Reader Closed")
        let book = try world.importBook(from: writeSource(named: "Pilot Rota Eleven.md", Self.twoChapters))
        let before = try landmarks(in: Self.twoChapters)
        let after = try landmarks(in: Self.paragraphAdded)
        savePlaces(before, on: book, in: world)
        XCTAssertEqual(editCopies(of: book), [])
        try Self.paragraphAdded.write(to: MarkdownCacheService.cacheURL(for: book), atomically: true, encoding: .utf8)
        await runLaunchCachePass(of: world.library)
        XCTAssertEqual(coordinates(of: try XCTUnwrap(world.library.bookByID(book.id))), before.coordinates, "the launch pass moved the places")

        let reader = world.openReader(for: try XCTUnwrap(world.library.bookByID(book.id)))
        await waitForReaderToLoadYielding(reader)

        try assertReaderFollowed(reader, to: after, book: book, in: world)
        XCTAssertEqual(cursor(of: reader), after.reading)
    }

    /// Where `reader`'s cursor is.
    private func cursor(of reader: ReaderViewModel) -> TextPlace {
        TextPlace(chapter: reader.currentChapterIndex, offset: reader.currentCharacterOffset)
    }

    /// Checks that `reader`, the row, and the record of `book` all hold the
    /// places of `landmarks` (the text the reader shows): the reader's own
    /// copy of the book, its bookmark list, and its skipped heading
    /// (`isHeadingSkipped`, which the reader's filter reads).
    private func assertReaderFollowed(
        _ reader: ReaderViewModel,
        to landmarks: Landmarks,
        book: Book,
        in world: IntegrationWorld,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(coordinates(of: reader.book), landmarks.coordinates, "the reader's copy of the book", file: file, line: line)
        XCTAssertEqual(
            reader.bookmarks.map { [$0.chapterIndex, $0.characterOffset] },
            [[landmarks.marked.chapter, landmarks.marked.offset]],
            "the reader's bookmark list",
            file: file,
            line: line
        )
        let shoals = try XCTUnwrap(reader.headings.first { $0.text == "Shoals" }, "no Shoals heading", file: file, line: line)
        XCTAssertTrue(reader.isHeadingSkipped(shoals), "the skipped heading is not skipped", file: file, line: line)
        XCTAssertEqual(reader.skippedHeadingIDs, [landmarks.shoals.id], file: file, line: line)
        XCTAssertEqual(coordinates(of: try XCTUnwrap(world.library.bookByID(book.id))), landmarks.coordinates, "the row", file: file, line: line)
        XCTAssertEqual(coordinates(of: try recordedBook(like: book)), landmarks.coordinates, "the record", file: file, line: line)
    }

    // MARK: - Fixtures

    /// Two chapters, the second with a subheading.
    private static let twoChapters = """
    <!-- chapter: Harbour -->
    # Harbour

    The pilots meet the ships at dawn. They board from small launches.

    <!-- chapter: Channel -->
    # Channel

    Buoys mark the channel. The tide sets across it twice a day.

    ## Shoals

    Sand moves after every storm.
    """

    /// The two chapters as the user edits them: a paragraph added before
    /// "Buoys", and the subheading renamed.
    private static let editedChapters = """
    <!-- chapter: Harbour -->
    # Harbour

    The pilots meet the ships at dawn. They board from small launches.

    <!-- chapter: Channel -->
    # Channel

    A pilot boat waits at the outer mark.

    Buoys mark the channel. The tide sets across it twice a day.

    ## Sandbanks

    Sand moves after every storm.
    """

    /// Waits until `condition` holds or `timeout` passes, yielding the main
    /// actor between looks, so that what runs there meanwhile (a reader's
    /// load, a check's report) can run; an async test's own work holds the
    /// main actor while it spins the run loop, as `waitUntil` does.
    /// Returns the outcome.
    private func eventually(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    /// Runs the launch's cache pass over `library`
    /// (`LibraryViewModel.extractMissingContentCaches`), as launch and a
    /// library opening do, and waits for it to end, yielding the main
    /// actor; then writes every pending save. A pass that ends after the
    /// wait only sets a flag.
    private func runLaunchCachePass(of library: LibraryViewModel) async {
        let finished = OSAllocatedUnfairLock(initialState: false)
        library.extractMissingContentCaches { finished.withLock { $0 = true } }
        let ended = await eventually(timeout: 30) { finished.withLock { $0 } }
        XCTAssertTrue(ended, "the launch's cache pass never ended")
        LibraryPersistenceService.flushPendingSave()
    }

    /// Writes `text` as a file named `name` in a sandbox folder of its own,
    /// for an import to read.
    private func writeSource(named name: String, _ text: String) throws -> URL {
        let file = try makeSandboxDirectory("Edit Text Source").appendingPathComponent(name)
        try Data(text.utf8).write(to: file)
        return file
    }

    /// An editor of the test's own, with what it was asked to do.
    @MainActor
    struct TestEditor {
        let editor: BookTextEditor
        let recorder: EditorRecorder
        let sessions: BookTextEditSessions
        let readingTexts: ReadingTextCache

        /// Ends every session the test began.
        func endAll() {
            editor.endAll()
        }
    }

    /// An editor whose explanation, app chooser, and opener are `recorder`'s,
    /// remembering its explanation in a sandboxed store, its sessions
    /// checking with `access` inside `boundary` and dropping reading texts
    /// from a sandbox folder; or using `sessions` when given.
    private func makeEditor(
        access: MaintenanceFileAccess = .live,
        boundary: StorageBoundary = .shared,
        sessions given: BookTextEditSessions? = nil
    ) -> TestEditor {
        let recorder = EditorRecorder()
        let readingTexts = ReadingTextCache(folder: HostedTestSandbox.home.appendingPathComponent("Edit Text Reading Texts \(UUID().uuidString)"))
        let sessions = given ?? BookTextEditSessions(access: access, readingTexts: readingTexts, boundary: boundary)
        let editor = BookTextEditor(
            sessions: sessions,
            preferences: makeSandboxedPreferences("Edit Text"),
            notificationCenter: NotificationCenter(),
            explain: { title, _ in recorder.explain(title) },
            chooseApp: { title, _ in recorder.chooseApp(title) },
            open: { file, app in try recorder.open(file, app) },
            isAppActive: { true }
        )
        return TestEditor(editor: editor, recorder: recorder, sessions: sessions, readingTexts: readingTexts)
    }

    /// What one check of `book` finds now, waited for.
    private func checkResult(of book: Book, in sessions: BookTextEditSessions) async -> BookTextEditCheck {
        await withCheckedContinuation { continuation in
            sessions.queue.async {
                let found = BookTextEditSessions.check(
                    book,
                    against: sessions.baseline(of: book.id) ?? BookTextBaseline(source: nil, cache: FileFingerprint(stamp: FileStamp(byteCount: 0, modificationTimeNanoseconds: 0), digest: "")),
                    access: sessions.access,
                    readingTexts: sessions.readingTexts
                )
                continuation.resume(returning: found.found)
            }
        }
    }

    /// Checks `book` through `editor` as TextMouth becoming active does,
    /// and returns what VoiceOver heard since, waiting a moment for it.
    private func check(
        _ book: Book,
        with editor: TestEditor,
        in announcements: AnnouncementCapture
    ) async -> [String] {
        let before = announcements.messages.count
        editor.editor.appBecameActive()
        // The check runs on the sessions' queue; a check queued after it
        // returns once it has run, and its report reaches the main actor.
        await withCheckedContinuation { continuation in
            editor.sessions.queue.async { continuation.resume() }
        }
        _ = await eventually(timeout: 2) { announcements.messages.count > before }
        return Array(announcements.messages.dropFirst(before))
    }

    /// Waits until the sessions' queue has run everything queued so far: a
    /// session's copy of its text, and the checks of an app becoming active.
    private func waitForChecks(of sessions: BookTextEditSessions) async {
        await withCheckedContinuation { continuation in
            sessions.queue.async { continuation.resume() }
        }
    }

    /// The folders of the Edit Text snapshots that hold a copy of `book`,
    /// sorted by name. Read from the folder itself, as the snapshots folder
    /// of the rebuilds is read (`snapshotsHoldACopy(of:)`).
    private func editCopies(of book: Book) -> [URL] {
        let root = MachineLocalPaths.editTextSnapshots
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names
            .filter { $0.hasPrefix("\(book.id.uuidString) ") }
            .sorted()
            .map { root.appendingPathComponent($0, isDirectory: true) }
    }

    /// The text a copy's folder holds, as bytes.
    private func textKept(in copy: URL) -> Data? {
        try? Data(contentsOf: copy.appendingPathComponent(PlaceSnapshot.textFileName))
    }

    /// The record a copy's folder holds.
    private func recordKept(in copy: URL) throws -> PlaceSnapshot.Record {
        try JSONDecoder().decode(
            PlaceSnapshot.Record.self,
            from: Data(contentsOf: copy.appendingPathComponent(PlaceSnapshot.recordFileName))
        )
    }

    /// The copies of the user's text kept beside `book`'s content.md, oldest
    /// first.
    private func keptCopies(of book: Book) -> [URL] {
        LibraryIndexQuarantine.existingCopies(
            of: MarkdownCacheService.cacheURL(for: book),
            marker: TextMouthPaths.keptTextCopyMarker
        )
    }
}

// MARK: - Test Doubles

/// What the test's editor was asked to do, and how it answers: the
/// explanation, the app chooser, and the opener.
@MainActor
final class EditorRecorder {
    /// The titles of the books the explanation was given for.
    private(set) var explained: [String] = []
    /// The titles of the books an app was chosen for.
    private(set) var choseAppFor: [String] = []
    /// The files opened, with the app each was opened in.
    private(set) var opened: [(file: URL, app: URL?)] = []
    /// Whether the user goes on after the explanation.
    var goesOn = true
    /// The app the user chooses, or nil for Cancel.
    var chosenApp: URL?
    /// The error opening fails with, or nil.
    var openError: Error?

    func explain(_ title: String) -> Bool {
        explained.append(title)
        return goesOn
    }

    func chooseApp(_ title: String) -> URL? {
        choseAppFor.append(title)
        return chosenApp
    }

    func open(_ file: URL, _ app: URL?) throws {
        if let openError { throw openError }
        opened.append((file, app))
    }
}

/// A file a test can put in the cloud and bring back, as a sync service
/// evicts and downloads it: dataless, and its reads refused, while
/// `isInCloud` is true.
final class CloudSwitch: Sendable {
    /// The file's path.
    private let path: String
    /// Whether the file is in the cloud now, guarded by the lock itself.
    private let state = OSAllocatedUnfairLock(initialState: false)

    init(_ url: URL) {
        path = url.standardizedFileURL.path
    }

    /// Whether the file is in the cloud now.
    var isInCloud: Bool {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    /// An access that calls the file dataless while it is in the cloud.
    var access: MaintenanceFileAccess {
        MaintenanceFileAccess(
            isDataless: { [self] in $0.standardizedFileURL.path == path && isInCloud },
            refusesRead: { [self] in $0.standardizedFileURL.path == path && isInCloud }
        )
    }
}
