# Logs
<!-- id: logs; keys: diagnostics, logging, log files, console output; src:  -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## The diagnostic logs
<!-- id: diagnostic-logs; keys: logging, DiagnosticLog.File, event, trace, console echo, log levels; src: TextMouth/Services/DiagnosticLog.swift, TextMouth/Services/LogWriter.swift, TextMouth/Services/TextMouthPaths.swift, TextMouth/Models/LogLocation.swift -->

The diagnostic logs.

### Who owns the logs
<!-- id: who-owns-logs; keys: log rotation, .previous, serial queue, maxLogFileSize, log size cap, File Provider; src: TextMouth/Services/DiagnosticLog.swift, TextMouth/Services/TextMouthPaths.swift, TextMouth/Services/LogWriter.swift, TextMouth/Models/CloudStorageContract.swift -->

- Owner: DiagnosticLog, the one policy for what a log line may say and which lines are written.
  It alone calls TextMouthPaths.appendLog, which hands each line, by its log's name (DiagnosticLog.File), to LogWriter.shared.
  The writer writes on one serial queue, never blocking or crashing the app, opens each file for its line only, and keeps each file to two generations of at most 2 MB.
  A full log becomes its .previous by one rename(2) that replaces the older generation in the same step.
  A rename refused twice, as a File Provider folder can refuse one, starts the log over in place with a LOG_ROTATION line.
  And a log only in the cloud is never downloaded (every write runs inside DatalessFiles.withoutDownloading), but kept as the older generation while a fresh file starts.

### Where the logs are written
<!-- id: where-logs-are-written; keys: Logs folder, Library/Logs/TextMouth, log fallback, log location setting, LogDestination; src: TextMouth/Services/LogWriter.swift, TextMouth/Models/LogLocation.swift, TextMouth/Services/TextMouthPaths.swift, TextMouth/Models/CloudStorageContract.swift, TextMouth/Services/DataDirectoryAvailability.swift, TextMouth/ViewModels/SettingsViewModel.swift -->

- Where they are: TextMouthPaths.logDestination(for:dataDirectory:thisMacsFolder:isUnavailable:), the one resolution of the logs' folder, which the writer runs for every line (LogWriter.Environment.app) and Storage settings run to show it.
  Under the default choice (LogLocation.dataDirectory) it is the data directory's Logs folder, in the current storage generation's root; under the other (LogLocation.machine), this Mac's ~/Library/Logs/TextMouth (MachineLocalPaths.logs).
  While the data directory can't take lines (its gate is closed, its folder or its Logs folder is missing, as FolderState reads them without downloading, or a write there fails), lines go to this Mac's folder with the reason (LogDestination, LogFallback), and back once it can.
  Each time lines change place, the writer begins the debug log they arrive in with one LOG_LOCATION line saying why, a change of the choice included.
  It never makes a folder in the data directory: ensureDirectoryStructure makes Logs with the data directory's other folders, so a line never brings back a data directory that is gone.
  A move copies Logs with the rest, and lines go into the moved folder once the move publishes; a line written during the copy, after Logs was copied, stays in the old folder, which the move leaves where it was.

### Who may write a log line
<!-- id: who-may-write-log-line; keys: event vs trace, TRACE_SUPPRESSED, traceLinesPerSecond, log privacy, DiagnosticLog.Category, source scan, BuildIdentity; src: TextMouth/Services/DiagnosticLog.swift, TextMouth/Services/TextMouthPaths.swift, TextMouth/Services/LibraryWindowRouter.swift, TextMouth/Services/ImportScratchSpace.swift, TextMouth/Services/DataDirectoryAvailability.swift, TextMouth/Models/BookContentIndex.swift, TextMouth/App/BuildIdentity.swift, TextMouthProductionTests/LogContentPolicyTests.swift, TextMouthProductionTests/SourceScanTestSupport.swift, TextMouthProductionTests/UncheckedConcurrencyPolicyTests.swift -->

