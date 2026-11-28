# The plan for the official 0.2.0 install (October 23, 2026)

Written by `plan020` from its brief (`Scripts/agents/briefs/2026-10-23/plan020.md`), on main at be385e1a. Nothing was built or run, and the live library at `~/.TextMouth` was not read.

The user's request: "I want to install the new version with it as stable as you can make it so also plan any todos requiring breaking changes for my official update to 0.2.0."

**The build the user runs** is fb46ea6e, version 0.1.1, built October 17, 2026 at 23:16 UTC (the Info.plist of `/Applications/TextMouth.app`). It is called 0.1.1 below. It predates every merge from `team/textfmt` (fcb30520) on: 399 commits.

**In short:**
- 0.2.0 already writes one thing 0.1.1 cannot take: eight new book formats, any one of which makes 0.1.1 refuse the whole library. Its other changes are read harmlessly by 0.1.1, or dropped by it, and on a return to 0.2.0 only an Edit Text change is replaced, with a copy kept (section 1).
- No format change has to be made before the install. Four items make the install, and every later update, safer: V01 and V02 are small, V03 and V04 medium (V04 is optional). The escaping in content.md is better left until the first update after the install (section 2.2, V06).
- The stability list (section 3) is what to fix first:
  - Rehearse the first launch's page re-read on a copy of the library (3.1).
  - Close its two gaps: a Change Location during the batch, and a book open in a reader.
  - Stop EPUB page-break elements from dropping real words.
  - Make Resume after a very quick Pause keep the place.
  - Stop Replace Existing from discarding a book's place and records.

## 1. What 0.2.0 already writes that 0.1.1 cannot read

Each change below says what 0.2.0 writes, what 0.1.1 does with it, with the file and line in fb46ea6e, and the outcome.

### 1.1 Eight new `BookFormat` cases: the library is refused

