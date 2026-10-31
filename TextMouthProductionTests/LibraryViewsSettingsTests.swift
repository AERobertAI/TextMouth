import XCTest
@testable import TextMouth

/// The Library tab of Settings (design sections 7 and 9): every sentence it
/// says, the row VoiceOver reads for each view, the commands each view
/// offers alike in its VoiceOver actions, the context menu, and the buttons,
/// and what Move, Duplicate, Delete, and Restore Default do to the views and
/// to the sorts the library's index keeps. Each test has a store on
/// sandboxed preferences and a library model of its own.
///
/// Each test runs on the main actor, not the class as a whole, as
/// `UnopenedCategoryTests` explains.
final class LibraryViewsSettingsTests: XCTestCase {
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

    /// Every sentence of the tab, exactly as the design gives it.
    func testEveryWording() {
        typealias W = LibraryViewsSettingsWording
        XCTAssertEqual(W.tabTitle, "Library")
        XCTAssertEqual(W.sectionHeader, "Views")
        XCTAssertEqual(
            W.orderCaption,
            "The Library window's View pop-up offers these views, in this order. A new Library window opens at the first one it offers."
        )
        XCTAssertEqual(
            W.visibilityCaption,
            "Always offers a view all the time. When Applicable offers it only while it lists something: the Reading List "
                + "while it holds a book, an episode, or an article, and Feeds while there is a feed. Hidden leaves it out. "
                + "A window showing a view keeps it until you choose another."
        )
        XCTAssertEqual(W.listLabel, "Views")
        XCTAssertEqual(
            W.rowLabel(name: "Reading List", isBuiltIn: true, visibility: .always, number: 5, count: 6),
            "Reading List, built in, always, 5 of 6"
        )
        XCTAssertEqual(
            W.rowLabel(name: "Unread EPUBs", isBuiltIn: false, visibility: .whenApplicable, number: 7, count: 7),
            "Unread EPUBs, custom, when applicable, 7 of 7"
        )
        XCTAssertEqual(LibraryViewVisibility.allCases.map(W.visibilityName), ["Always", "When Applicable", "Hidden"])
        XCTAssertEqual(LibraryViewVisibility.allCases.map(W.visibilityWord), ["always", "when applicable", "hidden"])
        XCTAssertEqual(LibraryViewVisibility.allCases.map(W.showAction), ["Show Always", "Show When Applicable", "Hide"])
        XCTAssertEqual(W.foldersHint, "Shows one folder at a time")
        XCTAssertEqual(W.readingListHint, "Shows the books in the order you arrange")
        XCTAssertEqual(
            [W.moveUpAction, W.moveDownAction, W.duplicateAction, W.deleteAction, W.restoreAction],
            ["Move Up", "Move Down", "Duplicate", "Delete…", "Restore Default…"]
        )
        XCTAssertEqual(W.visibilityTitle, "Visibility")
        XCTAssertEqual(W.visibilityLabel(name: "Feeds"), "Visibility of Feeds")
        XCTAssertEqual(W.visibilityHint, "Sets when the View pop-up offers this view")
        XCTAssertEqual(W.foldersVisibilityHint, "Folders is always shown: every folder and feed opens there.")
        XCTAssertEqual(W.moveUpLabel(name: "Feeds"), "Move Feeds Up")
        XCTAssertEqual(W.moveDownLabel(name: "Feeds"), "Move Feeds Down")
        XCTAssertEqual(W.moveUpHint, "Moves the view one place up the list")
        XCTAssertEqual(W.moveDownHint, "Moves the view one place down the list")
        XCTAssertEqual(W.firstInListHint, "The view is first in the list.")
        XCTAssertEqual(W.lastInListHint, "The view is last in the list.")
        XCTAssertEqual(W.placeAnnouncement(name: "Reading List", number: 4, count: 6), "Reading List, 4 of 6")
        XCTAssertEqual(W.duplicateHint, "Makes a view of your own with this view's conditions and sort.")
        XCTAssertEqual(W.duplicateUnavailableHint, "Folders and the Reading List have no conditions to copy.")
        XCTAssertEqual(W.duplicated(name: "Unopened Copy", number: 4, count: 7), "Made Unopened Copy, 4 of 7.")
        XCTAssertEqual(W.deleteHint, "Deletes the view. What it lists stays in the library.")
        XCTAssertEqual(W.deleteBuiltInHint, "A built-in view can be hidden, not deleted.")
        XCTAssertEqual(W.deleteTitle(name: "Unread EPUBs"), "Delete the view “Unread EPUBs”?")
        XCTAssertEqual(
            W.deleteMessage,
            "Its conditions and sort are deleted. The books, episodes, articles, and feeds it lists stay in the library, "
                + "and a Library window showing it shows another view."
        )
        XCTAssertEqual([W.deleteButton, W.cancelButton, W.restoreButton], ["Delete", "Cancel", "Restore Default"])
        XCTAssertEqual(W.deleted(name: "Unread EPUBs"), "Deleted Unread EPUBs.")
        XCTAssertEqual(W.restoreHint, "Gives the view back the name, conditions, sort, and limit TextMouth gave it.")
        XCTAssertEqual(W.restoreUnchangedHint, "This view is as TextMouth made it.")
        XCTAssertEqual(W.restoreCustomHint, "A view you made has no default to restore.")
        XCTAssertEqual(W.restoreTitle(name: "Not Yet"), "Restore “Not Yet” to its default?")
        XCTAssertEqual(
            W.restoreMessage,
            "Its name, conditions, sort, and limit go back to TextMouth's own. Its place in the list and when it is offered stay as they are."
        )
        XCTAssertEqual(W.restored(name: "Unopened"), "Restored Unopened.")
        XCTAssertEqual(W.unreadableCaption(count: 1), "1 view needs a newer TextMouth. It is kept as it is, and not offered.")
        XCTAssertEqual(W.unreadableCaption(count: 3), "3 views need a newer TextMouth. They are kept as they are, and not offered.")
        // Added by the review of October 31, 2026.
        XCTAssertEqual(W.viewLimit, "The Library holds at most 200 views.")
        XCTAssertEqual(W.restoreNameTaken(name: "Feeds"), "Another view is named Feeds. Rename it first, then restore this view.")
        XCTAssertEqual(W.visibilityChanged(name: "Feeds", to: .hidden), "Feeds, hidden")
        XCTAssertEqual(W.visibilityChanged(name: "Feeds", to: .always), "Feeds, shown always")
        XCTAssertEqual(W.visibilityChanged(name: "Feeds", to: .whenApplicable), "Feeds, shown when applicable")
        XCTAssertEqual(W.deleted(name: "Mine", selected: "Feeds", number: 6, count: 6), "Deleted Mine. Feeds selected, 6 of 6.")
    }

