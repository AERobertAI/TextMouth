import Foundation
import Combine

/// Mirrors the app's settings in config.json, in the data directory, where
/// they can be read and edited by hand.
///
/// The preferences store is the source of truth while TextMouth runs, and
/// config.json follows it: each settings change saves the file. At launch
/// the file's values are applied first, because the file is where settings
/// can change while TextMouth is closed. While TextMouth runs, a watcher
/// notices edits saved from outside, tells them from TextMouth's own saves
/// by their bytes rather than by timing, and publishes each once through
/// `externalEdits`. Everything here runs on the main actor, which owns all
/// of the watcher's state.
@MainActor
final class ConfigService: ObservableObject {
    /// The service for the data directory's config.json.
    static let shared = ConfigService()

    /// The settings as config.json holds them. Screens that manage a field of
    /// their own change it here and call `saveToDisk()`; the settings model
    /// keeps the fields it mirrors in step with the preferences.
    @Published var config: AppConfig = AppConfig()

    /// Publishes each edit of config.json made outside TextMouth, once, after
    /// `config` holds it. Delivery is synchronous on the main actor, so a
    /// subscriber applies edits in order and never receives TextMouth's own
    /// saves. The settings model applies these to the preferences.
    let externalEdits = PassthroughSubject<AppConfig, Never>()

    // MARK: - The File

    /// What config.json held when this service was created.
    enum LoadedFile: Equatable {
        /// There was no file: the first launch, or the file was deleted.
        case missing
        /// The file decoded, and `config` holds its values.
        case decoded
        /// The file exists but could not be read or decoded. It stays as it
        /// is, so whoever edited it can correct it.
        case unreadable
    }

    /// What config.json held when this service was created.
    private(set) var loadedFile: LoadedFile = .missing

    /// Whether config.json held a decodable file when this service was
    /// created; `config` then holds that file's values, which launch applies
    /// to the preferences. A file that leaves speed unset still counts, since
    /// it can hold every other setting.
    var hasExistingConfig: Bool { loadedFile == .decoded }

    /// The file to mirror in place of the data directory's, for tests.
    private let customFileURL: URL?

    /// config.json: the file this service was created for, or else the one
    /// in the data directory in use, which moves when the library does.
    var fileURL: URL { customFileURL ?? TextMouthPaths.configFile }

    /// Whether config.json can't be used now (FR02): this service follows
    /// the data directory's file, and the library model found the data
    /// directory unavailable. Nothing is read from it or written into it then.
    private var isFileUnavailable: Bool {
        customFileURL == nil && TextMouthPaths.isDataDirectoryUnavailable
    }

    /// Whether config.json was left unread or unsaved because the data
    /// directory was unavailable, so it is reconciled once it is back
    /// (`dataDirectoryBecameAvailable()`).
    private var skippedFileWhileUnavailable = false

    /// Whether config.json was found only in the cloud (FR02), so it was
    /// neither read nor written, since reading it would download it first
    /// and wait on the network. Said once in the debug log until the file is
    /// on this Mac again; every save until then tries again.
    private var isFileInCloud = false

    // MARK: - Coalesced Saves

    /// How long a save asked for with `scheduleSave()` waits for the next
    /// change (PERF17).
    private let saveDelay: Duration

    /// The save delay TextMouth uses: long enough to span the steps of a
    /// slider being dragged or a stepper being held, short enough that the
    /// file follows a change within a moment.
    nonisolated static let defaultSaveDelay: Duration = .milliseconds(250)

    /// The save waiting for `saveDelay` to pass, if any.
    private var scheduledSave: Task<Void, Never>?

    /// Hears when the data directory is available again.
    private var availabilitySubscription: AnyCancellable?

    /// The file-system calls this service makes, replaceable so tests can
    /// count them.
    struct FileOperations {
        /// Replaces the file at a URL with new contents in one atomic step.
        var write: @MainActor (_ data: Data, _ url: URL) throws -> Void
        /// Opens a path for event notification only, returning a descriptor,
        /// or -1 when it cannot be opened.
        var openForEvents: @MainActor (_ path: String) -> Int32
        /// Closes a descriptor that `openForEvents` returned.
        var close: @MainActor (_ descriptor: Int32) -> Void
        /// Reads the file at a URL with dataless files left in the cloud
        /// (PERF17): a file only in the cloud throws the refusal
        /// `DatalessFiles.isDownloadRefusal` recognizes instead of being
        /// downloaded. Tests refuse reads with one of their own, since only
        /// a sync service makes dataless files.
        var read: @MainActor (_ url: URL) throws -> Data = { url in
            try DatalessFiles.withoutDownloading { try Data(contentsOf: url) }
        }

        /// The calls the app makes.
        static var system: FileOperations {
            FileOperations(
                write: { data, url in try data.write(to: url, options: .atomic) },
                openForEvents: { path in Darwin.open(path, O_EVTONLY) },
                close: { descriptor in _ = Darwin.close(descriptor) }
            )
        }
    }

    /// The file-system calls in use.
    private let fileOperations: FileOperations

    // MARK: - Agreement With the File

    /// config.json's bytes as this process last wrote, loaded, or examined
    /// them. A file event that finds these bytes brings nothing new: it is
    /// TextMouth's own save, or an edit already applied or rejected. This
    /// replaces a half-second window after each save during which every
    /// event, an editor's included, used to be ignored.
    private var lastHandledContents: Data?

    /// The settings this process and config.json last agreed on: the ones it
    /// last loaded, wrote, or applied. Saving merges an edit it finds on disk
    /// against this, to tell the fields TextMouth changed since from the
    /// fields the edit changed. Nil until a file was decoded or written.
    private var lastSyncedConfig: AppConfig?

    // MARK: - Watcher State

    /// Whether the watcher is on: from `startWatching()` until `shutdown()`.
    private var isWatching = false
    /// How long a burst of file events must stay quiet before the file is
    /// read.
    private let coalescingDelay: Duration
    /// The events received since the file was last checked, combined.
    private var pendingEvents: DispatchSource.FileSystemEvent = []
    /// The check that runs once the current burst of events settles.
    private var pendingCheck: Task<Void, Never>?

    /// The file the watcher listens to.
    private struct WatchedFile {
        /// Which file it is, whatever path later leads to it.
        let identity: FileIdentity
        /// Delivers its events; cancelling it closes its descriptor.
        let source: DispatchSourceFileSystemObject
    }

    /// The file the watcher listens to, if any.
    private var watchedFile: WatchedFile?
    /// The search for a file that went missing, while it goes on.
    private var rearmRetry: Task<Void, Never>?

    /// The events that matter: a write in place, and the rename, deletion,
    /// or revocation (its volume was unmounted) that ends the watched file's
    /// time at the path.
    private static let watchedEvents: DispatchSource.FileSystemEvent = [.write, .rename, .delete, .revoke]

    /// The pauses before each look for a missing file: short at first, for an
    /// editor that puts the new file in place a moment after removing the old
    /// one, and longer at the end, for a slow volume. About 1.5 seconds in all.
    private static let rearmRetryDelays: [Duration] = [50, 100, 200, 400, 800].map { .milliseconds($0) }

    // MARK: - Watcher Decision

    /// What the watcher does about a batch of file events.
    struct WatcherActions: Equatable {
        /// Watch the file now at the path: the watched one was renamed,
        /// deleted, or revoked, as when an atomic save renames a new file
        /// over it.
        let rearm: Bool
        /// Decode the file and apply it: it holds bytes this process has
        /// neither written nor seen.
        let reload: Bool
    }

    /// The watcher's decision for `event`, given config.json's bytes now (nil
    /// when there is no readable file) and the bytes this process last wrote,
    /// loaded, or examined.
    ///
    /// Comparing contents rather than the time since the last save is what
    /// tells TextMouth's own writes from anyone else's: an edit saved moments
    /// after TextMouth saved is still applied, and TextMouth's own save never
    /// is, however late its events arrive. Atomic saves replace the watched
    /// file, TextMouth's included, so the event alone decides whether to
    /// follow the file.
    nonisolated static func watcherActions(
        for event: DispatchSource.FileSystemEvent,
        fileContents: Data?,
        lastHandledContents: Data?
    ) -> WatcherActions {
        WatcherActions(
            rearm: replacesWatchedFile(event),
            reload: fileContents.map { $0 != lastHandledContents } ?? false
        )
    }