- **What 0.2.0 writes.** The raw values `webarchive` and `ssml` (FMT03, FMT07), `rtf`, `rtfd`, `doc`, `odt`, and `wordml` (FMT13), all from `team/textfmt` (October 18), and `braille` (FMT20, October 19 and 20), in the book's library.json row and in its package's bookInfo.json. A DTBook is a `daisy` book, and .dotx, .docm, and .dotm are `docx`, so they add none.
- **What 0.1.1 does.**
  - `Book.init(from:)` decodes `format` strictly (`Models/Book.swift:345`), and `Library` decodes the rows as one array (`Models/Library.swift:169`). One such row fails the whole index.
  - `LibraryPersistenceService.readIndex` (lines 1302 to 1333) then keeps a copy, `library.json.unreadable-<date>`, suspends every library.json write, and the Library window offers its recovery options.
  - It shows a provisional library: every package whose bookInfo.json it can decode, and every folder on disk (`buildProvisionalLibrary`, `LibraryViewModel+IndexRecovery.swift:323` to 326). Books in the new formats are missing from it, since it cannot decode their records either (`BookMetadata.format`, `Models/BookInfo.swift:84`).
  - Package records are still written for the books it shows (the service's own comment, lines 6 to 13), and those writes drop 0.2.0's fields (1.2).
  - Its Rebuild Library Index saves the provisional library as the index (lines 366 to 391). The books in the new formats leave the index; their packages stay, and 0.2.0's orphan adoption takes them back. Folder rows and manual order that only the index held are lost, and only the preserved copy keeps them.
- **Outcome.** Going back to 0.1.1 after adding any book in these formats is unsafe. The user's What's New says it only of braille books (`docs/user/whats-new.md:18`), and claims that nothing is written; `docs/user/cloud-library.md:38` names the October 18 formats correctly. V01 corrects it.

### 1.2 The new optional fields: dropped by 0.1.1's writes

- **What 0.2.0 writes:**
  - `editedText`, the record of a finished Edit Text change (B12);
  - `pageReaderVersion`, the page reader that wrote content.md (PG09 and PG16);
  - `brailleTable`, the braille table a braille book was read with (FMT21);
  - `brailleTableVersion`, the liblouis version of this Mac's table (review R2).

  They are written in the row, in the package record, and, for the braille fields, in the removal marker. 0.2.0 reads each one leniently (`fields.optionalValue`).
- **What 0.1.1 does.** It ignores keys it does not know, and drops them from every row and record it writes.
- **Outcome on returning to 0.2.0:**
  - **No `pageReaderVersion`.** The launch re-read compares the book again. Its content.md, written with pages, equals the file read with pages, so it is `writtenWithPages` and only stamped (`LibraryViewModel+Migration.swift:1181`). This holds only while the extraction is unchanged; see 2.8.
  - **No `editedText`.** An edited book matches neither read, so it is `changed`. It is copied as `content.md.edited-<UTC>` and read again with pages (line 1006): the edit is replaced, and the copy keeps it.
  - **The braille fields.** 0.1.1 can decode neither a braille book's row nor its record, so it never rewrites them.
- **Outcome overall.** Harmless unless the user edits text in 0.2.0 and then goes back.

### 1.3 `SkipUnit` "Page": read as the default unit

- **Where it is stored.** As a raw string:
  - globally, in the preferences store (`skipForwardUnitRaw` and its three companions), mirrored into config.json's `skipForwardUnit`, `skipBackwardUnit`, `shiftSkipForwardUnit`, and `shiftSkipBackwardUnit`;
  - per book, in `localSkipForwardUnit` and `localSkipBackwardUnit`.
- **What 0.1.1 does:**
  - config.json's `rawChoice` with an `EnumSettingRule` (`Models/SettingsPolicy.swift:423` to 427) refuses "Page" and keeps the default: 15 seconds, or 30 for the Shift skips;
  - the store's string resolves through `SkipUnit(rawValue:)`, with the default as fallback;
  - a book's "Page" falls back to the global unit (`PlaybackSkipUnitPolicy`, `ViewModels/SettingsViewModel.swift:163` to 164).
- **Outcome.** Harmless: nothing fails, and the Playback picker shows the default.

### 1.4 config.json's new keys: ignored, then dropped from the file

- **The keys:**
  - `keepsOriginalOfConvertedAudio`, held only in config.json;
  - `showsPageInReader`, `saysPageInWhereAmI`, and `brailleTable`, mirrored from the preferences store.
- **What 0.1.1 does.** It decodes config.json a field at a time (`Services/ConfigService.swift:417`) and ignores keys it does not know. It writes the file from its own fields, so these keys vanish from it.
- **Outcome on returning to 0.2.0.** The mirrored values are still in the preferences store, which 0.1.1 never clears, and 0.2.0 keeps the store's value when the file lacks a key (an empty `brailleTable` keeps the current choice). Only `keepsOriginalOfConvertedAudio` returns to its default, off. Harmless.

### 1.5 content.md's page markers: silent in 0.1.1

- **What 0.2.0 writes.** `<!-- page: LABEL -->`, placed only by `MarkdownMarkerWriter` and never at the start of a line. The cache format stays 3.0.7: pages are recorded by `pageReaderVersion`, not by a cache-format bump.
- **What 0.1.1 does:**
  - It takes 3.0.7 as current: `SemanticVersion.isOutdated` is false for an equal or newer stamp (`Models/SemanticVersion.swift:15` to 24). So it never extracts 0.2.0's books again.
  - Its `MarkdownParser` drops every HTML comment that is not a heading annotation (`Parsers/MarkdownParser.swift:229` to 243). A marker adds no word and no character, so places and bookmarks line up.
  - Its chapter split looks only at lines that begin with `<!-- chapter: `.
  - Its Edit Text shows the markers, as 0.2.0's does.
- **The reading-text cache** went from format 1 to 2 (it now holds pages). 0.1.1 refuses version 2 (`Services/ReadingTextCache.swift:250`) and writes version 1, which 0.2.0 then writes again as 2. That costs only time.
- **Outcome.** Harmless.

### 1.6 Unchanged since 0.1.1

- **Formats and versions:** transcript.json (layout 1), the feed indexes (format 1), the content index (1.0.0), text anchors (1), audio edit lists (1), and the cleanup rules (format 1).
- **Shortcuts:** three actions were added (Next Page, Previous Page, Go to Page…), and no saved name changed.
- **Packages:**
  - their file names are the same (`isPackageContentName` is identical);
  - the Ogg conversion was already in 0.1.1;
  - the kept originals of converted audio live in `.convertedOriginals`, a hidden folder that 0.1.1's track scan skips (`Parsers/AudioBookParser.swift:41`).

## 2. Changes still to come that would break, or force a re-read, later

### 2.1 Cache-format bumps

- No open item asks for one. The only candidate is the escaping (2.2).
- After 0.2.0's first launch, every Edit Text change is recorded (B12), so a later bump keeps the user's edits (`BookTextEditSessions.holdsTakenEdit`). It still reads every text book again, though.
- A reader change for one format should re-read only that format's books (V07).

### 2.2 The escaping of source text in content.md

**What it is.**
- `MarkdownLiteral.escaped` backslash-escapes every ASCII punctuation character (`Parsers/MarkdownLiteral.swift:8` to 18 and 33 to 55), so content.md reads "Hello\, world\." It has done so:
  - for plain text since cache format 3.0.6;
  - for HTML, EPUB, and DAISY 2.02 since 3.0.7;
  - in the DOCX and DAISY writers, and in a transcript's text (`TranscriptTextBuilder`).
- It is the one form CommonMark reads literally anywhere, without context. It also disarms swift-markdown's smart punctuation, which would otherwise make quotes curly, "--" a dash, and "..." an ellipsis. Those change characters, and so move places.

**Where the user meets it.**
- Export's Markdown kind copies content.md byte for byte, its escapes and TextMouth's comment markers included (`Services/BookExportService.swift:311` to 319).
- Edit Text opens the same file in the user's editor, where every backslash shows on a braille display.
- The transcripts team's T3 is fixing what Export writes tonight. Text books' content.md is left to this plan.

**Escaping only what Markdown needs.**
- A context-aware escaper would leave commas, semicolons, question marks, and the like alone.
- It would still escape:
  - a period or closing parenthesis after a number at a line's start, and a period beside another period;
  - quotes, hyphens, and the characters with Markdown meanings, as now.
- If it is right, the reader's text is unchanged, character for character, so places, bookmarks, text anchors, and the content index are untouched. Only content.md's bytes change.

**How it would meet PG16's first-launch compare, if both shipped in 0.2.0.**
- **With a cache-format bump (3.0.8).** PG16 compares only a book "behind only in its pages": `isBehindOnlyInPages` requires a current cache (`LibraryViewModel+Migration.swift:1083` to 1086). So every book would skip the compare and be rebuilt as any version bump rebuilds it:
  - an edit made before B12 would be replaced with no copy;
  - `PAGES_UPGRADE_SUMMARY`'s count of replaced text, the agreed sign of drift, would mean nothing.

  It is unsafe as it stands.
- **Without a bump.** The new escaping would go only into the writing with pages, and the reading without pages would stay exactly 3.0.7, so PG16's logic stays as reviewed. But:
  - every writer gains a mode;
  - a mistake in the new escaper would reach about 730 books in one launch, the launch whose summary is meant to show drift;
  - books whose format has no page reader (plain text, Markdown, SSML, web archives, braille) would keep the old escaping.
- **Either way,** the byte compare holds only while the extraction is unchanged (2.8).

**Leaving it.**
- It costs nothing now. Edit Text keeps showing backslashes, and the user has made no edits.
- It can be done in the first update after the install (V06) with cache format 3.1.0. It is safe then, because every edit since B12 is recorded. It costs one more background reading of the text books. This library is mostly EPUB (about 730 on October 3) and held no PDFs when last counted (September 28), so there is little or no OCR.

**Recommendation:** leave content.md's escaping for 0.2.0, and fix only Export (T3, tonight). The choice is the user's (question 1).

### 2.3 Content index 1.1.0 (PG14)

- **The problem with a bump.** `BookContentIndex.currentVersion` is one global version, checked by equality (`Models/BookContentIndex.swift:10` and 52):
  - `needsContentAnalysis` analyses every book whose stamp differs again;
  - every text anchor's measure includes that version (`Models/TextAnchor.swift:59`).

  So 1.1.0 would re-index every book, over 700, and re-measure every anchor at that update's first launch, for the pages of a DAISY audiobook (the library holds one DAISY book). 0.2.0, after a return to it, would write 1.0.0 back.
- **Recommendation.** PG14 keeps 1.0.0:
  - the pages become an optional field of the audio chapters, which 0.2.0 ignores;
  - only DAISY audiobooks are analysed again, through a stamp of their own (V07).

  Record the decision now, and build it after the install.

### 2.4 transcript.json

- **Already forward-safe.** Layout 1 is unchanged since 0.1.1. A later layout is left as it is and not read (`TranscriptStore.Lookup.unsupportedVersion`, `Services/TranscriptStore.swift:84` to 94), so 0.2.0 is already safe as an older build.
- **Tonight.** The transcripts team should keep layout 1 and add only optional fields.
- **Later.** FMT23 and FMT25 (transcripts that come with the audio) may need a field saying where a transcript came from: optional within layout 1, or layout 2 under the same rule.
- **For T5's review.** Transcribe Audio… must never write over a transcript of a later layout.

### 2.5 Package layout and file names

No change is pending.

### 2.6 Settings or shortcut defaults that would be renamed

- **None is pending.**
  - Shortcut actions are saved by name, and a renamed action keeps its former name (`ShortcutAction.formerNames`, `Models/KeyboardShortcut.swift:1463` to 1479).
  - T4's "Retranscribe Audio…" has no shortcut action, so it is wording only.
  - FR13 kept "Recent" as the saved value of the Recently Opened category.
- **The rule stays:** a rename keeps the saved value, or adds a former name.

### 2.7 Library index fields

- **What is decoded strictly:**
  - a row's `format`, `id`, `title`, `author`, `filePath`, `md5Hash`, `folderPath`, `dateAdded`, and `bookmarks`;
  - the library's `sortField` and `sortAscending`, its rows as one array, and its folders.

  The code is at `Models/Library.swift:69` to 70 and 169 to 170, and `Models/Book.swift:492` to 502.
- **The risk.** A later build that adds a format, such as FMT15 CSV, FMT26 FictionBook, FMT33 PowerPoint, FMT34 pictures, FMT40 eBraille, FMT42 MOBI, or FMT45 email, or a sort field, makes 0.2.0 refuse the library as 0.1.1 refuses 0.2.0's (V03).

### 2.8 Anything else with a version or a strict decoder

- **The page re-read's byte compare** (PG16) assumes that the extraction is unchanged since content.md was written.
  - The first `PageReaderVersions` bump of a format would find every book of that format `changed`, since content.md holds the old reader's pages and neither reading matches. One example is an EPUB page fix after the first launch's summary.
  - Each such book would be copied: about 730 copies for EPUB, and a summary full of replaced text (V05).
- **Later readers change existing books' text or chapters:**
  - FMT16 (text in other encodings);
  - FMT17 (markers read as audio chapters, which moves places in existing audiobooks);
  - FMT27 and FMT47 (real headings for ODT, DOC, and RTF);
  - PG12 (braille pages) and PG13 (form feeds).

  Each should re-read only its format through its own stamp, and FMT17 should apply to new imports only, or move places with its chapters (V07).
- **Already forward-safe:** the feed index refuses a newer format (`Services/Feeds/FeedIndex.swift:55`); the reading-text cache is only a cache.
- **Nothing to rename:** `pageReaderVersion` can keep its JSON key even if it comes to stamp more than pages, since `CodingKeys` decouples the Swift name.

## Before the official 0.2.0 install

*A draft for `TODO-2026-09-04.md`, in its item form, ordered by when to build each item:*
- *First, the stability fixes (3.2 below, from its first item down, each a fix of its own).*
- *Next, V01 to V04, before the install.*
- *Last, the rehearsal of the first launch (3.1), on the build that will be installed.*
- *V05 to V07 come after the install. They are recorded now so that later updates stay smooth.*

- [ ] **V01 — Say truly what going back to 0.1.1 does.** Difficulty S · Impact 4 · Before the install, in the next documentation pass (no build).
  - **What:**
    - What's New's warning names every 0.2.0 format that 0.1.1 cannot read: braille, rich text, rich text with attachments, Word 97-2003, OpenDocument, Word 2003 XML, Safari web archive, and SSML.
    - It says that 0.1.1 keeps library.json and a copy of it, but still writes book records, which then lose 0.2.0's records of edits and pages.
    - It says never to choose Rebuild Library Index in 0.1.1, which drops the books in the new formats from the index, with folder rows and manual order that only the index held.
    - The comment on `BookFormat.braille` ("keeps the library's file and writes nothing") is corrected to match, in V02's branch, since a documentation pass edits no code.
  - **Why:** the warning today names only braille books, and says nothing is written (1.1).
  - **Older build:** this item is its documentation.
  - **Migration:** none.
  - **Files:** `docs/user/whats-new.md`, `docs/user/where-your-library-lives.md`, and `docs/user/cloud-library.md` (check its line 38).
  - **Tests:** none (Markdown only).
  - **Risks:** none.
- [ ] **V02 — Pin 0.2.0's on-disk contract in one test class.** Difficulty S · Impact 4 · Before the install (tests, and one comment).
  - **What:** `OnDiskContractTests` pins the following, and only what existing tests do not already pin (look first, DRY):
    - every `BookFormat` raw value, `SkipUnit` raw value, and `LibrarySortField` and `LibraryCategory` raw value;
    - the shortcut action names with `formerNames`;
    - config.json's keys;
    - the keys of a library row and of a package record, from encoding a fully populated book;
    - the package file names;
    - the versions: cache format 3.0.7, content index 1.0.0, the `PageReaderVersions` table, reading-text cache 2, transcript layout 1, feed index and feed format 1, text anchor 1, audio edit list 1, and cleanup rules 1.

    Each assertion's message says what a change forces: an older build's refusal, a re-read of the library, or a re-index. It points at this plan.
  - **Why:** "after that, updates should be smooth". Every later change to these becomes a deliberate step that a review sees, never a side effect.
  - **Older build:** nothing changes.
  - **Migration:** none.
  - **Files:** `TextMouthProductionTests/OnDiskContractTests.swift` (new: `xcodegen generate`, the committed `project.pbxproj`, and a line in `Scripts/test/areas.conf`); in its own commit, V01's comment on `BookFormat.braille` in `TextMouth/Models/Book.swift`.
  - **Tests:** the class itself.
  - **Risks:** duplicating pins that exist already; reuse them instead. Some do: cache format 3.0.7 in `BookContentIndexTests`, `MetadataReaderVersionTests`, and `TextAnchorFineWordsTests`; shortcut former names in `MenuKeyShortcutTests` and `ImportAndShortcutPolicyTests`; `SkipUnit`'s cases in `SettingsPolicyTests` and `PageNavigationTests`.
- [ ] **V03 — Open a library that a later TextMouth wrote.** Difficulty M · Impact 4 · Before the install, after the stability fixes (question 2).
  - **What:**
    - library.json's rows are decoded one at a time, and so are the rows of each feed's index, which are books too (`Services/Feeds/FeedIndex.swift`).
    - A row that does not decode is kept as its JSON object, with its `id` and `tmbDirectoryName` when they read. It is written back unchanged at every save, and never shown or counted.
    - Its package is treated as owned by every walk of the packages: orphan adoption, the startup repair, Rebuild Directory, the removal sweeps, and the data-directory move, which copies it.
    - A `sortField` that does not decode reads as the default, and is written back as it was.
    - One sentence, in the Library's summary or in Storage settings, says how many books need a newer TextMouth, and one debug-log line says the same.
  - **Why:**
    - Only the build the user goes back to can use this, and 0.2.0 is the official build they would go back to.
    - Every format in the queue adds a `BookFormat` case (FMT15, FMT26, FMT33 to FMT36, FMT40, FMT42, FMT45), and today each would make 0.2.0 refuse the whole library (2.7).
  - **Older build:** no format changes; 0.1.1 is unaffected.
  - **Migration:** none.
  - **Files:**
    - `Models/Library.swift` (decoding and encoding) and `Services/Feeds/FeedIndex.swift`;
    - `Services/LibraryPersistenceService.swift`;
    - `Services/FileImportService.swift` (`adoptOrphanedTMBPackages`);
    - `ViewModels/LibraryViewModel+Migration.swift` (the startup repair);
    - the Rebuild Directory, removal, and data-directory move code;
    - the summary's wording.
  - **Tests:**
    - a library holding a row whose format is "fb2", a row without `title`, and the sort field "pages": it loads, shows the other books, and writes the unreadable rows back equal as JSON objects;
    - no maintenance pass moves, adopts, or deletes their packages;
    - `ContentAnalysisMergeTests`, the library index classes, and `LogContentPolicyTests` for the new log tag.
  - **Risks:**
    - a walk of the packages that misses such a row's package, and adopts or deletes it: list every walk first (`grep -rn tmbDirectoryName TextMouth/Services TextMouth/ViewModels`);
    - a save that rebuilds `books` from the shown rows alone.
- [ ] **V04 — Keep the fields that a later TextMouth added.** Difficulty M · Impact 2 · Before the install only if the user wants it (question 2); otherwise later, or never.
  - **What:** a library row (`Book`), a package record (`BookInfo`), and config.json keep the keys they do not know, decoded into one JSON object and written back as they were. A known field always wins.
  - **Why:** a return to 0.2.0 from a later version otherwise loses that version's state for each book, as 0.1.1 drops 0.2.0's `editedText` and `pageReaderVersion` (1.2).
  - **Older build:** nothing changes.
  - **Migration:** none.
  - **Files:** `Models/Book.swift` (an encoder written by hand), `Models/BookInfo.swift`, `Services/ConfigService.swift`, and a small JSON value type if none exists.
  - **Tests:** round trips with unknown keys; `ContentAnalysisMergeTests` (a field on `Book`); the config fixtures.
  - **Risks:**
    - an encoder written by hand must keep every key's name;
    - the analysis and record merges must carry the unknown keys, or drop them on purpose.
- [ ] **V05 — Read text that a page reader wrote again, for newer pages, without the byte compare.** Difficulty S · Impact 4 · After the install. It is required in the release that first bumps a line of `PageReaderVersions`.
  - **What:**
    - In the launch re-read, a book whose `pageReaderVersion` is set and notes no failure (`PageReaderVersions.notesFailure` is false) skips `pageUpgradeCheck`'s compare. Its content.md was written by a page reader that succeeded, so by a build with B12.
    - Such a book is read again, unless it holds a taken edit (already checked), or its content.md changed since its record (the check for an edit saved while TextMouth was closed decides, as now).
    - Every other book is compared as now:
      - one with no stamp, which is text from 0.1.1's time;
      - one whose stamp notes a failure ("+failed-once" or "+failed"). Such a stamp is also written when a book's file is missing or no longer extracts (`unreadableText`, `LibraryViewModel+Migration.swift:1221` to 1240), and that book's content.md is still the old text.
  - **Why:** without it, the first bump of a format's page reader copies every book of that format (2.8): about 730 `content.md.edited-` copies for EPUB.
  - **Older build:** nothing changes.
  - **Migration:** none.
  - **Files:** `ViewModels/LibraryViewModel+Migration.swift` (around lines 990 and 1124), and the comments in `Models/PageReaderVersions.swift`.
  - **Tests:**
    - a book stamped 1.0.0, whose format's reader becomes 1.0.1, is read again with no copy;
    - with a taken edit, it is kept;
    - with content.md changed since its record, the edit check decides;
    - an unstamped book is compared as now;
    - a book stamped "1.0.0+failed" by a missing file, whose file comes back after the reader becomes 1.0.1, is compared, and copied when it differs;
    - a "+failed-once" stamp keeps its meaning, and is compared;
    - the `pages` and `places` areas, and `PlaceRelocationAtRebuildTests`.
  - **Risks:** a stamp lost in a round trip through 0.1.1 sends the book through the compare, which is safe; keep that.
- [ ] **V06 — Escape only what Markdown needs in content.md, with cache format 3.1.0.** Difficulty M · Impact 3 · The first update after the install (question 1).
  - **What:**
    - `MarkdownLiteral` gains a minimal form. A character is escaped only where CommonMark, GitHub tables and strikethrough, or smart punctuation would otherwise read it:
      - the backslash, backtick, asterisk, underscore, square brackets, angle brackets, ampersand, pipe, tilde, and both quotes;
      - a hyphen beside another hyphen, or at a line's start;
      - a period or closing parenthesis after a number at a line's start, and a period beside another period;
      - "!" before "[";
      - "#", "+", "=", and ">" at a line's start;
      - U+FEFF, as now.
    - Every writer that uses it switches: `PlainTextParser`, `HTMLToMarkdownConverter`, `DOCXParser+Converter`, `DAISYParser+TextExtraction`, and `MarkdownEmphasis`.
    - A reading with `includesPages: false` keeps reproducing 3.0.7 exactly, full escaping included. It stays the reference for the compare below, and for the parsers' exact-output tests that read with it.
    - The cache format becomes 3.1.0, with its line in the version history.
  - **Why:** the file Edit Text opens, and anything copied from it, then reads as written, with no backslash before every comma and period.
  - **Older build:** 0.2.0 and 0.1.1 both take 3.1.0 as current (a newer stamp is never outdated), and read the same text from it.
  - **Migration:**
    - The bump reads every text book again in the startup batch, and edits are kept (B12).
    - A book that holds neither an edit record nor a page stamp was never compared by PG16: plain text, Markdown, SSML, web archives, and braille. It is compared first with the 3.0.7 reading, which PG16's reading without pages already gives, and copied when it differs. This is PG16's rule, extended to those books.
  - **Files:** `Parsers/MarkdownLiteral.swift` and its callers, `Services/MarkdownCacheService.swift`, and `ViewModels/LibraryViewModel+Migration.swift`.
  - **Tests:**
    - a property test that the minimal and full forms parse to the same reading text, over generated strings (every ASCII punctuation character in every position, at line starts, in runs, and beside combining marks) and over the golden corpus;
    - the exact-output tests that read with `includesPages: false` pass unchanged, which proves 3.0.7 is still reproduced; the goldens written with pages, such as parts of `TextPipelineGoldenTests`, are regenerated (the brief lists them);
    - the heading-annotation classes, the reading-text cache tests, and `BookTextEditTests`.
  - **Risks:**
    - a context the escaper misses would reach every book at once. So each book's content.md is written in the minimal form only after it parses to the same reading text as the full form; otherwise that book keeps the full form, and the debug log names it.
    - A batch stopped between writing a book's content.md and committing its record leaves TextMouth's own text where the next launch looks for an edit saved while it was closed. PG16 handles this for the page re-read (`writtenWithPages`); the version-bump path must compare with the new reading before it takes such a text as an edit.
    - Transcripts' content.md is the transcripts team's: their places count time, so it can change on its own.
- [ ] **V07 — A change to how one format is read re-reads only that format's books.** Difficulty S (a rule, and PG14's design) · Impact 3 · Record it now, and apply it in each item as that item is built.
  - **What:**
    - A later reader change adds or bumps that format's line in the table of reader versions (`PageReaderVersions`, generalized; its JSON key can stay `pageReaderVersion`). It never bumps the global cache format or content-index version. This covers PG12, PG13, PG14, FMT16, FMT17, FMT27, and FMT47.
    - PG14 keeps `BookContentIndex` 1.0.0. Its pages become an optional field of the audio chapters, and DAISY audiobooks get a stamp of their own.
    - FMT17 changes the chapters of audiobooks already in the library, which moves places. It applies to new imports only, unless it moves places with the chapters.
  - **Why:** a global bump reads or indexes the whole library again for one format's books (2.3).
  - **Older build:** 0.2.0 ignores an optional field, and a stamp line it does not know.
  - **Migration:** per format, as each item says.
  - **Files:** `Models/PageReaderVersions.swift`, `Models/BookContentIndex.swift` (PG14), and each item's own.
  - **Tests:** each item's own, with V02's pins changed on purpose.
  - **Risks:** DAISY text books and DAISY audiobooks share the `daisy` format, so their stamps must tell them apart.

