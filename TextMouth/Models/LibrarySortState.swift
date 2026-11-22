import Foundation

// MARK: - Where a Library Window Is

/// Where a library window is: the view it shows and, in Folders, the folder
/// it shows (TODO A06; views since October 30, 2026,
/// LIBRARY-VIEWS-RESEARCH-2026-10-30.md). This is a place in the library,
/// not the data directory's location on disk.
///
/// Everything that follows from the place alone is decided here: the key its
/// sort setting is saved under, the sort it shows until the user chooses one,
/// its name in the window title, and the folder whose manual order it can
/// rearrange. The window, its Sort menu, and the tests share these rules.
struct LibraryLocation: Equatable {
    /// The view shown, as its definition stood when the location was made.
    var view: LibraryViewDefinition
    /// The folder shown in Folders; "" is the root. The other views keep the
    /// folder last shown in Folders and ignore it.
    var folderPath: String

    /// The location of `view`, at `folderPath` when it is Folders.
    init(view: LibraryViewDefinition, folderPath: String) {
        self.view = view
        self.folderPath = folderPath
    }

    /// The location of one of the five categories' views as TextMouth ships
    /// it (`LibraryViewDefinition.shipped(_:)`), at `folderPath` in Folders.
    init(category: LibraryCategory, folderPath: String) {
        self.init(view: .shipped(category), folderPath: folderPath)
    }

    /// The category whose rules the location follows: its view's own, for
    /// the five categories' views, and All Items' for the Feeds view and
    /// every view the listener makes, which, like All Items, list rows from
    /// every folder in an order no one arranges. It serves the callers that
    /// take a category (`ReadingListOpenRequests`,
    /// `LibraryFolderSettingsTarget`, `LibraryFeedFolders.folderRows`),
    /// which tell Folders and the Reading List from the rest, and the tests;
    /// new code asks `view.kind` and `view.id`.
    var category: LibraryCategory {
        view.id.category ?? .allItems
    }

    /// The key the location's sort setting is saved under in
    /// `Library.folderSortSettings`: the folder path in Folders, a category's
    /// reserved key in the other four categories' views, and, for Feeds and
    /// the listener's views, a key beginning with "/", which no folder path
    /// can match (`LibraryViewDefinition.sortSettingsKey`).
    var sortSettingsKey: String {
        view.sortSettingsKey ?? folderPath
    }

    /// The sort the location shows until the user chooses one.
    var defaultSortSetting: FolderSortSetting {
        view.defaultSortSetting
    }

    /// The location's name in the window title: the folder's own name, or
    /// "All Folders" at the root, in Folders; the view's name elsewhere,
    /// the same words the View pop-up shows.
    var name: String {
        guard view.kind == .folders else { return view.name }
        return folderPath.isEmpty
            ? Self.allFoldersName
            : folderPath.components(separatedBy: "/").last ?? Self.allFoldersName
    }

    /// The name of the root of Folders: every folder's books are reached from
    /// it, so the window title calls it "All Folders".
    nonisolated static var allFoldersName: String {
        // Translators: Name of the library's top level in the Folders view, where the window title and the folder announcements call it that. It holds every folder.
        InterfaceText.line("libraryLocation.allFoldersName", "All Folders")
    }

    /// Whether the location shows its books in an order of its own, which
    /// no sort changes: the Reading List, in the order the user arranges
    /// (FR09). Its Sort menu names that order and offers no other, and no
    /// sort is ever saved for it.
    var keepsItsOwnOrder: Bool {
        view.kind == .readingList
    }

    /// Whether the location's view lists feeds and nothing else, so it has
    /// no sort: feeds are always listed by title, its Sort menu names that
    /// order, and its window title names no sort.
    var listsOnlyFeeds: Bool {
        view.filter?.listsOnlyFeeds ?? false
    }

    /// The folder whose manual order the location shows: the folder shown in
    /// Folders, the root included. Filter views (All Items, Unopened,
    /// Recently Opened, Feeds, and the listener's) mix books from many
    /// folders, which share no one order, so they have none; the Reading
    /// List has an order of its own, which is no folder's.
    var manualOrderFolder: String? {
        view.kind == .folders ? folderPath : nil
    }

