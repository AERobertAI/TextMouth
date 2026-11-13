import Combine
import SwiftUI

// MARK: - Edit Mode Bar

/// Toolbar shown at the top of the library when edit mode is active.
/// Provides batch actions and selection controls that work reliably with VoiceOver.
///
/// It has no way out of edit mode of its own: the window's toolbar button
/// ("Exit edit mode") and the Library menu's Edit Mode, Command-E, are the
/// ways out. A Done here did the same as the toolbar's button, a second
/// control for one command (TODO A10).
struct EditModeBar: View {
    /// The listed books selected, by the list's own selection or edit
    /// mode's checks: those Move and Remove act on, as the Edit button's
    /// hint counts them too (`LibrarySelectionPolicy.selected(in:native:edit:)`).
    let selectedCount: Int
    /// The books listed.
    let totalCount: Int
    /// Whether removing asks first and where deleted files go, so the
    /// Remove button says what it will do.
    let removalPreferences: RemovalPreferences
    /// Whether every selected book is a feed item (FR11), whose Remove is
    /// its Delete Download, which the button then says it is (REV11 F2).
    var selectedAreFeedItems = false
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void
    let onMove: () -> Void
    let onRemove: () -> Void
    /// Add to Reading List and Remove from Reading List for the selected
    /// books, beside Move (FR09), by membership as a selection's row offers
    /// them, or the one the view suggests, dimmed, while none is selected
    /// (`ReadingListCommand.editBarCommands`). None unless the list
    /// supplies them.
    var readingListCommands: [ReadingListCommand] = []
    /// Runs one of `readingListCommands`, saying what it did as the row's
    /// context menu does.
    var onReadingListCommand: (ReadingListCommand) -> Void = { _ in }

    /// The words for removing the selected books: Delete Download's when
    /// every one is a feed item.
    private var removal: LibraryRemoveCommandWording {
        LibraryRemoveCommandWording(preferences: removalPreferences, count: selectedCount, feedItemsOnly: selectedAreFeedItems)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("\(selectedCount) of \(totalCount) selected")
                .font(.callout)
                .fontWeight(.medium)

            Spacer()

            // Select All, or Deselect All once every book listed is
            // selected; with no book listed, Select All, dimmed.
            let deselects = Self.offersDeselectAll(selectedCount: selectedCount, totalCount: totalCount)
            Button(deselects ? "Deselect All" : "Select All") {
                if deselects {
                    onDeselectAll()
                } else {
                    onSelectAll()
                }
            }
            .disabled(totalCount == 0)
            .accessibilityLabel(Self.selectAllLabel(selectedCount: selectedCount, totalCount: totalCount))

            Button("Move") { onMove() }
                .disabled(selectedCount == 0)
                .accessibilityLabel("Move \(CountWording.books(selectedCount)) to folder")

            // Add to Reading List and Remove from Reading List (FR09),
            // dimmed while they would act on no book.
            ForEach(readingListCommands) { command in
                Button(ReadingListWording.editBarTitle(command.kind)) { onReadingListCommand(command) }
                    .disabled(command.books.isEmpty)
                    .accessibilityLabel(ReadingListWording.editBarLabel(command.kind, count: command.books.count))
                    .accessibilityHint(ReadingListWording.editBarHint(command.kind))
            }

            Button(removal.shortTitle, role: .destructive) { onRemove() }
                .disabled(selectedCount == 0)
                .accessibilityLabel(removal.accessibilityLabel)
                .accessibilityHint(removal.accessibilityHint)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accessibilityLabel(selectedCount: selectedCount, totalCount: totalCount))
    }

    /// What VoiceOver calls the bar: "Edit mode, 0 of 1 book selected",
    /// "Edit mode, 2 of 5 books selected", the noun agreeing with the books
    /// listed (TODO A10; it said "0 of 1 books").
    nonisolated static func accessibilityLabel(selectedCount: Int, totalCount: Int) -> String {
        "Edit mode, \(CountWording.part(selectedCount, of: totalCount, singular: "book", plural: "books")) selected"
    }

    /// Whether the bar's selection button deselects: once every book listed
    /// is selected, and only while a book is listed, so a list of none
    /// offers Select All, dimmed, where it offered Deselect All (REV13).
    nonisolated static func offersDeselectAll(selectedCount: Int, totalCount: Int) -> Bool {
        totalCount > 0 && selectedCount >= totalCount
    }

    /// What VoiceOver calls Select All, or Deselect All once every book is
    /// selected: "Select all 1 book", "Select all 12 books", "Deselect all
    /// books" (TODO A10; it said "Select all 1 books"), and "Select all
    /// books", dimmed, while none is listed.
    nonisolated static func selectAllLabel(selectedCount: Int, totalCount: Int) -> String {
        if offersDeselectAll(selectedCount: selectedCount, totalCount: totalCount) {
            return "Deselect all books"
        }
        return totalCount > 0 ? "Select all \(CountWording.books(totalCount))" : "Select all books"
    }
}

// MARK: - Time Remaining Bar

