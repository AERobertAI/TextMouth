# TextMouth Codebase Audit

Audit date: 2026-03-19
Files reviewed: 30 Swift files across App, Models, Parsers, Services, ViewModels, and Views directories.

---

## Critical Issues

### 1. Force Unwrap on HTML Tag Name Can Crash
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Parsers/HTMLParser.swift`, line 24
- **Also:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Parsers/EPUBParser.swift`, line 309
- **Category:** Code Quality / Bug
- **Severity:** Critical
- **Description:** `tag.last!` force-unwraps the last character of the tag name to extract the heading level. If SwiftSoup ever returns an empty tag name string, this will crash the app. Both `HTMLParser.parse` and `EPUBParser.parseChapterHTML` contain the same pattern:
  ```swift
  let level = Int(String(tag.last!)) ?? 1
  ```
- **Suggested Fix:** Use safe unwrapping: `let level = tag.last.flatMap({ Int(String($0)) }) ?? 1`

### 2. Force Unwrap on Application Support Directory
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Services/FileImportService.swift`, line 24
- **Also:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Services/LibraryPersistenceService.swift`, line 7
- **Category:** Code Quality
- **Severity:** Critical
- **Description:** `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!` force-unwraps. While this practically never fails on macOS, it is a force-unwrap in production code. If the directory is somehow unavailable (sandboxing edge case, test environment), the app crashes.
- **Suggested Fix:** Use `guard let` with a meaningful error, or provide a fallback.

### 3. Memory Leak in Voice Preview
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Views/Settings/SettingsView.swift`, lines 71-78
- **Category:** Code Quality
- **Severity:** Critical
- **Description:** `previewVoice()` creates a local `AVSpeechSynthesizer` that goes out of scope immediately. The synthesizer may be deallocated while still speaking, causing either a crash or the preview silently failing. AVSpeechSynthesizer must be retained for the duration of the utterance.
- **Suggested Fix:** Store the synthesizer as a `@State` or a persistent property so it lives long enough for the speech to complete.

---

## Major Issues

### 4. Hardcoded Skip Labels Don't Match User Settings
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Views/Reader/PlaybackControlsView.swift`, lines 15, 35
- **Category:** Inconsistency / Accessibility
- **Severity:** Major
- **Description:** The skip backward button has the icon `gobackward.15` and accessibility label "Skip backward 15 seconds", while the skip forward button uses `goforward.30` and "Skip forward 30 seconds". However, the actual skip behavior is determined by user-configurable `settingsViewModel.skipForwardUnit` and `settingsViewModel.skipBackwardUnit`, which could be set to heading, bookmark, or a different time duration. The icons and labels are always wrong when the user has changed their skip settings.
- **Suggested Fix:** Dynamically set the SF Symbol name and accessibility label based on `settingsViewModel.skipForwardUnit` / `settingsViewModel.skipBackwardUnit`. For time-based units, use the corresponding `goforward.N` / `gobackward.N` icon. For heading/bookmark skips, use a different icon.

### 5. Heading Offset Search Finds First Occurrence, Not Correct One
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Parsers/HTMLParser.swift`, lines 28-29
- **Also:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Parsers/MarkdownParser.swift`, lines 22-23
- **Also:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Parsers/EPUBParser.swift`, lines 314-315
- **Category:** Bug
- **Severity:** Major
- **Description:** When computing the character offset for headings, `fullText.range(of: headingText)` returns the range of the *first* occurrence in the text. If the same heading text appears multiple times (e.g., "Introduction" in different sections, or repeated subheadings), all occurrences after the first will get the wrong offset, pointing to the first occurrence instead of the correct one.
- **Suggested Fix:** Track the search start position and use `fullText.range(of: headingText, range: searchStart..<fullText.endIndex)` to find each subsequent occurrence in order.

### 6. Duplicate Heading Detection in PlainTextParser
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Parsers/PlainTextParser.swift`, lines 32-68
- **Category:** Bug
- **Severity:** Major
- **Description:** A line that starts with `#` AND is all-caps AND is 3-80 characters will be detected as both a markdown heading (lines 32-47) and an all-caps heading (lines 61-68), producing duplicate entries in the headings list. There is no guard to prevent the all-caps check from running on lines already identified as markdown headings.
- **Suggested Fix:** Add an `else` or `continue` after the markdown heading detection to skip the all-caps check, or deduplicate headings by offset.

