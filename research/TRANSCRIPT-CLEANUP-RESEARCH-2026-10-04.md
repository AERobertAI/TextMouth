# Which words the recognizer gets wrong, and what a cleanup can fix

Research for the October 4 request: "is it possible to go through and see what words are most mistaken by the model (by you or an agent running transcripting on some of the text) and giving an option to experimentally clean up the transcript?" It measures the transcription engine on main, the macOS 26 speech recognizer that TextMouth uses (SpeechTranscriber, English model of macOS 26.3.1), on this Mac (Apple M3, 8 GB), against speech whose text is known. Nothing was downloaded, nothing was played aloud, and no audio went into the repository. The measurement can be run again: section 11.

## Summary

- **Measured:** 4 hours of speech, 38,834 words of known text: a person narrating a DAISY book, a synthetic voice narrating another, and two of the Mac's voices reading eleven chapters of Pride and Prejudice, Frankenstein, and Alice's Adventures in Wonderland.
- **Word error rate:** 6.7% for the person, 10.4% for the DAISY book's synthetic voice, and 4.9% and 3.4% for the Mac's voices Alex and Daniel.
- **The person's errors are hardly mishearings.** Of the 235 word errors on the person's narration, 218 are conventions and names: pages and chapters the narrator announced (34%), numbers written in figures (23%), compounds joined or split (20%), names spelled another way (13%), and spellings. About 11 words in 3,515, 0.3%, were misheard, and 6 more errors came from the book itself: two typos, two of its spellings, and an index letter.
- **Synthetic speech goes wrong differently.** Its voices drew 2 to 10 times as many errors of the misheard kinds as the person (1.0% to 5.0% of words, against 0.5%), mostly small words and words heard as others. Their mistakes are poor evidence for narrated audiobooks, and the specific words wrong rarely matched: of the person's 93 distinct differences, the synthetic voices made at most 9.
- **Confidence flags synthetic mistakes, not the person's.** For the synthetic voices, words heard with a confidence under 0.5 were wrong 22% to 53% of the time. On the person's narration, half of all wrong words, and half of the words truly misheard, had a confidence of 0.95 or more.
- **Spelling follows the transcription language.** Listening in English (United Kingdom), the recognizer wrote British spelling itself: differences in spelling fell from 105 word errors to 26, and the Mac voices' error rates on the three British books fell by 0.1 to 0.5 points.
- **No correction is safe for every book.** 286 corrections were right in every place they applied; only 19 were right in two places or more, and every one was a book's spelling or hyphenation, or a real word misheard in one book ("begged" for "beg", "chase" for "chaise"). Corrections learned from four books and tried on the fifth were right 13 times and wrong 90 times.
- **So TextMouth's own rule list is empty,** and Clean Up Transcript (Experimental)… applies the rules you write: a name the recognizer always spells another way in a series is the case it fits. The rule file comes with worked examples, and every cleanup can be undone.

## 1. What was measured

### Known text

| Source | Read by | Audio | Words | Text |
|---|---|---:|---:|---|
| Fire Safety (DAISY 2.02) | A person, Tony Porter | 26.2 min | 3,515 | The book's own text, through TextMouth's DAISY parser |
| Are You Ready (DAISY 3) | TPB Narrator, synthetic, 2009 | 50.7 min | 6,933 | The same |
| Pride and Prejudice, chapters 1 to 5 | Alex and Daniel | 33.5 and 28.9 min | 5,364 | Project Gutenberg's text (TestData/pride.txt) |
| Frankenstein, letters 1 to 3 and chapter 1 | Alex and Daniel | 28.5 and 25.0 min | 4,586 | The same (TestData/frankenstein.html) |
| Alice's Adventures in Wonderland, chapters 1 and 2 | Alex and Daniel | 25.1 and 21.3 min | 4,243 | The same (TestData/alice.epub) |

