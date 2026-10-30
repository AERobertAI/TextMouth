import Foundation

/// Which of the Library's views a window offers and shows (the design of
/// October 30, 2026, LIBRARY-VIEWS-RESEARCH-2026-10-30.md, section 5).
extension LibraryViewModel {
    /// Whether `view` lists something now: Folders always; the Reading List
    /// while it holds a book, an episode, or an article; a filter view while
    /// its books (`displayedBooks(at:)`, asked first, since the list cache
    /// keeps them) or its feed rows (`LibraryFeedsSectionRows.feeds(at:center:)`,
    /// from `center`) are not empty.
    func listsSomething(_ view: LibraryViewDefinition, center: FeedCenter) -> Bool {
        switch view.kind {
        case .folders:
            return true
        case .readingList:
            return !readingListBooks.isEmpty
        case .filter:
            let location = LibraryLocation(view: view, folderPath: "")
            return !displayedBooks(at: location).isEmpty
                || !LibraryFeedsSectionRows.feeds(at: location, center: center).isEmpty
        }
    }

    /// The views the View pop-up offers a window showing `current`
    /// (`LibraryViewDefinitionList.offeredViews`), a view offered when
    /// applicable while `listsSomething(_:center:)` says so.
    func offeredViews(in list: LibraryViewDefinitionList, current: LibraryViewID?, center: FeedCenter) -> [LibraryViewDefinition] {
        list.offeredViews(current: current) { listsSomething($0, center: center) }
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
}
