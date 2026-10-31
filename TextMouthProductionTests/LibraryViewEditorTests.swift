import AppKit
import SwiftUI
import XCTest
@testable import TextMouth

/// The view editor (the design of October 30, 2026,
/// LIBRARY-VIEWS-RESEARCH-2026-10-30.md, sections 7 and 9): every sentence
/// it says, the count of what a draft lists and the description of a
/// filter, the drafts of conditions, the view and sort a draft makes, the
/// problems Save finds in their order, saving through the Library tab's
/// actions, and the sheet hosted at its size, every control within it.
///
/// Each test runs on the main actor where it needs it, not the class as a
/// whole, as `UnopenedCategoryTests` explains.
final class LibraryViewEditorTests: XCTestCase {
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

    /// Every label, item, error, and announcement, exactly.
    func testEveryWording() {
        typealias W = LibraryViewEditorWording
        XCTAssertEqual([W.newTitle, W.editTitle("Unopened"), W.newViewButton, W.editButton], ["New View", "Edit Unopened", "New View…", "Edit…"])
        XCTAssertEqual(W.newViewHint, "Makes a view of your own from the conditions you choose.")
        XCTAssertEqual(W.editHint, "Changes the view's name, what it lists, its conditions, its sort, and its limit.")
        XCTAssertEqual(
            W.editDisabledHint,
            "Folders and the Reading List list what they always have. You can move them, and hide the Reading List."
        )
        XCTAssertEqual([W.cancel, W.save, W.nameLabel, W.listsLabel], ["Cancel", "Save", "Name", "Lists"])
        XCTAssertEqual(LibraryViewItemKind.allCases.map(W.kindName), ["Books", "Episodes", "Articles", "Feeds"])
        XCTAssertEqual(
            W.listsCaption,
            "Conditions about books test books, episodes, and articles; conditions about feeds test feeds. A condition never hides a row it does not test."
        )
        XCTAssertEqual([W.matchLabel, W.matchName(.all), W.matchName(.any)], ["Match", "All Conditions", "Any Condition"])
        XCTAssertEqual(W.conditionsHeader, "Conditions")
        XCTAssertEqual(W.noConditions, "No conditions: the view lists every item of the kinds chosen.")
        XCTAssertEqual(
            LibraryViewCondition.Kind.allCases.map(W.testName),
            ["Format", "Folder", "Reading State", "Reading List", "Date Added", "Date Opened", "Title or Author", "New Items", "Subscription"]
        )
        XCTAssertEqual(
            LibraryViewCondition.Kind.allCases.map { "\(W.relationName($0, isNegated: false))/\(W.relationName($0, isNegated: true))" },
            [
                "Is/Is Not", "Is/Is Not", "Is/Is Not", "In the Reading List/Not in the Reading List",
                "Within the Last/Not Within the Last", "Within the Last/Not Within the Last",
                "Contains/Does Not Contain", "Has New Episodes or Articles/Has None New", "Subscribed/Unsubscribed",
            ]
        )
        XCTAssertEqual(LibraryReadingState.allCases.map(W.stateName), ["Unopened", "In Progress", "Finished"])
        XCTAssertEqual(
            [W.conditionLabel(2), W.relationLabel(2), W.formatLabel(2), W.folderLabel(2), W.subfoldersLabel(2), W.readingStateLabel(2), W.daysLabel(2), W.textLabel(2), W.removeLabel(2)],
            [
                "Condition 2", "Condition 2 relation", "Condition 2 format", "Condition 2 folder", "Condition 2 includes subfolders",
                "Condition 2 reading state", "Condition 2 days", "Condition 2 text", "Remove condition 2",
            ]
        )
        XCTAssertEqual([W.subfoldersTitle, W.daysCaption, W.removeTitle, W.addCondition], ["Including Subfolders", "days", "Remove", "Add Condition"])
        XCTAssertEqual(W.conditionLimitHint, "A view holds at most 20 conditions.")
        XCTAssertEqual(W.onePerFeedTitle, "Only the Latest from Each Feed")
        XCTAssertEqual(W.onePerFeedHint, "Of each feed's episodes and articles, lists only the one you opened last.")
        XCTAssertEqual([W.sortByLabel, W.orderLabel, W.orderName(ascending: true), W.orderName(ascending: false)], ["Sort By", "Order", "Ascending", "Descending"])
        XCTAssertEqual(W.feedsOnlySortNote, "Feeds are always listed by title.")
        XCTAssertEqual(LibrarySortState.manualOrderHasNoDirection, "Manual order has no direction")
        XCTAssertEqual([W.limitTitle, W.limitFieldLabel, W.chosenByLabel], ["Show at Most", "Most rows shown", "Chosen By"])
        XCTAssertEqual(LibraryViewLimit.Order.allCases.map(W.limitOrderName), ["Opened Last", "Added Last", "First in the Sort"])
        XCTAssertEqual(W.nameMissing, "Give the view a name.")
        XCTAssertEqual(W.nameTooLong, "A view's name can be at most 60 characters.")
        XCTAssertEqual(W.nameTaken("Unopened"), "Another view is already named Unopened. Choose another name.")
        XCTAssertEqual(W.nothingListed, "Choose at least one kind of item for the view to list.")
        XCTAssertEqual(W.textMissing(3), "Condition 3 needs the text to look for.")
        XCTAssertEqual(W.saved("Unread EPUBs"), "Saved Unread EPUBs.")
        XCTAssertEqual(W.added("Unread EPUBs", number: 7, count: 7), "Added Unread EPUBs, 7 of 7.")
        XCTAssertEqual(W.missingFolder, "a folder no longer in the library")
    }

