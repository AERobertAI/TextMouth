import Foundation

// MARK: - A View's Identity

/// A Library view's permanent identity (the design of October 30, 2026,
/// LIBRARY-VIEWS-RESEARCH-2026-10-30.md, section 2).
///
/// The five views TextMouth has always had are named by their categories,
/// whose names are already saved names (`LibraryCategory`); the Feeds view by
/// "Feeds"; a view the listener made by a UUID. config.json keeps the
/// identity as text (`storedValue`), and a view keeps it however it is
/// renamed, moved, or changed.
enum LibraryViewID: Hashable, Sendable {
    /// One of the five views TextMouth has always had: Folders, All Items,
    /// Unopened, Recently Opened, and the Reading List.
    case category(LibraryCategory)
    /// The Feeds view, which lists the feeds alone.
    case feeds
    /// A view the listener made.
    case custom(UUID)

    /// The Feeds view's stored identity, which is also its shipped name, as
    /// each category's name is its saved name.
    static let feedsStoredValue = "Feeds"

    /// The identity as config.json keeps it: the category's name, "Feeds",
    /// or the UUID's text.
    var storedValue: String {
        switch self {
        case .category(let category): return category.rawValue
        case .feeds: return Self.feedsStoredValue
        case .custom(let uuid): return uuid.uuidString
        }
    }

    /// Reads a stored identity: a category's name or former name
    /// (`LibraryCategory(savedName:)`), "Feeds", or a UUID's text; nil for
    /// anything else, such as the identity of a view a later TextMouth
    /// added.
    init?(storedValue: String) {
        if let category = LibraryCategory(savedName: storedValue) {
            self = .category(category)
        } else if storedValue == Self.feedsStoredValue {
            self = .feeds
        } else if let uuid = UUID(uuidString: storedValue) {
            self = .custom(uuid)
        } else {
            return nil
        }
    }

    /// The category of one of the five categories' views; nil for Feeds and
    /// custom views.
    var category: LibraryCategory? {
        guard case .category(let category) = self else { return nil }
        return category
    }

    /// Whether TextMouth made the view: every view but the listener's own.
    var isBuiltIn: Bool {
        if case .custom = self { return false }
        return true
    }

    /// Every built-in view, in the order TextMouth ships them: the five
    /// categories in their picker's old order, then Feeds.
    static let builtIns: [LibraryViewID] = LibraryCategory.allCases.map { .category($0) } + [.feeds]
}

// MARK: - When a View Is Offered

/// When a Library window's View pop-up offers a view (design section 5).
enum LibraryViewVisibility: String, CaseIterable, Sendable {
    /// Offered all the time.
    case always
    /// Offered only while the view lists something.
    case whenApplicable
    /// Never offered, unless a window shows it already.
    case hidden
}

// MARK: - What a Filter View Lists

/// The kinds of rows a filter view can list (design section 4).
enum LibraryViewItemKind: String, CaseIterable, Sendable {
    /// Rows of the library's own books.
    case books
    /// Downloaded feed items whose format is audio.
    case episodes
    /// Downloaded feed items of any other format.
    case articles
    /// Feeds' rows, as the Feeds section shows them.
    case feeds
}

/// Whether a filter view's conditions must all hold, or one is enough.
enum LibraryViewMatch: String, CaseIterable, Sendable {
    /// Every condition that tests a row holds.
    case all
    /// At least one condition that tests a row holds.
    case any
}

/// How far the listener has got with a book, episode, or article, as a
/// condition tests it.
enum LibraryReadingState: String, CaseIterable, Sendable {
    /// Never opened (`Book.isUnopened`).
    case unopened
    /// Opened, and not finished.
    case inProgress
    /// Finished, as Books Finished counts it (`ReadingStats.finishedBookIDs`).
    case finished
}

// MARK: - A Condition

