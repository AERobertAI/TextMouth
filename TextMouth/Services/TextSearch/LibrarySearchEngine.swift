import Foundation
import os

// MARK: - What a Search Reads

/// One book Search Library reads, as the library's row describes it: what
/// the search needs to find its text without asking the main actor again.
struct LibrarySearchBook: Sendable, Identifiable, Equatable {
    /// The book's ID.
    let id: UUID
    /// Its title, which its results speak, and which a book of one chapter
    /// without headings gives its chapter.
    let title: String
    /// Its author, as the library shows it.
    let author: String
    /// Its content.md: its reading text as Markdown, or a transcribed
    /// audiobook's transcript.
    let contentURL: URL
    /// Its package folder, which a cloud library can hold only in the
    /// cloud; nil for an old book without a package of its own.
    let packageURL: URL?
    /// Whether it is an audiobook, whose text is its transcript.
    let isAudiobook: Bool

    /// The book with these fields; tests make their own.
    init(id: UUID, title: String, author: String, contentURL: URL, packageURL: URL?, isAudiobook: Bool) {
        self.id = id
        self.title = title
        self.author = author
        self.contentURL = contentURL
        self.packageURL = packageURL
        self.isAudiobook = isAudiobook
    }

    /// The search's view of `book`, a library row: its content.md and its
    /// package, where the reader finds them.
    init(_ book: Book) {
        self.init(
            id: book.id,
            title: book.title,
            author: book.author,
            contentURL: MarkdownCacheService.cacheURL(for: book),
            packageURL: book.tmbDirectoryName.isEmpty ? nil : book.tmbDirectory,
            isAudiobook: book.format.isAudio
        )
    }
}

// MARK: - How Much a Search Keeps

/// How much a search keeps of each book's matches: the first matches with
/// their context, and a count that stops past a limit, so a common word
/// costs no more than a rare one once each book has shown enough.
struct LibrarySearchLimits: Sendable, Equatable {
    /// How many of a book's matches are kept with their context, in reading
    /// order.
    var keptPerBook: Int
    /// How many of a book's matches are counted: a book with more says so
    /// (`LibrarySearchBookResult.countReachedLimit`) and is read no further.
    var countedPerBook: Int

    /// The limits of a search of the whole library: a hundred matches kept,
    /// of which the window lists the first ones (`LibrarySearchModel`), and
    /// a thousand counted.
    static let library = LibrarySearchLimits(keptPerBook: 100, countedPerBook: 1_000)

    /// The limits of Show All Matches in a book: as many as Search in Book
    /// lists (`BookSearchEngine.resultLimit`), each kept.
    static let wholeBook = LibrarySearchLimits(
        keptPerBook: BookSearchEngine.resultLimit,
        countedPerBook: BookSearchEngine.resultLimit
    )
}

// MARK: - What a Search Found

/// What a search found in one book: its count and its first matches, each
/// with where it is, exactly as Search in Book finds them in that book.
struct LibrarySearchBookResult: Sendable, Identifiable, Equatable {
    /// The book's ID.
    var id: UUID { book.id }
    /// The book.
    let book: LibrarySearchBook
    /// The book's place in the list the search was given, which orders the
    /// results however the books finish.
    let order: Int
    /// How many matches the book holds, up to the limit counted
    /// (`LibrarySearchLimits.countedPerBook`).
    let matchCount: Int
    /// Whether the book holds more matches than `matchCount`, the limit.
    let countReachedLimit: Bool
    /// The first matches, in reading order, at most the limit kept, each
    /// with its context and the heading or chapter it is in.
    let matches: [BookSearchResult]
}

/// What a search has done so far, book by book: how many books it searched,
/// how many it found matches in, and why it searched those it did not.
struct LibrarySearchTally: Sendable, Equatable {
    /// The books the search was given.
    var booksGiven = 0
    /// The books searched, those prepared on the way included.
    var booksSearched = 0
    /// The books searched whose text the search first had to prepare, by
    /// parsing their content.md (`LibrarySearchTextStore`).
    var booksPrepared = 0
    /// The books that hold at least one match.
    var booksWithMatches = 0
    /// The matches counted, each book's up to its limit.
    var matches = 0
    /// The books whose count reached its limit, so that `matches` is a
    /// lower bound.
    var booksPastTheLimit = 0
    /// The books not searched because their text is only in the cloud:
    /// reading it would download it.
    var booksInCloud = 0
    /// The books without a text to search: an audiobook not transcribed, or
    /// a book whose text was never extracted.
    var booksWithoutText = 0
    /// The books whose text could not be read.
    var booksUnreadable = 0

