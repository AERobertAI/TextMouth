# Task engine-editor: the editor round trip

You are worker `engine-editor` of team `engine` (lead `engine-lead`). Read `Scripts/agents/briefs/2026-11-03/ios0-common.md` (the pattern; its rules override this brief) and `team-engine.md` beside it. Branch: `git checkout -b engine/editor team/engine`.

## Files and goal

- `TextMouth/Services/PackageFileEditing.swift` (16 errors)
- `TextMouth/Services/BookTextEditor.swift` (10)
- `TextMouth/Services/BookManifestEditor.swift` (6)
- New files you create under `TextMouth/Platform/iOS/Services/`, and the tests of these files.

The census errors are pasted at the end. Done when the census shows none of these files and none caused by your stand-ins.

## Decisions (settled; do not reopen)

1. **Move all three files unchanged** to `TextMouth/Platform/macOS/Services/` (one `git mv` commit per file or one for the three; the text unchanged). Before it, `grep -rn "Services/PackageFileEditing\|Services/BookTextEditor\|Services/BookManifestEditor" TextMouthTests TextMouthProductionTests Scripts project.yml`: a test that reads a file by path gets its path updated in the same commit, and you report it.
2. **Stand-ins** in `TextMouth/Platform/iOS/Services/PackageFileEditing+iOS.swift`, `BookTextEditor+iOS.swift`, `BookManifestEditor+iOS.swift`, each starting `// Phase 0 stand-in: ...` (what the Mac version does: opens a book's text or manifest file in the user's own app and takes the saved file back; what iOS does: nothing, or throws). Same type names, `@MainActor` where the Mac twin is, and exactly the members shared code uses. Find them with `grep -rn "BookTextEditor\|BookManifestEditor\|PackageFileEditing" TextMouth --include='*.swift'` outside the three files. The lead's list:
   - `BookTextEditor.shared`; `edit(_:choosingApp:in:from:)` (the window parameter is `PlatformWindow?`; look at the Mac signature and callers in ReaderBookCommands and LibraryView); `canEditText(of:isTranscribed:)` static, which returns `false` on iOS; `pauseEditing(of:)` async, returning `true` (nothing is being edited, so nothing blocks), and `resumeEditing(of:)` async, doing nothing; `explainedPreference` with the `.key` that ConfigService reads (give it the same key string as the Mac, by reusing `StoredPreference` if it compiles on iOS).
   - `BookManifestEditor.shared`, `edit(...)`, `end(_:)`, the `editor:` parameter type used by LibraryViewModel+ManifestEdits (check what it calls), `explainedPreference.key`, and whatever ReaderViewModel (`manifestEditor`, `lookForOutsideManifestEdit`) calls.
   - `PackageFileEditing.openWithWorkspace(_:app:)` static (TranscriptCleanupSheetModel) throws `IOSUnavailable.feature("Editing a book's text in another app")`; `edit(...)` of the text editor stand-in does nothing (it returns `Void`), or throws if its Mac twin throws.
   - A member that cannot work throws `IOSUnavailable.feature("Editing a book's text in another app")` or `.feature("Editing a book's manifest in another app")`. No traps.
3. If a stand-in's shape needs a type that only a moved file declares (`Wording`, `EditorChoice`), copy just what the callers use, in the stand-in, and say so in its comment.
4. Add no `@unchecked Sendable` or `nonisolated(unsafe)`.

## Mac test areas to request from the train

`library`, `places` (classes to name: any `BookTextEditor...Tests`, `BookManifestEditor...Tests`, `PackageFileEditing...Tests`: `ls TextMouthProductionTests | grep -i "editor\|PackageFile"`).

## Watch for

Another worker (`engine-helpers`) runs beside you, in WatchedProcess, OrphanedConversionSweep, and PlaybackMemoryGuard. Touch none of them. `ConfigService.swift` is not yours: if the stand-in cannot satisfy its line 742 as it stands, post a finding to `engine-lead` rather than editing it.

## The census's errors for your files (32; census of 72d9f5cd)

```
TextMouth/Services/BookManifestEditor.swift:56:18: error: @escaping attribute only applies to function types
TextMouth/Services/BookManifestEditor.swift:57:20: error: @escaping attribute only applies to function types
TextMouth/Services/BookManifestEditor.swift:59:58: error: cannot find 'NSApp' in scope
TextMouth/Services/BookManifestEditor.swift:87:91: error: cannot find type 'NSWindow' in scope
TextMouth/Services/BookManifestEditor.swift:256:61: error: cannot find type 'NSWindow' in scope
TextMouth/Services/BookManifestEditor.swift:262:63: error: cannot find type 'NSWindow' in scope
TextMouth/Services/BookTextEditor.swift:84:18: error: @escaping attribute only applies to function types
TextMouth/Services/BookTextEditor.swift:84:28: error: unsupported recursion for reference to type alias 'Explainer' of type 'BookTextEditor'
TextMouth/Services/BookTextEditor.swift:85:20: error: @escaping attribute only applies to function types
TextMouth/Services/BookTextEditor.swift:85:30: error: unsupported recursion for reference to type alias 'AppChooser' of type 'BookTextEditor'
TextMouth/Services/BookTextEditor.swift:87:58: error: cannot find 'NSApp' in scope
TextMouth/Services/BookTextEditor.swift:115:91: error: cannot find type 'NSWindow' in scope
TextMouth/Services/BookTextEditor.swift:142:97: error: cannot find type 'NSWindow' in scope
TextMouth/Services/BookTextEditor.swift:156:92: error: cannot find type 'NSWindow' in scope
TextMouth/Services/BookTextEditor.swift:385:61: error: cannot find type 'NSWindow' in scope
TextMouth/Services/BookTextEditor.swift:391:63: error: cannot find type 'NSWindow' in scope
TextMouth/Services/PackageFileEditing.swift:17:70: error: cannot find type 'NSWindow' in scope
TextMouth/Services/PackageFileEditing.swift:20:71: error: cannot find type 'NSWindow' in scope
TextMouth/Services/PackageFileEditing.swift:85:18: error: @escaping attribute only applies to function types
TextMouth/Services/PackageFileEditing.swift:86:20: error: @escaping attribute only applies to function types
TextMouth/Services/PackageFileEditing.swift:104:74: error: cannot find type 'NSWindow' in scope
TextMouth/Services/PackageFileEditing.swift:145:22: error: cannot find 'NSApplication' in scope
TextMouth/Services/PackageFileEditing.swift:167:51: error: cannot find type 'NSWindow' in scope
TextMouth/Services/PackageFileEditing.swift:190:81: error: cannot find type 'NSWindow' in scope
TextMouth/Services/PackageFileEditing.swift:191:21: error: cannot find 'NSAlert' in scope
TextMouth/Services/PackageFileEditing.swift:202:61: error: cannot infer contextual base in reference to member 'alertFirstButtonReturn'
TextMouth/Services/PackageFileEditing.swift:209:83: error: cannot find type 'NSWindow' in scope
TextMouth/Services/PackageFileEditing.swift:210:21: error: cannot find 'NSOpenPanel' in scope
TextMouth/Services/PackageFileEditing.swift:217:39: error: reference to member 'application' cannot be resolved without a contextual type
TextMouth/Services/PackageFileEditing.swift:219:23: error: cannot find type 'NSApplication' in scope
TextMouth/Services/PackageFileEditing.swift:234:25: error: cannot find 'NSWorkspace' in scope
TextMouth/Services/PackageFileEditing.swift:241:29: error: cannot find 'NSWorkspace' in scope
```
