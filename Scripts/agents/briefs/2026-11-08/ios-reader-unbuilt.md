# Task `iosunbuilt`: the reader's pieces the spec asks for and nobody built (November 8, 2026)

Slug `iosunbuilt`, branch `ios/unbuilt-1108` from `ios/lead-1108`. Read `Scripts/agents/briefs/2026-11-08/ios-workers.md` first; its rules hold.

The outside review (`/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/iosui/review-code-1108.md`, its last section) lists what the spec asks for that isn't built. These four are yours, one commit each with its tests. The words are the Mac's, or the spec's where it gives them; read the spec's lines named below.

1. **The error alert while the book plays** (spec, "While the book is loading, or can't load", line 479). `PhoneReaderSnapshot.errorAlert` carries the Mac's `ReaderViewModel.ErrorAlert`, and nothing shows it. Present it over the reader with the Mac's buttons: "Retry" or "Try Again" where `offersRetry` (doing what the Mac's alert does: find it in `TextMouth/Views/Reader/ReaderView.swift`, `ReaderErrorAlert`), and "Cancel" and "OK" as the Mac has them. Closing it clears the reader's error, as the Mac's does. Focus goes to the alert, and when it closes, back to Play (`PhoneFocusRegistry`, kind `.play`). The decisions (which buttons, what each does) belong in a plain type in `TextMouth/Phone/`, tested on the Mac.
2. **Book Info from the reader.** `PhoneReaderSheetContent` shows `PhoneUnbuiltSheet(title: "Book Information")`, while `PhoneBookInfoSheet` (`TextMouth/Platform/iOS/Views/Library/PhoneBookInfoSheet.swift`) is built for the Library's rows. Show it, for the reader's book, with focus landing where the spec's Book Info sheet says (line 566).
3. **The Speech Stopped sheet** (spec line 480, and lines 846-847 for its words made the iPhone's). Only its announcement is said today. Present the sheet, rebuilt for the phone like the others, with its Details text, Copy Details, and Close, and no Show Logs in Finder.
4. **Preview Voice pauses a playing book and plays it on after** (spec lines 556 and 743), in Settings and in the Voice sheet. `PhoneSettingsVoicePreview` already takes a `pauseBook` closure: give it one from the session, which pauses the book that plays (either reader) and returns what resumes it, and make the Voice sheet's preview do the same. Before it speaks, ask `audioMayStart` as the reader's Play does, since Apple's audio session must be active. The review found the preview speaks over the book and never asks.

**Not yours:** the session's and audio's code beyond the pause closure, Book content, and the announcement mapping. Slice 8 (`iosslice8`) has Read All and the escape gesture at the same time.

## Your files

`TextMouth/Phone/` (new plain types, and `PhoneSettingsVoicePreview`), `TextMouth/Platform/iOS/Views/Reader/PhoneReaderView.swift`, `PhoneReaderSheetContent.swift`, `PhoneVoiceSheet.swift`, a new sheet file for Speech Stopped, `TextMouth/Platform/iOS/Views/Settings/PhoneSettingsView.swift`, and their tests.

## What the lead checks in the simulator

The Book Info sheet from the reader can be opened and read in the simulator. The error alert, Speech Stopped, and Preview Voice need sound or a failing engine, so say how you tested them on the Mac, and what a phone must show.
