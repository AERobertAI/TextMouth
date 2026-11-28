# The iPhone interface: announcements, text, sheets, and search
<!-- id: phone-interface; keys: iPhone interface, VoiceOver, sheets, phone policies; src:  -->

Part of [TextMouth's architecture](../../ARCHITECTURE.md).

## The announcement priorities on iOS
<!-- id: announcement-priorities-ios; keys: UIAccessibility.post, announcement, speech priority, interrupt, queued speech; src: TextMouth/Services/VoiceOverAnnouncer.swift, TextMouth/Platform/iOS/Services/NSAccessibilityPriorityLevel+iOS.swift, TextMouth/Phone/PhoneAnnouncer.swift, TextMouth/Phone/VoiceOverAnnouncer+Collecting.swift, TextMouth/Phone/PhoneMoveFeedback.swift, TextMouthProductionTests/VoiceOverAnnouncerTests.swift -->

- Apple's header (`UIAccessibilityConstants.h`) says the default priority interrupts existing speech but can itself be interrupted.
  It says the low priority is queued and spoken after other speech has finished.
  - The first draft had these reversed, so every shared high or medium word cut off what VoiceOver was saying.
- `VoiceOverAnnouncer.postThroughAccessibility` now maps the shared priorities on iOS this way:
  - high and medium post at iOS's default priority, so they interrupt;
  - low posts at iOS's low priority, so it waits its turn.
- iOS's own high priority cannot be interrupted once started.
  The shared announcer never posts it.
  `PhoneAnnouncer.important` posts it by a path of its own (`VoiceOverAnnouncer.postToVoiceOver`).
  - In a process hosting tests, `important` goes through the announcer's poster at high priority, so a test reads it.
- `PhoneAnnouncer` is what the phone's own code says to VoiceOver:
  - `say` posts at low, after a delay of 0.15 seconds, so the words follow VoiceOver's own speech about what just changed.
  - `joined` runs several messages into one announcement.
    It adds a full stop to a message that ends in no sentence mark, so the voice pauses, and it returns a lone message as it is.
  - `say(inOrder:)` says a run of messages as one announcement, because a run posted one by one would cut each other off.
  - `combined` joins announcements posted together into one, at the highest priority among them.
  - `important` interrupts at once.
- `VoiceOverAnnouncer.collectingAnnouncements(during:)` returns what a synchronous call announced, instead of posting it.
  A move uses it to sort what it says (`PhoneMoveFeedback`) before anything is heard.
- Words that should follow VoiceOver's speech go through `say`: the sheets' farewell words, a folder's arrival words, and import results.

## Book content: PhonePassagePolicy
<!-- id: phone-passage-policy; keys: page turn, Read All, causesPageTurn, Follow in Braille, Cover chapter, accessibilityScroll; src: TextMouth/Phone/PhonePassagePolicy.swift, TextMouth/Platform/iOS/Views/Reader/PhoneBookTextView.swift, TextMouth/Phone/PhoneReaderControls.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift, TextMouthProductionTests/PhonePassagePolicyTests.swift -->

- `PhonePassagePolicy` decides what passage Book content holds and when it changes.
  It is a plain type, so the Mac's tests cover every rule.
- `placeToShow(chapter:offset:chapterCount:hasWords:)` says where the passage is taken from.
  - If the reading place's chapter has words to say, the passage is taken from that place.
  - If not, it is taken from the start of the next chapter that has words, which is where Play would begin reading.
  - If no chapter from there on has words, the answer is nil, and Book content keeps its stand-in.
- It is needed because a Project Gutenberg EPUB opens at its "Cover", a chapter that is only an image, and Book content was blank there.
  - `hasWords` uses `ReaderViewModel.hasSpeakableText`, which is playback's own rule.
  - The search is `ReaderViewModel.nextSpeakableChapterIndex`, the same forward-only search that playback makes over silent chapters.
  - The Mac's Book content still shows nothing at such a chapter.
    Whether the Mac should do the same is an open question to the user.
- `turnEffect(isPlaying:)` says what a page turn does.
  A page turn comes from the three-finger swipe or from VoiceOver's Read All.
  - Paused, it is `movesPlaceAndText`: the place moves to the new page, then the text shows it.
    Stopping Read All therefore leaves the place where the reading got to.
  - Playing, it is `movesTextOnly`: the book plays on where it is, and only the text moves.
- Read All works through the page-turn trait.
  - `PhoneBookTextView` adds `causesPageTurn` to its traits.
  - At the end of the passage, VoiceOver calls `accessibilityScroll(.next)` and reads on from the next passage.
  - At the book's end the scroll returns false, which ends the reading.
- `changesPassage(on:hasFocus:isPlaying:followsInBraille:)` decides when the text changes.
  A focused text view must not change under a reader, in speech or in braille.
  - A move made while the book plays does not swap the text under a reader who has focus on it, unless Follow in Braille is on.
    Paused, a move always shows.
  - The ten-second tick follows the book only while it plays and Book content has no focus, or Follow in Braille is on.
  - The book loading, focus leaving, and the listener's own request always change it.
- Book content is one accessibility element (FR48), so a swipe passes the whole text; its rotor still moves by line, word, and character.
  - Its timer ticks each second (`followInterval`), and `tickPlan` says what a tick does: it asks for the 10-second refresh when due, and it moves the highlight when the place has moved.
  - The highlight is the sentence at the place (`spokenSentence`), as a background color only: nothing is posted to VoiceOver and no focus moves.
  - `highlightFollows`: it moves, and the text scrolls to it, only while Book content has no focus (or Follow in Braille is on) and not for 5 quiet seconds (`touchQuietInterval`) after a finger scroll; the refresh waits then too.
  - The height is twelve lines at the text size, at most 55% of the reader's scrolling column (`PhoneReaderControls.bookContentHeight`), so Play stays on the first screen and a finger has something outside the text to scroll by.

## PhoneEscapePolicy
<!-- id: phone-escape-policy; keys: two-finger scrub, escape gesture, import question, navigation Back, search field; src: TextMouth/Phone/PhoneEscapePolicy.swift, TextMouth/Platform/iOS/Views/Library/PhoneLibraryView.swift, TextMouth/Platform/iOS/Views/Import/PhoneImportQuestionSheet.swift, TextMouthProductionTests/PhoneEscapePolicyTests.swift -->

- VoiceOver's escape gesture is the two-finger scrub.
  - The system already pops a pushed screen (the reader, a folder) through the navigation stack's Back.
  - It closes a sheet unless the sheet turned off its interactive dismissal.
- The import question turns it off (`interactiveDismissDisabled(true)`), so only an answer settles it.
  A scrub on the question must leave it open.
- A search is the one place where the system does not know what "back" means, so `PhoneEscapePolicy.libraryOutcome(isSearching:isFolderScreen:)` says.
  It returns one of three outcomes:
  - `clearSearch`, if the search field holds text, wherever the screen is.
    The field is emptied and focus goes to it.
  - `goBack`, if the screen is a folder's and no search is in progress.
  - `nothing`, at the top of the Library, which has nowhere to go back to.
- `PhoneLibraryView` attaches it as `.accessibilityAction(.escape)`.

## Error alert, Speech Stopped, preview pause
<!-- id: error-alert-speech-stopped-preview; keys: retry, refusal, Speech Stopped, Preview Voice, voice preview, pause sound; src: TextMouth/Phone/PhoneErrorAlertPlan.swift, TextMouth/Platform/iOS/Views/Reader/PhoneReaderErrorAlert.swift, TextMouth/Platform/iOS/Views/Reader/PhoneSpeechRefusalSheet.swift, TextMouth/Phone/PhoneSpeechRefusalPresentation.swift, TextMouth/Models/SpeechRefusalReport.swift, TextMouth/Phone/PhonePreviewPause.swift, TextMouth/Phone/PhoneSettingsVoicePreview.swift, TextMouth/Phone/PhoneSession.swift -->

- `PhoneErrorAlertPlan` decides what the error alert over the reader shows and does.
  It is the Mac's `ReaderViewModel.ErrorAlert`, with the Mac's buttons.
  - An error that can be retried gets "Retry", or "Try Again" for a chapter that could not be got from the cloud, and "Cancel".
  - An error that cannot be retried gets "OK" alone.
  - Every button closes the alert and forgets the error in the reader.
  - Retry then calls `retryAudioPlayback()` on the next turn of the main queue.
    A retry that fails again can then present a fresh alert, instead of having the closing alert clear its message.
  - `returnsFocusToPlay(errorAlertNow:)` is true only when no alert is showing once the alert has closed, so focus is never taken from a fresh alert.
  - `PhoneReaderErrorAlert` presents the alert from the session's snapshot (`snapshot.errorAlert`), which changes only when the alert comes or goes.
- The Speech Stopped sheet is `PhoneSpeechRefusalSheet`, over the Mac's `SpeechRefusalReport` and `SpeechRefusalWording`.
  Its words say iPhone where the Mac's say Mac.
  - The summary reads "The iPhone's speech engine refused to speak the text here, twice, so speech stopped.
    Play tries again from the same place."
  - The report's device heading is "This iPhone", and its system line starts "iOS:".
  - `SpeechRefusalWording.runsOnPhone` chooses the words, and each function takes an `onPhone` parameter, so the Mac's tests reach both.
  - The sheet has no Show Logs in Finder.
    VoiceOver's order is the heading with what happened, the Details text area, Copy Details, and Close in the toolbar.
  - `PhoneSpeechRefusalPresentation.shows` decides when it shows.
    A screen presents one sheet or alert at a time, so the report waits while a panel sheet, the error alert, or another alert is over the reader.
    It shows as the last of them closes.
- Preview Voice pauses a playing book.
  `PhonePreviewPause.pause` pauses each reader that plays, and returns a closure that plays on the readers it paused, or nil if none was playing.
  - The closure leaves alone a book that plays by then, because a second Play would only restart it.
  - `PhoneSession.pauseBookForPreview` gives it both readers, once each.
    It pauses without the pause sound, since the preview is about to speak.
  - `PhoneSettingsVoicePreview` asks `audioMayStart` first.
    It pauses the book only at the first of a run of previews, and resumes it once, when the last preview ends, is cancelled, is refused by the speech engine, or is stopped.
  - Settings and the reader's Voice sheet both use it.

## PhoneTextStyle: the phone's text at full contrast
<!-- id: phone-text-style; keys: contrast, accessibility audit, Dynamic Type, secondary gray, tint, PhoneTextColor; src: TextMouth/Platform/iOS/Views/PhoneTextStyle.swift, TextMouth/Platform/iOS/Views/Library/PhoneLibraryRowViews.swift, TextMouthiOSTests/PhoneValueRowTests.swift -->

- `TextMouth/Platform/iOS/Views/PhoneTextStyle.swift` holds the colors of the phone's words in one place.
  - The reason is Apple's accessibility audit.
    It finds iOS's secondary gray only "nearly" enough contrast, and the tint a button draws its words in no better.
  - So the phone draws every word in the primary label color, and tells the kinds apart by font, weight, and position.
  - The Library did this first for its rows (`PhoneRowLines`).
    Settings, Headings, Go To, Sleep Timer, Bookmarks, the Voice sheet, Add to Library, Book Information, and the choice sheet use the same style now, with no word changed.
- `PhoneTextColor` names three colors:
  - `secondary`, for captions, details, values, and section headings: the words a design would draw in gray.
  - `primary`, for the words of a button or of a row that is one, which iOS would draw in the tint.
    It is kept apart from `secondary` because a tint fails the audit on its own account, whatever is decided about gray.
  - `disabled`, for words that do nothing now.
    It is `Color.secondary`, the system's gray, so that a dimmed button or row still looks dimmed.
    Whether the audit lets a disabled control's text pass is unverified.
- Two view modifiers apply them: `phoneSecondaryText()` and `phonePrimaryText()`.
  Each draws the color while the control is enabled, and `disabled` while it is not, by reading the `isEnabled` environment value.
  - They name a color outright and not a hierarchical style, because inside a button the hierarchical styles take the button's tint.

### PhoneActionButton and PhoneValueRow
<!-- id: phone-action-button-value-row; keys: LabeledContent, ButtonRole, accessibility text size, VStack, stacking; src: TextMouth/Platform/iOS/Views/PhoneTextStyle.swift, TextMouthiOSTests/PhoneValueRowTests.swift -->

- `PhoneActionButton` is a `Button` whose plain words take `phonePrimaryText()`.
  Use it in place of `Button(title, action:)`.
  VoiceOver reads the same label.
  It takes an optional `ButtonRole`.
- `PhoneValueRow` shows a name and its value in place of `LabeledContent(name, value:)`, whose value iOS draws in gray.
  The name takes `primary` and the value `secondary`.
  - At the accessibility text sizes (`typeSize.isAccessibilitySize`) the value goes under the name, in a `VStack`.
    Side by side, the name broke in the middle of a word beside its value at the largest size ("Fade out duration" in Settings).
  - `PhoneValueRowTests` (`TextMouthiOSTests`, 3 tests) pins the stacking.
    It asks a hosting controller how tall the row is at a width of 300 points and compares that with the name's height, the 4-point gap, and the value's.
    At all five accessibility sizes the row must be the stacked height, to within 1.5 points, and at the seven ordinary sizes it must be shorter.
    Un-stacking the row fails it, and so does always stacking it.
    It was not run against an un-stacked row, and that `LabeledContent` lays out side by side outside a Form is inferred.

### Where the contrast choice stands
<!-- id: where-contrast-choice-stands; keys: humanQuestions, low vision, false positive, audit result, undo; src: TextMouth/Platform/iOS/Views/PhoneTextStyle.swift -->

- The spec has no section on contrast, so `PhoneTextStyle` cites its words on text sizes by their section names, and no longer by numbers: "The layout" of the reader ("At large text sizes, the grid becomes one column and the screen scrolls") and "A book's row" ("What's visible").
- Full contrast for all of the phone's text follows the recommended answer to question 2 of section 6 in `humanQuestions/2026-11-08.md`.
  The user has not answered.
  Until they do, the work follows the recommendation: yes, for people with low vision.
- To undo it, make one line say `static let secondary = Color.secondary` in `PhoneTextColor`.
  Button words stay at full contrast, since `primary` is a separate line.
- The contrast result: the audit's findings of contrast fell from about 50 to 2 on the sheets tested.
  Both remaining ones are on the first section header under the bar ("Voice" in Settings, "New Timer" in Sleep Timer).
  They are false positives, proven from the screenshots: the pixels over each header's frame are black (0, 0, 0) on (235 to 242, 235 to 242, 240 to 247), about 17 to 1.
  Nothing switched off cleared them (the header trait, sliders, switches, steppers, the field).
  The audit accepts them by the header's label and the contrast kind only (see [The audit and its accepted findings](../developer/testing-iphone-audit.md)).

## PhoneSheetButton: where a sheet's buttons go
<!-- id: phone-sheet-button; keys: toolbar, topBarTrailing, cancellationAction, confirmationAction, ToolbarContent, button order; src: TextMouth/Platform/iOS/Views/PhoneSheetButton.swift, TextMouth/Platform/iOS/Views/Reader/PhoneReaderSheetContent.swift, TextMouth/Platform/iOS/Views/PhoneTextStyle.swift, TextMouth/Platform/iOS/Views/PhoneChoiceSheet.swift, TextMouth/Platform/iOS/Views/Library/PhoneBookInfoSheet.swift, TextMouth/Platform/iOS/Views/Library/PhoneFolderSheetForm.swift, TextMouth/Platform/iOS/Views/Library/PhoneFolderDeleteSheet.swift, TextMouth/Platform/iOS/Views/Import/PhoneAddToLibrarySheet.swift, TextMouth/Platform/iOS/Views/Reader/PhoneSpeechRefusalSheet.swift, TextMouth/Platform/iOS/Views/Reader/PhoneGoToSheet.swift, TextMouth/Platform/iOS/Views/Reader/PhoneHeadingsSheet.swift, TextMouth/Platform/iOS/Views/Reader/PhoneSleepTimerSheet.swift, TextMouth/Platform/iOS/Views/Reader/PhoneVoiceSheet.swift, TextMouth/Platform/iOS/Views/Reader/PhoneBookmarksSheet.swift -->

- `TextMouth/Platform/iOS/Views/PhoneSheetButton.swift` holds `PhoneSheetButtonPlacement` and `PhoneSheetButton`.
  Every sheet's Cancel, Close, Done, Save, and Back to Book comes from it, and no sheet places one itself.
  - The sheets: Book Information (and its loading state), the choice sheet, both folder sheets (the form and Delete Folder), the stand-in sheet for a panel not built yet (`PhoneUnbuiltSheet`), Speech Stopped, Go To, Headings, Sleep Timer, Voice, Bookmarks, and Add to Library.
- `PhoneSheetButtonPlacement.placement` is the one place the placement is decided.
  It is `.topBarTrailing`.
  Changing it back is one line.
- A `PhoneSheetButton` is a `ToolbarContent`, used in a `.toolbar` in place of a `ToolbarItem` with a `Button`.
  It takes:
  - `title`, the button's words, drawn at full contrast through `PhoneActionButton`;
  - `label`, what VoiceOver and braille call it when that is not the title, and the title if none is given;
  - `hint`, which is none by default;
  - `isEnabled`, which is true by default, and a button that is not enabled is dimmed;
  - the `action`.
- The order is the title, then Cancel (or Close, or Done), then the confirming button.
  VoiceOver reads the title, then Cancel, then the confirm button, as the spec orders them.
  - A sheet lists its Cancel before its confirm button in its toolbar, and the trailing placement keeps that order.
  - The two folder sheets had Cancel before the title.
    They follow the spec now.
- Why not the system's places, `.cancellationAction` and `.confirmationAction`:
  - In the simulator's tests (iPhone 17, iOS 26), Book Information's and the choice sheet's Cancel were reported missing, though Go To's, in `.topBarTrailing`, was found.
  - A probe test put the buttons back in `.cancellationAction` and read the sheet's tree.
    The probe was removed in 0.4.3, with its test and its launch variable.
    `PhoneSheetButton.swift`'s comment keeps the history, and it is accurate.
    The buttons were never missing.
    They were ordinary buttons labeled "Cancel" and "Save", with no identifier, drawn as text pills 66 and 51 points wide, and not as an xmark or "Close".
  - What was wrong was their order.
    Those places are the bar's leading side, so the accessibility tree read "Cancel, Save, Book Information", with the buttons before the title.
    The tests read a sheet from its title on, so they found no Cancel after it.
    The earlier reports of a missing Cancel were an order problem.
  - Limit: the probe gave the buttons explicit labels, so the unlabeled case was not observed.
    This is written in the helper's comment.
- `PhoneSheetButtonPlacement` has no probe: no launch variable changes the placement, and `placement` is a computed property, `.topBarTrailing`, since `ToolbarItemPlacement` is not `Sendable` and a stored one is not concurrency-safe.
- Not verified: the order on a phone with VoiceOver, since VoiceOver does not run in the simulator.
  The simulator's tree is what the tests read.
- A related fix from the same round: a `Slider` in the Voice sheet is labeled by its label closure alone.
  A `.accessibilityLabel` on top of it made VoiceOver read "Speed, Speed", so the extra modifier was removed.

## Book Actions, the timer control, and the skips
<!-- id: phone-book-actions-timer; keys: FR49, FR50, FR51, FR52, long press, triple tap, Go To value, focusTarget; src: TextMouth/Phone/PhoneReaderState.swift, TextMouth/Phone/PhoneReaderControls.swift, TextMouth/Phone/PhoneControlDescription.swift, TextMouth/Platform/iOS/Views/Reader/PhoneReaderView.swift, TextMouth/Platform/iOS/Views/Reader/PhoneControl.swift, TextMouthProductionTests/PhoneReaderControlsTests.swift -->

- Book Actions (`PhoneReaderControl.bookActions`) is a menu button at the end of the fourth row, holding `bookActionItems`: Sleep Timer, Voice, Book Info, and Export this book.
  - The items are made as the menu opens (`PhoneControl.setMenuItems`), and each opens its old sheet.
  - Focus returns to Book Actions as the sheet closes, since the item's own button isn't on screen.
- While a sleep timer runs, the Sleep Timer shows under Play (`PhoneReaderControl.screen(timerRuns:)`), its value the time left, redrawn each second for sight alone.
  `PhoneSleepTimerWatcher` republishes only when the timer starts or ends.
  - `focusTarget(returningTo:timerRuns:)` sends focus to Play when the control it names has left the screen, as when the timer ends under VoiceOver's focus.
- Play has a long press, which is VoiceOver's one-finger triple tap, and a Sleep Timer action; both open the Sleep Timer sheet with focus returning to Play.
- Skip backward and Skip forward are hidden from VoiceOver only while it runs (`isHiddenFromVoiceOver`, `voiceOverOrder`), since adjusting Play makes the same moves.
  They stay for touch, Voice Control, Switch Control, and the shortcuts.
- Go To's value is the page at the place and the time there (`goToValue`: "Page 112 of 300, 1:02:03"), read when VoiceOver asks and never announced as it changes.

## Search in Book
<!-- id: search-book; keys: reader controls, control grid, VoiceOver order, openSearch, gridRows; src: TextMouth/Phone/PhoneReaderState.swift, TextMouth/Phone/PhoneReaderControls.swift, TextMouth/Phone/PhoneReaderModel.swift, TextMouth/Phone/PhoneBookSearch.swift, TextMouth/Phone/PhoneLaunchRequest.swift, TextMouth/Platform/iOS/Views/Reader/PhoneReaderView.swift, TextMouth/ViewModels/ReaderViewModel+Bookmarks.swift, TextMouthProductionTests/PhoneReaderControlsTests.swift -->

- The reader's eleventh control, `PhoneReaderControl.searchInBook` (the ninth of the 14 in `PhoneReaderControl.grid`), comes after Headings and before Go To in VoiceOver's order.
  Its label is "Search in Book", the Mac's command (`ShortcutAction.searchInBook.title`), and its hint is "Opens a search of the book's text."
  (`PhoneBookSearchVocabulary`).
  It opens `PhoneReaderSheet.search`.
- `PhoneReaderModel.openSearch()` decides whether it opens, and returns true only when the book has text to search (`ReaderViewModel.canSearchText`).
  - While the book loads, it says "Loading TITLE" with medium priority and opens nothing.
  - For an audiobook with no transcript text, it says why, in the Mac's words (`ReaderViewModel.announceNoTextToSearch`), and opens nothing.
  - For a text book that failed to load, it says nothing: that screen shows the failure in place of the controls.
- The grid has five rows (`PhoneReaderControl.gridRows`), and `grid` is their concatenation, so VoiceOver's order is the same however the rows break:
  - Where Am I?, Navigation unit, Speed;
  - Previous Heading, Next Heading, Add bookmark;
  - Bookmarks, Headings, Search in Book;
  - Go To, Return, Book Actions;
  - Skip backward, Skip forward.
- A plain three to a row would split the skips, so each pair stays together and the two skips are the last row, as in the spec.
  - `testTheGridRowsKeepOrderAndPairs` pins the order, at most three to a row, the three groups, and the last row.
    It does not pin the exact rows.

### The search sheet and its typing pause
<!-- id: search-sheet-typing-pause; keys: debounce, typing pause, Braille Screen Input, BookSearchModel, status line, regular expression; src: TextMouth/Platform/iOS/Views/Reader/PhoneSearchSheet.swift, TextMouth/Phone/PhoneBookSearch.swift, TextMouth/ViewModels/BookSearchModel.swift, TextMouth/Views/Reader/BookSearchView.swift, TextMouthProductionTests/PhoneBookSearchTests.swift, TextMouthProductionTests/BookSearchModelTests.swift -->

- The sheet is `PhoneSearchSheet` (`Platform/iOS/Views/Reader/`), thin over `PhoneBookSearchSource` and over the Mac's `BookSearchModel` and `BookSearchEngine`.
  - VoiceOver's order is the title, Back to Book, the field, the status line, the regular-expression switch, a "Search results" heading, and then the results in the order they lie in the book.
  - The Mac's words are shared through `BookSearchWording` (`Views/Reader/BookSearchView.swift`): the field's label "Search text" and its two hints, the switch's label "Use regular expression" and its hint, the "Search results" label, and Back to Book's hint "Close search and return to the book".
    The Mac's sheet reads them from there too, with the values unchanged.
  - Only what the phone adds is in `PhoneBookSearchVocabulary`: the button's hint, a result row's hint "Goes to this result."
    (the Mac's "Activate to navigate to this result" names a gesture), and the typing pause.
  - A text book's results say where the match is as a percent, the Mac's default.
    There is no Display picker, and there is no clear-search button.
  - Focus lands in the field 0.35 seconds after the sheet opens, unless VoiceOver has landed on a reader control meanwhile (the tickets, below).
  - The field turns off capital letters and correction, so the listener's text goes in as typed.
- A search waits for typing to pause for one second (`PhoneBookSearchVocabulary.typingPause`), as the Library's search does, so that a listener typing with a braille display or Braille Screen Input is not told "No matches" between letters.
  The Mac waits a quarter second.
  - `BookSearchModel` has a `debounceInterval` parameter for it, `init(corpus:debounceInterval:announce:)`.
    `BookSearchModel.debounceInterval` is the default, 250 milliseconds, so the Mac's one call passes none and behaves as before.
  - `PhoneBookSearchSource.makeModel(announce:)` passes the phone's second.
  - `testNothingIsSaidUntilTypingHasPausedForASecond` sets the query, waits 0.6 seconds, and requires that the status is still "Searching…" with nothing said.
    It would fail at 250 milliseconds.
  - Each completed search says its status once, with low priority (`PhoneAnnouncer`), so typing is never cut off.
    The status line holds the same words for anyone who flicks to it.

### Going to a result, and the phone's words
<!-- id: going-result-phone-words; keys: transcript jump, Return place, farewell, noTextToSearch, offersTranscription, isTranscribable; src: TextMouth/ViewModels/ReaderViewModel+Bookmarks.swift, TextMouth/Phone/PhoneReaderModel.swift, TextMouth/Views/Reader/BookSearchView.swift, TextMouth/Platform/iOS/Views/Reader/PhoneSearchSheet.swift, TextMouthProductionTests/PhoneReaderModelTests.swift -->

- A result goes to its place with `ReaderViewModel.goToSearchResult(chapterIndex:characterOffset:inTranscript:)`, which the Mac's sheet now calls too, so one place decides the move.
  A transcript's result moves the audio to the start of the sentence holding the match, and any other book's moves the place to the match.
  - The Return place is kept, the sheet closes, and the session counts the book as opened (`PhoneReaderModel.noteJumped`).
  - What the jump says is collected and said after the sheet has closed (`PhoneSheetFarewell`).
    A transcript jump says "Moved to TIME, HEADING."
    (`BookSearchWording.movedTo(time:location:)`), and a text book's jump says nothing beyond what the reader says, as on the Mac.
    It plays on from the result if Auto-play after navigation is on.
  - Back to Book, and the sheet disappearing any other way, stop a search still running (`cancelSearch()`), so nothing is said for a sheet that is gone.
- `offersTranscription` is a parameter of `BookSearchWording.noTextToSearch` and `ReaderViewModel.announceNoTextToSearch`, true by default.
  The phone cannot transcribe, so `openSearch()` passes false.
  - An audiobook with no transcript hears "TITLE has no transcript to search." and not the Mac's "Transcribe it first, with Transcribe Audio."
  - A stale transcript hears its reason without "Transcribe it again, then search the new transcript."
  - Two tests in `PhoneReaderModelTests` pin it: a packaged audiobook that `isTranscribable` must not mention "ranscribe" on the phone, and the Mac's words must still name the command.
  - The phone's words for a held edit still mention "your editor" and "content.md".
    The phone cannot hold an edit, so this is a follow-up only.

### Focus requests and their tickets
<!-- id: focus-requests-their-tickets; keys: focus ticket, VoiceOver focus, sheet close, focus return, 0.35 seconds; src: TextMouth/Phone/PhoneFocusRequests.swift, TextMouth/Phone/PhoneFocusPolicy.swift, TextMouth/Platform/iOS/Views/PhoneFocusRegistry.swift, TextMouth/Platform/iOS/Views/Reader/PhoneSearchSheet.swift, TextMouthProductionTests/PhoneFocusRequestsTests.swift -->

- The focus requests are `PhoneFocusRequests` (`Phone/PhoneFocusRequests.swift`), a plain value with no clock, which the Mac's tests drive by calls alone, and `PhoneFocusRegistry` (`Platform/iOS/Views/`), which observes VoiceOver's landings.
  - A request that waits 0.35 seconds takes a ticket (`request()`, through `PhoneFocusRegistry.beginRequest()`), and asks for it back when its time comes (`claim(_:)`, through `claimRequest(_:)`).
    It posts only if the ticket is still good.
  - VoiceOver landing on any of the reader's controls (`PhoneControlKind`) spends every ticket still waiting, since that is the listener's own move (`focusLanded(on:)`).
  - A landing on Back or the title cancels nothing.
    The spec said "Any focus event cancels a request still waiting", and now says what the code does.
    `PhoneFocusPolicy` already exempted those two, and cancelling on them could stop focus from ever returning after a sheet closes.
    This needs a phone to check.
  - The sheet's focus into its field, the alert's and Speech Stopped's returns, and a sheet's return to its control all go through the tickets.
    The Library's list-focus helper is not wired to them.
  - `PhoneFocusRequestsTests` has six cases, including every kind of control, so a control whose landing fails to cancel is named.
    Nothing tests the iOS posting path.
  - Unverified: whether VoiceOver lands on another reader control by itself as a sheet finishes closing.
    If it does, the return of focus is cancelled by VoiceOver rather than the listener.

### Closing one reader, and where tests are
<!-- id: closing-one-reader-where-tests; keys: closeBook, Remove from Library, Now Playing, leaveReader, testing; src: TextMouth/Phone/PhoneSession.swift, TextMouth/Platform/iOS/Views/Library/PhoneLibraryView.swift, TextMouthProductionTests/PhoneSessionTests.swift -->

- `PhoneSession.closeBook(id:)` closes only that book's reader.
  A book on screen with another behind it hands the screen to the one behind, as Back does (`leaveReader`), and a book that is not open does nothing.
  The Library's Remove calls it (`PhoneLibraryView`), so removing the book that plays behind the screen no longer stops the other.
  - `PhoneSessionTests` pin four cases: the book behind, the book on screen, the only book, and a book not open.
  - The on-screen case also checks which reader Now Playing follows, but with only two readers it passes with or without the hand-over, so it does not prove it.
    A third reader would.
- The tests are in [Testing the iPhone app](../developer/testing-iphone.md).

## The Export sheet
<!-- id: the-export-sheet; keys: PhoneExportSheet, PhoneExportOffer, PhoneBrailleExportRows, PhoneExportQuestion, PhoneExportFolder, Export this book, FR31, fileImporter; src: TextMouth/Platform/iOS/Views/Export/PhoneExportSheet.swift, TextMouth/Platform/iOS/Views/Export/PhoneBrailleExportRows.swift, TextMouth/Phone/PhoneExportOffer.swift, TextMouth/Phone/PhoneExportFolder.swift, TextMouth/Phone/PhoneExportQuestion.swift, TextMouth/Phone/PhoneLibraryOffer.swift, TextMouth/Platform/iOS/Views/Library/PhoneLibraryView.swift, TextMouth/Platform/iOS/Views/Reader/PhoneReaderSheetContent.swift, TextMouthiOSTests/PhoneExportSheetTests.swift, TextMouthiOSUITests/ExportUITests.swift -->

Export on the iPhone (FR31, phase 1) is the shared `BookExportModel` under a sheet of its own; the model's hooks, the delivery, and the memory check are in [Exports on the iPhone](state/exports-iphone.md).

- Two entry points open it:
  - `PhoneLibraryOffer`'s `.export` command, "Export…" (`BookExportWording.commandTitle(count: 1)`), in a book's row after Move to Folder... as on the Mac;
  - `PhoneReaderControl.export`, "Export this book", an item of Book Actions, which opens `PhoneReaderSheet.export` over the reader, so a speech refusal's report waits for it to close.
- `PhoneExportSheet` is a `NavigationStack` over one `List`, its buttons placed by `PhoneSheetButton`.
  What it offers and says at each stage is decided in plain types the Mac's host tests: `PhoneExportOffer.kinds` (every kind), `Stage`, `content(stage:kindCount:)`, the `Bar`, the Stop row, the spoken audio and braille rows, `shareButton`, the card, and `folderRow(folderName:)`.
  The bar is Cancel, or Stop while exporting, or Close, then Export; Close takes Stop's place while the spoken audio file is made, and Export is dimmed while another export runs.
  Every word is the Mac's (`BookExportWording`), except the memory sentence (`PhoneExportWording`).
- Focus lands on the first kind `PhoneFocusPolicy.screenChangedDelay` after the books are listed.
  It returns to the opener after a Convert to list, the folder picker, or an alert closes (`returnFocus(to:)`, with `@AccessibilityFocusState`).
  When the Stop row or the progress row goes, focus moves to the progress row while the export goes on, or to the end's words once it has ended; the move picks its row when it fires, since a quick file after the audio can end the export within the wait.
- The folder row opens `fileImporter` for a folder, and `onCancellation` returns focus to the row, since a cancel never reaches `onCompletion`.
  `PhoneExportFolder.keep(_:in:)` keeps the choice (see [Exports on the iPhone](state/exports-iphone.md)).
- While an export runs the sheet has `interactiveDismissDisabled`.
  While the spoken audio file is made it may be dismissed, and then goes on as a card in the Library (see [Exports on the iPhone](state/exports-iphone.md)).
  The accessibility escape action, on the whole sheet and not the list, presses Stop while an export runs and otherwise closes the sheet.
  Every options choice (braille's and spoken audio's) is presented from the sheet's list, never from a row, since a row that scrolls away takes its presenter with it.
  The sheet stays open after an export ends and shows the model's `finishedWords`.
- `PhoneBrailleExportRows` draws the braille rows while BRF or PEF is chosen, over the writer's options through `TextExportOptionsEditing.brailleOptions`.
  The braille code is one choice row over the Braille setting's grouped list given `BrailleTableCatalog.exportCodes`, so print-only tables are offered.
  The cells and lines are steppers, each one adjustable element that says its value.
- `PhoneExportQuestion` is the iPhone's `ExportDeepChapterAlert`: an alert whose message says what each button does, since an iOS alert's buttons have no hints, with Export as Written the default and Cancel Export the cancel role.
- Tests:
  - on the Mac's host, `PhoneExportOfferTests`, `PhoneExportFolderTests`, `PhoneExportQuestionTests`, and `PhoneExportModelTests`;
  - in the iPhone's unit bundle, `PhoneExportSheetTests` and `PhoneBrailleExportOptionsTests`;
  - on GitHub, `ExportUITests` (see [Testing the iPhone app](../developer/testing-iphone.md)).

## What is left
<!-- id: what-left; keys: phase 1, typecheck-ios, hand check, bundle identifier, open items; src: TextMouth/Platform/PlatformApplication.swift, Makefile, Scripts/ios/typecheck.py, Scripts/ios/mac-projection.py, project.yml -->

- These are not done: the rotors on Play, Book content's language, the Files drop folder, and sounds.
  [The audit and its accepted findings](../developer/testing-iphone-audit.md) lists the audit findings that are still open.
- Phase 1 left these places empty or approximate, and the first run has not settled them:
  - the Shortcuts recorder, hardware keys, and menus, which compile but are untested on iOS;
  - a recording backend, if recording comes to iOS;
  - a writer for the EPUB metadata, which needs a serializer and a decision on whether to match Foundation's output;
  - the window passed through shared code, which is nil on iOS, since `PlatformApplication` names no key or main window.
- The iOS app has a bundle identifier of its own, `com.textmouth.TextMouth.iOS`, so the question phase 0 left open is settled.
- Everything that sounds or needs VoiceOver can be checked only on a phone, with the spec's hand-check list.
- A change to shared code has a second check.
  Compile it for iOS with `make typecheck-ios`, and show it leaves the Mac as it was with `make mac-projection`, besides the hosted test suite, which tests the Mac only.
  The type-checks do not compile tests (see [Testing the iPhone app](../developer/testing-iphone.md)).
  Count the AppKit uses left by compiling, not by searching for `import AppKit`: SwiftUI brings AppKit's names in, and a file that imports it without using it shows no census error, so check strict mode or list the bare imports before calling the census done.

## What the iPhone's import refuses
<!-- id: iphone-import-refusals; keys: PhoneImportRefusal, convertedAudio, PhoneImportWording, tracksLeftOut, refuseConversion, copy protection; src: TextMouth/Phone/PhoneImportRefusal.swift, TextMouth/Phone/PhoneImportWording.swift, TextMouth/Services/FileImportService+AudioConversion.swift; status: incomplete; issues: FMT55 -->

- PhoneImportRefusal is thrown only on iOS (`#if os(iOS)`), where the Mac would start a program or, for TextMouth's own audio readers, still converts: FileImportService.convertImportedAudio finds the tracks the import converts and refuses them by kind.
  - `.convertedAudio` for what afconvert converts (Ogg, AC-3, CAF, and the rest).
  - The files TextMouth's own readers decode (TTA, WavPack, Monkey's Audio) are no longer refused: `isReadByOwnReader` lets one through by its bytes, or by its name when its bytes are of no format the import converts, and the plist offers their types.
    An Ogg file named .tta is still refused as Ogg, and a file of no format named so fails in the converter as unreadable, as on the Mac.
  - The files only FFmpeg reads are no longer refused: the iPhone converts them in the app (FMT54).
    `refuseConversion` throws `FFmpegAudioConverter.Failure.copyProtected`, the Mac's own sentence, first for a copy-protected one, under the conversion's step, before it refuses another file for its kind.
    Ogg and the formats the Mac converts with afconvert are FMT55.
  - `.wordSixOrNinetyFive` for the format that needs textutil.
  - `.macBrailleTable` for a braille book that needs one of a Mac's own tables that the iPhone's pack has no table of the same file name for, thrown by BrailleBookReader.markdown before anything is read.
    The iPhone reads other braille books itself, a Mac's `mac:<file>` with the pack's table of that name (see [The translator on the iPhone](state/imports-braille-tables.md#the-translator-on-the-iphone)).
- A folder, ZIP, or playlist leaves out a file named like one only FFmpeg reads whose bytes are of none, with the Mac's notice (`FFmpegImportWording.tracksLeftOutNotice`), and refuses what is left that needs converting.
  The iPhone's converter is never missing, so it leaves out no file for that.
