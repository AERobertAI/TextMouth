# TextMouth for iPhone: the spec, reviewed as its reader

Reviewed: `IOS-INTERFACE-SPEC-2026-11-07.md` at commit aa8a55d8, whole and in order, with the Mac's user pages and the Mac code the spec reuses.

Nothing has run. What I say VoiceOver does comes from knowing it, so treat each as a prediction for the hand-check list. What I looked up is under "Sources". Counts use the spec's own order: a flick, double-tap, twist, or four-finger tap is one gesture, and typing is one per key at best.

## The verdict

- The design is the right one: land on Play, magic tap from anywhere, swipe on Play to move, the text one flick left, one gesture the next morning. I'd use this app.
- Two things stop me on the first day: search at the Library's top doesn't reach books in folders (4), and nothing says how my library reaches the phone (8).
- Three things I'd curse daily: reading by braille never moves my place (1), next heading has no good path and its rotor throws focus off Play (2), and a mistaken double-tap on a row stops my book (3).
- The magic tap and adjust story is the one I want. The rotor story isn't yet.

## What hurts, worst first

### 1. Reading by braille never moves my place

- Where: "3. Book content", "What's deferred". Tasks 9 and 7.
- Paused, I flick left and pan through three paragraphs, then go back and activate Play. The book speaks those three paragraphs again, from the old sentence. "Go on listening from there" doesn't exist.
- The text ends at 20,000 characters or the chapter's end. Only Read All's page turn goes on from there, and the spec calls that "the first thing to cut", while calling this element "how a braille reader reads the book".
- Nothing before the place is there, so I can't pan back one sentence.
- My braille place is kept nowhere. After Auto-Lock (the spec never mentions the idle timer), a call, or a flick away, I'm back at the passage's first word. That's the app losing my place.
- Instead, in the first version:
  - Paused, activating Book content is Listen from Here: the place moves to VoiceOver's cursor, the Return place is kept, and the book plays. Its hint says so, and it adds no "Actions available". A first run must show whether a selectable text view's `selectedTextRange` follows VoiceOver's cursor or a router key. If it doesn't, a sentence rotor of the app's own on the text view tells the app which sentence I'm on, since a rotor can return a range in a `UITextInput`.
  - Playing, activating it brings the text to the sentence being spoken: a Follow in Braille by hand, with nothing moving until I ask.
  - Paging apart from Read All, and never on the cut list: `accessibilityScroll` gives the next or previous passage, across chapters, by Apple's "Scroll down one page" (a three-finger swipe, or Dots 1-4-5-6 with Space), and moves the place while paused.
  - The screen stays awake while Book content has focus.

### 2. Next heading has no good path, and its rotor throws focus off Play

- Where: "The rotors", "What a move says". Tasks 2 and 4.
- "The result names the Where Am I? element." VoiceOver goes to the element a rotor returns, and reads it. So a flick down on Headings, with the book playing, takes focus off Play and says "Where Am I?, Page 112 of 300, 30.0% through the book, 3 hours remaining at current speed, button" over the book. That breaks principles 1 and 2, and "the rotor flick says what a move says" can't be true.
- I'm now five flicks from Play, on a button whose double-tap pauses the book and starts a speech.
- Rotors on every element also mean that with the rotor left on Headings, a flick down on Book content, meant for the next line, moves the book.
- Without the rotor, next heading is 6 gestures and leaves my unit on Heading, with 5 more to put it back. Through the sheet it's worse (7). On the Mac it's one key.
- Instead:
  - Set the rotors on Play alone, and return Play, by the fresh object the spec already names. Never another control. If that can't be silent, cut the rotors.
  - Since that's unverified, give headings a sure path: two plain buttons, "Previous heading" and "Next heading" (5). Focus stays, a second double-tap goes on, and my unit stays Sentence.

### 3. A mistaken double-tap on a row stops my book