- **The synthetic chapters:** their prose without headings (mostly numbers), one paragraph a line, the illustrations' captions and the italics' underscores taken out. AVSpeechSynthesizer.write rendered each chapter whole at the default rate, without playing it, to AAC at 64 kbps and 22,050 Hz [2]. Alex is the Mac's enhanced US English voice and Daniel its compact British one; both rendered 65 to 195 times faster than real time.
- **The engine:** the app's own SystemTranscriptionEngine, in US English, then again in British English (section 7), each file transcribed whole as Transcribe Audio… transcribes it. 4 hours took about 5 minutes, with other agents building meanwhile.
- **The DAISY books' text** includes what their narrators skip or add: page numbers, the credits, the index. Their audio was imported as TextMouth imports an audio DAISY book, and transcribed in the order the book plays its files.

### How a transcript was scored

- **Words** are compared in lower case, without the punctuation at either end, with every apostrophe read as a straight one, and with dashes (—, –, and --) separating words, so "“Bingley.”" matches "bingley" and "I’m" matches "I'm". Runs of punctuation alone are left out.
- **Alignment:** the most words matched in order, as Edit Text lays an edit over a transcript (TranscriptEditAlignment: unique words as anchors, then the longest common subsequence between them). Between two matched words, a stretch of words heard and words written is one difference. A stretch counts its longer side's words as errors: a word heard for a word written is a substitution, a word written but not heard a deletion, and a word heard but not written an insertion.
- **Word error rate:** substitutions, deletions, and insertions over the words written. The October 3 research spelled numbers out before scoring and found 7.5% and 11.3% for the two DAISY books; here figures and words count as different, which the kinds of difference below set apart.

### Kinds of difference

Each difference gets the first kind it fits, in this order:

1. **Passages not in both:** more than 6 words on a side. None was found: the narrators' additions are short.
2. **Pages and chapters announced:** only the words page, chapter, part, section, or contents, with numbers.
3. **Numbers:** a figure, a number word or ordinal, or a roman numeral.
4. **Proper names:** a word with a capital letter that begins no sentence, heard or written.
5. **Hyphenation and compounds:** the same letters joined or split another way: "today" for "to-day", "rabbit hole" for "rabbit-hole".
6. **American and British spelling:** the same word once both are written the American way: "honor" for "honour", "practiced" for "practised".
7. **Archaic words:** "shew", "ancle", and the like.
8. **Homophones:** "there" for "their", from a list of 121 sets.
9. **Small words:** only articles, pronouns, prepositions, conjunctions, and auxiliaries.
10. **Other words:** any other word heard as another.

The first seven are passages, names, and conventions: how a book and the recognizer write the same speech differently. The last three are mishearings.

## 2. Word error rates

| Group | Words | Word error rate | Substitutions | Deletions | Insertions |
|---|---:|---:|---:|---:|---:|
| A person (Fire Safety) | 3,515 | 6.7% | 107 | 50 | 78 |
| TPB Narrator (Are You Ready) | 6,933 | 10.4% | 532 | 70 | 116 |
| Alex | 14,193 | 4.9% | 529 | 80 | 89 |
| Daniel | 14,193 | 3.4% | 362 | 50 | 67 |
| All synthetic speech | 35,319 | 5.4% | 1,423 | 200 | 272 |
| Everything | 38,834 | 5.5% | 1,530 | 250 | 350 |

By book, Alex and Daniel: Pride and Prejudice 5.2% and 3.9%, Frankenstein 5.3% and 2.9%, Alice 4.2% and 3.3%.

## 3. What the differences are

Word errors by kind, with each kind's share of the group's errors:

