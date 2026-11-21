# Translating TextMouth
<!-- id: translating-textmouth; keys: localization, translator, Spanish, xcstrings, String Catalog, TRANSLATION.md, l10n.py; src: Scripts/l10n/l10n.py, Scripts/l10n/translate.py, TextMouth/Localization/Localizable.xcstrings -->

Part of [TextMouth's documentation](../../README.md).

This is what a translator, human or agent, reads before translating the app's interface text.
The text lives in one String Catalog, `TextMouth/Localization/Localizable.xcstrings`, which both apps share.
Never edit the catalog by hand: `Scripts/l10n/l10n.py` writes it in the layout Xcode expects, and checks what it writes.
The catalog holds 23 languages.
The first eleven are English, Spanish (`es`), Italian (`it`), French (`fr`), Brazilian Portuguese (`pt-BR`), German (`de`), Russian (`ru`), Ukrainian (`uk`), Simplified Chinese (`zh-Hans`), Japanese (`ja`), and Korean (`ko`).
The second wave of twelve is Hindi (`hi`), Arabic (`ar`), Bengali (`bn`), Indonesian (`id`), Vietnamese (`vi`), Turkish (`tr`), Thai (`th`), Polish (`pl`), Traditional Chinese (`zh-Hant`), Dutch (`nl`), Swedish (`sv`), and Hebrew (`he`).
All but English are machine translations, and a native speaker has reviewed none.
`Scripts/l10n/config.json`'s `languages` list is still empty, so `check` does not yet fail for a string missing in a language; it fails only for a string that is wrong.

## The steps
<!-- id: translation-steps; keys: sync, todo, apply, check, status, batch, rejected, plural; src: Scripts/l10n/l10n.py, Scripts/l10n/translate.py -->

Run every command as `python3 -I -B Scripts/l10n/l10n.py COMMAND`; `--help` after a command lists its options.

1. `sync` type-checks both apps and merges the strings the compiler finds into the catalog.
   The agent that changed the code runs it, and it takes the heavy-work lock for about four minutes, so a translator does not.
   It also writes `build/l10n/locations.json`, the file and line of each string and the commit it read them from, which `todo` reads for the code around a string.
   It copies each key's note, the `// Translators:` line above its literal, into the catalog as the key's comment; a source that does not match the compiler's record is named, its keys keep their comments, and `sync` exits 1.
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
- `scan.py show FILE` lists, apart from the unlocalized text, each key whose note is missing or misplaced: a `comment:` argument, a key with no `// Translators:` line directly above it (a SwiftUI literal such as `Button("…")` too), and a line that holds two keys; `lint` refuses each.

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
- A name beside Japanese, Chinese, or Korean text is not hidden by it: "TextMouthは" and "TextMouth가" keep the name, since those scripts have no spaces (`_SPACELESS` in `Scripts/l10n/glossary.py`).
  A Latin or Cyrillic letter beside a name still joins it into another word.
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

## Italian
<!-- id: translation-italian; keys: it, tu, Apple's Italian, many; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Address the listener as "tu": "Scegli una cartella", "la tua libreria".
- Menu items and buttons use the imperative ("Apri", "Riproduci"); hints use the third person and end with a period ("Riproduce il libro.").
- Sentence case: "Elenco di lettura".
- Plural categories `one`, `many`, `other`; `many` is exact millions ("%lld di libri").

## French
<!-- id: translation-french; keys: fr, vous, no-break space, Apple's French, many; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Address the listener as "vous": "Choisissez un dossier", "votre bibliothèque".
- Menu items and buttons use the infinitive ("Ouvrir", "Lire"); hints use the third person and end with a period ("Lit le livre.").
- Sentence case.
  A no-break space (U+00A0) goes before `:`, `;`, `?`, and `!` and inside « », never a plain space.
- Plural categories `one`, `many`, `other`; `one` covers 0 and 1 and keeps the number, and `many` is exact millions ("%lld de livres").

## Brazilian Portuguese
<!-- id: translation-portuguese-brazil; keys: pt-BR, você, Brazilian words, Apple's Portuguese, many; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Address the listener as "você": "Escolha uma pasta", "sua biblioteca".
- Menu items and buttons use the infinitive ("Abrir", "Reproduzir"); hints use the third person and end with a period ("Reproduz o livro.").
- Brazil's words and spelling ("arquivo", "tela", "excluir"), never Portugal's.
- Plural categories `one`, `many`, `other`; `one` covers 0 and 1 and keeps the number, and `many` is exact millions ("%lld de livros").

## German
<!-- id: translation-german; keys: de, du, capitalized nouns, long words, Apple's German; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Address the listener as "du", as Apple's German does: "Wähle einen Ordner", "deine Bibliothek".
- Menu items and buttons use the infinitive ("Öffnen", "Wiedergeben"); hints use the third person and end with a period ("Gibt das Buch wieder.").
- Nouns are capitalized; quotation marks are „…“.
- German runs long: take the shorter of two good words, and never a compound a button label cannot hold.
- Plural categories `one`, `other`.

## Russian
<!-- id: translation-russian; keys: ru, вы, Cyrillic, few, many, Apple's Russian; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Address the listener formally, "вы" in lower case: "Выберите папку", "ваша книга".
- Menu items and buttons use the infinitive ("Открыть", "Воспроизвести"); hints use the third person and end with a period ("Воспроизводит книгу.").
- Quotation marks «…»; use "ё" only where Apple's Russian does, and consistently.
- Plural categories `one` (1, 21, not 11), `few` (2 to 4, 22 to 24), `many` (0, 5 to 20, 25 to 30), and `other` (a fraction); every form keeps the number.

## Ukrainian
<!-- id: translation-ukrainian; keys: uk, ви, Cyrillic, apostrophe, few, many; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Ukrainian words and spelling, never Russian ones; address the listener formally, "ви": "Виберіть папку", "ваша бібліотека".
- Menu items and buttons use the infinitive ("Відкрити", "Відтворити"); hints use the third person and end with a period ("Відтворює книгу.").
- Quotation marks «…»; the apostrophe inside a word is the typographic one (U+2019), everywhere.
- Plural categories `one`, `few`, `many`, `other`, as in Russian; every form keeps the number.

## Simplified Chinese
<!-- id: translation-chinese; keys: zh-Hans, Mandarin, full-width punctuation, measure word, Apple's Chinese; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Mainland Simplified Chinese as Apple writes it; address the listener as "你" where a sentence needs it.
- Full-width punctuation in Chinese text (，。：；？！“”（）), and a space between Chinese characters and a Latin word or a placeholder: "在 Mac 上", "%lld 本书".
- Labels are short noun or verb phrases ("打开", "播放"); hints are sentences that end with "。".
- One plural category, `other`, with the number and the right measure word.

## Japanese
<!-- id: translation-japanese; keys: ja, polite style, katakana, counters, Apple's Japanese; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- The polite style (です・ます) in sentences, hints, and messages ("ブックを再生します。"); labels and menu items as Apple writes them ("開く", "再生").
- Full-width punctuation (、。「」); loanwords in katakana as Apple spells them (ライブラリ, フォルダ).
- One plural category, `other`, with the number and the right counter (冊, 件, 個, 分).

## Korean
<!-- id: translation-korean; keys: ko, Hangul, particles, polite endings, Apple's Korean; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Polite formal endings in sentences, hints, and messages ("책을 재생합니다."); labels and menu items as Apple writes them ("열기", "재생").
- Where a placeholder's last sound is unknown, write both particle forms, as Apple's Korean does: "%@을(를)", "%@이(가)".
  A name takes its particle straight against it ("TextMouth가").
- One plural category, `other`, with the number and the right counter (권, 개, 분).

## Hindi
<!-- id: translation-hindi; keys: hi, Devanagari, आप, danda, Apple's Hindi; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Devanagari, addressing the listener as "आप"; menu items and buttons as Apple writes them ("खोलें", "चलाएँ", "रद्द करें"); hints in the third person ("पुस्तक चलाता है।").
- Sentences end with "।"; Mac, iPhone, and the glossary's names stay in Latin letters.
- Plural categories `one` and `other`; `one` covers 0 and 1 and keeps the number.

## Arabic
<!-- id: translation-arabic; keys: ar, right-to-left, RTL, Modern Standard Arabic, mirrored layout, Apple's Arabic; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py; status: incomplete; issues: FR36 -->

- Modern Standard Arabic as Apple's Arabic interface writes it: commands in Apple's form, hints in the third person, and the punctuation (، ؛ ؟) and quotation marks Apple's Arabic uses.
- Arabic is the app's first right-to-left language, with Hebrew.
  A string holds no direction marks: Foundation lays the text out, SwiftUI mirrors the layout, and a Latin name or a placeholder stays as it is inside the text.
- Plural categories `zero` (0), `one` (1), `two` (2), `few` (3 to 10), `many` (11 to 99, by the last two digits), and `other`; every form keeps the number.
- No test yet looks at a mirrored window, so the layout is unchecked.

## Bengali
<!-- id: translation-bengali; keys: bn, Bengali script, আপনি, Apple's Bengali; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Bengali script, addressing the listener as "আপনি"; commands and hints as Apple's Bengali would write them; sentences end with "।".
- Plural categories `one` and `other`; `one` covers 0 and 1 and keeps the number.

## Indonesian
<!-- id: translation-indonesian; keys: id, Anda, base form, Apple's Indonesian; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Address the listener as "Anda"; commands in the base form ("Buka", "Putar", "Batalkan"); hints in the third person ("Memutar buku.").
- One plural category, `other`; a noun after a number stays singular ("%lld buku").

## Vietnamese
<!-- id: translation-vietnamese; keys: vi, bạn, Apple's Vietnamese, Hiển thị; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Address the listener as "bạn"; commands as Apple writes them ("Mở", "Phát", "Hủy"); hints are sentences that end with a period.
- One plural category, `other`: Foundation on macOS 26.3 gives Vietnamese no other form, though CLDR 49 gives it `one`.
- The consistency pass settled "Hiển thị" for Show everywhere, with the control's name in quotation marks inside a sentence.

## Turkish
<!-- id: translation-turkish; keys: tr, apostrophe, suffix, kelime, Apple's Turkish; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Commands in the imperative ("Aç", "Oynat", "Vazgeç"); hints in the third person ("Kitabı oynatır."); a sentence that addresses the listener uses Apple's polite form.
- A suffix on a name takes an apostrophe ("TextMouth'u", "Mac'te"), but not after a translated name such as "Çöp Sepeti" or "Okuma Listesi"; a noun after a number stays singular.
- Plural categories `one` (exactly 1) and `other`; the two forms are usually the same text.
- The consistency pass settled "kelime" for word (not "sözcük") and quotation marks around a control's name held by a placeholder.

## Thai
<!-- id: translation-thai; keys: th, no spaces, full stop, Apple's Thai; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- No space between words, a space between phrases and around Latin words and numbers; no polite particles; commands as Apple writes them ("เปิด", "เล่น", "ยกเลิก").
- No full stop ends a sentence, as in Apple's Thai.
- One plural category, `other`.

## Polish
<!-- id: translation-polish; keys: pl, few, many, Macu, glued ending, Apple's Polish; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py; status: incomplete; issues: FR36 -->

- Commands in the imperative ("Otwórz", "Odtwórz", "Anuluj"); hints in the third person ("Odtwarza książkę."); quotation marks „…”.
- Plural categories `one` (exactly 1), `few` (2 to 4, 22 to 24, 32 to 34, not 12 to 14), `many` (0, 5 to 21, 25 to 31), and `other` (a fraction); every form but `one` keeps the number.
- The name check refuses a name with an ending glued on ("Macu"), so translators write "komputer Mac" instead.
  A follow-up may let Polish endings through.

## Traditional Chinese
<!-- id: translation-chinese-traditional; keys: zh-Hant, Taiwan, 檔案夾, Apple's Traditional Chinese; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Taiwan's Traditional Chinese as Apple writes it (資料夾, 檔案, 設定, 播放, 書籤, 搜尋), never Simplified words converted character by character; address the listener as "你".
- The consistency pass settled 檔案夾 for a folder, as Apple's Finder writes it.
- Full-width punctuation (，。：；？！「」（）) and a space between Chinese and a Latin word or a placeholder.
- One plural category, `other`.

## Dutch
<!-- id: translation-dutch; keys: nl, je, Apple's Dutch; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py -->

- Address the listener as "je"; menu items and buttons as Apple writes them ("Open", "Speel af", "Annuleer"); hints in the third person ("Speelt het boek af.").
- Plural categories `one` and `other`.

## Swedish
<!-- id: translation-swedish; keys: sv, du, Macen, glued ending, Apple's Swedish; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py; status: incomplete; issues: FR36 -->

- Address the listener as "du"; commands in the imperative ("Öppna", "Spela upp", "Avbryt"); hints in the third person ("Spelar upp boken."); quotation marks ”…”.
- The name check refuses a name with an ending glued on ("Macen", "TextMouths"), so translators write "Mac-datorn" instead.
- Plural categories `one` and `other`.

## Hebrew
<!-- id: translation-hebrew; keys: he, right-to-left, RTL, gendered forms, Apple's Hebrew; src: Scripts/l10n/glossary.json, Scripts/l10n/catalog.py; status: incomplete; issues: FR36 -->

- Apple's Hebrew: commands in the forms its interface uses, hints in the third person, a gendered form avoided where Apple avoids it, and its quotation marks and punctuation.
- Right to left, with no direction marks (see Arabic); no test yet looks at a mirrored window.
- Plural categories `one` (exactly 1), `two` (exactly 2), and `other`.

## Translating at scale
<!-- id: translation-at-scale; keys: partition, key file, disjoint keys, batches, consistency pass, glossary first, 20 agents, extract-report; src: Scripts/l10n/l10n.py, Scripts/l10n/glossary.json, Scripts/agents/extract-report.py -->

The nine languages added after Spanish were made this way, about 4,200 strings each.
Developers who convert code read [Localizing TextMouth's code](localization.md) instead.

1. Glossary first.
   One agent (`l10nglossary`) chooses each glossary term in every new language, marked `"check": true`, before any translator starts.
   Translators use those words even where they would choose another, and propose better ones in their reports.
2. Partition the keys.
   List the keys that still lack the language, and split them by area of the app into six disjoint key files of 650 to 750 keys (library; storage and settings; feeds and import; audio and transcripts; reader, formats, and menus; export, speech, and iPhone).
   Two translators never hold the same key, so their branches merge without a conflict.
3. Give each translator one file, and its own scratch folder, since two translators that wrote `batch-1.json` in one folder overwrote each other's batch.
   It runs `todo --keys-from FILE --out DIR/batch.json`, 250 strings at a time, and `apply`.
   Its branch holds only the catalog.
4. Run at most 20 agents at once, and launch the next as a slot frees.
   Past 20, a launch is refused; a finished agent keeps its slot until it is stopped, and stopping it also ends its leftover background checks.
5. A translator never runs `check`.
   One run takes about 12 minutes on an eleven-language catalog, and twenty at once pushed the load past 80.
   `apply` already checks every string it writes, and the orchestrator runs `check` on the merged catalog.
6. A translator's report is its final message.
   An agent in an isolated worktree cannot write the main checkout, so `Scripts/agents/extract-report.py` prints the report from the agent's transcript.
7. Check each branch before merging: it changed only its own keys, in its own language, and none of them is left without the language.
8. After a language's branches merge, one agent makes a consistency pass over the whole language:
   - a control's name inside a sentence matches that control's own label;
   - each term has one translation, and the pass's glossary changes go to a file, which the orchestrator applies to `glossary.json` at once, so later passes see them;
   - names that must not be translated stay as they are.
   The pass changes the catalog only, and is a branch of its own.

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
