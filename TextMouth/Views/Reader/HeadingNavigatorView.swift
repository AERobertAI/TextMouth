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

    /// What the sheet shows of its reader, which it follows instead of the
    /// whole reader (PERF30): the book's title, its headings, the sections
    /// skipped, and the heading the reading position is in under each level
    /// filter. While a book plays its position moves eight times a second,
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
        }
    }

    /// The deepest heading level the level filter offers; its "All" choice
    /// shows every heading up to this level.
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
        let skipPrefix = isSkipped ? "Skipped, " : ""
        let currentSuffix = isCurrent ? " (current heading)" : ""
        let base = "\(skipPrefix)\(text)\(currentSuffix) - level \(level)"
        return suffix.isEmpty ? base : "\(base), \(suffix)"
    }

    static func filteredHeadings(_ headings: [Heading], maximumLevel: Int) -> [Heading] {
        headings.filter { $0.level <= maximumLevel }
    }

    static func levelsPresent(in headings: [Heading]) -> [Int] {
        Array(Set(headings.map(\.level))).sorted()
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
    /// The row that receives the sheet's one-time accessibility focus request.
    /// Keep this separate from `currentHeadingID`: playback may cross into a
    /// new section while the sheet is open, but it must not steal VoiceOver
    /// focus from whichever control the user is currently exploring.
    @State private var initialFocusHeadingID: String?
    enum HeadingDisplayMode: String, CaseIterable {
        case timeEstimate = "Duration"
        case timeIntoBook = "Time In"
        case percentage = "Percentage"

        var accessibilityLabel: String {
            switch self {
            case .timeEstimate: return "Show estimated duration for each heading"
            case .timeIntoBook: return "Show time into book where each heading starts"
            case .percentage: return "Show percentage through book for each heading"
            }
        }
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
                Text("Headings")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()

                Picker("Display", selection: $displayMode) {
                    ForEach(HeadingDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 280)
                .accessibilityLabel("Heading info display mode")

                Button("Back to Book") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityHint("Close the headings screen and return to the book")
            }
            .padding()

            // Heading level filter
            if headingLevelsPresent.count > 1 {
                HStack(spacing: 8) {
                    Text("Show levels:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("Max level", selection: $maxHeadingLevel) {
                        ForEach(headingLevelsPresent, id: \.self) { level in
                            Text("H1–H\(level)").tag(level)
                        }
                        Text("All").tag(Self.deepestFilterLevel)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Heading level filter")
                    .accessibilityHint("Show only headings up to this level")
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
            }

            Divider()

            if shown.value.headings.isEmpty {
                Text("No headings found in this document.")
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
                .accessibilityRotor("Heading Levels") {
                    ForEach(filteredHeadings) { heading in
                        AccessibilityRotorEntry(
                            Self.accessibilityDescription(text: heading.text, level: heading.level),
                            id: heading.id
                        )
                    }
                }
            }
        }
        .frame(width: 550, height: 500)
        .navigationTitle("Headings: \(shown.value.title)")
        .accessibilityLabel("Headings, \(CountWording.phrase(headingItems.count, singular: "heading", plural: "headings"))")
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
        let filtered = filteredHeadings
        let skippedIDs = shown.value.skippedHeadingIDs

        guard let content = viewModel.content else {
            return filtered.map { heading in
                let isSkipped = skippedIDs.contains(heading.id)
                return HeadingListItem(
                    heading: heading,
                    isSkipped: isSkipped,
                    infoText: "",
                    accessibilitySuffix: ""
                )
            }
        }

        // Heading offsets and totalCharacterCount use UTF-16 coordinates;
        // grapheme counts shift every later chapter after emoji/combining text.
        let chapterStartOffsets = cumulativeChapterOffsets(content.chapters.map(\.text.utf16Length))
        let allHeadings = shown.value.headings
        let totalCharacterCount = max(content.totalCharacterCount, 1)
        let totalWordCount = content.totalWordCount
        let totalReadingTime = content.estimatedReadingTime(wpm: viewModel.speechService.wordsPerMinute)

        let globalOffsetsByID = Dictionary(uniqueKeysWithValues: allHeadings.map { heading in
            (heading.id, chapterStartOffsets[safe: heading.chapterIndex, default: 0] + heading.characterOffset)
        })

        // Duration rows use the next heading visible under the current level
        // filter. Hidden subheadings remain part of the measured content, but
        // no longer truncate the displayed parent heading's duration.
        let nextOffsetsByID = Self.nextDisplayedHeadingOffsets(
            filtered,
            globalOffsetsByID: globalOffsetsByID,
            totalCharacterCount: totalCharacterCount
        )

        return filtered.map { heading in
            let isSkipped = skippedIDs.contains(heading.id)
            let globalOffset = globalOffsetsByID[heading.id] ?? 0
            let nextOffset = nextOffsetsByID[heading.id] ?? totalCharacterCount

            switch displayMode {
            case .timeEstimate:
                let charCount = max(nextOffset - globalOffset, 0)
                let seconds: TimeInterval
                if viewModel.isAudioBook {
                    seconds = Double(charCount) / ReaderViewModel.audioCharsPerSecond / viewModel.audioSpeed
                } else if totalWordCount > 0, viewModel.speechService.wordsPerMinute > 0 {
                    let wordEstimate = Double(charCount) / Double(totalCharacterCount) * Double(totalWordCount)
                    seconds = wordEstimate / viewModel.speechService.wordsPerMinute * 60.0
                } else {
                    seconds = 0
                }
                return HeadingListItem(
                    heading: heading,
                    isSkipped: isSkipped,
                    infoText: TimeFormatting.format(seconds),
                    accessibilitySuffix: TimeFormatting.spoken(seconds)
                )
            case .timeIntoBook:
                let seconds: TimeInterval
                if viewModel.isAudioBook {
                    seconds = Double(globalOffset) / ReaderViewModel.audioCharsPerSecond / viewModel.audioSpeed
                } else if viewModel.speechService.wordsPerMinute > 0 {
                    let fraction = Double(globalOffset) / Double(totalCharacterCount)
                    seconds = totalReadingTime * fraction
                } else {
                    seconds = 0
                }
                return HeadingListItem(
                    heading: heading,
                    isSkipped: isSkipped,
                    infoText: TimeFormatting.format(seconds),
                    accessibilitySuffix: "\(TimeFormatting.spoken(seconds)) in"
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

    private func rebuildHeadingItems() {
        let startedAt = CFAbsoluteTimeGetCurrent()
        headingItems = makeHeadingItems()
        let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
        voiceOverFocusLog("rebuilt headings items in \(String(format: "%.3f", elapsed))s")
    }

    /// Distinct heading levels present in this document (sorted), for building the filter picker
    private var headingLevelsPresent: [Int] {
        Self.levelsPresent(in: shown.value.headings)
    }

    private func cumulativeChapterOffsets(_ counts: [Int]) -> [Int] {
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
/// being read, and its time or percentage; its context menu goes to the
/// heading or skips its section.
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
        // This is the sole initial VoiceOver focus mechanism. It targets the
        // current heading when possible, while remaining fixed if playback
        // later advances into another heading.
        .modifier(InitialVoiceOverFocusModifier(
            isTarget: isInitialFocusTarget,
            delay: 0.2
        ))
        .contextMenu {
            Button("Go To", action: goTo)
            Button(item.isSkipped ? "Include Section" : "Skip Section", action: toggleSkip)
        }
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
                    .accessibilityLabel("Skipped")
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
                    .accessibilityLabel("Currently reading")
            }
        }
        .opacity(isSkipped ? 0.5 : 1.0)
    }

    var accessibilityHintText: String {
        "Double-tap to navigate. Use context menu to skip or include this section."
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
