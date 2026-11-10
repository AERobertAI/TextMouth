# Quitting while work is held (November 9, 2026)

You are `quitfix`, a Sonnet worker, on branch `fix/quit-while-held`. First read `common.md` beside this file and follow it, except for your start commit: make your branch at main, `git switch -c fix/quit-while-held 3fdf9db7`, and check that `git log -1 --format=%h` prints `3fdf9db7`.

When TextMouth is asked to quit while work it must finish is under way, it holds the quit: `applicationShouldTerminate` answers `.terminateLater`, and replies once the work ends. That work is a download, a re-read of books, an export, or a library move. An outside review of today's transcript branch found two old ways this goes wrong, both in the user's installed 0.4.2. They are your work. The user is blind and uses VoiceOver, so a frozen app or one that says nothing is worst of all.

## Read first

- Findings 1 and 2, the two blockers, of `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/followups1105/transcriptfollow-review.md`.
- The review's probes, copied to `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/quitfix/review-probes/`: `terminate_later.swift`, `terminate_key.swift`, `terminate_key_queue.swift`. Each is a small AppKit program with a 5-second watchdog. You may build and run them, and copies of them.
- The code the review names:
  - `AppDelegate.swift` around 142-148;
  - `UnsavedChangesTermination.swift` (101, 145, 163-169, 231-253);
  - `AudioEditorWindowController.swift` around 266-272;
  - `DataDirectoryMoveProgress.swift` around 147;
  - the Record window's take;
  - `QuitHold`.

## The two faults

1. **A quit asked again from the main queue while work is held never ends.**
   - Quit Anyway, a Retry that saves, an audio editor's Save or Discard, the Record window's take, and a library move's end all call `terminate(nil)` again from a main-queue block or a main-actor Task.
   - When work is held, AppKit's wait for the reply runs inside the main queue's drain and runs no main-queue work. So the hold's Task never starts, nothing replies, and TextMouth stays open with its main actor stopped.
   - **Fix:** ask again from outside the main queue's drain, for example with `NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)`. Do it in every such place, through one helper.
2. **A second Command-Q, or the Dock's Quit, while a reply is pending quits at once** without asking the delegate, cutting the held work off. Downloads lose their resume data, a re-read can stop between content.md and its record, and an export stops mid-chapter.
   - Choose the design by what the probes show, and say why. One choice: answer `.terminateCancel`, end the work, and ask again, as the editors already do. Note that a cancel also stops a logout. Another: take over the Quit command while a quit is held.
   - The listener's work must never be lost, TextMouth must never hang, and a quit must still end in a bounded time.
3. **Say what is happening.** While a quit is held, TextMouth tells the listener, aloud through VoiceOver's announcement and in plain words on screen, what it is finishing and that it will quit afterwards. A second request to quit says the same again; it doesn't cut the work off.

## Checks

- **Unit tests** in the suite for the decisions: what is held, what a second request does, and that every re-ask goes through the one helper.
  - No test may quit, terminate, or stop the test host, and no test may hang: every wait has a limit.
- **The AppKit behaviour** in child processes, with a watchdog, as the review's probes do. Make them a script in `Scripts/test/` that runs each case and prints its verdict; it isn't part of the suite.
  - It must show a held quit asked again from the main queue replying within a limit.
  - It must show a second Command-Q during a hold no longer cutting the work off.
- Before your train request, type-check your tests on your commit with `python3 -I /Users/roberteggleston/programming/ai/claude/swift/TextMouth/Scripts/ios/typecheck.py --platform macos --tests --ref <your commit>`. It takes the heavy lock itself, so never wrap it in `run_locked.py`.
- Then one train with the areas that hold the quit, the editors, the feeds' downloads, the exports, and the library move, and every class you change.
- **Breaks:** undo each fix in a scratch copy, and show that a test or the script's case fails.