/// One condition of a filter view: a test, and whether it holds when the
/// test fails instead ("is not"). Conditions about books test books,
/// episodes, and articles, conditions about feeds test feeds, and a
/// condition never hides a row it does not test (design section 4).
struct LibraryViewCondition: Hashable, Sendable {
    /// What a condition tests.
    enum Test: Hashable, Sendable {
        /// The row's format.
        case format(BookFormat)
        /// The row's folder: a folder by its ID, with or without the
        /// folders inside it, or, for nil, Library Root, the top of the
        /// library. A feed item is in its feed's folder.
        case folder(id: UUID?, includingSubfolders: Bool)
        /// How far the row has been read or played.
        case readingState(LibraryReadingState)
        /// Whether the row is in the reading list.
        case inReadingList
        /// Whether the row was added today or on one of the `days` − 1
        /// days before.
        case addedWithin(days: Int)
        /// Whether the row was last opened today or on one of the `days` −
        /// 1 days before; a row never opened is not.
        case openedWithin(days: Int)
        /// Whether the row's title or author contains the text, ignoring
        /// case, as the window's search matches.
        case titleOrAuthorContains(String)
        /// Whether a feed has a new episode or article.
        case hasNewItems
        /// Whether the listener is subscribed to a feed.
        case subscribed

        /// The kind of test, without its value.
        var kind: Kind {
            switch self {
            case .format: return .format
            case .folder: return .folder
            case .readingState: return .readingState
            case .inReadingList: return .inReadingList
            case .addedWithin: return .addedWithin
            case .openedWithin: return .openedWithin
            case .titleOrAuthorContains: return .titleOrAuthorContains
            case .hasNewItems: return .hasNewItems
            case .subscribed: return .subscribed
            }
        }
    }

    /// The kinds of test, by the names config.json gives them.
    enum Kind: String, CaseIterable, Sendable {
        case format
        case folder
        case readingState
        case inReadingList
        case addedWithin
        case openedWithin
        case titleOrAuthorContains
        case hasNewItems
        case subscribed

        /// The keys a condition of this kind holds in config.json, besides
        /// "test" and "not".
        fileprivate var valueKeys: Set<String> {
            switch self {
            case .format, .readingState: return ["value"]
            case .folder: return ["folderID", "includingSubfolders"]
            case .addedWithin, .openedWithin: return ["days"]
            case .titleOrAuthorContains: return ["text"]
            case .inReadingList, .hasNewItems, .subscribed: return []
            }
        }
    }

    /// What the condition tests.
    var test: Test
    /// Whether the condition holds when the test fails: "is not".
    var isNegated: Bool = false

    /// How many days back a date condition can reach: one day (today) to
    /// about ten years.
    static let dayRange = 1...3_650
    /// The most characters a title or author condition looks for.
    static let textLimit = 200

    /// Whether this condition tests rows of `kind`. Feeds are tested only
    /// by their folder, their title and author, whether they have new
    /// items, and whether they are subscribed; books, episodes, and articles
    /// by every test but the last two, which are about feeds.
    func tests(_ kind: LibraryViewItemKind) -> Bool {
        switch test.kind {
        case .folder, .titleOrAuthorContains:
            return true
        case .hasNewItems, .subscribed:
            return kind == .feeds
        case .format, .readingState, .inReadingList, .addedWithin, .openedWithin:
            return kind != .feeds
        }
    }
}

// MARK: - The Limit

/// How many rows a filter view lists at most, and which it keeps.
struct LibraryViewLimit: Hashable, Sendable {
    /// Which rows a limit keeps.
    enum Order: String, CaseIterable, Sendable {
        /// Those opened most recently.
        case lastOpened
        /// Those added most recently.
        case dateAdded
        /// The first in the view's sort.
        case viewSort
    }

    /// The most rows listed.
    var count: Int
    /// Which rows are kept.
    var chosenBy: Order

    /// The counts a limit can have.
    static let countRange = 1...9_999
}

// MARK: - A Filter

/// What a filter view lists: the kinds of rows, the conditions they meet,
/// and what happens after the conditions (design section 4).
struct LibraryViewFilter: Hashable, Sendable {
    /// The kinds of rows listed; never empty.
    var lists: Set<LibraryViewItemKind>
    /// Whether all the conditions that test a row must hold, or any one.
    var match: LibraryViewMatch = .all
    /// The conditions, in the order the listener gave them.
    var conditions: [LibraryViewCondition] = []
    /// Whether, of each feed's episodes and articles, only the one opened
    /// last is listed.
    var onePerFeed: Bool = false
    /// How many rows are listed at most, and which; nil for no limit.
    var limit: LibraryViewLimit?

