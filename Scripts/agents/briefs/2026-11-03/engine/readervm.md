# Task engine-readervm: the reader and transcription view models

You are worker `engine-readervm` of team `engine` (lead `engine-lead`). Read `Scripts/agents/briefs/2026-11-03/ios0-common.md` (the pattern; its rules override this brief) and `team-engine.md` beside it. Branch: `git checkout -b engine/readervm team/engine`.

## Files and goal

`TextMouth/ViewModels/`: `ReaderViewModel.swift` (8 errors), `ReaderViewModel+WhereAmI.swift` (6), `+CloudDownload.swift` (3), `+NextBookWindow.swift` (3), `+SpeechRefusal.swift` (2), `+OggConversion.swift` (1), `+Playback.swift` (1), `TranscriptCleanupSheetModel.swift` (5), `TranscriptionSheetModel.swift` (4), `TranscriptionJobCenter.swift` (3). Done when the census shows none of these files. The errors are pasted at the end.

## Decisions (settled; do not reopen)

1. **`NSWindow` becomes `PlatformWindow`** (Platform/PlatformTypes.swift) in every parameter, property, and cast (`notification.userInfo?["sourceWindow"] as? NSWindow` too). On the Mac it is the same type. Do not change what a method does with the window.
2. **`NSApp`, `NSApplication`, `NSPasteboard`, `NSWorkspace`, `NSTextView`** go behind `#if os(macOS)` ... `#else` ... `#endif`, the Mac text unchanged character for character.
   - **Never take a name away from iOS that a file you do not own uses.** `grep -rn "methodName" TextMouth --include='*.swift'` before you wrap a whole method; if anything outside the Mac's code calls it, the `#else` keeps the same signature and does the least that is safe, with a comment.
   - `ReaderViewModel.swift:1106-1121` (`isTargetedNotification` and the `NSApplication.didBecomeActiveNotification` publisher): the call `WindowCommandRouting.shouldAccept(sourceWindow:hostWindow:keyWindow:)` takes `NSApp.keyWindow` on the Mac and `nil` on iOS (a board finding asks `shell-lead` to make that overload available on iOS with `PlatformWindow?` parameters; it may not yet be there; the error would then remain in your census, which is fine, say so in your report). On iOS the app-activation publisher uses `UIApplication.didBecomeActiveNotification`.
   - `NSPasteboard` (WhereAmI 771-772): copying a string; on iOS use `UIPasteboard.general.string = ...` inside `#else`.
   - `NSWorkspace.shared.open(...)` for a plain-text file (TranscriptCleanupSheetModel:61): on iOS it throws or does nothing: use `IOSUnavailable.feature("Editing the cleanup rules in another app")` if the method throws; otherwise nothing.
   - The window standings (`+NextBookWindow.swift:40-46`, `+SpeechRefusal.swift:9-16`) read NSWindow-only properties (`isMiniaturized`, `attachedSheet`, `sheetParent`, `firstResponder`, `NSApp.isHidden`). Wrap each body in place; on iOS the `#else` returns the standing that means "no window" / "stands behind" (`.noWindow`, or `.of(...)` with every flag the Mac gives a reader without a window), so no iOS reader claims the listener's attention. A comment says phase 1 will read the scene instead.
3. `TranscriptionSheetModel.swift:96-97` (`center: .shared`, `transcribedBooks: .shared`) are knock-on errors of the `NSWindow` ones: recheck after fixing those. `BookTextEditor.shared.pauseEditing(of:)` and `resumeEditing(of:)` (used at TranscriptionSheetModel:98-99, TranscriptCleanupSheetModel:43-44, TranscriptionJobCenter:169) come from `engine-editor`'s stand-in, already on `team/engine` when you start.
4. `NSAccessibilityPriorityLevel` (WhereAmI:869, CloudDownload:739) and `priority: .high/.medium` (Playback:3199, OggConversion:55, WhereAmI:857/864, CloudDownload:631/767, TranscriptionJobCenter:266) are for a11y's team (finding posted to `a11y-lead`). Make no edit for them; if they remain, say so in your report.
5. No `@unchecked Sendable`, no `nonisolated(unsafe)`, no traps. Comment every new branch.

