# Team media: the Record window and the audio editor

Read `ios0-common.md` beside this file first: it is the pattern, and its rules override this charter. Your team is `media`, your lead `media-lead`, and your branch `team/media`. Your files are listed in `files-media.md` beside this file. They are the two features with windows of their own, the Record window (New Recording) and the audio editor, and their AppKit, AVCapture, and ffmpeg parts.

## Decisions already made

- **Neither feature comes to iOS in phase 0.** Their window controllers and launchers are AppKit through and through. Move them unchanged to `TextMouth/Platform/macOS/Views/…`:
  - Views/Recording/RecordingWindowController.swift;
  - Views/AudioEditor/AudioEditorWindowController.swift;
  - Views/AudioEditor/AudioEditorLauncher.swift;
  - Views/AudioEditor/AudioEditorEditMenu.swift.

  Grep each name they declare. Shared code that still uses one (the library's context menu, the delegate's quit hold, the router) gets an iOS stand-in with exactly those members, each doing nothing, and an `open…` throwing `IOSUnavailable.feature("Recording")` or `.feature("Editing audio")`.
- **The capture backend (Services/RecordingCaptureBackend.swift)** uses `AVCaptureAudioFileOutput`, which is Mac-only. Wrap that backend in `#if os(macOS)`. Give iOS a backend of the same protocol whose start throws `IOSUnavailable.feature("Recording")`.
  - **Services/RecordingInputDevices.swift**: its `transportType` reading goes behind `#if os(macOS)`. On iOS, every device's transport is unknown.
- **ffmpeg (Services/AudioEditing/FFmpeg.swift)** runs an installed ffmpeg as a child process. Move it unchanged. The iOS stand-in finds no ffmpeg, so every caller takes its "no ffmpeg" path, which exists already.
- **The two models (ViewModels/AudioEditorModel.swift, AudioEditorModel+PunchIn.swift, ViewModels/RecordingWindowModel.swift)** stay shared, with their AppKit bits wrapped: NSSound and the Tink sound in `/System/Library/Sounds`, NSWindow, NSApp. Their audio engines are AVFoundation, which iOS has.
- **The editor's other views (AudioEditorFileSheets.swift, AudioEditorFilterSheet.swift)** stay shared, wrapped in place; `.pickerStyle(.radioGroup)` becomes `.radioGroupPickerStyle()`.

## Tasks

About three tasks. For example:
1. recording: the controller, backend, input devices, and model;
2. the audio editor's window, launcher, and menu;
3. ffmpeg, the editor's models, and its sheets.

## Tests to request from the train

The areas `recording`, `editor`, and `audio`, and `windows` for the two controllers.

## Watch for

- No test may record from a real microphone or play sound aloud. The recording tests use their fakes; keep them working unchanged.
- The Record window and each editor window ask before closing, and so does the quit that AppDelegate holds (team shell owns it). Keep `RecordingWindowController.holdQuit` and `AudioEditorWindowController.holdQuit` exactly as they are on the Mac.
