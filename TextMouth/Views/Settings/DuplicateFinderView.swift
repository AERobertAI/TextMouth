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

/// A group of books that matched a duplicate filter
struct DuplicateGroup: Identifiable {
    let id = UUID()
    let matchKey: String
    let matchType: DuplicateFilter
    let books: [Book]
}

/// Sheet for finding and removing duplicate books across the library
struct DuplicateFinderView: View {
    let library: Library
    let onRemoveBooks: ([Book]) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Which filters are active
    @State private var activeFilters: Set<DuplicateFilter> = [.md5Hash]
    /// Books selected for removal
    @State private var selectedForRemoval: Set<UUID> = []
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
                        if activeFilters.contains(.isbn) && isbnCache.isEmpty {
                            // Load ISBNs from bookInfo.json before scanning
                            isLoadingISBNs = true
                            Task {
                                let cache = await loadISBNs(from: library.books)
                                await MainActor.run {
                                    isbnCache = cache
                                    isLoadingISBNs = false
                                    hasScanned = true
                                }
                            }
                        } else {
                            hasScanned = true
                        }
                    }
                    .disabled(activeFilters.isEmpty || isLoadingISBNs)
                    .accessibilityHint("Searches the entire library for books matching the selected criteria")

                    if hasScanned && !duplicateGroups.isEmpty && !selectedForRemoval.isEmpty {
                        Spacer()
                        Button("Remove \(selectedForRemoval.count) Selected", role: .destructive) {
                            let booksToRemove = library.books.filter { selectedForRemoval.contains($0.id) }
                            onRemoveBooks(booksToRemove)
                            // Clear selection and rescan
                            selectedForRemoval = []
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
            } else if duplicateGroups.isEmpty {
                Spacer()
                Text("No duplicates found.")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("No duplicates found with the selected criteria")
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(duplicateGroups) { group in
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

                            // Books in this group
                            ForEach(group.books) { book in
                                DuplicateBookRow(
                                    book: book,
                                    isSelected: selectedForRemoval.contains(book.id),
                                    onToggle: {
                                        if selectedForRemoval.contains(book.id) {
                                            selectedForRemoval.remove(book.id)
                                        } else {
                                            selectedForRemoval.insert(book.id)
                                        }
                                    }
                                )
                                Divider().padding(.leading)
                            }
                        }
                    }
                }
                .accessibilityLabel("\(duplicateGroups.count) duplicate groups found, \(totalDuplicateBooks) books total")
            }
        }
        .frame(width: 600, height: 550)
        .navigationTitle("Find Duplicates")
    }

    /// Compute duplicate groups based on active filters
    private var duplicateGroups: [DuplicateGroup] {
        guard hasScanned else { return [] }
        var allGroups: [DuplicateGroup] = []
        var seenBookIDs: Set<UUID> = []

        for filter in DuplicateFilter.allCases where activeFilters.contains(filter) {
            let groups = findDuplicates(by: filter)
            for group in groups {
                // Only include books not already shown in a higher-priority group
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

        return allGroups
    }

    private var totalDuplicateBooks: Int {
        duplicateGroups.reduce(0) { $0 + $1.books.count }
    }

    /// Find groups of books matching the given filter criterion
    private func findDuplicates(by filter: DuplicateFilter) -> [DuplicateGroup] {
        var buckets: [String: [Book]] = [:]

        for book in library.books {
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

        // Only return groups with 2+ books (actual duplicates)
        return buckets
            .filter { $0.value.count >= 2 }
            .map { (key, books) in
                let displayKey: String
                switch filter {
                case .md5Hash:
                    // Show the title of the first book rather than the raw hash
                    displayKey = books.first?.title ?? key
                case .isbn:
                    // Show "ISBN: xxx — Title" for readability
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

    /// Binding helper for filter toggles
    private func binding(for filter: DuplicateFilter) -> Binding<Bool> {
        Binding(
            get: { activeFilters.contains(filter) },
            set: { isOn in
                if isOn {
                    activeFilters.insert(filter)
                } else {
                    activeFilters.remove(filter)
                    // Clear ISBN cache when filter is removed to force reload next time
                    if filter == .isbn { isbnCache = [:] }
                }
                // Reset results when filters change
                hasScanned = false
                selectedForRemoval = []
            }
        )
    }

    /// Load ISBN values from bookInfo.json for all EPUB books.
    /// Runs on a background thread since it involves disk I/O.
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

/// A row showing a potentially duplicate book with a selection checkbox.
/// The entire row is a single accessibility element with toggle behavior.
struct DuplicateBookRow: View {
    let book: Book
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Selection indicator (visual only — accessibility is on the row)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundColor(isSelected ? .red : .secondary)
                .font(.title3)
                .accessibilityHidden(true)

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

                    if !book.folderPath.isEmpty {
                        Text(book.folderPath)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("Library Root")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            Text(book.dateAdded, style: .date)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
        .background(isSelected ? Color.red.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Double-tap to \(isSelected ? "deselect" : "select for removal")")
        .accessibilityAddTraits([.isButton])
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityAction(.default) { onToggle() }
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if isSelected {
            parts.append("Selected for removal")
        }
        parts.append(book.title)
        parts.append("by \(book.author)")
        parts.append(book.format.displayName)
        if !book.folderPath.isEmpty {
            parts.append("in \(book.folderPath)")
        } else {
            parts.append("in Library Root")
        }
        return parts.joined(separator: ", ")
    }
}
