# Task engine-nowplaying: Now Playing's Core Audio device watching

You are worker `engine-nowplaying` of team `engine` (lead `engine-lead`). Read `Scripts/agents/briefs/2026-11-03/ios0-common.md` (the pattern; its rules override this brief) and `team-engine.md` beside it. Branch: `git checkout -b engine/nowplaying team/engine`.

## Files and goal

- `TextMouth/Services/NowPlayingService.swift` (76 errors; 1,781 lines) and, only if needed, a new `TextMouth/Platform/macOS/Services/NowPlayingService+macOS.swift` and `TextMouth/Platform/iOS/Services/NowPlayingService+iOS.swift`.

Done when the census shows no error in NowPlayingService.swift. The errors, pasted at the end, are all in Core Audio's device API (`AudioObject...`, `kAudioHardware...`, `kAudioDeviceTransportType...`, `AudioObjectPropertyListenerBlock`), at lines 36-37 (`RemoteMediaCommandPolicy.isBluetoothTransport`), 332-334, 396-430 (stored properties and `init`), 1341-1375 (the listeners), 1562-1732 (the device queries and listener removal).

## Decisions (settled; do not reopen)

1. The service stays shared: Now Playing info, remote commands, the owner bookkeeping, and the route-change policy are what iOS needs. Only the device watching is Mac-only.
2. **Mechanism: the smaller projection wins.** The device queries (`currentDefaultOutputDeviceID`, `isBluetoothDevice`, `allAudioDeviceIDs`, the listener installation and removal at 1314-1420 and 1700-1740) are methods and can be moved, unchanged, into `extension NowPlayingService` in `Platform/macOS/Services/NowPlayingService+macOS.swift` (rule 5). A move leaves `private` members unreachable from the extension, so each such member's access level would change: that is a real change to a Mac file. So the usual choice is in-place `#if os(macOS)` ... `#else` ... `#endif` wraps, Mac text unchanged character for character, with the `#else` branch holding iOS stand-in bodies: the stored properties that need Core Audio types (`audioDeviceIDsProvider`, `deviceListListenerBlock`, the init parameter at 419-430) get an iOS spelling that has no Core Audio type (a closure returning `[UInt32]` is fine, since `AudioDeviceID` is `UInt32`), and the methods watch nothing. Decide per piece and compare with `make mac-projection BASE=team/engine DIFF=1`; the goal is no remaining Mac line.
3. `RemoteMediaCommandPolicy.isBluetoothTransport(_:)` (lines 35-40) compares against `kAudioDeviceTransportType...` constants that iOS lacks: on iOS it returns `false` (a comment says the iOS audio session reports the route type instead, phase 1).
4. iOS has the same members as the Mac (`handleDefaultOutputChange`, `handleDeviceListChange`, `refreshPreviousDeviceInfo`, the init parameters tests pass), watching nothing. Phase 1 will use the audio session's route-change notification: leave a comment saying so.
5. No trap in an iOS branch. No `@unchecked Sendable`, no `nonisolated(unsafe)`. The service is `@MainActor`: keep that.
6. The callers of NowPlayingService in other teams' files must keep compiling: before you rename or remove anything on iOS, `grep -rn "NowPlayingService\|NowPlayingSession\|RemoteMediaCommandPolicy" TextMouth --include='*.swift'`.

## Mac test areas to request from the train

`audio`, `playback-end` (classes to name: `ls TextMouthTests TextMouthProductionTests | grep -i "NowPlaying\|RemoteMedia\|AudioRoute\|Bluetooth"`).

## Watch for

The Mac's AirPods and Bluetooth route logic (pause on disconnect, the suppress window) must not change by one line. The Now Playing tests inject `audioDeviceIDsProvider`; keep that parameter's Mac type exactly.

## The census's errors for your files (76; census of 72d9f5cd)