    /// Whether `event` means the watched file no longer sits at the path.
    private nonisolated static func replacesWatchedFile(_ event: DispatchSource.FileSystemEvent) -> Bool {
        !event.isDisjoint(with: [.rename, .delete, .revoke])
    }

    // MARK: - Settings

    /// The contents of config.json. Numeric and enum-backed fields follow
    /// `SettingsPolicy`, which supplies their defaults and validates them
    /// when the file is decoded.
    ///
    /// Which preferences the file carries, and why the others stay out of
    /// it, is set out in `Portability`, below.
    struct AppConfig: Codable, Equatable {
        var selectedVoiceID: String = ""
        /// Words per minute (50–650). 0 means "not yet set by user".
        var wordsPerMinute: Double = SettingsPolicy.wordsPerMinute.configDefault
        /// Pitch multiplier (0.5–2.0, default 1.0). 0 means "not yet set by user"
        var pitchMultiplier: Double = SettingsPolicy.pitchMultiplier.configDefault
        var selectedLanguage: String = ""
        var skipForwardUnit: String = ""
        var skipBackwardUnit: String = ""
        var importDeleteBehavior: ImportDeleteBehavior = SettingsPolicy.importDeleteBehavior.defaultValue
        /// Path to the .TextMouth data directory. Empty string means default (~/.TextMouth).
        var dataDirectoryPath: String = ""
        /// Whether to show a confirmation dialog before removing a book
        var confirmBeforeDelete: Bool = true
        /// Shift+skip forward unit (secondary skip amount)
        var shiftSkipForwardUnit: String = ""
        /// Shift+skip backward unit (secondary skip amount)
        var shiftSkipBackwardUnit: String = ""
        /// Rewind-on-resume unit (none, sentence, paragraph, heading)
        var rewindOnResumeUnit: String = ""
        /// Whether smart mode is enabled (only rewind after long pauses)
        var rewindSmartMode: Bool = false
        /// Smart mode threshold in seconds (don't rewind if pause shorter than this)
        var rewindSmartThreshold: Double = SettingsPolicy.rewindSmartThreshold.configDefault
        /// Sleep timer fade-out duration in seconds (0 = instant pause)
        var sleepFadeOutDuration: Double = SettingsPolicy.sleepFadeOutDuration.configDefault
        /// Whether to automatically close the sleep timer sheet after setting a timer
        var sleepTimerAutoClose: Bool = true
        /// End-of-book behavior (stop, loop, continueNext)
        var endOfBookBehavior: String = ""
        /// Where the next book opens when listening goes on (this window, or
        /// a new window); empty until chosen, as `endOfBookBehavior` is
        var nextBookWindow: String = ""
        /// Punctuation pause level (0 = none, 1 = subtle, 2 = moderate, 3 = heavy)
        var punctuationPauseLevel: Double = SettingsPolicy.punctuationPauseLevel.configDefault
        /// UUID of the last book that was opened/played (for quick-resume)
        var lastOpenedBookID: String = ""
        /// Auto-play when navigating to a heading, bookmark, or search result
        var autoPlayOnNavigate: Bool = false
        /// Move deleted books to Trash instead of permanently deleting
        var moveToTrashInsteadOfDeleting: Bool = true
        /// Whether an import keeps the original of each audio file it
        /// converts (Ogg, AC-3, and the rest) in the book's package, beside
        /// the converted file. Off by default; feed episodes never keep one.
        /// Only imports made while it is on keep anything.
        var keepsOriginalOfConvertedAudio: Bool = false
        /// Whether Bluetooth disconnect monitoring is enabled
        var bluetoothMonitoringEnabled: Bool = true
        /// Suppress window duration (seconds) after Bluetooth disconnect
        var bluetoothDisconnectDelay: Double = SettingsPolicy.bluetoothDisconnectDelay.configDefault
        /// Whether the experimental "restart sleep timer via media
        /// gesture" detector is enabled. Off by default — see
        /// MediaGestureDetector for rationale.
        var restartTimerGestureEnabled: Bool = false
        /// Comma-separated event-type sequence (see
        /// MediaGestureDetector.EventType) that triggers a sleep timer
        /// restart when matched within the configured time window.
        var restartTimerGesturePattern: String = AppConfig.defaultRestartTimerGesturePattern
        /// Maximum elapsed time in seconds across the gesture's event
        /// sequence. Anything longer breaks the match and starts the
        /// pattern over.
        var restartTimerGestureWindow: Double = SettingsPolicy.restartTimerGestureWindow.configDefault

        // MARK: Fields added after the file first shipped
        //
        // A file written before one of these existed lacks it. Each reads as
        // nil or empty then, which leaves the preference as it is, so a file
        // from an earlier version never resets a newer preference.

