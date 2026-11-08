import Foundation

/// Which commands a row of the iPhone's Library offers, in which order, under
/// which names (the iPhone interface spec, "A book's row" and "The Library's
/// top"). Each is one of the row's named VoiceOver actions, on the Actions
/// rotor, and the same command in its context menu for touch.
///
/// Every name is the Mac's: called from the shared wording where the Mac has
/// it there, and from `PhoneLibraryVocabulary` where it sits inline in a Mac
/// view. A plain type, so the Mac's test host can read what a row offers.
enum PhoneLibraryOffer {
    /// What a row's command does.
    enum Action: Hashable, Sendable {
        /// Opens the book's Book Info sheet.
        case bookInfo
        /// Puts the book at the end of the reading list.
        case addToReadingList
        /// Takes the book off the reading list; it stays in the library.
        case removeFromReadingList
        /// Asks for a folder, and moves the book there.
        case moveToFolder
        /// Moves the book one place up the order the list shows.
        case moveUp
        /// Moves the book one place down the order the list shows.
        case moveDown
        /// Removes the book, asking first when the preference says so.
        case remove
        /// Renames the folder.
        case renameFolder
        /// Moves the folder into another.
        case moveFolder
        /// Deletes the folder, asking what becomes of what it holds.
        case deleteFolder
    }

    /// One command a row offers: what it does, and its name.
    struct Command: Identifiable, Equatable, Sendable {
        /// What the command does.
        let action: Action
        /// Its name on the Actions rotor and in the context menu.
        let title: String

        /// A row offers each action at most once, so the action identifies it.
        var id: Action { action }
    }

    /// The commands of `book`'s row, each only where it applies, in the
    /// spec's order: Book Info; Add to Reading List or Remove from Reading
    /// List; Move to Folder...; Move Up and Move Down, where the list shows an
    /// order the listener arranges; then the removal.
    ///
    /// - Parameters:
    ///   - book: The row's book.
    ///   - isInReadingList: Whether the book is in the reading list.
    ///   - moves: The book's moves through the order the list shows, or nil
    ///     where the list shows no order the listener arranges.
    ///   - removal: The removal preferences in force, which name the removal:
    ///     "Remove from Library..." when it asks first.
    static func bookCommands(
        for book: Book,
        isInReadingList: Bool,
        moves: LibraryManualMoves?,
        removal: RemovalPreferences
    ) -> [Command] {
        var commands = [Command(action: .bookInfo, title: PhoneLibraryVocabulary.bookInfo)]
        // The Mac's own rule: a book is offered exactly one of the two, by
        // whether the reading list holds it.
        let inList: Set<UUID> = isInReadingList ? [book.id] : []
        for listCommand in ReadingListCommand.commands(for: [book], isSelection: false, inList: inList) {
            let action: Action = listCommand.kind == .add ? .addToReadingList : .removeFromReadingList
            commands.append(Command(action: action, title: listCommand.title))
        }
        // Nil for a feed's item, which stays in its feed's folder.
        if let moveTitle = LibraryTransitionWording.moveToFolderTitle(for: [book]) {
            commands.append(Command(action: .moveToFolder, title: moveTitle))
        }
        for move in moves?.offered ?? [] {
            let action: Action = move.direction < 0 ? .moveUp : .moveDown
            commands.append(Command(action: action, title: move.title))
        }
        let removeTitle = LibraryRemoveCommandWording(preferences: removal, books: [book]).menuTitle
        commands.append(Command(action: .remove, title: removeTitle))
        return commands
    }

    /// The commands of a folder's row, in the Mac's order: Rename Folder...,
    /// Move Folder..., and Delete Folder... where the Mac offers it
    /// (`LibraryViewModel.offersDeleteFolder(_:)`).
    static func folderCommands(offersDelete: Bool) -> [Command] {
        var commands = [
            Command(action: .renameFolder, title: PhoneLibraryVocabulary.renameFolder),
            Command(action: .moveFolder, title: PhoneLibraryVocabulary.moveFolder),
        ]
        if offersDelete {
            commands.append(Command(action: .deleteFolder, title: PhoneLibraryVocabulary.deleteFolder))
        }
        return commands
    }
}