    /// The tab's row hints and Restore Default's hint, by view.
    @MainActor
    func testTheHintsEachViewGets() {
        let noFolders: (UUID?) -> String = { LibraryFolderChoice.name(of: $0, among: []) }
        XCTAssertEqual(LibraryViewsSettingsView.rowHint(of: .shipped(.folders), folderName: noFolders), "Shows one folder at a time")
        XCTAssertEqual(
            LibraryViewsSettingsView.rowHint(of: .shipped(.readingList), folderName: noFolders),
            "Shows the books in the order you arrange"
        )
        XCTAssertEqual(
            LibraryViewsSettingsView.rowHint(of: .shipped(.unopened), folderName: noFolders),
            "Lists books and feeds: reading state is Unopened and has new episodes or articles."
        )
        XCTAssertEqual(LibraryViewsSettingsView.restoreHint(of: .shipped(.unopened), available: true), LibraryViewsSettingsWording.restoreHint)
        XCTAssertEqual(LibraryViewsSettingsView.restoreHint(of: .shipped(.unopened), available: false), LibraryViewsSettingsWording.restoreUnchangedHint)
        XCTAssertEqual(LibraryViewsSettingsView.restoreHint(of: .shipped(.folders), available: false), LibraryViewsSettingsWording.restoreUnchangedHint)
        XCTAssertEqual(
            LibraryViewsSettingsView.restoreHint(of: LibraryViewDefinitionTests.custom("Mine"), available: false),
            LibraryViewsSettingsWording.restoreCustomHint
        )
        XCTAssertEqual(LibraryViewsSettingsView.restoreHint(of: nil, available: false), LibraryViewsSettingsWording.restoreCustomHint)
    }

    // MARK: - The Commands Each View Offers

