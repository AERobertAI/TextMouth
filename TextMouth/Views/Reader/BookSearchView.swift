import SwiftUI
import Foundation

enum BookTextSearch {
    static func ranges(in text: String, query: String, useRegex: Bool) throws -> [NSRange] {
        guard !query.isEmpty else { return [] }
        let fullRange = NSRange(location: 0, length: text.utf16Length)
        if useRegex {
            let regex = try NSRegularExpression(pattern: query, options: [.caseInsensitive])
            return regex.matches(in: text, range: fullRange).map(\.range)
        }

        let nsText = text as NSString
        var results: [NSRange] = []
        var remaining = fullRange
        while remaining.length > 0 {
            let match = nsText.range(of: query, options: [.caseInsensitive], range: remaining)
            guard match.location != NSNotFound else { break }
            results.append(match)
            let nextLocation = NSMaxRange(match)
            remaining = NSRange(location: nextLocation, length: fullRange.length - nextLocation)
        }
        return results
    }
}

struct BookSearchView: View {
    let chapterTexts: [String]
    let chapterTitles: [String]
    let totalCharacterCount: Int
    let totalWordCount: Int
    let currentWPM: Double
    let onNavigate: (Int, Int) -> Void  // chapterIndex, characterOffset
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var useRegex = false
    @State private var displayMode: DisplayMode = .percentage
    @FocusState private var isSearchFieldFocused: Bool
    enum DisplayMode: String, CaseIterable {
        case percentage = "Percentage"
        case time = "Time"

        var accessibilityLabel: String {
            switch self {
            case .percentage: return "Show percentage through book"
            case .time: return "Show estimated time into book"
            }
        }
    }

    fileprivate struct SearchResult: Identifiable {
        let id = UUID()
        let chapterIndex: Int
        let characterOffset: Int
        let matchedText: String
        let contextSnippet: String
        let globalOffset: Int
    }

    private enum SearchOutcome {
        case empty
        case results([SearchResult])
        case regexError(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Search in Book")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityLabel("Close search")
            }
            .padding()

            // Search field and options
            VStack(spacing: 8) {
                TextField("Search text", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFieldFocused)
                    .accessibilityLabel("Search text")
                    .accessibilityHint("Type to search within the book")
                    .accessibilityIdentifier(voiceOverFocusID)
                    .background(VoiceOverFocus(delay: 1.2))

                HStack {
                    Toggle("Use Regex", isOn: $useRegex)
                        .toggleStyle(.checkbox)
                        .accessibilityLabel("Use regular expression")
                        .accessibilityHint("When enabled, search text is treated as a regular expression")

                    Spacer()

                    Picker("Display", selection: $displayMode) {
                        ForEach(DisplayMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .accessibilityLabel("Position display mode")
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            // Results
            switch searchOutcome {
            case .empty:
                if searchText.isEmpty {
                    Text("Enter a search term above.")
                        .foregroundColor(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("No results found.")
                        .foregroundColor(.secondary)
                        .padding()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("No results found for \(searchText)")
                }

            case .regexError(let message):
                Text(message)
                    .foregroundColor(.red)
                    .font(.callout)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Regex error: \(message)")

            case .results(let results):
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(results) { result in
                            SearchResultRow(
                                result: result,
                                displayMode: displayMode,
                                chapterTitle: chapterTitles[result.chapterIndex],
                                totalCharacterCount: totalCharacterCount,
                                totalWordCount: totalWordCount,
                                currentWPM: currentWPM
                            )
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onNavigate(result.chapterIndex, result.characterOffset)
                                dismiss()
                            }
                            .accessibilityAction(.default) {
                                onNavigate(result.chapterIndex, result.characterOffset)
                                dismiss()
                            }
                            Divider()
                        }
                    }
                }
                .accessibilityLabel("\(results.count) \(results.count == 1 ? "match" : "matches") found")
                .accessibilityRotor("Search Results") {
                    ForEach(results) { result in
                        AccessibilityRotorEntry(
                            "\(result.contextSnippet), \(chapterTitles[result.chapterIndex])",
                            id: result.id
                        )
                    }
                }
            }
        }
        .frame(width: 500, height: 450)
        .navigationTitle("Search in Book")
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                isSearchFieldFocused = true
            }
        }
    }

    private var searchOutcome: SearchOutcome {
        guard !searchText.isEmpty else { return .empty }

        var results: [SearchResult] = []
        var cumulativeCount = 0

        for (chapterIndex, chapterText) in chapterTexts.enumerated() {
            let nsMatches: [NSRange]
            do {
                nsMatches = try BookTextSearch.ranges(
                    in: chapterText,
                    query: searchText,
                    useRegex: useRegex
                )
            } catch {
                return .regexError("Invalid regex: \(error.localizedDescription)")
            }

            for nsMatch in nsMatches {
                guard let matchRange = Range(nsMatch, in: chapterText) else { continue }
                let characterOffset = nsMatch.location
                let globalOffset = cumulativeCount + characterOffset
                let snippet = buildContextSnippet(text: chapterText, matchRange: matchRange)

                results.append(SearchResult(
                    chapterIndex: chapterIndex,
                    characterOffset: characterOffset,
                    matchedText: String(chapterText[matchRange]),
                    contextSnippet: snippet,
                    globalOffset: globalOffset
                ))
            }

            cumulativeCount += chapterText.utf16Length
        }

        return results.isEmpty ? .empty : .results(results)
    }

    private func buildContextSnippet(text: String, matchRange: Range<String.Index>) -> String {
        let beforeStart = text.index(matchRange.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
        let afterEnd = text.index(matchRange.upperBound, offsetBy: 30, limitedBy: text.endIndex) ?? text.endIndex

        let prefix = beforeStart > text.startIndex ? "..." : ""
        let suffix = afterEnd < text.endIndex ? "..." : ""

        let before = String(text[beforeStart..<matchRange.lowerBound])
        let matched = String(text[matchRange])
        let after = String(text[matchRange.upperBound..<afterEnd])

        return "\(prefix)\(before)\(matched)\(after)\(suffix)"
    }
}

private struct SearchResultRow: View {
    let result: BookSearchView.SearchResult
    let displayMode: BookSearchView.DisplayMode
    let chapterTitle: String
    let totalCharacterCount: Int
    let totalWordCount: Int
    let currentWPM: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.contextSnippet)
                .font(.body)
                .lineLimit(2)

            HStack {
                Text(chapterTitle)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text(positionText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 60, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Double-tap to navigate to this result")
    }

    private var percentage: Double {
        guard totalCharacterCount > 0 else { return 0 }
        return Double(result.globalOffset) / Double(totalCharacterCount) * 100
    }

    private var timeInSeconds: TimeInterval {
        guard totalCharacterCount > 0, currentWPM > 0 else { return 0 }
        let fraction = Double(result.globalOffset) / Double(totalCharacterCount)
        let totalSeconds = (Double(totalWordCount) / currentWPM) * 60
        return fraction * totalSeconds
    }

    private var positionText: String {
        switch displayMode {
        case .percentage:
            return String(format: "%.1f%%", percentage)
        case .time:
            return TimeFormatting.format(timeInSeconds)
        }
    }

    private var accessibilityDescription: String {
        switch displayMode {
        case .percentage:
            return "\(result.contextSnippet), \(chapterTitle), at \(String(format: "%.1f percent", percentage)) of book"
        case .time:
            return "\(result.contextSnippet), \(chapterTitle), at \(TimeFormatting.spoken(timeInSeconds)) into book"
        }
    }
}
