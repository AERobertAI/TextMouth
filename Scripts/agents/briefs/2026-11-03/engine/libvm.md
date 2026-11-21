# Task engine-libvm: the library view models and the export model

You are worker `engine-libvm` of team `engine` (lead `engine-lead`). Read `Scripts/agents/briefs/2026-11-03/ios0-common.md` (the pattern; its rules override this brief) and `team-engine.md` beside it. Branch: `git checkout -b engine/libvm team/engine`.

## Files and goal

`TextMouth/ViewModels/`: `LibraryViewModel.swift` (5 errors), `LibraryViewModel+Cloud.swift` (13), `+Migration.swift` (4), `+ReadingList.swift` (3), `+Import.swift` (2), `+IndexRecovery.swift` (2), `+Duplicates.swift` (1), `BookExportModel.swift` (5). Done when the census shows none of these files. The errors are pasted at the end.

## Decisions (settled; do not reopen)

1. **`NSWindow` becomes `PlatformWindow`** (Platform/PlatformTypes.swift) in every parameter, property, and cast. On the Mac it is the same type. Do not change what a method does with the window.
2. **`NSApp`, `NSApplication`, `NSAlert`, `NSOpenPanel`, `NSWorkspace` calls** go behind `#if os(macOS)` ... `#else` ... `#endif`, the Mac text unchanged character for character.
   - **Never take a name away from iOS that a file you do not own uses.** Before you wrap a whole method, `grep -rn "methodName" TextMouth --include='*.swift'`: if a Views file or another type calls it, the `#else` branch keeps the method with the same signature and does the least it safely can (returns `nil`, `false`, an empty result, or does nothing), with a comment. Only a method that nothing outside the Mac's code calls may be left out on iOS.
   - A panel (`NSOpenPanel` in LibraryViewModel+Import.swift:229 and BookExportModel.swift:495) is a Mac way to choose files; its iOS twin returns "no choice" (`nil` or an empty array, whichever the Mac's cancel returns).
   - An alert that asks a question and reads the answer (IndexRecovery, Migration): on iOS the `#else` takes the answer that does the least (the cancel/safe choice the Mac's alert would give if dismissed), and says so in a comment. No destructive default on iOS.
   - `NSWorkspace` openers (revealing in Finder, opening a URL) do nothing on iOS, or use `UIApplication.shared.open` only if that is a one-line, `@MainActor`-safe call.
3. The enum cases that fail as "cannot infer contextual base" (`.keepOnThisMac`, `.downloadNow`, `.keptBookRefresh`) are knock-on errors of the `NSWindow` ones: recheck after fixing those.
4. The `.medium` error in `+ReadingList.swift:119` and `+Duplicates.swift:459` is `VoiceOverAnnouncer.announce(priority:)`, which a11y's team handles (finding posted to `a11y-lead`). Make no edit for those; if they remain, say so in your report.
5. No `@unchecked Sendable`, no `nonisolated(unsafe)`, no traps. Comment every new branch.

**PlatformApplication (new since the pattern was written).** `TextMouth/Platform/PlatformApplication.swift` offers `PlatformApplication.keyWindow`, `.mainWindow`, `.isActive`, `.didBecomeActiveNotification`, and `.didResignActiveNotification`: on the Mac each is exactly `NSApp.keyWindow`, `NSApp.mainWindow`, `NSApp.isActive`, `NSApplication.didBecomeActiveNotification`, `NSApplication.didResignActiveNotification` (the projection reads them as such), and on iOS each answers as well as phase 0 can. Use them in place of those AppKit expressions (rule 3, an alias); the old expressions then need no `#if`. Other `NSApp`/`NSApplication` uses still go behind `#if os(macOS)`.

## Mac test areas to request from the train

`library`, `cloud` (name the classes of the files you touch: `ls TextMouthTests TextMouthProductionTests | grep -i "LibraryViewModel\|BookExport"`).

## Watch for

This is the app's largest view model; the Mac text must not change. `engine-readervm` works beside or after you on the reader's view models: touch none of the `ReaderViewModel*` or `Transcript*` files. Some of the files you change are called with `from window: NSWindow?` by views owned by other teams (`shell`, `a11y`); a `PlatformWindow?` parameter accepts their `NSWindow?` on the Mac, so nothing there changes.

## The census's errors for your files (35; census of 72d9f5cd)

```
TextMouth/ViewModels/BookExportModel.swift:366:40: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/BookExportModel.swift:495:65: error: cannot find type 'NSOpenPanel' in scope
TextMouth/ViewModels/BookExportModel.swift:496:21: error: cannot find 'NSOpenPanel' in scope
TextMouth/ViewModels/BookExportModel.swift:511:41: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/BookExportModel.swift:513:20: error: cannot find type 'NSApplication' in scope
TextMouth/ViewModels/LibraryViewModel+Cloud.swift:260:43: error: cannot find 'NSApplication' in scope
TextMouth/ViewModels/LibraryViewModel+Cloud.swift:530:66: error: cannot find 'NSWorkspace' in scope
TextMouth/ViewModels/LibraryViewModel+Cloud.swift:547:93: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/LibraryViewModel+Cloud.swift:574:75: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/LibraryViewModel+Cloud.swift:585:75: error: cannot infer contextual base in reference to member 'keepOnThisMac'
TextMouth/ViewModels/LibraryViewModel+Cloud.swift:592:52: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/LibraryViewModel+Cloud.swift:614:22: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/LibraryViewModel+Cloud.swift:662:53: error: 'nil' requires a contextual type
TextMouth/ViewModels/LibraryViewModel+Cloud.swift:662:67: error: cannot infer contextual base in reference to member 'keptBookRefresh'
TextMouth/ViewModels/LibraryViewModel+Cloud.swift:701:79: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/LibraryViewModel+Cloud.swift:702:61: error: cannot infer contextual base in reference to member 'downloadNow'
TextMouth/ViewModels/LibraryViewModel+Cloud.swift:752:22: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/LibraryViewModel+Cloud.swift:879:87: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/LibraryViewModel+Duplicates.swift:459:28: error: cannot infer contextual base in reference to member 'medium'
TextMouth/ViewModels/LibraryViewModel+Import.swift:229:43: error: cannot find type 'NSOpenPanel' in scope
TextMouth/ViewModels/LibraryViewModel+Import.swift:230:21: error: cannot find 'NSOpenPanel' in scope
TextMouth/ViewModels/LibraryViewModel+IndexRecovery.swift:402:9: error: cannot find 'NSApplication' in scope
TextMouth/ViewModels/LibraryViewModel+IndexRecovery.swift:402:40: error: 'nil' requires a contextual type
TextMouth/ViewModels/LibraryViewModel+Migration.swift:2491:37: error: cannot find 'NSWorkspace' in scope
TextMouth/ViewModels/LibraryViewModel+Migration.swift:2495:21: error: cannot find 'NSWorkspace' in scope
TextMouth/ViewModels/LibraryViewModel+Migration.swift:2504:21: error: cannot find 'NSApplication' in scope
TextMouth/ViewModels/LibraryViewModel+Migration.swift:2504:52: error: 'nil' requires a contextual type
TextMouth/ViewModels/LibraryViewModel+ReadingList.swift:68:67: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/LibraryViewModel+ReadingList.swift:89:72: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/LibraryViewModel+ReadingList.swift:119:24: error: cannot infer contextual base in reference to member 'medium'
TextMouth/ViewModels/LibraryViewModel.swift:486:34: error: cannot find 'NSWorkspace' in scope
TextMouth/ViewModels/LibraryViewModel.swift:621:59: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/LibraryViewModel.swift:630:78: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/LibraryViewModel.swift:641:69: error: cannot find 'NSWorkspace' in scope
TextMouth/ViewModels/LibraryViewModel.swift:642:40: error: cannot find 'NSWorkspace' in scope
```
