# Exporting books on the iPhone
<!-- id: exporting-on-iphone; keys: Export…, Export this book, PhoneExportSheet, Choose Folder…, iPhone export, Files, VoiceOver; src: TextMouth/Platform/iOS/Views/Export/PhoneExportSheet.swift, TextMouth/Phone/PhoneExportOffer.swift, TextMouth/Phone/PhoneExportFolder.swift -->

Part of [TextMouth's documentation](../../README.md).
The Mac's Export dialog, its kinds, its file names, and what each format holds are in [Exporting books](exporting-books.md); this page says what the iPhone does the same, and what it does differently.

## Where Export is
<!-- id: iphone-export-entry-points; keys: Export…, Export this book, Actions rotor, context menu, book row, reader controls; src: TextMouth/Phone/PhoneLibraryOffer.swift, TextMouth/Phone/PhoneReaderState.swift, TextMouth/Phone/PhoneReaderControls.swift -->

- In the Library, "Export…" is a command of a book's row: on VoiceOver's Actions rotor and in the row's context menu.
  It comes after "Move to Folder..." and before Move Up, Move Down, and the removal.
  It has no hint.
- In the reader, "Export this book" is an item of the Book Actions menu, after Book Info.
  Its hint is "Opens the Export dialog: the book's audio, its text, or its own file."
  It is drawn as "Export".
- On a folder's row, "Export 12 Books…" is a command after Move Folder... and before Delete Folder..., named by the books in the folder and below it ("Export…" for one).
  It opens one sheet, titled "Export 12 Books", and each book goes into a folder of its own, as on the Mac.
  A folder with no books has no such command.
- Either opens one sheet, titled "Export" and the book's title, as in "Export Moby-Dick".
- Closing the sheet puts VoiceOver's focus back on the row or the button that opened it, or on Book Actions in the reader.

## The sheet's rows
<!-- id: iphone-export-sheet-rows; keys: What to export, Cancel, Close, Stop, switch, Convert to, escape gesture, nothing to export; src: TextMouth/Platform/iOS/Views/Export/PhoneExportSheet.swift, TextMouth/Phone/PhoneExportOffer.swift -->

VoiceOver reads the sheet in this order:

1. The title.
2. Cancel; or Stop while an export runs; or Close once one has ended.
3. Export.
4. "What to export", a heading, then a switch for each kind the book holds, as the Mac's checkboxes are labelled: "Original file, 1.2 MB", "Text as Markdown, about 12 KB".
   - While a text kind's switch is on, its "Convert to" row follows it, a button whose value is the choice and whose hint is that choice's hint (see [Exporting books](exporting-books.md)).
     It opens a list of the choices, with the current one selected.
   - The Convert to choices are Markdown, HTML, RTF, EPUB, BRF, and PEF; "Convert transcript to" and "Convert headings to" are the Mac's.
   - While BRF or PEF is the choice, the braille rows follow (below).
5. The folder row.
6. While an export runs, a progress row, as in "Exporting 3 of 40 items…", whose value VoiceOver gives as a percent.
7. What the last export did.

- The first kind is on, and VoiceOver's focus starts on it a moment after the sheet opens.
  When the book holds nothing the iPhone exports, the sheet says "There is nothing to export."
- Export is dimmed until a folder is chosen and a kind is on.
  Its hint is "Exports the checked items to the folder."
- Every word is the Mac's, so the hints of each kind and format are the ones the Mac's pages list.

## Choosing the folder once
<!-- id: iphone-export-folder; keys: Choose Folder…, Export to, Files app, kept folder, bookmark, iCloud Drive; src: TextMouth/Phone/PhoneExportFolder.swift, TextMouth/Phone/PhoneExportOffer.swift, TextMouth/Platform/iOS/Views/Export/PhoneExportSheet.swift -->

- The folder row reads "Choose Folder…" until a folder is chosen.
  It opens the system's folder picker, the same one the Files app uses, so a folder on the phone, in iCloud Drive, or in another provider can be chosen.
  Its hint is "Chooses the folder the checked items are exported to."
- Once a folder is chosen the row reads "Export to: Downloads", with the folder's name as the system gives it.
  TextMouth keeps the folder, so every later export, from any book, goes there without asking.
  Press the row to choose another.
- A folder that has been moved or deleted, or whose provider has gone, is forgotten, and the row reads "Choose Folder…" again.
- Closing the picker without choosing puts VoiceOver's focus back on the folder row.
- A name already in the folder gets a number, as on the Mac, so nothing there is replaced.
  Each file is made whole inside TextMouth first and copied in only when it is finished, so Stop or a failure never leaves a half-written file in your folder.

## The braille rows
<!-- id: iphone-export-braille-rows; keys: Braille code, Cells per line, Lines per page, Braille page numbers, Line ends, Braille file characters, BRF, PEF; src: TextMouth/Platform/iOS/Views/Export/PhoneBrailleExportRows.swift, TextMouth/Services/Export/BrailleExportWriters.swift -->

While BRF or PEF is chosen, these rows follow Convert to, in the Mac's order and words (see [Exporting braille files](exporting-braille.md)):

- "Braille code", a button valued with the table in words and its language, as in "Unified English Braille, contracted (Grade 2), in English".
  It opens the list the Braille setting has, a heading for each language, and it also lists the tables that only write braille.
  One list stands for the Mac's three pop-ups, Language, Braille code, and Contraction.
- "Cells per line", adjustable, valued "40 cells", from 18 to 80.
- "Lines per page", adjustable, valued "25 lines", from 4 to 50.
- "Braille page numbers", a switch.
- For a BRF only, "Line ends", "CR LF" or "LF", and "Braille file characters".
- The rows start from the Braille setting and keep your choices until the sheet closes.
  When the Braille setting's table can't be used for an export, a line says so and which table the export starts from.
- The rows are dimmed while an export runs.

## Stop, the end, and what is refused
<!-- id: iphone-export-stop-end; keys: Stop, Close, Exported 3 items, Couldn't export, too little memory, swipe away, escape gesture, nested too deeply; src: TextMouth/Platform/iOS/Views/Export/PhoneExportSheet.swift, TextMouth/Phone/PhoneExportMemoryCheck.swift, TextMouth/Phone/PhoneExportQuestion.swift, TextMouth/Phone/PhoneExportWording.swift -->

- Export starts the export, and Cancel becomes Stop, hinted "Stops the export.
  The file being made is not kept."
  The files finished so far stay in the folder.
  VoiceOver's escape gesture presses Stop, and the sheet can't be swiped away while an export runs.
- Locking the screen does not cut a file off: TextMouth asks the phone for time to finish.
- The sheet stays open at the end, where the Mac's dialog closes, so what was said can be read again.
  Cancel becomes Close, and the end is the Mac's sentence, as in "Exported 3 items to Downloads.", or "Couldn't export Moby-Dick - Text.brf: TextMouth could not translate this braille."
- A book whose text is too large for the memory the phone has left is refused before it is converted, with the file's name and this sentence:
  "The iPhone has too little memory free to convert this book now.
  Close other apps, then export again."
  The other books and kinds still export.
- A chapter that nests quotes, lists, or emphasis too deeply puts the Mac's question (see [Exporting books](exporting-books.md)) in an alert over the sheet.
  Its message says what each button does: Export as Written, which is the default; Export Every Such Chapter as Written, shown while more may follow; and Cancel Export.
  The escape gesture presses Cancel Export, and so does Stop.
- The escape gesture presses Stop while an export runs, also while the spoken audio file is made and Close is in the bar.
- Only one export runs at a time.
  While one does, Export is dimmed in any other sheet.
  Its hint says "Another export is running.
  Its card is at the top of the Library."

## Spoken audio
<!-- id: iphone-export-spoken-audio; keys: Text as spoken audio, Format, From, To, Speed, Pitch, card, Live Activity; src: TextMouth/Platform/iOS/Views/Export/PhoneSpeechExportRows.swift, TextMouth/Phone/PhoneExportSession.swift, TextMouth/Platform/iOS/Services/PhoneExportBackgroundTask.swift, TextMouth/Platform/iOS/Views/Library/PhoneExportProgressCard.swift, TextMouth/Phone/PhoneExportOffer.swift -->

"Text as spoken audio" is the last switch, for a text book, one book at a time, as on the Mac.
Its rows follow it, in the Mac's words: "Format" (M4B, M4A, or MP3), "From" and "To" (or the line saying the book has no headings), "Speed" and "Pitch" (adjustable), "Voice: Moira", and a line about Apple's licence in the iPhone's words.
A Personal Voice, or no voice, is refused before anything is spoken, in sentences that name the iPhone's own Settings.

- The export goes on with the screen locked and with the sheet closed.
  Once the audio file is being made, Close takes Stop's place in the bar, hinted "Closes Export.
  The export goes on, and the Library shows how far it has come."
  VoiceOver says "You can close this.
  The export goes on."
  Its focus moves to a Stop row under the progress, so it never rests on a button whose meaning changed.
- Closed, the export is a card at the top of the Library, after the title: the export's title, how far it has come, and Stop.
  The system shows it too, as a Live Activity, with a Cancel that stops it as Stop does.
  At the end the card says what the export did and has Close.
  The end is announced without cutting off what VoiceOver is saying.
  When you close the sheet while the audio file is made, focus goes to the card's title.
  When the export ends, you hear it, and focus stays where you are, unless it was on the card's Stop, which has gone; then it goes to the card's title.
  Once you close the card, focus goes to the Library's first row.
- Stop keeps the chapters already spoken for a week, through closing the app.
  Exporting the same range again at the same speed and pitch goes on from them.
  The sentences at the end say "for a week", where the Mac's say "until TextMouth quits".
- When iOS stops the export, by its expiry or by Cancel in the Live Activity, the end begins "iOS stopped this export.", which your own Stop never says.
  The kept chapters are told as for any Stop.
- Locking the screen is fine.
  Closing TextMouth in the app switcher stops the task without a word, and the chapters spoken stay for the week.
- The escape gesture still presses Stop, never Close.

## Several books and Share…
<!-- id: iphone-export-several-share; keys: Export 12 Books, Share…, folder, files just exported, popover, iPad; src: TextMouth/Phone/PhoneLibraryOffer.swift, TextMouth/Phone/PhoneExportOffer.swift, TextMouth/Platform/iOS/Views/PhoneShareSheet.swift, TextMouth/Platform/iOS/Views/Export/PhoneExportSheet.swift -->

- A folder's books are exported at once from the folder's row, each into a folder of its own named for the book, with the Mac's file names inside it.
  Spoken audio is one book's, so a folder's export lists no such switch.
- After an export that wrote files, "Share…" follows what the export did, hinted "Sends the files just exported to another app or person."
  It opens the system's share sheet for those files, which are in the folder you chose, so TextMouth holds that folder open for as long as the sheet is up.
  On an iPad the sheet is a popover from the button; on an iPhone it is a sheet.
  Closing it puts VoiceOver's focus back on Share….
- Settings' Share Logs… uses the same sheet.

## What the iPhone doesn't export yet
<!-- id: iphone-export-not-yet; keys: Word, not yet, .doc, RTF; src: TextMouth/Phone/PhoneExportOffer.swift; status: incomplete; issues: FR31 -->

- Word 97-2003 (.doc) isn't a Convert to choice, since only the Mac writes it.
  RTF opens in Word, with its headings at their outline levels.
