# Exporting braille files
<!-- id: export-braille-files; keys: BRF, PEF, liblouis, embosser, braille display; src: TextMouth/Services/Export/BrailleExportWriters.swift, TextMouth/Views/Export/BrailleExportOptionsView.swift -->

Part of [TextMouth's documentation](../../README.md).

## BRF and PEF
<!-- id: export-brf-pef; keys: BANA Braille Formats 2016, six-dot, North American Braille ASCII, form feed, Unicode braille; src: TextMouth/Services/Export/BrailleExportWriters.swift -->

BRF and PEF translate the book's text to braille with liblouis, in the language, code, and contraction of the options below, and lay it out in pages as BANA's Braille Formats (2016) says.
Both hold six-dot cells only.
A BRF writes each cell as a character, North American Braille ASCII unless you choose other braille file characters below, with a form feed between its pages, for braille displays and embossers.
A PEF is XML that holds the same pages as Unicode braille, for embossers; its head names the book's title, its author when the library has one, its language (English when the book names none), a unique identifier, and the date it was made.

## The braille options
<!-- id: export-braille-options; keys: Cells per line, Lines per page, Line ends, Braille file characters, CR LF, stepper; src: TextMouth/Views/Export/BrailleExportOptionsView.swift, TextMouth/Models/BookExportWording.swift -->

While BRF or PEF is chosen, options sit under the Convert to pop-up (see [Exporting books](exporting-books.md)), in the order below.
They start from the Braille setting (see [Settings](settings-braille.md)), at 40 cells by 25 lines with page numbers on and, for a BRF, CR LF line ends and the braille file characters of the Braille tab.
The dialog keeps them until it closes, and they are dimmed while an export runs.
Each is read as its label, its value, and its hint:

- "Language", with the values of the Braille tab and of the tables that only write braille (see Pop-ups from the Braille tab, below).
  Its hint is "The language of the braille code the book is written in."
- "Braille code", with the values of the Braille tab and of the tables that only write braille (see Pop-ups from the Braille tab, below).
  Its hint is "The braille code the book is written in."
- "Contraction", with the values of the Braille tab and of the tables that only write braille (see Pop-ups from the Braille tab, below).
  Its hint is "Whether that code's braille is contracted."
- "Cells per line", a stepper from 18 to 80, with a value such as "40 cells".
  Its hint is "How many braille cells each line holds, from 18 to 80."
- "Lines per page", a stepper from 4 to 50, with a value such as "25 lines".
  Its hint is "How many lines each braille page holds, from 4 to 50."
- "Braille page numbers", a checkbox.
  Its hint is "Whether each page's last line carries its braille page number."
- "Line ends", for BRF only, a pop-up with "CR LF" and "LF".
  Its hint is "CR LF suits most braille displays and embossers."
  A PEF always ends a row with a line feed.
- "Braille file characters", for BRF only, after "Line ends", a pop-up that chooses how the file writes each braille cell as a character:
  - "North American Braille ASCII",
  - "Eurobraille, six-dot (German-speaking countries)",
  - or "Unicode braille patterns", starting from the Braille tab's choice (Unicode braille patterns is never that choice).
  Its hint is "How the BRF writes each braille cell.
  Most braille displays and embossers read North American Braille ASCII; those set up for German read Eurobraille.
  To share with a reader elsewhere, export a PEF."
  VoiceOver says its value first, as in "North American Braille ASCII, Braille file characters, pop-up button".
  A PEF always holds Unicode braille, so it has no such choice.

## Pop-ups from the Braille tab
<!-- id: export-braille-tab-pop-ups; keys: Mac tables, table check, refusal, print-only tables, direction forward; src: TextMouth/Views/Export/BrailleExportOptionsView.swift, TextMouth/Models/BrailleTableCatalog.swift, TextMouthProductionTests/BrailleTablePrintOnlyTests.swift -->

The three pop-ups are the Braille tab's own, so they offer this Mac's tables too, check a Mac table the first time it is chosen, and speak a refusal as the Braille tab does (see [Settings](settings-braille.md)).
They offer more than the Braille tab does: the tables that only write braille.
An export only ever writes braille, so it can use them, and they are one more choice in the Export dialog alone.

- Which tables: the Mac app's own four English tables, VoiceOver's tables on this Mac, and the tables of VoiceOver's that only write braille, which the Mac judges by the newer liblouis (see Tables that only write braille, in [Settings](settings-braille.md)).
  When one of them would be listed with the same words as a table that reads back, only the one that reads back is listed.
- Their names say nothing of direction: a table that only writes braille is named as the others are, by its code, its contraction, and its language.
- The options start from the Braille tab's choice.
  When that choice is one of these tables, the pop-ups show it, and an export writes with it.
  A table an iPhone chose, whose name has no "mac:" in front, such as fr-bfu-g2.ctb, shows as this Mac's table of that name, and the export writes with it.
- The iPhone's Export sheet offers them too: its pack carries print-only tables, German, Chinese, Korean, Czech, Thai, Vietnamese, Hebrew, and Persian among them (see [Exporting on the iPhone](exporting-on-iphone.md)).

## When the Settings table can't be used
<!-- id: export-braille-table-unusable; keys: Unified English Braille, Grade 2, fallback table, display name; src: TextMouth/Views/Export/BrailleExportOptionsView.swift -->

When the table chosen in Settings cannot be used here, the options start from Unified English Braille, contracted (Grade 2), and say so under the pop-ups until you choose another table:

"TextMouth can't use the braille table chosen in Settings, “French braille”, so this export starts from Unified English Braille, contracted (Grade 2)."
The table cannot be used when this Mac no longer has it, when it is this Mac's copy of one of TextMouth's own four tables, or when a check earlier in the session refused it, but not as too slow, or because it could not run, which the next check measures again.
The sentence names the table by its display name, or by its file name when this Mac does not offer it.

## Export while a table is being checked
<!-- id: export-while-table-being-checked; keys: Export hint, table check wait, Stop; src: TextMouth/Views/Export/BrailleExportOptionsView.swift, TextMouth/ViewModels/BookExportModel.swift -->

An export started while a table just chosen here is being checked waits for the check, and Stop is offered meanwhile: Stop, or closing the dialog, ends the export before it writes anything.
While the check runs, the Export button's hint is "Exports the checked items once the braille table just chosen is checked."
The export then writes with the table the pop-ups show once the check has passed, or the one they went back to.

## Eight-dot braille characters
<!-- id: export-eight-dot-braille; keys: eight-dot cell, six-dot, @ sign, email address; src: TextMouth/Services/Export/BrailleExportWriters.swift -->

Eight-dot braille characters already in a book's text are written as their six-dot part.
A table that writes an ordinary character as an eight-dot cell fails that book's export, naming the character, as in "Couldn't export Moby-Dick - Text.brf: The braille table writes “«” as an eight-dot cell, but TextMouth's BRF and PEF files are six-dot only."
When no one character is to blame, the sentence names the cell's dots.
Some tables write @ in eight-dot computer braille, so a book holding an e-mail address fails to export with them; the other books export.

## The braille layout
<!-- id: export-braille-layout; keys: heading cells, paragraph indent, list indent, page number, blank lines; src: TextMouth/Services/Export/BrailleExportWriters.swift -->

The layout:

- Headings 1 and 2 are centered, with a blank line before and after.
  Heading 3 starts at cell 5, and headings 4 to 6 at cell 7, each with a blank line before.
  A heading is never the last text on a page, unless it ends the book.
- A paragraph starts in cell 3 and runs over in cell 1.
- A list item starts in cell 1 and runs over in cell 3, and each level of a nested list starts two cells further in.
  A blank line comes before a list and after it, and none between its items; a list right after a heading in cell 5 or 7 has none before it.
  An item that runs over starts on a page with room for its first two lines.
  An ordered list's items begin with their number and a period.
- When "Braille page numbers" is checked, a page's last line carries its braille page number at the right, so a page holds one line of text fewer than "Lines per page" says.

## Quotes, code, tables, and links in braille
<!-- id: export-braille-blocks; keys: quote, code block, table rows, thematic break, link text; src: TextMouth/Services/Export/BrailleExportWriters.swift -->

A quote is written as the text of its blocks, a code block as a paragraph for each of its lines that has text, and a table as a paragraph for each row, its cells apart by semicolons.
A thematic break writes nothing.
The address of a link is not written, only its text.
Italic and bold are written as emphasis, as the next section says, except in a table's cells, a code block, a numbered item's number, and the book's title, which are plain.

## Italic and bold in braille
<!-- id: export-braille-emphasis; keys: emphasis signs, UEB, EBAE, sample test, byte for byte; src: TextMouth/Services/Export/BrailleExportWriters.swift; status: incomplete; issues: DR11 -->

Italic and bold in the book's text are written as the braille code's emphasis signs, where the table carries them.
TextMouth's braille helper tests each table it uses, by writing a sample with each kind of emphasis and reading it back, and a table whose signs do not read back exactly as written writes plain braille.
Unified English Braille, contracted or not, carries them.
English Braille, American Edition, and most of this Mac's tables do not, since liblouis cannot read their emphasis back, so they write plain braille, and the export of a book with emphasis is then the export of the same book without it, byte for byte.
TextMouth reads UEB braille back with its emphasis, as italic and bold in the book's text, and a word before an emphasis end sign comes back whole (see [What TextMouth reads](reads-daisy-and-braille.md), which also says how EBAE braille is read).

## A character the table lacks
<!-- id: export-braille-missing-characters; keys: Chinese, Cyrillic, emoji, escape notation; src: TextMouth/Services/Export/BrailleExportWriters.swift -->

A character the table lacks, such as Chinese, Cyrillic, or an emoji, is written in liblouis's escape notation, and TextMouth reads it back as that notation.

## A word longer than a line
<!-- id: export-braille-long-words; keys: hyphen, slash, line break; src: TextMouth/Services/Export/BrailleExportWriters.swift -->

A word longer than a line is cut after a hyphen or slash where it can be, and never inside a number.
The cut adds no hyphen or continuation indicator yet.

## Reading TextMouth's braille back
<!-- id: export-braille-read-back; keys: heading levels, import of braille, levels 1 and 2; src: TextMouth/Services/Export/BrailleExportWriters.swift -->

TextMouth reads its own braille back with fewer heading levels than it wrote: levels 1 and 2 are both centered, so they read back as level 1; level 3, at cell 5, as level 2; and levels 4 to 6, at cell 7, as level 3 (see [What TextMouth reads](reads-daisy-and-braille.md)).

## Stop during a braille translation
<!-- id: export-braille-stop; keys: helper time limit, translation, Stop; src: TextMouth/Services/Export/BrailleExportWriters.swift, TextMouth/ViewModels/BookExportModel.swift -->

Stop is read before a book's translation begins and after it ends, not during it, so a Stop pressed while a long book is translated takes effect when the translation ends, at the latest at the helper's time limit (see [Where TextMouth keeps your library](helper-programs.md)).
