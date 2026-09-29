import SwiftUI
import Foundation

/// Case-insensitive matching shared by book search: literal text, or a
/// regular expression. Ranges are UTF-16 `NSRange`s, TextMouth's text
/// coordinate system (see `OffsetMap.swift`).
enum BookTextSearch {
    /// Every match of `query` in `text`, in reading order. An empty query
    /// matches nothing; an invalid regular expression throws.
    static func ranges(in text: String, query: String, useRegex: Bool) throws -> [NSRange] {
        guard let matcher = try Matcher(query: query, useRegex: useRegex) else { return [] }
        var ranges: [NSRange] = []
        matcher.enumerateRanges(in: text) { range in
            ranges.append(range)
            return true
        }
        return ranges
    }

    /// A query compiled once, so a search across many chapters parses its
    /// regular expression a single time, and whose matching can stop early:
    /// at a result limit, or when the search is cancelled.
    struct Matcher {
        /// The compiled form of a non-empty query.
        private enum Pattern {
            case literal(String)
            case regex(NSRegularExpression)
        }

        private let pattern: Pattern

        /// Compile `query`, or return nil for an empty query, which matches
        /// nothing. Throws when `useRegex` is set and `query` is not a valid
        /// regular expression.
        init?(query: String, useRegex: Bool) throws {
            guard !query.isEmpty else { return nil }
            pattern = useRegex
                ? .regex(try NSRegularExpression(pattern: query, options: [.caseInsensitive]))
                : .literal(query)
        }

        /// Report each match in `text` to `visit`, in reading order, until
        /// `visit` returns false, `shouldStop` returns true, or the text ends.
        ///
        /// How promptly a stop request is heard:
        /// - Literal text: before each lookup. One lookup scans only as far as
        ///   the next match, which takes tens of milliseconds even across a
        ///   whole plain-text book held as a single chapter.
        /// - Regular expression: `.reportProgress` makes Foundation call the
        ///   block periodically during long-running matching, not only when a
        ///   match is found. ICU calls back between match attempts and from
        ///   inside a long backtracking attempt, so even a runaway pattern
        ///   normally stops promptly.
        ///
        /// Known limitation: how often Foundation calls back is undocumented,
        /// so a single pathological match attempt (catastrophic backtracking)
        /// is not guaranteed to be interruptible mid-backtrack. The interface
        /// stays responsive regardless: searches run off the main actor, and
        /// a search superseded by a newer query is cancelled and its results
        /// are discarded.
        func enumerateRanges(
            in text: String,
            shouldStop: () -> Bool = { false },
            visit: (NSRange) -> Bool
        ) {
            let fullRange = NSRange(location: 0, length: text.utf16Length)
            switch pattern {
            case .regex(let regex):
                // Progress callbacks arrive without a result; like every
                // match, each one is a chance to stop.
                regex.enumerateMatches(in: text, options: [.reportProgress], range: fullRange) { result, _, stop in
                    if shouldStop() {
                        stop.pointee = true
                    } else if let result, !visit(result.range) {
                        stop.pointee = true
                    }
                }

            case .literal(let query):
                let nsText = text as NSString
                var remaining = fullRange
                while remaining.length > 0, !shouldStop() {
                    let match = nsText.range(of: query, options: [.caseInsensitive], range: remaining)
                    guard match.location != NSNotFound, visit(match) else { return }
                    // Resume after the match, always moving forward so the
                    // loop ends even if a lookup ever returned an empty range.
                    let nextLocation = max(NSMaxRange(match), match.location + 1)
                    remaining = NSRange(location: nextLocation, length: fullRange.length - nextLocation)
                }
            }
        }
    }
}

/// One match found by book search: where it is, and what its result row
/// shows and speaks.
struct BookSearchResult: Identifiable, Equatable, Sendable {
    /// Stable across searches and view refreshes, so a result row and its
    /// "Search Results" rotor entry keep their identity while results update.
    var id: String { "\(chapterIndex):\(characterOffset):\(matchedText.utf16Length)" }
    /// Content unit (chapter) holding the match.
    let chapterIndex: Int
    /// UTF-16 offset of the match within its content unit.
    let characterOffset: Int
    let matchedText: String
    /// The match with up to 30 characters of context on each side.
    let contextSnippet: String
    /// UTF-16 offset of the match from the start of the book.
    let globalOffset: Int
    /// Heading containing the match, or nil when there is none to name.
    var locationTitle: String?

