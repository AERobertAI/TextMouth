import SwiftUI
import Foundation

/// The words Search in Book speaks about a transcribed audiobook: what it says
/// when there is no transcript to search, where a chosen result took the
/// reader, and what Go Back says with nowhere to go back to. Kept in one
/// place so each sentence is pinned by a test.
enum BookSearchWording {
    /// Said instead of opening Search in Book for an audiobook whose
    /// transcript does not exist yet.
    static func noTranscript(bookTitle: String) -> String {
        "\(bookTitle) has no transcript to search. Transcribe it first, with Transcribe Audio."
    }

    /// Said instead of opening Search in Book for a loaded audiobook with no
    /// transcript text to search, and why, never naming a command the book
    /// does not offer:
    /// - Without a transcript, `noTranscript(bookTitle:)` names Transcribe
    ///   Audio, which a book in a package of its own (`canTranscribe`) offers;
    ///   a book that is not in one offers no command, and none is named.
    /// - With a transcript whose text is not shown, the reason is said in the
    ///   words that say it elsewhere: the cloud's (`TranscriptionWording`),
    ///   the stale transcript's and the held edit's (`BookTextEditWording`).
    ///   No command is named: the book's is then Retranscribe Audio…, which
    ///   replaces the transcript and is the cure only for a stale one, so
    ///   that reason says to transcribe it again and the others say what
    ///   to do instead. A reason the reader does not know is not guessed.
    /// - Parameters:
    ///   - bookTitle: The book's title.
    ///   - canTranscribe: Whether the book is in a package of its own, so
    ///     that it offers to transcribe its audio
    ///     (`LibraryAudioCommand.isTranscribable`).
    ///   - hasTranscript: Whether the book has a transcript, as the library's
    ///     rows and the Book menu know it (`TranscribedBooks`).
    ///   - withheld: Why its text is not shown, when the reader knows.
    ///   - offersTranscription: Whether the app can transcribe at all. The
    ///     iPhone app cannot, so it passes false, and no sentence tells the
    ///     listener to transcribe or transcribe again.
    static func noTextToSearch(
        bookTitle: String,
        canTranscribe: Bool,
        hasTranscript: Bool,
        withheld: TranscriptTextWithheld?,
        offersTranscription: Bool = true
    ) -> String {
        guard hasTranscript else {
            return canTranscribe && offersTranscription
                ? noTranscript(bookTitle: bookTitle)
                : "\(bookTitle) has no transcript to search."
        }
        let lead = "\(bookTitle) has no transcript text to search now"
        switch withheld {
        case nil:
            return lead + "."
        case .transcriptInCloud?:
            return "\(lead). \(TranscriptionWording.transcriptInCloud)"
        case .textInCloud?:
            return "\(lead). \(TranscriptionWording.textInCloud)"
        case .audioChanged?:
            let because = "\(lead), because \(BookTextEditWording.transcriptStaleReason)"
            return offersTranscription ? "\(because) Transcribe it again, then search the new transcript." : because
        case .editHeld(let refusal, let keptCopy)?:
            let why = BookTextEditWording.heldReason(refusal, forAudiobook: true)
            return "\(lead), because its edited text can't be used: \(why) \(BookTextEditWording.kept(keptCopy))"
        }
    }

    /// Said once the search sheet has closed after a result was chosen: the
    /// time the reader moved to and, when it names one, where that is.
    static func movedTo(time: TimeInterval, location: String?) -> String {
        guard let location else { return "Moved to \(TimeFormatting.spoken(time))." }
        return "Moved to \(TimeFormatting.spoken(time)), \(location)."
    }

    /// Said by Go Back in a reader that has no saved position to return to.
    static let nothingToGoBackTo = "No previous position to return to."

    /// The search field's hint when the book searched is a transcript.
    static let transcriptFieldHint = "Type to search the book's transcript"

    /// The search field's label.
    static let fieldLabel = "Search text"

