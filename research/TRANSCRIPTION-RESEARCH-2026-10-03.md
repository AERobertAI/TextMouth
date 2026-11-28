# Transcribing audio with Apple's on-device speech APIs

Research for the October 3 request: "I would also want a transcripting feature eventually, look if Apple / Swift has an API for to solve the same problem as I think the PDF OCR transcription without a huge speech to text model". It draws on the code on main (a0bad26), the macOS 26.0 SDK in Xcode 26.0.1, Apple's documentation, and a prototype measured on this Mac (a Mac15,12: Apple M3, 8 cores, 8 GB, macOS 26.3.1). The prototype used only the DAISY audio books in the repository's TestData. It played nothing aloud, asked for no permission, and downloaded nothing. Bracketed numbers cite the sources at the end.

## Summary

- **Apple has the speech counterpart of Vision's OCR.** In macOS 26, SpeechAnalyzer with its SpeechTranscriber module transcribes audio files on the Mac. The model is a system asset that macOS downloads, updates, and shares between apps [1][4][7], so it adds nothing to TextMouth's size and runs outside its memory [7]. The English model is already on this Mac (139 MB).
- **Measured here:** 77.5 minutes of narration at about 64 seconds of audio per second, so an hour takes about a minute. The text came back punctuated, every word timed, and 8 to 11 words in 100 differed from the books' own text.
- **No permission prompt:** SpeechAnalyzer needs no authorization [8]. The prototype ran without one, even when built with no Info.plist at all.
- **macOS 14 and 15** have only SFSpeechRecognizer, on the device with the older dictation model, after a permission prompt. TextMouth's ad-hoc signing would bring that prompt back after every new build [12][13].
- **Recommendation: option B.** Keep the transcript in the audiobook's package and show it as the book's text while it plays, so the cursor, VoiceOver, and the braille display follow the narration, and Search in Book finds words in the audio. Start on macOS 26 only, with a job you start yourself that has progress, Cancel, and resume, and that runs and reports the way PDF text recognition does.

## 1. The two APIs

### SFSpeechRecognizer (macOS 10.15 and later)

- **What it does:** an SFSpeechURLRecognitionRequest names an audio file. Results arrive in a handler, and the final result's best transcription lists segments: a word or short phrase each, with its timestamp, duration, confidence, and alternatives [9][10][14].
- **On the device:** requiresOnDeviceRecognition keeps the audio on the Mac. It is honoured only when the recognizer's supportsOnDeviceRecognition is true (it is for en-US here), and Apple warns that on-device requests "won't be as accurate" [10][14].
- **Options:** addsPunctuation (macOS 13), contextualStrings (up to 100 short phrases), a custom language model (macOS 14), and a task hint [14].
- **Limits:** the one-minute limit and the daily request limits belong to the network service. "With on-device recognition, these limits do not apply" [11][14].
- **Languages:** 63 locales here, fewer of them on the device [11], and those depend on the dictation and Siri languages the user has turned on [7].
- **Threading:** handlers run on the main queue unless the recognizer's queue is set to another [14].
- **Permission:** the app must call requestAuthorization, which shows a system prompt with its NSSpeechRecognitionUsageDescription text. Without that key the app crashes [8][14].

### SpeechAnalyzer with SpeechTranscriber (macOS 26 and later)

