import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import TextMouth

/// A synthesizer that records what it is told and plays nothing, standing
/// in for the app's in every test of Speak Info.
final class InfoSynthesizerRecorder: LibraryInfoSynthesizing {
    var delegate: (any AVSpeechSynthesizerDelegate)?
    /// Every utterance it was told to speak, in order.
    private(set) var utterances: [AVSpeechUtterance] = []
    /// How many times it was told to stop.
    private(set) var stops = 0

    func speak(_ utterance: AVSpeechUtterance) {
        utterances.append(utterance)
    }

    func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stops += 1
        return true
    }

    /// The texts it was told to speak, in order.
    var spoken: [String] {
        utterances.map(\.speechString)
    }
}

/// Speak Info's speaker (October 7, 2026): the brief summary on the first
/// press, the full one on a quick second press, a stop on a press while it
/// speaks, with the app's own voice and speed, through a recorder, so no
/// test plays sound; and the Library window's part: which row is spoken,
/// the facts gathered for it, and the I key and Command-I in a hosted
/// window.
@MainActor
final class LibraryInfoSpeakerTests: XCTestCase {

    // MARK: - Fixtures

    /// A moment presses are timed from.
    private let start = Date(timeIntervalSince1970: 1_791_000_000)

    /// A folder's facts, whose summaries differ between brief and full.
    private let classics = LibraryInfoSubject.folder(
        FolderInfoFacts(name: "Classics", bookCount: 2, unopenedCount: 1, feedCount: 0, subfolderCount: 1, timeRemaining: 120)
    )

    /// A speaker speaking through a recorder.
    private func makeSpeaker() -> (speaker: LibraryInfoSpeaker, recorder: InfoSynthesizerRecorder) {
        let recorder = InfoSynthesizerRecorder()
        return (LibraryInfoSpeaker(synthesizer: recorder), recorder)
    }

    // MARK: - Pressing

    /// The first press speaks the brief summary with the chosen voice at the
    /// chosen speed, never VoiceOver's, and the speaker knows it speaks.
    func testTheFirstPressSpeaksTheBriefSummaryWithTheChosenVoiceAndSpeed() throws {
        let (speaker, recorder) = makeSpeaker()
        let voice = AVSpeechSynthesisVoice.speechVoices().first
        var asked: [Bool] = []

        let text = speaker.press(voice: voice, wordsPerMinute: 250, now: start) { full in
            asked.append(full)
            return classics
        }

        XCTAssertEqual(text, LibraryInfoWording.brief(classics))
        XCTAssertEqual(text, "Classics. Folder. 2 books, 1 unopened.")
        XCTAssertEqual(recorder.spoken, [text])
        XCTAssertEqual(asked, [false])
        XCTAssertTrue(speaker.isSpeaking)
        XCTAssertEqual(speaker.lastSpokenText, text)
        let utterance = try XCTUnwrap(recorder.utterances.first)
        XCTAssertEqual(utterance.rate, SpeechService.rateForWPM(250))
        XCTAssertFalse(utterance.prefersAssistiveTechnologySettings)
        XCTAssertEqual(utterance.voice?.identifier, voice?.identifier)
        XCTAssertNotNil(recorder.delegate, "nothing tells the speaker when the announcement ends")
    }

