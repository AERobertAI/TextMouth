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
