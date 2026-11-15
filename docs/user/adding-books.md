# Adding books
<!-- id: adding-books; keys: import, add a book, Open Book, FileImportService, menu commands; src: TextMouth/Services/FileImportService.swift, TextMouth/Models/AddToLibraryWording.swift -->

Part of [TextMouth's documentation](../../README.md).

## The Add to Library sheet
<!-- id: add-library-sheet; keys: plus button, toolbar, AddToLibraryChoice, ways to add, hints, Escape; src: TextMouth/Models/AddToLibraryWording.swift, TextMouth/Models/AddToLibraryChoice.swift, TextMouth/Views/Library/AddToLibrarySheet.swift -->

- Add to Library, the plus button in the Library window's toolbar, opens a sheet with every way to add to the library.
- It takes the place of the toolbar's Import, New from Text, and Add Feed buttons, whose commands are all in the sheet.
- VoiceOver calls the button "Add to Library", and its hint is "Opens a sheet with the ways to add to the library: open a book, import a folder, make a book from text, record audio, or add a feed".
- When the window lists no books and has no Continue button, VoiceOver's focus starts on it, where it started on the Import button before.
- The sheet has a heading, "Add to Library", a button for each way to add, and Cancel, which Escape presses.
  VoiceOver starts on the first button.
- The buttons come in the order below, with what each does written under it, which VoiceOver speaks as the button's hint:
  - Open Book…: "Opens a file picker to import books in any format TextMouth reads."
  - Import Folder…: "Chooses a folder that holds a DAISY book or audio tracks and imports it as one book."
  - New from Text…: "Makes a new book from text you paste or type."
  - New Recording…: "Records from a microphone into a new audiobook."
  - Add Feed…: "Opens a sheet where you type a feed's address and choose where its folder goes"
- Each button is named by its menu command, and VoiceOver adds the command's key in words when it has one, as in "Open Book…, Command + O".
- Choosing a button closes the sheet and then does what its menu command does, each described below.
- Cancel, or Escape, closes the sheet and does nothing.
- A button is dimmed when you have set its action to work only in reader windows, which you can for Open Book…, New from Text…, and New Recording…, under Works in in the Shortcuts tab of Settings.
  Its hint then ends "Not available in this window."

## Open Book… and Finder
<!-- id: open-book-finder; keys: Open With, document types, Info.plist, LSHandlerRank, default app, Pentax raw; src: TextMouth/Resources/Info.plist, TextMouth/Services/FileImportService.swift, TextMouth/App/MenuCommands.swift -->

- File menu, Open Book… (Command-O) imports the files you choose.
- Opening a supported file from Finder imports it and opens it.
- TextMouth declares itself a viewer of
  - rich text,
  - rich text with attachments,
  - Word 97-2003 documents and templates,
  - Word templates and macro documents,
  - OpenDocument text and templates,
  - web archives,
  - SSML files,
  - Kindle books (.mobi, .prc, .azw, and .azw3, and .kfx, .kfx-zip, .azw8, and .kpf),
  - BRF, BRL, and PEF braille files,
  - M3U and M3U8 playlists,
  - MPEG-4, M4V, and QuickTime video files (.mp4, .m4v, and .mov, whose sound alone it plays),
  - the audio formats it converts,
  - and every .xml file,

  so Finder offers it in the Open With menu for them.
- It declares them at Alternate rank, as it does for every format but its own .tmb packages, so it never asks to be the default app for any of them.
- A .pef file is also a Pentax raw photo to macOS, so Open Book… accepts whatever type the system gives a .pef, and the import tells a braille file from a photo by reading it.
- A photo is refused with the sentence for a PEF that cannot be read (below).

## TextMouth packages
<!-- id: textmouth-packages; keys: .tmb, package, Finder duplicate, Reading List, put back from Trash; src: TextMouth/Services/FileImportService+Packages.swift, TextMouth/ViewModels/LibraryViewModel+Import.swift -->

- A TextMouth package, a folder ending in .tmb, chosen in Open Book… opens as the book it holds, as it does from Finder, instead of being refused as an unsupported format.
- A package for a book the library does not list lands in the folder the window shows and, when the window shows the Reading List, goes onto the Reading List there, as any file imported there does, with the announcement naming the folder.
- Of several packages chosen at once, only the first opens a reader window.
- A package for a book the library lists opens that book, and a copy of the package, such as a Finder duplicate, or the old copy that Replace Existing left in the Trash and you put back, opens the listed book and never takes its place.

## New from Text…
<!-- id: new-from-text; keys: New Book from Text, TextInputView, paste, clipboard, editor, Shift-Command-T, Untitled; src: TextMouth/Views/Library/TextInputView.swift, TextMouth/Models/KeyboardShortcut.swift -->

- File menu, New from Text… makes a book from text you type or paste.
- Its key, Shift-Command-T, works in Library windows, and with no window open, when it opens New from Text… in a new Library window.
- In a reader window the same key opens or closes the Sleep Timer sheet (Show Sleep Timer).
  There, and in Settings, the New Recording window, and an audio editor's window, File > New from Text… is dimmed and shows no key, so choose it from a Library window.
- Either action can have another key, or work in another kind of window, from the Shortcuts tab of Settings (see Works in, under the Shortcuts tab).
- The New Book from Text window has a Title and an Author field, a text area, Paste from Clipboard, Open in Editor (on the Mac), Reload from Editor once an editor has the text, Cancel, and Add to Library.
- A book whose title holds only spaces, or nothing, is called Untitled, and so is its file.
- When something in that window does not work, a sentence beside the buttons says so, which VoiceOver also says once, and it goes when you change the text:
  - Paste from Clipboard with no text on the clipboard changes nothing: "The clipboard has no text to paste, so the text is unchanged.
    Copy some text, then paste again."
  - Open in Editor writes the text to a file in the Mac's temporary folder and opens it in the app this Mac opens plain text with.
    - If the file can't be written: "Could not open the text in an editor, because its file could not be written.
      Paste or type the text here instead, or try again."
    - If no app opens it: "Could not open the text in an editor, because no app opened its file.
      Paste or type the text here instead, or try again."
  - Reload from Editor reads the file back as an import reads a file: as UTF-8, in the encoding a byte-order mark names, or in the encoding its bytes look like, such as Windows-1251 Russian or Shift JIS Japanese, and as Windows-1252 only when nothing can be trusted.
    - Line endings become line feeds.
    - If the file can't be read, the text is left as it was: "Could not read the text back from the editor's file, so the text here is unchanged.
      Save the file in the editor, then choose Reload from Editor again, or choose Open in Editor to start again."
    - If it was read as Windows-1252 only for want of a better guess and holds characters beyond ASCII: "The text was reloaded, but the editor's file does not say what encoding it is in, so some characters may be wrong.
      Check the text, or save the file in the editor as UTF-8 and choose Reload from Editor again."
    - That note stays only while the text is as it was reloaded.

## New Recording…
<!-- id: new-recording; keys: record, microphone, Option-Command-N, audiobook; src: TextMouth/Views/Recording/RecordingWording.swift, TextMouth/App/MenuCommands.swift -->

- File menu, New Recording… (Option-Command-N), also in the Library menu, records from a microphone into a new audiobook (see [Recording from a microphone](recording.md)).

## Import Folder…
<!-- id: import-folder; keys: Import DAISY Folder, importDAISYFolder, folder of tracks, symbolic link, ORIGINAL_KEPT, Shift-Command-O; src: TextMouth/Services/FileImportService.swift, TextMouth/ViewModels/LibraryViewModel+Import.swift -->

- Library menu, Import Folder… (Shift-Command-O, in a Library window) imports a DAISY book kept as loose files, by its folder, one folder per book, or a folder of audio tracks as one audiobook, as a ZIP of the same tracks imports.
- A key you gave it when it was called Import DAISY Folder… keeps working.
- Opening such a folder from Finder imports it the same way.
- The folder's tracks, and its manifest, at its top level or inside its one folder, are copied into the book's package, and the folder is left as it was.
- The book takes the folder's name unless the manifest gives a title.
- A folder holding neither a DAISY book nor tracks is refused, and the alert says what it holds.
- A folder you import is never deleted or offered for deletion, whatever Storage settings say about originals, since it holds files that were not copied.
- Deleting an original also refuses a folder, or a link to one, whatever asked for it: nothing is deleted or sent to the Trash, and the debug log records ORIGINAL_KEPT with the folder's name.
- A folder that is a link (a symbolic link, such as `ln -s` makes) is read as the folder it points to, since you named it, and is imported as choosing that folder would be.
  - The book takes the name of the folder the link leads to, not the link's name, and that folder is what the book records as its source.
  - Links inside the folder are listed but not followed, so a link inside a folder cannot lead the import elsewhere.
  - A link to nothing is still an error.
    A link to a file is left as it is.
  - A link to a folder of DAISY books in folders is refused, as choosing the folder itself is.
- A folder holding DAISY books in folders inside it is not a book itself and is refused: choose the book folders instead, several at once.
  - The alert for it says that the folder holds no DAISY book and no audio tracks to import as one book, and lists the files found anywhere inside it, which does not say that the books are in the folders within.

## A transcript chosen with its audio
<!-- id: transcript-chosen-audio; keys: .vtt, .srt, WebVTT, SubRip, Attach Transcript, Dock icon, sidecar; src: TextMouth/Services/TranscriptPairing.swift, TextMouth/Services/FileImportService.swift -->

- A WebVTT (.vtt) or SubRip (.srt) file chosen or opened together with its audio is attached to that audio's book as the audio is imported.
  It is not imported as a book of its own, and nothing is refused.
- It works with Open Book… and when you open the files from Finder or drop them on the Dock icon.
- The file must be the one the audio finds as its transcript: named as the track is, with its extension changed (01.vtt beside 01.mp3), and, when both are beside the audio, the .vtt (see [Transcribing an audiobook](transcribing.md)).
  A .srt chosen beside an audio file that has a .vtt of its own is not that audio's transcript.
- A transcript file chosen without its audio, or with audio that does not find it, is refused as a book: "Unsupported file format: .vtt.
  A .vtt file is a transcript, not a book.
  To use it, import its audio, open the book, and choose Attach Transcript… from the Book menu."
  For a .srt file it says ".srt".
- If the audio's own import is skipped, as a duplicate or a refused file is, a transcript chosen with it is dropped too, silently.

## M3U and M3U8 playlists
<!-- id: m3u-m3u8-playlists; keys: M3U, M3U8, #EXTINF, #PLAYLIST, skipped entries, streaming, HLS; src: TextMouth/Parsers/M3UPlaylist.swift, TextMouth/Models/PlaylistImportWording.swift -->

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
<!-- id: add-feed; keys: subscribe, podcast, RSS, Shift-Command-F, Add Feed sheet; src: TextMouth/Views/Feeds/FeedWording.swift, TextMouth/Views/Feeds/AddFeedSheet.swift -->

- Library menu, Add Feed… (Shift-Command-F, in a Library window), or the Add Feed… button of the Add to Library sheet (above), subscribes to a podcast or article feed (see [Podcasts and article feeds](feeds.md)).

## ZIP archives
<!-- id: zip-archives; keys: archive, Create Folder, batch, textutil, braille helper, cancel; src: TextMouth/Services/ArchiveExtraction.swift, TextMouth/Services/FileImportService.swift -->

- A ZIP of several books imports each of them (an .rtfd folder inside is one book, not its separate files), and TextMouth offers to create a folder for them.
- The progress overlay's Cancel button stops a ZIP import after the book in progress, or at once when that book is, on the Mac, a Word document older than Word 6 that textutil is converting, or a braille file that the braille helper is translating.
- In that case textutil or the helper is stopped, that book is not imported, and the alert says after how many books the import stopped.
- A single file's import that Cancel stops that way ends with no alert.

## A TextMouth package inside a ZIP
<!-- id: textmouth-package-inside-zip; keys: .tmb in a ZIP, mailed package, compressed in Finder, duplicate; src: TextMouth/Services/FileImportService+Packages.swift, TextMouth/Services/FileImportService.swift -->

- A TextMouth package inside a ZIP, as one mailed or compressed in Finder, imports as one book, with its places, bookmarks, and settings, not as its book file and its text cache apart.
- A package whose book the library lists is skipped as a duplicate, and one that cannot be identified is a failure, so the archive is kept.

## Importing audio that TextMouth converts
<!-- id: importing-audio-that-textmouth-converts; keys: Ogg, AC-3, afconvert, ImportAudioConverter, watchdog, mix to stereo, Converting its audio; src: TextMouth/Services/ImportAudioConverter.swift, TextMouth/Services/FileImportService+AudioConversion.swift, TextMouth/Services/ImportFailure.swift -->

- Importing audio that TextMouth converts (Ogg, AC-3, and the other formats listed in [What TextMouth reads](what-textmouth-reads.md)) adds a step, Converting its audio, after the archive is extracted and its manifest checked.
- The overlay counts the tracks, as in "converting its audio: 12 of 176 tracks".
- The archive, folder, or file you import from is never changed.
- A track that can't be converted stops the import, and nothing is added.
- The alert says which track and why, as in "Could not import “My Tracks.zip”.
  Converting its audio failed: Converting 01.ogg was stopped because it used more than 960 seconds of processor time."
- That number is four times the converter's time limit, a minute plus a tenth of the track's length, here for a track of 30 minutes.
  [Where TextMouth keeps your library](where-your-library-lives.md) lists what else stops the converter.
- Cancel kills the conversions at once, and the import ends as a cancelled one.
- The reasons, with X the track's file name:
  - "The audio file X could not be read for converting."
    The Mac's tool could not read the file as audio, or the file's header claims a length that its size cannot hold, or more than a year.
  - "The audio converted from X failed its check: ..." and why: the converted file would not play, or lasts a different time from its source, as in "it lasts 12.0 seconds, not 600.0".
  - "The audio converted from X could not be given its name."
  - "Converting X was stopped because ..." and the watchdog's reason: "it ran longer than N seconds", "it held more than N MB of memory", "its output did not grow for N seconds", "it used more than N seconds of processor time", or "its output passed N MB", which is more than four times what the track should come to, and 16 MB more.
  - "Converting X failed (the converter ended with code N)."
  - "There is not enough free disk space to convert X: it needs N GB free."
    This is said before anything is converted, for audio of more than two channels, which is mixed to stereo through a hidden file of uncompressed sound that must fit on the disk.
  - "The audio file X has N channels but does not say which is which, so TextMouth cannot mix it to stereo."

## The original file after an import
<!-- id: original-file-after-import; keys: After Importing a Book, Keep Original, Delete After Import, Ask Each Time, .rtfd, Show Package Contents; src: TextMouth/Models/OriginalFileDeletionWording.swift, TextMouth/Services/FileImportService.swift -->

- Storage settings decide what happens to the original file after an import: keep it (the default), delete it, or ask each time.
- A folder imported with Import Folder… is the exception, as described there, and so is an .rtfd, which is a folder too: it is never deleted or offered for deletion.
- When After Importing a Book is set to Delete After Import or Ask Each Time, an alert titled "Book Imported" says "The original file was kept: it is a folder, and an import never deletes a folder.", and the book is added without opening, even if it came from Finder.
- A file inside a book's package, a folder ending in .tmb, or inside TextMouth's data directory is never deleted or offered for deletion, whatever After Importing a Book says: such a file, opened with Show Package Contents and Open With, is a copy of part of a book that is still in the library.
- It is kept with nothing said, and the debug log notes it.

## A ZIP holding a DAISY book with audio
<!-- id: zip-holding-daisy-book-audio; keys: DAISY ZIP, talking book, SMIL, archive kept, audio only; src: TextMouth/Services/FileImportService.swift, TextMouth/Models/ImportDecision.swift -->

- A ZIP holding a DAISY book with audio imports the book's audio alone, and the archive keeps its text and images, so the archive is kept whatever After Importing a Book says, and an alert titled "Book Imported" says why, as in "The original file was kept: TextMouth imported the audio of “Harbour Pilots” from the archive “pilots.zip”, and the archive is the only copy of its text."
- The archive is kept even when a SMIL file in it is one TextMouth will not parse, such as one with a tag of more than 1,024 attributes (see XML parts TextMouth can't safely read, above).
  TextMouth still finds the text files that SMIL file names, by reading it as plain text, so it does not take the archive for one with no text and offer it for deletion.
- For a talking book that has no text, in an archive of other books, it says "The original file was kept: TextMouth imported only the DAISY book “Harbour Pilots” from the archive “pilots.zip”." and, when the archive holds other books, adds " The archive also holds 2 other books that were not imported; unzip it to import them.", or, for one, "1 other book that was not imported; unzip it to import it."
- A DAISY ZIP without audio, which is imported whole, and a talking book whose archive holds nothing more, may still be deleted.

## A Markdown book named content.md
<!-- id: markdown-book-named-content-md; keys: content.md, content (book).md, text cache, Redo Text Extraction; src: TextMouth/Services/FileImportService.swift, TextMouth/Services/MarkdownCacheService.swift -->

- A Markdown book whose file is named content.md keeps its own file: the package stages it as "content (book).md", beside the text cache, which is a different file, so Redo Text Extraction still has the original.