    /// The count names each kind by its own noun, and says when there is
    /// nothing.
    func testTheCountOfWhatADraftLists() {
        let book = Book(title: "Atlas", format: .epub, filePath: "/a", md5Hash: "a", tmbDirectoryName: "a.tmb")
        var episode = Book(title: "Ep", format: .audio, filePath: "/e", md5Hash: "e", tmbDirectoryName: "e.tmb")
        episode.feedLink = FeedBookLink(feedID: UUID(), itemID: "guid:e")
        var article = Book(title: "Art", format: .html, filePath: "/r", md5Hash: "r", tmbDirectoryName: "r.tmb")
        article.feedLink = FeedBookLink(feedID: UUID(), itemID: "guid:r")
        XCTAssertEqual(LibraryViewEditorWording.count(of: [], feeds: 0), "Lists nothing now.")
        XCTAssertEqual(LibraryViewEditorWording.count(of: [book], feeds: 2), "Lists 1 book and 2 feeds.")
        XCTAssertEqual(LibraryViewEditorWording.count(of: [book, book, episode, article], feeds: 0), "Lists 2 books, 1 episode, and 1 article.")
    }

    /// A filter described: its kinds, its conditions joined by "and" or
    /// "or", one feed's latest, and its limit.
    func testAFilterDescribed() {
        let folderID = UUID()
        let name: (UUID?) -> String = { LibraryFolderChoice.name(of: $0, among: [LibraryFolderChoice(id: folderID, path: "Fiction/Short")]) }
        XCTAssertEqual(
            LibraryViewDefinition.shipped(.recent).filter.map { LibraryViewEditorWording.description(of: $0, folderName: name) },
            "Lists books, episodes, and articles: reading state is not Unopened; only the latest from each feed; at most 10, opened last."
        )
        XCTAssertEqual(
            LibraryViewDefinition.shipped(.allItems).filter.map { LibraryViewEditorWording.description(of: $0, folderName: name) },
            "Lists books and feeds."
        )
        let filter = LibraryViewFilter(
            lists: [.books],
            match: .any,
            conditions: [
                LibraryViewCondition(test: .format(.epub)),
                LibraryViewCondition(test: .folder(id: folderID, includingSubfolders: true), isNegated: true),
                LibraryViewCondition(test: .folder(id: nil, includingSubfolders: false)),
                LibraryViewCondition(test: .folder(id: UUID(), includingSubfolders: false)),
                LibraryViewCondition(test: .inReadingList),
                LibraryViewCondition(test: .addedWithin(days: 1)),
                LibraryViewCondition(test: .openedWithin(days: 30), isNegated: true),
                LibraryViewCondition(test: .titleOrAuthorContains("Austen"), isNegated: true),
                LibraryViewCondition(test: .hasNewItems, isNegated: true),
                LibraryViewCondition(test: .subscribed),
            ],
            limit: LibraryViewLimit(count: 20, chosenBy: .dateAdded)
        )
        XCTAssertEqual(
            LibraryViewEditorWording.description(of: filter, folderName: name),
            "Lists books: format is EPUB, folder is not Fiction/Short, including subfolders, folder is Library Root, "
                + "folder is a folder no longer in the library, in the reading list, added today, not opened within the last 30 days, "
                + "title or author does not contain “Austen”, has none new, or subscribed; at most 20, added last."
        )
        XCTAssertEqual(LibraryViewEditorWording.listWithOr(["A", "B"]), "A or B")
        XCTAssertEqual(LibraryViewEditorWording.listWithOr(["A"]), "A")
        XCTAssertEqual(LibraryViewEditorWording.listWithOr([]), "")
    }

