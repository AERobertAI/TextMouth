import SwiftUI

struct LibraryView: View {
    @EnvironmentObject var libraryViewModel: LibraryViewModel
    @EnvironmentObject var settingsViewModel: SettingsViewModel
    @Binding var currentFolderPath: String
    @Binding var category: LibraryCategory
    @Binding var sortField: LibrarySortField
    @Binding var sortAscending: Bool
    @Binding var showFileImporter: Bool
    let onOpenBook: (Book) -> Void

    @State private var showNewFolderSheet = false
    @State private var newFolderName = ""
    @State private var bookToMove: Book?
    @State private var showMoveSheet = false
    @State private var searchText = ""
    @State private var selectedBookID: UUID?
    @State private var bookInfoTarget: Book?
    @State private var showTextInput = false

    var body: some View {
        VStack(spacing: 0) {
            // Category picker
            Picker("View", selection: $category) {
                ForEach(LibraryCategory.allCases, id: \.self) { cat in
                    Text(cat.rawValue).tag(cat)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 8)
            .accessibilityLabel("Library category")

            // Breadcrumb navigation (only in folders mode)
            if category == .folders && !currentFolderPath.isEmpty {
                BreadcrumbBar(
                    path: currentFolderPath,
                    onNavigate: { currentFolderPath = $0 },
                    onNavigateRoot: { currentFolderPath = "" }
                )
            }

            // Quick-resume button
            if let lastBook = libraryViewModel.lastOpenedBook {
                Button {
                    onOpenBook(lastBook)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                            .foregroundColor(.accentColor)
                            .accessibilityHidden(true)
                        Text("Continue: \(lastBook.title)")
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        if let remaining = lastBook.estimatedTimeRemaining(wpm: settingsViewModel.wordsPerMinute) {
                            Text("\(TimeFormatting.format(remaining)) left")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel({
                    var label = "Continue listening to \(lastBook.title)"
                    if let remaining = lastBook.estimatedTimeRemaining(wpm: settingsViewModel.wordsPerMinute) {
                        label += ", \(TimeFormatting.spoken(remaining)) remaining"
                    }
                    return label
                }())
                .accessibilityHint("Opens the last book you were reading")
            }

            // Total time remaining bar (refreshTick forces periodic re-evaluation)
            let _ = libraryViewModel.refreshTick
            TimeRemainingBar(books: displayedBooks, wpm: settingsViewModel.wordsPerMinute)

            // Main list with native selection
            List(selection: $selectedBookID) {
                // Folders section (only in folders category)
                if category == .folders {
                    let subfolders = libraryViewModel.subfoldersOf(currentFolderPath)
                    if !subfolders.isEmpty {
                        Section {
                            ForEach(subfolders) { folder in
                                Button {
                                    currentFolderPath = folder.fullPath
                                } label: {
                                    FolderRow(
                                        folder: folder,
                                        bookCount: libraryViewModel.library.booksInFolder(folder.fullPath).count
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityAction(.default) {
                                    currentFolderPath = folder.fullPath
                                }
                                .contextMenu {
                                    Button("Delete Folder", role: .destructive) {
                                        libraryViewModel.removeFolder(folder)
                                    }
                                }
                            }
                        } header: {
                            Text("Folders")
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                }

                // Books section
                Section {
                    // Reference refreshTick so the list re-evaluates when the timer fires
                    let _ = libraryViewModel.refreshTick
                    ForEach(filteredBooks) { book in
                        BookRow(
                            book: book,
                            isOpenInWindow: libraryViewModel.openBookIDs.contains(book.id),
                            wpm: settingsViewModel.wordsPerMinute
                        )
                            .tag(book.id)
                            .accessibilityAction(.default) {
                                onOpenBook(book)
                            }
                            .contextMenu {
                                Button("Open") {
                                    onOpenBook(book)
                                }
                                Button("Book Info") {
                                    bookInfoTarget = book
                                }
                                Button("Move to Folder...") {
                                    bookToMove = book
                                    showMoveSheet = true
                                }
                                Divider()
                                Button("Remove from Library", role: .destructive) {
                                    libraryViewModel.removeBook(book)
                                }
                            }
                    }
                    .onMove { source, destination in
                        if sortField == .manual {
                            libraryViewModel.reorderBooksInFolder(
                                folderPath: currentFolderPath,
                                from: source,
                                to: destination
                            )
                        }
                    }
                } header: {
                    Text("Books (\(filteredBooks.count))")
                        .accessibilityAddTraits(.isHeader)
                }
            }
            .searchable(text: $searchText, prompt: "Search books")
            .accessibilityRotor("Books") {
                ForEach(filteredBooks) { book in
                    AccessibilityRotorEntry(book.title, id: book.id)
                }
            }
            .accessibilityRotor("Folders") {
                ForEach(libraryViewModel.subfoldersOf(currentFolderPath)) { folder in
                    AccessibilityRotorEntry(
                        "\(folder.name), \(libraryViewModel.library.booksInFolder(folder.fullPath).count) books",
                        id: folder.id
                    )
                }
            }
            .onDeleteCommand {
                // Delete key removes selected book
                if let id = selectedBookID,
                   let book = filteredBooks.first(where: { $0.id == id }) {
                    libraryViewModel.removeBook(book)
                    selectedBookID = nil
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                if category == .folders && !currentFolderPath.isEmpty {
                    Button {
                        navigateUp()
                    } label: {
                        Label("Go Back", systemImage: "chevron.left")
                    }
                    .accessibilityLabel("Go back to parent folder")
                }

                Button {
                    showFileImporter = true
                } label: {
                    Label("Import Book", systemImage: "plus")
                }
                .accessibilityLabel("Import a book file")
                .accessibilityHint("Opens a file picker to import EPUB, text, markdown, or HTML files")

                Button {
                    showTextInput = true
                } label: {
                    Label("New from Text", systemImage: "doc.text")
                }
                .accessibilityLabel("New book from text")
                .accessibilityHint("Create a new book by pasting or typing text")

                if category == .folders {
                    Button {
                        showNewFolderSheet = true
                    } label: {
                        Label("New Folder", systemImage: "folder.badge.plus")
                    }
                    .accessibilityLabel("Create new folder")
                }

                // Sort controls
                Menu {
                    ForEach(LibrarySortField.allCases, id: \.self) { field in
                        Button {
                            if sortField == field {
                                sortAscending.toggle()
                            } else {
                                sortField = field
                                sortAscending = true
                            }
                        } label: {
                            HStack {
                                Text(field.rawValue)
                                if sortField == field {
                                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                }
                            }
                        }
                    }
                    Divider()
                    Button {
                        sortAscending.toggle()
                    } label: {
                        Text(sortAscending ? "Sort Descending" : "Sort Ascending")
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort books by \(sortField.rawValue), \(sortAscending ? "ascending" : "descending")")
            }
        }
        .sheet(isPresented: $showNewFolderSheet) {
            NewFolderSheet(
                folderName: $newFolderName,
                onCreate: {
                    libraryViewModel.createFolder(name: newFolderName, parentPath: currentFolderPath)
                    newFolderName = ""
                    showNewFolderSheet = false
                },
                onCancel: {
                    newFolderName = ""
                    showNewFolderSheet = false
                }
            )
        }
        .sheet(isPresented: $showMoveSheet) {
            if let book = bookToMove {
                MoveFolderSheet(
                    book: book,
                    library: libraryViewModel.library,
                    onMove: { path in
                        libraryViewModel.moveBook(book, toFolder: path)
                        showMoveSheet = false
                    },
                    onCancel: { showMoveSheet = false }
                )
            }
        }
        .sheet(item: $bookInfoTarget) { book in
            LibraryBookInfoSheet(book: book, libraryViewModel: libraryViewModel)
        }
        .onReceive(NotificationCenter.default.publisher(for: .showBookInfo)) { _ in
            // Cmd+I: show info for selected book
            if let id = selectedBookID,
               let book = filteredBooks.first(where: { $0.id == id }) {
                bookInfoTarget = book
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSelectedBook)) { _ in
            // Enter key: open the selected book
            if let id = selectedBookID,
               let book = filteredBooks.first(where: { $0.id == id }) {
                onOpenBook(book)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newFromText)) { _ in
            showTextInput = true
        }
        .sheet(isPresented: $showTextInput) {
            TextInputView(
                onAdd: { title, author, text in
                    libraryViewModel.createBookFromText(title: title, author: author, text: text, toFolder: currentFolderPath)
                    showTextInput = false
                },
                onCancel: { showTextInput = false }
            )
        }
    }

    private var displayedBooks: [Book] {
        libraryViewModel.sortedBooks(
            libraryViewModel.booksForCategory(category, folderPath: currentFolderPath),
            by: sortField,
            ascending: sortAscending
        )
    }

    private var filteredBooks: [Book] {
        let books = displayedBooks
        if searchText.isEmpty { return books }
        let query = searchText.lowercased()
        return books.filter {
            $0.title.lowercased().contains(query) ||
            $0.author.lowercased().contains(query)
        }
    }

    private func navigateUp() {
        let parts = currentFolderPath.components(separatedBy: "/")
        if parts.count > 1 {
            currentFolderPath = parts.dropLast().joined(separator: "/")
        } else {
            currentFolderPath = ""
        }
    }
}

// MARK: - Time Remaining Bar

struct TimeRemainingBar: View {
    let books: [Book]
    let wpm: Double

    var body: some View {
        let (time, known, unknown) = computeTimeRemaining()
        if known > 0 || unknown > 0 {
            HStack(spacing: 12) {
                Label {
                    if known > 0 {
                        Text("\(TimeFormatting.format(time)) remaining")
                    }
                } icon: {
                    Image(systemName: "clock")
                        .foregroundColor(.green)
                }
                .font(.caption)

                if unknown > 0 {
                    Text("(\(unknown) \(unknown == 1 ? "book" : "books") not yet opened)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("\(books.count) \(books.count == 1 ? "book" : "books")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(time: time, known: known, unknown: unknown))
        }
    }

    private func computeTimeRemaining() -> (TimeInterval, Int, Int) {
        var total: TimeInterval = 0
        var known = 0
        var unknown = 0
        for book in books {
            if let remaining = book.estimatedTimeRemaining(wpm: wpm) {
                total += remaining
                known += 1
            } else {
                unknown += 1
            }
        }
        return (total, known, unknown)
    }

    private func accessibilityLabel(time: TimeInterval, known: Int, unknown: Int) -> String {
        var parts: [String] = []
        parts.append("\(books.count) \(books.count == 1 ? "book" : "books")")
        if known > 0 {
            parts.append("\(TimeFormatting.spoken(time)) total remaining at current speed")
        }
        if unknown > 0 {
            parts.append("\(unknown) \(unknown == 1 ? "book has" : "books have") not been opened yet")
        }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Subviews

struct BreadcrumbBar: View {
    let path: String
    let onNavigate: (String) -> Void
    let onNavigateRoot: () -> Void

    var body: some View {
        HStack {
            Button("Library") { onNavigateRoot() }
                .buttonStyle(.plain)
                .accessibilityLabel("Navigate to library root")

            let parts = path.components(separatedBy: "/")
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
                    .accessibilityHidden(true)

                Button(part) {
                    let subPath = parts[0...index].joined(separator: "/")
                    onNavigate(subPath)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Navigate to \(part)")
            }

            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }
}

struct FolderRow: View {
    let folder: BookFolder
    var bookCount: Int = 0

    var body: some View {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            Text(folder.name)
                .font(.headline)
            Spacer()
            Text("\(bookCount) \(bookCount == 1 ? "book" : "books")")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(folder.name), \(bookCount) \(bookCount == 1 ? "book" : "books")")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Double-tap to open folder")
    }
}

struct BookRow: View {
    let book: Book
    var isOpenInWindow: Bool = false
    var wpm: Double = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(book.title)
                    .font(.headline)

                if book.lastOpened == nil {
                    Text("New")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(3)
                } else if isOpenInWindow {
                    Text("Now Reading")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.green)
                        .foregroundColor(.white)
                        .cornerRadius(3)
                }
            }
            HStack {
                Text(book.author)
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                if let pos = book.readingPosition {
                    Text("Ch. \(pos.chapterIndex + 1)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let remaining = book.estimatedTimeRemaining(wpm: wpm) {
                    Text("\(TimeFormatting.format(remaining)) left")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Text(book.format.displayName)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(4)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Press Enter to open, Command I for info")
    }

    private var accessibilityLabel: String {
        var parts = [book.title, "by \(book.author)"]
        if book.lastOpened == nil {
            parts.append("New")
        } else if isOpenInWindow {
            parts.append("Now Reading")
        }
        if let pos = book.readingPosition {
            parts.append("Chapter \(pos.chapterIndex + 1)")
        }
        if let remaining = book.estimatedTimeRemaining(wpm: wpm) {
            parts.append("\(TimeFormatting.spoken(remaining)) remaining")
        }
        parts.append(book.format.displayName)
        return parts.joined(separator: ", ")
    }
}

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
                    var updated = book
                    updated.title = title
                    updated.author = author
                    libraryViewModel.updateBookMetadata(updated)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(title.isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 350)
    }
}

struct NewFolderSheet: View {
    @Binding var folderName: String
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
    }
}

struct MoveFolderSheet: View {
    let book: Book
    let library: Library
    let onMove: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Move \"\(book.title)\"")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            List {
                Button("Library Root") { onMove("") }
                    .accessibilityLabel("Move to library root")

                ForEach(library.folders) { folder in
                    Button(folder.fullPath) { onMove(folder.fullPath) }
                        .accessibilityLabel("Move to \(folder.fullPath)")
                }
            }
            .frame(height: 200)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
            }
        }
        .padding()
        .frame(width: 350)
    }
}

// Make Book conform to Identifiable for .sheet(item:) usage (already conforms via existing `id` property)