### 7. Setext Heading Detection Can Also Produce Duplicates
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Parsers/PlainTextParser.swift`, lines 49-58 and 61-68
- **Category:** Bug
- **Severity:** Major
- **Description:** A short all-caps line followed by `===` or `---` will be detected as both a setext-style heading and an all-caps heading. The setext branch and all-caps branch are not mutually exclusive.
- **Suggested Fix:** Restructure the conditions to be mutually exclusive (e.g., use `if/else if` chains or track which lines have already been classified).

### 8. Race Condition: DispatchQueue.main.async Mutation of @State in ContentView
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Views/ContentView.swift`, lines 73-75
- **Category:** Code Quality
- **Severity:** Major
- **Description:** `readerViewModel(for:)` is called during the SwiftUI view body evaluation but mutates `@State` (`readerViewModels`) inside a `DispatchQueue.main.async` block. Mutating `@State` from within body evaluation (even asynchronously) can cause infinite re-render loops or dropped updates. SwiftUI may have already finished the current render pass by the time the async block fires, causing the state to be out of sync.
- **Suggested Fix:** Use a different pattern: initialize the `ReaderViewModel` eagerly in `onChange(of: libraryViewModel.openBooks)` or use a factory cache outside of the view body.

### 9. SleepTimerService Updates @Published from Timer Callback off Main Thread
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Services/SleepTimerService.swift`, lines 65-73
- **Category:** Bug
- **Severity:** Major
- **Description:** `Timer.scheduledTimer` fires on the current run loop. If `startCountdown()` happens to be called from a background thread, the timer would fire on a background run loop, modifying `@Published` properties (`remainingSeconds`, `isActive`) off the main thread, which triggers undefined SwiftUI behavior. Even when called from main, the `expire()` method sets `isActive = false` and then calls `onTimerExpired?()` which calls `pause()` on the ReaderViewModel -- this chain should be verified to always run on main.
- **Suggested Fix:** Ensure the timer is always scheduled on the main RunLoop explicitly: `RunLoop.main.add(timer, forMode: .common)`, or wrap updates in `DispatchQueue.main.async`.

### 10. `book` Property on ReaderViewModel Is `let` -- Metadata Changes Don't Propagate
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/ViewModels/ReaderViewModel.swift`, line 7
- **Category:** Bug / Inconsistency
- **Severity:** Major
- **Description:** `let book: Book` means the ReaderViewModel's book is immutable. When `saveEPUBMetadata` is called (line 514), a local copy `var updatedBook = book` is created and modified, but `self.book` remains unchanged. The `ReaderView` continues displaying the old title and author from `viewModel.book.title` and `viewModel.book.author`. The NowPlaying service also continues using the stale title/author from `self.book`.
- **Suggested Fix:** Change `let book: Book` to `@Published var book: Book` so that updates to the title/author are reflected in the UI and NowPlaying.

### 11. NowPlayingService Never Removes Remote Command Targets
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Services/NowPlayingService.swift`, lines 30-75
- **Category:** Code Quality
- **Severity:** Major
- **Description:** Each call to `setupRemoteCommands()` calls `addTarget` on the shared `MPRemoteCommandCenter`, but there is no corresponding `removeTarget` call. If multiple `NowPlayingService` instances are created (one per ReaderViewModel, one per open book), each adds its own targets. Over time this accumulates handlers and causes multiple callbacks per media key press.
- **Suggested Fix:** Call `removeTarget` before `addTarget`, or store the handler tokens and remove them in `deinit`.

### 12. Word Count Calculation Inaccurate
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Models/DocumentContent.swift`, lines 73-75
- **Category:** Bug
- **Severity:** Major
- **Description:** `Chapter.wordCount` splits only on space characters: `text.split(separator: " ").count`. This does not account for tabs, newlines, or multiple consecutive spaces. A chapter with text separated by newlines (no spaces) would count as 1 word. The word count feeds into all time estimates.
- **Suggested Fix:** Use `text.split(whereSeparator: { $0.isWhitespace }).count` or use `enumerateSubstrings(in:, options: .byWords)` for more accurate counts.

