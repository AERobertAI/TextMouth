import XCTest
@testable import TextMouth

/// A book's bookmarks and saved reading position follow the sound when a
/// save of edited audio changes its file (FR04): the route from the file
/// as saved to the audio being saved (`AudioEditorTimeMap.Route`), the
/// places it moves over the book's chapters (`AudioEditPlaces`), and saves
/// through the editor of generated audio, whose places land where the same
/// sound is: before a cut, inside it, after it, inside a moved stretch, and
/// in a stretch trimmed away. No test plays a sound.
@MainActor
final class AudioEditPlacesTests: XCTestCase {

    // MARK: - Routes

    /// A route makes the edits made since the save; one made and undone
    /// leaves no trace, so a time inside a cut put back comes back exactly.
    func testARouteMakesTheNewEditsAndForgetsOnesUndone() {
        let cut = crossing(.cut(AudioTimeRange(start: 4, end: 6)), before: 10, after: 8)
        var route = AudioEditorTimeMap.Route()
        XCTAssertTrue(route.isEmpty)

        route.make(cut)
        XCTAssertEqual(route.map(2), 2, "before the cut")
        XCTAssertEqual(route.map(5), 4, "inside the cut: where it was")
        XCTAssertEqual(route.map(8), 6, "after the cut: earlier by its length")

        XCTAssertTrue(route.undo(cut))
        XCTAssertTrue(route.isEmpty)
        XCTAssertEqual(route.map(5), 5, "the cut undone moves nothing, not even a time inside it")
    }

    /// Undoing an edit the saved file holds crosses it backward, and redoing
    /// it takes that back; a new edit after it is crossed after the undo.
    func testARouteUndoesTheSavedFilesEditsBeforeMakingNewOnes() {
        let saved = crossing(.cut(AudioTimeRange(start: 4, end: 6)), before: 10, after: 8)
        var route = AudioEditorTimeMap.Route()
        XCTAssertTrue(route.undo(saved))
        XCTAssertEqual(route.map(3), 3)
        XCTAssertEqual(route.map(6), 8, "after the cut point, the sound put back comes first")
        route.make(saved)
        XCTAssertTrue(route.isEmpty, "a redo of the saved edit returns to the file")

        XCTAssertTrue(route.undo(saved))
        route.make(crossing(.cut(AudioTimeRange(start: 0, end: 1)), before: 10, after: 9))
        XCTAssertEqual(route.map(6), 7, "back through the saved cut, then on through the new one")
        XCTAssertEqual(route.undone.count, 1)
        XCTAssertEqual(route.made.count, 1)
    }

    /// An undo that isn't the route's newest made edit doesn't fit it.
    func testAnUndoThatDoesntFitIsRefused() {
        var route = AudioEditorTimeMap.Route()
        route.make(crossing(.insertSilence(at: 1, duration: 2), before: 10, after: 12))
        let before = route
        XCTAssertFalse(route.undo(crossing(.cut(AudioTimeRange(start: 0, end: 1)), before: 12, after: 11)))
        XCTAssertEqual(route, before)
    }

    // MARK: - Places Over the Chapters

    /// In a book of one file, a place is a time on the whole file: a cut in
    /// the first chapter moves a bookmark in the second to the same sound,
    /// the same distance into its chapter, which now starts earlier.
    func testPlacesInABookOfOneFileFollowTheSoundAcrossChapters() {
        let route = route(crossing(.cut(AudioTimeRange(start: 5, end: 7)), before: 30, after: 28))
        let before = oneFile([10, 20])
        let after = oneFile([8, 20])

        let inSecond = AudioEditPlaces.move(.init(chapter: 1, offset: 50), along: route, track: nil, from: before, to: after)
        XCTAssertEqual(inSecond, .init(chapter: 1, offset: 50))
        let insideCut = AudioEditPlaces.move(.init(chapter: 0, offset: 60), along: route, track: nil, from: before, to: after)
        XCTAssertEqual(insideCut, .init(chapter: 0, offset: 50))
        let lastOfSecond = AudioEditPlaces.move(.init(chapter: 1, offset: 199), along: route, track: nil, from: before, to: after)
        XCTAssertEqual(lastOfSecond, .init(chapter: 1, offset: 199), "the second chapter starts earlier, but keeps all its sound")
        XCTAssertNil(AudioEditPlaces.move(.init(chapter: 4, offset: 0), along: route, track: nil, from: before, to: after), "a chapter the book never had")
    }