    // MARK: - Drafts

    /// A condition's draft makes the condition it was made from, and keeps
    /// every other kind's value while its kind changes; days and text are
    /// kept within their limits.
    @MainActor
    func testConditionDrafts() {
        let tests: [LibraryViewCondition] = [
            LibraryViewCondition(test: .format(.pdf), isNegated: true),
            LibraryViewCondition(test: .folder(id: UUID(), includingSubfolders: false)),
            LibraryViewCondition(test: .readingState(.finished)),
            LibraryViewCondition(test: .inReadingList),
            LibraryViewCondition(test: .addedWithin(days: 3)),
            LibraryViewCondition(test: .openedWithin(days: 40)),
            LibraryViewCondition(test: .titleOrAuthorContains("Moby")),
            LibraryViewCondition(test: .hasNewItems),
            LibraryViewCondition(test: .subscribed, isNegated: true),
        ]
        for condition in tests {
            XCTAssertEqual(LibraryViewConditionDraft(condition).condition, condition)
        }
        var draft = LibraryViewConditionDraft(LibraryViewCondition(test: .titleOrAuthorContains("  Moby  ")))
        draft.kind = .format
        draft.format = .daisy
        draft.kind = .titleOrAuthorContains
        XCTAssertEqual(draft.condition, LibraryViewCondition(test: .titleOrAuthorContains("Moby")))
        draft.kind = .addedWithin
        draft.days = 99_999
        XCTAssertEqual(draft.condition, LibraryViewCondition(test: .addedWithin(days: 3_650)))
        XCTAssertEqual(LibraryViewConditionDraft.newCondition().condition, LibraryViewCondition(test: .format(.epub)))
    }

    /// A new draft makes a view of the listener's own; an edited one keeps
    /// the view's identity and visibility; the sort keeps the directions
    /// the view remembered.
    @MainActor
    func testTheViewAndSortADraftMakes() throws {
        let model = LibraryViewEditorModel()
        XCTAssertEqual(model.title, "New View")
        model.name = "  Unread EPUBs "
        model.conditions = [.newCondition()]
        model.limitIsOn = true
        model.limitCount = 0
        let made = model.definition()
        XCTAssertEqual(made.id, .custom(model.id))
        XCTAssertEqual(made.name, "Unread EPUBs")
        XCTAssertEqual(made.visibility, .always)
        XCTAssertEqual(made.filter?.limit, LibraryViewLimit(count: 1, chosenBy: .viewSort))

        var unopened = LibraryViewDefinition.shipped(.unopened)
        unopened.visibility = .hidden
        let edit = LibraryViewEditorModel(editing: unopened, sort: .unopenedDefault)
        XCTAssertEqual(edit.title, "Edit Unopened")
        XCTAssertEqual(edit.sortField, .dateAdded)
        XCTAssertFalse(edit.sortAscending)
        XCTAssertEqual(edit.definition(), unopened)
        edit.sortField = .title
        edit.sortAscending = true
        let shown = FolderSortSetting(sortField: .dateAdded, sortAscending: false, rememberedDirections: [.author: false])
        XCTAssertEqual(
            edit.sortSetting(from: shown),
            FolderSortSetting(sortField: .title, sortAscending: true, rememberedDirections: [.author: false, .dateAdded: false])
        )
    }

