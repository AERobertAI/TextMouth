import SwiftUI

struct HeadingNavigatorView: View {
    /// Static metadata for one heading row. Crucially does NOT include the
    /// "currently reading" flag — that's tracked separately via
    /// `currentHeadingID` so a moving playback cursor doesn't force the
    /// whole list and accessibility hierarchy to be rebuilt (and VoiceOver
    /// focus to be lost) on every word spoken.
    struct HeadingListItem: Identifiable {
        let heading: Heading
        let isSkipped: Bool
        let infoText: String
        let accessibilityDescription: String

        var id: String { heading.id }
    }

    /// Shared row/rotor label format so VoiceOver speaks heading names before
    /// structural level and optional status details.
    static func accessibilityDescription(
        text: String,
        level: Int,
        isSkipped: Bool = false,
        suffix: String = ""
    ) -> String {
        let skipPrefix = isSkipped ? "Skipped, " : ""
        let base = "\(skipPrefix)\(text) - level \(level)"
        return suffix.isEmpty ? base : "\(base), \(suffix)"
    }

    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var displayMode: HeadingDisplayMode = .timeEstimate
    @State private var maxHeadingLevel: Int = 6
    // Cache the rendered heading metadata in state so sheet presentation does
    // not repeatedly recompute timing/accessibility strings on the main thread.
    @State private var headingItems: [HeadingListItem] = []
    /// The id of the heading the playback cursor is currently inside. Updated
    /// independently of `headingItems` so the only thing that re-renders when
    /// the cursor advances within a heading is the speaker-icon badge — the
    /// full list (and its VoiceOver focus state) stays put.
    @State private var currentHeadingID: String?
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

    var body: some View {
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

                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
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
                        Text("All").tag(6)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Heading level filter")
                    .accessibilityHint("Show only headings up to this level")
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
            }

            Divider()