    /// The folder whose books the user can rearrange here while `sort` is
    /// shown: the location's manual-order folder, while the books are in
    /// manual order; otherwise nil. Rearranging, by dragging or with Move
    /// Book Up and Move Book Down, saves that folder's order at once and
    /// leaves the sort on manual order.
    func reorderableFolder(sortedBy sort: LibrarySortState) -> String? {
        sort.field == .manual ? manualOrderFolder : nil
    }

    /// What the user can rearrange here while `sort` is shown, by dragging
    /// or with Move Book Up and Move Book Down: a folder's manual order
    /// while the list shows it (`reorderableFolder(sortedBy:)`), the reading
    /// list's order at the Reading List, which always shows it (FR09), and
    /// nothing anywhere else.
    func reorderTarget(sortedBy sort: LibrarySortState) -> LibraryReorderTarget? {
        if keepsItsOwnOrder {
            return .readingList
        }
        return reorderableFolder(sortedBy: sort).map(LibraryReorderTarget.folder)
    }

    /// The library window's title, naming the location and its sort:
    /// "Library: Fiction (Author Descending)", or "Library: Recently Opened
    /// (Manual Order)" for manual order, which has no direction. The Reading
    /// List, whose one order is its own, and a view listing only feeds,
    /// always by title, are named alone: "Library: Reading List", "Library:
    /// Feeds".
    func windowTitle(sortedBy sort: LibrarySortState) -> String {
        if keepsItsOwnOrder || listsOnlyFeeds {
            // Translators: Title of a Library window that shows a view with one fixed order, such as the Reading List. %@ is the view's name.
            return InterfaceText.line("libraryLocation.windowTitle.name", "Library: \(name)")
        }
        // Translators: Title of a Library window. %1$@ is the name of the folder or view it shows. %2$@ is its sort, such as "Title Ascending" or "Manual Order".
        return InterfaceText.line("libraryLocation.windowTitle.nameAndSort", "Library: \(name) (\(sort.titleFragment))")
    }
}

// MARK: - What Can Be Rearranged

/// An order the user arranges, by dragging or with Move Book Up and Move
/// Book Down, which a Library window rearranges where it shows it.
enum LibraryReorderTarget: Equatable {
    /// The manual order of the books in the folder at this path (TODO A06).
    case folder(String)
    /// The reading list's own order (FR09).
    case readingList
}

// MARK: - A Change the User Makes

/// A change the user makes in the Sort menu. Only these are ever saved:
/// showing a location's sort never writes anything (TODO A06).
enum LibrarySortChange: Equatable {
    /// A field was chosen. Choosing the field already shown, the one the
    /// menu checks, leaves the sort as it is (TODO A11): only the direction
    /// command reverses it.
    case choose(LibrarySortField)
    /// Sort Ascending or Sort Descending was chosen: the direction reverses.
    case reverseDirection
}

extension LibrarySortField {
    /// Whether books sorted by this field can run either way. Every field
    /// can except manual order, which is the order the user arranged.
    var hasDirection: Bool {
        self != .manual
    }
}

// MARK: - The Sort a Location Shows

/// The sort a library location shows: its field, its direction, and the
/// direction it remembers for each of its other fields (TODO A06).
///
/// The window restores a location's sort from its saved setting, with
/// `Library.sortState(at:)`, every time it draws, so the first frame, a
/// change of folder or category, a change made in another window, and a
/// library replaced by index recovery all show the saved sort. Everything
/// that shows the sort derives from this one value (the window title, the
/// Sort menu's checked field and direction command, the Sort button's spoken
/// label, and the order of the books), so none of them can disagree.
///
/// The rule for manual order:
/// - Manual order has no direction. Books in manual order always appear in
///   the order the user arranged; the direction command is disabled, with
///   the hint "Manual order has no direction"; and the window title and the
///   Sort button name no direction.
/// - A saved setting whose field is manual ignores its `sortAscending`,
///   which earlier versions could save as descending.
/// - A location remembers the direction it last showed each field in.
///   Choosing a field shows it in that direction, or ascending when the
///   location has not shown it, so leaving manual order restores the chosen
///   field's last direction.
/// - Books can be rearranged only where the list shows one folder's manual
///   order, or at the Reading List, which always shows its own (see
///   `LibraryLocation.reorderTarget(sortedBy:)`); doing so saves the order
///   at once and leaves the field on manual order.
struct LibrarySortState: Equatable {
    /// The field the books are sorted by.
    let field: LibrarySortField
    /// Whether the books run ascending. Always true for manual order, which
    /// has no direction.
    let isAscending: Bool
    /// The direction (true for ascending) the location last showed each of
    /// its other fields in. Never holds the field shown, or manual order.
    let rememberedDirections: [LibrarySortField: Bool]

