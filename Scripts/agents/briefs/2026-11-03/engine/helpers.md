# Task engine-helpers: the helper programs and the memory guard

You are worker `engine-helpers` of team `engine` (lead `engine-lead`). Read `Scripts/agents/briefs/2026-11-03/ios0-common.md` (the pattern; its rules override this brief) and `team-engine.md` beside it. Branch: `git checkout -b engine/helpers team/engine`.

## Files and goal

- `TextMouth/Services/WatchedProcess.swift` (10 errors)
- `TextMouth/Services/OrphanedConversionSweep.swift` (12) and `OrphanedConversionSweep+Textutil.swift` (0, but see below)
- `TextMouth/Services/PlaybackMemoryGuard.swift` (3)
- New files you create under `TextMouth/Platform/iOS/Services/`, and tests of these files.

The census errors for these files are pasted at the end. Done when the census (`make typecheck-ios CENSUS=1`) shows none of these files and none caused by your stand-ins.

## Decisions (settled; do not reopen)

1. **WatchedProcess.** `git mv TextMouth/Services/WatchedProcess.swift TextMouth/Platform/macOS/Services/WatchedProcess.swift` in a commit of its own, text unchanged. Before it, `grep -rn "Services/WatchedProcess\|Services/OrphanedConversionSweep" TextMouthTests TextMouthProductionTests Scripts project.yml` (none were found by the lead; confirm), and run `grep -rn "WatchedProcess" TextMouth --include='*.swift'` to list the members shared code uses. The lead's list: `WatchedProcess.Limits` (memberwise init with `maximumSeconds`, `maximumResidentBytes`, `maximumStalledSeconds`, `pollInterval`, `maximumCPUSeconds`, `maximumOutputBytes`, and `effectiveMaximumCPUSeconds`), `.KillReason` (all cases, and `.words`), `.Outcome`, `.outputFileSuffix`, `.residentMemory(of:)`, `.run(...)`, `.runCapturingOutput(...)`, `.terminateAll()`. Check the callers (ImportAudioConverter, AudioFileInfo, TextutilConverter, BrailleTranslator, MacBrailleTableCheck, PlaybackMemoryGuard) for any member beyond these and cover it too.
2. **The stand-in:** `TextMouth/Platform/iOS/Services/WatchedProcess+iOS.swift`, `enum WatchedProcess`, beginning `// Phase 0 stand-in: ...` (what the Mac does: runs textutil, afconvert, afinfo and the braille helper as watched child processes under a watchdog; what iOS does instead: starts nothing). It copies the three plain value types (`Limits`, `KillReason` with its `words`, `Outcome`) from the Mac file with the same members, since callers build and switch over them; say so in the comment (a phase 1 clean-up could share them). `run` and `runCapturingOutput` keep their full parameter lists (including defaults) and throw `IOSUnavailable.feature("Converting this kind of file")`. `residentMemory(of:)` returns nil, `terminateAll()` does nothing, `outputFileSuffix` is the same string. Add no `@unchecked Sendable` or `nonisolated(unsafe)`.
3. **OrphanedConversionSweep.** Move it unchanged to `TextMouth/Platform/macOS/Services/`; its stand-in `OrphanedConversionSweep+iOS.swift` has the three `sweep...InBackground()` methods (see AppDelegate) and any other member shared code calls, each doing nothing. `OrphanedConversionSweep+Textutil.swift` extends the same type: if it compiles on iOS against the stand-in as it is (it uses no libproc/Process), leave it where it is and check the stand-in carries what it calls; if not, move it too, unchanged. Say which in your report.
4. **PlaybackMemoryGuard.** Wrap the NSAlert and NSApplication code in place (`#if os(macOS)` ... `#else` ... `#endif`, Mac text unchanged). On iOS the guard shows no alert: the `#else` branch does the least it safely can, with a comment. Its `WatchedProcess.terminateAll()` call stays as it is (the stand-in covers it). Not one line of its Mac behavior changes.

## Mac test areas to request from the train

`import`, `ogg`, `braille` (classes to name: `WatchedProcessSafetyTests`, `OrphanedConversionSweepTests`, `TextutilLeftoverSweepTests`, `PlaybackMemoryGuardTests` if it exists).

## Watch for

WatchedProcess's watchdog and the Ogg conversion protect the user's Mac from a hung decoder (October 14, 34 GB). The move must leave the Mac file byte-identical (`git diff -M --stat` shows a pure rename). Do not run any test yourself that starts a real converter; only the train runs tests.

## The census's errors for your files (25; census of 72d9f5cd)

```
TextMouth/Services/OrphanedConversionSweep.swift:238:24: error: cannot find 'proc_listallpids' in scope
TextMouth/Services/OrphanedConversionSweep.swift:238:41: error: 'nil' requires a contextual type
TextMouth/Services/OrphanedConversionSweep.swift:245:13: error: cannot find 'proc_listallpids' in scope
TextMouth/Services/OrphanedConversionSweep.swift:267:20: error: cannot find 'vnode_fdinfowithpath' in scope
TextMouth/Services/OrphanedConversionSweep.swift:268:39: error: cannot find type 'vnode_fdinfowithpath' in scope
TextMouth/Services/OrphanedConversionSweep.swift:269:15: error: cannot find 'proc_pidfdinfo' in scope
TextMouth/Services/OrphanedConversionSweep.swift:269:50: error: cannot find 'PROC_PIDFDVNODEPATHINFO' in scope
TextMouth/Services/OrphanedConversionSweep.swift:279:22: error: cannot find 'proc_pidpath' in scope
TextMouth/Services/OrphanedConversionSweep.swift:287:20: error: cannot find 'proc_bsdinfo' in scope
TextMouth/Services/OrphanedConversionSweep.swift:288:39: error: cannot find type 'proc_bsdinfo' in scope
TextMouth/Services/OrphanedConversionSweep.swift:290:15: error: cannot find 'proc_pidinfo' in scope
TextMouth/Services/OrphanedConversionSweep.swift:290:33: error: cannot find 'PROC_PIDTBSDINFO' in scope
TextMouth/Services/PlaybackMemoryGuard.swift:424:25: error: cannot find 'NSAlert' in scope
TextMouth/Services/PlaybackMemoryGuard.swift:447:9: error: cannot find 'NSApplication' in scope
TextMouth/Services/PlaybackMemoryGuard.swift:447:40: error: 'nil' requires a contextual type
TextMouth/Services/WatchedProcess.swift:104:20: error: cannot find 'proc_taskinfo' in scope
TextMouth/Services/WatchedProcess.swift:105:39: error: cannot find type 'proc_taskinfo' in scope
TextMouth/Services/WatchedProcess.swift:106:15: error: cannot find 'proc_pidinfo' in scope
TextMouth/Services/WatchedProcess.swift:106:33: error: cannot find 'PROC_PIDTASKINFO' in scope
TextMouth/Services/WatchedProcess.swift:172:65: error: cannot find type 'Process' in scope
TextMouth/Services/WatchedProcess.swift:217:81: error: cannot find type 'Process' in scope
TextMouth/Services/WatchedProcess.swift:218:22: error: cannot find 'Process' in scope
TextMouth/Services/WatchedProcess.swift:402:23: error: cannot find 'Process' in scope
TextMouth/Services/WatchedProcess.swift:414:40: error: cannot infer type of closure parameter '_' without a type annotation
TextMouth/Services/WatchedProcess.swift:467:42: error: cannot infer contextual base in reference to member 'uncaughtSignal'
```