    /// The matching context, then where it is: the rotor entry, and the
    /// start of the row's spoken label.
    var contextAndLocation: String {
        [contextSnippet, locationTitle].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The parts of an open book that a search reads. All are immutable value
/// copies, so a search can run off the main actor while the reader changes.
struct BookSearchCorpus: Sendable {
    let chapterTexts: [String]
    let chapterTitles: [String]
    /// Every heading in the book, used to name where each match is.
    let headings: [Heading]
    /// The book's title, so a content title that merely repeats it is not
    /// offered as a match's location.
    let bookTitle: String
}

/// What one completed search found.
enum BookSearchOutcome: Equatable, Sendable {
    /// Matches in reading order. `isTruncated` is true when the book holds
    /// more matches than the result limit, so only the first ones are listed.
    case matches([BookSearchResult], isTruncated: Bool)
    /// The query is not a valid regular expression; the text says why.
    case invalidPattern(String)
}

/// Searches a whole book. Synchronous and free of shared state, so it can
/// run off the main actor, and cancellable through `isCancelled`.
enum BookSearchEngine {
    /// The most matches one search lists. A broader query yields more rows
    /// than anyone would review one at a time; stopping here also bounds the
    /// work, memory, and rows that a query such as "e" would otherwise cost.
    static let resultLimit = 2_000

    /// Search every chapter of `corpus` for `query`, in reading order.
    /// - Throws: `CancellationError` once `isCancelled` returns true. A
    ///   cancelled search reports nothing, never a partial result.
    static func search(
        query: String,
        useRegex: Bool,
        in corpus: BookSearchCorpus,
        limit: Int = resultLimit,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> BookSearchOutcome {
        let matcher: BookTextSearch.Matcher
        do {
            guard let compiled = try BookTextSearch.Matcher(query: query, useRegex: useRegex) else {
                return .matches([], isTruncated: false)
            }
            matcher = compiled
        } catch {
            return .invalidPattern(error.localizedDescription)
        }

        let collected = try collectResults(
            in: corpus.chapterTexts,
            limit: limit,
            isCancelled: isCancelled
        ) { chapterText, visit in
            matcher.enumerateRanges(in: chapterText, shouldStop: isCancelled, visit: visit)
        }

        // Matches were collected in reading order; name each by its heading.
        var results = collected.results
        let locationTitles = BookSearchView.locationTitles(
            of: results.map { (chapterIndex: $0.chapterIndex, characterOffset: $0.characterOffset) },
            headings: corpus.headings,
            chapterTitles: corpus.chapterTitles,
            bookTitle: corpus.bookTitle
        )
        for index in results.indices {
            results[index].locationTitle = locationTitles[index]
        }
        return .matches(results, isTruncated: collected.isTruncated)
    }

    /// Turn each chapter's matches into results, in reading order, keeping
    /// at most `limit` of them. `enumerateMatches` reports one chapter's
    /// match ranges to a visitor that returns false once it wants no more.
    /// Kept apart from `search` so tests can count the chapters visited.
    /// - Throws: `CancellationError` once `isCancelled` returns true, checked
    ///   before each chapter and after the last one.
    static func collectResults(
        in chapterTexts: [String],
        limit: Int,
        isCancelled: () -> Bool,
        enumerateMatches: (_ chapterText: String, _ visit: (NSRange) -> Bool) -> Void
    ) throws -> (results: [BookSearchResult], isTruncated: Bool) {
        var results: [BookSearchResult] = []
        var isTruncated = false
        // UTF-16 offset where the current chapter starts within the book.
        var chapterStart = 0

        for (chapterIndex, chapterText) in chapterTexts.enumerated() {
            if isCancelled() { throw CancellationError() }

            enumerateMatches(chapterText) { match in
                // A range with no String equivalent is skipped, exactly as
                // before, and never counts toward the limit.
                guard let matchRange = Range(match, in: chapterText) else { return true }
                // Finding one more result than the limit is what proves the
                // list is truncated; nothing further needs to be found.
                guard results.count < limit else {
                    isTruncated = true
                    return false
                }
                results.append(BookSearchResult(
                    chapterIndex: chapterIndex,
                    characterOffset: match.location,
                    matchedText: String(chapterText[matchRange]),
                    contextSnippet: contextSnippet(in: chapterText, around: matchRange),
                    globalOffset: chapterStart + match.location
                ))
                return true
            }

            if isTruncated { break }
            chapterStart += chapterText.utf16Length
        }

        // Cancellation may have cut the final chapter's scan short; what it
        // found must not be reported as the complete answer.
        if isCancelled() { throw CancellationError() }
        return (results, isTruncated)
    }

    /// The match with up to 30 characters of context on each side, marking
    /// with "..." any text cut off before or after.
    private static func contextSnippet(in text: String, around matchRange: Range<String.Index>) -> String {
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

struct BookSearchView: View {
    let chapterTexts: [String]
    let chapterTitles: [String]
    /// Every heading in the book, used to name where each match is.
    let headings: [Heading]
    /// The book's title, so a content title that merely repeats it is not
    /// offered as a match's location.
    let bookTitle: String
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

    /// Name each match's location by the heading containing it, using the
    /// same rule and fallback as the reader header. Matches should arrive in
    /// reading order, as a search produces them, so one sweep serves them all.
    /// Nonisolated because `BookSearchEngine` calls it off the main actor.
    nonisolated static func locationTitles(
        of matches: [(chapterIndex: Int, characterOffset: Int)],
        headings: [Heading],
        chapterTitles: [String],
        bookTitle: String
    ) -> [String?] {
        var sweep = HeadingSweep(headings: headings)
        return matches.map { match in
            let contentTitle = chapterTitles.indices.contains(match.chapterIndex)
                ? chapterTitles[match.chapterIndex]
                : nil
            return sweep.position(chapterIndex: match.chapterIndex, characterOffset: match.characterOffset)
                .title(contentTitle: contentTitle, bookTitle: bookTitle)
        }
    }

    private enum SearchOutcome {
        case empty
        case results([BookSearchResult])
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
                Button("Back to Book") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityHint("Close search and return to the book")
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
                            // A native button exposes the same activation to
                            // keyboard, VoiceOver, braille, and pointer users.
                            Button {
                                onNavigate(result.chapterIndex, result.characterOffset)
                                dismiss()
                            } label: {
                                SearchResultRow(
                                    result: result,
                                    displayMode: displayMode,
                                    totalCharacterCount: totalCharacterCount,
                                    totalWordCount: totalWordCount,
                                    currentWPM: currentWPM
                                )
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                        }
                    }
                }
                .accessibilityLabel("\(results.count) \(results.count == 1 ? "match" : "matches") found")
                .accessibilityRotor("Search Results") {
                    ForEach(results) { result in
                        AccessibilityRotorEntry(result.contextAndLocation, id: result.id)
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

        // Nothing cancels this synchronous search, so it never throws.
        let corpus = BookSearchCorpus(
            chapterTexts: chapterTexts,
            chapterTitles: chapterTitles,
            headings: headings,
            bookTitle: bookTitle
        )
        guard let outcome = try? BookSearchEngine.search(
            query: searchText,
            useRegex: useRegex,
            in: corpus,
            isCancelled: { false }
        ) else { return .empty }

        switch outcome {
        case .matches(let results, _):
            return results.isEmpty ? .empty : .results(results)
        case .invalidPattern(let message):
            return .regexError("Invalid regex: \(message)")
        }
    }
}

private struct SearchResultRow: View {
    let result: BookSearchResult
    let displayMode: BookSearchView.DisplayMode
    let totalCharacterCount: Int
    let totalWordCount: Int
    let currentWPM: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(result.contextSnippet)
                .font(.body)
                .lineLimit(2)

            HStack {
                if let locationTitle = result.locationTitle {
                    Text(locationTitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(positionText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(minWidth: 60, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Activate to navigate to this result")
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

    /// Spoken row label: the context and location, then the position in the
    /// selected display mode.
    private var accessibilityDescription: String {
        switch displayMode {
        case .percentage:
            return "\(result.contextAndLocation), at \(String(format: "%.1f percent", percentage)) of book"
        case .time:
            return "\(result.contextAndLocation), at \(TimeFormatting.spoken(timeInSeconds)) into book"
        }
    }
}