| Kind | A person | TPB Narrator | Alex | Daniel |
|---|---:|---:|---:|---:|
| Pages and chapters announced | 80 (34.0%) | 3 (0.4%) | 0 | 0 |
| Numbers | 55 (23.4%) | 236 (32.9%) | 102 (14.6%) | 97 (20.3%) |
| Proper names | 30 (12.8%) | 94 (13.1%) | 99 (14.2%) | 100 (20.9%) |
| Hyphenation and compounds | 47 (20.0%) | 35 (4.9%) | 102 (14.6%) | 87 (18.2%) |
| American and British spelling | 6 (2.6%) | 1 (0.1%) | 49 (7.0%) | 55 (11.5%) |
| Archaic words | 0 | 0 | 6 (0.9%) | 3 (0.6%) |
| Homophones | 1 (0.4%) | 6 (0.8%) | 6 (0.9%) | 7 (1.5%) |
| Small words | 6 (2.6%) | 80 (11.1%) | 152 (21.8%) | 39 (8.1%) |
| Other words | 10 (4.3%) | 263 (36.6%) | 182 (26.1%) | 91 (19.0%) |

- **The person's narration** differs from its book mostly where a narrator speaks what a page only shows: "page" before 39 page numbers and "chapter" before 8 chapter numbers in the contents, figures for numbers, "firefighters" for the book's "fire fighters" (12 times), and names (Blaxland, Auscape). Of its 17 other word errors, 6 come from the book: two typos the narrator read right ("delibrately", "childs"), two of its spellings ("Acknowledgements", "barbeque"), and the index's letter "O", heard as "Oh". About 11 were misheard: "were" for "are" twice, "tracks" for "trucks", "stop" for "stops", "grass" for "grassed", "Where" for "Wear", and "a guardrail" for "guard rail".
- **The synthetic voices** add mishearings: TPB Narrator drew 349 word errors of the misheard kinds (5.0% of its words), Alex 340 (2.4%), and Daniel 137 (1.0%). Alex's "a" was heard as "the" 18 times.
- **Matched words written differently,** which are not errors: a word's case differed in 1.8% to 4.8% of matched words, and its ending punctuation in 5.2% to 8.6%.

## 4. The differences found most often

Substitutions, heard first:

| Heard | Written | Times | Where | Kind |
|---|---|---:|---|---|
| bennett | bennet | 42 | Pride and Prejudice | Proper names |
| 1st | first | 33 | All books | Numbers |
| the | a | 22 | Mostly Alex | Small words |
| 2 | two | 20 | All books | Numbers |
| 2nd | second | 13 | Alex and Daniel | Numbers |
| lizzie | lizzy | 13 | Pride and Prejudice | Proper names |
| firefighters | fire fighters | 12 | The person | Hyphenation and compounds |
| and / in | in / and | 11 each | Synthetic voices | Small words |
| honor | honour | 9 | British books | American and British spelling |
| neighborhood | neighbourhood | 8 | Pride and Prejudice | American and British spelling |
| oh | o | 7 | Alice, Pride and Prejudice, Fire Safety | Small words |
| hearst | hurst | 6 | Pride and Prejudice | Proper names |
| behavior | behaviour | 6 | British books | American and British spelling |
| out of the way | out-of-the-way | 5 | Alice | Hyphenation and compounds |

- **Insertions:** "page" (39) and "chapter" (8), both the person's; the others were few, mostly small words, and voices reading a symbol aloud ("asterisk", "comma").
- **Deletions:** small words ("a" 8, "and" 7, "or" 6), and numbers from Fire Safety's contents and index.

## 5. Confidence and mistakes

The recognizer gives each word a confidence from 0 to 1. How often the words in each range were wrong:

| Group | Words under 0.5 | Wrong among them | Words at 0.95 or more | Wrong among them | Wrong words at 0.95 or more |
|---|---:|---:|---:|---:|---:|
| A person | 1.4% | 22.0% | 72.5% | 3.6% | 49.7% |
| TPB Narrator | 6.2% | 53.1% | 56.6% | 1.6% | 9.7% |
| Alex | 2.4% | 29.8% | 70.5% | 1.6% | 24.8% |
| Daniel | 2.0% | 22.1% | 72.8% | 1.3% | 28.8% |

