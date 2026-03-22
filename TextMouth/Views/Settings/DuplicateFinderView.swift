import SwiftUI

/// Criteria for matching duplicate books
enum DuplicateFilter: String, CaseIterable, Identifiable {
    case md5Hash = "Identical File (MD5)"
    case isbn = "Same ISBN"
    case title = "Same Title"
    case author = "Same Author"
    case titleAndAuthor = "Same Title & Author"

    var id: String { rawValue }

    /// Description shown in the UI
    var hint: String {
        switch self {
        case .md5Hash: return "Exact file content match — the strongest indicator"
        case .isbn: return "EPUB books with the same ISBN identifier"
        case .title: return "Books with the same title, regardless of author"
        case .author: return "All books by the same author"
        case .titleAndAuthor: return "Books with both the same title and author"
        }
    }
}

/// A group of books that matched a duplicate filter.
/// ID is deterministic so SwiftUI can maintain list identity across state changes.
struct DuplicateGroup: Identifiable {
    let id: String
    let matchKey: String
    let matchType: DuplicateFilter
    let books: [Book]

    init(matchKey: String, matchType: DuplicateFilter, books: [Book]) {
        self.id = "\(matchType.rawValue):\(matchKey)"
        self.matchKey = matchKey
        self.matchType = matchType
        self.books = books
    }
}

/// Sheet for finding and removing duplicate books across the library
struct DuplicateFinderView: View {
    @ObservedObject var libraryViewModel: LibraryViewModel
    @Environment(\.dismiss) private var dismiss

    /// Which filters are active
    @State private var activeFilters: Set<DuplicateFilter> = [.md5Hash]
    /// Books selected for removal
    @State private var selectedForRemoval: Set<UUID> = []
    /// Cached scan results — only recomputed on explicit scan, not on selection changes
    @State private var scanResults: [DuplicateGroup] = []
    /// Whether the scan has been performed
    @State private var hasScanned = false
    /// ISBN cache: loaded on demand from bookInfo.json for EPUB books
    @State private var isbnCache: [UUID: String] = [:]
    /// Whether ISBN loading is in progress
    @State private var isLoadingISBNs = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Find Duplicate Books")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()

            Divider()

            // Filter checkboxes
            VStack(alignment: .leading, spacing: 8) {
                Text("Match criteria (checked filters are combined):")
                    .font(.callout)
                    .foregroundColor(.secondary)

                ForEach(DuplicateFilter.allCases) { filter in
                    Toggle(isOn: binding(for: filter)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(filter.rawValue)
                            Text(filter.hint)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .accessibilityLabel(filter.rawValue)
                    .accessibilityHint(filter.hint)
                }

                HStack {
                    Button(isLoadingISBNs ? "Loading ISBNs..." : "Scan for Duplicates") {
                        performScan()
                    }
                    .disabled(activeFilters.isEmpty || isLoadingISBNs)
                    .accessibilityHint("Searches the entire library for books matching the selected criteria")

                    if hasScanned && !selectedForRemoval.isEmpty {
                        Spacer()
                        Button("Remove \(selectedForRemoval.count) Selected", role: .destructive) {
                            let booksToRemove = libraryViewModel.library.books.filter {
                                selectedForRemoval.contains($0.id)
                            }
                            // Use removeBooksAndDelete directly — the user already
                            // confirmed by pressing this button, and removeBooks would
                            // try to show a nested confirmation dialog inside this sheet
                            libraryViewModel.removeBooksAndDelete(booksToRemove)
                            selectedForRemoval = []
                            // Re-scan with updated library after a brief delay for state to settle
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                runScan()
                            }
                        }
                        .accessibilityLabel("Remove \(selectedForRemoval.count) selected books from library")
                    }
                }
                .padding(.top, 4)
            }
            .padding()

            Divider()

            // Results
            if !hasScanned {
                Spacer()
                Text("Select match criteria above and press Scan.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if scanResults.isEmpty {
                Spacer()
                Text("No duplicates found.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("No duplicates found with the selected criteria")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(scanResults) { group in
                            // Group header
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.matchType.rawValue)
                                    .font(.caption2)
                                    .foregroundColor(.accentColor)
                                Text(group.matchKey)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                            }
                            .padding(.horizontal)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isHeader)

