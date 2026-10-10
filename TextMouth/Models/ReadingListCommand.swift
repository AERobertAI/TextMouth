import Foundation

/// A reading list command of a library row (FR09): an item of the row's
/// context menu and one of its VoiceOver actions, under the same name,
/// acting on the same books: Add to Reading List for the row's books not in
/// the list, and Remove from Reading List for those in it.
struct ReadingListCommand: Identifiable, Equatable {
    /// What a command does.
    enum Kind: Equatable {
        /// Add to Reading List: appends the books to the end of the list.
        case add
        /// Remove from Reading List: takes the books off the list; they
        /// stay in the library.
        case remove
    }

    /// What the command does.
    let kind: Kind
    /// The books it acts on, in list order.
    let books: [Book]
    /// Its title in the menu, which is also its VoiceOver action's name.
    let title: String

    /// A row offers each kind at most once, so the kind identifies it.
    var id: Kind { kind }

    /// The reading list commands for `targets`, the books a row's commands
    /// act on, given the books `inList` holds: Add to Reading List for
    /// those not in the list, then Remove from Reading List for those in
    /// it, each acting on its own books. A row's own book is offered
    /// exactly one of them, by membership; a selection holding books of
    /// both kinds is offered both, each titled with its count of books.
    /// - Parameters:
    ///   - targets: The books the row's commands act on, in list order.
    ///   - isSelection: Whether the row belongs to a selection of several
    ///     books, whose commands count their books in their titles.
    ///   - inList: The IDs of the books in the reading list.
    static func commands(for targets: [Book], isSelection: Bool, inList: Set<UUID>) -> [ReadingListCommand] {
        let adding = targets.filter { !inList.contains($0.id) }
        let removing = targets.filter { inList.contains($0.id) }
        var commands: [ReadingListCommand] = []
        if !adding.isEmpty {
            let title = ReadingListWording.addTitle(count: adding.count, forSelection: isSelection)
            commands.append(ReadingListCommand(kind: .add, books: adding, title: title))
        }
        if !removing.isEmpty {
            let title = ReadingListWording.removeTitle(count: removing.count, forSelection: isSelection)
            commands.append(ReadingListCommand(kind: .remove, books: removing, title: title))
        }
        return commands
    }

    /// The reading list commands of the Library window's edit-mode bar,
    /// beside Move, for `selection`, the books selected, in list order
    /// (FR09): as a selection's row offers them, Add to Reading List for
    /// the books not in the list and Remove from Reading List for those in
    /// it, each acting on its own books. With nothing selected, the one the
    /// view suggests, acting on no book, which the bar shows dimmed, so the
    /// command is found before a book is chosen: Remove from Reading List
    /// at the Reading List, where every book is in the list, and Add to
    /// Reading List everywhere else.
    /// - Parameters:
    ///   - selection: The selected books the list shows, in its order.
    ///   - inList: The IDs of the books in the reading list.
    ///   - atReadingList: Whether the window shows the Reading List.
    static func editBarCommands(for selection: [Book], inList: Set<UUID>, atReadingList: Bool) -> [ReadingListCommand] {
        guard selection.isEmpty else {
            return commands(for: selection, isSelection: true, inList: inList)
        }
        let kind: Kind = atReadingList ? .remove : .add
        return [ReadingListCommand(kind: kind, books: [], title: ReadingListWording.editBarTitle(kind))]
    }
}