## 3. Stability: what could lose data, places, or words, or crash

### 3.1 First: rehearse the first launch on a copy

- **Why.** 0.2.0's first launch reads every EPUB, HTML, PDF, DOCX, DAISY, and textutil book again, in the live library.
  - It reads each book twice: the compare without pages, then the reading with pages. That is about 1,460 extractions for about 730 EPUBs.
  - Its batch has never run on a real library of hundreds of books, and its time and memory were never measured (the pg16 notes in `AGENT-NOTES-2026-10-04.md`).
  - Its one summary line is the only sign of drift.

  It is the one step of the install that rewrites the whole library.
- **How:**
  - Copy library.json and the packages of the text books, but not the audiobooks, into a scratch folder.
  - Run 0.2.0's startup batch on the copy in a hosted test, opted in by an environment variable, so it runs inside the test sandbox. Never use a second instance of the app, or a changed data-directory setting, which the installed app shares.
  - Read `PAGES_UPGRADE_SUMMARY`, whose count of replaced text should be zero for a user who made no edits, along with the time and the peak memory.
  - For each book, measure how much reading text the reading with pages drops compared with the reading without pages. Only page labels should go, so list every book that loses more (3.2, item 2).
  - Then delete the copy.
- **Cost.** One agent, with no change to the app. About one to two gigabytes of disk while it runs; a sample of 150 books would answer the time and memory questions if disk is short.
- **Needs** the user's yes (question 3). It reads the live library, read-only, which the standing rules allow for a copy ("copy packages to scratch to reproduce bugs").

