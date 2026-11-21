# Library views: research and design (October 30, 2026)

The design of customizable Library views, written by `views-lead` before any code. The team builds the recommended answer to every question in section 10 tonight; the user answers only where they want something else.

## The request

The user wrote on October 30, 2026:

> "for new features I did want a optional library view which just shows "Feeds" loaded. in optional I want a settings section that allows reorganizing and changing which views show up as available in the Library, for settings of always, when applicable (like the reading list would show up only when there are episodes or reading list items) and allow moving up and down the views... then I want the ability to make custom views for that would basically act as filter or shortcuts for example for showing all books that are unopened and sorted in descending order or feeds with only new items..... but with more customization... the built in views should use the same system and be customizable."

Four parts:

1. A Feeds view, which lists the feeds alone.
2. A settings section listing the Library's views in order, each shown Always, When Applicable, or Hidden, with Move Up and Move Down.
3. Custom views: saved filters and sorts over the library.
4. One system: the built-in views are entries of the same list, customizable through it.

## Contents

1. What exists today
2. The model
3. The built-in views as presets
4. The filter language
5. Visibility
6. The window's picker and keys
7. The settings section and the editor
8. Storage, migration, and the version
9. Every wording a listener meets
10. Questions for the user
11. The build plan

## 1. What exists today

A Library window shows one of five categories (`LibraryCategory`), chosen in a segmented picker. Every place that depends on the category follows, by file, with what it decides.

### The category and the place

- `TextMouth/ViewModels/LibraryViewModel.swift:22-95`: `LibraryCategory`, five cases whose raw values are their names (Folders, All Items, Unopened, Recently Opened, Reading List). Raw values are an on-disk contract (`OnDiskContractTests`), and the decoder reads the former names "No Folder" and "Recent". `sortSettingsKey` gives each category but Folders a reserved key (`__allItems__`, `__unopened__`, `__recent__`, `__readingList__`); `defaultSortSetting` gives each its default sort.
- `TextMouth/Models/LibrarySortState.swift:13-95`: `LibraryLocation` (a category and a folder path). It decides the sort key, the default sort, the name in the title, `keepsItsOwnOrder` (the Reading List), `manualOrderFolder` (Folders only), `reorderTarget`, and `windowTitle` ("Library: Fiction (Author Descending)", "Library: Reading List").
- `TextMouth/Models/LibrarySortState.swift:296-328`: `Library.sortState(at:)` and `sortSetting(at:)`: the saved setting under the location's key, the No Folder carry-over at Unopened, and the Reading List's one order.
- `TextMouth/Models/BookFolder.swift:38-42`: `reservedNames`, the categories' keys and `__noFolder__`, which no folder may take as a name.
- `TextMouth/Models/Library.swift:41-52`: the default sorts (`defaultSort`, `recentDefault`, `unopenedDefault`, `readingListOrder`).

### What a category lists

- `TextMouth/ViewModels/LibraryViewModel+FolderManagement.swift:396-411`: `displayedBooks(at:matching:)`, through the cache, sorting all but the Reading List.
- `TextMouth/ViewModels/LibraryViewModel+FolderManagement.swift:450-464`: `booksForCategory`: a folder's books and its feed's items; `library.libraryBooks`; `library.unopenedBooks()`; `LibraryBookSorter.recent(library.books)`; the reading list's books.
- `TextMouth/Models/LibraryBookSorter.swift:14-31`: `recent(_:limit:)`: opened books, newest first, one item per feed (the one opened last), at most ten.
- `TextMouth/ViewModels/LibraryListCache.swift:38-69`: the cache key (category, folder path in Folders, sort field and direction, search, the feed of the folder shown). `289-297`: `hasSameListFields`, the book fields a list reads.
- `TextMouth/Views/Feeds/FeedLibraryPresentation.swift:176-194`: `LibraryFeedsSectionRows.feeds(at:center:)`: every feed in All Items; the feeds below the folder in Folders; feeds with a new item in Unopened; none in Recently Opened and the Reading List.
- `TextMouth/Views/Feeds/LibraryFeedFolders.swift:153`: a feed's folder has no Folders row only in Folders.

### The window

