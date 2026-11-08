# What iOS does to TextMouth

Report of `iosui-research-ios`, team `iosui`, November 7, 2026. Research only. Nothing here ran on iOS.

## How to read this

- Every claim carries a mark. DOCUMENTED: Apple says so in a document or an SDK header ("by DTS" means an Apple support engineer wrote it in the forums). REPORTED: someone says so in a forum, a blog, or a repository, unconfirmed by Apple. INFERRED: my reasoning from the code and the documents, which nobody has said or tested.
- "SDK" is `/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk`, iOS 26.0, from Xcode 26.0.1. Headers are cited by file name and line.
- "Thread N" is https://developer.apple.com/forums/thread/N. "Guide" is Apple's archived Audio Session Programming Guide, whose base is https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/.
- Code paths are relative to the repository, on branch `ios/interface` at 1ad90f4b.
- Limits of the sources: Apple's pages are dated 2026 and mention iOS 27, but this SDK is 26.0, so nothing from iOS 27 can be compiled here. The forums began refusing me near the end, so threads 736148, 730639, 716409, 660673, 748135, 801126, 73166, and 743633 are known only from search summaries. So is one Medium article.

## The ten things to know first

1. The data directory resolves outside the sandbox, because `TextMouthRuntime.realHomeDirectory` reads the user database. Nothing can be written on the first launch (section 6).
2. No code in `TextMouth/` configures an audio session, so the app would stop at the screen lock and obey the silent switch (section 1).
3. Importing any M4A, M4B, or MP4 fails, because the import asks `afinfo` first and the stand-in throws (section 7).
4. The generated Info.plist has no background mode, document types, or imported types, and those keys have no `INFOPLIST_KEY_` setting. A real plist, merged by `GENERATE_INFOPLIST_FILE`, is required (section 8).
5. `playbackState` does nothing on iOS. The lock screen's state comes from the session and the rate (section 3).
6. Nothing saves when the app goes to the background, and a suspended app is killed with no notice (section 4).
7. Route changes and interruptions have no handler. Headphones out would go on speaking aloud (section 1).
8. The biggest open risk is a report from October 2026 that a direct utterance pauses at the screen lock and resumes at unlock. A first run must check this first (section 2).
9. Every silent gap (a chapter pause, the next-book delay, chapter preparation) relies on a main-queue timer, which suspension freezes (section 4).
10. A background render at full speed can reach the CPU monitor's limit of 80 percent over 60 seconds (sections 2 and 5).

## 1. AVAudioSession

### Category, mode, and options

- Category `.playback`: it keeps playing with the silent switch on and allows background audio. Source: https://developer.apple.com/documentation/avfoundation/configuring-your-app-for-media-playback. DOCUMENTED. The default session is solo ambient, which stops at the lock (QA1626, https://developer.apple.com/library/ios/qa/qa1626/_index.html, old). DOCUMENTED. `grep AVAudioSession` finds nothing in `TextMouth/`, so that default is what the code gets today.
- Mode `.spokenAudio`: for apps that "play spoken audio and wish to be paused (via audio session interruption) rather than ducked if another app (such as a navigation app) plays a spoken audio prompt", naming podcast players and audio books. Source: `AVAudioSessionTypes.h:176-179`. DOCUMENTED. It fits speech and audiobooks: a person walking with Maps gets a pause and a resume, not speech over speech.
- `.default` would be ducked instead. `.voicePrompt` (`AVAudioSessionTypes.h:181-185`) is for short prompts.
- Caveat: a third-party article claims `.spokenAudio` degrades neural voices on real iPhones. REPORTED, once, search summary only. Compare the two modes by ear at the first run.
- Options: none.
  - `.mixWithOthers` costs the lock screen. WWDC22 session 110338: to be eligible, "your apps AVAudioSession must be configured with a non-mixable category and category option". Source: https://developer.apple.com/videos/play/wwdc2022-110338. DOCUMENTED.
  - `.duckOthers` (`AVAudioSessionTypes.h:444-445`) and `.interruptSpokenAudioAndMixWithOthers` (`:492-494`) both set MixWithOthers. DOCUMENTED. Thread 849627 saw `duckOthers` stop its app showing as Now Playing. REPORTED.
  - `.allowBluetoothHFP` cannot be changed in other categories (`:468-470`). `.allowBluetoothA2DP` is "always implicitly true" in output-only categories (`:513-515`), so AirPods work with no option. `.allowAirPlay` is "Only valid with" PlayAndRecord (`:524-528`). DOCUMENTED.
- `setPrefersNoInterruptionsFromSystemAlerts` (https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions, DOCUMENTED): leave it false, so a ringing call interrupts the book. That choice is mine.

### Activating and deactivating

- Activation blocks: "activating an audio session is a synchronous (blocking) operation", so don't do it "from a thread where a long blocking operation will be problematic". Source: `AVAudioSession.h:239-241`. DOCUMENTED. No time is given anywhere. Thread 759553 says it "causes the UI to pause updates". REPORTED. So use one serial queue for the session, off the main thread, and start audio on the main thread once it answers. INFERRED.
- When to activate: "defer this call until your app begins audio playback" (media playback article); "wait for the user to press the Play or Record button" (Guide, `AudioGuidelinesByAppType/AudioGuidelinesByAppType.html`). DOCUMENTED.
- While active: "While the app is in the foreground, keep the audio session active unless it's interrupted." Source: same Guide page. DOCUMENTED.
- When to deactivate: "If the app is not actively playing or recording audio when it transitions to the background, deactivate its audio session." Source: same page, and https://developer.apple.com/documentation/avfaudio/avaudiosession/interruptionnotification. DOCUMENTED.
- After a suspension: "Assume the app's audio session is inactive when it transitions from a suspended to foreground state." Source: same page. DOCUMENTED.
- Rules for deactivating: "first stop or pause all running I/Os". It used to return `IsBusy`, and "Starting in iOS 19.0, deactivating while IO is running will no longer return" it. Source: `AVAudioSession.h:247-254`. `.notifyOthersOnDeactivation` tells an interrupted app it may resume (`AVAudioSessionTypes.h:627-629`). DOCUMENTED.
- A trap: pausing only the player node and deactivating gave `IsBusy`, and a later resume played nothing or skipped the rest of the buffer. The author's own answer was not to deactivate on pause, only at `willResignActive` when paused. Source: thread 773870, February 2025. REPORTED.
- Automatic activation: "AVFoundation playback and recording classes automatically activate your audio session" (Guide, `ConfiguringanAudioSession/ConfiguringanAudioSession.html`). `AVAudioEngine.prepare` and `start` "may cause the audio session to be implicitly activated" (`AVAudioEngine.h:326, 350`). DOCUMENTED. `AVSpeechSynthesizer` activates on its own and doesn't deactivate, and `setActive(false)` right after fails with `!act`, which an Apple engineer reproduced (thread 759553, July 2024). REPORTED.
- Refusal: "Write your code to gracefully handle the system's refusal" (same Guide page). Codes: `!act` 560030580, `!int` cannot interrupt others 560557684, `!pla` cannot start playing 561015905, `!pri` 561017449, and `inac`. Source: `CoreAudioTypes.framework/Headers/AudioSessionTypes.h:85-97`. DOCUMENTED.

### Interruptions

- Thread: posted on the main thread (`interruptionNotification` page). DOCUMENTED.
- At the start, the system deactivates the session and audio stops. At the end: "Media playback apps should always look for this flag before beginning playback after an interruption. If it's not present, playback should not begin again until initiated by the user." Source: Guide, `HandlingAudioInterruptions/HandlingAudioInterruptions.html`. DOCUMENTED.
- The end may never come: "There is no guarantee that a begin interruption will have a corresponding end interruption." Source: same. DOCUMENTED. So any Play must try to reactivate.
- Calls: "Your app may be suspended following an interruption. This happens when a user accepts a phone call." Siri: "you must keep track of any remote control commands issued by Siri while the audio session is in an interrupted state", and the app "should not automatically resume playing". Source: same. DOCUMENTED.
- `wasSuspended` is gone: "Interruption notifications with reason 'wasSuspended' not present from iOS 16 onwards." Source: `AVAudioSessionTypes.h:595-597, 611`. DOCUMENTED. The web page still describes the key, but the header is newer. So a suspension can't be detected this way.
- Remaining reasons: `default`, `builtInMicMuted`, and `routeDisconnected` from iOS 17. None for Siri, a call, or an alarm (`AVAudioSessionTypes.h:609-622`). DOCUMENTED.
- iOS 27 adds `didBecomeInactiveNotification` and `resumptionRecommendationNotification`, and the system deprecates the legacy notification "in later releases" (interruptions article). DOCUMENTED. They aren't in this SDK (grep finds none). Use the legacy one: the deployment target is 26.0.
- Which objects stop themselves: "AVFoundation: The system automatically pauses playback or recording upon interruption and reactivates your audio session when you resume." Audio queues and I/O units: "These technologies put your app in control." Source: Guide's Table 3-2. DOCUMENTED. `AVAudioEngine` isn't in that table. REPORTED: "the engine stops without the node being stopped", and calling the node's `play` on a stopped engine raises an exception (https://github.com/a-ghorbani/react-native-speech/issues/45).
- What the engine needs afterwards: reactivate, `engine.start()`, then `playerNode.play()`. `AudioEngineService.resume()` already restarts a stopped engine first (`AudioEngineService.swift:1456-1463`). The most robust path is the flag the code has: `invalidatePlaybackBackendForAudioRouteChange()` (`ReaderViewModel+Playback.swift:333-336`) makes the next Play cold-start at the cursor. INFERRED.
- A trap in shared code: `SpeechService` takes any `didCancel` of the live utterance as the speech engine refusing the text (`SpeechService.swift:2702-2718, 1495-1514, 1544-1555`). On iOS an interruption or media reset may cancel it. Speech would then replace the synthesizer, drop brackets, spend the place's one retry, and may announce a refusal. INFERRED. The handler must set a flag this code checks. The watchdogs are safe once the reader is paused (`SpeechService.swift:1277-1285`).

### Route changes and AirPods

