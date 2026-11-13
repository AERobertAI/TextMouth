import XCTest
@testable import TextMouth

/// Pins what 0.2.0 writes to disk: the names that library.json, config.json,
/// and each package's records are made of, and the versions that say how a
/// file was written, so that changing any of them is a deliberate step a
/// review sees and never a side effect of another change. Every value is
/// compared against a literal, never against the code's own constant, so a
/// rename fails here even when every other test still passes.
///
/// Pinned elsewhere, and so not pinned again here:
/// - the text cache format "3.0.7": `BookContentIndexTests`,
///   `MetadataReaderVersionTests`, and `TextAnchorFineWordsTests`;
/// - the metadata reader's version: `MetadataReaderVersionTests`;
/// - the order of `SkipUnit`'s cases: `PageNavigationTests`
///   (`testThePageUnitIsBetweenParagraphAndHeading`), which does not pin
///   their saved names, pinned here;
/// - what the Record window's and the Bookmarks menu's former shortcut
///   names read as: `MenuKeyShortcutTests`
///   (`testNamesReadWithOrWithoutTheirEllipsis`) and
///   `ImportAndShortcutPolicyTests`; the whole table of former names is
///   pinned here;
/// - the file names bookInfo.json, content.md, and cachedAudio:
///   `LibraryFeedItemEditTests.testAPackagesOwnFilesAreNeverItsContent`,
///   and the folder .convertedOriginals: `ConvertedOriginalTests`.
final class OnDiskContractTests: XCTestCase {
    // MARK: - What Each Assertion Says

    /// The message of an assertion: what changed, what it forces, and where
    /// the plan explains why the value is pinned.
    private static func because(_ what: String, _ forces: String) -> String {
        "\(what) changed: \(forces). See PLAN-0.2.0-2026-10-23.md, V02."
    }

    /// What a changed `BookFormat` forces.
    private static let formatForces = "a TextMouth built before it refuses the whole library"

    /// What a changed row or record key forces.
    private static let keyForces =
        "that field is lost for every book, and a key added is dropped by an older TextMouth at its next write"

    /// What a fixture that leaves a field unset means for the keys it pins.
    private static func unset(_ what: String) -> String {
        "the fixture leaves \(what) unset, so the keys pinned prove nothing about it. See PLAN-0.2.0-2026-10-23.md, V02."
    }

    // MARK: - Saved Names (library.json, config.json)

    /// Every `BookFormat` is saved by its raw value, in library.json and in
    /// each package's record, in this order.
    ///
    /// "mobi" (FMT42, November 4, 2026) was added deliberately at the end: a
    /// TextMouth built before it refuses a library that holds a Kindle book,
    /// as 0.2.0's eight formats did, so the orchestrator raises the version's
    /// MINOR and the changelog cautions the user. "kfx" (FMT52, November 6,
    /// 2026) was added deliberately after it, for the same reason.
    func testEveryBookFormatIsSavedUnderItsOwnName() {
        XCTAssertEqual(
            BookFormat.allCases.map(\.rawValue),
            [
                "epub", "txt", "markdown", "html", "webarchive", "ssml", "docx", "rtf", "rtfd", "doc", "odt",
                "wordml", "braille", "daisy", "pdf", "audio", "mobi", "kfx",
            ],
            Self.because("a BookFormat's raw value, or the cases", Self.formatForces)
        )
    }

    /// A skip unit is saved by its raw value in config.json and in each
    /// book's own settings.
    func testEverySkipUnitIsSavedUnderItsOwnName() {
        XCTAssertEqual(
            SkipUnit.allCases.map(\.rawValue),
            [
                "10 seconds", "15 seconds", "30 seconds", "60 seconds", "Sentence", "Paragraph", "Page", "Heading",
                "Subheading", "Bookmark",
            ],
            Self.because("a SkipUnit's raw value", "an older TextMouth reads the saved unit as the default")
        )
    }

    /// A sort field is saved by its raw value in library.json's sort
    /// settings, and so is a library category in the preferences.
    func testEverySortFieldAndCategoryIsSavedUnderItsOwnName() {
        XCTAssertEqual(
            LibrarySortField.allCases.map(\.rawValue),
            ["Title", "Author", "Date Added", "Last Opened", "File Size", "Manual Order"],
            Self.because("a LibrarySortField's raw value, or the cases", "an older TextMouth refuses library.json")
        )
        XCTAssertEqual(
            LibraryCategory.allCases.map(\.rawValue),
            ["Folders", "All Items", "Unopened", "Recently Opened", "Reading List"],
            Self.because("a LibraryCategory's raw value", "the saved category is lost")
        )
    }

