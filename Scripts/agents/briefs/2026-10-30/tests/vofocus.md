# Task `vofocus`: where VoiceOver lands when a window or sheet opens

Slug `tests-vofocus`, branch `tests/vofocus` from `team/tests`. Read `_common.md` beside this file first. Audit item U21 (`build/orchestrator/oct30/tests-audit-untested.md` in the main checkout). A VoiceOver user lands wherever these functions say in every new window; nothing a test names reaches them.

## The code
`TextMouth/Views/VoiceOverFocus.swift` holds TWO copies of the same search:
- `StandardVoiceOverFocusTriggerView`: `findFirstInteractiveElement(root:depth:)` (326-360) asks the tested policy `acceptsFallback(role:label:isScrollerPart:)` (176), and `findElementByIdentifier(_:root:depth:)` (374 on); `staticFindAndFocus(in:)` at 215.
- `VoiceOverFocusTriggerView`: `findFirstInteractiveElement` (644 on) takes the first `AXRow`, `AXCell`, `AXButton`, or `AXTextField` WITHOUT the policy (so an unlabeled button, or a scroller's part, can win), and its own `findElementByIdentifier` (677 on); `staticFindAndFocus(in:)` at 481.
Both stop below depth 15. `WindowFocusPolicyTests` (87-127) tests `acceptsFallback` alone.

## Step 1: tests of today's behavior, and the difference (no production change)
New class `VoiceOverFocusSearchTests` (new file, `xcodegen generate`), on an `NSView` tree in an offscreen window (VoiceOver is not needed; never order the window in): a scroll view with its scrollers, a text field, a button with a title, a button with no label, and a view whose `accessibilityIdentifier` is set deep in the tree. For each of the two classes (make an instance as the app does; read how each is created):
1. `findFirstInteractiveElement(root:depth: 0)` returns the element `acceptsFallback` picks, skipping the scrollers' parts and the unlabeled button (expected to FAIL today for `VoiceOverFocusTriggerView`; mark nothing yet).
2. It returns nil for an empty tree, and nil for a tree whose only interactive element is deeper than 15 levels.
3. `findElementByIdentifier` finds the deep view by its identifier, and returns nil when none has it.
Then read who uses each class (`grep -rn "VoiceOverFocusTriggerView\|StandardVoiceOverFocusTriggerView" TextMouth`) and whether the second's policy is deliberate (comments, git log -S). Post to `tests-lead`: which windows use the second search, what a VoiceOver user lands on there today when the first interactive element is an unlabeled button or a scroller part, and the fix you propose (one search shared by both, asking `acceptsFallback`, with any deliberate preference kept, such as rows first in a list). Wait for the answer (`bbs watch tests-vofocus --timeout 600`, repeated).

## Step 2 (once the lead confirms)
Make the two classes share ONE implementation of each search (DRY), behaving as confirmed, with the tests above passing for both and a test for the confirmed preference. Prove the shared search's tests fail when it skips the policy.

## Classes to run
`VoiceOverFocusSearchTests WindowFocusPolicyTests`, and every class that names `VoiceOverFocus` (`grep -ln "VoiceOverFocus" TextMouthProductionTests/*.swift`). Files: the new test file, `project.pbxproj`, and, in step 2, `TextMouth/Views/VoiceOverFocus.swift` (claim it then).
