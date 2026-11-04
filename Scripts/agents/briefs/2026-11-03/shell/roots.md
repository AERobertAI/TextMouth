# Task roots: the Library window's root views and the reader's command modifier

Slug `shell-roots`, branch `shell/roots` (from `team/shell`, after `shell/router` and `shell/app` are in it). Read `../ios0-common.md` first (the pattern and the worker's part), then this brief. The lead is `shell-lead`.

## Your files and their errors (41 in the census)

Census: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/typecheck/results/orchestrator-ios-census-72d9f5cd-1103-200441/errors.txt` (`grep -E "Views/ContentView|Library/LibraryView.swift|ReaderBookCommands"`). Run your own census first: the router task changed what is left.

- `TextMouth/Views/ContentView.swift` (13): `hostWindow: NSWindow?`, `NSApplication.shared.terminate(nil)`, `NSApplication.ModalResponse` in the DAISY panel handler (~412), `ImportOrigin(window:)` (a cascade), the `window:`/`windowNumber:` label errors at ~360 and ~409 (cascades from calls typed `NSWindow`), a type-check timeout at line 33 that goes with the `NSApplication` error.
- `TextMouth/Views/Library/LibraryView.swift` (16): `NSWindow` in `WindowCommandRouting` (lines ~21-60: `shouldAccept(sourceWindow:hostWindow:keyWindow:)`, `rootWindow(for:)`), `hostWindow` (~269), `as? NSWindow` (~1662); the rest are cascades (`StandardVoiceOverFocus` backgrounds, the `Binding` errors, the `announcingFrom` extra-argument errors at ~1521).
- `TextMouth/Views/Reader/ReaderBookCommands.swift` (12): `takesCommand` (lines ~238-246: `as? NSWindow`, `NSApp.keyWindow`), the rest cascades and a type-check timeout at line 63.

Edit only these three files and new files under `TextMouth/Platform/`.

## Decisions (settled)

1. **All three stay shared.** They are the window roots phase 1 will build on.
2. `NSWindow` type names become `PlatformWindow` (rule 3), everywhere in the three files.
3. `WindowCommandRouting.rootWindow(for:)` follows `sheetParent`, an AppKit-only property: keep the Mac body inside `#if os(macOS)` and give the `#else` an answer that is right for a window with no sheets (return `window`). `NSApp.keyWindow` in `takesCommand` and anywhere else: wrap the statement in `#if os(macOS)` … `#else` (nil for the key window) `#endif`, keeping the Mac text character for character.
4. ContentView's `NSApplication.shared.terminate(nil)` (the Quit button of the data-directory screen) and the DAISY folder panel (`presentDAISYFolderPanel`, `NSApplication.ModalResponse`): wrap in place. The iOS branch of Quit is an empty closure, of the panel a `return` (importing folders on iPhone is phase 1).
5. `bringToFront()` (`isMiniaturized`, `deminiaturize`, `makeKeyAndOrderFront`) is AppKit only: wrap its body. On iOS it does nothing.
6. The type-check timeouts ("unable to type-check this expression in reasonable time") are almost always cascades of an earlier error in the same expression; fix the AppKit error first, rerun the census, and only if one remains, tell `shell-lead`: breaking up an expression changes Mac code and needs a reason.
7. Errors that name another team's type (`ImportOrigin`, `announceDataDirectoryUnavailability(from:)`, `VoiceOverAnnouncer.announceAfterSheetCloses(_:from:)`) are theirs: if they still take `NSWindow` after their team's changes, post a finding with `--file` to `shell-lead`.

## The Mac must not change

`make mac-projection BASE=team/shell DIFF=1`: only `NSWindow` to `PlatformWindow` and wrappers.

## Tests to request from the train

Areas `library`, `windows`, `feeds`, `reading-list`, `sheets`; classes `AddToLibraryToolbarTests,IntegrationWindowRoutingTests`, and whatever tests `WindowCommandRouting` (`grep -rln WindowCommandRouting TextMouthTests TextMouthProductionTests`). `AddToLibraryToolbarTests` reads `LibraryView.swift` by path. Request once, after your last commit.

## Completion check

The census shows no error in your three files; `make typecheck-mac` shows 0 errors, 0 warnings.
