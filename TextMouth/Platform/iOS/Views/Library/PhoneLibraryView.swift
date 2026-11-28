import Combine
import SwiftUI

/// Where VoiceOver's focus is sent on a Library screen: a row, or one of the
/// screen's own controls.
enum PhoneLibraryFocus: Hashable, Sendable {
    /// A book's or a folder's row.
    case row(PhoneRowID)
    /// The Continue row.
    case continueRow
    /// The Library view row.
    case libraryView
    /// Settings, in the bottom bar.
    case settings
    /// New Folder, in the bottom bar.
    case newFolder
    /// Sort, in the bottom bar.
    case sort
    /// The title of the export card at the top of the list.
    case exportCard
    /// The Stop button of the export card, which goes when its export ends.
    case exportCardStop
}

/// One iPhone Library screen (the iPhone interface spec, "The Library"): the
/// top of the Folders view, a folder, or any other view, one view over a
/// `LibraryLocation`.
///
/// VoiceOver's order: the title, the search field, the Continue row, Library
/// view (not in a folder), the folders under "Folders", the books under the
/// Mac's "Books (743)" and, in a long Title or Author sort, under letters,
/// the summary, then the bottom bar: Settings (not in a folder), New Folder
/// (Folders only), Sort, and Add to Library.
///
/// The view is thin: every word, every row, and what each command offers come
/// from plain types (`PhoneLibraryRows`, `PhoneRowWording`, `PhoneLibraryOffer`,
/// `PhoneLibraryChoices`), which the Mac's test host tests. It observes those
/// rows, never the library, so nothing is redrawn as a book plays.
///
/// Nothing here has run on iOS. Unverified until a first run, and on the
/// hand-check list: that VoiceOver's order runs through the list to the
/// bottom bar; that a heading-only section shows its heading; that
/// `onAppear` runs again on Back; that focus can be sent to a bottom bar's
/// button; and how quickly 700 rows flick by.
struct PhoneLibraryView: View {
    /// The app's model: the library, the settings, the session, the path.
    private let model: PhoneAppModel
    /// Whether this is a folder's screen, which has Back, no Library view, and
    /// no Settings.
    private let isFolderScreen: Bool

    /// The list, as values that change only when the list does.
    @StateObject private var rows: PhoneLibraryRows
    /// What the search field holds.
    @State private var searchText = ""
    /// The sheet shown, if any.
    @State private var sheet: PhoneLibrarySheet?
    /// The control a sheet returns focus to when it closes.
    @State private var sheetOpener: PhoneLibraryFocus?
    /// The rows as they were when the sheet opened.
    @State private var rowsWhenSheetOpened: [PhoneRowID] = []
    /// What VoiceOver says once the sheet has closed.
    @State private var sayAfterSheet: String?
    /// Whether the export card appeared as the sheet now closing closed (`PhoneExportCardFocus`): its dismissal then focuses
    /// the card.
    @State private var exportCardAppeared = false
    /// The Library's alert, if one shows: the removal question about a book, or why Remove Download left a book's
    /// download (FR46). One state and one alert modifier for both (`PhoneLibraryAlert`).
    @State private var alert: PhoneLibraryAlert?
    /// The row left for a book's or a folder's screen, which focus returns to.
    @State private var rowLeft: PhoneRowID?
    /// The rows as they were when that row was left, for the row that takes
    /// its place if it has gone.
    @State private var rowsWhenLeft: [PhoneRowID] = []
    /// Whether the screen has appeared before, so a folder says its words once.
    @State private var hasAppeared = false
    /// The row a feed command was run from, until the row it takes away has gone and focus has moved to its place (FR53).
    @State private var feedFocus: PhoneFeedFocusRequest?
    /// The count said once typing stops, waiting for a second of quiet.
    @State private var searchCountTask: Task<Void, Never>?
    /// Whether "No books match." was said for the current run of no results.
    @State private var saidNoMatches = false
    /// What was read of the book whose Book Info is shown.
    @State private var bookInfo: LibraryBookInfo = .simple
    /// The Book Info being read, so a later request replaces one still reading.
    @State private var bookInfoRequest: UUID?
    /// The list's scroller, kept for focus requests from outside its builder.
    @State private var scroller: ScrollViewProxy?
    /// The search field's keyboard focus, put down when a book opens.
    @FocusState private var searchFieldFocused: Bool
    /// VoiceOver's focus on this screen, set only on arrival and return.
    @AccessibilityFocusState private var focus: PhoneLibraryFocus?
    /// Pops this screen when it is a folder's, for the escape gesture.
    @Environment(\.dismiss) private var dismiss

