# Team `iosui`: what every worker shares (November 7, 2026)

You are building one slice of TextMouth's iPhone app, from the spec `IOS-INTERFACE-SPEC-2026-11-07.md` at the repository's root. Your prompt names your slice, your branch, and your files. This page says how every slice is built. The user is blind and reads with VoiceOver and braille, and will be the app's first user. The VoiceOver and braille experience is the design.

## Where you work

- Your worktree starts at origin/main from October 3. First: `git switch -c <your branch> ios/interface`. Your branch comes off the team's branch, `ios/interface`, never off main.
- The lead merges your branch into `ios/interface`. You don't merge, and you never touch main.
- Paths under `build/` and the file `TODO-2026-09-04.md` live in the main checkout, `/Users/roberteggleston/programming/ai/claude/swift/TextMouth`. Use full paths for those.
- Read only what your slice needs: the spec's sections your prompt names, then `docs/architecture/platforms.md`, then the code by line range. `grep -E` several patterns in one call. An agent's cost follows its calls times its context.

## Nothing can run on iOS tonight

The Mac can't hold the iOS platform, so no simulator and no device. `make typecheck-ios` compiles and links, and that is the only check of iOS code. So:

- **Keep SwiftUI views thin.** Put every decision, every sentence, and every piece of state logic in a plain type that compiles on both platforms, so the Mac's test host can run its tests through the train. A view reads the model and calls it, and holds nothing a test would want to see.
- **Check each API against Apple's documentation,** because no run will catch a misuse. The iOS 26 SDK is on this Mac, and its interfaces are the last word:
  - SwiftUI: `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk/System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/arm64e-apple-ios.swiftinterface`, read by grep and line range;
  - UIKit, AVFAudio, MediaPlayer and the rest: the `Headers` folders of that SDK's `System/Library/Frameworks/`;
  - Apple's documentation pages: fetch `https://developer.apple.com/tutorials/data/documentation/<lowercase path>.json` (WebFetch is a deferred tool: load it with ToolSearch, `select:WebFetch`).
- **Name each behavior you couldn't verify,** in a comment where it matters and in your report. Say plainly in your report that nothing has run on iOS.

## Where the code goes

- **A plain type that holds logic, wording, or state, and that a test should reach:** a shared file, in the folder `TextMouth/Phone/`. It compiles into both apps, and only the iPhone's views and its tests use it. It must import no UIKit and no AppKit. Name it for what it is, such as `PhoneReaderWording`.
- **A SwiftUI view, or anything that names UIKit, AVAudioSession, or another iOS-only API:** `TextMouth/Platform/iOS/`, in the folder that mirrors the kind of file: `App`, `Views/Library`, `Views/Reader`, `Views/Settings`, `Services`.
- **A shared file you must change:** only behind `#if os(iOS)`, or as a change that leaves the Mac's behavior exactly as it is, with a test to show it. Keep such changes to the fewest lines, and name every one in your report. `make mac-projection` must show nothing new for the Mac beyond your new files.
- **A new file** needs the Xcode project regenerated: run `python3 -I Scripts/agents/regenerate-project.py` and commit the project with the files. A test file goes in `TextMouthProductionTests/`.

## The wording

The two apps share one vocabulary. Every word a person can hear or feel in braille is either the Mac's own word, called through the shared wording type where one exists, or a word the spec gives. Don't invent wording, and don't change a Mac string. Where the Mac's sentence sits inside a Mac view, the spec says what to do: usually a new shared constant used by the iPhone alone, with a test pinning that it equals what the Mac says. Every sentence is a full, plain sentence. A hint says what a control does, never a gesture.

## Accessibility

- Follow the spec's element-by-element sections exactly: label, value, hint, traits, actions, rotor items, what's announced and when, where focus lands on arrival and return.
- Run `python3 Scripts/test/a11y-lint.py --base ios/interface` over your branch before each report, and fix what it finds. A view with no text of its own gets an `accessibilityLabel`.
- Nothing is conveyed by sight alone. Nothing moves VoiceOver's cursor unless the spec says so. Nothing speaks over the book unless the spec says so.

## Tests

- Unit tests are heavy and first-class: every plain type you write gets tests in `TextMouthProductionTests/`, in a class named for it. Prove the risky ones: break the code on purpose, watch them fail, and put it back.
- Every wait in a test has a limit. No test may trap, hang, play sound, or use a microphone.
- Send your branch through the train with your own test classes and the classes your shared changes can break:
  `python3 -I Scripts/agents/build-train.py request --agent <slug> --branch <branch> --classes <C,D> --areas <a,b>`, then wait in the background with `python3 -I Scripts/agents/wait-for-result.py --agent <slug>`. The train pools every pending branch, so never queue a deliberately broken one. It runs on the half hour.
- Run `make typecheck-ios` and `make typecheck-mac` on committed work, one at a time, in the Bash tool's background mode. Each takes the machine's lock itself: never wrap them in `run_locked.py`. Both must end with 0 errors and 0 warnings before you report.
- Nobody runs xcodebuild directly.

## Code

- Swift 6, complete concurrency checking, both apps. No `@unchecked Sendable` and no `nonisolated(unsafe)`: `UncheckedConcurrencyPolicyTests` counts them. No force unwrap, no `fatalError`, no `precondition` on anything a file or a person can change.
- A comment on every function and every non-obvious block, saying what and why. On iOS code, say what Apple's documentation says when that's why it's written so.
- DRY: `grep -rn` before you write a helper that may exist. Reuse the shared view models, services, and wording.
- Small, focused commits, one logical change each, often, so a stop loses nothing. Each message ends with this line:

      Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>

- Edit no `*.md` file except what your prompt names. Your report names the documentation each change needs.

## The board

`bbs` means `python3 .claude/skills/agent-bbs/scripts/bbs.py`, run from your worktree's root.

- Start: `bbs register <slug> --team iosui --role "ONE LINE" --branch <branch> --files <your files and globs>`, then `bbs claims`, and `bbs task move <slug> <task id> working` when your prompt gives a task id.
- During: read `bbs inbox <slug> --unread` before every check and every commit. Post `commit` after each commit with `--topic` holding its hash and subject, by `git log -1 --format='%h %s'`.
- A problem in a file you don't own: post a `finding --file <path>`. Don't fix it yourself.
- A decision the spec doesn't settle: `question --to iosui-lead`, and carry on with the safest choice.
- End: `bbs task move <slug> <task id> review --note "ONE LINE"`, post `done: <branch>` with `--to team:iosui`, and `bbs release <slug> --all`.

## Your report

Your final message is your report. Also try to save it: write it in your scratchpad, then `cp` it to `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/iosui/<slug>-report.md` (the Write tool refuses that path; `cp` through Bash works). At most 40 lines:

- the branch, and each commit's hash and subject;
- the files added and changed, and every shared file changed, with why it's safe for the Mac;
- the result lines of `make typecheck-mac`, `make typecheck-ios`, and the train;
- what you checked against Apple's documentation, and what you couldn't verify;
- what must be checked by hand on an iPhone, in VoiceOver's terms;
- your decisions, and anything the spec got wrong;
- the documentation your change needs.

Say plainly that nothing has run on iOS.
