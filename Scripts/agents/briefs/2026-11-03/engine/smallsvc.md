# Task engine-smallsvc: the small services, the Word writer, the PDF reader

You are worker `engine-smallsvc` of team `engine` (lead `engine-lead`). Read `Scripts/agents/briefs/2026-11-03/ios0-common.md` (the pattern; its rules override this brief) and `team-engine.md` beside it. Branch: `git checkout -b engine/smallsvc team/engine`.

## Files and goal

- `TextMouth/Services/LibrarySessionLease.swift` (8 errors), `PublishedFileProgress.swift` (3), `ReadingStatsService.swift` (3), `SleepTimerService.swift` (2), `TextSubstitutionService.swift` (1)
- `TextMouth/Services/Export/WordDocExportWriter.swift` (3), and the one line in `TextMouth/Services/Export/TextExportWriter.swift` that lists it
- `TextMouth/Parsers/PDFTextParser.swift` (3)
- `TextMouth/ViewModels/FeedDownloadProgress.swift` (2), `ImportProgress.swift` (1), `ContentAnalysisSummaryBuffer.swift` (1)

Done when the census shows none of these files. The errors are pasted at the end.

## Decisions (settled; do not reopen)

1. **LibrarySessionLease.** `SCDynamicStoreCopyComputerName(...)` (line ~502) becomes, in `#if os(macOS)` ... `#else` ... `#endif`, `UIDevice.current.name` on iOS (add `import UIKit` under `#if canImport(UIKit)` if needed; the iOS branch is `@MainActor`-safe or reads it in a nonisolated-safe way: check how the Mac function is isolated). The `NSAlert`/`NSApp`/`NSApplication` lines (153, 480-496) are wrapped in place; on iOS the lease shows no alert and does the least that is safe (a comment says why).
2. **PublishedFileProgress.** `Progress.addSubscriber(forFileURL:withPublishingHandler:)` and `removeSubscriber` are Mac-only: wrap in place; on iOS `subscribe` subscribes to nothing and returns whatever token type the Mac returns (a no-op value), and unsubscribe does nothing.
3. **ReadingStatsService.** `NSWorkspace`'s sleep and wake notifications: wrap in place; no notifications on iOS for now (comment).
4. **SleepTimerService** (lines 745, 1063) and **FeedDownloadProgress**, **ImportProgress**: the errors are `priority: .medium` of `VoiceOverAnnouncer.announce`. They disappear when a11y's team keeps `NSAccessibilityPriorityLevel` usable on iOS (a board finding is posted to `a11y-lead`). Make no edit for them; if after your other changes they remain in your census, say so in your report and leave them. **TextSubstitutionService** line 477 and **ContentAnalysisSummaryBuffer** line 229: wrap the `NSApplication` use in place, `#else` the least safe thing.
5. **WordDocExportWriter.** `git mv` it, unchanged, to `TextMouth/Platform/macOS/Services/Export/WordDocExportWriter.swift`. `TextExportWriters.all` in TextExportWriter.swift names `WordDocExportWriter()`: wrap that one line in `#if os(macOS)` ... `#endif` so that iOS's export never offers it (an `#if` inside an array literal is allowed since Swift 5.4; if it does not compile, build the array with a small `#if` ... `#else` pair of two complete literals, Mac text unchanged). Check that no other shared file names the type (`grep -rn WordDocExportWriter TextMouth`). Tests that build `WordDocExportWriter()` run on the Mac only; confirm no test reads the file by path.
6. **PDFTextParser.** `NSFont` becomes `PlatformFont` at lines 425, 502, 686. Where it reads the font's traits (`font?.fontDescriptor.symbolicTraits.contains(.bold)` and `.italic`, lines ~427-428, and wherever the same appears), NSFont's `NSFontDescriptor.SymbolicTraits` names (`.bold`, `.italic`) differ from UIFont's (`.traitBold`, `.traitItalic`): read them in an `#if os(macOS)` ... `#else` pair. The Mac text is exactly as before (aliases excepted); DRY the pair into one small private helper only if the Mac text stays the same.
7. No `@unchecked Sendable`, no `nonisolated(unsafe)`, no traps.