### 3.2 The open follow-ups, ranked by risk

The rank is likelihood on the user's library (mostly EPUB, a few audiobooks and podcasts, one Mac) times severity. Line numbers are the TODO's. A read-only helper checked each item against the code on main, and plan020 checked items 2, 3, and 5 in the code itself. No item loses data on its own: each needs a user action or an unusual book. Items marked **transcripts** touch the transcripts team's files tonight: schedule them after its merge, or give them to its T5 reviewer.

1. **The first launch's page re-read (PG09, PG16).** Lines 3860, 5099 to 5100, and 3828. It is certain to run, on every text book, and keeps text safe, but:
   - **The path is not rebased after a move.** `pageUpgradeCheck` reads the book through the batch's snapshot of its path (`LibraryViewModel+Migration.swift:1125` to 1129), while writing uses the current one. A Change Location during the batch (it stays enabled; only Redo is disabled, `StorageSettingsView.swift:377`) stamps every remaining book `+failed`: its text is safe, but it never gains pages without Redo Text Extraction. **Fix (S):** rebase the book before reading, or hold Change Location until the batch ends.
   - **A book open in a reader.** A reader restored at launch keeps saving places in the old text's numbering until it is opened again, when the text anchors move them (`ReaderViewModel.swift:1460` to 1466; line 3828). **Fix (S):** check whether the batch passes over a book whose reader is open; if it does not, have it wait for that reader to close.
   - **No cancel, and two readings of each book.** **Fix (M, optional):** compare with the reading with pages alone, for formats whose pages add no reading text.
   - **Copies.** The `content.md.edited-<UTC>` copies it keeps are never removed. The user should hear of them in What's New if the rehearsal finds any.
