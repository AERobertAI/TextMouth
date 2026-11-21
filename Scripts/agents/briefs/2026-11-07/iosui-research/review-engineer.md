# iPhone interface spec: engineering review

Reviewer: `iosui-review-eng`. I read `IOS-INTERFACE-SPEC-2026-11-07.md` whole, at abb68ac3 (its text is unchanged since aa8a55d8), and checked it against the code, the iOS 26 SDK, and Apple's pages. I also read `iosui-slices.md`, and the shared edits so far on `ios/s1-foundation`. Line numbers without a file are the spec's. Nothing here has run, so "expected" marks what no header or page states outright.

## In short

- The design stands. I would not reopen the UIKit life cycle, the UIKit controls, the row instead of the bar, or where the library lives.
- Three things can't work as written: the next book on a locked screen (F1), how shared words are held back (F2), and the reuse of the Mac's sheets (F3). Fixing F3 also removes the only change the spec proposes to the Mac's views.
- One SDK header answers a question the spec left open. A background activation is allowed "only when the app is the NowPlaying app" (F1). That gives a rule the spec needs: stay the Now Playing app.
- I found nothing sure to crash at launch. The nearest risks are a crash that repeats at every launch, because the book reopens (F4), and two crashes a natural first draft would write (F5, F6).
- Slice 1 should land more shared seams than it has now, or Slices 2 to 8 will collide (see "The slices").

## Blockers

### F1. BLOCKER: the next book can't start on a locked screen

- **Where:** "Deactivate... when: ... the book being closed" (513); "`open(_ book:)`... closes the old one and makes the new" (793); "Unverified: whether a non-mixable session can activate there" (551).
- **What's wrong:** at a book's end, `.continueToNextBook` reaches `PhoneSession`, which closes the old reader first. `close()` clears Now Playing, and the spec's rule deactivates the session. The new reader then loads on a background queue and claims its play when loaded. That is a non-mixable activation, in the background, by an app that has just stopped being Now Playing.
- **Evidence:**
  - `CoreAudioTypes.framework/Headers/AudioSessionTypes.h:50-52`: `CannotInterruptOthers`: "The app's audio session is non-mixable and trying to go active while in the background. This is allowed only when the app is the NowPlaying app."
  - `ReaderViewModel.swift:2256-2257`, then `NowPlayingService.swift:635-637` and `1226-1227`: info nil, state stopped.
  - `ReaderViewModel.swift:1461-1473` and `1745`, `ReaderViewModel+Playback.swift:3044-3059`: load, then claim.
- **Do instead:**
  - Add the rule to the spec: TextMouth stays the Now Playing app from the first Play until the listener opens another book in the foreground, or removes the book. A pause and a background deactivation leave the item in place. This also answers line 551.
  - "The book being closed" deactivates only when the listener opened another book in the foreground and no autoplay request waits (`ReaderAutoplayRequests.shared.waitingRequest(for:)`).
  - On a hand-over: hold `PhoneBackgroundHold`; make the new reader first; call its `updateNowPlayingInfo(title:author:isPlaying: false)`; then close the old one. `unregister` then publishes the new reader's item (`NowPlayingService.swift:635-640`). New before old is also the order the Mac has always run, since its old window stays open while the new one opens.
  - Handle the notification on the main queue's next turn, not inside it: `showNextBook` is still on the old reader's stack (`ReaderViewModel+NextBookWindow.swift:176-178`).
  - Test it in `PhoneSessionTests` with `NowPlayingService(systemNowPlaying:)`, whose recorder sees the item (`NowPlayingService.swift:444`).

### F2. BLOCKER: holding back the reader's words "only around the phone's own calls"

- **Where:** 289, against principle 1 (18), and 294, 307, 332. Also the brief's `collectingAnnouncements(during:)` in `PhoneReaderModel`.
- **What's wrong, in three parts:**
  - Remote moves aren't the phone's calls. The AirPods' double press runs `onSkipForward`, then `skipForward()`, then `performSkip`, which announces "Next sentence" over the book (`ReaderViewModel.swift:1059-1060`, `ReaderViewModel+Navigation.swift:130-141`, `363`).
  - "Only while it plays" contradicts the spec itself. A paused move by sentence must not say "Next sentence" (294), and adjusting the unit or the speed must never post their words (307, 332). These are `ReaderViewModel+Navigation.swift:38`, `ReaderViewModel+VoiceAndSpeed.swift:42`, `ReaderViewModel+Playback.swift:2528`.
  - A hold that drops everything in its scope drops words that must be heard. `navigateTo` can end the book or a sleep timer inside the move, and those say so before the move's own words (`ReaderViewModel+Navigation.swift:896`, `964`; `ReaderViewModel+Playback.swift:905`).
- **Does holding work, given what's deferred?** Yes for moves. Every move's own words are posted synchronously, after the move, through one funnel (`ReaderViewModel+WhereAmI.swift:866-882`). What's deferred or asynchronous is not a move's words, and should still be heard: `afterSheetCloses` (`VoiceOverAnnouncer.swift:91-95`), a bookmark refused (`ReaderViewModel+Bookmarks.swift:197-201`), a heading-end stop (`ReaderViewModel+Playback.swift:1157`), cloud words (`ReaderViewModel+CloudDownload.swift:745`), and timer expiry (`ReaderViewModel+Playback.swift:3203`). Natural playback announces no chapter change, so nothing needs holding there.
- **Do instead:**
  - One path for every move. Under `#if os(iOS)` in `setupCallbacks`, `onSkipForward` and `onSkipBackward` call a closure `PhoneSession` sets, which runs `PhoneReaderModel.move(forward:)`. Skip buttons, adjusting, rotors, and remote commands all use it.
  - `collectingAnnouncements` swaps `VoiceOverAnnouncer.poster` (`VoiceOverAnnouncer.swift:52`) around one synchronous call and restores it in a `defer`. `announce` itself doesn't change, so the Mac doesn't either. Put it in `TextMouth/Phone/` as an extension, so the Mac's test host can test it.
  - `PhoneMoveFeedback` sorts what was collected. For a structural unit that moved, the last word collected is the move's own, and earlier ones pass. For a unit in seconds, all pass, since those moves have no words of their own. If nothing moved, the Mac's word passes ("This book has no pages."), else the spec's "No next heading."
  - Then: if the book is playing after the move, drop the move's own word. If paused: heading, subheading, page, and bookmark keep theirs; sentence, paragraph, and seconds say the new place's words. Use the state after the move, since a backward skip from a finished book starts it (`ReaderViewModel+Navigation.swift:277-290`).
  - Use the same collector around `adjustSpeed`, `setAudioSpeed`, and `setSharedPlaybackSkipUnit`, keeping nothing.
  - Reword 289 to say all this.

