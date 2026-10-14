import XCTest
@testable import TextMouth

/// Edit Manifest in Default Editor and Edit Manifest With… (FR17): which
/// books offer them, the manifest written for a book without one, and how
/// an edit the user saves is taken.
///
/// Every book here is a world's book of silent tracks
/// (`IntegrationWorld.makeSilentAudioBook`): nothing is heard, nothing is
/// opened in another app, and nothing outside the test's sandbox is read.
@MainActor
final class BookManifestEditTests: XCTestCase {

    // MARK: - Which Books (Item 1)

    /// Only an audiobook of the library's own, in a package of its own,
    /// whose audio is a folder of tracks, can have its manifest edited: not
    /// a feed's item, a book without a package, or a text book, whatever
    /// its folder holds.
    func testOnlyALibraryAudiobookOfTracksInItsOwnPackageIsOffered() {
        let audio = Book(title: "Tide Tables", format: .audio, filePath: "/Library/Tide.tmb/audio", md5Hash: "tide", folderPath: "", tmbDirectoryName: "Tide.tmb")
        XCTAssertTrue(BookManifestEditing.canEditManifest(of: audio, isTrackFolder: true))
        XCTAssertFalse(BookManifestEditing.canEditManifest(of: audio, isTrackFolder: false), "A book that is no folder of tracks was offered")

        var feedItem = audio
        feedItem.feedLink = FeedBookLink(feedID: UUID(), itemID: "guid:tide")
        XCTAssertFalse(BookManifestEditing.canEditManifest(of: feedItem, isTrackFolder: true), "A feed's item was offered")

        var withoutPackage = audio
        withoutPackage.tmbDirectoryName = ""
        XCTAssertFalse(BookManifestEditing.canEditManifest(of: withoutPackage, isTrackFolder: true), "A book without a package was offered")

        var text = audio
        text.format = .txt
        XCTAssertFalse(BookManifestEditing.canEditManifest(of: text, isTrackFolder: true), "A text book was offered")
    }