- `TextMouth/Views/ContentView.swift:12`: the window's `@State category`, starting at Folders, never saved.
- `ContentView.swift:44`: passes the category to `LibraryView`.
- `ContentView.swift:146` and `389`: imports and Import Folder… made at the Reading List join the list.
- `ContentView.swift:245-253`: the window title, from the location and its sort.
- `TextMouth/Views/Library/LibraryView.swift:204`: the category binding; `211-214`: `categoryPickerLabel`, "Library category".
- `LibraryView.swift:366-376`: the segmented picker over `LibraryCategory.allCases`.
- `LibraryView.swift:379` and `949-958`: the Reading List's options bar.
- `LibraryView.swift:382`: breadcrumbs, in Folders below the top.
- `LibraryView.swift:436-445`: the summary bar, counting the feeds the location lists.
- `LibraryView.swift:452`: the Folders section, in Folders only.
- `LibraryView.swift:460`: the Feeds section, by location.
- `LibraryView.swift:498-502`: a change of category clears the selection.
- `LibraryView.swift:506`: Up One Level, in Folders below the top.
- `LibraryView.swift:530`: New Folder, in Folders only.
- `LibraryView.swift:643`: the feed commands' folder, in Folders only.
- `LibraryView.swift:774`: New from Text at the Reading List joins the list.
- `LibraryView.swift:876-893`: the Sort menu: the Reading List's one item, or the fields.
- `LibraryView.swift:920`: Apply Sort to All Subfolders, in Folders with subfolders.
- `LibraryView.swift:1152`: the "In reading list" note, everywhere but the Reading List.
- `LibraryView.swift:1271`: the empty reading list's sentence.
- `LibraryView.swift:1301`: the feed of the folder shown, in Folders only.
- `LibraryView.swift:1319`: a feed's row opens its folder, switching to Folders.
- `LibraryView.swift:1370`: a book opened at the Reading List is read from the list (`ReadingListOpenRequests`, `TextMouth/Services/ReadingListOpenRequests.swift:61-84`).
- `LibraryView.swift:1446` and `1462`: the edit bar's reading list command, and the selection pruned at the Reading List.
- `LibraryView.swift:1662-1670`: the Folder or Feed Settings target, in Folders only (`TextMouth/Views/Library/LibraryFolderSettingsTarget.swift:54-71`).
- `LibraryView.swift:1703-1748` and `1860`: the location, its sort, its reorder target, and its books.

### What nothing depends on

- No menu command switches the category (`TextMouth/App/MenuCommands.swift`), and no shortcut uses a digit: Command-1 to Command-9 are free (`TextMouth/Models/KeyboardShortcut.swift:1501-1700`).
- The category is never saved: every window opens at Folders.

### The tests that pin categories

`FolderSortSettingTests`, `UnopenedCategoryTests`, `LegacyLibraryModelTests`, `LibrarySortStateTests`, `LibrarySortSavingTests`, `ReadingListViewTests`, `ReadingListReaderTests`, `LibraryFolderSettingsTargetTests`, `FeedUILibraryRowsTests`, `OnDiskContractTests`, `LibraryListCacheTests`, `ViewsAndWindowsLibraryListTests`, and `ViewsAndWindowsBenchmarks`. Ten hosted test files build `LibraryView(currentFolderPath:category:showFileImporter:showTextInput:onOpenBook:)`. Tests use `LibraryLocation(category:folderPath:)`, `location.category`, `location.sortSettingsKey` as a dictionary key, and `LibraryCategory.allCases` (five). So the design keeps all of these as they are.

## 2. The model

### Names

Every new type is named `LibraryView…` followed by a noun that is not a SwiftUI view, or `LibraryViewDefinition…`, so none can be read as the SwiftUI `LibraryView` struct:

- `LibraryViewDefinition`: one view of the list.
- `LibraryViewID`: a view's permanent identity.
- `LibraryViewKind`: Folders, Reading List, or a filter view.
- `LibraryViewVisibility`: Always, When Applicable, Hidden.
- `LibraryViewFilter`, `LibraryViewCondition`, `LibraryViewItemKind`, `LibraryViewMatch`, `LibraryReadingState`, `LibraryViewLimit`: a filter view's filter.
- `LibraryViewDefinitionList`: the ordered list, with the entries this TextMouth cannot read.
- `LibraryViewDefinitionStore`: the observable owner of the list, kept in the preferences store and mirrored in config.json.
- `LibraryViewFilterContext`: what a filter reads beyond the books (today's date, the finished books, folders' paths).
- `LibraryViewsSettingsView`, `LibraryViewEditorSheet`, `LibraryViewEditorModel`: the Settings tab and the editor.
- Wording: `LibraryViewPickerWording` (the window), `LibraryViewsSettingsWording` (the tab), `LibraryViewEditorWording` (the editor and the conditions).

### A view

`LibraryViewDefinition` holds:

- `id: LibraryViewID`: permanent.
- `name: String`: what the picker and the title say.
- `visibility: LibraryViewVisibility`.
- `filter: LibraryViewFilter?`: what a filter view lists; nil exactly for Folders and the Reading List.
- `kind` (computed from the id): `.folders`, `.readingList`, or `.filter`.
- `isBuiltIn` (computed): every id but a custom one.

A view's place in the order is its index in the list: there is no separate position field, so two views can never claim one place.

### Identity

`LibraryViewID` is one of:

- `.category(LibraryCategory)`: the five views TextMouth has always had. Stored as the category's raw value ("Folders", "All Items", "Unopened", "Recently Opened", "Reading List"), which is already an on-disk contract, and whose decoder already reads "No Folder" and "Recent".
- `.feeds`: the new Feeds view, stored as "Feeds".
- `.custom(UUID)`: a view the listener made, stored as the UUID's string.

`LibraryCategory` stays exactly as it is, with its five cases. It is the identity of five built-in views and the key of their sorts.