---

## Minor Issues

### 13. `chapterStartOffset` Returns 0 for Index 0 Even If Called With Negative
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Models/DocumentContent.swift`, lines 35-38
- **Category:** Bug
- **Severity:** Minor
- **Description:** The guard `chapterIndex > 0 && chapterIndex < chapters.count` returns 0 for both negative indices and index 0. A negative index should arguably be treated as an error. Also, this means `chapterStartOffset(0)` returns 0, which is correct, but the logic conflates "invalid" with "first chapter".
- **Suggested Fix:** Consider using `guard chapterIndex >= 0 && chapterIndex < chapters.count else { return 0 }` and handle index 0 explicitly inside the body.

### 14. `isCurrentHeading` Logic Is Imprecise
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Views/Reader/HeadingNavigatorView.swift`, lines 81-84
- **Category:** Bug
- **Severity:** Minor
- **Description:** `isCurrentHeading` returns true for ALL headings in the current chapter whose `characterOffset <= currentCharacterOffset`. This means multiple headings can be marked as "current" simultaneously, including all prior headings in the chapter. The last such heading should be the current one, but the view will visually mark all prior headings as current (showing the speaker icon on all of them).
- **Suggested Fix:** Find the *last* heading before the current offset in the current chapter, and only mark that one as current. Or compare each heading against the *next* heading's offset.

### 15. Notification-Based Architecture Lacks Type Safety
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/App/MenuCommands.swift` (throughout)
- **Category:** Code Quality
- **Severity:** Minor
- **Description:** The app uses 13+ `NotificationCenter` notifications for communication between menu commands, ContentView, and ReaderViewModel. These are stringly-typed, have no payload type checking, and make it impossible to determine which reader should respond when multiple books are open. All open ReaderViewModels receive and respond to every notification (e.g., pressing Space will toggle playback on ALL open books).
- **Suggested Fix:** Use a `FocusedValue` or `@FocusedObject` approach to target commands to the active reader, or use a centralized command dispatcher that knows which reader is active.

### 16. `cancellables` as @State in ContentView
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Views/ContentView.swift`, line 9
- **Category:** Code Quality
- **Severity:** Minor
- **Description:** `@State private var cancellables = Set<AnyCancellable>()` stores Combine subscriptions in `@State`. `@State` is designed for value types that SwiftUI manages. Storing reference-type containers in `@State` that are mutated via `store(in:)` can lead to unexpected behavior because SwiftUI may not correctly track mutations.
- **Suggested Fix:** Use a `@StateObject` wrapper or store the subscriptions in a separate `ObservableObject` class.

### 17. `importAndOpenFiles` vs `importFiles` Inconsistent Security Scoping
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/ViewModels/LibraryViewModel.swift`, lines 42-73 vs 78-103
- **Category:** Inconsistency
- **Severity:** Minor
- **Description:** `importAndOpenFiles` (for Finder "Open With") starts security scoping with `let didAccess = url.startAccessingSecurityScopedResource()` and conditionally stops with `if didAccess { ... }`. `importFiles` (for file importer) uses `guard url.startAccessingSecurityScopedResource() else { continue }`, skipping files that fail to access. The behavior is inconsistent: one method skips files, the other attempts them anyway.
- **Suggested Fix:** Unify the approach. For Finder-opened files, security scoping may not be needed, so the conditional approach is fine. But the two methods should document why they differ.

### 18. `previewVoice` Duplicates Rate Calculation Logic
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Views/Settings/SettingsView.swift`, lines 75-76
- **Category:** Inconsistency
- **Severity:** Minor
- **Description:** The rate calculation `0.5 * (settingsViewModel.wordsPerMinute / 190.0)` is hardcoded here and separately in `SpeechService.rateForCurrentWPM()`. The baseline WPM (190.0) is duplicated and could drift.
- **Suggested Fix:** Expose a static helper on `SpeechService` for rate calculation, or call `SpeechService.rateForCurrentWPM()` directly.

