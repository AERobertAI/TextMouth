import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The Library window's views (the design of October 30, 2026,
/// LIBRARY-VIEWS-RESEARCH-2026-10-30.md, sections 5, 6, and 9): the words a
/// window says of its views, which views a window offers and which it
/// shows, what happens to a window whose view is deleted, the Books section
/// and the empty sentence of a view listing feeds alone, and the View
/// pop-up itself, hosted. Every store here is on sandboxed preferences of
/// the test's own, and every model the test's own.
///
/// Each test runs on the main actor, not the class as a whole, as
/// `UnopenedCategoryTests` explains.
final class LibraryViewPickerTests: XCTestCase {
    /// The isolated data root's index, put back after a test that saves.
    private var sandbox: LibraryIndexSandbox?

    override func setUpWithError() throws {
        sandbox = try LibraryIndexSandbox.capture()
    }

    override func tearDownWithError() throws {
        // Tear-down also runs when capturing failed in set-up.
        sandbox?.restore()
    }

    // MARK: - Wording

    /// Every sentence the window says of its views, exactly.
    func testEveryWording() {
        XCTAssertEqual(LibraryViewPickerWording.pickerWidthLimit, 320)
        XCTAssertEqual(LibraryViewPickerWording.emptyView, "Nothing matches this view now.")
        XCTAssertEqual(
            LibraryViewPickerWording.deletedView(nowShowing: "Folders"),
            "The view this window showed was deleted. It now shows Folders."
        )
        XCTAssertEqual(LibraryViewPickerWording.feedsOrderName, "Title")
        XCTAssertEqual(LibraryViewPickerWording.feedsSortMenuLabel, "Sort feeds by Title")
        XCTAssertEqual(LibraryViewPickerWording.feedsOrderHint, "Feeds are always listed by title")
        XCTAssertEqual(LibraryViewPickerWording.feedsOrderAnnouncement, "Feeds are listed by title")
    }

    // MARK: - Which Views a Window Offers

    /// Folders always lists something; the Reading List while it holds a
    /// row; a filter view while it lists a book or a feed.
    @MainActor
    func testWhichViewsListSomething() throws {
        let model = Self.model()
        let center = LibraryFeedFolders.shared.center
        XCTAssertTrue(model.listsSomething(.shipped(.folders), center: center))
        XCTAssertFalse(model.listsSomething(.shipped(.readingList), center: center))
        _ = model.addToReadingList(model.library.books.prefix(1).map(\.id))
        XCTAssertTrue(model.listsSomething(.shipped(.readingList), center: center))
        XCTAssertTrue(model.listsSomething(.shipped(.allItems), center: center))
        let nothing = LibraryViewDefinition(
            id: .custom(UUID()),
            name: "PDFs",
            visibility: .whenApplicable,
            filter: LibraryViewFilter(lists: [.books], conditions: [LibraryViewCondition(test: .format(.pdf))])
        )
        XCTAssertFalse(model.listsSomething(nothing, center: center))
    }

    /// The pop-up offers the views always offered and those offered when
    /// applicable while they list something, and keeps the view the window
    /// shows, however hidden; a window showing none yet, or a deleted view,
    /// shows the first view offered, the deleted one saying it fell back.
    @MainActor
    func testWhichViewsAWindowOffersAndShows() throws {
        let model = Self.model()
        let center = LibraryFeedFolders.shared.center
        var list = LibraryViewDefinitionList.shipped
        let pdfs = LibraryViewDefinition(
            id: .custom(UUID()),
            name: "PDFs",
            visibility: .whenApplicable,
            filter: LibraryViewFilter(lists: [.books], conditions: [LibraryViewCondition(test: .format(.pdf))])
        )
        list.add(pdfs, after: nil)
        list.setVisibility(.hidden, of: .category(.recent))
        let offered = model.offeredViews(in: list, current: nil, center: center).map(\.id)
        XCTAssertFalse(offered.contains(.category(.recent)))
        XCTAssertFalse(offered.contains(pdfs.id))
        XCTAssertEqual(Array(offered.prefix(3)), [.category(.folders), .category(.allItems), .category(.unopened)])
        XCTAssertTrue(model.offeredViews(in: list, current: .category(.recent), center: center).map(\.id).contains(.category(.recent)))

        XCTAssertEqual(model.shownView(nil, in: list, center: center).view.id, .category(.folders))
        XCTAssertFalse(model.shownView(nil, in: list, center: center).fellBack)
        XCTAssertEqual(model.shownView(pdfs.id, in: list, center: center).view.id, pdfs.id)
        list.delete(pdfs.id)
        let fallen = model.shownView(pdfs.id, in: list, center: center)
        XCTAssertEqual(fallen.view.id, .category(.folders))
        XCTAssertTrue(fallen.fellBack)
    }

