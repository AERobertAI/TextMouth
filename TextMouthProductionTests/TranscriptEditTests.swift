import XCTest
@testable import TextMouth

/// Editing a transcript (FR05): Edit Text opens a transcribed audiobook's
/// content.md in the user's editor, and an edit saved there is taken into
/// transcript.json itself, laid over its sentences, so the text the loader
/// writes from the transcript is the edit: each sentence keeps its time,
/// one whose text changed drops its words' timings, one deleted is gone,
/// and the transcript is marked edited. An edit that changes the number of
/// chapters is refused and kept; a hand edit the loader writes over is
/// kept first; Retranscribe and Delete Transcript say the edits go.
///
/// Every editor here is the test's own: it opens no app, shows no dialog,
/// and takes TextMouth to be active. Books live in a library folder of the
/// test's own, and no reader speaks.
@MainActor
final class TranscriptEditTests: XCTestCase {

    // MARK: - Laying an Edit over the Sentences

    /// An edit that changes nothing leaves every sentence where it was,
    /// past the chapter's heading.
    func testAnUnchangedTextKeepsEverySentenceWhereItWas() {
        let text = "Harbour\n\nOne two three. Four five."
        let ranges = TranscriptEditAlignment.ranges(
            of: ["One two three.", "Four five."],
            in: text,
            excluding: [NSRange(location: 0, length: 7)]
        )

        XCTAssertEqual(ranges, [NSRange(location: 9, length: 14), NSRange(location: 24, length: 10)])
    }

    /// A word changed stays in its sentence, even the first word of the
    /// next; a sentence deleted whole is gone; words inserted after a
    /// sentence join it, and words before the first join the first; line
    /// and paragraph breaks change nothing.
    func testChangedDeletedAndInsertedWordsGoWhereTheyStand() {
        let sentences = ["The cat sat.", "Dogs bark.", "Gulls cry.", "Boats rock."]
        let text = "Lately, the cat sang.\n\nHounds bark. Boats rock.\nAnd a gull."

        let ranges = TranscriptEditAlignment.ranges(of: sentences, in: text)

        XCTAssertEqual(ranges.map { $0.map { (text as NSString).substring(with: $0) } }, [
            "Lately, the cat sang.",
            "Hounds bark.",
            nil,
            "Boats rock.\nAnd a gull.",
        ])
    }

    /// A sentence deleted between two that read alike leaves its neighbours
    /// whole: sentences found word for word hold the alignment in place, so
    /// a word they share never strays into the deleted one.
    func testASentenceDeletedBetweenLikeSentencesLeavesThemWhole() {
        let sentences = ["Buoy one rolls.", "Buoy two rolls.", "Buoy three rolls."]
        let text = "Buoy one rolls. Buoy three rolls."

        let ranges = TranscriptEditAlignment.ranges(of: sentences, in: text)

        XCTAssertEqual(ranges.map { $0.map { (text as NSString).substring(with: $0) } }, [
            "Buoy one rolls.",
            nil,
            "Buoy three rolls.",
        ])
    }

