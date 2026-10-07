# Task brief: reviewspeech and reviewlibrary — read-only review of the five October 7 afternoon merges

Two reviewers share this brief; each takes its own merges. You are read-only: **edit no file, make no commit, run no build or test, post nothing on the board.** Your report goes to the orchestrator, who verifies each finding and briefs the fixes.

## Why
On October 7 the orchestrator merged five branches on their agents' reports and green suites without reading every line, since the usage limit was near. The TODO's "Start here (next session)" list puts this review first. Main's code is the merged state (`1059a8ed`; the commits after it touch only Markdown and briefs).

## Your merges
Read each merge's diff against its first parent (`git diff <merge>^1 <merge>`), and the branch's commits (`git log --reverse <merge>^1..<merge>^2`), then the surrounding code the diff relies on. The agents' own reports, with what they left unverified and their decisions, are in `AGENT-NOTES-2026-10-04.md` under "Agent notes, October 7, 2026"; their briefs are in `Scripts/agents/briefs/2026-10-07/`.
- **reviewspeech**: `aec5c91b` fix/speech-markup-guard (B01: `SpeechMarkupGuard`, `SpeechService` replacing its synthesizer and retrying, `AudioEngineService`'s `RenderCancellationObserver`, Where Am I's guarded line) and `f5273ba2` fix/airpods-rewind-after-finish (B02: `hasFinishedBook`, `NowPlayingService`, the reader's skip and play paths). Then their interplay: the airpods branch merged after the guard.
- **reviewlibrary**: `1790ae21` feature/unopened-category (FR08), `065ec6a0` feature/hand-edited-metadata-flags (FR06: `Book.HandEdits`, the editors' saves, the launch metadata refresh), and `33219144` feature/speak-info (FR07: `LibraryInfoWording`, `LibraryInfoSpeaker`, `LibraryInfoRow`, the I and Command-I handlers).

## What to look for, in this order
1. **Correctness**: a concrete input or state that gives a wrong result, a crash, a hang, lost or corrupted user data (library.json, bookInfo.json, a hand edit overwritten), a race (main actor versus a queue, a delegate callback after a stop, a stale callback of a replaced synthesizer), an offset or length error (UTF-16 versus characters; surrogate pairs; the guard's same-length promise), a retry that can loop, a state flag that can stick, an announcement that can repeat or never come.
2. **Accessibility**: a value VoiceOver cannot reach, a wording that reads wrong or twice, a key that fires while typing in a field, focus lost.
3. **Tests**: a test that can trap (force unwrap, unguarded subscript, over-fulfilled expectation), play sound, read `~/.TextMouth`, or pass for the wrong reason (asserting a constant against itself, a hosted test that skips everywhere and so pins nothing), and behavior the branch added with no test.
4. **Design and cleanliness**: duplication of an existing helper (DRY is a hard rule here), a comment that says something the code does not do, dead code, a name that misleads.
5. **The agents' claims**: check each claim in its AGENT-NOTES section and its README/ARCHITECTURE wording against the code, and say which are false or inexact (a documentation agent is writing from that wording right now).

## How to report
For each finding: a one-line title; the file and line on main; the severity (`bug`, `risk`, `test-gap`, `cleanup`, `doc-mismatch`); the concrete scenario (inputs or state, then what goes wrong); your confidence (`confirmed` by reading the code paths end to end, or `plausible`); and the smallest fix you would make. Most severe first. Then list what you checked and found sound, briefly, so the orchestrator knows what was covered. No finding is too small to list if it is real; do not pad with style preferences.

## Usage
You run on Opus 5.5. The usage script's "Weekly (Fable)" window does not count your work; ignore it, and read only "5-hour session" and "Weekly (all models)". If either falls below 10% left, stop and report what you have.