### A place in the library

`LibraryLocation` becomes a view and a folder path:

- `view: LibraryViewDefinition` and `folderPath: String`, stored.
- `init(view:folderPath:)`, which the window uses, and `init(category:folderPath:)`, which keeps every test and every caller that names a category working: it makes the location of that category's shipped view.
- `category: LibraryCategory`, computed: the view's own category for the five; All Items for the Feeds view and every custom view. It names the rules a location follows where a caller takes a category (`ReadingListOpenRequests`, `LibraryFolderSettingsTarget`, `LibraryFeedFolders.folderRows`), which only tell Folders and the Reading List from the rest. New code asks `view.kind` and `view.id` instead.
- `sortSettingsKey: String`: the folder path in Folders, a category's reserved key for the other four categories, and `"/views/" + id` for Feeds and custom views (section 8).
- `defaultSortSetting`: the category's default for the five; Title ascending for Feeds and custom views.
- `name`: the folder's name in Folders, as now; the view's name elsewhere.
- `keepsItsOwnOrder`: the Reading List.
- `listsOnlyFeeds` (new): a filter view whose filter lists feeds and nothing else.
- `manualOrderFolder`, `reorderTarget`: unchanged, by kind.
- `windowTitle(sortedBy:)`: "Library: <name> (<sort>)", or "Library: <name>" for the Reading List and for a view listing only feeds.

### What stays special

- **Folders** shows one folder at a time, with breadcrumbs, the Folders section, New Folder, Up One Level, Apply Sort to All Subfolders, and each folder's manual order. Customizable: its place in the list. It is always shown (section 5), cannot be renamed, edited, duplicated, or deleted.
- **The Reading List** shows its own order and its options bar. Customizable: its place and its visibility. It cannot be renamed, edited, duplicated, or deleted: its name is in the commands that fill it (Add to Reading List, Next in Reading List).
- **Filter views** (All Items, Unopened, Recently Opened, Feeds, and custom views) list what their filter finds, sorted by their sort.

## 3. The built-in views as presets

Each built-in filter view is a filter of the same language as a custom view, and is evaluated by the same code. Shipped definitions:

- **All Items**: lists books and feeds; no conditions. Sort: Title ascending until chosen (`__allItems__`).
- **Unopened**: lists books and feeds; all of: reading state is Unopened; has new episodes or articles. Sort: Date Added descending until chosen (`__unopened__`, with the No Folder carry-over unchanged).
- **Recently Opened**: lists books, episodes, and articles; all of: reading state is not Unopened; only the latest from each feed; at most 10, chosen by Opened Last. Sort: Last Opened descending until chosen (`__recent__`).
- **Feeds** (new): lists feeds; no conditions. Feeds are always listed by title.

Each preset gives exactly today's list:

- All Items' books are the library's own books (`library.libraryBooks`), and its feeds every feed.
- Unopened's books are those never opened (`library.unopenedBooks()`): the condition "has new episodes or articles" tests feeds only, so it never hides a book. Its feeds are those with a new item: "reading state" tests no feed.
- Recently Opened's rows are `LibraryBookSorter.recent(library.books)`'s, in its order: the sorter's algorithm becomes `LibraryBookSorter.latestOpened(_:limit:onePerFeed:)`, which `recent` calls and the evaluator calls for a limit chosen by Opened Last, so the two cannot drift apart. The ten are chosen by last opened whatever sort is shown, as now.
- A test compares each preset's rows, in order, with the old functions on a library of books, episodes, articles, opened and unopened, finished and not, with ties.

What a built-in filter view lets the listener change, through the same editor as a custom view: its name, what it lists, its conditions, its sort, its limit, and "only the latest from each feed". Restore Default gives back the shipped name, filter, and sort. What stays fixed, and why:

- Its id and its being built in: the window and the documents name it, so it can be hidden, never deleted.
- Folders' and the Reading List's contents, order, and names (above).
- The order of feeds, by title in every view, as the Feeds section always has.

## 4. The filter language

### What a view lists