### 19. Accessibility: `FolderRow` Uses `onTapGesture` Without Default Accessibility Action
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Views/Library/LibraryView.swift`, lines 29-31
- **Category:** Accessibility
- **Severity:** Minor
- **Description:** `FolderRow` has an `onTapGesture` to navigate into the folder and the row declares `.accessibilityAddTraits(.isButton)` with a hint. However, there is no `.accessibilityAction(.default)` matching the tap gesture. VoiceOver users can activate the button trait, but the `onTapGesture` may not be reliably invoked by VoiceOver activation on all macOS versions.
- **Suggested Fix:** Add `.accessibilityAction(.default) { libraryViewModel.navigateToFolder(folder.fullPath) }` to the row.

### 20. Accessibility: Sleep Timer Countdown Not Live-Announced
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Views/Reader/ReaderView.swift`, lines 184-195
- **Category:** Accessibility
- **Severity:** Minor
- **Description:** The sleep timer countdown text in `BookInfoBar` and `PlaybackControlsView` updates every second but is not marked with `.accessibilityValue` or announced as a live region. VoiceOver users have no way to know the timer is counting down without manually navigating to the element.
- **Suggested Fix:** Consider adding periodic VoiceOver announcements at key intervals (e.g., 5 minutes, 1 minute remaining), or mark the element with a live-region trait.

### 21. Accessibility: Loading Spinner Lacks Detail
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Views/Reader/ReaderView.swift`, line 13
- **Category:** Accessibility
- **Severity:** Minor
- **Description:** `ProgressView("Loading book...")` does not have an explicit accessibility label. While SwiftUI auto-labels ProgressView, VoiceOver users do not know *which* book is loading.
- **Suggested Fix:** Use `.accessibilityLabel("Loading \(viewModel.book.title)")`.

### 22. `BookRow` Double-Tap vs Single Tap
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Views/Library/LibraryView.swift`, line 48
- **Category:** Accessibility
- **Severity:** Minor
- **Description:** `BookRow` uses `.onTapGesture(count: 2)` for opening, but the accessibility hint says "Double-tap to open book." In VoiceOver, "double-tap" is the standard activation gesture (equivalent to a single click), so the hint is technically correct for VoiceOver users. However, for non-VoiceOver users, requiring a double-click on a list row is unusual for macOS and there is no single-tap handler, meaning a single click does nothing visible.
- **Suggested Fix:** Consider adding a single-click selection state, or make the primary action a single click/tap.

### 23. Missing Error Handling for `extractString` in EPUBParser
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Parsers/EPUBParser.swift`, line 334
- **Category:** Inconsistency
- **Severity:** Minor
- **Description:** `extractString` throws `EPUBParserError.missingContainer` for *any* missing entry, not just the container.xml. If the OPF file is missing, the error message will say "missing META-INF/container.xml" which is misleading.
- **Suggested Fix:** Use a more generic error case (e.g., `missingEntry(String)`) or check which path failed and throw the appropriate error.

### 24. `onChange(of:)` Uses Deprecated iOS 16 / macOS 13 Signature
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Views/ContentView.swift`, line 47
- **Also:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Views/Settings/SettingsView.swift`, line 35
- **Category:** Code Quality
- **Severity:** Minor
- **Description:** `onChange(of:) { _ in ... }` uses the deprecated single-parameter closure form. In macOS 14+ / iOS 17+, the preferred form is `onChange(of:) { oldValue, newValue in ... }`.
- **Suggested Fix:** Migrate to the new two-parameter form, or add `#available` checks if supporting older OS versions.