                            // Books in this group — each is a native checkbox Toggle
                            ForEach(group.books) { book in
                                Toggle(isOn: selectionBinding(for: book.id)) {
                                    DuplicateBookLabel(book: book)
                                }
                                .toggleStyle(.checkbox)
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                                .background(selectedForRemoval.contains(book.id)
                                    ? Color.red.opacity(0.08) : Color.clear)
                                .accessibilityLabel(bookAccessibilityLabel(book))
                                Divider().padding(.leading)
                            }
                        }
                    }
                }
                .accessibilityLabel("\(scanResults.count) duplicate groups found")
            }
        }
        .frame(width: 600, height: 550)
        .navigationTitle("Find Duplicates")
    }

    // MARK: - Scan Logic

    /// Start a scan, loading ISBNs first if needed
    private func performScan() {
        if activeFilters.contains(.isbn) && isbnCache.isEmpty {
            isLoadingISBNs = true
            Task {
                let cache = await loadISBNs(from: libraryViewModel.library.books)
                await MainActor.run {
                    isbnCache = cache
                    isLoadingISBNs = false
                    runScan()
                }
            }
        } else {
            runScan()
        }
    }

    /// Run the duplicate scan and cache results
    private func runScan() {
        var allGroups: [DuplicateGroup] = []
        var seenBookIDs: Set<UUID> = []

        for filter in DuplicateFilter.allCases where activeFilters.contains(filter) {
            let groups = findDuplicates(by: filter)
            for group in groups {
                let newBooks = group.books.filter { !seenBookIDs.contains($0.id) }
                if newBooks.count >= 2 {
                    allGroups.append(DuplicateGroup(
                        matchKey: group.matchKey,
                        matchType: group.matchType,
                        books: newBooks
                    ))
                    for book in newBooks {
                        seenBookIDs.insert(book.id)
                    }
                }
            }
        }

        scanResults = allGroups
        hasScanned = true
    }

    /// Find groups of books matching the given filter criterion
    private func findDuplicates(by filter: DuplicateFilter) -> [DuplicateGroup] {
        var buckets: [String: [Book]] = [:]

        for book in libraryViewModel.library.books {
            let key: String
            switch filter {
            case .md5Hash:
                guard !book.md5Hash.isEmpty else { continue }
                key = book.md5Hash
            case .isbn:
                guard let isbn = isbnCache[book.id], !isbn.isEmpty else { continue }
                key = isbn.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            case .title:
                let normalized = book.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty else { continue }
                key = normalized
            case .author:
                let normalized = book.author.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty, normalized != "unknown" else { continue }
                key = normalized
            case .titleAndAuthor:
                let t = book.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                let a = book.author.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                key = "\(t)|\(a)"
            }
            buckets[key, default: []].append(book)
        }

        return buckets
            .filter { $0.value.count >= 2 }
            .map { (key, books) in
                let displayKey: String
                switch filter {
                case .md5Hash:
                    displayKey = books.first?.title ?? key
                case .isbn:
                    displayKey = "ISBN: \(key.uppercased())"
                case .titleAndAuthor:
                    let parts = key.split(separator: "|", maxSplits: 1)
                    displayKey = parts.count == 2 ? "\(parts[0]) by \(parts[1])" : key
                default:
                    displayKey = key.capitalized
                }
                return DuplicateGroup(matchKey: displayKey, matchType: filter, books: books)
            }
            .sorted { $0.matchKey.localizedCaseInsensitiveCompare($1.matchKey) == .orderedAscending }
    }

    // MARK: - Helpers

    /// Stable binding for a book's selection state
    private func selectionBinding(for bookID: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedForRemoval.contains(bookID) },
            set: { isOn in
                if isOn {
                    selectedForRemoval.insert(bookID)
                } else {
                    selectedForRemoval.remove(bookID)
                }
            }
        )
    }

    private func binding(for filter: DuplicateFilter) -> Binding<Bool> {
        Binding(
            get: { activeFilters.contains(filter) },
            set: { isOn in
                if isOn {
                    activeFilters.insert(filter)
                } else {
                    activeFilters.remove(filter)
                    if filter == .isbn { isbnCache = [:] }
                }
                hasScanned = false
                scanResults = []
                selectedForRemoval = []
            }
        )
    }

    private func bookAccessibilityLabel(_ book: Book) -> String {
        var parts = [book.title, "by \(book.author)", book.format.displayName]
        if !book.folderPath.isEmpty {
            parts.append("in \(book.folderPath)")
        } else {
            parts.append("in Library Root")
        }
        return parts.joined(separator: ", ")
    }

    /// Load ISBN values from bookInfo.json for all EPUB books
    private func loadISBNs(from books: [Book]) async -> [UUID: String] {
        await withTaskGroup(of: (UUID, String)?.self) { group in
            for book in books where book.format == .epub && !book.tmbDirectoryName.isEmpty {
                group.addTask {
                    let tmbDir = book.tmbDirectory
                    guard let info = try? BookInfo.load(from: tmbDir),
                          let isbn = info.metadata.isbn, !isbn.isEmpty else {
                        return nil
                    }
                    return (book.id, isbn)
                }
            }
            var result: [UUID: String] = [:]
            for await pair in group {
                if let (id, isbn) = pair {
                    result[id] = isbn
                }
            }
            return result
        }
    }
}

/// The label content for a duplicate book row (used inside the native Toggle)
struct DuplicateBookLabel: View {
    let book: Book

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.body)
                    .fontWeight(.medium)

                HStack(spacing: 8) {
                    Text(book.author)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(book.format.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(3)

                    Text(book.folderPath.isEmpty ? "Library Root" : book.folderPath)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Text(book.dateAdded, style: .date)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}
