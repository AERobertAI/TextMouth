# TextMouth for iPhone: the interface specification (November 7, 2026)

## How to read this

- This is the design of TextMouth's iPhone app, for its first version. It is written for the person who will use it, and for the agents building it. Everything here reads in order with VoiceOver: real headings, short lists, no tables, no pictures.
- **Nothing in this document has run on an iPhone yet.** Since November 8, 2026 the app builds and runs in the iOS 26.0.1 simulator (iPhone 17), where its unit tests and its XCUITests, with Apple's accessibility audit, run; VoiceOver, braille, and sound can't be checked there. `make typecheck-ios` compiles and links the app for a device. Where a behavior can only be known from a first run, the text says "Unverified", and the hand-check list near the end covers it.
- The design rests on three research reports and two outside reviews, kept beside the briefs in `Scripts/agents/briefs/2026-11-07/iosui-research/`: `research-vo.md` (VoiceOver, braille, and what blind readers say), `research-code.md` (the code and the Mac's exact wording), `research-ios.md` (what iOS does to the app), and the reviews `review-user.md` (by a reviewer reading as the app's blind user) and `review-engineer.md` (by an iOS engineer who read the code). This version is revised from both reviews.
- **For the experience, read to "How it fits an iPad", then "The hand-check list" and "The open questions".** The sections between, "The map to the code" and "The implementation slices", are for whoever builds it. The Headings rotor at level 2 moves between them.
- Questions 1 to 4 and 6 in `humanQuestions/2026-11-03.md` have no answers yet. This spec builds on the recommended answers: iPhone first, with layouts that also work on an iPad; the first version's list in question 2; a library of the phone's own; iOS 26 and later. Each stays reversible. New questions are in the last section.
- What isn't in the first version is in three places: "What was rejected, and why", under the app's structure; "What the phone leaves out", under Settings; and "What's deferred".

## Who this is for

The app's first user is blind, and reads with VoiceOver and a braille display. They know the Mac app in depth, and its vocabulary. This isn't a sighted app made accessible afterward. The VoiceOver and braille experience is the design, and the visual layout follows from it: a sighted helper sees the same controls, in the same order, as large plain buttons.

## The principles

These settle most questions. Where a later section seems to disagree, the principles win and the section is wrong.

1. **The book is the feedback.** While the book plays, the app says nothing unless the listener asked. A heading passing, a chapter starting, a sentence's progress: none is announced, since what's playing says where you are. A move by sentence, paragraph, or seconds is silent too. The one exception is a move whose landing the book's own words can't name: a page, a bookmark, or an audiobook's heading says its short word.
2. **Focus stays where the listener put it.** VoiceOver's cursor moves only on arrival at a new screen, on return from a sheet, and after a jump the listener asked for. It never chases the spoken text, and nothing during playback moves it. Apple's criteria say a reading position mustn't reset unexpectedly, and readers curse exactly that in other apps.
3. **Nothing focusable changes while the book plays.** SwiftUI's documentation says a change to an element's label or value can be spoken automatically, and a braille reader's line can jump. So the reader's words are computed when VoiceOver asks for them, not pushed as the book moves. Nothing on the reader uses the updates-frequently trait.
4. **Everything spoken can also be read.** What the app's voice says never reaches a braille display, and announcements are short-lived flash messages there. So the book's text is an element, and every fact the app announces can also be found in an element.
5. **A short, stable set of controls, in a fixed order and a fixed place.** Controls don't appear, vanish, or move during a session, so a person can touch one directly. Nothing used often is hidden behind the Actions rotor or a More menu. A label's first few cells differ from its neighbors' where the Mac's words allow, for iOS 26's braille Item Overview.
6. **One vocabulary.** Where the Mac has a word for something, the iPhone uses that word: Skip forward, Navigation unit, Where Am I?, Book content. See "One vocabulary" below.
7. **A hint says what a control does, never a gesture.** VoiceOver, a braille display, and Voice Control each do it their own way. Hints stay short, because a user may keep only app hints on.
8. **Touch is never required.** iOS 26.4's Touch Curtain stops touch while a braille display is connected. Everything can be done with VoiceOver's item, rotor, and activate commands.
9. **No control that does what another does.** The user's standing rule (a slider beside a stepper is a duplicate). Three exceptions are named where they occur, each with its reason: the skip buttons, last in the reader's order; the Library's Play button, which isn't in VoiceOver's order; and the Speed slider in Voice & Speed, as on the Mac.
10. **The place is never lost.** Where a person reads by braille can become where they listen. A mistaken double-tap doesn't stop the book they're listening to. A book that crashes on opening doesn't reopen and crash again.

## A day with the app

What it's meant to be like, with the gestures counted and what's said. "Touch" means a finger on the control's fixed place, then a double-tap.

- **In the morning, the app having been closed overnight.** Double-tap the icon. VoiceOver says "Play, button, adjustable", then "Moby-Dick". Magic tap. The book plays from where it stopped, or up to 30 seconds before. Two gestures.
- **Back three sentences.** With Sentence chosen, three flicks down on Pause. Nothing is said. The book starts again from each place.
- **The next chapter.** Touch Next Heading: two gestures, with the unit left on Sentence. Each further heading is one double-tap. By flicks from Play it's six.
- **Where am I?** One flick right from Pause. VoiceOver reads "Where Am I?, The Battle, 12 minutes remaining in this heading, Page 112 of 300, 30 percent, 3 hours remaining", over the book, and a display shows it. A double-tap has it spoken in the book's voice, with the book paused for it. One flick left is Pause again.
- **Page 40.** Touch Go To. Focus is on the Page field, with its text selected. Type 4, 0, Go: five gestures. VoiceOver says "Jumped to page 40." and focus returns to Go To.
- **A bookmark.** Touch Add bookmark. "Bookmark 3 added." Two gestures. A note is added afterward, in Bookmarks, where focus lands on that bookmark.
- **Reading by braille.** Pause, then one move left to Book content. The display shows the sentence just spoken, and panning reads on. Double-tap, or Dots 3-6 with Space: the book plays from where the reading got to, with the old place kept for Return.
- **Going out.** Press the side button. The book goes on. A stem press pauses it, and another plays. One AirPod out pauses it, and back in plays.
- **In bed.** Touch Sleep Timer. Focus is on the last timer used, 30 minutes. Double-tap: "Timer set for 30 minutes.", then the book plays. Side button. Four gestures, and the book stops when it should, in silence.
- **Looking at another book while listening.** Double-tap a row by mistake. The book goes on. VoiceOver says "Play", then the new book's title. A scrub goes back, and nothing has changed: the book that's playing is still "Now Playing", and the other is still New.

## The app's structure

### The decision

- **One navigation stack.** The Library is the root. Choosing a folder pushes that folder. Choosing a book pushes its reader, full screen. Settings is pushed from the Library's root.
- **The reader's panels are sheets:** Headings, Bookmarks, Go To, Sleep Timer, Voice & Speed, Book Info. Each opens over the reader, and each returns focus to the control that opened it.
- **One book is listened to at a time, and the reader is owned above the navigation.** A single app-level object (`PhoneSession`) holds it. Leaving the reader's screen keeps the book playing.
- **Opening another book doesn't stop the first.** The first goes on playing until Play is pressed in the second. Going back from a second book that never played drops it, and the first is as it was. A book counts as opened at its first Play, its first move, or when its text is read, not at the row, so a mistaken double-tap leaves New, Unopened, and Recently Opened as they were.
- **The book in reach is a row, not a bar.** The first row of every Library screen is the Mac's Continue button: "Continue listening to Emma, 16 minutes remaining", or "Now Playing: Emma" while it plays. See "The Continue row".
- **The app is built on UIKit's life cycle,** with a `UIWindow` subclass as the one reliable home for the magic tap, and a `UIHostingController` holding the SwiftUI screens. See "The app's frame" under the code map.

### What was rejected, and why

- **A tab bar (Library, Reader, Settings), with iOS 26's `tabViewBottomAccessory` as a mini-player.** Nobody documents VoiceOver's order for that accessory, and its content can change with the tab bar's size, which could lose focus. A tab bar adds three stops to the end of every screen, and a reader needs one stack. Rejected until a first run shows otherwise.
- **A Now Playing bar pinned to the bottom of the screen,** as in Music or Audible. VoiceOver reaches it last, past every book in the library. Reports curse controls moved into a mini-player's actions, and focus lost around it. A row near the top is in the same place on every Library screen, and it is what the Mac already has.
- **The reader as a sheet or a full-screen cover.** A pushed screen has a system Back button and the system's two-finger scrub for free. A cover has neither.
- **SwiftUI's `App` with `@UIApplicationDelegateAdaptor`.** Two shipping audio apps (Paperback and FastPlay, both written for screen reader users) found that a delegate behind the adaptor "may never fire" for the magic tap, and put a window subclass under a scene delegate. Doing that inside a SwiftUI `App` needs an empty `WindowGroup`. A plain UIKit app delegate and scene delegate is simpler and fully documented.
- **A Direct Touch gesture area on the reader,** as some readers once had. It disables VoiceOver's own gestures there, has no braille equivalent, and a blind user can swipe through it by accident.
- **A position slider on the reader's screen.** Too easy to change by accident, and readers curse it for moving too far. Percent, page, and time are typed in Go To.
- **Stopping the first book as soon as a second opens.** It was this spec's first design, and the outside review as its reader rightly called it a daily curse: a mistaken double-tap would stop the book, change the Continue row, and mark the wrong book as opened for good.

### How a person moves around

- A flick right or left moves through a screen's elements in the order this spec gives.
- The two-finger scrub goes back: from the reader to the Library with the book still playing, from a folder to its parent, from a sheet to the screen under it.
- The two-finger double-tap, the magic tap, plays and pauses the current book from any screen of the app, sheets included (see "The magic tap").
- A four-finger tap near the top reaches the first element, and near the bottom the last.

## The rules every screen follows

### Focus on arrival and return

Each is a rule of one plain type, `PhoneFocusPolicy`, so tests can read it. Rows are asked for through one helper, `PhoneListFocus`, and controls through `PhoneFocusRegistry`.

- **A book opens.** Focus lands on Play, and the book's title is said after it with low priority, at every open.
  - At 0.35 seconds the app posts `.screenChanged` with Play as its argument.
  - It watches VoiceOver's focus. Once focus has been on Play even once, it stops for good. A landing on any of the reader's other controls is the listener's, and it stops for good then too.
  - If focus has reached none of them by 1.2 seconds, as when VoiceOver has wandered to Back or the title, it posts `.layoutChanged` with Play once. At 3 seconds it stops regardless.
  - So a quick flick is never thrown back.
- **Back to a Library screen.** Focus lands on the row just left: the book's row, or the folder's. A row not yet made has no element, and asking for it does nothing and reports nothing. So the helper checks that the ID is in the list, scrolls to it, waits 0.35 seconds, and sets the focus state to nothing and then to the row. If the row has gone, it's the next row, or the Continue row.
- **A folder opens.** Focus is left to VoiceOver's default, the title or Back, and VoiceOver says the Mac's words after 0.35 seconds: "Fiction, 12 books".
- **A sheet opens.** Focus lands on what the sheet is for, after 0.35 seconds, and the title is a flick away:
  - Headings: the current heading, as on the Mac.
  - Bookmarks: the bookmark nearest before the place.
  - Choices: the current choice.
  - Sleep Timer: the last timer used.
  - Go To: the Page field, or the time field in an audiobook, with its text selected.
  - A sheet with one field: that field.
- **A sheet closes.** Focus returns to the control that opened it, in `onDismiss`, by a `.layoutChanged` with that control as argument, after 0.35 seconds. Sheets and menus don't return focus by themselves.
- **A jump chosen in a sheet.** The sheet closes, focus returns to the control that opened it, and the rule for moves below says what is announced.
- **Coming back from the background.** Focus is restored to where it was only after a true return from the background, never after Control Center or a call banner, which leave it alone.
- **During playback,** nothing moves focus, ever. A chapter change, a book's end, and an interruption don't touch it.
- **The next book, when listening goes on from one book to another.** The reader's screen stays, with the new book's title and text. It's never rebuilt, so focus stays on the control it was on. VoiceOver says the Mac's "Starting: Dune".
- **Any focus event cancels a request still waiting,** so a delayed request can't pull focus from under a flick.