    /// Restores the sort a location shows from the setting saved for it: the
    /// one way a sort is loaded. It only reads, normalizing the setting (see
    /// `FolderSortSetting.normalized`); it never saves.
    init(restoring setting: FolderSortSetting) {
        let normalized = setting.normalized
        field = normalized.sortField
        isAscending = normalized.sortAscending
        rememberedDirections = normalized.rememberedDirections
    }

    /// The setting that saves this sort.
    var setting: FolderSortSetting {
        FolderSortSetting(
            sortField: field,
            sortAscending: isAscending,
            rememberedDirections: rememberedDirections
        )
    }

    /// Whether the sort has a direction: every field except manual order.
    var hasDirection: Bool {
        field.hasDirection
    }

    /// The sort after the user makes `change`. A change that does nothing,
    /// such as reversing manual order or choosing the field already shown,
    /// returns the sort unchanged, so it compares equal and nothing needs
    /// saving.
    func applying(_ change: LibrarySortChange) -> LibrarySortState {
        var next = setting
        switch change {
        case .reverseDirection:
            next.sortAscending.toggle()
        case .choose(let chosen) where chosen == field:
            // The checked field chosen again leaves the books as they are
            // (TODO A11). It used to reverse them; only the direction
            // command does that now.
            return self
        case .choose(let chosen):
            // Remember the direction being left, then show the chosen field
            // the way this location last showed it, or ascending.
            next.rememberedDirections[field] = isAscending
            next.sortField = chosen
            next.sortAscending = rememberedDirections[chosen] ?? true
        }
        // Restoring normalizes: it undoes a reversal of manual order, and
        // forgets what must not be remembered (the field now shown, and
        // manual order).
        return LibrarySortState(restoring: next)
    }
}

// MARK: - Showing the Sort

extension LibrarySortState {
    /// The field, then its direction when it has one: "Title, ascending",
    /// or "Manual Order".
    private var spokenSort: String {
        guard hasDirection else { return field.title }
        return isAscending
            // Translators: A sort, spoken: a sort field and its direction. %@ is the sort field's name, such as Title or Date Added. Used inside announcements and labels about the sort.
            ? InterfaceText.line("librarySortState.spokenSort.ascending", "\(field.title), ascending")
            // Translators: A sort, spoken: a sort field and its direction. %@ is the sort field's name, such as Title or Date Added. Used inside announcements and labels about the sort.
            : InterfaceText.line("librarySortState.spokenSort.descending", "\(field.title), descending")
    }

    /// The sort in the window title: "Title Ascending", or "Manual Order".
    var titleFragment: String {
        guard hasDirection else { return field.title }
        return isAscending
            // Translators: The sort in a Library window's title: a sort field and its direction, ascending. %@ is the sort field's name, such as Title or Date Added.
            ? InterfaceText.line("librarySortState.titleFragment.ascending", "\(field.title) Ascending")
            // Translators: The sort in a Library window's title: a sort field and its direction, descending. %@ is the sort field's name, such as Title or Date Added.
            : InterfaceText.line("librarySortState.titleFragment.descending", "\(field.title) Descending")
    }

    /// Whether the Sort menu checks `candidate`: only the field shown is.
    func isChecked(_ candidate: LibrarySortField) -> Bool {
        candidate == field
    }

    /// The title of the Sort menu's direction command, which says what it
    /// does: "Sort Descending" while ascending, "Sort Ascending" while
    /// descending.
    var directionCommandTitle: String {
        isAscending
            // Translators: Title of the Sort menu's command that reverses the sort, while the books are sorted ascending. It switches them to descending.
            ? InterfaceText.line("librarySortState.directionTitle.descending", "Sort Descending")
            // Translators: Title of the Sort menu's command that reverses the sort, while the books are sorted descending. It switches them to ascending.
            : InterfaceText.line("librarySortState.directionTitle.ascending", "Sort Ascending")
    }

