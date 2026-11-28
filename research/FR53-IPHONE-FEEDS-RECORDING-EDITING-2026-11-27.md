# Feeds, recording, and editing audio on the iPhone: plan (November 27, 2026)

Part of [the research folder](README.md).
Issue: FR53; related FR31 (export, the pattern this follows), DR27 (Transcribe Audio), DR01 (Search Library), and DOC04 (the user pages).
Read on main at 250a0d32f, version 0.6.0; written before any change, except the stand-in note in the last sections.
Apple's documentation is listed under Sources; every other fact names its file.

## What this plan decides

- The iPhone has none of the three today, and its screens never mention them: the Add to Library sheet offers Open Book and Import Folder only, Settings has no Feeds tab, and the Library view sheet hides Feeds (`PhoneLibraryChoices.isOfferedOnPhone`).
- The confusing part is that nothing says so; the stand-ins (`AudioEditorLauncher+iOS.swift`, `RecordingWindowController+iOS.swift`, the iOS `CaptureSessionRecordingBackend`) are never reached from the phone's interface.
- The immediate fix: one line at the end of the Add to Library sheet, "Feeds, recording, editing audio, and transcribing are only on the Mac for now."
- Every engine is already shared and compiles for iOS: the feed engine, the recording service and encoder, the edit session, renderer, and filters, and the Mac's own views and models for all three.
- So each feature is a set of iPhone screens over the Mac's models, plus four iOS services: background refresh, background downloads, an AVAudioEngine capture backend, and the record-and-play audio session.
- The order: feeds (four phases), recording (two), the editor (three). Nine branches, each one train.
- The iPhone app grows by about 1 to 2 MB over all nine, to about 19 MB of its 30 MB limit.
- New interface text stays small: the phone reuses the Mac's words, and each phase lists the lines it adds.

## What the iPhone build holds today

- The iPhone target compiles everything under `TextMouth/` but `Platform/macOS/` and `Resources/` (`project.yml`, target `TextMouthiOS`), so every shared file below is in the build now.
- Files that only choose `import AppKit` or `import UIKit` at the top, and so compile on both:
  - `AudioEditorModel.swift`, `AudioEditorModel+PunchIn.swift`, `AudioEditorFileSheets.swift`, `RecordingWindowModel.swift`;
  - `FeedArrivals.swift`, `FeedCommandRunner.swift`, `FeedInfoSheet.swift`, `FeedDownloadProgressSection.swift`, `LibraryFeedsWindowSupport.swift`, `OPMLImportSheet.swift`.
- Code inside `#if os(macOS)` that the iPhone needs its own half of:
  - `NSOpenPanel` and `NSSavePanel` in `OPMLImportSheet.swift` and `AudioEditorFileSheets.swift`;
  - `NSWorkspace.shared.open` of the privacy settings in `RecordingWindowModel.openPrivacySettings()`;
  - `NSSound` of `/System/Library/Sounds/Tink.aiff`, the count-in, in `AudioEditorModel+PunchIn.swift`;
  - `NSWindow.didBecomeKeyNotification` in `LibraryFeedsWindowSupport.swift`;
  - the capture backend in `RecordingCaptureBackend.swift` (`AVCaptureSession` and `AVCaptureAudioFileOutput`, which iOS lacks);
  - the transport-type filter in `RecordingInputDevices.swift`, and the ffmpeg program search in `AudioEditing/FFmpeg.swift` (nil on iOS; MP3 goes through the built-in LAME encoder, `AudioEditRenderer+MP3.swift`).
- Mac-only files: `Platform/macOS/Views/AudioEditor/` (the launcher, the window controller, the Edit menu) and `Platform/macOS/Views/Recording/RecordingWindowController.swift`.
- `AudioEditorTracks` (which track of a book to edit) is plain logic but lives in the Mac-only `AudioEditorLauncher.swift`; it moves to shared code in phase E1, not copied.
- The feed engine already runs on the iPhone: `LibraryViewModel` calls `startFeeds()` at every launch, on both platforms, with no feeds to work on.
- `make typecheck-ios` passes with 0 errors on main; nothing in this plan may raise it.

## Facts from Apple that shape the phases

- **Refresh.** `BGAppRefreshTask` is for "updating your app with small bits of information" and needs the `fetch` background mode and `BGTaskSchedulerPermittedIdentifiers`; tasks are registered "before the end of the app launch sequence", and the system decides when one runs [1, 4].
- **Long work.** `BGProcessingTask` runs "only when the device is idle", and ends when the person picks up the phone [2].
  `BGContinuedProcessingTask` (iOS 26) starts in the foreground, shows its progress in a Live Activity, and can be cancelled there [3]; the export uses it today (`PhoneExportBackgroundTask.swift`).
