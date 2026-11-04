# iOS phase 0 teams: the pattern (November 3, 2026)

On the evening of November 3, 2026 the user wrote: "please try spending the night with well reviewed sonnet agent teams and the pooled contribution scheduled builds to try conducting the first phase and fixing all IOS errors without changing MacOS behavior if possible." This file is the pattern every team follows tonight. It stands in for AGENTS.md: do not read AGENTS.md, README.md, ARCHITECTURE.md, the TODO, or AGENT-NOTES. Read `IOS-PORT-RESEARCH-2026-11-03.md` only in its sections "What the compiler found" and "How one codebase builds both apps".

Repository: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth`, TextMouth, a native macOS text-to-speech and audiobook player for a VoiceOver and braille user. The integration branch is `integrate/ios-phase0` (from main, version 0.2.5, whose suite is **9301 tests, 75 skipped, 0 failures**). It adds the iOS app target `TextMouthiOS`, the platform folders, and the tools below. The user has not installed 0.2.5 yet: main must stay stable and installable.

## The goal

The iOS target compiles and links: `make typecheck-ios` ends `BUILD SUCCEEDED` with 0 errors. At the same time the Mac app does exactly what it did: the same code compiled, the same suite green. At the start the iOS census counted about 817 errors in 99 files. Each team owns a set of those files and makes them compile for iOS.

## The rules for the Mac's code (the user's "without changing MacOS behavior")

Every change to a file the Mac compiles must be one of these:

1. **A move, unchanged.** `git mv` a file the Mac alone needs into `TextMouth/Platform/macOS/`, keeping its folder below that, so `TextMouth/Services/WatchedProcess.swift` becomes `TextMouth/Platform/macOS/Services/WatchedProcess.swift`. The file's text does not change in the move commit. Before you move a file, `grep -rn` the tests (`TextMouthTests`, `TextMouthProductionTests`) and `Scripts` for its path. A test that reads the file by its path keeps working only if you update that path in the same commit, and you report it.
2. **A wrapper.** Existing Mac code is wrapped, as it stands, in `#if os(macOS)` … `#else` … `#endif`, with iOS code in the `#else` branch. Inside the `#if os(macOS)` branch the text is the same as before, character for character. This includes the postfix form inside a SwiftUI modifier chain:

       Text(x)
           #if os(macOS)
           .onExitCommand { model.escape() }
           #endif

   In a file the Mac and iOS share, `import AppKit` becomes:

       #if os(macOS)
       import AppKit
       #else
       import UIKit
       #endif

   Use `#if canImport(UIKit)` only where UIKit itself is meant.
3. **A platform alias.** A type name becomes an alias that is exactly that type on the Mac. `TextMouth/Platform/PlatformTypes.swift` has `PlatformWindow` (NSWindow), `PlatformFont` (NSFont), and `PlatformView` (NSView). A new alias goes in a new file of your team's directly in `TextMouth/Platform/` (`PlatformShellTypes.swift`, say), one alias per line in the form `typealias PlatformX = NSX` inside `#if os(macOS)`. The projection reads every such file. Do not edit PlatformTypes.swift, which every team shares.
4. **The control-style helpers.** `.toggleStyle(.checkbox)` becomes `.checkboxToggleStyle()`, and `.pickerStyle(.radioGroup)` becomes `.radioGroupPickerStyle()` (TextMouth/Platform/PlatformControlStyles.swift). On the Mac each is exactly the old style.
5. **A split, unchanged.** When one file holds shared code and code only the Mac can compile, you may move a whole declaration, unchanged, into an extension in a new file under `TextMouth/Platform/macOS/` (`NowPlayingService+macOS.swift`). Do this only when wrapping it in place would be worse. The projection counts lines that leave one file and arrive in another as moved.

Anything else that changes what the Mac compiles is a real change. It needs a reason in the commit message and in your report, and the reviewer reads every such line. Avoid it. Check your branch at every step:

    make mac-projection BASE=<your branch's base> DIFF=1