2. **An EPUB page-break element loses all its text in the reading with pages.** Found in the code; not in the TODO.
   - **The cause.** `HTMLToMarkdownConverter.swift:219` to 224 skips every child of a page-break element when pages are read (`isPageBreakElement`, line 421, is true only then). The reading without pages, 3.0.7, reads them.
   - **The effect.** At the first launch, an EPUB that wraps real words in a page-break element loses those words. The old text matched the reading without pages, so no copy is kept, and the places are moved past them.
   - **The model to follow.** DAISY 2.02 has the guard this lacks: a fragment holding more than its page number is read as ever (`DAISYParser.swift:785` to 795).
   - **Fix (S, before the install):** skip the element's text only when it is no more than its page label; otherwise place the marker before it and read the text. The rehearsal measures how many books it touches.
3. **Resume after a very quick Pause restarts the chapter, and the saved place follows.** Line 3737.
   - **The cause.** `SpeechService.resume()` takes `currentWordRange?.location ?? madeAudioEngine?.currentCharOffset() ?? 0` (`SpeechService.swift:1939`), and nothing has reported a word yet when Pause comes within about 0.3 seconds of Play.
   - **The effect.** Resume plays the chapter from its start, so a quick Play and Pause, such as a double press, loses the place within a long chapter.
   - **Fix (S):** fall back to the offset the speech started from.
