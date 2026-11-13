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

            // While a search runs: how far it has got, and a way to stop it.
            if case .searching(let tally) = model.status, tally.booksGiven > 0 {
                HStack {
                    ProgressView(value: Double(tally.booksDone), total: Double(tally.booksGiven))
                        .accessibilityLabel(LibrarySearchWording.progressLabel)
                    Button(LibrarySearchWording.stopButton) { model.stopSearch() }
                        .keyboardShortcut(".", modifiers: .command)
                        .accessibilityHint(LibrarySearchWording.stopHint)
                }
            }

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
                Button(LibrarySearchWording.closeButton, action: close)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint(LibrarySearchWording.closeHint)
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
    /// none: the status line says why.
    @ViewBuilder
    private var results: some View {
        let sections = model.sections
        if sections.isEmpty {
            Spacer()
        } else {
            List(selection: $selection) {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.rows) { row in
                            LibrarySearchMatchRowView(row: row)
                                .tag(row.id)
                                .accessibilityAction(.default) { model.open(row) }
                        }
                        moreRow(after: section)
                    } header: {
                        Text(section.group.heading)
                            .font(.headline)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
            .focused($areResultsFocused)
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let row = matchRow(id, in: sections) {
                    Button(LibrarySearchWording.matchHint) { model.open(row) }
                }
            } primaryAction: { ids in
                if let id = ids.first { activate(id, in: sections) }
            }
            .accessibilityLabel(LibrarySearchWording.resultsLabel)
            .accessibilityRotor(LibrarySearchWording.booksRotor) {
                ForEach(sections) { section in
                    if let first = section.rows.first {
                        AccessibilityRotorEntry(section.group.heading, id: first.id)
                    } else if section.more == .showAll {
                        AccessibilityRotorEntry(section.group.heading, id: Self.showAllRowID(section.id))
                    }
                }
            }
            .accessibilityRotor(LibrarySearchWording.matchesRotor) {
                ForEach(sections) { section in
                    ForEach(section.rows) { row in
                        AccessibilityRotorEntry(row.spokenLabel, id: row.id)
                    }
                }
            }
        }
    }

    /// The row after a book's matches: Show All while the list shows fewer
    /// than the book holds, or a note once even Show All lists fewer.
    @ViewBuilder
    private func moreRow(after section: LibrarySearchSection) -> some View {
        switch section.more {
        case .nothing:
            EmptyView()
        case .showAll:
            let title = LibrarySearchWording.showAll(
                matches: section.group.matchCount,
                isLowerBound: section.group.countReachedLimit,
                bookTitle: section.group.book.title
            )
            Text(title)
                .foregroundColor(.accentColor)
                .tag(Self.showAllRowID(section.id))
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(LibrarySearchWording.showAllHint)
                .accessibilityAction(.default) { model.showAllMatches(in: section.id) }
        case .beyondShowAll:
            Text(LibrarySearchWording.moreThanListed(section.rows.count))
                .foregroundColor(.secondary)
        }
    }

    /// The match row `id` names, if it names one.
    private func matchRow(_ id: String, in sections: [LibrarySearchSection]) -> LibrarySearchMatchRow? {
        for section in sections {
            if let row = section.rows.first(where: { $0.id == id }) { return row }
        }
        return nil
    }

    /// What Return or a double-click on the row `id` does: opens a match, or
    /// lists all of a book's matches.
    private func activate(_ id: String, in sections: [LibrarySearchSection]) {
        if let row = matchRow(id, in: sections) {
            model.open(row)
        } else if let section = sections.first(where: { Self.showAllRowID($0.id) == id }) {
            model.showAllMatches(in: section.id)
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
