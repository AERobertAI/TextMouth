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
        /// Downloads the book's files from the cloud now (FR43: a book not on this device yet).
        case downloadNow
        /// Removes the book's download from this iPhone while it stays in iCloud Drive (FR46).
        case removeDownload
        /// Keeps the book's files on every device that syncs (FR43, section 16).
        case keepOnAllDevices
        /// Ends keeping the book's files on every device that syncs.
        case stopKeepingOnAllDevices
        /// Opens the Export sheet for the book.
        case export
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
        /// Opens the Export sheet for every book in the folder and below it, each into a folder of its own.
        case exportFolder
        /// Deletes the folder, asking what becomes of what it holds.
        case deleteFolder
        /// One of a feed's commands, offered by its row in the Feeds section (FR53): the Mac's `FeedCommand`.
        case feed(FeedCommand)
        /// One of a feed item's commands, offered by the row of an item not downloaded, and beside the book's own
        /// by the row of a downloaded one (FR53): the Mac's `FeedItemCommand`.
        case feedItem(FeedItemCommand)
    }

    /// One command a row offers: what it does, and its name.
    struct Command: Identifiable, Equatable, Sendable {
        /// What the command does.
        let action: Action
        /// Its name on the Actions rotor and in the context menu.
        let title: String
        /// Whether the command deletes something of the listener's, which the context menu marks as destructive: a
        /// book's removal, Delete Feed…, and a feed item's Delete Episode… (FR53).
        var isDestructive = false

        /// A row offers each action at most once, so the action identifies it.
        var id: Action { action }

        /// The command of `action`, a feed's command as the Mac offers it (FR53).
        init(_ action: FeedAction) {
            self.init(action: .feed(action.command), title: action.title, isDestructive: action.deletes)
        }

        /// The command of `action`, a feed item's command as the Mac offers it (FR53).
        init(_ action: FeedItemAction) {
            self.init(action: .feedItem(action.command), title: action.title, isDestructive: action.role == .destructive)
        }

        /// A command that does `action` under `title`; destructive when `isDestructive`.
        init(action: Action, title: String, isDestructive: Bool = false) {
            self.action = action
            self.title = title
            self.isDestructive = isDestructive || action == .remove
        }
    }

    /// The commands of `book`'s row, each only where it applies, in the
    /// spec's order: Book Info; Add to Reading List or Remove from Reading
    /// List; Move to Folder...; Export...; Move Up and Move Down, where the
    /// list shows an order the listener arranges; then the removal.
    ///
    /// - Parameters:
    ///   - book: The row's book.
    ///   - isInReadingList: Whether the book is in the reading list.
    ///   - moves: The book's moves through the order the list shows, or nil
    ///     where the list shows no order the listener arranges.
    ///   - removal: The removal preferences in force, which name the removal:
    ///     "Remove from Library..." when it asks first.
    ///   - isKeptOnAllDevices: Whether the book is kept on all devices, or nil
    ///     while sync is off, when neither keep command is offered (R1: nothing
    ///     is added before a folder is chosen).
    ///   - canDownload: Whether the book's files are only in the cloud, so Download Now is offered (FR43).
    ///   - canRemoveDownload: Whether the book is whole on this device in a synced library, so Remove Download is offered (FR46).
    ///   - feedActions: The commands of the feed item the book was downloaded from, which the Mac's row offers after
    ///     the cloud commands and in place of the removal, since Delete Download is the removal of a feed item (FR53).
    static func bookCommands(
        for book: Book,
        isInReadingList: Bool,
        moves: LibraryManualMoves?,
        removal: RemovalPreferences,
        isKeptOnAllDevices: Bool? = nil,
        canDownload: Bool = false,
        canRemoveDownload: Bool = false,
        feedActions: [FeedItemAction] = []
    ) -> [Command] {
        var commands = [Command(action: .bookInfo, title: PhoneLibraryVocabulary.bookInfo)]
        // The Mac's own rule: a book is offered exactly one of the two, by
        // whether the reading list holds it.
        let inList: Set<UUID> = isInReadingList ? [book.id] : []
        for listCommand in ReadingListCommand.commands(for: [book], isSelection: false, inList: inList) {
            let action: Action = listCommand.kind == .add ? .addToReadingList : .removeFromReadingList
            commands.append(Command(action: action, title: listCommand.title))
        }
        // Download Now for a book not on this device, as the Mac offers it.
        if canDownload {
            commands.append(Command(action: .downloadNow, title: LibraryCloudWording.downloadTitle(count: 1, forSelection: false)))
        }
        // Remove Download for a book whole on this device in a synced library, in the Mac's place after Download Now.
        if canRemoveDownload {
            commands.append(Command(action: .removeDownload, title: LibraryCloudWording.removeDownloadTitle(count: 1, forSelection: false)))
        }
        // One of the two keep commands, with sync on.
        if let isKept = isKeptOnAllDevices {
            commands.append(isKept
                ? Command(action: .stopKeepingOnAllDevices, title: SyncWording.stopKeepingTitle)
                : Command(action: .keepOnAllDevices, title: SyncWording.keepTitle))
        }
        // Nil for a feed's item, which stays in its feed's folder.
        if let moveTitle = LibraryTransitionWording.moveToFolderTitle(for: [book]) {
            commands.append(Command(action: .moveToFolder, title: moveTitle))
        }
        // The Mac's own command, in the Mac's place: after Move to Folder...
        // and before the moves and the removal (FR31).
        commands.append(Command(action: .export, title: BookExportWording.commandTitle(count: 1)))
        for move in moves?.offered ?? [] {
            let action: Action = move.direction < 0 ? .moveUp : .moveDown
            commands.append(Command(action: action, title: move.title))
        }
        // The commands of the feed item the book came from, as the Mac's row offers them (FR53).
        commands += feedActions.map { Command($0) }
        // One feed item's own Delete Download stands for the removal, so a row never offers both (REV11 F2).
        if LibraryRemoveCommandWording.isOfferedOnRow(for: [book], feedActions: feedActions) {
            let removeTitle = LibraryRemoveCommandWording(preferences: removal, books: [book]).menuTitle
            commands.append(Command(action: .remove, title: removeTitle))
        }
        return commands
    }

    /// The commands of a folder's row, in the Mac's order: Rename Folder...,
    /// Move Folder..., Export 12 Books... where the folder holds books (FR31, phase 3), and Delete Folder... where the
    /// Mac offers it (`LibraryViewModel.offersDeleteFolder(_:)`). `bookCount` is the books in the folder and every
    /// folder below it, as the row says them, and names the Mac's own command ("Export…" for one book).
    static func folderCommands(offersDelete: Bool, bookCount: Int = 0) -> [Command] {
        var commands = [
            Command(action: .renameFolder, title: PhoneLibraryVocabulary.renameFolder),
            Command(action: .moveFolder, title: PhoneLibraryVocabulary.moveFolder),
        ]
        if bookCount > 0 {
            commands.append(Command(action: .exportFolder, title: BookExportWording.commandTitle(count: bookCount)))
        }
        if offersDelete {
            commands.append(Command(action: .deleteFolder, title: PhoneLibraryVocabulary.deleteFolder))
        }
        return commands
    }
}

// MARK: - The Library's One Alert

/// What the Library's alert shows (the iPhone): the question before a book is removed, or why Remove Download left a
/// book's download (FR46), as the Mac's alert says it. One alert modifier serves both, so the Library, the screen every
/// other screen is pushed over and which stays under the reader and its sheets, holds no more presentations than it
/// did before sync's commands came: a second alert there was the sync branch's one change to the screens under the
/// reader's Export sheet, whose kind switches lost their taps beside it.
enum PhoneLibraryAlert: Equatable {
    /// Asks whether to remove `book` from the library.
    case removal(Book)
    /// Says why Remove Download left a book's download, in the words the command gave.
    case removeDownloadRefused(LibraryCloudRefusal)

    /// The alert's title.
    var title: String {
        switch self {
        case .removal(let book): return PhoneRowWording.removalTitle(for: book)
        case .removeDownloadRefused(let refusal): return refusal.title
        }
    }

    /// The alert's message.
    var message: String {
        switch self {
        case .removal: return PhoneRowWording.removalMessage
        case .removeDownloadRefused(let refusal): return refusal.message
        }
    }
}
