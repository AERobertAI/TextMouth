import XCTest
import os
@testable import TextMouth

// MARK: - Fixtures

/// Synthetic books whose Markdown holds what the reader's parse reads
/// differently from its source: emphasis splitting a phrase, links, escapes,
/// entities, headings of both kinds, a table, code, quotes, lists, HTML, page
/// markers, heading annotations, and chapter markers; and the Unicode cases
/// case folding and canonical equivalence turn on: precomposed and decomposed
/// accents, ß and the capital ß, the ﬁ and ﬀ ligatures, the Turkish dotted
/// and dotless I, Greek sigmas, the Kelvin sign, the long s, combining marks,
/// emoji with modifiers, and line endings of CR LF.
private let syntheticBooks: [(title: String, markdown: String)] = [
    ("Emphasis and Links", """
    <!-- chapter: Opening -->
    # The *quick* brown fox

    The **quick** brown fox jumps over the _lazy_ dog. A [quick link](https://example.com) and \\*stars\\*.
    An entity &amp; an accent &eacute;, and `code with the quick fox`.

    <!-- chapter: Second Chapter -->
    Setext Heading
    ==============

    > The quick brown fox, quoted,
    > twice: quick brown fox.

    1. quick
    2. brown fox

    | Name | Fox |
    |------|-----|
    | quick | brown |

    <!-- heading: 2 Annotated place -->
    The fox <!-- page: 7 --> ran on. QUICK BROWN FOX. Quick Brown Fox.
    """),
    ("Unicode Folding", """
    <!-- chapter: Café -->
    Café au lait at the caf\u{E9}; CAFE\u{301} again, then plain cafe. Na\u{EF}ve and nai\u{308}ve.

    Straße, STRASSE, strasse, Stra\u{1E9E}e; the \u{FB01}ne print is fine, FINE; o\u{FB00}er offer.

    <!-- chapter: Turkish and Greek -->
    \u{130}stanbul, istanbul, ISTANBUL, \u{131}rmak, IRMAK; \u{3A3}\u{3BF}\u{3C6}\u{3AF}\u{3B1} \u{3C3}\u{3BF}\u{3C6}\u{3CC}\u{3C2}, \u{3C3}\u{3C2}\u{3A3}.

    The \u{212A}elvin sign beside k and K; the long \u{17F} in Chri\u{17F}tmas; \u{1F44D}\u{1F3FD} and \u{1F469}\u{200D}\u{1F4BB}.
    """),
    ("Digits", """
    Chapter 2 begins.\u{B9} A footnote\u{B2} and \u{2462}, \u{BD} cup or 1\u{2044}2 cup, \u{FF12} wide, \u{2488} stopped.

    The Greek question mark\u{37E} and a plain one; \u{1D7DA} in bold, \u{2185} late.
    """),
    ("Line Endings", "Windows lines\r\nend with CR LF\r\nand the fox\r\nruns at the end fox"),
    ("Single Chapter", "fox at the very start, a fox in the middle, and a last fox"),
    ("No Matches", "Nothing to find here but plain words."),
]

/// Literal queries: words, phrases a Markdown mark splits in the source,
/// punctuation, a space, single letters, and the Unicode cases.
private let literalQueries = [
    "fox", "quick brown fox", "QUICK", "the", "brown fox jumps", "&", "*", " ", "e", "a",
    "café", "cafe", "CAFÉ", "é", "\u{301}", "naïve", "straße", "STRASSE", "ss", "ß", "ﬁne", "fine", "ff",
    "İstanbul", "istanbul", "ı", "I", "σοφός", "Σ", "ς", "k", "K", "\u{212A}", "s", "christmas", "👍", "👩",
    "end fox", "fox\r", "lines", "Annotated", "7",
    "1", "2", "3", "6", "Chapter 2", "1.", ";", "\u{BD}", "1\u{2044}2", "\u{FF12}", "\u{2462}",
]

/// Regular expressions, among them one across a line feed and an invalid one.
private let regexQueries = ["fox\\b", "qu?ick", "caf.", "\\p{M}", "fox\\s+jumps", "end\\s*\\n?", "^The", "[", "e\\u0301"]