### F3. BLOCKER: the Mac's sheets can't be reused as claimed

- **Where:** 173, 467, 471, 606-607, 615, 809-810, 816.
- **What's wrong:**
  - "In a `NavigationStack`... Cancel and confirm buttons in the toolbar" can't come from these views. Their buttons are in an `HStack` in their bodies, and each has its own heading (`LibrarySheetViews.swift:377-380`, `398-407`). Wrapping gives two titles and no toolbar buttons.
  - None scrolls. At a phone's width and at large Dynamic Type sizes, the lower controls are cut off.
  - `Picker` with no style in a `VStack` is a menu on iOS (expected), which 98 forbids (`LibrarySheetViews.swift:386`, `556`).
  - `SleepTimerView` observes the service and redraws every second, with a changing `accessibilityLabel` on a `Text` (`SleepTimerView.swift:46`, `145-147`). "Computed when focused" (471) can't be built in it, and it breaks principle 3.
  - The vertical list of 615 can't come from `ImportDecisionSheet`'s `HStack` (`ImportDecisionSheet.swift:87-93`).
  - Of the "used as they are": `ProgressOverlay` has a bar 300 wide with 32 padding each side, which is wider than a list row on most iPhones (expected), and a label that changes as it moves (`ContentView.swift:555`, `585`, `591`). `ReaderErrorAlert` observes the whole reader at 8 Hz (`ReaderView.swift:419`), against 796.
- **The count for `macOSFixedFrame`:** nine lines in four files. `LibrarySheetViews.swift:152`, `410`, `817`, `941`, `1020`, `1101`; `ImportDecisionSheet.swift:76`; `MetadataEditorView.swift:140`; `SleepTimerView.swift:101`. It would be safe for the Mac, and it isn't enough.
- **Do instead:**
  - Drop `macOSFixedFrame`. Rebuild these for the phone, calling the same closures and wording statics: the five folder sheets, Book Info, the import question, the sleep timer, and the progress card. Each is a small `Form`, about 40 to 80 lines. No Mac view changes, and no line is needed in `mac-projection.py`.
  - Folder choices go through `PhoneChoiceSheet`, from `LibraryFolderOption.options(in:)`.
  - The import question sets `.interactiveDismissDisabled(true)`, and its escape is the question's own cancel choice, since only an answer settles it (`ImportDecisionPresenter.swift:77-82`).
  - Book Info hides "write to the file": on iOS that throws (`docs/architecture/platforms.md:67`).
  - The alert reads the error from `PhoneSession`'s snapshot.
  - Truly reusable as they are: `ReaderLoadFailureView`, `HeadingRow`, `BookmarkRow`, `OperationFailureNotice`, `SheetWorkIndicator`, `PersistenceFailureBanner`, `ReadingStatsView`.
  - Slice 2 grows by this, so split the folder sheets into a slice of their own if workers are free.

## Major

### F4. MAJOR: one crash on opening a book repeats at every launch

- **Where:** 501, 797.
- **What's wrong:** the book reopens by itself at launch. A book that crashes or jetsams the reader on load does so again at each launch, before the listener can do anything. The only way out is deleting the app, and with it the library. This is an app that has never run, reading files it has never read on this platform.
- **Do instead:** before `makeReader`, write `phone.openingBookID` synchronously to `UserDefaults`. Clear it when the reader stops loading, whether it loaded or failed. At launch, if the key is still set, don't reopen. Stay on the Library, clear the key, and say with low priority: "TextMouth closed while opening Dune, so it wasn't reopened." Put it in Slice 1, with a test.

### F5. MAJOR: a main-actor trap waits in the audio notifications

- **Where:** "a small iOS file observes" (529), 533-535.
- **What's wrong:** the threads differ, and the spec doesn't say so. Under Swift 6, main-actor code a framework calls on another thread stops the app (`project.yml:33-35`).
- **Evidence:**
  - Apple's page for `routeChangeNotification`: "The system posts this notification on a secondary thread."
  - `AVAudioEngine.h:893-895`: the configuration change's "callback happens on an internal dispatch queue", and the engine "must not be deallocated from within" the handler.
  - Apple's page for `interruptionNotification`: posted on the main thread.
- **Do instead:** every observer uses `addObserver(forName:object:queue: .main)`, and only then `MainActor.assumeIsolated`. Never `queue: nil` with `assumeIsolated`, and never a Combine `.sink` without `.receive(on: DispatchQueue.main)`. The configuration change names each engine as its `object`, and there can be two (`SpeechService`'s and the look-ahead's), so observe inside `AudioEngineService` under `#if os(iOS)`. Follow the pattern at `NowPlayingService.swift:798-805`.

### F6. MAJOR: `AVAudioEngine` exceptions aren't caught where the phone will hit them

