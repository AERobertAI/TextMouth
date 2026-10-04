# Recording audio and a basic, fully accessible audio editor in TextMouth

Research for the October 3 request, from the code on main (a0bad26), the macOS 26 SDK headers, Apple's documentation, and a throwaway command-line prototype run on this Mac (not committed). The prototype never recorded from a microphone, asked for no permission, and played nothing aloud: every input was generated. Bracketed numbers cite the sources at the end.

The request: "the option to create audio from a recording, and to have a basic audio editor (some filters, a way to cut and audio to another point or out altogether, and similar level but fully accessible...)"

## Summary

- **Feasible with Apple's frameworks alone** (AVFoundation, AudioToolbox, Core Audio). No package is added, so the app-size limit is not at risk.
- **Recording:** an AVCaptureSession with a microphone the user chooses, writing 16-bit PCM into a CAF file in this Mac's own folder. This Mac's default input is the AirPods microphone at 24 kHz, and AVAudioRecorder can record only from the default. A CAF file of PCM was the only format still readable after the prototype cut a recording off as a crash would.
- **Becoming a book:** on Save, the take is encoded as AAC with its markers as chapters and imported through the same staging as New from Text, so it plays, keeps bookmarks, and syncs like any audiobook.
- **Permission:** one Info.plist key, plus the Audio Input entitlement. Because TextMouth is signed ad hoc, macOS will ask for the microphone again after every rebuild [5][6], unless the app gets a stable signing identity (open question 3).
- **Editing:** an edit list of time ranges, undoable, previewed through AVMutableComposition and saved through AVAssetReader and AVAssetWriter. In the prototype every cut, move, and inserted silence landed on the exact sample.
- **Finding things without a waveform:**
  - Typed times, In and Out at the playhead while listening, markers, and "from here to the playhead".
  - A pause search that found all 31 pauses in ten minutes of audio, each edge within 9 ms, at about 6,500 times real time.
  - Every result announced once and shown on the braille display.
- **Filters:** AVAudioEngine's offline rendering runs Apple's effects on a file: a speech cleanup chain at about 600 to 880 times real time, and Apple's voice isolation, a noise remover since macOS 13, at 33 to 70 times.
- **Chapters:** AAC in M4A or M4B with chapters is written in one pass and reads back through the app's own parser. Long files need one writer setting, missing from today's test fixture.
- **Recommendation:** a separate editor window with its own model and player, reusing the app's announcer, focus, shortcut, menu, and staging helpers, in six phases after a short spike.

## 1. What TextMouth does today

- **Privacy and signing:**
  - TextMouth.entitlements sets `com.apple.security.app-sandbox` to false.
  - project.yml signs ad hoc (`CODE_SIGN_IDENTITY: "-"`) without the Hardened Runtime. The installed app shows it: `flags=0x2(adhoc)`, no Team ID, and a designated requirement that is its cdhash.
  - Info.plist has `NSAppleEventsUsageDescription` but no `NSMicrophoneUsageDescription`. The deployment target is macOS 14.0.
- **Audio formats:** `BookFormat.audio` accepts mp3, m4a, m4b, wav, aiff, aif, flac, alac, and aac, but not caf. `AudioBookParser.audioFiles(in:)` uses the same list, so a CAF file can be neither imported nor found in an audio folder.
- **The import path:**
  - `FileImportService.importFileWithReport` copies a file into a package built under a hidden name (`ImportStaging`), reads it as the reader will (`publishReadableBook`, `BookContentAnalysisService.load`), writes and rereads bookInfo.json (`writeVerifiedRecord`), and publishes with one rename.
  - The record keeps the file's MD5 (`md5Hash`). Duplicate detection compares it, and a package import checks it (`inspectContent`).
  - New from Text builds its package the same way through `importText`, queued by `LibraryViewModel.createBookFromText`. A recording can follow that pattern exactly.
  - An audio file is listed under its tags' title and artist, or else under its file name and "Unknown" (`ImportedFileMetadata.read`).
- **Multi-file books:** a ZIP of tracks becomes an `audio` folder with an optional manifest.json (`AudioManifest`: title, author, chapter titles, order, and segments). Segments (`AudioSegment`, lists of clips of files) are how DAISY audiobooks play sections that are time ranges.
- **Chapter markers:**
  - `AudioPlaybackService.extractChapters(from:)` reads `availableChapterLocales` and `loadChapterMetadataGroups(bestMatchingPreferredLanguages:)`.
  - `AudioBookParser.parse(url:)` makes one heading per marker. Its text is a placeholder of ten characters a second (`ReaderViewModel.audioCharsPerSecond`).
  - The test fixture `AudioTestFixtures.writeChapteredAAC` already writes chapters as a disabled text track named as the audio's chapter list, and `AudioMediaValidationTests` reads them back, for a three-second file.
- **Playback:**
  - Each reader's `AudioPlaybackService` plays files with an `AVQueuePlayer`, stretched in the time domain, at speeds from 0.25 to 4 (`AudioSpeed`). Its seeks have zero tolerance.
  - A segmented book's clip ends when a periodic observer, firing every 0.25 seconds, sees its end, so a clip can run up to a quarter of a second long.