// MARK: - Engine

/// Search Library's engine: that it finds exactly what Search in Book finds
/// in each book, with the same counts, whether a book is prepared on the way
/// or read from the store; what it does with books it cannot search; and
/// that it stops when cancelled.
final class LibrarySearchEngineTests: XCTestCase {

    /// Limits high enough that nothing is cut, so every match is compared.
    private let everything = LibrarySearchLimits(keptPerBook: 100_000, countedPerBook: 100_000)

    // MARK: Exactness

    /// For every query and option, each book's matches are Search in Book's:
    /// the same chapters, offsets, matched text, context, global offsets,
    /// and places, in the same order, with the same count; on the first
    /// search, which prepares every book, and on the second, from the store.
    func testMatchesEqualSearchInBookForEverySyntheticBook() throws {
        let library = try makeLibrary(syntheticBooks)
        var compared = 0
        for pass in ["preparing", "from the store"] {
            for (queries, isRegex) in [(literalQueries, false), (regexQueries, true)] {
                for query in queries {
                    for matchCase in [false, true] {
                        let options = TextSearchOptions(matchCase: matchCase, isRegularExpression: isRegex)
                        let found = search(query, options, in: library)
                        let label = "\(pass), \(isRegex ? "regex" : "literal") \(query.debugDescription), match case \(matchCase)"
                        switch found.outcome {
                        case .invalidPattern:
                            XCTAssertThrowsError(try NSRegularExpression(pattern: query), label)
                            continue
                        case .cancelled:
                            XCTFail("\(label): cancelled")
                            continue
                        case .finished(let tally):
                            XCTAssertEqual(tally.booksSearched, library.books.count, label)
                        }
                        for (index, book) in library.books.enumerated() {
                            let expected = oracle(query, options, markdown: syntheticBooks[index].markdown, title: book.title)
                            let result = found.results[book.id]
                            XCTAssertEqual(result?.matchCount ?? 0, expected.count, "\(label), \(book.title): count")
                            XCTAssertEqual(result?.matches ?? [], expected, "\(label), \(book.title): matches")
                            compared += expected.count
                        }
                        if pass == "preparing", query == literalQueries.first, !matchCase {
                            XCTAssertEqual(found.tally?.booksPrepared, library.books.count, "the first search prepares every book")
                        }
                    }
                }
            }
        }
        XCTAssertGreaterThan(compared, 500, "the fixtures compared too few matches to mean anything")
        let second = search("fox", TextSearchOptions(), in: library)
        XCTAssertEqual(second.tally?.booksPrepared, 0, "a search after the first reads every book from the store")
    }

