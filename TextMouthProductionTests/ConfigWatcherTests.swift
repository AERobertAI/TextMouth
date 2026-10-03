import Combine
import XCTest
@testable import TextMouth

/// How config.json and the preferences meet: loading the file, reconciling it
/// with the preferences at launch, and following edits saved from outside
/// TextMouth. Every test uses a config.json of its own inside the isolated
/// test root and, where preferences are involved, a throwaway preferences
/// suite, so neither the running test host nor the user's settings are
/// touched.
@MainActor
final class ConfigWatcherTests: XCTestCase {
    // MARK: - Loading

    /// The service holds the file's values as soon as it exists, so no
    /// consumer created afterwards can read the defaults in their place.
    func testNewServiceHoldsTheFileValuesAtOnce() throws {
        let url = try makeConfigFileURL()
        let saved = ConfigService.AppConfig.everyFieldCustomized
        try ConfigService.fileData(for: saved).write(to: url)

        let service = ConfigService(fileURL: url)

        XCTAssertEqual(service.config, saved)
        XCTAssertEqual(service.loadedFile, .decoded)
        XCTAssertTrue(service.hasExistingConfig)
    }

    /// Any decodable file is an existing config, including one that leaves
    /// speed unset (0) as older files do: it still holds every other setting.
    func testADecodableFileIsAnExistingConfigEvenWithSpeedUnset() throws {
        let url = try makeConfigFileURL()
        try Data(#"{"wordsPerMinute": 0, "confirmBeforeDelete": false}"#.utf8).write(to: url)

        let service = ConfigService(fileURL: url)

        XCTAssertTrue(service.hasExistingConfig)
        XCTAssertEqual(service.loadedFile, .decoded)
        XCTAssertFalse(service.config.confirmBeforeDelete)
    }

    /// Without a file there is no existing config, and the defaults stand.
    func testAMissingFileIsNoExistingConfig() throws {
        let service = ConfigService(fileURL: try makeConfigFileURL())

        XCTAssertFalse(service.hasExistingConfig)
        XCTAssertEqual(service.loadedFile, .missing)
        XCTAssertEqual(service.config, ConfigService.AppConfig())
    }

    /// A file that is not JSON is no existing config either: the defaults
    /// stand, and the debug log names the file once.
    func testAnUndecodableFileIsLoggedAndIsNoExistingConfig() throws {
        let url = try makeConfigFileURL()
        try Data(#"{"wordsPerMinute": 300,,}"#.utf8).write(to: url)

        let service = ConfigService(fileURL: url)

        XCTAssertFalse(service.hasExistingConfig)
        XCTAssertEqual(service.loadedFile, .unreadable)
        XCTAssertEqual(service.config, ConfigService.AppConfig())
        XCTAssertEqual(debugLogLines(containing: url.path).count, 1)
    }

    // MARK: - Launch

    /// Launch applies a file edited while TextMouth was closed over
    /// preferences that disagree with it everywhere (an empty store, whose
    /// defaults differ from every value in the file, and which names no
    /// voice), and leaves the file exactly as it was: no write, the same
    /// file, modification date, and bytes, even once the watcher has had
    /// time to act.
    func testLaunchAdoptsAnEditedFileAndLeavesItUntouched() throws {
        let url = try makeConfigFileURL()
        let edited = launchConsistentConfig()
        let bytes = try ConfigService.fileData(for: edited)
        try bytes.write(to: url)
        let stamp = try fileStamp(url)
        let counter = FileOperationCounter()

        let (service, settings) = launch(url, defaults: try isolatedDefaults(), counter: counter)
        settle()

        var mirrored = edited
        settings.writePreferences(into: &mirrored)
        XCTAssertEqual(mirrored, edited, "every preference takes the file's value")
        XCTAssertEqual(service.config, edited)
        XCTAssertEqual(counter.writes, 0)
        XCTAssertEqual(try fileStamp(url), stamp)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    /// A file an older TextMouth wrote (laid out differently, without the
    /// newer fields, with speed unset, and with one value out of range) is
    /// rewritten once at launch. The file's values and the repaired one are
    /// kept, the preferences fill in the rest, and nothing answers that write
    /// with another.
    func testLaunchRewritesAStaleFileExactlyOnce() throws {
        let url = try makeConfigFileURL()
        try Data("""
        {
            "selectedVoiceID": "com.apple.voice.compact.fr-FR.Thomas",
            "wordsPerMinute": 0,
            "confirmBeforeDelete": false,
            "punctuationPauseLevel": 40
        }
        """.utf8).write(to: url)
        let defaults = try isolatedDefaults()
        defaults.set(333.0, forKey: "wordsPerMinute")
        let counter = FileOperationCounter()

        let (service, settings) = launch(url, defaults: defaults, counter: counter)
        settle()

        let written = try Data(contentsOf: url)
        let rewritten = try JSONDecoder().decode(ConfigService.AppConfig.self, from: written)
        XCTAssertEqual(counter.writes, 1)
        XCTAssertEqual(written, try ConfigService.fileData(for: service.config))
        XCTAssertEqual(rewritten.selectedVoiceID, "com.apple.voice.compact.fr-FR.Thomas")
        XCTAssertEqual(rewritten.wordsPerMinute, 333, "an unset speed keeps the stored one")
        XCTAssertFalse(rewritten.confirmBeforeDelete)
        XCTAssertEqual(rewritten.punctuationPauseLevel, 3)
        XCTAssertEqual(settings.punctuationPauseLevel, 3)
    }

    /// A file that cannot be read at launch is left for correction: nothing
    /// is written, its bytes stay, and the preferences keep their values.
    /// Once corrected, the watcher applies it, still without writing.
    func testLaunchLeavesAnUnreadableFileForCorrection() throws {
        let url = try makeConfigFileURL()
        let broken = Data(#"{"wordsPerMinute": 300,,}"#.utf8)
        try broken.write(to: url)
        let defaults = try isolatedDefaults()
        defaults.set(250.0, forKey: "wordsPerMinute")
        let counter = FileOperationCounter()

        let (service, settings) = launch(url, defaults: defaults, counter: counter)
        let recorder = EditRecorder(service)
        settle()

        XCTAssertEqual(counter.writes, 0)
        XCTAssertEqual(try Data(contentsOf: url), broken)
        XCTAssertEqual(settings.wordsPerMinute, 250)
        XCTAssertEqual(debugLogLines(containing: url.path).count, 1)

        var corrected = launchConsistentConfig()
        corrected.wordsPerMinute = 300
        try editorSave(ConfigService.fileData(for: corrected), to: url)

        XCTAssertTrue(waitUntil(timeout: 5) { recorder.edits.count == 1 })
        XCTAssertEqual(settings.wordsPerMinute, 300)
        XCTAssertEqual(counter.writes, 0)
    }

    // MARK: - Delivering external edits

    /// Settings changed in quick succession are announced once each and keep
    /// their last value. TextMouth's own saves are never replayed into the
    /// preferences; they used to be, a moment later, which rolled each change
    /// back to an older value and announced it again.
    func testRapidSettingChangesAreNeverReplayedBack() throws {
        let url = try makeConfigFileURL()
        try ConfigService.fileData(for: launchConsistentConfig()).write(to: url)
        let notificationCenter = NotificationCenter()
        let (service, settings) = launch(
            url,
            defaults: try isolatedDefaults(),
            counter: FileOperationCounter(),
            notificationCenter: notificationCenter
        )
        var speechChanges = 0
        let subscription = notificationCenter.publisher(for: .speechSettingsChanged)
            .sink { _ in speechChanges += 1 }

        settings.wordsPerMinute = 300
        settings.wordsPerMinute = 320
        settle()
        subscription.cancel()

        XCTAssertEqual(speechChanges, 2)
        XCTAssertEqual(settings.wordsPerMinute, 320)
        XCTAssertEqual(service.config.wordsPerMinute, 320)
        XCTAssertEqual(try ConfigService.decode(Data(contentsOf: url)).wordsPerMinute, 320)
    }

    /// An edit saved from outside TextMouth, noticed by the real file
    /// watcher, reaches the preferences exactly once and is not saved back.
    func testAnExternalEditReachesThePreferencesOnce() throws {
        let url = try makeConfigFileURL()
        var edit = launchConsistentConfig()
        try ConfigService.fileData(for: edit).write(to: url)
        let counter = FileOperationCounter()
        let (service, settings) = launch(url, defaults: try isolatedDefaults(), counter: counter)
        let recorder = EditRecorder(service)

        edit.sleepFadeOutDuration = 9
        try editorSave(ConfigService.fileData(for: edit), to: url)
        XCTAssertTrue(waitUntil(timeout: 5) { recorder.edits.count == 1 })
        settle()

        XCTAssertEqual(recorder.edits, [edit])
        XCTAssertEqual(settings.sleepFadeOutDuration, 9)
        XCTAssertEqual(counter.writes, 0)
    }

    // MARK: - Telling TextMouth's saves from external edits

    /// The watcher's decision depends on the file's bytes, not on when
    /// TextMouth last saved: its own bytes are never reloaded and anyone
    /// else's always are, while the event alone says whether to follow the
    /// file to a replacement.
    func testWatcherDecisionComparesContentsNotTiming() {
        let ours = Data("written by TextMouth".utf8)
        let theirs = Data("written by an editor".utf8)
        func actions(
            _ event: DispatchSource.FileSystemEvent,
            onDisk: Data?,
            handled: Data?
        ) -> ConfigService.WatcherActions {
            ConfigService.watcherActions(for: event, fileContents: onDisk, lastHandledContents: handled)
        }

        // TextMouth's own atomic save replaced the watched file.
        XCTAssertEqual(actions(.delete, onDisk: ours, handled: ours), .init(rearm: true, reload: false))
        // An editor's atomic save replaced it, whichever event reports that.
        XCTAssertEqual(actions(.delete, onDisk: theirs, handled: ours), .init(rearm: true, reload: true))
        XCTAssertEqual(actions(.rename, onDisk: theirs, handled: ours), .init(rearm: true, reload: true))
        // An edit written in place.
        XCTAssertEqual(actions(.write, onDisk: theirs, handled: ours), .init(rearm: false, reload: true))
        // A later event from a burst whose edit was already handled.
        XCTAssertEqual(actions(.write, onDisk: theirs, handled: theirs), .init(rearm: false, reload: false))
        // The file is gone: follow the path, with nothing to apply yet.
        XCTAssertEqual(actions(.delete, onDisk: nil, handled: ours), .init(rearm: true, reload: false))
        // A file that appeared where this process had seen none.
        XCTAssertEqual(actions(.write, onDisk: theirs, handled: nil), .init(rearm: false, reload: true))
    }

    /// TextMouth's own saves are recognized by their bytes: the events they
    /// cause apply nothing, however soon after one another they come.
    func testOwnSavesAreNeverReloaded() throws {
        let url = try makeConfigFileURL()
        try ConfigService.fileData(for: launchConsistentConfig()).write(to: url)
        let (service, settings) = launch(url, defaults: try isolatedDefaults(), counter: FileOperationCounter())
        let recorder = EditRecorder(service)

        settings.wordsPerMinute = 300
        // The event TextMouth's atomic save causes, handled at once rather
        // than after the watcher's delay.
        service.handleFileEvent(.delete)
        settings.pitchMultiplier = 1.8
        settle()

        XCTAssertEqual(recorder.edits, [])
        XCTAssertEqual(settings.wordsPerMinute, 300)
        XCTAssertEqual(settings.pitchMultiplier, 1.8)
    }

    /// An editor's atomic save that lands right after TextMouth saved twice
    /// in quick succession is applied exactly once, and applying it saves
    /// nothing. The half-second window that used to follow every save
    /// dropped such an edit.
    func testEditorSaveRightAfterRepeatedAppSavesIsAppliedOnce() throws {
        let url = try makeConfigFileURL()
        try ConfigService.fileData(for: launchConsistentConfig()).write(to: url)
        let counter = FileOperationCounter()
        let (service, settings) = launch(url, defaults: try isolatedDefaults(), counter: counter)
        let recorder = EditRecorder(service)

        settings.wordsPerMinute = 300
        settings.wordsPerMinute = 310
        // The editor opened the file as it is now and changes one value.
        var edit = service.config
        edit.sleepFadeOutDuration = 9
        let editBytes = try ConfigService.fileData(for: edit)
        try editorSave(editBytes, to: url)

        XCTAssertTrue(waitUntil(timeout: 5) { recorder.edits.count == 1 })
        settle()
        XCTAssertEqual(recorder.edits, [edit])
        XCTAssertEqual(settings.sleepFadeOutDuration, 9)
        XCTAssertEqual(settings.wordsPerMinute, 310)
        XCTAssertEqual(counter.writes, 2, "only the two settings changes wrote")
        XCTAssertEqual(try Data(contentsOf: url), editBytes)
    }

    /// An editor's save that lands between two of TextMouth's saves, before
    /// the watcher has handled it, is not lost to the second save: that save
    /// merges it in, applies it exactly once, and writes both changes.
    func testEditorSaveBetweenTwoAppSavesIsMergedAndAppliedOnce() throws {
        let url = try makeConfigFileURL()
        try ConfigService.fileData(for: launchConsistentConfig()).write(to: url)
        let counter = FileOperationCounter()
        let (service, settings) = launch(url, defaults: try isolatedDefaults(), counter: counter)
        let recorder = EditRecorder(service)

        settings.wordsPerMinute = 300
        var edit = service.config
        edit.sleepFadeOutDuration = 9
        try editorSave(ConfigService.fileData(for: edit), to: url)
        settings.wordsPerMinute = 310

        XCTAssertEqual(recorder.edits.count, 1, "the second save applied the edit at once")
        XCTAssertEqual(settings.sleepFadeOutDuration, 9)
        settle()
        XCTAssertEqual(recorder.edits.count, 1)
        XCTAssertEqual(settings.wordsPerMinute, 310)
        XCTAssertEqual(counter.writes, 2)
        let saved = try ConfigService.decode(Data(contentsOf: url))
        XCTAssertEqual(saved.wordsPerMinute, 310)
        XCTAssertEqual(saved.sleepFadeOutDuration, 9)
    }

    /// A merge keeps each field TextMouth changed since it last agreed with
    /// the file, takes the edit's value for every other field, and lets
    /// TextMouth's later change win when both changed the same field.
    func testMergeKeepsTextMouthsChangesAndTakesTheEditsOthers() {
        let base = ConfigService.AppConfig.everyFieldCustomized
        var ours = base
        ours.wordsPerMinute = 500
        ours.pitchMultiplier = 1.8
        var theirs = base
        theirs.pitchMultiplier = 0.7
        theirs.sleepFadeOutDuration = 9
        theirs.confirmBeforeDelete = true

        let merged = ConfigService.merging(ours: ours, theirs: theirs, base: base)

        var expected = base
        expected.wordsPerMinute = 500
        expected.pitchMultiplier = 1.8
        expected.sleepFadeOutDuration = 9
        expected.confirmBeforeDelete = true
        XCTAssertEqual(merged, expected)
        // With no base to compare against, the edit on disk is taken whole.
        XCTAssertEqual(ConfigService.merging(ours: ours, theirs: theirs, base: ours), theirs)
    }

    /// A field holding an object merges entry by entry: TextMouth's change
    /// to one action's shortcuts and the edit's change to another's both
    /// stand, as does a sound each changed; when both changed one action,
    /// TextMouth's later change wins.
    func testMergeCombinesTheEntriesOfShortcutsAndSounds() {
        let base = ConfigService.AppConfig.everyFieldCustomized
        var ours = base
        ours.keyboardShortcuts["Where Am I?"] = ["control+w"]
        ours.keyboardShortcuts["Go Back"] = ["control+["]
        ours.soundEffectAssignments["Play"] = "Ping"
        var theirs = base
        theirs.keyboardShortcuts["Add Bookmark"] = ["control+b"]
        theirs.keyboardShortcuts["Go Back"] = ["option+["]
        theirs.soundEffectAssignments["Pause"] = "Tink"

        let merged = ConfigService.merging(ours: ours, theirs: theirs, base: base)

        var expected = base
        expected.keyboardShortcuts["Where Am I?"] = ["control+w"]
        expected.keyboardShortcuts["Add Bookmark"] = ["control+b"]
        expected.keyboardShortcuts["Go Back"] = ["control+["]
        expected.soundEffectAssignments["Play"] = "Ping"
        expected.soundEffectAssignments["Pause"] = "Tink"
        XCTAssertEqual(merged, expected)
    }

    /// An edit with a value out of range is applied repaired, and the
    /// repaired snapshot is written back once so the file shows the value in
    /// use. The watcher recognizes that write as TextMouth's own: the edit is
    /// applied once, and nothing writes again.
    func testRepairedEditIsAppliedOnceAndWrittenBackOnce() throws {
        let url = try makeConfigFileURL()
        try ConfigService.fileData(for: launchConsistentConfig()).write(to: url)
        let counter = FileOperationCounter()
        let (service, settings) = launch(url, defaults: try isolatedDefaults(), counter: counter)
        let recorder = EditRecorder(service)

        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        fields["punctuationPauseLevel"] = 40
        try editorSave(JSONSerialization.data(withJSONObject: fields), to: url)

        XCTAssertTrue(waitUntil(timeout: 5) { recorder.edits.count == 1 })
        settle()
        XCTAssertEqual(recorder.edits.count, 1)
        XCTAssertEqual(settings.punctuationPauseLevel, 3)
        XCTAssertEqual(counter.writes, 1)
        XCTAssertEqual(service.config.punctuationPauseLevel, 3)
        XCTAssertEqual(try Data(contentsOf: url), try ConfigService.fileData(for: service.config))
    }

    /// An edit laid out its own way, with every value usable, is applied and
    /// left exactly as its editor saved it: layout alone is never rewritten.
    func testAnEditInItsOwnLayoutIsAppliedWithoutRewritingIt() throws {
        let url = try makeConfigFileURL()
        try ConfigService.fileData(for: launchConsistentConfig()).write(to: url)
        let counter = FileOperationCounter()
        let (service, settings) = launch(url, defaults: try isolatedDefaults(), counter: counter)
        let recorder = EditRecorder(service)

        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        fields["sleepFadeOutDuration"] = 9
        let compact = try JSONSerialization.data(withJSONObject: fields)
        try editorSave(compact, to: url)

        XCTAssertTrue(waitUntil(timeout: 5) { recorder.edits.count == 1 })
        settle()
        XCTAssertEqual(settings.sleepFadeOutDuration, 9)
        XCTAssertEqual(counter.writes, 0)
        XCTAssertEqual(try Data(contentsOf: url), compact)
        XCTAssertEqual(service.config.sleepFadeOutDuration, 9)
    }

    /// Only a value that decoding had to change counts as repaired: layout,
    /// missing and null fields, and keys TextMouth does not use do not.
    func testOnlyValuesDecodingChangedCountAsRepaired() throws {
        func repaired(_ json: String) throws -> Bool {
            let contents = Data(json.utf8)
            return ConfigService.decodingRepairedValues(in: contents, decoded: try ConfigService.decode(contents))
        }
        let saved = String(decoding: try ConfigService.fileData(for: .everyFieldCustomized), as: UTF8.self)

        XCTAssertFalse(try repaired(saved))
        XCTAssertFalse(try repaired(#"{"sleepFadeOutDuration":6,"wordsPerMinute":425.0}"#))
        XCTAssertFalse(try repaired(#"{"confirmBeforeDelete": null, "someFutureSetting": true}"#))
        XCTAssertFalse(try repaired(#"{"wordsPerMinute": 0}"#), "0 means not chosen yet")
        XCTAssertTrue(try repaired(#"{"punctuationPauseLevel": 40}"#))
        XCTAssertTrue(try repaired(#"{"rewindSmartMode": "yes"}"#))
        XCTAssertTrue(try repaired(#"{"skipForwardUnit": "17 seconds"}"#))
    }

    /// A file replaced with text that is not JSON changes no setting and is
    /// not overwritten, so the edit stays on disk to be corrected; the debug
    /// log names the file once, however many events follow. The corrected
    /// file is then applied.
    func testInvalidEditKeepsSettingsAndLeavesTheFileForCorrection() throws {
        let url = try makeConfigFileURL()
        var edit = launchConsistentConfig()
        try ConfigService.fileData(for: edit).write(to: url)
        let counter = FileOperationCounter()
        let (service, settings) = launch(url, defaults: try isolatedDefaults(), counter: counter)
        let recorder = EditRecorder(service)

        let broken = Data(#"{"sleepFadeOutDuration": 9,,}"#.utf8)
        try editorSave(broken, to: url)
        service.handleFileEvent(.rename)
        // The watcher's own events for the same save find the same bytes.
        settle()

        XCTAssertEqual(recorder.edits, [])
        XCTAssertEqual(settings.sleepFadeOutDuration, 6)
        XCTAssertEqual(counter.writes, 0)
        XCTAssertEqual(try Data(contentsOf: url), broken)
        XCTAssertEqual(debugLogLines(containing: url.path).count, 1)

        edit.sleepFadeOutDuration = 9
        try editorSave(ConfigService.fileData(for: edit), to: url)

        XCTAssertTrue(waitUntil(timeout: 5) { recorder.edits.count == 1 })
        XCTAssertEqual(settings.sleepFadeOutDuration, 9)
        XCTAssertEqual(counter.writes, 0)
    }

    // MARK: - Following the file

    /// After an editor's atomic save replaces the file, the real watcher
    /// listens to the new file: a later edit written into it in place, which
    /// only a watcher on the new file can notice, is applied too.
    func testWatcherFollowsAReplacedFileToLaterEdits() throws {
        let url = try makeConfigFileURL()
        var edit = launchConsistentConfig()
        try ConfigService.fileData(for: edit).write(to: url)
        let counter = FileOperationCounter()
        let (service, settings) = launch(url, defaults: try isolatedDefaults(), counter: counter)
        let recorder = EditRecorder(service)

        edit.sleepFadeOutDuration = 9
        try editorSave(ConfigService.fileData(for: edit), to: url)
        XCTAssertTrue(waitUntil(timeout: 5) { recorder.edits.count == 1 })
        settle()

        edit.punctuationPauseLevel = 3
        try ConfigService.fileData(for: edit).write(to: url)

        XCTAssertTrue(waitUntil(timeout: 5) { recorder.edits.count == 2 })
        XCTAssertEqual(recorder.edits.last, edit)
        XCTAssertEqual(settings.sleepFadeOutDuration, 9)
        XCTAssertEqual(settings.punctuationPauseLevel, 3)
        XCTAssertEqual(counter.writes, 0)
    }

    /// An editor may remove the file a moment before putting the new one in
    /// place. The watcher keeps looking, and applies the file that appears,
    /// although its appearance reports no event to anyone; it then listens
    /// to that file.
    func testWatcherFindsAFileThatReappearsAfterAGap() throws {
        let url = try makeConfigFileURL()
        var edit = launchConsistentConfig()
        try ConfigService.fileData(for: edit).write(to: url)
        let (service, settings) = launch(url, defaults: try isolatedDefaults(), counter: FileOperationCounter())
        let recorder = EditRecorder(service)

        try FileManager.default.removeItem(at: url)
        // Longer than the watcher's delay, so its check of the empty path
        // has come and gone before the file returns.
        settle(for: 0.4)
        edit.sleepFadeOutDuration = 9
        try ConfigService.fileData(for: edit).write(to: url)

        XCTAssertTrue(waitUntil(timeout: 5) { recorder.edits.count == 1 })
        XCTAssertEqual(settings.sleepFadeOutDuration, 9)

        edit.punctuationPauseLevel = 3
        try ConfigService.fileData(for: edit).write(to: url)

        XCTAssertTrue(waitUntil(timeout: 5) { recorder.edits.count == 2 })
        XCTAssertEqual(settings.punctuationPauseLevel, 3)
    }

    /// A replacement event while the watched file is still at the path, as
    /// when the event of a replacement already followed arrives late,
    /// reopens nothing.
    func testRearmingKeepsTheWatchedFileWithoutReopeningIt() throws {
        let url = try makeConfigFileURL()
        try ConfigService.fileData(for: launchConsistentConfig()).write(to: url)
        let counter = FileOperationCounter()
        let service = makeWatchingService(url, counter: counter)

        service.handleFileEvent([.rename, .delete])
        settle()

        XCTAssertEqual(counter.opens, 1)
        XCTAssertEqual(counter.openDescriptors, 1)
    }

    /// Following the file across many replacements, TextMouth's own saves
    /// and an editor's alike, opens exactly one descriptor per file and
    /// closes each one's predecessor, so one stays open however long the app
    /// runs; TextMouth's save follows its new file at once. Shutting down
    /// closes the last descriptor, and later edits wake nothing.
    func testReplacementsKeepOneDescriptorOpenAndShutdownClosesIt() throws {
        let url = try makeConfigFileURL()
        var edit = launchConsistentConfig()
        try ConfigService.fileData(for: edit).write(to: url)
        let counter = FileOperationCounter()
        let service = makeWatchingService(url, counter: counter)
        let replacements = 12

        for index in 0..<replacements {
            if index.isMultiple(of: 2) {
                service.config.wordsPerMinute = 300 + Double(index)
                service.saveToDisk()
                XCTAssertEqual(counter.opens, index + 2, "a save follows its new file before returning")
            } else {
                edit.wordsPerMinute = 300 + Double(index)
                try editorSave(ConfigService.fileData(for: edit), to: url)
                service.handleFileEvent(.delete)
            }
        }

        XCTAssertTrue(waitUntil(timeout: 5) { counter.openDescriptors == 1 })
        settle()
        XCTAssertEqual(counter.opens, replacements + 1)
        XCTAssertEqual(counter.openDescriptors, 1)

        service.shutdown()

        XCTAssertTrue(waitUntil(timeout: 5) { counter.openDescriptors == 0 })
        edit.wordsPerMinute = 450
        try editorSave(ConfigService.fileData(for: edit), to: url)
        settle()
        XCTAssertEqual(counter.opens, replacements + 1)
        XCTAssertEqual(counter.openDescriptors, 0)
        XCTAssertEqual(service.config.wordsPerMinute, 300 + Double(replacements - 1))
    }

    // MARK: - Preferences Mirrored Since TODO C04

    /// An edit of the playback bar's preferences, noticed through the
    /// watcher's handler, is applied once, refreshes open playback bars once
    /// per change, and writes nothing back.
    func testExternalEditOfThePlaybackBarIsAppliedOnce() throws {
        let url = try makeConfigFileURL()
        var edit = launchConsistentConfig()
        try ConfigService.fileData(for: edit).write(to: url)
        let counter = FileOperationCounter()
        let (service, settings) = launch(url, defaults: try isolatedDefaults(), counter: counter)
        let recorder = EditRecorder(service)
        let revision = settings.playbackControlsSettingsRevision

        edit.playbackNavigationUnitControlMode = PlaybackNavigationUnitControlMode.shared.rawValue
        edit.showBookmarkInPlaybackControls = false
        edit.showSpeedInPlaybackControls = true
        try editorSave(ConfigService.fileData(for: edit), to: url)
        service.handleFileEvent(.rename)
        settle()

        XCTAssertEqual(recorder.edits, [edit])
        XCTAssertEqual(settings.playbackNavigationUnitControlMode, .shared)
        XCTAssertFalse(settings.showBookmarkInPlaybackControls)
        XCTAssertTrue(settings.showSpeedInPlaybackControls)
        XCTAssertEqual(settings.playbackControlsSettingsRevision, revision + 3)
        XCTAssertEqual(counter.writes, 0)
    }

    /// An edit of the sound preferences, noticed through the watcher's
    /// handler, is applied once and reaches the sound service at once, each
    /// changed preference published once; nothing is written back.
    func testExternalEditOfTheSoundsReachesTheSoundServiceOnce() throws {
        let url = try makeConfigFileURL()
        var edit = launchConsistentConfig()
        try ConfigService.fileData(for: edit).write(to: url)
        let defaults = try isolatedDefaults()
        let counter = FileOperationCounter()
        let (service, settings) = launch(url, defaults: defaults, counter: counter)
        let sounds = SoundEffectService(preferences: defaults)
        let recorder = EditRecorder(service)
        var publications = 0
        let subscription = sounds.objectWillChange.sink { publications += 1 }

        edit.soundEffectsEnabled = true
        edit.soundEffectsVolume = 0.9
        edit.soundEffectAssignments[SoundEvent.play.rawValue] = "Ping"
        try editorSave(ConfigService.fileData(for: edit), to: url)
        service.handleFileEvent(.rename)
        settle()
        subscription.cancel()

        XCTAssertEqual(recorder.edits, [edit])
        XCTAssertTrue(sounds.soundsEnabled)
        XCTAssertEqual(sounds.volume, 0.9)
        XCTAssertEqual(sounds.assignments[.play], "Ping")
        XCTAssertEqual(sounds.assignments[.pause], "None")
        XCTAssertEqual(publications, 3)
        XCTAssertEqual(counter.writes, 0)
        withExtendedLifetime(settings) {}
    }

    /// A sound preference changed through the sound service, as the Sounds
    /// settings change it, is saved to config.json at once, and that save
    /// is never applied back as an edit.
    func testSoundChangeMadeInSettingsIsSavedToConfig() throws {
        let url = try makeConfigFileURL()
        try ConfigService.fileData(for: launchConsistentConfig()).write(to: url)
        let defaults = try isolatedDefaults()
        let counter = FileOperationCounter()
        let (service, settings) = launch(url, defaults: defaults, counter: counter)
        let sounds = SoundEffectService(preferences: defaults)
        let recorder = EditRecorder(service)

        sounds.volume = 0.65
        sounds.assignments[.whereAmIEnd] = "Sosumi"
        settle()

        XCTAssertEqual(counter.writes, 2, "one save for each change")
        let saved = try ConfigService.decode(Data(contentsOf: url))
        XCTAssertEqual(saved.soundEffectsVolume, 0.65)
        XCTAssertEqual(saved.soundEffectAssignments[SoundEvent.whereAmIEnd.rawValue], "Sosumi")
        XCTAssertEqual(recorder.edits, [])
        withExtendedLifetime(settings) {}
    }

    /// An edit of the substitution switch, noticed through the watcher's
    /// handler, is applied once and reaches the substitution service at
    /// once, published once, which is what open readers re-prepare their
    /// speech on; turning it back in the Text settings saves the file once.
    func testSubstitutionSwitchFollowsEditsAndIsSavedFromSettings() throws {
        let url = try makeConfigFileURL()
        var edit = launchConsistentConfig()
        try ConfigService.fileData(for: edit).write(to: url)
        let defaults = try isolatedDefaults()
        let counter = FileOperationCounter()
        let (service, settings) = launch(url, defaults: defaults, counter: counter)
        let substitutions = TextSubstitutionService(rules: [], isEnabled: false, preferences: defaults)
        let recorder = EditRecorder(service)
        var publications = 0
        let subscription = substitutions.objectWillChange.sink { publications += 1 }

        edit.substitutionsEnabled = true
        try editorSave(ConfigService.fileData(for: edit), to: url)
        service.handleFileEvent(.rename)
        settle()

        XCTAssertEqual(recorder.edits, [edit])
        XCTAssertTrue(substitutions.isEnabled)
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(counter.writes, 0)

        substitutions.isEnabled = false
        settle()
        subscription.cancel()

        XCTAssertEqual(counter.writes, 1)
        XCTAssertEqual(try ConfigService.decode(Data(contentsOf: url)).substitutionsEnabled, false)
        XCTAssertEqual(recorder.edits.count, 1, "TextMouth's own save is not applied back")
        withExtendedLifetime(settings) {}
    }

    /// An edit of the shortcuts, noticed through the watcher's handler, is
    /// applied once and reaches the shortcut manager at once, published
    /// once; the store keeps them where and as every release saved them,
    /// and nothing is written back.
    func testExternalEditOfTheShortcutsReachesTheManagerOnce() throws {
        let url = try makeConfigFileURL()
        var edit = launchConsistentConfig()
        try ConfigService.fileData(for: edit).write(to: url)
        let defaults = try isolatedDefaults()
        let counter = FileOperationCounter()
        let (service, settings) = launch(url, defaults: defaults, counter: counter)
        let manager = KeyboardShortcutManager(userDefaults: defaults, installsEventMonitor: false)
        let recorder = EditRecorder(service)
        var publications = 0
        let subscription = manager.objectWillChange.sink { publications += 1 }

        edit.keyboardShortcuts[ShortcutAction.whereAmI.rawValue] = ["control+w"]
        try editorSave(ConfigService.fileData(for: edit), to: url)
        service.handleFileEvent(.rename)
        settle()
        subscription.cancel()

        XCTAssertEqual(recorder.edits, [edit])
        XCTAssertEqual(manager.bindingsFor(.whereAmI), [KeyBinding(key: "w", control: true)])
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(counter.writes, 0)
        let stored = try XCTUnwrap(defaults.data(forKey: "customKeyboardBindings"))
        let saved = try JSONDecoder().decode([String: [KeyBinding]].self, from: stored)
        XCTAssertEqual(saved["Where Am I?"], [KeyBinding(key: "w", control: true)])
        withExtendedLifetime(settings) {}
    }

    /// A shortcut recorded in the Shortcuts settings, which changes the
    /// manager's bindings, is saved to config.json at once, and that save is
    /// never applied back as an edit.
    func testShortcutRecordedInSettingsIsSavedToConfig() throws {
        let url = try makeConfigFileURL()
        try ConfigService.fileData(for: launchConsistentConfig()).write(to: url)
        let defaults = try isolatedDefaults()
        let counter = FileOperationCounter()
        let (service, settings) = launch(url, defaults: defaults, counter: counter)
        let manager = KeyboardShortcutManager(userDefaults: defaults, installsEventMonitor: false)
        let recorder = EditRecorder(service)

        manager.addBinding(KeyBinding(key: "j", control: true), to: .whereAmI)
        settle()

        XCTAssertEqual(counter.writes, 1)
        let saved = try ConfigService.decode(Data(contentsOf: url))
        XCTAssertEqual(saved.keyboardShortcuts[ShortcutAction.whereAmI.rawValue], ["option+w", "control+j"])
        XCTAssertEqual(recorder.edits, [])
        withExtendedLifetime(settings) {}
    }

    // MARK: - Open Settings Follow Edits

    /// While the Storage settings are open, an edit of config.json reaches
    /// what their controls are bound to: the removal preferences model
    /// publishes the edit's removal choices once, and the settings model
    /// announces the edit's import choice once and reads it.
    func testStorageChoicesFollowAnExternalEdit() throws {
        let url = try makeConfigFileURL()
        var edit = launchConsistentConfig()
        try ConfigService.fileData(for: edit).write(to: url)
        let counter = FileOperationCounter()
        let (service, settings) = launch(url, defaults: try isolatedDefaults(), counter: counter)
        let removal = RemovalPreferencesModel(configService: service)
        var publishedRemoval: [RemovalPreferences] = []
        let removalSubscription = removal.$preferences.dropFirst().sink { publishedRemoval.append($0) }
        var settingsAnnouncements = 0
        let settingsSubscription = settings.objectWillChange.sink { settingsAnnouncements += 1 }

        edit.confirmBeforeDelete = true
        edit.moveToTrashInsteadOfDeleting = true
        edit.importDeleteBehavior = .deleteAfterImport
        try editorSave(ConfigService.fileData(for: edit), to: url)
        service.handleFileEvent(.rename)
        settle()
        removalSubscription.cancel()
        settingsSubscription.cancel()

        let edited = RemovalPreferences(confirmsFirst: true, movesToTrash: true)
        XCTAssertEqual(publishedRemoval, [edited])
        XCTAssertEqual(removal.preferences, edited)
        XCTAssertEqual(settings.importDeleteBehavior, .deleteAfterImport)
        XCTAssertEqual(settingsAnnouncements, 1)
        XCTAssertEqual(counter.writes, 0)
    }

    /// A Storage control changed after an edit of config.json starts from
    /// the edit's value and saves only its own choice, so the edit's other
    /// choices stay in force; no control writes back a copy taken when the
    /// window opened.
    func testStorageControlsChangeOnlyTheirOwnChoiceAfterAnEdit() throws {
        let url = try makeConfigFileURL()
        var edit = launchConsistentConfig()
        try ConfigService.fileData(for: edit).write(to: url)
        let counter = FileOperationCounter()
        let (service, settings) = launch(url, defaults: try isolatedDefaults(), counter: counter)
        let removal = RemovalPreferencesModel(configService: service)

        edit.confirmBeforeDelete = true
        edit.importDeleteBehavior = .deleteAfterImport
        try editorSave(ConfigService.fileData(for: edit), to: url)
        service.handleFileEvent(.rename)
        // The user turns off confirmation, which the window shows as on.
        removal.setConfirmsFirst(!removal.preferences.confirmsFirst)
        removal.setMovesToTrash(true)
        settings.importDeleteBehavior = .keepOriginal
        settle()

        let saved = try ConfigService.decode(Data(contentsOf: url))
        XCTAssertFalse(saved.confirmBeforeDelete)
        XCTAssertTrue(saved.moveToTrashInsteadOfDeleting)
        XCTAssertEqual(saved.importDeleteBehavior, .keepOriginal)
        XCTAssertEqual(removal.preferences, RemovalPreferences(confirmsFirst: false, movesToTrash: true))
        XCTAssertEqual(counter.writes, 3, "one save for each change")

        removal.setMovesToTrash(true)
        settings.importDeleteBehavior = .keepOriginal
        XCTAssertEqual(counter.writes, 3, "choosing a value already in force saves nothing")
    }

    /// The open Storage settings, as AppKit draws them, show their choices
    /// changing when the configuration changes outside them, as applying an
    /// edit of config.json changes it: both removal checkboxes and the
    /// import pop-up follow. The app's shared configuration is changed in
    /// memory only, and put back.
    func testOpenStorageSettingsShowChoicesChangedOutsideThem() throws {
        let service = ConfigService.shared
        let original = service.config
        defer {
            service.config.confirmBeforeDelete = original.confirmBeforeDelete
            service.config.moveToTrashInsteadOfDeleting = original.moveToTrashInsteadOfDeleting
            service.config.importDeleteBehavior = original.importDeleteBehavior
        }
        service.config.confirmBeforeDelete = false
        service.config.moveToTrashInsteadOfDeleting = false
        service.config.importDeleteBehavior = .keepOriginal
        let settings = SettingsViewModel(
            notificationCenter: NotificationCenter(),
            initializeServices: false,
            userDefaults: try isolatedDefaults()
        )
        let view = StorageSettingsView()
            .environmentObject(LibraryViewModel(initializeServices: false))
            .environmentObject(settings)

        try withHostedView(view, size: NSSize(width: 600, height: 900), until: { StorageControls($0) != nil }) { hosting in
            guard let before = StorageControls(hosting) else {
                throw XCTSkip("This macOS does not draw the Storage choices with AppKit controls")
            }
            XCTAssertEqual(before.confirm.state, .off)
            XCTAssertEqual(before.moveToTrash.state, .off)
            XCTAssertEqual(before.afterImport.titleOfSelectedItem, ImportDeleteBehavior.keepOriginal.rawValue)

            service.config.confirmBeforeDelete = true
            service.config.moveToTrashInsteadOfDeleting = true
            service.config.importDeleteBehavior = .askEachTime

            // SwiftUI redraws on a later turn of the run loop, and may draw
            // new controls, so each look finds them again.
            XCTAssertTrue(waitUntil {
                hosting.layoutSubtreeIfNeeded()
                guard let after = StorageControls(hosting) else { return false }
                return after.confirm.state == .on
                    && after.moveToTrash.state == .on
                    && after.afterImport.titleOfSelectedItem == ImportDeleteBehavior.askEachTime.rawValue
            })
        }
    }

    // MARK: - Saving

    /// A save writes only when the file's bytes would change: saving the
    /// same settings again leaves the file and its modification date alone.
    func testSavingUnchangedSettingsWritesNothing() throws {
        let url = try makeConfigFileURL()
        let counter = FileOperationCounter()
        let service = ConfigService(fileURL: url, fileOperations: counter.operations)
        service.config = .everyFieldCustomized

        service.saveToDisk()
        let stamp = try fileStamp(url)
        service.saveToDisk()

        XCTAssertEqual(counter.writes, 1)
        XCTAssertEqual(try fileStamp(url), stamp)
        XCTAssertEqual(try Data(contentsOf: url), try ConfigService.fileData(for: .everyFieldCustomized))

        service.config.wordsPerMinute = 300
        service.saveToDisk()

        XCTAssertEqual(counter.writes, 2)
    }

    // MARK: - Helpers

    /// Launches the way the app does: a service that loads `url`, then a
    /// settings model on `defaults` that reconciles the two and starts the
    /// watcher, which stops when the test ends.
    private func launch(
        _ url: URL,
        defaults: UserDefaults,
        counter: FileOperationCounter,
        notificationCenter: NotificationCenter = NotificationCenter()
    ) -> (service: ConfigService, settings: SettingsViewModel) {
        let service = ConfigService(fileURL: url, fileOperations: counter.operations)
        addTeardownBlock { service.shutdown() }
        let settings = SettingsViewModel(
            notificationCenter: notificationCenter,
            initializeServices: true,
            userDefaults: defaults,
            configService: service
        )
        return (service, settings)
    }

    /// A service on `url`, counting through `counter`, that watches the file
    /// without a settings model; it stops when the test ends.
    private func makeWatchingService(_ url: URL, counter: FileOperationCounter) -> ConfigService {
        let service = ConfigService(fileURL: url, fileOperations: counter.operations)
        addTeardownBlock { service.shutdown() }
        service.startWatching()
        return service
    }

    /// `everyFieldCustomized` with the data directory in use, so the settings
    /// model saves it back byte for byte: a launch on it has nothing to change.
    private func launchConsistentConfig() -> ConfigService.AppConfig {
        var config = ConfigService.AppConfig.everyFieldCustomized
        config.dataDirectoryPath = ConfigService.AppConfig.currentDataDirectoryPath
        return config
    }

    /// Lets file events, coalesced checks, and other queued main-actor work
    /// run for `seconds`, as the app's run loop would between two actions.
    private func settle(for seconds: TimeInterval = 0.5) {
        let quiet = expectation(description: "nothing is expected while settling")
        quiet.isInverted = true
        wait(for: [quiet], timeout: seconds)
    }

    /// Saves `data` over `url` the way editors do: into a temporary file
    /// beside it, which is then renamed over it, replacing the file in one
    /// step.
    private func editorSave(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temporary)
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Records the external edits a service publishes, in order.
    @MainActor
    private final class EditRecorder {
        /// Every edit published so far.
        private(set) var edits: [ConfigService.AppConfig] = []
        /// Keeps the subscription for the recorder's lifetime.
        private var subscription: AnyCancellable?

        init(_ service: ConfigService) {
            subscription = service.externalEdits.sink { [weak self] edit in
                self?.edits.append(edit)
            }
        }
    }

    /// Counts the file-system calls a service makes, passing each on to the
    /// system.
    @MainActor
    private final class FileOperationCounter {
        /// Atomic writes of config.json.
        private(set) var writes = 0
        /// Descriptors opened to watch the file.
        private(set) var opens = 0
        /// Watch descriptors closed.
        private(set) var closes = 0

        /// Watch descriptors open now.
        var openDescriptors: Int { opens - closes }

        /// The system's operations, counted.
        var operations: ConfigService.FileOperations {
            let system = ConfigService.FileOperations.system
            return ConfigService.FileOperations(
                write: { [self] data, url in
                    writes += 1
                    try system.write(data, url)
                },
                openForEvents: { [self] path in
                    let descriptor = system.openForEvents(path)
                    if descriptor >= 0 {
                        opens += 1
                    }
                    return descriptor
                },
                close: { [self] descriptor in
                    closes += 1
                    system.close(descriptor)
                }
            )
        }
    }

    /// The Storage settings' three choices as AppKit draws them: the import
    /// pop-up, found by its choices, and the two removal checkboxes. Nil
    /// until all three are drawn.
    @MainActor
    private struct StorageControls {
        let confirm: NSButton
        let moveToTrash: NSButton
        let afterImport: NSPopUpButton

        init?(_ root: NSView) {
            let importChoices = ImportDeleteBehavior.allCases.map(\.rawValue)
            // SwiftUI draws each checkbox's label itself, beside an untitled
            // AppKit checkbox, so the two are told apart by their order in
            // the pane: "Confirm before removing a book", then "Move to Trash
            // instead of deleting".
            let checkboxes = Self.descendants(of: root, as: NSButton.self).filter {
                !($0 is NSPopUpButton) && $0.title.isEmpty
            }
            guard checkboxes.count == 2,
                  let afterImport = Self.descendants(of: root, as: NSPopUpButton.self)
                      .first(where: { $0.itemTitles == importChoices }) else {
                return nil
            }
            confirm = checkboxes[0]
            moveToTrash = checkboxes[1]
            self.afterImport = afterImport
        }

        /// Every view of type `T` inside `view`, depth first.
        private static func descendants<T: NSView>(of view: NSView, as type: T.Type) -> [T] {
            var found: [T] = []
            for subview in view.subviews {
                if let match = subview as? T {
                    found.append(match)
                }
                found += descendants(of: subview, as: type)
            }
            return found
        }
    }

    /// One version of a file on disk: its identity, which an atomic write
    /// replaces, and its modification date.
    private struct FileStamp: Equatable {
        let identity: FileIdentity?
        let modified: Date?
    }

    /// The version of the file at `url` now.
    private func fileStamp(_ url: URL) throws -> FileStamp {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return FileStamp(identity: FileIdentity(of: url), modified: attributes[.modificationDate] as? Date)
    }
}