        /// Which per-book navigation menus the playback bar shows (a
        /// `PlaybackNavigationUnitControlMode` raw value); empty keeps the
        /// current choice.
        var playbackNavigationUnitControlMode: String = ""
        /// Whether the playback bar shows the bookmark button.
        var showBookmarkInPlaybackControls: Bool?
        /// Whether the playback bar shows the speed controls.
        var showSpeedInPlaybackControls: Bool?
        /// Whether the reader's toolbar shows an Export button (FR05).
        var showExportInReaderToolbar: Bool?
        /// Whether the reader names the speed beside time left and total
        /// time (P08): "3:44:01 left at 2.0x" for an audiobook not at 1x,
        /// "at 500 words a minute" for a text book.
        var includeSpeedWithTimes: Bool?
        /// Whether the reader screen shows the page being read (PG03), such
        /// as "Page 12 of 300", for a book with pages.
        var showsPageInReader: Bool?
        /// Whether Where Am I?'s summaries say the page being read (PG04),
        /// such as "Page 112 of 300", for a book with pages.
        var saysPageInWhereAmI: Bool?
        /// Whether sound effects play.
        var soundEffectsEnabled: Bool?
        /// How loud sound effects play, from 0 to 1, written to the
        /// hundredth: the precision Settings shows, as a percentage.
        var soundEffectsVolume: Double?
        /// The sound each playback event plays, keyed by the event's name as
        /// Settings shows it; "None" plays nothing. TextMouth writes every
        /// event; an event the file leaves out keeps its sound.
        var soundEffectAssignments: [String: String] = [:]
        /// Whether the text substitution rules apply. The rules themselves
        /// are kept in substitutions.json, beside this file.
        var substitutionsEnabled: Bool?
        /// How speech reads a run of a repeated symbol: "repeat" (every
        /// symbol), "count" ("7 asterisks"), or "omit" (a pause instead).
        /// Empty keeps the current choice.
        var repeatedSymbolStyle: String = ""
        /// The fewest symbols a run must have to be read as a count or left
        /// out, from 2 to 99, or -1 to read every symbol.
        var repeatedSymbolThreshold: Int?
        /// The symbols that can form runs, written together, such as
        /// "*-=_~#"; spaces, letters, and digits are ignored. Empty, like
        /// any empty text here, keeps the current symbols.
        var repeatedSymbolSet: String?
        /// The microphone the Record window records from, by its unique
        /// identifier (`RecordingInputChoice`). TextMouth writes it empty
        /// until one is chosen, when recordings use macOS's default input;
        /// empty, like any empty text here, keeps the current choice.
        var recordingInputDeviceID: String = ""
        /// Whether the Record window announces the level while recording
        /// (`RecordingLevelAnnouncements`).
        var recordingAnnouncesLevel: Bool?
        /// How many seconds apart it announces it, from 5 to 60.
        var recordingLevelAnnouncementSeconds: Double?
        /// What happens to the original audio of recordings and edited
        /// audiobooks (`AudioOriginalPolicy.Choice`): "keep", "delete", or
        /// "deleteAfterDays". Empty keeps the current choice. The name is
        /// from when only recordings kept an original.
        var recordingOriginalPolicy: String = ""
        /// How many days an original is kept when the choice is
        /// "deleteAfterDays", from 1 to 365.
        var recordingOriginalDays: Double?
        /// Whether an installed ffmpeg, when TextMouth finds one, runs the
        /// audio editor's filters (`AudioFilterEngine`), and writes MP3
        /// should TextMouth's own encoder be unavailable (`MP3Route`).
        var useInstalledFFmpeg: Bool?
        /// Whether the audio editor's Apply Filter plays a preview before
        /// applying a filter (`AudioEditorPreferences.previewFiltersFirst`).
        var audioEditorPreviewsFilters: Bool?
        /// Whether the audio editor plays half a second at the cursor after
        /// each move (`AudioEditorPreferences.playAfterMoves`).
        var audioEditorPlaysAfterMoves: Bool?
        /// The keyboard shortcuts of each action, keyed by the action's name
        /// as Settings shows it, in any letter case, in any of three forms
        /// (FR12, `ShortcutListing`): an action the user edited is a list of
        /// shortcuts such as ["option+shift+command+b"]
        /// (`KeyBinding.configText`), an empty list leaving it without one,
        /// or, when it works in a kind of window the user chose, an object
        /// such as {"keys": ["shift+command+t"], "worksIn": "Every window"}
        /// (FR12's branch E); every other action is text beginning with
        /// "default", such as "default: w". Writing a list or an object makes
        /// an action the user's, and writing "default" gives it back to
        /// TextMouth's defaults. A file in the old form, which earlier
        /// releases wrote as a list for every action and which holds no
        /// "default" and no object, makes the user's only the actions whose
        /// list differs from every default they had: a list equal to a
        /// default edits nothing (`KeyboardShortcutManager.adopt(_:in:)`).
        /// TextMouth writes every action from the record of the user's edits
        /// (`ShortcutEdits`); an action the file leaves out keeps its
        /// shortcuts.
        var keyboardShortcuts: [String: ShortcutListing] = [:]
        /// How soon a second press of a key must follow the first to make a
        /// double press, such as "w twice" in `keyboardShortcuts`, in
        /// seconds (FR12): one time for every shortcut, from 0.2 to 2 in
        /// tenths. A value out of range is read as the nearest bound, and
        /// one between tenths as the nearest tenth.
        var shortcutDoublePressSeconds: Double?
        /// Whether every feed is refreshed when TextMouth opens (FR03,
        /// `FeedSettings`).
        var feedRefreshAtLaunch: Bool?
        /// Hours between feed refreshes while TextMouth runs, 1 to 168, or 0
        /// to refresh only at launch and when asked.
        var feedRefreshIntervalHours: Int?
        /// The "List and download" choice (FR11, `FeedItemPolicy.Choice`):
        /// "everyListedNewestDownloaded" (every item listed, the newest
        /// downloaded), "everyListedDownloadsByHand", or "onlyNewestListed".
        /// Empty keeps the current choice, as does a name that is none of
        /// these. It replaced feedKeepEntries and feedAutoDownload, which a
        /// file written before it may still hold, and which are ignored.
        var feedItems: String = ""
        /// How many of each feed's newest items the choice downloads, or
        /// lists, from 1 to 2,000; a number outside that is read as the
        /// nearest of the two.
        var feedNewestCount: Int?
        /// Days after an episode plays to the end that its download is
        /// deleted, 0 (at once) to 365, or -1 never.
        var feedDeleteDownloadsDaysAfterPlayed: Int?
        /// Whether a refresh is announced in an alert.
        var feedRefreshAlert: Bool?
        /// Whether new episodes are announced in a notification.
        var feedNotifications: Bool?
        /// Where the diagnostic logs are written (`LogLocation`):
        /// "dataDirectory", in the data directory's Logs folder, or
        /// "machine", in this Mac's ~/Library/Logs/TextMouth. Empty keeps
        /// the current choice.
        var logLocation: String = ""
        /// The language transcription uses (`TranscriptionLanguage`), as a
        /// locale identifier such as "en-US" or "en-GB". Empty keeps the
        /// current choice, as does an identifier that cannot be one.
        var transcriptionLocale: String = ""
        /// Whether TextMouth offers to transcribe each audiobook just
        /// imported (`TranscriptionPreferences.offerAfterImport`).
        var offerTranscriptionAfterImport: Bool?
        /// The Library window's views, in order (October 30, 2026,
        /// `LibraryViewDefinitionList`): an array of objects, one per view,
        /// each with its "id" and "visibility", and, for a view the listener
        /// made or a built-in view they changed, its "name" and "filter".
        /// Each entry is read on its own: one this TextMouth cannot read is
        /// kept as it is and never offered, and a value out of range is
        /// repaired. Nil, or an empty array, leaves the views as they are.
        var libraryViews: [JSONValue]?
        /// What a title's leading article does in the Library's lists
        /// (`LeadingArticles`, November 13, 2026): "partOfTitle", as
        /// written; "ignoredWhenTyping", passed over when typing a title's
        /// first letters; or "ignoredWhenTypingAndSorting", passed over when
        /// sorting too, the rows showing "Hobbit, The". Empty keeps the
        /// current choice, as does a name that is none of these.
        var leadingArticles: String = ""
        /// The braille table TextMouth reads and writes braille with
        /// (`BraillePreferences`), by its stored value: a bundled table's
        /// file name, such as "en-ueb-g2.ctb", or "mac:" and the file name of
        /// one of this Mac's VoiceOver tables, such as "mac:fr-bfu-g2.ctb".
        /// Empty keeps the current choice, as does a bundled name the bundle
        /// lacks. A Mac table's value is taken as it is, without reading this
        /// Mac's tables (`BrailleTableCatalog.storableValue(_:)`), and is
        /// checked before its first use, as one chosen in Settings is
        /// (`MacBrailleTableCheck`), or refused by name if this Mac lacks it.
        var brailleTable: String = ""
        /// The braille file characters TextMouth imports a BRF or BRL file
        /// with (`BraillePreferences.fileCode`), by the code's id:
        /// "ascii-na" (North American Braille ASCII) or "ascii-eurobraille".
        /// Empty keeps the current choice, as does an id this TextMouth
        /// lacks, and "unicode", which an import recognizes by a file's bytes
        /// and never takes from the setting (`BrailleFileCode.importChoices`).
        var brailleFileCode: String = ""

