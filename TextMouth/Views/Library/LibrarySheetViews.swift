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
                    .background(VoiceOverFocus())
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

// MARK: - New Folder Sheet

struct NewFolderSheet: View {
    @Binding var folderName: String
    @Binding var parentPath: String
    let folders: [BookFolder]
    let onCreate: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("New Folder")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            TextField("Folder name", text: $folderName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Folder name")
                .background(VoiceOverFocus())

            Picker("Parent folder", selection: $parentPath) {
                Text("Library Root").tag("")
                ForEach(folders.sortedTreeOrder()) { folder in
                    if folder.depth < BookFolder.maxDepth {
                        Text(folder.fullPath).tag(folder.fullPath)
                    }
                }
            }
            .accessibilityLabel("Parent folder")

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Create", action: onCreate)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(folderName.isEmpty)
            }
        }
        .padding()
        .frame(width: 300)
        .navigationTitle("New Folder")
    }
}

// MARK: - Move Folder Sheet

struct MoveFolderSheet: View {
    let books: [Book]
    let library: Library
    let lastMovedFolderPath: String
    let onMove: (String) -> Void
    let onCreateFolder: (String, String) -> Void
    let onCancel: () -> Void

    /// The folder path currently selected in the picker
    @State private var selectedPath: String = ""
    /// Whether the inline new-folder fields are showing
    @State private var showNewFolder = false
    /// Name for the new folder being created
    @State private var newFolderName = ""
    /// Parent path for the new folder
    @State private var newFolderParent = ""

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
                                let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !name.isEmpty else { return }
                                onCreateFolder(name, newFolderParent)
                                // Select the newly created folder as destination
                                let sanitized = name.replacingOccurrences(of: "/", with: "-")
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                let newPath = newFolderParent.isEmpty ? sanitized : "\(newFolderParent)/\(sanitized)"
                                selectedPath = newPath
                                newFolderName = ""
                                showNewFolder = false
                            }
                            .disabled(newFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

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
                    onMove(selectedPath)
                }
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding()
        .frame(width: 400)
        .navigationTitle(headerTitle)
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
    let onRename: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Rename Folder")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            TextField("Folder name", text: $newName)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("New folder name")

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Rename", action: onRename)
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || newName.trimmingCharacters(in: .whitespacesAndNewlines) == currentName)
            }
        }
        .padding()
        .frame(width: 300)
        .navigationTitle("Rename Folder")
    }
}

// MARK: - Move Folder to Parent Sheet

/// Sheet for moving a folder to a new parent folder
struct MoveFolderToParentSheet: View {
    let folder: BookFolder
    let library: Library
    let onMove: (String) -> Void
    let onCancel: () -> Void

    @State private var selectedParent = ""

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

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Move") { onMove(selectedParent) }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(selectedParent == folder.parentPath)
            }
        }
        .padding()
        .frame(width: 400)
        .navigationTitle("Move Folder: \(folder.name)")
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
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var selectedDestination = ""

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

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Move Contents & Delete Folder") {
                    onConfirm(selectedDestination)
                }
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding()
        .frame(width: 450)
        .navigationTitle("Move Contents: \(folder.name)")
        .onAppear {
            // Default to the parent of the folder being deleted
            selectedDestination = folder.parentPath
        }
    }
}