4. **Replace Existing on a duplicate import throws away the old copy's state.** Lines 3499 and 3762. **Transcripts.**
   - **The cause.** `LibraryViewModel+Duplicates.swift:249` to 261 deletes the old package (to the Trash when that setting is on, as by default) and adds the new copy under a new ID. Only its place in the reading list is carried over.
   - **What is lost:** the reading position, bookmarks, notes, the book's own settings, an Edit Text change, and a transcript. The choice's hint ("keeps the new one in its place") does not say so.
   - **Fix (M):** carry the old book's state over under its ID, moving places by text anchors, or at least say in the dialog what is lost.
5. **Edit Text: a page marker at the start of a line drops that line's words.** Found in the code; not in the TODO.
   - **The cause.** CommonMark makes a line that begins with `<!--` an HTML block, the whole line included. `MarkdownParser.visitHTMLBlock` (`MarkdownParser.swift:249` to 258) keeps only a block that is exactly a marker, so any words after the marker on that line are not read.
   - **How it happens.** The writers never begin a line with a marker (`MarkdownMarkerWriter.swift:38` to 45), but an edit can: deleting the text before an inline marker, or joining lines. Edit Text's checks (`BookTextEditing.swift:22` to 42) do not look for it, and B12 then keeps the edit for good. The same holds for heading annotations.
   - **Why it matters now.** After the first launch, every text book's content.md holds markers.
   - **Fix (S):** when an edit is taken, move such a marker to the end of the line before it, as the writer places one, or refuse the edit with a sentence that says which line.