- Where: "The decision", open question 6. Task 13.
- Browsing with the book playing, I double-tap the wrong row. My book stops at once. VoiceOver says "Play, button, adjustable" and no title, so I don't know what I opened.
- Back lands on the wrong row, and the Continue row now names the wrong book. If my book lives in another folder, getting to it is 10 gestures or more, through Recently Opened or search.
- The wrong book has lost "New", left Unopened, and joined Recently Opened, for good.
- Instead:
  - The first book plays on until Play is pressed in the second. Back drops the second, and the first is still "Now Playing". The Mac's readers already live side by side. Podcast apps work this way: a row opens a page, and what's playing goes on until you press Play.
  - The magic tap pauses whatever is audible, and from silence plays the book on screen.
  - A book counts as opened at Play, not at the row.
  - Say the title with low priority at every open, not only a cold reopen.

### 4. Search at the Library's top doesn't reach books in folders

- Where: "The Library's top", item 4. Task 1.
- The spec doesn't say what it searches. The model's `displayedBooks(at:matching:)` narrows the books listed at the location, and in Folders that's `booksInFolder`, the books directly in the folder shown. At the top of a library kept in folders, I type a title I own and hear "No books match."
- The way round is All Items, then search: about 22 gestures against 12, and the Library stays on All Items.
- Unsaid: whether the Continue, Library view, and Sort rows stay among the results; the flicks from the field to the first result; what a two-finger scrub does while searching; whether the search and the keyboard are still there when I come back from a result.
- Instead:
  - Search from any Library screen covers the whole library: title, author, and folder name, with folder rows among the results. It departs from the Mac, so it's a question for the user.
  - Results are the list: field, Cancel, first row. A scrub clears the search. Back from a book keeps it, with the keyboard down and focus on the row.

### 5. The reader's order charges me for controls I don't use

- Where: "VoiceOver's order", "9. Where Am I?", question 1. Tasks 5, 2, 4.
- Where Am I? is 5 flicks from Play, each spoken over the book, and 5 back. On the Mac it's W.
- The skip buttons cost two flicks each way on every trip past them. Question 1 doesn't state that cost.
- No element names the heading I'm in. The app's voice says "The Battle"; the Headings value says only "Heading 26 of 412". Principle 4 promises every fact in an element, yet a braille reader must open a sheet for it. The time left in the heading is missing too.
- Instead:
  - Order: Back, title, Book content, Play, Where Am I?, Navigation unit, Speed, Previous heading, Next heading, Add bookmark, Bookmarks, Headings, Go To, Return, Sleep Timer, Voice, Book Info, Skip backward, Skip forward.
  - Voice Control and double-tappers keep the skip buttons: a four-finger tap near the bottom and one flick.
  - Where Am I?'s value leads with the heading and gives its time left. Headings' value is "The Battle, 26 of 412".

### 6. Silence is right after a sentence, wrong after a page or a bookmark

- Where: "What a move says", principles 1 and 4, "4. Play". Tasks 2, 4, 10.
- Playing, a move by Page, Bookmark, or an audiobook's heading says nothing, and the book's words can't say it: the Mac's own page says nothing is read aloud for a page. A stray flick with Bookmark chosen puts me somewhere unknown, in silence. The spec keeps "Jumped to page 12." while playing because it "names a place the book's words might not". The same argument holds here.
- Paused, what a move says is an announcement: a flash on the display, racing VoiceOver's own reading after an adjust. Yet the spec chose UIKit so that VoiceOver "reads the new value", and then gives Play no value.
- "The fix is in the hand-check list" isn't so: check 10 only asks the question. If VoiceOver says "Pause" after every flick over the book, the central gesture fails, and no fix is written.
- Eight words is half a sentence when I'm finding a place by sentence.
- Instead:
  - Playing: silent for Sentence, Paragraph, seconds, and a text book's Heading. Short words for Page, Bookmark, and an audiobook's Heading: "Page 113", "Bookmark 3", "Heading: Chapter 4".
  - Paused: Play's value after a move is what the move says, with the whole sentence for Sentence, which a flick cuts off. VoiceOver says it as the adjust's answer, and the display keeps it until Play.
  - Write the fallback now. Try a value of one space first. If that fails, say what replaces it.

