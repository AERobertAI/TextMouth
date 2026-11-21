import SwiftUI

/// The phone's Headings sheet (the iPhone interface spec, "The Headings
/// sheet"): the title, Back to Book, Show levels, Display, then a row for
/// each heading, with focus landing on the current one.
///
/// Thin over `PhoneHeadingsModel`, which decides every word and choice. The
/// reader isn't observed: the rows are built when the sheet opens and again
/// only for a change the listener makes, so nothing focusable changes while
/// the book plays.
struct PhoneHeadingsSheet: View {
    /// The reader whose headings the sheet lists, goes to, and skips.
    let reader: ReaderViewModel
    /// What the sheet leaves to say once it has closed.
    let farewell: PhoneSheetFarewell
    /// Tells the session the book was moved here, so it counts as opened
    /// (`PhoneReaderModel.noteJumped`).
    let noteJumped: @MainActor () -> Void

    /// What the sheet offers, at the place it opened at.
    @State private var model: PhoneHeadingsModel
    /// The rows, built when the sheet opens and after each change.
    @State private var rows: [PhoneHeadingsRow] = []
    /// The list of choices open over the sheet, if any.
    @State private var choosing: Choosing?
    /// Where VoiceOver's focus is asked to go.
    @AccessibilityFocusState private var focus: Focus?
    /// Closes the sheet.
    @Environment(\.dismiss) private var dismiss

    /// A sheet over `reader`, farewell words kept in `farewell`.
    init(reader: ReaderViewModel, farewell: PhoneSheetFarewell, noteJumped: @escaping @MainActor () -> Void) {
        self.reader = reader
        self.farewell = farewell
        self.noteJumped = noteJumped
        _model = State(initialValue: PhoneHeadingsModel(reader: reader))
    }

    /// What VoiceOver's focus can be asked to land on.
    enum Focus: Hashable, Sendable {
        /// The Show levels row.
        case levels
        /// The Display row.
        case display
        /// A heading's row, by the heading's ID.
        case heading(String)
    }

    /// Which list of choices is open over the sheet.
    enum Choosing: String, Identifiable {
        /// Show levels' choices.
        case levels
        /// The display's choices.
        case display

