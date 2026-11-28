# Transcribing an audiobook
<!-- id: transcribing-audiobook; keys: speech recognition, SpeechTranscriber, SpeechAnalyzer, captions, subtitles; src: TextMouth/Models/TranscriptionWording.swift, TextMouth/Services/TranscriptionAvailability.swift, TextMouth/Services/TranscriptionEngine.swift -->

Part of [TextMouth's documentation](../../README.md).

Transcribing an audiobook needs macOS 26 or later.

In a sentence quoted below, DATE stands for a day as the app writes it: the month's name, the day, and the year.

## Transcribe Audio…
<!-- id: transcribe-audio; keys: transcribe command, speech to text, Book menu, context menu; src: TextMouth/Models/TranscriptionWording.swift, TextMouth/Models/LibraryAudioCommand.swift, TextMouth/App/MenuCommands.swift -->

Transcribe Audio…, in an audiobook's context menu, its actions in VoiceOver's Actions menu, and an open audiobook's Book menu, opens the Transcribe Audio sheet for the book.
Once the book has a transcript, the command reads Retranscribe Audio… in all three places, in place of Transcribe Audio…, and the sheet is headed "Retranscribe Moby-Dick" (see Retranscribe Audio…, below).
Transcription works on one audiobook at a time, and chosen for several books, with a transcribed one among them or not, the command reads Transcribe Audio… and the sheet only says so.
On macOS 14 and 15 it only says that transcription needs macOS 26 or later, and on a Mac that can't run the speech model, that it can't.
## The Transcribe Audio sheet
<!-- id: transcribe-audio-sheet; keys: language model, model download, time estimate, progress; src: TextMouth/Models/TranscriptionWording.swift, TextMouth/ViewModels/TranscriptionSheetModel.swift, TextMouth/Views/Transcription/TranscriptionSheet.swift -->

The sheet gives the audio's length, how long transcribing should take (about a minute for each hour of audio), and the language set in Settings, with its speech model's status, as in "Language: English (United States), installed."
A model not yet on this Mac is offered as a button, as in "Download the English model, about 140 MB": nothing downloads until you press it, the download shows its progress, and Cancel Download stops it.
VoiceOver moves to the sheet's first control, then hears its lines.
Return presses Transcribe, and Escape presses Cancel.
While another book is being transcribed, the sheet names it, and Transcribe is unavailable until that finishes.
## While a book is transcribed
<!-- id: while-book-transcribed; keys: progress bar, cancel transcription, background transcription, quarter announcements; src: TextMouth/Models/TranscriptionWording.swift, TextMouth/ViewModels/TranscriptionJobCenter.swift, TextMouth/ViewModels/TranscriptionSheetModel.swift -->

While the book is transcribed, the sheet shows the file it is on, how much of the audio is done, the time elapsed, and a progress bar VoiceOver reads as "40 percent, file 3 of 12".
Cancel, which Escape presses, stops it and leaves the book as it was.
VoiceOver hears the start, as in "Transcribing Moby-Dick, about 6 minutes.", each quarter, as in "Moby-Dick: 25 percent transcribed.", and the end, as in "Transcribed Moby-Dick: 7,077 words in 51 seconds."
A transcription goes on when the window it began in closes, and Transcribe Audio… for that book shows it again.
Quitting TextMouth cancels it without asking.
## After a transcript is saved
<!-- id: after-transcript-saved; keys: Transcribed badge, library row, reader text; src: TextMouth/Models/TranscriptionWording.swift, TextMouth/ViewModels/TranscribedBooks.swift -->

Once the transcript is saved, an open reader of the book shows its text at once.
The book's row says Transcribed after its title, or Transcribing while it is being transcribed, after any cloud note, on screen and to VoiceOver alike.
A book that has a transcript is transcribed again with Retranscribe Audio… (next).
## Retranscribe Audio…
<!-- id: retranscribe-audio; keys: transcribe again, replace transcript, later version of TextMouth; src: TextMouth/Models/TranscriptionWording.swift, TextMouth/ViewModels/TranscriptionSheetModel.swift -->

Retranscribe Audio… transcribes the book's audio again and replaces its transcript.
Its sheet, headed "Retranscribe Moby-Dick", has a button that reads Retranscribe in place of Transcribe, whose hint is "Transcribes the book's audio again, replacing its transcript."
After the language, the sheet says in one line each what Retranscribe replaces: "Transcribed on DATE, in English (United States).
Transcribing again replaces this transcript."; if you edited the transcript, "You edited this transcript on DATE.
Transcribing again replaces your edits."; and if you cleaned it up, "You cleaned up this transcript on DATE.
Transcribing again replaces the cleanup."
A transcript that a later TextMouth wrote, as on another Mac sharing the library, which this TextMouth can't read, gets "This book has a transcript made by a later version of TextMouth.
Transcribing again replaces it." in place of the first line.
The rest of the sheet is as for Transcribe Audio…, above.
## A book or transcript only in iCloud
<!-- id: book-transcript-only-icloud; keys: cloud placeholder, content.md, not downloaded, Transcription stopped; src: TextMouth/Models/TranscriptionWording.swift, TextMouth/ViewModels/TranscriptionSheetModel.swift -->

Before a book is transcribed, the sheet looks for a file that is only in iCloud, without reading or downloading anything, so that the audio is not transcribed for nothing.
While the book's transcript is only in iCloud, the sheet says "The transcript is only in iCloud, so TextMouth leaves it.
Download the book, then try again.", and while its text, content.md, is only in iCloud, "The book's text is only in iCloud, so TextMouth leaves it.
Download the book, then try again.", the transcript's line first when both are.
Transcribe, or Retranscribe, is then unavailable, and VoiceOver moves to Cancel.
A text that goes to iCloud while the audio is being transcribed is caught when the transcript is to be saved: nothing is saved, the book keeps what it had, and the transcription ends with "Transcription stopped: " and the sentence about the text.
## Clean Up Transcript (Experimental)…
<!-- id: clean-up-transcript-experimental; keys: cleanup sheet, TranscriptCleanup, recognizer corrections, Apply; src: TextMouth/Models/TranscriptCleanupWording.swift, TextMouth/ViewModels/TranscriptCleanupSheetModel.swift, TextMouth/Views/Transcription/TranscriptCleanupSheet.swift -->

Clean Up Transcript (Experimental)…, in the same places for a transcribed audiobook, a feed's episode included, opens the Clean Up sheet, which corrects words the recognizer always writes another way, by rules, and changes nothing until you press Apply.
The sheet names the rules in use, as in "Rules: your copy, version 1 of DATE, 2 rules.",
- says what they would change, as in "23 corrections in 19 sentences.",
- and lists each rule that changes something, with its count and up to three examples, before and after, each read by VoiceOver as one line.

A rule that would leave a sentence with no text at all, as a rule that turns "um" into nothing would for a sentence that is only "Um", leaves that sentence as it is, neither listing nor counting it.

It says when the transcript was last cleaned up.

VoiceOver moves to Apply when the rules change something, and to Cancel otherwise, then hears the sheet's lines.

Return presses Apply, and Escape presses Cancel.

Coming back to TextMouth, as after editing the rules, shows what the rules would change then.

While the book is being transcribed, or its transcript can't be read, the sheet only says so.
## What Apply does
<!-- id: what-apply-does; keys: transcript.json.before-cleanup, backup copy, refused, word timings; src: TextMouth/Models/TranscriptCleanupWording.swift, TextMouth/Services/TranscriptCleanup.swift, TextMouth/Services/TranscriptCleanupStore.swift -->

Apply keeps the transcript as it was beside it, as transcript.json.before-cleanup,
- rewrites each sentence the rules changed, keeping its time in the audio and dropping its words' timings, as an edit in your own editor does,
- notes the cleanup in the transcript,
- and writes the book's text again from it.

Open readers show the cleaned text as the book plays on, and VoiceOver hears "Cleaned up the transcript of Moby-Dick: 23 corrections."

Positions and bookmarks stay as they were, since they count time.

Apply is refused, saying why, when the book is being transcribed,
- when the transcript changed after the sheet showed it, as when another Mac transcribed the book again,
- when the book's audio changed after it was transcribed,
- when the book's text is only in iCloud,
- or when the text holds changes that TextMouth can't keep a copy of before it replaces them.

The last two say, after "Couldn't clean up the transcript of Moby-Dick: ", "The book's text is only in iCloud, so TextMouth leaves it.

Download the book, then try again." and "The book's text has changes TextMouth couldn't copy, so it leaves the text as it is."
## Undo Cleanup
<!-- id: undo-cleanup; keys: restore transcript, Edit Text session, last cleanup; src: TextMouth/Models/TranscriptCleanupWording.swift, TextMouth/ViewModels/TranscriptCleanupSheetModel.swift, TextMouth/Services/TranscriptCleanupStore.swift -->

Undo Cleanup, in the sheet while the transcript is cleaned up, puts back the transcript from before the last cleanup, with its text, and removes the copy.
Only the last cleanup can be undone: the next replaces the copy with the transcript it cleans.
Undo Cleanup also undoes the edits you made since the cleanup, as the sheet says first.
A cleanup, its undo, Delete Transcript, and transcribing again each take first an edit you saved that TextMouth had not yet checked, then end the book's Edit Text session; if the change fails, the session begins again, so your later saves are still taken.
After a cleanup, an undo, or a new transcription, choose Edit Text again to edit the new text, since an edit saved in an editor opened before counts as one made outside Edit Text (see [Editing a book's text](editing-book-text.md)).
## A feed episode's transcript
<!-- id: feed-episode-transcript; keys: podcast episode, Delete Episode, Delete Feed, Move to Library; src: TextMouth/Models/BookTextEditWording.swift, TextMouth/Models/TranscriptCleanupWording.swift -->

A feed episode's transcript can be edited and cleaned up as any audiobook's can:
- Edit Text in Default Editor, Edit Text With…, and Clean Up Transcript (Experimental)… are offered for a transcribed episode in its feed, in its row's menu and its reader's Book menu,
- while Edit Audio…, Book Info's editing, and, for a feed's article, Edit Text still are not (see [Podcasts and article feeds](feed-commands.md)).

Your changes stay with the episode in its feed, even after its download is deleted; Delete Episode… and Delete Feed… delete them, and Move to Library… keeps them with the episode as a book.

The words are: "This episode's transcript, with your changes, stays with the episode in its feed, even after its download is deleted.

Deleting the episode or the feed deletes it; Move to Library keeps it with the episode as a book."

The Clean Up sheet has them on a line of its own, after the line that calls the cleanup experimental, and VoiceOver says them after the first edit of an episode's text that Edit Text takes, as "Text updated.

" followed by them; a later edit in the session says only "Text updated".
## Cleanup rules and Edit Rules…
<!-- id: cleanup-rules-edit-rules; keys: transcript-cleanup.json, Edit Rules, British spelling, built-in rules; src: TextMouth/Models/TranscriptCleanupRules.swift, TextMouth/Services/TranscriptCleanupRuleFile.swift, TextMouth/Resources/transcript-cleanup.json -->

The rules: TextMouth comes with none of its own, and the sheet then says how to add some.
Edit Rules… opens your own copy, transcript-cleanup.json in the data directory, in your default text editor, making it the first time from TextMouth's own file, which explains the format and holds two worked examples, used only once you move them into its rules.
A name the recognizer always spells another way in a series is the case a rule fits.
For British spelling, choose English (United Kingdom) as the transcription language instead: the recognizer then writes it without any rule.
## The fields of a rule
<!-- id: fields-rule; keys: wholeWord, evidence, pattern, replacement, unreadable copy; src: TextMouth/Models/TranscriptCleanupRules.swift, TextMouth/Services/TranscriptCleanupRuleFile.swift -->

A rule has a pattern and a replacement;
- wholeWord, true unless set, which matches whole words only, keeping the punctuation around them and a possessive "'s" after them, as "Bennett's" becomes "Bennet's", where false matches inside words too;
- evidence, how many places it was right in, 0 for a rule of your own;
- and an optional note.

Matching ignores case and the kind of apostrophe, the replacement takes the case of the words it replaces, and the rules apply in order.

Your copy can't be used when TextMouth can't read it in that format,
- or when its version is below 1, its date isn't a day written as `2026-10-04`,
- or one of its rules has an empty pattern or replacement, a pattern without a letter or figure, or a replacement holding its own pattern, which every cleanup would change again.

In each case:

- the sheet says why, naming the field, as in "rules[2].replacement is empty",
- a copy of it is kept beside it, its name followed by .unreadable- and the date and time,
- and TextMouth's own rules stand in until you correct it.

While your copy is only in the cloud, TextMouth asks the sync service for it, and its own rules stand in meanwhile.

When TextMouth's own rules are newer than your copy, the sheet says so.
## Delete Transcript…
<!-- id: delete-transcript; keys: remove transcript, reading text, transcribe again; src: TextMouth/Models/TranscriptionWording.swift, TextMouth/Services/TranscriptDeletion.swift -->

Delete Transcript…, in the same places for a transcribed audiobook, asks first, naming the book and saying when your edits go too, then deletes the transcript, the copy kept from before its last cleanup, the text made from it, and the reading text kept for the book.
The audio, your place, and your bookmarks stay, and the book can be transcribed again.
While the book is being transcribed, Delete Transcript… says to cancel the transcription first.
## Transcription settings
<!-- id: transcription-settings; keys: Playback tab, transcriptionLocale, offerTranscriptionAfterImport, config.json; src: TextMouth/Views/Transcription/TranscriptionSettingsSection.swift, TextMouth/Models/TranscriptionPreferences.swift, TextMouth/ViewModels/TranscriptionOffers.swift -->

The Playback tab of Settings has a Transcription group.
Transcription language lists the languages the recognizer supports, each marked installed or needs download.
Offer to transcribe after importing an audiobook, off by default, asks after each audiobook TextMouth imports, after the import's other questions, "Transcribe the Audiobook?":
- Transcribe, which Return presses, opens the sheet, which starts at once when the language's model is on this Mac, and otherwise offers the model's download, after which you choose Transcribe,
- and Not Now, which Escape presses, leaves the book as it is.

## Transcripts that come from a file
<!-- id: transcripts-that-come-from-file; keys: captions, subtitles, sidecar file, TranscriptSource; src: TextMouth/Services/OutsideTranscript.swift, TextMouth/Models/TimedText.swift -->

Part of version 0.4.2.
A transcript need not be made by recognition.
An audiobook can take one from a WebVTT (.vtt) or SubRip (.srt) file, on any macOS, and nothing is transcribed.

### Attach Transcript…
<!-- id: attach-transcript; keys: TranscriptAttachments, Open panel, 100 hours, cue limits; src: TextMouth/Models/TranscriptionWording.swift, TextMouth/ViewModels/TranscriptAttachments.swift, TextMouth/Models/TimedText.swift -->

- Attach Transcript… is in an open audiobook's Book menu.
  It is offered for the audiobooks that Transcribe Audio… is offered for: an audiobook in a package of its own.
- It opens an Open panel.
  The panel says "Choose a WebVTT (.vtt) or SubRip (.srt) transcript of Moby-Dick, timed from the start of its audio." and its button is Attach.
- A book of several tracks takes one file for the whole book, whose times run on across the tracks.
- While the file is saved, VoiceOver hears "Attaching “lecture.vtt” to Moby-Dick."
  When it is done, VoiceOver hears "Attached “lecture.vtt” to Moby-Dick: 7,077 words."
- If some timed passages of the file could not be read, the sentence goes on, as in "1 timed passage couldn't be read and was left out."
- A book's whole transcript is one file timed from the start of its audio, so for a long book its times run past 100 hours.
  Attach reads times up to 1,000 hours, and cuts the file into the book's audio files, each time then counted from its own file's start.
  - A single audio file can still be timed for only its first 100 hours.
    A passage that starts after a file's hundredth hour is left out and counted with the passages that could not be read, as in "2 timed passages couldn't be read and were left out."
    A passage that runs across the hundredth hour ends there.
  - A file that runs further past the end of the book's audio than a few seconds is still refused.
- A passage of more than 10,000 characters, some 1,700 words, is cut short, and the sentence goes on to say so, as in "1 timed passage was too long and was cut short."
  The cut falls at the end of a sentence in the passage's second half if there is one, else between two words.
  A speaker's name keeps its first 100 characters.
- The book's text is then the transcript, and the book's row says Transcribed.

### When a book has a transcript already
<!-- id: when-book-has-transcript-already; keys: Replace Transcript, confirmation, overwrite; src: TextMouth/Models/TranscriptionWording.swift, TextMouth/ViewModels/TranscriptAttachments.swift -->

- A confirmation asks first, headed "Replace the Transcript of Moby-Dick?".
  It says "The transcript from “lecture.vtt” replaces the book's transcript and the text made from it." and then what stays: the audio, your place, and your bookmarks.
- If you edited the transcript, it adds "Your edits to the transcript are replaced too."
  If you cleaned it up, it adds "Its cleanup is replaced too."
- Its button is Replace Transcript.

### When Attach Transcript… does nothing
<!-- id: when-attach-transcript-does-nothing; keys: attach alert, error message, named pipe, unreadable file; src: TextMouth/Models/TranscriptionWording.swift, TextMouth/Models/TimedText.swift -->

- Each reason is said in an alert titled Attach Transcript.
- The file is neither .vtt nor .srt: "TextMouth attaches WebVTT (.vtt) and SubRip (.srt) files."
- The item is not a plain file, such as a named pipe: "That item isn't a plain file TextMouth can read."
- The file can't be used: "“lecture.vtt” wasn't attached to Moby-Dick:" and the reason, such as "The file isn't a WebVTT transcript TextMouth can read."
- The book is being transcribed: "Moby-Dick is being transcribed.
  Cancel the transcription first, or attach the transcript once it finishes."

### While a transcript is being attached
<!-- id: while-transcript-being-attached; keys: dimmed, busy, second file; src: TextMouth/Models/TranscriptionWording.swift, TextMouth/ViewModels/TranscriptAttachments.swift -->

- Transcribe Audio… is dimmed for that book.
  From any other route, such as a library row's action or VoiceOver's, Transcribe Audio… waits: a notice titled Transcribe Audio says "A transcript is being attached to Moby-Dick.
  Transcribe it once that finishes."
- The notice is for one book.
  Transcribe Audio… for several books at once is refused by its own sheet, as before, whatever is being attached.
- Attach Transcript… is dimmed for the book too, so a second file is never attached over the first.

### A transcript beside the audio at import
<!-- id: transcript-beside-audio-at-import; keys: sidecar, TranscriptPairing, ZIP, playlist, import notice; src: TextMouth/Services/TranscriptPairing.swift, TextMouth/Models/TimedText.swift -->

- When you import an audiobook, TextMouth looks for a transcript file named as a track is: lecture.vtt beside lecture.m4a, or 03.vtt beside 03.mp3.
  It looks in a single file's folder, a folder of tracks, a ZIP, or a playlist's folder.
- WebVTT is preferred when both a .vtt and an .srt are there.
  Each track takes its own file, and the times run on across tracks.
- The file becomes the book's transcript.
  No transcription is offered for that book afterwards, and its row says Transcribed as soon as it is listed.
- A file that can't be used never fails the import.
  Once the import is done, VoiceOver hears "“lecture.vtt” beside the audio wasn't attached:" and the reason.
- For several files: "These transcript files beside the audio weren't attached: “03.vtt”, “07.vtt”, and “09.srt”.
  The debug log says why."
  At most five are named, then how many more.
- A file read from this Mac may be up to 20 MB.

### Where a transcript came from
<!-- id: where-transcript-came-from; keys: TranscriptSource, provenance, Book Info, Book Information; src: TextMouth/Models/TranscriptionWording.swift, TextMouth/ViewModels/TranscriptBookInfoModel.swift -->

- Book Information has a read-only detail named Transcript, which says where the book's transcript came from and when.
  VoiceOver reads it as "Transcript: " and the line.
- Made by recognition: "Transcribed on DATE, in English (United States)."
- Attached: "Attached from “lecture.vtt” on DATE."
  With several files, or a file whose name isn't known, it says "Attached from a WebVTT file on …" or "Attached from a file on …".
- Found at import: "Attached from “lecture.vtt” when the book was imported, on DATE."
- Found at import in files of more than one format, such as 01.vtt beside the first track and 02.srt beside the second: "Attached from WebVTT and SubRip files when the book was imported, on DATE."
- A podcast's own: "The podcast's own transcript, downloaded with the episode on DATE."
- If you edited it or cleaned it up, the line goes on with "You edited it on …" and "You cleaned it up on …".
- A transcript only in the cloud: "The transcript is only in the cloud.
  Its details appear once the book is downloaded."
  Nothing is downloaded to say it.
- The Retranscribe Audio… sheet names a transcript from a file in the same words and adds "Transcribing again replaces this transcript."

### Podcast transcripts
<!-- id: podcast-transcripts; keys: Podcasting 2.0, episode download, chapters; src: TextMouth/Parsers/PodcastTranscriptReader.swift, TextMouth/Models/TranscriptionWording.swift -->

- A podcast episode brings its own transcript and chapters when it downloads (see [Podcasts and article feeds](feed-listening-and-settings.md)).
- Downloading an episode again replaces its own transcript with the new one, unless you made or changed the transcript yourself.
