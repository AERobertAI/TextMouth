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
/// for the hold.
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
    /// UTF-8, is refused, announced once however often it is checked; the
    /// record, the row, and the reader keep the text they had.
    func testARefusedEditKeepsTheEarlierText() async throws {
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

        try "   \n\n\t\n".write(to: cache, atomically: true, encoding: .utf8)
        try await check(book, with: editor, expecting: BookTextEditWording.refused(.noChapters, bookTitle: book.title), in: announcements)
        try await check(book, with: editor, expecting: nil, in: announcements)
        try Data([0x48, 0xFF, 0xFE, 0x69]).write(to: cache)
        try await check(book, with: editor, expecting: BookTextEditWording.refused(.notText, bookTitle: book.title), in: announcements)

        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).contentIndex, indexBefore)
        XCTAssertEqual(world.library.bookByID(book.id)?.totalWordCount, indexBefore.totalWordCount)
        XCTAssertEqual(reader.content?.chapters.map(\.text), textBefore)
    }

    /// content.md edited while the book's own file changed too is not
    /// taken, and that is announced once.
    func testAnEditBesideAChangedSourceIsNotTaken() async throws {
        let world = try makeIntegrationWorld("Edit Text Source Changed")
        let book = try world.importBook(from: writeSource(named: "Harbour Pilots.md", Self.twoChapters))
        let indexBefore = try XCTUnwrap(BookInfo.load(from: book.tmbDirectory).contentIndex)
        let editor = makeEditor()
        defer { editor.endAll() }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)

        try (Self.twoChapters + "\n\nA new closing line.").write(to: book.bookFileURL, atomically: true, encoding: .utf8)
        try Self.editedChapters.write(to: MarkdownCacheService.cacheURL(for: book), atomically: true, encoding: .utf8)
        try await check(book, with: editor, expecting: BookTextEditWording.sourceChanged(bookTitle: book.title), in: announcements)
        try await check(book, with: editor, expecting: nil, in: announcements)

        XCTAssertEqual(try BookInfo.load(from: book.tmbDirectory).contentIndex, indexBefore)
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
    /// then asserts that exactly `expected` was announced since the last
    /// check (nothing for nil).
    private func check(
        _ book: Book,
        with editor: TestEditor,
        expecting expected: String?,
        in announcements: AnnouncementCapture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let before = announcements.messages.count
        editor.editor.appBecameActive()
        // The check runs on the sessions' queue; a check queued after it
        // returns once it has run, and its report reaches the main actor.
        await withCheckedContinuation { continuation in
            editor.sessions.queue.async { continuation.resume() }
        }
        _ = await eventually(timeout: 2) { announcements.messages.count > before }
        XCTAssertEqual(Array(announcements.messages.dropFirst(before)), expected.map { [$0] } ?? [], file: file, line: line)
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