        /// Decodes config.json one field at a time, because people edit it
        /// by hand. A missing field keeps its default (older files lack newer
        /// fields). A field that is unreadable, out of range, or unsupported
        /// is repaired and logged by `LenientFields` rather than failing the
        /// whole file, so one bad value can never discard the others.
        init(from decoder: Decoder) throws {
            let fields = LenientFields(try decoder.container(keyedBy: CodingKeys.self), source: "config.json")
            // The property defaults above are the only copy of each default.
            let fallback = AppConfig()
            selectedVoiceID = fields.value(.selectedVoiceID, default: fallback.selectedVoiceID)
            wordsPerMinute = fields.number(.wordsPerMinute, rule: SettingsPolicy.wordsPerMinute)
            pitchMultiplier = fields.number(.pitchMultiplier, rule: SettingsPolicy.pitchMultiplier)
            selectedLanguage = fields.value(.selectedLanguage, default: fallback.selectedLanguage)
            skipForwardUnit = fields.rawChoice(.skipForwardUnit, rule: SettingsPolicy.skipForwardUnit)
            skipBackwardUnit = fields.rawChoice(.skipBackwardUnit, rule: SettingsPolicy.skipBackwardUnit)
            importDeleteBehavior = fields.choice(.importDeleteBehavior, rule: SettingsPolicy.importDeleteBehavior)
            // Applying "" moves the library to the default location at once,
            // so an unreadable path keeps the directory already in use.
            dataDirectoryPath = fields.value(
                .dataDirectoryPath,
                default: fallback.dataDirectoryPath,
                ifUnreadable: Self.currentDataDirectoryPath
            )
            confirmBeforeDelete = fields.value(.confirmBeforeDelete, default: fallback.confirmBeforeDelete)
            shiftSkipForwardUnit = fields.rawChoice(.shiftSkipForwardUnit, rule: SettingsPolicy.shiftSkipForwardUnit)
            shiftSkipBackwardUnit = fields.rawChoice(.shiftSkipBackwardUnit, rule: SettingsPolicy.shiftSkipBackwardUnit)
            rewindOnResumeUnit = fields.rawChoice(.rewindOnResumeUnit, rule: SettingsPolicy.rewindOnResumeUnit)
            rewindSmartMode = fields.value(.rewindSmartMode, default: fallback.rewindSmartMode)
            rewindSmartThreshold = fields.number(.rewindSmartThreshold, rule: SettingsPolicy.rewindSmartThreshold)
            sleepFadeOutDuration = fields.number(.sleepFadeOutDuration, rule: SettingsPolicy.sleepFadeOutDuration)
            sleepTimerAutoClose = fields.value(.sleepTimerAutoClose, default: fallback.sleepTimerAutoClose)
            endOfBookBehavior = fields.rawChoice(.endOfBookBehavior, rule: SettingsPolicy.endOfBookBehavior)
            nextBookWindow = fields.rawChoice(.nextBookWindow, rule: SettingsPolicy.nextBookWindow)
            punctuationPauseLevel = fields.number(.punctuationPauseLevel, rule: SettingsPolicy.punctuationPauseLevel)
            lastOpenedBookID = fields.value(.lastOpenedBookID, default: fallback.lastOpenedBookID)
            autoPlayOnNavigate = fields.value(.autoPlayOnNavigate, default: fallback.autoPlayOnNavigate)
            moveToTrashInsteadOfDeleting = fields.value(
                .moveToTrashInsteadOfDeleting,
                default: fallback.moveToTrashInsteadOfDeleting
            )
            keepsOriginalOfConvertedAudio = fields.value(
                .keepsOriginalOfConvertedAudio,
                default: fallback.keepsOriginalOfConvertedAudio
            )
            bluetoothMonitoringEnabled = fields.value(
                .bluetoothMonitoringEnabled,
                default: fallback.bluetoothMonitoringEnabled
            )
            bluetoothDisconnectDelay = fields.number(
                .bluetoothDisconnectDelay,
                rule: SettingsPolicy.bluetoothDisconnectDelay
            )
            restartTimerGestureEnabled = fields.value(
                .restartTimerGestureEnabled,
                default: fallback.restartTimerGestureEnabled
            )
            restartTimerGesturePattern = fields.value(
                .restartTimerGesturePattern,
                default: fallback.restartTimerGesturePattern
            )
            restartTimerGestureWindow = fields.number(
                .restartTimerGestureWindow,
                rule: SettingsPolicy.restartTimerGestureWindow
            )
            playbackNavigationUnitControlMode = fields.rawChoice(
                .playbackNavigationUnitControlMode,
                rule: SettingsPolicy.playbackNavigationUnitControlMode
            )
            showBookmarkInPlaybackControls = fields.optionalFlag(.showBookmarkInPlaybackControls)
            showSpeedInPlaybackControls = fields.optionalFlag(.showSpeedInPlaybackControls)
            showExportInReaderToolbar = fields.optionalFlag(.showExportInReaderToolbar)
            includeSpeedWithTimes = fields.optionalFlag(.includeSpeedWithTimes)
            showsPageInReader = fields.optionalFlag(.showsPageInReader)
            saysPageInWhereAmI = fields.optionalFlag(.saysPageInWhereAmI)
            soundEffectsEnabled = fields.optionalFlag(.soundEffectsEnabled)
            soundEffectsVolume = fields.optionalNumber(.soundEffectsVolume, rule: SettingsPolicy.soundEffectsVolume)
            soundEffectAssignments = fields.entries(
                .soundEffectAssignments,
                rule: SettingsPolicy.soundEffectAssignments
            )
            substitutionsEnabled = fields.optionalFlag(.substitutionsEnabled)
            repeatedSymbolStyle = fields.rawChoice(.repeatedSymbolStyle, rule: SettingsPolicy.repeatedSymbolStyle)
            repeatedSymbolThreshold = fields.optionalThreshold(
                .repeatedSymbolThreshold,
                rule: SettingsPolicy.repeatedSymbolThreshold
            )
            repeatedSymbolSet = fields.optionalCharacterSet(.repeatedSymbolSet, rule: SettingsPolicy.repeatedSymbolSet)
            recordingInputDeviceID = fields.value(.recordingInputDeviceID, default: fallback.recordingInputDeviceID)
            recordingAnnouncesLevel = fields.optionalFlag(.recordingAnnouncesLevel)
            recordingLevelAnnouncementSeconds = fields.optionalNumber(
                .recordingLevelAnnouncementSeconds,
                rule: SettingsPolicy.recordingLevelAnnouncementSeconds
            )
            recordingOriginalPolicy = fields.rawChoice(.recordingOriginalPolicy, rule: SettingsPolicy.recordingOriginalPolicy)
            recordingOriginalDays = fields.optionalNumber(.recordingOriginalDays, rule: SettingsPolicy.recordingOriginalDays)
            useInstalledFFmpeg = fields.optionalFlag(.useInstalledFFmpeg)
            audioEditorPreviewsFilters = fields.optionalFlag(.audioEditorPreviewsFilters)
            audioEditorPlaysAfterMoves = fields.optionalFlag(.audioEditorPlaysAfterMoves)
            keyboardShortcuts = fields.entries(.keyboardShortcuts, rule: SettingsPolicy.keyboardShortcuts)
            // Moved into range and to the nearest tenth, which is logged as a
            // repair, as a clamped number is.
            shortcutDoublePressSeconds = fields.optionalValue(.shortcutDoublePressSeconds) { (seconds: Double) in
                SettingsPolicy.validatedDoublePressSeconds(seconds)
            }
            feedRefreshAtLaunch = fields.optionalFlag(.feedRefreshAtLaunch)
            feedRefreshIntervalHours = fields.optionalThreshold(
                .feedRefreshIntervalHours,
                rule: SettingsPolicy.feedRefreshIntervalHours
            )
            feedItems = fields.rawChoice(.feedItems, rule: SettingsPolicy.feedItems)
            // Moved into range, which is logged as a repair; a number that is
            // not whole is unreadable, and leaves the setting alone.
            feedNewestCount = fields.optionalValue(.feedNewestCount) { (count: Int) in
                SettingsPolicy.feedNewestCount.validated(count)
            }
            feedDeleteDownloadsDaysAfterPlayed = fields.optionalThreshold(
                .feedDeleteDownloadsDaysAfterPlayed,
                rule: SettingsPolicy.feedDeleteDownloadsDaysAfterPlayed
            )
            feedRefreshAlert = fields.optionalFlag(.feedRefreshAlert)
            feedNotifications = fields.optionalFlag(.feedNotifications)
            logLocation = fields.rawChoice(.logLocation, rule: SettingsPolicy.logLocation)
            // An identifier that cannot be one is repaired to empty, and
            // logged, so it leaves the current language alone.
            transcriptionLocale = fields.value(.transcriptionLocale, default: fallback.transcriptionLocale) {
                TranscriptionLanguage.validated($0) ?? ""
            }
            offerTranscriptionAfterImport = fields.optionalFlag(.offerTranscriptionAfterImport)
            // Any array of values: the list reads each entry on its own, with
            // its own bounds, when the settings model applies the file. An
            // empty array is no request, as an empty text is.
            libraryViews = fields.optionalValue(.libraryViews) { (entries: [JSONValue]) in
                entries.isEmpty ? nil : entries
            }
            leadingArticles = fields.rawChoice(.leadingArticles, rule: SettingsPolicy.leadingArticles)
            // Without reading this Mac's tables (review R3): decoding runs on
            // the main thread at every launch.
            brailleTable = fields.value(.brailleTable, default: fallback.brailleTable) {
                BrailleTableCatalog.storableValue($0) ?? ""
            }
            // An id this TextMouth lacks is repaired to empty, and logged, so
            // it leaves the current braille file characters alone.
            brailleFileCode = fields.value(.brailleFileCode, default: fallback.brailleFileCode) {
                BrailleFileCode.importChoice(withID: $0) == nil ? "" : $0
            }
        }