    /// A chapter marker set by the editor divides the same sound anew: a
    /// bookmark after it now counts from it.
    func testANewChapterMarkerDividesThePlacesAfterIt() {
        let route = route(crossing(.setChapter(at: 4, title: "Weir"), before: 10, after: 10))
        let moved = AudioEditPlaces.move(.init(chapter: 0, offset: 70), along: route, track: nil, from: oneFile([10]), to: oneFile([4, 6]))
        XCTAssertEqual(moved, .init(chapter: 1, offset: 30))
    }

    /// In a book of several tracks, only the track saved moves its places,
    /// renamed when its format's extension changed; another track's places
    /// keep their time.
    func testOnlyTheSavedTracksPlacesMoveInABookOfTracks() {
        let route = route(crossing(.cut(AudioTimeRange(start: 0, end: 2)), before: 6, after: 4))
        let before = tracks([("01.mp3", 5), ("02.mp3", 6)])
        let after = tracks([("01.mp3", 5), ("02.m4a", 4)])
        let track = AudioEditPlaces.Track(before: "02.mp3", after: "02.m4a")

        XCTAssertEqual(AudioEditPlaces.move(.init(chapter: 0, offset: 30), along: route, track: track, from: before, to: after), .init(chapter: 0, offset: 30))
        XCTAssertEqual(AudioEditPlaces.move(.init(chapter: 1, offset: 30), along: route, track: track, from: before, to: after), .init(chapter: 1, offset: 10))
        XCTAssertEqual(AudioEditPlaces.move(.init(chapter: 1, offset: 10), along: route, track: track, from: before, to: after), .init(chapter: 1, offset: 0))
        XCTAssertNil(AudioEditPlaces.move(.init(chapter: 1, offset: 10), along: route, track: nil, from: before, to: after), "a book of tracks without the track saved")
    }

    /// Moved bookmarks keep their numbers and notes; a moved position is
    /// dated now, with its offset across the book; one that stays is kept
    /// exactly as it was.
    func testFollowingKeepsBookmarksAndDatesAMovedPosition() throws {
        let route = route(crossing(.trimStart(to: 3), before: 10, after: 7))
        let layoutBefore = oneFile([10])
        let layoutAfter = oneFile([7])
        let bookmark = Bookmark(number: 3, chapterIndex: 0, characterOffset: 50, label: "Lock gates")
        let position = ReadingPosition(chapterIndex: 0, characterOffset: 20, globalCharacterOffset: 20)
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        let moved = AudioEditPlaces.follow(route, bookmarks: [bookmark], position: position, track: nil, from: layoutBefore, to: layoutAfter, at: now)
        let movedBookmark = try XCTUnwrap(moved.bookmarks.first)
        XCTAssertEqual(movedBookmark.characterOffset, 20)
        XCTAssertEqual(movedBookmark.number, 3)
        XCTAssertEqual(movedBookmark.label, "Lock gates")
        XCTAssertEqual(movedBookmark.id, bookmark.id)
        XCTAssertEqual(moved.position?.characterOffset, 0, "a position trimmed away goes to where the trim was")
        XCTAssertEqual(moved.position?.globalCharacterOffset, 0)
        XCTAssertEqual(moved.position?.lastUpdated, now)

        let unmoved = AudioEditPlaces.follow(
            self.route(crossing(.cut(AudioTimeRange(start: 8, end: 9)), before: 10, after: 9)),
            bookmarks: [],
            position: position,
            track: nil,
            from: layoutBefore,
            to: oneFile([9]),
            at: now
        )
        XCTAssertEqual(unmoved.position, position, "a position before the cut stays, dated as it was")
    }

