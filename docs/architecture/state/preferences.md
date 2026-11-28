# Preferences
<!-- id: preferences; keys: settings, prefs, defaults, options, config; src: TextMouth/Models/StoredPreference.swift, TextMouth/Models/SettingsPolicy.swift, TextMouth/Services/ConfigService.swift -->

Part of [TextMouth's architecture](../../../ARCHITECTURE.md).

## Preferences store
<!-- id: preferences-store; keys: UserDefaults, settings key, prefs, defaults; src: TextMouth/Models/StoredPreference.swift, TextMouth/App/TextMouthRuntime.swift, TextMouth/ViewModels/SettingsViewModel.swift -->

The preferences store.

### Preference owners: settings and services
<!-- id: preference-owners-settings-services; keys: owner of a setting, sounds, ffmpeg, microphone, sleep timer, session ID; src: TextMouth/App/TextMouthRuntime.swift, TextMouth/ViewModels/SettingsViewModel.swift, TextMouth/Services/SoundEffectService.swift, TextMouth/Services/TextSubstitutionService.swift, TextMouth/Services/KeyboardShortcutManager.swift, TextMouth/Services/SleepTimerService.swift, TextMouth/Services/TextMouthPaths.swift, TextMouth/Services/DataDirectoryAvailability.swift, TextMouth/Services/LibrarySessionLease.swift, TextMouth/ViewModels/LibraryViewModel+FeedDownloadReturn.swift, TextMouth/Services/RecordingInputDevices.swift, TextMouth/Services/RecordingPreferences.swift, TextMouth/Models/AudioOriginalPolicy.swift, TextMouth/Services/AudioEditing/FFmpeg.swift, TextMouth/Services/AudioEditing/AudioEditingPreferences.swift, TextMouth/Services/AudioEditing/AudioEditorPreferences.swift, TextMouth/Services/DiagnosticLog.swift -->

- Owner: TextMouthRuntime.current.preferences, which is UserDefaults.standard in the app and a sandboxed store under hosted tests.
  Each preference has one owner that reads and writes it:
  - SettingsViewModel: the Voice, Playback, and Miscellaneous settings, through properties backed by @AppStorage.
  - SoundEffectService: whether sounds play, their volume, and each event's sound.
  - TextSubstitutionService: whether the substitution rules apply, and the repeated-symbol style, threshold, and symbol set (repeatedSymbolStyle, repeatedSymbolThreshold, and repeatedSymbolSet), which that switch does not affect.
    It also owns the rules, kept in substitutions.json.
  - KeyboardShortcutManager: the record of the shortcuts the user edited, under keyboardShortcutEdits, from which every action's keys in force follow.
    No key is in force for two actions in one kind of window (ShortcutScope: every window but an audio editor's, Library windows, reader windows, the audio editor's windows, or the Record window; [Preferences: keyboard shortcuts](preferences-shortcuts.md)).
    The manager also holds the double-press time, under shortcutDoublePressSeconds.
    The whole map of every action's keys that earlier releases saved, under customKeyboardBindings, is read once, at the first launch without a record, and never written again.
  - SleepTimerService: the last timer started, under sleepTimer.lastUsedDuration.
  - TextMouthPaths and the library model, through DataDirectoryPreferences: the data directory's location, a bookmark of its folder, and the identity of the library expected there, under textMouthDataDirectory, textMouthDataDirectoryBookmark, and textMouthLibraryIdentity.
  - LibrarySessionLease: this Mac's ID, which names its file in a library's Sessions folder and, in a library in the cloud, the notes a launch leaves in a feed's folder when it finds the feed's record missing (FeedRecordAbsence), under textMouthSessionMacID.
  - RecordingInputChoice: the microphone the Record window and the audio editor's punch-ins record from, under recordingInputDeviceID, empty until one is chosen.
  - RecordingLevelAnnouncements (Services/RecordingPreferences.swift):
    - whether the Record window announces the level while recording, under recordingAnnouncesLevel, off until turned on, and
    - how many seconds apart, under recordingLevelAnnouncementSeconds (SettingsPolicy.recordingLevelAnnouncementSeconds: 5 to 60, 10 until changed), read as the Record window opens and written as they change.
  - AudioOriginalPolicy: what happens to the original audio of recordings and edited audiobooks, under recordingOriginalPolicy and recordingOriginalDays, the names it had when only recordings kept an original, which Storage settings' Audio Editing group changes.
  - AudioFilterEngine.usePreference: whether an installed ffmpeg, when TextMouth finds one, runs the audio editor's filters, and writes MP3 should the LAME built in fail to start, under useInstalledFFmpeg, on until turned off, which the same group changes.
    SettingsViewModel mirrors the Record window's keys (RecordingPreferences.keys) and audio editing's (AudioEditingPreferences.keys) in config.json.
  - AudioEditorPreferences: whether the editor's Apply Filter previews a filter before applying it, and whether the editor plays half a second at the cursor after each move, under audioEditorPreviewsFilters and audioEditorPlaysAfterMoves, both on until turned off, which the same group changes.
    They are among AudioEditingPreferences.keys, so config.json mirrors them.
  - DiagnosticLog.TraceSwitch: the hidden trace-logging switch, diagnosticTraceLogging.

### Log, export, and braille preferences
<!-- id: log-export-braille-preferences; keys: braille table, BRF, log folder, Export button, UEB, brailleTable; src: TextMouth/Models/LogLocation.swift, TextMouth/ViewModels/BookExportModel.swift, TextMouth/Models/BrailleTableCatalog.swift, TextMouth/Models/BrailleTableOrigin.swift, TextMouth/Parsers/BrailleFileCode.swift, TextMouth/Models/Book.swift, TextMouth/Views/Settings/BrailleSettingsView.swift, TextMouth/Views/Export/BrailleExportOptionsView.swift, TextMouth/ViewModels/SettingsViewModel.swift -->

- The log writer, through LogLocation.preference: where the logs are written, logLocation ("dataDirectory" or "machine"), which it reads for every line.
  Storage settings change it through SettingsViewModel.logLocation, and config.json mirrors it.
- Export, through BookExportPreferences.showInReaderToolbar: whether reader toolbars show an Export button, under showExportInReaderToolbar.
  Playback settings change it through SettingsViewModel.showExportInReaderToolbar, as Storage settings change logLocation, and config.json mirrors it.
- Braille, through BraillePreferences.table (Models/BrailleTableCatalog.swift): the braille table braille files are read and written with, by its stored value (BrailleTableSource: a bundled table's file name, or "mac:" and the file name of one of this Mac's tables), under brailleTable.
  It reads as the stored value when that is a table of the app's own pack, a "mac:" name, or, on the Mac, a bare file name of a VoiceOver file whose header makes a table, such as the value an iPhone stores (BrailleTableCatalog.storableValue(_:), which reads that one header and never the folder).
  A table that only writes braille is kept too, and a platform never rewrites a value it reads (see [Braille table pack](braille-table-pack.md#stored-values-on-each-platform)).
  A Mac table is kept even when this Mac no longer has it, so that an import or an export refuses it by name.
  Otherwise it reads as BrailleTableCatalog.defaultTableID, "en-ueb-g2.ctb", Unified English Braille contracted.
  Reading it never reads the Mac's folder.
  The Braille tab (BrailleSettingsView, whose three pop-ups, language, code, and contraction, are BrailleTablePickers, the view Export's braille options share) changes it through SettingsViewModel.brailleTable, which writes only an offered table's value and only a change.
  The pop-ups set a Mac table only once its check passes.
  Imports and braille exports read it through BraillePreferences.importTable(), which a hosted test overrides with the task-local tableForImports (see Braille files, in [Imports](imports-braille.md)).
  The file config.json mirrors it as brailleTable, an empty or invalid name there leaving the table as it is, and a "mac:" name taken as it is.
  A bare name this platform lacks, such as an iPhone's, leaves the table as it is too, and the file keeps the name until the table is changed on this device (SettingsViewModel.brailleTableHeldFromFile; see [Braille table pack](braille-table-pack.md#stored-values-on-each-platform)).
  BraillePreferences.fileCode, under brailleFileCode, is the braille file characters an import reads a BRF or BRL file with, by the code's id.
  It reads as the stored id when that is one of BrailleFileCode.importChoices (ascii-na or ascii-eurobraille) and as ascii-na otherwise.
  So a stored unicode or unknown id falls back to North American Braille ASCII, since Unicode braille patterns are recognized by a file's bytes and never taken from the setting.
  The Braille tab's fourth pop-up changes it through SettingsViewModel.brailleFileCode.
  Export's braille options start a BRF from it (BraillePreferences.importFileCode(), which a hosted test overrides with the task-local fileCodeForImports).
  The file config.json mirrors it as brailleFileCode, an empty, Unicode, or unknown id there leaving the choice as it is.
  A book's own code is its row's (Book.brailleFileCode), never this preference.
  A book's own table is its row's (Book.brailleTable), never this preference.
  BraillePreferences.guessesTable, under brailleGuessesTable, is whether an import may read a BRF or BRL clearly written in English Braille, American Edition with that code's table in place of a contracted UEB one (BrailleTableGuess, in [Imports](imports-braille-tables.md)).
  It is a flag on by default, changed by the Braille tab's switch through SettingsViewModel.guessesBrailleTable.
  It is read at an import through BraillePreferences.importGuessesTable() (which a hosted test overrides with the task-local guessesTableForImports).
  It is not mirrored in config.json.

### Editor, library, feed, and transcription preferences
<!-- id: editor-library-feed-transcription; keys: Edit Text, feed settings, library views, leading articles, transcription language, Library tab; src: TextMouth/Platform/macOS/Services/BookTextEditor.swift, TextMouth/ViewModels/LibraryViewModel+Migration.swift, TextMouth/Models/FeedSettings.swift, TextMouth/Models/FeedItemPolicy.swift, TextMouth/Views/Feeds/FeedSettingsView.swift, TextMouth/Views/Feeds/FeedItemPolicyControls.swift, TextMouth/Views/Feeds/FeedThresholdControl.swift, TextMouth/Models/TranscriptionLanguage.swift, TextMouth/Models/TranscriptionPreferences.swift, TextMouth/Views/Transcription/TranscriptionSettingsSection.swift, TextMouth/Models/LibraryViewDefinitionStore.swift, TextMouth/Models/LibraryViewDefinitionList.swift, TextMouth/Models/LibraryViewDefinition.swift, TextMouth/Views/Settings/LibraryViewsSettingsView.swift, TextMouth/Models/LeadingArticles.swift, TextMouth/Models/LeadingArticleWording.swift, TextMouth/Views/Settings/LeadingArticlesSettingsSection.swift, TextMouthProductionTests/HostedTestIsolationSupport.swift -->

- BookTextEditor: whether Edit Text has explained itself on this Mac, under editTextExplained, which stays out of config.json.
- The library model: whether this Mac has made the one-time move of finished books to their ends, under library.finishedBooksAtEndVersion (LibraryViewModel.finishedBooksAtEndKey, P07), which stays out of config.json too (ConfigService.AppConfig.Portability.localStoreKeys, since P08).
- FeedSettings: the seven feed settings (feedRefreshAtLaunch, feedRefreshIntervalHours, the List and download choice under feedItems and feedNewestCount, read together as itemPolicy, feedDeleteDownloadsDaysAfterPlayed, feedRefreshAlert, and feedNotifications).
  The feed engine reads them, the Feeds tab of Settings (FeedSettingsView) changes them through SettingsViewModel.feedSettings, and config.json mirrors them.
  The two settings the choice retired, feedKeepEntries and feedAutoDownload, stay in the store as they were, read only by the move to the choice (FeedSettings.moveToItemPolicyIfNeeded(in:)).
  They are listed as retired (FeedSettings.retiredPreferenceKeys, in the config.json mirror's retiredStoreKeys).
  FeedItemPolicyControls (Views/Feeds/FeedItemPolicyControls.swift) draws the List and download choice here and in Feed Info: a menu-style Picker labelled "List and download", whose titles and hints come from FeedWording.itemPolicyTitle and itemPolicyHint, with the feed's ItemNoun in Feed Info.
  Its number goes through FeedNumberField, the field and stepper every feed number shares, disabled while the choice downloads by hand.
  FeedThresholdControl draws the two that can be off, refreshing only at launch and when asked and never deleting a played download, the second in Feed Info too, each a FeedNumberField with a checkbox for its off value.
- TranscriptionLanguage: the language transcription uses, under transcriptionLocale (TranscriptionLanguage.preference), which reads a value that can't be a language identifier, or none, as this Mac's English.
  Playback settings' Transcription group (TranscriptionSettingsSection) changes it through SettingsViewModel.transcriptionLanguage, and config.json mirrors it.
- TranscriptionPreferences.offerAfterImport: whether an import offers to transcribe each audiobook it adds, under offerTranscriptionAfterImport, off until chosen, which the same group changes through SettingsViewModel.offerTranscriptionAfterImport; config.json mirrors it.
- LibraryViewDefinitionStore (Models/LibraryViewDefinitionStore.swift, on the main actor, an ObservableObject; LibraryViewDefinitionStore.shared is the one on the app's preferences).
  It holds the Library window's views, in order, under libraryViews (LibraryViewDefinitionList.fileKey), as one JSON array of the entries config.json holds, written as data with sorted keys, so that an older TextMouth that drops the key from config.json loses nothing here.
  LibraryViewDefinitionStore.preference, a `StoredPreference<LibraryViewDefinitionList>`, reads it as the shipped list while none is saved or what is saved is not a JSON array, and reading it logs nothing.
  The file config.json mirrors it as libraryViews (ConfigService.AppConfig.libraryViews, an optional array of JSONValue, listed in ConfigService.AppConfig.Portability.mirrored and among SettingsViewModel's service preference keys).
  SettingsViewModel writes it after each change and applies it at launch and on an outside edit, the list reading each entry on its own and logging its repairs as config.json's.
  An empty list or none leaves the views alone.
  The Library tab of Settings (LibraryViewsSettingsView) and the Library windows (ContentView and LibraryView, which observe the store) read it; the views' sorts are not in it (see [The library index](library-index.md)).
- LeadingArticles (Models/LeadingArticles.swift): what a title's leading article does in the Library's lists, under leadingArticles, "partOfTitle", "ignoredWhenTyping", or "ignoredWhenTypingAndSorting" ([The library index](library-index.md) for what each does).
  LeadingArticles.preference is a `StoredPreference<LeadingArticles>` written as the case's raw value and read through SettingsPolicy.leadingArticles, an EnumSettingRule whose default is .partOfTitle.
  So a missing or unsupported value reads as the default and nothing changes until the listener chooses.
  The Library tab's Titles section (LeadingArticlesSettingsSection, whose words are LeadingArticleWording's, in Views/Settings/LibraryViewsSettingsView.swift's tab) changes it through SettingsViewModel.leadingArticles, which writes only a change.
  The Library windows read it from the store each time they draw or sort (LibraryViewModel.leadingArticles, from TextMouthRuntime.current.preferences, always .partOfTitle on the iPhone), so a change reaches every open window at once.
  The file config.json mirrors it as leadingArticles (ConfigService.AppConfig.leadingArticles, a String, in Portability.mirrored).
  SettingsViewModel.syncToConfig writes the raw value, applying the file adopts SettingsPolicy.leadingArticles.requestedValue(fromConfig:), and an empty, unsupported, or differently cased name leaves the choice as it is.
  SettingsViewModel lists its key among the service preference keys it observes and announces (shownServicePreferenceKeys), so the pop-up follows a change made in config.json.
  The hosted tests' isolation check (HostedTestIsolationSupport.textMouthKeys) lists the key among those whose value in the user's real store it compares before and after a run.

### Who writes and observes preferences
<!-- id: who-writes-observes-preferences; keys: StoredPreference, key-value observing, KVO, revision, speed pitch voice; src: TextMouth/Models/StoredPreference.swift, TextMouth/ViewModels/SettingsViewModel.swift, TextMouth/Services/SpeechService.swift, TextMouth/Models/SettingsPolicy.swift -->

- Who may write it: each preference's owner, through its StoredPreference definition (the key, how the value is read, and how it is written, in one place) or its @AppStorage property.
  SettingsViewModel also applies config.json's values, using the services' own definitions for theirs.
- How others observe it: SettingsViewModel publishes its own changes and increments a revision that open playback bars watch.
  PreferenceObserver (key-value observing) tells SettingsViewModel when a service-owned key changes, so config.json follows.
  A change of logLocation, of showExportInReaderToolbar, of a feed setting, or of a transcription setting is also announced, so the controls showing it, and the readers' toolbars, follow it.
  SpeechService reads the speed, pitch, and voice from its store through SettingsPolicy.

## The config.json mirror
<!-- id: config-json-mirror; keys: config file, settings file, save delay, file watcher, outside edit, dataDirectoryPath; src: TextMouth/Services/ConfigService.swift, TextMouth/ViewModels/SettingsViewModel.swift, TextMouth/Models/LenientFields.swift, TextMouth/App/UnsavedChangesTermination.swift, TextMouth/Services/PersistenceFailureCenter.swift, TextMouth/Services/DataDirectoryAvailability.swift, TextMouth/ViewModels/LibraryViewModel.swift, TextMouth/Services/FileEventWatcher.swift, TextMouth/Platform/macOS/Services/PackageFileEditing.swift, TextMouth/Services/InterfaceTextOverrides.swift -->

The config.json mirror.

- Owner: ConfigService.shared, on the main actor.
  Its config property holds the file's values.
  While TextMouth runs, the preferences store is the source of truth and config.json follows it; at launch, the file is applied first, because it can change while TextMouth is closed.
- Who may write it: SettingsViewModel, after each settings change (syncToConfig) and when reconciling at launch, and the Storage settings for the three choices only the file holds.
  A change updates ConfigService.config at once, and scheduleSave() writes the file once changes pause for 250 ms (defaultSaveDelay), so a slider dragged through its steps writes it once.
  ConfigService.flushScheduledSave() writes a waiting save when TextMouth quits (UnsavedChangesTerminationGuard.flushPendingWrites()) and before the data directory moves, and in the hosted tests as each test ends (ConfigSaveFlush).
  ConfigService.saveToDisk, which writes at once, first merges any outside edit not yet handled, writes nothing when the file already holds the same bytes, and reports a failed save to PersistenceFailureCenter.
  Every read leaves dataless files in the cloud: a config.json only in the cloud is neither applied at launch nor written over, with one line in the debug log, until a save finds it on this Mac and merges it as an outside edit.
  While the data directory is unavailable, ConfigService neither reads, writes, nor watches the file; dataDirectoryBecameAvailable then merges it as an outside edit, keeping each setting changed meanwhile, saves it, and watches it again.
  A top-level key this version does not know is read into ConfigService.AppConfig's unknownKeys and written back ([Keys a later TextMouth adds](package-records.md)).
- How others observe it: ConfigService's FileEventWatcher notices saved edits, ConfigService tells them from TextMouth's own saves by their bytes, and it publishes each once through externalEdits, which SettingsViewModel.applyConfigChanges applies.
  FileEventWatcher (Services/FileEventWatcher.swift) is the app's one file watcher: ConfigService watches config.json, the editor of a book's text watches content.md and manifest.json (PackageFileEditing), and InterfaceTextOverrides watches interface_text.json, each with a watcher of its own.
  - It listens with a DispatchSource on a descriptor opened for events only (O_EVTONLY), also O_NONBLOCK, so that a FIFO by the file's name cannot hold the main thread, and O_CLOEXEC, so that no helper program inherits it.
  - It opens only a regular file: a FIFO, a device, or a folder by the name counts as a missing file.
  - It follows a save that replaces the file, looks again after each of its retry delays (50 to 800 ms) for a file that went missing, and calls settled once, with the events combined, after a quiet period; config.json listens for whole-file events, and an edited text for every kind of change.
  - A watcher's source is held by a SourceOwner that cancels it when the watcher is dropped, so a watcher released without stop() still closes its descriptor.
  A changed dataDirectoryPath posts dataDirectoryChangeRequested, and LibraryViewModel moves the data directory, unless DataDirectoryRequest finds the folder missing on this Mac or already holding a TextMouth library, as another Mac's path in a library in the cloud would.
  That edit is ignored with one CONFIG_FILE line.

## The policy table
<!-- id: policy-table; keys: validation, setting range, default value, clamp, retired keys, Portability; src: TextMouth/Models/SettingsPolicy.swift, TextMouth/Models/LenientFields.swift, TextMouth/Services/ConfigService.swift, TextMouth/Models/FeedSettings.swift -->

The policy table.

- Owner: SettingsPolicy, the single table of validated preferences.
  Each rule (NumericSettingRule, EnumSettingRule, KeyedSettingRule, ThresholdSettingRule, WholeNumberSettingRule, or CharacterSetSettingRule) states a key, the supported range, cases, or characters, the default, and, for speed and pitch, the value meaning "not chosen yet".
  Or, for a threshold, it states the value at or below which it is off: -1 for the repeated-symbol threshold, for the feeds' days, and for their retired kept entries, which only the move to the List and download choice reads, and 0 for the feeds' refresh interval.
  A WholeNumberSettingRule has no off value and moves anything outside its range to the nearest bound, as the List and download choice's number does (1 to 2,000).
- Who may write it: no one while the app runs; it is a static table whose ranges match the Settings controls.
- How others observe it: decoding config.json (LenientFields), applying it, reading @AppStorage values, services reading the store directly, and decoding per-book speed and pitch from bookInfo.json and library.json all pass values through it.
  ConfigService.AppConfig.Portability lists which preferences config.json mirrors, which only it holds, which stay on this Mac, and which an earlier release wrote and none writes now.
  The last are retiredStoreKeys: customKeyboardBindings, and FeedSettings.retiredPreferenceKeys, feedKeepEntries and feedAutoDownload.
  The tests take their expectations from those lists.
