# Task media/windows: the Record window's and the audio editor's AppKit windows leave the shared build

Worker slug `media-windows`. Branch `media/windows`, from `team/media`. Lead: `media-lead`. Read `Scripts/agents/briefs/2026-11-03/ios0-common.md` (the pattern and "The worker's part") first; its rules override this brief. It is in the orchestrator's worktree: `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/.claude/worktrees/ios0/Scripts/agents/briefs/2026-11-03/ios0-common.md`.

## What to do

Four files are AppKit through and through. Move each, **unchanged**, with `git mv` (rule 1), in one commit that holds the four moves and nothing else:

- `TextMouth/Views/Recording/RecordingWindowController.swift` -> `TextMouth/Platform/macOS/Views/Recording/RecordingWindowController.swift`
- `TextMouth/Views/AudioEditor/AudioEditorWindowController.swift` -> `TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorWindowController.swift`
- `TextMouth/Views/AudioEditor/AudioEditorLauncher.swift` -> `TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorLauncher.swift`
- `TextMouth/Views/AudioEditor/AudioEditorEditMenu.swift` -> `TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorEditMenu.swift`

I checked: no test or script names these files by path. Re-run `grep -rnE "Views/(AudioEditor|Recording)" TextMouthTests TextMouthProductionTests Scripts --include='*.swift' --include='*.py' --include='*.sh'` before you commit; if it finds a hit, update that path in the same commit and report it. Do **not** run xcodegen and do **not** commit `project.pbxproj`: the lead regenerates it once after both workers are in (the type-check reads the folders, not the project).

## The census errors (101 of them, all in the four moved files)

They vanish with the move. Nothing else is needed for them.

## The stand-ins (rule: "Stand-ins for Mac-only types that shared code names")

Shared files still name three of the moved types. Add iOS stand-ins for exactly what they use, each in its own file starting with the comment `// Phase 0 stand-in: ...` (what the Mac version does and what iOS does instead). After the move, re-run `grep -rnw <Name> TextMouth --include='*.swift'` for each name to confirm the member list below is complete, and add any member the grep shows that I missed.

1. `TextMouth/Platform/iOS/Views/Recording/RecordingWindowController+iOS.swift`: `@MainActor final class RecordingWindowController` with
   - `static let shared` and `nonisolated static let windowIdentifier = "new-recording"` (the Mac's text);
   - `func attach(_ library: LibraryViewModel) {}`;
   - `func show(library: LibraryViewModel? = nil, recovered: [RecoveredTake] = [])`, doing nothing. Copy the Mac's real signature. If `RecoveredTake` is declared in the moved file, it is not available on iOS: then drop the `recovered` parameter, as no shared caller passes it (grep to be sure);
   - `func holdQuit(then quit: @escaping @MainActor @Sendable () -> Void) -> Bool` returning `false` (nothing to hold).
   The callers (MenuCommands, AddToLibraryHost, AppDelegate, KeyboardShortcutManager, MenuVisibilityManager) call these without `try`, so `show` does nothing rather than throwing. Say in the comment that phase 1 opens a recording screen here and that `IOSUnavailable.feature("Recording")` is the error to use if a throwing entry is ever needed.
2. `TextMouth/Platform/iOS/Views/AudioEditor/AudioEditorWindowController+iOS.swift`: `@MainActor final class AudioEditorWindowController` with `static let shared`, `nonisolated static let windowIdentifier = "audio-editor"`, and `holdQuit(then:) -> Bool` returning `false`. (AppDelegate and KeyboardShortcutManager are the shared users; confirm by grep.)
3. `TextMouth/Platform/iOS/Views/AudioEditor/AudioEditorLauncher+iOS.swift`: `@MainActor enum AudioEditorLauncher` with
   - `static func canEdit(_ book: Book) -> Bool` returning `false`;
   - `static func edit(_ book: Book, in library: LibraryViewModel, from window: PlatformWindow?)` doing nothing (the Mac's parameter is `NSWindow?`; the stand-in compiles only on iOS, where callers pass `PlatformWindow?`; comment that `IOSUnavailable.feature("Editing audio")` is the phase 1 error);
   - `static func describe(_ error: Error) -> String`, a copy of the Mac's few lines (an `AudioEditError` by its case name up to the first "(", any other error by domain and code), so the shared models' log lines read the same on iOS. Comment that it duplicates the Mac's `describe`, because the Mac's sits in a file that moved whole. `AudioEditError` is shared; confirm.
   `AudioEditorTrack`, `AudioEditorTracks`, `AudioEditorWindowing`, `AudioEditorAlerts`, `AudioEditorUndoManager`, `AudioEditorEditMenu`, `CloseAnswer`, `CloseQuestion`, and `AudioEditorUnsavedEditsAnswer` are used by no file outside the moved ones (I grepped): no stand-in for those.

Stand-ins are `@MainActor` as their Mac twins are. No traps, no `fatalError`, no force unwraps. Comment every member.

## The Mac stays the same

`make mac-projection BASE=team/media DIFF=1` must show nothing left for these four files (moves are accounted) and nothing for the stand-ins (iOS-only files).

## Checks

1. `make typecheck-ios CENSUS=1`, then one `grep -E "Views/(AudioEditor|Recording)/|Platform/iOS/Views/(Recording|AudioEditor)" <errors.txt>`: it must find nothing about the four moved files or your stand-ins. Errors in other teams' files that name these types are findings for me (`--to media-lead`), not yours to fix.
2. `make typecheck-mac`: 0 errors, 0 warnings.
3. `make mac-projection BASE=team/media DIFF=1`.
4. Train: `python3 -I Scripts/agents/build-train.py request --agent media-windows --branch media/windows --areas recording,editor,windows --classes RecordingWindowTests,RecordingQuitTests,AudioEditorWindowTests,AudioEditorShortcutTests,AudioEditorOpeningTests,AudioEditorSavingTests,AudioEditorEndToEndTests,LibraryFeedAudioEditTests`, then `python3 -I Scripts/agents/wait-for-result.py --agent media-windows` in the background. (If `python3 Scripts/test/run-area.py --list` shows no area by one of those names, use the nearest listed ones and say so.)

## Completion

The census lists none of the four moved files and none of your stand-ins; `make typecheck-mac` shows 0 errors and 0 warnings; the projection shows no remaining Mac change; the train is green. Two commits: (1) the four moves, (2) the three stand-ins. Finish as "The worker's part" step 7 says.
