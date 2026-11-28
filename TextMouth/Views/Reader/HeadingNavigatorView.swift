import Combine
import SwiftUI

struct HeadingNavigatorView: View {
    /// Static metadata for one heading row. Crucially does NOT include the
    /// "currently reading" flag — that's tracked separately via
    /// `currentHeadingID` so a moving playback cursor doesn't force the
    /// whole list and accessibility hierarchy to be rebuilt (and VoiceOver
    /// focus to be lost) on every word spoken.
    struct HeadingListItem: Identifiable, Equatable {
        let heading: Heading
        let isSkipped: Bool
        let infoText: String
        /// Timing or percentage detail appended after the structural label.
        /// Store the suffix separately so the lightweight current-heading
        /// state can update the spoken label without rebuilding every row.
        let accessibilitySuffix: String

        var id: String { heading.id }

        /// Build the final row label, inserting the current status directly
        /// after the heading name as requested by VoiceOver users.
        func accessibilityDescription(isCurrent: Bool) -> String {
            HeadingNavigatorView.accessibilityDescription(
                text: heading.text,
                level: heading.level,
                isSkipped: isSkipped,
                isCurrent: isCurrent,
                suffix: accessibilitySuffix
            )
        }
    }

    /// What the rows' times depend on besides the headings and the position
    /// (P08): how the book's times are counted (an audiobook's recording, or
    /// a text book's words at its words per minute), the speed an audiobook's
    /// lengths are heard at, and the speed the setting names beside each
    /// length. The sheet rebuilds its rows when this changes, so a speed
    /// change made while it is open (Increase Speed, or the Settings window)
    /// reaches its Durations, its Time In values, and its named speeds. It
    /// does not change while a book plays, so playback rebuilds nothing.
    struct RowTiming: Equatable {
        /// How the book's times are counted, which its clock follows.
        let count: ReaderTimeWording.Count
        /// The speed the rows hear lengths at: an audiobook's speed, or 1
        /// for a text book, whose clock already counts its words at its
        /// speed. As `headingItems(for:displayed:allHeadings:skippedIDs:mode:)`
        /// passes it.
        let listeningSpeed: Double
        /// The speed named beside each length, nil while the setting is off.
        let namedSpeed: ReaderTimeWording.ListeningSpeed?

        /// What `reader` counts its times by now.
        @MainActor
        init(of reader: ReaderViewModel) {
            count = reader.timeCount
            listeningSpeed = reader.isAudioBook ? reader.audioSpeed : 1
            namedSpeed = reader.namedListeningSpeed
        }
    }

    /// What the sheet shows of its reader, which it follows instead of the
    /// whole reader (PERF30): the book's title, its headings, the sections
    /// skipped, and the heading the reading position is in under each level
    /// filter. While a book plays its position moves with every word,
    /// but this changes only when the position crosses into another heading.
    struct ReaderState: Equatable {
        /// The book's title, for the sheet's title.
        let title: String
        /// Every heading, in reading order.
        let headings: [Heading]
        /// The IDs of the headings whose sections are skipped.
        let skippedHeadingIDs: Set<String>
        /// The heading the reading position is in, by level filter, as
        /// `HeadingNavigatorView.currentHeadingIDs` lists them.
        let currentHeadingIDs: [String?]
        /// What the rows' times depend on, which a speed change alters.
        let timing: RowTiming

        /// What `reader` shows the sheet now, at the position it displays.
        @MainActor
        init(of reader: ReaderViewModel) {
            title = reader.book.title
            headings = reader.headings
            skippedHeadingIDs = reader.skippedHeadingIDs
            currentHeadingIDs = HeadingNavigatorView.currentHeadingIDs(
                in: reader.headings,
                chapterIndex: reader.displayChapterIndex,
                characterOffset: reader.displayCharacterOffset
            )
            timing = RowTiming(of: reader)
        }
    }

    /// The deepest heading level the level filter offers; its "All levels"
    /// choice shows every heading up to this level.
    nonisolated static let deepestFilterLevel = 6