    /// Every shortcut action is saved in config.json under its raw value,
    /// the name Settings shows, in this order.
    func testEveryShortcutActionIsSavedUnderItsOwnName() {
        XCTAssertEqual(
            ShortcutAction.allCases.map(\.rawValue),
            [
                "Play / Pause",
                "Release Media Controls",
                "Skip Forward",
                "Skip Backward",
                "Cycle Forward Navigation Unit",
                "Cycle Backward Navigation Unit",
                "Increase Speed",
                "Decrease Speed",
                "Copy Reading Position",
                "Search in Book",
                "Go to Library",
                "Go Back",
                "Go Forward",
                "Next Heading",
                "Previous Heading",
                "Go to Page…",
                "Next in Reading List",
                "Previous in Reading List",
                "Next in Folder",
                "Previous in Folder",
                "Up One Level",
                "Toggle Bookmark",
                "Next Bookmark",
                "Previous Bookmark",
                "Show Bookmarks",
                "Show Headings",
                "Show Sleep Timer",
                "Restart Sleep Timer",
                "Where Am I?",
                "Where Am I? Full Summary",
                "Speak Info",
                "Speak Full Info",
                "Speak Import Progress",
                "Speak Download Progress",
                "Open Selected Book",
                "Book Info",
                "Remove from Library",
                "New Folder",
                "Move to Folder",
                "Move to Library…",
                "Select All",
                "Edit Mode",
                "Move Book Up",
                "Move Book Down",
                "Add to Reading List",
                "Remove from Reading List",
                "Folder or Feed Settings",
                "Go to View 1",
                "Go to View 2",
                "Go to View 3",
                "Go to View 4",
                "Go to View 5",
                "Go to View 6",
                "Go to View 7",
                "Go to View 8",
                "Go to View 9",
                "Import Folder…",
                "Add Feed…",
                "Search Library…",
                "Open Book…",
                "New from Text…",
                "New Recording…",
                "New Recording: Record",
                "New Recording: Pause or Resume",
                "New Recording: Stop",
                "Audio Editor: Play / Pause",
                "Audio Editor: Stop",
                "Audio Editor: Back One Second",
                "Audio Editor: Forward One Second",
                "Audio Editor: Back 10 Seconds",
                "Audio Editor: Forward 10 Seconds",
                "Audio Editor: Back a Tenth of a Second",
                "Audio Editor: Forward a Tenth of a Second",
                "Audio Editor: Go to Start",
                "Audio Editor: Go to End",
                "Audio Editor: Go to Time…",
                "Audio Editor: Previous Chapter Marker",
                "Audio Editor: Next Chapter Marker",
                "Audio Editor: Previous Pause",
                "Audio Editor: Next Pause",
                "Audio Editor: Where Am I?",
                "Audio Editor: Mark In",
                "Audio Editor: Mark Out",
                "Audio Editor: Select to Previous Pause",
                "Audio Editor: Select to Next Pause",
                "Audio Editor: Select Chapter",
                "Audio Editor: Select All",
                "Audio Editor: Clear Selection",
                "Audio Editor: Speak Selection",
                "Audio Editor: Play Selection",
                "Audio Editor: Add Marker",
                "Audio Editor: Markers and Pauses…",
                "Audio Editor: Undo",
                "Audio Editor: Redo",
                "Audio Editor: Cut",
                "Audio Editor: Copy",
                "Audio Editor: Paste",
                "Audio Editor: Trim to Selection",
                "Audio Editor: Insert Silence…",
                "Audio Editor: Insert Chapter Marker…",
                "Audio Editor: Apply Filter…",
                "Audio Editor: Punch In",
                "Audio Editor: Save",
                "Audio Editor: Export…",
                "Audio Editor: Revert to Original…",
                "Audio Editor: Audio Info…",
            ],
            Self.because(
                "a shortcut action's name",
                "the user's own shortcut for it is lost, unless its old name is in ShortcutAction.formerNames"
            )
        )
    }

