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
            return "Choose a folder name that is not empty, is not \".\" or \"..\", "
                + "does not end in \".tmb\", and is not reserved by TextMouth."
        case .invalidPath(let path):
            if path.isEmpty {
                return "This folder has no stored name, so it cannot be changed safely."
            }
            return "\(Self.quoted(path)) is not a valid library folder location."
        case .folderNotFound:
            return "The folder is no longer in the library. It may have been moved, "
                + "renamed, or deleted in another window."
        case .destinationNotFound(let path):
            return "The destination folder \(Self.quoted(path)) is no longer in the library."
        case .unchanged:
            return "The folder already has that name and location."
        case .nameInUse(let proposedPath, let existingPath):
            let sentence = "A folder named \(Self.quoted(Self.name(of: existingPath))) "
                + "already exists in \(Self.place(Self.parent(of: existingPath)))."
            // Explain refusals whose spellings differ, which would otherwise
            // look like two different names.
            guard !BookFolder.spellingsMatch(proposedPath, existingPath) else { return sentence }
            return sentence + " Names that differ only in capitalization or accent "
                + "encoding refer to the same folder on this disk."
        case .namesCollide(let firstPath, let secondPath, let parentPath):
            return "The folders \(Self.quoted(Self.name(of: firstPath))) and "
                + "\(Self.quoted(Self.name(of: secondPath))) cannot both be moved into "
                + "\(Self.place(parentPath)), because their names refer to the same "
                + "folder on this disk."
        case .destinationInsideFolder(let folderPath, let destinationPath):
            return "Choose a destination outside \(Self.quoted(folderPath)). "
                + "\(Self.quoted(destinationPath)) is that folder or one of its subfolders."
        case .tooDeep(let path):
            let depth = FolderSubtree.components(of: path).count
            return "That would place \(Self.quoted(path)) \(depth) levels deep, but folders "
                + "can be nested at most \(BookFolder.maxDepth) levels."
        }
    }

    // MARK: - Formatting

    /// Wraps a name or path in straight double quotes.
    private static func quoted(_ text: String) -> String {
        "\"\(text)\""
    }

    /// Names a folder location, spelling out the library root.
    private static func place(_ folderPath: String) -> String {
        folderPath.isEmpty ? "Library Root" : quoted(folderPath)
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
