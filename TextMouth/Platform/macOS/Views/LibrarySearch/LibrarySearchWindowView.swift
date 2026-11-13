import SwiftUI

/// What the Search Library window shows (LIBRARY-SEARCH-RESEARCH-2026-11-13.md,
/// section 6): a search field, the Match Case and Regular Expression
/// checkboxes, a status line VoiceOver reads in place and hears once when a
/// search ends, and the results, grouped by book.
///
/// The results are a list, as the Library's books are: each book's heading
/// over its matches, every match a row that speaks its context, where it
/// is, and its book's title, so a row heard alone still names its book. A
/// match opens with Return or a double-click (the list's primary action),
/// and with VoiceOver's default action; a book with more matches than the
/// list shows ends with a row that lists the rest. The Books rotor moves
/// from book to book, the Matches rotor from match to match. Escape closes
/// the window, whose results stay for the next time it opens.
struct LibrarySearchWindowView: View {
    /// The searches and their results, kept by the app while the window is
    /// closed.
    @ObservedObject var model: LibrarySearchModel
    /// Closes the window.
    let close: () -> Void

    /// Whether the search field has the keyboard.
    @FocusState private var isFieldFocused: Bool
    /// Whether the results have the keyboard.
    @FocusState private var areResultsFocused: Bool
    /// The row selected in the results: a match's row or a book's Show All
    /// row, by its ID.
    @State private var selection: String?

    /// The ID of a book's Show All row.
    static func showAllRowID(_ bookID: UUID) -> String {
        "show-all:\(bookID.uuidString)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(LibrarySearchWording.fieldPrompt, text: $model.query)
                .textFieldStyle(.roundedBorder)
                .focused($isFieldFocused)
                .accessibilityLabel(LibrarySearchWording.fieldLabel)
                .accessibilityHint(LibrarySearchWording.fieldHint)
                .accessibilityIdentifier(voiceOverFocusID)
                .background(VoiceOverFocus(delay: 1.2))
                // Return takes the keyboard to the first result, ready for
                // the arrows and Return to open it.
                .onSubmit(selectFirstResult)

            // Plain text right after the field, which VoiceOver reads in
            // place; each finished search also announces it once.
            Text(model.status.text)
                .font(.callout)
                .foregroundColor(model.status.isError ? .red : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Toggle(BookSearchWording.matchCaseLabel, isOn: $model.matchCase)
                    .checkboxToggleStyle()
                    .accessibilityLabel(BookSearchWording.matchCaseLabel)
                    .accessibilityHint(BookSearchWording.matchCaseHint)
                Toggle(LibrarySearchWording.regexLabel, isOn: $model.useRegex)
                    .checkboxToggleStyle()
                    .accessibilityLabel(LibrarySearchWording.regexLabel)
                    .accessibilityHint(LibrarySearchWording.regexHint)
                Spacer()
                // Escape, as Search in Book's Back to Book has it.
                Button(LibrarySearchWording.closeButton, action: close)
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityHint(LibrarySearchWording.closeHint)
            }

            // While a search runs: how far it has got, and a way to stop it,
            // below the checkboxes, so nothing above moves when it shows.
            if case .searching(let tally) = model.status, tally.booksGiven > 0 {
                HStack {
                    ProgressView(value: Double(tally.booksDone), total: Double(tally.booksGiven))
                        .accessibilityLabel(LibrarySearchWording.progressLabel)
                    Button(LibrarySearchWording.stopButton) { model.stopSearch() }
                        .keyboardShortcut(".", modifiers: .command)
                        .accessibilityHint(LibrarySearchWording.stopHint)
                }
            }

            Divider()

            results
        }
        .padding()
        .frame(minWidth: 520, idealWidth: 640, minHeight: 360, idealHeight: 520)
        .onAppear {
            // The field takes the keyboard each time the window opens, its
            // last query still in it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isFieldFocused = true
            }
        }
    }

    // MARK: The Results

    /// The list of results, grouped by book, or nothing while there are
    /// none: the status line says why. Built from parts of its own, so the
    /// compiler type-checks each apart (as `ReaderView`'s body is built).
    @ViewBuilder
    private var results: some View {
        let sections = model.sections
        if sections.isEmpty {
            Spacer()
        } else {
            LibrarySearchResultsList(
                model: model,
                sections: sections,
                selection: $selection,
                isFocused: $areResultsFocused
            )
        }
    }

    /// Selects the first match and gives the results the keyboard, after
    /// Return in the search field; nothing while there are no results.
    private func selectFirstResult() {
        guard let first = model.sections.first(where: { !$0.rows.isEmpty })?.rows.first else { return }
        selection = first.id
        areResultsFocused = true
    }
}