    /// A passage rewritten whole, with no word in common, still gives every
    /// word to some sentence, in order, none overlapping.
    func testARewrittenPassageSharesItsWordsOutByPosition() {
        let sentences = ["Alpha beta gamma.", "Delta epsilon.", "Zeta eta theta iota."]
        let text = "One two three four five six seven eight nine."

        let ranges = TranscriptEditAlignment.ranges(of: sentences, in: text).compactMap { $0 }

        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges.first?.location, 0)
        XCTAssertEqual(ranges.last.map(NSMaxRange), (text as NSString).length)
        for (earlier, later) in zip(ranges, ranges.dropFirst()) {
            XCTAssertLessThanOrEqual(NSMaxRange(earlier), later.location, "\(ranges)")
        }
    }

    /// Words are matched without their case or the punctuation around
    /// them, so a fixed capital or comma keeps a sentence matched; a word of
    /// nothing but punctuation is matched as it is.
    func testWordsAreMatchedWithoutCaseOrSurroundingPunctuation() {
        XCTAssertEqual(TranscriptEditAlignment.key(of: "Porter."), "porter")
        XCTAssertEqual(TranscriptEditAlignment.key(of: "“Ahoy!”"), "ahoy")
        XCTAssertEqual(TranscriptEditAlignment.key(of: "—"), "—")
        XCTAssertEqual(TranscriptEditAlignment.words(in: "  a  b\n").map(\.range), [
            NSRange(location: 2, length: 1), NSRange(location: 5, length: 1),
        ])
    }

    /// A long chapter with a few edits keeps every untouched sentence
    /// exactly where it is, and the edited ones where their words are.
    func testALongChapterKeepsItsUntouchedSentencesExactly() {
        let sentences = (0..<3_000).map { "Buoy \($0) rolls in the swell." }
        var edited = sentences
        edited[1_200] = "Buoy 1200 rolls hard in the swell."
        edited.remove(at: 2_500)
        let text = edited.joined(separator: " ")

        let ranges = TranscriptEditAlignment.ranges(of: sentences, in: text)

        let nsText = text as NSString
        guard ranges.count == sentences.count else {
            return XCTFail("\(ranges.count) ranges for \(sentences.count) sentences")
        }
        XCTAssertEqual(ranges.first.flatMap { $0 }.map { nsText.substring(with: $0) }, sentences.first)
        XCTAssertEqual(ranges[1_200].map { nsText.substring(with: $0) }, "Buoy 1200 rolls hard in the swell.")
        XCTAssertNil(ranges[2_500])
        XCTAssertEqual(ranges.last.flatMap { $0 }.map { nsText.substring(with: $0) }, sentences.last)
    }

    // MARK: - Taking an Edit into the Transcript

    /// An edit laid over a transcript gives each sentence its edited words,
    /// keeps every sentence's time, drops the timings of words whose
    /// sentence changed, removes a sentence deleted, and marks the
    /// transcript edited; the result passes validation.
    func testAnEditTakesWordsKeepsTimesAndRemovesDeletedSentences() throws {
        let world = try makeIntegrationWorld("Transcript Edit Apply")
        let book = try world.makeSilentAudioBook(title: "Breakwater Notes", trackDurations: [3, 2])
        let transcript = try TranscriptFixtures.transcript(of: book, sentences: TranscriptionUIScripts.twoTracks)
        try TranscriptStore.install(transcript, for: book)
        let original = try String(contentsOf: MarkdownCacheService.cacheURL(for: book), encoding: .utf8)
        let deleted = replacing(" " + MarkdownLiteral.escaped("Rope coils dry on the pier."), with: "", in: original)
        let edited = replacing("The ferry bell", with: "The old ferry bell", in: deleted)
        let chapters = MarkdownCacheService.parseMultiChapterMarkdown(edited, bookTitle: book.title, bookAuthor: book.author).chapters
        var audioIndex = try BookContentAnalysisService.load(book: book).index
        audioIndex.transcript = nil
        let when = TranscriptFixtures.date.addingTimeInterval(86_400)

        let edit = try TranscriptEditing.apply(
            chapters,
            to: transcript,
            over: audioIndex,
            bookFileName: book.bookFileURL.lastPathComponent,
            editedAt: when
        )

        let files = edit.transcript.files
        XCTAssertEqual(files.map { $0.sentences.map(\.text) }, [
            ["Gannet wings fold over the breakwater."],
            ["The old ferry bell rings twice."],
        ])
        XCTAssertEqual(files.first?.sentences.first?.words.count, 6, "an unchanged sentence lost its words")
        XCTAssertEqual(files.last?.sentences.first?.words, [], "a changed sentence kept its words' timings")
        XCTAssertEqual(files.last?.sentences.first?.startMilliseconds, 0)
        XCTAssertEqual(files.last?.sentences.first?.endMilliseconds, 1_920)
        XCTAssertEqual(edit.transcript.editedAt, when)
        XCTAssertNil(edit.transcript.validationFailure())
        XCTAssertEqual(edit.sentences.map(\.count), [1, 1])
        let second = try XCTUnwrap(edit.sentences.last?.first)
        XCTAssertEqual(
            (try XCTUnwrap(chapters.last?.text) as NSString)
                .substring(with: NSRange(location: second.characterOffset, length: second.characterCount)),
            "The old ferry bell rings twice."
        )
        XCTAssertThrowsError(try TranscriptEditing.apply(
            Array(chapters.prefix(1)),
            to: transcript,
            over: audioIndex,
            bookFileName: book.bookFileURL.lastPathComponent,
            editedAt: when
        )) { error in
            XCTAssertEqual(error as? TranscriptEditError, .chaptersChanged(found: 1, expected: 2))
        }
    }

    /// Edit Text opens a transcribed audiobook's text, and a save there is
    /// taken into transcript.json: the reader shows the edit as the book
    /// plays on, content.md stays as the user saved it, the record's layer
    /// is fingerprinted with both files, VoiceOver hears "Text updated",
    /// and the next open reads the edit without writing anything again.
    func testAnEditOfATranscribedAudiobookIsTakenIntoItsTranscript() async throws {
        let world = try makeIntegrationWorld("Transcript Edit Taken")
        let title = "Breakwater Notes \(UUID().uuidString.prefix(8))"
        let book = try world.makeSilentAudioBook(title: title, trackDurations: [3, 2])
        try TranscriptStore.install(try TranscriptFixtures.transcript(of: book, sentences: TranscriptionUIScripts.twoTracks), for: book)
        let reader = world.openReader(for: book)
        let loaded = await eventuallyHolds { !reader.isLoading }
        XCTAssertTrue(loaded, "the reader never loaded")
        let editor = makeEditor()
        defer { editor.editor.endAll() }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        let cache = MarkdownCacheService.cacheURL(for: book)
        let edited = replacing(
            MarkdownLiteral.escaped("on the pier."),
            with: MarkdownLiteral.escaped("on the jetty."),
            in: try String(contentsOf: cache, encoding: .utf8)
        )

        XCTAssertTrue(BookTextEditor.canEditText(of: book, isTranscribed: true))
        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        XCTAssertEqual(editor.recorder.opened.map(\.file), [cache])
        try edited.write(to: cache, atomically: true, encoding: .utf8)
        editor.editor.appBecameActive()

        let shown = await eventuallyHolds { reader.content?.transcript?.chapterText(0)?.contains("jetty") == true }
        XCTAssertTrue(shown, "the reader never showed the edit")
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), edited, "content.md is not as the user saved it")
        guard case .found(let transcript) = TranscriptStore.read(from: book.tmbDirectory) else {
            return XCTFail("the transcript cannot be read")
        }
        XCTAssertEqual(transcript.files.first?.sentences.last?.text, "Rope coils dry on the jetty.")
        XCTAssertEqual(transcript.files.first?.sentences.last?.startMilliseconds, 1_500)
        XCTAssertNotNil(transcript.editedAt)
        let record = try BookInfo.load(from: book.tmbDirectory)
        let layer = try XCTUnwrap(record.contentIndex?.transcript)
        XCTAssertEqual(layer.textCacheFingerprint.source.digest,
                       try FileImportService.md5Hash(of: TextMouthPaths.transcriptPath(in: book.tmbDirectory)))
        XCTAssertEqual(layer.textCacheFingerprint.cache.digest, try FileImportService.md5Hash(of: cache))
        XCTAssertEqual(announcements.messages, [BookTextEditWording.updated])

        let reopened = TranscriptTextLoader.load(for: book, audioIndex: try XCTUnwrap(record.contentIndex))
        XCTAssertFalse(reopened.indexChanged)
        XCTAssertTrue(reopened.text?.chapterText(0)?.contains("jetty") == true, "the next open lost the edit")
        XCTAssertEqual(debugLogLines(containing: "TRANSCRIPT_TEXT_REBUILT: \(title):"), [])
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), edited, "the next open wrote the text again")
    }

    /// An edit that drops a chapter is refused and kept beside content.md,
    /// saying why; the transcript is as it was, and a reader opening the
    /// book plays its audio without the text rather than writing the text
    /// again over the edit.
    func testAnEditChangingTheChaptersIsRefusedAndKept() async throws {
        let world = try makeIntegrationWorld("Transcript Edit Chapters")
        let book = try world.makeSilentAudioBook(title: "Breakwater Notes", trackDurations: [3, 2])
        let transcript = try TranscriptFixtures.transcript(of: book, sentences: TranscriptionUIScripts.twoTracks)
        try TranscriptStore.install(transcript, for: book)
        let editor = makeEditor(sessions: .shared)
        defer { editor.editor.endAll() }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        let cache = MarkdownCacheService.cacheURL(for: book)
        let original = try String(contentsOf: cache, encoding: .utf8)
        let merged = original.replacingOccurrences(of: MarkdownCacheService.chapterMarker(title: "02") + "\n", with: "")
        XCTAssertNotEqual(merged, original, "the fixture's chapter marker was not found")

        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)
        try merged.write(to: cache, atomically: true, encoding: .utf8)
        let heard = await check(book, with: editor, in: announcements)

        let kept = try XCTUnwrap(keptCopies(of: book).first, "the refused edit was not kept")
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), merged)
        XCTAssertEqual(heard, [BookTextEditWording.notTaken(
            .chaptersChanged(found: 1, expected: 2),
            bookTitle: book.title,
            keptCopy: kept
        )])
        XCTAssertTrue(heard.first?.contains("has 1 chapter, but the audiobook has 2 chapters") == true, "\(heard)")
        XCTAssertEqual(TranscriptStore.read(from: book.tmbDirectory), .found(transcript))

        let loaded = try ReaderViewModel.readContent(of: book, readingTexts: nil)
        XCTAssertNil(loaded.content.transcript, "the text was shown over an edit not taken")
        XCTAssertEqual(loaded.content.chapters.count, 2, "the audio did not load")
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), merged, "the text was written again over the edit")
    }

    /// A content.md the user changed without the edit being taken is kept
    /// beside it before the loader writes the text again from the
    /// transcript, so nothing they saved is lost.
    func testTheLoaderKeepsTextTheUserSavedBeforeWritingItAgain() throws {
        let world = try makeIntegrationWorld("Transcript Edit Kept")
        let book = try world.makeSilentAudioBook(title: "Breakwater Notes", trackDurations: [3, 2])
        try TranscriptStore.install(try TranscriptFixtures.transcript(of: book, sentences: TranscriptionUIScripts.twoTracks), for: book)
        let cache = MarkdownCacheService.cacheURL(for: book)
        let generated = try String(contentsOf: cache, encoding: .utf8)
        let handEdit = generated + "\n\nA note added by hand."
        try handEdit.write(to: cache, atomically: true, encoding: .utf8)

        let load = TranscriptTextLoader.load(for: book, audioIndex: try XCTUnwrap(BookInfo.load(from: book.tmbDirectory).contentIndex))

        XCTAssertNotNil(load.text)
        XCTAssertEqual(try String(contentsOf: cache, encoding: .utf8), generated)
        let kept = try XCTUnwrap(keptCopies(of: book).first, "the hand edit was not kept")
        XCTAssertEqual(try String(contentsOf: kept, encoding: .utf8), handEdit)

        // Writing the same text again keeps nothing more.
        try TranscriptStore.install(try TranscriptFixtures.transcript(of: book, sentences: TranscriptionUIScripts.twoTracks), for: book)
        XCTAssertEqual(keptCopies(of: book), [kept])
    }

    // MARK: - What Goes with an Edited Transcript

    /// The Transcribe Audio sheet of a book whose transcript the user
    /// edited says that transcribing again replaces the edits, beside
    /// Retranscribe.
    func testTranscribeAgainSaysItReplacesTheUsersEdits() async {
        var transcript = TranscriptFixtures.transcript([(path: "01.mp3", duration: 1_000, sentences: [])])
        let when = TranscriptFixtures.date.addingTimeInterval(86_400)
        transcript.editedAt = when
        let model = TranscriptionSheetModel(
            request: .book(TranscriptionSheetTests.audiobook("Harbour Bells")),
            library: nil,
            services: makeSheetServices(transcript: .found(transcript))
        )

        await model.load()

        let warning = "You edited this transcript on \(TranscriptionWording.day(when)). Transcribing again replaces your edits."
        XCTAssertEqual(model.editedLine, warning)
        XCTAssertTrue(model.noticeLines.contains(warning))
        XCTAssertTrue(model.readyLines.contains(warning), "VoiceOver does not hear the warning")
        XCTAssertEqual(model.transcribeTitle, "Retranscribe")
    }

    /// Deleting an edited transcript says the edits go too.
    func testDeletingAnEditedTranscriptSaysTheEditsGoToo() async throws {
        let world = try makeIntegrationWorld("Transcript Edit Deletion")
        let book = try world.makeSilentAudioBook(title: "Breakwater Notes", trackDurations: [3, 2])
        var transcript = try TranscriptFixtures.transcript(of: book, sentences: TranscriptionUIScripts.twoTracks)
        transcript.editedAt = TranscriptFixtures.date
        let presenter = TranscriptionPresenter(services: { self.makeSheetServices(transcript: .found(transcript)) })

        await presenter.confirmDeletion(of: book, library: world.library, window: nil)

        XCTAssertEqual(presenter.deletion?.isEdited, true)
    }

    /// An audiobook without a transcript still has no text to edit: Edit
    /// Text says so, and opens nothing.
    func testAnAudiobookWithoutATranscriptHasNoTextToEdit() async throws {
        let world = try makeIntegrationWorld("Transcript Edit None")
        let book = try world.makeSilentAudioBook(title: "Breakwater Notes", trackDurations: [3, 2])
        let editor = makeEditor()
        defer { editor.editor.endAll() }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }

        await editor.editor.edit(book, choosingApp: false, in: world.library, from: nil)

        XCTAssertEqual(announcements.messages, [BookTextEditWording.noText(bookTitle: book.title)])
        XCTAssertEqual(editor.recorder.opened.count, 0)
        XCTAssertFalse(BookTextEditor.canEditText(of: book, isTranscribed: false))
        XCTAssertEqual(
            BookTextEditWording.noText(bookTitle: "Moby-Dick"),
            "Moby-Dick is an audiobook without a transcript, so it has no text to edit. Transcribe it first, with Transcribe Audio."
        )
    }

    // MARK: - A Feed Episode's Transcript

    /// A feed episode's transcript can be edited (October 23, 2026): two
    /// saves in one session are both taken into the transcript in the
    /// episode's package in its feed's folder, and VoiceOver hears where the
    /// transcript stays after the first save only.
    func testAnEditOfAFeedEpisodesTranscriptIsTakenAndSaysWhereItStays() async throws {
        let world = try makeIntegrationWorld("Transcript Edit Feed Episode")
        let episode = try makeFeedEpisode(in: world, title: "Breakwater Notes \(UUID().uuidString.prefix(8))")
        try TranscriptStore.install(try TranscriptFixtures.transcript(of: episode, sentences: TranscriptionUIScripts.twoTracks), for: episode)
        let reader = world.openReader(for: episode)
        let loaded = await eventuallyHolds { !reader.isLoading }
        XCTAssertTrue(loaded, "the reader never loaded")
        let editor = makeEditor()
        defer { editor.editor.endAll() }
        let announcements = AnnouncementCapture()
        defer { announcements.stop() }
        let cache = MarkdownCacheService.cacheURL(for: episode)
        XCTAssertTrue(episode.isFeedItem)
        XCTAssertTrue(BookTextEditor.canEditText(of: episode, isTranscribed: true))

        // The first save: the jetty replaces the pier, and the note is heard.
        await editor.editor.edit(episode, choosingApp: false, in: world.library, from: nil)
        let first = replacing(
            MarkdownLiteral.escaped("on the pier."),
            with: MarkdownLiteral.escaped("on the jetty."),
            in: try String(contentsOf: cache, encoding: .utf8)
        )
        try first.write(to: cache, atomically: true, encoding: .utf8)
        let heardFirst = await check(episode, with: editor, in: announcements)

        // The second save, in the same session: only "Text updated".
        let second = replacing(
            MarkdownLiteral.escaped("on the jetty."),
            with: MarkdownLiteral.escaped("on the quay."),
            in: first
        )
        try second.write(to: cache, atomically: true, encoding: .utf8)
        let heardSecond = await check(episode, with: editor, in: announcements)

        XCTAssertEqual(heardFirst + heardSecond, [BookTextEditWording.updatedInFeed, BookTextEditWording.updated])
        guard case .found(let transcript) = TranscriptStore.read(from: episode.tmbDirectory) else {
            return XCTFail("the transcript cannot be read")
        }
        XCTAssertEqual(transcript.files.first?.sentences.last?.text, "Rope coils dry on the quay.")
        XCTAssertNotNil(transcript.editedAt)
        XCTAssertTrue(episode.tmbDirectory.path.contains(FeedPaths.itemsFolder(of: try XCTUnwrap(episode.feedLink).feedID, in: TextMouthPaths.root).path))
    }

    /// The new sentences are exactly these: the note a feed episode's
    /// transcript carries, and the announcement of the first edit taken.
    func testTheFeedEpisodeTranscriptWordingIsPinned() {
        let note = "This episode's transcript, with your changes, stays with the episode in its feed, "
            + "even after its download is deleted. Deleting the episode or the feed deletes it; "
            + "Move to Library keeps it with the episode as a book."
        XCTAssertEqual(TranscriptionWording.feedEpisodeTranscriptNote, note)
        XCTAssertEqual(BookTextEditWording.updatedInFeed, "Text updated. " + note)
        XCTAssertEqual(BookTextEditWording.updated, "Text updated")
    }

    // MARK: - Fixtures

    /// An editor of the test's own and what it was asked to do.
    private struct TranscriptEditor {
        let editor: BookTextEditor
        let recorder: EditorRecorder
        let sessions: BookTextEditSessions
    }

    /// A silent two-track audiobook of the world's library turned into an
    /// episode in a feed of its own: its package moved into the feed's
    /// folder in the (sandboxed) data directory, and its row given a feed
    /// link, as a downloaded episode's is. The feed's folder is removed when
    /// the test ends.
    private func makeFeedEpisode(in world: IntegrationWorld, title: String) throws -> Book {
        var book = try world.makeSilentAudioBook(title: title, trackDurations: [3, 2])
        let link = FeedBookLink(feedID: UUID(), itemID: "guid:\(UUID().uuidString)")
        let itemsFolder = FeedPaths.itemsFolder(of: link.feedID, in: TextMouthPaths.root)
        addTeardownBlock { try? FileManager.default.removeItem(at: itemsFolder) }
        let oldPackage = book.tmbDirectory
        book.feedLink = link
        try FileManager.default.createDirectory(at: itemsFolder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: oldPackage, to: book.tmbDirectory)
        // The audiobook's tracks moved with its package.
        book.filePath = book.tmbDirectory.appendingPathComponent("Tracks", isDirectory: true).path
        let index = try XCTUnwrap(world.library.library.books.firstIndex { $0.id == book.id })
        world.library.library.books[index] = book
        return book
    }

    /// An editor whose explanation, app chooser, and opener are a
    /// recorder's, remembering its explanation in a sandboxed store, with
    /// sessions of its own dropping reading texts from a sandbox folder, or
    /// `sessions` when given (the app's, for a reader to settle an edit).
    private func makeEditor(sessions given: BookTextEditSessions? = nil) -> TranscriptEditor {
        let recorder = EditorRecorder()
        let readingTexts = ReadingTextCache(
            folder: HostedTestSandbox.home.appendingPathComponent("Transcript Edit Reading Texts \(UUID().uuidString)")
        )
        let sessions = given ?? BookTextEditSessions(readingTexts: readingTexts)
        let editor = BookTextEditor(
            sessions: sessions,
            preferences: makeSandboxedPreferences("Transcript Edit"),
            notificationCenter: NotificationCenter(),
            explain: { title, _ in recorder.explain(title) },
            chooseApp: { title, _ in recorder.chooseApp(title) },
            open: { file, app in try recorder.open(file, app) },
            isAppActive: { true }
        )
        return TranscriptEditor(editor: editor, recorder: recorder, sessions: sessions)
    }

    /// Checks `book` through `editor` as TextMouth becoming active does, and
    /// returns what VoiceOver heard since, waiting a moment for it.
    private func check(_ book: Book, with editor: TranscriptEditor, in announcements: AnnouncementCapture) async -> [String] {
        let before = announcements.messages.count
        editor.editor.appBecameActive()
        // The check runs on the sessions' queue; a check queued after it
        // returns once it has run, and its report reaches the main actor.
        await withCheckedContinuation { continuation in
            editor.sessions.queue.async { continuation.resume() }
        }
        _ = await eventuallyHolds(timeout: 2) { announcements.messages.count > before }
        return Array(announcements.messages.dropFirst(before))
    }

    /// `text` with `target` replaced by `replacement`, failing the test
    /// when `target` is not in it: content.md writes every sentence with
    /// its punctuation escaped, so an edit written against the plain text
    /// would otherwise change nothing and test nothing.
    private func replacing(
        _ target: String,
        with replacement: String,
        in text: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> String {
        XCTAssertTrue(text.contains(target), "content.md does not hold \"\(target)\"", file: file, line: line)
        return text.replacingOccurrences(of: target, with: replacement)
    }

    /// The copies of the user's text kept beside `book`'s content.md,
    /// oldest first.
    private func keptCopies(of book: Book) -> [URL] {
        LibraryIndexQuarantine.existingCopies(
            of: MarkdownCacheService.cacheURL(for: book),
            marker: TextMouthPaths.keptTextCopyMarker
        )
    }
}
