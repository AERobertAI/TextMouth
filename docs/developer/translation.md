# Translating TextMouth
<!-- id: translating-textmouth; keys: localization, translator, Spanish, xcstrings, String Catalog, TRANSLATION.md, l10n.py; src: Scripts/l10n/l10n.py, Scripts/l10n/translate.py, TextMouth/Localization/Localizable.xcstrings -->

Part of [TextMouth's documentation](../../README.md).

This is what a translator, human or agent, reads before translating the app's interface text.
The text lives in one String Catalog, `TextMouth/Localization/Localizable.xcstrings`, which both apps share.
Never edit the catalog by hand: `Scripts/l10n/l10n.py` writes it in the layout Xcode expects, and checks what it writes.
The shipped languages are listed in `Scripts/l10n/config.json`; Spanish (`es`) is the first.

## The steps
<!-- id: translation-steps; keys: sync, todo, apply, check, status, batch, rejected, plural; src: Scripts/l10n/l10n.py, Scripts/l10n/translate.py -->

Run every command as `python3 -I -B Scripts/l10n/l10n.py COMMAND`; `--help` after a command lists its options.

1. `sync` type-checks both apps and merges the strings the compiler finds into the catalog.
   The agent that changed the code runs it, and it takes the heavy-work lock for about four minutes, so a translator does not.
   It also writes `build/l10n/locations.json`, the file and line of each string and the commit it read them from, which `todo` reads for the code around a string.
2. `todo --lang es --out batch.json` writes a batch of up to 300 strings that still need Spanish.
   `--keys-from FILE`, `--file PATH...`, and `--area NAME` pick the strings (a list of keys, the strings some files use, or one of the scanner's areas); `--limit N` sets the batch size, and 0 means all (a negative number is refused).
   `--area` needs the unlocalized-text scanner (its area table, from the `l10n/scan` branch); without it `--area` says so, and `--file` and `--keys-from` still work.
   `todo` warns when `locations.json` was made from other code than this checkout's, and then leaves out the code of any use where the string's text is not within the five lines shown.
   An item's `previous` is an earlier translation of a nearly identical stale string, with its placeholders; it is offered only when the placeholders are the key's.
3. Fill in `translation` in each item of the batch: a text, or for a string with plural forms an object with one text for each plural category the language uses.
   Nothing else in an item is changed, except `"keepEnglish": true` where the English is right in the language too (a word both share).
4. `apply batch.json` checks each translation and writes the good ones as `machine_translated`; it is safe to run twice.
   It prints each refusal with its reason, writes the refused items to `batch.json.rejected.json`, and exits 1.
   Fix those items in that file and run `apply batch.json.rejected.json`: that run writes the good ones and rewrites the same file with what is still refused, so repeat until it exits 0 and the file has no items.
   Never apply the original `batch.json` again once its rejected file holds fixes: a rejected file newer than the batch is left alone, and the run says so.
   `apply --lang es` stops a batch made for another language.
5. `check` lists what is wrong in the catalog and warns where a translation does not use a glossary term (a warning, not a failure); `status --lang es` counts the strings by state.
6. The plural forms of an English string go in with `plural KEY --lang en --one "%lld book" --other "%lld books"`, since the key `%lld books` is only the fallback.
   `plural` takes the other languages' forms too, and checks their categories and placeholders as `apply` does.

`apply` refuses:
- placeholders that differ from the English's, plural form by plural form;
- a plural category the language does not use, or one it uses that is missing;
- plural forms for an English string that has none, or for a key with no number placeholder (`%lld`, `%d`, `%f`);
- a `one` form that leaves out the number, except in a language whose `one` means exactly 1 (Spanish, English, German, Italian, Dutch, Portuguese of Portugal): in French `one` also covers 0 and in Russian 21, so there the number stays;
- empty text, and control characters other than a line break and a tab;
- leading or trailing whitespace that differs from the English's, form by form;
- a different number of `%%` (a literal percent sign), and a lone `%` in a text that has placeholders;
- the English left as it was, unless the item has `keepEnglish` or the text is only names, numbers, and placeholders;
- a name from the glossary's `doNotTranslate` list that the English has and the translation lacks;
- a batch whose language is the source language or one the tools do not know, or differs from `--lang`;
- a string whose English changed after the batch was made, a stale string, and a machine translation over a person's: a form a person marked `translated` is kept as it is (a warning), and the other forms are written.

A translation more than three times as long as an English of at least 12 characters is only a warning, and so is a different number of line breaks inside the text.

## Syncing, pruning, and the test classes
<!-- id: translation-around-the-steps; keys: sync-paths.txt, syncPaths, prune, reach, stale, test classes, scan.py show; src: Scripts/l10n/l10n.py, Scripts/l10n/reach.py, Scripts/l10n/sync-paths.txt, Scripts/l10n/scan.py -->

`sync` keeps only the strings found in the files that `Scripts/l10n/sync-paths.txt` lists, one glob a line.
Blank lines and `#` comments are skipped, and repeats are dropped; a glob that matches no file is refused.
Each conversion wave adds its own lines there, kept sorted, and `.gitattributes` merges the file by union, so two waves never conflict.
An old `config.json` that still has a `syncPaths` key is refused with a sentence naming that file.

- After a cut, `check` fails until the strings the code no longer has are gone.
  `prune` deletes the stale strings that hold no translation in any language and prints each key; `prune --all` deletes every stale string, and `prune --dry-run` lists them and writes nothing.
- `reach [--base REF] [--explain]` prints the hosted test classes that the branch's localization could break, for `build-train.py request --classes`.
  The first line holds the Mac classes, comma-separated; the iPhone unit test classes follow on a line of their own, since a train names them by the area `phone`.
  It finds the classes whose files hold an English text the branch localized (cut at its first interpolation, 12 characters or more), name a converted file (they read its source), or are what `run-area.py --changed` finds; `--explain` gives each reason.
- `scan.py show FILE` lists, apart from the unlocalized text, the SwiftUI literals the compiler extracts with no comment (`Button("…")`, `.accessibilityLabel("…")`, and the like): `check` refuses them once the file is synced, so move each into a wording static with `String(localized:comment:)`.

## The catalog's merge driver
<!-- id: translation-merge-driver; keys: merge driver, .gitattributes, xcstrings, merge conflict, make l10n-merge-driver, shared keys, comment; src: Scripts/l10n/merge.py, Scripts/l10n/l10n.py, Makefile -->

Two branches that each add or translate strings merge without a conflict, because `.gitattributes` gives `*.xcstrings` the driver `merge=xcstrings`, which merges by key, language, and plural form.
Git reads the driver's definition from the repository's configuration, so define it once for each clone with `make l10n-merge-driver`.
The merge worktrees share that configuration, so one definition serves them all.
Without it git merges the catalog as text, and neighbouring keys conflict.

Many waves add the same short key ("Cancel", "Done"), each with its own comment, and a key main already has can gain a comment line on both branches.
`xcstringstool sync` writes such a comment as the distinct comments, sorted by code point and joined by line breaks, so the driver merges the two sides' comment lines into that sorted union, less any line a side cut, with no conflict.
Where a side's lines are not in sorted order (a comment that itself holds a line break), the driver keeps ours' lines and then theirs' new ones, and the next `sync` rewrites the comment.

The driver refuses (exit 2, your file untouched) a file that is not a catalog: not JSON, not an object, or with `strings` that is not an object of objects.
It writes the result through a temporary file and a rename, so an interrupted merge never leaves half a catalog.
When both sides changed one piece differently it keeps ours, prints the key and the three values on standard error, and exits 1, so git reports the file conflicted.

## States
<!-- id: translation-states; keys: machine_translated, translated, needs_review, stale, new, review; src: Scripts/l10n/catalog.py, Scripts/l10n/translate.py -->

- `new`: no translation yet.
- `machine_translated`: made by a model and checked by the tools; it ships.
- `translated`: a native speaker has reviewed it.
  `apply --state translated` is for that review only.
- `needs_review`: the English changed since the translation was written; `todo` offers the string again with the translation as `current`.
- `stale`: the code no longer has the string; `sync` marks it, and `check` reports it until someone deletes it.

A string is done in a language when every form of it is `machine_translated` or `translated` and none is empty.
Every state is compiled into the app, so an empty value would ship as empty text, and `check` refuses it.

## The rules for every language
<!-- id: translation-rules; keys: placeholders, plural categories, positions, length, glossary, comments, never translated; src: Scripts/l10n/catalog.py, Scripts/l10n/glossary.json, Scripts/l10n/glossary.py -->

- Read the `comment` and the `context` of an item: the comment says where the text appears and what it is, and the code shows the use.
- Keep every placeholder (`%@`, `%lld`, `%1$@`, `%.1f`) with its type; a text may reorder them only with positions (`%2$@ ... %1$@`), since unnumbered ones are taken in order.
  `%%` is a literal percent sign.
  Never type a number the app counts; the placeholder carries it.
- Give a plural string every category the language uses, as the item's `pluralCategories` lists them.
  The English has `one` and `other`; Spanish also has `many`, used for exact millions ("1 000 000 de libros"), so it needs a form of its own.
- Use the glossary's translation of each term in the item's `glossary`, and mark a doubt in your report rather than invent a second word.
  A glossary entry with `"check": true` is a word a native speaker has not yet confirmed.
  A term is never found inside a name (Windows-1252 is the name Windows), and a command word that is also an everyday word (Close, Open, Done, Play) is found only as a whole label or in a title-case phrase, so a sentence such as "close to the end" has no hit.
- Never change a name in `doNotTranslate`: TextMouth, VoiceOver, EPUB, DAISY, and the other product and format names.
- Never translate what a person does not read: the debug log's lines, a stored key or identifier, a file extension, a URL, a format's element names, or code.
  Such a string should not be in a batch; set `keepEnglish` on it, and name it in your report so it can be marked `shouldTranslate: false`.
- Translate meaning, not words: a text that reads as the English reads in the language is a good one, and a label that is a literal copy of the English word order is not.
- Keep the length near the English where you can: short labels grow most (Spanish runs 15 to 30 percent longer), and a button label must still fit.
- Keep the same punctuation habits as the language's own interface, but never add or drop a sentence.

## What VoiceOver and braille read
<!-- id: translation-voiceover-text; keys: accessibility label, hint, VoiceOver, braille, accessibility, gesture; src: Scripts/l10n/l10n.py -->

The user reads with VoiceOver and a braille display, so text meant for them is the most careful work in the catalog.
The rules are the English's, in the language:
- A label is a word or a short phrase, capitalized the way the language capitalizes, with no final period and no control type (not "button" or "botón").
- A hint is a short sentence that starts with a verb in the third person and ends with a period: "Plays the book." becomes "Reproduce el libro."
- A hint never names the gesture, the key, or the control: no "tap", "double-click", "toca", or "haz clic".
- An announcement says what happened, in the order a listener needs it, with the most important word first.
- A text that a translation makes much longer is also longer in braille, so keep the word choice short.

## Spanish
<!-- id: translation-spanish; keys: es, tú, usted, neutral Spanish, Latin America, regional words, glossary, Apple's Spanish; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

One neutral Spanish (`es`) serves every region, until the user says otherwise.
- Use the familiar "tú", never "usted" and never "vos" or "vosotros": "Elige una carpeta", "tu biblioteca".
- Avoid words that differ by country.
  Say "Mac" and "iPhone", not "ordenador" or "computadora" and "móvil" or "celular"; prefer "archivo", "carpeta", "descargar", and "agregar", which every region understands.
- Use the words Apple's own Spanish interface uses where the glossary has them.
- Menu items and buttons use the infinitive ("Reproducir", "Abrir"), hints use the third person ("Reproduce el libro."), and a message to the reader speaks to "tú" ("No se pudo abrir tu archivo.").
- Capitalize as Spanish does, not as English titles do: "Lista de lectura", not "Lista de Lectura".
- Open questions and exclamations with "¿" and "¡".
- Avoid a gendered word where a neutral one reads naturally; where none does, use the form the glossary gives.
- `many` is the exact-millions form: "%lld de libros".
  The usual counts use `one` and `other`.

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
    doNotTranslate names, and its previous translation when it has one.
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
