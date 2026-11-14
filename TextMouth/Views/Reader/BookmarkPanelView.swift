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

/// The bookmarks panel: the book's bookmarks in the order they were added,
/// each of which can be gone to, have its note edited, or be deleted, and a
/// way to add a bookmark at the reading position.
///
/// Everything works from the keyboard, with VoiceOver, and from a braille
/// display: every row is a button with its own Edit Note and Delete buttons,
/// offers all three commands as VoiceOver actions, and can be reached with
/// Tab or the Up and Down Arrow keys.
///
/// Focus follows the work. On opening, it goes to the bookmark nearest the
/// reading position; after an Add, to the new bookmark; after an edit, back
/// to the edited bookmark; after a delete, to the next bookmark, else the
/// previous one, else the Add button. Keyboard focus and the VoiceOver
/// cursor move together, and nothing extra is announced: the focused row's
/// own label says where focus is.
struct BookmarkPanelView: View {
    /// What the panel shows of its reader: the book's title, its bookmarks,
    /// and its headings, which name where each bookmark is (PERF30). The
    /// panel draws again when these change, and only then, rather than with
    /// each of the reader's publishes, about one a second while it plays. Its
    /// body reads the reader itself, whose values these are by the time it
    /// draws.
    struct ReaderState: Equatable {
        let title: String
        let bookmarks: [Bookmark]
        let headings: [Heading]

        /// What `reader` shows the panel now.
        @MainActor
        init(of reader: ReaderViewModel) {
            title = reader.book.title
            bookmarks = reader.bookmarks
            headings = reader.headings
        }
    }

    /// The reader whose bookmarks the panel lists, goes to, and edits. Not
    /// observed: the panel follows `shown` instead (PERF30).
    let viewModel: ReaderViewModel
    /// What the panel shows of the reader, republished only when it changes.
    @StateObject private var shown: ReaderSnapshot<ReaderState>
    @Environment(\.dismiss) private var dismiss
    @State private var mode: BookmarkPanelMode = .list
    @State private var noteText = ""
    /// The list's rows, in list order, each naming the heading that locates
    /// its bookmark. Rebuilt only when the bookmarks or the headings change,
    /// so the many other updates that redraw the panel (a keystroke in the
    /// note field, the reading position moving during playback) neither
    /// re-sort the bookmarks nor look up their headings again.
    @State private var rows: [BookmarkRow] = []
    /// The latest request to move focus, made when the panel opens and after
    /// each add, edit, or delete; see `focusTarget(after:in:)`.
    @State private var focusRequest = BookmarkPanelFocusRequest()
    /// The list control with keyboard focus: a bookmark's row or the Add
    /// button.
    @FocusState private var focusedControl: BookmarkPanelFocusTarget?
    @FocusState private var noteFieldFocused: Bool

    /// A panel of `viewModel`'s bookmarks.
    init(viewModel: ReaderViewModel) {
        self.viewModel = viewModel
        _shown = StateObject(wrappedValue: ReaderSnapshot(of: viewModel, ReaderState.init(of:)))
    }

