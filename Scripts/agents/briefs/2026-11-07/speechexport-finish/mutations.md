# speechexport-harness: the mutations to run (FMT43), November 7, 2026

For `speechexport-harness`, in the harness its brief made (`harness.md`, whose rules all still hold: no `rm`, plain shell commands, under `run_locked.py`, no window tests in the harness, no sound).

Refresh the harness's sources from the tip of `speechexport/finish` first (the lead names the commit), add `SpeechExportDialogTests` and `SpeechExportOptionsTests` with their window tests left out (every test that calls `withHostedView` or hosts a view in a window), and run every class once clean: that is the baseline. A baseline failure is a finding: report it, and go on with the rest.

Then each mutation below, one at a time, **in the copy under `build/harness/src` only, never in the repository**, with a small Python script that makes the one replacement (checking it found the text exactly once, and stopping otherwise), builds and runs the classes named, records which tests failed, and puts the original text back before the next. Each run under `run_locked.py`. Save the results as a table in `build/harness/mutations.tsv`. A build that fails to compile counts as "not run": fix the mutation so it compiles.

A mutation **survives** when every named test passes under it. Survivors are what the lead needs most: name each, with what you think the test misses. Do not edit any test.

## The list

Each line: file (under `TextMouth/`), the change, and the classes to run.

### The job (`Services/SpeechExport/SpeechExportJob.swift`, classes `SpeechExportJobTests SpeechExportServiceTests`)
1. Move `plan.store.removeAll()` before `try deliver()`.
2. Remove `try deliver()`.
3. In the catch, report `.ended(kept: counts.total, total: counts.total)`.
4. After success, report `.ended(kept: counts.total, total: counts.total)`.
5. `counts.kept = 0` in place of `try min(plan.store.open(), sections.count)`, with the store still opened (`_ = try plan.store.open()`).
6. `trailingSilence: SpeechExportJob.chapterGap` for every chapter, the last too.
7. In `Plan.init`, pass `pitch: 1` to the store's key instead of the request's pitch.
8. In `Plan.init`, leave the sections out of the key: `sections: []`.
9. `plan.checkSpace(keeping: 0, ...)` in place of `keeping: counts.kept`.
10. Remove `try cancellation.checkCancelled()` before the store is opened.
11. Remove the `whileHeld` hold: call the closure's contents directly, however is simplest (or make `hold` not run: `power.whileHeld` replaced by a direct call).
12. In `Shares.progress(speaking:framesWritten:)`, drop `min(Self.partCap, ...)`.
13. In `ProgressReporter.report`, drop the interval check (`urgent ||` always true).

### The store (`Services/SpeechExport/SpeechExportStore.swift`, classes `SpeechExportSupportTests SpeechExportJobTests`)
14. In `open()`, keep other exports' folders (remove the loop over `others`).
15. In `open()`, keep part files.
16. In `open()`, do not remove the chapters after the first missing one.
17. `isWholeChapter`: `return true` once the file exists.
18. `key`: leave out the voice identifier.
19. `removeAll()` does nothing.

### The renderer (`Services/SpeechExport/SpeechChapterRenderer.swift`, classes `SpeechChapterRendererTests SpeechExportJobTests`)
20. `rate:` fixed at 0.5 in `render`.
21. `pitchMultiplier:` fixed at 1.
22. In `ChapterSpeaker.speak`, no retry after a refusal.
23. In `render`, do not remove the file after a failure.
24. Do not throw `noSound` when no frame was written.
25. `isSameKind` always true.

### The text (`Services/SpeechExport/SpeechExportText.swift`, classes `SpeechExportTextTests SpeechExportJobTests`)
26. `pastLast = last + 1` (a To heading without its subheadings).
27. In `spans`, `first = 0` even with a From heading.
28. In `sections`, keep pieces with nothing speakable.
29. In `spokenOffset`, always `speech.offsetMap.toModified(offset)`, with no special case at either end.
30. `inputs(forChapterAt:...)`: `chapterHeadings` always `[]`.

### The encoder (`Services/SpeechExport/SpeechExportEncoder.swift`, class `SpeechExportEncoderTests`)
31. Titles nil in the timeline (`title: nil`).
32. Do not remove the destination on Stop.
33. No watch for Stop: run the work alone.

### The dialog's model (`ViewModels/BookExportModel.swift`, class `SpeechExportDialogTests`)
34. `speechRequest`: `books.first` in place of `currentBooks(books).first`.
35. `makeSpeechOptions`: `offer.book` in place of the library's copy.
36. `titleTag` always the book's title.
37. `titleTag` always the file title.
38. `skippedHeadingIDs: []` in the request.
39. `preparation: SpeechPreparationSettings.current()` with no arguments.
40. `conversions`: make the `.speech` conversion whether or not the kind is checked.
41. `optionsView`: return the view whether or not the kind is checked.
42. `load()`: leave the kind listed when its text cannot be read.
43. `load()`: make the options for an unavailable kind too.
44. The end: leave out the kept sentence.
45. The end: `speechProgress` not set to nil.
46. `progressText`: ignore the speech progress.
47. `progressFraction`: ignore the speech progress.
48. `showSpeechProgress`: no `guard isExporting`.
49. `isExportingSpeech`: `isExporting` alone.
50. `export`: pass no `speech:` context (so the live one would run: **do not run this one**; instead pass a context with the right environment and a progress closure that does nothing).

### The options' state (`ViewModels/SpeechExportOptionsState.swift`, class `SpeechExportOptionsTests`)
51. `setFrom`: no move of the To.
52. `setThrough`: no move of the From.
53. `fileTitle`: always "<stem> - Audio".
54. `fromItems` without the beginning.
55. The init: no holding of the speed to its range.

### The service (`Services/BookExportService.swift`, classes `SpeechExportServiceTests BookExportServiceTests`)
56. `spokenFiles`: no check of `request.bookID`.
57. `spokenFiles`: no `safeFileName`.
58. `moveScratchFile`: no `checkCancelled`.
59. `files(of:for:conversions:)`: plan a `.spoken` file through a text conversion (`case .spoken: url = source...`), if that compiles simply; otherwise skip and say so.
60. `offer(for:)`: offer the kind for an audiobook too.

### The words (`Models/SpeechExportWording.swift`, class `SpeechExportDialogTests`)
61. `kept`: `done > total` in place of `done >= total`.
62. `progress`: `done + 1` without the `min`.

## Report

The table's result per mutation, one line each: its number, whether it was caught, by which test, or that it survived, with your reading of why. Keep it under 80 lines. Do not fix anything. Leave the harness in place.
