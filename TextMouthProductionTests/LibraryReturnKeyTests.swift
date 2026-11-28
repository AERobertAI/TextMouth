import AppKit
import AVFoundation
import SwiftUI
import XCTest
@testable import TextMouth

/// Return in a Library window, Open Selected Book (returnrow): it opens the
/// row the list's selection holds, and never another row. The selection is
/// moved by Down Arrow, as a VoiceOver user moves it. In a feed's folder,
/// Return on a downloaded episode opens it. On the episode beside it, not
/// downloaded, Return once opened the downloaded one, because that row could
/// not hold the selection; now Return downloads it, then opens it. In a cloud
/// library, Return on a book only in the cloud opens that book (its reader
/// downloads it), beside a book on this Mac. A folder's or a feed's row
/// opens its folder, and with nothing selected VoiceOver hears so.
///
/// No key is really pressed. Arrows go to the hosted window, which never
/// comes on screen, and Return goes through the test's own shortcut manager.
/// Speak Info, which says which row is selected, speaks into a recorder, and
/// announcements are recorded, so nothing is heard.
@MainActor
final class LibraryReturnKeyTests: XCTestCase {
    /// The newer episode's identity, downloaded in the feed test.
    private static let newerID = "guid:newer"
    /// The older episode's identity, never downloaded until Return.
    private static let olderID = "guid:older"

    // MARK: - A Feed's Folder

    /// In a feed's folder, nothing is selected at first, so Return says so.
    /// Return on the downloaded episode opens it. One Down Arrow reaches the
    /// episode beside it, not downloaded, and Return there says it
    /// downloads it first, downloads it, and opens it, never opening the
    /// downloaded one again. From the folder holding the feed, Return on the
    /// feed's row opens the feed's folder.
    func testReturnOpensTheEpisodeSelectedAndDownloadsOneNotDownloadedFirst() async throws {
        let world = try FeedTestWorld(self, label: "ReturnKeyFeed")
        let feed = try await subscribe(world)
        let folderPath = try XCTUnwrap(world.library.feedFolderPath(forFolderID: feed.folderID))
        // The newer episode downloaded: a book standing for its download,
        // in the feed's folder. No package is written: nothing reads one.
        let downloaded = Book(
            title: "The newer episode",
            format: .audio,
            filePath: "/nonexistent/\(UUID().uuidString).m4a",
            md5Hash: UUID().uuidString,
            folderPath: folderPath
        )
        world.library.library.books.append(downloaded)
        world.center.store.updateItem(Self.newerID, of: feed.id) { $0.state = .downloaded(bookID: downloaded.id) }
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item(Self.olderID)?.state, .notDownloaded)
        // The books a finished feed download opens, by ID.
        var readerOpened: [UUID] = []
        world.library.readerOpener = { readerOpened.append($0) }
        let feedFolders = LibraryFeedFolders(center: world.center)

        let window = try ReturnKeyWindow(self, library: world.library, feedFolders: feedFolders, showing: folderPath)

        // Nothing is selected yet: Return says so, and opens nothing.
        var heardBefore = window.heard.count
        try window.pressReturn()
        XCTAssertEqual(window.heard(since: heardBefore), [LibraryInfoWording.nothingSelected])
        XCTAssertEqual(window.opened, [], "Return with nothing selected opened a book")

        guard window.moveDown(toRowBeginning: "The newer episode") else { return }
        try window.pressReturn()
        XCTAssertEqual(window.opened, [downloaded.id], "Return on the downloaded episode did not open it")

        // The next row down: the episode not downloaded, whose row the
        // selection once could not reach.
        guard window.moveDown(toRowBeginning: "The older episode", limit: 1) else { return }
        heardBefore = window.heard.count
        try window.pressReturn()
        XCTAssertEqual(window.opened, [downloaded.id], "Return on the episode not downloaded opened another book")
        XCTAssertEqual(window.heard(since: heardBefore).first, FeedWording.downloadingToOpen(title: "The older episode"))
        await waitFor("the episode Return chose downloads and opens", timeout: 30) { !readerOpened.isEmpty }
        let opened = try XCTUnwrap(readerOpened.first)
        XCTAssertEqual(world.center.store.record(of: feed.id)?.item(Self.olderID)?.state, .downloaded(bookID: opened))
        XCTAssertEqual(readerOpened.count, 1, "the download opened more than its own book")

