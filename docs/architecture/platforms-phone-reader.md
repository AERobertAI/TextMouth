# The iPhone reader's controls: Book Actions, the timer, and the skips
<!-- id: phone-reader-controls; keys: iPhone reader, controls, VoiceOver order, FR54, FR55; src: TextMouth/Phone/PhoneReaderState.swift -->

Part of [TextMouth's architecture](../../ARCHITECTURE.md).
The rest of the iPhone interface is in [The iPhone interface: announcements, text, sheets, and search](platforms-phone-interface.md); what VoiceOver reads here is in [The reader on the iPhone](../user/reader-on-iphone.md).

## Book Actions, the timer control, and the skips
<!-- id: phone-book-actions-timer; keys: FR54, FR55, Book Actions, Sleep Timer, Reset Timer, skips, focusTarget, playRow; src: TextMouth/Phone/PhoneReaderState.swift, TextMouth/Phone/PhoneReaderControls.swift, TextMouth/Phone/PhoneControlDescription.swift, TextMouth/Phone/PhoneReaderModel.swift, TextMouth/Phone/PhoneSleepTimerWatcher.swift, TextMouth/Platform/iOS/Views/Reader/PhoneReaderView.swift, TextMouth/Platform/iOS/Views/Reader/PhoneControl.swift, TextMouthProductionTests/PhoneReaderControlsTests.swift, TextMouthProductionTests/PhoneReaderModelTests.swift -->

- Play's row is Skip backward, Play, Skip forward (`PhoneReaderControl.playRow`), left to right and in VoiceOver's order.
  - Play is adjustable (`PhoneControlAdjustment.move`: up moves forward by the navigation unit, down back) and offers no actions.
  - The skips are hidden from VoiceOver only while Settings' "Hide skip buttons from VoiceOver" is on, which it is not by default (`isHiddenFromVoiceOver(hidingSkips:)`, `voiceOverOrder`).
    They stay for touch, Voice Control, Switch Control, and the shortcuts.
- Previous Heading and Next Heading are gone for everyone, since Play adjusted by the heading unit makes their moves.
- Book Actions (`PhoneReaderControl.bookActions`) is a menu button at the end of the last row of the grid, holding `bookActionItems`: Search in Book, Sleep Timer, Voice, Book Info, and Export this book.
  - Search in Book is no longer on the grid; the menu is the iPhone's counterpart of the Mac's toolbar.
  - The items are made as the menu opens (`PhoneControl.setMenuItems`), and each opens its sheet.
  - Focus returns to Book Actions as the sheet closes, since the item's own button isn't on screen.
- While a sleep timer runs, the Sleep Timer shows under Play (`PhoneReaderControl.screen(timerRuns:)`), its value the time left, redrawn each second for sight alone.
  `PhoneSleepTimerWatcher` republishes only when the timer starts or ends.
  - Its custom actions are Reset Timer and Cancel Timer (`PhoneControlAction.resetSleepTimer`, `.cancelSleepTimer`), and a double tap with none picked opens the Sleep Timer sheet.
  - `PhoneReaderModel.perform(_:)` is the one place an action is tied to what it does, so the Mac's test host checks it.
  - Reset Timer starts the timer again at its full length and plays the book; the Mac's "Timer reset" words come a moment later, since VoiceOver reads nothing after an action.
    A restart stops the timer for an instant, so the watcher skips its move to Play when a timer runs again by then, and focus stays on the control.
  - Cancel Timer says the Mac's cancel words once, and focus goes to Play.
  - `focusTarget(returningTo:timerRuns:)` sends focus to Play whenever the control it names has left the screen, as when a timer ends under VoiceOver's focus.
- A shake restarts a timer that ended by itself (`PhoneShakeRestart`, FR55): within 60 seconds of `SleepTimerService.endedByItselfAt`, which an expiry, a heading end, and a chapter end set, a new timer clears, and a cancel never sets.
  - `MagicTapWindow.motionEnded` takes the shake wherever a book is open and the app is in front; UIKit tells no app in the background, and nothing polls the motion sensors.
  - Settings' "Shake to restart the timer" turns it off, and it is on by default.
- Book content's height is Settings' Short, Medium, or Tall (`PhoneBookContentHeight`: 6, 12, or 18 lines, Medium by default), never more than `PhoneReaderControls.bookContentShareOfScreen` of the screen, so Play shows below it.
- Go To's value is the page at the place and the time there (`goToValue`: "Page 112 of 300, 1:02:03"), read when VoiceOver asks and never announced as it changes.
