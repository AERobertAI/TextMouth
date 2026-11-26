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

- `offering`: `PhoneExportOffer.kinds`, every `BookExportKind` but `.spokenAudio`, so the model lists no spoken audio.
- `destination`, `destinationIsChosen`, and `destinationName`: the kept folder, or none, in which case Export stays dimmed until `chooseDestination(_:named:)`.
- `delivery`: `.coordinatedCopy`; `memoryGuard`: `PhoneExportMemoryCheck.live`; `holdWhileExporting`: the folder's scope and a background task.
- `deepChapterPrompting`: `.standard`, which on iOS makes a `PhoneExportQuestionPrompt`.
  It shows `PhoneExportQuestion` as an alert over the sheet and resumes the waiting export exactly once, whichever of a button, `dismiss()`, and a second question comes first, so an export never waits for ever.
  A dismissal by the escape gesture or by Stop answers Cancel Export.
- `finishedWords` keeps the end's sentence for the sheet, which stays open after an export; the Mac's dialog closes.
