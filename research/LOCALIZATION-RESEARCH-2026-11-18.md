# Localizing TextMouth: research (November 18, 2026)

Your request: "the big feature I want to start is localizing the app to different languages, which I think would also be a good idea to extract all the text into strings to measure the size of all of the text and to cut down fluff and excess text in like the VO hints or labels, I would like it if all the text could fit in a strings file < 150 kb (as in the interface text). Lets start with spanish as the first test language to test the system, build tools to make it faster, and generally hammer out the process but evenentually I would like 11 languages, eventually I would like to release this app... I think XCode string catalogs would be the obvius choice for the system, research the system first to learn how it works and if there is another one that should be used."

How this was researched:
- Everything marked "tested" or "measured" was run on this Mac today with Xcode 26.0.1 (`xcstringstool`, `swiftc`, `swift build`) and XcodeGen 2.45.3, against main at 87cf6f44b.
- Two research agents read Apple's documentation, WWDC sessions, Apple's developer forums, XcodeGen's source, and the tools' repositories; their claims carry the source they cite, and a claim that rests on a blog says so.
- TextMouth's own text was measured twice: by the compiler's extraction, and by a scanner of every string literal in `TextMouth/` (experiment files in `build/orchestrator/l10n/`, gitignored).
- Nothing in the app was changed.

## The answer in short

- **Use Apple's String Catalogs.** No alternative is better for a native Mac and iPhone app: the Swift compiler finds the strings, the catalog holds every language with plurals, Xcode's command-line tools sync and compile it, the main translation services read it, and Apple's own guide to translating with agents is built on it.
- **It works without Xcode's interface.** The compiler writes the strings it would localize (`-emit-localized-strings`), and `xcstringstool sync` merges them into the catalog; tested, both run from the command line, and the extraction rides on the type-check TextMouth already runs (1 minute 52 seconds for the Mac app).
- **TextMouth's interface text today is about 125 to 170 KB of English** in about 4,500 unique strings, before any cutting (measured, below). The certain part is 124 KB; 46 KB more probably reaches the user.
  The 150 KB target is reachable: the VoiceOver hints alone are 14.6 KB, at 63 characters on average.
- **Almost none of it is localizable yet.** The compiler finds only 429 strings (10.7 KB) today, the literals in SwiftUI calls; the rest is in the 108 `…Wording` enums and in error messages, which return plain `String`s.
- **What ships per language** is a file holding each English key and its translation: about 0.41 to 1.03 MB for one language at today's size, depending on the file format.
  Xcode's default format for the Mac (UTF-16) is the largest: for 11 languages it would add about 11 MB and pass the Mac app's 30 MB limit, so the format must be set (UTF-8 adds about 6 MB).
  Every byte of English text is paid once per language, which makes the cutting worth more.
- **Translation:** Claude agents translate batches with a glossary, the code context, and a comment per string, marked `machine_translated` as Apple's agent guide does; native speakers review before release, through a translation service that is free for open-source projects (Crowdin or Transifex) or volunteers.
- **Spanish first:** one neutral `es`, which every Spanish region falls back to.
- **The work is large:** about 4,500 strings in 890 files, 261 hand-built English plurals, and about 5,600 test assertions that compare English text.
  The plan below converts the code without changing a word of English first, so the tests stay green, then cuts the text area by area, then translates.

## How String Catalogs work