    /// An action renamed since an earlier release is still read under its
    /// former name; the whole table is pinned, since losing a row loses the
    /// shortcuts the user gave that action under the old name.
    func testEveryFormerShortcutNameStillNamesItsAction() {
        XCTAssertEqual(
            ShortcutAction.formerNames.mapValues(\.rawValue),
            [
                "Recording Window: Record": "New Recording: Record",
                "Recording Window: Pause or Resume": "New Recording: Pause or Resume",
                "Recording Window: Stop": "New Recording: Stop",
                "Add Bookmark": "Toggle Bookmark",
                "Import DAISY Folder…": "Import Folder…",
            ],
            Self.because("a shortcut action's former name", "the user's own shortcut for it is lost")
        )
    }

    // MARK: - Keys (config.json, library.json, bookInfo.json)

    /// The keys of config.json, written with every optional setting set.
    /// An optional left out of the fixture would be left out of the file
    /// too, so the keys are also checked against the properties.
    func testConfigJSONHoldsExactlyTheseKeys() throws {
        let config = Self.configWithEverySettingSet()
        let object = try Self.object(from: ConfigService.fileData(for: config))
        let expected: Set<String> = [
            "selectedVoiceID", "wordsPerMinute", "pitchMultiplier", "selectedLanguage", "skipForwardUnit",
            "skipBackwardUnit", "importDeleteBehavior", "dataDirectoryPath", "confirmBeforeDelete",
            "shiftSkipForwardUnit", "shiftSkipBackwardUnit", "rewindOnResumeUnit", "rewindSmartMode",
            "rewindSmartThreshold", "sleepFadeOutDuration", "sleepTimerAutoClose", "endOfBookBehavior",
            "nextBookWindow", "punctuationPauseLevel", "lastOpenedBookID", "autoPlayOnNavigate", "moveToTrashInsteadOfDeleting",
            "keepsOriginalOfConvertedAudio", "bluetoothMonitoringEnabled", "bluetoothDisconnectDelay",
            "restartTimerGestureEnabled", "restartTimerGesturePattern", "restartTimerGestureWindow",
            "playbackNavigationUnitControlMode", "showBookmarkInPlaybackControls", "showSpeedInPlaybackControls",
            "showExportInReaderToolbar", "includeSpeedWithTimes", "showsPageInReader", "saysPageInWhereAmI",
            "soundEffectsEnabled", "soundEffectsVolume", "soundEffectAssignments", "substitutionsEnabled",
            "repeatedSymbolStyle", "repeatedSymbolThreshold", "repeatedSymbolSet", "recordingInputDeviceID",
            "recordingAnnouncesLevel", "recordingLevelAnnouncementSeconds", "recordingOriginalPolicy",
            "recordingOriginalDays", "useInstalledFFmpeg", "audioEditorPreviewsFilters",
            "libraryViews",
            "audioEditorPlaysAfterMoves", "keyboardShortcuts", "shortcutDoublePressSeconds", "feedRefreshAtLaunch",
            "feedRefreshIntervalHours", "feedItems", "feedNewestCount", "feedDeleteDownloadsDaysAfterPlayed",
            "feedRefreshAlert", "feedNotifications", "logLocation", "transcriptionLocale",
            "offerTranscriptionAfterImport", "brailleTable", "brailleFileCode",
        ]
        XCTAssertEqual(
            Set(object.keys),
            expected,
            Self.because(
                "a config.json key",
                "the user's setting is lost, and an older TextMouth drops a new key at its next write"
            )
        )
        XCTAssertEqual(Self.propertyNames(of: config), expected, Self.unset("a setting"))
    }