It prints, for each changed Swift file the Mac compiles, the lines that remain changed after moves, wrappers, aliases, helpers, and comments are accounted for. The goal is none, or only lines you can defend one by one.

## The rules for iOS's code

- **Nothing new for the user yet.** The iOS app is a placeholder screen (`TextMouth/Platform/iOS/App/TextMouthIOSApp.swift`). Phase 0 makes the shared code compile. It does not build iPhone features, so iOS branches only compile and do the least they safely can.
- **Stand-ins for Mac-only types that shared code names.** When a type moves to `Platform/macOS` but shared files (yours or another team's) still name it, add an iOS stand-in. It has the same name and the members those files use, in `TextMouth/Platform/iOS/<folder>/<Type>+iOS.swift`, starting with the comment `// Phase 0 stand-in: …`, which says what the Mac version does and what iOS does instead (usually nothing, or throws `IOSUnavailable`).
  - Never take a name away from iOS that a file you do not own uses: give it a stand-in instead.
  - Run `grep -rn "\bTypeName\b" TextMouth --include='*.swift'` before every move.
- **IOSUnavailable.** For work iOS cannot do (starting a helper program, opening an editor in another app), throw `IOSUnavailable.feature("…")`, declared once in `TextMouth/Platform/iOS/IOSUnavailable.swift` (already on `integrate/ios-phase0`). Its phrase completes "… is not available on iPhone yet.": `.feature("Converting this kind of file")`.
- **No traps.** No `fatalError`, force unwrap, or `preconditionFailure` in an iOS branch: a stand-in that cannot work returns or throws.
- **The concurrency rules hold on iOS too.** Swift 6 language mode, complete checking.
  - No `@unchecked Sendable` and no `nonisolated(unsafe)` in new code: `UncheckedConcurrencyPolicyTests` pins their counts (27 and 15) across every Swift file, the platform folders included.
  - Mark a stand-in `@MainActor` where its Mac twin is.

## Ownership

- Each team's charter lists the files it owns, from the census. A team edits only its own files, the new files it creates under `TextMouth/Platform/`, and the tests of the files it owns.
- A problem in another team's file is a board finding (`--file <path>`) to that team's lead. Never fix it yourself.
- Shared files nobody owns tonight: `PlatformTypes.swift`, `PlatformControlStyles.swift`, project.yml, and the scripts. Ask the orchestrator.
- `TextMouth.xcodeproj/project.pbxproj` is regenerated, never hand-edited: run `/opt/homebrew/bin/xcodegen generate` after adding, moving, or removing a file, and commit the result with it.

## Roles

- **The orchestrator** (the main session, Opus; `orchestrator` on the board) launches the leads and the reviewers, integrates the team branches on `integrate/ios-phase0`, runs the full Mac suite there, and merges into main.
- **A team lead** (Sonnet, effort high) owns `team/<team>`, made from `integrate/ios-phase0`.
  - It plans the team's work as tasks and writes a brief for each.
  - It launches up to **two workers at a time** (Sonnet, effort high), reviews each diff, and integrates the accepted work in a straight line.
  - It gets the team branch to 0 iOS errors in its own files and a green Mac test run of its areas.
  - It reports. A fresh reviewer then reads the whole team branch, and its findings come back to the lead.
- **A worker** does one task on `<team>/<task>`, made from the team branch, and reports to its lead.

## The lead's part

1. **Set up.**
   - Run `git -C <your worktree> checkout -b team/<team> integrate/ios-phase0`: the worktree starts elsewhere, so name the base by branch.
   - Register on the board as `<team>-lead`, with your files, and create your team (`bbs team create <team>-lead <team> --purpose "ONE LINE" --lead <team>-lead`).
   - Run one census (`make typecheck-ios CENSUS=1`) and keep its `errors.txt` path: your files' errors are your work list.
2. **Plan small.**
   - A task is one logical change, one to three commits, in files no other in-flight task touches.
   - Each worker costs about 50,000 tokens just to start, so give each a cluster of errors (about 40 to 120), and fold small fixes into a neighbouring task.
   - Write each brief to `Scripts/agents/briefs/2026-11-03/<team>/<task>.md`. It holds:
     - the files and the errors, pasted from the census;
     - the mechanism for each kind of error (which rule above, which stand-in);
     - the stand-ins to write and their members;
     - the Mac test classes and areas to request;
     - a completion check: the census shows none of the task's files.
   - Settle every decision in the brief. Commit the briefs (`git add -f`, one commit) before launching workers.
3. **Launch workers** with the Agent tool. Pass:
   - `subagent_type: "general-purpose"`, `model: "sonnet"`, `effort: "high"`, `isolation: "worktree"`;
   - a description naming the task;
   - a prompt naming the worker's slug (`<team>-<task>`), its branch (`git checkout -b <team>/<task> team/<team>`), its brief, and "The worker's part" of this file.

   Write down each worker's agent id. At most two of your workers run at once, since the Mac has 8 GB of memory and every check waits in one queue.
4. **Wait without polling.** You are told when a worker finishes. Meanwhile review, plan, or wait on the board with `bbs watch <team>-lead --timeout 240`. Never sleep in a loop.
5. **Review every diff** before you take it: `git diff team/<team>...<team>/<task> --stat`, then file by file, then `make mac-projection BASE=team/<team> HEAD=<team>/<task> DIFF=1`. Check:
   - every Mac change is one of the five kinds;
   - every stand-in carries its comment and has no trap;
   - comments on every new function;
   - no file outside the task;
   - the worker's census shows its files clean.

   For a fix, SendMessage the worker (its context is intact), or commit a small fix yourself.
6. **Integrate in a straight line.**
   - Remove the worker's worktree (`git worktree remove --force --force <path>`).
   - Rebase its branch onto `team/<team>` and `git merge --ff-only` it.
   - Regenerate the project if its files changed, and commit that.
   - Use `git -C <path>` rather than `cd … &&`.
7. **Finish.**
   - Rebase onto `integrate/ios-phase0` if the orchestrator says it moved.
   - Run `make typecheck-ios CENSUS=1` (your files must show 0 errors), `make typecheck-mac` (0 errors, 0 warnings), and `make mac-projection BASE=integrate/ios-phase0 DIFF=1`, and keep its output for your report.
   - Ask the train for your areas' Mac tests (below) and wait for the result.
   - Release your claims, post `done: team/<team>` to the orchestrator, and report.

## The worker's part

1. **Branch** from the team branch, as your lead says. Read your brief and the files it names, by line range. Read nothing else unless you must.
2. **Register,** joining your team: `bbs register <slug> --role "ONE LINE" --branch <branch> --team <team> --files <files>`.
3. **Change** with one logical change per commit. Each message ends with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
4. **Check,** in this order, each in the Bash tool's background mode, and wait for it to finish:
   - `make typecheck-ios CENSUS=1` until your brief's files show no error (read its `errors.txt` with one `grep` for your files);
   - then `make typecheck-mac` (0 errors and 0 warnings in the Mac build);
   - then `make mac-projection BASE=team/<team> DIFF=1`.

   Each check takes about two minutes after its turn in the machine-wide queue. Run them only on committed work, one at a time, and never in a loop.
5. **Tests.** If your brief names Mac test classes, ask the build train for them (below), and wait for the result with the waiter.
6. **Stay in your lane.** Edit no `*.md` file and no file outside your brief. For a problem elsewhere, post a finding with `--file <path>`. A failing existing test means stop and ask your lead. Never edit, weaken, or work around an existing test.
7. **Finish.**
   - Post `done: <branch>` to your lead.
   - Release your claims (`bbs release <slug> --all`).
   - Reply with a report of at most 15 lines:
     - the branch;
     - each commit's hash and subject;
     - the census's count for your files;
     - the Mac check's result line;
     - the projection's summary;
     - the train's result, if you asked for one;
     - what you could not verify, and your decisions.

## Builds and checks

Nobody runs xcodebuild tonight. The orchestrator holds every build slot, and the Mac's 8 GB froze under parallel builds on October 31.
- **Type-checks** run through one machine-wide lock, `Scripts/agents/heavy_lock.py`, which the build train shares; a check waits its turn and says whom it waits for. Each writes `summary.md` and `errors.txt` under `build/typecheck/results/` (the path is printed at the end).
  - `make typecheck-ios CENSUS=1`: the census, every AppKit use counted.
  - `make typecheck-ios`: strict, as the real iOS target builds.
  - `make typecheck-mac`: the Mac build, compiled and linked, in about 96 seconds.
- **Mac tests** go through the build train, every half hour, pooling everyone's branches.
  - Queue them: `python3 -I Scripts/agents/build-train.py request --agent <slug> --branch <branch> --areas <a,b> --classes <C,D>`. The areas are those of `python3 Scripts/test/run-area.py --list`. Keep the request to the areas your files touch; never `all`.
  - Then wait in the background: `python3 -I Scripts/agents/wait-for-result.py --agent <slug>`. It exits with your result.
  - A train also counts the iOS errors of the merged tree and lists those in your files.
  - A branch that conflicts is left out, and you are told.
- **Disk.** Check `df -g /System/Volumes/Data` before a check: below 3 GB free, post to the orchestrator and wait.
- **rm.** Every `rm` takes literal paths, never a shell variable: Claude Code stops for the user's approval otherwise, and the user is asleep. For an experiment, write each run's output into a new folder with a literal name, and delete nothing during the run.
- **Paths and editing.**
  - The worktree guard refuses `${TMPDIR}`; write literal paths.
  - A shell's `cd` lasts into later calls, so use `git -C <path>` and absolute paths.
  - `sed` here is GNU sed: use Python for in-place edits, never two heredocs on one command line, and Python tools write no bytecode (`python3 -I`, `sys.dont_write_bytecode = True`).

## Rules for everyone (the user's, and they override anything else)

- Never push, never `make install`, never merge into main.
- Never read, copy, or write anything under the user's live library, `~/.TextMouth`, in a test, an experiment, or a review.
- The user is a VoiceOver and braille user. Change no Mac wording, label, hint, or announcement. An iOS string a person could hear must be a full, plain sentence.
- No test may trap, play sound aloud, or record from a real microphone.
- Never play, probe, or decode Ogg audio through Apple's frameworks in TextMouth's process or a test's.
- Comment every function and non-obvious block. Keep code clean and DRY, and commits small and focused.
- Only leads write briefs, and they edit no other `*.md` file.

## The board

`bbs` means `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree root.
- Teams: `bbs team --help`, `bbs task --help`, and `.claude/skills/agent-bbs/SKILL.md`.
- Post with `bbs post <name> --tag <kind> --to <name|team:NAME|orchestrator> --topic "..."`. A topic is at most 200 characters.
- Read with `bbs inbox <name> --unread`.

## Usage

The orchestrator watches the weekly usage and stops new work at 60% left. Do not check usage yourself, and do not stop for a usage reading unless one is "critical". The "Weekly (Fable)" window does not apply to you. Commit small and often, so that a stop loses nothing.

## Keeping the cost down

An agent's cost follows how many calls it makes times how large its context has grown.
- Read by line range, once.
- Put several patterns in one `grep -E`, and make independent calls in one response.
- Keep reports short. A lead reads its workers' reports, not their transcripts, and reviews diffs `--stat` first.

## A lead's report (its final message)

Write it also to `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/ios0/<team>-lead-report.md`, which is gitignored and survives a session restart.
- The team branch and its commits: hash and subject.
- The census's count for your files, with the path of its `errors.txt`.
- `make typecheck-mac`'s result.
- The projection's summary line, and every real Mac change left, with its reason.
- The train's result line for your areas.
- For each task: the worker's slug and agent id, and whether its work was accepted as written, accepted after fixes (how many rounds), or dropped.
- The stand-ins you added, one line each, for phase 1's list.
- What you could not verify, your decisions, and the follow-ups, one line each, with the file.
- The pattern: what worked, what did not, and where Sonnet needed help.