### 7. Sheets land on the title, not on what I came for

- Where: "Focus on arrival and return", the sheets, `PhoneChoiceSheet`. Tasks 2, 4, 8, 14.
- The Mac's Headings sheet lands on the current heading ("Prefer the currently read heading", `initialFocusHeadingID`). The spec lands on the title and only scrolls, so this is a step back from the Mac. From the title, heading 26 is 29 flicks.
- A choice sheet marks the current choice with a trait, then lands on the title. With a hundred voices, that's a long flick to learn what I have.
- Instead: a sheet that's a list lands on what I came for. Headings: the current heading. Bookmarks: the nearest before the place. `PhoneChoiceSheet`: the current choice. Sleep Timer: the last preset used. The title is a flick away.

### 8. Nothing says how my library reaches the phone

- Where: "Importing", question 8. The premise of task 1.
- Import Folder imports one book. Open Book puts files in the folder shown. Folders are made by hand. AirDrop, the obvious way from my Mac, isn't in "Mail, Safari, Files, and Messages", and question 8 declines the one folder Finder could copy into.
- The Mac already has the piece, and the spec never names it: a ZIP of `.tmb` packages imports each book "with its places, bookmarks, and settings", and offers a folder for them.
- Instead:
  - Write the path down: on the Mac, ZIP a folder's packages, and send them by AirDrop or USB; on the phone, Create Folder. Check that packages made on the Mac open, and that their paths heal.
  - Answer question 8 yes, with folders inside it becoming library folders. Decide question 5 before this, not after.

### 9. The reader's layout isn't specified, and experts touch

- Where: "Who this is for" ("large plain buttons"), "How a person moves around". Every reader task.
- The spec counts only flicks. A control always in one place is one touch from anywhere: touch Where Am I?, hear it, touch Play. Seventeen large buttons won't fit one iPhone screen, and if the screen scrolls, nothing has a fixed place. In bed I have one thumb.
- Instead: specify it. No scrolling at default text sizes, the text in a strip, the rest in a fixed grid, and Play large and in the same place in every book. Check that Item Chooser (two-finger triple-tap, or Dots 2-4 with Space) lists every control by a usable name.

### 10. The Library puts what I came for far down

- Where: "The Library's top", "A folder", "What was rejected". Tasks 1 and 13.
- The spec rejects a bar because the row is "one flick from the title, in the same place on every Library screen". By its own order the Continue row is 4 flicks at the top and 3 in a folder. From anywhere deep it's 6 gestures to reach the reader.
- The first folder is 10 flicks from the title.
- All Items is 743 rows in one section. The Mac's letter navigation has no equal here, and the Headings rotor sees only "Books (743)".
- "A folder opens: focus is left to VoiceOver's default, the Back button or the title, so the folder's name is heard." The Back button is named for the parent, so on it I hear where I came from. The Mac says "Fiction, 12 books" on entering.
- Instead:
  - Title, Search, Continue row, Library view, then the folders and books. Settings, Add to Library, Sort, and New Folder go at the foot of the list, reached by a four-finger tap near the bottom.
  - Take the Library's Play out of VoiceOver's order: the magic tap does it.
  - In a title or author sort, use letter sections, whose headers the Headings rotor reaches, or iOS 26's `sectionIndexLabel`.
  - On a folder's arrival, focus the title and say the Mac's words.

### 11. Focus can be yanked from under a quick flick

- Where: "Focus on arrival and return". Tasks 2 and 7.
- For 3 seconds the app re-posts Play "if VoiceOver lands somewhere else by itself", and "stops the moment the listener moves". Nothing tells the app who moved focus. Open a book, flick to Navigation unit within a second, and I may be thrown back. The 0.35-second posts after a sheet can do the same.
- Instead: re-post only when focus lands on Back or the title, where VoiceOver wanders by itself. A landing on Play's neighbors is mine. Any focus event cancels a pending post. Test it in `PhoneFocusPolicyTests`.