    /// The keys of library.json's four sections and of a library row, written
    /// with every field set but the feed link, which a library's own book
    /// never carries (a feed item's row lives in its feed's index).
    func testALibraryRowHoldsExactlyTheseKeys() throws {
        var book = Self.bookWithEveryFieldSet()
        book.feedLink = nil
        let file = try Self.object(from: LibraryPersistenceService.encodedIndex(Library(books: [book])))
        XCTAssertEqual(
            Set(file.keys),
            ["books", "folders", "folderSortSettings", "readingList"],
            Self.because("a library.json section", "an older TextMouth drops a new section at its next write")
        )
        let rows = try XCTUnwrap(file["books"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first)
        let expected: Set<String> = [
            "id", "title", "author", "format", "filePath", "md5Hash", "folderPath", "dateAdded", "lastOpened",
            "readingPosition", "bookmarks", "totalWordCount", "totalCharacterCount", "tmbDirectoryName",
            "sourceFilePath", "lastPlaybackStarted", "lastPlaybackStopped", "localVoiceID", "localWPM",
            "localPitch", "skippedHeadingIDs", "skippedHeadings", "waitingSkippedHeadings",
            "localEndOfBookBehavior", "localSkipForwardUnit", "localSkipBackwardUnit", "manualSortOrder",
            "audioDuration", "audioAlbum", "audioGenre", "audioYear", "epubPublisher", "epubPublicationDate",
            "epubISBN", "epubLanguage", "epubIdentifier", "epubVersion", "cacheFormatVersion",
            "contentIndexVersion", "textCacheFingerprint", "editedText", "pageReaderVersion",
            "metadataReaderVersion", "handEdits", "brailleTable", "brailleTableVersion",
            // braillecodes: the braille file characters a BRF or BRL book is read with, by the code's id. An
            // optional key, read leniently; an older TextMouth drops it, and the book then reads as North
            // American Braille ASCII.
            "brailleFileCode",
            // FMT16: the encoding a text book's file was guessed to be in. An optional key, written only for
            // a book imported with a guess, so every other row is exactly as it was.
            "textEncoding",
            // encodingchoice: who decided that encoding, "chosen" or "automatic", when the listener chose
            // in Book Information. An optional key, read leniently, written only for such a book; an older
            // TextMouth drops it, and the chosen encoding then reads as a guess of the same encoding.
            "textEncodingSource",
        ]
        XCTAssertEqual(Set(row.keys), expected, Self.because("a library row's key", Self.keyForces))
        // Every property but the feed link is a key; the feed link is the
        // feed index's, never library.json's.
        XCTAssertEqual(
            Self.propertyNames(of: book).subtracting(["feedLink"]),
            expected,
            Self.unset("a field")
        )
    }

    /// The keys of a package's bookInfo.json, in its three sections, with
    /// every field set. The content index is a file of its own.
    func testAPackageRecordHoldsExactlyTheseKeys() throws {
        let book = Self.bookWithEveryFieldSet()
        var info = book.bookInfo(replacing: nil, contentIndex: nil)
        info.state.transcript = TranscriptNote(version: 1, locale: "en-US", createdAt: Self.date)
        let record = try Self.object(from: Self.recordEncoder.encode(info))
        XCTAssertEqual(
            Set(record.keys),
            ["metadata", "state", "bookmarks"],
            Self.because("a bookInfo.json section", Self.keyForces)
        )

        let metadata = try XCTUnwrap(record["metadata"] as? [String: Any])
        let expectedMetadata: Set<String> = [
            "title", "author", "format", "md5Hash", "dateAdded", "lastOpened", "originalFileName", "folderPath",
            "bookID", "sourceFilePath", "publisher", "publicationDate", "isbn", "language", "epubIdentifier",
            "epubVersion", "audioAlbum", "audioGenre", "audioYear", "metadataReaderVersion", "handEdits",
            "feedLink", "brailleTable", "brailleTableVersion",
            // braillecodes: the braille file code, as in a library row.
            "brailleFileCode",
            // FMT16, and encodingchoice's source, as in a library row.
            "textEncoding", "textEncodingSource",
        ]
        XCTAssertEqual(
            Set(metadata.keys),
            expectedMetadata,
            Self.because("a bookInfo.json metadata key", Self.keyForces)
        )
        XCTAssertEqual(Self.propertyNames(of: info.metadata), expectedMetadata, Self.unset("a metadata field"))

        let state = try XCTUnwrap(record["state"] as? [String: Any])
        let expectedState: Set<String> = [
            "readingPosition", "totalWordCount", "totalCharacterCount", "isNew", "tmbDirectoryName",
            "lastPlaybackStarted", "lastPlaybackStopped", "localVoiceID", "localWPM", "localPitch",
            "skippedHeadingIDs", "skippedHeadings", "waitingSkippedHeadings", "localEndOfBookBehavior",
            "localSkipForwardUnit", "localSkipBackwardUnit", "manualSortOrder", "audioDuration",
            "cacheFormatVersion", "contentIndexVersion", "textCacheFingerprint", "editedText", "pageReaderVersion",
            "transcript", "revision",
        ]
        XCTAssertEqual(Set(state.keys), expectedState, Self.because("a bookInfo.json state key", Self.keyForces))
        XCTAssertEqual(Self.propertyNames(of: info.state), expectedState, Self.unset("a state field"))
    }

    /// The keys of the records inside a row that hold the user's places: the
    /// reading position, a bookmark, a skipped heading, and the anchor each
    /// carries.
    func testTheRecordsOfAUsersPlacesHoldExactlyTheseKeys() throws {
        var book = Self.bookWithEveryFieldSet()
        book.feedLink = nil
        let file = try Self.object(from: LibraryPersistenceService.encodedIndex(Library(books: [book])))
        let rows = try XCTUnwrap(file["books"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first)

        let position = try XCTUnwrap(row["readingPosition"] as? [String: Any])
        XCTAssertEqual(
            Set(position.keys),
            ["chapterIndex", "headingIndex", "characterOffset", "globalCharacterOffset", "lastUpdated", "anchor"],
            Self.because("a reading position's key", Self.keyForces)
        )
        let bookmarks = try XCTUnwrap(row["bookmarks"] as? [[String: Any]])
        let bookmark = try XCTUnwrap(bookmarks.first)
        XCTAssertEqual(
            Set(bookmark.keys),
            ["id", "number", "chapterIndex", "characterOffset", "label", "dateCreated", "anchor"],
            Self.because("a bookmark's key", Self.keyForces)
        )
        let skips = try XCTUnwrap(row["skippedHeadings"] as? [[String: Any]])
        let skip = try XCTUnwrap(skips.first)
        XCTAssertEqual(
            Set(skip.keys),
            ["level", "label", "chapterIndex", "characterOffset", "anchor"],
            Self.because("a skipped heading's key", Self.keyForces)
        )
        let anchor = try XCTUnwrap(position["anchor"] as? [String: Any])
        XCTAssertEqual(
            Set(anchor.keys),
            ["before", "after", "fraction", "measuredIn", "version"],
            Self.because("a text anchor's key", Self.keyForces)
        )
    }

    /// The keys of the removal marker Remove from Library Only writes into a
    /// package (removedFromLibrary.json), as it writes them, from a book with
    /// every field set. The marker is all a book added back keeps of its
    /// deleted bookInfo.json.
    func testARemovalMarkerHoldsExactlyTheseKeys() throws {
        let marker = RemovedFromLibraryMarker(book: Self.bookWithEveryFieldSet(), removedAt: Self.date)
        let package = try makeSandboxDirectory("Removal Marker Keys")
        try marker.write(into: package)
        let written = try Self.object(from: Data(contentsOf: TextMouthPaths.removedFromLibraryMarkerPath(in: package)))
        let expected: Set<String> = [
            "bookID", "title", "author", "removedAt", "brailleTable", "brailleTableVersion", "textEncoding",
            "textEncodingSource",
            // B12: the record of an edit taken with Edit Text and the fingerprints of the text cache, so that a
            // book added back keeps the text the user changed. Optional keys, read leniently; an older
            // TextMouth ignores them, and reads the book's file over the edit as it always did.
            "editedText", "textCacheFingerprint",
            // The braille file characters a BRF or BRL is read in (braillecodes), so that a book added back
            // reads in the code it was read in. An optional key; an older TextMouth ignores it, and reads the
            // file as North American Braille ASCII, as it always did.
            "brailleFileCode",
        ]
        XCTAssertEqual(
            Set(written.keys),
            expected,
            Self.because("a removal marker's key", "a book added back from a marker written before loses that field")
        )
        XCTAssertEqual(Self.propertyNames(of: marker), expected, Self.unset("a marker field"))
    }

    // MARK: - File and Folder Names

    /// The names of the files and folders in the data directory and in
    /// each package, besides those pinned elsewhere (see the class).
    func testTheFilesAndFoldersTextMouthKeepsAreNamedAsBefore() {
        let why = "an older TextMouth no longer finds it"
        // The data directory.
        XCTAssertEqual(
            TextMouthPaths.dataDirectoryName,
            ".TextMouth", // lint-ok: a name compared with a literal; no path is built, read, or written
            Self.because("the data directory's name", why)
        )
        XCTAssertEqual(TextMouthPaths.libraryFolderName, "Library", Self.because("the Library folder's name", why))
        XCTAssertEqual(TextMouthPaths.logsFolderName, "Logs", Self.because("the Logs folder's name", why))
        XCTAssertEqual(FeedPaths.recordsFolderName, "Feeds", Self.because("the Feeds folder's name", why))
        XCTAssertEqual(
            [
                TextMouthPaths.configFile, TextMouthPaths.libraryIndexFile, TextMouthPaths.readingCheckpointsFile,
                TextMouthPaths.substitutionsFile, TextMouthPaths.readingStatsFile,
            ].map(\.lastPathComponent),
            ["config.json", "library.json", "reading-checkpoints.json", "substitutions.json", "reading_stats.json"],
            Self.because("a file in the data directory", why)
        )
        XCTAssertEqual(
            AudioFilterPresetLibrary.fileName,
            "audio-filters.json",
            Self.because("the audio filters' file", why)
        )
        XCTAssertEqual(FeedPaths.indexFileName, "library.json", Self.because("a feed's index file", why))
        // A package.
        XCTAssertEqual(
            TextMouthPaths.contentIndexFileName,
            "contentIndex.json",
            Self.because("the content index's file", why)
        )
        XCTAssertEqual(
            TextMouthPaths.removedFromLibraryMarkerName,
            "removedFromLibrary.json",
            Self.because("the removed-from-library marker", why)
        )
        XCTAssertEqual(
            TextMouthPaths.transcriptFileName,
            "transcript.json",
            Self.because("the transcript's file", why)
        )
        XCTAssertEqual(
            TextMouthPaths.transcriptBeforeCleanupFileName,
            "transcript.json.before-cleanup",
            Self.because("the transcript's copy from before a cleanup", why)
        )
        XCTAssertEqual(TextMouthPaths.keptTextCopyMarker, ".edited-", Self.because("a kept copy of edited text", why))
        XCTAssertEqual(BookOrigin.fileName, "origin.json", Self.because("a package's origin record", why))
        XCTAssertEqual(
            BookOrigin.originalTakeFileName,
            "original-take.caf",
            Self.because("a recording's original take", why)
        )
        XCTAssertEqual(AudioEditPackage.folderName, "audioEdits", Self.because("the audio edit folder", why))
        XCTAssertEqual(
            AudioEditPackage.historyFileName,
            "edits.json",
            Self.because("the audio edit history's file", why)
        )
        XCTAssertEqual(
            AudioEditPackage.originalsFolderName,
            "originals",
            Self.because("the audio edit originals' folder", why)
        )
        XCTAssertEqual(
            AudioEditPackage.takesFolderName,
            "takes",
            Self.because("the audio edit takes' folder", why)
        )
        // The copy of the text a rebuild keeps on this Mac, and the reading
        // texts kept on it.
        XCTAssertEqual(PlaceSnapshot.textFileName, "content.md", Self.because("a place snapshot's text file", why))
        XCTAssertEqual(PlaceSnapshot.recordFileName, "places.json", Self.because("a place snapshot's record", why))
        XCTAssertEqual(
            ReadingTextCache.fileExtension,
            "readingtext",
            Self.because("a reading text file's extension", why)
        )
    }

    // MARK: - Versions

    /// The version of the content index, whose change has every book
    /// indexed again.
    func testTheContentIndexVersion() {
        XCTAssertEqual(
            BookContentIndex.currentVersion,
            "1.0.0",
            Self.because("the content index version", "every book is indexed again at the next launch")
        )
    }

    /// Each page reader's version: the formats with pages, and that no
    /// other format has one.
    func testThePageReaderVersions() {
        let withPages = ["epub", "html", "pdf", "docx", "daisy", "rtf", "rtfd", "doc", "odt", "wordml", "braille", "txt", "kfx", "mobi"]
        let forces = "every book of that format is read again at the next launch (V05, V07)"
        var versions: [String: String] = [:]
        var withoutPages: Set<String> = []
        for format in BookFormat.allCases {
            if let version = PageReaderVersions.current(for: format) {
                versions[format.rawValue] = version
            } else {
                withoutPages.insert(format.rawValue)
            }
        }
        // EPUB and HTML were at 1.0.1 from October 24, 2026: their converter
        // left a page-break element's number out of the label of a heading
        // that holds one, which changed those books' reading text. On
        // November 4, 2026 they went to 1.0.2, where a label of only the
        // word "Page" names no page and an EPUB page list that labels none
        // of its pages is passed over, and then to 1.0.3, where a label's
        // leading "Page" is taken off; both changed those books' pages, and
        // their text where a page-break element holds its page's number.
        XCTAssertEqual(
            versions,
            Dictionary(uniqueKeysWithValues: withPages.map { name -> (String, String) in
                // Rich text and Word 97-2003 went to TextMouth's own readers (FMT47) at 1.1.0;
                // rich text is at 1.2.0 (deleted text, a number in a cell, notes), DOCX at
                // 1.1.0 (hidden text, text boxes once, notes), 1.2.0 (hidden text of
                // table styles and document defaults), and 1.3.0 (symbols by font), and
                // Word 6 to Word 2003 at 1.3.0
                // (1.2.0: hidden text, piece formatting, list numbers, and text boxes; 1.3.0:
                // Word 6 and Word 95). OpenDocument text and Word 2003 XML went to TextMouth's
                // own readers at 1.1.0; Word 2003 XML is at 1.2.0 (a row marked hidden hides
                // nothing of its own) and 1.3.0 (symbols by font).
                let raised = [
                    "epub": "1.0.3", "html": "1.0.4", "txt": "1.0.1", "rtf": "1.2.0", "rtfd": "1.2.0", "doc": "1.3.0",
                    "docx": "1.3.0", "odt": "1.1.0", "wordml": "1.3.0",
                ]
                // Kindle books (.mobi and .azw3) are at 1.1.0: soft hyphens left out of MOBI 6 books, and the KF8 chapter rule.
                return (name, raised[name] ?? (name == "mobi" ? "1.1.0" : "1.0.0"))
            }),
            Self.because("a page reader's version, or the formats with pages", forces)
        )
        XCTAssertEqual(
            withoutPages,
            ["markdown", "webarchive", "ssml", "audio"],
            Self.because("the formats without pages", forces)
        )
    }

    /// The layout versions of the reading-text cache and of the other files
    /// a newer TextMouth could write, and an older one would refuse or
    /// ignore.
    func testTheLayoutVersions() {
        XCTAssertEqual(
            ReadingTextCache.formatVersion,
            2,
            Self.because("the reading-text cache's layout version", "this Mac's kept reading texts are dropped")
        )
        let forces = "an older TextMouth refuses or ignores what a newer one wrote"
        XCTAssertEqual(Transcript.currentVersion, 1, Self.because("the transcript's layout version", forces))
        XCTAssertEqual(FeedIndex.currentFormatVersion, 1, Self.because("the feed index's layout version", forces))
        XCTAssertEqual(FeedRecord.currentFormatVersion, 1, Self.because("the feed record's layout version", forces))
        XCTAssertEqual(TextAnchor.currentVersion, 1, Self.because("the text anchor's version", forces))
        XCTAssertEqual(AudioEditHistory.currentVersion, 1, Self.because("the audio edit list's layout version", forces))
        XCTAssertEqual(
            TranscriptCleanupRuleSet.currentFormat,
            1,
            Self.because("the cleanup rules' layout version", forces)
        )
    }

    // MARK: - Fixtures

    /// The one date every fixture uses, to the second.
    private static let date = Date(timeIntervalSince1970: 1_700_000_000)

    /// How bookInfo.json is written (`BookInfo`'s own encoder is private).
    private static var recordEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    /// The top-level object of `data`, a JSON document.
    private static func object(from data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The names of `value`'s stored properties. A mirror shows the storage
    /// of a property wrapper as "_name" (`BookMetadata.textEncoding`), while
    /// the property, and its key in the file, are "name".
    private static func propertyNames(of value: Any) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap(\.label).map { $0.hasPrefix("_") ? String($0.dropFirst()) : $0 })
    }

    /// A config with every optional setting set, so each one is a key.
    private static func configWithEverySettingSet() -> ConfigService.AppConfig {
        var config = ConfigService.AppConfig()
        config.showBookmarkInPlaybackControls = true
        config.showSpeedInPlaybackControls = true
        config.showExportInReaderToolbar = true
        config.includeSpeedWithTimes = true
        config.showsPageInReader = true
        config.saysPageInWhereAmI = true
        config.soundEffectsEnabled = true
        config.soundEffectsVolume = 0.5
        config.substitutionsEnabled = true
        config.repeatedSymbolThreshold = 5
        config.repeatedSymbolSet = "*-="
        config.recordingAnnouncesLevel = true
        config.recordingLevelAnnouncementSeconds = 10
        config.recordingOriginalDays = 30
        config.useInstalledFFmpeg = true
        config.audioEditorPreviewsFilters = true
        config.audioEditorPlaysAfterMoves = true
        config.shortcutDoublePressSeconds = 0.5
        config.feedRefreshAtLaunch = true
        config.feedRefreshIntervalHours = 6
        config.feedNewestCount = 3
        config.feedDeleteDownloadsDaysAfterPlayed = 7
        config.feedRefreshAlert = true
        config.feedNotifications = true
        config.offerTranscriptionAfterImport = true
        config.libraryViews = LibraryViewDefinitionList.shipped.fileEntries
        return config
    }

    /// A book with every field set, its feed link included.
    private static func bookWithEveryFieldSet() -> Book {
        let anchor = TextAnchor(before: "before", after: "after", fraction: 0.5, measuredIn: "3.0.7/1.0.0")
        let skipped = SkippedHeading(level: 2, label: "Heading", chapterIndex: 1, characterOffset: 7, anchor: anchor)
        let waiting = SkippedHeading(level: 3, label: "Waiting", chapterIndex: 2, characterOffset: 9, anchor: anchor)
        let fingerprint = FileFingerprint(
            stamp: FileStamp(byteCount: 1_000, modificationTimeNanoseconds: 1_000_000_007),
            digest: "digest"
        )
        return Book(
            id: UUID(),
            title: "Title",
            author: "Author",
            format: .epub,
            filePath: "/library/book.epub",
            md5Hash: "hash",
            folderPath: "Folder",
            dateAdded: date,
            lastOpened: date.addingTimeInterval(1),
            readingPosition: ReadingPosition(
                chapterIndex: 3, headingIndex: 1, characterOffset: 30, globalCharacterOffset: 300, anchor: anchor
            ),
            bookmarks: [
                Bookmark(number: 1, chapterIndex: 1, characterOffset: 5, label: "Mark", dateCreated: date, anchor: anchor)
            ],
            totalWordCount: 100,
            totalCharacterCount: 500,
            tmbDirectoryName: "Package.tmb",
            sourceFilePath: "/sources/book.epub",
            lastPlaybackStarted: date.addingTimeInterval(2),
            lastPlaybackStopped: date.addingTimeInterval(3),
            localVoiceID: "voice",
            localWPM: 200,
            localPitch: 1.1,
            skippedHeadingIDs: [skipped.id],
            skippedHeadings: [skipped],
            waitingSkippedHeadings: [waiting],
            localEndOfBookBehavior: "behavior",
            localSkipForwardUnit: "forward",
            localSkipBackwardUnit: "backward",
            manualSortOrder: 4,
            audioDuration: 60,
            audioAlbum: "Album",
            audioGenre: "Genre",
            audioYear: "2000",
            epubPublisher: "Publisher",
            epubPublicationDate: "Published",
            epubISBN: "ISBN",
            epubLanguage: "en",
            epubIdentifier: "identifier",
            epubVersion: "3.0",
            cacheFormatVersion: "cache",
            contentIndexVersion: "index",
            textCacheFingerprint: TextCacheFingerprint(source: fingerprint, cache: fingerprint),
            editedText: EditedText(cacheDigest: "cache", takenAt: date.addingTimeInterval(4)),
            pageReaderVersion: "pages",
            metadataReaderVersion: "reader",
            handEdits: Book.HandEdits(fields: [.title], sinceImport: true),
            feedLink: FeedBookLink(feedID: UUID(), itemID: "item"),
            brailleTable: "table.ctb",
            brailleTableVersion: "liblouis",
            brailleFileCode: "ascii-eurobraille",
            textEncoding: "windows-1251",
            textEncodingSource: .chosen
        )
    }
}