- **The cursor:** an audiobook's position, bookmarks, and jumps are a chapter plus a character offset at ten characters a second (`ReadingPosition`, `Bookmark`, `ReaderViewModel+Jump`), so 0.1-second resolution. `JumpToTimePanel` takes hours, minutes, and whole seconds in three plain text fields; its comments explain that plain fields kept VoiceOver reading them as edit text.
- **No recording, writing, or export code:**
  - Outside the tests, nothing uses an input node, a capture session, a recorder, an asset writer, or an export session.
  - Audio metadata edits stay in the library and are never written to the file (`MetadataEditorView`).
  - The app has no save panel or file exporter.
- **Speech engine:** each text book's reader makes its own `AVAudioEngine` in `AudioEngineService` when speech first needs one, for speech only.
- **Accessibility plumbing to reuse:**
  - `VoiceOverAnnouncer`, whose announcements the tests record.
  - `InitialVoiceOverFocusModifier` and `StandardVoiceOverFocus` for a new window's first focus.
  - `TimeFormatting.spoken` and `CountWording`.
  - `KeyboardShortcutManager` with rebindable `ShortcutAction`s. The reader's defaults: Space and K play, J and L skip, W is Where Am I, F and B change the skip unit.
  - `MenuVisibilityManager`, whose comments list the steps for adding a window type with its own menus.
  - `SoundEffectService`'s system sounds.
- **This Mac's own folders:** `MachineLocalPaths` (Working Copies, Import Staging, and Archive Extraction in Application Support) never sync, and follow `TextMouthRuntime` into the test sandbox.

## 2. What is on this Mac

- **System:** MacBook Air with an Apple M3 (Mac15,12), 8 GB of memory, macOS 26.3.1.
- **Inputs,** read from Core Audio without opening any:
  - MacBook Air Microphone: built in, 48 kHz, one channel.
  - AirPods Pro: Bluetooth, 24 kHz, one channel. This is the default input and also the default output.
  - The iPhone's microphone through Continuity: 48 kHz.
  - Virtual devices: Background Music and Microsoft Teams Audio.
- **What the output plays through:** the MacBook Air Speakers identify themselves (a built-in transport and the data source `ispk`, internal speakers). Bluetooth devices name no data source and report only their transport. So TextMouth can tell when sound goes to the built-in speakers, but not a Bluetooth speaker from earbuds.
- **Disk:** about 3.6 GB free (99% used). One hour of 16-bit mono PCM takes about 345 MB.

## 3. Recording

### Three ways to capture

- **A. AVAudioRecorder.**
  - For: pause, resume, metering, and any Core Audio format, in little code [7].
  - Against: it records "from the system's active input device" [7], which here is the AirPods at 24 kHz. Its `channelAssignments` is unavailable on macOS [9], so there is no microphone choice.
  - Against: no samples reach the app, so there are no exact clip counts and no live pause search. Apple points to AVAudioEngine for processing [7].
- **B. AVAudioEngine's input node with a tap.**
  - For: every buffer, and voice processing (echo cancellation) [9][12].
  - Against: "on macOS, AVAudioInputNode and AVAudioOutputNode communicate with the system's default input and output devices" [9]. Another device needs a Core Audio property on the node's audio unit (`kAudioOutputUnitProperty_CurrentDevice`). Apple documents that property for the HAL unit [10]; developers report it works for the engine [11]; Apple doesn't document it there.
  - Against: the engine stops itself when a device's channel count or sample rate changes [9].
  - Against: once an engine's input node has run with permission, the microphone indicator shows whenever that engine runs [9], so the reader's speech engine must never touch it.
  - Against: voice processing ducks "other (i.e. non-voice) audio" [9][12], which would quiet VoiceOver, and works only with devices, never offline [9].
- **C. AVCaptureSession with a chosen AVCaptureDevice.**
  - For: an official choice of device. `AVCaptureDevice.DiscoverySession` lists microphones with the `.microphone` type on macOS 14 [8].
  - Two outputs fit it. `AVCaptureAudioDataOutput` delivers linear PCM in a chosen format through its macOS-only `audioSettings` [9], and the app writes the buffers itself. `AVCaptureAudioFileOutput` (macOS only) writes "any audio file type supported by CoreAudio", pauses and resumes, and meters through `AVCaptureAudioChannel`'s `averagePowerLevel` and `peakHoldLevel` [8][9].
  - Against: `startRunning()` blocks until the session starts or fails [9], so it runs on a serial queue.
  - `AVCaptureDeviceWasDisconnectedNotification` and `AVCaptureSessionRuntimeErrorNotification` report a lost device or a failure [9].

**Recommendation: C, with the data output.** It is the only option with an official microphone choice, and writing the buffers ourselves gives exact levels, clip counts, a check for silent input, and the crash-safe file below. AVCaptureAudioFileOutput is the fallback if the spike finds the data output troublesome; its file after a crash is unmeasured.

### The file while recording (measured)

- **What survives a crash:** the prototype wrote ten seconds in each format, then ended its process with `_exit`, so nothing finished the file:
  - CAF with 16-bit PCM: all 10.00 seconds read back, through AVAudioFile and AVURLAsset.
  - CAF with AAC: 0 seconds. The bytes are there; probably the packet table, which compressed audio needs, is written only when the file is finished.
  - WAV with 16-bit PCM: 0 seconds. The bytes are there too, but the header's size was never written.
  - M4A with AAC, and M4A with Apple Lossless: the files can't be opened.
