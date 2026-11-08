import SwiftUI

/// The phone's Bookmarks sheet (the iPhone interface spec, "The Bookmarks
/// sheet"): the title, Done, Add Bookmark, then the bookmarks in the order
/// they lie in the book, with focus landing on the one nearest before the
/// place, each with Edit Note and Delete.
///
/// Thin over `PhoneBookmarksModel`, which orders the rows, names them in the
/// Mac's words, and decides where focus goes; the changes are the reader's
/// own. The reader isn't observed: the rows are built when the sheet opens
/// and again after each change the listener makes.
struct PhoneBookmarksSheet: View {
    /// The reader whose bookmarks the sheet lists.
    let reader: ReaderViewModel
    /// What the sheet leaves to say once it has closed.
    let farewell: PhoneSheetFarewell
    /// Tells the session the book was moved here, so it counts as opened
    /// (`PhoneReaderModel.noteJumped`).
    let noteJumped: @MainActor () -> Void

    /// The rows, in book order.
    @State private var model: PhoneBookmarksModel
    /// The place being read as the sheet opened, for its first focus.
    @State private var openedAt: PhoneBookmarkPlace
    /// The Add or Edit sheet open over this one, if any.
    @State private var noteSheet: NoteSheet?
    /// The bookmark whose removal is being asked about, if any.
    @State private var removing: Bookmark?
    /// What the Add or Edit sheet leaves to say once it has closed.
    @State private var noteFarewell = PhoneSheetFarewell()
    /// Where focus goes once the Add or Edit sheet has closed.
    @State private var focusAfterNoteSheet: Focus?
    /// Where VoiceOver's focus is asked to go.
    @AccessibilityFocusState private var focus: Focus?
    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss

    /// A sheet over `reader`, farewell words kept in `farewell`.
    init(reader: ReaderViewModel, farewell: PhoneSheetFarewell, noteJumped: @escaping @MainActor () -> Void) {
        self.reader = reader
        self.farewell = farewell
        self.noteJumped = noteJumped
        _model = State(initialValue: PhoneBookmarksModel(reader: reader))
        _openedAt = State(initialValue: PhoneBookmarkPlace(readingIn: reader))
    }

    /// What VoiceOver's focus can be asked to land on.
    enum Focus: Hashable, Sendable {
        /// The Add Bookmark button.
        case addButton
        /// A bookmark's row.
        case bookmark(UUID)

        /// The focus the Mac's rule names.
        init(_ target: BookmarkPanelFocusTarget) {
            switch target {
            case .bookmark(let id): self = .bookmark(id)
            case .addButton: self = .addButton
            }
        }
    }

    /// The sheet open over this one: Add Bookmark, at the place taken as it
    /// opened, or Edit Note for a bookmark.
    enum NoteSheet: Identifiable {
        /// Add Bookmark, at `place`.
        case add(PhoneBookmarkPlace)
        /// Edit Note for `bookmark`.
        case edit(Bookmark)