- Thread: "The system posts this notification on a secondary thread." Source: https://developer.apple.com/documentation/avfaudio/avaudiosession/routechangenotification. DOCUMENTED. In the Swift 6 mode a main-actor closure traps there, as MediaPlayer's handlers could (`NowPlayingService.swift:791-795`). Use `addObserver(forName:object:queue: .main)`. INFERRED.
- "Media playback apps should pause playback if the route change reason is AVAudioSessionRouteChangeReasonOldDeviceUnavailable, but should not if the reason is AVAudioSessionRouteChangeReasonOverride." Source: Guide, `HandlingAudioHardwareRouteChanges/HandlingAudioHardwareRouteChanges.html`. DOCUMENTED.
- `AVPlayer` pauses itself: "When they disconnect their headphones, playback is automatically paused." Source: https://developer.apple.com/documentation/avfaudio/responding-to-audio-route-changes. DOCUMENTED. Nothing promises this for speech or an engine, so those go on aloud until the app acts. INFERRED.
- From iOS 17, "by default Now Playing sessions will be interrupted if they are active when a route change occurs because of a disconnect event." Source: `AVAudioSession.h:492-494`. DOCUMENTED. So one disconnect gives an interruption and a route change, in an unstated order. The handler must be idempotent.
- `AVAudioEngineConfigurationChangeNotification`: on a change of hardware channel count or sample rate "the engine stops itself", and the callback "happens on an internal dispatch queue", where the engine must not be released. Source: `AVAudioEngine.h:885-895`. DOCUMENTED. `AudioEngineService` has no observer (grep finds none). AirPods going in or out while it plays leaves `isPlaying` true over silence, and no watchdog watches the engine. If the node then reports the last slice with `isPaused` false, `SpeechSegmentEndPolicy` calls it finished (`AudioEngineService.swift:185, 795`) and the next chapter starts. INFERRED.
- Ear detection, at user level: AirPods "pause and resume" for one AirPod and stop for both (https://support.apple.com/en-us/108764). DOCUMENTED.
- What the app receives: Apple staff, 2018: "The MPRemoteCommandSample shows how media applications can support the automatic pause and play functionality with the AirPods when taking them in and out of the ear." Source: thread 97554. REPORTED. So remote commands, not a route change, though nobody names which. Sleep Detection (iOS 26) gives "a standard pause", with no reason (thread 842375, August 2026). REPORTED.
- Both out: expect `.oldDeviceUnavailable` once the route goes to the speaker, but no source states the sequence. This can't be known until a first run. The remote command path already handles Pause and Play, so leave it alone and log what arrives.

### Media services reset

- Posted on the main thread with no `userInfo`. Reinitialize audio objects and reset category, options, and mode. "Don't restart playback, recording, or processing until the user initiates it." Don't re-register notifications. Test with Settings, Developer, Reset Media Services. Sources: https://developer.apple.com/documentation/avfaudio/avaudiosession/mediaserviceswereresetnotification and QA1749, https://developer.apple.com/library/archive/qa/qa1749/_index.html. DOCUMENTED.
- For TextMouth: set the category again; replace `directSynth` (`replaceDirectSynthesizer` exists) and `whereAmISynth`; release the `AVQueuePlayer`; rebuild `AVAudioEngine` and its nodes (`playerNode` and `timePitch` are bound at init); keep `RenderedSpeechAudio`, which is plain memory; clear `warmedVoices`; show the book paused at its place. INFERRED.

### Long-form route and spatial audio

- `.longFormAudio` sends output where Music and Podcasts play, allowed with `.playback` and `.spokenAudio`, with no options. Sources: `AVAudioSessionTypes.h:696-703`, `AVAudioSession.h:59-68`. DOCUMENTED. It matters only with AirPlay, so try it later. INFERRED.
- Spatial audio doesn't apply to mono speech. The Spatial Audio Profile capability isn't on a free team (section 8).

## 2. Background audio

### What keeps the app running

- iOS's "default behaviour is to suspend your app shortly after the user has moved it to the background"; "If you're building a music player, use the `audio` background mode." Source: Quinn, thread 685525. DOCUMENTED by DTS. With the mode and a configured session "your app is ready to play background audio" (media playback article). DOCUMENTED.
- Must audio be audible? No document says. "Use a background task instead of streaming silence to keep the app from being suspended" (Guide, guidelines page). The Energy Guide lists "Playing silent audio" among background energy wasters (https://developer.apple.com/library/archive/documentation/Performance/Conceptual/EnergyGuide-iOS/WorkLessInTheBackground.html). DOCUMENTED. Apps run silent keep-alive loops (thread 849627). REPORTED. My reading: running audio output counts, not whether it can be heard. INFERRED.
- How soon after audio stops? No source gives a number. It can't be known until a first run. Design for "almost at once".
- "Starting in iOS 10, the system deactivates an app's audio session when it suspends the app process." Source: `interruptionNotification` page. DOCUMENTED.

### The direct path: `speak(_:)`

- `usesApplicationAudioSession`: YES (default) uses the shared session. NO uses a separate one that "will mix and duck other audio", managed for you, perhaps on another route. Sources: `AVSpeechSynthesis.h:259-263`, https://developer.apple.com/videos/play/wwdc2020/10022/. DOCUMENTED. Keep YES: NO is mixable, which costs Now Playing.
- No Apple document says what `speak` does in the background. The reports, all REPORTED:
  - October 2026, thread 849627, unanswered, through `expo-speech`: "speech that has already started reliably pauses mid-utterance the moment the screen locks, and resumes and completes the moment the screen is unlocked", with `.playback`, background audio, a running `AVAudioPlayer`, and no error. Some builds never completed. This is the most important open question. If true, a locked phone reads nothing on this path, and the playback watchdog sees nothing wrong, since `isSpeaking` stays true (`SpeechService.swift:1206-1213`, INFERRED).
  - 2015, threads 27097 and 23160, iOS 9: speech sometimes waits for the foreground. Workaround: half a second of silence through `AVAudioPlayer` right after `speak`. Old, no Apple answer.
  - 2023 to 2024, thread 737685: long utterances stop part way on iOS 17, tied to one voice. TextMouth's chunks of 1,000 and 5,000 units (`SpeechService.swift:756, 761`) keep utterances short.
  - 2024 to 2025, thread 762207: the first `speak` waits seconds with `IPCAUClient: can't connect to server (-66748)`, one poster saying on iOS 26 alone. Workaround: a silent warm-up word. `VoiceWarmUp` (`SpeechService.swift:341-345`) writes one, though whether that helps `speak` is unknown, and the 10-second cold watchdog (`SpeechService.swift:784`) allows for the delay.
  - June 2026, Swift Forums, iOS 26.5.1: a short utterance is occasionally not spoken (https://forums.swift.org/t/avspeechsynthesizer-occasionally-doesnt-speak/87505).
  - October 2025, thread 804648: `AVSpeechSynthesisVoice(language:)` ignores the voice chosen in Settings on iOS 26. Apple couldn't reproduce it, and an identifier works. `SpeechService.swift:955` falls back to `"en-US"`, so the voice sheet must save an identifier.
- Without an active session it activates by itself (thread 759553). REPORTED. In the background that non-mixable activation may fail with `!int`. INFERRED.
- Between two utterances: no document. TextMouth hands the next chunk over while the current one speaks (`SpeechService.swift:1101-1113`), so no app code runs in the gap. That is the best design for the background. INFERRED.
- A pause in speech: `pauseSpeaking` stops output, so the app can be suspended soon after. How long a paused utterance stays resumable is unstated. The code already falls back when `continueSpeaking` fails (`SpeechService.swift:2006-2014`).

### The engine path: `write` and `AVAudioPlayerNode`

- Rendered buffers through a running `AVAudioEngine` are ordinary audio output, needing no speech service while they play, so a lock can't stall them the way thread 849627 describes. INFERRED. The feeder schedules about nine seconds ahead on its own queue (`AudioEngineService.swift:900-905, 813-819`), with no main thread needed.
- `write`: a callback never firing on iOS 16 was traced to a local synthesizer or a nil voice (thread 714984). TextMouth holds the synthesizer and passes a voice. REPORTED.
- Personal Voice: "Cannot use AVSpeechSynthesizerBufferCallback with Personal Voices, defaulting to output channel" (thread 736148). REPORTED. Leave them out of rendering, or they may play aloud.
- Memory growth: thread 730639, iOS 16, reported gone in the iOS 17 beta. REPORTED. Nothing current found.
- CPU: "iOS employs a CPU Monitor that watches background apps for excessive CPU usage", with the example "(Limit 80%) Observed 89% over 60 seconds" (Energy Guide). DOCUMENTED. A 15 percent limit is reported for voice apps on iOS 15.2 to 15.3 alone. REPORTED. A crash thread names `com.apple.TextToSpeech.SpeechThread` (716409), suggesting synthesis runs in the app's process. INFERRED. A look-ahead render runs on a `.userInitiated` global queue (`AudioEngineService.swift:929`), up to 100,000 units, so one lasting over about 48 seconds in the background risks `CPU_FATAL`. INFERRED.
- Does a `write` activate the shared session? Nobody says. `VoiceWarmUp` writes one word when a reader opens (`SpeechService.swift:484-490`). If that activates `.playback`, opening a book stops the user's music before Play. INFERRED. Check it. The fix would be `usesApplicationAudioSession = false` on rendering synthesizers, under `#if os(iOS)`.
- `speechVoices()`: the only measurement is the code's own, 65 to 114 ms on the Mac (`VoiceCatalog.swift:7-10`). Nothing found for iOS. `VoiceCatalog` already lists off the main thread.

### Starting again from a remote command

- Commands reach "the app that's currently or was most recently playing", and "An app doesn't receive remote control events until it begins playing content." Source: https://developer.apple.com/documentation/mediaplayer/handling-external-player-events-notifications. DOCUMENTED.
- "The system launches or resumes the app, in the background, and affords it time to process any related events." Source: https://developer.apple.com/documentation/xcode/configuring-background-execution-modes. DOCUMENTED.
- Activating non-mixable audio from the background: Apple Support, relayed in 2021: "If an app is in the background..., by design, it can only start audio with mixing" (thread 668820). `setActive` after a call in the background fails with `!int` until the app opens (thread 813278, `.playAndRecord`). REPORTED. Yet podcast apps resume from the lock screen daily, and nothing I found explains how. My reading: the Now Playing app gets an allowance. INFERRED. This can't be known until a first run.
- A force-quit app: iOS "sets a flag that prevents the app from being launched in the background" until the user opens it (thread 685525). DOCUMENTED by DTS.
- A killed app relaunched for a Play needs its targets at launch. TextMouth registers them at the first reader's `setup` (`NowPlayingService.swift:509, 668-673`) and answers `.commandFailed` with no owner (`:850`). So after a kill, lock-screen Play does nothing. INFERRED.

### Which path for books

- The user's rule, `feedback_playback_architecture.md`: never switch direct to engine during playback, only at natural breaks (seek, pause and resume, chapter boundary). The code keeps it (`SpeechService.swift:1006-1064`).
- Recommendation for the first build: keep the Mac's policy, direct at Play with the render behind it, and the engine from the next natural break. It needs no rewrite of shared code, and the suite describes it. Word places come from the synthesizer on the direct path, where the engine path estimates them (`AudioEngineService.swift:1222-1234`). The engine takes over at the first chapter boundary, so most of a long listen is on the path least exposed to a lock stall.
- Three iOS-only additions keep the rule and reduce the risk:
  - Prefer finished rendered audio at Play: if the chapter's render is ready, start with `usePreRenderedEngine`, so nothing switches at all.
  - A word-progress watchdog: if `isSpeaking && !isPaused` and no `willSpeakRange` arrives for several seconds, nothing is being heard, so it is a natural break. Recover as `recoverFromIdleDirectSynthesizer` does, at the last reported word. This covers thread 849627's stall, which the present watchdog misses.
  - No Personal Voices in rendering.
- The one fact that can overturn this: if the first run shows direct speech stalls at the lock, make iOS engine-only. Play renders a short head (about the first 1,000 units), starts the engine, and goes on rendering behind it. That needs a feeder that can take audio still being written, which the immutable `RenderedSpeechAudio` can't do. The rule still holds, since nothing ever switches.

## 3. Now Playing and remote commands

### What must be true

- "First, you must register a handler for at least one remote command. Second, your apps AVAudioSession must be configured with a non-mixable category and category option." Source: WWDC22 110338. DOCUMENTED.
- "You don't have direct control over what information the system displays, or its formatting." Source: https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter. DOCUMENTED.

### Metadata

- `playbackState`: "This only applies on macOS, where playback state cannot be determined by the application's audio session." Source: `MPNowPlayingInfoCenter.h:66-70`. DOCUMENTED. `NowPlayingService.swift:1227, 1237` set it. That is harmless, so leave it for the Mac. Threads 773870 and 730114 report a stale pause icon on iOS: rate 0 alone didn't change it, and it came right once the session was deactivated. REPORTED.
- Elapsed time "will be automatically extrapolated from the previously provided elapsed time and playback rate" (`MPNowPlayingInfoCenter.h:83-86`). Update on a play, a pause, a seek, and a new item (WWDC22). DOCUMENTED.
- Rate and default rate: if 1.5 is the listener's normal speed, both are 1.5, and a paused item has rate 0 (`MPNowPlayingInfoCenter.h:88-101`). DOCUMENTED.
- `MPNowPlayingInfoPropertyIsLiveStream` (`:118`): leave false. `MPNowPlayingInfoPropertyMediaType`: audio, as the code sets (`NowPlayingService.swift:1233`). `MPNowPlayingInfoPropertyChapterNumber` is zero-based (`:112`). DOCUMENTED.
- `MPNowPlayingSession` is created with `AVPlayer`s: "This will assert if players is nil or empty" (`MPNowPlayingSession.h:37-38`). DOCUMENTED. The speech path has no `AVPlayer`, so don't use it. Use the shared `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter`, as the Mac does.

### Which commands show, and which press sends what

- AirPods, user level: press once, play or pause; twice, skip forward; three times, skip back. Head gestures are for "responding to calls, messages, and more". Source: https://support.apple.com/en-us/102628. DOCUMENTED.
- Command names: single press `togglePlayPauseCommand`, double press `nextTrackCommand` (https://www.glucode.com/blog/posts/enabling-now-playing-and-earphone-button-controls-for-an-audio-app, 2021). Double and triple as next and previous track, on macOS (https://github.com/faymatt99/airpods-keybind). REPORTED. Whether a double press falls back to `skipForwardCommand` when next track is disabled, nobody says.
- Lock screen and Control Center: "iOS system media controls have only two side buttons", and "enabled skip-interval commands take those slots ahead of" next and previous (https://github.com/riteshshukla04/react-native-nitro-player/pull/182). REPORTED. Thread 818270 (March 2026) saw skip buttons with skip disabled, for video, so media type may matter. REPORTED. No Apple document states the rule.
- `changePlaybackPositionCommand` is the scrubber; `seekForwardCommand` and `seekBackwardCommand` are hold-to-seek; `changePlaybackRateCommand` has no lock-screen control I can confirm; `bookmarkCommand` is an `MPFeedbackCommand` with `localizedTitle` (`MPRemoteCommand.h:83`), and whether iOS 26 shows it is unknown.
- The code enables seven commands (`NowPlayingService.swift:755-785`), with `preferredIntervals` of 30 and 15 (`:772, :776`). But `skipForward()` moves by `playbackSkipForwardUnit` (`ReaderViewModel+Navigation.swift:134-140`), which may be a sentence, a heading, or a bookmark (`SettingsViewModel.swift:38-51`). So the button says one thing and does another. INFERRED.

### VoiceOver and the lock screen

- I found no document or report on how VoiceOver reads these controls. It can't be known until a first run. The app controls the metadata (title, artist, album, chapter). It doesn't control the buttons' labels, apart from what the system derives from `preferredIntervals`. INFERRED.
- Magic Tap: `AccessibilityActionKind.magicTap` exists (`SwiftUI.swiftinterface:24754`). DOCUMENTED. With no handler the system plays or pauses the active media app, and iOS 26 lets the user turn that off in Settings, Accessibility, VoiceOver, Commands, Magic Tap. REPORTED (AppleVis, search summaries). Add `.accessibilityAction(.magicTap)` on the reader's and library's roots, calling `togglePlayPause`.
- `prefersAssistiveTechnologySettings` "will take precedence over any properties you are explicitly setting" (WWDC20 10022). DOCUMENTED. The code sets it false (`SpeechService.swift:1151`, `AudioEngineService.swift:1182`). Keep that.
- Announcements while backgrounded: `SleepTimerService` milestones (`SleepTimerService.swift:1055-1069`) and book-end wording go through VoiceOver. Nothing says VoiceOver speaks an announcement from a background app. Assume it's lost. Anything the listener must hear on a locked phone should go through the app's own audio. INFERRED.

### What `NowPlayingService` does, and what iOS needs

- It is one coordinator with readers as owners, seven commands registered once, handlers that acknowledge at once and defer to the main queue on any thread (`NowPlayingService.swift:798-832`, which suits iOS as it stands), a suppress window after a Bluetooth loss, and title, artist, media type, rate, and `playbackState`.
- `NowPlayingService+iOS.swift` holds two typealiases. The listeners are `#if os(macOS)` (`NowPlayingService.swift:1347-1410`). `armSuppressAndPauseIfPlaying` and `invalidateRegisteredAudioBackends` are `private` (`:1536, :1561`), so a separate file can't call them: the route handler needs an `#if os(iOS)` block in the shared file. `handleDefaultOutputChange` can't be reused, since `previousDeviceWasBluetooth` is always false on iOS.
- iOS needs:
  - a route handler: `.oldDeviceUnavailable` invalidates backends and arms and pauses; `.newDeviceAvailable` invalidates only; `.override` does nothing;
  - an interruption handler, as in section 1;
  - elapsed, duration, and chapter in `NowPlayingItem`;
  - truthful `preferredIntervals` from the skip unit;
  - targets at launch, with a path that opens the last book when no reader exists;
  - session deactivation in `releaseMediaControls`.
- The Mac's route-change rewind is `pauseForAudioRouteChange` plus `applyRewindOnResume` (`ReaderViewModel+Playback.swift:324-327, 251, 3510`), reading `lastPlaybackStopped`. iOS needs only the route handler to reach `onAudioRouteChangePause` (`ReaderViewModel.swift:1057`), and the rewind comes at the next Play. INFERRED.
- The suppress window exists for a Mac daemon's spurious toggle, and whether iOS sends one is unknown. On iOS a Play within the window is consumed (`NowPlayingService.swift:14-15`), which could eat the play from reinserting AirPods quickly. Log it at the first run. INFERRED.
- An `AVPlayer` that paused itself: `AudioPlaybackService` keeps `isPlaying` true, since its progress check judges only a rate above zero after the start (`AudioPlaybackService.swift:2202-2218`). The reader shows Playing until the handlers pause it. INFERRED.

## 4. The life cycle

### Phases and order

- `.active`: "in the foreground and interactive". `.inactive`: "in the foreground but should pause its work". `.background`: "isn't currently visible". At App level the phase aggregates scenes, and "When an app enters the `background` phase, expect the app to terminate soon after." Source: https://developer.apple.com/documentation/swiftui/scenephase. DOCUMENTED.
- "Do as little as possible... do any cleanup work immediately upon entering this state." Source: https://developer.apple.com/documentation/swiftui/scenephase/background. DOCUMENTED.
- Order on leaving: `willResignActive`, `didEnterBackground`, a snapshot, then perhaps suspension. Source: https://developer.apple.com/documentation/uikit/about-the-background-execution-sequence. DOCUMENTED. The order of `scenePhase` relative to the UIKit notifications isn't stated.
- `.inactive` also comes for Control Center, a notification pull, and a call banner, so it isn't leaving. INFERRED. `PlatformApplication.didResignActiveNotification` is `willResignActive` (`PlatformApplication.swift:63`), and nothing shared listens to it today.

### Time allowed

- `applicationDidEnterBackground` "has five seconds to perform any tasks and return." Source: https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time. DOCUMENTED.
- `beginBackgroundTask`: "On current systems you can expect about 30 seconds", and "The system does not guarantee any background task execution time." Expiry handlers run on the main thread, must finish "in less than a second or so", and a task left unended gets the app killed with `0x8badf00d`. Source: Quinn, thread 85066. DOCUMENTED by DTS.
- "Call this method as early as possible before starting your task, preferably before your app actually enters the background. The method requests the task assertion for your app asynchronously." Source: https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(withname:expirationhandler:). DOCUMENTED.
- Safe at background: "Save user data to disk and close any open files", discard what can be reloaded, hold no shared resources. Source: https://developer.apple.com/documentation/uikit/preparing-your-ui-to-run-in-the-background. DOCUMENTED.
- A file lock held while suspended gets the app killed (https://developer.apple.com/documentation/metrickit/mxbackgroundexitdata/cumulativesuspendedwithlockedfileexitcount). DOCUMENTED. TextMouth takes no `flock` or `fcntl` lock (grep finds none).

### Termination with no notice

- `applicationWillTerminate` "is generally not called when the user quits the app", though it "may be called in situations where the app is running in the background (not suspended)". Source: https://developer.apple.com/documentation/uikit/uiapplicationdelegate/applicationwillterminate(_:). DOCUMENTED. A suspended app is simply reclaimed. REPORTED, from older Apple guides quoted elsewhere.
- A kill can come while audio plays: `vm-pageshortage` "needed to free background process memory for the current foreground app", and `per-process-limit` applies to all. Source: https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports. DOCUMENTED. No document says playing audio prevents jetsam, so don't assume it.
- For TextMouth: `flushPendingWrites` runs only on quit paths (`UnsavedChangesTermination.swift:187`, `AppDelegate.swift:195-234`, `PlaybackMemoryGuard.swift:449`). Debounces wait 0.5 seconds (`LibraryPersistenceService.swift:192, 961`), checkpoints come every 30 seconds (`ReaderViewModel.swift:132`), and `close()` (`ReaderViewModel.swift:2239`) never runs on a kill.
- The design survives a kill well: a checkpoint reaches `bookInfo.json` at once, and `reading-checkpoints.json` recovers it at launch (`LibraryViewModel+Migration.swift:83`). So a kill loses at most 30 seconds of place, once a background flush is added.

### State restoration

- `SceneStorage`: "The system makes no guarantees as to when and how often the data will be persisted", and "If the Scene is explicitly destroyed (e.g. the switcher snapshot is destroyed on iPadOS...), the data is also destroyed." Source: https://developer.apple.com/documentation/swiftui/scenestorage. DOCUMENTED.
- So `SceneStorage` and a saved `NavigationPath` are conveniences at most. For "I come back the next day": write the open book's ID to preferences when a reader opens, clear it when the listener closes the book, and at launch reopen that reader paused at its place, with VoiceOver's focus on Play. INFERRED.
- Launch watchdog: a first frame missed within the allowance is a `scene-create` kill, with an example of "19.97 seconds". Source: https://developer.apple.com/documentation/xcode/addressing-watchdog-terminations. DOCUMENTED. `LibraryViewModel.init` calls `startLibrary` and `loadLibraryIndex` with its repairs (`LibraryViewModel.swift:405-434`), so measure this on the phone.

### Tasks, timers, and the sleep timer

- Suspension "prevents the process from running any code" (thread 685525). DOCUMENTED by DTS. `Task`, `Timer`, and `DispatchSource` all wait. While audio keeps the app running they fire as usual. REPORTED. A paused app with no audio gets suspended, so a `Task`-based timer doesn't fire. INFERRED.
- `Timer`: "If the firing time is delayed so far that it passes one or more of the scheduled firing times, the timer is fired only once for that time period." Source: https://developer.apple.com/documentation/foundation/timer. DOCUMENTED.
- `ContinuousClock` "does not stop incrementing while the system is asleep"; `SuspendingClock` "stops incrementing while the system is asleep". Source: https://developer.apple.com/documentation/swift/continuousclock. DOCUMENTED.
- `SleepTimerService` counts ticks: `remainingSeconds -= 1` on a repeating one-second `Timer` (`SleepTimerService.swift:936-955`). A delayed run loop loses seconds, so the book plays long.
- How to build it correctly across suspension, under `#if os(iOS)`, all INFERRED:
  - Keep a deadline as a `ContinuousClock.Instant`, set at start and at each resume of the countdown.
  - Each tick computes `remainingSeconds` from the deadline. Ticks only update the display and fire milestones.
  - On any return to running (`didBecomeActive`, a remote command), check the deadline first. If it passed, expire at once and say so.
  - Keep the rule that the countdown halts when playback pauses (`SleepTimerService.swift:796-820`), so nothing has to fire during a suspension, which only comes when nothing plays.
  - Wrap the expiry in a background task: pause, save, flush, deactivate.

### Silent gaps

- These run with no audio, so they can be frozen: a chapter pause (`ReaderViewModel+Playback.swift:2303, 2333`); the next book's 0.5 seconds and load (`:2873, :2945`, `ReaderViewModel+BookMoves.swift:148`); Where Am I?'s end sound (`ReaderViewModel+WhereAmI.swift:611`); a chapter's speech being prepared off the main thread (`isWaitingForChapterSpeech`).
- The fix is one iOS helper: begin a named background task as audio ends, and end it when audio starts or the work gives up. That is Apple's advice: "Use a background task instead of streaming silence." DOCUMENTED. It lasts about 30 seconds. For a longer manifest pause, play silence through the engine. INFERRED.
- A new `AVPlayer` in the background: "calling -play sets the player rate to 1, but the system resets it automatically to 0", the root cause being a player recreated after an item ended, and the fix one `AVQueuePlayer` kept alive (https://github.com/SRGSSR/srgletterbox-apple/issues/211). REPORTED. `AudioPlaybackService.load` makes a new `AVQueuePlayer` per file (`AudioPlaybackService.swift:826`) unless playback rolled on gaplessly, so chapter pauses and any unqueued file are exposed. Test it at the first run.

## 5. Memory

### Limits

- No published number. "per-process-limit: The process crossed the resident memory limit imposed by the system on all apps", and extensions "have a much lower per-process memory limit" (jetsam article). DOCUMENTED.
- Numbers seen, all REPORTED and in disagreement: "ActiveHard 2098 MB" on a 4 GB iPhone 12 (thread 688973); about 4,000 MB on an iPhone 16 Pro and about 900 MB on an iPhone SE (a blog); 4.8 to 5.2 GB on 8 GB iPhones (a guide). Measure on the phone.
- `os_proc_available_memory()`: bytes left before the limit. "Memory limits can change during the app life cycle." It returns 0 if not an app or over the limit. Source: `usr/include/os/proc.h:46-87`. DOCUMENTED.
- Warnings come "if the system runs low on free memory and is unable to reclaim memory by terminating suspended apps". Free what can be reloaded, and "consider writing any unsaved data to disk". Source: https://developer.apple.com/documentation/uikit/responding-to-memory-warnings. DOCUMENTED.
- `com.apple.developer.kernel.increased-memory-limit` is "only available on some device models" (https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit). DOCUMENTED. Apple's table doesn't list it, and lists the neighbouring "Increased Debugging Memory Limit" and "Extended Virtual Addressing" as paid only, so assume no for a free team. INFERRED. It isn't needed.
- Background: "ActiveHard" suggests a separate inactive limit, and no document gives one. INFERRED. Check `os_proc_available_memory` while locked.

### What TextMouth uses

- Rendered speech: 16-bit mono at 22,050 Hz is 2.65 MB a minute. The largest render, 100,000 units (`SpeechService.swift:328`), is about 37 minutes, about 98 MB, and with the look-ahead about 196 MB. A 48 kHz voice, if one exists, would take about 214 MB each. INFERRED, by arithmetic from `AudioEngineService.swift:197-198`.
- A 50 MB `content.md`: `Data(contentsOf:)` (`MarkdownCacheService.swift:600`, `BookContentAnalysisService.swift:207`) plus its String is at least 100 MB. The guard's comment says "a 20 MB one-chapter book some hundreds while it opens" (`PlaybackMemoryGuard.swift:51-52`), so about 500 MB to 1 GB at peak. INFERRED. It fits a phone with a 2 GB limit in the foreground, but check first.
- A 2 GB audiobook: MD5 streams in 1 MiB pieces (`FileImportService.swift:2478-2479`) and `AVPlayer` reads from the file, so RAM doesn't grow. INFERRED. The costs are disk and time. The exception is DAISY audio, read whole up to 256 MB a file (`ArchiveEntryReader.swift:11-15`, "safe... on a Mac with 8 GB").

### The memory guard

- It reads `phys_footprint` every 5 or 30 seconds, stops playback at 3 GB, and saves and quits at 6 GB (`PlaybackMemoryGuard.swift:54, 60`), written after the October 14 runaway inside Apple's Vorbis decoder.
- On iOS: `task_info` works, but jetsam acts first on most iPhones, so the ceilings never help. INFERRED. `quit` is a no-op (`:456-463`), and `quitFromAnyThread` calls `_exit(0)` 15 seconds later (`:470-474, 599-602`). "Do not call the `exit` function." Source: QA1561, https://developer.apple.com/library/archive/qa/qa1561/_index.html. DOCUMENTED, though unlikely to be reached.
- What iOS should do instead, under `#if os(iOS)`, with thresholds only suggested (INFERRED):
  - Use `os_proc_available_memory()`. Under about 150 MB while playing, stop and say why. Never quit.
  - Before a look-ahead render, require about 300 MB free, and skip it otherwise.
  - On a memory warning, drop the look-ahead audio and `ReadingTextCache`, and save positions.
  - Keep the Vorbis rule: `ImportAudioConverter.isNeverDecodedInApp` (`ImportAudioConverter.swift:207-210`) works as it stands.
- Other assumptions of 8 GB: comments and the limits above. `ArchiveBudget`'s 8 GB is disk, not memory.

## 6. The sandbox and files

### What the data directory resolves to today

- `TextMouthRuntime.detect` gives `realHomeDirectory` (`TextMouthRuntime.swift:123`), which reads `getpwuid(getuid())` first (`:144-149`), on purpose, so that "neither an app sandbox nor a changed HOME variable can redirect it". On an iPhone that entry is expected to be the system user's home, `/var/mobile`, not the container. INFERRED; my search found no source confirming it for iOS. The sandbox will refuse writes there, and `ensureDirectoryStructure` is called with `try?` (`LibraryViewModel.swift:424`), so it may fail quietly.
- Even with `NSHomeDirectory()`, `defaultRoot` is `.TextMouth` at the container root (`TextMouthPaths.swift:15-17`). The documented places are `Documents/`, `Library/`, and `tmp/` (https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html). DOCUMENTED. Whether the root is writable isn't stated, so don't rely on it.
- `MachineLocalPaths` builds from the same home (`CloudStorageContract.swift:577-580, 585-593, 650-653`). With a right home these become the right folders under `Library/`.
- "Applications should always call the system to get the locations of the standard directories." Source: TN2406, https://developer.apple.com/library/archive/technotes/tn2406/_index.html. DOCUMENTED.

### How to change it

- In `TextMouthRuntime.realHomeDirectory`, under `#if os(iOS)`: `URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)`.
- In `TextMouthPaths.defaultRoot(in:)`, under `#if os(iOS)`: `home/Library/Application Support/.TextMouth`.
- Don't name it `Library/Application Support/TextMouth`. That is exactly `legacyApplicationSupportDirectory` (`TextMouthPaths.swift:593-596`), which the legacy migration reads at launch.
- `createDirectory(withIntermediateDirectories: true)` (`TextMouthPaths.swift:399`) already makes Application Support, which may not exist in a new container. INFERRED.

### Where the library lives: Application Support, not Documents

- Documents: "Only store files you may wish to expose to the user", backed up. Library: "files you don't want exposed to the user", backed up except Caches. Source: file system guide. DOCUMENTED.
- With both `LSSupportsOpeningDocumentsInPlace` and `UIFileSharingEnabled`, documents "appear in the Files app, and in a document browser", and "other processes can modify the document at any time" (Apple's older reference, quoted at https://discussions.apple.com/thread/8554020). DOCUMENTED, second hand. The folder also needs "at least one file" (Apple DTS, thread 765329).
- If the library were in Documents, `library.json`, `bookInfo.json`, `.tmb` packages, and logs would all show in Files, where they can be deleted, renamed, or moved with VoiceOver by accident, under an app that assumes it owns them. So keep it hidden. Use Documents as a visible drop folder, for books copied in from Finder or Files. INFERRED.
- Backups: everything outside `tmp` and `Caches` is backed up unless excluded, and `isExcludedFromBackup` must be set again after saving ("certain file operations can reset resource values"). Apple's guidance cuts both ways: exclude re-downloadable large files, but "if your app allows the user to import arbitrary files such as PDFs, ebooks, and digital comics, don't exclude those files". Source: https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup. DOCUMENTED.
- A library of many gigabytes would fill a small iCloud plan and could make the whole phone's backup fail. INFERRED. Proposal for the user: back up records and text, and exclude audiobook audio by default, as a setting. A restored phone then has books with missing audio (TN2285: do-not-backup files "will not be installed"), and the library must say so per book. `ImportScratchSpace.prepareFolder` already excludes scratch folders (`ImportScratchSpace.swift:104-107`).
- Container paths: "the absolute path to the app's container... and thus all files inside it, will change. For this reason, you must only save paths to files relative to your application container", and `Documents/` and `Library/` (except Caches) "are the only directories that are guaranteed to be preserved across updates". Source: TN2285, https://developer.apple.com/library/ios/technotes/tn2285/_index.html. DOCUMENTED.
- `Book.filePath` is an absolute string (`Book.swift:240`), and a free team reinstalls at least every 7 days. `repairStaleFilePaths` re-finds a book by folder and package name when its file is absent (`LibraryViewModel+Migration.swift:283-337`), so it should heal at launch. But feed items are shelved first and skip that repair (`:73, :89`). INFERRED. Check both at the first run.
- Offload: "free up storage used by the app, but keep its documents and data". REPORTED, Apple's wording quoted by press. A development-signed app can't be restored from the App Store, so it would need a reinstall from Xcode. INFERRED.
- Low disk: the system purges `tmp` and `Library/Caches` (backup article). DOCUMENTED. `ReadingTextCache` lives there and rebuilds.
- File protection: the default is "Complete until first user authentication", so reads and writes work on a locked phone after the first unlock. Source: https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files. DOCUMENTED. Don't add a stricter class, or books can't be read during locked playback.
- Trash: `FileImportService.moveToTrash` calls `trashItem` (`FileImportService.swift:2368`). The API exists (`NSFileManager.h:215`), but where it puts things in a sandbox isn't stated, and `3328` not-supported errors are reported for the trash directory. REPORTED. Use plain removal on iOS, and word the removal alert to match. INFERRED.

## 7. Importing

### `fileImporter`

- `fileImporter(isPresented:allowedContentTypes:allowsMultipleSelection:onCompletion:)`, with an `onCancellation:` form (`SwiftUI.swiftinterface:7400-7409`). "This dialog provides security-scoped URLs." Source: https://developer.apple.com/documentation/swiftui/view/fileimporter(ispresented:allowedcontenttypes:allowsmultipleselection:oncompletion:). DOCUMENTED. The existing call is `ContentView.swift:167-186`.
- Folders: add `.folder`, since `supportedTypes` (`FileImportService.swift:2843`) has none. When you enumerate a picked folder, "the resulting URLs are also security-scoped." Source: https://developer.apple.com/documentation/uikit/providing-access-to-directories. DOCUMENTED.
- Scope: "You must call `startAccessingSecurityScopedResource` before accessing the URL", and "The system lets your app access only a limited number of security-scoped URLs at one time." Source: https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/DocumentPickerProgrammingGuide/AccessingDocuments/AccessingDocuments.html, 2015. DOCUMENTED.
- Scope at the folder is enough: "Security scope applies to directories as well." Failures (`sandbox_extension_consume error=[12]`) came after about 340 per-file cycles. On iOS it's "very difficult... to get a URL out of ANY API that doesn't have a security scope attached", and implicit scope "is actually managed at the process level". Source: Apple DTS, thread 793561, July 2025. DOCUMENTED by DTS.
- Which thread: no restriction is stated. TextMouth starts the scope later, on the import queue (`LibraryViewModel+Import.swift:293, 569, 660`). Keep the URL object rather than rebuilding it from `.path`, and hold the scope across the whole copy (https://www.theswift.dev/posts/make-file-imports-survive-security-scoped-url-access/). REPORTED.
- File coordination: "Your app must perform all file read and write operations using file coordination" (picker guide). DOCUMENTED. TextMouth has no `NSFileCoordinator` at all (grep finds none). It reads and copies plainly (`FileImportService.swift:1209, 2478-2506`), and `importSources(for:)` reads a folder on the main thread before any scope starts (`LibraryViewModel+Import.swift:158, 173`, then `DAISYParser+PackageInventory.swift:45`).
- A file in iCloud Drive not yet downloaded: no Apple document says whether the picker waits for it.
  - "In iOS, apps must ask the system (either explicitly or implicitly) to download the file. You implicitly download a file by trying to access that file by using methods in the NSFileCoordinator class", and "the coordinated read operation blocks until the file finishes downloading (or fails to download)." Source: https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html. DOCUMENTED.
  - A not-downloaded file is "missing from the tree (iCloud), or may be listed as a note that can't be read" (https://github.com/BrainFrameTech/brainframe/issues/219); plain reads failed in thread 748135. REPORTED.
  - A coordinated read "will automatically begin a background task when granted" (https://developer.apple.com/documentation/foundation/nsfilecoordinator). DOCUMENTED.
  - So never read a picked URL plainly. Copy under coordination, on the import queue, with progress. INFERRED.
- `UIDocumentPickerViewController` with `asCopy: true`: repeated taps on a slow source gave a truncated copy ("a 788 MB source archive may be copied as a 56 MB file"). Apple DTS: "This is definitely a bug", "set 'asCopy' to 'NO' and do the copy yourself", which "will let you provide better progress data". Source: thread 765101. DOCUMENTED by DTS.
- When the URL expires: a copied file "remains available until the app closes"; for open-mode URLs, "Do not save any URLs accessed through open or move operations" (picker guide). DOCUMENTED. `SerialImportQueue` holds URLs in memory only, so a kill loses them. INFERRED.

### Open In and the share sheet

- `CFBundleDocumentTypes` with `LSItemContentTypes`, `LSHandlerRank`, `CFBundleTypeName`, and `CFBundleTypeRole`: "This allows other apps, through the iOS document interaction technology, to offer the user the option to hand off those files to your app." Source: https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/DocumentInteraction_TopicsForIOS/Articles/RegisteringtheFileTypesYourAppSupports.html. DOCUMENTED. Use `Alternate` for others' formats and `Owner` for `.tmb`, as the Mac does.
- "Define an imported type if your app uses a type that another app defines, or if it's a proprietary file format the system doesn't declare." Don't redeclare system types. Source: https://developer.apple.com/documentation/uniformtypeidentifiers/defining-file-and-data-types-for-your-app. DOCUMENTED.
- Does the app appear with only document types? For files, by the reports, yes: "It works fine when a file of the given filetypes is opened in the Files App or as Attachment from Mail. If I click the share icon, my app appears in the Share Sheet" (thread 724707, 2023); likewise thread 743571 (2023). REPORTED. Not for Photos, and in thread 772501 (2025) an Apple Frameworks Engineer says "You will need a share extension" for photos, while that poster's config didn't appear in Safari or Mail either. REPORTED, and in partial conflict. No source covers Messages. Check them all at the first run.
- A share extension for the first version: not needed. INFERRED. Its cost: a target with its own App ID, counted against a free team's 10 App IDs in 7 days (and maybe its 3 apps, unconfirmed); an app group, which Apple's table allows on a free team; "much lower" memory; no way to simply open the app, so a shared folder read at the next launch. It is poor for a 2 GB audiobook.
- What URL arrives: `Documents/Inbox` holds "files your app was asked to open by outside entities, such as email attachments from Mail" (file system guide). DOCUMENTED. With `LSSupportsOpeningDocumentsInPlace` YES, a file in Files arrives where it lies, security-scoped; with NO it's copied to the Inbox. REPORTED. "When the value of this property is false, you must copy the document to maintain access to it" (https://developer.apple.com/documentation/uikit/uiapplication/openurloptionskey/openinplace, deprecated in iOS 26 for `UISceneOpenURLOptions.openInPlace`, `UIApplication.h:633`, `UISceneOptions.h:65`). DOCUMENTED.
- SwiftUI's `onOpenURL` gives only the URL (`SwiftUI.swiftinterface:2638`). So treat every URL alike: scope, coordinated copy, import, and remove it if it's inside `Documents/Inbox`.
- `Documents/Inbox`: "Your app can read and delete files but cannot create new files or write to existing ones." Backed up. Source: file system guide. DOCUMENTED. The "delete original?" question in `completeSingleImportedBook` must not ask about an Inbox copy. Sweep the Inbox at launch and each return to the foreground. INFERRED.
- Cold launch: for a scene app the URL comes "through `connectionOptions.urlContexts`" and `application(_:open:options:)` is never called (thread 743571). REPORTED. `onOpenURL` receives URLs "in a particular scene" (https://developer.apple.com/documentation/swiftui/view/onopenurl(perform:)). DOCUMENTED. Nothing states its cold-launch timing, so put it on the root view and test. Hold the URLs until `hasStartedLibrary`, as the Mac routes through `LibraryWindowRouter` (`AppDelegate.swift:244-245`). INFERRED.
- A file arriving during another import: `SerialImportQueue` already queues them (`LibraryViewModel+Import.swift:93-109`). INFERRED that it holds on iOS.
- Types lost without declarations: `UTType("com.textmouth.opf-package")`, `daisy-book`, and `book-package` return nil (`FileImportService.swift:2911-2921`). `UTType(importedAs:)` returns a type with no extension bound (`:2874-2886`), so MOBI, KFX, BRF, BRL, PEF, and SSML could be greyed out in the picker. INFERRED. Copy the declarations from `TextMouth/Resources/Info.plist`, which iOS excludes today (`project.yml:280`).

### A long import going to the background

- `beginBackgroundTask`: about 30 seconds, no guarantee (section 4). When time runs out, end the task from the expiry handler. Don't try to cancel a `copyItem`, and don't block.
- A suspended process is frozen and resumes if not killed. `ImportStaging` publishes by one rename, so a kill leaves a hidden `.import-…` package and no half-book. `removeAbandoned` clears it (`ImportStaging.swift:13-22, 101-123`), `removeLeftoverArchiveExtractions` clears extractions at launch (`LibraryViewModel.swift:427`), and the source is never changed. This is a good property to keep. INFERRED.
- `BGContinuedProcessingTask` (iOS 26):
  - It begins "in response to someone's action", in the foreground, and the system shows "the title and subtitle" in a Live Activity, where a person can monitor and cancel. Source: https://developer.apple.com/documentation/backgroundtasks/performing-long-running-tasks-on-ios-and-ipados. DOCUMENTED.
  - It "must report progress", and "Tasks that appear stalled may be forcibly expired" (`BGTask.h:123-126`). DOCUMENTED.
  - Registration is exempt from the launch deadline (`BGTaskScheduler.h:80-81`): register when the action happens (https://developer.apple.com/videos/play/wwdc2025/227/). The identifier comes from `BGTaskSchedulerPermittedIdentifiers`, prefixed with the bundle ID, in the wildcard form `<MainBundle>.<SemanticContext>.*` (`BGTaskRequest.h:161-164`). Strategy `.queue` by default, or `.fail` (`:106-114`). DOCUMENTED.
  - "The system cancels any running tasks if a person closes the app in the app switcher, but the app doesn't receive an indication of cancellation in that case." Not on the simulator (`BGTaskScheduler.h:30`). DOCUMENTED.
  - Thread 801126 reports a handler no longer called on the iOS 26 release on one device. REPORTED. No entitlement is needed unless the GPU is asked for (`BGTaskRequest.h:128`), so a free team should manage. INFERRED. Whether VoiceOver reads the Live Activity is unknown.
- For the first build: wrap each import in `beginBackgroundTask`, keep the existing overlay, and add `BGContinuedProcessingTask` once a run shows the basics hold. While a book plays, the app keeps running, so imports go on. INFERRED.
- What to tell the user under VoiceOver: before leaving, nothing can be said, and a background announcement may be lost. On return to `.active`, say what happened: "Importing Dune went on while TextMouth was away", or "was stopped: TextMouth was closed. Import it again." A kill loses the queue, so persist the names to a small file and report at launch. INFERRED.

### What hits `IOSUnavailable` or a stand-in

- Audio tracks asked about with `afinfo`: every `.mpeg4` and `.unknown` file (`AudioContentSniffer.swift:109-118`) reaches `AudioFileInfo.read`, which calls `WatchedProcess.runCapturingOutput` (`AudioFileInfo.swift:292`). On iOS that throws (`WatchedProcess+iOS.swift:106-116`), though the doc comment says "Throws: CancellationError only" (`AudioFileInfo.swift:285`). It propagates to `convertImportedAudio` (`FileImportService+AudioConversion.swift:51, 60`). So every M4B, M4A, MP4, and MOV import fails at "Converting its audio".
- The fix, under `#if os(iOS)`: read the 4-character code from the file's own `stsd` box, as `OggHeaderReader` reads Ogg. AAC, ALAC, or MP3 plays as it is (`playsAsIs`, `ImportAudioConverter.swift:241-252`), and anything else is refused by name. INFERRED.
- Converted formats: Ogg, Opus, AC-3, AMR, MP2, CAF, and more (`ImportAudioConverter.swift:41-58`) run `/usr/bin/afconvert`, so they're refused: "Converting this kind of file is not available on iPhone yet." The user's Ogg radio dramas won't import on iOS yet. Also `LibraryViewModel+OggConversion.swift:225`.
- Word 6 and 95: `TextutilConverter.swift:301`, refused as `platforms.md` says.
- Braille books: `BrailleTranslator.Tool.helper` has no executable (`BrailleTranslator.swift:126-127`) and throws "the helper is missing" (`:695-697`). So BRF, BRL, and PEF fail with wording that means nothing to the listener. Give them a proper refusal.
- Others from `platforms.md`: recording, the audio editor, the file and folder panels (empty branches), `EPUBParser.updateOPFMetadata`, Word 97-2003 export.

## 8. Info.plist and project keys

### How the keys get in

- "Each information property list key corresponds with a build setting that's named for the key with a `INFOPLIST_KEY_` prefix", but "Xcode doesn't use values from user-defined build settings... even if you create settings with the `INFOPLIST_KEY_` prefix." Source: https://developer.apple.com/documentation/bundleresources/managing-your-app-s-information-property-list. DOCUMENTED.
- The settings Xcode knows are in `SwiftBuild.framework/.../SWBCore.framework/Versions/A/Resources/CoreBuildSystem.xcspec:3729-4615`. DOCUMENTED, by the tool itself. It has `CFBundleDisplayName`, `LSSupportsOpeningDocumentsInPlace` (line 4402), `UISupportsDocumentBrowser`, `UILaunchScreen_Generation`, `UIApplicationSceneManifest_Generation`, `UIRequiresFullScreen`, and orientations. It doesn't have `UIBackgroundModes`, `UIFileSharingEnabled`, `CFBundleDocumentTypes`, `UTImportedTypeDeclarations`, `UTExportedTypeDeclarations`, `NSAppTransportSecurity`, or `BGTaskSchedulerPermittedIdentifiers`. So `INFOPLIST_KEY_UIBackgroundModes` would be silently ignored.
- Merging: "If the value is `Yes`, then Xcode merges the content of the property list file with the values from the Info.plist Values build settings." Source: same article. DOCUMENTED. Which side wins on a shared key isn't stated, so keep each key on one side.
- "Don't add the property list file to your target." Source: same. DOCUMENTED. `TextMouthiOS.sources` is `path: TextMouth` less two folders (`project.yml:276-280`), so keep the plist out of `TextMouth/`, or it's copied in as a resource and draws a SwiftPM unhandled-file warning in `typecheck.py`. Use a new top-level folder, `iOSApp/`. INFERRED.

### `project.yml` change

```yaml
TextMouthiOS:
  sources:
    - path: TextMouth
      excludes: ["Platform/macOS/**", "Resources/**"]
    - path: iOSApp/Assets.xcassets
  settings:
    base:
      GENERATE_INFOPLIST_FILE: true
      INFOPLIST_FILE: iOSApp/Info.plist
      PRODUCT_BUNDLE_IDENTIFIER: com.textmouth.TextMouth.iOS
      INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace: YES
      INFOPLIST_KEY_CFBundleDisplayName: TextMouth
      INFOPLIST_KEY_UILaunchScreen_Generation: true
      INFOPLIST_KEY_UIApplicationSceneManifest_Generation: true
      ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
      CODE_SIGN_STYLE: Automatic
```

- XcodeGen's `info:` with `properties` also works, writing the file and setting `INFOPLIST_FILE` unless already set (https://github.com/yonaskolb/XcodeGen/blob/master/Docs/ProjectSpec.md). DOCUMENTED. A hand-kept file is simpler to review. xcodegen here is 2.45.3.
- `DEVELOPMENT_TEAM`: the project is regenerated, so a choice made in Xcode's window is lost. Pass it on the command line or from an untracked `.xcconfig`. INFERRED.

### `iOSApp/Info.plist` for the first version

```xml
<key>UIBackgroundModes</key>
<array><string>audio</string></array>
<key>UIFileSharingEnabled</key>
<true/>
<key>CFBundleDocumentTypes</key>
<array><!-- from TextMouth/Resources/Info.plist, less the types iOS refuses --></array>
<key>UTImportedTypeDeclarations</key>
<array><!-- the Mac's ten --></array>
<key>UTExportedTypeDeclarations</key>
<array><!-- com.textmouth.book-package --></array>
<key>NSAppTransportSecurity</key>
<dict><key>NSAllowsArbitraryLoads</key><true/></dict>
```

- `CFBundleDocumentTypes`: of the Mac's 33 entries, leave out "Ogg Audio", "Audio Converted at Import", "ALAC Audio" (its entry names CAF, `com.apple.coreaudio-format`, which iOS refuses), and the three braille entries, so that no app offers TextMouth a file it will refuse. Add them back as they come to work. INFERRED.
- `NSAppTransportSecurity`: the Mac has it for HTTP feeds, and it's only needed if feeds are in the first version.
- `BGTaskSchedulerPermittedIdentifiers`: `["com.textmouth.TextMouth.iOS.import.*"]`, once `BGContinuedProcessingTask` comes.
- Not needed yet: `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`.

### Bundle identifier and icon

- Today both apps share `com.textmouth.TextMouth` (`project.yml:158, 287`). Make iOS distinct: a free team registers it and has 10 App IDs at a time, so choose once; the `BGTaskScheduler` identifiers must begin with it; and if the iOS app ever runs on the Mac as "Designed for iPad", a shared identifier collides with the Mac app's container and preferences. INFERRED.
- Icon: `Resources/**` is excluded (`project.yml:280`), and the Mac's `AppIcon` holds only Mac sizes. A new `iOSApp/Assets.xcassets` with one 1024-pixel universal icon is enough, and a development install runs without one. INFERRED. Low priority.

### The free team

- From Apple's table, https://developer.apple.com/help/account/reference/supported-capabilities-ios, read from the page's markup, column "Apple Developer". DOCUMENTED.
  - Allowed: App groups, Background modes, Data protection, Keychain sharing, HealthKit, HomeKit, Inter-App Audio, Maps, Wireless Accessory Configuration.
  - Not allowed: iCloud (all three), Push notifications, Siri, Associated domains, Extended Virtual Addressing, Increased Debugging Memory Limit, Spatial Audio Profile, Time Sensitive Notifications, Group Activities, Sustained Execution.
  - A third-party page disagrees on App Groups (https://zudo-tauri-wisdom.takazudomodular.com/docs/mobile/ios-signing-free-team/). Apple's table wins.
- Limits: "Up to 10 App IDs, expiring after 7 days"; up to 3 devices; up to 3 apps per device; profiles expire after 7 days (https://developer.apple.com/support/compare-memberships/, as my reader captured it). DOCUMENTED.
- `UIBackgroundModes` is a plist key, so nothing refuses `audio`. INFERRED. Every 7 days, rebuild and install over the top, and the data stays. Never delete the app. REPORTED and INFERRED.

### `Scripts/ios/typecheck.py`

- It writes a `Package.swift` around the sources and runs `swift build --sdk ... --triple arm64-apple-ios26.0` (`typecheck.py:160-212, 322-324`). It builds a plain executable: no bundle, no Info.plist, no entitlements, no asset catalog, no signing, no resources. So it sees none of this section. A wrong key or a missing background mode passes it.
- Suggestion: a small script under `make typecheck-ios` that loads `iOSApp/Info.plist` with `plistlib` and asserts the keys above and the document types against `FileImportService`'s list. INFERRED.

## 9. Other things that surprise a Mac developer

- `UIApplication.shared` before a scene: don't touch it in `App.init`; use `@UIApplicationDelegateAdaptor` for launch work. INFERRED. Order: `willFinishLaunching`, `didFinishLaunching`, then the scene (https://developer.apple.com/documentation/uikit/about-the-app-launch-sequence). DOCUMENTED.
- `UIDevice.current.name` (`LibrarySessionLease.swift:523`) is "iPhone" on iOS 16 and later without an entitlement (https://developer.apple.com/documentation/uikit/uidevice/name). DOCUMENTED. Harmless. The lease's 60-second file write (`LibrarySessionLease.swift:149, 193`) has no use for a library only this phone holds, so turn it off on iOS. INFERRED.
- `Bundle.main`: `BuildIdentity` reads `TextMouthGitCommit` and others, absent from a generated plist, and says "unknown" (`BuildIdentity.swift:15-20`). `TranscriptCleanupRuleFile.builtInBytes` returns nil (`TranscriptCleanupRuleFile.swift:56`). Both fine. The licences copied into the Mac app aren't in the iOS target; copy them before anything is distributed.
- System sounds: `/System/Library/Sounds` (`SoundEffectService.swift:194`) is a Mac path. `soundFile(named:)` returns nil and `availableSounds()` gives only "None", so Play, Pause, and skip are silent. INFERRED. For a blind listener those sounds are feedback, so ship own short sounds in `iOSApp/`.
- `thermalState`: "At higher thermal states your app should reduce usage of system resources" (https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.property). DOCUMENTED. Skip look-ahead renders at `.serious` and `.critical`. INFERRED.
- Low Power Mode: "Reducing CPU and GPU performance", "Pausing discretionary and background activities" (https://developer.apple.com/documentation/foundation/processinfo/islowpowermodeenabled), and a shorter auto-lock (Energy Guide, `LowPowerMode.html`). DOCUMENTED. Audio and timers aren't mentioned. Renders will be slower. `FeedCenter` already checks it (`FeedCenter.swift:65`).
- `isIdleTimerDisabled`: "Most apps should let the system turn off the screen when the idle timer elapses. This includes audio apps." (https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled). DOCUMENTED. Don't set it.
- Silent switch: `.playback` plays regardless (section 1). DOCUMENTED. Handoff: `NSUserActivity` is absent from the code, so there's nothing to do.
- Lock and `AVPlayer`: playback goes on with the mode and category set. Thread 660673 had `AVPlayer` paused on entering the background on iOS 14. REPORTED.
- `AVPlayer.allowsExternalPlayback` defaults to true (its page). DOCUMENTED. AirPlay works for audiobooks with no code, and speech follows the session's route. INFERRED.
- Audio formats: no Apple page lists file formats for iOS's `AVPlayer`, so ask at runtime with `AVURLAsset.audiovisualMIMETypes()`. TextMouth's plays-as-is set (MP3, AAC, ALAC, WAV, AIFF, FLAC) is expected to hold, FLAC to be checked. Protected M4B won't play. INFERRED.
- `AVAudioFile` and long files: the book path doesn't use them. Speech is buffers, and audiobooks are `AVPlayer`.
- `AVAudioTime` drift: position comes from the player timeline (`AudioEngineService.swift:1592-1600`), not a wall clock, so there's no drift. `stop` "returns the player timeline to sample time 0" (`AVAudioPlayerNode.h:110-111`). DOCUMENTED. After an engine self-stop the offset falls back on `currentWordRange` (`SpeechService.swift:1943-1952`). INFERRED. "A player should not be stopped from within a completion handler" (`AVAudioPlayerNode.h:145-146`), which the feeder's queue hop respects.
- `AVAudioEngine` before a session: `setupEngine` touches `mainMixerNode` in `init` (`AudioEngineService.swift:938-945`), and `play` reconnects nodes outside any exception catch (`:1259-1262`). `_GetHWFormat` and `IsFormatSampleRateAndChannelCountValid` exceptions are reported when the hardware format is invalid, as during a call, mostly for input (threads 73166, 743633). REPORTED. Wrap the iOS connect in `ObjCException.catching`. INFERRED.
- `Network` in the background: there is no general mechanism for running code, and a background `URLSession` is the tool for large HTTP transfers (thread 685525). DOCUMENTED by DTS. `FeedNetwork` uses an ephemeral foreground session (`FeedNetwork.swift:71`), which works only while the app runs. INFERRED. The feeds start on their own at launch (`LibraryViewModel.swift:453`, `FeedCenter.swift:66`), so keep them foreground-only at first. Discretionary work already avoids expensive networks (`FeedNetwork.swift:92-94`). The User-Agent says "Macintosh" (`FeedNetwork.swift:88`).
- CPU and energy while locked: position tracking ticks at 0.1 seconds with word extraction on `.userInteractive` (`SpeechService.swift:2228, 2238`), watchdogs at 0.5 seconds (`:766`), view refreshes at 0.12 seconds (`ReaderViewModel.swift:710`). Slow them when `scenePhase` isn't `.active`, and give timers a tolerance ("at least 10% of the interval", `Timer` page). DOCUMENTED.
- Windows: `openWindow` per book, `WindowAccessor`, and `keyWindow` nil. `WindowCommandRouting` accepts commands with no host window (`LibraryView.swift:14-17`), so a single reader works. The interface team owns the rest.
- `TARGETED_DEVICE_FAMILY: "1,2"` (`project.yml:288`) also builds for iPad, with scenes and multitasking. Use `"1"` until iPad has been considered. INFERRED.
- Newer iOS than the SDK: forum posts mention iOS 27.0.1. If the iPhone runs newer than 26.0, Xcode 26.0.1 may not install to it. INFERRED. Check before the first install.

## 10. Recommendations for this app

### Session configuration

```swift
// iOS only: TextMouth/Platform/iOS/Services/AudioSessionController+iOS.swift
// All session calls run on one serial queue, off the main thread.
let session = AVAudioSession.sharedInstance()
try session.setCategory(.playback, mode: .spokenAudio, policy: .default, options: [])
// No .mixWithOthers, .duckOthers, or .interruptSpokenAudioAndMixWithOthers:
//   each makes the session mixable, which costs Now Playing.
// No .allowBluetoothHFP, .allowBluetoothA2DP, or .allowAirPlay:
//   A2DP is implicit in .playback, and the others do not apply to it.
try session.setActive(true)   // At Play, before any audio starts.
```

- `directSynth.usesApplicationAudioSession` stays true.
- Observers: interruption and media reset on the main queue; route change with `queue: .main`, since it's posted on a secondary thread; `AVAudioEngineConfigurationChange` nonisolated, hopping to main, never releasing the engine in it.

### When to activate and deactivate

- Set the category at launch, which interrupts nothing. Activate at any Play: the button, a remote command, or the next book. Log a failure with its code, and say so if it failed.
- Stay active through chapter changes, gaps, seeks, fades, and foreground pauses.
- Deactivate with `.notifyOthersOnDeactivation`, after stopping audio and after the pause sound, when: entering the background while paused; a sleep timer expires in the background; the book ends with nothing following; Release Media Controls; a book closes. Treat `!act` as a log line (thread 759553).
- After any return from suspension, assume it's inactive.

### Speech path

- Direct at Play, the render behind it, and the engine from the next natural break: the Mac's policy, unchanged. The user's rule holds.
- iOS-only additions: prefer finished rendered audio at Play; a word-progress watchdog recovering at the last reported word, since nothing is heard then; no Personal Voices in rendering; skip or slow look-ahead renders in the background.
- If the first run shows direct speech stalls at the lock, go engine-only with a streaming feeder, which still never switches.

### Remote commands and their mapping

- `playCommand`: `playOrResume()`. `pauseCommand`: `pause()`. `togglePlayPauseCommand`: `togglePlayPause()`.
- `nextTrackCommand` and `previousTrackCommand`: `skipForward()` and `skipBackward()`, as on the Mac, whatever the unit. These are what AirPods double and triple press are reported to send.
- `skipForwardCommand` and `skipBackwardCommand`: enabled only when the unit is seconds, with `preferredIntervals` set to those seconds (`SkipUnit.seconds10` to `seconds60`). Otherwise disabled, so the lock screen doesn't promise a time it won't skip.
- `changePlaybackPositionCommand`: audiobooks only, seeking within the chapter; disabled for speech; optional in the first version.
- Disabled: `seekForwardCommand`, `seekBackwardCommand`, `changePlaybackRateCommand`, `bookmarkCommand`, `stopCommand`.
- Install targets at launch. With no reader, open the last book and play; failing that, answer `.noActionableNowPlayingItem`.
- Metadata: title, author, chapter or heading as album title, media type audio, and rate (1.0 or the speed, or 0 when paused), on each play, pause, seek, chapter, and speed change. Elapsed and duration for audiobooks. For speech, leave time out at first, since any figure would be an estimate.

### What must be saved when

- At every pause, stop, and chapter change: as now, plus a flush when not `.active`.
- At interruption began, a route loss, a sleep timer's expiry, and a memory warning: `savePosition()`, then flush.
- At `scenePhase == .background`: begin a background task, call `UnsavedChangesTerminationGuard.flushPendingWrites()`, end the task. Off the main thread if `library.json` proves slow.
- At `scenePhase == .inactive`: nothing heavy. Every 30 seconds while playing: as now.
- When a reader opens: the book's ID in preferences, for reopening next day. When an import starts and ends: its name in a small file, to report a kill.

### Where the library lives

- `Library/Application Support/.TextMouth`, hidden from Files, with records and text backed up and audiobook audio excluded by a setting (a question for the user). `Documents/` is a drop folder only, visible in Files and in Finder over USB. `Library/Caches` holds what can be rebuilt.

### Import path

- `fileImporter` with `supportedTypes + [.folder]`, and `onOpenURL` on the root view. Both go to one iOS step: hold until the library is open, start scope, copy under `NSFileCoordinator` on the import queue into Import Staging with progress, stop scope, then hand the local copy to the existing `importFiles`. The rest of the import is unchanged.
- Remove anything from `Documents/Inbox` after import, and sweep it at launch. Each import in `beginBackgroundTask`, with `BGContinuedProcessingTask` afterwards. No share extension in the first version. Fix the `afinfo` step first, or no M4B imports.

### Plist keys

- Plist: `UIBackgroundModes` = `audio`; `UIFileSharingEnabled` = true; `CFBundleDocumentTypes`; `UTImportedTypeDeclarations`; `UTExportedTypeDeclarations`; `NSAppTransportSecurity` if feeds ship.
- Build settings: `GENERATE_INFOPLIST_FILE`, `INFOPLIST_FILE`, `INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace` = YES, the existing display name, launch screen, and scene manifest keys, and a distinct `PRODUCT_BUNDLE_IDENTIFIER`. Later: `BGTaskSchedulerPermittedIdentifiers`.

### What a first real run must check

Speech and the lock:

1. Direct speech, press the side button, listen for five minutes. Does it keep speaking? (Thread 849627.)
2. Engine audio, same test.
3. A chapter boundary while locked, with look-ahead ready and not ready.
4. A manifest chapter pause, the next book in the folder, and a chapter whose speech takes time to prepare, all locked.
5. `.spokenAudio` against `.default` by ear, with a compact and an enhanced voice.
6. Does the one-word warm-up stop Music when a book opens?
7. Does `speak` run alongside a `write`, or stutter as on the Mac?
8. Render speed in seconds per 1,000 units, foreground and locked, watching for `CPU_FATAL`; and whether a 100,000-unit chapter beats the 120-second limit (`AudioEngineService.swift:1202`).
9. The WPM table and `renderWPM` (`AudioEngineService.swift:1025`) are Mac measurements: time a known passage on both paths. The sample rate `write` delivers, per voice.

Interruptions and routes:

10. A phone call, accepted then ended, locked and unlocked: `shouldResume`, and whether reactivation works or gives `!int`.
11. Siri, an alarm, and Maps prompts.
12. Is `didCancel` delivered on an interruption? Does speech then misreport a refusal?
13. AirPods: one out, one back, both out, into the case, stem presses once, twice, and three times, and Sleep Detection. Log every command and route reason, in order.
14. Wired headphones out on each path, and AirPods in while the engine plays. Does it stop itself?
15. Settings, Developer, Reset Media Services, during speech and during an audiobook.

The lock screen:

16. Does TextMouth appear, on each path? Is the icon right after a pause, with the session active and inactive?
17. Which side buttons show with each set of enabled commands?
18. What does VoiceOver read for each control and for the title?
19. Lock-screen Play after a minute, an hour, and after the app was killed. Does activation succeed?
20. VoiceOver announcements while backgrounded: heard or lost? Do its speech and the book duck or overlap? Magic Tap, with and without the handler.

Life cycle and memory:

21. Reinstall over the top: do all books open, feed items too?
22. Kill by the switcher and by memory pressure: how far back is the place?
23. `os_proc_available_memory()` in the foreground and locked, with the largest book and with two renders.
24. Launch time with the whole library, against the watchdog.
25. The sleep timer over an hour locked: does it stop on time? A fade on each path?

Files:

26. Writing at the chosen root, with the `getpwuid` result logged once to settle section 6.
27. Pick an EPUB and an M4B from On My iPhone, iCloud Drive (downloaded and not), and a third-party provider; a 2 GB file; a folder of tracks; 400 files at once.
28. Share or open an EPUB from Mail, Files, Messages, and a Safari download, cold and warm. What URL arrives?
29. An import on leaving the app, with a book playing and without. Killed in the middle.
30. Does `Documents` show in Files with a file in it? In Finder's Files tab?
31. The runtime list of playable types, FLAC included.
32. Does `BGContinuedProcessingTask` run, and does VoiceOver read its Live Activity?

### The 15 most dangerous assumptions in the current code

1. The home directory is the sandbox's. `TextMouthRuntime.swift:144-149` (`getpwuid`), used at `:123`; `.TextMouth` at the container root, `TextMouthPaths.swift:15-17`; `MachineLocalPaths`, `CloudStorageContract.swift:577-580, 650-653`. Nothing can be saved.
2. Audio needs no session. No `AVAudioSession` in `TextMouth/`; `SpeechService.swift:1162`, `AudioEngineService.swift:1286`, `AudioPlaybackService.swift:982`. It stops at the lock and obeys the silent switch.
3. The generated plist is enough. `project.yml:284-293`: no background mode, no document types, no imported types, which also empties `FileImportService.swift:2874-2886, 2911-2921`.
4. `afinfo` is always there. `AudioFileInfo.swift:285, 292` with `WatchedProcess+iOS.swift:106-116`, reached from `FileImportService+AudioConversion.swift:51, 60`. Every M4B, M4A, and MP4 import fails.
5. Something will call the quit path. `UnsavedChangesTermination.swift:187` is called only from `AppDelegate.swift:195-234` and the guard, with debounces at `LibraryPersistenceService.swift:192, 961`. Nothing flushes at background, and `close()` (`ReaderViewModel.swift:2239`) never runs on a kill.
6. A device listener sees the headphones leave. `NowPlayingService.swift:1406-1410`: none on iOS, so speech goes on aloud, and `:1536, :1561` can't be reached from the `+iOS` file.
7. A running engine stays running. `AudioEngineService.swift:1286` with no configuration-change observer; `:185, :795` can take a self-stop for the end of a chapter; no watchdog watches the engine.
8. A `didCancel` the app didn't ask for is a refusal of the text. `SpeechService.swift:2702-2718, 1495-1514, 1544-1555`. On iOS it may be an interruption.
9. A main-queue delay always fires. `ReaderViewModel+Playback.swift:2333, 2945`, `ReaderViewModel+BookMoves.swift:148`, `ReaderViewModel+WhereAmI.swift:611`, with no audio playing, so the app can be suspended first.
10. A new player can start at any time. `AudioPlaybackService.swift:826` makes a new `AVQueuePlayer` per file, and a report says a new player in the background gets its rate reset to 0.
11. A tick is a second. `SleepTimerService.swift:936-955` counts ticks of a repeating `Timer`, which skips missed fires.
12. `playbackState` tells the system. `NowPlayingService.swift:1227, 1237` (macOS only, per `MPNowPlayingInfoCenter.h:66-70`); no elapsed or duration at `:1230-1234`; targets appear only with a first reader (`:509, :850`), so Play after a relaunch does nothing; `preferredIntervals` at `:772, :776` promise seconds that `ReaderViewModel+Navigation.swift:134-140` may not skip.
13. Memory is measured in gigabytes. `PlaybackMemoryGuard.swift:54, 60` act above most iPhones' limits, `:470-474` calls `_exit(0)`, and renders of up to about 98 MB each, two at a time (`SpeechService.swift:328`), aren't checked against what's left.
14. A chosen file is on disk and may be read plainly. `FileImportService.swift:1209, 2478-2506`, with no `NSFileCoordinator` anywhere; `LibraryViewModel+Import.swift:173` reads a folder on the main thread before any scope; `FileImportService.swift:2368` uses a trash iOS may not have.
15. The background has CPU to spare, and the system sounds exist. A full render at `.userInitiated` (`AudioEngineService.swift:929`) and a 0.1-second position timer on `.userInteractive` (`SpeechService.swift:2228, 2238`), both against an 80-percent CPU monitor; and `/System/Library/Sounds` (`SoundEffectService.swift:194`), which leaves a blind listener without the Play and Pause sounds.
