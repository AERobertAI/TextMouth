# Media keys and the sleep timer
<!-- id: reader-media-and-sleep-timer-page; keys: AirPods, headphones, Now Playing, remote commands, timer; src: TextMouth/Services/NowPlayingService.swift, TextMouth/Services/SleepTimerService.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift -->

Part of [TextMouth's documentation](../../README.md).

The reader window itself, its menus, and search are in [Reader windows](reader-windows.md).

## Headphone and media keys
<!-- id: reader-headphone-media-keys; keys: AirPods, play pause key, Play command, Now Playing, remote command, last book, MPRemoteCommandCenter; src: TextMouth/Services/NowPlayingService.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Services/MediaGestureDetector.swift -->

Headphone and media keys control the reader that is playing, or, when none is, whichever came last of the reader window you used and the book that paused, or reached its end, while playing.
A Play command, which some headphones send apart from Play/Pause, goes to that last one even while another book plays.

### A book that pauses behind another window
<!-- id: reader-book-that-pauses-behind-another; keys: paused in Now Playing, headphones disconnecting, voice not starting, waiting to play, auto-play; src: TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Services/NowPlayingService.swift -->

A book that pauses while another book's window is in front, from the AirPods, a media key, its sleep timer running out, the headphones disconnecting, a recording starting, or its voice not starting a passage, is shown paused in Now Playing.
See [A voice that does not start a passage](reader-speech-problems.md#a-voice-that-does-not-start-a-passage).
And the next Play resumes it rather than starting the book in front.
Moving to another book's window afterwards makes that window's book the one Play starts.
A book waiting to play, for its chapter's speech or for a chapter's files to download, counts as playing: the AirPods leaving, a recording starting, or another book starting pauses it, so it never starts by itself once ready; Auto-play on navigate leaves such a book waiting.

### A book that rests finished at its end
<!-- id: reader-book-that-rests-finished-at; keys: finished state, rests at end, Previous Track, Skip Backward, Next Track, replay the end; src: TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Services/NowPlayingService.swift, TextMouth/Models/EndOfBookRule.swift -->

A book that ends and stops there, rather than starting again or continuing to the next book, rests finished at its end while its window stays open.
Now Playing shows it paused at its end, so the AirPods and the media keys still reach TextMouth.
And Previous Track or Skip Backward, from them or from the reader's own Skip Backward, moves back by the skip unit from the end and plays from there, so you can hear its last words again, with the skip's sound and then Play's.
It plays again only while no other book plays: with another book playing, Skip Backward in the finished book's window moves its cursor back without playing, leaves the other book playing, and the book is finished no longer.
When a sleep timer set for the end of the heading or of the book stops, at its end, a book that would continue to the next book, the timer is spent and the book rests finished: Skip Backward plays its end again, at full volume, and when it ends this time, the next book starts.
Skip Forward or Next Track by a number of seconds stays at the end and plays nothing, while a forward skip by sentence, paragraph, heading, or bookmark that finds a later place moves there without playing.
That move, or any other jump, such as to a heading, ends the finished state, as Release Media Controls does.
The book is then an ordinary stopped book, whose skips move the cursor without playing, and Play plays from the cursor, or, while the cursor is still at the end, does what Play does at a book's end (see [When a book ends](reader-book-end.md#when-a-book-ends)).
Closing the window, or quitting TextMouth, keeps it: the book is saved at its end, and opens finished again.

### A book that continues to the next book
<!-- id: reader-book-that-continues-next-book; keys: Starting, Still starting, rewind, next book announced, Play pressed; src: TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Models/EndOfBookWording.swift -->

A book that continues to the next book, in its folder or in the reading list, doesn't rest finished, though it too is saved at its end.
As VoiceOver says "Starting: Dune", Now Playing shows it paused at its end until Dune plays, and a rewind pressed in that moment moves its cursor back without playing over the book announced.
Play pressed in that moment, from the AirPods, a media key, or the keyboard, starts Dune at once instead of half a second later, and until Dune starts, Play never plays the finished book.
Once Dune has been asked for, Play or Play/Pause reaching the finished book says "Still starting: Dune".
Once Dune plays, Play in the finished book's window plays it as usual.

### Release Media Controls
<!-- id: reader-release-media-controls; keys: Media controls released, Media controls not released, give up media keys, Now Playing; src: TextMouth/Services/NowPlayingService.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/App/MenuCommands.swift -->

Release Media Controls is in the Playback menu while the window's book holds the media controls, meaning Now Playing shows it, playing or paused: a finished book counts, and so does a book whose speech stopped where the speech engine refused the text or where the sleep timer stopped it.
It hands the controls back to the system and says "Media controls released".
Once another book plays, that book holds them, and the first book's window no longer offers Release Media Controls; a key you gave it then changes nothing there and says "Media controls not released: this book does not hold them."

### Now Playing after a close, a pause, or a save
<!-- id: reader-now-playing-after-close-pause; keys: pause sound, window close, metadata save, title in Now Playing, AirPods stay; src: TextMouth/Services/NowPlayingService.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift -->

Closing a book's window, or the book being stopped, as when a chapter can't be downloaded or its text is replaced, takes its book out of Now Playing whenever Now Playing shows it, even from behind another book's window.
The book whose window you used last is shown instead if it was played and is paused, and otherwise the AirPods and the media keys go back to other apps.
A Pause that pauses nothing, as one reaching a book already paused or finished, makes no pause sound.
And one reaching a book that doesn't hold the media controls, such as one that never played, was stopped, or released them, tells the system nothing, so the AirPods stay with the app or the book they are with.
Saving a book's metadata, in its window or the Library window, or any other change of its title or author, such as the metadata refresh after an update, shows its new title in Now Playing only while the book holds the media controls, a finished book included.
So a save never takes the AirPods from the app or the book you were listening to.

## The sleep timer
<!-- id: reader-windows-sleep-timer; keys: sleep timer sheet, Stop At, presets, minutes, SleepTimerService, SleepTimerView; src: TextMouth/Services/SleepTimerService.swift, TextMouth/Views/Reader/SleepTimerView.swift, TextMouth/Models/DocumentContent.swift -->

The sleep timer runs for a set number of minutes, a preset or typed, or stops at a place in the book: its sheet's Stop At section sets one that stops at the end of the heading, or at the end of the book, for text books and audiobooks alike.
Headings are one concept for any book: where the next heading of any level begins, as Next Heading finds it, or the book ends, in a text book of any format or an audiobook, whose chapters, tracks, and chapter markers are its headings.

### End of heading
<!-- id: reader-end-heading; keys: End of chapter, End of document, stop at heading, Restart Sleep Timer, chapter end; src: TextMouth/Services/SleepTimerService.swift, TextMouth/Models/DocumentContent.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift -->

End of heading pauses playback where the heading playing ends:

- within a chapter, where the next heading begins, with the cursor put back at that heading for Play to start it;
- at a chapter's end, when the next chapter opens with the next heading, as every audiobook chapter does, with the reader waiting at the start of that chapter, which Play starts;
- and at the book's end, which ends the last heading.

A timer for the end of the heading set where there is nothing to read, as on a book's cover, waits for the end of the heading that playback starts in, so Play does not stop in silence at once.
A next chapter that has text before its first heading, or no heading at all, goes on under the same heading, so playback goes on into it.
Restart Sleep Timer after a timer saved as End of chapter, or as End of document, arms End of heading.
VoiceOver says "Sleep timer: stops at the end of this heading." as the timer is set, reads its status the same way in the sheet and in the reader, and says "Sleep timer expired at the end of the heading.
Playback paused." where it stops; stopped at the book's end, the reader says instead that the book finished and why nothing follows, as in "Finished: Moby-Dick.
Next book not started because of the sleep timer."

### End of book
<!-- id: reader-end-book; keys: stop at book end, timer expired, next book not started; src: TextMouth/Services/SleepTimerService.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Models/EndOfBookWording.swift -->

End of book pauses playback when the book ends, before the book starts again or the next book starts.

### Fade out
<!-- id: reader-fade-out; keys: fade out time, volume fade, Playback settings, prepared audio, m4b, chapter marker; src: TextMouth/Services/SleepTimerService.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Services/SpeechService.swift -->

An audiobook fades out toward a stop at a chapter's end over the sleep timer's Fade out time, in Playback settings, when one is set.
Speech is not faded toward such a stop, and an m4b's chapter marker inside one file stops the timer a moment past the marker, without a fade, the cursor put back at the marker.
When a timer counting minutes runs out and a Fade out time is set, playback fades out over that time before it pauses:

- an audiobook in its own audio,
- speech playing from the audio TextMouth prepared in that audio, and
- speech read straight from the voice in ever quieter stretches, the voice starting again from the word it had reached.

Speech read straight from the voice does not move to the prepared audio as the fade begins, a move that could repeat or skip a few words.

### One sleep timer for each window
<!-- id: reader-one-sleep-timer-each-window; keys: SleepTimerRegistry, second window, timer per window, window's own timer; src: TextMouth/Services/SleepTimerRegistry.swift, TextMouth/Services/SleepTimerService.swift, TextMouth/Models/SleepTimerHandOverWording.swift -->

Each reader window has a sleep timer of its own, which belongs to the window and pauses only its book: setting, restarting, or cancelling a timer in one window leaves every other window's timer as it is, and another window's playback, even of the same book, never pauses or ends it.
A book you open in a second window while the first has a timer, running or paused, starts with no timer, and playing it neither runs nor stops the first window's.
A window keeps its timer when the book it shows changes in place, as when listening goes on to the next book in the same window (see [When a book ends](reader-book-end.md#when-a-book-ends)).
A new window that listening goes on to takes the timer once its book has loaded; closing a window stops only its own timer.

### Showing, setting, and restarting the timer
<!-- id: reader-showing-setting-restarting-timer; keys: Show Sleep Timer, Restart Sleep Timer, AirPods gesture, MediaGestureDetector, Timer reset, Timer restarted; src: TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Views/Reader/SleepTimerView.swift, TextMouth/Services/MediaGestureDetector.swift, TextMouth/App/MenuCommands.swift -->

Each window's Sleep Timer sheet shows, sets, restarts, and cancels that window's timer, and the sheets of two windows can be open at once.
Show Sleep Timer and Restart Sleep Timer from the menu or the keyboard act in the window in front.
Restart Sleep Timer from the AirPods or the media gesture acts on the book you are hearing: the window of the book that is playing or, while none plays, of the book whose window you used last.
A restart in a window with no timer running starts a timer there, with the duration last started in any window, and VoiceOver says "Timer restarted: 10 minutes."; with a timer running it says "Timer reset." as before.

### The custom timer's minutes
<!-- id: reader-custom-timer-minutes; keys: custom timer, Adjust minutes, stepper, singular minute, accessibility label; src: TextMouth/Views/Reader/SleepTimerView.swift -->

In the sheet, the custom timer's field and its Adjust minutes stepper both say their minutes with the unit, as in "30 minutes", and the stepper moves by 5; a custom timer of one minute is said in the singular, as in "Set timer for 1 minute".
Its hint, "Plays the book.", says that it also starts the book.

## Stop and Release Media Controls
<!-- id: reader-stop-release-media-controls; keys: stop command, chapter download, countdown, speech engine word past end; src: TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Services/SleepTimerService.swift, TextMouth/Services/NowPlayingService.swift -->

Stop, and Release Media Controls, which stops the book, end the wait of a chapter downloading from the cloud, and Play then waits for the chapter again.
A sleep timer of minutes stops counting down at every stop, as it does at a pause, and counts on only when playback does.
A voice that reports a word past the end of its text is ignored, with the cursor staying where it was.