- **Shape:** a SpeechAnalyzer actor runs modules. SpeechTranscriber is the new model, built for long-form and distant audio such as lectures and meetings [7]; DictationTranscriber is the model that on-device SFSpeechRecognizer uses; and SpeechDetector finds where speech is [1][2][3][14]. Each module delivers its results as an AsyncSequence.
- **Hardware:** SpeechTranscriber.isAvailable says whether this Mac can run the new model (it can). Apple suggests DictationTranscriber where it can't [2][3].
- **Languages:** SpeechTranscriber supports 30 locales here: German, English in 9 regions, Spanish, French, Italian, Japanese, Korean, Portuguese, Cantonese, and Chinese. DictationTranscriber supports 43.
- **Models:** AssetInventory reserves locales for the app (up to 5 here), downloads a model with a Progress, and releases it. Models persist, update, and are shared with other apps [4].
- **Results:** each result covers a stretch of the audio and carries an AttributedString whose runs hold an audioTimeRange and, when asked for, a transcriptionConfidence [7][14]. Volatile results are early guesses that later results replace [7]; a file needs only final results.
- **Presets,** as the SDK defines them: transcription adds nothing, progressiveTranscription adds volatile and fast results, and the time-indexed presets add audioTimeRange [14]. The prototype asked for time ranges and confidence, without volatile results.
- **Input:** analyzeSequence(from:) takes an AVAudioFile and converts it itself; it read the MP3 and AAC fixtures directly. Buffers must already match a format the modules accept, since the analyzer "does not transparently upsample, downsample, or convert audio input" [5]. Here that is 16 kHz mono 16-bit, made with AVAudioConverter.
- **Newer than this SDK:** macOS 27 adds AnalyzerInputConverter and AssetInputSequenceProvider for that conversion, and an option to exceed the limit on simultaneous analyses [6]. Apple's pages already show them; the macOS 26.0 SDK has none of them.
- **Control:** prepareToAnalyze loads the model ahead, finalizeAndFinish(through:) ends the input, cancelAndFinishNow() stops, and Options set the priority and how long the model stays loaded [1].

### Permission, sandbox, and signing

- **SpeechAnalyzer:** Apple says the permission process "only applies to speech recognition using SFSpeechRecognizer", and that SpeechAnalyzer's transcribers don't send audio to Apple's servers [8].
- **SFSpeechRecognizer:** macOS records the answer against the app's designated requirement, and an ad-hoc signature's requirement is "tied to that specific version of the code" [12]. TextMouth is ad-hoc signed (CODE_SIGN_IDENTITY "-", confirmed on the installed copy), so each `make install` of a new build would ask again [13].
- **Sandbox:** TextMouth isn't sandboxed (com.apple.security.app-sandbox is false in TextMouth/Resources/TextMouth.entitlements). Privacy prompts are a separate, mandatory mechanism that applies either way [13]. Transcribing files needs no entitlement; a sandboxed app would also need read access to each file.
- **Info.plist:** TextMouth's holds NSAppleEventsUsageDescription and no speech key. Only the SFSpeechRecognizer path would need NSSpeechRecognitionUsageDescription.

### Choosing at run time

- The app targets macOS 14.0 (project.yml) and builds with the macOS 26.0 SDK, so the macOS 26 types sit behind `if #available(macOS 26.0, *)`.
- **On macOS 26:** SpeechTranscriber when isAvailable and the locale is supported, otherwise DictationTranscriber. Neither needs permission.
- **On macOS 14 and 15:** SFSpeechRecognizer with requiresOnDeviceRecognition, when supportsOnDeviceRecognition is true, after the prompt. Otherwise the command says that transcription needs macOS 26.
- **Never Apple's servers:** a book's audio stays on the Mac.

## 2. The prototype on this Mac

### What was run

- **TranscribeProbe,** a Swift command-line program compiled with swiftc in the Swift 6 language mode the app uses, kept outside the repository in this session's scratchpad. It reports what the Mac offers, transcribes files, resumes part-way, and cancels. It never opens the microphone or plays audio.
- **Fixtures:** the two DAISY audio ZIPs in TestData, extracted to the scratchpad. Git doesn't track them, so only the main checkout has them.
  - Fire Safety, DAISY 2.02: 51 MP3 files, 26.2 minutes, mono 22,050 Hz, read by a person ("Read by Tony Porter", says the recording).
  - Are You Ready, DAISY 3: 35 MP3 files, 51.3 minutes, the same format, synthetic Indian English speech made by TPB Narrator in 2009.
  - Both are full-text books: their SMIL files link each phrase of the text to a stretch of audio, which gave a reference to score against.
- **Settings:** the en-US locale; en-AU on Fire Safety scored the same. Other agents' builds kept the load average between 2 and 7 on 8 cores, so the speeds are conservative.

### What the Mac offers