        /// The sheet itself, for `sheet(item:)`.
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let bookmark): return "edit-\(bookmark.id)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    if model.isEmpty {
                        emptyList
                    } else {
                        ForEach(model.rows) { row in
                            bookmarkRow(row)
                                .id(Focus.bookmark(row.id))
                        }
                    }
                }
                .task {
                    // The bookmark nearest before the place, or, in an empty
                    // list, Add Bookmark, as on the Mac.
                    switch Focus(model.openingFocus(at: openedAt)) {
                    case .bookmark(let id):
                        PhoneListFocus.focus(Focus.bookmark(id), proxy: proxy, state: $focus)
                    case .addButton:
                        moveFocus(to: .addButton)
                    }
                }
                .sheet(item: $noteSheet, onDismiss: { afterNoteSheet(proxy: proxy) }) { sheet in
                    noteSheetView(sheet)
                }
            }
            .navigationTitle(PhoneBookmarksVocabulary.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // In this order, so VoiceOver reads the title, then Done, then
                // Add Bookmark.
                PhoneSheetButton(title: PhoneBookmarksVocabulary.done) { dismiss() }
                ToolbarItem(placement: PhoneSheetButtonPlacement.placement) {
                    Button {
                        // The place is taken now, not at Add.
                        noteSheet = .add(PhoneBookmarkPlace(readingIn: reader))
                    } label: {
                        Label(PhoneBookmarksVocabulary.addBookmark, systemImage: "plus")
                    }
                    .accessibilityLabel(PhoneBookmarksVocabulary.addBookmarkLabel)
                    .accessibilityFocused($focus, equals: .addButton)
                }
            }
            .alert(
                removeQuestionTitle,
                isPresented: isAskingToRemove,
                presenting: removing
            ) { bookmark in
                Button(PhoneReaderWording.remove, role: .destructive) { delete(bookmark) }
                Button(PhoneAppWording.cancel, role: .cancel) {}
            } message: { bookmark in
                Text(bookmark.label)
            }
        }
    }

    // MARK: The removal question

    /// The removal question's title, or "" while no bookmark is being removed.
    /// Held apart from `body` so the compiler type-checks each piece alone.
    private var removeQuestionTitle: String {
        guard let bookmark = removing else { return "" }
        return PhoneBookmarksWording.removeQuestion(number: bookmark.number)
    }

    /// Whether the removal question shows: while a bookmark is being removed,
    /// and cleared when the question is answered or dismissed.
    private var isAskingToRemove: Binding<Bool> {
        Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
    }

    // MARK: The list

    /// The Mac's words for an empty list, read as one element.
    private var emptyList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(PhoneBookmarksVocabulary.empty)
            Text(PhoneBookmarksWording.emptyHelp)
                .phoneSecondaryText()
        }
        .accessibilityElement(children: .combine)
    }

    /// One bookmark's row: a button that goes to it, read by the Mac's
    /// label, with Edit Note and Delete as actions, and a context menu of
    /// the same for touch.
    private func bookmarkRow(_ row: PhoneBookmarksRow) -> some View {
        Button {
            go(to: row.bookmark)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.shownTitle).phonePrimaryText()
                if let heading = row.headingText {
                    Text(heading).phoneSecondaryText()
                }
                if !row.bookmark.label.isEmpty {
                    Text(row.bookmark.label).italic().phonePrimaryText()
                }
                Text(row.bookmark.dateText).phoneSecondaryText()
            }
        }
        .accessibilityLabel(row.label)
        .accessibilityHint(PhoneBookmarksVocabulary.rowHint)
        .accessibilityAction(named: BookmarkCommand.editNote.title) { noteSheet = .edit(row.bookmark) }
        .accessibilityAction(named: BookmarkCommand.delete.title) { askToDelete(row.bookmark) }
        .contextMenu {
            Button(BookmarkCommand.editNote.title) { noteSheet = .edit(row.bookmark) }
            Button(BookmarkCommand.delete.title, role: .destructive) { askToDelete(row.bookmark) }
        }
        .accessibilityFocused($focus, equals: .bookmark(row.id))
    }

    // MARK: What the rows do

    /// Goes to `bookmark`, keeping the Return place, as the Mac's sheet
    /// does, and closes the sheet; the Mac's "Bookmark 3" is said once it
    /// has closed, with anything else the jump said.
    private func go(to bookmark: Bookmark) {
        let said = VoiceOverAnnouncer.collectingAnnouncements {
            reader.navigateToBookmark(bookmark)
        }
        farewell.keep([PhoneBookmarksWording.jumpAnnouncement(to: bookmark)] + said.map(\.message))
        noteJumped()
        dismiss()
    }

    /// Deletes `bookmark` at once, or asks first when it has a note.
    private func askToDelete(_ bookmark: Bookmark) {
        if PhoneBookmarksModel.asksBeforeRemoving(bookmark) {
            removing = bookmark
        } else {
            delete(bookmark)
        }
    }

    /// Deletes `bookmark`, and moves focus by the Mac's rule: to the row
    /// after it, else the row before, else Add Bookmark.
    private func delete(_ bookmark: Bookmark) {
        // Decided first, while the list still holds the bookmark's neighbors.
        let target = Focus(model.focus(after: .delete(bookmark.id)))
        reader.removeBookmark(bookmark)
        model = PhoneBookmarksModel(reader: reader)
        moveFocus(to: target)
    }

    /// Asks VoiceOver's focus to land on `target` a moment from now, once
    /// the list has redrawn.
    private func moveFocus(to target: Focus) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(PhoneFocusPolicy.screenChangedDelay))
            focus = nil
            await Task.yield()
            focus = target
        }
    }

    // MARK: Add Bookmark and Edit Note

    /// The Add or Edit sheet.
    @ViewBuilder
    private func noteSheetView(_ sheet: NoteSheet) -> some View {
        switch sheet {
        case .add(let place):
            PhoneBookmarkNoteSheet(
                title: PhoneBookmarksVocabulary.addBookmark,
                field: PhoneBookmarksVocabulary.addNoteField,
                hint: PhoneBookmarksVocabulary.addNoteHint,
                startingNote: "",
                doneTitle: PhoneBookmarksVocabulary.add,
                onCancel: { focusAfterNoteSheet = Focus(model.focus(after: .cancelAdd)) },
                onDone: { note in add(note: note, at: place) }
            )
        case .edit(let bookmark):
            PhoneBookmarkNoteSheet(
                title: PhoneBookmarksVocabulary.editTitle(number: bookmark.number),
                field: PhoneBookmarksVocabulary.editNoteField,
                hint: nil,
                startingNote: bookmark.label,
                doneTitle: PhoneAppWording.save,
                onCancel: { focusAfterNoteSheet = Focus(model.focus(after: .edit(bookmark.id))) },
                onDone: { note in save(note: note, for: bookmark) }
            )
        }
    }

    /// Adds a bookmark with `note` at `place`, the place taken as Add opened,
    /// and has focus go to it, with the Mac's "Bookmark 3 added" said once
    /// the Add sheet has closed.
    private func add(note: String, at place: PhoneBookmarkPlace) {
        var added: Bookmark?
        let said = VoiceOverAnnouncer.collectingAnnouncements {
            added = reader.addBookmark(at: place, note: note)
        }
        noteFarewell.keep(said.map(\.message))
        model = PhoneBookmarksModel(reader: reader)
        focusAfterNoteSheet = Focus(model.focus(after: .add(added?.id)))
    }

    /// Saves `note` as `bookmark`'s note, and has focus go back to it.
    private func save(note: String, for bookmark: Bookmark) {
        reader.updateBookmarkLabel(bookmark, label: note)
        model = PhoneBookmarksModel(reader: reader)
        focusAfterNoteSheet = Focus(model.focus(after: .edit(bookmark.id)))
    }

    /// The Add or Edit sheet has closed: focus goes where it said, and its
    /// words are said after.
    private func afterNoteSheet(proxy: ScrollViewProxy) {
        let target = focusAfterNoteSheet
        focusAfterNoteSheet = nil
        if let target {
            if case .bookmark = target {
                PhoneListFocus.focus(target, proxy: proxy, state: $focus)
            } else {
                moveFocus(to: target)
            }
        }
        noteFarewell.sheetDidClose()
    }
}