    /// The books the search has finished with, searched or not.
    var booksDone: Int {
        booksSearched + booksInCloud + booksWithoutText + booksUnreadable
    }
}

/// How a search ended.
enum LibrarySearchOutcome: Equatable, Sendable {
    /// Every book was searched or passed over, as the tally says.
    case finished(LibrarySearchTally)
    /// The search was cancelled before it finished; nothing it found counts.
    case cancelled
    /// The query is not a valid regular expression; the text says why.
    case invalidPattern(String)
}

// MARK: - The Engine

/// Searches the text of many books at once (LIBRARY-SEARCH-RESEARCH-2026-11-13.md):
/// each book's reading text, read from this Mac's search texts
/// (`LibrarySearchTextStore`), or parsed from its content.md and kept there
/// when the search texts do not hold it as it is now.
///
/// - **Exactly what Search in Book finds.** The chapters searched are the
///   reader's, from the same parse, and every match is found by the matcher
///   Search in Book uses (`BookTextSearch.Matcher`), over the whole chapter
///   with the same calls, its context by the same function
///   (`BookTextSearch.contextSnippet`), and where it is by the same rule
///   (`BookSearchView.locationTitles`). For a literal query, a chapter's
///   bytes are first looked over (`LibrarySearchPrefilter`), which passes
///   over a chapter none of whose lines can hold a match and changes nothing
///   found.
/// - **Spread over the Mac's cores.** Books are searched in parallel on
///   Dispatch's threads, never in Swift's concurrency pool, which has one
///   thread a core and must stay free for the rest of the app: a plain
///   search on every core, a regular expression, or a literal one that must
///   search whole chapters, on at most four, since each holds a chapter.
/// - **Bounded memory.** A worker holds one chapter of one book at a time,
///   and parsing a book to prepare it, which takes 5 to 22 times its
///   content.md while it runs, is let in only while the content.md being
///   parsed adds up to at most `preparingBudget` (one larger book at a time).
/// - **Never downloads.** Every read runs with dataless files left in the
///   cloud (`MaintenanceFileAccess.read`), and a book whose package or
///   content.md is in the cloud is counted, not read.
/// - **Stops at once.** `isCancelled` is asked before each book, each
///   chapter, each line searched, and inside each lookup.
enum LibrarySearchEngine {
    /// The most content.md bytes being parsed at once while books are
    /// prepared: 32 MB, one larger book alone. Parsing takes 5 to 22 times
    /// its text while it runs (`ReadingTextCache`), so this bounds the
    /// preparing's peak to some hundreds of megabytes.
    static let preparingBudget = 32 * 1_048_576

    /// The most workers a search that reads whole chapters runs: each holds
    /// a chapter, which can be tens of megabytes.
    static let wholeChapterWorkers = 4