- **Where:** 534, and speech's move to the engine at a natural break.
- **What's wrong:** AVFAudio reports broken preconditions by raising `NSException`, and Swift can't catch those. The code already catches them on the player node, but not on `engine.start()` or `engine.connect`. On a phone these run with routes coming and going, and during interruptions.
- **Evidence:** `AudioEngineService.swift:686-690` catches; `1259-1262` and `1286` don't.
- **Do instead:** under `#if os(iOS)`, wrap `connect` and `start` in `ObjCException.catching`, and report failure the way the `start` failure path already does. The catcher is linked (`project.yml:303`).

### F7. MAJOR: activation has no seam, its failure has nowhere to go, and other voices skip it

- **Where:** 511, 514, 532.
- **What's wrong:**
  - There is one good place, and the spec doesn't name it. All three starts call `nowPlayingService.activateRemoteCommandsIfNeeded()` (`ReaderViewModel+Playback.swift:76`, `222`, `249`). But that returns nothing, so a refused activation (a call in progress) can't stop the play. The reader would show Playing in silence until the start watchdog gives up, or `engine.start()` fails.
  - Where Am I? and Preview Voice speak without passing there (`ReaderViewModel.swift:389`, `ReaderViewModel+WhereAmI.swift:561`, `ReaderView.swift:1109`). With `usesApplicationAudioSession` on, they use an inactive session (`AVSpeechSynthesis.h:259-263`).
- **Do instead:**
  - Add one `#if os(iOS)` closure on the reader, `audioMayStart: () -> Bool`, default true. Call it just above line 73 of `play()`, and at the top of `resumeAudioPlayback()` and `resumeSpeechPlayback()`, before any state changes. `PhoneSession` sets it to activate, log how long that took, and on failure say `PhoneAnnouncer.important` and answer false.
  - Call the same activation before Where Am I? (`whereAmI(_:)`) and in the phone's own Preview Voice.
  - On the thread question: `play()` runs on the main actor, and a remote command reaches it through `DispatchQueue.main.async` (`NowPlayingService.swift:439-443`, `863-865`), so activation never runs inside MediaPlayer's handler. Main thread at Play is acceptable for a first version, as 514 says.

### F8. MAJOR: deactivating a paused book fails while its engine runs

- **Where:** "after stopping audio" (513), when entering the background while paused.
- **What's wrong:** a paused book isn't stopped. `AudioEngineService.pause()` pauses the node and leaves the engine running (`AudioEngineService.swift:1416-1421`). `setActive(false)` then fails with `IsBusy` (`AudioSessionTypes.h:43-45`), the session stays active, and other apps' audio isn't told to resume.
- **Do instead:** before deactivating, call `reader.invalidatePlaybackBackendForAudioRouteChange()` (`ReaderViewModel+Playback.swift:333`), so the next resume starts cold, and add an iOS-only `AudioEngineService.pauseEngine()` that calls `engine.pause()`. `resume()` already restarts a stopped engine (`AudioEngineService.swift:1456`). Log a thrown error and treat it as harmless. Leave Now Playing in place (F1).

### F9. MAJOR: a remote Play with no reader is refused, and a Play during loading is lost

- **Where:** 279, 551, 794.
- **What's wrong:** `acceptRemoteCommand` answers `.commandFailed` when there's no owner (`NowPlayingService.swift:850`), so "the handler opens the book last open" can't happen, and nothing in 819 names that change. Commands are also registered only when the first reader appears (`NowPlayingService.swift:509`, `668-673`). While loading, `play()` returns silently (`ReaderViewModel+Playback.swift:39`), so "the press is remembered" needs code. The autoplay request looks like the tool for it, but it restarts a finished book from its beginning (`ReaderViewModel+Playback.swift:3053-3056`), unlike a real Play.
- **Do instead:**
  - Call `activateRemoteCommandsIfNeeded()` in `didFinishLaunching`.
  - Add an `#if os(iOS)` fallback closure in `acceptRemoteCommand`, called on the main queue when there's no active owner, which runs `PhoneSession.togglePlayPauseFromAnywhere()`.
  - Add `PhoneSession.playWhenLoaded: Bool`. Play, the magic tap, and remote Play set it while `reader.isLoading`, and a second press clears it. A subscription to `reader.$isLoading` calls `playOrResume()` when loading ends without an error, and otherwise drops it.

### F10. MAJOR: the settings "set once by the app" have no mechanism, and their defaults are wrong for the phone

- **Where:** 311, 702, 704.
- **What's wrong:**
  - `PlaybackNavigationUnitControlMode` defaults to `.none` (`SettingsPolicy.swift:439-440`). In that mode the reader ignores the book's own unit (`ReaderViewModel+Navigation.swift:12-13`, `25-33`), so choosing a unit on the phone would appear to do nothing.
  - `moveToTrashInsteadOfDeleting` defaults to true (`ConfigService.swift:263-264`), so a removal takes the Trash path (`FileImportService.swift:2367`, `2383`).
- **Do instead:** add `PhoneDefaults.apply(to: settings, config:)`, plain and tested, called by `PhoneAppModel` before any reader exists, at every launch: mode `.shared`, Trash off, Keep Original.

### F11. MAJOR: Library rows do change while the book plays

- **Where:** 158, and the brief's "Rows read a value computed when the list is drawn".
- **What's wrong:** the list is drawn again whenever `LibraryViewModel` publishes, and it publishes at every 30-second checkpoint and after every move (`LibraryViewModel.swift:117`, `LibraryViewModel+BookOperations.swift:689-697`, `ReaderViewModel+Navigation.swift:685`, `763`, `826`, `971`). The playing book's percent and time left change in its label, and focus lands on exactly that row after Back (62). A changed label on a focused element can be spoken (principle 3).
- **Do instead:**
  - `PhoneLibraryRows`, a small `ObservableObject` in `TextMouth/Phone/`. `PhoneLibraryView` observes it and not the library.
  - It holds `[PhoneRowValue]`, each an `Equatable` struct of id, label, and visible lines. It subscribes to `library.$library` and republishes only when the list's signature changes: the IDs in order, titles, authors, and folder counts.
  - It rebuilds fully on `onAppear`, when a book stops playing, and when the view, sort, or search changes.
  - `PhoneBookRow` takes only a `PhoneRowValue`, and uses `.equatable()`.