            if viewModel.headings.isEmpty {
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
                        ForEach(Array(headingItems.enumerated()), id: \.element.id) { index, item in
                            // `isCurrent` is derived inline so updates to the
                            // playback cursor only redraw the speaker badge,
                            // not the whole list.
                            let isCurrent = item.heading.id == currentHeadingID
                            let row = HeadingRow(
                                heading: item.heading,
                                isCurrent: isCurrent,
                                isSkipped: item.isSkipped,
                                infoText: item.infoText
                            )

                            Button {
                                viewModel.navigateToHeading(item.heading)
                                dismiss()
                            } label: {
                                row
                                    .padding(.horizontal)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(item.accessibilityDescription)
                            .accessibilityHint(row.accessibilityHintText)
                            .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
                            // This is the sole initial VoiceOver focus
                            // mechanism. It posts a one-time accessibility
                            // notification without persistently binding the
                            // first row as the keyboard focus target.
                            .modifier(FirstItemFocusModifier(isFirst: index == 0, delay: 0.2))
                            .contextMenu {
                                Button("Go To") {
                                    viewModel.navigateToHeading(item.heading)
                                    dismiss()
                                }
                                Button(item.isSkipped ? "Include Section" : "Skip Section") {
                                    viewModel.toggleHeadingSkip(item.heading)
                                }
                            }
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
        .navigationTitle("Headings: \(viewModel.book.title)")
        .accessibilityLabel("Headings, \(headingItems.count) \(headingItems.count == 1 ? "heading" : "headings")")
        .onAppear {
            rebuildHeadingItems()
            currentHeadingID = computedCurrentHeadingID()
            voiceOverFocusLog("headings sheet appeared with \(headingItems.count) rows")
        }
        .onChange(of: displayMode) { _, _ in
            rebuildHeadingItems()
        }
        .onChange(of: maxHeadingLevel) { _, _ in
            rebuildHeadingItems()
            // The filter scope changed — the cursor's heading may have just
            // been filtered out (or back in). Recompute now so the badge
            // is correct immediately, instead of waiting for the next
            // playback tick to repair the state via updateCurrentHeadingIDIfChanged.
            currentHeadingID = computedCurrentHeadingID()
        }
        .onChange(of: viewModel.headings) { _, _ in
            rebuildHeadingItems()
            // Heading list changed entirely — the cached current id may be
            // stale (e.g. the heading was renamed/removed), recompute.
            currentHeadingID = computedCurrentHeadingID()
        }
        // Position-driven changes never rebuild the list. They only update
        // the lightweight `currentHeadingID` state — which feeds the inline
        // `isCurrent` check in the ForEach. The list's identity, scroll
        // position, and VoiceOver focus all stay put. Crossing a heading
        // boundary updates a single row's speaker badge; cursor movement
        // within a heading is a no-op.
        .onChange(of: viewModel.displayChapterIndex) { _, _ in
            updateCurrentHeadingIDIfChanged()
        }
        .onChange(of: viewModel.displayCharacterOffset) { _, _ in
            updateCurrentHeadingIDIfChanged()
        }
        .onChange(of: viewModel.book.skippedHeadingIDs ?? []) { _, _ in
            rebuildHeadingItems()
        }
    }

    private var filteredHeadings: [Heading] {
        viewModel.headings.filter { $0.level <= maxHeadingLevel }
    }

    private func makeHeadingItems() -> [HeadingListItem] {
        let filtered = filteredHeadings
        let skippedIDs = viewModel.skippedHeadingIDs

        guard let content = viewModel.content else {
            return filtered.map { heading in
                let isSkipped = skippedIDs.contains(heading.id)
                return HeadingListItem(
                    heading: heading,
                    isSkipped: isSkipped,
                    infoText: "",
                    accessibilityDescription: describeHeading(heading, isSkipped: isSkipped, suffix: "")
                )
            }
        }

        let chapterStartOffsets = cumulativeChapterOffsets(content.chapters.map(\.text.count))
        let allHeadings = viewModel.headings
        let totalCharacterCount = max(content.totalCharacterCount, 1)
        let totalWordCount = content.totalWordCount
        let totalReadingTime = content.estimatedReadingTime(wpm: viewModel.speechService.wordsPerMinute)

        let globalOffsetsByID = Dictionary(uniqueKeysWithValues: allHeadings.map { heading in
            (heading.id, chapterStartOffsets[safe: heading.chapterIndex, default: 0] + heading.characterOffset)
        })

        var nextOffsetsByID: [String: Int] = [:]
        for (index, heading) in allHeadings.enumerated() {
            if index + 1 < allHeadings.count {
                let nextHeading = allHeadings[index + 1]
                nextOffsetsByID[heading.id] = globalOffsetsByID[nextHeading.id] ?? totalCharacterCount
            } else {
                nextOffsetsByID[heading.id] = totalCharacterCount
            }
        }

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
                    accessibilityDescription: describeHeading(heading, isSkipped: isSkipped, suffix: TimeFormatting.spoken(seconds))
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
                    accessibilityDescription: describeHeading(heading, isSkipped: isSkipped, suffix: "\(TimeFormatting.spoken(seconds)) in")
                )
            case .percentage:
                let percent = min(Double(globalOffset) / Double(totalCharacterCount) * 100.0, 100.0)
                return HeadingListItem(
                    heading: heading,
                    isSkipped: isSkipped,
                    infoText: String(format: "%.1f%%", percent),
                    accessibilityDescription: describeHeading(
                        heading,
                        isSkipped: isSkipped,
                        suffix: String(format: "%.1f percent", percent)
                    )
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

    /// Compute which heading the playback cursor is currently inside, scoped
    /// to the visible filter level. Used to drive the inline `isCurrent`
    /// check on each row without rebuilding the cached `headingItems`.
    private func computedCurrentHeadingID() -> String? {
        currentHeadingID(in: filteredHeadings)
    }

    /// Update `currentHeadingID` only when the cursor has actually crossed a
    /// heading boundary. The throttled display offset still advances during
    /// playback, but the vast majority of those updates land inside the same
    /// heading and produce no change here, so SwiftUI doesn't re-render
    /// anything. When the cursor does cross into a new heading, exactly
    /// two rows redraw (the previous and new "currently reading" rows).
    private func updateCurrentHeadingIDIfChanged() {
        let newID = computedCurrentHeadingID()
        if newID != currentHeadingID {
            currentHeadingID = newID
        }
    }

    /// Distinct heading levels present in this document (sorted), for building the filter picker
    private var headingLevelsPresent: [Int] {
        Array(Set(viewModel.headings.map { $0.level })).sorted()
    }

    private func currentHeadingID(in headings: [Heading]) -> String? {
        headings.last(where: {
            $0.chapterIndex < viewModel.displayChapterIndex ||
            ($0.chapterIndex == viewModel.displayChapterIndex && $0.characterOffset <= viewModel.displayCharacterOffset)
        })?.id
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

    private func describeHeading(_ heading: Heading, isSkipped: Bool, suffix: String) -> String {
        Self.accessibilityDescription(
            text: heading.text,
            level: heading.level,
            isSkipped: isSkipped,
            suffix: suffix
        )
    }
}

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