- **Downloads.** A background `URLSession` hands transfers to another process that goes on while the app is suspended or ended by the system, and relaunches the app to deliver them [5, 6].
  - Only HTTP and HTTPS: no custom protocol, so the tests' stub protocol (`FeedNetwork`'s `protocolClasses`) cannot reach it.
  - Redirects are always followed, and the delegate's redirect method is never called.
  - A force quit from the app switcher cancels every transfer, and the app is not relaunched until the person opens it [6].
  - Starting downloads one at a time from the background raises a delay each time; start many tasks in one session instead [5].
- **Permission.** The first recording asks for the microphone; without permission the app "captures only silence"; without `NSMicrophoneUsageDescription` "the app exits" [7]. The key is in the iPhone's `Info.plist` already.
- **Interruptions.** A call or Siri interrupts the session; recording stops [8]. iOS 27 adds life-cycle notifications, but the deployment target is iOS 26 and GitHub builds with Xcode 26.0.1, so the phone keeps the older `interruptionNotification` until the SDK floor moves.
- **Bluetooth.** `allowBluetoothHFP` makes headsets' microphones available to `playAndRecord` [9]; iOS 26's `bluetoothHighQualityRecording` gives full-bandwidth AirPods recording where supported, with HFP as the fallback, and "isn't currently supported in the European Union" [10].
- **`playAndRecord`** keeps working with the screen locked when the `audio` background mode is set, which the iPhone has, and is nonmixable by default [11].
- **VoiceOver.** `accessibilityAdjustableAction` (swipe up and down), `accessibilityAction(named:)` (the Actions rotor), and `accessibilityRotor` (custom rotors) are SwiftUI's on iOS 16 and later [12, 13, 14].
  The iPhone spec found SwiftUI's value late after an adjustment, so the reader's adjustable controls are UIKit (`PhoneControl.swift`); the editor reuses that control.

## The immediate fix for the stand-ins