- **For a large library:** `displayedBooks(at:matching:)` is cached (`LibraryViewModel+FolderManagement.swift:396-413`), and a `List` makes rows lazily. 743 rows are cheap if the row values are built once per list, not per redraw. Hand-check 37 measures it.

### F12. MAJOR: focus requests to `List` rows fail silently

- **Where:** 62, 64-65, 168, 428.
- **What's wrong:** a row not yet made has no element, and setting `AccessibilityFocusState` for it does nothing and reports nothing (expected). So "if the row isn't on the screen" can't be known by asking. Setting the same value twice also does nothing. Two workers would solve this differently.
- **Do instead:** one helper, `PhoneListFocus`, used by every list.
  - Wrap the `List` in a `ScrollViewReader`.
  - If the row's ID is in the current list: `proxy.scrollTo(id)`, wait 0.35 seconds, set the state to nil, then to the row. If the ID is gone: use the policy's fallback, the Continue row or the next row.
  - For controls: `AccessibilityFocusState` for SwiftUI rows only. A `UIViewRepresentable`'s view gets `UIAccessibility.post(.layoutChanged, argument: view)`, as the spec has it.
  - Slice 1 lands `PhoneFocusRegistry`, a weak `[PhoneControlKind: UIView]`, filled by `makeUIView`, so Slices 4, 7, and 8 agree.
  - `PhoneChoiceSheet`, already on the branch, has this bug for a long list: a selected voice far down isn't focused. Add the same `ScrollViewReader`.

### F13. MAJOR: nothing owns the navigation path

- **Where:** 32, 792-798, 69.
- **What's wrong:** `open(_:)` "shows" the reader, and imports, the Continue row, and reopening all need to push it, but the spec gives no type for the path. If the route carries a book ID, or the view uses the Mac's `.id(bookID)` (`TextMouthApp.swift:69`), then the next book rebuilds the screen and focus is lost, against 69.
- **Do instead:** `PhoneRoute` in `TextMouth/Phone/`: `.folder(path)`, `.reader`, `.settings`, with no book ID in `.reader`. The path is `@Published` on `PhoneAppModel`, and `NavigationStack(path:)` binds to it. `PhoneReaderView` and its `PhoneControl`s are never keyed by book; each control asks the session for the current reader at the moment VoiceOver asks. Slice 1 lands this.

### F14. MAJOR: the coordinated copy can hold the import queue for ever, and nothing says when its copy goes

- **Where:** 592, 601.
- **What's wrong:**
  - `SerialImportQueue` is one serial queue (`LibraryViewModel+Import.swift:16-17`). `NSFileCoordinator`'s read has no time limit, so a file provider that hangs or an offline iCloud file blocks every later import, with no way out. The team's rule is that every wait has a limit.
  - `importFiles` returns at once and has no completion (`LibraryViewModel+Import.swift:888-913`), and a duplicate's question holds its URL for as long as it waits. So "removed after the import" has no moment.
  - A coordinated read of a folder doesn't bring down its children (expected), and a phone needs room for two copies of a 2 GB book.
- **Do instead:**
  - Run the copy on a queue of its own, before `enqueueImport`. Keep the `NSFileCoordinator` so Cancel Import and a stall limit can call `cancel()`.
  - For a folder, coordinate each file.
  - Copy into `tmp/PhoneImport/<UUID>/<original name>`, keeping the name, since the book's title comes from it.
  - Check the free space first, with `volumeAvailableCapacityForImportantUsage`, for twice the size.
  - Sweep that folder and `Documents/Inbox` when `library.isImporting` is false and `library.importDecisions.current` is nil, by observing those two published values. Don't take `onActivityChanged`: it has one slot, already used (`LibraryViewModel+Import.swift:503`). Sweep at launch too. Sweeping is the app's own deletion of its own scratch at run time, which tonight's no-delete rule, about agents' commands, doesn't touch.

### F15. MAJOR: how `PhoneControl` computes its words

- **Where:** 209-212.
- **What's wrong:** the shape is right, but VoiceOver asks for label, value, hint, traits, and frame, several times for each focus. A full `PhoneReaderState` per getter means `HeadingPosition` and page lookups, over and over, on the main thread. Two workers would also read different cursors.
- **Do instead:**
  - Each getter calls a closure into `PhoneReaderModel`, which builds `PhoneReaderState` once and keeps it until the main queue's next turn (`DispatchQueue.main.async { cache = nil }`).
  - It reads the real cursor, `currentChapterIndex` and `currentCharacterOffset`, not the throttled display one.
  - `accessibilityActivate()` returns true after acting.
  - No `.accessibilityElement(children:)` may wrap the column, or the UIKit views vanish from VoiceOver. Order then follows the `VStack` (expected): add "in the spec's order" to hand-check 14.
  - A value is read at focus, so a braille line can go stale while focus rests there. That's acceptable, and it's what check 14 will show.

### F16. MAJOR: Book content's policy needs its inputs named

