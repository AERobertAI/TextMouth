# a11y task `focus`: VoiceOver focus moves to the Mac folder; the announcer compiles on iOS

Slug `a11y-focus`, branch `a11y/focus` (from `team/a11y`). Read `../ios0-common.md` ("The worker's part", and the rules) and `../team-a11y.md` first. These two files are the first of the team's, and other teams' files name what they declare, so keep every signature.

## Files

- `TextMouth/Views/VoiceOverFocus.swift`: 76 census errors, all because it is AppKit. It has nothing for iOS.
- `TextMouth/Services/VoiceOverAnnouncer.swift`: 13 errors.
- New: `TextMouth/Platform/iOS/Views/VoiceOverFocus+iOS.swift`, `TextMouth/Platform/iOS/Services/NSAccessibilityPriorityLevel+iOS.swift`.
- Tests to read, not edit: `TextMouthProductionTests/VoiceOverFocusClosedWindowTests.swift`, `WindowFocusPolicyTests.swift`, and the tests naming `VoiceOverAnnouncer`.

## Part 1: VoiceOverFocus.swift

1. `git mv TextMouth/Views/VoiceOverFocus.swift TextMouth/Platform/macOS/Views/VoiceOverFocus.swift`, in a commit of its own with the text unchanged. First `grep -rnE "VoiceOverFocus\.swift"` over `TextMouthTests`, `TextMouthProductionTests`, `Scripts` (not `Scripts/agents/briefs`): `Scripts/test/a11y-lint.py` names the file by base name, which still matches; report anything that reads the path.
2. The iOS twin, in `Platform/iOS/Views/VoiceOverFocus+iOS.swift`, every name the shared files use. The census and grep found these (re-run `grep -rnE` over `TextMouth --include='*.swift'` outside the moved file to confirm):
   - `let voiceOverFocusID = "vo-focus-target"`.
   - `func voiceOverFocusLog(_ message: @autoclosure () -> String)`, writing `DiagnosticLog.trace(.focus, message())` exactly as the Mac does (check `DiagnosticLog` is shared code; if it is not, make the iOS body empty).
   - `struct StandardVoiceOverFocus: View` with `var delay: TimeInterval = 0.8` and `struct VoiceOverFocus: View` with `var delay: TimeInterval = 1.2`; used as `.background(VoiceOverFocus(delay: 1.2))`. Their `body` is `Color.clear` (they are triggers with no appearance), with `.accessibilityHidden(true)`, so nothing new reaches a VoiceOver user. Comment: phase 0 stand-in, phase 1 does real iPhone focus.
   - `struct InitialVoiceOverFocusModifier: ViewModifier` with `let isTarget: Bool` and `var delay: TimeInterval = 1.2` (the memberwise init `InitialVoiceOverFocusModifier(isTarget:delay:)` is used in about 34 places). When `isTarget`, the body returns `content.accessibilityIdentifier(voiceOverFocusID)`; otherwise `content`. (Do not add the background trigger; do not add `accessibilityAddTraits`. Identifier only.)
   - `extension PlatformWindow { var hasContentForVoiceOverFocus: Bool }` (`UIWindow` on iOS: true when `rootViewController?.view` has subviews).
   - `@MainActor final class StandardVoiceOverFocusTriggerView` (a plain class on iOS; the Mac's is an NSView), with `init()` and these members, which shared code (Views/SwitchedWindowFocus.swift of team shell, Views/Feeds/FeedDownloadProgressSection.swift of yours) uses: `static func focusPostCount(of window: PlatformWindow) -> Int` (returns 0), `func findMarkedElement(in window: PlatformWindow) -> Any?` (nil), `static func placeFocus(on target: Any, in window: PlatformWindow)` (does nothing), `static func staticFindAndFocus(in window: PlatformWindow)` (does nothing). Each with a comment saying what the Mac does and that iOS does nothing yet.
   - No `VoiceOverFocusTriggerView`, `VoiceOverFocusDiagnostics` or `noteFocusPost`: only Mac tests name them.
   - Keep `@MainActor` where the Mac's type has it. No `@unchecked Sendable`, no `nonisolated(unsafe)`, no static mutable globals.
   - Start the file with `// Phase 0 stand-in: ...` comment, as ios0-common.md says.

## Part 2: VoiceOverAnnouncer.swift (stays shared; the Mac's text stays character for character inside `#if os(macOS)`)

1. `import AppKit` becomes the rule 2 form (AppKit on the Mac, UIKit and SwiftUI on iOS, whichever the iOS branch needs).
2. Each `NSWindow?` becomes `PlatformWindow?` (rule 3: `PlatformWindow` is `NSWindow` on the Mac). That is five places: the `Poster` typealias, `announce`, `announceAfterSheetCloses`, `postThroughAccessibility`.
3. `NSAccessibilityPriorityLevel` stays the name in the shared file. Declare an iOS stand-in of that name in `Platform/iOS/Services/NSAccessibilityPriorityLevel+iOS.swift`: `enum NSAccessibilityPriorityLevel: Int, Sendable { case low = 10, medium = 50, high = 90 }` (the Mac's raw values), commented. Callers in the engine team's files write `.high` and `.medium` and one default `= .high`. The engine lead agreed to this on the board (#4871).
4. `postThroughAccessibility`: wrap the Mac body in `#if os(macOS)` as it stands and write the iOS branch: it posts `message` with `AccessibilityNotification.Announcement` (SwiftUI, iOS 17), or `UIAccessibility.post(notification: .announcement, argument:)` if the SwiftUI type cannot carry a priority. Read Apple's documentation for `AccessibilityNotification.Announcement` and `accessibilitySpeechAnnouncementPriority` / `UIAccessibility.Notification.announcement` before choosing. Map the priority on iOS in a comment: high speaks at once (`.high`), medium and low queue after current speech (`.default` / `.low`). The `window` argument is unused on iOS. Check the iOS target's minimum version in `project.yml` and use only APIs it has.
5. `VoiceOverAnnouncement: Equatable` must conform on iOS, which the stand-in enum gives.
6. The `NSApp?.keyWindow ?? NSApp?.mainWindow` line stays inside the Mac branch.

## Checks and tests

- Order: `make typecheck-ios CENSUS=1` (until `grep -E "VoiceOverFocus|VoiceOverAnnouncer" errors.txt` shows nothing; errors in OTHER files that name your stand-ins are theirs, but tell me), then `make typecheck-mac`, then `make mac-projection BASE=team/a11y DIFF=1`. Expect the projection to show the announcer's `#if`/`#else` lines as wrappers and nothing else.
- Run `make lint-a11y LINT_BASE=team/a11y`.
- Ask the train for the areas `accessibility,sheets` with classes `VoiceOverFocusClosedWindowTests,WindowFocusPolicyTests` (and any test class that names `VoiceOverAnnouncer`, found with grep), then wait for the result.

## Completion check

The census shows no error in `VoiceOverFocus` or `VoiceOverAnnouncer` files nor in `Platform/iOS/Views/VoiceOverFocus+iOS.swift`. The errors in other files that are only `background(... requires VoiceOverFocus conform to ShapeStyle)` (AddFeedSheet, BookSearchView, PlaybackControlsView, and the like) must be gone too.
