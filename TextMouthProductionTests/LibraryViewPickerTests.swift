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

    /// Which views shown when applicable list something is asked outside
    /// the list cache, sorting and measuring nothing: forty such views,
    /// asked for the View pop-up and for Go to View, derive no list, and
    /// those listing something are offered (review of October 31, 2026,
    /// finding 4).
    @MainActor
    func testWhichViewsApplyDerivesNoList() throws {
        let model = Self.model()
        let center = LibraryFeedFolders.shared.center
        var list = LibraryViewDefinitionList.shipped
        list.setVisibility(.hidden, of: .feeds)
        for number in 1...40 {
            // The even views list the EPUB, Atlas; the odd ones a PDF, none.
            let format: BookFormat = number.isMultiple(of: 2) ? .epub : .pdf
            let view = LibraryViewDefinition(
                id: .custom(UUID()),
                name: "View \(number)",
                visibility: .whenApplicable,
                filter: LibraryViewFilter(
                    lists: [.books],
                    conditions: [LibraryViewCondition(test: .format(format))],
                    limit: LibraryViewLimit(count: 1, chosenBy: .viewSort)
                )
            )
            XCTAssertTrue(list.add(view, after: nil))
        }
        let derivations = model.listCache.derivationCount
        let measurements = model.listCache.fileMeasurementCount

        // As a window's body asks: once for the views that apply, then the
        // pop-up's views and Go to View's.
        let applicable = model.applicableViews(in: list, center: center)
        let poppedUp = model.offeredViews(in: list, current: .category(.recent), center: center, applicable: applicable)
        let offered = model.offeredViews(in: list, current: nil, center: center, applicable: applicable)
        XCTAssertEqual(
            offered.map(\.name).filter { $0.hasPrefix("View ") },
            (1...40).filter { $0.isMultiple(of: 2) }.map { "View \($0)" }
        )
        XCTAssertEqual(poppedUp, offered)
        // Asked afresh, as Go to View's key asks.
        XCTAssertEqual(model.offeredViews(in: list, current: nil, center: center), offered)
        XCTAssertEqual(model.listCache.derivationCount, derivations, "asking which views apply derived a list")
        XCTAssertEqual(model.listCache.fileMeasurementCount, measurements, "asking which views apply measured a file")
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

    /// A view listing feeds alone has no Books section, and the Feeds view,
    /// the listener's views, and any view without a Books section say that
    /// nothing matches while they list nothing at all; the five categories'
    /// views as TextMouth ships them never do (review of October 31, 2026,
    /// finding 11).
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

        // Unopened, changed to list feeds alone, would otherwise show
        // nothing at all.
        var unopened = LibraryViewDefinition.shipped(.unopened)
        unopened.filter?.lists = [.feeds]
        XCTAssertFalse(LibraryView.hasBooksSection(unopened))
        XCTAssertTrue(LibraryView.showsEmptySentence(for: unopened, listsBooks: false, listsFeeds: false))
        XCTAssertFalse(LibraryView.showsEmptySentence(for: unopened, listsBooks: false, listsFeeds: true))
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
            name: Array(repeating: "Long Name", count: 6).joined(separator: " "),
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