        // The folder holding the feed, where the feed's row stands for the
        // feed's folder: Return opens that folder.
        let above = try ReturnKeyWindow(self, library: world.library, feedFolders: feedFolders, showing: world.folder.path)
        guard above.moveDown(toRowBeginning: "The Tactile Atlas") else { return }
        try above.pressReturn()
        XCTAssertEqual(above.location.path, folderPath, "Return on the feed's row did not open its folder")
    }

    // MARK: - A Cloud Library

    /// In a cloud library, Return on a folder's row opens the folder. In it,
    /// Return on the book downloaded to this Mac opens it, and one Down Arrow
    /// later, Return on the book only in the cloud opens that book, whose
    /// reader downloads it first.
    func testReturnOpensABookOnlyInTheCloudBesideOneOnThisMac() throws {
        let model = LibraryViewModel(initializeServices: false)
        // A shelf in a room, so the window opens on a folder of the test's
        // own, whose rows are the shelf's alone.
        let room = BookFolder(name: "Room")
        let shelfFolder = BookFolder(name: "Shelf", parentPath: room.name)
        let shelf = shelfFolder.fullPath
        /// A book on the shelf, `index` in its manual order.
        func book(_ title: String, _ index: Int) -> Book {
            Book(
                title: title,
                author: "Author",
                format: .epub,
                filePath: "/nonexistent/return-key/\(index).epub",
                md5Hash: "return-key-\(index)",
                folderPath: shelf,
                manualSortOrder: index
            )
        }
        let onThisMac = book("On this Mac", 0)
        let inCloud = book("Only in the cloud", 1)
        model.library = Library(books: [onThisMac, inCloud], folders: [room, shelfFolder])
        let location = LibraryLocation(category: .folders, folderPath: shelf)
        model.library.folderSortSettings[location.sortSettingsKey] = FolderSortSetting(sortField: .manual, sortAscending: true)
        // The rows' cloud notes come from the app's store, which nothing
        // refreshes in a process hosting tests; leaving the cloud location
        // afterwards forgets the states recorded here.
        let states = BookCloudStates.shared
        let locationBefore = states.libraryLocation
        states.setLibraryLocation(.cloud(.iCloudDrive))
        states.record(.downloaded, for: onThisMac.id)
        states.record(.inCloud, for: inCloud.id)
        addTeardownBlock { @MainActor in states.setLibraryLocation(locationBefore) }

        let window = try ReturnKeyWindow(self, library: model, showing: room.fullPath)

        guard window.moveDown(toRowBeginning: shelfFolder.name) else { return }
        try window.pressReturn()
        XCTAssertEqual(window.location.path, shelf, "Return on the folder's row did not open the folder")
        try window.takeKeyboard()

        guard window.moveDown(toRowBeginning: "On this Mac") else { return }
        try window.pressReturn()
        XCTAssertEqual(window.opened, [onThisMac.id], "Return on the book on this Mac did not open it")

        guard window.moveDown(toRowBeginning: "Only in the cloud", limit: 1) else { return }
        try window.pressReturn()
        XCTAssertEqual(window.opened, [onThisMac.id, inCloud.id], "Return on the book only in the cloud opened another")
    }

    // MARK: - Helpers

    /// Subscribes `world` to The Tactile Atlas, a feed of two episodes a
    /// day and a half apart, into a new folder in the world's folder. The
    /// older episode's audio is served, so its download can finish.
    private func subscribe(_ world: FeedTestWorld) async throws -> Feed {
        world.server.serve("/audio/older.m4a", FeedMediaFixtures.file(try FeedMediaFixtures.silentAAC(duration: 1), mimeType: "audio/mp4"))
        world.server.serve("/atlas.xml", .feed(FeedXML.rss(title: "The Tactile Atlas", items: [
            FeedXML.Item(
                guid: "newer",
                title: "The newer episode",
                published: world.day(0.5),
                enclosure: world.server.url("/audio/newer.m4a").absoluteString,
                enclosureType: "audio/mp4"
            ),
            FeedXML.Item(
                guid: "older",
                title: "The older episode",
                published: world.day(-1),
                enclosure: world.server.url("/audio/older.m4a").absoluteString,
                enclosureType: "audio/mp4"
            ),
        ])))
        await world.start()
        let outcome = try await world.center.subscribe(
            to: world.server.url("/atlas.xml").absoluteString,
            into: .newFolder(inParentPath: world.folder.path)
        )
        guard case .subscribed(let feed) = outcome else {
            throw NSError(domain: "LibraryReturnKeyTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(outcome)"])
        }
        return feed
    }
}

