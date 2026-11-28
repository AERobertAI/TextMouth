# Searching the whole library's text (November 13, 2026)

You are `libsearch`, an Opus lead. Your branch is `feature/library-search`, made at local main. First read `common.md` beside this brief and follow it.

## The user's words

On November 13, 2026:

> "I want ful and effeicent and fast library text search to find strings in books (with options for case insynth and regex) the regex time I understand won't be super fast, but I do want the straight string ignore case or not to take 5 seconds or less on my whole library, you have my permission to test non changing code on my actual library when building."

## The user's library

Measured read-only by the orchestrator on November 13: 750 books have a `content.md`, 676.7 MB of text in all, the largest 28.8 MB; the whole data directory is 11 GB with its audio. It is local, at `~/.TextMouth` (its books in `~/.TextMouth/Library/<folder>/<book>.tmb/`).

## What the permission allows, exactly

This is the orchestrator's reading of the user's permission, and you follow it to the letter:
- You may run code that **only reads** the user's library, to measure your search's speed and check its results: a small benchmark harness or a command-line build of your search code, pointed at `~/.TextMouth`.
- It opens files read-only and **writes nothing anywhere under `~/.TextMouth`**: no cache, no index, no lock file, no file coordination that writes, no saved setting. Any index or cache your design keeps is built, in a measurement, under `build/orchestrator/libsearch/`, never in the library.
- **Never launch TextMouth itself, or the test host, against it**: the app writes its library as it opens it.
- Run each measurement through `run_locked.py`, so nothing heavy runs beside it, and run it again for a second, warm reading.
- **Copy nothing out of it.** No title, author, or text of the user's books goes into a commit, a test, a fixture, a log you keep, a report, or a message: report counts, sizes, and timings only. Delete nothing (no `rm` at all).
- Everything else in the live-library rule stands, and no test in the suite may touch it.

## What exists

