# The reader on the iPhone
<!-- id: reader-on-iphone; keys: iPhone reader, Book content, Book Actions, Sleep Timer, Go To, skip buttons, long press, VoiceOver order; src: TextMouth/Phone/PhoneReaderState.swift, TextMouth/Phone/PhoneReaderControls.swift, TextMouth/Phone/PhonePassagePolicy.swift, TextMouth/Platform/iOS/Views/Reader/PhoneReaderView.swift -->

Part of [TextMouth's documentation](../../README.md).
The Mac's reader windows are in [Reader windows](reader-windows.md); this page says how the iPhone's reader is laid out and what VoiceOver reads there.

## What VoiceOver passes, in order
<!-- id: iphone-reader-order; keys: swipe order, controls, Book Actions, skips hidden, timer under Play; src: TextMouth/Phone/PhoneReaderState.swift, TextMouth/Platform/iOS/Views/Reader/PhoneReaderView.swift -->

After Back and the title, VoiceOver passes these, one swipe each:

- Book content.
- Skip backward, Play, and Skip forward.
- The Sleep Timer, only while a timer runs: its value is the time left.
- Where Am I?, Navigation unit, and Speed.
- Add bookmark, Bookmarks, and Headings.
- Go To, Return, and Book Actions.

Play is adjustable: swipe up or down on it to move forward or back by the navigation unit, which can be a heading, so the reader has no Previous Heading or Next Heading buttons.
Skip backward and Skip forward make the same moves.
Settings has a switch, Hide skip buttons from VoiceOver, which is off; turn it on and VoiceOver passes over the skips, which stay for touch, Voice Control, and Switch Control.

## Book content
<!-- id: iphone-reader-book-content; keys: text area, highlight, follow, scroll; src: TextMouth/Phone/PhonePassagePolicy.swift, TextMouth/Platform/iOS/Views/Reader/PhoneBookTextView.swift -->

Book content is one element holding the passage at the reading place, so one swipe passes the whole text.
VoiceOver's rotor moves through it by line, word, and character.
It is the main area of the screen, about twelve lines by default (see Settings for the reader, below) and never more than 55% of the height, so Play is on the first screen at any text size.

- The sentence being spoken has a yellow background, for sight; it changes nothing VoiceOver reads and moves no focus.
- While the book plays, the highlight moves with the speech once a second and the text scrolls to keep it in view.
  It holds still while VoiceOver's focus is in the text, unless Follow in Braille is on, and for 5 seconds after you scroll the text with a finger.
- While the book plays, a new passage replaces the text about every 10 seconds, under the same rules.

## Book Actions and the Sleep Timer
<!-- id: iphone-reader-book-actions; keys: menu, Sleep Timer, Reset Timer, Cancel Timer, shake, Search in Book, Voice, focus; src: TextMouth/Phone/PhoneReaderControls.swift, TextMouth/Phone/PhoneControlDescription.swift, TextMouth/Phone/PhoneShakeRestart.swift, TextMouth/Platform/iOS/Views/Reader/PhoneReaderView.swift -->

- Book Actions is a menu: double tap it, then choose Search in Book, Sleep Timer, Voice, Book Info, or Export this book.
  Each opens its sheet, and when the sheet closes, VoiceOver's focus returns to Book Actions.
- While a timer runs, the Sleep Timer shows after Skip forward with the time left.
  Double tap it to open the Sleep Timer sheet, or choose one of its actions first:
  - Reset Timer starts it again at its full length and plays the book, and VoiceOver's focus stays on the control;
  - Cancel Timer stops it, and focus goes to Play.
- When a timer ends by itself, focus goes to Play, not to the top of the screen.
- Within a minute after a timer ends by itself, shaking the iPhone starts the same timer again and plays the book.
  This works anywhere a book is open while TextMouth is in front, and Settings' Shake to restart the timer switch, which is on, turns it off.
  A timer you cancelled is not restarted by a shake.

## Settings for the reader
<!-- id: iphone-reader-settings; keys: Book content height, Short, Medium, Tall, Hide skip buttons, Shake to restart the timer; src: TextMouth/Phone/PhoneBookContentHeight.swift, TextMouth/Phone/PhoneSettingsModel.swift, TextMouth/Phone/PhoneDefaults.swift -->

Settings has three rows for the reader:
- Book content height, Short, Medium, or Tall: about 6, 12, or 18 lines of text, Medium until you choose, and never more than 55% of the screen.
- Hide skip buttons from VoiceOver, under Reading.
- Shake to restart the timer, under Sleep Timer.

## Go To's value
<!-- id: iphone-reader-go-to-value; keys: page, time, Go To; src: TextMouth/Phone/PhoneReaderControls.swift -->

Go To reads the place it would start from, as the sheet's fields do: the page and then the time, as in "Page 112 of 300, 1:02:03".
A book of fewer than two pages leaves the page out, and a book still loading has no value.
VoiceOver reads it when you reach Go To and doesn't announce it as the place moves.

## Changing the voice
<!-- id: iphone-reader-voice-change; keys: voice, Voice sheet, speech restarts; src: TextMouth/Services/SpeechService.swift -->

A voice chosen while the book plays or is paused takes effect at once: speech goes on from the start of the word you were at, in the new voice, and if the book was paused, Play starts there.