- **Why CAF:** Apple's CAF overview explains it. AIFF and WAV must update the header's size at the end, "which can result in an unusable file if recording is interrupted", while CAF lets an app append audio "in a manner that allows it to determine the amount of data even if the size field in the header has not been finalized" [13]. CAF also has no 4 GB limit [13]. AVAssetWriter's movie fragments are the other documented way [9]; I didn't test them.
- **Sizes per hour,** mono at 48 kHz, measured on one minute of each:
  - 16-bit PCM: 345 MB.
  - AAC at 64 kbit/s: 33 MB. At 96 kbit/s: 48 MB. HE-AAC at 32 kbit/s: 17 MB.
  - Apple Lossless: 236 MB on the noise-like test signal. Real speech should compress better; that is unmeasured.
  - MP3 can't be written: Core Audio has no MP3 encoder (AVAudioFile refused it with error `fmt?`).
- **So:** a take is recorded as CAF with 16-bit PCM at the device's own rate, and becomes AAC only when it is saved as a book.

### Permission and signing

- **What the app must declare:**
  - `NSMicrophoneUsageDescription` is required [1]. Without it, "the app exits" at the first access to a microphone [4].
  - Apple's capture article also asks for the Audio Input entitlement in macOS, "Otherwise, the system terminates your app" [2]. That entitlement belongs to the Hardened Runtime [3], which TextMouth doesn't use. Adding `com.apple.security.device.audio-input` now costs nothing, and notarizing would need the Hardened Runtime anyway [3].
  - A sandboxed build would also need `com.apple.security.device.microphone` [3].
- **When to ask:** at the first Record, after a spoken explanation, through `AVCaptureDevice.requestAccess(for: .audio)` [2] (or `AVAudioApplication.requestRecordPermission()`, macOS 14 [4]). After a denial, the window says how to allow it, with a button that opens Privacy & Security.
- **A denial records silence, not an error:** "Unless a user grants your app permission to record audio, it captures only silence (zeroed out audio samples)" [4]. The recorder checks the status before it starts, and warns when the first seconds are exactly zero.
- **Ad hoc signing forgets the permission:**
  - macOS stores each app's designated requirement with its permissions. Ad hoc signed code "has a DR but it's tied to that specific version of the code", so after a change "macOS repeats that prompt" [5].
  - Apple's developer support puts it plainly: "Every time you rebuild, the program get a different signature and TCC thinks it's a different program" [6].
  - With `make install` after each change, you'd be asked after every update, and System Settings would collect stale TextMouth entries.
  - A stable identity fixes this [6]. The preferred one is an Apple Development identity, which Xcode creates for a free account's Personal Team, and for which the system sets up the designated requirement correctly [6][22]. A self-signed certificate from Keychain Access also works, but its designated requirement has to be written by hand [6]. Neither was tried here.

### Levels without recording VoiceOver

- **The problem:** through the speakers, the built-in microphone records VoiceOver's speech and TextMouth's own announcements and sounds. TextMouth can't silence VoiceOver, but it can stay silent itself and check the route. When the output is the built-in speakers, Record says so first: "VoiceOver's speech may be recorded through the speakers. Use headphones, or continue."
- **A level check first:** Test Level listens for five seconds without recording, then speaks a summary from the measured peak and background levels, such as "Loudest −9 dB: good. Background −58 dB: quiet." The thresholds are tuned in the spike.
- **While recording:**
  - The meter is a text element whose value, such as "Level −18 dB, good", the braille display shows when the VoiceOver cursor is on it. It posts no announcements.
  - On request: the elapsed time and the space left.
  - With headphones only, an optional short sound when the level clips, at most once every few seconds.
  - M drops a marker, for example at a sentence to redo, to find later in the editor.
- **Cues are never in the take:**
  - Record speaks "Recording in 3 seconds" and plays three short sounds, and capture starts after the last one.
  - Stop ends capture before anything is announced. Pause and Resume work the same way.
- **Pause:** buffers stop going into the file while the session keeps running for the meter, so the file has no gap. The microphone indicator stays on.
- **Other sound:** Record pauses any reader that is playing.
- **A lost microphone:** if the device goes (AirPods put away), the take stops, keeps what it recorded, and VoiceOver hears why.
- **Disk:** free space is checked before Record and every minute. A recording near the end of the space stops itself and keeps the take.

### Where a recording lands