    /// The heading the reading position at `chapterIndex` and
    /// `characterOffset` is in, under each level filter the sheet offers:
    /// entry `level - 1` is the last heading in `headings` (in reading order)
    /// at `level` or above that starts at or before the position, or nil
    /// before the first. The same rule picks the current heading for one
    /// filter; one pass answers it for every filter, so the sheet's snapshot
    /// can follow the position without knowing the filter shown.
    nonisolated static func currentHeadingIDs(
        in headings: [Heading],
        chapterIndex: Int,
        characterOffset: Int
    ) -> [String?] {
        var current = [String?](repeating: nil, count: deepestFilterLevel)
        for heading in headings where heading.startsAtOrBefore(chapterIndex: chapterIndex, characterOffset: characterOffset) {
            for maximumLevel in 1...deepestFilterLevel where heading.level <= maximumLevel {
                current[maximumLevel - 1] = heading.id
            }
        }
        return current
    }

    /// The heading the reading position is in under the filter that shows
    /// levels up to `maximumLevel`, from `currentHeadingIDs`.
    nonisolated static func currentHeadingID(forMaximumLevel maximumLevel: Int, in currentHeadingIDs: [String?]) -> String? {
        let index = min(max(maximumLevel, 1), deepestFilterLevel) - 1
        return currentHeadingIDs.indices.contains(index) ? currentHeadingIDs[index] : nil
    }

    /// Shared row/rotor label format so VoiceOver speaks heading names before
    /// structural level and optional status details. Pure, so nonisolated:
    /// `HeadingListItem`, which is not main-actor isolated, and tests call it.
    nonisolated static func accessibilityDescription(
        text: String,
        level: Int,
        isSkipped: Bool = false,
        isCurrent: Bool = false,
        suffix: String = ""
    ) -> String {
        // One whole string for each of the four states, never glued pieces.
        let base: String
        switch (isSkipped, isCurrent) {
        case (false, false):
            // Translators: What VoiceOver says for a heading in the headings list. %1$@ is the heading's text; %2$lld is its level, 1 for the biggest heading.
            base = InterfaceText.line("headingNavigatorView.level", "\(text) - level \(number: level)")
        case (true, false):
            // Translators: What VoiceOver says for a heading the user skipped, in the headings list. %1$@ is the heading's text; %2$lld is its level, 1 for the biggest heading.
            base = InterfaceText.line("headingNavigatorView.skippedLevel", "Skipped, \(text) - level \(number: level)")
        case (false, true):
            // Translators: What VoiceOver says for the heading being read, in the headings list. %1$@ is the heading's text; %2$lld is its level, 1 for the biggest heading.
            base = InterfaceText.line("headingNavigatorView.currentLevel", "\(text) (current heading) - level \(number: level)")
        case (true, true):
            // Translators: What VoiceOver says for the heading being read when the user skipped it, in the headings list. %1$@ is the heading's text; %2$lld is its level, 1 for the biggest heading.
            base = InterfaceText.line("headingNavigatorView.skippedCurrentLevel", "Skipped, \(text) (current heading) - level \(number: level)")
        }
        guard !suffix.isEmpty else { return base }
        // Translators: A heading's description followed by a detail such as its duration. %1$@ is the description, such as "Chapter One - level 1"; %2$@ is the detail, such as "4 minutes".
        return InterfaceText.line("sentence.commaJoined", "\(base), \(suffix)")
    }

    static func filteredHeadings(_ headings: [Heading], maximumLevel: Int) -> [Heading] {
        headings.filter { $0.level <= maximumLevel }
    }

    static func levelsPresent(in headings: [Heading]) -> [Int] {
        Array(Set(headings.map(\.level))).sortedStably()
    }

    /// The levels the filter offers a choice of its own for, given the
    /// levels present in the book, sorted: every one but the deepest. A
    /// choice of the deepest level shows every heading, as the filter's
    /// "All levels" choice does, so offering both put the same filter twice
    /// before VoiceOver (and gave two choices one tag in a book with level-6
    /// headings).
    static func filterLevels(for levelsPresent: [Int]) -> [Int] {
        Array(levelsPresent.dropLast())
    }

    /// What VoiceOver calls the list of headings: "Headings, 1 heading",
    /// "Headings, 12 headings", counting those the level filter shows.
    nonisolated static func listLabel(headingCount: Int) -> String {
        // Translators: What VoiceOver calls the list of headings, with how many it shows. %lld is the number of headings the level filter shows.
        InterfaceText.line("headingNavigatorView.listLabel", "Headings, \(number: headingCount) headings")
    }

