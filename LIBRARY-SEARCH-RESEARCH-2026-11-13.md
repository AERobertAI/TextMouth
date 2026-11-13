# Searching the whole library's text (November 13, 2026)

The design of Search Library, written before and while it was built, with its measurements on the user's library and the questions it leaves for the user. Branch `feature/library-search` (agent `libsearch`).

## 1. What the user asked

On November 13, 2026:

> "I want ful and effeicent and fast library text search to find strings in books (with options for case insynth and regex) the regex time I understand won't be super fast, but I do want the straight string ignore case or not to take 5 seconds or less on my whole library, you have my permission to test non changing code on my actual library when building."

The orchestrator measured the library read-only that day: 750 books with a `content.md`, 676.7 MB of text, the largest 28.8 MB; 11 GB with its audio, at `~/.TextMouth`.

## 2. What is searched

**Decision: the reader's own chapter texts, kept in a cache of this Mac's own outside the library (`LibrarySearchTextStore`), made from content.md by the very parse the reader makes.**

- **Not the raw content.md.** The reader does not show content.md: it parses it (`MarkdownCacheService.parseMultiChapterMarkdown`: `splitChapters`, then swift-markdown and `PlainTextExtractor` for each chapter). Emphasis (`the *quick* brown`), links (`[text](url)`), escapes (`\*`), entities (`&amp;`), heading marks, tables (read a row at a time), and our own markers (chapter, heading, and page comments) all differ between the two. A phrase the reader shows whole can be split in content.md, and an offset into content.md is not an offset into the reader's text. Searching content.md would miss matches and place the rest wrongly.
- **Not a parse at each search.** Parsing costs about 30 ms a megabyte in the Release app (`ReadingTextCache`'s measurement), 20 seconds of processor time for 677 MB, with a transient peak of 5 to 22 times the text. That alone breaks the five seconds.
- **Not a file in each package.** A plain text beside content.md would be a stored format (`OnDiskContractTests`, and an older TextMouth must ignore it), must stay in step with Edit Text and every rebuild, would be uploaded by a cloud library to every Mac, copied by a data-directory move, and counted by the File Size sort.
- **A cache outside the library.** One file per book in `~/Library/Caches/com.textmouth.TextMouth/Search Text/` (`MachineLocalPaths.librarySearchText`), named by the book's ID: a JSON header (the producer, the key, each chapter's title, UTF-8 and UTF-16 lengths, and headings) and the chapter texts as UTF-8. A file is used only for:
  - its key: content.md's identity (`ContentFileIdentity`: size, modification and status-change times, inode, taken before the read) and the book's title, which a one-chapter book without headings gives its chapter. Edit Text, a rebuild, Redo Text Extraction, a re-read in another encoding, or a sync changes the identity, so the next search parses the book again;
  - its producer: the layout, `BookContentIndex.currentVersion`, and a digest of what the parser makes of a fixed sample holding every construct it reads (`parserFingerprint`). The reader's own `ReadingTextCache` keys on the build identity instead, which would make every installation parse the whole library again; a parser that changes any construct changes the digest, so a new build keeps the files only when its parser reads as before.
- **When it is made.** A search that finds a book's file missing or unusable parses the book's content.md (never downloading it), searches the result, and keeps it. The first search ever, and the first after a parser change, prepares every book; later searches read the cache. Measured below.
- **Its cost** on the user's library (section 8): 650.2 MB in 737 files, the size of the library's text, and 8.7 seconds for the first search ever, which prepares every book (51 seconds of processor time spread over the cores, a peak of 591 MB resident); a later search reads it in under a second.

## 3. How case is ignored, and how a match is found

**Decision: Foundation decides every match, with Search in Book's own calls over whole chapters; a byte-level prefilter only passes over the chapters that can hold none.**

