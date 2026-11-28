# Localizing TextMouth's code
<!-- id: localizing-textmouth-code; keys: FR39, localization, interface text, InterfaceText.line, ID, pack, developers; src: TextMouth/Localization/InterfaceText/InterfaceTextLine.swift, Scripts/l10n/l10n.py, TextMouth/Localization/Localizable.xcstrings -->

Part of [TextMouth's documentation](../../README.md).

This page is for the developer or agent who writes or changes a line of text a person reads or hears, in either app.
A translator reads [Translating TextMouth](translation.md) instead: it covers the catalog's states, the translation steps, and the rules for every language, and this page does not repeat it.
TextMouth looks up its own words with its own engine, not Apple's string lookup (FR39).
The design and its measurements are in `research/STRINGS-SYSTEM-DESIGN-2026-11-21.md`.

## Writing a line
<!-- id: localization-the-call; keys: InterfaceText.line, Wording enum, Translators note, number, text, specifier, comment argument, one call to a line; src: TextMouth/Localization/InterfaceText/InterfaceTextLine.swift, TextMouth/Localization/InterfaceText/InterfaceTextFormat.swift, TextMouth/Models/InterfaceLanguagePicker.swift, Scripts/l10n/interface_calls.py, Scripts/l10n/scan.py -->

Every line is a call, written in a `…Wording` enum so that a test can name it:

    // Translators: Title of the group in Settings where the person picks the language of TextMouth's own words (menus, windows, messages), and the label of its pop-up. Appears on the Mac in the Miscellaneous tab and on the iPhone in its own section.
    InterfaceText.line("interfaceLanguage.title", "Interface Language")

- The ID is a plain string literal, so the sync can read it; the English is the line as the code holds it.
- The note for the translators is one `// Translators: <note>` line directly above the line that holds the call, at its indentation.
  It says where the text appears and what each placeholder holds.
  A call starts on a line of its own, so a note belongs to one call.
- A value inside the English is one of two forms: `\(number: n)` for an integer (`%lld`), and `\(text)` for any string (`%@`).
  Nothing else compiles (a `Double`, an enum, an `Int` without `number:`): format a value first, then interpolate the text.
- A `%` in a literal with interpolations is doubled for you; a literal with none is kept as written.
- A line that holds a count and several forms is a plural line (below).
- Write no `String(localized:)`, `LocalizedStringResource`, `NSLocalizedString`, or SwiftUI literal key (`Text("…")`, `Button("…")`): no table of Apple's ships, so each would show its key.
  `make lint-l10n` refuses them, and a `comment:` argument, a call with no note above it, and a line that holds two calls.
- A string that no person reads (a stored value, an identifier, a log line) is marked `// l10n: no (reason)` at the end of its line, and is no call.

## IDs
<!-- id: localization-ids; keys: ID form, permanent ID, retired-ids.txt, ids.py suggest, common ID, one ID one English; src: Scripts/l10n/ids.py, Scripts/l10n/retired-ids.txt, Scripts/l10n/interface_calls.py, Scripts/l10n/sync.py -->

- An ID is two to four lower-camel segments joined by dots, at most 48 characters: `endOfBook.starting`, `common.cancel`.
  The first segment names the owner (the type without `Wording`), the next the member, and a switch's case may be a last segment.
  A text that several types share is `common.…`.
- An ID is permanent and means one English text: a call elsewhere with other English needs an ID of its own.
  Changing the English of an existing ID marks every other language's translation `needs_review`, so do it only on purpose, and translate it again.
- An ID that left the catalog is never given again.
  `Scripts/l10n/retired-ids.txt` lists them, one to a line, `l10n.py prune` appends the ones it deletes, and `sync` and `lint` refuse a retired ID.
- `python3 -I -B Scripts/l10n/ids.py suggest FILE:LINE` proposes an ID for the call on that line by these rules, clear of every ID in use and every retired one.

## Plural lines
<!-- id: localization-plural-lines; keys: plural, one, other, few, many, l10n.py plural, count sentence, PluralRules; status: incomplete; issues: TL14; src: Scripts/l10n/l10n.py, Scripts/l10n/translate.py, TextMouth/Localization/InterfaceText/PluralRules.swift, TextMouth/Models/CountWording.swift -->

A sentence with a count is one whole sentence with `\(number: n)`, never a noun glued on (`noun + "s"`), since languages agree words with the count in their own ways.
Its forms live in the catalog: write the English ones with

    python3 -I -B Scripts/l10n/l10n.py plural <ID> --lang en --one "%lld book" --other "%lld books"

and the translators add each language's forms, as many as `PluralRules` gives the language.
The engine uses the first number among the call's arguments to pick the form, and the English forms from the pack too: a call's own English may be any form, usually `one`.
Give every count sentence English `one` and `other`, even one that never says one, since `apply` refuses plural forms for an ID whose English has none.
That limit and `plural`'s refusal of a plural that agrees with a second number are TL14.
Where the English has no plural entry, the call's own text is shown at every count.

## The engine
<!-- id: localization-engine; keys: InterfaceTextEngine, Strings.pack, lookup order, fallback, specifier check, FormatSpecifiers, INTERFACE_TEXT_PROBLEM, never traps; src: TextMouth/Localization/InterfaceText/InterfaceTextEngine.swift, TextMouth/Localization/InterfaceText/InterfaceTextPack.swift, TextMouth/Localization/InterfaceText/FormatSpecifiers.swift, TextMouth/Localization/InterfaceText/InterfaceTextLine.swift, TextMouth/Localization/InterfaceText/PluralRules.swift -->

`TextMouth/Localization/InterfaceText/` holds the engine, which both apps share.
It reads `Strings.pack` from the app's resources: the IDs, the English, the notes, and one compressed blob for each language.
The pack's container is `Scripts/packs/packfile.py` and `PackContainer.swift` (see The pack's compression, below), and what its blobs hold is in `Scripts/l10n/pack.py` and `InterfaceTextPack.swift`; the reader treats the file as untrusted bytes and checks every bound before it reads.
A lookup of `InterfaceText.line(id, english)` goes in this order:

