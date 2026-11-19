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
            return String(localized: "A folder name can't be empty, \".\" or \"..\", end in \".tmb\", or be reserved by TextMouth.",
                          comment: "Error shown when a folder's new name is refused: the name is empty, is a single or double dot, ends in .tmb, or is one TextMouth keeps for itself. The quoted pieces are literal text.")
        case .invalidPath(let path):
            if path.isEmpty {
                return String(localized: "This folder has no stored name, so it cannot be changed safely.",
                              comment: "Error shown when a folder edit is refused because the folder has no name on record.")
            }
            return String(localized: "\(Self.quoted(path)) is not a valid library folder location.",
                          comment: "Error shown when a folder edit is refused because its location is not a safe library path. %@ is the location, in straight double quotes.")
        case .folderNotFound:
            return String(localized: "The folder is no longer in the library. It may have been moved, renamed, or deleted in another window.",
                          comment: "Error shown when a folder edit is refused because the folder is gone from the library.")
        case .destinationNotFound(let path):
            return String(localized: "The destination folder \(Self.quoted(path)) is no longer in the library.",
                          comment: "Error shown when a move is refused because the folder it goes into is gone from the library. %@ is that folder's location, in straight double quotes.")
        case .unchanged:
            return String(localized: "The folder already has that name and location.",
                          comment: "Error shown when a folder edit would leave the folder exactly as it is.")
        case .nameInUse(let proposedPath, let existingPath):
            let sentence = String(localized: "A folder named \(Self.quoted(Self.name(of: existingPath))) already exists in \(Self.place(Self.parent(of: existingPath))).",
                                  comment: "Error shown when a folder's new name or place is taken. %1$@ is the existing folder's name, in straight double quotes. %2$@ is where it is: its folder's location in straight double quotes, or the name of the library's top level.")
            // Explain refusals whose spellings differ, which would otherwise
            // look like two different names.
            guard !BookFolder.spellingsMatch(proposedPath, existingPath) else { return sentence }
            return SentenceWording.joined([
                sentence,
                String(localized: "Names that differ only in capitalization or accent encoding refer to the same folder on this disk.",
                       comment: "Second sentence of the error about a folder name that is taken, added when the two names are spelled differently, in capital letters or in how an accent is stored."),
            ])
        case .namesCollide(let firstPath, let secondPath, let parentPath):
            return String(localized: "The folders \(Self.quoted(Self.name(of: firstPath))) and \(Self.quoted(Self.name(of: secondPath))) can't both move into \(Self.place(parentPath)): their names mean the same folder on this disk.",
                          comment: "Error shown when two folders moved together would land on the same name. %1$@ and %2$@ are the two folders' names, in straight double quotes. %3$@ is where they go: a folder's location in straight double quotes, or the name of the library's top level.")
        case .destinationInsideFolder(let folderPath, let destinationPath):
            return SentenceWording.joined([
                String(localized: "Choose a destination outside \(Self.quoted(folderPath)).",
                       comment: "First sentence of the error shown when a folder is moved into itself. %@ is the folder's location, in straight double quotes."),
                String(localized: "\(Self.quoted(destinationPath)) is that folder or one of its subfolders.",
                       comment: "Second sentence of the error shown when a folder is moved into itself. %@ is the chosen destination's location, in straight double quotes."),
            ])
        case .tooDeep(let path):
            let depth = FolderSubtree.components(of: path).count
            return String(localized: "That would put \(Self.quoted(path)) \(depth) levels deep, but folders nest at most \(BookFolder.maxDepth) levels.",
                          comment: "Error shown when a folder edit would nest a folder too deep. %1$@ is the folder's location, in straight double quotes. %2$lld is how many levels deep it would be. %3$lld is the most levels allowed.")
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
        String(localized: "Library Root",
               comment: "The name of the library's top level, the place that holds the folders and the books outside any folder. Shown as a folder choice, and in messages that say where a folder is.")
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
