# Team a11y: VoiceOver focus and announcements, text areas, sheets, and control styles

Read `ios0-common.md` beside this file first: it is the pattern, and its rules override this charter. Your team is `a11y`, your lead `a11y-lead`, and your branch `team/a11y`. Your files are listed in `files-a11y.md` beside this file. They are what a VoiceOver user meets most: the focus placement and announcements, the read-only and editable text areas, and the sheets and presentations, many of which also use the Mac's checkbox and radio styles.

## Decisions already made

- **VoiceOver focus (Views/VoiceOverFocus.swift)** places VoiceOver's focus in new windows and sheets through AppKit's accessibility API.
  - Move it unchanged to `TextMouth/Platform/macOS/Views/`.
  - Give iOS, in `TextMouth/Platform/iOS/Views/VoiceOverFocus+iOS.swift`, every name the shared views use: the view modifiers, `StandardVoiceOverFocus`, `InitialVoiceOverFocusModifier`, and `voiceOverFocusID`, whatever the census and grep show. Keep the same signatures.
  - Each iOS version does the least that is safe: it returns the view unchanged, or marks the element with SwiftUI's own `accessibilityAddTraits` or `AccessibilityFocusState` where that is one line. Comment each as a phase 0 stand-in.
  - Phase 1 does real iPhone focus. Do not build it now.
- **Announcements (Services/VoiceOverAnnouncer.swift)** stay shared. The Mac branch stays as it is. The iOS branch posts the same text with SwiftUI's `AccessibilityNotification.Announcement`, which exists on both platforms (iOS 17 and later), or `UIAccessibility.post(notification: .announcement, argument:)`. Keep the Mac's priority levels on the Mac, and map them on iOS with a comment.
- **The text areas (Views/ReadOnlyTextArea.swift, Views/Library/TextInputView.swift)** wrap NSTextView.
  - Move each Mac version unchanged.
  - Give iOS a version with the same name and initializer: a `UIViewRepresentable` around `UITextView`, read-only or editable as the Mac's is, whose text VoiceOver reads.
  - These two are the only real iOS views tonight. Keep them small, and label them as the Mac's are.
- **The sheets and presentations** stay shared. Wrap their AppKit parts in place:
  - `NSWindow` becomes `PlatformWindow`;
  - NSAlert and NSOpenPanel or NSSavePanel go behind `#if os(macOS)`, with an iOS branch that does nothing, or reports through the sheet's own error state;
  - `.toggleStyle(.checkbox)` becomes `.checkboxToggleStyle()`, and `.pickerStyle(.radioGroup)` becomes `.radioGroupPickerStyle()`;
  - `onExitCommand` takes the postfix `#if os(macOS)` form.

  Every label, hint, and announcement stays word for word on the Mac.

## Tasks

About four tasks. For example:
1. VoiceOver focus and its iOS twin;
2. the announcer and the two text areas;
3. the sheets of Export, Transcription, and Reader;
4. the Library, Settings, and Feeds sheets with the control styles.

Do the first two first: other teams' views use their names.

## Tests to request from the train

The areas `accessibility`, `sheets`, `export`, `transcripts`, and `settings`. Add `library` and `feeds` for their sheets.

## Watch for

- The accessibility tests check wording and focus. If one fails, stop and ask: a change of wording is exactly what the user forbade.
- `make lint-a11y` checks the SwiftUI lines a branch adds. Run it (`LINT_BASE=team/a11y`) on each worker's diff before you take it.