6. **Variable-bit-rate MP3s seek imprecisely.** Line 3803.
   - **The cause.** The player's asset is opened without precise timing (`AudioPlaybackService.swift:850`), though the probe uses it (`AudioMediaProbe.swift:97`), and seeks are clamped to the estimated length (line 974).
   - **The effect.** A podcast episode or MP3 audiobook can resume seconds from its saved place, repeating or skipping words.
   - **Fix (S):** open with precise timing, after measuring the load time on long files.
7. **`AsyncBridge.waitForResult` has no time limit.** Lines 3842 and 3788.
   - **The callers:** `ReaderViewModel.swift:1495`, `BookContentAnalysisService.swift:559` and 564, `FileImportService.swift:253`, and `BookParser.swift:66`.
   - **The effect.** An AVFoundation read that never returns leaves a reader on Loading, or a single-file import stuck with no cancel. The main thread stays free.
   - **Fix (M).**
8. **The reader-load race follow-ups** (`fix/reader-load-race`). Line 3857.
   - **Play during a move.** For an audiobook that was not playing when the move began, Play reads the moving files, since `pauseAudioForPackageMove()` sets aside only playing audio (`ReaderViewModel+LibraryUpdates.swift:149` to 159). The result is a "damaged" failure; nothing is lost. **Fix (S):** guard Play with `isPackageMoving`.
   - **Session-only losses.** A load that succeeds mid-move can lose its tags, manifest pauses, transcript, and EPUB metadata for the session. **Transcripts.** **Fix (M).**
   - **Stuck on Loading.** A book of tracks waits on storage for its manifest (`BookManifestEditing.swift:895`), so any storage hold keeps its reader on Loading.
