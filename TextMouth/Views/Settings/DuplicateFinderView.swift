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
            .sortedStably { $0.matchKey.localizedCaseInsensitiveCompare($1.matchKey) == .orderedAscending }
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

/// The pages the Duplicate Finder shows a scan's groups in (REV13): runs of
/// whole groups, in the scan's order, each listing at most `rowsPerPage`
/// books in all, unless one group alone lists more, which then has a page
/// of its own. Every book is a native checkbox, by far the costliest row
/// the sheet draws (see `DuplicateGroupList`), so a page is measured in
/// books, not groups: a page of identical files, two books a group, holds
/// about twenty groups, and a page of authors' books five or six.
struct DuplicateGroupPages: Equatable {
    /// The most books a page lists, unless one group alone lists more:
    /// about a quarter of a second of drawing (see `DuplicateGroupList`).
    static let rowsPerPage = 40

    /// The groups on each page, as ranges of their indices in the scan's
    /// order, none of them empty; no page for a scan that found no group.
    let ranges: [Range<Int>]

    /// The pages of groups listing `rowCounts` books each, in that order,
    /// each page listing at most `rowsPerPage` books unless its one group
    /// lists more.
    init(rowCounts: [Int], rowsPerPage: Int = Self.rowsPerPage) {
        var ranges: [Range<Int>] = []
        var start = 0
        var rows = 0
        for (index, count) in rowCounts.enumerated() {
            // A group that would take the page past its books begins the
            // next page, unless it would be the page's first.
            if index > start, rows + count > rowsPerPage {
                ranges.append(start..<index)
                start = index
                rows = 0
            }
            rows += count
        }
        if start < rowCounts.count {
            ranges.append(start..<rowCounts.count)
        }
        self.ranges = ranges
    }

    /// The pages of `groups`, as the sheet shows them.
    init(groups: [DuplicateGroup], rowsPerPage: Int = Self.rowsPerPage) {
        self.init(rowCounts: groups.map(\.books.count), rowsPerPage: rowsPerPage)
    }

    /// How many pages there are.
    var count: Int { ranges.count }

    /// `page` within the pages there are: the first for one before them,
    /// the last for one past them.
    func clamped(_ page: Int) -> Int {
        min(max(page, 0), max(ranges.count - 1, 0))
    }

    /// The indices of the groups on `page`, which is clamped first; none
    /// when there is no page.
    func groupIndices(onPage page: Int) -> Range<Int> {
        ranges.isEmpty ? 0..<0 : ranges[clamped(page)]
    }

