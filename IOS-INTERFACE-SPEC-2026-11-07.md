# TextMouth for iPhone: the interface specification (November 7, 2026)

## How to read this

- This is the design of TextMouth's iPhone app, for its first version. It is written for the person who will use it, and for the agents building it. Everything here reads in order with VoiceOver: real headings, short lists, no tables, no pictures.
- **Nothing in this document has run on an iPhone.** This Mac has no room for the iOS platform, so there is no simulator and no device. `make typecheck-ios` compiles and links the app, and that is the only check of iOS code so far. Where a behavior can only be known from a first run, the text says "Unverified", and the hand-check list near the end covers it.
- The design rests on three research reports, kept beside the briefs in `Scripts/agents/briefs/2026-11-07/iosui-research/`: `research-vo.md` (VoiceOver, braille, and what blind readers say), `research-code.md` (the code and the Mac's exact wording), and `research-ios.md` (what iOS does to the app). Sources for each claim are there.
- Questions 1 to 4 and 6 in `humanQuestions/2026-11-03.md` have no answers yet. This spec builds on the recommended answers: iPhone first, with layouts that also work on an iPad; the first version's list in question 2; a library of the phone's own; iOS 26 and later. Each stays reversible. New questions are in the last section.

## Who this is for

The app's first user is blind, and reads with VoiceOver and a braille display. They know the Mac app in depth, and its vocabulary. This isn't a sighted app made accessible afterward. The VoiceOver and braille experience is the design, and the visual layout follows from it: a sighted helper sees the same controls, in the same order, as large plain buttons.

## The principles

These settle most questions. Where a later section seems to disagree, the principles win and the section is wrong.

1. **The book is the feedback.** While the book plays, the app says nothing unless the listener asked. A page turning, a heading passing, a chapter starting, a move by a unit: none of them is announced while the book is audible, since what's playing says where you are.
2. **Focus stays where the listener put it.** VoiceOver's cursor moves only on arrival at a new screen, on return from a sheet, and after a jump the listener asked for. It never chases the spoken text, and nothing during playback moves it. Apple's criteria say a reading position mustn't reset unexpectedly, and readers curse exactly that in other apps.
3. **Nothing focusable changes while the book plays.** SwiftUI's documentation says a change to an element's label or value can be spoken automatically, and a braille reader's line can jump. So the reader's words are computed when VoiceOver asks for them, not pushed as the book moves. Nothing on the reader uses the updates-frequently trait.
4. **Everything spoken can also be read.** What the app's voice says never reaches a braille display, and announcements are short-lived flash messages there. So the book's text is an element, and every fact the app announces can also be found in an element.
5. **A short, stable set of controls, in a fixed order.** Controls don't appear, vanish, or move during a session. Nothing the listener uses often is hidden behind the Actions rotor or a More menu. A label's first few cells differ from its neighbors', for iOS 26's braille Item Overview.
6. **One vocabulary.** Where the Mac has a word for something, the iPhone uses that word: Skip forward, Navigation unit, Where Am I?, Book content. See "One vocabulary" below.
7. **A hint says what a control does, never a gesture.** VoiceOver, a braille display, and Voice Control each do it their own way. Hints stay short, because a user may keep only app hints on.
8. **Touch is never required.** iOS 26.4's Touch Curtain stops touch while a braille display is connected. Everything can be done with VoiceOver's item, rotor, and activate commands.
9. **No control that does what another does.** The user's standing rule (a slider beside a stepper is a duplicate). The one exception is named in the reader's section, with its reason and a question.

## The app's structure

### The decision

- **One navigation stack.** The Library is the root. Choosing a folder pushes that folder. Choosing a book pushes its reader, full screen. Settings is pushed from the Library's root.
- **The reader's panels are sheets:** Headings, Bookmarks, Go To, Sleep Timer, Voice & Speed, Book Info. Each opens over the reader, and each returns focus to the control that opened it.
- **One reader at a time, owned above the navigation.** A single app-level object (`PhoneSession`, below) holds the open book's `ReaderViewModel`. Leaving the reader's screen keeps the book playing. Opening another book saves and closes the first, and the new one waits at its place until Play.
- **The book in reach is a row, not a bar.** The first row of every Library screen is the Mac's Continue button: "Continue listening to Emma, 16 minutes remaining", or "Now Playing: Emma" while it plays. See "The Continue row".
- **The app is built on UIKit's life cycle,** with a `UIWindow` subclass as the one reliable home for the magic tap, and a `UIHostingController` holding the SwiftUI screens. See "The app's frame" under the code map.

### What was rejected, and why

- **A tab bar (Library, Reader, Settings), with iOS 26's `tabViewBottomAccessory` as a mini-player.** Nobody documents VoiceOver's order for that accessory, and its content can change with the tab bar's size, which could lose focus. A tab bar adds three stops to the end of every screen, and a reader needs one stack. Rejected until a first run shows otherwise.
- **A Now Playing bar pinned to the bottom of the screen,** as in Music or Audible. VoiceOver reaches it last, past every book in the library. Reports curse controls moved into a mini-player's actions, and focus lost around it. A row at the top is one flick from the title, in the same place on every Library screen, and it is what the Mac already has.
- **The reader as a sheet or a full-screen cover.** A pushed screen has a system Back button and the system's two-finger scrub for free. A cover has neither.
- **SwiftUI's `App` with `@UIApplicationDelegateAdaptor`.** Two shipping audio apps (Paperback and FastPlay, both written for screen reader users) found that a delegate behind the adaptor "may never fire" for the magic tap, and put a window subclass under a scene delegate. Doing that inside a SwiftUI `App` needs an empty `WindowGroup`. A plain UIKit app delegate and scene delegate is simpler and fully documented.
- **A Direct Touch gesture area on the reader,** as some readers once had. It disables VoiceOver's own gestures there, has no braille equivalent, and a blind user can swipe through it by accident.
- **A position slider on the reader's screen.** Too easy to change by accident, and readers curse it for moving too far. Percent, page, and time are typed in Go To.
- **Keeping the first book playing while a second is opened and looked at,** which the Mac's many windows allow. It means two live readers on the phone. Rejected for the first version. It's a question at the end.

### How a person moves around

- A flick right or left moves through a screen's elements in the order this spec gives.
- The two-finger scrub goes back: from the reader to the Library with the book still playing, from a folder to its parent, from a sheet to the screen under it.
- The two-finger double-tap, the magic tap, plays and pauses the current book from any screen of the app, sheets included (see "The magic tap").
- A four-finger tap near the top reaches the first element, and near the bottom the last.

## The rules every screen follows

### Focus on arrival and return

Each is a rule of one plain type, `PhoneFocusPolicy`, so tests can read it.

- **A book opens:** focus lands on Play. After the screen appears, the app posts `.screenChanged` with Play as its argument. For up to 3 seconds, if VoiceOver lands somewhere else by itself, the app posts it again; it stops the moment the listener moves. (Paperback's method. VoiceOver lands somewhere by itself on appearing, and may do so again.)
- **Back to a Library screen:** focus lands on the row just left: the book's row, or the folder's row. It's asked for by row ID after 0.35 seconds, since VoiceOver may go to the top on a pop. If the row isn't on the screen, focus lands on the Continue row.
- **A folder opens:** focus is left to VoiceOver's default, the Back button or the title, so the folder's name is heard.
- **A sheet opens:** focus lands on the sheet's heading, after 0.35 seconds. The exception is any sheet whose whole point is a field: there it lands on the field.
- **A sheet closes:** focus returns to the control that opened it, in `onDismiss`, by a `.layoutChanged` with that control as argument, after 0.35 seconds. Sheets and menus don't return focus by themselves.
- **A jump chosen in a sheet:** the sheet closes, focus returns to the control that opened it, and the rule for moves below says what is announced.
- **Coming back from the background:** focus is restored to where it was only after a true return from the background, never after Control Center or a call banner, which leave it alone.
- **During playback:** nothing moves focus, ever. A chapter change, a book's end, and an interruption don't touch it.
- **The next book, when listening goes on from one book to another:** the reader's screen stays, with the new book's title and its text. Focus stays on the control it was on. VoiceOver says the Mac's "Starting: Dune".

### Announcements

- All go through the shared `VoiceOverAnnouncer`, whose iOS branch posts `AccessibilityNotification.Announcement`.
- **Priority.** Nearly every shared call says `.high`, which on iOS can't be interrupted once started, so a quick second flick couldn't cut it off. On iOS, the announcer maps high to `.default`, medium to `.default`, and low to `.low`. The one thing that keeps `.high` is a stop the listener must know about: `PhoneAnnouncer.important(_:)`, used for a book that can't be played or speech that has stopped.
- **Timing.** An announcement after an activation is posted 0.15 seconds later, or SwiftUI's own layout notification can cut it off.
- **While the book plays,** an announcement caused by a move is dropped (principle 1). Answers to something else the listener did are still said: a bookmark added, a voice changed, a timer set.
- **Background results,** such as an import finishing, are `.low`, so they wait their turn.
- **Unverified:** whether an announcement posted while the app is in the background is ever heard. Assume it's lost, and say nothing important that way.

### The magic tap

- A `UIWindow` subclass, `MagicTapWindow`, overrides `accessibilityPerformMagicTap()`. The window is in every responder chain, sheets included.
- **It toggles the current book:** the open reader's `togglePlayPause()`. With no reader open, it opens the book last opened (`lastOpenedBook`) without leaving the screen, and plays it as soon as it has loaded.
- **It returns false** when no book has ever been opened, so that the system's own fallback runs.
- **It says nothing.** The book starting or stopping is the feedback.
- **Unverified, and first on the hand-check list:** that it doesn't take dictation from a text field, or a phone call's answer and end, and that the reader's Play label changing under a magic tap isn't spoken over the book. If a text field does lose dictation, `MagicTapWindow` returns false while a text field holds the keyboard.
- Outside the app, the system's magic tap plays and pauses the current media app through remote commands, unless the user has turned off iOS 26's Media Playback switch.

### Lists

- Every list is a SwiftUI `List`, whose rows are real elements. A `LazyVStack` isn't used, since offscreen elements aren't reliable there.
- A row's identity never changes when the list refreshes, so VoiceOver's cursor stays put.
- Section headers carry the header trait, so the Headings rotor jumps between them.
- A row's commands are explicit named actions, on the Actions rotor, with a context menu of the same commands for touch.

### Choices

Picking from a list of choices (a library view, a sort, a language, a voice) is a small sheet of the app's own, `PhoneChoiceSheet`: a list where each choice is a row, the current one has the selected trait, and choosing closes the sheet. SwiftUI's `Menu` isn't used for these, since it doesn't return focus when it closes and `AccessibilityFocusState` can't bring it back.

## The Library

The Library is three kinds of screen with one shape: the top of the Folders view, a folder, and any other view such as All Items.

### The Library's top

VoiceOver's order:

1. **Title.** "Library", the navigation title, a heading. A view other than Folders shows that view's name as well: "Library: All Items".
2. **Settings.** Button.
   - Label: "Settings". Hint: "Opens TextMouth's settings." Opens the Settings screen.
3. **Add to Library.** Button.
   - Label, hint, and title: the Mac's `AddToLibraryWording`, except that the hint names what the phone offers: "Opens a sheet with the ways to add to the library: open a book, or import a folder." Opens the sheet in "Importing".
4. **Search.** The search field, kept under the navigation bar by `.searchable(placement: .navigationBarDrawer(displayMode: .always))`, so it's near the top and not last in the order where iOS 26 would put it.
   - Prompt: "Search books", the Mac's.
   - Results replace the list as you type. After typing stops for a second, VoiceOver says the count with low priority, as in "3 books"; with none, "No books match."
5. **The Continue row,** and the Play button that follows it. See "The Continue row". Both are absent until a book has been opened.
6. **Library view.** A row showing the view, which opens `PhoneChoiceSheet`.
   - Label: "Library view". Value: the view's name, such as "Folders".
   - Hint: "Chooses what the Library lists."
   - Its choices are what the Mac's pop-up offers: `offeredViews(in:current:center:applicable:)`. Feeds doesn't appear, since the phone has none.
   - Choosing closes the sheet, and focus returns here, so VoiceOver reads the new value. The list below changes. Nothing else is said.
7. **Sort.** A row, opening `PhoneChoiceSheet`.
   - Label: the Mac's `LibrarySortState` words, "Sort books by Title, ascending".
   - Hint: "Chooses the order of the books."
   - Choices: the fields, "Title", "Author", "Date Added", "Last Opened", "File Size", and "Manual Order"; then the Mac's "Sort Descending" or "Sort Ascending", dimmed in Manual Order with the hint "Manual order has no direction"; and in a folder with subfolders, "Apply Sort to All Subfolders".
   - On choosing, VoiceOver says the Mac's "Sorted by Title, ascending" once the sheet has closed.
8. **New Folder.** A row, only in the Folders view. Label: "Create new folder". Opens the New Folder sheet.
9. **"Folders",** a section heading, then one row for each folder.
   - Label: the Mac's "Fiction, 12 books". Hint: "Opens the folder."
   - Actions: "Rename Folder...", "Move Folder...", "Delete Folder...".
10. **"Books (743)",** a section heading in the Mac's words, then one row for each book. See "A book's row".
11. **The summary,** last, one static element: the Mac's spoken summary, "743 books. 14 hours total remaining at current speed." It isn't updated while the book plays.

A four-finger tap near the bottom reaches the summary, and the Headings rotor reaches the sections.

### A folder

The same, with these differences:

- First comes the system's Back button, named for where it goes.
- The title is the folder's name, a heading.
- Settings and Library view aren't here. Up One Level isn't either: Back is that.
- The section headings and the rows are the folder's own.

### Any other view

All Items, Unopened, Recently Opened, Reading List, and views the user makes on the Mac if a library ever moves: the same as the top, with no Folders section and no New Folder. A view that lists nothing shows one row, the Mac's "Nothing matches this view now." The Reading List keeps the order you arrange. Its Sort row reads "Sort books by Reading List Order", with that one choice, and an empty Reading List says: "The reading list is empty. To add a book, choose Add to Reading List from its actions."

### A book's row

- **Label:** exactly the Mac's `BookRow.rowAccessibilityLabel`, in its order: the title; "by" and the author; "In reading list"; "New" or "Now Reading"; progress, such as "42 percent" or "Finished"; time left, such as "2 hours, 5 minutes remaining"; the format, such as "EPUB". Example: "Middlemarch, by George Eliot, 42 percent, 2 hours, 5 minutes remaining, EPUB". The title comes first.
- **Value:** none.
- **Hint:** "Opens the book."
- **Traits:** button.
- **Actions,** each only where it applies, in this order: "Book Info"; "Add to Reading List" or "Remove from Reading List"; "Move to Folder..."; "Move Up" and "Move Down", where the list has an order you arrange; "Remove from Library...".
  - Move Up and Move Down say the Mac's `placeAnnouncement`, as in "Dune, 3 of 12".
- **Braille:** the label, then VoiceOver's mark for a button. The title's first cells tell rows apart.
- **While the book plays:** a row's words don't update. `LiveReadingPositions` ticks once a second on the Mac, and on the phone a row reads it only when the list is next drawn after the screen appears.
- **What's visible:** two lines, the title, then the author and progress, at Dynamic Type sizes. The Mac's `BookRow` is too wide for a phone, so the phone draws its own and calls the same words.

### Removing a book

- Remove from Library... asks first, unless Confirm before removing a book is off.
- **On a phone there is no Trash a person can open, and a library folder a person can't see.** So the phone offers one choice, and uses the Mac's words for it:
  - Title: "Remove Book?"
  - Message: "This deletes the book and its files from this iPhone, and they can't be recovered. Your Mac's library isn't touched."
  - Buttons: "Delete Permanently", and "Cancel".
- Afterwards VoiceOver says the Mac's "Deleted “Dune” permanently.", and focus goes to the row after the one removed, or before it if it was the last.
- If that book is the one open in the reader, the reader closes first, and its place is lost along with it.

### Folder sheets

New Folder, Rename Folder, Move Folder, Move to Folder, and Delete Folder are the Mac's sheets, with their wording, in a `NavigationStack` with the sheet's title and the Mac's Cancel and confirm buttons in the toolbar. Each one's text field has the keyboard and VoiceOver's cursor on arrival. Failures show under the field as the Mac's `OperationFailureNotice`, "Error: " and the reason, and are announced once.

### The Continue row

The Mac's Continue button, as a row. It's the same on every Library screen, first after the search field or the title.

- **Not playing.** Label: the Mac's "Continue listening to Emma, 16 minutes remaining". A finished book has no time left: "Continue listening to Emma".
- **Playing.** Label: "Now Playing: Emma". There's no time left, since it would change. The first cells differ from "Continue".
- **Hint:** the Mac's "Opens the last book you were reading".
- **Traits:** button.
- Activating opens the reader, with focus on Play, and the book goes on playing if it was.
- **After it, one more element, a Play button.** Label: "Play" or "Pause". Hint: "Plays or pauses Emma." It starts a media session in the Play state, as the reader's Play does. Without VoiceOver running it's the only way to pause from the Library. It isn't adjustable.
- **Its words change only when playing starts or stops, or when the book changes.** It reads a `ReaderSnapshot`-style value, not the reader, so it isn't redrawn 8 times a second.
- A book deleted from the library leaves the row, and the row goes to the book before it in Last Opened, or disappears when there's none.

## The reader

The reader is the heart of the app, and the screen a person spends their time on. It serves both text read aloud and audiobooks, with the same elements in the same order.

### The idea

- **Land on Play.** A book opens with VoiceOver on Play. A double-tap plays. A magic tap plays from anywhere.
- **Swipe up or down on Play to move by the navigation unit.** That is the pattern blind readers praise in Voice Dream, and that Speech Central and Paperback also use. No rotor twist is needed, because VoiceOver selects Adjust by itself when focus lands on an adjustable element (an Apple engineer's accepted answer). It works from a braille display with the "move by rotor setting" commands, dots 3 and 6.
- **The element after Play chooses the unit,** adjustable in the same way.
- **The element before Play is the book's text,** so a person who pauses can flick once to the left and read what was just spoken, by line, by word, or on a display.
- **Everything else follows in a fixed order,** by how often it's used.

### What was rejected for moving by unit, and why

- **The rotor as the way to move.** A custom rotor must return a real element, and no document says what VoiceOver does when that is the element it already stands on. The closest report is an end-of-list sound and no speech. VoiceOver also reselects Adjust whenever focus lands on an adjustable element, and some readers dislike twisting. So the rotor is a second way (below), not the first, and a first run decides how good it is.
- **A rotor of every sentence built in SwiftUI.** SwiftUI's rotors describe every entry; a book has 50,000 sentences; and a field report has one listed by VoiceOver and stepping to none of its rows. Only UIKit's `UIAccessibilityCustomRotor` is lazy.
- **Actions as the way to move.** Too many steps for something done again and again.
- **A gesture area with Direct Touch.** See "What was rejected" under the app's structure.

### Why the reader's controls are UIKit views

- The reader's five most used controls are small UIKit views in the SwiftUI layout (`PhoneControl`, a `UIViewRepresentable`), and so is every other control on this screen, for one shape throughout.
- In UIKit, `accessibilityLabel`, `accessibilityValue`, and `accessibilityHint` can be computed at the moment VoiceOver asks, and `accessibilityIncrement()` and `accessibilityDecrement()` change state synchronously, so VoiceOver reads the new value and not the old. In SwiftUI, a value updates only with a redraw, later than VoiceOver's read, which is a reported failure.
- SwiftUI may speak a changed label on a focused element by itself (principle 3). A UIKit view whose words are computed on request has nothing to push.
- A plain struct, `PhoneControlDescription`, says what each control's words and traits are for a given state, in shared code, so the Mac's test host can test every sentence. The UIKit view only reads it.
- SwiftUI's `AccessibilityTraits` has no `.adjustable` in this SDK, though a WWDC26 sample uses it. UIKit's does.

### VoiceOver's order

1. Back
2. The title
3. Book content
4. Play
5. Navigation unit
6. Skip backward
7. Skip forward
8. Speed
9. Where Am I?
10. Add bookmark
11. Bookmarks
12. Headings
13. Go To
14. Return
15. Sleep Timer
16. Voice, or Audio Settings
17. Book Info

These never appear or vanish while the book is open. Their words change only as this section says.

### 1. Back

- The system's Back button, named for where it goes, such as "Library" or "Fiction".
- It goes back with the book still playing. So does the two-finger scrub.
- Focus then lands on the book's row (see "Focus on arrival and return").
- Going back doesn't close the book. It stays open behind the Continue row. It closes when another book opens, when it's removed from the library, or when the app is killed.

### 2. The title

- The navigation title: the book's title, with VoiceOver's heading trait. The Mac's "Book: Moby-Dick by Herman Melville" is a window's title; here the screen shows only "Moby-Dick". A book read from the Reading List reads "Reading List: Moby-Dick", the Mac's prefix.
- A cold reopen at launch (see "Coming back the next day") says the title once, with low priority, after VoiceOver has read Play, since nothing else has said which book this is.

### 3. Book content

The book's text, as the Mac's reader has it just above the playback controls.

- **Element:** a read-only `UITextView`, in the mold of `ReadOnlyTextArea+iOS`. As a text view it gets Lines, Words, and Characters on the rotor, a cursor on a braille display, and panning, without further code.
- **Label:** "Book content", the Mac's.
- **Value:** the passage: up to 20,000 characters (the Mac's limit, `maxDisplayChars`) of the chapter, **starting at the start of the sentence at the reading position**. The Mac centers its text around the place, since it has no way to scroll VoiceOver to it. On the phone, the first thing read is the place, so a person who pauses and flicks to it hears the sentence just spoken. It keeps whole words at its end, using the same rules as `VisibleTextWindowPolicy` at that edge.
- **Hint:** none.
- **Traits:** static text. Text context `.narrative`, and the book's language if it's known.
- **Actions:** none, or VoiceOver would say "Actions available" after it.
- **When the text changes, by `PhonePassagePolicy`:**
  - when the book has loaded;
  - when the book pauses or stops: the passage then starts at the sentence just spoken, unless the element has focus;
  - after a move while paused;
  - while the book plays, at most every 10 seconds, **and only while this element doesn't have focus**;
  - when it has focus and the book plays, never: a focused text view must not change under a reader, in speech or in braille.
  - It's always brought up to date when focus leaves it.
- **Reading while the book plays:** VoiceOver reads the passage over the book, ducked or not as the user set. That's the listener's choice, as is a two-finger tap to stop VoiceOver's reading. Nothing pauses by itself.
- **A later "Read All" with two fingers:** with the page-turn trait and `accessibilityScroll`, VoiceOver reads on past the passage's end. While paused, each turn also moves the book's place, so stopping leaves the place there. While the book plays, a turn moves only the passage. Built in the VoiceOver slice, as the first thing to cut if it misbehaves. **Unverified.**
- **An audiobook** has no text unless it's transcribed (its chapters are spaces, and a reader must not show them). With a transcript it shows that, like any book. With none, the element reads: "Book content, this audiobook has no text."
- **Braille:** this is how a braille reader reads the book: label, then the text, with the cursor and panning VoiceOver gives any text view. Speech isn't needed. **A setting to advance the passage as speech goes on, Follow in Braille, is deferred** until a first run shows what a changing text view does on a display.

**The whole-book reading screen is deferred.** Later, a Read Text screen can hold the entire book as a lazy container of paragraph elements (Paperback's design, MIT licensed), so VoiceOver focus itself is the place, flicks move by paragraph, rotors land on real elements, and Read All never runs out. It needs a real run to judge, and it isn't tonight's work. One text element is Apple's documented route with the least code, and it's a real start. It's named under "What's deferred".

### 4. Play

- **Label:** "Play", or "Pause" while the book plays, by the Mac's rule: `isCurrentlyPlaying && !isCurrentlyPaused`. A waiting book counts as playing.
- **Value:** none. **Unverified:** what VoiceOver says after an adjustment with no value. If it repeats "Play" over the book, the fix is in the hand-check list.
- **Hint:** "Moves back or forward by Sentence." naming the unit in force, computed when asked. The hint says what adjusting does, since activating needs no explaining.
- **Traits:** button, adjustable. **Starts a media session in the Play state only.** An Apple engineer's accepted answer says this trait stops VoiceOver speaking "Play button, playing" over the book. After Pause, VoiceOver saying "Play" in the silence confirms it, so the Pause state doesn't have the trait.
- **Activate:** `togglePlayPause()`. While the book is still loading, the press is remembered and the book plays as loading ends, and the value reads "Loading" until then. So the listener never has to find Play twice.
- **Adjust up:** moves forward by the unit in force. **Adjust down:** moves back. Each calls the reader's own skip by unit, `performSkip(unit:forward:)`, directly. The Mac's 0.4-second debounce on `skipForward` and `skipBackward` is for one media key arriving by two paths, and it would drop a quick second flick in silence.
- **Actions:** none.
- **What's said after a move:** see "What a move says".
- **Braille:** "Play" and VoiceOver's marks. Dots 3 and 6 adjust; dots 3-6 activate; the display's magic tap, dots 1-5-6, plays and pauses from anywhere.

### What a move says

One plain type, `PhoneMoveFeedback`, decides, whether the move came from adjusting Play, from a skip button, or from a rotor.

- **While the book plays: nothing,** for any unit. The book, starting at the new place, is what's heard. The shared code's "Next sentence", "Heading: The Battle", "Page 12", and "Bookmark 3" are not posted. They're held back only around the phone's own calls to the reader's moves, and only while it plays.
- **While paused:**
  - **Heading, Subheading:** the Mac's "Heading: The Battle".
  - **Page:** the Mac's "Page 112".
  - **Bookmark:** the Mac's "Bookmark 3".
  - **Sentence, Paragraph, and seconds in a text book:** the first eight words of the new place, as the new words are what a person wants to hear. The Mac's "Next sentence" says nothing useful here. Paperback does the same.
  - **Seconds in an audiobook:** the Mac's clock words, "Moved to 1 hour, 3 minutes, 45 seconds." A skip by seconds on the Mac says nothing, but silence after a paused move looks like a dead control.
- **Nothing that way,** whether paused or playing: "No next heading.", "No previous page.", "No next bookmark.", and so on, with the unit's name in lower case. For a skip by seconds at either end: "Start of the book." or "End of the book." The Mac says nothing here, but a press that does nothing must be told from a press that was missed.
- **A book with no pages:** Page isn't offered. If it's in force from a saved choice, moving says the Mac's "This book has no pages."
- **Every move keeps the Mac's Return place,** when the Mac's does: "Return" goes back to where the last jump began.
- **Auto-play after navigation** does what the Mac's does: with it on, a paused book plays from where a jump from a list lands.

### 5. Navigation unit

- **Label:** "Navigation unit", the Mac's.
- **Value:** the unit's name, the Mac's: "10 seconds", "15 seconds", "30 seconds", "60 seconds", "Sentence", "Paragraph", "Page", "Heading", "Subheading", "Bookmark".
- **Hint:** "Chooses what Play and the skip buttons move by."
- **Traits:** adjustable. It isn't a button, and activating it does nothing.
- **Adjust up:** the next unit in the Mac's order, wrapping around. **Adjust down:** the one before. VoiceOver reads the new value alone. The shared "Navigation unit: Sentence" isn't also posted.
- **What's offered:** the Mac's list, by `navigationUnitChoices(keeping:)`, with these differences:
  - **Sentence and Paragraph aren't offered for an audiobook,** which has no text to stop at. On the Mac they do nothing in silence. A transcribed audiobook is the same for now.
  - Page is left out for a book without pages, as on the Mac.
- **Stored per book,** one unit for both directions. The phone sets the Mac's "One Unit for Both Directions" mode, and doesn't offer the choice. Until a book has its own, it starts at the global Skip Forward choice in Settings.
- **Braille:** "Navigation unit Sentence". Dots 3 and 6 change it.

### 6 and 7. Skip backward, Skip forward

- **Labels:** the Mac's "Skip backward: Sentence", "Skip forward: Sentence".
- **Value:** none. **Hint:** none: the label says it.
- **Traits:** button.
- **Activate:** a move, with what "What a move says" says. It doesn't move focus.
- **This is the one duplicate on the screen, and it's on purpose:** the same move as adjusting Play.
  - Without VoiceOver running, there's no adjusting, so a sighted helper or Voice Control needs a button.
  - With VoiceOver, one double-tap after another is steadier than swipes for some people, and some readers dislike adjustable elements.
  - On the Mac, a key and a button do the same thing too: think of adjusting as Play's keyboard shortcut.
  - It's a question at the end, in case the user prefers them out of VoiceOver's order.

### 8. Speed

- **Label:** "Speed" for a text book; the Mac's "Audio speed" for an audiobook.
- **Value:** the Mac's "200 words per minute" or "1.25 times speed".
- **Hint:** for an audiobook, the Mac's "Changes the speed in steps of 0.1 times". For a text book: "Changes the speed in steps of 25 words per minute."
- **Traits:** adjustable.
- **Adjust up or down:** `adjustSpeed(delta:)` by the Mac's 25 words per minute, from 50 to 650; or `setAudioSpeed(_:)` by 0.1, from 0.25 to 4. It applies to this book, as on the Mac. VoiceOver reads the new value alone: the shared "225 words per minute" isn't also posted.
- **While the book plays,** a change takes effect as the Mac's does. Speech restarts at a natural break, under the rule that speech never switches paths in mid-play.
- **Braille:** "Speed 200 words per minute". Digits, as readers asked of Voice Dream.
- The Mac's tortoise and hare buttons aren't here, which would be duplicates. Pitch is in Voice & Speed.

### 9. Where Am I?

- **Label:** "Where Am I?" While its announcement speaks: the Mac's "Stop Where Am I announcement".
- **Value:** the Mac's status row, computed when asked: "Page 112 of 300, 30.0% through the book, 3 hours remaining at current speed". A finished book: "Finished". The page is left out while Show the page on the reader screen is off, or the book has none.
- **Hint:** none.
- **Traits:** button. Starts a media session, for the same reason as Play: its answer is spoken by the app.
- **Activate:** the Mac's `whereAmI(.brief)`, unchanged: the book pauses, the summary is spoken in the book's voice by the app, and the book plays on, as in "Dune. The Battle. Heading 26 of 412. Page 112 of 300. 30 percent. 3 hours remaining."
- **Actions:** "Where Am I? Full Summary", the Mac's, which is the Mac's `whereAmI(.full)`.
- **Why the app's voice, and not a VoiceOver announcement:** a VoiceOver announcement over the book, or with the Mac's pause and resume timed by a notification that can fail to arrive, is more fragile than one code path already tested. It also works from the lock screen in time. The value above is what braille gets, without pressing anything, and a person who only wants the place can stop at this element.
- **Braille:** the value is the display's place in the book: page, percent, and time, read by landing here. Speech isn't required.

### 10. Add bookmark

- **Label:** the Mac's "Add bookmark", or "Remove bookmark" while the place is near a bookmark, computed when asked.
- **Hint:** none.
- **Traits:** button.
- **Activate:** `toggleBookmarkAtCurrentPosition()`. VoiceOver says the Mac's "Bookmark 3 added" or "Bookmark 3 removed", also while the book plays, since the listener asked. Focus stays. The book goes on.

### 11. Bookmarks

- **Label:** "Bookmarks", the Mac's visible word. **Value:** the count, such as "3 bookmarks", computed when asked, and left out at none.
- **Hint:** "Opens the list of bookmarks."
- **Traits:** button. Opens the Bookmarks sheet, below.

### 12. Headings

- **Label:** "Headings". **Value:** the Mac's "Heading 26 of 412", computed when asked.
- **Hint:** "Opens the list of headings."
- **Traits:** button. Opens the Headings sheet, below.

### 13. Go To

- **Label:** "Go To", the Mac's word on a list row. **Hint:** "Goes to a page, a percent, or a time."
- **Traits:** button. Opens the Go To sheet, below.

### 14. Return

- **Label:** the Mac's "Return to previous reading position".
- **Hint:** the Mac's says "Go back to where you were before browsing headings or bookmarks", which is too narrow here: "Goes back to where the last jump began."
- **Traits:** button.
- **Activate:** `returnToSavedPosition()`, and the Mac's "Returned to previous position". With no place, the Mac's "No previous position to return to." On the Mac this button vanishes with no place to return to. Here it stays, by principle 5.

### 15. Sleep Timer

- **Label:** "Sleep Timer".
- **Value:** computed when asked: "Off", or the Mac's spoken status, as in "4 minutes, 59 seconds remaining", "stops at the end of this heading", or "fading out".
- **Hint:** "Opens the sleep timer."
- **Traits:** button. Opens the Sleep Timer sheet, below.

### 16. Voice, or Audio Settings

- **Label:** the Mac's `BookSettingsWording.buttonTitle`: "Voice" for a text book; "Audio Settings" for an audiobook. The Mac's "Change voice for this book" is its hint here.
- **Traits:** button. Opens the sheet below.

### 17. Book Info

- **Label:** "Book Info". **Hint:** the Mac's "Show book information".
- **Traits:** button. Opens the Book Info sheet.

### The rotors

The second way to move. A person on any of the reader's elements can twist to these, and flick down for the next or up for the previous. They're UIKit's lazy rotors, set on the reader's container or, failing that, on the window, only while the reader is on screen.

- **Headings:** system type `.heading`, so VoiceOver uses its usual heading commands. Moves by heading.
- **Pages:** only in a book of more than one page.
- **Bookmarks:** only in a book with one or more.
- **What it returns, the part only a first run can settle:** a move happens in the search block, and the result names the Where Am I? element, whose value then reads the new place. A flick with nothing that way returns nil, which is VoiceOver's boundary sound.
- **Unverified, and likely to change:** what VoiceOver does when the same element comes back on the next flick. This piece is small and can be removed in a line. If the first run shows silence, the fix to try is a fresh element object that compares equal by unit, which is what Paperback does.
- Rotors aren't offered for sentences and paragraphs: adjusting Play is the way, with Sentence or Paragraph chosen.
- The rotor flick says what a move says, and it's the same whether adjusting or twisting.

### While the book is loading, or can't load

- **Loading:** the screen is whole from the start: every element is in its place, and Play's value reads "Loading". The Mac's "Loading book..." is shown. Book content's value reads "Loading Moby-Dick", the Mac's words. Nothing is announced unless it takes more than 5 seconds; then the low-priority "Loading Moby-Dick" is said once.
- **A book that can't load:** Play and all the moving controls are replaced by the Mac's `ReaderLoadFailureView`, "Failed to load book" and the reason, as one element, and focus moves there. Back goes on working.
- **Errors while playing:** the Mac's `ReaderErrorAlert`, with "Retry", "Try Again", "Cancel", and "OK". Focus goes to the alert. When it closes, focus returns to Play.
- **Speech stops because the engine refused a passage:** the Mac's "Speech Stopped" sheet, with its Details text area, Copy Details, and Close, and its words made iPhone's (see "Words that say Mac"). Show Logs in Finder isn't there.

### The Bookmarks sheet

A sheet, with a `NavigationStack`. VoiceOver's order:

1. **Title:** "Bookmarks", a heading, where focus lands.
2. **Done:** toolbar button, the Mac's word. Closes the sheet.
3. **Add Bookmark:** toolbar button. Label: the Mac's "Add bookmark at current position". It opens the Mac's Add Bookmark sheet, with "Note (optional)", "Cancel", and "Add".
4. **The list,** in the Mac's `listOrder`, the order they lie in the book:
   - Label: the Mac's, "Bookmark 3, The Battle, Note: Check this, added October 9, 2026".
   - Hint: "Goes to this bookmark and closes the list."
   - Actions: "Edit Note", "Delete".
5. **Empty:** the Mac's "No bookmarks yet." and "Add Bookmark adds one at the current position."

Choosing a bookmark closes the sheet, and calls `navigateToBookmark(_:)`, with the Return place kept. Focus returns to the Bookmarks button, and a move's rule applies: paused, "Bookmark 3"; playing, nothing. After a delete, focus goes to the next row, or the row before, by the Mac's `focusTarget(after:in:)`.

### The Headings sheet

A sheet, with a `NavigationStack`. VoiceOver's order:

1. **Title:** "Headings", a heading.
2. **Back to Book:** toolbar button, the Mac's, with its hint.
3. **Show levels:** a row opening `PhoneChoiceSheet`, the Mac's filter: "All levels", "Level 1", "Levels 1 to 2", and so on. Its hint is the Mac's "Shows only the headings up to the level chosen."
4. **Display:** a row opening `PhoneChoiceSheet`. Label: the Mac's "Heading info display mode". Choices: "Duration", "Time In", "Percentage".
5. **The list,** one row for each heading:
   - Label: the Mac's: "The Battle (current heading) - level 2, 1 hour, 3 minutes". "Skipped, " starts a skipped section's row.
   - Hint: the Mac's "Goes to this heading and closes the list."
   - Actions: the Mac's "Skip Section" or "Include Section".
6. **Empty:** the Mac's "No headings found in this document."

On arrival, the sheet first scrolls so the current heading's row is visible, and the Heading Levels rotor is the Mac's. Choosing a heading works like choosing a bookmark, and says "Heading: The Battle" if paused.

### The Go To sheet

The Mac's three panels, in one sheet. VoiceOver's order:

1. **Title:** "Go To", a heading.
2. **Cancel:** toolbar button, the Mac's. Closes it.
3. **"Page",** a field, only in a book of more than one page.
   - Hint: the Mac's, "This book has 300 pages, from i to 300. Type a page as the book numbers it, such as 12 or xii."
   - It starts at the page being read. Keyboard: numbers and punctuation, since a page can be xii.
4. **Jump:** a button after that field, the Mac's word. Label: "Jump to page".
5. **"Percent through the book",** a field. Hint: the Mac's "Type a percent from 0 to 100, such as 47.5." A decimal pad.
6. **Jump:** Label: "Jump to percent".
7. **The time field:** the Mac's "Time in the recording" for an audiobook, or "Time at 500 words a minute" for a text book. Hint: the Mac's "Type a time, such as 12:04.3, 1:02:03, or 75.5." Numbers and punctuation.
8. **Jump:** Label: "Jump to time".

- Each field works as the Mac's: `goToPage(typed:)`, `goToPercent(typed:)`, `goToTime(typed:)`. A field left at its starting value and jumped from closes without moving, as on the Mac. The keyboard's Go key is the same as Jump.
- A refusal stays on the sheet: under the field, as the Mac's "Error: There is no page 400 in this book. Its pages run from i to 300.", and announced once. Focus stays in the field.
- A jump closes the sheet, focus returns to Go To, and VoiceOver says the Mac's "Jumped to page 12.", "Jumped to 47.5 percent.", or "Jumped to 1 hour, 3 minutes, 45 seconds in the recording.", once the sheet has closed, also while playing, since it was asked for and names a place the book's words might not.

### The Sleep Timer sheet

The Mac's `SleepTimerView`, with its wording, in a `NavigationStack`. VoiceOver's order:

1. **Title:** "Sleep Timer", a heading.
2. **Close:** toolbar button, with the Mac's hint.
3. **Current Timer,** when one runs: a heading, then its status (the Mac's `spokenLabel`, computed when focused), then the Mac's "Reset Timer" and "Cancel Timer".
4. **New Timer:** a heading, then the Mac's "Setting a new timer replaces the current one." when one runs, and "Pause playback after:".
5. **The presets:** 10, 15, 30, 45, and 60 minutes. Label: the Mac's "Set timer for 15 minutes and start playing".
6. **Custom:** "Custom timer minutes", a number-pad field; "Adjust minutes", a stepper by 5; and "Set".
7. **Stop At:** a heading, then the Mac's "End of heading" and "End of book", each with its label and hint.

- The hint "Return sets the timer" is the Mac's, and has no meaning on a phone: "Type the minutes, or change them 5 at a time with Adjust minutes. Set sets the timer and starts playing."
- The Mac's setting Close sheet after setting timer applies. On closing, focus returns to Sleep Timer. VoiceOver says the Mac's "Timer set for 15 minutes." once the sheet has closed.
- **How it counts on a phone:** see "The sleep timer on a phone". Its milestones (5 minutes, 1 minute, 30 and 10 seconds) are the Mac's, with low priority, and may be lost in the background.

### The Voice & Speed sheet

The Mac's `BookVoicePickerView`, for a text book. Title: the Mac's "Voice & Speed for This Book". VoiceOver's order:

1. **Title,** a heading. **Close,** a toolbar button.
2. **Language:** a row opening `PhoneChoiceSheet`. The Mac's "Voice language filter".
3. **Voice:** a row opening `PhoneChoiceSheet`. Label: the Mac's "Select voice for this book". Each choice's label: "Samantha, Enhanced quality". A Personal Voice isn't listed, since it can't be rendered.
4. **Preview Voice:** the Mac's "Preview selected voice".
5. **Speed:** the Mac's slider, "Speed", with the value "200 words per minute".
6. **Pitch:** the Mac's slider, "Pitch", with the value "Normal (1.0x)".
7. **When this book ends:** a row opening `PhoneChoiceSheet`. Label: the Mac's "End of book behavior for this book". With a choice of its own: the Mac's "Use Global Default".
8. **Save to Global Settings,** and **Reset to Global Settings,** the Mac's.

- The Speed slider here is the same setting as the reader's Speed element, as on the Mac, where this sheet's slider and the playback bar's buttons are one setting too.
- The voices are the iPhone's own, downloaded in Settings. An empty list says: "No voices are installed. Add voices in Settings, Accessibility, Read & Speak." **Unverified:** the path's wording on the phone.
- For an audiobook, the sheet is the Mac's Audio Settings for This Book: "Audio speed", When this book ends, and "Reset to Normal Speed".

### Coming back the next day

- **The app is still running, or was suspended:** it comes back as it was. A reader that was on screen is on screen, with focus restored only after a true background.
- **The app was killed:** at launch, if a book was open (its ID is kept in preferences while it's open, and cleared when another opens or the listener deletes it), the Library's top appears with the reader pushed over it, paused at the saved place. VoiceOver lands on Play, then says the book's title with low priority.
- A magic tap, or a remote Play if the system lets it through, plays from there. So the next day's first act can be a single gesture.
- The saved place loses at most 30 seconds of a kill: a checkpoint runs every 30 seconds of play, and every pause, stop, and move to the background saves and flushes.

## Listening with the screen locked

### The audio session

- **Category and mode:** `.playback`, `.spokenAudio`, no options. It keeps playing with the silent switch on and with the screen locked (with the `audio` background mode), and a navigation app's prompt pauses the book and hands it back, rather than talking over it. Apple names podcast players and audiobooks for this mode.
- **No options, because each costs something.** `.mixWithOthers`, `.duckOthers`, and `.interruptSpokenAudioAndMixWithOthers` all make the session mixable, and a mixable session can't be the Now Playing app. Bluetooth output to AirPods is implicit in `.playback`.
- **Set the category at launch,** which interrupts nothing. **Activate at Play,** whether from the button, the magic tap, a remote command, or the next book, never earlier, or opening a book would stop the user's music.
- **Stay active** through chapter changes, gaps, seeks, fades, and a pause in the foreground.
- **Deactivate,** with `.notifyOthersOnDeactivation`, after stopping audio, when: entering the background while paused; a sleep timer expiring in the background; a book ending with nothing to follow; the book being closed; or Release Media Controls.
- **Activation blocks,** and Apple says not to do it where blocking would hurt. The first version activates on the main thread at Play, since `play()` is synchronous in shared code, and it logs how long it took. **Unverified:** whether that's ever long enough to hear.
- **VoiceOver's ducking isn't the app's to set.** No API touches it. It's the user's setting, under VoiceOver, Audio, Audio Ducking. The app's guide says so.
- `AVSpeechSynthesizer.usesApplicationAudioSession` stays true, and `prefersAssistiveTechnologySettings` stays false, so the book reads in the voice chosen for it.

### Which speech path

- **The Mac's policy, unchanged:** direct `AVSpeechSynthesizer` speech at Play, the render into `AudioEngineService` behind it, and the engine from the next natural break. The user's rule is that speech never switches from direct to engine in mid-play, and this keeps it.
- **Three additions, on iOS alone:**
  - If finished rendered audio for the chapter is ready at Play, start on the engine, so nothing switches at all.
  - A word-progress watchdog: playing, not paused, and no word reported for several seconds means nothing is being heard, so it's a natural break, and it recovers at the last reported word.
  - No Personal Voice in rendering, since `write` can't take one and would play it aloud.
- **The biggest open risk on the phone:** one report (October 2026, unanswered) says direct speech pauses at the screen lock and resumes at unlock. If the first run confirms that, iOS goes engine-only, with a streaming feeder, which still never switches. **This is check 1.**

### What pauses and what resumes

One plain type, `PhoneAudioEventPolicy`, decides, and a small iOS file observes:

- **An interruption begins** (a call, an alarm, Siri, a navigation prompt): the book counts as paused where it stopped, and the place is saved. Speech isn't told that the engine refused the text: a cancel the app didn't ask for during an interruption is flagged, so `SpeechService` doesn't read it as a refusal.
- **An interruption ends with `shouldResume`:** the book plays on. Without it, it stays paused until Play. Any Play tries to activate again, since an end isn't guaranteed.
- **`.oldDeviceUnavailable`,** headphones out or AirPods gone: pause through the Mac's own `pauseForAudioRouteChange()`, so the Mac's rewind on resume applies. **`.override`** does nothing. **`.newDeviceAvailable`** invalidates the backend only, so the next Play starts cold on the new output.
- **`AVAudioEngineConfigurationChange`:** the engine stops itself. The same invalidation, and a natural break: playback goes on from the place, or else the engine's silence could be read as the chapter's end.
- **`mediaServicesWereReset`:** rebuild the audio objects, set the category again, and show the book paused at its place, with no automatic restart.
- **AirPods out of one ear:** what arrives is expected to be a remote Pause and later a remote Play. These work as they are. **Unverified:** the exact order and reasons, which get logged at the first run.
- **Each handler is idempotent,** since a disconnect gives both an interruption and a route change, in an unstated order.

### The lock screen, Control Center, and AirPods

- **What's shown** (the system's choice of layout, the app's choice of words):
  - Title: the book's title. Artist: its author. Album: the heading being read.
  - Rate: the speed in use, or 0 when paused; default rate the same speed.
  - For an audiobook, elapsed time and duration in the chapter. For speech, neither at first, since any figure would be an estimate.
- **Commands,** by `PhoneRemoteCommandPolicy`:
  - `playCommand`, `pauseCommand`, `togglePlayPauseCommand`: as on the Mac.
  - `nextTrackCommand`, `previousTrackCommand`: skip forward and backward by the book's navigation unit, as on the Mac. These are reported to be what the AirPods' double and triple press send.
  - `skipForwardCommand`, `skipBackwardCommand`: enabled only when the unit is a number of seconds, with `preferredIntervals` set to that number; disabled otherwise, so that the lock screen never promises 15 seconds and moves a heading. The Mac's fixed 30 and 15 stay on the Mac.
  - `changePlaybackPositionCommand`: an audiobook only, within the chapter. Optional in the first version.
  - All others stay disabled.
- **Registered at launch,** so a killed app that the system wakes for a Play can answer: the handler opens the book last open, and plays it. **Unverified:** whether a non-mixable session can activate there. Podcast apps resume from the lock screen every day, and nothing found explains how.
- **The Mac's Release Media Controls** isn't in the first version's reader. A later menu can have it. The session and command handling are written so it can be added.
- **VoiceOver on the lock screen:** the system's labels on the system's buttons. The app controls only the words above. **Unverified.**

### The sleep timer on a phone

- The Mac's timer counts ticks of a repeating timer, and a tick that's late is lost. On iOS it holds a deadline, a `ContinuousClock` instant, set at start and at each resume of the countdown, and each tick computes what's left from it. The rule that the countdown halts when the book pauses stays, so nothing needs to fire during a suspension, which only happens when nothing's playing.
- On any return to running, the deadline is checked first, and an expired timer expires at once, saying the Mac's "Sleep timer expired. Playback paused."
- An expiry in the background is wrapped in a background task: fade, pause, save, flush, deactivate.

### Silent gaps

A chapter pause, the wait for the next book, and speech being prepared all have no audio running, and iOS can suspend an app with no audio almost at once. So one iOS helper begins a named background task as audio ends, and ends it when audio starts or the work gives up. That's Apple's advice: "Use a background task instead of streaming silence." It lasts about 30 seconds, and a manifest pause longer than that is a known limit in the first version. **Unverified:** how soon suspension comes.

### Saving

- **At the move to the background:** a background task around `UnsavedChangesTerminationGuard.flushPendingWrites()`. A book playing in the background is still being listened to, so its listening session goes on.
- **At each pause, stop, and interruption, and at a memory warning:** `savePosition()`, and a flush if not in the foreground.
- **While it plays:** the Mac's checkpoint every 30 seconds, which reaches the book's record at once.
- **When a reader opens:** the book's ID in preferences, for coming back.

### Memory

- The Mac's memory guard acts at 3 GB and 6 GB, and jetsam acts first on most iPhones. On iOS it reads `os_proc_available_memory()` instead: under about 150 MB while playing, it stops the book, saves, and says why. It never quits.
- Before a look-ahead render, it wants about 300 MB free, or it skips the render. At `.serious` or `.critical` thermal state, it skips them too. At a memory warning, it drops the look-ahead audio and `ReadingTextCache`, and saves.
- These thresholds are guesses until the phone is measured. No figure for the limit is published, and reports range from about 900 MB to 5 GB.

## Importing

### Adding a book

The Add to Library sheet, in a `NavigationStack`. VoiceOver's order:

1. **Title:** "Add to Library", a heading, where focus lands.
2. **Cancel:** toolbar button.
3. **"Open Book…"** a row, the Mac's word. Its summary is the Mac's "Opens a file picker to import books in any format TextMouth reads."
4. **"Import Folder…"** a row. Its summary is the Mac's "Chooses a folder that holds a DAISY book or audio tracks and imports it as one book."

Later items, as they arrive: New from Text…, Add Feed…. New Recording… isn't offered.

- Each opens SwiftUI's `fileImporter`, with the Mac's `FileImportService.supportedTypes` (the first with multiple selection; the second with `.folder`). The system's picker is VoiceOver-accessible by Apple's own design.
- **The picked URLs are security-scoped and may not be downloaded.** So one iOS step runs first: hold them until the library has started; start the scope; copy under `NSFileCoordinator` on the import queue, with progress, into import staging; stop the scope; and hand the local copy to the shared `importFiles(urls:toFolder:from:addingToReadingList:)`. Nothing reads a picked URL plainly. `UIDocumentPickerViewController` with `asCopy` isn't used: Apple's engineer called its truncated copies a bug.
- Books go in the folder the Library showed last, as on the Mac.
- **After the import:** focus stays where it was, and VoiceOver says the Mac's "Finished importing “Dune”." with low priority. The book's row is in the list.

### From Mail, Safari, Files, and Messages

- **No share extension in the first version.** Reports say document types are enough to put the app in the share sheet for a file in Mail or Files. Photos need an extension, and Messages isn't covered by any source. **Unverified.** An extension would cost an App ID, an app group, and much lower memory, and it's poor for a 2 GB audiobook.
- `CFBundleDocumentTypes` lists the Mac's formats less those iOS refuses (Ogg and other converted audio, CAF, and the three braille formats), so no app offers TextMouth a file it would refuse.
- A URL arriving through `scene(_:openURLContexts:)`, or `connectionOptions.urlContexts` at a cold launch, takes the same path as a picked file, after the library has started, then `importAndOpenFiles(urls:from:)`, so the book opens with focus on Play.
- A copy in `Documents/Inbox` is removed after the import, and the Inbox is swept at launch and on each return to the foreground. The question about deleting the original isn't asked for a copy in the Inbox.
- A file arriving during another import waits in `SerialImportQueue`.

### Progress

- **The Mac's overlay:** `ProgressOverlay`, with `ImportProgressWording`: "Importing Books", "Book 2 of 10: “Dune”, Reading its text", "About 3 minutes left", and the Mac's Cancel Import. It's a card at the top of the Library's list, not a modal, so everything goes on working around it.
- **VoiceOver order:** after the title and toolbar, before the Continue row. Its label and value read the state at the moment VoiceOver asks. It announces nothing as it moves; every line is there to be read.
- **Going to the background:** each import runs in `beginBackgroundTask`, about 30 seconds, more if a book is playing. A suspended import resumes where it was. A killed one leaves only a hidden staging folder, which is cleared at launch. `ImportStaging` publishes by one rename, so there's never half a book.
- **Coming back:** VoiceOver says, with low priority, what happened while away. Its name is kept in a small file while an import runs, so a killed import can be named at the next launch: "Importing “Dune” was stopped when TextMouth closed. Add it again."
- **`BGContinuedProcessingTask`** is the better tool for a long import, in iOS 26, with a Live Activity. It comes after the basics have run.

### Import questions

- On iOS the Mac's presenter never shows a question: `ImportOrigin(window:)` is always nil, so a duplicate would wait for ever. The phone presents `library.importDecisions.current` itself, in the Mac's `ImportDecisionSheet` with `takesFocus: true`, and answers with `answerImportDecision(_:with:)`.
- The Mac's three buttons in a row become a vertical list, with the Mac's words and hints: "Keep Both", "Replace Existing", "Cancel"; and "Create Folder", "No Thanks".
- The sentence "The existing copy's files go to the Trash" becomes: "The existing copy's files are deleted."

### What can't be imported, and what it says

- **Audio that needs converting** (Ogg, Opus, AC-3, AMR, MP2, CAF): the Mac's sentence, "Converting this kind of file is not available on iPhone yet." So an Ogg book needs the Mac for now.
- **Word 6 and Word 95:** the same sentence.
- **Braille books (BRF, BRL, PEF):** "Reading braille files is not available on iPhone yet." On iOS the translator's helper is missing, and without this refusal the wording would mean nothing.
- **An M4B, M4A, or MP4:** these must import. The iOS stand-in for `WatchedProcess.runCapturingOutput` answers "could not start" rather than throw, so the file is left as it is and played by `AVPlayer`. A protected M4B says so at Play, as the Mac's failure sentence does.
- **Any other failure:** the Mac's "Could not import “Dune”. Reading its text failed: …", in an alert titled "Nothing Imported", with OK.

## Errors, empty states, long operations

- **The library is empty, at first launch:** after the toolbar, one row: "Your library is empty. Add to Library adds a book." with the rest of the list absent. Focus lands on the title as usual.
- **An empty folder:** the section heading "Books (0)", then a row: "This folder is empty."
- **No matches in search:** a row, "No books match.", and it's said once with low priority.
- **A library that can't be read or found:** the phone's library is in its own container, so this should be rare. The Mac's `DataDirectoryUnavailableText` without its Quit button or its advice on choosing another folder, and with the Mac's Try Again.
- **Saving fails, such as on a full disk:** the Mac's `PersistenceFailureBanner`, "Storage problems", with Retry and Dismiss, at the top of the Library's list.
- **Reading the library's text again at launch** (after an update): the Mac's overlay, "Extracting Text", as a card like the import's.
- **A very long book opening:** see "While the book is loading".

## Settings

A pushed `Form`, with real section headings. On the phone: fewer settings than the Mac, and the same words for each. Everything here is a `SettingsViewModel` property the Mac has, and each change takes effect as on the Mac.

### VoiceOver's order

**Voice:**

- "Language", label "Voice language", a row opening `PhoneChoiceSheet`, with "All".
- "Voice", label "Select voice", hint "Choose a voice for reading. Change takes effect immediately.", a row opening `PhoneChoiceSheet`.
- "Preview Voice", label "Preview selected voice". It speaks the Mac's "Hello! This is TextMouth, ready to read for you."
- "Default speed", a slider, value "200 words per minute". Caption, as the hint: "Default speed for new books. Each book can override this with its own speed."
- "Default pitch", a slider, value "Normal (1.0x)". Caption, as the hint: "Default pitch for new books. 1.0 is normal. Each book can override this."

**Skip Controls:**

- "Skip Forward", label "Skip forward unit", hint "What happens when you skip forward", a row opening `PhoneChoiceSheet`. This is the global unit, which a book starts with until it has its own.
- "Skip Backward" is the Mac's second choice. On the phone, one unit serves both directions, as the reader has it, so it isn't shown. See the questions.

**Rewind on Resume:**

- "Rewind to", label "Rewind on resume unit", hint "When resuming playback, rewind to the start of this unit": "None", "Sentence", "Paragraph", "Heading".
- "Smart mode", label "Smart rewind mode", hint "Only rewind if the pause was longer than the threshold".
- "Minimum pause threshold", a stepper, value "70 seconds". Hint: "Don't rewind if paused for less than this."

**Punctuation Pauses:**

- "Punctuation pause level", a stepper, value "Off", "Subtle", "Moderate", or "Heavy". Hint: the Mac's caption, "0 = Off, 1 = Subtle (periods), 2 = Moderate (+ commas), 3 = Heavy (+ paragraph breaks)".

**Navigation:**

- "Auto-play after navigation", a switch. Hint: "When enabled, playback starts automatically after jumping to a heading, bookmark, or search result".

**End of Book:**

- "When book ends", label "End of book behavior", hint "What happens when a book finishes playing", a row opening `PhoneChoiceSheet`: "Stop", "Stop, and Play Starts Over", "Loop to Start", "Continue to Next Book". Its caption is the Mac's: "With "Stop", Play on a finished book says it is finished; with "Stop, and Play Starts Over", Play starts it again from the beginning."

**Sleep Timer:**

- "Fade out duration", a stepper, value "Off" or "5 seconds". Hint: "Gradually reduce volume before pausing when the sleep timer expires. 0 pauses instantly."
- "Close sleep timer sheet after setting a timer", a switch. Hint: "When off, the sheet stays open showing the remaining time and a reset button".

**Times:**

- "Include the speed with time left and total time", a switch, with the Mac's hint.

**Pages:**

- "Show the page on the reader screen", and "Say the page in Where Am I?", switches, with the Mac's hints.

**Removal Behavior:**

- "Confirm before removing a book", a switch.

**Statistics:**

- "Reading Statistics", a row that pushes the Mac's `ReadingStatsView`, unchanged: "Today", "This Week", "All Time", "Current Streak", "Books Finished This Year", "Books Finished All Time", "Recently Finished".

**About:**

- "Version", a static row, such as "0.4.0".
- "Share Logs…", a button, the iOS share sheet with the app's recent log text. Without this, a first run on a phone can't be diagnosed. Hint: "Shares TextMouth's recent logs as a text file. They hold no book text."

### What the phone leaves out, and why

- **Keys:** the Shortcuts tab, Shift+Skip units, and double-press time. A phone has no keys yet.
- **Mac windows:** Open the next book in, and the reader toolbar and bar choices. A phone has one screen of its own. These settings are set once by the app and not shown: Navigation unit controls at One Unit for Both Directions.
- **Storage:** the data directory, moving a library, Library Maintenance, and the logs' location. The container is the place.
- **Removal:** Move to Trash instead of deleting is off, and hidden, since a phone has no Trash a person can open. After Importing a Book stays Keep Original, and hidden, since the phone copies a file from Files. Keep originals of converted audio: nothing converts on iOS.
- **Bluetooth monitoring, and the restart gesture:** a Mac's daemon, and a later wish.
- **Sounds:** `/System/Library/Sounds` is a Mac folder, so the Mac's Play and Pause sounds don't exist on iOS, and the tab would offer only "None". See the questions.
- **Later features:** the Braille, Feeds, Text, and Library tabs, Transcription, and Audio Editing. Their defaults still act, so the shipped substitution rules apply to speech.

## One vocabulary

### The rule

- A word the Mac has is the word the iPhone uses. Shared wording types are called, not copied: `ReaderPageWording`, `ReaderTimeWording`, `EndOfBookWording`, `ImportProgressWording`, `ImportDecisionWording`, `CountWording`, `LibrarySortState`, `BookSettingsWording`, `Bookmark.accessibilityLabel`, `HeadingNavigatorView`'s statics, `SleepTimerDuration`, and `ReaderViewModel`'s own functions.
- A Mac word that sits inline in a Mac view is held in `PhoneVocabulary` for the phone, and the Mac's view stays as it is. A test, `PhoneVocabularyTests`, reads the Mac's source file and requires each such word to be there word for word, so the two can't drift apart unnoticed.
- A word the phone needs that the Mac doesn't have is in `PhoneReaderWording`, or the like, and it's in this spec. It's a full, plain sentence.

### New words, in one place

- "Settings", "Opens TextMouth's settings."
- "Chooses what the Library lists.", "Chooses the order of the books."
- "Now Playing: Emma", "Plays or pauses Emma."
- "Moves back or forward by Sentence.", "Chooses what Play and the skip buttons move by.", "Changes the speed in steps of 25 words per minute."
- "Opens the list of bookmarks.", "Opens the list of headings.", "Goes to a page, a percent, or a time.", "Opens the sleep timer.", "Goes back to where the last jump began."
- "Go To", "Jump to page", "Jump to percent", "Jump to time".
- "No next heading." and its kin, "Start of the book.", "End of the book."
- "Off", for a sleep timer not running.
- "Book content, this audiobook has no text."
- "Your library is empty. Add to Library adds a book.", "This folder is empty.", "No books match.", "The reading list is empty. To add a book, choose Add to Reading List from its actions."
- "This deletes the book and its files from this iPhone, and they can't be recovered. Your Mac's library isn't touched."
- "Reading braille files is not available on iPhone yet."
- "Importing “Dune” was stopped when TextMouth closed. Add it again."
- "Share Logs…", "Shares TextMouth's recent logs as a text file. They hold no book text."

### Words that say Mac

Each of these is shared, and each has a test pinning it on the Mac. Each gets an iOS branch that leaves the Mac's text as it is:

- "Speech stopped: the Mac's speech engine refused this text." becomes "Speech stopped: the speech engine refused this text."
- The Speech Stopped sheet's "The Mac's speech engine refused…" becomes "The iPhone's speech engine refused…", and its report's "macOS" lines become "iOS". "Details are in the book's window." becomes "Details are on the book's screen."
- "if it stops again, quit and reopen TextMouth" becomes "if it stops again, close TextMouth from the App Switcher and reopen it".
- "a fault in macOS's audio" becomes "a fault in the system's audio".
- Empty Bookmarks: "Add Bookmark adds one at the current position.", by passing no keys, as the Mac's function allows.
- The custom timer's "Return sets the timer" (see the Sleep Timer sheet).
- The Reading List's "the Library menu" and "dragging".
- "Trash" throughout `RemovalWording`, `ImportDecisionWording`, and `OriginalFileDeletionWording`: the phone uses only the delete mode and its words.
- "Show in Finder", "Kept on this Mac", and "this Mac": cloud notes never appear, since the phone's library is local.

## What's deferred, and how it fits later

- **The whole-book Read Text screen,** with VoiceOver focus as the place. It's a second element under the reader's Book content, or a screen pushed from it, and the reader's controls stay.
- **Follow in Braille,** advancing the passage during speech.
- **Sounds,** once the user decides which.
- **Search in Book:** `BookSearchModel` is shared. A sheet, and a button after Headings.
- **Next and Previous in Folder and in Reading List:** two more buttons in the reader. **Speak Info.** **Edit Mode** for many books at once. **The Reading List's options.** **Folder Settings.** **The view editor.**
- **Feeds:** the engine is shared. Downloads need background `URLSession`, and refreshing needs a background task. A Feeds view returns in the Library view's choices.
- **Transcription:** `SpeechAnalyzer` exists on iOS 26. A long job as a `BGContinuedProcessingTask`.
- **Export:** the shared writers, through `fileExporter`.
- **Editing text:** an editor of the app's own, since iOS has no round trip through another app. The New from Text view is a start.
- **Braille books:** liblouis in the app, on one serial queue, if the user wants it (question 7 of November 3).
- **Recording, and the audio editor:** a last phase, suiting an iPad first.
- **A library shared with the Mac,** or just places shared: question 3 of November 3.
- **Ogg:** a later decoder of Xiph's, never Apple's inside the app.

## How it fits an iPad

- The first version runs on an iPad as it is, as a compatible layout: the one navigation stack in the full window, and sheets as form sheets. No code assumes an iPhone's width: lists and forms size themselves, and the reader's controls sit in a centered column of limited width.
- **Later,** a `NavigationSplitView` puts the Library beside the reader. iPadOS windows can give each book its own, as on the Mac, with `openWindow`. Then the "one reader" rule loosens to `PhoneSession` per scene, and Mac-style commands appear in the iPadOS 26 menu bar with keyboard shortcuts from the Mac's list. `MagicTapWindow` works per scene already.
- **Nothing in the first version's order changes on an iPad,** since it's the same screens.

## The map to the code

`Scripts/agents/briefs/2026-11-07/iosui-research/research-code.md` has every function with its file and line. This section says how the new code sits on it.

### Where the new code goes

- **`TextMouth/Phone/`:** plain types, compiled into both apps, tested by the Mac's test host, importing no UIKit. Only the iPhone's views and their tests use them, so they're the same kind of change phase 0 allowed: new shared code the Mac never calls.
- **`TextMouth/Platform/iOS/`:** SwiftUI views and everything that names UIKit, AVAudioSession, or another iOS-only API. Nothing here can be tested tonight. Views stay thin.
- **`iOSApp/`:** new, top level, outside the source folder: `Info.plist`, and later the icon and any sounds.
- **Shared files:** changes only behind `#if os(iOS)`, each named in a report.

### The app's frame

- **`TextMouthAppDelegate`:** `@main`, `UIResponder`, `UIApplicationDelegate`, in `Platform/iOS/App/`. It replaces the placeholder `TextMouthIOSApp`. `application(_:configurationForConnecting:options:)` names `TextMouthSceneDelegate` as the delegate class. It sets the audio category at launch.
- **`TextMouthSceneDelegate`:** creates `MagicTapWindow(windowScene:)`, whose root is a `UIHostingController` holding `PhoneRootView`. It handles `scene(_:openURLContexts:)` and `connectionOptions.urlContexts` for files, and `sceneDidEnterBackground`, `sceneWillEnterForeground`, and `sceneDidBecomeActive` for the life cycle. These are UIKit's documented calls, so SwiftUI's `scenePhase` and `onOpenURL` aren't used.
- **`PhoneAppModel`:** `@MainActor`, shared, in `TextMouth/Phone/`. It's made once at launch, in the Mac's order: `LibraryViewModel()`, `SettingsViewModel()`, `SoundEffectService()`, and `PhoneSession`.
- **`PhoneRootView`:** `NavigationStack` over `PhoneLibraryView`, and the app-wide presentations: errors, import questions, removal, and progress.

### `PhoneSession`, the owner of the reader

A shared `@MainActor` `ObservableObject`, with tests on the Mac:

- Holds `reader: ReaderViewModel?`. Makes it with `BookReaderWindowView.makeReader(...)`, which is `static` and has no view in it. Sets `soundEffectService` at once. Calls `markBookOpened`.
- **`open(_ book:)`:** if this book's reader exists, shows it. Otherwise closes the old one and makes the new. `close()` is final, and is in no `onDisappear`.
- **`togglePlayPauseFromAnywhere() -> Bool`:** the magic tap and the remote commands' fallback.
- **Listens to `.continueToNextBook` and `.openBookWindow`,** which only the Mac's `AppDelegate` starts today. Without this, Continue to Next Book says "Starting: Dune" and nothing starts. `windowStanding` is `.noWindow` on iOS, so `showNextBook` takes that path by itself.
- **Publishes a small snapshot:** title, whether it's playing, whether it's loading. Views never observe the reader directly, or they'd redraw 8 times a second while playing and hurt VoiceOver. Like the Mac's `ReaderSnapshot`.
- **Remembers the open book's ID,** for coming back the next day.
- **Sets `library.readerOpener`,** for imports that open.

### Paths

- `TextMouthRuntime.realHomeDirectory`, under `#if os(iOS)`, returns `NSHomeDirectory()`. It reads `getpwuid` today, on purpose, to avoid sandboxes. On a phone that names `/var/mobile`, and in the Simulator the user's **real** `~/.TextMouth`. So this comes first, before anything runs.
- `TextMouthPaths.defaultRoot(in:)`, under `#if os(iOS)`, is `Library/Application Support/.TextMouth`. It's not `.TextMouth` at the container's top, which isn't writable, and not `Library/Application Support/TextMouth`, which the legacy migration reads as an old library.
- Hidden from Files, because `library.json` and the book packages mustn't be touched by a stray flick. Backed up, but see the questions on audiobook audio.
- `Book.filePath` is absolute, and a free team's reinstall every 7 days moves the container. `repairStaleFilePaths` heals a book at launch. Feed items don't, and aren't in the first version.

### The Mac's views: what's used

- **Used as they are:** `ReaderLoadFailureView`, `ReaderErrorAlert`, `HeadingRow`, `BookmarkRow`, `OperationFailureNotice`, `SheetWorkIndicator`, `ProgressOverlay`, `PersistenceFailureBanner`, `ReadingStatsView`.
- **Used with a Mac-only frame:** `ImportDecisionSheet`, `LibraryBookInfoSheet`, `MetadataEditorView`, `SleepTimerView`, and the folder sheets, each with its fixed size moved behind a new helper in `Platform/PlatformControlStyles.swift`, `macOSFixedFrame(...)`, which applies the frame on the Mac alone and has its line in `Scripts/ios/mac-projection.py`. If a sheet needs more than that, it's rebuilt for the phone, calling the same model and wording.
- **Rebuilt for the phone, calling the same model:** `PhoneLibraryView`, `PhoneBookRow`, `PhoneReaderView`, `PhoneBookmarksSheet`, `PhoneHeadingsSheet`, `PhoneGoToSheet`, `PhoneVoiceSheet`, `PhoneSettingsView`.
- **Not used:** `LibraryWindowView`, `LibraryView`, `BookReaderWindowView`, `ReaderView`, `ReaderBookCommandsSupport`, `ReaderPanelCommands`, `SettingsView`, `MenuCommands`.

### The stand-ins that must become real

- `VoiceOverFocus` and its kin: the phone's focus is in `PhoneFocusPolicy` and its views, and the reused Mac sheets that ask for it get it from a sheet wrapper.
- `WatchedProcess.runCapturingOutput`: answers "could not start", so M4B imports.
- `ImportDecisionPresenter`: the phone presents the queue itself.
- `NowPlayingService+iOS`: route and interruption handling. Since `armSuppressAndPauseIfPlaying` and `invalidateRegisteredAudioBackends` are private, the handler needs an `#if os(iOS)` block in the shared file.
- `SpeechService`: the flag for an interruption's cancel, and the word-progress watchdog, under `#if os(iOS)`.
- `SleepTimerService`: the deadline, under `#if os(iOS)`.
- `PlaybackMemoryGuard`: `os_proc_available_memory`, under `#if os(iOS)`.
- `SoundEffectService`: nothing yet. It answers no sound.

### Plain types and their tests

Each is shared, in `TextMouth/Phone/`, with a test class of the same name plus `Tests`:

- `PhoneVocabulary`, `PhoneReaderWording`: the words.
- `PhoneControlDescription`, `PhoneReaderControls`: the label, value, hint, and traits of every reader control, for a given plain state.
- `PhoneNavigationUnits`: what's offered, next, and previous, for text and audio, with and without pages.
- `PhoneMoveFeedback`: what a move says, for each unit, playing or paused, moved or not.
- `PhonePassagePolicy`: where Book content's text starts and ends, and when it may change.
- `PhoneFocusPolicy`: where focus goes after each event.
- `PhoneSession`: open, switch, close, magic tap, next book, reopening.
- `PhoneRemoteCommandPolicy`: which commands, and which intervals, for each unit.
- `PhoneAudioEventPolicy`: what each interruption and route change does.
- `PhoneSleepDeadline`: what's left, from a deadline.
- `PhoneImportHolding`: URLs held until the library has started, and what's done with an Inbox copy.
- `PhoneRowWording`: the Continue row, and search's count.
- `iOSApp/Info.plist` gets a test too, which the Mac can read: `IOSInfoPlistTests` requires the background mode, and that the document types agree with `FileImportService`. `make typecheck-ios` can't see a plist.

## The implementation slices

In order. Each is a branch off `ios/interface`, and is merged only after both type-checks and its tests pass. The train runs its test classes, plus the classes any shared change can break.

### Slice 1: the foundation

- **Does:** `iOSApp/Info.plist`, and `project.yml`'s keys, with the distinct bundle identifier `com.textmouth.TextMouth.iOS`. The two path changes. `WatchedProcess.runCapturingOutput`. The app delegate, scene delegate, and `MagicTapWindow`. `PhoneAppModel` and `PhoneSession`. A `PhoneRootView` that lists books by title, and opens a bare reader with one Play. It's the whole frame, thin.
- **Tests:** `PhoneSessionTests`, `IOSInfoPlistTests`. `make typecheck-mac` shows nothing new for the Mac but the shared files added.

### Slice 2: the Library

- **Does:** the Library's top, folders, views, book rows, folder rows and sheets, search, sorting, the Continue row, removal, Book Info, empty states.
- **Tests:** `PhoneRowWordingTests`, `PhoneVocabularyTests`, `PhoneFocusPolicyTests`.

### Slice 3: importing

- **Does:** Add to Library, the file importer, the coordinated copy, opening from other apps, the Inbox, progress, import questions, refusals.
- **Tests:** `PhoneImportHoldingTests`. The Mac's `ImportDecisionSheetTests` and `ProgressOverlayTests` stay green through the frame change.

### Slice 4: the reader

- **Does:** `PhoneControl`, the 17 elements, what a move says, Book content and its policy, the announcer's iOS rules, loading and failure.
- **Tests:** `PhoneReaderControlsTests`, `PhoneNavigationUnitsTests`, `PhoneMoveFeedbackTests`, `PhonePassagePolicyTests`.

### Slice 5: audio

- **Does:** the session, its activation, interruptions, routes, the engine's configuration change, media reset, Now Playing's words, remote commands by unit, targets at launch.
- **Tests:** `PhoneRemoteCommandPolicyTests`, `PhoneAudioEventPolicyTests`. The Mac's `NowPlayingOwnershipTests`, `MediaCommandPlaybackTests`, and `RemoteMediaCommandPolicyTests` stay green.

### Slice 6: the life cycle

- **Does:** saving at the background, memory, thermal state, silent gaps, the sleep timer's deadline, coming back the next day.
- **Tests:** `PhoneSleepDeadlineTests`, more of `PhoneSessionTests`. The Mac's `SleepTimerServiceTests` stay green.

### Slice 7: the reader's panels

- **Does:** Bookmarks, Headings, Go To, Sleep Timer, Voice & Speed, Audio Settings, Book Info, Where Am I?.
- **Tests:** each sheet's decisions in a plain type.

### Slice 8: VoiceOver

- **Does:** the magic tap's wiring, the focus coordinator, `.screenChanged` re-posting, the rotors, Read All's page turn, escape on anything custom.
- **Tests:** `PhoneFocusPolicyTests`. The rest is by hand.

### Slice 9: Settings

- **Does:** the Settings screen, Share Logs.
- **Tests:** `PhoneVocabularyTests`.

After these: `Scripts/test/a11y-lint.py` over all of it, and an outside review against this spec and Apple's documentation.

## The hand-check list

To follow with VoiceOver on the iPhone once the iOS platform is there. Order matters: the first few decide the most. Say which version of iOS the phone runs: iOS 27 shipped in September, and this was built against the iOS 26 SDK. If Xcode 26.0.1 can't install to it, that comes first.

### First: does it run at all

1. It installs, it opens to the Library, and VoiceOver reads it. Open Settings, then About, and note the version.
2. Add a short EPUB from Files with Add to Library, then Open Book…. Its row appears, and VoiceOver hears the import finishing. Add an M4B the same way.
3. Close the app from the App Switcher, and open it again. The library is still there. This settles where the library lives.

### Speech and the lock

4. Open a text book, double-tap Play, then press the side button. Does it go on speaking, for five minutes?
5. Pause and play again, so that it's on prepared audio, and repeat the test.
6. Let a chapter end while locked. Let a book end with Continue to Next Book, while locked.
7. Does opening a book stop your music, before any Play?
8. With a compact voice and an enhanced voice, is `.spokenAudio` audibly worse than `.default`? One report says so.

### VoiceOver on Play

9. Double-tap Play. Does VoiceOver stay silent? Is the book's first word lost? Double-tap Pause: does it say "Play"?
10. Swipe up and down on Play, paused and playing, with hints on and off. What does VoiceOver say each time, with no value? Is the word heard after a paused move the first words of the new place?
11. Flick to Navigation unit, then swipe. Flick back to Play. Is Adjust selected by itself?
12. Magic tap: on Play, in the Library, in a sheet, in an alert, in the search field (dictation must win), with no book ever opened, on the lock screen, in another app, during a phone call, and with iOS 26's Media Playback switch off.
13. Twist to Headings, Pages, and Bookmarks on the reader. Flick down twice. What is heard? This decides the rotor's future.
14. Flick through the reader's elements with the book playing. Is anything spoken without your flick? Leave focus on Where Am I? and on Sleep Timer for a minute: does either speak by itself?
15. With Audio Ducking off, When Speaking, and Always: flick during speech. Does anything pause? Do the two voices interfere?

### Focus

16. Open a book: does focus land on Play, and stay? Go back: does it land on the book's row? Open each sheet and close it: does focus return to its button?
17. Swipe down Control Center and close it. Take a call banner. Lock and unlock. Go to the Home Screen and return. Where is focus each time?

### Reading the text

18. Pause. Flick left from Play to Book content. Does it start at the sentence just spoken? Lines, Words, and Characters on the rotor. Two-finger swipe down: does Read All go on past the passage? Does stopping leave the book's place there?
19. Leave focus on Book content with the book playing. Does its text stay still?

### Braille

20. Connect a display. Item Overview at 2 to 7 cells: can you tell the reader's elements apart?
21. Dots 3 and 6 on Play and on Navigation unit. Dots 3-6, and a router key, to activate. Dots 1-5-6, the magic tap. Dots 1-2, escape. Panning through Book content, and Turn Pages when Panning.
22. Announcements: how long do they stay? Are they in the announcement history, dots 1-3-4-5?
23. Sound Curtain on: does it mute the book? Touch Curtain: is everything still possible?
24. Type in the search field with the display and with Braille Screen Input.

### Lock screen and AirPods

25. Does TextMouth appear on the lock screen? Are the title and the heading right? Does VoiceOver read the buttons? Which side buttons show with a unit of 15 seconds, and with Sentence?
26. AirPods: one out and back; both out; into the case; a stem press once, twice, and three times. Note what each does. Logs say what arrived.
27. Lock-screen Play after a minute, an hour, and after the app was killed.
28. Wired headphones out on speech and on an audiobook. AirPods in while it plays.
29. A phone call, taken then ended, locked and unlocked. Siri. An alarm. A Maps prompt: does it pause and hand back?
30. In Settings, Developer, Reset Media Services, during speech.

### Files and the life cycle

31. From Mail, Safari, Files, and Messages: share or open an EPUB, with TextMouth closed and open. Does TextMouth appear? Does the book open with focus on Play?
32. A file in iCloud Drive that isn't downloaded. A 2 GB audiobook. A folder of tracks.
33. An import, then leave the app, with a book playing and without. An import, then close it from the App Switcher.
34. Close from the App Switcher while playing. How far back is the place? Does the next launch reopen the book, paused, on Play, and say its title?
35. Reinstall over the top, as a free team must every 7 days. Do the books still open?
36. The sleep timer over an hour, locked. Does it stop on time?
37. Launch time with a large library.
38. Share Logs from Settings, and send them over. They hold the first run's answers.

## The open questions

Each with a recommendation, and what's built meanwhile. None stops the work. These are for the user, on top of questions 1 to 4 and 6 of `humanQuestions/2026-11-03.md`.

1. **The two skip buttons.** They do what adjusting Play does.
   - Keep them in VoiceOver's order, take them out of VoiceOver's order only, or remove them?
   - Recommended: keep them, for a double-tap and for Voice Control.
   - Built: kept.
2. **One unit, or a unit for each direction.** The Mac can have a forward unit and a backward unit.
   - Recommended: one, since Play's adjusting moves both ways and two would mean another element.
   - Built: one.
3. **Where Am I?, spoken by the app or by VoiceOver.** The app's voice pauses the book and uses the Mac's tested path. VoiceOver would put it on the display as a flash message, in VoiceOver's voice, and the value on the element gives braille the place either way.
   - Recommended: the app's voice, as built.
4. **Play's sounds.** The Mac's Play, Pause, and skip sounds are macOS's system sounds, which don't exist on iOS and can't be copied.
   - Do you want sounds on the phone, and made how: short new ones of our own, or none, with the book as the feedback?
   - Recommended: none in the first version, then decide after using it.
   - Built: none.
5. **Audiobook audio in iCloud backup.** A large library could fill a small iCloud plan and could make the phone's whole backup fail. If it's left out, a restored phone has books with missing audio.
   - Recommended: leave audiobook audio out of backup, as a setting, with the text and records backed up.
   - Built: everything is backed up, as nothing excludes it. To be decided before a big library goes on the phone.
6. **Opening a second book while the first plays.** Opening it stops the first, and the new one waits for Play.
   - Or the first could go on until Play is pressed in the second, at the cost of two live readers.
   - Recommended: as built, and see how it feels.
7. **Where the book's text sits.** Book content comes just before Play, as on the Mac, so a pause and one flick left reach it. It's also one more stop on the way from the title.
   - Recommended: as built.
8. **A folder in the Files app to drop books in.** It would show "On My iPhone, TextMouth", so books could be copied in over USB from Finder.
   - Recommended: not in the first version, since Add to Library and Open In cover it, and an empty visible folder explains nothing. It takes one plist key and a scan at launch.
   - Built: no such folder.
9. **Search field at the top.** iOS 26 prefers the bottom, where VoiceOver reaches it last with a four-finger tap. This spec pins it near the top, as one more stop before the Continue row.
   - Recommended: as built, and move it if the stop bothers you.
10. **Follow in Braille.** Should Book content's text advance with speech, for someone reading along on a display? It's deferred, since a changing text view may move the display under the reader, and only a first run can say.
    - Recommended: try it after the first run.
11. **A default for the navigation unit.** The Mac's is 15 seconds. Sentence may be more natural for a text book, on a phone.
    - Recommended: keep the Mac's setting as the default, so the two apps agree; each book remembers its own.
    - Built: as recommended.
12. **Your iPhone's iOS version.** If it runs iOS 27, Xcode 26.0.1 may not install to it, and first-run behavior may differ from this SDK's documentation. Please say which it runs.