**PlatformApplication (new since the pattern was written).** `TextMouth/Platform/PlatformApplication.swift` offers `PlatformApplication.keyWindow`, `.mainWindow`, `.isActive`, `.didBecomeActiveNotification`, and `.didResignActiveNotification`: on the Mac each is exactly `NSApp.keyWindow`, `NSApp.mainWindow`, `NSApp.isActive`, `NSApplication.didBecomeActiveNotification`, `NSApplication.didResignActiveNotification` (the projection reads them as such), and on iOS each answers as well as phase 0 can. Use them in place of those AppKit expressions (rule 3, an alias); the old expressions then need no `#if`. Other `NSApp`/`NSApplication` uses still go behind `#if os(macOS)`.

## Mac test areas to request from the train

`storage`, `stats`, `export`, `pdf` (name the classes of the files you touch: `ls TextMouthTests TextMouthProductionTests | grep -i "SessionLease\|PublishedFile\|ReadingStats\|SleepTimer\|TextSubstitution\|RTFExport\|BookExport\|PDF"`).

## Watch for

`UncheckedConcurrencyPolicyTests` pins the counts. The PDF reader's font-size and heading statistics must read exactly as before on the Mac.

## The census's errors for your files (24; census of 72d9f5cd)

```
TextMouth/Parsers/PDFTextParser.swift:425:41: error: cannot find type 'NSFont' in scope
TextMouth/Parsers/PDFTextParser.swift:502:41: error: cannot find type 'NSFont' in scope
TextMouth/Parsers/PDFTextParser.swift:686:40: error: cannot find type 'NSFont' in scope
TextMouth/Services/LibrarySessionLease.swift:153:51: error: cannot find 'NSApplication' in scope
TextMouth/Services/LibrarySessionLease.swift:153:82: error: 'nil' requires a contextual type
TextMouth/Services/LibrarySessionLease.swift:480:21: error: cannot find 'NSAlert' in scope
TextMouth/Services/LibrarySessionLease.swift:481:29: error: cannot infer contextual base in reference to member 'warning'
TextMouth/Services/LibrarySessionLease.swift:486:25: error: cannot find 'NSApp' in scope
TextMouth/Services/LibrarySessionLease.swift:486:44: error: cannot find 'NSApp' in scope
TextMouth/Services/LibrarySessionLease.swift:496:52: error: cannot find type 'NSApplication' in scope
TextMouth/Services/LibrarySessionLease.swift:502:10: error: 'SCDynamicStoreCopyComputerName' is unavailable in iOS
TextMouth/Services/PublishedFileProgress.swift:56:35: error: 'addSubscriber(forFileURL:withPublishingHandler:)' is unavailable in iOS
TextMouth/Services/PublishedFileProgress.swift:104:22: error: 'removeSubscriber' is unavailable in iOS
TextMouth/Services/PublishedFileProgress.swift:117:22: error: 'removeSubscriber' is unavailable in iOS
TextMouth/Services/ReadingStatsService.swift:213:54: error: cannot find 'NSWorkspace' in scope
TextMouth/Services/ReadingStatsService.swift:225:29: error: cannot find 'NSWorkspace' in scope
TextMouth/Services/ReadingStatsService.swift:228:29: error: cannot find 'NSWorkspace' in scope
TextMouth/Services/SleepTimerService.swift:745:82: error: cannot infer contextual base in reference to member 'medium'
TextMouth/Services/SleepTimerService.swift:1063:57: error: cannot infer contextual base in reference to member 'medium'
TextMouth/Services/TextSubstitutionService.swift:477:29: error: cannot find 'NSApplication' in scope
TextMouth/ViewModels/ContentAnalysisSummaryBuffer.swift:229:29: error: cannot find 'NSApplication' in scope
TextMouth/ViewModels/FeedDownloadProgress.swift:437:24: error: cannot infer contextual base in reference to member 'medium'
TextMouth/ViewModels/FeedDownloadProgress.swift:452:24: error: cannot infer contextual base in reference to member 'medium'
TextMouth/ViewModels/ImportProgress.swift:342:24: error: cannot infer contextual base in reference to member 'medium'
```
