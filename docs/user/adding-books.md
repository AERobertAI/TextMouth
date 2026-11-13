# Adding books

Part of [TextMouth's documentation](../../README.md).

## The Add to Library sheet

- Add to Library, the plus button in the Library window's toolbar, opens a sheet with every way to add to the library.
- On October 17, 2026 it took the place of the toolbar's Import, New from Text, and Add Feed buttons, whose commands are all in the sheet.
- VoiceOver calls the button "Add to Library", and its hint is "Opens a sheet with the ways to add to the library: open a book, import a folder, make a book from text, record audio, or add a feed".
- When the window lists no books and has no Continue button, VoiceOver's focus starts on it, where it started on the Import button before.
- The sheet has a heading, "Add to Library", a button for each way to add, and Cancel, which Escape presses. VoiceOver starts on the first button.
- The buttons come in the order below, with what each does written under it, which VoiceOver speaks as the button's hint:
  - Open Book…: "Opens a file picker to import books in any format TextMouth reads."
  - Import Folder…: "Chooses a folder that holds a DAISY book or audio tracks and imports it as one book."
  - New from Text…: "Makes a new book from text you paste or type."
  - New Recording…: "Records from a microphone into a new audiobook."
  - Add Feed…: "Opens a sheet where you type a feed's address and choose where its folder goes"
- Each button is named by its menu command, and VoiceOver adds the command's key in words when it has one, as in "Open Book…, Command + O".
- Choosing a button closes the sheet and then does what its menu command does, each described below.
- Cancel, or Escape, closes the sheet and does nothing.
- A button is dimmed when you have set its action to work only in reader windows, which you can for Open Book…, New from Text…, and New Recording…, under Works in in the Shortcuts tab of Settings. Its hint then ends "Not available in this window."

## Open Book… and Finder

- File menu, Open Book… (Command-O) imports the files you choose.
- Opening a supported file from Finder imports it and opens it.
- TextMouth declares itself a viewer of rich text, rich text with attachments, Word 97-2003 documents and templates, Word templates and macro documents, OpenDocument text and templates, web archives, SSML files, Kindle books (.mobi, .prc, .azw, and .azw3, and .kfx, .kfx-zip, .azw8, and .kpf), BRF, BRL, and PEF braille files, M3U and M3U8 playlists, MPEG-4, M4V, and QuickTime video files (.mp4, .m4v, and .mov, whose sound alone it plays), the audio formats it converts, and every .xml file, so Finder offers it in the Open With menu for them.
- It declares them at Alternate rank, as it does for every format but its own .tmb packages, so it never asks to be the default app for any of them.
- A .pef file is also a Pentax raw photo to macOS, so Open Book… accepts whatever type the system gives a .pef, and the import tells a braille file from a photo by reading it.
- A photo is refused with the sentence for a PEF that cannot be read (below).

## TextMouth packages

- A TextMouth package, a folder ending in .tmb, chosen in Open Book… opens as the book it holds, as it does from Finder, instead of being refused as an unsupported format.
- A package for a book the library does not list lands in the folder the window shows and, when the window shows the Reading List, goes onto the Reading List there, as any file imported there does, with the announcement naming the folder.
- Of several packages chosen at once, only the first opens a reader window.
- A package for a book the library lists opens that book, and a copy of the package, such as a Finder duplicate, or the old copy that Replace Existing left in the Trash and you put back, opens the listed book and never takes its place.

## New from Text…

- File menu, New from Text… makes a book from text you type or paste.
- Its key, Shift-Command-T, works in Library windows, and with no window open, when it opens New from Text… in a new Library window.
- In a reader window the same key opens or closes the Sleep Timer sheet (Show Sleep Timer). There, and in Settings, the New Recording window, and an audio editor's window, File > New from Text… is dimmed and shows no key, so choose it from a Library window.
- Either action can have another key, or work in another kind of window, from the Shortcuts tab of Settings (see Works in, under the Shortcuts tab).
- The New Book from Text window has a Title and an Author field, a text area, Paste from Clipboard, Open in Editor (on the Mac), Reload from Editor once an editor has the text, Cancel, and Add to Library.
- A book whose title holds only spaces, or nothing, is called Untitled, and so is its file.
- When something in that window does not work, a sentence beside the buttons says so, which VoiceOver also says once, and it goes when you change the text:
  - Paste from Clipboard with no text on the clipboard changes nothing: "The clipboard has no text to paste, so the text is unchanged. Copy some text, then paste again."
  - Open in Editor writes the text to a file in the Mac's temporary folder and opens it in the app this Mac opens plain text with.
    - If the file can't be written: "Could not open the text in an editor, because its file could not be written. Paste or type the text here instead, or try again."
    - If no app opens it: "Could not open the text in an editor, because no app opened its file. Paste or type the text here instead, or try again."
  - Reload from Editor reads the file back as an import reads a file: as UTF-8, in the encoding a byte-order mark names, or in the encoding its bytes look like, such as Windows-1251 Russian or Shift JIS Japanese, and as Windows-1252 only when nothing can be trusted.
    - Line endings become line feeds.
    - If the file can't be read, the text is left as it was: "Could not read the text back from the editor's file, so the text here is unchanged. Save the file in the editor, then choose Reload from Editor again, or choose Open in Editor to start again."
    - If it was read as Windows-1252 only for want of a better guess and holds characters beyond ASCII: "The text was reloaded, but the editor's file does not say what encoding it is in, so some characters may be wrong. Check the text, or save the file in the editor as UTF-8 and choose Reload from Editor again."
    - That note stays only while the text is as it was reloaded.

## New Recording…

- File menu, New Recording… (Option-Command-N), also in the Library menu, records from a microphone into a new audiobook (see [Recording from a microphone](recording.md)).

## Import Folder…

- Library menu, Import Folder… (Shift-Command-O, in a Library window) imports a DAISY book kept as loose files, by its folder, one folder per book, or a folder of audio tracks as one audiobook, as a ZIP of the same tracks imports.
- It was called Import DAISY Folder… before October 14, 2026, and a key you gave it keeps working.
- Opening such a folder from Finder imports it the same way.
- The folder's tracks, and its manifest, at its top level or inside its one folder, are copied into the book's package, and the folder is left as it was.
- The book takes the folder's name unless the manifest gives a title.
- A folder holding neither a DAISY book nor tracks is refused, and the alert says what it holds.
- A folder you import is never deleted or offered for deletion, whatever Storage settings say about originals, since it holds files that were not copied.
- Deleting an original also refuses a folder, or a link to one, whatever asked for it: nothing is deleted or sent to the Trash, and the debug log records ORIGINAL_KEPT with the folder's name.
- A folder that is a link (a symbolic link, such as `ln -s` makes) is read as the folder it points to, since you named it, and is imported as choosing that folder would be.
  - The book takes the name of the folder the link leads to, not the link's name, and that folder is what the book records as its source.
  - Links inside the folder are listed but not followed, so a link inside a folder cannot lead the import elsewhere.
  - A link to nothing is still an error. A link to a file is left as it is.
  - A link to a folder of DAISY books in folders is refused, as choosing the folder itself is.
- A folder holding DAISY books in folders inside it is not a book itself and is refused: choose the book folders instead, several at once.
  - The alert for it says that the folder holds no DAISY book and no audio tracks to import as one book, and lists the files found anywhere inside it, which does not say that the books are in the folders within.

## A transcript chosen with its audio

- A WebVTT (.vtt) or SubRip (.srt) file chosen or opened together with its audio is attached to that audio's book as the audio is imported. It is not imported as a book of its own, and nothing is refused.
- It works with Open Book… and when you open the files from Finder or drop them on the Dock icon.
- The file must be the one the audio finds as its transcript: named as the track is, with its extension changed (01.vtt beside 01.mp3), and, when both are beside the audio, the .vtt (see [Transcribing an audiobook](transcribing.md)). A .srt chosen beside an audio file that has a .vtt of its own is not that audio's transcript.
- A transcript file chosen without its audio, or with audio that does not find it, is refused as a book: "Unsupported file format: .vtt. A .vtt file is a transcript, not a book. To use it, import its audio, open the book, and choose Attach Transcript… from the Book menu." For a .srt file it says ".srt".
- If the audio's own import is skipped, as a duplicate or a refused file is, a transcript chosen with it is dropped too, silently.

## M3U and M3U8 playlists

- An M3U or M3U8 playlist (.m3u, .m3u8), chosen with Open Book…, imports as one audiobook of the files it lists, as a folder of the same tracks imports.
- The book is named by the playlist's #PLAYLIST line, else by the playlist's file name without its extension, and has a heading for each entry, in the playlist's order, titled by its #EXTINF line, else by the file's name.
- The tracks are copied into the book's package, and those that need converting are converted (see [What TextMouth reads](what-textmouth-reads.md)).
- Importing the same playlist again finds a duplicate.
- Only ordinary files inside the playlist's own folder, or in folders beneath it, are used:
  - Each other entry is skipped and named with its reason: "a web address", "outside the playlist's folder", "not found", "a folder", "not an audio file", "hidden", "not an ordinary file", or "listed before".
  - Once the book is in the library, an alert titled Book Imported lists them, as in "TextMouth skipped 2 entries of “mix.m3u”: “https://example.com/a.mp3” (a web address) and “More/c.mp3” (not found).", and the book is not opened.
  - At most ten entries are named, fewer when the list would pass 600 characters, then "and N more", and an entry of more than 60 characters is shortened with "…", keeping its start and its file name.
- A playlist and its tracks are never changed, deleted, or offered for deletion, whatever After Importing a Book says.
- TextMouth never fetches an address: a streaming playlist, for audio on the web, is refused, and so is one that lists only web addresses.

## Add Feed…

- Library menu, Add Feed… (Shift-Command-F, in a Library window), or the Add Feed… button of the Add to Library sheet (above), subscribes to a podcast or article feed (see [Podcasts and article feeds](feeds.md)).

## ZIP archives

- A ZIP of several books imports each of them (an .rtfd folder inside is one book, not its separate files), and TextMouth offers to create a folder for them.
- The progress overlay's Cancel button stops a ZIP import after the book in progress, or at once when that book is, on the Mac, a Word document older than Word 6 that textutil is converting, or a braille file that the braille helper is translating.
- In that case textutil or the helper is stopped, that book is not imported, and the alert says after how many books the import stopped.
- A single file's import that Cancel stops that way ends with no alert.

## A TextMouth package inside a ZIP

- A TextMouth package inside a ZIP, as one mailed or compressed in Finder, imports as one book, with its places, bookmarks, and settings, not as its book file and its text cache apart.
- A package whose book the library lists is skipped as a duplicate, and one that cannot be identified is a failure, so the archive is kept.

## The import overlay

- While books import, the import overlay in the Library window shows how far the import has got, and VoiceOver reads all of it there.

### What the overlay says

- For a ZIP archive the overlay first counts the items and bytes extracted, as in "Extracting “Library Export.zip”: 120 of 300 items, 1.2 GB of 3.4 GB...".
- It then counts the books processed, as in "2 of 100 books processed", with the book under way, by its name in the archive, and the step it is at, as in "Book 3 of 100: “Moby Dick.epub”, reading its text".
- A single file, or a ZIP holding one book, shows its name and its step the same way, as do a TextMouth package opened from the Finder, from "checking the package" on, and a book made with New from Text, by the title you typed.
- A package's line says "copying it into the library" while it copies.
- A recording saved from the New Recording window is named by its title the same way, its line going quietly once the save ends, since its window says how the save ended.
- The count's noun agrees with the total, as in "0 of 1 book processed", as it does in the overlay of a text cache update or of Redo Text Extraction, as in "0 of 1 book extracted".
- A ZIP holding one audiobook also counts the items and bytes extracted while it extracts, as in "“Harbor Talks.zip”, extracting the archive: 12 of 30 items, 120 MB of 340 MB".

### Time and waiting imports

- Once a book of several is done, the overlay gives the time left, as in "About 4 minutes left" or "Less than a minute left".
- It weighs each book still to come by its size where that tells its time, as an EPUB's, PDF's, Word document's, or text file's does, so a large book still to come counts for more, while an audiobook's file, a DAISY book, or an .rtfd folder counts at the average time such books took.
- When more imports wait behind the one shown, the overlay says how many, as in "2 more imports waiting", until Cancel is pressed.
- Once a book has taken 10 seconds, the overlay says for how long, as in "1 minute, 5 seconds on this book", in steps of 5 seconds, so a stuck book shows as a time growing on one step.

### What VoiceOver hears

- For an import that runs 10 seconds or more, VoiceOver also hears, wherever you are, each quarter of a ZIP's books, as in "Importing “Library Export.zip”: 25 of 100 books processed, about 4 minutes left.", and how it ended, as in "Finished importing “Library Export.zip”: 97 books imported, 2 skipped as duplicates, 1 failed."

### The Nothing Imported alert

- A ZIP import that brings no new book, and in which nothing failed, says what it found in the Library window's alert, titled Nothing Imported, however quickly it ends: "No new books in “Library Export.zip”: all 24 were already in your library." ("both" for two, and "its one book" for one).
- For an archive holding no book TextMouth reads, the alert says what the archive holds instead, most files first, as in "No books were found in “Radio.zip”. It holds 176 .wma files, which TextMouth does not import."
- Up to three kinds are named, the rest counted as other files.
- The alert waits on screen, and VoiceOver reads it as it appears, so it is never missed as an announcement made while you were in another app could be.
- One with a failure says so in its alert instead.

### Cancel and speaking the overlay

- Cancel says at once "Cancelling after this book...", or "Cancelling..." before the first book.
- The alert of a cancelled import says where it stopped.
- Library menu, Speak Import Progress has VoiceOver speak the overlay's lines on request, or say "No import is under way."
- Give it a key in the Shortcuts tab of Settings, under Information, to use it in every window but an audio editor's, a reader's included (see Works in, under the Shortcuts tab).

## When an import fails

- When an import fails, an alert names the file, the step that failed, and why, as in "Could not import “notes.md”. Reading its text failed: This file has no text to read."
- Nothing is added to the library, and the original file stays where it was, whatever Storage settings say about originals.
- A ZIP batch lists each failed file by name with the same reason after it, while the batch's other books import, and the debug log records the same words in an IMPORT_FAILED line.
- These reasons have plain words of their own:

### A file with no text to read

- A plain text, Markdown, HTML, web archive, SSML, rich text, Word 97-2003, OpenDocument, Word 2003 XML, Kindle, or braille file, or a DTBook on its own, with no text in it is refused with "This file has no text to read."
- That covers a file of no bytes, a file of only white space or only a byte-order mark, an HTML file or a web archive of only markup, a document of only empty paragraphs, an SSML file of only markup, and a braille file of only blank lines or one that translates to nothing but white space, so no silent, empty book is added.
- A Markdown file that is only a heading still imports.
- An .xml file of no bytes or only white space is refused the same way, but at the step "Checking its format", as in "Could not import “empty.xml”. Checking its format failed: This file has no text to read."
- Open Book…, Finder, and the files inside a ZIP are checked. New from Text… and the rebuilding of a book already in the library are not.

### A disk without room

- A disk without room for the book is reported as "There isn’t enough free space on the disk.", as in "Could not import “Middlemarch.epub”. Copying it into the library failed: There isn’t enough free space on the disk."
- The words never name the hidden package the import was building.

### Documents TextMouth's own readers can't read

- A rich text, rich text with attachments, Word 97-2003, OpenDocument, or Word 2003 XML document that TextMouth's own reader can't read, and, on the Mac, a Word document older than Word 6 that textutil can't read, is refused with a sentence that names its kind, as in "Could not import “Letter.doc”. Reading its text failed: This file could not be read as a Word 97-2003 document. It may be damaged, or another kind of file."
- The kind is "a rich text document", "a rich text document with attachments", "a Word 97-2003 document", "an OpenDocument text document", or "a Word 2003 XML document".
- A Word 6 or Word 95 document, which TextMouth's own reader reads since version 0.4.1, is named as a Word 97-2003 one, as is a Word 1 or Word 2 document, which is a bare stream and not a compound file.
- The same sentence covers each way a file can be unreadable:
  - A file that is not rich text, though it is named so: its first bytes, after a byte-order mark and white space, are not {\rtf.
    - An .rtfd folder that holds no TXT.rtf, or only a link in its place, says "a rich text document with attachments".
    - Groups nested more than 10,000 deep, which no real document holds, are refused as "a rich text document", whatever the file's name.
  - A file that is not a Word 97-2003 document, though it is named so, or whose structure is damaged: a compound file that fails its own checks, a file with no WordDocument part, a number or an offset that does not fit the file, or fields nested more than 10,000 deep.
  - An OpenDocument document is unreadable in these cases:
    - It is not a ZIP package.
    - It holds the media type of another kind of document (a spreadsheet, say).
    - It has no content part.
    - Its content part is damaged, cut off, declares a document type, has a tag of more than 1,024 attributes, is written in an encoding TextMouth can't read safely (see below), or is nested more than 200 elements deep.
  - A damaged styles or information part does not refuse an OpenDocument document: the body is read without it.
  - A Word 2003 XML file is unreadable if its root is not a Word document, or if it is damaged, declares a document type, has a tag of more than 1,024 attributes, is written in an encoding TextMouth can't read safely (see below), or is nested more than 200 elements deep.
  - A Word 6 or Word 95 document whose structure is damaged: a compound file that fails its own checks, a file with no WordDocument part, a number or an offset that does not fit the file.
  - A Word 6 or Word 95 style sheet, bin table, or section table that does not fit loses its formatting, not the document.
  - On the Mac, a Word document older than Word 6 is unreadable when textutil exits on it, or writes nothing for it, which is what it does when it cannot read a file.

### Documents on iOS

- On iOS, which runs no helper program, a Word document older than Word 6 is refused with "Converting this kind of file is not available on iPhone yet."
- Rich text, rich text with attachments, Word 6 to Word 2003 documents, OpenDocument text, and Word 2003 XML are read there, as on the Mac.
- A Word 6 or Word 95 document has been read there since version 0.4.1. It was refused on iOS before, and read by textutil on the Mac.
- A Word 6 or Word 95 document is told from a Word 97-2003 one by its own bytes.

### An OpenDocument text document's title and author

- An OpenDocument text document's title and author come from the document's own information.
- Apple's textutil lost an .odt's author, so a book of that kind added before version 0.4.0 shows the author Unknown.
- The library does not change an author it has, but importing the file again with Replace Existing gives the book the author the file names, where you edited neither (see below).

### A document older than Word 6 that textutil was stopped on

- On the Mac, a Word document older than Word 6 that textutil was stopped on, for passing one of its limits (see [Where TextMouth keeps your library](where-your-library-lives.md)), says why: "TextMouth stopped reading this document because it ran longer than 31 seconds."
- The reason can instead be "it held more than 1024 MB of memory" or "it used more than 121 seconds of processor time".
- The 31 seconds are the 30 allowed and one more for each million bytes of the document, rounded up, here for a small document, and the 121 are four times the time allowed.
- Every other kind of document, Word 6 and Word 95 since version 0.4.1 among them, is read inside TextMouth, never by textutil, and is not stopped this way.

### Documents protected by a password

- A Word 97-2003 document (a Word 6 or Word 95 one too) or an OpenDocument document protected by a password is refused with "This document is protected by a password. Save a copy without the password, then import that copy."

### A Word document's title and author

- A Word document's (.docx) title and author come from the document's core properties, its title and its creator.
- A title that the properties leave empty, or hold only spaces, is not a name: the book takes the file's name, as a document with no properties does.
- A creator left empty is not a name either: the author is "Unknown", as for a document with no creator at all.

### XML parts TextMouth can't safely read

- A Word document, an EPUB, a DAISY book, or an SSML file with a part TextMouth can't safely read is refused, naming the part, in one of three sentences.
- Before TextMouth reads a part, it checks the part's raw bytes, which no real file in its collection fails.
- For an EPUB, the parts checked are its XML files, such as its container, package document, and navigation files. Its chapters are read as web pages.
- The three sentences are:
  - A part with a tag of more than 1,024 attributes is damaged, as in "The file “word/document.xml” in this document is damaged or incomplete: it has a tag with too many attributes for TextMouth to read safely. Get a fresh copy of the document, then import it again."
    - The container is "this document" for a Word document, "this EPUB book" for an EPUB, or "this DAISY book" for a DAISY book.
    - An SSML file says "This SSML file is damaged or incomplete: it has a tag with too many attributes for TextMouth to read safely."
    - A tag's length is not limited, only its attributes.
  - A part of the ZIP archive that cannot be unpacked is damaged in the same words (0.4.3), with the reason that its data cannot be read: "The file “word/document.xml” in this document is damaged or incomplete: its compressed data could not be decoded. Get a fresh copy of the document, then import it again."
    - The reason is "its compressed data could not be decoded" for a compressed part, and "its data could not be read" for a stored one.
    - A DAISY book says "in this DAISY book" and "Get a fresh copy of the book", and an EPUB says "in this EPUB book", with the same reasons. Before this, a Word or DAISY file with a damaged ZIP part showed the ZIP library's own error.
    - The ZIP library's own error goes to the debug log, in a line that begins DOCX_ZIP_ERROR, DAISY_ZIP_ERROR, or EPUB_ZIP_ERROR, with the part's name inside the archive and no path on this Mac.
    - A write that fails while a DAISY file is copied, such as a full disk, is not called damage. It is reported as the error it is.
  - A part that defines entities of its own in its document type declaration (an internal subset, in square brackets) is refused: "TextMouth can't safely read the file “word/document.xml” in this document, because it defines entities of its own. Open the document in the program that made it, save it again, then import it again."
    - An EPUB or DAISY book says "this EPUB book" or "this DAISY book" and "Open the book in the program that made it".
    - An SSML file says "TextMouth can't safely read this SSML file, because it defines entities of its own. Open it in a text editor, take the entity definitions out, save it, then import it again."
    - A document type that only names an external one, as DAISY and NCX files do, is read.
  - A part written in an encoding other than UTF-8, UTF-16, UTF-32, US-ASCII, ISO-8859, Windows-1250 to 1258, KOI8-R, KOI8-U, Macintosh, Shift_JIS, EUC-JP, EUC-KR, GB2312, GBK, GB18030, or Big5 (or an alias of them) is refused: "TextMouth can't safely read the file “word/document.xml” in this document, because it is written in the UTF-7 encoding. Save it as UTF-8, then import it again."
    - An SSML file says "TextMouth can't safely read this SSML file, because it is written in the UTF-7 encoding. Save it as UTF-8, then import it again."
- An OpenDocument or Word 2003 XML document is refused for any of these three with the one sentence of its kind, as in "This file could not be read as an OpenDocument text document. It may be damaged, or another kind of file.", and a PEF braille file with "This file could not be read as a PEF braille file. It may be damaged, or another kind of file."
- A Word 2003 XML or OpenDocument document that declares a document type at all is refused too, as before.

### Markup TextMouth can't safely read

- Before TextMouth reads the markup of an EPUB chapter, an HTML file, a DAISY book, a Kindle book, or a web archive's page, it looks through it once. A Word, rich text, or OpenDocument document passes through the same look, in the HTML its reader writes. Markup that would crash TextMouth or fill the Mac's memory is refused, with one of four sentences that never call the file damaged, since it may not be.
- Markup nested thousands of levels deep, a document of millions of tags, and a broken declaration used to be able to stop TextMouth. No real book tried is refused for any of them.
- The four sentences, as an alert gives them after "Could not import “x”. Reading its text failed: ":
  - Markup nested too deeply, more than 128 levels: "This file's markup nests more than 128 levels deep, which TextMouth can't read safely. Get another copy of the file, or save it in another format, then import it again."
  - Too much markup in one document, more than 1,000,000 units of memory, a unit being about 800 bytes of the tree TextMouth builds: "One document in this file holds too much markup for TextMouth to read without running out of memory. Divide the document into smaller files, then import them."
  - Too many attributes on one tag, more than 1,000: "One tag in this file has more than 1,000 attributes, which TextMouth can't read safely. Get another copy of the file, or save it in another format, then import it again."
  - Markup built so that reading it would take far too long: "This file's markup is built in a way that would take TextMouth far too long to read. Get another copy of the file, or save it in another format, then import it again."
- The deepest real book nests 12 levels, and the deepest web page tried 36. The biggest real document, a whole dictionary as one 32 MB HTML file, uses under half the memory limit. No real tag has more than 7 attributes.
- An EPUB with a chapter that is refused reads its other chapters, and the report of the book names the chapter that was left out, as in chapter 2 (“OEBPS/ch02.xhtml”) "has markup that could not be read". If it is the only chapter, the EPUB's own sentence about a chapter that could not be read says so, not one of the four.
- A broken declaration in the markup, such as `<?a>` or a torn `<?xml version="1.0"`, is read as nothing, with the words around it, and no sentence is spoken.
- A feed gives no sentence. A page that a feed address was looked for in, an article's web page, and a title or summary in a feed are passed over when they pass a limit: no feed is found on that page, an article's book holds the feed's own text, a title is kept as it was written, and the markup of an item that passes a limit reads as no text. Feed discovery reads a page nested up to 512 levels deep, deeper than a book, since it converts nothing.

### Documents past the 64 MB limit

- A document, web archive, SSML file, DTBook, or Kindle book past the limit of 64 MB (see [What TextMouth reads](what-textmouth-reads.md)) is refused with "This document holds more than 64 MB, the most TextMouth reads from one document."
- For a rich text document the 64 MB counts the rich text file, or an .rtfd's TXT.rtf alone, whatever its attachments hold.
- For a Word 97-2003 document it counts the Word file.

### Web archives that can't be read

- A web archive that can't be read as one is refused with "This file is not a web archive TextMouth can read. It may be damaged, or another kind of file."
- One whose main file is not a page or text says "This web archive holds a file of the type “image/png”, not a web page or text, so it has nothing to read.", naming the type the archive gives.

### SSML files that can't be read

- An SSML file that begins with another element is refused with "This file is not SSML: it begins with the element “html”, not “speak”.", naming that element.
- One whose markup is broken is refused with "This SSML file is damaged or incomplete: " and how and where, as in "its markup breaks off early or has extra content after the end (line 1, column 27)."

### XML files of no known kind

- An .xml file that is not a DTBook, Word 2003 XML, or a PEF braille file is refused before anything is copied, at the step "Checking its format", as in "Could not import “catalog.xml”. Checking its format failed: This XML file is not a DTBook book, a Word 2003 XML document, or a PEF braille file, the kinds of XML file TextMouth reads."

### Kindle books that can't be read

- A Kindle book that can't be read is refused with a sentence that says why, as in "Could not import “Ferry Notes.mobi”. Reading its text failed: This Kindle book is copy-protected, and TextMouth can't read copy-protected books."
- The sentences are:
  - For a copy-protected book: "This Kindle book is copy-protected, and TextMouth can't read copy-protected books." This is checked first, so no part of such a book's text is read. A file that holds both MOBI 6 and KF8 is checked in both halves.
  - For a book whose text is compressed in a way TextMouth does not know: "This Kindle book is compressed in a way TextMouth can't read yet."
  - For a book that stops short or contradicts itself, as one whose download broke off does: "This Kindle book is damaged or incomplete: ", what is wrong, and "Get a fresh copy of the book, then import it again.", as in "This Kindle book is damaged or incomplete: its text records hold 4096 bytes of the 68150 it says the text has. Get a fresh copy of the book, then import it again."
  - For a file named as a Kindle book that is not one: "This file is not a Kindle book that TextMouth can read."
  - For a book with no words in it: "This file has no text to read."
- A KF8 book (an .azw3) imports like any other Kindle book. The sentence about the newer KF8 format that earlier versions gave is gone.
- A file that holds both MOBI 6 and KF8 whose KF8 half is damaged is read from its MOBI 6 half and imports. Only a copy-protected book is refused for it.

### KFX Kindle books that can't be read

- A KFX Kindle book that can't be read is refused with a sentence that says why.
- A copy-protected book, a damaged one, and a file named as a Kindle book that is not one get the sentences above.
- The others are:
  - For a book with no flowing text to read, such as a fixed-layout book, a print replica, a comic, a magazine, a children's book, a textbook, a notebook, or a book of only pictures: "This Kindle book has no flowing text to read, such as a comic or a print replica, so TextMouth can't read it."
  - For a Kindle Create package (.kpf), the file an author makes before a book is published: "This file is a Kindle Create package, which TextMouth can't read yet."
  - For a file that holds only a part of a Kindle book, such as the metadata file that sits beside it: "This file holds only part of a Kindle book. Open the book's main .kfx file."
- A KFX book is told copy-protected if its file, a license file beside it, or any part of a book of several is protected, and TextMouth never tries to remove the protection.

### Braille files that can't be read

- A braille file that can't be read is refused with a sentence that says what is wrong, as in "Could not import “Emma.brf”. Reading its text failed: Line 12 holds “é”, which is not braille ASCII."
- The sentences are:
  - For a BRF or BRL file with something in it that is not braille ASCII: "Line 12 holds “é”, which is not braille ASCII."
    - Lines are counted from 1 by their ends.
    - What shows as nothing, or joins the character before it (white space, an invisible character, or a combining mark), is named by its code, as in "Line 1 holds the character U+00A0, which is not braille ASCII."
    - So is a control character, as in "Line 12 holds the control character U+0007, which is not braille ASCII."
    - The blank braille pattern U+2800 is named by its code too, as in "Line 1 holds the character U+2800, which is not braille ASCII."
  - For a BRF or BRL file read as Eurobraille, six-dot, with something in it that is not Eurobraille, the same sentence with the code's name: "Line 3 holds “é”, which is not Eurobraille."
  - For a BRF or BRL file read as Unicode braille patterns, with a byte that is no braille pattern: "Line 2 holds the byte 0xE9, which is not a Unicode braille pattern."
  - For a BRF or BRL file read in a seven-bit code, North American Braille ASCII or Eurobraille, with a byte above 0x7F that begins no valid character, which may be a file of eight-bit computer braille: "Line 2 holds the byte 0xE9. This file may be eight-bit computer braille, which TextMouth does not read."
    - The line and the byte let you find a single stray byte.
  - For a BRF or BRL file that begins with a UTF-16 byte order mark: "This file is in UTF-16, which TextMouth does not read as braille. Save it in UTF-8 to read it."
  - For a book that records braille file characters this TextMouth does not know, as a library written by a newer TextMouth can: "TextMouth has no braille file characters named “ascii-braillo-no-047-01”." The book is refused by name, never read as another code, since that would give wrong text with no error.
  - For a PEF file that is not well-formed XML, is not a PEF document, or has a row that is not braille, which is also what a Pentax photo named .pef gets: "This file could not be read as a PEF braille file. It may be damaged, or another kind of file."
  - For a PEF file in eight-dot braille, or a BRF or BRL file of Unicode braille patterns that uses dot 7 or 8: "This file is eight-dot braille, which TextMouth does not read."
  - For a file past a limit (see [What TextMouth reads](what-textmouth-reads.md)): "This braille file holds more than 32 MB, the most TextMouth reads from one braille file.", "This file has more than 100,000 braille pages, the most TextMouth reads.", or "This file has more than 4,000,000 lines of braille, the most TextMouth reads."
  - For a book that names a braille table this TextMouth does not have, as a library written by a newer TextMouth with more tables can: "TextMouth has no braille table named “en-xx.ctb”."
    - The same sentence refuses one of this Mac's tables that this Mac no longer has or that its check refused (see [Settings](settings.md)), named with "mac:" before its file name, as in "TextMouth has no braille table named “mac:el.ctb”."
    - A TextMouth from before it offered this Mac's tables reads every "mac:" name so.
  - For one of this Mac's tables that could not be checked, as when the braille helper failed: "TextMouth could not check this Mac's braille table “mac:el.ctb”: the braille helper failed. Try again."
    - The table is not refused, and trying again checks it again.
    - The other reasons are listed in [Settings](settings.md).
  - For a translation that TextMouth stopped on, for passing one of the helper's limits (see [Where TextMouth keeps your library](where-your-library-lives.md)): "TextMouth stopped the braille translation because it ran longer than 11 seconds."
    - The 11 seconds are the 10 allowed and the share of the book's size, rounded up, here for a small book.
    - The reasons are the watchdog's, in the words listed under "Converting X was stopped because ...", below.
  - For a translation that failed any other way, because the helper is missing, could not start, ended with an error, or wrote output that does not match what it was given: "TextMouth could not translate this braille."

### Playlists that can't be imported

- A playlist that can't be imported is refused at the step "Reading the file", as in "Could not import “radio.m3u8”. Reading the file failed: It is a streaming playlist for audio on the web, which TextMouth does not import."
- The other reasons are:
  - "It lists only web addresses, and TextMouth imports only files on this Mac."
  - "It names no audio file in its own folder that TextMouth can import.", followed, when entries were skipped, by "It skipped 3 entries: " and the entries, named as the notice above names them.
  - "The playlist “mix.m3u” is too large to read." for a playlist file of more than 4 MiB.

## The Book Imported alert

- An import that adds its book but has something to tell ends with an alert titled "Book Imported", where a failure's alert is titled "Error": the entries a playlist skipped, the original of an .rtfd that was kept, or chapters or pages that were left out.
- The book is in the library, but it is not opened, so the alert is not left behind a reader window.
- A ZIP batch's alert that sums up its failed and incomplete books is still titled "Error".

## A book that is already in the library

- When a book's content is already in the library, TextMouth asks whether to keep both, replace the existing book, or cancel.
- A feed's episode or article holding the same file doesn't count.
- The question says which file matches which book, as in "“Moby-Dick.epub” matches “Moby-Dick”, which is already in your library. Replace the existing copy, or keep both as separate books?", and then, after a blank line, what Replace Existing keeps of the existing copy and where its files go:
  - For a text book: "Replacing keeps the existing copy's reading position and bookmarks, moved to their words in the new text wherever those are found, and its settings, folder, and place on the reading list. An edit of its text is kept beside the new text as a copy, not applied to it."
  - For an audiobook: "Replacing keeps the existing copy's reading position, bookmarks, settings, folder, and place on the reading list, and its transcript when the audio is the same. Edits of its audio or of its manifest are not kept."
  - For an audiobook whose new copy came with a transcript file beside its audio (see [Transcribing an audiobook](transcribing.md)), the sentence says which transcript will stay:
    - Kept: "Replacing keeps the existing copy's reading position, bookmarks, settings, folder, and place on the reading list, and its transcript when the audio is the same, rather than the transcript file found beside the new copy's audio. Edits of its audio or of its manifest are not kept."
    - Replaced: "Replacing keeps the existing copy's reading position, bookmarks, settings, folder, and place on the reading list. The transcript file found beside the new copy's audio replaces the existing copy's transcript. Edits of its audio or of its manifest are not kept."
  - When one copy is played from a recording and the other is read aloud from its text, as a DAISY book is: "One copy is played from its recording and the other is read aloud from its text, so replacing keeps only the existing copy's folder and place on the reading list, not its reading position, its bookmarks and their notes, or its settings."
  - Then one more sentence, by Move to Trash instead of deleting, under Removal Behavior in the Storage tab of Settings: "The existing copy's files go to the Trash, but putting them back won't return that copy to your library." while it is on, and "The existing copy's files are deleted permanently and cannot be recovered." while it is off.
  - A copy that is missing chapters adds "The copy just imported is incomplete." and what it lacks.
- The Replace Existing button's hint says "Puts the new copy in place of the one already in the library, keeping the existing copy's reading position, bookmarks, and settings.", and, for a recording and a text, "Puts the new copy in place of the one already in the library, keeping only the existing copy's folder and place on the reading list."

## What Replace Existing keeps

- Which transcript an audiobook keeps (0.4.2), when both copies have one and the new copy's came from a file beside its audio:
  - The existing copy's transcript stays when recognition made it, when you edited it or cleaned it up, or when this TextMouth can't tell, as for one made by a later version or one only in the cloud. It stays only when the audio is the same, as below.
  - The existing copy's transcript gives way to the file when it came from outside, from an attached file or a podcast, and you never edited or cleaned it up.
  - The question tells you which of the two will happen before you answer.
  - After the answer, when a file was not used, VoiceOver hears "“lecture.vtt” was beside the audio but wasn't attached as the book's transcript: Replacing kept the existing copy's transcript. To use the file instead, open the book and choose Attach Transcript… from the Book menu."
  - When each of several tracks brought a file, one sentence names them together and gives no Attach Transcript… advice, since that command takes one file for the whole book: "The transcript files beside the audio weren't attached as the book's transcript: Replacing kept the existing copy's transcript."

- Replace Existing makes the new copy the same book as the existing one, under the same ID, so it keeps more than the question names:
  - It keeps the existing copy's date added, its place among the books of its folder when you ordered them by hand, when it was last opened and played, the details you edited by hand in Book Info, and its own voice, speed, pitch, end-of-book choice, and skip units.
    - Everything else is the new copy's: its file and text, and its title and author where you edited neither.
  - The reading position, the bookmarks with their notes, and the skipped headings of a text book move to their words in the new text, as when a book's text is read again (see [Reader windows](reader-windows.md)), and a place whose words are not found stays where it was saved.
    - They move from the existing copy's text only when that is the text they were saved in.
    - From text saved in an editor without TextMouth's taking the edit, they are found by their words in the new text alone.
  - An audiobook's places count time in its recording.
    - Where the new copy has other chapters than the existing one, a book of tracks keeps each place at the same time into the same track, and a skipped heading follows its track.
    - Any other audiobook keeps each place at the same time on the recording, never cut short at the old chapter's end, and keeps its skipped headings aside, skipping nothing (see [Reader windows](reader-windows.md)).
  - The copies of edited text that Edit Text kept for the existing copy go with it into the new copy's package, and so does the existing copy's own text, kept as a content.md.edited- copy beside the new text, when it holds an edit you made or a save that no edit took (see [Where TextMouth keeps your library](where-your-library-lives.md)).
    - When such a copy is kept, VoiceOver says, after the answer, "Replaced “X”. Its earlier text was kept as content.md.edited-…, in the book's package.", with X the book's title and the dots standing for the date and time in the copy's name.
  - An audiobook's transcript comes along only when the new copy's audio is proven to be the same, without reading the audio whole:
    - A book of one audio file that is the very file transcribed, under the same name or another.
    - The same archive or folder imported again, with every audio file at the same path and of the same size.
    - Every audio file the same by path, size, and date.
    - A file only in the cloud proves nothing.
    - A transcript you edited that stays behind, because the audio is not proven the same, leaves its text beside the new copy as a content.md.edited- copy too, and an audiobook that kept its transcript is not offered for transcription afterwards.
  - A BRF or BRL book keeps the braille file characters it is read with (see Book Information, in [The Library window](library-window.md)).
    - When the new copy is the very same file, TextMouth reads it again in those characters if the copy was read in others and its bytes are not certainly Unicode braille patterns.
    - When the copy can't be read so, nothing is replaced, and the question stays, with the reason, as in "“Ledger” can't be read as Eurobraille, six-dot (German-speaking countries): Line 3 holds “é”, which is not Eurobraille. Nothing was changed."
    - A copy with other bytes keeps what its import read.
  - The existing copy's files are removed only once the library holds the new copy, so a stop at any moment leaves the old book whole, or the new copy with everything carried over.
    - An old copy left beside the new one, or put back from the Trash with Finder, is never added to the library as a second book: its package names the book the new copy now is, and the debug log records an ORPHAN_ID_LISTED line for it at the launch that finds it.

## When Replace Existing waits

- Replace Existing waits while the existing copy is in use, while its text is being read again in another encoding (see [The Library window](library-window.md)), while something it would keep is only in the cloud, where nothing is downloaded for it, and while TextMouth moves books between folders or rebuilds its data directory.
- The question stays open, nothing has changed, and the reason appears above its buttons, which VoiceOver reads as "Error: " and the sentence, and speaks once as it appears.
- Once the cause is gone, choose Replace Existing again.
- With X the title of the existing copy, the sentences are:
  - Open in a reader: "“X” is open in a reader. Close it, then choose Replace Existing again."
  - Being transcribed: "“X” is being transcribed, and replacing it now would lose the transcript. Wait until the transcription ends, or cancel it, then choose Replace Existing again."
  - Being exported: "“X” is being exported, and replacing it now would stop the export. Wait until the export ends, then choose Replace Existing again."
  - Its audio being edited in the audio editor, or saved from it: "The audio of “X” is being edited. Close the audio editor, or wait until it has saved, then choose Replace Existing again."
  - Its text being read again in another encoding, from the Text Encoding pop-up in Book Information: "TextMouth is reading “X” again in another encoding. Try again when that finishes."
  - Its text being read again with other braille file characters, from the Braille File Characters pop-up in Book Information: "TextMouth is reading “X” again with other braille file characters. Try again when that finishes."
  - Files only in the cloud: "Some of the files of “X” are only in the cloud, and replacing it now would leave them behind. Download the book, then choose Replace Existing again."
  - Books moving between folders: "TextMouth is moving books between folders. Wait until that finishes, then choose Replace Existing again."
  - The data directory being rebuilt: "TextMouth is rebuilding its data directory. Wait until that finishes, then choose Replace Existing again."

## When a replacement fails

- A replacement that fails leaves the question open with "Could not replace duplicate: " and the reason, and both copies as they were, the new copy as it was imported.
- Two reasons are TextMouth's own words:
  - "TextMouth couldn't keep the edited text of the copy in your library beside the new copy's text, so it left both copies as they are."
  - "TextMouth couldn't save the library's index, so it left both copies as they are."
- Any other failure gives the system's own reason.

## When the replaced copy's files can't be removed

- When the new copy has taken the place of the existing one but the existing copy's files cannot be removed, the replacement stands, and the library's alert says "The new copy took the place of “X”, but the old copy's files could not be moved to the Trash, so they stay in its folder: " and the system's reason, with "deleted" in place of "moved to the Trash" while Move to Trash instead of deleting is off.
- With the Trash off, TextMouth first renames the old package to a hidden name, then deletes it, and what cannot be deleted stays hidden until the next import into that folder removes it.

## A replaced book open in Edit Text

- If the replaced book was open in Edit Text, VoiceOver says, once, "Edit Text has stopped for X, since a new copy replaced it. Choose Edit Text again to edit the new copy's text.", with X the book's title, so that you are not left saving into an editor nothing listens to (see [Editing a book's text](editing-book-text.md)).
- An Edit Manifest session for the replaced book ends without a word.