    /// A second press within three seconds of the first speaks the full
    /// summary, and a press three seconds or more after the last one that
    /// started an announcement is brief again, at the boundary Where Am I
    /// keeps.
    func testASecondPressWithinThreeSecondsSpeaksTheFullSummary() {
        let (speaker, recorder) = makeSpeaker()
        var asked: [Bool] = []
        func press(after seconds: TimeInterval) -> String? {
            speaker.press(voice: nil, wordsPerMinute: 200, now: start.addingTimeInterval(seconds)) { full in
                asked.append(full)
                return classics
            }
        }

        XCTAssertEqual(press(after: 0), LibraryInfoWording.brief(classics))
        speaker.announcementFinished()
        XCTAssertFalse(speaker.isSpeaking)
        let full = press(after: 2)
        XCTAssertEqual(full, LibraryInfoWording.full(classics, now: start.addingTimeInterval(2)))
        XCTAssertEqual(full, "Classics. Folder. 2 books, 1 unopened. 1 subfolder. 2 minutes remaining in total.")
        speaker.announcementFinished()
        // Three seconds after the press that started the full summary.
        XCTAssertEqual(press(after: 5), LibraryInfoWording.brief(classics))
        XCTAssertEqual(asked, [false, true, false])
        XCTAssertEqual(recorder.spoken.count, 3)
    }

    /// A press while an announcement speaks stops it, speaks nothing, and
    /// asks for no subject; a stop while nothing speaks does nothing.
    func testAPressWhileSpeakingStopsTheAnnouncement() {
        let (speaker, recorder) = makeSpeaker()
        speaker.stop()
        XCTAssertEqual(recorder.stops, 0)

        speaker.press(voice: nil, wordsPerMinute: 200, now: start) { _ in classics }
        let stopsBefore = recorder.stops
        var asked = 0
        let text = speaker.press(voice: nil, wordsPerMinute: 200, now: start.addingTimeInterval(1)) { _ in
            asked += 1
            return classics
        }

        XCTAssertNil(text)
        XCTAssertEqual(asked, 0)
        XCTAssertFalse(speaker.isSpeaking)
        XCTAssertEqual(recorder.stops, stopsBefore + 1)
        XCTAssertEqual(recorder.spoken.count, 1)
    }

    /// The escalation window counts from the press that started the brief
    /// summary, as Where Am I's does: a quick third press after a stop
    /// speaks the full summary, and a later one the brief.
    func testAQuickThirdPressAfterAStopSpeaksTheFullSummary() {
        let (speaker, _) = makeSpeaker()
        func press(after seconds: TimeInterval) -> String? {
            speaker.press(voice: nil, wordsPerMinute: 200, now: start.addingTimeInterval(seconds)) { _ in classics }
        }

        XCTAssertEqual(press(after: 0), LibraryInfoWording.brief(classics))
        XCTAssertNil(press(after: 1), "the second press should have stopped the announcement")
        XCTAssertEqual(press(after: 2), LibraryInfoWording.full(classics, now: start.addingTimeInterval(2)))
        XCTAssertNil(press(after: 2.5))
        XCTAssertEqual(press(after: 6), LibraryInfoWording.brief(classics))
    }

    /// With nothing selected, every press says so, the quick second one
    /// included.
    func testNothingSelectedIsSaidOnEveryPress() {
        let (speaker, recorder) = makeSpeaker()

        XCTAssertEqual(speaker.press(voice: nil, wordsPerMinute: 200, now: start) { _ in nil }, "Nothing is selected.")
        speaker.announcementFinished()
        XCTAssertEqual(speaker.press(voice: nil, wordsPerMinute: 200, now: start.addingTimeInterval(1)) { _ in nil }, "Nothing is selected.")
        XCTAssertEqual(recorder.spoken, ["Nothing is selected.", "Nothing is selected."])
    }

    /// The synthesizer's delegate ends the announcement at once on the main
    /// thread, so the next press speaks instead of stopping.
    func testTheSynthesizersDelegateEndsTheAnnouncement() throws {
        let (speaker, recorder) = makeSpeaker()
        speaker.press(voice: nil, wordsPerMinute: 200, now: start) { _ in classics }
        let utterance = try XCTUnwrap(recorder.utterances.first)
        let delegate = try XCTUnwrap(recorder.delegate)

        // The speaker's delegate is told as the synthesizer tells it, by a
        // synthesizer that speaks nothing here.
        delegate.speechSynthesizer?(AVSpeechSynthesizer(), didFinish: utterance)

        XCTAssertFalse(speaker.isSpeaking, "the announcement never ended")
        XCTAssertEqual(speaker.press(voice: nil, wordsPerMinute: 200, now: start.addingTimeInterval(10)) { _ in classics }, LibraryInfoWording.brief(classics))
    }

