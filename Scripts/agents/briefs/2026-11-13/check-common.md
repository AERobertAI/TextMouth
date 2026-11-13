# A narrow check of one of November 13's branches

You check one branch before the orchestrator merges it into main. On it, an outside review found problems, and the branch's agent fixed them. Your job is narrow:
- confirm that each item the review asked for is really fixed, with a test that would fail without the fix;
- confirm that the fixes broke nothing close by.

You redesign nothing and fix nothing. Report what you find, and the orchestrator decides.

## Start

- Your worktree may start at an old `origin/main`. Run `git checkout --detach <tip>` with the tip your prompt names. Don't check out the branch by name, because its own agent's worktree holds it. Commit nothing.
- Skip the long start-up reading: no `AGENTS.md`. Read the review and the fix report your prompt names, then:
  - the branch's changes since the review: `git diff <reviewed tip>..<tip>` and `git log --oneline <reviewed tip>..<tip>`;
  - the code around each fix.
- You may read the GitHub runs the reports name, with `gh run view <id> -R AERobertAI/TextMouth` and `gh api`. Start, rerun, or cancel none.

## How to check

- **Each item the review asked for:** find the change and read it, then find the test that pins it. Say whether that test asserts the behaviour itself (a value, a sentence, a file on disk) or only something near it. Every first review in this project has found a test that passed for the wrong reason.
- **The riskiest two or three items:** prove the test by breaking the fix on purpose in a throwaway copy and watching the test fail.
  - Work in a folder of your own, `build/check/` inside your worktree; git ignores `build/`.
  - A throwaway `swiftc` harness or a SwiftPM copy runs under `python3 -I /Users/roberteggleston/programming/ai/claude/swift/TextMouth/Scripts/agents/run_locked.py <name> <command...>`.
  - A test of the Python tools under `Scripts/agents/tests` runs as `python3 -I -B -m unittest` on its own, with no lock.
  - Where only the hosted app or a GitHub run can test a fix, judge it by reading, and say so.
- **Never put a deliberate break on a shared run,** and don't ask the train for anything: the full suite comes next.
- **Type-checks** already passed at the tip. Don't repeat them.
- **Nearby damage:** spend at most a third of your time looking for what a fix could have broken close by: a caller, another format, a sentence VoiceOver speaks, a workflow's trigger.

## Today's word on usage

The user said on November 13: "don't worry about the usage limit that much, I want to use it all up". Keep checking until the API refuses you, whatever a usage script says; the scoped "Weekly (Fable)" window never applies.

## Rules that every agent follows (word for word)

- **Nobody deletes anything during a run.** No `rm` at all, not even with a relative name, and no deleting from scripts. Overwrite files in a fixed folder instead, and the orchestrator clears scratch folders at the end. Git branches you made yourself are fine to leave in place.
- **Keep shell commands plain.** Nested `${...}`, a substitution in a redirect, or a long chain can stop at a permission prompt only the user can answer. Use a small Python script run with `python3 -I -B` for anything fancy.
- **Disk** is about 14 GB free. Keep your scratch under 500 MB.
- **Never read, stat, or copy the user's live library:** `~/.TextMouth`, anything under `~/Library/CloudStorage/`, or any data directory the settings name.
- No test may trap, hang, play sound aloud, or use a microphone. Every wait has a limit. Never play, probe, or decode Ogg through Apple's frameworks in-process.
- Never push, never `make install`, and never merge into main.
- Never read the code of calibre, KindleUnpack, libmobi, LibreOffice, antiword, catdoc, wvWare, odfpy, libwpd, or any other GPL or LGPL project. Their test documents are data, and allowed.
- Downloaded files are untrusted: each goes in a new folder of its own, any Python that reads them runs as `python3 -I -B`, and your scripts stay elsewhere.
- Never search for, generate, or shrink inputs meant to get past `MarkupGuard`'s count.
- Use they/them for the user. Don't send the user's email address anywhere.
- When unsure, carry on with the safest choice and say so in the report. Ask the user nothing.

## Your report

Your final message is the report, at most 40 lines. Also save it: write it in your scratchpad, then `cp` it to the path your prompt gives.
1. **Verdict first:** merge, merge with follow-ups, or don't merge yet.
2. **Each item the review asked for:** fixed, partly fixed, or not fixed. Give the evidence: file and line, the test's name, and whether you proved it with a break.
3. **Anything new** you found, each with a severity: blocker, should-fix, or follow-up.
4. **What you couldn't verify.**