- Who may write it: any code, through DiagnosticLog.event, for a line that is always written and echoed to the console, or DiagnosticLog.trace, for routine lines written only while tracing is on and at most 20 a second in each category; DiagnosticLog.log takes the level as an argument.
  Every call names its category: playback, focus, import, storage, statistics, feeds, or app.
  The app category, for the app as a whole, holds the BUILD_IDENTITY line written at launch (which also goes to the unified log) and LibraryWindowRouter's routing, whose failures are events and whose routine waits are trace.
  Trace lines are marked with their category.
  A line goes to the debug log unless it is one of the sleep timer's or speech's own (DiagnosticLog.File).
  Lines never hold book text or substitution rules,
  - name files by their place inside the data directory or this Mac's own TextMouth folder (ImportScratchSpace.loggablePath),
  - name a data directory by its folder and the one holding it (DataDirectoryPaths.shortName(of:)),
  - name a feed by its host, never its whole address, which can carry a private feed's token,
  - and give book titles only in event lines.

  LogContentPolicyTests scans the source, read through AppSourceFile (TextMouthProductionTests/SourceScanTestSupport.swift) as UncheckedConcurrencyPolicyTests reads it, for calls that break these rules, and fails when
  - any file but DiagnosticLog.swift calls TextMouthPaths.appendLog,
  - or any file but TextMouthPaths.swift calls LogWriter.shared.append.

  No file is exempt from either check.
  A CONTENT_INDEX_REJECTED line carries the reason BookContentIndex gives, out of the scan's sight, which names a relabeled heading by where its labels first differ and how long each is, never by its words (alignmentFailure(with:countingWords:)).

### How the logs are observed
<!-- id: how-logs-are-observed; keys: log tags, event tags, Logs settings, Show Logs in Finder, LogsSettingsWording, tag catalogue; src: TextMouth/Services/DiagnosticLog.swift, TextMouth/Services/LogWriter.swift, TextMouth/Views/Settings/LogsSettingsSection.swift, TextMouth/Platform/macOS/Views/LogsInFinder.swift, TextMouthProductionTests/LogContentPolicyTests.swift, TextMouth/Models/FeedSettings.swift, TextMouth/Parsers/TextFileDecoder.swift, TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorLauncher.swift, TextMouth/Platform/macOS/Views/Recording/RecordingWindowController.swift, TextMouth/Services/AudioEditing/AudioEditHistoryStore.swift, TextMouth/Services/AudioEditing/AudioFilterPresets.swift, TextMouth/Services/AudioEditing/AudioOriginalSweep.swift, TextMouth/Services/BookCloudStorageService.swift, TextMouth/Services/BookExportService.swift, TextMouth/Services/BookTextEditing.swift, TextMouth/Services/DuplicateReplacement.swift, TextMouth/Services/Feeds/FeedCenter+DeleteFeed.swift, TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Services/Feeds/FeedDownloadManager.swift, TextMouth/Services/Feeds/FeedEpisodeExtras.swift, TextMouth/Services/Feeds/FeedEpisodeImporter.swift, TextMouth/Services/Feeds/FeedFetchState.swift, TextMouth/Services/Feeds/FeedIndex.swift, TextMouth/Services/Feeds/FeedItemPackage.swift, TextMouth/Services/Feeds/FeedLifecycle.swift, TextMouth/Services/Feeds/FeedNewestRule.swift, TextMouth/Services/Feeds/FeedRefresher.swift, TextMouth/Services/Feeds/FeedStore.swift, TextMouth/Services/KeptBooks.swift, TextMouth/Services/LibraryPersistenceService.swift, TextMouth/Services/LibrarySessionLease.swift, TextMouth/Services/MaintenanceFileAccess.swift, TextMouth/Services/MarkdownCacheService.swift, TextMouth/Services/ReaderWorkingCopy.swift, TextMouth/Services/ReadingStatsService.swift, TextMouth/Services/RecordingCaptureBackend.swift, TextMouth/Services/RecordingService.swift, TextMouth/Services/TextMouthPaths.swift, TextMouth/Services/TextSearch/LibrarySearchPreparer.swift, TextMouth/Services/TextSubstitutionService.swift, TextMouth/Services/TranscriptCleanupRuleFile.swift, TextMouth/Services/TranscriptCleanupStore.swift, TextMouth/Services/TranscriptStore.swift, TextMouth/Services/TranscriptTextLoader.swift, TextMouth/ViewModels/AudioEditSession.swift, TextMouth/ViewModels/AudioEditorModel+Saving.swift, TextMouth/ViewModels/LibraryViewModel+AudioEditing.swift, TextMouth/ViewModels/LibraryViewModel+Cloud.swift, TextMouth/ViewModels/LibraryViewModel+DeleteFeed.swift, TextMouth/ViewModels/LibraryViewModel+FeedDownloadReturn.swift, TextMouth/ViewModels/LibraryViewModel+FeedItemMove.swift, TextMouth/ViewModels/LibraryViewModel+MetadataRefresh.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/ViewModels/LibraryViewModel+MoveToLibrary.swift, TextMouth/ViewModels/LibraryViewModel+Recording.swift, TextMouth/ViewModels/LibraryViewModel+TextEncoding.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/ViewModels/ReaderViewModel+CloudDownload.swift, TextMouth/ViewModels/ReaderViewModel+OggConversion.swift, TextMouth/ViewModels/TranscriptionJobCenter.swift, TextMouth/Views/Library/LibrarySheetViews.swift -->