    /// Random chapters of letters, case pairs, accents written both ways,
    /// ligatures, digits and their compatibility forms, the special
    /// characters, and line breaks, searched for pieces of themselves with
    /// their case changed: the prefiltered search of lines finds exactly what
    /// Search in Book finds in whole chapters.
    func testThePrefilteredSearchAgreesWithSearchInBookOnRandomText() throws {
        var generator = LibrarySearchRandomNumbers(seed: 20_261_113)
        let alphabet: [String] = [
            "a", "b", "e", "f", "i", "k", "s", "t", "A", "E", "I", "K", "S", " ", " ", " ", ",", "\n", "\n", "\r\n",
            "é", "e\u{301}", "É", "ß", "ẞ", "ss", "ﬁ", "ﬀ", "fi", "İ", "ı", "i\u{307}", "\u{212A}", "ſ", "σ", "ς", "Σ",
            "\u{301}", "\u{308}", "ẗ", "ǰ", "ŉ", "\u{2BC}", "n", "’", "—", "😀", "👍🏽", "\u{AD}", "\u{200B}",
            "1", "2", "\u{B2}", "\u{2460}", "\u{2461}", "\u{BC}", "\u{2044}", "\u{FF12}", ";", "\u{37E}",
        ]
        var books: [(title: String, markdown: String)] = []
        for index in 0..<24 {
            let chapters = (0..<3).map { _ in
                (0..<Int.random(in: 40...400, using: &generator))
                    .map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }
                    .joined()
            }
            // Backslashes, stars, and other marks stay out, so each chapter
            // reads as the characters it holds.
            books.append((title: "Random \(index)", markdown: chapters.enumerated()
                .map { "<!-- chapter: Part \($0.offset) -->\n\($0.element)" }
                .joined(separator: "\n\n")))
        }
        let library = try makeLibrary(books)
        var compared = 0
        for round in 0..<120 {
            let source = books[round % books.count].markdown
            let scalars = Array(source.unicodeScalars)
            let start = Int.random(in: 0..<max(1, scalars.count - 4), using: &generator)
            let length = Int.random(in: 1...4, using: &generator)
            var query = String(String.UnicodeScalarView(scalars[start..<min(scalars.count, start + length)]))
            if round % 3 == 0 { query = query.uppercased() }
            if round % 3 == 1 { query = query.lowercased() }
            guard !query.isEmpty, !query.contains("<"), !query.contains("-") else { continue }
            for matchCase in [false, true] {
                let options = TextSearchOptions(matchCase: matchCase, isRegularExpression: false)
                let found = search(query, options, in: library)
                for (index, book) in library.books.enumerated() {
                    let expected = oracle(query, options, markdown: books[index].markdown, title: book.title)
                    XCTAssertEqual(
                        found.results[book.id]?.matches ?? [], expected,
                        "round \(round), query \(query.unicodeScalars.map { String($0.value, radix: 16) }), match case \(matchCase), \(book.title)"
                    )
                    compared += expected.count
                }
            }
        }
        XCTAssertGreaterThan(compared, 1_000, "the random rounds compared too few matches to mean anything")
    }

    // MARK: Books It Cannot Search

    /// An empty content.md is searched and holds nothing; one that is not
    /// UTF-8 is counted as unreadable; a package without one has no text; and
    /// none of them stops the search of the rest.
    func testEmptyUnreadableAndMissingTextsAreCountedApart() throws {
        let library = try makeLibrary([("Empty", ""), ("Words", "a fox"), ("Broken", "placeholder"), ("Missing", "x")])
        try Data([0x66, 0x6F, 0x78, 0xFF, 0xFE, 0x20]).write(to: (try library.book(2)).contentURL)
        try FileManager.default.removeItem(at: (try library.book(3)).contentURL)
        let found = search("fox", TextSearchOptions(), in: library)
        let tally = try XCTUnwrap(found.tally, "the search did not finish")
        XCTAssertEqual(tally.booksSearched, 2, "the empty book and the one with words are searched: \(tally)")
        XCTAssertEqual(tally.booksUnreadable, 1, "the book whose content.md is not UTF-8: \(tally)")
        XCTAssertEqual(tally.booksWithoutText, 1, "the book with no content.md: \(tally)")
        XCTAssertEqual(found.results.count, 1, "only the book with words matches")
        XCTAssertEqual(found.results[(try library.book(1)).id]?.matchCount, 1)
    }

    /// A book whose content.md, or whose package, is only in the cloud is
    /// counted and never read: nothing of it reaches the store, so no search
    /// downloads it.
    func testBooksInTheCloudAreCountedAndNeverRead() throws {
        let library = try makeLibrary([("Here", "the fox"), ("Text in the Cloud", "the fox"), ("Package in the Cloud", "the fox")])
        let cloudText = (try library.book(1)).contentURL.standardizedFileURL.path
        let cloudPackage = try XCTUnwrap((try library.book(2)).packageURL).standardizedFileURL.path
        let access = MaintenanceFileAccess(isDataless: { url in
            let path = url.standardizedFileURL.path
            return path == cloudText || path == cloudPackage
        })
        let found = search("fox", TextSearchOptions(), in: library, fileAccess: access)
        let tally = try XCTUnwrap(found.tally)
        XCTAssertEqual(tally.booksInCloud, 2, "\(tally)")
        XCTAssertEqual(tally.booksSearched, 1, "\(tally)")
        XCTAssertEqual(Set(found.results.keys), [(try library.book(0)).id])
        for book in library.books.dropFirst() {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: library.store.url(for: book.id).path),
                "\(book.title) was read into the store"
            )
        }
    }

    /// An invalid regular expression ends the search at once with its reason.
    func testAnInvalidRegularExpressionSaysWhy() throws {
        let library = try makeLibrary([("Words", "a fox")])
        let found = search("fox(", TextSearchOptions(matchCase: false, isRegularExpression: true), in: library)
        guard case .invalidPattern(let reason) = found.outcome else {
            return XCTFail("expected an invalid pattern, got \(found.outcome)")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(found.results.isEmpty)
    }

    // MARK: Limits and Cancelling

    /// A book's count stops one past the limit counted, saying so, and only
    /// the first matches up to the limit kept are kept: Search in Book's
    /// first ones.
    func testABooksCountAndKeptMatchesStopAtTheirLimits() throws {
        let markdown = String(repeating: "tick tock ", count: 50)
        let library = try makeLibrary([("Metronome", markdown)])
        let limits = LibrarySearchLimits(keptPerBook: 10, countedPerBook: 20)
        let found = search("tock", TextSearchOptions(), in: library, limits: limits)
        let result = try XCTUnwrap(found.results[(try library.book(0)).id])
        XCTAssertEqual(result.matchCount, 20)
        XCTAssertTrue(result.countReachedLimit)
        XCTAssertEqual(result.matches, Array(oracle("tock", TextSearchOptions(), markdown: markdown, title: "Metronome").prefix(10)))
        XCTAssertEqual(found.tally?.booksPastTheLimit, 1)

        let exact = search("tock", TextSearchOptions(), in: library, limits: LibrarySearchLimits(keptPerBook: 10, countedPerBook: 50))
        XCTAssertEqual(exact.results[(try library.book(0)).id]?.matchCount, 50, "exactly the limit is no more than it")
        XCTAssertEqual(exact.results[(try library.book(0)).id]?.countReachedLimit, false)
    }

    /// A search cancelled partway ends cancelled: with one worker, nothing
    /// is reported after the cancel; with several, at most the books already
    /// under way when it came, one a worker, and never the rest.
    func testACancelledSearchStopsAndReportsNothingMore() throws {
        let library = try makeLibrary((0..<40).map { ("Book \($0)", String(repeating: "the fox ran. ", count: 200)) })
        for workers in [1, 4] {
            let cancelled = OSAllocatedUnfairLock(initialState: false)
            let reports = OSAllocatedUnfairLock(initialState: 0)
            let outcome = LibrarySearchEngine.search(
                query: "fox", options: TextSearchOptions(), in: library.books, store: library.store,
                limits: everything, workerCount: workers,
                isCancelled: { cancelled.withLock { $0 } },
                report: { _, _ in
                    reports.withLock { $0 += 1 }
                    cancelled.withLock { $0 = true }
                }
            )
            XCTAssertEqual(outcome, .cancelled, "\(workers) workers")
            let reported = reports.withLock { $0 }
            XCTAssertGreaterThanOrEqual(reported, 1, "\(workers) workers")
            XCTAssertLessThanOrEqual(reported, workers, "\(workers) workers: the search went on after the cancel")
        }
    }

    /// A cancel heard just before a book is prepared stops it before its
    /// content.md is read, and one heard while it is read stops it before
    /// the parse: the book is neither parsed nor kept, and the search ends
    /// cancelled, where until November 13 a cancelled search still parsed
    /// the book it had taken (the review's finding 3). The cancel comes from
    /// the file access itself, at the very moment each check guards.
    func testACancelStopsAPreparationBeforeTheReadAndBeforeTheParse() throws {
        for moment in ["before the read", "during the read"] {
            let library = try makeLibrary([("First", "the fox"), ("Second", "the fox")])
            let first = try library.book(0)
            let second = try library.book(1)
            let secondContent = second.contentURL.standardizedFileURL.path
            let cancelled = OSAllocatedUnfairLock(initialState: false)
            let readsOfSecond = OSAllocatedUnfairLock(initialState: 0)
            let access = MaintenanceFileAccess(
                isDataless: { url in
                    // The second book's content.md is looked at for the
                    // cloud just before the book is prepared.
                    if moment == "before the read", url.standardizedFileURL.path == secondContent {
                        cancelled.withLock { $0 = true }
                    }
                    return false
                },
                refusesRead: { url in
                    if url.standardizedFileURL.path == secondContent {
                        readsOfSecond.withLock { $0 += 1 }
                        if moment == "during the read" { cancelled.withLock { $0 = true } }
                    }
                    return false
                }
            )

            let outcome = LibrarySearchEngine.search(
                query: "fox", options: TextSearchOptions(), in: library.books, store: library.store,
                fileAccess: access, limits: everything, workerCount: 1,
                isCancelled: { cancelled.withLock { $0 } },
                report: { _, _ in }
            )

            XCTAssertEqual(outcome, .cancelled, moment)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: library.store.url(for: first.id).path),
                "\(moment): the first book, searched before the cancel, was not kept"
            )
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: library.store.url(for: second.id).path),
                "\(moment): the second book was parsed and kept after the cancel"
            )
            XCTAssertEqual(
                readsOfSecond.withLock { $0 }, moment == "before the read" ? 0 : 1,
                "\(moment): reads of the second book's content.md"
            )
        }
    }

    /// A wait at the preparing gate ends as soon as its search is cancelled,
    /// letting nothing in, where until November 13 it waited for the parse
    /// ahead of it to end (the review's finding 3); uncancelled, a wait goes
    /// on until the book ahead leaves, and is then let in.
    func testAWaitAtThePreparingGateEndsOnACancel() {
        let gate = LibrarySearchPreparingGate(budget: 10)
        XCTAssertTrue(gate.enter(10, isCancelled: { false }), "an empty gate lets a book in")

        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let admitted = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let cancelledWaitEnded = expectation(description: "the cancelled wait ended")
        DispatchQueue.global().async {
            let entered = gate.enter(5, isCancelled: { cancelled.withLock { $0 } })
            admitted.withLock { $0 = entered }
            cancelledWaitEnded.fulfill()
        }
        // The waiter waits while the first book is in.
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertNil(admitted.withLock { $0 }, "a second book was let in beside a gate already full")
        cancelled.withLock { $0 = true }
        wait(for: [cancelledWaitEnded], timeout: 2)
        XCTAssertEqual(admitted.withLock { $0 }, false, "a cancelled wait was let in")

        // Uncancelled, the next book is let in once the first leaves.
        let letIn = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        let uncancelledWaitEnded = expectation(description: "the uncancelled wait ended")
        DispatchQueue.global().async {
            let entered = gate.enter(5, isCancelled: { false })
            letIn.withLock { $0 = entered }
            if entered { gate.leave(5) }
            uncancelledWaitEnded.fulfill()
        }
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertNil(letIn.withLock { $0 }, "the next book was let in before the first left")
        gate.leave(10)
        wait(for: [uncancelledWaitEnded], timeout: 5)
        XCTAssertEqual(letIn.withLock { $0 }, true, "the next book was not let in once the first left")
    }

    // MARK: The Store

    /// A book's text changed since the last search (as Edit Text changes it)
    /// is prepared again, and the search finds what it holds now.
    func testABookChangedSinceTheLastSearchIsPreparedAgain() throws {
        let library = try makeLibrary([("Changing", "the fox"), ("Steady", "the fox")])
        XCTAssertEqual(search("fox", TextSearchOptions(), in: library).tally?.booksPrepared, 2)
        try "the hound and the fox and the fox".write(to: (try library.book(0)).contentURL, atomically: true, encoding: .utf8)
        let found = search("fox", TextSearchOptions(), in: library)
        XCTAssertEqual(found.tally?.booksPrepared, 1, "only the changed book is prepared again")
        XCTAssertEqual(found.results[(try library.book(0)).id]?.matchCount, 2, "the changed book's new text is searched")
    }

    /// A store file cut short after its header (a disk that filled, a crash
    /// while it was copied) is not searched as far as it goes: it is removed,
    /// and the book is prepared again and searched whole.
    func testABookWhoseStoreFileIsCutShortIsPreparedAgain() throws {
        let markdown = "<!-- chapter: One -->\nthe fox\n\n<!-- chapter: Two -->\n" + String(repeating: "a fox ran. ", count: 400)
        let library = try makeLibrary([("Cut Short", markdown)])
        XCTAssertEqual(search("fox", TextSearchOptions(), in: library).results[(try library.book(0)).id]?.matchCount, 401)
        let file = library.store.url(for: (try library.book(0)).id)
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int)
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(size - 100))
        try handle.close()

        let found = search("fox", TextSearchOptions(), in: library)
        XCTAssertEqual(found.tally?.booksPrepared, 1, "the book with a damaged file is prepared again")
        XCTAssertEqual(found.results[(try library.book(0)).id]?.matchCount, 401, "and searched whole")
        let again = search("fox", TextSearchOptions(), in: library)
        XCTAssertEqual(again.tally?.booksPrepared, 0, "the file made again is used")
    }

    /// On a disk with less free than the app's reserve, a search keeps no
    /// search text and works from what it parsed: the same matches as with
    /// room, every book prepared, none counted unreadable, so the status says
    /// nothing new; and the next search prepares them again (the review of
    /// November 13, finding 10).
    func testOnAFullDiskTheSearchWorksFromTheParseAndKeepsNothing() throws {
        let books = [("Full One", "the fox and the fox"), ("Full Two", "<!-- chapter: A -->\na fox\n\n<!-- chapter: B -->\nno match")]
        let roomy = try makeLibrary(books)
        let full = try makeLibrary(books, space: LibrarySearchTextSpace(reserve: 1_000_000_000, freeSpace: { _ in 10_000 }))

        let withRoom = search("fox", TextSearchOptions(), in: roomy)
        let onAFullDisk = search("fox", TextSearchOptions(), in: full)

        let tally = try XCTUnwrap(onAFullDisk.tally, "the search on a full disk did not finish")
        XCTAssertEqual(tally.booksPrepared, 2, "\(tally)")
        XCTAssertEqual(tally.booksUnreadable, 0, "a book that could not be kept was counted unreadable: \(tally)")
        XCTAssertEqual(tally.matches, 3, "\(tally)")
        for index in books.indices {
            let id = try full.book(index).id
            let roomyID = try roomy.book(index).id
            XCTAssertEqual(
                onAFullDisk.results[id]?.matches.map(\.globalOffset), withRoom.results[roomyID]?.matches.map(\.globalOffset),
                "book \(index): the matches on a full disk differ from those with room"
            )
        }
        let kept = (try? FileManager.default.contentsOfDirectory(atPath: full.store.folder.path)) ?? []
        XCTAssertEqual(kept, [], "a search text was kept on a full disk")
        XCTAssertEqual(search("fox", TextSearchOptions(), in: full).tally?.booksPrepared, 2, "the next search prepares again")
    }

    // MARK: Speed

    /// A plain search of a prepared synthetic library takes no longer than a
    /// loose limit per megabyte of text, so a change that slows the search
    /// many times over fails here rather than on the user's library. The
    /// limit is the hosted Debug build's, far above the Release app's (the
    /// research document has the user's library's numbers).
    func testAPlainSearchKeepsToItsTimePerMegabyte() throws {
        let paragraph = String(repeating: "The garden window looked over the river at night, and \u{2019}twas quiet. ", count: 40)
        let book = (0..<20).map { "<!-- chapter: Part \($0) -->\n\(paragraph)\n\n\(paragraph)" }.joined(separator: "\n\n")
        let library = try makeLibrary((0..<32).map { ("Speed \($0)", book) })
        let megabytes = Double(library.books.count * book.utf8.count) / 1_048_576
        _ = search("zebra", TextSearchOptions(), in: library)

        var best = Double.infinity
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            let found = search("zebra", TextSearchOptions(), in: library)
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
            XCTAssertEqual(found.tally?.booksPrepared, 0, "the library was prepared before it was timed")
        }
        let perMegabyte = best / megabytes
        print(String(format: "PERFORMANCE: library search of %.1f MB: %.3f s, %.4f s a megabyte", megabytes, best, perMegabyte))
        XCTAssertLessThan(perMegabyte, TestMachine.allowed(0.25), "a plain search took \(best) s for \(megabytes) MB")
    }

    // MARK: Helpers

    /// A library made by the test: each book's content.md in a package of its
    /// own, a store in a folder of its own, all in the sandbox.
    private struct Library {
        let books: [LibrarySearchBook]
        let store: LibrarySearchTextStore

        /// The `index`th book, or a test failure when there is none.
        func book(_ index: Int) throws -> LibrarySearchBook {
            try XCTUnwrap(books.indices.contains(index) ? books[index] : nil, "the library has no book \(index)")
        }
    }

    /// Writes `books` as packages in a sandbox folder, with a store whose
    /// room on the disk `space` decides (the disk's own by default).
    private func makeLibrary(
        _ books: [(title: String, markdown: String)],
        space: LibrarySearchTextSpace = LibrarySearchTextSpace()
    ) throws -> Library {
        let folder = try makeSandboxDirectory("LibrarySearch")
        var made: [LibrarySearchBook] = []
        for (index, book) in books.enumerated() {
            let package = folder.appendingPathComponent("Library/Book \(index).tmb", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let content = package.appendingPathComponent("content.md")
            try Data(book.markdown.utf8).write(to: content)
            made.append(LibrarySearchBook(
                id: UUID(), title: book.title, author: "Test", contentURL: content, packageURL: package, isAudiobook: false
            ))
        }
        return Library(
            books: made,
            store: LibrarySearchTextStore(folder: folder.appendingPathComponent("Store", isDirectory: true), space: space)
        )
    }

    /// What one library search found: its outcome, its tally, and each
    /// book's result.
    private struct Found {
        var outcome: LibrarySearchOutcome
        var results: [UUID: LibrarySearchBookResult]
        var tally: LibrarySearchTally? {
            if case .finished(let tally) = outcome { return tally }
            return nil
        }
    }

    /// Searches `library` for `query` with `options`.
    private func search(
        _ query: String,
        _ options: TextSearchOptions,
        in library: Library,
        limits: LibrarySearchLimits? = nil,
        fileAccess: MaintenanceFileAccess = .live
    ) -> Found {
        let results = OSAllocatedUnfairLock(initialState: [UUID: LibrarySearchBookResult]())
        let outcome = LibrarySearchEngine.search(
            query: query, options: options, in: library.books, store: library.store,
            fileAccess: fileAccess, limits: limits ?? everything,
            isCancelled: { false },
            report: { result, _ in
                if let result { results.withLock { $0[result.book.id] = result } }
            }
        )
        return Found(outcome: outcome, results: results.withLock { $0 })
    }

    /// What Search in Book finds in the book whose content.md is `markdown`:
    /// the reader's chapters, parsed as the reader parses them, with its
    /// headings, searched by Search in Book's engine.
    private func oracle(_ query: String, _ options: TextSearchOptions, markdown: String, title: String) -> [BookSearchResult] {
        let content = MarkdownCacheService.parseMultiChapterMarkdown(markdown, bookTitle: title, bookAuthor: "Test")
        let corpus = BookSearchCorpus(
            chapterTexts: content.chapters.map(\.text),
            chapterTitles: content.chapters.map(\.title),
            headings: content.allHeadings,
            bookTitle: title
        )
        guard case .matches(let results, _) = (try? BookSearchEngine.search(
            query: query, options: options, in: corpus, limit: 100_000, isCancelled: { false }
        )) ?? .matches([], isTruncated: false) else { return [] }
        return results
    }
}

/// A generator of the same random numbers for the same seed (SplitMix64), so
/// a failure of the random rounds comes back on every run.
private struct LibrarySearchRandomNumbers: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