- **The take:** `Recordings/<id>.caf` in `MachineLocalPaths.root`, beside Working Copies. It never syncs, it's on the startup volume, and in tests it's inside the sandbox.
- **After a crash:** the next launch offers what's left: "A recording from 23:40, 12 minutes long, wasn't saved. Save, Edit, or Delete."
- **Save as Book:**
  - Asks for a title, an author, and a library folder (the window's current one).
  - Encodes AAC (64 kbit/s mono by default), with the markers as chapters if you want them, in one pass (section 6).
  - Imports the file through the same staging as New from Text (a new `FileImportService.importRecording`, queued like `createBookFromText`), so the book is listed, plays, keeps bookmarks, and syncs like any audiobook.
  - Deletes the take once the book is published, unless the original is kept (open question 4).
  - The new book then opens in a reader or in the editor.

## 4. Editing without a waveform

### The edit list

- **A value:** `AudioEditList`, an ordered list of segments. Each segment is a source (a take, a book's audio file, a rendered file, or silence) and a range of sample frames.
- **Edits are pure functions on it:** delete a range, copy, paste at a time, move (a delete then a paste), trim to a range, insert silence, and apply a filter to a range (which renders the range and swaps in the rendered file). Markers and chapter marks are times on the same timeline.
- **A time map:** each edit also maps old times to new ones; a time inside a deleted range goes to the cut point. Markers, chapter marks, the playhead, and the book's bookmarks and saved position all follow the audio through it. It is a pure function, so tests can cover it fully.
- **Undo and redo:** the window's `UndoManager` keeps the previous list for each edit [19]. Its action names appear in the Edit menu and VoiceOver reads them, as in "Undo Delete 2.5 Seconds" [19].
- **Preview:** each change rebuilds an `AVMutableComposition` from the list and plays it in an `AVPlayer` [14]. A composition refers to the source files without copying them.
- **Saving:** the list is rendered. Either AVAssetReader decodes the composition and AVAssetWriter encodes AAC with chapters, or a passthrough export copies PCM.

### What the prototype showed

- **Edits are exact:**
  - The test file was a 30-second ramp in which every sample names its source frame.
  - Edits: a cut (5 to 7 s), a move (10 to 12 s, placed at 2 s), and one second of inserted silence, giving 29.000 seconds.
  - AVAssetReader returned all 1,392,000 samples from the expected frames, and the silence as zeros, through both a track output and an audio mix output.
- **Passthrough export:**
  - Cuts and moves of PCM exported to CAF and WAV exactly.
  - Any composition holding an empty range from `insertEmptyTimeRange` [14] was refused (AVFoundation error −11838).
  - Silence inserted as media, a one-second silent file, exported exactly. So silence is always a generated silent file, never an empty range.
- **AAC:**
  - The Apple M4A preset kept the edited length exactly (29.000 s) and the audio in place (median shift 0.1 sample).
  - A passthrough export of edited AAC to M4A is refused, even for cuts on packet boundaries.
  - To a QuickTime movie it works, through an edit list that AVAssetReader honors but AVAudioFile ignores (28.12 seconds instead of 28.00, the audio 0.1 second late).
  - So saving an edited AAC book means encoding it again, and each save loses a little quality. That is one reason to keep the original take.
- **Pause search:**
  - Test audio: ten minutes of generated speech-like sound over a background at −67 dBFS.
  - Method: 10-millisecond windows below −45 dBFS, for at least a second.
  - Result: all 31 true pauses, each edge within 9 ms, and nothing else, in 0.09 seconds (about 6,500 times real time) with 4 MB of memory. Thresholds from −55 to −40 dBFS gave the same result.
  - It also found both pauses in speech made with `say`.

### Finding and selecting a range

- **The playhead** is a time, accurate to the sample, spoken in hours, minutes, seconds, and tenths.
- **Ways to set a selection:**
  - **In and Out** at the playhead while listening: I and O, as in Final Cut Pro [21].
  - **Typed times:** Go to Time, Set Start, and Set End use the three plain fields of `JumpToTimePanel`, with seconds that take decimals (an extension of `JumpInputValidator`, which accepts whole seconds).
  - **Markers,** dropped while listening or recording (M, as in Final Cut Pro [21]), listed by number, name, and time, each with Go, Rename, Delete, and Select to Playhead.
  - **From here to the playhead:** select from the last stop, a marker, or the selection's other end to the playhead.
  - **Pauses:**
    - A list of the pauses longer than a chosen length. The threshold is set from the measured background, such as 15 dB above it.
    - Next Pause and Previous Pause, and Select Pause.
    - Shorten Pauses Longer Than…, across a whole recording.
    - Trim Silence at the ends.
  - **Nudging:** move the start or end by 10 ms, 100 ms, or 1 second. Each nudge plays the audio up to the edge, or from it, so you hear where it lands.
- **Listening:**
  - Play Selection stops at the selection's end through the item's `forwardPlaybackEndTime` [18], not through a periodic check like the reader's clip chains.
  - Play Edge plays a second either side of the start or the end.
  - Play Across Cut plays two seconds either side of a cut, in the edited result.
  - Fast listening goes up to 8 times, with the time-domain algorithm the reader already uses, which the SDK describes as "Suitable for voice" with a "Variable rate from 1/32 to 32" [9].
  - Skim plays half a second of every five.
- **What VoiceOver and the braille display get:**
  - A command that changes the selection or the audio announces its result once, as in "Selection 1 minute 4.2 seconds to 1 minute 6.7 seconds, 2.5 seconds long" or "Deleted 2.5 seconds. Now 12 minutes 27.5 seconds long."
  - Nothing is announced during playback. W, as in the reader, speaks the position, the length, the selection, and the nearest marker.
  - The window is made of native elements: a heading, a status text, buttons, and lists of markers, pauses, chapters, and edit history, each row with its own actions. VoiceOver's navigation, the rotor, and a braille display work as they do elsewhere in TextMouth.
  - The status text has a short braille form: "1:04.2–1:06.7, 2.5 s".
  - A drawn waveform, if there is one, is for sighted helpers and hidden from VoiceOver.
  - An optional audio graph of loudness over time, which VoiceOver can play and explore [20], gives an overview but is never the only way to find anything.

### Keyboard commands (a proposal)

- Every command is in the menu bar, in a new menu shown only for the editor window (`MenuVisibilityManager`), and is rebindable in Settings, Shortcuts, under a new Audio Editor group. Single letters act only while no text field has focus, as the reader's do.
- **Playing:**
  - Space or K: play or pause.
  - J and L: back and forward by the step. F: cycle the step (0.1, 1, 5, or 30 seconds).
  - Command-Plus and Command-Minus: speed.
- **Selecting:**
  - I and O: set the start and the end at the playhead. Shift-I and Shift-O: go to the start and the end.
  - P: play the selection. Escape: clear it.
  - E: switch which edge a nudge moves. Comma and Period nudge it back and forward, by 100 ms; with Option by 10 ms, with Shift by 1 second.
- **Finding:**
  - M: add a marker.
  - Option-Command-Down and Option-Command-Up: next and previous marker, the reader's heading keys.
  - N and Shift-N: next and previous pause. G: go to a time. W: Where Am I.
- **Editing:**
  - Command-X, Command-C, and Command-V: cut, copy, and paste at the playhead. Delete: delete the selection.
  - Command-Z and Shift-Command-Z: undo and redo. Command-S: save.
- **New Recording…** goes in the File menu after New from Text. Its shortcut is to be chosen: Shift-Command-R is already Restart Sleep Timer.

### Its own window, not the reader

- **Why:**
  - The reader's audiobook model is a character cursor with 0.1-second resolution, and its clip chains overrun ends by up to 0.25 seconds.
  - Its playback carries the sleep timer, Now Playing, statistics, checkpoints, autoplay, and the cloud working copy. An editor needs none of them, and an edit could disturb any of them.
- **The pieces:**
  - An `AudioEditorWindowView` scene: a `WindowGroup` with an ID and `.commandsRemoved()`, as the reader has.
  - An `AudioEditorViewModel` on the main actor, holding the list, the selection, the markers, and undo.
  - An `EditorPlayback` service around AVPlayer, with zero-tolerance seeks.
  - An `AudioRenderer` off the main thread for previews of filters, renders, and saves.
- **Shared, not repeated:** TimeFormatting, CountWording, VoiceOverAnnouncer, InitialVoiceOverFocusModifier, KeyboardShortcutManager, AudioSpeed, SoundEffectService, DiagnosticLog, and the import staging.
- **From the reader:** Edit Audio opens the editor at the reader's position, converting its character offset with `AudioBookParser.time(forCharacterOffset:)`.
- **First focus** goes to the status text, through `InitialVoiceOverFocusModifier`, which already copes with a new window's late accessibility tree and with a window closed meanwhile (PERF33).
- **When it closes,** the editor lets go of everything that grows with the audio, as a closed reader does, since SwiftUI keeps closed windows for the rest of the session.

### Saving back to the library

- **Save** replaces the book's audio file in its package:
  - Render to a staged file, and read it as an import does.
  - Then, in one step, replace the file and publish the new MD5, length, chapters (the content index), the remapped bookmarks, position, and transcript (section 7), and the record.
  - Nothing is published unless the write succeeded, as `saveEPUBMetadata` does for EPUB metadata.
- **Save as New Book** imports the result as a new audiobook and leaves the original.
- **An open book:** a book open in a reader must be closed first, as Remove Download refuses an open book.
- **A cloud library:** the editor reads a working copy (`ReaderWorkingCopy`'s pattern), and a save uploads the new file.
- **First draft:** recordings and single-file audiobooks only.
  - A ZIP of tracks or a DAISY book is a folder of files with sections that cross files; editing one means joining it into one file first (open question 5).
  - An MP3 book saves as M4A, since Core Audio can't encode MP3, so its file name changes too.

## 5. Filters

### Measured offline

All of these ran through AVAudioEngine's offline manual rendering [17], on the ten-minute file (48 kHz, mono), writing 16-bit CAF:

- **Speech cleanup:** an EQ (high-pass at 80 Hz, +3 dB at 3 kHz), Apple's dynamics processor, and Apple's peak limiter. Ten minutes in 0.7 to 1.0 seconds (about 600 to 880 times real time), in 6 MB.
- **Apple's voice isolation** (`kAudioUnitSubType_AUSoundIsolation`, macOS 13 [9]):
  - Speed: 33 times real time on a 10-second file, including loading its model, and 70 times on a minute, in about 20 MB.
  - On synthesized speech, it took the background from −84 dBFS to nothing and kept the voice's loudest moments within 0.7 dB.
  - On noise bursts, which aren't voice, it cut 32 dB. It removes whatever isn't speech, music included.
- **Faster speech:** a quarter faster without changing pitch (AVAudioUnitTimePitch), at 290 times, giving 480 seconds.
- **Reverb:** 254 times, but only in stereo.
  - Connecting it in mono raised an Objective-C exception (`kAudioUnitErr_FormatNotSupported`, −10868) that ended the process, since Swift can't catch one.
  - The fix: ask each unit first through `AUAudioUnitBus.setFormat`, which throws a Swift error instead, and up-mix through a mixer node when a unit refuses mono.
- **The "radio" distortion preset:** 820 times.
- **Normalize to −1 dBFS with half-second fades:** plain Swift over 64K-frame chunks in two passes, at 250 times, in 4 MB. Apple's vDSP would be faster.
- **Memory** stayed between 4 and 20 MB whatever the file's length.

### A first set

- **Level:** gain, normalize, and fade in and out.
- **Clarity:** remove rumble (high-pass), a clearer voice (presence boost), and even out the level (dynamics processor and limiter).
- **Noise:** reduce background noise with voice isolation, using the high-quality model on macOS 15 and later [9].
- **Speed:** change the speed permanently.
- **Presets, not parameters:** each filter offers a few named settings, such as "Reduce Background Noise: Light" and "Strong".
- **Later:** loudness matching (LUFS), click and hum removal, and character presets such as reverb.

### Previewing on the selection

- A second engine, output only and never the speech engine, plays the selection through the same chain in real time.
- Compare switches the chain's bypass at once and announces "Original" or "Processed". Settings change while it plays.
- Apply renders the selection offline into a new file in the edit's folder and swaps it in. Undo puts the original back.

## 6. Export and chapters

- **Into the library:** AAC in M4A or M4B with chapters, written in one pass:
  - AVAssetReader decodes; AVAssetWriter encodes AAC, adds a text track of titles named as the audio track's chapter list [16], and writes the title and author as common metadata.
  - Measured: ten minutes in 2.2 seconds (276 times real time), 5.0 MB at 64 kbit/s, in 20 MB of memory.
  - Read back with the same calls `extractChapters` makes: the three chapters at 0, 200, and 400 seconds with their titles, the title and author, and exactly 600.000 seconds.
- **The chapter track must be laid out ahead of the audio:**
  - With the writer's default interleaving, the text input refused the second title (200 seconds in) because the audio hadn't started. Appending titles as the audio reached them stalled the audio at 4 to 6 seconds.
  - Setting the text input's `mediaDataLocation` to `beforeMainMediaDataNotInterleaved` fixed it. The SDK recommends that setting for "chapter name tracks" [9].
  - The test fixture's writer works only because its files last three seconds. The production writer needs the setting, and a test on a ten-minute file.
- **To a file outside the library:** Export Audio… with a save panel.
  - Formats: M4A or M4B (AAC with chapters), WAV, AIFF, CAF, or Apple Lossless in M4A.
  - No MP3: Core Audio has no encoder for it.
  - The Apple M4A preset adds gapless-playback data [15].
  - Progress: on macOS 15 and later from `states(updateInterval:)` [15]; on macOS 14, by polling.
  - The async `export(to:as:isolation:)` is back-deployed to macOS 10.15 in this SDK [15], so it needs no macOS 15 check (the test fixture still has one).
- **Tags:** an exported file carries the book's title, author, album, genre, and year from the library, the metadata the editor already edits.
- **CAF in the library:** add caf to `BookFormat.audio` (and to Info.plist's document types) only if lossless originals should be importable. Otherwise CAF stays internal.

## 7. Where transcription attaches

TRANSCRIPTION-RESEARCH-2026-10-03.md, now on main, recommends a transcript.json layer in the audiobook's package: each word timed in milliseconds, keyed to each audio file's path, size, and modification time, made on macOS 26 by SpeechAnalyzer, which needs no permission prompt. A recording and the editor attach to it in three places:

- **After Save as Book:** a recording is an audiobook like any other, so it is transcribed the same way. That document's first question already asks whether recordings come first.
- **In the editor:** words become another way to find a place. Find a word and select its time range, or take sentence ends as candidate cut points.
- **After an edit:** saving changes the audio file, so its fingerprint no longer matches the transcript. Rather than transcribing again, the save carries the transcript through the edit's time map (words in deleted ranges dropped, the rest moved) and records the new fingerprint.

## 8. Risks

1. **Permission after every rebuild:** ad hoc signing gives a new identity each build, so macOS asks again each time [5][6].
2. **Silence instead of an error** when permission is denied [4]: the recorder must check the status and detect all-zero input.
3. **VoiceOver in the recording:** through the speakers, the built-in microphone records VoiceOver. AVAudioEngine's voice processing, which cancels echo, also ducks other audio, VoiceOver included [9][12].
4. **Crashes:** only takes in CAF with PCM survive (measured). Recovery at launch is part of Phase 1.
5. **Disk:** about 3.6 GB free here, and an hour of PCM is about 345 MB.
6. **Memory:** an hour of mono Float32 at 48 kHz is 691 MB. Never read a file whole; every pass in the prototype streamed in 20 MB or less.
7. **Devices:**
   - The default input here is the AirPods at 24 kHz.
   - A device can leave mid-take.
   - With option B, a change of sample rate stops the engine [9].
8. **Uncatchable exceptions:** AVAudioEngine.connect raises Objective-C exceptions for formats a unit refuses (measured with the reverb), so check every format first.
9. **A stalled writer:** AVAssetWriter stalls on long files without `mediaDataLocation` set on the chapter track.
10. **Quality loss:** each save of an edited AAC book encodes it again.
11. **VoiceOver focus in a new window:**
    - The editor is a third window type.
    - VoiceOverFocus waits 0.8 to 1.2 seconds and retries, and its delayed search once crashed after a window closed (PERF33).
    - `MenuVisibilityManager` must learn the new window type before its Library fallback, or, as its comments warn, the editor is taken for a Library window and shows the Library menu instead of its own.
12. **Swift 6:**
    - Capture callbacks arrive on the capture queue, and levels must cross to the main actor.
    - Each new `@unchecked Sendable` needs the comment naming its lock or queue, and changes the counts `UncheckedConcurrencyPolicyTests` pins.
    - New log tags join the list `LogContentPolicyTests` pins.
13. **Long renders:** they need progress, Cancel, and announcements at each quarter, as a data-directory move has.

## 9. Testing strategy

- **Unit tests (pure and fast):**
  - Edit list operations and their time maps, with the edges: an empty selection, a selection at the very end, and pasting into the range just cut.
  - Remapping bookmarks, the position, markers, chapters, and a transcript's words.
  - Wording: the spoken and braille forms of times, selections, levels, and edit names, built once for both, as `CountWording` is.
  - Level math (dBFS, clipping, silence) and the pause search, on generated buffers.
  - The free-space policy and the naming of recovered takes.
  - The new shortcut defaults, which must not collide with the reader's.
- **Hosted tests with generated audio:**
  - Ground rules: use `AudioTestFixtures`, extended with a ramp writer and a tones-and-pauses writer. Never touch the user's library, and never play sound: check with AVAssetReader, or a muted AVPlayer.
  - Composition exactness for each edit (the prototype's ramp check).
  - Passthrough export, silence as media, and the refused empty range.
  - AAC with chapters on a ten-minute file (the stall), read back through `AudioBookParser.parse`.
  - Each filter: that it accepts the format, and the length of its output.
  - Importing a recording: the book appears, analyzes, and has its chapters.
  - Saving an edited book: the MD5, the duration, and the remapped bookmarks. A save refused while the book is open.
  - Announcements, through `VoiceOverAnnouncer`'s recorder; the focus target and labels, through the accessibility test helpers.
- **Recording without a microphone:**
  - The recorder takes its buffers from an `AudioCaptureSource` protocol, and tests feed it generated buffers: all zeros (a denial), a device lost mid-take, and a full disk.
  - The real capture session is tested by hand, or by an opt-in hosted test behind an environment variable, as the real-drive cloud tests are, since it brings up the permission prompt.
- **Crash safety:** a helper process ends with `_exit` mid-write, as the prototype did, never with `abort`, so no crash report appears.
- **By hand, with VoiceOver and braille:**
  - Record with the built-in microphone while listening on AirPods, and again with the speakers.
  - Select, cut, undo, and save.
  - Every command from the menus and from the keys.

## 10. Phased plan

- **Phase 0, spike (2 to 3 days):**
  - The signing identity, and the permission prompt across a rebuild.
  - Capture from the built-in microphone while the AirPods play VoiceOver, and a device lost mid-take.
  - Real takes cut off by a crash; AVCaptureAudioFileOutput against the data output.
  - Voice isolation on your own voice.
  - AVPlayer over a composition of 100 edits, listening for gaps.
  - How VoiceOver and the braille display present a level value that changes.
- **Phase 1, record and save as a book (1 to 1.5 weeks):**
  - The Info.plist key, the entitlement, and the permission flow.
  - A New Recording window: a microphone picker, Test Level, Record, Pause, Resume, Stop, markers, the time, and the space left.
  - CAF takes, and their recovery after a crash.
  - Save as Book: AAC with the markers as chapters, through staging. Tests.
- **Phase 2, the editor, with trim and delete (1.5 to 2 weeks):**
  - The window type and its menu, the edit list, and preview.
  - The playhead, the selection, markers, pauses, and announcements.
  - Undo, Save, Save as New Book, and remapped bookmarks. Tests.
- **Phase 3, move, copy, paste, and silence (1 week).**
- **Phase 4, filters with preview and Compare (1 to 1.5 weeks).**
- **Phase 5, chapters and Export Audio… (1 week).**
- **Phase 6, optional:** the audio graph, re-recording a selection, joining multi-file books to edit them, transcript-assisted editing, and loudness matching.

## Open questions for you

1. What will you record: your own voice (notes, narration), or also sound from other apps? Other apps' sound needs a different API and permission, not researched here.
2. Which microphone: the MacBook's own, a USB microphone, the iPhone, or AirPods? Should TextMouth remember its own choice, separate from the system's input?
3. May TextMouth be signed with a stable identity (a free Apple Development certificate made in Xcode, or a self-signed certificate) so that macOS remembers the microphone permission? Or is answering the prompt after each update acceptable?
4. Keep the original take (lossless, about 345 MB an hour) beside the edited book, so any edit can be redone without loss? Or keep only the edited audiobook (about 33 MB an hour)?
5. Should editing apply to any single-file audiobook you imported (replacing its file, with an MP3 becoming M4A), only to recordings, or always save as a new book? Should a multi-file book be joined into one file to edit it?
6. While recording, do you want braille only, speech on request, or sounds through headphones? When the sound goes to the speakers, should Record refuse, warn, or say nothing?
7. Which filters first: background noise, evening out the level, normalize, speed, or something else?
8. In the editor, single-letter keys (I, O, M, J, K, L), as in the reader and in video editors, or Command combinations only?
9. Are M4A or M4B and WAV enough for export, or is MP3 needed? MP3 would mean bundling an encoder and a larger app.
10. Do you want a visual waveform for sighted helpers, and the audio graph for yourself?

## What I could not verify

- Anything that needs the microphone:
  - Capture with a chosen device.
  - The permission prompt, and its return after a rebuild.
  - AVCaptureAudioFileOutput's file after a crash.
  - Latency, and a device lost mid-take.
- Whether voice processing removes VoiceOver's speech from the microphone, and how AirPods sound while their microphone is in use.
- Choosing AVAudioEngine's input device through `kAudioOutputUnitProperty_CurrentDevice` [11].
- Voice isolation on real recorded speech: only synthesized speech and noise were tested.
- Whether AVPlayer plays a composition of many edits without audible gaps, and how precisely `forwardPlaybackEndTime` stops it: the exactness test decoded the audio and didn't play it.
- Lossless sizes on real speech.
- How VoiceOver speaks, and the braille display shows, a level value that changes several times a second.
- Signing with a free Apple Development certificate or a self-signed one.

## Sources

1. NSMicrophoneUsageDescription: https://developer.apple.com/documentation/bundleresources/information-property-list/nsmicrophoneusagedescription
2. Requesting authorization to capture and save media: https://developer.apple.com/documentation/avfoundation/requesting-authorization-to-capture-and-save-media
3. Audio Input Entitlement, Hardened Runtime, and the sandbox's microphone entitlement: https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input , https://developer.apple.com/documentation/security/hardened-runtime , https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.microphone
4. AVAudioApplication.requestRecordPermission(completionHandler:): https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)
5. TN3127, Inside Code Signing: Requirements: https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
6. Apple Developer Forums, DTS answers on TCC, ad hoc signing, and signing identities: https://developer.apple.com/forums/thread/678816 , https://developer.apple.com/forums/thread/730043 , https://developer.apple.com/forums/thread/712555
7. AVAudioRecorder: https://developer.apple.com/documentation/avfaudio/avaudiorecorder
8. AVCaptureAudioFileOutput and AVCaptureDevice.DeviceType.microphone: https://developer.apple.com/documentation/avfoundation/avcaptureaudiofileoutput , https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/microphone
9. macOS 26 SDK headers: AVFAudio (`AVAudioEngine.h`, `AVAudioIONode.h`, `AVAudioRecorder.h`, `AVAudioApplication.h`), AVFoundation (`AVCaptureFileOutput.h`, `AVCaptureAudioDataOutput.h`, `AVCaptureSession.h`, `AVCaptureDevice.h`, `AVAssetWriter.h`, `AVAssetWriterInput.h`, `AVAudioProcessingSettings.h`), and AudioToolbox (`AUComponent.h`, `AudioUnitParameters.h`).
10. TN2091, Device input using the HAL Output Audio Unit: https://developer.apple.com/library/archive/technotes/tn2091/_index.html
11. Apple Developer Forums, selecting the audio device for AVAudioEngine (developers' answers, not Apple's): https://developer.apple.com/forums/thread/71008
12. WWDC23, What's new in voice processing: https://developer.apple.com/videos/play/wwdc2023/10235/
13. Apple Core Audio Format Specification, overview and Audio Data chunk: https://developer.apple.com/library/archive/documentation/MusicAudio/Reference/CAFSpec/CAF_overview/CAF_overview.html , https://developer.apple.com/library/archive/documentation/MusicAudio/Reference/CAFSpec/CAF_spec/CAF_spec.html
14. AVMutableComposition and its time-range methods: https://developer.apple.com/documentation/avfoundation/avmutablecomposition , https://developer.apple.com/documentation/avfoundation/avmutablecomposition/removetimerange(_:) , https://developer.apple.com/documentation/avfoundation/avmutablecomposition/insertemptytimerange(_:) , https://developer.apple.com/documentation/avfoundation/avmutablecomposition/inserttimerange(_:of:at:)
15. AVAssetExportSession, AVAssetExportPresetAppleM4A, export(to:as:isolation:), and states(updateInterval:): https://developer.apple.com/documentation/avfoundation/avassetexportsession , https://developer.apple.com/documentation/avfoundation/avassetexportpresetapplem4a , https://developer.apple.com/documentation/avfoundation/avassetexportsession/export(to:as:isolation:) , https://developer.apple.com/documentation/avfoundation/avassetexportsession/states(updateinterval:)
16. AVAssetTrack.AssociationType.chapterList: https://developer.apple.com/documentation/avfoundation/avassettrack/associationtype/chapterlist
17. Performing offline audio processing: https://developer.apple.com/documentation/avfaudio/performing-offline-audio-processing
18. AVPlayerItem.forwardPlaybackEndTime: https://developer.apple.com/documentation/avfoundation/avplayeritem/forwardplaybackendtime
19. UndoManager: https://developer.apple.com/documentation/foundation/undomanager
20. Representing chart data as an audio graph, and accessibilityChartDescriptor(_:): https://developer.apple.com/documentation/accessibility/representing-chart-data-as-an-audio-graph , https://developer.apple.com/documentation/swiftui/view/accessibilitychartdescriptor(_:)
21. Apple Support, Keyboard shortcuts in Final Cut Pro for Mac: https://support.apple.com/guide/final-cut-pro/keyboard-shortcuts-ver90ba5929/mac
22. Technical Q&A QA1915, on the free Personal Team ("build apps for your personal use on devices owned by you"): https://developer.apple.com/library/archive/qa/qa1915/_index.html