    /// The most conditions a view holds.
    static let conditionLimit = 20

    /// Whether the filter lists feeds and nothing else, so the view has no
    /// sort: feeds are always listed by title.
    var listsOnlyFeeds: Bool {
        lists == [.feeds]
    }

    /// Whether the filter lists books, episodes, or articles.
    var listsItems: Bool {
        !lists.isDisjoint(with: [.books, .episodes, .articles])
    }
}

// MARK: - A View

/// The kinds of view: two that list what they always have, and filter
/// views.
enum LibraryViewKind: Sendable {
    /// Folders: one folder at a time, with its breadcrumbs and manual order.
    case folders
    /// The Reading List: its books in the order the listener arranges.
    case readingList
    /// A view listing what its filter finds.
    case filter
}

/// One view of the Library window (design section 2): its identity, its
/// name, when the View pop-up offers it, and, for a filter view, its
/// filter. Its place in the order is its index in the list
/// (`LibraryViewDefinitionList`); its sort is saved in library.json under
/// `sortSettingsKey`.
struct LibraryViewDefinition: Equatable, Identifiable, Sendable {
    /// The view's permanent identity.
    let id: LibraryViewID
    /// What the View pop-up and the window title call it.
    var name: String
    /// When the View pop-up offers it.
    var visibility: LibraryViewVisibility
    /// What a filter view lists; nil exactly for Folders and the Reading
    /// List.
    var filter: LibraryViewFilter?
    /// The keys of its config.json entry that this TextMouth does not know,
    /// such as one a later TextMouth added, kept to be written back as they
    /// were.
    var extraFields: [String: JSONValue] = [:]
    /// The members of its config.json entry ("name", "visibility",
    /// "filter") that reading repaired only for showing, as they were read
    /// (nil: absent), written back exactly so until the listener changes
    /// that member here (review of October 31, 2026, findings 2 and 3): a
    /// visibility this TextMouth does not know, a name or filter on Folders
    /// or the Reading List, a built-in view's filter it cannot read, and a
    /// name it trimmed, cut, or numbered apart from another view's.
    var keptAsRead: [String: JSONValue?] = [:]

    /// The most characters a view's name has.
    static let nameLimit = 60
    /// What the sort keys of Feeds and of custom views begin with. A folder
    /// path never begins with "/", so no folder can take such a key, and no
    /// folder name needs reserving (design section 8).
    static let sortSettingsKeyPrefix = "/views/"

    /// The kind of view, which its identity decides.
    var kind: LibraryViewKind {
        switch id {
        case .category(.folders): return .folders
        case .category(.readingList): return .readingList
        case .category, .feeds, .custom: return .filter
        }
    }

    /// Whether TextMouth made the view.
    var isBuiltIn: Bool {
        id.isBuiltIn
    }

    /// The key the view's sort is saved under in
    /// `Library.folderSortSettings`: nil for Folders, where each folder's
    /// path is its key; a category's reserved key for the other four
    /// categories (`LibraryCategory.sortSettingsKey`); and the prefix and
    /// the stored identity for Feeds and custom views, as in "/views/Feeds".
    var sortSettingsKey: String? {
        switch id {
        case .category(let category):
            return category.sortSettingsKey
        case .feeds, .custom:
            return Self.sortSettingsKeyPrefix + id.storedValue
        }
    }

    /// The sort the view shows until one is chosen: its category's default
    /// for the five categories, and title ascending for Feeds and custom
    /// views.
    var defaultSortSetting: FolderSortSetting {
        id.category?.defaultSortSetting ?? .defaultSort
    }

    /// Whether a built-in view's name or filter differs from the one
    /// TextMouth ships; always false for a custom view, which has none.
    var differsFromShipped: Bool {
        guard let shipped = Self.shipped(id) else { return false }
        return name != shipped.name || filter != shipped.filter
    }

    // MARK: The Shipped Views

    /// The view TextMouth ships for a built-in identity (design section 3);
    /// nil for a custom one.
    static func shipped(_ id: LibraryViewID) -> LibraryViewDefinition? {
        switch id {
        case .category(let category):
            return shipped(category)
        case .feeds:
            return LibraryViewDefinition(
                id: .feeds,
                name: LibraryViewID.feedsStoredValue,
                visibility: .whenApplicable,
                filter: LibraryViewFilter(lists: [.feeds])
            )
        case .custom:
            return nil
        }
    }