    /// Save finds the first problem in the order the sheet shows its
    /// controls, and none at last; no more than 20 conditions are added.
    @MainActor
    func testTheProblemsSaveFindsInTheirOrder() {
        let list = LibraryViewDefinitionList.shipped
        let model = LibraryViewEditorModel()
        XCTAssertEqual(model.firstProblem(in: list), "Give the view a name.")
        model.name = String(repeating: "N", count: 61)
        XCTAssertEqual(model.firstProblem(in: list), "A view's name can be at most 60 characters.")
        model.name = " unopened "
        XCTAssertEqual(model.firstProblem(in: list), "Another view is already named unopened. Choose another name.")
        model.name = "Mine"
        model.lists = []
        XCTAssertEqual(model.firstProblem(in: list), "Choose at least one kind of item for the view to list.")
        model.lists = [.books]
        model.addCondition()
        var text = LibraryViewConditionDraft.newCondition()
        text.kind = .titleOrAuthorContains
        text.text = "   "
        model.conditions.append(text)
        XCTAssertEqual(model.firstProblem(in: list), "Condition 2 needs the text to look for.")
        model.removeCondition(text.id)
        XCTAssertNil(model.firstProblem(in: list))
        XCTAssertNil(LibraryViewEditorModel(editing: .shipped(.unopened), sort: .unopenedDefault).firstProblem(in: list))

        for _ in 0..<25 {
            model.addCondition()
        }
        XCTAssertEqual(model.conditions.count, 20)
        XCTAssertFalse(model.canAddCondition)
    }

    // MARK: - Saving

    /// Save adds a new view at the end with its sort, or puts an edited one
    /// in its place, saying which; a problem saves nothing.
    @MainActor
    func testSavingThroughTheLibraryTab() throws {
        let actions = LibraryViewsSettingsActions(
            store: LibraryViewDefinitionStore(preferences: makeSandboxedPreferences("library-view-editor")),
            library: LibraryViewModel(initializeServices: false)
        )
        let model = LibraryViewEditorModel()
        XCTAssertEqual(actions.save(model), .problem("Give the view a name."))
        XCTAssertEqual(actions.store.list, .shipped)

        model.name = "Unread EPUBs"
        model.sortField = .author
        model.sortAscending = false
        XCTAssertEqual(actions.save(model), .saved(id: .custom(model.id), announcement: "Added Unread EPUBs, 7 of 7."))
        let saved = try XCTUnwrap(actions.store.list.view(.custom(model.id)))
        let key = try XCTUnwrap(saved.sortSettingsKey)
        XCTAssertEqual(actions.library.library.folderSortSettings[key]?.sortField, .author)
        XCTAssertEqual(actions.library.library.folderSortSettings[key]?.sortAscending, false)

        let edit = LibraryViewEditorModel(editing: .shipped(.allItems), sort: .defaultSort)
        edit.name = "Everything"
        XCTAssertEqual(actions.save(edit), .saved(id: .category(.allItems), announcement: "Saved Everything."))
        XCTAssertEqual(actions.store.list.view(.category(.allItems))?.name, "Everything")
        XCTAssertNil(actions.library.library.folderSortSettings["__allItems__"])
    }

    // MARK: - The Sheet