        /// The list itself, for `sheet(item:)`.
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    filters
                    headingRows
                }
                .task {
                    rows = model.rows(for: reader)
                    if let target = model.initialFocusID(in: rows) {
                        PhoneListFocus.focus(Focus.heading(target), proxy: proxy, state: $focus)
                    }
                }
            }
            .navigationTitle(PhoneHeadingsVocabulary.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                PhoneSheetButton(title: PhoneHeadingsVocabulary.backToBook, hint: PhoneHeadingsVocabulary.backToBookHint) {
                    dismiss()
                }
            }
            .sheet(item: $choosing, onDismiss: returnFocusFromChoices) { choosing in
                choices(for: choosing)
            }
        }
    }

    // MARK: The filters

    /// Show levels, in a book of more than one level, and Display: each a
    /// row opening its list of choices.
    @ViewBuilder
    private var filters: some View {
        Section {
            if model.showsLevelFilter {
                PhoneActionButton(title: HeadingNavigatorView.levelFilterLabel) { open(.levels) }
                    .accessibilityValue(model.levelFilterValue)
                    .accessibilityHint(HeadingNavigatorView.levelFilterHint)
                    .accessibilityFocused($focus, equals: .levels)
                    .id(Focus.levels)
            }
            PhoneActionButton(title: PhoneHeadingsVocabulary.displayLabel) { open(.display) }
                .accessibilityValue(model.displayValue)
                .accessibilityFocused($focus, equals: .display)
                .id(Focus.display)
        }
    }

    /// The list of choices `choosing` names, each closing it as it's made.
    @ViewBuilder
    private func choices(for choosing: Choosing) -> some View {
        switch choosing {
        case .levels:
            PhoneChoiceSheet(
                title: HeadingNavigatorView.levelFilterLabel,
                choices: model.levelChoices,
                selected: model.maximumLevel
            ) { level in
                model.maximumLevel = level
                rows = model.rows(for: reader)
            }
        case .display:
            PhoneChoiceSheet(
                title: PhoneHeadingsVocabulary.displayTitle,
                choices: PhoneHeadingsModel.displayChoices,
                selected: model.displayMode
            ) { mode in
                model.displayMode = mode
                rows = model.rows(for: reader)
            }
        }
    }

    /// Opens the list of choices `list`, noting it for the return of focus.
    private func open(_ list: Choosing) {
        lastChoosing = list
        choosing = list
    }

    /// Puts focus back on the row whose list of choices just closed, a
    /// moment after it has gone, as every sheet's return does.
    private func returnFocusFromChoices() {
        let target: Focus = lastChoosing == .levels ? .levels : .display
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(PhoneFocusPolicy.screenChangedDelay))
            focus = nil
            await Task.yield()
            focus = target
        }
    }

    /// The list of choices last opened, kept for the return of focus, since
    /// `choosing` is nil by the time the sheet's `onDismiss` runs.
    @State private var lastChoosing: Choosing?

    // MARK: The headings

    /// A row for each heading the filter shows, or the Mac's sentence for a
    /// book without headings.
    @ViewBuilder
    private var headingRows: some View {
        Section {
            if model.headings.isEmpty {
                Text(PhoneHeadingsVocabulary.empty)
            } else {
                ForEach(rows) { row in
                    headingRow(row)
                        .id(Focus.heading(row.id))
                }
            }
        }
    }

    /// One heading's row: a button that goes to it, read by the Mac's
    /// label, with the one action Skip Section or Include Section, and a
    /// context menu of the same for touch.
    private func headingRow(_ row: PhoneHeadingsRow) -> some View {
        Button {
            go(to: row.heading)
        } label: {
            HStack {
                Text(row.heading.text)
                    .padding(.leading, CGFloat(max(row.heading.level - 1, 0) * 12))
                    .strikethrough(row.isSkipped)
                    .phonePrimaryText()
                Spacer()
                Text(row.infoText)
                    .phoneSecondaryText()
            }
        }
        .accessibilityLabel(row.label)
        .accessibilityHint(PhoneHeadingsVocabulary.rowHint)
        .accessibilityAddTraits(row.isCurrent ? .isSelected : [])
        .accessibilityAction(named: row.toggleSkipActionName) { toggleSkip(row.heading) }
        .contextMenu {
            Button(row.toggleSkipActionName) { toggleSkip(row.heading) }
        }
        .accessibilityFocused($focus, equals: .heading(row.id))
    }

    // MARK: What the rows do

    /// Goes to `heading`, keeping the Return place, as the Mac's sheet does,
    /// and closes the sheet; what the move says is said once it has closed,
    /// by "What a move says", with anything else the jump said.
    private func go(to heading: Heading) {
        let playsAfterJump = reader.isPlaybackActivelyAdvancing || reader.settingsViewModel.autoPlayOnNavigate
        let said = VoiceOverAnnouncer.collectingAnnouncements {
            reader.navigateToHeading(heading)
        }
        let own = PhoneHeadingsModel.jumpAnnouncement(
            arrivingAt: heading,
            in: model.headings,
            isAudioBook: reader.isAudioBook,
            playsAfterJump: playsAfterJump
        )
        farewell.keep([own].compactMap { $0 } + said.map(\.message))
        noteJumped()
        dismiss()
    }

    /// Skips `heading`'s section, or includes it again, as the Mac's row
    /// does, and says the Mac's words a moment later; the row's label
    /// changes, since the listener asked.
    private func toggleSkip(_ heading: Heading) {
        let said = VoiceOverAnnouncer.collectingAnnouncements {
            reader.toggleHeadingSkip(heading)
        }
        model.skippedHeadingIDs = reader.skippedHeadingIDs
        rows = model.rows(for: reader)
        PhoneAnnouncer.say(inOrder: said.map(\.message))
    }
}
