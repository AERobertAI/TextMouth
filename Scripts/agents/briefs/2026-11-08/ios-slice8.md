# Task `iosslice8`: Slice 8, VoiceOver's Read All, the escape gesture, and every screen's order (November 8, 2026)

Slug `iosslice8`, branch `ios/slice8-1108` from `ios/lead-1108`. Read `Scripts/agents/briefs/2026-11-08/ios-workers.md` first; its rules hold.

The spec's Slice 8 (`IOS-INTERFACE-SPEC-2026-11-07.md`, "The implementation slices") is "the rotors, Read All, escape, and a sweep of every screen". The rotors stay off, as the spec's first cut (`playRotorsEnabled`). Yours, one commit each with its tests:

1. **Read All on Book content** (spec, "Book content", the line beginning "**Read All**", line 316). A two-finger swipe down reads on past the passage's end by the same paging, with UIKit's page-turn trait (`.causesPageTurn`) on the text view, so VoiceOver calls `accessibilityScroll(.next)` at the end and reads on. While paused, each turn moves the place, so stopping leaves the place there; while playing, a turn moves only the passage. Read Apple's header (`UIAccessibilityConstants.h`, `UIAccessibilityTraitCausesPageTurn`) and the existing `accessibilityScroll(_:)` in `PhoneBookTextView` first. The decision of what a turn does belongs in `PhonePassagePolicy`, tested on the Mac.
2. **The escape gesture** (a two-finger scrub; spec, "How a person moves around", line 70, and each sheet's section). Check, by reading Apple's documentation on `accessibilityPerformEscape()` and the code, that the scrub goes back from the reader (the system's navigation), closes each sheet that can be closed, and doesn't close the import question, which only an answer settles (spec line 709). Where a view needs `accessibilityPerformEscape()`, give it one, with tests where a test can reach it: an iOS-hosted test in `TextMouthiOSTests` can call it on a view.
3. **A sweep of every screen's order against the spec,** as XCUITests in `TextMouthiOSUITests`, beside the lead's `LibraryUITests` and `ReaderUITests` (use `TextMouthUITestCase`: `launch`, `launchIntoTheReader`, `elementsInOrder`, `assertOrder`, and `audit`). Settings, the Add to Library sheet, and the reader's sheets: Headings, Bookmarks, Go To, Sleep Timer, Voice & Speed, Book Info, and the navigation unit's choice. For each, the order of its elements as the spec's section lists them, and Apple's audit, accepting only findings on parts iOS draws, each with its reason. **Open nothing that makes a sound:** never Play, Preview Voice, or Where Am I?, and never type, since the keyboard's clicks are sounds.

The lead runs the XCUITests in the simulator: you don't. Write them so a mistake fails with the whole order in the message, as `assertOrder` does, and say in your report what each test expects.

**Not yours:** the error alert, Book Info's content, Speech Stopped, and Preview Voice, which `iosunbuilt` has at the same time.

## Your files

`TextMouth/Platform/iOS/Views/Reader/PhoneBookTextView.swift`, `TextMouth/Phone/PhonePassagePolicy.swift`, any view that needs `accessibilityPerformEscape()`, `TextMouthiOSTests/`, `TextMouthiOSUITests/` (new files only, and `TextMouthUITestCase` if a helper is missing), and their Mac tests.
