# Audio edits
<!-- id: audio-edits; keys: audio editor, edit history, MP3 encoder, original policy, filter presets, punch-in; src:  -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## The edit history
<!-- id: edit-history; keys: undo history, non-destructive editing, edit list, layout version, audioEdits folder, set-aside chapters, takes, Revert to Original; src: TextMouth/Models/AudioEdit.swift, TextMouth/Models/AudioEditList.swift, TextMouth/Services/AudioEditing/AudioEditHistoryStore.swift, TextMouth/Services/AudioEditing/AudioEditPackage.swift, TextMouth/Services/AudioEditing/AudioEditError.swift, TextMouth/Models/BookOrigin.swift, TextMouth/Services/FileImportService+Packages.swift, TextMouth/Services/SavedFile.swift, TextMouth/Services/TextMouthPaths.swift, TextMouth/Services/Feeds/FeedItemPackage.swift, TextMouth/ViewModels/LibraryViewModel+AudioEditing.swift -->

The edit history (FR04): an edited audiobook's audioEdits/edits.json, and a recording's original take until its first edit.

- Owner: the package. edits.json (AudioEditHistory, in layout AudioEditHistory.currentVersion, 1) is a record, pretty-printed with sorted keys and ISO 8601 dates.
  It holds the book's own original policy (policyOverride; none follows the global setting), and one AudioEditList for each audio file edited, named by its path inside the package.
  A list is the file's version control.
  It holds its edits in order (AudioEditEntry: an identity, when it was made, and an AudioEdit, whose times are seconds on the audio as the edits before it left it).
  It holds a cursor (how many are applied; the rest were undone and can be redone until a new edit discards them), renderedCursor (how many the book's file holds as last rendered), and when it was last rendered.
  It holds its original (AudioOriginal: its file, and when the audio was last edited from it), or when the policy deleted it.
  It holds, too, the editor's markers (AudioEditMarker: an identity, a time on the audio as the applied edits leave it, and a name), written only when there are any, so a list without them is written as before.
  An earlier TextMouth reads such a list and drops the markers when it next writes it.
  While an original is kept the edits apply to it, so every edit can be undone; without one they apply to the file as last rendered, and undo stops there (undoLimit).
  The folder also holds:
  - originals, the originals of imported books' files, each at its file's own path, and
  - takes, the takes of punch-ins and of audio inserted (AudioEdit.insert(at:with:), stored as "insert": a paste, or a recording made with nothing selected), as Apple Lossless when that loses nothing (AudioEditPackage).
- Who may write it: only AudioEditHistoryStore, whose update reads, changes, and writes a history under one lock for the whole process, so an editing session, a render, and the original policy's sweep never write over one another, and then deletes the takes no edit can use any more.
  A recording's take stays recorded in its origin record, origin.json, as the Record window saved it, until the history holds more than it.
  The write that adds an edit, a marker, or a policy of the book's own, writes edits.json and strikes the take from origin.json, so exactly one record describes it.
  A history that can't be used is preserved beside itself (SavedFile.preserveUnusable, AUDIO_EDITS_FILE), and one of a later layout is left alone; neither is written over, and an editing session starts over only when asked to (startingOver).
- A podcast episode's chapters beside a book of one file (podcastChapters.json) are set aside when edits are saved (0.4.3):
  - LibraryViewModel.setAsidePodcastChapters(of:in:) moves the file to the hidden .podcastChapters.unedited.json (TextMouthPaths.podcastChaptersSetAsideFileName) when the save applies at least one edit, and the content analysis of that save does not read the chapters.
    A PODCAST_CHAPTERS_SET_ASIDE line says so, and a PODCAST_CHAPTERS_LEFT line says a move that failed, the save going on.
  - restorePodcastChapters(of:in:) moves it back when a save applies no edit, so the original audio the chapters were timed to is back, and the analysis reads them (PODCAST_CHAPTERS_RESTORED).
    Chapters already in their place, as a new download's, are left, and the set-aside file with them.
  - AudioEditHistoryStore.update discards it (AudioEditPackage.discardSetAsidePodcastChapters, PODCAST_CHAPTERS_DISCARDED) when a history starts over after an unusable one, since the audio an undo of every edit reaches is no longer the one the chapters fit.
    The discard runs after the new history is written, so a failed write tries again.
  - It goes with its episode (it is not in staysWithoutTheFile, so FeedItemPackage.removeWhatTheFileMade and whole-package removal take it), and is never taken for content (FileImportService.isPackageContentName).
    It stays when the policy deletes the original (at most 1 MB).
    A history file deleted outside TextMouth reads as empty and not unusable, so no discard happens (a follow-up).
- How others observe it: AudioEditHistoryStore.read never downloads: a history, or a recording's origin record, only in the cloud is reported as such (Lookup.inCloud, AudioEditError.historyInCloud): an edit or a save is refused until it is on this Mac, and a sweep leaves the book for later.
  A path a history records is used only while it stays inside the package (AudioEditPackage.url(of:in:)), however edits.json was edited.
  FileImportService.isPackageContentName passes over the folder by its one name.

## Rendering the edited audio
<!-- id: rendering-edited-audio; keys: save edits, export edited audio, preview, AVMutableComposition, filter engine, bookmarks follow edits, ffmpeg, scratch folder; src: TextMouth/Models/AudioEditTimeline.swift, TextMouth/Models/AudioFilterChain.swift, TextMouth/Models/AudioBuiltInFilter.swift, TextMouth/Models/AudioEditWording.swift, TextMouth/Models/AudioEditPlaces.swift, TextMouth/Services/AudioEditing/AudioEditComposition.swift, TextMouth/Services/AudioEditing/AudioEditRenderer.swift, TextMouth/Services/AudioEditing/AudioEditRenderer+MP3.swift, TextMouth/Services/AudioEditing/AudioEditBookRender.swift, TextMouth/Services/AudioEditing/AudioFilterProcessor.swift, TextMouth/Services/AudioEditing/AudioFilterRunner.swift, TextMouth/Services/AudioEditing/FFmpeg.swift, TextMouth/Services/AudioEditing/AudioExportFormat.swift, TextMouth/ViewModels/AudioEditSession.swift, TextMouth/ViewModels/AudioEditorTimeMap.swift, TextMouth/ViewModels/LibraryViewModel+AudioEditing.swift, TextMouth/Services/BookContentAnalysisService.swift, TextMouth/Services/LibraryPersistenceService.swift -->

From the list to sound: previewing, saving, and exporting edited audio.

- Owner: values made from the list, off the main thread.
  AudioEditTimeline is the edited audio laid out in whole sample frames at the rate of the audio the edits start from, so every edit lands on the same sample however often it is applied; it applies the edits that only rearrange sound itself, and its chapter markers follow the sound.
  A filter's or a gain change's stretch goes through an AudioEditProcessing.
  AudioFilterProcessor renders the stretch to float PCM, runs its chain on the engine chosen when the session or the save began (AudioFilterEngine: TextMouth's own filters through AudioFilterRunner, or the installed ffmpeg as a child process).
  It keeps the result in this Mac's Audio Edits folder (AudioEditScratch) under a digest of everything that decides it, so undo, redo, and a later render read it back.
  Whatever writes there makes the book's folder again first (AudioEditScratch.make), since a save removes it while an editor edits on, and macOS may empty the Caches folder.
  A stretch of the edited audio whose file macOS removed is made again when next needed (AudioEditSession.restorePurgedStretches, before an edit, a preview, a stretch copied or cut, and an export).
  Callers at once share one rebuild, one made for a list that changed meanwhile is not taken, and of two renders of one stretch at once, the result the first moved into place stands (AudioFilterProcessor).
  AudioEditComposition makes a timeline an AVMutableComposition, which a preview plays and copies of stored samples go through, never a render: AVFoundation decodes an MP3 wrongly through a composition, silencing about 100 ms at a cut and sometimes shifting the sound after it.
  AudioEditRenderer decodes a render's edits stretch by stretch (readStretches): one AVAssetReader for each stretch over its own time range, with a run-up of 0.5 s and a run-past of 0.25 s (readRunUp, readRunPast), and its buffers retimed.
  Every source is opened and checked before the file it would replace is removed.
  A stretch that decodes short by up to 20 ms (fillableShortfall) is filled with silence, and a longer shortfall fails the render; each stretch hands over exactly its own frames, with a pool and a yield per stretch.
  It writes with AVAssetWriter in one pass, no further than the edits' length, so a compressed take that ends them adds none of its last packet's padding, and MP3 with the LAME built in.
  The decoded floats are handed to MP3Encoder buffer by buffer (AudioEditRenderer.renderMP3, along an MP3Route), or, should LAME fail to start, rendered to float PCM and encoded by an installed ffmpeg (FFmpeg.encodeMP3).
  The AVAssetWriter path and LAME's share readStretches.
- Who may write it: AudioEditSession, on the main actor, is the edit session the editor window's model works through (the editor window, below).
  It changes the list only through the history store, off the main thread, checking each edit against the audio first (AudioEditError.invalidEdit, a sentence saying why), and holds a use of its book while it is open.
  LibraryViewModel.saveAudioEdits refuses a book open in a reader and runs AudioEditBookRender as storage work (StorageWork.audioEditing) under a use of the book.
  Under the history's lock, an imported file never rendered into has its original kept first, a clone, unless the policy keeps none.
  The edits are rendered into a hidden file beside the book's file, in its own format where TextMouth can write it (AudioRenderFormat.inPlace), and read back and checked for length.
  It is put in the file's place in one step, or under a new name, the old file then deleted only once the book's record names the new one (LibraryPersistenceService.writePendingBookInfoNow).
  Under the lock again, the list notes what the file holds.
  The book's audio is then analyzed afresh (BookContentAnalysisService.analyzeAudio), and its row, record, and index saved.
  Its bookmarks and saved reading position follow the sound (AudioEditPlaces.follow).
  The session keeps the route from the file as last saved to the audio edited now (AudioEditSession.savedFileRoute, an AudioEditorTimeMap.Route: each edit, undo, and redo a crossing with the audio's lengths around it, an undo of the newest crossing taking it back).
  It works the route out from the list as it opens, and knows none when the file holds edits the list no longer has.
  The save (saveAudioEdits) reads the chapters as the reader lays them over the file before the render (BookContentAnalysisService.load), and moves each place through that layout, along the route, and through the new one.
  A place is a time on the whole file in a book of one file, or on its track in a book of several, where only the saved track's places move.
  A moved position is dated at the save, so it wins over older copies of itself; without a route, nothing moves, and an AUDIO_EDITS_SAVED line says why.
  Everything here works without a window.
- How others observe it: the book's row and record take its new file, fingerprint, length, chapters, and index, with an AUDIO_EDITS_SAVED line; the reading text kept for it is dropped, and a transcript made of the old audio no longer matches its fingerprints, so it is stale.
  AudioEditSession.export writes the edits as they stand, saved or not, to a new file in an AudioExportFormat, MP3 among them without ffmpeg, leaving the book's file alone.

### The sample depth of a render
<!-- id: render-sample-depth; keys: 64-bit float, bit depth, readableDepth, AVAssetWriterInput, 24-bit, FLAC, Apple Lossless, renderFailed; src: TextMouth/Services/AudioEditing/AudioEditRenderer.swift, TextMouth/Services/AudioEditing/AudioFilterProcessor.swift, TextMouth/Services/AudioEditing/AudioEditError.swift, TextMouth/Services/ObjCException.swift, TextMouth/Services/OwnAudioConverter.swift-->

How a render keeps the depth of the audio it starts from, and what it does with one AVFoundation refuses.

- Owner: AudioRenderSettings (AudioEditRenderer.swift), made from the book's own format by make.
  AVFoundation's readers and writers take integer samples of 8, 16, 24, and 32 bits (acceptedIntegerDepths) and 32-bit floats, and raise an Objective-C exception for any other depth, which ends the app.
  AudioRenderSettings.readableDepth(bits:isFloat:) keeps those, takes an integer depth between two (12 or 20 bits) up to the next, and makes everything else (a 64-bit float, a 64-bit integer, a depth not known) a 32-bit float.
  AudioRenderSettings.pcm(_:_:bits:isFloat:) is the one place a render's PCM settings are made, for each format's own (make) and a filter's float CAF (floatCAF), so no reader or writer is given a depth it refuses.
- WAVE and AIFF: AVAssetWriter writes integers only, so a float book becomes 32-bit integers there, and an integer book keeps its depth, to 32 bits.
  A 64-bit float book edits, previews, saves, and exports in every format.
- Lossless books: Apple Lossless and FLAC report 0 bits a channel, and give the depth of their source in their format flags instead (storedIntegerDepth(of:), 1 for 16 bits to 4 for 32).
  A saved Apple Lossless book keeps its depth, 20 bits written as 24 (OwnAudioConverter.writtenBitDepth(forAppleLossless:)), and a WAVE or AIFF export of one keeps it too.
  The flags of a FLAC file were checked only on a made-up description, not on a real file.
- Copies as stored: a render copies samples as the book stores them (canCopySamples) only when its caller asked for no settings, so a filter's input, a stretch copied or cut, and ffmpeg's MP3 intermediate, which ask for floatCAF, are decoded to 32-bit floats even from a 64-bit float book.
- Raised exceptions: makingWithoutRaising wraps the writer's inputs, stored and decoded, and the reader's output in ObjCException.making, so a raise becomes AudioEditError.renderFailed, named by its summary for the debug log.
  Save's message (AudioEditorWording.saveFailed) and Export's (exportFailed) both end with the reason, AudioEditError.renderFailed's sentence "The edited audio couldn't be written" and its full stop.
  A failed Save removes its staged file.
- Apple Lossless is written at 16, 24, or 32 bits: ImportAudioConverter.appleLosslessBitDepth(forBitsPerSample:) writes 17 to 24 bits at 24, since AVAssetReader cannot read the 20-bit file afconvert and AVFoundation's writer make.
  OwnAudioConverter.writtenBitDepth(forAppleLossless:) stays for the editor, which meets books imported at 20 bits before.
- A 64-bit integer CAF, which AVFoundation cannot decode, is refused on import by its form, not as damaged (see Probing an audio file's duration in [Imports: audio](imports-audio.md)).

## MP3 files TextMouth writes
<!-- id: mp3-files-textmouth-writes; keys: LAME, ID3 tag, chapter frames, gapless, iTunSMPB, libmp3lame, bit rate, MP3 encoder; src: TextMouth/Services/MP3/MP3Encoder.swift, TextMouth/Services/MP3/MP3Tag.swift, TextMouth/Services/AudioEditing/AudioEditRenderer+MP3.swift, TextMouth/Parsers/AudioBookParser.swift, TextMouth/Parsers/AudioMediaProbe.swift, Vendor/lame, project.yml -->

An MP3 file TextMouth writes (FR04): an MP3 book's save, or an export.

- Owner: MP3Encoder, one for each file: LAME 3.100's encoder at a constant bit rate (MP3EncoderSettings: an MP3 book's own, or 64 kbit/s a channel for speech, LAME taking the nearest the sample rate allows), quality 2, mono or joint stereo.
  The file starts with MP3Tag's ID3v2.3 tag, which holds the title (TIT2) and author (TPE1) in UTF-16.
  It holds one top-level table of contents (CTOC) listing a chapter frame (CHAP) for each chapter marker, at most 255 (maximumChapters), since AVFoundation reads only a top-level table and a table counts its entries in one byte, the 255th then running to the end.
  It holds the iTunes gapless comment, iTunSMPB (MP3GaplessInfo), which AVFoundation honours, written at a fixed width first and again in place once finish() knows the numbers.
  LAME's own Info tag goes in the frame LAME leaves for it, when that frame has room.
  An encoder that doesn't finish removes its file.
- Who may write it: AudioEditRenderer.renderMP3, for an MP3 book's save and for an export.
- How others observe it: as any MP3, through AudioEditBase, AudioBookParser, and AudioMediaProbe.
- The library: LAME 3.100 in Vendor/lame, built by project.yml as the static library target LAME (libmp3lame.a), optimized for size, its warnings hidden, DEBUG undefined, and linked without -ObjC (requiresObjCLinking: false).
  Swift imports it as the LAME module (Vendor/lame/include/module.modulemap), in MP3Encoder alone.
  README.md's Third-party code is its notice.

## Markers in WAVE, AIFF, and CAF files, and label files
<!-- id: wave-aiff-caf-markers-labels; keys: AudioMarkerList, holdsChapterMarkers, keepsBookChapters, AUDIO_MARKERS_NOT_WRITTEN, chapterMarkersLeftOut, Audacity labels, FMT11, FMT06; src: TextMouth/Services/AudioMarkerList.swift, TextMouth/Services/AudioEditing/AudioEditRenderer.swift, TextMouth/ViewModels/AudioEditorModel+Saving.swift, TextMouth/Views/AudioEditor/AudioEditorWording.swift, TextMouth/Parsers/AudacityLabels.swift -->

- AudioEditRenderer.render writes a render's chapters into an MPEG-4 file's chapter track and an MP3's chapter frames as it writes.
  Once the audio is written it writes them into a WAVE, AIFF, or CAF file's marker list (writeMarkers, AudioMarkerList.write, FMT11).
  Each is at its start, named by its title, the sound before the first included, so the chapters read back exactly (FileChapterReaders).
  Outcome.chapterMarkersLeftOut is true only when there were markers and the write failed; the file stays whole without them and AUDIO_MARKERS_NOT_WRITTEN says why, naming no folder.
- AudioRenderFormat.holdsChapterMarkers is true for every format the editor writes (isMPEG4, MP3, isPCM), so AudioEditorWording.chaptersLeftOut never shows now.
  It stays for a format that would not hold them.
  keepsBookChapters is false for CAF, whose markers a save writes but metadataAsset never reads back as chapters (FileChapterReaders reads WAVE and AIFF), so a save of a CAF book in place warns with chaptersNotReadBack.
  Core Audio reports an AIFF's marker list 8 bytes short (120 of 128), so AudioMarkerList counts it by the bytes allocated.
- Export Audio's checkbox (AudioEditorModel.exportsLabels, off until checked, for the window's life) also writes AudioEditorModel.labelEntries as an Audacity label file (AudacityLabels.text(of:)) beside the audio.
  The entries are each chapter marker and each marker, in time order.
  The file is the audio's stem with .txt, or "stem 2.txt" and on, written so that no file is replaced.
  The export's sentence says the labels written, that they failed with why, or that there was no marker, so none was written (AudioEditorWording.exported(file:labels:), exported(file:labelsFailed:), exportedWithoutLabels(file:)).

## The originals and the original policy
<!-- id: originals-original-policy; keys: keep original, delete original, original-take.caf, sweep, Storage settings, recording take, undo limit, AudioOriginalPolicy; src: TextMouth/Models/AudioOriginalPolicy.swift, TextMouth/Models/AudioEditList.swift, TextMouth/Services/AudioEditing/AudioOriginalSweep.swift, TextMouth/Services/AudioEditing/AudioEditActivity.swift, TextMouth/Services/AudioEditing/AudioEditingPreferences.swift, TextMouth/ViewModels/AudioEditSession.swift, TextMouth/ViewModels/SettingsViewModel.swift, TextMouth/ViewModels/LibraryViewModel+AudioEditing.swift, TextMouth/ViewModels/LibraryViewModel+Recording.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/Views/Settings/AudioEditingSettingsSection.swift, TextMouth/Views/Settings/StorageSettingsView.swift -->

The originals, and the original policy.

- Owner: AudioOriginalPolicy: keep, delete (edits then change the book's audio in place), or delete a number of days after the last edit.
  It is held globally in the preferences store under the names it had when only recordings kept an original, recordingOriginalPolicy and recordingOriginalDays (SettingsPolicy's rules: delete after 1 day until changed, from 1 to 365 days), and mirrored in config.json.
  A book's own policy, in its edit history or, for a recording never edited, beside its take in origin.json, wins.
  An original is a recording's take, original-take.caf, which a recording saved under delete never keeps, or the copy of an imported file kept as its edits are first rendered.
- Who may write it: Storage settings' Audio Editing group (AudioEditingSettingsSection, whose AudioEditingSettingsModel follows the store through PreferenceObserver) and config.json, for the global policy.
  LibraryViewModel.setAudioOriginalPolicy(_:forBook:), for a book's own, which the editor's Audio Info calls (AudioEditSession.setPolicyOverride(_:)).
  Only AudioOriginalSweep deletes an original, at launch (startLibrary), after each recording or edit is saved, and after a book's own policy changes (sweepAudioOriginalsInBackground), off the main thread as storage work.
  It deletes only when the policy says its time is up, the book's file holds exactly the applied edits (AudioEditList.canForgetOriginal), and AudioEditActivity says the book is neither open in a reader nor being edited or rendered.
  Its open-in-reader mark is set at once as a reader registers or unregisters, and `openBookIDs` follows a turn later ([why](windows.md#the-registry-of-open-readers-and-when-it-publishes)).
  It asks under the history's lock, which a render takes only once its use has begun, so a render never loses the original it reads.
- How others observe it: the list notes when its original was deleted, and undo stops at the audio as last rendered.
  A sweep never downloads: a package whose history is only in the cloud waits for a later sweep, on this Mac or another, deleting an original reads none of it, and a history it can't read is left alone.
  It writes AUDIO_ORIGINALS_SWEPT, and AUDIO_ORIGINAL_REMOVAL_FAILED for an original the next sweep tries again.

## The filter presets
<!-- id: filter-presets; keys: audio-filters.json, Apply Filter, Filter Presets, premade presets, ffmpeg chain, AudioFilterPreset, reset to defaults; src: TextMouth/Services/AudioEditing/AudioFilterPresets.swift, TextMouth/Views/AudioEditor/AudioEditorFilterSheet.swift, TextMouth/Views/Settings/AudioFilterPresetsView.swift -->

The filter presets.

- Owner: AudioFilterPresetLibrary, on the main actor: the presets the editor offers (AudioFilterPreset: an identity, a name, and a chain in ffmpeg's syntax), kept in audio-filters.json in the data directory (TextMouthPaths.audioFiltersFile), beside substitutions.json.
  The twelve premade presets (AudioFilterPresetLibrary.standard), each with an identity made from its name, stand in, unsaved, while there is no file.
- Who may write it: add, update, remove, move, and resetToDefaults, each saving the file whole.
  It is read and written as substitutions.json is: never read or written over while only in the cloud, the premade presets standing in and a save waiting.
  A file that can't be used is preserved beside itself.
  One that arrives from another Mac while the premade presets stand in takes their place, the change made meanwhile refused (AudioFilterPresetError.fileArrived).
  The editor's Apply Filter (AudioEditorFilterSheet) and Storage settings' Filter Presets… (AudioFilterPresetsView) each make one, reading the file as they open.
  The file is looked up at each read and write (TextMouthPaths.audioFiltersFile), unless a test chose one, so a Filter Presets pane left open through a data-directory move writes the library then in use.
  A save made while a move copies the library is provisional ([Holding storage work](data-directory.md)).
  It registers the bytes it wrote with StorageBoundary.isProvisionalSave, and the move writes them again in the moved library, even if the pane has closed, so a first save, which has no file for the copy to take, is not lost.
- How others observe it: the editor's filter chains; AUDIO_FILTERS_FILE lines tell of each wait and preserved copy.

## The editor window
<!-- id: editor-window; keys: Audio Editor, punch-in, waveform, cut copy paste, markers, Edit Audio, keyboard shortcuts, undo manager; src: TextMouth/ViewModels/AudioEditorModel.swift, TextMouth/ViewModels/AudioEditorModel+Commands.swift, TextMouth/ViewModels/AudioEditorModel+Editing.swift, TextMouth/ViewModels/AudioEditorModel+Filters.swift, TextMouth/ViewModels/AudioEditorModel+Listening.swift, TextMouth/ViewModels/AudioEditorModel+PunchIn.swift, TextMouth/ViewModels/AudioEditorModel+Saving.swift, TextMouth/ViewModels/AudioEditorModel+Selecting.swift, TextMouth/ViewModels/AudioEditorPrompt.swift, TextMouth/ViewModels/AudioEditorTimeMap.swift, TextMouth/ViewModels/AudioEditSession.swift, TextMouth/ViewModels/LibraryViewModel+AudioEditing.swift, TextMouth/Models/AudioEditList.swift, TextMouth/Models/LibraryAudioCommand.swift, TextMouth/Models/TimeEntry.swift, TextMouth/Models/KeyboardShortcut.swift, TextMouth/Models/ShortcutEdits.swift, TextMouth/Services/AudioEditing/AudioEditorPlayer.swift, TextMouth/Services/AudioEditing/AudioEditorLevels.swift, TextMouth/Services/AudioEditing/AudioEditorPreferences.swift, TextMouth/Services/AudioEditing/AudioEditCaches.swift, TextMouth/Services/AudioEditing/AudioFilterPresets.swift, TextMouth/Services/KeyboardShortcutManager.swift, TextMouth/Services/ShortcutPressDispatcher.swift, TextMouth/Services/RecordingService.swift, TextMouth/Services/VoiceOverAnnouncer.swift, TextMouth/Views/AudioEditor/AudioEditorView.swift, TextMouth/Views/AudioEditor/AudioEditorCommandViews.swift, TextMouth/Views/AudioEditor/AudioEditorCommands.swift, TextMouth/Views/AudioEditor/AudioEditorFileSheets.swift, TextMouth/Views/AudioEditor/AudioEditorFilterSheet.swift, TextMouth/Views/AudioEditor/AudioEditorMarkersSheet.swift, TextMouth/Views/AudioEditor/AudioEditorWaveform.swift, TextMouth/Views/AudioEditor/AudioEditorWording.swift, TextMouth/Views/Settings/AudioFilterPresetsView.swift, TextMouth/Views/Settings/AudioEditingSettingsSection.swift, TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorEditMenu.swift, TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorLauncher.swift, TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorWindowController.swift, TextMouth/Platform/iOS/Views/AudioEditor/AudioEditorLauncher+iOS.swift, TextMouth/Platform/iOS/Views/AudioEditor/AudioEditorWindowController+iOS.swift, TextMouth/Platform/macOS/App/AppDelegate.swift, TextMouthProductionTests/AudioEditorWindowTests.swift -->

The editor window (FR04): one audio file of a book, open for editing.

- Owner: AudioEditorModel, on the main actor, one for each window, over one AudioEditSession, which it changes only through the session.
  It holds the cursor and the selection.
  It holds the markers (AudioEditMarker), which follow the sound through edits and undo (AudioEditorTimeMap), come back from the file's edit list as the window opens.
  They are kept there after every change (AudioEditSession.keepMarkers: written off the main thread one at a time, a newer request taking the place of one waiting, and a save waiting first for those asked before it), Revert to Original deleting them.
  It holds the audio a Cut or Copy keeps for Paste (AudioEditorClip: up to ten minutes, rendered losslessly by AudioEditSession.renderStretch(_:to:) into the window's own folder in this Mac's Audio Editor Clips, which AudioEditCaches.newClipFolder() names).
  It is kept in the package as a take once pasted.
  It holds the punch-in under way (AudioEditorPunchIn).
  It holds the levels and pauses (AudioEditorLevels: a level for every hundredth of a second, and a pause wherever they stay at least 0.4 seconds below 15 dB above the quietest tenth, kept between -60 and -30 dBFS).
  They are measured from the preview after each edit on a thread of its own (AudioEditorLevels.Reading, bridged to its task with a cancellation handler that only raises a flag, since a reader may not be cancelled while it is read).
  One measurement at a time, a newer one waiting for the older, cancelled one to stop.
  It plays through AudioEditorPlayback (AVAudioEditorPlayer, an AVPlayer over the session's composition, every seek exact, touching neither Now Playing nor the media keys).
  It records punch-ins through RecordingService with the Record window's capture backend and microphone choice (AudioEditorRecorder), after a count-in.
  Its sentences are AudioEditorWording's.
  Its views are AudioEditorView; its sheets, one at a time (AudioEditorSheet: a question with one field, the markers and pauses, Apply Filter, the progress of a save or an export, Export, and Audio Info); and AudioEditorWaveform, hidden from accessibility.
- Who may write it: the window's commands, pressed as a button, a shortcut, or a VoiceOver action, which all reach AudioEditorModel.perform(_:); while a punch-in records, only Stop, Play / Pause, Punch In, Clear Selection, and Where Am I? act.
  AudioEditorLauncher opens the window, from the Book menu (editBookAudio) or a row's LibraryAudioCommand.editAudio(_:).
  It refuses a book that isn't an audiobook in a package of its own, or whose manifest plays sections (AudioEditorTracks.sections).
  It asks which track of a book of several.
  It closes the book's reader (closeReaderForAudioEditing), waiting up to three seconds for it.
  It opens the session, asking first when a history that can't be read would be started over.
  AudioEditorWindowController.shared keeps one window for each book, brings an open one forward, and asks Save, Discard, or Cancel before a window closes over edits not saved.
  It keeps the window open while work is under way or a punch-in records, and opens the book's reader again once the window closes, when the launcher closed it.
  As TextMouth quits, the app delegate asks it after a library move (holdQuit).
  An editor still working or recording holds the quit, its window brought forward to say so.
  Otherwise each editor with edits not saved is asked about in turn, by its book's title, in an alert over every window, each answer carried out as closing carries it out (carryOut), the markers still waiting are written, and one request to quit again goes through.
  Audio Info gives the book an original policy of its own (AudioEditSession.setPolicyOverride(_:), through LibraryViewModel.setAudioOriginalPolicy(_:forBook:)).
  On iOS, AudioEditorLauncher and AudioEditorWindowController are stand-ins of the same names (TextMouth/Platform/iOS/Views/AudioEditor/): no book can be edited, and no quit is held.
### Keys, the Edit menu, and the sheets
<!-- id: editor-keys-menu-sheets; keys: ShortcutScope, KeyClaims, undo manager, Edit menu, Apply Filter sheet, markers sheet, rename row; src: TextMouth/Models/KeyboardShortcut.swift, TextMouth/Models/ShortcutEdits.swift, TextMouth/Services/KeyboardShortcutManager.swift, TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorEditMenu.swift, TextMouth/ViewModels/AudioEditorModel+Filters.swift, TextMouth/Views/AudioEditor/AudioEditorFilterSheet.swift, TextMouth/Views/AudioEditor/AudioEditorMarkersSheet.swift, TextMouth/Views/AudioEditor/AudioEditorWording.swift, TextMouthProductionTests/AudioEditorWindowTests.swift -->

- Keys: the Audio Editor group of ShortcutAction works in a scope of its own (ShortcutScope.audioEditor, its defaultScope), so its keys may be the reader's.
  KeyboardShortcutManager matches a press only against the actions whose scopes reach the key window's kind (windowKind(ofKeyWindow:)): the editor's alone in an editor window, none in a sheet over one, and elsewhere those of every scope that reaches that kind of window.
  A key moved in Settings or config.json leaves only the actions whose scopes overlap its own (KeyClaims).
  In an editor window a press with Shift matches only a binding with Shift, since none of the editor's actions takes Shift along (ShortcutAction.actionsTakingShiftAlong), so a Shift-R the user gave Release Media Controls never reaches the editor's R, Punch In.
  An editor key posts audioEditorShortcut with the action and the window it was pressed in, and only that window's model acts (WindowCommandRouting).
- The Edit menu: AppKit's own, so a text field anywhere keeps its Undo Typing, its Cut, and the rest.
  An editor window's delegate, the editors' controller, gives the window its editor's stand-in undo manager (windowWillReturnUndoManager, AudioEditorUndoManager), whose titles and availability are the editor's Undo and Redo buttons' and which NSWindow's own undo: and redo: validate and call.
  The delegate also answers cut:, copy:, paste:, and selectAll: (NSMenuItemValidation) only while the editor's window is itself the key window, never in a sheet over it.
  Each sends the editor's command as its shortcut does (AudioEditorEditMenu.send, posting audioEditorShortcut), taken through WindowCommandRouting.
- What it added to the session:
  - AudioEditSession.insert(takeAt:at:using:), for a paste and for a recording made with nothing selected;
  - makePreview(applying:), which Apply Filter's Preview plays;
  - renderStretch(_:to:), for a clip; and
  - saveFormat(), the format a save writes, for Audio Info and a save's first sentence.
- The sheets: AudioEditorModel+Filters.swift's applyWouldPreview(_:on:) says whether Apply previews first (the setting on, and the preset not yet previewed on that target since Apply Filter opened, per previewedFilter, which openFilters clears).
  The same file's chooseApply reads it, and applyHint(for:on:) turns it into Apply's hint (AudioEditorWording.applyPreviewsFirstHint or applyHint), which AudioEditorFilterSheet gives the button.
  AudioEditorFilterSheet takes its AudioFilterPresetLibrary (the saved presets, unless a test gives others) and asks VoiceOver's start for Cancel when it lists no preset.
  In AudioEditorMarkersSheet.swift the marker, chapter marker, and pause rows share row(_:subject:commands:) over RowCommand (a title, whether it is destructive, and an action).
  A row is one container labelled with the row's words, the drawn text hidden from VoiceOver, a button per command labelled rowButton(title, subject), the subjects being markerSubject, chapterSubject, and pauseSubject, and the commands as the row's actions by title.
  AudioEditorRenameRow is a row's rename state (the field, where the keyboard goes as the row opens, Save Name as the default button, and Cancel as the cancel button).
  The sheet's closeShortcut(whileRenaming:) gives Close the cancel key only while no name is typed.
  Tests: AudioEditorWindowTests hosts the prompt sheets and the rename row, puts the keyboard in the field (windowWithKeyboardInField), and sends keys through window.sendEvent (press), which includes AppKit's key-equivalent pass, proving that one Return runs a command once.
  Its testARowsWordsAreReadOnce skips without an assistive app.
- How others observe it: the window shows and speaks its state: Position, Status, and Last message, which repeats the last announcement made through VoiceOverAnnouncer for a braille display.
  AUDIO_EDITOR lines tell of a book the editor couldn't open, of a save or an export it couldn't finish, and of markers it couldn't keep, naming an error by its kind, never by a path.
  The editor's two settings are AudioEditorPreferences ([Preferences](preferences.md), Editor, library, feed, and transcription preferences).
  Its tests play through FakeAudioEditorPlayer, which only notes what it was asked, and record through FakeCaptureBackend, so they make no sound and need no microphone.

## Manifest books in the editor
<!-- id: manifest-books-editor; keys: rename track, manifest.json, multi-track book, track plan; src: TextMouth/Parsers/AudioManifest.swift, TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorLauncher.swift, TextMouth/Services/BookManifestEditing.swift -->

A manifest book (FR17, #2457): AudioEditorTracks.of arranges a book's tracks with AudioTrackPlan, and renameTrack finds the manifest through AudioManifestLocation and renames the track in tracks, order, chapters, and segments, through BookManifestFile.change.
