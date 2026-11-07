import Foundation

// MARK: - The Mac's words

/// The words of the Mac's Headings sheet that sit inline in its view,
/// `HeadingNavigatorView`, held here for the phone's sheet, which is rebuilt
/// for the phone rather than wrapped (the iPhone interface spec, "One
/// vocabulary"). `PhoneHeadingsVocabularyTests` reads the Mac's source and
/// requires each word to be there as it is, so the two apps can't drift
/// apart. Words the Mac's view already offers as statics are called there,
/// not copied here.
enum PhoneHeadingsVocabulary {
    /// The sheet's title, read as its heading.
    static let title = "Headings"
    /// The toolbar button that closes the sheet.
    static let backToBook = "Back to Book"
    /// What Back to Book does.
    static let backToBookHint = "Close the headings screen and return to the book"
    /// The display row's label: which time or percent each row ends with.
    static let displayLabel = "Heading info display mode"
    /// What the sheet says for a book without headings.
    static let empty = "No headings found in this document."
    /// A heading row's hint: what choosing it does, never a gesture.
    static let rowHint = "Goes to this heading and closes the list."
}

// MARK: - A row

/// One heading's row in the phone's Headings sheet: what it shows, what
/// VoiceOver reads, and its one named action.
struct PhoneHeadingsRow: Identifiable, Equatable {
    /// The heading the row goes to.
    let heading: Heading
    /// Whether the heading's section is skipped.
    let isSkipped: Bool
    /// Whether the reading place was in this heading when the sheet opened,
    /// under the level filter shown.
    let isCurrent: Bool
    /// What VoiceOver reads: the Mac's row label, as in "The Battle (current
    /// heading) - level 2, 1 hour, 3 minutes", with "Skipped, " first for a
    /// skipped section.
    let label: String
    /// The time or percent shown after the heading's name, for sight; the
    /// label says it in words.
    let infoText: String

    /// The heading's own ID, which the list never changes when it refreshes,
    /// so VoiceOver's cursor stays put (the spec, under "Lists").
    var id: String { heading.id }

    /// The name of the row's one action, on the Actions rotor and in its
    /// context menu: the Mac's "Skip Section", or "Include Section" for a
    /// section already skipped. Go To isn't offered as an action, since
    /// activating the row does it (the spec, "The Headings sheet").
    var toggleSkipActionName: String {
        HeadingRow.commandTitles(isSkipped: isSkipped).toggleSkip
    }
}

// MARK: - The sheet

/// What the phone's Headings sheet shows and decides, for one book's headings
/// at the place the sheet opened at (the iPhone interface spec, "The Headings
/// sheet"): the level filter's and the display's choices, the rows, and where
/// focus lands on arrival. Every word is the Mac's, through
/// `HeadingNavigatorView`'s statics and `PhoneHeadingsVocabulary`.
///
/// The current heading is taken once, when the sheet opens, and not followed
/// while the book plays: a row's label that changed under VoiceOver's cursor
/// could be spoken over the book (the spec's principle 3). A skip the
/// listener asks for does change its row, since it was asked for.
///
/// Main-actor isolated because the Mac's statics it calls are a view's.
@MainActor
struct PhoneHeadingsModel {
    /// Every heading of the book, in reading order.
    let headings: [Heading]
    /// The IDs of the headings whose sections are skipped.
    var skippedHeadingIDs: Set<String>
    /// The heading the place was in when the sheet opened, under each level
    /// filter, as `HeadingNavigatorView.currentHeadingIDs` lists them.
    let currentHeadingIDs: [String?]
    /// The deepest level the list shows: every level at first, as on the
    /// Mac.
    var maximumLevel = HeadingNavigatorView.deepestFilterLevel
    /// What each row ends with: its duration at first, as on the Mac.
    var displayMode: HeadingNavigatorView.HeadingDisplayMode = .timeEstimate

    /// A model for a book's `headings`, `skippedHeadingIDs`, and the
    /// `currentHeadingIDs` of the place the sheet opens at.
    init(headings: [Heading], skippedHeadingIDs: Set<String>, currentHeadingIDs: [String?]) {
        self.headings = headings
        self.skippedHeadingIDs = skippedHeadingIDs
        self.currentHeadingIDs = currentHeadingIDs
    }

    // MARK: The level filter

    /// The levels present in the book, sorted.
    var levelsPresent: [Int] {
        HeadingNavigatorView.levelsPresent(in: headings)
    }

    /// Whether the sheet offers Show levels: only in a book with headings of
    /// more than one level, as on the Mac, where one level would leave a
    /// filter whose one choice changes nothing. A book's levels don't change
    /// while the sheet is open, so the row never appears or vanishes there.
    var showsLevelFilter: Bool {
        levelsPresent.count > 1
    }

