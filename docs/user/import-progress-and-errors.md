# Import progress and errors
<!-- id: import-progress-errors; keys: import overlay, refusals, errors, alert wording; src: TextMouth/Models/ImportProgressWording.swift, TextMouth/Services/ImportFailure.swift -->

Part of [TextMouth's documentation](../../README.md).

How books are added is in [Adding books](adding-books.md).

## The import overlay
<!-- id: import-overlay; keys: progress overlay, Importing Books, ImportProgress, VoiceOver reads; src: TextMouth/ViewModels/ImportProgress.swift, TextMouth/Models/ImportProgressWording.swift -->

- While books import, the import overlay in the Library window shows how far the import has got, and VoiceOver reads all of it there.

### What the overlay says
<!-- id: what-overlay-says; keys: Extracting, items and bytes, books processed, step, checking the package; src: TextMouth/Models/ImportProgressWording.swift, TextMouth/ViewModels/ImportProgress.swift -->

- For a ZIP archive the overlay first counts the items and bytes extracted, as in "Extracting “Library Export.zip”: 120 of 300 items, 1.2 GB of 3.4 GB...".
- It then counts the books processed, as in "2 of 100 books processed", with the book under way, by its name in the archive, and the step it is at, as in "Book 3 of 100: “Moby Dick.epub”, reading its text".
- A single file, or a ZIP holding one book, shows its name and its step the same way, as do a TextMouth package opened from the Finder, from "checking the package" on, and a book made with New from Text, by the title you typed.
- A package's line says "copying it into the library" while it copies.
- A picture or comic book archive of several pages counts them as it reads their text, as in "reading its text: 3 of 12 pages", and Cancel stops it before the next page.
- A picture or archive with no text is refused with "No text was found in this picture." or "No text was found in the one picture of this comic book archive.", and one of several pages says "No text was found on any of the 3 pages of this picture."
- When some pages can't be read, the alert says so, as in "Text recognition could not read 1 of 12 pages: page 3 (its picture could not be decoded)."
- A picture that is too large is refused as in "This picture is 12,000 by 12,000 pixels, larger than the 100 megapixels TextMouth reads in one picture."
- A picture that is not one is refused with "This file could not be read as a picture.
  It may be damaged, or another kind of file."
- An archive that is not a comic is refused with "This file could not be read as a comic book archive.
  It may be damaged, or another kind of file."
- An archive with no pictures is refused with "This comic book archive holds no pictures TextMouth can read."
- The debug log notes a page file that could not be read as COMIC_ZIP_ERROR.
- A recording saved from the New Recording window is named by its title the same way, its line going quietly once the save ends, since its window says how the save ended.
- The count's noun agrees with the total, as in "0 of 1 book processed", as it does in the overlay of a text cache update or of Redo Text Extraction, as in "0 of 1 book extracted".
- A ZIP holding one audiobook also counts the items and bytes extracted while it extracts, as in "“Harbor Talks.zip”, extracting the archive: 12 of 30 items, 120 MB of 340 MB".

### Time and waiting imports
<!-- id: time-waiting-imports; keys: time left, estimate, TimeLeftEstimate, more imports waiting, stuck book; src: TextMouth/Models/TimeLeftEstimate.swift, TextMouth/Models/ImportProgressWording.swift -->

- Once a book of several is done, the overlay gives the time left, as in "About 4 minutes left" or "Less than a minute left".
- It weighs each book still to come by its size where that tells its time, as an EPUB's, PDF's, Word document's, or text file's does, so a large book still to come counts for more, while an audiobook's file, a DAISY book, or an .rtfd folder counts at the average time such books took.
- When more imports wait behind the one shown, the overlay says how many, as in "2 more imports waiting", until Cancel is pressed.
- Once a book has taken 10 seconds, the overlay says for how long, as in "1 minute, 5 seconds on this book", in steps of 5 seconds, so a stuck book shows as a time growing on one step.

### What VoiceOver hears
<!-- id: what-voiceover-hears; keys: announcement, quarter, Finished importing, spoken progress; src: TextMouth/Models/ImportProgressWording.swift, TextMouth/ViewModels/ImportProgress.swift -->

- For an import that runs 10 seconds or more, VoiceOver also hears, wherever you are, each quarter of a ZIP's books, as in "Importing “Library Export.zip”: 25 of 100 books processed, about 4 minutes left."
  And how it ended, as in "Finished importing “Library Export.zip”: 97 books imported, 2 skipped as duplicates, 1 failed."

### The Nothing Imported alert
<!-- id: nothing-imported-alert; keys: Already in Library, No books were found, archive holds, alert title; src: TextMouth/Models/ImportProgressWording.swift, TextMouth/ViewModels/LibraryViewModel+Import.swift -->

- A ZIP import that brings no new book, and in which nothing failed, says what it found in the Library window's alert, titled Nothing Imported, however quickly it ends: "No new books in “Library Export.zip”: all 24 were already in your library."
  ("both" for two, and "its one book" for one).
- For an archive holding no book TextMouth reads, the alert says what the archive holds instead, most files first, as in "No books were found in “Docs.zip”.
  It holds 176 .exe files, which TextMouth does not import."
- Up to three kinds are named, the rest counted as other files.
- A kind with advice adds its sentence once, after the ones that name the files.
  A single refused file gets the same sentence after "Unsupported file format".
  A folder named like a refused kind, such as an old Pages package, gets it too.
  - Pages: "Export Pages documents from Pages as Word documents or EPUB books, then import those."
  - Keynote and Numbers: "Export Keynote presentations from Keynote as PDF files, then import those." and "Export Numbers spreadsheets from Numbers as PDF files, then import those."
  - WordPerfect (.wpd, .wp): "Save WordPerfect documents as Word or HTML files in a program that reads them, such as LibreOffice, then import those."
  - Compiled HTML Help (.chm): "Convert Compiled HTML Help files to HTML files or PDF files, then import those."
  - DjVu (.djvu, .djv): "Convert DjVu documents to PDF files, then import those."
  - XPS (.xps, .oxps): "Convert XPS documents to PDF files, then import those."
  - RAR comics (.cbr): "Repack the pages of RAR comics as CBZ comics, then import those."
  - Other RAR archives (.rar): "TextMouth does not open RAR archives.
    Unpack them, then import what they hold."
  - Copy-protected audio (.aa, .aax, .aaxc, .m4p): "TextMouth cannot open copy-protected files."
- The alert waits on screen, and VoiceOver reads it as it appears, so it is never missed as an announcement made while you were in another app could be.
- One with a failure says so in its alert instead.

### Cancel and speaking the overlay
<!-- id: cancel-speaking-overlay; keys: Cancelling, Speak Import Progress, No import is under way, Information shortcut; src: TextMouth/Models/ImportProgressWording.swift, TextMouth/App/MenuCommands.swift, TextMouth/ViewModels/ImportProgress.swift -->

- Cancel says at once "Cancelling after this book...", or "Cancelling..." before the first book.
- The alert of a cancelled import says where it stopped.
- Library menu, Speak Import Progress has VoiceOver speak the overlay's lines on request, or say "No import is under way."
- Give it a key in the Shortcuts tab of Settings, under Information, to use it in every window but an audio editor's, a reader's included (see Works in, under the Shortcuts tab).

## When an import fails
<!-- id: when-import-fails; keys: Could not import, IMPORT_FAILED, step that failed, error alert, ImportFailure; src: TextMouth/Services/ImportFailure.swift, TextMouth/ViewModels/LibraryViewModel+Import.swift -->

- When an import fails, an alert names the file, the step that failed, and why, as in "Could not import “notes.md”.
  Reading its text failed: This file has no text to read."
- Nothing is added to the library, and the original file stays where it was, whatever Storage settings say about originals.
- A ZIP batch lists each failed file by name with the same reason after it, while the batch's other books import, and the debug log records the same words in an IMPORT_FAILED line.
- These reasons have plain words of their own:

### A file with no text to read
<!-- id: adding-books-file-no-text-read; keys: empty file, blank book, no text, silent book, whitespace only, Checking its format; src: TextMouth/Services/FileImportService.swift -->

- A plain text, Markdown, HTML, web archive, SSML, rich text, Word (.docx, and its templates and macro documents), Word 97-2003, OpenDocument, Word 2003 XML, Kindle, or braille file, or a DTBook on its own, with no text in it is refused with "This file has no text to read."
- That covers a file of no bytes, a file of only white space or only a byte-order mark, an HTML file or a web archive of only markup, a document of only empty paragraphs, an SSML file of only markup, and a braille file of only blank lines or one that translates to nothing but white space.
  So no silent, empty book is added.
- A Markdown file that is only a heading still imports.
- An .xml file of no bytes or only white space is refused the same way, but at the step "Checking its format", as in "Could not import “empty.xml”.
  Checking its format failed: This file has no text to read."
- Open Book…, Finder, and the files inside a ZIP are checked.
  New from Text… and the rebuilding of a book already in the library are not.

### A disk without room
<!-- id: disk-without-room; keys: free space, disk full, ENOSPC, reserve 1 GB, APFS clone, folder of tracks; src: TextMouth/Services/ImportFailure.swift, TextMouth/Services/ArchiveBudget.swift, TextMouth/Services/FileImportService.swift -->

- A disk without room for the book is reported as "There isn’t enough free space on the disk.", as in "Could not import “Middlemarch.epub”.
  Copying it into the library failed: There isn’t enough free space on the disk."
- The words never name the hidden package the import was building.
- A folder of tracks or a playlist is checked before the first track is copied: TextMouth adds up the tracks' sizes and refuses the import unless the disk would keep its reserve of 1 GB free (the one the archives use) once they were copied, with the same sentence and nothing written.
  A track on the same APFS disk as the library counts as nothing, since the copy shares its bytes with the original, so a big folder on the library's own disk is not refused for room its copy will not take.

### Audio whose samples TextMouth can't decode
<!-- id: audio-samples-cannot-decode; keys: 64-bit, floating-point, WAVE, CAF, AIFF, samples, Convert it; src: TextMouth/Models/AudioSampleForm.swift, TextMouth/Parsers/AudioMediaProbe.swift, TextMouth/Services/ImportAudioConverter.swift, TextMouth/Services/AudioFileInfo.swift, TextMouth/Services/FileImportService.swift -->

- A valid audio file whose samples are stored in a form that no decoder on the Mac reads is not called damaged: it is refused with its form, as in "“Talk.wav” uses 64-bit integer samples, which TextMouth can't play.
  Convert it to 16-bit or 24-bit integer samples, then import it again."
- The refused forms are integers deeper than 32 bits (33, 40, 48, and 64) and floating-point samples of 16 or 24 bits, which the sentence names as "16-bit floating-point".
  Integers of 8, 12, 16, 20, 24, and 32 bits and floating-point samples of 32 and 64 bits import.
- A WAVE, AIFF, or CAF file imported by itself, as a track of a book, or to be converted says the same.
- The form is named only after the file has failed to decode, so a Mac that reads it imports it.
- A file that is damaged, or whose header names no believable depth, still hears the damage sentence.
- An 8-bit or a 128-bit floating-point CAF file does not open as audio at all, and says "The audio file X could not be read for converting."
- The iPhone gives a WAVE or AIFF file this sentence, and a CAF file there still says "Converting this kind of file isn't available on iPhone yet."

### Documents TextMouth's own readers can't read
<!-- id: documents-textmouth-own-readers-cant; keys: rtf, rtfd, Word 97-2003, OpenDocument, Word 2003 XML, textutil, damaged, unreadable; src: TextMouth/Services/TextutilConverter.swift, TextMouth/Parsers/TextutilSourceCheck.swift -->

- A rich text, rich text with attachments, Word 97-2003, OpenDocument, or Word 2003 XML document that TextMouth's own reader can't read, and, on the Mac, a Word document older than Word 6 that textutil can't read, is refused with a sentence that names its kind, as in "Could not import “Letter.doc”.
  Reading its text failed: This file could not be read as a Word 97-2003 document.
  It may be damaged, or another kind of file."
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
<!-- id: documents-ios; keys: iPhone, iOS, helper program, Word 6, Word 95, not available on iPhone; src: TextMouth/Platform/iOS/IOSUnavailable.swift, TextMouth/Platform/iOS/Services/WatchedProcess+iOS.swift, TextMouth/Parsers/WordDocumentReader.swift -->

- On iOS, which runs no helper program, a Word document older than Word 6 is refused with "Converting this kind of file is not available on iPhone yet."
- Rich text, rich text with attachments, Word 6 to Word 2003 documents, OpenDocument text, and Word 2003 XML are read there, as on the Mac.
- A Word 6 or Word 95 document has been read there since version 0.4.1.
- A Word 6 or Word 95 document is told from a Word 97-2003 one by its own bytes.

### An OpenDocument text document's title and author
<!-- id: opendocument-text-document-title-author; keys: .odt, .ott, author Unknown, dc:creator, textutil lost author; src: TextMouth/Parsers/ODTDocumentReader.swift -->

- An OpenDocument text document's title and author come from the document's own information.
- Apple's textutil lost an .odt's author, so a book of that kind added before version 0.4.0 shows the author Unknown.
- The library does not change an author it has, but importing the file again with Replace Existing gives the book the author the file names, where you edited neither (see [Duplicate books and Replace Existing](duplicate-books.md)).

### A document older than Word 6 that textutil was stopped on
<!-- id: document-older-than-word-6; keys: textutil limit, watchdog, 31 seconds, 1024 MB, 121 seconds, Word 1, Word 2; src: TextMouth/Services/TextutilConverter.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift -->

- On the Mac, a Word document older than Word 6 that textutil was stopped on, for passing one of its limits (see [Where TextMouth keeps your library](helper-programs.md)), says why: "TextMouth stopped reading this document because it ran longer than 31 seconds."
- The reason can instead be "it held more than 1024 MB of memory" or "it used more than 121 seconds of processor time".
- The 31 seconds are the 30 allowed and one more for each million bytes of the document, rounded up, here for a small document, and the 121 are four times the time allowed.
- Every other kind of document, Word 6 and Word 95 since version 0.4.1 among them, is read inside TextMouth, never by textutil, and is not stopped this way.

### Documents protected by a password
<!-- id: documents-protected-password; keys: encrypted, password, locked PDF, Save a copy without the password; src: TextMouth/Parsers/TextutilSourceCheck.swift, TextMouth/Parsers/WordDocumentReader.swift, TextMouth/Parsers/PDFTextParser.swift, TextMouth/Parsers/EncryptedArchive.swift -->

- A Word 97-2003 document (a Word 6 or Word 95 one too) or an OpenDocument document protected by a password is refused with "This document is protected by a password.
  Save a copy without the password, then import that copy."
- A PDF, a Word (.docx) document, or a ZIP-based book (EPUB, DAISY, comic archive, KFX) that a password protects is added locked.
  On the Mac one panel first asks for the password of every protected book in the list, with Unlock and Import Locked; the iPhone adds them locked.
  A locked book's row says "Locked".
  Opening it asks for the password, unless a remembered one fits; Remember this password keeps it in this device's Keychain, and Remove the password from this book rewrites the book's own file without it.
  While it is open nothing of its text is written to disk: no text cache, headings, search text, or saved words, and its sections cannot be skipped.
  A PDF that only restricts copying or printing is not locked and imports as usual.
- A ZIP archive whose files a password protects, when it holds several books, is refused with "This ZIP archive is protected by a password." and the names of the files it could not read.
  7z and RAR archives, and protected audiobooks, are not opened.

### A Word document's title and author
<!-- id: word-document-title-author; keys: .docx, core properties, dc:title, dc:creator, Unknown; src: TextMouth/Parsers/DOCXParser+Metadata.swift -->

- A Word document's (.docx) title and author come from the document's core properties, its title and its creator.
- A title that the properties leave empty, or hold only spaces, is not a name: the book takes the file's name, as a document with no properties does.
- A creator left empty is not a name either: the author is "Unknown", as for a document with no creator at all.

### XML parts TextMouth can't safely read
<!-- id: xml-parts-textmouth-cant-safely; keys: XXE, DOCTYPE, entities, UTF-7, too many attributes, DOCX_ZIP_ERROR, EPUB_ZIP_ERROR; src: TextMouth/Parsers/XMLInputGuard.swift, TextMouth/Parsers/ArchiveEntryReader.swift -->

- A Word document, an EPUB, a DAISY book, or an SSML file with a part TextMouth can't safely read is refused, naming the part, in one of three sentences.
- Before TextMouth reads a part, it checks the part's raw bytes, which no real file in its collection fails.
- For an EPUB, the parts checked are its XML files, such as its container, package document, and navigation files.
  Its chapters are read as web pages.
- The three sentences are:
  - A part with a tag of more than 1,024 attributes is damaged, as in "The file “word/document.xml” in this document is damaged or incomplete: it has a tag with too many attributes for TextMouth to read safely.
    Get a fresh copy of the document, then import it again."
    - The container is "this document" for a Word document, "this EPUB book" for an EPUB, or "this DAISY book" for a DAISY book.
    - An SSML file says "This SSML file is damaged or incomplete: it has a tag with too many attributes for TextMouth to read safely."
    - A tag's length is not limited, only its attributes.
  - A part of the ZIP archive that cannot be unpacked is damaged in the same words (0.4.3), with the reason that its data cannot be read: "The file “word/document.xml” in this document is damaged or incomplete: its compressed data could not be decoded.
    Get a fresh copy of the document, then import it again."
    - The reason is "its compressed data could not be decoded" for a compressed part, and "its data could not be read" for a stored one.
    - A DAISY book says "in this DAISY book" and "Get a fresh copy of the book", and an EPUB says "in this EPUB book", with the same reasons.
    - The ZIP library's own error goes to the debug log, in a line that begins DOCX_ZIP_ERROR, DAISY_ZIP_ERROR, or EPUB_ZIP_ERROR, with the part's name inside the archive and no path on this Mac.
    - A write that fails while a DAISY file is copied, such as a full disk, is not called damage.
      It is reported as the error it is.
  - A part that defines entities of its own in its document type declaration (an internal subset, in square brackets) is refused: "TextMouth can't safely read the file “word/document.xml” in this document, because it defines entities of its own.
    Open the document in the program that made it, save it again, then import it again."
    - An EPUB or DAISY book says "this EPUB book" or "this DAISY book" and "Open the book in the program that made it".
    - An SSML file says "TextMouth can't safely read this SSML file, because it defines entities of its own.
      Open it in a text editor, take the entity definitions out, save it, then import it again."
    - A document type that only names an external one, as DAISY and NCX files do, is read.
  - A part written in an encoding other than UTF-8, UTF-16, UTF-32, US-ASCII, ISO-8859, Windows-1250 to 1258, KOI8-R, KOI8-U, Macintosh, Shift_JIS, EUC-JP, EUC-KR, GB2312, GBK, GB18030, or Big5 (or an alias of them) is refused.
    "TextMouth can't safely read the file “word/document.xml” in this document, because it is written in the UTF-7 encoding.
    Save it as UTF-8, then import it again."
    - An SSML file says "TextMouth can't safely read this SSML file, because it is written in the UTF-7 encoding.
      Save it as UTF-8, then import it again."
- An OpenDocument or Word 2003 XML document is refused for any of these three with the one sentence of its kind, as in "This file could not be read as an OpenDocument text document.
  It may be damaged, or another kind of file.", and a PEF braille file with "This file could not be read as a PEF braille file.
  It may be damaged, or another kind of file."
- A Word 2003 XML or OpenDocument document that declares a document type at all is refused too.

### Markup TextMouth can't safely read
<!-- id: markup-textmouth-cant-safely-read; keys: MarkupGuard, nesting, 128 levels, 1,000 attributes, memory, far too long; src: TextMouth/Parsers/MarkupGuard.swift -->

- Before TextMouth reads the markup of an EPUB chapter, an HTML file, a DAISY book, a Kindle book, or a web archive's page, it looks through it once.
  A Word, rich text, or OpenDocument document passes through the same look, in the HTML its reader writes.
  Markup that would crash TextMouth or fill the Mac's memory is refused, with one of four sentences that never call the file damaged, since it may not be.
- Markup nested thousands of levels deep, a document of millions of tags, and a broken declaration used to be able to stop TextMouth.
  No real book tried is refused for any of them.
- The four sentences, as an alert gives them after "Could not import “x”.
  Reading its text failed: ":
  - Markup nested too deeply, more than 128 levels (a Markdown file's block quotes and lists count too, since 0.4.7: a .md or .txt file of five thousand ">" marks is refused with this sentence and nothing is added to the library).
    "This file's markup nests more than 128 levels deep, which TextMouth can't read safely.
    Get another copy of the file, or save it in another format, then import it again."
  - Too much markup in one document, more than 1,000,000 units of memory, a unit being about 800 bytes of the tree TextMouth builds: "One document in this file has too much markup for TextMouth to read in memory.
    Divide the document into smaller files, then import them."
  - Too many attributes on one tag, more than 1,000: "One tag in this file has more than 1,000 attributes, which TextMouth can't read safely.
    Get another copy of the file, or save it in another format, then import it again."
  - Markup built so that reading it would take far too long: "This file's markup would take TextMouth far too long to read.
    Get another copy of the file, or save it in another format, then import it again."
- The deepest real book nests 12 levels, and the deepest web page tried 36.
  The biggest real document, a whole dictionary as one 32 MB HTML file, uses under half the memory limit.
  No real tag has more than 7 attributes.
- An EPUB with a chapter that is refused reads its other chapters, and the report of the book names the chapter that was left out, as in chapter 2 (“OEBPS/ch02.xhtml”) "has markup that could not be read".
  If it is the only chapter, the EPUB's own sentence about a chapter that could not be read says so, not one of the four.
- A broken declaration in the markup, such as `<?a>` or a torn `<?xml version="1.0"`, is read as nothing, with the words around it, and no sentence is spoken.
- A feed gives no sentence.
  A page that a feed address was looked for in, an article's web page, and a title or summary in a feed are passed over when they pass a limit.
  No feed is found on that page, an article's book holds the feed's own text, a title is kept as it was written, and the markup of an item that passes a limit reads as no text.
  Feed discovery reads a page nested up to 512 levels deep, deeper than a book, since it converts nothing.

### Documents past the 64 MB limit
<!-- id: documents-past-64-mb-limit; keys: size limit, too large, 64 MB, DocumentByteLimit; src: TextMouth/Parsers/DocumentByteLimit.swift -->

- A document, web archive, SSML file, DTBook, or Kindle book past the limit of 64 MB (see [What TextMouth reads](reads-pages-and-limits.md)) is refused with "This document holds more than 64 MB, the most TextMouth reads from one document."
- For a rich text document the 64 MB counts the rich text file, or an .rtfd's TXT.rtf alone, whatever its attachments hold.
- For a Word 97-2003 document it counts the Word file.

### Web archives that can't be read
<!-- id: web-archives-that-cant-be; keys: .webarchive, not a web page, image/png; src: TextMouth/Parsers/WebArchiveReader.swift -->

- A web archive that can't be read as one is refused with "This file is not a web archive TextMouth can read.
  It may be damaged, or another kind of file."
- One whose main file is not a page or text says "This web archive holds a file of the type “image/png”, not a web page or text, so it has nothing to read.", naming the type the archive gives.

### SSML files that can't be read
<!-- id: ssml-files-that-cant-be; keys: SSML, speak element, damaged, line and column; src: TextMouth/Parsers/SSMLReader.swift -->

- An SSML file that begins with another element is refused with "This file is not SSML: it begins with the element “html”, not “speak”.", naming that element.
- One whose markup is broken is refused with "This SSML file is damaged or incomplete: " and how and where, as in "its markup breaks off early or has extra content after the end (line 1, column 27)."

### XML files of no known kind
<!-- id: xml-files-no-known-kind; keys: .xml, DTBook, Word 2003 XML, PEF, Checking its format; src: TextMouth/Services/FileImportService.swift, TextMouth/Parsers/XMLDocumentSniffer.swift -->

- An .xml file that is not a DTBook, Word 2003 XML, or a PEF braille file is refused before anything is copied, at the step "Checking its format", as in "Could not import “catalog.xml”.
  Checking its format failed: This XML file is not a DTBook book, a Word 2003 XML document, or a PEF braille file, the only XML TextMouth reads."

### Kindle books that can't be read
<!-- id: kindle-books-that-cant-be; keys: MOBI, AZW, AZW3, KF8, DRM, copy-protected, damaged; src: TextMouth/Parsers/MOBIError.swift, TextMouth/Parsers/MOBIParser.swift -->

- A Kindle book that can't be read is refused with a sentence that says why, as in "Could not import “Ferry Notes.mobi”.
  Reading its text failed: This Kindle book is copy-protected, and TextMouth can't read copy-protected books."
- The sentences are:
  - For a copy-protected book: "This Kindle book is copy-protected, and TextMouth can't read copy-protected books."
    This is checked first, so no part of such a book's text is read.
    A file that holds both MOBI 6 and KF8 is checked in both halves.
  - For a book whose text is compressed in a way TextMouth does not know: "This Kindle book is compressed in a way TextMouth can't read yet."
  - For a book that stops short or contradicts itself, as one whose download broke off does.
    "This Kindle book is damaged or incomplete: ", what is wrong, and "Get a fresh copy of the book, then import it again.", as in "This Kindle book is damaged or incomplete: its text records hold 4096 bytes of the 68150 it says the text has.
    Get a fresh copy of the book, then import it again."
  - For a file named as a Kindle book that is not one: "This file is not a Kindle book that TextMouth can read."
  - For a book with no words in it: "This file has no text to read."
- A KF8 book (an .azw3) imports like any other Kindle book.
- A file that holds both MOBI 6 and KF8 whose KF8 half is damaged is read from its MOBI 6 half and imports.
  Only a copy-protected book is refused for it.

### KFX Kindle books that can't be read
<!-- id: kfx-kindle-books-that-cant; keys: KFX, KPF, Kindle Create, fixed layout, print replica, DRM, sidecar; src: TextMouth/Parsers/KFXError.swift, TextMouth/Parsers/KFXPackage.swift -->

- A KFX Kindle book that can't be read is refused with a sentence that says why.
- A copy-protected book, a damaged one, and a file named as a Kindle book that is not one get the sentences above.
- The others are:
  - For a book with no flowing text to read, such as a fixed-layout book, a print replica, a comic, a magazine, a children's book, a textbook, a notebook, or a book of only pictures: "This Kindle book has no flowing text, as in a comic or print replica, so TextMouth can't read it."
  - For a Kindle Create package (.kpf), the file an author makes before a book is published: "This file is a Kindle Create package, which TextMouth can't read yet."
  - For a file that holds only a part of a Kindle book, such as the metadata file that sits beside it: "This file holds only part of a Kindle book.
    Open the book's main .kfx file."
- A KFX book is told copy-protected if its file, a license file beside it, or any part of a book of several is protected, and TextMouth never tries to remove the protection.

### Braille files that can't be read
<!-- id: braille-files-that-cant-be; keys: BRF, BRL, PEF, braille ASCII, Eurobraille, Unicode braille patterns, eight-dot, liblouis; src: TextMouth/Parsers/BrailleFileReader.swift, TextMouth/Services/BrailleTranslator.swift -->

- A braille file that can't be read is refused with a sentence that says what is wrong, as in "Could not import “Emma.brf”.
  Reading its text failed: Line 12 holds “é”, which is not braille ASCII."
- The sentences are:
  - For a BRF or BRL file with something in it that is not braille ASCII: "Line 12 holds “é”, which is not braille ASCII."
    - Lines are counted from 1 by their ends.
    - What shows as nothing, or joins the character before it (white space, an invisible character, or a combining mark), is named by its code, as in "Line 1 holds the character U+00A0, which is not braille ASCII."
    - So is a control character, as in "Line 12 holds the control character U+0007, which is not braille ASCII."
    - The blank braille pattern U+2800 is named by its code too, as in "Line 1 holds the character U+2800, which is not braille ASCII."
  - For a BRF or BRL file read as Eurobraille, six-dot, with something in it that is not Eurobraille, the same sentence with the code's name: "Line 3 holds “é”, which is not Eurobraille."
  - For a BRF or BRL file read as Unicode braille patterns, with a byte that is no braille pattern: "Line 2 holds the byte 0xE9, which is not a Unicode braille pattern."
  - For a BRF or BRL file read in a seven-bit code, North American Braille ASCII or Eurobraille, with a byte above 0x7F that begins no valid character, which may be a file of eight-bit computer braille: "Line 2 holds the byte 0xE9.
    This file may be eight-bit computer braille, which TextMouth does not read."
    - The line and the byte let you find a single stray byte.
  - For a BRF or BRL file that begins with a UTF-16 byte order mark: "This file is in UTF-16, which TextMouth does not read as braille.
    Save it in UTF-8 to read it."
  - For a book that records braille file characters this TextMouth does not know, as a library written by a newer TextMouth can: "TextMouth has no braille file characters named “ascii-braillo-no-047-01”."
    The book is refused by name, never read as another code, since that would give wrong text with no error.
  - For a PEF file that is not well-formed XML, is not a PEF document, or has a row that is not braille, which is also what a Pentax photo named .pef gets: "This file could not be read as a PEF braille file.
    It may be damaged, or another kind of file."
  - For a PEF file in eight-dot braille, or a BRF or BRL file of Unicode braille patterns that uses dot 7 or 8: "This file is eight-dot braille, which TextMouth does not read."
  - For a file past a limit (see [What TextMouth reads](reads-pages-and-limits.md)).
    "This braille file holds more than 32 MB, the most TextMouth reads from one braille file.", "This file has more than 100,000 braille pages, the most TextMouth reads.", or "This file has more than 4,000,000 lines of braille, the most TextMouth reads."
  - For a book that names a braille table this TextMouth does not have, as a library written by a newer TextMouth with more tables can: "TextMouth has no braille table named “en-xx.ctb”."
    - The same sentence refuses one of this Mac's tables that this Mac no longer has or that its check refused (see [Settings](settings-braille.md)), named with "mac:" before its file name, as in "TextMouth has no braille table named “mac:el.ctb”."
    - A TextMouth from before it offered this Mac's tables reads every "mac:" name so.
  - For one of this Mac's tables that could not be checked, as when the braille helper failed: "TextMouth could not check this Mac's braille table “mac:el.ctb”: the braille helper failed.
    Try again."
    - The table is not refused, and trying again checks it again.
    - The other reasons are listed in [Settings](settings-braille.md).
  - For a translation that TextMouth stopped on, for passing one of the helper's limits (see [Where TextMouth keeps your library](helper-programs.md)): "TextMouth stopped the braille translation because it ran longer than 11 seconds."
    - The 11 seconds are the 10 allowed and the share of the book's size, rounded up, here for a small book.
    - The reasons are the watchdog's, in the words listed under "Converting X was stopped because ..." in [Adding books](adding-books.md).
  - For a translation that failed any other way, because the helper is missing, could not start, ended with an error, or wrote output that does not match what it was given: "TextMouth could not translate this braille."

### Playlists that can't be imported
<!-- id: playlists-that-cant-be-imported; keys: M3U refused, streaming playlist, HLS, web addresses, 4 MiB; src: TextMouth/Models/PlaylistImportWording.swift, TextMouth/Parsers/M3UPlaylist.swift -->

- A playlist that can't be imported is refused at the step "Reading the file", as in "Could not import “radio.m3u8”.
  Reading the file failed: It is a streaming playlist for web audio, which TextMouth does not import."
- The other reasons are:
  - "It lists only web addresses, and TextMouth imports only files on this Mac."
  - "It names no audio file in its own folder that TextMouth can import.", followed, when entries were skipped, by "It skipped 3 entries: " and the entries, named as the notice in [Adding books](adding-books.md) names them.
  - "The playlist “mix.m3u” is too large to read." for a playlist file of more than 4 MiB.

## The Book Imported alert
<!-- id: book-imported-alert; keys: Book Imported, Books Imported, Some Files Not Imported, alert title, left out chapters; src: TextMouth/Models/ImportProgressWording.swift, TextMouth/ViewModels/LibraryViewModel+Import.swift -->

- An import that adds its book but has something to tell ends with an alert titled "Book Imported", where a failure's alert is titled "Error": the entries a playlist skipped, the original of an .rtfd that was kept, or chapters or pages that were left out.
- The book is in the library, but it is not opened, so the alert is not left behind a reader window.
- A ZIP batch's alert that sums up its failed and incomplete books is titled by what the batch did, never "Error", since the books that came in are in the library:
  - "Nothing Imported" when the batch found no book, whether files failed or it was cancelled early.
  - "Already in Library" when it found books but the library already held every one.
  - "Some Files Not Imported" when books came in but a file failed or the batch was cancelled.
  - "Book Imported", for one book, or "Books Imported", for several, when every book came in and only some lack chapters or pages.
