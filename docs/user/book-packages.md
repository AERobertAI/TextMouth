# A book's package
<!-- id: book-package; keys: .tmb, package, book folder, bundle; src: TextMouth/Services/TextMouthPaths.swift, TextMouth/Services/FileImportService+Packages.swift -->

Part of [TextMouth's documentation](../../README.md).

## The Library folder and its packages
<!-- id: library-folder-packages; keys: .tmb, package, book folder, library folders; src: TextMouth/Services/TextMouthPaths.swift, TextMouth/Services/FileImportService+Packages.swift -->

Library: your books.
Its folders are the library's folders, and each book is a package: a folder named after the book's title, author, date added, and identifier, ending in .tmb.
A package holds:

## The book's own file
<!-- id: book-own-file; keys: original file, audiobook tracks, DAISY audio, manifest.json; src: TextMouth/Services/FileImportService+Packages.swift -->

The book's own file, under its original name.
An audiobook made of several tracks keeps them in a folder instead; one converted from a DAISY audio ZIP also has a manifest.json listing its sections and the stretches of audio each one plays.

## .convertedOriginals, the originals of converted audio
<!-- id: convertedoriginals-originals-converted; keys: Keep originals, converted audio, Export originals; src: TextMouth/Services/ImportAudioConverter.swift, TextMouth/Models/ConvertedOriginalWording.swift, TextMouth/Services/FileImportService+AudioConversion.swift -->

.convertedOriginals: a hidden folder, present only in an audiobook that was imported while Keep originals of converted audio was on, and whose import converted audio.
It holds each original as it was, under its path from the book's folder of tracks, or by its own name for a single file.
Nothing in TextMouth opens these files; Export copies them out (see [Exporting books](exporting-books.md)).

## bookInfo.json, the book's record
<!-- id: bookinfo-json-book-record; keys: book record, metadata, bookmarks, per-book settings, publisher, ISBN; src: TextMouth/Models/BookInfo.swift, TextMouth/Models/Book.swift, TextMouth/Services/LibraryPersistenceService.swift -->

bookInfo.json: the book's record, with its metadata (for an EPUB, its publisher, publication date, ISBN, language, identifier, and EPUB version, read at import or, for a book imported before TextMouth kept them, the first time a reader opens it;

- for a braille book, the braille table it is read with, such as en-ueb-g2.ctb, or "mac:" and the file name of one of this Mac's tables, such as mac:fr-bfu-g2.ctb, with the liblouis version of this Mac's tables, such as 3.34.0, when it is one of them, all of which its row in library.json holds too),
- which of its metadata fields you edited by hand, reading position, bookmarks, and per-book settings, written within half a second of each change, and every 30 seconds while the book plays.

It can rebuild a book's library entry if library.json is lost.
From 0.5.0 on, TextMouth keeps a key a later TextMouth added to a book's record when it saves the book again.
While a record is only in the cloud, TextMouth neither reads nor writes it, and the book's changes are saved in library.json alone, without waiting, until the record is on this Mac again.
A downloaded episode's or article's record also names its feed and item, as its row in the feed's index does.

### A text book's encoding
<!-- id: text-book-encoding; keys: text encoding, charset, Text Encoding pop-up, textEncoding; src: TextMouth/Models/TextEncodingRecord.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift -->

A plain text, Markdown, or HTML book whose encoding TextMouth guessed when it was added, or whose encoding you chose in Book Information (see [What TextMouth reads](reads-text-files.md)), keeps it in its row and in its record, by name, such as windows-1251, koi8-r, macintosh, or utf-8.
Every later reading of the book's text, a rebuild of content.md included, uses it.
A choice is recorded as chosen, in a second key beside it, textEncodingSource, whose value is "chosen", or "automatic" when you chose Automatic.
A chosen encoding is read whatever the file's bytes say of themselves, and a guessed one only where they name no encoding.

### A braille book's file characters
<!-- id: braille-book-file-characters; keys: BRF, BRL, Braille ASCII, Eurobraille, Unicode braille patterns, ascii-na; src: TextMouth/Models/Book.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift, TextMouth/Services/MarkdownCacheService.swift -->

A BRF or BRL braille book keeps the braille file characters its file is read with in its row and in its record, as brailleFileCode, by the code's id:

- "ascii-na" for North American Braille ASCII,
- "ascii-eurobraille" for Eurobraille, six-dot,
- or "unicode" for Unicode braille patterns (see [What TextMouth reads](reads-daisy-and-braille.md)).

