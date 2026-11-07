# Finishing the podcast transcript team: what every worker shares (November 7, 2026)

TextMouth is a native macOS and iOS text-to-speech and audiobook reader. Its user is blind and reads with VoiceOver and braille. The lead is `podcastext-lead2`, on branch `podcast/finish`, which holds a paused team's work on FMT23 and FMT25, merged with main (version 0.4.0 and later):

- **FMT23:** an audiobook takes a transcript from a WebVTT (.vtt) or SubRip (.srt) file instead of being transcribed: a file named as a track, found at import (one file, a folder of tracks, a ZIP, a playlist), or chosen with Book > Attach Transcript…. A transcript exports as either format.
- **FMT25:** a podcast episode's own transcript (WebVTT, Podcasting 2.0 JSON, SubRip) and chapters (Podcasting 2.0 JSON) download with it.

The feature's decisions, which the user approved on October 18, are in `Scripts/agents/briefs/2026-10-30/team-podcastext.md` ("Decisions settled for you"). Read that section. The research is `FORMATS-RESEARCH-2026-10-17.md`, sections 5.4 and 5.5.

This code was written on October 30 and 31 by workers whose reports are lost, and it has had no outside review. Every first review on this project has found blockers, usually where a test passes for the wrong reason. So your job is to find what is wrong, fix it with small commits, and prove the tests.

## Your branch

Your worktree starts at an old commit. Before anything else, in your worktree's root:

    git switch -c <your branch> podcast/finish

Make your branch only from `podcast/finish`, by that name. Use `git -C` nowhere else: run git in your own worktree, with plain commands.

## How to work

- **Read by line range, once.** Put several patterns in one `grep -E`. Make independent calls in one response. A worker's cost is its calls times its context.
- **Small commits.** One logical change each, with its test. Comments on every function and every non-obvious block, saying what and why. Readable before clever. Don't repeat what exists: `grep` first.
- **Each message ends** with: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`
- **Edit no `*.md` file.** Your report names the documentation your change needs, page by page, and the lead's report carries it.
- **A new Swift file** needs the project regenerated: `python3 -I Scripts/agents/regenerate-project.py`, and commit `TextMouth.xcodeproj/project.pbxproj` with the file. Put a new test class in `Scripts/test/areas.conf`, in the area that fits, and check with `python3 Scripts/test/run-area.py --unassigned`.
- **Swift 6 complete concurrency.** No `@unchecked Sendable` and no `nonisolated(unsafe)`: `UncheckedConcurrencyPolicyTests` counts them.
- **The listener.** Every sentence a person can hear is a full, plain sentence, and a test pins it word for word. Every control is keyboard-operable and every value is spoken. Nothing is conveyed by sight alone. No existing wording, label, or hint changes unless your brief says so.
- **A failing existing test** means stop and ask the lead: never weaken, skip, or work around one.
- **Ask nothing of the user.** Ask the lead on the board: `bbs post <slug> --to podcastext-lead2 --tag question --topic "..."`. If you have `SendMessage`, you may send it to `podcastext-lead2`. Carry on with the safest choice meanwhile.

## Proving tests

A test proves something only if it fails when the code is wrong. So for the risky tests, break the code on purpose and see the test fail, **in a throwaway copy, never on the train.**

- **The copy.** Make one folder under the session's scratchpad, named for your slug: `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/6f916f11-568e-4f1a-87f7-9dabb0918bca/scratchpad/<slug>/`. Keep it under 500 MB, because the disk is tight. Overwrite files there instead of deleting them. The orchestrator clears the scratch folders at the end.
- **How.** For pure code (readers, writers, the models), a small SwiftPM package or a `swiftc` harness compiling copies of just the files needed, with the test bodies cut in verbatim. It is much faster than the whole app and stays small. Run every compile and larger run under the Mac's lock:

      python3 -I /Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/followups1105/run_locked.py <slug> <command...>

  Never wrap `make typecheck-*` in that: they take the lock themselves.
- **Code that needs the whole app** (hosted tests of a sheet or a library) cannot be proven this way within the size limit. For those, read each test against the code and say in your report why it would fail if the code were wrong, or say that you could not tell.
- **Report the matrix:** each mutation, and which test noticed it. A mutation nothing notices is a missing test: add one, or say why the change is equivalent.

## Builds and tests

Nobody runs xcodebuild directly.

- **Type-checks,** on committed work, one at a time, in the Bash tool's background mode, never in a loop: `make typecheck-mac` (about 100 seconds) and `make typecheck-ios` (about 2 minutes). Each prints its summary's path. Both must stay at 0 errors and 0 warnings.
- **Tests** go through the build train, which leaves every half hour and pools every agent's branch:

      python3 -I Scripts/agents/build-train.py request --agent <slug> --branch <your branch> --classes <A,B> --areas <x,y>
      python3 -I Scripts/agents/wait-for-result.py --agent <slug>

  Run the second in the Bash tool's background mode; you are told when it ends. Ask for your own classes and those your change can break, never `all`. The areas come from `python3 Scripts/test/run-area.py --list`. New test classes are run by name. A class that holds a test you wrote must have run and passed before you report.
- **Disk.** `df -g /System/Volumes/Data` before a check: below 3 GB free, tell the lead and wait.

## The board

`bbs` means `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree's root. The lead has claimed the feature's files; you claim only yours.
- **Start:** `bbs register <slug> --role "ONE LINE" --branch <your branch> --files <your files and globs>`, then `bbs claims` and `bbs read --last 5`.
- **During:** read `bbs inbox <slug> --unread` before every check and every commit. Post `commit` after each commit: `bbs post <slug> --tag commit --topic "<hash> <subject>"`, at most 200 characters. Post `finding --file <path>` for a problem in a file outside your brief, and leave that file alone.
- **End:** `bbs post <slug> --to podcastext-lead2 --topic "done: <branch>"`, then `bbs release <slug> --all`.

## Your report (your final message)

At most 40 lines. Say first, in one sentence, what you found and what you fixed.
- The branch, and each commit's hash and subject.
- The train's result line, for your classes; the type-checks' result lines.
- Each finding: the file and line, what goes wrong in plain words, how you found it, and what you did. Findings you left: why, and what you recommend.
- The mutation matrix, or where it is.
- What you could not verify. Say so plainly: an untested guess stated as fact costs more than a gap.
- The documentation your change needs, page by page, under `docs/`.