- How others observe it: by reading textmouth_debug.log, textmouth_timer.log, and textmouth_transition.log in the folder in use.
  Storage settings' Logs group (LogsSettingsSection, worded by LogsSettingsWording):
  - names that folder,
  - says why while the logs fall back,
  - and opens it in Finder through LogsInFinder.show(for:) (Platform/macOS/Views/LogsInFinder.swift), which the speech refusal report also calls and which prepares the folder first (TextMouthPaths.preparedLogsFolder).

  These groups of events have tags of their own, which LogContentPolicyTests pins with every other event tag:
  - The logs themselves: LOG_LOCATION, each time lines change place, and LOG_ROTATION, for a log started over.
  - The book service's downloads and removals: CLOUD_DOWNLOAD_STARTED, CLOUD_DOWNLOAD_FINISHED, CLOUD_DOWNLOAD_FAILED, CLOUD_DOWNLOAD_STOPPED, CLOUD_DOWNLOAD_REMOVED, and CLOUD_DOWNLOAD_REMOVAL_FAILED.
  - The list's commands: DOWNLOAD_NOW_STARTED, DOWNLOAD_NOW_FINISHED, DOWNLOAD_NOW_FAILED, REMOVE_DOWNLOAD_STARTED, REMOVE_DOWNLOAD_FINISHED, and REMOVE_DOWNLOAD_REFUSED.
  - Keep on This Mac:
    - KEEP_ON_MAC, for keeping and stopping and for a Kept Books.json or Keep Reading List Books.json that can't be read or saved,
    - and KEPT_BOOK_DOWNLOAD_STARTED, KEPT_BOOK_DOWNLOAD_FAILED, and KEPT_BOOK_DOWNLOAD_FINISHED, for the downloads a keep or a refresh starts,
    - and DOWNLOAD_SKIPPED_NO_ROOM, once for each book a download plan left out for want of free space (the origin and the title; logged again only after the book next starts), the only record of a book the listener kept themselves, since VoiceOver hears of the reading list's alone.
  - The reader: READER_DOWNLOAD_STARTED, READER_DOWNLOAD_FINISHED, READER_DOWNLOAD_FAILED, READER_DOWNLOAD_CANCELLED, READER_READ_REFUSED, WORKING_COPY_MADE, WORKING_COPY_SKIPPED, WORKING_COPY_REMOVED, WORKING_COPY_LEFT, and WORKING_COPIES_SWEPT.
  - Maintenance: MAINTENANCE_SKIPPED_IN_CLOUD, one line for each pass that left books in the cloud.
  - Package records: BOOK_RECORD_IN_CLOUD, once for each book whose saves go to library.json alone while its record is only in the cloud.
  - The data directory: DATA_DIRECTORY_FOUND, DATA_DIRECTORY_AVAILABLE, DATA_DIRECTORY_UNAVAILABLE, DATA_DIRECTORY_UNMOUNTED, DATA_DIRECTORY_LOST, DATA_DIRECTORY_MOVE, DATA_DIRECTORY_SWITCH, LIBRARY_IDENTITY, and LIBRARY_SESSION.
    Beside them are LIBRARY_COMPARED, CONFLICT_COPY_FOUND, SUBSTITUTIONS_FILE, and READING_STATS_FILE.