- **Search in Book** (Command-F): `BookSearchEngine`, `BookSearchResult`, `BookSearchCorpus`, `BookSearchView`, and `SearchResultRow` in `TextMouth/Views/Reader/BookSearchView.swift`, with `BookSearchModel` in `TextMouth/ViewModels/BookSearchModel.swift` (debounce, cancellation by generation, a status VoiceOver reads). It is always case-insensitive, has a "Use regular expression" switch (`NSRegularExpression` with `.caseInsensitive`), searches the reader's chapter texts, keeps 500 results at most (`resultLimit`), and shows 30 characters of context; a transcript is searched by time (`BookSearchTiming`). The iPhone has its own sheet over the same engine (`Phone/PhoneBookSearch.swift`, `Platform/iOS/Views/Reader/PhoneSearchSheet.swift`).
- **The text:** each text book's text cache is `content.md`, its text as Markdown (a transcribed audiobook's is its transcript), described in `docs/architecture/state/text-caches.md`. `BookContentAnalysisService.load` parses it into `DocumentContent`, splitting it into chapters (`MarkdownCacheService.splitChapters(_:)`); find exactly how the reader's chapter texts, which Search in Book searches and whose offsets the cursor uses, are made from it.
- **Opening a book at a place:** a reader claims requests waiting for its book as it loads, or at once when it is already open (`TextMouth/Services/ReaderRequestStore.swift`, as the reading list's `ReadingListOpenRequests` and the autoplay requests do). Search in Book's `choose(_:)` moves the cursor to a result.
- **The library in the cloud:** a book whose files are not downloaded must not be fetched by a search (`docs/architecture/state/cloud-state.md`).

## Required behavior

1. **A Search Library command** in the menus (the Edit menu's Find submenu, or the Library's own menu, whichever fits the app's menus; say which), with a shortcut that collides with nothing in the shortcut registry, reachable from the Library window and from a reader window. It opens a window or sheet with:
   - a search field;
   - **Match Case** (off by default: the search ignores case) and **Regular Expression** (off by default);
   - a status VoiceOver reads ("Searching 750 books…", "212 matches in 31 books", "No matches", an invalid pattern's reason, and how many books in the cloud weren't searched);
   - the results, grouped by book: each book with its match count, and each match with its context and where it is (the chapter or heading's title).
2. **Activating a match opens its book at that match**, in its reader (opening the window, or switching an open one to it, as opening from the Library does), with the cursor on the match. Say what Go Back does in the reader after that.
3. **Speed.** A plain search, with Match Case on or off, takes **5 seconds or less on the user's library**, from the moment the search starts to its last result, including the time to read the files when they are not in memory: measure a first run after a while idle and a second, and report both. A regular expression may take longer, but shows progress and stops at once on Cancel or a new query.
4. **Exactness.** A match the library search lists is found at the same place by Search in Book in that book, for the same query and options, and the counts agree, apart from cases you name in the design. Search in Book gains Match Case too, through the same engine (DRY: one matcher, one place for case folding and context), keeping its default.
5. **Memory.** The search never holds the whole library's text at once: bound what it keeps, and report its peak in a measurement.
6. **Results without end.** A common word ("the") must not stall the app or produce a list VoiceOver can't get through: cap matches per book and in all, say so in the status, and offer the rest (for instance "Show all matches in this book", or opening the book's own Search in Book with the query).
7. **Accessibility.** Each result row speaks the book's title, the match in its context, and where it is; the keyboard reaches everything (the field, both options, the results, opening a result, Escape to close); the results' count is spoken when a search ends, once.
8. **The iPhone** keeps compiling (`make typecheck-ios` at 0 errors). An iPhone version of the screen is a follow-up; keep the engine in shared code so it can come later.

## Design, before code

Write `LIBRARY-SEARCH-RESEARCH-2026-11-13.md` in the repository root (stage it with `git add -f`; this is the one Markdown file you edit), with your measurements, then build it. Decide, and say why:
- **What is searched:** the raw `content.md`, whose Markdown marks (emphasis, headings, links, escapes) can split a phrase and add characters the reader never shows, or a plain text the reader's chapters are made of, kept beside `content.md` or built when first needed. If you keep a file of your own in each book's package, it is a stored format: it needs `OnDiskContractTests`, an older TextMouth must be unharmed by it, and it must stay in step with Edit Text and every rebuild of `content.md`. A cache outside the library is the other way; say which, with the cost of each in time and disk on the user's library.
- **How case is ignored:** with full Unicode (Search in Book's NSString search with `.caseInsensitive` is the reference), and how fast. A byte-level search (memchr or a two-way or Boyer-Moore search over UTF-8) is fast for a plain search with Match Case on; ignoring case needs folding that keeps offsets you can map back.
- **How work is spread:** files read in parallel on the Mac's cores (four performance and four efficiency), memory-mapped or in chunks, a match that crosses a chunk's edge, and results published to the main actor in batches.
- **How a match's place is found in the reader:** an offset into the chapter text, the match's number within the book, or a search again in the reader for the same query; the place must be right after Edit Text or a rebuild.
- **What the window looks like** to VoiceOver, its title, and where the results go when the window closes and opens again.

## Tests

- The matcher: ASCII and Unicode case folding against Search in Book's results (accents, ß, Turkish dotted I, Greek final sigma, combining marks), Match Case on and off, regular expressions and an invalid one, a match across a chunk's edge, an empty file, a file not valid UTF-8, a book in the cloud.
- Exactness: for synthetic books (Markdown with emphasis, headings, links, escapes, and a transcript), the library search's matches equal Search in Book's, with the same counts.
- Speed: a performance test on a synthetic library made by the test (sized for a fast suite, never the user's library), whose time per megabyte is pinned loosely, so the hosted suite stays quick and steady; the real library's numbers go in the report.
- Opening a result moves the reader's cursor to the match, in a book already open and in one that isn't.
- Cancel and a new query stop the old search, and its results never land after the new one's.

## Workers

You may launch up to three Sonnet workers at once with the Agent tool (`model: "sonnet"`, `effort: "high"`, `isolation: "worktree"`, `subagent_type: "general-purpose"`), each with a brief of exact files, line ranges, the mechanism, and the tests, told to read `common.md` and to branch from your branch by name. A worker who measures the user's library must have this brief's "What the permission allows" section word for word in its own brief. Review every diff before you take it.

## Your report

Follow `common.md`'s report, and add: the measurements on the user's library (cold and warm, Match Case on and off, a regular expression, the peak memory); the design's summary in ten lines; the questions for the user; and the documentation each change needs (a section of `docs/user/library-window.md` or a page of its own, `docs/user/reader-windows.md` for Search in Book's Match Case, and `docs/architecture/state/text-caches.md` for any cache).
