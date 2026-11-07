# Task keys: the shortcut model, the manager, the dispatcher, and the Shortcuts tab

Slug `shell-keys`, branch `shell/keys` (from `team/shell`). Read `../ios0-common.md` first (the pattern and the worker's part), then this brief. The lead is `shell-lead`.

## Your files and their errors (82 in the census)

The census at `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/typecheck/results/orchestrator-ios-census-72d9f5cd-1103-200441/errors.txt` (yours: `grep -E "Models/KeyboardShortcut.swift|Services/KeyboardShortcutManager|Services/ShortcutPressDispatcher|Settings/KeyboardShortcutsSettingsView"`):

- `TextMouth/Models/KeyboardShortcut.swift` (40): `KeyBinding.from(event: NSEvent)` (line ~945) and the `NS…FunctionKey` constants in `functionKeys` (lines ~1023-1059).
- `TextMouth/Services/KeyboardShortcutManager.swift` (21): the event monitor and everything that handles an `NSEvent`, `NSWindow`, `NSResponder`, `NSPanel`, `NSTextView`, `NSTextField` (lines ~566-760).
- `TextMouth/Services/ShortcutPressDispatcher.swift` (6): only `NSWindow` type names.
- `TextMouth/Views/Settings/KeyboardShortcutsSettingsView.swift` (15): `ShortcutRecorderEventHandler` (an `NSViewRepresentable`, lines ~751-870) and its use at ~724; the error at line 72 (`from: nil`) is a cascade from another team's file and goes away once that file takes `PlatformWindow?` (if it does not, post a finding to `shell-lead`; do not work around it).

You edit only these four files and the new files you create under `TextMouth/Platform/`. Their tests are yours only to keep passing.

## Decisions (settled; do not re-open them)

1. **KeyboardShortcut.swift stays shared.** Its stored form is part of config.json.
   - Wrap `static func from(event: NSEvent) -> KeyBinding?` in `#if os(macOS)` … `#endif`, text unchanged inside.
   - **Do not edit the `functionKeys` table.** Instead give iOS the constants it names: one new file, `TextMouth/Platform/iOS/Models/FunctionKeyConstants+iOS.swift`, starting with `// Phase 0 stand-in: AppKit's NSEvent.h function-key constants, which UIKit lacks. The Mac uses AppKit's own; iOS declares the same names with the same values so config.json's key names (pageDown, f5, …) mean the same on both.` It declares each name the table uses (`NSDeleteFunctionKey`, `NSHomeFunctionKey`, … `NSF1FunctionKey`, about 70) as a global `let` of type `Int`, with the value NSEvent.h gives. Get the values from the header (`find /Applications/Xcode.app -name NSEvent.h -path "*AppKit.framework*"`, then `grep -E "FunctionKey"`), and write one line per constant with a one-line comment for the group. Then check every value by script: parse the header's `NS…FunctionKey = 0x…` lines and compare them with your file's, and say in your report that you did. A wrong value would make a config.json key name mean a different key on iPhone.
   - Any other `NSEvent`-typed code in the file that the census lists is wrapped the same way.
2. **KeyboardShortcutManager stays shared** (its config mirror, edits, scopes, dispatcher wiring and double-press trial are plain Swift). Wrap in `#if os(macOS)` the event half: `eventMonitor`, `startMonitoring`, `stopMonitoring`, both `handleKeyEvent`s, `isDialog`, `windowKind(ofKeyWindow:)`, `windowKind(of:)`, `isTextInput`, and the call sites of `startMonitoring()` and `stopMonitoring()` (line ~104 and where stop is called).
   - `post(_:)` and the rest stay shared, but `post` reads `trigger.window.windowNumber`, which UIKit's window lacks: wrap the whole `if trigger.action == .restartSleepTimer { … }` block (the Mac's text stays character for character).
   - The census hides errors behind the `NSWindow` ones, so more may appear after your first pass; handle each by the five rules.
   - Keep the declarations' order and text. If a private member is used on both sides of a wrapper, leave it unwrapped.
3. **ShortcutPressDispatcher stays shared.** Change each `NSWindow` to `PlatformWindow` (rule 3). Touch nothing else unless the next census asks.
4. **KeyboardShortcutsSettingsView stays shared** (the wording, rows, and stepper are plain SwiftUI; phase 1 wants them). Wrap `ShortcutRecorderEventHandler` and its use in `ShortcutRecorderButton` (line ~724) in `#if os(macOS)`; for the call site use the postfix form inside the modifier chain. On iOS the recorder button then records no key. Do not change the wording, labels, or hints.
5. Any other error the next census shows in these four files: use rule 2 (wrap) or rule 3 (alias). A new alias goes in `TextMouth/Platform/PlatformShellTypes.swift` (the lead owns that file; if you need one, post to `shell-lead` and wait).

## The Mac must not change

`make mac-projection BASE=team/shell DIFF=1` must show no changed Mac line except `NSWindow` to `PlatformWindow` aliases. Constants you add live only in a file the Mac does not compile.

## Tests to request from the train

Areas `shortcuts` and `legacy`; classes `KeyboardShortcutTests,MenuVisibilityTests,KeyboardReachabilityTests,ShortcutMigrationTests,ShortcutsSettingsTabTests`. Request once, after your last commit.

## Completion check

The census (`make typecheck-ios CENSUS=1`) shows no error in your four files and none in `Platform/iOS/Models/FunctionKeyConstants+iOS.swift`; `make typecheck-mac` shows 0 errors and 0 warnings. Errors in other teams' files that name your files are theirs: ignore them.
