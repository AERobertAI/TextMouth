# Resuming a paused team (November 7, 2026)

Two teams were paused on the night of October 30 to make room for other work, with nothing wrong in them: `team/podcastext` (FMT23, FMT25) and `team/speechexport` (FMT43). On November 7 the user said of the week's remaining usage: "Go crazy, I want to use it all." So the orchestrator is finishing them. The user gave their answers on these features long ago, in the question lists the old briefs cite. You are a fresh lead, and nothing from the old session carries over but the code and the brief.

## What's changed since

The old brief's rules on builds and worktrees are out of date. These hold instead:
- `Scripts/agents/briefs/2026-11-06/common.md`, and `Scripts/agents/briefs/2026-11-04/readers-common.md` as it says, for builds, tests, the board, and the rules. There are no build slots now: `make typecheck-*` takes a machine-wide lock, and tests go through the build train.
- Main has moved about 800 commits, to version 0.4.0 and beyond. The readers, exports, the Library's views, and `AGENTS.md` are all newer. Read what you touch again, because the old brief's picture of the code may be stale.

## What to do

1. Read your team's old brief, `Scripts/agents/briefs/2026-10-30/team-<name>.md`, for what the feature is and what the user answered. Read the worker branches named below, and `git log` for how far each got.
2. Make your branch from the team branch and merge `main` into it. Merge the workers' branches that aren't in it yet. Resolve conflicts with care, keep each worker's tests, and don't guess at what a conflict meant: read both sides.
3. Finish the feature as the brief describes, with your own workers if the rest of it splits well: use `model: "sonnet"` and `effort: "high"` for workers. Work in small commits, each with tests. Every first review here has found blockers, usually where a test passes for the wrong reason, so prove your tests by breaking the code on purpose in a throwaway copy, never on the train.
4. Send it through the train with the classes it can break, and check `make typecheck-mac` and `make typecheck-ios`.

An outside Opus review follows your report, and you don't merge into main.

## Rules that have tightened tonight

- **Nobody deletes anything tonight.** No `rm` at all, not even with a relative name, and no deleting from scripts. A prompt about an `rm` woke the user and stopped things. Overwrite files in a fixed folder instead, and the orchestrator clears scratch folders at the end. Git branches you made yourself are fine to leave in place.
- **Keep shell commands plain.** Nested `${...}`, a substitution in a redirect, or a long chain can stop at a permission prompt only the user can answer. Use a small Python script run with `python3 -I -B` for anything fancy.
- **Disk is tight.** Keep each agent's scratch under 500 MB.
- **Never read, stat, or copy the user's live library:** `~/.TextMouth`, anything under `~/Library/CloudStorage/`, or any data directory the settings name.
- No test may trap, hang, play sound aloud, or use a microphone. Every wait has a limit. Never play, probe, or decode Ogg through Apple's frameworks in-process.
- Never push, never `make install`, and never merge into main.
- Put all of these, word for word, in every prompt you write.

## Your report

Your final message is your report, saved also at `build/orchestrator/followups1105/<name>-report.md` in the main checkout if that write is allowed. Give the branch, each part's commits, the train's and type-checks' results, what a person now gets, what isn't done, what you couldn't verify, any question for the user with your recommendation, and the documentation each change needs, page by page.