- **Installed:** SpeechTranscriber.isAvailable is true, and installedLocales lists all 9 English locales. One model serves them: com.apple.speech.asr.transcription.en, version 3100.4000.29, 139 MB in /System/Library/AssetsV2.
- **Best input:** 16 kHz mono 16-bit integers; 8 kHz is also accepted.
- **Status:** AssetInventory.status said "supported", not "installed", for the probe all along, and assetInstallationRequest returned a request, yet the installed model transcribed everything. Probably an update is waiting: the system's asset catalog lists version 3100.50007.81507, a 138,412,032-byte download (206 MB unpacked). The probe never called downloadAndInstall. Its request reserved en_US, which it released afterwards.
- **No prompt:** SpeechTranscriber ran in a plain command-line tool, with no app bundle and no prompt, and in a second build with no Info.plist at all, so it needs no app around it.
- **SFSpeechRecognizer:** authorizationStatus stayed notDetermined, since the probe never asked, so its path didn't run. DictationTranscriber, which uses the same model [3], stood in.

### Speed

- **Books:** Fire Safety took 24.0 seconds (65.5 seconds of audio per second) and Are You Ready 48.6 (63.3). Together, an hour of audio took about 56 seconds.
- **Long files:** the longest file, 6.4 minutes, ran at 68.2, and an AAC copy of a file, in M4A, at 68.7. Speed doesn't fall with length.
- **Start-up:** loading the model took 3.5 to 6.6 seconds per process, and about 3 milliseconds once kept loaded.
- **Results:** the first came a median 0.07 seconds after the audio was handed over, then one per sentence (a median 4.2 seconds of audio, at most 20.8).
- **Where the work runs:** a system service, localspeechrecognition, starts on demand and quits afterwards. It peaked at 579 MB on Fire Safety and 627 MB on Are You Ready and kept about 1.6 cores busy, while the probe itself never held more than 22 MB.
- **DictationTranscriber:** 23.9 seconds of audio per second on Fire Safety, peaking at 427 MB.

### Accuracy

- **Word error rate** against each book's text (lower case, no punctuation, numerals spelled out): 7.5% for the person (3,593 words) and 11.3% for the synthetic voice (6,717 words).
- **Prose only:** counting only prose phrases, matched by the SMIL's time windows, gives 8.3% and 10.5%. DictationTranscriber scored 9.2% on Fire Safety.
- **Real errors:** names ("Blaxland" as "Blacksland", "Neosporin" as "Neostoran"), small words ("are" as "were"), and splits ("alight" as "a light", "store bought" as "store, dog").
- **Counted, but not errors:** page numbers the narrator skips, words the narration has and the reference lacks (the credit, image descriptions, list numbers), and typos in the books themselves.
- **Confidence:** on the longest file the median word scored 0.96, and 7.5% of words scored under 0.5.

### Timing

- **Words:** each is timed in 60-millisecond steps. SpeechTranscriber's words are contiguous: each starts where the one before ended, so a pause belongs to the word after it, while each word ends where it is spoken.
- **Against the SMIL:** a phrase's first word started a median 0.10 seconds before the SMIL's start for that phrase in Fire Safety (half within 0.26 seconds, 90% within 1.08) and 0.27 before for Are You Ready (half within 0.57, 90% within 1.08). That is close enough for a cursor to follow sentences and words.
- **DictationTranscriber** leaves pauses as gaps, but 19 of its time ranges, beside 3,707 good ones, were not numbers, so code must check CMTimeRange's isValid and isNumeric.

### Resume, cancel, and Swift 6

- **Buffers:** resuming 50 seconds into a 100-second file, with converted buffers and a bufferStartTime, kept the file's times. Of the 135 words the whole-file run found after that point, 134 matched, their starts a median 0.02 seconds apart and at most 0.26.
- **File input:** setting an AVAudioFile's framePosition before analyzeSequence(from:) resumes too, but the times then count from that point, so the app adds the offset.
- **Cancel:** cancelAndFinishNow() returned at once, and the results ended with a CancellationError within 2 milliseconds.
- **Swift 6:** the file path compiled with no warnings. AVAudioConverter's input block is @Sendable in Swift 6, and capturing the buffer drew four concurrency warnings, which would fail `make check`. Reading the file directly, with an offset, avoids them.

## 3. How the PDF reader runs text recognition (T09)

