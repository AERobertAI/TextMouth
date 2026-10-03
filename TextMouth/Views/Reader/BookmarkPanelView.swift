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
    /// The list's rows, in list order, each naming the heading that locates
    /// its bookmark. Rebuilt only when the bookmarks or the headings change,
    /// so the many other updates that redraw the panel (a keystroke in the
    /// note field, the reading position moving during playback) neither
    /// re-sort the bookmarks nor look up their headings again.
    @State private var rows: [BookmarkRow] = []
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
            rebuildRows()
            guard let firstBookmark = sortedBookmarks.first else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                focusedBookmarkID = firstBookmark.id
            }
        }
        .onChange(of: viewModel.bookmarks) { _, _ in
            rebuildRows()
        }
        .onChange(of: viewModel.headings) { _, _ in
            rebuildRows()
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
                    // Keep every row alive while the panel is open, as the
                    // headings panel does. LazyVStack recycles rows out of
                    // view, which can invalidate VoiceOver's current element
                    // and leaves those rows unable to take focus.
                    VStack(alignment: .leading, spacing: 0) {
                        // Identified by bookmark, so a row keeps its identity,
                        // and with it focus, when the list changes around it.
                        ForEach(rows, id: \.bookmark.id) { row in
                            bookmarkRowView(row)
                            Divider()
                        }
                    }
                }
                .accessibilityRotor("Bookmarks") {
                    // Rotor entries speak exactly what the rows say.
                    ForEach(rows, id: \.bookmark.id) { row in
                        AccessibilityRotorEntry(row.bookmarkAccessibilityLabel, id: row.bookmark.id)
                    }
                }
            }
        }
    }

    // MARK: - Rows

    /// One bookmark's row: a button that goes to the bookmark, with Edit Note
    /// and Delete buttons beside it.
    ///
    /// Every row's button can take keyboard focus (with keyboard navigation
    /// on, as for any button), and Space or Return on it goes to the
    /// bookmark. For VoiceOver the row is a container named after its
    /// bookmark, holding the three buttons as separate controls. The row and
    /// its main button both offer all three commands as VoiceOver actions,
    /// so they are at hand wherever the VoiceOver cursor is in the row.
    /// Pointer users find them in the row's context menu as well.
    private func bookmarkRowView(_ row: BookmarkRow) -> some View {
        let bookmark = row.bookmark
        return HStack(spacing: 8) {
            Button {
                perform(.goTo, on: bookmark)
            } label: {
                row
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focusedBookmarkID, equals: bookmark.id)
            // A focused button presses on Space by itself. Return, which
            // would otherwise look for a default button, goes to the
            // bookmark too; a held key does not repeat the navigation.
            .onKeyPress(keys: [.return], phases: .down) { _ in
                perform(.goTo, on: bookmark)
                return .handled
            }
            .accessibilityLabel(row.bookmarkAccessibilityLabel)
            .accessibilityHint(row.accessibilityHintText)
            .accessibilityActions { commandActions(for: bookmark) }
            .modifier(InitialVoiceOverFocusModifier(
                isTarget: bookmark.id == rows.first?.bookmark.id,
                delay: 1.2
            ))

            ForEach(BookmarkCommand.rowButtons, id: \.self) { command in
                commandButton(command, for: bookmark)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .accessibilityLabel(command.buttonLabel(forBookmarkNumber: bookmark.number))
                    .help(command.title)
            }
        }
        .padding(.horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(row.bookmarkAccessibilityLabel)
        .accessibilityActions { commandActions(for: bookmark) }
        .contextMenu {
            ForEach(BookmarkCommand.allCases, id: \.self) { command in
                commandButton(command, for: bookmark)
            }
        }
    }

    /// A button that runs `command` on `bookmark`, named and pictured as the
    /// command: beside a row and in its context menu.
    private func commandButton(_ command: BookmarkCommand, for bookmark: Bookmark) -> some View {
        Button(role: command.role) {
            perform(command, on: bookmark)
        } label: {
            Label(command.title, systemImage: command.systemImage)
        }
    }

    /// The commands on `bookmark` as VoiceOver actions, each under its name.
    private func commandActions(for bookmark: Bookmark) -> some View {
        ForEach(BookmarkCommand.allCases, id: \.self) { command in
            Button(command.title) {
                perform(command, on: bookmark)
            }
        }
    }

    /// Carry out `command` on `bookmark`, whichever control asked for it:
    /// the row, a button beside it, a VoiceOver action, or the context menu.
    private func perform(_ command: BookmarkCommand, on bookmark: Bookmark) {
        switch command {
        case .goTo:
            viewModel.navigateToBookmark(bookmark)
            dismiss()
        case .editNote:
            noteText = bookmark.label
            mode = .edit(bookmark)
        case .delete:
            viewModel.removeBookmark(bookmark)
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

    /// Rebuild the list's rows from the reader's bookmarks, in list order.
    private func rebuildRows() {
        rows = Self.listOrder(of: viewModel.bookmarks).map(bookmarkRow(for:))
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

// MARK: - Bookmark commands

/// A command on one bookmark. Every row offers each command three ways,
/// always under the same name: as a button (Go To is the row itself; Edit
/// Note and Delete sit beside it), as a VoiceOver action, and in the row's
/// context menu.
enum BookmarkCommand: CaseIterable {
    case goTo
    case editNote
    case delete

    /// The commands drawn as buttons beside each row. Go To needs none: the
    /// row itself is its button.
    static let rowButtons: [BookmarkCommand] = [.editNote, .delete]

    /// The command's name: its VoiceOver action and its context menu item.
    var title: String {
        switch self {
        case .goTo: return "Go To"
        case .editNote: return "Edit Note"
        case .delete: return "Delete"
        }
    }

    /// The SF Symbol drawn for the command, on its button beside a row and
    /// in the context menu.
    var systemImage: String {
        switch self {
        case .goTo: return "arrow.forward"
        case .editNote: return "pencil"
        case .delete: return "trash"
        }
    }

    /// Delete removes the bookmark for good, so its button and menu item are
    /// marked destructive.
    var role: ButtonRole? {
        self == .delete ? .destructive : nil
    }

    /// What VoiceOver calls a button running the command on bookmark
    /// `number`. Each names its bookmark, so it makes sense on its own: "Go
    /// to bookmark 3", "Edit note for bookmark 3", "Delete bookmark 3". The
    /// panel names the buttons beside a row this way; the row's own button
    /// speaks its bookmark's full label instead.
    func buttonLabel(forBookmarkNumber number: Int) -> String {
        switch self {
        case .goTo: return "Go to bookmark \(number)"
        case .editNote: return "Edit note for bookmark \(number)"
        case .delete: return "Delete bookmark \(number)"
        }
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