### Announcements

- All go through the shared `VoiceOverAnnouncer`, or the phone's `PhoneAnnouncer` over it, whose iOS branch posts `AccessibilityNotification.Announcement`.
- **Priority.** Nearly every shared call says `.high`, which on iOS can't be interrupted once started, so a quick second flick couldn't cut it off. On iOS, the announcer maps high and medium to `.default`, and low to `.low`. The one thing that keeps `.high` is a stop the listener must know about: `PhoneAnnouncer.important(_:)`, used for a book that can't be played or speech that has stopped.
- **Timing.** An announcement after an activation is posted 0.15 seconds later, or SwiftUI's own layout notification can cut it off.
- **While the book plays,** what a move would have said is dropped, by "What a move says". Answers to something else the listener did are still said: a bookmark added, a voice changed, a timer set.
- **Background results,** such as an import finishing, are `.low`, so they wait their turn. The two shared calls that post those at high get an iOS branch that asks for low.
- **The sleep timer's spoken milestones are dropped on the phone.** The Mac's "Sleep timer: 5 minutes remaining" over the book, in the dark, heard or lost by chance, breaks principle 1.
- **Unverified:** whether an announcement posted while the app is in the background is ever heard. Assume it's lost, and say nothing important that way.

### What a braille display shows

Unless a section says otherwise, an element shows its label, its value, and VoiceOver's marks for its traits. A hint shows as an alert message. An announcement is a flash message for the time the user has set, and may be in VoiceOver's announcement history (Dots 1-3-4-5 with Space; **Unverified** for an app's). So nothing is said only by announcement: what it says can be found in an element.

### The magic tap

- A `UIWindow` subclass, `MagicTapWindow`, overrides `accessibilityPerformMagicTap()`. The window is in every responder chain, sheets included. The app delegate implements it too, as a second home.
- **If anything is audible, it pauses that.** From silence, it plays the book on screen. With no reader on screen, it plays the book in reach: the open reader's book, else the book last opened, else the row with the newest Last Opened date. That opens the book without leaving the screen, and plays it as soon as it has loaded.
- **It returns false** when there's no book at all, so that the system's own fallback runs.
- **It says nothing.** The book starting or stopping is the feedback.
- **Unverified, and early on the hand-check list:** that it doesn't take dictation from a text field, or a ringing phone's answer, and that the reader's Play label changing under a magic tap isn't spoken over the book. If a text field does lose dictation, `MagicTapWindow` returns false while a text field holds the keyboard. Apple lists Dots 1-5-6 as "Play/Pause Music", not as the magic tap, so at a cold reopen, before TextMouth holds Now Playing, it might start Music: also on the list.
- Outside the app, the system's magic tap plays and pauses the current media app through remote commands, unless the user has turned off iOS 26's Media Playback switch.

### Lists

- Every list is a SwiftUI `List`, whose rows are real elements. A `LazyVStack` isn't used, since offscreen elements aren't reliable there.
- A row's identity never changes when the list refreshes, so VoiceOver's cursor stays put.
- Section headers carry the header trait, so the Headings rotor jumps between them.
- A row's commands are explicit named actions, on the Actions rotor, with a context menu of the same commands for touch.

### Choices

Picking from a list of choices (a library view, a sort, a navigation unit, a language, a voice, a folder) is a small sheet of the app's own, `PhoneChoiceSheet`: a list where each choice is a row, the current one has the selected trait and has focus on arrival, and choosing closes the sheet. SwiftUI's `Menu`, and a `Picker` shown as one, aren't used, since a menu doesn't return focus when it closes and `AccessibilityFocusState` can't bring it back.

### A sheet's buttons

- Every sheet's buttons (Cancel, Close, Done, Save, and Back to Book) are in the trailing end of its bar, and come after the title: VoiceOver reads the title, then Cancel (or Close, or Done, or Back to Book), then the confirming button.
- They are placed by `PhoneSheetButton`, in `.topBarTrailing`, and not by `.cancellationAction` and `.confirmationAction`. Those are the bar's leading side, and the accessibility tree read the buttons before the title.
- Each button has its label given outright, so that VoiceOver and braille say the Mac's word whatever the system draws.

## The Library

The Library is three kinds of screen with one shape: the top of the Folders view, a folder, and any other view such as All Items. What a person came for comes first; what's used less sits in the bar at the bottom, reached by a four-finger tap near the bottom.

### The Library's top

VoiceOver's order:

1. **Title.** "Library", the navigation title, shown inline, a heading. A view other than Folders adds its name: "Library: All Items".
2. **Search.** The search field, kept under the navigation bar by `.searchable(placement: .navigationBarDrawer(displayMode: .always))`. See "Searching".
3. **The Continue row.** See "The Continue row". Absent until a book has been opened.
4. **Library view.** A row, opening `PhoneChoiceSheet`.
   - Label: "Library view". Value: the view's name, such as "Folders".
   - Hint: "Chooses what the Library lists."
   - Its choices are what the Mac's pop-up offers. Feeds doesn't appear, since the phone has none.
   - Choosing closes the sheet, and focus returns here, so VoiceOver reads the new value. The list below changes. Nothing else is said.
5. **"Folders",** a section heading, then one row for each folder.
   - Label: the Mac's "Fiction, 12 books". Hint: "Opens the folder."
   - Actions: "Rename Folder...", "Move Folder...", "Delete Folder...".
6. **"Books (743)",** a section heading in the Mac's words, then one row for each book. See "A book's row". In a Title or Author sort, with more than about 30 books, the books have letter sections as well, with "A", "B", and so on as headings the Headings rotor reaches, and iOS 26's section index for touch.
7. **The summary,** one static element: the Mac's spoken summary, "743 books. 14 hours total remaining at current speed." It isn't updated while the book plays.

Then the bar at the bottom, the last elements, in this order:

8. **Settings.** Label: "Settings". Hint: "Opens TextMouth's settings." Pushes the Settings screen.
9. **New Folder.** Only in the Folders view. Label: the Mac's "Create new folder". Opens the New Folder sheet.
10. **Sort.** Label: the Mac's "Sort books by Title, ascending". Hint: "Chooses the order of the books." Opens `PhoneChoiceSheet`.
    - Choices: the fields, "Title", "Author", "Date Added", "Last Opened", "File Size", and "Manual Order"; then the Mac's "Sort Descending" or "Sort Ascending", dimmed in Manual Order with the hint "Manual order has no direction"; and in a folder with subfolders, "Apply Sort to All Subfolders".
    - On choosing, VoiceOver says the Mac's "Sorted by Title, ascending" once the sheet has closed.
11. **Add to Library.** Label and title: the Mac's. Hint: "Opens a sheet with the ways to add to the library: open a book, or import a folder." Opens the sheet in "Importing". A four-finger tap near the bottom lands here.

**Unverified:** that VoiceOver's order runs through the list to the bottom bar, and how quickly it flicks through 700 rows.

### A folder

The same, with these differences:

- First comes the system's Back button, named for where it goes.
- The title is the folder's name, a heading.
- Library view and Settings aren't here. Up One Level isn't either: Back is that.
- The section headings and the rows are the folder's own.

### Any other view

All Items, Unopened, Recently Opened, Reading List, and views the user makes on the Mac if a library ever moves: the same as the top, with no Folders section and no New Folder. A view that lists nothing shows one row, the Mac's "Nothing matches this view now." The Reading List keeps the order you arrange. Its Sort reads "Sort books by Reading List Order", with that one choice, and an empty Reading List says: "The reading list is empty. To add a book, choose Add to Reading List from its actions."

### Searching

- **It covers the whole library from any Library screen:** titles, authors, and folder names, with folder rows among the results. The Mac's search narrows only the place shown, which at the top of a library kept in folders would find nothing. This departs from the Mac, so it's a question at the end.
- **The results are the list.** While searching, the Continue row, Library view, and the summary step aside: the order is the field, Cancel, then the first result.
- After typing stops for a second, VoiceOver says the count with low priority, as in "3 books"; with none, a row says "No books match.", and that is said once.
- **A scrub clears the search,** and the list comes back with focus on the field.
- **Back from a book keeps the search,** with the keyboard down, and focus on the row.

### A book's row

- **Label:** exactly the Mac's `BookRow.rowAccessibilityLabel`, in its order: the title; "by" and the author; "In reading list"; "New" or "Now Reading"; progress, such as "42 percent" or "Finished"; time left, such as "2 hours, 5 minutes remaining"; the format, such as "EPUB". Example: "Middlemarch, by George Eliot, 42 percent, 2 hours, 5 minutes remaining, EPUB". The title comes first.
- **Value:** none.
- **Hint:** "Opens the book."
- **Traits:** button.
- **Actions,** each only where it applies, in this order: "Book Info"; "Add to Reading List" or "Remove from Reading List"; "Move to Folder..."; "Move Up" and "Move Down", where the list has an order you arrange; "Remove from Library...".
  - Move Up and Move Down say the Mac's `placeAnnouncement`, as in "Dune, 3 of 12".
- **Braille:** the label, then VoiceOver's mark for a button. The title's first cells tell rows apart.
- **While the book plays:** a row's words don't update. The list is held by `PhoneLibraryRows`, which republishes only when the list itself changes, not at each checkpoint of the book playing. A focused row can't change its label under the listener.
- **What's visible:** two lines, the title, then the author and progress, at Dynamic Type sizes. The Mac's `BookRow` is too wide for a phone, so the phone draws its own and calls the same words.

### Removing a book

- Remove from Library... asks first, unless Confirm before removing a book is off.
- **On a phone there is no Trash a person can open, and a library folder a person can't see.** So the phone offers one choice, and uses the Mac's words for it:
  - Title: "Remove Book?"
  - Message: "This deletes the book and its files from this iPhone, and they can't be recovered. Your Mac's library isn't touched."
  - Buttons: "Delete Permanently", and "Cancel".
- Afterwards VoiceOver says the Mac's "Deleted “Dune” permanently.", and focus goes to the row after the one removed, or before it if it was the last.
- If that book is the one open in the reader, the reader closes first.

### Folder sheets

New Folder, Rename Folder, Move Folder, Move to Folder, and Delete Folder are small sheets rebuilt for the phone, with the Mac's words and over the Mac's model calls: a `Form` in a `NavigationStack`, with the sheet's title and, after it, the Mac's Cancel and confirm buttons in the toolbar. The Mac's own sheets can't be wrapped: their buttons are in their bodies, they don't scroll, and a `Picker` in them is a menu here. Each one's text field has the keyboard and VoiceOver's cursor on arrival. A folder is chosen through `PhoneChoiceSheet`. Failures show under the field as the Mac's "Error: " and the reason, and are announced once.

### The Continue row

The Mac's Continue button, as a row, the same on every Library screen, right after the search field.

- **Not playing.** Label: the Mac's "Continue listening to Emma, 16 minutes remaining". A finished book has no time left: "Continue listening to Emma".
- **Playing.** Label: "Now Playing: Emma". There's no time left, since it would change. The first cells differ from "Continue".
- **Hint:** the Mac's "Opens the last book you were reading".
- **Traits:** button.
- **Actions:** none. The magic tap plays and pauses from here.
- Activating opens the reader, with focus on Play, and the book goes on playing if it was.
- **What's visible beside it: a Play button,** "Play" or "Pause", for a sighted helper. It isn't in VoiceOver's order, since the magic tap does the same.
- **Its words change only when playing starts or stops, or when the book changes.** It reads the session's small snapshot, not the reader, so it isn't redrawn 8 times a second.
- A book deleted from the library leaves the row, which goes to the book then in reach, or disappears when there's none.

## The reader

The reader is the heart of the app, and the screen a person spends their time on. It serves both text read aloud and audiobooks, with the same elements in the same places.

### The idea

- **Land on Play.** A book opens with VoiceOver on Play. A double-tap plays. A magic tap plays from anywhere.
- **Swipe up or down on Play to move by the navigation unit.** That is the pattern blind readers praise in Voice Dream, and that Speech Central and Paperback also use. No rotor twist is needed, because VoiceOver selects Adjust by itself when focus lands on an adjustable element (an Apple engineer's accepted answer). It works from a braille display with the "move by rotor setting" commands, Dots 3 and 6.
- **The element before Play is the book's text,** so a person who pauses can move once to the left and read what was just spoken, by line, by word, or on a display, and then listen on from where the reading got to.
- **The element after Play is Where Am I?,** since on the Mac that's one key.
- **Everything else follows in a fixed order and a fixed place,** by how often it's used.

### What was rejected for moving by unit, and why

- **The rotor as the way to move.** A custom rotor must return a real element, and no document says what VoiceOver does when that is the element it already stands on. The closest report is an end-of-list sound and no speech. VoiceOver also reselects Adjust whenever focus lands on an adjustable element, and some readers dislike twisting. So the rotor is a second way (below), and a first run decides how good it is.
- **A rotor of every sentence built in SwiftUI.** SwiftUI's rotors describe every entry; a book has 50,000 sentences; and a field report has one listed by VoiceOver and stepping to none of its rows.
- **Actions as the way to move.** Too many steps for something done again and again.
- **A gesture area with Direct Touch.** See "What was rejected" under the app's structure.

### Why the reader's controls are UIKit views

- Every control on this screen but Back and the title is a small UIKit view in the SwiftUI layout.
- In UIKit, a control's words can be computed at the moment VoiceOver asks, and adjusting changes state synchronously, so VoiceOver reads the new value and not the old. In SwiftUI, a value updates only with a redraw, later than VoiceOver's read, which is a reported failure.
- SwiftUI may speak a changed label on a focused element by itself (principle 3). A UIKit view whose words are computed on request has nothing to push.
- A plain type says what each control's words and traits are for a given state, in shared code, so the Mac's test host can test every sentence. The UIKit view only reads it.

### The layout

The visual layout follows from the order, and it matters to VoiceOver as well, since a control always in one place is one touch from anywhere.

- **No scrolling at default text sizes.** From the top: Book content, as a strip about six lines tall; Play, full width and tall, at the same height in every book; then a grid of three columns and five rows, in the order below.
- **Rows of the grid:** Where Am I?, Navigation unit, Speed. Previous Heading, Next Heading, Add bookmark. Bookmarks, Headings, Go To. Return, Sleep Timer, Voice. Book Info, Skip backward, Skip forward.
- **At large text sizes,** the grid becomes one column and the screen scrolls. VoiceOver scrolls it as focus moves.
- **On a wide screen,** the column has a limited width, centered.
- **Unverified:** that a person can find Play by touch, and that Item Chooser (a two-finger triple-tap, or Dots 2-4 with Space) lists every control by a usable name.

### VoiceOver's order

1. Back
2. The title
3. Book content
4. Play
5. Where Am I?
6. Navigation unit
7. Speed
8. Previous Heading
9. Next Heading
10. Add bookmark
11. Bookmarks
12. Headings
13. Go To
14. Return
15. Sleep Timer
16. Voice, or Audio Settings
17. Book Info
18. Skip backward
19. Skip forward

These never appear or vanish while the book is open. Their words change only as this section says.

### Back

- The system's Back button, named for where it goes, such as "Library" or "Fiction".
- It goes back with the book still playing. So does the two-finger scrub.
- Focus then lands on the book's row (see "Focus on arrival and return").
- Going back doesn't close a book that has played. It stays behind the Continue row. A second book that never played closes as you leave it, and the first is as it was.

### The title

- The navigation title, shown inline: the book's title, with VoiceOver's heading trait. The Mac's "Book: Moby-Dick by Herman Melville" is a window's title; here the screen shows only "Moby-Dick". A book read from the Reading List reads "Reading List: Moby-Dick", the Mac's prefix.
- The title is said once with low priority at every open, after VoiceOver has read Play, since nothing else has said which book this is.

### Book content

The book's text, as the Mac's reader has it just above the playback controls. This is how a braille reader reads the book.

- **Element:** a read-only text view. As a text view it gets Lines, Words, and Characters on the rotor, a cursor on a braille display, and panning, without further code.
- **Label:** "Book content", the Mac's.
- **Value:** the passage: up to 20,000 characters of the chapter (the Mac's limit), **starting at the start of the sentence at the reading position**. The Mac centers its text around the place. On the phone, the first thing read is the place, so a person who pauses and moves to it hears the sentence just spoken. It keeps whole words at its end, by the Mac's rules.
- **A chapter with no words.** Some books open at a chapter that has nothing to say, such as a Project Gutenberg EPUB's "Cover", which is only an image.
  - Book content then shows the next chapter that has words, from its start. That is the chapter Play reads, by the same forward-only search playback makes over silent chapters (`PhonePassagePolicy.placeToShow`).
  - Nothing is left blank. If no chapter from the place on has words, Book content keeps its stand-in.
  - The Mac's Book content shows nothing at such a chapter. Whether the Mac should do the same is a question to the user.
- **Hint,** computed when asked: while paused, "Plays from here."; while playing, "Brings the text to the sentence being spoken."
- **Traits:** static text. Text context narrative, and the book's language if it's known.
- **Actions:** none, or VoiceOver would say "Actions available" after it.
- **Activate:**
  - **Paused: Listen from Here.** The place moves to VoiceOver's cursor in the text, the old place is kept for Return, and the book plays. VoiceOver's cursor is found, in order: the text view's selection, if VoiceOver or a router key has moved it; the sentence last reached through the Sentences rotor below; otherwise the passage's start. **Unverified:** whether a selectable text view's selection follows VoiceOver's cursor or a router key.
  - **Playing:** the text comes to the sentence being spoken, a Follow in Braille by hand. Nothing moves until it's asked for, and the book plays on.
- **Sentences rotor,** on this element alone: a lazy rotor that moves by sentence within the text, returning a range in the text view, as Apple's WWDC20 session shows. Each result is remembered as VoiceOver's sentence, for Listen from Here.
- **Paging,** never on the cut list: Apple's "Scroll down one page" and "up" (a three-finger swipe, or Dots 1-4-5-6 and 3-4-5-6 with Space) give the next or previous passage, across chapters. While paused, a page moves the place. While playing, it moves only the passage. Each says the new page's place by the system's page-scrolled status: the Mac's page or percent words.
- **Read All** (a two-finger swipe down) reads on past the passage's end, by the same paging, with the page-turn trait. While paused, each turn moves the place, so stopping leaves the place there. **Unverified,** and the one part of this element that may be cut.
- **The screen stays awake while this element has focus,** since a person reading by braille may not touch the phone for minutes.
- **When the text changes,** by `PhonePassagePolicy`:
  - when the book has loaded;
  - when the book pauses or stops: the passage then starts at the sentence just spoken, unless the element has focus;
  - after a move while paused;
  - while the book plays, at most every 10 seconds, **and only while this element doesn't have focus**;
  - when it has focus and the book plays, never, unless the Follow in Braille switch in Settings is on: a focused text view must not change under a reader, in speech or in braille;
  - and always when focus leaves it, and on coming back from the background.
- **Reading while the book plays:** VoiceOver reads the passage over the book, ducked or not as the user set. That's the listener's choice, as is a two-finger tap to stop VoiceOver's reading. Nothing pauses by itself.
- **An audiobook** has no text unless it's transcribed (its chapters are spaces, and a reader must not show them). With a transcript it shows that, like any book. With none, the element reads: "Book content, this audiobook has no text. The Battle." It gives the heading being heard.
- **Braille:** the label, then the text, with the cursor and panning VoiceOver gives any text view.

**The whole-book reading screen is deferred.** Later, a Read Text screen can hold the entire book as a lazy container of paragraph elements (Paperback's design, MIT licensed), so VoiceOver focus itself is the place, flicks move by paragraph, rotors land on real elements, and Read All never runs out. It needs a real run to judge. Named under "What's deferred".

### Play

- **Label:** "Play", or "Pause" while the book plays, by the Mac's rule. A waiting book counts as playing.
- **Value:** empty while playing. While paused, after a move, it's what the move said (below), kept until Play or the next move. While loading, "Loading".
- **Hint:** "Moves back or forward by sentence.", naming the unit in force in lower case, computed when asked. The hint says what adjusting does, since activating needs no explaining.
- **Traits:** button, adjustable. **Starts a media session in the Play state only.** An Apple engineer's accepted answer says this trait stops VoiceOver speaking "Play button, playing" over the book. After Pause, VoiceOver saying "Play" in the silence confirms it, so the Pause state doesn't have the trait.
- **Activate:** Play or Pause, as on the Mac. While the book is still loading, the press is remembered and the book plays as loading ends. A second press forgets it. So the listener never has to find Play twice.
- **Adjust up:** moves forward by the unit in force. **Adjust down:** moves back. **The Mac's 0.4-second skip debounce doesn't apply here:** it's for one media key arriving by two paths on a Mac, and it would drop a quick second flick in silence.
- **Up is forward,** as Voice Dream's and Apple's "increase" have it, though on a rotor down is next. From a display, Dot 3 with Space goes forward. It's a choice, a hand check, and a question.
- **Actions:** none.
- **Rotors:** see "The rotors".
- **Unverified, and the central check:** what VoiceOver says after an adjustment while the book plays, with an empty value. If it says "Pause" after each flick, try a value of one space. If that fails too, the first version accepts the word "Pause", a short one; if that proves unbearable, the skip buttons and the Next Heading button carry the moves until it's solved. Nothing else depends on this.
- **Braille:** "Play", the value, and VoiceOver's marks. Dots 3 and 6 adjust; Dots 3-6 activate; Dots 1-5-6 play and pause from anywhere.

### What a move says

One plain type, `PhoneMoveFeedback`, decides, whether the move came from adjusting Play, a skip button, Next Heading, a rotor, or the AirPods. All of them take one path through the phone's reader model, and what the shared code would have said is collected, not posted, and sorted.

- **While the book plays:**
  - **Sentence, Paragraph, seconds, and a text book's Heading or Subheading: nothing.** The book, starting at the new place, is what's heard.
  - **Page, Bookmark, and an audiobook's Heading or Subheading: the Mac's short word.** "Page 113", "Bookmark 3", "Heading: Chapter 4". The book's own words can't say these, as the Mac's own page says: nothing is read aloud for a page. A stray flick with Bookmark chosen shouldn't put a person somewhere unknown, in silence.
- **While paused,** the words go in Play's value, so VoiceOver says them as the adjust's answer, a flick cuts them off, and the display keeps them. After a skip button, a heading button, or a rotor, they're also announced, since no adjust answers there.
  - **Heading, Subheading:** the Mac's "Heading: The Battle".
  - **Page:** the Mac's "Page 112".
  - **Bookmark:** the Mac's "Bookmark 3".
  - **Sentence, Paragraph, and seconds in a text book:** the whole sentence at the new place, capped at about 300 characters. The Mac's "Next sentence" says nothing useful here.
  - **Seconds in an audiobook:** the Mac's clock words, "Moved to 1 hour, 3 minutes, 45 seconds." A skip by seconds on the Mac says nothing, but silence after a paused move looks like a dead control.
- **With Auto-play after navigation on,** a jump from a list that starts the book counts as playing.
- **Nothing that way,** whether paused or playing: "No next heading.", "No previous page.", "No next bookmark.", and so on, with the unit's name in lower case. For a skip by seconds at either end: "Start of the book." or "End of the book." The Mac says nothing here, but a press that does nothing must be told from a press that was missed.
- **A book with no pages:** Page isn't offered. If it's in force from a saved choice, it falls to the book's default.
- **Anything else the shared code said during the move still passes:** a sleep timer stopping, or the book ending.
- **Every jump keeps the Mac's Return place,** as the Mac's does.

### Where Am I?

- **Label:** "Where Am I?" While its announcement speaks: the Mac's "Stop Where Am I announcement".
- **Value,** computed when asked: the heading; the Mac's "12 minutes remaining in this heading"; the page; "30 percent"; and "3 hours remaining". So: "The Battle, 12 minutes remaining in this heading, Page 112 of 300, 30 percent, 3 hours remaining". An audiobook adds where in the recording, "2 hours, 13 minutes in". A finished book: "Finished". The page is left out while Show the page on the reader screen is off, or the book has none. Nothing warns that it can go old while focus rests here: landing again refreshes it.
- **Hint:** none.
- **Traits:** button. Starts a media session, for the same reason as Play: its answer is spoken by the app.
- **Activate:** the Mac's brief summary, unchanged: the book pauses, the summary is spoken in the book's voice by the app, and the book plays on, as in "Dune. The Battle. Heading 26 of 412. Page 112 of 300. 30 percent. 3 hours remaining."
- **Actions:** "Where Am I? Full Summary" and "Copy Reading Position", the Mac's.
- **Why the app's voice, and not a VoiceOver announcement:** a VoiceOver announcement over the book, or with the Mac's pause and resume timed by a notification that can fail to arrive, is more fragile than one code path already tested. The value above is what braille gets, without pressing anything, and a person who only wants the place can stop at this element.

### Navigation unit

- **Label:** "Navigation unit", the Mac's.
- **Value:** the unit's name, the Mac's: "10 seconds", "15 seconds", "30 seconds", "60 seconds", "Sentence", "Paragraph", "Page", "Heading", "Subheading", "Bookmark".
- **Hint:** "Chooses what Play and the skip buttons move by."
- **Traits:** button, adjustable.
- **Adjust up:** the next unit in the Mac's order, wrapping around. **Adjust down:** the one before. VoiceOver reads the new value alone: the shared "Navigation unit: Sentence" isn't also posted.
- **Activate:** opens `PhoneChoiceSheet`, with focus on the current unit, so that Bookmark needn't be five flicks from Sentence. Choosing returns focus here.
- **What's offered:** the Mac's list, with these differences:
  - **Sentence and Paragraph aren't offered for an audiobook,** which has no text to stop at. On the Mac they do nothing in silence. A transcribed audiobook is the same for now.
  - Page is left out for a book without pages, as on the Mac.
- **Stored per book,** one unit for both directions. The phone sets the Mac's "One Unit for Both Directions" mode, and doesn't offer the choice.
- **Until a book has its own, it starts at a default for its kind:** Sentence for a text book, and 15 seconds for an audiobook, set in Settings. A unit a book doesn't offer falls to its default.
- **Braille:** "Navigation unit Sentence". At 14 cells the value that changes may be off the line: a hand check.

### Speed

- **Label:** "Speed" for a text book; the Mac's "Audio speed" for an audiobook.
- **Value:** the Mac's "200 words per minute" or "1.25 times speed".
- **Hint:** for an audiobook, the Mac's "Changes the speed in steps of 0.1 times". For a text book: "Changes the speed in steps of 25 words per minute."
- **Traits:** adjustable.
- **Adjust up or down:** by the Mac's 25 words per minute, from 50 to 650; or by 0.1, from 0.25 to 4. It applies to this book, as on the Mac. VoiceOver reads the new value alone: the shared "225 words per minute" isn't also posted.
- **While the book plays,** a change takes effect as the Mac's does. Speech restarts at a natural break, under the rule that speech never switches paths in mid-play.
- **Braille:** "Speed 200 words per minute". Digits, as readers asked of Voice Dream.
- The Mac's tortoise and hare buttons aren't here, which would be duplicates. Pitch is in Voice & Speed.

### Previous Heading, Next Heading

- **Labels:** the Mac's menu words, "Previous Heading" and "Next Heading".
- **Value:** none. **Hint:** "Moves to the heading before, leaving the navigation unit as it is." and "Moves to the next heading, leaving the navigation unit as it is."
- **Traits:** button.
- **Activate:** a move by heading, with what "What a move says" says. Focus stays, so a second double-tap goes on.
- **Why they're here, on top of a unit of Heading:** on the Mac a heading is one key, and without these it's six gestures that leave the unit changed.

### Add bookmark

- **Label:** the Mac's "Add bookmark", or "Remove bookmark" while the place is near a bookmark, computed when asked.
- **Hint:** none.
- **Traits:** button.
- **Activate:** VoiceOver says the Mac's "Bookmark 3 added" or "Bookmark 3 removed", also while the book plays, since the listener asked. Focus stays. The book goes on.
- **Removing a bookmark that has a note asks first:** an alert titled "Remove Bookmark 3?", with its note as the message, and "Remove" and "Cancel". With no note, it's removed at once.

### Bookmarks

- **Label:** "Bookmarks", the Mac's visible word. **Value:** the count, such as "3 bookmarks", computed when asked, and left out at none.
- **Hint:** "Opens the list of bookmarks."
- **Traits:** button. Opens the Bookmarks sheet, below.

### Headings

- **Label:** "Headings". **Value:** the heading and its place, "The Battle, 26 of 412", computed when asked.
- **Hint:** "Opens the list of headings."
- **Traits:** button. Opens the Headings sheet, below.

### Go To

- **Label:** "Go To", the Mac's word on a list row. **Hint:** "Goes to a page, a percent, or a time."
- **Traits:** button. Opens the Go To sheet, below.

### Return

- **Label:** the Mac's "Return to previous reading position".
- **Hint:** the Mac's says "Go back to where you were before browsing headings or bookmarks", which is too narrow here: "Goes back to where the last jump began."
- **Traits:** button.
- **Activate:** the Mac's "Returned to previous position". With no place, the Mac's "No previous position to return to." On the Mac this button vanishes with no place to return to. Here it stays, by principle 5.

### Sleep Timer

- **Label:** "Sleep Timer".
- **Value:** computed when asked: "Off", or the Mac's spoken status, as in "4 minutes, 59 seconds remaining", "stops at the end of this heading", or "fading out".
- **Hint:** "Opens the sleep timer."
- **Traits:** button. Opens the Sleep Timer sheet, below.

### Voice, or Audio Settings

- **Label:** the Mac's: "Voice" for a text book; "Audio Settings" for an audiobook. The Mac's "Change voice for this book" is its hint here.
- **Traits:** button. Opens the sheet below.

### Book Info

- **Label:** "Book Info". **Hint:** the Mac's "Show book information".
- **Traits:** button. Opens the Book Info sheet.

### Skip backward, Skip forward

- **Labels:** the Mac's "Skip backward: Sentence", "Skip forward: Sentence".
- **Value:** none. **Hint:** none: the label says it.
- **Traits:** button.
- **Activate:** a move, with what "What a move says" says. It doesn't move focus.
- **The first of the named duplicates:** the same move as adjusting Play, and they're last in the order, so they cost nobody a flick. Without VoiceOver running there's no adjusting, so a sighted helper or Voice Control needs a button. With VoiceOver, one double-tap after another is steadier than swipes for some people. A four-finger tap near the bottom and one flick reach them. It's a question at the end.

### The rotors

The second way to move, and the first thing to cut. A person on Play can twist to these, and flick down for the next or up for the previous. They're UIKit's lazy rotors, set on Play alone, so that with the rotor left on Headings, a flick on Book content still means the next line.

- **Headings:** system type heading, so VoiceOver uses its usual heading commands.
- **Pages:** only in a book of more than one page.
- **Bookmarks:** only in a book with one or more.
- **What it returns:** Play, by a fresh object that compares equal, never another control, so focus stays on Play and nothing is read but what a move says. A flick with nothing that way returns nil, which is VoiceOver's boundary sound.
- **Unverified, and likely to change:** what VoiceOver does when Play comes back. A move also happens inside what the API calls a search, and VoiceOver may call that when it isn't expected. This piece sits behind one flag, and is built last. If it can't be silent, it's cut: Next Heading and adjusting Play are the design.

### While the book is loading, or can't load

- **Loading:** the screen is whole from the start: every element is in its place, and Play's value reads "Loading". The Mac's "Loading book..." is shown, and Book content's value reads "Loading Moby-Dick", the Mac's words. Nothing is announced unless it takes more than 5 seconds; then the low-priority "Loading Moby-Dick" is said once.
- **A book that can't load:** the moving controls are replaced by the Mac's "Failed to load book" and the reason, as one element, and focus moves there. Back goes on working.
- **Errors while playing:** the Mac's error alert, with "Retry", "Try Again", "Cancel", and "OK", reading the error from the session's snapshot. Focus goes to the alert. When it closes, focus returns to Play.
- **Speech stops because the engine refused a passage:** the Mac's "Speech Stopped" sheet, with its Details text area, Copy Details, and Close, and its words made iPhone's (see "Words that say Mac"). Show Logs in Finder isn't there.

### The Bookmarks sheet

A sheet, with a `NavigationStack`. VoiceOver's order:

1. **Title:** "Bookmarks", a heading.
2. **Done:** toolbar button, the Mac's word. Closes the sheet.
3. **Add Bookmark:** toolbar button. Label: the Mac's "Add bookmark at current position". It opens the Add Bookmark sheet, with "Note (optional)", "Cancel", and "Add". **The place is taken when this opens,** not at Add, so a note written with the book playing doesn't land wherever the book has got to. Focus lands on the field.
4. **The list,** in the order they lie in the book. **Focus lands on the bookmark nearest before the place.** After a plain Add bookmark on the reader, that's the new one, so Edit Note is close.
   - Label: the Mac's, "Bookmark 3, The Battle, Note: Check this, added October 9, 2026".
   - Hint: "Goes to this bookmark and closes the list."
   - Actions: "Edit Note", "Delete". Delete of a bookmark with a note asks first.
5. **Empty:** the Mac's "No bookmarks yet." and "Add Bookmark adds one at the current position."

Choosing a bookmark closes the sheet, and goes there with the Return place kept. Focus returns to the Bookmarks button, and "What a move says" applies. After a delete, focus goes to the next row, or the row before, by the Mac's rule.

### The Headings sheet

A sheet, with a `NavigationStack`. VoiceOver's order:

1. **Title:** "Headings", a heading.
2. **Back to Book:** toolbar button, the Mac's, with its hint.
3. **Show levels:** a row opening `PhoneChoiceSheet`, the Mac's filter: "All levels", "Level 1", "Levels 1 to 2", and so on. Its hint is the Mac's "Shows only the headings up to the level chosen."
4. **Display:** a row opening `PhoneChoiceSheet`. Label: the Mac's "Heading info display mode". Choices: "Duration", "Time In", "Percentage".
5. **The list,** one row for each heading. **Focus lands on the current heading,** as on the Mac.
   - Label: the Mac's: "The Battle (current heading) - level 2, 1 hour, 3 minutes". "Skipped, " starts a skipped section's row.
   - Hint: the Mac's "Goes to this heading and closes the list."
   - Actions: the Mac's "Skip Section" or "Include Section".
6. **Empty:** the Mac's "No headings found in this document."

Choosing a heading works like choosing a bookmark.

### The Go To sheet

The Mac's three panels, in one sheet. VoiceOver's order:

1. **Title:** "Go To", a heading.
2. **Cancel:** toolbar button, the Mac's. Closes it.
3. **"Page",** a field, only in a book of more than one page. **Focus lands here, with its text selected,** so typing replaces it. In an audiobook, focus lands on the time field the same way.
   - Hint: the Mac's, "This book has 300 pages, from i to 300. Type a page as the book numbers it, such as 12 or xii."
   - It starts at the page being read.
4. **Jump:** a button after that field, the Mac's word. Label: "Jump to page".
5. **"Percent through the book",** a field. Hint: the Mac's "Type a percent from 0 to 100, such as 47.5."
6. **Jump:** Label: "Jump to percent".
7. **The time field:** the Mac's "Time in the recording" for an audiobook, or "Time at 500 words a minute" for a text book. Hint: the Mac's "Type a time, such as 12:04.3, 1:02:03, or 75.5."
8. **Jump:** Label: "Jump to time".

- Every field's keyboard is numbers and punctuation, which has a Go key. A decimal pad has none. The Go key is the same as Jump.
- Each field works as the Mac's. A field left at its starting value and jumped from closes without moving, as on the Mac.
- A refusal stays on the sheet: under the field, as the Mac's "Error: There is no page 400 in this book. Its pages run from i to 300.", and announced once. Focus stays in the field.
- A jump closes the sheet, focus returns to Go To, and VoiceOver says the Mac's "Jumped to page 12.", "Jumped to 47.5 percent.", or "Jumped to 1 hour, 3 minutes, 45 seconds in the recording.", once the sheet has closed, also while playing, since it was asked for.

### The Sleep Timer sheet

Rebuilt for the phone, with the Mac's words, in a `NavigationStack`. The Mac's view redraws each second with a changing label, which principle 3 forbids. VoiceOver's order:

1. **Title:** "Sleep Timer", a heading.
2. **Close:** toolbar button, with the Mac's hint.
3. **Current Timer,** when one runs: a heading, then its status (computed when focused), then the Mac's "Reset Timer" and "Cancel Timer".
4. **New Timer:** a heading, then the Mac's "Setting a new timer replaces the current one." when one runs, and "Pause playback after:".
5. **The presets:** 10, 15, 30, 45, and 60 minutes. Label: the Mac's "Set timer for 15 minutes and start playing". **Focus lands on the last timer used,** so a nightly timer is one double-tap.
6. **Custom:** "Custom timer minutes", a number-pad field; "Adjust minutes", a stepper by 5; and "Set".
7. **Stop At:** a heading, then the Mac's "End of heading" and "End of book", each with its label and hint.

- The hint "Return sets the timer" is the Mac's, and has no meaning on a phone: "Type the minutes, or change them 5 at a time with Adjust minutes. Set sets the timer and starts playing."
- The Mac's setting Close sheet after setting timer applies. On closing, focus returns to Sleep Timer. VoiceOver says the Mac's "Timer set for 15 minutes." once the sheet has closed, **and then the book starts,** so the words aren't lost under it.
- **How it counts on a phone:** see "The sleep timer on a phone".

### The Voice & Speed sheet

For a text book. Title: the Mac's "Voice & Speed for This Book". VoiceOver's order:

1. **Title,** a heading. **Close,** a toolbar button.
2. **Language:** a row opening `PhoneChoiceSheet`. The Mac's "Voice language filter".
3. **Voice:** a row opening `PhoneChoiceSheet`. Label: the Mac's "Select voice for this book". Each choice's label: "Samantha, Enhanced quality". A Personal Voice isn't listed, since it can't be rendered.
4. **Preview Voice:** the Mac's "Preview selected voice". A book that's playing pauses for it, and plays on after, as with Where Am I?.
5. **Speed:** the Mac's slider, "Speed", with the value "200 words per minute", in steps of 25.
6. **Pitch:** the Mac's slider, "Pitch", with the value "Normal (1.0x)".
7. **When this book ends:** a row opening `PhoneChoiceSheet`. Label: the Mac's "End of book behavior for this book". With a choice of its own: the Mac's "Use Global Default".
8. **Save to Global Settings,** and **Reset to Global Settings,** the Mac's.

- The Speed slider here is the same setting as the reader's Speed, as on the Mac, where this sheet's slider and the playback bar's buttons are one setting too.
- The voices are the iPhone's own, downloaded in Settings. Once the voices have loaded, an empty list says: "No voices are installed. Add voices in Settings, Accessibility, Read & Speak." **Unverified:** the path's wording on the phone.
- For an audiobook, the sheet is the Mac's Audio Settings for This Book: "Audio speed", When this book ends, and "Reset to Normal Speed".

### The Book Info sheet

Rebuilt for the phone, with the Mac's words. VoiceOver's order: the title "Book Information", a heading; Cancel and Save in the toolbar, after the title; the title field, "Book title"; the author field, whose label depends on the kind of book (below); then the read-only rows, each one element, its label and its value: "Format", "Added", "Last Opened", "Word Count". An EPUB adds "Publisher" and "Publication date" as fields, then "ISBN", "Language", "Identifier", and "EPUB Version". An audiobook has the Mac's "Artist or narrator", "Album name", "Genre", and "Year", then "Duration". The Mac's "edited by hand" follows a field's label where it applies. The author field is labeled by the kind of book, as the code shows it: a book with no more than a title and an author, "Book author"; an EPUB, "Author", the Mac's metadata editor's word; an audiobook, "Artist or narrator". The title field is "Book title" for all three. The Mac's "Also write to the library's copy of the EPUB file" isn't there: on iOS it can't write. Save closes the sheet, focus returns to Book Info, and VoiceOver says the Mac's "Metadata updated".

### Coming back the next day

- **The app is still running, or was suspended:** it comes back as it was, with focus restored only after a true background.
- **The app was killed,** with the reader on screen when it left: at launch, the Library's top appears with the reader pushed over it, paused at the saved place. VoiceOver lands on Play, then says the book's title with low priority. A book read from the Reading List still is.
- **The app was killed,** with the Library on screen: it opens on the Library, with the book in the Continue row.
- **A file opened from another app wins over reopening.**
- **The crash guard:** the app writes which book it's opening before it opens it, and clears that when the book has loaded or failed. If that's still set at launch, it doesn't reopen the book, and says with low priority: "TextMouth closed while opening Dune, so it wasn't reopened." Otherwise one book that crashes the reader would crash it at every launch, with deleting the app as the only way out.
- A magic tap, or a remote Play, plays from there. So the next day's first act can be a single gesture.
- The saved place loses at most 30 seconds of a kill: a checkpoint runs every 30 seconds of play, and every pause, stop, and move to the background saves and flushes.

## Listening with the screen locked

### The audio session

- **Category and mode:** `.playback`, `.spokenAudio`, no options. It keeps playing with the silent switch on and with the screen locked (with the `audio` background mode), and a navigation app's prompt pauses the book and hands it back, rather than talking over it. Apple names podcast players and audiobooks for this mode.
- **No options, because each costs something.** `.mixWithOthers`, `.duckOthers`, and `.interruptSpokenAudioAndMixWithOthers` all make the session mixable, and a mixable session can't be the Now Playing app. Bluetooth output to AirPods is implicit in `.playback`.
- **Set the category at launch,** which interrupts nothing. **Activate at Play,** whether from the button, the magic tap, a remote command, Where Am I?, Preview Voice, or the next book, never earlier, or opening a book would stop the user's music.
- **If activation is refused,** as during a call, Play doesn't start in silence: VoiceOver says, with high priority, "Can't play now: a call or another app is using the audio." and the book stays paused.
- **Stay active** through chapter changes, gaps, seeks, fades, and a pause in the foreground.
- **TextMouth stays the Now Playing app** from the first Play until the listener plays another app's audio or removes the book. A pause, and a deactivation in the background, leave its item on the lock screen. Apple's header says a non-mixable session may go active in the background "only when the app is the NowPlaying app", so this is what lets the next book, or a Play from the lock screen, start on a locked phone.
- **Deactivate,** with `.notifyOthersOnDeactivation`, after stopping audio, when: entering the background while paused; a sleep timer expiring in the background; a book ending with nothing to follow; or the book being removed. A paused book's engine is paused too first, or the deactivation fails as busy.
- **Activation blocks,** and Apple says not to do it where blocking would hurt. The first version activates on the main thread at Play, since Play is synchronous in shared code, and it logs how long it took. **Unverified:** whether that's ever long enough to hear.
- **VoiceOver's ducking isn't the app's to set.** No API touches it. It's the user's setting, under VoiceOver, Audio, Audio Ducking. The app's guide says so.
- The synthesizer uses the app's audio session, and doesn't take VoiceOver's voice settings, so the book reads in the voice chosen for it.

### Which speech path

- **The Mac's policy, unchanged:** direct `AVSpeechSynthesizer` speech at Play, the render into `AudioEngineService` behind it, and the engine from the next natural break. The user's rule is that speech never switches from direct to engine in mid-play, and this keeps it.
- **Three additions, on iOS alone:**
  - If finished rendered audio for the chapter is ready at Play, start on the engine, so nothing switches at all.
  - A word-progress watchdog: playing, not paused, and no word reported for several seconds means nothing is being heard, so it's a natural break, and it recovers at the last reported word.
  - No Personal Voice in rendering, since `write` can't take one and would play it aloud.
- **The biggest open risk on the phone:** one report (October 2026, unanswered) says direct speech pauses at the screen lock and resumes at unlock. If the first run confirms that, iOS goes engine-only, with a streaming feeder, which still never switches. **This is check 1.**

### What pauses and what resumes

One plain type, `PhoneAudioEventPolicy`, decides, and a small iOS file observes. Every observer is on the main queue, since the route change arrives on another thread and Swift 6 stops an app that runs main-actor code there.

- **An interruption begins** (a call, an alarm, Siri, a navigation prompt): the book counts as paused where it stopped, and the place is saved. A cancel of speech the app didn't ask for, during an interruption, isn't read as the engine refusing the text.
- **An interruption ends with "should resume":** the book plays on, with Rewind on Resume applied, as after headphones, but only if the interruption paused it. A book the listener had paused stays paused. Without "should resume," it stays paused until Play. Any Play tries to activate again, since an end isn't guaranteed.
- **Headphones out, AirPods gone** (`.oldDeviceUnavailable`): pause through the Mac's own route-change pause, so the Mac's rewind on resume applies. The Mac's two-second guard against a stray Play, which is for a macOS daemon, isn't used on the phone, so a Play as AirPods go back in isn't lost. **An override** does nothing. **A new device** invalidates the backend only, so the next Play starts cold on the new output.
- **The engine's configuration changes:** the engine stops itself. The same invalidation, and a natural break: playback goes on from the place, so the engine's silence isn't read as the chapter's end. The engine's start and its connections are wrapped to catch the exception AVFoundation raises for a bad hardware format.
- **Media services are reset:** close the reader, set the category again, and open the same book paused at its place, with no automatic restart.
- **AirPods out of one ear:** what arrives is expected to be a remote Pause and later a remote Play. These work as they are. **Unverified:** the exact order and reasons, which get logged at the first run.
- **Each handler is idempotent,** since a disconnect gives both an interruption and a route change, in an unstated order.

### The lock screen, Control Center, and AirPods

- **What's shown** (the system's choice of layout, the app's choice of words):
  - Title: the book's title. Artist: its author.
  - Rate: the speed in use, or 0 when paused; default rate the same speed.
  - For an audiobook, elapsed time and duration in the chapter. For speech, neither at first, since any figure would be an estimate.
  - The heading isn't shown as the album at first: it's updated only at a play, a pause, or a move, so it would go stale while the book plays on.
- **Commands,** by `PhoneRemoteCommandPolicy`:
  - Play, Pause, and Play/Pause: as on the Mac.
  - Next track and previous track: skip forward and backward by the book's navigation unit, as on the Mac. These are reported to be what the AirPods' double and triple press send. They take the same path as every other move, so they say what a move says.
  - Skip forward and skip backward by seconds: enabled only when the unit is a number of seconds, with that number shown; disabled otherwise, so that the lock screen never promises 15 seconds and moves a heading. The Mac's fixed 30 and 15 stay on the Mac.
  - Change playback position: an audiobook only, within the chapter. Optional in the first version.
  - All others stay disabled.
- **Registered at launch,** so a killed app that the system wakes for a Play can answer: with no reader, the handler plays the book in reach. **Unverified:** whether the system lets it go active there; the Now Playing rule above is what makes it possible.
- **The Mac's Release Media Controls** isn't in the first version's reader.
- **VoiceOver on the lock screen:** the system's labels on the system's buttons. The app controls only the words above. **Unverified.**

### The sleep timer on a phone

- The Mac's timer counts ticks of a repeating timer, and a tick that's late is lost. On iOS it holds a deadline, set at start and at each resume of the countdown, and each tick computes what's left from it. The rule that the countdown halts when the book pauses stays, so nothing needs to fire during a suspension, which only happens when nothing's playing.
- On any return to running, the deadline is checked first, and an expired timer expires at once, saying the Mac's "Sleep timer expired. Playback paused."
- An expiry in the background is wrapped in a background task: fade, pause, save, flush, deactivate. Every background task's expiry handler ends it, or iOS ends the app.
- Its spoken milestones are dropped on the phone (see "Announcements").

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

### How a library reaches the phone

The phone has a library of its own. A person's books come over in these ways, all in the first version but the last:

- **One book at a time,** from Files with Add to Library, or by Open In from Mail, Safari, Messages, or AirDrop.
- **Many books at once, with their places:** on the Mac, put a folder's books in a ZIP of TextMouth's book packages (the `.tmb` packages the Mac's library holds), and send it by AirDrop. The phone imports each book with its places, bookmarks, and settings, as the Mac does a ZIP of packages, and offers a folder for them, the Mac's "Create Folder for Imported Books?". Paths made on the Mac heal at the phone's launch. **Unverified:** that AirDrop offers TextMouth for the ZIP, and that the packages open.
- **A folder in the Files app to drop books in,** "On My iPhone, TextMouth", where Finder can copy books over USB, and whose folders become library folders: a slice after the first version's core, and a question at the end.

### Adding a book

The Add to Library sheet, in a `NavigationStack`. VoiceOver's order:

1. **Title:** "Add to Library", a heading.
2. **Cancel:** toolbar button.
3. **"Open Book…"** a row, the Mac's word. Its summary is the Mac's "Opens a file picker to import books in any format TextMouth reads." Focus lands here.
4. **"Import Folder…"** a row. Its summary is the Mac's "Chooses a folder that holds a DAISY book or audio tracks and imports it as one book."

Later items, as they arrive: New from Text…, Add Feed…. New Recording… isn't offered.

- **One file picker,** SwiftUI's `fileImporter`, set for books (several at once) or a folder by which row was chosen. Two on one screen are reported not to work. The system's picker is VoiceOver-accessible by Apple's own design.
- **The sheet closes before anything is said.** Then VoiceOver says, once, "Importing Dune", or "Importing 3 books".
- **The picked files are security-scoped and may not be downloaded,** so one iOS step runs first, on a queue of its own, never the import queue: hold them until the library has started; check there's room for twice the size; start the scope; copy each file under file coordination, with progress, into a scratch folder of the app's own, keeping the file's name, since the book's title comes from it; stop the scope; and hand the local copies to the shared import. Nothing reads a picked file plainly.
- **A file that's only in iCloud** downloads first, as part of the copy. The progress card says "Downloading “Dune”", and after 2 minutes without progress the copy is cancelled and VoiceOver says: "“Dune” couldn't be downloaded from iCloud. Check the connection, then add it again." Cancel Import cancels the copy too. **Unverified:** how a file provider behaves offline.
- `UIDocumentPickerViewController` with `asCopy` isn't used: Apple's engineer called its truncated copies a bug.
- Books go in the folder the Library showed last, as on the Mac.
- **After the import,** focus stays where it was, and VoiceOver says the Mac's "Finished importing “Dune”." with low priority, however short the import. The book's row is in the list.
- **The screen stays awake while an import runs and the app is in front,** so Auto-Lock doesn't stop it.

### From other apps

- **No share extension in the first version.** Reports say document types are enough to put the app in the share sheet for a file in Mail or Files. Photos need an extension, and Messages isn't covered by any source. **Unverified.** An extension would cost an App ID, an app group, and much lower memory, and it's poor for a 2 GB audiobook.
- The app's document types list the Mac's formats less those iOS refuses (Ogg and other converted audio, CAF, and the three braille formats), so no app offers TextMouth a file it would refuse. TextMouth's own book package and ZIPs are on the list.
- A file from Files arrives where it lies, security-scoped. A file from Mail arrives as a copy in the app's Inbox. Both take the same path as a picked file.
- **With no book playing,** the book opens when it's imported, with focus on Play, as the Mac's opened file does.
- **With a book playing, it's imported and not opened.** The listener's book goes on, and focus stays where it is. VoiceOver says, with low priority, "Finished importing “Dune”."
- **At a cold launch,** a file wins over reopening the last book.
- The Inbox copy and the scratch copy are removed once the import is over and no question waits. The Inbox and the scratch folder are swept at launch, too. The question about deleting the original isn't asked for a copy the app made.
- A file arriving during another import waits its turn.

### Progress

- **A card at the top of the Library's list,** rebuilt for the phone with the Mac's words: "Importing Books", "Book 2 of 10: “Dune”, Reading its text", "About 3 minutes left", and the Mac's Cancel Import. It isn't a modal, so everything goes on working around it. Its words are read when VoiceOver asks; it announces nothing as it moves.
- **VoiceOver order:** after the title, before the search field.
- **While no book plays,** the Mac's quarter announcements are kept, with low priority: "25 of 100 books processed, about 4 minutes left". While a book plays, they're dropped.
- **Going to the background:** each import runs in a background task, about 30 seconds, more if a book is playing. A suspended import resumes where it was. A killed one leaves only a hidden staging folder, which is cleared at launch. The shared import publishes a book by one rename, so there's never half a book.
- **Coming back:** VoiceOver says, with low priority, what happened while away. Its name is kept in a small file while an import runs, so a killed import can be named at the next launch: "Importing “Dune” was stopped when TextMouth closed. Add it again."
- **iOS 26's continued processing task** is the better tool for a long import, with a Live Activity. It's the first follow-up.

### Import questions

- On iOS the Mac's presenter never shows a question, so a duplicate would wait for ever. The phone presents the waiting question itself, in a sheet rebuilt with the Mac's words, which can't be swiped away: only an answer settles it, and its Cancel is the question's own.
- The Mac's three buttons in a row become a vertical list, with the Mac's words and hints: "Keep Both", "Replace Existing", "Cancel"; and "Create Folder", "No Thanks". Focus lands on the question's text.
- The sentence "The existing copy's files go to the Trash" becomes: "The existing copy's files are deleted."

### What can't be imported, and what it says

- **Audio that needs converting** (Ogg, Opus, AC-3, AMR, MP2, CAF), the file named and the next step given: "“Radio Drama” is in Ogg, which TextMouth on iPhone can't play yet. Add it on your Mac, then send the book here." The kind is named as the Mac names it ("Ogg", "Opus", "AC-3"). A ZIP holding such tracks says the same.
- **Word 6 and Word 95:** "“Notes” is a Word 6 or Word 95 document, which TextMouth on iPhone can't read yet. Add it on your Mac, then send the book here."
- **Braille books (BRF, BRL, PEF):** "“Ledger” is a braille file, which TextMouth on iPhone can't read yet. Add it on your Mac, then send the book here."
- **An M4B, M4A, or MP4:** these must import. The iOS stand-in for the helper that asks a file what it holds answers "could not start" rather than throw, so the file is left as it is and played by the system's player. A protected M4B says so at Play, as the Mac's failure sentence does.
- **Any other failure:** the Mac's "Could not import “Dune”. Reading its text failed: …", in an alert titled "Nothing Imported", with OK.

## Errors, empty states, long operations

- **The library is empty, at first launch:** after the title and search, one row: "Your library is empty. Add to Library adds a book." with the rest of the list absent. Focus lands on the title as usual.
- **An empty folder:** the section heading "Books (0)", then a row: "This folder is empty."
- **No matches in search:** a row, "No books match.", and it's said once with low priority.
- **A library that can't be read or found:** the phone's library is in its own container, so this should be rare. The Mac's words of `DataDirectoryUnavailableText`, without its Quit button or its advice on choosing another folder, and with the Mac's Try Again.
- **Saving fails, such as on a full disk:** the Mac's "Storage problems" notice, with Retry and Dismiss, at the top of the Library's list.
- **Reading the library's text again at launch** (after an update): the Mac's words, "Extracting Text", in a card like the import's.
- **A very long book opening:** see "While the book is loading".

## Settings

A pushed `Form`, with real section headings. On the phone: fewer settings than the Mac, and the same words for each. Everything here is a `SettingsViewModel` property the Mac has, and each change takes effect as on the Mac.

### VoiceOver's order

The Settings screen, in this order, with its sections as headings. Focus lands on the title.

**Voice:**

- "Language", label "Voice language", a row opening `PhoneChoiceSheet`, with "All".
- "Voice", label "Select voice", hint "Choose a voice for reading. Change takes effect immediately.", a row opening `PhoneChoiceSheet`.
- "Preview Voice", label "Preview selected voice". It speaks the Mac's "Hello! This is TextMouth, ready to read for you." A book that's playing pauses for it.
- "Default speed", a slider in steps of 25, value "200 words per minute". Caption, as the hint: "Default speed for new books. Each book can override this with its own speed."
- "Default pitch", a slider, value "Normal (1.0x)". Caption, as the hint: "Default pitch for new books. 1.0 is normal. Each book can override this."

**Navigation:**

- "Navigation unit for text books", a row opening `PhoneChoiceSheet`, default "Sentence".
- "Navigation unit for audiobooks", the same, default "15 seconds", without Sentence and Paragraph.
- Hint for both: "What a book of this kind moves by until it has a unit of its own."
- "Auto-play after navigation", a switch. Hint: "When enabled, playback starts automatically after jumping to a heading, bookmark, or search result".

**Rewind on Resume:**

- "Rewind to", label "Rewind on resume unit", hint "When resuming playback, rewind to the start of this unit": "None", "Sentence", "Paragraph", "Heading".
- "Smart mode", label "Smart rewind mode", hint "Only rewind if the pause was longer than the threshold".
- "Minimum pause threshold", a stepper, value "70 seconds". Hint: "Don't rewind if paused for less than this."

**Punctuation Pauses:**

- "Punctuation pause level", a stepper, value "Off", "Subtle", "Moderate", or "Heavy". Hint: the Mac's caption, "0 = Off, 1 = Subtle (periods), 2 = Moderate (+ commas), 3 = Heavy (+ paragraph breaks)".

**End of Book:**

- "When book ends", label "End of book behavior", hint "What happens when a book finishes playing", a row opening `PhoneChoiceSheet`: "Stop", "Stop, and Play Starts Over", "Loop to Start", "Continue to Next Book". Its caption is the Mac's: "With "Stop", Play on a finished book says it is finished; with "Stop, and Play Starts Over", Play starts it again from the beginning."

**Sleep Timer:**

- "Fade out duration", a stepper, value "Off" or "5 seconds". Hint: "Gradually reduce volume before pausing when the sleep timer expires. 0 pauses instantly."
- "Close sleep timer sheet after setting a timer", a switch. Hint: "When off, the sheet stays open showing the remaining time and a reset button".

**Reading:**

- "Follow in Braille", a switch, off. Hint: "While the book plays, moves Book content on with the speech, even while you're reading it. For trying out with a braille display." It's here so a first run can decide question 10.

**Times:**

- "Include the speed with time left and total time", a switch, with the Mac's hint.

**Pages:**

- "Show the page on the reader screen", and "Say the page in Where Am I?", switches, with the Mac's hints.

**Removal Behavior:**

- "Confirm before removing a book", a switch.

**Statistics:**

- "Reading Statistics", a row that pushes the Mac's statistics view, unchanged: "Today", "This Week", "All Time", "Current Streak", "Books Finished This Year", "Books Finished All Time", "Recently Finished".

**About:**

- "Version", a static row, such as "0.4.0".
- "Share Logs…", a button: the iOS share sheet with the app's recent log text. Without this, a first run on a phone can't be diagnosed. Hint: "Shares TextMouth's recent logs as a text file. They hold no book text."

### What the phone leaves out, and why

- **Keys:** the Shortcuts tab, Shift+Skip units, and double-press time. Keys on a Bluetooth keyboard are deferred.
- **The Mac's Skip Forward and Skip Backward units:** on the phone one unit serves both directions, so the two navigation-unit defaults take their place.
- **Mac windows:** Open the next book in, and the reader toolbar and bar choices. A phone has one screen of its own. These settings are set by the app at every launch and not shown: Navigation unit controls at One Unit for Both Directions.
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
- "Now Playing: Emma".
- "Moves back or forward by sentence.", "Chooses what Play and the skip buttons move by.", "Changes the speed in steps of 25 words per minute."
- "Moves to the heading before, leaving the navigation unit as it is.", "Moves to the next heading, leaving the navigation unit as it is."
- "Plays from here.", "Brings the text to the sentence being spoken."
- "Opens the list of bookmarks.", "Opens the list of headings.", "Goes to a page, a percent, or a time.", "Opens the sleep timer.", "Goes back to where the last jump began."
- "Go To", "Jump to page", "Jump to percent", "Jump to time".
- "No next heading." and its kin, "Start of the book.", "End of the book."
- "Off", for a sleep timer not running.
- "Book content, this audiobook has no text." and the heading.
- "Remove Bookmark 3?", "Remove".
- "Your library is empty. Add to Library adds a book.", "This folder is empty.", "No books match.", "The reading list is empty. To add a book, choose Add to Reading List from its actions."
- "This deletes the book and its files from this iPhone, and they can't be recovered. Your Mac's library isn't touched."
- "Importing Dune", "Importing 3 books", "Downloading “Dune”", "“Dune” couldn't be downloaded from iCloud. Check the connection, then add it again."
- "“Radio Drama” is in Ogg, which TextMouth on iPhone can't play yet. Add it on your Mac, then send the book here." and its two kin.
- "Importing “Dune” was stopped when TextMouth closed. Add it again."
- "TextMouth closed while opening Dune, so it wasn't reopened."
- "Can't play now: a call or another app is using the audio."
- "Navigation unit for text books", "Navigation unit for audiobooks", "What a book of this kind moves by until it has a unit of its own."
- "Follow in Braille", and its hint.
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

- **The whole-book Read Text screen,** with VoiceOver focus as the place. It's a screen pushed from Book content, and the reader's controls stay.
- **Follow in Braille as a design,** beyond the test switch.
- **Sounds,** once the user decides which.
- **Search in Book:** the Mac's search model is shared, and it's the one way to find a line, so it's the first addition after the core: a sheet, and a button after Headings.
- **The drop folder in Files** (see "How a library reaches the phone").
- **Next and Previous in Folder and in Reading List:** two more buttons in the reader. **Speak Info.** **Edit Mode** for many books at once. **The Reading List's options.** **Folder Settings.** **The view editor.**
- **Restart Sleep Timer without unlocking,** from the AirPods' gesture as on the Mac, or by a shake, as some audiobook players do.
- **App Shortcuts,** for the Action Button, Back Tap, and Siri: Where Am I?, and a bookmark from a locked phone.
- **Keys on a Bluetooth keyboard:** Space and W first, from the Mac's list.
- **Feeds:** the engine is shared. Downloads need background transfers, and refreshing needs a background task. A Feeds view returns in the Library view's choices.
- **Transcription:** iOS 26 has the Mac's speech analyzer. A long job as a continued processing task.
- **Export:** the shared writers, through the system's save sheet.
- **Editing text:** an editor of the app's own, since iOS has no round trip through another app. The New from Text view is a start.
- **Braille books:** liblouis in the app, on one serial queue, if the user wants it (question 7 of November 3).
- **Recording, and the audio editor:** a last phase, suiting an iPad first.
- **A library shared with the Mac,** or just places shared: question 3 of November 3. Shared places are what a person moving between the two would miss most.
- **Ogg:** a later decoder of Xiph's, never Apple's inside the app.

## How it fits an iPad

- The first version runs on an iPad as it is, as a compatible layout: the one navigation stack in the full window, and sheets as form sheets. No code assumes an iPhone's width: lists and forms size themselves, and the reader's controls sit in a centered column of limited width.
- **Later,** a `NavigationSplitView` puts the Library beside the reader. iPadOS windows can give each book its own, as on the Mac, with `openWindow`. Then the "one reader" rule loosens to `PhoneSession` per scene, and Mac-style commands appear in the iPadOS 26 menu bar with keyboard shortcuts from the Mac's list. `MagicTapWindow` works per scene already.
- **Nothing in the first version's order changes on an iPad,** since it's the same screens.

## The map to the code

`Scripts/agents/briefs/2026-11-07/iosui-research/research-code.md` has every function with its file and line, and `review-engineer.md` beside it the findings this section follows. This section says how the new code sits on the old.

### Where the new code goes

- **`TextMouth/Phone/`:** plain types, compiled into both apps, tested by the Mac's test host, importing no UIKit. Only the iPhone's views and their tests use them: new shared code the Mac never calls. `make mac-projection` skips this folder, and a scan test requires that nothing outside it and `Platform/iOS/` names a `Phone` type outside `#if os(iOS)`. No new `@unchecked Sendable` or `nonisolated(unsafe)`: a policy test pins their counts.
- **`TextMouth/Platform/iOS/`:** SwiftUI views and everything that names UIKit, AVAudioSession, or another iOS-only API. Views stay thin. Since November 8 its code is tested in the iOS simulator: hosted unit tests in `TextMouthiOSTests/`, and XCUITests of the Library and the reader in `TextMouthiOSUITests/`.
- **The iOS `Info.plist`:** `TextMouth/Platform/iOS/Info.plist`, written from the Mac's by `Scripts/ios/sync-info-plist.py` (`make check-ios-plist` says when it is stale), with the keys only iOS needs: the audio background mode, and one scene at a time. Until November 8 it was a file of its own at `iOSApp/Info.plist`; main's merge made the two one. The icon and any sounds come later.
- **Shared files:** changes only behind `#if os(iOS)`, each named in a report.

### The app's frame

- **`TextMouthAppDelegate`:** `@main`, `UIResponder`, `UIApplicationDelegate`, in `Platform/iOS/App/`. It makes `PhoneAppModel` in `didFinishLaunching`, which a background launch also reaches. `application(_:configurationForConnecting:options:)` names `TextMouthSceneDelegate` as the delegate class. It sets the audio category and registers the remote commands at launch. It implements the magic tap too.
- **`TextMouthSceneDelegate`:** creates `MagicTapWindow(windowScene:)`, whose root is a `UIHostingController` holding `PhoneRootView`. It hands every event to `PhoneLifeCycle`: opened files (from `scene(_:openURLContexts:)` and the launch options), entering the background, coming to the foreground, and becoming active. No slice edits the delegate after the first.
- **`Info.plist`:** the scene manifest with one scene, the `audio` background mode, the document types, and the imported and exported type declarations the Mac's plist has. A test reads it on the Mac.
- **`PhoneAppModel`:** `@MainActor`, shared. It makes `LibraryViewModel`, `SettingsViewModel`, `SoundEffectService`, and `PhoneSession` in the Mac's order, applies `PhoneDefaults`, and holds the navigation path, `[PhoneRoute]`, which `NavigationStack(path:)` binds to.
- **`PhoneRoute`:** `.folder(path)`, `.reader`, `.settings`. `.reader` carries no book: the reader's screen is never rebuilt for the next book, so focus survives it.
- **`PhoneRootView`:** the `NavigationStack`, and one modifier for each slice's presentations, each in its own file.
- **`PhoneDefaults`:** set at every launch, before any reader: the Mac's unit-control mode One Unit for Both Directions (in the Mac's default mode a book's own unit is ignored), Trash off, Keep Original; and the two navigation-unit defaults.

### `PhoneSession`, the owner of the reader

A shared `@MainActor` `ObservableObject`, with tests on the Mac:

- Makes a reader through an injected closure, the Mac's `makeReader` by default, sets its sound service at once, and refuses a book that isn't in the library.
- **At most two readers:** the one listened to, and one opened and not yet played. Play in the second pauses the first by the shared code's own rule, and the session closes the first on the main queue's next turn. Leaving the second unplayed closes it.
- **A book counts as opened** at its first Play, move, or reading: `noteBookEngaged()`.
- **The magic tap:** `togglePlayPauseFromAnywhere() -> Bool`, by "The magic tap". The book in reach: the open reader's, else `lastOpenedBook`, else the newest Last Opened, else none.
- **Play while loading:** `playWhenLoaded`, consumed when loading ends without an error, forgotten at a second press.
- **The next book:** listens to `.continueToNextBook` and `.openBookWindow`, which only the Mac's app delegate started before. On the main queue's next turn, it makes the new reader first, gives it the Now Playing item, and then closes the old one, so TextMouth stays the Now Playing app on a locked phone.
- **Reopening, and its crash guard,** in preferences written synchronously.
- **Publishes a small snapshot,** title, playing, loading, and an error, so that no view observes the reader's 8 Hz.
- **Moves:** `ReaderPhoneHooks`, a struct of closures on the reader under `#if os(iOS)`, sends the AirPods' and the lock screen's skips to the phone's own move path, and gives the audio slice its `audioMayStart` and `audioEnded`.

### Holding back what a move would say

- `VoiceOverAnnouncer.collectingAnnouncements(during:)`, an extension in `TextMouth/Phone/`, swaps the announcer's poster around one synchronous call and puts it back in a `defer`. The announcer itself doesn't change, so the Mac doesn't either.
- Every move's own words are posted synchronously, after the move, so collecting works. What's said later, such as a sleep timer's end or a cloud message, isn't collected and still reaches VoiceOver.
- `PhoneMoveFeedback` sorts what was collected: the last word of a structural move is the move's own; the rest pass; a move in seconds has no words of its own.
- The same collector wraps the speed and unit changes, keeping nothing.
- Whether a move happened is the cursor before and after.

### Paths

- `TextMouthRuntime.realHomeDirectory`, under `#if os(iOS)`, returns `NSHomeDirectory()`. On a phone the user database names `/var/mobile`, and in the Simulator the user's **real** `~/.TextMouth`.
- `TextMouthPaths.defaultRoot(in:)`, under `#if os(iOS)`, is `Library/Application Support/.TextMouth`: not the container's top, which isn't writable, and not `Library/Application Support/TextMouth`, which the legacy migration reads as an old library.
- Hidden from Files. Backed up, but see the questions on audiobook audio.
- `Book.filePath` is absolute, and a free team's reinstall every 7 days moves the container. The launch's path repair heals a book.
- No session lease on the phone: its library is never shared.

### The Mac's views: what's used

- **Used as they are:** the load failure view, the heading and bookmark rows, the operation failure notice, the work indicator, the storage problems notice, and the statistics view.
- **Rebuilt for the phone, calling the same model and wording:** the Library, its rows, the reader, the five folder sheets, Book Info, the import question, the progress card, the sleep timer, the Bookmarks, Headings, Go To, and Voice sheets, the error alert, and Settings. The Mac's sheets can't be wrapped: their buttons are in their bodies, they don't scroll, a `Picker` in them is a menu here, and the sleep timer's redraws each second. No Mac view changes.
- **Not used:** the Mac's Library and reader windows and views, its book commands, its menus, and its Settings window.

### The stand-ins that must become real

- **Focus:** `PhoneFocusPolicy`, `PhoneFocusRegistry` (each control's view, by kind), and `PhoneListFocus` (rows).
- **The helper that asks a file what it holds** answers "could not start", so M4B imports.
- **Import questions:** the phone presents the queue itself.
- **Now Playing:** route and interruption handling, and a fallback for a Play with no reader, behind `#if os(iOS)` in the shared service, since the methods it needs are private.
- **Speech:** the interruption's flag, and the word-progress watchdog, armed only after a play's first word, under `#if os(iOS)`.
- **The audio engine:** the configuration change observed per engine, a pause of the engine before deactivating, and caught exceptions, under `#if os(iOS)`.
- **The sleep timer:** the deadline, and milestones crossed rather than matched, under `#if os(iOS)`.
- **The memory guard:** `os_proc_available_memory()`, never quitting, and idle if its first reading is 0.
- **Sounds:** nothing yet.

### Plain types and their tests

Each is shared, in `TextMouth/Phone/`, with a test class of the same name plus `Tests`:

- `PhoneSession`, `PhoneDefaults`, `PhoneRoute`, `PhoneLifeCycle`.
- `PhoneAnnouncer`, and the collector.
- `PhoneFocusPolicy`: the arrival state machine, with injected time.
- `PhoneLibraryRows`, `PhoneRowWording`, `PhoneLibraryVocabulary`.
- `PhoneControlDescription`, `PhoneReaderControls`, `PhoneReaderModel`: every reader control's words and traits for a plain state, computed once per turn of the main queue.
- `PhoneNavigationUnits`, `PhoneMoveFeedback`, `PhonePassagePolicy`.
- `PhoneRemoteCommandPolicy`, `PhoneAudioEventPolicy`, `PhoneNowPlayingInfo`.
- `PhoneSleepDeadline`.
- `PhoneImportHolding`.
- The panels' models, and the settings' model and vocabulary.
- `IOSInfoPlistTests`: the background mode, the one scene, and a declaration for every type the importer names.
- Every vocabulary test reads the Mac's own source file and requires each inline word to be there word for word.

## The implementation slices

In order. Each is a branch off `ios/interface`, merged only after both type-checks and its tests pass. The train runs its test classes, plus the classes any shared change can break. The briefs are in `Scripts/agents/briefs/2026-11-07/iosui-slices.md`.

- **Slice 1, the foundation:** the frame, the plist, the paths, the M4B fix, `PhoneSession` with two readers, the next book, the crash guard, `PhoneDefaults`, `PhoneRoute`, `PhoneLifeCycle`, the reader's hooks, the announcer's collector and mapping, the focus policy and registry, the reader's sheet list, the root's modifiers, and the policy tools.
- **Slice 2, the Library:** its screens, rows, search, the Continue row, sorting, views, removal, and Book Info.
- **Slice 2b, the folder sheets,** split from the Library.
- **Slice 3, importing:** Add to Library, the copy, other apps, progress, questions, refusals. Then the drop folder, if time allows.
- **Slice 4, the reader:** its controls, Book content, the moves and their words, loading and failure.
- **Slice 5, audio:** the session, interruptions, routes, the engine, Now Playing, remote commands.
- **Slice 6, the life cycle:** saving, memory, thermal state, silent gaps, the sleep timer's deadline, reopening.
- **Slice 7, the reader's panels:** the sheets, and Where Am I?. Then Search in Book, if time allows.
- **Slice 8, VoiceOver:** the rotors, Read All, escape, and a sweep of every screen.
- **Slice 9, Settings,** with Share Logs first.

**If the night is cut short, in this order:** the foundation and Share Logs; Open Book and the duplicate question; audio's core; the reader's core (Play, Book content, Where Am I?, Navigation unit, the skips); the background flush. Cut first: the rotors, Read All, the Library's other views, the panels but Headings, then the rest of Settings.

## The hand-check list

To follow with VoiceOver on the iPhone once the iOS platform is there. Order matters: the first few decide the most. Say which version of iOS the phone runs: iOS 27 shipped in September, and this was built against the iOS 26 SDK. If Xcode 26.0.1 can't install to it, that comes first.

### First: does it run at all

1. It installs, it opens to the Library, and VoiceOver reads it. Open Settings, and note the version. Share Logs works.
2. Add a short EPUB from Files with Add to Library, then Open Book…. The sheet closes, "Importing" is said, its row appears, and VoiceOver says the import finished. Add an M4B the same way.
3. Close the app from the App Switcher, and open it again. The library is still there.

### Speech and the lock

4. Open a text book, double-tap Play, then press the side button. Does it go on speaking? For five minutes, then for two hours, with memory and battery noted from the logs.
5. Pause and play again, so that it's on prepared audio, and repeat.
6. Does TextMouth appear on the lock screen, on each path?
7. Let a chapter end while locked. Let a book end with Continue to Next Book, while locked. Does the next book start?
8. Does opening a book stop your music, before any Play?
9. With a compact voice and an enhanced voice, is spoken-audio mode audibly worse than the default mode? One report says so.

### VoiceOver on Play

10. Double-tap Play. Does VoiceOver stay silent? Is the book's first word lost? Double-tap Pause: does it say "Play"?
11. Swipe up and down on Play while it plays. What does VoiceOver say each time, with no value? If it says "Pause", try the one-space value. This decides the central gesture.
12. Swipe up and down on Play while paused, with hints on and off. Is the new place's sentence said, and shown on a display?
13. Up is forward on Play. From a display, Dot 3 with Space moves forward and Dot 6 back. Pass or fail.
14. Flick to Navigation unit and swipe; double-tap it for the list; flick back to Play. Is Adjust selected by itself?
15. Flick right within a second of opening a book. Are you thrown back to Play?
16. Find Play, Where Am I?, and Next Heading by touch. Does Item Chooser list every control by a usable name?

### The magic tap

17. On Play, in the Library, in a sheet, and in an alert.
18. In the search field: dictation must win.
19. With no book ever opened: the system's own action.
20. On the lock screen, and in another app.
21. With the phone ringing, locked and unlocked, with TextMouth in front: the call must be answered.
22. During a call, and with iOS 26's Media Playback switch off.
23. Dots 1-5-6 with Space at a cold reopen, before TextMouth has played: does Music start instead?

### The reader's elements

24. Flick through every element with the book playing. Are they in the spec's order? Is anything spoken without your flick? Leave focus on Where Am I? and on Sleep Timer for a minute: does either speak by itself?
25. With Audio Ducking off, When Speaking, and Always: flick during speech. Does anything pause? Do the two voices interfere?
26. Twist to Headings, Pages, and Bookmarks on Play. Flick down twice. What is heard, and where is focus after? This decides the rotors.
27. Next Heading twice. Previous Heading. Bookmark by unit while playing: is "Bookmark 3" said?

### Focus

28. Open a book: does focus land on Play, and stay? Go back: does it land on the book's row, in a list of 700? Open each sheet and close it: does focus land where the spec says, and return to its button?
29. Swipe down Control Center and close it. Take a call banner. Lock and unlock. Go to the Home Screen and return. Where is focus each time?

### Reading the text

30. Pause. Move left from Play to Book content. Does it start at the sentence just spoken? Lines, Words, and Characters on the rotor; the Sentences rotor.
31. Read three paragraphs in, then double-tap: does the book play from there? Does Return go back?
32. Three-finger swipes: the next and previous passage. Two-finger swipe down: does Read All go on past the passage? Does stopping leave the place there?
33. Leave focus on Book content with the book playing. Does its text stay still? Turn on Follow in Braille, and try again with a display.
34. Auto-Lock while reading Book content: does the screen stay awake?

### Braille

35. Item Overview at 2 to 7 cells: can you tell the reader's elements apart? Read the values of Navigation unit, Where Am I?, and Return at 14 and 20 cells.
36. Dots 3 and 6 on Play and on Navigation unit. Dots 3-6, and a router key, to activate. Dots 1-2, escape. Panning through Book content, and Turn Pages when Panning.
37. Announcements: how long do they stay? Are they in the announcement history?
38. Sound Curtain on: does it mute the book? Touch Curtain: is everything still possible? Reading along with VoiceOver's speech off.
39. Type in the search field with the display and with Braille Screen Input.

### Lock screen and AirPods

40. Are the title and author right? Does VoiceOver read the buttons? Which side buttons show with a unit of 15 seconds, and with Sentence?
41. AirPods: one out and back; both out; into the case; a stem press once, twice, and three times. Note what each does; the logs say what arrived.
42. Lock-screen Play after a minute, an hour, and after the app was killed.
43. Wired headphones out on speech and on an audiobook. AirPods in while it plays.
44. A phone call, taken then ended, locked and unlocked: does the book come back with its rewind? Play during the call: is the reason said? Siri. An alarm. A Maps prompt: does it pause and hand back?
45. In Settings, Developer, Reset Media Services, during speech.
46. Voices that report words oddly, such as Eloquence or a Novelty voice: does the word-progress watchdog restart them at one word?

### Files and the life cycle

47. From Mail, Safari, Files, Messages, and AirDrop: share or open an EPUB, with TextMouth closed and open. Does TextMouth appear? Does the book open with focus on Play, and is a playing book left alone?
48. A ZIP of the Mac's book packages, by AirDrop: do the books arrive with their places? Make a folder for them.
49. A file in iCloud Drive that isn't downloaded, with and without Airplane Mode. A 2 GB audiobook. A folder of tracks. An Ogg file and a ZIP of Ogg tracks: is the sentence right?
50. An import, then leave the app, with a book playing and without. An import, then close it from the App Switcher.
51. Double-tap a row by mistake while a book plays. Is the book still playing, and still New? Back: is all as it was?
52. Close from the App Switcher while playing. How far back is the place? Does the next launch reopen the book, paused, on Play, and say its title? Close it from the Library: does it open on the Library?
53. Reinstall over the top, as a free team must every 7 days. Do the books still open?
54. The sleep timer over an hour, locked. Does it stop on time?
55. Launch time with a large library. Flick speed in a list of 700 rows.
56. Settings, Reading Statistics, the Voice sheet, Book Info, and the folder sheets, each in order.
57. Share Logs from Settings, and send them over. They hold the first run's answers.

### Read All and the scrub

Read All is VoiceOver's two-finger swipe down. The scrub is its escape gesture, a two-finger Z-shaped stroke, or Dots 1-2 on a braille display, as item 36 has it.

58. Pause, focus Book content, and Read All. Does it read on past the end of the passage into the next one by itself, without a swipe? Does it say a page-scrolled status at each turn?
59. Stop Read All partway, with a two-finger tap. Is the place where the reading got to? Does Play start from there? Does Return still go back to the place from before?
60. Read All to the end of a chapter, into the next, and at the end of the book. Does it end at the book's end, with VoiceOver's boundary sound and no error?
61. Start the book, then Read All in Book content. Does the book play on where it is, with only the text moving?
62. Scrub in the reader. Do you go back to the Library with the book still playing, and does focus land on the book's row?
63. Scrub in a folder. Do you go back to its parent? Scrub at the top of the Library: does nothing happen, and nothing break?
64. Type a search, then scrub. Is the search cleared, the list back, and focus on the field? Search inside a folder and scrub twice: does the first clear the search and the second go back?
65. Scrub on each sheet: Add to Library, Settings, Bookmarks, Headings, Go To, Sleep Timer, Voice & Speed, Book Information, and the folder sheets. Does each close, and does focus return to the button that opened it?
66. Scrub on the import question. It must stay open: only an answer settles it. Scrub on a folder sheet while it works: it must stay open too.
67. Scrub with a braille display (Dots 1-2) in each of those places. Is it the same as the gesture?

## The open questions

Each with a recommendation, and what's built meanwhile. None stops the work. These are for the user, on top of questions 1 to 4 and 6 of `humanQuestions/2026-11-03.md`.

1. **Your iPhone's iOS version.** If it runs iOS 27, Xcode 26.0.1 may not install to it, and first-run behavior may differ from this SDK's documentation. Please say which it runs. It decides whether anything installs.
2. **The skip buttons.** They do what adjusting Play does, and they're last in the order, so they cost nothing on the way.
   - Keep them as built, take them out of VoiceOver's order only, or remove them?
   - Recommended: as built.
3. **One unit, or one for each direction.** The Mac can have a forward unit and a backward unit.
   - Recommended: one, since Play's adjusting moves both ways.
4. **Where Am I?, spoken by the app or by VoiceOver.** The app's voice pauses the book and uses the Mac's tested path. Its element's value gives braille the place either way.
   - Recommended: the app's voice, as built.
5. **Play's sounds.** The Mac's Play, Pause, and skip sounds are macOS's system sounds, which don't exist on iOS and can't be copied.
   - Sounds on the phone, made how: short new ones of our own, or none, with the book as the feedback?
   - Recommended: none in the first version, then decide after using it.
6. **Audiobook audio in iCloud backup.** A large library could fill a small iCloud plan and could make the phone's whole backup fail. If it's left out, a restored phone has books with missing audio.
   - Recommended: leave audiobook audio out of backup, as a setting, with the text and records backed up. Decide before a large library goes on the phone.
   - Built: everything is backed up.
7. **A folder in the Files app to drop books in,** "On My iPhone, TextMouth", for books copied over USB from Finder, its folders becoming library folders.
   - Recommended: yes, as the reviewer reading as the user argued, after the core; with question 6 decided first.
8. **Search across the whole library,** from any Library screen, with folders among the results. The Mac's search covers only the place shown.
   - Recommended: as built, the whole library.
9. **A page, a bookmark, and an audiobook's heading speak their short word while the book plays,** and a sentence's move is silent.
   - Recommended: as built.
10. **Follow in Braille.** Should Book content advance with speech, for someone reading along on a display, even while they read it? There's a test switch in Settings, off.
    - Recommended: try it after the first run, and decide then.
11. **Up is forward on Play,** as Voice Dream has it and as "increase" means, though on a rotor down is next, and from a display Dot 3 then moves forward.
    - Recommended: as built; the first run says whether it's bearable.
12. **The sleep timer's spoken milestones,** at 5 minutes, 1 minute, 30 and 10 seconds, are dropped on the phone.
    - Recommended: as built. They could come back as a switch, off.
13. **A cold launch reopens the reader only if the reader was on screen when the app left.**
    - Recommended: as built.
14. **Where the book's text sits:** Book content just before Play, as on the Mac.
    - Recommended: as built.
15. **The search field at the top,** where iOS 26 would put it at the bottom.
    - Recommended: as built.
