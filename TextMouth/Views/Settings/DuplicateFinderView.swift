import SwiftUI

/// Criteria for matching duplicate books. Checked criteria combine, so none
/// is offered that two others make together: Same Title checked with Same
/// Author groups by both, as a "Same Title & Author" checkbox did until
/// October 6, 2026. The one difference: books without an author, which Same
/// Author leaves out, are grouped by Same Title alone.
enum DuplicateFilter: String, CaseIterable, Identifiable {
    case md5Hash = "Identical File (MD5)"
    case isbn = "Same ISBN"
    case title = "Same Title"
    case author = "Same Author"

    var id: String { rawValue }

    /// Description shown in the UI
    var hint: String {
        switch self {
        case .md5Hash: return "Exact file content match — the strongest indicator"
        case .isbn: return "EPUB books with the same ISBN identifier"
        case .title: return "Books with the same title, regardless of author"
        case .author: return "All books by the same author"
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

    /// What matched, naming each criterion checked: "Same Title", or "Same
    /// Title and Same Author" for criteria checked together.
    var matchDescription: String {
        ListFormatter.localizedString(byJoining: matchTypes.map(\.rawValue))
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
        }
    }

    private static func normalize(_ value: String) -> String {
        value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The group's heading: what its books share, one value for each
    /// criterion in the criteria's order, joined with semicolons; a title
    /// and an author matched together read as one, "Shared by One Author".
    private static func displayKey(
        components: [String],
        filters: [DuplicateFilter],
        books: [Book]
    ) -> String {
        var values: [String] = []
        for (filter, component) in zip(filters, components) {
            switch filter {
            case .md5Hash:
                values.append(books.first?.title ?? component)
            case .isbn:
                values.append("ISBN: \(component.uppercased())")
            case .title:
                values.append(component.capitalized)
            case .author:
                // The criteria keep their declared order, so a title, when
                // checked, is the value appended just before the author.
                if filters.contains(.title), let title = values.popLast() {
                    values.append("\(title) by \(component.capitalized)")
                } else {
                    values.append(component.capitalized)
                }
            }
        }
        return values.joined(separator: "; ")
    }
}

/// How the Duplicate Finder removes the books selected in it (TODO A08). It
/// deletes their files, to the Trash or permanently as the preference
/// chooses, through the library's Trash-aware path, and asks first when
/// "Confirm before removing a book" is on.
enum DuplicateRemoval {
    /// What pressing the removal button does first.
    enum Step: Equatable {
        /// Ask, in these words; nothing is removed until the user confirms.
        case confirm(RemovalWording)
        /// Remove at once.
        case removeNow
    }

    /// The first step of removing `books` under `preferences`.
    static func firstStep(removing books: [Book], preferences: RemovalPreferences) -> Step {
        guard preferences.confirmsFirst else { return .removeNow }
        return .confirm(RemovalWording(preferences.deletionMode, books: books))
    }

    /// Removes the books with these IDs that are still in the library,
    /// deleting their packages through the library's Trash-aware path, and
    /// returns the outcome in the words of the deleting mode. Books removed
    /// elsewhere since they were selected are skipped.
    @MainActor
    static func remove(_ bookIDs: Set<UUID>, from libraryViewModel: LibraryViewModel) -> OperationOutcome {
        let books = libraryViewModel.library.books.filter { bookIDs.contains($0.id) }
        guard !books.isEmpty else { return .success(nil) }
        return libraryViewModel.removeBooksAndDeleteReturningOutcome(books)
    }
}

/// The Duplicate Finder's removal button, which says what it does: "Move 2
/// Selected to Trash" or "Delete 2 Selected Permanently", spoken in full.
struct DuplicateRemovalButton: View {
    /// The words for removing the selected books.
    let wording: RemovalWording
    let action: () -> Void

    var body: some View {
        Button(wording.selectionButtonTitle, role: .destructive, action: action)
            .accessibilityLabel(wording.selectionAccessibilityLabel)
    }
}

/// The words of Find Duplicate Books that VoiceOver hears for what the
/// sheet shows as one row or line.
enum DuplicateFinderWording {
    /// The folder named for a book at the library's top level.
    static let libraryRoot = "Library Root"

    /// A duplicate's row, everything it shows in one label: "Atlas, by
    /// Dorothy Vance, EPUB, in Travel, added October 6, 2026". The date the
    /// book was added tells two copies apart, so it is spoken, not only
    /// shown.
    static func bookLabel(_ book: Book) -> String {
        [
            book.title,
            "by \(book.author)",
            book.format.displayName,
            "in \(book.folderPath.isEmpty ? libraryRoot : book.folderPath)",
            "added \(book.dateAdded.formatted(date: .long, time: .omitted))",
        ].joined(separator: ", ")
    }

    /// What the sheet shows when a scan finds nothing.
    static let noDuplicates = "No duplicates found."

    /// What a scan found, read from its results and spoken when the scan
    /// ends: "No duplicates found with the selected criteria", "1 duplicate
    /// group found", "3 duplicate groups found".
    static func scanResult(groupCount: Int) -> String {
        groupCount == 0
            ? "No duplicates found with the selected criteria"
            : CountWording.phrase(groupCount, singular: "duplicate group found", plural: "duplicate groups found")
    }

    /// Says what a scan the user asked for found, as the removal's outcome
    /// is said, since VoiceOver stays on the Scan button as the results
    /// appear below it.
    @MainActor
    static func announceScanResult(groupCount: Int) {
        VoiceOverAnnouncer.announce(scanResult(groupCount: groupCount))
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
    /// Whether removing asks first and where deleted files go, kept current
    /// so the button and its confirmation say what removal will do.
    @State private var removalPreferences = RemovalPreferences(ConfigService.shared.config)
    /// The removal waiting for the user's confirmation.
    @State private var pendingRemoval: PendingRemoval?
    /// What the last removal did, shown under the buttons.
    @State private var removalOutcome: OperationOutcome?

    /// A removal waiting for confirmation: the books it captured when it
    /// was requested, and the words the confirmation shows.
    private struct PendingRemoval {
        let bookIDs: Set<UUID>
        let wording: RemovalWording
    }

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

                    if hasScanned && !selectedBooks.isEmpty {
                        Spacer()
                        DuplicateRemovalButton(
                            wording: RemovalWording(removalPreferences.deletionMode, books: selectedBooks),
                            action: requestRemoval
                        )
                    }
                }
                .padding(.top, 4)

                // What the last removal did, also announced when it happened.
                if let outcome = removalOutcome, let message = outcome.message {
                    Text(message)
                        .font(.callout)
                        .foregroundColor(outcome.succeeded ? .secondary : .red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
                Text(DuplicateFinderWording.noDuplicates)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(DuplicateFinderWording.scanResult(groupCount: 0))
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
                                .accessibilityLabel(DuplicateFinderWording.bookLabel(book))
                                Divider().padding(.leading)
                            }
                        }
                    }
                }
                .accessibilityLabel(DuplicateFinderWording.scanResult(groupCount: scanResults.count))
            }
        }
        .frame(width: 600, height: 550)
        .navigationTitle("Find Duplicates")
        .trackingRemovalPreferences($removalPreferences)
        // The confirmation is presented from the sheet itself, so the
        // confirmation preference is honored here too.
        .alert(
            pendingRemoval?.wording.confirmationTitle ?? "",
            isPresented: isConfirmingRemoval,
            presenting: pendingRemoval
        ) { removal in
            Button(removal.wording.buttonTitle, role: .destructive) {
                finishRemoval(of: removal.bookIDs)
            }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            Text(removal.wording.confirmationMessage)
        }
    }

    // MARK: - Scan Logic

    /// Start a scan, loading ISBNs first if needed, and say what it found
    private func performScan() {
        if activeFilters.contains(.isbn) && isbnCache.isEmpty {
            isLoadingISBNs = true
            Task {
                let cache = await loadISBNs(from: libraryViewModel.booksForDuplicateScan)
                await MainActor.run {
                    isbnCache = cache
                    isLoadingISBNs = false
                    runScan(announcing: true)
                }
            }
        } else {
            runScan(announcing: true)
        }
    }

    /// Run the duplicate scan and cache results; `announcing`, say what it
    /// found. The scan after a removal stays quiet: the removal's outcome
    /// is announced instead.
    private func runScan(announcing: Bool) {
        scanResults = DuplicateFinderEngine.findDuplicates(
            books: libraryViewModel.booksForDuplicateScan,
            filters: activeFilters,
            isbnCache: isbnCache
        )
        hasScanned = true
        if announcing {
            DuplicateFinderWording.announceScanResult(groupCount: scanResults.count)
        }
    }

    // MARK: - Removal

    /// The books selected for removal that are still in the library.
    private var selectedBooks: [Book] {
        libraryViewModel.library.books.filter { selectedForRemoval.contains($0.id) }
    }

    /// Whether the removal confirmation is showing; dismissing it drops the
    /// pending removal.
    private var isConfirmingRemoval: Binding<Bool> {
        Binding(
            get: { pendingRemoval != nil },
            set: { isShowing in
                if !isShowing { pendingRemoval = nil }
            }
        )
    }

    /// Removes the selected books, first asking inside this sheet when
    /// "Confirm before removing a book" is on.
    private func requestRemoval() {
        let books = selectedBooks
        guard !books.isEmpty else { return }
        let bookIDs = Set(books.map(\.id))
        switch DuplicateRemoval.firstStep(removing: books, preferences: removalPreferences) {
        case .confirm(let wording):
            pendingRemoval = PendingRemoval(bookIDs: bookIDs, wording: wording)
        case .removeNow:
            finishRemoval(of: bookIDs)
        }
    }

    /// Removes the books, shows what happened under the buttons and has
    /// VoiceOver announce it, keeps any book that stayed in the library
    /// selected so it can be tried again, and scans again.
    private func finishRemoval(of bookIDs: Set<UUID>) {
        let outcome = DuplicateRemoval.remove(bookIDs, from: libraryViewModel)
        removalOutcome = outcome
        if let message = outcome.message {
            VoiceOverAnnouncer.announce(message)
        }
        let remaining = Set(libraryViewModel.library.books.map(\.id))
        selectedForRemoval.formIntersection(remaining)
        runScan(announcing: false)
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

                    Text(book.folderPath.isEmpty ? DuplicateFinderWording.libraryRoot : book.folderPath)
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