        init() {}

        /// The `dataDirectoryPath` describing the data directory in use: empty
        /// for the default location, otherwise its full path.
        static var currentDataDirectoryPath: String {
            TextMouthPaths.isCustomPath ? TextMouthPaths.rootPath : ""
        }

        /// Three previous-track presses in a row: the restart-timer gesture
        /// until the user picks another, shared with the Settings model.
        static let defaultRestartTimerGesturePattern = "previousTrack,previousTrack,previousTrack"

        // MARK: Portability

        /// Which preferences config.json carries (TODO C04).
        ///
        /// Every preference TextMouth keeps is portable or machine-local. A
        /// portable preference is mirrored in config.json, so it can be set
        /// by editing the file and travels with it to another Mac: the
        /// settings model writes it into the file and applies the file's
        /// value back. A machine-local one describes this Mac, or what
        /// TextMouth was last doing on it, so it stays out of the mirror.
        ///
        /// The tests take their expected sets from these lists: every
        /// preference the settings model and the services keep must be
        /// listed, every listed config.json field must be in the file, and
        /// every portable preference must survive a round trip through it.
        enum Portability {
            /// Portable preferences kept in the preferences store, each with
            /// the config.json field that carries it, by Settings tab.
            static let mirrored: [(storeKey: String, field: String)] = {
                // Voice.
                var mirrored = sameNames(["selectedVoiceID", "wordsPerMinute", "pitchMultiplier", "selectedLanguage"])
                // Playback.
                mirrored += sameNames([
                    "skipForwardUnit", "skipBackwardUnit", "shiftSkipForwardUnit", "shiftSkipBackwardUnit",
                    "rewindOnResumeUnit", "rewindSmartMode", "rewindSmartThreshold", "punctuationPauseLevel",
                    "autoPlayOnNavigate", "endOfBookBehavior", "nextBookWindow", "sleepFadeOutDuration", "sleepTimerAutoClose",
                    "playbackNavigationUnitControlMode", "showBookmarkInPlaybackControls",
                    "showSpeedInPlaybackControls", "showExportInReaderToolbar", "includeSpeedWithTimes",
                    "showsPageInReader", "saysPageInWhereAmI",
                ])
                // Shortcuts: the record of the ones the user edited (FR12),
                // which the file lists with every other action's defaults,
                // and the double-press time.
                mirrored.append((storeKey: KeyboardShortcutManager.editsPreference.key, field: "keyboardShortcuts"))
                mirrored += sameNames([KeyboardShortcutManager.doublePressTimePreference.key])
                // Text: the switch and the repeated-symbol settings. The rules
                // are kept in substitutions.json.
                mirrored += sameNames([
                    "substitutionsEnabled", "repeatedSymbolStyle", "repeatedSymbolThreshold", "repeatedSymbolSet",
                ])
                // Sounds.
                mirrored += sameNames(["soundEffectsEnabled", "soundEffectsVolume", "soundEffectAssignments"])
                // Recording: the microphone the Record window remembers, and
                // its level announcements.
                mirrored += sameNames(RecordingPreferences.keys)
                // Audio editing: how long the original audio of recordings and
                // edited audiobooks is kept, whether an installed ffmpeg runs
                // filters, and whether the editor previews a
                // filter before applying it and plays half a second after
                // each move.
                mirrored += sameNames(AudioEditingPreferences.keys)
                // Miscellaneous.
                mirrored += sameNames([
                    "bluetoothMonitoringEnabled", "bluetoothDisconnectDelay", "restartTimerGestureEnabled",
                    "restartTimerGesturePattern", "restartTimerGestureWindow",
                ])
                // Feeds (FR03), which the feed engine keeps, with the "List and
                // download" choice and its number (FR11).
                mirrored += sameNames([
                    "feedRefreshAtLaunch", "feedRefreshIntervalHours", "feedItems", "feedNewestCount",
                    "feedDeleteDownloadsDaysAfterPlayed", "feedRefreshAlert", "feedNotifications",
                ])
                // Storage: where the logs are written, which the log writer
                // keeps. The tab's other choices config.json alone holds.
                mirrored += sameNames(["logLocation"])
                // Transcription: the language it uses, which
                // TranscriptionLanguage keeps, and whether it is offered
                // after an import (FR05).
                mirrored += sameNames(["transcriptionLocale", "offerTranscriptionAfterImport"])
                // Library (October 30, 2026): the Library window's views,
                // which the views store keeps (`LibraryViewDefinitionStore`).
                mirrored += sameNames([LibraryViewDefinitionList.fileKey])
                // And what a title's leading article does in its lists, which
                // the Library windows read (`LeadingArticles`, November 13, 2026).
                mirrored += sameNames([SettingsPolicy.leadingArticles.key])
                // Braille (FMT21): the table braille files are read and written with.
                // And the braille file characters a BRF or BRL file is imported in (braillecodes).
                mirrored += sameNames(["brailleTable", "brailleFileCode"])
                return mirrored
            }()

            /// Portable preferences config.json alone holds: the Storage
            /// settings' import and removal choices.
            static let fileOnly = [
                "importDeleteBehavior", "confirmBeforeDelete", "moveToTrashInsteadOfDeleting",
                "keepsOriginalOfConvertedAudio",
            ]

            /// Preferences-store keys an earlier release wrote, read once to
            /// move what they held and never written again, so each stays
            /// as a copy to go back to; neither mirrored nor written to
            /// config.json.
            /// - `customKeyboardBindings`: every action's keys, as saved
            ///   before the record of the user's edits (FR12). The move to
            ///   the record reads it at the first launch without one
            ///   (`KeyboardShortcutManager.moveSavedShortcutsIfNeeded`).
            /// - `feedKeepEntries` and `feedAutoDownload`: how many entries
            ///   each feed kept, and whether new episodes downloaded by
            ///   themselves, before the "List and download" choice (FR11).
            ///   The move to the choice reads them at the first launch
            ///   without one (`FeedSettings.moveToItemPolicyIfNeeded(in:)`).
            static let retiredStoreKeys = [KeyboardShortcutManager.savedMapKey] + FeedSettings.retiredPreferenceKeys

            /// Machine-local values config.json holds without mirroring them.
            /// - `dataDirectoryPath`: where this Mac keeps its library. The
            ///   Storage settings manage it: TextMouth always writes the
            ///   directory in use, and a different path in the file asks the
            ///   library to move there rather than being copied as a setting.
            /// - `lastOpenedBookID`: a book in this Mac's library, which the
            ///   library records when a book opens.
            static let localFields = ["dataDirectoryPath", "lastOpenedBookID"]

