# libpolish/letterkeys: Speak Info on Shift-Command-I, and letters alone jump in a Library window

Worker slug `libpolish-letterkeys`, branch `libpolish/letterkeys` made from `team/libpolish`. Lead: `libpolish-lead`. Read `Scripts/agents/briefs/2026-10-17/teams-common.md`, "The worker's part", and follow it.

## What the user said (October 17)

"I noticed that "i" in the library view said the info instead of using letter jump navigation to move to the first book of that letter... Maybe all library view shortcuts should by default require cmd ... and have letter navigation take priority", and then: "Is cmd+shift+i mapped to anything? I would rather have it as that and twice for full info, go ahead and change it in the reader too to be consistant".

## What the lead found (do not repeat this work)

- **Letter navigation is the list's own type-select** (the SwiftUI `List`'s `NSTableView`). The shortcut manager's local key monitor (`KeyboardShortcutManager.swift:566-622`) meets every key first and hands it to `ShortcutPressDispatcher.handle(_:)`, which consumes any key its index holds for the window's kind.
- **The defaults that are a letter with no modifier**, outside the audio editor: K (Play / Pause), J (Skip Backward), L (Skip Forward), F and B (the navigation-unit cycles), W and W twice (Where Am I?), and I and I twice (Speak Info, Speak Full Info). All work in every window (`ShortcutScope.app`). Space is Play / Pause too, and stays.
- **The press's kind.** A Library window is `.library`, and so is a sheet over one (`KeyboardShortcutManager.windowKind(ofKeyWindow:)`, :673-713). A plain titled test window with no identifier is a Library window too (`MenuVisibilityManager.detectWindowType`, the fallback), which is why some manager tests below change.
- **Shift-Command-I is free.** No default or menu item holds it, and it is no system command (`KeyBinding.systemCommands`). Book Info keeps Command-I, and the audio editor's Mark In keeps I in its own scope.
- **Speak Info acts only in a Library window.** Only `LibraryView` takes `.speakInfo` (:705-712). Its scope stays every window, as the user asked for the reader too, so its key does nothing in a reader, as I does now.
- **Unedited actions follow the defaults** (`formerDefaultBindings`'s doc, `KeyboardShortcut.swift:1628-1638`). config.json's "default: i" words are never read back (`ShortcutListing`, :1212-1222). So a new default reaches every listener who never changed these actions, this user included. One who changed them keeps their keys, and nothing needs migrating.
- **The rule this brief sets** (the lead's decision). In a Library window, and in a sheet over one, a letter pressed with no modifier at all, once or twice, never runs a shortcut: TextMouth's defaults and the listener's own alike. It goes on to the list, or to the sheet's control. A letter with Shift, Option, Command, or Control still acts there. This user's own Shift-R for Release Media Controls keeps working in Library windows, and Shift-J and Shift-L no longer fall back to J's and L's actions there.

## The change (two commits)

### Commit 1: Speak Info and Speak Full Info default to Shift-Command-I and Shift-Command-I twice

1. `TextMouth/Models/KeyboardShortcut.swift:1557-1567`: `.speakInfo: [KeyBinding(key: "i", command: true, shift: true)]` and `.speakFullInfo: [KeyBinding(key: "i", command: true, shift: true, isDoublePress: true)]`. Rewrite the two comments: the user chose Shift-Command-I on October 17, so that a letter alone jumps to books in a Library window; Book Info keeps Command-I; twice for the full summary, the dispatcher comparing whole strokes, modifiers included. Update `speakFullInfo`'s case doc (:58-60, "I twice by default").
2. Comments only, naming the new keys where they name I: `TextMouth/App/MenuCommands.swift:348-358` and `:788-795`; `TextMouth/Views/Library/LibraryInfoRow.swift:5`; `TextMouth/Models/LibraryInfoWording.swift:93-94`. Leave `LibraryView.swift` to the lead.
3. Tests changed on purpose (each named in your report, with why: the defaults moved):
   - `SpeakInfoShortcutTests`: every test (:1-70) and the class doc, for Shift-Command-I. Pin its `displayString` "⇧⌘I", its `accessibleDisplayString` "Shift + Command + I", and its `configText` as `configText` writes it. No app action holds a letter I alone by default, only the editor's Mark In. From a text field Shift-Command-I acts, as Command-I does (`shouldHandle`), while typing an I types. An older custom Shift-Command-I on another action keeps it, and Speak Info goes without.
   - `FullSummaryActionTests` (:19, :60-63), `ShortcutListingTests` (:153), `ShortcutMigrationTests` (:119-121), `ShortcutEditsTests.testANewDefaultNeverTakesAKeyAnEditedActionHolds` (:146-156; put Shift-Command-I on Where Am I? there), `ShortcutConfigFileTests` (:211-212, :323-324, :405-436): the new keys and their "default: …" words.
   - `DoublePressBindingTests` (:100-116): its "default: i" entries are an older file's, whose words are never read. Leave them unless the test compares what is written.
   - `ShortcutPressDispatcherTests.testIAndWTwiceSwitchToTheFullSummariesWithoutWaiting` (:111-132): Shift-Command-I in place of I, the name to match. This pins the escalation with the new key.
   - `LibraryInfoSpeakerTests`: only the comments and failure messages that name the I key (it posts notifications, so its behavior does not change).

### Commit 2: a letter alone goes to letter navigation in a Library window

4. In `KeyboardShortcut.swift`, after the `isDialogKey` extension (ends :714), add `extension KeyBinding { var isLetterAlone: Bool }`. It is true when `key` is one character that is a letter (`key.count == 1 && key.first?.isLetter == true`) and none of `command`, `option`, `shift`, `control` is held, single or double press. Add `ShortcutWindowKind.navigatesByLetter: Bool` (the enum is at :488-500), true for `.library` alone. Doc both, quoting the user's "have letter navigation take priority".
5. `TextMouth/Services/ShortcutPressDispatcher.swift`, `Index.init` (:421-465): in the loop over kinds (:433), skip a binding whose `stroke.isLetterAlone` in a kind that `navigatesByLetter`, with a comment. Every lookup then follows: presses, waits (`waitingKeys`, `KeyboardShortcutManager.waitingAction(for:in:)`), and the Shift fallback in `match(_:)`. Add a bullet to the type's doc list (:25-58) saying the rule in a sentence.
6. `TextMouth/Views/Settings/KeyboardShortcutsSettingsView.swift`: add `static let letterNavigationNote = "In Library windows, a letter pressed alone moves to the first book or folder whose name starts with it, so a shortcut that is a letter alone, such as W, works only in other windows."` to `ShortcutsSettingsWording` (:414+), with a doc. Show it as `Text` in the first `Section` (:18-31), after the trial status.
7. **New tests** in `ShortcutPressDispatcherTests`, a `// MARK: - Letters in Library Windows` section:
   - With the defaults, in a `.library` press, W, J, K, L, F, and B each match nothing and are not consumed; in a `.reader` press each runs its action (Where Am I?, Skip Backward, Play / Pause, Skip Forward, and the two cycles); Space plays and pauses in both. Shift-J matches nothing in `.library`. Use `Harness(ShortcutAction.defaultBindings, …)` and `press(_:at:kind:)` (:1109-1118).
   - A letter the listener binds alone (Q on Where Am I?) acts in a reader and not in a Library window. Shift-Q and Option-Q bound to it act in both.
   - `isLetterAlone`: true for "w" and "w twice", and for a non-Latin letter such as "é". False for "space", "1", ",", "w" with Shift, and "w" with Command.
   - Through the manager: `handleKeyEvent` of a plain W in `makeShortcutWindow(.library)` (`ShortcutKeyPressSupport.swift:71`) returns false and posts nothing; in `makeShortcutWindow(.reader)` it returns true and posts Where Am I?. Build events with the support file's helpers.
   - In `ShortcutsSettingsTabTests`: `letterNavigationNote`'s exact words.
8. **Tests changed on purpose** (each named in your report, with why: a letter alone no longer acts in a Library window):
   - `testTheIndexHoldsEachKeysTwoActionsByScope` (:445-460): plain J has no actions in `.library`. Assert its actions in `.reader`, and drop `.library` from `waitingKeys`.
   - `testTheManagerPostsWhatTheDispatcherDecides` (:468-508): its `makeWindow()` counts as a Library window. Press J in `makeShortcutWindow(.reader)`.
   - `testTheManagerPostsTheBriefSummaryThenTheFullOne` (:134-160): W twice in a reader window; Shift-Command-I twice in a Library window, which shows the new key acts there.
   - Any other existing test that fails: stop and ask your lead (rule 6).

## Tests to run (only these; `python3 Scripts/test/run-area.py shortcuts LibraryInfoSpeakerTests AddToLibraryTests` with `BBS_AGENT=libpolish-letterkeys`)

The `shortcuts` area holds `KeyboardReachabilityTests`, `ShortcutMigrationTests`, `ShortcutPressDispatcherTests`, `MenuKeyShortcutTests`, `SpeakInfoShortcutTests`, `TextFieldEditingKeysTests`, `WindowScopeShortcutTests`, `ShortcutsSettingsTabTests`, and the legacy `LegacyKeyboardShortcutScenarioTests`. Log to `/private/tmp/claude-501/-Users-roberteggleston-programming-ai-claude-swift-TextMouth/8d971e15-7103-46cf-b45e-5c4d099f2f74/scratchpad/libpolish-letterkeys-<n>.log` (`--log`). Before you report, run `make lint-tests LINT_BASE=team/libpolish` and `make lint-a11y LINT_BASE=team/libpolish`.

## Completion check (must print nothing but the editor's Mark In)

    grep -rn 'KeyBinding(key: "i")' TextMouth

## Do not touch

`LibraryView.swift`, `LibrarySheetViews.swift`, `LibrarySubviews.swift`, `ReadingListWording.swift`, `MoveToLibrarySheet.swift`, any `*.md` file, the audio editor's defaults, and `ShortcutScope`'s scopes. Other teams own `FileImportService.swift`, the parsers, `FeedDownloadManager.swift`, and `LibraryPersistenceService.swift`.