    /// The level filter's label, which the screen shows beside it and
    /// VoiceOver speaks as its name.
    nonisolated static var levelFilterLabel: String {
        // Translators: Label of the headings sheet's level filter, which limits the headings shown to those up to a level.
        InterfaceText.line("headingNavigatorView.levelFilterLabel", "Show levels")
    }
    /// The level filter's hint: what choosing does.
    nonisolated static var levelFilterHint: String {
        // Translators: Hint of the headings sheet's level filter: what choosing a level does.
        InterfaceText.line("headingNavigatorView.levelFilterHint", "Shows only the headings up to the level chosen.")
    }
    /// The caption the screen shows beside the level filter: its label and a colon.
    nonisolated static var levelFilterCaption: String {
        // Translators: Caption beside the headings sheet's level filter. %@ is the filter's label; the colon follows it as the language writes a label before a control.
        InterfaceText.line("headingNavigatorView.levelFilterCaption", "\(levelFilterLabel):")
    }

    /// The level filter's name for the choice showing levels 1 to
    /// `maximumLevel`, in words a braille display and VoiceOver read alike:
    /// "Level 1", "Levels 1 to 3", and "All levels" for the deepest level
    /// the filter offers (TODO A10; the choices said "H1–H1", "H1–H3", and
    /// "All", with an en dash).
    nonisolated static func filterChoiceTitle(maximumLevel: Int) -> String {
        if maximumLevel >= deepestFilterLevel {
            // Translators: Choice of the headings sheet's level filter that shows every level.
            return InterfaceText.line("headingNavigatorView.filterChoiceTitle.allLevels", "All levels")
        }
        if maximumLevel <= 1 {
            // Translators: Choice of the headings sheet's level filter that shows only the biggest headings, level 1.
            return InterfaceText.line("headingNavigatorView.filterChoiceTitle.level", "Level 1")
        }
        // Translators: Choice of the headings sheet's level filter that shows levels from 1 to a deeper one. %lld is the deepest level shown.
        return InterfaceText.line("headingNavigatorView.filterChoiceTitle.levels", "Levels 1 to \(number: maximumLevel)")
    }

    /// Return the end offset for every heading currently displayed in the
    /// navigator. A filtered-out heading must not terminate a visible row's
    /// duration: when the user selects H1 only, each H1 describes the whole
    /// span through the next displayed H1 (or through the end of the book).
    static func nextDisplayedHeadingOffsets(
        _ displayedHeadings: [Heading],
        globalOffsetsByID: [String: Int],
        totalCharacterCount: Int
    ) -> [String: Int] {
        var nextOffsetsByID: [String: Int] = [:]
        nextOffsetsByID.reserveCapacity(displayedHeadings.count)

        for (index, heading) in displayedHeadings.enumerated() {
            if index + 1 < displayedHeadings.count {
                let nextHeading = displayedHeadings[index + 1]
                nextOffsetsByID[heading.id] = globalOffsetsByID[nextHeading.id] ?? totalCharacterCount
            } else {
                nextOffsetsByID[heading.id] = totalCharacterCount
            }
        }

        return nextOffsetsByID
    }

    /// The reader whose headings the sheet lists, goes to, and skips. Not
    /// observed: the sheet follows `shown` instead (PERF30).
    let viewModel: ReaderViewModel
    /// What the sheet shows of the reader, republished only when it changes.
    @StateObject private var shown: ReaderSnapshot<ReaderState>
    @Environment(\.dismiss) private var dismiss
    @State private var displayMode: HeadingDisplayMode = .timeEstimate
    @State private var maxHeadingLevel: Int = HeadingNavigatorView.deepestFilterLevel
    // Cache the rendered heading metadata in state so sheet presentation does
    // not repeatedly recompute timing/accessibility strings on the main thread.
    @State private var headingItems: [HeadingListItem] = []
    /// The timing the rows were last built with, so a change to the
    /// settings, which the snapshot never hears, rebuilds them only when it
    /// changed what their times depend on.
    @State private var builtTiming: RowTiming?
    /// The row that receives the sheet's one-time accessibility focus request.
    /// Keep this separate from `currentHeadingID`: playback may cross into a
    /// new section while the sheet is open, but it must not steal VoiceOver
    /// focus from whichever control the user is currently exploring.
    @State private var initialFocusHeadingID: String?
    /// What each heading's row shows after its name, as the display
    /// picker's segments name it.
    enum HeadingDisplayMode: String, CaseIterable {
        case timeEstimate = "Duration" // l10n: no (stored id: `title` is shown)
        case timeIntoBook = "Time In" // l10n: no (stored id: `title` is shown)
        case percentage = "Percentage" // l10n: no (stored id: `title` is shown)

