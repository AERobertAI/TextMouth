# Editing audio
<!-- id: editing-audio; keys: audio editor, Edit Audio, no waveform, VoiceOver editing; src: TextMouth/Views/AudioEditor/AudioEditorView.swift, TextMouth/Views/AudioEditor/AudioEditorWording.swift -->

Part of [TextMouth's documentation](../../README.md).

TextMouth edits an audiobook's audio, a recording's or an imported one's, in an editor window made for the keyboard, VoiceOver, and a braille display; nothing in it needs a waveform.

## Opening the editor
<!-- id: audio-editor-opening; keys: Edit Audio…, Book menu, context menu, one editor per book, several tracks, DAISY; src: TextMouth/Views/AudioEditor/AudioEditorWording.swift, TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorLauncher.swift, TextMouth/ViewModels/LibraryViewModel+AudioEditing.swift; status: incomplete; issues: DR30 -->

Opening the editor:

- Edit Audio… is in a reader's Book menu, after Delete Transcript…, and first among the audio commands of a library row's context menu and its actions in VoiceOver's Actions menu, for one audiobook kept in a package of its own.
  A feed's episode can't be edited while it belongs to its feed, and says "An episode in its feed can't be edited."
  Move to Library… makes it a book of the library's own, and so editable.
- A book of several tracks asks which one to edit, in a pop-up listing them by chapter name: the editor works on one track at a time.
  A book whose manifest plays stretches of its tracks as sections, as a DAISY audiobook's does, can't be edited yet.
- A book open in a reader is closed there first, VoiceOver saying why, and opens again when the editor closes.
- Each book has one editor window, titled "Edit Audio:" and the book's title, followed by the track's name for a book of several; choosing Edit Audio… again brings it forward.
  When the book's edit history can't be read, a copy of it is kept in the book's package, and the editor asks whether to start over with no edits.

## The editor window
<!-- id: audio-editor-window; keys: Position, Status, Last message, button groups, Shortcuts tab, Audio Editor shortcuts; src: TextMouth/Views/AudioEditor/AudioEditorView.swift, TextMouth/Views/AudioEditor/AudioEditorCommandViews.swift, TextMouth/Views/AudioEditor/AudioEditorCommands.swift, TextMouth/Views/AudioEditor/AudioEditorWording.swift -->

The window:

- VoiceOver starts on Position, which says where the cursor is in words, as in "12 minutes, 4.3 seconds of 48 minutes", and shows it as a clock, as in "12:04.3 of 48:00".
  Status says the same with the chapter and the selection, and Last message repeats the last announcement, for a braille display.
  Nothing is announced while the audio plays unless you ask, as with Where Am I.
- Every command is also a button, in four groups under the headings Listen and Move, Select and Mark, Edit, and Save and Export, and each button's hint says what it does and its shortcuts in words, as they are set and as the Shortcuts tab says them, as in "Shortcut: Shift + J."
  A command that needs a selection, or something to paste, is dimmed without one.
- The editor's shortcuts are a group of their own, Audio Editor, in the Shortcuts tab of Settings.
  They work only while an editor window is in front, never in a sheet over it, so they can share keys with the reader.
  The keys below are the defaults.

## Listening and moving
<!-- id: audio-editor-listening; keys: play, pause, skip, jump, Go to Time, chapter marker, next pause; src: TextMouth/ViewModels/AudioEditorModel+Listening.swift, TextMouth/Services/AudioEditing/AudioEditorPlayer.swift, TextMouth/Views/AudioEditor/AudioEditorWording.swift -->

Listening and moving:

- Space or K plays and pauses; S stops, and goes back to where playing began.
- J or Comma moves back one second, and L or Period forward one; Shift-J and Shift-L move ten seconds; Option with J, Comma, L, or Period moves a tenth of a second.
- Command-Up Arrow and Command-Down Arrow go to the start and the end; G goes to a time you type, such as 12:04.3, 1:02:03, or 75.5.
- Option-Command-Up Arrow and Option-Command-Down Arrow go to the previous and the next chapter marker.
- N and Shift-N go to where the sound after the next or the previous pause begins, saying how long the pause was; W says where the cursor is.
- While the audio plays, a move carries it on from the new place; otherwise a move plays half a second there, when "Play half a second after each move", in the Audio Editing group and on by default, says so.
  The small steps say nothing, since Position and the half second tell where they went; every jump says where it landed.

## Selecting and marking
<!-- id: audio-editor-selecting; keys: selection, markers, pauses, silence detection, Markers sheet, Rename marker; src: TextMouth/ViewModels/AudioEditorModel+Selecting.swift, TextMouth/Services/AudioEditing/AudioEditorLevels.swift, TextMouth/Views/AudioEditor/AudioEditorMarkersSheet.swift, TextMouth/Views/AudioEditor/AudioEditorWording.swift -->

Selecting and marking:

- I and O mark the selection's start and end at the cursor.
- Option-N selects from the cursor to the next pause, and Option-Shift-N back to the previous one: that is how a phrase is selected.
- C selects the chapter the cursor is in, Command-A selects everything, and Escape clears the selection.
- Shift-W says where the selection starts and ends, and how long it is; P plays it.
- A pause is at least 0.4 seconds, longer than a breath between words, quieter than a level 15 decibels above the recording's background (the level of its quietest tenth), that level kept between minus 60 and minus 30 decibels.
- M drops a marker at the cursor, even while playing.
  Shift-M lists the markers, the chapter markers, and the pauses, each row read whole, once, as in "Marker 3, Intro, at 1 minute, 4 seconds".
  Each row then has buttons, which name the row, as in "Delete Marker 3".
  A marker's buttons are Go To, Rename, and Delete, a chapter marker's are Go To, Rename, and Remove, and a pause's are Go To and Select.
  They are buttons, and also the row's VoiceOver actions.
  Rename opens a field in the row, with Save Name, which Return presses, and Cancel; while a name is being typed, Escape presses that Cancel, once the keyboard has left the field, and Close takes Escape only while no name is being typed.
  Markers follow the sound through edits and are kept with the edits of the file they are in, so the next window on that file, the book's or one of its tracks, shows them again, in its list too.
  Revert to Original deletes them, saying so before and after, and Redo doesn't bring them back.

## Editing
<!-- id: audio-editor-editing; keys: cut, copy, paste, trim, insert silence, punch in, filter preset, undo; src: TextMouth/ViewModels/AudioEditorModel+Editing.swift, TextMouth/ViewModels/AudioEditorModel+PunchIn.swift, TextMouth/ViewModels/AudioEditorModel+Filters.swift, TextMouth/Views/AudioEditor/AudioEditorFilterSheet.swift, TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorEditMenu.swift, TextMouth/Views/AudioEditor/AudioEditorWording.swift -->

Editing:

- Delete or Command-X cuts the selection, Command-C copies it, and Command-V pastes at the cursor or over the selection.
  A Paste right after a Cut, with nothing selected, moves the audio, as one edit.
  Up to ten minutes is kept for Paste, while the disk keeps a gigabyte free; a longer cut can still be moved by a Paste right after it.
- T trims to the selection, as one edit.
  Shift-S inserts silence of a length you type.
  Shift-C sets a chapter marker at the cursor with a title you type, renaming one already there.
  In Go to Time, Insert Silence, Insert Chapter Marker, and a rename row, one press of Return runs the command once.
- F applies a filter preset to the selection or the whole file.
  Its Preview plays up to 20 seconds of it filtered without applying anything, and while "Preview filters before applying", on by default, says so, the first Apply previews and the second applies.
  Apply's hint says what a press does now: that it plays the filtered audio first, until that preset has been previewed on that target, through Apply or Preview, since the sheet opened; or that it applies the filter.
  With every preset deleted in Settings, Apply Filter starts VoiceOver on Cancel, since there is no preset to start on.
- R punches in: it says what it will record and from which microphone, beeps, and records over the selection, or, with nothing selected, inserts at the cursor.
  R, S, or Space ends the recording and selects it, and Escape discards it.
  Microphone for Punch In chooses the microphone, the one the Record window remembers too, apart from the input macOS uses for everything else.
- Command-Z and Shift-Command-Z undo and redo; their buttons are named for the edit, as in "Undo Cut 2.5 Seconds".
- The main Edit menu's Undo, Redo, Cut, Copy, Paste, and Select All are the editor's own while its window is in front, Undo and Redo named as their buttons are, and each available when its button is; in a sheet over the editor, and in every other window, they keep their usual meaning.

## Saving and exporting
<!-- id: audio-editor-saving; keys: save, revert to original, Audio Info, bookmarks move, close window, quit with unsaved edits; src: TextMouth/ViewModels/AudioEditorModel+Saving.swift, TextMouth/Views/AudioEditor/AudioEditorFileSheets.swift, TextMouth/Services/AudioEditing/AudioExportFormat.swift, TextMouth/Views/AudioEditor/AudioEditorWording.swift; status: incomplete; issues: DR29 -->

Saving and exporting:

- Command-S saves into the book's file, in the format it keeps, saying the length and the format first; a save that takes a while announces each quarter.
- A save moves the book's bookmarks and its saved reading position with the sound: one before every edit stays, one after an edit moves with the sound, and one inside a stretch cut or trimmed away goes to where that stretch was.
  In a book of several tracks, only those in the track saved move.
  A bookmark keeps its number and note.
- Shift-Command-E exports to a file and a format you choose.
- A save or an export writes the chapter markers into every format the editor writes: an MPEG-4 file's chapter track, an MP3's chapter frames, and a WAVE, AIFF, or CAF file's marker list.
  - A WAVE or AIFF file's markers are read back as the book's chapters.
  - TextMouth doesn't read CAF markers back, so a save in place of a CAF book says "TextMouth doesn't read chapter markers back from CAF files, so this book won't list its 3 chapter markers once saved."
  - If the markers can't be written into the file, the file keeps its audio without them, and the save says "Its 3 chapter markers couldn't be written into the file, so it has none."; the debug log records AUDIO_MARKERS_NOT_WRITTEN.
- Option-Command-Z, after asking, reverts to the original audio, when the original is kept; Redo brings the edits back.
- Command-I shows Audio Info: the length, the file, the format a save writes, the edits, whether the original is kept, and Original audio for this book, which gives the book a policy of its own (below).
- Closing the window with edits not saved asks Save, Discard, or Cancel.
  Discard returns to the audio as saved, and the next time you edit the book, Redo brings the edits back.
  The window stays open while a change is under way or a punch-in records, saying so.
  Quitting TextMouth asks the same about each editor with edits not saved, one at a time, in the order of their books' titles, its window brought forward: Discard there undoes the edits, which Redo brings back the next time you edit the book.
  Cancel, or a save that fails, keeps TextMouth open, and an editor still working, or recording a punch-in, keeps it open and says so.

## The waveform
<!-- id: audio-editor-waveform; keys: sighted helpers, drawing; src: TextMouth/Views/AudioEditor/AudioEditorWaveform.swift -->

A waveform of the audio, with the cursor, the selection, the chapter markers, and the markers, is drawn for sighted helpers; VoiceOver never meets it, and no command needs it.

## Kinds of edit
<!-- id: audio-editor-edit-kinds; keys: edit list, chapter markers follow, refused edit; src: TextMouth/Models/AudioEdit.swift, TextMouth/Models/AudioEditTimeline.swift, TextMouth/Models/AudioEditWording.swift -->

Edits: trimming either end, cutting, moving a stretch, inserting silence or audio (a paste, or a recording at the cursor), replacing a stretch with a new take (punch-in), adding, renaming, and removing chapter markers, filters, and volume changes.
Every edit lands on the same sample however often it is applied, and an edit that doesn't fit the audio is refused with a sentence saying why.
Chapter markers follow the sound: a marker where sound is inserted, replaced, or filtered stays at the stretch's start, markers inside a cut move to where it was, and markers inside a replaced or filtered stretch move in proportion.

## Podcast chapters when edits are saved
<!-- id: audio-editor-podcast-chapters; keys: podcast, episode chapters, Start Over, feed episode; src: TextMouth/ViewModels/LibraryViewModel+AudioEditing.swift, TextMouth/Services/AudioEditing/AudioEditPackage.swift, TextMouth/Parsers/PodcastChapters.swift -->

A podcast episode's own chapters are set aside when edits are saved (0.4.3).
Its chapters were timed to the audio as it was downloaded, and an edited file no longer fits them, so they are kept out of sight in the book's package and the episode has none while it holds edits.

- Saving with every edit undone brings the chapters back, since the original audio they were timed to is back.
- Start Over does not bring them back.
  When the editor asks whether to start over with no edits, the chapters set aside are discarded with the old history, since the audio they fit can no longer be reached.
  Edits made after that, and undone, do not restore them.
- The set-aside chapters go with the episode, and stay while the policy for original audio deletes the original (a file of at most 1 MB).
- A book of several files has no podcast chapters to set aside.

## Undo, redo, and saving
<!-- id: audio-editor-undo-redo; keys: edit history, save formats, FLAC, AAC, Apple Lossless, m4b; src: TextMouth/Services/AudioEditing/AudioEditHistoryStore.swift, TextMouth/Services/AudioEditing/AudioEditRenderer.swift, TextMouth/Services/AudioEditing/AudioExportFormat.swift -->

Undo and redo go back through every edit of a file, across launches and Macs, since the edits are kept in the book's package.
Saving writes the edits into the book's file, in its own format where TextMouth can write it: AAC in .m4a or .m4b, MP3, which TextMouth writes itself (below), Apple Lossless, WAVE, AIFF, or uncompressed CAF.
An MP3 cut is saved with no short silence at the cut and without the occasional refusal ("The edited audio couldn't be written.") that earlier versions had.
To remove an old gap from a book saved before, choose Revert to Original, redo the edits, and save.
A FLAC book becomes Apple Lossless, and any other becomes AAC in .m4a.
Its chapters, length, and index are measured afresh.
A book open in a reader can't be saved; close it there first.
A 24-bit Apple Lossless or FLAC book keeps its 24 bits when saved, and so does a WAVE or AIFF export of it.
A book of 64-bit floating point samples, which AVFoundation's writers refuse, can be edited, saved, and exported: its samples are written as 32-bit floats, or as 32-bit integers in WAVE and AIFF.
If AVFoundation still refuses to write the audio, TextMouth goes on, and the editor says why:

- Save says "The edits couldn't be saved." followed by "The edited audio couldn't be written."
- Export says "The audio couldn't be exported." followed by the same sentence.

## The original audio
<!-- id: audio-editor-original-audio; keys: Keep, Don't keep, Keep for days, Storage settings, retention, Audio Info policy; src: TextMouth/Services/AudioEditing/AudioOriginalSweep.swift, TextMouth/Services/AudioEditing/AudioEditingPreferences.swift, TextMouth/Views/Settings/AudioEditingSettingsSection.swift -->

The original audio: unless the policy below keeps none, the first save keeps a copy of the audio the edits started from, and a recording keeps its original take, so every edit can be undone while the original is kept.
Original audio, in the Storage tab's Audio Editing group, decides how long:

- Keep.
- Don't keep, which edits the book's file in place, so undo then stops at the audio as last saved.
- Keep for a number of days (1 to 365, 1 by default) after the last edit, or, for a recording never edited, after it was saved.

A change applies to the originals already kept, too.
A book can also have a policy of its own, set in the editor's Audio Info, which wins.
Originals whose time is up are deleted when TextMouth starts, after a recording or an edit is saved, and when a book's own policy changes, never while the book is open in a reader or being edited, nor while undone edits or edits not yet saved need them, and nothing is downloaded to do it.

## Filters and ffmpeg
<!-- id: audio-editor-filters; keys: highpass, equalizer, loudnorm, Use ffmpeg for filters, Remove Rumble, Audiobook Loudness; src: TextMouth/Services/AudioEditing/AudioFilterProcessor.swift, TextMouth/Services/AudioEditing/AudioFilterRunner.swift, TextMouth/Services/AudioEditing/FFmpeg.swift, TextMouth/Services/AudioEditing/AudioFilterPresets.swift -->

Filters are written as ffmpeg writes them, such as highpass=f=80,equalizer=f=3000:t=q:w=1:g=3.
Without ffmpeg, TextMouth runs volume, highpass, lowpass, equalizer, afade, atempo, loudnorm, silenceremove, acompressor, and areverse itself, as ffmpeg does, though its loudnorm applies one gain, as ffmpeg's two-pass normalization does, where ffmpeg in one pass changes its gain as it goes.
It says which filters it runs when a chain asks for another.
A filter given no value for an option it needs is refused, with the filter and the option named and what to give, as in "The equalizer filter needs its frequency: give a number from 0.0001 to 999999."
A width that makes no usable filter at its frequency is refused too, as in "The equalizer filter's width can't be “5000”: give a narrower width, since this one makes no usable filter at 3000 Hz.".
With ffmpeg installed (Homebrew's, MacPorts', or one on PATH), Use ffmpeg for filters, in the Audio Editing group and on by default, runs every filter ffmpeg has; the switch's help names where TextMouth found ffmpeg, and without one, a line says that it isn't installed.
The converter inside TextMouth has no filters, so the switch never involves it.
The switch covers filters only: importing WMA, Matroska, and the other formats only ffmpeg reads uses the converter inside TextMouth whatever it says (see [What TextMouth reads](reads-audiobooks.md)).
Twelve premade presets, such as Remove Rumble, Audiobook Loudness, and Shorten Long Pauses, can be edited, reordered, removed, added to, and reset, in Filter Presets… (below), and work with or without ffmpeg.

## MP3 without ffmpeg
<!-- id: audio-editor-mp3; keys: LAME, ID3 chapters, gapless, bit rate; src: TextMouth/Services/AudioEditing/AudioEditRenderer+MP3.swift, TextMouth/Services/MP3/MP3Encoder.swift, TextMouth/Services/MP3/MP3Tag.swift -->

MP3 needs no ffmpeg: TextMouth writes it with the LAME encoder built into the app (see [Third-party code](../developer/third-party-code.md)).
It writes a constant bit rate, an MP3 book's own or 64 kilobits a second a channel for speech.
It tags the file with the title and author, and writes the chapter markers as ID3 chapter frames (at most 255, the most one table of contents lists; past that, the 255th runs to the end).
A chapter's title with a Windows line break in it, a carriage return and a line feed, is written whole.
It writes the iTunes gapless numbers too, so TextMouth and Apple's players measure the file exactly as long as its sound.
Export lists it as MP3.
Should that encoder ever fail to start, an installed ffmpeg the switch allows writes MP3 instead.

## Export
<!-- id: audio-editor-export; keys: Shift-Command-E, export to a file, save a copy; src: TextMouth/ViewModels/AudioEditorModel+Saving.swift, TextMouth/Services/AudioEditing/AudioExportFormat.swift -->

Export writes the edits as they stand, saved or not, to a new file in any of those formats, with its chapter markers where the format holds them, leaving the book's file alone.

- The Export sheet has a checkbox, "Also write the markers as Audacity labels", off when the editor opens, and kept as set until its window closes.
  Its hint is "Writes chapter markers and markers beside the audio, in an Audacity label file of the same name."
  - The label file is the audio's name with .txt, beside it, or "name 2.txt" and on when that name is taken, so no file is replaced.
  - A marker with no name is called "Marker" and its number.
  - The export says "Exported “name.wav” and its labels, “name.txt”."
  - When the labels failed, it says "Exported “name.wav”, but its labels couldn't be written." and why.
  - With no marker of either kind, the hint says "No chapter markers or markers, so no label file would be written."
  - The export then says "Exported “name.wav”."
    It adds "It has no markers, so no label file was written."

## Audio editor settings
<!-- id: audio-editor-settings; keys: Storage tab, Audio Editing group, Filter Presets, config.json, audioEditorPreviewsFilters, audioEditorPlaysAfterMoves; src: TextMouth/Views/Settings/AudioEditingSettingsSection.swift, TextMouth/Views/Settings/AudioFilterPresetsView.swift, TextMouth/Services/AudioEditing/AudioEditorPreferences.swift -->

Settings: "Preview filters before applying" and "Play half a second after each move", in the Audio Editing group of Storage settings, are on by default, and config.json keeps them as audioEditorPreviewsFilters and audioEditorPlaysAfterMoves.
Filter Presets…, in the same group, lists the presets, to edit, add, reorder, delete, or reset them, each command a button of the preset's row and, when it can act, one of the row's VoiceOver actions and context menu items.
The presets are saved in the library in use: a preset saved while the library is being moved is saved again in the moved library, even if the list was closed meanwhile, and a list left open through a move writes to the moved library afterwards.

## Tracks and the manifest
<!-- id: audio-editor-tracks; keys: manifest order, renamed track, Ogg to m4a; src: TextMouth/Services/AudioEditing/AudioEditBookRender.swift -->

The audio editor lists a book's tracks in its manifest's order, with its titles.
A track saved under a new name, as an Ogg track saved as .m4a, is renamed in the manifest too, so it keeps its place, title, and group.
