import SwiftUI

struct HeadingNavigatorView: View {
    @ObservedObject var viewModel: ReaderViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var displayMode: HeadingDisplayMode = .timeEstimate
    @State private var maxHeadingLevel: Int = 6

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
                List(filteredHeadings) { heading in
                    HeadingRow(
                        heading: heading,
                        isCurrent: isCurrentHeading(heading),
                        isSkipped: viewModel.isHeadingSkipped(heading),
                        displayMode: displayMode,
                        viewModel: viewModel
                    )
                    .onTapGesture {
                        viewModel.navigateToHeading(heading)
                        dismiss()
                    }
                    .accessibilityAction(.default) {
                        viewModel.navigateToHeading(heading)
                        dismiss()
                    }
                    .contextMenu {
                        Button("Go To") {
                            viewModel.navigateToHeading(heading)
                            dismiss()
                        }
                        Button(viewModel.isHeadingSkipped(heading) ? "Include Section" : "Skip Section") {
                            viewModel.toggleHeadingSkip(heading)
                        }
                    }
                }
                .accessibilityRotor("Heading Levels") {
                    ForEach(filteredHeadings) { heading in
                        AccessibilityRotorEntry(
                            "\(heading.text) - level \(heading.level)",
                            id: heading.id
                        )
                    }
                }
            }
        }
        .frame(width: 550, height: 500)
        .accessibilityLabel("Headings, \(filteredHeadings.count) \(filteredHeadings.count == 1 ? "heading" : "headings")")
    }

    private var filteredHeadings: [Heading] {
        viewModel.headings.filter { $0.level <= maxHeadingLevel }
    }

    /// Distinct heading levels present in this document (sorted), for building the filter picker
    private var headingLevelsPresent: [Int] {
        Array(Set(viewModel.headings.map { $0.level })).sorted()
    }

    private func isCurrentHeading(_ heading: Heading) -> Bool {
        // Find the last heading at or before the current position — only that one is "current"
        let currentID = filteredHeadings.last(where: {
            $0.chapterIndex < viewModel.currentChapterIndex ||
            ($0.chapterIndex == viewModel.currentChapterIndex && $0.characterOffset <= viewModel.currentCharacterOffset)
        })?.id
        return heading.id == currentID
    }
}

struct HeadingRow: View {
    let heading: Heading
    let isCurrent: Bool
    var isSkipped: Bool = false
    let displayMode: HeadingNavigatorView.HeadingDisplayMode
    let viewModel: ReaderViewModel

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
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Double-tap to navigate. Use context menu to skip or include this section.")
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    private var infoText: String {
        switch displayMode {
        case .timeEstimate:
            return TimeFormatting.format(viewModel.timeEstimateForHeading(heading))
        case .timeIntoBook:
            return TimeFormatting.format(viewModel.timeToHeading(heading))
        case .percentage:
            return String(format: "%.1f%%", viewModel.percentAtHeading(heading))
        }
    }

    private var accessibilityDescription: String {
        // Format: "heading name - level N, info" for fast screen reader scanning
        let skipPrefix = isSkipped ? "Skipped, " : ""
        let base = "\(skipPrefix)\(heading.text) - level \(heading.level)"
        switch displayMode {
        case .timeEstimate:
            return "\(base), \(TimeFormatting.spoken(viewModel.timeEstimateForHeading(heading)))"
        case .timeIntoBook:
            return "\(base), \(TimeFormatting.spoken(viewModel.timeToHeading(heading))) in"
        case .percentage:
            return "\(base), \(String(format: "%.1f percent", viewModel.percentAtHeading(heading)))"
        }
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
