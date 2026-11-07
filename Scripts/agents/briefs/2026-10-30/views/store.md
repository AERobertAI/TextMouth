# Task `store`: keeping the Library views in the preferences and config.json (team `views`, October 30, 2026)

Slug `views-store`, branch `views/store` from `team/views`. Read `Scripts/agents/briefs/2026-10-30/teams-common.md` ("The worker's part", "Rules for everyone", "The board", "Builds"), then this brief. The design is `LIBRARY-VIEWS-RESEARCH-2026-10-30.md` at the worktree's root: read section 8. The model is on the team branch: `TextMouth/Models/LibraryViewDefinitionList.swift` (read whole: `fileKey`, `init(fileEntries:logRepairsAs:)`, `fileEntries`, the operations) and `TextMouth/Models/LibraryViewDefinition.swift` (skim).

## What you build

The observable owner of the list, kept in the preferences store and mirrored in config.json like every portable preference. No UI uses it yet, so behavior does not change, except that config.json gains the `libraryViews` key at its next save. One or two commits.

The `braillecodes` team edits `SettingsViewModel.swift` and `ConfigService.swift` tonight too: before editing, read the board's claims (`bbs claims`) and claim only the lines you add; add your lines next to the braille table's lines, in your own statements, never editing theirs.

### 1. `TextMouth/Models/LibraryViewDefinitionStore.swift` (new)

```swift
/// The Library's views, as the preferences store keeps them under "libraryViews" and config.json
/// mirrors them (design section 8): what Library windows and the Library settings tab read and change.
@MainActor
final class LibraryViewDefinitionStore: ObservableObject {
    /// The store the app uses: its preferences (`TextMouthRuntime.current.preferences`, which a
    /// process hosting tests keeps in its sandbox).
    static let shared = LibraryViewDefinitionStore(preferences: TextMouthRuntime.current.preferences)

    /// The list in the preferences store: the JSON array config.json holds, as data, written with
    /// sorted keys; the shipped list while none is saved or what is saved cannot be read as an array.
    /// Reading logs nothing: TextMouth wrote what the store holds.
    nonisolated static let preference: StoredPreference<LibraryViewDefinitionList>

    /// The list now. Published only when it changes.
    @Published private(set) var list: LibraryViewDefinitionList

    /// A store reading and writing `preferences`, following every change of the key there, whoever
    /// makes it (the settings model applying config.json, another store on the same preferences), so
    /// `list` always shows what is saved.
    init(preferences: UserDefaults)

    /// Changes the list with `change`, saves it when it changed, and returns what `change` returned:
    /// the operations' Bool, for the words said after them.
    @discardableResult
    func update<Result>(_ change: (inout LibraryViewDefinitionList) -> Result) -> Result
}
```

Follow the pattern of `StoredPreference` and `PreferenceObserver` in `TextMouth/Models/StoredPreference.swift` (read it whole) and of a group of preferences such as `FeedSettings` (`TextMouth/Models/FeedSettings.swift:1-120`). The observer's handler re-reads the preference and assigns `list` only when it differs. Never `@unchecked Sendable` or `nonisolated(unsafe)`.

### 2. config.json (`TextMouth/Services/ConfigService.swift`)

- `AppConfig` (lines 224-430): `var libraryViews: [JSONValue]?` in "Fields added after the file first shipped", with a doc comment saying what it holds and that nil or an empty array leaves the views as they are (design section 8).
- The decoder (`init(from:)`, about line 437-540): `libraryViews = fields.optionalValue(.libraryViews) { (entries: [JSONValue]) in entries.isEmpty ? nil : entries }`. Bounds are the list's (`LibraryViewDefinitionList.init(fileEntries:logRepairsAs:)`), not repeated here.
- `Portability.mirrored` (about line 590-660): `mirrored += sameNames([LibraryViewDefinitionList.fileKey])`, under a comment "Library (October 30, 2026): the Library window's views, which the views store keeps." after the braille line.

### 3. The settings model (`TextMouth/ViewModels/SettingsViewModel.swift`)

- `servicePreferenceKeys` (line 864): add `LibraryViewDefinitionStore.preference.key` (keep the two-part sum; the compiler needs it).
- `writeServicePreferences(into:)` (about line 1000-1035): `config.libraryViews = LibraryViewDefinitionStore.preference.read(from: preferences).fileEntries`.
- `adoptServicePreferences(from:)` (about line 1040-1118): `adopt(config.libraryViews.map { LibraryViewDefinitionList(fileEntries: $0, logRepairsAs: "config.json") }, into: LibraryViewDefinitionStore.preference)`, with a comment that the list reads each entry on its own, keeps the unreadable ones, and logs its repairs.
- Not in `shownServicePreferenceKeys`: the views store observes the key itself.

## Tests

1. New `TextMouthProductionTests/LibraryViewDefinitionStoreTests.swift`, on a sandboxed preferences store of its own (see how `FeedSettingsTests` or `ConfigSyncTests` make one; never the standard store), `@MainActor` per test as `UnopenedCategoryTests` explains:
   - a new store reads the shipped list; `update` saves, and a second store on the same preferences reads the change; `update` that changes nothing writes nothing (the preference's data is unchanged) and publishes nothing;
   - a change written to the preferences by another writer reaches `list` (the observer);
   - data that is not a JSON array reads as the shipped list; unreadable entries survive a round trip through the store.
2. The config and settings tests, extended where they enumerate every config.json field: `OnDiskContractTests.testConfigJSONHoldsExactlyTheseKeys` gains "libraryViews" in its expected set and `configWithEverySettingSet()` sets it (a list with a custom view), as `brailleTable` was added; the Portability round-trip tests (`ConfigSyncTests` and the others `grep -ln Portability TextMouthProductionTests/*.swift` lists) gain the key where they list fields or need a value that differs from the default. Say in your commit message which existing tests you extended and that the change is the new key alone. Change no assertion about any other key.
3. A config.json with `libraryViews` reaches the store through the settings model (adopt), with a repair logged as config.json's; a change in the store reaches config.json (write); a config.json without the key, as an older TextMouth writes it, leaves the store's list as it is.

## Build and test

- `/opt/homebrew/bin/xcodegen generate` for the new test file; commit `project.pbxproj` with it. Add the class to the `[settings]` area of `Scripts/test/areas.conf`, on its own line, moving no other line.
- `BBS_AGENT=views-store python3 Scripts/test/run-area.py LibraryViewDefinitionStoreTests OnDiskContractTests ConfigSyncTests ConfigWatcherTests ConfigSaveCoalescingTests FeedSettingsTests DataDirectoryPreferencesTests DataDirectoryConfigTests ShortcutConfigFileTests AudioEditorSettingsTests UncheckedConcurrencyPolicyTests LogContentPolicyTests` and every other class `grep -rln "AppConfig\|Portability\|servicePreferenceKeys" TextMouthProductionTests` lists, in the background, checking no more than every four minutes.
- `make lint-tests LINT_BASE=team/views`; no new Swift warning.
- When done: `BBS_AGENT=views-store python3 Scripts/test/run-area.py --clean`.

## Do not touch

Anything else; no `*.md` file. In the shared files, only the lines named here.
