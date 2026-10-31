import Foundation

/// What the view editor says (the design of October 30, 2026,
/// LIBRARY-VIEWS-RESEARCH-2026-10-30.md, section 9, "The editor"): every
/// label, item, hint, error, and announcement of the sheet that makes and
/// changes a view, the count of what a draft lists, and the description of a
/// filter the Library tab's rows give as their hints. The same words on
/// screen, to VoiceOver, and on a braille display.
enum LibraryViewEditorWording {
    // MARK: - The Sheet and the Tab's Buttons

    /// The sheet's title for a new view.
    static let newTitle = "New View"
    /// The sheet's title for a view being changed.
    static func editTitle(_ name: String) -> String {
        "Edit \(name)"
    }
    /// The Library tab's button that makes a view.
    static let newViewButton = "New View…"
    /// Its hint.
    static let newViewHint = "Makes a view of your own from the conditions you choose."
    /// The Library tab's button that changes the view selected.
    static let editButton = "Edit…"
    /// Its hint.
    static let editHint = "Changes the view's name, what it lists, its conditions, its sort, and its limit."
    /// Its hint for Folders and the Reading List, when it is dimmed.
    static let editDisabledHint = "Folders and the Reading List list what they always have. "
        + "You can move them, and hide the Reading List."
    /// The button that closes the sheet, changing nothing.
    static let cancel = "Cancel"
    /// The button that saves the view.
    static let save = "Save"

    // MARK: - Name and Kinds

    /// The name field's label.
    static let nameLabel = "Name"
    /// The label of the checkboxes saying what the view lists.
    static let listsLabel = "Lists"
    /// A kind of row as its checkbox names it: "Books", "Episodes",
    /// "Articles", or "Feeds".
    static func kindName(_ kind: LibraryViewItemKind) -> String {
        switch kind {
        case .books: return "Books"
        case .episodes: return "Episodes"
        case .articles: return "Articles"
        case .feeds: return "Feeds"
        }
    }
    /// What conditions test, under the kinds.
    static let listsCaption = "Conditions about books test books, episodes, and articles; conditions about feeds "
        + "test feeds. A condition never hides a row it does not test."

    // MARK: - Matching

    /// The match pop-up's label.
    static let matchLabel = "Match"
    /// A match as its pop-up names it.
    static func matchName(_ match: LibraryViewMatch) -> String {
        match == .all ? "All Conditions" : "Any Condition"
    }

    // MARK: - Conditions