- **The file.** A catalog (`Localizable.xcstrings`) is one JSON file: `sourceLanguage`, `version` (1.0, or 1.1 once Xcode 26's comment or symbol generation is used), and `strings`, keyed by the string's key.
  Apple publishes no schema.
- **Each string** has a `comment` for translators, an optional `extractionState` (none for strings found in code, `manual` for strings added by hand, `stale` for strings no longer found), `shouldTranslate`, and `localizations`: per language, a `stringUnit` with a `state` and a `value`, or `variations` by plural category or device.
- **The states** in Xcode's editor are `new`, `needs_review`, `translated`, and `stale`; Apple's agent guide adds `machine_translated` (tested: `xcstringstool` 26.0.1 compiles and keeps all five).
- **Keys.** By default the key is the English text itself, and English ships no file of its own: the key is the fallback (tested).
  Interpolations become format specifiers in the key: `"\(n) books left"` is `%lld books left`, a `String` is `%@`, a `Double` `%lf` (tested).
- **Plurals** are variations of one key, with the categories each language uses: Spanish `one`, `many` (only for exact millions), and `other`; Russian and Polish add `few`; Arabic uses all six.
  A string with two counts uses `substitutions`.
- **Tables.** Each catalog is a table; `String(localized: "…", table: "Menus")` looks in `Menus.xcstrings` (tested).
- **What the build ships:** each language gets `<language>.lproj/Localizable.strings`, and `Localizable.stringsdict` when it has plurals (tested with `xcstringstool compile`).
  Every state is compiled, so an entry left `new` with an empty value ships as empty text (research agent, scratch build): the check must refuse empty values.

## What the compiler finds, and what it misses

Tested with `swiftc -emit-localized-strings` on sample files:
- **Found:** literals in `Text`, `Button`, `Label`, `Toggle`, `.accessibilityLabel`, `.accessibilityHint`, `.accessibilityValue`, `.help`, and `.navigationTitle`; `String(localized:)` with its `comment:` and `table:`; `LocalizedStringResource`; and a literal passed to any parameter typed `LocalizedStringResource`, such as an `announce(_:)` helper.
- **Missed:** a `String` variable passed to `Text(title)` or `.accessibilityLabel(title)` (shown as is, never translated), `Text(verbatim:)`, a `static let x = "…"` in a wording enum, and `NSLocalizedString`.
- **A helper loses comments.** A literal passed to a custom function's `String.LocalizationValue` parameter is found, but its `comment:` argument is not; only `LocalizedStringResource("…", comment: "…")` keeps it.
  So the code uses Apple's own `String(localized: "…", comment: "…")` everywhere, not a TextMouth helper.
- **Tests and the language.** A `LocalizedStringResource` whose `locale` is set to Spanish returns the Spanish text in-process; `String(localized:locale:)` does not (its locale only formats numbers), and overriding `Bundle.localizedString(forKey:value:table:)` does not intercept it (all tested).
  So a test reads Spanish by starting the app in Spanish (`-AppleLanguages (es)`), as the iPhone interface tests on GitHub can, or reads the catalog itself.

## Extraction without Xcode's interface

- **Xcode's own route** updates a catalog only in its interface, after a build: a command-line `xcodebuild build` writes the extracted `.stringsdata` files but leaves the catalog alone (research agent, tested in a scratch project).
- **`xcodebuild -exportLocalizations`** does sync the catalog and writes an `.xcloc` with XLIFF, but it builds every target of the project and every Swift package for each of their platforms, whatever scheme is named (Apple's developer forums).
- **TextMouth's route** (tested): `Scripts/ios/typecheck.py` already builds the app's sources as a Swift package; built again with `-Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc <folder>`, it wrote 908 `.stringsdata` files for the Mac app in 1 minute 52 seconds under the heavy-work lock.
  `xcstringstool sync Localizable.xcstrings --stringsdata <each file>` merged them in 0.3 seconds.
- **Two traps of `sync`** (tested): the catalog's file name must equal the table's name (a catalog called anything but `Localizable.xcstrings` received nothing), and a string absent from the files given is marked stale.
  So a sync must always be given both apps' files: the iPhone-only strings are not in the Mac's build, and the Mac-only ones not in the iPhone's.
- **What sync does to translations** (tested): new strings are added, existing translations and their states are kept, and a string that left the code becomes `stale` with its translations kept.

## TextMouth's interface text today

Measured on main at 87cf6f44b: 890 Swift files and 293,610 lines in `TextMouth/` hold 17,542 string literals.
The scanner sorted each by the call it is passed to, the declaration it sits in, and its shape:
- **Certain interface text: 3,147 unique strings, 124,311 bytes** (a string found in two places counts once in a total, so the parts below add up to a little more).
  - The `…Wording` and `…Vocabulary` types: 2,532 strings, 97,411 bytes.
  - Error messages (`errorDescription` and the like): 328 strings, 18,304 bytes.
  - Literals in SwiftUI and AppKit calls: 413 strings, 10,599 bytes; the compiler's own count of these is 429 strings and 10,665 bytes, which checks the scanner.
- **Probable interface text: 1,475 strings, 47,462 bytes,** sentences returned from other code (menu titles in `KeyboardShortcut.swift`, sentences built in services and views); about half of a sample was interface text.
- **Left out of the count:**
  - the debug log, 1,182 strings and 50,255 bytes, which stays English for bug reports;
  - the parsers' damage reasons, 449 strings and 13,949 bytes, technical detail that reaches you only inside an import failure (question 3);
  - keys, file names, tags, and code, about 4,460 strings.
- **The VoiceOver text:** 234 hints, 14,632 bytes, 63 characters on average; 260 labels, 4,949 bytes, 19 characters on average (those the scanner can identify by call or name).
- **The longest strings** run to 263 characters; 108 are over 100, and 15 over 145.
- **Where it is:** `Models/` 69 KB, `Views/` 51 KB, `Services/` 37 KB, `ViewModels/` 9 KB, `Parsers/` 8 KB, `Phone/` 5 KB; the largest single file is `AudioEditorWording.swift`, 9.4 KB.

The count is an estimate until the code is converted: then the catalog itself is the exact measure, and `l10n size` reports it.

## What ships, and the app's size

Measured with `xcstringstool compile` on a catalog of today's 4,519 strings with a stand-in Spanish value 20% longer than each English one:
- **UTF-8 XML** (`xcstringstool`'s default): 550,866 bytes per language.
- **Binary property list:** 662,463 bytes; it stores any string with an accented letter as UTF-16, so for real Spanish it lands between this and the UTF-8 figure.
- **UTF-16 XML,** Xcode's default for the Mac's build (research agent, scratch build; `STRINGS_FILE_OUTPUT_ENCODING`): 1,033,660 bytes.
- **The old plain-text `.strings` format** in UTF-8 would be about 410 KB (an estimate: the same text with less markup); Xcode does not write it, so it would take a build step of ours.
- **Compressed** (the App Store's download, a zipped Mac app): about 200 KB per language.
- **The catalog itself,** with one language and comments, is 1.5 MB; it is not shipped.

For 11 languages at today's text, the Mac app (21.0 MB) and the iPhone app (16.1 MB) each grow by about 4.5 to 6 MB in UTF-8 and 11.4 MB in UTF-16; `make check` warns above 30 MB and fails above 40 MB.
Each language file holds the English keys too, so every byte cut from the English text is saved once in the app's code and once more in every language's file.
Short keys in place of the English text would save about 150 KB per language, but English would then ship a file of its own, and the code would lose its readable text and Apple's default workflow; not recommended.
The iPhone app also carries the Mac-only strings, since both apps compile the same wording enums; trimming them per app is a later size item.

## The alternatives

- **Legacy `.strings` and `.stringsdict` files:** still supported, but Apple has recommended catalogs since Xcode 15, and both compile to the same runtime lookup ([Apple](https://developer.apple.com/documentation/xcode/localizing-strings-that-contain-plurals)). No reason to start there.
- **SwiftGen and R.swift** (generated, type-safe accessors): both nearly idle since 2024, and neither has merged catalog support (SwiftGen [#1065](https://github.com/SwiftGen/SwiftGen/issues/1065), R.swift [#886](https://github.com/mac-cain13/R.swift/pull/886)); Xcode 26 generates symbols for hand-added catalog strings itself (`xcstringstool generate-symbols`, tested present).
- **Fluent and ICU MessageFormat** give grammatical gender and case selectors, which catalogs lack, but there is no maintained Swift Fluent, and the one Swift MessageFormat 2 library is a few days old with one star ([repository](https://github.com/swift-standards/swift-unicode-messageformat)).
  Apple's automatic grammar agreement (`^[…](inflect: true)`) covers some agreement in Spanish, English, French, Italian, Portuguese, and German ([WWDC23 10153](https://developer.apple.com/videos/play/wwdc2023/10153)).
- **Command-line tools around catalogs** exist: validators (Asana's [locheck](https://github.com/Asana/locheck), MIT), converters ([langcodec](https://github.com/oops-rs/langcodec), MIT, catalog to and from XLIFF, CSV, and Android), and translators that call an API ([swift-translate](https://github.com/hidden-spectrum/swift-translate), MIT).
  None does what TextMouth needs as a whole (both apps' extraction without Xcode, a ratchet on size, agent batches with code context), and each would be a dependency of the toolchain; TextMouth's own Python tools, like its issue and doc libraries, fit better, and these are worth reading for their rules.
- **Reasons not to use catalogs:** none found that apply. The risks are merge conflicts in one large JSON file, which a merge driver answers, and Weblate's missing support (below).

## Translating: agents, services, and review

- **Apple's guide to translating with agents** ([Localizing your app using agents](https://developer.apple.com/documentation/xcode/localizing-your-app-using-agents)) describes Xcode's own agent translation: it marks each result `machine_translated` (in XLIFF, `state-qualifier="leveraged-mt"`), and reads translation guidance from a `TRANSLATION.md` that `AGENTS.md` or `CLAUDE.md` points to, with a glossary and a list of strings not to translate.
  It says to have people who speak each language and live in its regions give feedback.
  Xcode's version of this is in its interface (a summary of WWDC26 session 213 puts it in Xcode 27); TextMouth's tools follow the same conventions from the command line.
- **Quality:** no rigorous public comparison of language models with professional translators for interface text was found.
  Published practice agrees on a glossary, a comment per string, placeholders locked, length checked, and review by a native speaker; one 2026 study of LLM pipelines found most defects were faults of the code (hand-built plurals, sentences glued together), not of the translation ([MDPI](https://doi.org/10.3390/info17101026), abstract only).
- **Translation services that read catalogs natively** (plurals, devices, comments): Crowdin, Lokalise, Phrase, POEditor, Transifex, Localazy.
  Crowdin ([open-source plan](https://crowdin.com/page/open-source-project-setup-request)) and Transifex ([open source](https://www.transifex.com/open-source/)) are free for open-source projects like TextMouth (MIT); Crowdin asks for an active community and three months of development.
  Weblate, the open-source one, does not read catalogs ([issue #10848](https://github.com/WeblateOrg/weblate/issues/10848), open since January 2024), only XLIFF.
- **Apple's glossaries** of its own interface terms in each language are offered to developers as a download (Apple ID needed; not checked today); they would make TextMouth use the words macOS uses.

## VoiceOver, braille, and a translated interface

- **Apple's rules for labels** (Accessibility Programming Guide, archived; read through a summary, so paraphrased): a word or a very short phrase, capitalized, no period, never the control's type, and localized.
- **For hints:** a brief description of the result, beginning with a verb in the third person ("Plays the book."), no subject, ending with a period, never naming the gesture, the control, or its type.
  So "Activate to navigate to this result", a hint in `BookSearchView.swift` today, names the gesture.
- **Which voice speaks it:** VoiceOver speaks in the language set in the system's settings (Apple's archived guide), not by the app's language; its "Detect languages" option switches voices for text in another language, less reliably on the Mac than on the iPhone (Apple support pages; forum reports for the reliability).
  A Spanish TextMouth under an English VoiceOver voice may be read with English rules, so announcements could carry their language as an attribute (`NSAccessibilityLanguageTextAttribute` on the Mac); a later item.
- **Braille:** the table is VoiceOver's own setting (VoiceOver Utility, Braille, Layout), not the app's.
- **The app's language** follows the system's list, or a per-app choice in System Settings, General, Language & Region, Applications (and the iPhone's Settings); the app restarts when it changes.

## Spanish

- **Which Spanish:** Xcode offers `es` and `es-419` (Latin America); App Store Connect lists Spain and Mexico.
  One neutral `es` serves every region, since `es-MX`, `es-US`, and `es-AR` fall back to it ([Apple](https://developer.apple.com/documentation/xcode/choosing-localization-regions-and-scripts)); regional files can come later.
- **Plurals:** `one` (exactly 1), `many` (exact millions), `other` (CLDR 49).
- **Length:** Spanish runs 15 to 30% longer than English in characters (vendor figures); short labels grow most.
- **Tone:** formal "usted" or familiar "tú" is a choice for the whole app (question 5); Apple's own Spanish interface appears to use "tú", not checked today.

## Eleven languages

No authoritative ranking of App Store languages exists; one vendor's 2025 request shares put French, German, Japanese, Simplified Chinese, Spanish, Italian, Brazilian Portuguese, Korean, Dutch, and Turkish first ([Alconost](https://alconost.com/en/blog/how-to-reach-global-users), vendor).
No data on screen-reader users by language was found.
A suggestion (judgment, question 6):
1. Spanish (`es`): your first, and among the most spoken.
2. French (`fr`).
3. German (`de`).
4. Portuguese, Brazil (`pt-BR`).
5. Italian (`it`).
6. Japanese (`ja`): no plurals; about twice the bytes of English in UTF-8.
7. Chinese, Simplified (`zh-Hans`): no plurals.
8. Korean (`ko`).
9. Dutch (`nl`).
10. Russian (`ru`): four plural categories; Cyrillic takes two bytes a letter.
11. Arabic (`ar`): a large blind population, but right-to-left layout and six plural categories make it the costliest; Polish or Turkish instead if not.

## What the code has to change

- **Wording enums:** each `"…"` becomes `String(localized: "…", comment: "…")`; a `static let` becomes a computed `static var`, so a value is never cached in the wrong language.
- **Plurals:** the 261 uses of `CountWording` build English plurals from a singular and a plural word ("1 book", "2 books"); each becomes one localized string with plural forms in the catalog (`"\(count) books"`, English `one` "%lld book").
- **Sentences glued together:** a sentence built from pieces (`"…words per minute" + (local ? ", book-specific speed" : "")` in `ReaderView.swift`) becomes whole sentences with placeholders, since other languages order the pieces differently.
- **Numbers, times, and lists** go through Foundation's formatters (`formatted()`, `Duration.formatted`, `ListFormatStyle`), which speak each language's own forms.
- **Language and key names:** language names come from `Locale` (`TextPlausibility.swift` spells out "Finnish"), and the spoken key names ("Command", "Control" in `KeyboardShortcut.swift`) take macOS's own words for each language.
- **Text stored as data stays as stored:** "Untitled" is saved as a book's title by four parsers and `BookInfo`'s default; a stored title, an author placeholder, a setting's raw value, or a shortcut in `config.json` must not change with the interface language (question 8).
- **Not translated:** the debug log, the system's sound names ("Pop", "Tink"), braille tables' names from liblouis, and accessibility identifiers.
- **Info.plist:** the permission prompts and the file-type names (47 on the Mac, 44 on the iPhone, such as "Markdown Document", shown in the Finder) need a second catalog, `InfoPlist.xcstrings`, for each app.

## Testing

- **The suite stays English.** About 5,600 assertions in 925 test files compare English text; the conversion changes no English, so they keep passing, and each cut updates its own tests.
- **The catalog check** (`l10n check`, in `make check`): every string translated in each shipped language, placeholders equal in number, order, and type, every plural category of the language present, no empty value, a comment on every string, and the English under its budget.
- **The unlocalized-text lint** (`make lint-l10n`): the scanner as a ratchet, failing when a file gains interface text that is not localized, so the converted areas stay converted.
- **Spanish at run time:** the iPhone interface tests on GitHub can start the app with `-AppleLanguages (es)` and read the labels and values VoiceOver speaks; for the Mac, a train request in Spanish is a tool to add.
  Apple's pseudolanguages (double length, accented, right to left) are launch arguments too (`-NSDoubleLocalizedStrings YES`), mostly for sighted checks of truncation.
- **By ear:** you can run TextMouth in Spanish from System Settings with VoiceOver; the `vo-control` skill could also record what VoiceOver says in Spanish and flag English words left.

## The tools to build

One command, `Scripts/l10n/l10n.py`, in the style of the issue and doc libraries, with tests in `Scripts/l10n/tests/`:
- `sync`: extracts both apps' strings through the type-check and merges them into the catalog, keeping a map from each string to the lines that use it.
- `status`: per language, how many strings are translated, machine-translated, new, or stale.
- `size`: the English bytes against the budget, and each language's shipped size in each format.
- `check`: the catalog check above.
- `todo` and `apply`: a batch of untranslated strings for one agent, with each string's comment, placeholders, plural categories, the code around it, and the glossary's terms; then the translated batch merged back, checked, and marked `machine_translated`.
- A git merge driver for `.xcstrings`, so two branches that add strings merge by key, as `Issues/` files already merge by field.
- `make lint-l10n`, the scanner as a ratchet.

## The plan

1. **Tools (today):** `l10ncore` (the catalog, its sync, status, size, and check, the build settings, `make` targets) and `l10nscan` (the scanner and its lint), in parallel.
2. **Translation tools and a pilot (next):** `l10nxlate` (todo, apply, the glossary, the merge driver, the translation guide), and `l10npilot`, which takes the sleep timer, bookmarks, and the Reading List on both apps (about 135 strings) through every step: converted, cut to the rules, translated into Spanish, checked, and tested in Spanish on GitHub, so you can hear it.
3. **Conversion waves:** the rest of the app, by area, three to five agents at a time, with no English changed; the lint's baseline falls with each.
4. **Cutting:** area by area to the agreed rules, toward 150 KB, with the tests updated.
5. **Spanish:** the whole catalog translated and checked; you listen, and native speakers review.
6. **The other ten languages,** then `InfoPlist.xcstrings`, the per-app size trim, and the release work.

## Questions for you

In `humanQuestions/2026-11-18.md`, each with a recommended answer, which the agents build until you answer.

## Not verified

- That Xcode's own Mac build writes UTF-16 by default, and which setting gives the smallest real Spanish file: `l10ncore` measures the real build.
- That the iPhone interface tests read Spanish labels under `-AppleLanguages (es)`; the pilot does it on GitHub.
- Whether Xcode's catalog editor shows Spanish's `many` category, and Apple's full list of languages for grammar agreement.
- The exact wording of Apple's label and hint rules, read through a summary of the archived guide.
- Any count of screen-reader users by language, and any rigorous comparison of machine and human translation of interface text.
- Whether Apple's Spanish interface uses "tú" throughout, and the terms of Apple's localization glossaries.

## Sources and files

- Apple: [String catalogs](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog), [preparing text for translation](https://developer.apple.com/documentation/xcode/preparing-your-apps-text-for-translation), [exporting localizations](https://developer.apple.com/documentation/xcode/exporting-localizations), [WWDC23 10155, Discover String Catalogs](https://developer.apple.com/videos/play/wwdc2023/10155/), [WWDC25 225, Explore localization with Xcode](https://developer.apple.com/videos/play/wwdc2025/225/), [Xcode 26 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes), [Accessibility Programming Guide](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/iPhoneAccessibility/Making_Application_Accessible/Making_Application_Accessible.html).
- XcodeGen: catalogs since 2.39.0, and `knownRegions` taken from the languages a catalog holds ([changelog](https://github.com/yonaskolb/XcodeGen/blob/master/CHANGELOG.md)).
- CLDR plural rules: [chart](https://www.unicode.org/cldr/charts/47/supplemental/language_plural_rules.html).
- Text expansion: [W3C](https://www.w3.org/International/articles/article-text-size/index.en).
- This Mac's experiments, gitignored: `build/orchestrator/l10n/` (the scanner `scan_strings.py`, its output `scan.json`, the extraction script, and the catalogs tested).