- **When it runs:** OCR is part of extracting a PDF's text (PDFTextParser.extract), page by page in an autoreleasepool. That happens when an import reads the book, when the text cache batch or Redo Text Extraction rebuilds content.md, and when a reader opens a PDF whose content.md is missing or outdated. It never runs on the main thread, and imports and the batch run it inside StorageBoundary.perform.
- **The seam:** VisionPDFTextRecognizer conforms to PDFPageTextRecognizer, and tests replace PDFTextParser.defaultRecognizer, held under a lock, with a fake. OCRSession stops asking once Vision proves unavailable.
- **The report:** PDFExtractionDiagnostics says how each page was read, and ExtractionReport makes one sentence of it. An import presents it as a warning and keeps the original, a cache rebuild logs it as PDF_INCOMPLETE_CONTENT, and a ZIP import summarizes it.
- **The cache:** recognized text lands in content.md, so OCR runs again only when content.md is rebuilt.
- **What it lacks:** progress within a PDF (the overlay counts books), a Cancel within one (Cancel stops a ZIP import after the book in progress), and a stored page report.
- **For transcription, keep:** a protocol with a fake for tests, one spoken report sentence, the expensive result saved in the package, and nothing done twice.
- **For transcription, change:** it takes minutes rather than seconds, so it is a separate job you start, never part of an import or of maintenance, with progress, Cancel, and resume.

## 4. How it fits TextMouth

### What an audiobook is today

- **Chapters** are whole files, time ranges of one file, or, for DAISY, sections that play a list of clips across files (AudioSegment, kept in manifest.json). contentIndex.json records each chapter's file, start, and duration, and every clip (BookContentAudioChapterIndex).
- **Text** is placeholder spaces, ten per second of audio (ReaderViewModel.audioCharsPerSecond), and 16 places in 7 files convert between the two. So a position or bookmark, a chapter and a character offset, stands for a time.
- **No content.md,** and Search in Book is withheld, since the text is only spacing.
- **DAISY:** an audio import copies only the audio, so the text a full-text DAISY book carries, as both fixtures do, is left behind.
- **Podcasts:** RSS-READER-RESEARCH-2026-10-03.md recommends that each downloaded episode become an ordinary book, and lists transcripts as later work, so an episode would be transcribed as any audiobook is.

### Options

- **A. A new text book made from the transcript,** as New from Text makes one.
  - For: the smallest change; search, braille, and your voices work at once.
  - Against: two books for one work, positions not shared, and no cursor following the narration.
- **B. The transcript as a layer of the audiobook.** The package keeps transcript.json, and while the book plays, the reader shows the transcript around the word being spoken.
  - For: one book; VoiceOver and the braille display can read what the narrator says; Search in Book works for audio, and Where Am I? can quote the sentence being read. Positions and bookmarks stay times, so nothing saved changes when a transcript arrives, is redone, or is deleted.
  - Against: a timeline from chapter time to transcript text, across a section's clips and files, and the changes to display, search, and Where Am I? that use it.
- **C. A synchronized book,** text and audio as equals, as in full-text DAISY books and EPUB 3 Media Overlays.
  - For: it would also keep a full-text DAISY book's text, and let any such book be read by a voice or by its narrator.
  - Against: a new format through import, reader, index, and caches; the largest change, and more than transcripts need.

**Recommendation: B,** with its timeline written so that C can reuse it. A can follow as a small export.

### Storage, sync, and rebuilds

- **transcript.json in the package,** beside contentIndex.json. For each audio file it holds the file's path, size, and modification time; the engine, model version, and locale; and each word with its start and length in milliseconds and its confidence. About 8,100 words an hour come to about 190 KB an hour, compactly, so a 20-hour book needs about 4 MB.
- **A record, not a cache:** a new cache format or Redo Text Extraction never discards it, since recognition takes minutes and models change. Only a changed audio file, or Transcribe Again, replaces it.
- **Derived text:** each chapter's text is cut from the words by the chapter's time ranges, cheaply, so a change in how text is derived never transcribes again.
- **Cloud:** the file syncs with its package, so another Mac, even one without macOS 26, reads the transcript. Transcribing a book only in the cloud downloads it first, as opening it does, and maintenance never transcribes. Each audio file's transcript is written whole, atomically.
- **library.json** gains only whether a book has a transcript, for its row and menus.
- **Logs** must not quote transcripts: no log line may hold book text, as LogContentPolicyTests checks.

### Running a transcription

