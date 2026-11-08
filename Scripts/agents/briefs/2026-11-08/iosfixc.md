# The iPhone interface: the ten failing XCUITests (November 8, 2026)

You are `iosfixc`, a Sonnet worker. The iPhone app's interface (`ios/lead-1108`) ran in the simulator this morning, and its outside review's 13 findings are fixed and checked. It is merging into main now. In its last simulator pass, 16 of 16 unit tests and 8 of 18 XCUITests passed. Your job is the other 10, and a few small follow-ups. The user is blind and reads with VoiceOver and a braille display: what VoiceOver and the audit read is the design.

## Start

- Your worktree may start at an old `origin/main`. Make your branch at the merge: `git switch -c ios/fix-c-1108 acf6afc1`, and check that `git log -1 --format=%h` prints `acf6afc1`.
- Read, in this order:
  - the lead's report, `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/iosui/ioslead-report.md`, its section "What isn't done, and what I couldn't verify";
  - the outside check, `iosverify-report.md` beside it, its item 8;
  - how to build and test for the simulator, in `docs/developer/building.md` and `docs/developer/testing.md` as the docs branch has them: `git show docs/ios-1108:docs/developer/building.md`, and the same for testing.md.
- Read "Making each train count" in `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/docs/agents/working-with-agents.md` and follow it. Trains leave once an hour, on the hour, and heavy jobs run one after the other.

## The work, in this order

1. **Book Information and the navigation unit's choice show no Cancel, and the Voice sheet never showed "Speed".** By reading, the app has both: a Cancel in `.cancellationAction`, and a slider labelled "Speed". So find why each test misses it: an element found by label that has only an identifier, a query made before the sheet is up, or a slider's label read as its value. Fix the test, or the app if the app is wrong. Make each failure message say what it found instead, as the lead's Back test now does.
2. **Contrast.** The user hasn't answered yet, so follow the recommended answer: all of the phone's text at full contrast, with no word changed. Apple's audit says iOS's secondary gray only "nearly" passes, on Settings (10), Headings (22), Go To, Add to Library, Sleep Timer, and Bookmarks.
   - Make one shared style for secondary text and use it everywhere, rather than editing each view's colour. The Library's text is already full contrast, so start from how it does it.
   - The change must be easy to undo if the user answers no: one place.
3. **Dynamic Type.** Settings has 4 findings, and the Library's summary is "partially unsupported", with no cap found in the code. Look for a fixed font size, `lineLimit`, `minimumScaleFactor`, or a fixed frame, and check the largest accessibility sizes. Text must grow and wrap, never be cut.
4. **Go To:** one "element detection" finding, so look at that first, and two clipped texts.
5. **Small follow-ups.**
   - `PhoneErrorAlertPlanTests`, `PhonePreviewPauseTests`, and `PhoneSpeechRefusalPresentationTests` are in the `settings` area of `Scripts/test/areas.conf`. Move them to `phone` if they test the phone's code.
   - `TextMouth/Phone/PhoneSettingsDefaults.swift` holds only a comment. Remove it with `git rm`, then run `python3 -I -B Scripts/agents/regenerate-project.py`. Git keeps it in its history. This is the one removal allowed.

## Checks

- **Simulator runs:**
  - Every simulator build or test run goes through `python3 -I /Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/followups1105/run_locked.py <name> <command...>`, with `-derivedDataPath /Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/DerivedData-ios.noindex`.
  - Use iPhone 17 only, and make no new devices. Run `xcrun simctl shutdown all` afterwards.
  - At most two passes in all, each with every XCUITest and unit test in it. Fix everything you can between them by reading.
- **Never press Play, never type, and nothing that makes a sound:** the simulator plays through the Mac's speakers, which the user would hear.
- **Type-checks.** Run `make typecheck-mac` and `make typecheck-ios` once for the batch, after committing, since they check HEAD's commit. Never wrap them in `run_locked.py`.
- **The train.** If you changed Swift that the Mac compiles, send one request naming the `phone`, `accessibility`, and `support` areas and every class your change could touch: `python3 -I Scripts/agents/build-train.py request --agent iosfixc --branch ios/fix-c-1108 --areas phone,accessibility,support --classes A,B`. Then wait for it with one background `python3 -I Scripts/agents/wait-for-result.py --agent iosfixc`.
- **Disk:** about 12 GB free. Report how much you add.

## Rules that every agent follows (word for word)

- **Nobody deletes anything during a run.** No `rm` at all, not even with a relative name, and no deleting from scripts. Overwrite files in a fixed folder instead, and the orchestrator clears scratch folders at the end. Git branches you made yourself are fine to leave in place.
- **Keep shell commands plain.** Nested `${...}`, a substitution in a redirect, or a long chain can stop at a permission prompt only the user can answer. Use a small Python script run with `python3 -I -B` for anything fancy.
- **Never read, stat, or copy the user's live library:** `~/.TextMouth`, anything under `~/Library/CloudStorage/`, or any data directory the settings name.
- No test may trap, hang, play sound aloud, or use a microphone. Every wait has a limit. Never play, probe, or decode Ogg through Apple's frameworks in-process.
- Never push, never `make install`, and never merge into main.
- Never read the code of calibre, KindleUnpack, libmobi, LibreOffice, antiword, catdoc, wvWare, odfpy, libwpd, or any other GPL or LGPL project.
- Use they/them for the user. Don't send the user's email address anywhere.
- When unsure, carry on with the safest choice and say so in the report. Ask the user nothing.

## Commits and report

- Commit small and often, each saying what it changed and what checked it. Messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Your final message is the report, 40 lines at most:
  - the branch, its tip, and its commits;
  - each of the 10 XCUITests, before and after;
  - the audit findings left, each with its reason;
  - the type-checks, the train, and the simulator passes;
  - the disk you added;
  - what you couldn't verify;
  - the documentation each change needs (you edit no Markdown).
