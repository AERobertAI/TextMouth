import Foundation

// MARK: - One Condition as the Editor Shows It

/// One condition as the view editor shows it (the design of October 30,
/// 2026, LIBRARY-VIEWS-RESEARCH-2026-10-30.md, section 7): its kind of test,
/// whether it is negated, and a value for every kind, so switching the test
/// pop-up away and back keeps what was chosen or typed.
struct LibraryViewConditionDraft: Identifiable, Equatable {
    /// Identifies the row while the sheet shows it.
    let id: UUID
    /// The kind of test.
    var kind: LibraryViewCondition.Kind
    /// Whether the condition holds when the test fails.
    var isNegated: Bool
    /// The format a Format condition tests.
    var format: BookFormat = .epub
    /// The folder a Folder condition tests; nil for Library Root.
    var folderID: UUID?
    /// Whether a Folder condition takes in the folders inside it.
    var includingSubfolders = true
    /// The reading state a Reading State condition tests.
    var readingState: LibraryReadingState = .unopened
    /// The days a date condition reaches back.
    var days = 7
    /// The text a Title or Author condition looks for.
    var text = ""

    /// The draft of `condition`: its kind and value, and the defaults for
    /// every other kind's value.
    init(_ condition: LibraryViewCondition) {
        id = UUID()
        kind = condition.test.kind
        isNegated = condition.isNegated
        switch condition.test {
        case .format(let format): self.format = format
        case .folder(let folderID, let includingSubfolders):
            self.folderID = folderID
            self.includingSubfolders = includingSubfolders
        case .readingState(let state): readingState = state
        case .addedWithin(let days), .openedWithin(let days): self.days = days
        case .titleOrAuthorContains(let text): self.text = text
        case .inReadingList, .hasNewItems, .subscribed: break
        }
    }

    /// The condition Add Condition adds: Format is EPUB.
    static func newCondition() -> LibraryViewConditionDraft {
        LibraryViewConditionDraft(LibraryViewCondition(test: .format(.epub)))
    }

    /// The condition the draft makes, its days kept in range and its text
    /// trimmed and cut to the limit.
    var condition: LibraryViewCondition {
        let test: LibraryViewCondition.Test
        let clampedDays = min(max(days, LibraryViewCondition.dayRange.lowerBound), LibraryViewCondition.dayRange.upperBound)
        switch kind {
        case .format: test = .format(format)
        case .folder: test = .folder(id: folderID, includingSubfolders: includingSubfolders)
        case .readingState: test = .readingState(readingState)
        case .inReadingList: test = .inReadingList
        case .addedWithin: test = .addedWithin(days: clampedDays)
        case .openedWithin: test = .openedWithin(days: clampedDays)
        case .titleOrAuthorContains:
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            test = .titleOrAuthorContains(String(trimmed.prefix(LibraryViewCondition.textLimit)))
        case .hasNewItems: test = .hasNewItems
        case .subscribed: test = .subscribed
        }
        return LibraryViewCondition(test: test, isNegated: isNegated)
    }
}

// MARK: - The Editor

/// What the view editor sheet edits (design section 7): a view's name, what
/// it lists, its conditions, its sort, and its limit, as a draft that Save
/// checks (`firstProblem(in:)`) before the Library tab saves the view and
/// its sort.
@MainActor
final class LibraryViewEditorModel: ObservableObject, Identifiable {
    /// Identifies the sheet, and is the new view's identity when there is no
    /// original.
    let id: UUID
    /// The view being changed, or nil for a new one.
    let original: LibraryViewDefinition?

    /// The name typed.
    @Published var name: String
    /// The kinds of rows listed.
    @Published var lists: Set<LibraryViewItemKind>
    /// Whether all conditions or any must hold.
    @Published var match: LibraryViewMatch
    /// The conditions, in order.
    @Published var conditions: [LibraryViewConditionDraft]
    /// Whether only the latest item of each feed is listed.
    @Published var onePerFeed: Bool
    /// Whether the view lists at most `limitCount` rows.
    @Published var limitIsOn: Bool
    /// The most rows listed, while the limit is on.
    @Published var limitCount: Int
    /// Which rows the limit keeps.
    @Published var limitChosenBy: LibraryViewLimit.Order
    /// The field the view's rows are sorted by.
    @Published var sortField: LibrarySortField
    /// Whether they run ascending.
    @Published var sortAscending: Bool
    /// The problem the last Save found, shown and announced; nil when none.
    @Published var problem: String?

    /// A model for a new view: it lists books, all conditions, none yet,
    /// title ascending, with no limit.
    init() {
        id = UUID()
        original = nil
        name = ""
        lists = [.books]
        match = .all
        conditions = []
        onePerFeed = false
        limitIsOn = false
        limitCount = 10
        limitChosenBy = .viewSort
        sortField = .title
        sortAscending = true
    }