struct TimeRemainingBar: View {
    let books: [Book]
    let wpm: Double
    /// How many of `books` are in the cloud (FR02), which the bar shows and
    /// speaks when it is more than 0. The list counts them in a cloud
    /// library and passes 0 anywhere else, where the bar is as it was.
    var booksInCloud: Int = 0
    /// How many of `books` are kept on this Mac (Keep on This Mac), which
    /// the bar shows and speaks after the books in the cloud when it is more
    /// than 0. The list counts them in a cloud library and passes 0 anywhere
    /// else.
    var booksKept: Int = 0
    /// Optional fallback focus target for the library when Continue Listening is absent.
    /// This summary is part of the content area and shows up reliably in the AX tree,
    /// unlike List section headers in this view hierarchy.
    var focusIdentifier: String? = nil
    var shouldTriggerFocus = false
    /// Where readers are between checkpoints (TODO PERF11): the bar adds up
    /// the time left from them and redraws as they move, while the list
    /// around it does not. The inert store, the default, holds none.
    @ObservedObject var livePositions: LiveReadingPositions = .inert
    /// What the bar says of the feed whose folder it sums up (FR03): the
    /// feed's items counted in place of the books, and its last check at
    /// the end. Nil, the default, everywhere else, where the bar is as it
    /// was; given, the bar shows even before any item is downloaded.
    var feedSummary: FeedWording.FolderSummary? = nil
    /// How many feeds the Feeds section lists where the bar is (FR11), which
    /// the bar names beside the books, as in "743 books, 2 feeds"; 0, the
    /// default, where it lists none, and the bar then counts the books
    /// alone. A feed's episodes and articles are never among `books`.
    var feedCount: Int = 0