/// The results: each book's section in a list with one selection, whose
/// Return and double-click open the selected match or list a book's rest,
/// with the Books and Matches rotors.
private struct LibrarySearchResultsList: View {
    /// The searches, which a row's action opens or lists more of.
    @ObservedObject var model: LibrarySearchModel
    /// What the list shows.
    let sections: [LibrarySearchSection]
    /// The selected row's ID.
    @Binding var selection: String?
    /// Whether the list has the keyboard.
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        List(selection: $selection) {
            ForEach(sections) { section in
                LibrarySearchSectionView(model: model, section: section)
            }
        }
        .focused(isFocused)
        .contextMenu(forSelectionType: String.self, menu: menu(for:), primaryAction: activate)
        .accessibilityLabel(LibrarySearchWording.resultsLabel)
        .modifier(LibrarySearchRotors(sections: sections))
    }

    /// The context menu of the selected rows: Open for a match.
    @ViewBuilder
    private func menu(for ids: Set<String>) -> some View {
        if let id = ids.first, let row = LibrarySearchWindowView.matchRow(id, in: sections) {
            Button(LibrarySearchWording.matchHint) { model.open(row) }
        }
    }

    /// What Return or a double-click on the selected row does: opens a
    /// match, or lists all of a book's matches.
    private func activate(_ ids: Set<String>) {
        guard let id = ids.first else { return }
        if let row = LibrarySearchWindowView.matchRow(id, in: sections) {
            model.open(row)
        } else if let section = sections.first(where: { LibrarySearchWindowView.showAllRowID($0.id) == id }) {
            model.showAllMatches(in: section.id)
        }
    }
}

/// One book's part of the results: its heading, its matches, and the row
/// after them.
private struct LibrarySearchSectionView: View {
    /// The searches, which a row's action opens or lists more of.
    @ObservedObject var model: LibrarySearchModel
    /// The book's part.
    let section: LibrarySearchSection

    var body: some View {
        Section {
            ForEach(section.rows) { row in
                LibrarySearchMatchRowView(row: row)
                    .tag(row.id)
                    .accessibilityAction(.default) { model.open(row) }
            }
            moreRow
        } header: {
            Text(section.group.heading)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// The row after the book's matches: Show All while the list shows
    /// fewer than the book holds, or a note once even Show All lists fewer.
    @ViewBuilder
    private var moreRow: some View {
        switch section.more {
        case .nothing:
            EmptyView()
        case .showAll:
            Text(section.moreLabel)
                .foregroundColor(.accentColor)
                .tag(LibrarySearchWindowView.showAllRowID(section.id))
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(LibrarySearchWording.showAllHint)
                .accessibilityAction(.default) { model.showAllMatches(in: section.id) }
        case .beyondShowAll:
            Text(section.moreLabel)
                .foregroundColor(.secondary)
        }
    }
}

/// The results' rotors: Books, moving to each book's first row, and Matches,
/// moving to each match listed, each entry its row's words.
private struct LibrarySearchRotors: ViewModifier {
    /// What the list shows.
    let sections: [LibrarySearchSection]

    /// One rotor entry: its words and the row it moves to.
    private struct Entry: Identifiable {
        let id: String
        let label: String
    }

    /// Each book's entry: its heading, at its first match, or at its Show
    /// All row when it lists no match.
    private var books: [Entry] {
        sections.compactMap { section in
            if let first = section.rows.first {
                return Entry(id: first.id, label: section.group.heading)
            }
            guard section.more == .showAll else { return nil }
            return Entry(id: LibrarySearchWindowView.showAllRowID(section.id), label: section.group.heading)
        }
    }

    /// Each match's entry, as its row speaks it.
    private var matches: [Entry] {
        sections.flatMap { section in
            section.rows.map { Entry(id: $0.id, label: $0.spokenLabel) }
        }
    }

    func body(content: Content) -> some View {
        content
            .accessibilityRotor(LibrarySearchWording.booksRotor) {
                ForEach(books) { entry in
                    AccessibilityRotorEntry(entry.label, id: entry.id)
                }
            }
            .accessibilityRotor(LibrarySearchWording.matchesRotor) {
                ForEach(matches) { entry in
                    AccessibilityRotorEntry(entry.label, id: entry.id)
                }
            }
    }
}

extension LibrarySearchWindowView {
    /// The match row `id` names, if it names one.
    static func matchRow(_ id: String, in sections: [LibrarySearchSection]) -> LibrarySearchMatchRow? {
        for section in sections {
            if let row = section.rows.first(where: { $0.id == id }) { return row }
        }
        return nil
    }
}

/// One match's row: the match in its context, and where it is, shown, and
/// spoken with the book's title.
struct LibrarySearchMatchRowView: View {
    /// The row's match.
    let row: LibrarySearchMatchRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.match.contextSnippet)
                .lineLimit(2)
            if let location = row.match.locationTitle {
                Text(location)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.spokenLabel)
        .accessibilityHint(LibrarySearchWording.matchHint)
    }
}