### Log tags: transcripts, recordings, and audio editing
<!-- id: log-tags-transcripts-recordings-audio; keys: TRANSCRIPT_FILE, TRANSCRIPTION_STARTED, RECORDING_STARTED, AUDIO_EDITS_SAVED, AUDIO_EDITOR; src: TextMouth/Platform/macOS/Views/AudioEditor/AudioEditorLauncher.swift, TextMouth/Platform/macOS/Views/Recording/RecordingWindowController.swift, TextMouth/Services/AudioEditing/AudioEditHistoryStore.swift, TextMouth/Services/AudioEditing/AudioFilterPresets.swift, TextMouth/Services/AudioEditing/AudioOriginalSweep.swift, TextMouthProductionTests/LogContentPolicyTests.swift -->

- Transcripts:
  - TRANSCRIPT_FILE, for a transcript.json that can't be used, preserved beside itself;
  - TRANSCRIPT_STALE, for a transcript whose audio changed since it was made;
  - TRANSCRIPT_TEXT_REBUILT, for content.md and its layer written again from transcript.json;
  - TRANSCRIPT_CLEANUP_RULES, for the user's copy of the cleanup rules, only in the cloud or preserved beside itself;
  - TRANSCRIPT_CLEANED_UP, for a cleanup saved, with its counts and its rules' source and version;
  - TRANSCRIPT_CLEANUP_UNDONE, for a cleanup undone;
  - and TRANSCRIPTION_STARTED, TRANSCRIPTION_FINISHED, TRANSCRIPTION_CANCELLED, and TRANSCRIPTION_FAILED, for a transcription's start and its end.

  None quotes the transcript or a rule.
- Recordings:
  - RECORDING_STARTED, RECORDING_START_FAILED, RECORDING_STOPPED, RECORDING_STOP_FAILED, RECORDING_INTERRUPTED, RECORDING_CAPTURE_FAILED, and RECORDING_FORMAT_FALLBACK, for a take starting, stopping, or ending on its own, and a capture in the microphone's own format;
  - RECORDING_SAVED, for a take saved as a book;
  - RECORDING_TAKES_RECOVERED, for the takes left in the Recordings folder that launch found;
  - and RECORDING_WINDOW_REFUSED, for a Record window asked for before there was a library to save into.
- Audio editing:
  - AUDIO_EDITS_FILE, for an edit history that can't be used, preserved beside itself, which never quotes the history, since it can hold chapter titles;
  - AUDIO_EDITS_SAVED, for edits saved into a book's audio;
  - AUDIO_ORIGINALS_SWEPT and AUDIO_ORIGINAL_REMOVAL_FAILED, for the originals of recordings and edited audiobooks the policy deleted or couldn't;
  - AUDIO_FILTERS_FILE, for the filter presets' file, unusable or only in the cloud;
  - AUDIO_EDIT_CACHES_SWEPT, for the folders a crash, or a quit with editors open, left in this Mac's audio editing caches, removed at launch;
  - AUDIO_MARKERS_NOT_WRITTEN, for a render whose WAVE, AIFF, or CAF file could not be given its chapter markers, naming the file and an error, never a folder;
  - AUDIO_CHAPTERS_NOT_KEPT, for a converted .m4a whose source's chapters could not be written into it, naming the file and an error's domain and code;
  - and AUDIO_EDITOR, for a book the editor couldn't open, a save or an export it couldn't finish, and markers it couldn't keep, naming an error by its kind, never by a path.