### 25. `@Published` Property Modified from Background Thread Risk
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/ViewModels/ReaderViewModel.swift`, lines 207-231
- **Category:** Code Quality
- **Severity:** Minor
- **Description:** `loadContent()` dispatches to a background queue and then dispatches back to main to set `content`, `headings`, `epubMetadata`, and `isLoading`. The `[weak self]` in the background closure is good, but if `self` is deallocated between the background dispatch and the main dispatch, the inner `self.` references will silently do nothing. More importantly, the outer `guard let self = self` on line 208 creates a strong reference for the duration of the background work, preventing deallocation even if the user navigates away.
- **Suggested Fix:** Use `[weak self]` in both the outer and inner closures. Use Swift concurrency (`Task`, `@MainActor`) for cleaner lifecycle management.

### 26. `allHeadings` Computed Property Is O(n*m) and Called Frequently
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Models/DocumentContent.swift`, lines 17-27
- **Category:** Code Quality
- **Severity:** Minor
- **Description:** `allHeadings` iterates all chapters and all headings each time it is called. In `ReaderViewModel`, methods like `nextHeading()`, `previousHeading()`, `timeEstimateForHeading()`, etc. each call `content.allHeadings`, meaning it is recomputed on every heading navigation or time estimate. For large books this is wasteful.
- **Suggested Fix:** Cache `allHeadings` after parsing, or compute it once and store it on the `DocumentContent`.

### 27. `skipWords` Clamps to `chapter.text.count - 1` Which May Still Be Out of Bounds
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/ViewModels/ReaderViewModel.swift`, line 371
- **Category:** Bug
- **Severity:** Minor
- **Description:** If `chapter.text` is empty (count == 0), then `chapter.text.count - 1` is -1 (Int underflow in the context of `max(0, ...)`), which actually works out to 0 due to `max`. However, the subsequent code on line 376 checks `newOffset < text.count` but `text.count` for an empty string is 0, so it would skip the word-boundary snapping. The edge case is handled, but the intent is unclear.
- **Suggested Fix:** Add an early return if `chapter.text.isEmpty`.

### 28. `speechSettingsChanged` Notification Can Cause Redundant Reloads
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/ViewModels/SettingsViewModel.swift`, line 91
- **Also:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Services/SpeechService.swift`, lines 46-48
- **Category:** Code Quality
- **Severity:** Minor
- **Description:** Both `selectedVoiceID` and `wordsPerMinute` have `didSet` that calls `broadcastChanges()`, which fires `speechSettingsChanged`. If both change, two notifications fire. Each notification causes `SpeechService.reloadSettings()` which reads from UserDefaults. With `@AppStorage`, the UserDefaults write for the second property may not have committed when the first notification fires.
- **Suggested Fix:** Debounce the notification (e.g., coalesce with `DispatchQueue.main.async`).

### 29. Accessibility: "Reading progress" Container Label Overrides Children
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Views/Reader/ReaderView.swift`, lines 200-201
- **Category:** Accessibility
- **Severity:** Minor
- **Description:** `BookInfoBar` uses both `.accessibilityElement(children: .contain)` and `.accessibilityLabel("Reading progress")`. When `.contain` is used, children are individually accessible, but the container label "Reading progress" may be announced before each child element, which is redundant since each child already has its own descriptive label.
- **Suggested Fix:** Remove the `.accessibilityLabel` on the container, or use `.accessibilityElement(children: .combine)` if you want a single combined element.

