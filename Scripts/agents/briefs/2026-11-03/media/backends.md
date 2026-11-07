# Task media/backends: the capture backend, input devices, ffmpeg, the two models, and two sheets

Worker slug `media-backends`. Branch `media/backends`, from `team/media`. Lead: `media-lead`. Read `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/.claude/worktrees/ios0/Scripts/agents/briefs/2026-11-03/ios0-common.md` (the pattern and "The worker's part") first; its rules override this brief. Another worker (`media-windows`) moves the four window-controller files at the same time: do not touch those, `PlatformTypes.swift`, or `project.pbxproj`. Do not run xcodegen.

Your 8 files and their census errors:

- `TextMouth/Services/RecordingCaptureBackend.swift`: 120:25 and 149:22, `AVCaptureAudioFileOutput` is unavailable in iOS
- `TextMouth/Services/RecordingInputDevices.swift`: 125:77 `transportType` unavailable; 142-144 `kAudioDeviceTransportType{Virtual,Aggregate,AutoAggregate}` not found
- `TextMouth/Services/AudioEditing/FFmpeg.swift`: 175:35 `Process`
- `TextMouth/ViewModels/AudioEditorModel+PunchIn.swift`: 49:9 `NSSound`
- `TextMouth/ViewModels/AudioEditorModel.swift`: 43, 208, 315 `NSWindow`; 317 `NSApp`, `keyWindow`, and the overload mismatch that follows from them
- `TextMouth/ViewModels/RecordingWindowModel.swift`: 355:9 `NSWorkspace`
- `TextMouth/Views/AudioEditor/AudioEditorFileSheets.swift`: 89:21 `NSSavePanel`
- `TextMouth/Views/AudioEditor/AudioEditorFilterSheet.swift`: 74:31 `.pickerStyle(.radioGroup)`

## Mechanisms (decided; follow them, one commit each, in this order)

1. **ffmpeg (`FFmpeg.swift`)**: wrap in place (rule 2), not a move. This changes the charter's plan, because the file also holds `AudioFilterEngine`, which shared code uses, so a move would need stand-ins for both types. Wrap the body of `func run(_ arguments: [String]) async throws` in `#if os(macOS)` ... `#else` ... `#endif`, keeping the Mac text character for character. The `#else` branch is `throw AudioFilterError.ffmpegMissing`, with a comment that iOS cannot start a child process and `FFmpeg.locate` finds no executable there anyway, so callers already take their "no ffmpeg" path. Change nothing else.
2. **Capture backend (`RecordingCaptureBackend.swift`)**: read the whole file by line range first. Keep the protocol and value types (`RecordingCaptureEvent`, `RecordingLevels`, `RecordingCaptureSnapshot`, `RecordingCaptureError`, `RecordingCaptureBackend`) shared. Wrap in `#if os(macOS)` the Mac backend, `actor CaptureSessionRecordingBackend`, and `final class FileRecordingDelegate` (which conforms to `AVCaptureFileOutputRecordingDelegate`), plus any helper only they use. In the `#else` branch add `actor CaptureSessionRecordingBackend: RecordingCaptureBackend`, the same name so shared code that constructs it compiles (grep `CaptureSessionRecordingBackend` to see how it is used). Its `start` throws: if the protocol's `start` must throw a `RecordingCaptureError`, throw `.setupFailed("Recording is not available on iPhone yet.")`, otherwise throw `IOSUnavailable.feature("Recording")`; say in your report which you chose. Its other protocol members return empty or idle values. Begin the `#else` code with the comment `// Phase 0 stand-in: ...`. A stand-in actor needs no `unownedExecutor`. No traps.
3. **Input devices (`RecordingInputDevices.swift`)**: `import CoreAudio` stays unless the census says otherwise. Wrap in `#if os(macOS)` the Mac-only reading: the `.filter { ... Self.isMicrophone(transportType: ...) }` in `devices()`, and `isMicrophone(transportType:)` with its `kAudioDeviceTransportType*` constants. In `#else`, `devices()` keeps every connected device (every device's transport is unknown, so none is dropped as virtual): `.filter { $0.isConnected }`. If the census also flags `.external` in `DiscoverySession(deviceTypes:)`, wrap that array too. Tests' use of `isMicrophone(transportType:)` must keep working on the Mac.
4. **`AudioEditorModel.swift`, `AudioEditorModel+PunchIn.swift`, `RecordingWindowModel.swift`**:
   - `import AppKit` becomes the `#if os(macOS) import AppKit #else import UIKit #endif` form (rule 2) in each file that imports it.
   - `NSWindow` becomes `PlatformWindow` (rule 3) at lines 43, 208, 315 and any other mention in the file.
   - `NSApp.keyWindow` at line 317: wrap the `guard ... WindowCommandRouting.shouldAccept(...)` in `#if os(macOS)` ... `#else`. The iOS branch is `guard let action else { return }` followed by the same `perform(action)`, with a comment that iOS has no second window to route between. Do not touch `WindowCommandRouting` (team shell owns `LibraryView.swift`); if its overload still fails on iOS only inside the Mac branch, fine.
   - `NSSound` in `beep()`: wrap the `NSSound(...)?.play()` line in `#if os(macOS)` and leave the sleep for both.
   - `NSWorkspace.shared.open(url)` in `openPrivacySettings()`: wrap the Mac line in `#if os(macOS)`; the `#else` branch does nothing, with a comment that phase 1 opens iOS Settings.
5. **Sheets**: `AudioEditorFilterSheet.swift` line 74, `.pickerStyle(.radioGroup)` becomes `.radioGroupPickerStyle()` (rule 4). `AudioEditorFileSheets.swift`: check whether its `import AppKit` needs the rule-2 form. `chooseDestination()` uses `NSSavePanel`: wrap its whole body in `#if os(macOS)`; the `#else` branch does nothing, with a comment that iOS will use a file exporter in phase 1. The button that calls it stays.

Comment every new branch. The Mac text inside every `#if os(macOS)` is identical to before.

## Checks

1. `make typecheck-ios CENSUS=1`, then `grep -E "RecordingCaptureBackend|RecordingInputDevices|AudioEditing/FFmpeg|AudioEditorModel|RecordingWindowModel|AudioEditorFileSheets|AudioEditorFilterSheet" <errors.txt>`: it must find nothing. A remaining error that comes from another team's file is a finding for me (`--to media-lead`), not yours to fix.
2. `make typecheck-mac`: 0 errors, 0 warnings.
3. `make mac-projection BASE=team/media DIFF=1`: no remaining Mac change except lines you can defend one by one; list any.
4. Train: first name the real test classes: `grep -rlE "class .*Tests" TextMouthProductionTests TextMouthTests | grep -iE "recording|audioeditor|ffmpeg|audiofilter"` and pick the ones about the backend, input devices, the recording and editor models, punch in, and the filter engine. Then `python3 -I Scripts/agents/build-train.py request --agent media-backends --branch media/backends --areas recording,editor,audio --classes <those>`, and wait with `python3 -I Scripts/agents/wait-for-result.py --agent media-backends` in the background.

## Completion

The census lists none of your files; typecheck-mac shows 0 errors and 0 warnings; the projection shows nothing but defended lines; the train is green. Finish as "The worker's part" step 7 says.
