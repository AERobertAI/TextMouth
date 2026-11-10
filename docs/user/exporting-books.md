# Exporting books

Part of [TextMouth's documentation](../../README.md).

- The Export dialog lists what the books hold: a checkbox for each kind, labelled with its size and with its number of files when there are several, or, for several books, with how many of them hold it, as in "Original file, 1.2 MB", "Audio, 12 files, 340 MB", or "Audio, 2 books, 680 MB". The kinds are Audio, an audiobook's file or its tracks; Original file, a text book's own file (an .rtfd, which is a folder, is copied whole, and its size is that of the files inside it) or, for an audiobook whose import kept the originals of the audio it converted (Keep originals of converted audio, under [Settings](settings.md)), those files as they were before: one file under its own name, or, for a book of tracks, a folder named like "Moby-Dick - Original Files", each original under its path inside the book's folder of tracks; Text as Markdown, the book's text with its headings, lists, and emphasis (the Convert to menu, below, can make it HTML, RTF, a Word document, or braille instead); Text as plain text, each chapter's words under its title, before any substitution rules; Original recording, a recording as it was made, before any edits; Original audio (before edits), an edited audiobook's audio as it was before its first edit, which TextMouth keeps while the Original audio setting does: one file named after the book, as in "Moby-Dick - Original Audio.mp3", or, for a book of tracks, the edited tracks' originals in a folder of that name; and Transcript, its transcript.json, copied as it is, and, for an audiobook, the transcript's text as Markdown, written as Text as Markdown is (below). Kinds that none of the books hold aren't listed. VoiceOver starts on the first checkbox, and the first kind that can be exported is checked.
- The files go to your Documents folder, or to the folder you last exported to since TextMouth opened. Choose Folder… chooses another, and its New Folder button makes one; TextMouth's own data directory is refused. One book's items go straight into the folder, except its tracks, or a DAISY book's loose files, which go into a folder named after the book: tracks are numbered in the order the book plays them and named for their chapters, as in "01 - The Harbour.mp3". Several books get a folder each. A name already in use gets a number, as in "Moby-Dick - Text 2.md", so nothing is ever replaced. Each file, whether copied, plain text, or converted, is made first in a scratch folder, on the same disk as the folder you chose when the Mac provides one there, and moved into that folder only once it is whole, never over a file that is already there. So an export never replaces or removes a file that was already in the folder, and the folder never holds a half-written file, even after Stop or a failure.
- Return presses Export, and Escape presses Cancel, or Stop while the export runs, which ends the export: the files finished so far stay in the folder, and the file being made is not kept. VoiceOver reads Export's hint as "Exports the checked items to the folder." and Stop's as "Stops the export. The file being made is not kept." A progress bar says how far it has got, as in "Exporting 3 of 40 items…"; it counts finished files, so it does not move while one long book is converted. At the end VoiceOver says how it went, as in "Exported 3 items to Documents.", and the dialog closes, unless the export was stopped or left something out: then it stays open, saying what couldn't be exported and why, and Cancel becomes Close.
- Nothing is downloaded. In a library in the cloud, a kind whose files are only in the cloud says "in the cloud" and can't be checked, and the books it leaves out are named, as in "Moby-Dick isn't downloaded. Download it first: select it in the library, then choose Download Now."

## Converting a book's text

- While Text as Markdown is checked, a pop-up named "Convert to" sits beside it, and VoiceOver reaches it right after the checkbox. Its label is "Convert to", its value is the choice made, and its hint is that choice's hint. The choices are Markdown, HTML, RTF, "Word 97-2003 (.doc)", EPUB, BRF, and PEF, and their hints are:
  - Markdown: "The book's text as Markdown, with its headings, lists, and emphasis." The Text as Markdown checkbox has the same hint while Markdown is chosen.
  - HTML: "A web page of the book's text, with a contents list linking each heading."
  - RTF: "Rich text, with each heading at its outline level, for Word, Pages, and TextEdit."
  - Word 97-2003 (.doc): "Word 97-2003 document. Its headings are plain text, so Word's navigation pane does not list them."
  - EPUB: "An e-book with the book's headings, contents, and page numbers where it has them, for Apple Books and other reading apps. It holds no pictures."
  - BRF: "Braille Ready Format: pages of braille, for braille displays and embossers."
  - PEF: "Portable Embosser Format: pages of Unicode braille in XML, for embossers."
- Every Export dialog starts on Markdown, so an export made as before gives a file under the same name, and a dialog keeps the choice made in it until it closes. Only a text book's Text as Markdown checkbox has the menu: an audiobook's Transcript has none, and gives its transcript.json byte for byte and its text as Markdown.
- While HTML, RTF, Word, EPUB, BRF, or PEF is chosen, the checkbox is named for the choice, as in "Text as HTML" or "Text as Word 97-2003 (.doc)", and "Text as HTML, 2 books" for several books. It then gives no size, since a converted file's size is known only once it is written; with Markdown chosen it keeps its size, as before. Its hint is "The book's text as HTML, made from the Markdown TextMouth reads it from.", with RTF, Word 97-2003 (.doc), EPUB, BRF, or PEF in place of HTML.
- Each book gets its own file, named like the Markdown's but with the format's ending, as in "Moby-Dick - Text.html", "Moby-Dick - Text.rtf", "Moby-Dick - Text.doc", "Moby-Dick - Text.epub", "Moby-Dick - Text.brf", or "Moby-Dick - Text.pef", and numbered when the name is in use, as in "Moby-Dick - Text 2.html".
- TextMouth converts the books one at a time, and the dialog's progress bar and Stop work as in any export. Stop ends a braille export at once, even while its translation runs. A book that cannot be converted is named in the sentence VoiceOver says at the end, with why, and the other books still export. When Word's writer cannot make a book, the sentence is "Couldn't export Moby-Dick - Text.doc: The book's text could not be made into a Word 97-2003 document." When the braille translation fails, the sentence is the translator's, as in "Couldn't export Moby-Dick - Text.brf: TextMouth could not translate this braille." (see [Adding books](adding-books.md) for its other sentences).

## What a converted file holds

- The text is the book's content.md, the Markdown TextMouth reads, with any edits you made in Edit Text (see [Editing a book's text](editing-book-text.md)), before any substitution rules. Markdown stays the base: Markdown, HTML, RTF, Word 97-2003, EPUB, BRF, and PEF are each written from it, none copied.
- Markdown, HTML, RTF, Word 97-2003, EPUB, BRF, and PEF all leave out content.md's chapter-marker lines (an EPUB uses them to make its chapters, and its page lines to make its pages), its page lines, its navigation annotations, and any raw HTML, and a picture becomes its alternative text.
- A chapter with no heading of its own gets its title as a level-1 heading, as the reader's heading list shows it. The book's title becomes a level-1 heading, written first, only when the text has no level-1 heading, and never in the Markdown.
- Each file but a BRF and the Markdown carries the book's title, and its author when the library has one (a BRF has no place for them, and the Markdown is only the book's text). In Markdown, HTML, RTF, and EPUB, only http, https, and mailto addresses become links; any other link is plain text. An EPUB writes the address so that an EPUB checker accepts it (a character outside ASCII is percent-encoded), and a link it cannot write that way, one with a port past 65535, say, or a host with letters outside ASCII, is written as its words alone.
- Markdown is written from the walk of content.md, not copied from it: headings, paragraphs, lists, quotes, code, tables, and web and mail links, with emphasis and strong emphasis kept. It has a backslash only where Markdown needs one: before `*`, `` ` ``, `[`, `]`, `|`, `~`, and `<`, before an underscore outside a word, an ampersand that would begin a character reference, a number sign that would close a heading, and a backslash that precedes punctuation or ends a line, and before the first character of a line that would begin a heading, a list, a quote, or a numbered item. A comma, period, colon, question mark, quotation mark, or apostrophe has none, so a sentence stands in the file as it reads, where content.md may put a backslash before each of them. The Transcript's Markdown is written the same way.
- HTML is a web page (XHTML), and it carries the book's language when the book has one. When the text has headings, the page has a contents list, a navigation landmark named "Contents", that links each heading; the list leaves out the book's own title heading. A book that skips heading levels (a level 1, then 3, then 2) has one nested list for them, the 3 and the 2 beside each other under the 1, where it used to have two lists inside one item. The page carries the book's language only when it is a well-formed language tag, and so do the PEF and EPUB files.
- RTF headings are bold and larger, from 22 point at level 1 down to 13 point at level 6, and carry outline levels, so TextMouth reads them back as headings at the same levels. A list is a run of paragraphs, each starting with a bullet or a number and a tab. A table of more than 63 columns becomes a paragraph for each row, its cells apart by tabs.
- Word 97-2003 (.doc) is made by Apple's writer from TextMouth's RTF, so it holds the same text. Its headings are larger and bold but plain text, so Word's navigation pane does not list them. It loses six rare characters that the RTF keeps: the bidirectional embedding and override controls U+202A to U+202E, and U+FFFD, which becomes "?".

- EPUB is an EPUB 3 e-book, made by TextMouth's own writer from the same walk of content.md that the other converted formats are written from, with the chapters and the pages kept as well as the words (see EPUB 3, below). It is written for a reader who navigates by headings and pages, and states only what is true of the file.

## EPUB 3

- The package holds, in the order the ZIP does, `mimetype` (stored, first), the container file, a file of XHTML for each chapter, the navigation document (`nav.xhtml`), and the package document (`content.opf`). A chapter that passes about 256,000 bytes goes on in another file, which begins where a heading does once the first is past that size, or after four times as much where there is none.
- The navigation document has a contents list (a navigation landmark named "Contents") nested by the headings' levels, which links every heading, every chapter, and every place the book's own contents point at, and, for a book with pages, a page list (named "Pages", hidden from the page as EPUB intends) that links every page and is read by the reading system's page navigation. A page whose label would be empty is named by its number.
- A heading is a real heading at its level. A chapter that begins with words before any heading gets a contents entry named for the chapter, or the book, and no heading added; a chapter with a title and no blocks leaves the contents, and a heading made only of characters XML forbids, or of zero-width ones, is written as a target with no heading and listed as "Untitled". An empty book is one empty chapter, which is valid, though TextMouth's own reader says it has nothing to read.
- The package document names the book's identifier (its library identity, so exporting a book twice gives one identifier), title, and author, its language where the book has one ("und", undetermined, where it does not, and then the chapters carry no language and each block takes its direction from its words), and the date of the export. A book in a right-to-left language or script, such as Hebrew, Arabic, Persian, Urdu, or a language written in Arabic letters, gets right-to-left text and page progression. The accessibility metadata says textual, sufficient as text, no hazards, a table of contents and a reading order always, structural navigation only when the book has headings of its own, and page navigation and page break markers only when it has pages, with a summary in plain words, as in "This book was exported from TextMouth as text only. Its headings are real headings, and the contents list links them. It has a page list, and the start of each page is marked in the text. It has no pictures, sound, or video, and the text of a picture's description is kept as text." It claims conformance to no standard.
- It holds no pictures (their alternative text stays as text), styles, raw HTML, heading annotations as headings, or cover, and no character that XML forbids. A page that begins in a table cell stays in the cell; a contents place in a cell moves to just before the table.
- The file is written to a scratch file and opened again before it is moved into place: every part must read back whole with the checksum the ZIP stores for it, else the file is removed and the export fails with "The EPUB file could not be written." A failed write says "The EPUB file could not be written, because the disk may be full.", or, for a volume that is read-only or a permission that is missing, "The EPUB file could not be written: " and the system's words.
- What an EPUB reads back as, when TextMouth imports its own export: the words, the pages with the same word before each, and the headings at the same levels are the same. These differ: a contents place that is not a heading reads back as a heading row at its depth in the contents, not at its level; one in a table cell reads back a few words early; of several chapters that hold only page markers, only the first title is kept; and a chapter that begins with words, or a long book with no headings that was split into files, gains heading rows (named for the chapter or the book, then "Chapter 2", "Chapter 3", and so on).

## Braille files

- BRF and PEF translate the book's text to braille with liblouis, in the language, code, and contraction of the options below, and lay it out in pages as BANA's Braille Formats (2016) says. Both hold six-dot cells only. A BRF writes each cell as a character, North American Braille ASCII unless you choose other braille file characters below, with a form feed between its pages, for braille displays and embossers. A PEF is XML that holds the same pages as Unicode braille, for embossers; its head names the book's title, its author when the library has one, its language (English when the book names none), a unique identifier, and the date it was made.
- While BRF or PEF is chosen, options sit under the Convert to pop-up, in the order below. They start from the Braille setting (see [Settings](settings.md)), at 40 cells by 25 lines with page numbers on and, for a BRF, CR LF line ends and the braille file characters of the Braille tab. The dialog keeps them until it closes, and they are dimmed while an export runs. Each is read as its label, its value, and its hint:
  - "Language", with the values of the Braille tab. Its hint is "The language of the braille code the book is written in."
  - "Braille code", with the values of the Braille tab. Its hint is "The braille code the book is written in."
  - "Contraction", with the values of the Braille tab. Its hint is "Whether that code's braille is contracted."
  - "Cells per line", a stepper from 18 to 80, with a value such as "40 cells". Its hint is "How many braille cells each line holds, from 18 to 80."
  - "Lines per page", a stepper from 4 to 50, with a value such as "25 lines". Its hint is "How many lines each braille page holds, from 4 to 50."
  - "Braille page numbers", a checkbox. Its hint is "Whether each page's last line carries its braille page number."
  - "Line ends", for BRF only, a pop-up with "CR LF" and "LF". Its hint is "CR LF suits most braille displays and embossers." A PEF always ends a row with a line feed.
  - "Braille file characters", for BRF only, after "Line ends", a pop-up that chooses how the file writes each braille cell as a character: "North American Braille ASCII", "Eurobraille, six-dot (German-speaking countries)", or "Unicode braille patterns", starting from the Braille tab's choice (Unicode braille patterns is never that choice). Its hint is "How the BRF file writes each braille cell. Most braille displays and embossers read North American Braille ASCII, and those set up for German read Eurobraille. To share braille with a reader elsewhere, export a PEF." VoiceOver says its value first, as in "North American Braille ASCII, Braille file characters, pop-up button". A PEF always holds Unicode braille, so it has no such choice.
- The three pop-ups are the Braille tab's own, so they offer this Mac's tables too, check a Mac table the first time it is chosen, and speak a refusal as the Braille tab does (see [Settings](settings.md)).
- When the table chosen in Settings cannot be used here, the options start from Unified English Braille, contracted (Grade 2), and say so under the pop-ups until you choose another table: "TextMouth can't use the braille table chosen in Settings, “French braille”, so this export starts from Unified English Braille, contracted (Grade 2)." The table cannot be used when this Mac no longer has it, when it is this Mac's copy of one of TextMouth's own four tables, or when a check earlier in the session refused it, but not as too slow, or because it could not run, which the next check measures again. The sentence names the table by its display name, or by its file name when this Mac does not offer it.
- An export started while a table just chosen here is being checked waits for the check, and Stop is offered meanwhile: Stop, or closing the dialog, ends the export before it writes anything. While the check runs, the Export button's hint is "Exports the checked items to the folder once the braille table just chosen has been checked." The export then writes with the table the pop-ups show once the check has passed, or the one they went back to.
- Eight-dot braille characters already in a book's text are written as their six-dot part. A table that writes an ordinary character as an eight-dot cell fails that book's export, naming the character, as in "Couldn't export Moby-Dick - Text.brf: The braille table writes “«” as an eight-dot cell, and TextMouth writes BRF and PEF files in six-dot braille only." When no one character is to blame, the sentence names the cell's dots. Some tables write @ in eight-dot computer braille, so a book holding an e-mail address fails to export with them; the other books export.
- The layout:
  - Headings 1 and 2 are centered, with a blank line before and after. Heading 3 starts at cell 5, and headings 4 to 6 at cell 7, each with a blank line before. A heading is never the last text on a page, unless it ends the book.
  - A paragraph starts in cell 3 and runs over in cell 1.
  - A list item starts in cell 1 and runs over in cell 3, and each level of a nested list starts two cells further in. A blank line comes before a list and after it, and none between its items; a list right after a heading in cell 5 or 7 has none before it. An item that runs over starts on a page with room for its first two lines. An ordered list's items begin with their number and a period.
  - When "Braille page numbers" is checked, a page's last line carries its braille page number at the right, so a page holds one line of text fewer than "Lines per page" says.
- A quote is written as the text of its blocks, a code block as a paragraph for each of its lines that has text, and a table as a paragraph for each row, its cells apart by semicolons. A thematic break writes nothing. The address of a link is not written, only its text. Italic and bold are written as emphasis, as the next bullet says, except in a table's cells, a code block, a numbered item's number, and the book's title, which are plain.
- Italic and bold in the book's text are written as the braille code's emphasis signs, where the table carries them. TextMouth's braille helper tests each table it uses, by writing a sample with each kind of emphasis and reading it back, and a table whose signs do not read back exactly as written writes plain braille. Unified English Braille, contracted or not, carries them. English Braille, American Edition, and most of this Mac's tables do not, since liblouis cannot read their emphasis back, so they write plain braille as every export did, and the export of a book with emphasis is then the export of the same book without it, byte for byte. TextMouth reads UEB braille back with its emphasis, as italic and bold in the book's text, and a word before an emphasis end sign comes back whole (see [What TextMouth reads](what-textmouth-reads.md), which also says how EBAE braille is read).
- A character the table lacks, such as Chinese, Cyrillic, or an emoji, is written in liblouis's escape notation, and TextMouth reads it back as that notation.
- A word longer than a line is cut after a hyphen or slash where it can be, and never inside a number. The cut adds no hyphen or continuation indicator yet.
- TextMouth reads its own braille back with fewer heading levels than it wrote: levels 1 and 2 are both centered, so they read back as level 1; level 3, at cell 5, as level 2; and levels 4 to 6, at cell 7, as level 3 (see [What TextMouth reads](what-textmouth-reads.md)).
- Stop is read before a book's translation begins and after it ends, not during it, so a Stop pressed while a long book is translated takes effect when the translation ends, at the latest at the helper's time limit (see [Where TextMouth keeps your library](where-your-library-lives.md)).

## A transcript as captions

Part of version 0.4.2.

- The Transcript checkbox has its own pop-up, "Convert transcript to", so it never sounds like the "Convert to" pop-up of the text. VoiceOver reaches it right after the checkbox.
- Its choices are JSON and Markdown, then each text writer, such as HTML, RTF, or EPUB, then WebVTT and SubRip.
- JSON and Markdown is the first choice and the default. It gives the transcript as TextMouth keeps it, as before.
- A text writer writes the transcript's text, made from the Markdown TextMouth reads it from, as it does for the text of a book. EPUB is among them.
- WebVTT: "Captions in WebVTT, which web browsers and most players read: one file for the book, timed from the start of its audio."
- SubRip: "Captions in SubRip (.srt), which nearly every player reads: one file for the book, timed from the start of its audio."
- While captions are chosen, the checkbox reads "Transcript as WebVTT", with no size and no file count. A WebVTT file is plain UTF-8. A SubRip file begins with the UTF-8 byte-order mark and ends each line with CR LF.
- SubRip has no standard way to escape text, so TextMouth writes as character references the few strings that a player or reader would take for something else, and TextMouth's reader decodes them:
  - the ">" that ends "-->", as &gt;;
  - a "<" with a ">" after it, which would look like a tag, as &lt;;
  - a "{" followed by a backslash, as &#123;;
  - an "&" that begins what a reader would decode, as &amp;.
- Other players may show those references as written.
- A transcript that keeps its text and no times, such as one that holds only Markdown, can't be written as captions. The export says "Couldn't export … - Transcript.vtt: The book has no timed transcript to write as captions."
- A transcript only in the cloud is not downloaded. The export names the book, as in "Moby-Dick isn't downloaded. Download it first: select it in the library, then choose Download Now."

## Text as spoken audio

Part of version 0.4.2. A text book can be spoken by its voice into one audio file, with a chapter for each heading.

### The options

- The Export dialog of a text book has a checkbox named "Text as spoken audio". Its hint is "The book's text spoken by its voice into one audio file, with a chapter for each heading." It gives no size, since the size is known only once the book is spoken.
- The dialog reads the book's headings only once you check it. Until then it opens at once. While it reads, it says "Reading the book's headings…". If the text can't be read, it says "This book's text can't be read, so it can't be spoken into an audio file."
- The options follow the checkbox, in this order. They are dimmed while an export runs.
  - Format, a pop-up with M4B, M4A, and MP3. Its hint is "The kind of audio file. M4B is an audiobook; M4A and MP3 play in more apps. M4B and M4A have a chapter for each heading; an MP3, for each of the first 255."
  - From, a pop-up of the book's beginning, "Beginning of the book", and each heading. Its hint is "Where the spoken audio begins: the beginning of the book, or a heading."
  - To, a pop-up of each heading and "End of the book". Its hint is "The heading whose section ends the spoken audio, with any headings under it, or the end of the book."
  - Speed, a slider, read as a value such as "200 words per minute". Its hint is "How fast the voice speaks in the audio file. It starts at this book's speed."
  - Pitch, a slider, read as "Normal (1.0x)" or "1.5x". Its hint is "How high the voice sounds in the audio file. It starts at this book's pitch."
  - A line naming the voice, as in "Voice: Moira", and a line about Apple's licence: "Speech made with the Mac's voices is for your personal, non-commercial use, under Apple's licence."
- A heading is listed as the headings panel says it, as in "Chapter 3 - level 1", or "Skipped, Notes - level 2" for one you skip.
- A book with no headings has no From and To. The options say "This book has no headings, so all of it is exported."
- The options have no group of their own. VoiceOver reaches them one after another, right after the checkbox, as it does the braille options.
- The voice, speed, and pitch start from what the book is read with.

### MP3 and chapters

- M4B and M4A have a chapter at each heading. An MP3 can hold chapters for the first 255 headings only.
- While MP3 is chosen for a range of more than 255 headings, a line follows the Format pop-up: "This range has 300 headings, and an MP3 has chapters for the first 255 only. Choose M4B to have a chapter for each of them." Headings you skip are not counted.
- The end of such an export says it too: "The MP3 has chapters for the first 255 of its 300 headings; export it as M4B to have a chapter for each."

### While it runs

- Export speaks the book chapter by chapter, and the progress says which: "Speaking chapter 2 of 12…". Then it says "Encoding the audio file…".
- The file is named after the book and the range, as in "Middlemarch - Audio" for the whole book, or "Middlemarch - Chapter 2 to End".
- Stop keeps the chapters already spoken. Its hint is "Stops the export. The chapters already spoken are kept, so exporting the same range at the same speed and pitch goes on from there, before TextMouth quits, a different export of spoken audio starts, or the book's voice, text, substitution rules, or pauses change."
- The end says what was kept: "Kept 5 of 12 chapters: export the same range at the same speed and pitch to go on from chapter 6, before TextMouth quits, a different export of spoken audio starts, or the book's voice, text, substitution rules, or pauses change." There is a form for all chapters and one for a single chapter.
- Kept chapters live in this Mac's Caches folder, in a folder named Speech Export. TextMouth empties it at the next launch.
- Quitting TextMouth during an export stops it as Stop does, then quits. It waits at most 5 seconds. The chapters already made stay until the next launch empties them.
  - A small window titled "Quitting TextMouth" appears, and VoiceOver says: "TextMouth is finishing up before it quits: stopping a speech export with the chapters it finished kept. It will quit as soon as that is done." With several exports it says "stopping 2 speech exports with the chapters they finished kept".
  - Pressing Command-Q again, or choosing Quit in the Dock again, says the same words again and does not cut the export off (0.4.4). It used to quit at once.
  - Logging out, restarting, or shutting down waits for the export to stop, up to 5 seconds, and is not cancelled.
- The spoken chapters are deleted only after the finished file is in the chosen folder, so a file that can't be put there loses no chapters.

### When a book can't be spoken

- Each reason is said before anything is spoken, with what to do:
  - A Personal Voice: "“Ana” is a Personal Voice, which macOS can't record to a file. Choose another voice for this book with the Voice button in its reader, then export again."
  - No voice: "No voice is installed to speak it. Add a voice in System Settings, Accessibility, Spoken Content, then export again."
  - Too little disk: "There isn't room on the disk for it: it needs about 400 MB, and TextMouth keeps 1 GB free. Free some space, then export again."
  - A second export: "TextMouth is already exporting spoken audio, which it does one export at a time. Export this once that one has finished."
  - Nothing to speak: "The part of the book chosen has no words to speak."
  - Headings that changed: "The book's headings changed after the Export dialog opened. Close it, open it again, and choose the range again."
- A chapter the voice can't speak fails the whole export:
  - "The voice made no sound for “Chapter 3”. Check that the book's voice speaks the book's language."
  - "The voice stopped making sound partway through “Chapter 3”, and TextMouth stopped waiting for it."
  - Sound counts when the chapter's loudest sample rises above 0.001, which is -60 dBFS. The chapters spoken before the failing one are kept.
- Export refuses the folder where spoken chapters are kept, for any kind of export, and anything inside it: "Export can't write into the folder where TextMouth keeps spoken chapters, since TextMouth empties it. Choose another folder."

### A caution about listening

- While a spoken-audio export runs, listening to a book in TextMouth hasn't been tested. If the reading jumps back to words it has already said, stop the export or pause the reading.

### What is not done yet

- Time ranges, a selection, and the formats WAV, AIFF, CAF, Apple Lossless, and FLAC are not offered.
- Each chapter is not encoded while the next is spoken: the file is encoded once, at the end.
- Premium and neural voices were not measured.
- Whether VoiceOver reads the MP3 line, "Reading the book's headings…", and the unreadable-text line well in the drawn dialog was not checked by hand.
