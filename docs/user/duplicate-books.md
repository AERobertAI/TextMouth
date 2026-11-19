# Duplicate books and Replace Existing
<!-- id: duplicate-books-replace-existing; keys: duplicate, Replace Existing, Keep Both, import question; src: TextMouth/Models/ImportDecision.swift, TextMouth/Services/DuplicateReplacement.swift -->

Part of [TextMouth's documentation](../../README.md).

How books are added is in [Adding books](adding-books.md).

## A book that is already in the library
<!-- id: book-that-already-library; keys: Duplicate Book Found, Keep Both, Cancel, same content, hint; src: TextMouth/Models/ImportDecision.swift, TextMouth/ViewModels/LibraryViewModel+Duplicates.swift -->

- When a book's content is already in the library, TextMouth asks whether to keep both, replace the existing book, or cancel.
- A feed's episode or article holding the same file doesn't count.
- The question says which file matches which book, as in "“Moby-Dick.epub” matches “Moby-Dick”, already in your library.
  Replace the existing copy, or keep both as separate books?", and then, after a blank line, what Replace Existing keeps of the existing copy and where its files go:
  - For a text book: "Replacing keeps the existing copy's reading position and bookmarks, moved to their words in the new text where found, and its settings, folder, and place on the reading list.
    An edit of its text is kept as a copy beside the new text, not applied."
  - For an audiobook: "Replacing keeps the existing copy's reading position, bookmarks, settings, folder, and place on the reading list, and its transcript when the audio is the same.
    Edits of its audio or of its manifest are not kept."
  - For an audiobook whose new copy came with a transcript file beside its audio (see [Transcribing an audiobook](transcribing.md)), the sentence says which transcript will stay:
    - Kept: "Replacing keeps the existing copy's reading position, bookmarks, settings, folder, and place on the reading list, and its transcript when the audio is the same, rather than the transcript file found beside the new copy's audio.
      Edits of its audio or of its manifest are not kept."
    - Replaced: "Replacing keeps the existing copy's reading position, bookmarks, settings, folder, and place on the reading list.
      The transcript file found beside the new copy's audio replaces the existing copy's transcript.
      Edits of its audio or of its manifest are not kept."
  - When one copy is played from a recording and the other is read aloud from its text, as a DAISY book is.
    "One copy is played from a recording and the other is read aloud from text, so replacing keeps only the existing copy's folder and place on the reading list, not its reading position, bookmarks and their notes, or settings."
  - Then one more sentence, by Move to Trash instead of deleting, under Removal Behavior in the Storage tab of Settings.
    "The existing copy's files go to the Trash, but putting them back won't return that copy to your library." while it is on, and "The existing copy's files are deleted permanently and cannot be recovered." while it is off.
  - A copy that is missing chapters adds "The copy just imported is incomplete." and what it lacks.
- The Replace Existing button's hint says "Puts the new copy in place of the one already in the library, keeping the existing copy's reading position, bookmarks, and settings."
  And, for a recording and a text, "Puts the new copy in place of the one already in the library, keeping only the existing copy's folder and place on the reading list."

## What Replace Existing keeps
<!-- id: what-replace-existing-keeps; keys: same ID, carried over, new copy, replaced book; src: TextMouth/Services/DuplicateReplacement.swift -->

### Which transcript an audiobook keeps
<!-- id: replace-keeps-which-transcript; keys: transcript file, sidecar, Attach Transcript, recognition, TranscriptOutcome; src: TextMouth/Services/DuplicateReplacement.swift, TextMouth/Services/TranscriptPairing.swift -->

Which transcript an audiobook keeps (0.4.2), when both copies have one and the new copy's came from a file beside its audio:
- The existing copy's transcript stays when recognition made it, when you edited it or cleaned it up, or when this TextMouth can't tell, as for one made by a later version or one only in the cloud.
  It stays only when the audio is the same, as below.
- The existing copy's transcript gives way to the file when it came from outside, from an attached file or a podcast, and you never edited or cleaned it up.
- The question tells you which of the two will happen before you answer.
- After the answer, when a file was not used, VoiceOver hears "“lecture.vtt” beside the audio wasn't attached: Replacing kept the existing copy's transcript.
  To use it, open the book and choose Attach Transcript… from the Book menu."
- When each of several tracks brought a file, one sentence names them together and gives no Attach Transcript… advice, since that command takes one file for the whole book.
  "The transcript files beside the audio weren't attached: Replacing kept the existing copy's transcript."

### What else the new copy keeps
<!-- id: replace-keeps-details; keys: date added, manual order, last opened, Book Info edits, voice, speed, pitch; src: TextMouth/Services/DuplicateReplacement.swift, TextMouth/Models/Book+OwnSettings.swift -->

Replace Existing makes the new copy the same book as the existing one, under the same ID, so it keeps more than the question names:
- It keeps the existing copy's date added, its place among the books of its folder when you ordered them by hand, when it was last opened and played, the details you edited by hand in Book Info, and its own voice, speed, pitch, end-of-book choice, and skip units.
  - Everything else is the new copy's: its file and text, and its title and author where you edited neither.

### Places in a text book
<!-- id: replace-keeps-places-text; keys: bookmarks, reading position, skipped headings, PlaceRelocator, words moved; src: TextMouth/Models/PlaceRelocator.swift, TextMouth/Services/DuplicateReplacement.swift -->

- The reading position, the bookmarks with their notes, and the skipped headings of a text book move to their words in the new text, as when a book's text is read again (see [Reader windows](reader-book-end.md)), and a place whose words are not found stays where it was saved.
  - They move from the existing copy's text only when that is the text they were saved in.
  - From text saved in an editor without TextMouth's taking the edit, they are found by their words in the new text alone.

### Places in an audiobook
<!-- id: replace-keeps-places-audio; keys: tracks, PlaceClock, TrackPlaces, time on recording, skipped headings; src: TextMouth/Models/TrackPlaces.swift, TextMouth/Models/PlaceClock.swift, TextMouth/Services/DuplicateReplacement.swift -->

- An audiobook's places count time in its recording.
  - Where the new copy has other chapters than the existing one, a book of tracks keeps each place at the same time into the same track, and a skipped heading follows its track.
  - Any other audiobook keeps each place at the same time on the recording, never cut short at the old chapter's end, and keeps its skipped headings aside, skipping nothing (see [Reader windows](reader-book-end.md)).

### Copies of edited text
<!-- id: replace-keeps-edited-text; keys: content.md.edited, Edit Text, saved edit, kept copy; src: TextMouth/Services/DuplicateReplacement.swift -->

- The copies of edited text that Edit Text kept for the existing copy go with it into the new copy's package.
  And so does the existing copy's own text, kept as a content.md.edited- copy beside the new text, when it holds an edit you made or a save that no edit took (see [Where TextMouth keeps your library](book-packages.md)).
  - When such a copy is kept, VoiceOver says, after the answer, "Replaced “X”.
    Its earlier text was kept as content.md.edited-…, in the book's package.", with X the book's title and the dots standing for the date and time in the copy's name.

### An audiobook's transcript
<!-- id: replace-keeps-audio-transcript; keys: same audio, proven the same, path size date, cloud only, offer to transcribe; src: TextMouth/Services/DuplicateReplacement.swift -->

- An audiobook's transcript comes along only when the new copy's audio is proven to be the same, without reading the audio whole:
  - A book of one audio file that is the very file transcribed, under the same name or another.
  - The same archive or folder imported again, with every audio file at the same path and of the same size.
  - Every audio file the same by path, size, and date.
  - A file only in the cloud proves nothing.
  - A transcript you edited that stays behind, because the audio is not proven the same, leaves its text beside the new copy as a content.md.edited- copy too, and an audiobook that kept its transcript is not offered for transcription afterwards.

### Braille file characters
<!-- id: replace-keeps-braille-characters; keys: BRF, BRL, Eurobraille, six-dot, braille ASCII, Book Information; src: TextMouth/Services/DuplicateReplacement.swift, TextMouth/Parsers/BrailleFileCode.swift -->

- A BRF or BRL book keeps the braille file characters it is read with (see Book Information, in [The Library window](book-information.md)).
  - When the new copy is the very same file, TextMouth reads it again in those characters if the copy was read in others and its bytes are not certainly Unicode braille patterns.
  - When the copy can't be read so, nothing is replaced, and the question stays, with the reason, as in "“Ledger” can't be read as Eurobraille, six-dot (German-speaking countries): Line 3 holds “é”, which is not Eurobraille.
    Nothing was changed."
  - A copy with other bytes keeps what its import read.

### Braille code
<!-- id: replace-keeps-braille-code; keys: Braille Code pop-up, UEB, liblouis table, Braille setting; src: TextMouth/Services/DuplicateReplacement.swift -->

- A braille book keeps the braille code its existing copy is read with: when the new copy is the very same file and was translated with another code, TextMouth reads it again with the existing copy's.
  A BRF or BRL book whose characters and code both differ is read again once, with both.
  A book's code does not record whether you chose it in Book Information's Braille Code pop-up or it was only the Braille setting when the book was added, so after changing the setting, importing the same file again and choosing Replace Existing keeps the old code.
  Choose the new one in Book Information afterwards.
  A code this Mac no longer offers, as one of VoiceOver's tables a macOS update removed, stops the replacement by name, so the code is never lost without a word.
  Nothing is replaced and the question stays, and choosing another code for the existing copy in Book Information, or Keep Both, is the way on.
  A copy with other bytes, such as a second edition, is translated with the Braille setting's code.

### Text encoding
<!-- id: replace-keeps-text-encoding; keys: Text Encoding pop-up, charset, byte order mark, Shift JIS, guessed encoding; src: TextMouth/Services/DuplicateReplacement.swift, TextMouth/Parsers/TextEncodingGuesser.swift -->

- A plain text, Markdown, or HTML book keeps the encoding you chose in Book Information's Text Encoding pop-up, when both of these hold:
  - The choice was yours.
    Automatic, and an encoding TextMouth guessed, are what the new copy's own import does, so there is nothing to carry.
  - The choice is about this file: the new copy is the very same file, or its bytes name no encoding of their own (no byte order mark, no valid UTF-8, no declaration) and every byte reads in the encoding you chose.
  - A new copy that names its encoding, or that your choice can't read, is not the file the choice was made about: it keeps what its import read, and Replace Existing goes ahead.
    The very same file that your choice can't read is refused, with the reason, as in “Moby-Dick” can't be read as Shift JIS (Japanese): it holds bytes that are not valid in that encoding.
    Nothing was changed.

### When the old copy's files are removed
<!-- id: replace-keeps-old-files-removed; keys: ORPHAN_ID_LISTED, put back from Trash, package, old copy left beside; src: TextMouth/Services/DuplicateReplacement.swift, TextMouth/Services/FileImportService.swift -->

- The existing copy's files are removed only once the library holds the new copy, so a stop at any moment leaves the old book whole, or the new copy with everything carried over.
  - An old copy left beside the new one, or put back from the Trash with Finder, is never added to the library as a second book: its package names the book the new copy now is, and the debug log records an ORPHAN_ID_LISTED line for it at the launch that finds it.

## While Replace Existing works
<!-- id: while-replace-existing-works; keys: spinner, Replacing, off the main thread, still carrying out your last answer, changed while being replaced; src: TextMouth/ViewModels/LibraryViewModel+Duplicates.swift, TextMouth/Models/ImportDecision.swift -->

- Replace Existing makes the new copy ready off the main thread, so TextMouth's windows and VoiceOver stay responsive while a long braille book is read again in the code its old copy was read in.
- The question's sheet dims its buttons, shows "Replacing “X”.
  This can take a moment." with a spinner, and, if the work is still going after a second, VoiceOver hears the same words once.
- Another answer to the same question meanwhile does nothing and says "TextMouth is still carrying out your last answer.
  Wait until it finishes."
- When the work ends, TextMouth checks that nothing changed under it: the question is still the one being asked, the library is not moving, the existing copy is the one the work was made from, and it is still free to replace.
  If anything changed, the new copy is put back as its import published it, both copies stay as they were, and the question stays with the reason, as in "“X” changed while it was being replaced, so TextMouth left both copies as they are.
  Choose Replace Existing again."
- Quitting waits for the work, as it waits for a text that is read again.

## When Replace Existing waits
<!-- id: when-replace-existing-waits; keys: open in a reader, being transcribed, being exported, audio editor, cloud, Error; src: TextMouth/Services/DuplicateReplacement.swift, TextMouth/Models/FeedBookUse.swift -->

- Replace Existing waits
  - while the existing copy is in use,
  - while its text is being read again in another encoding or with another braille code (see [The Library window](book-information.md)),
  - while something it would keep is only in the cloud, where nothing is downloaded for it,
  - and while TextMouth moves books between folders or rebuilds its data directory.
- The question stays open, nothing has changed, and the reason appears above its buttons, which VoiceOver reads as "Error: " and the sentence, and speaks once as it appears.
- Once the cause is gone, choose Replace Existing again.
- With X the title of the existing copy, the sentences are:
  - Open in a reader: "“X” is open in a reader.
    Close it, then choose Replace Existing again."
  - Being transcribed: "“X” is being transcribed, and replacing it now would lose the transcript.
    Wait until the transcription ends, or cancel it, then choose Replace Existing again."
  - Being exported: "“X” is being exported, and replacing it now would stop the export.
    Wait until the export ends, then choose Replace Existing again."
  - Its audio being edited in the audio editor, or saved from it: "The audio of “X” is being edited.
    Close the audio editor or wait for it to save, then choose Replace Existing again."
  - Its text being read again in another encoding, from the Text Encoding pop-up in Book Information: "TextMouth is reading “X” again in another encoding.
    Try again when that finishes."
  - Its text being read again with other braille file characters, from the Braille File Characters pop-up in Book Information: "TextMouth is reading “X” again with other braille file characters.
    Try again when that finishes."
  - Its text being read again with another braille code, from the Braille Code pop-up in Book Information: "TextMouth is reading “X” again with another braille code.
    Try again when that finishes."
  - Being replaced already: "TextMouth is replacing “X” with the new copy.
    Try again when that finishes."
    Edit Text, Redo Text Extraction, a re-read from Book Information, and a reader opening the book say it too, until the replacement ends.
  - Files only in the cloud: "Some files of “X” are only in the cloud, and replacing it now would leave them behind.
    Download the book, then choose Replace Existing again."
  - Books moving between folders: "TextMouth is moving books between folders.
    Wait until that finishes, then choose Replace Existing again."
  - The data directory being rebuilt: "TextMouth is rebuilding its data directory.
    Wait until that finishes, then choose Replace Existing again."

## When a replacement fails
<!-- id: when-replacement-fails; keys: Could not replace duplicate, edited text, library index; src: TextMouth/ViewModels/LibraryViewModel+Duplicates.swift, TextMouth/Services/DuplicateReplacement.swift -->

- A replacement that fails leaves the question open with "Could not replace duplicate: " and the reason, and both copies as they were, the new copy as it was imported.
- Two reasons are TextMouth's own words:
  - "TextMouth couldn't keep the edited text of the copy in your library beside the new copy's text, so it left both copies as they are."
  - "TextMouth couldn't save the library's index, so it left both copies as they are."
- Any other failure gives the system's own reason.

## When the replaced copy's files can't be removed
<!-- id: when-replaced-copy-files-cant; keys: could not be moved to the Trash, Move to Trash instead of deleting, hidden name; src: TextMouth/Services/DuplicateReplacement.swift, TextMouth/Models/RemovalWording.swift -->

- When the new copy has taken the place of the existing one but the existing copy's files cannot be removed, the replacement stands.
  And the library's alert says "The new copy replaced “X”, but the old copy's files could not be moved to the Trash and stay in its folder: " and the system's reason.
  With "deleted" in place of "moved to the Trash" while Move to Trash instead of deleting is off.
- With the Trash off, TextMouth first renames the old package to a hidden name, then deletes it, and what cannot be deleted stays hidden until the next import into that folder removes it.

## A replaced book open in Edit Text
<!-- id: replaced-book-open-edit-text; keys: Edit Text has stopped, Edit Manifest, editor session; src: TextMouth/Models/BookTextEditWording.swift, TextMouth/Platform/macOS/Services/BookTextEditor.swift -->

- If the replaced book was open in Edit Text, VoiceOver says, once, "Edit Text has stopped for X, since a new copy replaced it.
  Choose Edit Text again to edit the new copy's text.", with X the book's title, so that you are not left saving into an editor nothing listens to (see [Editing a book's text](editing-book-text.md)).
- An Edit Manifest session for the replaced book ends without a word.

## Offer to transcribe after importing
<!-- id: offer-transcribe-after-importing; keys: Offer to transcribe, Playback tab, No Thanks, Not Now; src: TextMouth/ViewModels/TranscriptionOffers.swift, TextMouth/Models/TranscriptionWording.swift -->

- With Offer to transcribe after importing an audiobook on, in the Playback tab of Settings, TextMouth asks after each audiobook it imports, on a Mac that can transcribe, whether to transcribe it, after that import's other questions (see [Transcribing an audiobook](transcribing.md)).

## Questions about imports wait their turn
<!-- id: questions-about-imports-wait-their; keys: queue of questions, ImportDecisionQueue, Return, Escape, Duplicate Book Found 2 of 5; src: TextMouth/Models/ImportDecisionQueue.swift, TextMouth/Models/ImportDecision.swift -->

- These questions wait their turn.
- They are asked one at a time, in the order they arose, in the Library window where the import started, or in another Library window if that one has closed.
- When there is more than one, each title gives its place, as in "Duplicate Book Found, 2 of 5".
- Return chooses Keep Both, Create Folder, or Transcribe, and Escape chooses Cancel, Keep, No Thanks, or Not Now.
- Replace Existing and deleting an original file are never on a key.
- A question that appears while you are working in another window, such as a reader, waits in its Library window without taking focus or speaking.

### A duplicate's new copy waits in the library
<!-- id: duplicate-new-copy-waits-library; keys: .awaitingDuplicateAnswer, Duplicate Copies Moved to the Trash, Put Back, unanswered; src: TextMouth/Services/DuplicateReplacement.swift, TextMouth/Models/ImportDecision.swift -->

- A duplicate's new copy waits in the library, in a package marked with a hidden file, .awaitingDuplicateAnswer, until you answer.
- When TextMouth closes with the question unanswered, the next launch moves the copy to the Trash, whatever Settings says about the Trash, and says so in an alert titled "Duplicate Copies Moved to the Trash".
  As in "TextMouth moved the new copy of “Moby-Dick” to the Trash, because the question whether to keep it as a duplicate was never answered before TextMouth closed.
  To get it back, open the Trash and choose Put Back."
- For two or three copies it says, with the titles listed as “A” and “B” for two and “A”, “B”, and “C” for three, "TextMouth moved the new copies of “A”, “B”, and “C” to the Trash, because the questions whether to keep them as duplicates were never answered before TextMouth closed.
  To get them back, open the Trash and choose Put Back.", and for more, "TextMouth moved 4 new copies of duplicate books to the Trash, because the questions whether to keep them as duplicates were never answered before TextMouth closed.
  To get them back, open the Trash and choose Put Back."
- A copy whose question is less than a day old stays, since another Mac sharing the library may be asking it.
- The file the copy came from is never deleted.

### When Keep Both and Replace Existing keep the question
<!-- id: when-keep-both-replace-existing; keys: library can't be reached, files gone, waiting mark, Choose Cancel; src: TextMouth/Models/ImportDecision.swift, TextMouth/ViewModels/LibraryViewModel+Duplicates.swift -->

- Keep Both and Replace Existing keep the question, and say why, when they cannot keep the new copy, each sentence naming the book:
  - While the library can't be reached, as when its drive dropped off: "The library can't be reached, so TextMouth can't keep the new copy of “Moby-Dick”.
    Answer again once it is back."
    The copy is intact, so there is nothing to cancel.
  - When the copy's files are gone, taken by another Mac's launch or in Finder: "The files of the new copy of “Moby-Dick” are no longer in the library, so it can't be kept.
    Choose Cancel, then import the file again."
    The original file is kept.
  - When Keep Both cannot take the waiting mark off the copy: "TextMouth could not keep the new copy of “Moby-Dick”.
    Choose Cancel to discard the copy, then import the file again."

### A book opened from Finder
<!-- id: book-opened-from-finder; keys: Finder, Open With, opens after questions; src: TextMouth/ViewModels/LibraryViewModel+Import.swift -->

- A book opened from Finder opens once it is in the library and its questions are answered.

### Cancel and the questions
<!-- id: cancel-questions; keys: withdrawn questions, discard copy, offer dropped, ZIP books stay; src: TextMouth/Models/ImportDecisionQueue.swift, TextMouth/ViewModels/LibraryViewModel+Import.swift -->

- The progress overlay's Cancel button also withdraws the questions of the imports started before it was pressed, those waiting and any still to come:
  - A duplicate's new copy is discarded.
  - An original file is kept.
  - A ZIP's books stay where they are.
  - An offer to transcribe is dropped.