### 30. Keyboard Shortcut Conflict: Two Escape Shortcuts in MetadataEditorView
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Views/Reader/MetadataEditorView.swift`, lines 25 and 103
- **Category:** Inconsistency
- **Severity:** Minor
- **Description:** Both the "Done" button (line 25) and the "Cancel" button (line 103) have `.keyboardShortcut(.escape)`. Pressing Escape will trigger one of them non-deterministically, but "Done" (which does nothing but dismiss) and "Cancel" (which also dismisses without saving) behave the same, so this is mostly a code clarity issue. However if "Done" behavior ever changes, the conflict becomes a problem.
- **Suggested Fix:** Remove the `.keyboardShortcut(.escape)` from the "Done" button since "Cancel" is the conventional Escape target.

### 31. `estimatedReadingTime` Uses WPM but Multiplies by 60
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Models/DocumentContent.swift`, line 48
- **Category:** Code Quality
- **Severity:** Minor
- **Description:** The formula `Double(totalWordCount) / wpm * 60.0` correctly converts WPM to seconds, but the method name `estimatedReadingTime` and the return type `TimeInterval` (which is in seconds) could cause confusion if a caller assumes the return is in minutes. This is not a bug but a readability concern.
- **Suggested Fix:** Add a documentation comment clarifying the return value is in seconds.

### 32. `LibrarySortField.fileSize` Performs File I/O During Sort
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/ViewModels/LibraryViewModel.swift`, lines 184-187
- **Category:** Code Quality
- **Severity:** Minor
- **Description:** Sorting by file size calls `FileManager.default.attributesOfItem(atPath:)` inside the sort comparator, which performs disk I/O for every comparison. For N books, this is O(N log N) file system calls, which can be slow and blocks the main thread.
- **Suggested Fix:** Pre-compute file sizes into a dictionary before sorting, or cache file sizes on the `Book` model.

### 33. `Heading` Has `let id = UUID()` Which Breaks Hashable Stability
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Models/DocumentContent.swift`, lines 85-86
- **Category:** Code Quality
- **Severity:** Minor
- **Description:** `Heading` generates a new `id` every time it is created. Since `allHeadings` recomputes headings from chapters (creating new `Heading` instances with mutated `chapterIndex`), the IDs change each time `allHeadings` is called. Any SwiftUI view or rotor using heading IDs will see them as new elements each time, breaking animations and VoiceOver rotor stability.
- **Suggested Fix:** Derive a stable ID from the heading's content and position (e.g., `"\(chapterIndex)-\(characterOffset)-\(text)"`), or cache heading instances.

### 34. `announceToVoiceOver` Uses `NSApp.keyWindow as Any` Which May Be Nil
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/ViewModels/ReaderViewModel.swift`, lines 548-549
- **Category:** Accessibility
- **Severity:** Minor
- **Description:** `NSApp.keyWindow` can be nil if no window has key status (e.g., during app launch or when a system dialog is frontmost). Passing `nil as Any` as the element may cause the announcement to be silently dropped.
- **Suggested Fix:** Guard against nil: `guard let window = NSApp.keyWindow else { return }`.

### 35. No Validation of Folder Names
- **File:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/ViewModels/LibraryViewModel.swift`, line 216
- **Also:** `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/TextMouth/Models/Library.swift`, line 60
- **Category:** Bug
- **Severity:** Minor
- **Description:** Folder names are not validated for special characters like `/`, which is used as the path separator internally. A folder named "Sci/Fi" would create a malformed path that could break folder navigation, subfolder queries, and book filtering.
- **Suggested Fix:** Strip or reject `/` characters (and other filesystem-unsafe characters) from folder names before creation.

---

## Summary

| Severity | Count |
|----------|-------|
| Critical | 3     |
| Major    | 9     |
| Minor    | 23    |
| **Total**| **35**|

### Top Priority Fixes
1. Fix the force-unwrap crash in heading level extraction (issues 1)
2. Fix the voice preview memory leak (issue 3)
3. Fix hardcoded skip labels that mislead users and VoiceOver (issue 4)
4. Fix heading offset search returning wrong positions for duplicate headings (issue 5)
5. Fix duplicate heading detection in PlainTextParser (issues 6, 7)
6. Fix stale `book` property after metadata edit (issue 10)
7. Fix NowPlayingService accumulating remote command handlers (issue 11)
8. Fix word count calculation that ignores newlines/tabs (issue 12)