    /// The view TextMouth ships for one of the five categories: named as the
    /// category is, always offered, with the filter that lists exactly what
    /// the category listed before views could be changed.
    static func shipped(_ category: LibraryCategory) -> LibraryViewDefinition {
        LibraryViewDefinition(
            id: .category(category),
            name: category.rawValue,
            visibility: .always,
            filter: shippedFilter(of: category)
        )
    }

    /// The filter of a category's shipped view: none for Folders and the
    /// Reading List; every book and feed for All Items; the books never
    /// opened and the feeds with a new item for Unopened; and, for Recently
    /// Opened, the rows opened, one per feed, the ten opened last.
    private static func shippedFilter(of category: LibraryCategory) -> LibraryViewFilter? {
        switch category {
        case .folders, .readingList:
            return nil
        case .allItems:
            return LibraryViewFilter(lists: [.books, .feeds])
        case .unopened:
            return LibraryViewFilter(
                lists: [.books, .feeds],
                conditions: [
                    LibraryViewCondition(test: .readingState(.unopened)),
                    LibraryViewCondition(test: .hasNewItems),
                ]
            )
        case .recent:
            return LibraryViewFilter(
                lists: [.books, .episodes, .articles],
                conditions: [LibraryViewCondition(test: .readingState(.unopened), isNegated: true)],
                onePerFeed: true,
                limit: LibraryViewLimit(count: LibraryBookSorter.recentlyOpenedCount, chosenBy: .lastOpened)
            )
        }
    }
}

// MARK: - Writing config.json's Entries

extension LibraryViewDefinition {
    /// The keys of an entry this TextMouth reads; any other is kept in
    /// `extraFields`.
    fileprivate static let fileKeys: Set<String> = ["id", "name", "visibility", "filter"]

    /// The entry config.json holds for the view (design section 8): its
    /// identity and visibility, and its name and filter, which a built-in
    /// view writes only once the listener changed them, so a later
    /// TextMouth can improve the shipped views. Unknown keys it was read
    /// with are written back beside them, and the members it showed
    /// repaired are written back as they were read (`keptAsRead`), so an
    /// entry this TextMouth only read is written back exactly as it was.
    var fileEntry: JSONValue {
        var members = extraFields
        members["id"] = .string(id.storedValue)
        members["visibility"] = .string(visibility.rawValue)
        let shipped = Self.shipped(id)
        if name != shipped?.name {
            members["name"] = .string(name)
        }
        if let filter, filter != shipped?.filter {
            members["filter"] = filter.fileValue
        }
        for (key, value) in keptAsRead {
            // Nil removes the member, which the entry did not hold.
            members[key] = value
        }
        return .object(members)
    }

    /// The members whose shown value reading may repair, and whose read
    /// value `keptAsRead` keeps.
    static let repairableKeys = ["name", "visibility", "filter"]

    /// Forgets the read value of `key`, which the listener changed here, so
    /// the entry writes the view's own value from now on.
    mutating func forgetReadValue(of key: String) {
        keptAsRead[key] = nil
    }
}

extension LibraryViewFilter {
    /// The keys of a filter in config.json; a filter holding any other is
    /// unreadable.
    fileprivate static let fileKeys: Set<String> = ["lists", "match", "conditions", "onePerFeed", "limit"]

    /// The filter as config.json holds it: the kinds listed in a fixed
    /// order, the match, the conditions, and the rest only when set.
    var fileValue: JSONValue {
        var members: [String: JSONValue] = [
            "lists": .array(LibraryViewItemKind.allCases.filter(lists.contains).map { .string($0.rawValue) }),
            "match": .string(match.rawValue),
            "conditions": .array(conditions.map(\.fileValue)),
        ]
        if onePerFeed {
            members["onePerFeed"] = .bool(true)
        }
        if let limit {
            members["limit"] = .object([
                "count": .integer(Int64(limit.count)),
                "chosenBy": .string(limit.chosenBy.rawValue),
            ])
        }
        return .object(members)
    }
}