    /// The sheet, with 20 conditions, a folder whose path is long, and a
    /// name of 60 characters: every control lies where it can be reached,
    /// none passes the sheet's right edge, and no condition's pop-up is
    /// wider than its bound (review of October 31, 2026, finding 14). The
    /// form may draw its rows only near where it is scrolled to, so the
    /// checks run at every place from its top to its bottom.
    @MainActor
    func testTheSheetFitsItsSize() throws {
        let model = LibraryViewEditorModel()
        model.name = String(repeating: "N", count: 60)
        model.lists = [.books, .episodes]
        let folder = LibraryFolderChoice(id: UUID(), path: String(repeating: "Long Folder/", count: 16) + "End")
        // Every kind of test, over and again, twenty in all.
        for kind in Array(repeating: LibraryViewCondition.Kind.allCases, count: 3).joined().prefix(20) {
            var draft = LibraryViewConditionDraft.newCondition()
            draft.kind = kind
            draft.folderID = folder.id
            model.conditions.append(draft)
        }
        let size = LibraryViewEditorSheet.size
        let hosted = hostOffscreen(
            LibraryViewEditorSheet(model: model, folders: [folder], count: { "Lists nothing now." }, onCancel: {}, onSave: {}),
            size: size
        )
        defer { takeDown(hosted.window) }
        let page = hosted.hostingView
        // The form's scroll view: the one whose document is tallest.
        func form() -> NSScrollView? {
            descendants(of: page, as: NSScrollView.self).max {
                ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
            }
        }
        XCTAssertTrue(
            waitUntil(timeout: 15) {
                page.layoutSubtreeIfNeeded()
                return !self.descendants(of: page, as: NSPopUpButton.self).isEmpty && form() != nil
            },
            "the sheet's form was not drawn"
        )
        settle(page, seconds: 0.2)
        let scrollView = try XCTUnwrap(form(), "the sheet's form has no scroll view")
        let document = try XCTUnwrap(scrollView.documentView, "the form's scroll view has no document")

        var unreachable = Set<String>()
        var pastTheEdge = Set<String>()
        var tooWide = Set<String>()
        var conditionPopUpCount = 0
        var sawAFolderPopUp = false
        // Half the visible height at a time, so every row is drawn at some
        // place, down to the place that shows the form's end.
        let step = max(scrollView.contentView.bounds.height / 2, 20)
        var offset: CGFloat = 0
        while true {
            document.scroll(NSPoint(x: 0, y: offset))
            settle(page, seconds: 0.05)
            let controls = visibleControls(in: page)
            unreachable.formUnion(controls.filter { !isReachable($0, in: page) }.map { describe($0, in: page) })
            pastTheEdge.formUnion(controls.filter { $0.convert($0.bounds, to: page).maxX > size.width + 0.5 }.map { describe($0, in: page) })
            let popUps = conditionPopUps(in: page)
            conditionPopUpCount = max(conditionPopUpCount, popUps.count)
            sawAFolderPopUp = sawAFolderPopUp || popUps.contains { $0.itemTitles.first == LibraryFolderOption.rootLabel }
            tooWide.formUnion(popUps.filter { $0.frame.width > LibraryViewEditorSheet.popUpWidth + 0.5 }.map {
                "\($0.titleOfSelectedItem ?? "") \(describe($0, in: page))"
            })
            if offset >= document.frame.height {
                break
            }
            offset += step
        }
        XCTAssertEqual(unreachable.sorted(), [])
        XCTAssertEqual(pastTheEdge.sorted(), [])
        XCTAssertEqual(tooWide.sorted(), [])
        // What was drawn, said when no condition pop-up was found.
        let drawn = descendants(of: page, as: NSPopUpButton.self).map(\.itemTitles)
        XCTAssertGreaterThan(conditionPopUpCount, 0, "no condition pop-up was found by its items; pop-ups drawn: \(drawn); form \(document.frame.size)")
        XCTAssertTrue(sawAFolderPopUp, "no folder pop-up was drawn; pop-ups drawn: \(drawn)")
    }

    /// The pop-ups of the conditions drawn in `page`, told apart by their
    /// items, since their spoken labels are SwiftUI's rather than the
    /// pop-ups' own: the tests, a relation's two, the formats, the reading
    /// states, and the folders, which begin with Library Root.
    @MainActor
    private func conditionPopUps(in page: NSView) -> [NSPopUpButton] {
        typealias W = LibraryViewEditorWording
        let kinds = LibraryViewCondition.Kind.allCases
        var itemSets: [Set<String>] = [Set(kinds.map(W.testName))]
        itemSets += kinds.map { Set([W.relationName($0, isNegated: false), W.relationName($0, isNegated: true)]) }
        itemSets.append(Set(BookFormat.allCases.map(\.displayName)))
        itemSets.append(Set(LibraryReadingState.allCases.map(W.stateName)))
        return descendants(of: page, as: NSPopUpButton.self).filter { popUp in
            itemSets.contains(Set(popUp.itemTitles)) || popUp.itemTitles.first == LibraryFolderOption.rootLabel
        }
    }

