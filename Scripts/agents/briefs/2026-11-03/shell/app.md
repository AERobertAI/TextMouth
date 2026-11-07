# Task app: the application delegate, menus, and the small AppKit-only files

Slug `shell-app`, branch `shell/app` (from `team/shell`). Read `../ios0-common.md` first (the pattern and the worker's part), then this brief. The lead is `shell-lead`.

## Your files and their errors (60 in the census)

Census: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/typecheck/results/orchestrator-ios-census-72d9f5cd-1103-200441/errors.txt` (`grep -E "AppDelegate|MenuCommands|UnsavedChangesTermination|MenuVisibilityManager|SilentKeyEquivalent|LogsInFinder|SwitchedWindowFocus"`).

- `TextMouth/App/AppDelegate.swift` (13), `TextMouth/Services/MenuVisibilityManager.swift` (11): Mac only.
- `TextMouth/App/UnsavedChangesTermination.swift` (6): mixed.
- `TextMouth/App/MenuCommands.swift` (15): all in `FrontWindowKind` (lines ~771-817).
- `TextMouth/Views/SilentKeyEquivalent.swift` (13), `TextMouth/Views/LogsInFinder.swift` (1), `TextMouth/Views/SwitchedWindowFocus.swift` (1).

Edit only these files and new files under `TextMouth/Platform/`.

## Decisions (settled)

1. **Moves, unchanged (rule 1)**, each file in its own commit with `git mv` and no edit, after `grep -rn` of the tests and `Scripts` for the path (the lead found none for these, but check):
   - `TextMouth/App/AppDelegate.swift` to `TextMouth/Platform/macOS/App/AppDelegate.swift`. Only `TextMouthApp.swift` (already in `Platform/macOS`) names it in code.
   - `TextMouth/Services/MenuVisibilityManager.swift` to `TextMouth/Platform/macOS/Services/MenuVisibilityManager.swift`. Only Mac-only code names it in code (`KeyboardShortcutManager`'s Mac half, `FrontWindowKind`); other mentions are comments.
   - `TextMouth/Views/SilentKeyEquivalent.swift`, `TextMouth/Views/LogsInFinder.swift`, `TextMouth/Views/SwitchedWindowFocus.swift` to the same names under `TextMouth/Platform/macOS/Views/`.
2. **iOS stand-ins** for what shared files still name (each file starts with `// Phase 0 stand-in: …` saying what the Mac does and what iOS does instead, comments every member, `@MainActor` where the Mac's is, no traps):
   - `TextMouth/Platform/iOS/Views/SilentKeyEquivalent+iOS.swift`: `struct SilentKeyEquivalent: View` with `let key: KeyEquivalent`, `let action: () -> Void`, and a body of `Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)`. (The Mac one takes a hardware key; iOS does nothing yet.) Four sheets (`.background(SilentKeyEquivalent(key: .escape, action: …))`) use it.
   - `TextMouth/Platform/iOS/Views/LogsInFinder+iOS.swift`: `enum LogsInFinder` with `@MainActor static func show(for location: LogLocation, opening open: (URL) -> Bool = { _ in false }) -> String?` returning `IOSUnavailable.feature("Showing the logs in Finder").errorDescription` (a full sentence), never opening anything. Match the Mac's signature exactly.
   - `TextMouth/Platform/iOS/Views/SwitchedWindowFocus+iOS.swift`: `@MainActor enum SwitchedWindowFocus` with `static let checkDelay: TimeInterval = 1.6`, `nonisolated static func shouldPlace(postsAtTheLoad:postsNow:windowIsKey:) -> Bool` (the same one-line body as the Mac's), and `static func place(in window: PlatformWindow)`, which does nothing (empty body with a comment). Only `place(in:)` is named by shared code (`ReaderViewModel`).
   - AppDelegate and MenuVisibilityManager get **no** stand-in unless the next census shows shared code naming them.
3. **MenuCommands.swift stays shared and in place** (the lead's decision against the charter: `KeyboardReachabilityTests` and four other tests read `App/MenuCommands.swift` by path, and its focused-value keys are published by shared views).
   - Split `FrontWindowKind` (rule 5): move the section from `// MARK: - The Window in Front (FR12's Branch E)` through the end of `final class FrontWindowKind`, unchanged, into `TextMouth/Platform/macOS/App/FrontWindowKind.swift` (add `import AppKit` and `import SwiftUI` at the top). Do not touch the `extension View` that follows it in MenuCommands.
   - iOS stand-in `TextMouth/Platform/iOS/App/FrontWindowKind+iOS.swift`: `@MainActor final class FrontWindowKind: ObservableObject` with `static let shared`, `@Published private(set) var kind: ShortcutWindowKind?` (always nil), a private init, and `static func kind(of window: PlatformWindow?) -> ShortcutWindowKind?` returning nil.
   - Tests scan MenuCommands.swift by line content: moving the class changes line numbers only; run them.
4. **UnsavedChangesTermination.swift stays shared** (`QuitHold`, `TerminationDecision`, and `flushPendingWrites` are named by shared code: `FeedDownloadManager`, `LibraryViewModel+TextEncoding`, `PlaybackMemoryGuard`). Wrap in place, Mac text unchanged:
   - `import AppKit` to the `#if os(macOS)` form (rule 2; UIKit on the iOS side only if the file still needs it).
   - `UnsavedChangesPrompt.run` (NSAlert), the guard's `reply() -> NSApplication.TerminateReply`, and the default `{ NSApp.terminate(nil) }` for `requestTermination` go behind `#if os(macOS)`. The iOS side keeps the guard's stored closures, with `init` defaults `requestTermination: {}` and `prompt: { _ in .cancel }`, since the iPhone has no quit to hold. `flushPendingWrites()` and `QuitHold` stay shared and untouched. Because `init`'s defaults sit in a parameter list, wrap the whole `init` in `#if os(macOS)` … `#else` (second init) … `#endif`.
5. After the moves, run the census: errors may surface in the files that stayed (they were hidden behind the missing AppKit types). Handle each by the five rules and tell `shell-lead` if one needs a decision.

## The Mac must not change

`make mac-projection BASE=team/shell DIFF=1`: only moves, wrappers, the import form. Moves are separate commits, so a reviewer can see each is a pure rename.

## Tests to request from the train

Areas `shortcuts`, `windows`, `legacy`; classes `MenuVisibilityTests,KeyboardReachabilityTests,SourceScanSymlinkTests,NextBookWindowReaderTests,LibraryFolderSettingsTargetTests,LegacyMenuVisibilityScenarioTests`, and the class that tests `UnsavedChangesTerminationGuard` (find it with `grep -rln UnsavedChangesTerminationGuard TextMouthTests TextMouthProductionTests`). Scripts/test/a11y-lint.py reads `TextMouth/Views` by path: moving three Views files out of it is a finding for `shell-lead` (post it), not yours to fix. Request once, after your last commit.

## Completion check

The census shows no error in your files that stayed and none in the new iOS files; `make typecheck-mac` shows 0 errors, 0 warnings; run `/opt/homebrew/bin/xcodegen generate` after the moves and commit the result.