    /// Each view offers the moves it can make, the visibilities it lacks
    /// (Folders none), Duplicate for a filter view, Delete… for a custom
    /// one, and Restore Default… for a built-in filter view that differs
    /// from TextMouth's own or has a sort saved.
    @MainActor
    func testTheCommandsEachViewOffers() {
        var list = LibraryViewDefinitionList.shipped
        let mine = LibraryViewDefinitionTests.custom("Mine")
        list.add(mine, after: nil)
        func commands(_ id: LibraryViewID, sortDiffers: Bool = false) -> [LibraryViewsSettingsCommand] {
            guard let view = list.view(id) else { return [] }
            return LibraryViewsSettingsCommand.available(for: view, in: list, sortDiffers: sortDiffers)
        }
        XCTAssertEqual(commands(.category(.folders)), [.moveDown])
        XCTAssertEqual(commands(.category(.allItems)), [.edit, .moveUp, .moveDown, .show(.whenApplicable), .show(.hidden), .duplicate])
        XCTAssertEqual(
            commands(.category(.allItems), sortDiffers: true),
            [.edit, .moveUp, .moveDown, .show(.whenApplicable), .show(.hidden), .duplicate, .restoreDefault]
        )
        XCTAssertEqual(commands(.category(.readingList)), [.moveUp, .moveDown, .show(.whenApplicable), .show(.hidden)])
        XCTAssertEqual(commands(.category(.readingList), sortDiffers: true), [.moveUp, .moveDown, .show(.whenApplicable), .show(.hidden)])
        XCTAssertEqual(commands(.feeds), [.edit, .moveUp, .moveDown, .show(.always), .show(.hidden), .duplicate])
        XCTAssertEqual(commands(mine.id), [.edit, .moveUp, .show(.whenApplicable), .show(.hidden), .duplicate, .delete])

        var renamed = LibraryViewDefinition.shipped(.unopened)
        renamed.name = "Not Yet"
        list.replace(renamed)
        XCTAssertEqual(commands(.category(.unopened)).last, .restoreDefault)
        XCTAssertEqual(
            [LibraryViewsSettingsCommand.edit, .moveUp, .moveDown, .show(.always), .show(.whenApplicable), .show(.hidden), .duplicate, .delete, .restoreDefault]
                .map(\.title),
            ["Edit…", "Move Up", "Move Down", "Show Always", "Show When Applicable", "Hide", "Duplicate", "Delete…", "Restore Default…"]
        )
    }

    // MARK: - What the Commands Do

    /// A move says the view's new place; a move past an end does nothing
    /// and says nothing; Folders keeps its visibility.
    @MainActor
    func testMovingAndShowingAView() throws {
        let actions = makeActions("moving")
        let readingList = LibraryViewDefinition.shipped(.readingList)
        XCTAssertEqual(actions.move(readingList, by: -1), "Reading List, 4 of 6")
        XCTAssertNil(actions.move(.shipped(.folders), by: -1))
        XCTAssertEqual(actions.store.list.views.map(\.id).dropFirst(3).first, .category(.readingList))
        XCTAssertFalse(actions.setVisibility(.hidden, of: .shipped(.folders)))
        XCTAssertTrue(actions.setVisibility(.hidden, of: readingList))
        XCTAssertEqual(actions.store.list.view(.category(.readingList))?.visibility, .hidden)
    }

    /// Duplicate makes a custom view named after the original, right after
    /// it, always offered, with its filter and the sort it shows saved under
    /// the copy's key.
    @MainActor
    func testDuplicatingAView() throws {
        let actions = makeActions("duplicate")
        let authorDescending = FolderSortSetting(sortField: .author, sortAscending: false)
        actions.library.setFolderSortSetting(authorDescending, for: "__unopened__")
        var unopened = LibraryViewDefinition.shipped(.unopened)
        unopened.visibility = .hidden
        actions.store.update { $0.replace(unopened) }

        let made = try XCTUnwrap(actions.duplicate(unopened))
        XCTAssertEqual(made.announcement, "Made Unopened Copy, 4 of 7.")
        let copy = try XCTUnwrap(actions.store.list.view(made.id))
        XCTAssertFalse(copy.isBuiltIn)
        XCTAssertEqual(copy.name, "Unopened Copy")
        XCTAssertEqual(copy.visibility, .always)
        XCTAssertEqual(copy.filter, unopened.filter)
        let key = try XCTUnwrap(copy.sortSettingsKey)
        XCTAssertEqual(actions.library.library.folderSortSettings[key], authorDescending)

        // Recently Opened's copy keeps the sort Recently Opened shows, its
        // default, newest opened first, though none is saved for it.
        let recent = try XCTUnwrap(actions.duplicate(.shipped(.recent)))
        let recentKey = try XCTUnwrap(actions.store.list.view(recent.id)?.sortSettingsKey)
        XCTAssertEqual(actions.library.library.folderSortSettings[recentKey], .recentDefault)

        XCTAssertNil(actions.duplicate(.shipped(.folders)))
        XCTAssertNil(actions.duplicate(.shipped(.readingList)))
    }