    // MARK: - The Review of October 31, 2026

    /// A view listing feeds alone saves no limit and no "only the latest
    /// from each feed", and its description says neither; one listing
    /// books alone saves no "only the latest" (finding 6).
    @MainActor
    func testSettingsThatCannotApplyAreNeitherSavedNorDescribed() {
        let model = LibraryViewEditorModel()
        model.lists = [.feeds]
        model.limitIsOn = true
        model.onePerFeed = true
        XCTAssertFalse(model.limitApplies)
        XCTAssertFalse(model.onePerFeedApplies)
        XCTAssertNil(model.filter.limit)
        XCTAssertFalse(model.filter.onePerFeed)
        let feedsAlone = LibraryViewFilter(lists: [.feeds], onePerFeed: true, limit: LibraryViewLimit(count: 5, chosenBy: .lastOpened))
        let description = LibraryViewEditorWording.description(of: feedsAlone) { _ in "" }
        XCTAssertEqual(description, "Lists feeds.")
        XCTAssertFalse(description.contains("at most"))

        model.lists = [.books]
        XCTAssertTrue(model.limitApplies)
        XCTAssertFalse(model.onePerFeedApplies)
        XCTAssertEqual(model.filter.limit, LibraryViewLimit(count: 10, chosenBy: .viewSort))
        XCTAssertFalse(model.filter.onePerFeed)
        XCTAssertEqual(
            LibraryViewEditorWording.onePerFeedUnavailableHint,
            "Applies only to a view that lists episodes or articles."
        )
        XCTAssertEqual(
            LibraryViewEditorWording.limitUnavailableHint,
            "A limit chooses among books, episodes, and articles, never feeds."
        )
    }

    /// The count of a draft whose limit is chosen by First in the Sort
    /// follows the draft's own sort, as Save will show it (finding 8).
    @MainActor
    func testTheCountFollowsTheDraftsSort() throws {
        let library = LibraryViewModel(initializeServices: false)
        library.finishedBookIDs = { [] }
        let start = Date(timeIntervalSince1970: 1_791_000_000)
        func row(_ title: String, _ format: BookFormat, feed: UUID?, daysLater: Double) -> Book {
            var book = Book(title: title, format: format, filePath: "/\(title)", md5Hash: title, tmbDirectoryName: "\(title).tmb")
            book.dateAdded = start.addingTimeInterval(daysLater * 86_400)
            book.feedLink = feed.map { FeedBookLink(feedID: $0, itemID: "guid:\(title)") }
            return book
        }
        let feed = UUID()
        library.library = Library(books: [
            row("Atlas", .epub, feed: nil, daysLater: 0),
            row("Bestiary", .epub, feed: nil, daysLater: 1),
            row("Cartography", .epub, feed: nil, daysLater: 2),
            row("Xylophone Hour", .audio, feed: feed, daysLater: 10),
            row("Yodel Hour", .audio, feed: feed, daysLater: 11),
            row("Zither Hour", .audio, feed: feed, daysLater: 12),
        ])
        let actions = LibraryViewsSettingsActions(
            store: LibraryViewDefinitionStore(preferences: makeSandboxedPreferences("library-view-editor-count")),
            library: library
        )
        let model = LibraryViewEditorModel()
        model.name = "Five"
        model.lists = [.books, .episodes]
        model.limitIsOn = true
        model.limitCount = 3
        model.limitChosenBy = .viewSort
        model.sortField = .title
        model.sortAscending = true
        XCTAssertEqual(actions.countSentence(for: model), "Lists 3 books.")
        model.sortField = .dateAdded
        model.sortAscending = false
        XCTAssertEqual(actions.countSentence(for: model), "Lists 3 episodes.")
    }
}