- **Where:** 255-265.
- **What's wrong:** nothing says how the view knows it has focus, what drives the 10 seconds, or what runs in the background.
- **Do instead:**
  - `PhoneBookTextView: UITextView` overrides `accessibilityElementDidBecomeFocused()` and `accessibilityElementDidLoseFocus()` (`UIAccessibility.h:315-316`), which set `hasFocus`. Losing focus asks the policy at once.
  - A `Timer` in `PhoneReaderView`, on the main run loop, runs only while the scene is active, the reader is on screen, and the book plays, every 10 seconds. It doesn't run in the background: on coming back, one refresh.
  - `PhonePassagePolicy` is pure: `(cursor, chapterText, hasFocus, isPlaying, event)` gives a range or "no change". It uses `ReaderViewModel.sentenceStart(in:before:)` (`ReaderViewModel+Navigation.swift:524`). Compare before assigning `text`.
  - Layout: `isScrollEnabled = true`, and a fixed height in SwiftUI. Scrolling off, 20,000 characters would make the column enormous.

### F17. MAJOR: "stops the moment the listener moves" can't be told from VoiceOver landing elsewhere

- **Where:** 61.
- **What's wrong:** `elementFocusedNotification` reports both alike. Reposting `.screenChanged` also replays its sound, and yanks a quick flick back.
- **Do instead:** first post `.screenChanged` with Play at 0.35 seconds. Watch the notification. Once focus has been on Play even once, stop for good: any later move is the listener's. If it hasn't landed by 1.2 seconds, post `.layoutChanged` with Play once, and stop at 3 seconds. Put it in `PhoneFocusPolicy`, as a small state machine with injected time.

### F18. MAJOR: "low priority" can't be reached by the mapping, and a short import says nothing

- **Where:** 74, 77, 479, 594, hand-check 2.
- **What's wrong:**
  - The shared import ending posts at the default `.high`, which maps to `.default` (`ImportProgress.swift:361-362`).
  - It says nothing unless the import ran long (`ImportProgress.swift:387-388`), so hand-check 2 would fail on a short EPUB.
  - The timer's milestones are `.medium`, which also maps to `.default` (`SleepTimerService.swift:1068`), so they would interrupt VoiceOver's own reading.
  - Milestones also match exact seconds (`SleepTimerService.swift:1056-1057`). With a deadline, a late tick jumps past one.
- **Do instead:** `#if os(iOS)` at those two calls, giving `.low`. On iOS, `.book` announces however short the import. `PhoneSleepDeadline` reports milestones crossed since the last tick, not exact matches. Principle 1 also needs the timer's milestones named as an exception, or they must go.

### F19. MAJOR: the word watchdog and "start on the engine" meet existing code

- **Where:** 522-523.
- **What's wrong:**
  - A voice that reports no words would look like silence at every tick, and restart at the same word until the recovery cap pauses it. Reports differ by voice (expected).
  - "If finished rendered audio is ready at Play" can't be reached in `speak(_:fromCharOffset:)`, which stops and discards rendered audio first (`SpeechService.swift:1011-1018`).
- **Do instead:**
  - Arm the watchdog only after this play's first word has arrived. Disarm while interrupted. Extend the existing tick (`SpeechService.swift:1198-1226`), and share `idleRecoveries` (`SpeechService.swift:1327-1332`), so the cap holds.
  - Add the engine start as a branch at the top of `speak`, under `#if os(iOS)`, before those lines, using `renderedAudioMatchesSpeech`.

### F20. MAJOR: rotors are in the wrong place, and contradict the rule on moves

- **Where:** 398, 403, 406.
- **What's wrong:**
  - "On the reader's container" doesn't exist: the column is SwiftUI, and the hosting view is SwiftUI's own.
  - Moving inside a search block is a side effect in what the API calls a search (`UIAccessibilityCustomRotor.h:94-96`), and VoiceOver may call it when you don't expect (expected).
  - The result moves focus to Where Am I?, whose value is then spoken. So a move while playing is not silent, against 406 and principle 1.
- **Do instead:** set rotors on the elements themselves. Every reader control but Back and the title is a `PhoneControl`, and the header says "an element (or an element in the ancestor hierarchy)" (`UIAccessibilityCustomRotor.h:19`, `64`), so override `accessibilityCustomRotors` there. That makes the window question moot. Build this last, with one flag, and cut it first if the night runs short: adjusting Play is the design, and this is a second way.

### F21. MAJOR: what `lastOpenedBook` returns, and the reopening

- **Where:** 83-84, 186, 501, 570.
- **What's wrong:**
  - `lastOpenedBook` returns nil once that book is deleted (`LibraryViewModel+BookOperations.swift:966-970`), so the row can't go "to the book before it in Last Opened".
  - Its ID reaches disk only when changes pause (`LibraryViewModel+BookOperations.swift:943-947`), so a kill can lose it.
  - The spec's preference key is a second store of nearly the same fact, since going back doesn't close a book.
- **Do instead:**
  - `PhoneSession.bookInReach`: the open reader's book, else `lastOpenedBook`, else the row with the newest `lastOpened`, else nil, which is what makes the magic tap return false.
  - Keep the one preference for reopening, written synchronously at open, removed on deletion, and read through F4's check.
  - At launch, an opened file wins over reopening. A book no longer in the library clears the key. A launch for a remote Play sets `playWhenLoaded`.

## Minor