    // MARK: - Shared With Where Am I

    /// The escalation interval is Where Am I's, and the text of a press is
    /// the wording's.
    func testTheEscalationIntervalAndTextAreSharedWithWhereAmI() {
        XCTAssertEqual(LibraryInfoSpeaker.escalationInterval, ReaderViewModel.whereAmIEscalationInterval)
        XCTAssertEqual(LibraryInfoSpeaker.escalationInterval, 3)
        XCTAssertEqual(LibraryInfoSpeaker.text(for: nil, full: true, now: start), LibraryInfoWording.nothingSelected)
        XCTAssertEqual(LibraryInfoSpeaker.text(for: classics, full: false, now: start), LibraryInfoWording.brief(classics))
        XCTAssertEqual(LibraryInfoSpeaker.text(for: classics, full: true, now: start), LibraryInfoWording.full(classics, now: start))
    }

    /// The app's own synthesizer is what a speaker made without one speaks
    /// through; made here, it speaks nothing.
    func testTheAppsSynthesizerIsTheDefault() {
        let synthesizer = LibraryInfoSpeaker.makeSynthesizer()
        XCTAssertTrue(synthesizer is AVSpeechSynthesizer)
        XCTAssertNil(synthesizer.delegate)
    }

    // MARK: - The Selected Row

    /// The row the window's commands act on is the first selected row in
    /// the list's order, a folder's or a feed's as a book's; the edit
    /// selection's first book when the List selects none of the rows shown;
    /// nothing otherwise.
    func testTheSelectedRowIsTheFirstInListOrderOrTheEditSelectionsFirstBook() {
        let folders = [BookFolder(name: "Classics"), BookFolder(name: "History")]
        let feed = FeedRowContent(
            id: UUID(),
            title: "Planet Money",
            folderPath: "Podcasts/Planet Money",
            counts: FeedItemCounts(),
            check: FeedWording.Check(visible: "Not checked yet", spoken: "not checked yet", failed: false)
        )
        let books = [
            Book(title: "First", format: .txt, filePath: "/nonexistent/first.txt", md5Hash: "first"),
            Book(title: "Second", format: .txt, filePath: "/nonexistent/second.txt", md5Hash: "second"),
        ]
        func selected(_ ids: Set<UUID>, edit: Set<UUID> = []) -> LibraryInfoRow? {
            LibraryInfoRow.selected(ids, editSelection: edit, folders: folders, feeds: [feed], books: books)
        }

        XCTAssertEqual(selected([books[1].id]), .book(books[1]))
        XCTAssertEqual(selected([books[0].id, books[1].id]), .book(books[0]))
        XCTAssertEqual(selected([folders[1].id, books[0].id]), .folder(folders[1]))
        XCTAssertEqual(selected([feed.id, books[0].id]), .feed(feed))
        XCTAssertEqual(selected([folders[0].id, feed.id]), .folder(folders[0]))
        XCTAssertEqual(selected([], edit: [books[1].id]), .book(books[1]))
        XCTAssertEqual(selected([UUID()], edit: [books[1].id]), .book(books[1]))
        XCTAssertNil(selected([UUID()]))
        XCTAssertNil(selected([]))
    }

    // MARK: - A Book's Facts