            /// Machine-local preferences-store keys, never written to
            /// config.json.
            /// - `textMouthDataDirectory`: the data directory's location, the
            ///   store's copy of `dataDirectoryPath`.
            /// - `textMouthDataDirectoryBookmark` and `textMouthLibraryIdentity`:
            ///   a bookmark of that folder, and the identity of the library
            ///   this Mac expects in it (`DataDirectoryPreferences`, FR02).
            /// - `textMouthSessionMacID`: the ID naming this Mac's lease in a
            ///   library other Macs can open (`LibrarySessionLease`, FR02).
            /// - `sleepTimer.lastUsedDuration`: the last sleep timer started,
            ///   which restarting the timer reuses: state, not a setting.
            /// - `NSQuitAlwaysKeepsWindows`: window restoration, which
            ///   TextMouth turns off at every launch. AppKit keeps this Mac's
            ///   window positions in the store too, and they stay there.
            /// - `editTextExplained`: whether Edit Text has explained what it
            ///   does on this Mac (FR05): state, not a setting.
            /// - `editManifestExplained`: whether Edit Manifest has explained
            ///   what it does on this Mac (FR17): state, not a setting.
            /// - `library.finishedBooksAtEndVersion`: the version of the
            ///   one-time move of finished books to their ends made on this
            ///   Mac (`LibraryViewModel.finishedBooksAtEndKey`, P07): state,
            ///   not a setting.
            static let localStoreKeys = DataDirectoryPreferences.keys
                + [LibrarySessionLease.macIDPreference.key, "sleepTimer.lastUsedDuration", "NSQuitAlwaysKeepsWindows"]
                + [BookTextEditor.explainedPreference.key, BookManifestEditor.explainedPreference.key]
                + [LibraryViewModel.finishedBooksAtEndKey]

            /// Pairs each key with the config.json field of the same name.
            private static func sameNames(_ keys: [String]) -> [(storeKey: String, field: String)] {
                keys.map { (storeKey: $0, field: $0) }
            }
        }
    }

    // MARK: - Lifecycle

    /// Creates a service and loads its file before returning.
    ///
    /// - Parameters:
    ///   - fileURL: The file to mirror. Nil, as `shared` uses, follows the
    ///     data directory in use; tests pass a file of their own.
    ///   - fileOperations: The file-system calls to make; tests count them.
    ///   - coalescingDelay: How long a burst of file events must stay quiet
    ///     before the watcher reads the file.
    ///   - saveDelay: How long a save asked for with `scheduleSave()` waits
    ///     for the next change.
    init(
        fileURL: URL? = nil,
        fileOperations: FileOperations = .system,
        coalescingDelay: Duration = .milliseconds(200),
        saveDelay: Duration = ConfigService.defaultSaveDelay
    ) {
        customFileURL = fileURL
        self.fileOperations = fileOperations
        self.coalescingDelay = coalescingDelay
        self.saveDelay = saveDelay
        loadFromDisk()
        if fileURL == nil {
            availabilitySubscription = NotificationCenter.default
                .publisher(for: .dataDirectoryDidBecomeAvailable)
                .sink { [weak self] _ in self?.dataDirectoryBecameAvailable() }
        }
    }

    /// Starts following config.json for edits made outside TextMouth. Launch
    /// calls this once it has reconciled the file with the preferences.
    func startWatching() {
        isWatching = true
        rearmWatcher()
    }

    /// Stops following config.json: a save waiting for its delay is written
    /// first, pending checks and searches are dropped, and the watched file's
    /// descriptor is closed once its source is cancelled. Events that arrive
    /// later are ignored.
    func shutdown() {
        flushScheduledSave()
        isWatching = false
        pendingCheck?.cancel()
        pendingCheck = nil
        pendingEvents = []
        rearmRetry?.cancel()
        rearmRetry = nil
        availabilitySubscription = nil
        disarm()
    }

    /// Follows config.json again once the data directory is back (FR02).
    /// When this service left the file unread or unsaved meanwhile, the file
    /// is first reconciled as an edit found on disk: each setting changed
    /// here meanwhile keeps its new value, every other one takes the file's,
    /// and the result is published for the settings model to apply, then
    /// saved. The settings in use when the file was first skipped stand for
    /// what it last held. A watcher that lost the file while the library was
    /// away attaches to it again, and checks it, so an edit saved elsewhere
    /// meanwhile is applied too; one still attached is left as it is.
    func dataDirectoryBecameAvailable() {
        guard !isFileUnavailable else { return }
        if skippedFileWhileUnavailable {
            skippedFileWhileUnavailable = false
            saveToDisk()
        }
        if watchedFile == nil {
            rearmWatcher()
        }
    }

    // MARK: - Persistence

    /// Saves config.json once changes pause for `saveDelay` (PERF17): each
    /// settings change asks for a save, and a burst of them, such as a
    /// slider moved through its steps, writes the file once. `config` holds
    /// every change at once; only the file waits. A save made meanwhile with
    /// `saveToDisk()` writes it at once instead, and `flushScheduledSave()`
    /// does when TextMouth quits or the data directory moves.
    func scheduleSave() {
        scheduledSave?.cancel()
        scheduledSave = Task { [weak self, saveDelay] in
            try? await Task.sleep(for: saveDelay)
            guard !Task.isCancelled, let self else { return }
            self.scheduledSave = nil
            self.saveToDisk()
        }
    }

    /// Writes a save that `scheduleSave()` left waiting, now, as TextMouth
    /// quits, or before the data directory moves, so the file holds the
    /// latest settings. Does nothing when no save waits.
    func flushScheduledSave() {
        guard hasScheduledSave else { return }
        saveToDisk()
    }

    /// Whether a save asked for with `scheduleSave()` is waiting.
    var hasScheduledSave: Bool {
        scheduledSave != nil
    }

    /// Makes config.json hold `config`, at once; a save waiting for its delay
    /// is no longer needed.
    ///
    /// An edit that reached the file since this process last wrote or read
    /// it, still waiting for the watcher's delay, is merged in first rather
    /// than saved over. Nothing is written when the file already holds
    /// exactly the resulting bytes: writing them again would change only the
    /// modification date and wake the watcher, so a launch on a consistent
    /// file writes nothing. The bytes become `lastHandledContents`, which is
    /// how the watcher recognizes the events of this save as TextMouth's own.
    ///
    /// The file is read with dataless files left in the cloud (FR02,
    /// PERF17): one only in the cloud is neither read, which would wait on
    /// the network here on the main thread, nor written over, which would
    /// replace what another Mac saved. The preferences hold every setting
    /// meanwhile, and a later save, once the file is on this Mac, merges it
    /// as an edit found on disk.
    func saveToDisk() {
        scheduledSave?.cancel()
        scheduledSave = nil
        // Nothing is written where the library isn't (FR02). The preferences
        // hold every setting meanwhile, so this is no failure; the settings
        // in use now stand for what the file last held, unless an agreement
        // with the file already says, and the file is reconciled when the
        // data directory is back.
        guard !isFileUnavailable else {
            if lastSyncedConfig == nil {
                lastSyncedConfig = config
            }
            skippedFileWhileUnavailable = true
            return
        }
        let onDisk: Data?
        switch readFile() {
        case .inCloud:
            // The settings in use stand for what the file last held, unless
            // an agreement with the file already says, so the save that finds
            // it on this Mac again keeps the changes made meanwhile.
            if lastSyncedConfig == nil {
                lastSyncedConfig = config
            }
            noteFileInCloud()
            return
        case .contents(let contents):
            onDisk = contents
        case .none:
            onDisk = nil
        }
        isFileInCloud = false
        if let onDisk, onDisk != lastHandledContents {
            mergeUnhandledEdit(onDisk)
        }
        let data: Data
        do {
            data = try Self.fileData(for: config)
        } catch {
            log("could not encode the settings for \(fileURL.path): \(error)")
            return
        }
        guard data != onDisk else {
            recordAgreement(data)
            return
        }
        do {
            try TextMouthPaths.ensureDirectoryStructure()
            try fileOperations.write(data, fileURL)
        } catch {
            log("could not save \(fileURL.path): \(error)")
            // The settings in use are not on disk: the user is told, not only
            // the log (TODO S09). A retry saves the settings as they are then,
            // the same ones unless a later change has saved them itself.
            PersistenceFailureCenter.shared.recordFailure(
                .configuration,
                path: fileURL.path,
                error: error
            ) { [weak self] _ in
                self?.saveToDisk()
            }
            return
        }
        recordAgreement(data)
        // The atomic write replaced the watched file. Follow the new one now
        // rather than when its event arrives, leaving no moment unwatched.
        rearmWatcher()
    }