- **F22. Library order needs an inline title (106-113).** With the default large title, the bar's buttons come before the title (expected). Use `.navigationBarTitleDisplayMode(.inline)` on every Library screen and the reader, with Settings and Add in one `ToolbarItemGroup(placement: .topBarTrailing)`.
- **F23. One `fileImporter` (591).** Reports say two on one view don't both work. Use one, with its types and `allowsMultipleSelection` from a `@State` mode (SwiftUI interface:7400), inside the Add to Library sheet. On completion, dismiss the sheet, then hand over the URLs.
- **F24. `shouldResume` (532).** Resume only if the interruption itself paused the book. Give `PhoneAudioEventPolicy` an input `wasPlayingWhenInterrupted`, or a book the listener paused starts by itself after a call.
- **F25. No suppression on iOS (533, 819).** Don't call `armSuppressAndPauseIfPlaying` on the phone. It gates Play and Toggle for its window (2 seconds by `setup`'s default), for a bug the file itself calls macOS's (`NowPlayingService.swift:214-221`, `1536-1556`), so a Play as AirPods go back in could be lost. In the iOS block: `noteExternalRoutingChange()`, `onAudioRouteChangePause()` if playing, then `invalidateRegisteredAudioBackends`.
- **F26. Media services reset (535).** "Rebuild the audio objects" is simply: close the reader, set the category, and open the same book paused. `close()` and `init` already make everything anew.
- **F27. Two windows on an iPad (766).** The generated scene manifest allows several scenes (expected: check the built plist). One `PhoneSession` can't serve two. Put `UIApplicationSceneManifest` in `iOSApp/Info.plist` with `UIApplicationSupportsMultipleScenes` false, and drop the `_Generation` key.
- **F28. Memory guard (574).** `MemoryWatch.quit` still reaches `_exit(0)` on iOS unless guarded (`PlaybackMemoryGuard.swift:470-474`, `591-602`). And `os_proc_available_memory()` returns 0 "if the calling process is not an app, or the calling process exceeds its memory limit" (`usr/include/os/proc.h:81-82`), so a Simulator run would stop every book. If the first reading is 0, the guard stays idle for the process.
- **F29. Voices (495, 785).** `PhoneAppModel`'s order leaves out `VoiceCatalog.shared.loadIfNeeded()` (`TextMouthApp.swift:32`). Without it, "No voices are installed" would be said falsely. Call it from the first screen's appearance.
- **F30. No lease on a phone.** `DataDirectoryEnvironment.app`'s iOS branch passes `.shared` lease and the fetcher (`LibraryViewModel.swift:546-551`), which starts a repeating timer (`LibrarySessionLease.swift:190-195`). Pass nil for both: that branch is iOS only, and a phone's library is never shared.
- **F31. Album goes stale (542).** `updateNowPlayingInfo` runs only at play, pause, and moves. Either drive the heading from `PhoneSession`'s snapshot, or leave Album out of the first version. Extra fields on `NowPlayingItem` go under `#if os(iOS)`, since `NowPlayingOwnershipTests` compares it.
- **F32. Background tasks (559, 563, 567).** Every one's expiration handler must end it, or iOS terminates the app. Say so in `PhoneBackgroundHold`.
- **F33. Plist test (841).** `IOSInfoPlistTests` should also require a declaration for every `UTType(importedAs:)` and `UTType("com.textmouth...")` in `supportedTypes` (`FileImportService.swift:2874-2921`). Undeclared, the `UTType("...")` ones are nil and silently drop out of the picker. `ios/s1-foundation` has the declarations; the spec doesn't mention them. That branch also sets `LSSupportsOpeningDocumentsInPlace`, while 601 speaks only of the Inbox. Both happen: Files gives a URL in place, and Mail gives an Inbox copy. So the opened-file path starts the scope for every URL.
- **F34. `PhoneSession` seams (790).** Take a `makeReader` closure and a `NotificationCenter`, so tests never reach the running host's center. If `bookByID` is nil, refuse: don't make the Mac's placeholder book.
- **F35. Speech speed may read wrong (329).** `rateTable` was measured on a Mac (`SpeechService.swift:2304-2307`). Log the measured pace at the first run.

## The questions, in brief

Questions 4, 5, and 6 have sections of their own below.

### 1. What can't be built as written?

- F1, F2, F3, F9, F13.
- **The frame is right.** `UIKit.swiftinterface:5148-5155` gives `UIApplicationDelegate` a `@MainActor static func main()`, so `@main` on a delegate works in the SwiftPM executable as the placeholder's did. A scene delegate named from `configurationForConnecting` works with a generated manifest.
- **Hosted SwiftUI is fine.** `NavigationStack`, `.searchable(placement: .navigationBarDrawer(displayMode: .always))`, sheets, alerts, `fileImporter`, and `AccessibilityFocusState` all exist as modifiers needing no `Scene` (SwiftUI interface:9346, 7400, 21454-21501). None of the reused views reads `scenePhase` or `openWindow`, and none needs an `@EnvironmentObject`: those are only in `ContentView`, `BookReaderWindowView`, `ReaderView`, `LibraryView`, and two settings sections, none reused.
- **`UIViewRepresentable` elements:** VoiceOver talks to the UIKit view directly, so `accessibilityIncrement`, query-time words, and rotors on the element all work (expected). Order is a first-run check.
- **A rotor on the window:** the header promises ancestors, but a SwiftUI node's chain up to the window is undocumented. F20 avoids it.
- **`PhoneSession`:** works with F1, F9, F13, and F34. `init` registers and loads with no window. `close()` is safe to call once. `nextBookWindowSwitcher` stays nil, so `.openANewWindow` follows (`Models/NextBookWindow.swift:139`), as 795 says. `attach(to:)` never runs, and nothing needs it. All of it is main actor, and these notifications are posted on the main thread.

### 2. What misuses an API?

- F5, F6, F7, F8, F24, F25, F28, F32.
- Right as written: `.playback` with `.spokenAudio` and no options; setting the category at launch; `.startsMediaSession` on Play only in the Play state; `usesApplicationAudioSession` left at its default, which the code never sets; `.default` as the announcement priority that can be interrupted; `preferredIntervals` by unit; next and previous track for the AirPods.

### 3. What's underspecified?

