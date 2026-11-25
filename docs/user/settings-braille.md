# Settings: the Braille tab
<!-- id: settings-braille-tab; keys: braille settings, braille code, liblouis, BRF, PEF, braille display; src: TextMouth/Views/Settings/BrailleSettingsView.swift, TextMouth/Models/BrailleTableCatalog.swift -->

Part of [TextMouth's documentation](../../README.md).

## Braille tab
<!-- id: braille-tab; keys: brailleTable, brailleFileCode, UEB, English Braille American Edition, grade 2, contracted; src: TextMouth/Views/Settings/BrailleSettingsView.swift, TextMouth/Models/BrailleTableCatalog.swift, TextMouth/ViewModels/BrailleCodeChoiceModel.swift -->

The Braille tab, between Text and Sounds, chooses the braille code TextMouth reads braille files with and writes braille in (see [What TextMouth reads](reads-daisy-and-braille.md) and [Exporting books](exporting-braille.md)).
Its one group is headed "Braille", and holds three pop-up buttons, a sentence, and a caption.
Export's braille options draw the same three pop-ups.
The iPhone has a Braille section in its Settings instead (see The iPhone's Braille section, below).

### Language, Braille code, and Contraction
<!-- id: language-braille-code-contraction; keys: Language pop-up, Braille code pop-up, Contraction pop-up, Grade 1, Grade 2, uncontracted; src: TextMouth/Views/Settings/BrailleSettingsView.swift, TextMouth/ViewModels/BrailleCodeChoiceModel.swift, TextMouth/Models/BrailleTableCatalog.swift -->

- "Language" comes first.
  Its hint is "The language of the braille code for reading and writing braille."
  English is listed first, and the other languages follow in alphabetical order. macOS names each language in your language; a language macOS cannot name takes the table's own name; for example, Munda shows as "Munda".
- "Braille code" offers the chosen language's codes.
  English has "Unified English Braille" and "English Braille, American Edition", and this Mac's tables add more, such as "English braille as used in the U.K." on macOS 26.3.
  A code of another language is listed by its tables' display names, such as "French braille" or "Danish 6-dot braille (2022 standard)".
  Its hint is "The braille code for reading and writing braille."
- "Contraction" offers what the chosen code's tables state: "Uncontracted (Grade 1)" and "Contracted (Grade 2)", and, for some of this Mac's tables, "Uncontracted (Grade 0)", "Partly contracted", or "As the table defines" for a table that states no contraction.
  A table that states no grade leaves out the grade in parentheses after "Uncontracted" or "Contracted".
  Its hint is "Whether that code's braille is contracted, which writes common words and letter groups in fewer cells."
  Choosing another language or code keeps the contraction you had when the new code has it, and otherwise takes its contracted table, or its first.

### Defaults, and where the chosen table comes from
<!-- id: defaults-where-chosen-table-comes; keys: default braille table, built into TextMouth, liblouis version, table missing; src: TextMouth/Views/Settings/BrailleSettingsView.swift, TextMouth/Models/BrailleTableOrigin.swift, TextMouth/Models/BrailleTableCatalog.swift -->

- Until you choose, the language is English, the code is Unified English Braille, and the contraction is contracted (Grade 2).
  English stays built in and stays the default.
- Under the pop-ups, one sentence says where the chosen table comes from.
  For a table built into TextMouth it is "The chosen table is built into TextMouth (liblouis 3.39.0)."
  For one of this Mac's tables it is "The chosen table is one of this Mac's VoiceOver braille tables (liblouis 3.34.0).", with the version of this Mac's tables; when they name none, it says "The chosen table is one of this Mac's VoiceOver braille tables." alone.
  When this Mac no longer has the table chosen, as after a macOS update that removed it, it is "This Mac no longer has the chosen table, “mac:fr-bfu-g2.ctb”; choose another."
- A table chosen on an iPhone, whose name has no "mac:" in front, such as fr-bfu-g2.ctb, is read by this Mac with VoiceOver's table of that name.
  The pop-ups show it as that table, with its language, and the sentence says it is one of this Mac's VoiceOver braille tables; it is never shown as English, or as built in.
  A bare name this Mac has no usable table of, including a table whose includes VoiceOver's folder lacks (Icelandic, Portuguese, and Serbian today), is not taken; the sentence never calls such a table built into TextMouth.
- A table chosen with "mac:" in front for one of TextMouth's own, such as mac:en-ueb-g2.ctb, shows as the built-in table of that name, on a Mac and on an iPhone.
- The caption under that sentence reads "TextMouth reads braille files (BRF, BRL, and PEF) with this code and exports with it unless the Export dialog chooses another.
  A book keeps the code it was imported with."
  A change applies to the books imported from then on; a book already in the library keeps its code.

### Braille file characters
<!-- id: settings-braille-file-characters; keys: brailleFileCode, ascii-na, Eurobraille, Braille ASCII, Unicode braille patterns, BRL; src: TextMouth/Views/Settings/BrailleSettingsView.swift, TextMouth/ViewModels/BrailleFileCodeChoiceModel.swift, TextMouth/Parsers/BrailleFileCode.swift -->

- "Braille file characters" follows that caption: a pop-up button that chooses how a BRF or BRL file writes each braille cell as a character, for the books you add from now on.
  It is left out, as the other pop-ups are, when TextMouth finds no braille tables.
  Its items are "North American Braille ASCII", the default, and "Eurobraille, six-dot (German-speaking countries)".
  Its hint is "How a BRF or BRL file writes each braille cell.
  Most files use North American Braille ASCII."
  VoiceOver says its value first, as in "North American Braille ASCII, Braille file characters, pop-up button".
- Its own caption, under it, reads "TextMouth reads BRF and BRL files you add from now on with these characters, and recognizes Unicode braille patterns by itself.
  The Export dialog starts a BRF with them.
  A book keeps its import characters, which Book Information can change."
  Unicode braille patterns, the third code, is not an item here, since TextMouth recognizes a file of them by its bytes; the Export dialog and Book Information list all three.
  A book keeps the characters it was imported with, whatever this setting says later.
- config.json holds the choice as brailleFileCode (see [Editing settings in config.json](config-json.md)).

### Guess the braille code of new books
<!-- id: guess-braille-code-new-books; keys: code detection, guessed code, English Braille American Edition, auto-detect, import; src: TextMouth/Views/Settings/BrailleSettingsView.swift, TextMouth/Parsers/BrailleCodeDetector.swift -->

- "Guess the braille code of new books" follows, a switch that is on by default.
  It is left out, as the pop-ups are, when TextMouth finds no braille tables.
  Its hint is "When on, a braille file read as contracted Unified English Braille that is clearly English Braille, American Edition is read as that instead."
- Its caption, under it, reads "Only a book that clearly shows English Braille, American Edition changes, when added.
  Book Information says the code was guessed and can choose another."
  - The switch changes only the books you add from then on.
    A book already in the library is not guessed again, whichever way the switch is set, and turning it off changes no book.
  - It acts only when the code above is a contracted Unified English Braille table, which it is until you choose another.
    With any other code, or uncontracted Unified English Braille, your choice stands.
  - It applies to a BRF or BRL file; a PEF file is never guessed.
    See [What TextMouth reads](reads-daisy-and-braille.md) for what counts as clearly.
  - config.json does not hold this switch.

### Built-in tables and where the choice is kept
<!-- id: built-tables-where-choice-kept; keys: en-ueb-g1.ctb, en-ueb-g2.ctb, en_US.tbl, en-us-g1.ctb, brailleTable, BrailleTables.pack; src: TextMouth/Models/BrailleTableCatalog.swift, TextMouth/Views/Settings/BrailleSettingsView.swift, TextMouth/Packs/BrailleTablePack.swift, Scripts/packs/braille_tables_mac.txt -->

- Four tables are built into the Mac app: Unified English uncontracted (en-ueb-g1.ctb) and contracted (en-ueb-g2.ctb) braille, and English uncontracted (en-us-g1.ctb) and contracted (en_US.tbl) braille as used in the U.S. The pop-ups offer what the tables say about themselves.
  The iPhone app carries many more, for many languages (see The iPhone's Braille section, below).
  Neither app holds a table as a loose file: each keeps its tables in one compressed file, and unpacks a table into its caches folder the first time it is used.
  macOS or iOS may empty that folder; TextMouth unpacks the table again when it is next needed.
  In place of the pop-ups, the tab says "TextMouth found no braille tables in its bundle." when TextMouth finds no table at all, in its bundle or on this Mac.
- config.json holds the choice as brailleTable (see [Editing settings in config.json](config-json.md)).
- A table's stored value is its bare file name, such as "en-ueb-g2.ctb", and the value of one of this Mac's tables is "mac:" and its file name.
  A library shared by a Mac and an iPhone, and a book sent from one to the other in a TextMouth package, carry such values across.
  Each device reads the other's value with its own table of that file name and neither rewrites it: see Braille settings in [Editing settings in config.json](config-json.md).

### The iPhone's Braille section
<!-- id: iphone-braille-section; keys: iPhone Settings, Braille code row, braille tables, FR32, FR40, language headings, VoiceOver list; src: TextMouth/Phone/PhoneSettingsModel.swift, TextMouth/Phone/PhoneSettingsWording.swift, TextMouth/Phone/PhoneChoice.swift, TextMouth/Platform/iOS/Views/Settings/PhoneSettingsView.swift, TextMouth/Platform/iOS/Views/PhoneChoiceSheet.swift, TextMouth/Models/BrailleTableCatalog.swift, TextMouthiOSUITests/BrailleSettingsUITests.swift -->

The iPhone's Settings has a section headed "Braille", after Reading and before Times.
It holds, in order:

- "Braille code", a button whose value is the table in use in words, such as "Unified English Braille, contracted (Grade 2), in English".
  Its hint is "The braille code for reading braille files."
- A caption: "TextMouth reads braille files you add from now on with this code.
  A book keeps the code it was added with."
- A second caption, only when the table in use only writes braille: "The chosen table only writes braille, so it is not offered for reading braille files; choose another."
- "Braille file characters", a button whose value is the characters in use, such as "North American Braille ASCII".
  Its hint is "How a BRF or BRL file writes each braille cell.
  Most files use North American Braille ASCII."
- The switch "Guess the braille code of new books".
  Its hint, "When on, a braille file read as contracted Unified English Braille that is clearly English Braille, American Edition is read as that instead.", is also written under it as a caption.
  It does what the Mac's switch does (see Guess the braille code of new books, above).

### The iPhone's list of braille codes
<!-- id: iphone-braille-list; keys: Braille code list, language headings, selected row, Cancel, VoiceOver headings rotor; src: TextMouth/Phone/PhoneSettingsModel.swift, TextMouth/Phone/PhoneChoice.swift, TextMouth/Platform/iOS/Views/PhoneChoiceSheet.swift, TextMouth/Platform/iOS/Views/Settings/PhoneSettingsView.swift, TextMouth/Models/BrailleTableCatalog.swift, TextMouthiOSUITests/BrailleSettingsUITests.swift -->

"Braille code" opens a list under the title "Braille code", with a Cancel button.
One list holds every table the iPhone reads braille files with, where the Mac has the Language, Braille code, and Contraction pop-ups:

- The tables are grouped by language, each group under a heading that VoiceOver's Headings rotor moves by.
  English comes first, and the other languages follow by their names in your language.
- Each table is one row, read as its code, how far it contracts, and its language, such as "French braille, contracted (Grade 2), in French".
  The table in use is announced as selected, and the list opens with VoiceOver on it.
  This holds for a table a Mac chose too: a value such as "mac:fr-bfu-g2.ctb" marks the iPhone's French row, and the Braille code row's value says its language.
- A table that only writes braille is not in the list (see Tables that only write braille, below).
- Choosing a table sets it at once and closes the list.
  Cancel closes the list and leaves the choice as it was.
- The choice applies to the books you add from then on.
  A book keeps the table it was added with.
  The test log line that begins BRAILLE_COUNTS says how many tables and languages the list offers.

"Braille file characters" opens a list of the characters a BRF or BRL file may be read with, the two seven-bit codes the Mac's pop-up offers.

The Mac's tab has more, and the iPhone's section leaves it out:

- the Language and Contraction pop-ups, which the one list replaces;
- the sentence under the pop-ups that says where the table comes from, except the one for a table that only writes braille, and the captions the Mac's tab puts under the file characters pop-up and the guess switch;
- this Mac's VoiceOver tables, their check, and their refusals, since an iPhone has no such tables.

A table the iPhone's pack lacks is not on the iPhone at all: a book that needs one of a Mac's own tables is refused (see [What TextMouth reads](reads-daisy-and-braille.md)).
The captions of the Braille section wrap onto as many lines as their words need at any text size.

## This Mac's braille tables
<!-- id: this-mac-braille-tables; keys: VoiceOver braille tables, mac: tables, BrailleTables folder, LiblouisBrailleTranslator, 26.3, eight-dot; src: TextMouth/Models/BrailleTableCatalog.swift, TextMouth/Models/BrailleTableOrigin.swift, TextMouth/Services/MacBrailleTableCheck.swift, TextMouth/Services/BrailleTranslator.swift, TextMouthProductionTests/BrailleTablePrintOnlyTests.swift -->

This Mac's braille tables, in the Braille tab and in Export's braille options, are VoiceOver's own, and they add the languages and codes beyond TextMouth's four English tables.

- Where they come from: VoiceOver's liblouis tables, in /System/Library/ScreenReader/BrailleTables/LiblouisBrailleTranslator.brailletable, in its Contents/Resources/liblouis/tables folder; they are liblouis 3.34.0 on macOS 26.3.
  TextMouth reads them where they are and never copies, changes, or downloads them, so the app does not grow.
  The Mac app carries only its four English tables, since VoiceOver's folder holds the others.
  A Mac without that folder offers TextMouth's own tables alone, with no error.
- When they are read: TextMouth reads the tables' headers once, at launch, in the background, so the pop-ups, Export, and Book Info find them ready.
- Which are offered for reading: literary tables only.
  Never one that states it is eight-dot (one that states nothing is offered, and its check, below, decides), never a table that only includes another table offered in the same language, and never a table that only writes braille (see Tables that only write braille, below).
  Where this Mac has a file named like one of TextMouth's four, only TextMouth's is listed.
  The test log line that begins BRAILLE_COUNTS says how many tables and languages this Mac offers for reading and for export.
- Left out: a VoiceOver table that does nothing but include files its folder lacks, since it could never load.
  Apple left out some of the files that a few tables include, so on macOS 26.3 Icelandic (is.tbl), Portuguese (pt.tbl), and Serbian (sr.tbl) are not listed.
- Listed, but refused when chosen: on macOS 26.3 the tables of Greek, Hungarian, and Cantonese.
- The check: TextMouth checks a Mac table the first time it is chosen in a session, off the main thread, so nothing waits; the pop-ups show the table chosen until the check ends.
  TextMouth's braille helper loads the table, translates a sample of letters, digits, and typographic punctuation to braille and back, and measures its memory and speed.
  A table is refused when it does not load, when it needs more than 64 MB of memory, or when it translates more slowly than 50 KB a second (20 seconds for each MB), and a table that does not state that it is six-dot is refused when its braille for the sample holds eight-dot cells.
  A table that passes runs with limits made for it (see [Where TextMouth keeps your library](helper-programs.md)).
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
  Choose it again to retry."
  The reason after the colon is "the braille helper failed", "TextMouth could not make a folder to check it in", or "the braille helper was stopped because" and the watchdog's reason, in the words listed in [Adding books](adding-books.md).
  At an import or an export the sentence is "TextMouth could not check this Mac's braille table “mac:el.ctb”: the braille helper failed.
  Try again."

## Tables that only write braille
<!-- id: tables-only-write-braille; keys: print-only, direction forward, export only, Czech, Latvian, Slovenian, Chinese, liblouis 3.39.0; src: TextMouth/Models/BrailleTableCatalog.swift, TextMouth/Views/Settings/BrailleSettingsView.swift, TextMouth/Views/Export/BrailleExportOptionsView.swift, TextMouthProductionTests/BrailleTablePrintOnlyTests.swift -->

Some of liblouis's tables write braille from print and cannot read a braille file back, which reading a braille book needs.
They are marked "direction: forward" in the table; German, Czech, Latvian, Slovenian, Chinese, Korean, Thai, Vietnamese, Hebrew, and Persian have such tables.

- Exporting braille offers them (see [Exporting braille files](exporting-braille.md)).
  Reading never does: not the Braille tab, not Book Information's Braille Code pop-up, not Replace Existing, and not an import.
  The iPhone has no Export dialog yet, so its list offers them nowhere; its pack carries them.
- The Mac judges each of VoiceOver's tables by the newer liblouis.
  When VoiceOver's liblouis is older than TextMouth's, 3.39.0, or names no version, or a version that is not a number, a table is print-only when either marks it so.
  VoiceOver's older copies of cs.tbl, lv.tbl, sl.tbl, and zh_CHN.tbl lack the mark that 3.39.0 gives them, and so does a table that only includes one, such as zh_TW.tbl.
  When VoiceOver's liblouis is newer, VoiceOver's own tables decide.
  The Mac offers a print-only table for export and not for reading.
- Nothing in use breaks.
  A book already read with such a table keeps its text and its stored value, and so does a setting that names one.
  They are only left out of the choices you make from now on.
- When the table chosen in the Braille tab is one of them, the pop-ups show the first language and code in their lists, and the sentence under them reads "The chosen table only writes braille, so it is not offered for reading braille files; choose another."
