# Reading places that survive re-extraction (T06)

A design note for T06, written before it is built. It draws on the code on main at 2eb4b8cb (rechecked at 06edaba1, where nothing it relies on changed but Replace's handling of the reading list), and on a measurement program in the session's scratchpad that compiled TextMouth's own parser files at four versions of the text extraction (3.0.2, 3.0.3, 3.0.4, and today's 3.0.7) and ran them on copies of the repository's fixtures. Run on today's code, the program reproduced the golden digests `TextPipelineGoldenTests` records for all six text fixtures, content.md and reading alike, byte for byte. The user's library was read only for numbers: library.json and the content indexes of the 52 books that hold a place were read by scripts that printed counts and dates alone, and config.json for one number, the speech speed. Nothing was copied, nothing in the app or the library was changed, and no app was built.

The item, quoted whole from TODO-2026-09-04.md: "T06 — Relocate reading positions, bookmarks, and skipped headings after re-extraction. P1 · Impact 4 · Difficulty 5 · Design / Risk. Numeric offsets and heading IDs can change when text/chapter extraction improves. Add versioned text anchors or an explicit migration/reporting policy. Acceptance: re-extract a book with inserted code, removed duplicate links, and corrected chapter boundaries; saved locations either follow the same content or are clearly reported as needing review."

## Summary

- **Today a saved place is two numbers.** A reading position and a bookmark are a chapter index and a UTF-16 offset into that chapter's reading text (`ReadingPosition`, `Bookmark`, Models/Book.swift). A skipped heading is an ID, `"<chapter>-<offset>-<level>-<label>"` (`Heading.init`, Models/DocumentContent.swift). Nothing records which text they were measured in. Every path that extracts a book's text again carries them over as they are. The reader only brings them into range: a chapter past the end becomes the last chapter's start, and an offset past its chapter's end becomes the chapter's start (`ReaderViewModel.showLoadedContent`). A skipped heading whose ID no longer exists is simply no longer skipped, silently.
- **The extraction changes often.** The text cache version changed eight times after it was introduced on March 24, five of them in September. Reading text has also changed with no version at all (Markdown tables read a row at a time), and with the cache bumped but content.md unchanged (3.0.3 changed the Markdown reading of four of the six fixtures). Edit Text, a feed article downloaded again, and an EPUB title written into its file change a book's text or headings outside any version.
- **What shifts, measured with the app's own extraction.** In the 17 real comparisons that moved any place (42,160 places sampled at word starts), today's numbers resume 80.7% of places on other words, and 7.5% more within five words. From 3.0.4 to 3.0.7, the change the user's library took on October 3, the median miss is 10 words in alice.epub, 76 in frankenstein.html, and 809 in pride.txt: four minutes of listening at 200 words a minute, and a minute and a half at the user's 500. A chapter that 3.0.4 restored (a spine document in a sibling folder) put two thirds of the book's places into the chapter before their own. Of 557 headings in those comparisons, 484 were still in the book under a new ID, so a section skipped there would play again.
- **The three acceptance cases**, each replayed through the real code where the history holds it: restored code (sample.md, 3.0.2 to 3.0.3) moved 66% of places by 11 units; removed duplicate link text (alice.docx, 33 links, the same step) moved every place, median miss 135 words; a restored chapter (alice.epub with chapter V in a sibling folder, 3.0.3 to 3.0.4) put 68% of places in another chapter. Synthetic versions of all three, with exact truth, on four books and two seeds, agree.
- **This user's library.** 745 rows: 730 EPUB, 11 audiobooks, 2 plain text, 1 HTML, 1 DAISY. 52 text books hold a place past their start: 52 positions and 5 bookmarks in 4 of them, and no skipped headings. 46 of the 52 positions and all 5 bookmarks were saved before the content.md their book has now (625 text caches were rewritten on October 3, 101 on October 7). In 40 of the 52, the chapters before the place have since grown or shrunk, by a median of 547 UTF-16 units. 3 books hold a position past the end of their last chapter, and will reopen at that chapter's start. Every one of the 52 can move again at the next extraction change.
- **Options, measured.**
  - (a) Text anchors (the text around each place, kept with it, found again by its words): of 59,300 places in 26 real comparisons, none placed on wrong words, 0.3% reported. Of 106,773 synthetic places, 5 placed wrong, 13 words early, and 0.2% reported. About 156 bytes a place. Needs no old text.
  - (b) A migration that diffs the old text with the new: perfect on the synthetic cases, but it needs the old reading text exactly as the old build read it. A newer build often can't reproduce that, and it misses every path outside the cache rebuild.
  - (c) A "needs review" report alone: safe, but after the October 3 change it would have asked the user to review nearly every place in every book.
- **Recommendation: (a), with (c) for what (a) can't place.**
  - **What each place keeps:** 64 UTF-16 units of text on each side, found again by its words when the direct check fails.
  - **When a place can't be found, or is found twice:** it is put at the best guess, announced once, and listed under Places to Review with the words that were there.
  - **Skipped headings:** they become a level, a label, and an anchor, and are found again among the headings of their level.
  - **Edit Text:** it moves bookmarks and skipped headings too, with the same finder.
  - **No diff migration.**
- Section 7 asks ten yes-or-no questions, each with a recommended answer. Section 8 plans four branches: the anchor engine, capturing anchors (with the existing places), finding them again, and the review list.

## 1. Where a place is saved today

### Saved places