    /// The heading above the conditions.
    static let conditionsHeader = "Conditions"
    /// What the editor says while the view has no condition.
    static let noConditions = "No conditions: the view lists every item of the kinds chosen."
    /// A kind of test as a condition's test pop-up names it.
    static func testName(_ kind: LibraryViewCondition.Kind) -> String {
        switch kind {
        case .format: return "Format"
        case .folder: return "Folder"
        case .readingState: return "Reading State"
        case .inReadingList: return "Reading List"
        case .addedWithin: return "Date Added"
        case .openedWithin: return "Date Opened"
        case .titleOrAuthorContains: return "Title or Author"
        case .hasNewItems: return "New Items"
        case .subscribed: return "Subscription"
        }
    }
    /// A condition's relation as its relation pop-up names it, by its test
    /// and whether it is negated.
    static func relationName(_ kind: LibraryViewCondition.Kind, isNegated: Bool) -> String {
        switch kind {
        case .format, .folder, .readingState:
            return isNegated ? "Is Not" : "Is"
        case .inReadingList:
            return isNegated ? "Not in the Reading List" : "In the Reading List"
        case .addedWithin, .openedWithin:
            return isNegated ? "Not Within the Last" : "Within the Last"
        case .titleOrAuthorContains:
            return isNegated ? "Does Not Contain" : "Contains"
        case .hasNewItems:
            return isNegated ? "Has None New" : "Has New Episodes or Articles"
        case .subscribed:
            return isNegated ? "Unsubscribed" : "Subscribed"
        }
    }
    /// A reading state as the pop-up names it.
    static func stateName(_ state: LibraryReadingState) -> String {
        switch state {
        case .unopened: return "Unopened"
        case .inProgress: return "In Progress"
        case .finished: return "Finished"
        }
    }
    /// The test pop-up's spoken label: "Condition 2".
    static func conditionLabel(_ number: Int) -> String {
        "Condition \(number)"
    }
    /// The relation pop-up's spoken label.
    static func relationLabel(_ number: Int) -> String {
        "Condition \(number) relation"
    }
    /// The format pop-up's spoken label.
    static func formatLabel(_ number: Int) -> String {
        "Condition \(number) format"
    }
    /// The folder pop-up's spoken label.
    static func folderLabel(_ number: Int) -> String {
        "Condition \(number) folder"
    }
    /// The subfolders checkbox's visible title.
    static let subfoldersTitle = "Including Subfolders"
    /// The subfolders checkbox's spoken label.
    static func subfoldersLabel(_ number: Int) -> String {
        "Condition \(number) includes subfolders"
    }
    /// The reading state pop-up's spoken label.
    static func readingStateLabel(_ number: Int) -> String {
        "Condition \(number) reading state"
    }
    /// The days field's spoken label.
    static func daysLabel(_ number: Int) -> String {
        "Condition \(number) days"
    }
    /// The caption after the days field.
    static let daysCaption = "days"
    /// The text field's spoken label.
    static func textLabel(_ number: Int) -> String {
        "Condition \(number) text"
    }
    /// The remove button's visible title.
    static let removeTitle = "Remove"
    /// The remove button's spoken label.
    static func removeLabel(_ number: Int) -> String {
        "Remove condition \(number)"
    }
    /// The button that adds a condition.
    static let addCondition = "Add Condition"
    /// Its hint at the limit, when it is dimmed.
    static let conditionLimitHint = "A view holds at most \(LibraryViewFilter.conditionLimit) conditions."

    // MARK: - After the Conditions

    /// The checkbox that keeps one item per feed.
    static let onePerFeedTitle = "Only the Latest from Each Feed"
    /// Its hint.
    static let onePerFeedHint = "Of each feed's episodes and articles, lists only the one you opened last."
    /// The sort field pop-up's label.
    static let sortByLabel = "Sort By"
    /// The direction pop-up's label.
    static let orderLabel = "Order"
    /// A direction as the pop-up names it.
    static func orderName(ascending: Bool) -> String {
        ascending ? "Ascending" : "Descending"
    }
    /// What stands for the sort while the view lists feeds alone.
    static let feedsOnlySortNote = LibraryViewPickerWording.feedsOrderHint + "."
    /// The limit checkbox.
    static let limitTitle = "Show at Most"
    /// The limit field's spoken label.
    static let limitFieldLabel = "Most rows shown"
    /// The pop-up of which rows a limit keeps.
    static let chosenByLabel = "Chosen By"
    /// A limit's order as its pop-up names it.
    static func limitOrderName(_ order: LibraryViewLimit.Order) -> String {
        switch order {
        case .lastOpened: return "Opened Last"
        case .dateAdded: return "Added Last"
        case .viewSort: return "First in the Sort"
        }
    }

    // MARK: - Problems and Announcements

    /// Save's problem with no name.
    static let nameMissing = "Give the view a name."
    /// Save's problem with a name too long.
    static let nameTooLong = "A view's name can be at most \(LibraryViewDefinition.nameLimit) characters."
    /// Save's problem with a name another view has.
    static func nameTaken(_ name: String) -> String {
        "Another view is already named \(name). Choose another name."
    }
    /// Save's problem with no kind listed.
    static let nothingListed = "Choose at least one kind of item for the view to list."
    /// Save's problem with a title or author condition looking for nothing.
    static func textMissing(_ number: Int) -> String {
        "Condition \(number) needs the text to look for."
    }
    /// What VoiceOver says once a changed view is saved.
    static func saved(_ name: String) -> String {
        "Saved \(name)."
    }
    /// What VoiceOver says once a new view is added, with its place.
    static func added(_ name: String, number: Int, count: Int) -> String {
        "Added \(name), \(number) of \(count)."
    }