    /// The page to show once the scan is made again, as after a removal,
    /// these being the pages of its `groups`: the page now holding the
    /// group with `groupID`, the one that headed the page shown before,
    /// when the scan still finds it, so the list stays where it was;
    /// otherwise `previousPage`, or the last page when there are fewer.
    func page(keeping groupID: String?, of groups: [DuplicateGroup], orElse previousPage: Int) -> Int {
        if let groupID, let index = groups.firstIndex(where: { $0.id == groupID }),
           let page = ranges.firstIndex(where: { $0.contains(index) }) {
            return page
        }
        return clamped(previousPage)
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

    /// The scan button's title.
    static let scanTitle = "Scan for Duplicates"

    /// What the sheet shows before its first scan, naming the scan button
    /// by its title, which reads as what to do; it said "press Scan", a
    /// button with another name (TODO A10).
    static let notScannedYet = "Check the criteria above, then \(scanTitle)."

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

    // MARK: Pages (REV13)

    /// The line over the page of groups shown while a scan's groups take
    /// more than one page (`DuplicateGroupPages`), shown and spoken alike,
    /// and announced as Previous Groups or Next Groups turns to its page:
    /// "Showing groups 1 to 7 of 116", or, for a page holding one group,
    /// "Showing group 12 of 116". `range` is a page's group indices.
    static func pageLine(groups range: Range<Int>, of total: Int) -> String {
        range.count == 1
            ? "Showing group \(range.upperBound) of \(total)"
            : "Showing groups \(range.lowerBound + 1) to \(range.upperBound) of \(total)"
    }

    /// The title of the button turning to the page of groups before.
    static let previousPageTitle = "Previous Groups"
    /// What that button does.
    static let previousPageHint = "Shows the groups before these."
    /// The title of the button turning to the page of groups after.
    static let nextPageTitle = "Next Groups"
    /// What that button does.
    static let nextPageHint = "Shows the groups after these."
}

/// The line saying which of a scan's groups the sheet shows, with the
/// buttons turning to the groups before and after, while the groups take
/// more than one page (`DuplicateGroupPages`). A button with no page to
/// turn to is dimmed, so each stays where it is.
struct DuplicateGroupPager: View {
    /// Which groups are shown (`DuplicateFinderWording.pageLine`).
    let line: String
    /// Whether a page comes before the one shown.
    let hasPrevious: Bool
    /// Whether a page comes after the one shown.
    let hasNext: Bool
    /// Turns to the page before.
    let onPrevious: () -> Void
    /// Turns to the page after.
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(line)
                .font(.callout)
            Spacer()
            Button(DuplicateFinderWording.previousPageTitle, action: onPrevious)
                .disabled(!hasPrevious)
                .accessibilityHint(DuplicateFinderWording.previousPageHint)
            Button(DuplicateFinderWording.nextPageTitle, action: onNext)
                .disabled(!hasNext)
                .accessibilityHint(DuplicateFinderWording.nextPageHint)
        }
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
    /// The page of `scanResults` shown (`DuplicateGroupPages`), from 0.
    @State private var pageIndex = 0
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
                    .checkboxToggleStyle()
                    .accessibilityLabel(filter.rawValue)
                    .accessibilityHint(filter.hint)
                }

                HStack {
                    Button(isLoadingISBNs ? "Loading ISBNs..." : DuplicateFinderWording.scanTitle) {
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
                Text(DuplicateFinderWording.notScannedYet)
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
                if pages.count > 1 {
                    DuplicateGroupPager(
                        line: pageLine,
                        hasPrevious: pageIndex > 0,
                        hasNext: pageIndex < pages.count - 1,
                        onPrevious: { turnPage(by: -1) },
                        onNext: { turnPage(by: 1) }
                    )
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    Divider()
                }
                DuplicateGroupList(groups: shownGroups, selection: $selectedForRemoval)
                    // Made anew for each page, so a page opens at its top.
                    .id(shownRange.lowerBound)
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
                    runScan()
                }
            }
        } else {
            runScan()
        }
    }

    /// Run the duplicate scan and cache results. A scan the user asked for
    /// shows its first page of groups and says what it found. The scan made
    /// again `afterRemoval` stays quiet, since the removal's outcome is
    /// announced instead, and keeps the list where it was: on the page now
    /// holding the group that headed the page shown.
    private func runScan(afterRemoval: Bool = false) {
        let headingGroupID = afterRemoval ? shownGroups.first?.id : nil
        scanResults = DuplicateFinderEngine.findDuplicates(
            books: libraryViewModel.booksForDuplicateScan,
            filters: activeFilters,
            isbnCache: isbnCache
        )
        pageIndex = afterRemoval ? pages.page(keeping: headingGroupID, of: scanResults, orElse: pageIndex) : 0
        hasScanned = true
        if !afterRemoval {
            DuplicateFinderWording.announceScanResult(groupCount: scanResults.count)
        }
    }

    // MARK: - Pages

    /// The pages the scan's groups are shown in.
    private var pages: DuplicateGroupPages {
        DuplicateGroupPages(groups: scanResults)
    }

    /// The indices of the groups on the page shown.
    private var shownRange: Range<Int> {
        pages.groupIndices(onPage: pageIndex)
    }

    /// The groups on the page shown.
    private var shownGroups: [DuplicateGroup] {
        Array(scanResults[shownRange])
    }

    /// The line saying which groups are shown, while there are pages.
    private var pageLine: String {
        DuplicateFinderWording.pageLine(groups: shownRange, of: scanResults.count)
    }

    /// Turns `offset` pages on, back for a negative one, and says which
    /// groups are shown now, since VoiceOver stays on the button pressed.
    private func turnPage(by offset: Int) {
        pageIndex = pages.clamped(pageIndex + offset)
        VoiceOverAnnouncer.announce(pageLine)
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
        runScan(afterRemoval: true)
    }

    // MARK: - Helpers

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
                pageIndex = 0
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

/// The Duplicate Finder's results, one page of them: each group's heading,
/// then a native checkbox for each of its books, which checks it for
/// removal. The sheet labels the list with what the scan found.
struct DuplicateGroupList: View {
    /// The groups on the page shown, in the order the engine sorted them.
    let groups: [DuplicateGroup]
    /// The books checked for removal.
    @Binding var selection: Set<UUID>

    var body: some View {
        ScrollView {
            // Keep every group and book row alive while the sheet is
            // open, as the headings and bookmarks panels do:
            // LazyVStack recycles rows out of view, which can
            // invalidate VoiceOver's current element and send its
            // cursor back toward the top (TODO A10). That is costly:
            // measured on October 10, 2026, hosted at the sheet's size
            // in a Debug build, each book's native checkbox took 4 to 8
            // ms of the main thread and a quarter of a megabyte (a row
            // of text alone, 0.2 ms), so an author scan of a 700-book
            // library, 116 groups of 688 books, took 4 to 5.4 seconds
            // and 184 MB to show at once, and each check redrew it in
            // 0.14 to 0.24 seconds. So the sheet shows a page of at most
            // 40 books (`DuplicateGroupPages`): that scan's first page,
            // 36 books, took 0.23 seconds and 10 MB, and a check 21 ms.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(groups) { group in
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
                        .checkboxToggleStyle()
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .background(selection.contains(book.id)
                            ? Color.red.opacity(0.08) : Color.clear)
                        .accessibilityLabel(DuplicateFinderWording.bookLabel(book))
                        Divider().padding(.leading)
                    }
                }
            }
        }
    }

    /// Stable binding for a book's selection state
    private func selectionBinding(for bookID: UUID) -> Binding<Bool> {
        Binding(
            get: { selection.contains(bookID) },
            set: { isOn in
                if isOn {
                    selection.insert(bookID)
                } else {
                    selection.remove(bookID)
                }
            }
        )
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