        /// The name the display picker shows for this choice.
        var title: String {
            switch self {
            case .timeEstimate:
                // Translators: Choice of the headings sheet's display picker: each heading shows how long it lasts.
                return InterfaceText.line("common.duration", "Duration")
            case .timeIntoBook:
                // Translators: Choice of the headings sheet's display picker: each heading shows the time into the book at which it begins.
                return InterfaceText.line("headingDisplayMode.title.timeIntoBook", "Time In")
            case .percentage:
                // Translators: Choice of the headings sheet's display picker: each heading shows how far through the book it begins, as a percent.
                return InterfaceText.line("common.percentage", "Percentage")
            }
        }
    }

    // MARK: Words of the sheet

    /// The sheet's heading.
    nonisolated static var sheetTitle: String {
        // Translators: Heading of the headings sheet, which lists a book's headings.
        InterfaceText.line("common.headings", "Headings")
    }
    /// The display picker's name.
    nonisolated static var displayPickerTitle: String {
        // Translators: Name of the headings sheet's picker that chooses what each heading shows after its name.
        InterfaceText.line("common.display", "Display")
    }
    /// What VoiceOver calls the display picker.
    nonisolated static var displayPickerLabel: String {
        // Translators: What VoiceOver calls the headings sheet's picker that chooses what each heading shows after its name.
        InterfaceText.line("headingNavigatorView.displayPickerLabel", "Heading info display mode")
    }
    /// The button that closes the sheet.
    nonisolated static var backToBookTitle: String {
        // Translators: Button of the headings sheet that closes it and returns to the book.
        InterfaceText.line("common.backToBook", "Back to Book")
    }
    /// That button's hint.
    nonisolated static var backToBookHint: String {
        // Translators: Hint of the headings sheet's Back to Book button.
        InterfaceText.line("headingNavigatorView.backToBookHint", "Close the headings screen and return to the book")
    }
    /// What the sheet says when the book has no headings.
    nonisolated static var noHeadingsMessage: String {
        // Translators: Message in the headings sheet when the book has no headings.
        InterfaceText.line("headingNavigatorView.noHeadingsMessage", "No headings found in this document.")
    }
    /// The name of the rotor that moves among headings by level.
    nonisolated static var levelsRotorName: String {
        // Translators: Name of the VoiceOver rotor that moves among the headings of the headings list.
        InterfaceText.line("headingNavigatorView.levelsRotorName", "Heading Levels")
    }
    /// The sheet's navigation title.
    nonisolated static func navigationTitle(bookTitle: String) -> String {
        // Translators: Navigation title of the headings sheet. %@ is the book's title.
        InterfaceText.line("headingNavigatorView.navigationTitle", "Headings: \(bookTitle)")
    }
    /// What VoiceOver says for the mark on a skipped heading.
    nonisolated static var skippedMarkLabel: String {
        // Translators: What VoiceOver says for the mark on a heading the user skipped.
        InterfaceText.line("headingNavigatorView.skippedMarkLabel", "Skipped")
    }
    /// What VoiceOver says for the mark on the heading being read.
    nonisolated static var currentMarkLabel: String {
        // Translators: What VoiceOver says for the speaker mark on the heading being read.
        InterfaceText.line("headingNavigatorView.currentMarkLabel", "Currently reading")
    }

    /// A sheet listing `viewModel`'s headings.
    init(viewModel: ReaderViewModel) {
        self.viewModel = viewModel
        _shown = StateObject(wrappedValue: ReaderSnapshot(of: viewModel, ReaderState.init(of:)))
    }

    /// The heading the playback cursor is in, under the level filter shown:
    /// the row with the speaker badge. It changes only when the cursor
    /// crosses into another heading, which redraws the sheet and, of its
    /// rows, only the two whose badge moves; the list's identity, scroll
    /// position, and VoiceOver focus stay put.
    private var currentHeadingID: String? {
        Self.currentHeadingID(forMaximumLevel: maxHeadingLevel, in: shown.value.currentHeadingIDs)
    }