- **Off the main thread:** a transcription job, an actor, works through a book file by file, one book at a time. Results are gathered on its own tasks, never on the main actor.
- **Storage:** each file's write goes through StorageBoundary.perform. A data-directory move, Rebuild Directory, or folder edit pauses the job, and it carries on afterwards.
- **Progress:** audio done over the book's total, measured at the end of the latest result. A result arrives every few seconds of audio, so it moves smoothly.
- **Cancel:** cancelAndFinishNow() stops at once. Finished files keep their transcripts, and the file in progress is dropped.
- **Resume:** skip finished files. Within a long file, keep its finished sentences and restart after the last one, adding the offset.
- **One at a time:** the system limits simultaneous analyses and throws insufficientResources beyond them [1].

### What you see and hear

- **The command:** Transcribe Audio… in an audiobook's context menu, the Library menu, and the row's VoiceOver actions, then Transcribe Again and Delete Transcript once there is one.
- **A new language:** when its model isn't installed, TextMouth says so, with its size, and downloads it with progress once you agree.
- **Progress, as cloud downloads show it:**
  - A progress bar that VoiceOver moves to, read as "3 of 12 files, 40 percent", with Cancel, which Escape presses.
  - Announcements at the start, each quarter, and the end, as in "Transcribed Fire Safety: 51 files, 26 minutes of audio."
  - The row's note, "Transcribing 40%", spoken as "transcribing, 40 percent", with reading progress spoken as "42 percent read".
- **Problems,** in one spoken sentence as an ExtractionReport gives them: the files not transcribed and why, or "Transcription needs macOS 26."
- **In the reader:** the text area (displayVisibleTextWindow, labelled "Book content") shows the transcript around the current word as the book plays, so VoiceOver and the braille display can read it. While paused it can be selected.

### Searching audio

- **Search in Book** opens for an audiobook with a transcript. A result names its chapter and time, and choosing it moves playback to that word.
- **Across the library:** out of scope for now; the Library's search matches only a book's title and author.

## 5. Risks

1. **Accuracy:** 8 to 11 words in 100 differ on narration, and names and invented words fare worst. Contextual strings (title, author, chapter titles) may help, but that is untested.
2. **Languages:** each language is its own model download, an app may reserve 5, and a book in an unsupported locale gets DictationTranscriber or nothing.
3. **Long books:** a 20-hour book would take about 19 minutes, with the speech service holding about 600 MB on an 8 GB Mac.
4. **Model updates:** transcribing again may change words. Store the model version, and never transcribe again unasked.
5. **Deployment target:** the good path needs macOS 26. macOS 14 and 15 bring a permission prompt that returns after each ad-hoc build, and a model that was slower and less accurate here.
6. **Timing:** pauses fold into the next word, so the cursor can reach a paragraph's first word a second or two early. The dictation model can return invalid ranges.
7. **Swift 6:** AVAudioConverter's @Sendable block draws warnings; reading the file directly avoids it.
8. **Disk:** this Mac's data volume had about 4 GB free during this work, and a language model takes about 140 MB.
9. **Documentation drift:** Apple's pages now describe macOS 27 additions. Code must keep to the macOS 26.0 SDK until the toolchain moves.

## 6. Phases and tests

Tests use speech generated in the test sandbox with AVSpeechSynthesizer.write (rendered to a file, never played) or the DAISY fixtures where a checkout has them, never your library. A test that needs the real model skips below macOS 26, when SpeechTranscriber.isAvailable is false, or when installedLocales lacks the locale; AssetInventory.status is not a reliable sign.

- **Phase 0, spike (done):** this document and the scratchpad prototype.
- **Phase 1, engine and storage, no interface (about 1 week):**
  - A transcriber protocol, a SpeechAnalyzer implementation, and a fake that replays scripted results.
  - transcript.json's model, versioned and compact, with each audio file's fingerprint.
  - The job actor, with progress, Cancel, resume, and atomic writes.
  - Tests: encoding round trips and versions; invalid ranges dropped; progress across many files and within one; Cancel keeping finished files; resume at the right offset; a changed audio file invalidating its transcript; no transcript words in logs; one opt-in test transcribing generated speech, checking its words and rising times.
