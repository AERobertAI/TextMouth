import Foundation

/// Which of the Library's views a window offers and shows (the design of
/// October 30, 2026, LIBRARY-VIEWS-RESEARCH-2026-10-30.md, section 5).
extension LibraryViewModel {
    /// Whether `view` lists something now: Folders always; the Reading List
    /// while it holds a book, an episode, or an article; a filter view while
    /// one of its rows matches its filter, a book, episode, or article first
    /// (`LibraryViewFilterEvaluator.listsAnyItem`), then a feed from `center`
    /// (`LibraryFeedsSectionRows.listsAnyFeed`). Each search ends at the first
    /// match, outside the list cache, and sorts and measures nothing, so a
    /// window may ask it of every view at every redraw (review of October
    /// 31, 2026, finding 4).
    func listsSomething(_ view: LibraryViewDefinition, center: FeedCenter) -> Bool {
        switch view.kind {
        case .folders:
            return true
        case .readingList:
            return !readingListBooks.isEmpty
        case .filter:
            guard let filter = view.filter else { return false }
            let context = filterContext(for: LibraryLocation(view: view, folderPath: "")) ?? LibraryViewFilterContext()
            return LibraryViewFilterEvaluator.listsAnyItem(of: filter, in: library.books, context: context)
                || LibraryFeedsSectionRows.listsAnyFeed(of: view, center: center)
        }
    }

    /// The views of `list` shown when applicable that list something now
    /// (`listsSomething(_:center:)`), each asked once: what a window's View
    /// pop-up and Go to View share for a whole redraw.
    func applicableViews(in list: LibraryViewDefinitionList, center: FeedCenter) -> Set<LibraryViewID> {
        Set(list.views.filter { $0.visibility == .whenApplicable && listsSomething($0, center: center) }.map(\.id))
    }

    /// The views the View pop-up offers a window showing `current`
    /// (`LibraryViewDefinitionList.offeredViews`), those shown when
    /// applicable among `applicable` (`applicableViews(in:center:)`), which
    /// is worked out here when not given.
    func offeredViews(
        in list: LibraryViewDefinitionList,
        current: LibraryViewID?,
        center: FeedCenter,
        applicable: Set<LibraryViewID>? = nil
    ) -> [LibraryViewDefinition] {
        let applying = applicable ?? applicableViews(in: list, center: center)
        return list.offeredViews(current: current) { applying.contains($0.id) }
    }

    /// The view a window showing `id` shows: that view, or, when the list no
    /// longer has it (it was deleted) or the window shows none yet, the
    /// first view the pop-up offers, with `fellBack` true for a deleted one.
    func shownView(
        _ id: LibraryViewID?,
        in list: LibraryViewDefinitionList,
        center: FeedCenter
    ) -> (view: LibraryViewDefinition, fellBack: Bool) {
        if let id, let view = list.view(id) {
            return (view, false)
        }
        return (list.firstOffered { listsSomething($0, center: center) }, id != nil)
    }

    // MARK: - Go to View (Design Section 6)

    /// What Go to View does: the view a window goes to, if any, and what it
    /// says.
    struct GoToViewOutcome: Equatable {
        /// The view the window shows now, or nil when no view has the number.
        let view: LibraryViewDefinition?
        /// What the window announces: the view's name and what it lists, or
        /// that there is no such view.
        let announcement: String
    }

    /// What Go to View `number`, by its key or the Library menu, does in a
    /// window whose Folders shows `folderPath`: it goes to the `number`th of
    /// the views the View pop-up offers a window showing none
    /// (`offeredViews(in:current:center:)` with no current view), so a view
    /// a pop-up keeps only because its window shows it never counts and a
    /// key always goes to the same view, and says the view's name and what
    /// it lists there, its books, episodes, and articles before a search
    /// narrows them, and its feeds, "All Items, 743 books, 2 feeds"; or, with
    /// fewer views offered, it goes nowhere and says "There is no view 7.
    /// The View pop-up offers 6 views."
    func goToView(numbered number: Int, in list: LibraryViewDefinitionList, folderPath: String, center: FeedCenter) -> GoToViewOutcome {
        let offered = offeredViews(in: list, current: nil, center: center)
        guard offered.indices.contains(number - 1) else {
            return GoToViewOutcome(view: nil, announcement: LibraryViewPickerWording.noView(number: number, offered: offered.count))
        }
        let view = offered[number - 1]
        let location = LibraryLocation(view: view, folderPath: folderPath)
        let counts = CountWording.listItems(
            of: displayedBooks(at: location),
            feeds: LibraryFeedsSectionRows.feeds(at: location, center: center).count
        )
        return GoToViewOutcome(view: view, announcement: LibraryViewPickerWording.wentToView(name: view.name, counts: counts))
    }
}
