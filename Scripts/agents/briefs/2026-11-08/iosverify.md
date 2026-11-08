# A narrow check of the iPhone interface before it merges into main (November 8, 2026)

You check `ios/lead-1108` at **1fefa2cf** before the orchestrator merges it into main. An outside Opus review found 5 majors and 8 minors, two Sonnet workers fixed all 13, and train 1108-0900 passed the tip (1,270 tests, 0 failures). Your job is narrow: confirm that each finding is really fixed, with a test that would fail without the fix, and that the branch leaves the Mac app as it was. You redesign nothing and fix nothing. Report what you find, and the orchestrator decides.

Read `Scripts/agents/briefs/2026-11-08/verify-common.md` for the method, the rules (word for word), and the report format. These lines replace its older ones:

- **Start.** `git log -1 --format=%h main` should print `bbf72424` (version 0.4.2 with KF8). Run `git checkout --detach 1fefa2cf`. The branch's diff is `git diff main...1fefa2cf`, and its own commits are `git log --first-parent --oneline 37292728..1fefa2cf`.
- **Trains** leave once an hour, on the hour, and each tests the commit your request names. Read "Making each train count" in `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/docs/agents/working-with-agents.md`: one request, naming every class you need, reviewed before you send it.
- **No simulator.** Don't build or run `TextMouthiOS` or its tests; the lead's two passes are the evidence. Judge iOS-only screens by reading, and say so. Never press Play.

## Read first

- The review: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/iosui/review-code-1108.md`.
- The lead's report: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/iosui/ioslead-report.md`.
- The spec, only where a finding needs it: `IOS-INTERFACE-SPEC-2026-11-07.md` in the repository root.

## What to check

1. **The 13 findings.** iosfixa fixed 1, 2, 4, 7, 8, 10, and 11; iosfixb fixed 3, 5, 6, 9, 12, and 13. For each, say fixed, partly fixed, or not fixed, with the test that pins it. Prove the riskiest three by breaking the fix in a throwaway copy (the phone's logic tests run on the Mac's host, so a SwiftPM copy under `run_locked.py` can run them).
2. **The Mac stays as it was.** `make mac-projection BASE=main` should show four real changes: three reflows, and `SpeechRefusalReport.swift`'s wording, whose Mac strings stay identical (pinned by `SpeechRefusalReportTests`). Confirm that the reflows change no behaviour, and that the strings really are identical.
3. **The shared changes inside `#if os(iOS)`** leave the Mac's path unchanged: TextMouthRuntime's launch request, SettingsViewModel's braille table, VoiceOverAnnouncer's priorities, and ReaderViewModel+Playback's lock-screen policy.
4. **The debug launch request** (`PhoneLaunchRequest`, `TEXTMOUTH_UI_TEST=1`, `TEXTMOUTH_OPEN_AT_LAUNCH`). It should be compiled only into debug builds, and only for iOS, so a release build can't be steered by an environment variable. Its sandboxed library should never touch a real one.
5. **The project.**
   - The Mac's `TextMouth` scheme, and what its tests run, should not include the two new iOS test targets, so the Mac's full suite is unchanged.
   - The copy-files phases should match main's: `python3 -I -B /Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/followups1105/copy_phases.py TextMouth.xcodeproj/project.pbxproj`, compared with the same command's output for main's project file.
6. **The iOS plist.** There is one plist. `Scripts/ios/sync-info-plist.py` adds the audio background mode and the one-scene setting. `IOSInfoPlistTests` checks both, and `make check-ios-plist` passes.
7. **The two defects of the first run.**
   - Book content was blank at a chapter with no text; it should now show the next chapter with words.
   - config.json's braille table was "repaired" at every launch.
   Each should be pinned by a test.
8. **The XCUITests still failing** (10 of 18) are known and are the next round's work. Just say whether any of them looks like a defect in the app rather than an unfinished audit: the Cancel missing from Book Information and from the navigation unit's choice, and the Voice sheet that never showed "Speed".
9. **Nearby damage:** at most a third of your time.

Your final message is the report, in verify-common.md's form, 40 lines at most.