1. It finds the ID by binary search over the pack's ID list, with no allocation.
2. It takes the person's own line for the ID in the language when the person has one ([the person's own lines](../architecture/state/interface-text.md#the-persons-own-lines)), else, for any language but English, the language's entry for the ID.
   A plural entry gives the form `PluralRules` picks for the call's first number, and the last form when the call has no number.
3. It checks the entry's specifiers against the call's arguments, once for each language and ID.
   Only five forms are allowed: `%@`, `%n$@`, `%lld`, `%n$lld`, and `%%`, each the kind of argument it reads, numbered and unnumbered never mixed.
4. A text with no `%`, or a call with no arguments, is returned as it is; any other goes through `String(format:locale:arguments:)` with the interface locale.

It falls back to the call's own English when there is no pack, no entry for the ID in the language, a text that fails its check, or an ID the pack lacks, and it never traps.
For a plural line the fallback is the pack's English forms when they fit the call.
Each problem (a missing or damaged pack, an unknown ID, a text that fails its check) is reported once, in English, to the debug log as `INTERFACE_TEXT_PROBLEM: …`; the engine itself never imports the logger.
Each language's decoded entries are kept after their first use, and the notes are never decoded.

## The pack's compression
<!-- id: localization-pack-compression; keys: Strings.pack, bzip2, LZMA, xz, libbz2, CBZip2, directory record, format 2; src: Scripts/l10n/pack.py, Scripts/packs/packfile.py, TextMouth/Packs/PackContainer.swift, TextMouth/Localization/InterfaceText/InterfaceTextPack.swift, Vendor/CBZip2/include/module.modulemap, project.yml, Scripts/check.sh, TextMouthProductionTests/InterfaceTextTests.swift, TextMouthProductionTests/PackContainerTests.swift, Scripts/l10n/tests/test_pack.py, Scripts/packs/tests/test_packfile.py -->

The container is shared with BrailleTables.pack (see [Braille table pack](../architecture/state/braille-table-pack.md)): `Scripts/packs/packfile.py` writes it and `TextMouth/Packs/PackContainer.swift` reads it, so the two packs cannot drift apart.
It knows only the framing: the header, the directory, the bounds, and the compression.
Each pack gives it a format (its magic, its version, and the limits that stop a hostile header) and says what its blobs hold, and a pack can check each directory record in file order (`recordCheck`).
The header's count is the number of IDs here and the number of table files in the braille pack.
This pack's magic is `TMSP` and its format is 2: the header's version is 2, and each blob's 32-byte directory record ends with its method.
- Method 0 is an xz stream (LZMA2), which Apple's Compression framework decodes (`COMPRESSION_LZMA`).
- Method 1 is a bzip2 stream, which the system's `libbz2` decodes in one call.
- `pack.py build` compresses each blob both ways and keeps the smaller, LZMA on a tie, so the two can mix in one pack.
- The reader refuses any other version, format 1 included, right after the magic, and any other method.
  A pack it refuses gives English, as a missing one does, and the problem is reported once (see The engine, above).
- `make check` holds each app's pack to `PACK_LIMIT_BYTES` in `Scripts/check.sh`.
- The apps link the system's `libbz2` through the `CBZip2` module, whose module map (`Vendor/CBZip2/include/module.modulemap`) imports the SDK's own bzip2 header and links `bz2`; project.yml puts it on `SWIFT_INCLUDE_PATHS`.
  Nothing of bzip2 is vendored.
- `InterfaceTextTests` reads both methods in one pack, a stream under the wrong method, and garbage in a blob, each giving English and one report; `Scripts/l10n/tests/test_pack.py` tests the builder.
- `PackContainerTests` test the container reader with a format of its own, both methods, and damage, and `Scripts/packs/tests/test_packfile.py` tests the writer.
- A tool that compiles the engine outside the app, as the type-check of the iPhone's code does, needs `Vendor/CBZip2/include` on its include path.
  `Scripts/ios/typecheck.py` and `Scripts/l10n/verify_packs.py` pass it, and `verify_packs.py` compiles `PackContainer.swift` with the engine.

## The interface language
<!-- id: localization-interface-language; keys: InterfaceLanguageChoice, choose, select, observer, didChange, followsInterfaceLanguage, WindowTitleFollower, AppleLanguages; src: TextMouth/Localization/InterfaceText/InterfaceLanguage.swift, TextMouth/Localization/InterfaceText/InterfaceLanguageChoice.swift, TextMouth/Views/InterfaceLanguageEnvironment.swift, TextMouth/Platform/macOS/Views/WindowTitleFollower.swift, TextMouth/App/MenuCommands.swift, TextMouth/Platform/iOS/App/MagicTapWindow.swift -->

`InterfaceLanguage.current` is the language and the locale every lookup reads: one immutable value behind a lock, swapped whole by a switch.
The person's choice (`InterfaceLanguageChoice`) is System or one of the 25 languages, kept in the app's own preferences domain, under the key AppleLanguages: a language writes `[code]` and System removes the key, which is what the system's per-app language setting writes too.
A stored value the app does not carry reads as System.
Under System the language is the first of `Bundle.main.preferredLocalizations` that the app carries, and the locale is `Locale.autoupdatingCurrent`.
Under hosted tests System is English with `en_US`, so the suite does not follow the Mac it runs on.

- `InterfaceLanguage.choose(_:)` saves the choice and switches at once through `select`.
  The picker's `InterfaceLanguagePicker.apply` calls it and announces the new language through VoiceOver in that language; see [the picker](../user/settings.md#the-language-of-the-interface).
- A lookup registers a SwiftUI dependency, so a switch runs again every body that looked up a line, and nothing else: focus, selection, and scroll position stay.
- `InterfaceLanguage.observer` is what the `Commands` structs of the menu bar observe, and `InterfaceLanguage.didChange` is the notification AppKit and UIKit code listens to.
- `followsInterfaceLanguage()` goes on the root of every window.
  It sets the view tree's locale and its layout direction, which is right to left for Arabic, Hebrew, Persian, and Urdu.
- A window whose title the code sets once uses `WindowTitleFollower.follow(window) { title }`, which sets it again after each switch: the Record, Search Library, and audio editor windows, and the quit notice's panel.
  An alert or file panel already open keeps its words until it closes; every open window is worded again.
- A test, or a title set that must read a line in another language, binds `InterfaceLanguage.$scopedLanguage.withValue("es") { … }`, or passes `language:` to `InterfaceText.line`, so nothing global changes.
- A formatted number or date is written with the interface locale: use `interfaceFormatted()` (`TextMouth/Localization/InterfaceFormatting.swift`), not `Locale.current`, which keeps the launch's language after a live switch.

## What stays Apple's
<!-- id: localization-what-stays-apples; keys: InfoPlist.strings, CFBundleLocalizations, CFBundleDisplayName, locale, language names, system panels; src: Scripts/l10n/pack.py, TextMouth/Resources/Info.plist, TextMouth/Platform/iOS/Info.plist, TextMouth/Localization/InterfaceFormatting.swift, TextMouth/Models/InterfaceLanguagePicker.swift -->

- `InfoPlist.strings`: the system reads the app's Info.plist strings from each language's `.lproj` folder, so `pack.py` writes one there for each language.
- `CFBundleLocalizations` in both Info.plists lists the 25 languages, which keeps the bundle's languages for the system.
  `l10n.py check` holds the list to the catalog's.
- The formatters' locale: Foundation writes numbers and dates, and `String(format:locale:)` writes a line's numbers, from the interface locale (`InterfaceLanguage.locale(for:region:)`), with the system's region.
- The picker's language names come from Foundation, and the system's own panels and menu items change at the next launch.

## What the apps ship
<!-- id: localization-what-ships; keys: Strings.pack, lproj, verify_packs.py, InterfaceTextShippedPackTests, PluralRules, remove-apple-tables, TextMouth Test, TEXTMOUTH_TEST_DISPLAY_NAME; src: Scripts/l10n/pack.py, Scripts/l10n/verify_packs.py, Scripts/l10n/pack-probe/main.swift, TextMouthProductionTests/InterfaceTextShippedPackTests.swift, Scripts/check.sh, project.yml, TextMouth/Resources/Info.plist -->

Each app ships one `Strings.pack` and no table of Apple's.
The build phase "Pack interface text" (`project.yml`) builds the pack from the catalog with `Scripts/l10n/pack.py`, writes each language's `InfoPlist.strings`, and removes any Localizable table of Apple's that an earlier build left (`--remove-apple-tables`).
A Debug build, the tests' host, is named TextMouth Test: the phase writes `TEXTMOUTH_TEST_DISPLAY_NAME` (`project.yml`) into each `InfoPlist.strings` as `CFBundleDisplayName`, so the Dock, the app switcher, and VoiceOver tell it from the installed app.
A Release build keeps the name TextMouth, and `make check` fails one that a test name reached.
Three checks hold it:
- `make l10n-check` runs `verify_packs.py`, with the probe in `Scripts/l10n/pack-probe/`.
  It compiles the catalog with `xcstringstool` in a folder of its own and compares the engine with Apple's lookup there, for every ID in every language at 13 counts.
  It also checks the system's choice of language for 52 preference lists;
- `InterfaceTextShippedPackTests`, on both apps, compares the shipped pack with the catalog, and checks that the bundle holds the 25 languages and no table of Apple's;
- `make check` fails an app that ships a table of Apple's, or a `.lproj` folder without its `InfoPlist.strings`.

A new language needs its plural rule in `PluralRules`, which `InterfaceTextTests` checks against Apple's own rule.

## The commands
<!-- id: localization-commands; keys: make l10n-sync, l10n-status, l10n-check, lint-l10n, plural, prune, reach, todo; src: Makefile, Scripts/l10n/l10n.py, Scripts/l10n/scan.py, Scripts/l10n/reach.py -->

Run `l10n.py` as `python3 -I -B Scripts/l10n/l10n.py COMMAND`; `--help` lists each command's options.

- `make l10n-sync` brings the catalog into step with the code's calls, in about two seconds (below).
  Run it after adding or changing a line, commit the catalog with the code, and run `l10n.py check`, which must find 0 problems.
  The branch that adds or changes a line also translates it into all 24 other languages before it merges, with `l10n.py todo` and `apply` (see [Translating TextMouth](translation.md#the-steps)); `l10n.py status` must show 0 missing.
  A line left in English shows English in every language, and each line is 24 texts to translate and review, so keep new text short and few.
- `l10n.py check` holds the catalog to the code: each `en` equals the call's English, and the notes, placeholders, plural forms, empty values, stale IDs, and the bundle's language list are in order.
  `make l10n-check` runs it, then `verify_packs.py`, and `make check` runs `l10n-check`.
- `make l10n-status` counts each language's strings by state (`LANG_CODE=es` for one), and `make l10n-size` is the size report.
- `l10n.py plural ID --lang en --one … --other …` writes an ID's plural forms.
- `l10n.py prune` deletes the stale IDs that hold no translation and retires them; `prune --all` and `--dry-run` are in [Translating TextMouth](translation.md#syncing-pruning-and-the-test-classes).
- `l10n.py reach` lists the test classes the branch's localization could break, for `build-train.py request --classes`, and the iPhone unit classes on a line of their own.
- `make lint-l10n` runs `scan.py lint` (below).
  `scan.py show FILE` lists a file's interface literals that are no call yet, and its notes that are missing or misplaced.
- `todo` and `apply` are the translators' commands; see [Translating TextMouth](translation.md).
- The l10n tools' speed tests (`Scripts/l10n/tests`) time their own CPU (`time.process_time`), not the clock, so a busy Mac cannot fail them.

## How the sync reads the code
<!-- id: localization-sync-reads-code; keys: sync, lexer, InterfaceText.line, refusals, stale, needs_review, locations.json, sync time; src: Scripts/l10n/sync.py, Scripts/l10n/interface_calls.py, Scripts/l10n/l10n.py -->

`sync` reads every `InterfaceText.line("<ID>", "<English>")` call in `TextMouth/` with the lexer (`Scripts/l10n/sync.py`), in about two seconds, with no build and no heavy-work lock.
A new ID gets its English as `en` and its note as the comment; an ID the code no longer has is marked stale; an ID whose English changed gets the new `en`, and every other language `needs_review`.
It refuses, and writes nothing, an ID outside the pattern or retired, one ID with two English texts, a call with no note above it, two calls on one line, and an ID or English that is not one plain literal.
It writes the catalog only when something changed, and `build/l10n/locations.json`, which `todo` reads, every time.

## The scanner's lint
<!-- id: localization-scanner-ratchet; keys: scan-baseline.json, lint-l10n, ratchet, merge chain, L10N_LINT_FAILED, --update-baseline, // l10n: no, apple lookup; src: Scripts/l10n/scan.py, Scripts/l10n/scan-baseline.json, Scripts/l10n/apple_lookups.py, Scripts/l10n/swiftscan/ratchet.py, Scripts/agents/merge-chain.sh, Makefile -->

`scan.py lint` fails when a file has more interface literals that are no `InterfaceText.line` call than `Scripts/l10n/scan-baseline.json` records for it, or a file the baseline does not list has any.
Every file is at zero now, so the baseline lists none, and any such literal fails.
A literal counts as a call's English when it is the call's literal, and as marked when its line ends `// l10n: no`.
The scanner reads a log-only argument (`stop(reason:)`) as prose, so mark it.
In every file of `TextMouth/` it also fails on a lookup into Apple's tables (`apple_lookups.py`), a `comment:` argument, a call with no note above it, a line that holds two calls, and an ID outside the pattern or retired.
A branch never edits the baseline.
The merge chain runs `scan.py lint --base HEAD` on the merged tree and aborts the merge (`L10N_LINT_FAILED`) when a file got worse; on success it runs `scan.py lint --update-baseline`, which lowers a count that fell and never raises one.

## The catalog's merge driver
<!-- id: localization-merge-driver-setup; keys: make l10n-merge-driver, merge=xcstrings, shared ID, comment merge, union merge; src: Makefile, Scripts/l10n/merge.py, .gitattributes -->

Git merges the catalog with its own driver (`merge=xcstrings` in `.gitattributes`), by ID, language, and plural form.
Define the driver once for each clone with `make l10n-merge-driver`; without it git merges the catalog as text and neighbouring IDs conflict.
Values, states, and plural forms that both sides changed still conflict.
[Translating TextMouth](translation.md#the-catalogs-merge-driver) describes the driver in full.

## The size budget
<!-- id: localization-size-budget; keys: 150 KB, budgetBytes, budgetFails, l10n-size, English bytes; status: incomplete; issues: FR34; src: Scripts/l10n/config.json, Scripts/l10n/l10n.py -->

The English text in the catalog has a budget of 150,000 bytes (`budgetBytes` in `Scripts/l10n/config.json`), and `make l10n-size` reports it, with each blob of the pack.
The English is over the budget now.
The budget only reports (`budgetFails` is false); it will fail once the cutting is done.

## Writing a line well
<!-- id: localization-rules-that-bite; keys: whole sentence, glued sentence, logName, LogDescribing, SentenceWording, stored value, grouping, menu titles; src: TextMouth/Models/SentenceWording.swift, TextMouth/Models/CountWording.swift, TextMouth/Services/TranscriptionService.swift, TextMouth/Models/Book.swift, TextMouth/Views/Feeds/FeedCommands.swift, TextMouth/Parsers/TextEncodingCatalog.swift, TextMouth/Platform/macOS/Services/MenuVisibilityManager.swift, TextMouthProductionTests/IOSBranchTests.swift -->

- **Whole sentences.**
  A sentence is one line for each case of a `switch`, never a noun glued into it: `ItemNoun.choose(episode:article:item:)` takes one sentence for each noun.
  A label of parts joined with commas is one line for each set of parts, with positions in the note (`%1$lld`, `%2$@`).
  Whole sentences join through `SentenceWording.joined(_:)`, each ending with its own full stop first, and a list of non-sentences ("A, B and C") is `CountWording.list`, since Japanese and Chinese join with none.
- **The debug log stays English.**
  A localized property interpolated into a log line puts the interface language into the log.
  Give the type an English `logName` beside the localized text, and mark a log-only argument `// l10n: no`.
  An error shown on screen and written to the log conforms to `LogDescribing`, and the log writes `logDescription`, never `errorDescription`.
- **A stored value is never localized.**
  An enum raw value or a stored string that the interface also shows keeps its stored form, and the interface shows a twin (`Book.displayAuthor(_:)` for the stored "Unknown"), since a library or a `config.json` written in one language must read in another.
  Code that chooses by a name compares its identity, never its localized text (`TextEncodingCatalog.Label`).
- **An identifier is ungrouped; a count is grouped.**
  An `\(number:)` is formatted for the region, so 1234 reads "1,234" in en_US: right for a count, wrong for a number that names a thing (a bookmark's number, a page, an ID).
  Write an identifier as text, `\(String(number))`, and say so in the note.
- **Menus match localized titles.**
  A menu's title is a line, so code that compares a menu's title against English stops matching.
  `MenuVisibilityManager.titles(for:languages:)` holds each title in the interface language, in English, and in the languages a test names.
- **The phone's words forward to the Mac's.**
  Mac code names no `Phone*` type outside an iOS branch, which `IOSBranchTests` enforces by reading the source.
- **Keep the English** of an existing line unless you mean to change it: about 5,600 test assertions compare it, and a changed English sends every translation to `needs_review`.
