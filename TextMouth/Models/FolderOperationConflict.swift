import Foundation

/// Why the library refused a folder edit. Every case carries the paths
/// involved, so the message can tell a VoiceOver user exactly which folders
/// collided and where, instead of the edit failing silently.
enum FolderOperationConflict: Error, Equatable {
    /// The name is empty, "." or "..", ends in ".tmb", or is reserved.
    case invalidName
    /// A folder path is not a safe relative library path.
    case invalidPath(String)
    /// The folder being edited is no longer in the library.
    case folderNotFound
    /// The destination is neither the library root nor an existing folder.
    case destinationNotFound(String)
    /// The edit would leave the folder exactly as it is.
    case unchanged
    /// The result would name the same directory as an existing folder.
    case nameInUse(proposedPath: String, existingPath: String)
    /// Two folders moving together would land on the same name in `parentPath`.
    case namesCollide(firstPath: String, secondPath: String, parentPath: String)
    /// The destination is the folder itself or one of its subfolders.
    case destinationInsideFolder(folderPath: String, destinationPath: String)
    /// The edit would nest `path` deeper than `BookFolder.maxDepth`.
    case tooDeep(String)
}

extension FolderOperationConflict: LocalizedError {
    var errorDescription: String? { message }

    /// A complete sentence that names the folders involved. Folder names are
    /// quoted and locations are spelled out ("Library Root" for the top
    /// level), matching the folder pickers.
    var message: String {
        switch self {
        case .invalidName:
            // Translators: Error shown when a folder's new name is refused: the name is empty, is a single or double dot, ends in .tmb, or is one TextMouth keeps for itself. The quoted pieces are literal text.
            return InterfaceText.line("folderOperationConflict.invalidName", "A folder name can't be empty, \".\" or \"..\", end in \".tmb\", or be reserved by TextMouth.")
        case .invalidPath(let path):
            if path.isEmpty {
                // Translators: Error shown when a folder edit is refused because the folder has no name on record.
                return InterfaceText.line("folderOperationConflict.invalidPath.changed", "This folder has no stored name, so it cannot be changed safely.")
            }
            // Translators: Error shown when a folder edit is refused because its location is not a safe library path. %@ is the location, in straight double quotes.
            return InterfaceText.line("folderOperationConflict.invalidPath.location", "\(Self.quoted(path)) is not a valid library folder location.")
        case .folderNotFound:
            // Translators: Error shown when a folder edit is refused because the folder is gone from the library.
            return InterfaceText.line("folderOperationConflict.folderNotFound", "The folder is no longer in the library. It may have been moved, renamed, or deleted in another window.")
        case .destinationNotFound(let path):
            // Translators: Error shown when a move is refused because the folder it goes into is gone from the library. %@ is that folder's location, in straight double quotes.
            return InterfaceText.line("folderOperationConflict.destinationNotFound", "The destination folder \(Self.quoted(path)) is no longer in the library.")
        case .unchanged:
            // Translators: Error shown when a folder edit would leave the folder exactly as it is.
            return InterfaceText.line("folderOperationConflict.unchanged", "The folder already has that name and location.")
        case .nameInUse(let proposedPath, let existingPath):
            // Translators: Error shown when a folder's new name or place is taken. %1$@ is the existing folder's name, in straight double quotes. %2$@ is where it is: its folder's location in straight double quotes, or the name of the library's top level.
            let sentence = InterfaceText.line("folderOperationConflict.nameInUse.already", "A folder named \(Self.quoted(Self.name(of: existingPath))) already exists in \(Self.place(Self.parent(of: existingPath))).")
            // Explain refusals whose spellings differ, which would otherwise
            // look like two different names.
            guard !BookFolder.spellingsMatch(proposedPath, existingPath) else { return sentence }
            return SentenceWording.joined([
                sentence,
                // Translators: Second sentence of the error about a folder name that is taken, added when the two names are spelled differently, in capital letters or in how an accent is stored.
                InterfaceText.line("folderOperationConflict.nameInUse.capitalization", "Names that differ only in capitalization or accent encoding refer to the same folder on this disk."),
            ])
        case .namesCollide(let firstPath, let secondPath, let parentPath):
            // Translators: Error shown when two folders moved together would land on the same name. %1$@ and %2$@ are the two folders' names, in straight double quotes. %3$@ is where they go: a folder's location in straight double quotes, or the name of the library's top level.
            return InterfaceText.line("folderOperationConflict.namesCollide", "The folders \(Self.quoted(Self.name(of: firstPath))) and \(Self.quoted(Self.name(of: secondPath))) can't both move into \(Self.place(parentPath)): their names mean the same folder on this disk.")
        case .destinationInsideFolder(let folderPath, let destinationPath):
            return SentenceWording.joined([
                // Translators: First sentence of the error shown when a folder is moved into itself. %@ is the folder's location, in straight double quotes.
                InterfaceText.line("folderOperationConflict.chooseOutsideFolder", "Choose a destination outside \(Self.quoted(folderPath))."),
                // Translators: Second sentence of the error shown when a folder is moved into itself. %@ is the chosen destination's location, in straight double quotes.
                InterfaceText.line("folderOperationConflict.insideFolder", "\(Self.quoted(destinationPath)) is that folder or one of its subfolders."),
            ])
        case .tooDeep(let path):
            let depth = FolderSubtree.components(of: path).count
            // Translators: Error shown when a folder edit would nest a folder too deep. %1$@ is the folder's location, in straight double quotes. %2$lld is how many levels deep it would be. %3$lld is the most levels allowed.
            return InterfaceText.line("folderOperationConflict.tooDeep", "That would put \(Self.quoted(path)) \(number: depth) levels deep, but folders nest at most \(number: BookFolder.maxDepth) levels.")
        }
    }

    // MARK: - Formatting

    /// Wraps a name or path in straight double quotes.
    private static func quoted(_ text: String) -> String {
        "\"\(text)\""
    }

    /// The name the library's top level goes by in a folder picker and in
    /// these messages. Every place that names it reads this one.
    nonisolated static var libraryRootName: String {
        // Translators: The name of the library's top level, the place that holds the folders and the books outside any folder. Shown as a folder choice, and in messages that say where a folder is.
        InterfaceText.line("common.libraryRoot", "Library Root")
    }

    /// Names a folder location, spelling out the library root.
    private static func place(_ folderPath: String) -> String {
        folderPath.isEmpty ? libraryRootName : quoted(folderPath)
    }

    /// The last folder name in a library path.
    private static func name(of path: String) -> String {
        FolderSubtree.components(of: path).last ?? ""
    }

    /// The library path of the folder containing `path`.
    private static func parent(of path: String) -> String {
        FolderSubtree.path(from: Array(FolderSubtree.components(of: path).dropLast()))
    }
}