    /// Search `books` for `query` with `options`, calling `report` from the
    /// search's threads after each book with what it found there, if
    /// anything, and the tally so far, which only grows.
    ///
    /// - Parameters:
    ///   - store: The search texts to read and keep.
    ///   - fileAccess: How books' files are reached: `live` in the app, a
    ///     fake in tests, which cannot make dataless files.
    ///   - limits: How much of each book's matches is kept and counted.
    ///   - workerCount: How many books are searched at once; by default
    ///     every core for a plain search, and fewer for one of whole chapters.
    ///   - isCancelled: Whether the search should stop; asked often.
    /// - Returns: How the search ended. Blocks until then: run it off the
    ///   main thread.
    static func search(
        query: String,
        options: TextSearchOptions,
        in books: [LibrarySearchBook],
        store: LibrarySearchTextStore,
        fileAccess: MaintenanceFileAccess = .live,
        limits: LibrarySearchLimits = .library,
        workerCount: Int? = nil,
        isCancelled: @escaping @Sendable () -> Bool,
        report: @escaping @Sendable (LibrarySearchBookResult?, LibrarySearchTally) -> Void
    ) -> LibrarySearchOutcome {
        let matcher: BookTextSearch.Matcher
        do {
            guard let compiled = try BookTextSearch.Matcher(query: query, options: options) else {
                return .finished(LibrarySearchTally(booksGiven: books.count))
            }
            matcher = compiled
        } catch {
            return .invalidPattern(error.localizedDescription)
        }
        let prefilter = LibrarySearchPrefilter(query: query, options: options)
        let cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
        let workers = max(1, min(workerCount ?? (prefilter == nil ? min(cores, wholeChapterWorkers) : cores), max(1, books.count)))

        let next = OSAllocatedUnfairLock(initialState: 0)
        let tally = OSAllocatedUnfairLock(initialState: LibrarySearchTally(booksGiven: books.count))
        let gate = PreparingGate(budget: preparingBudget)
        let reader = BookReader(matcher: matcher, prefilter: prefilter, limits: limits, store: store, fileAccess: fileAccess, gate: gate)

        DispatchQueue.concurrentPerform(iterations: workers) { _ in
            // Each worker reuses one buffer for the chapters it reads.
            var buffer: [UInt8] = []
            while !isCancelled() {
                let index = next.withLock { position -> Int in
                    defer { position += 1 }
                    return position
                }
                guard index < books.count else { return }
                let book = books[index]
                let read = reader.search(book, order: index, buffer: &buffer, isCancelled: isCancelled)
                // A book cut off by a cancel reports nothing.
                guard !isCancelled() else { return }
                let snapshot = tally.withLock { counts -> LibrarySearchTally in
                    counts.add(read)
                    return counts
                }
                report(read.result, snapshot)
            }
        }
        if isCancelled() { return .cancelled }
        return .finished(tally.withLock { $0 })
    }
}

// MARK: - One Book

/// How the search of one book ended.
fileprivate struct BookRead {
    /// Why the book was or was not searched.
    enum State {
        /// Searched, its text first prepared when `prepared` is true.
        case searched(prepared: Bool)
        /// Its package or content.md is only in the cloud.
        case inCloud
        /// It has no content.md.
        case withoutText
        /// Its content.md could not be read or is not UTF-8.
        case unreadable
    }

    var state: State
    /// What it found, when it found anything.
    var result: LibrarySearchBookResult?
}

extension LibrarySearchTally {
    /// Counts `read`, one more book done.
    fileprivate mutating func add(_ read: BookRead) {
        switch read.state {
        case .searched(let prepared):
            booksSearched += 1
            if prepared { booksPrepared += 1 }
        case .inCloud:
            booksInCloud += 1
        case .withoutText:
            booksWithoutText += 1
        case .unreadable:
            booksUnreadable += 1
        }
        if let result = read.result {
            booksWithMatches += 1
            matches += result.matchCount
            if result.countReachedLimit { booksPastTheLimit += 1 }
        }
    }
}