extension LibraryViewCondition {
    /// The condition as config.json holds it: its test's name, the value the
    /// test needs, and "not" only when negated.
    var fileValue: JSONValue {
        var members: [String: JSONValue] = ["test": .string(test.kind.rawValue)]
        switch test {
        case .format(let format):
            members["value"] = .string(format.rawValue)
        case .folder(let folderID, let includingSubfolders):
            members["folderID"] = folderID.map { .string($0.uuidString) } ?? .null
            members["includingSubfolders"] = .bool(includingSubfolders)
        case .readingState(let state):
            members["value"] = .string(state.rawValue)
        case .addedWithin(let days), .openedWithin(let days):
            members["days"] = .integer(Int64(days))
        case .titleOrAuthorContains(let text):
            members["text"] = .string(text)
        case .inReadingList, .hasNewItems, .subscribed:
            break
        }
        if isNegated {
            members["not"] = .bool(true)
        }
        return .object(members)
    }
}

// MARK: - Reading config.json's Entries

/// A place in config.json, for the log lines that say what reading it
/// repaired: a member's name, or an index in an array.
struct LibraryViewFileKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    /// The member named `name`.
    init(_ name: String) {
        stringValue = name
        intValue = nil
    }

    /// The element at `index`.
    init(_ index: Int) {
        stringValue = "\(index)"
        intValue = index
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.init(intValue)
    }
}

/// Reading one entry of config.json's `libraryViews`, an untrusted value:
/// where it is, for the log, and whether its repairs are logged at all.
/// Entries TextMouth wrote to the preferences store are read without
/// logging, since they need no repair.
struct LibraryViewEntryReading {
    /// The source named in log lines, such as "config.json"; nil logs
    /// nothing.
    let source: String?
    /// Where the value being read is.
    let path: [LibraryViewFileKey]

    /// The reading of the member `name` of the value read now.
    func member(_ name: String) -> LibraryViewEntryReading {
        LibraryViewEntryReading(source: source, path: path + [LibraryViewFileKey(name)])
    }

    /// The reading of the element `index` of the value read now.
    func element(_ index: Int) -> LibraryViewEntryReading {
        LibraryViewEntryReading(source: source, path: path + [LibraryViewFileKey(index)])
    }

    /// Logs a repair of the member `name` (or of the value itself, for
    /// nil). `detail` names the kind of repair alone, never a name or a text
    /// the listener typed, which the logs must not hold.
    func logRepair(of name: String?, _ detail: String) {
        guard let source else { return }
        let place = name.map { path + [LibraryViewFileKey($0)] } ?? path
        StoredValueRepair.log(source: source, codingPath: place, detail: detail)
    }

    /// `value` moved into `range`, with the move logged as a repair of the
    /// member `name`.
    func clamped(_ value: Int, into range: ClosedRange<Int>, member name: String) -> Int {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        if clamped != value {
            logRepair(of: name, "moved a number out of range to \(clamped)")
        }
        return clamped
    }