### 12. One global unit fits neither kind of book

- Where: "5. Navigation unit", Settings' "Skip Controls", question 11. Tasks 2 and 10.
- With a global Sentence, an audiobook starts on a unit it doesn't offer. The spec covers Page in this case, not Sentence, and on the Mac those "do nothing in silence".
- With the 15-second default, a text book's first move lands mid-sentence, and each new book takes 5 gestures to reach Sentence.
- Settings calls it "Skip forward unit", though here it serves both directions and the reader calls it Navigation unit.
- Double-tapping Navigation unit does nothing, in silence, also from a display.
- Instead:
  - Two defaults: Sentence for text books, 15 seconds for audiobooks, each named Navigation unit in Settings. A unit a book doesn't offer falls to its default.
  - Activating Navigation unit opens `PhoneChoiceSheet`, so Bookmark needn't be five flicks from Sentence.

### 13. Up is forward on Play, but down is next on every rotor

- Where: "The idea", "4. Play", "The rotors". Tasks 2 and 9.
- On Play, a flick up moves forward. On the rotors, and on Lines one flick away, a flick down is next.
- From a display it reads backward: Dot 6 with Space, Apple's "move to next item using rotor setting", moves the book back, and Dot 3, "previous", moves it forward.
- I can learn it, but it's a choice, and the spec doesn't make it. Add it to the hand-check list with a pass or fail, and to the questions.

### 14. A bookmark with a note lands in the wrong place

- Where: "10. Add bookmark", "The Bookmarks sheet". Task 4.
- With a note it's about 16 gestures and the typing. The Mac's code takes the place when Add is pressed, so with the book playing, the bookmark lands wherever the book has got to after all that.
- The button also turns into Remove within 10 characters of a bookmark (half a second in an audiobook). Removing asks nothing, has no undo, and takes the note.
- Instead: the place is taken when the Add sheet opens. With finding 7's rule, a plain Add followed by Edit Note is 6 gestures: flick to Bookmarks, double-tap, land on the new bookmark, twist to Actions, flick to Edit Note, double-tap. Removing a bookmark that has a note asks first.

### 15. Importing: silence, and being thrown

- Where: "Adding a book", "From Mail", "Progress". Task 11.
- From Mail with a book playing, `importAndOpenFiles` opens the new book when the import ends: my book stops, and focus moves, whatever I'm doing by then. At a cold launch with a file, the spec both restores the reader and opens the file, and doesn't say which wins.
- After picking a file, nothing is said until it finishes, and the spec doesn't say whether the Add to Library sheet closes. A 2 GB book means minutes of silence.
- The Mac's quarter announcements ("25 of 100 books processed, about 4 minutes left") are dropped, and the progress card can't be reached from the reader.
- A file only in iCloud has no words of its own, no time limit offline, and no stated Cancel.
- Leaving stops the work after 30 seconds without a word, and Auto-Lock does the same while I wait with the app open.
- Instead:
  - With a book playing, import and don't open. A file wins over reopening at launch. If I've moved since the file arrived, don't take my focus.
  - Close the sheet first, and say "Importing Dune" once. Keep the quarters while no book plays.
  - Add a download line, a limit, and a failure sentence. Test in Airplane Mode.
  - Keep the screen awake during an import. `BGContinuedProcessingTask` is the first follow-up.

### 16. The sleep timer in bed

- Where: "The Sleep Timer sheet", "What the phone leaves out". Task 8.
- It's 11 gestures every night, and 5 more stops if one runs.
- The milestones at 5 minutes, 1 minute, 30 and 10 seconds break principle 1: VoiceOver over the book in the dark, heard or lost by chance.
- Restarting it takes unlocking and the sheet. The Mac's Restart Sleep Timer is "a later wish".
- Instead: land on the last preset, for 5 gestures. Drop the milestones on the phone, or make them a switch that's off. Plan a restart that needs no unlocking, from the AirPods, or by a shake, as some audiobook players do.

### 17. Calls and other interruptions