    /// Whether the direction command can be chosen: not in manual order.
    var isDirectionCommandEnabled: Bool {
        hasDirection
    }

    /// Why manual order offers no direction: the direction command's hint,
    /// and the view editor's Order pop-up's, while it is dimmed.
    nonisolated static var manualOrderHasNoDirection: String {
        // Translators: Hint of the Sort menu's direction command, and of the library view editor's order pop-up, while the books are in manual order, which has no ascending or descending.
        InterfaceText.line("librarySortState.manualOrderHasNoDirection", "Manual order has no direction")
    }

    /// The direction command's hint, which VoiceOver speaks and the pointer
    /// shows as a tooltip. In manual order it says why the command is off.
    var directionCommandHint: String {
        hasDirection
            // Translators: Hint of the Sort menu's direction command: it reverses the order of the books shown.
            ? InterfaceText.line("librarySortState.directionCommandHint", "Reverses the order of the books")
            : Self.manualOrderHasNoDirection
    }

    /// The Sort button's spoken label: "Sort books by Title, ascending", or
    /// "Sort books by Manual Order".
    var menuAccessibilityLabel: String {
        // Translators: Spoken label of the Sort button. %@ is the current sort, such as "Title, ascending" or "Manual Order".
        InterfaceText.line("common.sortBooksByValue", "Sort books by \(spokenSort)")
    }

    /// What VoiceOver says when the user changes the sort: "Sorted by
    /// Author, descending", or "Sorted by Manual Order".
    var changeAnnouncement: String {
        // Translators: VoiceOver announcement after the sort changes. %@ is the new sort, such as "Author, descending" or "Manual Order".
        InterfaceText.line("common.sortedByValue", "Sorted by \(spokenSort)")
    }

    /// What VoiceOver says when the user applies this sort to every
    /// subfolder: "All subfolders now sorted by Title, ascending".
    var subfolderAnnouncement: String {
        // Translators: VoiceOver announcement after the sort is applied to every subfolder. %@ is the sort, such as "Title, ascending".
        InterfaceText.line("librarySortState.subfolderAnnouncement", "All subfolders now sorted by \(spokenSort)")
    }

    /// The books in this sort's order: the one comparator every library list
    /// uses. Manual order is always ascending, because it has no direction.
    /// File sizes come from `fileSizes`, which `LibraryViewModel.sortedBooks`
    /// takes from sizes measured once per book and kept until its file
    /// changes (`LibraryListCache`), never once per comparison. Titles are
    /// read as `articles`, the Leading articles setting, says.
    func sorted(_ books: [Book], fileSizes: [UUID: Int] = [:], articles: LeadingArticles = .partOfTitle) -> [Book] {
        LibraryBookSorter.sorted(books, by: field, ascending: isAscending, fileSizes: fileSizes, articles: articles)
    }
}

// MARK: - Restoring

extension Library {
    /// The sort `location` shows, restored from the setting saved for it, or
    /// from its category's default when none is saved (TODO A06). This is
    /// the one function every window, menu, and list uses to load a sort.
    func sortState(at location: LibraryLocation) -> LibrarySortState {
        LibrarySortState(restoring: sortSetting(at: location))
    }

    /// The setting saved for `location`, or its category's default. At
    /// Unopened, a sort saved while the category was named No Folder (under
    /// `LibraryCategory.formerNoFolderSortSettingsKey`) is carried over by
    /// being read here, until a sort is chosen at Unopened, which is saved
    /// under Unopened's own key and shadows it; nothing is ever written
    /// under the old key. A No Folder sort of manual order is not carried
    /// over: it was the arrangement of the root's books, which books from
    /// many folders do not share, so Unopened shows its default instead.
    /// The Reading List always shows its own order (FR09), whatever is
    /// saved under its key.
    func sortSetting(at location: LibraryLocation) -> FolderSortSetting {
        if location.keepsItsOwnOrder {
            return location.defaultSortSetting
        }
        if let saved = folderSortSettings[location.sortSettingsKey] {
            return saved
        }
        if location.category == .unopened,
           let former = folderSortSettings[LibraryCategory.formerNoFolderSortSettingsKey],
           former.sortField.hasDirection {
            return former
        }
        return location.defaultSortSetting
    }
}
