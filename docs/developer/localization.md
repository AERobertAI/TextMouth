# Localizing TextMouth's code
<!-- id: localizing-textmouth-code; keys: FR34, localization, conversion, wave, String Catalog, developers; src: Scripts/l10n/l10n.py, Scripts/l10n/scan.py, TextMouth/Localization/Localizable.xcstrings -->

Part of [TextMouth's documentation](../../README.md).

This page is for the developer or agent who converts a part of the app's code to localized text.
A translator reads [Translating TextMouth](translation.md) instead; it covers the translation steps, the glossary, and the rules for every language, and this page does not repeat it.
Every Swift file of the app is converted, in three rounds of waves, and the interface text was cut by the user's rules with every fact kept (FR34).
Spanish is the first language, as the test of the system, and about eleven are planned; the Spanish is not on main yet.
The plan and its measurements are in `research/LOCALIZATION-RESEARCH-2026-11-18.md`.

## The String Catalog
<!-- id: localization-string-catalog; keys: Localizable.xcstrings, es.lproj, development language, STRINGS_FILE_OUTPUT_ENCODING, SWIFT_EMIT_LOC_STRINGS, stringsdict; src: TextMouth/Localization/Localizable.xcstrings, project.yml, TextMouth/Resources/Info.plist, TextMouth/Platform/iOS/Info.plist, Scripts/l10n/catalog.py -->

Both apps share one catalog, `TextMouth/Localization/Localizable.xcstrings`, with English as the development language (`CFBundleDevelopmentRegion` in both Info.plists).
The compiler extracts each string a source file uses, and `l10n.py sync` merges them into the catalog; nobody edits the catalog by hand.
`project.yml` turns the extraction on (`SWIFT_EMIT_LOC_STRINGS`).
It ships the catalog as `.strings` and `.stringsdict` files in each language's `.lproj` (`LOCALIZATION_PREFERS_STRING_CATALOGS`).
It writes them as UTF-8 (`STRINGS_FILE_OUTPUT_ENCODING: UTF-8`), the smallest of the encodings Xcode offers.
Each string needs a comment that says where it appears and what each placeholder holds, which `l10n.py check` enforces.
Apple's `String(localized:comment:)`, or a SwiftUI literal, is the only way to write one; never `NSLocalizedString`, and never a helper of TextMouth's own, since the compiler drops the comment of a helper's literal.
A key is the English text, and keys are app-wide: one translation serves every place that shows the same words.
A word with two meanings gets a key of its own only when a translator says so.

## The size budget
<!-- id: localization-size-budget; keys: 150 KB, budgetBytes, budgetFails, l10n-size, English bytes, es.lproj size; status: incomplete; issues: FR34; src: Scripts/l10n/config.json, Scripts/l10n/l10n.py -->

The English text in the catalog has a budget of 150,000 bytes (`budgetBytes` in `Scripts/l10n/config.json`), and `make l10n-size` reports it, with each language's shipped size in each format.
The budget only reports for now (`budgetFails` is false); it will fail once the cutting is done.
Measured on the pilot's Spanish, 5,805 bytes of English shipped as 22,576 bytes in the XML Xcode writes as UTF-8, about four times as many.
The catalog now holds 188 strings and 6,035 bytes of English.
Converting a sentence whole grows the English by about a fifth before any cut, because glued sentences become whole ones and each count gets its plural forms.

## The commands
<!-- id: localization-commands; keys: make l10n-sync, l10n-status, l10n-check, lint-l10n, plural, prune, reach, scan.py show; status: incomplete; issues: TL14; src: Makefile, Scripts/l10n/l10n.py, Scripts/l10n/scan.py, Scripts/l10n/reach.py -->

- `make l10n-sync` (`REF=commit`, or `WORKTREE=1` for uncommitted work) extracts the strings of both apps and merges them into the catalog.
- `make l10n-status` counts each language's strings by state (`LANG_CODE=es` for one), `make l10n-size` is the size report, and `make l10n-check` checks the catalog: comments, placeholders, plural forms, empty values, stale strings, and malformed parts.
  `make check` runs `l10n-check`.
- `make lint-l10n` is the scanner's ratchet (below).
- `l10n.py plural KEY --lang en --one "..." --other "..."` writes a string's plural forms.
  Give every count sentence English `one` and `other`, even one that never says one, since `apply` refuses plural forms for a key whose English has none.
  That is a limit to lift later (TL14), as is `plural`'s refusal of a plural that agrees with a second number.
- `l10n.py prune` deletes the stale strings a cut leaves, which `check` otherwise reports until someone does; `prune --all` and `--dry-run` are in [Translating TextMouth](translation.md#syncing-pruning-and-the-test-classes).
- `l10n.py reach` lists the test classes the branch's localization could break, for `build-train.py request --classes`, and the iPhone unit classes on a line of their own.
- `scan.py report [--by area|file]` totals the unlocalized text by area or file.
  `scan.py show FILE` lists a file's unlocalized literals until it shows none, and also the SwiftUI literals the compiler extracts with no comment, which `check` refuses once the file is synced.
  A line ending `// l10n: no (reason)` is left out on purpose: an identifier, a stored value, a log line.
- `todo` and `apply` are the translators' commands; see [Translating TextMouth](translation.md).

## The extraction and the lock
<!-- id: localization-extraction-lock; keys: typecheck.py --emit-strings, -emit-localized-strings, stringsdata, heavy-work lock, locations.json, sync time; src: Scripts/ios/typecheck.py, Scripts/l10n/l10n.py, Scripts/agents/heavy_lock.py -->

`sync` runs `Scripts/ios/typecheck.py --emit-strings` for the Mac and for the iPhone.
The compiler writes one `.stringsdata` file for each Swift file into a folder of its own under `build/l10n/stringsdata/`, and `sync` merges both folders.
Each extraction takes the heavy-work lock itself, so never wrap `sync` in `run_locked.py`, and it takes about four minutes (157 to 340 seconds measured), so run it once for a batch of edits.
`--worktree` extracts the tree as it is, so one commit can hold the code and the catalog it needs.
The build folders are never deleted during a run: each sync leaves about 7 MB, which the orchestrator clears afterwards.
`sync` keeps only the strings of the files `Scripts/l10n/sync-paths.txt` lists, one glob a line, and a glob that matches no file is refused.
It also writes `build/l10n/locations.json`, which `todo` reads.

## The scanner's ratchet
<!-- id: localization-scanner-ratchet; keys: scan-baseline.json, lint-l10n, ratchet, merge chain, L10N_LINT_FAILED, --update-baseline, // l10n: no; src: Scripts/l10n/scan.py, Scripts/l10n/scan-baseline.json, Scripts/l10n/swiftscan/ratchet.py, Scripts/agents/merge-chain.sh, Makefile -->

`scan.py lint` fails when a file has more unlocalized interface literals than `Scripts/l10n/scan-baseline.json` records for it, or a file the baseline does not list has any.
A branch never edits the baseline.
The merge chain runs `scan.py lint --base HEAD` on the merged tree, and aborts the merge (`L10N_LINT_FAILED`) when a file got worse.
On success it runs `scan.py lint --update-baseline`, which lowers each count that fell and drops a file that reached zero, and stages the baseline into the merge itself.
So the baseline falls with every conversion merged, and never rises.
A literal counts as localized when the compiler extracts it with a comment, and as marked when its line ends `// l10n: no`.
The scanner reads a log-only argument (`stop(reason:)`) as prose, so mark it.

## The catalog's merge driver
<!-- id: localization-merge-driver-setup; keys: make l10n-merge-driver, merge=xcstrings, shared key, comment merge, union merge; src: Makefile, Scripts/l10n/merge.py, .gitattributes -->

Git merges the catalog with its own driver (`merge=xcstrings` in `.gitattributes`), by key, language, and plural form.
Define the driver once for each clone with `make l10n-merge-driver`; without it git merges the catalog as text and neighbouring keys conflict.
Two waves that add the same short key ("Cancel") each write a comment for it, and the driver merges the two comments into one sorted list, as `xcstringstool sync` writes them.
Values, states, and plural forms that both sides changed still conflict.
[Translating TextMouth](translation.md#the-catalogs-merge-driver) describes the driver in full.

## The sync paths file
<!-- id: localization-sync-paths; keys: sync-paths.txt, union merge, unsorted, sorted, test_syncpaths, globs; src: Scripts/l10n/sync-paths.txt, Scripts/l10n/tests/test_syncpaths.py, .gitattributes -->

Each wave added the globs of its own files to `Scripts/l10n/sync-paths.txt`, and now that every file is converted the file holds one line, `TextMouth/**` (0d0a0d544), so a new file is synced without an edit here.
Git merges the file by union, which kept both sides' lines where each added them, so two waves that added at the same place left the file out of order.
`test_syncpaths` keeps the file sorted, and fails until someone sorts it again (e057b6036 did, after the pilot's merge): after a merge that touches the file, sort it before the suite.

## The pilot's patterns
<!-- id: localization-pilot-patterns; keys: conversion patterns, wording enum, plural string, glued sentence, announcement, logName, FR35; src: TextMouth/Models/EndOfBookWording.swift, TextMouth/Models/NextBookWindow.swift, TextMouth/Models/ReadingListReaderWording.swift, TextMouth/Models/Book.swift, TextMouth/Services/SleepTimerService.swift, TextMouth/Views/Reader/SleepTimerView.swift, TextMouth/Views/Reader/BookmarkPanelView.swift -->

The pilot (FR35) took the sleep timer, bookmarks, and the Reading List on both apps from English to Spanish.
Each pattern keeps the English word for word, so the suite's assertions keep passing; read the commit to see it worked.

1. A wording enum's `static let` becomes a computed `static var` with `String(localized:comment:)`, so no language is cached (d7b1b7784, `EndOfBookWording`).
2. A view's literal moves into the view's wording statics, which the view shows as a String, since a SwiftUI literal has no comment (d7b1b7784, `SleepTimerView`; 6a13a6387, `BookmarkPanelView`).
   A static that a plain enum or a test reads is `nonisolated`, and each iPhone vocabulary member forwards to the Mac's static, so one definition serves both apps.
3. A count inside a sentence becomes the whole sentence with `%lld`, with English `one` and `other` forms added by `plural` (d7b1b7784; ea0aa881d).
4. A glued sentence becomes one whole string for each case of a `switch`, never `noun.singular + "s"` (d7b1b7784, `NextBookWindowWording`; ea0aa881d, `ReadingListReaderWording`).
   A label of parts joined with commas (`Bookmark.accessibilityLabel`) is one whole string for each set of parts, with positions in the comment (`%1$lld`, `%2$@`).
5. A raw value shown as a title keeps its raw value, which `config.json` stores (`// l10n: no`), and gains a `title`; every place that showed the raw value shows `title` (d7b1b7784, `NextBookWindow`).
6. An announcement is one `nonisolated static func` that the Mac and the phone share, not two copies of a literal (6a13a6387).
7. A time uses `Duration.formatted(.time(pattern: .minuteSecond))` in place of `String(format: "%d:%02d")`, which writes the same English past an hour ("61:00") and each language's digits (d7b1b7784, `SleepTimerService.formattedRemaining`).
8. Text the log also writes keeps an English `logName` beside the localized text, and the log writes that (5bb26946b, `BookSuccession.nothing(note:logName:)`).
9. A fragment that another area glues into its English sentence stays English until that area converts, marked `// l10n: no (inside <file>'s English sentences)` (ca30f4cd4, `EndOfBookWording.kind(isArticle:)`).
10. A sentence that names another control interpolates the control's shown name, so the two agree in every language, and a translation never types another control's English (d8d7f9405).
11. Whole sentences join through `SentenceWording.joined(_:)`, never `joined(separator: " ")`.
    Each sentence ends with its own full stop first, and a list of non-sentences ("A, B and C") is `CountWording.list`.

## The patterns of the conversion waves
<!-- id: localization-wave-patterns; keys: LogDescribing, ItemNoun.choose, displayAuthor, IOSUnavailable, TextEncodingCatalog.Label, IOSBranchTests, FR34; src: TextMouth/Services/TranscriptionService.swift, TextMouth/Views/Feeds/FeedCommands.swift, TextMouth/Models/Book.swift, TextMouth/Services/AudioEditing/AudioFilterPresets.swift, TextMouth/Platform/iOS/IOSUnavailable.swift, TextMouth/Parsers/TextEncodingCatalog.swift, TextMouthProductionTests/IOSBranchTests.swift -->

The waves added these to the pilot's patterns (the numbering above goes on); each names a commit on main to read.

12. An error shown on screen and written to the log conforms to `LogDescribing` (`logDescription`, in `TranscriptionService.swift`), and the log writes `logDescription`, never `errorDescription` (feb1706d4, `TranscriptionError`).
    Many error types gained it: the importers' and the readers' failures, `BookExportFailure.logReason`, `ShortcutRefusal.logReason`, `BookCloudError.logReason`, `LegacyMigrationError.logDescription`.
    A type with a name the log also writes has an English `logName` beside the localized name (`BookFormat.logName`, `FeedFetchError.logName`).
13. A sentence that names a feed's items is written whole for each noun, never a noun glued into it: `ItemNoun.choose(episode:article:item:)` takes one whole sentence for each case, and asks only for the one that matches (5917491b1, `FeedCommands.swift`).
    So every language agrees its words with the noun.
14. A stored value that the interface also shows keeps its stored form, and the interface shows a localized twin beside it (pattern 5 is the first case):
    - `Book.displayAuthor(_:)` shows the stored "Unknown" placeholder in the interface language, and every other author as written (d9dde26f1);
    - `PremadeFilterPreset.title` beside the stored English name, which an edited copy keeps (1e97f78f1);
    - a shortcut action's raw value, a scope's `configName`, and a braille code's id stay as stored, and the interface shows a title.
    Ask of every enum raw value or stored string whether anything shows it; the stored form is never localized, since a library or a `config.json` written in one language must read in another.
15. A typed error case replaces a phrase glued into one English frame: `IOSUnavailable.convertingThisKindOfFile`, `.editingInAnotherApp`, and `.showingLogsInFinder` each hold a whole sentence (2d38de070).
    `feature(_:)` stays English until its four callers convert, marked `// l10n: no (inside IOSUnavailable's English sentence ...)`; see [the stand-ins](../architecture/platforms.md#the-ios-stand-ins-and-iosunavailable).
16. A choice that code makes about a name compares the name's identity, never its localized text: `TextEncodingCatalog.Label` has one case for each encoding name, and `TextEncodingChoices` compares labels (33cd7c8e4).
    Foundation's names for an encoding differ from ours in English too, so comparing text was never right.
17. Mac code names no `Phone*` type outside an iOS branch, which `IOSBranchTests.testOnlyTheIPhonesFoldersNameItsTypesOutsideAnIOSBranch` enforces by reading the source.
    The phone's words forward to the Mac's statics; where Mac code needs a word the phone's type holds (Cancel), it gets its own static with the same key and comment, so the catalog is unchanged (33df32b4d).
    A comparison against a menu's or a button's title follows pattern 10 and the menus bullet below.

## The rules that bite
<!-- id: localization-rules-that-bite; keys: identifier, count grouping, debug log English, menu titles, fragment, app-wide keys, MenuVisibilityManager, Stepper; src: TextMouth/Platform/macOS/Services/MenuVisibilityManager.swift, TextMouth/Models/Book.swift, TextMouth/ViewModels/ReaderViewModel+GoingOn.swift, TextMouth/Models/EndOfBookWording.swift, TextMouth/ViewModels/LibraryViewModel+Cloud.swift -->

- **The debug log stays English.**
  A localized property interpolated into a log line puts the interface language into the log.
  Give the type an English `logName` beside the localized text (`BookSuccession.nothing(note:logName:)`), and mark a log-only argument `// l10n: no`.
  Search the whole app, not only the area's files, for `DiagnosticLog`, `timerLog`, and `SleepTimerService.log` lines that interpolate text a wave localized.
  `CountWording.list(titles)` is written into log lines in `LibraryViewModel+Cloud.swift` (`KEEP_ON_MAC`, `REMOVE_DOWNLOAD_STARTED`, and the origin's `started` line), and once localized it writes "y" in Spanish: log the titles joined with ", ".
- **Menus match localized titles.**
  A `CommandMenu("Bookmarks")` literal is a key, so translating "Bookmarks" renames the menu, and code that compares a menu's title against English stops matching.
  `MenuVisibilityManager` keeps each menu's keys in one list marked `// l10n: no` and hides by `titles(for:locale:)`, which holds each key, its text in the app's bundle, and its text in a locale; a test names a Spanish locale and finds "Marcadores".
  Before translating a short key, list every literal that holds it and every place that compares a title (`.title ==`, `contains(title)`, a set of titles).
- **An identifier stays ungrouped; a count is grouped.**
  An `Int` placeholder is formatted for the region, so 1234 reads "1,234" in en_US.
  That is right for a count ("1,000 books"), and wrong for a number that names a thing: a bookmark's number, a page or track number, an ID, a version.
  Write an identifier as `String(number)`, so the key holds `%@` and its comment says it is an identifier written without grouping (`Bookmark.name`, 93d5d874b).
  Ask of every `Int` placeholder whether it is counted or named, and test with 12345.
  A `Double` becomes `%lf` ("1.500000 seconds"): format it before interpolating.
- **A fragment inside another area's English sentence stays English** until that area converts, marked `// l10n: no (inside <file>'s English sentences)`.
  The pilot translated two such fragments, and the Spanish read "Downloading the next episodio: ...".
  A translation that must name another area's English control keeps the English name until that area converts, and the report lists it.
- **Keys are app-wide.**
  Once "Sleep Timer" has Spanish, every SwiftUI literal "Sleep Timer" shows it.
  The same sentence in two areas ("Available only while ...") is cut together or not at all, so the two read alike and share one translation.
- **A `Stepper("")`** extracts an empty key, and a hidden title with an explicit label is read twice on the Mac: give the stepper an empty view as its label (a0d1295b4).
- **Sentences joined with a full stop and a space** assume Latin punctuation.
  Japanese and Chinese need the joining localized, so use `SentenceWording.joined` (pattern 11).
- **The phone's vocabulary tests read the Mac's source** for inline literals (`PhoneSleepTimerVocabularyTests`, `PhoneBookmarksVocabularyTests`, and others), so converting a Mac view breaks them by design.
  Rewrite each to check that the phone's word equals the Mac's static and that the Mac's source shows the static (7235ee4c4); search the tests for each converted file's name, since the English will not find them.

## What a wave puts in its brief
<!-- id: localization-wave-brief; keys: wave, conversion area, train request, sync-paths globs, code and catalog together, reach; src: Scripts/l10n/l10n.py, Scripts/l10n/reach.py, Scripts/l10n/sync-paths.txt, Scripts/agents/build-train.py -->

- The exact files, the globs to add to `sync-paths.txt`, and the shared files of which only the area's own text may change.
- The patterns above, and the rules that bite.
- English unchanged in the conversion: about 5,600 test assertions compare it, and only tests that read source text change.
- The commands, in order: `scan.py show FILE` until it shows nothing; `l10n.py sync --worktree`; `plural` for each count that can be one; `check`; the type-checks.
- Code and catalog committed together, area by area.
- The train request: the classes `reach` finds, the iPhone bundle, and every test class whose file names a converted file; the `phone` area whenever an iPhone file or a shared file changed.
- Cutting the text (a step of its own, whose cuts the user hears first) and translating it (the translators' work) are separate steps.
- Translating the catalog's strings in batches is its own work: see [Translating at scale](translation.md#translating-at-scale).
- An area of about 60 strings took the pilot's Opus agent about two hours to convert and test, most of it waiting for the sync, the type-checks, and a train: plan one area of up to 100 strings for each agent.
