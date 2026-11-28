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

## TextMouth's own converter, for audio macOS cannot read
<!-- id: ffmpeg-ffprobe-helper-programs; keys: ffmpeg, FFmpeg, WMA, Matroska, TextMouthFFmpeg, sandbox, AUDIO_CONVERSION_KILLED, AUDIO_DECODER_REFUSED; src: TextMouth/Services/FFmpegAudioConverter.swift, TextMouth/Services/FFmpegHelperStream.swift, TextMouth/Models/FFmpegImportWording.swift, TextMouthFFmpeg/main.c, TextMouth/Platform/macOS/Services/WatchedProcess.swift -->

TextMouth converts WMA, Speex, Musepack, WebM, Matroska, AVI, Flash video, and RealMedia audio with a converter it carries inside the app, built from FFmpeg, so nothing needs installing (see [What TextMouth reads](reads-audiobooks.md)).
It is a small program in the app, TextMouthFFmpeg, which TextMouth starts for each file, first to ask what the file holds and then to decode its sound, each as a separate process that TextMouth watches.
An ffmpeg installed on the Mac, Homebrew's or any other, is not used for the import.

- Once it has opened the file, the converter confines itself with macOS's computing-only sandbox: it can compute, read that one file, and write its answer, and nothing else, so it opens no other file, makes no network connection, and starts no program, whatever the file holds.
  If macOS refuses the sandbox, the converter reads nothing, and the import says "TextMouth's converter could not make itself safe before reading “NAME”, so it did not read the file.
  Install TextMouth again, then import the file again."
- TextMouth stops the converter's probe when it runs longer than 30 seconds plus one more for each 20 MB of the file, or holds more than 512 MB of memory.
  The debug log records AUDIO_INFO_KILLED, with the file's name and the reason.
- TextMouth stops its decode by the converter's rules of its own: more than a minute plus a tenth of the track's length, more than 1 GB of memory, or no growth of its output for a minute.
  FFmpeg is also refused any single request for more than 256 MB, and decodes on one thread.
  The debug log records AUDIO_CONVERSION_KILLED, as it does for afconvert.
- TextMouth looks at the decode four times a second.
  It also counts the file it writes before each block, so a file that grows too fast is stopped at its cap, not up to a second later.
- A file that says no length is limited by its size instead: its output may be at most 50 times the file, and no less than 64 MB.
- The converter is given only the file, opened by TextMouth itself, and the format named from the file's first bytes, so it never guesses a format or opens a web address.
- When the converter finishes a whole file, it has two seconds to end by itself, and TextMouth then ends it without counting that as a failure.
- A file the converter cannot read says "TextMouth can't read “NAME” as WMA.
  It may be damaged, or named for another format.", and one that makes it stop says "TextMouth's converter stopped unexpectedly while reading “NAME”.
  The file may be damaged."
- A file whose sound the converter decodes with errors is still imported, and the debug log records AUDIO_DECODER_REFUSED, with the file's name and how many packets and frames it refused.
  The sound it refused is kept as silence, so the book keeps its length and its chapter marks, and the import says so (see [What TextMouth reads](reads-audiobooks.md#formats-only-ffmpeg-reads)).
- The Use ffmpeg for filters switch in Settings covers the audio editor's filters only, and those still run an ffmpeg installed on the Mac when the switch allows (see [Editing audio](editing-audio.md)).
- Cancel stops the converter at once.
- The iPhone starts no program, so there the converter runs inside TextMouth itself, one step at a time, under the same limits, except that time counts only while TextMouth is running.
  Switching to another app in the middle of an import does not use up its time.
  It keeps at least 512 MB of the app's memory free, or half of what was free when the conversion began if that is less, and the sentences when it stops are in [What TextMouth reads](reads-audiobooks.md#on-the-iphone).

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
<!-- id: textmouthbraille-braille-helper; keys: liblouis, braille translation, print to braille, helper limits, Mac tables; src: TextMouth/Services/BrailleTranslator.swift, TextMouth/Services/MacBrailleTableCheck.swift, TextMouthBraille/main.c; status: incomplete; issues: FU02, B20 -->

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
The debug log records BRAILLE_TABLES_UNAVAILABLE when a braille table cannot be unpacked from the app's pack, with the file's name and why, once for each cause, and never a folder or a book's text.
Cancel in the import overlay stops it at once.
The iPhone can start no program, so it runs the same translation, liblouis 3.39.0, inside the app, one call at a time on a thread of its own.
It keeps the Mac's limits as nearly as one process allows: its batches read the same limits on time and output, and a call still running 5 seconds past its limit is abandoned, since nothing in an app can stop one of its threads.
A translation abandoned so says "TextMouth stopped the braille translation because it ran longer than N seconds, and won't try again until TextMouth is closed and opened again.", with N its limit in seconds.
  Near the end of a book's time, N is only the time the book had left, not the book's whole time.
Every translation after it says "TextMouth stopped the braille translation earlier because it took too long, and won't try again until TextMouth is closed and opened again."
A translation's time counts only while TextMouth is running, so switching to another app in the middle of a translation no longer stops braille until TextMouth is closed and opened again.
A crash in liblouis, which the Mac's helper survives, would end the iPhone app (FU02).

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