## Mac test areas to request from the train

`reader-text`, `transcripts`, `cloud` (name the classes of the files you touch: `ls TextMouthTests TextMouthProductionTests | grep -i "ReaderViewModel\|TranscriptCleanup\|TranscriptionSheet\|TranscriptionJob"`).

## Watch for

ReaderViewModel+Playback is 3,800 lines of speech and playback logic; the one error there is the announcer priority, and you edit nothing in that file.

## The census's errors for your files (36; census of 72d9f5cd)

```
TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift:631:79: error: cannot infer contextual base in reference to member 'medium'
TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift:739:61: error: cannot find type 'NSAccessibilityPriorityLevel' in scope
TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift:767:89: error: cannot infer contextual base in reference to member 'medium'
TextMouth/ViewModels/ReaderViewModel+NextBookWindow.swift:44:26: error: cannot find 'NSApp' in scope
TextMouth/ViewModels/ReaderViewModel+NextBookWindow.swift:46:60: error: cannot find type 'NSTextView' in scope
TextMouth/ViewModels/ReaderViewModel+NextBookWindow.swift:84:28: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/ReaderViewModel+OggConversion.swift:55:57: error: cannot infer contextual base in reference to member 'high'
TextMouth/ViewModels/ReaderViewModel+Playback.swift:3199:83: error: cannot infer contextual base in reference to member 'high'
TextMouth/ViewModels/ReaderViewModel+SpeechRefusal.swift:10:25: error: cannot find 'NSApp' in scope
TextMouth/ViewModels/ReaderViewModel+SpeechRefusal.swift:12:26: error: cannot find 'NSApp' in scope
TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift:771:9: error: cannot find 'NSPasteboard' in scope
TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift:772:9: error: cannot find 'NSPasteboard' in scope
TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift:772:71: error: cannot infer contextual base in reference to member 'string'
TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift:857:46: error: cannot infer contextual base in reference to member 'high'
TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift:864:46: error: cannot infer contextual base in reference to member 'medium'
TextMouth/ViewModels/ReaderViewModel+WhereAmI.swift:869:64: error: cannot find type 'NSAccessibilityPriorityLevel' in scope
TextMouth/ViewModels/ReaderViewModel.swift:296:44: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/ReaderViewModel.swift:378:26: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/ReaderViewModel.swift:549:33: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/ReaderViewModel.swift:1106:71: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/ReaderViewModel.swift:1107:49: error: missing arguments for parameters 'sourceMatchesHost', 'hostWindowIsKey' in call
TextMouth/ViewModels/ReaderViewModel.swift:1110:24: error: cannot find 'NSApp' in scope
TextMouth/ViewModels/ReaderViewModel.swift:1110:30: error: extra argument 'keyWindow' in call
TextMouth/ViewModels/ReaderViewModel.swift:1119:27: error: cannot find 'NSApplication' in scope
TextMouth/ViewModels/TranscriptCleanupSheetModel.swift:21:32: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/TranscriptCleanupSheetModel.swift:31:39: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/TranscriptCleanupSheetModel.swift:61:26: error: cannot find 'NSWorkspace' in scope
TextMouth/ViewModels/TranscriptCleanupSheetModel.swift:61:72: error: cannot infer contextual base in reference to member 'plainText'
TextMouth/ViewModels/TranscriptCleanupSheetModel.swift:145:22: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/TranscriptionJobCenter.swift:152:40: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/TranscriptionJobCenter.swift:186:83: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/TranscriptionJobCenter.swift:266:28: error: cannot infer contextual base in reference to member 'medium'
TextMouth/ViewModels/TranscriptionSheetModel.swift:69:39: error: cannot find type 'NSWindow' in scope
TextMouth/ViewModels/TranscriptionSheetModel.swift:96:22: error: cannot infer contextual base in reference to member 'shared'
TextMouth/ViewModels/TranscriptionSheetModel.swift:97:32: error: cannot infer contextual base in reference to member 'shared'
TextMouth/ViewModels/TranscriptionSheetModel.swift:244:22: error: cannot find type 'NSWindow' in scope
```