## The original file after an import

- Storage settings decide what happens to the original file after an import: keep it (the default), delete it, or ask each time.
- A folder imported with Import Folder… is the exception, as described there, and so is an .rtfd, which is a folder too: it is never deleted or offered for deletion.
- When After Importing a Book is set to Delete After Import or Ask Each Time, an alert titled "Book Imported" says "The original file was kept: it is a folder, and an import never deletes a folder.", and the book is added without opening, even if it came from Finder.
- A file inside a book's package, a folder ending in .tmb, or inside TextMouth's data directory is never deleted or offered for deletion, whatever After Importing a Book says: such a file, opened with Show Package Contents and Open With, is a copy of part of a book that is still in the library.
- It is kept with nothing said, and the debug log notes it.

## A ZIP holding a DAISY book with audio

- A ZIP holding a DAISY book with audio imports the book's audio alone, and the archive keeps its text and images, so the archive is kept whatever After Importing a Book says, and an alert titled "Book Imported" says why, as in "The original file was kept: TextMouth imported the audio of “Harbour Pilots” from the archive “pilots.zip”, and the archive is the only copy of its text."
- The archive is kept even when a SMIL file in it is one TextMouth will not parse, such as one with a tag of more than 1,024 attributes (see XML parts TextMouth can't safely read, above). TextMouth still finds the text files that SMIL file names, by reading it as plain text, so it does not take the archive for one with no text and offer it for deletion. Before 0.4.3 it could.
- For a talking book that has no text, in an archive of other books, it says "The original file was kept: TextMouth imported only the DAISY book “Harbour Pilots” from the archive “pilots.zip”." and, when the archive holds other books, adds " The archive also holds 2 other books that were not imported; unzip it to import them.", or, for one, "1 other book that was not imported; unzip it to import it."
- A DAISY ZIP without audio, which is imported whole, and a talking book whose archive holds nothing more, may still be deleted.

## A Markdown book named content.md

- A Markdown book whose file is named content.md keeps its own file: the package stages it as "content (book).md", beside the text cache, which is a different file, so Redo Text Extraction still has the original.

## Offer to transcribe after importing

- With Offer to transcribe after importing an audiobook on, in the Playback tab of Settings, TextMouth asks after each audiobook it imports, on a Mac that can transcribe, whether to transcribe it, after that import's other questions (see [Transcribing an audiobook](transcribing.md)).

## Questions about imports wait their turn

- These questions wait their turn.
- They are asked one at a time, in the order they arose, in the Library window where the import started, or in another Library window if that one has closed.
- When there is more than one, each title gives its place, as in "Duplicate Book Found, 2 of 5".
- Return chooses Keep Both, Create Folder, or Transcribe, and Escape chooses Cancel, Keep, No Thanks, or Not Now.
- Replace Existing and deleting an original file are never on a key.
- A question that appears while you are working in another window, such as a reader, waits in its Library window without taking focus or speaking.

### A duplicate's new copy waits in the library

- A duplicate's new copy waits in the library, in a package marked with a hidden file, .awaitingDuplicateAnswer, until you answer.
- When TextMouth closes with the question unanswered, the next launch moves the copy to the Trash, whatever Settings says about the Trash, and says so in an alert titled "Duplicate Copies Moved to the Trash", as in "TextMouth moved the new copy of “Moby-Dick” to the Trash, because the question whether to keep it as a duplicate was never answered before TextMouth closed. To get it back, open the Trash and choose Put Back."
- For two or three copies it says "TextMouth moved the new copies of “A”, “B”, and “C” to the Trash, because the questions whether to keep them as duplicates were never answered before TextMouth closed. To get them back, open the Trash and choose Put Back.", and for more, "TextMouth moved 4 new copies of duplicate books to the Trash, because the questions whether to keep them as duplicates were never answered before TextMouth closed. To get them back, open the Trash and choose Put Back."
- A copy whose question is less than a day old stays, since another Mac sharing the library may be asking it.
- The file the copy came from is never deleted.

### When Keep Both and Replace Existing keep the question

- Keep Both and Replace Existing keep the question, and say why, when they cannot keep the new copy, each sentence naming the book:
  - While the library can't be reached, as when its drive dropped off: "The library can't be reached right now, so TextMouth can't keep the new copy of “Moby-Dick”. Answer again once the library is back." The copy is intact, so there is nothing to cancel.
  - When the copy's files are gone, taken by another Mac's launch or in Finder: "The files of the new copy of “Moby-Dick” are no longer in the library, so it can't be kept. Choose Cancel, then import the file again." The original file is kept.
  - When Keep Both cannot take the waiting mark off the copy: "TextMouth could not keep the new copy of “Moby-Dick”. Choose Cancel to discard the copy, then import the file again."

### A book opened from Finder

- A book opened from Finder opens once it is in the library and its questions are answered.

### Cancel and the questions

- The progress overlay's Cancel button also withdraws the questions of the imports started before it was pressed, those waiting and any still to come:
  - A duplicate's new copy is discarded.
  - An original file is kept.
  - A ZIP's books stay where they are.
  - An offer to transcribe is dropped.

## Importing audio that TextMouth converts

- Importing audio that TextMouth converts (Ogg, AC-3, and the other formats listed in [What TextMouth reads](what-textmouth-reads.md)) adds a step, Converting its audio, after the archive is extracted and its manifest checked.
- The overlay counts the tracks, as in "converting its audio: 12 of 176 tracks".
- The archive, folder, or file you import from is never changed.
- A track that can't be converted stops the import, and nothing is added.
- The alert says which track and why, as in "Could not import “My Tracks.zip”. Converting its audio failed: Converting 01.ogg was stopped because it used more than 960 seconds of processor time."
- That number is four times the converter's time limit, a minute plus a tenth of the track's length, here for a track of 30 minutes. [Where TextMouth keeps your library](where-your-library-lives.md) lists what else stops the converter.
- Cancel kills the conversions at once, and the import ends as a cancelled one.
- The reasons, with X the track's file name:
  - "The audio file X could not be read for converting." The Mac's tool could not read the file as audio, or the file's header claims a length that its size cannot hold, or more than a year.
  - "The audio converted from X failed its check: ..." and why: the converted file would not play, or lasts a different time from its source, as in "it lasts 12.0 seconds, not 600.0".
  - "The audio converted from X could not be given its name."
  - "Converting X was stopped because ..." and the watchdog's reason: "it ran longer than N seconds", "it held more than N MB of memory", "its output did not grow for N seconds", "it used more than N seconds of processor time", or "its output passed N MB", which is more than four times what the track should come to, and 16 MB more.
  - "Converting X failed (the converter ended with code N)."
  - "There is not enough free disk space to convert X: it needs N GB free." This is said before anything is converted, for audio of more than two channels, which is mixed to stereo through a hidden file of uncompressed sound that must fit on the disk.
  - "The audio file X has N channels but does not say which is which, so TextMouth cannot mix it to stereo."
