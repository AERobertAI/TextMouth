# a11y task `textareas`: the read-only text area, the paste view, and four small sheets

Slug `a11y-textareas`, branch `a11y/textareas` (from `team/a11y`). Read `../ios0-common.md` ("The worker's part", and the rules) and `../team-a11y.md` first. Another worker, `a11y-focus`, is at the same time moving `Views/VoiceOverFocus.swift` and changing `Services/VoiceOverAnnouncer.swift`; do not touch those. Errors in your files that name `VoiceOverFocus`, `StandardVoiceOverFocus`, `SilentKeyEquivalent` (team shell's file) or `NSAccessibilityPriorityLevel` are theirs and go away when their work lands.

## Files and decisions

1. `TextMouth/Views/ReadOnlyTextArea.swift` (12 errors): an `NSViewRepresentable` around `NSTextView`.
   - `git mv` it, unchanged, to `TextMouth/Platform/macOS/Views/ReadOnlyTextArea.swift`, in a commit of its own. First `grep -rn "ReadOnlyTextArea"` over `TextMouthTests`, `TextMouthProductionTests`, `Scripts` (not the briefs): report anything that reads its path.
   - Write the iOS twin, `TextMouth/Platform/iOS/Views/ReadOnlyTextArea+iOS.swift`, starting `// Phase 0 stand-in: ...`: `struct ReadOnlyTextArea: UIViewRepresentable` with the same stored properties and memberwise initializer (`text: String`, `label: String`, `var takesFocus = false`), used as `ReadOnlyTextArea(text:label:)` and `ReadOnlyTextArea(text:label:takesFocus:)` followed by `.frame(...)`.
   - Its view is a `UITextView`: `isEditable = false`, `isSelectable = true`, `font = UIFont.preferredFont(forTextStyle: .body)` with `adjustsFontForContentSizeCategory = true`, `text = text`, `accessibilityLabel = label`, `isAccessibilityElement = true`, a small `textContainerInset`, and the same `updateUIView` that keeps the text and label current (assign `text` only when it differs). `takesFocus`: after the view is in a window, post `UIAccessibility.post(notification: .screenChanged, argument: textView)` once, with a weak reference, 0.2 seconds later, as the Mac delays. Comment the mapping from the Mac's `makeFirstResponder`.
   - Mark the type `@MainActor` only if the Mac's is not (it is not; `UIViewRepresentable` requirements are main-actor already).
2. `TextMouth/Views/Library/TextInputView.swift` (3 errors). **The charter calls this an NSTextView wrapper; it is not.** It is a SwiftUI view with a `TextEditor`, and the file also holds `TextImportPolicy`, which other files use, so it stays in place and is wrapped:
   - `import AppKit` becomes the rule 2 form.
   - `pasteFromClipboard()`: the Mac body in `#if os(macOS)` unchanged; the iOS branch sets `textContent` from `UIPasteboard.general.string` when it is not nil.
   - `openInEditor()`: the whole Mac body in `#if os(macOS)` unchanged (it uses `NSWorkspace`); the iOS branch does nothing and has a comment: phase 0, iOS has no external editor; phase 1 decides. It must not throw or trap.
3. `TextMouth/Views/Reader/SpeechRefusalReportSheet.swift` (5 errors):
   - `import AppKit`: rule 2 form.
   - `copyDetails(of:to:)` takes an `NSPasteboard`, and the sheet calls it as `Self.copyDetails(of: report, to: .general)`, which also reads on iOS if an overload takes a `UIPasteboard`. So keep the Mac function in `#if os(macOS)` and write the iOS function after `#else`: same name and labels, `to pasteboard: UIPasteboard`, sets `pasteboard.string = report.text`, announces `SpeechRefusalWording.copiedAnnouncement` (the Mac says the not-copied sentence when the pasteboard refuses; on iOS the setter cannot fail, so announce copied). `TextMouthProductionTests/SpeechRefusalSheetTests.swift:93` calls the Mac version: do not edit it.
4. `TextMouth/Views/Feeds/FeedInfoSheet.swift` (5 errors): `import AppKit` rule 2 form; the two `.toggleStyle(.checkbox)` become `.checkboxToggleStyle()` (rule 4). The `.frame` and `SilentKeyEquivalent` errors are cascades.
5. `TextMouth/Views/Library/LibraryIndexRecoveryViews.swift` (1 error): the "Show Saved Copy in Finder" button uses `NSWorkspace`. Wrap the whole `Button("Show Saved Copy in Finder") { ... }` and the lines that belong to it in `#if os(macOS)`, text unchanged, with nothing in an `#else` (the saved copy's path is already shown on the line above as "Saved copy"). Comment why.

## Checks and tests

- Order: `make typecheck-ios CENSUS=1` (until `grep -E "ReadOnlyTextArea|TextInputView|SpeechRefusalReportSheet|FeedInfoSheet|LibraryIndexRecoveryViews" errors.txt` shows nothing but the cascades named above), then `make typecheck-mac`, then `make mac-projection BASE=team/a11y DIFF=1`. Expect only the moves, the import wrappers, the `#if` wrappers and the helper calls.
- `make lint-a11y LINT_BASE=team/a11y`.
- Train: areas `accessibility,feeds,library,transcripts`, classes `SpeechRefusalSheetTests` plus the test classes that name `ReadOnlyTextArea`, `TextInputView`, `FeedInfoSheet` or `LibraryIndexRecovery` (grep for them); wait for the result.

## Completion check

The census shows no error in these five files that is not a cascade of the focus task's or the shell team's work, and `ReadOnlyTextArea+iOS.swift` is clean. List any cascade you saw.
