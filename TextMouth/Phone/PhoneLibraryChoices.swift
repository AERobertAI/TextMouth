import Foundation

/// What the iPhone Library's two choice sheets offer, Library view and Sort,
/// and what choosing does (the iPhone interface spec, "The Library's top",
/// items 4 and 10). The sheet itself is `PhoneChoiceSheet`; this decides its
/// rows, which is current, and the words, all of them the Mac's.
@MainActor
enum PhoneLibraryChoices {
    // MARK: - Library View

    /// The views the Library view sheet offers a screen showing `current`:
    /// what the Mac's View pop-up offers, but Feeds, and any view that lists
    /// only feeds, since the phone has none.
    static func views(
        in library: LibraryViewModel,
        list: LibraryViewDefinitionList,
        current: LibraryViewID?,
        center: FeedCenter
    ) -> [PhoneChoice<LibraryViewID>] {
        library.offeredViews(in: list, current: current, center: center)
            .filter(isOfferedOnPhone)
            .map { PhoneChoice(id: $0.id, label: $0.name) }
    }

    /// Whether the phone offers `view`: not Feeds, and not a view of feeds
    /// alone.
    nonisolated static func isOfferedOnPhone(_ view: LibraryViewDefinition) -> Bool {
        view.id != .feeds && view.filter?.listsOnlyFeeds != true
    }

    // MARK: - Sort

    /// One row of the Sort sheet.
    enum SortChoice: Hashable, Sendable {
        /// Sorts by this field.
        case field(LibrarySortField)
        /// Reverses the direction: the Mac's "Sort Descending" or "Sort
        /// Ascending".
        case reverseDirection
        /// Gives every subfolder this folder's sort.
        case applyToSubfolders
        /// The Reading List's one order.
        case readingListOrder
    }

    /// The Sort sheet's rows at `location`, whose sort is `sort`: the fields,
    /// then the direction, dimmed in Manual Order with the Mac's hint, then,
    /// in a folder with subfolders, Apply Sort to All Subfolders. The
    /// Reading List offers its one order alone.
    nonisolated static func sortChoices(
        at location: LibraryLocation,
        sort: LibrarySortState,
        hasSubfolders: Bool
    ) -> [PhoneChoice<SortChoice>] {
        guard !location.keepsItsOwnOrder else {
            return [PhoneChoice(id: .readingListOrder, label: ReadingListWording.orderName)]
        }
        var choices = LibrarySortField.allCases.map { PhoneChoice(id: SortChoice.field($0), label: $0.rawValue) }
        choices.append(PhoneChoice(
            id: .reverseDirection,
            label: sort.directionCommandTitle,
            hint: sort.isDirectionCommandEnabled ? nil : LibrarySortState.manualOrderHasNoDirection,
            isEnabled: sort.isDirectionCommandEnabled
        ))
        if location.view.kind == .folders && hasSubfolders {
            choices.append(PhoneChoice(id: .applyToSubfolders, label: PhoneLibraryVocabulary.applySortToSubfolders))
        }
        return choices
    }

    /// The Sort row the sheet marks current at `location`.
    nonisolated static func currentSortChoice(at location: LibraryLocation, sort: LibrarySortState) -> SortChoice {
        location.keepsItsOwnOrder ? .readingListOrder : .field(sort.field)
    }

    /// The Sort button's spoken label, the Mac's: "Sort books by Title,
    /// ascending", or "Sort books by Reading List Order".
    nonisolated static func sortLabel(at location: LibraryLocation, sort: LibrarySortState) -> String {
        location.keepsItsOwnOrder ? ReadingListWording.sortMenuLabel : sort.menuAccessibilityLabel
    }

    /// Makes `choice` at `location`, through the Mac's one path that saves a
    /// sort, and returns what VoiceOver says once the sheet has closed: the
    /// Mac's "Sorted by Title, ascending", "All subfolders now sorted by
    /// Title, ascending", or "Sorted by Reading List Order".
    static func choose(_ choice: SortChoice, at location: LibraryLocation, in library: LibraryViewModel) -> String {
        switch choice {
        case .field(let field):
            return library.userChangedSort(.choose(field), at: location).changeAnnouncement
        case .reverseDirection:
            return library.userChangedSort(.reverseDirection, at: location).changeAnnouncement
        case .applyToSubfolders:
            let sort = library.sortState(at: location)
            library.applySortToSubfolders(sort.setting, from: location.folderPath)
            return sort.subfolderAnnouncement
        case .readingListOrder:
            return ReadingListWording.orderAnnouncement
        }
    }
}