    /// A book's facts are its row's: the progress and time left from its
    /// reader's live position when that is newer, the cloud note and the
    /// kept note in a cloud library and neither on this Mac, whether a
    /// reader has it open, and its file size, measured only for the full
    /// summary and never for a book in the cloud.
    func testABooksFactsAreItsRowsAndTheFileSizeIsMeasuredOnlyForTheFullSummary() throws {
        let sandbox = try makeSandboxDirectory("SpeakInfoBookFacts")
        let file = sandbox.appendingPathComponent("Middlemarch.txt")
        try Data(repeating: 0x61, count: 4_096).write(to: file)
        let added = Date(timeIntervalSince1970: 1_790_000_000)
        let book = Book(
            title: "Middlemarch",
            author: "George Eliot",
            format: .txt,
            filePath: file.path,
            md5Hash: "middlemarch",
            folderPath: "Classics",
            dateAdded: added,
            lastOpened: added.addingTimeInterval(3_600),
            readingPosition: ReadingPosition(chapterIndex: 0, characterOffset: 50_000),
            bookmarks: [Bookmark(number: 1, chapterIndex: 0, characterOffset: 10), Bookmark(number: 2, chapterIndex: 0, characterOffset: 20)],
            totalWordCount: 80_000,
            totalCharacterCount: 200_000
        )
        let library = LibraryViewModel(initializeServices: false)
        library.library = Library(books: [book], folders: [BookFolder(name: "Classics")])
        library.openBookIDs = [book.id]
        let kept = KeptBooks(file: nil)
        kept.keep([book.id])
        func facts(_ book: Book, cloud: BookCloudStates, full: Bool) -> BookInfoFacts {
            BookInfoFacts(book, library: library, wordsPerMinute: 200, cloudStates: cloud, keptBooks: kept, measuresFileSize: full)
        }

        // On this Mac: no cloud note, and kept says nothing.
        let local = BookCloudStates()
        XCTAssertEqual(facts(book, cloud: local, full: true), BookInfoFacts(
            title: "Middlemarch",
            author: "George Eliot",
            format: "Plain Text",
            folderPath: "Classics",
            progress: "25 percent",
            timeRemaining: book.estimatedTimeRemaining(wpm: 200),
            isUnopened: false,
            dateAdded: added,
            lastOpened: book.lastOpened,
            bookmarkCount: 2,
            fileSize: 4_096,
            cloudNote: nil,
            isKeptOnThisMac: false,
            isOpenInWindow: true
        ))
        XCTAssertEqual(facts(book, cloud: local, full: true).progress, BookRow.spokenProgress(for: book, besideDownloadPercentage: false))
        XCTAssertNil(facts(book, cloud: local, full: false).fileSize, "the brief summary measured the file")

        // The reader's live position, newer than the row's, is the row's.
        library.livePositions.update(ReadingPosition(chapterIndex: 0, characterOffset: 100_000), of: book)
        let live = facts(book, cloud: local, full: false)
        XCTAssertEqual(live.progress, "50 percent")
        XCTAssertEqual(live.timeRemaining, library.livePositions.applied(to: book).estimatedTimeRemaining(wpm: 200))

        // In a cloud library: the note, the kept note, and no measured size
        // for a book in the cloud, which must never be downloaded for it.
        let cloud = BookCloudStates()
        cloud.setLibraryLocation(.cloud(.iCloudDrive))
        cloud.record(.inCloud, for: book.id)
        let inCloud = facts(book, cloud: cloud, full: true)
        XCTAssertEqual(inCloud.cloudNote, "In Cloud")
        XCTAssertTrue(inCloud.isKeptOnThisMac)
        XCTAssertNil(inCloud.fileSize)
        cloud.record(.downloaded, for: book.id)
        XCTAssertEqual(facts(book, cloud: cloud, full: true).fileSize, 4_096)
        XCTAssertEqual(facts(book, cloud: cloud, full: true).cloudNote, "Downloaded")

        // A book never opened, with no position and no file to measure.
        let draft = facts(Book(title: "Draft", format: .txt, filePath: "/nonexistent/draft.txt", md5Hash: "draft"), cloud: local, full: true)
        XCTAssertTrue(draft.isUnopened)
        XCTAssertNil(draft.progress)
        XCTAssertNil(draft.timeRemaining)
        XCTAssertNil(draft.fileSize)
        XCTAssertEqual(draft.author, Book.unknownAuthor)
        XCTAssertFalse(draft.isOpenInWindow)
        XCTAssertEqual(draft.bookmarkCount, 0)
    }

