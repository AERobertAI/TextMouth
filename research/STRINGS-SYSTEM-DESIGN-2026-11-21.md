# TextMouth's own interface-string system: design (November 21, 2026)

Part of [the research folder](README.md).
Issue: FR39, with TL14, TL15, and TL19; it builds on [the compression research](LOCALIZATION-COMPRESSION-RESEARCH-2026-11-21.md).
Written before any change; no code was touched.
Measured on main at 49b8c3ded (0.5.8: 25 languages, 4,190 strings) with small probes in a scratch folder, on macOS 26.3.1 and Swift 6.2.

## What this design decides

The user's eight decisions of November 21 stand as the brief gives them; this design settles the rest.

- IDs are `owner.member[.case]` in lower camel case, taken once from the Swift declaration that holds each string, then frozen; a key used by several types becomes `common.*`, and TL14's keys split by use.
- A call site is `InterfaceText.line("endOfBook.starting", "Starting: \(title)")`; an integer interpolates as `\(number: n)`, and nothing else compiles.
- TextMouth picks the text and its plural form, and Foundation's `String(format:locale:arguments:)` writes it with `Locale.current`: identical to `String(localized:)` in all 215,750 lookups measured.
- One `Strings.pack` holds the IDs, the English, the notes, and one LZMA blob for each language: 1.28 MB against 11.40 MB today, decoded into memory in 1 to 2.3 ms; no cache folder.
- The code holds the English; a new `sync` reads it from the sources in seconds, without the compiler or the heavy-work lock, and keeps the catalog's `en` values with it.
- The call sites convert while the catalog keeps its English keys, a table mapping each to its ID; then the catalog is re-keyed; then Apple's tables leave.
- The picker defaults to System and switches at once; a choice also writes the app's own `AppleLanguages`, so from the next launch it is the system's per-app language, exactly.
- Overrides live in `interface_text.json` in the data folder: every language, changed lines only, in the shape the Export writes.

## What the code holds today

- `String(localized:)` with a literal: 4,601 calls in 242 files, each under its `// Translators:` line, reaching all 4,190 keys; 224 keys have two sites or more (Cancel has 25).
- Two more calls take a runtime key: `MenuVisibilityManager.titles(for:locale:)`, one of them through `LocalizedStringResource(_:locale:)`.
- SwiftUI literal keys: none.
  Every `Text`, `Button`, `Label`, `Toggle`, `Picker`, `.help`, `.accessibilityLabel` or hint, alert, and `CommandMenu` title is given a `String` from a wording member, which SwiftUI shows verbatim, so no view changes.
- None of `NSLocalizedString`, `AttributedString(localized:)`, a format-style interpolation, a multi-line or raw localized literal, a device variation, or a substitution.
- The keys hold only `%@` (1,808) and `%lld` (398), never a position; translations number them in 10,391 units, 1,042 of which change their order.
- 321 keys are plural (English `one` and `other`; plural in all 25 languages), 49 hold `%lld` without plural forms, and 28 hold two numbers or more.
  `xcstringstool` makes the first `%lld` the plural argument (`%2$#@value@` in 1,100 compiled entries, `%3$#@value@` in 50), and warns for one key (TL14 item 9).
- Every call is evaluated when asked: 1,586 sit in computed static properties, 583 in computed instance properties, and the rest in function bodies and their `switch` arms; no `static let` or stored property holds one.

By the translators' six areas (a file belongs to the area of its scanner feature; 5 sites tie to no single key by the scanner alone, an ambiguous `%@` or `%lld`, and `locations.json` ties them):

| Area | Sites | Files | In wording types | Plain | One `%@` | One `%lld` | Two or more | Plural |
|---|---|---|---|---|---|---|---|---|
| Library | 808 | 26 | 710 | 485 | 175 | 0 | 77 | 70 |
| Storage and settings | 832 | 36 | 533 | 527 | 161 | 5 | 86 | 51 |
| Feeds and import | 763 | 47 | 579 | 401 | 180 | 1 | 65 | 115 |
| Audio and transcripts | 706 | 27 | 593 | 432 | 160 | 1 | 82 | 31 |
| Reader, formats, menus | 791 | 47 | 346 | 594 | 115 | 1 | 65 | 16 |
| Export, speech, iPhone | 701 | 59 | 486 | 468 | 130 | 5 | 42 | 55 |

## Measurements

