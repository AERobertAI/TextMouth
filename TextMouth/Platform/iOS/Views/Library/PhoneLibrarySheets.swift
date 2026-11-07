import SwiftUI

/// What a Library screen asks of the screens around it that other slices
/// own. Folders, the reader, and Settings are pushed on the model's path; Add
/// to Library is the import slice's sheet, which `PhoneRootView` reaches.
struct PhoneLibraryNavigation {
    /// Presents Add to Library (Slice 3's).
    let addToLibrary: @MainActor () -> Void
}

/// A folder sheet the Library presents, which Slice 2b (`iosui-folders`)
/// builds: each a view taking the library and what it acts on, with a
/// closure for when it is done.
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
    /// One of the folder sheets, with the name of the command that asked
    /// for it.
    case folder(PhoneLibraryFolderSheet, title: String)

    /// One sheet at a time, told apart by what it is for.
    var id: String {
        switch self {
        case .libraryView: "libraryView"
        case .sort: "sort"
        case .bookInfo(let bookID): "bookInfo-\(bookID.uuidString)"
        case .folder(let sheet, _): "folder-\(sheet.hashValue)"
        }
    }
}

/// Stands in for a folder sheet until Slice 2b's views reach this branch: a
/// sheet titled with the command's own name, the Mac's, and Cancel. The
/// Library presents every folder sheet in one place, so Slice 2b's views
/// replace this in one switch.
struct PhoneLibraryFolderSheetPlaceholder: View {
    /// The command's name, the Mac's, as the sheet's title.
    let title: String
    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {}
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(PhoneLibraryVocabulary.cancel) { dismiss() }
                    }
                }
        }
    }
}