    // MARK: - A Folder's and a Feed's Facts

    /// A folder's facts count the books in it and below it with the
    /// unopened ones, the feeds inside it, its own subfolders, and the time
    /// left in all its books; a feed's folder is its feed, with its
    /// address, as a feed's row is; and a feed's row whose feed is gone
    /// keeps the row's facts without an address.
    func testAFoldersFactsCountItsTreeAndAFeedsFolderIsItsFeed() async throws {
        let world = try FeedTestWorld(self, label: "SpeakInfoFolderFacts")
        let base = world.bookFolder.fullPath
        let feed = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", into: base)
        let feedFolderPath = try XCTUnwrap(world.library.feedFolderPath(forFolderID: feed.folderID))
        try world.library.createFolderReturningFolder(name: "Shelf", parentPath: base)
        /// A book at `path`, opened a sixth of the way through when `opened`.
        func book(_ title: String, in path: String, opened: Bool) -> Book {
            Book(
                title: title,
                format: .txt,
                filePath: "/nonexistent/\(title).txt",
                md5Hash: title,
                folderPath: path,
                lastOpened: opened ? Date() : nil,
                readingPosition: opened ? ReadingPosition(chapterIndex: 0, characterOffset: 1_000) : nil,
                totalWordCount: 1_000,
                totalCharacterCount: 6_000
            )
        }
        world.library.library.books += [
            book("Read", in: base, opened: true),
            book("Unread", in: base, opened: false),
            book("Shelved", in: "\(base)/Shelf", opened: true),
            book("Elsewhere", in: "", opened: true),
        ]
        let feedFolders = LibraryFeedFolders(center: world.center)
        let now = Date()
        let cloud = BookCloudStates()
        let kept = KeptBooks(file: nil)
        func subject(_ row: LibraryInfoRow) -> LibraryInfoSubject {
            LibraryInfoSubject(row, library: world.library, feedFolders: feedFolders, wordsPerMinute: 200, cloudStates: cloud, keptBooks: kept, measuresFileSize: false, now: now)
        }

        // The folder: its tree's books, feeds, its own subfolders, and the
        // time left: two books of 300 seconds opened a sixth of the way
        // through, and the unopened one, measured, whole.
        let folder = FolderInfoFacts(world.bookFolder, library: world.library, feedFolders: feedFolders, wordsPerMinute: 200)
        XCTAssertEqual(folder.name, world.bookFolder.name)
        XCTAssertEqual(folder.bookCount, 3)
        XCTAssertEqual(folder.unopenedCount, 1)
        XCTAssertEqual(folder.feedCount, 1)
        XCTAssertEqual(folder.subfolderCount, 2)
        XCTAssertEqual(folder.timeRemaining ?? 0, 800, accuracy: 0.001)
        XCTAssertEqual(subject(.folder(world.bookFolder)), .folder(folder))
        let empty = FolderInfoFacts(BookFolder(name: "Empty"), library: world.library, feedFolders: feedFolders, wordsPerMinute: 200)
        XCTAssertEqual(empty, FolderInfoFacts(name: "Empty", bookCount: 0, unopenedCount: 0, feedCount: 0, subfolderCount: 0, timeRemaining: nil))

        // The feed's folder is its feed, as its row in the Feeds section is.
        let feedFolder = try XCTUnwrap(world.library.library.folders.first { $0.id == feed.folderID })
        let atlas = try XCTUnwrap(FeedInfoFacts.of(feedID: feed.id, center: world.center, now: now))
        XCTAssertEqual(atlas.title, "The Tactile Atlas")
        XCTAssertEqual(atlas.address, world.server.url("/atlas.xml").absoluteString)
        XCTAssertEqual(atlas.folderPath, feedFolderPath)
        XCTAssertEqual(atlas.counts, world.center.counts(of: feed.id))
        XCTAssertEqual(atlas.counts.listed, 1)
        XCTAssertEqual(atlas.check, world.center.checkWording(of: feed.id, now: now).visible)
        XCTAssertEqual(subject(.folder(feedFolder)), .feed(atlas))
        let row = try XCTUnwrap(LibraryFeedsSectionRows.rows(at: LibraryLocation(category: .folders, folderPath: ""), center: world.center, now: now).first)
        XCTAssertEqual(subject(.feed(row)), .feed(atlas))

        // Unsubscribed since the row was drawn: the row's facts, with no
        // address; and the folder, no longer a feed's, is a folder again.
        world.center.unsubscribe(feed.id)
        XCTAssertNil(FeedInfoFacts.of(feedID: feed.id, center: world.center, now: now))
        XCTAssertEqual(subject(.feed(row)), .feed(FeedInfoFacts(row)))
        XCTAssertNil(FeedInfoFacts(row).address)
        XCTAssertEqual(FeedInfoFacts(row).title, "The Tactile Atlas")
        guard case .folder(let plain) = subject(.folder(feedFolder)) else {
            return XCTFail("a folder whose feed is gone was still spoken as a feed")
        }
        XCTAssertEqual(plain.name, feedFolder.name)
    }