// MARK: - The Hosted Window

/// A hosted Library window for the Return tests. It holds the list, a
/// shortcut manager of its own that posts where the window listens, Speak
/// Info speaking into a recorder, and what the window opened and announced.
/// Everything it swaps is put back, and the window taken down, when the test
/// ends.
@MainActor
private final class ReturnKeyWindow {
    /// The folder the window shows, which Return on a folder's or a feed's
    /// row changes, and the window follows.
    final class Location: ObservableObject {
        /// The folder's path; "" for the top of the library.
        @Published var path: String

        /// A location showing `path`.
        init(_ path: String) {
            self.path = path
        }
    }

    /// What the window opened and VoiceOver was asked to say, which the
    /// window's closures record into, so none of them holds the window.
    @MainActor
    private final class Record {
        /// The books the window asked to open, by ID, in order.
        var opened: [UUID] = []
        /// What VoiceOver was asked to say, in order.
        var heard: [String] = []
    }

    /// The folder shown.
    let location: Location
    /// The test the window belongs to.
    private let test: XCTestCase
    /// The window and the view it hosts.
    private let hosted: (window: NSWindow, hostingView: NSView)
    /// The shortcut manager Return goes through.
    private let manager: KeyboardShortcutManager
    /// What Speak Info speaks into.
    private let recorder: InfoSynthesizerRecorder
    /// What the window did.
    private let record: Record
    /// The window's list, once it has the keyboard.
    private var list: NSTableView?

    /// The books the window asked to open, by ID, in order.
    var opened: [UUID] {
        record.opened
    }

    /// What VoiceOver was asked to say, in order.
    var heard: [String] {
        record.heard
    }

    /// Hosts a Library window showing the folder at `path` of `library`,
    /// its feeds those of `feedFolders`, and gives its list the keyboard.
    /// - Throws: `XCTSkip` where this macOS gives an offscreen window's list
    ///   no keyboard focus, so no arrow key could reach it.
    init(
        _ test: XCTestCase,
        library: LibraryViewModel,
        feedFolders: LibraryFeedFolders = .shared,
        showing path: String
    ) throws {
        let record = Record()
        let recorder = InfoSynthesizerRecorder()
        // Speak Info through the recorder, and every announcement recorded,
        // both put back when the test ends.
        let previousSynthesizer = LibraryInfoSpeaker.makeSynthesizer
        LibraryInfoSpeaker.makeSynthesizer = { recorder }
        let previousPoster = VoiceOverAnnouncer.poster
        VoiceOverAnnouncer.poster = { announcement, _ in record.heard.append(announcement.message) }
        test.addTeardownBlock { @MainActor in
            LibraryInfoSpeaker.makeSynthesizer = previousSynthesizer
            VoiceOverAnnouncer.poster = previousPoster
        }

        let location = Location(path)
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        let root = ReturnKeyLibrary(location: location, feedFolders: feedFolders) { book in
            record.opened.append(book.id)
        }
        .environmentObject(library)
        .environmentObject(settings)
        let hosted = test.hostOffscreen(root)
        // Taken down as `takeDown(_:)` does, once the test ends.
        let window = hosted.window
        test.addTeardownBlock { @MainActor in
            window.contentView = NSView()
            window.close()
        }

        self.test = test
        self.location = location
        self.hosted = hosted
        self.recorder = recorder
        self.record = record
        manager = KeyboardShortcutManager(
            userDefaults: test.makeSandboxedPreferences("return-key"),
            installsEventMonitor: false,
            notificationCenter: .default
        )
        test.settle(hosted.hostingView, seconds: 0.5)
        try takeKeyboard()
    }

