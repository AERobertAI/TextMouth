# The audit and its accepted findings
<!-- id: audit-accepted-findings; keys: XCUIAccessibilityAuditTypes, accessibility QA, iPhone, VoiceOver; src: TextMouthiOSUITests/TextMouthUITestCase.swift -->

Part of [TextMouth's documentation](../../README.md).

- Each UI test that audits runs Apple's accessibility audit on the screen showing, `performAccessibilityAudit`, and fails once with every finding that is not accepted.
  Each finding is listed with its type, its element, and Apple's words, so one run shows them all.
  A screenshot of the audited screen is kept with the results.

## How the audit runs
<!-- id: how-audit-runs; keys: audit kind, audit loop, SDK kinds, findings, audit types; src: TextMouthiOSUITests/TextMouthUITestCase.swift -->

- **Each kind runs alone.**
  `audit` makes one `performAccessibilityAudit` call for each of the seven kinds, from one table, `auditKinds` in `TextMouthUITestCase` (the kind and its name), which `name(of:)` reads as well.
  The seven are the iOS 26.0 SDK's: contrast, element detection, hit region, element description, Dynamic Type, clipped text, and trait.
  - Why: audited together, a finding named no element ("no element"), so it could be neither matched to an accepted one nor found on the screen.
    Audited alone, it names its element.
    Go To's "Potentially inaccessible text" appeared in both runs that audited every kind together, and in none of five launches that audited that kind alone.
    Its cause is unknown.
    That it is a product of the combined run rests on two combined runs against five single ones.
  - The loop runs the kinds in the table, not `.all`.
    A kind that a later SDK adds is skipped until it gets a row there, and the table's comment says so.
  - A finding's element is read from one snapshot, taken only if the element still exists, and the same snapshot serves the match and the trace (type, label, value, identifier, frame, whether it is enabled, and its children).
- On iOS the audit only inspects.
  The audit of an element's actions exists on macOS alone (`XCUIAccessibilityAuditTypes.h`).

## The accepted findings
<!-- id: accepted-findings; keys: Accepted struct, allow list, waived finding, color contrast; src: TextMouthiOSUITests/TextMouthUITestCase.swift, TextMouthiOSUITests/LargeTextUITests.swift, TextMouthiOSUITests/SearchUITests.swift, TextMouthiOSTests/PhoneWholeWordsTests.swift -->

- A finding is accepted only when the app cannot change it, or when it is proven false.
  An `Accepted` value matches the audit's type and the element's label (exactly, or by its start when `labelIsPrefix`), and, for some, Apple's own short description of the finding.
  It is kept with the results, with its reason.
  There are nine, in five groups, and a tenth for the phone's SwiftUI text fields (see the next section).
  The Search in Book audit declares one more of its own, in the test (see SearchUITests, below).
  - **Parts iOS draws:**
    - `searchField`: the clipped-text finding on "Search books", because the system's search field clips its placeholder at the largest text sizes, and VoiceOver and braille read it whole.
    - `barItem(label)`: the Dynamic Type finding on a button in a bar, because iOS draws the button and does not grow bar items with Dynamic Type.
      It shows them in the Large Content Viewer instead.
      Two bars count: the bar at the bottom of the Library ("Settings", "Add to Library"), and the top bar of a sheet (Cancel, Close, Done, Save, and Back to Book).
      Each sheet's test names its own buttons.
    - `navigationTitle(title)`: the clipped-text finding on a screen's title, because iOS truncates a long title at large sizes, and VoiceOver and braille read it whole.
      It is accepted for the reader (the book's title) and the sheets: Add to Library, Settings, Bookmarks, Headings, Go To, Sleep Timer, "Voice & Speed for This Book", Book Information, and "Navigation unit".
  - **A false positive, proven:** `firstHeader(title)` is the contrast finding on the first section header under a bar, "Voice" on Settings and "New Timer" on Sleep Timer.
    The screenshots kept with the results showed black text, (0, 0, 0), on (235 to 242, 235 to 242, 240 to 247), in a frame 370 by 40 points at (16, 116) or (16, 132): about 17 to 1.
    Nothing switched off cleared it.
    It is matched by the header's words and the contrast kind only, so any other contrast finding still fails.
  - **A false positive, measured:** `brailleCaption` is the clipped-text finding on the Braille section's caption in Settings, matched by its exact words and the kind only.
    `PhoneWholeWordsTests` measures its frame a point taller than its words at the largest size, and the screenshot kept with train 1125-0148's audit shows all seven of its lines whole.
  - **Large text, by element:** `librarySummary` is the Dynamic Type finding ("partially unsupported") on the Library's summary row, matched by the first words of its label, "1 book."
    The row is a plain `Text` that grows and wraps (5 lines at the largest size in the screenshots).
    Its cause is unknown.
  - **Large text, with no element**, used only on the audits of `LargeTextUITests`, and matched by an empty label, the kind, and Apple's exact words:
    - `unnamedUnsupported`: "Dynamic Type font sizes are unsupported".
      Probably the system stepper's minus and plus, which iOS does not grow, but this is unproven.
      It is accepted on Settings at the largest size, as it first appears, as well as scrolled, and on the Library scrolled.
    - `unnamedPartlyUnsupported`: "Dynamic Type font sizes are partially unsupported", seen once on the Library scrolled.
      It is accepted on the two scrolled audits.
    - `scrolledPastTheEdge`: the clipped-text kind and Apple's words "Text clipped", for text cut by the screen's edge or the bar it scrolls under, which is what scrolling does.
      The screenshot of pass 4 showed a line cut under the navigation bar and a row cut at the bottom edge.
      It is used only by the two scrolled audits.
    - The scrolled Settings audit also passes `acceptingTextCutByTheScroll` to `audit`, which accepts a clipped-text finding on any named row whose frame crosses the bottom of the navigation bar or the bottom edge of the screen, and keeps it with the results.
      The audit cannot tell a cut by the edge from a cut of the text; the same screen audited unscrolled holds every row whole.
    - These three are broader than the others and not verified one by one.
      A real fixed font would still name its element and fail.
- Any other finding fails its test.
  To accept a new kind, add an `Accepted` value with its reason to `TextMouthUITestCase`, and add its reason here.

## The text fields' accepted finding
<!-- id: text-field-accepted-finding; keys: swiftUITextField, partially unsupported, adjustsFontForContentSizeCategory, A11Y-GOTO, canary, fixed font; src: TextMouthiOSUITests/TextMouthUITestCase.swift, TextMouthiOSUITests/ScreenOrderUITests.swift, TextMouthiOSTests/PhoneTextFieldScalingTests.swift, TextMouthProductionTests/PhoneFontPolicyTests.swift -->

- `Accepted.swiftUITextField(label)` is the Dynamic Type finding "partially unsupported" on a phone `TextField`.
  It is used for Go To's Page, Percent, and Time, Sleep Timer's custom minutes, Book Information's four fields, and Search's field.
- **Why it is accepted.**
  The text grows, and the audit reads a flag SwiftUI does not set.
  - `PhoneTextFieldScalingTests` hosts each of those sheets and checks that every input's font has a text style and is at least twice as big at the largest size.
  - The audit reads UIKit's `adjustsFontForContentSizeCategory`.
    SwiftUI leaves it off on the UITextField (or, for a field that grows to several lines, the UITextView) it draws.
    A GitHub run logged it off, in the body text style, for a bare field, one with `selection:`, a number-pad field, and a vertical one.
  - An Apple DTS engineer says SwiftUI "does not always pass along that specific UIKit-level flag", and that with system fonts "you are doing everything right" (developer.apple.com/forums/thread/828525).
- **What still fails.**
  The value matches the kind, the exact label (a start, for Time and for Book Information's hand-edited labels), and the words "partially unsupported".
  A fixed font, which the audit words "unsupported", fails the audit, and `PhoneFontPolicyTests` refuses `.system(size:` and `.custom(_:fixedSize:` in the phone's source.
- **When to remove it.**
  `PhoneTextFieldScalingTests.testSwiftUIStillLeavesTheDynamicTypeSwitchOff` fails once SwiftUI turns the switch on.
  Then delete the `Accepted` values, their uses in `ScreenOrderUITests` and `SearchUITests`, and the canary.
- The finding came and went from one launch to the next (A11Y-GOTO), so `testTheGoToSheetHasTheSpecsOrder` launches and audits Go To once, and the old test that audited it on five launches in a row is gone.

## Audits that report without failing
<!-- id: audits-that-report-without-failing; keys: soft audit, report only, XCTAttachment, warning; src: TextMouthiOSUITests/TextMouthUITestCase.swift, TextMouthiOSUITests/LibraryUITests.swift, TextMouthiOSUITests/ScreenOrderUITests.swift, TextMouthiOSUITests/SearchUITests.swift, TextMouthiOSUITests/LargeTextUITests.swift -->

- `audit(_:screen:types:informing:accepting:)` takes `informing`, a kind of finding that is kept with the results and does not fail the test.
  The note is an attachment named "SCREEN: findings reported, not failed".
- It is for a kind that another test checks, or whose cause is not known.
  Five audits use it, all for Dynamic Type at the normal text size:
  - the Library with a book (`testTheLibraryWithABookPassesTheAudit`), for its summary row;
  - Settings (`testSettingsPassesTheAudit`), for the lower rows: a slider's value and caption, and the switch;
  - Sleep Timer, for its stepper's label, a system control's;
  - Book Information, for the read-only rows at the bottom;
  - the Search in Book sheet with results (`testTheSearchSheetPassesTheAudit`), for the status line, the "Search results" heading, the regular-expression switch, and the field; `LargeTextUITests` measures that these grow (see SearchUITests, below).
- `LargeTextUITests` does not use it: it fails on what it finds, except the accepted findings above.
- A test that reports is not proof that the screen passes.
  `LargeTextUITests` audits the same screens at the largest size.
- Every other kind of finding on those screens still fails.

## LargeTextUITests
<!-- id: largetextuitests; keys: accessibility size, AX5, Dynamic Type growth, retry tap; src: TextMouthiOSUITests/LargeTextUITests.swift, TextMouthiOSUITests/TextMouthUITestCase.swift, TextMouthiOSUITests/ScreenOrderUITests.swift, TextMouthiOSUITests/SearchUITests.swift, TextMouth/Platform/iOS/Views/PhoneTextStyle.swift -->

- It audits for Dynamic Type and clipped text only (`sizeFindings`), at the largest size iOS offers, Accessibility Extra Extra Extra Large.
  A bigger size does not exist.
- The size is set at launch with `-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL` (`TextMouthUITestCase.largestText`), as the Larger Text setting would.
  Nothing changes the simulator's own settings.
- **Dynamic Type and clipped text fail** (0.4.3).
  Only the accepted findings above pass, and any other Dynamic Type finding, such as a fixed font on either screen, fails.
- Its four tests:
  - `testTheLibraryWithABookHoldsAtTheLargestText` audits the Library with a book, as it first appears and then scrolled once, since the summary row is below the first screen at this size.
    It accepts the system parts and `librarySummary`, and, scrolled, the three nameless findings.
  - `testSettingsHoldsAtTheLargestText` audits Settings as it first appears and then scrolled two screens down.
    A list lays its rows out lazily and a swipe's momentum carries on after the swipe returns, so the audit must not read it mid-scroll.
    The test first scrolls the whole list through once (`scrollThroughTheList`), so every row has been laid out, and before each audit waits for a still screen (`waitUntilStill`): the frames of every labeled element are the same on two reads half a second apart, for at most `patience`.
    It accepts the title, `brailleCaption`, and `unnamedUnsupported`, and, scrolled, the other two nameless findings.
    Switch labels and captions take `phoneWholeWords`, a point of line spacing that leaves each frame taller than its words, since a frame that fit its words exactly was read as clipped in some runs.
    `PhoneValueRow` stacks the value under the name at these sizes, and the screenshots show nothing cut or overlapped.
  - `testAddToLibraryHoldsAtTheLargestText` audits the Add to Library sheet.
    It accepts its title and Cancel, and nothing else.
  - `testTheSearchSheetHoldsAtTheLargestText` types a search into the Search in Book sheet (so it runs only where sound is allowed) at the default size and then at the largest, in two launches of the same test, and measures the height in points of the four parts the sheet's audit named:
    - the field,
    - the status line,
    - the switch, and
    - the "Search results" heading.

    Each must have grown by at least its own bound (`minimumGrowth`: the field 2.4, the status line 1.55, the switch 2.5, the heading 1.75, as height at the largest size over height at the default).
    Each bound lies about halfway between what the sheet measures with every part capped at Accessibility 2 and what it measures as it is (run 43374972739 on a proof branch that capped it, never merged, and run 43066870675).
    So a cap at Accessibility 2 or any smaller size fails, naming every part that fell short, and the sheet as it is passes.
    Text in a fixed font would not grow at all.
    Every run prints each part's heights and ratio on `SEARCH-GROWTH` lines of `ios-ui.log`.
    The sheet's elements come from `openSearchSheet`, `waitForStatus` and `waitForResults`, which moved from `SearchUITests` to `TextMouthUITestCase` for it.
    It then audits clipped text only at the largest size (Dynamic Type is the measurement's), accepting the title, Back to Book and `scrolledPastTheEdge`.
    It passed in run 43041108180 (the sheet's text grows), in 58 seconds.
- **The sheet taps retry.**
  At the largest size the first tap after a launch was seen to do nothing (a Back, an Add to Library, and, in pass 5, the Bookmarks control).
  `tap(_:until:in:what:)` taps up to three times, 5 seconds apart, until the screen it wants shows.
  At the top of each round it returns if that screen is already there, so a screen that was slow to come is not tapped past.
  `LargeTextUITests` and `openReaderSheet` of `ScreenOrderUITests` use it; a switch never does, since a retried tap would turn it off again (`ExportUITests` holds each one a quarter of a second instead).
- Nothing is pressed but a book's Back, Settings, Add to Library, and Search in Book, and nothing is typed but the one search of the Search test.

## PlaybackUITests
<!-- id: playbackuitests; keys: transport controls, skip sentence, end of heading timer, regression proof, mutation; src: TextMouthiOSUITests/PlaybackUITests.swift, TextMouthiOSUITests/TextMouthUITestCase.swift, TextMouthiOSTests/PhoneControlButtonTests.swift, TextMouthProductionTests/PhoneReaderControlsTests.swift, TextMouth/Phone/PhoneSleepTimerModel.swift, TextMouth/ViewModels/ReaderViewModel+Playback.swift -->

- They press Play, Pause, the skip buttons, and the Sleep Timer's buttons in the reader, on Alice's Adventures in Wonderland (an EPUB, so nothing is played through Apple's players but the app's own speech), and read what VoiceOver would be given.
  Each starts with `requireSound`, so each skips on this Mac, saying why.
  XCUITest reads a control's label, value, and type (button), and whether it is enabled; it does not read the hint or the other traits (adjustable, starts a media session), which `PhoneControlButtonTests` and the Mac's `PhoneReaderControlsTests` hold.
- The six tests:
  - `testPlayBecomesPauseAndPauseBecomesPlay`: before, "Play", a button, enabled, with no value; after Play, "Pause" with no value, still there three seconds later (a failed speech would put an alert up or turn it back into Play); after Pause, "Play" with no value, since nothing was moved.
    Then Play, three skips forward while playing, and Pause leave Book content past where it began.
    A second Play and Pause leave it at that place or later in the same passage (found inside the first, with white space made alike), never at the book's opening, so a Play that started the book over fails.
  - `testSkippingForwardWhilePlayingMovesTheBookAndKeepsItPlaying`: the sentences are learned first, silently: paused, each of six Skip forward presses puts the sentence at its new place in Play's value, and six presses back return Book content to the opening.
    Then, playing, six presses forward leave Pause on screen, and after Pause Book content begins at the sixth sentence or later (the first 80 characters tell sentences apart), never at the opening or the first five.
    The new place is not searched for in the opening passage: that is a short title page, and the place is in a later chapter.
  - `testSkippingBackwardAtTheStartSaysSoAndLeavesTheBookPlaying`: paused at the opening, Skip backward puts words in Play's value ("previous", "start" or "beginning" in them; the spec's are "No previous sentence.") and leaves Book content alone.
    With the book playing, the same press leaves Pause on screen.
  - `testASleepTimerCountsDownWhileTheBookPlaysAndStopsWhenItPauses`: the 10-minute preset starts the book (Pause), the Sleep Timer reads "M:SS remaining" between 9:00 and 10:00, a later reading is smaller while it plays, and two readings four seconds apart are equal once it is paused.
  - `testAnEndOfBookTimerNamesItsStopAndCancelEndsIt`: "Stop at the end of the book" starts the book and the control reads "stops at the end of the book".
    The sheet then lists Sleep Timer (its title), Reset Timer, Cancel Timer and New Timer, and after Cancel Timer the control has left the reader (FR51).
    The sheet's "Current Timer" heading and its status line are not in the tree once a timer is set, though Reset Timer after them is; a list scrolled to the last timer used would explain the heading but not that, so whether VoiceOver misses them is not settled and needs a device.
  - `testAnEndOfHeadingTimerSetAtTheCoverPlaysOnAndNamesItsStop`: at the book's opening, "Stop at the end of this heading" starts the book (Pause), the Sleep Timer shows, reading "stops at the end of this heading", and Pause is still there three seconds later (`assertHolds`).
    It passed in run 43041108180 with the fix, in 23 seconds, and fails without it (see the proof, below).
- **End of heading at the cover.**
  A timer set to the end of the heading takes the heading Play starts in (`retargetSleepTimerHeading(toPlayStartingAt:)`, since 0.4.6), not the first heading after the cursor, since Play skips a silent cover chapter to the first chapter with words.
  The Mac's reader shares the code.
- **Proof that the test finds the fault.**
  A branch with the merge's changes under `TextMouth/ViewModels/` taken out (never merged, sent to `TestBuild` once by hand) was run with this class on GitHub (run 43048443160).
  `testAnEndOfHeadingTimerSetAtTheCoverPlaysOnAndNamesItsStop` failed with the symptom of run 42948545901, "The book did not start playing ... The control reads \"Play\", and the Sleep Timer reads \"Off\"", and the class's other five tests passed.

## SearchUITests
<!-- id: searchuitests; keys: find in book, search sheet, software keyboard, PhoneBookSearchVocabulary; src: TextMouthiOSUITests/SearchUITests.swift, TextMouthiOSUITests/TextMouthUITestCase.swift, TextMouth/Platform/iOS/Views/Reader/PhoneSearchSheet.swift, TextMouth/Phone/PhoneBookSearch.swift -->

- They drive the Search in Book sheet (0.4.4) in the simulator.
  The searches are typed into the field, as a person types them, so every test but the empty sheet's runs only where sound is allowed (on GitHub's runner; see [In the simulator, sound tests run on GitHub only](testing-iphone.md#in-the-simulator-sound-tests-run-on-github-only)).
  The word searched for is "Cheshire" in Alice's Adventures in Wonderland, which the book holds in several chapters, far below the 500-result limit.
  A result's jump is silent, since Auto-play after navigation is off in the launch's sandbox.
- The sheet's search waits a second for typing to pause, so each test first waits for the status line to end in " matches", " match", or "No matches", for up to the usual patience.
- The seven tests (the first, third, fourth, fifth, sixth, and seventh type):
  - `testTheSearchSheetReadsItsFieldStatusSwitchAndResultsInOrder`: the title, Back to Book, the field, the status line between the field and the switch, the switch, the "Search results" heading, then the results.
    The first result is a button that holds the word and ends with " percent of book".
  - `testWithNothingSearchedTheSheetSaysSo`: with no search the status is "Enter a search term above." and there is no results heading.
  - `testAWordNotInTheBookGivesNoMatches`: "No matches", and no results heading.
  - `testACorrectionMadeWhileTypingIsSearchedFor`: the word with a stray "x" typed after it gives "No matches"; one delete key later the results come and the field holds just the word.
  - `testEmptyingTheFieldReturnsTheSheetToItsPrompt`: after a search with results, deleting every typed character brings back "Enter a search term above." and takes the results' heading away.
  - `testAResultTakesTheReaderToItsPlace`: choosing the first result closes the sheet, puts Search in Book back on the reader, leaves Play unpressed, and within the patience puts the word into Book content's text.
  - `testTheSearchSheetPassesTheAudit`: the audit of the sheet with results.
- The audit's keyboard.
  The field takes the keyboard, which the audit reads too: with it up, the audit finds contrast findings on result rows under the keyboard and "TUIPredictionViewCell" element-description findings of the system keyboard's own.
  A swipe of the whole app does not put the keyboard away.
  So the test drags from the "Search results" heading to the navigation bar, a scroll of the list, which is silent and puts the keyboard away (`scrollDismissesKeyboard`).
  If the keyboard stays up, the audit runs all the same and a note says so.

### Dynamic Type, the accepted finding, and the passes
<!-- id: dynamic-type-accepted-finding-passes; keys: search sheet audit, pass history, CI runs, on-screen keyboard; src: TextMouthiOSUITests/SearchUITests.swift, TextMouthiOSUITests/LargeTextUITests.swift, TextMouthiOSUITests/TextMouthUITestCase.swift, TextMouthiOSUITests/LibraryUITests.swift, TextMouth/Platform/iOS/Views/Reader/PhoneSearchSheet.swift -->

- **Dynamic Type is reported, not failed.**
  The sheet's text does grow.
  Its code draws all of it in the system's styles with no fixed size (`Text`, `TextField`, `Toggle`, a section header), and `LargeTextUITests.testTheSearchSheetHoldsAtTheLargestText` measures each of the four parts at the largest size against the default and passed (run 43041108180).
  So the findings are the audit's own, which come and go, like the Library's summary row and the other sheets' (see Audits that report without failing, above), and the audit reports Dynamic Type without failing it.
  Clipped text and every other kind still fail.
  The audit's helpers (`openSearchSheet`, `waitForStatus`, `waitForResults`) live in `TextMouthUITestCase`.
- Accepted: the system's title, Back to Book, the clipped text of a scroll, and one contrast finding that stays, on "CHAPTER VI.
  Pig and Pepper", the first result's heading at y 71 scrolled under the navigation bar's glass.
  It is matched by that exact label and the contrast kind, and every other contrast finding fails.
  Whether it is a false positive is unproven: the phone draws every result in the primary label color.
  A real contrast failure on an element with exactly that label would pass.
- The audit passed once on the iPhone 17, in a run that passed all 26 tests; whether it is stable across launches is untested.
- Not verified: anything that needs VoiceOver or sound, the Return place after a jump, and the sheet's focus into its field.

## Book Information's test expects "Author"
<!-- id: book-information-test-expects-author; keys: field label, PhoneLibraryVocabulary, authorFieldLabel; src: TextMouthiOSUITests/ScreenOrderUITests.swift, TextMouth/Phone/PhoneLibraryVocabulary.swift, TextMouth/Platform/iOS/Views/Library/PhoneBookInfoSheet.swift -->

- `testTheBookInformationSheetHasTheSpecsOrder` expects the order "Book Information", "Cancel", "Save", "Book title", "Author", "Publisher", "Publication date", "Format", "Added", "Last Opened", "Word Count".
- The book is an EPUB.
  Its form uses the Mac's metadata editor's words, so its author field is "Author".
  A book with no more than a title and author has "Book author".

## What is still open
<!-- id: what-still-open; keys: known issues, unverified, audit flakiness, Dynamic Type caption; src: TextMouth/Platform/iOS/Views/PhoneTextStyle.swift, TextMouthiOSTests/PhoneValueRowTests.swift, TextMouth/Platform/iOS/Views/Settings/PhoneSettingsView.swift, TextMouthiOSUITests/TextMouthUITestCase.swift -->

These are findings with no known cause, and things not verified.
The last passes fail on none of them.

- **Dynamic Type at the normal size** on Settings, Sleep Timer, Book Information, and the Library's summary is reported and not failed (see Audits that report without failing, above).
  Plain text nodes are named:
  - Settings: "Auto-play after navigation", its caption, and the pitch caption;
  - Sleep Timer: "Adjust minutes";
  - Book Information: "Last Opened", "Word Count", and their values.
  - The cause is not found.
    Identical rows differ: the speed caption is never flagged, and the pitch caption only sometimes.
    A result repeats within a launch (3 of 3) and differs between launches.
    It is probably iOS's, which is not proven.
  - The only pattern seen earlier: the captions on Settings are hidden from VoiceOver with `accessibilityHidden`, and the Library's summary is not.
- **At the largest size**, what the audit does not name (the two Dynamic Type wordings, "Text clipped") is accepted by wording.
  What the Settings "unsupported" finding is has not been proven.
- **Go To's "Potentially inaccessible text"** does not appear when each kind is audited alone.
  Its cause is unknown.
- **Not verified:**
  - the disabled controls' text contrast (`PhoneTextColor.disabled` keeps the system gray);
  - `PhoneValueRowTests` against a row that is not stacked;
  - the Return key in Book Information's multi-line fields (a Return is dropped, so the value stays on one line);
  - anything that needs VoiceOver.
- **Contrast:** Apple's audit says iOS's secondary gray only nearly passes contrast, so the phone draws all its text at full contrast (see PhoneTextStyle in [The two apps and the platform folders](../architecture/platforms-phone-interface.md)).
  That follows the recommended answer to question 2 of section 6 in `humanQuestions/2026-11-08.md`, which the user has not answered.
  Undoing it is one line.