### Log tags: feeds
<!-- id: log-tags-feeds; keys: FEED_SUBSCRIBED, FEED_DOWNLOAD_STARTED, FEED_ITEM_PLAYED, FEED_RULE_DOWNLOADS, FEED_DELETED, Delete Feed; src: TextMouth/Services/Feeds/FeedCenter.swift, TextMouth/Services/Feeds/FeedCenter+DeleteFeed.swift, TextMouth/Services/Feeds/FeedDownloadManager.swift, TextMouth/Services/Feeds/FeedIndex.swift, TextMouth/Services/Feeds/FeedNewestRule.swift, TextMouth/Services/Feeds/FeedRefresher.swift, TextMouthProductionTests/LogContentPolicyTests.swift -->

- Feeds, every one pinned:
  - FEED_RECORD_IN_CLOUD, FEED_RECORD_SAVE_FAILED, FEED_RECORD_UNREADABLE, FEED_FETCH_STATE_SAVE_FAILED, and FEED_ITEM_POLICY_MOVED, for the records, this Mac's fetch details, and the move to the List and download choice;
  - FEED_SUBSCRIBED, FEED_UNSUBSCRIBED, FEED_RESUBSCRIBED, FEED_REFRESHED, FEED_REFRESH_FAILED, FEED_MOVED, and FEED_PARSE_REPAIRED, for subscribing, unsubscribing, and refreshing;
  - FEED_DOWNLOAD_STARTED, FEED_DOWNLOAD_FINISHED, FEED_DOWNLOAD_FAILED, FEED_DOWNLOAD_CANCELLED, FEED_DOWNLOADS_CANCELLED, FEED_DOWNLOAD_WAITING, FEED_DOWNLOAD_RESTORED, FEED_DOWNLOAD_DISCARDED, FEED_DOWNLOAD_LEFT, and FEED_ARTICLE_TEXT_KEPT, for downloads;
  - FEED_PACKAGE_SWAP_FAILED, FEED_PACKAGE_PUT_BACK, FEED_PACKAGE_SET_ASIDE_REMOVED, and FEED_PACKAGE_SET_ASIDE_LEFT, for the kept package a download replaces;
  - FEED_ITEM_PLAYED, FEED_DOWNLOAD_DELETED, FEED_DOWNLOAD_DELETE_FAILED, FEED_DOWNLOAD_DELETE_REFUSED, FEED_DOWNLOAD_CACHE_LEFT, FEED_DOWNLOAD_HELD_ASIDE,
  -  FEED_HELD_ASIDE_SWEPT, FEED_HELD_ASIDE_LEFT, FEED_DOWNLOAD_FORGOTTEN, FEED_LIBRARY_BOOK_GONE, FEED_SWEEP_LEFT_IN_CLOUD, FEED_SWEEP_PUT_OFF, FEED_KEPT_PACKAGE_DELETE_FAILED, and FEED_KEPT_PACKAGES_PUT_OFF, for played items and the removal of downloads and kept packages;
  - FEED_RULE_DOWNLOADS, FEED_RULE_LEFT_IN_CLOUD, and FEED_RULE_PUT_OFF, for the newest-N rule;
  - FEED_INDEX, FEED_INDEX_IN_CLOUD, FEED_INDEX_NEWER, and FEED_INDEX_UNREADABLE, for the feeds' own indexes;
  - FEED_DOWNLOADS_MOVE, FEED_DOWNLOADS_MOVED, FEED_DOWNLOAD_MOVE_FAILED, FEED_DOWNLOAD_MOVE_REFUSED, FEED_ITEMS_KEPT, FEED_ITEMS_DOWNLOADED_AGAIN,
  -  FEED_ITEM_MOVED_TO_LIBRARY, FEED_MOVE_TO_LIBRARY_FAILED, FEED_MOVE_TO_LIBRARY_PUT_OFF, FEED_DOWNLOADS_RETURN, FEED_DOWNLOADS_RETURNED, FEED_DOWNLOAD_RETURN_FAILED, FEED_RECORD_ABSENT, and FEED_RECORD_BACK, for moves of downloads into their feeds, into the library, and back from a gone feed;
  - and FEED_DELETED, FEED_DELETE_PUT_OFF, FEED_DELETE_STOPPED, FEED_DELETE_REFUSED, FEED_DELETE_FOLDER_LEFT, and FEED_DELETE_FOLDER_KEPT, for Delete Feed… (FR14).