    /// A folder of tracks plays one track per heading with or without a
    /// manifest, and with one inside its one folder; a converted DAISY
    /// book's folder of sections and a single-file audiobook do not.
    func testAFolderOfTracksIsFoundWithOrWithoutAManifest() throws {
        let world = try makeIntegrationWorld("Edit Manifest Which Books")
        let plain = try world.makeSilentAudioBook(title: "Plain Tracks", trackDurations: [0.2, 0.2])
        let listed = try world.makeSilentAudioBook(
            title: "Listed Tracks",
            trackDurations: [0.2, 0.2],
            manifest: #"{"tracks": ["02.wav", "01.wav"]}"#
        )
        let sections = try world.makeSegmentedAudioBook(
            title: "Sections",
            files: ["a.wav": 0.4],
            sections: [
                AudioSegment(title: "One", file: "a.wav", startTime: 0, endTime: 0.2),
                AudioSegment(title: "Two", file: "a.wav", startTime: 0.2, endTime: 0.4)
            ]
        )
        let single = try world.makeSilentAudioFileBook(title: "Single File", duration: 0.2)

        XCTAssertTrue(BookManifestEditing.hasTrackFolder(plain), "A folder of tracks without a manifest was not found")
        XCTAssertTrue(BookManifestEditing.hasTrackFolder(listed), "A folder of tracks with a manifest was not found")
        XCTAssertFalse(BookManifestEditing.hasTrackFolder(sections), "A folder of sections was taken for one of tracks")
        XCTAssertFalse(BookManifestEditing.hasTrackFolder(single), "A single-file audiobook was taken for a folder of tracks")

        // A manifest inside the folder's one folder is found where the
        // reader finds it, and its sections count there too.
        let wrapped = try makeSandboxDirectory("Edit Manifest Wrapped")
        let inner = wrapped.appendingPathComponent("Radio", isDirectory: true)
        try AudioTestFixtures.writeSilence(to: inner.appendingPathComponent("a.wav"), duration: 0.2)
        try Data(#"{"title": "Wrapped"}"#.utf8).write(to: inner.appendingPathComponent(AudioManifest.fileName))
        XCTAssertEqual(BookManifestEditing.isTrackFolder(wrapped), true)
        try Data(#"{"segments": [{"title": "One", "file": "a.wav", "startTime": 0, "endTime": 0.1}]}"#.utf8)
            .write(to: inner.appendingPathComponent(AudioManifest.fileName))
        XCTAssertEqual(BookManifestEditing.isTrackFolder(wrapped), false, "A wrapped manifest's sections were missed")
    }

    /// A folder only in the cloud, or whose manifest is, is not looked into,
    /// so nothing is downloaded, and it is not offered until it is here.
    func testAFolderOnlyInTheCloudIsNotLookedInto() throws {
        let world = try makeIntegrationWorld("Edit Manifest Cloud")
        let book = try world.makeSilentAudioBook(title: "Cloud Tracks", trackDurations: [0.2], manifest: #"{"title": "Cloud Tracks"}"#)
        let folder = book.bookFileURL

        XCTAssertNil(BookManifestEditing.isTrackFolder(folder, isDataless: { _ in true }))
        XCTAssertNil(BookManifestEditing.isTrackFolder(folder, isDataless: { $0.lastPathComponent == AudioManifest.fileName }))
        XCTAssertFalse(BookManifestEditing.hasTrackFolder(book, isDataless: { _ in true }))
    }

    /// The store records the books whose audio is a folder of tracks, and
    /// only those, so a row and a reader offer the commands for them alone.
    func testTheStoreRecordsOnlyTheFoldersOfTracks() async throws {
        let world = try makeIntegrationWorld("Edit Manifest Store")
        let tracks = try world.makeSilentAudioBook(title: "Store Tracks", trackDurations: [0.2, 0.2])
        let single = try world.makeSilentAudioFileBook(title: "Store Single", duration: 0.2)
        var feedItem = try world.makeSilentAudioBook(title: "Store Episode", trackDurations: [0.2])
        feedItem.feedLink = FeedBookLink(feedID: UUID(), itemID: "guid:episode")
        let store = TrackFolderBooks()

        await store.refresh([tracks, single, feedItem])

        XCTAssertEqual(store.bookIDs, [tracks.id])
        XCTAssertTrue(store.contains(tracks.id))
        XCTAssertFalse(store.contains(single.id))
    }

    // MARK: - The Commands (Item 2)

    /// The commands, the explanation, and the app chooser are worded as
    /// Edit Text's are, for a manifest, and VoiceOver hears "Manifest
    /// updated" when an edit is taken.
    func testTheCommandsAreWordedForAManifest() {
        XCTAssertEqual(BookManifestEditWording.editTitle, "Edit Manifest in Default Editor")
        XCTAssertEqual(BookManifestEditWording.editWithTitle, "Edit Manifest With…")
        XCTAssertEqual(BookManifestEditWording.explanationTitle(bookTitle: "Tide Tables"), "Edit the Manifest of Tide Tables?")
        XCTAssertEqual(BookManifestEditWording.appPanelTitle, "Edit Manifest With")
        XCTAssertEqual(
            BookManifestEditWording.appPanelMessage(bookTitle: "Tide Tables"),
            "Choose the app to edit the manifest of Tide Tables with."
        )
        XCTAssertEqual(BookManifestEditWording.updated, "Manifest updated")
        XCTAssertTrue(BookManifestEditWording.explanation.hasSuffix("This explanation appears only once."))
        XCTAssertTrue(
            ConfigService.AppConfig.Portability.localStoreKeys.contains(BookManifestEditor.explainedPreference.key),
            "Whether Edit Manifest explained itself would travel in config.json"
        )
    }

    /// The first Edit Manifest explains itself and opens the manifest with
    /// the default app; the next opens it at once; Edit Manifest With… asks
    /// for the app and opens it there. The book's manifest is opened as it
    /// is, never written again.
    func testEditManifestExplainsItselfOnceThenOpensTheManifest() async throws {
        let world = try makeIntegrationWorld("Edit Manifest Opens")
        let manifestText = #"{"title": "Tide Tables", "tracks": ["02.wav", "01.wav"]}"#
        let book = try world.makeSilentAudioBook(title: "Tide Tables", trackDurations: [0.2, 0.2], manifest: manifestText)
        let editor = makeEditor()
        defer { editor.editor.endAll() }
        let manifest = book.bookFileURL.appendingPathComponent(AudioManifest.fileName)

        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        editor.recorder.chosenApp = textEdit
        await editor.editor.edit(book, choosingApp: true, in: world.library, from: nil)

        XCTAssertEqual(editor.recorder.explained, ["Tide Tables"], "The explanation was not given once")
        XCTAssertEqual(editor.recorder.choseAppFor, ["Tide Tables"])
        XCTAssertEqual(editor.recorder.opened.map(\.file.standardizedFileURL), Array(repeating: manifest.standardizedFileURL, count: 3))
        XCTAssertEqual(editor.recorder.opened.map(\.app), [nil, nil, textEdit])
        XCTAssertEqual(try String(contentsOf: manifest, encoding: .utf8), manifestText, "The book's manifest was written again")
        XCTAssertTrue(editor.sessions.isEditing(book.id))
    }

    /// Cancelling the explanation, or the app chooser, opens nothing, starts
    /// no session, and writes no manifest for a book without one.
    func testCancellingOpensNothingAndWritesNothing() async throws {
        let world = try makeIntegrationWorld("Edit Manifest Cancel")
        let book = try world.makeSilentAudioBook(title: "Plain Tracks", trackDurations: [0.2, 0.2])
        let editor = makeEditor()
        defer { editor.editor.endAll() }

        editor.recorder.goesOn = false
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        editor.recorder.goesOn = true
        editor.recorder.chosenApp = nil
        await editor.editor.edit(book, choosingApp: true, in: world.library, from: nil)

        XCTAssertTrue(editor.recorder.opened.isEmpty)
        XCTAssertFalse(editor.sessions.isEditing(book.id))
        XCTAssertNil(AudioManifestLocation.find(in: book.bookFileURL), "A manifest was written for a book the user did not edit")
    }

    /// A book that is no audiobook of tracks says so and opens nothing, and
    /// an editor that cannot open the manifest says why and ends the
    /// session it began.
    func testWhyNothingOpenedIsSaid() async throws {
        let world = try makeIntegrationWorld("Edit Manifest Refused")
        let single = try world.makeSilentAudioFileBook(title: "Single File", duration: 0.2)
        let tracks = try world.makeSilentAudioBook(title: "Plain Tracks", trackDurations: [0.2])
        let editor = makeEditor()
        defer { editor.editor.endAll() }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        await editor.editor.edit(single, choosingApp: false, in: world.library, from: nil)
        editor.recorder.openError = CocoaError(.fileReadNoPermission)
        await editor.editor.edit(tracks, choosingApp: false, in: world.library, from: nil)

        XCTAssertTrue(editor.recorder.opened.isEmpty)
        XCTAssertFalse(editor.sessions.isEditing(tracks.id), "A session outlived an editor that could not open")
        XCTAssertEqual(announcements.messages.first, BookManifestEditWording.noManifest(bookTitle: "Single File"))
        XCTAssertEqual(announcements.messages.count, 2)
        XCTAssertTrue(announcements.messages.last?.hasPrefix("Couldn't open the manifest of Plain Tracks: ") == true)
    }

    // MARK: - A Manifest for a Book Without One (Item 3)

    /// A book without a manifest is given one before it opens: its tracks in
    /// the order they play, each with its heading's title, in the tracks
    /// format, with its title and author, and no pause between tracks. Read
    /// as the reader reads it, it changes nothing: the same headings, and
    /// the tracks still play straight on into each other.
    func testABookWithoutAManifestIsGivenOneThatChangesNothing() async throws {
        let world = try makeIntegrationWorld("Edit Manifest Written")
        let book = try world.makeSilentAudioBook(title: "Plain Tracks", trackDurations: [0.2, 0.3, 0.2])
        let before = try XCTUnwrap(book.storedBookInfo()?.contentIndex)
        let editor = makeEditor()
        defer { editor.editor.endAll() }

        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)

        let location = try XCTUnwrap(AudioManifestLocation.find(in: book.bookFileURL), "No manifest was written")
        XCTAssertEqual(location.prefix, "")
        XCTAssertEqual(editor.recorder.opened.map(\.file.standardizedFileURL), [location.url.standardizedFileURL])
        let written = try AudioManifest.decoded(from: Data(contentsOf: location.url))
        XCTAssertEqual(written.title, "Plain Tracks")
        XCTAssertEqual(written.author, book.author)
        XCTAssertEqual(written.pauseBetweenTracksMs, 0)
        XCTAssertEqual(written.tracks, [
            .track(AudioManifestTrack(file: "01.wav", title: "01")),
            .track(AudioManifestTrack(file: "02.wav", title: "02")),
            .track(AudioManifestTrack(file: "03.wav", title: "03"))
        ])
        XCTAssertNil(written.order)
        XCTAssertNil(written.chapters)

        let after = try BookContentAnalysisService.analyzeAudio(book: book, url: book.bookFileURL).index
        XCTAssertEqual(after.allHeadings.map(\.text), before.allHeadings.map(\.text))
        XCTAssertEqual(after.chapters.map(\.audioFilePath), before.chapters.map(\.audioFilePath))
        let pauses = ChapterPauses.betweenTracks(of: after, inAudioFolder: book.bookFileURL)
        XCTAssertEqual((0..<3).map { pauses.after(chapter: $0) }, [0, 0, 0], "The written manifest put pauses between the tracks")
    }

    /// A folder whose top level holds only one folder is given its manifest
    /// inside that folder, where Finder's Compress command would have put
    /// one, naming each track by its own name; the reader finds it there.
    func testAWrappedFolderIsGivenItsManifestInsideItsOneFolder() async throws {
        let world = try makeIntegrationWorld("Edit Manifest Wrapped")
        let book = try makeWrappedAudioBook(in: world, title: "Wrapped Tracks", wrapper: "Disc One", tracks: ["b.wav", "a.wav"])
        let editor = makeEditor()
        defer { editor.editor.endAll() }

        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)

        let location = try XCTUnwrap(AudioManifestLocation.find(in: book.bookFileURL))
        XCTAssertEqual(location.prefix, "Disc One/")
        let written = try AudioManifest.decoded(from: Data(contentsOf: location.url))
        XCTAssertEqual(written.tracks, [
            .track(AudioManifestTrack(file: "a.wav", title: "a")),
            .track(AudioManifestTrack(file: "b.wav", title: "b"))
        ])
    }

    // MARK: - Taking an Edit (Item 4)

    /// An edit with a problem changes nothing: VoiceOver hears the problem
    /// in the words an import uses, once for the same bytes, and the next
    /// save, a good one, is taken: the book's headings are rebuilt in the
    /// manifest's order, its record and row take them, and VoiceOver hears
    /// "Manifest updated".
    func testAnEditWithAProblemChangesNothingAndTheNextSaveIsTaken() async throws {
        let world = try makeIntegrationWorld("Edit Manifest Takes")
        let book = try world.makeSilentAudioBook(title: "Harbour Pilots", trackDurations: [0.2, 0.3, 0.4])
        let indexBefore = try XCTUnwrap(book.storedBookInfo()?.contentIndex)
        let editor = makeEditor()
        defer { editor.editor.endAll() }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        let manifest = try XCTUnwrap(AudioManifestLocation.find(in: book.bookFileURL)).url

        try save(#"{"titel": "Harbour Pilots"}"#, to: manifest)
        let refused = await check(with: editor, in: announcements)
        let problem = try XCTUnwrap(AudioManifestProblem.unknownKeys(["titel"], entry: nil).errorDescription)
        XCTAssertEqual(refused, [BookManifestEditWording.notTaken(problem: problem, bookTitle: "Harbour Pilots")])
        XCTAssertEqual(book.storedBookInfo()?.contentIndex?.allHeadings.map(\.text), indexBefore.allHeadings.map(\.text))
        let again = await check(with: editor, in: announcements)
        XCTAssertEqual(again, [], "The same refused bytes were announced twice")

        try save("""
        {
          "title": "Harbour Pilots",
          "tracks": [
            { "heading": "Night Watch" },
            { "file": "03.wav", "title": "Third" },
            "01.wav",
            { "file": "02.wav", "title": "Second" }
          ]
        }
        """, to: manifest)
        let taken = await check(with: editor, in: announcements)

        XCTAssertEqual(taken, [BookManifestEditWording.updated])
        let index = try XCTUnwrap(book.storedBookInfo()?.contentIndex)
        XCTAssertEqual(index.allHeadings.map(\.text), ["Night Watch", "Third", "01", "Second"])
        XCTAssertEqual(index.chapters.map(\.audioFilePath), ["03.wav", "01.wav", "02.wav"])
        let row = try XCTUnwrap(world.library.bookByID(book.id))
        XCTAssertEqual(row.audioDuration ?? 0, 0.9, accuracy: 0.05, "The row lost the book's duration")
        XCTAssertTrue(editor.sessions.isEditing(book.id), "The session ended with the edit")
    }

    /// A manifest that would make the book's tracks into sections, as a
    /// converted DAISY book's does, is refused, and the book keeps its
    /// headings.
    func testAnEditGivingSectionsIsRefused() async throws {
        let world = try makeIntegrationWorld("Edit Manifest Sections")
        let book = try world.makeSilentAudioBook(title: "Harbour Pilots", trackDurations: [0.4, 0.2])
        let editor = makeEditor()
        defer { editor.editor.endAll() }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        let manifest = try XCTUnwrap(AudioManifestLocation.find(in: book.bookFileURL)).url

        try save(#"{"segments": [{"title": "One", "file": "01.wav", "startTime": 0, "endTime": 0.2}]}"#, to: manifest)
        let heard = await check(with: editor, in: announcements)

        XCTAssertEqual(heard, [BookManifestEditWording.notTaken(problem: BookManifestEditWording.sectionsGiven, bookTitle: "Harbour Pilots")])
        XCTAssertEqual(book.storedBookInfo()?.contentIndex?.chapters.map(\.audioFilePath), ["01.wav", "02.wav"])
    }

    // MARK: - Helpers

    /// An editor of the test's own, with what it was asked to do.
    struct TestEditor {
        let editor: BookManifestEditor
        let recorder: EditorRecorder
        let sessions: BookManifestEditSessions
    }

    /// An editor whose explanation, app chooser, and opener are a
    /// recorder's, remembering its explanation in a sandboxed store, and
    /// whose sessions are its own.
    private func makeEditor() -> TestEditor {
        let recorder = EditorRecorder()
        let sessions = BookManifestEditSessions()
        let editor = BookManifestEditor(
            sessions: sessions,
            preferences: makeSandboxedPreferences("Edit Manifest"),
            notificationCenter: NotificationCenter(),
            explain: { title, _ in recorder.explain(title) },
            chooseApp: { title, _ in recorder.chooseApp(title) },
            open: { file, app in try recorder.open(file, app) },
            isAppActive: { true }
        )
        return TestEditor(editor: editor, recorder: recorder, sessions: sessions)
    }

    /// Saves `text` as the manifest at `url`, as an editor saves it: a new
    /// file put in its place, a moment later than the last save, so its
    /// stamp differs.
    private func save(_ text: String, to url: URL) throws {
        let later = Date().addingTimeInterval(1)
        try Data(text.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path)
    }

    /// Checks every book through `editor` as TextMouth becoming active does,
    /// and returns what VoiceOver heard since, waiting a moment for it.
    private func check(with editor: TestEditor, in announcements: AnnouncementCapture) async -> [String] {
        let before = announcements.messages.count
        editor.editor.appBecameActive()
        // The check runs on the sessions' queue; a block queued after it
        // runs once it has, and its report then reaches the main actor.
        await withCheckedContinuation { continuation in
            editor.sessions.queue.async { continuation.resume() }
        }
        _ = await eventually(timeout: 2) { announcements.messages.count > before }
        return Array(announcements.messages.dropFirst(before))
    }

    /// An audiobook whose tracks, named `tracks`, are silent and lie in the
    /// one folder `wrapper` of its audio folder, as Finder's Compress
    /// command leaves a ZIP's tracks, indexed and listed in `world`.
    private func makeWrappedAudioBook(in world: IntegrationWorld, title: String, wrapper: String, tracks: [String]) throws -> Book {
        let packageName = "\(UUID().uuidString).tmb"
        let audio = TextMouthPaths.tmbPath(folderPath: world.folder.path, tmbName: packageName)
            .appendingPathComponent("audio", isDirectory: true)
        for name in tracks {
            try AudioTestFixtures.writeSilence(to: audio.appendingPathComponent(wrapper).appendingPathComponent(name), duration: 0.2)
        }
        let book = Book(
            title: title,
            format: .audio,
            filePath: audio.path,
            md5Hash: UUID().uuidString,
            folderPath: world.folder.path,
            tmbDirectoryName: packageName
        )
        try book.saveBookInfoThrowing(contentIndex: BookContentAnalysisService.load(book: book).index)
        world.library.library.addBook(book)
        return book
    }

    // MARK: - Title and Author, Kept in Step (Item 4)

    /// An edited manifest's title and author become the book's, in its row
    /// and its record.
    func testAnEditedManifestsTitleAndAuthorBecomeTheBooks() async throws {
        let world = try makeIntegrationWorld("Edit Manifest Title")
        let book = try world.makeSilentAudioBook(title: "Harbour Pilots", trackDurations: [0.2, 0.2])
        let editor = makeEditor()
        defer { editor.editor.endAll() }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        let manifest = try XCTUnwrap(AudioManifestLocation.find(in: book.bookFileURL)).url

        try save(#"{"title": "Night Pilots", "author": "Ines Okafor", "tracks": ["02.wav", "01.wav"]}"#, to: manifest)
        let heard = await check(with: editor, in: announcements)

        XCTAssertEqual(heard, [BookManifestEditWording.updated])
        let row = try XCTUnwrap(world.library.bookByID(book.id))
        XCTAssertEqual(row.title, "Night Pilots")
        XCTAssertEqual(row.author, "Ines Okafor")
        LibraryPersistenceService.flushPendingSave()
        XCTAssertEqual(row.storedBookInfo()?.metadata.title, "Night Pilots", "The record kept the old title")
        XCTAssertEqual(row.storedBookInfo()?.metadata.author, "Ines Okafor")
    }

    /// An edit of the book's title and author in a metadata editor is
    /// written into its manifest at once, changing nothing else the user
    /// wrote there, a key TextMouth reads leniently included.
    func testAMetadataEditIsWrittenIntoTheManifest() async throws {
        let world = try makeIntegrationWorld("Edit Manifest Metadata")
        let book = try world.makeSilentAudioBook(
            title: "Harbour Pilots",
            trackDurations: [0.2, 0.2],
            manifest: #"{"title": "Harbour Pilots", "pauseBetweenTracksMs": 500, "tracks": [{"file": "02.wav", "title": "Ebb"}, "01.wav"]}"#
        )

        world.library.updateBookMetadata(
            Book.MetadataEdit(
                opened: [.title: "Harbour Pilots", .author: book.author],
                saved: [.title: "Night Pilots", .author: "Ines Okafor"]
            ),
            of: book.id
        )
        await waitForManifestWrites(of: .shared)

        let manifest = try XCTUnwrap(AudioManifestLocation.find(in: book.bookFileURL)).url
        let written = try AudioManifest.decoded(from: Data(contentsOf: manifest))
        XCTAssertEqual(written.title, "Night Pilots")
        XCTAssertEqual(written.author, "Ines Okafor")
        XCTAssertEqual(written.pauseBetweenTracksMs, 500)
        XCTAssertEqual(written.tracks, [.track(AudioManifestTrack(file: "02.wav", title: "Ebb")), .track(AudioManifestTrack(file: "01.wav"))])
        XCTAssertEqual(world.library.bookByID(book.id)?.title, "Night Pilots")
    }

    /// A metadata edit of a book of tracks without a manifest gives it one,
    /// holding the new title, and no pause between its tracks.
    func testAMetadataEditGivesABookWithoutAManifestOne() async throws {
        let world = try makeIntegrationWorld("Edit Manifest Metadata New")
        let book = try world.makeSilentAudioBook(title: "Harbour Pilots", trackDurations: [0.2, 0.2])

        world.library.updateBookMetadata(
            Book.MetadataEdit(opened: [.title: "Harbour Pilots"], saved: [.title: "Night Pilots"]),
            of: book.id
        )
        await waitForManifestWrites(of: .shared)

        let manifest = try XCTUnwrap(AudioManifestLocation.find(in: book.bookFileURL), "No manifest took the title").url
        let written = try AudioManifest.decoded(from: Data(contentsOf: manifest))
        XCTAssertEqual(written.title, "Night Pilots")
        XCTAssertEqual(written.author, book.author)
        XCTAssertEqual(written.pauseBetweenTracksMs, 0)
        XCTAssertEqual(written.tracks?.count, 2)
    }

    /// TextMouth's own write of the title, while the manifest is being
    /// edited, is not taken for the user's edit: no "Manifest updated".
    func testTextMouthsOwnWriteIsNotTakenForAnEdit() async throws {
        let world = try makeIntegrationWorld("Edit Manifest Own Write")
        let book = try world.makeSilentAudioBook(title: "Harbour Pilots", trackDurations: [0.2, 0.2])
        let editor = makeEditor()
        defer { editor.editor.endAll() }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        let baseline = editor.sessions.baseline(of: book.id)

        let written = expectation(description: "The manifest was written")
        world.library.setTitleAndAuthor(ofManifestBook: book.id, title: "Night Pilots", author: nil, sessions: editor.sessions) { didWrite in
            XCTAssertTrue(didWrite)
            written.fulfill()
        }
        await fulfillment(of: [written], timeout: 5)
        let heard = await check(with: editor, in: announcements)

        XCTAssertEqual(heard, [], "TextMouth's own write was announced as an edit")
        XCTAssertNotEqual(editor.sessions.baseline(of: book.id), baseline, "The session kept the baseline from before the write")
    }

    /// The launch's metadata refresh never changes the title or author of a
    /// book of tracks, which has no tags of its own: the row and the
    /// manifest keep what they say.
    func testTheLaunchRefreshLeavesAManifestBooksTitleAndAuthor() async throws {
        let world = try makeIntegrationWorld("Edit Manifest Refresh")
        let book = try world.makeSilentAudioBook(
            title: "Harbour Pilots",
            trackDurations: [0.2],
            manifest: #"{"title": "Harbour Pilots", "author": "Ines Okafor"}"#
        )
        world.library.updateBook(id: book.id) { row in
            row.author = "Ines Okafor"
            row.metadataReaderVersion = nil
            row.handEdits = .noneSinceImport
        }
        let manifest = try XCTUnwrap(AudioManifestLocation.find(in: book.bookFileURL)).url
        let before = try Data(contentsOf: manifest)
        XCTAssertTrue(LibraryViewModel.needsMetadataRefresh(try XCTUnwrap(world.library.bookByID(book.id))))

        let finished = expectation(description: "The metadata refresh finished")
        world.library.refreshOutdatedMetadata { finished.fulfill() }
        await fulfillment(of: [finished], timeout: 10)

        let row = try XCTUnwrap(world.library.bookByID(book.id))
        XCTAssertEqual(row.title, "Harbour Pilots")
        XCTAssertEqual(row.author, "Ines Okafor")
        XCTAssertEqual(try Data(contentsOf: manifest), before, "The refresh wrote the manifest")
    }

    /// Waits until the manifest writes queued on `sessions` so far have run.
    private func waitForManifestWrites(of sessions: BookManifestEditSessions) async {
        await withCheckedContinuation { continuation in
            sessions.queue.async { continuation.resume() }
        }
    }

    // MARK: - Places Follow Their Tracks (Item 5)

    /// Reordering the tracks moves the reading position and a bookmark to
    /// the chapters that play their tracks now, at the same time into each,
    /// in the row and in the record alike.
    func testThePositionAndABookmarkStayOnTheirTracksWhenTheTracksAreReordered() async throws {
        let world = try makeIntegrationWorld("Edit Manifest Places")
        let book = try world.makeSilentAudioBook(title: "Harbour Pilots", trackDurations: [0.4, 0.4, 0.4])
        let offset = AudioBookParser.characterOffset(forTime: 0.25)
        let bookmarkOffset = AudioBookParser.characterOffset(forTime: 0.1)
        world.library.updateBook(id: book.id) { row in
            row.readingPosition = ReadingPosition(chapterIndex: 2, characterOffset: offset)
            row.bookmarks = [Bookmark(number: 1, chapterIndex: 0, characterOffset: bookmarkOffset, label: "Pilot boat")]
        }
        LibraryPersistenceService.flushPendingSave()
        let editor = makeEditor()
        defer { editor.editor.endAll() }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        await editor.editor.edit(try XCTUnwrap(world.library.bookByID(book.id)), choosingApp: false, in: world.library, from: nil)
        let manifest = try XCTUnwrap(AudioManifestLocation.find(in: book.bookFileURL)).url

        try save(#"{"tracks": ["03.wav", "01.wav", "02.wav"]}"#, to: manifest)
        let heard = await check(with: editor, in: announcements)

        XCTAssertEqual(heard, [BookManifestEditWording.updated])
        let row = try XCTUnwrap(world.library.bookByID(book.id))
        XCTAssertEqual(row.readingPosition?.chapterIndex, 0, "The position left its track")
        XCTAssertEqual(row.readingPosition?.characterOffset, offset, "The position left its time")
        XCTAssertEqual(row.bookmarks.map(\.chapterIndex), [1], "The bookmark left its track")
        XCTAssertEqual(row.bookmarks.map(\.characterOffset), [bookmarkOffset])
        XCTAssertEqual(row.bookmarks.map(\.label), ["Pilot boat"])
        LibraryPersistenceService.flushPendingSave()
        let record = try XCTUnwrap(row.storedBookInfo())
        XCTAssertEqual(record.state.readingPosition?.chapterIndex, 0, "The record's position left its track")
        XCTAssertEqual(record.bookmarks.map(\.chapterIndex), [1], "The record's bookmark left its track")
    }

    /// Group headings and titles change nothing but headings: the position
    /// keeps its chapter, its time, and its date.
    func testGroupHeadingsAndTitlesMoveNoPlace() async throws {
        let world = try makeIntegrationWorld("Edit Manifest Places Kept")
        let book = try world.makeSilentAudioBook(title: "Harbour Pilots", trackDurations: [0.4, 0.4, 0.4])
        let offset = AudioBookParser.characterOffset(forTime: 0.2)
        world.library.updateBook(id: book.id) { row in
            row.readingPosition = ReadingPosition(chapterIndex: 1, characterOffset: offset)
        }
        let saved = try XCTUnwrap(world.library.bookByID(book.id)?.readingPosition)
        let editor = makeEditor()
        defer { editor.editor.endAll() }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        await editor.editor.edit(try XCTUnwrap(world.library.bookByID(book.id)), choosingApp: false, in: world.library, from: nil)
        let manifest = try XCTUnwrap(AudioManifestLocation.find(in: book.bookFileURL)).url

        try save(#"{"tracks": [{"heading": "Night Watch"}, {"file": "01.wav", "title": "Ebb"}, {"file": "02.wav", "title": "Flood"}, "03.wav"]}"#, to: manifest)
        let heard = await check(with: editor, in: announcements)

        XCTAssertEqual(heard, [BookManifestEditWording.updated])
        XCTAssertEqual(book.storedBookInfo()?.contentIndex?.allHeadings.map(\.text), ["Night Watch", "Ebb", "Flood", "03"])
        XCTAssertEqual(world.library.bookByID(book.id)?.readingPosition, saved, "A place moved though no track did")
    }

    /// A skipped track heading follows its track, taking its new title and
    /// level; a skipped group heading follows its words, and waits, naming
    /// no heading, once no group heading has them. The position's offset
    /// across the whole book is worked out anew.
    func testSkippedHeadingsFollowTheirTracksOrTheirWords() {
        let old = trackIndex([
            ("a.wav", ["Season One", "A"]),
            ("b.wav", ["B"]),
            ("c.wav", ["C"])
        ], groupLevels: true)
        let regrouped = trackIndex([
            ("c.wav", ["Season One", "C"]),
            ("a.wav", ["Alpha"]),
            ("b.wav", ["B"])
        ], groupLevels: true)
        let ungrouped = trackIndex([("c.wav", ["C"]), ("a.wav", ["A"]), ("b.wav", ["B"])], groupLevels: false)
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var places = PlaceRelocator.Places()
        places.position = ReadingPosition(chapterIndex: 1, characterOffset: 4, globalCharacterOffset: 14)
        places.skippedHeadings = [
            SkippedHeading(level: 2, label: "A", chapterIndex: 0, characterOffset: 0),
            SkippedHeading(level: 1, label: "Season One", chapterIndex: 0, characterOffset: 0),
            SkippedHeading(level: 2, label: "C", chapterIndex: 2, characterOffset: 0)
        ]

        let moved = TrackPlaces.moved(places, from: old, to: regrouped, at: date)

        XCTAssertEqual(moved.position?.chapterIndex, 2)
        XCTAssertEqual(moved.position?.characterOffset, 4)
        XCTAssertEqual(moved.position?.globalCharacterOffset, regrouped.chapterStartOffset(2) + 4)
        XCTAssertEqual(moved.position?.lastUpdated, date, "A position that changed chapter was not dated at the move")
        XCTAssertEqual(moved.skippedHeadings, [
            SkippedHeading(level: 2, label: "Alpha", chapterIndex: 1, characterOffset: 0),
            SkippedHeading(level: 1, label: "Season One", chapterIndex: 0, characterOffset: 0),
            SkippedHeading(level: 2, label: "C", chapterIndex: 0, characterOffset: 0)
        ])
        XCTAssertEqual(moved.waitingSkippedHeadings, [])

        let withoutGroup = TrackPlaces.moved(places, from: old, to: ungrouped, at: date)
        XCTAssertEqual(withoutGroup.skippedHeadings.map(\.label), ["A", "C"])
        XCTAssertEqual(withoutGroup.waitingSkippedHeadings, [SkippedHeading(level: 1, label: "Season One", chapterIndex: 0, characterOffset: 0)])
    }

    /// An index of a book of tracks, ten characters a chapter: each entry
    /// a track's file and its headings at its start, a group heading first;
    /// with `groupLevels`, a group heading is level 1 and every track after
    /// the first group is level 2, as `AudioTrackPlan` levels them.
    private func trackIndex(_ tracks: [(file: String, headings: [String])], groupLevels: Bool) -> BookContentIndex {
        let folder = URL(fileURLWithPath: "/Track Places", isDirectory: true)
        var grouped = false
        let chapters = tracks.enumerated().map { number, track -> Chapter in
            if groupLevels && track.headings.count > 1 {
                grouped = true
            }
            let headings = track.headings.enumerated().map { position, text in
                let isGroup = position < track.headings.count - 1
                return Heading(level: isGroup || !grouped ? 1 : 2, text: text, chapterIndex: number, characterOffset: 0)
            }
            return Chapter(title: track.headings.last ?? track.file, text: String(repeating: " ", count: 10), headings: headings)
        }
        return BookContentIndex.build(
            fromChapters: chapters,
            format: .audio,
            audioFilePaths: tracks.map { folder.appendingPathComponent($0.file).path },
            audioBaseURL: folder
        )
    }

    // MARK: - An Open or Playing Reader (Item 6)

    /// An open reader shows the new headings at once, its cursor on the
    /// same track at the same time, its chapter files in the new order, and
    /// saves its place there; nothing starts playing.
    func testAnOpenReaderShowsTheNewHeadingsWithItsCursorOnItsTrack() async throws {
        let world = try makeIntegrationWorld("Edit Manifest Open Reader")
        let book = try world.makeSilentAudioBook(title: "Harbour Soundings", trackDurations: [0.4, 0.4, 0.4])
        let reader = world.openReader(for: book)
        let files = try await loadedTrackFiles(of: reader, count: 3)
        let offset = AudioBookParser.characterOffset(forTime: 0.3)
        reader.navigateTo(chapterIndex: 2, characterOffset: offset)
        let editor = makeEditor()
        defer { editor.editor.endAll() }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        let manifest = try XCTUnwrap(AudioManifestLocation.find(in: book.bookFileURL)).url

        try save(#"{"tracks": [{"heading": "Ebb Tide"}, {"file": "03.wav", "title": "Third"}, "01.wav", "02.wav"]}"#, to: manifest)
        let heard = await check(with: editor, in: announcements)

        XCTAssertEqual(heard, [BookManifestEditWording.updated])
        XCTAssertEqual(reader.content?.contentIndex.allHeadings.map(\.text), ["Ebb Tide", "Third", "01", "02"])
        XCTAssertEqual(reader.currentChapterIndex, 0, "The cursor left its track")
        XCTAssertEqual(reader.currentCharacterOffset, offset, "The cursor left its time")
        XCTAssertEqual(reader.audioChapterFiles.map(resolvedPath), [files[2], files[0], files[1]])
        XCTAssertFalse(reader.isCurrentlyPlaying, "The edit started playback")
        XCTAssertEqual(world.library.bookByID(book.id)?.readingPosition?.chapterIndex, 0, "The reader's place was not saved on its track")
    }

    /// A playing reader plays on in the same file, on the same player, in
    /// the same play, without a break; the file named to follow is the next
    /// track in the new order, and the book goes on to it.
    func testAPlayingReaderPlaysOnIntoTheNextTrackInTheNewOrder() async throws {
        let world = try makeIntegrationWorld("Edit Manifest Playing Reader")
        let book = try world.makeSilentAudioBook(title: "Harbour Soundings", trackDurations: [3, 0.6, 0.6])
        let reader = world.openReader(for: book)
        let files = try await loadedTrackFiles(of: reader, count: 3)
        let service = reader.audioPlaybackService
        defer { reader.stop() }
        let editor = makeEditor()
        defer { editor.editor.endAll() }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        let manifest = try XCTUnwrap(AudioManifestLocation.find(in: book.bookFileURL)).url

        reader.play()
        XCTAssertEqual(service.queuedFilePaths, [files[0], files[1]])
        let player = try XCTUnwrap(service._playerForTesting)
        let generation = reader.chapterPlaybackGeneration
        try save(#"{"pauseBetweenTracksMs": 0, "tracks": ["01.wav", "03.wav", "02.wav"]}"#, to: manifest)
        let heard = await check(with: editor, in: announcements)

        XCTAssertEqual(heard, [BookManifestEditWording.updated])
        XCTAssertTrue(reader.isCurrentlyPlaying, "The edit stopped playback")
        XCTAssertTrue(service._playerForTesting === player, "Playback began again on a new player")
        XCTAssertEqual(reader.chapterPlaybackGeneration, generation, "Playback began again")
        XCTAssertEqual(service.loadedURL.map { resolvedPath($0.path) }, files[0], "Another file plays")
        XCTAssertEqual(reader.content?.chapters.map(\.title), ["01", "03", "02"])
        XCTAssertEqual(service.queuedFilePaths, [files[0], files[2]], "The next track in the new order was not named to follow")

        let wentOn = await eventually(timeout: 10) { reader.currentChapterIndex == 1 }
        XCTAssertTrue(wentOn, "The book did not go on from the first track")
        XCTAssertEqual(service.loadedURL.map { resolvedPath($0.path) }, files[2], "The book went on to the old order's next track")
    }

    /// The chapter files of `reader`'s audiobook once it has loaded, each
    /// as a resolved path, waiting for the load without holding the main
    /// actor, on which it finishes.
    ///
    /// - Throws: when the reader did not load `count` tracks in time, so a
    ///   test never indexes past the tracks it has.
    private func loadedTrackFiles(of reader: ReaderViewModel, count: Int) async throws -> [String] {
        let loaded = await eventually(timeout: 10) { !reader.isLoading && reader.content != nil }
        let files = reader.audioChapterFiles.map(resolvedPath)
        guard loaded, files.count == count else {
            XCTFail("The reader loaded \(files.count) of \(count) tracks")
            throw CancellationError()
        }
        return files
    }

    // MARK: - The Audio Editor Keeps the Manifest (Item 7)

    /// The audio editor's track chooser lists a book's tracks as the reader
    /// arranges them: in the manifest's order, with its titles, by a
    /// manifest inside the folder's one folder too.
    func testTheAudioEditorListsTheTracksAsTheReaderArrangesThem() throws {
        let world = try makeIntegrationWorld("Edit Manifest Editor Tracks")
        let book = try makeRadioBook(in: world, manifestNaming: "b.m4a")

        guard case .tracks(let tracks) = try AudioEditorTracks.of(book) else {
            return XCTFail("The book's tracks were not listed")
        }
        XCTAssertEqual(tracks.map(\.title), ["c", "Bravo", "a"])
        XCTAssertEqual(tracks.map(\.path), ["audio/Radio/c.wav", "audio/Radio/b.m4a", "audio/Radio/a.wav"])
    }

    /// An edited Ogg track, which renders to .m4a under a new name, is
    /// renamed in the manifest wherever the reader finds it, so it keeps its
    /// place, its title, and its group, and the manifest keeps everything
    /// else it said.
    func testAnEditedOggTrackKeepsItsPlaceTitleAndGroup() throws {
        let world = try makeIntegrationWorld("Edit Manifest Editor Rename")
        let book = try makeRadioBook(in: world, manifestNaming: "b.ogg")
        let audio = book.bookFileURL

        try AudioEditBookRender.renameTrack("audio/Radio/b.ogg", to: "audio/Radio/b.m4a", inManifestOf: audio, folderInPackage: "audio", bookID: book.id)

        let found = try XCTUnwrap(AudioManifest.read(inAudioFolder: audio))
        XCTAssertEqual(found.location.prefix, "Radio/")
        XCTAssertEqual(found.manifest.tracks, [
            .heading("Season One"),
            .track(AudioManifestTrack(file: "c.wav")),
            .track(AudioManifestTrack(file: "b.m4a", title: "Bravo", pauseAfterMs: 900)),
            .track(AudioManifestTrack(file: "a.wav"))
        ])
        XCTAssertEqual(found.manifest.title, "Radio Plays")
        let plan = AudioTrackPlan(arranging: try AudioBookParser.trackPaths(in: audio).map(found.location.name(ofTrackAt:)), by: found.manifest)
        XCTAssertEqual(plan.tracks.map(\.name), ["c.wav", "b.m4a", "a.wav"], "The edited track left its place")
        XCTAssertEqual(plan.tracks.map(\.title), ["c", "Bravo", "a"], "The edited track lost its title")
        XCTAssertEqual(plan.tracks.map(\.level), [2, 2, 2], "The edited track left its group")
    }

    /// The JSON rename follows a track everywhere a manifest of the older
    /// keys names it, and in a section's clips.
    func testARenameFollowsTheTrackThroughTheOlderKeysAndSections() {
        var object: [String: Any] = [
            "order": ["b.ogg", "a.wav"],
            "chapters": ["b.ogg": "Bravo"],
            "segments": [["title": "One", "clips": [["file": "b.ogg", "startTime": 0, "endTime": 1]]]]
        ]

        BookManifestFile.renameTrack("b.ogg", to: "b.m4a", in: &object)

        XCTAssertEqual(object["order"] as? [String], ["b.m4a", "a.wav"])
        XCTAssertEqual(object["chapters"] as? [String: String], ["b.m4a": "Bravo"])
        let clips = ((object["segments"] as? [[String: Any]])?.first?["clips"] as? [[String: Any]]) ?? []
        XCTAssertEqual(clips.compactMap { $0["file"] as? String }, ["b.m4a"])
    }

    /// A radio book: silent tracks a.wav, b.m4a, and c.wav in the one
    /// folder Radio of its audio folder, with a manifest there naming the
    /// middle track `middle`, under a group heading, with a title and a
    /// pause of its own; indexed and listed in `world`.
    private func makeRadioBook(in world: IntegrationWorld, manifestNaming middle: String) throws -> Book {
        let packageName = "\(UUID().uuidString).tmb"
        let audio = TextMouthPaths.tmbPath(folderPath: world.folder.path, tmbName: packageName)
            .appendingPathComponent("audio", isDirectory: true)
        let radio = audio.appendingPathComponent("Radio", isDirectory: true)
        try AudioTestFixtures.writeSilence(to: radio.appendingPathComponent("a.wav"), duration: 0.2)
        try AudioTestFixtures.writeAACSilence(to: radio.appendingPathComponent("b.m4a"), duration: 0.2)
        try AudioTestFixtures.writeSilence(to: radio.appendingPathComponent("c.wav"), duration: 0.2)
        let manifest = """
        {"title": "Radio Plays", "tracks": [{"heading": "Season One"}, "c.wav", \
        {"file": "\(middle)", "title": "Bravo", "pauseAfterMs": 900}, "a.wav"]}
        """
        try Data(manifest.utf8).write(to: radio.appendingPathComponent(AudioManifest.fileName))
        let book = Book(
            title: "Radio Plays",
            format: .audio,
            filePath: audio.path,
            md5Hash: UUID().uuidString,
            folderPath: world.folder.path,
            tmbDirectoryName: packageName
        )
        world.library.library.addBook(book)
        return book
    }

    // MARK: - Importing a Folder of Tracks (Part B, Item 8)

    /// A folder of audio tracks without a manifest imports as one
    /// audiobook titled by the folder's name, its tracks copied into the
    /// book's package and played one per heading, in Finder's order; the
    /// folder itself is left as it was, and Open Book's sources keep it whole.
    func testAFolderOfTracksImportsAsOneAudiobook() throws {
        let world = try makeIntegrationWorld("Folder Import Plain")
        let folder = try makeSandboxDirectory("Folder Import Sources").appendingPathComponent("Night Ferries", isDirectory: true)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("Track 10.wav"), duration: 0.2)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("Track 2.wav"), duration: 0.2)
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()

        XCTAssertEqual(LibraryViewModel.importSources(for: folder), [folder])
        let book = try world.importBook(from: folder)

        XCTAssertEqual(book.title, "Night Ferries")
        XCTAssertEqual(book.format, .audio)
        XCTAssertTrue(book.filePath.hasPrefix(book.tmbDirectory.path + "/"), "The tracks were not copied into the package")
        let index = try XCTUnwrap(book.storedBookInfo()?.contentIndex)
        XCTAssertEqual(index.audioLayout, .multiFile)
        XCTAssertEqual(index.allHeadings.map(\.text), ["Track 2", "Track 10"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted(), before, "The folder was changed")
        XCTAssertTrue(BookManifestEditing.hasTrackFolder(book), "The imported book's manifest cannot be edited")
    }

    /// A folder whose tracks and manifest lie in its one folder imports as
    /// a ZIP made by Finder's Compress does: the manifest is found there,
    /// copied with the tracks, and names the book, its author, and its
    /// headings, in its order.
    func testAFolderOfTracksTakesItsManifest() throws {
        let world = try makeIntegrationWorld("Folder Import Manifest")
        let folder = try makeSandboxDirectory("Folder Import Sources").appendingPathComponent("Downloads", isDirectory: true)
        let radio = folder.appendingPathComponent("Radio", isDirectory: true)
        try AudioTestFixtures.writeSilence(to: radio.appendingPathComponent("a.wav"), duration: 0.2)
        try AudioTestFixtures.writeSilence(to: radio.appendingPathComponent("b.wav"), duration: 0.2)
        try Data(#"{"title": "Radio Plays", "author": "Kwame Asante", "tracks": [{"file": "b.wav", "title": "Bravo"}, "a.wav"]}"#.utf8)
            .write(to: radio.appendingPathComponent(AudioManifest.fileName))

        let book = try world.importBook(from: folder)

        XCTAssertEqual(book.title, "Radio Plays")
        XCTAssertEqual(book.author, "Kwame Asante")
        XCTAssertEqual(AudioManifestLocation.find(in: book.bookFileURL)?.prefix, "Radio/", "The manifest was not copied with the tracks")
        XCTAssertEqual(book.storedBookInfo()?.contentIndex?.allHeadings.map(\.text), ["Bravo", "a"])
    }

    /// A folder whose manifest has a mistake is refused at the manifest, in
    /// the words a ZIP's import uses, and nothing is added.
    func testAFolderWhoseManifestHasAMistakeIsRefusedAtItsManifest() throws {
        let world = try makeIntegrationWorld("Folder Import Mistake")
        let folder = try makeSandboxDirectory("Folder Import Sources").appendingPathComponent("Misspelled", isDirectory: true)
        try AudioTestFixtures.writeSilence(to: folder.appendingPathComponent("a.wav"), duration: 0.2)
        try Data(#"{"titel": "Misspelled"}"#.utf8).write(to: folder.appendingPathComponent(AudioManifest.fileName))

        XCTAssertThrowsError(try world.importBook(from: folder)) { error in
            XCTAssertEqual((error as? ImportFailure)?.step, .readingManifest)
            let problem = AudioManifestProblem.unknownKeys(["titel"], entry: nil).errorDescription ?? "no problem"
            XCTAssertTrue(error.localizedDescription.hasSuffix(problem), error.localizedDescription)
        }
        XCTAssertTrue(world.library.library.books.isEmpty)
    }

    /// Import DAISY Folder… is Import Folder… now, and the name it had still
    /// names it, so a key the user gave it keeps working.
    func testImportFolderKeepsTheKeyGivenToImportDAISYFolder() {
        XCTAssertEqual(ShortcutAction.importDAISYFolder.title, "Import Folder…")
        XCTAssertEqual(ShortcutAction.exactlyNamed("Import DAISY Folder…"), .importDAISYFolder)
        XCTAssertEqual(ShortcutAction.named("import daisy folder"), .importDAISYFolder)
        XCTAssertEqual(ShortcutAction.named("Import Folder..."), .importDAISYFolder)
    }
}