- **One matcher.** `BookTextSearch.Matcher` (moved from `BookSearchView.swift` to `Services/TextSearch/BookTextSearch.swift`) is Search in Book's and Search Library's: `NSString.range(of:options:range:)` with `.caseInsensitive`, or none for Match Case, never `.literal`, so a precomposed letter and the same letter with a combining mark match each other; or an `NSRegularExpression` with `.caseInsensitive` unless case must match. One context function (`BookTextSearch.contextSnippet`, 30 Characters each side) and one rule for where a match is (`BookSearchView.locationTitles`). Search in Book gains Match Case through the same matcher, off by default.
- **What Foundation's search counts as a match.** A probe on this Mac (macOS 26.3, November 13; `semantics.swift` in the agent's scratch folder) searched the cases the matcher must agree with, ignoring case (`.caseInsensitive`) and matching it (no option):

  | Query | Text | Ignoring case | Matching case |
  |---|---|---|---|
  | STRASSE, or ss | Straße, ß | found (full case folding) | not found |
  | s | ß | not found (no part of a character) | not found |
  | fi, ffi | ﬁ, ﬃ | found | not found |
  | i | İ (dotted capital I) | not found | not found |
  | İ | i with a combining dot | found | not found |
  | ı (dotless i) and i, I | either way | not found | not found |
  | σ, Σ, ς | each other | found | not found |
  | é (precomposed) | e and a combining acute | found | found (canonical equivalence) |
  | e, or cafe | e with a combining acute, café | not found (a base inside a longer character) | not found |
  | a lone combining acute | e and a combining acute | found, at the mark | found |
  | k | the Kelvin sign | found | not found |
  | K | the Kelvin sign | found | found (it is canonically K) |
  | ſ (long s) and s | either way | found | not found |
  | a | fullwidth A or a | not found | not found |
  | don't, a b, ab | don’t, a no-break space b, a soft hyphen or a zero-width space between a and b | not found | not found |
  | 👍 | 👍🏽 (with a skin tone) | not found | not found |
  | 👩 | 👩‍💻 (a ZWJ sequence) | found, at its start | found |
  | ❤ | ❤️ (with a variation selector) | not found | not found |
  | a line feed, or a carriage return | CR LF | found, each apart | found |
  | e with two marks in one order | the same in the other order | found | found |
  | µ (micro sign), Ω (ohm sign), ⅰ, ⓐ | μ, ω, Ⅰ, Ⓐ | found | not found |
  | 𐐨 (Deseret) | 𐐀 | not found | not found |
  | ᾳ (iota subscript) | αι | not found | not found |

  So Foundation folds case fully (ß is ss) but matches no part of a character, takes no base letter for a precomposed one, ignores no character, and counts canonically equivalent spellings as one; Match Case keeps the equivalence and drops the folding.