    /// Records that config.json holds `data`, the bytes of `config`: the
    /// watcher ignores these bytes, the next merge starts from `config`, and
    /// the settings are saved, which settles any earlier failed save.
    private func recordAgreement(_ data: Data) {
        lastHandledContents = data
        lastSyncedConfig = config
        PersistenceFailureCenter.shared.recordSuccess(.configuration)
    }

    /// What a read of config.json found.
    private enum FileRead {
        /// The file's bytes.
        case contents(Data)
        /// No file, or one that cannot be read.
        case none
        /// A file only in the cloud (FR02), which was not read: reading it
        /// would have downloaded it first.
        case inCloud
    }

    /// config.json as it is now, read with dataless files left in the cloud,
    /// so a read never waits on the network (PERF17).
    private func readFile() -> FileRead {
        do {
            return .contents(try fileOperations.read(fileURL))
        } catch where DatalessFiles.isDownloadRefusal(error) {
            return .inCloud
        } catch {
            return .none
        }
    }

    /// config.json's current bytes, or nil when there is no file, it cannot
    /// be read, or it is only in the cloud.
    private func readFileContents() -> Data? {
        guard case .contents(let contents) = readFile() else { return nil }
        return contents
    }

    /// Takes up config.json once it is on this Mac, after it was found only in
    /// the cloud (`noteFileInCloud()`): the file is merged with the settings
    /// in use as the first save that finds it would, so a setting changed
    /// here meanwhile keeps its new value and every other one takes the
    /// file's, without a restart. Does nothing unless the file was waiting
    /// in the cloud; while it still is, nothing is read or written.
    func fileMayHaveArrived() {
        guard isFileInCloud else { return }
        saveToDisk()
    }

    /// Notes that config.json is only in the cloud, so it is neither read
    /// nor written now (FR02), which the debug log says once.
    private func noteFileInCloud() {
        guard !isFileInCloud else { return }
        isFileInCloud = true
        log(
            "\(fileURL.lastPathComponent) is only in the cloud, so it is neither read nor written "
                + "until it is on this Mac; the settings are kept meanwhile"
        )
    }

    /// The exact bytes `saveToDisk()` writes for `config`: sorted, indented
    /// JSON that stays readable for people who edit the file by hand.
    nonisolated static func fileData(for config: AppConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(config)
    }

    /// Reads config.json into `config` before returning.
    ///
    /// Consumers created afterwards therefore read the file's values. The
    /// assignment used to wait for the next main-queue turn, so launch found
    /// only defaults, skipped applying the file, and saved the preferences
    /// over it before the file's own values arrived.
    private func loadFromDisk() {
        // Nothing is read from a data directory the library model found
        // unavailable, which may hold another library's settings (FR02): the
        // file is reconciled once the library is back.
        guard !isFileUnavailable else {
            loadedFile = .missing
            skippedFileWhileUnavailable = true
            return
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            loadedFile = .missing
            return
        }
        do {
            // Read with dataless files left in the cloud (FR02, PERF17): a
            // file only in the cloud is not this launch's to wait for. Its
            // settings are not applied, the preferences stand, and the
            // first save that finds the file on this Mac merges it.
            let contents = try fileOperations.read(fileURL)
            lastHandledContents = contents
            let decoded = try Self.decode(contents)
            if decoded != config {
                config = decoded
            }
            lastSyncedConfig = decoded
            loadedFile = .decoded
        } catch where DatalessFiles.isDownloadRefusal(error) {
            // Not loaded: the preferences stand until the file is on this
            // Mac, and the saves until then leave it as it is. The settings
            // in use now stand for what the file last held, so a setting
            // changed from here on, the first one included, is kept when
            // the file arrives and is merged.
            loadedFile = .missing
            if lastSyncedConfig == nil {
                lastSyncedConfig = config
            }
            noteFileInCloud()
        } catch {
            loadedFile = .unreadable
            logUnreadableFile(error)
        }
    }

    /// Decodes config.json's bytes. The decoder is lenient: a single bad
    /// value is repaired and logged rather than failing the whole file.
    nonisolated static func decode(_ contents: Data) throws -> AppConfig {
        try JSONDecoder().decode(AppConfig.self, from: contents)
    }

    // MARK: - External Edits

    /// Applies config.json's `contents` as an edit made outside TextMouth:
    /// `config` takes the whole snapshot, which is then published once. A
    /// file that cannot be decoded changes nothing and stays on disk as it
    /// is, for whoever edited it to correct; the debug log says why, once,
    /// since the same bytes are not examined twice.
    ///
    /// Changes made here whose save is still waiting (PERF17) stand: the
    /// edit is merged with them, as a save merges an edit it finds, rather
    /// than replacing them, and the waiting save then writes both.
    private func applyExternalEdit(_ contents: Data) {
        lastHandledContents = contents
        let edited: AppConfig
        do {
            edited = try Self.decode(contents)
        } catch {
            logUnreadableFile(error)
            return
        }
        let applied = hasScheduledSave
            ? Self.merging(ours: config, theirs: edited, base: lastSyncedConfig ?? config)
            : edited
        lastSyncedConfig = edited
        adopt(applied)
        // A value the file could not hold as written was repaired. Writing
        // the repaired snapshot once makes the file show the value in use;
        // the watcher recognizes that write as TextMouth's own. Otherwise the
        // file stays exactly as its editor saved it.
        if Self.decodingRepairedValues(in: contents, decoded: edited) {
            saveToDisk()
        }
    }

    /// Whether decoding `contents` into `decoded` changed a value the file
    /// states: a number clamped into range, an unsupported choice dropped, or
    /// a value of the wrong type replaced. Layout, missing and null fields,
    /// and keys TextMouth does not use are not repairs, so a hand-edited
    /// file is never rewritten for its form alone.
    nonisolated static func decodingRepairedValues(in contents: Data, decoded: AppConfig) -> Bool {
        // Contents that only the lenient decoder could read, such as a number
        // too large to represent, had something replaced.
        guard let stated = (try? JSONSerialization.jsonObject(with: contents)) as? [String: Any] else {
            return true
        }
        guard let used = try? jsonFields(of: decoded) else {
            return false
        }
        return stated.contains { key, value in
            guard !(value is NSNull), let usedValue = used[key] else {
                return false
            }
            return !sameJSONValue(value, usedValue)
        }
    }

    /// Folds in an edit that reached config.json after this process last
    /// wrote or read it, which the watcher has not handled yet because its
    /// events are still settling. The save about to happen would otherwise
    /// replace it unseen.
    ///
    /// The merged snapshot is published like any external edit, so the
    /// preferences take the edit's values too. Contents that cannot be
    /// decoded are logged; the save then replaces them.
    private func mergeUnhandledEdit(_ contents: Data) {
        lastHandledContents = contents
        let edited: AppConfig
        do {
            edited = try Self.decode(contents)
        } catch {
            log("saving over \(fileURL.path), which could not be read. \(Self.failureReason(error))")
            return
        }
        // Without a known base, the edit on disk is taken whole.
        adopt(Self.merging(ours: config, theirs: edited, base: lastSyncedConfig ?? config))
    }

    /// Makes `snapshot`, which came from the file, the configuration in use,
    /// and publishes it once.
    private func adopt(_ snapshot: AppConfig) {
        config = snapshot
        externalEdits.send(snapshot)
    }

    /// Combines an edit found on disk (`theirs`) with the changes this
    /// process made since it last agreed with the file (`base`): a field this
    /// process changed keeps its value, and every other field takes the
    /// edit's. When both changed a field, this process's value wins, being
    /// the later change: the edit was already on disk when this process saved.
    /// A field holding an object, such as the shortcuts of every action, is
    /// merged entry by entry the same way, so this process's change to one
    /// action's shortcuts and the edit's change to another's both stand.
    ///
    /// Fields are compared as config.json holds them, so the merge follows
    /// `AppConfig`'s coding keys and needs no list of fields of its own.
    nonisolated static func merging(ours: AppConfig, theirs: AppConfig, base: AppConfig) -> AppConfig {
        guard let oursFields = try? jsonFields(of: ours),
              let baseFields = try? jsonFields(of: base),
              let theirsFields = try? jsonFields(of: theirs) else {
            return ours
        }
        let mergedFields = mergedJSONObject(ours: oursFields, theirs: theirsFields, base: baseFields)
        guard let data = try? JSONSerialization.data(withJSONObject: mergedFields),
              let merged = try? decode(data) else {
            return ours
        }
        return merged
    }