- **The reading position** (`ReadingPosition`, Models/Book.swift):
  - its fields: `chapterIndex`, `characterOffset` (UTF-16 units into the chapter's reading text), `globalCharacterOffset` (the chapter's start plus the offset, for the library's time left and percent), and `lastUpdated`;
  - `headingIndex`, which is decoded but never written;
  - where it is kept: in the book's library.json row (`Book.readingPosition`), in its record (`BookState.readingPosition`, bookInfo.json), and for a feed item in its feed's index (`Feeds/<feed ID>/library.json`).
- **How a position is written.** `ReaderViewModel.makeCurrentReadingPosition()` builds every position the reader saves:
  - a checkpoint every 30 seconds of playback, and at pause, stop, close, chapter end, and navigation (`persistReadingPosition`), into the record at once and library.json within five minutes;
  - live positions about once a second, held in memory for the library's rows (`LiveReadingPositions`).
- **Bookmarks** (`Bookmark`): `chapterIndex`, `characterOffset`, `number`, `label` (the user's note), and `dateCreated`, in the row and the record.
  - `LibraryViewModel.addBookmark` adds one at the reader's cursor. The bookmark toggle first nudges it with `adjustedBookmarkOffset`, so that two never fall within 10 units in a text book.
  - A bookmark's heading is worked out when it is shown (`headingText(forBookmark:)`).
- **Skipped headings** (`Book.skippedHeadingIDs`, `BookState.skippedHeadingIDs`): a list of `Heading.id` strings, `"<chapter>-<offset>-<level>-<label>"`.
  - The content index records the same IDs (`BookContentIndex.build`).
  - `SkippedSectionFilter.apply` leaves out the text from a skipped heading to the next heading of any level in its chapter.
  - The Headings sheet shows a heading as skipped when its ID is in the list (`ReaderViewModel.isHeadingSkipped`).
- **Places in audiobooks** count time, at ten characters a second (`ReaderViewModel.audioCharsPerSecond`). Text extraction never moves them; audio edits do, through `AudioEditPlaces.follow`, which maps each place through the edit's exact route and dates a moved position so it wins over older copies.

### Stores that hold no place of their own

- **The checkpoint journal** (`ReadingCheckpointJournal`, Services/LibraryPersistenceService.swift) names book IDs only. After a crash, launch takes the record's position when it is newer than the row's (`adoptNewerRecordedPositions`).
- **The reading list** holds book IDs. **Stats** count listening by book ID and day (`ReadingStats`). Neither keys anything by offset.
- **Held in memory or written to logs only:**
  - the reader's cursor, its Return place (`savePositionForReturn`), search results, and the sleep timer's next heading, which is found again at each load;
  - the refusal report's places (`SpeechRefusalPlace`, counted while the window is open) and its `SPEECH_REFUSAL_REPORTED` log lines.
- **Transcripts' offsets** (word offsets inside sentences in transcript.json, and sentence offsets in the text layer) are the transcript's own structure, rebuilt with it. No user place is kept in transcript-text coordinates.
- **Copy Reading Position** and the export write text, never a stored place.

## 2. Every way a book's text is extracted again

Each path, and what it does to places now.

- **The startup batch** (`LibraryViewModel.extractMissingContentCaches`, LibraryViewModel+Migration.swift):
  - which books it rebuilds (`booksNeedingCacheUpdate`): a missing cache, an older `cacheFormatVersion` (`MarkdownCacheService.isCacheOutdated`), a source or content.md of another size than the row's fingerprints record (T07), or a content.md of the same size with another date (FR05);
  - how: `rebuildTextCaches`, `committedTextCache`, and `MarkdownCacheService.generateReportedCacheAnalyzeAndStamp`;
  - what reaches the record: `LibraryPersistenceService.saveContentAnalysis` merges only the analysis fields and the index;
  - places: unchanged, as numbers.
- **Redo Text Extraction** (Storage settings, `redoAllTextExtraction`): the same rebuild for every text book, with `force`. It does not even read the cache it replaces. Places stay as numbers.
- **The reader's own rebuild.** `ReaderViewModel.readContent` asks `BookContentAnalysisService.load` for a new cache when the book's cache version is outdated. `loadExistingCache` rebuilds a cache whose source or content.md changed (`CACHE_STALE`). Places stay as numbers, clamped as above.
- **All of these write through one function, `MarkdownCacheService.writeCache`.** The old content.md is still on disk when it runs.
- **Reading text derived again without re-extraction:**
  - `BookContentIndex.currentVersion` changes, or a change ships with no version at all. Reading Markdown tables a row at a time changed the reading text of DOCX and Markdown books with tables while changing neither version (ARCHITECTURE.md, "Text caches and content indexes").
  - The saved index then fails `alignmentFailure` (`CONTENT_INDEX_REJECTED`) and is rebuilt. `ReadingTextCache` is keyed by the build, so it is parsed again.
  - Places stay as numbers. **No cache or index version recorded with a place could notice this.**
- **Edit Text** (FR05, `BookTextEditSessions`, `LibraryViewModel.commitTextEdit`):
  - With a reader open, `ReaderViewModel.showEditedText` moves only its cursor (`EditedTextCursor`), and "Bookmarks keep their places in the chapters, which an edit may have moved".
  - With no reader open, nothing moves, and an edit saved while TextMouth was closed is taken at launch the same way (`TEXT_EDIT_ADOPTED`).
- **A transcript edited or cleaned up** (audiobooks): only the text layer changes. Places count time and do not move.
- **The legacy migration** (`LegacyBookMigration`) builds the cache last. Places stay as numbers.
- **A feed item downloaded again** (FR11, `FeedEpisodeImporter.restoreBook`):
  - The kept row's place, bookmarks, and skipped headings return with the same book.
  - An article's HTML is written afresh from the feed's text (`articleHTML`) and read by today's extraction. If the publisher changed the article, or the extraction changed meanwhile, the numbers point elsewhere.
- **Replace, answering a duplicate import** (`LibraryViewModel.settle(_:of:with:)`, `.replaceExisting`):
  - It deletes the library's copy with its package, and the new copy joins as a new book. Since ac7be130 the new copy takes the old one's spot on the reading list, but the old copy's reading position, bookmarks, skipped headings, and settings are lost.
  - A duplicate is matched by MD5 or by the same source path (`duplicateMatch(for:)`), so the second kind can be a revised file.
- **The metadata refresh** (`refreshOutdatedMetadata`) changes titles and authors only. No text, offset, or heading ID changes.
- **An EPUB title written into its file** (the metadata editor's write):
  - The source's fingerprint changes, so the next load rebuilds the cache (`CACHE_STALE`). The text comes out the same.
  - An untitled chapter's start heading takes its label from a rule that compares the chapter's document title with the package title (`fallbackTitle` in `EPUBParser.preparedChapter`). So such a heading can be relabelled, and its ID changes.
- **The cloud:**
  - A book downloaded again comes back byte for byte, with no re-extraction.
  - In a library shared by two Macs, a newer TextMouth rebuilds content.md and an older one keeps it, since `SemanticVersion.isOutdated` never undoes a newer stamp. So places saved on either Mac meet text written by the other.
  - An older TextMouth rewrites records without the fields it does not know.
- **A data-directory move** copies files byte for byte. Nothing moves.

**How often extraction has changed.** `MarkdownCacheService.currentCacheVersion` went from 2 (March 24) through 2.0.0, 2.0.1 (May 7), 3.0.2 (July 16), 3.0.3 (September 4), 3.0.4 (September 8), 3.0.5 (September 28), and 3.0.6 to 3.0.7 (September 29). The user's library took the last step on October 3, when 625 of its text caches were rewritten.

## 3. What shifts

### How it was measured

- **The extraction, as the app runs it.** A standalone Swift program (`textanchors-measure/driver`, Swift 6.2) in the session's scratchpad, not part of the app, compiled the parser files of each version straight from git:
  - 3.0.2 at f556c1f0^, 3.0.3 at f556c1f0, 3.0.4 at 534e8f7c, and 3.0.7 at 2eb4b8cb;
  - the files: the EPUB, HTML, DOCX, plain-text, and Markdown parsers with their helpers, `MarkdownDocParser`, Models/DocumentContent.swift, and Services/OffsetMap.swift;
  - each version's own cache-writer extraction and chapter split, copied verbatim from that version's `MarkdownCacheService` (that file needs the app's storage services);
  - stubs only for logging, metadata writing, and hashing, which no reading text depends on;
  - linked against the SwiftSoup, swift-markdown, cmark, and ZIPFoundation objects that the main build folder holds, copied first.
- **The check:** today's version reproduced the content.md and reading digests that `TextPipelineGoldenTests` records for all six text fixtures (alice.epub, frankenstein.html, pride.txt, sample.md, alice.docx, test_book.docx).
- **The reading measured:** what every open after the first reads, the reading text and headings parsed from content.md. An EPUB's first open after a rebuild reads the chapters the extractor prepared instead, and these matched exactly.
- **The comparison** (`textanchors-measure/compare`, Swift, `-O`):
  - **The places sampled:** about 3,000 per comparison, at evenly spaced word starts.
  - **Where each place's words are now:** for a real pair, a word alignment of the two readings (patience diff over words compared by their letters and digits, lower-cased). For a synthetic case, the exact map the case was built with.
  - **How a landing is judged:** "Same place" means on the place's own words (or anywhere in the passage that replaced them); "near" means within five words in the same paragraph; anything else is "wrong".
  - **A heading's place** is the one most of its first five words agree on.
  - **Checked by hand:** five headings the alignment paired with the same words elsewhere (a contents list, a title page, a restored chapter's heading). In each, the anchor had chosen the right heading. The vote and a fallback to the nearest heading of the same level and label settled four; one still counts as a wrong anchored heading in the totals.
- **The real acceptance cases:**
  - Restored code and removed duplicate links are the 3.0.2 to 3.0.3 step: `MarkdownDocParser` began reading code (F13), and the DOCX converter began writing each hyperlink's text once (F15).
  - A corrected chapter boundary: alice-sibling.epub, a copy of alice.epub with chapter V moved to a folder beside the package's and named as `../Text/…`, which 3.0.3's cache writer skipped and 3.0.4 restores (F22, ed1f073d).
- **The synthetic cases**, built on today's readings, seeds 1 and 2:
  - **code:** a code block before one paragraph in ten and an inline span before one word in 250, so the text grows 2% to 5%.
  - **links:** one to four words written twice, once in about 250 words.
  - **restore:** a chapter the old reading lacked.
  - **move:** a chapter's heading and first paragraph at the end of the chapter before.
  - **merge:** two chapters run together.
  - **The books:** alice.epub, frankenstein.html, pride.txt, and alice.docx; for the chapter cases, the two novels split at their chapter headings (33 and 96 chapters), as an EPUB of them would be.
- **The anchors measured** keep 64 UTF-16 units each side (32 and 96 were measured too) and are found by the rules in section 5.
- **The user's library:**
  - Scripts read library.json, and for the 52 books with a place their contentIndex.json files, and printed counts, dates, and offsets only. No title, note, or heading label was printed or copied.
  - The debug log was searched for tags.
  - config.json was read for the speech speed, 500 words a minute.
- **The machine:** an Apple M3 with 8 GB, macOS 26.3. Other agents were building (load average 5.5 to 6.2), so the timings are upper bounds, and the scratch code is not optimized.

### Real version steps

What today's numbers do to places, and what anchors do instead, for each single step that moved places.

| Book | Step | Reading text | Places moved | Today: wrong words (median miss) | Heading IDs changed, heading still there | Anchors: placed / reported / wrong |
| --- | --- | --- | --- | --- | --- | --- |
| sample.md | 3.0.2 → 3.0.3 | +11 (code kept) | 66% | 18.2% (2 words); 48% within five | 5 of 7 | 100% / 0 / 0 |
| alice.docx | 3.0.2 → 3.0.3 | −811 (link text written once) | 100% | 100% (135 words) | 7 of 8; 12 empty headings replaced | 99.3% / 0.7% / 0 |
| frankenstein.html | 3.0.2 → 3.0.3 | +2,095, content.md unchanged | 99.8% | 99.8% (129 words) | 30 of 34 | 99.9% / 0.1% / 0 |
| pride.txt | 3.0.2 → 3.0.3 | +26,482, content.md unchanged | 99.9% | 99.9% (1,299 words) | 95 of 95 | 99.8% / 0.2% / 0 |
| alice-sibling.epub | 3.0.3 → 3.0.4 | 14 → 15 chapters, +11,761 | 68% | 68% (2,263 words) | 9 of 18 | 99.7% / 0.3% / 0 |
| alice.epub | 3.0.4 → 3.0.7 | +401 | 99.4% | 19.9% (10 words); 36.6% within five | 15 of 21 (13 labels) | 99.5% / 0.5% / 0 |
| frankenstein.html | 3.0.4 → 3.0.7 | −443 | 99.8% | 99.8% (76 words) | 29 of 34 | 99.8% / 0.2% / 0 |
| pride.txt | 3.0.4 → 3.0.7 | −9,097 | 100% | 99.9% (809 words) | 95 of 95 | 99.8% / 0.2% / 0 |
| alice.docx | 3.0.4 → 3.0.7 | +163 | 99.2% | 98.7% (28 words) | 15 of 20 | 99.6% / 0.4% / 0 |
| test_book.docx | 3.0.4 → 3.0.7 | +18 | 36.9% | 6.0% (3 words); 31% within five | 3 of 10 | 96.8% / 3.2% / 0 |

- **3.0.3 to 3.0.4 changed no fixture's reading text.** It only added two navigation headings to alice.epub, as T11 said. The sibling-path copy is the exception, because its chapter returns.
- **In alice.epub, 3.0.2 to 3.0.3 moved no place.** Its 994 new units are a contents list at the end of chapter 1.
- **Across 3.0.2 to 3.0.7**, the cumulative steps, today's numbers put 6% (test_book.docx) to 100% (alice.docx) of places on other words. A place past the new end of a chapter goes back to its start: the worst misses (29,578 words in alice.docx, 78,078 in frankenstein.html, and 130,333 in pride.txt) are places sent back to the start of the book.
- **Totals:**
  - Over all 26 real comparisons (59,300 places, 9 of the comparisons moving no place): today 57.4% wrong; `EditedTextCursor`, given the old text in memory, 3.2% wrong; anchors 99.7% placed, 0.3% reported, none wrong.
  - Over the 17 that moved places (42,160): today 80.7% wrong; `EditedTextCursor` 4.5%; anchors 99.6% placed, 0.42% reported, none wrong.
- **`EditedTextCursor` fails on rewrapped text.** It searches for 48 units of the old text literally, so a change of line breaks defeats it: 27% to 31% of pride.txt's places landed on other words, after a fallback that says nothing. Its searches took up to 13 ms a place in a 744,000-unit chapter.

### Synthetic acceptance cases (exact truth, both seeds)

| Case | Places | Today: wrong words (median misses) | Anchors: placed / reported / wrong | Diff: wrong | Heading IDs changed / anchored right |
| --- | --- | --- | --- | --- | --- |
| code | 25,204 | 84.3% to 99.9% (40 to 2,041 words) | 99.5% to 99.9% / 77 / 5 | 0 | 286 of 340 / 339 |
| links | 25,439 | 62.9% to 99.3% (14 to 603 words) | 98.3% to 99.2%, 221 more within five / 77 / 0 | 0 | 284 of 340 / 340 |
| restore | 18,874 | 74.2% to 83.6% (2,046 to 3,096 words) | 99.5% to 99.9% / 48 / 0 | 0 | 190 of 294 / 288 |
| move | 18,628 | 1.3% to 8.8% (6 to 198 words) | 100% / 0 / 0 | 0 | 6 of 300 / 294 |
| merge | 18,628 | 49.7% to 63.0% (2,270 to 3,217 words) | 99.7% to 99.9% / 28 / 0 | 0 | 144 of 300 / 294 |

- **The 5 wrong anchor placements** are places with a code block inserted just before them and an inline span inside their next words. With the words after the place broken twice, the words before won, and the place went to the start of the inserted block, 13 words early.
- **Every reported place** in the synthetic cases still had its words in the new text: these are false alarms, 0.2% of places, mostly from passages the books repeat.
- **The diff placed everything**, because the synthetic old text is exactly the text the places were measured in (section 4).

### This user's library

- **What it holds:**
  - **Rows:** 745: 730 EPUB, 11 audiobooks, 2 plain text, 1 HTML, 1 DAISY.
  - **Text books with a position:** 80, of which 52 are past their start (49 EPUB, 1 DAISY, 1 HTML, 1 plain text). Together their reading text is 41.0 million UTF-16 units in 2,203 chapters.
  - **Bookmarks:** 5, in 4 of those books, made between March 20 and September 11.
  - **Skipped headings:** none.
  - **Cache versions:** all 52 books are at cache 3.0.7, index 1.0.0.
  - **Audiobooks:** 10 hold a place, counted in time, which text extraction never moves.
- **Their places predate their text:**
  - 625 text caches were written on October 3, 101 on October 7, and 1 on October 9; 50 of the 52 books with places were rewritten on October 3.
  - 46 of the 52 positions, saved from March 20 on, and all 5 bookmarks predate the content.md their book has now. Each was carried over as numbers through every change since it was saved.
  - The debug log since October 4 holds no cache lines, so it cannot say why 101 caches were rewritten on October 7.
- **The text before them moved.** A position's `globalCharacterOffset` records where its chapter began when it was saved, so it can be compared with today's index without reading any text:
  - In 40 of the 52 books the chapters before the place have since grown (25) or shrunk (15): by a median of 547 UTF-16 units (about 90 words), at most 216,770.
  - In 12 of them the saved global offset now falls in an earlier chapter.
  - This measures the earlier chapters, not the place's own drift, which needs the old text, gone since October 3. It shows that the extraction changes reached most books with a place.
- **Three books will reopen at the wrong end.** Their positions, at the end of their last chapter, now lie past it (offset 534 in a chapter of 530, 445 in 194, and 2,786 in 2,782), and `showLoadedContent` will send each to the start of its last chapter.
- **The next extraction change** can move all 52 positions and the 5 bookmarks: 49 of the books are EPUBs, which every change to HTML or EPUB reading reaches.

## 4. The options

### (a) Text anchors

- **What a place keeps:** the reading text just before and just after it, 64 UTF-16 units each, never splitting a character, beside its chapter and offset. When the text changes, the place is found again by those words.
- **Measured:** 99.7% placed and 0.3% reported over the real steps, with none wrong. 99.6% placed, 0.2% reported, and 5 wrong (13 words early) over the synthetic cases.
- **Anchored headings:**
  - In the real steps, 749 of 778 right and 28 reported: 24 are the 12 empty headings 3.0.2 piled at one offset in alice.docx, in two comparisons each, and 4 are a title page's repeated lines. The one counted wrong was right on inspection.
  - In the synthetic cases, 1,555 of 1,574 right, 19 reported, and none wrong.
- **Quote length:**

  | Quote each side | Real: placed / reported | Synthetic: placed / reported / wrong | Bytes a place |
  | --- | --- | --- | --- |
  | 32 units | 99.25% / 0.74% | 99.0% / 0.78% / 7 | 90 |
  | 64 units | 99.69% / 0.30% | 99.6% / 0.22% / 5 | 156 |
  | 96 units | 99.76% / 0.22% | 99.6% / 0.15% / 7 | 221 |

  64 units halves 32's reports for 66 more bytes; 96 adds little.
- **What it covers:** every path in section 2, the unversioned ones included, since the quote checks itself against whatever text is loaded. It needs no old text, so Edit Text, a feed article downloaded again, another Mac's rebuild, and a Replace of a revised file are all covered.
- **Failure modes:**
  - **Repeated text:** a licence printed at both ends of a Gutenberg book, or a title page repeated in a colophon. A place there is reported, never jumped across the book (the locality rule in section 5). Before that rule, the synthetic cases had sent places 28,000 words away.
  - **Text rewritten at the place:** reported.
  - **An insertion exactly at the place with an edit inside its next words:** the place lands just before the inserted text (the 5 synthetic misses).
  - **Places saved before anchors** have no quote; section 5 says how they get one.
- **Cost:**
  - **Storage:** 153 to 159 bytes a place as JSON for Latin text, more for scripts that need three UTF-8 bytes a character. For this user's 57 places, about 9 KB across library.json and bookInfo.json.
  - **The direct check:** comparing 128 units, microseconds a place at each load.
  - **When a check fails:** the book's words are indexed once. The scratch program took about 0.25 s per million UTF-16 units to find the words, and 1 to 3.5 ms to index them. Each place then took 0.006 to 0.04 ms.
- **For a VoiceOver user, when a place can't be placed:**
  - The reader opens at the best guess and says once how many places need review.
  - Places to Review quotes the words that were there, so the user can hear or read them in braille and decide.
  - Nothing moves silently to a wrong paragraph. In the real cases a place either landed on its own words or was reported; in the synthetic ones, 5 of 106,773 landed 13 words early, at the start of a block inserted just before them.

### (b) A versioned migration by diff

- **What it does:** each place records the extraction it was measured in. When a book is extracted again, its old reading text is aligned with the new, and each place carried across.
- **Measured:** it placed every synthetic place, in milliseconds. For pride.txt the word alignment took 0.4 ms after the words were found.
- **Why it fails in practice:**
  - **It needs the old reading text exactly as the old build read it.** The new build parses old content.md with the new parser, which is not the text the places were measured in when the reading derivation changed:
    - On September 4, four of the six fixtures kept content.md byte for byte while their reading changed, by up to 26,482 units.
    - The Markdown table change altered reading text with no version at all.
    - To diff reliably, TextMouth would have to keep a copy of each book's reading text as it was when its places were saved: about 41 million units for this user's 52 books.
  - **It misses paths outside the cache rebuild.** Edit Text (the user's editor replaces the text), a feed article downloaded again into its kept package, a newer TextMouth on another Mac, and Replace never pass through a migration step. Redo Text Extraction does not even read the cache it replaces.
  - **It can't follow reordered text:** text moved in the order of the book is a deletion and an insertion to a diff.
- **Cost:** a second read and parse of each rebuilt book with places, the alignment, and two texts in memory at once, in the cache batch's workers.
- **For a VoiceOver user, when it can't place a place:** nothing tells. It falls back to the numbers unless (c) is added.

### (c) A "needs review" report alone

- **What it does:** each place records the text it was measured in (a version, or a digest of its chapter). A place whose text changed is shown as needing review, with the old words around it, and left where it is.
- **Measured burden:** in the October 3 step, 99% or more of places moved in four of the five changed fixtures (37% in the fifth). For this user that means nearly all 52 positions and 5 bookmarks to review, book by book, by ear or in braille, after one routine update.
- **What it covers:** detection by a version misses the unversioned changes. Detection by quote (a) catches them.
- **For a VoiceOver user:** honest but exhausting. Each book announces on opening, and every place has to be judged by its quote.

### Combinations and the recommendation

- **(a) with (c), recommended.** Anchors place almost everything; the review list holds the 0.3% they can't, each with its words.
- **(a) with (b), not recommended.** A diff as a second chance inside `writeCache`, where the old content.md is on disk, would help only places anchors report, and only on the one path where the old reading text can sometimes be had.
- **The "versioned" part of T06.** Each anchor records the cache and index versions it was measured in (for example "3.0.7/1.0.0") and a format version of its own. These are not used to decide anything, since the quote decides, but a future diagnosis can count places measured in older text without inferring it from dates, as this note had to.

## 5. The design

### What a place keeps

- **`TextAnchor`** (new, Models), with the fields below, and decoded with `decodeIfPresent` so older files load:
  - `before` and `after`: up to 64 UTF-16 units of the chapter's reading text before and from the place, cut on composed-character boundaries (`rangeOfComposedCharacterSequences`);
  - `fraction`: the place's share of the whole book, for "near";
  - `measuredIn` (the cache and index versions) and `version` (the anchor format, 1).
- **Where it is kept:**
  - `ReadingPosition.anchor` and `Bookmark.anchor`.
  - **`SkippedHeading`** (new): `level`, `label`, `chapterIndex`, `characterOffset`, and an anchor at the heading's start. `Book.skippedHeadings` replaces `skippedHeadingIDs`, which is read once to make them and then kept in step for older builds.
  - The reader still filters by the IDs of the headings each skip resolves to, so `SkippedSectionFilter` and `ChapterSpeechInputs` do not change.
- **Captured whenever a place is saved,** from the text the reader shows:
  - `makeCurrentReadingPosition()`, for every checkpoint and live position;
  - `toggleBookmarkAtCurrentPosition` and `addBookmarkAtCurrentPosition`, at the offset each saves (the toggle's nudged one), passing the anchor to `LibraryViewModel.addBookmark`;
  - `toggleHeadingSkip`.

### Finding a place again

The rules measured above, written for `TextAnchorFinder` (new, Models):

1. **The direct check.** If `before` ends and `after` begins at the saved chapter and offset, the place is unchanged.
2. **Words.** A word is a run of characters between whitespace holding a letter or digit. Words are compared by their letters and digits, lower-cased, so changes of punctuation, quotes, and line breaks leave them the same.
3. **Candidates.** Every place where the first four words after the place stand, and every place the last four words before it end.
4. **Score.**
   - Each word after the place that agrees, in order up to the first that doesn't, counts 2; each word before it counts 1.
   - The words after count double because they are what the listener was about to hear, so text inserted at the place leaves the place before its own words.
   - A candidate needs 8.
5. **One best.** The one best candidate is the place. A tie is "found twice", and the place is reported.
6. **Locality.** A candidate scoring 8 or more within 5% of the book (at least 3,000 units) of where the place was, beaten only by one farther away, is reported rather than taken. This keeps a place in a repeated licence from jumping to the other copy.
7. **Headings.**
   - A skipped heading is looked for among the new headings of its level: each scored as above at its start, plus 3 when its label is unchanged, under the same tie and locality rules.
   - A heading in a chapter without words (a cover) is the one heading of its level and label.
   - A heading found again takes its new label: "[]CHAPTER I." became "CHAPTER I. Down the Rabbit-Hole" on October 3.

The word index is built only when a direct check fails, off the main thread, during the reader's background load (`readContent`). The load returns what moved, and `showLoadedContent` applies it on the main actor if the places have not changed meanwhile.

### When places are found again

- **At every load** (`showLoadedContent`), for the position, the bookmarks, and the skipped headings. This replaces today's clamp.
- **At Edit Text** (`showEditedText`), for all three, with the same finder; `EditedTextCursor` retires. A closed book's places follow at its next open.
- **Everything else needs nothing of its own:** a feed article downloaded again, a cache rebuilt by any path, another Mac's text, a Replace that keeps places (question 10). The next load finds the places.

### What a moved place becomes

- **Its anchor is captured again** from the new text, so the next load is a direct check.
- **A moved position** is dated at the move, as `AudioEditPlaces.follow` dates one, so it wins over an older copy in the checkpoint journal's adoption or another Mac's index.
- **A moved bookmark** keeps its ID, number, note, and date. **A skipped heading** takes the found heading's place and label.
- **The library saves them** as it saves any change: the row, the record, and the feed's index for a feed item.
- **The log** gets one line a load, `PLACES_RELOCATED: <title>: moved N, unchanged M, to review K`, with counts only.

### Places that need review

- **The place is marked** (`needsReview`, with the quote it had) and kept, so the mark survives closing the book.
- **Its cursor goes to the best guess:** the nearest equal candidate, or the same share of its chapter at a word start.
- **The existing places**, saved before anchors and holding no quote, take their quote from the text as it reads now (question 6):
  - at each book's next load;
  - and, for books not opened, in a launch pass before the text cache batch (`updateContentCachesAndStatistics`), off the main thread, skipping books in the cloud and books held by an edit, with one `TEXT_ANCHORS_BACKFILLED` line.
  - The build that adds this changes no extraction (question 9), so no book is extracted again before its places have their quotes.
- **A place past its chapter's end** goes to the chapter's end, and in the last chapter rests at the book's end (question 7).

### What does not change

- Audiobooks' places, which count time; transcripts; the content index's own heading IDs, which still name headings in the text.
- The checkpoint journal, which names books; the reading list; Stats.

## 6. Accessibility

- **Moves are silent** (question 3). A place found again opens where its words are, as the user left it, with nothing to hear but the book. Announcing moves would speak at nearly every book after an update.
- **Problems are announced once, after the book loads.** For example: "2 places in this book need review: the text changed where they were. Review Places is in the Bookmarks menu."
  - It goes through the reader's VoiceOver announcer, and waits while the window is behind, as the refusal report does.
  - Its wording is pinned by static constants and tests, as every spoken wording is.
- **Places to Review, a section of the Bookmarks sheet.** One row a place, read as one element:
  - The row reads its kind, number, and note, then "It was at:" and the words before and after, then "Now at:" and the heading and first words where the cursor went. For example: "Bookmark 3, Note: the trial. It was at: …she went on, What's your name, child? | My name is Alice, so please your Majesty… Now at: CHAPTER XI. Who Stole the Tarts?, My name is Alice…"
  - The quote is plain text, so a braille display reads it as written.
  - Its buttons: Go There, Keep Here, which clears the mark, and Delete for a bookmark or Skip This Heading for a heading.
  - Return goes there and Escape closes. VoiceOver focus lands on the first row.
- **The full Where Am I?** adds "2 places to review" while any remain.
- **Nothing is conveyed by sight alone:** the mark is in the row's label, not a colour or an icon.

## 7. Questions for you

Each has a recommended answer.

1. **Should each saved place keep the text around it?** Your reading position, each bookmark, and each skipped heading would keep about 64 characters of the book's text on each side, about 160 bytes each and 9 KB for your 57 places. TextMouth could then find each place again whenever a book's text is read anew. Recommended: yes. In the real changes measured, this put no place on wrong words, where today's numbers put 81% on wrong words.
2. **When TextMouth can't tell where a place went, should it say so and list the place under Places to Review, with the words that were there?** This happens when the text at the place was rewritten, or when the words stand twice in the book, as a licence printed at both ends does. The book would open at the best guess and say once how many places need review. Recommended: yes. In the measured changes, 0.3% of places.
3. **Should a place that is found again move there without being announced?** Only problems would be announced, and each move would get a line in the debug log. Recommended: yes. In the change your library took on October 3, nearly every place moved.
4. **Should a skipped heading be remembered by its level, its label, and the text where it starts, rather than by today's ID?** The ID changes whenever text before the heading changes or its label is corrected (484 of 557 headings in the measured changes), which silently brings a skipped section back. Recommended: yes.
5. **Should Edit Text move your bookmarks and skipped headings with the text, and a closed book's position at its next open?** Today it moves only an open reader's cursor. Recommended: yes.
6. **For places saved before this change, should TextMouth take their text from each book as it reads now?** The text they were saved in is gone, so a place that has already drifted can't be put back (46 of your 52 positions predate the October 3 rebuild). From then on each would stay with the words it points at. Recommended: yes.
7. **Should a place past its chapter's end go to the chapter's end, and in the last chapter to the end of the book, rather than to the chapter's start?** Three of your books, whose positions are at the end of their last chapter, would then reopen at their end rather than at that chapter's start (P07 is the wider question). Recommended: yes.
8. **Should TextMouth leave out a migration that keeps each book's old text to compare with the new?** It needs the old reading text exactly as the old build read it, which a newer build often can't reproduce. On September 4 the reading of four fixtures changed while their content.md stayed the same. It also misses Edit Text, feed articles, and another Mac's rebuild. Recommended: yes, leave it out.
9. **Should the build that adds the saved text change no text extraction?** Every existing place would then take its text from the text it was saved against, before anything moves. The next extraction change would wait for a later build. Recommended: yes.
10. **Should Replace keep your place, bookmarks, skipped headings, and settings when the new copy is the same file revised (the same source path)?** Today Replace deletes them with the old copy's package. With saved text they can be found in the revised copy. Recommended: yes, in a later branch.

## 8. Build plan

Four branches in order, each with its tests, and a documentation pass after each merge.

### Branch A: `feature/text-anchors` (the engine)

- **What it adds:**
  - `TextAnchor`, its capture from a chapter's text, and the word keys.
  - `TextAnchorFinder`: the direct check, candidates, scores, the tie and locality rules, and headings by level, label, and anchor.
  - `ReadingPosition.anchor`, `Bookmark.anchor`, and `SkippedHeading` with `Book.skippedHeadings`, each decoded with `decodeIfPresent`.
- **Tests** (pure, no window):
  - the direct check;
  - restored code before, inside, and exactly at a place;
  - duplicate link text removed, as DOCX wrote it before 3.0.3;
  - rewrapped lines, as plain text changed in 3.0.6;
  - a restored chapter, merged chapters, and a moved boundary;
  - a licence printed twice with an edit inside one copy's anchor (reported, never the far copy);
  - places at a chapter's start and end, and a cover chapter's heading;
  - emoji, combining marks, and CR LF at a quote's cut;
  - a record without anchors decoding;
  - the anchor's size pinned for Latin text;
  - two short real pairs kept as strings: sample.md's code paragraph and an alice.docx linked paragraph, from their 3.0.2 and 3.0.3 readings.
- **Pins:** `ContentAnalysisMergeTests.bookWithEveryFieldSet` and `testBookRebuiltFromItsRecordHasEveryField` gain `skippedHeadings`.
- **Size:** about 450 lines, with 700 lines of tests.

### Branch B: `feature/text-anchors-capture`

- **What it adds:**
  - Capture at every save: `makeCurrentReadingPosition()`, the two bookmark adds (with `LibraryViewModel.addBookmark` and `Library.addBookmark` taking the anchor), and `toggleHeadingSkip` (with `updateSkippedHeadings` taking `SkippedHeading`s).
  - The existing places: captured at load when in range, and in the launch pass before the text cache batch (section 5).
  - The end-of-chapter rule (question 7).
- **Tests** (hosted):
  - capture on save, in the row and the record;
  - the launch pass over a library with and without places, a book in the cloud, and a book held by an edit;
  - the checkpoint journal's adoption keeping the anchor;
  - `LiveReadingPositions` publishing nothing for an unmoved cursor;
  - a feed item's index keeping anchors;
  - a record written before this branch loading.
- **Size:** about 300 lines, with 500 lines of tests.
- **No extraction change in its build** (question 9).

### Branch C: `feature/text-anchors-relocate`

- **What it adds:**
  - Finding places again in the reader's background load, and applying them in `showLoadedContent` in place of the clamp, with moved places saved, unplaced ones marked, and the log line.
  - `showEditedText` moving the cursor, bookmarks, and skipped headings with the same finder. `EditedTextCursor` retires and its tests move to the finder.
- **Tests** (hosted):
  - a book whose content.md changes between two opens (position, bookmarks, and a skipped heading follow);
  - a repeated passage (marked for review);
  - Edit Text with bookmarks;
  - an unchanged book (nothing written);
  - a large book whose places are found off the main thread.
- **Size:** about 350 lines, with 600 lines of tests.

### Branch D: `feature/places-to-review` (interface)

- **What it adds:**
  - The announcement, and the Places to Review section of the Bookmarks sheet with its rows and buttons.
  - A Review Places item in the Bookmarks menu, and the full Where Am I?'s count.
- **Tests:**
  - wording pinned by static constants;
  - the announcement made once a load;
  - the hosted sheet's AppKit controls; its buttons, which SwiftUI does not expose to these tests, skip with `XCTSkip` as common.md describes.
- **Size:** about 300 lines, with 350 lines of tests.

### Branch E, after question 10: `feature/replace-keeps-places`

Replace from the same source path carries the old copy's places and settings to the new copy, found by their saved text.

### Risks

- **An older TextMouth** (another Mac, or an older build run again) rewrites records without anchors. The next newer launch captures them again from the text as it then reads.
- **Repeated text** is reported rather than guessed: 0.3% of places, every one of which a listener can settle from its quote.
- **Scripts without spaces** (Chinese, Japanese) make long "words"; the finder still compares them exactly, but was not measured on such text.
- **The quotes are the book's own text** in library.json and bookInfo.json, which sync with a library in the cloud.
- **Already-drifted places** can't be repaired: their quote records where they point now.

## Follow-ups noticed (not part of T06)

- `ReadingPosition.headingIndex` is decoded but never written. (Models/Book.swift)
- `showLoadedContent` sends an offset past its chapter's end to the chapter's start, so a book read to its end whose last chapter shortened reopens at that chapter's start; three of this user's books will. (ViewModels/ReaderViewModel.swift; P07)
- Edit Text moves only an open reader's cursor. Bookmarks, skipped headings, and a closed book's position stay as numbers. (ViewModels/ReaderViewModel+EditedText.swift, ViewModels/LibraryViewModel+TextEdits.swift)
- `EditedTextCursor`'s literal 48-unit search fails on rewrapped text and falls back to a proportional place without saying so: 27% to 31% of pride.txt's places were wrong. (ViewModels/ReaderViewModel+EditedText.swift)
- A stale skipped-heading ID stays in `skippedHeadingIDs` for good, and the Headings sheet shows its section as included. (ViewModels/ReaderViewModel+VoiceAndSpeed.swift)
- Replace on a duplicate import from the same source path deletes the old copy's places and settings with its package. (ViewModels/LibraryViewModel+Duplicates.swift)
- The library row's percent and time left use the saved `globalCharacterOffset` against the new total until the book is opened again. (Models/Book.swift, `percentComplete`, `estimatedTimeRemaining`)
- Writing an EPUB's title into its file can relabel untitled chapters' start headings, since their label depends on the package title. (Parsers/EPUBParser+Navigation.swift, `preparedChapter`)
- The cache batch logs nothing when it rewrites caches in bulk, so the user's debug log cannot say why 101 caches were rewritten on October 7. (ViewModels/LibraryViewModel+Migration.swift)
- 3.0.3 and 3.0.4 read alice.epub's contents table with its link targets in the reading text ("[CHAPTER XII.](1801890453487475839_11-h-12.htm.html#chap12)Alice’s Evidence"); 3.0.7 reads one entry a paragraph. Books cached by those versions spoke such text until October 3. Fixed already; noted because places in contents pages moved most (alice.epub's chapter 1 went from 1,942 to 1,377 units).
- A feed episode downloaded again with other advertisements keeps its places, which count time and now point elsewhere: the audio form of this problem, outside T06. (Services/Feeds/FeedEpisodeImporter.swift, `restoreBook`)

## What I could not verify

- **No app was built and no hosted test was run.** Every proposed change is on paper.
- **The old versions' packages.** The 3.0.2, 3.0.3, and 3.0.4 parsers were linked with today's SwiftSoup (2.13.9) and swift-markdown (0.9.0). In September the project resolved them at build time (`from: "2.7.5"` and `from: "0.5.0"`, with no Package.resolved committed), so a build of that time may have used older releases. Only today's version is checked against recorded digests.
- **PDF and DAISY extraction were not measured.** The user has one DAISY book with a place.
- **The real comparisons' truth is a word alignment**, which can pair repeated words with the wrong copy. Five such heading artifacts were found and checked by hand; places may carry a few too.
- **The user's places' own drift** within their chapters can't be measured: the text they were saved in was replaced on October 3. Only the earlier chapters' change (by global offsets) and the dates are known.
- **The timings** were taken under load in unoptimized scratch code.
- **VoiceOver and braille** on the proposed announcement and review list: on paper.
- **Text without spaces between words** (Chinese, Japanese): not measured.