- Today a person on the iPhone meets no sign of feeds, recording, or the editor, so they cannot tell whether the features are missing, hidden, or broken.
- The Add to Library sheet is where a person looks for New Recording… and Add Feed… (the Mac's sheet lists them), so the note goes there, after Import Folder…, as static text VoiceOver reads after the two rows.
- Its words: "Feeds, recording, editing audio, and transcribing are only on the Mac for now." One new line, translated into all 24 languages.
- Each later phase shortens the line as its feature arrives, and the last removes it.
- Nothing else on the phone changes: the stand-ins are never reached, so no error sentence a person could hear changes.
- Found while reading: the sync sends every folder, a feed's folder among them (`SyncProjection.of`), though the sync plan lists feeds' folders as left out; a feed's folder reaches the phone empty, since feed items don't sync. Posted as a finding for sync's owner.

## Feeds: the shared code each phase uses

- The engine: `FeedCenter`, `FeedStore`, `FeedRefresher`, `FeedParser`, `JSONFeedParser`, `FeedDiscovery`, `FeedOPML`, `FeedDownloadManager`, `FeedTransfer`, `FeedNetwork`, `FeedEpisodeImporter`, `FeedLifecycle`, `FeedNewestRule`, `FeedReconciler`, all in `TextMouth/Services/Feeds/`.
- The library's side: `LibraryViewModel+Feeds`, `+FeedItemMove`, `+DeleteFeed`, `+FeedDownloadReturn`; `FeedDownloadProgress`; the item policies of FR11, FR12, and FR19 (`FeedItemPolicy`, `FeedSettings`, `FeedBookUse`).
- The Mac's models the phone's screens drive, unchanged: `AddFeedModel`, `FeedInfoModel`, `OPMLImportModel`, the commands `FeedCommand` and `FeedItemCommand`, and the counts of `LibraryFeedFolders` and `FeedLibraryPresentation`.
- The Mac's words, reused: `FeedWording`, `FeedLibraryWording`, `FeedSettingsWording`, `FeedDownloadProgressWording`.
- What moves, not copies: the parts of `FeedCommandRunner` and `LibraryFeedsWindowSupport` that run a command and word its notice become window-free, and the Mac's window code calls them as the phone's sheet does.
- Podcast transcripts and chapters come with a download (`PodcastTranscriptReader`, `PodcastChapters`), so the phone reads them in its reader as it reads any transcript.

## Feeds, phase F1: subscribe, list, download, and listen

- Add Feed… returns to the Add to Library sheet, after Import Folder…: the Mac's sheet over `AddFeedModel`, an address field and the search's results, with the Mac's words.
- The Library view sheet offers Feeds again (`isOfferedOnPhone` lets it through), and a feed's folder row says "Feed" and its counts, as the Mac's Folders list does (`FolderRow.accessibilityLabel(name:bookCount:feedCounts:)`, which the phone passes `nil` today).
- A feed's folder lists its items as rows: title, date, and state ("Not downloaded", "Downloading, 40 percent", "Downloaded", "Played").
- Each item row's actions, in the Actions rotor and its context menu: Download, Play (once downloaded), Show Description…, Mark as Played, Move to Library…, Delete Download, the Mac's `FeedItemCommand` cases.
- Each feed's row adds Refresh Feed, Feed Info…, Unsubscribe, and Delete Feed…, the Mac's `FeedCommand` cases.
- Downloads run in the foreground session today's engine uses, and stop when iOS suspends the app; F3 moves them to the background.
- Refresh at launch and on Refresh Feed, through the engine; F2 adds the schedule.
- Tests: the row and action wording (`TextMouthTests`, shared), the Feeds choice through `PhoneLibraryChoicesTests`, and an interface test of the sheet's and a feed folder's VoiceOver order against a stubbed feed on GitHub.
- Text: about 2 new lines (the row state while downloading, which the Mac shows elsewhere, and the shortened stand-in note).

## Feeds, phase F2: refreshing in the background, and the Feeds settings

- A `BGAppRefreshTask` (`com.textmouth.TextMouth.iOS.feeds.refresh`, added to `BGTaskSchedulerPermittedIdentifiers` with the `fetch` mode) asks the engine to refresh every feed.
- It is registered in `TextMouthAppDelegate` before launch ends, scheduled again at each run and as the app goes to the background, with the Mac's interval as its earliest start.
- The engine's refresh is cut short at the task's expiration and finishes with `setTaskCompleted`; a refresh that starts downloads hands them to F3's session.
- Settings gains a Feeds section from the Mac's `FeedSettingsView` rows: refresh interval, refresh at launch, the item policy, and the newest count, as the phone's other sections are built (`PhoneSettingsSection`).
- The interval's hint says iOS chooses the moment: "iOS refreshes no sooner than this, when it allows."
- Tests: the scheduling decision as plain logic (when, which identifier, after which events), with a fake scheduler; `IOSInfoPlistTests` for the new mode and identifier; the config fixtures for any new setting.
- Text: about 2 lines (the interval's hint, and the section's footer if question 3 says so).

## Feeds, phase F3: downloads that go on with the app suspended

- The iPhone's download session becomes `URLSessionConfiguration.background(withIdentifier:)`, one session for every download, `sessionSendsLaunchEvents` on; a hosted test keeps the ephemeral session and its stub protocol, chosen where `FeedNetwork` is made.
- `application(_:handleEventsForBackgroundURLSession:completionHandler:)` keeps the handler; the engine's delegate calls it on the main queue once `urlSessionDidFinishEvents` arrives [5].
- A finished file is moved into the item's package before the delegate method returns, by the engine's existing import (`FeedEpisodeImporter`).
- Today each download has its own delegate awaiting a continuation (`FeedTransfer`); a background session has one delegate for every task and outlives the process, so the phone's half names each task by its item (`taskDescription`) and finds the item again after a relaunch.
  This is the phase's largest change, and the Mac keeps its own path.
- `FeedTransfer`'s redirect check (http and https only) is never called in a background session [5], which carries only HTTP and HTTPS anyway; the final URL comes from the task's response, as `finalURL` does today.
- A force-quit's cancelled downloads restart at the next launch from what `FeedDownloadManager+PartialDownloads` kept, as the Mac's do after a quit.
- A download card at the top of the Library, from `PhoneImportProgressCard`'s pattern, over the Mac's `FeedDownloadProgressWording`, with Cancel.
- Cellular: question 2; the recommended answer is a switch "Download on cellular", off, setting `allowsCellularAccess`.
- Tests: the session choice; the completion-handler bookkeeping with a fake session; the move into the package; the redirect check on a final URL.
- Text: about 2 lines (the switch and its hint).

## Feeds, phase F4: OPML, Feed Info's options, and the rest of the Mac's set

- Import Subscriptions… and Export Subscriptions… through SwiftUI's `fileImporter` and `fileExporter` in place of `NSOpenPanel` and `NSSavePanel`, over `OPMLImportModel` and `FeedOPML`, one shared seam that both platforms' sheets call.
- Feed Info… on the phone: the Mac's `FeedInfoModel`, its description as a read-only text area (`ReadOnlyTextArea+iOS.swift`), the feed's two exceptions to the feed settings, and its folder.
- FR19's listening options for a feed's folder come with the phone's folder options, whenever those reach the phone (FR23).
- FeedArrivals' announcement after a refresh the person asked for, through `PhoneAnnouncer`; a background refresh says nothing, by the spec's rule that the book is the feedback.
- Tests: the OPML seam on both platforms, Feed Info's VoiceOver order on GitHub.
- Text: none expected; every word is the Mac's.

## Feeds: the iPhone screens in VoiceOver's order

- **Add Feed:** the heading "Add Feed"; Cancel; the address field, focused; Subscribe; then the search's results, each one element with its title and author; the plain-http warning, when it applies, as an alert.
- **A feed's folder:** the heading, the feed's name; its summary row ("12 items, 3 downloaded, 2 new"); the items, newest first, each one element whose actions are in the Actions rotor; then the bottom bar (Sort, Add to Library), as a folder screen has today.
- **An item's row:** label "Episode 212: The Long Count", value "Downloaded, 41 minutes, played to 12 minutes", hint the Mac's; double-tap opens it in the reader once downloaded, and starts the download otherwise.
- **Feed Info:** the heading; Done; the feed's title, author, and address as rows; its description; "Where downloads go"; its two exceptions, each a picker that names the global setting it follows; Unsubscribe and Delete Feed… last, apart.
- **The download card:** one element, "Downloading 3 episodes, 40 percent, Episode 212", with Cancel after it.

## Recording: the shared code, and what the iPhone adds

- Shared and used as they are: `RecordingService` (start, pause, resume, stop, take recovery), `RecordingTake`, `RecordingEncoder` (AAC in `.m4a`), `FileImportService+Recording`, `LibraryViewModel+Recording`, `RecordingWindowModel`, `RecordingWording`, `AudioInputPermission`.
- New on the iPhone, in `TextMouth/Platform/iOS/Services/`:
  - an `AVAudioEngine` backend for the existing `RecordingCaptureBackend` protocol, writing the same 16-bit PCM CAF take through an input tap, with the levels from the tap's buffers; it replaces the iOS stand-in in `RecordingCaptureBackend.swift`;
  - the recording half of `PhoneAudioSession`: `playAndRecord` with `allowBluetoothHFP` and `bluetoothHighQualityRecording`, only while the Record screen records, then back to `playback` and `spokenAudio`, never a switch while a book plays (the session pauses the book first);
  - an iOS `RecordingInputCatalog` over `AVAudioSession.availableInputs` and `setPreferredInput`, in place of the capture-device list, so AirPods, wired headsets, and USB microphones are named as iOS names them.
- Permission through `AVAudioApplication.requestRecordPermission`, mapped onto the shared `AudioInputAuthorization`; the denied sentence gets an iPhone wording that names Settings, Privacy & Security, Microphone, and its button opens `UIApplication.openSettingsURLString`.
- The count-in is a short sound bundled in the app (a few kilobytes), since iOS has no `/System/Library/Sounds` for an app.

## Recording, phase R1: the Record screen

- New Recording… joins the Add to Library sheet, after Import Folder…, with the Mac's summary "Records from a microphone into a new audiobook."
- The Record screen, a sheet over `RecordingWindowModel`, in VoiceOver's order, every word the Mac's (`RecordingWording`):
  - the heading "New Recording", then Close;
  - Microphone, a picker; Title, a field; Save in, a picker of the library's folders;
  - Record, which becomes Pause or Resume, then Stop, which saves the audiobook;
  - the time and level, one element read when the person moves to it, never announced while recording;
  - once saved, Open in Reader.
- The Mac's microphone hint names macOS, so the iPhone needs its own line.
- Recording goes on with the screen locked and the app in the background, through the `audio` mode; the screen stays awake while it is shown (`PhoneScreenSleep`).
- A call or Siri pauses the take and says so once the call ends ("Recording paused by a call. 12 minutes kept."); it never resumes on its own, as the iPhone's playback rule already reads Apple's guidance (`PhoneAudioEventPolicy`).
- AirPods taken out, or a headset unplugged, pause the take as the Mac's `deviceDisconnected` does, and the built-in microphone is offered.
- The app going to the background mid-save finishes the encode in a `BGContinuedProcessingTask`, like the export's.
- Tests, none with a real microphone: the backend against a fake engine source writing a known buffer; the session's category switches with a fake session; the interruption and route decisions as plain logic; the screen's VoiceOver order on GitHub without recording.
- Text: about 4 lines (the iPhone's denied sentence, the microphone hint, the call's pause sentence, and the shortened stand-in note).

## Recording, phase R2: recovered takes and the rest

- Recovered recordings: the Mac's list at the top of the Record screen, from `RecoveredTake`, to save as audiobooks or discard; a take a crash or a forced end left is readable to where it stopped, by its format.
- A launch after iOS ended the app mid-recording offers them once, as the Mac's launch does.
- `RecordingWindowController+iOS.swift` and the iOS stand-in backend go; `IOSUnavailable.feature("Recording")` goes with them.
- Tests: the recovery list from a fixture take in the test's own sandbox; the launch offer's decision.
- Text: none expected.

## The editor: the shared code, and the touch screen

- Shared and used as they are: `AudioEditSession`, `AudioEditorModel` and its extensions, `AudioEditRenderer`, `AudioFilterRunner`, `AudioEditorPlayer`, `AudioEditorLevels`, `AudioEditorWording`, and `LibraryViewModel+AudioEditing`.
- `AudioEditHistoryStore` saves each edit as it is made, so a suspension loses nothing.
- The Mac's window is a column of every command as a button, under four headings: Listen, Select, Edit, File (`AudioEditorView.groups`, 41 commands); each is a shortcut action, so the Mac reaches all of them by key.
- On the iPhone that column stays, since a list of labeled buttons under headings is what VoiceOver reads best, and the headings rotor moves between the four groups.
- What the touch screen adds: the time display becomes the screen's one adjustable element, the reader's UIKit control (`PhoneControl`) with its value computed when VoiceOver asks.
  - Swipe up or down moves the cursor by the step chosen (the Mac's skip, long skip, and short skip as the step), and says the new time.
  - Its Actions rotor holds the commands used most while moving: Play or Pause, Mark In, Mark Out, Play Selection, Cut, Undo, Add Marker, the Mac's names.
  - Custom rotors on it: Chapters, Markers, and Pauses, each landing the cursor on one.
- The waveform stays for sighted helpers, hidden from VoiceOver, as on the Mac.
- The Mac's sheets come over: the prompts (Go to Time, Insert Silence, chapter names), Markers, Filters, the progress of a save, and Info.
- Never Ogg through Apple's players: the editor's preview is an `AVPlayer`, so a book whose audio is Ogg is refused before a session opens, with `make lint-ogg` run on the branch.

## Editor, phases E1 to E3

- **E1, open, listen, select, edit, save.** Edit Audio… as an action of an audiobook's row (and of the reader's Book Actions once FR51 has one), over the shared `LibraryAudioCommand.isAudioEditable`.
  `AudioEditorTracks` moves to shared code, and a choice sheet picks a track; then the screen above.
  Save renders through the library, in a `BGContinuedProcessingTask` when the app leaves the front.
  Leaving with unsaved edits asks "Save changes?" as the Mac's close does; a suspension saves nothing new, since the history holds every edit.
- **E2, export and filters.** Export through `fileExporter` in place of `NSSavePanel`, one shared seam with the Mac's sheet; the filter sheet; MP3 through the built-in encoder.
- **E3, Punch In, and a keyboard.** Punch In over R1's backend and audio session (so after R1); the Mac's editor shortcuts as iPadOS key commands, read from the same shortcut list; the launcher and window-controller stand-ins go.
- Tests: the adjustable step and its spoken value as plain logic; the rotors' entries from a session with chapters and markers; the Ogg refusal; E1's screen order and the Actions rotor's names on GitHub; save and export through the existing renderer tests, which run on the Mac and serve both.
- Text: about 3 lines in E1 (the step's name, "Save changes?" if the Mac's words don't fit, the shortened note), none in E2, 1 in E3 (removing the note).

## Size

- Measured on November 27 (train `--ios-size`): the iPhone app is 17.3 MB, 17.2 MB as an estimated App Store download, against the 30 MB limit (40 strict).
- The engines are compiled into the iPhone app today; the feed engine is live (`startFeeds()`), while the editor's and the recording's models, reached from no iPhone screen, are likely stripped by the Release build's dead-code stripping and come back as screens reach them.
- Estimates, each to be measured with `--ios-size` on its branch's last train: feeds F1 to F4, 0.3 to 0.6 MB; recording, 0.1 to 0.3 MB with the sound; the editor, 0.4 to 0.8 MB.
- Over all nine phases, about 1 to 2 MB, so about 19 MB.
- Nothing here adds a library: AVAudioEngine, BackgroundTasks, and URLSession are the system's.

## The tests every phase keeps

- No test uses a microphone, plays sound aloud, or reaches the network: the capture backend reads a fake source, the feeds a stub protocol, the player a stand-in (`AudioEditorPlayer`'s test player).
- No test traps: no force unwraps of a session's state, every wait limited.
- Shared logic is tested once in the Mac's bundles; a test the phone must also run is shared by path with the iPhone unit bundle, as `docs/developer/testing.md` says ("iPhone unit").
- Each new screen gets its order in `ScreenOrderUITests` and an accessibility audit in its interface test, on GitHub only.
- Each branch names its classes and `--areas phone` in its train, and its last train asks for `--ios-size`.
- A new setting names the config fixtures' tests; a new `Info.plist` key, `IOSInfoPlistTests`.

## Questions for the user

1. Should feed subscriptions sync between the Mac and the iPhone, or does each device keep its own? Recommended: each its own for F1 to F4; syncing subscriptions is the sync plan's "What waits", later.
2. Should the iPhone download episodes on cellular? Recommended: a switch, "Download on cellular", off.
3. The Mac's refresh interval can only be a minimum on the iPhone, since iOS picks the moment. Keep the setting with that hint? Recommended: yes.
4. Which first: feeds, recording, or the editor? Recommended: feeds, then recording, then the editor, which needs recording for Punch In.
5. Does New Recording… belong in the Add to Library sheet, as on the Mac? Recommended: yes.
6. The editor on the iPhone with VoiceOver first, or the iPad with a keyboard first? Recommended: the iPhone, since that is the device in use; the iPad's keys in E3.
7. When a call interrupts a recording: pause and keep the take, resuming only when asked? Recommended: yes.
8. AirPods' high-quality recording where iOS offers it, falling back to the headset microphone? Recommended: yes.
9. A feed's episodes stay off the sync, as now? Recommended: yes, until subscriptions sync.
10. The immediate note in the Add to Library sheet only, or also in Settings, About? Recommended: the sheet only, one home.
11. Feeds' folders reach the iPhone empty today. Leave them out of the sync, as the sync plan said, until feeds sync? Recommended: yes (sync's owner decides; posted as a finding).

## Sources

1. Apple, `BGAppRefreshTask`. https://developer.apple.com/documentation/backgroundtasks/bgapprefreshtask
2. Apple, `BGProcessingTask`. https://developer.apple.com/documentation/backgroundtasks/bgprocessingtask
3. Apple, `BGContinuedProcessingTask`. https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask
4. Apple, "Using background tasks to update your app". https://developer.apple.com/documentation/uikit/using-background-tasks-to-update-your-app
5. Apple, "Downloading files in the background". https://developer.apple.com/documentation/foundation/downloading-files-in-the-background
6. Apple, `URLSessionConfiguration.background(withIdentifier:)`. https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)
7. Apple, `AVAudioApplication.requestRecordPermission(completionHandler:)`. https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission(completionhandler:)
8. Apple, "Handling audio interruptions". https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions
9. Apple, `AVAudioSession.CategoryOptions.allowBluetoothHFP`. https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/allowbluetoothhfp
10. Apple, `AVAudioSession.CategoryOptions.bluetoothHighQualityRecording`. https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/bluetoothhighqualityrecording
11. Apple, `AVAudioSession.Category.playAndRecord`. https://developer.apple.com/documentation/avfaudio/avaudiosession/category-swift.struct/playandrecord
12. Apple, `accessibilityAdjustableAction(_:)`. https://developer.apple.com/documentation/swiftui/view/accessibilityadjustableaction(_:)
13. Apple, `accessibilityAction(named:_:)`. https://developer.apple.com/documentation/swiftui/view/accessibilityaction(named:_:)
14. Apple, `accessibilityRotor(_:entries:)`. https://developer.apple.com/documentation/swiftui/view/accessibilityrotor(_:entries:)
15. Apple, "Responding to audio route changes". https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes
