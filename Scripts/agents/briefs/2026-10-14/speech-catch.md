# Task brief: speechcatch — rendered speech must not crash when the audio output stops (B08)

Slug `speechcatch`. Branch `fix/rendered-speech-exception` from local `main` (at 33bf4fb3 or later: `git merge-base --is-ancestor 33bf4fb3 HEAD`). Read `common.md` beside this brief for the rules, the build wrapper, and the report format. No other agent is working now. The weekly budget is nearly spent: work directly, build only targeted classes until the one full suite at the end, and keep your report short.

## The bug
`RenderedSpeechFeeder` (`TextMouth/Services/AudioEngineService.swift`) calls `node.play()` on an `AVAudioPlayerNode` in two places:
- `start(_:)`, inside `queue.sync`, around line 596;
- `resumeNode()`, around line 627 (called around line 1347).

When the Mac's audio output stops cycling, AVFAudio raises an Objective-C exception there ("player did not see an IO cycle"). Swift cannot catch it, so TextMouth crashes. On October 14 the test host crashed nine times this way in `AudioEngineBehaviorTests` during an audio-output glitch (board #2491).

## Required behavior, one commit each, with tests
1. **An Objective-C exception catcher, built exactly as LAME is built.** See `project.yml`: the `LAME` target, the app's `SWIFT_INCLUDE_PATHS`, and `Vendor/lame/include/module.modulemap`.
   - Files:
     - `Vendor/ObjCExceptionCatcher/ObjCExceptionCatcher.m`;
     - `Vendor/ObjCExceptionCatcher/include/ObjCExceptionCatcher.h`;
     - `Vendor/ObjCExceptionCatcher/include/module.modulemap`, declaring `module ObjCExceptionCatcher { header "ObjCExceptionCatcher.h" export * }`.
   - API: one C function, `NSException * _Nullable TMCatchException(NS_NOESCAPE void (^ _Nonnull block)(void));`. It runs `block` inside `@try` and returns the exception caught, or nil.
   - Target: a `library.static` target with `requiresObjCLinking: false` (a function, no class) and ARC on. The app depends on it, and its include folder is added to the app's `SWIFT_INCLUDE_PATHS`. Mirror whatever the test target does for LAME's module, so the tests build.
   - Swift side: a thin Swift wrapper in the app, `ObjCException.catching(_:) -> NSException?`, in `TextMouth/Services/ObjCException.swift`, is the only Swift code that imports the module.
   - Run `/opt/homebrew/bin/xcodegen generate`, and commit `project.pbxproj` with the files.
   - Tests: a block that doesn't raise runs and yields nil; a block that raises (`NSException(name:reason:userInfo:).raise()`) yields that exception, with no crash.
2. **The feeder never lets an exception through.**
   - The calls: route every `node.play()` in `RenderedSpeechFeeder` through the catcher. Make the player start injectable for tests (a closure property defaulting to `{ $0.play() }`).
   - In `start(_:)`, a caught exception ends the play (`endPlay()`), stops the node (through the catcher too), logs one event line, and returns false. The line is `SPEECH_PLAYER_EXCEPTION: <name>: <reason>`; `LogContentPolicyTests` checks its form.
   - `resumeNode()` returns whether it resumed, false on an exception (with the same log line).
   - Callers: trace what the engine does with `started == false` (around line 1220) and with a failed resume (around line 1347). Make sure the listener is told, through the speech service's existing failure or stop path, never left with Playing over silence. Reuse existing wording where it fits; any new sentence is pinned by a test.
   - Tests: inject a start that raises, then check that `start` returns false, nothing stays scheduled, the line is logged, and the reader or speech service ends up stopped and saying so. Nothing may trap, and no test plays sound aloud.

## Report
As `common.md` says, short: the commits, the suite's exact line, what you could not verify, and two or three sentences of documentation wording, naming each page (`docs/architecture/state/media-playback.md` and `docs/architecture/shared-helpers.md`).