    // MARK: - The Library Window

    /// In a hosted Library window, the I key speaks that nothing is
    /// selected, then, once a row is selected (the List selects a folder's
    /// row by its ID as a book's), that row's information: a plain
    /// folder's, a feed's folder's and a feed's row's as the feed, and a
    /// book's; Command-I on the plain folder speaks it too, since a folder
    /// has no sheet, and on the feed's row speaks nothing, opening Feed
    /// Info instead. The window's speaker speaks through a recorder, so
    /// nothing is heard.
    func testThePlainIKeyInAHostedLibraryWindowSpeaksTheSelectedRow() async throws {
        let recorder = InfoSynthesizerRecorder()
        let previous = LibraryInfoSpeaker.makeSynthesizer
        LibraryInfoSpeaker.makeSynthesizer = { recorder }
        defer { LibraryInfoSpeaker.makeSynthesizer = previous }

        let world = try FeedTestWorld(self, label: "SpeakInfoHosted")
        let base = world.bookFolder.fullPath
        let feed = try await subscribe(world, title: "The Tactile Atlas", path: "/atlas.xml", into: base)
        try world.library.createFolderReturningFolder(name: "Classics", parentPath: base)
        world.library.library.books.append(Book(
            title: "Middlemarch",
            author: "George Eliot",
            format: .epub,
            filePath: "/nonexistent/middlemarch.epub",
            md5Hash: "middlemarch",
            folderPath: base
        ))
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        let hosted = hostOffscreen(
            LibraryView(
                currentFolderPath: .constant(base),
                category: .constant(.folders),
                showFileImporter: .constant(false),
                showTextInput: .constant(false),
                onOpenBook: { _ in },
                feedFolders: LibraryFeedFolders(center: world.center)
            )
            .environmentObject(world.library)
            .environmentObject(settings)
        )
        defer { takeDown(hosted.window) }
        settle(hosted.hostingView, seconds: 0.5)
        let userInfo: [AnyHashable: Any] = ["sourceWindow": hosted.window]

        /// Posts `name` as the key pressed in the window would, and returns
        /// what was spoken for it, if anything, ending that announcement so
        /// the next press speaks rather than stops.
        func press(_ name: Notification.Name) -> String? {
            let before = recorder.utterances.count
            NotificationCenter.default.post(name: name, object: nil, userInfo: userInfo)
            flush(hosted.hostingView)
            guard recorder.utterances.count > before, let utterance = recorder.utterances.last else { return nil }
            // Told on the main thread, the speaker's delegate ends the
            // announcement at once.
            recorder.delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didFinish: utterance)
            flush(hosted.hostingView)
            return utterance.speechString
        }

