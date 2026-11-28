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
        InterfaceText.line("libraryViewEditor.newTitle", "New View")
    }
    /// The sheet's title for a view being changed.
    static func editTitle(_ name: String) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The sheet's title for a view being changed. Placeholders in order: name.
        InterfaceText.line("libraryViewEditor.editTitle", "Edit \(name)")
    }
    /// The Library tab's button that makes a view.
    static var newViewButton: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The Library tab's button that makes a view.
        InterfaceText.line("libraryViewEditor.newViewButton", "New View…")
    }
    /// Its hint.
    static var newViewHint: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Its hint.
        InterfaceText.line("libraryViewEditor.newViewHint", "Makes a view of your own from the conditions you choose.")
    }
    /// The Library tab's button that changes the view selected.
    static var editButton: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The Library tab's button that changes the view selected.
        InterfaceText.line("libraryViewEditor.editButton", "Edit…")
    }
    /// Its hint.
    static var editHint: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Its hint.
        InterfaceText.line("libraryViewEditor.editHint", "Changes the view's name, what it lists, its conditions, its sort, and its limit.")
    }
    /// Its hint for Folders and the Reading List, when it is dimmed.
    static var editDisabledHint: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Its hint for Folders and the Reading List, when it is dimmed.
        InterfaceText.line("libraryViewEditor.editDisabledHint", "Folders and the Reading List list what they always have. You can move them, and hide the Reading List.")
    }
    /// The button that closes the sheet, changing nothing.
    static var cancel: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The button that closes the sheet, changing nothing.
        InterfaceText.line("common.cancel", "Cancel")
    }
    /// The button that saves the view.
    static var save: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The button that saves the view.
        InterfaceText.line("common.save", "Save")
    }

    // MARK: - Name and Kinds

    /// The name field's label.
    static var nameLabel: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The name field's label.
        InterfaceText.line("common.name", "Name")
    }
    /// The label of the checkboxes saying what the view lists.
    static var listsLabel: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The label of the checkboxes saying what the view lists.
        InterfaceText.line("libraryViewEditor.listsLabel", "Lists")
    }
    /// A kind of row as its checkbox names it: "Books", "Episodes",
    /// "Articles", or "Feeds".
    static func kindName(_ kind: LibraryViewItemKind) -> String {
        switch kind {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of row as its checkbox names it: "Books", "Episodes", "Articles", or "Feeds". This is the case .books.
        case .books: return InterfaceText.line("common.books", "Books")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of row as its checkbox names it: "Books", "Episodes", "Articles", or "Feeds". This is the case .episodes.
        case .episodes: return InterfaceText.line("common.episodes", "Episodes")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of row as its checkbox names it: "Books", "Episodes", "Articles", or "Feeds". This is the case .articles.
        case .articles: return InterfaceText.line("common.articles", "Articles")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of row as its checkbox names it: "Books", "Episodes", "Articles", or "Feeds". This is the case .feeds.
        case .feeds: return InterfaceText.line("common.feeds", "Feeds")
        }
    }
    /// What conditions test, under the kinds.
    static var listsCaption: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. What conditions test, under the kinds.
        InterfaceText.line("libraryViewEditor.listsCaption", "Conditions about books test books, episodes, and articles; conditions about feeds test feeds. A condition never hides a row it does not test.")
    }

    // MARK: - Matching

    /// The match pop-up's label.
    static var matchLabel: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The match pop-up's label.
        InterfaceText.line("libraryViewEditor.matchLabel", "Match")
    }
    /// A match as its pop-up names it.
    static func matchName(_ match: LibraryViewMatch) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A match as its pop-up names it. This is the form for the first case of the condition.
        match == .all ? InterfaceText.line("libraryViewEditor.matchName.conditions", "All Conditions") :
            // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A match as its pop-up names it. This is the form for the other case of the condition.
            InterfaceText.line("libraryViewEditor.matchName.condition", "Any Condition")
    }

    // MARK: - Conditions

    /// The heading above the conditions.
    static var conditionsHeader: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The heading above the conditions.
        InterfaceText.line("libraryViewEditor.conditionsHeader", "Conditions")
    }
    /// What the editor says while the view has no condition.
    static var noConditions: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. What the editor says while the view has no condition.
        InterfaceText.line("libraryViewEditor.noConditions", "No conditions: the view lists every item of the kinds chosen.")
    }
    /// A kind of test as a condition's test pop-up names it.
    static func testName(_ kind: LibraryViewCondition.Kind) -> String {
        switch kind {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .format.
        case .format: return InterfaceText.line("common.format", "Format")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .folder.
        case .folder: return InterfaceText.line("common.folder", "Folder")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .readingState.
        case .readingState: return InterfaceText.line("libraryViewEditor.testName.readingState", "Reading State")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .inReadingList.
        case .inReadingList: return InterfaceText.line("common.readingList", "Reading List")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .addedWithin.
        case .addedWithin: return InterfaceText.line("common.dateAdded", "Date Added")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .openedWithin.
        case .openedWithin: return InterfaceText.line("libraryViewEditor.testName.openedWithin", "Date Opened")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .titleOrAuthorContains.
        case .titleOrAuthorContains: return InterfaceText.line("libraryViewEditor.testName.titleOrAuthorContains", "Title or Author")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .hasNewItems.
        case .hasNewItems: return InterfaceText.line("common.newItems", "New Items")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A kind of test as a condition's test pop-up names it. This is the case .subscribed.
        case .subscribed: return InterfaceText.line("libraryViewEditor.testName.subscribed", "Subscription")
        }
    }
    /// A condition's relation as its relation pop-up names it, by its test
    /// and whether it is negated.
    static func relationName(_ kind: LibraryViewCondition.Kind, isNegated: Bool) -> String {
        switch kind {
        case .format, .folder, .readingState:
            // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the first case of the condition.
            return isNegated ? InterfaceText.line("libraryViewEditor.relationName.format.not", "Is Not") :
                // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the other case of the condition.
                InterfaceText.line("libraryViewEditor.relationName.format.is", "Is")
        case .inReadingList:
            // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the first case of the condition.
            return isNegated ? InterfaceText.line("libraryViewEditor.relationName.inReadingList.not", "Not in the Reading List") :
                // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the other case of the condition.
                InterfaceText.line("libraryViewEditor.inReadingList.title", "In the Reading List")
        case .addedWithin, .openedWithin:
            // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the first case of the condition.
            return isNegated ? InterfaceText.line("libraryViewEditor.relationName.addedWithin.not", "Not Within the Last") :
                // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the other case of the condition.
                InterfaceText.line("libraryViewEditor.relationName.addedWithin.last", "Within the Last")
        case .titleOrAuthorContains:
            // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the first case of the condition.
            return isNegated ? InterfaceText.line("libraryViewEditor.relationName.doesNotContain", "Does Not Contain") :
                // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the other case of the condition.
                InterfaceText.line("libraryViewEditor.relationName.contains", "Contains")
        case .hasNewItems:
            // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the first case of the condition.
            return isNegated ? InterfaceText.line("libraryViewEditor.relationName.hasNewItems.none", "Has None New") :
                // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the other case of the condition.
                InterfaceText.line("libraryViewEditor.hasNewItems.episodes", "Has New Episodes or Articles")
        case .subscribed:
            // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the first case of the condition.
            return isNegated ? InterfaceText.line("common.unsubscribed", "Unsubscribed") :
                // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A condition's relation as its relation pop-up names it, by its test and whether it is negated. This is the form for the other case of the condition.
                InterfaceText.line("libraryViewEditor.relationName.subscribed", "Subscribed")
        }
    }
    /// A reading state as the pop-up names it.
    static func stateName(_ state: LibraryReadingState) -> String {
        switch state {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A reading state as the pop-up names it. This is the case .unopened.
        case .unopened: return InterfaceText.line("common.unopened", "Unopened")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A reading state as the pop-up names it. This is the case .inProgress.
        case .inProgress: return InterfaceText.line("libraryViewEditor.stateName.inProgress", "In Progress")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A reading state as the pop-up names it. This is the case .finished.
        case .finished: return InterfaceText.line("common.finished", "Finished")
        }
    }
    /// The test pop-up's spoken label: "Condition 2".
    static func conditionLabel(_ number: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The test pop-up's spoken label: "Condition 2". %@ is the condition's number, an identifier written without digit grouping.
        InterfaceText.line("libraryViewEditor.conditionLabel", "Condition \(String(number))")
    }
    /// The relation pop-up's spoken label.
    static func relationLabel(_ number: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The relation pop-up's spoken label. %@ is the condition's number, an identifier written without digit grouping.
        InterfaceText.line("libraryViewEditor.relationLabel", "Condition \(String(number)) relation")
    }
    /// The format pop-up's spoken label.
    static func formatLabel(_ number: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The format pop-up's spoken label. %@ is the condition's number, an identifier written without digit grouping.
        InterfaceText.line("libraryViewEditor.formatLabel", "Condition \(String(number)) format")
    }
    /// The folder pop-up's spoken label.
    static func folderLabel(_ number: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The folder pop-up's spoken label. %@ is the condition's number, an identifier written without digit grouping.
        InterfaceText.line("libraryViewEditor.folderLabel", "Condition \(String(number)) folder")
    }
    /// The subfolders checkbox's visible title.
    static var subfoldersTitle: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The subfolders checkbox's visible title.
        InterfaceText.line("libraryViewEditor.subfoldersTitle", "Including Subfolders")
    }
    /// The subfolders checkbox's spoken label.
    static func subfoldersLabel(_ number: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The subfolders checkbox's spoken label. %@ is the condition's number, an identifier written without digit grouping.
        InterfaceText.line("libraryViewEditor.subfoldersLabel", "Condition \(String(number)) includes subfolders")
    }
    /// The reading state pop-up's spoken label.
    static func readingStateLabel(_ number: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The reading state pop-up's spoken label. %@ is the condition's number, an identifier written without digit grouping.
        InterfaceText.line("libraryViewEditor.readingStateLabel", "Condition \(String(number)) reading state")
    }
    /// The days field's spoken label.
    static func daysLabel(_ number: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The days field's spoken label. %@ is the condition's number, an identifier written without digit grouping.
        InterfaceText.line("libraryViewEditor.daysLabel", "Condition \(String(number)) days")
    }
    /// The caption after the days field.
    static var daysCaption: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The caption after the days field.
        InterfaceText.line("libraryViewEditor.daysCaption", "days")
    }
    /// The text field's spoken label.
    static func textLabel(_ number: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The text field's spoken label. %@ is the condition's number, an identifier written without digit grouping.
        InterfaceText.line("libraryViewEditor.textLabel", "Condition \(String(number)) text")
    }
    /// The remove button's visible title.
    static var removeTitle: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The remove button's visible title.
        InterfaceText.line("common.remove", "Remove")
    }
    /// The remove button's spoken label.
    static func removeLabel(_ number: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The remove button's spoken label. %@ is the condition's number, an identifier written without digit grouping.
        InterfaceText.line("libraryViewEditor.removeLabel", "Remove condition \(String(number))")
    }
    /// The button that adds a condition.
    static var addCondition: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The button that adds a condition.
        InterfaceText.line("libraryViewEditor.addCondition", "Add Condition")
    }
    /// Its hint at the limit, when it is dimmed.
    static var conditionLimitHint: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Its hint at the limit, when it is dimmed. Placeholders in order: LibraryViewFilter.conditionLimit.
        InterfaceText.line("libraryViewEditor.conditionLimitHint", "A view holds at most \(number: LibraryViewFilter.conditionLimit) conditions.")
    }

    // MARK: - After the Conditions

    /// The checkbox that keeps one item per feed.
    static var onePerFeedTitle: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The checkbox that keeps one item per feed.
        InterfaceText.line("libraryViewEditor.onePerFeedTitle", "Only the Latest from Each Feed")
    }
    /// Its hint.
    static var onePerFeedHint: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Its hint.
        InterfaceText.line("libraryViewEditor.onePerFeedHint", "Of each feed's episodes and articles, lists only the one you opened last.")
    }
    /// Its hint while the view lists no episodes or articles, when it is
    /// dimmed (review of October 31, 2026, finding 6).
    static var onePerFeedUnavailableHint: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Its hint while the view lists no episodes or articles, when it is dimmed (review of October 31, 2026, finding 6).
        InterfaceText.line("libraryViewEditor.onePerFeedUnavailableHint", "Applies only to a view that lists episodes or articles.")
    }
    /// Show at Most's hint while the view lists feeds alone, when it is
    /// dimmed (finding 6).
    static var limitUnavailableHint: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Show at Most's hint while the view lists feeds alone, when it is dimmed (finding 6).
        InterfaceText.line("libraryViewEditor.limitUnavailableHint", "A limit chooses among books, episodes, and articles, never feeds.")
    }
    /// The sort field pop-up's label.
    static var sortByLabel: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The sort field pop-up's label.
        InterfaceText.line("libraryViewEditor.sortByLabel", "Sort By")
    }
    /// The direction pop-up's label.
    static var orderLabel: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The direction pop-up's label.
        InterfaceText.line("libraryViewEditor.orderLabel", "Order")
    }
    /// A direction as the pop-up names it.
    static func orderName(ascending: Bool) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A direction as the pop-up names it. This is the form for the first case of the condition.
        ascending ? InterfaceText.line("libraryViewEditor.orderName.ascending", "Ascending") :
            // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A direction as the pop-up names it. This is the form for the other case of the condition.
            InterfaceText.line("libraryViewEditor.orderName.descending", "Descending")
    }
    /// What stands for the sort while the view lists feeds alone.
    static var feedsOnlySortNote: String {
        let hint = LibraryViewPickerWording.feedsOrderHint
        // Translators: Library view editor: the note shown in place of the sort choice while the view lists feeds alone. %@ is a sentence without its full stop, saying feeds are always listed by title; this adds the full stop.
        return InterfaceText.line("common.valuePeriod", "\(hint).")
    }
    /// The limit checkbox.
    static var limitTitle: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The limit checkbox.
        InterfaceText.line("libraryViewEditor.limitTitle", "Show at Most")
    }
    /// The limit field's spoken label.
    static var limitFieldLabel: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The limit field's spoken label.
        InterfaceText.line("libraryViewEditor.limitFieldLabel", "Most rows shown")
    }
    /// The pop-up of which rows a limit keeps.
    static var chosenByLabel: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. The pop-up of which rows a limit keeps.
        InterfaceText.line("libraryViewEditor.chosenByLabel", "Chosen By")
    }
    /// A limit's order as its pop-up names it.
    static func limitOrderName(_ order: LibraryViewLimit.Order) -> String {
        switch order {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A limit's order as its pop-up names it. This is the case .lastOpened.
        case .lastOpened: return InterfaceText.line("libraryViewEditor.limitOrderName.lastOpened", "Opened Last")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A limit's order as its pop-up names it. This is the case .dateAdded.
        case .dateAdded: return InterfaceText.line("libraryViewEditor.limitOrderName.dateAdded", "Added Last")
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. A limit's order as its pop-up names it. This is the case .viewSort.
        case .viewSort: return InterfaceText.line("libraryViewEditor.limitOrderName.viewSort", "First in the Sort")
        }
    }

    // MARK: - Problems and Announcements

    /// Save's problem with no name.
    static var nameMissing: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Save's problem with no name.
        InterfaceText.line("libraryViewEditor.nameMissing", "Give the view a name.")
    }
    /// Save's problem with a name too long.
    static var nameTooLong: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Save's problem with a name too long. Placeholders in order: LibraryViewDefinition.nameLimit.
        InterfaceText.line("libraryViewEditor.nameTooLong", "A view's name can be at most \(number: LibraryViewDefinition.nameLimit) characters.")
    }
    /// Save's problem with a name another view has.
    static func nameTaken(_ name: String) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Save's problem with a name another view has. Placeholders in order: name.
        InterfaceText.line("libraryViewEditor.nameTaken", "Another view is already named \(name). Choose another name.")
    }
    /// Save's problem with no kind listed.
    static var nothingListed: String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Save's problem with no kind listed.
        InterfaceText.line("libraryViewEditor.nothingListed", "Choose at least one kind of item for the view to list.")
    }
    /// Save's problem with a title or author condition looking for nothing.
    static func textMissing(_ number: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. Save's problem with a title or author condition looking for nothing. %@ is the condition's number, an identifier written without digit grouping.
        InterfaceText.line("libraryViewEditor.textMissing", "Condition \(String(number)) needs the text to look for.")
    }
    /// What VoiceOver says once a changed view is saved.
    static func saved(_ name: String) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. What VoiceOver says once a changed view is saved. Placeholders in order: name.
        InterfaceText.line("libraryViewEditor.saved", "Saved \(name).")
    }
    /// What VoiceOver says once a new view is added, with its place.
    static func added(_ name: String, number: Int, count: Int) -> String {
        // Translators: Text of the Library view editor sheet, which makes and changes a view of the Library window, and of the descriptions of a view's filter. What VoiceOver says once a new view is added, with its place. Placeholders in order: name, number, count.
        InterfaceText.line("libraryViewEditor.added", "Added \(name), \(number: number) of \(number: count).")
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
            return InterfaceText.line("libraryViewEditor.count.nothing", "Lists nothing now.")
        }
        let list = CountWording.list(parts)
        // Translators: Library view editor: what the sheet says of a draft view's contents. %@ is a list of counts, such as "23 books and 2 feeds".
        return InterfaceText.line("libraryViewEditor.count.lists", "Lists \(list).")
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
            text = InterfaceText.line("libraryViewEditor.description.kinds", "Lists \(kinds)")
        } else {
            let list = filter.match == .all ? CountWording.list(conditions) : listWithOr(conditions)
            // Translators: Library view editor: the start of a filter's description, which says what a view lists and its conditions. %1$@ is a list of the kinds it lists in lower case, such as "books and feeds"; %2$@ is its conditions joined by "and" or "or". A description ends with a full stop added later.
            text = InterfaceText.line("libraryViewEditor.description.kindsAndConditions", "Lists \(kinds): \(list)")
        }
        // One per feed and a limit are said only where they apply (review of
        // October 31, 2026, finding 6), each after a semicolon.
        var tails: [String] = []
        if filter.onePerFeed, !filter.lists.isDisjoint(with: [.episodes, .articles]) {
            // Translators: Library view editor: a clause at the end of a filter's description, said when the view lists only the newest item of each feed.
            tails.append(InterfaceText.line("libraryViewEditor.description.latest", "only the latest from each feed"))
        }
        if let limit = filter.limit, filter.listsItems {
            let order = limitOrderNameInSentence(limit.chosenBy)
            // Translators: Library view editor: a clause at the end of a filter's description, said when the view shows only some rows. %1$lld is how many rows at most, a count; %2$@ is how they are chosen, in lower case, such as "opened last".
            tails.append(InterfaceText.line("libraryViewEditor.description.most", "at most \(number: limit.count), \(order)"))
        }
        for tail in tails {
            // Translators: Library view editor: adds one more clause to a filter's description. %1$@ is the description so far and %2$@ the clause added after a semicolon.
            text = InterfaceText.line("common.valueSemicolonValue", "\(text); \(tail)")
        }
        // Translators: Library view editor: ends a filter's description with a full stop. %@ is the whole description.
        return InterfaceText.line("common.valuePeriod", "\(text).")
    }

    /// A kind of row in lower case, inside a description: "books",
    /// "episodes", "articles", or "feeds".
    private static func kindNameInSentence(_ kind: LibraryViewItemKind) -> String {
        switch kind {
        case .books:
            // Translators: Library view editor: the kind of row books, in lower case inside a filter's description such as "Lists books and feeds".
            return InterfaceText.line("libraryViewEditor.kindNameInSentence.books", "books")
        case .episodes:
            // Translators: Library view editor: the kind of row podcast episodes, in lower case inside a filter's description such as "Lists books and episodes".
            return InterfaceText.line("libraryViewEditor.kindNameInSentence.episodes", "episodes")
        case .articles:
            // Translators: Library view editor: the kind of row news articles, in lower case inside a filter's description such as "Lists books and articles".
            return InterfaceText.line("libraryViewEditor.kindNameInSentence.articles", "articles")
        case .feeds:
            // Translators: Library view editor: the kind of row feeds, in lower case inside a filter's description such as "Lists books and feeds".
            return InterfaceText.line("libraryViewEditor.kindNameInSentence.feeds", "feeds")
        }
    }

    /// A limit's order in lower case, inside a description: "opened last",
    /// "added last", or "first in the sort".
    private static func limitOrderNameInSentence(_ order: LibraryViewLimit.Order) -> String {
        switch order {
        case .lastOpened:
            // Translators: Library view editor: how a view's limit chooses rows, in lower case inside a filter's description: the books opened most recently.
            return InterfaceText.line("libraryViewEditor.lastOpened", "opened last")
        case .dateAdded:
            // Translators: Library view editor: how a view's limit chooses rows, in lower case inside a filter's description: the items added most recently.
            return InterfaceText.line("libraryViewEditor.dateAdded", "added last")
        case .viewSort:
            // Translators: Library view editor: how a view's limit chooses rows, in lower case inside a filter's description: the first rows of the view's own sort.
            return InterfaceText.line("libraryViewEditor.viewSort", "first in the sort")
        }
    }

    /// The name a folder condition gives a folder no longer in the library.
    static var missingFolder: String {
        // Translators: Library view editor: the name a folder condition gives a folder that is no longer in the library, inside a filter's description such as "folder is a folder no longer in the library".
        InterfaceText.line("libraryViewEditor.missingFolder", "a folder no longer in the library")
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
                ? InterfaceText.line("libraryViewEditor.phrase.format.formatNot", "format is not \(name)")
                // Translators: Library view editor: a condition inside a filter's description. %@ is a book format's name, such as EPUB.
                : InterfaceText.line("libraryViewEditor.phrase.format.equals", "format is \(name)")
        case .folder(let id, let includingSubfolders):
            let name = folderName(id)
            switch (not, includingSubfolders) {
            case (false, false):
                // Translators: Library view editor: a condition inside a filter's description. %@ is a library folder's path, Library Root, or a note that it is gone.
                return InterfaceText.line("libraryViewEditor.phrase.folder.equals", "folder is \(name)")
            case (false, true):
                // Translators: Library view editor: a condition inside a filter's description. %@ is a library folder's path, Library Root, or a note that it is gone. The folders below it count too.
                return InterfaceText.line("libraryViewEditor.phrase.folder.including", "folder is \(name), including subfolders")
            case (true, false):
                // Translators: Library view editor: a condition inside a filter's description. %@ is a library folder's path, Library Root, or a note that it is gone.
                return InterfaceText.line("libraryViewEditor.phrase.folder.folderNot", "folder is not \(name)")
            case (true, true):
                // Translators: Library view editor: a condition inside a filter's description. %@ is a library folder's path, Library Root, or a note that it is gone. The folders below it count too.
                return InterfaceText.line("libraryViewEditor.folder.notIncludingSubfolders", "folder is not \(name), including subfolders")
            }
        case .readingState(let state):
            let name = stateName(state)
            return not
                // Translators: Library view editor: a condition inside a filter's description. %@ is a reading state's name: Unopened, In Progress, or Finished.
                ? InterfaceText.line("libraryViewEditor.phrase.readingState.readingNot", "reading state is not \(name)")
                // Translators: Library view editor: a condition inside a filter's description. %@ is a reading state's name: Unopened, In Progress, or Finished.
                : InterfaceText.line("libraryViewEditor.phrase.readingState.equals", "reading state is \(name)")
        case .inReadingList:
            return not
                // Translators: Library view editor: a condition inside a filter's description: the item is not in the Reading List.
                ? InterfaceText.line("libraryViewEditor.phrase.inReadingList.not", "not in the reading list")
                // Translators: Library view editor: a condition inside a filter's description: the item is in the Reading List.
                : InterfaceText.line("libraryViewEditor.phrase.inReadingList.member", "in the reading list")
        case .addedWithin(let days):
            return addedPhrase(days: days, negated: not)
        case .openedWithin(let days):
            return openedPhrase(days: days, negated: not)
        case .titleOrAuthorContains(let text):
            return not
                // Translators: Library view editor: a condition inside a filter's description. %@ is the text the listener typed to look for.
                ? InterfaceText.line("libraryViewEditor.titleOrAuthorContains.contain", "title or author does not contain “\(text)”")
                // Translators: Library view editor: a condition inside a filter's description. %@ is the text the listener typed to look for.
                : InterfaceText.line("libraryViewEditor.titleOrAuthorContains.matches", "title or author contains “\(text)”")
        case .hasNewItems:
            return not
                // Translators: Library view editor: a condition inside a filter's description: a feed has no new episodes or articles.
                ? InterfaceText.line("libraryViewEditor.phrase.hasNewItems.none", "has none new")
                // Translators: Library view editor: a condition inside a filter's description: a feed has new episodes or articles.
                : InterfaceText.line("libraryViewEditor.phrase.hasNewItems.episodes", "has new episodes or articles")
        case .subscribed:
            return not
                // Translators: Library view editor: a condition inside a filter's description: the listener is not subscribed to the feed.
                ? InterfaceText.line("libraryViewEditor.phrase.subscribed.unsubscribed", "unsubscribed")
                // Translators: Library view editor: a condition inside a filter's description: the listener is subscribed to the feed.
                : InterfaceText.line("libraryViewEditor.phrase.subscribed.active", "subscribed")
        }
    }

    /// "added today" for one day, else "added within the last 7 days", with
    /// "not " in front when negated: whole strings, one for each case.
    private static func addedPhrase(days: Int, negated: Bool) -> String {
        switch (negated, days == 1) {
        case (false, true):
            // Translators: Library view editor: a condition inside a filter's description: the item was added today.
            return InterfaceText.line("libraryViewEditor.addedPhrase.today", "added today")
        case (true, true):
            // Translators: Library view editor: a condition inside a filter's description: the item was not added today.
            return InterfaceText.line("libraryViewEditor.addedPhrase.notToday", "not added today")
        case (false, false):
            // Translators: Library view editor: a condition inside a filter's description. %lld is a number of days, a count.
            return InterfaceText.line("libraryViewEditor.addedPhrase.withinLastDays", "added within the last \(number: days) days")
        case (true, false):
            // Translators: Library view editor: a condition inside a filter's description. %lld is a number of days, a count.
            return InterfaceText.line("libraryViewEditor.addedPhrase.notWithinLastDays", "not added within the last \(number: days) days")
        }
    }

    /// "opened today" for one day, else "opened within the last 7 days",
    /// with "not " in front when negated.
    private static func openedPhrase(days: Int, negated: Bool) -> String {
        switch (negated, days == 1) {
        case (false, true):
            // Translators: Library view editor: a condition inside a filter's description: the book was opened today.
            return InterfaceText.line("libraryViewEditor.openedPhrase.today", "opened today")
        case (true, true):
            // Translators: Library view editor: a condition inside a filter's description: the book was not opened today.
            return InterfaceText.line("libraryViewEditor.openedPhrase.notToday", "not opened today")
        case (false, false):
            // Translators: Library view editor: a condition inside a filter's description. %lld is a number of days, a count.
            return InterfaceText.line("libraryViewEditor.openedPhrase.withinLastDays", "opened within the last \(number: days) days")
        case (true, false):
            // Translators: Library view editor: a condition inside a filter's description. %lld is a number of days, a count.
            return InterfaceText.line("libraryViewEditor.openedPhrase.notWithinLastDays", "not opened within the last \(number: days) days")
        }
    }

    /// `items` joined as `CountWording.list` joins them, with "or" where it
    /// says "and": "A", "A or B", "A, B, or C", in the region's list style.
    static func listWithOr(_ items: [String], locale: Locale = InterfaceLanguage.current.locale) -> String {
        items.formatted(.list(type: .or).locale(locale))
    }
}
