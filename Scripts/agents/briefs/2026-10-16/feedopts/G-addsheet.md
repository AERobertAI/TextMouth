# Task G, `feedopts-addsheet`: the Add to Library choices and their sheet (FR20, part one)

Branch `feedopts/addsheet`. Read `00-contract.md` first, then the addendum `Scripts/agents/briefs/2026-10-16/team-feedopts-fr20.md` (the user's words and the orchestrator's design, items 1 to 6). **Build the choices, the sheet, and the model that runs a choice only after the sheet has gone. Do not touch `LibraryView.swift`**: task H puts the toolbar button there and replaces the three it stands for. Your tests host the sheet directly.

## The five choices, defined once

New `TextMouth/Models/AddToLibraryChoice.swift`: `enum AddToLibraryChoice: CaseIterable, Identifiable, Equatable, Sendable` with cases in this order (the order the sheet lists them): `openBook`, `importFolder`, `newFromText`, `newRecording`, `addFeed`. Each has:
- `action: ShortcutAction`: `.openBook`, `.importDAISYFolder`, `.newFromText`, `.newRecording`, `.addFeed` (`KeyboardShortcut.swift:97-106`);
- `title: String` = `action.title` ("Open Book…", "Import Folder…", "New from Text…", "New Recording…", "Add Feed…"): the sheet and the menus say the same words, and a rename of an action reaches the sheet;
- `summary: String`: one line, shown under the button and given as its accessibility hint (`AddToLibraryWording`, below);
- how it runs, as a case of a small `AddToLibraryRun` enum: `.notification(Notification.Name)` for `openBook` (`.openBookFile`), `importFolder` (`.importDAISYFolder`), `newFromText` (`.newFromText`), `addFeed` (`.addFeed`), and `.recordingWindow` for `newRecording`. These are exactly what the menus run: File > Open Book…, Library > Import Folder…, File > New from Text…, Library > Add Feed… post those notifications (`MenuCommands.swift:~100-110, 291, 319`), and File > New Recording… calls `RecordingWindowController.shared.show(library:)` (`MenuCommands.swift:104`). **A later "Import from URL…" is one more case here**, nothing else (say so in the type's comment).

New `TextMouth/Models/AddToLibraryWording.swift` (`enum AddToLibraryWording`, every string a constant or a function with a doc comment, each pinned by a test):
| | |
| --- | --- |
| `sheetTitle` | "Add to Library" (the heading, with the header trait, and the navigation title) |
| `buttonTitle` | "Add to Library" (the toolbar button's title; task H uses it) |
| `buttonLabel` | "Add to Library" |
| `buttonHint` | "Opens a sheet with the ways to add to the library: open a book, import a folder, make a book from text, record audio, or add a feed" |
| `cancel` | "Cancel" |
| `summary(.openBook)` | `LibraryView.importBookHint`: "Opens a file picker to import books in any format TextMouth reads." (reuse the pinned constant, `LibraryView.swift:1726`; do not copy its text) |
| `summary(.importFolder)` | "Chooses a folder that holds a DAISY book or audio tracks and imports it as one book." |
| `summary(.newFromText)` | "Makes a new book from text you paste or type." |
| `summary(.newRecording)` | "Records from a microphone into a new audiobook." |
| `summary(.addFeed)` | `FeedWording.addFeedButtonHint`: "Opens a sheet where you type a feed's address and choose where its folder goes" (reuse the constant, `FeedWording.swift:26`) |
| `unavailableHint(choice)` | "<summary> Not available in this window." (said when a choice is dimmed) |
| `label(choice, key: String?)` | the button's spoken label: the title, then, when a key is in force, " " and the key in words (`KeyBinding.accessibleDisplayString`, `KeyboardShortcut.swift:~770`), e.g. "Open Book…, Command + O" |

## The model and the sheet

New `TextMouth/Views/Library/AddToLibrarySheet.swift`:
- `@MainActor final class AddToLibraryModel: ObservableObject`: `init(isEnabled: @escaping (AddToLibraryChoice) -> Bool, perform: @escaping (AddToLibraryChoice) -> Void)`; `@Published var isPresented`; `func choose(_ choice: AddToLibraryChoice)` (ignored when `!isEnabled(choice)`; records the choice as pending and sets `isPresented = false`); `func cancel()` (sets `isPresented = false`, nothing pending); `func sheetDidDismiss()` (runs the pending choice exactly once through `perform`, then forgets it; does nothing when none is pending). **A choice runs only after the sheet has gone**, so a sheet it opens (New from Text, Add Feed) or the file panel (Open Book…) is not refused by SwiftUI while this one closes: the owner passes `onDismiss: model.sheetDidDismiss` to `.sheet(isPresented:onDismiss:)` (as `.sheet(isPresented: $showMoveSheet, onDismiss: sayWhatTheMoveLeft)` does in `LibraryView.swift:593`). Document this contract on the type.
- `struct AddToLibrarySheet: View`: the heading; then one `Button` per choice, in order; each shows the title (and the key in words beside it, when `keyDescription(choice)` returns one) with the summary under it in a smaller secondary style, is a single accessibility element (label from `AddToLibraryWording.label`, hint the summary, or `unavailableHint` when dimmed), and is dimmed when `!model.isEnabled(choice)`; then a Cancel button that Escape reaches (`.keyboardShortcut(.cancelAction)`). Parameters: `model`, `keyDescription: (AddToLibraryChoice) -> String?`. Fixed frame (`.frame(width: 420)` and a height that fits five rows, with a `ScrollView` only if it cannot), because a view that outgrows its hosting window crashes the test host (`AccessibilityTestSupport.swift`, read `withHostedView`'s comment). Every control keyboard-operable by Tab and Space; nothing by sight alone. Take the initial VoiceOver focus the way `NewFolderSheet` and the other sheets in `LibrarySheetViews.swift` do (read `:219-280` and how they request focus), on the first choice.
- "Enabled only where its menu command works" (FR12's branch E, `MenuCommands.swift:66-80, 694-698`): a production helper `AddToLibraryChoice.isEnabled(under shortcuts: KeyboardShortcutManager, in kind: ShortcutWindowKind?) -> Bool` = `shortcuts.scope(of: action).admitsMenuCommand(in: kind)` (the call `menuCommandKey` makes), unit-tested with a scope that excludes Library windows. A key in words for a choice: `shortcuts.keyEquivalent(for: action)?.accessibleDisplayString`, in a helper `AddToLibraryChoice.keyDescription(under:)`, tested.

## Tests (new `TextMouthProductionTests/AddToLibraryTests.swift`, needs `xcodegen generate`, `project.pbxproj` committed with it)

1. The choices: five, in this order, each titled by its action, each with its run; every wording string pinned; the summaries reuse the two constants.
2. The model: `choose` closes (`isPresented` false) and runs nothing until `sheetDidDismiss()`; then runs the choice once, and a second `sheetDidDismiss()` runs nothing; `cancel()` closes and runs nothing, even after `sheetDidDismiss()`; a dimmed choice is ignored; choosing twice before the dismissal runs only the last once.
3. The hosted sheet (`withHostedView` and `descendants(of:as:)`, `AccessibilityTestSupport.swift`; read how `FeedUICommandsTests.swift:443-490` hosts a sheet): the five buttons in order with their titles; Cancel; a dimmed choice disabled; pressing a choice's button calls `model.choose`; Escape reaches Cancel (the button's key equivalent, or as `FeedUICommandsTests` proves Escape reaches Done).
4. The helpers `isEnabled(under:in:)` and `keyDescription(under:)`, with a `KeyboardShortcutManager` built as `ShortcutsSettingsTabTests` or `MenuKeyShortcutTests` build one.
5. A choice and its menu command cannot drift apart: for the four choices that post a notification, the `action`'s `notificationName` (`KeyboardShortcut.swift:~262-300`) equals the choice's notification; for New Recording, the action's `notificationName` is `actsWithoutNotification` and the choice's run is `.recordingWindow`.

## Tests to run

`AddToLibraryTests`, `MenuKeyShortcutTests`, `ShortcutsSettingsTabTests`, `A10AccessibilityTests` (it pins `LibraryView.importBookHint`).

## Commits

1. The choices, the wording, and their tests (1, 5).
2. The model with its tests (2, 4).
3. The sheet with its hosted tests (3).

## Do not touch

`LibraryView.swift`, `MenuCommands.swift`, `ContentView.swift`, `FeedWording.swift`, `RecordingWindowController`, every existing test.
