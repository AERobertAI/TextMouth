# Task H, `feedopts-addbutton`: one "Add to Library" toolbar button replaces three (FR20, part two)

Branch `feedopts/addbutton`. Read `00-contract.md`, then the addendum `Scripts/agents/briefs/2026-10-16/team-feedopts-fr20.md` (items 1, 3, 5, 6 are this task). Task G is on the team branch (`AddToLibraryChoice`, `AddToLibraryWording`, `AddToLibraryModel`, `AddToLibrarySheet`, `AddToLibraryChoice.isEnabled(under:in:)`, `keyDescription(under:)`), and task F (the Folder/Feed Settings button) too, in the same toolbar: keep its button and everything else about the toolbar exactly as it is. **Replace the Import, New from Text, and Add Feed toolbar buttons with one button, "Add to Library", that opens G's sheet; a choice runs only once the sheet has closed.**

## What exists (read by line range)

- `TextMouth/Views/Library/LibraryView.swift:493-555` (the toolbar; after F the line numbers have moved, find them by the code): the Up One Level button; `importBookButton(focusTarget:)` (defined `:1730-1745`, with `LibraryFocusTargetModifier` after it, and `importBookHint` `:1726`, which G reuses: **keep that constant and its text**, `A10AccessibilityTests.swift:493` pins it); the New from Text button (`showTextInput = true`, hint "Create a new book by pasting or typing text"); the Add Feed button (posts `.addFeed` naming this window as `sourceWindow`, labelled with `FeedWording.addFeedToolbarTitle`, `addFeedButtonLabel`, `addFeedButtonHint`, `FeedWording.swift:20-26`); then Edit, New Folder, F's button, and the Sort menu.
- `LibraryFocusTarget` (`LibraryView.swift:58-66`): `.importButton` is where VoiceOver's focus starts in a window with no books (`WindowFocusPolicyTests.swift:109` pins the case's name). **Keep the case name**; the new button takes over its role: `focusTarget == .importButton` marks the Add to Library button as the initial VoiceOver target, as `LibraryFocusTargetModifier` marks the Import button now. Say so in the case's comment.
- The menus and what they run: File > Open Book… posts `.openBookFile`; New from Text… posts `.newFromText`; Library > Import Folder… posts `.importDAISYFolder`; Add Feed… posts `.addFeed`; New Recording… calls `RecordingWindowController.shared.show(library:)` (`MenuCommands.swift:90-110, 291-321`). `ContentView.takeGlobalAction` (`ContentView.swift:301-345`) presents the file panel, the New from Text sheet, and the folder panel on the window the router chose (`LibraryWindowRouter.swift:116-130`: the key window when it is a Library window, which this window is once its sheet has gone).
- `LibraryOrderCommandsSupport` (`LibraryView.swift:1952`): the style of a `ViewModifier` that owns a group of this window's commands.

## What to build

