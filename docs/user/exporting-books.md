# Exporting books
<!-- id: exporting-books; keys: ; src: -->

Part of [TextMouth's documentation](../../README.md).

## What the Export dialog lists
<!-- id: what-export-dialog-lists; keys: ; src: -->

The Export dialog lists what the books hold: a checkbox for each kind, labelled with its size and with its number of files when there are several, or, for several books, with how many of them hold it, as in "Original file, 1.2 MB", "Audio, 12 files, 340 MB", or "Audio, 2 books, 680 MB".
The kinds are
- Audio, an audiobook's file or its tracks;
- Original file, a text book's own file (an .rtfd, which is a folder, is copied whole, and its size is that of the files inside it) or,
  - for an audiobook whose import kept the originals of the audio it converted (Keep originals of converted audio, under [Settings](settings.md)), those files as they were before:
    - one file under its own name, or, for a book of tracks, a folder named like "Moby-Dick - Original Files", each original under its path inside the book's folder of tracks;
- Text as Markdown, the book's text with its headings, lists, and emphasis (the Convert to menu, below, can make it HTML, RTF, a Word document, or braille instead);
- Text as plain text, each chapter's words under its title, before any substitution rules;
- Original recording, a recording as it was made, before any edits;
- Original audio (before edits), an edited audiobook's audio as it was before its first edit, which TextMouth keeps while the Original audio setting does:
  - one file named after the book, as in "Moby-Dick - Original Audio.mp3", or, for a book of tracks, the edited tracks' originals in a folder of that name;
- and Transcript, its transcript.json, copied as it is, and, for an audiobook, the transcript's text as Markdown, written as Text as Markdown is (below).

Kinds that none of the books hold aren't listed.
VoiceOver starts on the first checkbox, and the first kind that can be exported is checked.

## Where the files go
<!-- id: where-files-go; keys: ; src: -->

The files go to your Documents folder, or to the folder you last exported to since TextMouth opened.
Choose Folder… chooses another, and its New Folder button makes one; TextMouth's own data directory is refused.
One book's items go straight into the folder, except its tracks, or a DAISY book's loose files, which go into a folder named after the book: tracks are numbered in the order the book plays them and named for their chapters, as in "01 - The Harbour.mp3".
Several books get a folder each.
A name already in use gets a number, as in "Moby-Dick - Text 2.md", so nothing is ever replaced.
Each file, whether copied, plain text, or converted, is made first in a scratch folder, on the same disk as the folder you chose when the Mac provides one there, and moved into that folder only once it is whole, never over a file that is already there.
So an export never replaces or removes a file that was already in the folder, and the folder never holds a half-written file, even after Stop or a failure.

## Export, Cancel, and Stop
<!-- id: export-cancel-stop; keys: ; src: -->

Return presses Export, and Escape presses Cancel, or Stop while the export runs, which ends the export: the files finished so far stay in the folder, and the file being made is not kept.
VoiceOver reads Export's hint as "Exports the checked items to the folder." and Stop's as "Stops the export.
The file being made is not kept."
A progress bar says how far it has got, as in "Exporting 3 of 40 items…"; it counts finished files, so it does not move while one long book is converted.
At the end VoiceOver says how it went, as in "Exported 3 items to Documents.", and the dialog closes, unless the export was stopped or left something out: then it stays open, saying what couldn't be exported and why, and Cancel becomes Close.

## Books in the cloud
<!-- id: books-cloud; keys: ; src: -->

Nothing is downloaded.
In a library in the cloud, a kind whose files are only in the cloud says "in the cloud" and can't be checked, and the books it leaves out are named, as in "Moby-Dick isn't downloaded.
Download it first: select it in the library, then choose Download Now."

## Converting a book's text
<!-- id: converting-book-text; keys: ; src: -->

### The Convert to pop-up
<!-- id: convert-pop-up; keys: ; src: -->

While Text as Markdown is checked, a pop-up named "Convert to" sits beside it, and VoiceOver reaches it right after the checkbox.
Its label is "Convert to", its value is the choice made, and its hint is that choice's hint.
The choices are Markdown, HTML, RTF, "Word 97-2003 (.doc)", EPUB, BRF, and PEF, and their hints are:

- Markdown: "The book's text as Markdown, with its headings, lists, and emphasis."
  The Text as Markdown checkbox has the same hint while Markdown is chosen.
- HTML: "A web page of the book's text, with a contents list linking each heading."
- RTF: "Rich text, with each heading at its outline level, for Word, Pages, and TextEdit."
- Word 97-2003 (.doc): "Word 97-2003 document.
  Its headings are plain text, so Word's navigation pane does not list them."
- EPUB: "An e-book with the book's headings, contents, and page numbers where it has them, for Apple Books and other reading apps.
  It holds no pictures."
- BRF: "Braille Ready Format: pages of braille, for braille displays and embossers."
- PEF: "Portable Embosser Format: pages of Unicode braille in XML, for embossers."

### What a dialog starts on and keeps
<!-- id: what-dialog-starts-keeps; keys: ; src: -->

Every Export dialog starts on Markdown, so an export that leaves the menu alone gives the Markdown file, named like "Moby-Dick - Text.md", and a dialog keeps the choice made in it until it closes.
Only a text book's Text as Markdown checkbox has the menu: an audiobook's Transcript has none, and gives its transcript.json byte for byte and its text as Markdown.

### The checkbox's name when a format is chosen
<!-- id: checkbox-name-when-format-chosen; keys: ; src: -->

While HTML, RTF, Word, EPUB, BRF, or PEF is chosen, the checkbox is named for the choice, as in "Text as HTML" or "Text as Word 97-2003 (.doc)", and "Text as HTML, 2 books" for several books.
It then gives no size, since a converted file's size is known only once it is written; with Markdown chosen it keeps its size.
Its hint is "The book's text as HTML, made from the Markdown TextMouth reads it from.", with RTF, Word 97-2003 (.doc), EPUB, BRF, or PEF in place of HTML.

### File names of converted text
<!-- id: file-names-converted-text; keys: ; src: -->

Each book gets its own file, named like the Markdown's but with the format's ending, as in
- "Moby-Dick - Text.html",
- "Moby-Dick - Text.rtf",
- "Moby-Dick - Text.doc",
- "Moby-Dick - Text.epub",
- "Moby-Dick - Text.brf",
- or "Moby-Dick - Text.pef",
- and numbered when the name is in use, as in "Moby-Dick - Text 2.html".

### Converting several books
<!-- id: converting-several-books; keys: ; src: -->

TextMouth converts the books one at a time, and the dialog's progress bar and Stop work as in any export.
Stop ends a braille export at once, even while its translation runs.
A book that cannot be converted is named in the sentence VoiceOver says at the end, with why, and the other books still export.
When Word's writer cannot make a book, the sentence is "Couldn't export Moby-Dick - Text.doc: The book's text could not be made into a Word 97-2003 document."
When the braille translation fails, the sentence is the translator's, as in "Couldn't export Moby-Dick - Text.brf: TextMouth could not translate this braille."
(see [Adding books](adding-books.md) for its other sentences).

## What a converted file holds
<!-- id: what-converted-file-holds; keys: ; src: -->

### Where the text comes from
<!-- id: where-text-comes-from; keys: ; src: -->

The text is the book's content.md, the Markdown TextMouth reads, with any edits you made in Edit Text (see [Editing a book's text](editing-book-text.md)), before any substitution rules.
Markdown stays the base: Markdown, HTML, RTF, Word 97-2003, EPUB, BRF, and PEF are each written from it, none copied.