### Log tags: export, edited text, nesting, search, and encodings
<!-- id: log-tags-export-text-encodings; keys: BOOK_EXPORT, TEXT_EDIT_ADOPTED, MOVE_SHEET_SHOWN, MARKDOWN_NESTING_KEPT_RAW, LIBRARY_SEARCH_PREPARATION, TEXT_ENCODING_CHANGED; src: TextMouth/Services/BookExportService.swift, TextMouth/Services/BookTextEditing.swift, TextMouth/Parsers/TextFileDecoder.swift, TextMouthProductionTests/LogContentPolicyTests.swift -->

- Export and edited text:
  - BOOK_EXPORT and BOOK_EXPORT_FAILED, for how an export ended and each file it couldn't write;
  - TEXT_EDIT_ADOPTED, TEXT_EDIT_REFUSED, TEXT_EDIT_SOURCE_CHANGED, and TEXT_EDIT_FAILED, for an edit taken, refused, left because the book's own file or its transcript changed too, or one that couldn't be read or committed;
  - TEXT_EDIT_HELD, for a rebuild refused over an edit not taken;
  - and TEXT_EDIT_KEPT, for text kept aside before a rebuild, or a transcript's text written again, replaced it.
- The Move sheet: MOVE_SHEET_SHOWN, each time the Move to Folder or Move to Library sheet appears (MoveFolderSheet.shownLine(command:places:items:)), with the command, how many places it lists, and how many items it moves, never a title or a path.
- Markdown nesting: MARKDOWN_NESTING_KEPT_RAW, once for each parse of a content.md in which chapters nest too deeply to read and are kept as written, with counts only ("2 of 40 chapters nest too deeply to read and are kept as written").
  An import of such a file is refused with the guard's sentence and logs only the import's own failure line (see Markdown parsed from content.md, in [Text caches](text-caches.md)).
- Search Library: LIBRARY_SEARCH_PREPARATION, one line each time a background pass of the search texts ends (LibrarySearchPreparer.logPassEnded),
  - saying how it ended
  - and counting the books it was given, already prepared, prepared, in the cloud, without text, and unreadable, with its seconds,
  - and naming no book or title (see Search Library's search texts, in [Text caches](text-caches-rereads-edits.md)).
- Text encodings (FMT16):
  - TEXT_ENCODING_GUESS, for a plain text, Markdown, or HTML file read in the encoding an import guessed, with the file's name and the encoding's identifier, once for the import;
  - and TEXT_ENCODING_FALLBACK, for a file read as Windows-1252 because nothing named its encoding, on every such read.

  Neither quotes the file's text (Text files in other encodings, in [Imports](imports-text-encodings.md)).
  A book read again in another encoding from Book Information (encodingchoice) writes TEXT_ENCODING_CHANGED, with:
  - the book's title,
  - how it was read ("read again as koi8-r, chosen", "read again automatically, as windows-1251, guessed", or "read again automatically, with no encoding to record"),
  - and the copy of its earlier text that was kept, if any.

  The same tag names a content.md that could not be put back after a failed re-read.
  A braille book read again with other braille file characters writes BRAILLE_FILE_CODE_CHANGED and with another braille code BRAILLE_TABLE_CHANGED (the table's stored value, as "BRAILLE_TABLE_CHANGED: Ledger: read again with en-ueb-g1.ctb", and the kept copy, if any).
  The two in that order for a re-read of both.
  It quotes none of the book's text (Reading a book again in another encoding, in [Text caches](text-caches-rereads-edits.md)).
