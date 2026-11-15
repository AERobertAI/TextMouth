# Helper programs TextMouth watches
<!-- id: helper-programs-textmouth-watches; keys: subprocess, watchdog, killed, limits, time and memory; src: TextMouth/Platform/macOS/Services/WatchedProcess.swift, TextMouth/Services/ImportAudioConverter.swift, TextMouth/Services/TextutilConverter.swift, TextMouth/Services/BrailleTranslator.swift -->

Part of [TextMouth's documentation](../../README.md).

## Converting Ogg audio already in the library
<!-- id: converting-ogg-audio-already-library; keys: Vorbis, Opus, Converting audio progress, one-time conversion; src: TextMouth/ViewModels/LibraryViewModel+OggConversion.swift, TextMouth/ViewModels/OggConversionProgress.swift -->

Once for each library, TextMouth converts the Ogg audio of the books already in it, one book at a time, while the Library window shows "Converting audio: 12 of 176 tracks of “Title”".
Bookmarks and positions stay where they were.
A book needs room for its converted copy plus TextMouth's one-gigabyte reserve; one that doesn't fit waits, and an alert says how much space it needs.
A book whose files are only in the cloud waits until they are on this Mac.
The debug log records OGG_CONVERTED for each book converted and OGG_CONVERSION_WAITS for each that waits.

## afconvert, the audio converter
<!-- id: afconvert-audio-converter; keys: AAC, Apple Lossless, converter limits, AUDIO_CONVERSION_KILLED; src: TextMouth/Services/ImportAudioConverter.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift -->

TextMouth converts Ogg audio, and the other audio its import converts (see [What TextMouth reads](reads-audiobooks.md)), to AAC, or to Apple Lossless when the source is lossless, with Apple's own afconvert tool, run as a separate process that TextMouth stops when:

- it runs longer than a minute plus a tenth of the track's length,
- grows past 1 GB,
- stops writing for 20 seconds,
- or writes more than four times what the track should come to and 16 MB more.

The Mac itself ends it when it has used more than four times that many seconds of processor time or tries to write past that amount.
An import that can't convert a track stops (see [Adding books](adding-books.md)).
A library book whose Ogg conversion fails is left exactly as it was and tried again at the next launch; Play says so.
The debug log records AUDIO_CONVERSION_KILLED for each conversion stopped, as OGG_CONVERSION_KILLED did before version 0.2.0.

### When the converter ends
<!-- id: when-converter-ends; keys: orphan, force-quit, leftover converter; src: TextMouth/Platform/macOS/Services/OrphanedConversionSweep.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift -->

The converter ends with TextMouth: when TextMouth quits, when it is force-quit, and when it quits to protect your Mac.
At each launch TextMouth also stops any converter an earlier run left behind, touching only one that is writing one of TextMouth's own hidden conversion files.
The debug log records OGG_ORPHAN_SWEPT, with how many it stopped, when it stopped any.

## afinfo, which checks what an audio file holds
<!-- id: afinfo-which-checks-what-audio; keys: audio file info, MPEG-4, QuickTime, implausible length; src: TextMouth/Services/AudioFileInfo.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift -->

Before it converts a file other than Ogg, and when a file's first bytes don't settle whether to convert it (an MPEG-4 or QuickTime file), TextMouth asks Apple's afinfo tool what the file holds.
It does so also as a separate process that TextMouth watches.
TextMouth stops it when it runs longer than 30 seconds plus one more for each 20 MB of the file, holds more than 512 MB of memory, or prints more than 1 MB.
Apple's afinfo prints into a hidden file in the Mac's temporary folder, named with a dot, an ID, and .watched-output, which is removed when afinfo ends.
The debug log records AUDIO_INFO_KILLED, with the file's name and the reason, for each afinfo stopped, and AUDIO_INFO_IMPLAUSIBLE, with the file's name and the length it claimed, for a file whose header claims a length that its size cannot hold.

### When afinfo ends
<!-- id: when-afinfo-ends; keys: orphan, leftover process, temporary files; src: TextMouth/Platform/macOS/Services/OrphanedConversionSweep.swift -->

afinfo ends with TextMouth in the same three cases as the Ogg converter.
At each launch TextMouth also stops any afinfo an earlier run left behind, touching only one that is printing into one of those hidden files, and removes those files from the temporary folder when they are more than an hour old.
The debug log records AFINFO_LEFTOVERS_SWEPT, with how many processes it stopped and how many files it removed, when it did either.

## textutil, for the oldest Word documents
<!-- id: textutil-oldest-word-documents; keys: Word 97, .doc, antique documents, import refused; src: TextMouth/Services/TextutilConverter.swift, TextMouth/Parsers/TextutilDocumentReader.swift -->

TextMouth reads, on the Mac only, a Word document older than Word 6 with Apple's own textutil tool, run as a separate process that TextMouth watches (see [What TextMouth reads](what-textmouth-reads.md)).
Every other kind of document, Word 6 and Word 95 documents since version 0.4.1 and OpenDocument text and Word 2003 XML since version 0.4.0 among them, is read inside TextMouth by its own code, which starts no process and is never stopped this way.
TextMouth stops it when it runs longer than 30 seconds plus one more for each million bytes of the document, grows past 1 GB of memory, or uses more than four times the time allowed in processor time, which the Mac itself enforces.
A document it stopped fails to import with "TextMouth stopped reading this document because ...", and the debug log records TEXTUTIL_KILLED, with the file's name and the reason.
When textutil fails by itself, because it could not start, ended with an error, or ended without writing anything, which is what it does when it cannot read a file, the debug log records TEXTUTIL_FAILED, with the file's name and which of those happened.
Cancel in the import overlay stops it at once, and for any import that Cancel stops the debug log records IMPORT_CANCELLED, with the file's name and where the import stopped, as in "while reading its text", "after 3 of 10 books", or "before it started".

### Where textutil writes
<!-- id: textutil-output-location; keys: hidden output file, temporary folder, reread text; src: TextMouth/Services/TextutilConverter.swift, TextMouth/Parsers/TextutilDocumentReader.swift, TextMouth/Platform/macOS/Services/OrphanedConversionSweep+Textutil.swift -->

While an import runs, textutil writes its output as a hidden file in the package the import is building, which goes with that package should the import fail or be cancelled.
When TextMouth reads again the text of a book already in the library, it writes it in a new folder named TextMouth-textutil- followed by an ID, in the Mac's temporary folder, and removes the folder when the conversion ends.

### When textutil ends
<!-- id: when-textutil-ends; keys: orphan, leftover process, temporary folder; src: TextMouth/Platform/macOS/Services/OrphanedConversionSweep+Textutil.swift -->

textutil ends with TextMouth in the same three cases as the Ogg converter.
At each launch TextMouth also stops any textutil an earlier run left behind, touching only one that is writing one of TextMouth's own hidden output files, and removes the TextMouth-textutil- folders in the temporary folder that are more than an hour old.
The debug log records TEXTUTIL_LEFTOVERS_SWEPT, with how many processes it stopped and how many folders it removed, when it did either.

## TextMouthBraille, the braille helper
<!-- id: textmouthbraille-braille-helper; keys: liblouis, braille translation, print to braille, helper limits, Mac tables; src: TextMouth/Services/BrailleTranslator.swift, TextMouth/Services/MacBrailleTableCheck.swift, TextMouthBraille/main.c -->

TextMouth translates between print and braille with liblouis, which runs in TextMouthBraille, a helper program of TextMouth's own inside the app, also as a separate process that TextMouth watches (see [What TextMouth reads](reads-daisy-and-braille.md)).
TextMouth stops it:

- when it runs longer than 10 seconds plus a quarter of a second for each million bytes of braille it is given to read, or 6 seconds for each million bytes of print it is given to write as braille;
- when its output does not grow for as long;
- when it holds more than 16 MB of memory;
- or when it writes more than 10 times its input, 32 times when it writes braille, and 1 MB more.

The Mac itself ends it when it has used more than four times the time allowed in processor time.
For one of this Mac's tables that has passed its check (see [Settings](settings-braille.md)), the limits on time and on memory are raised to four times the time and twice the memory its check measured, and a limit is never lowered.
A book the helper stopped fails to import with "TextMouth stopped the braille translation because ...", and an export of braille fails the same way (see [Adding books](import-progress-and-errors.md) and [Exporting books](exporting-books.md)).
The debug log records BRAILLE_HELPER_KILLED, with what the helper was doing (back for braille to print, forward for print to braille), the table, and the reason.
When the helper fails by itself, because it is missing, could not start, ended with an error, or wrote output that does not match its input, the debug log records BRAILLE_HELPER_FAILED, with the same and what happened.
Neither line holds any text of a book.
The debug log also records BRAILLE_MAC_TABLE_REFUSED when the check of one of this Mac's tables refuses it, with the table's name, as "mac:" and its file name, and the reason in the refusal's words (see [Settings](settings-braille.md)).
A check that could not run is not logged so, and the line holds no text of a book.
Cancel in the import overlay stops it at once.

### Where the braille helper writes
<!-- id: where-braille-helper-writes; keys: braille-in, braille-out, scratch files, temporary folder; src: TextMouth/Services/BrailleTranslator.swift -->

The helper reads a hidden file and writes another, named with a dot, an ID, and .braille-in.txt or .braille-out.txt, in the places textutil's output goes:

- in the package an import is building,
- and, when TextMouth reads again the text of a braille book already in the library, in a TextMouth-textutil- folder in the Mac's temporary folder.

An export's are in its scratch folder, and the check of one of this Mac's tables chosen in Settings or in Export's braille options makes its files in a TextMouth-textutil- folder too.
They are removed however the translation ends.

### When the braille helper ends
<!-- id: when-braille-helper-ends; keys: orphan, force-quit, leftover helper; src: TextMouth/Services/BrailleTranslator.swift, TextMouth/Platform/macOS/Services/WatchedProcess.swift -->

The helper ends with TextMouth in the same three cases as the Ogg converter.
Unlike textutil, the helper is not looked for at launch, but the removal of old TextMouth-textutil- folders, above, covers a braille folder too.
