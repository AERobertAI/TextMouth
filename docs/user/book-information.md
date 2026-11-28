# Book Information
<!-- id: book-information; keys: Book Info sheet, book details, metadata, Info; src: TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/Models/LibraryInfoWording.swift -->

Part of [TextMouth's documentation](../../README.md).

## Details you edited by hand
<!-- id: details-you-edited-hand; keys: manual edit, metadata editor, library.json, trimmed spaces, EPUB metadata, empty title; src: TextMouth/Models/BookInfo.swift, TextMouth/Models/EPUBMetadataSave.swift, TextMouth/Views/Reader/MetadataEditorView.swift, TextMouth/ViewModels/LibraryViewModel+BookOperations.swift -->

TextMouth records which of a book's details you typed yourself.
When you save Book Info, or the metadata editor of an EPUB or an audiobook, each field whose value you changed is marked as edited by hand, in library.json and in the book's record.
The fields are the title, the author (an audiobook's artist), an EPUB's publisher and publication date, and an audiobook's album, genre, and year.
The next time you open Book Info, from the Library window or from a reader, VoiceOver says "edited by hand" after the label of each such field, as in "Book title, edited by hand"; in a reader, that includes a field you saved there a moment before.
Saving changes, and marks, only the fields you changed in that editor since it opened.
A field you leave as the editor showed it is neither saved nor marked, even where the editor showed what the book's file says, and even if another window, or the metadata refresh after an update, changed it while the editor was open: that change stays.
Every editor trims the spaces and line breaks around each value as it saves: "Press " is saved as "Press", a value that differs from what the editor showed only in those spaces counts as unchanged, and spaces typed over an empty field change nothing and mark nothing.
A value the book already holds with spaces around it, which you leave alone, is not rewritten.
A title of only spaces is never saved, by any editor, and the metadata editor of an EPUB or an audiobook refuses a title you emptied: it stays open with your edits, and VoiceOver says, and the editor shows, "Could not save: the book's title is empty.
Type a title, then save again."
A book that opened with no title can still be saved without one, so a change to another detail is never held back.
While a book's file is only in the cloud, its editor shows empty each detail TextMouth doesn't know, such as an EPUB's publisher and date or an audiobook's album, genre, and year; a detail you leave empty there stays unknown, so the file's own values show once the book is downloaded.
When you also check Also write to the library's copy of the EPUB file, the file takes the book's title, author, publisher, and date as the library has them at that moment, your changes included.
The file is saved even when the EPUB's container file spells the package document's path in another case than the archive does (as "Content.opf" over "content.opf"): the archive's own spelling is kept.
If that file is missing from the library, nothing is saved, and VoiceOver says "Could not save metadata to the library's copy of “alice.epub”, because that file is missing from the library.
Turn off “Also write to the library's copy of the EPUB file” to save the metadata to the library only.
Nothing was changed."
A field once marked stays marked, even if you later type back what the file says.
The metadata refresh after an update never replaces a field edited by hand (see library.json, under [Where TextMouth keeps your library](data-directory-files.md)).

## Reading an audiobook's tags
<!-- id: reading-audiobook-tags; keys: audio tags, ID3, hung file, album, artist, cloud only; src: TextMouth/Views/Library/LibraryBookInfoLoader.swift, TextMouth/Services/AsyncBridge.swift, TextMouth/Views/Library/LibrarySheetViews.swift -->

Book Information for an audiobook reads the tags of its audio file when it opens.
If that read has not finished after 30 seconds, as with a file that hangs the system's audio reader, the sheet stops waiting and shows the details TextMouth keeps for the book, and does not read that file's tags again until TextMouth is closed and opened again, or the file changes.
It says nothing about a download then, since the file is on this Mac; the message about a book that is only in the cloud is for a book that is.

## Text Encoding
<!-- id: text-encoding; keys: character set, charset, garbled text, mojibake, Read Again; src: TextMouth/Models/LibraryInfoWording.swift, TextMouth/Models/TextEncodingChoice.swift, TextMouth/ViewModels/TextEncodingChoiceModel.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift -->

Text Encoding, in Book Information, is a pop-up button that names the encoding a plain text, Markdown, or HTML book's file is read in, and reads the file again in another when you choose one.
Book Info opens it, from the Library window or from a reader.
VoiceOver says its value first, then its label, as in "Windows-1251 (Cyrillic), guessed, Text Encoding", and its hint is "Choose another encoding to read the book's file again in it."

### Which books have a Text Encoding pop-up
<!-- id: which-books-have-text-encoding; keys: encoding recorded, plain text, Markdown, HTML, New from Text; src: TextMouth/Models/TextEncodingRecord.swift, TextMouth/Models/TextEncodingChoice.swift -->

Which books have it: a plain text, Markdown, or HTML book you added from a file, with Open Book…, from Finder, or in a ZIP of books, and any other book of those formats that records an encoding.
Text you typed or pasted with New from Text…, a feed's article, a book of any other format, and a book added back after Remove from Library Only that recorded no encoding have none.

### The Text Encoding items
<!-- id: text-encoding-items; keys: Automatic, UTF-8, Windows-1252, Shift JIS, GBK, Big5, EUC-KR; src: TextMouth/Parsers/TextEncodingCatalog.swift, TextMouth/Models/TextEncodingChoice.swift -->

Its items are "Automatic", "UTF-8", "Windows-1252 (Western European)", and then the encodings TextMouth guesses among, named and ordered as [What TextMouth reads](reads-text-files.md) lists them.
Automatic reads the file as TextMouth reads a file you add, so it takes back a choice.
UTF-16 and UTF-32 have no item of their own: Automatic finds them by their byte order mark, and by the pattern of their bytes when they have none (see [What TextMouth reads](reads-text-files.md)).
A short Chinese, Japanese, or Korean UTF-16 file with few spaces, digits, or line ends is not found that way, and cannot be set right here.
Shift JIS, GBK, Big5, and EUC-KR are one item each, though each stands for two encodings, Windows' variant and the standard it extends, and a choice reads the file in whichever of the two reads every byte.

### What the selected encoding says
<!-- id: what-selected-encoding-says; keys: chosen, guessed, byte order mark, BOM, declared, recognized by its bytes; src: TextMouth/Models/TextEncodingChoice.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/Parsers/TextEncodingGuesser.swift -->

The item selected is the encoding the book is read in now, and its name says what decided it:
- "Shift JIS (Japanese), chosen": you chose it.
- "Windows-1251 (Cyrillic), guessed": TextMouth guessed it, when you added the file or when you chose Automatic.
- "UTF-8, from its byte order mark": the file begins with a byte order mark.
  For UTF-16 it is "UTF-16 (little-endian), from its byte order mark" or "UTF-16 (big-endian), from its byte order mark".
- "UTF-16 (little-endian), recognized by its bytes": a UTF-16 file with no byte order mark, found by the pattern of its bytes.
  The pattern is its zero bytes if it is in Latin letters, its high bytes if it is in Greek, Cyrillic, Hebrew, or Arabic, or its mix of spaces, digits, or line ends among Chinese, Japanese, or Korean characters.
  The other byte order is "UTF-16 (big-endian), recognized by its bytes".
  A UTF-32 file with no mark is named the same way, as in "UTF-32 (little-endian), recognized by its bytes".
- "UTF-8": the bytes are valid UTF-8, which needs no more.
- "ISO 8859-2 (Central European), declared in the file": an HTML file declares it.
- "Windows-1252 (Western European), the default": nothing in the file says, and no guess was made.
- "Checking the file": the book records no encoding, and TextMouth is working out what its file says.
  The pop-up is dimmed meanwhile.
- "Not known until the book is downloaded": the book records no encoding and its file is only in the cloud, which is never downloaded to find out (see [Keeping your library in the cloud](cloud-library.md)).
- "Not known, since the file can't be read": the book records no encoding and its file can't be read.

### When no item names the encoding
<!-- id: when-no-item-names-encoding; keys: UTF-32, extra item, unknown encoding, Checking the file; src: TextMouth/Models/TextEncodingChoice.swift, TextMouth/ViewModels/TextEncodingChoiceModel.swift -->

When no item names the encoding, as with UTF-16 and UTF-32, or while it is checked or not known, one more item stands last in the list, selected, and says so.
Choosing it, or the item already selected, changes nothing.

### Choosing another encoding
<!-- id: choosing-another-encoding; keys: alert, Read Again, Cancel, edit kept, content.md.edited; src: TextMouth/Models/LibraryInfoWording.swift, TextMouth/ViewModels/TextEncodingChoiceModel.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift -->

Choosing another item asks first, in an alert.
- Its title is "Read “Moby-Dick” again as Shift JIS (Japanese)?", or, for Automatic, "Read “Moby-Dick” again automatically?".
- Its message is these sentences, in this order, with a space between them:
  - For Automatic only: "TextMouth reads its file as it reads a file you add: in the encoding the file names, or else the one TextMouth finds."
  - "Its text is replaced by the new reading."
  - "Your place and bookmarks move with their words.
    Where none of their words are left, as when garbled letters become Cyrillic, each goes to about the same point in its chapter, or to the nearest passage the two readings share."
  - Only when the book's text holds text TextMouth did not write, an edit made with Edit Text or a save that no edit took: "An edit of its text is kept beside the new reading, as a copy in the book's package."
  - Only while Edit Text is open on the book: "Edit Text stops for this book; choose Edit Text again to edit the new reading."
- Its buttons are Read Again, which Return presses, and Cancel, which Escape presses.
  Cancel changes nothing, the pop-up included.

### What Read Again does to a text book
<!-- id: what-read-again-does-text; keys: re-read, reread, spinner, bookmarks move, reading position; src: TextMouth/Models/LibraryInfoWording.swift, TextMouth/ViewModels/BookRereadChoosing.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift -->

Read Again reads the file again, in the encoding chosen or as Automatic reads it.
- The book's text is replaced.
  Your reading position, bookmarks, and skipped sections move to their words (see [Reader windows](reader-book-end.md)), and a reader that has the book open shows the new text, its cursor on the same words as near as TextMouth can find them (see [Editing a book's text](editing-book-text.md)).
- A choice is recorded with the book, and every later reading of its text uses it, whatever its bytes say of themselves (see [What TextMouth reads](reads-text-files.md) and [Where TextMouth keeps your library](book-packages.md)).
- While it works, the sheet shows "Reading the book again..." with a spinner, and the pop-up, Cancel, and Save are dimmed.
  The sheet stays open until the book has been read again.

### When Read Again is done
<!-- id: when-read-again-done; keys: announcement, KOI8-R, Edit Text stopped, edited copy; src: TextMouth/Models/LibraryInfoWording.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift -->

When it is done, the pop-up shows the new encoding, and VoiceOver says what the book is read in now, as in "“Moby-Dick” is now read as KOI8-R (Russian), chosen." or "“Moby-Dick” is now read as UTF-8."
When TextMouth can't work out what that is, because the book's file went to the cloud as it was read, it says "“Moby-Dick” was read again." instead.
When text TextMouth did not write was kept, VoiceOver adds "Its earlier text was kept as content.md.edited-…, in the book's package.", with the dots standing for the date and time in the copy's name.
And when Edit Text was open on the book it adds, after that, "Edit Text has stopped for Moby-Dick, since its file was read again.
Choose Edit Text again to edit the new text."

### When a text book can't be read again
<!-- id: when-text-book-cant-be; keys: refusal, error message, invalid bytes, not downloaded, busy, export in progress; src: TextMouth/Models/LibraryInfoWording.swift, TextMouth/Models/LibraryCloudWording.swift, TextMouth/ViewModels/TextEncodingChoiceModel.swift -->

A book that can't be read again changes nothing: not its text, its places, nor its record.
The sheet shows why below the form, which VoiceOver reads as "Error: " and the sentence and also announces once, and the pop-up keeps showing what the book is read in.
- Before the alert, choosing an item says one of these:
  - "TextMouth is reading the library's text again.
    Try again when that finishes." while TextMouth reads the library's text again, at launch or for Redo Text Extraction.
  - "TextMouth is reading “Moby-Dick” again in another encoding.
    Try again when that finishes." while that book is being read again already.
  - "“Moby-Dick” is being exported.
    Wait until the export ends, then try again."
  - "TextMouth is moving books between folders.
    Try again when that finishes.", "TextMouth is rebuilding its data directory.
    Try again when that finishes.", "TextMouth is already moving its data directory.
    Try again once that move is done.", or "TextMouth is switching to another library and opening again on it.", while the library's storage is busy with that (see [Where TextMouth keeps your library](where-your-library-lives.md)).
- After Read Again, it says one of these:
  - "“Moby-Dick” can't be read as Shift JIS (Japanese): it holds bytes that are not valid in that encoding.
    Nothing was changed."
    (see Choosing the encoding in [What TextMouth reads](reads-text-files.md) for what is not valid).
  - "Moby-Dick isn't downloaded.
    Download it first: select it in the library, then choose Download Now." when the book's file is only in the cloud.
  - "TextMouth couldn't keep the text you changed in “Moby-Dick” beside the new reading, so it left the book as it was." when no copy of the text TextMouth did not write could be made.
  - "TextMouth couldn't read “Moby-Dick” again, so it left the book as it was." when the reading failed, with a colon and the reason after "as it was" when there is one.
- Before the alert or after Read Again, when the book has left the library meanwhile: "The book is no longer in the library, so it was not read again."

## Braille Code
<!-- id: braille-code; keys: braille table, liblouis, UEB, BRF, BRL, PEF, Grade 2; src: TextMouth/Models/LibraryInfoWording.swift, TextMouth/ViewModels/BrailleCodeChoiceModel.swift, TextMouth/Models/BrailleTableCatalog.swift, TextMouth/ViewModels/BookRereadChoosing.swift -->

Braille Code, in Book Information, is a pop-up button that names the braille code a braille book's text is translated to print with, and reads the book's file again with another when you choose one.
VoiceOver says its value first, then its label, as in "Unified English Braille, contracted (Grade 2), Braille Code, pop-up button", and its hint is "Choose another braille code to read the book's file again with it."
It works as the Text Encoding pop-up does, which this page describes above, except as follows.

### Which books have a Braille Code pop-up
<!-- id: which-books-have-braille-code; keys: braille book, PEF, feed item; src: TextMouth/ViewModels/BrailleCodeChoiceModel.swift -->

Which books have it: any braille book, whatever its file (BRF, BRL, or PEF), except a feed's item, whose sheet keeps the plain Braille Code row.

### The Braille Code items
<!-- id: braille-code-items; keys: braille tables, VoiceOver tables, macOS update, Grade 1, Grade 2; src: TextMouth/Models/BrailleTableCatalog.swift, TextMouth/ViewModels/BrailleCodeChoiceModel.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouthProductionTests/BrailleTablePrintOnlyTests.swift -->

Its items are the braille codes this TextMouth and this Mac offer, each named as the book's row and Speak Info name it, such as "Unified English Braille, contracted (Grade 2)" or "French braille, contracted (Grade 2), in French", with the book's own selected.
A book that records no code shows the default one.
A code this Mac no longer offers, as one of VoiceOver's tables a macOS update removed, shows as the last item, selected, by the name it was recorded under; choosing it changes nothing.
A book whose table is stored as the other kind of device spells it, such as an iPhone's fr-bfu-g2.ctb on a Mac, has its own item selected, and keeps the value it was stored with.
The items never include a table that only writes braille (see Tables that only write braille, in [Settings](settings-braille.md)).
A book already read with one keeps its text and its table, and the pop-up shows it as that last item, selected, by its name; choosing it changes nothing.
Reading this Mac's tables takes a moment, so the pop-up is dimmed until they are listed, showing the book's own code meanwhile.

### A guessed braille code
<!-- id: guessed-braille-code; keys: Keep This Code, guess, braille code detection, Guess the braille code of new books; src: TextMouth/Models/LibraryInfoWording.swift, TextMouth/Parsers/BrailleCodeDetector.swift, TextMouth/ViewModels/BrailleCodeChoiceModel.swift -->

A guessed code says so.
When TextMouth guessed a BRF or BRL book's code as it was added (see [What TextMouth reads](reads-daisy-and-braille.md)), the pop-up's value, and Speak Info's, end with ", guessed", as in "English Braille, American Edition, contracted (Grade 2), guessed, Braille Code, pop-up button".
- Under the pop-up stands plain text that VoiceOver and a braille display read as the next item after it: "Guessed from the book's braille.
  If it reads wrongly, choose Unified English Braille in Braille Code."
  The note is not announced when the sheet opens.
- After the note comes a button, "Keep This Code", with the hint "Stops saying the code was guessed.
  The book is not read again."
  It keeps the code as your own: the word "guessed" and the note go, the book's text is not read again, and VoiceOver says "“Ledger” keeps English Braille, American Edition, contracted (Grade 2)."
  The button is dimmed while the book is being read again.
- To correct a guess, choose another code in the pop-up, as for any book: it asks first, reads the book again, and records your choice, so the book is no longer said to be guessed.
- A book whose code you chose, and every book added before TextMouth could guess, says nothing of a guess.

### A suggestion to choose another code
<!-- id: suggestion-choose-another-code; keys: English Braille American Edition, EBAE, UEB, ation, ally; src: TextMouth/Parsers/BrailleCodeDetector.swift, TextMouth/Models/LibraryInfoWording.swift -->

A suggestion sometimes stands under the pop-up, as plain text that VoiceOver and a braille display read as the next item after it: "This braille looks like English Braille, American Edition.
Choose its Braille Code in Book Information."
- It appears when the book is read with a Unified English Braille table and its braille is written in English Braille, American Edition, the code before UEB.
  TextMouth looks for that code's own signs: the signs for "to" and "by" joined to the next word, and the signs for "ation" and "ally" inside a word.
  It says so only when there are at least ten such words and at least one in a hundred of the book's words.
- Read with a UEB table, an old transcription reads wrongly with no error, as "to the sea" reading "!the sea".
  Choosing English Braille, American Edition in the pop-up reads the book again, asking first.
- The suggestion never changes the code by itself.
  It is looser than the guess made as a book is added, so a book the import left alone can still show it.
  It is announced once, as it appears, each time Book Information opens: VoiceOver says it without your moving to it, and you can read it again by moving down from the pop-up.
  It is not shown for a book whose file is not on this Mac, or one read with another code.

### Choosing another braille code
<!-- id: choosing-another-braille-code; keys: alert, Read Again, Cancel, translated to print; src: TextMouth/Models/LibraryInfoWording.swift, TextMouth/ViewModels/BrailleCodeChoiceModel.swift -->

Choosing another item asks first, in an alert whose title is "Read “Ledger” again as Unified English Braille, uncontracted (Grade 1)?" and whose buttons are Read Again and Cancel.
Its message begins "The braille is translated to print again with this code.
Nothing checks that it is the right choice.
If words read wrongly, choose another.", and goes on, as the Braille File Characters alert does, with the sentences about the text being replaced and the places moving, and about an edit of the text being kept and Edit Text stopping, where they apply.

### What Read Again does for a braille code
<!-- id: what-read-again-does-braille; keys: tables version, record choice, reader follows; src: TextMouth/ViewModels/BrailleCodeChoiceModel.swift, TextMouth/Models/LibraryInfoWording.swift -->

Read Again records the choice and the version of this Mac's tables it was made with, and says "“Ledger” is now read as Unified English Braille, uncontracted (Grade 1)." with the same added sentences.
A reader window open on the book follows the new code.

### When a braille book can't be read again
<!-- id: when-braille-book-cant-be; keys: refusal, two pop-ups, refused; src: TextMouth/Models/LibraryInfoWording.swift, TextMouth/ViewModels/BrailleCodeChoiceModel.swift -->

A book that can't be read again changes nothing, and the sheet shows why, as for the other pop-ups; when two of the sheet's pop-ups were used and both refused, it shows the refusal of the one used last.

### While a book is read again with another braille code
<!-- id: while-book-read-again-another; keys: busy, Redo Text Extraction, Replace Existing, Edit Text waits; src: TextMouth/Models/LibraryInfoWording.swift, TextMouth/ViewModels/BrailleCodeChoiceModel.swift -->

While TextMouth reads a book again with another braille code, a second re-read, Edit Text, Redo Text Extraction, and Replace Existing of that book wait and say "TextMouth is reading “Ledger” again with another braille code.
Try again when that finishes."

## Braille File Characters
<!-- id: book-info-braille-file-characters; keys: BRF characters, NABCC, ASCII braille, Eurobraille, seven-bit, six-dot; src: TextMouth/Models/BrailleFileCodeRecord.swift, TextMouth/ViewModels/BrailleFileCodeChoiceModel.swift, TextMouth/Parsers/BrailleFileCode.swift, TextMouth/Models/LibraryInfoWording.swift -->

Braille File Characters, in Book Information, is a pop-up button that names the braille file characters a BRF or BRL book's file is read with, and reads the file again with others when you choose them.
It stands after the sheet's Braille Code pop-up, and VoiceOver says its value first, then its label, as in "North American Braille ASCII, Braille File Characters, pop-up button"; its hint is "Choose other characters to read the book's file again with them."
It works as the Text Encoding pop-up does, which this page describes above, except as follows.

### Which books have Braille File Characters
<!-- id: which-books-have-braille-file; keys: BRF, BRL, PEF, no pop-up; src: TextMouth/ViewModels/BrailleFileCodeChoiceModel.swift, TextMouth/Models/BrailleFileCodeRecord.swift -->

Which books have it: a braille book whose file is a BRF or a BRL.
A PEF, whose rows are always Unicode braille patterns, a feed's item, and a book of any other format have none.

### The Braille File Characters items
<!-- id: braille-file-characters-items; keys: North American Braille ASCII, NABCC, Unicode braille patterns, unknown code; src: TextMouth/Models/BrailleFileCodeRecord.swift, TextMouth/Parsers/BrailleFileCode.swift, TextMouth/Models/LibraryInfoWording.swift -->

Its items are the three codes, "North American Braille ASCII", "Eurobraille, six-dot (German-speaking countries)", and "Unicode braille patterns", with the book's own selected.
A book that records no code shows North American Braille ASCII.
A code this TextMouth does not know, as a newer TextMouth may have recorded, shows as the last item, selected, as in "“ascii-braillo-no-047-01”, which this version of TextMouth can't read"; choosing it changes nothing.
There is no Automatic, since nothing is guessed.

### Choosing other braille file characters
<!-- id: choosing-other-braille-file-characters; keys: alert, Read Again, Cancel, seven-bit codes; src: TextMouth/Models/LibraryInfoWording.swift, TextMouth/ViewModels/BrailleFileCodeChoiceModel.swift -->

Choosing another item asks first, in an alert whose title is "Read “Ledger” again as Eurobraille, six-dot (German-speaking countries)?" and whose buttons are Read Again and Cancel.
Its message begins "Nothing checks that this is the right choice.
If numbers and punctuation sound wrong, choose another." for a choice between the two seven-bit codes.
For a choice to or from Unicode braille patterns, which the reading checks, it begins "If the file is not written in Unicode braille patterns, TextMouth refuses it, and nothing changes.", naming the code chosen.
It goes on "Its text is replaced by the new reading.
Your place and bookmarks move with their words.
Where none of their words are left, each goes to about the same point in its chapter, or to the nearest passage the two readings share." and then, as for an encoding, the sentences about an edit of the text being kept and about Edit Text stopping, where they apply.

### What Read Again does for the characters
<!-- id: what-read-again-does-characters; keys: records choice, re-read, edit kept; src: TextMouth/ViewModels/BrailleFileCodeChoiceModel.swift, TextMouth/Models/LibraryInfoWording.swift -->

Read Again records the choice with the book, as the encoding's does, and says "“Ledger” is now read as Eurobraille, six-dot (German-speaking countries)." with the same added sentences.

### When a file is not braille in the code chosen
<!-- id: when-file-not-braille-code; keys: refused, line number, invalid character, Unicode braille patterns; src: TextMouth/Parsers/BrailleFileReader.swift, TextMouth/Models/LibraryInfoWording.swift, TextMouth/ViewModels/BrailleFileCodeChoiceModel.swift -->

A file that is not braille in the code chosen changes nothing, and the sheet says why: "“Ledger” can't be read as Eurobraille, six-dot (German-speaking countries): Line 3 holds “é”, which is not Eurobraille.
Nothing was changed."
The reader's sentence inside it is one of those listed in [Adding books](import-progress-and-errors.md).
While TextMouth reads a book again with other braille file characters, a second re-read, Edit Text, Redo Text Extraction, and Replace Existing of that book wait and say "TextMouth is reading “Ledger” again with other braille file characters.
Try again when that finishes."
The other refusals are the encoding's.