    /// Delete removes a custom view and the sort saved for it, and names
    /// the view to select next; a built-in view cannot be deleted.
    @MainActor
    func testDeletingAView() throws {
        let actions = makeActions("delete")
        let first = LibraryViewDefinitionTests.custom("First")
        let second = LibraryViewDefinitionTests.custom("Second")
        actions.store.update { $0.add(first, after: nil) }
        actions.store.update { $0.add(second, after: nil) }
        let key = try XCTUnwrap(first.sortSettingsKey)
        actions.library.setFolderSortSetting(FolderSortSetting(sortField: .dateAdded, sortAscending: false), for: key)

        let deleted = try XCTUnwrap(actions.delete(first))
        // The view selected now, and its place (review finding 13).
        XCTAssertEqual(deleted.announcement, "Deleted First. Second selected, 7 of 7.")
        XCTAssertEqual(deleted.nextSelection, second.id)
        XCTAssertNil(actions.store.list.view(first.id))
        XCTAssertNil(actions.library.library.folderSortSettings[key])

        let last = try XCTUnwrap(actions.delete(second))
        XCTAssertEqual(last.nextSelection, .feeds)
        XCTAssertEqual(last.announcement, "Deleted Second. Feeds selected, 6 of 6.")
        XCTAssertNil(actions.delete(.shipped(.unopened)))
        XCTAssertEqual(actions.store.list, .shipped)
    }

    /// Restore Default gives a built-in view its own name, filter, and sort
    /// back, keeping its place and visibility, and names it by its own name;
    /// it does nothing to a view as TextMouth made it. Unopened's shipped
    /// sort is written under its key (review finding 9); another view's
    /// saved sort is removed.
    @MainActor
    func testRestoringABuiltInView() throws {
        let actions = makeActions("restore")
        XCTAssertNil(actions.restoreDefault(.shipped(.unopened)))

        var unopened = LibraryViewDefinition.shipped(.unopened)
        unopened.name = "Not Yet"
        unopened.visibility = .whenApplicable
        actions.store.update { $0.replace(unopened) }
        actions.library.setFolderSortSetting(FolderSortSetting(sortField: .title, sortAscending: true), for: "__unopened__")
        XCTAssertTrue(actions.sortDiffers(for: unopened))

        XCTAssertEqual(actions.restoreDefault(unopened), "Restored Unopened.")
        var expected = LibraryViewDefinition.shipped(.unopened)
        expected.visibility = .whenApplicable
        XCTAssertEqual(actions.store.list.view(.category(.unopened)), expected)
        XCTAssertEqual(actions.library.library.folderSortSettings["__unopened__"], .unopenedDefault)
        XCTAssertFalse(actions.sortDiffers(for: expected))

        // A sort saved alone is reason enough, and is removed.
        actions.library.setFolderSortSetting(FolderSortSetting(sortField: .author, sortAscending: true), for: "__allItems__")
        XCTAssertEqual(actions.restoreDefault(.shipped(.allItems)), "Restored All Items.")
        XCTAssertNil(actions.library.library.folderSortSettings["__allItems__"])
    }

    // MARK: - The Review of October 31, 2026

    /// At the list's limit, Duplicate makes nothing and offers itself no
    /// more, Save of a new view reports the limit, and the list is
    /// unchanged, its last view included (finding 1).
    @MainActor
    func testTheListsLimitRefusesNewViews() throws {
        let actions = makeActions("limit")
        actions.store.update { list in
            while list.canAdd {
                list.add(LibraryViewDefinitionTests.custom("View \(list.views.count)"), after: nil)
            }
        }
        let full = actions.store.list
        XCTAssertEqual(full.entries.count, LibraryViewDefinitionList.entryLimit)
        let last = try XCTUnwrap(full.views.last)

        XCTAssertNil(actions.duplicate(.shipped(.unopened)))
        XCTAssertFalse(actions.commands(for: .shipped(.unopened)).contains(.duplicate))
        let model = LibraryViewEditorModel()
        model.name = "One Too Many"
        XCTAssertEqual(actions.save(model), .problem("The Library holds at most 200 views."))
        XCTAssertEqual(actions.store.list, full)
        XCTAssertEqual(actions.store.list.views.last, last)
        XCTAssertEqual(
            LibraryViewsSettingsView.duplicateHint(of: .shipped(.unopened), available: false, canAdd: false),
            "The Library holds at most 200 views."
        )
    }