- **Phase 2, the reader (about 1 week):**
  - The timeline from chapter time to transcript text, for whole files, time ranges, and clip lists.
  - The text area following playback, Search in Book for transcribed audiobooks, and Where Am I? quoting the sentence.
  - Tests: the timeline both ways, at word edges, in pauses, and across a section's clips and files; a search result moving playback; audiobooks without transcripts unchanged.
- **Phase 3, the command and progress (about 1 week):**
  - The menu, context menu, and VoiceOver actions; the language and model download; progress, announcements, and the row's note; refusals while the data directory moves and below macOS 26.
  - Wording built once for the screen and VoiceOver, with CountWording for counts.
  - Tests: wording, announcement milestones, command availability, refusals, and the progress view's accessibility label and value. By hand: VoiceOver and braille on a real book.
- **Phase 4, optional:** a text book from a transcript (A); the macOS 14 and 15 fallback; keeping full-text DAISY books' text on the same timeline (toward C); contextual strings, if they measurably help.

## Open questions for you

1. What should be transcribed first: audiobooks you have, podcast episodes once the RSS reader exists, or recordings?
2. Is macOS 26 alone acceptable? Supporting macOS 14 and 15 brings a permission prompt that returns after every new build of TextMouth, and a slower, less accurate model.
3. While an audiobook plays, should its text follow the narration word by word, sentence by sentence, or only when you ask, with Where Am I?
4. Do you also want a separate text book made from a transcript (option A), to read in your own voice?
5. Which languages do your audiobooks use? English is installed; each other language is a download of about 140 MB, and an app may reserve five.
6. Should TextMouth offer to transcribe after you import an audiobook, or only when you choose Transcribe Audio…?
7. Should transcripts sync with a library in the cloud, at about 200 KB per hour of audio? I'd recommend it.

## What I could not verify

- SFSpeechRecognizer itself, which needs the permission prompt; DictationTranscriber stood in for its model.
- The download size through the API: the installation request's Progress had no total before it started. The size above comes from the system's asset catalog.
- What AssetInventory's "supported" status means for an installed model, and whether downloadAndInstall would download the newer version.
- Whether a command-line tool would get the SFSpeechRecognizer prompt itself or on behalf of the terminal that runs it.
- Whether VoiceOver refreshes the braille display as the text area follows the narration.
- Accuracy on long commercial audiobooks, music beds, other accents, and other languages; and whether contextual strings help SpeechTranscriber.

## Sources

1. SpeechAnalyzer: https://developer.apple.com/documentation/speech/speechanalyzer
2. SpeechTranscriber: https://developer.apple.com/documentation/speech/speechtranscriber and https://developer.apple.com/documentation/speech/speechtranscriber/isavailable
3. DictationTranscriber: https://developer.apple.com/documentation/speech/dictationtranscriber
4. AssetInventory: https://developer.apple.com/documentation/speech/assetinventory
5. bestAvailableAudioFormat(compatibleWith:): https://developer.apple.com/documentation/speech/speechanalyzer/bestavailableaudioformat(compatiblewith:)
6. macOS 27 additions: https://developer.apple.com/documentation/speech/analyzerinputconverter , https://developer.apple.com/documentation/speech/assetinputsequenceprovider , https://developer.apple.com/documentation/speech/speechanalyzer/options/ignoresresourcelimits
7. WWDC25 session 277, Bring advanced speech-to-text to your app with SpeechAnalyzer: https://developer.apple.com/videos/play/wwdc2025/277/
8. Asking Permission to Use Speech Recognition: https://developer.apple.com/documentation/speech/asking-permission-to-use-speech-recognition
9. SFSpeechRecognizer: https://developer.apple.com/documentation/speech/sfspeechrecognizer
10. requiresOnDeviceRecognition and SFTranscriptionSegment: https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition and https://developer.apple.com/documentation/speech/sftranscriptionsegment
11. WWDC19 session 256, Advances in Speech Recognition: https://developer.apple.com/videos/play/wwdc2019/256/
12. TN3127, Inside Code Signing: Requirements: https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
13. Apple Developer Forums, On File System Permissions (Apple DTS): https://developer.apple.com/forums/thread/678819
14. The macOS 26.0 SDK in Xcode 26.0.1: Speech.framework's SFSpeechRecognizer.h, SFSpeechRecognitionRequest.h, SFTranscriptionSegment.h, and Speech.swiftinterface.