    /// Show levels' choices, in the Mac's order: "Level 1", "Levels 1 to 2",
    /// and so on for the levels the book has, then "All levels".
    var levelChoices: [PhoneChoice<Int>] {
        let levels = HeadingNavigatorView.filterLevels(for: levelsPresent) + [HeadingNavigatorView.deepestFilterLevel]
        return levels.map { level in
            PhoneChoice(id: level, label: HeadingNavigatorView.filterChoiceTitle(maximumLevel: level))
        }
    }

    /// Show levels' value: the filter in force, as "All levels".
    var levelFilterValue: String {
        HeadingNavigatorView.filterChoiceTitle(maximumLevel: maximumLevel)
    }

    // MARK: The display

    /// The display's choices, the Mac's: "Duration", "Time In",
    /// "Percentage".
    static let displayChoices: [PhoneChoice<HeadingNavigatorView.HeadingDisplayMode>] =
        HeadingNavigatorView.HeadingDisplayMode.allCases.map { PhoneChoice(id: $0, label: $0.rawValue) }

    /// The display's value: the mode in force, as "Duration".
    var displayValue: String {
        displayMode.rawValue
    }

    // MARK: The rows

    /// The headings the level filter shows, in reading order.
    var displayedHeadings: [Heading] {
        HeadingNavigatorView.filteredHeadings(headings, maximumLevel: maximumLevel)
    }

    /// The heading the place was in when the sheet opened, under the level
    /// filter shown; nil before the first heading shown.
    var currentHeadingID: String? {
        HeadingNavigatorView.currentHeadingID(forMaximumLevel: maximumLevel, in: currentHeadingIDs)
    }

    /// The rows for `items`, the Mac's row details of `displayedHeadings` in
    /// `displayMode` (`HeadingNavigatorView.headingItems`): each with the
    /// Mac's label, its current heading named in it.
    func rows(from items: [HeadingNavigatorView.HeadingListItem]) -> [PhoneHeadingsRow] {
        let current = currentHeadingID
        return items.map { item in
            let isCurrent = item.heading.id == current
            return PhoneHeadingsRow(
                heading: item.heading,
                isSkipped: item.isSkipped,
                isCurrent: isCurrent,
                label: item.accessibilityDescription(isCurrent: isCurrent),
                infoText: item.infoText
            )
        }
    }

    /// The row VoiceOver's focus lands on when the sheet opens: the current
    /// heading, as on the Mac, or the first row when the place is before the
    /// first heading shown; nil for an empty list.
    func initialFocusID(in rows: [PhoneHeadingsRow]) -> String? {
        if let current = currentHeadingID, rows.contains(where: { $0.id == current }) {
            return current
        }
        return rows.first?.id
    }

    // MARK: After a jump

    /// What VoiceOver says once the sheet has closed on a heading chosen in
    /// it, by "What a move says" in the spec: while the book plays after the
    /// jump, nothing for a text book, whose own words say where it is, and
    /// the Mac's "Heading: Chapter 4" for an audiobook, whose words can't;
    /// while it rests paused, the Mac's words in either. A jump that starts
    /// the book, with Auto-play after navigation on, counts as playing.
    ///
    /// - Parameters:
    ///   - heading: The heading chosen.
    ///   - headings: Every heading of the book, for the headings that begin
    ///     at the same place (`ReaderViewModel.headingAnnouncement`).
    ///   - isAudioBook: Whether the book is an audiobook.
    ///   - playsAfterJump: Whether the book plays once the jump is made.
    nonisolated static func jumpAnnouncement(
        arrivingAt heading: Heading,
        in headings: [Heading],
        isAudioBook: Bool,
        playsAfterJump: Bool
    ) -> String? {
        if playsAfterJump && !isAudioBook { return nil }
        return ReaderViewModel.headingAnnouncement(arrivingAt: heading, in: headings)
    }
}

// MARK: - From a reader

extension PhoneHeadingsModel {
    /// The model for `reader`'s book at the place its screen shows now.
    init(reader: ReaderViewModel) {
        self.init(
            headings: reader.headings,
            skippedHeadingIDs: reader.skippedHeadingIDs,
            currentHeadingIDs: HeadingNavigatorView.currentHeadingIDs(
                in: reader.headings,
                chapterIndex: reader.displayChapterIndex,
                characterOffset: reader.displayCharacterOffset
            )
        )
    }

    /// The rows for `reader`'s book, with the times and percents the Mac's
    /// sheet gives them on the book's clock.
    func rows(for reader: ReaderViewModel) -> [PhoneHeadingsRow] {
        rows(from: HeadingNavigatorView.headingItems(
            for: reader,
            displayed: displayedHeadings,
            allHeadings: headings,
            skippedIDs: skippedHeadingIDs,
            mode: displayMode
        ))
    }
}