- Apple's formatter: in a process for each language (`-AppleLanguages (xx)`, with Xcode's compiled tables compacted as the app ships them), `String(localized:)` equals `String(format: table text, locale: Locale.current, arguments:)`.
  That held for every key, each integer key at 13 counts: 8,630 lookups a language, 215,750 in all, no difference.
- A prototype of the engine, reading a prototype pack (binary search over the IDs, CLDR's rules, Foundation's formatter), equals `String(localized:)` in the same 215,750 lookups; it takes 4.3 to 5.5 µs a lookup against Apple's 5.6 to 8.1.
  Its first run found the pack format's one trap: the last entry lacked its terminator, so every entry now ends with one.
- Plural rules: in all 25 languages the Swift table below picks Foundation's category at every count tried up to 2^53: 0 to 10,000, and around each power of ten to 10^15 and around 2^53.
  Above 2^53 Foundation rounds the count through a `Double` (Russian 10^16 + 1 comes out `many`), first at 2^53 + 7 in Arabic; no count in the app comes near.
- Sizes: today's compact tables are 11,404,782 bytes; the pack is 1,192,280 (the ID list 26,004; English 42,980; each language 40,680 to 53,968), and the notes add 83,288.
- Decoding with Apple's LZMA decoder, NUL scan included: 1.0 to 2.3 ms a language (median of 15), 35 ms for all 26 blobs; the prototype builder, Python's `lzma` (xz, preset 9 extreme), writes the whole pack in 1.9 s.
- An explicit-locale lookup, `String(localized: LocalizedStringResource(value, locale:))`, takes 5.2 ms (it skips Foundation's table cache), so a test that loops over languages reads each language's own bundle instead.
- `Locale.current` under a per-app language is the language with the system's region: `es_US`, `ar_US` (Latin digits), `pt_US` for Brazilian Portuguese, `ko-Kore_US`, and `fa_US@numbers=latn`.
- With `CFBundleLocalizations` in the Info.plist and no `.lproj` folder at all, `Bundle.main.localizations` still lists the 25 and picks the same language.
- The estimate: the Mac app from 32.2 MB to about 22.2, the iPhone app from 27.1 to about 17.1, counting about 0.14 MB of ID literals in each executable.

## IDs

**Form.**
- Two to four segments, each lower camel case, ASCII letters and digits, starting with a letter: `[a-z][A-Za-z0-9]*(\.[a-z][A-Za-z0-9]*){1,3}`, at most 48 characters.
- `owner`: the innermost type declaring the member that holds the call, less a final Wording, Vocabulary, Words, or Text, with a leading run of capitals lowered whole (`EPUBExportWriter` gives `epubExportWriter`); FFmpeg is one word (`ffmpegImport`).
- `member`: the property or function; then the `switch` arm's case when the member switches over one, except that an error's `errorDescription`, `failureReason`, or `recoverySuggestion` gives way to the case alone.
- A member holding several strings outside cases adds the first three words of each English in lower camel case, then five, then a number.
- A key that several types use is `common.` and its first four words: Cancel is `common.cancel`.
- Examples from the prototype: `headingNavigatorView.levelFilterHint`, `feed.folderMissing`, `bookExport.nothingToExport`, `shortcutAction.title.editMode`, `dataDirectoryUnavailableError.errorDescription`.

**The generated table.**
- The prototype formed 3,969 keys from one declaration, 21 from one type's several members, and 200 as `common`; 1,357 needed words from their English; the median ID has 32 characters and the 90th percentile 50.
- 464 IDs came out over 48 characters and 236 ended in a digit: the generator lists them, and a reviewer shortens each once.
- `Scripts/l10n/ids.json` holds it: `{"version": 1, "ids": {"<key>": "<ID>"}, "splits": {"<key>": [{"id": "<ID>", "sites": ["<file>:<owner>.<member>"]}]}}`.
- `Scripts/l10n/ids.py propose` writes it from the sources and the catalog; `ids.py check` refuses a key without an ID, an ID given twice, one outside the pattern, and a split whose sites do not cover the key's.
- TL14's keys split by use, each new ID taking a copy of the key's every translation and state, so nothing heard changes: the brief's Book, End, Return, File, Subscribed, Unknown, Go To, and Insert, and TL14's New, Added %@, Library windows, by %@, Delete, Pause, Reset, `%@ %@`, and `%@, %@`.
  Unknown, for example, splits three ways: an author (`Book.displayAuthor`), a length (`TimeFormatting.totalSeconds`), and a voice's tier (`qualityLabel`).

**Stability.**
- An ID is permanent from its first merge: it is a literal at the call, so renaming Swift code never renames it, and a retired ID goes to `Scripts/l10n/retired-ids.txt`, which `sync` refuses to see again.
- Rewording the English keeps the ID: `sync` marks each translation `needs_review` and it keeps shipping, as Xcode does; a new meaning takes a new ID.
- Two calls may share an ID only with the same English and placeholders.
- A new string's ID is written by the developer by the rules above; `ids.py suggest FILE:LINE` proposes one.

**What follows the keys.**
- The glossary (285 terms) names English terms, never keys, so it is unchanged; its matching reads the `en` values.
- The review records' 6,231 fixes name 2,339 keys, all in the catalog: the migration adds `"id"` (or `"ids"` for a split key) to each fix and leaves `key` and `english` as written.

## The Swift API

```swift
// Translators: VoiceOver announcement as the next book starts playing after one ends. %@ is the next book's title.
InterfaceText.line("endOfBook.starting", "Starting: \(title)")
```

- `InterfaceText` is a caseless enum shared by both apps; `line(_ id: StaticString, _ english: InterfaceText.Format) -> String` is `nonisolated` and safe on any thread.
  The ID is a `StaticString`, so it can only be a literal, which `sync` reads.
  The name `Wording` was the first choice, but three app files and a test declare a `typealias Wording`, and `PackageFileEditing.swift` a nested `struct Wording`, which would hide it.
- `InterfaceText.Format` is `ExpressibleByStringInterpolation` and `Sendable`.
  A literal segment adds its text with each `%` doubled, `\(text)` takes `some StringProtocol` and adds `%@`, and `\(number: n)` takes `some BinaryInteger` and adds `%lld`.
  No other interpolation compiles (a `Double`, an enum, an `Int` without `number:`), so the format equals the key Xcode extracts today, character for character.
- The note stays a `// Translators:` line directly above the call's line, one call to a line, as TL15 has it.

Each pattern of the code, as the codemod rewrites it:
- A wording property: `static var title: String { InterfaceText.line("common.sleepTimer", "Sleep Timer") }`, a key that several types share.
- A text with a value: `InterfaceText.line("feed.folderMissing", "The folder of \(name) is no longer in the library.")`.
- A count: `InterfaceText.line("common.books", "\(number: count) books")`; its English `one` comes from the catalog, as now.
- Two numbers: `InterfaceText.line("readerCloud.progressValue.of", "\(number: done) of \(name), \(number: percent)%")`, whose `%` the format doubles.
- A plural with two numbers: `InterfaceText.line("folderOperationConflict.message.tooDeep", "That would put \(name) \(number: depth) levels deep, but folders nest at most \(number: limit) levels.")`.
  Its form follows `depth`, the first number, as Xcode's compile does.
- A `switch` arm: `case .end: return InterfaceText.line("keyBinding.localizedKeyWords.end", "End")`.
- Views, menus, hints, help, and alerts: unchanged, since they show the members' strings (`Button(PlaybackControlsWording.pause)`, `CommandMenu(MenuWording.book)`).
- Another language, for tests and for title sets: `InterfaceText.line(id, english, language: "es")`.
  `MenuVisibilityManager` compares a menu's title against its ID's text in the current language and in English, replacing its two runtime-key calls.
- Formatters inside wording code take `InterfaceLanguage.current.locale` where they take `.current` today: `CountWording.list`, `LibraryViewEditorWording.listWithOr`, the `.formatted` calls, and byte counts.

**Live switching.**
- Each lookup reads `InterfaceLanguage.shared.state` through an `ObservationRegistrar` access.
  So any SwiftUI body that looked up a string depends on the language and runs again when it changes, and nothing else does: focus, selection, and scroll position stay.
- The `Commands` structs hold `@ObservedObject private var language = InterfaceLanguage.observer`, an `ObservableObject` that publishes on a switch, as they observe `FrontWindowKind.shared` now.
- AppKit code that sets a title once (three `NSWindow`s and one `NSPanel`) observes `InterfaceLanguage.didChange` and sets it again; an open `NSAlert` or panel keeps its words until it closes.
- Text a model stored earlier (about 30 assignments of a wording text to a message or title property) keeps its language until it is set again; the picker's phase lists them and makes each that stays on screen computed.

## The engine

Its core is Foundation only (the pack reader, the plural rules, the specifier check, the lookup), so the harness compiles it into a command-line probe, as `verify_packs.py` compiles `LanguagePackTests.swift` today; the observer, the notification, and the environment are separate files.

A lookup of `id` with `english`:
1. Take the state (language, formatting locale, tables, overrides) under an `OSAllocatedUnfairLock`; the tables are immutable `Sendable` values, so the rest runs without the lock.
2. Find the ID's index by binary search over the decoded ID list, comparing the `StaticString`'s bytes, with no allocation.
3. Take the first of: the person's override of that line; the pack's entry for the language; English.
   English is the call's own format for a plain line; for a plural line, the pack's English forms when their `other` equals the call's format, else the call's format at every count.
4. A plural entry gives the form of `PluralRules.category(of: firstNumber, language:)` for the language whose forms they are.
5. The text's specifiers are checked against the call's arguments once for each language and ID, and the verdict kept; a text that fails falls back to English and is logged once.
6. A text without `%` is returned as it is; any other goes to `String(format: text, locale: state.locale, arguments:)`.

- Decoded entries are kept for the language in use, so a second lookup of a line decodes nothing.
- At the first lookup the pack is memory-mapped and the ID list and the language in use decoded, about 3 ms on this Mac; English is decoded at its first need, and the notes only for an Export.
- Memory: the decoded blobs, at most about 0.8 MB, against the one table Foundation keeps today.
- A missing or unreadable pack, a blob whose size, entry count, or UTF-8 is wrong, an unknown ID, or a text that fails its check falls back to English, logs once in English, and never traps.
- Tests choose a language with a `@TaskLocal` (`InterfaceLanguage.$testLanguage`), as `BraillePreferences.tableForImports` is chosen.
  Under hosted tests System means English with `en_US` formatting, so the suite's interface text no longer follows the Mac's language (TL14 item 1).

## Plural rules

- `PluralRules` holds CLDR's cardinal rules for the 25 languages, for whole numbers, as `LanguagePackPluralRules.category(of:language:)` writes them; it moves from the tests into the app, and the tests use it.
- `Scripts/l10n/tests/test_plural_rules_swift.py` then reads the app's file, so the one Swift table and `catalog.py`'s `PLURAL_CATEGORIES` stay equal.
- The pack stores a plural entry's forms in the language's category order from that table, so the reader needs no names.
- Vietnamese stays `other` alone, as Foundation picks it although CLDR 49 gives it `one`.
- The hosted test that asks Foundation which category it picks, a stringsdict in the test's sandbox for each language, grows from 7 counts to 0 to 10,000 and the large ones below 2^53; it stays after Apple's tables leave, so an operating system that changes a rule shows.

## Numbers and dates inside strings

- `String(localized:)` writes a `%lld` with `Locale.current`: the region's grouping and digits, not the language's.
  Under a per-app Spanish on a US Mac it is `es_US` and 1234567 reads "1,234,567"; Arabic in Egypt's region is written with Arabic-Indic digits, and Persian in Iran's with Persian ones.
- Foundation wraps a `%@` argument in U+2068 and U+2069 when the format's first strong letter is right to left, or the argument holds right-to-left text, whatever the locale: 2,677 of Arabic's 8,630 lookups.
  Handing the text to Foundation keeps this exactly.
- Under System the engine formats with `Locale.current`, which the measurements show is identical.
- After a live switch the engine builds the locale Foundation would: the language without its region (`pt-BR` gives `pt`), the system's region, and Latin digits for Persian outside Iran and Afghanistan.
  Against Foundation under `-AppleLocale` in 12 regions (300 pairs) it matched 298; Persian in Saudi Arabia and Urdu in Iran keep the region's digits in Foundation, and those differ until the next launch.
- From the next launch the choice is the system's per-app language, so `Locale.current` is Foundation's own.
- No key holds a date: the code formats dates, lists, and sizes before interpolating them, so those formatters take `InterfaceLanguage.current.locale`, and SwiftUI's `Text(date, style:)` follows each window's environment locale.

## The pack

**Format, version 1** (`Strings.pack`, in each app's resources; little-endian):
- A header: the magic `TMSP`, the version (u16), flags (u16, zero), the SHA-256 of the catalog's content it was built from, the number of IDs (u32), and the number of blobs (u32).
- A directory, one record a blob: its name (12 bytes of ASCII padded with NULs: `ids`, `notes`, `en`, `es`, ...), its offset, its compressed size, its raw size, and its entry count (u32 each).
- The blobs, each an xz stream (LZMA2, preset 9 extreme), which Apple's `COMPRESSION_LZMA` decodes.
- `ids`: the IDs in code-point order; every other blob holds one entry for each ID in that order; every entry, the last included, ends with a NUL.
- A language entry is empty (no text: English is used), the text, or U+0001 followed by the forms in the language's category order, joined by U+0001; a plural whose forms are all one text is written as that text, as `compact_packs.py` squeezes today.
- `notes`: each ID's translators' note, for the Export.
- The reader checks the magic, the version, each blob's bounds, raw size, entry count, and UTF-8 before it uses a byte.

**The builder** (`Scripts/l10n/pack.py`, standard library only):
- `build` reads the catalog through `catalog.py`, keeping what Xcode compiles today (every state but `new`); during the transition `--ids Scripts/l10n/ids.json` maps English keys to IDs.
  It reads the catalog, not `compact_packs.py`'s output, because Xcode stops compiling the catalog at the switch; while both exist, the harness compares them.
- It refuses a specifier other than `%@`, `%n$@`, `%lld`, `%n$lld`, and `%%`, a control character other than a line feed or tab, a missing or extra plural category, a device variation or substitution (the catalog has none), and an ID outside the pattern.
- It writes the same bytes for the same catalog, so `make check`'s reproducibility holds; a stamp of the catalog's hash skips a build when nothing changed.
- `verify` decodes a pack and compares every entry with the catalog; `compare` compares two packs ID by ID; `size` reports each blob.
- A build phase, "Pack interface text", writes it into both apps before signing; after the switch it also writes each language's `InfoPlist.strings`.
- The budget: `make check` fails a pack over 1.5 MB, a language table left in an `.lproj`, or a pack whose hash is not the catalog's.

## Where the English lives, and the sync tool

- The code is the English's one source; the catalog's `en` values and English plural forms follow it, and the pack's English is built from the catalog.
- An English line shows the code's English at once, before any sync, so the tests' English is always the code's.
- `l10n.py sync` scans `TextMouth/**` with the scanner's lexer, in about two seconds, without the compiler or the heavy-work lock.
  - For each `InterfaceText.line` call it reads the ID, the English (a literal's `%` doubled, `\(number: …)` as `%lld`, any other interpolation as `%@`), the note above, and the place.
  - It refuses, writing nothing: an ID outside the pattern or retired, one ID with two English texts or two sets of placeholders, a missing note, two calls on one line, and a non-literal ID or English.
  - It adds a new ID with its English as `en` (state `translated`) and its notes as the comment, and marks an ID it no longer finds stale, for `prune`.
  - When an English text changed it writes the new one and marks the other languages `needs_review`; a plural's English `one` waits for `plural`, and `check` fails until it has it.
  - It writes `build/l10n/locations.json`, which `todo` reads, as now.
- During the transition `sync` is today's, plus a `.stringsdata` file it writes for the converted calls, so `xcstringstool sync` keeps their keys, and a check that each converted call's ID and English agree with `ids.json`.
- `make lint-l10n` keeps its ratchet and its notes rule, with these new rules once Apple's tables leave:
  - a literal is localized when it is the English of an `InterfaceText.line` call;
  - `String(localized:)`, `LocalizedStringResource`, `AttributedString(localized:)`, `NSLocalizedString`, and SwiftUI literal keys (`Text("…")` and the other calls `classify.py` lists) are refused anywhere in `TextMouth/`, since nothing would serve them;
  - an ID is a literal in the pattern and not retired.
- `l10n.py check` adds: each ID's `en` equals the code's English, each English plural's `other` equals the code's English, and only the five specifiers appear.
- The translators' commands keep their names and steps on the re-keyed catalog: a batch item's `key` is the ID beside its `english`, and `plural` takes an ID.
  Each place that uses the key as the English must read the `en` value: `english_shape`, `english_form`, and `unit_placeholder_problems` in `translate.py`, `Catalog.english_forms`, the similarity of `previous`, and `reach.py`'s search for English in tests.
- The catalog stays a valid String Catalog that Xcode can open, its entries marked `"extractionState" : "manual"`, but neither app compiles it.

## Language choice

**System.**
- Under System the language is `Bundle.main.preferredLocalizations.first`, Foundation's own choice from the person's languages, so it is today's by construction.
- Measured matches: zh-Hant-TW, zh-Hant-HK, zh-HK, zh-TW, and zh-MO give `zh-Hant`; zh-CN, zh-SG, and zh give `zh-Hans`; pt-PT, pt, and pt-AO give `pt-BR`; es-419, es-MX, and es-US give `es`.
  Also: iw gives `he`; nb alone gives English, the development region, while nb then sv gives `sv`; ca then es gives `es`; hi-Latn gives English.
- The bundle keeps the 25 languages two ways: `CFBundleLocalizations` in both Info.plists, and an `.lproj` folder per language holding its `InfoPlist.strings`.

**The picker.**
- Settings gets an Interface Language group: on the Mac at the top of the Miscellaneous tab, on the iPhone a section of its Settings.
- Its first choice is System, named with the language it gives ("System (English)"); then the 25, each read by its own name first and then by its name in the interface language ("Español, Spanish"), sorted by the first.
  Someone who switches by mistake to a language they cannot read finds their own by its own name.
- The choice is the app domain's `AppleLanguages`, the key the system's per-app language setting uses, so the two agree: a language writes `[code]`, System removes the key; hosted tests write a sandboxed store.
  The picker's phase checks by hand that System Settings and the iPhone's Settings show the choice.
- A change resolves the language and its locale, decodes its blob (about 2 ms), swaps the state, and announces the new language in that language through the announcement helpers.

**Switching at once.**
- SwiftUI: lookups re-run as above, and each window's root, through one modifier, sets `.environment(\.locale, …)` and `.environment(\.layoutDirection, …)` from the state, so formatters and right-to-left layout follow.
- AppKit: the menu bar's `Commands` re-run through the observer, `NSApp.mainMenu`'s `userInterfaceLayoutDirection` follows, and the windows titled from code set their titles again.
- The iPhone: the same root modifier on `MagicTapWindow`'s hosting controller, its view's `semanticContentAttribute` for UIKit's bars, and the window's `accessibilityLanguage`.
- What follows only from the next launch: the window frame's own direction, the menu items macOS supplies, and system panels, which is why the choice writes `AppleLanguages`.

## What stays Apple's

- The Info.plist strings, which the system reads: the app's name (never translated), the microphone and Apple Events prompts, and the document types' names, through each `.lproj`'s `InfoPlist.strings`; their IDs (`infoPlist.*`) live in the same catalog, and the pack's build phase writes those files.
- The `.lproj` folders and `CFBundleLocalizations`, so the system's per-app language lists and `preferredLocalizations` stay.
- The menu items macOS supplies (About, Services, Hide, Quit, the Edit and Window menus' standard items), the open and save panels' own controls, share sheets, permission alerts, the keyboard, and VoiceOver's own words (roles and its hints).
- Foundation's formatters for dates, lists, sizes, and language and voice names, given the interface locale.
- The debug log, which stays English.

## Overrides and export

**The file.**
- `interface_text.json` in the data folder, wherever Settings has put it: only the lines the person changed, in any of the 25 languages.
- The shape, which the Export shares, so a line copies from one to the other:

```json
{"version": 1, "languages": {"es": {"lines": {
  "common.sleepTimer": {"text": "Temporizador", "english": "Sleep Timer", "note": "The sleep timer's title."},
  "common.books": {"plural": {"one": "%lld libro", "many": "%lld de libros", "other": "%lld libros"}}
}}}}
```

- `english` and `note` are context only; when `english` differs from the line's English after an update, Settings says so and the line still applies.

**Validation.** A line is ignored and reported when:
- its ID or its language is unknown;
- it gives `text` for a plural line or `plural` for a plain one;
- its placeholders differ from the English's by slot and type (positions are allowed), it mixes numbered and unnumbered ones, or its count of `%%` differs;
- it uses a specifier other than the five, or holds a lone `%`;
- its plural categories are not exactly the language's, or a form is empty or holds a control character other than a line feed or tab.

The check is `apply`'s placeholder and plural rules, ported to Swift for the five specifiers, without its rules of style; the engine uses the same check on the pack's texts, so a bad line can never reach Foundation's formatter.
Lines not in the file come from the pack, so every update's better wording reaches them.

**Reading.**
- At launch, once the library is open, through `LibraryViewModel+LaunchFiles`'s path for a library in the cloud, so the first window never waits for it.
- On every change, through ConfigService's file watcher, which this work moves into one shared type (the duplication `docs/architecture/known-duplication.md` lists).
- Nothing writes the file except the person: TextMouth writes it only for Edit Interface Text… when it does not exist yet, so a cloud data folder sees no write at launch.

**Where problems show.**
- The Interface Language group says how many lines are in use and how many are ignored, and lists each ignored line as a sentence with its ID, language, and reason.
- The debug log writes `INTERFACE_TEXT_LOADED` and one `INTERFACE_TEXT_IGNORED` line for each, in English.

**Export.**
- Export Interface Text… writes every line of the interface language as it now reads, with its English and note and `"changed": true` on the person's own lines: a save panel on the Mac, the file exporter on the iPhone.
- Edit Interface Text… opens the file in the Mac's default editor; the iPhone reads the same file from its data folder.

## Tests

- **The equivalence harness** (`Scripts/l10n/verify_pack.py`, with `Scripts/l10n/engine-probe/` compiled with the engine's core):
  Apple's `String(localized:)` in a process of each language must equal the engine's text from the real pack, for every key and language (the catalog has no device variations).
  Each number runs through 0, 1, 2, 3, 5, 11, 21, 101, 1,000, 12,345, 1,000,000, 2,000,000, and 1,234,567, a key's second number starting three places on.
  `make l10n-check` runs it on the Mac in about 30 seconds, and a GitHub run repeats it; it is the gate before any call site changes.
- **The migration's check:** `pack.py compare` proves the pack from the re-keyed catalog equals the transition's pack, ID by ID, a split ID equalling its key.
- **Hosted, both apps** (`InterfaceTextTests`, succeeding `LanguagePackTests` and shared with the iPhone's unit bundle):
  - every pack entry equals the catalog's, in every language;
  - every lookup equals `String(format:locale:)` of the catalog's form at the counts above, with `Locale(identifier: "<code>_US")`;
  - Apple's plural rule equals `PluralRules` at the counts of Plural rules;
  - `Bundle.main.localizations` holds the 25, each `.lproj` holds its `InfoPlist.strings`, and no `Localizable` table ships;
  - a corrupt pack in the sandbox (bad magic, a cut blob, a wrong size, bad UTF-8) gives English and no crash.
  Until the switch, an equivalence test compares the engine with Apple's tables read through each language's own `Bundle(path:)`.
- **Unit:** the `Format` type's formats against today's keys; IDs, the specifier check with hostile texts (`%s`, `%n`, `%5$@`, `%@` for a number, a lone `%`) that never reach Foundation; the locale rule; the choice store; overrides' validation and loading; the reader's refusals.
- **SwiftUI:** a hosted view shows a line, the language switches, and the view's text is the new language's (hosted in a fixed frame, as AGENTS.md's lessons require).
- **The iPhone on GitHub:** the unit bundle runs `InterfaceTextTests`; an interface test switches to Spanish and back, and to Arabic, checking a label and the reading order.
- **VoiceOver's text unchanged:** the harness proves every string identical, the suite's 5,600 English assertions pass unchanged, and the user does a short VoiceOver check after the switch.

## The migration in phases

Each phase is a branch of its own, merged after a green full Mac suite; the estimates are an agent's working time, trains not counted.

1. **The engine** (Opus, 5 hours): `InterfaceText.line` and `InterfaceText.Format`, the pack reader, the lookup with its fallbacks and checks, `PluralRules` moved from the tests, and `InterfaceLanguage` with System only.
   Gate: unit tests on the Mac and the iPhone, `make typecheck-ios` at 0 errors, no call site changed.
2. **The pack builder** (Sonnet, 3 hours): `pack.py` with its tests; its first commit gives phase 1 its fixture packs and their catalogs.
   Gate: its tests, two builds byte-identical, the sizes reported.
3. **IDs** (Sonnet to generate, Opus to review the flagged ones, 4 hours): `ids.py` and `ids.json`, the splits.
   Gate: `ids.py check` clean; the orchestrator reads the flagged list.
4. **The harness** (Opus, 3 hours), after 1 to 3: the engine probe in `make l10n-check`, and the hosted equivalence test.
   Gate: no difference in 25 languages on the Mac, and the hosted test green on both apps.
5. **The sync tool and the lint, transition mode** (Opus, 4 hours): `sync` reads `InterfaceText.line` calls, the lint accepts them, and the pack's build phase ships the pack beside Apple's tables (each app 1.3 MB larger until phase 8).
   It also writes the codemod, `Scripts/l10n/convert_calls.py`, which rewrites a file's calls from `ids.json` and the keys' specifiers and refuses any call it cannot tie to one key.
   Gate: the l10n tests, the ratchet unchanged, a train with `reach`'s classes.
6. **The call sites** (six Sonnet agents in parallel, about 3 hours each), by the area of each file: the codemod, then the compile errors, the five ambiguous sites, `MenuVisibilityManager`, and the tests that read the converted sources.
   Gate for each area: the type-checks, `sync`'s check clean, the harness still exact, a train naming the area's classes and `phone`.
7. **The catalog's migration** (Opus, 4 hours): re-keying by ID, the `en` values, the splits, the review records' `id`, the tools reading English from `en`, and `sync` without the compiler.
   Gate: `pack.py compare`, the l10n tests, the harness.
8. **The switch** (Opus, 3 hours): the catalog out of both targets, `SWIFT_EMIT_LOC_STRINGS` off, the compact phase replaced, `InfoPlist.strings` and `CFBundleLocalizations` in, `InterfaceTextTests`, `SpanishLocalizationTests` on the engine, the lint's new rules.
   Gate: the full suite on both apps, `make check SIGN_APP=true` with the Mac at most 22.5 MB and the iPhone at most 17.5 MB, and the user's VoiceOver check.
9. **The picker** (Opus, 6 hours), after 6, beside 7 and 8: the group, the choice in `AppleLanguages`, the live switch, the formatters' locale, right to left, and the stored texts.
   Gate: its unit and hosted tests, the iPhone interface test on GitHub, a VoiceOver check of a switch.
10. **Overrides and export** (Opus, 5 hours), beside 9 in files of its own: the shared watcher first, then the file, its check, the problems list, Export, and the log tags.
    Gate: its tests, `LogContentPolicyTests`, and the hosted test of a watched change.
11. **Docs** (Sonnet, 3 hours): `localization.md` and `translation.md` rewritten for IDs, the user pages for the picker and the file, the architecture pages, and the code rules in `AGENTS.md` and the briefs.

About 58 agent hours; the longest chain, 1, 4, 5, 6, 7, 8, 11, is about 25 hours, with 2 and 3 beside 1, and 9 and 10 beside 7 and 8.
The catalog is re-keyed after the calls convert, not before as the brief listed: re-keyed first, every call not yet converted would find no table entry and show English, unless the build wrote Apple's tables back from the IDs, code that the switch would throw away.

## Risks

- A text differs from today's (a fallback, a plural form, the isolates): the harness, before any call site changes and at every phase after it, and the hosted test.
- The codemod changes an English text or misplaces `number:`: `sync`'s check of each call against its key and `ids.json`, the type-check, and the suite's English assertions.
- A view keeps the old language after a switch: the observation access in every lookup, the hosted view test, and the list of stored texts.
- A menu keeps its old title: the `Commands` observer and a hosted test of `NSApp.mainMenu`'s titles after a switch.
- A bad text crashes `String(format:)`: the specifier check before any text reaches Foundation, with hostile texts in the unit tests.
- A missing or corrupt pack: English and a log line, which the corrupt-pack test covers.
- The size goal: `make check` at phase 8 (expected Mac 22.2 MB, iPhone 17.1 MB) and the 1.5 MB budget.
- The system's language list loses TextMouth: `CFBundleLocalizations` and the `.lproj` folders, and the hosted test of `Bundle.main.localizations`.
- The translators' tools read keys as English: phase 7's list of those places, with a re-keyed fixture catalog in the l10n tests.
- A live switch formats numbers otherwise than the next launch (Persian in Saudi Arabia, Urdu in Iran): measured, and cleared by the relaunch.
- VoiceOver keeps reading in the old language's voice after a switch: the iPhone's `accessibilityLanguage`, and the user's VoiceOver check on both apps.
- A string added during the transition lacks an ID or a note: `sync`'s refusals and the lint, as now.
- A future macOS changes a plural rule: the hosted plural test fails and the table is changed on purpose.

## Questions for the user

1. Call sites read `InterfaceText.line("feed.folderMissing", "The folder of \(name) is no longer in the library.")`, numbers as `\(number: count)`: is that form right? Recommended: yes.
2. IDs from the code's own names, such as `endOfBook.starting` and `common.cancel`, frozen once given? Recommended: yes.
3. The picker at the top of the Mac's Miscellaneous tab and in a Language section of the iPhone's Settings? Recommended: yes.
4. A choice also sets the system's per-app language, so menus macOS supplies follow from the next launch? Recommended: yes.
5. Each language listed by its own name first, then by its name in your language ("Español, Spanish")? Recommended: yes.
6. Ship the translators' notes (83 KB) so the Export shows each line's note? Recommended: yes.
7. One `interface_text.json` in the data folder for every language, holding only your changes? Recommended: yes.
8. Convert the call sites before re-keying the catalog? Recommended: yes, for the reason in the phases.
9. Translate the microphone prompt and the other Info.plist strings through the same catalog? Recommended: yes, a small batch after the switch.
10. A short VoiceOver check after the switch, and after a switch to Spanish and back? Recommended: yes.