### What every format leaves out
<!-- id: what-every-format-leaves-out; keys: ; src: -->

Markdown, HTML, RTF, Word 97-2003, EPUB, BRF, and PEF all leave out content.md's chapter-marker lines (an EPUB uses them to make its chapters, and its page lines to make its pages), its page lines, its navigation annotations, and any raw HTML, and a picture becomes its alternative text.

### Headings and the book's title
<!-- id: headings-book-title; keys: ; src: -->

A chapter with no heading of its own gets its title as a level-1 heading, as the reader's heading list shows it.
The book's title becomes a level-1 heading, written first, only when the text has no level-1 heading, and never in the Markdown.

### Titles, authors, and links
<!-- id: titles-authors-links; keys: ; src: -->

Each file but a BRF and the Markdown carries the book's title, and its author when the library has one (a BRF has no place for them, and the Markdown is only the book's text).
In Markdown, HTML, RTF, and EPUB, only http, https, and mailto addresses become links; any other link is plain text.
An EPUB writes the address so that an EPUB checker accepts it (a character outside ASCII is percent-encoded), and a link it cannot write that way, one with a port past 65535, say, or a host with letters outside ASCII, is written as its words alone.

### How Markdown is written
<!-- id: how-markdown-written; keys: ; src: -->

Markdown is written from the walk of content.md, not copied from it: headings, paragraphs, lists, quotes, code, tables, and web and mail links, with emphasis and strong emphasis kept.
It has a backslash only where Markdown needs one:
- before `*`, `` ` ``, `[`, `]`, `|`, `~`, and `<`,
- before an underscore outside a word, an ampersand that would begin a character reference, a number sign that would close a heading, and a backslash that precedes punctuation or ends a line,
- and before the first character of a line that would begin a heading, a list, a quote, or a numbered item.

A comma, period, colon, question mark, quotation mark, or apostrophe has none, so a sentence stands in the file as it reads, where content.md may put a backslash before each of them.
The Transcript's Markdown is written the same way.

### HTML
<!-- id: html; keys: ; src: -->

HTML is a web page (XHTML), and it carries the book's language when the book has one.
When the text has headings, the page has a contents list, a navigation landmark named "Contents", that links each heading; the list leaves out the book's own title heading.
A book that skips heading levels (a level 1, then 3, then 2) has one nested list for them, the 3 and the 2 beside each other under the 1.
The page carries the book's language only when it is a well-formed language tag, and so do the PEF and EPUB files.

### RTF
<!-- id: rtf; keys: ; src: -->

RTF headings are bold and larger, from 22 point at level 1 down to 13 point at level 6, and carry outline levels, so TextMouth reads them back as headings at the same levels.
A list is a run of paragraphs, each starting with a bullet or a number and a tab.
A table of more than 63 columns becomes a paragraph for each row, its cells apart by tabs.

### Word 97-2003 (.doc)
<!-- id: word-97-2003-doc; keys: ; src: -->

Word 97-2003 (.doc) is made by Apple's writer from TextMouth's RTF, so it holds the same text.
Its headings are larger and bold but plain text, so Word's navigation pane does not list them.
It loses six rare characters that the RTF keeps: the bidirectional embedding and override controls U+202A to U+202E, and U+FFFD, which becomes "?".

### How an EPUB is made
<!-- id: how-epub-made; keys: ; src: -->

EPUB is an EPUB 3 e-book, made by TextMouth's own writer from the same walk of content.md that the other converted formats are written from, with the chapters and the pages kept as well as the words (see EPUB 3, below).
It is written for a reader who navigates by headings and pages, and states only what is true of the file.

## EPUB 3
<!-- id: epub-3; keys: ; src: -->

### Files in an EPUB package
<!-- id: files-epub-package; keys: ; src: -->

The package holds, in the order the ZIP does, `mimetype` (stored, first), the container file, a file of XHTML for each chapter, the navigation document (`nav.xhtml`), and the package document (`content.opf`).
A chapter that passes about 256,000 bytes goes on in another file, which begins where a heading does once the first is past that size, or after four times as much where there is none.

### The navigation document
<!-- id: navigation-document; keys: ; src: -->

The navigation document has a contents list (a navigation landmark named "Contents") nested by the headings' levels, which links
- every heading, every chapter, and every place the book's own contents point at,
- and, for a book with pages, a page list (named "Pages", hidden from the page as EPUB intends) that links every page and is read by the reading system's page navigation.

A page whose label would be empty is named by its number.

### Headings in an EPUB
<!-- id: headings-epub; keys: ; src: -->

A heading is a real heading at its level.
A chapter that begins with words before any heading gets a contents entry named for the chapter, or the book, and no heading added;
- a chapter with a title and no blocks leaves the contents,
- and a heading made only of characters XML forbids, or of zero-width ones, is written as a target with no heading and listed as "Untitled".

An empty book is one empty chapter, which is valid, though TextMouth's own reader says it has nothing to read.

### The package document
<!-- id: package-document; keys: ; src: -->

The package document names
- the book's identifier (its library identity, so exporting a book twice gives one identifier), title, and author,
- its language where the book has one ("und", undetermined, where it does not, and then the chapters carry no language and each block takes its direction from its words),
- and the date of the export.

A book in a right-to-left language or script, such as Hebrew, Arabic, Persian, Urdu, or a language written in Arabic letters, gets right-to-left text and page progression.
The accessibility metadata says
- textual, sufficient as text, no hazards,
- a table of contents and a reading order always,
- structural navigation only when the book has headings of its own,
- and page navigation and page break markers only when it has pages,
- with a summary in plain words, as in "This book was exported from TextMouth as text only.
  Its headings are real headings, and the contents list links them.
  It has a page list, and the start of each page is marked in the text.
  It has no pictures, sound, or video, and the text of a picture's description is kept as text."

It claims conformance to no standard.

### What an EPUB leaves out
<!-- id: what-epub-leaves-out; keys: ; src: -->

It holds no pictures (their alternative text stays as text), styles, raw HTML, heading annotations as headings, or cover, and no character that XML forbids.
A page that begins in a table cell stays in the cell; a contents place in a cell moves to just before the table.

### Checking the EPUB file as it is written
<!-- id: checking-epub-file-as-it; keys: ; src: -->

The file is written to a scratch file and opened again before it is moved into place: every part must read back whole with the checksum the ZIP stores for it, else the file is removed and the export fails with "The EPUB file could not be written."
A failed write says "The EPUB file could not be written, because the disk may be full.", or, for a volume that is read-only or a permission that is missing, "The EPUB file could not be written: " and the system's words.

### What an EPUB reads back as
<!-- id: what-epub-reads-back-as; keys: ; src: -->

What an EPUB reads back as, when TextMouth imports its own export: the words, the pages with the same word before each, and the headings at the same levels are the same.
These differ:
- a contents place that is not a heading reads back as a heading row at its depth in the contents, not at its level;
- one in a table cell reads back a few words early;
- of several chapters that hold only page markers, only the first title is kept;
- and a chapter that begins with words, or a long book with no headings that was split into files, gains heading rows (named for the chapter or the book, then "Chapter 2", "Chapter 3", and so on).