- **The prefilter** (`LibrarySearchPrefilter`). A literal query that holds no line feed or carriage return can match no line feed, so every match lies within one line. The query's anchor, its longest run of ASCII characters none of which stands beside a non-ASCII one (below), is matched by Foundation either by the same bytes, letters in either case when case is ignored, or by text holding one of the few non-ASCII characters Foundation can match against ASCII alone (`LibrarySearchSpecials`), standing for one of the anchor's characters. No ASCII byte is ever part of a longer UTF-8 sequence. So a chapter none of whose lines holds the anchor or such a character holds no match, and a scan of its bytes for the anchor's rarest byte (a table of 256 flags, then the whole anchor) passes over it without decoding it.
- **Every other chapter is searched whole**, from its start, by the very calls Search in Book makes on the same text, so the matches are Search in Book's by construction. A first version searched only the lines that might hold a match, and train 1113-0322 showed why that cannot work: Foundation's case-insensitive search does not answer a range alone as it answers the same text inside a longer one. In a range of a few dozen characters it takes a digit's compatibility forms (², ２, ②) for the digit; over a whole chapter it does not. So "2" found more in a line than in its chapter, and the library search listed matches Search in Book does not. Nothing of a chapter is searched on its own now; the prefilter is safe against Foundation's most permissive answer, the one a scalar alone gets.
- **The special characters.** A sweep of all 1,111,936 scalars (`specials.swift`) asked Foundation whether an ASCII query, each printable character and each piece of the ASCII of the scalar's case mappings, folding, and decompositions, is found in the scalar alone, and whether the scalar is passed over between two letters. Ignoring case, 226 are found: ß, ẞ, ſ, the Kelvin sign, the seven Latin ligatures, the Greek question mark and varia, and, which nothing in Unicode's case folding predicts, a digit's compatibility forms: the superscript and subscript digits, the circled, parenthesized, and stopped numbers (①, ⑴, ⒈, ㉑, ㊱), the fullwidth, mathematical, and segmented digits, and the late Roman numeral six. Matching case, 4: the Kelvin sign, the Greek question mark and varia, and the late Roman six. None is passed over. `LibrarySearchSpecials` holds the two sets, and `LibrarySearchSpecialsTests` sweeps every assigned scalar again on each run of the suite, so a macOS that matches more fails a test rather than missing matches.
- **Three rules make the anchor safe with that table.**
  - An ASCII character beside a non-ASCII one in the query is left out of the anchor, since the two may stand together for one character of the text that holds neither's bytes (e and an accent for é, ʼ and n for ŉ, 1, the fraction slash, and 2 for ½).
  - A special character makes its chapter a candidate only when it can stand for one of the anchor's characters (`standsFor`, asked of Foundation once a run), so a book's footnote superscripts never make it a candidate for a word.
  - Any character with a numeric value (a digit form, a Roman numeral, a fraction, another script's digit) is special for an anchor holding a digit or the parentheses, full stop, or comma of the numbered forms, whether or not the table lists it: the runner's macOS 26.7 also matches the circled sans-serif zeros (U+1F10B, U+1F10C) against "0", which 26.3 does not, so a table of digit forms lags a newer macOS. The sweep of every scalar checks that each ASCII query Foundation finds in a scalar is made of what the scalar stands for, on whichever macOS runs the suite.
- **Without a prefilter.** A regular expression (its matches can cross lines, and anchors and look-behind depend on the whole text), a query holding a line feed or carriage return, and a query with no ASCII to anchor on (Greek, Cyrillic, Japanese) are searched over whole chapters by the matcher, as Search in Book searches them. Exact, and slower: measured below.

## 4. How the work is spread

- **Threads.** Books are searched in parallel by `DispatchQueue.concurrentPerform`, never in Swift's concurrency pool, which has one thread a core and must stay free for the rest of the app (`docs/developer/testing.md`, "A blocked call in the concurrency pool starves the app"). A plain search uses every core (four performance and four efficiency cores here); a search of whole chapters four, since each holds a chapter.
- **Reading.** Each worker reads one chapter at a time with `pread` into a buffer it reuses; a chapter the prefilter cannot pass over is decoded once into a String for the matcher. A match never crosses a chapter's edge, as in Search in Book, so no chunk edge exists within a chapter: the largest chapter bounds a worker's memory.
- **Preparing.** Parsing a book, 5 to 22 times its content.md while it runs, is let in only while the content.md being parsed adds up to at most 32 MB (`PreparingGate`; one larger book alone).
- **The cloud.** A book whose package or content.md is only in the cloud is counted and not read (`MaintenanceFileAccess.isInCloud`; reads run with dataless files left in the cloud), so a search never downloads a book; the status says how many were not searched.
- **To the main actor.** The engine reports each book from its threads into a locked inbox; the model takes what has come every 150 ms and adds the books in their places (the books are searched in the Library's title order, `LibraryBookSorter`), so the list grows in order whatever order the books finish in.
- **Cancel.** A newer query or option, closing the window, or the model going cancels the search: `isCancelled` is asked before each book and chapter, and inside each lookup (regular expressions through `.reportProgress`). A generation number keeps a stale search's results from ever landing after a newer one's.

## 5. How a match's place is found in the reader

- **Request.** Opening a match makes a `LibrarySearchJumpRequest` (a `ReaderRequestStore` kind, as the reading list's and the autoplay requests are) carrying the match's chapter, UTF-16 offset, global offset, matched text, and the query and options that found it, then posts `.openBookWindow`, as opening from the Library does: the router opens the book's reader window, or brings its open window forward, and refuses while the library moves.
- **Claim.** The book's reader claims the request once its book has loaded: as the load ends for a new window, or at once for a reader already open (`requestsMade`). It searches its own text with the same matcher and options and goes to the match at the request's place when it is still there; when the text changed since the search (Edit Text, a rebuild), to the match nearest the old place, saying so; when the match is gone, it says so and stays.
- **Go Back.** The move goes through `navigatePreservingReturnPosition`, as Search in Book's does, so Go Back returns to where the reader was before the jump: in a book that was not open, the place it opened at (its saved reading position); in an open book, where it was.

## 6. The window

- **Command.** Edit > Find > Search Library…, Option-Command-F, in every window. The app had no Find submenu (SwiftUI adds one only with `TextEditingCommands`, which the app does not use), and the Library menu shows only while a Library window is in front (`MenuVisibilityManager`), while the Edit menu shows in every window, a reader's included, so the command is reachable from both, where a Mac's find commands are. It is a key equivalent (`ShortcutAction.searchLibrary`, in the Shortcuts tab's Library group), and Option-Command-F is no other default's, no menu's, and no system command's; Command-F stays Search in Book's in a reader, and Shift-Command-F Add Feed's in the Library.
- **Window.** One window, "Search Library", an AppKit window hosting SwiftUI (`LibrarySearchWindowController`), whose identifier keeps the Library's and the readers' menus away while it is in front, and keeps the shortcut manager from taking its keys: Return and Space act in its list.
- **To VoiceOver, in order:** the search field ("Search the library", its hint "Type to search the text of every book in the library"); the status line, read in place, and announced once when a search ends; the Match Case and Regular Expression checkboxes; Close (Escape); the results, a list: each book's heading ("Title, by Author: 12 matches"), then its matches, each row speaking the match in its context, where it is, and its book's title ("…the garden window looked…, Chapter 3, in Title"); then "Show all 212 matches in Title" when the list shows fewer. Return or a double-click, or VoiceOver's default action, opens a match. The Books rotor moves from book to book, the Matches rotor from match to match. Return in the search field goes to the first result.
- **Where the results go.** The app keeps one model, so closing the window keeps the query, its options, and its results, and the next opening shows them with the field taking the keyboard. A search the closing cut off runs again when the window opens.

## 7. Results without end

- A book keeps its first 100 matches with their context and counts up to 1,000 (a book with more says "more than 1,000"); the list shows up to 20 a book and 1,000 in all, and a book with more ends with Show All, which lists up to Search in Book's 500 for that book. The status says what the list leaves out: "212 matches in 31 books", "More than 41,000 matches in 750 books; showing up to 20 in each book, and 1,000 in all", with "; 3 books in the cloud weren't searched" or "; 1 book couldn't be read" when so.

## 8. Measurements on the user's library

**Method.** A harness built for Release from the app's own sources, at 42aa5487 for the first series and at 8037759b for the engine as built (`measure.py` in the agent's scratch folder: the app's sources with a `main.swift` in place of its `@main`, and `swift build -c release`) ran `LibrarySearchEngine` itself over `~/.TextMouth/Library`, which it only read: files opened read-only, the store in `build/orchestrator/libsearch/store-1`, and the process run as a hosted test is (`XCTestConfigurationFilePath` set), so any default place the app's code names is a sandbox in the temporary folder. Each run was its own process, under the heavy-work lock, so nothing else heavy ran beside it, and it printed counts, times, and memory only. The books are the 737 packages below the Library folder holding a content.md (676.3 MB; the orchestrator counted 750 content.md files in the whole data directory). The Mac is the development Mac (Apple M3, 4 performance and 4 efficiency cores, 8 GB); a run used every core but those of the whole-chapter searches, which used four. "Total" is from the search's start to its last book.

The engine as built (8037759b: a chapter the prefilter cannot pass over is searched whole), measured 46 minutes after the first series, with other agents' builds and type-checks run in between, so the first run is the first after a while:

| Search | Total | Processor | Peak resident | Books with matches | Matches counted |
|---|---|---|---|---|---|
| "window", ignoring case: the first run after 46 minutes | 1.20 s | 7.1 s | 100 MB | 706 | 35,162 |
| "window", ignoring case, again | 1.07 s | 7.4 s | 101 MB | 706 | 35,162 |
| "window", matching case | 0.99 s | 7.0 s | 99 MB | 704 | 34,295 |
| again | 0.98 s | 6.8 s | 97 MB | 704 | 34,295 |
| "the garden" (a phrase), ignoring case | 0.57 s | 3.9 s | 101 MB | 460 | 4,784 |
| "zebra" (a rare word), ignoring case | 0.24 s | 1.6 s | 86 MB | 109 | 201 |
| "the" (a common word), ignoring case | 0.29 s | 1.9 s | 103 MB | 730 | more than 715,364 (693 books past 1,000) |
| "café" (no ASCII anchor: every chapter whole), ignoring case | 1.51 s | 10.1 s | 95 MB | 198 | 1,336 |
| "colou?r" (a regular expression), ignoring case | 3.25 s | 12.9 s | 75 MB | 709 | 26,197 |
| again | 3.18 s | 12.6 s | 70 MB | 709 | 26,197 |

The first search ever, which prepared all 737 books into an empty store (the first series, 42aa5487, whose preparing is the same code): 8.73 s, 51.1 s of processor time, 591 MB resident at its peak, 706 books with 35,162 matches for "window". The first version, which searched the candidate lines alone, took about half as long for a plain search (0.43 to 0.64 s for "window", 0.18 s for "zebra") and found the same counts here; it is replaced because Foundation does not answer a line as it answers its chapter (section 3).

- **The five seconds.** Every plain search, ignoring case or matching it, ends in under 1.3 seconds once the books are prepared, the first after a while included, and a regular expression in under 3.5. The one search over five seconds is the first ever, which prepares every book once (8.7 seconds), and the first after a parser change or after macOS empties the Caches folder.
- **Memory.** A search holds one chapter per worker: its peak was 70 to 103 MB resident for the whole process. Preparing, which parses content.md, peaked at 591 MB with the 32 MB gate.
- **Foundation's speed** (probe on one core, 32 MB of synthetic prose with curly quotes and dashes): its case-insensitive search reads 137 MB a second through a native Swift string and 286 MB a second through a UTF-16 NSString, against 1,759 MB a second for `memmem` on the UTF-8 bytes: the prefilter's scan of bytes is why a rare word costs under 2 seconds of processor time, where "café", for which every chapter is searched by Foundation, costs 10.

## 9. Cases where the two searches differ, named

- **A transcribed audiobook's place.** Search in Book names a transcript's match by the audio chapter's title and gives its time; the library search names it by the transcript chapter's own title and gives no time (it does not read the audio's index). Activating it moves the reader to the same sentence as Search in Book would.
- **A book whose text the reader withholds** (a transcript in the cloud, stale, or with an edit held): the library search lists what content.md holds; the reader, asked to move, says why it has no text, as Search in Book does.
- **A parser change that leaves the sample's reading alone** would keep cached texts the new parser reads differently; the reader's search on opening still places the cursor on the match nearest.

## 10. Questions for the user

Each with the answer built.

1. **Should Search Library search feed items too** (articles, and episodes with transcripts)? The Library's lists leave feed items out, so it leaves them out. Recommended and built: not now; a later "Include feeds" checkbox if wanted.
2. **Should TextMouth prepare the search texts in the background**, after launch or when the Search Library window opens, so that the first search after an installation whose parser reads differently, or after macOS empties the Caches folder, is as fast as the rest? Recommended and built: no; the first such search prepares what it needs (measured in section 8), and every later one reads the cache. Preparing at launch would spend the processor on every launch that changed a book.
3. **Is the cache's disk use acceptable** (section 8: about the size of the library's text, in `~/Library/Caches`, which macOS may empty when the disk runs low and Time Machine does not back up)? Recommended and built: yes; a "Clear Search Text" button in Storage settings could follow.
4. **A match's row speaks its context, then where it is, then the book** ("…the garden window…, Chapter 3, in Title"), so moving from row to row hears what differs first, and the book's heading above its matches says the title first. Recommended and built: as described.
5. **The list's limits:** 20 matches a book and 1,000 in all, with Show All listing up to 500 of one book's; a book's count stops at "more than 1,000". Recommended and built: as described.
6. **Match Case on the iPhone's Search in Book**: the shared model has it; the phone's sheet shows no checkbox yet, since its interface tests audit that sheet. Recommended: add it with the iPhone's Search Library screen, a follow-up.
7. **Option-Command-F** for Search Library…: no other default, menu, or system command has it. Recommended and built: as described.
8. **A search of only the Library window's current folder or view**: not built. Recommended: a follow-up, as a "Search in" pop-up, if wanted.
