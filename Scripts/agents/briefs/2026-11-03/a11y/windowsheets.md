# a11y task `windowsheets`: the Export, Transcription, and import-question sheets

Slug `a11y-windowsheets`, branch `a11y/windowsheets` (from `team/a11y`, after the `focus` and `textareas` tasks are in). Read `../ios0-common.md` ("The worker's part", and the rules) and `../team-a11y.md` first.

## Files (census errors, 40 in all)

- `TextMouth/Views/Export/BookExportPresentation.swift` (10), `BookExportSheet.swift` (6), `BrailleExportOptionsView.swift` (1)
- `TextMouth/Views/Transcription/TranscriptionPresentation.swift` (10), `TranscriptionSheet.swift` (1), `TranscriptCleanupSheet.swift` (1)
- `TextMouth/Views/Library/ImportDecisionPresenter.swift` (7), `AddToLibraryHost.swift` (4)

Errors that name `SilentKeyEquivalent`, `VoiceOverFocus`, or `LibraryWindowRouter` members are cascades from other work; list them but do not fix them.

## Mechanisms (decided; do not invent others)

1. **`NSWindow` becomes `PlatformWindow`** everywhere (rule 3), including `[NSWindow]`, `NSWindow?`, `weak var ...: NSWindow?`, `as? NSWindow`. This also clears the `ImportOrigin(window:)` label errors ("expected windowNumber:"), which are cascades of `NSWindow` missing.
2. **`import AppKit`** in a shared file becomes the rule 2 form.
3. **`NSApp.keyWindow`, `NSApp.isActive`, `NSApplication.didBecomeActiveNotification`** are named `PlatformApplication.keyWindow`, `.isActive`, and `.didBecomeActiveNotification` (`TextMouth/Platform/PlatformApplication.swift`, already on your branch; read it first). On the Mac each is exactly the old expression, so swapping the name is a platform alias in the projection's eyes; no `#if` and no `#else` branch is needed. Apply it at: BookExportPresentation.swift:53, ImportDecisionPresenter.swift:88, TranscriptionPresentation.swift:287, TranscriptCleanupSheet.swift:38. Where the same function also uses an AppKit-only member (`window.attachedSheet` in `ImportDecisionPresenter.userIsIn(_:)`), wrap that function's Mac body in `#if os(macOS)` unchanged, and let the iOS body be `PlatformApplication.isActive && window?.isKeyWindow == true`.
4. (Folded into 3.)
5. **`.onExitCommand { model.escape() }`** (TranscriptionSheet.swift:37, TranscriptCleanupSheet.swift:35): the postfix `#if os(macOS)` form, exactly as ios0-common.md shows.
6. **`.toggleStyle(.checkbox)`** (BookExportSheet.swift:96, BrailleExportOptionsView.swift:424) becomes `.checkboxToggleStyle()` (rule 4).
7. `BookExportSheet.swift:137` and `:212` ("requires wrapper ObservedObject<BookExportModel>.Wrapper"): expected to be cascades of the `NSWindow` error in the same file. Fix the NSWindow errors first, rerun the census, and only then look at them. If they persist, find the cause in the file, make the smallest change that is a wrapper, and report it to me.
8. Do not change any label, hint, or spoken sentence.

## Checks and tests

- Order: `make typecheck-ios CENSUS=1` until the eight files show only cascades; `make typecheck-mac`; `make mac-projection BASE=team/a11y DIFF=1` (expect only alias, wrapper, helper, and import lines); `make lint-a11y LINT_BASE=team/a11y`.
- Train: areas `export,transcripts,sheets,library`; classes `BookExportSheetTests,TranscriptionSheetViewTests,TranscriptCleanupSheetTests` plus any test class that names `ExportCommandRouting`, `ImportOrigin`, `ImportDecisionPresenter`, `AddToLibraryHost` or `TranscriptionPresentation` (grep). Wait for the result.

## Completion check

The census shows none of the eight files except cascades from other teams' files, which you list.