    /// A model for changing the filter view `view`, whose sort shown is
    /// `sort`.
    init(editing view: LibraryViewDefinition, sort: FolderSortSetting) {
        id = UUID()
        original = view
        name = view.name
        let filter = view.filter ?? LibraryViewFilter(lists: [.books])
        lists = filter.lists
        match = filter.match
        conditions = filter.conditions.map(LibraryViewConditionDraft.init)
        onePerFeed = filter.onePerFeed
        limitIsOn = filter.limit != nil
        limitCount = filter.limit?.count ?? 10
        limitChosenBy = filter.limit?.chosenBy ?? .viewSort
        let shown = sort.normalized
        sortField = shown.sortField
        sortAscending = shown.sortAscending
    }

    /// The sheet's title: "New View", or "Edit <name>".
    var title: String {
        original.map { LibraryViewEditorWording.editTitle($0.name) } ?? LibraryViewEditorWording.newTitle
    }

    /// Whether another condition may be added: fewer than the limit.
    var canAddCondition: Bool {
        conditions.count < LibraryViewFilter.conditionLimit
    }

    /// Adds Format is EPUB at the end, within the limit.
    func addCondition() {
        guard canAddCondition else { return }
        conditions.append(.newCondition())
    }

    /// Removes the condition `id`.
    func removeCondition(_ id: UUID) {
        conditions.removeAll { $0.id == id }
    }

    /// Whether "Only the Latest from Each Feed" applies: while the draft
    /// lists episodes or articles, the rows feeds have.
    var onePerFeedApplies: Bool {
        !lists.isDisjoint(with: [.episodes, .articles])
    }

    /// Whether Show at Most applies: while the draft lists books,
    /// episodes, or articles, the rows a limit chooses among; feeds are
    /// always listed whole.
    var limitApplies: Bool {
        !lists.isDisjoint(with: [.books, .episodes, .articles])
    }

    /// The draft's filter. One per feed and the limit are saved only where
    /// they apply (`onePerFeedApplies`, `limitApplies`), so a view never
    /// keeps a setting the listener cannot see working (review of October
    /// 31, 2026, finding 6).
    var filter: LibraryViewFilter {
        LibraryViewFilter(
            lists: lists,
            match: match,
            conditions: conditions.map(\.condition),
            onePerFeed: onePerFeed && onePerFeedApplies,
            limit: limitIsOn && limitApplies
                ? LibraryViewLimit(
                    count: min(max(limitCount, LibraryViewLimit.countRange.lowerBound), LibraryViewLimit.countRange.upperBound),
                    chosenBy: limitChosenBy
                )
                : nil
        )
    }

    /// The view the draft makes: the original with this name and filter,
    /// keeping its identity, visibility, and the keys it was read with; or a
    /// new view of the listener's own, always offered, its identity the
    /// model's.
    func definition() -> LibraryViewDefinition {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var view = original else {
            return LibraryViewDefinition(id: .custom(id), name: trimmed, visibility: .always, filter: filter)
        }
        view.name = trimmed
        view.filter = filter
        return view
    }

    /// `shown`, the sort the view shows now, with this field and direction,
    /// normalized as a location shows it: its remembered directions kept,
    /// manual order ascending.
    func sortSetting(from shown: FolderSortSetting) -> FolderSortSetting {
        var setting = shown
        if setting.sortField != sortField {
            setting.rememberedDirections[setting.sortField] = setting.sortAscending
            setting.sortField = sortField
        }
        setting.sortAscending = sortAscending
        return setting.normalized
    }

    /// The first problem with the draft, in the order the sheet shows its
    /// controls, or nil: no name, a name too long or another view's, no
    /// kind listed, or a Title or Author condition looking for nothing.
    func firstProblem(in list: LibraryViewDefinitionList) -> String? {
        // A new view needs room in the list (review of October 31, 2026,
        // finding 1).
        if original == nil, !list.canAdd {
            return LibraryViewsSettingsWording.viewLimit
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return LibraryViewEditorWording.nameMissing
        }
        if trimmed.count > LibraryViewDefinition.nameLimit {
            return LibraryViewEditorWording.nameTooLong
        }
        if list.isNameTaken(trimmed, except: original?.id) {
            return LibraryViewEditorWording.nameTaken(trimmed)
        }
        if lists.isEmpty {
            return LibraryViewEditorWording.nothingListed
        }
        for (index, draft) in conditions.enumerated()
        where draft.kind == .titleOrAuthorContains && draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LibraryViewEditorWording.textMissing(index + 1)
        }
        return nil
    }
}
