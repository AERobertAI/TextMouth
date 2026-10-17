import SwiftUI
import XCTest
@testable import TextMouth

/// The folder the Library toolbar's settings button opens (FR19): which
/// folder shown gives which target, and the wording of the button, pinned
/// exactly since the listener hears it through VoiceOver.
final class LibraryFolderSettingsTargetTests: XCTestCase {

    // MARK: - Fixtures

    /// A plain folder "Essays", a folder "Essays/Drafts" inside it, and a
    /// feed's folder "Podcasts".
    private let essays = BookFolder(name: "Essays")
    private let drafts = BookFolder(name: "Drafts", parentPath: "Essays")
    private let podcasts = BookFolder(name: "Podcasts")
    /// The feed whose downloads go to "Podcasts".
    private let feedID = UUID()

    /// The target for a window showing `path` of `category`, with the
    /// podcasts feed titled `title` (nil: its record is gone).
    private func target(
        category: LibraryCategory = .folders,
        path: String,
        feedTitle title: String? = "Evening Dispatch"
    ) -> LibraryFolderSettingsTarget? {
        // Local copies, so the closures capture no test case.
        let feedFolderID = podcasts.id
        let feed = feedID
        return LibraryFolderSettingsTarget.of(
            category: category,
            folderPath: path,
            folders: [essays, drafts, podcasts],
            feedID: { $0 == feedFolderID ? feed : nil },
            feedTitle: { $0 == feed ? title : nil }
        )
    }

    // MARK: - Which target

    /// The top level is no folder, so it has no settings to open.
    func testTheTopLevelHasNoTarget() {
        XCTAssertNil(target(path: ""))
    }

    /// Only the Folders category shows a folder; the others have no target
    /// even when the path still names one.
    func testNoCategoryButFoldersHasATarget() {
        for category in LibraryCategory.allCases where category != .folders {
            XCTAssertNil(target(category: category, path: "Essays"), category.rawValue)
        }
    }

    /// A path no folder has gives no target.
    func testAnUnknownPathHasNoTarget() {
        XCTAssertNil(target(path: "Nowhere"))
        XCTAssertNil(target(path: "Essays/Nowhere"))
    }

    /// A plain folder gives the folder target, by its ID and name.
    func testAPlainFolderGivesAFolderTarget() {
        XCTAssertEqual(target(path: "Essays"), .folder(folderID: essays.id, name: "Essays"))
    }

    /// A nested folder is found by its full path, named by its own name.
    func testANestedPlainFolderGivesAFolderTarget() {
        XCTAssertEqual(target(path: "Essays/Drafts"), .folder(folderID: drafts.id, name: "Drafts"))
    }

    /// A feed's folder gives the feed target, with the feed's own title.
    func testAFeedsFolderGivesAFeedTarget() {
        XCTAssertEqual(target(path: "Podcasts"), .feed(feedID: feedID, title: "Evening Dispatch"))
    }

    /// A feed's folder whose feed record is gone still gives the feed
    /// target, titled with the folder's name.
    func testAFeedsFolderWhoseRecordIsGoneIsTitledByItsName() {
        XCTAssertEqual(target(path: "Podcasts", feedTitle: nil), .feed(feedID: feedID, title: "Podcasts"))
    }

    // MARK: - Wording

    /// The button's title, label, hint, and symbol in a feed's folder.
    func testTheFeedButtonsWordsArePinned() {
        let feed = LibraryFolderSettingsTarget.feed(feedID: feedID, title: "Evening Dispatch")
        XCTAssertEqual(feed.buttonTitle, "Feed Settings")
        XCTAssertEqual(feed.accessibilityLabel, "Feed settings for Evening Dispatch")
        XCTAssertEqual(
            feed.accessibilityHint,
            "Opens the settings of this feed: where its downloads go, what it lists and downloads, and what happens when an episode ends"
        )
        XCTAssertEqual(feed.systemImage, "slider.horizontal.3")
    }

    /// The button's title, label, hint, and symbol in a plain folder.
    func testTheFolderButtonsWordsArePinned() {
        let folder = LibraryFolderSettingsTarget.folder(folderID: essays.id, name: "Essays")
        XCTAssertEqual(folder.buttonTitle, "Folder Settings")
        XCTAssertEqual(folder.accessibilityLabel, "Folder settings for Essays")
        XCTAssertEqual(
            folder.accessibilityHint,
            "Opens the settings of this folder: what it holds, and what happens when one of its books ends"
        )
        XCTAssertEqual(folder.systemImage, "slider.horizontal.3")
    }

    /// What the shortcut says where no folder is shown.
    func testTheNothingToOpenLineIsPinned() {
        XCTAssertEqual(LibraryFolderSettingsWording.nothingToOpen, "Open a folder first to see its settings")
    }
}

/// The Folder or Feed Settings shortcut action (FR19): a Library-menu
/// command with no default key, which the Shortcuts tab lists under Library.
final class FolderOrFeedSettingsShortcutTests: XCTestCase {

    /// The action's title, group, scope, and the notification it posts.
    func testTheActionIsALibraryCommandWithNoKey() {
        let action = ShortcutAction.folderOrFeedSettings
        XCTAssertEqual(action.rawValue, "Folder or Feed Settings")
        XCTAssertEqual(action.title, "Folder or Feed Settings")
        XCTAssertEqual(action.category, "Library")
        XCTAssertEqual(action.defaultScope, .app)
        XCTAssertEqual(ShortcutAction.defaultBindings[action], [])
        XCTAssertEqual(action.notificationName, .showFolderOrFeedSettings)
        XCTAssertEqual(Notification.Name.showFolderOrFeedSettings.rawValue, "showFolderOrFeedSettings")
    }

    /// The Shortcuts tab lists the action in its Library group, whose row
    /// says it has no shortcut, and the record of edits lists it too.
    func testTheShortcutsTabListsIt() {
        XCTAssertTrue(ShortcutAction.allCases.filter { $0.category == "Library" }.contains(.folderOrFeedSettings))
        XCTAssertEqual(
            ShortcutsSettingsWording.rowLabel(for: .folderOrFeedSettings, keys: [], isEdited: false),
            "Folder or Feed Settings: No shortcut"
        )
        let listings = ShortcutEdits([:]).listings(defaults: ShortcutAction.defaultBindings)
        XCTAssertEqual(listings[.folderOrFeedSettings], "default: none")
    }

    /// The Library menu has a command for it, which is what lets a listener
    /// without a key reach it. SwiftUI builds the menu where a test cannot
    /// read it, so this reads the menu's source for the item.
    func testTheLibraryMenuHasTheCommand() throws {
        // MenuCommands.swift sits in TextMouth/App, beside the test folder.
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("TextMouth/App/MenuCommands.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(text.contains("Button(ShortcutAction.folderOrFeedSettings.title)"))
        XCTAssertTrue(text.contains("post(name: .showFolderOrFeedSettings"))
    }
}

// MARK: - Opening and the Library Window

/// Opening the settings of the folder a Library window shows (FR19): the one
/// path the toolbar's button and the command share, the modifier that hears
/// the command and presents the sheet, and the toolbar as AppKit draws it.
@MainActor
final class LibraryFolderSettingsWindowTests: XCTestCase {

    // MARK: - Fixtures

    /// A feed engine and library of the test's own, with a plain folder
    /// "Essays", a folder "Drafts" inside it, and one feed, whose folder is
    /// the world's own folder.
    private struct Shelf {
        let world: FeedTestWorld
        let feed: Feed
        let feedFolders: LibraryFeedFolders
        let feedPath: String
        /// The plain folder "Essays", and "Drafts" inside it.
        let plainPath: String
        let nestedPath: String
    }

    /// Builds the shelf, subscribing to a feed of one article.
    private func makeShelf(_ label: String) async throws -> Shelf {
        let world = try FeedTestWorld(self, label: label)
        let item = FeedXML.Item(
            guid: "one", title: "One", published: world.day(1), enclosure: nil,
            enclosureType: "audio/mp4", link: "https://atlas.example/one"
        )
        world.server.serve("/feed.xml", .feed(FeedXML.rss(items: [item])))
        let feed = try await world.subscribe("/feed.xml")
        // The plain folders go inside the world's own folder, which holds
        // everything the test makes.
        let essays = try world.library.createFolderReturningFolder(name: "Essays", parentPath: world.folder.path)
        let drafts = try world.library.createFolderReturningFolder(name: "Drafts", parentPath: essays.fullPath)
        return Shelf(
            world: world,
            feed: feed,
            feedFolders: LibraryFeedFolders(center: world.center),
            feedPath: world.bookFolder.fullPath,
            plainPath: essays.fullPath,
            nestedPath: drafts.fullPath
        )
    }

    /// Hosts a Library window on `shelf` showing `path` of `category`.
    private func hostLibrary(
        _ shelf: Shelf,
        category: LibraryCategory = .folders,
        path: String
    ) -> (window: NSWindow, hostingView: NSView) {
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        // Hosted as `hostOffscreen` does, but with the toolbars bridged, so
        // SwiftUI draws the window's toolbar in AppKit's.
        let hostingView = NSHostingView(
            rootView: LibraryView(
                currentFolderPath: .constant(path),
                category: .constant(category),
                showFileImporter: .constant(false),
                showTextInput: .constant(false),
                onOpenBook: { _ in },
                feedFolders: shelf.feedFolders
            )
            .environmentObject(shelf.world.library)
            .environmentObject(settings)
        )
        hostingView.sceneBridgingOptions = [.toolbars]
        let window = OffscreenTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.title = "Hosted Library window test"
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        return (window, hostingView)
    }

    // MARK: - The Shared Path

    /// A feed's target opens Feed Info for its feed, and only that.
    func testAFeedTargetOpensFeedInfo() {
        let feedID = UUID()
        var opened: [String] = []
        LibraryFolderSettingsTarget.open(
            .feed(feedID: feedID, title: "Atlas"),
            showFeedInfo: { opened.append("feed \($0)") },
            showFolderSettings: { opened.append("folder \($0)") },
            announce: { opened.append("said \($0)") }
        )
        XCTAssertEqual(opened, ["feed \(feedID)"])
    }

    /// A plain folder's target opens Folder Settings for its folder.
    func testAFolderTargetOpensFolderSettings() {
        let folderID = UUID()
        var opened: [String] = []
        LibraryFolderSettingsTarget.open(
            .folder(folderID: folderID, name: "Essays"),
            showFeedInfo: { opened.append("feed \($0)") },
            showFolderSettings: { opened.append("folder \($0)") },
            announce: { opened.append("said \($0)") }
        )
        XCTAssertEqual(opened, ["folder \(folderID)"])
    }

    /// With no target, nothing opens and the listener hears why.
    func testNoTargetSaysThereIsNothingToOpen() {
        var opened: [String] = []
        LibraryFolderSettingsTarget.open(
            nil,
            showFeedInfo: { opened.append("feed \($0)") },
            showFolderSettings: { opened.append("folder \($0)") },
            announce: { opened.append("said \($0)") }
        )
        XCTAssertEqual(opened, ["said Open a folder first to see its settings"])
    }

    /// Feed Info, opened through the path Command-I takes, is the sheet's
    /// model for the feed whose folder is shown.
    func testAFeedTargetOpensTheFeedInfoSheetsModel() async throws {
        let shelf = try await makeShelf("Feed Settings Opens Feed Info")
        let presenter = LibraryFeedsPresenter()
        let context = FeedCommandContext(center: shelf.world.center, library: shelf.world.library, window: nil)
        let target = LibraryFolderSettingsTarget.of(
            category: .folders,
            folderPath: shelf.feedPath,
            folders: shelf.world.library.library.folders,
            feedID: { shelf.feedFolders.feedID(inFolder: $0) },
            feedTitle: { shelf.world.center.store.records[$0]?.feed.title }
        )
        XCTAssertEqual(target, .feed(feedID: shelf.feed.id, title: shelf.feed.title))

        LibraryFolderSettingsTarget.open(
            target,
            showFeedInfo: { feedID in
                presenter.perform(FeedAction(command: .feedInfo, feedID: feedID, title: FeedWording.feedInfoTitle), in: context)
            },
            showFolderSettings: { _ in XCTFail("a feed's folder opened Folder Settings") },
            announce: { XCTFail("said \($0)") }
        )
        XCTAssertEqual(presenter.feedInfo?.feedID, shelf.feed.id)
    }

    // MARK: - The Modifier

    /// A command the window takes opens the settings; one it does not take
    /// does nothing.
    func testTheCommandOpensSettingsOnlyInTheWindowThatTakesIt() {
        var takes = true
        var opens = 0
        let hosted = hostOffscreen(
            Text("Library").modifier(LibraryFolderSettingsSupport(
                folderSettings: .constant(nil),
                takesCommand: { _ in takes },
                openShownSettings: { opens += 1 }
            ))
        )
        defer { takeDown(hosted.window) }
        settle(hosted.hostingView, seconds: 0.2)

        NotificationCenter.default.post(name: .showFolderOrFeedSettings, object: nil)
        XCTAssertEqual(opens, 1)

        takes = false
        NotificationCenter.default.post(name: .showFolderOrFeedSettings, object: nil)
        XCTAssertEqual(opens, 1, "a window that does not take the command opened settings")
    }

    // MARK: - The Library Window

    /// With no folder shown, the command is taken by the window it names and
    /// says there is nothing to open; another window's command is ignored.
    func testTheCommandWithNoFolderShownSaysSo() async throws {
        let shelf = try await makeShelf("Folder Settings Command At Top")
        let hosted = hostLibrary(shelf, path: "")
        defer { takeDown(hosted.window) }
        settle(hosted.hostingView, seconds: 0.5)
        let capture = AnnouncementCapture()
        defer { capture.stop() }

        let elsewhere = NSWindow()
        NotificationCenter.default.post(
            name: .showFolderOrFeedSettings, object: nil, userInfo: ["sourceWindow": elsewhere]
        )
        XCTAssertEqual(capture.messages, [], "a window that does not take the command spoke")

        NotificationCenter.default.post(
            name: .showFolderOrFeedSettings, object: nil, userInfo: ["sourceWindow": hosted.window]
        )
        XCTAssertEqual(capture.messages, [LibraryFolderSettingsWording.nothingToOpen])
    }

    /// The labels of the toolbar's items as AppKit draws them, or nil when
    /// this macOS draws no toolbar for a hosted view.
    private func toolbarLabels(of window: NSWindow) -> [String]? {
        guard waitUntil(timeout: 5, {
            window.contentView?.layoutSubtreeIfNeeded()
            return window.toolbar != nil
        }) else { return nil }
        settle(window.contentView, seconds: 0.5)
        return window.toolbar?.items.map(\.label)
    }

    /// The toolbar holds the settings button only while a folder of the
    /// Folders category is shown, titled for what the folder is.
    func testTheToolbarShowsTheButtonOnlyInAFolder() async throws {
        let shelf = try await makeShelf("Folder Settings Toolbar")

        /// The labels for a window showing `path` of `category`.
        func labels(_ category: LibraryCategory, _ path: String) throws -> [String] {
            let hosted = hostLibrary(shelf, category: category, path: path)
            defer { takeDown(hosted.window) }
            guard let labels = toolbarLabels(of: hosted.window) else {
                throw XCTSkip("This macOS draws no toolbar for a hosted SwiftUI view")
            }
            return labels
        }
        let feedButton = LibraryFolderSettingsWording.feedButtonTitle
        let folderButton = LibraryFolderSettingsWording.folderButtonTitle

        let top = try labels(.folders, "")
        XCTAssertFalse(top.contains(folderButton) || top.contains(feedButton), "the top level has a settings button: \(top)")
        XCTAssertTrue(try labels(.folders, shelf.plainPath).contains(folderButton), "no Folder Settings in a plain folder")
        XCTAssertTrue(try labels(.folders, shelf.nestedPath).contains(folderButton), "no Folder Settings in a nested folder")
        let inFeed = try labels(.folders, shelf.feedPath)
        XCTAssertTrue(inFeed.contains(feedButton), "no Feed Settings in a feed's folder: \(inFeed)")
        XCTAssertFalse(inFeed.contains(folderButton), "Folder Settings in a feed's folder")
        for category in LibraryCategory.allCases where category != .folders {
            let other = try labels(category, shelf.plainPath)
            XCTAssertFalse(other.contains(folderButton) || other.contains(feedButton), "\(category.rawValue) has a settings button")
        }
    }
}
