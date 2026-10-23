# Charter: team `transcripts` (October 23, 2026)

You are `transcripts-lead`, an Opus lead with Sonnet workers, on `team/transcripts`. TextMouth is a native macOS text-to-speech and audiobook player whose user is blind and reads with VoiceOver and a braille display.

## The request, in the user's words
"tonight I would like you to look at audio transcripts and how there used in audio items, maybe its just the feed but I transcribed episode 378 of Finish it at random and can't find the option to edit transcript which I thought was a thing, also I think there should be a implemented text search feature for transcribed books that searches the transcript and lets the user click on the results to go there Also when exporting every , and . character seems to be escaped in the markdown, not sure if thats entensional. Also call the menu item "retranscribe audio" or similar if there is alreay a transcript... and just have a team investigate the rest of the implementation for bugs and fix any. I want to install the new version with it as stable as you can make it".

The user has not installed 0.2.0 yet, and wants it as stable as it can be made before they do.

## Where things are
- **The user's guide:** `docs/user/transcribing.md` and `docs/user/editing-book-text.md`.
- **The code:**
  - services: `TextMouth/Services/Transcript*.swift` and `Transcription*.swift`;
  - views: `TextMouth/Views/Transcription/`;
  - the command wiring: `TextMouth/Views/Reader/ReaderBookCommands.swift`, `TextMouth/Views/Library/LibraryView.swift`, and `TextMouth/App/MenuCommands.swift`;
  - wording: `TranscriptionWording.swift` and `TranscriptCleanupWording.swift`.
- **The research and decisions:**
  - `TRANSCRIPTION-RESEARCH-2026-10-03.md` and `TRANSCRIPT-CLEANUP-RESEARCH-2026-10-04.md`, which are gitignored, so read them in the main checkout at `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/`;
  - the FR05 (Edit Text for transcribed audiobooks) and FR11 (feeds) items in the TODO, also in the main checkout: `grep -n -E "FR05|FR11" TODO-2026-09-04.md`.

## Items
1. **T1, editing a feed episode's transcript.** Edit Text is withheld for an episode or article in its feed: `ReaderBookCommands.swift` around line 120, `BookTextEditor.canEditText`, and "An episode's or article's transcript, in its feed, is not cleaned up (FR11): only made again or deleted".
   - Find why FR11 decided this, in the TODO and in the questions files under `humanQuestions/` in the main checkout.
   - The user now asks for it, so offer Edit Text for a feed item's transcript, keeping whatever made FR11 cautious. For example, an episode the feed's rules would delete should keep its transcript edits only as long as the episode is kept; say so in the command's help or a sentence the listener hears.
   - If enabling it is unsafe, make the command visible with a sentence that says how to edit, such as "Move to Library first", and report why.
   - Do the same for Clean Up Transcript, or explain why not.
2. **T2, searching a transcript.** A transcribed book needs a search of its transcript that lists the results; activating a result goes there in the audio. A VoiceOver user must be able to:
   - type a word;
   - hear how many results there are;
   - move through them, each read with its time and a few words around it;
   - press Return on one to jump to that place, announced, with Go Back returning.

   First find out what search exists today for text books and audiobooks (the reader's Find, `BookSearchModel`). Extend it, rather than building a second one (DRY). It needs a menu command with a key, which must not duplicate an existing command (check `KeyboardShortcut.swift`).
3. **T3, escaped commas and periods in exports.** An exported transcript's Markdown escapes "," and ".". Find where:
   - in the transcript's text builder (`TranscriptTextBuilder`, `MarkdownLiteral`);
   - in Export's Transcript kind;
   - in content.md generally, since text books' content.md also escapes source text as Markdown literals since cache format 3.0.6.

   Escape only what Markdown needs, in what the export writes. A change to how text books' content.md is generated is a cache-format change, which re-reads the whole library. Do not make that one; describe it in your report, for the 0.2.0 plan. A change to transcribed audiobooks' content.md is safe, since their places count time, but say so and test it.
4. **T4, Retranscribe Audio….** When the book already has a transcript, the command reads "Retranscribe Audio…" everywhere it appears: the menus, the context menu, and VoiceOver's actions. Pin the words in tests.
5. **T5, a bug hunt.** Have a fresh Opus reviewer read the transcription implementation end to end, before or alongside the items: transcribing, the job center, the transcript store, Edit Text's alignment, cleanup, deletion, export, feed episodes, the cloud, and cancelling. Fix what it confirms, with tests. You may launch that reviewer as one of your workers, on Opus.

## How
- **The common rules.** Follow `Scripts/agents/briefs/2026-10-19/teams-common.md`: the board, the build wrapper, tests, worker briefs, and the report's form.
- **Budget.** Tonight's line is 15% of the week left; it is about 24% now. Start no new worker below 17%, and use at most 4 Sonnet workers plus the one Opus reviewer.
- **Disk.** It has about 11 GB free. At most two builds at once, and check for 4 GB before each. Workers delete their build folders as soon as their last run ends.
- **Briefs** settle every type, sentence, label, hint, and test. List the exact-output tests a worker may change.
- **Tests:**
  - none may trap, play a sound, record, or touch `~/.TextMouth` or `UserDefaults.standard`;
  - a hosted accessibility test calls `skipUnlessHostedWindowsExposeAccessibility()` first;
  - transcription tests use the existing stand-ins and fixtures, and never run the real speech model.
- **Your full run.** When everything is integrated, run the full suite once. Name any load-sensitive failure (teams-common lists them), rerun its class alone, and report both.
- **Never** push or merge into main.

## The report
Teams-common's form, plus:
- each item's outcome, with its commits;
- why FR11 withheld editing;
- the escaping's source, and what changed;
- every new sentence, label, hint, value, and key a listener hears;
- the README and TODO sentences;
- anything for the 0.2.0 plan, such as format changes you did not make.
