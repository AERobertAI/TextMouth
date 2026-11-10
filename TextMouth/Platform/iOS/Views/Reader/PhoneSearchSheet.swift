import SwiftUI

/// The phone's Search in Book sheet: the title, Back to Book, the search
/// field, what the search found so far, the regular-expression switch, then a
/// row for each result, in the Mac's words and over the Mac's search
/// (`BookSearchModel`, `BookSearchEngine`).
///
/// VoiceOver's order is the title, Back to Book, the field, the status line,
/// the switch, the "Search results" heading, and the results in the order they
/// lie in the book. Focus lands in the field a moment after the sheet opens,
/// as it does in every sheet with one field. Each completed search says its
/// status once with low priority (`PhoneAnnouncer`), so typing is never cut
/// off; the status line holds the same words for anyone who flicks to it.
///
/// A result goes to its place, keeping the Return place as the Mac's sheet
/// does, and closes the sheet; anything the jump says is said once the sheet
/// has closed (`PhoneSheetFarewell`), and the control that opened the sheet
/// takes focus back. Back to Book stops a search still running, so nothing is
/// said for a sheet that is gone.
///
/// Thin over `PhoneBookSearchSource`, which says every row's words. The
/// reader isn't observed: the sheet searches the text as it opened, and
/// nothing focusable changes while the book plays.
struct PhoneSearchSheet: View {
    /// The reader the sheet searches and moves.
    let reader: ReaderViewModel
    /// What the sheet leaves to say once it has closed.
    let farewell: PhoneSheetFarewell
    /// Tells the session the book was moved here, so it counts as opened
    /// (`PhoneReaderModel.noteJumped`).
    let noteJumped: @MainActor () -> Void

    /// What the sheet searches, copied as it opened.
    private let source: PhoneBookSearchSource
    /// Runs the searches: waits for typing to pause, searches off the main
    /// actor, and reports each search's status.
    @StateObject private var model: BookSearchModel
    /// Whether the field holds the keyboard.
    @FocusState private var fieldHasKeyboard: Bool
    /// Whether VoiceOver's focus is asked into the field.
    @AccessibilityFocusState private var fieldHasVoiceOver: Bool
    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss

    /// A sheet over `reader`, farewell words kept in `farewell`.
    init(reader: ReaderViewModel, farewell: PhoneSheetFarewell, noteJumped: @escaping @MainActor () -> Void) {
        self.reader = reader
        self.farewell = farewell
        self.noteJumped = noteJumped
        let source = PhoneBookSearchSource(reader: reader)
        self.source = source
        // Built once as the sheet opens; later redraws of the reader's
        // screen make this initializer run again, and its copy goes unused.
        _model = StateObject(wrappedValue: source.makeModel(announce: { PhoneAnnouncer.say($0) }))
    }

    var body: some View {
        NavigationStack {
            List {
                searchControls
                if !model.results.isEmpty {
                    resultRows
                }
            }
            // Scrolling the results puts the keyboard away, so it never
            // covers the rows being read or touched.
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle(PhoneBookSearchVocabulary.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                PhoneSheetButton(title: PhoneBookSearchVocabulary.backToBook, hint: BookSearchWording.backToBookHint) {
                    dismiss()
                }
            }
            .task {
                fillFieldForTesting()
                // A sheet with one field: focus lands in it, a moment after
                // the sheet appears, unless the listener has moved first
                // (the request holds a ticket, as the reader's returns do).
                let ticket = PhoneFocusRegistry.shared.beginRequest()
                try? await Task.sleep(for: .seconds(PhoneFocusPolicy.screenChangedDelay))
                guard PhoneFocusRegistry.shared.claimRequest(ticket) else { return }
                fieldHasKeyboard = true
                fieldHasVoiceOver = true
            }
            // Closing the sheet stops its search, so nothing is said after
            // it is gone.
            .onDisappear { model.cancelSearch() }
        }
    }

    // MARK: The field, the status, and the switch

    /// The field, the line that says what the search found, and the switch
    /// that makes the text a regular expression, in that order.
    @ViewBuilder
    private var searchControls: some View {
        Section {
            TextField(BookSearchWording.fieldLabel, text: $model.query)
                .focused($fieldHasKeyboard)
                .accessibilityFocused($fieldHasVoiceOver)
                .accessibilityLabel(BookSearchWording.fieldLabel)
                .accessibilityHint(source.isTranscript ? BookSearchWording.transcriptFieldHint : BookSearchWording.fieldHint)
                .submitLabel(.search)
                // A search is for words as they are written: no capital
                // letter or correction is put in the listener's text.
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .phonePrimaryText()
            // Plain text right after the field, which VoiceOver reads in
            // place; each completed search also says it (`PhoneAnnouncer`).
            Text(model.status.text)
                .phoneSecondaryText()
            Toggle(BookSearchWording.regexLabel, isOn: $model.useRegex)
                .accessibilityHint(BookSearchWording.regexHint)
                .phonePrimaryText()
        }
    }

    /// Fills the field with the text a UI test asks for, in debug builds only
    /// (the launch request's search variable): a test must not type, since the
    /// software keyboard clicks aloud.
    private func fillFieldForTesting() {
        #if DEBUG
        if let text = PhoneLaunchRequest.searchText(ProcessInfo.processInfo.environment) {
            model.query = text
        }
        #endif
    }

    // MARK: The results

    /// A row for each result under a "Search results" heading the Headings
    /// rotor reaches.
    private var resultRows: some View {
        Section {
            ForEach(model.results) { result in
                resultRow(source.row(for: result), result: result)
            }
        } header: {
            Text(BookSearchWording.resultsLabel)
                .phoneSecondaryText()
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// One result's row: a button that goes to it, read by the Mac's words:
    /// the context, where it is, and its place in the book.
    private func resultRow(_ row: PhoneBookSearchRow, result: BookSearchResult) -> some View {
        Button {
            go(to: result)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.context).phonePrimaryText()
                if let location = row.location {
                    Text(location).phoneSecondaryText()
                }
                Text(row.position).phoneSecondaryText()
            }
        }
        .accessibilityLabel(row.label)
        .accessibilityHint(PhoneBookSearchVocabulary.rowHint)
    }

    // MARK: What a row does

    /// Goes to `result`, keeping the Return place, and closes the sheet; what
    /// the jump says, a transcript's "Moved to 1:02:03, Chapter 4" included,
    /// is said once the sheet has closed.
    private func go(to result: BookSearchResult) {
        let said = VoiceOverAnnouncer.collectingAnnouncements {
            reader.goToSearchResult(
                chapterIndex: result.chapterIndex,
                characterOffset: result.characterOffset,
                inTranscript: source.isTranscript
            )
            // Kept by the reader for after the sheet on the Mac; here it
            // is collected with the rest, and said by the farewell.
            reader.announcePendingJump()
        }
        farewell.keep(said.map(\.message))
        noteJumped()
        dismiss()
    }
}
