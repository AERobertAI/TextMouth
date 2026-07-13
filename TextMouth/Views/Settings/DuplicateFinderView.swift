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
    let matchTypes: [DuplicateFilter]
    let books: [Book]

    var matchDescription: String {
        if matchTypes.count == 1 {
            return matchTypes[0].rawValue
        }
        return "Combined: " + matchTypes.map(\.rawValue).joined(separator: ", ")
    }

    init(matchKey: String, matchTypes: [DuplicateFilter], books: [Book]) {
        self.id = "\(matchTypes.map(\.rawValue).joined(separator: "+")):\(matchKey)"
        self.matchKey = matchKey
        self.matchTypes = matchTypes
        self.books = books
    }
}

/// Pure duplicate grouping used by the view and production tests. Multiple
/// selected filters are an AND operation: a book is eligible only when every
/// filter has a value, and books share a group only when every value matches.
enum DuplicateFinderEngine {
    static func findDuplicates(
        books: [Book],
        filters: Set<DuplicateFilter>,
        isbnCache: [UUID: String]
    ) -> [DuplicateGroup] {
        let orderedFilters = DuplicateFilter.allCases.filter { filters.contains($0) }
        guard !orderedFilters.isEmpty else { return [] }

        var buckets: [[String]: [Book]] = [:]
        for book in books {
            var compositeKey: [String] = []
            for filter in orderedFilters {
                guard let component = keyComponent(for: book, filter: filter, isbnCache: isbnCache) else {
                    compositeKey = []
                    break
                }
                compositeKey.append(component)
            }
            guard compositeKey.count == orderedFilters.count else { continue }
            buckets[compositeKey, default: []].append(book)
        }

        return buckets
            .filter { $0.value.count >= 2 }
            .map { key, matchingBooks in
                DuplicateGroup(
                    matchKey: displayKey(
                        components: key,
                        filters: orderedFilters,
                        books: matchingBooks
                    ),
                    matchTypes: orderedFilters,
                    books: matchingBooks
                )
            }
            .sorted { $0.matchKey.localizedCaseInsensitiveCompare($1.matchKey) == .orderedAscending }
    }

    private static func keyComponent(
        for book: Book,
        filter: DuplicateFilter,
        isbnCache: [UUID: String]
    ) -> String? {
        switch filter {
        case .md5Hash:
            return book.md5Hash.isEmpty ? nil : book.md5Hash
        case .isbn:
            guard let isbn = isbnCache[book.id] else { return nil }
            let normalized = normalize(isbn)
            return normalized.isEmpty ? nil : normalized
        case .title:
            let normalized = normalize(book.title)
            return normalized.isEmpty ? nil : normalized
        case .author:
            let normalized = normalize(book.author)
            return normalized.isEmpty || normalized == "unknown" ? nil : normalized
        case .titleAndAuthor:
            let title = normalize(book.title)
            let author = normalize(book.author)
            guard !title.isEmpty else { return nil }
            return "\(title)|\(author)"
        }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func displayKey(
        components: [String],
        filters: [DuplicateFilter],
        books: [Book]
    ) -> String {
        let values = zip(filters, components).map { filter, component -> String in
            switch filter {
            case .md5Hash:
                return books.first?.title ?? component
            case .isbn:
                return "ISBN: \(component.uppercased())"
            case .titleAndAuthor:
                let parts = component.split(separator: "|", maxSplits: 1)
                return parts.count == 2 ? "\(parts[0]) by \(parts[1])" : component
            default:
                return component.capitalized
            }
        }
        return values.joined(separator: "; ")
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
                                Text(group.matchDescription)
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
        scanResults = DuplicateFinderEngine.findDuplicates(
            books: libraryViewModel.library.books,
            filters: activeFilters,
            isbnCache: isbnCache
        )
        hasScanned = true
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
