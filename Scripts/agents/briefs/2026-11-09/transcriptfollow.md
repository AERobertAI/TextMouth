# Transcripts, podcasts, and spoken-audio export: their follow-ups (November 9, 2026)

You are `transcriptfollow`, a Sonnet worker, on branch `fix/transcript-followups`. First read `common.md` beside this file and follow it exactly: it says how to start, check, and report.

Two features merged on November 8, in 0.4.2:
- transcripts that come with podcasts and audiobooks (FMT23, FMT25);
- spoken-audio export (FMT43).

Their merge entries in `TODO-2026-09-04.md` list follow-ups, and the small, real ones are your work.

## Read first

- The TODO entries "Transcripts that come with podcasts and audiobooks (FMT23, FMT25)" and "Spoken-audio export (FMT43)", with their follow-ups.
- In the main checkout's `build/orchestrator/followups1105/`:
  - `podcast-review.md` and `podcastcheck-report.md`, where the items below come from;
  - `speechexport-review.md` and `speechcheck-report.md`.

## The work, in this order

Each item gets a test that fails without its fix. If time runs short, stop after a finished item and list the rest in your report.

1. **"Touched" isn't fully pinned.** In `TextMouth/Services/DuplicateReplacement.swift`, removing `|| transcript.cleanedUp != nil` from the `isTouched:` argument of `givesWayToABroughtTranscript` passes the tests. Add the test that fails.
2. **The refusal to transcribe while attaching** checks one-book requests only. Make every request check it.
3. **One cue's text has no limit.** Cap it, with a sentence where a cue is cut, and keep a hostile file's cost bounded.
4. **Cue times past 100 hours** can't be read back by Attach Transcript…. Read them.
5. **Main-thread file work.** Removing episodes reads each transcript.json on the main thread (about 70 ms for 16 MB, once per unopened episode). `TranscriptAttachments.startingFolder` checks its folder on the main thread too, which can stall on a cloud drive. Move both off it.
6. **Reverting an edited episode** to its original take loses the podcast's chapters. Keep them.
7. **01.vtt beside 02.srt** records one format for both. Record each track's own.
8. **A .vtt chosen with its audio** in the import panel is refused as a book. Attach it to that audio, as a .vtt beside it would be, or else say in the refusal how to attach it. Report which.
9. **A quit during a transcript's fetch** downloads the episode again at the next launch. Fix it if the fix stays inside the fetch. Otherwise report why not.
10. **A second quit during an export** replies to AppKit twice, as `QuitHold` does for all held work. Fix it once in the shared quit path, with a test, for every kind of held work.
11. **Spoken-audio export's two silence guards** (the review's B1) do the same job. Keep one, and show that its tests still fail when it is broken.

## Checks

- One train for the batch, with the areas of `Scripts/test/areas.conf` that hold the transcript, feed, import, export, and speech-export classes, and every class your change could touch.
- No test plays sound or uses a microphone. A test that needs speech renders to a buffer or uses a fake synthesizer, as the spoken-audio export's tests do.
