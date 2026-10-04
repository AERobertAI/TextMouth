import SwiftUI

// MARK: - The Feeds Section (FR03)

/// The Feeds section of a Library window's list (FR03), after Folders and
/// before Books, shown only where there are feeds: a heading VoiceOver's
/// rotor finds, and a row for each feed that opens the feed's folder, as a
/// folder's row does, with the feed's commands in its context menu and as
/// its VoiceOver actions.
///
/// It observes the feed engine itself, so a download's progress or a
/// refresh redraws this section and nothing else of the list.
struct LibraryFeedsSection: View {
    /// The feed engine.
    @ObservedObject var center: FeedCenter
    /// Where the list is.
    let location: LibraryLocation
    /// Opens a feed's folder, or, when it is gone, says so.
    let open: (FeedRowContent) -> Void
    /// Runs a feed's command.
    let perform: (FeedAction) -> Void

    var body: some View {
        let _ = ViewBodyCounter.record("LibraryFeedsSection")
        let rows = LibraryFeedsSectionRows.rows(at: location, center: center)
        if !rows.isEmpty {
            Section {
                ForEach(rows) { row in
                    let actions = FeedAction.actions(for: row.id, noun: row.counts.noun)
                    Button {
                        open(row)
                    } label: {
                        FeedRow(content: row)
                            .equatable()
                    }
                    .buttonStyle(.plain)
                    .accessibilityAction(.default) {
                        open(row)
                    }
                    .accessibilityActions {
                        ForEach(actions) { action in
                            Button(action.title) { perform(action) }
                        }
                    }
                    .contextMenu {
                        ForEach(actions) { action in
                            Button(action.title, role: action.role) { perform(action) }
                        }
                    }
                }
            } header: {
                Text(FeedWording.feedsSectionTitle)
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }
}

/// One feed's row in the Feeds section (FR03): its title and the note
/// "Feed", its items counted, and its last check or why it failed, all
/// spoken as one sentence. Equatable on what it shows, so a change to
/// another feed leaves it as it was.
struct FeedRow: View, Equatable {
    /// What the row shows.
    let content: FeedRowContent

    var body: some View {
        let _ = ViewBodyCounter.record("FeedRow")
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.up.forward")
                .foregroundColor(.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(content.title)
                        .font(.headline)
                    FeedBadge(text: FeedWording.feedNote, color: .secondary)
                    if content.folderPath == nil {
                        FeedBadge(text: FeedWording.folderMissingNote, color: .red)
                    }
                }
                Text(content.countsText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(content.check.visible)
                    .font(.caption)
                    .foregroundColor(content.check.failed ? .red : .secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(content.label)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(FeedWording.feedRowHint)
    }
}

/// A short note beside a title, as the library's rows draw "New" and "Now
/// Reading": white words on a colored capsule. VoiceOver reads its row's
/// label instead, which says the same.
struct FeedBadge: View {
    /// The words.
    let text: String
    /// The capsule's color.
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color)
            .foregroundColor(.white)
            .cornerRadius(3)
            .accessibilityHidden(true)
    }
}

// MARK: - A Feed's Folder

/// What a feed's folder lists instead of its Books section (FR03): the
/// feed's items, newest first, under a heading counting them ("Episodes
/// (12)"), each downloaded one as its book's own row, unchanged but for the
/// item's commands beside the book's, and each other one as an item row
/// with its commands in its context menu and as its VoiceOver actions; then,
/// under "Books", the folder's books that came from no item of the feed.
///
/// It observes the feed engine itself, so a download's progress redraws
/// these rows and nothing else of the list.
struct FeedFolderSections<BookRowView: View>: View {
    /// The feed engine.
    @ObservedObject var center: FeedCenter
    /// The feed whose folder this is.
    let feedID: UUID
    /// The folder's books as the list shows them, narrowed by the search.
    let shownBooks: [Book]
    /// Every book of the folder.
    let folderBooks: [Book]
    /// The search narrowing the list.
    let search: String
    /// A book's row, as the library draws every book, with the commands of
    /// the item it came from, if any.
    let bookRow: (Book, [FeedItemAction]) -> BookRowView
    /// Runs an item's command.
    let perform: (FeedItemAction) -> Void

    var body: some View {
        let _ = ViewBodyCounter.record("FeedFolderSections")
        let listing = FeedFolderListing.make(
            feedID: feedID,
            center: center,
            shownBooks: shownBooks,
            folderBooks: folderBooks,
            search: search
        )
        Section {
            ForEach(listing.entries) { entry in
                switch entry {
                case .book(let book, let actions):
                    bookRow(book, actions)
                case .item(let content):
                    itemRow(content)
                }
            }
        } header: {
            Text(FeedWording.sectionTitle(listing.noun, count: listing.entries.count))
                .accessibilityAddTraits(.isHeader)
        }
        if !listing.otherBooks.isEmpty {
            Section {
                ForEach(listing.otherBooks) { book in
                    bookRow(book, [])
                }
            } header: {
                Text(FeedWording.otherBooksTitle(count: listing.otherBooks.count))
                    .accessibilityAddTraits(.isHeader)
            }
        }
    }

    /// An item's row, whose default action opens it, downloading it first,
    /// with its commands in its context menu and as its VoiceOver actions.
    private func itemRow(_ content: FeedItemRowContent) -> some View {
        let actions = FeedItemAction.actions(for: content)
        return FeedItemRow(content: content)
            .equatable()
            .accessibilityAction(.default) {
                if let open = actions.first(where: { $0.command == .open }) {
                    perform(open)
                }
            }
            .accessibilityActions {
                ForEach(actions) { action in
                    Button(action.title) { perform(action) }
                }
            }
            .contextMenu {
                ForEach(actions) { action in
                    if action.command == .deleteItem || action.command == .showDescription {
                        Divider()
                    }
                    Button(action.title, role: action.role) {
                        perform(action)
                    }
                }
            }
    }
}

/// One row of a feed's item that is not downloaded, or is downloaded into
/// another folder (FR03): its title with its notes (Played, its download's
/// state, New), then its date and its duration, all spoken as one sentence
/// with the most telling words first. Equatable on what it shows.
struct FeedItemRow: View, Equatable {
    /// What the row shows.
    let content: FeedItemRowContent

    var body: some View {
        let _ = ViewBodyCounter.record("FeedItemRow")
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(content.title)
                    .font(.headline)
                if content.isPlayed {
                    FeedBadge(text: FeedWording.playedNote(isArticle: content.isArticle), color: .secondary)
                }
                Text(content.state.visibleNote)
                    .font(.caption)
                    .foregroundColor(content.state.failureReason == nil ? .secondary : .red)
                if content.isNew {
                    FeedBadge(text: FeedWording.newNote, color: .blue)
                }
            }
            HStack(spacing: 8) {
                if let reason = content.state.failureReason, !reason.isEmpty {
                    Text(reason)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
                if let date = content.dateText {
                    Text(date)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let duration = content.duration {
                    Text(TimeFormatting.format(duration))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(content.label)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(FeedWording.itemRowHint(content.state))
    }
}

// MARK: - A Feed's Folder's Summary Bar

/// The library's summary bar, which in a feed's folder (FR03) counts the
/// feed's items and downloads and says its last check, beside the time
/// left in its downloads. It observes the feed engine, so the counts follow
/// each download while the list around it stays as it was. It holds the bar
/// in every folder, feed's or not, so moving between folders never makes
/// the bar anew, and never repeats the bar's VoiceOver focus request.
struct FeedFolderSummaryBar<Bar: View>: View {
    /// The feed engine.
    @ObservedObject var center: FeedCenter
    /// The feed whose folder the list shows, or nil.
    let feedID: UUID?
    /// The library's bar, given what to say of the feed, or nil outside a
    /// feed's folder.
    let bar: (FeedWording.FolderSummary?) -> Bar

    var body: some View {
        bar(feedID.map { center.folderSummary(of: $0, now: Date()) })
    }
}