    var body: some View {
        let _ = ViewBodyCounter.record("BookmarkPanelView")
        ScrollViewReader { list in
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
                requestFocus(Self.openingFocusTarget(for: viewModel), voiceOverDelay: Self.openingVoiceOverDelay)
            }
            .onChange(of: shown.value.bookmarks) { _, _ in
                rebuildRows()
            }
            .onChange(of: shown.value.headings) { _, _ in
                rebuildRows()
            }
            // Keyboard focus follows each request once SwiftUI has drawn its
            // target: after an add or an edit the list itself comes back, and
            // on opening the sheet is still presenting. A newer request
            // cancels one still waiting, and none is applied once the user
            // has left the list to add or edit, where the note field has
            // focus. VoiceOver follows through the target's own
            // `RequestedVoiceOverFocus`, so the two land on the same control.
            // The list scrolls to the target even when keyboard focus cannot
            // go there (keyboard navigation off), so the new or nearest
            // bookmark is in view.
            .task(id: focusRequest) {
                guard let target = focusRequest.target else { return }
                try? await Task.sleep(for: Self.keyboardFocusDelay)
                guard !Task.isCancelled, mode == .list else { return }
                focusedControl = target
                scroll(list, toShow: target)
            }
            // Keep the row with keyboard focus in view as the user moves it.
            .onChange(of: focusedControl) { _, control in
                guard let control else { return }
                scroll(list, toShow: control)
            }
        }
    }

    /// Scroll the list just enough to show the row `target` names. The Add
    /// button, above the list, is always in view.
    private func scroll(_ list: ScrollViewProxy, toShow target: BookmarkPanelFocusTarget) {
        guard case .bookmark(let id) = target else { return }
        list.scrollTo(id)
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
                // Focus comes here when no bookmark is left to focus, and
                // back here when an Add is cancelled.
                .focused($focusedControl, equals: .addButton)
                .modifier(RequestedVoiceOverFocus(
                    isTarget: focusRequest.target == .addButton,
                    request: focusRequest
                ))

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
                    Text(Self.emptyListHelp(keys: Self.addBookmarkKeysInForce()))
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
    /// on, as for any button). Space or Return on it goes to the bookmark,
    /// Up and Down Arrow move to the rows above and below it, and Tab visits
    /// every control in turn. For VoiceOver the row is a container named
    /// after its bookmark, holding the three buttons as separate controls.
    /// The row and its main button both offer all three commands as
    /// VoiceOver actions, so they are at hand wherever the VoiceOver cursor
    /// is in the row. Pointer users find them in the row's context menu too.
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
            .focused($focusedControl, equals: .bookmark(bookmark.id))
            // A focused button presses on Space by itself. Return, which
            // would otherwise look for a default button, goes to the
            // bookmark too; a held key does not repeat the navigation.
            .onKeyPress(keys: [.return], phases: .down) { _ in
                perform(.goTo, on: bookmark)
                return .handled
            }
            // Up and Down Arrow move between rows, as in a list; holding one
            // keeps moving.
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                moveFocus(from: bookmark, by: press.key == .upArrow ? -1 : 1)
                return .handled
            }
            .accessibilityLabel(row.bookmarkAccessibilityLabel)
            .accessibilityHint(row.accessibilityHintText)
            .accessibilityActions { commandActions(for: bookmark) }
            .modifier(RequestedVoiceOverFocus(
                isTarget: focusRequest.target == .bookmark(bookmark.id),
                request: focusRequest
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
            requestFocus(Self.delete(bookmark, from: viewModel))
        }
    }

    /// Move keyboard focus `offset` rows from `bookmark`'s row: -1 to the row
    /// above, 1 to the row below. At either end of the list focus stays put,
    /// as in any list. VoiceOver, whose cursor follows keyboard focus unless
    /// the user turns that off, is not asked to move separately.
    private func moveFocus(from bookmark: Bookmark, by offset: Int) {
        guard let neighbor = Self.neighbor(of: bookmark.id, offset: offset, in: rows.map(\.bookmark)) else {
            return
        }
        focusedControl = .bookmark(neighbor.id)
    }

    /// Ask for keyboard focus and the VoiceOver cursor to move to `target`.
    /// VoiceOver moves after `voiceOverDelay`: by default the short delay
    /// for a panel already on screen; opening the panel passes a longer one.
    private func requestFocus(
        _ target: BookmarkPanelFocusTarget,
        voiceOverDelay: TimeInterval = Self.restoringVoiceOverDelay
    ) {
        focusRequest = BookmarkPanelFocusRequest(
            target: target,
            voiceOverDelay: voiceOverDelay,
            serial: focusRequest.serial + 1
        )
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
                    requestFocus(Self.focusTarget(after: .cancelAdd, in: viewModel))
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Add") {
                    let target = Self.add(note: noteText, to: viewModel)
                    noteText = ""
                    mode = .list
                    requestFocus(target)
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
                    requestFocus(Self.focusTarget(after: .edit(bookmark.id), in: viewModel))
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button("Save") {
                    let target = Self.saveNote(noteText, for: bookmark, in: viewModel)
                    mode = .list
                    requestFocus(target)
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

/// The bookmark panel's only input is its reader (PERF30).
extension BookmarkPanelView: SheetOverOneReader {}

extension BookmarkPanelView {
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

// MARK: - The Empty List

extension BookmarkPanelView {
    /// The help under "No bookmarks yet.": what adds one, by the keys in
    /// force for adding a bookmark, in words, which a braille display shows
    /// as words rather than as signs, as in "Command + B adds a bookmark at
    /// the current position."; or, while that command has no key, by the
    /// Add Bookmark button above. It used to say "Press Cmd+B", whatever the
    /// key was (TODO A10).
    nonisolated static func emptyListHelp(keys: [KeyBinding]) -> String {
        guard !keys.isEmpty else { return "Add Bookmark adds one at the current position." }
        return "\(KeyBinding.accessibleDisplayString(for: keys)) adds a bookmark at the current position."
    }

    /// The keys in force for adding a bookmark (the Bookmarks menu's Toggle
    /// Bookmark), as the app's preferences give them, which the shortcut
    /// manager keeps: read when the empty list draws, so a key changed in
    /// Settings is the one named.
    static func addBookmarkKeysInForce() -> [KeyBinding] {
        KeyboardShortcutManager.bindingsPreference.read(from: TextMouthRuntime.current.preferences)[.addBookmark] ?? []
    }
}

// MARK: - Operations

extension BookmarkPanelView {
    /// How long VoiceOver waits before moving into the panel when it opens:
    /// the sheet must finish presenting first.
    static let openingVoiceOverDelay: TimeInterval = 1.2

    /// How long VoiceOver waits before moving after an add, edit, or delete.
    /// The panel is already on screen, so this waits only for the redrawn
    /// rows, and is short so that VoiceOver moves before the user is likely
    /// to have moved on, rather than pulling them back afterwards.
    static let restoringVoiceOverDelay: TimeInterval = 0.3

    /// How long keyboard focus waits before moving to a requested control:
    /// time for SwiftUI to draw it, and on opening for the sheet to present.
    static let keyboardFocusDelay: Duration = .milliseconds(150)

    /// Where focus goes after `operation`, among the bookmarks `viewModel`
    /// holds now.
    static func focusTarget(
        after operation: BookmarkPanelOperation,
        in viewModel: ReaderViewModel
    ) -> BookmarkPanelFocusTarget {
        focusTarget(after: operation, in: listOrder(of: viewModel.bookmarks))
    }

    /// Where focus goes when the panel opens on `viewModel`: the bookmark
    /// nearest its reading position, or the Add button when it has none.
    static func openingFocusTarget(for viewModel: ReaderViewModel) -> BookmarkPanelFocusTarget {
        let opening = BookmarkPanelOperation.open(
            chapterIndex: viewModel.currentChapterIndex,
            characterOffset: viewModel.currentCharacterOffset
        )
        return focusTarget(after: opening, in: viewModel)
    }

    /// Add a bookmark with `note` at `viewModel`'s reading position, and
    /// return where focus goes: to the new bookmark.
    static func add(note: String, to viewModel: ReaderViewModel) -> BookmarkPanelFocusTarget {
        let added = viewModel.addBookmarkAtCurrentPosition(label: note)
        return focusTarget(after: .add(added?.id), in: viewModel)
    }

    /// Save `note` as `bookmark`'s note, and return where focus goes: back to
    /// that bookmark.
    static func saveNote(
        _ note: String,
        for bookmark: Bookmark,
        in viewModel: ReaderViewModel
    ) -> BookmarkPanelFocusTarget {
        viewModel.updateBookmarkLabel(bookmark, label: note)
        return focusTarget(after: .edit(bookmark.id), in: viewModel)
    }

    /// Delete `bookmark`, and return where focus goes: to the bookmark
    /// listed after it, else the one before it, else the Add button.
    static func delete(_ bookmark: Bookmark, from viewModel: ReaderViewModel) -> BookmarkPanelFocusTarget {
        // Decided first, while the list still shows the bookmark's neighbors.
        let target = focusTarget(after: .delete(bookmark.id), in: viewModel)
        viewModel.removeBookmark(bookmark)
        return target
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

            // The same words the row's label ends with (TODO A10).
            Text(bookmark.dateText)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    /// What VoiceOver says the row's button does: its result, never a
    /// gesture or a key, since VoiceOver, a braille display, and the
    /// keyboard each do it their own way (TODO A10; it said "Double-tap to
    /// navigate to this bookmark").
    var accessibilityHintText: String {
        "Goes to this bookmark and closes the list."
    }

    /// Spoken label shared with the Bookmarks rotor.
    var bookmarkAccessibilityLabel: String {
        bookmark.accessibilityLabel(headingText: headingText)
    }
}

// MARK: - Focus requests

/// A request to move keyboard focus and the VoiceOver cursor in the
/// bookmarks panel, made when it opens and after each add, edit, or delete.
private struct BookmarkPanelFocusRequest: Equatable {
    /// The control to focus; nil until the panel makes its first request.
    var target: BookmarkPanelFocusTarget?
    /// How long VoiceOver waits before moving to `target`.
    var voiceOverDelay: TimeInterval = 0
    /// Numbers the requests, so that asking again for the control already
    /// asked for is still a new request.
    var serial = 0
}

/// Points the panel's latest focus request at one control for VoiceOver.
///
/// `InitialVoiceOverFocusModifier` moves VoiceOver once, when its trigger
/// view first enters the window. So the control a request targets takes the
/// request's number as its identity, and a new request for the same control
/// (the row below a deleted one, when that row was already the target, say)
/// draws a fresh trigger that moves VoiceOver again. Every other control
/// keeps one identity throughout.
private struct RequestedVoiceOverFocus: ViewModifier {
    /// Whether this control is the request's target.
    let isTarget: Bool
    /// The panel's latest request.
    let request: BookmarkPanelFocusRequest

    func body(content: Content) -> some View {
        content
            .modifier(InitialVoiceOverFocusModifier(isTarget: isTarget, delay: request.voiceOverDelay))
            .id(isTarget ? request.serial : 0)
    }
}
