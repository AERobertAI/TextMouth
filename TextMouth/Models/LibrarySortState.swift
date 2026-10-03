import Foundation

// MARK: - Where a Library Window Is

/// Where a library window is: a category and, in the Folders category, the
/// folder it shows (TODO A06). This is a place in the library, not the data
/// directory's location on disk.
///
/// Everything that follows from the place alone is decided here: the key its
/// sort setting is saved under, the sort it shows until the user chooses one,
/// its name in the window title, and the folder whose manual order it can
/// rearrange. The window, its Sort menu, and the tests share these rules.
struct LibraryLocation: Equatable {
    /// The category shown.
    var category: LibraryCategory
    /// The folder shown in the Folders category; "" is the root. The other
    /// categories keep the folder last shown in Folders and ignore it.
    var folderPath: String

    /// The key the location's sort setting is saved under in
    /// `Library.folderSortSettings`: the folder path in Folders, and in every
    /// other category a reserved key that no folder path can match.
    var sortSettingsKey: String {
        category.sortSettingsKey ?? folderPath
    }

    /// The sort the location shows until the user chooses one.
    var defaultSortSetting: FolderSortSetting {
        category.defaultSortSetting
    }

    /// The location's name in the window title: the folder's own name, or
    /// "All Folders" at the root, or the category's name.
    var name: String {
        switch category {
        case .folders:
            return folderPath.isEmpty
                ? "All Folders"
                : folderPath.components(separatedBy: "/").last ?? "All Folders"
        case .allItems, .noFolder, .recent:
            // The same words the category picker shows.
            return category.rawValue
        }
    }

    /// The folder whose manual order the location shows: the folder shown in
    /// Folders, and the root in No Folder, whose books are exactly the
    /// root's. All Items and Recent mix books from many folders, which share
    /// no one order, so they have none.
    var manualOrderFolder: String? {
        switch category {
        case .folders:
            return folderPath
        case .noFolder:
            return ""
        case .allItems, .recent:
            return nil
        }
    }

    /// The folder whose books the user can rearrange here while `sort` is
    /// shown: the location's manual-order folder, while the books are in
    /// manual order; otherwise nil. Rearranging, by dragging or with Move
    /// Book Up and Move Book Down, saves that folder's order at once and
    /// leaves the sort on manual order.
    func reorderableFolder(sortedBy sort: LibrarySortState) -> String? {
        sort.field == .manual ? manualOrderFolder : nil
    }

    /// The library window's title, naming the location and its sort:
    /// "Library: Fiction (Author Descending)", or "Library: Recent (Manual
    /// Order)" for manual order, which has no direction.
    func windowTitle(sortedBy sort: LibrarySortState) -> String {
        "Library: \(name) (\(sort.titleFragment))"
    }
}

// MARK: - A Change the User Makes

/// A change the user makes in the Sort menu. Only these are ever saved:
/// showing a location's sort never writes anything (TODO A06).
enum LibrarySortChange: Equatable {
    /// A field was chosen. Choosing the field already shown reverses its
    /// direction, as it always has; manual order has none to reverse.
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
///   order (see `LibraryLocation.reorderableFolder(sortedBy:)`); doing so
///   saves the order at once and leaves the field on manual order.
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
    /// such as reversing manual order or choosing it again, returns the sort
    /// unchanged, so it compares equal and nothing needs saving.
    func applying(_ change: LibrarySortChange) -> LibrarySortState {
        var next = setting
        switch change {
        case .reverseDirection:
            next.sortAscending.toggle()
        case .choose(let chosen) where chosen == field:
            next.sortAscending.toggle()
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
    /// The direction in words, or nil for manual order.
    private var directionName: String? {
        guard hasDirection else { return nil }
        return isAscending ? "Ascending" : "Descending"
    }

    /// The field, then its direction when it has one: "Title, ascending",
    /// or "Manual Order".
    private var spokenSort: String {
        [field.rawValue, directionName?.lowercased()]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// The sort in the window title: "Title Ascending", or "Manual Order".
    var titleFragment: String {
        [field.rawValue, directionName]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    /// Whether the Sort menu checks `candidate`: only the field shown is.
    func isChecked(_ candidate: LibrarySortField) -> Bool {
        candidate == field
    }

    /// The title of the Sort menu's direction command, which says what it
    /// does: "Sort Descending" while ascending, "Sort Ascending" while
    /// descending.
    var directionCommandTitle: String {
        isAscending ? "Sort Descending" : "Sort Ascending"
    }

    /// Whether the direction command can be chosen: not in manual order.
    var isDirectionCommandEnabled: Bool {
        hasDirection
    }

    /// The direction command's hint, which VoiceOver speaks and the pointer
    /// shows as a tooltip. In manual order it says why the command is off.
    var directionCommandHint: String {
        hasDirection ? "Reverses the order of the books" : "Manual order has no direction"
    }

    /// The Sort button's spoken label: "Sort books by Title, ascending", or
    /// "Sort books by Manual Order".
    var menuAccessibilityLabel: String {
        "Sort books by \(spokenSort)"
    }

    /// What VoiceOver says when the user changes the sort: "Sorted by
    /// Author, descending", or "Sorted by Manual Order".
    var changeAnnouncement: String {
        "Sorted by \(spokenSort)"
    }

    /// What VoiceOver says when the user applies this sort to every
    /// subfolder: "All subfolders now sorted by Title, ascending".
    var subfolderAnnouncement: String {
        "All subfolders now sorted by \(spokenSort)"
    }

    /// The books in this sort's order: the one comparator every library list
    /// uses. Manual order is always ascending, because it has no direction.
    /// File sizes come from `fileSizes`, which `LibraryViewModel.sortedBooks`
    /// takes from sizes measured once per book and kept until its file
    /// changes (`LibraryListCache`), never once per comparison.
    func sorted(_ books: [Book], fileSizes: [UUID: Int] = [:]) -> [Book] {
        LibraryBookSorter.sorted(books, by: field, ascending: isAscending, fileSizes: fileSizes)
    }
}

// MARK: - Restoring

extension Library {
    /// The sort `location` shows, restored from the setting saved for it, or
    /// from its category's default when none is saved (TODO A06). This is
    /// the one function every window, menu, and list uses to load a sort.
    func sortState(at location: LibraryLocation) -> LibrarySortState {
        LibrarySortState(
            restoring: sortSetting(for: location.sortSettingsKey, default: location.defaultSortSetting)
        )
    }
}