    /// One JSON object merged: `theirs`, with each entry this process changed
    /// from `base` taking this process's value. An entry that is an object on
    /// all three sides is merged the same way, one level further in; any
    /// other changed entry is taken whole.
    private nonisolated static func mergedJSONObject(
        ours: [String: Any],
        theirs: [String: Any],
        base: [String: Any]
    ) -> [String: Any] {
        var merged = theirs
        for (key, value) in ours where !sameJSONValue(value, base[key]) {
            if let oursObject = value as? [String: Any],
               let theirsObject = theirs[key] as? [String: Any],
               let baseObject = base[key] as? [String: Any] {
                merged[key] = mergedJSONObject(ours: oursObject, theirs: theirsObject, base: baseObject)
            } else {
                merged[key] = value
            }
        }
        return merged
    }

    /// `config` as the JSON object config.json holds, keyed by field name.
    private nonisolated static func jsonFields(of config: AppConfig) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: fileData(for: config))
        guard let fields = object as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }
        return fields
    }

    /// Whether two values that JSONSerialization produced are equal. They are
    /// all NSObjects, which compare by value; two missing values are equal.
    private nonisolated static func sameJSONValue(_ lhs: Any?, _ rhs: Any?) -> Bool {
        guard let lhs = lhs as? NSObject, let rhs = rhs as? NSObject else {
            return lhs == nil && rhs == nil
        }
        return lhs.isEqual(rhs)
    }

    // MARK: - File Watching

    /// Acts on a settled batch of file events: follows the file when it was
    /// replaced, and applies its contents when they hold an edit this process
    /// has neither written nor seen. The watcher calls this once a burst of
    /// events settles; tests call it directly.
    func handleFileEvent(_ event: DispatchSource.FileSystemEvent) {
        // A file in a data directory found unavailable is not this library's
        // settings to apply (FR02); it is reconciled when the library is back.
        guard !isFileUnavailable else { return }
        let contents = readFileContents()
        let actions = Self.watcherActions(
            for: event,
            fileContents: contents,
            lastHandledContents: lastHandledContents
        )
        // A file replaced again after the read above is checked once more
        // when the watcher attaches to it, so the order here loses nothing.
        if actions.rearm {
            rearmWatcher()
        }
        if actions.reload, let contents {
            applyExternalEdit(contents)
        }
    }

    /// Collects an event from the watched file's source, on the main actor.
    /// A replacement is followed at once, so no edit to the new file goes
    /// unreported while the burst settles; the batch goes to
    /// `handleFileEvent(_:)` once no further event has arrived for
    /// `coalescingDelay`.
    private func receiveFileEvent(_ event: DispatchSource.FileSystemEvent) {
        guard isWatching else { return }
        if Self.replacesWatchedFile(event) {
            rearmWatcher()
        }
        pendingEvents.formUnion(event)
        scheduleCheck()
    }

    /// Checks the file once `coalescingDelay` passes without a new event,
    /// handling every event collected until then as one batch: an editor's
    /// save arrives as several events, and a file written in place may be
    /// incomplete until they end.
    private func scheduleCheck() {
        pendingCheck?.cancel()
        pendingCheck = Task { [weak self, coalescingDelay] in
            try? await Task.sleep(for: coalescingDelay)
            guard !Task.isCancelled, let self else { return }
            let events = self.pendingEvents
            self.pendingEvents = []
            self.pendingCheck = nil
            self.handleFileEvent(events)
        }
    }

    /// Moves the watcher to the file now at `fileURL`.
    ///
    /// When no file is there, an editor may be partway through a save that
    /// removes or renames the old file before putting the new one in place,
    /// so the watcher looks again a few times before giving up until the
    /// next save.
    private func rearmWatcher() {
        guard isWatching else { return }
        // Nothing in a data directory found unavailable is watched (FR02);
        // reconciling the file when the library is back rearms the watcher.
        guard !isFileUnavailable else {
            disarm()
            return
        }
        if armWatcher() {
            rearmRetry?.cancel()
            rearmRetry = nil
            return
        }
        // The watched file is gone or renamed away: stop listening to it.
        disarm()
        guard rearmRetry == nil else { return }
        rearmRetry = Task { [weak self] in
            await self?.lookForMissingFile()
        }
    }

    /// Looks for the file after each of `rearmRetryDelays`, watching it as
    /// soon as it is back. Giving up is logged.
    private func lookForMissingFile() async {
        for delay in Self.rearmRetryDelays {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, isWatching else { return }
            if armWatcher() {
                rearmRetry = nil
                return
            }
        }
        rearmRetry = nil
        log("\(fileURL.path) is missing; watching resumes when TextMouth next saves the settings")
    }

    /// Attaches the watcher to the file now at `fileURL`, unless it already
    /// listens to that very file, and returns whether a file is watched.
    ///
    /// A newly attached file is checked once events settle: an edit saved
    /// before the watcher attached reports no event of its own, so the check
    /// is what keeps the moment between two watched files covered.
    @discardableResult
    private func armWatcher() -> Bool {
        guard !isFileUnavailable else { return false }
        // Identify the file before opening it. A replacement in between makes
        // the next rearm see a different file and open it again: one open too
        // many at worst, never an edit missed.
        guard let identity = FileIdentity(of: fileURL) else { return false }
        if watchedFile?.identity == identity { return true }
        let descriptor = fileOperations.openForEvents(fileURL.path)
        guard descriptor >= 0 else { return false }
        disarm()

        // The source delivers on the main queue, where all of the watcher's
        // state lives: the handler only passes the event mask on, so nothing
        // is read from another thread.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: Self.watchedEvents,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.receiveFileEvent(source.data)
            }
        }
        // Dispatch runs this once the source has stopped using the
        // descriptor, the only safe moment to close it.
        let close = fileOperations.close
        source.setCancelHandler {
            MainActor.assumeIsolated {
                close(descriptor)
            }
        }
        source.resume()
        watchedFile = WatchedFile(identity: identity, source: source)
        scheduleCheck()
        return true
    }

    /// Stops listening to the watched file. Cancelling its source closes the
    /// descriptor, and releases the handlers that hold the source.
    private func disarm() {
        watchedFile?.source.cancel()
        watchedFile = nil
    }

    // MARK: - Diagnostics

    /// Records a config.json event in the console and the debug log, as
    /// `CONFIG_FILE: <message>`, an event of the storage category
    /// (`DiagnosticLog`). The policy names the file by its path inside the
    /// data directory (`config.json`), never by its absolute path.
    private func log(_ message: String) {
        DiagnosticLog.event(.storage, "CONFIG_FILE: \(message)")
    }

    /// Records that config.json could not be used, and that the settings in
    /// use were kept.
    private func logUnreadableFile(_ error: Error) {
        log("could not read \(fileURL.path); keeping the settings in use. \(Self.failureReason(error))")
    }

    /// Why decoding failed, in one line: the decoder's summary, then the
    /// parser's account of where the text went wrong when it gives one, such
    /// as "Unexpected character ',' around line 1, column 24."
    private nonisolated static func failureReason(_ error: Error) -> String {
        guard case DecodingError.dataCorrupted(let context) = error else {
            return String(describing: error)
        }
        let detail = (context.underlyingError as NSError?)?.userInfo[NSDebugDescriptionErrorKey] as? String
        return [context.debugDescription, detail].compactMap { $0 }.joined(separator: " ")
    }
}

/// How to handle original files after import
enum ImportDeleteBehavior: String, Codable, CaseIterable {
    case keepOriginal = "Keep Original"
    case deleteAfterImport = "Delete After Import"
    case askEachTime = "Ask Each Time"

    var description: String { rawValue }
}
