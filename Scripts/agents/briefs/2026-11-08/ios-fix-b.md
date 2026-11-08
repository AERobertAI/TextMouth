# Task `iosfixb`: the review's fixes in VoiceOver's words and the reader's screen (November 8, 2026)

Slug `iosfixb`, branch `ios/fix-b-1108` from `ios/lead-1108`. Read `Scripts/agents/briefs/2026-11-08/ios-workers.md` first; its rules hold.

An outside Opus review read the iPhone branch against the spec and Apple's documentation. Its report is `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/iosui/review-code-1108.md`: read each finding below there in full, with its evidence and the fix it proposes, then check it against the code yourself before you change anything. If a finding turns out wrong, say why in your report and leave it.

## Your findings

One commit for each, with its tests, in this order:

1. **Finding 3 (major): the announcement priorities.** Apple's header (`UIAccessibilityConstants.h`, iOS 26 SDK, lines 261-266) says `.default` interrupts what VoiceOver is saying and `.low` is queued until it has finished. The code assumed the reverse. Words that should follow VoiceOver's own speech (a sheet's farewell, a folder's arrival, an import's result) go at `.low`; a run of words posted together becomes one announcement, so none is cut off by the next; the comments say what the header says. The mapping is in the `#if os(iOS)` branch of the shared `VoiceOverAnnouncer.swift` and in `PhoneAnnouncer`; the loops that post several words are at `PhoneReaderSheetContent.swift:112-113`, `PhoneReaderModel.swift:499-500`, `PhoneHeadingsSheet.swift:226`, and `PhoneVoiceSheet.swift:336`. Keep the Mac's mapping as it is.
2. **Finding 5 (major): one keeper of the screen's sleep,** counting who holds it, used by the import copier and Book content, so neither switches the other off.
3. **From the first run in the simulator: Book content is blank when the place is in a chapter with no text.** A Project Gutenberg EPUB starts with a "Cover" chapter holding only an image, so a new book opens on an empty Book content, and VoiceOver reads "Book content" with nothing after it. Show the passage from the next sentence after the place, which is in the next chapter with text, as Play would read it. The decision belongs in the plain type (`PhonePassagePolicy`), with tests on the Mac, and `PhoneBookTextView.show(passageOf:chapter:at:)` uses it. Say what the Mac's reader shows in the same case.
4. **Finding 9 (minor):** a move while the book plays doesn't replace Book content under a reader who has focus on it.
5. **Findings 6, 12, and 13 (minor):** a jump from the Headings, Bookmarks, or Go To sheet counts the book as opened; the title isn't said twice when a launch reopens the reader; and "Loading…" isn't said as the listener leaves.
6. **The review's small duplicates in your files:** `PhoneFocusRegistry.kind(of:)`, which nothing calls while the arrival repeats its lookup; and `PhoneReaderView.sheetView`, which works out the units again instead of calling `model.offeredUnits(of:)`. (The Follow in Braille key, kept twice, was folded by `iosdry` and is on `ios/lead-1108` now.)

7. **From Apple's accessibility audit in the simulator** (`TextMouthiOSUITests`, `LibraryUITests`): the Library's own drawing.
   - A book row's second line ("Lewis Carroll, 0%") fails contrast. The row is a button, so its secondary text takes the tint and comes out light blue.
   - Contrast "nearly passed" for the row's title, "Library view", the section heading "Books (1)", the summary, and the empty Library's note.
   - Dynamic Type is "partially unsupported" for the summary ("1 book. 2 hours, 27 minutes, 50 seconds total remaining at current speed").

   Make the rows' text the system's primary and secondary label colors, not the tint, and check each of the others in `PhoneLibraryView` and `PhoneLibraryRowViews`. These are for a sighted helper and for low vision: no word changes. The audit's findings on parts iOS draws (the search field, the bar's buttons, the navigation title) are accepted in the tests with their reasons, so leave those.

## Your files

`TextMouth/Phone/PhoneAnnouncer.swift`, `TextMouth/Phone/PhonePassagePolicy.swift`, `TextMouth/Phone/PhoneReaderSheet*.swift`, `TextMouth/Phone/PhoneFocus*.swift`, `TextMouth/Phone/PhoneReaderModel.swift` (only what findings 3 and 9 need), the `#if os(iOS)` branch of `VoiceOverAnnouncer.swift`, `TextMouth/Platform/iOS/Views/**`, a new keeper of the screen's sleep in `TextMouth/Platform/iOS/Services/`, `PhoneImportCopier.swift` (only its use of the screen's sleep), and their tests. Another worker, `iosfixa`, has the session, audio, the background work, and the app delegate at the same time: leave those to them, and if you must touch one of their files, tell the lead first.

## What the lead checks in the simulator

Say in your report which of your changes the simulator can show (a launch, the Library, the reader, Book content's text and value, without pressing Play) and which only a phone with VoiceOver can.
