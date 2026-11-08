import SwiftUI

/// A folder sheet the Library presents: each one of Slice 2b's
/// `PhoneFolderSheet` initializers, over the library and what it acts on.
enum PhoneLibraryFolderSheet: Hashable {
    /// New Folder, inside the folder at this path ("" is the top).
    case newFolder(parentPath: String)
    /// Rename Folder... of this folder.
    case rename(BookFolder)
    /// Move Folder... of this folder.
    case move(BookFolder)
    /// Delete Folder... of this folder.
    case delete(BookFolder)
    /// Move to Folder... of the book with this ID.
    case moveBook(UUID)
}

/// A sheet a Library screen presents.
enum PhoneLibrarySheet: Identifiable {
    /// Library view's choices.
    case libraryView
    /// Sort's choices.
    case sort
    /// The Book Info sheet of the book with this ID.
    case bookInfo(UUID)
    /// One of the folder sheets.
    case folder(PhoneLibraryFolderSheet)

    /// One sheet at a time, told apart by what it is for.
    var id: String {
        switch self {
        case .libraryView: "libraryView"
        case .sort: "sort"
        case .bookInfo(let bookID): "bookInfo-\(bookID.uuidString)"
        case .folder(let sheet): "folder-\(sheet.hashValue)"
        }
    }
}