    var body: some View {
        let (time, known, unknown) = computeTimeRemaining()
        if known > 0 || unknown > 0 || feedSummary != nil || feedCount > 0 {
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
                    Text("(\(CountWording.books(unknown)) not yet opened)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if booksInCloud > 0 {
                    Text(Self.cloudCountText(booksInCloud))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if booksKept > 0 {
                    Text(Self.keptCountText(booksKept))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let feedSummary {
                    Text(feedSummary.check.visible)
                        .font(.caption)
                        .foregroundColor(feedSummary.check.failed ? .red : .secondary)
                }

                Text(countText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel(time: time, known: known, unknown: unknown))
            .accessibilityIdentifier(focusIdentifier ?? "")
            .background(
                Group {
                    if shouldTriggerFocus {
                        StandardVoiceOverFocus(delay: 1.2)
                    }
                }
            )
        }
    }

    /// The time left in `books` at `wpm`, each from its reader's live
    /// position while that is newer than the library's, with how many books
    /// have a known and an unknown time left.
    private func computeTimeRemaining() -> (TimeInterval, Int, Int) {
        var total: TimeInterval = 0
        var known = 0
        var unknown = 0
        for book in books {
            if let remaining = livePositions.applied(to: book).estimatedTimeRemaining(wpm: wpm) {
                total += remaining
                known += 1
            } else {
                unknown += 1
            }
        }
        return (total, known, unknown)
    }

    /// What the bar counts, shown and spoken alike: in a feed's folder, the
    /// feed's items in place of the books; elsewhere the books, the episodes
    /// and articles listed beside them, as Recently Opened and the Reading
    /// List list them, each by its own noun, and the feeds beside them where
    /// there are any (FR11): "2 books, 5 episodes".
    var countText: String {
        feedSummary?.counts ?? CountWording.listItems(of: books, feeds: feedCount)
    }

    private func accessibilityLabel(time: TimeInterval, known: Int, unknown: Int) -> String {
        var parts: [String] = []
        parts.append(countText)
        if known > 0 {
            parts.append("\(TimeFormatting.spoken(time)) total remaining at current speed")
        }
        if unknown > 0 {
            parts.append("\(CountWording.phrase(unknown, singular: "book has", plural: "books have")) not been opened yet")
        }
        if booksInCloud > 0 {
            parts.append(Self.spokenCount(booksInCloud, "in the cloud"))
        }
        if booksKept > 0 {
            parts.append(Self.spokenCount(booksKept, "kept on this Mac"))
        }
        if let feedSummary {
            parts.append(feedSummary.check.visible)
        }
        return parts.joined(separator: ". ")
    }

    /// What VoiceOver says for the whole bar, as its body sets it.
    var summaryAccessibilityLabel: String {
        let (time, known, unknown) = computeTimeRemaining()
        return accessibilityLabel(time: time, known: known, unknown: unknown)
    }

    /// The bar's visible count of books in the cloud: "1 book in the cloud",
    /// "3 books in the cloud".
    static func cloudCountText(_ count: Int) -> String {
        "\(CountWording.books(count)) in the cloud"
    }

    /// The bar's visible count of books kept on this Mac: "1 book kept on
    /// this Mac", "3 books kept on this Mac".
    static func keptCountText(_ count: Int) -> String {
        "\(CountWording.books(count)) kept on this Mac"
    }

    /// `count` books said to be somewhere, as the bar's label speaks it:
    /// "1 book is in the cloud", "3 books are kept on this Mac".
    private static func spokenCount(_ count: Int, _ place: String) -> String {
        "\(CountWording.phrase(count, singular: "book is", plural: "books are")) \(place)"
    }
}

// MARK: - Breadcrumb Bar

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

// MARK: - Folder Row

struct FolderRow: View {
    let folder: BookFolder
    var bookCount: Int = 0
    /// The items of the feed whose folder this is, counted as the feed's
    /// row in the Feeds section counts them (FR03): the row then says the
    /// note "Feed" after the folder's name and counts the feed's items in
    /// place of its books. Nil, the default, for any other folder.
    var feedCounts: FeedItemCounts? = nil
    /// How many feeds have their folders below this one, as the Feeds
    /// section lists them there (FR11), which the row names beside its
    /// books; 0, the default, for none.
    var feedsBelow: Int = 0

    var body: some View {
        HStack {
            Image(systemName: "folder.fill")
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            Text(folder.name)
                .font(.headline)
            if feedCounts != nil {
                FeedBadge(text: FeedWording.feedNote, color: .secondary)
            }
            // A feed the listener unsubscribed from, which is not checked
            // (FR11, branch D); its label says so too.
            if feedCounts?.isSubscribed == false {
                FeedBadge(text: FeedWording.unsubscribedNote, color: .secondary)
            }
            Spacer()
            Text(Self.countText(bookCount: bookCount, feedCounts: feedCounts, feedsBelow: feedsBelow))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.accessibilityLabel(name: folder.name, bookCount: bookCount, feedCounts: feedCounts, feedsBelow: feedsBelow))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Self.accessibilityHint)
    }

    /// What VoiceOver says the row does: its result, never a gesture or a
    /// key, since VoiceOver, a braille display, and the keyboard each do it
    /// their own way (TODO A10; it said "Double-tap to open folder").
    nonisolated static let accessibilityHint = "Opens the folder."

    /// What the row shows after the folder's name: its books counted, "12
    /// books", with the feeds below it beside them, "3 books, 2 feeds", or
    /// those feeds alone where it holds no book, "2 feeds" (FR11); or, for a
    /// feed's folder, the feed's items as the feed's row counts them, "10 of
    /// 381 episodes listed, 3 downloaded" (FR03).
    static func countText(bookCount: Int, feedCounts: FeedItemCounts?, feedsBelow: Int = 0) -> String {
        feedCounts.map(FeedWording.countsPhrase) ?? CountWording.booksAndFeeds(books: bookCount, feeds: feedsBelow)
    }

    /// What VoiceOver says for a folder's row and for its entry in the
    /// Folders rotor, which share it: "Fiction, 12 books", "Poems, 1 book",
    /// "Podcasts, 3 books, 2 feeds", "Shows, 2 feeds" (FR11), and, for a
    /// feed's folder, its name, "Feed", and the feed's items as the feed's
    /// row counts them, "Planet Money, Feed, 10 of 381 episodes listed, 3
    /// downloaded", never its downloads as books (FR03).
    static func accessibilityLabel(name: String, bookCount: Int, feedCounts: FeedItemCounts?, feedsBelow: Int = 0) -> String {
        guard let feedCounts else { return "\(name), \(countText(bookCount: bookCount, feedCounts: nil, feedsBelow: feedsBelow))" }
        return FeedWording.folderAnnouncement(name: name, counts: feedCounts)
    }
}

// MARK: - Book Row

struct BookRow: View {
    let book: Book
    /// The title the row shows and speaks in place of the book's own, as
    /// the Leading articles setting has the Library show titles while
    /// sorting passes over articles ("Hobbit, The"); nil, the default,
    /// shows the book's title as written. The book keeps its title.
    var shownTitle: String? = nil
    var isOpenInWindow: Bool = false
    var wpm: Double = 200
    var isEditMode: Bool = false
    var isEditSelected: Bool = false
    /// The book's cloud state, shown and spoken after the New or Now Reading
    /// badge (FR02). Nil when the library is not in a cloud location, or the
    /// book has not been checked yet: the row then looks and reads as it
    /// always has. The list passes what `BookCloudStates` recorded, so a row
    /// never asks the file system anything.
    var cloudState: BookCloudState? = nil
    /// Whether the row says the book is kept on this Mac (Keep on This Mac):
    /// "Kept on this Mac", shown and spoken after the cloud note. The list
    /// passes true only for a kept book in a cloud library.
    var isKeptOnThisMac: Bool = false
    /// The book's transcription note (FR05): "Transcribed" or
    /// "Transcribing", shown and spoken after the cloud notes; nil for none.
    var transcriptionNote: TranscriptionRowNote? = nil
    /// Whether the row says its book is in the reading list (FR09): "In
    /// reading list", spoken in the row's label right after its title and
    /// author, so scrolling through many rows finds it in the same place
    /// every time. The list passes true only outside the Reading List,
    /// where every row's book is in the list.
    var isInReadingList: Bool = false
    /// Move Up and Move Down, offered while the list shows an order the
    /// user arranges, a folder's manual order or the reading list (FR09):
    /// the row's first VoiceOver actions, under the names its context menu
    /// gives them. Nil, offering neither, anywhere else.
    var manualMoves: LibraryManualMoves? = nil
    /// Runs one of `manualMoves`' moves.
    var performManualMove: (LibraryManualMove) -> Void = { _ in }
    /// The cloud commands of the row's context menu, which are also the
    /// row's VoiceOver actions (VO-Command-Space), under the same names
    /// (FR02).
    var cloudCommands: [LibraryCloudCommand] = []
    /// Runs one of `cloudCommands`.
    var performCloudCommand: (LibraryCloudCommand) -> Void = { _ in }
    /// The audio commands of the row's context menu, Edit Audio… (FR04) and
    /// the transcription commands (FR05), which are also its VoiceOver
    /// actions, after the cloud commands, under the same names.
    var audioCommands: [LibraryAudioCommand] = []
    /// Runs one of `audioCommands`.
    var performAudioCommand: (LibraryAudioCommand) -> Void = { _ in }
    /// The commands of the feed item the book was downloaded from, in its
    /// feed's folder (FR03), which follow the cloud commands as VoiceOver
    /// actions; none for any other book.
    var feedActions: [FeedItemAction] = []
    /// Runs one of `feedActions`.
    var performFeedAction: (FeedItemAction) -> Void = { _ in }
    /// Add to Reading List or Remove from Reading List, by membership, or
    /// both for a selection holding books of each kind (FR09): the row's
    /// last VoiceOver actions, under the names its context menu gives them.
    var readingListCommands: [ReadingListCommand] = []
    /// Runs one of `readingListCommands`.
    var performReadingListCommand: (ReadingListCommand) -> Void = { _ in }
    /// The book's live position while a reader plays it (TODO PERF11). The
    /// row observes this one entry, so it redraws when its own book's
    /// reader moves and no other row does. The inert entry, the default,
    /// holds none.
    @ObservedObject var livePosition: LiveReadingPosition = .inert