    /// Restore Default refuses, changing nothing, when another view has the
    /// shipped name, and says which name (finding 5).
    @MainActor
    func testRestoreDefaultRefusesAShippedNameAnotherViewHas() throws {
        let actions = makeActions("restore-name")
        var feeds = try XCTUnwrap(LibraryViewDefinition.shipped(LibraryViewID.feeds))
        feeds.name = "Podcasts"
        actions.store.update { $0.replace(feeds) }
        var allItems = LibraryViewDefinition.shipped(.allItems)
        allItems.name = "Feeds"
        actions.store.update { $0.replace(allItems) }
        let before = actions.store.list

        XCTAssertEqual(
            actions.restoreDefault(feeds),
            "Another view is named Feeds. Rename it first, then restore this view."
        )
        XCTAssertEqual(actions.store.list, before)
        var list = before
        XCTAssertFalse(list.restoreDefault(.feeds))
    }

    /// Restoring Unopened, whose library still holds a sort chosen for the
    /// former No Folder, shows its shipped sort, not that one, and then
    /// offers Restore Default no more (finding 9).
    @MainActor
    func testRestoringUnopenedLeavesTheNoFolderSortBehind() throws {
        let actions = makeActions("restore-unopened")
        actions.library.setFolderSortSetting(FolderSortSetting(sortField: .title, sortAscending: true), for: "__noFolder__")
        actions.library.setFolderSortSetting(FolderSortSetting(sortField: .author, sortAscending: true), for: "__unopened__")
        let unopened = LibraryViewDefinition.shipped(.unopened)
        XCTAssertTrue(actions.commands(for: unopened).contains(.restoreDefault))

        XCTAssertEqual(actions.restoreDefault(unopened), "Restored Unopened.")
        let shown = actions.shownSortSetting(of: unopened)
        XCTAssertEqual(shown.sortField, .dateAdded)
        XCTAssertFalse(shown.sortAscending)
        XCTAssertFalse(actions.sortDiffers(for: unopened))
        XCTAssertFalse(actions.commands(for: unopened).contains(.restoreDefault))

        // Before any restore, the carried-over sort alone already differs.
        let other = makeActions("restore-unopened-carried")
        other.library.setFolderSortSetting(FolderSortSetting(sortField: .title, sortAscending: true), for: "__noFolder__")
        XCTAssertTrue(other.sortDiffers(for: unopened))
    }

    /// A visibility chosen from a row's action or the context menu is said:
    /// the view and how it is offered now; nothing when nothing changed
    /// (finding 12).
    @MainActor
    func testAVisibilityChosenFromARowIsSaid() throws {
        let actions = makeActions("visibility-said")
        let feeds = try XCTUnwrap(LibraryViewDefinition.shipped(LibraryViewID.feeds))
        XCTAssertEqual(actions.setVisibilitySaying(.hidden, of: feeds), "Feeds, hidden")
        XCTAssertNil(actions.setVisibilitySaying(.hidden, of: feeds))
        XCTAssertEqual(actions.setVisibilitySaying(.always, of: feeds), "Feeds, shown always")
        XCTAssertEqual(actions.setVisibilitySaying(.whenApplicable, of: feeds), "Feeds, shown when applicable")
        XCTAssertNil(actions.setVisibilitySaying(.hidden, of: .shipped(.folders)))
    }

    // MARK: - Fixtures

    /// The tab's actions on a store of sandboxed preferences named after
    /// `label`, discarded when the test ends, and a library model of their
    /// own, without services.
    @MainActor
    private func makeActions(_ label: String) -> LibraryViewsSettingsActions {
        LibraryViewsSettingsActions(
            store: LibraryViewDefinitionStore(preferences: makeSandboxedPreferences("library-views-settings-\(label)")),
            library: LibraryViewModel(initializeServices: false)
        )
    }
}
