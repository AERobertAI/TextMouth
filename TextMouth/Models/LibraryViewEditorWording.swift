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
    static var newTitle: String {
        String(localized: "New View",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The sheet's title for a new view.")
    }
    /// The sheet's title for a view being changed.
    static func editTitle(_ name: String) -> String {
        String(localized: "Edit \(name)",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The sheet's title for a view being changed. Placeholders in order: name.")
    }
    /// The Library tab's button that makes a view.
    static var newViewButton: String {
        String(localized: "New View…",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The Library tab's button that makes a view.")
    }
    /// Its hint.
    static var newViewHint: String {
        String(localized: "Makes a view of your own from the conditions you choose.",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Its hint.")
    }
    /// The Library tab's button that changes the view selected.
    static var editButton: String {
        String(localized: "Edit…",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The Library tab's button that changes the view selected.")
    }
    /// Its hint.
    static var editHint: String {
        String(localized: "Changes the view's name, what it lists, its conditions, its sort, and its limit.",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Its hint.")
    }
    /// Its hint for Folders and the Reading List, when it is dimmed.
    static var editDisabledHint: String {
        String(localized: "Folders and the Reading List list what they always have. You can move them, and hide the Reading List.",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Its hint for Folders and the Reading List, when it is dimmed.")
    }
    /// The button that closes the sheet, changing nothing.
    static var cancel: String {
        String(localized: "Cancel",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The button that closes the sheet, changing nothing.")
    }
    /// The button that saves the view.
    static var save: String {
        String(localized: "Save",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The button that saves the view.")
    }

    // MARK: - Name and Kinds

    /// The name field's label.
    static var nameLabel: String {
        String(localized: "Name",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The name field's label.")
    }
    /// The label of the checkboxes saying what the view lists.
    static var listsLabel: String {
        String(localized: "Lists",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The label of the checkboxes saying what the view lists.")
    }
    /// A kind of row as its checkbox names it: "Books", "Episodes",
    /// "Articles", or "Feeds".
    static func kindName(_ kind: LibraryViewItemKind) -> String {
        switch kind {
        case .books: return String(localized: "Books",
                            comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of row as its checkbox names it: \"Books\", \"Episodes\", \"Articles\", or \"Feeds\". This is the case .books.")
        case .episodes: return String(localized: "Episodes",
                               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of row as its checkbox names it: \"Books\", \"Episodes\", \"Articles\", or \"Feeds\". This is the case .episodes.")
        case .articles: return String(localized: "Articles",
                               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of row as its checkbox names it: \"Books\", \"Episodes\", \"Articles\", or \"Feeds\". This is the case .articles.")
        case .feeds: return String(localized: "Feeds",
                            comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of row as its checkbox names it: \"Books\", \"Episodes\", \"Articles\", or \"Feeds\". This is the case .feeds.")
        }
    }
    /// What conditions test, under the kinds.
    static var listsCaption: String {
        String(localized: "Conditions about books test books, episodes, and articles; conditions about feeds test feeds. A condition never hides a row it does not test.",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. What conditions test, under the kinds.")
    }

    // MARK: - Matching

    /// The match pop-up's label.
    static var matchLabel: String {
        String(localized: "Match",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The match pop-up's label.")
    }
    /// A match as its pop-up names it.
    static func matchName(_ match: LibraryViewMatch) -> String {
        match == .all ? String(localized: "All Conditions", comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A match as its pop-up names it. This is the form for the first case of the condition.") : String(localized: "Any Condition", comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A match as its pop-up names it. This is the form for the other case of the condition.")
    }

    // MARK: - Conditions

    /// The heading above the conditions.
    static var conditionsHeader: String {
        String(localized: "Conditions",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The heading above the conditions.")
    }
    /// What the editor says while the view has no condition.
    static var noConditions: String {
        String(localized: "No conditions: the view lists every item of the kinds chosen.",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. What the editor says while the view has no condition.")
    }
    /// A kind of test as a condition's test pop-up names it.
    static func testName(_ kind: LibraryViewCondition.Kind) -> String {
        switch kind {
        case .format: return String(localized: "Format",
                             comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .format.")
        case .folder: return String(localized: "Folder",
                             comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .folder.")
        case .readingState: return String(localized: "Reading State",
                                   comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .readingState.")
        case .inReadingList: return String(localized: "Reading List",
                                    comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .inReadingList.")
        case .addedWithin: return String(localized: "Date Added",
                                  comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .addedWithin.")
        case .openedWithin: return String(localized: "Date Opened",
                                   comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .openedWithin.")
        case .titleOrAuthorContains: return String(localized: "Title or Author",
                                            comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .titleOrAuthorContains.")
        case .hasNewItems: return String(localized: "New Items",
                                  comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .hasNewItems.")
        case .subscribed: return String(localized: "Subscription",
                                 comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .subscribed.")
        }
    }
    /// A condition's relation as its relation pop-up names it, by its test
    /// and whether it is negated.
    static func relationName(_ kind: LibraryViewCondition.Kind, isNegated: Bool) -> String {
        switch kind {
        case .format, .folder, .readingState:
            return isNegated ? String(localized: "Is Not", comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the first case of the condition.") : String(localized: "Is", comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the other case of the condition.")
        case .inReadingList:
            return isNegated ? String(localized: "Not in the Reading List", comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the first case of the condition.") : String(localized: "In the Reading List", comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the other case of the condition.")
        case .addedWithin, .openedWithin:
            return isNegated ? String(localized: "Not Within the Last", comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the first case of the condition.") : String(localized: "Within the Last", comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the other case of the condition.")
        case .titleOrAuthorContains:
            return isNegated ? String(localized: "Does Not Contain", comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the first case of the condition.") : String(localized: "Contains", comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the other case of the condition.")
        case .hasNewItems:
            return isNegated ? String(localized: "Has None New", comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the first case of the condition.") : String(localized: "Has New Episodes or Articles", comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the other case of the condition.")
        case .subscribed:
            return isNegated ? String(localized: "Unsubscribed", comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the first case of the condition.") : String(localized: "Subscribed", comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the other case of the condition.")
        }
    }
    /// A reading state as the pop-up names it.
    static func stateName(_ state: LibraryReadingState) -> String {
        switch state {
        case .unopened: return String(localized: "Unopened",
                               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A reading state as the pop-up names it. This is the case .unopened.")
        case .inProgress: return String(localized: "In Progress",
                                 comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A reading state as the pop-up names it. This is the case .inProgress.")
        case .finished: return String(localized: "Finished",
                               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A reading state as the pop-up names it. This is the case .finished.")
        }
    }
    /// The test pop-up's spoken label: "Condition 2".
    static func conditionLabel(_ number: Int) -> String {
        String(localized: "Condition \(String(number))",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The test pop-up's spoken label: \"Condition 2\". %@ is the condition's number, an identifier written without digit grouping.")
    }
    /// The relation pop-up's spoken label.
    static func relationLabel(_ number: Int) -> String {
        String(localized: "Condition \(String(number)) relation",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The relation pop-up's spoken label. %@ is the condition's number, an identifier written without digit grouping.")
    }
    /// The format pop-up's spoken label.
    static func formatLabel(_ number: Int) -> String {
        String(localized: "Condition \(String(number)) format",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The format pop-up's spoken label. %@ is the condition's number, an identifier written without digit grouping.")
    }
    /// The folder pop-up's spoken label.
    static func folderLabel(_ number: Int) -> String {
        String(localized: "Condition \(String(number)) folder",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The folder pop-up's spoken label. %@ is the condition's number, an identifier written without digit grouping.")
    }
    /// The subfolders checkbox's visible title.
    static var subfoldersTitle: String {
        String(localized: "Including Subfolders",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The subfolders checkbox's visible title.")
    }
    /// The subfolders checkbox's spoken label.
    static func subfoldersLabel(_ number: Int) -> String {
        String(localized: "Condition \(String(number)) includes subfolders",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The subfolders checkbox's spoken label. %@ is the condition's number, an identifier written without digit grouping.")
    }
    /// The reading state pop-up's spoken label.
    static func readingStateLabel(_ number: Int) -> String {
        String(localized: "Condition \(String(number)) reading state",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The reading state pop-up's spoken label. %@ is the condition's number, an identifier written without digit grouping.")
    }
    /// The days field's spoken label.
    static func daysLabel(_ number: Int) -> String {
        String(localized: "Condition \(String(number)) days",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The days field's spoken label. %@ is the condition's number, an identifier written without digit grouping.")
    }
    /// The caption after the days field.
    static var daysCaption: String {
        String(localized: "days",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The caption after the days field.")
    }
    /// The text field's spoken label.
    static func textLabel(_ number: Int) -> String {
        String(localized: "Condition \(String(number)) text",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The text field's spoken label. %@ is the condition's number, an identifier written without digit grouping.")
    }
    /// The remove button's visible title.
    static var removeTitle: String {
        String(localized: "Remove",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The remove button's visible title.")
    }
    /// The remove button's spoken label.
    static func removeLabel(_ number: Int) -> String {
        String(localized: "Remove condition \(String(number))",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The remove button's spoken label. %@ is the condition's number, an identifier written without digit grouping.")
    }
    /// The button that adds a condition.
    static var addCondition: String {
        String(localized: "Add Condition",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The button that adds a condition.")
    }
    /// Its hint at the limit, when it is dimmed.
    static var conditionLimitHint: String {
        String(localized: "A view holds at most \(LibraryViewFilter.conditionLimit) conditions.",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Its hint at the limit, when it is dimmed. Placeholders in order: LibraryViewFilter.conditionLimit.")
    }

    // MARK: - After the Conditions

    /// The checkbox that keeps one item per feed.
    static var onePerFeedTitle: String {
        String(localized: "Only the Latest from Each Feed",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The checkbox that keeps one item per feed.")
    }
    /// Its hint.
    static var onePerFeedHint: String {
        String(localized: "Of each feed's episodes and articles, lists only the one you opened last.",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Its hint.")
    }
    /// Its hint while the view lists no episodes or articles, when it is
    /// dimmed (review of October 31, 2026, finding 6).
    static var onePerFeedUnavailableHint: String {
        String(localized: "Applies only to a view that lists episodes or articles.",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Its hint while the view lists no episodes or articles, when it is dimmed (review of October 31, 2026, finding 6).")
    }
    /// Show at Most's hint while the view lists feeds alone, when it is
    /// dimmed (finding 6).
    static var limitUnavailableHint: String {
        String(localized: "A limit chooses among books, episodes, and articles, never feeds.",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Show at Most's hint while the view lists feeds alone, when it is dimmed (finding 6).")
    }
    /// The sort field pop-up's label.
    static var sortByLabel: String {
        String(localized: "Sort By",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The sort field pop-up's label.")
    }
    /// The direction pop-up's label.
    static var orderLabel: String {
        String(localized: "Order",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The direction pop-up's label.")
    }
    /// A direction as the pop-up names it.
    static func orderName(ascending: Bool) -> String {
        ascending ? String(localized: "Ascending", comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A direction as the pop-up names it. This is the form for the first case of the condition.") : String(localized: "Descending", comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A direction as the pop-up names it. This is the form for the other case of the condition.")
    }
    /// What stands for the sort while the view lists feeds alone.
    static var feedsOnlySortNote: String {
        let hint = LibraryViewPickerWording.feedsOrderHint
        return String(localized: "\(hint).",
                      comment: "Library view editor: the note shown in place of the sort choice while the view lists feeds alone. %@ is a sentence without its full stop, saying feeds are always listed by title; this adds the full stop.")
    }
    /// The limit checkbox.
    static var limitTitle: String {
        String(localized: "Show at Most",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The limit checkbox.")
    }
    /// The limit field's spoken label.
    static var limitFieldLabel: String {
        String(localized: "Most rows shown",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The limit field's spoken label.")
    }
    /// The pop-up of which rows a limit keeps.
    static var chosenByLabel: String {
        String(localized: "Chosen By",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The pop-up of which rows a limit keeps.")
    }
    /// A limit's order as its pop-up names it.
    static func limitOrderName(_ order: LibraryViewLimit.Order) -> String {
        switch order {
        case .lastOpened: return String(localized: "Opened Last",
                                 comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A limit's order as its pop-up names it. This is the case .lastOpened.")
        case .dateAdded: return String(localized: "Added Last",
                                comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A limit's order as its pop-up names it. This is the case .dateAdded.")
        case .viewSort: return String(localized: "First in the Sort",
                               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A limit's order as its pop-up names it. This is the case .viewSort.")
        }
    }

    // MARK: - Problems and Announcements

    /// Save's problem with no name.
    static var nameMissing: String {
        String(localized: "Give the view a name.",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Save's problem with no name.")
    }
    /// Save's problem with a name too long.
    static var nameTooLong: String {
        String(localized: "A view's name can be at most \(LibraryViewDefinition.nameLimit) characters.",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Save's problem with a name too long. Placeholders in order: LibraryViewDefinition.nameLimit.")
    }
    /// Save's problem with a name another view has.
    static func nameTaken(_ name: String) -> String {
        String(localized: "Another view is already named \(name). Choose another name.",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Save's problem with a name another view has. Placeholders in order: name.")
    }
    /// Save's problem with no kind listed.
    static var nothingListed: String {
        String(localized: "Choose at least one kind of item for the view to list.",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Save's problem with no kind listed.")
    }
    /// Save's problem with a title or author condition looking for nothing.
    static func textMissing(_ number: Int) -> String {
        String(localized: "Condition \(String(number)) needs the text to look for.",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Save's problem with a title or author condition looking for nothing. %@ is the condition's number, an identifier written without digit grouping.")
    }
    /// What VoiceOver says once a changed view is saved.
    static func saved(_ name: String) -> String {
        String(localized: "Saved \(name).",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. What VoiceOver says once a changed view is saved. Placeholders in order: name.")
    }
    /// What VoiceOver says once a new view is added, with its place.
    static func added(_ name: String, number: Int, count: Int) -> String {
        String(localized: "Added \(name), \(number) of \(count).",
               comment: "Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. What VoiceOver says once a new view is added, with its place. Placeholders in order: name, number, count.")
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
        if episodes > 0 { parts.append(CountWording.episodes(episodes)) }
        if articles > 0 { parts.append(CountWording.articles(articles)) }
        if feeds > 0 { parts.append(CountWording.feeds(feeds)) }
        if parts.isEmpty {
            return String(localized: "Lists nothing now.",
                          comment: "Library view editor: what the sheet says of a draft view that lists nothing at the moment.")
        }
        let list = CountWording.list(parts)
        return String(localized: "Lists \(list).",
                      comment: "Library view editor: what the sheet says of a draft view's contents. %@ is a list of counts, such as \"23 books and 2 feeds\".")
    }

    // MARK: - A Filter Described

    /// A filter as the Library tab's row hint describes it: "Lists books and
    /// feeds: reading state is Unopened and has new episodes or articles."
    /// The kinds, then the conditions joined by "and" (All) or "or" (Any),
    /// then "only the latest from each feed" and the limit, as they apply.
    /// `folderName` names a folder condition's folder: Library Root for nil,
    /// a folder's path, or that it is no longer in the library.
    static func description(of filter: LibraryViewFilter, folderName: (UUID?) -> String) -> String {
        let kinds = CountWording.list(
            LibraryViewItemKind.allCases.filter(filter.lists.contains).map { kindNameInSentence($0) })
        let conditions = filter.conditions.map { phrase(of: $0, folderName: folderName) }
        // The sentence's main clause: the kinds, then the conditions when there are any.
        var text: String
        if conditions.isEmpty {
            text = String(localized: "Lists \(kinds)",
                          comment: "Library view editor: the start of a filter's description, which says what a view lists. %@ is a list of the kinds it lists in lower case, such as \"books and feeds\". A description ends with a full stop added later.")
        } else {
            let list = filter.match == .all ? CountWording.list(conditions) : listWithOr(conditions)
            text = String(localized: "Lists \(kinds): \(list)",
                          comment: "Library view editor: the start of a filter's description, which says what a view lists and its conditions. %1$@ is a list of the kinds it lists in lower case, such as \"books and feeds\"; %2$@ is its conditions joined by \"and\" or \"or\". A description ends with a full stop added later.")
        }
        // One per feed and a limit are said only where they apply (review of
        // October 31, 2026, finding 6), each after a semicolon.
        var tails: [String] = []
        if filter.onePerFeed, !filter.lists.isDisjoint(with: [.episodes, .articles]) {
            tails.append(String(localized: "only the latest from each feed",
                                comment: "Library view editor: a clause at the end of a filter's description, said when the view lists only the newest item of each feed."))
        }
        if let limit = filter.limit, filter.listsItems {
            let order = limitOrderNameInSentence(limit.chosenBy)
            tails.append(String(localized: "at most \(limit.count), \(order)",
                                comment: "Library view editor: a clause at the end of a filter's description, said when the view shows only some rows. %1$lld is how many rows at most, a count; %2$@ is how they are chosen, in lower case, such as \"opened last\"."))
        }
        for tail in tails {
            text = String(localized: "\(text); \(tail)",
                          comment: "Library view editor: adds one more clause to a filter's description. %1$@ is the description so far and %2$@ the clause added after a semicolon.")
        }
        return String(localized: "\(text).",
                      comment: "Library view editor: ends a filter's description with a full stop. %@ is the whole description.")
    }

    /// A kind of row in lower case, inside a description: "books",
    /// "episodes", "articles", or "feeds".
    private static func kindNameInSentence(_ kind: LibraryViewItemKind) -> String {
        switch kind {
        case .books:
            return String(localized: "books", comment: "Library view editor: the kind of row books, in lower case inside a filter's description such as \"Lists books and feeds\".")
        case .episodes:
            return String(localized: "episodes", comment: "Library view editor: the kind of row podcast episodes, in lower case inside a filter's description such as \"Lists books and episodes\".")
        case .articles:
            return String(localized: "articles", comment: "Library view editor: the kind of row news articles, in lower case inside a filter's description such as \"Lists books and articles\".")
        case .feeds:
            return String(localized: "feeds", comment: "Library view editor: the kind of row feeds, in lower case inside a filter's description such as \"Lists books and feeds\".")
        }
    }

    /// A limit's order in lower case, inside a description: "opened last",
    /// "added last", or "first in the sort".
    private static func limitOrderNameInSentence(_ order: LibraryViewLimit.Order) -> String {
        switch order {
        case .lastOpened:
            return String(localized: "opened last", comment: "Library view editor: how a view's limit chooses rows, in lower case inside a filter's description: the books opened most recently.")
        case .dateAdded:
            return String(localized: "added last", comment: "Library view editor: how a view's limit chooses rows, in lower case inside a filter's description: the items added most recently.")
        case .viewSort:
            return String(localized: "first in the sort", comment: "Library view editor: how a view's limit chooses rows, in lower case inside a filter's description: the first rows of the view's own sort.")
        }
    }

    /// The name a folder condition gives a folder no longer in the library.
    static var missingFolder: String {
        String(localized: "a folder no longer in the library",
               comment: "Library view editor: the name a folder condition gives a folder that is no longer in the library, inside a filter's description such as \"folder is a folder no longer in the library\".")
    }

    /// One condition as a description says it: "format is EPUB", "not opened
    /// within the last 30 days". Each case, negated or not, is one whole
    /// string, so a language orders its words as it needs.
    static func phrase(of condition: LibraryViewCondition, folderName: (UUID?) -> String) -> String {
        let not = condition.isNegated
        switch condition.test {
        case .format(let format):
            let name = format.displayName
            return not
                ? String(localized: "format is not \(name)",
                         comment: "Library view editor: a condition inside a filter's description. %@ is a book format's name, such as EPUB.")
                : String(localized: "format is \(name)",
                         comment: "Library view editor: a condition inside a filter's description. %@ is a book format's name, such as EPUB.")
        case .folder(let id, let includingSubfolders):
            let name = folderName(id)
            switch (not, includingSubfolders) {
            case (false, false):
                return String(localized: "folder is \(name)",
                              comment: "Library view editor: a condition inside a filter's description. %@ is a library folder's path, Library Root, or a note that it is gone.")
            case (false, true):
                return String(localized: "folder is \(name), including subfolders",
                              comment: "Library view editor: a condition inside a filter's description. %@ is a library folder's path, Library Root, or a note that it is gone. The folders below it count too.")
            case (true, false):
                return String(localized: "folder is not \(name)",
                              comment: "Library view editor: a condition inside a filter's description. %@ is a library folder's path, Library Root, or a note that it is gone.")
            case (true, true):
                return String(localized: "folder is not \(name), including subfolders",
                              comment: "Library view editor: a condition inside a filter's description. %@ is a library folder's path, Library Root, or a note that it is gone. The folders below it count too.")
            }
        case .readingState(let state):
            let name = stateName(state)
            return not
                ? String(localized: "reading state is not \(name)",
                         comment: "Library view editor: a condition inside a filter's description. %@ is a reading state's name: Unopened, In Progress, or Finished.")
                : String(localized: "reading state is \(name)",
                         comment: "Library view editor: a condition inside a filter's description. %@ is a reading state's name: Unopened, In Progress, or Finished.")
        case .inReadingList:
            return not
                ? String(localized: "not in the reading list",
                         comment: "Library view editor: a condition inside a filter's description: the item is not in the Reading List.")
                : String(localized: "in the reading list",
                         comment: "Library view editor: a condition inside a filter's description: the item is in the Reading List.")
        case .addedWithin(let days):
            return addedPhrase(days: days, negated: not)
        case .openedWithin(let days):
            return openedPhrase(days: days, negated: not)
        case .titleOrAuthorContains(let text):
            return not
                ? String(localized: "title or author does not contain “\(text)”",
                         comment: "Library view editor: a condition inside a filter's description. %@ is the text the listener typed to look for.")
                : String(localized: "title or author contains “\(text)”",
                         comment: "Library view editor: a condition inside a filter's description. %@ is the text the listener typed to look for.")
        case .hasNewItems:
            return not
                ? String(localized: "has none new",
                         comment: "Library view editor: a condition inside a filter's description: a feed has no new episodes or articles.")
                : String(localized: "has new episodes or articles",
                         comment: "Library view editor: a condition inside a filter's description: a feed has new episodes or articles.")
        case .subscribed:
            return not
                ? String(localized: "unsubscribed",
                         comment: "Library view editor: a condition inside a filter's description: the listener is not subscribed to the feed.")
                : String(localized: "subscribed",
                         comment: "Library view editor: a condition inside a filter's description: the listener is subscribed to the feed.")
        }
    }

    /// "added today" for one day, else "added within the last 7 days", with
    /// "not " in front when negated: whole strings, one for each case.
    private static func addedPhrase(days: Int, negated: Bool) -> String {
        switch (negated, days == 1) {
        case (false, true):
            return String(localized: "added today",
                          comment: "Library view editor: a condition inside a filter's description: the item was added today.")
        case (true, true):
            return String(localized: "not added today",
                          comment: "Library view editor: a condition inside a filter's description: the item was not added today.")
        case (false, false):
            return String(localized: "added within the last \(days) days",
                          comment: "Library view editor: a condition inside a filter's description. %lld is a number of days, a count.")
        case (true, false):
            return String(localized: "not added within the last \(days) days",
                          comment: "Library view editor: a condition inside a filter's description. %lld is a number of days, a count.")
        }
    }

    /// "opened today" for one day, else "opened within the last 7 days",
    /// with "not " in front when negated.
    private static func openedPhrase(days: Int, negated: Bool) -> String {
        switch (negated, days == 1) {
        case (false, true):
            return String(localized: "opened today",
                          comment: "Library view editor: a condition inside a filter's description: the book was opened today.")
        case (true, true):
            return String(localized: "not opened today",
                          comment: "Library view editor: a condition inside a filter's description: the book was not opened today.")
        case (false, false):
            return String(localized: "opened within the last \(days) days",
                          comment: "Library view editor: a condition inside a filter's description. %lld is a number of days, a count.")
        case (true, false):
            return String(localized: "not opened within the last \(days) days",
                          comment: "Library view editor: a condition inside a filter's description. %lld is a number of days, a count.")
        }
    }

    /// `items` joined as `CountWording.list` joins them, with "or" where it
    /// says "and": "A", "A or B", "A, B, or C", in the region's list style.
    static func listWithOr(_ items: [String], locale: Locale = .current) -> String {
        items.formatted(.list(type: .or).locale(locale))
    }
}
