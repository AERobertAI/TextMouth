import SwiftUI

/// Tracks which sub-view the bookmark panel is showing.
/// Using inline modes instead of nested sheets avoids a macOS SwiftUI bug
/// where dismissing a sheet-on-sheet breaks the outer sheet's responder
/// chain, trapping keyboard focus and making escape / Cmd+W unresponsive.
enum BookmarkPanelMode: Equatable {
    case list
    case add
    case edit(Bookmark)
}

/// A control in the bookmarks list that can take keyboard focus and the
/// VoiceOver cursor.
enum BookmarkPanelFocusTarget: Hashable {
    /// The row of the bookmark with this identifier.
    case bookmark(UUID)
    /// The Add Bookmark button, for when no bookmark is left to focus.
    case addButton
}

/// Something that just happened in the bookmarks panel. Each one decides
/// where focus goes next; see `BookmarkPanelView.focusTarget(after:in:)`.
enum BookmarkPanelOperation: Equatable {
    /// The panel opened with the reader at this position.
    case open(chapterIndex: Int, characterOffset: Int)
    /// An Add finished, adding the bookmark with this identifier, or nil
    /// when the reader added none.
    case add(UUID?)
    /// An Add was cancelled.
    case cancelAdd
    /// An edit of the note of the bookmark with this identifier was saved
    /// or cancelled.
    case edit(UUID)
    /// The bookmark with this identifier was deleted.
    case delete(UUID)
}