    /// The book as the row shows its progress and time left: with its
    /// reader's live position while that is newer than the library's.
    private var shownBook: Book {
        livePosition.applied(to: book)
    }

    /// The title the row shows and speaks: `shownTitle`, or the book's own.
    private var title: String {
        shownTitle ?? book.title
    }

    var body: some View {
        let _ = ViewBodyCounter.record("BookRow")
        HStack(spacing: 8) {
            // Selection indicator in edit mode
            if isEditMode {
                Image(systemName: isEditSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isEditSelected ? .accentColor : .secondary)
                    .font(.title3)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title)
                        .font(.headline)

                    if book.isUnopened {
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

                    // "Downloaded", "In Cloud", and so on, in a cloud library.
                    if let cloudState {
                        BookCloudNote(state: cloudState)
                    }

                    // "Kept on this Mac", after the cloud note.
                    if isKeptOnThisMac {
                        BookKeptNote()
                    }

                    // "Transcribed" or "Transcribing", after the cloud notes (FR05).
                    if let transcriptionNote {
                        RowNoteBadge(symbolName: transcriptionNote.symbolName, text: transcriptionNote.text)
                    }
                }
                HStack {
                    Text(book.author)
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Spacer()

                    if let progress = Self.progressText(for: shownBook) {
                        Text(progress.visible)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let remaining = Self.timeRemaining(for: shownBook, wpm: wpm) {
                        Text(Self.remainingText(remaining).visible)
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
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(rowAccessibilityLabel)
        .accessibilityHint(Self.accessibilityHint(isEditMode: isEditMode, isEditSelected: isEditSelected))
        .accessibilityAddTraits(isEditSelected ? [.isSelected] : [])
        .accessibilityActions {
            // First, so reordering a list takes the fewest keys (FR09).
            ForEach(manualMoves?.offered ?? []) { move in
                Button(move.title) { performManualMove(move) }
            }
            ForEach(cloudCommands) { command in
                Button(command.title) { performCloudCommand(command) }
            }
            ForEach(audioCommands) { command in
                Button(command.title) { performAudioCommand(command) }
            }
            ForEach(feedActions) { action in
                Button(action.title) { performFeedAction(action) }
            }
            ForEach(readingListCommands) { command in
                Button(command.title) { performReadingListCommand(command) }
            }
        }
    }

    /// What VoiceOver says the row's default action does: in edit mode it
    /// selects the book, or deselects it, and otherwise it opens the book
    /// (`LibraryBookListRow`). The hint says the result, never a gesture or
    /// a key, since VoiceOver, a braille display, and the keyboard each do
    /// it their own way (TODO A10; it said "Double-tap to select" and "Press
    /// Enter to open, Command I for info").
    nonisolated static func accessibilityHint(isEditMode: Bool, isEditSelected: Bool) -> String {
        guard isEditMode else { return "Opens the book." }
        return isEditSelected ? "Deselects this book." : "Selects this book."
    }

    /// The names of the row's own VoiceOver actions, in the order VoiceOver
    /// lists them.
    var accessibilityActionNames: [String] {
        // One list of each kind's names, joined: a chain of `+` is more
        // than the type checker can take in reasonable time.
        let names: [[String]] = [
            (manualMoves?.offered ?? []).map(\.title),
            cloudCommands.map(\.title),
            audioCommands.map(\.title),
            feedActions.map(\.title),
            readingListCommands.map(\.title),
        ]
        return names.flatMap { $0 }
    }

    /// Spoken label for the whole row, replacing its combined children: it
    /// begins with the title as the row shows it, so VoiceOver and a braille
    /// display read what the row shows.
    var rowAccessibilityLabel: String {
        var parts: [String] = []
        if isEditMode && isEditSelected {
            parts.append("Selected")
        }
        parts.append(title)
        parts.append("by \(book.author)")
        // Right after the title and author, so a book in the reading list
        // says so in the same place on every row (FR09).
        if isInReadingList {
            parts.append(ReadingListWording.inReadingListNote)
        }
        if book.isUnopened {
            parts.append("New")
        } else if isOpenInWindow {
            parts.append("Now Reading")
        }
        if let cloudNote = cloudState?.spokenNote {
            parts.append(cloudNote)
        }
        if isKeptOnThisMac {
            parts.append(KeptOnThisMacNote.text)
        }
        if let transcriptionNote {
            parts.append(transcriptionNote.text)
        }
        let besideDownloadPercentage = cloudState?.speaksPercentage ?? false
        if let progress = Self.spokenProgress(for: shownBook, besideDownloadPercentage: besideDownloadPercentage) {
            parts.append(progress)
        }
        if let remaining = Self.timeRemaining(for: shownBook, wpm: wpm) {
            parts.append(Self.remainingText(remaining).spoken)
        }
        parts.append(book.format.displayName)
        return parts.joined(separator: ", ")
    }

    // The row's words, apart from the view, so a feed item's row (FR11,
    // `FeedKeptProgress`) and the tests say them as this row does, from any
    // thread.

    /// Progress shown in a library row — visible "42%", spoken "42 percent" —
    /// or nil to hide it when it cannot be known without parsing the book.
    /// Whole percents are rounded the same way Where Am I speaks them. A
    /// book resting at its end, finished, says so in a word, shown and
    /// spoken alike: "Finished" (`EndOfBookWording.finishedProgress`, TODO
    /// P07), in place of "100%".
    nonisolated static func progressText(for book: Book) -> (visible: String, spoken: String)? {
        if book.restsAtEnd {
            return (visible: EndOfBookWording.finishedProgress, spoken: EndOfBookWording.finishedProgress)
        }
        guard let percent = book.percentComplete else { return nil }
        let wholePercent = String(format: "%.0f", percent)
        return (visible: "\(wholePercent)%", spoken: "\(wholePercent) percent")
    }

    /// The reading progress as the row's label speaks it: "42 percent", or
    /// "42 percent read" when the label also speaks a download's percentage
    /// (FR02), so it never holds two bare percentages. "Finished" is no
    /// percentage, and is spoken as it is beside one. Nil when the row shows
    /// no progress.
    nonisolated static func spokenProgress(for book: Book, besideDownloadPercentage: Bool) -> String? {
        guard let progress = progressText(for: book) else { return nil }
        return besideDownloadPercentage && !book.restsAtEnd ? "\(progress.spoken) read" : progress.spoken
    }

    /// The time left after the reading position that the row shows and
    /// speaks: the book's estimate at `wpm` (`Book.estimatedTimeRemaining(wpm:)`),
    /// or nil when it is unknown, and for a book resting at its end, whose
    /// "Finished" says it all where "0:00 left" once stood (TODO P07). Speak
    /// Info says what the row says.
    nonisolated static func timeRemaining(for book: Book, wpm: Double) -> TimeInterval? {
        book.restsAtEnd ? nil : book.estimatedTimeRemaining(wpm: wpm)
    }

    /// The time left after the reading position as a library row shows
    /// it, "16:00 left", and speaks it, "16 minutes remaining": a book's
    /// row, and a feed item's row for the place kept after its file went
    /// (FR11, `FeedKeptProgress`).
    nonisolated static func remainingText(_ remaining: TimeInterval) -> (visible: String, spoken: String) {
        (visible: "\(TimeFormatting.format(remaining)) left", spoken: LibraryInfoWording.remaining(remaining))
    }
}

// MARK: - Library List Row

/// One of a book row's two moves through an order the user arranges, a
/// folder's manual order or the reading list: Move Up or Move Down, under
/// the one name its context menu item and its VoiceOver action both give
/// it.
struct LibraryManualMove: Identifiable, Equatable {
    /// Move Up: one place toward the top of the order.
    static let up = LibraryManualMove(title: "Move Up", direction: -1)
    /// Move Down: one place toward the bottom of the order.
    static let down = LibraryManualMove(title: "Move Down", direction: 1)

    /// The move's name in the row's context menu and its VoiceOver actions.
    let title: String
    /// The move's step through the order: -1 up, +1 down.
    let direction: Int

    /// A row offers each move at most once, so its step identifies it.
    var id: Int { direction }
}

/// Whether a book can move up, and whether it can move down, in the manual
/// order the list shows (TODO A06), read from the list's own order rather
/// than by sorting the folder again for every row (PERF28).
struct LibraryManualMoves: Equatable {
    /// Whether Move Up is offered: the book is not first.
    let canMoveUp: Bool
    /// Whether Move Down is offered: the book is not last.
    let canMoveDown: Bool

    /// Whether either move is offered, so the menu shows them apart.
    var canMove: Bool {
        canMoveUp || canMoveDown
    }

    /// The moves offered, Move Up before Move Down: the row's context menu
    /// items and its first VoiceOver actions alike (FR09), so a VoiceOver
    /// user reorders from the row without the menu or a drag.
    var offered: [LibraryManualMove] {
        (canMoveUp ? [.up] : []) + (canMoveDown ? [.down] : [])
    }

    /// Each book's moves in `ordered`, a folder's books in their manual
    /// order as the list shows it, by ID: every book but the first can move
    /// up, and every book but the last can move down, as
    /// `ManualBookOrder.canMove` decides. A book listed twice keeps its
    /// first place, as it does there.
    static func moves(in ordered: [Book]) -> [UUID: LibraryManualMoves] {
        var moves: [UUID: LibraryManualMoves] = [:]
        moves.reserveCapacity(ordered.count)
        for (index, book) in ordered.enumerated() where moves[book.id] == nil {
            moves[book.id] = LibraryManualMoves(
                canMoveUp: index > 0,
                canMoveDown: index < ordered.count - 1
            )
        }
        return moves
    }
}

/// What a library row's commands do, supplied by the list. Each closure acts
/// on the list's state as it is when the command runs, so rows never compare
/// them (PERF28).
struct LibraryBookRowActions {
    /// Opens a book in its reader.
    let open: (Book) -> Void
    /// Shows a book's Book Info.
    let showInfo: (Book) -> Void
    /// Enters edit mode with a book selected.
    let select: (Book) -> Void
    /// Selects or deselects a book in edit mode.
    let toggleSelection: (Book) -> Void
    /// Asks where to move books, and moves them there.
    let moveToFolder: ([Book]) -> Void
    /// Moves a book one place up (-1) or down (+1) in the order the list
    /// shows, a folder's manual order or the reading list, from the row's
    /// context menu, saying which book it passed.
    let moveInManualOrder: (Book, Int) -> Void
    /// Moves a book one place up (-1) or down (+1) in that order from the
    /// row's Move Up or Move Down VoiceOver action, saying the book's new
    /// place, "Dune, 3 of 12" (FR09). Doing nothing unless the list
    /// supplies it.
    var moveSayingPlace: (Book, Int) -> Void = { _, _ in }
    /// Runs a cloud command (FR02).
    let performCloudCommand: (LibraryCloudCommand) -> Void
    /// Removes books, as the removal preferences say.
    let remove: ([Book]) -> Void
    /// Opens the Export dialog for books (FR05). Doing nothing unless the
    /// list supplies it, so rows made only to be compared need not.
    var export: ([Book]) -> Void = { _ in }
    /// Opens a book's text in the user's own editor, or, when the flag is
    /// true, in an app they choose (FR05). Doing nothing unless the list
    /// supplies it.
    var editText: (Book, _ choosingApp: Bool) -> Void = { _, _ in }
    /// Opens an audiobook's manifest in the user's own editor, or, when the
    /// flag is true, in an app they choose (FR17). Doing nothing unless the
    /// list supplies it.
    var editManifest: (Book, _ choosingApp: Bool) -> Void = { _, _ in }
    /// Runs an audio command: Edit Audio… (FR04) or a transcription command
    /// (FR05). Doing nothing unless the list supplies it.
    var performAudioCommand: (LibraryAudioCommand) -> Void = { _ in }
    /// Runs a command of the feed item a book was downloaded from (FR03).
    /// Doing nothing unless the list supplies it.
    var performFeedAction: (FeedItemAction) -> Void = { _ in }
    /// Runs Add to Reading List or Remove from Reading List (FR09). Doing
    /// nothing unless the list supplies it.
    var performReadingListCommand: (ReadingListCommand) -> Void = { _ in }
}

/// One book's row in the library list: the row, its context menu, its
/// default action, and its cloud commands (FR02) and audio commands (Edit
/// Audio…, FR04, and transcription's, FR05) as VoiceOver actions, which
/// act on the same books.
///
/// Equatable on everything it shows (PERF28). When a change to the library
/// draws the list again, SwiftUI skips every row the change left as it was,
/// so one changed book redraws one row; and SwiftUI builds a row's context
/// menu each time the row draws, which now happens only when the row has
/// something new to show. The comparison lives here, not in `BookRow`,
/// which observes its live position: what a row observes cannot be read by
/// a comparison, which runs outside the main actor.
struct LibraryBookListRow: View, Equatable {
    /// The row's book.
    let book: Book
    /// The title the row shows and speaks in place of the book's own while
    /// the Leading articles setting has titles shown with their articles
    /// after them ("Hobbit, The"); nil shows the title as written.
    var shownTitle: String? = nil
    /// Whether a reader window has the book open.
    let isOpenInWindow: Bool
    /// The speed the time left is figured at.
    let wpm: Double
    /// Whether the list is in edit mode.
    let isEditMode: Bool
    /// Whether the book is selected in edit mode.
    let isEditSelected: Bool
    /// The book's cloud state, when the library is in a cloud location
    /// (FR02).
    let cloudState: BookCloudState?
    /// Whether the row says the book is kept on this Mac (Keep on This Mac).
    let isKeptOnThisMac: Bool
    /// The books the commands act on: the selection, in list order, when
    /// the row belongs to a selection of several books; otherwise the row's
    /// own book.
    let targets: [Book]
    /// The cloud commands for `targets` (FR02).
    let cloudCommands: [LibraryCloudCommand]
    /// Move Up and Move Down, offered for the row's own book while the list
    /// shows an order the user arranges, its folder's manual order or the
    /// reading list: context menu items and VoiceOver actions alike (FR09);
    /// nil otherwise.
    let manualMoves: LibraryManualMoves?
    /// Whether removing asks first and where deleted files go, so Remove
    /// says what it will do.
    let removalPreferences: RemovalPreferences
    /// The book's live position while a reader plays it (TODO PERF11): one
    /// object for the book all session, compared by identity. `BookRow`
    /// observes it, so its changes redraw the row's progress alone.
    let livePosition: LiveReadingPosition
    /// The audio commands for `targets`, Edit Audio… (FR04) and the
    /// transcription commands (FR05): context menu items and VoiceOver
    /// actions alike.
    var audioCommands: [LibraryAudioCommand] = []
    /// The book's transcription note, "Transcribed" or "Transcribing"
    /// (FR05), or nil for none.
    var transcriptionNote: TranscriptionRowNote? = nil
    /// Whether the book is an audiobook whose audio is a folder of tracks,
    /// whose manifest Edit Manifest can open (FR17, `TrackFolderBooks`).
    var isTrackFolder = false
    /// The commands of the feed item the book was downloaded from, in its
    /// feed's folder (FR03); none for any other book.
    var feedActions: [FeedItemAction] = []
    /// Whether the row says its book is in the reading list (FR09); true
    /// only outside the Reading List.
    var isInReadingList: Bool = false
    /// Add to Reading List and Remove from Reading List for `targets`
    /// (FR09): context menu items and VoiceOver actions alike.
    var readingListCommands: [ReadingListCommand] = []
    /// What the commands do. Never compared.
    let actions: LibraryBookRowActions

    /// Whether two rows show the same thing: every input but `actions`.
    nonisolated static func == (lhs: LibraryBookListRow, rhs: LibraryBookListRow) -> Bool {
        lhs.book == rhs.book
            && lhs.shownTitle == rhs.shownTitle
            && lhs.isOpenInWindow == rhs.isOpenInWindow
            && lhs.wpm == rhs.wpm
            && lhs.isEditMode == rhs.isEditMode
            && lhs.isEditSelected == rhs.isEditSelected
            && lhs.cloudState == rhs.cloudState
            && lhs.isKeptOnThisMac == rhs.isKeptOnThisMac
            && lhs.targets == rhs.targets
            && lhs.cloudCommands == rhs.cloudCommands
            && lhs.manualMoves == rhs.manualMoves
            && lhs.removalPreferences == rhs.removalPreferences
            && lhs.livePosition === rhs.livePosition
            && lhs.audioCommands == rhs.audioCommands
            && lhs.transcriptionNote == rhs.transcriptionNote
            && lhs.isTrackFolder == rhs.isTrackFolder
            && lhs.feedActions == rhs.feedActions
            && lhs.isInReadingList == rhs.isInReadingList
            && lhs.readingListCommands == rhs.readingListCommands
    }

    var body: some View {
        let _ = ViewBodyCounter.record("LibraryBookListRow")
        BookRow(
            book: book,
            shownTitle: shownTitle,
            isOpenInWindow: isOpenInWindow,
            wpm: wpm,
            isEditMode: isEditMode,
            isEditSelected: isEditSelected,
            cloudState: cloudState,
            isKeptOnThisMac: isKeptOnThisMac,
            transcriptionNote: transcriptionNote,
            isInReadingList: isInReadingList,
            manualMoves: manualMoves,
            performManualMove: { move in actions.moveSayingPlace(book, move.direction) },
            cloudCommands: cloudCommands,
            performCloudCommand: actions.performCloudCommand,
            audioCommands: audioCommands,
            performAudioCommand: actions.performAudioCommand,
            feedActions: feedActions,
            performFeedAction: actions.performFeedAction,
            readingListCommands: readingListCommands,
            performReadingListCommand: actions.performReadingListCommand,
            livePosition: livePosition
        )
        .accessibilityAction(.default) {
            if isEditMode {
                actions.toggleSelection(book)
            } else {
                actions.open(book)
            }
        }
        .contextMenu {
            menu
        }
    }

    /// The row's context menu. Its commands act on `targets`: the selection
    /// when the row belongs to one, otherwise the row's book. The cloud
    /// commands (FR02) and the audio commands (FR04, FR05) are also the
    /// row's VoiceOver actions.
    @ViewBuilder
    private var menu: some View {
        let isMulti = targets.count > 1

        if !isMulti {
            Button("Open") {
                actions.open(book)
            }
            Button("Book Info") {
                actions.showInfo(book)
            }
        }
        if !isEditMode {
            Button("Select") {
                actions.select(book)
            }
        }
        // Not for feed items alone, which stay in their feeds' folders
        // (FR11); a mixed selection's move says which items it left.
        if let moveTitle = LibraryTransitionWording.moveToFolderTitle(for: targets) {
            Button(moveTitle) {
                actions.moveToFolder(targets)
            }
        }
        // Add to Reading List or Remove from Reading List, by membership,
        // also VoiceOver actions (FR09).
        ForEach(readingListCommands) { command in
            Button(command.title) {
                actions.performReadingListCommand(command)
            }
        }
        // The Export dialog for the row's book or the selection (FR05).
        Button(BookExportWording.commandTitle(count: targets.count)) {
            actions.export(targets)
        }
        // A text book's text, or a transcribed audiobook's, in the user's
        // own editor (FR05).
        if !isMulti && BookTextEditor.canEditText(of: book, isTranscribed: transcriptionNote == .transcribed) {
            Button(BookTextEditWording.editTitle) {
                actions.editText(book, false)
            }
            Button(BookTextEditWording.editWithTitle) {
                actions.editText(book, true)
            }
        }
        // An audiobook of tracks' manifest in the user's own editor (FR17).
        if !isMulti && BookManifestEditing.canEditManifest(of: book, isTrackFolder: isTrackFolder) {
            Button(BookManifestEditWording.editTitle) {
                actions.editManifest(book, false)
            }
            Button(BookManifestEditWording.editWithTitle) {
                actions.editManifest(book, true)
            }
        }
        // Edit Audio… (FR04) and Transcribe Audio… for an audiobook, and Clean Up
        // Transcript (Experimental)… and Delete Transcript… for a transcribed one
        // (FR05), also VoiceOver actions.
        ForEach(audioCommands) { command in
            Button(command.title) {
                actions.performAudioCommand(command)
            }
        }
        // Move Up and Move Down: single book only, where the list shows an
        // order the user arranges, a folder's manual order (TODO A06) or
        // the reading list (FR09); also the row's first VoiceOver actions.
        if let manualMoves, manualMoves.canMove {
            Divider()
            ForEach(manualMoves.offered) { move in
                Button(move.title) {
                    actions.moveInManualOrder(book, move.direction)
                }
            }
        }
        // Download Now and Remove Download in a cloud library, and Show in
        // Finder in every library (FR02).
        if !cloudCommands.isEmpty {
            Divider()
            ForEach(cloudCommands) { command in
                Button(command.title) {
                    actions.performCloudCommand(command)
                }
            }
        }
        // The commands of the feed item the book was downloaded from, in
        // its feed's folder (FR03).
        if !feedActions.isEmpty {
            Divider()
            ForEach(feedActions) { action in
                Button(action.title, role: action.role) {
                    actions.performFeedAction(action)
                }
            }
        }
        // Says what removal will do: ask first, or move the files to the
        // Trash, or delete them; for feed items alone, Delete Download.
        // One feed item's own Delete Download above stands for it, so the
        // menu offers no command twice (REV11 F2).
        if LibraryRemoveCommandWording.isOfferedOnRow(for: targets, feedActions: feedActions) {
            Divider()
            Button(
                LibraryRemoveCommandWording(
                    preferences: removalPreferences,
                    books: targets
                ).menuTitle,
                role: .destructive
            ) {
                actions.remove(targets)
            }
        }
    }
}

// MARK: - Tree-Order Folder Sorting

extension Array where Element == BookFolder {
    /// Sort folders in tree order: each parent is immediately followed by its children,
    /// then the next sibling. Siblings are sorted alphabetically.
    /// This prevents unrelated folders like "Misc SciFi anthologies" from appearing
    /// between "Misc SciFi" and "Misc SciFi/Sub" in picker lists.
    func sortedTreeOrder() -> [BookFolder] {
        // Sort so that a folder's children appear immediately after it,
        // before any unrelated folder that shares a prefix (e.g. "Misc SciFi"
        // children before "Misc SciFi anthologies").
        //
        // Replace "/" with "\0" for comparison so path separators sort before
        // any printable character (space is 0x20, "/" is 0x2F — both after "\0").
        // This ensures "Misc SciFi\0Sub" < "Misc SciFi anthologies".
        sorted {
            let a = $0.fullPath.lowercased().replacingOccurrences(of: "/", with: "\0")
            let b = $1.fullPath.lowercased().replacingOccurrences(of: "/", with: "\0")
            return a < b
        }
    }
}

// MARK: - Removal Preferences

extension View {
    /// Keeps `preferences` equal to the removal preferences in config.json,
    /// so removal buttons and confirmations always describe what removing
    /// will really do, even right after the preferences change in Settings.
    /// Only a change to one of the two preferences updates it, so other
    /// settings changes cause no redraw. Every view subscribes to the one
    /// shared model, so a view that draws again keeps its subscription.
    @MainActor
    func trackingRemovalPreferences(_ preferences: Binding<RemovalPreferences>) -> some View {
        onReceive(RemovalPreferencesModel.shared.$preferences) { current in
            preferences.wrappedValue = current
        }
    }
}
