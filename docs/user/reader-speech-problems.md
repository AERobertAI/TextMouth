# When speech or audio goes wrong
<!-- id: reader-speech-problems-page; keys: speech engine, voice, audio problems, memory, Ogg; src: TextMouth/Services/SpeechService.swift, TextMouth/Services/SpeechMarkupGuard.swift, TextMouth/Services/PlaybackMemoryGuard.swift -->

Part of [TextMouth's documentation](../../README.md).

The reader window itself, its menus, and search are in [Reader windows](reader-windows.md).

## Speech markup in a book's text
<!-- id: reader-speech-markup-book-text; keys: SSML, angle brackets, speech markup, sm tag, AVSpeechSynthesizer, macOS 26.3.1; src: TextMouth/Services/SpeechMarkupGuard.swift, TextMouth/Services/SpeechService.swift -->

### The markup guard
<!-- id: reader-markup-guard; keys: angle quotation marks, opening tag, closing tag, less-than sign, greater-than sign, ampersand; src: TextMouth/Services/SpeechMarkupGuard.swift, TextMouth/Services/SpeechService.swift -->

A book's text can hold what looks like markup, such as the `<sm>` and `</sm>` one novel marks its silent messages with, and the speech engine of macOS 26.3.1 takes such tags for speech markup.
It skipped the rest of a passage after an opening tag, and refused a passage holding a closing tag alone, after which the book's speech stopped and couldn't be started again.
TextMouth hands the voice each tag with its two angle brackets changed to single angle quotation marks, which the engine doesn't take for markup, so the brackets are silent and what is between them, a tag's name included, is spoken.
The engine takes for an opening tag:

- any name of letters, figures, or symbols between angle brackets, with no space or slash inside it and spaces around it or not, such as `<sm>`, `< sm >`, `<5>`, `<...>`, `<=>`, or `<*>`;
- such a name followed by name=value attributes, as in <a href="x">;
- and empty brackets, <> or < >.

Each of these made it skip the rest of a passage without a sound, and TextMouth silences the brackets of every one, and of every closing tag, such as `</sm>`.
A less-than or greater-than sign that isn't part of a tag, as in "x < y and y > z", is still read aloud, except in audio TextMouth prepared again with every angle bracket silent (below).
An ampersand is left for the voice, which reads it as "and".
And the text on screen and on a braille display is unchanged.

### A null character
<!-- id: reader-null-character; keys: U+0000, NUL, control character, Where Am I, Speak Info; src: TextMouth/Services/SpeechMarkupGuard.swift -->

A null character (U+0000), which a badly converted file can hold, made the speech engine drop the rest of a passage without a sound, and without a refusal TextMouth could hear; TextMouth hands the voice a space in its place.
No other control character dropped anything.
Where Am I?, which can quote the book, and Speak Info, which speaks titles, are spoken the same way.

### When the speech engine refuses a passage
<!-- id: reader-when-speech-engine-refuses-passage; keys: refusal, fresh voice, prepared audio, background audio, retry, chapter audio; src: TextMouth/Services/SpeechService.swift, TextMouth/ViewModels/ReaderViewModel+SpeechRefusal.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift -->

Should the speech engine still refuse a passage of a text book, TextMouth starts the voice afresh at once, since the one that refused would never speak again.
If TextMouth has finished preparing the chapter's audio in the background, as it does while it speaks any chapter of up to 100,000 characters, speech goes on from that audio at the refused passage, from the last word heard in it or from its start, so nothing heard is heard twice.
If the speech engine refuses the chapter's text as TextMouth prepares its audio in the background, TextMouth prepares the audio once more with every angle bracket silent, so that a refusal while the voice reads has that audio to go on from.
Speech played from that audio says no less-than or greater-than sign.
Without prepared audio to go on from, TextMouth tries the passage once more from there, with every angle bracket in the rest of the passage silent, so a less-than sign there isn't read; the passages after it are read as before.
That one more try belongs to the place: once speech has gone on from it, a refusal met at that same place later, as after a jump back to it, is tried once more too.

### The Speech Stopped sheet
<!-- id: reader-speech-stopped-sheet; keys: Speech Stopped, Details, report, Copy Details, Show Logs in Finder, refusal report, speech log; src: TextMouth/Views/Reader/SpeechRefusalReportSheet.swift, TextMouth/Models/SpeechRefusalReport.swift, TextMouth/ViewModels/ReaderViewModel+SpeechRefusal.swift -->

Refused there again, with no prepared audio to go on from, speech stops with the cursor at that passage.
And the book's window shows a sheet headed "Speech Stopped", with one sentence under the heading, which VoiceOver reads with it: "The speech engine refused to speak the text here, twice, so speech stopped.
Play tries again from the same place."
Below them, a read-only text area labelled Details, which VoiceOver reads line by line and a braille display pans, holds a report for finding the cause:

- the book and its format;
- the place, as the brief Where Am I? says it, then the chapter, and the character where speech stopped, counted both in the book's text and in the spoken text, whose offsets the speech log gives;
- how many times that place was refused while the window has been open;
- the time, as the logs write it;
- up to 100 characters before where speech stopped and 400 from it, of the book's text and of the text exactly as it was handed to the speech engine, after the substitutions and the markup guard, with where the refused text begins and ends said in words on lines of their own;
- the markup guard in force;
- the voice, the speed, and the rate, pitch, and volume handed to the engine;
- macOS's version;
- TextMouth's build;
- and the last 40 lines the book's speech logged, including the routine lines that the speech log's file keeps only while tracing is on, which hold offsets and lengths, never the book's words.

Copy Details copies the whole report as plain text and says "Details copied"; Show Logs in Finder opens the folder the logs are written to, and says why, aloud and under the buttons, when Finder can't; and Close, Return, or Escape closes the sheet.
With the book's window in front, VoiceOver moves to the sheet's heading and hears nothing else.
When another window or app is in front, a panel such as Headings or Bookmarks, the Export dialog, a transcription dialog, or an error alert is open over the book, or the report is open already, VoiceOver says instead "Speech stopped: the speech engine refused this passage.
Details are in the book's window.", and the sheet waits in the book's window, or until what is over the book closes, when VoiceOver moves to it.
A refusal while the report is open updates it in place, and Play leaves it open.

### After speech stops
<!-- id: reader-after-speech-stops; keys: pause, AirPods, sleep timer, Next Heading, skip past the passage, listening time; src: TextMouth/ViewModels/ReaderViewModel+SpeechRefusal.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift -->

TextMouth treats that stop as a pause: the AirPods and the media keys stay with TextMouth, and their next press is Play, which speaks from that passage; no time after the stop counts as listening; the place is saved; and a sleep timer's countdown waits until Play.
Pressing Play there usually brings the same refusal and the report again, counting one more refusal of the place, so move past the passage first, with a forward skip by sentence or paragraph, or with Next Heading or Show Headings, and then press Play.
A passage refused just as you pause is tried again, the same way, when you press Play, and one refused while the sleep timer fades speech out is tried again at once, no louder than the fade had come to.

### A stopped Where Am I? or Speak Info
<!-- id: reader-stopped-where-am-i-speak; keys: announcement, summary, fresh start, stopped announcement; src: TextMouth/Services/SpeechService.swift, TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift, TextMouth/ViewModels/ReaderViewModel+SpeakInfo.swift -->

Should the speech engine stop a Where Am I? announcement before its end, the announcement ends without its end sound and the book stays paused, as a pause leaves it, so Play/Pause plays it at once, and the next Where Am I? speaks with a fresh start of its voice.
Should it stop a Speak Info summary, the next press speaks, with a fresh start of the voice.

### A voice that does not start a passage
<!-- id: reader-voice-that-does-not-start; keys: Speech paused, voice did not start, five and a half seconds, ten and a half seconds, watchdog, start watchdog; src: TextMouth/Services/SpeechService.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift -->

Should the voice be handed a passage and not start it, TextMouth notices about five and a half seconds later.
Or about ten and a half while the voice has started nothing yet, as at the first Play in a book's window or after it was started afresh, since a voice still loading can take longer, counting only while speech should be heard.
It then starts the voice afresh and goes on from the start of that passage, from the audio it prepared when it has it, and otherwise from the voice.
A jump, or such a recovery, that would go on from the prepared audio goes on from the voice when the Mac can't play that audio.
If the voice still hasn't started the passage after two fresh starts, speech pauses there, with no pause sound, the AirPods' next press is Play, and VoiceOver says "Speech paused: the voice did not start.
Press Play to try again."
Play resumes from that place, as after any pause.

### A voice that goes silent
<!-- id: reader-voice-that-goes-silent; keys: silence, voice stops, restart at same word, stall; src: TextMouth/Services/SpeechService.swift -->

A voice that starts a passage and then goes silent without finishing it is started again from about where it went silent, at most twice at the same word; the third time speech pauses there in the same way, with the same words.

## Time limits on reading audio
<!-- id: reader-time-limits-reading-audio; keys: Loading, import stuck, timeout, AsyncBridge, Reading the audio took longer; src: TextMouth/Services/AsyncBridge.swift -->

Reading an audiobook's audio to open it or to import it has a time limit of 5 minutes, and reading an audio file's tags one of 30 seconds, so that a read which never returns cannot leave a window on Loading or an import stuck for good.
After 5 minutes the book or the import fails as any read does, with "Reading the audio took longer than 5 minutes; TextMouth stopped waiting."; after 30 seconds the book opens without its tags.

## Audio that stops responding
<!-- id: reader-audio-that-stops-responding; keys: stalled audio, Playback stopped, audio engine, frozen playback, ten seconds; src: TextMouth/Services/AudioPlaybackService.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift -->

If an audiobook's audio stops moving while TextMouth shows it playing, TextMouth stops it after about ten seconds and says: "Playback stopped: the audio stopped responding.
Press Play to try again; if it stops again, quit and reopen TextMouth."

## Memory growing while a book plays
<!-- id: reader-memory-growing-while-book-plays; keys: 3 GB, memory footprint, runaway memory, playback stopped, PlaybackMemoryGuard; src: TextMouth/Services/PlaybackMemoryGuard.swift, TextMouth/Services/AudioPlaybackService.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift -->

If TextMouth's memory grows past 3 GB while a book plays, which only a fault in macOS's audio causes, playback stops and TextMouth says how large its memory grew.

## The memory limit
<!-- id: reader-memory-limit; keys: 6 GB, memory, saves your place and quits, runaway, footprint, every 5 seconds; src: TextMouth/Services/PlaybackMemoryGuard.swift -->

TextMouth reads its own memory every 5 seconds while a book plays, and every 30 seconds when nothing does, or every 5 once it holds 1 GB or more.
Past 6 GB, whether or not anything is playing and whatever the cause, it saves your place and quits, so a runaway can't exhaust the Mac's memory.
The limit is 6 GB on every Mac, however much memory the Mac has.

## The alert after a memory quit
<!-- id: reader-alert-after-memory-quit; keys: TextMouth Quit to Protect Your Mac, launch alert, memory quit, quit notice; src: TextMouth/Services/PlaybackMemoryGuard.swift -->

The next launch tells you of such a quit in an alert titled "TextMouth Quit to Protect Your Mac", with an OK button.
The alert gives the date and time in your region's format and how large the memory had grown.
If a book was playing, or had been stopped for the growth, it names the book: "TextMouth quit on DATE AND TIME: its memory grew to 6.1 GB while Ferry Timetables played, because of a fault in macOS's audio.
Your place was saved."
If nothing was playing, it says so: "TextMouth quit on DATE AND TIME: its memory grew to 6.1 GB while nothing was playing.
Your place was saved."

## Sound effects
<!-- id: reader-sound-effects; keys: sound effect, pause sound, sounds setting, SoundEffectService; src: TextMouth/Services/SoundEffectService.swift -->

Sound effects never hold up the window: a sound the system can't start is skipped.

## Audio being converted from Ogg
<!-- id: reader-audio-being-converted-from-ogg; keys: Ogg Vorbis, AAC conversion, Play refused, converted, OggConversion; src: TextMouth/ViewModels/ReaderViewModel+OggConversion.swift, TextMouth/ViewModels/LibraryViewModel+OggConversion.swift, TextMouth/ViewModels/OggConversionProgress.swift -->

Play refuses a book whose audio is being converted, saying "This book's audio is being converted from Ogg to AAC.
It plays when that ends."
A book found still in Ogg is converted at once instead of played.