An import records it explicitly, North American's too, and a read of the file again with other characters records the new ones; a PEF records none.
The key is left out when there is none, and a book without it is read as North American Braille ASCII, or as Unicode braille patterns when its first character is a braille pattern.
Every later reading of the book's text, a rebuild of content.md included, uses it.
A TextMouth older than the one that records it ignores the key and drops it at its next save.
When it rebuilds such a book's text, as Redo Text Extraction or a new cache version does, it reads a Eurobraille book as North American Braille ASCII, which gives wrong numbers and punctuation, or refuses a Unicode one and keeps its old text.
Open a library that holds books you set to Eurobraille or Unicode braille patterns only with the TextMouth that set them, or a later one.

### A braille book's guessed code
<!-- id: braille-book-guessed-code; keys: guessed braille code, braille table, Book Information; src: TextMouth/Models/Book.swift, TextMouth/ViewModels/BrailleCodeChoiceModel.swift -->

A braille book whose code TextMouth guessed when the book was added (see [What TextMouth reads](reads-daisy-and-braille.md)) keeps that in its row and in its record, as brailleTableOrigin, whose value is "guessed".
The key is left out for every other book, for books added before TextMouth could guess, and once you choose a code in Book Information or keep the guess, so those books are written exactly as before.
A TextMouth older than the one that records it ignores the key and drops it at its next save, and the book is then read with the same code but no longer said to be guessed.

### Older TextMouths and the encoding keys
<!-- id: older-textmouths-encoding-keys; keys: older version, downgrade, compatibility, Windows-1252; src: TextMouth/Models/Book.swift, TextMouth/Models/TextEncodingRecord.swift -->

A TextMouth older than 0.2.2, 0.1.1 included, does not know the encoding's key or the note's, and drops both from the row and the record when it saves them.
TextMouth 0.2.2 knows the encoding but not the note, and drops the note, so a choice becomes a guess of the same encoding: the book is read as before, unless the choice overrode valid UTF-8, a byte-order mark, or an HTML file's declaration, and Book Information says "guessed".
Once the row and the record have both lost the encoding, nothing can bring it back, so the next time that book's text is rebuilt (content.md, below) it may be read as Windows-1252 again, as it was before TextMouth guessed.
Open a library that holds such books with TextMouth 0.2.2 or later, and one that holds a book you chose an encoding for with TextMouth 0.2.3 or later.

## contentIndex.json, the chapter index
<!-- id: contentindex-json-chapter-index; keys: chapters, headings, word counts, audiobook timing; src: TextMouth/Models/BookInfo.swift -->

contentIndex.json: the index of the book's chapters and headings, with their word counts and, for an audiobook, its timing, written when the book is imported or its content is analyzed again, so saving the book's place never rewrites it.
Earlier versions of TextMouth kept the index inside bookInfo.json: TextMouth moves it out the next time it saves such a book, and an earlier version that opens a book saved since finds no index there and analyzes the book once more.

## content.md, the text cache
<!-- id: library-content-md-text-cache; keys: text cache, Markdown, rebuild, Redo Text Extraction; src: TextMouth/Services/MarkdownCacheService.swift, TextMouth/Models/PageReaderVersions.swift, TextMouth/Services/BookTextEditing.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift -->