- Where: "What pauses and what resumes", "The magic tap". Task 6.
- A route change gets Rewind on Resume, and an interruption's resume doesn't say. After a long call I want the rewind.
- Play during a call fails to activate, and nothing is said. Say why.
- Check 12 says "during a phone call". Name the ringing, locked and unlocked with the app in front: there the magic tap must answer.
- Apple lists Dots 1-5-6 as "Play/Pause Music", not as the magic tap. At a cold reopen, before TextMouth holds Now Playing, it might start Music. Add that to check 21.
- "It also works from the lock screen in time" (Where Am I?): nothing in the spec triggers it there. Cut it, or say how.

### 18. Go To

- Where: "The Go To sheet". Task 3.
- The rule says a sheet "whose whole point is a field" lands on it. Go To has three, and doesn't say which, or which has the keyboard.
- The Page field starts at "112". Unless that's selected, each jump starts with three deletes.
- Percent is a decimal pad, which has no Go key, though "the keyboard's Go key is the same as Jump".
- Instead: land on the Page field with the text selected, or on the time field in an audiobook, and use numbers and punctuation throughout. That takes page 40 from 12 gestures to 9.

### 19. The Ogg sentence

- Where: "What can't be imported". Task 12.
- "Converting this kind of file is not available on iPhone yet." It names neither the file nor the kind, talks of a conversion I never asked for, and gives no next step. The section doesn't say how it's shown, and the picker still offers the file.
- Instead: "“Radio Drama” is in Ogg, which TextMouth on iPhone can't play yet. Add it on your Mac, then send the book here." The same pattern serves Word 6 and braille. A ZIP of Ogg tracks must get it too.

### 20. Smaller things

- A cold launch always lands in the reader, even if I'd gone back to the Library, since Back never closes a book. I'd accept that, but say so. A cold reopen also forgets the book was read from the Reading List, since only its ID is kept.
- Book Info is the one reader panel with no order. Reused Mac sheets may bring pop-ups, which are the Menus the spec bans.
- With Auto-play on, "Bookmark 3" lands on the book's first words. Treat that as playing. A preset's "Timer set for 30 minutes." does the same: say it first, then start.
- Preview Voice with a book playing is unspecified. Pause and resume, as Where Am I? does.
- An audiobook's Book content stop says only "has no text". Have it give the heading too.
- The Default speed slider's step isn't given. Use the reader's 25.
- Where Am I?'s value says "30.0%", heard as "thirty point zero", and its summary says "30 percent". Drop the ".0".

## The tasks, gesture by gesture

### 1. Find a book among 700

- Launch, with no book ever opened: "Library, heading", and the same on the display.
- By folders, the 11th book in the 4th subfolder of the 5th folder, with the rotor staying on Headings: twist, flick down to "Folders, heading", flick right to "Fiction, 12 books, button" after 4 more, double-tap: 8. Next level: 7. Last level: 14. Total 29. Without the rotor, the first folder alone is 10 flicks.
- By search: 3 flicks to "Search books, search field", double-tap, 5 letters, then "3 books", 2 flicks past Cancel, double-tap: 12. As the model works today, "No books match." Through All Items: about 22. Unclear and silent spots are in finding 4.
- Search wins at any depth, once it searches everything.

### 2. Open, listen, skip, heading, speed

- Double-tap the row: "Play, button, adjustable" or "Play, Loading", then the hint. Double-tap or magic tap: VoiceOver is silent and the book starts. 2 gestures, and very good.
- Three sentences, the first time: flick right, "Navigation unit, 15 seconds, adjustable", over the book; 3 flicks up, each value read; flick left, "Pause, button, adjustable"; 3 flicks up. 8 gestures, then 3 once the unit is set. If no-value is silent, the book restarting is all I hear.
- Next heading: 6 gestures, and my unit is changed (2).
- Speed: 4 flicks, "225 words per minute" per flick up, 4 flicks back. The book may change only at its next natural break, after VoiceOver has given the number.

### 3. Jump to page 40