    /// The search field's hint when the book searched is a text book.
    static let fieldHint = "Type to search within the book"

    /// The Use Regex switch's label.
    static let regexLabel = "Use regular expression"

    /// The Use Regex switch's hint.
    static let regexHint = "When enabled, search text is treated as a regular expression"

    /// The label of the list of results.
    static let resultsLabel = "Search results"

    /// The hint of the button that closes the sheet.
    static let backToBookHint = "Close search and return to the book"
}

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
    /// The text that matched, as it appears in the book.
    let matchedText: String
    /// The match with up to 30 characters of context on each side.
    let contextSnippet: String
    /// UTF-16 offset of the match from the start of the book.
    let globalOffset: Int
    /// Heading containing the match, or nil when there is none to name.
    var locationTitle: String?
    /// Seconds from the start of the book at which the match is heard, for a
    /// match in a transcript; nil for a text book's.
    var time: TimeInterval?

    /// The matching context, then where it is: the rotor entry, and the
    /// start of the row's spoken label.
    var contextAndLocation: String {
        [contextSnippet, locationTitle].compactMap { $0 }.joined(separator: ", ")
    }

    /// For a timed result, `contextAndLocation` and the time it is heard,
    /// spoken: the row's label and the rotor entry. Nil for an untimed one.
    var timedLabel: String? {
        time.map { "\(contextAndLocation), at \(TimeFormatting.spoken($0))" }
    }
}

/// What a search of a transcribed audiobook needs to give each match the
/// time it is heard: the transcript the chapters' texts come from, and where
/// each audio chapter begins.
struct BookSearchTiming: Sendable {
    /// The transcript whose chapter texts are searched, and whose index
    /// gives a place in a chapter's text its time.
    let transcript: TranscriptText
    /// Where each chapter begins, in seconds from the start of the book.
    let chapterStarts: [TimeInterval]

    /// Seconds from the start of the book at which the match at
    /// `characterOffset` of chapter `chapterIndex` is heard: the chapter's
    /// start (0 for a chapter outside `chapterStarts`) and the start of the
    /// sentence holding the match, which is also where a jump to it lands.
    func time(chapterIndex: Int, characterOffset: Int) -> TimeInterval {
        let start = chapterStarts.indices.contains(chapterIndex) ? chapterStarts[chapterIndex] : 0
        return start + transcript.chapterTime(atTextOffset: characterOffset, inChapter: chapterIndex)
    }

    /// The timing of `transcript` over an audiobook whose chapters are
    /// `audioChapters`. An audiobook's chapter text is spacing that counts
    /// time (`ReaderViewModel.audioCharsPerSecond` characters a second), so a
    /// chapter begins where the lengths of those before it add up.
    static func forTranscript(_ transcript: TranscriptText, audioChapters: [Chapter]) -> BookSearchTiming {
        var starts: [TimeInterval] = []
        var elapsed: TimeInterval = 0
        for chapter in audioChapters {
            starts.append(elapsed)
            elapsed += AudioBookParser.time(forCharacterOffset: chapter.text.utf16Length)
        }
        return BookSearchTiming(transcript: transcript, chapterStarts: starts)
    }
}

