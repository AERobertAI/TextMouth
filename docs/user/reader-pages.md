# Pages in a reader
<!-- id: reader-pages-page; keys: page numbers, page labels, printed page, page break, PageBreak; src: TextMouth/Models/BookPages.swift, TextMouth/Models/ReaderPageWording.swift, TextMouth/ViewModels/ReaderViewModel+Pages.swift -->

Part of [TextMouth's documentation](../../README.md).

The reader window itself, its menus, and search are in [Reader windows](reader-windows.md).

## Pages
<!-- id: reader-pages; keys: page labels, roman numerals, printed page numbers, PageBreak, page list; src: TextMouth/Models/BookPages.swift, TextMouth/Models/PageReaderVersions.swift -->

Pages: a book can have pages, numbered as its source numbers them, such as 12, xii, or A-3 ([What TextMouth reads](reads-pages-and-limits.md) says which books have them).
A page is a place in the book's text and adds no words: nothing is read aloud for a page, and moving by page moves no saved place.
A page begins at its first whole word.

## A page break inside a heading
<!-- id: reader-page-break-inside-heading; keys: pagebreak, epub:type, page-list, Part 9Two, heading text; src: TextMouth/Models/PageReaderVersions.swift, TextMouth/Parsers/HTMLReadingText.swift -->

In an EPUB or HTML book, the number of a page break inside a heading is no part of the heading, as it is no part of the text.
A heading written "Part 9Two", with the page break's number between the words, is the heading "Part Two" in the text, in Show Headings, and for Next Heading, and page 9 begins where the heading does.

## Page as a navigation unit
<!-- id: reader-page-as-navigation-unit; keys: SkipUnit, skip unit, navigation unit, cycle units, one page; src: TextMouth/ViewModels/ReaderViewModel+Pages.swift, TextMouth/ViewModels/SettingsViewModel.swift, TextMouth/Models/ReaderPageWording.swift -->

Page is a navigation unit, between Paragraph and Heading in the list of units.
With Page chosen, Skip Forward and Skip Backward move by page, and Cycle Forward Navigation Unit and Cycle Backward Navigation Unit stop at it.
A book without pages has none to move by: the cycle passes Page over there, and Skip Forward or Skip Backward with Page chosen says "This book has no pages." and moves nothing.
Neither has a book of only one page, which has no other page to go to: there the pickers leave Page out, and a skip by Page says "This book has only one page." and moves nothing.

## Navigation unit pickers in a book without pages
<!-- id: reader-navigation-unit-pickers-book-without; keys: navigationUnitChoices, skip unit pickers, Playback tab, playback bar; src: TextMouth/ViewModels/ReaderViewModel+Pages.swift, TextMouth/Views/Reader/PlaybackControlsView.swift -->

For a book without pages, the playback bar's navigation unit pickers, the one VoiceOver calls Navigation unit or the two called Forward navigation unit and Backward navigation unit, leave Page out of their lists.
The exception is Page when it is the unit in force: it stays in the list so that the picker shows its value.
The four skip unit pickers in the Playback tab of Settings (see [Settings](settings.md)) list Page for every book.

## Skip by page
<!-- id: reader-skip-page; keys: nextPage, previousPage, Return button, previous reading position; src: TextMouth/ViewModels/ReaderViewModel+Pages.swift, TextMouth/Models/BookPages.swift, TextMouth/Models/ReaderPageWording.swift -->

With Page chosen, Skip Forward moves to the start of the next page and says its label, as in "Page 13", and Skip Backward moves to the start of the page being read, or to the start of the one before it when the reading position is within 10 characters of that start, and says its label.
On the last page Skip Forward does nothing, and at the start of the first page, or before it, Skip Backward does nothing.
Pages that begin at one place are one stop, and the label said is the last of them.
A page that begins in a section you skip, or after the book's last word, is passed over.
Each move keeps the place it began at for the toolbar's Return button, which VoiceOver calls "Return to previous reading position".

## Go to Page
<!-- id: reader-go-page; keys: goToPage, jump to page, page panel, repeated label, goToPageLabelIsRepeated; src: TextMouth/ViewModels/ReaderViewModel+Pages.swift, TextMouth/Models/ReaderPageWording.swift, TextMouth/Views/Reader/ReaderJumpPanels.swift, TextMouth/Models/KeyboardShortcut.swift -->

Go to Page… (Option-Command-G) opens a panel below the status row with one field, labelled "Page", whose hint says how many pages the book has and what to type, as in "This book has 300 pages, from i to 300.
Type a page as the book numbers it, such as 12 or xii."
(a book of one page names it: "This book's only page is 1.")
The field starts at the label of the page being read, empty before the first page, and has the keyboard.
Return, or Jump, goes to the start of the page typed and says "Jumped to page 12."; Escape, or Cancel, closes the panel.
Capitals and spaces around the page don't matter: "XII" is page xii.
A label that more than one page has, such as "2" on the plates and in the text, goes to the first such page after the page being read, or to the first in the book when none comes after it, and the jump says which of them it reached, counting from the first in book order:

- "Jumped to page 2, the second page labelled 2.", or
- "Jumped to page 2, the first page labelled 2." after the wrap.

The count is in words up to the tenth and in figures after, as in "the 11th page labelled 2".
Return while the field still holds the label it started at closes the panel, leaving the place where it is and saying nothing, unless another page of the book carries that label too.
Then Return goes to that label's next page, and after the last page that carries it, to the first, so Return on the starting label steps through the pages of a repeated label.

## Where Go to Page puts the cursor
<!-- id: reader-where-go-page-puts-cursor; keys: jumpAnnouncement, page has no words, skipped section, cursor is on page; src: TextMouth/Models/ReaderPageWording.swift, TextMouth/ViewModels/ReaderViewModel+Pages.swift -->

When the cursor does not land on the page asked for, Go to Page says where it is, and why when the book's pages say, in place of "Jumped to page 7.", so that its words agree with the status row:

- A page with no words of its own, which begins where the page after it does: "Page 7 has no words, so the cursor is on page 8."
  A last page that begins after the book's last word is reached at that word, on the page before it: "Page 9 has no words, so the cursor is on page 8."
  When no page comes before, as in a book whose only page begins after its last word, the cursor is before the page: "Page 1 has no words, so the cursor is before page 1."
- A page whose every word is in a skipped section, when the book is playing, since speech goes on with the next words it reads: "Page 40 is in a skipped section, so the cursor is on page 52."
  With the book stopped, the cursor stays on such a page, as on any other, and the jump says "Jumped to page 40."
- No reason in the pages, as when a text substitution deletes every word of the page: "The cursor is on page 52."
- A page of a label that other pages carry too is named as which of them it is, and so is the page the cursor is on, as in:
  - "The first page labelled 3 has no words, so the cursor is on the second page labelled 3.",
  - "Page 5 has no words, so the cursor is on the second page labelled 2.",
  - "The second page labelled 2 has no words, so the cursor is on page 3.", and
  - "The second page labelled 2 is in a skipped section, so the cursor is on page 3."

- A skip by Page says the label of the page the cursor reaches, as before.

## Go to Page refuses what is not a page
<!-- id: reader-go-page-refuses-what-not; keys: invalid page, page not found, Type a page number, typed page; src: TextMouth/Models/ReaderPageWording.swift, TextMouth/ViewModels/ReaderViewModel+Pages.swift -->

Go to Page… refuses what is not a page, under the field and aloud, and leaves the panel open: "Type a page number." for an empty field; "There is no page 400 in this book.
Its pages run from i to 300." for a page the book does not have; and, for a book of one page, "There is no page 400 in this book.
Its only page is 1."

## Go to Page in a book without pages
<!-- id: reader-go-page-book-without-pages; keys: pageCommandHasPages, dimmed, disabled menu item, one page, still loading; src: TextMouth/ViewModels/ReaderViewModel+Pages.swift, TextMouth/App/MenuCommands.swift, TextMouth/Models/ReaderPageWording.swift -->

In a book without pages, the Navigate menu dims Go to Page…, and its key says "This book has no pages." and does nothing.
In a book of only one page the menu dims it too, its key says "This book has only one page." and does nothing, and Where Am I? leaves the page out.
While a book is still loading, Go to Page… and Skip Forward or Skip Backward with Page chosen do nothing and say nothing, since the book may have pages.

## The page button in the status row
<!-- id: reader-page-button-status-row; keys: page button, Page 12 of 300, pageButtonHint, status row, showsPageInReader; src: TextMouth/Models/ReaderPageWording.swift, TextMouth/Views/Reader/ReaderView.swift, TextMouth/Views/Reader/ReaderJumpPanels.swift, TextMouth/Models/BookPages.swift -->

The status row has a button beside the percent that shows the page being read, as in "Page 12 of 300", or "Before page i" before the first page; VoiceOver reads the same words as its label.
The N of "of N" is the largest page label that is a whole number, so a book numbered i to xiv and then 1 to 300 says "of 300", and a book with no such label counts its pages.
Pressing the button opens Go to Page's panel, and its hint says what a press does: "Opens jump to page controls", "Hides jump to page controls" while that panel is open, and "Switches to jump to page controls" while the percent or time panel is.
The button is drawn in a book of more than one page while "Show the page on the reader screen" is on (see [Settings](settings.md)), since a book of one page would say "Page 1 of 1" wherever you are; Go to Page… opens the panel either way.
A page the book names "Page 12" is page 12, so the button never says "Page Page 12".

## Where Am I? and the page
<!-- id: reader-where-am-i-page; keys: Where Am I, Full Summary, Before page, summary, saysPageInWhereAmI; src: TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift, TextMouth/Models/ReaderPageWording.swift, TextMouth/Models/BookPages.swift -->

Where Am I? says the page right after the heading number, as in "Dune.
The Battle.
Heading 26 of 412.
Page 112 of 300.
30 percent.
3 hours remaining."; Where Am I?
Full Summary says it in the same place, and before the first page both say "Before page" and its label, as in "Before page i".
"Say the page in Where Am I?"
(see [Settings](settings.md)) turns it off.
