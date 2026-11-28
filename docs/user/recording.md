# Recording from a microphone
<!-- id: new-recording-window; keys: audio recorder, voice memo, mic, dictation, capture; src: TextMouth/Views/Recording/RecordingWindowView.swift, TextMouth/Views/Recording/RecordingWording.swift, TextMouth/ViewModels/RecordingWindowModel.swift, TextMouth/Platform/macOS/Views/Recording/RecordingWindowController.swift -->

Part of [TextMouth's documentation](../../README.md).

File menu, New Recording… (Option-Command-N), also in the Library menu, opens the New Recording window, which records from a microphone into a new audiobook in your library.
One such window is open at a time, and the command brings it forward.
VoiceOver starts on its Microphone pop-up, Tab reaches every control, and each control's label, value, and hint say in speech and braille what the screen shows.

## Choosing what to record
<!-- id: new-recording-choosing; keys: input device, mic, source, title, folder; src: TextMouth/Services/RecordingInputDevices.swift, TextMouth/Services/RecordingPreferences.swift, TextMouth/Views/Recording/RecordingWording.swift -->

### The microphone list
<!-- id: new-recording-microphone-list; keys: input device, USB, AirPods, aggregate device, virtual device; src: TextMouth/Services/RecordingInputDevices.swift, TextMouth/Views/Recording/RecordingWording.swift, TextMouth/ViewModels/RecordingWindowModel.swift -->

Microphone lists the microphones connected to this Mac by name: its own, AirPods or other headphones, or an external one.
Two of the same name are numbered, as in "USB Microphone (2)".
Virtual and aggregate devices, which carry other apps' sound, aren't listed, so TextMouth can't record other apps.
The list follows microphones as they connect and disconnect, even while recording, though the choice can't change while a recording is under way.

### The remembered microphone
<!-- id: new-recording-remembered-microphone; keys: RecordingInputChoice, system input, punch-in, disconnected, reconnected; src: TextMouth/Services/RecordingPreferences.swift, TextMouth/Services/RecordingInputDevices.swift, TextMouth/Views/Recording/RecordingWording.swift, TextMouth/ViewModels/RecordingWindowModel.swift -->

TextMouth remembers its own choice of microphone, which the audio editor's punch-ins use too, and leaves the input macOS uses for everything else alone.
When the remembered microphone isn't connected, recordings use the system's input, and the window says so as it opens, as in "The microphone TextMouth used last isn't connected, so recordings use MacBook Pro Microphone.".
While nothing is recording, the window says when the microphone in use disconnects, and which one recordings use now.
When one connects that recordings now use, the remembered one coming back or the first connected at all, as in "AirPods Pro was connected, so recordings use it."
And when others connect, as in "USB Microphone was connected; choose it in the Microphone pop-up to record from it."

### Title and folder
<!-- id: new-recording-title-folder; keys: default title, timestamp, Save in, destination folder; src: TextMouth/Views/Recording/RecordingWording.swift, TextMouth/ViewModels/RecordingWindowModel.swift -->

Title starts as "Recording" followed by the date and time, as in "Recording YYYY-MM-DD HH:MM", the year, month, day, hour, and minute.
Save in chooses the library folder, the top of the library, Library, by default.

## Recording
<!-- id: new-recording-record-controls; keys: record button, start recording, microphone permission; src: TextMouth/ViewModels/RecordingWindowModel.swift, TextMouth/Services/RecordingService.swift, TextMouth/Views/Recording/RecordingWording.swift -->

### Record, Pause, and Stop
<!-- id: new-recording-record-pause-stop; keys: Command-R, Command-P, Command-Period, Privacy & Security, microphone access, shortcuts; src: TextMouth/Views/Recording/RecordingWording.swift, TextMouth/ViewModels/RecordingWindowModel.swift, TextMouth/Services/RecordingService.swift -->

Record (Command-R), Pause or Resume (Command-P), and Stop (Command-Period), unless you give them other keys in the Shortcuts tab of Settings, under New Recording.
Each button's hint names its key in force, in words, as in "Starts recording from AirPods Pro.
Shortcut: Command + R.", and names none while the button has no key.
The first recording asks macOS's permission to use the microphone, once.
After a no, the window says where to change it, System Settings, Privacy & Security, Microphone, offers Open Privacy Settings, and records nothing.

### What VoiceOver says as recording starts
<!-- id: new-recording-voiceover-speech; keys: announcement, speakers, feedback, Recording from, Paused, Resuming; src: TextMouth/Views/Recording/RecordingWording.swift, TextMouth/ViewModels/RecordingWindowModel.swift -->

Record says "Recording from" and the microphone's name, and recording starts a second later; Pause says "Paused.", and Resume says "Resuming." a second before recording goes on.
Through speakers, VoiceOver's speech can be recorded too.

### Books playing in a reader
<!-- id: new-recording-pauses-readers; keys: playback paused, echo, audio feedback, Paused the book that was playing; src: TextMouth/Views/Recording/RecordingWording.swift, TextMouth/ViewModels/RecordingWindowModel.swift -->

Record and Resume first pause every book playing in a reader, so the microphone doesn't pick it up, and say so first, as in "Paused the book that was playing.
Recording from AirPods Pro."; resuming the books is yours to do.

### Elapsed time and level
<!-- id: new-recording-elapsed-level; keys: level meter, decibels, peak, average, loudness, clipping; src: TextMouth/Views/Recording/RecordingWording.swift, TextMouth/ViewModels/RecordingWindowModel.swift, TextMouth/Views/Recording/RecordingWindowView.swift -->

Elapsed is the time recorded, pauses left out, which VoiceOver reads as "1 minute, 4 seconds".
Level is the microphone's peak and average in decibels and how loud that is: silent, quiet (below minus 36 decibels), good, loud (from minus 6 decibels), or too loud (above minus 1 decibel); VoiceOver reads it as "minus 12 decibels, good".
Both change once a second and are read when you move to them, never spoken on their own.
A drawn meter beside the level, for sighted helpers, is hidden from VoiceOver.

### Announcing the level
<!-- id: new-recording-announce-level; keys: RecordingLevelAnnouncements, level announcements, interval, stepper, config.json; src: TextMouth/Services/RecordingPreferences.swift, TextMouth/Views/Recording/RecordingWording.swift, TextMouth/ViewModels/RecordingWindowModel.swift -->

Announce level every 10 seconds, off by default, has VoiceOver speak the level while recording, as in "Level minus 12 decibels, good", and the stepper after it sets how often, from 5 to 60 seconds in steps of 5.
TextMouth remembers both, and config.json keeps them too.

### A recording with no sound
<!-- id: new-recording-no-sound; keys: muted microphone, silence, warning, no signal; src: TextMouth/Views/Recording/RecordingWording.swift, TextMouth/ViewModels/RecordingWindowModel.swift -->

When a recording has held no sound at all for five seconds, as a muted microphone gives, the window says once, "No sound is reaching TextMouth from" the microphone's name, "Check that the microphone is on and not muted."

## Saving
<!-- id: new-recording-saving; keys: save recording, M4A, audiobook, Stop; src: TextMouth/Services/RecordingEncoder.swift, TextMouth/Services/FileImportService+Recording.swift, TextMouth/ViewModels/RecordingWindowModel.swift -->

### What Stop saves
<!-- id: new-recording-what-stop-saves; keys: M4A, AAC, mono, 64 kbps, Open in Reader, author Unknown; src: TextMouth/Services/RecordingEncoder.swift, TextMouth/Services/FileImportService+Recording.swift, TextMouth/Views/Recording/RecordingWording.swift, TextMouth/ViewModels/RecordingWindowModel.swift -->

Stop saves without asking: an M4A audiobook (AAC, one channel, at most 64 kilobits a second, tagged with its title, its author Unknown) in the chosen folder.
VoiceOver says "Saved Recording as" and the title, after "Saving the recording…" when saving takes more than a second, and Open in Reader opens the book.
It plays, keeps its place and bookmarks, and syncs like any other audiobook.

### A recording that stops on its own
<!-- id: new-recording-stops-on-its-own; keys: microphone disconnected, low disk space, 512 megabytes, device error; src: TextMouth/Services/RecordingCaptureBackend.swift, TextMouth/ViewModels/RecordingWindowModel.swift, TextMouth/Views/Recording/RecordingWording.swift -->

When recording stops on its own, because the microphone was disconnected, the disk has less than 512 megabytes free, or the microphone reported a problem, the window says why and saves what was recorded.

### A save that fails
<!-- id: new-recording-save-fails; keys: Save Again, Discard Recording, encoding failure, kept take; src: TextMouth/Services/RecordingEncoder.swift, TextMouth/ViewModels/RecordingWindowModel.swift, TextMouth/Views/Recording/RecordingWording.swift -->

A save that fails keeps the recording, with Save Again and Discard Recording.

### Closing the window
<!-- id: new-recording-closing-window; keys: close window, unsaved recording, Stop and Save, Discard, Cancel; src: TextMouth/Platform/macOS/Views/Recording/RecordingWindowController.swift, TextMouth/Views/Recording/RecordingWording.swift, TextMouth/ViewModels/RecordingWindowModel.swift -->

Closing the window while recording asks "Stop and save the recording?", with Stop and Save, which Return presses, Discard, and Cancel, which Escape presses.
Closing it while a recording waits unsaved asks "Save the recording?", with Save, Discard, and Cancel.

### Quitting TextMouth
<!-- id: new-recording-quitting; keys: quit, Command-Q, unsaved recording, terminate; src: TextMouth/Platform/macOS/Views/Recording/RecordingWindowController.swift, TextMouth/ViewModels/RecordingWindowModel.swift, TextMouth/Views/Recording/RecordingWording.swift -->

Quitting TextMouth asks the same question, the window brought forward: saving or discarding then quits, and Cancel keeps TextMouth open with the recording as it was.
A save that fails keeps TextMouth open, the window saying why, and the next quit asks again; a quit while a recording is starting or being saved waits for it, then asks if anything is left to ask.

## Recovered recordings
<!-- id: new-recording-recovered; keys: crash recovery, leftover take, power cut, Recordings folder, orphaned take; src: TextMouth/Services/RecordingTake.swift, TextMouth/ViewModels/RecordingWindowModel.swift, TextMouth/Views/Recording/RecordingWording.swift -->

### Where recovered recordings are listed
<!-- id: new-recording-recovered-list; keys: crash recovery, leftover take, forced quit, Recordings folder; src: TextMouth/Services/RecordingTake.swift, TextMouth/ViewModels/RecordingWindowModel.swift, TextMouth/Views/Recording/RecordingWording.swift, TextMouth/Platform/macOS/Views/Recording/RecordingWindowController.swift -->

A recording cut off by a crash, a forced quit, or a power cut stays in this Mac's Recordings folder, readable up to where it stopped, as does one whose save failed after its window closed.
The New Recording window lists them first, under Recovered recordings, each by when it was recorded and how long it lasts, as in "Recording of", the date and time, and the length, "1 minute, 4 seconds", and says how many it kept when it first lists them.
When TextMouth starts and finds any, it opens the window on them, VoiceOver starting on the first one's Save as Audiobook.
A recording an audio editor is making is never listed.

### Saving or discarding a recovered recording
<!-- id: new-recording-recovered-save-discard; keys: Save as Audiobook, Discard, empty recording, unsaved take; src: TextMouth/Services/RecordingTake.swift, TextMouth/ViewModels/RecordingWindowModel.swift, TextMouth/Views/Recording/RecordingWording.swift -->

Save as Audiobook saves one as Stop does, titled for when it was recorded, as in "Recording YYYY-MM-DD HH:MM", in the Save in folder; Discard deletes it.
Each button's label names its recording; one that holds no sound can only be discarded, and both wait while a recording is under way, being saved, or waiting to be saved.
Nothing is deleted on its own: a recording neither saved nor discarded is listed again next time.

## The original take
<!-- id: new-recording-original-take; keys: lossless, PCM, CAF, original-take.caf, 345 megabytes; src: TextMouth/Services/RecordingTake.swift, TextMouth/Models/AudioOriginalPolicy.swift -->

### The original audio policy
<!-- id: new-recording-original-policy; keys: recordingOriginalPolicy, recordingOriginalDays, Storage settings, Audio Editing, undo edits; src: TextMouth/Models/AudioOriginalPolicy.swift, TextMouth/Views/Settings/AudioEditingSettingsSection.swift, TextMouth/Services/RecordingPreferences.swift -->

A recording is first made as its original take, lossless audio of about 345 megabytes an hour, from which the audiobook's audio is encoded.
What happens to it follows the original audio policy of [Editing audio](editing-audio.md).
Original audio, in the Storage tab's Audio Editing group, offers Keep, Don't keep, and Keep for a number of days, the default, with Days to keep an original, from 1 to 365, 1 by default, counted from when the recording was saved, or from its last edit.
A change applies to the originals already kept too.

### Deleting old originals
<!-- id: new-recording-delete-originals; keys: expired originals, cleanup at launch, cloud library, sync; src: TextMouth/Models/AudioOriginalPolicy.swift, TextMouth/Services/RecordingTake.swift -->

Originals whose time is up are deleted when TextMouth starts and after each recording or edit is saved, and nothing is downloaded to do it.
In a library in the cloud, an original syncs with its book.