/// The parts of an open book that a search reads. All are immutable value
/// copies, so a search can run off the main actor while the reader changes.
struct BookSearchCorpus: Sendable {
    /// Text of each content unit (chapter), searched in reading order.
    let chapterTexts: [String]
    /// Title of each content unit, which names a match's location in a book
    /// without headings.
    let chapterTitles: [String]
    /// Every heading in the book, used to name where each match is.
    let headings: [Heading]
    /// The book's title, so a content title that merely repeats it is not
    /// offered as a match's location.
    let bookTitle: String
    /// What gives each match the time it is heard, when the book is a
    /// transcribed audiobook; nil for a text book.
    var timing: BookSearchTiming? = nil
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
    /// The sheet keeps every row it lists alive for VoiceOver (TODO A10),
    /// which costs about half a millisecond and a tenth of a megabyte a row
    /// to draw, so 500 rows draw in about a quarter of a second; 2,000, the
    /// limit until then, took over a second and some 200 megabytes.
    static let resultLimit = 500

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
            // A transcript's matches also say when they are heard.
            results[index].time = corpus.timing?.time(
                chapterIndex: results[index].chapterIndex,
                characterOffset: results[index].characterOffset
            )
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
    let totalCharacterCount: Int
    let totalWordCount: Int
    let currentWPM: Double
    let onNavigate: (Int, Int) -> Void  // chapterIndex, characterOffset
    /// Whether the book searched is a transcript, whose results are timed
    /// exactly: it shows no Display picker, and its rows give the time.
    private let isTimed: Bool
    @Environment(\.dismiss) private var dismiss

    /// Runs the searches: waits for typing to pause, works off the main
    /// actor, and reports each search's status.
    @StateObject private var model: BookSearchModel
    @State private var displayMode: DisplayMode = .percentage
    @FocusState private var isSearchFieldFocused: Bool

    /// - Parameters:
    ///   - chapterTexts: Text of each content unit, searched in order.
    ///   - chapterTitles: Title of each content unit, which names a match's
    ///     location in a book without headings.
    ///   - headings: Every heading in the book, used to name where each
    ///     match is.
    ///   - bookTitle: The book's title, so a content title that merely
    ///     repeats it is not offered as a match's location.
    ///   - announce: Speaks each completed search's status through VoiceOver.
    ///   - onNavigate: Opens a result, given its chapter index and UTF-16
    ///     character offset.
    init(
        chapterTexts: [String],
        chapterTitles: [String],
        headings: [Heading],
        bookTitle: String,
        totalCharacterCount: Int,
        totalWordCount: Int,
        currentWPM: Double,
        announce: @escaping @MainActor (String) -> Void,
        onNavigate: @escaping (Int, Int) -> Void
    ) {
        self.init(
            corpus: BookSearchCorpus(
                chapterTexts: chapterTexts,
                chapterTitles: chapterTitles,
                headings: headings,
                bookTitle: bookTitle
            ),
            totalCharacterCount: totalCharacterCount,
            totalWordCount: totalWordCount,
            currentWPM: currentWPM,
            announce: announce,
            onNavigate: onNavigate
        )
    }

    /// - Parameters:
    ///   - corpus: The book's text, titles, and headings to search, with the
    ///     timing of a transcribed audiobook's, whose results say when they
    ///     are heard.
    ///   - announce: Speaks each completed search's status through VoiceOver.
    ///   - onNavigate: Opens a result, given its chapter index and UTF-16
    ///     character offset.
    init(
        corpus: BookSearchCorpus,
        totalCharacterCount: Int,
        totalWordCount: Int,
        currentWPM: Double,
        announce: @escaping @MainActor (String) -> Void,
        onNavigate: @escaping (Int, Int) -> Void
    ) {
        self.totalCharacterCount = totalCharacterCount
        self.totalWordCount = totalWordCount
        self.currentWPM = currentWPM
        self.onNavigate = onNavigate
        isTimed = corpus.timing != nil
        // StateObject builds the model once each time the sheet opens; the
        // copies of the book passed in by later reader refreshes go unused.
        _model = StateObject(wrappedValue: BookSearchModel(corpus: corpus, announce: announce))
    }

    /// Where each result's row says its match is, as the display picker's
    /// segments name it.
    enum DisplayMode: String, CaseIterable {
        case percentage = "Percentage"
        case time = "Time"
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

    /// Open `result`, and close the sheet: what a click, Space, Return, and
    /// VoiceOver's activation of a result's row all do.
    private func choose(_ result: BookSearchResult) {
        onNavigate(result.chapterIndex, result.characterOffset)
        dismiss()
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
                    .accessibilityHint(BookSearchWording.backToBookHint)
            }
            .padding()