/// The Add Bookmark and Edit Note sheets: a title, one note field, where
/// focus lands, then Cancel and the button that keeps the note, in the order
/// the spec gives.
private struct PhoneBookmarkNoteSheet: View {
    /// The sheet's title, read as its heading.
    let title: String
    /// The field's visible word.
    let field: String
    /// The field's hint, if it has one.
    let hint: String?
    /// What the field starts with.
    let startingNote: String
    /// The button that keeps the note: Add, or Save.
    let doneTitle: String
    /// Runs as Cancel closes the sheet.
    let onCancel: () -> Void
    /// Runs with the note as the done button closes the sheet.
    let onDone: (String) -> Void

    /// What the field holds.
    @State private var note = ""
    /// Whether the field holds the keyboard.
    @FocusState private var fieldHasKeyboard: Bool
    /// Whether VoiceOver's focus is asked into the field.
    @AccessibilityFocusState private var fieldHasVoiceOver: Bool
    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField(field, text: $note)
                    .submitLabel(.done)
                    .onSubmit(finish)
                    .focused($fieldHasKeyboard)
                    .accessibilityFocused($fieldHasVoiceOver)
                    .accessibilityLabel(PhoneBookmarksVocabulary.noteLabel)
                    .accessibilityHint(hint ?? "")
                Button(PhoneAppWording.cancel) {
                    onCancel()
                    dismiss()
                }
                Button(doneTitle, action: finish)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .task {
                note = startingNote
                // A sheet with one field: focus lands in it, a moment after
                // the sheet appears.
                try? await Task.sleep(for: .seconds(PhoneFocusPolicy.screenChangedDelay))
                fieldHasKeyboard = true
                fieldHasVoiceOver = true
            }
        }
    }

    /// Keeps the note and closes the sheet.
    private func finish() {
        onDone(note)
        dismiss()
    }
}
