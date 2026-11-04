# Task router: the window router and the window-hosting views

Slug `shell-router`, branch `shell/router` (from `team/shell`). Read `../ios0-common.md` first (the pattern and the worker's part), then this brief. The lead is `shell-lead`.

## Your files and their errors (58 in the census)

Census: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/typecheck/results/orchestrator-ios-census-72d9f5cd-1103-200441/errors.txt` (`grep -E "LibraryWindowRouter|BookReaderWindowView|LibraryFeedsWindowSupport|FeedCommandRunner|Settings/SettingsView.swift"`).

- `TextMouth/Services/LibraryWindowRouter.swift` (28): `NSWindow` type names, `NSApp.keyWindow` as a default, `import AppKit`.
- `TextMouth/Views/Reader/BookReaderWindowView.swift` (20): `WindowAccessor` (NSViewRepresentable) and its helper classes, lines ~160-281, and `NSWindow` types.
- `TextMouth/Views/Feeds/LibraryFeedsWindowSupport.swift` (8): `NSWindow` types, and `NSWindow.didBecomeKeyNotification` at ~146. The `Binding` errors at 204 and 240 are cascades.
- `TextMouth/Views/Feeds/FeedCommandRunner.swift` (1): `let window: NSWindow?`.
- `TextMouth/Views/Settings/SettingsView.swift` (1): line 148 `.toggleStyle(.checkbox)`.

You edit only these files and the new files you create under `TextMouth/Platform/`.

## Decisions (settled)

1. **The router stays shared, not moved.** (The charter said to move it with a stand-in; the lead checked: its whole logic, `GlobalAction` and its handlers included, is plain Swift once a window is a `PlatformWindow`, and a stand-in would copy 600 lines.)
   - `import AppKit` becomes the `#if os(macOS) import AppKit #else import UIKit #endif` form (rule 2).
   - Every `NSWindow` type name becomes `PlatformWindow` (rule 3), including `GlobalActionHandler`'s cases. `NSWindow.didBecome…` style notification names are not type names: wrap the code that uses them.
   - The default `keyWindow: ... = { NSApp.keyWindow }` must stay `NSApp.keyWindow` on the Mac. Do it with a small `static` helper, declared once, `#if os(macOS)` returning `NSApp.keyWindow` and `#else` returning nil, and the default argument calls the helper (an alias-like helper: report it as a real Mac change, since the Mac's default now goes through a call, with this reason). If the compiler accepts `#if` around the default expression itself, prefer that and the Mac text stays unchanged.
   - The census hides errors behind the `NSWindow` ones: expect `sheetParent`, `windowNumber`, `isKeyWindow` and similar to surface. Wrap each such use (rule 2); on iOS the answer is "no relationship" (nil, false, or the window itself).
2. **BookReaderWindowView stays shared.** `WindowAccessor`, `WindowAccessorView`, and `NotificationObservation` are AppKit only and are named by other files (`ContentView`, `LibraryView`, `BookExportSheet`).
   - Move them, **unchanged**, into `TextMouth/Platform/macOS/Views/Reader/WindowAccessor.swift` (rule 5: cut the lines from `BookReaderWindowView.swift`, paste them, add `import AppKit` and `import SwiftUI` at the top; the declarations' text stays character for character, `NSWindow` included). Keep the doc comments.
   - Give iOS `TextMouth/Platform/iOS/Views/Reader/WindowAccessor+iOS.swift`, starting `// Phase 0 stand-in: the Mac's WindowAccessor hands the SwiftUI view its NSWindow and reports key, close, and on-screen changes; iOS reports nothing yet.` It declares `struct WindowAccessor: View` with the same stored properties and the same `init` (same labels, defaults, and `@escaping`), the window parameter typed `PlatformWindow`, and `body` returning `Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)`. Comment every member.
   - Everything else in `BookReaderWindowView` (`NSWindow` types in `viewModel.attach(to:)`, etc.): use rule 3 or rule 2.
3. **LibraryFeedsWindowSupport, FeedCommandRunner:** `NSWindow` to `PlatformWindow` (rule 3). Wrap the key-window notification (`NSWindow.didBecomeKeyNotification`, ~146) in `#if os(macOS)`, keeping the Mac text unchanged.
4. **SettingsView:** `.toggleStyle(.checkbox)` to `.checkboxToggleStyle()` (rule 4). Look for other macOS-only styles the census may reveal after it.
5. Other teams' files that take or return `NSWindow` (view models, sheets) change to `PlatformWindow` as well; if your census shows a mismatch with one of them, post a finding to `shell-lead` with `--file`.

## The Mac must not change

`make mac-projection BASE=team/shell DIFF=1` shows no changed Mac line except `NSWindow` to `PlatformWindow`, the import wrapper, the helper call (if you needed it), and the WindowAccessor move.

## Tests to request from the train

Areas `windows`, `settings`, `feeds`; classes `LibraryWindowRouterTests,WindowsMatrixTests,IntegrationWindowRoutingTests,AddToLibraryToolbarTests,NextBookWindowReaderTests,NextBookWindowTests,PageNavigationTests`. The last four read `SettingsView.swift`, `LibraryView.swift` and `BookReaderWindowView.swift` by path: they must stay green. Request once, after your last commit.

## Completion check

The census shows no error in your five files and none in `WindowAccessor+iOS.swift`; `make typecheck-mac` shows 0 errors, 0 warnings. Run `/opt/homebrew/bin/xcodegen generate` after the move and commit the result.
