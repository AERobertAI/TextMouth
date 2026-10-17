# testkit/a11y-lint: an accessibility linter for the SwiftUI lines a branch adds

Slug `testkit-a11y-lint`. Branch `testkit/a11y-lint`, made from `team/testkit` AFTER `testkit/trap-lint` was integrated (`Scripts/test/difflint.py` exists on your branch; if it does not, stop and tell `testkit-lead`). Python 3 standard library only. **You build nothing.** Read `teams-common.md`'s worker's part first.

## Why

The user is blind. Every control must be keyboard-operable, every value spoken, nothing conveyed by sight alone, and every wording pinned by a test. In-process accessibility walks only work while hosted windows expose accessibility, which they often do not (`AccessibilityTestSupport.swift:391`), so the project cannot test "does this new view have a label" by running it. A static check of the SwiftUI sources can catch the common mistakes on exactly the lines a branch adds: no baseline needed, old code never complains, and every lead and worker can run it before a build and at review. It uses the diff-lint engine that `testkit/trap-lint` built.

## Ground truth

- `Scripts/test/difflint.py` (read it by `-h` and its function comments): `Rule`, `lint_file`, `mask_swift` (code view and code-with-strings view per line), `added_lines`, `report`, `main(rules, default_paths, argv)`, the `// lint-ok: <reason>` suppression, the `--base/--paths/--all/--strict/--selftest` options. `Scripts/test/trap-lint.py` is the model for a rules file. Do not change the engine unless a bug blocks you (then post a finding to the lead).
- The app's views: `TextMouth/Views/` (about 120 files; `ls` it once) and `TextMouth/App/MenuCommands.swift`. Existing accessibility conventions to learn from, by `grep -n` only: `.accessibilityLabel`, `.accessibilityHint`, `.accessibilityValue`, `.accessibilityAction`, `.accessibilityElement(children:`, `.accessibilityHidden`, `VoiceOverFocus`, `VoiceOverAnnouncer`.
- TODO A03 (TODO-2026-09-04.md line 3547): a view with a row tap gesture and drag reordering was invisible to VoiceOver; the repair added explicit edit and move-up/down actions. That is the class of mistake to catch.
- SwiftUI `.help("...")` sets the accessibility help text on macOS; do not flag it.

## The rules (names are part of the interface; tune patterns on the real code, see "Measure")

ERROR (almost certainly a defect):
- `empty-label`: `.accessibilityLabel("")` or `.accessibilityLabel(Text(""))`.
- `tap-gesture-only`: an `.onTapGesture` where none of the next 8 code lines has `.accessibilityAddTraits(.isButton)`, `.accessibilityAction`, or `.accessibilityElement(`, and the previous 3 lines do not open a `Button`: a tap-only control cannot be activated by VoiceOver.
- `hidden-control`: `.accessibilityHidden(true)` on a line that also declares a `Button(`, `Toggle(`, `TextField(`, `Picker(`, `Slider(`, or `Stepper(`.
- `unnamed-field`: `TextField("",`/`Toggle("",`/`Picker("",` with no `.accessibilityLabel` in the next 6 lines.
REVIEW (suspect; a person decides):
- `unlabelled-image`: `Image(systemName:` or `Image("` with neither `.accessibilityHidden(true)` nor `.accessibilityLabel(` in the next 4 code lines, and not inside a `Label(` or a `Button(...) { ... Text` that names itself.
- `icon-only-button`: a `Button` whose label closure holds an `Image` and no `Text`, with no `.accessibilityLabel` in the closure or the next 4 lines.
- `drag-without-keyboard`: `.onMove(`, `.onDrag(`, `.draggable(`, `.dropDestination(`: confirm a keyboard alternative exists (A03's move up/down actions).
- `hover-only`: `.onHover(` (an affordance that appears only on hover is unreachable by keyboard).
- `fixed-font-size`: `.font(.system(size:` (does not follow the user's text-size settings; the matrix's "Display/accessibility settings" row).
- `direct-announcement`: `NSAccessibility.post(` or `AccessibilityNotification.Announcement` outside `VoiceOverAnnouncer.swift`/`VoiceOverFocus.swift` (spoken wording goes through the announcer so a test pins it).
- `color-word`: user-visible text literals (in `Text("...")`, `.accessibilityLabel("...")`) that point to a color or a position by sight (`"the red button"`, `"above"`, `"below"`, `"on the right"`, `"click"`, `"see the"`), which nothing says to a blind user; you may use the word list `A10AccessibilityTests.testNoneOfTheseHintsNamesAGestureAClickOrASign` (TextMouthProductionTests/A10AccessibilityTests.swift:226-257) as a starting point. Keep the list in one constant.

## Measure before you finish

Run `python3 Scripts/test/a11y-lint.py --all` and read the per-rule counts and a sample of each rule's hits. A rule whose hits are mostly false positives must be refined or demoted to REVIEW; a REAL defect in existing code stays in the audit and goes in your report as a finding (file:line, one line each, at most 15; the lead passes them on). Do NOT edit any app file. Then prove the added-lines mode as `trap-lint` did: an untracked temporary Swift file under `TextMouth/Views/` with one hit per rule (delete it afterwards), run with no `--all`, and see exactly those lines reported and exit status 1.

## Commits

1. `a11y-lint.py` with the ERROR rules and its `--selftest` (one must-hit and one must-not-hit snippet per rule, a `lint-ok` case).
2. The REVIEW rules and their selftest cases.

## Report (at most 15 lines)

Branch; commits; per-rule counts from `--all`; the real findings; the runtime of `--all`; what you could not verify.