- **On synthetic speech,** a low confidence marks a likely mistake: half of TPB Narrator's words under 0.5 were wrong, and 43% to 55% of the synthetic voices' words in errors of the misheard kinds were under 0.7.
- **On the person's narration it does not:** the recognizer was sure of its conventions (figures, "firefighters"), and of the 10 words it truly misheard and gave a confidence, 5 were at 0.95 or more. A cleanup cannot pick out what to fix by confidence.

## 6. Synthetic speech and a person

The mistakes on synthetic speech do not resemble the person's, and the user's books are narrated by people:

- **In kind:** errors of the misheard kinds were 7% of the person's word errors, and 29% to 49% of the synthetic voices'. Comparing the shares of each kind (passages left out), the person's mix overlaps TPB Narrator's by 49%, Alex's by 52%, and Daniel's by 61%.
- **In words:** of the person's 93 distinct differences, TPB Narrator made 9, Alex 6, and Daniel 5, most of them numbers.
- **So** the synthetic chapters measure the recognizer's conventions well (spelling, compounds, numbers, names, which depend on the text, not the voice), and its mishearings badly: they overstate how often it mishears a narrator, and in other words. One narrator on one 26-minute book is a small sample of people; section 12 says what it leaves open.

## 7. The transcription language and spelling

Transcribing everything again in English (United Kingdom), with the same model:

| Group | US English | UK English | Spelling differences, US | Spelling differences, UK |
|---|---:|---:|---:|---:|
| A person (Fire Safety, British spelling) | 6.7% | 6.7% | 6 | 3 |
| TPB Narrator (Are You Ready, American spelling) | 10.4% | 10.6% | 1 | 13 |
| Alex (three books in British spelling) | 4.9% | 4.6% | 49 | 6 |
| Daniel (the same books) | 3.4% | 3.1% | 55 | 7 |

- **The recognizer spells as its language does:** in UK English it wrote honour, neighbour, travelled, organisations, centre, and colour; in US English, honor, neighbor, traveled, organizations, center, and color.
- **What was left** is the books' own choices: "judgment", "learnt", and the "-ize" of "authorized"; and, for the book in American spelling, the British spelling the UK model now wrote.
- **So** choosing the transcription language that spells as the books do (Settings, Playback, Transcription) does what spelling rules would, with nothing to maintain.

## 8. What a cleanup can and cannot fix

A cleanup replaces words with other words wherever they stand, without hearing the audio. Measured, it:

- **Can fix** what the recognizer writes the same wrong way wherever it hears it, for the books at hand: a name in a series ("Bennett" for "Bennet", 42 times in five chapters read by two voices), a book's own compounds or older spellings ("to-morrow"), or the spelling of another English when the transcription language doesn't match the books.
- **Cannot fix** a word misheard as another real word: the same words are right elsewhere ("were" for "are" is a mistake only where "are" was said). These are most of the true mishearings.
- **Cannot fix** small words dropped or added, sentences ended in other places, or anything only the audio tells apart. Confidence does not single these out on a person's narration (section 5).
- **Should not change** numbers, which the recognizer writes as figures where books spell them out ("1st", "2"). VoiceOver speaks both alike, and a rule would also change the figures books do use.
- **Does not need to fix** most of the person's 6.7%: page announcements, figures, and compounds are not wrong to a listener, and spelling follows the transcription language.

## 9. The rules TextMouth ships

### How they were derived