    /// A Library screen at `location`.
    init(model: PhoneAppModel, location: LibraryLocation) {
        self.model = model
        isFolderScreen = location.view.kind == .folders && !location.folderPath.isEmpty
        let session = model.session
        let settings = model.settings
        // The Continue row hears the book behind the one on screen, else the
        // one reader (`continueSnapshot`), which and whether it plays alone.
        let listening = Publishers.CombineLatest(session.$listeningSnapshot, session.$snapshot)
            .map { behind, onScreen in
                let shown = behind ?? onScreen
                return PhoneLibraryListening(bookID: shown?.bookID, isPlaying: shown?.isPlaying ?? false)
            }
            .eraseToAnyPublisher()
        _rows = StateObject(wrappedValue: PhoneLibraryRows(
            library: model.library,
            location: location,
            wordsPerMinute: { settings.wordsPerMinute },
            removalPreferences: { RemovalPreferencesModel.shared.preferences },
            bookInReach: { session.bookInReach },
            listening: listening
        ))
    }

    /// The library the rows come from, called but never observed here.
    private var library: LibraryViewModel { model.library }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                // The import's progress, Slice 3's, at the top of the list
                // after the title (the spec's "Progress"): it shows nothing
                // while nothing imports, and observes only the import.
                PhoneImportProgressCard()
                // An export that goes on with its sheet closed (FR31, phase 2): the sheet's title, how far it has
                // come, and Stop; then what it did, and Close. It shows nothing while no export has its card.
                PhoneExportProgressCard(focus: $focus)
                // The Mac's Storage problems notice, as it is, at the top of
                // the list while a write keeps failing: it observes only the
                // failure center, and shows nothing until then. Each of its
                // buttons keeps its own touch area in a row.
                PersistenceFailureBanner(center: library.failureCenter)
                    .buttonStyle(.borderless)
                if !rows.isSearching {
                    if let continueRow = rows.continueRow {
                        PhoneContinueRowView(
                            value: continueRow,
                            open: { openContinueBook(continueRow.bookID) },
                            playPause: { _ = model.session.togglePlayPauseFromAnywhere() }
                        )
                        .equatable()
                        .accessibilityFocused($focus, equals: .continueRow)
                        .id(PhoneLibraryFocus.continueRow)
                    }
                    if !isFolderScreen && !showsEmptyLibrary {
                        libraryViewRow
                    }
                }
                ForEach(rows.sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            rowView(row)
                                .accessibilityFocused($focus, equals: .row(row.id))
                                .id(PhoneLibraryFocus.row(row.id))
                        }
                    } header: {
                        if let header = section.header {
                            // Full contrast (`PhoneTextColor`); the heading's
                            // text style still scales.
                            Text(header)
                                .phoneSecondaryText()
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                    // iOS 26's section index, for touch: the letter sections'.
                    .sectionIndexLabel(section.indexLabel)
                }
                if !rows.isSearching, let summary = rows.summary {
                    // One static element, built with the rows.
                    // A text style (it scales with Dynamic Type), given the
                    // row's whole width and as many lines as it needs, in
                    // the primary label color for contrast. No fixed size
                    // or line limit: the audit still found the footnote
                    // style with a vertical fixed size "partially
                    // unsupported", so it's the subheadline style, free to
                    // grow.
                    // With a Sync Now action for VoiceOver once sync is on (FR43).
                    PhoneLibrarySummaryText(summary: summary)
                }
            }
            .onAppear {
                scroller = proxy
                arrive()
            }
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(PhoneLibraryVocabulary.searchPrompt)
        )
        .searchFocused($searchFieldFocused)
        // VoiceOver's escape (the two-finger scrub): the search is cleared
        // first, then a folder goes back, as `PhoneEscapePolicy` says.
        .accessibilityAction(.escape) { scrubbed() }
        .onChange(of: searchText) { _, text in
            searched(text)
        }
        // A feed command that took its row away (Delete Download, Delete Episode…) leaves focus on the row now in its place.
        .onChange(of: rows.rowIDs) { _, now in
            feedRowsChanged(to: now)
        }
        .navigationTitle(PhoneRowWording.screenTitle(for: rows.location))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                bottomBar
            }
        }
        // The export card appearing, ending, and being closed moves VoiceOver's focus.
        .onReceive(PhoneExportSession.shared.cardEvents) { exportCardChanged($0) }
        .sheet(item: $sheet, onDismiss: { sheetClosed() }) { shown in
            sheetView(shown)
        }
        // The removal question, or why Remove Download kept a book's download (FR46), as the Mac shows it: one alert
        // modifier for both, since this screen stays under every screen pushed over it, the reader and its sheets.
        .alert(
            alert?.title ?? "",
            isPresented: Binding(
                get: { alert != nil },
                set: { if !$0 { alert = nil } }
            ),
            presenting: alert
        ) { shown in
            switch shown {
            case .removal(let book):
                Button(PhoneRowWording.removalDeleteButton, role: .destructive) {
                    remove(book)
                }
                Button(PhoneAppWording.cancel, role: .cancel) {}
            case .removeDownloadRefused:
                Button(PhoneAppWording.close, role: .cancel) {}
            }
        } message: { shown in
            Text(shown.message)
        }
    }

    // MARK: - Rows

    /// Whether the list is the empty library's one sentence, with the rest
    /// of the list absent.
    private var showsEmptyLibrary: Bool {
        rows.rowIDs == [.note(.emptyLibrary)]
    }

    /// The Library view row: its label, its value the view's name, opening
    /// the choices.
    private var libraryViewRow: some View {
        Button {
            open(.libraryView, from: .libraryView)
        } label: {
            // The system's label colors, not the button's tint, which
            // `LabeledContent` would take inside a Button.
            LabeledContent {
                // Full contrast (the audit found the secondary color not
                // enough); the label stays distinct by its semibold weight.
                Text(rows.location.view.name)
                    .phoneSecondaryText()
            } label: {
                Text(PhoneRowWording.libraryViewLabel)
                    .fontWeight(.semibold)
                    .phonePrimaryText()
            }
        }
        .accessibilityLabel(PhoneRowWording.libraryViewLabel)
        .accessibilityValue(rows.location.view.name)
        .accessibilityHint(PhoneRowWording.libraryViewHint)
        .accessibilityFocused($focus, equals: .libraryView)
        .id(PhoneLibraryFocus.libraryView)
    }

    /// The view of `row`, by its kind.
    @ViewBuilder
    private func rowView(_ row: PhoneRowValue) -> some View {
        switch row.id {
        case .book(let bookID):
            PhoneBookRow(value: row, open: { openBook(bookID) }, perform: { perform($0, onBook: bookID, titled: row) })
                .equatable()
        case .folder(let folderID):
            PhoneFolderRow(value: row, open: { openFolder(folderID) }, perform: { perform($0, onFolder: folderID, titled: row) })
                .equatable()
        case .note:
            PhoneNoteRow(value: row)
        case .feed(let feedID):
            PhoneFeedRow(value: row, open: { openFeed(feedID) }, perform: { perform($0, onFeed: feedID) })
                .equatable()
        case .feedItem(let feedID, let itemID):
            PhoneFeedItemRow(
                value: row,
                // The item's default action opens it, downloading it first when it is not here (FR53).
                open: { perform(.feedItem(.open), onItem: itemID, of: feedID, from: row.id) },
                perform: { perform($0, onItem: itemID, of: feedID, from: row.id) }
            )
            .equatable()
        }
    }

    // MARK: - The Bottom Bar

    /// Settings, New Folder, Sort, and Add to Library, each where the spec
    /// puts it: the last elements of the screen.
    @ViewBuilder
    private var bottomBar: some View {
        if !isFolderScreen {
            Button(PhoneRowWording.settingsTitle) {
                model.path.append(.settings)
            }
            .accessibilityHint(PhoneRowWording.settingsHint)
            .accessibilityFocused($focus, equals: .settings)
        }
        if rows.location.view.kind == .folders {
            Button {
                open(.folder(.newFolder(parentPath: rows.location.folderPath)), from: .newFolder)
            } label: {
                Label(PhoneFolderVocabulary.newFolderTitle, systemImage: "folder.badge.plus")
            }
            .accessibilityLabel(PhoneLibraryVocabulary.newFolderLabel)
            .accessibilityFocused($focus, equals: .newFolder)
        }
        Button {
            open(.sort, from: .sort)
        } label: {
            Label(PhoneLibraryVocabulary.sortTitle, systemImage: "arrow.up.arrow.down")
        }
        .accessibilityLabel(PhoneLibraryChoices.sortLabel(at: rows.location, sort: library.sortState(at: rows.location)))
        .accessibilityHint(PhoneRowWording.sortHint)
        .accessibilityFocused($focus, equals: .sort)
        Button(AddToLibraryWording.buttonTitle) {
            // Slice 3's sheet, importing into the folder this screen shows,
            // as on the Mac; "" at the top and in any other view.
            PhoneImportCopier.shared.showAddToLibrary(inFolder: rows.location.folderPath)
        }
        .accessibilityLabel(AddToLibraryWording.buttonLabel)
        .accessibilityHint(PhoneRowWording.addToLibraryHint)
    }

    // MARK: - Sheets

    /// The view of `shown`.
    @ViewBuilder
    private func sheetView(_ shown: PhoneLibrarySheet) -> some View {
        switch shown {
        case .libraryView:
            PhoneChoiceSheet(
                title: PhoneRowWording.libraryViewLabel,
                choices: PhoneLibraryChoices.views(
                    in: library,
                    list: LibraryViewDefinitionStore.shared.list,
                    current: rows.location.view.id,
                    center: LibraryFeedFolders.shared.center
                ),
                selected: rows.location.view.id,
                onChoose: { chooseView($0) }
            )
        case .sort:
            let sort = library.sortState(at: rows.location)
            PhoneChoiceSheet(
                title: PhoneLibraryVocabulary.sortTitle,
                choices: PhoneLibraryChoices.sortChoices(
                    at: rows.location,
                    sort: sort,
                    hasSubfolders: !library.subfoldersOf(rows.location.folderPath).isEmpty
                ),
                selected: PhoneLibraryChoices.currentSortChoice(at: rows.location, sort: sort),
                onChoose: { chooseSort($0) }
            )
        case .bookInfo(let bookID):
            // It says "Metadata updated" itself, once the save is done.
            if let book = library.bookByID(bookID) {
                PhoneBookInfoSheet(book: book, library: library, info: bookInfo)
            }
        case .folder(let request):
            folderSheet(request)
        case .export(let bookID):
            // A book gone meanwhile has no sheet. What keeps the app running
            // while an export does is the life cycle's.
            if let book = library.bookByID(bookID) {
                PhoneExportSheet(
                    books: [book],
                    library: library,
                    beginHold: { [lifeCycle = model.lifeCycle] name in lifeCycle.beginHold(name) }
                )
            }
        case .exportFolder(let path):
            // The folder's books as the library holds them now, each exported into a folder of its own (the Mac's way for
            // several books); a folder emptied meanwhile has no sheet.
            let books = library.library.booksInFolderTree(path)
            if !books.isEmpty {
                PhoneExportSheet(
                    books: books,
                    library: library,
                    beginHold: { [lifeCycle = model.lifeCycle] name in lifeCycle.beginHold(name) }
                )
            }
        }
    }

    /// Slice 2b's folder sheet for `request`, one initializer for each. Each
    /// holds its own navigation stack and title, closes itself, and says its
    /// own words; focus returns in `sheetClosed()`, to the row in the place
    /// of one that left. A book gone meanwhile has no sheet.
    @ViewBuilder
    private func folderSheet(_ request: PhoneLibraryFolderSheet) -> some View {
        switch request {
        case .newFolder(let parentPath):
            PhoneFolderSheet(library: library, newFolderIn: parentPath) { _ in }
        case .rename(let folder):
            PhoneFolderSheet(library: library, renaming: folder) { _ in }
        case .move(let folder):
            PhoneFolderSheet(library: library, moving: folder) { _ in }
        case .delete(let folder):
            PhoneFolderSheet(library: library, deleting: folder) { _ in }
        case .moveBook(let bookID):
            if let book = library.bookByID(bookID) {
                PhoneFolderSheet(library: library, movingBooks: [book]) { _ in }
            }
        }
    }

    /// Shows `shown`, and remembers `opener` for focus to return to, with the
    /// rows as they were, for a row a sheet moves or deletes.
    private func open(_ shown: PhoneLibrarySheet, from opener: PhoneLibraryFocus) {
        sheetOpener = opener
        rowsWhenSheetOpened = rows.rowIDs
        sheet = shown
    }

    /// Once a sheet has closed: focus back on what opened it, or, for a row
    /// the sheet took out of the list, on the row now in its place, a turn
    /// later, once the list has heard of the change; then what the sheet's
    /// choice says, after VoiceOver has settled (the Mac's `afterSheetDelay`).
    private func sheetClosed() {
        // An export sheet that closed on a card gives focus to the card, and nothing else asks: one owner, one request.
        let landing = PhoneExportCardFocus.afterSheetClosed(cardAppeared: exportCardAppeared)
        exportCardAppeared = false
        if landing == .card {
            DispatchQueue.main.async { requestFocus(.exportCard) }
        } else if let opener = sheetOpener {
            let before = rowsWhenSheetOpened
            DispatchQueue.main.async {
                guard case .row(let row) = opener else {
                    requestFocus(opener)
                    return
                }
                let now = rows.rowIDs
                if let target = PhoneListFocus.row(row, in: now, fallback: nil)
                    ?? PhoneListFocus.fallback(forGone: row, oldRows: before, newRows: now, otherwise: nil) {
                    requestFocus(.row(target))
                }
            }
        }
        sheetOpener = nil
        if let said = sayAfterSheet {
            DispatchQueue.main.asyncAfter(deadline: .now() + VoiceOverAnnouncer.afterSheetDelay) {
                PhoneAnnouncer.say(said)
            }
        }
        sayAfterSheet = nil
    }

    /// Shows the view `id` in place, at its top. Nothing is said: focus
    /// returns to Library view, which reads the new value.
    private func chooseView(_ id: LibraryViewID) {
        guard let view = LibraryViewDefinitionStore.shared.list.view(id) else { return }
        rows.show(LibraryLocation(view: view, folderPath: ""))
    }

    /// Makes the sort choice through the Mac's one path, lists the books in
    /// the new order, and says the Mac's words once the sheet has closed.
    private func chooseSort(_ choice: PhoneLibraryChoices.SortChoice) {
        sayAfterSheet = PhoneLibraryChoices.choose(choice, at: rows.location, in: library)
        rows.show(rows.location)
    }

    // MARK: - Opening

    /// Opens the book `bookID` in the session, without stopping the one that
    /// plays, and pushes the reader's screen. Back returns focus to its row.
    private func openBook(_ bookID: UUID) {
        guard let book = library.bookByID(bookID) else { return }
        leaveRow(.book(bookID))
        guard model.session.open(book) != nil else { return }
        model.showReader()
    }

    /// Opens the book the Continue row names and pushes the reader's screen;
    /// a book playing goes on playing.
    private func openContinueBook(_ bookID: UUID) {
        guard let book = library.bookByID(bookID) else { return }
        rowLeft = nil
        searchFieldFocused = false
        guard model.session.open(book) != nil else { return }
        model.showReader()
    }

    /// Pushes the folder `folderID`, by its path now. Back returns focus to
    /// its row.
    private func openFolder(_ folderID: UUID) {
        guard let folder = libraryFolder(folderID) else { return }
        leaveRow(.folder(folderID))
        model.path.append(.folder(path: folder.fullPath))
    }

    /// The library's folder `folderID`, or nil once it has gone.
    private func libraryFolder(_ folderID: UUID) -> BookFolder? {
        library.library.folders.first { $0.id == folderID }
    }

    /// Remembers `row` for focus to return to, with the rows around it, and
    /// puts the keyboard down, keeping the search.
    private func leaveRow(_ row: PhoneRowID) {
        rowLeft = row
        rowsWhenLeft = rows.rowIDs
        searchFieldFocused = false
    }

    /// On arrival and on every return: the rows built afresh; a folder says
    /// its words once; a return sends focus to the row left, or to the row
    /// now in its place, or the Continue row.
    private func arrive() {
        rows.rebuild()
        guard hasAppeared else {
            hasAppeared = true
            if isFolderScreen {
                // Focus is left where VoiceOver puts it, the title or Back.
                let words = PhoneRowWording.folderArrival(at: rows.location.folderPath, in: library.library)
                DispatchQueue.main.asyncAfter(deadline: .now() + PhoneListFocus.settleDelay) {
                    PhoneAnnouncer.say(words)
                }
            }
            return
        }
        guard let left = rowLeft else { return }
        rowLeft = nil
        let now = rows.rowIDs
        if let target = PhoneListFocus.row(left, in: now, fallback: nil)
            ?? PhoneListFocus.fallback(forGone: left, oldRows: rowsWhenLeft, newRows: now, otherwise: nil) {
            requestFocus(.row(target))
        } else if rows.continueRow != nil {
            requestFocus(.continueRow)
        }
    }

    /// What happened to the export card (`PhoneExportCardFocus` decides): the card appearing is noted, for the dismissal of
    /// the sheet that closed on it to focus the card; its export ending moves focus only off its Stop, which has gone; and
    /// once it is closed focus goes to the Library's first row, so that it never rests on something that has gone.
    private func exportCardChanged(_ event: PhoneExportSession.CardEvent) {
        // Only a sheet of this screen leaves its dismissal to say; one over the reader, or none, leaves nothing to say.
        if event == .appeared, sheetOpener != nil { exportCardAppeared = true }
        switch PhoneExportCardFocus.target(for: event, focusWasOnStop: focus == .exportCardStop) {
        case .card?:
            requestFocus(.exportCard)
        case .firstRow?:
            if let first = rows.rowIDs.first { requestFocus(.row(first)) }
        case nil:
            break
        }
    }

    /// Sends VoiceOver's focus to `target` by the list's one helper
    /// (`PhoneListFocus`): scrolled into being, then asked for a moment later.
    private func requestFocus(_ target: PhoneLibraryFocus) {
        guard let scroller else { return }
        PhoneListFocus.focus(target, proxy: scroller, state: $focus)
    }

    // MARK: - Feeds (FR53)

    /// Opens the folder of the feed `feedID`, which lists its items, and
    /// pushes its screen; Back returns focus to its row. A feed whose folder
    /// has gone says so, as the Mac does, and opens nothing.
    private func openFeed(_ feedID: UUID) {
        guard let feed = library.feeds.store.record(of: feedID)?.feed else { return }
        guard let path = library.feeds.folderPath(of: feed) else {
            PhoneAnnouncer.say(FeedWording.folderMissing(title: feed.title))
            return
        }
        leaveRow(.feed(feedID))
        model.path.append(.folder(path: path))
    }

    /// Runs a feed row's command, which the Mac's runner does and says: the
    /// questions it asks and the sheets it opens are the root's.
    private func perform(_ action: PhoneLibraryOffer.Action, onFeed feedID: UUID) {
        guard case .feed(let command) = action else { return }
        PhoneFeedsHub.shared.perform(command, feedID: feedID, in: library)
    }

    /// Runs a feed item's command from its own row or its downloaded book's,
    /// `row`. A command that takes the row away or gives it another identity
    /// (Delete Download makes a book's row the item's; Delete Episode… takes
    /// it out of the list) first asks that focus follow it to the row in its
    /// place (`feedRowsChanged(to:)`).
    private func perform(_ action: PhoneLibraryOffer.Action, onItem itemID: String, of feedID: UUID, from row: PhoneRowID) {
        guard case .feedItem(let command) = action else { return }
        if command == .deleteDownload || command == .deleteItem {
            feedFocus = PhoneFeedFocusRequest(
                row: row,
                successor: command == .deleteDownload ? .feedItem(feedID: feedID, itemID: itemID) : nil,
                oldRows: rows.rowIDs
            )
        }
        PhoneFeedsHub.shared.perform(command, feedID: feedID, itemID: itemID, in: library)
        rows.rebuild()
    }

    /// Once the list changes after a feed command, sends focus to the row in
    /// the place of the one the command took away: the row that took its
    /// identity, else the one after it, or before it. A row still there
    /// leaves focus where VoiceOver has it (the command was cancelled, or
    /// changed only the row's words).
    private func feedRowsChanged(to now: [PhoneRowID]) {
        guard let request = feedFocus, !now.contains(request.row) else { return }
        feedFocus = nil
        let target = request.successor.flatMap { now.contains($0) ? $0 : nil }
            ?? PhoneListFocus.fallback(forGone: request.row, oldRows: request.oldRows, newRows: now, otherwise: nil)
        if let target {
            requestFocus(.row(target))
        }
    }

    // MARK: - Searching

    /// Lists what `text` finds, and, once typing has stopped for a second,
    /// says the count with low priority; "No books match." is said once for a
    /// run of searches that find nothing.
    private func searched(_ text: String) {
        rows.search(for: text)
        searchCountTask?.cancel()
        guard !text.isEmpty else {
            saidNoMatches = false
            return
        }
        searchCountTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            let counts = rows.searchCounts
            let foundNothing = counts.books == 0 && counts.folders == 0
            guard !(foundNothing && saidNoMatches) else { return }
            saidNoMatches = foundNothing
            PhoneAnnouncer.say(PhoneRowWording.searchCount(books: counts.books, folders: counts.folders))
        }
    }

    /// The escape gesture: clears a search and puts focus on the field, else
    /// goes back from a folder to its parent. The top of the Library has
    /// nowhere to go, so nothing happens there.
    private func scrubbed() {
        switch PhoneEscapePolicy.libraryOutcome(isSearching: !searchText.isEmpty, isFolderScreen: isFolderScreen) {
        case .clearSearch:
            // The text's change reaches `rows` through `onChange(of:)`.
            searchText = ""
            searchFieldFocused = true
        case .goBack:
            dismiss()
        case .nothing:
            break
        }
    }

    // MARK: - Commands

    /// Runs a book row's command.
    private func perform(_ action: PhoneLibraryOffer.Action, onBook bookID: UUID, titled row: PhoneRowValue) {
        guard let book = library.bookByID(bookID) else { return }
        switch action {
        case .bookInfo:
            showBookInfo(for: book)
        case .addToReadingList:
            PhoneAnnouncer.say(PhoneRowWording.readingListAdded(title: book.title, added: !library.addToReadingList([bookID]).isEmpty))
            rows.rebuild()
        case .removeFromReadingList:
            // At the Reading List the row leaves, and focus goes to its neighbor.
            let neighbor = rows.location.keepsItsOwnOrder ? rows.neighbor(of: .book(bookID)) : nil
            PhoneAnnouncer.say(PhoneRowWording.readingListRemoved(title: book.title, removed: !library.removeFromReadingList([bookID]).isEmpty))
            rows.rebuild()
            if let neighbor {
                requestFocus(.row(neighbor))
            }
        case .downloadNow:
            // The Mac's own command, on the book alone: it asks the cloud for the files, and the row shows the progress.
            let commands = LibraryCloudCommand.commands(for: [book], isSelection: false, states: .shared, kept: [])
            if let download = commands.first(where: { $0.kind == .download }) {
                Task { await library.cloudCommands.perform(download, in: library, from: nil) }
            }
        case .removeDownload:
            // The Mac's own command, on the book alone: it proves the copy in iCloud Drive first, says what came of it, and the row
            // shows In Cloud. A refusal is an alert, spoken once by VoiceOver as it appears.
            let commands = LibraryCloudCommand.commands(for: [book], isSelection: false, states: .shared, kept: [])
            if let removal = commands.first(where: { $0.kind == .removeDownload }) {
                Task {
                    if let refused = await library.cloudCommands.perform(removal, in: library, from: nil) {
                        alert = .removeDownloadRefused(refused)
                    }
                    rows.rebuild()
                }
            }
        case .keepOnAllDevices, .stopKeepingOnAllDevices:
            // Stamped on this device and synced, the set following at once; the person is told, and the rows are built again.
            PhoneKeepOnAllDevices.set(action == .keepOnAllDevices, book)
            rows.rebuild()
        case .moveToFolder:
            open(.folder(.moveBook(bookID)), from: .row(.book(bookID)))
        case .export:
            open(.export(bookID), from: .row(.book(bookID)))
        case .moveUp, .moveDown:
            move(book, direction: action == .moveUp ? -1 : 1)
        case .remove:
            if RemovalPreferencesModel.shared.preferences.confirmsFirst {
                alert = .removal(book)
            } else {
                remove(book)
            }
        case .feedItem:
            // The commands of the feed item the book was downloaded from (FR53).
            guard let link = book.feedLink else { return }
            perform(action, onItem: link.itemID, of: link.feedID, from: .book(bookID))
        case .renameFolder, .moveFolder, .deleteFolder, .exportFolder, .feed:
            break
        }
    }

    /// Runs a folder row's command: each a folder sheet. Delete Folder...
    /// first takes the Mac's step: a folder holding nothing is removed at
    /// once, with no question (`PhoneFolderSheetModel.startDeleting`).
    private func perform(_ action: PhoneLibraryOffer.Action, onFolder folderID: UUID, titled row: PhoneRowValue) {
        guard let folder = libraryFolder(folderID) else { return }
        let shown: PhoneLibraryFolderSheet
        switch action {
        case .renameFolder:
            shown = .rename(folder)
        case .moveFolder:
            shown = .move(folder)
        case .deleteFolder:
            guard PhoneFolderSheetModel.startDeleting(folder, in: library) == .asks else { return }
            shown = .delete(folder)
        case .exportFolder:
            // Not a folder sheet: the Export sheet, for the folder's books.
            open(.exportFolder(folder.fullPath), from: .row(.folder(folderID)))
            return
        default:
            return
        }
        open(.folder(shown), from: .row(.folder(folderID)))
    }

    /// Shows Book Info for `book` once what it shows is read, off the main
    /// thread, as the Mac's Library reads it: an EPUB's or an audiobook's
    /// metadata, or nothing more for any other book. A later request replaces
    /// one still reading.
    private func showBookInfo(for book: Book) {
        let request = UUID()
        bookInfoRequest = request
        Task { @MainActor in
            let info = await LibraryBookInfoReader.system.info(for: book)
            guard bookInfoRequest == request else { return }
            bookInfoRequest = nil
            bookInfo = info
            open(.bookInfo(book.id), from: .row(.book(book.id)))
        }
    }

    /// Moves `book` one place up (-1) or down (+1) in the order the list
    /// shows, and says the Mac's place, "Dune, 3 of 12". Focus stays on the
    /// row, whose identity is the same.
    private func move(_ book: Book, direction: Int) {
        let sort = library.sortState(at: rows.location)
        guard let target = rows.location.reorderTarget(sortedBy: sort) else { return }
        let said = library.moveBook(book.id, direction: direction, in: target)?.placeAnnouncement
            ?? ManualBookOrder.cannotMoveAnnouncement(book.title, direction: direction)
        rows.rebuild()
        PhoneAnnouncer.say(said)
    }

    /// Deletes `book` for good, its reader closed first if it is open; then
    /// focus goes to the row after it, or before it, and VoiceOver says the
    /// Mac's "Deleted “Dune” permanently.". A book that stays is named by the
    /// library's own alert, at the root.
    private func remove(_ book: Book) {
        let neighbor = rows.neighbor(of: .book(book.id))
        let session = model.session
        // Only this book's reader closes; a different book that plays on
        // behind the screen is left alone (nothing happens if it isn't open).
        session.closeBook(id: book.id)
        library.removeBooksAndDelete([book])
        guard library.bookByID(book.id) == nil else { return }
        rows.rebuild()
        if let neighbor {
            requestFocus(.row(neighbor))
        } else if rows.continueRow != nil {
            requestFocus(.continueRow)
        }
        let said = PhoneRowWording.removalDone(title: book.title)
        DispatchQueue.main.asyncAfter(deadline: .now() + VoiceOverAnnouncer.afterSheetDelay) {
            PhoneAnnouncer.say(said)
        }
    }
}
