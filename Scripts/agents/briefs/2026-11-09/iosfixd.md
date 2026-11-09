# The iPhone interface: its open audit findings (November 9, 2026)

You are `iosfixd`, a Sonnet worker, on branch `ios/fix-d-1109`. First read `common.md` beside this file and follow it exactly: it says how to start, check, and report.

The iPhone app's interface (unshipped) runs in the simulator. After yesterday's fix round, 17 of its 22 XCUITests pass. The five left are audit findings, three with no known cause, and a few small follow-ups remain. They are your work.

## Read first

- In the main checkout's `build/orchestrator/iosui/`:
  - `iosfixc-report-1.md` and `iosfixc-report-2.md`, yesterday's worker's reports (the second and the code win where they disagree);
  - `review-code-1108.md`, the first review;
  - `ioslead-scratch/`, the lead's scripts for simulator passes (`first_run.py`, `sim_session.py`), the only record of its exact commands.
- In `docs/developer/testing.md`, the iPhone's section: the open findings, the audits that report without failing, `LargeTextUITests`, and the probe. `docs/developer/building.md`: building and testing for the simulator.
- In `docs/architecture/platforms.md`: `PhoneTextStyle`, `PhoneValueRow`, and `PhoneSheetButton`.

## The work, in this order

1. **`LargeTextUITests`'s two findings**, real Dynamic Type faults at the largest accessibility size: the Library's summary and Settings. Text must grow and wrap, never be cut or overlap. Look for a fixed font size, a `lineLimit`, a `minimumScaleFactor`, a fixed frame, or a row that won't stack.
2. **Dynamic Type "partially unsupported"** on Settings, Sleep Timer, and Book Information. It reports without failing, and its cause is unknown. Find which element each finding names and why. Fix ours; report what is iOS's.
3. **Go To's "element detection" finding**, with no cause found. Find the element the audit names, by its frame, label, and traits: a container with no label, an element of zero size, or one hidden yet still in the tree. Fix it.
4. **The contrast of the first section header** on Settings ("Voice") and on Sleep Timer ("New Timer"). The text is black, so these are likely false positives.
   - Prove what the audit measures: the element, its frame, and the colours behind it.
   - If it is ours, fix it.
   - If it is a false positive, let that one issue pass, by its element and its kind only, with a comment saying why. Every other contrast issue must still fail.
5. **`PhoneValueRow`'s stacking** at the accessibility sizes has no test: add one.
6. **The placement probe** (`TEXTMOUTH_PROBE_SYSTEM_PLACEMENT`, `ToolbarPlacementProbeUITests`) has given its answer, which `docs/developer/testing.md` and `platforms.md` record.
   - Remove the probe's code.
   - Remove its test file with `git rm`, then run `python3 -I -B Scripts/agents/regenerate-project.py`. Git keeps it in its history. This is the one removal allowed.
7. **`PhoneTextStyle.swift`** cites a spec section, "Dynamic Type and contrast", that `IOS-INTERFACE-SPEC-2026-11-07.md` doesn't have. Cite the section that says it, by its real name.
8. **`PhoneLaunchRequest`** compiles into every build, though both its uses are debug-only. Make the whole of it debug-only.
   - The type-checks define DEBUG, so they can't prove it. Show by reading that every use is debug-only.
   - Run one Release build of the iOS app for the simulator, through `run_locked.py`.
   - The Mac's Release builds belong to `macsize`, so say in your report that the Mac's Release side is unchecked.
9. **The reopen keys outlive the crash guard's clearing,** so a crash in that short window reopens the book at the next launch. Find the order in `PhoneLifeCycle+Reopening.swift` and its callers, make the keys go with the guard, and pin it with a unit test.

## Checks

- **Simulator passes:**
  - At most three in all, each with every XCUITest and unit test in it. Fix everything you can by reading before the first, and between passes.
  - Each through `run_locked.py`, with `-derivedDataPath /Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/DerivedData-ios.noindex`.
  - iPhone 17 only, and make no new devices. Run `xcrun simctl shutdown all` after each.
- **Never press Play, never type, and nothing that makes a sound:** the simulator plays through the Mac's speakers, which the user would hear.
- **The train.** If you changed Swift that the Mac compiles, send one request with `--areas phone,accessibility,support` and every class your change could touch.
- **Your report** gives each of the five findings before and after, with the audit's own words.
