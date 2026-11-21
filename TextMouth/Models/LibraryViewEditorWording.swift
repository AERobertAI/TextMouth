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
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The sheet's title for a new view.
        String(localized: "New View")
    }
    /// The sheet's title for a view being changed.
    static func editTitle(_ name: String) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The sheet's title for a view being changed. Placeholders in order: name.
        String(localized: "Edit \(name)")
    }
    /// The Library tab's button that makes a view.
    static var newViewButton: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The Library tab's button that makes a view.
        String(localized: "New View…")
    }
    /// Its hint.
    static var newViewHint: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Its hint.
        String(localized: "Makes a view of your own from the conditions you choose.")
    }
    /// The Library tab's button that changes the view selected.
    static var editButton: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The Library tab's button that changes the view selected.
        String(localized: "Edit…")
    }
    /// Its hint.
    static var editHint: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Its hint.
        String(localized: "Changes the view's name, what it lists, its conditions, its sort, and its limit.")
    }
    /// Its hint for Folders and the Reading List, when it is dimmed.
    static var editDisabledHint: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Its hint for Folders and the Reading List, when it is dimmed.
        String(localized: "Folders and the Reading List list what they always have. You can move them, and hide the Reading List.")
    }
    /// The button that closes the sheet, changing nothing.
    static var cancel: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The button that closes the sheet, changing nothing.
        String(localized: "Cancel")
    }
    /// The button that saves the view.
    static var save: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The button that saves the view.
        String(localized: "Save")
    }

    // MARK: - Name and Kinds

    /// The name field's label.
    static var nameLabel: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The name field's label.
        String(localized: "Name")
    }
    /// The label of the checkboxes saying what the view lists.
    static var listsLabel: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The label of the checkboxes saying what the view lists.
        String(localized: "Lists")
    }
    /// A kind of row as its checkbox names it: "Books", "Episodes",
    /// "Articles", or "Feeds".
    static func kindName(_ kind: LibraryViewItemKind) -> String {
        switch kind {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of row as its checkbox names it: "Books", "Episodes", "Articles", or "Feeds". This is the case .books.
        case .books: return String(localized: "Books")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of row as its checkbox names it: "Books", "Episodes", "Articles", or "Feeds". This is the case .episodes.
        case .episodes: return String(localized: "Episodes")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of row as its checkbox names it: "Books", "Episodes", "Articles", or "Feeds". This is the case .articles.
        case .articles: return String(localized: "Articles")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of row as its checkbox names it: "Books", "Episodes", "Articles", or "Feeds". This is the case .feeds.
        case .feeds: return String(localized: "Feeds")
        }
    }
    /// What conditions test, under the kinds.
    static var listsCaption: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. What conditions test, under the kinds.
        String(localized: "Conditions about books test books, episodes, and articles; conditions about feeds test feeds. A condition never hides a row it does not test.")
    }

    // MARK: - Matching

    /// The match pop-up's label.
    static var matchLabel: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The match pop-up's label.
        String(localized: "Match")
    }
    /// A match as its pop-up names it.
    static func matchName(_ match: LibraryViewMatch) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A match as its pop-up names it. This is the form for the first case of the condition.
        match == .all ? String(localized: "All Conditions") :
            // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A match as its pop-up names it. This is the form for the other case of the condition.
            String(localized: "Any Condition")
    }

    // MARK: - Conditions

    /// The heading above the conditions.
    static var conditionsHeader: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The heading above the conditions.
        String(localized: "Conditions")
    }
    /// What the editor says while the view has no condition.
    static var noConditions: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. What the editor says while the view has no condition.
        String(localized: "No conditions: the view lists every item of the kinds chosen.")
    }
    /// A kind of test as a condition's test pop-up names it.
    static func testName(_ kind: LibraryViewCondition.Kind) -> String {
        switch kind {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .format.
        case .format: return String(localized: "Format")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .folder.
        case .folder: return String(localized: "Folder")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .readingState.
        case .readingState: return String(localized: "Reading State")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .inReadingList.
        case .inReadingList: return String(localized: "Reading List")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .addedWithin.
        case .addedWithin: return String(localized: "Date Added")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .openedWithin.
        case .openedWithin: return String(localized: "Date Opened")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .titleOrAuthorContains.
        case .titleOrAuthorContains: return String(localized: "Title or Author")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .hasNewItems.
        case .hasNewItems: return String(localized: "New Items")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .subscribed.
        case .subscribed: return String(localized: "Subscription")
        }
    }
    /// A condition's relation as its relation pop-up names it, by its test
    /// and whether it is negated.
    static func relationName(_ kind: LibraryViewCondition.Kind, isNegated: Bool) -> String {
        switch kind {
        case .format, .folder, .readingState:
            // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the first case of the condition.
            return isNegated ? String(localized: "Is Not") :
                // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the other case of the condition.
                String(localized: "Is")
        case .inReadingList:
            // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the first case of the condition.
            return isNegated ? String(localized: "Not in the Reading List") :
                // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the other case of the condition.
                String(localized: "In the Reading List")
        case .addedWithin, .openedWithin:
            // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the first case of the condition.
            return isNegated ? String(localized: "Not Within the Last") :
                // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the other case of the condition.
                String(localized: "Within the Last")
        case .titleOrAuthorContains:
            // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the first case of the condition.
            return isNegated ? String(localized: "Does Not Contain") :
                // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the other case of the condition.
                String(localized: "Contains")
        case .hasNewItems:
            // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the first case of the condition.
            return isNegated ? String(localized: "Has None New") :
                // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the other case of the condition.
                String(localized: "Has New Episodes or Articles")
        case .subscribed:
            // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the first case of the condition.
            return isNegated ? String(localized: "Unsubscribed") :
                // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the other case of the condition.
                String(localized: "Subscribed")
        }
    }
    /// A reading state as the pop-up names it.
    static func stateName(_ state: LibraryReadingState) -> String {
        switch state {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A reading state as the pop-up names it. This is the case .unopened.
        case .unopened: return String(localized: "Unopened")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A reading state as the pop-up names it. This is the case .inProgress.
        case .inProgress: return String(localized: "In Progress")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A reading state as the pop-up names it. This is the case .finished.
        case .finished: return String(localized: "Finished")
        }
    }
    /// The test pop-up's spoken label: "Condition 2".
    static func conditionLabel(_ number: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The test pop-up's spoken label: "Condition 2". %@ is the condition's number, an identifier written without digit grouping.
        String(localized: "Condition \(String(number))")
    }
    /// The relation pop-up's spoken label.
    static func relationLabel(_ number: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The relation pop-up's spoken label. %@ is the condition's number, an identifier written without digit grouping.
        String(localized: "Condition \(String(number)) relation")
    }
    /// The format pop-up's spoken label.
    static func formatLabel(_ number: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The format pop-up's spoken label. %@ is the condition's number, an identifier written without digit grouping.
        String(localized: "Condition \(String(number)) format")
    }
    /// The folder pop-up's spoken label.
    static func folderLabel(_ number: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The folder pop-up's spoken label. %@ is the condition's number, an identifier written without digit grouping.
        String(localized: "Condition \(String(number)) folder")
    }
    /// The subfolders checkbox's visible title.
    static var subfoldersTitle: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The subfolders checkbox's visible title.
        String(localized: "Including Subfolders")
    }
    /// The subfolders checkbox's spoken label.
    static func subfoldersLabel(_ number: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The subfolders checkbox's spoken label. %@ is the condition's number, an identifier written without digit grouping.
        String(localized: "Condition \(String(number)) includes subfolders")
    }
    /// The reading state pop-up's spoken label.
    static func readingStateLabel(_ number: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The reading state pop-up's spoken label. %@ is the condition's number, an identifier written without digit grouping.
        String(localized: "Condition \(String(number)) reading state")
    }
    /// The days field's spoken label.
    static func daysLabel(_ number: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The days field's spoken label. %@ is the condition's number, an identifier written without digit grouping.
        String(localized: "Condition \(String(number)) days")
    }
    /// The caption after the days field.
    static var daysCaption: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The caption after the days field.
        String(localized: "days")
    }
    /// The text field's spoken label.
    static func textLabel(_ number: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The text field's spoken label. %@ is the condition's number, an identifier written without digit grouping.
        String(localized: "Condition \(String(number)) text")
    }
    /// The remove button's visible title.
    static var removeTitle: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The remove button's visible title.
        String(localized: "Remove")
    }
    /// The remove button's spoken label.
    static func removeLabel(_ number: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The remove button's spoken label. %@ is the condition's number, an identifier written without digit grouping.
        String(localized: "Remove condition \(String(number))")
    }
    /// The button that adds a condition.
    static var addCondition: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The button that adds a condition.
        String(localized: "Add Condition")
    }
    /// Its hint at the limit, when it is dimmed.
    static var conditionLimitHint: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Its hint at the limit, when it is dimmed. Placeholders in order: LibraryViewFilter.conditionLimit.
        String(localized: "A view holds at most \(LibraryViewFilter.conditionLimit) conditions.")
    }

    // MARK: - After the Conditions

    /// The checkbox that keeps one item per feed.
    static var onePerFeedTitle: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The checkbox that keeps one item per feed.
        String(localized: "Only the Latest from Each Feed")
    }
    /// Its hint.
    static var onePerFeedHint: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Its hint.
        String(localized: "Of each feed's episodes and articles, lists only the one you opened last.")
    }
    /// Its hint while the view lists no episodes or articles, when it is
    /// dimmed (review of October 31, 2026, finding 6).
    static var onePerFeedUnavailableHint: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Its hint while the view lists no episodes or articles, when it is dimmed (review of October 31, 2026, finding 6).
        String(localized: "Applies only to a view that lists episodes or articles.")
    }
    /// Show at Most's hint while the view lists feeds alone, when it is
    /// dimmed (finding 6).
    static var limitUnavailableHint: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Show at Most's hint while the view lists feeds alone, when it is dimmed (finding 6).
        String(localized: "A limit chooses among books, episodes, and articles, never feeds.")
    }
    /// The sort field pop-up's label.
    static var sortByLabel: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The sort field pop-up's label.
        String(localized: "Sort By")
    }
    /// The direction pop-up's label.
    static var orderLabel: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The direction pop-up's label.
        String(localized: "Order")
    }
    /// A direction as the pop-up names it.
    static func orderName(ascending: Bool) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A direction as the pop-up names it. This is the form for the first case of the condition.
        ascending ? String(localized: "Ascending") :
            // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A direction as the pop-up names it. This is the form for the other case of the condition.
            String(localized: "Descending")
    }
    /// What stands for the sort while the view lists feeds alone.
    static var feedsOnlySortNote: String {
        let hint = LibraryViewPickerWording.feedsOrderHint
        // Translators: Library view editor: the note shown in place of the sort choice while the view lists feeds alone. %@ is a sentence without its full stop, saying feeds are always listed by title; this adds the full stop.
        return String(localized: "\(hint).")
    }
    /// The limit checkbox.
    static var limitTitle: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The limit checkbox.
        String(localized: "Show at Most")
    }
    /// The limit field's spoken label.
    static var limitFieldLabel: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The limit field's spoken label.
        String(localized: "Most rows shown")
    }
    /// The pop-up of which rows a limit keeps.
    static var chosenByLabel: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The pop-up of which rows a limit keeps.
        String(localized: "Chosen By")
    }
    /// A limit's order as its pop-up names it.
    static func limitOrderName(_ order: LibraryViewLimit.Order) -> String {
        switch order {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A limit's order as its pop-up names it. This is the case .lastOpened.
        case .lastOpened: return String(localized: "Opened Last")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A limit's order as its pop-up names it. This is the case .dateAdded.
        case .dateAdded: return String(localized: "Added Last")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A limit's order as its pop-up names it. This is the case .viewSort.
        case .viewSort: return String(localized: "First in the Sort")
        }
    }

    // MARK: - Problems and Announcements

    /// Save's problem with no name.
    static var nameMissing: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Save's problem with no name.
        String(localized: "Give the view a name.")
    }
    /// Save's problem with a name too long.
    static var nameTooLong: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Save's problem with a name too long. Placeholders in order: LibraryViewDefinition.nameLimit.
        String(localized: "A view's name can be at most \(LibraryViewDefinition.nameLimit) characters.")
    }
    /// Save's problem with a name another view has.
    static func nameTaken(_ name: String) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Save's problem with a name another view has. Placeholders in order: name.
        String(localized: "Another view is already named \(name). Choose another name.")
    }
    /// Save's problem with no kind listed.
    static var nothingListed: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Save's problem with no kind listed.
        String(localized: "Choose at least one kind of item for the view to list.")
    }
    /// Save's problem with a title or author condition looking for nothing.
    static func textMissing(_ number: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Save's problem with a title or author condition looking for nothing. %@ is the condition's number, an identifier written without digit grouping.
        String(localized: "Condition \(String(number)) needs the text to look for.")
    }
    /// What VoiceOver says once a changed view is saved.
    static func saved(_ name: String) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. What VoiceOver says once a changed view is saved. Placeholders in order: name.
        String(localized: "Saved \(name).")
    }
    /// What VoiceOver says once a new view is added, with its place.
    static func added(_ name: String, number: Int, count: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. What VoiceOver says once a new view is added, with its place. Placeholders in order: name, number, count.
        String(localized: "Added \(name), \(number) of \(count).")
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
            // Translators: Library view editor: what the sheet says of a draft view that lists nothing at the moment.
            return String(localized: "Lists nothing now.")
        }
        let list = CountWording.list(parts)
        // Translators: Library view editor: what the sheet says of a draft view's contents. %@ is a list of counts, such as "23 books and 2 feeds".
        return String(localized: "Lists \(list).")
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
            // Translators: Library view editor: the start of a filter's description, which says what a view lists. %@ is a list of the kinds it lists in lower case, such as "books and feeds". A description ends with a full stop added later.
            text = String(localized: "Lists \(kinds)")
        } else {
            let list = filter.match == .all ? CountWording.list(conditions) : listWithOr(conditions)
            // Translators: Library view editor: the start of a filter's description, which says what a view lists and its conditions. %1$@ is a list of the kinds it lists in lower case, such as "books and feeds"; %2$@ is its conditions joined by "and" or "or". A description ends with a full stop added later.
            text = String(localized: "Lists \(kinds): \(list)")
        }
        // One per feed and a limit are said only where they apply (review of
        // October 31, 2026, finding 6), each after a semicolon.
        var tails: [String] = []
        if filter.onePerFeed, !filter.lists.isDisjoint(with: [.episodes, .articles]) {
            // Translators: Library view editor: a clause at the end of a filter's description, said when the view lists only the newest item of each feed.
            tails.append(String(localized: "only the latest from each feed"))
        }
        if let limit = filter.limit, filter.listsItems {
            let order = limitOrderNameInSentence(limit.chosenBy)
            // Translators: Library view editor: a clause at the end of a filter's description, said when the view shows only some rows. %1$lld is how many rows at most, a count; %2$@ is how they are chosen, in lower case, such as "opened last".
            tails.append(String(localized: "at most \(limit.count), \(order)"))
        }
        for tail in tails {
            // Translators: Library view editor: adds one more clause to a filter's description. %1$@ is the description so far and %2$@ the clause added after a semicolon.
            text = String(localized: "\(text); \(tail)")
        }
        // Translators: Library view editor: ends a filter's description with a full stop. %@ is the whole description.
        return String(localized: "\(text).")
    }

    /// A kind of row in lower case, inside a description: "books",
    /// "episodes", "articles", or "feeds".
    private static func kindNameInSentence(_ kind: LibraryViewItemKind) -> String {
        switch kind {
        case .books:
            // Translators: Library view editor: the kind of row books, in lower case inside a filter's description such as "Lists books and feeds".
            return String(localized: "books")
        case .episodes:
            // Translators: Library view editor: the kind of row podcast episodes, in lower case inside a filter's description such as "Lists books and episodes".
            return String(localized: "episodes")
        case .articles:
            // Translators: Library view editor: the kind of row news articles, in lower case inside a filter's description such as "Lists books and articles".
            return String(localized: "articles")
        case .feeds:
            // Translators: Library view editor: the kind of row feeds, in lower case inside a filter's description such as "Lists books and feeds".
            return String(localized: "feeds")
        }
    }

    /// A limit's order in lower case, inside a description: "opened last",
    /// "added last", or "first in the sort".
    private static func limitOrderNameInSentence(_ order: LibraryViewLimit.Order) -> String {
        switch order {
        case .lastOpened:
            // Translators: Library view editor: how a view's limit chooses rows, in lower case inside a filter's description: the books opened most recently.
            return String(localized: "opened last")
        case .dateAdded:
            // Translators: Library view editor: how a view's limit chooses rows, in lower case inside a filter's description: the items added most recently.
            return String(localized: "added last")
        case .viewSort:
            // Translators: Library view editor: how a view's limit chooses rows, in lower case inside a filter's description: the first rows of the view's own sort.
            return String(localized: "first in the sort")
        }
    }

    /// The name a folder condition gives a folder no longer in the library.
    static var missingFolder: String {
        // Translators: Library view editor: the name a folder condition gives a folder that is no longer in the library, inside a filter's description such as "folder is a folder no longer in the library".
        String(localized: "a folder no longer in the library")
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
                // Translators: Library view editor: a condition inside a filter's description. %@ is a book format's name, such as EPUB.
                ? String(localized: "format is not \(name)")
                // Translators: Library view editor: a condition inside a filter's description. %@ is a book format's name, such as EPUB.
                : String(localized: "format is \(name)")
        case .folder(let id, let includingSubfolders):
            let name = folderName(id)
            switch (not, includingSubfolders) {
            case (false, false):
                // Translators: Library view editor: a condition inside a filter's description. %@ is a library folder's path, Library Root, or a note that it is gone.
                return String(localized: "folder is \(name)")
            case (false, true):
                // Translators: Library view editor: a condition inside a filter's description. %@ is a library folder's path, Library Root, or a note that it is gone. The folders below it count too.
                return String(localized: "folder is \(name), including subfolders")
            case (true, false):
                // Translators: Library view editor: a condition inside a filter's description. %@ is a library folder's path, Library Root, or a note that it is gone.
                return String(localized: "folder is not \(name)")
            case (true, true):
                // Translators: Library view editor: a condition inside a filter's description. %@ is a library folder's path, Library Root, or a note that it is gone. The folders below it count too.
                return String(localized: "folder is not \(name), including subfolders")
            }
        case .readingState(let state):
            let name = stateName(state)
            return not
                // Translators: Library view editor: a condition inside a filter's description. %@ is a reading state's name: Unopened, In Progress, or Finished.
                ? String(localized: "reading state is not \(name)")
                // Translators: Library view editor: a condition inside a filter's description. %@ is a reading state's name: Unopened, In Progress, or Finished.
                : String(localized: "reading state is \(name)")
        case .inReadingList:
            return not
                // Translators: Library view editor: a condition inside a filter's description: the item is not in the Reading List.
                ? String(localized: "not in the reading list")
                // Translators: Library view editor: a condition inside a filter's description: the item is in the Reading List.
                : String(localized: "in the reading list")
        case .addedWithin(let days):
            return addedPhrase(days: days, negated: not)
        case .openedWithin(let days):
            return openedPhrase(days: days, negated: not)
        case .titleOrAuthorContains(let text):
            return not
                // Translators: Library view editor: a condition inside a filter's description. %@ is the text the listener typed to look for.
                ? String(localized: "title or author does not contain “\(text)”")
                // Translators: Library view editor: a condition inside a filter's description. %@ is the text the listener typed to look for.
                : String(localized: "title or author contains “\(text)”")
        case .hasNewItems:
            return not
                // Translators: Library view editor: a condition inside a filter's description: a feed has no new episodes or articles.
                ? String(localized: "has none new")
                // Translators: Library view editor: a condition inside a filter's description: a feed has new episodes or articles.
                : String(localized: "has new episodes or articles")
        case .subscribed:
            return not
                // Translators: Library view editor: a condition inside a filter's description: the listener is not subscribed to the feed.
                ? String(localized: "unsubscribed")
                // Translators: Library view editor: a condition inside a filter's description: the listener is subscribed to the feed.
                : String(localized: "subscribed")
        }
    }

    /// "added today" for one day, else "added within the last 7 days", with
    /// "not " in front when negated: whole strings, one for each case.
    private static func addedPhrase(days: Int, negated: Bool) -> String {
        switch (negated, days == 1) {
        case (false, true):
            // Translators: Library view editor: a condition inside a filter's description: the item was added today.
            return String(localized: "added today")
        case (true, true):
            // Translators: Library view editor: a condition inside a filter's description: the item was not added today.
            return String(localized: "not added today")
        case (false, false):
            // Translators: Library view editor: a condition inside a filter's description. %lld is a number of days, a count.
            return String(localized: "added within the last \(days) days")
        case (true, false):
            // Translators: Library view editor: a condition inside a filter's description. %lld is a number of days, a count.
            return String(localized: "not added within the last \(days) days")
        }
    }

    /// "opened today" for one day, else "opened within the last 7 days",
    /// with "not " in front when negated.
    private static func openedPhrase(days: Int, negated: Bool) -> String {
        switch (negated, days == 1) {
        case (false, true):
            // Translators: Library view editor: a condition inside a filter's description: the book was opened today.
            return String(localized: "opened today")
        case (true, true):
            // Translators: Library view editor: a condition inside a filter's description: the book was not opened today.
            return String(localized: "not opened today")
        case (false, false):
            // Translators: Library view editor: a condition inside a filter's description. %lld is a number of days, a count.
            return String(localized: "opened within the last \(days) days")
        case (true, false):
            // Translators: Library view editor: a condition inside a filter's description. %lld is a number of days, a count.
            return String(localized: "not opened within the last \(days) days")
        }
    }

    /// `items` joined as `CountWording.list` joins them, with "or" where it
    /// says "and": "A", "A or B", "A, B, or C", in the region's list style.
    static func listWithOr(_ items: [String], locale: Locale = .current) -> String {
        items.formatted(.list(type: .or).locale(locale))
    }
}
