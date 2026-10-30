# bughunt-quitsaves: a quit keeps the listener's place, and sleep is not listening

Worker slug `bughunt-quitsaves`, branch `bughunt/quitsaves` (from `team/bughunt`). Read `README.md` beside this file first. Two small fixes, one commit each, each with its test.

## 1. Quitting while a book plays loses up to 30 seconds of the place
While a book plays, `ReaderViewModel.publishLivePosition` (`TextMouth/ViewModels/ReaderViewModel.swift`, about line 2069-2100) saves a checkpoint to the book's row and record only every 30 seconds (`PlaybackCheckpointPolicy`, line 127); between checkpoints the place lives only in memory. Command-Q, logging out, or shutting down runs `AppDelegate.applicationShouldTerminate` (`TextMouth/App/AppDelegate.swift:195`), whose flush, `UnsavedChangesTerminationGuard.flushPendingWrites()` (`TextMouth/App/UnsavedChangesTermination.swift:158-162`), writes only what is already queued, and then `applicationWillTerminate` (`:218`). Nothing saves an open reader: its `close()` runs from the window's `.onDisappear` (`TextMouth/Views/Reader/BookReaderWindowView.swift:69`), which SwiftUI does not call at termination. So the next launch opens the book up to about 30 seconds back. The memory guard's own quit already saves every open reader first (`PlaybackMemoryGuard.saveEverythingAndQuit`, `TextMouth/Services/PlaybackMemoryGuard.swift:367-374`).

Fix:
1. `PlaybackMemoryGuard` gains `saveEveryOpenReaderPosition()`: `openReaders(playingOnly: false)` (`:378`), each `savePosition()`. `saveEverythingAndQuit` calls it instead of its own loop (DRY). Readers report to the guard through `reader(_:isPlaying:title:)` (`:340`) whether or not the guard `isEnabled`, so this works in hosted tests too; confirm that by reading.
2. `UnsavedChangesTerminationGuard.flushPendingWrites()` calls `PlaybackMemoryGuard.shared.saveEveryOpenReaderPosition()` **first**, before `LibraryPersistenceService.flushPendingSave()`, so the places it saves are written by that same flush. Update its doc comment (it now writes every open reader's place first). A quit that is then cancelled (Cancel in the unsaved-changes prompt) has only saved a place early, which is harmless.

Tests:
- `PlaybackMemoryGuardTests`: two stand-in readers (the class already has a stand-in `MemoryGuardedReader`; grep it), one playing and one not, and a third that has closed (`hasClosed` true): `saveEveryOpenReaderPosition()` saves the first two only.
- `UnsavedChangesTerminationTests`: with a reader open in an integration world (grep the test target for how other tests open a real `ReaderViewModel` on a sandbox book, such as `ReaderPositionPersistenceTests` or the `IntegrationWorld` helpers), move its `currentCharacterOffset` without a checkpoint, call `UnsavedChangesTerminationGuard.flushPendingWrites()`, and assert the library row (and the book's record, as the existing position tests read it) holds the new offset. It fails without the fix.

## 2. Time the Mac sleeps during playback is credited as listening (TODO-2026-09-04.md, the September 30 follow-up "Mac sleep during a session is still credited as listening")
`ReadingStatsService` (`TextMouth/Services/ReadingStatsService.swift`) credits an open listening session in slices: the 60-second checkpoint timer (`startCheckpointTimer`, `:684`) calls `checkpointActiveSession(at:)` (`:367`), which credits everything since `activeSession.creditedThrough` (`uncreditedSessionTime`, `:384`). Nothing observes the Mac's sleep, so a book left playing when the lid closes for 7 hours is credited 7 hours on wake: Today, This Week, All Time, the streak, and the book's total.

Fix:
1. Two functions, `noteSystemWillSleep(at:)` and `noteSystemDidWake(at:)`: going to sleep checkpoints the open session at that moment (`checkpointActiveSession(at:)`, so everything heard so far is credited and saved); waking moves the open session's `creditedThrough` to the wake time (never backwards: `max` of the two), so the time asleep is never credited, while the session stays open and goes on crediting from the wake.
2. `init` subscribes to `NSWorkspace.shared.notificationCenter`'s `NSWorkspace.willSleepNotification` and `NSWorkspace.didWakeNotification`, calling those two with `Date()`, in the same style as the existing `availabilitySubscription` (Combine `publisher(for:)`, `[weak self]`); keep the subscriptions in properties.
3. Comment both, with why.

Test, in `ReadingStatsServiceTests` (grep how it makes a service on a temporary file and starts sessions at given dates): start a session at t0, checkpoint at t0+60, `noteSystemWillSleep(at: t0+60)`, `noteSystemDidWake(at: t0+8h)`, end the session at t0+8h+30; the book's total and today's are 90 seconds (within the class's tolerance). Also: a wake with no session open changes nothing.

## Run
`PlaybackMemoryGuardTests UnsavedChangesTerminationTests ReadingStatsServiceTests ReadingStatsTimeZoneTests` (if that class exists; grep) plus the class you used to open a reader for item 1.

## Do not touch
`withStorageWorkHeld` and `DataDirectoryMigrator.swift` (the tests team fixes the writers racing a data-directory move tonight, the statistics' saves among them), the checkpoint policy's 30 seconds, the reader's close path, the quit sequence's order beyond the one call added to the flush, or any wording (none changes).