- Four-finger tap near the bottom, "Book Info"; 4 flicks left, "Go To, button"; double-tap: 6.
- Then, as written: delete three digits, type 4 and 0, Go: 12. If it lands on the title, 15. Selected text and a set landing: 9 (18).
- "Jumped to page 40." is a flash on the display. Focus is on Go To, 9 flicks from Play.

### 4. Bookmark with a note, go to it, come back

- Note: 7 flicks to Bookmarks, double-tap, 2 flicks to Add Bookmark, double-tap, type, 2 flicks to Add, double-tap, flick to Done, double-tap: about 16. Wrong place (14).
- From page 90: 7 flicks, double-tap, 3 flicks to the first row plus its place in the list, double-tap: 12 or more. Playing, nothing is said, not the bookmark's number or its note.
- Back: 3 flicks from the Bookmarks button to Return, double-tap: 4. "Returned to previous position." That's good, because focus returned close by.

### 5. Where am I, while it plays

- Speech: 5 flicks, then the value is read over the book. Double-tap: the book pauses, the summary speaks in the book's voice, and the book goes on. 6 gestures, and 5 back.
- Braille: 5 moves with Dot 4 and Space. The display shows "Where Am I?", the page, the percent, and the time left, but no heading. It stays as it was while the book moves on, which is right by principle 3, and nothing warns me it's old. Leaving and landing again refreshes it.

### 6. Locked, AirPods, a call, Siri

- Side button: VoiceOver's own words, and the book goes on, if check 4 passes.
- Stem press: pause, with nothing said. One AirPod out and back: pause, then play, expected and unverified. Both are right.
- A call: the book pauses, and plays on after if the system says so. Rewind unsaid, and Play during the call silent (17).
- Siri: the same pause and resume. "Pause" and "resume" should work through Now Playing. Nothing app-specific works, such as asking where I am, and the spec doesn't mention it.

### 7. The next day, after a kill

- Double-tap the icon: "Play, button, adjustable", then "Moby-Dick". Magic tap. 2 gestures, and that's the best thing in the spec.
- At most 30 seconds lost. Whether Rewind on Resume applies isn't said. Dots 1-5-6 may not be the magic tap here (17).

### 8. Sleep timer, 30 minutes, in bed

- Four-finger tap, 2 flicks left, "Sleep Timer, Off, button", double-tap, "Sleep Timer, heading". Flick to Close, New Timer, "Pause playback after:", 10, 15, 30, then double-tap: 11. "Timer set for 30 minutes." Side button: 12.
- At expiry, in the background, the words are probably lost, which is fine in bed.

### 9. Braille: read while paused, then read along

- Magic tap, Dot 1 with Space: "Book content", and VoiceOver starts reading aloud unless speech is off. The display shows the sentence just spoken. Panning works, and that's the good part.
- "Go on from there": not possible (1).
- Reading along: the text holds still under me, as promised. It drifts from the voice, and re-syncing takes two moves, with up to 10 seconds of staleness and VoiceOver's voice over the book unless I turn its speech off (Dots 1-3-4 with Space). Follow in Braille is deferred, and no check on the list could decide it.

### 10. An M4B with chapters

- The same elements, in the same order. These differ: no Sentence, Paragraph, or Page; "Audio speed, 1.25 times speed"; Audio Settings for Voice; "Time in the recording" in Go To; and "Moved to 1 hour, 3 minutes, 45 seconds." after a paused skip.
- Book content is a stop that says "has no text". Where Am I?'s value has no chapter name and no time in the recording. Sentence as the global unit breaks it (12). A next chapter by Heading is silent, and the audio may not name it (6).

### 11. Add from Mail, Files, a big ZIP

- Mail: the share sheet, which the spec leaves unverified, then TextMouth opens. Focus and words on arrival aren't specified. My playing book stops at the end (15).
- Files, on iCloud: 2 flicks to Add to Library, double-tap, 2 flicks to Open Book…, double-tap: 6, then the system's picker. Then silence, with no download words.
- Big ZIP: "Create Folder" or "No Thanks", then silence. Leave, and it halts after 30 seconds. Back: a low-priority line says what happened. Killed: "Importing “Dune” was stopped when TextMouth closed. Add it again.", which works, since a ZIP passes over the books it already has.

