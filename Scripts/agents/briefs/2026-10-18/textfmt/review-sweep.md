# textfmt-rvsweep: textutil's leftovers after a crash or a force quit (review item 11)

Slug `textfmt-rvsweep`, branch `textfmt/rvsweep` from `team/textfmt`. Read `Scripts/agents/briefs/2026-10-18/textfmt/shared.md` first, then `TextMouth/Services/OrphanedConversionSweep.swift` whole.

## Why

When TextMouth is force-quit or crashes while textutil runs, three things can be left: an orphaned `/usr/bin/textutil` process (the reaper normally kills it, but not if the reaper itself is killed), a `TextMouth-textutil-<UUID>` working folder in the temporary directory (`TextutilDocumentReader.withWorkingFolder`), and its hidden `.<UUID>.textutil.html` output. Nothing sweeps them. `OrphanedConversionSweep` already runs at launch for afconvert's orphans, and team audiofmt, which owns that file, agreed that we extend it **with new functions only**: leave `converterPath`, `isTemporaryOutputName`, and `shouldKill` exactly as they are (audiofmt changes them on its own branch), and touch nothing else of theirs.

## What to do

1. **Orphaned textutil.** New functions beside the afconvert ones: `/usr/bin/textutil`, run by the current user, an orphan (parent pid 1), whose `-output` argument's last path component is hidden (starts with ".") and ends with `TextutilConverter.temporarySuffix`, with something before it. Only such a process is killed; one whose parent lives, or another user's or app's, never is. Reuse `ProcessSnapshot`, `runningProcesses()`, and `snapshot(of:)` as they are.
2. **Stale working folders.** A new function removes, from a root that tests can replace (the temporary directory by default), each folder named `TextMouth-textutil-` followed by a UUID whose modification time is more than one hour old, so a conversion running in this process (textutil's limit is at most 30 s plus 1 s per MB, 94 s at 64 MB) is never swept; nothing else in the root is touched. Count what was removed.
3. **Run both at launch** where the afconvert sweep runs (find the call of `sweepInBackground`), in the background, and log one line when something was swept, in the file's style (a new log tag: say it in your report; run `LogContentPolicyTests`).

## Tests (a new class `TextutilLeftoverSweepTests`)

The kill rule on snapshots (as the afconvert rule's tests do: find them): textutil orphan with a TextMouth output name is killed; with a parent, another user, a non-hidden name, another suffix, or another program, it is not. The folder sweep in a sandbox root: an old `TextMouth-textutil-<UUID>` folder is removed, a fresh one, an old folder with another name, and an old file named like the folder are kept. Never kill a real process in a test, and never sweep the real temporary directory in a test.

Run `TextutilLeftoverSweepTests`, the afconvert sweep's tests, `LogContentPolicyTests`, and `UncheckedConcurrencyPolicyTests`.