    var body: some View {
        let _ = ViewBodyCounter.record("HeadingNavigatorView")
        VStack(spacing: 0) {
            HStack {
                Text(Self.sheetTitle)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()

                Picker(Self.displayPickerTitle, selection: $displayMode) {
                    ForEach(HeadingDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                .accessibilityLabel(Self.displayPickerLabel)

                Button(Self.backToBookTitle) { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityHint(Self.backToBookHint)
            }
            .padding()

            // Heading level filter: one control with one name, which the
            // screen shows beside it and VoiceOver speaks once, as the
            // filter's own. A caption naming it again used to be a second
            // stop, and the picker's own title, "Max level", showed as a
            // second label beside the caption (TODO A10). A segmented
            // picker's label view never reaches VoiceOver, so the name is
            // its accessibility label, and the caption is for the eye.
            if headingLevelsPresent.count > 1 {
                HStack(spacing: 8) {
                    Text(Self.levelFilterCaption)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .accessibilityHidden(true)

                    Picker(selection: $maxHeadingLevel) {
                        ForEach(Self.filterLevels(for: headingLevelsPresent), id: \.self) { level in
                            Text(Self.filterChoiceTitle(maximumLevel: level)).tag(level)
                        }
                        Text(Self.filterChoiceTitle(maximumLevel: Self.deepestFilterLevel)).tag(Self.deepestFilterLevel)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityLabel(Self.levelFilterLabel)
                    .accessibilityHint(Self.levelFilterHint)
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
            }

            Divider()

            if shown.value.headings.isEmpty {
                Text(Self.noHeadingsMessage)
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    // Keep every heading row alive while the sheet is open.
                    // LazyVStack recycles offscreen accessibility elements;
                    // on long lists that can invalidate VoiceOver's current
                    // element and send focus back toward the beginning.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(headingItems) { item in
                            // `isCurrent` is derived inline, and rows are
                            // equatable, so a move of the playback cursor into
                            // another heading redraws only the two rows whose
                            // speaker badge moves, not the whole list.
                            HeadingNavigatorRow(
                                item: item,
                                isCurrent: item.heading.id == currentHeadingID,
                                isInitialFocusTarget: item.id == initialFocusHeadingID,
                                goTo: {
                                    viewModel.navigateToHeading(item.heading)
                                    dismiss()
                                },
                                toggleSkip: {
                                    viewModel.toggleHeadingSkip(item.heading)
                                }
                            )
                            .equatable()
                            Divider()
                        }
                    }
                }
                .accessibilityRotor(Self.levelsRotorName) {
                    ForEach(filteredHeadings) { heading in
                        AccessibilityRotorEntry(
                            Self.accessibilityDescription(text: heading.text, level: heading.level),
                            id: heading.id
                        )
                    }
                }
                // The list's name, with how many headings it shows. It was
                // on the whole sheet, whose controls are no one element, so
                // the controls in it took the name: the display and level
                // pickers were each "Headings, 3 headings" to VoiceOver
                // (TODO A10).
                .accessibilityLabel(Self.listLabel(headingCount: headingItems.count))
            }
        }
        .frame(width: 550, height: 500)
        .navigationTitle(Self.navigationTitle(bookTitle: shown.value.title))
        .onAppear {
            rebuildHeadingItems()
            initialFocusHeadingID = Self.initialFocusHeadingID(
                currentHeadingID: currentHeadingID,
                headingItems: headingItems
            )
            voiceOverFocusLog("headings sheet appeared with \(headingItems.count) rows")
        }
        .onChange(of: displayMode) { _, _ in
            rebuildHeadingItems()
        }
        // The badge follows the filter by itself: the current heading is
        // derived for each filter from the snapshot.
        .onChange(of: maxHeadingLevel) { _, _ in
            rebuildHeadingItems()
        }
        .onChange(of: shown.value.headings) { _, _ in
            rebuildHeadingItems()
        }
        .onChange(of: shown.value.skippedHeadingIDs) { _, _ in
            rebuildHeadingItems()
        }
        // A speed change while the sheet is open (Increase Speed acts under
        // a sheet) reaches the snapshot, which republishes the timing.
        .onChange(of: shown.value.timing) { _, _ in
            rebuildHeadingItems()
        }
        // The setting that names the speed is the settings model's, which
        // the reader does not republish. Look on the next main-queue turn,
        // so the new value is stored before it is read, and rebuild only if
        // the timing really changed: any other setting rebuilds nothing.
        .onReceive(
            viewModel.settingsViewModel.objectWillChange.receive(on: DispatchQueue.main)
        ) { _ in
            rebuildHeadingItemsIfTimingChanged()
        }
    }

    private var filteredHeadings: [Heading] {
        Self.filteredHeadings(shown.value.headings, maximumLevel: maxHeadingLevel)
    }

    /// Prefer the currently read heading for initial accessibility focus.
    /// Documents whose first heading begins after the saved reading position
    /// have no current heading yet, so they intentionally fall back to row one.
    /// Pure, so nonisolated, and tests call it from any context.
    nonisolated static func initialFocusHeadingID(
        currentHeadingID: String?,
        headingItems: [HeadingListItem]
    ) -> String? {
        currentHeadingID ?? headingItems.first?.id
    }

    private func makeHeadingItems() -> [HeadingListItem] {
        Self.headingItems(
            for: viewModel,
            displayed: filteredHeadings,
            allHeadings: shown.value.headings,
            skippedIDs: shown.value.skippedHeadingIDs,
            mode: displayMode
        )
    }

    /// The rows the sheet shows for `reader`'s book: its places named on
    /// its clock (`ReaderViewModel.placeClock`), an audiobook's lengths
    /// heard at its speed, and that speed named beside each length while
    /// the setting asks for it (`ReaderViewModel.namedListeningSpeed`).
    /// Before the book's content loads, each row shows its heading alone.
    static func headingItems(
        for reader: ReaderViewModel,
        displayed: [Heading],
        allHeadings: [Heading],
        skippedIDs: Set<String>,
        mode: HeadingDisplayMode
    ) -> [HeadingListItem] {
        guard let content = reader.content, let clock = reader.placeClock else {
            return displayed.map { heading in
                HeadingListItem(
                    heading: heading,
                    isSkipped: skippedIDs.contains(heading.id),
                    infoText: "",
                    accessibilitySuffix: ""
                )
            }
        }
        return headingItems(
            displayed: displayed,
            allHeadings: allHeadings,
            skippedIDs: skippedIDs,
            mode: mode,
            content: content,
            clock: clock,
            listeningSpeed: reader.isAudioBook ? reader.audioSpeed : 1,
            namedSpeed: reader.namedListeningSpeed
        )
    }

    /// The rows the sheet shows for the `displayed` headings, in `mode`,
    /// for a book whose `content` names its places on `clock`
    /// (`ReaderViewModel.placeClock`, P08):
    ///
    /// - Time In: where each heading starts on the clock. An audiobook's is
    ///   its time in the recording, the same at every speed, so typed into
    ///   Go to Time it lands on the heading; a text book's is its time at
    ///   its words per minute, as always.
    /// - Duration: how long each heading lasts, to the next heading shown or
    ///   the book's end, heard at `listeningSpeed`: an audiobook's speed, or
    ///   1 for a text book, whose clock already counts its words at its
    ///   speed. Headings the level filter hides stay part of the heading
    ///   before them, rather than ending it. `namedSpeed`, while the setting
    ///   names the speed, follows each length, shown and spoken ("25:03 at
    ///   2.0x"); nil leaves the lengths as they always read.
    /// - Percentage: where each heading starts, as a share of the book's
    ///   units.
    static func headingItems(
        displayed: [Heading],
        allHeadings: [Heading],
        skippedIDs: Set<String>,
        mode: HeadingDisplayMode,
        content: DocumentContent,
        clock: PlaceClock,
        listeningSpeed: Double,
        namedSpeed: ReaderTimeWording.ListeningSpeed? = nil
    ) -> [HeadingListItem] {
        // Heading offsets and totalCharacterCount use UTF-16 coordinates;
        // grapheme counts shift every later chapter after emoji/combining text.
        let chapterStartOffsets = cumulativeChapterOffsets(content.chapters.map(\.text.utf16Length))
        let totalCharacterCount = max(content.totalCharacterCount, 1)
        // A speed that is no number, or not above 0, hears lengths at 1x.
        let speed = listeningSpeed.isFinite && listeningSpeed > 0 ? listeningSpeed : 1

        let globalOffsetsByID = Dictionary(uniqueKeysWithValues: allHeadings.map { heading in
            (heading.id, chapterStartOffsets[safe: heading.chapterIndex, default: 0] + heading.characterOffset)
        })

        // Duration rows use the next heading visible under the current level
        // filter. Hidden subheadings remain part of the measured content, but
        // no longer truncate the displayed parent heading's duration.
        let nextOffsetsByID = nextDisplayedHeadingOffsets(
            displayed,
            globalOffsetsByID: globalOffsetsByID,
            totalCharacterCount: totalCharacterCount
        )

        return displayed.map { heading in
            let isSkipped = skippedIDs.contains(heading.id)
            let globalOffset = globalOffsetsByID[heading.id] ?? 0
            let start = clock.time(chapterIndex: heading.chapterIndex, characterOffset: heading.characterOffset)

            switch mode {
            case .timeEstimate:
                // To the next heading shown, found as a place, or, after the
                // last one shown, to the clock's end (`PlaceClock.end`): the
                // place of the book's total (`location(forGlobalOffset:)`) is
                // its last unit, a unit short of the end, so a last chapter
                // ending on a whole second, 25:03.0, showed as 25:02 (REV14).
                // The span is added chapter by chapter, so a whole chapter
                // lasts exactly its duration (`PlaceClock.span(from:to:)`).
                let end = nextOffsetsByID[heading.id]
                    .flatMap { $0 < totalCharacterCount ? content.location(forGlobalOffset: $0) : nil }
                    .map { PlaceClock.Place(chapterIndex: $0.chapterIndex, characterOffset: $0.localOffset) }
                    ?? clock.end
                let headingPlace = PlaceClock.Place(chapterIndex: heading.chapterIndex, characterOffset: heading.characterOffset)
                let seconds = clock.span(from: headingPlace, to: end) / speed
                return HeadingListItem(
                    heading: heading,
                    isSkipped: isSkipped,
                    infoText: ReaderTimeWording.shown(TimeFormatting.format(seconds), speed: namedSpeed),
                    accessibilitySuffix: ReaderTimeWording.spoken(TimeFormatting.spoken(seconds), speed: namedSpeed)
                )
            case .timeIntoBook:
                return HeadingListItem(
                    heading: heading,
                    isSkipped: isSkipped,
                    infoText: TimeFormatting.format(start),
                    accessibilitySuffix: "\(TimeFormatting.spoken(start)) in"
                )
            case .percentage:
                let percent = min(Double(globalOffset) / Double(totalCharacterCount) * 100.0, 100.0)
                return HeadingListItem(
                    heading: heading,
                    isSkipped: isSkipped,
                    infoText: String(format: "%.1f%%", percent),
                    accessibilitySuffix: String(format: "%.1f percent", percent)
                )
            }
        }
    }

    /// Rebuild the rows if what their times depend on differs from what
    /// they were built with. Only the rows change: the focus request and the
    /// current-heading badge stay where they are, and each row keeps its
    /// heading's ID as its identity.
    private func rebuildHeadingItemsIfTimingChanged() {
        if RowTiming(of: viewModel) != builtTiming {
            rebuildHeadingItems()
        }
    }

    private func rebuildHeadingItems() {
        let startedAt = CFAbsoluteTimeGetCurrent()
        // Note the timing first, so every way into a rebuild keeps it current.
        builtTiming = RowTiming(of: viewModel)
        headingItems = makeHeadingItems()
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
        voiceOverFocusLog("rebuilt headings items in \(String(format: "%.3f", elapsed))s")
    }

    /// Distinct heading levels present in this document (sorted), for building the filter picker
    private var headingLevelsPresent: [Int] {
        Self.levelsPresent(in: shown.value.headings)
    }

    /// Where each chapter starts, in UTF-16 code units: the counts before
    /// it, together.
    private static func cumulativeChapterOffsets(_ counts: [Int]) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(counts.count)
        var runningTotal = 0
        for count in counts {
            offsets.append(runningTotal)
            runningTotal += count
        }
        return offsets
    }

}

/// One row of the headings sheet: a button that goes to its heading, whose
/// VoiceOver label speaks the heading, its level, whether it is skipped or
/// being read, and its time or percentage. Its VoiceOver actions and its
/// context menu offer the same commands under the same names: Go To, and
/// Skip Section or Include Section, as a bookmark's row offers its own
/// (TODO A10; until then skipping was in the context menu alone).
///
/// Equatable on what it shows, never on its actions (PERF30): when the
/// playback cursor crosses into another heading the sheet draws again, and
/// of its rows only the two whose badge moves draw again with it.
private struct HeadingNavigatorRow: View, Equatable {
    /// The heading and what the row says about it.
    let item: HeadingNavigatorView.HeadingListItem
    /// Whether the playback cursor is in this heading.
    let isCurrent: Bool
    /// Whether this row takes the sheet's one-time VoiceOver focus request.
    let isInitialFocusTarget: Bool
    /// Goes to the heading and closes the sheet.
    let goTo: () -> Void
    /// Skips the heading's section, or includes it again.
    let toggleSkip: () -> Void