        XCTAssertEqual(press(.speakInfo), LibraryInfoWording.nothingSelected)

        // Each row of the list selected in turn, from the top, and spoken.
        let list = try XCTUnwrap(descendants(of: hosted.hostingView, as: NSTableView.self).first, "the window shows no list")
        // The presses follow within three seconds of each other, so the
        // summaries alternate between brief and full: each is known by
        // its opening.
        var heard: [(row: Int, text: String)] = []
        var outcomes: [String] = []
        for row in 0..<list.numberOfRows {
            list.deselectAll(nil)
            flush(hosted.hostingView)
            list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            flush(hosted.hostingView)
            let stopsBefore = recorder.stops
            if let text = press(.speakInfo) {
                outcomes.append("\(row): \(text)")
                if text != LibraryInfoWording.nothingSelected {
                    heard.append((row, text))
                }
            } else {
                outcomes.append("\(row): \(recorder.stops > stopsBefore ? "stopped" : "silent")")
            }
        }
        let texts = heard.map(\.text)
        let report = outcomes.joined(separator: " | ")
        let atlasPrefix = "The Tactile Atlas. Feed. 1 episode"
        XCTAssertEqual(texts.filter { $0.hasPrefix("Classics. Folder. 0 books.") }.count, 1, report)
        XCTAssertEqual(texts.filter { $0.hasPrefix(atlasPrefix) }.count, 2, "the feed's folder and the feed's row: " + report)
        XCTAssertEqual(texts.filter { $0.hasPrefix("Middlemarch. By George Eliot. EPUB. In \(base). Unopened.") }.count, 1, report)
        XCTAssertEqual(texts.count, 4, report)
        XCTAssertNotNil(FeedInfoFacts.of(feedID: feed.id, center: world.center, now: Date()))

        // Command-I on the plain folder speaks it; on the feed's row it
        // speaks nothing, opening Feed Info.
        let classicsRow = try XCTUnwrap(heard.first { $0.text.hasPrefix("Classics. Folder.") }?.row)
        list.selectRowIndexes(IndexSet(integer: classicsRow), byExtendingSelection: false)
        flush(hosted.hostingView)
        XCTAssertEqual(press(.showBookInfo)?.hasPrefix("Classics. Folder. 0 books."), true)
        let feedRow = try XCTUnwrap(heard.filter { $0.text.hasPrefix(atlasPrefix) }.last?.row)
        list.selectRowIndexes(IndexSet(integer: feedRow), byExtendingSelection: false)
        flush(hosted.hostingView)
        XCTAssertNil(press(.showBookInfo), "Command-I on a feed's row spoke instead of opening Feed Info")
        settle(hosted.hostingView, seconds: 0.3)
    }

    // MARK: - Helpers

    /// Subscribes `world` to a feed titled `title` served at `path`, its
    /// folder made at `parentPath`, each item offering audio, so every one
    /// is an episode.
    private func subscribe(_ world: FeedTestWorld, title: String, path: String, into parentPath: String) async throws -> Feed {
        let item = FeedXML.Item(guid: "ep-1", title: "A map you can touch", enclosure: "https://atlas.example/audio/ep-1.mp3")
        world.server.serve(path, .feed(FeedXML.rss(title: title, items: [item])))
        if !world.center.hasStarted {
            await world.start()
        }
        let outcome = try await world.center.subscribe(to: world.server.url(path).absoluteString, into: .newFolder(inParentPath: parentPath))
        guard case .subscribed(let feed) = outcome else {
            throw NSError(domain: "LibraryInfoSpeakerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(outcome)"])
        }
        return feed
    }
}