/// Searches one book at a time for one search: finds its text, prepares it
/// when the store does not hold it, and searches each chapter.
fileprivate struct BookReader: Sendable {
    let matcher: BookTextSearch.Matcher
    let prefilter: LibrarySearchPrefilter?
    let limits: LibrarySearchLimits
    let store: LibrarySearchTextStore
    let fileAccess: MaintenanceFileAccess
    let gate: PreparingGate

    /// Searches `book`, the `order`th the search was given, reading its
    /// chapters into `buffer`.
    func search(_ book: LibrarySearchBook, order: Int, buffer: inout [UInt8], isCancelled: () -> Bool) -> BookRead {
        // Nothing of a book in the cloud is read: not even its search text,
        // whose key could not be checked against a content.md not here.
        if let package = book.packageURL, fileAccess.isInCloud(package) {
            return BookRead(state: .inCloud)
        }
        if fileAccess.isInCloud(book.contentURL) {
            return BookRead(state: .inCloud)
        }
        guard let identity = ContentFileIdentity(of: book.contentURL) else {
            return BookRead(state: .withoutText)
        }
        let key = LibrarySearchTextKey(content: identity, bookTitle: book.title)
        var scan = BookScan(matcher: matcher, prefilter: prefilter, limits: limits)

        if let file = store.open(bookID: book.id, key: key) {
            defer { file.close() }
            var isDamaged = false
            for index in file.chapters.indices {
                guard !isCancelled() else { break }
                // A file shorter than its header says is damaged: it goes,
                // and the book is prepared again below.
                guard file.readChapter(index, into: &buffer) else {
                    isDamaged = true
                    break
                }
                let count = file.chapters[index].byteCount
                let goOn = buffer.withUnsafeBufferPointer { all in
                    scan.searchChapter(index, bytes: UnsafeBufferPointer(rebasing: all[0..<count]), text: nil, isCancelled: isCancelled)
                }
                guard goOn else { break }
                scan.endChapter(utf16Length: file.chapters[index].utf16Length)
            }
            if !isDamaged {
                return BookRead(state: .searched(prepared: false), result: scan.result(for: book, order: order, chapters: file.chapters))
            }
            store.remove(bookID: book.id)
            scan = BookScan(matcher: matcher, prefilter: prefilter, limits: limits)
        }

        guard let prepared = prepare(book, key: key) else {
            return BookRead(state: .unreadable)
        }
        if case .inCloud = prepared { return BookRead(state: .inCloud) }
        guard case .prepared(let text) = prepared else { return BookRead(state: .unreadable) }
        for (index, chapterText) in text.texts.enumerated() {
            guard !isCancelled() else { break }
            var chapter = chapterText
            let goOn = chapter.withUTF8 { bytes in
                scan.searchChapter(index, bytes: bytes, text: chapterText, isCancelled: isCancelled)
            }
            guard goOn else { break }
            scan.endChapter(utf16Length: text.chapters[index].utf16Length)
        }
        return BookRead(state: .searched(prepared: true), result: scan.result(for: book, order: order, chapters: text.chapters))
    }

    /// What preparing a book's text gave.
    enum Prepared {
        /// The book's search text, parsed from its content.md.
        case prepared(LibrarySearchTextBook)
        /// Its content.md turned out to be in the cloud.
        case inCloud
    }

    /// The search text of `book`, parsed from its content.md, whose identity
    /// was `key` when the search looked, and kept in the store under that
    /// key, unless content.md changed while it was read; nil when content.md
    /// cannot be read or is not UTF-8. Waits its turn at the gate, so few
    /// books are parsed at once.
    private func prepare(_ book: LibrarySearchBook, key: LibrarySearchTextKey) -> Prepared? {
        let size = Int(clamping: key.content.byteCount)
        gate.enter(size)
        defer { gate.leave(size) }
        let bytes: Data
        do {
            bytes = try fileAccess.read(book.contentURL) { try Data(contentsOf: book.contentURL) }
        } catch {
            return DatalessFiles.isDownloadRefusal(error) ? .inCloud : nil
        }
        guard let markdown = try? MarkdownCacheService.cacheText(from: bytes, at: book.contentURL) else { return nil }
        let chapters = MarkdownCacheService.parseMultiChapterMarkdown(
            markdown, bookTitle: book.title, bookAuthor: book.author
        ).chapters
        let text = LibrarySearchTextBook(parsed: chapters)
        // A content.md that changed while it was read is searched as read,
        // and not kept: the next search reads it again.
        if ContentFileIdentity(of: book.contentURL) == key.content {
            try? store.store(text, for: book.id, key: key)
        }
        return .prepared(text)
    }
}

// MARK: - One Book's Chapters

