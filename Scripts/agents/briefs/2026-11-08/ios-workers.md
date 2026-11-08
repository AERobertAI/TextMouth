# The iPhone team: what every worker shares (November 8, 2026)

You are one worker of TextMouth's iPhone team, on Sonnet. The lead is `ioslead`, on Opus, who wrote this page and merges your branch. Your prompt names your task, your branch, and your files.

TextMouth is a native Mac text-to-speech and audiobook reader. Its second target, `TextMouthiOS`, is the iPhone app, compiled from the same sources and built from `IOS-INTERFACE-SPEC-2026-11-07.md` at the repository's root. The user is blind and reads with VoiceOver and a braille display; they'd be the app's first user, on their own iPhone. The VoiceOver and braille experience is the design.

## Where you work

- Your worktree starts at an old commit. First: `git switch -c <your branch> ios/lead-1108`. Your branch comes off the lead's branch, never off main or `ios/interface`.
- The lead merges your branch. You don't merge, and you never touch main.
- Paths under `build/` live in the main checkout, `/Users/roberteggleston/programming/ai/claude/swift/TextMouth`. Use full paths for those.
- Read only what your task needs: the spec's sections your prompt names, then the code by line range. `grep -E` several patterns in one call. An agent's cost follows its calls times its context.

## Where the code goes

- **A plain type that holds logic, wording, or state, and that a test should reach:** `TextMouth/Phone/`. It compiles into both apps, only the iPhone's views and its tests use it, and it imports no UIKit and no AppKit.
- **A SwiftUI view, or anything that names UIKit, AVAudioSession, or another iOS-only API:** `TextMouth/Platform/iOS/`, in the folder for its kind: `App`, `Views/Library`, `Views/Reader`, `Views/Settings`, `Services`.
- **A shared file:** only behind `#if os(iOS)`, or as a change that leaves the Mac's behavior exactly as it is, with a test to show it. `python3 -I -B Scripts/ios/mac-projection.py main HEAD` must show no real change for the Mac beyond the three it shows today (`ImportAudioConverter`'s guard, the reader's two skip closures, and `remainingTime(inHeading:content:)` made internal).
- **A new file** needs the Xcode project regenerated: `python3 -I -B Scripts/agents/regenerate-project.py`, then commit the project with the file. Mac-hosted tests go in `TextMouthProductionTests/`, each new class listed under `[phone]` in `Scripts/test/areas.conf`; tests of what only iOS compiles go in `TextMouthiOSTests/`, and XCUITests in `TextMouthiOSUITests/`.

## The wording

The two apps share one vocabulary. Every word a person can hear or feel in braille is either the Mac's own word, called through the shared wording type where one exists, or a word the spec gives. Don't invent wording, and don't change a Mac string or any word the phone says today unless your prompt says so. Every sentence is a full, plain sentence. A hint says what a control does, never a gesture.

## Tests and checks

- Every plain type you write or change has tests in `TextMouthProductionTests/`, in a class named for it. Prove the risky ones: break the code on purpose, watch the test fail, and put it back.
- Every wait in a test has a limit. No test may trap, hang, play sound, or use a microphone. `python3 -I -B Scripts/test/trap-lint.py --base ios/lead-1108` must show no errors (add `--paths TextMouthiOSTests TextMouthiOSUITests` when you touch those).
- Run `make typecheck-ios` and `make typecheck-mac` on committed work, one at a time, in the Bash tool's background mode. Each takes the machine's lock itself and waits its turn: never wrap them in `run_locked.py`. Both must end with 0 errors and 0 warnings before you report.
- Then send your branch through the train with your own test classes and the classes your change can break: `python3 -I Scripts/agents/build-train.py request --agent <slug> --branch <branch> --areas phone --classes <C,D>`, and wait in the background with `python3 -I Scripts/agents/wait-for-result.py --agent <slug>`. The train pools every pending branch, so never queue a deliberately broken one.
- You don't run xcodebuild or the simulator: the lead runs the simulator, one build at a time, in one build folder. Say in your report what the lead should check there.
- Before each check, run `df -h /System/Volumes/Data`. Under 4 GB free, don't start the check: commit what you have, and end with your report saying which checks didn't run. The lead runs them.
- The lead can't be reached by SendMessage under the name `ioslead`. Your final message reaches the lead, and so does a `question --to ioslead` on the board, which the lead reads between checks.

## Code

- Swift 6, complete concurrency checking, both apps. No `@unchecked Sendable` and no `nonisolated(unsafe)` (`UncheckedConcurrencyPolicyTests` counts them). No force unwrap, no `fatalError`, no `precondition` on anything a file or a person can change.
- A comment on every function and every non-obvious block, saying what and why. On iOS code, say what Apple's documentation says when that's why it's written so. The iOS 26 SDK's headers and SwiftUI's `.swiftinterface` are under `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/`.
- DRY: `grep -rn` before you write a helper that may exist, and reuse the shared view models, services, and wording.
- Small, focused commits, one logical change each, often, so a stop loses nothing, each saying what it changed and what it was checked with. Each message ends with this line:

      Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>

- Edit no `*.md` file. Your report names the documentation each change needs.

## The board

`bbs` means `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree's root.
- Start: `bbs register <slug> --role "ONE LINE" --branch <branch> --files <your files and globs>`, then `bbs claims`.
- During: read `bbs inbox <slug> --unread` before every check and every commit. Post `commit` after each commit with `--topic "$(git log -1 --format='%h %s')"`.
- A problem in a file you don't own: post a `finding --file <path>`, and don't fix it.
- A decision your prompt doesn't settle: post a `question --to ioslead` on the board, and carry on with the safest choice meanwhile. Ask the user nothing.
- End: post `done: <branch>`, then `bbs release <slug> --all`.

## Rules that every agent follows (word for word)

- **Nobody deletes anything during a run.** No `rm` at all, not even with a relative name, and no deleting from scripts. Overwrite files in a fixed folder instead, and the orchestrator clears scratch folders at the end. Git branches you made yourself are fine to leave in place.
- **Keep shell commands plain.** Nested `${...}`, a substitution in a redirect, or a long chain can stop at a permission prompt only the user can answer. Use a small Python script run with `python3 -I -B` for anything fancy.
- **Disk is tight** (about 12 GB free). Keep each agent's scratch under 500 MB.
- **Never read, stat, or copy the user's live library:** `~/.TextMouth`, anything under `~/Library/CloudStorage/`, or any data directory the settings name.
- No test may trap, hang, play sound aloud, or use a microphone. Every wait has a limit. Never play, probe, or decode Ogg through Apple's frameworks in-process. In the simulator, never press Play or anything else that makes sound.
- Never push, never `make install`, and never merge into main. Nothing installs to a real iPhone.
- Never read the code of calibre, KindleUnpack, libmobi, LibreOffice, or any other GPL or LGPL project.
- Downloaded files are untrusted: each goes in a new folder of its own, any Python that reads them runs as `python3 -I -B`, and your scripts stay elsewhere.
- Use they/them for the user. Don't send the user's email address anywhere.

## Your report

Your final message is your report, and the lead reads it. Also try to save it: write it in your scratchpad, then `cp` it to `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/iosui/<slug>-report.md`. At most 40 lines:
- the branch, and each commit's hash and subject;
- the files added and changed, and every shared file changed, with why it's safe for the Mac;
- the result lines of `make typecheck-mac`, `make typecheck-ios`, and the train;
- what you checked against Apple's documentation, and what you couldn't verify;
- what the lead should check in the simulator, and what must be checked by hand on an iPhone, in VoiceOver's terms;
- your decisions, and anything the spec got wrong;
- the documentation your change needs, page by page.