    // MARK: - Saving Through the Editor

    /// Bookmarks before, inside, and after a cut, and the reading position
    /// after it, point at the same sound once the cut is saved; the book's
    /// record holds them so.
    func testBookmarksAroundACutFollowTheSoundWhenSaved() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        let positionBefore = place(in: harness, bookmarksAt: [2, 5, 8], positionAt: 9)
        model.select(AudioTimeRange(start: 4, end: 6))
        await model.cut()

        let saved = await model.save()

        XCTAssertTrue(saved, "\(harness.announcements.sentences)")
        let book = try XCTUnwrap(harness.fixture.library.bookByID(harness.fixture.book.id))
        XCTAssertEqual(offsets(of: book), [20, 40, 60], "before the cut stays; inside it goes to the cut; after it moves back")
        XCTAssertEqual(book.bookmarks.map(\.number), [1, 2, 3])
        XCTAssertEqual(book.readingPosition?.characterOffset, 70)
        XCTAssertEqual(book.readingPosition?.globalCharacterOffset, 70)
        XCTAssertGreaterThan(try XCTUnwrap(book.readingPosition?.lastUpdated), positionBefore)
        LibraryPersistenceService.writePendingBookInfoNow(bookID: book.id)
        let record = try StoredBookRecord.read(from: harness.fixture.package).info
        XCTAssertEqual(record.bookmarks.map(\.characterOffset).sorted(), [20, 40, 60])
        XCTAssertEqual(record.state.readingPosition?.characterOffset, 70)
    }

    /// A bookmark inside a stretch moved by a Paste right after its Cut goes
    /// with it; one the move closes up over follows, and one past it stays.
    func testABookmarkMovesWithAMovedStretch() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        place(in: harness, bookmarksAt: [1.5, 5, 9])
        model.select(AudioTimeRange(start: 1, end: 2))
        await model.cut()
        // 7 seconds into the audio cut is 8 seconds into the audio before it.
        model.move(to: 7)
        await model.paste()
        XCTAssertEqual(model.undoName, "Move 1 Second")

        let saved = await model.save()

        XCTAssertTrue(saved, "\(harness.announcements.sentences)")
        let book = try XCTUnwrap(harness.fixture.library.bookByID(harness.fixture.book.id))
        XCTAssertEqual(offsets(of: book), [75, 40, 90])
    }

    /// The reading position in a stretch Trim to Selection removes goes to
    /// where the stretch was; a bookmark after the selection goes to the
    /// end, and one inside it keeps its sound.
    func testAPositionTrimmedAwayGoesToWhereTheTrimWas() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        place(in: harness, bookmarksAt: [5, 9], positionAt: 1)
        model.select(AudioTimeRange(start: 3, end: 7))
        await model.trimToSelection()

        let saved = await model.save()

        XCTAssertTrue(saved, "\(harness.announcements.sentences)")
        let book = try XCTUnwrap(harness.fixture.library.bookByID(harness.fixture.book.id))
        XCTAssertEqual(book.readingPosition?.characterOffset, 0)
        XCTAssertEqual(offsets(of: book), [20, 39], "the audio is 4 seconds long, 40 characters")
    }

    /// An edit made and undone before a save moves nothing: only the edit
    /// kept moves the bookmarks.
    func testAnEditUndoneBeforeASaveMovesNothing() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        place(in: harness, bookmarksAt: [5, 8])
        model.select(AudioTimeRange(start: 4, end: 6))
        await model.cut()
        await model.undo()
        model.select(AudioTimeRange(start: 0, end: 1))
        await model.cut()

        let saved = await model.save()

        XCTAssertTrue(saved, "\(harness.announcements.sentences)")
        let book = try XCTUnwrap(harness.fixture.library.bookByID(harness.fixture.book.id))
        XCTAssertEqual(offsets(of: book), [40, 70])
    }

    /// A saved cut undone and saved again puts the bookmarks back; another
    /// edit made after undoing it, whose history no longer holds the cut,
    /// moves them back through the cut and on through the new edit.
    func testUndoingASavedEditMovesTheBookmarksBack() async throws {
        let harness = try await openRamp(seconds: 10)
        let model = harness.model
        place(in: harness, bookmarksAt: [8])
        model.select(AudioTimeRange(start: 4, end: 6))
        await model.cut()
        await model.save()
        XCTAssertEqual(offsets(of: try XCTUnwrap(harness.fixture.library.bookByID(harness.fixture.book.id))), [60])

        await model.undo()
        let savedBack = await model.save()
        XCTAssertTrue(savedBack, "\(harness.announcements.sentences)")
        XCTAssertEqual(offsets(of: try XCTUnwrap(harness.fixture.library.bookByID(harness.fixture.book.id))), [80])

        await model.redo()
        await model.save()
        await model.undo()
        model.select(AudioTimeRange(start: 0, end: 1))
        await model.cut()
        XCTAssertNil(model.session.list.renderedCursor, "the history no longer holds what the file does")
        let savedOver = await model.save()
        XCTAssertTrue(savedOver, "\(harness.announcements.sentences)")
        XCTAssertEqual(offsets(of: try XCTUnwrap(harness.fixture.library.bookByID(harness.fixture.book.id))), [70])
    }

    /// Edits left unsaved by a window that never asked, as a crash leaves
    /// them, are still followed by the next window's save; so are saved
    /// edits left undone.
    func testEditsLeftByAnEarlierWindowAreFollowed() async throws {
        let fixture = try AudioEditorTestBook.ramp(seconds: 10, for: self)
        let first = try await EditorHarness.open(fixture, for: self)
        first.model.select(AudioTimeRange(start: 4, end: 6))
        await first.model.cut()
        first.model.windowClosed()

        let second = try await EditorHarness.open(fixture, for: self)
        addTeardownBlock { @MainActor in second.model.windowClosed() }
        XCTAssertEqual(second.model.session.savedFileRoute?.made.count, 1)
        place(in: second, bookmarksAt: [8])
        await second.model.save()
        XCTAssertEqual(offsets(of: try XCTUnwrap(fixture.library.bookByID(fixture.book.id))), [60])
        await second.model.undo()
        second.model.windowClosed()

        let third = try await EditorHarness.open(fixture, for: self)
        addTeardownBlock { @MainActor in third.model.windowClosed() }
        XCTAssertEqual(third.model.session.savedFileRoute?.undone.count, 1)
        await third.model.save()
        XCTAssertEqual(offsets(of: try XCTUnwrap(fixture.library.bookByID(fixture.book.id))), [80])
    }

    /// In a book of two tracks, saving a cut in the second moves only the
    /// second track's bookmark.
    func testOnlyTheEditedTracksBookmarksMove() async throws {
        let fixture = try AudioEditorTestBook.make(named: "audio", for: self) { folder in
            for name in ["a.wav", "b.wav"] {
                try AudioTestFixtures.writeIdentityRamp(
                    to: folder.appendingPathComponent(name),
                    frames: Int(AudioEditorTestBook.rate * 4),
                    sampleRate: AudioEditorTestBook.rate
                )
            }
        }
        let harness = try await EditorHarness.open(fixture, for: self, track: AudioEditorTrack(path: "audio/b.wav", title: "b"))
        addTeardownBlock { @MainActor in harness.model.windowClosed() }
        AudioEditorPreferences.playAfterMoves.write(false, to: harness.store)
        await harness.model.loadPreview()
        let library = fixture.library
        library.library.addBookmark(bookID: fixture.book.id, chapterIndex: 0, characterOffset: 30)
        library.library.addBookmark(bookID: fixture.book.id, chapterIndex: 1, characterOffset: 30)
        harness.model.select(AudioTimeRange(start: 0, end: 1))
        await harness.model.cut()

        let saved = await harness.model.save()

        XCTAssertTrue(saved, "\(harness.announcements.sentences)")
        let book = try XCTUnwrap(library.bookByID(fixture.book.id))
        XCTAssertEqual(book.bookmarks.map(\.chapterIndex), [0, 1])
        XCTAssertEqual(offsets(of: book), [30, 20])
    }

    // MARK: - Helpers

    /// `edit`, made when the audio lasted `before` seconds, leaving it
    /// `after` seconds long, as a fresh entry.
    private func crossing(_ edit: AudioEdit, before: TimeInterval, after: TimeInterval) -> AudioEditorTimeMap.Crossing {
        AudioEditorTimeMap.Crossing(AudioEditEntry(id: UUID(), madeAt: Date(), edit: edit), before: before, after: after)
    }

    /// A route that makes `crossings`, in order.
    private func route(_ crossings: AudioEditorTimeMap.Crossing...) -> AudioEditorTimeMap.Route {
        var route = AudioEditorTimeMap.Route()
        crossings.forEach { route.make($0) }
        return route
    }

    /// The content index of an audiobook of one file whose chapters last
    /// `lengths` seconds each, as the parser lays them out.
    private func oneFile(_ lengths: [TimeInterval]) -> BookContentIndex {
        BookContentIndex.build(fromChapters: chapters(lengths), format: .audio)
    }

    /// The content index of an audiobook of `tracks`, each its name inside
    /// the book's folder and its length in seconds.
    private func tracks(_ tracks: [(name: String, seconds: TimeInterval)]) -> BookContentIndex {
        let folder = URL(fileURLWithPath: "/Volumes/No Such Disk/Ferry Log/audio", isDirectory: true)
        return BookContentIndex.build(
            fromChapters: chapters(tracks.map(\.seconds)),
            format: .audio,
            audioFilePaths: tracks.map { folder.appendingPathComponent($0.name).path },
            audioBaseURL: folder
        )
    }

    /// Placeholder chapters lasting `lengths` seconds each, ten characters a
    /// second, as the audiobook parser makes them.
    private func chapters(_ lengths: [TimeInterval]) -> [Chapter] {
        lengths.enumerated().map { index, length in
            let title = "Chapter \(index + 1)"
            return Chapter(
                title: title,
                text: String(repeating: " ", count: Int((length * ReaderViewModel.audioCharsPerSecond).rounded())),
                headings: [Heading(level: 1, text: title, chapterIndex: index, characterOffset: 0)]
            )
        }
    }

    /// Gives the harness's book, of one file without chapter markers, a
    /// bookmark at each of `seconds`, and a reading position at
    /// `position` seconds when given; returns when the position was dated.
    @discardableResult
    private func place(in harness: EditorHarness, bookmarksAt seconds: [TimeInterval], positionAt position: TimeInterval? = nil) -> Date {
        let library = harness.fixture.library
        let id = harness.fixture.book.id
        for time in seconds {
            library.library.addBookmark(bookID: id, chapterIndex: 0, characterOffset: Int((time * 10).rounded()))
        }
        let reading = ReadingPosition(
            chapterIndex: 0,
            characterOffset: Int(((position ?? 0) * 10).rounded()),
            globalCharacterOffset: Int(((position ?? 0) * 10).rounded())
        )
        if position != nil {
            library.library.updateReadingPosition(bookID: id, position: reading)
        }
        return reading.lastUpdated
    }

    /// The character offsets of `book`'s bookmarks, by their numbers.
    private func offsets(of book: Book) -> [Int] {
        book.bookmarks.sorted { $0.number < $1.number }.map(\.characterOffset)
    }
}