1. **Candidates:** every substitution of 1 to 3 words a side that was not a passage, a page announcement, a number, or a name, as a whole-word correction from what was heard to what was written: 286 distinct corrections were right everywhere their words were heard, in every recording, within a sentence.
2. **Evidence:** places in the known texts, each counted once however many voices read it. 19 corrections were right in two places or more: 7 were American spellings of British books (behaviour, endeavour, favourable, good-humoured, labour, marvellous, practised), 7 the books' compounds (a light/alight, panhandles/pan handles, forever/for ever, prize-money, rabbit-hole, waistcoat-pocket, daydreams), and 5 real words misheard in one book (begged/beg, chase/chaise, glut/gloves, cry to/cried, billy/Bingley).
3. **Generality:** a correction was kept only if it corrects a mishearing, not a convention only some books follow, and if the words it replaces are not themselves English words, as the Mac's spelling checker knows them in American or British English [3], since English words are right wherever they were meant. Of the 286, 31 replaced words that are no English word ("amultur" for "amateur", "antivistamine" for "antihistamine"); each was found in one place only. **None was kept.**
4. **Held-out check:** to see whether "right in every place measured" carries over to books not measured, corrections that were right in every place of four books were tried on the fifth:

| Book held out | Always right in the other four | Heard in this book | Times right | Times wrong | Wrong, for example |
|---|---:|---:|---:|---:|---|
| Alice | 254 | 7 | 2 | 28 | dog → bought; dull → tall; french → wrench |
| Are You Ready | 189 | 10 | 0 | 17 | neighborhood → neighbourhood; learned → learnt |
| Fire Safety | 276 | 4 | 0 | 5 | onto → on to; lift → loved; reader → rubber |
| Frankenstein | 212 | 6 | 4 | 12 | tomorrow → to-morrow; the land → hand |
| Pride and Prejudice | 246 | 9 | 7 | 28 | amongst → among these; dare say → daresay |

Right 13 times, wrong 90 times: a correction that was always right in some books is mostly wrong in another. In UK English, right 3 times and wrong 89.

### The rule file

