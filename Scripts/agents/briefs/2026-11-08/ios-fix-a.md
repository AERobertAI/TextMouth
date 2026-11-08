# Task `iosfixa`: the review's fixes in the session, audio, and the background (November 8, 2026)

Slug `iosfixa`, branch `ios/fix-a-1108` from `ios/lead-1108`. Read `Scripts/agents/briefs/2026-11-08/ios-workers.md` first; its rules hold.

An outside Opus review read the iPhone branch against the spec and Apple's documentation. Its report is `/Users/roberteggleston/programming/ai/claude/swift/TextMouth/build/orchestrator/iosui/review-code-1108.md`: read each finding below there in full, with its evidence and the fix it proposes, then check it against the code yourself before you change anything. If a finding turns out wrong, say why in your report and leave it.

## Your findings

One commit for each, with its tests, in this order:

1. **Finding 1 (major): the lock screen's skip interval follows the phone's unit in force.** Give `ReaderPhoneHooks` a way to ask the unit in force (filled by `PhoneReaderModel.fillHooks`), build `PhoneRemoteCommandPolicy` from it on iOS, and apply the commands again whenever Settings changes a kind's unit. The change in `ReaderViewModel+Playback.swift` is a shared file's, so it stays inside its `#if os(iOS)` branch.
2. **Finding 2 (major): the next book that starts behind the screen gets the life cycle's hooks.** The review's better fix is the one to make, if it's small: `PhoneSession` publishes each reader once as it makes it, and `PhoneAudioSession` and `PhoneBackgroundWork` both attach there. This also folds the duplicate it names: two ways of joining the session's readers.
3. **Finding 4 (major): a lock-screen Play that wakes a killed app holds the app until its book has loaded,** through `endHoldOnLoad` as `goOn` does, and the crash guard is read and cleared before any reader exists.
4. **Findings 7, 10, and 11 (minor):** a Play pressed while loading survives Back; one rule for which book a remote Play reaches (the review suggests `NowPlayingSession.focus()` in `PhoneSession.setCurrent`); and one "a book plays, or waits to" check in `PhoneAudioSession`.
5. **Finding 8 (minor):** the import's checks of whether a book plays read both readers' snapshots.
6. **From the first run in the simulator:** config.json's braille table is "repaired" at every launch (`STORED_VALUE_REPAIRED config.json brailleTable: replaced unsupported value "en-ueb-g2.ctb" with ""` at launches 2 and 3 in a row), so the repair isn't kept, or the iPhone's default is the Mac's. Find out which, and make the iPhone write a value it accepts, once.
7. **The review's duplicates in `PhoneSession`:** the loop in `rememberForReopening()` that is `forgetReopening()`, and the lines `close(_:)` and `loadEnded(_:)` share.

## Your files

`TextMouth/Phone/PhoneSession.swift`, `TextMouth/Phone/PhoneReaderModel.swift` (only `fillHooks` and what finding 1 needs), `TextMouth/Phone/ReaderPhoneHooks.swift`, `TextMouth/Phone/PhoneRemoteCommandPolicy.swift`, `TextMouth/Phone/PhoneLifeCycle*.swift`, `TextMouth/Platform/iOS/Services/PhoneAudioSession.swift`, `TextMouth/Platform/iOS/Services/PhoneBackgroundWork.swift`, `TextMouth/Platform/iOS/Services/PhoneImportCopier.swift` (finding 8 only), `TextMouth/Platform/iOS/App/`, the `#if os(iOS)` branches of `ReaderViewModel+Playback.swift` and `NowPlayingService.swift`, the settings or config code finding 6 needs, and their tests. Another worker, `iosfixb`, has the announcements, the idle timer, the sheets, and Book content at the same time: leave those to them, and if you must touch one of their files, tell the lead first.

## What the lead checks in the simulator

Say in your report which of your changes the simulator can show (a launch, the Library, the reader, without pressing Play) and which only a phone can.
