# Exporting text as spoken audio
<!-- id: export-spoken-audio; keys: speech export, M4B, M4A, MP3, audiobook from text, synthesize; src: TextMouth/Models/SpeechExportWording.swift, TextMouth/Services/SpeechExport/SpeechExportJob.swift, TextMouth/Views/Export/SpeechExportOptionsView.swift -->

Part of [TextMouth's documentation](../../README.md).

Part of version 0.4.2.
A text book can be spoken by its voice into one audio file, with a chapter for each heading.

## The options
<!-- id: export-spoken-audio-options; keys: Format, From, To, Speed, Pitch, voice licence, headings range; src: TextMouth/Views/Export/SpeechExportOptionsView.swift, TextMouth/ViewModels/SpeechExportOptionsState.swift, TextMouth/Models/SpeechExportWording.swift -->

- The Export dialog of a text book has a checkbox named "Text as spoken audio".
  Its hint is "The book's text spoken by its voice into one audio file, with a chapter for each heading."
  It gives no size, since the size is known only once the book is spoken.
- The dialog reads the book's headings only once you check it.
  Until then it opens at once.
  While it reads, it says "Reading the book's headings…".
  If the text can't be read, it says "This book's text can't be read, so it can't be spoken into an audio file."
- The options follow the checkbox, in this order.
  They are dimmed while an export runs.
  - Format, a pop-up with M4B, M4A, and MP3.
    Its hint is "Chooses the file format.
    M4B is an audiobook; M4A and MP3 play in more apps.
    M4B and M4A have a chapter for each heading; an MP3, for the first 255."
  - From, a pop-up of the book's beginning, "Beginning of the book", and each heading.
    Its hint is "Where the audio begins: the book's beginning, or a heading."
  - To, a pop-up of each heading and "End of the book".
    Its hint is "The heading whose section ends the audio, with its subheadings, or the end of the book."
  - Speed, a slider, read as a value such as "200 words per minute".
    Its hint is "How fast the voice speaks in the file.
    It starts at the book's speed."
  - Pitch, a slider, read as "Normal (1.0x)" or "1.5x".
    Its hint is "How high the voice sounds in the file.
    It starts at the book's pitch."
  - A line naming the voice, as in "Voice: Moira", and a line about Apple's licence: "Speech from the Mac's voices is for personal, non-commercial use, under Apple's licence."
- A heading is listed as the headings panel says it, as in "Chapter 3 - level 1", or "Skipped, Notes - level 2" for one you skip.
- A book with no headings has no From and To.
  The options say "This book has no headings, so all of it is exported."
- The options have no group of their own.
  VoiceOver reaches them one after another, right after the checkbox, as it does the braille options (see [Exporting braille files](exporting-braille.md)).
- The voice, speed, and pitch start from what the book is read with.

## MP3 and chapters
<!-- id: export-spoken-audio-mp3-chapters; keys: 255 chapters, ID3 chapters, M4B; src: TextMouth/Models/SpeechExportWording.swift, TextMouth/ViewModels/SpeechExportOptionsState.swift -->

- M4B and M4A have a chapter at each heading.
  An MP3 can hold chapters for the first 255 headings only.
- While MP3 is chosen for a range of more than 255 headings, a line follows the Format pop-up: "This range has 300 headings, but an MP3 has chapters for the first 255 only.
  Choose M4B for a chapter for each."
  Headings you skip are not counted.
- The end of such an export says it too: "The MP3 has chapters for the first 255 of its 300 headings; export as M4B for a chapter for each."

## While it runs
<!-- id: export-spoken-audio-while-running; keys: Speaking chapter, Encoding, Stop, kept chapters, Speech Export folder, Quitting TextMouth, Command-Q; src: TextMouth/Services/SpeechExport/SpeechExportJob.swift, TextMouth/Services/SpeechExport/SpeechExportStore.swift, TextMouth/Services/SpeechExport/SpeechExportsUnderWay.swift -->

- Export speaks the book chapter by chapter, and the progress says which: "Speaking chapter 2 of 12…".
  Then it says "Encoding the audio file…".
- The file is named after the book and the range, as in "Middlemarch - Audio" for the whole book, or "Middlemarch - Chapter 2 to End".
- Stop keeps the chapters already spoken.
  Its hint is "Stops the export and keeps the chapters already spoken until TextMouth quits, a different spoken audio export starts, or the book's voice, text, substitutions, or pauses change.
  Exporting the same range at the same speed and pitch goes on from them."
- The end says what was kept: "Kept 5 of 12 chapters until TextMouth quits, a different spoken audio export starts, or the book's voice, text, substitutions, or pauses change.
  To go on from chapter 6, export the same range at the same speed and pitch."
  There is a form for all chapters and one for a single chapter.
- Kept chapters live in this Mac's Caches folder, in a folder named Speech Export.
  TextMouth empties it at the next launch.
- Quitting TextMouth during an export stops it as Stop does, then quits.
  It waits at most 5 seconds.
  The chapters already made stay until the next launch empties them.
  - A small window titled "Quitting TextMouth" appears, and VoiceOver says: "TextMouth is finishing up before it quits: stopping a speech export with the chapters it finished kept.
    It quits when that is done."
    With several exports it says "stopping 2 speech exports with the chapters they finished kept".
  - Pressing Command-Q again, or choosing Quit in the Dock again, says the same words again and does not cut the export off (0.4.4).
  - Logging out, restarting, or shutting down waits for the export to stop, up to 5 seconds, and is not cancelled.
- The spoken chapters are deleted only after the finished file is in the chosen folder, so a file that can't be put there loses no chapters.

## When a book can't be spoken
<!-- id: export-spoken-audio-refusals; keys: Personal Voice, no voice, disk space, silence, -60 dBFS, spoken chapters folder; src: TextMouth/Services/SpeechExport/SpeechExportError.swift, TextMouth/Services/SpeechExport/SpeechExportSpace.swift, TextMouth/Services/SpeechExport/SpeechExportVoice.swift, TextMouth/Services/SpeechExport/SpeechChapterRenderer.swift -->

- Each reason is said before anything is spoken, with what to do:
  - A Personal Voice: "“Ana” is a Personal Voice, which macOS can't record to a file.
    Choose another voice with the Voice button in the reader, then export again."
  - No voice: "No voice is installed.
    Add one in System Settings, Accessibility, Spoken Content, then export again."
  - Too little disk: "The disk lacks room: this needs about 400 MB, and TextMouth keeps 1 GB free.
    Free some space, then export again."
  - A second export: "TextMouth exports one spoken audio file at a time.
    Export this once the current one has finished."
  - Nothing to speak: "The part of the book chosen has no words to speak."
  - Headings that changed: "The book's headings changed after the dialog opened.
    Reopen it and choose the range again."
- A chapter the voice can't speak fails the whole export:
  - "The voice made no sound for “Chapter 3”.
    Check that it speaks the book's language."
  - "The voice stopped partway through “Chapter 3”, and TextMouth stopped waiting."
  - Sound counts when the chapter's loudest sample rises above 0.001, which is -60 dBFS.
    The chapters spoken before the failing one are kept.
- Export refuses the folder where spoken chapters are kept, for any kind of export, and anything inside it: "Export can't write into the folder where TextMouth keeps spoken chapters, which it empties.
  Choose another folder."

## A caution about listening
<!-- id: export-spoken-audio-caution; keys: listening during export, reading jumps back; src: TextMouth/Services/SpeechExport/SpeechExportJob.swift -->

- While a spoken-audio export runs, listening to a book in TextMouth hasn't been tested.
  If the reading jumps back to words it has already said, stop the export or pause the reading.

## What is not done yet
<!-- id: export-spoken-audio-not-done; keys: WAV, AIFF, CAF, FLAC, time ranges, Premium voices; src: TextMouth/Models/SpeechExportWording.swift; status: incomplete; issues: DR26, DR28 -->

- Time ranges, a selection, and the formats WAV, AIFF, CAF, Apple Lossless, and FLAC are not offered.
- Each chapter is not encoded while the next is spoken: the file is encoded once, at the end.
- Premium and neural voices were not measured.
- Whether VoiceOver reads the MP3 line, "Reading the book's headings…", and the unreadable-text line well in the drawn dialog was not checked by hand.