    /// Whether two rows show the same thing: everything but the actions.
    nonisolated static func == (lhs: HeadingNavigatorRow, rhs: HeadingNavigatorRow) -> Bool {
        lhs.item == rhs.item
            && lhs.isCurrent == rhs.isCurrent
            && lhs.isInitialFocusTarget == rhs.isInitialFocusTarget
    }

    var body: some View {
        let _ = ViewBodyCounter.record("HeadingNavigatorRow")
        let row = HeadingRow(
            heading: item.heading,
            isCurrent: isCurrent,
            isSkipped: item.isSkipped,
            infoText: item.infoText
        )
        Button(action: goTo) {
            row
                .padding(.horizontal)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.accessibilityDescription(isCurrent: isCurrent))
        .accessibilityHint(row.accessibilityHintText)
        // Preserve the semantic selected state while the label controls
        // exactly where VoiceOver speaks the human-readable "current heading"
        // status.
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        .accessibilityActions { commands }
        // This is the sole initial VoiceOver focus mechanism. It targets the
        // current heading when possible, while remaining fixed if playback
        // later advances into another heading.
        .modifier(InitialVoiceOverFocusModifier(
            isTarget: isInitialFocusTarget,
            delay: 0.2
        ))
        .contextMenu { commands }
    }

    /// The row's commands, its VoiceOver actions and its context menu
    /// alike: Go To, then Skip Section, or Include Section for a section
    /// already skipped (`HeadingRow.commandTitles(isSkipped:)`).
    @ViewBuilder
    private var commands: some View {
        let titles = HeadingRow.commandTitles(isSkipped: item.isSkipped)
        Button(titles.goTo, action: goTo)
        Button(titles.toggleSkip, action: toggleSkip)
    }
}

/// The headings sheet's only input is its reader (PERF30).
extension HeadingNavigatorView: SheetOverOneReader {}

struct HeadingRow: View {
    let heading: Heading
    let isCurrent: Bool
    var isSkipped: Bool = false
    let infoText: String