### 12. Ogg, and a duplicate

- Ogg: finding 19.
- Duplicate: focus moves to the first choice and the question is read: "Keep Both", "Replace Existing", "Cancel", in a vertical list. Good. "The existing copy's files are deleted." is plain and right.

### 13. Browse while it plays, wrong book, get back

- Scrub: 1, onto the book's row, read over the book. Browsing talks over it, by my own choice and ducking setting.
- Wrong row, double-tap: the book stops, and "Play" is said (3). Back: scrub. Then the row, double-tap, double-tap: 4 at best, if the row is close by. It's far more if not.
- Without a mistake, returning to the reader from deep in a list is 6: four-finger tap, 4 flicks, double-tap. Focus lands on Pause and the book never stops. Good.

### 14. Default voice and rate, and this week's time

- Settings: flick, double-tap. Arrival isn't specified. About 4 flicks to Voice, double-tap, flick through the voices, double-tap. 2 flicks to "Default speed", flick up per step. About 10, plus the voices and the steps.
- This Week: four-finger tap near the bottom, 3 flicks to Reading Statistics, double-tap, about 3 flicks: 8, or 10 from the Library's title. Fine for a weekly look. `ReadingStatsView` has no order in the spec and no hand check.

## What's right, and must not be lost

- Landing on Play, a press during loading remembered, and one gesture the next morning.
- The magic tap from any screen, saying nothing, with Actions kept off Play.
- Adjust on Play, with Navigation unit one element away.
- Focus staying where I put it, and nothing focusable changing under me. No updates-frequently trait.
- Book content just before Play, starting at the sentence just spoken, and holding still while I read.
- "No next heading." and its kin: a press that does nothing is told from a press that was missed.
- Announcements that a flick can cut off, with `.high` kept for a real stop.
- One stack, no tab bar, no bottom mini-player, no position slider, no gesture area.
- Choice sheets in place of Menus, because they return focus.
- Activating the audio session only at Play, so opening a book never stops my music. The lock screen promising only what it does.
- A Return that stays in its place. The Mac's words through shared code, with a test to hold them.
- Saying "Unverified" where it's so. That's the most trustworthy thing about this document.

## Words and labels

- The Mac's vocabulary is used faithfully. I'd move between the apps without confusion, apart from Play moving things and "Skip forward unit". "Go To", "Jump to page", and "Now Playing: Emma" are good new words.
- At 14 cells, "Navigation unit" fills the line and the value that changes is off it. "Where Am I?" and "Return to previous reading position" have the same problem. Check 20 asks only about Item Overview: add reading the value at 14 and 20 cells.
- "Skip backward" and "Skip forward" are neighbors sharing five cells, which breaks principle 5 as written.
- Principle 9 says there's one duplicate. The Library's Play and the sheet's Speed slider are two more. Name them or cut them.
- Five sheets use Done, Back to Book, Cancel, and Close for one act, in one position. The Mac's words, but worth a look.
- "Moves back or forward by Sentence.": lower-case the unit.

## What's deferred

- Wrongly deferred:
  - Paging past the passage, and Listen from Here (1).
  - Search in Book: the model is shared, and it's the only way to find a line.
  - A test switch for Follow in Braille in the first build, so that a first run can decide question 10.
  - The Files folder (8).
- Rightly deferred: feeds, transcription, export, the text editor, recording, the audio editor, braille books, the view editor, Edit Mode, Folder Settings, sounds, and the whole-book screen, once paging exists.
- What I'd miss most: shared places with the Mac, every day I change devices. Then my own substitution rules, Next in Folder, and Restart Sleep Timer.
- Named nowhere in the spec:
  - Copy Reading Position.
  - Keys on a Bluetooth keyboard. "A phone has no keys yet" isn't so for me: Space and W would be cheap.
  - App Shortcuts, for the Action Button, Back Tap, and Siri: Where Am I?, and a bookmark from a locked phone.

