# Saving failures
<!-- id: saving-failures; keys: persistence failure, unsaved changes, write failure; src:  -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## Outstanding failed writes
<!-- id: outstanding-failed-writes; keys: PersistenceFailure, PersistenceSubsystem, PersistenceBannerRow, PersistenceFailureBanner, recordFailure, recordSuccess, save failed, originalFileCleanup; src: TextMouth/Services/PersistenceFailureCenter.swift, TextMouth/Views/Library/PersistenceFailureBanner.swift, TextMouth/App/UnsavedChangesTermination.swift, TextMouth/Services/Feeds/FeedStore.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/ReadingStatsService.swift, TextMouth/Services/ConfigService.swift, TextMouth/Services/TextSubstitutionService.swift, TextMouth/ViewModels/LibraryViewModel+Duplicates.swift -->

Outstanding failed writes.

- Owner: PersistenceFailureCenter.shared, which keeps the latest failure of each file (of each book, for package records) with its path, error, time, and a retry when the write can run again with the same data.
- Who may write it: every service that saves a store reports failures and successes from its own queue, without waiting, and a later success for the same file settles its failure:
  - the library index and package records (LibraryPersistenceService),
  - statistics (ReadingStatsService),
  - settings (ConfigService),
  - substitution rules (TextSubstitutionService),
  - feed records (FeedStore),
  - an import's cleanup of the original file,
  - and a package that a failed library transition's rollback could not put back (`.strandedPackage`, from `LibraryViewModel+BookOperations.moveBack`).
- A Retry while an operation holds the storage work (a data-directory move, Rebuild Directory, a folder edit, Move to Library, a switch of libraries) does not wait on the main thread or write at once.
  The failure center keeps the retry across the held work and runs it when the hold ends, in the data directory then in use, for statistics, settings, substitution rules, feed records, and a stranded package (whose Retry then acts where the package is).
  The failure's reason says when the changes are saved (FeedRecordWaitsForStorageWork, FeedWording.recordWaits(for:) for a feed), and PersistenceFailureCenter.announceOutcomeOfWaitingRetry(of:) tells VoiceOver how it went.
  Retry Saving stays enabled during a move.
- A save of the statistics or the substitution rules made while a move copies the library is provisional (StorageBoundary.isProvisionalSave(of:rewrite:), [Holding storage work](data-directory.md)).
  It is written and a failure is recorded as any other, but its success settles no earlier failure.
  The save the move makes again after its hold is released does, once the move has waited for the statistics' queue, so an outcome is never judged before it.
  Quit Anyway during a long Rebuild Directory leaves such a change unsaved, and a change the quit stopped waiting for is reported with no Retry.
- How others observe it: the Library window's banner shows one row for each failing subsystem, with Retry and Dismiss, and VoiceOver announces a subsystem once when it starts to fail.
  While anything is unsaved, hasUnsavedChanges makes quitting ask first (UnsavedChangesTermination, with Retry, Quit Anyway, and Cancel).

## Quitting with something unsaved
<!-- id: quitting-something-unsaved; keys: applicationShouldTerminate, TerminationDecision, terminateNow, QuitReason, QuitHold, QuitFinisher, QuitNotice, quit alert; src: TextMouth/App/UnsavedChangesTermination.swift, TextMouth/App/QuitRequest.swift, TextMouth/App/QuitFinisher.swift, TextMouth/App/QuitReason.swift, TextMouth/App/QuitHold.swift, TextMouth/Platform/macOS/Views/QuitNotice.swift -->

Quitting with something unsaved (UnsavedChangesTerminationGuard; the whole quit is in [Launch](../launch.md)).

- The order: the guard answers after step 0's questions (a library move, the Record window's take, the audio editors' edits) and before step 4's work (downloads, re-reads, and speech exports finished before TextMouth quits).
- Retry runs every unsaved write again and asks to quit again; Quit Anyway asks to quit again with its choice kept for that one request; Cancel keeps TextMouth open.
  Both ask through QuitRequest.ask(), a timer on the main run loop, never a call from a main-queue block, which would leave a held quit with no reply.
- Quit Anyway answers one request, the one it makes.
  If step 4 cancels that request to finish work (reply(whenQuitting:) returns .terminateCancel), the choice is kept for the request that follows the work, so the unsaved-changes alert is not shown twice.
- If an earlier question cancels the request that follows the work (a take, an editor's edits, or a library move began meanwhile), the kept Quit Anyway is forgotten (forgetQuitAnyway()), since it belonged to that quit, and a later quit asks again.
- A quit asked for by the system ending the session meets the guard like any other.
  With changes unsaved it is cancelled, which stops the log out, and the alert is shown.
