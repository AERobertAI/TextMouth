# Exporting text as spoken audio
<!-- id: text-as-spoken-audio; keys: ; src: -->

Part of [TextMouth's documentation](../../README.md).

Part of version 0.4.2.
A text book can be spoken by its voice into one audio file, with a chapter for each heading.

## The options
<!-- id: options; keys: ; src: -->

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
    Its hint is "The kind of audio file.
    M4B is an audiobook; M4A and MP3 play in more apps.
    M4B and M4A have a chapter for each heading; an MP3, for each of the first 255."
  - From, a pop-up of the book's beginning, "Beginning of the book", and each heading.
    Its hint is "Where the spoken audio begins: the beginning of the book, or a heading."
  - To, a pop-up of each heading and "End of the book".
    Its hint is "The heading whose section ends the spoken audio, with any headings under it, or the end of the book."
  - Speed, a slider, read as a value such as "200 words per minute".
    Its hint is "How fast the voice speaks in the audio file.
    It starts at this book's speed."
  - Pitch, a slider, read as "Normal (1.0x)" or "1.5x".
    Its hint is "How high the voice sounds in the audio file.
    It starts at this book's pitch."
  - A line naming the voice, as in "Voice: Moira", and a line about Apple's licence: "Speech made with the Mac's voices is for your personal, non-commercial use, under Apple's licence."
- A heading is listed as the headings panel says it, as in "Chapter 3 - level 1", or "Skipped, Notes - level 2" for one you skip.
- A book with no headings has no From and To.
  The options say "This book has no headings, so all of it is exported."
- The options have no group of their own.
  VoiceOver reaches them one after another, right after the checkbox, as it does the braille options.
- The voice, speed, and pitch start from what the book is read with.

## MP3 and chapters
<!-- id: mp3-chapters; keys: ; src: -->

- M4B and M4A have a chapter at each heading.
  An MP3 can hold chapters for the first 255 headings only.
- While MP3 is chosen for a range of more than 255 headings, a line follows the Format pop-up: "This range has 300 headings, and an MP3 has chapters for the first 255 only.
  Choose M4B to have a chapter for each of them."
  Headings you skip are not counted.
- The end of such an export says it too: "The MP3 has chapters for the first 255 of its 300 headings; export it as M4B to have a chapter for each."

## While it runs
<!-- id: while-it-runs; keys: ; src: -->

- Export speaks the book chapter by chapter, and the progress says which: "Speaking chapter 2 of 12…".
  Then it says "Encoding the audio file…".
- The file is named after the book and the range, as in "Middlemarch - Audio" for the whole book, or "Middlemarch - Chapter 2 to End".
- Stop keeps the chapters already spoken.
  Its hint is "Stops the export.
  The chapters already spoken are kept, so exporting the same range at the same speed and pitch goes on from there, before TextMouth quits, a different export of spoken audio starts, or the book's voice, text, substitution rules, or pauses change."
- The end says what was kept: "Kept 5 of 12 chapters: export the same range at the same speed and pitch to go on from chapter 6, before TextMouth quits, a different export of spoken audio starts, or the book's voice, text, substitution rules, or pauses change."
  There is a form for all chapters and one for a single chapter.
- Kept chapters live in this Mac's Caches folder, in a folder named Speech Export.
  TextMouth empties it at the next launch.
- Quitting TextMouth during an export stops it as Stop does, then quits.
  It waits at most 5 seconds.
  The chapters already made stay until the next launch empties them.
  - A small window titled "Quitting TextMouth" appears, and VoiceOver says: "TextMouth is finishing up before it quits: stopping a speech export with the chapters it finished kept.
    It will quit as soon as that is done."
    With several exports it says "stopping 2 speech exports with the chapters they finished kept".
  - Pressing Command-Q again, or choosing Quit in the Dock again, says the same words again and does not cut the export off (0.4.4).
  - Logging out, restarting, or shutting down waits for the export to stop, up to 5 seconds, and is not cancelled.
- The spoken chapters are deleted only after the finished file is in the chosen folder, so a file that can't be put there loses no chapters.

## When a book can't be spoken
<!-- id: when-book-cant-be-spoken; keys: ; src: -->

- Each reason is said before anything is spoken, with what to do:
  - A Personal Voice: "“Ana” is a Personal Voice, which macOS can't record to a file.
    Choose another voice for this book with the Voice button in its reader, then export again."
  - No voice: "No voice is installed to speak it.
    Add a voice in System Settings, Accessibility, Spoken Content, then export again."
  - Too little disk: "There isn't room on the disk for it: it needs about 400 MB, and TextMouth keeps 1 GB free.
    Free some space, then export again."
  - A second export: "TextMouth is already exporting spoken audio, which it does one export at a time.
    Export this once that one has finished."
  - Nothing to speak: "The part of the book chosen has no words to speak."
  - Headings that changed: "The book's headings changed after the Export dialog opened.
    Close it, open it again, and choose the range again."
- A chapter the voice can't speak fails the whole export:
  - "The voice made no sound for “Chapter 3”.
    Check that the book's voice speaks the book's language."
  - "The voice stopped making sound partway through “Chapter 3”, and TextMouth stopped waiting for it."
  - Sound counts when the chapter's loudest sample rises above 0.001, which is -60 dBFS.
    The chapters spoken before the failing one are kept.
- Export refuses the folder where spoken chapters are kept, for any kind of export, and anything inside it: "Export can't write into the folder where TextMouth keeps spoken chapters, since TextMouth empties it.
  Choose another folder."

## A caution about listening
<!-- id: caution-about-listening; keys: ; src: -->

- While a spoken-audio export runs, listening to a book in TextMouth hasn't been tested.
  If the reading jumps back to words it has already said, stop the export or pause the reading.

## What is not done yet
<!-- id: what-not-done-yet; keys: ; src: -->

- Time ranges, a selection, and the formats WAV, AIFF, CAF, Apple Lossless, and FLAC are not offered.
- Each chapter is not encoded while the next is spoken: the file is encoded once, at the end.
- Premium and neural voices were not measured.
- Whether VoiceOver reads the MP3 line, "Reading the book's headings…", and the unreadable-text line well in the drawn dialog was not checked by hand.
