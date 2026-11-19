# Settings: the Library tab
<!-- id: settings-library-tab; keys: custom views, smart folders, saved filters, View pop-up, libraryViews; src: TextMouth/Views/Settings/LibraryViewsSettingsView.swift, TextMouth/Models/LibraryViewsSettingsWording.swift -->

Part of [TextMouth's documentation](../../README.md).

## Library tab: views
<!-- id: library-tab-views; keys: libraryViews, View pop-up, 860 points, Reading List, Feeds view, Folders view; src: TextMouth/Views/Settings/LibraryViewsSettingsView.swift, TextMouth/Models/LibraryViewsSettingsWording.swift, TextMouth/Models/LibraryViewDefinition.swift -->

The Library tab, between Stats and Feeds, arranges the views the Library window's View pop-up offers (see [The Library window](library-window.md)).
Its toolbar symbol is a row of books, and the window is 860 points wide, so its eleven tabs fit.
Like the Text tab, it does not scroll as a whole: its list fills the room the other controls leave.

### The list of views
<!-- id: list-views; keys: built in, custom, Show Always, Show When Applicable, Hide, Move Up, Move Down, VO-Command-Space; src: TextMouth/Models/LibraryViewsSettingsWording.swift, TextMouth/Views/Settings/LibraryViewsSettingsView.swift, TextMouth/ViewModels/LibraryViewsSettingsActions.swift -->

- The heading "Views" is followed by two captions.
  The first reads "The View pop-up of a Library window offers these views in this order.
  A new window opens at the first one offered."
  The second reads "Always offers a view all the time.
  When Applicable offers it only while it lists something: the Reading List while it holds a book, episode, or article, and Feeds while there is a feed.
  Hidden leaves it out.
  A window keeps its view until you choose another."
- The list, which VoiceOver calls "Views", has one row for each view, in order, and each row is one element that VoiceOver reads as its name, "built in" or "custom", its visibility, and its place, as in "Reading List, built in, always, 5 of 6".
  A row's hint says what the view lists: for Folders, "Shows one folder at a time".
  For the Reading List, "Shows the books in the order you arrange".
  And for any other view its conditions, as in "Lists books and feeds: reading state is Unopened and has new episodes or articles." or "Lists books, episodes, and articles: reading state is not Unopened; only the latest from each feed; at most 10, opened last."
  The first view is selected when the tab opens, and the arrow keys move the selection.
  Return, or a double-click, is Edit… for a view that can be edited, which is any view but Folders and the Reading List.
- A row's VoiceOver actions (VO-Command-Space) and its context menu offer the same commands, each only where it applies: Edit…, Move Up, Move Down, Show Always, Show When Applicable, Hide, Duplicate, Delete…, and Restore Default….
  The Show commands are the visibilities the view does not have, and Folders has none.
  After Show Always, Show When Applicable, or Hide from a row, VoiceOver says, as in "Feeds, shown always", "Feeds, shown when applicable", or "Feeds, hidden".

### Controls for the selected view
<!-- id: controls-selected-view; keys: Visibility, New View, Edit, Duplicate, Delete, Restore Default, 200 views, Copy 2; src: TextMouth/Models/LibraryViewsSettingsWording.swift, TextMouth/ViewModels/LibraryViewsSettingsActions.swift, TextMouth/Views/Settings/LibraryViewsSettingsView.swift, TextMouth/Models/LibraryViewDefinitionList.swift -->

- Under the list are the controls for the selected view.
  Each is dimmed while it does not apply, and its hint then says why.
  - "Visibility" is a pop-up button with the items "Always", "When Applicable", and "Hidden"; VoiceOver calls it "Visibility of Reading List", with the hint "Sets when the View pop-up offers this view".
    For Folders it is dimmed, with the hint "Folders is always shown: every folder and feed opens there."
    Folders is always offered, so the pop-up is never empty, and a feed's row, which opens its folder, always has Folders to open it in.
  - "Move Up" and "Move Down" move the view one place, and VoiceOver calls them "Move Reading List Up" and "Move Reading List Down", with the hints "Moves the view one place up the list" and "Moves the view one place down the list".
    Each says the view's new place, as in "Reading List, 4 of 6".
    Move Up is dimmed for the first view, with the hint "The view is first in the list.", and Move Down for the last, with "The view is last in the list."
  - "New View…" opens the view editor (below) for a view of your own, added at the end of the list and offered Always.
    Its hint is "Makes a view of your own from the conditions you choose."
    The list holds at most 200 views; at 200 the button is dimmed, with the hint "The Library holds at most 200 views."
  - "Edit…" opens the editor on the selected view; its hint is "Changes the view's name, what it lists, its conditions, its sort, and its limit."
    For Folders and the Reading List, whose contents and names do not change, it is dimmed, with the hint "Folders and the Reading List list what they always have.
    You can move them, and hide the Reading List."
  - "Duplicate" makes a view of your own from a filter view, named for the view with " Copy" after it, then " Copy 2", right after it in the list, offered Always, with the same conditions and the sort shown.
    Its hint is "Makes your own view with these conditions and sort."
    VoiceOver then says, as in "Made Unopened Copy, 4 of 7."
    It is dimmed for Folders and the Reading List, with the hint "Folders and the Reading List have no conditions to copy.", and at 200 views, with "The Library holds at most 200 views."
  - "Delete…" deletes a view of your own, after asking.
    Its hint is "Deletes the view.
    What it lists stays in the library."
    For a built-in view, which can be hidden and never deleted, it is dimmed, with the hint "A built-in view can be hidden, not deleted."
    The question is titled "Delete the view “Unread EPUBs”?", with the message "Its conditions and sort are deleted.
    The books, episodes, articles, and feeds it lists stay in the library, and a Library window showing it shows another view." and the buttons "Delete" and "Cancel".
    Once it is deleted, focus returns to the list, and VoiceOver says which view is selected now, as in "Deleted Unread EPUBs.
    Feeds selected, 6 of 6."
  - "Restore Default…" gives a built-in filter view, All Items, Unopened, Recently Opened, or Feeds, back the name, conditions, sort, and limit TextMouth gave it, after asking.
    Its hint is "Gives the view back the name, conditions, sort, and limit TextMouth gave it."
    It is available while the view's name, conditions, or the sort it shows differ from TextMouth's own; otherwise it is dimmed, with the hint "This view is as TextMouth made it.", or, for a view of your own, "A view you made has no default to restore."
    The question is titled "Restore “Unopened” to its default?", with the message "Its name, conditions, sort, and limit go back to TextMouth's own.
    Its place in the list and when it is offered stay as they are." and the buttons "Restore Default" and "Cancel"; afterwards VoiceOver says "Restored Unopened."
    When another view already has the name TextMouth gave this one, it asks nothing and says "Another view is named Feeds.
    Rename it first, then restore this view."

### Newer views and where the list is kept
<!-- id: newer-views-where-list-kept; keys: libraryViews, needs a newer TextMouth, unreadable views, library.json, view sort; src: TextMouth/Models/LibraryViewDefinitionStore.swift, TextMouth/Models/LibraryViewsSettingsWording.swift, TextMouth/Services/ConfigService.swift -->

- When config.json holds views a later TextMouth wrote, which this TextMouth keeps as they are and never offers, a caption under the controls says so: "1 view needs a newer TextMouth.
  It is kept as it is, and not offered." or, for more, "2 views need a newer TextMouth.
  They are kept as they are, and not offered."
- Where the choices are kept: config.json holds the list as libraryViews (see [Editing settings in config.json](config-json.md)); each view's sort stays with the library's sorts, in library.json.

### Titles: leading articles
<!-- id: titles-leading-articles; keys: leadingArticles, partOfTitle, ignoredWhenTyping, ignoredWhenTypingAndSorting, The Hobbit, sort title; src: TextMouth/Models/LeadingArticleWording.swift, TextMouth/Models/LeadingArticles.swift, TextMouth/Views/Settings/LeadingArticlesSettingsSection.swift -->

- The Titles section, at the bottom of the tab under the controls for the selected view, decides what a title's leading article does in the Library window's lists.
  Its heading, "Titles", is a heading to VoiceOver, and it holds one pop-up button, "Leading articles", with the hint "Chooses whether The, A, and An at the start of a title count when sorting and when typing a title's first letters."
  (the pointer shows the same words as its tooltip).
  A sentence under the pop-up says what the choice in force does, as text, so you hear it with hints turned off, and a braille display shows it.
  The pop-up has three choices, and none of them changes a title: Book Information, a reader window, Now Playing, Speak Info, and Export keep each title as written, and so do the files.
  - "Part of the Title" is the default, and changes nothing.
    Its sentence reads "Titles sort, and are found by typing, as they are written: The Hobbit is among the T's."
  - "Ignored When Typing" reads "The Hobbit counts as an H when you type.
    The list keeps its order and shows each title as it is written."
    Typing the first letters of a title goes past its leading article ("h" goes to "The Hobbit"), and "the h" goes to it too, but the lists sort and show titles as before.
  - "Ignored When Typing and Sorting" reads "The Hobbit sorts among the H's and shows as Hobbit, The.
    Typing H finds it among the H's."
    Every Library list sorts by the title from where it files, its leading article left out, and shows each row's title with the article after it, as an encyclopedia's index does.
    A row's VoiceOver label, the Books rotor, and a search read the shown title (see [The Library window](library-typing-and-speak-info.md)).
  - Under the second and third choices the sentence goes on with a note about languages.
    It reads "When articles are ignored, a book whose metadata names French, German, Spanish, Italian, Portuguese, Dutch, Catalan, Swedish, Danish, or Norwegian passes over that language's articles, such as Le and Die, and The.
    Any other book passes over The, A, and An.
    Folder names stay as you typed them."
    So a book whose language is one of those ten, named by a code such as "fr", "fr-CA", "pt_BR", or "fre", or by a name such as "French" or "Deutsch", passes over that language's articles and English's The, but not A or An, which are not articles in those languages.
    "Die Verwandlung" files under V in a German book, and "The Hobbit" still files under H in a French one.
    A book with no language, an English one, or one in a language not listed passes over The, A, and An.
    A feed names no language, so a feed's title and the titles of its items not yet downloaded are read with English's articles.
    An article that is elided joins the next word, as in "L'Étranger", which files under É.
    A quotation mark or a bracket before the article is passed over with it, and a title is shown with its article inside them: “The Raven” and Other Poems shows as “Raven, The” and Other Poems.
    A title that is only its article, or that has no more than punctuation after it, is not read as having one.
    A before is, was, to, for, and, or, through, thru, versus, vs, &, +, or a single letter is the letter A, not an article, so "A Is for Alibi" and "A to Z" file under A. Folder names, which you typed yourself, are never read for articles.
  - The iPhone lists titles as written, whatever the setting holds.
  - Where the choice is kept: config.json holds it as leadingArticles, "partOfTitle", "ignoredWhenTyping", or "ignoredWhenTypingAndSorting" (see [Editing settings in config.json](config-json.md)).
    A change is saved at once, and every open Library window sorts, shows, and finds titles by it from then on.
### The view editor
<!-- id: view-editor; keys: New View sheet, Edit sheet, Name, Lists, Match, All Conditions, Any Condition; src: TextMouth/Models/LibraryViewEditorWording.swift, TextMouth/Views/Settings/LibraryViewEditorSheet.swift, TextMouth/ViewModels/LibraryViewEditorModel.swift -->

The view editor is a sheet over Settings, 620 points wide and 520 high, that scrolls inside.
Its heading is "New View", or "Edit" and the view's name, as in "Edit Unopened".
From the top, it has these controls, and Escape presses Cancel and Return presses Save.

- "Name" is a text field.
  The name is 1 to 60 characters and differs from every other view's name, ignoring case.

- "Lists" is four checkboxes, "Books", "Episodes", "Articles", and "Feeds", with the caption "Conditions about books test books, episodes, and articles; conditions about feeds test feeds.
  A condition never hides a row it does not test."
  Episodes and articles are the feed items you have downloaded, episodes the ones whose format is audio.
  A new view lists books.

- "Match" is a pop-up button with "All Conditions" and "Any Condition": a row is listed when all of the conditions that test it hold, or when at least one does.
  A row that no condition tests is listed.

### The view editor: conditions
<!-- id: view-editor-conditions; keys: condition tests, Reading State, Date Added, Date Opened, Title or Author, Format, Subscription, New Items; src: TextMouth/Models/LibraryViewEditorWording.swift, TextMouth/Models/LibraryViewFilterEvaluator.swift, TextMouth/Models/LibraryViewDefinition.swift -->

- "Conditions" is a heading above one row for each condition, or, with none, the sentence "No conditions: the view lists every item of the kinds chosen."
  A condition's row has a test pop-up, which VoiceOver calls "Condition 2"; a relation pop-up, "Condition 2 relation"; "Remove", which VoiceOver calls "Remove condition 2"; and the control the test needs.
  A pop-up is read value first, as in "Reading State, Condition 2, pop-up button".
  "Add Condition" adds "Format is EPUB" at the end, up to 20; at 20 it is dimmed, with the hint "A view holds at most 20 conditions."

- The tests, with the relations each offers and the control it needs, are these.
  "Format": "Is" or "Is Not", and a pop-up of the formats, "Condition 2 format".
  "Folder": "Is" or "Is Not", a pop-up, "Condition 2 folder", of "Library Root", the top of the library, and the folders by path, and a checkbox "Including Subfolders", "Condition 2 includes subfolders".
  A folder removed from the library is shown as "a folder no longer in the library" and matches nothing.
  "Reading State": "Is" or "Is Not", and a pop-up, "Condition 2 reading state", of "Unopened", "In Progress", and "Finished".
  "Reading List": "In the Reading List" or "Not in the Reading List".
  "Date Added" and "Date Opened": "Within the Last" or "Not Within the Last", and a number of days, 1 to 3,650, in a field, "Condition 2 days", followed by the word "days"; one day means today, and a row never opened is not within any days of being opened.
  "Title or Author": "Contains" or "Does Not Contain", and a text of up to 200 characters, "Condition 2 text", compared ignoring case, as the window's search does.
  "New Items", for feeds: "Has New Episodes or Articles" or "Has None New".
  "Subscription", for feeds: "Subscribed" or "Unsubscribed".
  Format, Reading State, Reading List, Date Added, and Date Opened test books, episodes, and articles only; New Items and Subscription test feeds only; Folder, by the folder a feed lives in, and Title or Author, by a feed's title and author, test all four kinds.

### The view editor: sort, limit, and saving
<!-- id: view-editor-sort-limit-saving; keys: Sort By, Order, Show at Most, Chosen By, Only the Latest from Each Feed, Save, Cancel; src: TextMouth/Models/LibraryViewEditorWording.swift, TextMouth/ViewModels/LibraryViewEditorModel.swift, TextMouth/Views/Settings/LibraryViewEditorSheet.swift -->

- "Only the Latest from Each Feed" is a checkbox with the hint "Of each feed's episodes and articles, lists only the one you opened last."
  It is dimmed, with the hint "Applies only to a view that lists episodes or articles.", while the view lists neither.

- "Sort By" is a pop-up of the Sort menu's fields, Title, Author, Date Added, Last Opened, File Size, and Manual Order, and "Order" is a pop-up of "Ascending" and "Descending", dimmed in Manual Order, with the hint "Manual order has no direction".
  A view that lists only feeds has the sentence "Feeds are always listed by title." in their place.

- "Show at Most" is a checkbox, followed by a number field and a stepper, both spoken "Most rows shown", 1 to 9,999, and a pop-up "Chosen By" with "Opened Last", "Added Last", and "First in the Sort", which says which rows stay when the view would list more.
  They are dimmed, with the hint "A limit chooses among books, episodes, and articles, never feeds.", for a view that lists feeds alone.

- The count, a sentence at the end of the form, says what the draft lists now, as in "Lists 23 books and 2 feeds.", "Lists 2 books, 1 episode, and 1 article.", or "Lists nothing now.", and changes as you change the draft, ranked by the draft's sort.
- "Cancel" closes the sheet and changes nothing.
  "Save" checks the draft; a problem stays on the sheet as a sentence, which VoiceOver also says, and nothing is saved.
  The problems are "Give the view a name.", "A view's name can be at most 60 characters.", "Another view is already named Unopened Copy.
  Choose another name."
  (naming the view that has the name), "Choose at least one kind of item for the view to list.", "Condition 2 needs the text to look for."
  (naming the condition), and, for a new view at the limit, "The Library holds at most 200 views."
  A saved view is selected in the list, and once the sheet has closed VoiceOver says "Saved Unread EPUBs." or, for a new view, "Added Unread EPUBs, 7 of 7."