    /// Gives the window's list the keyboard, as clicking into it would, and
    /// again after the window shows another folder.
    /// - Throws: `XCTSkip` where this macOS gives an offscreen window's list
    ///   no keyboard focus.
    func takeKeyboard() throws {
        test.settle(hosted.hostingView, seconds: 0.3)
        let table = try XCTUnwrap(test.descendants(of: hosted.hostingView, as: NSTableView.self).first, "the window shows no list")
        guard hosted.window.makeFirstResponder(table), hosted.window.firstResponder === table else {
            throw XCTSkip("This macOS gives an offscreen window's list no keyboard focus, so no arrow key reaches it")
        }
        list = table
    }

    /// What VoiceOver was asked to say after the first `count` messages.
    func heard(since count: Int) -> [String] {
        Array(record.heard.dropFirst(count))
    }

    /// Presses Return with the list having the keyboard, as the event
    /// monitor hands the press to the shortcut manager, and lets the window
    /// act on it.
    func pressReturn(file: StaticString = #filePath, line: UInt = #line) throws {
        let press = try ShortcutKeyPresses.keyPress(of: KeyBinding(key: "return"))
        XCTAssertTrue(
            manager.handleKeyEvent(press, keyWindow: hosted.window, firstResponder: list),
            "Return was not taken as Open Selected Book",
            file: file,
            line: line
        )
        test.settle(hosted.hostingView, seconds: 0.3)
    }

    /// Presses Down Arrow in the list until Speak Info says the selected
    /// row begins with `prefix`, at most `limit` times, as a listener moves
    /// down to a row. Returns whether it got there; when it does not, the
    /// test fails, naming what each press selected.
    func moveDown(
        toRowBeginning prefix: String,
        limit: Int = 4,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        var reached: [String] = []
        for _ in 0..<limit {
            guard let down = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [.numericPad, .function],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: hosted.window.windowNumber,
                context: nil,
                characters: "\u{F701}",
                charactersIgnoringModifiers: "\u{F701}",
                isARepeat: false,
                keyCode: 125
            ) else {
                XCTFail("no Down Arrow key press could be made", file: file, line: line)
                return false
            }
            hosted.window.sendEvent(down)
            test.settle(hosted.hostingView, seconds: 0.3)
            let summary = selectedRowSummary() ?? "nothing spoken"
            if summary.hasPrefix(prefix) {
                return true
            }
            reached.append(summary)
        }
        XCTFail("Down Arrow never selected the row of \(prefix); each press selected: \(reached)", file: file, line: line)
        return false
    }

    /// What Speak Info says of the row the list's selection holds: its
    /// brief summary, or that nothing is selected; nil if it said nothing.
    private func selectedRowSummary() -> String? {
        let before = recorder.utterances.count
        NotificationCenter.default.post(name: .speakInfo, object: nil, userInfo: ["sourceWindow": hosted.window])
        test.flush(hosted.hostingView)
        guard recorder.utterances.count > before, let utterance = recorder.utterances.last else { return nil }
        // Ended at once, so the next press speaks rather than stops.
        recorder.delegate?.speechSynthesizer?(AVSpeechSynthesizer(), didFinish: utterance)
        test.flush(hosted.hostingView)
        return utterance.speechString
    }
}

/// A Library window's list showing the folder `location` holds, and
/// following it when Return opens another folder.
private struct ReturnKeyLibrary: View {
    /// The folder shown.
    @ObservedObject var location: ReturnKeyWindow.Location
    /// Which library folders hold feeds.
    let feedFolders: LibraryFeedFolders
    /// Opens a book, as the window's reader scene would.
    let onOpenBook: (Book) -> Void

    var body: some View {
        LibraryView(
            currentFolderPath: $location.path,
            category: .constant(.folders),
            showFileImporter: .constant(false),
            showTextInput: .constant(false),
            onOpenBook: onOpenBook,
            feedFolders: feedFolders
        )
    }
}