9. **EPUB files are looked up by exact case.** Line 3467.
   - **The cause.** `EPUBParser.swift:500` and 506, and `EPUBParser+Navigation.swift:258` and 311, use `archive[path]` alone; DAISY already uses the case-insensitive lookup (`DAISYParser.swift:186`).
   - **The effect.** A badly made EPUB loses a chapter at import, with a warning. Books already in the library do not change.
   - **Fix (S).**
10. **A Word 97-2003 file with a table of contents or a link keeps its words joined at page breaks.** Line 3859.
    - **The cause.** Field instructions throw off the letter count (`TextutilPageBreaks.swift:239` to 301), so those breaks get neither a page nor B13's space ("runs on andcontinues").
    - **Also:** a run of 32 or more identical letters can misplace a page, and B13's space can land after an opening quote.
    - **Scope.** New imports only.
    - **Fix (M).**

**Lower risk**, one line each:
- DAISY clock values such as "500ms" or "2min" read as 0, so each clip plays from its file's start; new DAISY audio imports only (line 3847, `DAISYParser+Audio.swift:129` to 160).
- A feed item deleted while it is being transcribed loses its transcript (lines 3807 and 3811). **Transcripts.**
- A new download of a feed article replaces the edit its rules kept, with no copy (lines 3797 and 3798).
- With permanent deletion, a feed download held aside is deleted for good at the next launch (line 3814).
- A transcribed Ogg book's transcript goes stale after conversion, and a failed delete after the commit leaves a duplicate track (line 3839). **Transcripts.**
- Two manifest saves less than 0.75 seconds apart move places twice (line 3836).
- PDF text is written into Markdown unescaped (`PDFTextParser.swift:599` to 620; lines 3424 and 3700), and raw HTML blocks in Markdown books are not read (line 3683).
- Text files in other encodings are read as Windows-1252 (FMT16; lines 3471 and 3847).
- A content.md nested thousands deep could overflow the stack (line 3853).
- Cloud: a substitution change made before a synced substitutions.json arrives is dropped (line 3731); a move into a cloud folder uploads the staged copy midway (line 3666).
- The memory guard's quit skips the library move, recording, and unsaved audio-editor holds (line 3838).
- Deadlocks nothing triggers today: `betweenWrites` re-entry, and `DispatchQueue.main.sync` in `SpeechService.swift:417` and the import paths (line 3717).
- Export's exclusive copy across volumes can remove another app's file landing at the target in the same instant (line 3853).
- Page labels and Go to Page: page-number text inside an EPUB heading stays in the spoken heading ("Part 9Two"), and Go to Page announces the typed label (line 3859).

**Already fixed on main**, so not to chase:
- B12's row overriding a newer record (line 3859), by pg16;
- the statistics file in the cloud (3819);
- the feed index read at launch (3791);
- the speech player node and idle recovery (3840, 3793);
- a buffer completion while paused (3671);
- `removedFromLibrary.json` on re-import (3455);
- Delete Original deleting permanently or deleting a folder (3499, 3844);
- Rebuild Library Index losing the reading list (3762);
- a place past its chapter's end (#2028).

## Questions for the user

Only the choices that are the user's. Each has a recommended answer.

1. **content.md's escaping (V06): in 0.2.0, or in the first update after it?**
   - **The context.** A book's text file, content.md, puts a backslash before every punctuation mark ("Hello\, world\."). Edit Text shows it that way, and Export copied it that way; the transcripts team is fixing Export tonight.
   - **In 0.2.0.** Changing content.md before the install touches every text format's reader just before a first launch that already reads about 730 books again. It also weakens the check that shows whether anything changed unexpectedly.
   - **After the install.** It costs one more reading of the text books in the background, with your edits kept.
   - **Recommended:** in the first update after the install.
   - Answer:
2. **Should 0.2.0 open a library that a later TextMouth wrote (V03), and keep the details a later version added (V04)?**
   - **The context.** Both matter only if you ever go back to 0.2.0 after installing a later version. Without V03, a book in any format added later makes 0.2.0 refuse the whole library, as 0.1.1 refuses one with 0.2.0's new formats. Each is a medium-sized item.
   - **Recommended:** V03 yes, before the install; V04 not now.
   - Answer:
3. **May an agent copy your library's text books, read-only, to a scratch folder to rehearse 0.2.0's first launch, and delete the copy afterwards (3.1)?**
   - **The context.** The first launch reads every text book again in your live library. A rehearsal on a copy would show, before that happens, how long it takes, how much memory it needs, and whether any book's text would be replaced.
   - **What it touches.** Nothing in your library is changed. Audiobooks are not copied.
   - **Recommended:** yes.
   - Answer:
