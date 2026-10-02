import SwiftUI

// MARK: - Book Info Sheet

/// Book info editor accessible from the library context menu
struct LibraryBookInfoSheet: View {
    let book: Book
    let libraryViewModel: LibraryViewModel
    @State private var title: String
    @State private var author: String
    @Environment(\.dismiss) private var dismiss

    init(book: Book, libraryViewModel: LibraryViewModel) {
        self.book = book
        self.libraryViewModel = libraryViewModel
        self._title = State(initialValue: book.title)
        self._author = State(initialValue: book.author)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Book Information")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Form {
                TextField("Title", text: $title)
                    .accessibilityLabel("Book title")
                TextField("Author", text: $author)
                    .accessibilityLabel("Book author")

                LabeledContent("Format") {
                    Text(book.format.displayName)
                }
                LabeledContent("Added") {
                    Text(book.dateAdded, style: .date)
                }
                if let lastOpened = book.lastOpened {
                    LabeledContent("Last Opened") {
                        Text(lastOpened, style: .date)
                    }
                }
                if let words = book.totalWordCount {
                    LabeledContent("Word Count") {
                        Text("\(words)")
                    }
                }
            }

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Save") {
                    // Capture state before dismissing
                    let savedTitle = title
                    let savedAuthor = author
                    let savedBook = book
                    let vm = libraryViewModel

                    // Dismiss first so shared state updates don't steal focus
                    dismiss()

                    DispatchQueue.main.async {
                        var updated = savedBook
                        updated.title = savedTitle
                        updated.author = savedAuthor
                        vm.updateBookMetadata(updated)
                    }
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(title.isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 350)
        .navigationTitle("Info: \(book.title)")
    }
}

// MARK: - Operation Failure Notice

/// Why the operation a sheet started failed, shown inside the sheet (TODO
/// A07). A sheet whose operation fails stays open with the user's input, so
/// the reason sits beside the controls that can put it right. VoiceOver
/// reads the notice as text labelled as an error, where the red color tells
/// sighted users the same, and the failure is announced once as it happens,
/// from the sheet, which keeps focus.
struct OperationFailureNotice: View {
    /// The failure to show, or nil to show nothing.
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .font(.callout)
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Self.accessibilityLabel(for: message))
        }
    }

    /// What VoiceOver reads for a failure: the message, introduced as an
    /// error.
    nonisolated static func accessibilityLabel(for message: String) -> String {
        "Error: \(message)"
    }

    /// The message a sheet shows after `outcome`: nil after a success, when
    /// the sheet is closing, or else the reason, which VoiceOver is asked to
    /// speak once so the user hears it without leaving the control they used.
    static func message(after outcome: OperationOutcome) -> String? {
        guard let failure = outcome.failureMessage else { return nil }
        VoiceOverAnnouncer.announce(failure)
        return failure
    }
}

extension View {
    /// Clears a sheet's failure message as soon as the user changes `value`,
    /// an input the failure was about, so a reason that no longer applies is
    /// never read beside new input.
    func clearingFailure<Value: Equatable>(
        _ message: Binding<String?>,
        whenChanged value: Value
    ) -> some View {
        onChange(of: value) { _, _ in
            message.wrappedValue = nil
        }
    }
}

// MARK: - New Folder Sheet

struct NewFolderSheet: View {
    @Binding var folderName: String
    @Binding var parentPath: String
    let folders: [BookFolder]
    /// Creates the folder and returns what happened. The owner closes the
    /// sheet after a success; after a failure the sheet stays open with the
    /// name and parent the user chose, and shows why.
    let onCreate: () -> OperationOutcome
    let onCancel: () -> Void

    /// Why the last Create failed, until the user changes the name or parent.
    @State private var failureMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("New Folder")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            TextField("Folder name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Folder name")

            Picker("Parent folder", selection: $parentPath) {
                Text("Library Root").tag("")
                ForEach(folders.sortedTreeOrder()) { folder in
                    if folder.depth < BookFolder.maxDepth {
                        Text(folder.fullPath).tag(folder.fullPath)
                    }
                }
            }
            .accessibilityLabel("Parent folder")

            OperationFailureNotice(message: failureMessage)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Create") {
                    failureMessage = OperationFailureNotice.message(after: onCreate())
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(BookFolder.normalizedName(folderName) == nil)
            }
        }
        .padding()
        .frame(width: 300)
        .navigationTitle("New Folder")
        .clearingFailure($failureMessage, whenChanged: folderName)
        .clearingFailure($failureMessage, whenChanged: parentPath)
    }
}

// MARK: - Move Folder Sheet

struct MoveFolderSheet: View {
    let books: [Book]
    let library: Library
    let lastMovedFolderPath: String
    /// Moves the books into the folder at the given path and returns what
    /// happened. The owner closes the sheet after a success; after a failure
    /// the sheet stays open with the chosen destination and shows why.
    let onMove: (String) -> OperationOutcome
    /// Creates a folder from a name and a parent path and returns what
    /// happened. After a success the new folder becomes the destination;
    /// after a failure the new-folder fields keep their input and the sheet
    /// shows why.
    let onCreateFolder: (String, String) -> OperationOutcome
    let onCancel: () -> Void

    /// The folder path currently selected in the picker
    @State private var selectedPath: String = ""
    /// Whether the inline new-folder fields are showing
    @State private var showNewFolder = false
    /// Name for the new folder being created
    @State private var newFolderName = ""
    /// Parent path for the new folder
    @State private var newFolderParent = ""
    /// Why the last Move or Create failed, until the user changes an input.
    @State private var failureMessage: String?

    /// Title shown in the sheet header
    private var headerTitle: String {
        if books.count == 1, let book = books.first {
            return "Move \"\(book.title)\""
        }
        return "Move \(books.count) Books"
    }

    /// All available destination paths, including "Library Root" (empty string)
    private var folderOptions: [(label: String, path: String)] {
        var options: [(String, String)] = [("Library Root", "")]
        for folder in library.folders.sortedTreeOrder() {
            options.append((folder.fullPath, folder.fullPath))
        }
        return options
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(headerTitle)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            // Folder picker
            Picker("Destination", selection: $selectedPath) {
                ForEach(folderOptions, id: \.path) { option in
                    Text(option.label).tag(option.path)
                }
            }
            .accessibilityLabel("Destination folder")

            // Inline new folder creation
            if showNewFolder {
                GroupBox("New Folder") {
                    VStack(spacing: 8) {
                        TextField("Folder name", text: $newFolderName)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("New folder name")

                        Picker("Parent folder", selection: $newFolderParent) {
                            Text("Library Root").tag("")
                            ForEach(library.folders.sortedTreeOrder()) { folder in
                                if folder.depth < BookFolder.maxDepth {
                                    Text(folder.fullPath).tag(folder.fullPath)
                                }
                            }
                        }
                        .accessibilityLabel("Parent folder for new folder")

                        HStack {
                            Button("Cancel") {
                                newFolderName = ""
                                showNewFolder = false
                            }
                            Spacer()
                            Button("Create") {
                                guard let name = BookFolder.normalizedName(newFolderName) else { return }
                                failureMessage = OperationFailureNotice.message(
                                    after: onCreateFolder(name, newFolderParent)
                                )
                                // A refused or failed folder keeps the fields
                                // open with the name, beside the reason.
                                guard failureMessage == nil else { return }
                                // Select the newly created folder as destination
                                let newPath = newFolderParent.isEmpty ? name : "\(newFolderParent)/\(name)"
                                selectedPath = newPath
                                newFolderName = ""
                                showNewFolder = false
                            }
                            .disabled(BookFolder.normalizedName(newFolderName) == nil)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            OperationFailureNotice(message: failureMessage)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                if !showNewFolder {
                    Button("New Folder...") {
                        showNewFolder = true
                    }
                }

                Button("Move") {
                    failureMessage = OperationFailureNotice.message(after: onMove(selectedPath))
                }
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding()
        .frame(width: 400)
        .navigationTitle(headerTitle)
        .clearingFailure($failureMessage, whenChanged: selectedPath)
        .clearingFailure($failureMessage, whenChanged: newFolderName)
        .clearingFailure($failureMessage, whenChanged: newFolderParent)
        .onAppear {
            // Default to last moved folder if it still exists, otherwise Library Root
            if !lastMovedFolderPath.isEmpty,
               folderOptions.contains(where: { $0.path == lastMovedFolderPath }) {
                selectedPath = lastMovedFolderPath
            }
        }
    }
}

// MARK: - Rename Folder Sheet

/// Sheet for renaming a folder
struct RenameFolderSheet: View {
    let currentName: String
    @Binding var newName: String
    /// Renames the folder and returns what happened. The owner closes the
    /// sheet after a success; after a failure the sheet stays open with the
    /// typed name and shows why.
    let onRename: () -> OperationOutcome
    let onCancel: () -> Void

    /// Why the last Rename failed, until the user changes the name.
    @State private var failureMessage: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Folder")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            TextField("Folder name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("New folder name")

            OperationFailureNotice(message: failureMessage)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Rename") {
                    failureMessage = OperationFailureNotice.message(after: onRename())
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(BookFolder.normalizedName(newName) == nil
                          || BookFolder.normalizedName(newName) == currentName)
            }
        }
        .padding()
        .frame(width: 300)
        .navigationTitle("Rename Folder")
        .clearingFailure($failureMessage, whenChanged: newName)
    }
}

// MARK: - Move Folder to Parent Sheet

/// Sheet for moving a folder to a new parent folder
struct MoveFolderToParentSheet: View {
    let folder: BookFolder
    let library: Library
    /// Moves the folder under the given parent path and returns what
    /// happened. The owner closes the sheet after a success; after a failure
    /// the sheet stays open with the chosen parent and shows why.
    let onMove: (String) -> OperationOutcome
    let onCancel: () -> Void

    @State private var selectedParent = ""
    /// Why the last Move failed, until the user picks another parent.
    @State private var failureMessage: String?

    /// Valid destinations: all folders except the folder itself, its descendants, and its current parent
    private var validDestinations: [(label: String, path: String)] {
        let selfPath = folder.fullPath
        var options: [(String, String)] = [("Library Root", "")]
        for f in library.folders.sortedTreeOrder() {
            // Exclude: the folder itself, its descendants, and check depth limit
            if f.fullPath == selfPath { continue }
            if f.fullPath.hasPrefix(selfPath + "/") { continue }
            // Check that moving here wouldn't exceed max depth
            let newDepth = (f.fullPath.isEmpty ? 0 : f.fullPath.components(separatedBy: "/").count) + 1
            if newDepth > BookFolder.maxDepth { continue }
            options.append((f.fullPath, f.fullPath))
        }
        return options
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Move \"\(folder.name)\"")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Picker("New parent folder", selection: $selectedParent) {
                ForEach(validDestinations, id: \.path) { option in
                    Text(option.label).tag(option.path)
                }
            }
            .accessibilityLabel("Destination parent folder")

            OperationFailureNotice(message: failureMessage)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Move") {
                    failureMessage = OperationFailureNotice.message(after: onMove(selectedParent))
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(selectedParent == folder.parentPath)
            }
        }
        .padding()
        .frame(width: 400)
        .navigationTitle("Move Folder: \(folder.name)")
        .clearingFailure($failureMessage, whenChanged: selectedParent)
        .onAppear {
            selectedParent = folder.parentPath
        }
    }
}

// MARK: - Delete Folder Move Contents Sheet

/// Sheet for choosing where to move folder contents when deleting a folder
struct DeleteFolderMoveContentsSheet: View {
    let folder: BookFolder
    let library: Library
    /// Moves the folder's contents to the given path, deletes the folder,
    /// and returns what happened. The owner closes the sheet after a
    /// success; after a failure the sheet stays open with the chosen
    /// destination and shows why.
    let onConfirm: (String) -> OperationOutcome
    let onCancel: () -> Void

    @State private var selectedDestination = ""
    /// Why the last attempt failed, until the user picks another destination.
    @State private var failureMessage: String?

    /// Valid destinations: all folders except the folder being deleted and its descendants
    private var validDestinations: [(label: String, path: String)] {
        let selfPath = folder.fullPath
        var options: [(String, String)] = [("Library Root", "")]
        for f in library.folders.sortedTreeOrder() {
            if f.fullPath == selfPath { continue }
            if f.fullPath.hasPrefix(selfPath + "/") { continue }
            options.append((f.fullPath, f.fullPath))
        }
        return options
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Move Contents of \"\(folder.name)\"")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Text("Choose where to move the books and subfolders before deleting \"\(folder.name)\".")
                .font(.callout)
                .foregroundColor(.secondary)

            Picker("Move contents to", selection: $selectedDestination) {
                ForEach(validDestinations, id: \.path) { option in
                    Text(option.label).tag(option.path)
                }
            }
            .accessibilityLabel("Destination for folder contents")

            OperationFailureNotice(message: failureMessage)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Move Contents & Delete Folder") {
                    failureMessage = OperationFailureNotice.message(after: onConfirm(selectedDestination))
                }
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding()
        .frame(width: 450)
        .navigationTitle("Move Contents: \(folder.name)")
        .clearingFailure($failureMessage, whenChanged: selectedDestination)
        .onAppear {
            // Default to the parent of the folder being deleted
            selectedDestination = folder.parentPath
        }
    }
}
