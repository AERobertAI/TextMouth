# Translating TextMouth
<!-- id: translating-textmouth; keys: localization, translator, xcstrings, String Catalog, ID, en value, l10n.py; src: Scripts/l10n/l10n.py, Scripts/l10n/translate.py, TextMouth/Localization/Localizable.xcstrings -->

Part of [TextMouth's documentation](../../README.md).

This is what a translator, human or agent, reads before translating the app's interface text.
The text lives in one String Catalog, `TextMouth/Localization/Localizable.xcstrings`, which both apps share.
It is keyed by ID, the permanent name of each line (`endOfBook.starting`; see [Localizing TextMouth's code](localization.md#ids)).
Each entry holds the English as its `en` value, the note for the translators as its comment, and one value for each language that has a translation.
A line whose language has no value yet shows English.
Neither app compiles the catalog: the build turns it into the pack the engine reads (see [What the apps ship](localization.md#what-the-apps-ship)).
Never edit the catalog by hand: `Scripts/l10n/l10n.py` writes it in the layout Xcode expects, and checks what it writes.
The catalog holds 25 languages.
The first eleven are English, Spanish (`es`), Italian (`it`), French (`fr`), Brazilian Portuguese (`pt-BR`), German (`de`), Russian (`ru`), Ukrainian (`uk`), Simplified Chinese (`zh-Hans`), Japanese (`ja`), and Korean (`ko`).
The second wave of twelve is Hindi (`hi`), Arabic (`ar`), Bengali (`bn`), Indonesian (`id`), Vietnamese (`vi`), Turkish (`tr`), Thai (`th`), Polish (`pl`), Traditional Chinese (`zh-Hant`), Dutch (`nl`), Swedish (`sv`), and Hebrew (`he`).
The third wave of two is Urdu (`ur`) and Persian (`fa`).
All but English are machine translations, and a native speaker has reviewed none; a heavier model has reviewed every one's wording (see Reviewing a language).
`Scripts/l10n/config.json`'s `languages` list is still empty, so `check` does not yet fail for a string missing in a language; it fails only for a string that is wrong.

## The steps
<!-- id: translation-steps; keys: sync, todo, apply, check, status, rejected, plural, ID; src: Scripts/l10n/l10n.py, Scripts/l10n/translate.py, Scripts/l10n/sync.py -->

Run every command as `python3 -I -B Scripts/l10n/l10n.py COMMAND`; `--help` after a command lists its options.

1. `sync` reads the code's `InterfaceText.line` calls and merges them into the catalog, in about two seconds, with no build and no lock (see [How the sync reads the code](localization.md#how-the-sync-reads-the-code)).
   The agent that changed the code runs it, so a translator does not.
   That agent also translates each line it added or changed, in all 24 languages, with steps 2 to 4 below, before its branch merges, and `status` must show 0 missing in every language.
   It also writes `build/l10n/locations.json`, the file and line of each ID and the commit it read them from, which `todo` reads for the code around a string.
   It copies each ID's note, the `// Translators:` line above its call, into the catalog as the ID's comment.
2. `todo --lang es --out batch.json` writes a batch of up to 300 strings that still need Spanish.
   `--keys-from FILE`, `--file PATH...`, and `--area NAME` pick the strings (a list of IDs, the strings some files use, or one of the scanner's areas, which `scan.py report` names); `--limit N` sets the batch size, and 0 means all (a negative number is refused).
   `todo` warns when `locations.json` was made from other code than this checkout's, and then leaves out the code of any use where the string's text is not within the five lines shown.
   An item's `key` holds the string's ID, and its `english` the `en` value.
   An item's `previous` is an earlier translation of a nearly identical stale string, with its placeholders; it is offered only when the placeholders are the item's.
3. Fill in `translation` in each item of the batch: a text, or for a string with plural forms an object with one text for each plural category the language uses.
   Nothing else in an item is changed, except `"keepEnglish": true` where the English is right in the language too (a word both share).
4. `apply batch.json` checks each translation and writes the good ones as `machine_translated`; it is safe to run twice.
   It prints each refusal with its reason, writes the refused items to `batch.json.rejected.json`, and exits 1.
   Fix those items in that file and run `apply batch.json.rejected.json`: that run writes the good ones and rewrites the same file with what is still refused, so repeat until it exits 0 and the file has no items.
   Never apply the original `batch.json` again once its rejected file holds fixes: a rejected file newer than the batch is left alone, and the run says so.
   `apply --lang es` stops a batch made for another language.
5. `check` lists what is wrong in the catalog and warns where a translation does not use a glossary term (a warning, not a failure); `status --lang es` counts the strings by state.
6. The plural forms of an English string go in with `plural ID --lang en --one "%lld book" --other "%lld books"`.
   `plural` takes the other languages' forms too, and checks their categories and placeholders as `apply` does.

`apply` refuses:
- placeholders that differ from the English's, plural form by plural form;
- a plural category the language does not use, or one it uses that is missing;
- plural forms for an English string that has none, or for an ID whose English has no number placeholder (`%lld`);
- a `one` form that leaves out the number, except in a language whose `one` means exactly 1 (Spanish, English, German, Italian, Dutch, Portuguese of Portugal): in French `one` also covers 0 and in Russian 21, so there the number stays;
- empty text, and control characters other than a line break and a tab;
- leading or trailing whitespace that differs from the English's, form by form;
- a different number of `%%` (a literal percent sign), and a lone `%` in a text that has placeholders;
- the English left as it was, unless the item has `keepEnglish` or the text is only names, numbers, and placeholders;
- a name from the glossary's `doNotTranslate` list that the English has and the translation lacks;
- a batch whose language is the source language or one the tools do not know, or differs from `--lang`;
- an ID the catalog does not have, a string whose English changed after the batch was made, a stale string, and a machine translation over a person's: a form a person marked `translated` is kept as it is (a warning), and the other forms are written.

A translation more than three times as long as an English of at least 12 characters is only a warning, and so is a different number of line breaks inside the text.

## Syncing, pruning, and the test classes
<!-- id: translation-around-the-steps; keys: sync, prune, reach, stale, test classes, scan.py show; src: Scripts/l10n/l10n.py, Scripts/l10n/sync.py, Scripts/l10n/reach.py, Scripts/l10n/scan.py -->

`sync` reads every Swift file of `TextMouth/`, so a new file needs no list (see [Localizing TextMouth's code](localization.md#how-the-sync-reads-the-code)).

- After a cut, `check` fails until the strings the code no longer has are gone.
  `prune` deletes the stale strings that hold no translation in any language and prints each ID; `prune --all` deletes every stale string, and `prune --dry-run` lists them and writes nothing.
  Each ID it deletes goes to `Scripts/l10n/retired-ids.txt`, so no later line is given it again.
- `reach [--base REF] [--explain]` prints the hosted test classes that the branch's localization could break, for `build-train.py request --classes`.
  The first line holds the Mac classes, comma-separated; the iPhone unit test classes follow on a line of their own, since a train names them by the area `phone`.
  It finds the classes whose files hold an English text the branch localized (cut at its first interpolation, 12 characters or more), name a converted file (they read its source), or are what `run-area.py --changed` finds; `--explain` gives each reason.
- `scan.py show FILE` lists, apart from the interface literals that are no call, each call whose note is missing or misplaced: a `comment:` argument, a call with no `// Translators:` line directly above it, and a line that holds two calls; `lint` refuses each.

## The catalog's merge driver
<!-- id: translation-merge-driver; keys: merge driver, .gitattributes, xcstrings, merge conflict, make l10n-merge-driver, comment; src: Scripts/l10n/merge.py, Scripts/l10n/l10n.py, Makefile -->

Two branches that each add or translate strings merge without a conflict, because `.gitattributes` gives `*.xcstrings` the driver `merge=xcstrings`, which merges by ID, language, and plural form.
Git reads the driver's definition from the repository's configuration, so define it once for each clone with `make l10n-merge-driver`.
The merge worktrees share that configuration, so one definition serves them all.
Without it git merges the catalog as text, and neighbouring IDs conflict.

An ID that main already has can gain a comment line on both branches.
The driver merges the two sides' comment lines into one sorted union, less any line a side cut, with no conflict.
Where a side's lines are not in sorted order (a comment that itself holds a line break), the driver keeps ours' lines and then theirs' new ones, and the next `sync` rewrites the comment.

The driver refuses (exit 2, your file untouched) a file that is not a catalog: not JSON, not an object, or with `strings` that is not an object of objects.
It writes the result through a temporary file and a rename, so an interrupted merge never leaves half a catalog.
When both sides changed one piece differently it keeps ours, prints the ID and the three values on standard error, and exits 1, so git reports the file conflicted.

## States
<!-- id: translation-states; keys: machine_translated, translated, needs_review, stale, new, missing, en; src: Scripts/l10n/catalog.py, Scripts/l10n/translate.py, Scripts/l10n/pack.py -->

- `missing`: the ID has no value in the language yet, which is what `sync` leaves for a new ID, and the line shows English.
- `new`: a value held in the state `new`, which the pack leaves out.
- `machine_translated`: made by a model and checked by the tools; it ships.
- `translated`: a native speaker has reviewed it.
  `apply --state translated` is for that review only.
- `needs_review`: the English changed since the translation was written; `sync` sets it, the translation keeps shipping, and `todo` offers the string again with the translation as `current`.
- `stale`: the code no longer has the ID; `sync` marks it, and `check` reports it until someone deletes it.

The English `en` value is `translated`, since it is the text itself, and a batch never writes it: `sync` does, from the code, and `plural` writes its plural forms.
A string is done in a language when every form of it is `machine_translated` or `translated` and none is empty.
The pack holds every state except `new`, so an empty value would ship as empty text, and `check` refuses it.

## The rules for every language
<!-- id: translation-rules; keys: placeholders, plural categories, positions, length, glossary, comments, never translated; src: Scripts/l10n/catalog.py, Scripts/l10n/glossary.json, Scripts/l10n/glossary.py -->

- Read the `comment` and the `context` of an item: the comment is the note from the code's `// Translators:` line, which says where the text appears and what it is, and the context shows the use.
- Keep every placeholder (`%@`, `%lld`, `%1$@`, `%.1f`) with its type; a text may reorder them only with positions (`%2$@ ... %1$@`), since unnumbered ones are taken in order.
  `%%` is a literal percent sign.
  Never type a number the app counts; the placeholder carries it.
- Give a plural string every category the language uses, as the item's `pluralCategories` lists them.
  The English has `one` and `other`; Spanish also has `many`, used for exact millions ("1 000 000 de libros"), so it needs a form of its own.
- Use the glossary's translation of each term in the item's `glossary`, and mark a doubt in your report rather than invent a second word.
  A glossary entry with `"check": true` is a word a native speaker has not yet confirmed.
  A term is never found inside a name (Windows-1252 is the name Windows), and a command word that is also an everyday word (Close, Open, Done, Play) is found only as a whole label or in a title-case phrase, so a sentence such as "close to the end" has no hit.
- Never change a name in `doNotTranslate`: TextMouth, VoiceOver, EPUB, DAISY, and the other product and format names.
- A name beside Japanese, Chinese, or Korean text is not hidden by it: "TextMouthは" and "TextMouth가" keep the name, since those scripts have no spaces (`_SPACELESS` in `Scripts/l10n/glossary.py`).
  A Latin or Cyrillic letter beside a name still joins it into another word.
- Never translate what a person does not read: the debug log's lines, a stored key or identifier, a file extension, a URL, a format's element names, or code.
  Such a string should not be in a batch; set `keepEnglish` on it, and name it in your report so it can be marked `shouldTranslate: false`.
- Translate meaning, not words: a text that reads as the English reads in the language is a good one, and a label that is a literal copy of the English word order is not.
- Keep the length near the English where you can: short labels grow most (Spanish runs 15 to 30 percent longer), and a button label must still fit.
- Keep the same punctuation habits as the language's own interface, but never add or drop a sentence.
- Write a settings or menu path with the language's own separator between its steps (a comma, the Arabic comma, の in Japanese, 的 in Chinese, a space in Thai), never ">", which VoiceOver reads aloud.

## What VoiceOver and braille read
<!-- id: translation-voiceover-text; keys: accessibility label, hint, VoiceOver, braille, accessibility, gesture; src: Scripts/l10n/l10n.py -->

The user reads with VoiceOver and a braille display, so text meant for them is the most careful work in the catalog.
The rules are the English's, in the language:
- A label is a word or a short phrase, capitalized the way the language capitalizes, with no final period and no control type (not "button" or "botón").
- A hint is a short sentence that starts with a verb in the third person and ends with a period: "Plays the book." becomes "Reproduce el libro."
- A hint never names the gesture, the key, or the control: no "tap", "double-click", "toca", or "haz clic".
- An announcement says what happened, in the order a listener needs it, with the most important word first.
- A text that a translation makes much longer is also longer in braille, so keep the word choice short.

## The language sections
<!-- id: translation-language-sections; keys: Spanish, Urdu, Persian, per-language notes, right-to-left, plural categories; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

Each language's letters, forms of address, punctuation, plural categories, and glossary doubts are in [The interface languages](translation-languages.md).

## Translating at scale
<!-- id: translation-at-scale; keys: partition, ID file, disjoint IDs, batches, consistency pass, glossary first, 20 agents, extract-report; src: Scripts/l10n/l10n.py, Scripts/l10n/glossary.json, Scripts/agents/extract-report.py -->

The languages added after Spanish were made this way, about 4,200 strings each.
Developers who convert code read [Localizing TextMouth's code](localization.md) instead.

1. Glossary first.
   One agent (`l10nglossary`) chooses each glossary term in every new language, marked `"check": true`, before any translator starts.
   Translators use those words even where they would choose another, and propose better ones in their reports.
2. Partition the IDs.
   List the IDs that still lack the language, and split them by area of the app into six disjoint ID files of 650 to 750 IDs (library; storage and settings; feeds and import; audio and transcripts; reader, formats, and menus; export, speech, and iPhone).
   Two translators never hold the same ID, so their branches merge without a conflict.
3. Give each translator one file, and its own scratch folder, since two translators that wrote `batch-1.json` in one folder overwrote each other's batch.
   It runs `todo --keys-from FILE --out DIR/batch.json`, 250 strings at a time, and `apply`.
   Its branch holds only the catalog.
4. Run at most 20 agents at once, and launch the next as a slot frees.
   Past 20, a launch is refused; a finished agent keeps its slot until it is stopped, and stopping it also ends its leftover background checks.
5. A translator never runs `check`: `apply` already checks every string it writes, and the orchestrator runs `check` on the merged catalog.
6. A translator's report is its final message.
   An agent in an isolated worktree cannot write the main checkout, so `Scripts/agents/extract-report.py` prints the report from the agent's transcript.
7. Check each branch before merging: it changed only its own IDs, in its own language, and none of them is left without the language.
8. After a language's branches merge, one agent makes a consistency pass over the whole language:
   - a control's name inside a sentence matches that control's own label;
   - each term has one translation, and the pass's glossary changes go to a file, which the orchestrator applies to `glossary.json` at once, so later passes see them;
   - names that must not be translated stay as they are.
   The pass changes the catalog only, and is a branch of its own.
9. A consistency pass or a review writes its own batch, `{"language": ..., "items": [{"key": <an ID>, "english": ..., "translation": ...}]}`, and runs `apply` on it.
   `todo` offers only the strings a language still lacks, so it never lists one to rework.
10. The orchestrator fits a pass's glossary changes to the glossary's tests and drops an entry they refuse: a new term may not share another term's text, and a term's own text must hold each term its English contains.

## Adding a language
<!-- id: translation-adding-language; keys: new language, checklist, plural categories, CFBundleLocalizations, verify_packs, language code, picker; src: Scripts/l10n/l10n.py, Scripts/l10n/catalog.py, Scripts/l10n/glossary.json, Scripts/l10n/verify_packs.py, Scripts/ios/sync-info-plist.py, TextMouth/Resources/Info.plist, TextMouth/Localization/InterfaceText/PluralRules.swift, Scripts/l10n/tests/test_plural_rules_swift.py, Makefile -->

A person or an agent follows these steps from the start.

1. Choose the code Xcode uses for the language: `zh-Hant` and `pt-BR` carry a script or region, `hi` does not.
2. Add its plural categories to `PLURAL_CATEGORIES` in `Scripts/l10n/catalog.py`, and its rule to `PluralRules` (`TextMouth/Localization/InterfaceText/PluralRules.swift`).
   The Interface Language picker lists the languages of `PluralRules.categories`, so this step also adds the language to the picker.
   Check the rule Foundation on this macOS applies, not only CLDR's: Vietnamese has `other` alone in Foundation, though CLDR 49 gives it `one`.
   `InterfaceTextTests` checks the table against Apple's rule at run time; `test_plural_rules_swift.py` fails when the two tables differ, and `Scripts/l10n/tests/test_catalog.py` keeps the catalog's.
3. Add the language's text to every glossary term in `Scripts/l10n/glossary.json`, each marked `"check": true`, with the glossary's tests green (`Scripts/l10n/tests/test_glossary_file.py`).
   One agent for each language does this, so every translator of the language later uses the same words.
4. Write the language's rules for translators, as the sections of [The interface languages](translation-languages.md) do: the address (register), the command form of menu items and buttons, the hints, the quotation marks, and how a sentence ends.
   Follow Apple's own interface in the language.
5. Split the IDs the language lacks into the six area files (see Translating at scale), and give each file to one translator.
6. Check each translator's branch before merging it: it changed only its own IDs, in its own language, and none of them is left without the language.
   Merge the branches; the catalog's merge driver merges them by ID.
7. Run one consistency pass over the language, then apply its glossary changes to `glossary.json`.
8. Where usage allows, have a heavier model review the wording (see Reviewing a language).
9. Add the language to `CFBundleLocalizations` in the Mac's `TextMouth/Resources/Info.plist`, English first and the rest in code-point order, then run `python3 -I -B Scripts/ios/sync-info-plist.py` for the iPhone's.
   `check` fails until the list equals the catalog's languages, since with no table of Apple's that list is what offers the language to the system.
10. Check the whole:
    - `python3 -I -B Scripts/l10n/verify_packs.py`: the engine's lookup equals Apple's for every ID in the new language;
    - `python3 -I -B Scripts/l10n/l10n.py check` and the l10n tests (`make l10n-check` runs the first and `verify_packs.py`);
    - an iPhone train that names `InterfaceTextShippedPackTests`;
    - the full Mac suite;
    - `make check`, for the app's size against the limit (see [Building](building.md), the make check gate).
11. Name the language in the opening of this page, in the list in [Settings](../user/settings.md) (the interface language), and in the changelog.

## What adding a language still does by hand
<!-- id: translation-adding-by-hand; keys: orchestrator scripts, area split, branch check, fit glossary changes, review dump, not in the repository, limitation; src: Scripts/l10n/l10n.py, Scripts/l10n/glossary.json; status: incomplete; issues: TL20, Q18 -->

These steps of Adding a language are done with the orchestrator's own scripts, which are not in the repository yet:
- the area split of step 5 (the six ID files);
- the branch check of step 6;
- fitting the glossary changes of step 7 to the glossary's tests, which drops each entry the tests refuse;
- the review's dump and its batch writer, which step 8 uses.

A person who adds a language writes them again from the steps above.
No test yet looks at a window mirrored for a right-to-left language (Arabic and Hebrew).

## Reviewing a language
<!-- id: translation-reviewing-language; keys: review, reviewer, Opus, fix categories, reviews folder, native speaker, record; src: Scripts/l10n/l10n.py, Scripts/l10n/glossary.json -->

A heavier model (Opus) reads each language's wording after its consistency pass, and a native speaker reviews it after that.
Nobody has read the machine translation for bad wording until then, and the user hears every string through VoiceOver and braille.

1. One reviewer reads one third of one language: two of the six areas, in numbered chunks of 150 strings.
   A plural string shows its forms on one line, and a short string carries the start of its note.
2. Fix a string when it is wrong or plainly unnatural, not when it merely differs from what the reviewer would write.
   Each fix has one category:
   - `meaning`: another sense of the word (Play, Sheet, Index, Track, Book, Return), swapped subject and object, a lost negation;
   - `grammar`: agreement, case, a wrong particle or verb form, a sentence built around a placeholder that cannot read right for every value;
   - `natural`: a copy of the English word order or idiom, or a label far longer than it needs to be;
   - `term`: a word other than Apple's for the same thing, where the glossary does not decide it;
   - `register`: a form of address or command form unlike the rest of the language;
   - `punctuation`: the language's own quotation marks, spacing, and sentence ends;
   - `voiceover`: a label that names its control type, a hint that names a gesture or a key, or a hint that is not a sentence.
3. Leave alone a glossary word, even one the reviewer would choose differently: propose it in the report, unless it is wrong in the sense one string needs.
   Leave alone placeholders and their order, plural categories, names never translated, and `keepEnglish` strings.
4. Write each chunk's fixes as a batch (`l10n.py apply`, with its refusal loop), and record each fix: the string's `id`, the English, the text before, the text after, and the category with one short reason.
   Check the catalog once at the end.
5. The records go to `Scripts/l10n/reviews/<code>.json`, one file a language, for the native speaker who reviews next.
   A fix names its string by `id`, or by `ids` where one fix covers several; its `key` is the English text that was the string's key before the catalog was keyed by ID.
   Every language but English has a file there, so each has had this one review; what is still open is a native speaker's.
6. A file may hold a part 4: the words carried across the three parts after they merged (Apple's own names read from this Mac's tables, the settings paths, and a few words the parts disagreed on).

## The prompt for a translator agent
<!-- id: translation-agent-prompt; keys: prompt, translator agent, batch file, brief; src: Scripts/l10n/l10n.py -->

The orchestrator launches one agent per batch with this prompt, after `todo --lang LANGUAGE --out BATCH` has written the batch.
Replace LANGUAGE and BATCH; a model of the Sonnet kind at high effort does this well.

    You translate the interface text of TextMouth, a macOS and iPhone text-to-speech and audiobook app whose user is blind
    and reads with VoiceOver and a braille display, into LANGUAGE.
    Read docs/developer/translation.md first, and follow it exactly.
    Your batch is BATCH, written by Scripts/l10n/l10n.py todo. Fill in "translation" in every item, and change nothing else
    except "keepEnglish": true where the English is also right in LANGUAGE.
    For each item use its comment, its context (the code around the use), its placeholders, its glossary terms, its
    doNotTranslate names, and its previous translation when it has one. An item's key is the string's ID, not its text.
    Then run: python3 -I -B Scripts/l10n/l10n.py apply BATCH
    Fix every refusal in BATCH.rejected.json (its items carry the reasons), then run apply on BATCH.rejected.json, which
    rewrites that same file with what is still refused; repeat until apply exits 0. Never apply BATCH again after that.
    Then run check.
    Never read or write ~/.TextMouth or any data folder; never delete a file; do not commit anything but the catalog and
    the glossary; do not push or merge.
    Report in 20 lines: how many strings were written, each refusal you could not fix and why, each string that should
    not be translated (a log line, a stored key), each glossary term you doubt, and each place where the comment or the
    context was not enough to translate with confidence.

The agent works from its own branch, and its commit holds only `TextMouth/Localization/Localizable.xcstrings` (and `Scripts/l10n/glossary.json` where it added a term).