- **Holding words back:** F2.
- **`performSkip` and whether a move happened:** it returns nothing (`ReaderViewModel+Navigation.swift:230`). Compare chapter and offset before and after: every path sets them synchronously (`ReaderViewModel+Navigation.swift:659`, `742`, `812`, `923-950`). Call `cancelWhereAmIIfActive()` first, since time-based skips don't, as the brief already has. Keep this in `PhoneReaderModel`, and don't change `performSkip`'s signature.
- **`PhoneControl`:** F15. **`PhonePassagePolicy`:** F16. **`PhoneFocusPolicy` and lists:** F12, F17. **Rows and 8 Hz:** F11. **`lastOpenedBook` and reopening:** F21. **`macOSFixedFrame`, reused sheets:** F3.
- **The flush in `sceneDidEnterBackground`:** on the main thread, inside a background task. `flushPendingWrites` is main-actor work (`UnsavedChangesTermination.swift:187-193`). It waits on the two persistence queues (`LibraryPersistenceService.swift:304`, `314`), and nothing on them waits for the main thread (`LibraryPersistenceService.swift:352-358`). The import queue's `main.sync` (`LibraryViewModel+Import.swift:669`) can't deadlock it, since main never waits for that queue. The cost is one write of about half a megabyte. Log its time. Don't flush at `willResignActive`, or Control Center would flush.

### 7. Is anything in the design wrong?

- **UIKit life cycle:** keep it. The SDK supports it directly, and 43's reasons stand.
- **UIKit controls:** keep them. Line 213 is true: `SwiftUICore`'s traits have `isButton`, `updatesFrequently`, and `startsMediaSession`, and no adjustable (`SwiftUICore.swiftinterface:4932-4943`). SwiftUI does have `.accessibilityAdjustableAction` (SwiftUI interface:1840), so the real reason for UIKit is query-time words and the value read after adjusting, as 210 says.
- **Row instead of bar:** keep it. Nothing in the code argues against it, and it matches the Mac's Continue button.
- **Speech path:** keep it. The evidence for engine-only is one report, and it's check 1. Make sure the first run logs enough to decide.
- **Where the library lives:** keep it. `realHomeDirectory` and `defaultRoot(in:)` are right, `ios/s1-foundation` guards them properly, and `repairStaleFilePaths` heals `filePath` (`LibraryViewModel+Migration.swift:283-339`), with track paths relative (`BookContentAnalysisService.swift:66`).
- **Changes I do argue for:** F1's Now Playing rule, F4's reopening check, F3's rebuilt sheets, and F20's rotors last.

## What the first real run will show, ranked

By likelihood and by how much it hurts. Nothing here is checked by a compile.

1. **Speech stops at the lock, or TextMouth isn't on the lock screen.** It's the spec's check 1, and I'd add Now Playing to it: whether `AVSpeechSynthesizer` output alone makes the app eligible is undocumented. Log every activation's result, the route, and word ticks.
2. **Silence on the next book while locked:** sure without F1.
3. **A crash on opening a book, then at every launch:** F4. Any parser or audio surprise on the new platform reaches this.
4. **A crash when AirPods come out, or on an engine configuration change:** F5, if written the natural way.
5. **A crash at the first natural break, when speech moves to the engine:** F6.
6. **Playing in silence during a call, or after a refused activation:** F7.
7. **"Next sentence" spoken over the book from an AirPods press:** F2.
8. **The navigation unit that won't change, and a removal that takes the Trash path:** F10.
9. **Pause then lock: music doesn't come back, and the app stays awake:** F8.
10. **Rows that speak by themselves when focus rests on the playing book:** F11.
11. **Focus lost on returning to a long list:** F12.
12. **A whole chapter rendered while locked, on a phone.** The render runs at `.userInitiated` (`AudioEngineService.swift:929`). iOS limits CPU use in the background (expected), and a phone heats. Log render time. Check whether the thermal skip should also cover the first render while locked.
13. **Column layout, and flick order.** A `UIButton` sizes itself. The text view needs a height (F16).
14. **The pace of speech:** F35.

**At launch, specifically, I found nothing sure to fail:**

- `getpwuid` is fixed on `ios/s1-foundation`.
- `ensureDirectoryStructure` makes intermediate folders (`TextMouthPaths.swift:399`).
- `Bundle.main` lookups tolerate absence: `BuildIdentity` says "unknown", and `TranscriptCleanupRuleFile` guards.
- No entitlement is needed for background audio.
- Don't add a Data Protection entitlement: files must stay readable while locked.
- `UIApplication.shared` is safe if `PhoneAppModel` is made in `didFinishLaunching`, not in the delegate's `init`, and that also covers background launches, which may not connect a scene first.
- `LibraryViewModel.init` runs the index load and repair on the main thread (`LibraryViewModel.swift:394-408`, `419-460`). At 743 books that's half a megabyte and a few `stat`s per book, nowhere near the launch watchdog (expected). Log the time, and don't move it tonight.

## Which Mac behaviors will silently change?

None, if these hold.