## The hand-check list

- The spec calls the magic tap "first on the hand-check list" (it's 12) and lock speech "check 1" (it's 4). Keep lock speech first, put 9 to 12 straight after it, and split 12, which holds nine checks.
- Add:
  - Where focus ends after a rotor flick. Check 13 asks only what's heard.
  - Direction, with Dots 3 and 6.
  - A flick within a second of opening a book.
  - Finding Play by touch, and Item Chooser.
  - Two hours locked, with memory and battery logged. Check 4 is five minutes, and I read for hours.
  - Voices that report words oddly: Eloquence, a Novelty voice, a third-party voice. The word-progress watchdog could fire on them, and keep restarting at one word.
  - Reading along with VoiceOver's speech off. Auto-Lock during reading. A text view changing under a display.
  - The ringing phone. Play during a call. Dots 1-5-6 at a cold reopen.
  - The wrong-row path. Mail with a book playing. A cold launch with a file. Airplane Mode on an iCloud file.
  - A ZIP of Mac packages, by AirDrop and by USB.
  - Settings, Statistics, the Voice sheet, Book Info, and the folder sheets: none is on the list.
  - Flick speed in a list of 700 rows. Check 37 is only launch time.

## The open questions

- Question 1: move the skip buttons to the end of the order, and state the cost of leaving them.
- Question 6: disagree. The first book plays until Play in the second (3).
- Question 8: disagree. Yes, in the first version (8).
- Question 10: needs a test switch and a check.
- Question 11: disagree. Two defaults (12).
- Question 5: decide before a library goes on the phone. Its setting isn't in Settings' order yet.
- Questions 2, 3, 4, 7, and 9: agree, with 9 subject to finding 10.
- Question 12 should come first, since it decides whether anything installs.
- Add these:
  - Does search cover the whole library?
  - Do a page and a bookmark speak while playing?
  - Is up forward on Play?
  - Should the sleep timer's milestones stay?
  - Does a cold launch always reopen the reader?

## The spec as a document

- Headings, order, and plain lists all work under VoiceOver. Nothing fights me.
- At 995 lines it serves two readers, and I wade through code names to get my answers. Backticks are read aloud at some punctuation settings. Move "The map to the code" and the slices to a page of their own, or at least to the end, and keep identifiers out of the reader's section.
- It lacks what I most wanted to read: a day in the app, with counts and with what's said. A short section of that would have shown findings 2, 5, and 10 to the author.
- What isn't in the first version is in three places: "What was rejected", "What the phone leaves out", and "What's deferred". Link them, at least.

## Sources

- Apple, [Common braille commands for VoiceOver](https://support.apple.com/en-us/118665): Dots 3 and 6, Dots 3-6, Dots 1-5-6, Dots 1-4-5-6, Dots 2-4, and Dots 1-3-4.
- Apple, [VoiceOver efficiency with custom rotors, WWDC20](https://developer.apple.com/videos/play/wwdc2020/10116/): a rotor returns a target element, or a range in a `UITextInput`. Nil stays put.
- Apple, [`sectionIndexLabel`](https://developer.apple.com/documentation/swiftui/view/sectionindexlabel(_:)) and [`listSectionIndexVisibility`](https://developer.apple.com/documentation/swiftui/view/listsectionindexvisibility(_:)), iOS 26.
- The Mac, under `TextMouth/`:
  - `ViewModels/LibraryViewModel+FolderManagement.swift` and `Models/Library.swift`: the search's scope.
  - `Views/Reader/HeadingNavigatorView.swift`: the Headings sheet's landing.
  - `ViewModels/ReaderViewModel+Bookmarks.swift` and `Views/Reader/BookmarkPanelView.swift`: when a bookmark takes its place, and how near counts as near.
- The Mac's `docs/user/adding-books.md`: ZIPs of packages, and the quarter announcements.
