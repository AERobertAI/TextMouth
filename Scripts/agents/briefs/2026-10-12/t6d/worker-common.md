# Team t6d: what every worker does (October 12, 2026)

Your lead is `t6d-lead`. Your task brief names your slug (`t6d-<task>`), your branch (`t6d/<task>`), and your board task's number. This file adds to "The worker's part" of `teams-common.md` beside it; read that part and its "Rules for everyone", "Builds", and "Keeping the cost down", and nothing else of it.

## What the team is building
T06's branch D: when TextMouth rebuilds a book's text (writes a new content.md), the book's saved places (its reading position, bookmarks, and skipped headings) move from the old text to the new one with `PlaceRelocator`, so the listener's places stay on their words. Moves are silent: nothing is spoken or shown. The design is `TEXT-ANCHORS-ADDENDUM-2026-10-10.md`, section 9; your brief quotes what you need, so you need not read it.

## Every command is a plain command
The worktree guard refuses compound commands. So:
- No `cd … &&`. Use `git -C <your worktree path> …` for git, and absolute paths elsewhere.
- No `$VAR` or `${TMPDIR}` in a command's name or in the build command: write paths out in full.
- Run the board as `python3 .claude/skills/agent-bbs/scripts/bbs.py …` from your worktree root (written `bbs` below), one command at a time.

## Start
1. `git -C <your worktree> checkout -b t6d/<task> team/t6d`
2. `bbs register t6d-<task> --role "ONE LINE" --branch t6d/<task> --files <the files your brief names>`
3. `bbs task move t6d-<task> <task number> working`
4. Read your brief, then the files it names, by the line ranges it gives. Line numbers are those of `main` at 889b10e2 unless the brief says otherwise; an earlier task of this team may have shifted them a little, so find the function by name.

## Build and test
Start every build in the background (the Bash tool's `run_in_background`), and check on it no more often than every 4 minutes with one short command. Run only the test classes your brief names. The command, with your slug and classes:

    BBS_AGENT=t6d-<task> .claude/skills/agent-bbs/scripts/build-slot-with-bbs.sh xcodebuild test -project TextMouth.xcodeproj -scheme TextMouth -destination 'platform=macOS' -parallel-testing-enabled NO -jobs 4 CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -derivedDataPath /var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-t6d-<task> -only-testing:TextMouthProductionTests/<Class> -only-testing:TextMouthProductionTests/<Class2> > <your scratchpad>/t6d-<task>-build.log 2>&1

Read a result with one command: `grep -E "Executed [0-9]+ tests|error:|failed \(" <log> | tail -20`.

A new Swift file (source or test) needs `/opt/homebrew/bin/xcodegen generate` run from your worktree root, and the regenerated `TextMouth.xcodeproj/project.pbxproj` committed in the same commit as the file.

## Code and tests
- Comment every function, property, and non-obvious block, in the plain, exact style of the code around it. Keep it DRY: reuse the helpers your brief names rather than writing another.
- No test may trap: no force unwrap, no unguarded subscript (use `XCTUnwrap` and `first`), no expectation fulfilled twice. No test plays sound or records. No test touches `~/.TextMouth`; hosted tests run in the test sandbox, which `TextMouthPaths` and `MachineLocalPaths` already point at.
- Edit no `*.md` file and no file your brief does not name. For a problem elsewhere, post a finding: `bbs post t6d-<task> --tag finding --to t6d-lead --file <path> --topic "…"`.
- Each commit is one logical change with its tests, and its message ends with a blank line and `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Write the message to a file in your scratchpad and commit with `git -C <worktree> commit -F <file>`.

## Finish
1. `bbs post t6d-<task> --to t6d-lead --topic "done: t6d/<task>"`
2. `bbs task move t6d-<task> <task number> review`
3. Remove your build folder, exactly these two commands:
   - `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-t6d-<task>/Build/Products/Debug/TextMouth.app"`
   - `rm -rf "/var/folders/zl/r86mh72d0j3d1gsypcj1928m0000gn/T/TextMouth-DerivedData-t6d-<task>"`
4. `bbs release t6d-<task> --all` (this releases your file claims; it does not unregister you from the board, and you need not).
5. Reply with a report of at most 15 lines: the branch; each commit's hash and subject; the tests you added and the exact `Executed …` line of your last run; what you could not verify; and the decisions you made that the brief left open.