content.md: the text cache, the book's text as Markdown, so a text book opens without parsing its source again.
TextMouth rebuilds it when the source file changes or when a newer version of TextMouth reads that format better, but these automatic rebuilds keep text you changed with Edit Text.
Redo Text Extraction, a button in the Storage tab of Settings, rebuilds it on request for every text book (see [Editing a book's text](editing-book-text.md) for what it does to that text).
A choice in a book's Text Encoding pop-up in Book Information rebuilds it for that book alone, in the encoding chosen (see [The Library window](book-information.md)).

### Pages and page markers
<!-- id: pages-page-markers; keys: page break, page label, page number, pagebreak; src: TextMouth/Parsers/MarkdownPageMarker.swift, TextMouth/Parsers/EPUBParser+Navigation.swift, TextMouth/Parsers/DAISYParser+TextExtraction.swift, TextMouth/Models/PageReaderVersions.swift -->

A line such as `<!-- page: 12 -->` in it marks where a page begins (see [Editing a book's text](editing-book-text.md)).
Books already in your library gain their pages at the next launch after an update gives their format pages: TextMouth reads each one's file again, once, and your places follow their words.
Books open in a reader are read first, and each such reader then quietly shows the book's new text with its pages, its cursor on the same words; speech that was playing starts again from the cursor.
An EPUB's page-break element keeps its words: its own text is skipped only when it is no more than its page's label, the page's number and perhaps a caption of up to 32 characters, and any longer or other text in it is read, after its page marker.
An element with no aria-label or title that holds more than that begins no page.
DAISY 2.02 follows the same rule for what a page entry points at.
A Word 6 or Word 95 document, which textutil read until version 0.4.1, with a table of contents or a link got every page, with the words kept apart at each break, where it got only its first page before.

### How the launch that adds pages treats your text
<!-- id: how-launch-that-adds-pages; keys: page upgrade, changed text kept, copy of old text; src: TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/Models/PageReaderVersions.swift, TextMouth/Services/BookTextEditing.swift -->

First it compares the whole of the book's content.md with what the book's file gives.
A book whose text you changed with Edit Text keeps that text, without pages, until Redo Text Extraction, and so does one whose content.md was changed in another editor since TextMouth last wrote it.
Any other book whose content.md differs from what its file gives,

- even only in a heading, a heading's level, or a chapter's title, as an edit made before version 0.2.0 recorded edits may,
- or in a chapter that an EPUB lost by naming its file in another letter case than its ZIP spells it,

is read again with its pages too, once TextMouth has kept a copy of its text beside it as content.md.edited- followed by a date and time (below).
If no copy can be made, the book keeps its text, without pages, and every automatic rebuild keeps it, as it keeps text you changed with Edit Text.
A book whose file is missing keeps its text without pages; one whose file can't be read is tried again at the next launch, then keeps its text without pages; and one whose files are only in the cloud gains its pages at a launch when they're on this Mac.
A Word document older than Word 6, which textutil reads, whose pages textutil couldn't read is tried again at the next launch, then keeps its text without pages until Redo Text Extraction.
The debug log records a PAGES_REPLACED_TEXT line naming each copy kept, a PAGES_SKIPPED_CHANGED_TEXT line for each book that keeps its text, and one PAGES_UPGRADE_SUMMARY line counting the books given pages, replaced keeping a copy, kept as changed, skipped, and failed.

### Rich text and Word books read again
<!-- id: rich-text-word-books-read; keys: .doc, .docx, RTF, OpenDocument, page reader version; src: TextMouth/Models/PageReaderVersions.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift -->

A rich text, rich text with attachments, or Word 97-2003 book was read again once at the first launch of version 0.3.1, when TextMouth's own reader replaced textutil for it, and gained the headings and pages that reader finds.
At the first launch of version 0.4.0, every rich text, rich text with attachments, Word 97-2003, Word, OpenDocument text, and Word 2003 XML book is read again once more, for what the readers now find:

- hidden text and tracked deletions left out,
- footnotes, endnotes, and text boxes read,
- and, for an OpenDocument or Word 2003 XML book, the document's own headings and its pages.

Each is kept or replaced by the rules above, so your place follows its words and text you changed with Edit Text is kept.
At the first launch of version 0.4.1,

- every .doc book is read again once more (its page reader line is 1.3.0), for Word 6 and Word 95 documents, which TextMouth now reads itself, and for the symbols of Word documents,
- and every .docx and .wordml book is read again once more (1.2.0), for the hidden text it now finds: a table style's and the document defaults' hiding in a .docx, and the words of a hidden row in Word 2003 XML.

Each is kept or replaced by the same rules, so your place follows its words and text you changed with Edit Text is kept.

### New books, Edit Text, and transcribed audiobooks
<!-- id: new-books-edit-text-transcribed; keys: new book, your own editor, transcript text; src: TextMouth/Services/BookTextEditing.swift, TextMouth/Platform/macOS/Services/BookTextEditor.swift, TextMouth/Services/TranscriptTextLoader.swift -->

A book you add, or whose text is rebuilt for another reason, gains its pages as its text is read.
Edit Text opens it in your own editor, and TextMouth takes what you save while it's open (see [Editing a book's text](editing-book-text.md)).
A transcribed audiobook's content.md holds its transcript's text instead (see transcript.json, below).

### Braille, plain text, EPUB, and HTML books read again
<!-- id: braille-plain-text-epub-html; keys: read again, page number, heading names, braille emphasis; src: TextMouth/Models/PageReaderVersions.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift -->

The first launch of version 0.2.2 reads every braille, plain text, EPUB, and HTML book again, once, in the way just described.
Braille and plain text books gain their pages.
An EPUB or HTML book loses the number of a page break from the name of any heading that held one.
A braille book is read with that version's better reading of emphasis and of some words (see [What TextMouth reads](reads-daisy-and-braille.md) and [Reader windows](reader-windows.md)).
A braille book whose new reading differs from its text, by its words or by its emphasis alone, as one whose braille holds emphasis signs may, keeps a copy of its old text beside it, as any book whose content.md differs from what its file gives does.
An EPUB or HTML book that has its pages already is read again without that comparison, and keeps no copy.
A book's places follow its words in every case.

### DAISY books read again
<!-- id: daisy-books-read-again; keys: DTBook, DAISY 3, page entries; src: TextMouth/Models/PageReaderVersions.swift, TextMouth/Parsers/DAISYParser+TextExtraction.swift -->

The first launch of version 0.4.7 reads every DAISY book again, once, in the way just described: only a DAISY 3 book of several DTBook files, with a page that holds no words, ends with another text (see [What TextMouth reads](reads-pages-and-limits.md)).

## content.md.edited- copies of text
<!-- id: content-md-edited-copies-text; keys: kept copy, backup of text, edited text, Edit Text; src: TextMouth/Services/BookTextEditing.swift, TextMouth/Models/BookTextEditWording.swift, TextMouth/Services/TextMouthPaths.swift -->

content.md.edited- followed by a date and time: a copy of text in content.md that Edit Text couldn't take, or that TextMouth replaced,

- reading the text again from the book's own file (Redo Text Extraction and a choice in a book's Text Encoding pop-up do this over text you changed with Edit Text, after keeping it here,
- and so does the launch that gives books their pages, over text that differs from the book's file but that no record of Edit Text names)
- or, for a transcribed audiobook, writing it again from the transcript.

TextMouth never reads these copies, and Delete Transcript leaves them; delete them when you no longer need them.

## transcript.json, an audiobook's transcript
<!-- id: transcript-json-audiobook-transcript; keys: speech recognition, word timings, confidence, Transcribe Audio; src: TextMouth/Models/Transcript.swift, TextMouth/Services/TranscriptStore.swift, TextMouth/Services/TranscriptTextLoader.swift, TextMouth/Services/TranscriptInstallation.swift -->

transcript.json: an audiobook's transcript, present once the book has been transcribed:

- the language,
- the recognizer and its model,
- the version of TextMouth,
- the date,
- the date of your last edit of it, once you have edited it,
- its last cleanup, once it has been cleaned up (when, whose rules, their version and date, and how many corrections),
- and, for each audio file, its fingerprint (its size, modification time, and digest) and every sentence heard in it, with each word's start and end in milliseconds and the recognizer's confidence.

TextMouth writes the book's content.md from it, a heading for each chapter and a paragraph for every few sentences.
TextMouth writes content.md again from it when the book next opens if content.md is missing or holds text TextMouth didn't write or take, which it first keeps beside content.md as content.md.edited- followed by a date and time, or if a newer version of TextMouth writes it differently.
The transcript itself changes only when the book is transcribed again, Edit Text takes an edit of its text, or a cleanup is applied or undone, and Delete Transcript deletes it.
- One whose audio file has changed since it was made is kept, but its text is no longer shown;
- one written by a later version of TextMouth, as on another Mac sharing the library, is left as it is, unread;
- and one that can't be read is kept beside itself as transcript.json.unreadable- followed by a date and time.

## transcript.json.before-cleanup
<!-- id: transcript-json-before-cleanup; keys: Undo Cleanup, Clean Up Transcript, previous transcript; src: TextMouth/Services/TranscriptCleanupStore.swift -->

transcript.json.before-cleanup: the transcript as it was before its last cleanup, which Undo Cleanup puts back and removes.
The next cleanup replaces it, and Delete Transcript deletes it.

## origin.json, a recording's origin
<!-- id: origin-json-recording-origin; keys: recording details, microphone, original take, original audio policy; src: TextMouth/Models/BookOrigin.swift, TextMouth/Models/AudioOriginalPolicy.swift -->

origin.json: only in a recording's package:

- when the recording started,
- how long it lasts,
- the microphone it was recorded from,
- and, until the book's audio is first edited, whether its original take is kept, with when the book's audio was last made from it, which the original audio policy counts from;
- after that, audioEdits/edits.json (below) records the take instead.

Earlier versions of TextMouth leave it alone.

## original-take.caf, a recording's original take
<!-- id: original-take-caf-recording-original; keys: lossless, CAF, original audio policy, unedited recording; src: TextMouth/Models/BookOrigin.swift, TextMouth/Models/AudioOriginalPolicy.swift, TextMouth/Services/FileImportService+Recording.swift -->

original-take.caf: a recording's original take, lossless, for as long as the original audio policy keeps it (see [Editing audio](editing-audio.md)).

## audioEdits, the audio editor's folder
<!-- id: audioedits-audio-editor-folder; keys: edit history, punch-in, markers, original audio, takes; src: TextMouth/Services/AudioEditing/AudioEditPackage.swift, TextMouth/Services/AudioEditing/AudioEditHistoryStore.swift, TextMouth/Models/AudioEditList.swift -->

audioEdits: present once a book's audio has been edited, or a marker dropped in its editor:

- edits.json, the edit history of each of its audio files, with the editor's markers, and the book's own original policy;
- originals, the original audio of an imported book's files, for as long as the policy keeps it;
- and takes, the new takes of punch-ins and the audio pasted or recorded at the cursor, as Apple Lossless when that loses nothing.

A history that can't be read is kept beside itself as edits.json.unreadable- followed by a date and time; one written by a later version of TextMouth is left alone.
Earlier versions of TextMouth leave the folder alone.

## removedFromLibrary.json
<!-- id: removedfromlibrary-json; keys: Remove from Library Only, add back, kept package; src: TextMouth/Models/RemovedFromLibraryMarker.swift, TextMouth/Services/FileImportService+Packages.swift, TextMouth/Services/DuplicateReplacement.swift -->

removedFromLibrary.json: present only when you chose Remove from Library Only.
It keeps the package on disk without the book returning to the library.
For a braille book it also keeps its braille table, and the liblouis version of this Mac's tables when it is one of them, so the book reads as before when it is added back, and a braille book whose code was guessed keeps that too, so it is still said to be guessed.
A text book whose encoding was guessed or chosen keeps that encoding, and who decided it, too, for the same reason, and a BRF or BRL book keeps its braille file characters.
A book added back from such a package keeps the text its package holds: when reading the book's file would write other text over content.md, TextMouth first keeps content.md as content.md.edited- followed by a date and time, and says "The text of Harbour Pilots was read again from its own file.
The text content.md held before was kept as content.md.edited-20261004T123012Z, in the book's package."
A marker written before markers carried an edit record gets the same, and a package of a book edited with Edit Text imports with its edit kept.
When no copy can be kept, adding the book back stops with "Harbour Pilots was not added back: no copy of the text its package held could be kept first, so TextMouth left the text as it was."

## .storeCopy.json, a book's pointer to the sync folder
<!-- id: storecopy-json; keys: placeholder, pointer, In Cloud, library sync, sync folder; src: TextMouth/Services/SyncPlaceholder.swift, TextMouth/Models/Sync/SyncInterfaces.swift -->

.storeCopy.json: present only in a library that syncs (see [Syncing your library between your devices](syncing-your-library.md)).
It names the book's copy in the sync folder and which of its files are on this device.
A book another device added, and this one hasn't downloaded, is a package of only its record and this pointer, and shows In Cloud.
Its leading dot keeps it out of export and out of the files a book is said to have.

## .import- folders, imports in progress
<!-- id: import-folders-imports-progress; keys: import staging, interrupted import, leftover folder; src: TextMouth/Services/ImportStaging.swift -->

A folder whose name starts with .import- is an import in progress.
Imports build their packages here only while the data directory is on another drive than this Mac's own folders (see [Folders of this Mac's own](this-macs-folders.md)), and otherwise in this Mac's Import Staging folder.
Nothing else in TextMouth treats such a folder as a book.
The next import into the same library folder removes one that an interrupted import, or an earlier version, left behind, and each import that builds in this Mac's folder clears what interrupted imports left there.

## .awaitingDuplicateAnswer
<!-- id: awaitingduplicateanswer; keys: duplicate question, Keep Both, Replace Existing; src: TextMouth/Services/DuplicateReplacement.swift -->

A hidden file named .awaitingDuplicateAnswer marks the package of a duplicate's new copy while its question, Keep Both or Replace Existing, waits for an answer (see [Adding books](duplicate-books.md)).
Keep Both and Replace Existing take it off, and no walk of the library adopts a package that holds it; a package copied into the library with the mark still on is imported without it.
