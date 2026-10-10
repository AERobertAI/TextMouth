# Task brief: refusalalert — B05, an alert with the details when the speech engine refuses a passage

Slug `refusalalert`; branch `feature/speech-refusal-alert`. Read `common.md` beside this file first.

## What the user asked for
B05 in TODO-2026-09-04.md. On October 7 the user declined an automatic skip past a passage the speech engine refuses: "I feel like VoiceOver should just say like "speech interopted for unknown reason" or something or even better popup a dialog with the error and any log to help find it, the skip passage thing is a bug group, it shouldn't be worked around."

So: when speech stops because macOS's speech engine refused a passage on a fresh synthesizer too, an accessible alert in the book's window names what happened and where, gives the details that help find the cause, and offers a way to copy them, so each refusal can be fixed rather than skipped. Nothing skips the passage; Play still speaks on from the cursor, as today.

## Background
- B01 (merged aec5c91b) and the speech-refusal follow-ups (6b78bd4c): macOS 26's speech engine parses a plain `AVSpeechUtterance` holding tag-shaped text as SSML and refuses some chunks (`SSMLParserError` in the unified log), and a refusing synthesizer can stop speaking at all. A same-length guard turns the brackets of tag-shaped runs into U+2039 and U+203A before any utterance; a refused live utterance replaces the synthesizer and retries once, strictly guarded; a second refusal ends speech there. Read the "From the speechguard agent" and "From the speechfix agent" sections of `AGENT-NOTES-2026-10-04.md`, and REV07's speech findings in the TODO.
- Today that second refusal runs `SpeechService.endDirectSpeechRefused(at:)` (TextMouth/Services/SpeechService.swift): it logs `DIRECT_RETRY_FAILED` with the offset and the chunk's range, keeps the cursor at the offset, announces `SpeechService.engineRefusedAnnouncement`, and calls `onSpeechRefused`, which the reader wires (ReaderViewModel.swift, about line 669) to `ReaderViewModel.showPlaybackStoppedAfterRefusal()` (ReaderViewModel+Playback.swift): the reader shows itself paused, ends the listening session, holds the sleep timer, records the stop, and saves the position.
- The log files' rule (the log policy, `DiagnosticLog`): offsets and lengths only, never a book's words. The alert may show the book's words on screen and put them on the pasteboard when the user asks; the log files never get them.

## Required behavior
1. **What the alert says.** A sheet on the reader window, not a bare `.alert`, so a long report stays readable line by line with VoiceOver and a braille display. A heading such as "Speech stopped", one plain sentence of what happened ("The Mac's speech engine refused to speak the text here, twice, so speech stopped. Play tries again from the same place."), where it happened (the chapter's title and number, the position as the reader says it elsewhere, and the character offset), and the details:
   - the passage around the offset as the book has it, and the text exactly as it was handed to the speech engine (after substitution rules and the markup guard), each a few hundred characters at most, with the refused chunk's start and end marked in words;
   - the voice (name, identifier, language, quality), the rate, macOS's version, and TextMouth's build (the Info.plist's `TextMouthGitCommit` and `TextMouthBuildDate` where present);
   - the speech service's recent transition lines for this speech (they hold offsets only), such as the last 40, ending with `DIRECT_RETRY_FAILED`; prefer a small in-memory record the service keeps as it logs over reading log files on the main thread;
   - the time, and how many times this place has been refused while the window has been open.
   Build the report's text in a pure function (a value type with the facts, and its words), so every line is pinned by a test without a window.
2. **What the alert does.** "Copy Details" puts the whole report on the pasteboard as plain text and announces "Details copied" through `VoiceOverAnnouncer`; "Close" is the default button, closing with Return or Escape. The details are in a read-only, selectable text area VoiceOver can read and a braille display can pan. Optional, if it stays small: "Show Logs in Finder", revealing the Logs folder of the data directory (`<data directory>/Logs`), as the user wants logs findable there.
3. **What VoiceOver hears at the stop.** One clear message, not two that talk over each other: keep a spoken announcement for a listener whose window is not in front, worded in the user's direction (for example "Speech stopped: the speech engine refused this passage. Details are in the book's window."), and let the sheet speak for itself when it appears. Pin the words with a constant.
4. **Only one at a time.** A second refusal while the sheet is open updates it (its count and details) instead of stacking another; a refusal in a reader that has closed shows nothing; a refusal never steals focus from another app (a sheet waits on its window).
5. **The log line.** Showing the sheet logs one line with the chapter, the offset, and the chunk's range, as the other speech lines do, and no words of the book.

## Files you own
TextMouth/Services/SpeechService.swift (only `endDirectSpeechRefused(at:)`, what it hands the reader, `engineRefusedAnnouncement`, and the recent-lines record if you add one there), TextMouth/ViewModels/ReaderViewModel.swift (only the `onSpeechRefused` hookup), TextMouth/ViewModels/ReaderViewModel+Playback.swift (only `showPlaybackStoppedAfterRefusal()` and the report state it sets), a new report model and a new sheet view (for example TextMouth/Models/SpeechRefusalReport.swift and TextMouth/Views/Reader/SpeechRefusalReportSheet.swift), the line of the reader's window or view that attaches the sheet, and their tests. No other agent edits these files now. Leave `ReaderViewModel+WhereAmI.swift` and the keyboard files alone (FR12's branches change them).

## Tests
- The report's words, line by line, for a text book and an audiobook's transcript if refusals can happen there, with a passage at a chapter's start and at its end (no out-of-range slice: clamp every window, never trap).
- `onSpeechRefused` sets the report on the reader; a second refusal updates it; a closed reader sets nothing; Play after the stop still speaks on from the cursor (the existing refusal tests stay green; extend them, don't replace them).
- Copy Details writes to a pasteboard passed in (a named one in tests, never the general pasteboard) and announces.
- The recent-lines record keeps only the newest lines and holds no book text.
- No test speaks aloud: use the fake synthesizers the existing refusal tests use.

## Verify or report as unverified
- A real refusal on this Mac cannot be made on purpose without a tag shape the guard misses; say whether you found one in an offline probe (`write(toBufferCallback:)` plays nothing) or report it unverified. Never play sound.
- Live VoiceOver and braille on the sheet are unverified; say so.
- Report the README and ARCHITECTURE wording for what a listener sees when speech is refused.