- **TextMouth/Resources/transcript-cleanup.json:** format 1, version 1 of October 4, 2026, its rule list empty, an "about" saying why, and two worked examples TextMouth does not apply until they are moved into the rules: "Bennett" to "Bennet" (a name the recognizer wrote in 29 of the 37 places Pride and Prejudice has Bennet, right for that book only), and "neighbor" to "neighbour" inside words (spelling, which the transcription language does better).
- **A rule** has a pattern, a replacement, wholeWord (true unless set), evidence (the places it was right in, 0 for a rule of the user's), and an optional note. Matching ignores case and the kind of apostrophe; a whole-word rule keeps the punctuation around its words and a possessive "'s" after them ("Bennett's" becomes "Bennet's"), and needs nothing but spaces between the words of a pattern of several; the replacement takes the case of the words it replaces (all capitals, a capital first letter, or as written). Rules apply in order.
- **A rule is refused,** with the field named, when its pattern is empty or holds no letter or figure, a whole-word pattern holds a word of punctuation alone, its replacement is empty, its evidence is below 0, or its replacement holds its own pattern, which would change again at every cleanup.
- **Your own copy,** transcript-cleanup.json in the data directory beside substitutions.json, is used instead whenever it is there and usable, and syncs with the library. Edit Rules… makes it from TextMouth's own file the first time and opens it in your default text editor.

## 10. Clean Up Transcript (Experimental)…

- **Where:** beside Transcribe Audio…, for one transcribed audiobook: the library row's context menu and VoiceOver actions, and the reader's Book menu.
- **The sheet:** says what the cleanup is, names the rules (TextMouth's own or your copy, their version and date, and how many), says why a list is empty, and lists what would change: the number of corrections and sentences, then each rule with its count and up to three examples, before and after, each read by VoiceOver as one line. It says when the transcript was last cleaned up, and when you edited it since. Its buttons are Edit Rules…, Undo Cleanup (after a cleanup), Cancel, and Apply. VoiceOver moves to Apply when the rules change something and to Cancel otherwise, then hears the sheet's lines; Return presses Apply and Escape Cancel. Coming back to TextMouth, as after editing the rules, shows what the rules would change then.
- **Apply:** keeps transcript.json as it was beside it, as transcript.json.before-cleanup; rewrites the sentences the rules changed, keeping their times and dropping their words' timings, as an edit in your editor does; records the cleanup in transcript.json (cleanedUp: when, the rules' version, date, and source, and the corrections made); and writes content.md and the transcript's layer of the book's index again from it. Open readers show the cleaned text as the book plays on, and VoiceOver hears "Cleaned up the transcript of Moby-Dick: 23 corrections." Positions and bookmarks are untouched: they count time.
- **Undo Cleanup:** puts back transcript.json.before-cleanup, its text and layer, and removes it. One cleanup can be undone; a second replaces the copy with the transcript it cleaned.
- **Refused, with a sentence:** a transcript changed since the sheet showed it, rules that change nothing, a book being transcribed, a transcript only in the cloud, and audio changed since it was transcribed. A cleanup that fails before it replaces transcript.json leaves the copy beside it as it was.
- **Elsewhere:** Delete Transcript also deletes the copy; the copy is TextMouth's own file, never taken for the book (TextMouthPaths.isTranscriptFile). Your copy of the rules is read as substitutions.json is: one only in the cloud is never read, and TextMouth's own rules stand in until it is on this Mac; one that can't be used is kept beside itself, with the reason in the sheet, and TextMouth's own rules stand in. The debug log's TRANSCRIPT_CLEANUP_RULES, TRANSCRIPT_CLEANED_UP, and TRANSCRIPT_CLEANUP_UNDONE lines give counts and file names, never words.

## 11. Measuring again

- **The test:** TranscriptAccuracyMeasurementTests, which runs only when `TEST_RUNNER_TEXTMOUTH_TRANSCRIPT_MEASUREMENT` names a folder: it measures the DAISY fixtures a checkout keeps and each `audio/<text>--<voice>.m4a` in the folder against `texts/<text>.txt`, keeps each transcript in `transcripts/` (so a second run does not transcribe again), and writes `measurement.md`, the tables of this document, and `differences.json`, every difference with its confidences and context. `TEST_RUNNER_TEXTMOUTH_TRANSCRIPT_MEASUREMENT_LOCALE=en-US,en-GB` measures in each language.
- **The audio:** each chapter's text, one paragraph a line, rendered with AVSpeechSynthesizer.write by a voice such as com.apple.speech.synthesis.voice.Alex and written with AVAudioFile, never played. Keep it outside the repository.
- **The code:** TranscriptAccuracy (in the app, beside the edit alignment it builds on) aligns, sorts, tallies, and derives; its unit tests cover each step on small invented cases.

## 12. What I could not verify

- **People:** one narrator, one 26-minute Australian non-fiction book. Commercial audiobooks, other accents, dialogue, music beds, and fiction read by a person are untested; no LibriVox recording was downloaded.
- **Languages and models:** English only, one model version; a model update may change every number here.
- **The alignment** matches as many words as possible, then counts each stretch's longer side; a full edit-distance alignment can count a few errors fewer.
- **Names:** "a capital letter that begins no sentence" also catches titles (Mr.) and dialogue opened mid-sentence.
- **The cleanup in use:** VoiceOver and the braille display on the sheet by hand; SwiftUI exposes its buttons' labels only to a connected assistive app, so the tests pin the words they come from.

## Sources

1. SpeechTranscriber: https://developer.apple.com/documentation/speech/speechtranscriber
2. AVSpeechSynthesizer write(_:toBufferCallback:): https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer/write(_:tobuffercallback:)
3. NSSpellChecker: https://developer.apple.com/documentation/appkit/nsspellchecker
4. TRANSCRIPTION-RESEARCH-2026-10-03.md, on how TextMouth transcribes, and the DAISY fixtures.
5. Project Gutenberg: Pride and Prejudice (#1342), Frankenstein (#84), Alice's Adventures in Wonderland (#11), as kept in TestData.