struct BookmarkPanelView: View {
    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var mode: BookmarkPanelMode = .list
    @State private var noteText = ""
    @FocusState private var focusedBookmarkID: UUID?
    @FocusState private var noteFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            switch mode {
            case .list:
                listContent
            case .add:
                addContent
            case .edit(let bookmark):
                editContent(bookmark)
            }
        }
        .frame(width: 380, height: 400)
        .navigationTitle(viewModel.book.title)
        .onAppear {
            guard let firstBookmark = sortedBookmarks.first else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                focusedBookmarkID = firstBookmark.id
            }
        }
    }

    // MARK: - List Mode

    private var listContent: some View {
        Group {
            // Header bar
            HStack {
                Text("Bookmarks")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()

                Button {
                    noteText = ""
                    mode = .add
                } label: {
                    Label("Add Bookmark", systemImage: "plus")
                }
                .accessibilityLabel("Add bookmark at current position")
                .modifier(EmptyBookmarksFocusModifier(isEmpty: viewModel.bookmarks.isEmpty))

                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            .padding()

            Divider()

            if viewModel.bookmarks.isEmpty {
                // Empty state — grouped into a single VoiceOver element
                VStack(spacing: 8) {
                    Text("No bookmarks yet.")
                        .foregroundColor(.secondary)
                    Text("Press Cmd+B to add a bookmark at the current position.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .accessibilityElement(children: .combine)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(sortedBookmarks.enumerated()), id: \.element.id) { index, bookmark in
                            let row = bookmarkRow(for: bookmark)

                            Button {
                                viewModel.navigateToBookmark(bookmark)
                                dismiss()
                            } label: {
                                row
                                    .padding(.horizontal)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                                .buttonStyle(.plain)
                                .focusable(index == 0)
                                .focused($focusedBookmarkID, equals: index == 0 ? bookmark.id : nil)
                                .accessibilityLabel(row.bookmarkAccessibilityLabel)
                                .accessibilityHint(row.accessibilityHintText)
                                .modifier(InitialVoiceOverFocusModifier(
                                    isTarget: index == 0,
                                    delay: 1.2
                                ))
                                .contextMenu {
                                    Button("Go To") {
                                        viewModel.navigateToBookmark(bookmark)
                                        dismiss()
                                    }
                                    Button("Edit Note") {
                                        noteText = bookmark.label
                                        mode = .edit(bookmark)
                                    }
                                    Button("Delete", role: .destructive) {
                                        viewModel.removeBookmark(bookmark)
                                    }
                                }
                            Divider()
                        }
                    }
                }
                .accessibilityRotor("Bookmarks") {
                    // Rotor entries speak exactly what the rows say.
                    ForEach(sortedBookmarks) { bookmark in
                        AccessibilityRotorEntry(
                            bookmarkRow(for: bookmark).bookmarkAccessibilityLabel,
                            id: bookmark.id
                        )
                    }
                }
            }
        }
    }

    // MARK: - Add Bookmark (Inline)

    private var addContent: some View {
        VStack(spacing: 16) {
            Text("Add Bookmark")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            TextField("Note (optional)", text: $noteText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Bookmark note")
                .accessibilityHint("Optional note to describe this bookmark")
                .focused($noteFieldFocused)

            HStack {
                Button("Cancel") {
                    noteText = ""
                    mode = .list
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Add") {
                    viewModel.addBookmarkAtCurrentPosition(label: noteText)
                    noteText = ""
                    mode = .list
                }
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding()
        .onAppear {
            noteFieldFocused = true
        }
    }

    // MARK: - Edit Bookmark (Inline)

    private func editContent(_ bookmark: Bookmark) -> some View {
        VStack(spacing: 16) {
            Text("Edit Bookmark \(bookmark.number)")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            TextField("Note", text: $noteText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Bookmark note")
                .focused($noteFieldFocused)

            HStack {
                Button("Cancel") {
                    mode = .list
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Save") {
                    viewModel.updateBookmarkLabel(bookmark, label: noteText)
                    mode = .list
                }
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding()
        .onAppear {
            noteFieldFocused = true
        }
    }
}

extension BookmarkPanelView {
    var sortedBookmarks: [Bookmark] {
        Self.listOrder(of: viewModel.bookmarks)
    }

    /// Row for `bookmark`, located by the heading that contains it. Both the
    /// list and the Bookmarks rotor build rows here so they always agree.
    func bookmarkRow(for bookmark: Bookmark) -> BookmarkRow {
        BookmarkRow(bookmark: bookmark, headingText: viewModel.headingText(forBookmark: bookmark))
    }
}

// MARK: - Where focus goes

extension BookmarkPanelView {
    /// The bookmarks in the order the panel lists them: by number, which is
    /// the order they were added in.
    nonisolated static func listOrder(of bookmarks: [Bookmark]) -> [Bookmark] {
        bookmarks.sorted { $0.number < $1.number }
    }

    /// Where keyboard focus and the VoiceOver cursor go after `operation`.
    ///
    /// - Opening: the bookmark nearest the reading position
    ///   (`nearestBookmark(toChapter:offset:in:)`).
    /// - Add: the new bookmark. Cancelling an Add, or an Add that added
    ///   nothing, returns to the Add button.
    /// - Saving or cancelling an edit: the edited bookmark.
    /// - Delete: the bookmark listed after the deleted one, else the one
    ///   before it.
    ///
    /// When the bookmark chosen is not listed (it went while its note was
    /// being edited, say), focus goes to the first bookmark listed, and
    /// whenever no bookmark is left, to the Add button.
    ///
    /// - Parameter listed: The bookmarks in list order: for a delete, as
    ///   listed just before it; otherwise, as listed now.
    nonisolated static func focusTarget(
        after operation: BookmarkPanelOperation,
        in listed: [Bookmark]
    ) -> BookmarkPanelFocusTarget {
        /// Whether `id` names a listed bookmark.
        func isListed(_ id: UUID) -> Bool {
            listed.contains { $0.id == id }
        }

        switch operation {
        case let .open(chapterIndex, characterOffset):
            let nearest = nearestBookmark(toChapter: chapterIndex, offset: characterOffset, in: listed)
            return nearest.map { .bookmark($0.id) } ?? .addButton
        case .add(let id):
            guard let id, isListed(id) else { return .addButton }
            return .bookmark(id)
        case .cancelAdd:
            return .addButton
        case .edit(let id):
            return isListed(id) ? .bookmark(id) : firstBookmarkOrAddButton(in: listed)
        case .delete(let id):
            guard isListed(id) else { return firstBookmarkOrAddButton(in: listed) }
            let survivor = neighbor(of: id, offset: 1, in: listed) ?? neighbor(of: id, offset: -1, in: listed)
            return survivor.map { .bookmark($0.id) } ?? .addButton
        }
    }

    /// The bookmark nearest a reading position, found as the headings panel
    /// finds the current heading: the last bookmark at or before the
    /// position in the book. When every bookmark lies beyond the position,
    /// the first one after it. Of bookmarks at the same place, the one listed
    /// first is chosen. Nil only when no bookmark is listed.
    nonisolated static func nearestBookmark(
        toChapter chapterIndex: Int,
        offset characterOffset: Int,
        in listed: [Bookmark]
    ) -> Bookmark? {
        let position = (chapterIndex, characterOffset)
        var latestBehind: Bookmark?
        var earliestAhead: Bookmark?
        // Only a strictly better place replaces a choice, so of two
        // bookmarks at one place the one listed first stays chosen.
        for bookmark in listed {
            let place = location(of: bookmark)
            if place <= position {
                if latestBehind.map({ location(of: $0) < place }) ?? true {
                    latestBehind = bookmark
                }
            } else if earliestAhead.map({ place < location(of: $0) }) ?? true {
                earliestAhead = bookmark
            }
        }
        return latestBehind ?? earliestAhead
    }

    /// The bookmark listed `offset` places from the one with `id`: -1 for the
    /// one before it, 1 for the one after it. Nil past either end of the
    /// list, and for a bookmark that is not listed.
    nonisolated static func neighbor(of id: UUID, offset: Int, in listed: [Bookmark]) -> Bookmark? {
        guard let index = listed.firstIndex(where: { $0.id == id }) else { return nil }
        let neighborIndex = index + offset
        return listed.indices.contains(neighborIndex) ? listed[neighborIndex] : nil
    }

    /// Where `bookmark` lies in the book: its content unit, then its
    /// character offset within that unit, ordered as positions are read.
    private nonisolated static func location(of bookmark: Bookmark) -> (Int, Int) {
        (bookmark.chapterIndex, bookmark.characterOffset)
    }

    /// The first bookmark listed, or the Add button when none is.
    private nonisolated static func firstBookmarkOrAddButton(in listed: [Bookmark]) -> BookmarkPanelFocusTarget {
        listed.first.map { .bookmark($0.id) } ?? .addButton
    }
}

struct BookmarkRow: View {
    let bookmark: Bookmark
    /// Text of the heading containing the bookmark, shown under its number
    /// and spoken in its label; nil leaves the location out.
    let headingText: String?

    var body: some View {
        HStack {
            Image(systemName: "bookmark.fill")
                .foregroundColor(.orange)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Bookmark \(bookmark.number)")
                    .font(.headline)

                if let headingText {
                    Text(headingText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if !bookmark.label.isEmpty {
                    Text(bookmark.label)
                        .font(.caption)
                        .foregroundColor(.primary)
                        .italic()
                }
            }

            Spacer()

            Text(bookmark.dateCreated, style: .date)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    var accessibilityHintText: String {
        "Double-tap to navigate to this bookmark"
    }

    /// Spoken label shared with the Bookmarks rotor.
    var bookmarkAccessibilityLabel: String {
        bookmark.accessibilityLabel(headingText: headingText)
    }
}

private struct EmptyBookmarksFocusModifier: ViewModifier {
    let isEmpty: Bool

    func body(content: Content) -> some View {
        if isEmpty {
            content
                .accessibilityIdentifier(voiceOverFocusID)
                .background(VoiceOverFocus(delay: 1.2))
        } else {
            content
        }
    }
}
