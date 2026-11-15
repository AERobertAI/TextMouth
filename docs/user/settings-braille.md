# Settings: the Braille tab
<!-- id: settings-braille-tab; keys: braille settings, braille code, liblouis, BRF, PEF, braille display; src: TextMouth/Views/Settings/BrailleSettingsView.swift, TextMouth/Models/BrailleTableCatalog.swift -->

Part of [TextMouth's documentation](../../README.md).

## Braille tab
<!-- id: braille-tab; keys: brailleTable, brailleFileCode, UEB, English Braille American Edition, grade 2, contracted; src: TextMouth/Views/Settings/BrailleSettingsView.swift, TextMouth/Models/BrailleTableCatalog.swift, TextMouth/ViewModels/BrailleCodeChoiceModel.swift -->

The Braille tab, between Text and Sounds, chooses the braille code TextMouth reads braille files with and writes braille in (see [What TextMouth reads](what-textmouth-reads.md) and [Exporting books](exporting-books.md)).
Its one group is headed "Braille", and holds three pop-up buttons, a sentence, and a caption.
Export's braille options draw the same three pop-ups.

### Language, Braille code, and Contraction
<!-- id: language-braille-code-contraction; keys: Language pop-up, Braille code pop-up, Contraction pop-up, Grade 1, Grade 2, uncontracted; src: TextMouth/Views/Settings/BrailleSettingsView.swift, TextMouth/ViewModels/BrailleCodeChoiceModel.swift, TextMouth/Models/BrailleTableCatalog.swift -->

- "Language" comes first.
  Its hint is "The language of the braille code TextMouth reads braille files with and writes braille in."
  English is listed first, and the other languages follow in alphabetical order. macOS names each language in your language; a language macOS cannot name takes the table's own name; for example, Munda shows as "Munda".
- "Braille code" offers the chosen language's codes.
  English has "Unified English Braille" and "English Braille, American Edition", and this Mac's tables add more, such as "English braille as used in the U.K." on macOS 26.3.
  A code of another language is listed by its tables' display names, such as "French braille" or "Danish 6-dot braille (2022 standard)".
  Its hint is "The braille code TextMouth reads braille files with and writes braille in."
- "Contraction" offers what the chosen code's tables state: "Uncontracted (Grade 1)" and "Contracted (Grade 2)", and, for some of this Mac's tables, "Uncontracted (Grade 0)", "Partly contracted", or "As the table defines" for a table that states no contraction.
  A table that states no grade leaves out the grade in parentheses after "Uncontracted" or "Contracted".
  Its hint is "Whether that code's braille is contracted.
  Contracted braille writes common words and letter groups in fewer cells."
  Choosing another language or code keeps the contraction you had when the new code has it, and otherwise takes its contracted table, or its first.

### Defaults, and where the chosen table comes from
<!-- id: defaults-where-chosen-table-comes; keys: default braille table, built into TextMouth, liblouis version, table missing; src: TextMouth/Views/Settings/BrailleSettingsView.swift, TextMouth/Models/BrailleTableOrigin.swift, TextMouth/Models/BrailleTableCatalog.swift -->

- Until you choose, the language is English, the code is Unified English Braille, and the contraction is contracted (Grade 2).
  English stays built in and stays the default.
- Under the pop-ups, one sentence says where the chosen table comes from.
  For a table built into TextMouth it is "The chosen table is built into TextMouth (liblouis 3.39.0)."
  For one of this Mac's tables it is "The chosen table is one of this Mac's VoiceOver braille tables (liblouis 3.34.0).", with the version of this Mac's tables; when they name none, it says "The chosen table is one of this Mac's VoiceOver braille tables." alone.
  When this Mac no longer has the table chosen, as after a macOS update that removed it, it is "This Mac no longer has the chosen table, “mac:fr-bfu-g2.ctb”; choose another."
- The caption under that sentence reads "TextMouth reads braille files (BRF, BRL, and PEF) with this code, and exports braille with it unless you choose another in the Export dialog.
  A book keeps the code it was imported with."
  A change applies to the books imported from then on; a book already in the library keeps its code.

### Braille file characters
<!-- id: braille-file-characters; keys: brailleFileCode, ascii-na, Eurobraille, Braille ASCII, Unicode braille patterns, BRL; src: TextMouth/Views/Settings/BrailleSettingsView.swift, TextMouth/ViewModels/BrailleFileCodeChoiceModel.swift, TextMouth/Parsers/BrailleFileCode.swift -->

- "Braille file characters" follows that caption: a pop-up button that chooses how a BRF or BRL file writes each braille cell as a character, for the books you add from now on.
  It is left out, as the other pop-ups are, when TextMouth finds no braille tables.
  Its items are "North American Braille ASCII", the default, and "Eurobraille, six-dot (German-speaking countries)".
  Its hint is "How a BRF or BRL file writes each braille cell as a character.
  Most files use North American Braille ASCII."
  VoiceOver says its value first, as in "North American Braille ASCII, Braille file characters, pop-up button".
- Its own caption, under it, reads "TextMouth reads BRF and BRL files you add from now on with these characters; a file of Unicode braille patterns is recognized by itself.
  The Export dialog starts a BRF with them.
  A book keeps the characters it was imported with, which Book Information can change."
  Unicode braille patterns, the third code, is not an item here, since TextMouth recognizes a file of them by its bytes; the Export dialog and Book Information list all three.
  A book keeps the characters it was imported with, whatever this setting says later.
- config.json holds the choice as brailleFileCode (see [Editing settings in config.json](config-json.md)).

### Guess the braille code of new books
<!-- id: guess-braille-code-new-books; keys: code detection, guessed code, English Braille American Edition, auto-detect, import; src: TextMouth/Views/Settings/BrailleSettingsView.swift, TextMouth/Parsers/BrailleCodeDetector.swift -->

- "Guess the braille code of new books" follows, a switch that is on by default.
  It is left out, as the pop-ups are, when TextMouth finds no braille tables.
  Its hint is "When on, a braille file read as Unified English Braille, contracted, that is clearly English Braille, American Edition, is read with that code instead."
- Its caption, under it, reads "Only a book that clearly shows English Braille, American Edition is changed, when it is added.
  Book Information says the code was guessed and can choose another."
  - The switch changes only the books you add from then on.
    A book already in the library is not guessed again, whichever way the switch is set, and turning it off changes no book.
  - It acts only when the code above is a contracted Unified English Braille table, which it is until you choose another.
    With any other code, or uncontracted Unified English Braille, your choice stands.
  - It applies to a BRF or BRL file; a PEF file is never guessed.
    See [What TextMouth reads](what-textmouth-reads.md) for what counts as clearly.
  - config.json does not hold this switch.

### Built-in tables and where the choice is kept
<!-- id: built-tables-where-choice-kept; keys: en-ueb-g1.ctb, en-ueb-g2.ctb, en_US.tbl, en-us-g1.ctb, brailleTable; src: TextMouth/Models/BrailleTableCatalog.swift, TextMouth/Views/Settings/BrailleSettingsView.swift -->

- Four tables are built into TextMouth: Unified English uncontracted (en-ueb-g1.ctb) and contracted (en-ueb-g2.ctb) braille, and English uncontracted (en-us-g1.ctb) and contracted (en_US.tbl) braille as used in the U.S. The pop-ups offer what the tables say about themselves.
  In place of them, the tab says "TextMouth found no braille tables in its bundle." when TextMouth finds no table at all, in its bundle or on this Mac.
- config.json holds the choice as brailleTable (see [Editing settings in config.json](config-json.md)).

## This Mac's braille tables
<!-- id: this-mac-braille-tables; keys: VoiceOver braille tables, mac: tables, BrailleTables folder, LiblouisBrailleTranslator, 26.3, eight-dot; src: TextMouth/Models/BrailleTableCatalog.swift, TextMouth/Models/BrailleTableOrigin.swift, TextMouth/Services/MacBrailleTableCheck.swift, TextMouth/Services/BrailleTranslator.swift -->

This Mac's braille tables, in the Braille tab and in Export's braille options, are VoiceOver's own, and they add the languages and codes beyond TextMouth's four English tables.

- Where they come from: VoiceOver's liblouis tables, in /System/Library/ScreenReader/BrailleTables/LiblouisBrailleTranslator.brailletable, in its Contents/Resources/liblouis/tables folder; they are liblouis 3.34.0 on macOS 26.3.
  TextMouth reads them where they are and never copies, changes, or downloads them, so the app does not grow.
  A Mac without that folder offers TextMouth's own tables alone, with no error.
- When they are read: TextMouth reads the tables' headers once, at launch, in the background, so the pop-ups, Export, and Book Info find them ready.
- Which are offered: literary tables only; never one that states it is eight-dot (one that states nothing is offered, and its check, below, decides); and never a table that only includes another table offered in the same language.
  Where this Mac has a file named like one of TextMouth's four, only TextMouth's is listed.
  On macOS 26.3 about 121 tables in 79 languages are usable.
- Listed, but refused when chosen: on macOS 26.3 the tables of Greek, Hungarian, Icelandic, Serbian, and Cantonese.
- The check: TextMouth checks a Mac table the first time it is chosen in a session, off the main thread, so nothing waits; the pop-ups show the table chosen until the check ends.
  TextMouth's braille helper loads the table, translates a sample of letters, digits, and typographic punctuation to braille and back, and measures its memory and speed.
  A table is refused when it does not load, when it needs more than 64 MB of memory, or when it translates more slowly than 50 KB a second (20 seconds for each MB), and a table that does not state that it is six-dot is refused when its braille for the sample holds eight-dot cells.
  A table that passes runs with limits made for it (see [Where TextMouth keeps your library](where-your-library-lives.md)).
  TextMouth also checks a Mac table before its first use at an import or an export, so a table named in config.json, or one a macOS update changed or removed, is refused by name.
  TextMouth keeps a verdict until it quits, except a "too slow" refusal and a check that could not run, which the next choice or import measures again.
- A refusal is spoken once the pop-up's menu has closed, and the pop-ups go back to the table in use: "TextMouth can't use this Mac's table “Greek braille”: it does not load in TextMouth's liblouis 3.39.0."
  The table is named by its display name, and the reasons after the colon are:
  - "it does not load in TextMouth's liblouis 3.39.0"
  - "it writes eight-dot braille, and TextMouth uses six-dot braille only"
  - "this Mac no longer has it"
  - "it needs more than 64 MB of memory"
  - "it translates too slowly, under 50 KB a second"
- A check that could not run says nothing of the table: "TextMouth could not check this Mac's table “Greek braille”: the braille helper failed.
  Choose it again to try once more."
  The reason after the colon is "the braille helper failed", "TextMouth could not make a folder to check it in", or "the braille helper was stopped because" and the watchdog's reason, in the words listed in [Adding books](adding-books.md).
  At an import or an export the sentence is "TextMouth could not check this Mac's braille table “mac:el.ctb”: the braille helper failed.
  Try again."
