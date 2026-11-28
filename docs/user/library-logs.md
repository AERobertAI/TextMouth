# The diagnostic logs
<!-- id: library-logs-diagnostic-logs; keys: log files, debug log, diagnostics, troubleshooting; src: TextMouth/Services/DiagnosticLog.swift, TextMouth/Services/LogWriter.swift, TextMouth/Views/Settings/LogsSettingsSection.swift -->

Part of [TextMouth's documentation](../../README.md).

## The Logs folder
<!-- id: logs-folder; keys: privacy, no book text, redaction, log contents; src: TextMouth/Services/DiagnosticLog.swift, TextMouth/Services/LogWriter.swift, TextMouth/Services/TextMouthPaths.swift -->

Logs: the diagnostic logs, which TextMouth writes here unless Storage settings put them on this Mac, so they sit beside your books, move with the library, and sync with it when it is in the cloud.
They never hold your substitution rules, and they name files by their place inside the data directory or this Mac's TextMouth folder.
They hold none of your books' text either: a CONTENT_INDEX_REJECTED line, written when a book's saved index is set aside and rebuilt, names a heading that changed by where it changed, never by its words.
A transcript is a book's text too:

- the TRANSCRIPT_FILE, TRANSCRIPT_STALE, and TRANSCRIPT_TEXT_REBUILT lines name a book's files by their place in the book, and never quote what was heard,
- a transcription's TRANSCRIPTION_STARTED line names the book and the language, and the line that ends it, TRANSCRIPTION_FINISHED, TRANSCRIPTION_CANCELLED, or TRANSCRIPTION_FAILED, the seconds it took and the words it found, or why it failed, never a word heard,
- the TRANSCRIPT_CLEANUP_RULES, TRANSCRIPT_CLEANED_UP, and TRANSCRIPT_CLEANUP_UNDONE lines of a cleanup give counts and file names, never the words it changed or its rules,
- an AUDIO_EDITS_FILE line, for an audio edit history that can't be used, never quotes the history, which can hold chapter titles,
- and an AUDIO_EDITOR line, for an editor that couldn't open a book or finish a save or an export, names the error by its kind, never by a file's path.

A feed is named by its host, never by its whole address, which can carry a private feed's token.

## textmouth_debug.log, the main log
<!-- id: textmouth-debug-log-main-log; keys: log lines, events, troubleshooting, speech refusal, Where Am I; src: TextMouth/Services/DiagnosticLog.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouth/Services/FileImportService.swift, TextMouth/Views/Library/LibrarySheetViews.swift, TextMouth/Services/LibraryPersistenceService.swift -->

textmouth_debug.log, the main log.
- Its PLAYBACK_STOPPED_AFTER_REFUSAL line tells of a reader that stopped at a passage the speech engine refused,
- its PLAYBACK_PAUSED_AFTER_START_STALLS line of a reader that paused where the voice did not start,
- its WHERE_AM_I_CANCEL_UNEXPECTED line of a Where Am I? announcement the system cut short,
- and its WHERE_AM_I_RESUME_REJECTED line of a book Where Am I? paused that would not resume as the announcement ended, which is left paused.

- Its BOOK_FINISHED line marks each end of a book but a loop's, naming the book by the start of its identifier and saying whether Books Finished counted it then, had counted it already, or heard a rewind replay its end;
- and one FINISHED_BOOKS_AT_END line counts the finished books the one-time move put at their ends, those waiting for a later launch, and those it could not place.

Every ZIP import of several books ends with a ZIP_IMPORT_FINISHED line naming the archive, with the books imported, skipped as duplicates, failed, and imported without all their text, whether Cancel stopped it, and the files it passed over by kind, as in "notBooks=176 (wma 176)".
Its MOVE_SHEET_SHOWN line tells of the Move to Folder or Move to Library sheet appearing, with how many places it lists and how many items it moves, as in "MOVE_SHEET_SHOWN: Move to Folder lists 5 place(s) for 2 item(s)", never a title or a path.
Its LIBRARY_ROWS_KEPT line tells, when library.json is read, how many of its rows need a newer TextMouth and are kept as they are, and its ASYNC_TIME_LIMIT line of an audio read that passed its limit and was abandoned, naming no file or title.

## Playback events in the debug log
<!-- id: playback-events-debug-log; keys: stalled player, memory guard, sound effects; src: TextMouth/Services/AudioPlaybackService.swift, TextMouth/Services/PlaybackMemoryGuard.swift, TextMouth/Services/SoundEffectService.swift -->

The debug log names these playback events: AUDIO_PLAYBACK_STALLED (a player whose time stopped moving), AUDIO_MEMORY_RUNAWAY (the memory guard stopping playback or quitting), and SOUND_EFFECT_STUCK (sounds dropped behind one that didn't start).

## textmouth_timer.log, the sleep timer's log
<!-- id: textmouth-timer-log-sleep-timer; keys: sleep timer, timer log; src: TextMouth/Services/DiagnosticLog.swift -->

textmouth_timer.log, the sleep timer's log.

## textmouth_transition.log, the speech engine's log
<!-- id: textmouth-transition-log-speech-engine; keys: speech engine, voice, watchdog, refused passage; src: TextMouth/Services/SpeechService.swift, TextMouth/ViewModels/ReaderViewModel+SpeechRefusal.swift -->

textmouth_transition.log, the speech engine's log.
- Its DIRECT_CANCEL_UNEXPECTED, DIRECT_RETRY_ENGINE, DIRECT_RETRY_ENGINE_FAILED, DIRECT_RETRY, DIRECT_RETRY_AT_RESUME, SLEEP_FADE_DIRECT_SEGMENT_REFUSED, DIRECT_RETRY_FAILED, RENDER_REFUSED, and RENDER_RETRY_RENDERED lines tell of a passage the speech engine refused and what TextMouth did then;
- its DIRECT_WATCHDOG_RECOVERY, DIRECT_START_WATCHDOG_RECOVERY, DIRECT_START_STALLED, and DIRECT_IDLE_STALLED lines of speech that stalled or never started, and how it went on or where it paused;
- its SEEK_ENGINE_FAILED, DIRECT_WATCHDOG_ENGINE_FAILED, and DIRECT_START_WATCHDOG_ENGINE_FAILED lines of prepared audio that could not play, after which speech went on from the voice;
- its AUDIO_ENGINE_START_FAILED lines of a play or a resume that could not start the audio engine, with the system's words for why;
- and its DIRECT_SYNTH_REPLACED lines of each fresh start of the voice and why;
- all by offsets and lengths, never the passage's words.

Its SPEECH_REFUSAL_REPORTED line tells of the report shown when speech stopped, with how many times that place was refused and whether VoiceOver was told.

## Trace lines
<!-- id: trace-lines; keys: tracing, verbose logging, defaults write, environment variable; src: TextMouth/Services/DiagnosticLog.swift -->

Routine trace lines are written only while tracing is on: set the TEXTMOUTH_TRACE_LOG environment variable for one launch, or run `defaults write com.textmouth.TextMouth diagnosticTraceLogging -bool YES` until you turn it off again with `-bool NO`.

## Log rotation
<!-- id: log-rotation; keys: rotate, size limit, cloud upload, previous generation; src: TextMouth/Services/LogWriter.swift -->

A log that reaches 2 MB is renamed with .previous added to its name, replacing the older one in the same step, and a fresh one starts, so each log keeps at most two generations and a cloud drive uploads little.
When the rename is refused twice, as a cloud drive can refuse one while it uploads the file, the log starts over instead, beginning with a LOG_ROTATION line saying why.
TextMouth never downloads a log to add a line to it: one whose content is only in the cloud becomes the .previous generation, and a fresh one starts.

## Choosing where the logs go
<!-- id: choosing-where-logs-go; keys: Log location, Logs group, Storage tab, Finder; src: TextMouth/Views/Settings/LogsSettingsSection.swift, TextMouth/Services/LogWriter.swift, TextMouth/Platform/macOS/Views/LogsInFinder.swift -->

The Logs group in Storage settings chooses where they go: Log location offers Inside the data directory, the default, and In this Mac's Logs folder (~/Library/Logs/TextMouth).
A change applies from the next line written; logs already written stay where they are.
The line under the picker names the folder in use, and why while the logs can't go where it asks, and Show Logs in Finder opens that folder, saying so, aloud too, when Finder can't.

## Logs while the library is missing
<!-- id: logs-while-library-missing; keys: fallback location, LOG_LOCATION, missing Logs folder; src: TextMouth/Services/LogWriter.swift, TextMouth/Services/TextMouthPaths.swift -->

While the library isn't available, or the data directory or its Logs folder is missing, the logs go to ~/Library/Logs/TextMouth, and back to the data directory once it can take them.
Each time they change place, the debug log they arrive in says why in a LOG_LOCATION line.
TextMouth never creates a folder in the data directory to write a log: the Logs folder is made with the data directory's other folders.