    var body: some View {
        HStack {
            if isSkipped {
                Image(systemName: "forward.fill")
                    .font(.caption2)
                    .foregroundColor(.orange)
                    .accessibilityLabel(HeadingNavigatorView.skippedMarkLabel)
            }

            Text(heading.text)
                .font(fontForLevel(heading.level))
                .fontWeight(heading.level <= 2 ? .bold : .regular)
                .padding(.leading, CGFloat((heading.level - 1) * 16))
                .strikethrough(isSkipped, color: .secondary)

            Spacer()

            // Info column based on display mode
            Text(infoText)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(minWidth: 60, alignment: .trailing)

            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundColor(.accentColor)
                    .accessibilityLabel(HeadingNavigatorView.currentMarkLabel)
            }
        }
        .opacity(isSkipped ? 0.5 : 1.0)
    }

    /// What VoiceOver says the row's button does: its result, never a
    /// gesture or a menu to open, since VoiceOver, a braille display, and
    /// the keyboard each do it their own way; skipping is among the row's
    /// VoiceOver actions (TODO A10; it said "Double-tap to navigate. Use
    /// context menu to skip or include this section.").
    var accessibilityHintText: String {
        // Translators: Hint of a heading's row in the headings list: what choosing it does.
        InterfaceText.line("common.goesToThisHeadingAndCloses", "Goes to this heading and closes the list.")
    }

    /// The names of a heading row's commands, its VoiceOver actions and its
    /// context menu items: Go To, and Skip Section, or Include Section for
    /// a section that `isSkipped`.
    nonisolated static func commandTitles(isSkipped: Bool) -> (goTo: String, toggleSkip: String) {
        (
            // Translators: Name of a heading row's command that goes to the heading, as a VoiceOver action and a context menu item.
            InterfaceText.line("common.goTo", "Go To"),
            isSkipped
                // Translators: Name of a heading row's command that stops skipping the section, as a VoiceOver action and a context menu item.
                ? InterfaceText.line("headingRow.commandTitles.include", "Include Section")
                // Translators: Name of a heading row's command that makes speech skip the section, as a VoiceOver action and a context menu item.
                : InterfaceText.line("headingRow.commandTitles.skip", "Skip Section")
        )
    }

    private func fontForLevel(_ level: Int) -> Font {
        switch level {
        case 1: return .title3
        case 2: return .headline
        case 3: return .subheadline
        default: return .body
        }
    }
}

private extension Array {
    subscript(safe index: Int, default fallback: Element) -> Element {
        indices.contains(index) ? self[index] : fallback
    }
}