1. **The toolbar**: remove the three buttons (the Import button, New from Text, Add Feed); in their place, one button: `Label(AddToLibraryWording.buttonTitle, systemImage: "plus")`, `.accessibilityLabel(AddToLibraryWording.buttonLabel)`, `.accessibilityHint(AddToLibraryWording.buttonHint)`, carrying the `LibraryFocusTargetModifier` the Import button carried. Shown wherever any of the three was shown (they had no conditions; check). Rename `importBookButton` to `addToLibraryButton` and its comment; delete what is dead afterwards (`FeedWording.addFeedToolbarTitle` and `addFeedButtonLabel`, if nothing else reads them; keep `addFeedButtonHint`, G reuses it).
2. **The sheet**: a new `private struct LibraryAddToLibrarySupport: ViewModifier` in `LibraryView.swift` (or a file of its own under `Views/Library/`) holding `@StateObject` `AddToLibraryModel`, with `.sheet(isPresented: $model.isPresented, onDismiss: model.sheetDidDismiss) { AddToLibrarySheet(...) }`. The button sets `isPresented = true`. The model's two closures: `isEnabled` = `AddToLibraryChoice.isEnabled(under: shortcuts, in: .library)` (find the `KeyboardShortcutManager` and the window kind the menus use, `FrontWindowKind`/`ShortcutWindowKind`), `perform` = the **runner**:
   - `.notification(name)`: post it on the notification center the runner is given; for `.addFeed` also with `userInfo: ["sourceWindow": hostWindow]` when the window is known, as the old Add Feed button did (`LibraryView.swift:516-521`); the other three exactly as the menus post them (no `userInfo`);
   - `.recordingWindow`: `RecordingWindowController.shared.show(library: libraryViewModel)`.
   The runner is a small injectable type (`post: (Notification.Name, [AnyHashable: Any]?) -> Void`, `showRecordingWindow: () -> Void`), so **no test posts a real `.openBookFile`, `.importDAISYFolder`, `.newFromText`, or `.addFeed` or shows the recording window**: the test host is the app itself, and a real post could open a file panel on a live window. Production passes the default center and the controller.
   - `keyDescription` for the sheet comes from `AddToLibraryChoice.keyDescription(under:)`.
3. **Nothing else about the window changes**: the importer, the New from Text sheet, the Add Feed sheet, and the folder panel are presented by the same code as before, reached by the same notifications (`showFileImporter` stays a binding from `ContentView`).

## Tests (new `TextMouthProductionTests/AddToLibraryToolbarTests.swift`, needs `xcodegen generate`, `project.pbxproj` committed with it)

- The toolbar as drawn: host the Library window's view in a window and read its toolbar's items as `BookExportSheetTests.swift:298-330` reads a reader's, and `ViewsAndWindowsLibraryListTests.swift:114` constructs the view: "Add to Library" is there, once, and "Import Book", "New from Text", "Add Feed" are not. If the Library view's toolbar cannot be read that way, prove it through the pieces and say so in your report.
- The button's label, hint, and system image; the focus target role (the modifier is applied when `focusTarget == .importButton`, not otherwise).
- The runner: each of the five choices, chosen in the model and then dismissed, makes exactly one call of the runner with the notification the menu posts (`.openBookFile`, `.importDAISYFolder`, `.newFromText`, `.addFeed` with `sourceWindow`, and the recording call), after the sheet's `isPresented` has become false; Cancel and Escape run nothing; a dimmed choice runs nothing.
- The router picks this window: with `LibraryWindowRouter.handler(for:keyWindow:registeredLibraryWindows:readerWindows:)` (`LibraryWindowRouter.swift:216`) and two registered Library windows, the key one (this window) takes `.openBookFile`, `.newFromText`, and `.importDAISYFolder`.
- No old behavior lost: the sheets the three buttons opened are still opened by their notifications (the existing tests for `takeGlobalAction`, run unedited, show it).

## Existing tests that change on purpose

Any existing test that pins one of the three old toolbar buttons (their labels, hints, or presence): change it to the new behavior, **and list each such test and why in your report**. I found none by searching their strings, so expect none; if you find one, that is the report line. Any other failing test: stop and ask.

## Tests to run

`AddToLibraryToolbarTests`, `AddToLibraryTests`, `WindowFocusPolicyTests`, `A10AccessibilityTests`, `ViewsAndWindowsLibraryListTests`, `LibraryFolderSettingsTargetTests`, `IntegrationWindowRoutingTests`, `FeedUILibraryRowsTests`, `ReadingListViewTests`, `LibraryInfoSpeakerTests` (these build the Library view).

## Commits

1. The runner and the sheet's modifier, with their tests (nothing visible yet).
2. The toolbar button replacing the three, the dead constants removed, with its tests.

## Do not touch

F's toolbar button and shortcut, `AddToLibrarySheet.swift` and `AddToLibraryChoice.swift` (G's; post a finding if something there is wrong), `MenuCommands.swift` and the menus' items, `ContentView.swift`, `LibraryWindowRouter.swift`.
