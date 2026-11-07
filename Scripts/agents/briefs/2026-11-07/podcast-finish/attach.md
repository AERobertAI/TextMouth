# Worker `pf-attach`: Attach Transcript… and the pairing at import, reviewed

Slug `pf-attach`, branch `podcast/attach-proof`. Read `common.md` beside this brief first.

## Your files

`TextMouth/Services/OutsideTranscript.swift`, `TextMouth/Services/TranscriptPairing.swift`, `TextMouth/ViewModels/TranscriptAttachments.swift`, the attach parts of `TextMouth/Views/Transcription/TranscriptionPresentation.swift`, and the branch's changes to `TextMouth/Services/TranscriptInstallation.swift`, `TextMouth/Services/FileImportService.swift`, `TextMouth/ViewModels/TranscriptionOffers.swift`, `TextMouth/ViewModels/TranscriptionSheetModel.swift`, `TextMouth/Views/Reader/ReaderBookCommands.swift`, `TextMouth/App/MenuCommands.swift`, and `TextMouth/Models/TranscriptionWording.swift` (see them with `git diff main...podcast/finish -- <file>`), and the tests `TextMouthProductionTests/OutsideTranscriptTests.swift`, `TranscriptAttachTests.swift`, `TranscriptPairingTests.swift`. See how `TranscriptStore`, `TranscriptTextLoader`, and `TranscribedBooks` take what these write.

Worker `pf-bookinfo` adds a function to `TranscriptionWording.swift`, at its end. Another worker reviews the readers. The lead owns everything under `TextMouth/Services/Feeds/`.

## Check, at least

1. **Does it reach the listener?** Follow each path to what is heard and read, by reading the code: an audiobook of one file with lecture.vtt beside it; a folder of tracks with some tracks' files present; a ZIP (are .vtt and .srt files extracted at all, and where, when `publishTracks` looks in `audioDirectory`?); a playlist (paths through subfolders); a DAISY or other package; a book whose audio is converted at import (`lecture.ogg` to `lecture.m4a`, without decoding Ogg). The reader's text, Search in Book, follow along, Edit Text, Where Am I, Delete Transcript, Retranscribe Audio…, Clean Up Transcript, Export: each treats a transcript from outside as a recognized one? `locale` is "und": what does each of them do with it, and with a `model.engine` of "none" (`TranscriptionLanguage.name`, the cleanup's language, the accuracy report)? Is anything spoken that a listener would find strange?
2. **Decision 1:** a transcript from outside replaces nothing silently. An alert names what goes. Its words, its Cancel, Escape, and keyboard path. What the book has when it is `.inCloud`, `.unsupportedVersion`, or `.unusable`. A transcription running or starting at each step.
3. **Decision 6:** a file running past the end. Each track's file in a folder is checked against its track, and Attach's one file against the whole book. How is each sentence past a track's end stored when it lies within the 5-second margin (`checkFits` lets it through, and `TranscriptPairing` does not cut it)? Does anything downstream (the reader's timing, `TranscriptTextBuilder`, `Transcript.validationFailure()`) mishandle a sentence ending after its file's `durationMilliseconds`?
4. **The cut across tracks** (`OutsideTranscript.split`). Rounding: tracks of fractional length. A cue exactly on a boundary, one spanning a boundary (does its text stay whole in one track, as intended? does the time held to the track make the sentence end before it starts?). A zero-length track. Is the sum of `Transcript.milliseconds(duration)` the same timeline the reader and the writers use? Word offsets once a cue is cut.
5. **Pairing's safety.** Symbolic links, folders, named pipes, a path with `..`, a huge file (`TimedTextLimits.localFileBytes`), a very large folder (is anything listed or read that needn't be?), a track named with two dots (`a.b.m4a`: which stem?), a case-insensitive disk, a transcript that lies beside only the 3rd of 10 tracks, two tracks of one stem (`01.mp3`, `01.flac`). A failure of any kind must leave the import as it would have been. The notices: words, and which window hears them.
6. **`TranscriptAttachments`.** Every way out ends the attaching: is any path left with the book dimmed for good (an alert dismissed by the window closing, the presenter released, a `Task` cancelled)? Two windows on one book.
7. **iOS.** `make typecheck-ios` is green, and on the iPhone nothing opens for `chooseTranscriptFile`. Confirm nothing else there can reach `NSOpenPanel` or `import AppKit`.
8. **The tests.** Read them as a skeptic: which pass for the wrong reason? `OutsideTranscript.checkFits`, `split`, and `TranscriptSource` are pure enough to prove by mutation in a harness (see `common.md`).

## Fix what you find

A commit for each fix, with a test that fails without it. Don't change a decision of the team's brief: if one looks wrong, tell the lead.

Run `OutsideTranscriptTests TranscriptAttachTests TranscriptPairingTests KeyboardReachabilityTests` and the `transcripts` area on the train, and the `import` area if you change the import.
