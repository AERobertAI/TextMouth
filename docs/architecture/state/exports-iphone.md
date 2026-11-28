# Exports on the iPhone
<!-- id: exports-iphone; keys: FR31, iPhone export, delivery seam, BookExportDelivery, memory check, export folder; src: -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).
The model, the service, and the writers are shared with the Mac and are in [Exports](exports.md).
The sheet and its entry points are in [The iPhone interface](../platforms-phone-interface.md#the-export-sheet).
What a person hears is in [Exporting on the iPhone](../../user/exporting-on-iphone.md).

## The delivery seam
<!-- id: export-delivery-seam; keys: BookExportDelivery, moving, coordinatedCopy, NSFileCoordinator, scratch folder, copyExclusively, stale scratch folders, Stop; src: TextMouth/Services/BookExportDelivery.swift, TextMouth/Services/BookExportService.swift, TextMouthProductionTests/BookExportDeliveryTests.swift -->

Every file is made whole in a scratch folder and then delivered to its name in the chosen folder, which nothing already there is ever replaced by.
The one thing that differs between the apps is how a scratch folder is made and how a finished file crosses, and `BookExportDelivery` holds both as a value that `BookExportService.export` is given (`BookExportDelivery.standard` picks by platform).

- `moving`, the Mac's: the scratch folder is `makeScratchFolder(near:)`'s, on the target's volume, and delivery makes the target's folder and calls `moveExclusively` (see [Exports](exports.md)).
- `coordinatedCopy`, the iPhone's: the scratch folder is `makeTemporaryScratchFolder()`'s, in the app's temporary folder, named with `BookExportDelivery.scratchFolderPrefix`.
  Delivery is `copyCoordinated(_:to:cancellation:)`: the target's folders are made, and then the whole file or package is copied to the target, each under an `NSFileCoordinator` that coordinates the writing, with `copyExclusively` so a taken name fails with `fileWriteFileExists`.
  A rename out of the app's container into a file provider's folder isn't relied on, and a provider's folder is where Apple says to coordinate every access.
- Stop calls the coordinator's `cancel()` through the export's `BookExportCancellation`, so a coordination blocked on a provider ends as `CancellationError`, which `coordinateWriting` tells from a failure.
- The export removes its own scratch folder afterwards, as on the Mac.
  `removeStaleScratchFolders` removes the scratch folders a launch ended mid-file left, those a day older than now, as an export starts and off the main thread; it touches nothing else in the temporary folder.
- Both ways are tested on the Mac's host: `BookExportDeliveryTests` runs the iPhone's copy too, and is shared with the iPhone's unit bundle.

## The kept folder
<!-- id: export-kept-folder; keys: PhoneExportFolder, bookmark, security scope, phoneExportFolderBookmark, localizedName, stale bookmark, holdAccess; src: TextMouth/Phone/PhoneExportFolder.swift, TextMouthProductionTests/PhoneExportFolderTests.swift -->

- `PhoneExportFolder` keeps the folder the picker returned as a bookmark in the preferences (`bookmarkKey`, "phoneExportFolderBookmark"), made while the picker's security scope is held.
  When no bookmark can be made, nothing is kept and the one before is forgotten, so a choice that was not kept is never undone silently later.
- `kept(in:)` resolves it when the sheet's model is made, once, on the main thread.
  A stale bookmark of a folder that is still there is made again; one that no longer resolves, or whose folder is gone or is no longer a folder, is forgotten, and the folder row asks again.
- The name shown, "Downloads", is `URLResourceValues.localizedName`, read once under the scope, since outside it an iCloud Drive folder may read as its path's last part; `BookExportWording.folderName(of:)` uses it on the iPhone and `FileManager.displayName(atPath:)` on the Mac.
- An export holds the folder's scope for its whole run (`holdAccess(to:)`) together with a background task (`PhoneLifeCycle.beginHold`), through the model's `holdWhileExporting`.
- A Debug build alone reads `TEXTMOUTH_EXPORT_TO` (`PhoneLaunchRequest.exportFolder`), an absolute path used as the folder with no picker, which an interface test cannot drive; it is inside `#if DEBUG`, as `TEXTMOUTH_UI_TEST` is.

## The memory check
<!-- id: export-memory-check; keys: PhoneExportMemoryCheck, os_proc_available_memory, SessionMemoryFloor, peakBytesPerTextByte, braillePeakBytesPerTextByte, PHONE_EXPORT_PEAK, tooLittleMemory; src: TextMouth/Phone/PhoneExportMemoryCheck.swift, TextMouth/Platform/iOS/Services/PhoneExportMemoryCheck+iOS.swift, TextMouth/Phone/PhoneExportWording.swift, TextMouthiOSTests/PhoneExportPeakMemoryTests.swift, TextMouthProductionTests/PhoneExportMemoryCheckTests.swift -->

A text conversion walks all of content.md into an `ExportDocument`, and HTML, RTF, and EPUB build their file in memory, so a large book could ask for a gigabyte and iOS would end the app.
`BookExportService.export` asks its `memoryGuard` before each book's walk (and before plain text and captions, under the ids `plain-text` and `captions`), and a refusal fails that file with `PhoneExportWording.tooLittleMemory`, while the other files still export.

- The memory left is `SessionMemoryFloor.app.left` (`os_proc_available_memory()`), which is nil where the system sets no limit, as in the simulator, and then every conversion is allowed.
- A conversion is allowed when the memory left is at least the estimated peak plus a floor of 512 MB (`floorBytes`, the in-app FFmpeg converter's floor).
- The estimate is the text's bytes times a figure for the writer:
  - 16 (`peakBytesPerTextByte`) for Markdown, HTML, RTF, EPUB, plain text, and captions;
  - 32 (`braillePeakBytesPerTextByte`) for BRF and PEF, which keep print blocks and cells beside the translation.
- How they were measured, on GitHub's simulator and never on the Mac, by `PhoneExportPeakMemoryTests`:
  - each writer exports a fixture through the real service while a thread samples the process's physical footprint, and the peak above the start, over the text's size, is one `PHONE_EXPORT_PEAK` log line;
  - the text writers held 5.4 to 10.9 bytes for each byte in six runs; HTML read 10.57 in one run and 10.94 in the next, so each figure leaves a margin over its range;
  - braille held 10.9 to 28.8 for 1 MB of text in five runs, which includes the engine's own 0.6 to 3 MB and a first compile of its tables, and 19.0 to 25.7 for 3 MB with the engine warm;
  - the test fails only past twice a figure, so a writer that grew shows in the log and a figure is raised by its evidence.
- A first tiny braille export warms the engine, and its peak, logged as `writer=engine`, must stay under 64 MB, inside the floor.
  The braille fixtures are 1 MB, since the translation has a time limit for the whole call.
- The test runs only on GitHub's runner (`TestMachine.skipUnlessGitHubRunner`), since it fills hundreds of megabytes.

## The model's hooks
<!-- id: export-iphone-model-hooks; keys: BookExportModel, offering, destinationIsChosen, memoryGuard, holdWhileExporting, PhoneExportQuestionPrompt, DeepChapterPrompting, finishedWords; src: TextMouth/ViewModels/BookExportModel.swift, TextMouth/Phone/PhoneExportQuestion.swift, TextMouth/Phone/PhoneExportOffer.swift, TextMouthProductionTests/PhoneExportModelTests.swift, TextMouthProductionTests/PhoneExportQuestionTests.swift -->

The iPhone's sheet reads the shared `BookExportModel` and gives it these at its start (`PhoneExportSheet.makeModel`), each with a default that leaves the Mac as it was:

- `offering`: `PhoneExportOffer.kinds`, every `BookExportKind`, spoken audio included (the model itself offers it for one text book alone).
- `destination`, `destinationIsChosen`, and `destinationName`: the kept folder, or none, in which case Export stays dimmed until `chooseDestination(_:named:)`.
- `delivery`: `.coordinatedCopy`; `memoryGuard`: `PhoneExportMemoryCheck.live`; `holdWhileExporting`: the folder's scope and a background task.
- `deepChapterPrompting`: `.standard`, which on iOS makes a `PhoneExportQuestionPrompt`.
  It shows `PhoneExportQuestion` as an alert over the sheet and resumes the waiting export exactly once, whichever of a button, `dismiss()`, and a second question comes first, so an export never waits for ever.
  A dismissal by the escape gesture or by Stop answers Cancel Export.
- `finishedWords` keeps the end's sentence for the sheet, which stays open after an export; the Mac's dialog closes.

## Spoken audio and the session
<!-- id: export-iphone-spoken-audio; keys: PhoneExportSession, PhoneExportBackgroundTask, BGContinuedProcessingTask, PhoneExportTaskMirror, PhoneExportProgressCard, SpeechExportStore, RunningClock, wordsBeforeTheEnd; src: TextMouth/Phone/PhoneExportSession.swift, TextMouth/Phone/PhoneExportTaskMirror.swift, TextMouth/Platform/iOS/Services/PhoneExportBackgroundTask.swift, TextMouth/Platform/iOS/Views/Library/PhoneExportProgressCard.swift, TextMouth/Platform/iOS/Views/Export/PhoneSpeechExportRows.swift, TextMouth/Services/SpeechExport/SpeechBufferSynthesizer.swift, TextMouth/Services/SpeechExport/SpeechExportStore.swift, Scripts/ios/sync-info-plist.py, TextMouthProductionTests/PhoneExportSpeechTests.swift -->

The speech export is the Mac's code: `SpeechExportJob` speaks with `AVSpeechSynthesizer.write(_:toBufferCallback:)` and encodes through the audio editor's renderer.
What differs is how it keeps running, who stops it, and what it says.

- `SpeechBufferDelivery` times its stall limits by a `RunningClock`, which is `.app` on the iPhone and `.system` on the Mac, so a suspension is no stall; the write holds the clock's heartbeat.
- `PhoneExportSession.shared` runs each export (`export(_:)`), one at a time (`running`, `isBusy(for:)`), so a second export is dimmed in its sheet and refused by the session.
  For a spoken audio export it asks `PhoneExportTasking` for a continued processing task as Export is pressed, the person's action iOS requires.
  `PhoneExportBackgroundTask` registers a handler under `com.textmouth.TextMouth.iOS.export.` and a UUID, which the plist's wildcard permits, then submits with the strategy `fail`.
  When the system takes no task, the export goes on held by the background task every export has.
- The task's progress is `PhoneExportTaskMirror.update`: the whole export in a thousand units, never going back (`NeverBackwards`), and the progress words as its subtitle.
  It measures the whole export, not the sheet's bar, which starts again at 0 for the encoding: speaking fills 80% of the spoken file's share and encoding the rest, so the Live Activity keeps moving to the end, and iOS doesn't take a long book's encoding for a stall.
  The session ends the task with the export, a success only when every file was written.
- The expiration handler, from iOS or from Cancel in the Live Activity, is `stopBySystem(_:)`: it sets `BookExportModel.wordsBeforeTheEnd` and stops, so the end begins "iOS stopped this export." and then says what is kept for a week.
  An export that finished before the stop took effect does not begin so.
- The card's focus has one owner (`PhoneExportCardFocus`): the dismissal of the sheet that closed on the card gives it the card's title, the end moves focus only off the card's Stop, and closing it goes to the Library's first row.
  A new export that replaces an ended card asks for no focus (the `replaced` event), so focus stays in the new sheet; the card has an identifier the list scrolls to.
  The session clears iOS's words (`wordsBeforeTheEnd`) at every end, so they never begin the next export's.
- The sheet may close only while the audio file is made (`BookExportModel.isMakingSpeech`).
  `sheetClosed(_:)` then makes the card (`cardModel`, told to the Library by `cardEvents`) and lowers the end's announcement.
  A file of the same book can follow the spoken audio (a transcript, an original), and may ask about a chapter nested too deeply, so `PhoneExportQuestionPrompt` answers Cancel Export at once once the sheet has closed, and the end says so.
  `testAFileCanFollowTheSpokenAudioSoThePromptHasToAnswerForAClosedSheet` pins the order.
- `SpeechExportStore` keeps an export's chapters for a week on the iPhone (`keptOnPhone`), and the iPhone's launch sweep removes older ones (`sweep(keeping:)`, from the app delegate); the Mac keeps them until it quits.
- The words that name the Mac take the iPhone's through an `onPhone` parameter whose default is `SpeechRefusalWording.runsOnPhone`: the two refusals, the engine's refusal, the licence line, Stop's hint, and the kept sentences.
- Tests:
  - the speech export's suites run on the Mac's host with a fake synthesizer that makes a tone in memory, never aloud;
  - `PhoneExportSpeechTests` is plain-value tests shared with the iPhone's bundle, and the session's tests are in `SpeechExportDialogTests`;
  - no test presses Export with spoken audio on the iPhone.

## Several books and Share…
<!-- id: export-iphone-several-share; keys: exportFolder, booksInFolderTree, PhoneShareSheet, shareButton, holdAccess, popover; src: TextMouth/Phone/PhoneLibraryOffer.swift, TextMouth/Platform/iOS/Views/Library/PhoneLibraryView.swift, TextMouth/Platform/iOS/Views/PhoneShareSheet.swift, TextMouth/Platform/iOS/Views/Export/PhoneExportSheet.swift, TextMouth/Phone/PhoneExportOffer.swift -->

- A folder row's `.exportFolder` command, titled by `BookExportWording.commandTitle(count:)` for the books in the folder tree, opens `PhoneExportSheet` over `Library.booksInFolderTree(_:)`.
  The shared service plans a folder for each book.
- `PhoneExportOffer.shareButton(stage:exportedCount:)` offers Share… after an export that wrote a file.
  The sheet holds the destination's scope (`PhoneExportFolder.holdAccess(to:)`) while `PhoneShareSheet` (a `UIActivityViewController`) shows.
  It is a popover anchored to the button, which iOS adapts to a sheet in compact width.