```
TextMouth/Services/NowPlayingService.swift:36:26: error: cannot find 'kAudioDeviceTransportTypeBluetooth' in scope
TextMouth/Services/NowPlayingService.swift:37:33: error: cannot find 'kAudioDeviceTransportTypeBluetoothLE' in scope
TextMouth/Services/NowPlayingService.swift:332:53: error: cannot find type 'AudioDeviceID' in scope
TextMouth/Services/NowPlayingService.swift:333:49: error: cannot find type 'AudioDeviceID' in scope
TextMouth/Services/NowPlayingService.swift:334:44: error: cannot find type 'AudioDeviceID' in scope
TextMouth/Services/NowPlayingService.swift:396:44: error: cannot find type 'AudioObjectPropertyListenerBlock' in scope
TextMouth/Services/NowPlayingService.swift:400:42: error: cannot find type 'AudioObjectPropertyListenerBlock' in scope
TextMouth/Services/NowPlayingService.swift:419:40: error: cannot find type 'AudioDeviceID' in scope
TextMouth/Services/NowPlayingService.swift:428:37: error: cannot find type 'AudioDeviceID' in scope
TextMouth/Services/NowPlayingService.swift:429:33: error: cannot find type 'AudioDeviceID' in scope
TextMouth/Services/NowPlayingService.swift:430:30: error: cannot find type 'AudioDeviceID' in scope
TextMouth/Services/NowPlayingService.swift:1341:36: error: cannot find 'AudioObjectPropertyAddress' in scope
TextMouth/Services/NowPlayingService.swift:1342:24: error: cannot find 'kAudioHardwarePropertyDefaultOutputDevice' in scope
TextMouth/Services/NowPlayingService.swift:1343:21: error: cannot find 'kAudioObjectPropertyScopeGlobal' in scope
TextMouth/Services/NowPlayingService.swift:1344:23: error: cannot find 'kAudioObjectPropertyElementMain' in scope
TextMouth/Services/NowPlayingService.swift:1347:33: error: cannot find type 'AudioObjectPropertyListenerBlock' in scope
TextMouth/Services/NowPlayingService.swift:1351:30: error: cannot find 'AudioObjectPropertyAddress' in scope
TextMouth/Services/NowPlayingService.swift:1352:24: error: cannot find 'kAudioHardwarePropertyDevices' in scope
TextMouth/Services/NowPlayingService.swift:1353:21: error: cannot find 'kAudioObjectPropertyScopeGlobal' in scope
TextMouth/Services/NowPlayingService.swift:1354:23: error: cannot find 'kAudioObjectPropertyElementMain' in scope
TextMouth/Services/NowPlayingService.swift:1357:27: error: cannot find type 'AudioObjectPropertyListenerBlock' in scope
TextMouth/Services/NowPlayingService.swift:1368:29: error: cannot find 'AudioObjectAddPropertyListenerBlock' in scope
TextMouth/Services/NowPlayingService.swift:1369:13: error: cannot find 'AudioObjectID' in scope
TextMouth/Services/NowPlayingService.swift:1369:27: error: cannot find 'kAudioObjectSystemObject' in scope
TextMouth/Services/NowPlayingService.swift:1374:29: error: cannot find 'AudioObjectAddPropertyListenerBlock' in scope
TextMouth/Services/NowPlayingService.swift:1375:13: error: cannot find 'AudioObjectID' in scope
TextMouth/Services/NowPlayingService.swift:1375:27: error: cannot find 'kAudioObjectSystemObject' in scope
TextMouth/Services/NowPlayingService.swift:1562:52: error: cannot find type 'AudioDeviceID' in scope
TextMouth/Services/NowPlayingService.swift:1566:24: error: cannot find 'AudioDeviceID' in scope
TextMouth/Services/NowPlayingService.swift:1567:40: error: cannot find type 'AudioDeviceID' in scope
TextMouth/Services/NowPlayingService.swift:1568:23: error: cannot find 'AudioObjectPropertyAddress' in scope
TextMouth/Services/NowPlayingService.swift:1569:24: error: cannot find 'kAudioHardwarePropertyDefaultOutputDevice' in scope
TextMouth/Services/NowPlayingService.swift:1570:21: error: cannot find 'kAudioObjectPropertyScopeGlobal' in scope
TextMouth/Services/NowPlayingService.swift:1571:23: error: cannot find 'kAudioObjectPropertyElementMain' in scope
TextMouth/Services/NowPlayingService.swift:1573:22: error: cannot find 'AudioObjectGetPropertyData' in scope
TextMouth/Services/NowPlayingService.swift:1574:13: error: cannot find 'AudioObjectID' in scope
TextMouth/Services/NowPlayingService.swift:1574:27: error: cannot find 'kAudioObjectSystemObject' in scope
TextMouth/Services/NowPlayingService.swift:1577:13: error: 'nil' requires a contextual type
TextMouth/Services/NowPlayingService.swift:1589:48: error: cannot find type 'AudioDeviceID' in scope
TextMouth/Services/NowPlayingService.swift:1595:23: error: cannot find 'AudioObjectPropertyAddress' in scope
TextMouth/Services/NowPlayingService.swift:1596:24: error: cannot find 'kAudioDevicePropertyTransportType' in scope
TextMouth/Services/NowPlayingService.swift:1597:21: error: cannot find 'kAudioObjectPropertyScopeGlobal' in scope
TextMouth/Services/NowPlayingService.swift:1598:23: error: cannot find 'kAudioObjectPropertyElementMain' in scope
TextMouth/Services/NowPlayingService.swift:1600:22: error: cannot find 'AudioObjectGetPropertyData' in scope
TextMouth/Services/NowPlayingService.swift:1604:13: error: 'nil' requires a contextual type
TextMouth/Services/NowPlayingService.swift:1662:42: error: cannot find type 'AudioDeviceID' in scope
TextMouth/Services/NowPlayingService.swift:1666:23: error: cannot find 'AudioObjectPropertyAddress' in scope
TextMouth/Services/NowPlayingService.swift:1667:24: error: cannot find 'kAudioHardwarePropertyDevices' in scope
TextMouth/Services/NowPlayingService.swift:1668:21: error: cannot find 'kAudioObjectPropertyScopeGlobal' in scope
TextMouth/Services/NowPlayingService.swift:1669:23: error: cannot find 'kAudioObjectPropertyElementMain' in scope
TextMouth/Services/NowPlayingService.swift:1672:26: error: cannot find 'AudioObjectGetPropertyDataSize' in scope
TextMouth/Services/NowPlayingService.swift:1673:13: error: cannot find 'AudioObjectID' in scope
TextMouth/Services/NowPlayingService.swift:1673:27: error: cannot find 'kAudioObjectSystemObject' in scope
TextMouth/Services/NowPlayingService.swift:1676:13: error: 'nil' requires a contextual type
TextMouth/Services/NowPlayingService.swift:1686:55: error: cannot find type 'AudioDeviceID' in scope
TextMouth/Services/NowPlayingService.swift:1687:25: error: cannot call value of non-function type '[Any]'
TextMouth/Services/NowPlayingService.swift:1687:26: error: cannot find 'AudioDeviceID' in scope
TextMouth/Services/NowPlayingService.swift:1688:22: error: cannot find 'AudioObjectGetPropertyData' in scope
TextMouth/Services/NowPlayingService.swift:1689:13: error: cannot find 'AudioObjectID' in scope
TextMouth/Services/NowPlayingService.swift:1689:27: error: cannot find 'kAudioObjectSystemObject' in scope
TextMouth/Services/NowPlayingService.swift:1692:13: error: 'nil' requires a contextual type
TextMouth/Services/NowPlayingService.swift:1698:52: error: cannot find type 'AudioDeviceID' in scope
TextMouth/Services/NowPlayingService.swift:1711:40: error: cannot find 'AudioObjectPropertyAddress' in scope
TextMouth/Services/NowPlayingService.swift:1712:28: error: cannot find 'kAudioHardwarePropertyDefaultOutputDevice' in scope
TextMouth/Services/NowPlayingService.swift:1713:25: error: cannot find 'kAudioObjectPropertyScopeGlobal' in scope
TextMouth/Services/NowPlayingService.swift:1714:27: error: cannot find 'kAudioObjectPropertyElementMain' in scope
TextMouth/Services/NowPlayingService.swift:1716:13: error: cannot find 'AudioObjectRemovePropertyListenerBlock' in scope
TextMouth/Services/NowPlayingService.swift:1717:17: error: cannot find 'AudioObjectID' in scope
TextMouth/Services/NowPlayingService.swift:1717:31: error: cannot find 'kAudioObjectSystemObject' in scope
TextMouth/Services/NowPlayingService.swift:1726:34: error: cannot find 'AudioObjectPropertyAddress' in scope
TextMouth/Services/NowPlayingService.swift:1727:28: error: cannot find 'kAudioHardwarePropertyDevices' in scope
TextMouth/Services/NowPlayingService.swift:1728:25: error: cannot find 'kAudioObjectPropertyScopeGlobal' in scope
TextMouth/Services/NowPlayingService.swift:1729:27: error: cannot find 'kAudioObjectPropertyElementMain' in scope
TextMouth/Services/NowPlayingService.swift:1731:13: error: cannot find 'AudioObjectRemovePropertyListenerBlock' in scope
TextMouth/Services/NowPlayingService.swift:1732:17: error: cannot find 'AudioObjectID' in scope
TextMouth/Services/NowPlayingService.swift:1732:31: error: cannot find 'kAudioObjectSystemObject' in scope
```