    // MARK: - The Count

    /// What a draft lists now: "Lists 23 books and 2 feeds.", each kind by
    /// its own noun (`CountWording`), rows told apart by `Book.listedKind`;
    /// "Lists nothing now." when it lists nothing.
    static func count(of rows: [Book], feeds: Int) -> String {
        var books = 0, episodes = 0, articles = 0
        for row in rows {
            switch row.listedKind {
            case .books: books += 1
            case .episodes: episodes += 1
            case .articles: articles += 1
            case .feeds: break
            }
        }
        var parts: [String] = []
        if books > 0 { parts.append(CountWording.books(books)) }
        if episodes > 0 { parts.append(CountWording.phrase(episodes, singular: "episode", plural: "episodes")) }
        if articles > 0 { parts.append(CountWording.phrase(articles, singular: "article", plural: "articles")) }
        if feeds > 0 { parts.append(CountWording.feeds(feeds)) }
        return parts.isEmpty ? "Lists nothing now." : "Lists \(CountWording.list(parts))."
    }

    // MARK: - A Filter Described

    /// A filter as the Library tab's row hint describes it: "Lists books and
    /// feeds: reading state is Unopened and has new episodes or articles."
    /// The kinds, then the conditions joined by "and" (All) or "or" (Any),
    /// then "only the latest from each feed" and the limit, as they apply.
    /// `folderName` names a folder condition's folder: Library Root for nil,
    /// a folder's path, or that it is no longer in the library.
    static func description(of filter: LibraryViewFilter, folderName: (UUID?) -> String) -> String {
        let kinds = LibraryViewItemKind.allCases.filter(filter.lists.contains).map { kindName($0).lowercased() }
        var text = "Lists \(CountWording.list(kinds))"
        let conditions = filter.conditions.map { phrase(of: $0, folderName: folderName) }
        if !conditions.isEmpty {
            text += ": " + (filter.match == .all ? CountWording.list(conditions) : listWithOr(conditions))
        }
        if filter.onePerFeed {
            text += "; only the latest from each feed"
        }
        if let limit = filter.limit {
            text += "; at most \(limit.count), \(limitOrderName(limit.chosenBy).lowercased())"
        }
        return text + "."
    }

    /// The name a folder condition gives a folder no longer in the library.
    static let missingFolder = "a folder no longer in the library"

    /// One condition as a description says it: "format is EPUB", "not opened
    /// within the last 30 days".
    static func phrase(of condition: LibraryViewCondition, folderName: (UUID?) -> String) -> String {
        let not = condition.isNegated
        switch condition.test {
        case .format(let format):
            return "format \(not ? "is not" : "is") \(format.displayName)"
        case .folder(let id, let includingSubfolders):
            return "folder \(not ? "is not" : "is") \(folderName(id))" + (includingSubfolders ? ", including subfolders" : "")
        case .readingState(let state):
            return "reading state \(not ? "is not" : "is") \(stateName(state))"
        case .inReadingList:
            return not ? "not in the reading list" : "in the reading list"
        case .addedWithin(let days):
            return (not ? "not " : "") + "added " + withinDays(days)
        case .openedWithin(let days):
            return (not ? "not " : "") + "opened " + withinDays(days)
        case .titleOrAuthorContains(let text):
            return "title or author \(not ? "does not contain" : "contains") “\(text)”"
        case .hasNewItems:
            return not ? "has none new" : "has new episodes or articles"
        case .subscribed:
            return not ? "unsubscribed" : "subscribed"
        }
    }

    /// "today" for one day, else "within the last 7 days".
    private static func withinDays(_ days: Int) -> String {
        days == 1 ? "today" : "within the last \(days) days"
    }

    /// `items` joined as `CountWording.list` joins them, with "or" where it
    /// says "and": "A", "A or B", "A, B, or C".
    static func listWithOr(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) or \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", or " + (items.last ?? "")
        }
    }
}