            // Search field, the status of its search, and options
            VStack(spacing: 8) {
                TextField("Search text", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFieldFocused)
                    .accessibilityLabel(BookSearchWording.fieldLabel)
                    .accessibilityHint(isTimed ? BookSearchWording.transcriptFieldHint : BookSearchWording.fieldHint)
                    .accessibilityIdentifier(voiceOverFocusID)
                    .background(VoiceOverFocus(delay: 1.2))

                // Plain text right after the field, which VoiceOver reads in
                // place. Each completed search also announces it, so the
                // outcome is heard without leaving the field.
                Text(model.status.text)
                    .font(.callout)
                    .foregroundColor(model.status.isError ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Toggle("Use Regex", isOn: $model.useRegex)
                        .checkboxToggleStyle()
                        .accessibilityLabel(BookSearchWording.regexLabel)
                        .accessibilityHint(BookSearchWording.regexHint)

                    Spacer()

                    // A transcript's results have their exact time, so there
                    // is no estimate to choose how to show.
                    if !isTimed {
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
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            Divider()

            // Results. When there are none, the status line says why.
            if model.results.isEmpty {
                Spacer()
            } else {
                ScrollView {
                    // Keep every result row alive while the sheet is open,
                    // as the headings and bookmarks panels do: LazyVStack
                    // recycles rows out of view, which can invalidate
                    // VoiceOver's current element and send its cursor back
                    // toward the top of a long list (TODO A10). The result
                    // limit bounds what the rows cost.
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.results) { result in
                            // A native button exposes the same activation to
                            // keyboard, VoiceOver, braille, and pointer users.
                            Button {
                                choose(result)
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
                            // A focused button presses on Space by itself.
                            // Return, which would otherwise look for a
                            // default button, chooses the result too, as it
                            // does a bookmark; a held key does not repeat.
                            .onKeyPress(keys: [.return], phases: .down) { _ in
                                choose(result)
                                return .handled
                            }
                            Divider()
                        }
                    }
                }
                // The status line above gives the count, which "N matches
                // found" here would repeat, and misstate once the result
                // limit is reached.
                .accessibilityLabel(BookSearchWording.resultsLabel)
                .accessibilityRotor("Search Results") {
                    ForEach(model.results) { result in
                        AccessibilityRotorEntry(result.timedLabel ?? result.contextAndLocation, id: result.id)
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
        // Closing the sheet stops its search, so nothing is announced after
        // it is gone.
        .onDisappear { model.cancelSearch() }
    }
}

/// One result's row: its context, where it is, and its position, shown and
/// spoken. Internal so a test can read what it says.
struct SearchResultRow: View {
    let result: BookSearchResult
    let displayMode: BookSearchView.DisplayMode
    let totalCharacterCount: Int
    let totalWordCount: Int
    let currentWPM: Double

    var body: some View {
        // Counted, so a test can tell that the list draws every row, not
        // only those in view (TODO A10).
        let _ = ViewBodyCounter.record("SearchResultRow")
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

    /// Where the row shows the match: a transcript's exact time, or the
    /// estimate in the display mode chosen.
    var positionText: String {
        if let time = result.time { return TimeFormatting.format(time) }
        switch displayMode {
        case .percentage:
            return String(format: "%.1f%%", percentage)
        case .time:
            return TimeFormatting.format(timeInSeconds)
        }
    }

    /// Spoken row label: the context and location, then the position: the
    /// exact time for a transcript's result, else the estimate in the
    /// selected display mode.
    var accessibilityDescription: String {
        if let timedLabel = result.timedLabel { return timedLabel }
        switch displayMode {
        case .percentage:
            return "\(result.contextAndLocation), at \(String(format: "%.1f percent", percentage)) of book"
        case .time:
            return "\(result.contextAndLocation), at \(TimeFormatting.spoken(timeInSeconds)) into book"
        }
    }
}
