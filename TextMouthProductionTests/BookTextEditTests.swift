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
/// that replaces text the user saved keeps it first.
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
        XCTAssertNotNil(outcome, "Redo Text Extraction did not run")

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

    // MARK: - Where the Cursor Goes

    /// The cursor keeps its place in an unchanged chapter, follows the
    /// words it was at when text is added before them, stands after the
    /// words before it when its own were rewritten, finds its words in
    /// another chapter, and otherwise keeps its proportion at a word start.
    func testTheCursorFollowsItsWords() {
        let old = [
            Chapter(title: "One", text: "Alpha beta gamma delta epsilon zeta."),
            Chapter(title: "Two", text: "The harbour lights came on one by one along the quay."),
        ]
        let quay = ("The harbour lights came on one by one along the quay." as NSString).range(of: "one by one").location

        XCTAssertEqual(position(1, quay, old, old), [1, quay])

        let added = [old[0], Chapter(title: "Two", text: "Night fell early. The harbour lights came on one by one along the quay.")]
        XCTAssertEqual(position(1, quay, old, added), [1, quay + "Night fell early. ".utf16.count])

        let rewritten = [old[0], Chapter(title: "Two", text: "The harbour lights came on all at once.")]
        let afterKept = ("The harbour lights came on " as NSString).length
        XCTAssertEqual(position(1, quay, old, rewritten), [1, afterKept])

        let split = [
            old[0],
            Chapter(title: "Interlude", text: "Gulls."),
            Chapter(title: "Two", text: "The harbour lights came on one by one along the quay."),
        ]
        XCTAssertEqual(position(1, quay, old, split), [2, quay], "the chapter of the same title")

        let moved = [Chapter(title: "One", text: "Alpha beta gamma delta epsilon zeta. The harbour lights came on one by one along the quay.")]
        let movedOffset = (moved[0].text as NSString).range(of: "one by one").location
        XCTAssertEqual(position(1, quay, old, moved), [0, movedOffset])

        let unrelated = [old[0], Chapter(title: "Two", text: "Completely different words fill this chapter now, end to end.")]
        let proportional = position(1, quay, old, unrelated)
        XCTAssertEqual(proportional.first, 1)
        let text = unrelated[1].text
        XCTAssertEqual(proportional.last, ReaderViewModel.snappedWordStart(in: text, at: proportional.last ?? -1))

        XCTAssertEqual(position(9, 4, old, old), [1, 4], "a chapter past the end is clamped")
        XCTAssertEqual(position(0, 0, old, []), [0, 0])
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

    /// Waits until `reader` has loaded its book, yielding the main actor
    /// (`eventually`), and fails the test when it never does.
    private func waitForReaderToLoadYielding(
        _ reader: ReaderViewModel,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let loaded = await eventually(timeout: 10) { !reader.isLoading }
        XCTAssertTrue(loaded, "\(reader.book.title) never finished loading", file: file, line: line)
    }

    /// The cursor `EditedTextCursor` gives, as [chapter, offset].
    private func position(_ chapter: Int, _ offset: Int, _ old: [Chapter], _ new: [Chapter]) -> [Int] {
        let found = EditedTextCursor.position(chapterIndex: chapter, characterOffset: offset, in: old, to: new)
        return [found.chapterIndex, found.characterOffset]
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
