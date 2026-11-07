# Team `speechexport`: a text book, or a range of its headings, exported as audio (FMT43), October 30, 2026

Read `teams-common.md` beside this file first: it is the pattern, the rules, and the report format, and it stands in for AGENTS.md. You are the lead, `speechexport-lead`, on branch `team/speechexport`, made from local `main` by name (`git checkout -b team/speechexport main`; your worktree may start on an older commit).

## What and why
FMT43 in the TODO's formats section, "the user's wish ("giving the option to export part of a text book as audio")": `grep -n "FMT43 —" TODO-2026-09-04.md` in the main checkout (`/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TODO-2026-09-04.md`, gitignored, so read it there, by line). The research is `FORMATS-RESEARCH-2026-10-17.md` section 7.5 (in your worktree), and section 12's questions 17 to 20, which the user answered on October 18:
- **17, the speed:** "put the rate and pitch in the dialog as sliders set to the current rate". So the Export dialog shows a Rate slider and a Pitch slider, each starting at the book's current rate and pitch, and the export sounds as those sliders say. One slider for each, no stepper beside it (the user's rule: a slider beside a stepper is a duplicate control).
- **18, the range:** "headings / chapter ranges, and then I was thinking like timestamp to timestamp". So this build exports the whole book or a range from one heading to another (the current chapter is a range of one); a time range and a selection are a later stage (FMT44), noted as follow-ups.
- **19, resuming:** "Yes, and think about how to optimize this." Finished chapter files are kept while an export runs, so a stopped export resumes at its next chapter; they are deleted when it finishes or is cancelled for good. Think about speed: render chapters in order but encode a finished chapter while the next renders, if that is safe on an 8 GB Mac.
- **20, the licence line:** "yes": one plain line under the audio choices in the Export dialog, with nothing to tick, saying that speech made with the Mac's voices is for personal, non-commercial use under Apple's licence (section 7.5 quotes the licence).

## Read first
- The Export dialog and its model: `TextMouth/Views/Export/`, `TextMouth/ViewModels/BookExportModel.swift`, `TextMouth/Services/BookExportService.swift`, `TextMouth/Services/Export/`, and `docs/user/exporting-books.md` and `docs/architecture/state/exports.md`.
- How the reader makes what it speaks: the reading text (substitution rules, pauses, `SpeechMarkupGuard`), the chunks, the voice, rate, and pitch, and how `AudioEngineService` renders with `AVSpeechSynthesizer.write(_:toBufferCallback:)`: `TextMouth/Services/AudioEngineService.swift`, `SpeechService.swift`, `TextSubstitutionService.swift`, `SpeechMarkupGuard.swift`, `ChapterSpeechCache.swift`, and `docs/architecture/reading-a-book.md`. Reuse the reader's own functions for the reading text, never a copy of them (the project's DRY rule).
- The audio editor's renderer and encoders, which write M4B and M4A with chapters and MP3 with ID3 chapters: `TextMouth/Services/AudioEditing/` and `TextMouth/Services/MP3/`.

## Decisions settled for you
1. Formats in this build: M4B (the default, a chapter per heading), M4A, and MP3 with ID3 chapters.
2. The voice is the book's voice. Personal Voice cannot render to buffers (research 7.5): refuse it with a sentence that says so and names what to choose instead.
3. Before starting: check the free disk space against an estimate (16-bit mono at 22,050 Hz is 44.1 KB a second, before encoding; estimate a chapter's seconds from its words and the rate), and refuse with a sentence if it cannot fit with the app's existing one-gigabyte reserve.
4. Hold a power assertion while exporting, so the Mac does not sleep, released at the end however it ends.
5. Progress is spoken and shown as Export's other kinds show it (chapters done of all, then encoding), and VoiceOver hears it at the same moments as the other exports' progress.
6. Cancel stops the export and keeps the finished chapters for a resume, said in a sentence; the next export of the same book, range, and settings resumes, and any other export first deletes the kept chapters.
7. **No test may sound aloud:** tests render through a fake synthesizer seam that hands back silent or tone buffers, never a real `AVSpeechSynthesizer` writing to the speakers; one opt-in test (behind an environment variable, skipped by default) may use the real synthesizer's `write` with a real voice. Personal Voice is never touched by a test.
8. The temporary chapter files live in TextMouth's own scratch space (`ImportScratchSpace` or the export's own folder), never in the user's library, and are swept on the next launch if the app quit mid-export.

## Order of work (each one or two commits, with tests)
1. The reading text of a range of headings, from the reader's own functions, with tests that it equals what the reader speaks.
2. Rendering a chapter to a PCM CAF through a synthesizer seam (the fake for tests), with the rate and pitch.
3. Encoding and chaptering through the editor's renderer (M4B, M4A, MP3).
4. The export job: disk check, power assertion, progress, cancel, resume, cleanup.
5. The Export dialog's audio choices: format, range (from heading, to heading), Rate and Pitch sliders, the licence line, and every wording; `SettingsTabFitTests`-style fit checks if the dialog grows, and `make lint-a11y`.
Run each worker's touched classes plus the export and playback areas in `Scripts/test/areas.conf`.

## Files
You own the new speech-export files and their tests, and the Export dialog's audio part. Shared files where you add only your own lines: `BookExportModel.swift`, `BookExportService.swift`, the Export views, `AudioEngineService.swift` and `SpeechService.swift` (a seam only, with no change in how the reader plays), `Scripts/test/areas.conf`, `project.pbxproj` (by `xcodegen generate` only). The `bughunt` team reviews playback tonight and may fix bugs in `SpeechService.swift` and `AudioEngineService.swift`: claim each file before a worker edits it, read the claims, and agree on the board first.

## Builds
Five other teams build tonight. Plan, read, and write your briefs first; build only when the disk rule in `teams-common.md` allows, and keep one build folder for the whole team. Waiting for a slot or for disk is normal.

## When you are done
Follow "Finish" in `teams-common.md`: rebase on main, one full suite, report, with every sentence a listener hears and the follow-ups for FMT44 (time ranges, a selection, WAV, AIFF, CAF, Apple Lossless, FLAC).