    // MARK: - A View Listing Feeds Alone

    /// A view listing feeds alone has no Books section, and the Feeds view
    /// and the listener's views say that nothing matches while they list
    /// nothing at all; the five categories' views never do.
    func testTheBooksSectionAndTheEmptySentence() throws {
        let feeds = try XCTUnwrap(LibraryViewDefinition.shipped(.feeds))
        let mine = LibraryViewDefinitionTests.custom("Mine")
        XCTAssertFalse(LibraryView.hasBooksSection(feeds))
        XCTAssertTrue(LibraryView.hasBooksSection(mine))
        XCTAssertTrue(LibraryView.hasBooksSection(.shipped(.folders)))
        XCTAssertTrue(LibraryView.hasBooksSection(.shipped(.readingList)))
        XCTAssertTrue(LibraryView.hasBooksSection(.shipped(.allItems)))

        XCTAssertTrue(LibraryView.showsEmptySentence(for: feeds, listsBooks: false, listsFeeds: false))
        XCTAssertFalse(LibraryView.showsEmptySentence(for: feeds, listsBooks: false, listsFeeds: true))
        XCTAssertTrue(LibraryView.showsEmptySentence(for: mine, listsBooks: false, listsFeeds: false))
        XCTAssertFalse(LibraryView.showsEmptySentence(for: mine, listsBooks: true, listsFeeds: false))
        for category in LibraryCategory.allCases {
            XCTAssertFalse(LibraryView.showsEmptySentence(for: .shipped(category), listsBooks: false, listsFeeds: false), "\(category)")
        }
    }

    // MARK: - The Pop-up, Hosted

    /// The window's View pop-up is a pop-up button, no longer a segmented
    /// control, showing the view shown and offering the views by name, and
    /// no wider than its limit, even for a view named with 60 characters.
    @MainActor
    func testTheViewPopUpOffersTheViewsByName() throws {
        let model = Self.model()
        let store = LibraryViewDefinitionStore(preferences: makeSandboxedPreferences("library-view-picker"))
        let long = LibraryViewDefinition(
            id: .custom(UUID()),
            name: String(repeating: "Long Name ", count: 6),
            visibility: .always,
            filter: LibraryViewFilter(lists: [.books])
        )
        store.update { $0.add(long, after: nil) }
        let settings = SettingsViewModel(notificationCenter: NotificationCenter(), initializeServices: false)
        let hosted = hostOffscreen(
            LibraryView(
                currentFolderPath: .constant(""),
                shownViewID: .constant(long.id),
                showFileImporter: .constant(false),
                showTextInput: .constant(false),
                onOpenBook: { _ in },
                views: store
            )
            .environmentObject(model)
            .environmentObject(settings)
        )
        defer { takeDown(hosted.window) }
        var popUp: NSPopUpButton?
        _ = waitUntil(timeout: 2) {
            hosted.hostingView.layoutSubtreeIfNeeded()
            popUp = self.descendants(of: hosted.hostingView, as: NSPopUpButton.self)
                .first { $0.itemTitles.contains("Folders") }
            return popUp != nil
        }
        let picker = try XCTUnwrap(popUp, "the View pop-up was not drawn")
        XCTAssertEqual(picker.titleOfSelectedItem, long.name)
        XCTAssertEqual(Array(picker.itemTitles.prefix(5)), ["Folders", "All Items", "Unopened", "Recently Opened", "Reading List"])
        XCTAssertTrue(picker.itemTitles.contains(long.name))
        XCTAssertLessThanOrEqual(picker.frame.width, LibraryViewPickerWording.pickerWidthLimit + 0.5)
        XCTAssertTrue(descendants(of: hosted.hostingView, as: NSSegmentedControl.self).isEmpty)
    }

    // MARK: - Fixtures

    /// A model of two books at the top of the library, an EPUB and a text
    /// book, neither opened nor in the reading list, and a folder, Essays.
    @MainActor
    private static func model() -> LibraryViewModel {
        let model = LibraryViewModel(initializeServices: false)
        model.finishedBookIDs = { [] }
        model.library = Library(
            books: [
                Book(title: "Atlas", format: .epub, filePath: "/Atlas.epub", md5Hash: "atlas", tmbDirectoryName: "Atlas.tmb"),
                Book(title: "Bestiary", format: .txt, filePath: "/Bestiary.txt", md5Hash: "bestiary", tmbDirectoryName: "Bestiary.tmb"),
            ],
            folders: [BookFolder(name: "Essays")]
        )
        return model
    }
}
