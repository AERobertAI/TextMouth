import SwiftUI

/// One of the iPhone's five folder sheets, which the Library presents: New
/// Folder, Rename Folder, Move Folder, Move to Folder, or Delete Folder with
/// its Move Contents choice (the spec, "Folder sheets"). Each is a small
/// `Form` in a `NavigationStack`, rebuilt for the phone over the Mac's model
/// calls and words, since the Mac's own sheets can't be shown on a phone.
///
/// The Library presents every folder sheet through one `sheet(item:)` of
/// `PhoneFolderSheetRequest`s, returns focus to the control that opened it
/// in that sheet's `onDismiss`, and hears in `onFinish` what was done, once,
/// after a success, so it can tell which row focus goes to. A sheet left by
/// Cancel or VoiceOver's scrub calls nothing. Each sheet says its own words:
/// a failure as it happens, and New Folder's "Folder Q3 created in
/// Reports." once it has closed, as the Mac's Library window does.
///
/// Delete Folder... on a folder holding nothing presents no sheet, as on the
/// Mac: `PhoneFolderSheetModel.startDeleting(_:in:)` says which.
///
/// Nothing here has run on iOS.
struct PhoneFolderSheet: View {
    /// What the sheet shows and does, made once for the sheet.
    @StateObject private var model: PhoneFolderSheetModel
    /// Told what was done, after a success.
    private let onFinish: @MainActor (PhoneFolderSheetResult) -> Void
    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss

    /// The sheet `request` asks for, over `library`.
    init(
        library: LibraryViewModel,
        request: PhoneFolderSheetRequest,
        onFinish: @escaping @MainActor (PhoneFolderSheetResult) -> Void
    ) {
        _model = StateObject(wrappedValue: PhoneFolderSheetModel(task: request.task, library: library))
        self.onFinish = onFinish
    }

    /// A sheet over a model another sheet made, as Move to Folder makes its
    /// New Folder...'s (`PhoneFolderSheetModel.newFolderModel()`). SwiftUI
    /// keeps the first model it's handed for as long as the sheet shows.
    init(model: PhoneFolderSheetModel, onFinish: @escaping @MainActor (PhoneFolderSheetResult) -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onFinish = onFinish
    }

    /// New Folder, making a folder in the one at `parentPath`, the folder the
    /// Library shows ("" at the top).
    init(library: LibraryViewModel, newFolderIn parentPath: String, onFinish: @escaping @MainActor (PhoneFolderSheetResult) -> Void) {
        self.init(library: library, request: PhoneFolderSheetRequest(task: .newFolder(parentPath: parentPath)), onFinish: onFinish)
    }

    /// Rename Folder, for `folder`.
    init(library: LibraryViewModel, renaming folder: BookFolder, onFinish: @escaping @MainActor (PhoneFolderSheetResult) -> Void) {
        self.init(library: library, request: PhoneFolderSheetRequest(task: .renameFolder(folder)), onFinish: onFinish)
    }

    /// Move Folder, moving `folder` under another parent.
    init(library: LibraryViewModel, moving folder: BookFolder, onFinish: @escaping @MainActor (PhoneFolderSheetResult) -> Void) {
        self.init(library: library, request: PhoneFolderSheetRequest(task: .moveFolder(folder)), onFinish: onFinish)
    }

    /// Move to Folder, moving `books` into another folder.
    init(library: LibraryViewModel, movingBooks books: [Book], onFinish: @escaping @MainActor (PhoneFolderSheetResult) -> Void) {
        self.init(library: library, request: PhoneFolderSheetRequest(task: .moveBooks(books)), onFinish: onFinish)
    }

    /// Delete Folder, for `folder`, which holds something.
    init(library: LibraryViewModel, deleting folder: BookFolder, onFinish: @escaping @MainActor (PhoneFolderSheetResult) -> Void) {
        self.init(library: library, request: PhoneFolderSheetRequest(task: .deleteFolder(folder)), onFinish: onFinish)
    }

    var body: some View {
        NavigationStack {
            if case .deleteFolder = model.task {
                PhoneFolderDeleteQuestion(model: model, finish: finish)
            } else {
                PhoneFolderSheetForm(model: model, title: model.title, explanation: nil, showsCancel: true, finish: finish)
            }
        }
    }

    /// Closes the sheet, then tells the Library what was done, if anything.
    private func finish(_ result: PhoneFolderSheetResult?) {
        dismiss()
        if let result {
            onFinish(result)
        }
    }
}