/// The search of one book's chapters, one after another: its count, its
/// matches kept, and where each chapter begins in the book.
fileprivate struct BookScan {
    let matcher: BookTextSearch.Matcher
    let prefilter: LibrarySearchPrefilter?
    let limits: LibrarySearchLimits
    /// The matches counted so far.
    private(set) var count = 0
    /// Whether the count went past the limit, ending the book's search.
    private(set) var reachedLimit = false
    /// The matches kept, in reading order.
    private(set) var kept: [BookSearchResult] = []
    /// Where the chapter being searched begins in the book, in UTF-16 units.
    private var chapterStart = 0

    init(matcher: BookTextSearch.Matcher, prefilter: LibrarySearchPrefilter?, limits: LibrarySearchLimits) {
        self.matcher = matcher
        self.prefilter = prefilter
        self.limits = limits
    }

    /// Searches chapter `index`, whose UTF-8 is `bytes` and whose text is
    /// `knownText` when the caller has it (it is made from the bytes when the
    /// chapter may hold a match). Returns false once the book's search is
    /// done: its count past the limit, or the search cancelled.
    mutating func searchChapter(
        _ index: Int,
        bytes: UnsafeBufferPointer<UInt8>,
        text knownText: String?,
        isCancelled: () -> Bool
    ) -> Bool {
        // Copied, so the closure below, which counts each match into this
        // scan, never overlaps a read of the scan's own properties.
        let matcher = matcher
        // A chapter none of whose lines may hold a match is passed over
        // without being decoded; any other is searched whole.
        if let prefilter {
            var mayHoldAMatch = false
            prefilter.forEachCandidateLine(in: bytes) { _ in
                mayHoldAMatch = true
                return false
            }
            guard mayHoldAMatch else { return !isCancelled() }
        }
        // The whole chapter, exactly as Search in Book searches it: the same
        // text, the same calls from its start, so the same matches.
        // Foundation's case-insensitive search does not answer a range alone
        // as it answers the same text inside a longer one (it takes a digit's
        // compatibility forms for the digit in a short range only; found on
        // November 13, LIBRARY-SEARCH-RESEARCH-2026-11-13.md, section 3), so
        // no part of a chapter is searched on its own.
        let text = knownText ?? String(decoding: bytes, as: UTF8.self)
        matcher.enumerateRanges(in: text, shouldStop: isCancelled) { match in
            record(match, in: text, chapter: index)
        }
        return !reachedLimit && !isCancelled()
    }

    /// Moves past a chapter whose text is `utf16Length` units long.
    mutating func endChapter(utf16Length: Int) {
        chapterStart += utf16Length
    }

    /// Counts `match`, a match in chapter `chapter` whose text is `text`,
    /// and keeps it while fewer than the limit are kept, exactly as Search in
    /// Book makes its result (`BookSearchEngine.collectResults`): a range
    /// with no String equivalent is passed over and never counted. Returns
    /// whether the search goes on.
    private mutating func record(_ match: NSRange, in text: String, chapter: Int) -> Bool {
        guard let matchRange = Range(match, in: text) else { return true }
        guard count < limits.countedPerBook else {
            // One more than the limit proves the count went past it.
            reachedLimit = true
            return false
        }
        count += 1
        if kept.count < limits.keptPerBook {
            kept.append(BookSearchResult(
                chapterIndex: chapter,
                characterOffset: match.location,
                matchedText: String(text[matchRange]),
                contextSnippet: BookTextSearch.contextSnippet(in: text, around: matchRange),
                globalOffset: chapterStart + match.location
            ))
        }
        return true
    }

    /// What the search found in `book`, whose chapters are `chapters`, or
    /// nil when it found nothing: the kept matches named by their headings,
    /// as Search in Book names them, or for a transcript by its chapters'
    /// titles alone, as Search in Book names a transcript's.
    func result(for book: LibrarySearchBook, order: Int, chapters: [LibrarySearchTextChapter]) -> LibrarySearchBookResult? {
        guard count > 0 else { return nil }
        let titles = BookSearchView.locationTitles(
            of: kept.map { (chapterIndex: $0.chapterIndex, characterOffset: $0.characterOffset) },
            headings: book.isAudiobook ? [] : chapters.flatMap(\.headings),
            chapterTitles: chapters.map(\.title),
            bookTitle: book.title
        )
        var named = kept
        for index in named.indices {
            named[index].locationTitle = titles[index]
        }
        return LibrarySearchBookResult(book: book, order: order, matchCount: count, countReachedLimit: reachedLimit, matches: named)
    }
}

// MARK: - Preparing a Few Books at a Time

/// Lets books be prepared only while the content.md being parsed adds up to
/// at most a budget, so preparing many books at once never takes more
/// memory than a few. A book larger than the budget is let in alone.
fileprivate final class PreparingGate: Sendable {
    /// The bytes being parsed now, under the lock with its condition.
    private let state = OSAllocatedUnfairLock(initialState: 0)
    /// Signalled whenever a book leaves.
    private let condition = NSCondition()
    /// The most bytes let in at once.
    private let budget: Int

    /// A gate letting in `budget` bytes at once.
    init(budget: Int) {
        self.budget = budget
    }

    /// Waits until `size` bytes fit, or nothing is being parsed, and counts
    /// them in.
    func enter(_ size: Int) {
        condition.lock()
        defer { condition.unlock() }
        while true {
            let admitted = state.withLock { used -> Bool in
                guard used == 0 || used + size <= budget else { return false }
                used += size
                return true
            }
            if admitted { return }
            condition.wait()
        }
    }

    /// Counts `size` bytes out, and wakes those waiting.
    func leave(_ size: Int) {
        condition.lock()
        state.withLock { $0 -= size }
        condition.broadcast()
        condition.unlock()
    }
}
