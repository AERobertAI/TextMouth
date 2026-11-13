import Foundation

/// Runs the Search in Book sheet's searches. It waits for typing to pause,
/// runs each search off the main actor, cancels a search as soon as a newer
/// query makes it obsolete, and publishes results, a status line, and a
/// VoiceOver announcement for the latest query only.
@MainActor
final class BookSearchModel: ObservableObject {
    /// Runs one complete search with the options chosen. Called off the
    /// main actor, and expected to throw `CancellationError` once the task
    /// running it is cancelled.
    typealias Search = @Sendable (_ query: String, _ options: TextSearchOptions) throws -> BookSearchOutcome

    /// How long typing must pause before a search starts: long enough to
    /// skip the partial words of steady typing, short enough to feel
    /// immediate.
    static let debounceInterval: Duration = .milliseconds(250)

    /// What the status line says about the current query.
    enum Status: Equatable {
        /// The query is empty.
        case idle
        /// A search for the current query is waiting for typing to pause,
        /// or running.
        case searching
        /// The search finished and lists every one of its `count` matches.
        case found(count: Int)
        /// The search stopped at the result limit: `shown` matches are
        /// listed, and more exist.
        case truncated(shown: Int)
        /// The query is not a valid regular expression; the message says why.
        case invalidPattern(String)

        /// The status line's text, which VoiceOver also announces when a
        /// search completes.
        var text: String {
            switch self {
            case .idle:
                return "Enter a search term above."
            case .searching:
                return "Searching…"
            case .found(let count):
                switch count {
                case 0: return "No matches"
                case 1: return "1 match"
                default: return "\(count.formatted()) matches"
                }
            case .truncated(let shown):
                return "Showing the first \(shown.formatted()) matches; refine your search"
            case .invalidPattern(let message):
                return "Invalid regular expression: \(message)"
            }
        }

        /// Whether the status reports a problem with the query. The text
        /// says so in words; the status line also shows it in red.
        var isError: Bool {
            if case .invalidPattern = self { return true }
            return false
        }
    }

    /// The search text, bound to the search field. Every change starts over.
    @Published var query = "" {
        didSet { if query != oldValue { restartSearch() } }
    }

    /// Whether `query` is a regular expression, bound to the Use Regex
    /// checkbox. Every change starts over.
    @Published var useRegex = false {
        didSet { if useRegex != oldValue { restartSearch() } }
    }

    /// Whether a match must have the query's letters in the query's case,
    /// bound to the Match Case checkbox; off, as Search in Book always
    /// searched, so the search ignores case. Every change starts over.
    @Published var matchCase = false {
        didSet { if matchCase != oldValue { restartSearch() } }
    }

    /// The options the next search runs with: the two checkboxes.
    var options: TextSearchOptions {
        TextSearchOptions(matchCase: matchCase, isRegularExpression: useRegex)
    }

    /// Matches from the latest completed search, in reading order. They stay
    /// listed while a newer search runs, so rows do not vanish and reappear
    /// at every keystroke.
    @Published private(set) var results: [BookSearchResult] = []

    /// What the status line says.
    @Published private(set) var status: Status = .idle

    /// Counts restarts. Each search remembers the generation it began in and
    /// publishes only while that is still current, so a stale completion can
    /// never replace a newer query's results, even one that finished despite
    /// being cancelled.
    private(set) var generation = 0

    /// The pending or running search for the current generation, if any.
    /// Tests await it to observe a search finishing.
    private(set) var searchTask: Task<Void, Never>?

    private let debounceInterval: Duration
    /// Speaks each completed search's status through VoiceOver.
    private let announce: @MainActor (String) -> Void
    private let search: Search

    /// A model that searches `corpus` with `BookSearchEngine`.
    /// - Parameters:
    ///   - debounceInterval: How long typing must pause before a search
    ///     starts; the Mac's by default, and the phone's longer one.
    ///   - announce: Speaks each completed search's status through
    ///     VoiceOver.
    convenience init(
        corpus: BookSearchCorpus,
        debounceInterval: Duration = BookSearchModel.debounceInterval,
        announce: @escaping @MainActor (String) -> Void
    ) {
        self.init(debounceInterval: debounceInterval, announce: announce) { query, options in
            try BookSearchEngine.search(query: query, options: options, in: corpus)
        }
    }

    /// - Parameters:
    ///   - debounceInterval: How long typing must pause before a search starts.
    ///   - announce: Speaks each completed search's status through VoiceOver.
    ///   - search: Runs one search off the main actor. Tests pass fakes that
    ///     count, delay, or record searches.
    init(
        debounceInterval: Duration,
        announce: @escaping @MainActor (String) -> Void,
        search: @escaping Search
    ) {
        self.debounceInterval = debounceInterval
        self.announce = announce
        self.search = search
    }

    /// A search still pending when the sheet goes away has nobody to report
    /// to, so it stops too.
    deinit {
        searchTask?.cancel()
    }

    /// Stop any pending or running search without publishing anything: for
    /// when the sheet closes, so no work continues and nothing is announced
    /// for a sheet that is gone.
    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
        generation += 1
    }

    /// Start over for the current query: cancel whatever search is pending
    /// or running, then, unless the query is empty, search again once typing
    /// pauses.
    private func restartSearch() {
        cancelSearch()

        guard !query.isEmpty else {
            // Nothing to search for. Clear at once, so no results linger for
            // text that is gone.
            results = []
            status = .idle
            return
        }

        status = .searching
        let generation = generation
        let query = query
        let options = options
        let search = search
        let debounceInterval = debounceInterval
        searchTask = Task { [weak self] in
            do {
                // The debounce: the next edit cancels this task during the
                // sleep, so steady typing runs one search for the final text.
                try await Task.sleep(for: debounceInterval)
                let outcome = try await Self.runDetached { try search(query, options) }
                self?.publish(outcome, generation: generation)
            } catch {
                // Cancelled by a newer edit or by the sheet closing. Searches
                // throw nothing else, so there is nothing to show.
            }
        }
    }

    /// Show a finished search's outcome and announce its status, but only if
    /// it still belongs to the latest query.
    private func publish(_ outcome: BookSearchOutcome, generation: Int) {
        guard generation == self.generation else { return }
        searchTask = nil
        switch outcome {
        case .matches(let matches, let isTruncated):
            results = matches
            status = isTruncated ? .truncated(shown: matches.count) : .found(count: matches.count)
        case .invalidPattern(let message):
            results = []
            status = .invalidPattern(message)
        }
        announce(status.text)
    }

    /// Run `work` on a detached task, off the main actor, passing on the
    /// caller's cancellation. A detached task does not inherit cancellation;
    /// without the handler, a superseded search would run to the end.
    private nonisolated static func runDetached(
        _ work: @escaping @Sendable () throws -> BookSearchOutcome
    ) async throws -> BookSearchOutcome {
        let task = Task.detached(priority: .userInitiated) { try work() }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