- **Paths, `WatchedProcess`:** safe. `ios/s1-foundation`'s `TextMouthRuntime`, `TextMouthPaths`, and `ImportAudioConverter` edits are all under `#if os(iOS)`, and `WatchedProcess+iOS.swift` isn't compiled on the Mac.
- **`VoiceOverAnnouncer`:** the mapping is inside the existing `#else` (`VoiceOverAnnouncer.swift:119-132`). The collector swaps `poster`, so `announce` doesn't change. Safe.
- **`NowPlayingService`:** keep the Mac's `[30]` and `[15]` (`NowPlayingService.swift:771-777`) outside any iOS branch. Don't add fields to `NowPlayingItem` for the Mac.
- **`SpeechService`, `SleepTimerService`, `PlaybackMemoryGuard`, `AudioEngineService`:** safe if every addition is inside `#if os(iOS)`, including stored properties. `make mac-projection` will show any that isn't.
- **`PlatformControlStyles`:** no change needed, with F3.
- **`project.yml`:** safe. The bundle identifier and plist settings are only in the `TextMouthiOS` stanza (`project.yml:272-296`), and `iOSApp/` is in no target's sources. `regenerate-project.py` compares only copy phases, so it isn't affected. The iOS target copies no licence files, unlike the Mac's (`project.yml:121-153`): harmless tonight, needed before anyone else gets the app.
- **`TextMouth/Phone/`, compiled into the Mac:**
  - `UncheckedConcurrencyPolicyTests` scans every Swift file under `TextMouth/`, with counts pinned at 28 and 15 (`UncheckedConcurrencyPolicyTests.swift:16-19`, `SourceScanTestSupport.swift:20-23`). A new `@unchecked Sendable` or `nonisolated(unsafe)` in either phone folder fails it, and two branches changing the pin will conflict. Tell workers to avoid both.
  - `LogContentPolicyTests` reads the same files, so phone log lines follow its rules.
  - `make check` fails on any Swift warning, in the Phone folder too.
  - `mac-projection.py` counts `TextMouth/Phone/` as Mac code (`mac_compiles`, `mac-projection.py:271-274`), so every new line prints as a real change and could hide a true one. Skip that folder there, and add a scan test: no file outside `TextMouth/Phone/` and `TextMouth/Platform/iOS/` names `Phone[A-Z]` outside `#if os(iOS)`.
  - `a11y-lint.py`'s `DEFAULT_PATHS` leaves out `TextMouth/Phone/` (`a11y-lint.py:42`), where all the words live. Add it, or a hint saying "tap" passes. Its `direct-announcement` rule will flag `PhoneAnnouncer`: add that file to `ANNOUNCER_FILES`.

## The slices

**Order and size.** The order is right, with these changes:

- Share Logs moves from Slice 9 to Slice 1 or 2: 697 itself says a first run can't be diagnosed without it. It's one row.
- F4's check and `PhoneDefaults` go in Slice 1.
- Slice 2 is too large with F3. Move the folder sheets out if a worker is free.

**Conflicts I foresee, and how to avoid them.** Slice 1 is still in progress: when I looked, its branch had no app delegate committed yet, so this is the time. Have it land these, each empty or minimal:

- `TextMouthSceneDelegate.swift`: Slices 3, 6, and 8 all want it, and the brief gives it to 6 while 3 has a "seam" in it. Land `PhoneLifeCycle`, with `didEnterBackground`, `willEnterForeground`, `didBecomeActive`, and `openedFiles`, and closures slices register. The delegate only calls it, and no slice edits the delegate after Slice 1.
- `PhoneRootView.swift`: Slice 2 claims it; 3, 6, and 8 need it. Land one modifier per slice, in its own file (`.phoneImportPresentations`, `.phoneReopening`), so `PhoneRootView` isn't edited again.
- `PhoneSession.swift` and `PhoneAppModel.swift`: Slices 4, 5, and 6 all add to them. Land the stored objects now, and have each slice work in its own extension file (`PhoneSession+Reopening.swift`, `PhoneSession+Audio.swift`).
- `ReaderViewModel.swift` and `ReaderViewModel+Playback.swift`: Slices 4, 5, and 6 each need hooks in the same functions. Land one `#if os(iOS)` property, `phoneHooks`, a struct of closures for moves (F2), `audioMayStart` (F7), and audio-ended for silent gaps, with its call sites. Then the slices fill closures and don't edit those functions.
- `PhoneAnnouncer`, `PhoneFocusPolicy`, `PhoneFocusRegistry`, `PhoneRoute`: used by nearly every slice, and owned by none in the brief. Land them in Slice 1. `PhoneReaderSheet`, the enum Slice 7 fills, goes there too, so 4 and 7 don't wait on each other.
- `SpeechService.swift` and `AudioEngineService.swift`: give them to Slice 5 alone. Slice 6's thermal and memory skips go through a closure in `SpeechRenderCoordinator`.
- `TextMouth.xcodeproj/project.pbxproj`: no worry. `merge-chain.sh:22-23` regenerates on a conflict in it alone.

**If the night were cut short, build in this order:**

1. Slice 1, with the seams above and Share Logs.
2. Open Book alone from Slice 3: one importer, the coordinated copy, and the duplicate question, since without it a duplicate waits for ever. A phone with no book can test nothing.
3. Slice 5's core: category, `audio` mode, activation with F7, interruption, route change, Now Playing's words, and the F1 rule.
4. Slice 4's core: Play, Book content, Navigation unit, Skip, Where Am I?.
5. The background flush from Slice 6.

That's enough for the checks that decide the most (1 to 10). Cut in this order: rotors, Read All, the Library's other views, Slice 7's sheets but Headings, then the rest of Settings.

## What's right

- The principles, and how seriously they take a focused element changing.
- A plain, tested type for each decision. That's the right way to build what can't run tonight.
- `ImportOrigin(window:)` being nil means the phone must present questions itself (`ImportDecisionPresenter.swift:20-22`, `86-87`).
- `.continueToNextBook` and `.openBookWindow` having no listener without the Mac's `AppDelegate` (`AppDelegate.swift:22`).
- M4B needs `runCapturingOutput` to answer "could not start", not throw (`AudioFileInfo.swift:308`, against `WatchedProcess+iOS.swift:115`).
- `performSkip` called directly, without the 0.4-second debounce: the debounce is for a Mac's two paths (`ReaderViewModel+Navigation.swift:167-182`).
- The magic tap on a window, with returning false as the way out. One line more: also implement it on `TextMouthAppDelegate`, which is in the chain too (`UIAccessibility.h:398-403`), as a second home if a sheet's chain misses the window.
- The hand-check list, whose first items are the ones that decide the most.
- Every "Unverified" I checked is honest. Only line 551 can now be settled from a header.
