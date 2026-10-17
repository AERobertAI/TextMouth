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