`lists`, any of: Books (rows of the library's own books), Episodes (feed items whose format is audio), Articles (other feed items), Feeds (feed rows). At least one. Episodes and articles are those downloaded, which have rows, as Recently Opened and the Reading List list them now; a feed's items not downloaded are listed in its folder alone (section 10, question 10).

The rule for telling the three kinds of rows apart moves into one place, `Book.listedKind`, which `CountWording`'s counts use too.

### Conditions

Each condition is a test and a negation (`isNegated`). Conditions about books test books, episodes, and articles; conditions about feeds test feeds; a condition never hides a row it does not test.

- **Format** is or is not one of `BookFormat`'s formats (all 18, by `displayName`). Tests books, episodes, articles: `book.format`.
- **Folder** is or is not a chosen folder, with or without the folders inside it, or Library Root (the books at the top of the library). Stored by the folder's ID, so renaming and moving the folder keep it. Tests books by `folderPath`, episodes and articles by their feed's folder, feeds by their folder. A folder no longer in the library matches nothing.
- **Reading state** is or is not Unopened (`lastOpened == nil`), In Progress (opened and not finished), or Finished (in `ReadingStats.finishedBookIDs`, as Books Finished counts). Tests books, episodes, articles.
- **Reading list**: in it or not (`library.readingList.bookIDs`). Tests books, episodes, articles.
- **Date added** within the last N days or not, 1 to 3,650: added today or on one of the N−1 days before, by this Mac's calendar. Tests books, episodes, articles (`dateAdded`).
- **Date opened** within the last N days or not, the same way (`lastOpened`; a row never opened is not within). Tests books, episodes, articles.
- **Title or author** contains, or does not contain, a text of 1 to 200 characters, ignoring case as the window's search does. Tests every row: a feed's title and author.
- **New items**: a feed has a new episode or article, or none (`FeedCenter.counts(of:).new`). Tests feeds.
- **Subscription**: subscribed or unsubscribed (`Feed.isSubscribed`). Tests feeds.

At most 20 conditions in a view.

### Matching

`match`: All Conditions or Any Condition. A row is listed when it is of a kind the view lists and, of the conditions that test it, all hold (All) or at least one holds (Any). A row that no condition tests is listed. With no conditions, the view lists every row of its kinds.

### After the conditions

In this order:

1. **Only the latest from each feed** (`onePerFeed`): of each feed's episodes and articles, the one opened last.
2. **The limit** (`limit`, optional): at most N rows, 1 to 9,999, chosen by Opened Last (most recently opened first), Added Last (most recently added first), or First in the Sort (the first N in the view's sort).
3. **The sort**: the view's sort orders the rows left; feeds come in their own section, by title.

### Left out, as follow-ups

Each needs data TextMouth does not keep, or a new kind of row:

- A feed's episodes and articles not downloaded, in a filter view.
- Duration or time left, author alone, series, language, and file size as conditions.
- "Subscribed within N days" for feeds, and sorting feeds.
- Nested groups of conditions (All within Any).

## 5. Visibility

The settings show three words: **Always**, **When Applicable**, **Hidden**.

### When a view is applicable

A view is applicable while it lists something:

- Folders: always.
- The Reading List: while it holds a book, an episode, or an article.
- A filter view: while its filter lists at least one row, book or feed. Feeds' shipped filter is applicable while there is a feed, subscribed or not.

### Which views the picker offers

The views shown Always, then those shown When Applicable while applicable, in the list's order; and the view the window shows, wherever it is, whatever its visibility (below).

### At least one view

Folders is always shown: its visibility is fixed at Always, and its pop-up is dimmed with the reason. So no setting can leave the picker empty, and a feed's row, which opens the feed's folder, always has Folders to open it in.

### A window never leaves its view by itself

- A view hidden in Settings, or emptied, while a window shows it stays shown in that window, and in its picker, until the listener chooses another view; then it leaves the picker. Nothing moves under VoiceOver's cursor, and nothing is announced.
- A view deleted while a window shows it cannot stay. The window moves to the first view the picker offers (Folders, unless another is first) and announces, from that window, "The view this window showed was deleted. It now shows Folders." The Delete confirmation says beforehand that windows showing the view will show another.
- A new Library window opens at the first view the picker offers.

## 6. The window's picker and keys

### The picker

A pop-up button, always:

- Visible label "View"; VoiceOver hears its value and then its label, "Unopened, Library view, pop-up button". The spoken label changes from "Library category" to "Library view", the word the settings use (one assertion in `UnopenedCategoryTests` changes on purpose).
- Items: the offered views' names, in order. A braille display shows the value and label.
- Its width is bounded (`frame(maxWidth: 320)`), so a long custom name never makes the window's content outgrow the window, which once crashed the test host. Names are at most 60 characters.
- Choosing a view with the pop-up says nothing more: VoiceOver speaks the item chosen, as it spoke the segment.

Why a pop-up, not segments: six segments crowd the control at the window's minimum width of 600 points, custom views add more, and a control that changes kind as the window resizes would change how VoiceOver reads it under the listener.

### Keys

Command-1 to Command-9 are free. The last task of the build adds nine shortcut actions, Go to View 1 to Go to View 9, with Command-1 to Command-9 by default, in the Shortcuts tab under Library, and a Library menu submenu, Go to View, listing the views offered, each of the first nine with its key. A key counts the views offered Always and When Applicable, not a view kept only because it is shown, so a key always goes to the same view. Going to a view by key or menu announces its name and what it lists, "All Items, 743 books, 2 feeds". A key with no view says "There is no view 7. The View pop-up offers 6 views."

## 7. The settings section and the editor

### Where

A new Settings tab, **Library**, between Stats and Feeds, symbol `books.vertical`. The window grows from 780 to 860 points, as it grew for Braille, so the eleven tabs fit its toolbar. Like the Text tab, the Library tab does not scroll as a whole: its list fills the room the other controls leave (`SettingsTabFitTests` gains the tab on purpose).

### The list

- One row per readable view, in order, each one element. VoiceOver reads "Reading List, built in, always, 5 of 6"; its hint describes the filter, "Lists books and feeds: reading state is Unopened, and has new episodes or articles".
- The first view is selected when the tab opens. Arrow keys move the selection; Return or a double-click is Edit… for a view that can be edited.
- Each row's VoiceOver actions, only those that apply: Move Up, Move Down, Show Always, Show When Applicable, Hide, Edit…, Duplicate, Delete…, Restore Default…. Its context menu has the same commands.

### The controls for the selected view

- **Visibility** pop-up (Always, When Applicable, Hidden), spoken "Visibility of Reading List"; dimmed for Folders, with the hint "Folders is always shown: every folder and feed opens there."
- **Move Up** and **Move Down**, spoken "Move Reading List Up"; each announces the new place, "Reading List, 4 of 6", and is dimmed at the end it cannot pass.
- **New View…**: the editor, for a view of the listener's own, added at the end, shown Always.
- **Edit…**: the editor; for filter views.
- **Duplicate**: a custom copy of a filter view, named "<name> Copy" (then "<name> Copy 2"), right after it, shown Always, with the same sort.
- **Delete…**: custom views; asks first.
- **Restore Default…**: built-in filter views, while they differ from the shipped view; asks first.

### The editor sheet

A sheet over Settings, 620 by 520 points, scrolling inside, titled "New View" or "Edit <name>":

- **Name**: a text field, 1 to 60 characters, unique among the views, ignoring case.
- **Lists**: four checkboxes, Books, Episodes, Articles, Feeds.
- **Match**: All Conditions or Any Condition.
- **Conditions**: a row each, with a test pop-up, a relation pop-up, the value control the test needs, and Remove. Add Condition adds "Format is EPUB" at the end, up to 20. Every control's spoken label names its condition, "Condition 2", and VoiceOver reads a pop-up's value first: "Reading State, Condition 2, pop-up button".
- **Only the Latest from Each Feed**: a checkbox, while episodes or articles are listed.
- **Sort By** and **Order**, as the Sort menu offers them; Order is dimmed in Manual Order. A view listing only feeds says "Feeds are always listed by title." in their place.
- **Show at Most**: a checkbox, a number field with a stepper, and **Chosen By** (Opened Last, Added Last, First in the Sort).
- **The count**: "Lists 23 books and 2 feeds.", recounted as the draft changes, by the same code the window lists with.
- **Cancel** (Escape) and **Save** (Return). Save checks the draft; a problem stays on the sheet as a sentence, announced, and nothing is saved.

## 8. Storage, migration, and the version

### Where the definitions live

In **config.json, beside the other preferences**, under the key `libraryViews`, with the preferences store holding the same list under the same key, as every portable preference is mirrored (`ConfigService.AppConfig.Portability.mirrored`).

Why config.json and not library.json:

- An older TextMouth rewrites library.json from the four keys it knows, so it would drop the views at its first save, with no other copy left.
- An older TextMouth drops `libraryViews` from config.json too, but this Mac's preferences store keeps the list, and a config.json without the key changes no preference, so the next TextMouth writes the list back. Nothing is lost.
- Views are a preference about how to look at the library, beside the other preferences, editable by hand like them.

### The JSON

```json
"libraryViews" : [
  { "id" : "Folders", "visibility" : "always" },
  { "id" : "All Items", "visibility" : "always" },
  { "id" : "Unopened", "visibility" : "always" },
  { "id" : "Recently Opened", "visibility" : "always" },
  { "id" : "Reading List", "visibility" : "always" },
  { "id" : "Feeds", "visibility" : "whenApplicable" },
  {
    "filter" : {
      "conditions" : [
        { "test" : "format", "value" : "epub" },
        { "test" : "readingState", "value" : "unopened" }
      ],
      "limit" : { "chosenBy" : "dateAdded", "count" : 20 },
      "lists" : [ "books" ],
      "match" : "all"
    },
    "id" : "6F9619FF-8B86-D011-B42D-00C04FC964FF",
    "name" : "Unread EPUBs",
    "visibility" : "always"
  }
]
```

- A built-in view's entry holds `id` and `visibility`, and `name` or `filter` only once the listener changed them, so later TextMouths can improve the shipped presets. A custom view's entry holds all four.
- A condition is `{"test": …}` with, by test, `"value"` (a `BookFormat` raw value, or `unopened`, `inProgress`, `finished`), `"folderID"` (a UUID, or null for Library Root) and `"includingSubfolders"`, `"days"`, or `"text"`; and `"not": true` when negated. Tests: `format`, `folder`, `readingState`, `inReadingList`, `addedWithin`, `openedWithin`, `titleOrAuthorContains`, `hasNewItems`, `subscribed`.
- `onePerFeed` is written only when true, `limit` only when set, `"not"` only when true.

### Reading it, as untrusted input

- Each entry is read on its own. An entry this TextMouth cannot read (an unknown id, test, format, state, or kind, a custom view without a name or a filter, a filter listing nothing, or a duplicate id) is kept exactly as it was, in its place, and written back; it is never offered. The Library tab says how many need a newer TextMouth.
- Numbers out of range are moved into it, texts are cut to their limits (name 60, text 200), an unknown visibility reads as the view's default, and each repair is logged, as config.json's other fields are.
- At most 200 entries and 20 conditions per view are read; the rest are dropped, logged.
- A built-in view missing from the list is added at its end with its shipped definition, so no built-in view can be lost by a hand edit, and a later TextMouth's new built-in view appears.
- An empty list, or none, changes nothing.

### Sorts

Every view's sort stays in library.json's `folderSortSettings`, so the Sort menu, the window title, and the cache keep their one path:

- Folders under each folder's path, and All Items, Unopened, Recently Opened, and the Reading List under their reserved keys, as now.
- Feeds and custom views under `"/views/" + id`, such as `"/views/Feeds"`. A folder path never begins with "/", so no folder can take the key, and no folder name needs reserving (`BookFolder.reservedNames` keeps its five keys). Moving, renaming, deleting, and repairing folders never touch these keys: they are not valid library paths.
- An older TextMouth keeps these keys: it reads every key of `folderSortSettings` and writes them back.
- The editor's Sort By and Order save under the same key as the Sort menu. Duplicate copies the source's sort to the copy's key; Delete and Restore Default remove the key.

### An existing user's first launch

No `libraryViews` anywhere, so the list is the shipped one: Folders, All Items, Unopened, Recently Opened, Reading List, all Always, in today's order, with today's sorts, read from the same keys; then Feeds, When Applicable, last. Every window opens at Folders. config.json gains the list at its next save.

### The version

PATCH. A TextMouth one version older opens the library and config.json and keeps both working (above); no stored format changes, and nothing is removed or renamed: config.json gains a key and `folderSortSettings` new keys, both of which an older TextMouth tolerates.

## 9. Every wording a listener meets

### The Library window

- Picker: visible label "View"; spoken label "Library view"; items, the views' names.
- Window title: "Library: <view> (<sort>)", such as "Library: Unread EPUBs (Date Added Descending)"; "Library: Feeds" for a view listing only feeds; Folders and the Reading List as now.
- Sort menu in a view listing only feeds: the button "Sort feeds by Title"; its one item "Title", checked, with the hint "Feeds are always listed by title"; choosing it says "Feeds are listed by title".
- A Feeds or custom view listing nothing: the row "Nothing matches this view now." The five categories' views look as they do now.
- A view listing only feeds has no Books section.
- Summary bar and Speak Info: unchanged, counting the rows listed, "23 books, 2 feeds", "5 episodes".
- A view deleted while shown: "The view this window showed was deleted. It now shows Folders."
- Go to View: "All Items, 743 books, 2 feeds"; with no such view, "There is no view 7. The View pop-up offers 6 views."
- Menu: the submenu "Go to View", its items the views' names; the actions "Go to View 1" to "Go to View 9".

### The Library tab

- Tab: "Library". Section: "Views".
- Captions: "The Library window's View pop-up offers these views, in this order. A new Library window opens at the first one it offers." and "Always offers a view all the time. When Applicable offers it only while it lists something: the Reading List while it holds a book, an episode, or an article, and Feeds while there is a feed. Hidden leaves it out. A window showing a view keeps it until you choose another."
- The list: spoken label "Views"; a row, "<name>, built in|custom, always|when applicable|hidden, <n> of <count>"; its hint, the filter's description (below), or for Folders "Shows one folder at a time" and for the Reading List "Shows the books in the order you arrange".
- Row actions: "Move Up", "Move Down", "Show Always", "Show When Applicable", "Hide", "Edit…", "Duplicate", "Delete…", "Restore Default…".
- Visibility: visible "Visibility"; spoken "Visibility of <name>"; items "Always", "When Applicable", "Hidden"; hint "Sets when the View pop-up offers this view"; for Folders, dimmed, "Folders is always shown: every folder and feed opens there."
- Move buttons: visible "Move Up", "Move Down"; spoken "Move <name> Up", "Move <name> Down"; announcement "<name>, <n> of <count>".
- New View…: hint "Makes a view of your own from the conditions you choose."
- Edit…: hint "Changes the view's name, what it lists, its conditions, its sort, and its limit."; dimmed for Folders and the Reading List: "Folders and the Reading List list what they always have. You can move them, and hide the Reading List."
- Duplicate: hint "Makes a view of your own with this view's conditions and sort."; announcement "Made <new name>, <n> of <count>."
- Delete…: hint "Deletes the view. What it lists stays in the library."; dimmed for built-in views: "A built-in view can be hidden, not deleted." Alert: title "Delete the view “<name>”?"; message "Its conditions and sort are deleted. The books, episodes, articles, and feeds it lists stay in the library, and a Library window showing it shows another view."; buttons "Delete", "Cancel"; afterwards "Deleted <name>."
- Restore Default…: hint "Gives the view back the name, conditions, sort, and limit TextMouth gave it."; dimmed while it has them: "This view is as TextMouth made it." Alert: title "Restore “<name>” to its default?"; message "Its name, conditions, sort, and limit go back to TextMouth's own. Its place in the list and when it is offered stay as they are."; buttons "Restore Default", "Cancel"; afterwards "Restored <name>."
- Unreadable entries: "1 view needs a newer TextMouth. It is kept as it is, and not offered." / "<n> views need a newer TextMouth. They are kept as they are, and not offered."

### The editor

- Title: "New View", "Edit <name>".
- "Name"; "Lists" with "Books", "Episodes", "Articles", "Feeds"; caption "Conditions about books test books, episodes, and articles; conditions about feeds test feeds. A condition never hides a row it does not test."
- "Match": "All Conditions", "Any Condition".
- "Conditions"; with none, "No conditions: the view lists every item of the kinds chosen."
- Test pop-up, spoken "Condition <n>": "Format", "Folder", "Reading State", "Reading List", "Date Added", "Date Opened", "Title or Author", "New Items", "Subscription".
- Relation pop-up, spoken "Condition <n> relation", by test: Format, Folder, and Reading State "Is", "Is Not"; Reading List "In the Reading List", "Not in the Reading List"; Date Added and Date Opened "Within the Last", "Not Within the Last"; Title or Author "Contains", "Does Not Contain"; New Items "Has New Episodes or Articles", "Has None New"; Subscription "Subscribed", "Unsubscribed".
- Values, spoken "Condition <n> format", "Condition <n> folder" (items "Library Root" and the folders' paths, as the Move dialog names them), "Condition <n> includes subfolders" (visible "Including Subfolders"), "Condition <n> reading state" ("Unopened", "In Progress", "Finished"), "Condition <n> days" (caption "days"), "Condition <n> text".
- Remove: visible "Remove", spoken "Remove condition <n>". "Add Condition"; at 20, dimmed: "A view holds at most 20 conditions."
- "Only the Latest from Each Feed", hint "Of each feed's episodes and articles, lists only the one you opened last."
- "Sort By"; "Order" ("Ascending", "Descending"), dimmed in Manual Order with the Sort menu's hint "Manual order has no direction"; for feeds alone, "Feeds are always listed by title."
- "Show at Most", the field spoken "Most rows shown", "Chosen By": "Opened Last", "Added Last", "First in the Sort".
- The count: "Lists 23 books and 2 feeds." (the counts as `CountWording` phrases them, joined as a sentence lists them), or "Lists nothing now."
- "Cancel", "Save".
- Errors: "Give the view a name."; "A view's name can be at most 60 characters."; "Another view is already named <name>. Choose another name."; "Choose at least one kind of item for the view to list."; "Condition <n> needs the text to look for."
- After Save: "Saved <name>." or, for a new view, "Added <name>, <n> of <count>."
- A filter's description, for the list's hint: "Lists <kinds>" then, with conditions, ": " and the conditions joined by "and" (All) or "or" (Any), each as "format is EPUB", "folder is Fiction, including subfolders", "reading state is Finished", "in the reading list", "added within the last 7 days", "not opened within the last 30 days", "title or author contains “Austen”", "has new episodes or articles", "subscribed"; then, as they apply, "; only the latest from each feed" and "; at most 10, opened last".

## 10. Questions for the user

The team builds every recommended answer tonight.

1. **The Feeds view's visibility and place.** You called it optional. Recommended: When Applicable, last in the list, so it appears once you subscribe to a feed and can be hidden in the Library tab.
2. **The Reading List's visibility.** Today it is always shown. Recommended: Always, as now; When Applicable is one choice away.
3. **The word for hidden.** Recommended: "Hidden" (Always, When Applicable, Hidden), which also reads well in a row: "Feeds, built in, hidden, 6 of 6".
4. **The picker.** Recommended: a pop-up button always, labeled View and spoken "Library view" (until now "Library category"). The alternative keeps the segmented control while five views or fewer are offered, and switches to a pop-up beyond.
5. **Where the settings live.** Recommended: a new Library tab between Stats and Feeds, the window 80 points wider. The alternative is a section of the Miscellaneous tab.
6. **Hiding Folders.** Recommended: Folders cannot be hidden, since every folder and every feed's episodes open there.
7. **Renaming built-in views.** Recommended: All Items, Unopened, Recently Opened, and Feeds can be renamed and edited, and restored; Folders and the Reading List cannot, since commands use their names.
8. **Keys for views.** Recommended: Command-1 to Command-9 go to the first nine views offered, changeable in the Shortcuts tab, with a Go to View submenu in the Library menu. Built last tonight; if time runs out, it is a follow-up.
9. **A view hidden or emptied while shown.** Recommended: the window keeps it until you choose another view, and says nothing.
10. **Episodes not downloaded.** Recommended: a custom view lists downloaded episodes and articles, as Recently Opened does; listing those not downloaded is a follow-up.
11. **The empty sentence.** Recommended: "Nothing matches this view now." in Feeds and custom views only; the five views you know look as they do now.
12. **Restore Default.** Recommended: it restores the name, conditions, sort, and limit, and leaves the place and the visibility.
13. **Announcements on switching.** Recommended: the pop-up says only what VoiceOver says of it; Go to View announces the view and its counts.
14. **"Only the Latest from Each Feed".** Recommended: offered to every view, as Recently Opened uses it.
15. **What a limit keeps.** Recommended: Opened Last, Added Last, or First in the Sort, so Recently Opened's ten stay the ten opened last whatever sort you choose.
16. **Sorting feeds.** Recommended: always by title, as now; a sort of their own is a follow-up.

## 11. The build plan

Each task is a worker on its own branch from `team/views`, one or two commits, its tests named in its brief. Builds run one at a time. Behavior stays identical for an existing user until task 5, which deliberately changes the picker to a pop-up spoken "Library view".

1. **`model`**: `LibraryViewDefinition.swift` (the types, the shipped presets, JSON reading with bounds and writing) and `LibraryViewDefinitionList.swift` (the ordered list, unreadable entries kept, missing built-ins added, the operations: move, set visibility, add, replace, duplicate, delete, restore default, the views offered, the first offered). Two commits. Tests: `LibraryViewDefinitionTests`, `LibraryViewDefinitionListTests`. No behavior change.
2. **`evaluator`** (after 1): `LibraryViewFilterEvaluator.swift` (rows matching a filter, latest per feed, limit; feeds matching), `LibraryViewFilterContext`, `LibraryBookSorter.latestOpened` with `recent` calling it, `Book.listedKind` with `CountWording` using it. Tests: `LibraryViewFilterEvaluatorTests`, including the preset equivalence; `LibrarySortStateTests`, `UnopenedCategoryTests`, `ReadingListViewTests` (counts). No behavior change.
3. **`store`** (after 1, beside 2): `LibraryViewDefinitionStore.swift` (the preference, the observer, the operations writing it), `ConfigService.AppConfig.libraryViews` and its Portability entry, `SettingsViewModel`'s write and adopt lines. Tests: `LibraryViewDefinitionStoreTests`, the config and settings test classes, `OnDiskContractTests`. No behavior change.
4. **`location`** (after 2): `LibraryLocation` holding a view (`LibrarySortState.swift`), the cache key (`LibraryListCache.swift`, with `format` in `hasSameListFields`), `displayedBooks` and `booksForCategory` through the evaluator (`LibraryViewModel+FolderManagement.swift`), `LibraryFeedsSectionRows.feeds(at:)` through it (`FeedLibraryPresentation.swift`), and the `"/views/"` keys kept by folder operations. Tests: every class that pins categories (section 1), `LibraryListCacheTests`, and a new `LibraryViewLocationTests`. No behavior change.
5. **`window`** (after 3 and 4): `ContentView`'s view state, `LibraryView`'s view binding with a category-binding initializer for the tests, the pop-up picker, every kind test, the fallback, the Feeds-only list (no Books section, the empty sentence, the feeds sort item). Tests: the hosted library tests (section 1), a new `LibraryViewPickerTests`, `make lint-a11y`.
6. **`settings`** (after 3, beside 4 and 5): `LibraryViewsSettingsView.swift`, `LibraryViewsSettingsWording`, the tab in `SettingsView.swift`, `LibraryViewModel.removeSortSetting(for:)`, Duplicate, Delete, Restore Default. Tests: `SettingsTabFitTests` (changed on purpose: eleven tabs, Library not scrolling as a whole), a new `LibraryViewsSettingsTests`, `make lint-a11y`.
7. **`editor`** (after 2 and 6): `LibraryViewEditorModel.swift`, `LibraryViewEditorWording`, `LibraryViewEditorSheet.swift`, New View… and Edit… in the tab, saving the definition and the sort. Two commits (the model, then the sheet). Tests: `LibraryViewEditorModelTests`, a hosted fit test of the sheet, `SettingsTabFitTests`, `make lint-a11y`.
8. **`goto`** (after 5, last, if time allows): nine shortcut actions, the Library menu's Go to View submenu, the window's handling. Tests: `KeyboardReachabilityTests`, `ShortcutMigrationTests`, the legacy shortcut scenarios, `MenuKeyShortcutTests`, a new `LibraryViewGoToTests`.

### The documents to change afterwards

`docs/user/library-window.md` (the picker, the views, the Feeds view), `docs/user/settings.md` (the Library tab), `docs/user/feeds.md` (the Feeds view), `docs/user/config-json.md` (`libraryViews`), `docs/user/settings.md`'s Shortcuts section and `docs/user/library-window.md`'s keys if task 8 lands, `docs/architecture/state/preferences.md` (the new mirrored preference), `docs/architecture/state/library-index.md` (the `"/views/"` sort keys), `docs/architecture/state/windows.md` (the window's view state), and the changelog.
