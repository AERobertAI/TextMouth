# a11y task `settingssheets`: Reader, Library, Settings, and Feeds sheets with the control styles

Slug `a11y-settingssheets`, branch `a11y/settingssheets` (from `team/a11y`, after `focus` and `textareas` are in). Read `../ios0-common.md` ("The worker's part", and the rules) and `../team-a11y.md` first.

## Files (census errors, 31 in all; many are cascades)

- `Views/Reader/ReaderView.swift` (6), `BookSearchView.swift` (1), `PlaybackControlsView.swift` (1)
- `Views/Library/FolderSettingsSheet.swift` (2), `ReadingListOptionsBar.swift` (1), `LibrarySubviews.swift` (1), `FeedItemBookInfoSheet.swift` (1)
- `Views/Feeds/FeedDownloadProgressSection.swift` (3), `AddFeedSheet.swift` (2), `OPMLImportSheet.swift` (4)
- `Views/Settings/StorageSettingsView.swift` (4), `DuplicateFinderView.swift` (2), `LibraryViewsSettingsView.swift` (2), `LibraryViewEditorSheet.swift` (1)

All paths are under `TextMouth/`.

## Mechanisms (decided)

1. **`NSWindow` becomes `PlatformWindow`** (rule 3): ReaderView.swift:645 and :659, FeedDownloadProgressSection.swift:102 and :117. `import AppKit` becomes the rule 2 form wherever a shared file here has it.
2. **Control styles (rule 4):** every `.toggleStyle(.checkbox)` becomes `.checkboxToggleStyle()` (FolderSettingsSheet:217, ReadingListOptionsBar:45, DuplicateFinderView:430 and :721, LibraryViewEditorSheet:69, BookSearchView:534), and AddFeedSheet:362 `.pickerStyle(.radioGroup)` becomes `.radioGroupPickerStyle()`.
3. **`NSApp.keyWindow`** is named `PlatformApplication.keyWindow` (`TextMouth/Platform/PlatformApplication.swift`, already on your branch; read it first): on the Mac exactly the old expression, so the swap is a platform alias in the projection's eyes, and it needs no `#if`. Apply it at ReaderView.swift:661 (`shouldAcceptPanelCommand`) and FeedDownloadProgressSection.swift:91. StorageSettingsView.swift:666 sits in `chooseFolder()`, which goes whole into `#if os(macOS)` (see 4). ReaderView.swift:645-650: `as? NSWindow` becomes `as? PlatformWindow` by rule 3. The engine lead asked shell for `WindowCommandRouting.shouldAccept(sourceWindow:hostWindow:keyWindow:)` on iOS (board #4872); if it is still missing, list it as a cascade.
4. **Panels:** a function that builds or runs an `NSOpenPanel` or `NSSavePanel` goes whole into `#if os(macOS)`, Mac text unchanged, and its iOS branch does nothing, with a comment that phase 1 uses a file importer:
   - OPMLImportSheet.swift `chooseOPMLFile(in:parentPath:)` (line ~328) and the save-panel function (line ~387): same signatures, empty on iOS.
   - StorageSettingsView.swift `makeLibraryFolderPanel(isLibraryAvailable:)` (Mac only, no iOS twin: only Mac tests call it; grep to confirm) and `chooseFolder()` (iOS: empty).
5. **Cascades, expected to clear on their own:** `background(... SilentKeyEquivalent ...)` (team shell's file), `background(... VoiceOverFocus ...)` and `StandardVoiceOverFocus` (the `focus` task), `'nil' requires a contextual type` in LibraryViewsSettingsView:316 and :398 (they pass `from: nil` to `VoiceOverAnnouncer.announce...`, which the `focus` task fixes), and LibrarySubviews.swift:152 ("unable to type-check in reasonable time", most likely the same cascade). Rerun the census after the real fixes; for any that remains, find its cause, make the smallest change that is one of the five kinds, and tell me.
6. Do not change any label, hint, or spoken sentence.

## Checks and tests

- Order: `make typecheck-ios CENSUS=1` until the fourteen files show only cascades; `make typecheck-mac`; `make mac-projection BASE=team/a11y DIFF=1`; `make lint-a11y LINT_BASE=team/a11y`.
- Train: areas `settings,feeds,library,sheets,accessibility`; classes that name `FeedDownloadProgressSection`, `OPMLImport`, `StorageSettings`, `DuplicateFinder`, `LibraryViewsSettings`, `AddFeedSheet`, `FolderSettings` (grep the test folders for each). Wait for the result.

## Completion check

The census shows none of the fourteen files except cascades from other teams' files, which you list.