    /// `text` cut to `limit` characters, and trimmed of the whitespace the
    /// cut leaves at its end, with the cut logged as a repair of the member
    /// `name`.
    func cut(_ text: String, to limit: Int, member name: String) -> String {
        guard text.count > limit else { return text }
        logRepair(of: name, "cut a text to \(limit) characters")
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension LibraryViewDefinition {
    /// Reads one entry of config.json's `libraryViews` (design section 8),
    /// returning nil when it is unreadable, such as a view a later TextMouth
    /// added, which the list keeps as it was and never offers. Values out of
    /// range are moved into it, and a missing or unknown visibility or
    /// built-in name takes the shipped one, each repair logged as `reading`
    /// says.
    init?(fileEntry: JSONValue, reading: LibraryViewEntryReading) {
        guard case .object(let members) = fileEntry,
              let storedID = members["id"]?.stringValue,
              let id = LibraryViewID(storedValue: storedID) else {
            return nil
        }
        let shipped = Self.shipped(id)
        guard let name = Self.readName(members["name"], shipped: shipped, reading: reading) else { return nil }
        let visibility = Self.readVisibility(members["visibility"], of: id, shipped: shipped, reading: reading)
        let filter: LibraryViewFilter?
        switch id {
        case .category(.folders), .category(.readingList):
            // These list what they always have: a filter is ignored.
            filter = nil
            if members["filter"] != nil {
                reading.logRepair(of: "filter", "ignored a filter on a view that lists what it always has")
            }
        default:
            if let value = members["filter"] {
                if let read = LibraryViewFilter(fileValue: value, reading: reading.member("filter")) {
                    filter = read
                } else if let shipped {
                    // A built-in view keeps its place and shows its own
                    // filter; the one read is written back as it was.
                    filter = shipped.filter
                    reading.logRepair(of: "filter", "showed the built-in view's own filter in place of one this TextMouth cannot read")
                } else {
                    return nil
                }
            } else if let shipped {
                filter = shipped.filter
            } else {
                // A custom view without a filter lists nothing that can be known.
                return nil
            }
        }
        self.init(
            id: id,
            name: name,
            visibility: visibility,
            filter: filter,
            extraFields: members.filter { !Self.fileKeys.contains($0.key) }
        )
        // Every member shown otherwise than it was read is kept as read, to
        // be written back exactly so (review of October 31, 2026, finding 2).
        // `self.` names the entry the view writes; plain `fileEntry` is the
        // parameter, the entry as read.
        let written = self.fileEntry
        for key in Self.repairableKeys where written[key] != members[key] {
            keptAsRead.updateValue(members[key], forKey: key)
        }
    }

    /// The name an entry gives, trimmed and cut to `nameLimit`: a custom
    /// view's own, or nil when it has none, which makes it unreadable; for
    /// Folders and the Reading List always the shipped one; for another
    /// built-in view its own, or the shipped one when it has none.
    private static func readName(
        _ value: JSONValue?,
        shipped: LibraryViewDefinition?,
        reading: LibraryViewEntryReading
    ) -> String? {
        let given = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let shipped else {
            guard let given, !given.isEmpty else { return nil }
            return reading.cut(given, to: nameLimit, member: "name")
        }
        if shipped.kind != .filter {
            if value != nil, given != shipped.name {
                reading.logRepair(of: "name", "kept the built-in view's own name")
            }
            return shipped.name
        }
        guard let given, !given.isEmpty else {
            if value != nil {
                reading.logRepair(of: "name", "replaced an unreadable name with the built-in view's own")
            }
            return shipped.name
        }
        return reading.cut(given, to: nameLimit, member: "name")
    }

    /// The visibility an entry gives, or, when it gives none or one this
    /// TextMouth does not know, the shipped view's, or Always for a custom
    /// view. Folders is always offered, whatever the entry says.
    private static func readVisibility(
        _ value: JSONValue?,
        of id: LibraryViewID,
        shipped: LibraryViewDefinition?,
        reading: LibraryViewEntryReading
    ) -> LibraryViewVisibility {
        var visibility: LibraryViewVisibility
        if let raw = value?.stringValue, let read = LibraryViewVisibility(rawValue: raw) {
            visibility = read
        } else {
            visibility = shipped?.visibility ?? .always
            reading.logRepair(of: "visibility", "replaced a missing or unknown visibility with \(visibility.rawValue)")
        }
        if id == .category(.folders), visibility != .always {
            visibility = .always
            reading.logRepair(of: "visibility", "Folders is always shown")
        }
        return visibility
    }
}

extension LibraryViewFilter {
    /// Reads a filter as config.json holds it, or returns nil when anything
    /// in it is unknown or malformed, so a filter a later TextMouth wrote is
    /// never evaluated wrongly. Numbers out of range and texts too long are
    /// repaired, as `reading` logs.
    init?(fileValue: JSONValue, reading: LibraryViewEntryReading) {
        guard case .object(let members) = fileValue,
              Set(members.keys).isSubset(of: Self.fileKeys),
              case .array(let listed)? = members["lists"],
              !listed.isEmpty else {
            return nil
        }
        var lists = Set<LibraryViewItemKind>()
        for item in listed {
            guard let raw = item.stringValue, let kind = LibraryViewItemKind(rawValue: raw) else { return nil }
            lists.insert(kind)
        }
        self.init(lists: lists)
        if let value = members["match"] {
            guard let raw = value.stringValue, let read = LibraryViewMatch(rawValue: raw) else { return nil }
            match = read
        }
        if let value = members["conditions"] {
            guard case .array(let items) = value, items.count <= Self.conditionLimit else { return nil }
            let conditionsReading = reading.member("conditions")
            for (index, item) in items.enumerated() {
                guard let condition = LibraryViewCondition(fileValue: item, reading: conditionsReading.element(index)) else {
                    return nil
                }
                conditions.append(condition)
            }
        }
        if let value = members["onePerFeed"] {
            if case .bool(let flag) = value {
                onePerFeed = flag
            } else {
                reading.logRepair(of: "onePerFeed", "replaced a value that is not true or false with false")
            }
        }
        if let value = members["limit"], value != .null {
            guard case .object(let limitMembers) = value,
                  Set(limitMembers.keys).isSubset(of: ["count", "chosenBy"]),
                  let count = limitMembers["count"]?.libraryViewWholeNumber,
                  let raw = limitMembers["chosenBy"]?.stringValue,
                  let order = LibraryViewLimit.Order(rawValue: raw) else {
                return nil
            }
            limit = LibraryViewLimit(
                count: reading.member("limit").clamped(count, into: LibraryViewLimit.countRange, member: "count"),
                chosenBy: order
            )
        }
    }
}

extension LibraryViewCondition {
    /// Reads a condition as config.json holds it, or returns nil when its
    /// test, its value, or any key is unknown or malformed. Days out of range
    /// and a text too long are repaired, as `reading` logs.
    init?(fileValue: JSONValue, reading: LibraryViewEntryReading) {
        guard case .object(let members) = fileValue,
              let name = members["test"]?.stringValue,
              let kind = Kind(rawValue: name),
              Set(members.keys).isSubset(of: kind.valueKeys.union(["test", "not"])) else {
            return nil
        }
        var isNegated = false
        if let value = members["not"] {
            guard case .bool(let flag) = value else { return nil }
            isNegated = flag
        }
        guard let test = Self.readTest(kind, from: members, reading: reading) else { return nil }
        self.init(test: test, isNegated: isNegated)
    }

    /// The test of `kind` with the value `members` give it, or nil when the
    /// value is missing or malformed.
    private static func readTest(
        _ kind: Kind,
        from members: [String: JSONValue],
        reading: LibraryViewEntryReading
    ) -> Test? {
        switch kind {
        case .format:
            guard let raw = members["value"]?.stringValue, let format = BookFormat(rawValue: raw) else { return nil }
            return .format(format)
        case .folder:
            let folderID: UUID?
            switch members["folderID"] {
            case nil, .null?:
                folderID = nil
            case .string(let text)?:
                guard let uuid = UUID(uuidString: text) else { return nil }
                folderID = uuid
            default:
                return nil
            }
            var includingSubfolders = false
            if let value = members["includingSubfolders"] {
                guard case .bool(let flag) = value else { return nil }
                includingSubfolders = flag
            }
            return .folder(id: folderID, includingSubfolders: includingSubfolders)
        case .readingState:
            guard let raw = members["value"]?.stringValue, let state = LibraryReadingState(rawValue: raw) else { return nil }
            return .readingState(state)
        case .addedWithin, .openedWithin:
            guard let days = members["days"]?.libraryViewWholeNumber else { return nil }
            let clamped = reading.clamped(days, into: dayRange, member: "days")
            return kind == .addedWithin ? .addedWithin(days: clamped) : .openedWithin(days: clamped)
        case .titleOrAuthorContains:
            guard let text = members["text"]?.stringValue else { return nil }
            return .titleOrAuthorContains(reading.cut(text, to: textLimit, member: "text"))
        case .inReadingList:
            return .inReadingList
        case .hasNewItems:
            return .hasNewItems
        case .subscribed:
            return .subscribed
        }
    }
}

private extension JSONValue {
    /// A whole number, from an integer or a number with no fraction, held in
    /// an `Int` (a whole number beyond its range becomes its nearest bound,
    /// which the caller then moves into its own range); nil for anything
    /// else.
    var libraryViewWholeNumber: Int? {
        switch self {
        case .integer(let whole):
            return Int(clamping: whole)
        case .number(let number) where number.isFinite && number == number.rounded():
            if let exact = Int(exactly: number) {
                return exact
            }
            return number > 0 ? Int.max : Int.min
        default:
            return nil
        }
    }
}
