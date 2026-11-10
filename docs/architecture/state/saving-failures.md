# Saving failures

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

- Outstanding failed writes.
  - Owner: PersistenceFailureCenter.shared, which keeps the latest failure of each file (of each book, for package records) with its path, error, time, and a retry when the write can run again with the same data.
  - Who may write it: every service that saves a store reports failures and successes from its own queue, without waiting: the library index and package records (LibraryPersistenceService), statistics (ReadingStatsService), settings (ConfigService), substitution rules (TextSubstitutionService), feed records (FeedStore), and an import's cleanup of the original file. A later success for the same file settles its failure.
  - How others observe it: the Library window's banner shows one row for each failing subsystem, with Retry and Dismiss, and VoiceOver announces a subsystem once when it starts to fail. While anything is unsaved, hasUnsavedChanges makes quitting ask first (UnsavedChangesTermination, with Retry, Quit Anyway, and Cancel).
  - Files: Services/PersistenceFailureCenter.swift, Views/Library/PersistenceFailureBanner.swift, App/UnsavedChangesTermination.swift, Services/Feeds/FeedStore.swift.
- Quitting with something unsaved (UnsavedChangesTerminationGuard; the whole quit is in [Launch](../launch.md)).
  - The order: the guard answers after step 0's questions (a library move, the Record window's take, the audio editors' edits) and before step 4's work (downloads, re-reads, and speech exports finished before TextMouth quits).
  - Retry runs every unsaved write again and asks to quit again; Quit Anyway asks to quit again with its choice kept for that one request; Cancel keeps TextMouth open. Both ask through QuitRequest.ask(), a timer on the main run loop, never a call from a main-queue block, which would leave a held quit with no reply.
  - Quit Anyway answers one request, the one it makes. If step 4 cancels that request to finish work (reply(whenQuitting:) returns .terminateCancel), the choice is kept for the request that follows the work, so the unsaved-changes alert is not shown twice.
  - If an earlier question cancels the request that follows the work (a take, an editor's edits, or a library move began meanwhile), the kept Quit Anyway is forgotten (forgetQuitAnyway()), since it belonged to that quit, and a later quit asks again.
  - A quit asked for by the system ending the session meets the guard like any other. With changes unsaved it is cancelled, which stops the log out, and the alert is shown.
  - Files: App/UnsavedChangesTermination.swift, App/QuitRequest.swift, App/QuitFinisher.swift, App/QuitReason.swift, App/QuitHold.swift, Platform/macOS/Views/QuitNotice.swift.
